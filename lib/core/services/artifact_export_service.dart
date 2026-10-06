import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

enum ArtifactSaveResult { saved, cancelled }

final class ArtifactExportTooLarge implements Exception {
  final int maximumBytes;

  const ArtifactExportTooLarge(this.maximumBytes);

  @override
  String toString() => 'artifact_export_too_large';
}

abstract interface class ArtifactExportActions {
  Future<void> copyText(String content);

  Future<ArtifactSaveResult> saveText({
    required String fileName,
    required String content,
  });

  Future<void> shareText({
    required String fileName,
    required String mimeType,
    required String content,
  });

  Future<ArtifactSaveResult> saveBytes({
    required String fileName,
    required Uint8List bytes,
  });
}

/// Exportación iniciada explícitamente por el usuario. Nunca publica contenido
/// en segundo plano y usa únicamente el selector/Share Sheet de Android.
final class PlatformArtifactExportActions implements ArtifactExportActions {
  static const int maximumBytes = 25 * 1024 * 1024;

  const PlatformArtifactExportActions();

  @override
  Future<void> copyText(String content) =>
      Clipboard.setData(ClipboardData(text: content));

  @override
  Future<ArtifactSaveResult> saveText({
    required String fileName,
    required String content,
  }) => saveBytes(
    fileName: fileName,
    bytes: Uint8List.fromList(utf8.encode(content)),
  );

  @override
  Future<void> shareText({
    required String fileName,
    required String mimeType,
    required String content,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(content));
    _checkSize(bytes.length);
    final directory = await getTemporaryDirectory();
    final safeName = sanitizeFileName(fileName);
    final unique = DateTime.now().microsecondsSinceEpoch;
    final file = File('${directory.path}/artifact-$unique-$safeName');
    await file.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles([XFile(file.path, mimeType: mimeType)]);
  }

  @override
  Future<ArtifactSaveResult> saveBytes({
    required String fileName,
    required Uint8List bytes,
  }) async {
    _checkSize(bytes.length);
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Console',
      fileName: sanitizeFileName(fileName),
      bytes: bytes,
    );
    return path == null
        ? ArtifactSaveResult.cancelled
        : ArtifactSaveResult.saved;
  }

  static String sanitizeFileName(String value) {
    final basename = value.replaceAll('\\', '/').split('/').last;
    var safe = basename
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\.{2,}'), '.')
        .trim();
    safe = safe.replaceFirst(RegExp(r'^\.+'), '');
    if (safe.length > 120) safe = safe.substring(0, 120);
    return safe.isEmpty ? 'artifact.txt' : safe;
  }

  static void _checkSize(int size) {
    if (size <= 0 || size > maximumBytes) {
      throw const ArtifactExportTooLarge(maximumBytes);
    }
  }
}
