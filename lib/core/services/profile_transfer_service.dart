import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'attachment_uploader.dart';
import 'connection_manager.dart';

enum ProfileTransferErrorCode {
  unsupported,
  downloadUnavailable,
  fileTooLarge,
  invalidArchive,
  cancelled,
  stale,
  readOnly,
  server,
}

class ProfileTransferException implements Exception {
  const ProfileTransferException(
    this.code, {
    this.detail = '',
    this.serverPath,
  });

  final ProfileTransferErrorCode code;
  final String detail;
  final String? serverPath;

  @override
  String toString() => detail.isEmpty ? code.name : detail;
}

typedef ProfileArchiveShare = Future<void> Function(File archive);
typedef ProfileTransferProgress = void Function(int received, int? total);

class ProfileTransferService {
  ProfileTransferService({
    required this.client,
    required this.readOnly,
    Future<Directory> Function()? cacheDirectory,
    int Function()? nowMillis,
    bool Function()? isCurrent,
  }) : _cacheDirectory = cacheDirectory ?? getTemporaryDirectory,
       _nowMillis = nowMillis ?? _systemNowMillis,
       _isCurrent = isCurrent ?? _alwaysCurrent;

  static const int maxArchiveBytes = 100 * 1024 * 1024;

  final DashboardClient client;
  final bool readOnly;
  final Future<Directory> Function() _cacheDirectory;
  final int Function() _nowMillis;
  final bool Function() _isCurrent;
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  Future<void> exportProfile(
    String profile, {
    required ProfileArchiveShare share,
    ProfileTransferProgress? onProgress,
  }) async {
    _begin();
    String? remotePath;
    File? localArchive;
    var downloaded = false;
    try {
      final response = await client.apiPost(
        'profiles/${Uri.encodeComponent(profile)}/export',
        body: const {'extra_files': <String, String>{}, 'output': ''},
      );
      _ensureCurrent();
      remotePath = (response['archive'] ?? '').toString().trim();
      if (remotePath.isEmpty) {
        throw const ProfileTransferException(
          ProfileTransferErrorCode.server,
          detail: 'The server did not return an archive path.',
        );
      }

      final cacheRoot = await _cacheDirectory();
      _ensureCurrent();
      final transferDirectory = Directory(
        '${cacheRoot.path}/hermes-profile-transfers',
      );
      await transferDirectory.create(recursive: true);
      await _clearDirectory(transferDirectory);
      localArchive = File(
        '${transferDirectory.path}/${_safeArchiveName(remotePath)}',
      );

      try {
        await client.apiDownloadToFile(
          'files/download?path=${Uri.encodeQueryComponent(remotePath)}',
          localArchive,
          maxBytes: maxArchiveBytes,
          onProgress: onProgress,
          isCancelled: () => _cancelled || !_isCurrent(),
        );
      } on DashboardHttpException catch (error) {
        if (error.statusCode == 403 || error.statusCode == 404) {
          throw ProfileTransferException(
            ProfileTransferErrorCode.downloadUnavailable,
            detail: _detail(error),
            serverPath: remotePath,
          );
        }
        rethrow;
      }
      downloaded = true;
      _ensureCurrent();
      await share(localArchive);
    } on DashboardDownloadCancelled {
      _throwCancelledOrStale();
    } on DashboardHttpException catch (error) {
      throw _mapHttp(error);
    } finally {
      if (downloaded && remotePath != null) {
        await _deleteRemote(remotePath);
      }
      if (localArchive != null) await _deleteLocal(localArchive);
    }
  }

