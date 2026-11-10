import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../models/attachment_draft.dart';
import '../services/connection_manager.dart';
import '../services/generated_media_service.dart';
import '../services/media_dimensions.dart';
import '../services/media_prefetcher.dart';
import '../theme/app_theme.dart';
import '../theme/theme_contrast.dart';
import '../design/tokens.dart' show HermesRadius;
import '../theme/motion.dart' show HermesMotion;
import 'generated_image_card.dart';
import 'hermes_app_bar.dart';
import 'hermes_notice.dart';
import 'media_viewer/media_viewer.dart';
import 'save_to_device_feedback.dart' show saveFileToDevice;

/// Tipo visual de adjunto, derivado del mime/extensión. Gobierna el badge de
/// color y la etiqueta corta (estilo ChatGPT: "PDF", "DOC", "IMG"…).
enum AttachmentKind {
  image,
  pdf,
  doc,
  sheet,
  code,
  text,
  archive,
  audio,
  video,
  other,
}

AttachmentKind attachmentKindFor(String name, String mimeType) {
  final m = mimeType.toLowerCase();
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  if (m.startsWith('image/') ||
      const {
        'png',
        'jpg',
        'jpeg',
        'gif',
        'webp',
        'bmp',
        'heic',
      }.contains(ext)) {
    return AttachmentKind.image;
  }
  if (m == 'application/pdf' || ext == 'pdf') return AttachmentKind.pdf;
  if (const {'doc', 'docx', 'odt', 'rtf'}.contains(ext) || m.contains('word')) {
    return AttachmentKind.doc;
  }
  if (const {'xls', 'xlsx', 'csv', 'ods'}.contains(ext) ||
      m.contains('sheet') ||
      m == 'text/csv') {
    return AttachmentKind.sheet;
  }
  if (const {
    'json',
    'yaml',
    'yml',
    'xml',
    'sh',
    'py',
    'dart',
    'js',
    'ts',
  }.contains(ext)) {
    return AttachmentKind.code;
  }
  if (const {'txt', 'md', 'log'}.contains(ext) || m.startsWith('text/')) {
    return AttachmentKind.text;
  }
  if (const {'zip', 'tar', 'gz', '7z', 'rar'}.contains(ext)) {
    return AttachmentKind.archive;
  }
  if (m.startsWith('audio/') ||
      const {'mp3', 'wav', 'ogg', 'm4a'}.contains(ext)) {
    return AttachmentKind.audio;
  }
  if (m.startsWith('video/') ||
      const {'mp4', 'm4v', 'mov', 'webm', 'mkv', '3gp', 'avi'}.contains(ext)) {
    return AttachmentKind.video;
  }
  return AttachmentKind.other;
}

/// Etiqueta corta para el badge (p. ej. "PDF", "DOC", "TXT").
String _badgeLabel(AttachmentKind kind, String name, Strings strings) {
  final ext = name.contains('.') ? name.split('.').last.toUpperCase() : '';
  return switch (kind) {
    AttachmentKind.pdf => 'PDF',
    AttachmentKind.doc => ext.isNotEmpty ? ext : 'DOC',
    AttachmentKind.sheet => ext.isNotEmpty ? ext : 'CSV',
    AttachmentKind.code => ext.isNotEmpty ? ext : strings.i18n131P6BadgeCode,
    AttachmentKind.text => ext.isNotEmpty ? ext : 'TXT',
    AttachmentKind.archive => ext.isNotEmpty ? ext : 'ZIP',
    AttachmentKind.audio => ext.isNotEmpty ? ext : strings.i18n131P6BadgeAudio,
    AttachmentKind.video => ext.isNotEmpty ? ext : strings.i18n131P6BadgeVideo,
    AttachmentKind.image => strings.sa1215KindImage,
    AttachmentKind.other => ext.isNotEmpty ? ext : strings.sa1215KindFile,
  };
}

Color _badgeColor(AttachmentKind kind) {
  return switch (kind) {
    AttachmentKind.pdf => const Color(0xFFE5484D),
    AttachmentKind.doc => const Color(0xFF4C7DF0),
    AttachmentKind.sheet => const Color(0xFF2E9E5B),
    AttachmentKind.code => const Color(0xFF8E7CF0),
    AttachmentKind.text => const Color(0xFF8A8F98),
    AttachmentKind.archive => const Color(0xFFC79328),
    AttachmentKind.audio => const Color(0xFFD06BB3),
    AttachmentKind.video => const Color(0xFF6E6AE8),
    AttachmentKind.image => const Color(0xFF2E9E5B),
    AttachmentKind.other => const Color(0xFF8A8F98),
  };
}

/// How much of a kind's colour tints its badge tile.
const double _badgeTint = 0.16;

/// The tint of a badge tile of [kind], drawn over the surface below it.
Color attachmentBadgeTint(AttachmentKind kind) =>
    _badgeColor(kind).withValues(alpha: _badgeTint);

final Map<(AttachmentKind, int, double, bool), Color> _badgeInks = {};

/// The colour of [kind] made readable over [under], the surface its badge
/// sits on (through the badge's own tint when [tinted]): the hue stays, and
/// the ink moves toward black or white only as far as [minimum] needs
/// (4.5:1 for a label, 3:1 for an icon). The fixed kind colours were tuned
/// for a dark page; on a light one some fell to 2.4:1.
Color attachmentBadgeInk(
  AttachmentKind kind,
  Color under, {
  double minimum = 4.5,
  bool tinted = true,
}) {
  final key = (kind, under.toARGB32(), minimum, tinted);
  return _badgeInks[key] ??= _readableBadgeInk(kind, under, minimum, tinted);
}

Color _readableBadgeInk(
  AttachmentKind kind,
  Color under,
  double minimum,
  bool tinted,
) {
  final hue = _badgeColor(kind);
  final behind = tinted
      ? ThemeContrast.composite(attachmentBadgeTint(kind), under)
      : under;
  return ThemeContrast.adjustForContrast(hue, [behind], minimum: minimum);
}

/// Tarjeta de adjunto estilo ChatGPT: imágenes como miniatura, documentos como
/// tarjeta con badge de tipo + nombre + tamaño. Reutilizable en el compositor
/// (con [onRemove]) y en los mensajes enviados (con [onTap]).
class AttachmentCard extends StatelessWidget {
  final String name;
  final String mimeType;
  final String sizeLabel;

  /// Imagen local a previsualizar (compositor). Si es null y la miniatura es
  /// remota, se usa [thumbnailUrl].
  final File? thumbnailFile;
  final String? thumbnailUrl;

  /// Estado de subida opcional (para feedback en el compositor).
  final bool showUploadState;
  final AttachmentUploadState uploadState;

  final VoidCallback? onRemove;
  final VoidCallback? onRetry;
  final VoidCallback? onTap;

  /// Composer tray variant: every attachment is a [compactThumbSize] rounded
  /// square (image thumb, or a kind icon plus a short name) with a small ×
  /// inside its corner. Chat bubbles keep the default 120 dp thumb.
  final bool compact;

  /// Side of every tile in the [compact] variant.
  static const double compactThumbSize = 60;

  /// The 48 dp × / retry targets of a [compact] tile overhang it by this
  /// much above and to the side, so the tile's centre stays free for the
  /// preview tap.
  static const double compactTargetTop = 16;
  static const double compactTargetSide = 20;

  /// QA 9493: the small badge of a [compact] tile sits INSIDE its corner,
  /// its centre this far from the tile's top and side edges.
  static const double compactBadgeInset = 12;

  /// Places [badge] inside its overhanging 48 dp target so that its centre
  /// lands [compactBadgeInset] in from the tile's corner: the top end
  /// corner for the × ([end]), the top start corner for retry.
  static Widget _compactBadge(Widget badge, {required bool end}) {
    const reach = compactTargetSide + compactBadgeInset;
    return Align(
      alignment: Alignment.topLeft,
      child: Transform.translate(
        offset: Offset(
          end ? 48 - reach : reach,
          compactTargetTop + compactBadgeInset,
        ),
        child: FractionalTranslation(
          translation: const Offset(-0.5, -0.5),
          child: badge,
        ),
      ),
    );
  }

