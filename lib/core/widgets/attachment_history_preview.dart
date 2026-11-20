import 'package:hermes_android/core/design/hicons.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../models/attachment_draft.dart';
import '../services/artifact_viewer_kind.dart';
import '../services/attachment_uploader.dart';
import '../services/generated_media_service.dart';
import '../theme/app_theme.dart';
import 'artifact_viewer/artifact_viewer_screen.dart';
import 'artifact_viewer/pdf_document_view.dart' show kPdfRenderDeadline;
import 'attachment_card.dart';
import 'attachment_preview.dart';
import 'hermes_app_bar.dart';
import 'hermes_notice.dart';
import 'console_loader.dart';

@visibleForTesting
const attachmentDocumentPreviewChannelName = 'hermes/document_preview';

typedef AttachmentHistoryResolver =
    Future<File?> Function(AttachmentHistoryReference reference);

/// Tarjeta de un adjunto ya enviado. Resuelve la referencia opaca de forma
/// asíncrona y solo habilita la apertura después de verificar path, tamaño y
/// SHA-256 dentro del almacén privado de Hermes.
class AttachmentHistoryCard extends StatefulWidget {
  final String name;
  final String sizeLabel;
  final AttachmentHistoryReference reference;
  final AttachmentHistoryResolver? resolver;

  const AttachmentHistoryCard({
    required this.name,
    required this.sizeLabel,
    required this.reference,
    this.resolver,
    super.key,
  });

  @override
  State<AttachmentHistoryCard> createState() => _AttachmentHistoryCardState();

  @visibleForTesting
  static void clearVerifiedCacheForTesting() =>
      _AttachmentHistoryCardState._verifiedFiles.clear();
}

class _AttachmentHistoryCardState extends State<AttachmentHistoryCard> {
  /// Verified files, by reference marker. The transcript list is unkeyed, so
  /// a new turn (or any row shift) remounts the bubble with a fresh State; a
  /// fresh State that re-ran the fs + SHA-256 check would paint the bare file
  /// card until the Future settled — the thumb "flicker" right after sending
  /// an image. A remount reads the cached File and paints the thumb on its
  /// first frame instead. Only successful verifications are cached (a null
  /// result may become available later); bounded, oldest evicted first.
  static final Map<String, File> _verifiedFiles = <String, File>{};
  static const int _verifiedFilesLimit = 64;

  late Future<File?> _resolvedFile;
  File? _syncFile;

  @override
  void initState() {
    super.initState();
    _resolvedFile = _resolve();
  }

  @override
  void didUpdateWidget(AttachmentHistoryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference.toMarker() != widget.reference.toMarker() ||
        oldWidget.resolver != widget.resolver) {
      _resolvedFile = _resolve();
    }
  }

  Future<File?> _resolve() {
    final marker = widget.reference.toMarker();
    var cached = widget.resolver == null ? _verifiedFiles[marker] : null;
    if (cached != null && !cached.existsSync()) {
      _verifiedFiles.remove(marker);
      cached = null;
    }
    _syncFile = cached;
    if (cached != null) return Future<File?>.value(cached);
    return _verify().then((file) {
      if (file != null && widget.resolver == null) _remember(marker, file);
      return file;
    });
  }

  /// The full path + size + SHA-256 check. Opening always re-runs it: the
  /// cache only shortcuts what is painted, never what is handed to a viewer.
  Future<File?> _verify() =>
      widget.resolver?.call(widget.reference) ??
      AttachmentUploader.resolveHistoryReference(widget.reference);

  static void _remember(String marker, File file) {
    _verifiedFiles.remove(marker);
    _verifiedFiles[marker] = file;
    while (_verifiedFiles.length > _verifiedFilesLimit) {
      _verifiedFiles.remove(_verifiedFiles.keys.first);
    }
  }

  Future<void> _open() async {
    final file = await _verify();
    if (!mounted) return;
    if (file == null) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(
          content: Text(Strings.of(context).chaAttachmentPreviewUnavailable),
        ),
        kind: HermesNoticeKind.warning,
      );
      return;
    }
    if (_isImage) {
      await showImageViewer(context, file);
      return;
    }
    if (artifactViewerRendersInline(
      artifactViewerKindFor(
        name: widget.name,
        mimeType: widget.reference.mimeType,
      ),
    )) {
      await openArtifactViewer(
        context,
        name: widget.name,
        mimeType: widget.reference.mimeType,
        file: file,
        sizeBytes: widget.reference.sizeBytes,
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AttachmentBytesPreviewScreen(
          name: widget.name,
          sizeLabel: widget.sizeLabel,
          reference: widget.reference,
          file: file,
        ),
      ),
    );
  }

  /// An image sent through the file picker was stored as a document; its
  /// MIME type still says it is an image, so it previews as one.
  bool get _isImage =>
      widget.reference.type == AttachmentType.image ||
      const {
        'image/jpeg',
        'image/png',
        'image/gif',
        'image/webp',
      }.contains(widget.reference.mimeType.toLowerCase());

  bool get _playsInline => switch (attachmentPreviewKindFor(
    widget.name,
    widget.reference.mimeType,
  )) {
    AttachmentPreviewKind.video || AttachmentPreviewKind.audio => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _resolvedFile,
      initialData: _syncFile,
      builder: (context, snapshot) {
        final file = snapshot.data;
        final available = file != null;
        if (file != null && _playsInline) {
          // Videos and audio play in place (poster frame, play, duration)
          // instead of opening a byte dump.
          return AttachmentPreview(
            name: widget.name,
            mimeType: widget.reference.mimeType,
            sizeLabel: widget.sizeLabel,
            file: file,
          );
        }
        final thumbnail = available && _isImage ? file : null;
        final openPreview = available ? _open : null;
        final card = AttachmentCard(
          name: widget.name,
          mimeType: widget.reference.mimeType,
          sizeLabel: widget.sizeLabel,
          thumbnailFile: thumbnail,
          onTap: openPreview,
        );
        if (!available) return card;
        return Semantics(
          button: true,
          label: Strings.of(context).chaPreviewAttachment(widget.name),
          onTap: _open,
          excludeSemantics: true,
          child: card,
        );
      },
    );
  }
}

