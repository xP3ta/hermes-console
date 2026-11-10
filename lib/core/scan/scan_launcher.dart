import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import 'document_scan_screen.dart';

/// Opens the document scanner and returns what it produced as temporary
/// files (one PNG per page, or one PDF), ready to go through the same path as
/// a picked photo. The caller deletes the files it does not keep. Empty when
/// the user leaves without exporting.
Future<List<XFile>> openDocumentScanner(
  BuildContext context, {
  required int maxPages,
}) async {
  final result = await Navigator.of(context).push<ScanResult>(
    MaterialPageRoute<ScanResult>(
      builder: (_) => DocumentScanScreen(maxPages: maxPages),
    ),
  );
  if (result == null || result.files.isEmpty) return const [];
  final files = <XFile>[];
  for (final scanned in result.files) {
    final file = File(
      '${Directory.systemTemp.path}/hermes-scan-${const Uuid().v4()}-'
      '${scanned.name}',
    );
    await file.writeAsBytes(scanned.bytes, flush: true);
    files.add(XFile(file.path, name: scanned.name, mimeType: scanned.mimeType));
  }
  return files;
}