  /// The badge centred in its target, or in the tile's corner when
  /// [compact].
  Widget _badgeSlot(Widget badge, {required bool end}) =>
      compact ? _compactBadge(badge, end: end) : Center(child: badge);

  double get _radius => compact ? 14 : 12;

  const AttachmentCard({
    super.key,
    required this.name,
    required this.mimeType,
    required this.sizeLabel,
    this.thumbnailFile,
    this.thumbnailUrl,
    this.showUploadState = false,
    this.uploadState = AttachmentUploadState.pending,
    this.onRemove,
    this.onRetry,
    this.onTap,
    this.compact = false,
  });

  double get _thumbSize => compact ? compactThumbSize : 120;

  @override
  Widget build(BuildContext context) {
    final kind = attachmentKindFor(name, mimeType);
    final card = kind == AttachmentKind.image && _hasThumb
        ? _imageThumb(context, kind)
        : compact
        ? _fileTile(context, kind)
        : _fileCard(context, kind);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        if (uploadState == AttachmentUploadState.uploading)
          Positioned.fill(child: _overlay(context, spinner: true)),
        // The resting states (pending / attached) are the default: an image
        // thumb carries no text badge for them. Only a transition (uploading)
        // or a failure (error, with its retry button) is labelled.
        if (showUploadState &&
            kind == AttachmentKind.image &&
            _hasThumb &&
            _showsImageStateBadge)
          _imageStateBadge(context),
        if (onRetry != null) _retryButton(context),
        if (onRemove != null) _removeButton(context),
      ],
    );
  }

  bool get _hasThumb =>
      thumbnailFile != null || (thumbnailUrl?.isNotEmpty ?? false);

  // The compact composer thumb is too narrow for the text pill ("Error al…"):
  // there the state is carried by the spinner, the retry button and the
  // semantics label of the strip instead.
  bool get _showsImageStateBadge =>
      !compact &&
      (uploadState == AttachmentUploadState.uploading ||
          uploadState == AttachmentUploadState.error);

  /// Decode bound for the 120 dp thumb (3x). Only ONE side is fixed: giving
  /// the decoder both `cacheWidth` and `cacheHeight` resizes the bitmap to
  /// 360x360 without preserving its aspect ratio, so a portrait photo arrives
  /// already squashed before `BoxFit.cover` crops it.
  static const int _thumbDecodeWidth = 360;

  Widget _imageThumb(BuildContext context, AttachmentKind kind) {
    final colors = Theme.of(context).hermes;
    // `gaplessPlayback`: a rebuild that swaps the provider (or the file's
    // identity) keeps the previous frame on screen instead of flashing blank
    // while the new decode lands — the "flicker" seen during streaming.
    final img = thumbnailFile != null
        ? Image.file(
            thumbnailFile!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: _thumbDecodeWidth,
          )
        : Image.network(
            thumbnailUrl!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: _thumbDecodeWidth,
            errorBuilder: (_, _, _) =>
                compact ? _fileTile(context, kind) : _fileCard(context, kind),
          );
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: Container(
          width: _thumbSize,
          height: _thumbSize,
          color: colors.surfaceVariant,
          child: img,
        ),
      ),
    );
  }

  /// The L2 chat design's file card (`v2-cadu-console.html` `.card`): the
  /// type tile, the name, «PDF · 2,4 MB» in mono, and a chevron when it
  /// opens. Only what is known: no page count, no reading time.
  Widget _fileCard(BuildContext context, AttachmentKind kind) {
    final colors = Theme.of(context).hermes;
    // A card that opens is a button for TalkBack too (REVIEW-R5-B #19).
    return Semantics(
      container: onTap != null,
      button: onTap != null,
      child: _fileCardBody(colors, context, kind),
    );
  }

  Widget _fileCardBody(
    HermesThemeColors colors,
    BuildContext context,
    AttachmentKind kind,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        key: const ValueKey('attachment-file-card'),
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(HermesRadius.floating),
          border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _badge(context, kind),
            const SizedBox(width: 12),
            // The chevron sits over the end of the text block, which keeps
            // its room: only the badge and the gap are fixed, so a narrow
            // card (a room's file row beside its three actions) shrinks the
            // name instead of overflowing (gint26).
            Flexible(
              child: Stack(
                alignment: AlignmentDirectional.centerEnd,
                children: [
                  Padding(
                    padding: EdgeInsetsDirectional.only(
                      end: onTap != null ? 28 : 0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _fileSubtitle(context, kind),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: uploadState == AttachmentUploadState.error
                                ? colors.error
                                : colors.textSecondary,
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onTap != null)
                    PositionedDirectional(
                      end: 0,
                      child: Icon(
                        Icons.chevron_right_rounded,
                        key: const ValueKey('attachment-file-card-open'),
                        size: 20,
                        color: colors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tray tile for a non-image attachment: the kind icon and a short name
  /// inside the same rounded square as an image thumb.
  Widget _fileTile(BuildContext context, AttachmentKind kind) {
    final colors = Theme.of(context).hermes;
    final failed = uploadState == AttachmentUploadState.error;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: compactThumbSize,
        height: compactThumbSize,
        padding: const EdgeInsets.fromLTRB(5, 8, 5, 6),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(_radius),
          border: Border.all(
            color: failed
                ? colors.error
                : colors.divider.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _tileIcon(kind),
              size: 22,
              color: failed
                  ? colors.error
                  : attachmentBadgeInk(
                      kind,
                      colors.surfaceVariant,
                      minimum: 3,
                      tinted: false,
                    ),
            ),
            const SizedBox(height: 4),
            // Fixed tile: the name may grow a little with the text scale but
            // never past the tile; the full name stays in semantics.
            MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: Text(
                name,
                key: const ValueKey('attachment-tile-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 10,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _tileIcon(AttachmentKind kind) => switch (kind) {
    AttachmentKind.image => Icons.image_outlined,
    AttachmentKind.video => Icons.movie_outlined,
    AttachmentKind.audio => Icons.audiotrack_outlined,
    AttachmentKind.archive => Icons.folder_zip_outlined,
    AttachmentKind.other => Icons.insert_drive_file_outlined,
    AttachmentKind.pdf ||
    AttachmentKind.doc ||
    AttachmentKind.sheet ||
    AttachmentKind.code ||
    AttachmentKind.text => Icons.description_outlined,
  };

  String _fileSubtitle(BuildContext context, AttachmentKind kind) {
    if (!showUploadState) {
      final badge = _badgeLabel(kind, name, Strings.of(context));
      return sizeLabel.isEmpty ? badge : '$badge · $sizeLabel';
    }
    final state = _uploadStateLabel(context);
    return sizeLabel.isEmpty ? state : '$state · $sizeLabel';
  }

  String _uploadStateLabel(BuildContext context) {
    final strings = Strings.of(context);
    return switch (uploadState) {
      AttachmentUploadState.pending => strings.chaAttachmentPending,
      AttachmentUploadState.uploading => strings.chaAttachmentUploading,
      AttachmentUploadState.error => strings.chaAttachmentFailed,
      AttachmentUploadState.attached => strings.chaAttachmentAttached,
      AttachmentUploadState.removed => strings.chaAttachmentRemoved,
    };
  }

  Widget _imageStateBadge(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final isError = uploadState == AttachmentUploadState.error;
    return Positioned(
      left: 8,
      right: 8,
      bottom: 8,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: (isError ? colors.error : Colors.black).withValues(
              alpha: isError ? 0.9 : 0.68,
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            _uploadStateLabel(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  /// L2 `.ft`: the file type on a tile tinted with its colour.
  Widget _badge(BuildContext context, AttachmentKind kind) {
    final color = _badgeColor(kind);
    final ink = attachmentBadgeInk(
      kind,
      Theme.of(context).hermes.surfaceVariant,
    );
    return Container(
      width: 46,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: attachmentBadgeTint(kind),
        borderRadius: BorderRadius.circular(HermesRadius.control),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        _badgeLabel(kind, name, Strings.of(context)),
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: TextStyle(
          color: ink,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w700,
          fontSize: 11,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _overlay(BuildContext context, {bool spinner = false}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(_radius),
      child: Container(
        color: Colors.black.withValues(alpha: 0.45),
        alignment: Alignment.center,
        child: spinner
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
    );
  }

  Widget _removeButton(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Positioned(
      top: compact ? -compactTargetTop : -12,
      right: compact ? -compactTargetSide : -12,
      child: Semantics(
        button: true,
        label: Strings.of(context).chaRemoveAttachment,
        excludeSemantics: true,
        child: Tooltip(
          message: Strings.of(context).chaRemoveAttachment,
          child: GestureDetector(
            onTap: onRemove,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 48,
              height: 48,
              child: _badgeSlot(
                end: true,
                Container(
                  padding: EdgeInsets.all(compact ? 2 : 3),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.divider),
                  ),
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _retryButton(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Positioned(
      top: compact ? -compactTargetTop : -12,
      left: compact ? -compactTargetSide : -12,
      child: Semantics(
        button: true,
        label: Strings.of(context).chaRetryAttachment,
        excludeSemantics: true,
        child: Tooltip(
          message: Strings.of(context).chaRetryAttachment,
          child: GestureDetector(
            onTap: onRetry,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 48,
              height: 48,
              child: _badgeSlot(
                end: false,
                Container(
                  padding: EdgeInsets.all(compact ? 2 : 4),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.divider),
                  ),
                  child: Icon(
                    Icons.refresh_rounded,
                    size: compact ? 14 : 15,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum GeneratedFileStatus { consent, downloading, ready, error, offline }

class GeneratedFileCard extends StatelessWidget {
  final String name;
  final String mimeType;
  final GeneratedFileStatus status;
  final int receivedBytes;
  final int? totalBytes;
  final String? errorLabel;
  final VoidCallback onDownload;
  final VoidCallback? onCancel;
  final VoidCallback? onOpen;
  final VoidCallback? onShare;
  final VoidCallback? onSave;

  /// `::preview{file="….html"}`: labelled as an HTML preview. Console has no
  /// live sandboxed frame yet, so the card stays a downloadable file.
  final bool htmlPreview;

  const GeneratedFileCard({
    super.key,
    required this.name,
    required this.mimeType,
    required this.status,
    required this.onDownload,
    this.onCancel,
    this.receivedBytes = 0,
    this.totalBytes,
    this.errorLabel,
    this.onOpen,
    this.onShare,
    this.onSave,
    this.htmlPreview = false,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final total = totalBytes;
    final determinate = total != null && total > 0;
    final progress = determinate
        ? (receivedBytes / total).clamp(0.0, 1.0)
        : null;
    final sizeLabel = switch (status) {
      GeneratedFileStatus.consent =>
        total != null ? _formatFileBytes(total) : strings.commonDownload,
      GeneratedFileStatus.downloading =>
        determinate
            ? '${_formatFileBytes(receivedBytes)} / ${_formatFileBytes(total)}'
            : strings.genMediaLoading,
      GeneratedFileStatus.ready =>
        total != null
            ? _formatFileBytes(total)
            : _formatFileBytes(receivedBytes),
      GeneratedFileStatus.error => errorLabel ?? strings.genMediaError,
      GeneratedFileStatus.offline => strings.genMediaOffline,
    };
    final cardLabel = htmlPreview
        ? '${strings.genMediaHtmlPreview} · $sizeLabel'
        : sizeLabel;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AttachmentCard(
            key: ValueKey<String>(
              htmlPreview
                  ? 'generated-html-preview-card'
                  : 'generated-file-card',
            ),
            name: name,
            mimeType: mimeType,
            sizeLabel: cardLabel,
            onTap: status == GeneratedFileStatus.ready ? onOpen : null,
          ),
          if (status == GeneratedFileStatus.downloading) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: 260,
              child: LinearProgressIndicator(value: progress),
            ),
          ],
          const SizedBox(height: 4),
          if (status == GeneratedFileStatus.consent)
            TextButton.icon(
              onPressed: onDownload,
              icon: const Icon(Icons.download_rounded),
              label: Text(strings.commonDownload),
            )
          else if (status == GeneratedFileStatus.downloading &&
              onCancel != null)
            TextButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.close_rounded),
              label: Text(strings.commonCancel),
            )
          else if (status == GeneratedFileStatus.error ||
              status == GeneratedFileStatus.offline)
            TextButton.icon(
              onPressed: onDownload,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(strings.commonRetry),
            )
          else if (status == GeneratedFileStatus.ready)
            Wrap(
              spacing: 4,
              children: [
                TextButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(strings.commonOpen),
                ),
                TextButton.icon(
                  onPressed: onShare,
                  icon: const Icon(Icons.share_outlined),
                  label: Text(strings.commonShare),
                ),
                TextButton.icon(
                  onPressed: onSave,
                  icon: const Icon(Icons.save_alt_rounded),
                  label: Text(strings.commonSave),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

String _formatFileBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
  final mib = kib / 1024;
  return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
}

typedef GeneratedMediaFileLoader =
    Future<File> Function(
      GeneratedMediaProgress onProgress,
      bool Function() isCancelled,
    );
typedef GeneratedMediaReadyBuilder =
    Widget? Function(
      BuildContext context,
      File file,
      int sizeBytes,
      VoidCallback onOpenExternal,
      VoidCallback onShare,
      VoidCallback onSave,
    );
typedef GeneratedMediaOpenCallback =
    Future<void> Function(
      BuildContext context,
      File file,
      int sizeBytes,
      VoidCallback onOpenExternal,
      VoidCallback onShare,
      VoidCallback onSave,
    );

bool _isTransientGeneratedMediaError(Object error) {
  if (error is SocketException ||
      error is TimeoutException ||
      error is HttpException ||
      error is http.ClientException) {
    return true;
  }
  if (error is DashboardHttpException) {
    return error.statusCode == 401 || error.statusCode >= 500;
  }
  return error is DashboardAuthException &&
      error.code != DashboardAuthFailureCode.rateLimited &&
      (error.statusCode ?? 0) >= 500;
}

Future<void> openGeneratedMediaExternally(
  File file, {
  required String mimeType,
  required int expectedSize,
}) async {
  if (!GeneratedMediaService.allowsExternalOpen(file, mimeType: mimeType)) {
    throw const FormatException('executable generated media cannot be opened');
  }
  final locator = GeneratedMediaService.cacheLocator(file);
  if (locator == null) throw const FormatException('invalid generated cache');
  final digest = (await sha256.bind(file.openRead()).first).toString();
  await const MethodChannel(
    'hermes/document_preview',
  ).invokeMethod<void>('openGeneratedFile', {
    'storageKey': digest,
    'expectedSize': expectedSize,
    'expectedSha256': digest,
    'generatedConnectionKey': locator.connectionKey,
    'generatedFileKey': locator.fileKey,
    'mimeType': mimeType,
  });
}

class GeneratedMediaAttachmentCard extends StatefulWidget {
  final GeneratedMediaReference reference;
  final bool autoLoad;
  final GeneratedMediaFileLoader load;
  final GeneratedMediaReadyBuilder? readyBuilder;
  final GeneratedMediaOpenCallback? onOpen;
  final GeneratedAudioPlayback? audioPlayback;
  final String Function(BuildContext context, Object error)? errorLabelBuilder;

  /// Identity of this file within its connection and profile. When set, a
  /// verified ready file is remembered so that a card the lazy transcript
  /// disposed while scrolling comes back ready on its first frame, instead of
  /// replaying consent → download → ready (a second load and two height jumps
  /// every time it re-enters the viewport). Null disables the memo.
  final String? readyMemoKey;

  const GeneratedMediaAttachmentCard({
    super.key,
    required this.reference,
    required this.autoLoad,
    required this.load,
    this.readyBuilder,
    this.onOpen,
    this.audioPlayback,
    this.errorLabelBuilder,
    this.readyMemoKey,
  });

  static const int _readyMemoCapacity = 128;

  /// M1: characters of decoded text previews the memo keeps across all
  /// entries; past it the oldest previews are read again on remount.
  static const int _readyMemoTextBudget = 1024 * 1024;

  /// Insertion-ordered, so the first entry is the least recently used.
  /// [text]/[lines] keep a text file's decoded preview and whole-file line
  /// count, so a remount neither reads nor decodes it again.
  static final Map<String, _ReadyEntry> _readyMemo = {};

  @visibleForTesting
  static void clearReadyMemoForTesting() => _readyMemo.clear();

  static _ReadyEntry? _recallReady(String key) {
    final entry = _readyMemo.remove(key);
    if (entry == null) return null;
    // The cache may have been evicted or replaced on disk since.
    if (!entry.file.existsSync() || entry.file.lengthSync() != entry.length) {
      return null;
    }
    _readyMemo[key] = entry;
    return entry;
  }

  static void _rememberReady(
    String key,
    File file,
    int length, {
    String? text,
    int? lines,
  }) {
    _readyMemo.remove(key);
    _readyMemo[key] = (file: file, length: length, text: text, lines: lines);
    while (_readyMemo.length > _readyMemoCapacity) {
      _readyMemo.remove(_readyMemo.keys.first);
    }
    var chars = 0;
    for (final entry in _readyMemo.values) {
      chars += entry.text?.length ?? 0;
    }
    for (final MapEntry(key: older, :value) in _readyMemo.entries.toList()) {
      if (chars <= _readyMemoTextBudget) break;
      final text = value.text;
      if (text == null) continue;
      chars -= text.length;
      _readyMemo[older] = (
        file: value.file,
        length: value.length,
        text: null,
        lines: value.lines,
      );
    }
  }

  @override
  State<GeneratedMediaAttachmentCard> createState() =>
      _GeneratedMediaAttachmentCardState();
}

typedef _ReadyEntry = ({File file, int length, String? text, int? lines});

/// M1: an inline text preview reads at most this much of the file; the
/// full viewer reads the whole file when it opens.
const int _textPreviewMaxBytes = 64 * 1024;

class _GeneratedMediaAttachmentCardState
    extends State<GeneratedMediaAttachmentCard>
    with WidgetsBindingObserver {
  GeneratedFileStatus _status = GeneratedFileStatus.consent;
  File? _file;
  String? _text;

  /// Lines of the whole file when [_text] holds only its first 64 KB.
  int? _textLines;
  int _receivedBytes = 0;
  int? _totalBytes;
  String? _errorLabel;
  bool _cancelled = false;
  bool _autoLimitExceeded = false;
  bool _visible = false;
  bool _visibilityCheckScheduled = false;
  int _generation = 0;
  GeneratedMediaAutoLoadCancellation? _autoLoadCancellation;
  ScrollableState? _scrollable;

  int get _autoLimit => GeneratedMediaService.autoLoadLimit(widget.reference);

  bool get _inForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  bool get _mayAutoLoad =>
      widget.autoLoad &&
      widget.reference.sourceKind == GeneratedMediaSourceKind.serverPath &&
      GeneratedMediaService.allowsAutoLoad(widget.reference);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _totalBytes = widget.reference.sizeBytes;
    _restoreRemembered();
    _scheduleVisibilityCheck();
  }

  String? get _memoKey {
    final scope = widget.readyMemoKey;
    if (scope == null) return null;
    return GeneratedMediaService.readyKey(scope, widget.reference);
  }

  /// Images (and other inline media) are painted in a reserved box instead
  /// of a file card while their bytes are on their way.
  bool get _presizedImage =>
      widget.reference.kind == GeneratedMediaKind.image &&
      !widget.reference.htmlPreview;

  /// Synchronous so the very first frame is already the ready card: the
  /// in-process memo, then a finished prefetch, then the private disk cache
  /// (reopen / app restart), none of which touch the network.
  void _restoreRemembered() {
    final key = _memoKey;
    if (key == null) return;
    var remembered = GeneratedMediaAttachmentCard._recallReady(key);
    if (remembered == null &&
        widget.reference.kind != GeneratedMediaKind.file) {
      // Files (text/PDF) keep the async inline-safety check of a real load.
      final cached =
          MediaPrefetcher.instance.readyFile(key) ??
          GeneratedMediaService.cachedFileSync(
            widget.readyMemoKey!,
            widget.reference,
          );
      if (cached != null) {
        try {
          final length = cached.lengthSync();
          if (length > 0 && length <= _autoLimit) {
            GeneratedMediaAttachmentCard._rememberReady(key, cached, length);
            remembered = (
              file: cached,
              length: length,
              text: null,
              lines: null,
            );
          }
        } catch (_) {
          // Evicted meanwhile: load normally.
        }
      }
    }
    if (remembered == null) return;
    _file = remembered.file;
    _text =
        remembered.text ?? _readTextPreview(remembered.file, remembered.length);
    _textLines = remembered.lines;
    _receivedBytes = remembered.length;
    _totalBytes = remembered.length;
    _status = GeneratedFileStatus.ready;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable != _scrollable) {
      _scrollable?.position.removeListener(_scheduleVisibilityCheck);
      _scrollable = scrollable;
      _scrollable?.position.addListener(_scheduleVisibilityCheck);
    }
    _scheduleVisibilityCheck();
  }

  @override
  void didUpdateWidget(covariant GeneratedMediaAttachmentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference.source != widget.reference.source ||
        oldWidget.autoLoad != widget.autoLoad) {
      _generation++;
      _cancelled = true;
      _autoLoadCancellation?.cancel();
      _autoLoadCancellation = null;
      _file = null;
      _text = null;
      _textLines = null;
      _receivedBytes = 0;
      _totalBytes = widget.reference.sizeBytes;
      _errorLabel = null;
      _status = GeneratedFileStatus.consent;
      _restoreRemembered();
      _scheduleVisibilityCheck();
    }
  }

  void _scheduleVisibilityCheck() {
    if (_visibilityCheckScheduled) return;
    _visibilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckScheduled = false;
      if (!mounted) return;
      final visible = _isWithinViewport();
      if (visible == _visible) {
        if (visible) _startAutoLoad();
        return;
      }
      _visible = visible;
      if (visible) {
        _startAutoLoad();
      } else {
        _cancelInvisibleAutoLoad();
      }
    });
  }

  bool _isWithinViewport() {
    final renderObject =
        _contentKey.currentContext?.findRenderObject() ??
        context.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return false;
    }
    final widgetRect =
        renderObject.localToGlobal(Offset.zero) & renderObject.size;
    final viewportObject = _scrollable?.context.findRenderObject();
    final viewportRect =
        viewportObject is RenderBox &&
            viewportObject.attached &&
            viewportObject.hasSize
        ? viewportObject.localToGlobal(Offset.zero) & viewportObject.size
        : Offset.zero & MediaQuery.sizeOf(context);
    final intersection = widgetRect.intersect(viewportRect);
    return intersection.width > 0 && intersection.height > 0;
  }

  void _cancelInvisibleAutoLoad() {
    final cancellation = _autoLoadCancellation;
    if (cancellation == null) return;
    _generation++;
    _cancelled = true;
    cancellation.cancel();
    _autoLoadCancellation = null;
    if (_status == GeneratedFileStatus.downloading) {
      setState(() {
        _receivedBytes = 0;
        _status = GeneratedFileStatus.consent;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleVisibilityCheck();
      return;
    }
    if (_status == GeneratedFileStatus.downloading) {
      _generation++;
      _cancelled = true;
      _autoLoadCancellation?.cancel();
      _autoLoadCancellation = null;
      if (mounted) setState(() => _status = GeneratedFileStatus.offline);
    }
  }

  void _startAutoLoad() {
    if (!mounted ||
        !_visible ||
        !_inForeground ||
        !_mayAutoLoad ||
        _file != null) {
      return;
    }
    final knownSize = widget.reference.sizeBytes;
    if (knownSize != null && knownSize > _autoLimit) return;
    if (_status == GeneratedFileStatus.downloading ||
        _status == GeneratedFileStatus.error) {
      return;
    }
    unawaited(_start(automatic: true));
  }

  Future<void> _start({required bool automatic}) async {
    if (!mounted || (automatic && (!_visible || !_inForeground))) return;
    final generation = ++_generation;
    final cancellation = automatic
        ? GeneratedMediaAutoLoadCancellation()
        : null;
    if (automatic) {
      _autoLoadCancellation?.cancel();
      _autoLoadCancellation = cancellation;
    }
    setState(() {
      _cancelled = false;
      _autoLimitExceeded = false;
      _receivedBytes = 0;
      _totalBytes = widget.reference.sizeBytes;
      _errorLabel = null;
      _status = GeneratedFileStatus.downloading;
      _file = null;
      _text = null;
    });
    try {
      Future<File> performLoad() => widget.load(
        (received, total) {
          if (!mounted || generation != _generation || _cancelled) return;
          if (automatic &&
              ((total != null && total > _autoLimit) ||
                  received > _autoLimit)) {
            _autoLimitExceeded = true;
          }
          setState(() {
            _receivedBytes = received;
            if (total != null) _totalBytes = total;
          });
        },
        () {
          return _cancelled ||
              cancellation?.isCancelled == true ||
              !mounted ||
              generation != _generation ||
              (automatic &&
                  (!_visible || !_inForeground || _autoLimitExceeded));
        },
      );
      Future<File> performLoadWithRetry() async {
        try {
          return await performLoad();
        } catch (error) {
          if (!_isTransientGeneratedMediaError(error) ||
              _cancelled ||
              cancellation?.isCancelled == true ||
              !mounted ||
              generation != _generation) {
            rethrow;
          }
          return performLoad();
        }
      }

      Future<File> slottedLoad() => automatic
          ? GeneratedMediaService.runAutoLoad(
              performLoadWithRetry,
              cancellation: cancellation,
              isCancelled: () =>
                  _cancelled ||
                  !mounted ||
                  !_visible ||
                  generation != _generation,
            )
          : performLoadWithRetry();
      // A background prefetch of this very file is running: join it rather
      // than taking a second slot or issuing a second request.
      final memoKey = _memoKey;
      final prefetching = memoKey == null
          ? null
          : MediaPrefetcher.instance.pending(memoKey);
      final file = prefetching != null
          ? (await prefetching) ?? await slottedLoad()
          : await slottedLoad();
      if (!mounted || generation != _generation || _cancelled) return;
      final length = file.lengthSync();
      if (!mounted || generation != _generation || _cancelled) return;
      if (automatic && length > _autoLimit) {
        setState(() {
          _receivedBytes = 0;
          _totalBytes = length;
          _status = GeneratedFileStatus.consent;
        });
        return;
      }
      if (widget.reference.kind == GeneratedMediaKind.file &&
          !await GeneratedMediaService.isSafeForInlinePreview(
            widget.reference,
            file,
          )) {
        if (!mounted || generation != _generation || _cancelled) return;
        setState(() {
          _errorLabel = Strings.of(context).genMediaDenied;
          _status = GeneratedFileStatus.error;
        });
        return;
      }
      final text = _readTextPreview(file, length);
      final lines = text != null && length > _textPreviewMaxBytes
          ? await _countLines(file)
          : null;
      if (!mounted || generation != _generation || _cancelled) return;
      if (memoKey != null) {
        GeneratedMediaAttachmentCard._rememberReady(
          memoKey,
          file,
          length,
          text: text,
          lines: lines,
        );
      }
      setState(() {
        _file = file;
        _text = text;
        _textLines = lines;
        _receivedBytes = length;
        _totalBytes = length;
        _status = GeneratedFileStatus.ready;
      });
    } on GeneratedMediaDownloadCancelled {
      _finishCancelled(generation);
    } catch (error) {
      if (!mounted || generation != _generation || _cancelled) return;
      if (_autoLimitExceeded) {
        setState(() => _status = GeneratedFileStatus.consent);
        return;
      }
      setState(() {
        _errorLabel = widget.errorLabelBuilder?.call(context, error);
        _status = error is SocketException
            ? GeneratedFileStatus.offline
            : GeneratedFileStatus.error;
      });
    } finally {
      if (identical(_autoLoadCancellation, cancellation)) {
        _autoLoadCancellation = null;
      }
    }
  }

  String? _readTextPreview(File file, int length) {
    final declaredPdf =
        widget.reference.mimeType == 'application/pdf' ||
        widget.reference.displayName.toLowerCase().endsWith('.pdf');
    if (widget.reference.kind != GeneratedMediaKind.file ||
        !GeneratedMediaService.allowsAutoLoad(widget.reference) ||
        declaredPdf ||
        // An HTML preview is a page, not prose: keep the downloadable card
        // instead of dumping its markup as a text preview.
        widget.reference.htmlPreview ||
        length > GeneratedMediaService.maxAutoTextBytes) {
      return null;
    }
    try {
      // M1: only the head; a 2 MB read and decode blocked the UI thread.
      final Uint8List bytes;
      final reader = file.openSync();
      try {
        bytes = reader.readSync(_textPreviewMaxBytes);
      } finally {
        reader.closeSync();
      }
      final text = utf8.decode(
        length > bytes.length ? _wholeUtf8Prefix(bytes) : bytes,
        allowMalformed: false,
      );
      if (GeneratedMediaService.isTextLike(widget.reference) ||
          !text.contains('\u0000')) {
        return text;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// [bytes] without a UTF-8 sequence cut at its end.
  static Uint8List _wholeUtf8Prefix(Uint8List bytes) {
    for (var back = 1; back <= 4 && back <= bytes.length; back++) {
      final byte = bytes[bytes.length - back];
      if (byte & 0xC0 == 0x80) continue; // continuation byte
      final need = switch (byte) {
        < 0x80 => 1,
        >= 0xF0 => 4,
        >= 0xE0 => 3,
        _ => 2,
      };
      return need > back
          ? Uint8List.sublistView(bytes, 0, bytes.length - back)
          : bytes;
    }
    return bytes;
  }

  /// Lines of [file] as [LineSplitter] counts them, read in chunks.
  static Future<int> _countLines(File file) async {
    var lines = 0;
    var last = -1;
    var afterCr = false;
    await for (final chunk in file.openRead()) {
      for (final byte in chunk) {
        if (byte == 0x0A) {
          if (!afterCr) lines++;
        } else if (byte == 0x0D) {
          lines++;
        }
        afterCr = byte == 0x0D;
        last = byte;
      }
    }
    if (last != -1 && last != 0x0A && last != 0x0D) lines++;
    return lines;
  }

  void _finishCancelled(int generation) {
    if (!mounted || generation != _generation) return;
    setState(() {
      _receivedBytes = 0;
      _status = _autoLimitExceeded
          ? GeneratedFileStatus.consent
          : GeneratedFileStatus.offline;
    });
  }

  void _cancel() {
    _generation++;
    _cancelled = true;
    _autoLoadCancellation?.cancel();
    _autoLoadCancellation = null;
    setState(() {
      _receivedBytes = 0;
      _status = GeneratedFileStatus.consent;
    });
  }

  Future<void> _openExternal() async {
    final file = _file;
    if (file == null ||
        !GeneratedMediaService.allowsAutoLoad(widget.reference)) {
      return;
    }
    try {
      await openGeneratedMediaExternally(
        file,
        mimeType: widget.reference.mimeType,
        expectedSize: _receivedBytes,
      );
    } catch (_) {
      if (mounted) _showActionError();
    }
  }

  Future<void> _share() async {
    final file = _file;
    if (file == null) return;
    try {
      await Share.shareXFiles([
        XFile(
          file.path,
          name: widget.reference.displayName,
          mimeType: widget.reference.mimeType,
        ),
      ]);
    } catch (_) {
      if (mounted) _showActionError();
    }
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    // Copied by blocks to the place chosen; a failure says why.
    await saveFileToDevice(
      context,
      file,
      name: widget.reference.displayName,
      source: 'attachment_card',
    );
  }

  Future<void> _open() async {
    final file = _file;
    if (file == null) return;
    // A host-provided opener (the chat's in-app artifact viewer) takes text
    // too, so Markdown/HTML/code render natively instead of as raw source.
    if (_text != null && widget.onOpen == null) {
      // The preview may hold only the head: the viewer gets the whole file.
      final text = _textLines == null
          ? _text!
          : utf8.decode(await file.readAsBytes(), allowMalformed: true);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => GeneratedTextViewerScreen(
            name: widget.reference.displayName,
            text: text,
            sizeBytes: _receivedBytes,
            onShare: _share,
            onSave: _save,
          ),
        ),
      );
      return;
    }
    if (widget.reference.kind == GeneratedMediaKind.audio) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => GeneratedAudioViewerScreen(
            file: file,
            name: widget.reference.displayName,
            mimeType: widget.reference.mimeType,
            sizeBytes: _receivedBytes,
            onShare: _share,
            onSave: _save,
          ),
        ),
      );
      return;
    }
    await widget.onOpen?.call(
      context,
      file,
      _receivedBytes,
      _openExternal,
      _share,
      _save,
    );
  }

  /// Skeleton or thumbnail of an image in one size-animated frame. Known
  /// dimensions make the skeleton exactly as tall as the thumbnail, so the
  /// row never moves; unknown ones reserve 16:9 and animate once. Null when
  /// the regular file card applies (over the cap, error, offline).
  Widget? _buildPresizedImage(BuildContext context, File? file) {
    Widget? child;
    if (_status == GeneratedFileStatus.ready && file != null) {
      child = widget.readyBuilder?.call(
        context,
        file,
        _receivedBytes,
        _openExternal,
        _share,
        _save,
      );
    } else {
      final knownSize = widget.reference.sizeBytes;
      final waitsForAutoLoad =
          _mayAutoLoad &&
          !_autoLimitExceeded &&
          (knownSize == null || knownSize <= _autoLimit) &&
          (_totalBytes == null || _totalBytes! <= _autoLimit);
      if (waitsForAutoLoad &&
          (_status == GeneratedFileStatus.consent ||
              _status == GeneratedFileStatus.downloading)) {
        final memoKey = _memoKey;
        final total = _totalBytes;
        child = KeyedSubtree(
          key: ValueKey<String>('generated-${widget.reference.kind.name}-card'),
          child: GeneratedImageSkeleton(
            intrinsicSize: memoKey == null
                ? null
                : MediaDimensionsCache.lookup(memoKey),
            loading: _status == GeneratedFileStatus.downloading,
            progress: total != null && total > 0 && _receivedBytes > 0
                ? (_receivedBytes / total).clamp(0.0, 1.0)
                : null,
          ),
        );
      }
    }
    if (child == null) return null;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    return AnimatedSize(
      duration: HermesMotion.base,
      curve: Curves.easeOut,
      alignment: Alignment.topLeft,
      child: child,
    );
  }

  void _showActionError() {
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).genMediaError)),
      kind: HermesNoticeKind.error,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollable?.position.removeListener(_scheduleVisibilityCheck);
    _generation++;
    _cancelled = true;
    _autoLoadCancellation?.cancel();
    _autoLoadCancellation = null;
    super.dispose();
  }

  /// The card's own content, under the size animation: whether it is on
  /// screen is measured on it, not on the animating box around it, which
  /// can still be at an old (even empty) size (gint56: a video after a
  /// zero-sized tile was never seen, so never loaded).
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'generated-media');

  @override
  Widget build(BuildContext context) {
    final card = KeyedSubtree(key: _contentKey, child: _buildCard(context));
    // F5 (REPORT-AUDITORIA-FLUIDEZ §3, A3/A4/A5): the download card giving
    // way to the file's own card (a PDF page, a player, a text or HTML
    // preview, the actions of a finished file) eases instead of jumping.
    // A presized image already does it in its own frame. Instant with
    // reduced motion.
    if (_presizedImage ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      return card;
    }
    return AnimatedSize(
      duration: HermesMotion.base,
      curve: HermesMotion.emphasized,
      alignment: AlignmentDirectional.topStart,
      child: card,
    );
  }

  Widget _buildCard(BuildContext context) {
    final file = _file;
    final mayOpen =
        file != null &&
        GeneratedMediaService.allowsAutoLoad(widget.reference) &&
        GeneratedMediaService.allowsExternalOpen(
          file,
          mimeType: widget.reference.mimeType,
        );
    if (_presizedImage) {
      final image = _buildPresizedImage(context, file);
      if (image != null) return image;
    }
    if (_status == GeneratedFileStatus.ready && file != null) {
      if (_text != null) {
        return GeneratedTextPreviewCard(
          name: widget.reference.displayName,
          text: _text!,
          lineCount: _textLines,
          sizeBytes: _receivedBytes,
          onOpen: _open,
          onShare: _share,
          onSave: _save,
        );
      }
      if (widget.reference.kind == GeneratedMediaKind.audio) {
        return GeneratedAudioPlayerCard(
          file: file,
          name: widget.reference.displayName,
          mimeType: widget.reference.mimeType,
          sizeBytes: _receivedBytes,
          onShare: _share,
          onSave: _save,
          onOpen: _open,
          playback: widget.audioPlayback,
        );
      }
      final readyBuilder = widget.readyBuilder;
      if (readyBuilder != null) {
        final ready = readyBuilder(
          context,
          file,
          _receivedBytes,
          _openExternal,
          _share,
          _save,
        );
        if (ready != null) return ready;
      }
    }
    return GeneratedFileCard(
      key: ValueKey<String>('generated-${widget.reference.kind.name}-card'),
      name: widget.reference.displayName,
      mimeType: widget.reference.mimeType,
      status: _status,
      receivedBytes: _receivedBytes,
      totalBytes: _totalBytes,
      errorLabel: _errorLabel,
      htmlPreview: widget.reference.htmlPreview,
      onDownload: () => _start(automatic: false),
      onCancel: _cancel,
      onOpen: mayOpen ? _open : null,
      onShare: file == null ? null : _share,
      onSave: file == null ? null : _save,
    );
  }
}

class GeneratedTextPreviewCard extends StatelessWidget {
  final String name;
  final String text;
  final int sizeBytes;
  final VoidCallback onOpen;
  final VoidCallback onShare;
  final VoidCallback onSave;

  /// Lines of the whole file when [text] is only its head.
  final int? lineCount;

  const GeneratedTextPreviewCard({
    super.key,
    required this.name,
    required this.text,
    this.lineCount,
    required this.sizeBytes,
    required this.onOpen,
    required this.onShare,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final lines = const LineSplitter().convert(text);
    final previewLines = lines.take(12).toList();
    final totalLines = lineCount ?? lines.length;
    final truncated = totalLines > previewLines.length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        key: const ValueKey<String>('generated-text-preview'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.divider),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${previewLines.join('\n')}${truncated ? '\n…' : ''}',
                    key: const ValueKey<String>('generated-text-preview-body'),
                    maxLines: 13,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.genMediaTextSummary(
                      totalLines,
                      _formatFileBytes(sizeBytes),
                    ),
                    style: TextStyle(color: colors.textSecondary, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_full_rounded),
                label: Text(strings.genMediaViewFullText),
              ),
              TextButton.icon(
                onPressed: onShare,
                icon: const Icon(Icons.share_outlined),
                label: Text(strings.commonShare),
              ),
              TextButton.icon(
                onPressed: onSave,
                icon: const Icon(Icons.save_alt_rounded),
                label: Text(strings.commonSave),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class GeneratedTextViewerScreen extends StatelessWidget {
  final String name;
  final String text;
  final int sizeBytes;
  final VoidCallback onShare;
  final VoidCallback onSave;

  const GeneratedTextViewerScreen({
    super.key,
    required this.name,
    required this.text,
    required this.sizeBytes,
    required this.onShare,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        // No glass (Q9-CRISTAL): nothing scrolls under it.
        glass: false,
        title: Text(name),
        actions: [
          IconButton(
            key: const ValueKey<String>('generated-text-copy'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              HermesNotice.of(context).showSnackBar(
                SnackBar(content: Text(strings.chaCopied)),
                kind: HermesNoticeKind.success,
              );
            },
            tooltip: strings.commonCopy,
            icon: const Icon(Icons.copy_rounded),
          ),
          IconButton(
            onPressed: onShare,
            tooltip: strings.commonShare,
            icon: const Icon(Icons.share_outlined),
          ),
          IconButton(
            onPressed: onSave,
            tooltip: strings.commonSave,
            icon: const Icon(Icons.save_alt_rounded),
          ),
        ],
      ),
      // SelectionArea (no SelectableText) es lo que permite seleccionar texto
      // SIN robarle el gesto de arrastre vertical al scroll: con
      // SelectableText suelto dentro de un SingleChildScrollView el propio
      // recognizer de selección ganaba el arrastre y la pantalla no
      // desplazaba nunca (reportado en el Pixel real).
      body: SafeArea(
        child: SelectionArea(
          child: SingleChildScrollView(
            key: const ValueKey<String>('generated-text-viewer-safe-area'),
            padding: const EdgeInsets.all(16),
            child: Text(
              text,
              key: const ValueKey<String>('generated-text-viewer-body'),
              style: TextStyle(
                color: colors.textPrimary,
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GeneratedPdfPreviewCard extends StatefulWidget {
  final File file;
  final String name;
  final int sizeBytes;
  final VoidCallback onOpen;
  final VoidCallback onShare;
  final VoidCallback onSave;

  /// Eases its own size changes. Off inside a card that already eases its
  /// child ([GeneratedMediaAttachmentCard]): two nested size animations
  /// retarget each other (REVIEW-T3-B).
  final bool animateSize;

  const GeneratedPdfPreviewCard({
    super.key,
    required this.file,
    required this.name,
    required this.sizeBytes,
    required this.onOpen,
    required this.onShare,
    required this.onSave,
    this.animateSize = true,
  });

  @override
  State<GeneratedPdfPreviewCard> createState() =>
      _GeneratedPdfPreviewCardState();
}

class _GeneratedPdfPreviewCardState extends State<GeneratedPdfPreviewCard> {
  static const _channel = MethodChannel('hermes/document_preview');
  late Future<({Uint8List bytes, int pageCount, double aspectRatio})?> _preview;

  @override
  void initState() {
    super.initState();
    _preview = _loadPreview();
  }

  @override
  void didUpdateWidget(covariant GeneratedPdfPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _preview = _loadPreview();
    }
  }

  Future<({Uint8List bytes, int pageCount, double aspectRatio})?>
  _loadPreview() async {
    final locator = GeneratedMediaService.cacheLocator(widget.file);
    if (locator == null) return null;
    try {
      final digest = (await sha256.bind(widget.file.openRead()).first)
          .toString();
      final response = await _channel
          .invokeMapMethod<String, dynamic>('renderPdfPage', {
            'storageKey': digest,
            'page': 0,
            'expectedSize': widget.sizeBytes,
            'expectedSha256': digest,
            'generatedConnectionKey': locator.connectionKey,
            'generatedFileKey': locator.fileKey,
          });
      final bytes = response?['pngBytes'];
      final pageCount = (response?['pageCount'] as num?)?.toInt();
      if (bytes is! Uint8List ||
          bytes.isEmpty ||
          pageCount == null ||
          pageCount <= 0) {
        return null;
      }
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final aspectRatio = image.width / image.height;
      image.dispose();
      codec.dispose();
      return (bytes: bytes, pageCount: pageCount, aspectRatio: aspectRatio);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: FutureBuilder<({Uint8List bytes, int pageCount, double aspectRatio})?>(
        future: _preview,
        builder: (context, snapshot) {
          final loading = snapshot.connectionState != ConnectionState.done;
          final preview = snapshot.data;
          final Widget card;
          if (!loading && preview == null) {
            card = GeneratedFileCard(
              name: widget.name,
              mimeType: 'application/pdf',
              status: GeneratedFileStatus.ready,
              receivedBytes: widget.sizeBytes,
              totalBytes: widget.sizeBytes,
              onDownload: widget.onOpen,
              onOpen: widget.onOpen,
              onShare: widget.onShare,
              onSave: widget.onSave,
            );
          } else {
            card = _previewCard(strings, colors, preview);
          }
          // F5 (REPORT-AUDITORIA-FLUIDEZ §3, A4): while the first page
          // renders, the card already has an A4 page, its caption and its
          // actions, so an A4 PDF takes its place without moving the chat;
          // another shape eases into its own. Instant with reduced motion.
          if (reduceMotion || !widget.animateSize) return card;
          return AnimatedSize(
            duration: HermesMotion.base,
            curve: HermesMotion.emphasized,
            alignment: AlignmentDirectional.topStart,
            child: card,
          );
        },
      ),
    );
  }

  /// The preview card; with no [preview] yet, the same card holding an A4
  /// page with a spinner and its actions not yet active.
  Widget _previewCard(
    Strings strings,
    HermesThemeColors colors,
    ({Uint8List bytes, int pageCount, double aspectRatio})? preview,
  ) {
    final aspectRatio = preview == null
        ? 1 / math.sqrt2
        : preview.aspectRatio.clamp(0.5, 2.4).toDouble();
    final previewWidth = math.min(260.0, 320.0 * aspectRatio);
    final ready = preview != null;
    final caption = ready
        ? '${widget.name} · ${strings.genMediaPages(preview.pageCount)} · ${_formatFileBytes(widget.sizeBytes)}'
        : '${widget.name} · ${_formatFileBytes(widget.sizeBytes)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          key: ValueKey<String>(
            ready ? 'generated-pdf-preview-card' : 'generated-pdf-loading',
          ),
          width: previewWidth,
          child: Material(
            color: colors.surfaceVariant,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: colors.divider),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: ready ? widget.onOpen : null,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AspectRatio(
                    aspectRatio: aspectRatio,
                    child: ColoredBox(
                      color: colors.surface,
                      child: ready
                          ? Image.memory(
                              preview.bytes,
                              key: const ValueKey<String>(
                                'generated-pdf-thumbnail',
                              ),
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            )
                          : Center(
                              // TalkBack hears what the spinner shows, as
                              // a node of its own: merged into the card it
                              // was lost in the caption's label (gint58).
                              child: Semantics(
                                container: true,
                                label: strings.genMediaLoading,
                                child: const CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                    ),
                  ),
                  Container(
                    key: const ValueKey<String>('generated-pdf-caption'),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    color: colors.surfaceVariant,
                    child: Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Wrap(
          key: const ValueKey<String>('generated-pdf-actions'),
          spacing: 4,
          children: [
            TextButton.icon(
              onPressed: ready ? widget.onOpen : null,
              icon: const Icon(Icons.open_in_full_rounded),
              label: Text(strings.commonOpen),
            ),
            TextButton.icon(
              onPressed: ready ? widget.onShare : null,
              icon: const Icon(Icons.share_outlined),
              label: Text(strings.commonShare),
            ),
            TextButton.icon(
              onPressed: ready ? widget.onSave : null,
              icon: const Icon(Icons.save_alt_rounded),
              label: Text(strings.commonSave),
            ),
          ],
        ),
      ],
    );
  }
}

abstract interface class GeneratedAudioPlayback {
  Stream<Duration> get durationChanges;
  Stream<Duration> get positionChanges;
  Stream<bool> get playingChanges;

  Future<void> play(File file);
  Future<void> resume();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> dispose();
}

final class AudioplayersGeneratedAudioPlayback
    implements GeneratedAudioPlayback {
  final AudioPlayer _player = AudioPlayer();

  @override
  Stream<Duration> get durationChanges => _player.onDurationChanged;

  @override
  Stream<Duration> get positionChanges => _player.onPositionChanged;

  @override
  Stream<bool> get playingChanges =>
      _player.onPlayerStateChanged.map((state) => state == PlayerState.playing);

  @override
  Future<void> play(File file) => _player.play(DeviceFileSource(file.path));

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> dispose() => _player.dispose();
}

class GeneratedAudioPlayerCard extends StatefulWidget {
  final File file;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final VoidCallback onShare;
  final VoidCallback onSave;
  final VoidCallback? onOpen;
  final bool showOpenAction;
  final GeneratedAudioPlayback? playback;

  /// Starts playing on the first frame: the user already asked for it.
  final bool autoplay;

  const GeneratedAudioPlayerCard({
    super.key,
    required this.file,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.onShare,
    required this.onSave,
    this.onOpen,
    this.showOpenAction = true,
    this.playback,
    this.autoplay = false,
  });

  @override
  State<GeneratedAudioPlayerCard> createState() =>
      _GeneratedAudioPlayerCardState();
}

class _GeneratedAudioPlayerCardState extends State<GeneratedAudioPlayerCard> {
  late final GeneratedAudioPlayback _playback =
      widget.playback ?? AudioplayersGeneratedAudioPlayback();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _playing = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _subscriptions.addAll([
      _playback.durationChanges.listen((value) {
        if (mounted) setState(() => _duration = value);
      }),
      _playback.positionChanges.listen((value) {
        if (mounted) setState(() => _position = value);
      }),
      _playback.playingChanges.listen((value) {
        if (mounted) setState(() => _playing = value);
      }),
    ]);
    if (widget.autoplay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_toggle());
      });
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_playback.dispose());
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _playback.pause();
      return;
    }
    if (_started) {
      await _playback.resume();
    } else {
      _started = true;
      await _playback.play(widget.file);
    }
  }

  Future<void> _seek(double milliseconds) async {
    await _playback.seek(Duration(milliseconds: milliseconds.round()));
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final durationMs = _duration.inMilliseconds;
    final positionMs = _position.inMilliseconds.clamp(0, durationMs);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        key: const ValueKey<String>('generated-audio-player'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AttachmentCard(
            name: widget.name,
            mimeType: widget.mimeType,
            sizeLabel: _formatFileBytes(widget.sizeBytes),
            onTap: widget.onOpen ?? _toggle,
          ),
          SizedBox(
            width: 300,
            child: Row(
              children: [
                Semantics(
                  label: _playing
                      ? Strings.of(context).a11yPauseAudio
                      : Strings.of(context).a11yPlayAudio,
                  button: true,
                  onTap: _toggle,
                  excludeSemantics: true,
                  child: IconButton(
                    onPressed: _toggle,
                    tooltip: _playing
                        ? Strings.of(context).a11yPauseAudio
                        : Strings.of(context).a11yPlayAudio,
                    icon: Icon(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    ),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: positionMs.toDouble(),
                    max: math.max(1, durationMs).toDouble(),
                    onChanged: durationMs > 0 ? _seek : null,
                  ),
                ),
                Text(
                  '${_formatAudioDuration(_position)} / ${_formatAudioDuration(_duration)}',
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 4,
            children: [
              if (widget.showOpenAction)
                TextButton.icon(
                  onPressed: widget.onOpen ?? _toggle,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(strings.commonOpen),
                ),
              TextButton.icon(
                onPressed: widget.onShare,
                icon: const Icon(Icons.share_outlined),
                label: Text(strings.commonShare),
              ),
              TextButton.icon(
                onPressed: widget.onSave,
                icon: const Icon(Icons.save_alt_rounded),
                label: Text(strings.commonSave),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class GeneratedAudioViewerScreen extends StatelessWidget {
  final File file;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final VoidCallback onShare;
  final VoidCallback onSave;

  const GeneratedAudioViewerScreen({
    super.key,
    required this.file,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.onShare,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        // No glass (Q9-CRISTAL): nothing scrolls under it.
        glass: false,
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            onPressed: onShare,
            tooltip: strings.commonShare,
            icon: const Icon(Icons.share_outlined),
          ),
          IconButton(
            onPressed: onSave,
            tooltip: strings.commonSave,
            icon: const Icon(Icons.save_alt_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: GeneratedAudioPlayerCard(
              file: file,
              name: name,
              mimeType: mimeType,
              sizeBytes: sizeBytes,
              onShare: onShare,
              onSave: onSave,
              showOpenAction: false,
            ),
          ),
        ),
      ),
    );
  }
}

class GeneratedFileViewerScreen extends StatelessWidget {
  final String name;
  final String mimeType;
  final int sizeBytes;
  final VoidCallback onOpenWith;
  final VoidCallback onShare;
  final VoidCallback onSave;

  const GeneratedFileViewerScreen({
    super.key,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.onOpenWith,
    required this.onShare,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final kind = attachmentKindFor(name, mimeType);
    return Scaffold(
      appBar: HermesAppBar(
        // No glass (Q9-CRISTAL): nothing scrolls under it.
        glass: false,
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            onPressed: onShare,
            tooltip: strings.commonShare,
            icon: const Icon(Icons.share_outlined),
          ),
          IconButton(
            onPressed: onSave,
            tooltip: strings.commonSave,
            icon: const Icon(Icons.save_alt_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _badgeForViewer(context, kind),
                const SizedBox(height: 20),
                SelectableText(
                  name,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$mimeType · ${_formatFileBytes(sizeBytes)}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.textSecondary),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onOpenWith,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(strings.genMediaOpenWith),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: onShare,
                      icon: const Icon(Icons.share_outlined),
                      label: Text(strings.commonShare),
                    ),
                    TextButton.icon(
                      onPressed: onSave,
                      icon: const Icon(Icons.save_alt_rounded),
                      label: Text(strings.commonSave),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _badgeForViewer(BuildContext context, AttachmentKind kind) {
    final ink = attachmentBadgeInk(kind, Theme.of(context).hermes.background);
    return Container(
      width: 88,
      height: 96,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: attachmentBadgeTint(kind),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        _badgeLabel(kind, name, Strings.of(context)),
        style: TextStyle(
          color: ink,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

String _formatAudioDuration(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Abre la imagen [file] en el visor de medios ([MediaViewerScreen]):
/// zoom, guardar, compartir y cierre por botón, gesto o atrás. [name] es el
/// nombre que enseña; sin él dice «Imagen».
Future<void> showImageViewer(BuildContext context, File file, {String? name}) {
  return showImageGallery(context, [file], names: [name]);
}

/// The media viewer over [files] (one or more images of the same reply),
/// starting at [initialIndex]. Swipe pages between them; pinch, double tap
/// or the zoom bar zooms the one on screen, and paging pauses while it is
/// zoomed. [names] are their names, in the same order, when known.
Future<void> showImageGallery(
  BuildContext context,
  List<File> files, {
  int initialIndex = 0,
  List<String?> names = const [],
}) {
  assert(files.isNotEmpty);
  final items = [
    for (var i = 0; i < files.length; i++)
      MediaViewerItem(
        kind: MediaViewerKind.image,
        file: files[i],
        name: i < names.length ? names[i] : null,
        mimeType: _imageMimeType(files[i].path),
      ),
  ];
  return showMediaViewer(context, items, initialIndex: initialIndex);
}

String _imageMimeType(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  return 'image/png';
}

/// Guarda [file] en la galería del sistema (spec 030). En Android 13+ `gal`
/// no requiere permiso para su propia media.
///
/// Compartido entre el visor de imágenes ([showImageViewer]) y la tarjeta o
/// visor a pantalla completa de vídeo generado ([isVideo]: true), para no
/// duplicar la llamada a `gal` ni el manejo de errores en cada sitio.
Future<void> saveMediaToGallery(
  BuildContext context,
  File file, {
  bool isVideo = false,
}) async {
  final s = Strings.of(context);
  final messenger = HermesNotice.of(context);
  try {
    if (isVideo) {
      await Gal.putVideo(file.path);
    } else {
      await Gal.putImage(file.path);
    }
    messenger.showSnackBar(
      SnackBar(content: Text(isVideo ? s.genVideoSaved : s.imgSavedToGallery)),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(isVideo ? s.genVideoSaveFailed : s.imgSaveFailed)),
    );
  }
}

/// Abre el selector de compartir del sistema con [file]. Vale tanto para
/// imágenes como para vídeo: `share_plus` decide el tipo por extensión.
Future<void> shareMediaFile(File file) async {
  await Share.shareXFiles([XFile(file.path)]);
}
