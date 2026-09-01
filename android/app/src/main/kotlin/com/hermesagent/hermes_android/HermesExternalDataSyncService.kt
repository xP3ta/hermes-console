package com.hermesagent.hermes_android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Lease nativa efímera para SSH/SFTP en Android 15+.
 *
 * Mantener dataSync fuera del servicio Flutter permanente es deliberado: su
 * cuota/timeout del sistema puede terminar esta transferencia, pero nunca el
 * listener remoteMessaging de chats, Cron y Kanban. No restaura trabajo tras
 * process death, boot ni actualización y no conserva destinos ni credenciales.
 */
class HermesExternalDataSyncService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_START) {
            stopNow()
            return START_NOT_STICKY
        }
        createChannel()
        val notification =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_hermes)
                .setContentTitle("Hermes Console")
                .setContentText(getString(R.string.external_data_sync_active))
                .setContentIntent(openAppIntent())
                .addAction(
                    0,
                    getString(R.string.external_data_sync_stop),
                    stopOwnersIntent(),
                )
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setSilent(true)
                .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForegroundCompat()
        super.onDestroy()
    }

    override fun onTimeout(startId: Int) {
        requestOwnerStop(this)
        stopNow()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        requestOwnerStop(this)
        stopNow()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.external_data_sync_channel),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(R.string.external_data_sync_active)
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            },
        )
    }

    private fun openAppIntent(): PendingIntent {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val flags =
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE
                } else {
                    0
                }
        return PendingIntent.getActivity(this, 0, launch, flags)
    }

    private fun stopOwnersIntent(): PendingIntent {
        val intent =
            Intent(this, MainActivity::class.java)
                .setAction(ACTION_STOP_REQUESTED)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val flags =
            PendingIntent.FLAG_CANCEL_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE
                } else {
                    0
                }
        return PendingIntent.getActivity(this, NOTIFICATION_ID, intent, flags)
    }

    private fun stopNow() {
        stopForegroundCompat()
        stopSelf()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    companion object {
        private const val ACTION_START =
            "dev.xpetalab.hermesconsole.action.START_EXTERNAL_DATA_SYNC"
        private const val ACTION_STOP_REQUESTED =
            "dev.xpetalab.hermesconsole.action.STOP_EXTERNAL_DATA_SYNC"
        const val ACTION_OWNER_STOP_REQUIRED =
            "dev.xpetalab.hermesconsole.action.EXTERNAL_DATA_SYNC_OWNER_STOP_REQUIRED"
        private const val CHANNEL_ID = "hermes_external_data_sync"
        private const val NOTIFICATION_ID = 257
        private const val CONTROL_PREFS = "hermes_external_data_sync_control"
        private const val PENDING_OWNER_STOP = "pending_owner_stop"

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, HermesExternalDataSyncService::class.java)
                    .setAction(ACTION_START),
            )
        }

        fun stop(context: Context) {
            context.stopService(
                Intent(context, HermesExternalDataSyncService::class.java),
            )
        }

        fun consumeStopRequest(intent: Intent?): Boolean {
            if (intent?.action != ACTION_STOP_REQUESTED) return false
            // Flutter recibe un launch neutro: esta acción es control interno,
            // no una ruta/deep-link visible para Navigator.
            intent.action = Intent.ACTION_MAIN
            return true
        }

        fun requestOwnerStop(context: Context) {
            // commit() hace durable la orden antes de devolver el timeout al
            // sistema. Si Flutter no está vivo, se consumirá al próximo host.
            context.getSharedPreferences(CONTROL_PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(PENDING_OWNER_STOP, true)
                .commit()
            context.sendBroadcast(
                Intent(ACTION_OWNER_STOP_REQUIRED).setPackage(context.packageName),
            )
        }

        fun hasPendingOwnerStop(context: Context): Boolean =
            context.getSharedPreferences(CONTROL_PREFS, Context.MODE_PRIVATE)
                .getBoolean(PENDING_OWNER_STOP, false)

        fun acknowledgeOwnerStop(context: Context) {
            context.getSharedPreferences(CONTROL_PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(PENDING_OWNER_STOP, false)
                .commit()
        }
    }
}
