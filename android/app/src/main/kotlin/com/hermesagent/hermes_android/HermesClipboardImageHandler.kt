package com.hermesagent.hermes_android

import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Channel "hermes/clipboard": images on the system clipboard for the
 * composers' long-press "Paste image" (Flutter's Paste reads text only).
 *
 * - `hasImage`: whether the primary clip declares an image type. Reads only
 *   the clip description, never the content.
 * - `readImage`: the first item's image as `{mimeType, name, bytes}`, or
 *   `{mimeType, name, tooLarge: true}` when it exceeds [MAX_BYTES] (checked
 *   against the provider's size and again while reading, so an oversized
 *   stream is never buffered in full), or `null` when there is no image.
 *
 * The foreground app may read its clipboard without any permission; the
 * clip's content URI read grant comes with `primaryClip`. Dart decides type
 * and batch limits through the composer's shared paste helper.
 */
class HermesClipboardImageHandler(context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "hermes/clipboard"

        /** Same per-image cap as the composers (8 MiB). */
        const val MAX_BYTES = 8L * 1024 * 1024
    }

    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "hermes-clipboard-image").apply { isDaemon = true }
    }

    private val clipboard: ClipboardManager?
        get() = appContext.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasImage" -> result.success(hasImage())
            "readImage" -> {
                // Clipboard access must happen on the main thread while the
                // app has focus; only the stream read moves off it.
                val uri = imageUri()
                if (uri == null) {
                    result.success(null)
                    return
                }
                executor.execute {
                    val reply =
                        try {
                            readImage(uri)
                        } catch (_: Exception) {
                            null
                        }
                    mainHandler.post {
                        if (reply == null) {
                            result.error("clipboard_read_failed", null, null)
                        } else {
                            result.success(reply)
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun close() {
        executor.shutdownNow()
    }

    private fun hasImage(): Boolean =
        try {
            clipboard?.primaryClipDescription?.hasMimeType("image/*") == true
        } catch (_: Exception) {
            false
        }

    private fun imageUri(): Uri? =
        try {
            val manager = clipboard ?: return null
            if (manager.primaryClipDescription?.hasMimeType("image/*") != true) {
                null
            } else {
                manager.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
            }
        } catch (_: Exception) {
            null
        }

    private fun readImage(uri: Uri): Map<String, Any?>? {
        val resolver = appContext.contentResolver
        val mimeType = resolver.getType(uri)?.lowercase() ?: return null
        if (!mimeType.startsWith("image/")) return null
        var name: String? = null
        var declaredSize = -1L
        resolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    name = cursor.getString(nameIndex)
                }
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    declaredSize = cursor.getLong(sizeIndex)
                }
            }
        }
        val tooLarge = mapOf("mimeType" to mimeType, "name" to name, "tooLarge" to true)
        if (declaredSize > MAX_BYTES) return tooLarge
        val input = resolver.openInputStream(uri) ?: return null
        val out = ByteArrayOutputStream()
        input.use { stream ->
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) break
                total += read
                if (total > MAX_BYTES) return tooLarge
                out.write(buffer, 0, read)
            }
        }
        return mapOf("mimeType" to mimeType, "name" to name, "bytes" to out.toByteArray())
    }
}
