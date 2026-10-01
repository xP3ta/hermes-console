import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import 'package:webview_flutter/webview_flutter.dart';

import '../../../l10n/app_localizations.dart';
import '../../services/artifact_viewer_kind.dart';
import '../../design/modal.dart';
import '../../theme/app_theme.dart';
import '../chat/chat_markdown_body.dart';
import '../hermes_app_bar.dart';
import '../hermes_notice.dart';
import 'artifact_html_policy.dart';

/// Bytes rendered before the viewer asks the user to "Mostrar todo".
const int artifactViewerInitialRenderBytes = 1024 * 1024;

/// Markdown is laid out eagerly by flutter_markdown, so its cap is lower.
const int artifactViewerMarkdownRenderBytes = 256 * 1024;

/// Syntax colouring runs synchronously; above this the text stays mono.
const int artifactViewerHighlightBytes = 256 * 1024;

const int _maxSearchMatches = 5000;

/// Opens [ArtifactViewerScreen] full screen for a file the app already holds
/// in private storage.
Future<void> openArtifactViewer(
  BuildContext context, {
  required String name,
  required String mimeType,
  required File file,
  int? sizeBytes,
  VoidCallback? onOpenExternal,
  VoidCallback? onShare,
  VoidCallback? onSave,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => ArtifactViewerScreen(
      name: name,
      mimeType: mimeType,
      loadBytes: file.readAsBytes,
      file: file,
      sizeBytes: sizeBytes,
      onOpenExternal: onOpenExternal,
      onShare: onShare,
      onSave: onSave,
    ),
  ),
);

/// In-app, full-screen viewer for artifacts delivered in the chat.
///
/// HTML/SVG render in a locked-down system WebView (inline scripts run, as in
/// Desktop's sandboxed iframe, but there is no navigation, no network, file
/// or bridge access, and links tapped by the user open in the default
/// browser). Markdown, code and plain text render natively;
/// images zoom/pan; PDF and unknown types show their metadata with
/// "Abrir con…"/"Compartir".
class ArtifactViewerScreen extends StatefulWidget {
  const ArtifactViewerScreen({
    super.key,
    required this.name,
    required this.mimeType,
    required this.loadBytes,
    this.file,
    this.sizeBytes,
    this.onOpenExternal,
    this.onShare,
    this.onSave,
    this.launchExternalLink,
    this.webViewSettingsFor = defaultArtifactWebViewSettings,
  });

  final String name;
  final String mimeType;
  final Future<Uint8List> Function() loadBytes;

  /// Private copy backing the bytes; needed only for the image viewer.
  final File? file;
  final int? sizeBytes;
  final VoidCallback? onOpenExternal;
  final VoidCallback? onShare;
  final VoidCallback? onSave;

  /// External opener for links tapped inside an HTML document. Defaults to
  /// `launchUrl(..., mode: LaunchMode.externalApplication)`.
  final Future<bool> Function(Uri uri)? launchExternalLink;
  final ArtifactWebViewSettingsFactory webViewSettingsFor;

  @override
  State<ArtifactViewerScreen> createState() => _ArtifactViewerScreenState();
}

class _ArtifactViewerScreenState extends State<ArtifactViewerScreen> {
  final GlobalKey _menuAnchor = GlobalKey();

