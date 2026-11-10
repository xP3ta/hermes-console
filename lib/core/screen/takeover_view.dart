import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'screen_server.dart';

/// Whether the embedded page may follow [requestUrl].
///
/// Only `https` on the same host and port as [page] is allowed, so the
/// asset-loader page can be replaced with a fresh ticket and nothing else
/// can navigate away.
NavigationDecision screenNavigationDecision(Uri page, String requestUrl) {
  final uri = Uri.tryParse(requestUrl);
  if (uri == null || uri.userInfo.isNotEmpty) {
    return NavigationDecision.prevent;
  }
  if (uri.scheme != 'https') return NavigationDecision.prevent;
  if (uri.host.toLowerCase() != page.host.toLowerCase()) {
    return NavigationDecision.prevent;
  }
  if (uri.port != page.port) return NavigationDecision.prevent;
  return NavigationDecision.navigate;
}

/// Installs the on-device asset loader for [controller], when it is Android.
///
/// Tests and other platforms leave the WebView as the caller configured it.
/// The page is then loaded from `https://appassets.androidplatform.net`,
/// which the loader serves from the app bundle. The loader wraps
/// webview_flutter's client (it no longer replaces it, REVIEW-PR210 P1), so
/// [screenNavigationDecision] below runs on Android too, with the same rule
/// enforced natively as a backstop; a failed asset is reported through
/// [onLoadFailed], and a renderer the system killed through [onRenderGone]
/// (the native client returns true, so the app is not closed; REVIEW-R5-B
/// #1).
Future<void> installScreenAssetHost(
  WebViewController controller, {
  VoidCallback? onLoadFailed,
  VoidCallback? onRenderGone,
}) async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  final platform = controller.platform;
  if (platform is! AndroidWebViewController) return;
  const channel = MethodChannel(screenAssetChannelName);
  channel.setMethodCallHandler(
    screenAssetHostCalls(
      onLoadFailed: onLoadFailed,
      onRenderGone: onRenderGone,
    ),
  );
  await channel.invokeMethod<void>('install', platform.webViewIdentifier);
}

/// What the native asset host reports: `loadFailed` (a noVNC asset did not
/// load) and `renderGone` (the WebView's renderer died).
Future<void> Function(MethodCall call) screenAssetHostCalls({
  VoidCallback? onLoadFailed,
  VoidCallback? onRenderGone,
}) => (call) async {
  switch (call.method) {
    case 'loadFailed':
      onLoadFailed?.call();
    case 'renderGone':
      onRenderGone?.call();
  }
};

/// Stops listening for asset failures from the on-device asset loader.
void releaseScreenAssetHost() {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  const MethodChannel(screenAssetChannelName).setMethodCallHandler(null);
}

/// Whether [wsUrl] carries the session (keystrokes included) in cleartext.
bool screenSocketUnencrypted(String wsUrl) =>
    Uri.tryParse(wsUrl)?.scheme.toLowerCase() == 'ws';

/// noVNC page served by the Android asset loader.
class TakeoverView extends StatefulWidget {
  /// Creates a view of [pageUri].
  const TakeoverView({
    required this.pageUri,
    required this.wsUrl,
    required this.onBridgeMessage,
    this.onUnavailable,
    super.key,
  });

  /// `bridge.html` URL: overlay copy and touchpad mode, never the ticket.
  final Uri pageUri;

  /// Ticketed display websocket, handed to the page once it is `ready`. A
  /// new value reloads the page and connects it to the new socket.
  final String wsUrl;

  /// Messages from the page (`lost`, `reconnect`, and the other status tokens).
  final ValueChanged<String> onBridgeMessage;

  /// Called when the asset host cannot be installed or the page cannot load.
  final VoidCallback? onUnavailable;

  @override
  State<TakeoverView> createState() => TakeoverViewState();
}

