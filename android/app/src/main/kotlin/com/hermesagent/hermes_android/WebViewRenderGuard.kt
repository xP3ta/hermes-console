package com.hermesagent.hermes_android

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi

/**
 * Keeps a dying WebView renderer from closing the app for the in-app
 * browser (REVIEW-R5-B #1): `install` wraps the WebView's webview_flutter
 * client in a [DelegatingWebViewClient], and a dead renderer is reported to
 * Dart as `renderGone` with the WebView's id.
 */
object WebViewRenderGuard {
    const val CHANNEL = "hermes/webview_guard"

    fun register(engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "install" -> {
                    val id = (call.arguments as? Number)?.toLong()
                    val webView = id?.let { WebViewFlutterAndroidExternalApi.getWebView(engine, it) }
                    val inner = webView?.let { DelegatingWebViewClient.flutterClient(it) }
                    if (id == null || webView == null) {
                        result.error("missing", "Web view is not available", null)
                    } else if (inner == null) {
                        // API 24-25 without the WebView feature: the client
                        // cannot be read, and a wrapper with nothing inside
                        // would drop the Dart NavigationDelegate and the page
                        // callbacks. There is no renderer-gone callback below
                        // API 26 to gain anyway.
                        result.error("unsupported", "Web view client is not readable", null)
                    } else {
                        webView.webViewClient =
                            DelegatingWebViewClient(inner) {
                                channel.invokeMethod("renderGone", id)
                            }
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