/// Preview interna basada exclusivamente en la copia privada verificada. Texto
/// se decodifica localmente, PDF se rasteriza con PdfRenderer de Android y el
/// resto se muestra como bytes hexadecimales sin ejecutar ni exportar nada.
class AttachmentBytesPreviewScreen extends StatefulWidget {
  final String name;
  final String sizeLabel;
  final AttachmentHistoryReference reference;
  final File file;
  final VoidCallback? onOpenExternal;
  final VoidCallback? onShare;
  final VoidCallback? onSave;

  const AttachmentBytesPreviewScreen({
    required this.name,
    required this.sizeLabel,
    required this.reference,
    required this.file,
    this.onOpenExternal,
    this.onShare,
    this.onSave,
    super.key,
  });

  @override
  State<AttachmentBytesPreviewScreen> createState() =>
      _AttachmentBytesPreviewScreenState();
}

class _AttachmentBytesPreviewScreenState
    extends State<AttachmentBytesPreviewScreen> {
  late final Future<Uint8List> _bytes = widget.file.readAsBytes();

  bool get _isText => AttachmentUploader.isTextEmbeddable(
    AttachmentDraft(
      type: widget.reference.type,
      name: widget.name,
      mimeType: widget.reference.mimeType,
      sizeBytes: widget.reference.sizeBytes,
      localPath: widget.file.path,
    ),
  );

  bool _isPdf(Uint8List bytes) {
    final declaredPdf =
        widget.reference.mimeType.toLowerCase() == 'application/pdf' ||
        widget.name.toLowerCase().endsWith('.pdf');
    return declaredPdf &&
        bytes.length >= 5 &&
        bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46 &&
        bytes[4] == 0x2d;
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        // No glass (Q9-CRISTAL): nothing scrolls under it.
        glass: false,
        title: Text(widget.name),
        actions: [
          if (widget.onOpenExternal != null)
            IconButton(
              onPressed: widget.onOpenExternal,
              tooltip: strings.genMediaOpenWith,
              icon: const Icon(HIcons.open_in_new_rounded),
            ),
          if (widget.onShare != null)
            IconButton(
              onPressed: widget.onShare,
              tooltip: strings.commonShare,
              icon: const Icon(HIcons.share_outlined),
            ),
          if (widget.onSave != null)
            IconButton(
              onPressed: widget.onSave,
              tooltip: strings.commonSave,
              icon: const Icon(HIcons.save_alt_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<Uint8List>(
          future: _bytes,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConsoleLoader.large(
                      label: strings.chaAttachmentPreviewLoading,
                    ),
                  ],
                ),
              );
            }
            final bytes = snapshot.data;
            if (snapshot.hasError || bytes == null) {
              return _PreviewUnavailable(
                message: strings.chaAttachmentPreviewUnavailable,
              );
            }
            return Column(
              children: [
                _AttachmentMetadataHeader(
                  mimeType: widget.reference.mimeType,
                  sizeLabel: widget.sizeLabel,
                  digest: widget.reference.sha256Hex,
                ),
                Expanded(
                  child: _isText
                      ? _TextBytesPreview(bytes: bytes)
                      : _isPdf(bytes)
                      ? _PdfBytesPreview(
                          reference: widget.reference,
                          file: widget.file,
                          onOpenExternal: widget.onOpenExternal,
                          onShare: widget.onShare,
                          onSave: widget.onSave,
                        )
                      : _BinaryBytesPreview(bytes: bytes),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AttachmentMetadataHeader extends StatelessWidget {
  final String mimeType;
  final String sizeLabel;
  final String digest;

  const _AttachmentMetadataHeader({
    required this.mimeType,
    required this.sizeLabel,
    required this.digest,
  });

  @override
  Widget build(BuildContext context) {
    // Bug real: usaba Theme.of(context).colorScheme (Material 3 por defecto)
    // en vez del theme extension `hermes` de la app; de ahí el contraste roto.
    final colors = Theme.of(context).hermes;
    final details = [
      if (mimeType.isNotEmpty) mimeType,
      if (sizeLabel.isNotEmpty) sizeLabel,
      'SHA-256 ${digest.substring(0, 12)}…',
    ].join(' · ');
    // Metadatos en una línea, sin caja, coherente con el resto de superficies
    // rediseñadas.
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Text(
          details,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
        ),
      ),
    );
  }
}

class _TextBytesPreview extends StatelessWidget {
  final Uint8List bytes;

  const _TextBytesPreview({required this.bytes});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final text = utf8.decode(bytes, allowMalformed: true);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: SelectionArea(
            child: Text(
              text,
              style: TextStyle(
                fontFamily: 'monospace',
                height: 1.5,
                fontSize: 12.5,
                color: colors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PdfPageResult {
  final Uint8List pngBytes;
  final int pageCount;

  const _PdfPageResult({required this.pngBytes, required this.pageCount});
}

class _PdfBytesPreview extends StatefulWidget {
  final AttachmentHistoryReference reference;
  final File file;
  final VoidCallback? onOpenExternal;
  final VoidCallback? onShare;
  final VoidCallback? onSave;

  const _PdfBytesPreview({
    required this.reference,
    required this.file,
    this.onOpenExternal,
    this.onShare,
    this.onSave,
  });

  @override
  State<_PdfBytesPreview> createState() => _PdfBytesPreviewState();
}

class _PdfBytesPreviewState extends State<_PdfBytesPreview> {
  static const _channel = MethodChannel(attachmentDocumentPreviewChannelName);
  static const _maxRenderedPages = 40;

  final Map<int, Future<_PdfPageResult>> _pages = {};

  Future<_PdfPageResult> _renderPage(int page) =>
      _pages.putIfAbsent(page, () async {
        final locator = GeneratedMediaService.cacheLocator(widget.file);
        final response = await _channel
            .invokeMapMethod<String, dynamic>('renderPdfPage', {
              'storageKey': widget.reference.storageKey,
              'page': page,
              'expectedSize': widget.reference.sizeBytes,
              'expectedSha256': widget.reference.sha256Hex,
              if (locator != null) ...{
                'generatedConnectionKey': locator.connectionKey,
                'generatedFileKey': locator.fileKey,
              },
            })
            .timeout(kPdfRenderDeadline);
        final png = response?['pngBytes'];
        final count = (response?['pageCount'] as num?)?.toInt();
        if (png is! Uint8List || png.isEmpty || count == null || count <= 0) {
          throw const FormatException('invalid native PDF preview response');
        }
        return _PdfPageResult(pngBytes: png, pageCount: count);
      });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return FutureBuilder<_PdfPageResult>(
      future: _renderPage(0),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: ConsoleLoader.medium());
        }
        if (snapshot.hasError || snapshot.data == null) {
          // A PDF the renderer refuses (broken, protected) is said in
          // words, with what still works; only a renderer that did not
          // answer in time may do better on a second try.
          final timedOut = snapshot.error is TimeoutException;
          return _PdfFailure(
            detail: timedOut ? strings.vwPreviewTimedOut : null,
            onRetry: timedOut ? () => setState(_pages.clear) : null,
            onOpenExternal: widget.onOpenExternal,
            onShare: widget.onShare,
            onSave: widget.onSave,
          );
        }
        final firstPage = snapshot.data!;
        final pageCount = firstPage.pageCount
            .clamp(1, _maxRenderedPages)
            .toInt();
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          itemCount: pageCount,
          itemBuilder: (context, page) => _LazyPdfPage(
            page: page,
            pageCount: firstPage.pageCount,
            rendered: page == 0
                ? Future<_PdfPageResult>.value(firstPage)
                : _renderPage(page),
          ),
        );
      },
    );
  }
}

class _LazyPdfPage extends StatelessWidget {
  final int page;
  final int pageCount;
  final Future<_PdfPageResult> rendered;

  const _LazyPdfPage({
    required this.page,
    required this.pageCount,
    required this.rendered,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 0.72,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: colors.divider),
              ),
              child: FutureBuilder<_PdfPageResult>(
                future: rendered,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: ConsoleLoader.medium());
                  }
                  final result = snapshot.data;
                  if (snapshot.hasError || result == null) {
                    return _PreviewUnavailable(
                      message: strings.chaAttachmentPreviewUnavailable,
                    );
                  }
                  return InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 5,
                    child: Center(
                      child: Image.memory(
                        result.pngBytes,
                        key: ValueKey('attachment-pdf-page-$page'),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(strings.chaAttachmentPreviewPage(page + 1, pageCount)),
        ],
      ),
    );
  }
}

