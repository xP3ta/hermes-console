package com.hermesagent.hermes_android

import android.app.ActivityManager
import android.app.UiModeManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Rect
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
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
// Canal nativo "hermes/android_apps": detectar / abrir apps externas y consultar
// el dispositivo. La UI nunca toca intents directamente; todo pasa por
// el adaptador Dart `AndroidApps`.
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
    private val networkAvailabilityEventsName = "hermes/network_availability"
    private val platformInfoChannelName = "hermes/platform_info"
    private val foregroundRestartContractChannelName =
        "hermes/foreground_restart_contract"
    private val foregroundExternalDataSyncChannelName =
        "hermes/foreground_external_data_sync"
    private var shareChannel: MethodChannel? = null
    private var richNotificationsChannel: MethodChannel? = null
    private var newSessionLaunchChannel: MethodChannel? = null
    private var memoryChannel: MethodChannel? = null
    private var externalDataSyncChannel: MethodChannel? = null
    private var pcmStreamHandler: HermesPcmStreamHandler? = null
    private var fullDuplexCaptureHandler: HermesFullDuplexCaptureHandler? = null
    private var documentPreviewHandler: HermesDocumentPreviewHandler? = null
    private var clipboardImageHandler: HermesClipboardImageHandler? = null
    private var pendingShare: Map<String, Any?>? = null
    private var pendingNewSessionLaunch: Map<String, Any?>? = null
    private var pendingExternalDataSyncStop = false
    private var externalDataSyncStopReceiverRegistered = false
    private var networkAvailabilitySink: EventChannel.EventSink? = null
    private var networkCallbackRegistered = false
    private var validatedNetwork: Network? = null
    private val networkCallback =
        object : ConnectivityManager.NetworkCallback() {
            // Wi-Fi can call onAvailable before validation and a captive portal
            // has INTERNET without VALIDATED: only a validated network counts
            // (developer.android.com "Read network state").
            override fun onCapabilitiesChanged(
                network: Network,
                caps: NetworkCapabilities,
            ) {
                val validated =
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                if (!validated) {
                    if (validatedNetwork == network) validatedNetwork = null
                    return
                }
                if (validatedNetwork == network) return
                validatedNetwork = network
                val sink = networkAvailabilitySink ?: return
                runOnUiThread {
                    if (networkAvailabilitySink === sink) sink.success("available")
                }
            }

            override fun onLost(network: Network) {
                if (validatedNetwork == network) validatedNetwork = null
                val sink = networkAvailabilitySink ?: return
                runOnUiThread {
                    if (networkAvailabilitySink === sink) sink.success("lost")
                }
            }
        }
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
        DurableSecretWriter.attach(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        clipboardImageHandler?.close()
        clipboardImageHandler = HermesClipboardImageHandler(applicationContext).also { handler ->
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                HermesClipboardImageHandler.CHANNEL_NAME,
            ).setMethodCallHandler(handler)
        }
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
        richNotificationsChannel?.let { HermesRichNotifications.detach(it) }
        richNotificationsChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                HermesRichNotifications.CHANNEL_NAME,
            ).also { HermesRichNotifications.attach(applicationContext, it) }
        stopNetworkAvailabilityEvents()
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            networkAvailabilityEventsName,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    startNetworkAvailabilityEvents(events)
                }

                override fun onCancel(arguments: Any?) {
                    stopNetworkAvailabilityEvents()
                }
            },
        )
        val liveAudioEvents = HermesLiveAudioEvents(applicationContext)
        liveAudioEvents.installFocusListener()
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hermes/live_audio_events",
        ).setStreamHandler(liveAudioEvents)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            platformInfoChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                "getPerformanceClass" -> {
                    val activity =
                        getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val power = getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(
                        mapOf(
                            "lowRamDevice" to activity.isLowRamDevice,
                            "powerSaveMode" to power.isPowerSaveMode,
                        ),
                    )
                }
                "getInstallerPackage" -> {
                    val installer =
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                packageManager.getInstallSourceInfo(packageName)
                                    .installingPackageName
                            } else {
                                @Suppress("DEPRECATION")
                                packageManager.getInstallerPackageName(packageName)
                            }
                        } catch (_: Exception) {
                            null
                        }
                    result.success(installer)
                }
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
                    "deviceInfo" -> result.success(deviceInfo())
                    "openAppSettings" -> result.success(openAppSettings())
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        richNotificationsChannel?.let { HermesRichNotifications.detach(it) }
        richNotificationsChannel = null
        if (externalDataSyncStopReceiverRegistered) {
            unregisterReceiver(externalDataSyncStopReceiver)
            externalDataSyncStopReceiverRegistered = false
        }
        externalDataSyncChannel = null
        newSessionLaunchChannel = null
        memoryChannel = null
        stopNetworkAvailabilityEvents()
        documentPreviewHandler?.close()
        documentPreviewHandler = null
        clipboardImageHandler?.close()
        clipboardImageHandler = null
        fullDuplexCaptureHandler?.close()
        fullDuplexCaptureHandler = null
        pcmStreamHandler?.close()
        pcmStreamHandler = null
        super.onDestroy()
    }

    private fun startNetworkAvailabilityEvents(events: EventChannel.EventSink) {
        stopNetworkAvailabilityEvents()
        networkAvailabilitySink = events
        val connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        try {
            connectivityManager.registerDefaultNetworkCallback(networkCallback)
            networkCallbackRegistered = true
        } catch (_: SecurityException) {
            networkAvailabilitySink = null
            events.error("network_state_unavailable", null, null)
        }
    }

    private fun stopNetworkAvailabilityEvents() {
        networkAvailabilitySink = null
        validatedNetwork = null
        if (!networkCallbackRegistered) return
        val connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        try {
            connectivityManager.unregisterNetworkCallback(networkCallback)
        } catch (_: IllegalArgumentException) {
            // The platform already removed the callback with the Activity.
        }
        networkCallbackRegistered = false
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
            // Compartir un enlace pega solo el enlace: el título de la página
            // (EXTRA_SUBJECT) no es lo que la persona quiso enviar.
            SHARED_LINK_ONLY.matches(body) -> body
            subject.isEmpty() -> body
            body.isEmpty() -> subject
            body.startsWith(subject) -> body
            else -> "$subject\n\n$body"
        }

        // En un compartido de texto (enlace, selección) los URI de EXTRA_STREAM
        // y del ClipData son la vista previa que añade la app emisora (la
        // miniatura de la página), no un archivo elegido por la persona. Un
        // archivo de texto compartido sin cuerpo sí sigue adjuntándose.
        val isTextShare = source.type?.startsWith("text/") == true
        val streamsArePreview = source.action == Intent.ACTION_SEND &&
            isTextShare &&
            body.isNotEmpty()

        val uris = linkedSetOf<Uri>()
        if (!streamsArePreview) {
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
        if (uri.scheme != "content" || remainingBatchBytes <= 0L) return null
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

        /** Un único enlace http(s) sin espacios ni saltos de línea. */
        private val SHARED_LINK_ONLY = Regex("^https?://\\S+$", RegexOption.IGNORE_CASE)
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

    // Bytes libres en el sistema de ficheros de los datos de la aplicación.
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
}