  Future<String> importProfile(File archive, {String? name}) async {
    _begin();
    final filename = archive.uri.pathSegments.isEmpty
        ? ''
        : archive.uri.pathSegments.last;
    if (!_isArchiveName(filename)) {
      throw const ProfileTransferException(
        ProfileTransferErrorCode.invalidArchive,
      );
    }
    if (!await archive.exists()) {
      throw const ProfileTransferException(
        ProfileTransferErrorCode.invalidArchive,
      );
    }
    if (await archive.length() > maxArchiveBytes) {
      throw const ProfileTransferException(
        ProfileTransferErrorCode.fileTooLarge,
      );
    }
    _ensureCurrent();

    String? uploadedPath;
    try {
      final directory = await AttachmentUploader.resolveUploadDirectory(client);
      _ensureCurrent();
      final safeName = _safeArchiveName(filename);
      uploadedPath = '$directory/${_nowMillis()}_$safeName';
      await client.apiPostMultipartFile(
        'files/upload-stream',
        fieldName: 'file',
        filePath: archive.path,
        filename: safeName,
        fields: {'path': uploadedPath, 'overwrite': 'false'},
      );
      _ensureCurrent();
      final trimmedName = name?.trim();
      final result = await client.apiPost(
        'profiles/import',
        body: {
          'archive': uploadedPath,
          'name': trimmedName == null || trimmedName.isEmpty
              ? null
              : trimmedName,
        },
      );
      _ensureCurrent();
      final imported = (result['name'] ?? '').toString().trim();
      if (imported.isEmpty) {
        throw const ProfileTransferException(
          ProfileTransferErrorCode.server,
          detail: 'The server did not return the imported profile name.',
        );
      }
      return imported;
    } on DashboardHttpException catch (error) {
      throw _mapHttp(error);
    } finally {
      if (uploadedPath != null) await _deleteRemote(uploadedPath);
    }
  }

  void _begin() {
    _cancelled = false;
    if (readOnly) {
      throw const ProfileTransferException(ProfileTransferErrorCode.readOnly);
    }
    _ensureCurrent();
  }

  void _ensureCurrent() {
    if (_cancelled) {
      throw const ProfileTransferException(ProfileTransferErrorCode.cancelled);
    }
    if (!_isCurrent()) {
      throw const ProfileTransferException(ProfileTransferErrorCode.stale);
    }
  }

  Never _throwCancelledOrStale() {
    if (!_isCurrent()) {
      throw const ProfileTransferException(ProfileTransferErrorCode.stale);
    }
    throw const ProfileTransferException(ProfileTransferErrorCode.cancelled);
  }

  ProfileTransferException _mapHttp(DashboardHttpException error) {
    if (error.statusCode == 404 || error.statusCode == 405) {
      return ProfileTransferException(
        ProfileTransferErrorCode.unsupported,
        detail: _detail(error),
      );
    }
    if (error.statusCode == 413) {
      return ProfileTransferException(
        ProfileTransferErrorCode.fileTooLarge,
        detail: _detail(error),
      );
    }
    return ProfileTransferException(
      ProfileTransferErrorCode.server,
      detail: _detail(error),
    );
  }

  Future<void> _deleteRemote(String path) async {
    try {
      await client.apiDelete('files', body: {'path': path, 'recursive': false});
    } catch (_) {
      // Cleanup is best effort and must never hide the transfer result.
    }
  }

  Future<void> _clearDirectory(Directory directory) async {
    try {
      await for (final entry in directory.list()) {
        if (entry is File) await _deleteLocal(entry);
      }
    } catch (_) {
      // A stale cache file never blocks a fresh export.
    }
  }

  Future<void> _deleteLocal(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // The app cache remains bounded by the next transfer's cleanup pass.
    }
  }
}

int _systemNowMillis() => DateTime.now().millisecondsSinceEpoch;

bool _alwaysCurrent() => true;

bool _isArchiveName(String filename) {
  final lower = filename.toLowerCase();
  return lower.endsWith('.tar.gz') || lower.endsWith('.tgz');
}

String _safeArchiveName(String path) {
  final basename = path.split('/').last;
  final safe = basename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (_isArchiveName(safe)) return safe;
  return 'profile.tar.gz';
}

String _detail(DashboardHttpException error) {
  try {
    final decoded = jsonDecode(error.body);
    if (decoded is Map) {
      for (final key in const ['detail', 'message', 'error']) {
        final value = decoded[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    }
  } catch (_) {
    // Fall through to a stable status-only message.
  }
  return 'HTTP ${error.statusCode}';
}
