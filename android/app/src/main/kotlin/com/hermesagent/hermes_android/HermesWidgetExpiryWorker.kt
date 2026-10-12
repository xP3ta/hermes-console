package com.hermesagent.hermes_android

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

private const val EXPIRY_WORK_NAME = "hermes-launcher-widget-expiry-v2"

/**
 * Redraws placed widgets once, at the moment something they already show
 * stops being true by itself (data becomes old, a "done" outcome expires).
 * It performs no network, no Flutter callback and no self-rescheduling: the
 * redraw it triggers decides whether another moment is worth waiting for.
 */
internal class HermesWidgetExpiryWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        LauncherWidgetExpiry.fired()
        LauncherWidgets.requestUpdate(applicationContext, launcherWidgetReceivers())
        return Result.success()
    }
}

/** One pending redraw for the whole family, at the earliest moment any widget needs. */
internal object LauncherWidgetExpiry {
    /** Never sooner than this: a redraw is cheap, a loop of them is not. */
    private const val MIN_DELAY_MS = 30_000L

    @Volatile
    private var scheduledFor: Long = 0

    fun fired() {
        scheduledFor = 0
    }

    fun schedule(
        context: Context,
        dueAtMs: Long?,
        nowMs: Long = System.currentTimeMillis(),
    ) {
        // What is drawn now already tells the truth and nothing in it expires.
        dueAtMs ?: return
        if (dueAtMs <= nowMs) return
        // Every redraw asks again: the same moment is not enqueued twice.
        if (dueAtMs == scheduledFor) return
        val request =
            OneTimeWorkRequestBuilder<HermesWidgetExpiryWorker>()
                .setInitialDelay(maxOf(dueAtMs - nowMs, MIN_DELAY_MS), TimeUnit.MILLISECONDS)
                .build()
        try {
            WorkManager
                .getInstance(context.applicationContext)
                .enqueueUniqueWork(EXPIRY_WORK_NAME, ExistingWorkPolicy.REPLACE, request)
            scheduledFor = dueAtMs
        } catch (_: Exception) {
        }
    }
}
