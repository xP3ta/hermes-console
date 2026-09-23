import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

enum GeneratedMediaKind { image, video, audio, file }

enum GeneratedMediaSourceKind { serverPath, https }

typedef GeneratedMediaProgress = void Function(int received, int? total);
typedef GeneratedMediaStreamingFetcher =
    Future<void> Function(
      String path,
      File destination,
      GeneratedMediaProgress onProgress,
      bool Function() isCancelled,
    );

class GeneratedMediaDownloadCancelled implements Exception {
  const GeneratedMediaDownloadCancelled();

  @override
  String toString() => 'generated_media_download_cancelled';
}

class GeneratedMediaAutoLoadCancellation {
  bool _isCancelled = false;
  final Set<void Function()> _listeners = {};

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    final listeners = _listeners.toList(growable: false);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void _addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void _removeListener(void Function() listener) {
    _listeners.remove(listener);
  }
}

class _GeneratedMediaAutoLoadWaiter {
  final Completer<void> completer = Completer<void>();
}

class GeneratedMediaReference {
  final String source;
  final GeneratedMediaKind kind;
  final GeneratedMediaSourceKind sourceKind;
  final String displayName;
  final String mimeType;
  final int? sizeBytes;
  final DateTime? modifiedAt;

  const GeneratedMediaReference({
    required this.source,
    required this.kind,
    required this.sourceKind,
    this.displayName = 'file',
    this.mimeType = 'application/octet-stream',
    this.sizeBytes,
    this.modifiedAt,
  });
}

sealed class GeneratedMediaSegment {
  const GeneratedMediaSegment();
}

class GeneratedMediaTextSegment extends GeneratedMediaSegment {
  final String text;
  const GeneratedMediaTextSegment(this.text);
}

class GeneratedMediaFileSegment extends GeneratedMediaSegment {
  final GeneratedMediaReference reference;
  const GeneratedMediaFileSegment(this.reference);
}

/// Detects Hermes' canonical `MEDIA:<path-or-url>` directives and keeps their
/// bytes in app-private storage. Server paths are fetched by the authenticated
/// Dashboard client supplied by the caller; they are never exposed as public
/// URLs or Android external-storage paths.
class GeneratedMediaService {
  static const int maxImageBytes = 25 * 1024 * 1024;
  static const int maxVideoBytes = 100 * 1024 * 1024;
  static const int maxFileBytes = 100 * 1024 * 1024;
  static const int maxAutoImageBytes = 15 * 1024 * 1024;
  static const int maxAutoTextBytes = 2 * 1024 * 1024;
  static const int maxAutoPdfBytes = 20 * 1024 * 1024;
  static const int maxAutoAudioBytes = 25 * 1024 * 1024;
  static const int maxAutoVideoBytes = 60 * 1024 * 1024;
  static const int maxConcurrentAutoLoads = 2;
  static const int _maxCacheBytes = 512 * 1024 * 1024;
  static const int _maxRedirects = 3;

