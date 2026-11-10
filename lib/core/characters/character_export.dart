import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Hands a PNG to the system share sheet. Injected in tests.
typedef CharacterSharer = Future<void> Function(Uint8List png, String name);

/// Side, in pixels, of the PNG of a character.
const int characterPngSide = 1024;

/// Renders the repaint boundary under [boundaryKey] as a square PNG of
/// [side] pixels, or null when it is not on screen.
///
/// The boundary must hold only the character (no handles, no background),
/// so the picture is the character on transparency.
Future<Uint8List?> captureCharacterPng(
  GlobalKey boundaryKey, {
  int side = characterPngSide,
}) async {
  final object = boundaryKey.currentContext?.findRenderObject();
  if (object is! RenderRepaintBoundary || !object.hasSize) return null;
  final logical = object.size.longestSide;
  if (logical <= 0) return null;
  final image = await object.toImage(pixelRatio: side / logical);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// A file name for [name]: letters, digits and dashes only.
String characterFileName(String name) {
  final clean = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return clean.isEmpty ? 'character' : clean;
}

/// Folder, inside the temporary directory, that holds the PNGs on their way
/// to the share sheet.
const String characterShareFolder = 'character_share';

int _shares = 0;

/// Writes [png] to a temporary file, opens the share sheet with it and
/// deletes the file when the sheet is done (or failed). [tempDirectory] and
/// [share] are injected in tests.
Future<void> shareCharacterPng(
  Uint8List png,
  String name, {
  Future<Directory> Function()? tempDirectory,
  Future<void> Function(XFile file)? share,
}) async {
  final root = await (tempDirectory ?? getTemporaryDirectory)();
  // One folder per share, so two near-simultaneous shares never overwrite
  // each other's file.
  final folder = Directory(
    '${root.path}/$characterShareFolder/'
    '${DateTime.now().microsecondsSinceEpoch}-${_shares++}',
  );
  try {
    await folder.create(recursive: true);
    final file = File('${folder.path}/${characterFileName(name)}.png');
    await file.writeAsBytes(png, flush: true);
    final xfile = XFile(file.path, mimeType: 'image/png');
    await (share ?? (f) => Share.shareXFiles([f]))(xfile);
  } finally {
    await _deleteQuietly(folder);
  }
}

/// Removes whatever [shareCharacterPng] left behind (a crash mid-share).
Future<void> clearCharacterShareFiles({
  Future<Directory> Function()? tempDirectory,
}) async {
  try {
    final root = await (tempDirectory ?? getTemporaryDirectory)();
    await _deleteQuietly(Directory('${root.path}/$characterShareFolder'));
  } on Object {
    // Nothing to clean when there is no temporary directory.
  }
}

Future<void> _deleteQuietly(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } on FileSystemException {
    // A file the system still holds goes with the next cleaning.
  }
}
