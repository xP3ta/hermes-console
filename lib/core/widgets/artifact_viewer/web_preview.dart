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

import '../../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../hermes_app_bar.dart';
import 'artifact_html_policy.dart';

/// Documents the app itself writes for its locked-down WebView (a Mermaid
/// diagram, a 3D model) and the two places they are shown: a live preview
/// inside the chat ([InlineWebPreview], which keeps a still picture of the
/// drawn page) and a live, full screen one ([WebDocumentScreen]).
///
/// Nothing here reaches the network. The two libraries, and the decoders a
/// compressed model needs, are packed with the app (`assets/viewers/`, see
/// THIRD_PARTY_NOTICES.md) and inlined into the page; the page's own
/// Content-Security-Policy denies every request, and the WebView is
/// configured by [configureArtifactWebView] like every other guest document
/// (no navigation, no file access, no bridge).

const String kMermaidAsset = 'assets/viewers/mermaid.min.js';
const String kModelViewerAsset = 'assets/viewers/model-viewer-umd.min.js';

/// The decoders a compressed model needs, packed with the app next to
/// model-viewer (the very builds model-viewer 4.4.0 loads by default from
/// gstatic.com; see THIRD_PARTY_NOTICES.md). The page reads them from itself.
const String kDracoWrapperAsset = 'assets/viewers/draco_wasm_wrapper.js';
const String kDracoDecoderAsset = 'assets/viewers/draco_decoder.wasm';
const String kBasisTranscoderAsset = 'assets/viewers/basis_transcoder.js';
const String kBasisTranscoderWasmAsset =
    'assets/viewers/basis_transcoder.wasm';

/// Longest diagram source drawn; a longer fence stays a code block.
const int kMermaidMaxChars = 60000;

/// Largest 3D model embedded in a page.
const int kModelMaxBytes = 24 * 1024 * 1024;

/// Largest 3D model drawn by itself inside the chat; a larger one waits for
/// a touch and opens full screen.
const int kModelInlineMaxBytes = 8 * 1024 * 1024;

/// How long a page may take to draw before it is given up as failed.
const Duration kWebPageDeadline = Duration(seconds: 10);

/// The same for a 3D model, which is parsed and decoded on the phone.
const Duration kModelPageDeadline = Duration(seconds: 45);

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

// The model is read from a `data:` address, its textures from `blob:` ones
// and its decoders from the page itself: nothing leaves the device. A
// decoder is WebAssembly run in a worker the page makes from a `blob:`
// (three.js DRACOLoader / KTX2Loader); the meshopt one, bundled inside
// model-viewer, is switched on by a `blob:` script of the page's own. The
// Basis transcoder (embind) builds functions from strings, so a model with
// KTX2 textures alone also gets 'unsafe-eval'. Every other request is denied.
const String _modelCspHead =
    "default-src 'none'; script-src 'unsafe-inline' 'wasm-unsafe-eval'";
const String _modelCspMeshopt = ' blob:';
const String _modelCspBasis = " 'unsafe-eval'";
const String _modelCspTail =
    "; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; "
    "connect-src data: blob:; frame-src 'none'; child-src blob:; "
    "worker-src blob:; object-src 'none'; form-action 'none'; "
    "base-uri 'none'";

String _head(String csp, String style) =>
    '<!doctype html><html><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width,initial-scale=1">'
    '<meta http-equiv="Content-Security-Policy" content="$csp">'
    '<style>$style</style></head>';

/// The first script of every page the app writes: it keeps the page's state
/// in `window.__hc` (0 drawing, 1 drawn, 2 failed, with the reason). A
/// script error or a rejected promise before the page has drawn fails it;
/// once drawn, nothing changes it. A WebAssembly module the engine refuses
/// to compile is not a failure by itself: model-viewer compiles its meshopt
/// decoder up front for every model, and an engine older than
/// 'wasm-unsafe-eval' (Chromium 97) refuses it; a model that needs a decoder
/// still fails through the library's own error.
const String kPageErrorChannel = r'''
window.__hc={s:0,m:""};
window.__hcDone=function(){if(__hc.s===0)__hc.s=1;};
window.__hcFail=function(r){if(__hc.s!==0)return;
var m=(r&&(r.message||r.type))||r||"error";__hc.s=2;
__hc.m=encodeURIComponent(String(m).slice(0,300));};
addEventListener("error",function(e){__hcFail(e.error||e.message);});
addEventListener("unhandledrejection",function(e){var r=e.reason;
if(typeof WebAssembly==="object"&&r instanceof WebAssembly.CompileError)
return;__hcFail(r);});
''';

