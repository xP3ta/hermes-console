import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hermes_android/core/design/hicons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../theme/app_theme.dart';
import '../hermes_app_bar.dart';
import 'artifact_html_policy.dart';

/// Documents the app itself writes for its locked-down WebView (a Mermaid
/// diagram, a 3D model) and the two places they are shown: a live preview
/// inside the chat ([InlineWebPreview], which keeps a still picture of the
/// drawn page) and a live, full screen one ([WebDocumentScreen]).
///
/// Nothing here reaches the network. The two libraries are packed with the
/// app (`assets/viewers/`, see THIRD_PARTY_NOTICES.md) and inlined into the
/// page; the page's own Content-Security-Policy denies every request, and the
/// WebView is configured by [configureArtifactWebView] like every other guest
/// document (no navigation, no file access, no bridge).

const String kMermaidAsset = 'assets/viewers/mermaid.min.js';
const String kModelViewerAsset = 'assets/viewers/model-viewer-umd.min.js';

/// Longest diagram source drawn; a longer fence stays a code block.
const int kMermaidMaxChars = 60000;

/// Largest 3D model embedded in a page.
const int kModelMaxBytes = 24 * 1024 * 1024;

/// Largest 3D model drawn by itself inside the chat; a larger one waits for
/// a touch and opens full screen.
const int kModelInlineMaxBytes = 8 * 1024 * 1024;

