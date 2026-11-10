package com.hermesagent.hermes_android

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.system.ErrnoException
import android.system.OsConstants
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.activity.result.contract.ActivityResultContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * «Guardar en el móvil» directo (1.4.0, orden DESCARGAS-DIRECTAS).
 *
 * - `pick`: el diálogo «Guardar como» de Android (ACTION_CREATE_DOCUMENT,
 *   Storage Access Framework, sin permisos de almacenamiento) con el nombre
 *   ya saneado; devuelve el Uri elegido o null si se cancela.
 * - `begin` / `write` / `finish` / `abort`: escribe directamente en ese Uri
 *   con `ContentResolver.openOutputStream`, bloque a bloque, lo que llega
 *   (p. ej. una descarga SFTP). `abort` borra el documento a medias.
 * - `copy`: copia POR BLOQUES un archivo privado de la app (o otro Uri ya
 *   guardado) al Uri elegido; nada se carga entero en memoria.
 * - `view` / `share`: ACTION_VIEW o ACTION_SEND sobre el Uri, concediendo
 *   solo lectura a la app que lo abre.
 *
 * Los errores vuelven como códigos (`no_space`, `permission`,
 * `unsupported`, `source_missing`, `picker_not_shown`, `failed`): Dart dice
 * el motivo. Cada paso deja una línea `[save] …` en logcat (etiqueta
 * `HermesSave`), sin nombres, rutas ni Uris: solo pasos, tipos y bytes.
 */