/// 1 once the page has drawn, 2 once it has failed, 0 before.
const String kPageStateScript = '(window.__hc||{}).s||0';

/// The reason the page gave for failing, URI-encoded.
const String kPageFailureScript = '(window.__hc||{}).m||""';

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
      '<pre id="e" hidden></pre><script>$kPageErrorChannel</script>'
      '<script>$library</script><script>'
      '(async function(){var s=${_jsString(source)};try{'
      'mermaid.initialize({startOnLoad:false,securityLevel:"strict",'
      'theme:${dark ? '"dark"' : '"default"'},'
      'fontFamily:"system-ui,sans-serif"});'
      'var r=await mermaid.render("g",s);'
      'document.getElementById("d").innerHTML=r.svg;'
      '}catch(x){var e=document.getElementById("e");e.hidden=false;'
      'e.textContent=String((x&&x.message)||x);}'
      'document.title="done";__hcDone();})();</script></body></html>';
}

/// True once the diagram page has drawn (or reported its error).
const String kMermaidReadyScript = 'document.title==="done"';

/// True once the model page has loaded its model (its `load` event).
const String kModelReadyScript = '($kPageStateScript)===1';

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

/// Why a file cannot be drawn as a model, known before any page is made.
enum ModelFileProblemKind {
  /// Zero bytes.
  empty,

  /// Neither a glTF binary nor glTF JSON.
  notGltf,

  /// Its buffers or images are separate files that did not come with it.
  externalFiles,
}

class ModelFileProblem implements Exception {
  const ModelFileProblem(this.kind, [this.files = const []]);

  final ModelFileProblemKind kind;

  /// The files it points to, for [ModelFileProblemKind.externalFiles].
  final List<String> files;

  @override
  String toString() => 'ModelFileProblem(${kind.name}, $files)';
}

/// The decoders a model asks for in its glTF extensions.
typedef ModelNeeds = ({bool draco, bool meshopt, bool basis});

/// Reads what [bytes] (a GLB or a glTF JSON file) asks of the viewer. Throws
/// a [ModelFileProblem] for a file that cannot be drawn at all; a file whose
/// JSON cannot be read is left for the page to report.
ModelNeeds readModelNeeds(Uint8List bytes) {
  if (bytes.isEmpty) throw const ModelFileProblem(ModelFileProblemKind.empty);
  final binary =
      bytes.length >= 4 &&
      bytes[0] == 0x67 &&
      bytes[1] == 0x6C &&
      bytes[2] == 0x54 &&
      bytes[3] == 0x46;
  Object? json;
  try {
    if (binary) {
      // Header (magic, version, length), then the JSON chunk first.
      if (bytes.length >= 20) {
        int word(int at) =>
            bytes[at] |
            bytes[at + 1] << 8 |
            bytes[at + 2] << 16 |
            bytes[at + 3] << 24;
        final length = word(12);
        // 'JSON', little-endian.
        if (word(16) == 0x4E4F534A && 20 + length <= bytes.length) {
          json = jsonDecode(
            utf8.decode(Uint8List.sublistView(bytes, 20, 20 + length)),
          );
        }
      }
    } else {
      json = jsonDecode(utf8.decode(bytes));
    }
  } on FormatException {
    json = null;
  }
  if (json is! Map<String, dynamic>) {
    if (binary) return (draco: false, meshopt: false, basis: false);
    throw const ModelFileProblem(ModelFileProblemKind.notGltf);
  }
  if (!binary && json['asset'] is! Map) {
    throw const ModelFileProblem(ModelFileProblemKind.notGltf);
  }
  final outside = <String>[];
  for (final key in const ['buffers', 'images']) {
    final list = json[key];
    if (list is! List) continue;
    for (final item in list) {
      final uri = item is Map ? item['uri'] : null;
      if (uri is String && !uri.startsWith('data:')) outside.add(uri);
    }
  }
  if (outside.isNotEmpty) {
    throw ModelFileProblem(ModelFileProblemKind.externalFiles, outside);
  }
  final names = <String>{};
  for (final key in const ['extensionsUsed', 'extensionsRequired']) {
    final list = json[key];
    if (list is List) names.addAll(list.whereType<String>());
  }
  return (
    draco: names.contains('KHR_draco_mesh_compression'),
    meshopt:
        names.contains('EXT_meshopt_compression') ||
        names.contains('KHR_meshopt_compression'),
    basis: names.contains('KHR_texture_basisu'),
  );
}