String _hex(Color c) {
  String h(double v) =>
      (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${h(c.r)}${h(c.g)}${h(c.b)}';
}

/// [value] as a JavaScript string literal that cannot close the `<script>`
/// it is written in.
String _jsString(String value) => jsonEncode(value)
    .replaceAll('</', r'<\/')
    .replaceAll('<!--', r'<\!--')
    .replaceAll(' ', r' ')
    .replaceAll(' ', r' ');

const String _lockedCsp =
    "default-src 'none'; script-src 'unsafe-inline'; "
    "style-src 'unsafe-inline'; img-src data: blob:; font-src data:; "
    "connect-src 'none'; frame-src 'none'; child-src 'none'; "
    "worker-src 'none'; object-src 'none'; form-action 'none'; "
    "base-uri 'none'";

// The model is read from a `data:` address and its textures from `blob:`
// ones the page makes itself: neither leaves the device.
const String _modelCsp =
    "default-src 'none'; script-src 'unsafe-inline'; "
    "style-src 'unsafe-inline'; img-src data: blob:; font-src data:; "
    "connect-src data: blob:; frame-src 'none'; child-src 'none'; "
    "worker-src 'none'; object-src 'none'; form-action 'none'; "
    "base-uri 'none'";

String _head(String csp, String style) =>
    '<!doctype html><html><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width,initial-scale=1">'
    '<meta http-equiv="Content-Security-Policy" content="$csp">'
    '<style>$style</style></head>';

/// A page that draws the Mermaid diagram [source]. A diagram that does not
/// parse shows the parser's message instead.
Future<String> buildMermaidDocument(
  String source, {
  required bool dark,
  required Color background,
  required Color ink,
  AssetBundle? bundle,
}) async {
  final library = await (bundle ?? rootBundle).loadString(
    kMermaidAsset,
    cache: false,
  );
  final style =
      'html,body{margin:0;background:${_hex(background)};color:${_hex(ink)}}'
      '#d{padding:12px;display:flex;justify-content:center}'
      '#d svg{max-width:100%;height:auto}'
      '#e{font:13px/1.4 monospace;white-space:pre-wrap;margin:0;padding:12px}';
  return '${_head(_lockedCsp, style)}<body><div id="d"></div>'
      '<pre id="e" hidden></pre><script>$library</script><script>'
      '(async function(){var s=${_jsString(source)};try{'
      'mermaid.initialize({startOnLoad:false,securityLevel:"strict",'
      'theme:${dark ? '"dark"' : '"default"'},'
      'fontFamily:"system-ui,sans-serif"});'
      'var r=await mermaid.render("g",s);'
      'document.getElementById("d").innerHTML=r.svg;'
      '}catch(x){var e=document.getElementById("e");e.hidden=false;'
      'e.textContent=String((x&&x.message)||x);}'
      'document.title="done";})();</script></body></html>';
}

/// True once the diagram page has drawn (or reported its error).
const String kMermaidReadyScript = 'document.title==="done"';

/// True once the model page has loaded its model.
const String kModelReadyScript =
    '!!(document.querySelector("model-viewer")||{}).loaded';

/// The model as it is drawn now, as a PNG data URL ('' while not loaded). A
/// WebGL canvas is not in the WebView's own picture, so the page hands it
/// over itself.
const String kModelCaptureScript =
    '(function(){var m=document.querySelector("model-viewer");'
    'return m&&m.loaded?m.toDataURL("image/png"):"";})()';

/// MIME type of a 3D model by its file name, or null when it is not one the
/// viewer draws (glTF binary and self-contained glTF).
String? modelMimeFor(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.glb')) return 'model/gltf-binary';
  if (lower.endsWith('.gltf')) return 'model/gltf+json';
  return null;
}

/// A page that shows the 3D model [bytes] turning slowly; it can be dragged
/// and pinched.
Future<String> buildModelDocument(
  Uint8List bytes, {
  required String mimeType,
  required Color background,
  AssetBundle? bundle,
}) async {
  final library = await (bundle ?? rootBundle).loadString(
    kModelViewerAsset,
    cache: false,
  );
  final style =
      'html,body{margin:0;height:100%;background:${_hex(background)}}'
      'model-viewer{width:100%;height:100%;--poster-color:transparent}';
  return '${_head(_modelCsp, style)}<body><script>$library</script>'
      '<model-viewer src="data:$mimeType;base64,${base64Encode(bytes)}" '
      'camera-controls auto-rotate interaction-prompt="none" '
      'shadow-intensity="0.6" touch-action="none"></model-viewer>'
      '</body></html>';
}

/// One locked-down WebView showing the page [document] returns.
class WebDocumentView extends StatefulWidget {
  const WebDocumentView({
    super.key,
    required this.document,
    this.interactive = true,
    this.settingsFor = defaultArtifactWebViewSettings,
    this.onContentHeight,
    this.onFailed,
    this.onSnapshot,
    this.readyScript,
    this.captureScript,
  });

  final Future<String> Function() document;

  /// Hears, once, a PNG of the page as drawn. Asked only when set.
  final ValueChanged<Uint8List>? onSnapshot;

  /// JavaScript expression that is true when the page has drawn; the load
  /// having finished when null.
  final String? readyScript;

  /// JavaScript expression giving the picture as a PNG data URL, for a page
  /// whose content the WebView cannot draw into a bitmap; the WebView's own
  /// picture when null.
  final String? captureScript;

  /// False for a preview inside a scrolling list: touches go to the list.
  final bool interactive;
  final ArtifactWebViewSettingsFactory settingsFor;

  /// Hears the height of the page's content, in logical pixels, a few times
  /// after it loads (a diagram that sizes itself).
  final ValueChanged<double>? onContentHeight;
  final VoidCallback? onFailed;

  @override
  State<WebDocumentView> createState() => _WebDocumentViewState();
}

class _WebDocumentViewState extends State<WebDocumentView> {
  WebViewController? _controller;
  final ArtifactHtmlNavigationPolicy _policy = ArtifactHtmlNavigationPolicy();
  final List<Timer> _timers = [];

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  final List<Completer<bool>> _waits = [];

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    for (final wait in _waits) {
      if (!wait.isCompleted) wait.complete(false);
    }
    super.dispose();
  }

  /// A pause that ends early, with false, when the view goes away (it leaves
  /// no timer behind).
  Future<bool> _pause(int milliseconds) {
    final wait = Completer<bool>();
    _waits.add(wait);
    _timers.add(
      Timer(Duration(milliseconds: milliseconds), () {
        if (!wait.isCompleted) wait.complete(mounted);
      }),
    );
    return wait.future;
  }

  Future<void> _start() async {
    try {
      final controller = WebViewController(
        onPermissionRequest: denyArtifactPermissionRequest,
      );
      await configureArtifactWebView(
        controller,
        policy: _policy,
        settingsFor: widget.settingsFor,
      );
      await controller.setBackgroundColor(const Color(0x00000000));
      final page = await widget.document();
      if (!mounted) return;
      // The page is the app's own (or already wrapped by the guard): its
      // script draws it. It still has no bridge and cannot navigate.
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.loadHtmlString(page);
      if (!mounted) return;
      setState(() => _controller = controller);
      if (widget.onSnapshot != null) {
        unawaited(_settle());
      } else if (widget.onContentHeight != null) {
        for (final ms in const [350, 900, 1800, 3200]) {
          _timers.add(
            Timer(Duration(milliseconds: ms), () => unawaited(_measure())),
          );
        }
      }
    } catch (_) {
      if (mounted) widget.onFailed?.call();
    }
  }

  static const MethodChannel _snapshots = MethodChannel(
    'hermes/webview_snapshot',
  );

  Future<bool> _truthy(String expression) async {
    final controller = _controller;
    if (controller == null) return false;
    try {
      final result = await controller.runJavaScriptReturningResult(
        '($expression)?1:0',
      );
      return result == 1 || result.toString() == '1';
    } catch (_) {
      return false;
    }
  }

  /// Waits for the page to draw, tells its height, then hands over a still
  /// picture of it.
  Future<void> _settle() async {
    final ready = widget.readyScript ?? 'document.readyState==="complete"';
    for (var i = 0; i < 40; i++) {
      if (!await _pause(250)) return;
      if (await _truthy(ready)) break;
    }
    if (!mounted) return;
    await _measure();
    // The box takes the measured height and the page paints at it.
    if (!await _pause(700)) return;
    await _measure();
    if (!await _pause(150)) return;
    final bytes = await _capture();
    if (mounted && bytes != null) widget.onSnapshot?.call(bytes);
  }

  Future<Uint8List?> _capture() async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final script = widget.captureScript;
      if (script != null) {
        var text = (await controller.runJavaScriptReturningResult(
          script,
        )).toString();
        if (text.startsWith('"') && text.endsWith('"') && text.length >= 2) {
          text = text.substring(1, text.length - 1);
        }
        const head = 'data:image/png;base64,';
        if (!text.startsWith(head)) return null;
        final bytes = base64Decode(text.substring(head.length));
        return bytes.isEmpty ? null : bytes;
      }
      final platform = controller.platform;
      if (platform is! AndroidWebViewController) return null;
      final bytes = await _snapshots.invokeMethod<Uint8List>(
        'capture',
        platform.webViewIdentifier,
      );
      return bytes == null || bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> _measure() async {
    final controller = _controller;
    if (!mounted || controller == null) return;
    try {
      final result = await controller.runJavaScriptReturningResult(
        'Math.ceil(Math.max(document.body.scrollHeight,'
        'document.body.getBoundingClientRect().height))',
      );
      final height = result is num
          ? result.toDouble()
          : double.tryParse(result.toString());
      if (mounted && height != null && height > 0) {
        widget.onContentHeight?.call(height);
      }
    } catch (_) {
      // Not measurable: the preview keeps the height it has.
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox.expand();
    final view = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerUp: (_) => _policy.registerUserTap(),
      child: WebViewWidget(
        key: const ValueKey('web-document-webview'),
        controller: controller,
      ),
    );
    return widget.interactive ? view : IgnorePointer(child: view);
  }
}

