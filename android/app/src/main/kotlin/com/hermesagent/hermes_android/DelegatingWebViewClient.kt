package com.hermesagent.hermes_android

import android.graphics.Bitmap
import android.net.http.SslError
import android.os.Build
import android.os.Message
import android.view.KeyEvent
import android.webkit.ClientCertRequest
import android.webkit.HttpAuthHandler
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.annotation.RequiresApi
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature

/**
 * Hands every callback to [inner], the client webview_flutter installed (so
 * the Dart NavigationDelegate keeps running), and adds the one thing neither
 * webview_flutter nor Android's default does: when the renderer process dies
 * (out of memory, a heavy or hostile page) the app is told and survives.
 * Without an override that returns true, Android ends the whole app
 * (REVIEW-R5-B #1).
 */
internal open class DelegatingWebViewClient(
    val inner: WebViewClient?,
    private val onRendererGone: () -> Unit,
) : WebViewClient() {
    @RequiresApi(Build.VERSION_CODES.O)
    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
        inner?.onRenderProcessGone(view, detail)
        // The dead WebView is unusable: Dart replaces it (a new platform view)
        // and shows the error with Retry.
        onRendererGone()
        return true
    }

    override fun shouldInterceptRequest(
        view: WebView,
        request: WebResourceRequest,
    ): WebResourceResponse? = inner?.shouldInterceptRequest(view, request)

    override fun shouldOverrideUrlLoading(
        view: WebView,
        request: WebResourceRequest,
    ): Boolean = inner?.shouldOverrideUrlLoading(view, request) ?: false

    @Deprecated("Required for API 24")
    @Suppress("DEPRECATION")
    override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean =
        inner?.shouldOverrideUrlLoading(view, url) ?: false

    override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
        inner?.onPageStarted(view, url, favicon) ?: super.onPageStarted(view, url, favicon)
    }

    override fun onPageFinished(view: WebView, url: String) {
        inner?.onPageFinished(view, url) ?: super.onPageFinished(view, url)
    }

    override fun onPageCommitVisible(view: WebView, url: String) {
        inner?.onPageCommitVisible(view, url) ?: super.onPageCommitVisible(view, url)
    }

    override fun onLoadResource(view: WebView, url: String) {
        inner?.onLoadResource(view, url) ?: super.onLoadResource(view, url)
    }

    override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
        inner?.doUpdateVisitedHistory(view, url, isReload)
            ?: super.doUpdateVisitedHistory(view, url, isReload)
    }

    override fun onReceivedError(
        view: WebView,
        request: WebResourceRequest,
        error: WebResourceError,
    ) {
        inner?.onReceivedError(view, request, error) ?: super.onReceivedError(view, request, error)
    }

    override fun onReceivedHttpError(
        view: WebView,
        request: WebResourceRequest,
        errorResponse: WebResourceResponse,
    ) {
        inner?.onReceivedHttpError(view, request, errorResponse)
            ?: super.onReceivedHttpError(view, request, errorResponse)
    }

    override fun onReceivedHttpAuthRequest(
        view: WebView,
        handler: HttpAuthHandler,
        host: String,
        realm: String,
    ) {
        inner?.onReceivedHttpAuthRequest(view, handler, host, realm)
            ?: super.onReceivedHttpAuthRequest(view, handler, host, realm)
    }

    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
        // The default (and webview_flutter without a Dart handler) cancels.
        inner?.onReceivedSslError(view, handler, error)
            ?: super.onReceivedSslError(view, handler, error)
    }

    override fun onReceivedClientCertRequest(view: WebView, request: ClientCertRequest) {
        inner?.onReceivedClientCertRequest(view, request)
            ?: super.onReceivedClientCertRequest(view, request)
    }

    override fun onFormResubmission(view: WebView, dontResend: Message, resend: Message) {
        inner?.onFormResubmission(view, dontResend, resend)
            ?: super.onFormResubmission(view, dontResend, resend)
    }

    override fun onScaleChanged(view: WebView, oldScale: Float, newScale: Float) {
        inner?.onScaleChanged(view, oldScale, newScale)
            ?: super.onScaleChanged(view, oldScale, newScale)
    }

    override fun onUnhandledKeyEvent(view: WebView, event: KeyEvent) {
        inner?.onUnhandledKeyEvent(view, event) ?: super.onUnhandledKeyEvent(view, event)
    }

    companion object {
        /**
         * The client webview_flutter installed on [webView], or null where the
         * platform cannot report it (API 24-25 without the WebView feature).
         * A second install never wraps our own wrapper.
         */
        fun flutterClient(webView: WebView): WebViewClient? {
            val readable =
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ||
                    WebViewFeature.isFeatureSupported(WebViewFeature.GET_WEB_VIEW_CLIENT)
            if (!readable) return null
            val current = WebViewCompat.getWebViewClient(webView)
            return if (current is DelegatingWebViewClient) current.inner else current
        }
    }
}