  Future<void> _openMenu(Strings strings) async {
    final action = await showHermesMenu<String>(
      context: context,
      anchorKey: _menuAnchor,
      surfaceKey: const ValueKey('artifact-viewer-menu-surface'),
      actions: [
        if (_isTextual)
          HermesAction(
            value: 'copy',
            icon: Icons.copy_rounded,
            label: strings.commonCopy,
          ),
        if (widget.onShare != null)
          HermesAction(
            value: 'share',
            icon: Icons.share_outlined,
            label: strings.commonShare,
          ),
        if (widget.onOpenExternal != null)
          HermesAction(
            value: 'open',
            icon: Icons.open_in_new_rounded,
            label: strings.vw1215OpenOutside,
          ),
        if (widget.onSave != null)
          HermesAction(
            value: 'save',
            icon: Icons.save_alt_rounded,
            label: strings.commonSave,
          ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'copy':
        unawaited(_copy());
      case 'share':
        widget.onShare?.call();
      case 'open':
        widget.onOpenExternal?.call();
      case 'save':
        widget.onSave?.call();
    }
  }

  late final ArtifactViewerKind _kind = artifactViewerKindFor(
    name: widget.name,
    mimeType: widget.mimeType,
  );
  late final Future<Uint8List> _bytes = widget.loadBytes();
  final GlobalKey<_TextArtifactViewState> _textKey = GlobalKey();
  bool _showSource = false;
  String? _decoded;

  bool get _isTextual => switch (_kind) {
    ArtifactViewerKind.html ||
    ArtifactViewerKind.svg ||
    ArtifactViewerKind.markdown ||
    ArtifactViewerKind.text => true,
    _ => false,
  };

  bool get _showsTextView =>
      _kind == ArtifactViewerKind.text || (_isTextual && _showSource);

  String _decode(Uint8List bytes) =>
      _decoded ??= utf8.decode(bytes, allowMalformed: true);

  Future<void> _copy() async {
    final bytes = await _bytes;
    await Clipboard.setData(ClipboardData(text: _decode(bytes)));
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(Strings.of(context).chaCopied)),
      kind: HermesNoticeKind.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_showsTextView)
            IconButton(
              key: const ValueKey('artifact-viewer-search'),
              tooltip: strings.vw1215Search,
              icon: const Icon(Icons.search_rounded),
              onPressed: () => _textKey.currentState?.openSearch(),
            ),
          if (_isTextual && _kind != ArtifactViewerKind.text)
            IconButton(
              key: const ValueKey('artifact-viewer-source-toggle'),
              tooltip: _showSource
                  ? strings.vw1215ViewRendered
                  : strings.vw1215ViewSource,
              icon: Icon(
                _showSource ? Icons.preview_outlined : Icons.code_rounded,
              ),
              onPressed: () => setState(() => _showSource = !_showSource),
            ),
          IconButton(
            key: const ValueKey('artifact-viewer-menu'),
            // Anchor for the menu surface.
            icon: KeyedSubtree(
              key: _menuAnchor,
              child: const Icon(Icons.more_vert_rounded),
            ),
            tooltip: MaterialLocalizations.of(context).showMenuTooltip,
            onPressed: () => unawaited(_openMenu(strings)),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<Uint8List>(
          future: _bytes,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final bytes = snapshot.data;
            if (snapshot.hasError || bytes == null) {
              return _FallbackCard(
                name: widget.name,
                mimeType: widget.mimeType,
                sizeBytes: widget.sizeBytes,
                message: strings.vw1215LoadFailed,
                onOpenExternal: widget.onOpenExternal,
                onShare: widget.onShare,
              );
            }
            return _buildBody(context, bytes);
          },
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, Uint8List bytes) {
    if (_showsTextView) {
      return _TextArtifactView(
        key: _textKey,
        text: _decode(bytes),
        totalBytes: bytes.length,
        language: _kind == ArtifactViewerKind.text
            ? artifactHighlightLanguage(
                name: widget.name,
                mimeType: widget.mimeType,
              )
            : (_kind == ArtifactViewerKind.markdown ? 'markdown' : 'xml'),
      );
    }
    switch (_kind) {
      case ArtifactViewerKind.html:
        return _HtmlArtifactView(
          html: _decode(bytes),
          launchExternalLink: widget.launchExternalLink,
          settingsFor: widget.webViewSettingsFor,
        );
      case ArtifactViewerKind.svg:
        return _HtmlArtifactView(
          html: _decode(bytes),
          svg: true,
          launchExternalLink: widget.launchExternalLink,
          settingsFor: widget.webViewSettingsFor,
        );
      case ArtifactViewerKind.markdown:
        return _MarkdownArtifactView(
          text: _decode(bytes),
          totalBytes: bytes.length,
        );
      case ArtifactViewerKind.image:
        return _ImageArtifactView(bytes: bytes);
      case ArtifactViewerKind.text:
      case ArtifactViewerKind.pdf:
      case ArtifactViewerKind.unsupported:
        return _FallbackCard(
          name: widget.name,
          mimeType: widget.mimeType,
          sizeBytes: widget.sizeBytes ?? bytes.length,
          message: Strings.of(context).vw1215Unsupported,
          onOpenExternal: widget.onOpenExternal,
          onShare: widget.onShare,
          onSave: widget.onSave,
        );
    }
  }
}

String formatArtifactViewerBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
  final mib = kib / 1024;
  return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
}