class HermesSaveToDeviceHandler(
    context: Context,
    private val createDocument: (name: String, mimeType: String) -> Unit,
) : MethodChannel.MethodCallHandler, AutoCloseable {
    private val applicationContext = context.applicationContext
    private val resolver = applicationContext.contentResolver
    private val mainHandler = Handler(Looper.getMainLooper())

    // One thread: the blocks of a document are written in the order sent.
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private var pendingPick: MethodChannel.Result? = null
    private val writers = HashMap<Int, Writer>()
    private var nextWriter = 1

    private class Writer(val uri: Uri, val output: OutputStream) {
        var bytes = 0L
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(call.argument<String>("name").orEmpty(), result)
            "begin" -> begin(call.argument<String>("uri").orEmpty(), result)
            "write" -> write(
                call.argument<Number>("writer")?.toInt() ?: -1,
                call.argument<ByteArray>("bytes"),
                result,
            )
            "finish" -> finish(call.argument<Number>("writer")?.toInt() ?: -1, result)
            "abort" -> abort(call.argument<Number>("writer")?.toInt() ?: -1, result)
            "copy" -> copy(
                call.argument<String>("path"),
                call.argument<String>("source"),
                call.argument<String>("uri").orEmpty(),
                result,
            )
            "cancelPick" -> {
                // Dart gave up waiting (the dialog never showed): a later
                // result has nobody to go to.
                Log.i(TAG, "[save] pick abandoned by Dart waiting=${pendingPick != null}")
                pendingPick?.error(PICKER_NOT_SHOWN, "abandoned", null)
                pendingPick = null
                result.success(null)
            }
            "view" -> view(call.argument<String>("uri").orEmpty(), result)
            "share" -> share(call.argument<String>("uri").orEmpty(), result)
            "delete" -> {
                deleteDocument(Uri.parse(call.argument<String>("uri").orEmpty()))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(name: String, result: MethodChannel.Result) {
        Log.i(TAG, "[save] pick received")
        // A dialog whose answer never came (the app was paused, the result
        // lost) must not block every later save: it is answered and replaced.
        pendingPick?.let { stale ->
            Log.w(TAG, "[save] pick replaces one still pending")
            stale.error(PICKER_NOT_SHOWN, "superseded", null)
        }
        pendingPick = result
        val mimeType = mimeTypeOf(name)
        Log.i(TAG, "[save] pick launching mime=$mimeType")
        try {
            createDocument(name.ifBlank { "download" }, mimeType)
            Log.i(TAG, "[save] pick launched")
        } catch (error: ActivityNotFoundException) {
            Log.w(TAG, "[save] pick failed type=${error.javaClass.simpleName}")
            pendingPick = null
            result.error(UNSUPPORTED, "no document picker", null)
        } catch (error: RuntimeException) {
            // IllegalStateException of a launcher that is not registered,
            // or anything else that stops the dialog from showing.
            Log.w(TAG, "[save] pick failed type=${error.javaClass.simpleName}")
            pendingPick = null
            result.error(PICKER_NOT_SHOWN, error.javaClass.simpleName, null)
        }
    }

    /** The save dialog closed: [uri] is where to write, null when cancelled. */
    fun onDocumentCreated(uri: Uri?) {
        Log.i(TAG, "[save] picker result uri=${uri != null} waiting=${pendingPick != null}")
        val result = pendingPick
        if (result == null) {
            // Dart already gave up: the empty document just created would be
            // left behind with nothing in it.
            if (uri != null) deleteDocument(uri)
            return
        }
        pendingPick = null
        result.success(uri?.toString())
    }

    private fun begin(uriText: String, result: MethodChannel.Result) {
        val uri = Uri.parse(uriText)
        runOnExecutor("begin", result) {
            val output = resolver.openOutputStream(uri, "wt")
                ?: throw FileNotFoundException("no output stream")
            val id = synchronized(writers) {
                val id = nextWriter++
                writers[id] = Writer(uri, output)
                id
            }
            Log.i(TAG, "[save] begin writer=$id")
            id
        }
    }

    private fun write(id: Int, bytes: ByteArray?, result: MethodChannel.Result) {
        runOnExecutor("write", result) {
            val writer = synchronized(writers) { writers[id] }
                ?: throw IllegalStateException("no writer")
            if (bytes != null) {
                writer.output.write(bytes)
                writer.bytes += bytes.size
            }
            writer.bytes
        }
    }

    private fun finish(id: Int, result: MethodChannel.Result) {
        runOnExecutor("finish", result) {
            val writer = synchronized(writers) { writers.remove(id) }
                ?: throw IllegalStateException("no writer")
            try {
                writer.output.use { it.flush() }
            } catch (error: Throwable) {
                // The writer is already gone, so Dart's abort cannot remove
                // the half-written document: remove it here, as copy does.
                Log.w(TAG, "[save] finish stopped bytes=${writer.bytes}, partial document deleted")
                deleteDocument(writer.uri)
                throw error
            }
            Log.i(TAG, "[save] finish writer=$id bytes=${writer.bytes}")
            writer.bytes
        }
    }

    private fun abort(id: Int, result: MethodChannel.Result) {
        runOnExecutor("abort", result) {
            val writer = synchronized(writers) { writers.remove(id) }
            Log.i(TAG, "[save] abort writer=$id bytes=${writer?.bytes ?: 0}")
            if (writer != null) {
                runCatching { writer.output.close() }
                deleteDocument(writer.uri)
            }
            null
        }
    }

    private fun copy(
        path: String?,
        source: String?,
        uriText: String,
        result: MethodChannel.Result,
    ) {
        val target = Uri.parse(uriText)
        runOnExecutor("copy", result) {
            Log.i(TAG, "[save] copy start from=${if (path != null) "file" else "document"}")
            var bytes = 0L
            try {
                // Opened inside: a source that is gone also removes the
                // (empty) document the dialog created.
                val input: InputStream = when {
                    path != null -> privateFile(path).inputStream()
                    source != null -> openSource(Uri.parse(source))
                    else -> throw SourceMissing()
                }
                input.use { from ->
                    val output = resolver.openOutputStream(target, "wt")
                        ?: throw FileNotFoundException("no output stream")
                    output.use { to ->
                        val buffer = ByteArray(COPY_BUFFER_BYTES)
                        while (true) {
                            val read = from.read(buffer)
                            if (read < 0) break
                            to.write(buffer, 0, read)
                            bytes += read
                        }
                        to.flush()
                    }
                }
            } catch (error: Throwable) {
                // A half-written document is no copy: remove it.
                Log.w(TAG, "[save] copy stopped bytes=$bytes, partial document deleted")
                deleteDocument(target)
                throw error
            }
            Log.i(TAG, "[save] copy end bytes=$bytes")
            bytes
        }
    }

    private fun view(uriText: String, result: MethodChannel.Result) {
        val uri = Uri.parse(uriText)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, typeOf(uri))
            clipData = ClipData.newRawUri("document", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            applicationContext.startActivity(intent)
            Log.i(TAG, "[save] view launched")
            result.success(null)
        } catch (error: ActivityNotFoundException) {
            Log.w(TAG, "[save] view failed type=${error.javaClass.simpleName}")
            result.error(UNSUPPORTED, "no app to open it", null)
        } catch (error: SecurityException) {
            Log.w(TAG, "[save] view failed type=${error.javaClass.simpleName}")
            result.error(PERMISSION, null, null)
        }
    }

    private fun share(uriText: String, result: MethodChannel.Result) {
        val uri = Uri.parse(uriText)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = typeOf(uri)
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri("document", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(send, null).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            applicationContext.startActivity(chooser)
            Log.i(TAG, "[save] share launched")
            result.success(null)
        } catch (error: ActivityNotFoundException) {
            Log.w(TAG, "[save] share failed type=${error.javaClass.simpleName}")
            result.error(UNSUPPORTED, "no app to share with", null)
        } catch (error: SecurityException) {
            Log.w(TAG, "[save] share failed type=${error.javaClass.simpleName}")
            result.error(PERMISSION, null, null)
        }
    }

    /** A saved document to copy again: gone is said as gone. */
    private fun openSource(uri: Uri): InputStream = try {
        resolver.openInputStream(uri) ?: throw SourceMissing()
    } catch (_: FileNotFoundException) {
        throw SourceMissing()
    }

    /** Only the app's own private files can be copied out. */
    private fun privateFile(path: String): File {
        val root = applicationContext.dataDir.canonicalFile
        val file = try {
            File(path).canonicalFile
        } catch (_: IOException) {
            throw SourceMissing()
        }
        if (!file.path.startsWith(root.path + File.separator)) {
            throw SecurityException("outside the app's private data")
        }
        if (!file.isFile) throw SourceMissing()
        return file
    }

    private fun deleteDocument(uri: Uri) {
        val deleted = runCatching { DocumentsContract.deleteDocument(resolver, uri) }
        Log.i(
            TAG,
            "[save] delete ok=${deleted.getOrDefault(false)} " +
                "type=${deleted.exceptionOrNull()?.javaClass?.simpleName ?: "-"}",
        )
    }

    private fun typeOf(uri: Uri): String =
        runCatching { resolver.getType(uri) }.getOrNull()
            ?: "application/octet-stream"

    private fun mimeTypeOf(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
    }

    private fun <T> runOnExecutor(
        method: String,
        result: MethodChannel.Result,
        work: () -> T,
    ) {
        try {
            executor.execute {
                val outcome = runCatching(work)
                mainHandler.post {
                    outcome.fold(
                        onSuccess = { value -> result.success(value) },
                        onFailure = { error ->
                            val code = codeOf(error)
                            Log.w(
                                TAG,
                                "[save] $method failed type=${error.javaClass.simpleName} code=$code",
                            )
                            result.error(code, error.javaClass.simpleName, null)
                        },
                    )
                }
            }
        } catch (error: RejectedExecutionException) {
            Log.w(TAG, "[save] $method failed type=${error.javaClass.simpleName}")
            result.error(FAILED, error.javaClass.simpleName, null)
        }
    }

    private fun codeOf(error: Throwable): String = when {
        error is SourceMissing -> SOURCE_MISSING
        error is SecurityException -> PERMISSION
        error.isNoSpace() -> NO_SPACE
        error is FileNotFoundException || error is UnsupportedOperationException ->
            UNSUPPORTED
        else -> FAILED
    }

    private fun Throwable.isNoSpace(): Boolean {
        var cause: Throwable? = this
        while (cause != null) {
            if (cause is ErrnoException && cause.errno == OsConstants.ENOSPC) return true
            val message = cause.message.orEmpty()
            if (message.contains("ENOSPC") || message.contains("No space left")) return true
            cause = cause.cause
        }
        return false
    }

    private class SourceMissing : Exception("source missing")

    override fun close() {
        Log.i(TAG, "[save] handler closed pendingPick=${pendingPick != null}")
        pendingPick?.error(PICKER_NOT_SHOWN, "closed", null)
        pendingPick = null
        synchronized(writers) {
            writers.values.forEach { writer ->
                runCatching { writer.output.close() }
                deleteDocument(writer.uri)
            }
            writers.clear()
        }
        executor.shutdownNow()
    }

    companion object {
        const val CHANNEL_NAME = "hermes/save_to_device"
        private const val TAG = "HermesSave"
        private const val PICKER_NOT_SHOWN = "picker_not_shown"
        private const val COPY_BUFFER_BYTES = 256 * 1024
        private const val NO_SPACE = "no_space"
        private const val PERMISSION = "permission"
        private const val UNSUPPORTED = "unsupported"
        private const val SOURCE_MISSING = "source_missing"
        private const val FAILED = "failed"
    }
}

/** ACTION_CREATE_DOCUMENT with a suggested name and its MIME type. */
class SaveCreateDocument : ActivityResultContract<Pair<String, String>, Uri?>() {
    override fun createIntent(context: Context, input: Pair<String, String>): Intent =
        Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = input.second
            putExtra(Intent.EXTRA_TITLE, input.first)
        }

    override fun parseResult(resultCode: Int, intent: Intent?): Uri? =
        if (resultCode == Activity.RESULT_OK) intent?.data else null
}
