package com.hermesagent.hermes_android

import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

private const val DRAIN_WORK = "hermes-notification-action-drain-v1"
private const val SWEEP_WORK = "hermes-notification-action-expiry-v1"
private const val DRAIN_ENTRYPOINT_LIBRARY =
    "package:hermes_android/core/services/notifications/notification_action_drain.dart"
private const val DRAIN_ENTRYPOINT = "hermesNotificationActionDrain"
private const val DRAIN_TIMEOUT_MS = 90_000L
private const val DRAIN_ROUNDS = 3

/**
 * Executes notification / widget taps when no Flutter engine is alive (UI
 * swiped away, listener off). An expedited one-shot job boots a headless
 * engine on the Dart drain entrypoint, which answers through the exact same
 * server calls as the app and then says `drainFinished`. Bounded: at most
 * [DRAIN_ROUNDS] drains of [DRAIN_TIMEOUT_MS]; no periodic work.
 */
internal class HermesActionDrainWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val context = applicationContext
        repeat(DRAIN_ROUNDS) {
            if (!HermesNotificationActionInbox.hasPending(context)) return finish(context)
            if (HermesRichNotifications.hasExecutor()) {
                // The UI or the listener is alive: it owns the drain.
                HermesRichNotifications.notifyActionsAvailable()
                return finish(context)
            }
            if (!runHeadlessDrain(context)) {
                // No engine could start: tell the user now instead of letting
                // "Sending…" lapse silently. Reply text stays for the app.
                HermesNotificationActionInbox.expireUnexecuted(context, all = true)
                return Result.success()
            }
        }
        return finish(context)
    }

    private fun finish(context: Context): Result {
        HermesNotificationActionInbox.expireUnexecuted(context, all = false)
        return Result.success()
    }

    /** True when the engine ran the entrypoint (finished or timed out). */
    private suspend fun runHeadlessDrain(context: Context): Boolean {
        val finished = CompletableDeferred<Unit>()
        val handle =
            withContext(Dispatchers.Main) {
                try {
                    val loader = FlutterInjector.instance().flutterLoader()
                    loader.startInitialization(context)
                    loader.ensureInitializationComplete(context, null)
                    val engine = FlutterEngine(context)
                    val channel =
                        MethodChannel(engine.dartExecutor.binaryMessenger, HermesRichNotifications.CHANNEL_NAME)
                    HermesRichNotifications.attach(context, channel) { finished.complete(Unit) }
                    engine.dartExecutor.executeDartEntrypoint(
                        DartExecutor.DartEntrypoint(
                            loader.findAppBundlePath(),
                            DRAIN_ENTRYPOINT_LIBRARY,
                            DRAIN_ENTRYPOINT,
                        ),
                    )
                    engine to channel
                } catch (error: Exception) {
                    android.util.Log.w("HermesActionDrain", "headless engine failed: ${error.javaClass.simpleName}")
                    null
                }
            } ?: return false
        withTimeoutOrNull(DRAIN_TIMEOUT_MS) { finished.await() }
        withContext(Dispatchers.Main) {
            HermesRichNotifications.detach(handle.second)
            try {
                handle.first.destroy()
            } catch (_: Exception) {
            }
        }
        return true
    }

    override suspend fun getForegroundInfo(): ForegroundInfo {
        // Only used for expedited work before Android 12.
        HermesRichNotifications.ensureChannels(applicationContext)
        val notification =
            NotificationCompat.Builder(applicationContext, HermesRichNotifications.CH_LIVE)
                .setSmallIcon(R.drawable.ic_stat_hermes)
                .setContentTitle(applicationContext.getString(R.string.rich_brand))
                .setContentText(applicationContext.getString(R.string.rich_sending))
                .setSilent(true)
                .setOngoing(true)
                .build()
        return ForegroundInfo(0x4E07, notification)
    }
}

/** One-shot, non-periodic scheduling around the action inbox. */
internal object HermesActionDrainScheduler {
    fun drainNow(context: Context) {
        val request =
            OneTimeWorkRequestBuilder<HermesActionDrainWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
        try {
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniqueWork(DRAIN_WORK, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
        } catch (_: Exception) {
            HermesNotificationActionInbox.expireUnexecuted(context, all = true)
        }
    }

    /** Guarantees a "Couldn't send" instead of a silently lapsing "Sending…". */
    fun scheduleExpirySweep(context: Context) {
        val request =
            OneTimeWorkRequestBuilder<HermesActionExpiryWorker>()
                .setInitialDelay(HermesNotificationActionInbox.TTL_MS + 15_000L, TimeUnit.MILLISECONDS)
                .build()
        try {
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniqueWork(SWEEP_WORK, ExistingWorkPolicy.REPLACE, request)
        } catch (_: Exception) {
        }
    }

    fun rescheduleExpirySweep(context: Context) {
        val request =
            OneTimeWorkRequestBuilder<HermesActionExpiryWorker>()
                .setInitialDelay(HermesNotificationActionInbox.TTL_MS, TimeUnit.MILLISECONDS)
                .build()
        try {
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniqueWork(SWEEP_WORK, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
        } catch (_: Exception) {
        }
    }
}

/** No network, no Flutter: flips overdue taps to a visible failure. */
internal class HermesActionExpiryWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        HermesNotificationActionInbox.expireUnexecuted(applicationContext, all = false)
        if (HermesNotificationActionInbox.hasPending(applicationContext)) {
            HermesActionDrainScheduler.rescheduleExpirySweep(applicationContext)
        }
        return Result.success()
    }
}
