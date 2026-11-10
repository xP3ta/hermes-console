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
                    if (id == null || webView == null) {
                        result.error("missing", "Web view is not available", null)
                    } else {
                        webView.webViewClient =
                            DelegatingWebViewClient(
                                DelegatingWebViewClient.flutterClient(webView),
                            ) { channel.invokeMethod("renderGone", id) }
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