/// Cuts [text] to about [maxBytes] UTF-8 bytes at a line boundary.
String _prefixAtLineBoundary(String text, int maxBytes) {
  // Code units over-approximate bytes for ASCII and under-approximate them
  // for multi-byte text; either way the cut stays near the budget.
  var end = math.min(text.length, maxBytes);
  final newline = text.lastIndexOf('\n', end);
  if (newline > end ~/ 2) end = newline;
  return text.substring(0, end);
}

class _TruncationBanner extends StatelessWidget {
  const _TruncationBanner({
    required this.shownBytes,
    required this.totalBytes,
    required this.onShowAll,
  });

  final int shownBytes;
  final int totalBytes;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Container(
      key: const ValueKey('artifact-viewer-truncated'),
      width: double.infinity,
      color: colors.surfaceVariant,
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              strings.vw1215Truncated(
                formatArtifactViewerBytes(shownBytes),
                formatArtifactViewerBytes(totalBytes),
              ),
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
          ),
          TextButton(
            key: const ValueKey('artifact-viewer-show-all'),
            onPressed: onShowAll,
            child: Text(strings.vw1215ShowAll),
          ),
        ],
      ),
    );
  }
}

// ── HTML / SVG ────────────────────────────────────────────────────────────

class _HtmlArtifactView extends StatefulWidget {
  const _HtmlArtifactView({
    required this.html,
    required this.settingsFor,
    this.svg = false,
    this.launchExternalLink,
  });

  final String html;
  final bool svg;
  final Future<bool> Function(Uri uri)? launchExternalLink;
  final ArtifactWebViewSettingsFactory settingsFor;

  @override
  State<_HtmlArtifactView> createState() => _HtmlArtifactViewState();
}

class _HtmlArtifactViewState extends State<_HtmlArtifactView> {
  late final ArtifactHtmlNavigationPolicy _policy =
      ArtifactHtmlNavigationPolicy(launchExternal: _launch);
  late final WebViewController _controller = WebViewController(
    onPermissionRequest: denyArtifactPermissionRequest,
  );
  Future<void> _pending = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _pending = _configureAndLoad();
  }

  Future<bool> _launch(Uri uri) async {
    final launcher = widget.launchExternalLink ?? launchArtifactLinkExternally;
    final ok = await launcher(uri);
    if (!ok && mounted) {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).vw1215LinkOpenFailed)),
        kind: HermesNoticeKind.warning,
      );
    }
    return ok;
  }

  Future<void> _configureAndLoad() async {
    await configureArtifactWebView(
      _controller,
      policy: _policy,
      settingsFor: widget.settingsFor,
    );
    await _load();
  }

  /// Inline scripts always run for HTML (never for SVG, which is embedded as
  /// an image). Isolation comes from [configureArtifactWebView] and the guard
  /// document, not from asking the user: see [ArtifactHtmlNavigationPolicy].
  Future<void> _load() async {
    final scripts = !widget.svg;
    await _controller.setJavaScriptMode(
      scripts ? JavaScriptMode.unrestricted : JavaScriptMode.disabled,
    );
    await _controller.loadHtmlString(
      widget.svg
          ? buildGuardedSvgHtml(widget.html)
          : buildGuardedArtifactHtml(widget.html, scriptsEnabled: scripts),
    );
  }

  @override
  void didUpdateWidget(covariant _HtmlArtifactView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      _pending = _pending.then((_) => _load());
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerUp: (_) => _policy.registerUserTap(),
    child: WebViewWidget(
      key: const ValueKey('artifact-viewer-webview'),
      controller: _controller,
    ),
  );
}

