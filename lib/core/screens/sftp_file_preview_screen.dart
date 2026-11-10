// Vista previa de un archivo remoto (SFTP) en pantalla estrecha (1.4.0,
// huecos). Copia el visor de Hermes Desktop
// (`app/chat/right-rail/preview-file.tsx`): cargando, no disponible, «parece
// un archivo binario» y «archivo grande» con «Previsualizar de todos modos»,
// imagen y texto/código; los mismos límites (512 KB de texto) y la misma
// detección de binario (`electron/main.ts`, `looksBinary`). Lo que se puede
// ver lo pinta el visor de artefactos de la app.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/artifact_viewer_kind.dart';
import '../theme/app_theme.dart';
import '../utils/ssh_error.dart';
import '../widgets/artifact_viewer/artifact_viewer_screen.dart';
import '../widgets/chat/back_to_chat_notch.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart' show HermesEmptyState;
import '../feedback/feedback_policy.dart';

/// Desktop's text preview limit (`TEXT_PREVIEW_MAX_BYTES`).
const int sftpPreviewMaxBytes = 512 * 1024;

/// Desktop's binary sniff window.
const int sftpBinarySniffBytes = 4096;

/// Desktop's `looksBinary`: a NUL byte, or more than 12 % control bytes
/// other than tab, LF and CR, in the first [sftpBinarySniffBytes].
bool sftpLooksBinary(Uint8List bytes) {
  final sample = bytes.length > sftpBinarySniffBytes
      ? Uint8List.sublistView(bytes, 0, sftpBinarySniffBytes)
      : bytes;
  if (sample.isEmpty) return false;
  var suspicious = 0;
  for (final byte in sample) {
    if (byte == 0) return true;
    if (byte < 32 && byte != 9 && byte != 10 && byte != 13) suspicious++;
  }
  return suspicious / sample.length > 0.12;
}

/// Reads the remote file: at most [maxBytes] when given, else all of it.
typedef SftpFileReader = Future<Uint8List> Function(int? maxBytes);

enum _PreviewState { loading, unavailable, binary, large, ready }

class SftpFilePreviewScreen extends StatefulWidget {
  const SftpFilePreviewScreen({
    required this.name,
    required this.read,
    this.size,
    this.onDownload,
    this.onBackToChat,
    super.key,
  });

  final String name;

  /// Size from the listing, if known.
  final int? size;
  final SftpFileReader read;

  /// Offered when there is no inline preview.
  final VoidCallback? onDownload;

  /// Set when Files was opened from a chat: the notch returns there.
  final VoidCallback? onBackToChat;

  @override
  State<SftpFilePreviewScreen> createState() => _SftpFilePreviewScreenState();
}

class _SftpFilePreviewScreenState extends State<SftpFilePreviewScreen> {
  _PreviewState _state = _PreviewState.loading;
  Uint8List _bytes = Uint8List(0);
  bool _truncated = false;
  bool _anyway = false;
  Object? _error;
  late final ArtifactViewerKind _kind = artifactViewerKindFor(
    name: widget.name,
    mimeType: '',
  );

  /// Images and PDFs are shown whole and skip the binary sniff, as on
  /// Desktop; everything else is text, cut at 512 KB.
  bool get _isMedia =>
      _kind == ArtifactViewerKind.image || _kind == ArtifactViewerKind.pdf;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final size = widget.size;
    if (!_isMedia && !_anyway && size != null && size > sftpPreviewMaxBytes) {
      setState(() => _state = _PreviewState.large);
      return;
    }
    setState(() => _state = _PreviewState.loading);
    try {
      final bytes = await widget.read(_isMedia ? null : sftpPreviewMaxBytes);
      if (!mounted) return;
      final binary = !_isMedia && !_anyway && sftpLooksBinary(bytes);
      setState(() {
        _bytes = bytes;
        _truncated =
            !_isMedia &&
            (size != null
                ? size > bytes.length
                : bytes.length >= sftpPreviewMaxBytes);
        _state = binary ? _PreviewState.binary : _PreviewState.ready;
      });
      if (!binary && _truncated) {
        AppFeedback.notify(
          context,
          FeedbackKind.routine,
          Strings.of(context).sftpPreviewTruncated,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _state = _PreviewState.unavailable;
      });
    }
  }

  void _previewAnyway() {
    _anyway = true;
    if (_state == _PreviewState.binary) {
      setState(() => _state = _PreviewState.ready);
    } else {
      _load();
    }
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final notch = widget.onBackToChat == null
        ? null
        : BackToChatNotch(
            notchKey: const ValueKey('sftp-preview-notch'),
            label: strings.brwBackToChat,
            onTap: widget.onBackToChat!,
          );

    if (_state == _PreviewState.ready) {
      // Unknown types that are not binary (or binary previewed anyway)
      // read as plain text, like Desktop's source view.
      final mime =
          _kind == ArtifactViewerKind.unsupported ? 'text/plain' : '';
      final bytes = _bytes;
      final viewer = ArtifactViewerScreen(
        key: const ValueKey('sftp-preview-viewer'),
        name: widget.name,
        mimeType: mime,
        sizeBytes: widget.size,
        loadBytes: () async => bytes,
      );
      if (notch == null) return viewer;
      return ColoredBox(
        color: colors.background,
        child: Column(
          children: [
            Expanded(child: viewer),
            SafeArea(top: false, child: notch),
          ],
        ),
      );
    }

    final Widget body = switch (_state) {
      _PreviewState.loading => Center(
        child: ConsoleLoader.large(label: strings.sftpPreviewLoading),
      ),
      _PreviewState.unavailable => HermesEmptyState(
        key: const ValueKey('sftp-preview-unavailable'),
        icon: Icons.error_outline,
        title: strings.sftpPreviewUnavailable,
        body: localizedSshError(strings, _error ?? StateError('preview')),
        primaryLabel: strings.commonClose,
        onPrimary: () => Navigator.of(context).maybePop(),
      ),
      _PreviewState.binary => HermesEmptyState(
        key: const ValueKey('sftp-preview-binary'),
        icon: Icons.warning_amber_rounded,
        title: strings.sftpPreviewBinaryTitle,
        body: strings.sftpPreviewBinaryBody(widget.name),
        primaryLabel: strings.sftpPreviewAnyway,
        onPrimary: _previewAnyway,
        secondaryLabel: widget.onDownload == null
            ? null
            : strings.commonDownload,
        onSecondary: widget.onDownload,
      ),
      _PreviewState.large => HermesEmptyState(
        key: const ValueKey('sftp-preview-large'),
        icon: Icons.warning_amber_rounded,
        title: strings.sftpPreviewLargeTitle,
        body: strings.sftpPreviewLargeBody(
          widget.name,
          _fmtSize(widget.size ?? 0),
        ),
        primaryLabel: strings.sftpPreviewAnyway,
        onPrimary: _previewAnyway,
        secondaryLabel: widget.onDownload == null
            ? null
            : strings.commonDownload,
        onSecondary: widget.onDownload,
      ),
      _PreviewState.ready => const SizedBox.shrink(),
    };
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        // No glass (Q9-CRISTAL): nothing scrolls under it.
        glass: false,
        centerTitle: false,
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(child: SingleChildScrollView(child: body)),
          ),
          if (notch != null) SafeArea(top: false, child: notch),
        ],
      ),
    );
  }
}
