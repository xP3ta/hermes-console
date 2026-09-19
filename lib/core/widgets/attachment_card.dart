import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../models/attachment_draft.dart';
import '../theme/app_theme.dart';

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
  return AttachmentKind.other;
}

/// Etiqueta corta para el badge (p. ej. "PDF", "DOC", "TXT").
String _badgeLabel(AttachmentKind kind, String name) {
  final ext = name.contains('.') ? name.split('.').last.toUpperCase() : '';
  return switch (kind) {
    AttachmentKind.pdf => 'PDF',
    AttachmentKind.doc => ext.isNotEmpty ? ext : 'DOC',
    AttachmentKind.sheet => ext.isNotEmpty ? ext : 'CSV',
    AttachmentKind.code => ext.isNotEmpty ? ext : 'CODE',
    AttachmentKind.text => ext.isNotEmpty ? ext : 'TXT',
    AttachmentKind.archive => ext.isNotEmpty ? ext : 'ZIP',
    AttachmentKind.audio => ext.isNotEmpty ? ext : 'AUDIO',
    AttachmentKind.image => 'IMG',
    AttachmentKind.other => ext.isNotEmpty ? ext : 'FILE',
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
    AttachmentKind.image => const Color(0xFF2E9E5B),
    AttachmentKind.other => const Color(0xFF8A8F98),
  };
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
  });

  @override
  Widget build(BuildContext context) {
    final kind = attachmentKindFor(name, mimeType);
    final card = kind == AttachmentKind.image && _hasThumb
        ? _imageThumb(context, kind)
        : _fileCard(context, kind);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        if (uploadState == AttachmentUploadState.uploading)
          Positioned.fill(child: _overlay(context, spinner: true)),
        if (showUploadState && kind == AttachmentKind.image && _hasThumb)
          _imageStateBadge(context),
        if (onRetry != null) _retryButton(context),
        if (onRemove != null) _removeButton(context),
      ],
    );
  }

  bool get _hasThumb =>
      thumbnailFile != null || (thumbnailUrl?.isNotEmpty ?? false);

  Widget _imageThumb(BuildContext context, AttachmentKind kind) {
    final colors = Theme.of(context).hermes;
    final img = thumbnailFile != null
        ? Image.file(
            thumbnailFile!,
            fit: BoxFit.cover,
            cacheWidth: 360,
            cacheHeight: 360,
          )
        : Image.network(
            thumbnailUrl!,
            fit: BoxFit.cover,
            cacheWidth: 360,
            cacheHeight: 360,
            errorBuilder: (_, _, _) => _fileCard(context, kind),
          );
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 120,
          height: 120,
          color: colors.surfaceVariant,
          child: img,
        ),
      ),
    );
  }

  Widget _fileCard(BuildContext context, AttachmentKind kind) {
    final colors = Theme.of(context).hermes;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _badge(kind),
            const SizedBox(width: 10),
            Flexible(
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
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _fileSubtitle(context, kind),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: uploadState == AttachmentUploadState.error
                          ? colors.error
                          : colors.textSecondary,
                      fontSize: 11,
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

  String _fileSubtitle(BuildContext context, AttachmentKind kind) {
    if (!showUploadState) {
      return '${_badgeLabel(kind, name)} · $sizeLabel';
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

  Widget _badge(AttachmentKind kind) {
    final color = _badgeColor(kind);
    return Container(
      width: 40,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _badgeLabel(kind, name),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 10,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _overlay(BuildContext context, {bool spinner = false}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
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
      top: -12,
      right: -12,
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
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(3),
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
      top: -12,
      left: -12,
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
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.divider),
                  ),
                  child: Icon(
                    Icons.refresh_rounded,
                    size: 15,
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

/// Abre la imagen [file] a pantalla completa con zoom (pinch/double-tap),
/// fondo negro y cierre por toque/atrás. Visor ligero, sin dependencias extra.
Future<void> showImageViewer(BuildContext context, File file) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      barrierDismissible: true,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, anim, _) => FadeTransition(
        opacity: anim,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => Navigator.of(ctx).pop(),
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 5,
                      child: Center(
                        child: Image.file(
                          file,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white54,
                            size: 64,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  left: 8,
                  child: Row(
                    children: [
                      // Exportar la imagen (spec 030): guardar en la galería o
                      // compartir. Acción explícita del usuario sobre su propia
                      // imagen; el resto de la app sigue sin sacar datos solo.
                      Builder(
                        builder: (innerCtx) => IconButton(
                          icon: const Icon(
                            Icons.download_rounded,
                            color: Colors.white,
                          ),
                          tooltip: Strings.of(innerCtx).imgSaveToGallery,
                          onPressed: () => saveMediaToGallery(innerCtx, file),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.share_outlined,
                          color: Colors.white,
                        ),
                        tooltip: Strings.of(ctx).commonShare,
                        onPressed: () => shareMediaFile(file),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        tooltip: Strings.of(ctx).commonClose,
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
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
  final messenger = ScaffoldMessenger.of(context);
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
