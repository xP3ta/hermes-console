package com.hermesagent.hermes_android

import android.content.Context
import android.net.Uri
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewAssetLoader
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.io.ByteArrayInputStream
import java.io.IOException

/**
 * Serves the vendored noVNC tree on `https://appassets.androidplatform.net`
 * from the Flutter asset bundle. The WebView never fetches that origin: a
 * request the loader cannot answer gets a local 404, and Dart is told when
 * the page or one of its modules failed to load.
 */
object ScreenAssetHost {
    const val CHANNEL = "hermes/screen_assets"
    const val HOST = "appassets.androidplatform.net"

    /** Registers [CHANNEL] on [engine]. */
    fun register(context: Context, engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "install" -> install(context, engine, channel, call, result)
                "focus" -> focus(engine, call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun install(
        context: Context,
        engine: FlutterEngine,
        channel: MethodChannel,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val id = (call.arguments as? Number)?.toLong()
        if (id == null) {
            result.error("bad_args", "Missing web view id", null)
            return
        }
        val webView = WebViewFlutterAndroidExternalApi.getWebView(engine, id)
        if (webView == null) {
            result.error("missing", "Web view is not available", null)
            return
        }
        val loader =
            WebViewAssetLoader.Builder()
                .setDomain(HOST)
                .addPathHandler("/assets/novnc/", NovncHandler(context))
                .build()
        // Wrap webview_flutter's own client instead of replacing it, so the
        // Dart NavigationDelegate (screenNavigationDecision) and the page
        // callbacks keep running (REVIEW-PR210 P1).
        // Where the platform cannot report webview_flutter's client (API
        // 24-25 without the WebView feature) the native asset-host guard
        // below still holds. A dead renderer is reported, never a crash
        // (REVIEW-R5-B #1).
        webView.webViewClient =
            AssetClient(
                loader,
                DelegatingWebViewClient.flutterClient(webView),
                onLoadFailed = { channel.invokeMethod("loadFailed", null) },
                onRendererGone = { channel.invokeMethod("renderGone", null) },
            )
        result.success(null)
    }

    /**
     * Gives the embedded WebView real view focus, the prerequisite for the
     * page to raise the soft keyboard from a JS-initiated focus: touches on
     * the page grant it naturally, calls coming from the Flutter app bar
     * do not.
     */
    private fun focus(
        engine: FlutterEngine,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val id = (call.arguments as? Number)?.toLong()
        val webView = id?.let { WebViewFlutterAndroidExternalApi.getWebView(engine, it) }
        if (webView == null) {
            result.error("missing", "Web view is not available", null)
            return
        }
        webView.isFocusable = true
        webView.isFocusableInTouchMode = true
        webView.requestFocus()
        result.success(null)
    }
}

private class NovncHandler(context: Context) : WebViewAssetLoader.PathHandler {
    private val assets = context.assets
    private val lookup = FlutterInjector.instance().flutterLoader()

    override fun handle(path: String): WebResourceResponse? {
        if (!safe(path)) return null
        return try {
            val key = lookup.getLookupKeyForAsset("assets/novnc/$path")
            WebResourceResponse(mime(path), "utf-8", assets.open(key))
        } catch (_: IOException) {
            null
        }
    }

    private fun safe(path: String): Boolean {
        if (path.isEmpty() || path.contains('\\') || path.contains('\u0000')) return false
        return path.split('/').none { it.isEmpty() || it == "." || it == ".." }
    }

    private fun mime(path: String): String =
        when {
            path.endsWith(".html") -> "text/html"
            path.endsWith(".js") || path.endsWith(".mjs") -> "text/javascript"
            path.endsWith(".css") -> "text/css"
            path.endsWith(".json") -> "application/json"
            path.endsWith(".svg") -> "image/svg+xml"
            path.endsWith(".png") -> "image/png"
            path.endsWith(".txt") -> "text/plain"
            else -> "application/octet-stream"
        }
}

/**
 * Serves the asset host and delegates everything else to [inner], the
 * client webview_flutter installed (through [DelegatingWebViewClient], which
 * also survives a dead renderer). Two rules hold whatever [inner] says: a
 * miss on the asset host gets a local 404 (never the network), and no
 * navigation may leave the asset host. Inside it, [inner] (the Dart
 * NavigationDelegate) decides.
 */
private class AssetClient(
    private val loader: WebViewAssetLoader,
    inner: WebViewClient?,
    private val onLoadFailed: () -> Unit,
    onRendererGone: () -> Unit,
) : DelegatingWebViewClient(inner, onRendererGone) {
    override fun shouldInterceptRequest(
        view: WebView,
        request: WebResourceRequest,
    ): WebResourceResponse? {
        loader.shouldInterceptRequest(request.url)?.let { return it }
        // Never let a miss on the asset host reach the network.
        if (isAsset(request.url)) {
            return WebResourceResponse(
                "text/plain",
                "utf-8",
                404,
                "Not Found",
                emptyMap(),
                ByteArrayInputStream(ByteArray(0)),
            )
        }
        return super.shouldInterceptRequest(view, request)
    }

    override fun shouldOverrideUrlLoading(
        view: WebView,
        request: WebResourceRequest,
    ): Boolean {
        if (!isAsset(request.url)) return true
        return super.shouldOverrideUrlLoading(view, request)
    }

    @Deprecated("Required for API 24")
    @Suppress("DEPRECATION")
    override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean {
        if (!isAsset(Uri.parse(url))) return true
        return super.shouldOverrideUrlLoading(view, url)
    }

    override fun onReceivedError(
        view: WebView,
        request: WebResourceRequest,
        error: WebResourceError,
    ) {
        super.onReceivedError(view, request, error)
        // A load that a newer load replaces is aborted, not broken.
        if (error.description?.contains("ERR_ABORTED") == true) return
        if (isNovncAsset(request.url)) onLoadFailed()
    }

    override fun onReceivedHttpError(
        view: WebView,
        request: WebResourceRequest,
        errorResponse: WebResourceResponse,
    ) {
        super.onReceivedHttpError(view, request, errorResponse)
        if (isNovncAsset(request.url)) onLoadFailed()
    }

    private fun isAsset(url: Uri): Boolean =
        url.scheme == "https" && url.host.equals(ScreenAssetHost.HOST, ignoreCase = true)

    private fun isNovncAsset(url: Uri): Boolean =
        isAsset(url) && url.path.orEmpty().startsWith("/assets/novnc/")
}