class _BinaryBytesPreview extends StatelessWidget {
  final Uint8List bytes;

  const _BinaryBytesPreview({required this.bytes});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    // Bug real: usaba Theme.of(context).colorScheme/.textTheme (Material 3
    // por defecto) en vez del theme extension `hermes`.
    final colors = Theme.of(context).hermes;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.chaAttachmentPreviewBinaryTitle,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            strings.chaAttachmentPreviewBinaryBody,
            style: TextStyle(color: colors.textSecondary),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SelectionArea(
              child: Text(
                _hexExcerpt(bytes),
                style: TextStyle(
                  fontFamily: 'monospace',
                  height: 1.45,
                  fontSize: 12,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A PDF whose pages cannot be shown: why, and the file's actions.
class _PdfFailure extends StatelessWidget {
  const _PdfFailure({
    this.detail,
    this.onRetry,
    this.onOpenExternal,
    this.onShare,
    this.onSave,
  });

  final String? detail;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenExternal;
  final VoidCallback? onShare;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final detail = this.detail;
    return Center(
      key: const ValueKey('attachment-pdf-failure'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              HIcons.file_present_outlined,
              size: 48,
              color: colors.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              strings.vwPdfFailed,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textPrimary),
            ),
            if (detail != null) ...[
              const SizedBox(height: 4),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                if (onRetry != null)
                  TextButton.icon(
                    key: const ValueKey('attachment-pdf-retry'),
                    onPressed: onRetry,
                    icon: const Icon(HIcons.refresh_rounded),
                    label: Text(strings.commonRetry),
                  ),
                if (onOpenExternal != null)
                  TextButton.icon(
                    onPressed: onOpenExternal,
                    icon: const Icon(HIcons.open_in_new_rounded),
                    label: Text(strings.genMediaOpenWith),
                  ),
                if (onShare != null)
                  TextButton.icon(
                    onPressed: onShare,
                    icon: const Icon(HIcons.share_outlined),
                    label: Text(strings.commonShare),
                  ),
                if (onSave != null)
                  TextButton.icon(
                    onPressed: onSave,
                    icon: const Icon(HIcons.save_alt_rounded),
                    label: Text(strings.commonSave),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewUnavailable extends StatelessWidget {
  final String message;

  const _PreviewUnavailable({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(HIcons.file_present_outlined, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

String _hexExcerpt(Uint8List bytes) {
  const maxBytes = 2048;
  final length = bytes.length < maxBytes ? bytes.length : maxBytes;
  final output = StringBuffer();
  for (var offset = 0; offset < length; offset += 16) {
    output.write(offset.toRadixString(16).padLeft(8, '0'));
    output.write('  ');
    final end = (offset + 16) < length ? offset + 16 : length;
    for (var index = offset; index < end; index++) {
      output.write(bytes[index].toRadixString(16).padLeft(2, '0'));
      output.write(index == offset + 7 ? '  ' : ' ');
    }
    if (end < length) output.writeln();
  }
  if (bytes.length > length) {
    output.write('\n… +${bytes.length - length} bytes');
  }
  return output.toString();
}