/// Full screen [WebDocumentView] under a title.
class WebDocumentScreen extends StatelessWidget {
  const WebDocumentScreen({
    super.key,
    required this.title,
    required this.document,
    this.actions,
  });

  final String title;
  final Future<String> Function() document;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: HermesAppBar(
      glass: false,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: actions,
    ),
    body: SafeArea(child: WebDocumentView(document: document)),
  );
}

/// The previews that hold a WebView now, oldest first. Each one is a whole
/// renderer surface, so only a couple live at a time. A preview that comes on
/// screen waits its turn; one the user asks for by touch takes the place of
/// the oldest.
final class _LivePreviews {
  static const int max = 2;
  static final List<_InlineWebPreviewState> _live = [];
  static final List<_InlineWebPreviewState> _waiting = [];

  /// A place for [state] if one is free; otherwise it is told when one is.
  static bool tryClaim(_InlineWebPreviewState state) {
    if (_live.contains(state)) return true;
    if (_live.length >= max) {
      _waiting
        ..remove(state)
        ..add(state);
      return false;
    }
    _waiting.remove(state);
    _live.add(state);
    return true;
  }

  static void claim(_InlineWebPreviewState state) {
    _waiting.remove(state);
    _live
      ..remove(state)
      ..add(state);
    while (_live.length > max) {
      _live.removeAt(0)._release();
    }
  }