// ── Markdown ──────────────────────────────────────────────────────────────

class _MarkdownArtifactView extends StatefulWidget {
  const _MarkdownArtifactView({required this.text, required this.totalBytes});

  final String text;
  final int totalBytes;

  @override
  State<_MarkdownArtifactView> createState() => _MarkdownArtifactViewState();
}

class _MarkdownArtifactViewState extends State<_MarkdownArtifactView> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final capped =
        !_showAll && widget.totalBytes > artifactViewerMarkdownRenderBytes;
    final data = capped
        ? _prefixAtLineBoundary(widget.text, artifactViewerMarkdownRenderBytes)
        : widget.text;
    return Column(
      children: [
        if (capped)
          _TruncationBanner(
            shownBytes: utf8.encode(data).length,
            totalBytes: widget.totalBytes,
            onShowAll: () => setState(() => _showAll = true),
          ),
        Expanded(
          child: SingleChildScrollView(
            key: const ValueKey('artifact-viewer-markdown'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: ChatMarkdownBody(data: data),
          ),
        ),
      ],
    );
  }
}

// ── Images ────────────────────────────────────────────────────────────────

class _ImageArtifactView extends StatelessWidget {
  const _ImageArtifactView({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: InteractiveViewer(
      key: const ValueKey('artifact-viewer-image'),
      minScale: 1,
      maxScale: 8,
      child: Center(
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, _, _) => Icon(
            Icons.broken_image_outlined,
            size: 48,
            color: Theme.of(context).hermes.textSecondary,
          ),
        ),
      ),
    ),
  );
}

// ── Fallback (PDF / unknown) ──────────────────────────────────────────────

class _FallbackCard extends StatelessWidget {
  const _FallbackCard({
    required this.name,
    required this.mimeType,
    required this.message,
    this.sizeBytes,
    this.onOpenExternal,
    this.onShare,
    this.onSave,
  });

  final String name;
  final String mimeType;
  final int? sizeBytes;
  final String message;
  final VoidCallback? onOpenExternal;
  final VoidCallback? onShare;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final size = sizeBytes;
    return Center(
      key: const ValueKey('artifact-viewer-fallback'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 56,
              color: colors.textSecondary,
            ),
            const SizedBox(height: 16),
            SelectableText(
              name,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              [
                if (mimeType.isNotEmpty) mimeType,
                if (size != null) formatArtifactViewerBytes(size),
              ].join(' · '),
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 20),
            if (onOpenExternal != null)
              FilledButton.icon(
                key: const ValueKey('artifact-viewer-open-with'),
                onPressed: onOpenExternal,
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(strings.genMediaOpenWith),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (onShare != null)
                  TextButton.icon(
                    onPressed: onShare,
                    icon: const Icon(Icons.share_outlined),
                    label: Text(strings.commonShare),
                  ),
                if (onSave != null)
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
    );
  }
}

// ── Code / text ───────────────────────────────────────────────────────────

/// A flat run of text with an optional syntax colour, used to split a
/// highlighted document into lines.
typedef _Run = ({String text, Color? color});

class _SearchMatch {
  const _SearchMatch(this.line, this.start);

  final int line;
  final int start;
}

class _TextArtifactView extends StatefulWidget {
  const _TextArtifactView({
    super.key,
    required this.text,
    required this.totalBytes,
    this.language,
  });

  final String text;
  final int totalBytes;
  final String? language;

  @override
  State<_TextArtifactView> createState() => _TextArtifactViewState();
}

class _TextArtifactViewState extends State<_TextArtifactView> {
  final ScrollController _vertical = ScrollController();
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  bool _showAll = false;
  bool _searching = false;
  late List<String> _lines;
  List<List<_Run>>? _highlighted;
  int _shownBytes = 0;
  List<_SearchMatch> _matches = const [];
  int _current = 0;

