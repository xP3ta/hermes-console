package com.hermesagent.hermes_android

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlin.math.roundToInt

/**
 * Rasteriza páginas PDF desde el almacén privado de adjuntos enviados.
 *
 * El canal solo acepta una clave SHA-256, nunca una ruta. Antes de abrir el
 * descriptor revalida raíz canónica, tamaño y digest; un symlink, traversal o
 * marcador manipulado falla cerrado. No lanza intents ni exporta los bytes.
 */
class HermesDocumentPreviewHandler(
    context: Context,
) : MethodChannel.MethodCallHandler, AutoCloseable {
    private val applicationContext = context.applicationContext
    private val filesRoot = applicationContext.filesDir.canonicalFile
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "openGeneratedFile") {
            openGeneratedFile(call, result)
            return
        }
        if (call.method != "renderPdfPage") {
            result.notImplemented()
            return
        }
        val storageKey = call.argument<String>("storageKey").orEmpty()
        val pageIndex = (call.argument<Number>("page"))?.toInt() ?: -1
        val expectedSize = (call.argument<Number>("expectedSize"))?.toLong() ?: -1L
        val expectedSha256 = call.argument<String>("expectedSha256").orEmpty()
        val generatedConnectionKey = call.argument<String>("generatedConnectionKey").orEmpty()
        val generatedFileKey = call.argument<String>("generatedFileKey").orEmpty()
        try {
            executor.execute {
                val response = runCatching {
                    renderPdfPage(
                        storageKey = storageKey,
                        pageIndex = pageIndex,
                        expectedSize = expectedSize,
                        expectedSha256 = expectedSha256,
                        generatedConnectionKey = generatedConnectionKey,
                        generatedFileKey = generatedFileKey,
                    )
                }
                mainHandler.post {
                    response.fold(
                        onSuccess = result::success,
                        onFailure = {
                            result.error(
                                "preview_unavailable",
                                "The private PDF preview is unavailable",
                                null,
                            )
                        },
                    )
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error(
                "preview_unavailable",
                "The private PDF preview is unavailable",
                null,
            )
        }
    }

    private fun renderPdfPage(
        storageKey: String,
        pageIndex: Int,
        expectedSize: Long,
        expectedSha256: String,
        generatedConnectionKey: String,
        generatedFileKey: String,
    ): Map<String, Any> {
        val file = resolveValidatedFile(
            storageKey = storageKey,
            expectedSize = expectedSize,
            expectedSha256 = expectedSha256,
            generatedConnectionKey = generatedConnectionKey,
            generatedFileKey = generatedFileKey,
            maxGeneratedBytes = MAX_GENERATED_PDF_BYTES,
        )

        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                require(pageIndex in 0 until minOf(renderer.pageCount, MAX_RENDERED_PAGES))
                renderer.openPage(pageIndex).use { page ->
                    var width = minOf(MAX_RENDER_WIDTH, (page.width * 2).coerceAtLeast(1))
                    var height = (page.height * (width.toDouble() / page.width)).roundToInt()
                        .coerceAtLeast(1)
                    if (height > MAX_RENDER_HEIGHT) {
                        height = MAX_RENDER_HEIGHT
                        width = (page.width * (height.toDouble() / page.height)).roundToInt()
                            .coerceAtLeast(1)
                    }
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    try {
                        bitmap.eraseColor(Color.WHITE)
                        page.render(
                            bitmap,
                            null,
                            null,
                            PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY,
                        )
                        val output = ByteArrayOutputStream()
                        require(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
                        return mapOf(
                            "pngBytes" to output.toByteArray(),
                            "pageCount" to renderer.pageCount,
                            "pageIndex" to pageIndex,
                        )
                    } finally {
                        bitmap.recycle()
                    }
                }
            }
        }
    }

    private fun openGeneratedFile(call: MethodCall, result: MethodChannel.Result) {
        val storageKey = call.argument<String>("storageKey").orEmpty()
        val expectedSize = (call.argument<Number>("expectedSize"))?.toLong() ?: -1L
        val expectedSha256 = call.argument<String>("expectedSha256").orEmpty()
        val generatedConnectionKey = call.argument<String>("generatedConnectionKey").orEmpty()
        val generatedFileKey = call.argument<String>("generatedFileKey").orEmpty()
        val mimeType = call.argument<String>("mimeType").orEmpty()
        try {
            executor.execute {
                val response = runCatching {
                    require(generatedConnectionKey.isNotEmpty())
                    require(generatedFileKey.isNotEmpty())
                    resolveValidatedFile(
                        storageKey = storageKey,
                        expectedSize = expectedSize,
                        expectedSha256 = expectedSha256,
                        generatedConnectionKey = generatedConnectionKey,
                        generatedFileKey = generatedFileKey,
                        maxGeneratedBytes = MAX_GENERATED_FILE_BYTES,
                    )
                }
                mainHandler.post {
                    response.fold(
                        onSuccess = { file ->
                            runCatching { launchExternalViewer(file, mimeType) }.fold(
                                onSuccess = { result.success(null) },
                                onFailure = {
                                    result.error(
                                        "open_unavailable",
                                        "No application can open this private file",
                                        null,
                                    )
                                },
                            )
                        },
                        onFailure = {
                            result.error(
                                "open_unavailable",
                                "The private file is unavailable",
                                null,
                            )
                        },
                    )
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error("open_unavailable", "The private file is unavailable", null)
        }
    }

    private fun resolveValidatedFile(
        storageKey: String,
        expectedSize: Long,
        expectedSha256: String,
        generatedConnectionKey: String,
        generatedFileKey: String,
        maxGeneratedBytes: Long,
    ): File {
        require(storageKey.matches(SHA256_PATTERN))
        require(expectedSha256.matches(SHA256_PATTERN))
        val generated = generatedConnectionKey.isNotEmpty() || generatedFileKey.isNotEmpty()
        val file = if (generated) {
            require(generatedConnectionKey.matches(SHA256_PATTERN))
            require(generatedFileKey.matches(SHA256_PATTERN))
            require(expectedSize in 1..maxGeneratedBytes)
            resolveGeneratedMedia(generatedConnectionKey, generatedFileKey)
        } else {
            require(expectedSha256 == storageKey)
            require(expectedSize in 1..MAX_ATTACHMENT_BYTES)
            resolveSentAttachment(storageKey)
        }
        require(file.length() == expectedSize)
        require(file.sha256() == expectedSha256)
        return file
    }

    private fun launchExternalViewer(file: File, requestedMimeType: String) {
        val mimeType = requestedMimeType.takeIf { it.matches(MIME_TYPE_PATTERN) }
            ?: "application/octet-stream"
        val uri = FileProvider.getUriForFile(
            applicationContext,
            "${applicationContext.packageName}.generated_file_provider",
            file,
        )
        val viewIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            clipData = ClipData.newRawUri("generated file", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(viewIntent, null).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        applicationContext.startActivity(chooser)
    }

    private fun resolveSentAttachment(storageKey: String): File {
        val unresolvedDirectory = File(filesRoot, SENT_ATTACHMENTS_DIRECTORY).absoluteFile
        val directory = unresolvedDirectory.canonicalFile
        require(directory == unresolvedDirectory)
        require(directory.parentFile == filesRoot)
        require(directory.isDirectory)
        val unresolved = File(directory, storageKey).absoluteFile
        val file = unresolved.canonicalFile
        require(file == unresolved)
        require(file.parentFile == directory)
        require(file.isFile)
        return file
    }

    private fun resolveGeneratedMedia(connectionKey: String, fileKey: String): File {
        val unresolvedRoot = File(filesRoot, GENERATED_MEDIA_DIRECTORY).absoluteFile
        val root = unresolvedRoot.canonicalFile
        require(root == unresolvedRoot)
        require(root.parentFile == filesRoot)
        require(root.isDirectory)
        val unresolvedDirectory = File(root, connectionKey).absoluteFile
        val directory = unresolvedDirectory.canonicalFile
        require(directory == unresolvedDirectory)
        require(directory.parentFile == root)
        require(directory.isDirectory)
        val candidates = directory.listFiles { candidate ->
            candidate.isFile && candidate.name.substringBefore('.') == fileKey
        }.orEmpty()
        require(candidates.size == 1)
        val unresolved = candidates.single().absoluteFile
        val file = unresolved.canonicalFile
        require(file == unresolved)
        require(file.parentFile == directory)
        return file
    }

    private fun File.sha256(): String {
        val digest = MessageDigest.getInstance("SHA-256")
        inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    override fun close() {
        executor.shutdownNow()
    }

    private companion object {
        const val SENT_ATTACHMENTS_DIRECTORY = "sent_attachments"
        const val GENERATED_MEDIA_DIRECTORY = "generated_media"
        const val MAX_ATTACHMENT_BYTES = 8L * 1024L * 1024L
        const val MAX_GENERATED_PDF_BYTES = 20L * 1024L * 1024L
        const val MAX_GENERATED_FILE_BYTES = 100L * 1024L * 1024L
        const val MAX_RENDERED_PAGES = 40
        const val MAX_RENDER_WIDTH = 1440
        const val MAX_RENDER_HEIGHT = 4096
        val SHA256_PATTERN = Regex("^[a-f0-9]{64}$")
        val MIME_TYPE_PATTERN = Regex("^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$")
    }
}
