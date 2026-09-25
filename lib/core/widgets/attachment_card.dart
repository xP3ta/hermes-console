import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../models/attachment_draft.dart';
import '../services/connection_manager.dart';
import '../services/generated_media_service.dart';
import '../theme/app_theme.dart';
import 'hermes_notice.dart';

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

  bool get _showsImageStateBadge =>
      uploadState == AttachmentUploadState.uploading ||
      uploadState == AttachmentUploadState.error;

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

  const GeneratedMediaAttachmentCard({
    super.key,
    required this.reference,
    required this.autoLoad,
    required this.load,
    this.readyBuilder,
    this.onOpen,
    this.audioPlayback,
    this.errorLabelBuilder,
  });

  @override
  State<GeneratedMediaAttachmentCard> createState() =>
      _GeneratedMediaAttachmentCardState();
}

class _GeneratedMediaAttachmentCardState
    extends State<GeneratedMediaAttachmentCard>
    with WidgetsBindingObserver {
  GeneratedFileStatus _status = GeneratedFileStatus.consent;
  File? _file;
  String? _text;
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
    _scheduleVisibilityCheck();
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
      _receivedBytes = 0;
      _totalBytes = widget.reference.sizeBytes;
      _errorLabel = null;
      _status = GeneratedFileStatus.consent;
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
    final renderObject = context.findRenderObject();
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

      final file = automatic
          ? await GeneratedMediaService.runAutoLoad(
              performLoadWithRetry,
              cancellation: cancellation,
              isCancelled: () =>
                  _cancelled ||
                  !mounted ||
                  !_visible ||
                  generation != _generation,
            )
          : await performLoadWithRetry();
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
      if (!mounted || generation != _generation || _cancelled) return;
      setState(() {
        _file = file;
        _text = text;
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
      final bytes = file.readAsBytesSync();
      final text = utf8.decode(bytes, allowMalformed: false);
      if (GeneratedMediaService.isTextLike(widget.reference) ||
          !text.contains('\u0000')) {
        return text;
      }
    } on FormatException {
      return null;
    }
    return null;
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
    try {
      await FilePicker.platform.saveFile(
        dialogTitle: 'Hermes Console',
        fileName: widget.reference.displayName,
        bytes: await file.readAsBytes(),
      );
    } catch (_) {
      if (mounted) _showActionError();
    }
  }

  Future<void> _open() async {
    final file = _file;
    if (file == null) return;
    if (_text != null) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => GeneratedTextViewerScreen(
            name: widget.reference.displayName,
            text: _text!,
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

  @override
  Widget build(BuildContext context) {
    final file = _file;
    final mayOpen =
        file != null &&
        GeneratedMediaService.allowsAutoLoad(widget.reference) &&
        GeneratedMediaService.allowsExternalOpen(
          file,
          mimeType: widget.reference.mimeType,
        );
    if (_status == GeneratedFileStatus.ready && file != null) {
      if (_text != null) {
        return GeneratedTextPreviewCard(
          name: widget.reference.displayName,
          text: _text!,
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

  const GeneratedTextPreviewCard({
    super.key,
    required this.name,
    required this.text,
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
    final truncated = lines.length > previewLines.length;
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
                      lines.length,
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
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              _formatFileBytes(sizeBytes),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
            ),
          ],
        ),
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

  const GeneratedPdfPreviewCard({
    super.key,
    required this.file,
    required this.name,
    required this.sizeBytes,
    required this.onOpen,
    required this.onShare,
    required this.onSave,
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: FutureBuilder<({Uint8List bytes, int pageCount, double aspectRatio})?>(
        future: _preview,
        builder: (context, snapshot) {
          final preview = snapshot.data;
          if (snapshot.connectionState != ConnectionState.done) {
            return Container(
              key: const ValueKey<String>('generated-pdf-loading'),
              width: 260,
              height: 180,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.divider),
              ),
              child: const CircularProgressIndicator(strokeWidth: 2),
            );
          }
          if (preview == null) {
            return GeneratedFileCard(
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
          }
          final aspectRatio = preview.aspectRatio.clamp(0.5, 2.4).toDouble();
          final previewWidth = math.min(260.0, 320.0 * aspectRatio);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: const ValueKey<String>('generated-pdf-preview-card'),
                width: previewWidth,
                child: Material(
                  color: colors.surfaceVariant,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: colors.divider),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: widget.onOpen,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AspectRatio(
                          aspectRatio: aspectRatio,
                          child: ColoredBox(
                            color: colors.surface,
                            child: Image.memory(
                              preview.bytes,
                              key: const ValueKey<String>(
                                'generated-pdf-thumbnail',
                              ),
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
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
                            '${widget.name} · ${strings.genMediaPages(preview.pageCount)} · ${_formatFileBytes(widget.sizeBytes)}',
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
                    onPressed: widget.onOpen,
                    icon: const Icon(Icons.open_in_full_rounded),
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
          );
        },
      ),
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
                IconButton(
                  onPressed: _toggle,
                  icon: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
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
      appBar: AppBar(
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
      appBar: AppBar(
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
                _badgeForViewer(kind),
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

  Widget _badgeForViewer(AttachmentKind kind) {
    final color = _badgeColor(kind);
    return Container(
      width: 88,
      height: 96,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        _badgeLabel(kind, name),
        style: TextStyle(
          color: color,
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

/// Abre la imagen [file] a pantalla completa con zoom (pinch/double-tap),
/// fondo negro y cierre por toque/atrás. Visor ligero, sin dependencias extra.
Future<void> showImageViewer(BuildContext context, File file) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      barrierDismissible: true,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, anim, _) => FadeTransition(
        opacity: anim,
        child: _GeneratedImageViewer(file: file),
      ),
    ),
  );
}

class _GeneratedImageViewer extends StatefulWidget {
  final File file;

  const _GeneratedImageViewer({required this.file});

  @override
  State<_GeneratedImageViewer> createState() => _GeneratedImageViewerState();
}

class _GeneratedImageViewerState extends State<_GeneratedImageViewer> {
  final TransformationController _transformation = TransformationController();
  TapDownDetails? _doubleTapDetails;

  @override
  void dispose() {
    _transformation.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_transformation.value != Matrix4.identity()) {
      _transformation.value = Matrix4.identity();
      return;
    }
    final point = _doubleTapDetails?.localPosition ?? Offset.zero;
    _transformation.value = Matrix4.identity()
      ..translateByDouble(-point.dx * 2, -point.dy * 2, 0, 1)
      ..scaleByDouble(3, 3, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          key: const ValueKey<String>('generated-image-viewer-safe-area'),
          children: [
            Positioned.fill(
              child: GestureDetector(
                onDoubleTapDown: (details) => _doubleTapDetails = details,
                onDoubleTap: _toggleZoom,
                child: InteractiveViewer(
                  transformationController: _transformation,
                  minScale: 1,
                  maxScale: 5,
                  child: Center(
                    child: Image.file(
                      widget.file,
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
                  IconButton(
                    icon: const Icon(
                      Icons.download_rounded,
                      color: Colors.white,
                    ),
                    tooltip: Strings.of(context).imgSaveToGallery,
                    onPressed: () => saveMediaToGallery(context, widget.file),
                  ),
                  IconButton(
                    icon: const Icon(Icons.share_outlined, color: Colors.white),
                    tooltip: Strings.of(context).commonShare,
                    onPressed: () => shareMediaFile(widget.file),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: Strings.of(context).commonClose,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
