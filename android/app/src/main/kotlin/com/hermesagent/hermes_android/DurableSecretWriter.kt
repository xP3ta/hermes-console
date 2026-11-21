package com.hermesagent.hermes_android

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig
import com.it_nomads.fluttersecurestorage.NamespacedConfigSource
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
    private val keyPrefix = FlutterSecureStorageConfig(emptyMap()).sharedPreferencesKeyPrefix + "_"
    private val encryptedKeysets = setOf(
        "__androidx_security_crypto_encrypted_prefs_key_keyset__",
        "__androidx_security_crypto_encrypted_prefs_value_keyset__",
    )
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun attach(context: Context, messenger: BinaryMessenger): MethodChannel {
        val app = context.applicationContext
        return MethodChannel(messenger, CHANNEL_NAME).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "flush" -> io.execute {
                        val flushed =
                            try {
                                app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().commit()
                            } catch (_: Exception) {
                                false
                            }
                        main.post { result.success(flushed) }
                    }
                    "listKeys" -> io.execute {
                        try {
                            val keys = listKeys(app)
                            main.post { result.success(keys) }
                        } catch (_: Exception) {
                            main.post { result.error("key_list_failed", "Could not list secure storage keys", null) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** Lists the default backend's keys without decoding its encrypted values. */
    private fun listKeys(context: Context): List<String>? {
        val migrated =
            NamespacedConfigSource(context, PREFS_NAME).getBoolean("ENCRYPTED_PREFERENCES_MIGRATED", false)
        val keys = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).all.keys
        // Older EncryptedSharedPreferences installs encrypt the names too.
        // Let flutter_secure_storage handle their migration before listing.
        if (!migrated && keys.any { !it.startsWith(keyPrefix) && it !in encryptedKeysets }) {
            return null
        }
        return keys.filter { it.startsWith(keyPrefix) }.map { it.removePrefix(keyPrefix) }
    }

    fun detach(channel: MethodChannel) = channel.setMethodCallHandler(null)
}
