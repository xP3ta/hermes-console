package com.hermesagent.hermes_android

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/** Cron section of the launcher widgets (schema 1), published by Dart; read-only here. */
internal const val CRON_SNAPSHOT_KEY = "hermes_widget_cron_v1"
internal const val CRON_SCHEMA = 1

/**
 * A schedule read a while ago is still a schedule, so old jobs stay on the
 * widget; from this age on it also says since when it has had no news.
 */
internal const val CRON_STALE_AFTER_MS = 15 * 60 * 1000L

internal enum class CronWidgetResult { NONE, OK, FAILED, RUNNING }

internal data class CronWidgetJob(
    val id: String,
    val name: String,
    /** 0 when the job has no next run (paused, a one-shot that already ran). */
    val nextMs: Long,
    val lastMs: Long,
    val last: CronWidgetResult,
    val paused: Boolean,
    val openPayload: String?,
) {
    /** It is known when this job runs next. */
    fun scheduledAfter(nowMs: Long): Boolean = nextMs > nowMs
}

internal data class CronWidgetState(
    val connectionId: String? = null,
    val updatedAtMs: Long = 0,
    val jobs: List<CronWidgetJob> = emptyList(),
) {
    /** The app has listed the jobs at least once. */
    val present: Boolean get() = connectionId != null

    fun isStale(nowMs: Long): Boolean = updatedAtMs <= 0 || nowMs - updatedAtMs > CRON_STALE_AFTER_MS

    val failedCount: Int get() = jobs.count { it.last == CronWidgetResult.FAILED }

    /**
     * Jobs in the order the widget lists them at [nowMs]: the ones still to
     * run, soonest first; then the ones whose time has passed with no news
     * since (their result is not known here); then the ones with no next run.
     */
    fun ordered(nowMs: Long): List<CronWidgetJob> {
        val (ahead, rest) = jobs.partition { it.scheduledAfter(nowMs) }
        val (passed, unscheduled) = rest.partition { it.nextMs > 0 }
        return ahead.sortedBy { it.nextMs } + passed.sortedByDescending { it.nextMs } + unscheduled
    }

    /**
     * The first [count] rows of [ordered], with one rule on top: a job whose
     * last run failed is never the one left out. It takes the place of the
     * last row that did not fail.
     */
    fun rows(nowMs: Long, count: Int): List<CronWidgetJob> {
        val all = ordered(nowMs)
        if (count <= 0) return emptyList()
        if (all.size <= count) return all
        val shown = all.take(count).toMutableList()
        for (hidden in all.drop(count).filter { it.last == CronWidgetResult.FAILED }) {
            val replace = shown.indexOfLast { it.last != CronWidgetResult.FAILED }
            if (replace < 0) break
            shown[replace] = hidden
        }
        // Still by next run, whatever was swapped in.
        val order = all.withIndex().associate { it.value.id to it.index }
        return shown.sortedBy { order[it.id] ?: Int.MAX_VALUE }
    }

    /** When a drawing made at [nowMs] stops being true by itself. */
    fun nextChangeAtMs(nowMs: Long): Long? {
        if (!present) return null
        val times = buildList {
            if (updatedAtMs > 0) add(updatedAtMs + CRON_STALE_AFTER_MS + 1)
            for (job in jobs) if (job.nextMs > nowMs) add(job.nextMs + 1)
        }
        return times.filter { it > nowMs }.minOrNull()
    }

    companion object {
        fun from(preferences: SharedPreferences): CronWidgetState =
            parse(
                try {
                    preferences.getString(CRON_SNAPSHOT_KEY, null)
                } catch (_: ClassCastException) {
                    null
                },
            )

        fun parse(raw: String?): CronWidgetState {
            if (raw.isNullOrEmpty()) return CronWidgetState()
            return try {
                val json = JSONObject(raw)
                if (json.optInt("schema_version") != CRON_SCHEMA) return CronWidgetState()
                CronWidgetState(
                    connectionId = json.cronText("conn_id", 256) ?: return CronWidgetState(),
                    updatedAtMs = json.optLong("updated_at_ms").coerceAtLeast(0),
                    jobs = json.optJSONArray("jobs").cronObjects().take(24).mapNotNull(::job),
                )
            } catch (_: Exception) {
                CronWidgetState()
            }
        }

        private fun job(json: JSONObject): CronWidgetJob? =
            CronWidgetJob(
                id = json.cronText("id", 256) ?: return null,
                name = json.cronText("name", 120) ?: return null,
                nextMs = json.optLong("next_ms").coerceAtLeast(0),
                lastMs = json.optLong("last_ms").coerceAtLeast(0),
                last =
                    when (json.optString("last")) {
                        "ok" -> CronWidgetResult.OK
                        "failed" -> CronWidgetResult.FAILED
                        "running" -> CronWidgetResult.RUNNING
                        else -> CronWidgetResult.NONE
                    },
                paused = json.optBoolean("paused"),
                openPayload = json.cronText("open", 4000),
            )
    }
}

private fun JSONObject.cronText(name: String, max: Int): String? =
    if (isNull(name)) null else optString(name, "").trim().takeIf { it.isNotEmpty() }?.take(max)

private fun JSONArray?.cronObjects(): List<JSONObject> {
    this ?: return emptyList()
    return (0 until length()).mapNotNull { optJSONObject(it) }
}