class TakeoverViewState extends State<TakeoverView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController(
      onPermissionRequest: (request) {
        unawaited(request.deny());
      },
    );
    unawaited(_open());
  }

  @override
  void didUpdateWidget(TakeoverView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageUri == widget.pageUri &&
        oldWidget.wsUrl == widget.wsUrl) {
      return;
    }
    unawaited(_controller.loadRequest(widget.pageUri));
  }

  Future<void> _open() async {
    try {
      final controller = _controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(const Color(0xFF000000));
      await controller.addJavaScriptChannel(
        'TakeoverChannel',
        onMessageReceived: (message) {
          if (!mounted) return;
          // The page is loaded and listening: give it the socket now.
          if (message.message == 'ready') {
            unawaited(_runJs(screenConnectScript(widget.wsUrl)));
          }
          widget.onBridgeMessage(message.message);
        },
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              screenNavigationDecision(widget.pageUri, request.url),
        ),
      );
      await _lockDown(controller);
      if (!mounted) return;
      await installScreenAssetHost(
        controller,
        onLoadFailed: () {
          if (mounted) widget.onUnavailable?.call();
        },
        // The page is gone with its renderer: the takeover shows its error
        // and Retry builds a new view.
        onRenderGone: () {
          if (mounted) widget.onUnavailable?.call();
        },
      );
      if (!mounted) return;
      await controller.loadRequest(widget.pageUri);
    } catch (_) {
      if (mounted) widget.onUnavailable?.call();
    }
  }

  Future<void> _lockDown(WebViewController controller) async {
    final platform = controller.platform;
    if (platform is! AndroidWebViewController) return;
    await platform.setAllowFileAccess(false);
    await platform.setAllowContentAccess(false);
    await platform.setGeolocationEnabled(false);
    // The https asset page can only reach a ws:// Dashboard with mixed
    // content allowed. The page itself is ours and loads nothing else; the
    // takeover screen tells the user the session is not encrypted
    // (REVIEW-PR210 P2).
    await platform.setMixedContentMode(
      screenSocketUnencrypted(widget.wsUrl)
          ? MixedContentMode.alwaysAllow
          : MixedContentMode.neverAllow,
    );
    await platform.setGeolocationPermissionsPromptCallbacks(
      onShowPrompt: (_) async =>
          const GeolocationPermissionsResponse(allow: false, retain: false),
    );
    await platform.setOnShowFileSelector((_) async => const <String>[]);
  }

  /// Shows or hides the page's remote-typing keyboard.
  ///
  /// Showing first hands the native view focus to the WebView: without it
  /// the page's focus() cannot raise the Android IME.
  Future<void> showKeyboard(bool show) async {
    if (show) await _focusNativeView();
    await _runJs(
      'window.hermesScreen && window.hermesScreen.'
      '${show ? 'showKeyboard' : 'hideKeyboard'}()',
    );
  }

  /// Focuses the embedded WebView through the asset-loader channel.
  Future<void> _focusNativeView() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final platform = _controller.platform;
    if (platform is! AndroidWebViewController) return;
    try {
      // Same channel that installed the asset host; it resolves the native
      // view from the controller's webViewIdentifier.
      const channel = MethodChannel(screenAssetChannelName);
      await channel.invokeMethod<Object?>('focus', platform.webViewIdentifier);
    } catch (_) {
      // Without native focus the fallback is the floating page button.
    }
  }

  /// Switches the page between touchpad gestures and direct touches.
  ///
  /// The gesture logic lives inside the page: an overlay on top of a hybrid
  /// WebView never wins the native touch dispatch on Android.
  Future<void> setTouchpad(bool on) =>
      _runJs('window.hermesScreen && window.hermesScreen.setTouchpad($on)');

  /// Moves the page's virtual pointer by a finger delta (logical pixels).
  Future<void> padMove(double dx, double dy) => _runJs(
    'window.hermesScreen && window.hermesScreen.padMove('
    '${dx.toStringAsFixed(2)},${dy.toStringAsFixed(2)})',
  );

  /// Clicks at the virtual pointer: [mask] 1 left, 2 middle (wheel), 4 right.
  Future<void> padClick(int mask) =>
      _runJs('window.hermesScreen && window.hermesScreen.padClick($mask)');

  /// Holds a button down at the virtual pointer (for drags).
  Future<void> padDown(int mask) =>
      _runJs('window.hermesScreen && window.hermesScreen.padDown($mask)');

  /// Lets a held button go.
  Future<void> padUp(int mask) =>
      _runJs('window.hermesScreen && window.hermesScreen.padUp($mask)');

  /// Turns the mouse wheel [steps] notches (positive scrolls down).
  Future<void> padWheel(int steps) =>
      _runJs('window.hermesScreen && window.hermesScreen.padWheel($steps)');

  /// Zooms the view in or out one step.
  Future<void> zoomBy({required bool zoomIn}) => _runJs(
    'window.hermesScreen && window.hermesScreen.'
    '${zoomIn ? 'zoomIn' : 'zoomOut'}()',
  );

  /// Runs [js] in the page, ignoring failures.
  ///
  /// Commands race the page's own reloads (fresh tickets), where the
  /// execution is expected to fail; nothing depends on the result.
  Future<void> _runJs(String js) async {
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  @override
  void dispose() {
    releaseScreenAssetHost();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