  static void drop(_InlineWebPreviewState state) {
    _waiting.remove(state);
    if (_live.remove(state) && _waiting.isNotEmpty) {
      final next = _waiting.removeAt(0);
      scheduleMicrotask(next._maybeLoad);
    }
  }
}

/// Where the still pictures are kept between runs; the app's cache folder
/// when null. Tests set it (there is no cache folder under `flutter test`,
/// where nothing is kept on disk otherwise).
@visibleForTesting
Directory? debugPreviewSnapshotDirectory;

/// Still pictures of pages already drawn, by the key their preview gives:
/// a preview seen again shows its picture and makes no WebView. A few are
/// held in memory; all are kept in the app's private cache
/// (`preview_snapshots/`), so a chat opened again shows them at once.
final class _Snapshots {
  static const int _maxEntries = 24;
  static const int _maxBytes = 32 * 1024 * 1024;
  static const int _maxFiles = 120;
  static final Map<String, Uint8List> _byKey = {};
  static int _bytes = 0;
  static Future<Directory?>? _folder;

  static Uint8List? get(String? key) {
    if (key == null) return null;
    final hit = _byKey.remove(key);
    if (hit != null) _byKey[key] = hit;
    return hit;
  }

  static void _remember(String key, Uint8List png) {
    final old = _byKey.remove(key);
    if (old != null) _bytes -= old.length;
    _byKey[key] = png;
    _bytes += png.length;
    while (_byKey.length > _maxEntries || _bytes > _maxBytes) {
      final first = _byKey.keys.first;
      _bytes -= _byKey.remove(first)!.length;
    }
  }

  static Future<Directory?> _directory() => _folder ??= () async {
    try {
      final fixed = debugPreviewSnapshotDirectory;
      if (fixed == null && Platform.environment.containsKey('FLUTTER_TEST')) {
        return null;
      }
      final directory =
          fixed ??
          Directory('${(await getTemporaryDirectory()).path}/preview_snapshots');
      await directory.create(recursive: true);
      return directory;
    } catch (_) {
      return null;
    }
  }();

  static String _name(String key) =>
      '${sha256.convert(utf8.encode(key))}.png';

  /// The picture kept for [key] in an earlier run, if any.
  static Future<Uint8List?> load(String? key) async {
    if (key == null) return null;
    try {
      final directory = await _directory();
      if (directory == null) return null;
      final file = File('${directory.path}/${_name(key)}');
      if (!await file.exists()) return null;
      final png = await file.readAsBytes();
      if (png.isEmpty || png.length > _maxBytes ~/ 4) return null;
      _remember(key, png);
      return png;
    } catch (_) {
      return null;
    }
  }

  static void put(String? key, Uint8List png) {
    if (key == null || png.length > _maxBytes ~/ 4) return;
    _remember(key, png);
    unawaited(_store(key, png));
  }

  static Future<void> _store(String key, Uint8List png) async {
    try {
      final directory = await _directory();
      if (directory == null) return;
      await File('${directory.path}/${_name(key)}').writeAsBytes(png);
      final files = [
        await for (final entry in directory.list())
          if (entry is File) entry,
      ];
      if (files.length <= _maxFiles) return;
      final dated = [
        for (final file in files) (file: file, at: await file.lastModified()),
      ]..sort((a, b) => a.at.compareTo(b.at));
      for (final old in dated.take(files.length - _maxFiles)) {
        await old.file.delete();
      }
    } catch (_) {
      // Not kept: the page is drawn again next time.
    }
  }
}