/// Makes the `<model-viewer>` once the library is in. Its settings are read
/// from `window.ModelViewerElement` when the element is made (model-viewer
/// 4.4.0, ModelViewerElementBase constructor): the decoders are served from
/// the page itself (`hc-decoder:` is answered here and nowhere else). The
/// model's load and error events end the page's state; a model that fails to
/// parse is only written to `console.error` by the library
/// (CachingGLTFLoader.preload), so an Error written there fails it too.
/// Without WebGL 2 (three.js r163 inside model-viewer 4.4.0 needs it) the
/// model would load and draw nothing: the page fails at once instead.
/// A model that needs a decoder, on an engine that cannot compile
/// WebAssembly here (one older than 'wasm-unsafe-eval', Chromium 97), fails
/// at once ("hc:wasm") instead of waiting for a worker that never answers;
/// "hc:webgl" names the missing WebGL 2. [describeWebPageFailure] words both.
/// @DECODERS@, @FILES@, @MESHOPT@ and @SRC@ are filled in by
/// [buildModelDocument].
const String _modelBootScript = r'''
(function(){
var gl=document.createElement("canvas").getContext("webgl2");
if(!gl){__hcFail("hc:webgl");return;}
var lose=gl.getExtension("WEBGL_lose_context");if(lose)lose.loseContext();
if(@DECODERS@){try{new WebAssembly.Module(new Uint8Array(
[0,97,115,109,1,0,0,0]));}catch(x){__hcFail("hc:wasm");return;}}
var files=@FILES@,base="hc-decoder:/",own=window.fetch.bind(window);
function bytes(b){var s=atob(b),a=new Uint8Array(s.length);
for(var i=0;i<s.length;i++)a[i]=s.charCodeAt(i);return a;}
window.fetch=function(input,init){
var u=typeof input==="string"?input:input instanceof URL?input.href:
(input&&input.url)||"";
if(u.indexOf(base)!==0)return own(input,init);
var f=files[u.slice(base.length)];
if(!f)return Promise.reject(new Error("decoder not packed: "+
u.slice(base.length)));
return Promise.resolve(new Response(bytes(f.b),
{status:200,headers:{"Content-Type":f.t}}));};
var c=window.ModelViewerElement;
c.dracoDecoderLocation=base+"draco/";
c.ktx2TranscoderLocation=base+"basis/";
c.lottieLoaderLocation=base+"lottie.js";
if(@MESHOPT@)c.meshoptDecoderLocation=URL.createObjectURL(
new Blob([""],{type:"text/javascript"}));
var log=console.error;
console.error=function(x){if(x instanceof Error)__hcFail(x);
return log.apply(console,arguments);};
var v=document.createElement("model-viewer");
[["camera-controls",""],["auto-rotate",""],["interaction-prompt","none"],
["shadow-intensity","0.6"],["touch-action","none"]].forEach(function(a){
v.setAttribute(a[0],a[1]);});
v.addEventListener("load",function(){__hcDone();});
v.addEventListener("error",function(e){var d=e.detail||{};
__hcFail(d.sourceError||d.type||"error");});
v.src=@SRC@;
document.body.appendChild(v);
})();
''';

