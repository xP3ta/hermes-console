import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Channel of the native `WebViewRenderGuard` (MainActivity).
const String webViewGuardChannelName = 'hermes/webview_guard';

/// Tells a screen when the system killed its WebView's renderer.
abstract interface class WebViewRendererWatch {
  /// Starts watching [controller]'s WebView; [onGone] runs once if its
  /// renderer dies.
  Future<void> watch(WebViewController controller, VoidCallback onGone);

  /// Stops watching [controller].
  void forget(WebViewController controller);
}

/// Android: without a client that handles `onRenderProcessGone`, a dead
/// renderer (out of memory, a heavy or hostile page) closes the whole app.
/// The native guard wraps webview_flutter's client, keeps the app alive and
/// reports `renderGone`; the screen then replaces the WebView (REVIEW-R5-B
/// #1). Other platforms and the tests' fake WebView: nothing to watch.
class WebViewRenderGuard implements WebViewRendererWatch {
  WebViewRenderGuard._();

  static final WebViewRenderGuard instance = WebViewRenderGuard._();

  static const MethodChannel _channel = MethodChannel(webViewGuardChannelName);

  final Map<int, VoidCallback> _gone = {};
  bool _listening = false;

  static int? _idOf(WebViewController controller) {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    final platform = controller.platform;
    return platform is AndroidWebViewController
        ? platform.webViewIdentifier
        : null;
  }

  @override
  Future<void> watch(WebViewController controller, VoidCallback onGone) async {
    final id = _idOf(controller);
    if (id == null) return;
    _gone[id] = onGone;
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(handle);
    }
    try {
      await _channel.invokeMethod<void>('install', id);
    } on PlatformException {
      _gone.remove(id);
    } on MissingPluginException {
      _gone.remove(id);
    }
  }

  @override
  void forget(WebViewController controller) {
    final id = _idOf(controller);
    if (id != null) _gone.remove(id);
  }

  /// A call from the native guard.
  @visibleForTesting
  Future<void> handle(MethodCall call) async {
    if (call.method != 'renderGone') return;
    final id = call.arguments;
    if (id is int) _gone.remove(id)?.call();
  }
}