/// Width over height of a PNG, read from its header; null when it is not one.
double? _pngAspect(Uint8List png) {
  if (png.length < 24 || png[1] != 0x50 || png[2] != 0x4E || png[3] != 0x47) {
    return null;
  }
  final data = ByteData.sublistView(png, 16, 24);
  final width = data.getUint32(0);
  final height = data.getUint32(4);
  if (width == 0 || height == 0) return null;
  return width / height;
}

/// A page shown inside the chat as soon as it is on screen and the list is
/// still: the document is drawn once in a WebView and, as soon as it has
/// drawn, replaced by a still picture of itself, so the list scrolls over an
/// image and not over a live page. A tap opens the live page full screen
/// ([onOpen]). Where no picture can be taken the live page stays, as one of
/// at most two.
class InlineWebPreview extends StatefulWidget {
  const InlineWebPreview({
    super.key,
    required this.document,
    required this.label,
    required this.icon,
    this.aspectRatio = 4 / 3,
    this.fitContent = false,
    this.onOpen,
    this.fallback,
    this.maxWidth = 640,
    this.settingsFor = defaultArtifactWebViewSettings,
    this.snapshotKey,
    this.readyScript,
    this.captureScript,
    this.autoLoad = true,
    this.resolveSnapshotKey,
  });

  final Future<String> Function() document;

  /// Gives the picture's key when it takes work to know (the digest of a
  /// file); used instead of [snapshotKey].
  final Future<String?> Function()? resolveSnapshotKey;

  /// False for a page too heavy to draw unasked: it stays a placeholder and
  /// a tap opens it full screen.
  final bool autoLoad;

  /// Names the drawn page (its source and theme): its picture is kept under
  /// this key and reused. Without it the picture lives with this widget.
  final String? snapshotKey;

  /// See [WebDocumentView.readyScript] and [WebDocumentView.captureScript].
  final String? readyScript;
  final String? captureScript;

  /// What the placeholder says («HTML», «Diagrama», «3D»).
  final String label;
  final IconData icon;
  final double aspectRatio;

  /// The box takes the height of the page's content once it is known.
  final bool fitContent;
  final VoidCallback? onOpen;

  /// Shown instead when the page cannot be made (no WebView).
  final Widget? fallback;
  final double maxWidth;
  final ArtifactWebViewSettingsFactory settingsFor;

  @override
  State<InlineWebPreview> createState() => _InlineWebPreviewState();
}

class _InlineWebPreviewState extends State<InlineWebPreview> {
  bool _live = false;
  bool _failed = false;
  bool _visible = true;
  bool _covered = false;
  double? _contentHeight;
  ScrollPosition? _position;
  Uint8List? _snapshot;
  bool _looking = false;
  String? _key;

  @override
  void initState() {
    super.initState();
    _key = widget.snapshotKey;
    final resolve = widget.resolveSnapshotKey;
    if (resolve == null) _snapshot = _Snapshots.get(_key);
    if (_snapshot == null &&
        widget.autoLoad &&
        (_key != null || resolve != null)) {
      // A picture kept by an earlier run comes first: no page is made while
      // the cache is being read.
      _looking = true;
      unawaited(_findKept(resolve));
    }
  }