/// A page that shows the 3D model [bytes] turning slowly; it can be dragged
/// and pinched. Throws a [ModelFileProblem] for a file that is not one.
Future<String> buildModelDocument(
  Uint8List bytes, {
  required String mimeType,
  required Color background,
  AssetBundle? bundle,
}) async {
  final needs = readModelNeeds(bytes);
  final assets = bundle ?? rootBundle;
  final library = await assets.loadString(kModelViewerAsset, cache: false);
  final files = <String, Map<String, String>>{};
  Future<void> pack(String name, String asset, String type) async {
    final data = await assets.load(asset);
    files[name] = {'t': type, 'b': base64Encode(Uint8List.sublistView(data))};
  }

  if (needs.draco) {
    await pack(
      'draco/draco_wasm_wrapper.js',
      kDracoWrapperAsset,
      'text/javascript',
    );
    await pack(
      'draco/draco_decoder.wasm',
      kDracoDecoderAsset,
      'application/wasm',
    );
  }
  if (needs.basis) {
    await pack(
      'basis/basis_transcoder.js',
      kBasisTranscoderAsset,
      'text/javascript',
    );
    await pack(
      'basis/basis_transcoder.wasm',
      kBasisTranscoderWasmAsset,
      'application/wasm',
    );
  }
  final csp = [
    _modelCspHead,
    if (needs.meshopt) _modelCspMeshopt,
    if (needs.basis) _modelCspBasis,
    _modelCspTail,
  ].join();
  final decoders = needs.draco || needs.meshopt || needs.basis;
  final boot = _modelBootScript
      .replaceFirst('@DECODERS@', '$decoders')
      .replaceFirst('@MESHOPT@', '${needs.meshopt}')
      .replaceFirst('@SRC@', '"data:$mimeType;base64,${base64Encode(bytes)}"')
      .replaceFirst('@FILES@', jsonEncode(files));
  final style =
      'html,body{margin:0;height:100%;background:${_hex(background)}}'
      'model-viewer{width:100%;height:100%;--poster-color:transparent}';
  return '${_head(csp, style)}<body><script>$kPageErrorChannel</script>'
      '<script>$library</script><script>$boot</script></body></html>';
}

/// Why a page did not draw.
enum WebPageFailureKind {
  /// The page could not be made (the file is not one it can show, or the
  /// WebView could not be set up).
  notMade,

  /// The page said so: a script error, a rejected promise or its library's
  /// own error ([kPageErrorChannel]).
  reported,

  /// It had not drawn by its deadline.
  timedOut,
}

class WebPageFailure {
  const WebPageFailure(this.kind, {this.detail = '', this.cause});

  final WebPageFailureKind kind;

  /// What the page said, as it said it ('' when it said nothing).
  final String detail;

  /// What kept the page from being made ([WebPageFailureKind.notMade]).
  final Object? cause;
}

/// What the user reads for [failure]: why, in a sentence, and what the page
/// itself said, if anything. [model] for a 3D model's page.
({String title, String? detail}) describeWebPageFailure(
  Strings strings,
  WebPageFailure failure, {
  bool model = false,
}) {
  final cause = failure.cause;
  if (cause is ModelFileProblem) {
    final title = switch (cause.kind) {
      ModelFileProblemKind.empty => strings.fcoEmpty,
      ModelFileProblemKind.notGltf => strings.vwModelNotGltf,
      ModelFileProblemKind.externalFiles => strings.vwModelExternal(
        cause.files.take(3).join(', '),
      ),
    };
    return (title: title, detail: null);
  }
  // What the model page names by a code (_modelBootScript).
  switch (failure.detail) {
    case 'hc:wasm':
      return (title: strings.vwModelNeedsWasm, detail: null);
    case 'hc:webgl':
      return (title: strings.vwModelNeedsWebGl, detail: null);
  }
  final title = model ? strings.vwModelFailed : strings.vwPreviewFailed;
  if (failure.kind == WebPageFailureKind.timedOut) {
    return (title: title, detail: strings.vwPreviewTimedOut);
  }
  return (title: title, detail: failure.detail.isEmpty ? null : failure.detail);
}

/// A page that did not draw: why, and a way to try again.
class WebPageFailureView extends StatelessWidget {
  const WebPageFailureView({
    super.key,
    required this.failure,
    this.model = false,
    this.onRetry,
  });