  static const Set<String> _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.tiff',
  };
  static const Set<String> _videoExtensions = {
    '.mp4',
    '.mov',
    '.avi',
    '.mkv',
    '.webm',
    '.3gp',
  };
  static const Set<String> _audioExtensions = {
    '.mp3',
    '.m2a',
    '.wav',
    '.ogg',
    '.opus',
    '.m4a',
    '.flac',
  };
  static const Set<String> _executableExtensions = {
    '.apk',
    '.exe',
    '.msi',
    '.dmg',
    '.sh',
  };
  static const Set<String> _sensitiveDirectoryNames = {
    '.ssh',
    '.gnupg',
    '.aws',
    '.kube',
    '.docker',
    '.azure',
    '.gcloud',
  };
  static const Set<String> _sensitiveBasenames = {
    '.netrc',
    '.npmrc',
    '.pgpass',
    '.git-credentials',
    '.bash_history',
    '.zsh_history',
    '.python_history',
    '.psql_history',
    'authorized_keys',
    'key.properties',
    'credentials.json',
    'secrets.json',
    'id_rsa',
    'id_dsa',
    'id_ecdsa',
    'id_ed25519',
  };
  static const Set<String> _sensitiveExtensions = {
    '.jks',
    '.keystore',
    '.p12',
    '.pfx',
    '.pem',
    '.key',
    '.keytab',
    '.ovpn',
  };
  static const Set<String> _knownFileExtensions = {
    '.svg',
    '.pdf',
    '.docx',
    '.doc',
    '.odt',
    '.rtf',
    '.txt',
    '.md',
    '.epub',
    '.xlsx',
    '.xls',
    '.ods',
    '.csv',
    '.tsv',
    '.json',
    '.xml',
    '.yaml',
    '.yml',
    '.kmz',
    '.kml',
    '.geojson',
    '.gpx',
    '.pptx',
    '.ppt',
    '.odp',
    '.key',
    '.zip',
    '.tar',
    '.gz',
    '.tgz',
    '.bz2',
    '.xz',
    '.7z',
    '.rar',
    '.ipa',
    '.html',
    '.htm',
  };

  static final Map<String, Future<File>> _inFlight = {};
  static final List<_GeneratedMediaAutoLoadWaiter> _autoLoadWaiters = [];
  static int _activeAutoLoads = 0;

  static bool isTextLike(GeneratedMediaReference reference) {
    if (_isExecutableOrInstaller(
      reference.displayName,
      mimeType: reference.mimeType,
    )) {
      return false;
    }
    final lower = reference.displayName.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final extension = dot < 0 ? '' : lower.substring(dot);
    return reference.mimeType.startsWith('text/') ||
        const {
          '.txt',
          '.md',
          '.log',
          '.json',
          '.yaml',
          '.yml',
          '.csv',
          '.py',
          '.dart',
          '.js',
          '.ts',
          '.sh',
          '.xml',
          '.html',
          '.toml',
          '.ini',
        }.contains(extension);
  }

  static bool allowsAutoLoad(GeneratedMediaReference reference) =>
      !_isExecutableOrInstaller(
        reference.displayName,
        mimeType: reference.mimeType,
      );

  static bool allowsExternalOpen(File file, {required String mimeType}) =>
      !_isExecutableOrInstaller(file.path, mimeType: mimeType);

  static Future<bool> isSafeForInlinePreview(
    GeneratedMediaReference reference,
    File file,
  ) async {
    final sourcePath = reference.sourceKind == GeneratedMediaSourceKind.https
        ? Uri.tryParse(reference.source)?.path ?? reference.source
        : reference.source;
    if (_isSensitivePath(sourcePath) ||
        _isSensitiveName(reference.displayName)) {
      return false;
    }
    try {
      final resolvedPath = await file.resolveSymbolicLinks();
      return !_isSensitivePath(resolvedPath);
    } on FileSystemException {
      return false;
    }
  }

  static ({String connectionKey, String fileKey})? cacheLocator(File file) {
    final fileName = file.uri.pathSegments.isEmpty
        ? ''
        : file.uri.pathSegments.last;
    final dot = fileName.indexOf('.');
    final fileKey = dot < 0 ? fileName : fileName.substring(0, dot);
    final parentSegments = file.parent.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    final rootSegments = file.parent.parent.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    final connectionKey = parentSegments.isEmpty ? '' : parentSegments.last;
    final rootName = rootSegments.isEmpty ? '' : rootSegments.last;
    final sha256Key = RegExp(r'^[a-f0-9]{64}$');
    if (rootName != 'generated_media' ||
        !sha256Key.hasMatch(connectionKey) ||
        !sha256Key.hasMatch(fileKey)) {
      return null;
    }
    return (connectionKey: connectionKey, fileKey: fileKey);
  }

  static int autoLoadLimit(GeneratedMediaReference reference) {
    if (reference.kind == GeneratedMediaKind.image) return maxAutoImageBytes;
    if (reference.kind == GeneratedMediaKind.video) return maxAutoVideoBytes;
    if (reference.kind == GeneratedMediaKind.audio) return maxAutoAudioBytes;
    if (isTextLike(reference)) return maxAutoTextBytes;
    if (reference.mimeType == 'application/pdf' ||
        reference.displayName.toLowerCase().endsWith('.pdf')) {
      return maxAutoPdfBytes;
    }
    return maxAutoPdfBytes;
  }

  static Future<T> runAutoLoad<T>(
    Future<T> Function() load, {
    GeneratedMediaAutoLoadCancellation? cancellation,
    bool Function()? isCancelled,
  }) async {
    bool cancelled() =>
        cancellation?.isCancelled == true || (isCancelled?.call() ?? false);

    if (cancelled()) throw const GeneratedMediaDownloadCancelled();

    if (_activeAutoLoads < maxConcurrentAutoLoads) {
      _activeAutoLoads++;
    } else {
      final waiter = _GeneratedMediaAutoLoadWaiter();
      void cancelWaiter() {
        if (_autoLoadWaiters.remove(waiter)) {
          waiter.completer.completeError(
            const GeneratedMediaDownloadCancelled(),
          );
        }
      }

      cancellation?._addListener(cancelWaiter);
      _autoLoadWaiters.add(waiter);
      try {
        await waiter.completer.future;
      } finally {
        cancellation?._removeListener(cancelWaiter);
      }
      if (cancelled()) {
        _releaseAutoLoadSlot();
        throw const GeneratedMediaDownloadCancelled();
      }
    }

    try {
      return await load();
    } finally {
      _releaseAutoLoadSlot();
    }
  }

  static void _releaseAutoLoadSlot() {
    _activeAutoLoads--;
    if (_autoLoadWaiters.isEmpty) return;
    final waiter = _autoLoadWaiters.removeAt(0);
    _activeAutoLoads++;
    waiter.completer.complete();
  }

  static List<GeneratedMediaSegment> parseSegments(String content) {
    if (content.isEmpty || !content.contains('MEDIA:')) {
      return <GeneratedMediaSegment>[GeneratedMediaTextSegment(content)];
    }

    final segments = <GeneratedMediaSegment>[];
    final lines = content.split('\n');
    final text = StringBuffer();
    String? fenceMarker;
    var fenceWidth = 0;
    var withheldDirective = false;

    void flushText() {
      if (text.isEmpty) return;
      segments.add(GeneratedMediaTextSegment(text.toString()));
      text.clear();
    }

    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final hasNewline = index < lines.length - 1;
      final trimmed = line.trimLeft();
      final fence = RegExp(r'^(`{3,}|~{3,})').firstMatch(trimmed)?.group(1);
      if (fence != null &&
          (fenceMarker == null ||
              (fence[0] == fenceMarker && fence.length >= fenceWidth))) {
        if (fenceMarker == null) {
          fenceMarker = fence[0];
          fenceWidth = fence.length;
        } else {
          fenceMarker = null;
          fenceWidth = 0;
        }
        text.write(line);
        if (hasNewline) text.write('\n');
        continue;
      }

      final reference = fenceMarker != null ? null : _parseDirective(line);
      if (reference == null) {
        // Outside a code fence, MEDIA is a control directive rather than prose.
        // Drop malformed/unsupported directives so local paths, signed URLs or
        // traversal attempts never leak through Markdown, clipboard or TTS.
        if (fenceMarker == null && line.trimLeft().startsWith('MEDIA:')) {
          withheldDirective = true;
          if (hasNewline) text.write('\n');
          continue;
        }
        text.write(line);
        if (hasNewline) text.write('\n');
        continue;
      }

      flushText();
      segments.add(GeneratedMediaFileSegment(reference));
      if (hasNewline) text.write('\n');
    }
    flushText();
    if (segments.isNotEmpty) return segments;
    return <GeneratedMediaSegment>[
      GeneratedMediaTextSegment(withheldDirective ? '' : content),
    ];
  }

  static GeneratedMediaReference? referenceFromSource(String rawSource) {
    final source = rawSource.trim();
    if (source.isEmpty) return null;
    return _parseDirective('MEDIA:$source');
  }

  /// Extracts only successful first-party producer results. `agent_visible_image`
  /// is deliberately never fetched: it may be a sandbox-only path.
  static List<GeneratedMediaReference> referencesFromToolResult(
    String? toolName,
    Object? rawResult,
  ) {
    final normalizedName = toolName?.trim().toLowerCase();
    if (normalizedName != 'image_generate' &&
        normalizedName != 'video_generate') {
      return const [];
    }
    Object? decoded = rawResult;
    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return const [];
      }
    }
    if (decoded is! Map || decoded['success'] != true) return const [];

    final fields = normalizedName == 'image_generate'
        ? const ['host_image', 'image']
        : const ['video'];
    for (final field in fields) {
      final value = decoded[field];
      if (value is! String) continue;
      final reference = referenceFromSource(value);
      if (reference == null) continue;
      final expectedKind = normalizedName == 'image_generate'
          ? GeneratedMediaKind.image
          : GeneratedMediaKind.video;
      if (reference.kind == expectedKind) {
        return List<GeneratedMediaReference>.unmodifiable([reference]);
      }
    }
    return const [];
  }

  static GeneratedMediaReference? _parseDirective(String line) {
    final match = RegExp(r'^\s*MEDIA:\s*(.*?)\s*$').firstMatch(line);
    if (match == null) return null;
    var source = (match.group(1) ?? '').trim();
    if (source.length >= 2 &&
        ((source.startsWith('"') && source.endsWith('"')) ||
            (source.startsWith("'") && source.endsWith("'")))) {
      source = source.substring(1, source.length - 1).trim();
    }
    if (source.isEmpty || source.contains('\u0000')) return null;

    final uri = Uri.tryParse(source);
    final sourceKind = uri != null && uri.scheme.toLowerCase() == 'https'
        ? GeneratedMediaSourceKind.https
        : GeneratedMediaSourceKind.serverPath;
    if (uri != null &&
        uri.hasScheme &&
        sourceKind != GeneratedMediaSourceKind.https) {
      // Explicitly reject http:, file:, data: and custom schemes.
      return null;
    }
    if (sourceKind == GeneratedMediaSourceKind.https) {
      if (uri == null ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          _hasCredentialQuery(uri)) {
        return null;
      }
      source = uri.removeFragment().toString();
    }
    if (sourceKind == GeneratedMediaSourceKind.serverPath &&
        !_isSafeServerPath(source)) {
      return null;
    }

    final path = sourceKind == GeneratedMediaSourceKind.https
        ? uri!.path
        : source;
    if (_isSensitivePath(path)) return null;
    final rawName = _decodedBasename(path);
    if (_isSensitiveName(rawName)) return null;
    final displayName = _displayName(rawName);
    final lower = path.toLowerCase();
    final kind = _imageExtensions.any(lower.endsWith)
        ? GeneratedMediaKind.image
        : _videoExtensions.any(lower.endsWith)
        ? GeneratedMediaKind.video
        : _audioExtensions.any(lower.endsWith)
        ? GeneratedMediaKind.audio
        : GeneratedMediaKind.file;
    return GeneratedMediaReference(
      source: source,
      kind: kind,
      sourceKind: sourceKind,
      displayName: displayName,
      mimeType: _mimeType(displayName, kind),
    );
  }

  static bool _hasCredentialQuery(Uri uri) {
    try {
      return uri.queryParametersAll.keys.any(
        (key) => RegExp(
          r'(^|[_-])(token|key|secret|signature|credential|password|auth)($|[_-])',
          caseSensitive: false,
        ).hasMatch(key),
      );
    } on FormatException {
      return true;
    }
  }

  static String _decodedBasename(String path) {
    final raw = path.replaceAll('\\', '/').split('/').last;
    try {
      return Uri.decodeComponent(raw);
    } on FormatException {
      return raw;
    }
  }

  static String _displayName(String name) {
    var safe = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f]'), '_')
        .replaceAll(RegExp(r'\.{2,}'), '.')
        .trim();
    safe = safe.replaceFirst(RegExp(r'^\.+'), '');
    if (safe.length > 120) safe = safe.substring(0, 120);
    return safe.isEmpty ? 'file' : safe;
  }

  static bool _isSensitiveName(String name) {
    final lower = name.toLowerCase();
    if (lower == '.env' ||
        lower.endsWith('.env') ||
        lower.startsWith('.env.') ||
        _sensitiveBasenames.contains(lower)) {
      return true;
    }
    return _sensitiveExtensions.any(lower.endsWith);
  }

  static bool _isSensitivePath(String path) {
    final components = _decodedPathComponents(path);
    if (components == null || components.isEmpty) return true;
    final lower = components
        .map((component) => component.toLowerCase())
        .toList();
    if (path.startsWith('/') &&
        const {'proc', 'sys', 'dev'}.contains(lower.first)) {
      return true;
    }
    if (_isSensitiveName(lower.last)) return true;

    for (var index = 0; index < lower.length; index++) {
      final component = lower[index];
      if (component == '.config' &&
          index + 1 < lower.length &&
          lower[index + 1] == 'gcloud') {
        return true;
      }
      if (!_sensitiveDirectoryNames.contains(component)) continue;
      final isAllowedSshPublicFile = component == '.ssh' &&
          index == lower.length - 2 &&
          !lower.last.startsWith('.') &&
          (lower.last == 'known_hosts' || lower.last.endsWith('.pub'));
      if (!isAllowedSshPublicFile) return true;
    }
    return false;
  }

  static List<String>? _decodedPathComponents(String path) {
    final components = <String>[];
    for (final raw in path.replaceAll('\\', '/').split('/')) {
      if (raw.isEmpty) continue;
      try {
        final decoded = Uri.decodeComponent(raw);
        if (decoded.isEmpty ||
            decoded.contains('/') ||
            decoded.contains('\\')) {
          return null;
        }
        components.add(decoded);
      } on FormatException {
        return null;
      }
    }
    return components;
  }

  static bool _isExecutableOrInstaller(String name, {String? mimeType}) {
    if (mimeType?.toLowerCase() ==
        'application/vnd.android.package-archive') {
      return true;
    }
    final lower = _decodedBasename(name).toLowerCase();
    return _executableExtensions.any(lower.endsWith);
  }

  static String _mimeType(String name, GeneratedMediaKind kind) {
    final lower = name.toLowerCase();
    if (kind == GeneratedMediaKind.image) {
      if (lower.endsWith('.png')) return 'image/png';
      if (lower.endsWith('.gif')) return 'image/gif';
      if (lower.endsWith('.webp')) return 'image/webp';
      if (lower.endsWith('.bmp')) return 'image/bmp';
      if (lower.endsWith('.tiff')) return 'image/tiff';
      return 'image/jpeg';
    }
    if (kind == GeneratedMediaKind.video) {
      if (lower.endsWith('.webm')) return 'video/webm';
      if (lower.endsWith('.mov')) return 'video/quicktime';
      if (lower.endsWith('.avi')) return 'video/x-msvideo';
      if (lower.endsWith('.mkv')) return 'video/x-matroska';
      if (lower.endsWith('.3gp')) return 'video/3gpp';
      return 'video/mp4';
    }
    if (kind == GeneratedMediaKind.audio) {
      if (lower.endsWith('.wav')) return 'audio/wav';
      if (lower.endsWith('.ogg') || lower.endsWith('.opus')) return 'audio/ogg';
      if (lower.endsWith('.m4a') || lower.endsWith('.m2a')) return 'audio/mp4';
      if (lower.endsWith('.flac')) return 'audio/flac';
      return 'audio/mpeg';
    }
    final dot = lower.lastIndexOf('.');
    final extension = dot < 0 ? '' : lower.substring(dot);
    if (!_knownFileExtensions.contains(extension)) {
      return 'application/octet-stream';
    }
    return switch (extension) {
      '.pdf' => 'application/pdf',
      '.txt' || '.md' || '.csv' || '.tsv' => 'text/plain',
      '.json' || '.geojson' => 'application/json',
      '.xml' => 'application/xml',
      '.yaml' || '.yml' => 'application/yaml',
      '.svg' => 'image/svg+xml',
      '.html' || '.htm' => 'text/html',
      '.zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }

  static bool _isSafeServerPath(String source) {
    if (source.length > 2048 ||
        !source.startsWith('/') ||
        source.startsWith('//') ||
        source.contains('\\') ||
        source.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        source.contains('?') ||
        source.contains('#')) {
      return false;
    }
    for (final raw in source.split('/').skip(1)) {
      if (raw.isEmpty || raw == '.' || raw == '..') return false;
      String decoded;
      try {
        decoded = Uri.decodeComponent(raw);
      } on FormatException {
        return false;
      }
      if (decoded.isEmpty ||
          decoded == '.' ||
          decoded == '..' ||
          decoded.contains('/') ||
          decoded.contains('\\') ||
          decoded.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        return false;
      }
    }
    return !_isSensitivePath(source);
  }

  /// Text suitable for copy, read-aloud and notification previews: prose is
  /// preserved while server-local paths and signed media URLs stay private.
  static String stripDirectives(String content) => parseSegments(content)
      .whereType<GeneratedMediaTextSegment>()
      .map((segment) => segment.text)
      .join();

  static Future<File> ensureDownloaded(
    String connectionId,
    GeneratedMediaReference reference, {
    Future<Uint8List> Function(String path)? fetchServerPath,
    Future<void> Function(String path, File destination)? fetchServerPathToFile,
    GeneratedMediaStreamingFetcher? fetchServerPathToFileWithProgress,
    GeneratedMediaProgress? onProgress,
    bool Function()? isCancelled,
    Directory? baseDir,
  }) {
    if (reference.sourceKind == GeneratedMediaSourceKind.serverPath &&
        fetchServerPath == null &&
        fetchServerPathToFile == null &&
        fetchServerPathToFileWithProgress == null) {
      throw ArgumentError('A server-path fetcher is required');
    }
    final key =
        '${baseDir?.path ?? 'app'}\u0000$connectionId\u0000${reference.source}';
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = _ensureDownloaded(
      connectionId,
      reference,
      fetchServerPath: fetchServerPath,
      fetchServerPathToFile: fetchServerPathToFile,
      fetchServerPathToFileWithProgress: fetchServerPathToFileWithProgress,
      onProgress: onProgress,
      isCancelled: isCancelled,
      baseDir: baseDir,
    );
    _inFlight[key] = future;
    unawaited(
      future.then<void>(
        (_) {
          _inFlight.remove(key);
        },
        onError: (Object _, StackTrace _) {
          _inFlight.remove(key);
        },
      ),
    );
    return future;
  }

  static Future<File> _ensureDownloaded(
    String connectionId,
    GeneratedMediaReference reference, {
    Future<Uint8List> Function(String path)? fetchServerPath,
    Future<void> Function(String path, File destination)? fetchServerPathToFile,
    GeneratedMediaStreamingFetcher? fetchServerPathToFileWithProgress,
    GeneratedMediaProgress? onProgress,
    bool Function()? isCancelled,
    Directory? baseDir,
  }) async {
    if (isCancelled?.call() ?? false) {
      throw const GeneratedMediaDownloadCancelled();
    }
    final root = baseDir ?? await getApplicationSupportDirectory();
    final connectionHash = sha256.convert(utf8.encode(connectionId)).toString();
    final cacheIdentity = [
      reference.source,
      reference.sizeBytes?.toString() ?? '',
      reference.modifiedAt?.toUtc().microsecondsSinceEpoch.toString() ?? '',
    ].join('\u0000');
    final sourceHash = sha256.convert(utf8.encode(cacheIdentity)).toString();
    final suffix = _extensionFor(reference.displayName, reference.kind);
    final directory = Directory('${root.path}/generated_media/$connectionHash');
    await directory.create(recursive: true);
    final target = File('${directory.path}/$sourceHash$suffix');

    if (await target.exists()) {
      try {
        final length = await target.length();
        if (length > 0 && length <= _maxBytes(reference.kind)) {
          final probe = await _readPrefix(target, 32);
          if (validateBytes(probe, reference.kind)) {
            if (isCancelled?.call() ?? false) {
              throw const GeneratedMediaDownloadCancelled();
            }
            onProgress?.call(length, length);
            await target.setLastModified(DateTime.now());
            return target;
          }
        }
      } catch (_) {
        // A concurrent prune may have removed the cache entry. Re-download.
      }
      if (await target.exists()) {
        await target.delete().catchError((_) => target);
      }
    }

    final temporary = File(
      '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      if (reference.sourceKind == GeneratedMediaSourceKind.serverPath &&
          fetchServerPathToFileWithProgress != null) {
        await fetchServerPathToFileWithProgress(
          reference.source,
          temporary,
          onProgress ?? (_, _) {},
          isCancelled ?? () => false,
        );
      } else if (reference.sourceKind == GeneratedMediaSourceKind.serverPath &&
          fetchServerPathToFile != null) {
        await fetchServerPathToFile(reference.source, temporary);
      } else if (reference.sourceKind == GeneratedMediaSourceKind.serverPath) {
        final bytes = await fetchServerPath!(reference.source);
        if (bytes.isEmpty || bytes.length > _maxBytes(reference.kind)) {
          throw const FormatException('generated media exceeds its size limit');
        }
        if (isCancelled?.call() ?? false) {
          throw const GeneratedMediaDownloadCancelled();
        }
        await temporary.writeAsBytes(bytes, flush: true);
        onProgress?.call(bytes.length, bytes.length);
      } else {
        await _downloadHttpsToFile(
          reference.source,
          reference.kind,
          temporary,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      }

      if (isCancelled?.call() ?? false) {
        throw const GeneratedMediaDownloadCancelled();
      }
      final length = await temporary.length();
      if (length <= 0 || length > _maxBytes(reference.kind)) {
        throw const FormatException('generated media exceeds its size limit');
      }
      final probe = await _readPrefix(temporary, 32);
      if (!validateBytes(probe, reference.kind)) {
        throw const FormatException('generated media signature is invalid');
      }
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete().catchError((_) => temporary);
      }
    }
    await _pruneCache(Directory('${root.path}/generated_media'));
    return target;
  }

  static int _maxBytes(GeneratedMediaKind kind) => switch (kind) {
    GeneratedMediaKind.image => maxImageBytes,
    GeneratedMediaKind.video => maxVideoBytes,
    GeneratedMediaKind.audio || GeneratedMediaKind.file => maxFileBytes,
  };

  static String _extensionFor(String name, GeneratedMediaKind kind) {
    final dot = name.lastIndexOf('.');
    if (dot >= 0) {
      final extension = name.substring(dot).toLowerCase();
      final allowed = switch (kind) {
        GeneratedMediaKind.image => _imageExtensions,
        GeneratedMediaKind.video => _videoExtensions,
        GeneratedMediaKind.audio => _audioExtensions,
        GeneratedMediaKind.file => _knownFileExtensions,
      };
      if (allowed.contains(extension) ||
          (kind == GeneratedMediaKind.file &&
              RegExp(r'^\.[a-z0-9]{1,16}$').hasMatch(extension))) {
        return extension;
      }
    }
    return switch (kind) {
      GeneratedMediaKind.image => '.img',
      GeneratedMediaKind.video => '.video',
      GeneratedMediaKind.audio => '.audio',
      GeneratedMediaKind.file => '.file',
    };
  }

  static Future<Uint8List> _readPrefix(File file, int count) async {
    final handle = await file.open();
    try {
      return Uint8List.fromList(await handle.read(count));
    } finally {
      await handle.close();
    }
  }

  static bool validateBytes(Uint8List bytes, GeneratedMediaKind kind) {
    if (kind == GeneratedMediaKind.image) {
      if (bytes.length >= 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4e &&
          bytes[3] == 0x47 &&
          bytes[4] == 0x0d &&
          bytes[5] == 0x0a &&
          bytes[6] == 0x1a &&
          bytes[7] == 0x0a) {
        return true;
      }
      if (bytes.length >= 3 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff) {
        return true;
      }
      if (bytes.length >= 6) {
        final signature = String.fromCharCodes(bytes.sublist(0, 6));
        if (signature == 'GIF87a' || signature == 'GIF89a') return true;
      }
      if (bytes.length >= 12 &&
          String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
          String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
        return true;
      }
      if (bytes.length >= 4) {
        final signature = bytes.sublist(0, 4);
        if ((signature[0] == 0x49 &&
                signature[1] == 0x49 &&
                signature[2] == 0x2a &&
                signature[3] == 0x00) ||
            (signature[0] == 0x4d &&
                signature[1] == 0x4d &&
                signature[2] == 0x00 &&
                signature[3] == 0x2a)) {
          return true;
        }
      }
      return bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d;
    }

    if (kind == GeneratedMediaKind.file) return bytes.isNotEmpty;
    if (kind == GeneratedMediaKind.audio) {
      if (bytes.length >= 3 &&
          String.fromCharCodes(bytes.sublist(0, 3)) == 'ID3') {
        return true;
      }
      if (bytes.length >= 2 &&
          bytes[0] == 0xff &&
          (bytes[1] & 0xe0) == 0xe0) {
        return true;
      }
      if (bytes.length >= 4) {
        final signature = String.fromCharCodes(bytes.sublist(0, 4));
        if (signature == 'OggS' || signature == 'fLaC') return true;
      }
      if (bytes.length >= 12 &&
          String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
          String.fromCharCodes(bytes.sublist(8, 12)) == 'WAVE') {
        return true;
      }
      return bytes.length >= 12 &&
          String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp';
    }

    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
      return true;
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x1a &&
        bytes[1] == 0x45 &&
        bytes[2] == 0xdf &&
        bytes[3] == 0xa3) {
      return true;
    }
    return bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'AVI ';
  }

  static Future<void> _downloadHttpsToFile(
    String source,
    GeneratedMediaKind kind,
    File target, {
    GeneratedMediaProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    var uri = Uri.parse(source);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      for (var redirect = 0; redirect <= _maxRedirects; redirect++) {
        if (isCancelled?.call() ?? false) {
          throw const GeneratedMediaDownloadCancelled();
        }
        if (uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const FormatException(
            'only credential-free HTTPS media is supported',
          );
        }
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 20));
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await _cancelHttpResponse(response);
          if (location == null || redirect == _maxRedirects) {
            throw const HttpException('invalid media redirect');
          }
          final next = uri.resolve(location);
          if (next.scheme != 'https' || next.origin != uri.origin) {
            throw const HttpException('cross-origin media redirect rejected');
          }
          uri = next;
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await _cancelHttpResponse(response);
          throw HttpException('media download failed (${response.statusCode})');
        }
        final maxBytes = _maxBytes(kind);
        final declared = response.contentLength;
        final total = declared >= 0 ? declared : null;
        if (declared > maxBytes) {
          await _cancelHttpResponse(response);
          throw const HttpException('generated media is too large');
        }

        final sink = target.openWrite(mode: FileMode.writeOnly);
        var received = 0;
        try {
          await for (final chunk in response.timeout(
            const Duration(minutes: 2),
          )) {
            if (isCancelled?.call() ?? false) {
              throw const GeneratedMediaDownloadCancelled();
            }
            received += chunk.length;
            if (received > maxBytes) {
              throw const HttpException('generated media is too large');
            }
            sink.add(chunk);
            onProgress?.call(received, total);
            if (isCancelled?.call() ?? false) {
              throw const GeneratedMediaDownloadCancelled();
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (received <= 0) {
          throw const HttpException('generated media is empty');
        }
        if (total != null && received != total) {
          throw const HttpException('generated media download was incomplete');
        }
        return;
      }
      throw const HttpException('too many media redirects');
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _cancelHttpResponse(HttpClientResponse response) async {
    final subscription = response.listen((_) {});
    await subscription.cancel();
  }

  static Future<void> _pruneCache(Directory root) async {
    if (!await root.exists()) return;
    final files = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && !entity.path.contains('.tmp-')) files.add(entity);
    }
    var total = 0;
    final entries = <({File file, int bytes, DateTime modified})>[];
    for (final file in files) {
      try {
        final stat = await file.stat();
        total += stat.size;
        entries.add((file: file, bytes: stat.size, modified: stat.modified));
      } catch (_) {
        // A concurrent cleanup may already have removed it.
      }
    }
    if (total <= _maxCacheBytes) return;
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in entries) {
      if (total <= _maxCacheBytes) break;
      try {
        await entry.file.delete();
        total -= entry.bytes;
      } catch (_) {
        // Best effort cache maintenance.
      }
    }
  }
}