  Future<void> _findKept(Future<String?> Function()? resolve) async {
    Uint8List? png;
    try {
      if (resolve != null) _key = await resolve();
      png = _Snapshots.get(_key) ?? await _Snapshots.load(_key);
    } catch (_) {
      png = null;
    }
    if (!mounted) return;
    setState(() {
      _looking = false;
      _snapshot = png;
    });
    _maybeLoad();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covered = !TickerMode.valuesOf(context).enabled;
    if (covered != _covered) {
      _covered = covered;
      if (covered) _release();
    }
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_checkVisibility);
      _position?.isScrollingNotifier.removeListener(_scrollChanged);
      _position = position?..addListener(_checkVisibility);
      position?.isScrollingNotifier.addListener(_scrollChanged);
    }
    _maybeLoad();
  }

  @override
  void dispose() {
    _position?.removeListener(_checkVisibility);
    _position?.isScrollingNotifier.removeListener(_scrollChanged);
    _LivePreviews.drop(this);
    super.dispose();
  }

  bool get _scrolling => _position?.isScrollingNotifier.value ?? false;

  void _scrollChanged() {
    if (!_scrolling) _maybeLoad();
  }

  bool get _idle =>
      !mounted ||
      _live ||
      _failed ||
      _covered ||
      !_visible ||
      _looking ||
      !widget.autoLoad ||
      _snapshot != null;

  /// Starts the page when it is on screen, the list is still and there is a
  /// free place: nothing is created while the list moves.
  void _maybeLoad() {
    if (_idle || _scrolling) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_idle || _scrolling) return;
      if (!_LivePreviews.tryClaim(this)) return;
      setState(() => _live = true);
    });
  }

  void _keep(Uint8List png) {
    _Snapshots.put(_key, png);
    if (!mounted) return;
    setState(() {
      _snapshot = png;
      _live = false;
    });
    _LivePreviews.drop(this);
  }

  void _release() {
    _LivePreviews.drop(this);
    if (!_live) return;
    if (mounted) setState(() => _live = false);
  }

  void _checkVisibility() {
    if (!mounted) return;
    final box = context.findRenderObject();
    final viewport = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        viewport is! RenderBox ||
        !viewport.attached) {
      return;
    }
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final visible = top + box.size.height > 0 && top < viewport.size.height;
    if (visible == _visible) return;
    _visible = visible;
    if (visible) {
      _maybeLoad();
    } else {
      _release();
    }
  }

  void _load() {
    if (_live || _failed || _snapshot != null) return;
    _LivePreviews.claim(this);
    setState(() => _live = true);
  }

  @override
  Widget build(BuildContext context) {
    final fallback = widget.fallback;
    if (_failed && fallback != null) return fallback;
    final colors = Theme.of(context).hermes;
    final screen = MediaQuery.sizeOf(context).height;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth.clamp(0.0, widget.maxWidth)
                : widget.maxWidth;
            // A kept picture has the shape of the box it was taken in.
            final kept = _snapshot == null ? null : _pngAspect(_snapshot!);
            final content = widget.fitContent && kept != null
                ? width / kept
                : _contentHeight;
            final height = widget.fitContent && content != null
                ? content.clamp(72.0, screen * 0.6)
                : (width / widget.aspectRatio).clamp(72.0, screen * 0.6);
            return SizedBox(
              key: const ValueKey('inline-web-preview'),
              width: width,
              height: height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceVariant,
                    border: Border.all(color: colors.divider),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_snapshot != null)
                        Image.memory(
                          _snapshot!,
                          key: const ValueKey('inline-web-preview-picture'),
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          gaplessPlayback: true,
                          excludeFromSemantics: true,
                        )
                      else if (_live && !_failed)
                        WebDocumentView(
                          document: widget.document,
                          interactive: false,
                          settingsFor: widget.settingsFor,
                          onSnapshot: _keep,
                          readyScript: widget.readyScript,
                          captureScript: widget.captureScript,
                          onContentHeight: widget.fitContent
                              ? (h) {
                                  if (_contentHeight != h) {
                                    setState(() => _contentHeight = h);
                                  }
                                }
                              : null,
                          onFailed: () => setState(() {
                            _failed = true;
                            _live = false;
                            _LivePreviews.drop(this);
                          }),
                        )
                      else
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(widget.icon, color: colors.textSecondary),
                              const SizedBox(height: 6),
                              Text(
                                widget.label,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: colors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          key: const ValueKey('inline-web-preview-tap'),
                          onTap: _live || _snapshot != null || !widget.autoLoad
                              ? widget.onOpen
                              : _load,
                        ),
                      ),
                      if ((_live || _snapshot != null) &&
                          widget.onOpen != null)
                        PositionedDirectional(
                          end: 8,
                          bottom: 8,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.background.withValues(alpha: 0.7),
                                shape: BoxShape.circle,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Icon(
                                  HIcons.open_in_full_rounded,
                                  size: 16,
                                  color: colors.textPrimary,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