  final WebPageFailure failure;
  final bool model;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final text = describeWebPageFailure(strings, failure, model: model);
    final detail = text.detail;
    // Scaled down, never cut, in a box as small as a chat preview.
    return LayoutBuilder(
      builder: (context, constraints) => Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: constraints.maxWidth.isFinite ? constraints.maxWidth : 320,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                key: const ValueKey('web-page-failure'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    HIcons.error_outline_rounded,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    text.title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      key: const ValueKey('web-page-failure-detail'),
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (onRetry != null) ...[
                    const SizedBox(height: 4),
                    TextButton.icon(
                      key: const ValueKey('web-page-retry'),
                      onPressed: onRetry,
                      icon: const Icon(HIcons.refresh_rounded),
                      label: Text(strings.commonRetry),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One locked-down WebView showing the page [document] returns. It watches
/// the page until it has drawn: a page that fails ([kPageErrorChannel]) or
/// has not drawn by [deadline] is a [WebPageFailure], told to [onFailed] or,
/// without it, shown in place with a way to try again.
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
    this.deadline = kWebPageDeadline,
    this.model = false,
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
  final ValueChanged<WebPageFailure>? onFailed;

  /// How long the page may take to draw.
  final Duration deadline;

  /// The page draws a 3D model: a failure says so.
  final bool model;

  @override
  State<WebDocumentView> createState() => _WebDocumentViewState();
}

class _WebDocumentViewState extends State<WebDocumentView> {
  WebViewController? _controller;
  final ArtifactHtmlNavigationPolicy _policy = ArtifactHtmlNavigationPolicy();
  final List<Timer> _timers = [];
  WebPageFailure? _failure;

  /// Counts the pages made: a watch of an older one stops.
  int _run = 0;

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
    final run = ++_run;
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
      if (!mounted || run != _run) return;
      // The page is the app's own (or already wrapped by the guard): its
      // script draws it. It still has no bridge and cannot navigate.
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.loadHtmlString(page);
      if (!mounted || run != _run) return;
      setState(() => _controller = controller);
      if (widget.onSnapshot == null && widget.onContentHeight != null) {
        for (final ms in const [350, 900, 1800, 3200]) {
          _timers.add(
            Timer(Duration(milliseconds: ms), () => unawaited(_measure())),
          );
        }
      }
      unawaited(_settle(run));
    } catch (error) {
      if (mounted && run == _run) {
        _fail(WebPageFailure(WebPageFailureKind.notMade, cause: error));
      }
    }
  }

  void _fail(WebPageFailure failure) {
    if (!mounted) return;
    final onFailed = widget.onFailed;
    if (onFailed != null) {
      onFailed(failure);
      return;
    }
    setState(() {
      _failure = failure;
      _controller = null;
    });
  }

  void _retry() {
    setState(() => _failure = null);
    unawaited(_start());
  }

  static const MethodChannel _snapshots = MethodChannel(
    'hermes/webview_snapshot',
  );

  /// A page whose script is stuck does not answer: the question is dropped
  /// and the watch goes on to its deadline.
  static const Duration _answerWait = Duration(seconds: 2);

  Future<Object?> _ask(String script) async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      return await controller
          .runJavaScriptReturningResult(script)
          .timeout(_answerWait);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _truthy(String expression) async {
    final result = await _ask('($expression)?1:0');
    return result == 1 || result.toString() == '1';
  }

  /// What the page said when it failed, as plain text.
  Future<String> _failureDetail() async {
    var text = (await _ask(kPageFailureScript))?.toString() ?? '';
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        text = jsonDecode(text) as String;
      } catch (_) {
        text = text.substring(1, text.length - 1);
      }
    }
    try {
      text = Uri.decodeComponent(text);
    } catch (_) {
      // Left as it came.
    }
    return text.replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ').trim();
  }

