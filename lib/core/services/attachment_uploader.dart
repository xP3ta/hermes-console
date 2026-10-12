import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/attachment_draft.dart';
import 'connection_manager.dart';

enum PendingAttachmentLimitViolation { invalid, item, batch }

/// Clasifica el motivo exacto por el que una selección no cabe en el composer
/// (chat y salas comparten los mismos límites).
///
/// Los límites son inclusivos: 8 MiB por elemento y 24 MiB por lote siguen
/// siendo válidos. Mantener esta decisión pura evita mostrar el límite de un
/// fichero cuando el problema real es la suma del lote.
PendingAttachmentLimitViolation? pendingAttachmentLimitViolation({
  required int sizeBytes,
  required int itemLimit,
  required int currentBatchBytes,
}) {
  if (sizeBytes <= 0) return PendingAttachmentLimitViolation.invalid;
  if (sizeBytes > itemLimit) return PendingAttachmentLimitViolation.item;
  if (currentBatchBytes + sizeBytes > AttachmentUploader.maxBatchBytes) {
    return PendingAttachmentLimitViolation.batch;
  }
  return null;
}

/// Resultado de subir un adjunto al filesystem gestionado del agente.
class AttachmentUploadResult {
  final bool ok;

  /// Ruta gestionada donde quedó el archivo (la que verá el agente).
  final String? managedPath;
  final AttachmentErrorKind? errorKind;

  const AttachmentUploadResult.success(this.managedPath)
    : ok = true,
      errorKind = null;
  const AttachmentUploadResult.failure(this.errorKind)
    : ok = false,
      managedPath = null;
}

/// Referencia opaca y versionada a una copia privada conservada para el
/// historial. El marcador nunca contiene una ruta absoluta: [storageKey] solo
/// puede resolverse dentro de `app-support/sent_attachments` y [sha256Hex]
/// permite detectar manipulación o corrupción antes de abrir los bytes.
@immutable
class AttachmentHistoryReference {
  static const String markerPrefix = '⟦hatt:v1:';
  static const String markerSuffix = '⟧';
  static const int _maxMarkerLineCharacters = 1040;
  static const int _maxMarkerPayloadCharacters = 1024;

  final int index;
  final String storageKey;
  final AttachmentType type;
  final String mimeType;
  final int sizeBytes;
  final String sha256Hex;

  const AttachmentHistoryReference({
    required this.index,
    required this.storageKey,
    required this.type,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256Hex,
  });

