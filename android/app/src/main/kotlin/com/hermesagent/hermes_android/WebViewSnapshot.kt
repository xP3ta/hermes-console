package com.hermesagent.hermes_android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/**
 * A still picture of what one of the app's own preview WebViews shows, so
 * the chat can keep an image in the list instead of a live WebView.
 *
 * `capture` takes the WebView's id and answers PNG bytes, or null when there
 * is nothing to draw. It reads pixels only: no page, file or setting is
 * touched, and nothing leaves the process.
 */
object WebViewSnapshot {
    const val CHANNEL = "hermes/webview_snapshot"
    private const val MAX_SIDE = 1600

    fun register(engine: FlutterEngine) {
        val main = Handler(Looper.getMainLooper())
        val executor = Executors.newSingleThreadExecutor()
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "capture") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val id = (call.arguments as? Number)?.toLong()
                val webView = id?.let { WebViewFlutterAndroidExternalApi.getWebView(engine, it) }
                val width = webView?.width ?: 0
                val height = webView?.height ?: 0
                if (webView == null || width <= 0 || height <= 0) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                val scale = minOf(1f, MAX_SIDE / maxOf(width, height).toFloat())
                val bitmap =
                    try {
                        Bitmap.createBitmap(
                            (width * scale).roundToInt().coerceAtLeast(1),
                            (height * scale).roundToInt().coerceAtLeast(1),
                            Bitmap.Config.ARGB_8888,
                        ).also { target ->
                            val canvas = Canvas(target)
                            canvas.scale(scale, scale)
                            webView.draw(canvas)
                        }
                    } catch (_: Throwable) {
                        null
                    }
                if (bitmap == null) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                executor.execute {
                    val bytes =
                        runCatching {
                            ByteArrayOutputStream().use { out ->
                                if (bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) {
                                    out.toByteArray()
                                } else {
                                    null
                                }
                            }
                        }.getOrNull()
                    bitmap.recycle()
                    main.post { result.success(bytes) }
                }
            }
    }
}