  /// Waits for the page to draw; then, for a preview, tells its height and
  /// hands over a still picture of it. A page that fails, or has not drawn
  /// by the deadline, is a failure.
  Future<void> _settle(int run) async {
    final ready = widget.readyScript ?? 'document.readyState==="complete"';
    final ticks = (widget.deadline.inMilliseconds / 250).ceil();
    for (var i = 0; i < ticks; i++) {
      if (!await _pause(250) || run != _run) return;
      if (await _truthy('($kPageStateScript)===2')) {
        final detail = await _failureDetail();
        if (mounted && run == _run) {
          _fail(WebPageFailure(WebPageFailureKind.reported, detail: detail));
        }
        return;
      }
      if (await _truthy(ready)) {
        if (widget.onSnapshot != null) await _handOver(run);
        return;
      }
    }
    if (mounted && run == _run) {
      _fail(const WebPageFailure(WebPageFailureKind.timedOut));
    }
  }

  Future<void> _handOver(int run) async {
    await _measure();
    // The box takes the measured height and the page paints at it.
    if (!await _pause(700) || run != _run) return;
    await _measure();
    if (!await _pause(150) || run != _run) return;
    final bytes = await _capture();
    if (mounted && run == _run && bytes != null) {
      widget.onSnapshot?.call(bytes);
    }
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
    final failure = _failure;
    if (failure != null) {
      return WebPageFailureView(
        failure: failure,
        model: widget.model,
        onRetry: _retry,
      );
    }
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
    this.readyScript,
  });

  final String title;
  final Future<String> Function() document;
  final List<Widget>? actions;

  /// See [WebDocumentView.readyScript].
  final String? readyScript;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: HermesAppBar(
      glass: false,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: actions,
    ),
    body: SafeArea(
      child: WebDocumentView(document: document, readyScript: readyScript),
    ),
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

/// The cache folder the still pictures are kept under, standing for the
/// app's own (`getTemporaryDirectory`) when null. Tests set it (there is no
/// cache folder under `flutter test`, where nothing is kept on disk
/// otherwise).
@visibleForTesting
Directory? debugPreviewSnapshotDirectory;

/// The folder of the pictures, under the cache folder. Its name changes
/// whenever pictures made before can no longer be trusted: those of
/// `preview_snapshots/` were taken by builds that captured a page whatever
/// it showed after ten seconds (a grey 3D model, a blank diagram), and are
/// removed the first time the folder is looked up.
const String _snapshotFolder = 'preview_snapshots_v2';
const List<String> _retiredSnapshotFolders = ['preview_snapshots'];

/// Still pictures of pages already drawn, by the key their preview gives:
/// a preview seen again shows its picture and makes no WebView. A few are
/// held in memory; all are kept in the app's private cache
/// ([_snapshotFolder]), so a chat opened again shows them at once.
final class _Snapshots {
  static const int _maxEntries = 24;
  static const int _maxBytes = 32 * 1024 * 1024;
  static const int _maxFiles = 120;
  static final Map<String, Uint8List> _byKey = {};
  static int _bytes = 0;
  // Kept as a value, not as a future: a future kept across calls answers in
  // the zone that made it, which a later caller's zone may never run (one
  // widget test after another).
  static Directory? _folder;
  static bool _folderKnown = false;

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

  /// The look-up under way, shared by the previews that ask meanwhile;
  /// dropped once it has answered.
  static Future<Directory?>? _looking;

  static Future<Directory?> _directory() async {
    if (_folderKnown) return _folder;
    final looking = _looking ??= _findDirectory();
    try {
      return await looking;
    } finally {
      _looking = null;
    }
  }

