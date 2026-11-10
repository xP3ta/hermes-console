package com.hermesagent.hermes_android

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

private const val LIVE_CHECK_WORK = "hermes-live-turn-check-v1"
private const val KEY_ATTEMPT = "attempt"
private const val KEY_CHAIN_START = "chainStartMs"

/** Hard stop of a chain, whatever Dart answers (Dart's own window is 10 min). */
private const val CHAIN_MAX_MS = 11L * 60 * 1000
private const val CHECK_TIMEOUT_MS = 45_000L

/** Next run when the engine did not answer (busy, slow, no handler): the chain goes on. */
private const val NO_ANSWER_RETRY_MS = 60_000L

/**
 * Bounded background check of the chat turn rows while the app is in the
 * background and its sockets are cut. Each run: a row whose engine is gone
 * is withdrawn here; otherwise the owning engine (the UI one, woken from
 * the freezer by this job) is asked `checkLiveTurns`, which (never under
 * App Lock, where Dart schedules no chain) reads the chat's latest rows once
 * to end and announce the rows of finished turns. Rows keep their last
 * real state; only reads that fail to reach the server twice in a row mark
 * them «no connection · retrying».
 * It is told which of its sessions still have a row in the tray, so a row
 * already withdrawn is not announced again. Without an answer the
 * chain goes on. Dart answers when the next run is due; the chain never
 * outlives [CHAIN_MAX_MS]. No wakelock beyond WorkManager's own, no
 * foreground service, no new permission.
 */
internal class HermesLiveTurnCheckWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val context = applicationContext
        val attempt = inputData.getInt(KEY_ATTEMPT, 0)
        val chainStart = inputData.getLong(KEY_CHAIN_START, System.currentTimeMillis())
        val elapsed = System.currentTimeMillis() - chainStart
        if (elapsed > CHAIN_MAX_MS) return Result.success()
        val rows = HermesRichNotifications.liveTurnRows(context)
        // Owner -> sessions whose row is still in the tray (others may have
        // been withdrawn while the owner was frozen).
        val owners = LinkedHashMap<MethodChannel, MutableSet<String>>()
        for (row in rows) {
            val owner = row.owner
            if (owner == null) {
                HermesRichNotifications.cancelLiveTurnRow(context, row)
            } else {
                val sessions = owners.getOrPut(owner) { LinkedHashSet() }
                row.sessionId?.let { sessions.add(it) }
            }
        }
        if (owners.isEmpty()) return Result.success()
        var nextDelayMs: Long? = null
        for ((owner, sessions) in owners) {
            val answer = ask(owner, attempt, elapsed, sessions.toList())
            if (answer == null) {
                // No answer is not "nothing pending": its rows are still in
                // the tray, so the chain asks again (bounded by CHAIN_MAX_MS).
                nextDelayMs = minOf(nextDelayMs ?: NO_ANSWER_RETRY_MS, NO_ANSWER_RETRY_MS)
                continue
            }
            val pending = (answer["pending"] as? Number)?.toInt() ?: 0
            val next = (answer["nextDelayMs"] as? Number)?.toLong()
            if (pending > 0 && next != null && next > 0) {
                nextDelayMs = minOf(nextDelayMs ?: next, next)
            }
        }
        val delay = nextDelayMs
        if (delay != null && elapsed + delay <= CHAIN_MAX_MS) {
            HermesLiveTurnCheckScheduler.enqueue(context, delay, attempt + 1, chainStart, ExistingWorkPolicy.APPEND_OR_REPLACE)
        }
        return Result.success()
    }

    private suspend fun ask(
        owner: MethodChannel,
        attempt: Int,
        elapsed: Long,
        sessions: List<String>,
    ): Map<*, *>? {
        val answer = CompletableDeferred<Map<*, *>?>()
        withContext(Dispatchers.Main) {
            try {
                owner.invokeMethod(
                    "checkLiveTurns",
                    mapOf("attempt" to attempt, "elapsedMs" to elapsed, "sessions" to sessions),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            answer.complete(result as? Map<*, *>)
                        }

                        override fun error(code: String, message: String?, details: Any?) {
                            answer.complete(null)
                        }

                        override fun notImplemented() {
                            answer.complete(null)
                        }
                    },
                )
            } catch (_: Exception) {
                answer.complete(null)
            }
        }
        return withTimeoutOrNull(CHECK_TIMEOUT_MS) { answer.await() }
    }
}

internal object HermesLiveTurnCheckScheduler {
    /** The app went to the background with a live row: a chain starts unless one runs. */
    fun start(context: Context, delayMs: Long) {
        enqueue(context, delayMs.coerceAtLeast(15_000L), 0, System.currentTimeMillis(), ExistingWorkPolicy.KEEP)
    }

    fun enqueue(context: Context, delayMs: Long, attempt: Int, chainStartMs: Long, policy: ExistingWorkPolicy) {
        val request =
            OneTimeWorkRequestBuilder<HermesLiveTurnCheckWorker>()
                .setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
                .setInputData(workDataOf(KEY_ATTEMPT to attempt, KEY_CHAIN_START to chainStartMs))
                .build()
        try {
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniqueWork(LIVE_CHECK_WORK, policy, request)
        } catch (_: Exception) {
            // Without WorkManager the rows' own bounded lifetime applies.
        }
    }

    /** Back in front: the chats' sockets own their rows again. */
    fun cancel(context: Context) {
        try {
            WorkManager.getInstance(context.applicationContext).cancelUniqueWork(LIVE_CHECK_WORK)
        } catch (_: Exception) {
        }
    }
}