  String toMarker() {
    final payload = base64UrlEncode(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'i': index,
          'k': storageKey,
          't': type.name,
          'm': mimeType,
          's': sizeBytes,
          'h': sha256Hex,
        }),
      ),
    ).replaceAll('=', '');
    return '$markerPrefix$payload$markerSuffix';
  }

  static AttachmentHistoryReference? tryParseMarker(String line) {
    if (line.length > _maxMarkerLineCharacters) return null;
    final trimmed = line.trim();
    if (trimmed.length > _maxMarkerLineCharacters) return null;
    if (!trimmed.startsWith(markerPrefix) || !trimmed.endsWith(markerSuffix)) {
      return null;
    }
    final encoded = trimmed.substring(
      markerPrefix.length,
      trimmed.length - markerSuffix.length,
    );
    if (encoded.isEmpty ||
        encoded.length > _maxMarkerPayloadCharacters ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
      return null;
    }
    try {
      final padded = encoded.padRight(
        encoded.length + ((4 - encoded.length % 4) % 4),
        '=',
      );
      final decoded = jsonDecode(utf8.decode(base64Url.decode(padded)));
      if (decoded is! Map) return null;
      final data = Map<String, dynamic>.from(decoded);
      final version = (data['v'] as num?)?.toInt();
      final index = (data['i'] as num?)?.toInt();
      final storageKey = (data['k'] ?? '').toString();
      final rawType = (data['t'] ?? '').toString();
      final mimeType = (data['m'] ?? '').toString();
      final sizeBytes = (data['s'] as num?)?.toInt();
      final sha256Hex = (data['h'] ?? '').toString();
      final safeDigest = RegExp(r'^[a-f0-9]{64}$');
      if (version != 1 ||
          index == null ||
          index < 0 ||
          index > 99 ||
          !safeDigest.hasMatch(storageKey) ||
          !safeDigest.hasMatch(sha256Hex) ||
          storageKey != sha256Hex ||
          sizeBytes == null ||
          sizeBytes <= 0 ||
          sizeBytes > AttachmentUploader.maxBytes ||
          mimeType.length > 160 ||
          mimeType.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
        return null;
      }
      final type = AttachmentType.values.where(
        (value) => value.name == rawType,
      );
      if (type.isEmpty) return null;
      return AttachmentHistoryReference(
        index: index,
        storageKey: storageKey,
        type: type.first,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        sha256Hex: sha256Hex,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Sube adjuntos al agente vía la API de archivos del Dashboard
/// (`POST /api/files/upload`, base64 data URL). El agente puede luego leer el
/// archivo con sus herramientas referenciando la ruta devuelta.
///
/// Es una operación que ESCRIBE en el filesystem del agente: el llamador debe
/// haber pasado ya por el gate de aprobación y respetar el modo solo-lectura.
class AttachmentUploader {
  // El home del agente y la carpeta de uploads no cambian entre fotos de la
  // misma instancia. Evita dos round-trips redundantes en cada envío posterior.
  static final Map<String, String> _uploadDirs = <String, String>{};

  @visibleForTesting
  static void clearUploadDirectoryCacheForTesting() => _uploadDirs.clear();

  /// Límite conservador para no llenar el disco del agente ni reventar el
  /// timeout HTTP con base64 enorme.
  static const int maxBytes = 8 * 1024 * 1024;
  static const int maxBatchBytes = 24 * 1024 * 1024;
  static const int maxSentImageCacheBytes = 100 * 1024 * 1024;
  static const Duration maxSentImageCacheAge = Duration(days: 30);
  static const int maxSentAttachmentCacheBytes = 100 * 1024 * 1024;
  static const Duration maxSentAttachmentCacheAge = Duration(days: 30);
  static const String sentAttachmentDirectoryName = 'sent_attachments';

  /// Tipos permitidos (allowlist). Vacío de mime => se evalúa por extensión en
  /// [AttachmentDraft]; aquí solo cortamos ejecutables obvios.
  static const Set<String> _blockedExtensions = {
    'apk',
    'exe',
    'sh',
    'bat',
    'bin',
    'so',
    'dll',
    'msi',
    'deb',
  };

  /// Límite para incrustar texto directamente en el mensaje (evita prompts
  /// gigantes).
  static const int maxTextBytes = 256 * 1024;

  /// Materializa cualquier fichero del picker en app-support antes de guardar
  /// el draft. Cada [AttachmentDraft.localId] posee una copia independiente:
  /// retirarla nunca borra el fichero de otro chip o una ruta externa.
  ///
  /// [itemLimit] replaces the per-kind cap for surfaces that always upload
  /// (rooms): there a text file is never embedded, so the 256 KB inline-text
  /// cap does not apply.
  static Future<AttachmentDraft?> materializeForDraft(
    AttachmentDraft attachment, {
    Directory? baseDir,
    int? itemLimit,
  }) async {
    if (attachment.localId.isEmpty || attachment.localPath.isEmpty) return null;
    final source = File(attachment.localPath);
    if (!await source.exists()) return null;
    try {
      final length = await source.length();
      final limit =
          itemLimit ?? (isTextEmbeddable(attachment) ? maxTextBytes : maxBytes);
      if (length <= 0 || length > limit) return null;
      final base = baseDir ?? await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/attachment_drafts');
      if (!await dir.exists()) await dir.create(recursive: true);
      await _deleteStaleDraftPartials(dir);
      final safeId = attachment.localId.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '_',
      );
      if (safeId.isEmpty) return null;
      final safeName = attachment.name.replaceAll(
        RegExp(r'[^A-Za-z0-9._-]'),
        '_',
      );
      final destination = File(
        '${dir.path}/${safeId}_${safeName.isEmpty ? 'attachment' : safeName}',
      );
      final sourceDigest = await sha256.bind(source.openRead()).first;
      final destinationMatches =
          await destination.exists() &&
          await destination.length() == length &&
          await sha256.bind(destination.openRead()).first == sourceDigest;
      if (!destinationMatches) {
        final unique = DateTime.now().microsecondsSinceEpoch;
        final partial = File('${destination.path}.part.$unique');
        try {
          await source.openRead().pipe(
            partial.openWrite(mode: FileMode.writeOnly),
          );
          try {
            await partial.rename(destination.path);
          } on FileSystemException {
            if (await destination.exists()) await destination.delete();
            await partial.rename(destination.path);
          }
        } on FileSystemException {
          if (!await destination.exists() ||
              await destination.length() != length ||
              await sha256.bind(destination.openRead()).first != sourceDigest) {
            rethrow;
          }
        } finally {
          if (await partial.exists()) await partial.delete();
        }
      }
      final persistedLength = await destination.length();
      if (persistedLength != length) return null;
      return attachment.copyWith(
        localPath: destination.path,
        sizeBytes: persistedLength,
      );
    } catch (error) {
      debugPrint(
        '[attachment] private materialization failed (${error.runtimeType})',
      );
      return null;
    }
  }

  /// Borra únicamente una copia que coincide con el directorio privado y el
  /// owner [AttachmentDraft.localId]. Rutas legacy/externas fallan cerrado.
  static Future<bool> deletePrivateDraftCopy(
    AttachmentDraft attachment, {
    Directory? baseDir,
  }) async {
    if (attachment.localId.isEmpty || attachment.localPath.isEmpty) {
      return false;
    }
    try {
      final base = baseDir ?? await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/attachment_drafts');
      final file = File(attachment.localPath);
      if (!await dir.exists() || !await file.exists()) return false;
      final canonicalDir = await dir.resolveSymbolicLinks();
      final canonicalFile = await file.resolveSymbolicLinks();
      final prefix = '$canonicalDir${Platform.pathSeparator}';
      final safeId = attachment.localId.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '_',
      );
      final separator = canonicalFile.lastIndexOf(Platform.pathSeparator);
      final name = canonicalFile.substring(separator + 1);
      if (!canonicalFile.startsWith(prefix) || !name.startsWith('${safeId}_')) {
        return false;
      }
      await file.delete();
      return true;
    } catch (error) {
      debugPrint('[attachment] private cleanup failed (${error.runtimeType})');
      return false;
    }
  }

  static Future<void> _deleteStaleDraftPartials(Directory dir) async {
    final now = DateTime.now();
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.contains('.part.')) continue;
      try {
        final stat = await entity.stat();
        if (now.difference(stat.modified) > const Duration(hours: 1)) {
          await entity.delete();
        }
      } catch (_) {}
    }
  }

  /// Revalida el lote justo antes de enviarlo. No confía en el tamaño guardado
  /// por el picker ni en un borrador restaurado: el archivo pudo cambiar entre
  /// selección y envío.
  static Future<bool> validateBatch(List<AttachmentDraft> attachments) async {
    var total = 0;
    for (final attachment in attachments) {
      if (_hasBlockedExtension(attachment.name)) return false;
      if (attachment.localPath.isEmpty) return false;
      final file = File(attachment.localPath);
      if (!await file.exists()) return false;
      late final int length;
      try {
        length = await file.length();
      } catch (_) {
        return false;
      }
      final limit = isTextEmbeddable(attachment) ? maxTextBytes : maxBytes;
      if (length <= 0 || length > limit) return false;
      total += length;
      if (total > maxBatchBytes) return false;
      if (attachment.isImage && !await _hasSupportedImageMagic(file)) {
        return false;
      }
    }
    return true;
  }

  static bool _hasBlockedExtension(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return _blockedExtensions.contains(ext);
  }

  /// Mantiene el selector amplio sin permitir que un ejecutable obvio llegue
  /// a materializarse como borrador. La misma frontera se revalida al enviar.
  static bool isAllowedDocumentName(String name) => !_hasBlockedExtension(name);

  static Future<bool> _hasSupportedImageMagic(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final bytes = await handle.read(16);
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
      if (bytes.length >= 6 &&
          bytes[0] == 0x47 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x38 &&
          (bytes[4] == 0x37 || bytes[4] == 0x39) &&
          bytes[5] == 0x61) {
        return true;
      }
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50) {
        return true;
      }
      // HEIF/HEIC/AVIF usan contenedor ISO-BMFF (`ftyp`). El decoder final del
      // servidor decidirá la marca concreta; aquí solo impedimos texto/HTML o
      // ejecutables renombrados como imagen.
      return bytes.length >= 12 &&
          bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70;
    } catch (_) {
      return false;
    } finally {
      await handle?.close();
    }
  }

  static const Set<String> _textExt = {
    'txt',
    'md',
    'markdown',
    'csv',
    'tsv',
    'json',
    'yaml',
    'yml',
    'xml',
    'log',
    'ini',
    'cfg',
    'conf',
    'toml',
    'env',
    'sh',
    'bash',
    'py',
    'dart',
    'js',
    'ts',
    'java',
    'c',
    'cpp',
    'h',
    'hpp',
    'go',
    'rs',
    'rb',
    'php',
    'html',
    'css',
    'sql',
    'kt',
    'swift',
    'gradle',
    'properties',
  };

  /// ¿Es un archivo de texto que podemos incrustar directamente (sin depender
  /// de librerías del servidor para leerlo)?
  static bool isTextEmbeddable(AttachmentDraft a) {
    if (a.isImage) return false;
    final ext = a.name.contains('.')
        ? a.name.split('.').last.toLowerCase()
        : '';
    if (_textExt.contains(ext)) return true;
    return a.mimeType.toLowerCase().startsWith('text/');
  }

  /// Lenguaje sugerido para el bloque de código del contenido incrustado.
  static String langHint(AttachmentDraft a) {
    final ext = a.name.contains('.')
        ? a.name.split('.').last.toLowerCase()
        : '';
    const map = {
      'py': 'python',
      'js': 'javascript',
      'ts': 'typescript',
      'md': 'markdown',
      'yml': 'yaml',
      'sh': 'bash',
      'rb': 'ruby',
      'rs': 'rust',
      'kt': 'kotlin',
    };
    return map[ext] ?? ext;
  }

  /// Lee el contenido de un archivo de texto. Devuelve null si no existe, es
  /// demasiado grande o no se puede decodificar.
  static Future<String?> readTextContent(AttachmentDraft a) async {
    if (a.localPath.isEmpty) return null;
    final f = File(a.localPath);
    if (!await f.exists()) return null;
    if (await f.length() > maxTextBytes) return null;
    try {
      return await f.readAsString();
    } catch (error) {
      debugPrint('[attachment] text read failed (${error.runtimeType})');
      return null;
    }
  }

  /// Copia una imagen adjunta a un directorio persistente de la app, para poder
  /// mostrar su miniatura real en el historial del chat aunque el sistema limpie
  /// la caché del selector (image_picker copia a un temporal volátil). Devuelve
  /// la ruta persistente, o null si no es imagen o falla la copia.
  static Future<String?> persistImageLocally(
    AttachmentDraft a, {
    Directory? baseDir,
  }) async {
    if (!a.isImage || a.localPath.isEmpty) return null;
    final src = File(a.localPath);
    if (!await src.exists()) return null;
    try {
      final base = baseDir ?? await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/sent_images');
      if (!await dir.exists()) await dir.create(recursive: true);
      final safe = a.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final digest = (await sha256.bind(src.openRead()).first).toString();
      final dest = File('${dir.path}/${digest}_$safe');
      if (await dest.exists()) {
        await _evictSentImages(dir, keep: dest.path);
        return dest.path;
      }
      final unique = DateTime.now().microsecondsSinceEpoch;
      final partial = File('${dest.path}.part.$unique');
      try {
        await src.openRead().pipe(partial.openWrite(mode: FileMode.writeOnly));
        try {
          await partial.rename(dest.path);
        } on FileSystemException {
          // Otra selección concurrente pudo materializar el mismo hash.
          if (!await dest.exists()) rethrow;
        }
      } finally {
        if (await partial.exists()) await partial.delete();
      }
      await _evictSentImages(dir, keep: dest.path);
      return dest.path;
    } catch (error) {
      debugPrint(
        '[attachment] sent image persistence failed (${error.runtimeType})',
      );
      return null;
    }
  }

  /// Conserva una copia privada, atómica y acotada de cualquier adjunto que va
  /// a formar parte del historial. La identidad del fichero es su SHA-256; el
  /// nombre original y la ruta del picker nunca forman parte del path durable.
  static Future<AttachmentHistoryReference?> persistForHistory(
    AttachmentDraft attachment, {
    required int index,
    Directory? baseDir,
  }) async {
    if (index < 0 || index > 99 || attachment.localPath.isEmpty) return null;
    if (_hasBlockedExtension(attachment.name)) return null;
    final source = File(attachment.localPath);
    if (!await source.exists()) return null;
    try {
      final length = await source.length();
      final limit = isTextEmbeddable(attachment) ? maxTextBytes : maxBytes;
      if (length <= 0 || length > limit) return null;
      if (attachment.isImage && !await _hasSupportedImageMagic(source)) {
        return null;
      }
      final digest = (await sha256.bind(source.openRead()).first).toString();
      final base = baseDir ?? await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/$sentAttachmentDirectoryName');
      if (await dir.exists()) {
        if (await FileSystemEntity.type(dir.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          return null;
        }
      } else {
        await dir.create(recursive: true);
      }
      final destination = File('${dir.path}/$digest');
      final destinationMatches =
          await destination.exists() &&
          await FileSystemEntity.type(destination.path, followLinks: false) ==
              FileSystemEntityType.file &&
          await destination.length() == length &&
          (await sha256.bind(destination.openRead()).first).toString() ==
              digest;
      if (destinationMatches) {
        await destination.setLastModified(DateTime.now());
      } else {
        final partial = File(
          '${destination.path}.part.${DateTime.now().microsecondsSinceEpoch}',
        );
        try {
          await source.openRead().pipe(
            partial.openWrite(mode: FileMode.writeOnly),
          );
          try {
            await partial.rename(destination.path);
          } on FileSystemException {
            final concurrentMatch =
                await destination.exists() &&
                await FileSystemEntity.type(
                      destination.path,
                      followLinks: false,
                    ) ==
                    FileSystemEntityType.file &&
                await destination.length() == length &&
                (await sha256.bind(destination.openRead()).first).toString() ==
                    digest;
            if (!concurrentMatch) {
              if (await destination.exists()) await destination.delete();
              await partial.rename(destination.path);
            }
          }
        } finally {
          if (await partial.exists()) await partial.delete();
        }
      }
      final normalizedMimeType = attachment.mimeType.replaceAll(
        RegExp(r'[\u0000-\u001f\u007f]'),
        '',
      );
      final safeMimeType = normalizedMimeType.length <= 160
          ? normalizedMimeType
          : normalizedMimeType.substring(0, 160);
      final reference = AttachmentHistoryReference(
        index: index,
        storageKey: digest,
        type: attachment.type,
        mimeType: safeMimeType,
        sizeBytes: length,
        sha256Hex: digest,
      );
      await _evictSentAttachments(dir, keep: destination.path);
      return reference;
    } catch (error) {
      debugPrint(
        '[attachment] history persistence failed (${error.runtimeType})',
      );
      return null;
    }
  }

  /// Resuelve una referencia únicamente dentro del almacén privado y revalida
  /// tipo de entidad, tamaño y SHA-256. Traversal, symlinks y marcadores
  /// manipulados fallan cerrado.
  static Future<File?> resolveHistoryReference(
    AttachmentHistoryReference reference, {
    Directory? baseDir,
  }) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(reference.storageKey) ||
        reference.storageKey != reference.sha256Hex) {
      return null;
    }
    try {
      final base = baseDir ?? await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/$sentAttachmentDirectoryName');
      final candidate = File('${dir.path}/${reference.storageKey}');
      if (!await dir.exists() || !await candidate.exists()) return null;
      if (await FileSystemEntity.type(dir.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return null;
      }
      if (await FileSystemEntity.type(candidate.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final canonicalDir = await dir.resolveSymbolicLinks();
      final canonicalFile = await candidate.resolveSymbolicLinks();
      if (canonicalFile !=
          '$canonicalDir${Platform.pathSeparator}${reference.storageKey}') {
        return null;
      }
      final resolved = File(canonicalFile);
      if (await resolved.length() != reference.sizeBytes) return null;
      final digest = (await sha256.bind(resolved.openRead()).first).toString();
      return digest == reference.sha256Hex ? resolved : null;
    } catch (error) {
      debugPrint(
        '[attachment] history resolution failed (${error.runtimeType})',
      );
      return null;
    }
  }

  static Future<void> _evictSentAttachments(
    Directory dir, {
    required String keep,
  }) async {
    final now = DateTime.now();
    final files = <(File, FileStat)>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        if (entity.path.contains('.part.')) {
          if (now.difference(stat.modified) > const Duration(hours: 1)) {
            await entity.delete();
          }
          continue;
        }
        if (entity.path != keep &&
            now.difference(stat.modified) > maxSentAttachmentCacheAge) {
          await entity.delete();
        } else {
          files.add((entity, stat));
        }
      } catch (_) {}
    }
    files.sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
    var total = 0;
    for (final entry in files) {
      total += entry.$2.size;
      if (total <= maxSentAttachmentCacheBytes || entry.$1.path == keep) {
        continue;
      }
      try {
        await entry.$1.delete();
      } catch (_) {}
    }
  }

  static Future<void> _evictSentImages(
    Directory dir, {
    required String keep,
  }) async {
    final now = DateTime.now();
    final files = <(File, FileStat)>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        if (entity.path.contains('.part.')) {
          if (now.difference(stat.modified) > const Duration(hours: 1)) {
            await entity.delete();
          }
          continue;
        }
        if (entity.path != keep &&
            now.difference(stat.modified) > maxSentImageCacheAge) {
          await entity.delete();
        } else {
          files.add((entity, stat));
        }
      } catch (_) {}
    }
    files.sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
    var total = 0;
    for (final entry in files) {
      total += entry.$2.size;
      if (total <= maxSentImageCacheBytes || entry.$1.path == keep) continue;
      try {
        await entry.$1.delete();
      } catch (_) {}
    }
  }

  static Future<AttachmentUploadResult> upload(
    SavedConnection connection,
    AttachmentDraft attachment,
  ) async {
    if (attachment.localPath.isEmpty) {
      return const AttachmentUploadResult.failure(
        AttachmentErrorKind.missingFile,
      );
    }
    if (_hasBlockedExtension(attachment.name)) {
      return const AttachmentUploadResult.failure(
        AttachmentErrorKind.unsupportedType,
      );
    }
    final file = File(attachment.localPath);
    if (!await file.exists()) {
      return const AttachmentUploadResult.failure(
        AttachmentErrorKind.missingFile,
      );
    }
    final len = await file.length();
    if (len > maxBytes) {
      return const AttachmentUploadResult.failure(AttachmentErrorKind.tooLarge);
    }
    DashboardClient? dash;
    try {
      final bytes = await file.readAsBytes();
      final mime = attachment.mimeType.isNotEmpty
          ? attachment.mimeType
          : 'application/octet-stream';
      final dataUrl = 'data:$mime;base64,${base64Encode(bytes)}';
      final safeName = attachment.name.replaceAll(
        RegExp(r'[^A-Za-z0-9._-]'),
        '_',
      );
      dash = DashboardClient.lazy(connection);

      // La API exige ruta ABSOLUTA (400 "Path must be absolute"). Subimos bajo
      // hermes_home (lo informa /api/status, y el agente lo tiene en su fs), en
      // una subcarpeta dedicada que el agente puede leer con sus herramientas.
      final dir = await resolveUploadDirectory(dash);

      final ts = DateTime.now().millisecondsSinceEpoch;
      final absPath = '$dir/${ts}_$safeName';
      await dash.apiPost(
        'files/upload',
        body: {'path': absPath, 'data_url': dataUrl, 'overwrite': false},
      );
      return AttachmentUploadResult.success(absPath);
    } catch (_) {
      return const AttachmentUploadResult.failure(
        AttachmentErrorKind.transport,
      );
    } finally {
      dash?.close();
    }
  }

  /// Resolves the existing managed upload folder shared by attachments and
  /// profile imports. The folder is created best effort and cached per server.
  static Future<String> resolveUploadDirectory(DashboardClient dash) async {
    final cached = _uploadDirs[dash.baseUrl];
    if (cached != null) return cached;
    final base = await _agentBaseDir(dash);
    final dir = '$base/uploads';
    // Best-effort: crear la carpeta (ignora "ya existe"). Solo se intenta una
    // vez por Dashboard durante la vida del proceso.
    try {
      await dash.apiPost('files/mkdir', body: {'path': dir});
    } catch (e) {
      debugPrint('[attachment] excepción silenciada (se ignora sin más): $e');
    }
    _uploadDirs[dash.baseUrl] = dir;
    return dir;
  }

  /// Directorio base (absoluto) donde escribir. Usa `hermes_home` de
  /// /api/status; si no se puede, cae a /tmp (que el agente también ve).
  static Future<String> _agentBaseDir(DashboardClient dash) async {
    try {
      final status = await dash.apiGet('status');
      final home = (status['hermes_home'] ?? '').toString();
      if (home.startsWith('/')) return home;
    } catch (e) {
      debugPrint('[attachment] excepción silenciada (se ignora sin más): $e');
    }
    return '/tmp';
  }
}
