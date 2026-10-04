import 'dart:io';

import 'backup_restore_flow.dart';
import 'connection_manager.dart';

/// [HermesBackupGateway] over the Dashboard's `/api/ops` routes.
///
/// Every call carries `?profile=<name>`, `default` included: once the server
/// hosts several profiles it refuses an omitted one.
class DashboardBackupGateway implements HermesBackupGateway {
  DashboardBackupGateway(this._dashboard);

  final DashboardClient _dashboard;

  static const int _maxDownloadBytes = 2 * 1024 * 1024 * 1024;

  static String _profile(String profile) =>
      'profile=${Uri.encodeQueryComponent(profile)}';

  /// 404 and 405 mean the route does not exist on this server.
  static Never _rethrow(Object error) {
    if (error is DashboardHttpException &&
        (error.statusCode == 404 || error.statusCode == 405)) {
      throw const BackupRouteMissing();
    }
    throw error;
  }

  /// True only when the server positively shows the route: a plain success
  /// or the 422 the download route answers without its required `archive`.
  /// 404/405 mean it is missing (false). Anything else (401, 403, 5xx, a
  /// timeout, a dropped connection) proves nothing and is rethrown, so the
  /// page keeps its controls hidden until a retry succeeds.
  @override
  Future<bool> available() async {
    try {
      await _dashboard.apiGet('ops/backup/download');
      return true;
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 422) return true;
      if (error.statusCode == 404 || error.statusCode == 405) return false;
      rethrow;
    }
  }

  @override
  Future<BackupCreated> createBackup(String profile) async {
    final Map<String, dynamic> answer;
    try {
      answer = await _dashboard.apiPost(
        'ops/backup?${_profile(profile)}',
        body: const {},
      );
    } catch (error) {
      _rethrow(error);
    }
    final archive = answer['archive'];
    if (answer['ok'] != true || archive is! String || archive.isEmpty) {
      throw StateError('backup was not created');
    }
    return BackupCreated(
      archive: archive,
      name: answer['name']?.toString() ?? 'backup',
    );
  }

  @override
  Future<void> downloadBackup(
    String archive,
    String profile,
    File target,
  ) async {
    try {
      await _dashboard.apiDownloadToFile(
        'ops/backup/download?archive=${Uri.encodeQueryComponent(archive)}'
        '&${_profile(profile)}',
        target,
        maxBytes: _maxDownloadBytes,
      );
    } catch (error) {
      _rethrow(error);
    }
  }

  @override
  Future<void> importUpload(
    String profile,
    File zip, {
    required bool force,
  }) async {
    try {
      await _dashboard.apiPostMultipartFile(
        'ops/import-upload?${_profile(profile)}',
        fieldName: 'file',
        filePath: zip.path,
        filename: 'hermes-backup.zip',
        fields: {'force': force ? 'true' : 'false'},
        timeout: const Duration(minutes: 30),
      );
    } catch (error) {
      _rethrow(error);
    }
  }

  @override
  Future<Map<String, dynamic>> actionStatus(String name) =>
      _dashboard.getActionStatus(name);
}