  static Future<Directory?> _findDirectory() async {
    Directory? directory;
    try {
      final fixed = debugPreviewSnapshotDirectory;
      if (fixed != null || !Platform.environment.containsKey('FLUTTER_TEST')) {
        final root = fixed?.path ?? (await getTemporaryDirectory()).path;
        for (final retired in _retiredSnapshotFolders) {
          try {
            await Directory('$root/$retired').delete(recursive: true);
          } catch (_) {
            // Not there (already removed): nothing to clean.
          }
        }
        directory = Directory('$root/$_snapshotFolder');
        await directory.create(recursive: true);
      }
    } catch (_) {
      directory = null;
    }
    _folder = directory;
    _folderKnown = true;
    return directory;
  }

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
    this.knownSnapshotKey,
    this.deadline = kWebPageDeadline,
    this.model = false,
  });

  final Future<String> Function() document;

  /// What [resolveSnapshotKey] answered for these very bytes earlier in
  /// this run, without any work, or null. With it a picture already in
  /// memory is on the preview's first frame instead of after a placeholder.
  final String? Function()? knownSnapshotKey;

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

  /// See [WebDocumentView.deadline] and [WebDocumentView.model].
  final Duration deadline;
  final bool model;

  /// What the placeholder says («HTML», «Diagrama», «3D»).
  final String label;
  final IconData icon;
  final double aspectRatio;

  /// The box takes the height of the page's content once it is known.
  final bool fitContent;
  final VoidCallback? onOpen;

  /// Shown instead when the page does not draw; without it the box says
  /// why and offers to try again.
  final Widget? fallback;
  final double maxWidth;
  final ArtifactWebViewSettingsFactory settingsFor;

  @override
  State<InlineWebPreview> createState() => _InlineWebPreviewState();
}

class _InlineWebPreviewState extends State<InlineWebPreview> {
  bool _live = false;
  WebPageFailure? _failure;
  bool _visible = true;
  bool _covered = false;
  double? _contentHeight;
  ScrollPosition? _position;
  Uint8List? _snapshot;
  bool _looking = false;
  String? _key;

  /// The picture has been taken and is being decoded: the live page stays
  /// under it until it has a frame. Dropping the page in the same frame the
  /// picture was set left the box empty for a frame or more.
  bool _handingOver = false;

  @override
  void initState() {
    super.initState();
    _key = widget.snapshotKey;
    final resolve = widget.resolveSnapshotKey;
    if (resolve == null) {
      _snapshot = _Snapshots.get(_key);
    } else {
      String? known;
      try {
        known = widget.knownSnapshotKey?.call();
      } catch (_) {
        known = null;
      }
      final kept = _Snapshots.get(known);
      if (kept != null) {
        _key = known;
        _snapshot = kept;
      }
    }
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
      _failure != null ||
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
      _handingOver = _live;
    });
  }

  /// The picture is on screen (or cannot be drawn): the page under it goes.
  void _pictureShown() {
    if (!_handingOver) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_handingOver) return;
      _LivePreviews.drop(this);
      if (!mounted) return;
      setState(() {
        _handingOver = false;
        _live = false;
      });
    });
  }

  void _release() {
    _LivePreviews.drop(this);
    if (!_live) return;
    if (mounted) {
      setState(() {
        _live = false;
        _handingOver = false;
      });
    }
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
    if (_live || _failure != null || _snapshot != null) return;
    _LivePreviews.claim(this);
    setState(() => _live = true);
  }

  /// A page that failed is made again, at once, on a touch.
  void _retry() {
    setState(() => _failure = null);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final fallback = widget.fallback;
    final failure = _failure;
    if (failure != null && fallback != null) return fallback;
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
                      if (failure != null && _snapshot == null)
                        WebPageFailureView(
                          failure: failure,
                          model: widget.model,
                          onRetry: _retry,
                        )
                      else if (_live && (_snapshot == null || _handingOver))
                        WebDocumentView(
                          key: const ValueKey('inline-web-preview-page'),
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
                          deadline: widget.deadline,
                          model: widget.model,
                          onFailed: (failed) => setState(() {
                            _failure = failed;
                            _live = false;
                            _LivePreviews.drop(this);
                          }),
                        )
                      else if (_snapshot == null)
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
                      if (_snapshot != null)
                        Image.memory(
                          _snapshot!,
                          key: const ValueKey('inline-web-preview-picture'),
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          gaplessPlayback: true,
                          excludeFromSemantics: true,
                          frameBuilder: (context, child, frame, sync) {
                            if (sync || frame != null) _pictureShown();
                            return child;
                          },
                          errorBuilder: (context, error, stack) {
                            _pictureShown();
                            return const SizedBox.shrink();
                          },
                        ),
                      // A failure keeps its own button reachable.
                      if (failure == null)
                        Material(
                          type: MaterialType.transparency,
                          child: InkWell(
                            key: const ValueKey('inline-web-preview-tap'),
                            onTap:
                                _live || _snapshot != null || !widget.autoLoad
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
