import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'attachment_card.dart';
import 'cover_resize_image.dart';
import 'generated_video_card.dart';

/// How a sent or received attachment is previewed, wherever it appears
/// (main chat, bot chats, rooms).
enum AttachmentPreviewKind { image, video, audio, pdf, document }

const Set<String> _videoExtensions = {
  'mp4',
  'm4v',
  'mov',
  'webm',
  'mkv',
  '3gp',
  'avi',
};

String _extensionOf(String name) {
  final leaf = name.split(RegExp(r'[\\/]')).last;
  final dot = leaf.lastIndexOf('.');
  return dot <= 0 ? '' : leaf.substring(dot + 1).toLowerCase();
}

bool isVideoAttachment(String name, String mimeType) {
  final mime = mimeType.split(';').first.trim().toLowerCase();
  return mime.startsWith('video/') ||
      _videoExtensions.contains(_extensionOf(name));
}

AttachmentPreviewKind attachmentPreviewKindFor(String name, String mimeType) {
  if (isVideoAttachment(name, mimeType)) return AttachmentPreviewKind.video;
  return switch (attachmentKindFor(name, mimeType)) {
    AttachmentKind.image => AttachmentPreviewKind.image,
    AttachmentKind.audio => AttachmentPreviewKind.audio,
    AttachmentKind.pdf => AttachmentPreviewKind.pdf,
    _ => AttachmentPreviewKind.document,
  };
}

/// Shortens a long file name in the middle so its start and its extension
/// both stay readable: `quarterly-report-final-v3-signed.pdf` →
/// `quarterly-repor…-signed.pdf`.
String middleEllipsis(String name, {int maxChars = 30}) {
  final runes = name.runes.toList();
  if (runes.length <= maxChars || maxChars < 8) return name;
  final ext = _extensionOf(name);
  final tailLength = ext.isEmpty
      ? (maxChars / 3).floor()
      : (ext.length + 8).clamp(0, maxChars ~/ 2);
  final headLength = maxChars - tailLength - 1;
  return '${String.fromCharCodes(runes.take(headLength))}…'
      '${String.fromCharCodes(runes.skip(runes.length - tailLength))}';
}

/// Shared preview of one attachment once its verified local copy exists:
/// images as a bounded-decode thumbnail (tap → viewer), videos as the inline
/// player with its poster frame, play button and duration, audio as the
/// compact player and anything else as the type card (badge, short name,
/// size). Without a [file] it is always the type card, so a chip never
/// degrades to a bare file name.
class AttachmentPreview extends StatelessWidget {
  final String name;
  final String mimeType;
  final String sizeLabel;
  final File? file;

  /// Opens a document/PDF in its viewer. Images and videos open themselves.
  final VoidCallback? onOpen;

  const AttachmentPreview({
    super.key,
    required this.name,
    required this.mimeType,
    required this.sizeLabel,
    this.file,
    this.onOpen,
  });

  /// Logical side of an image thumbnail.
  static const double imageExtent = 160;

  /// Widest a video preview gets inside a message.
  static const double videoMaxWidth = 300;

  @override
  Widget build(BuildContext context) {
    final file = this.file;
    final kind = attachmentPreviewKindFor(name, mimeType);
    if (file != null) {
      switch (kind) {
        case AttachmentPreviewKind.image:
          return _imageThumb(context, file);
        case AttachmentPreviewKind.video:
          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: videoMaxWidth),
            child: GeneratedVideoCard(
              key: ValueKey<String>('attachment-preview-video-${file.path}'),
              file: file,
            ),
          );
        case AttachmentPreviewKind.audio:
          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: videoMaxWidth),
            child: GeneratedAudioPlayerCard(
              key: ValueKey<String>('attachment-preview-audio-${file.path}'),
              file: file,
              name: middleEllipsis(name),
              mimeType: mimeType,
              sizeBytes: _lengthOf(file),
              onShare: () => shareMediaFile(file),
              onSave: () => _saveCopy(file),
              showOpenAction: false,
            ),
          );
        case AttachmentPreviewKind.pdf:
        case AttachmentPreviewKind.document:
          break;
      }
    }
    return typeCard();
  }

  /// The badge + short name + size card used for documents and as the
  /// placeholder while a media copy is not available yet.
  Widget typeCard() => AttachmentCard(
    key: ValueKey<String>('attachment-preview-card-$name'),
    name: middleEllipsis(name),
    mimeType: mimeType.isEmpty && isVideoAttachment(name, mimeType)
        ? 'video/*'
        : mimeType,
    sizeLabel: sizeLabel,
    onTap: onOpen,
  );

  Widget _imageThumb(BuildContext context, File file) {
    final colors = Theme.of(context).hermes;
    final target = (imageExtent * MediaQuery.devicePixelRatioOf(context))
        .ceil();
    return GestureDetector(
      key: ValueKey<String>('attachment-preview-image-${file.path}'),
      onTap: () => showImageViewer(context, file),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: imageExtent,
          height: imageExtent,
          color: colors.surfaceVariant,
          // Decode near the box, never the full photo: a 12 MP shot would be
          // ~48 MB of RGBA per thumbnail on the raster path.
          child: Image(
            image: CoverResizeImage(FileImage(file), target: target),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            // A bitmap decoded ahead paints at once; otherwise it fades in
            // over the reserved box instead of popping.
            frameBuilder: (_, child, frame, synchronous) => synchronous
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration:
                        MediaQuery.maybeDisableAnimationsOf(context) ?? false
                        ? Duration.zero
                        : const Duration(milliseconds: 150),
                    curve: Curves.easeOut,
                    child: child,
                  ),
            errorBuilder: (_, _, _) => Center(child: typeCard()),
          ),
        ),
      ),
    );
  }

  static int _lengthOf(File file) {
    try {
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _saveCopy(File file) async {
    try {
      await FilePicker.platform.saveFile(
        dialogTitle: 'Hermes Console',
        fileName: name,
        bytes: await file.readAsBytes(),
      );
    } catch (_) {
      // The picker reports its own failures; nothing to roll back.
    }
  }
}
