package com.hermesagent.hermes_android

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/** Tareas section of the launcher widgets (schema 1), published by Dart; read-only here. */
internal const val TASKS_SNAPSHOT_KEY = "hermes_widget_tasks_v1"
internal const val TASKS_SCHEMA = 1

/** From this age on the widget says since when it has had no news of the board. */
internal const val TASKS_STALE_AFTER_MS = 15 * 60 * 1000L

internal enum class TaskWidgetState { RUNNING, ATTENTION, PENDING }

internal data class TaskWidgetTask(
    val id: String,
    val title: String,
    val state: TaskWidgetState,
    val assignee: String?,
    val openPayload: String?,
)

internal data class TasksWidgetState(
    val connectionId: String? = null,
    val updatedAtMs: Long = 0,
    /** Counts over the whole board, not only the cards listed here. */
    val running: Int = 0,
    val attention: Int = 0,
    val pending: Int = 0,
    /** Open cards: in progress first, then waiting for the owner, then pending. */
    val tasks: List<TaskWidgetTask> = emptyList(),
) {
    /** The app has read the board at least once. */
    val present: Boolean get() = connectionId != null

    val open: Int get() = running + attention + pending

    fun isStale(nowMs: Long): Boolean = updatedAtMs <= 0 || nowMs - updatedAtMs > TASKS_STALE_AFTER_MS

    /** When a drawing made at [nowMs] stops being true by itself. */
    fun nextChangeAtMs(nowMs: Long): Long? =
        (updatedAtMs + TASKS_STALE_AFTER_MS + 1).takeIf { present && updatedAtMs > 0 && it > nowMs }

    companion object {
        fun from(preferences: SharedPreferences): TasksWidgetState =
            parse(
                try {
                    preferences.getString(TASKS_SNAPSHOT_KEY, null)
                } catch (_: ClassCastException) {
                    null
                },
            )

        fun parse(raw: String?): TasksWidgetState {
            if (raw.isNullOrEmpty()) return TasksWidgetState()
            return try {
                val json = JSONObject(raw)
                if (json.optInt("schema_version") != TASKS_SCHEMA) return TasksWidgetState()
                TasksWidgetState(
                    connectionId = json.taskText("conn_id", 256) ?: return TasksWidgetState(),
                    updatedAtMs = json.optLong("updated_at_ms").coerceAtLeast(0),
                    running = json.optInt("running").coerceAtLeast(0),
                    attention = json.optInt("attention").coerceAtLeast(0),
                    pending = json.optInt("pending").coerceAtLeast(0),
                    tasks = json.optJSONArray("tasks").taskObjects().take(12).mapNotNull(::task),
                )
            } catch (_: Exception) {
                TasksWidgetState()
            }
        }

        private fun task(json: JSONObject): TaskWidgetTask? =
            TaskWidgetTask(
                id = json.taskText("id", 256) ?: return null,
                title = json.taskText("title", 120) ?: return null,
                state =
                    when (json.optString("state")) {
                        "running" -> TaskWidgetState.RUNNING
                        "attention" -> TaskWidgetState.ATTENTION
                        else -> TaskWidgetState.PENDING
                    },
                assignee = json.taskText("assignee", 64),
                openPayload = json.taskText("open", 4000),
            )
    }
}

private fun JSONObject.taskText(name: String, max: Int): String? =
    if (isNull(name)) null else optString(name, "").trim().takeIf { it.isNotEmpty() }?.take(max)

private fun JSONArray?.taskObjects(): List<JSONObject> {
    this ?: return emptyList()
    return (0 until length()).mapNotNull { optJSONObject(it) }
}
