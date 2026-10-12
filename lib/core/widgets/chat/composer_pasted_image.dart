import 'dart:io';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../models/attachment_draft.dart';
import '../../services/attachment_uploader.dart';

/// Image types every composer declares to the keyboard (Gboard images, GIFs
/// and clipboard screenshots arrive through `commitContent`). A payload with
/// any other type is refused before it touches the disk.
const List<String> kComposerInsertableImageMimeTypes = [
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
];

/// Most images one composer batch may hold, shared by every composer.
const int kComposerMaxPendingImages = 10;

/// Why a keyboard-inserted payload cannot join the composer batch.
enum ComposerPasteRejection { empty, unsupportedType, imageLimit, sizeLimit }

/// Checks a keyboard-inserted payload against the same limits the main chat
/// composer applies: an allowed image type, the per-image cap, the per-item
/// size cap and the batch size cap. `null` means it can be staged.
ComposerPasteRejection? composerPasteRejection(
  KeyboardInsertedContent content, {
  required Iterable<AttachmentDraft> pending,
}) {
  final bytes = content.data;
  if (bytes == null || bytes.isEmpty) return ComposerPasteRejection.empty;
  if (!kComposerInsertableImageMimeTypes.contains(
    content.mimeType.toLowerCase(),
  )) {
    return ComposerPasteRejection.unsupportedType;
  }
  if (pending.where((item) => item.isImage).length >=
      kComposerMaxPendingImages) {
    return ComposerPasteRejection.imageLimit;
  }
  final batchBytes = pending.fold<int>(0, (sum, item) => sum + item.sizeBytes);
  if (bytes.length > AttachmentUploader.maxBytes ||
      batchBytes + bytes.length > AttachmentUploader.maxBatchBytes) {
    return ComposerPasteRejection.sizeLimit;
  }
  return null;
}

/// Writes an accepted keyboard payload to a temporary file and hands it to
/// [materialize] (the private draft copy). The temporary file is removed
/// unless the materialized draft still points at it. Returns `null` when
/// materialization refused the file; I/O errors propagate to the caller.
Future<AttachmentDraft?> stageComposerPastedImage(
  KeyboardInsertedContent content, {
  required Future<AttachmentDraft?> Function(AttachmentDraft draft) materialize,
}) async {
  final bytes = content.data!;
  final mimeType = content.mimeType.toLowerCase();
  final extension = switch (mimeType) {
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => 'png',
  };
  final source = File(
    '${Directory.systemTemp.path}/hermes-ime-${const Uuid().v4()}.$extension',
  );
  AttachmentDraft? persisted;
  try {
    await source.writeAsBytes(bytes, flush: true);
    persisted = await materialize(
      AttachmentDraft(
        localId: const Uuid().v4(),
        type: AttachmentType.image,
        name: 'pasted-image.$extension',
        mimeType: mimeType,
        sizeBytes: bytes.length,
        localPath: source.path,
      ),
    );
    return persisted;
  } finally {
    if (persisted?.localPath != source.path) {
      try {
        if (await source.exists()) await source.delete();
      } catch (_) {}
    }
  }
}
