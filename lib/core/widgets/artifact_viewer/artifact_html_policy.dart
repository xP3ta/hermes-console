import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Security policy of the in-app HTML/SVG artifact viewer.
///
/// Guest documents come from the agent and are untrusted. The viewer loads
/// exactly one document with [WebViewController.loadHtmlString] and then:
///
/// * blocks every main-frame navigation (meta refresh, `location.href`,
///   `window.open`, `target=_blank`, form posts) — the WebView never leaves
///   the initial document;
/// * hands an `http(s)` URL to the external browser only when the navigation
///   follows a real tap inside the WebView ([registerUserTap]); scripted or
///   timed navigations are dropped silently and never launch anything;
/// * never launches non-web schemes (`file:`, `intent:`, `javascript:`,
///   `data:`, `content:` …);
/// * wraps the document in a Content-Security-Policy that denies every
///   network, frame, object and form destination (only inline styles and
///   `data:` media resources render) and, with scripts on, pins
///   `window.open` to a no-op.
///
/// JavaScript is disabled by default; the user may enable it per document.
class ArtifactHtmlNavigationPolicy {
  ArtifactHtmlNavigationPolicy({
    Future<bool> Function(Uri uri)? launchExternal,
    DateTime Function()? clock,
    this.tapWindow = const Duration(milliseconds: 1200),
  }) : _launchExternal = launchExternal ?? launchArtifactLinkExternally,
       _clock = clock ?? DateTime.now;

  final Future<bool> Function(Uri uri) _launchExternal;
  final DateTime Function() _clock;

  /// How long after a pointer-up inside the WebView a navigation request is
  /// still attributed to that tap.
  final Duration tapWindow;

  DateTime? _lastTap;

  /// Called for every pointer-up inside the WebView.
  void registerUserTap() => _lastTap = _clock();

  bool _consumeTap() {
    final tap = _lastTap;
    _lastTap = null;
    if (tap == null) return false;
    final elapsed = _clock().difference(tap);
    return !elapsed.isNegative && elapsed <= tapWindow;
  }

  /// Navigation-delegate callback. Always prevents the navigation; the only
  /// possible side effect is opening a tapped web link externally.
  NavigationDecision onNavigationRequest(NavigationRequest request) {
    // Each tap authorises at most one launch, and any main-frame request
    // consumes it so a later scripted navigation cannot reuse it.
    final userTap = request.isMainFrame && _consumeTap();
    final uri = Uri.tryParse(request.url);
    if (userTap && uri != null && isExternalWebLink(uri)) {
      unawaited(_launch(uri));
    }
    return NavigationDecision.prevent;
  }

  Future<void> _launch(Uri uri) async {
    try {
      await _launchExternal(uri);
    } catch (error) {
      debugPrint('Artifact viewer: external link failed ($uri): $error');
    }
  }