  bool get _capped =>
      !_showAll && widget.totalBytes > artifactViewerInitialRenderBytes;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(covariant _TextArtifactView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _prepare();
  }

  void _prepare() {
    final text = _capped
        ? _prefixAtLineBoundary(widget.text, artifactViewerInitialRenderBytes)
        : widget.text;
    _shownBytes = _capped ? utf8.encode(text).length : widget.totalBytes;
    _lines = const LineSplitter().convert(text);
    if (_lines.isEmpty) _lines = const [''];
    _highlighted = text.length <= artifactViewerHighlightBytes
        ? _highlightLines(text, widget.language)
        : null;
    _recomputeMatches();
  }

  void openSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _queryFocus.requestFocus();
    });
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _query.clear();
      _matches = const [];
      _current = 0;
    });
  }

  void _recomputeMatches() {
    final query = _query.text.toLowerCase();
    if (query.isEmpty) {
      _matches = const [];
      _current = 0;
      return;
    }
    final matches = <_SearchMatch>[];
    for (var i = 0; i < _lines.length; i++) {
      final line = _lines[i].toLowerCase();
      var from = 0;
      while (true) {
        final at = line.indexOf(query, from);
        if (at < 0) break;
        matches.add(_SearchMatch(i, at));
        if (matches.length >= _maxSearchMatches) break;
        from = at + query.length;
      }
      if (matches.length >= _maxSearchMatches) break;
    }
    _matches = matches;
    _current = 0;
  }

  void _onQueryChanged(String _) {
    setState(_recomputeMatches);
    _revealCurrent();
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _current = (_current + delta) % _matches.length;
      if (_current < 0) _current += _matches.length;
    });
    _revealCurrent();
  }

  double _lineExtent(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(13) * 1.45).ceilToDouble();

  void _revealCurrent() {
    if (_matches.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vertical.hasClients) return;
      final extent = _lineExtent(context);
      final position = _vertical.position;
      final target =
          (_matches[_current].line * extent - position.viewportDimension / 3)
              .clamp(0.0, position.maxScrollExtent);
      _vertical.jumpTo(target);
    });
  }

  @override
  void dispose() {
    _vertical.dispose();
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final extent = _lineExtent(context);
    final style = TextStyle(
      color: colors.textPrimary,
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.45,
    );
    final longest = _lines.fold<int>(0, (m, l) => math.max(m, l.length));
    final charWidth = MediaQuery.textScalerOf(context).scale(13) * 0.62;
    final contentWidth = math.min(longest * charWidth + 32, 20000.0);
    final currentMatch = _matches.isEmpty ? null : _matches[_current];
    return Column(
      children: [
        if (_capped)
          _TruncationBanner(
            shownBytes: _shownBytes,
            totalBytes: widget.totalBytes,
            onShowAll: () => setState(() {
              _showAll = true;
              _prepare();
            }),
          ),
        if (_searching)
          Container(
            color: colors.surfaceVariant,
            padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('artifact-viewer-search-field'),
                    controller: _query,
                    focusNode: _queryFocus,
                    onChanged: _onQueryChanged,
                    onSubmitted: (_) => _step(1),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: strings.vw1215Search,
                    ),
                  ),
                ),
                Text(
                  _query.text.isEmpty
                      ? ''
                      : _matches.isEmpty
                      ? strings.vw1215NoMatches
                      : strings.vw1215SearchCount(
                          _current + 1,
                          _matches.length,
                        ),
                  key: const ValueKey('artifact-viewer-search-count'),
                  style: TextStyle(color: colors.textSecondary, fontSize: 12),
                ),
                IconButton(
                  key: const ValueKey('artifact-viewer-search-prev'),
                  tooltip: strings.vw1215PreviousMatch,
                  onPressed: _matches.isEmpty ? null : () => _step(-1),
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                ),
                IconButton(
                  key: const ValueKey('artifact-viewer-search-next'),
                  tooltip: strings.vw1215NextMatch,
                  onPressed: _matches.isEmpty ? null : () => _step(1),
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
                IconButton(
                  tooltip: strings.vw1215CloseSearch,
                  onPressed: _closeSearch,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => SelectionArea(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(constraints.maxWidth, contentWidth),
                  child: ListView.builder(
                    key: const ValueKey('artifact-viewer-text'),
                    controller: _vertical,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    itemExtent: extent,
                    itemCount: _lines.length,
                    itemBuilder: (context, index) => Text.rich(
                      _lineSpan(index, currentMatch, colors),
                      key: ValueKey('artifact-viewer-line-$index'),
                      style: style,
                      maxLines: 1,
                      softWrap: false,
                      strutStyle: const StrutStyle(
                        fontSize: 13,
                        height: 1.45,
                        forceStrutHeight: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  TextSpan _lineSpan(
    int index,
    _SearchMatch? currentMatch,
    HermesThemeColors colors,
  ) {
    final line = _lines[index];
    final query = _query.text;
    if (query.isNotEmpty && line.toLowerCase().contains(query.toLowerCase())) {
      final lower = line.toLowerCase();
      final q = query.toLowerCase();
      final spans = <TextSpan>[];
      var from = 0;
      while (true) {
        final at = lower.indexOf(q, from);
        if (at < 0) break;
        if (at > from) spans.add(TextSpan(text: line.substring(from, at)));
        final isCurrent =
            currentMatch != null &&
            currentMatch.line == index &&
            currentMatch.start == at;
        spans.add(
          TextSpan(
            text: line.substring(at, at + q.length),
            style: TextStyle(
              backgroundColor: isCurrent
                  ? colors.accent
                  : colors.accent.withValues(alpha: 0.3),
              color: isCurrent ? colors.onAccent : null,
            ),
          ),
        );
        from = at + q.length;
      }
      if (from < line.length) spans.add(TextSpan(text: line.substring(from)));
      return TextSpan(children: spans);
    }
    final runs = _highlighted;
    if (runs == null || index >= runs.length) return TextSpan(text: line);
    return TextSpan(
      children: [
        for (final run in runs[index])
          TextSpan(
            text: run.text,
            style: run.color == null ? null : TextStyle(color: run.color),
          ),
      ],
    );
  }
}

/// Highlights [text] as one document (so multi-line strings/comments keep
/// their colour) and splits the coloured runs into lines.
List<List<_Run>>? _highlightLines(String text, String? language) {
  if (language == null || text.isEmpty) return null;
  List<Node>? nodes;
  try {
    nodes = highlight.parse(text, language: language).nodes;
  } catch (_) {
    return null;
  }
  if (nodes == null || nodes.isEmpty) return null;
  final runs = <_Run>[];
  void walk(List<Node> list, Color? inherited) {
    for (final node in list) {
      final color = _syntaxColor(node.className) ?? inherited;
      final value = node.value;
      if (value != null) {
        runs.add((text: value, color: color));
      } else if (node.children != null) {
        walk(node.children!, color);
      }
    }
  }

  walk(nodes, null);
  final lines = <List<_Run>>[<_Run>[]];
  for (final run in runs) {
    final parts = run.text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) lines.add(<_Run>[]);
      final part = parts[i].replaceAll('\r', '');
      if (part.isNotEmpty) lines.last.add((text: part, color: run.color));
    }
  }
  return lines;
}

Color? _syntaxColor(String? cls) => switch (cls) {
  'keyword' ||
  'built_in' ||
  'literal' ||
  'type' ||
  'meta' ||
  'meta-keyword' ||
  'selector-tag' ||
  'tag' ||
  'name' => const Color(0xFFE8821C),
  'string' ||
  'regexp' ||
  'symbol' ||
  'template-string' ||
  'addition' ||
  'attr' ||
  'attribute' => const Color(0xFF6BBF59),
  'comment' || 'quote' || 'deletion' => const Color(0xFF7A7A7A),
  'number' => const Color(0xFF9CB98A),
  'title' || 'function' || 'section' => const Color(0xFFDCB67A),
  _ => null,
};
