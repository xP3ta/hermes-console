package com.hermesagent.hermes_android

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Makes a secure-storage write durable before Dart carries on.
 *
 * flutter_secure_storage 10.x stores each value (already encrypted) in the
 * "FlutterSecureStorage" SharedPreferences file and writes it with apply(),
 * which returns before the bytes are on disk. A kill in that window would lose
 * a rotated refresh token. An empty synchronous commit() on the same
 * SharedPreferences instance writes the full in-memory state, pending apply()s
 * included, and waits for the replaced file: the old file or the new one stays,
 * never a torn one. Hermes Desktop does the same with a synchronous write.
 */
object DurableSecretWriter {
    const val CHANNEL_NAME = "hermes/durable_secrets"
    private const val PREFS_NAME = "FlutterSecureStorage"
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun attach(context: Context, messenger: BinaryMessenger): MethodChannel {
        val app = context.applicationContext
        return MethodChannel(messenger, CHANNEL_NAME).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "flush") return@setMethodCallHandler result.notImplemented()
                io.execute {
                    val flushed =
                        try {
                            app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().commit()
                        } catch (_: Exception) {
                            false
                        }
                    main.post { result.success(flushed) }
                }
            }
        }
    }

    fun detach(channel: MethodChannel) = channel.setMethodCallHandler(null)
}
