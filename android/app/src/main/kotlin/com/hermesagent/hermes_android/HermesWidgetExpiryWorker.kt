package com.hermesagent.hermes_android

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import es.antonborri.home_widget.HomeWidgetPlugin
import java.util.concurrent.TimeUnit

private const val EXPIRY_WORK_NAME = "hermes-widget-snapshot-expiry-v1"

/**
 * Redraws placed widgets once when their already-published snapshot becomes
 * old. It performs no network, Flutter callback or self-rescheduling.
 */
internal class HermesWidgetExpiryWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val data = HomeWidgetPlugin.getData(applicationContext)
        val now = System.currentTimeMillis()
        val legacyStale = HermesWidgetState.from(data).isStale(now)
        val botMode = BotModeWidgetState.from(data)
        // Stale snapshot, or a done/failed outcome whose window ended.
        val botModeDue = botMode.isStale(now) || botMode.hasExpiredOutcome(now)
        if (!legacyStale && !botModeDue) return Result.success()
        requestWidgetUpdates(applicationContext)
        return Result.success()
    }
}

internal object HermesWidgetExpiryScheduler {
    fun replace(
        context: Context,
        state: HermesWidgetState,
        nowMs: Long = System.currentTimeMillis(),
    ) {
        val staleAtMs = state.staleAtMs() ?: return
        val delayMs = staleAtMs - nowMs
        // A stale snapshot is rendered immediately by the current update. It
        // must not create a background loop just to confirm that it is stale.
        if (delayMs <= 0) return
        val request =
            OneTimeWorkRequestBuilder<HermesWidgetExpiryWorker>()
                .setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
                .build()
        WorkManager
            .getInstance(context.applicationContext)
            .enqueueUniqueWork(EXPIRY_WORK_NAME, ExistingWorkPolicy.REPLACE, request)
    }
}

/** Original Hermes Console widgets (1.2.13 receivers, HermesConsoleGlanceWidget). */
internal fun originalWidgetReceivers(): List<Class<*>> =
    listOf(
        NewSessionWidgetProvider::class.java,
        HermesCompactWidgetProvider::class.java,
        HermesControlWidgetProvider::class.java,
    )

private fun requestWidgetUpdates(context: Context) {
    // Both families: the original widgets and the Bot Mode widgets.
    for (receiver in originalWidgetReceivers()) updateReceiver(context, receiver)
    for (receiver in botModeWidgetReceivers()) updateReceiver(context, receiver)
}

private fun updateReceiver(
    context: Context,
    receiver: Class<*>,
) {
    val component = ComponentName(context, receiver)
    val ids = AppWidgetManager.getInstance(context).getAppWidgetIds(component)
    if (ids.isEmpty()) return
    context.sendBroadcast(
        Intent(context, receiver)
            .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids),
    )
}