  /// Only absolute `http`/`https` URLs with a host ever leave the app.
  static bool isExternalWebLink(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
}

/// Default external opener: the system browser, never an in-app tab.
Future<bool> launchArtifactLinkExternally(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// CSP for a guest document. Nothing may be fetched from the network, no
/// frame/object can be embedded and forms cannot submit anywhere.
String artifactContentSecurityPolicy({required bool scriptsEnabled}) => [
  "default-src 'none'",
  scriptsEnabled ? "script-src 'unsafe-inline'" : "script-src 'none'",
  "style-src 'unsafe-inline' data:",
  'img-src data: blob:',
  'media-src data: blob:',
  'font-src data:',
  "connect-src 'none'",
  "frame-src 'none'",
  "child-src 'none'",
  "worker-src 'none'",
  "object-src 'none'",
  "form-action 'none'",
  "base-uri 'none'",
].join('; ');

const String _windowOpenLock =
    '<script>(function(){try{Object.defineProperty(window,"open",'
    '{value:function(){return null;},writable:false,configurable:false});'
    '}catch(e){}})();</script>';

final RegExp _leadingDoctype = RegExp(
  r'^\s*<!doctype[^>]*>',
  caseSensitive: false,
);

/// Wraps [html] with the guard CSP (and the `window.open` lock when scripts
/// are on), keeping a leading `<!doctype>` first so standards mode survives.
String buildGuardedArtifactHtml(String html, {required bool scriptsEnabled}) {
  final csp = artifactContentSecurityPolicy(scriptsEnabled: scriptsEnabled);
  final guard =
      '<meta http-equiv="Content-Security-Policy" content="$csp">'
      '${scriptsEnabled ? _windowOpenLock : ''}';
  final doctype = _leadingDoctype.firstMatch(html);
  if (doctype == null) return '$guard$html';
  return '${doctype.group(0)}$guard${html.substring(doctype.end)}';
}

/// An SVG is never loaded as a document: it is embedded as an `<img>` data
/// URI, where SVG scripts and external references cannot run or load.
String buildGuardedSvgHtml(String svg) {
  final data = base64Encode(utf8.encode(svg));
  return buildGuardedArtifactHtml(
    '<!doctype html><html><head><meta name="viewport" '
    'content="width=device-width, initial-scale=1"><style>html,body{margin:0;'
    'height:100%;background:#fff}body{display:flex;align-items:center;'
    'justify-content:center}img{max-width:100%;max-height:100%}</style>'
    '</head><body><img alt="" src="data:image/svg+xml;base64,$data">'
    '</body></html>',
    scriptsEnabled: false,
  );
}

/// Platform-level WebView settings the viewer locks down before loading.
/// Abstracted so tests can prove the exact configuration without a device.
abstract interface class ArtifactWebViewPlatformSettings {
  Future<void> setAllowFileAccess(bool allow);
  Future<void> setAllowContentAccess(bool allow);
  Future<void> setGeolocationEnabled(bool enabled);
  Future<void> denyGeolocationPrompts();
  Future<void> setMixedContentNeverAllow();
  Future<void> setMediaPlaybackRequiresUserGesture(bool require);
  Future<void> refuseFileChooser();
}

typedef ArtifactWebViewSettingsFactory =
    ArtifactWebViewPlatformSettings? Function(WebViewController controller);

/// Android implementation backed by [AndroidWebViewController].
ArtifactWebViewPlatformSettings? defaultArtifactWebViewSettings(
  WebViewController controller,
) {
  final platform = controller.platform;
  if (platform is AndroidWebViewController) {
    return _AndroidArtifactWebViewSettings(platform);
  }
  return null;
}

final class _AndroidArtifactWebViewSettings
    implements ArtifactWebViewPlatformSettings {
  const _AndroidArtifactWebViewSettings(this._controller);

  final AndroidWebViewController _controller;

  @override
  Future<void> setAllowFileAccess(bool allow) =>
      _controller.setAllowFileAccess(allow);

  @override
  Future<void> setAllowContentAccess(bool allow) =>
      _controller.setAllowContentAccess(allow);

  @override
  Future<void> setGeolocationEnabled(bool enabled) =>
      _controller.setGeolocationEnabled(enabled);

  @override
  Future<void> denyGeolocationPrompts() =>
      _controller.setGeolocationPermissionsPromptCallbacks(
        onShowPrompt: (_) async =>
            const GeolocationPermissionsResponse(allow: false, retain: false),
      );

  @override
  Future<void> setMixedContentNeverAllow() =>
      _controller.setMixedContentMode(MixedContentMode.neverAllow);

  @override
  Future<void> setMediaPlaybackRequiresUserGesture(bool require) =>
      _controller.setMediaPlaybackRequiresUserGesture(require);

  @override
  Future<void> refuseFileChooser() =>
      _controller.setOnShowFileSelector((_) async => const <String>[]);
}

/// Applies the full lock-down to [controller] and wires [policy] as its only
/// navigation delegate. Must complete before any content is loaded.
Future<void> configureArtifactWebView(
  WebViewController controller, {
  required ArtifactHtmlNavigationPolicy policy,
  ArtifactWebViewSettingsFactory settingsFor = defaultArtifactWebViewSettings,
}) async {
  await controller.setJavaScriptMode(JavaScriptMode.disabled);
  await controller.setNavigationDelegate(
    NavigationDelegate(onNavigationRequest: policy.onNavigationRequest),
  );
  await controller.enableZoom(true);
  final settings = settingsFor(controller);
  if (settings != null) {
    await settings.setAllowFileAccess(false);
    await settings.setAllowContentAccess(false);
    await settings.setGeolocationEnabled(false);
    await settings.denyGeolocationPrompts();
    await settings.setMixedContentNeverAllow();
    await settings.setMediaPlaybackRequiresUserGesture(true);
    await settings.refuseFileChooser();
  }
}

/// Camera/microphone/MIDI requests from guest content are always denied.
void denyArtifactPermissionRequest(WebViewPermissionRequest request) =>
    unawaited(request.deny());
