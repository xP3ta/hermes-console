package com.hermesagent.hermes_android

import android.app.ForegroundServiceStartNotAllowedException
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import com.pravera.flutter_foreground_task.PreferencesKey
import com.pravera.flutter_foreground_task.models.ForegroundServiceAction
import com.pravera.flutter_foreground_task.models.ForegroundServiceStatus
import com.pravera.flutter_foreground_task.models.ForegroundServiceTypes
import com.pravera.flutter_foreground_task.models.ForegroundTaskOptions
import com.pravera.flutter_foreground_task.service.ForegroundService

/**
 * Durable restart contract for the single foreground service.
 *
 * Runtime may temporarily combine microphone/mediaPlayback/dataSync with the
 * user's automation opt-in. None of those transient owners is restartable from
 * background. The persisted contract therefore contains only remoteMessaging
 * on Android 15+ (dataSync on older Android), or a developer-stopped marker
 * when the user did not opt in. This also makes START_STICKY process recovery
 * safe: the plugin reloads this sanitized state, never the transient types.
 */
object HermesForegroundRestartContract {
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val AUTOMATION_OPT_IN = "flutter.notif_background_listen"

    fun automationEnabled(context: Context): Boolean =
        context
            .getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
            .getBoolean(AUTOMATION_OPT_IN, false)

    fun persist(context: Context) {
        // La preferencia nativa es la única autoridad. El isolate del servicio
        // y la UI mantienen caches distintas de SharedPreferences; aceptar un
        // booleano Dart permitiría que un update en vuelo reactivase el contrato
        // después de que Stop ya hubiese persistido false.
        val enabled = automationEnabled(context)
        ForegroundTaskOptions.updateData(
            context,
            mapOf(
                PreferencesKey.AUTO_RUN_ON_BOOT to enabled,
                PreferencesKey.AUTO_RUN_ON_MY_PACKAGE_REPLACED to enabled,
                PreferencesKey.ALLOW_AUTO_RESTART to false,
                PreferencesKey.STOP_WITH_TASK to false,
            ),
        )
        if (enabled) {
            // flutter_foreground_task's wire values: 9=remoteMessaging,
            // 2=dataSync. Persist exactly one automation type, never a runtime
            // union containing microphone/mediaPlayback or an SSH/SFTP lease.
            val automationTypes =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
                    listOf(9)
                } else {
                    listOf(2)
                }
            ForegroundServiceTypes.setData(
                context,
                mapOf(PreferencesKey.FOREGROUND_SERVICE_TYPES to automationTypes),
            )
            ForegroundServiceStatus.setData(
                context,
                ForegroundServiceAction.API_START,
            )
        } else {
            ForegroundServiceTypes.clearData(context)
            // The already-running transient owner is not stopped here. If the
            // process dies, START_STICKY reloads API_STOP and exits non-sticky.
            ForegroundServiceStatus.setData(
                context,
                ForegroundServiceAction.API_STOP,
            )
        }
    }
}

/**
 * Hard gate around flutter_foreground_task's mutable API_START/UPDATE/STOP
 * preference. Disabling the component makes Stop authoritative even if an old
 * service-isolate poll writes API_UPDATE after the user's request.
 */
object HermesForegroundServiceGate {
    private fun component(context: Context) =
        ComponentName(context, ForegroundService::class.java)

    fun prepareRuntimeService(context: Context) {
        context.packageManager.setComponentEnabledSetting(
            component(context),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
    }

    fun hardStopRuntimeService(context: Context) {
        context.packageManager.setComponentEnabledSetting(
            component(context),
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
        context.stopService(Intent(context, ForegroundService::class.java))
        ForegroundServiceStatus.setData(context, ForegroundServiceAction.API_STOP)
    }
}

/** Owns BOOT_COMPLETED/package-replaced so ephemeral plugin state cannot win. */
class HermesAutomationRebootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null || !isSupported(intent.action)) return
        val enabled = HermesForegroundRestartContract.automationEnabled(context)
        // Sanea también el estado viejo al recibir boot/package-replaced con el
        // opt-in desactivado; no basta con retornar y dejar API_START durable.
        HermesForegroundRestartContract.persist(context)
        if (!enabled) {
            HermesForegroundServiceGate.hardStopRuntimeService(context)
            return
        }

        HermesForegroundServiceGate.prepareRuntimeService(context)
        ForegroundServiceStatus.setData(context, ForegroundServiceAction.REBOOT)
        try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, ForegroundService::class.java),
            )
        } catch (error: ForegroundServiceStartNotAllowedException) {
            Log.e(TAG, "automation foreground restart not allowed", error)
        } catch (error: Exception) {
            Log.e(TAG, "automation foreground restart failed", error)
        }
    }

    private fun isSupported(action: String?): Boolean =
        action == Intent.ACTION_BOOT_COMPLETED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED

    private companion object {
        const val TAG = "HermesAutomationBoot"
    }
}
