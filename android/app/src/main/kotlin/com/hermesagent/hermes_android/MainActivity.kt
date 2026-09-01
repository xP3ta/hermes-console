package com.hermesagent.hermes_android

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.UiModeManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.StatFs
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

// FlutterFragmentActivity (no FlutterActivity): BiometricPrompt de local_auth
// solo funciona con hosts FragmentActivity.
//
// Canal nativo "hermes/android_apps": detectar / abrir apps externas y lanzar
// el instalador del agente en Termux. La UI nunca toca intents directamente;
// todo pasa por el adaptador Dart `AndroidApps`.
class MainActivity : FlutterFragmentActivity() {
    private val channelName = "hermes/android_apps"
    private val securityChannelName = "hermes/security"
    private val appearanceChannelName = "hermes/appearance"
    private val voiceNotificationCardChannelName = "hermes/voice_notification_card"
    private val shareChannelName = "hermes/share"
    private val systemGesturesChannelName = "hermes/system_gestures"
    private val pcmStreamChannelName = "hermes/pcm_stream"
    private val fullDuplexCaptureChannelName = "hermes/full_duplex_capture"
    private val fullDuplexCaptureEventsName = "hermes/full_duplex_capture_events"
    private val documentPreviewChannelName = "hermes/document_preview"
    private val memoryChannelName = "hermes/memory"
    private val platformInfoChannelName = "hermes/platform_info"
    private val foregroundRestartContractChannelName =
        "hermes/foreground_restart_contract"
    private val foregroundExternalDataSyncChannelName =
        "hermes/foreground_external_data_sync"
    private var shareChannel: MethodChannel? = null
    private var newSessionLaunchChannel: MethodChannel? = null
    private var memoryChannel: MethodChannel? = null
    private var externalDataSyncChannel: MethodChannel? = null
    private var pcmStreamHandler: HermesPcmStreamHandler? = null
    private var fullDuplexCaptureHandler: HermesFullDuplexCaptureHandler? = null
    private var documentPreviewHandler: HermesDocumentPreviewHandler? = null
    private var pendingShare: Map<String, Any?>? = null
    private var pendingNewSessionLaunch: Map<String, Any?>? = null
    private var pendingExternalDataSyncStop = false
    private var externalDataSyncStopReceiverRegistered = false
    private val externalDataSyncStopReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action !=
                    HermesExternalDataSyncService.ACTION_OWNER_STOP_REQUIRED
                ) {
                    return
                }
                deliverExternalDataSyncStop()
            }
        }

    // Permiso (dangerous) que exige el RunCommandService de Termux. Se
    // auto-concede si la Consola se instala DESPUÉS de Termux, pero al reinstalar
    // el APK (desarrollo) se pierde; entonces hay que pedirlo en runtime.
    private val termuxRunPermission = "com.termux.permission.RUN_COMMAND"
    private val termuxPermissionRequestCode = 4242

    override fun onCreate(savedInstanceState: Bundle?) {
        val externalDataSyncStop =
            HermesExternalDataSyncService.consumeStopRequest(intent)
        val launchPayload = NewSessionLaunchContract.parse(intent)
        // Estos URI son un contrato interno del widget, no deep links de la
        // aplicación. Flutter debe recibir el Intent ya neutralizado para que
        // WidgetsApp no intente resolver /open_app/... como una ruta nombrada.
        NewSessionLaunchContract.neutralize(intent)
        super.onCreate(savedInstanceState)
        ContextCompat.registerReceiver(
            this,
            externalDataSyncStopReceiver,
            IntentFilter(HermesExternalDataSyncService.ACTION_OWNER_STOP_REQUIRED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        externalDataSyncStopReceiverRegistered = true
        pendingShare = parseShareIntent(intent)
        pendingNewSessionLaunch = launchPayload
        pendingExternalDataSyncStop = externalDataSyncStop
    }

    override fun onNewIntent(intent: Intent) {
        val externalDataSyncStop =
            HermesExternalDataSyncService.consumeStopRequest(intent)
        val launchPayload = NewSessionLaunchContract.parse(intent)
        NewSessionLaunchContract.neutralize(intent)
        super.onNewIntent(intent)
        setIntent(intent)
        parseShareIntent(intent)?.let { payload ->
            // Conservarlo hasta que Flutter lo consuma. La bandeja Dart deduplica
            // por id, así una recreación de Activity nunca abre dos borradores.
            pendingShare = payload
            shareChannel?.invokeMethod("shareReceived", payload)
        }
        launchPayload?.let { payload ->
            deliverNewSessionLaunch(payload)
        }
        if (externalDataSyncStop) {
            deliverExternalDataSyncStop()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        documentPreviewHandler?.close()
        documentPreviewHandler = HermesDocumentPreviewHandler(applicationContext).also { handler ->
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                documentPreviewChannelName,
            ).setMethodCallHandler(handler)
        }
        pcmStreamHandler?.close()
        val pcmHandler = HermesPcmStreamHandler(applicationContext)
        pcmStreamHandler = pcmHandler.also { handler ->
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                pcmStreamChannelName,
            ).setMethodCallHandler(handler)
        }
        fullDuplexCaptureHandler?.close()
        fullDuplexCaptureHandler =
            HermesFullDuplexCaptureHandler(
                applicationContext,
                privateOutputProbe = { pcmHandler.hasPrivateOutput() },
            ).also { handler ->
                MethodChannel(
                    flutterEngine.dartExecutor.binaryMessenger,
                    fullDuplexCaptureChannelName,
                ).setMethodCallHandler(handler)
                EventChannel(
                    flutterEngine.dartExecutor.binaryMessenger,
                    fullDuplexCaptureEventsName,
                ).setStreamHandler(handler)
            }
        memoryChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            memoryChannelName,
        )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            platformInfoChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            foregroundRestartContractChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "persist" -> {
                    HermesForegroundRestartContract.persist(applicationContext)
                    result.success(null)
                }
                "prepareRuntimeService" -> {
                    val applied =
                        try {
                            HermesForegroundServiceGate.prepareRuntimeService(
                                applicationContext,
                            )
                            true
                        } catch (_: Exception) {
                            false
                        }
                    result.success(applied)
                }
                "hardStopRuntimeService" -> {
                    val applied =
                        try {
                            HermesForegroundServiceGate.hardStopRuntimeService(
                                applicationContext,
                            )
                            true
                        } catch (_: Exception) {
                            false
                        }
                    result.success(applied)
                }
                else -> result.notImplemented()
            }
        }
        externalDataSyncChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            foregroundExternalDataSyncChannelName,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setRequired" -> {
                        val required = call.argument<Boolean>("required") ?: false
                        val applied =
                            try {
                                if (required) {
                                    HermesExternalDataSyncService.start(applicationContext)
                                } else {
                                    HermesExternalDataSyncService.stop(applicationContext)
                                }
                                true
                            } catch (_: Exception) {
                                false
                            }
                        result.success(applied)
                    }
                    "takePendingStopRequested" -> {
                        val pending =
                            pendingExternalDataSyncStop ||
                                HermesExternalDataSyncService.hasPendingOwnerStop(
                                    applicationContext,
                                )
                        result.success(pending)
                    }
                    "acknowledgeStopRequested" -> {
                        pendingExternalDataSyncStop = false
                        HermesExternalDataSyncService.acknowledgeOwnerStop(
                            applicationContext,
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            shareChannelName,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "takePendingShare" -> {
                        val payload = pendingShare ?: parseShareIntent(intent)
                        pendingShare = null
                        result.success(payload)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        newSessionLaunchChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                NewSessionLaunchContract.CHANNEL_NAME,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "takePendingLaunchAction" -> {
                            val payload =
                                pendingNewSessionLaunch
                                    ?: NewSessionLaunchContract.parse(intent)
                            pendingNewSessionLaunch = null
                            NewSessionLaunchContract.neutralize(intent)
                            result.success(payload)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            systemGesturesChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setDrawerEdgeExclusion" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    applyDrawerEdgeExclusion(enabled)
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, securityChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecureScreen" -> {
                        val enabled = call.arguments as? Boolean ?: false
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appearanceChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setBrightness" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val brightness = call.argument<String>("brightness")
                            val mode = if (brightness == "light") {
                                UiModeManager.MODE_NIGHT_NO
                            } else {
                                UiModeManager.MODE_NIGHT_YES
                            }
                            val uiModeManager =
                                getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                            uiModeManager.setApplicationNightMode(mode)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            voiceNotificationCardChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "apply" -> result.success(
                    VoiceNotificationCardAdapter.apply(
                        applicationContext,
                        call.argument<Boolean>("paused") ?: false,
                        call.argument<String>("expectedPrimaryAction") ?: "",
                        call.argument<String>("stateLabel") ?: "",
                        call.argument<String>("microphoneLabel") ?: "",
                        call.argument<String>("openHintLabel") ?: "",
                        call.argument<String>("orbDescription") ?: "",
                        call.argument<String>("durationDescription") ?: "",
                    )
                )
                "inspect" -> result.success(
                    VoiceNotificationCardAdapter.inspect(applicationContext)
                )
                "clear" -> {
                    VoiceNotificationCardAdapter.clear()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isInstalled" ->
                        result.success(isPackageInstalled(call.argument<String>("package") ?: ""))
                    "launch" ->
                        result.success(launchPackage(call.argument<String>("package") ?: ""))
                    "runInTermux" ->
                        result.success(
                            runInTermux(
                                call.argument<String>("command") ?: "",
                                call.argument<Boolean>("background") ?: true
                            )
                        )
                    "launchTermuxForeground" ->
                        result.success(
                            launchTermuxForeground(call.argument<String>("command") ?: "")
                        )
                    "probeTermux" ->
                        probeTermux(call.argument<String>("command") ?: "", result)
                    "deviceInfo" -> result.success(deviceInfo())
                    "openAppSettings" -> result.success(openAppSettings())
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        if (externalDataSyncStopReceiverRegistered) {
            unregisterReceiver(externalDataSyncStopReceiver)
            externalDataSyncStopReceiverRegistered = false
        }
        externalDataSyncChannel = null
        newSessionLaunchChannel = null
        memoryChannel = null
        documentPreviewHandler?.close()
        documentPreviewHandler = null
        fullDuplexCaptureHandler?.close()
        fullDuplexCaptureHandler = null
        pcmStreamHandler?.close()
        pcmStreamHandler = null
        super.onDestroy()
    }

    private fun deliverExternalDataSyncStop() {
        pendingExternalDataSyncStop = true
        val channel = externalDataSyncChannel ?: return
        channel.invokeMethod(
            "stopRequested",
            null,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    // El handler Dart ya canceló SSH/SFTP. Consumir la orden
                    // solo ahora evita que una recreación de Activity aplique
                    // este Stop antiguo a una transferencia posterior.
                    pendingExternalDataSyncStop = false
                    HermesExternalDataSyncService.acknowledgeOwnerStop(
                        applicationContext,
                    )
                }

                override fun error(
                    errorCode: String,
                    errorMessage: String?,
                    errorDetails: Any?,
                ) = Unit

                override fun notImplemented() = Unit
            },
        )
    }

    // Flutter solo expone didHaveMemoryPressure (señal binaria que también se
    // dispara al ir a background). Reenviamos el nivel real para que Dart
    // distinga presión genuina de un simple cambio de visibilidad de la UI.
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        Log.d("HermesVoiceStab", "onTrimMemory level=$level")
        memoryChannel?.invokeMethod("trimMemory", mapOf("level" to level))
    }

    private fun deliverNewSessionLaunch(payload: Map<String, Any?>) {
        pendingNewSessionLaunch = payload
        val channel = newSessionLaunchChannel ?: return
        val deliveredEventId = payload["native_event_id"]
        channel.invokeMethod(
            "launchActionReceived",
            payload,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (pendingNewSessionLaunch?.get("native_event_id") == deliveredEventId) {
                        pendingNewSessionLaunch = null
                        NewSessionLaunchContract.neutralize(intent)
                    }
                }

                override fun error(
                    errorCode: String,
                    errorMessage: String?,
                    errorDetails: Any?,
                ) = Unit

                override fun notImplemented() = Unit
            },
        )
    }

    private fun parseShareIntent(source: Intent?): Map<String, Any?>? {
        if (source == null ||
            (source.action != Intent.ACTION_SEND &&
                source.action != Intent.ACTION_SEND_MULTIPLE)
        ) {
            return null
        }

        val subject = source.getStringExtra(Intent.EXTRA_SUBJECT)
            ?.trim()
            ?.take(512)
            .orEmpty()
        val body = source.getCharSequenceExtra(Intent.EXTRA_TEXT)
            ?.toString()
            ?.trim()
            ?.take(65536)
            .orEmpty()
        val text = when {
            subject.isEmpty() -> body
            body.isEmpty() -> subject
            body.startsWith(subject) -> body
            else -> "$subject\n\n$body"
        }

        val uris = linkedSetOf<Uri>()
        if (source.action == Intent.ACTION_SEND_MULTIPLE) {
            uris.addAll(parcelableUriList(source))
        } else {
            parcelableUri(source)?.let(uris::add)
        }
        source.clipData?.let { clip ->
            for (index in 0 until clip.itemCount.coerceAtMost(10)) {
                clip.getItemAt(index).uri?.let(uris::add)
            }
        }

        val attachments = mutableListOf<Map<String, Any>>()
        var rejected = 0
        var batchBytes = 0L
        for (uri in uris.take(10)) {
            val copied = copySharedUri(
                uri,
                fallbackMime = source.type,
                remainingBatchBytes = MAX_SHARE_BATCH_BYTES - batchBytes,
            )
            if (copied == null) {
                rejected += 1
                continue
            }
            attachments.add(copied)
            batchBytes += copied["size_bytes"] as Long
        }

        if (text.isEmpty() && attachments.isEmpty() && rejected == 0) return null
        return mapOf(
            "id" to "share-${UUID.randomUUID()}",
            "text" to text,
            "attachments" to attachments,
            "rejected_attachments" to rejected,
        )
    }

    @Suppress("DEPRECATION")
    private fun parcelableUri(source: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            source.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            source.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    @Suppress("DEPRECATION")
    private fun parcelableUriList(source: Intent): List<Uri> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            source.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                ?: emptyList()
        } else {
            source.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                ?: emptyList()
        }

    private fun copySharedUri(
        uri: Uri,
        fallbackMime: String?,
        remainingBatchBytes: Long,
    ): Map<String, Any>? {
        if (remainingBatchBytes <= 0L) return null
        val mime = contentResolver.getType(uri)
            ?.takeIf { it.length <= 160 }
            ?: fallbackMime?.takeIf { it.length <= 160 }
            ?: "application/octet-stream"
        val displayName = sharedDisplayName(uri, mime)
        val extension = displayName.substringAfterLast('.', "")
            .takeIf { it.matches(Regex("[A-Za-z0-9]{1,10}")) }
            ?: MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
        val directory = File(cacheDir, "shared_intents").apply { mkdirs() }
        val target = File(
            directory,
            buildString {
                append(UUID.randomUUID())
                if (!extension.isNullOrBlank()) append(".${extension.lowercase()}")
            },
        )
        val itemLimit = minOf(MAX_SHARE_ITEM_BYTES, remainingBatchBytes)
        return try {
            val input = contentResolver.openInputStream(uri) ?: return null
            var written = 0L
            input.use { stream ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = stream.read(buffer)
                        if (count < 0) break
                        written += count
                        if (written > itemLimit) {
                            throw IllegalArgumentException("shared item too large")
                        }
                        output.write(buffer, 0, count)
                    }
                }
            }
            if (written <= 0L) {
                target.delete()
                return null
            }
            mapOf(
                "type" to if (mime.startsWith("image/")) "image" else "document",
                "name" to displayName,
                "mime_type" to mime,
                "size_bytes" to written,
                "local_path" to target.absolutePath,
            )
        } catch (_: Exception) {
            target.delete()
            null
        }
    }

    private fun sharedDisplayName(uri: Uri, mime: String): String {
        var candidate = ""
        try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) candidate = cursor.getString(0).orEmpty()
            }
        } catch (_: Exception) {
            // Algunos providers no implementan DISPLAY_NAME.
        }
        candidate = candidate
            .substringAfterLast('/')
            .replace(Regex("[\\u0000\\r\\n]"), "_")
            .trim()
            .take(120)
        if (candidate.isNotEmpty()) return candidate
        val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
        return if (extension.isNullOrBlank()) "shared-file" else "shared-file.$extension"
    }

    private fun applyDrawerEdgeExclusion(enabled: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val root = window.decorView
        if (!enabled) {
            root.systemGestureExclusionRects = emptyList()
            return
        }

        root.post {
            val density = resources.displayMetrics.density
            val width = (24 * density).toInt().coerceAtLeast(1)
            // Android solo garantiza hasta 200 dp de exclusión por borde. Una
            // banda central hace fiable el drawer sin anular Atrás en toda la
            // altura ni tocar el borde derecho.
            val height = (200 * density)
                .toInt()
                .coerceAtMost(root.height)
                .coerceAtLeast(1)
            val top = ((root.height - height) / 2).coerceAtLeast(0)
            root.systemGestureExclusionRects = listOf(
                Rect(0, top, width, top + height),
            )
        }
    }

    companion object {
        private const val MAX_SHARE_ITEM_BYTES = 8L * 1024L * 1024L
        private const val MAX_SHARE_BATCH_BYTES = 24L * 1024L * 1024L
    }

    private fun openAppSettings(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    // RAM total y ABIs soportadas, para estimar qué modelos GGUF caben.
    private fun deviceInfo(): Map<String, Any> {
        val mi = ActivityManager.MemoryInfo()
        (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
            .getMemoryInfo(mi)
        return mapOf(
            "totalRamBytes" to mi.totalMem,
            "availRamBytes" to mi.availMem,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "freeDiskBytes" to freeDiskBytes()
        )
    }

    // Bytes libres en /data (mismo sistema de ficheros que usa Termux), para el
    // pre-flight de instalación del agente local.
    private fun freeDiskBytes(): Long {
        return try {
            StatFs(filesDir.absolutePath).availableBytes
        } catch (e: Exception) {
            -1L
        }
    }

    private fun isPackageInstalled(pkg: String): Boolean {
        if (pkg.isEmpty()) return false
        return try {
            packageManager.getPackageInfo(pkg, 0)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun launchPackage(pkg: String): Boolean {
        if (pkg.isEmpty()) return false
        return try {
            val intent = packageManager.getLaunchIntentForPackage(pkg) ?: return false
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    // Lanza un comando en Termux vía el servicio RUN_COMMAND. Requiere que el
    // usuario tenga Termux con `allow-external-apps=true` y conceda el permiso
    // com.termux.permission.RUN_COMMAND; si no es posible, devuelve false y la
    // UI ofrece reintento/cancelación.
    //
    // background=true: corre sin abrir terminal; la app
    //   muestra el progreso leyendo el log por localhost). Es el modo normal.
    // background=false existe por compatibilidad con Termux, pero la app no lo
    //   usa en flujos de usuario.
    // ¿Está concedido el permiso RUN_COMMAND de Termux?
    private fun hasTermuxRunPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, termuxRunPermission) ==
            PackageManager.PERMISSION_GRANTED

    // Pide al sistema excluir a Termux del ahorro de batería (Doze / App
    // Standby). Sin esto, Android congela com.termux y mata los procesos en
    // background lanzados por RUN_COMMAND (gateway/dashboard del agente local)
    // antes de que terminen de arrancar — el instalador se quedaba esperando la
    // salida del wrapper indefinidamente. Best-effort: si ya está excluido o el
    // diálogo no se puede mostrar, no hace nada.
    @android.annotation.SuppressLint("BatteryLife")
    private fun whitelistTermux() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations("com.termux")) {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                intent.data = Uri.parse("package:com.termux")
                startActivity(intent)
            }
        } catch (e: Exception) {
            // ignorar: es una optimización best-effort, no bloquea el flujo.
        }
    }

    @SuppressLint("SdCardPath") // Rutas contractuales de la API RUN_COMMAND de Termux.
    private fun runInTermux(command: String, background: Boolean): Boolean {
        if (command.isEmpty()) return false
        // Antes de lanzar el RUN_COMMAND, asegurar que Termux no será congelado
        // por App Standby mientras el proceso background corre (ver Bug 1).
        if (background) whitelistTermux()
        // Safety net: si el permiso no está concedido (p.ej. tras reinstalar el
        // APK en desarrollo, donde se pierde el auto-grant), lo solicitamos en
        // runtime de forma transparente y devolvemos false. El RunCommandService
        // rechazaría el intent igualmente; tras conceder el permiso, al volver el
        // foco a la app el flujo de instalación reintenta el RUN_COMMAND.
        if (!hasTermuxRunPermission()) {
            ActivityCompat.requestPermissions(
                this, arrayOf(termuxRunPermission), termuxPermissionRequestCode
            )
            return false
        }
        return try {
            val intent = Intent()
            intent.setClassName("com.termux", "com.termux.app.RunCommandService")
            intent.action = "com.termux.RUN_COMMAND"
            intent.putExtra(
                "com.termux.RUN_COMMAND_PATH",
                "/data/data/com.termux/files/usr/bin/bash"
            )
            intent.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", command))
            intent.putExtra(
                "com.termux.RUN_COMMAND_WORKDIR",
                "/data/data/com.termux/files/home"
            )
            intent.putExtra("com.termux.RUN_COMMAND_BACKGROUND", background)
            // SESSION_ACTION 0: cuando NO es background, abre/activa la sesión en
            // primer plano para que el usuario vea la ejecución.
            intent.putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", "0")
            startServiceCompat(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    // Ejecuta un comando CORTO en Termux y devuelve su stdout a Dart usando el
    // PendingIntent de resultado de RUN_COMMAND. Es la única forma de SONDEAR el
    // sistema de archivos de Termux desde la app (p. ej. saber si el agente
    // Hermes está instalado aunque esté parado) sin servidor ni dependencias.
    //
    // Termux ejecuta el comando y, al terminar, envía un broadcast a nuestro
    // PendingIntent con un Bundle "result" {stdout, stderr, exitCode}. Registramos
    // un receiver efímero con acción única, esperamos con timeout y devolvemos el
    // stdout (o null si Termux no responde / falta el permiso / se agota).
    @SuppressLint("SdCardPath") // Rutas contractuales de la API RUN_COMMAND de Termux.
    private fun probeTermux(command: String, result: MethodChannel.Result) {
        if (command.isEmpty() || !hasTermuxRunPermission()) {
            result.success(null)
            return
        }
        val handler = android.os.Handler(mainLooper)
        val action = "$packageName.TERMUX_PROBE_RESULT.${System.nanoTime()}"
        val replied = java.util.concurrent.atomic.AtomicBoolean(false)
        var receiverRef: BroadcastReceiver? = null

        fun finish(stdout: String?) {
            if (!replied.compareAndSet(false, true)) return
            receiverRef?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
            handler.post { result.success(stdout) }
        }

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                val bundle = intent.getBundleExtra("result")
                finish(bundle?.getString("stdout"))
            }
        }
        receiverRef = receiver
        try {
            val filter = IntentFilter(action)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(receiver, filter)
            }
        } catch (e: Exception) {
            finish(null)
            return
        }
        // Red de seguridad: si Termux nunca responde, no dejamos a Dart colgado.
        handler.postDelayed({ finish(null) }, 8000)
        try {
            val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                    PendingIntent.FLAG_MUTABLE else 0)
            val callback = PendingIntent.getBroadcast(
                this, 0, Intent(action).setPackage(packageName), piFlags
            )
            val intent = Intent()
            intent.setClassName("com.termux", "com.termux.app.RunCommandService")
            intent.action = "com.termux.RUN_COMMAND"
            intent.putExtra(
                "com.termux.RUN_COMMAND_PATH",
                "/data/data/com.termux/files/usr/bin/bash"
            )
            intent.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", command))
            intent.putExtra(
                "com.termux.RUN_COMMAND_WORKDIR",
                "/data/data/com.termux/files/home"
            )
            intent.putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            intent.putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", callback)
            startServiceCompat(intent)
        } catch (e: Exception) {
            finish(null)
        }
    }

    private fun startServiceCompat(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    // Abre Termux como ACTIVIDAD en primer plano (TermuxActivity) ejecutando un
    // comando. Es la vía del BOOTSTRAP: TermuxActivity acepta los extras de
    // comando aunque `allow-external-apps` aún no esté activo, al contrario que
    // el RunCommandService (background), que lo exige. Se usa una sola vez para
    // que el propio comando active la propiedad y devuelva el foco a la Consola.
    @SuppressLint("SdCardPath") // Rutas contractuales de la API RUN_COMMAND de Termux.
    private fun launchTermuxForeground(command: String): Boolean {
        if (command.isEmpty()) return false
        return try {
            val intent = Intent()
            intent.setClassName("com.termux", "com.termux.app.TermuxActivity")
            intent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_NO_ANIMATION or
                Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or
                Intent.FLAG_FROM_BACKGROUND
            )
            intent.putExtra(
                "com.termux.RUN_COMMAND_PATH",
                "/data/data/com.termux/files/usr/bin/bash"
            )
            intent.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", command))
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
