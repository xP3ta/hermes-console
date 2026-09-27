package com.hermesagent.hermes_android

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/** Bot Mode widget snapshot (schema 2) published by Dart; read-only here. */
internal const val BOT_MODE_SNAPSHOT_KEY = "hermes_widget_botmode_v2"
internal const val BOT_MODE_SCHEMA = 2

/** The listener publishes at least every 5 min; older data is shown as stale. */
internal const val BOT_MODE_STALE_AFTER_MS = 12 * 60 * 1000L

internal enum class WidgetBotState { IDLE, THINKING, WORKING, NEEDS_YOU }

internal data class WidgetBot(
    val profile: String,
    val name: String,
    val state: WidgetBotState,
    val line: String?,
    val facePath: String?,
    val openPayload: String,
)

internal data class WidgetApproval(
    val requestId: String,
    val title: String,
    val text: String,
    val facePath: String?,
    val actionPayload: String,
    val openPayload: String,
    val canApprove: Boolean,
)

internal data class WidgetRoomMember(val name: String, val state: String, val facePath: String?)

internal data class WidgetRoom(
    val id: String,
    val name: String,
    val working: Boolean,
    val members: List<WidgetRoomMember>,
    val lastSpeaker: String?,
    val lastMessage: String?,
    val openPayload: String,
    val stopPayload: String?,
)

internal data class BotModeWidgetState(
    val connectionId: String? = null,
    val connectionLabel: String? = null,
    val connected: Boolean = false,
    val workingCount: Int = 0,
    val needsYouCount: Int = 0,
    val bots: List<WidgetBot> = emptyList(),
    val approvals: List<WidgetApproval> = emptyList(),
    val room: WidgetRoom? = null,
    val quick: WidgetBot? = null,
    val updatedAtMs: Long = 0,
) {
    val present: Boolean get() = connectionId != null

    fun isStale(nowMs: Long): Boolean =
        updatedAtMs <= 0 || nowMs - updatedAtMs > BOT_MODE_STALE_AFTER_MS

    /**
     * Never show "working" beyond the proved window: a stale snapshot demotes
     * every Bot to idle and drops the working count and room Stop.
     */
    fun trusted(nowMs: Long): BotModeWidgetState {
        if (!isStale(nowMs)) return this
        return copy(
            connected = false,
            workingCount = 0,
            bots = bots.map { if (it.state == WidgetBotState.NEEDS_YOU) it else it.copy(state = WidgetBotState.IDLE, line = null) },
            room = room?.copy(working = false, stopPayload = null, members = room.members.map { it.copy(state = if (it.state == "needs_you") it.state else "idle") }),
            quick = quick?.copy(state = WidgetBotState.IDLE, line = null),
        )
    }

    /**
     * Lock screen / communal hub rendering: informational only. No command,
     * message or worker text, and no action payloads (Approve / Deny / Stop
     * need an unlocked home screen; the receiver also refuses widget taps
     * while the keyguard shows).
     */
    fun redactedForKeyguard(): BotModeWidgetState =
        copy(
            bots = bots.map { it.copy(line = null) },
            approvals = approvals.map { it.copy(text = "", canApprove = false) },
            room = room?.copy(lastSpeaker = null, lastMessage = null, stopPayload = null),
            quick = quick?.copy(line = null),
        )

    companion object {
        fun from(preferences: SharedPreferences): BotModeWidgetState =
            parse(
                try {
                    preferences.getString(BOT_MODE_SNAPSHOT_KEY, null)
                } catch (_: ClassCastException) {
                    null
                },
            )

        fun parse(raw: String?): BotModeWidgetState {
            if (raw.isNullOrEmpty()) return BotModeWidgetState()
            return try {
                val json = JSONObject(raw)
                if (json.optInt("schema_version") != BOT_MODE_SCHEMA) return BotModeWidgetState()
                BotModeWidgetState(
                    connectionId = json.text("conn_id", 256),
                    connectionLabel = json.text("conn_label", 64),
                    connected = json.optBoolean("connected"),
                    workingCount = json.optInt("working_count").coerceAtLeast(0),
                    needsYouCount = json.optInt("needs_you_count").coerceAtLeast(0),
                    bots = json.optJSONArray("bots").objects().take(16).mapNotNull(::bot),
                    approvals = json.optJSONArray("approvals").objects().take(6).mapNotNull(::approval),
                    room = json.optJSONObject("room")?.let(::room),
                    quick = json.optJSONObject("quick")?.let(::bot),
                    updatedAtMs = json.optLong("updated_at_ms"),
                )
            } catch (_: Exception) {
                BotModeWidgetState()
            }
        }

        private fun bot(json: JSONObject): WidgetBot? {
            val profile = json.text("profile", 64) ?: return null
            return WidgetBot(
                profile = profile,
                name = json.text("name", 48) ?: profile,
                state = when (json.optString("state")) {
                    "working" -> WidgetBotState.WORKING
                    "thinking" -> WidgetBotState.THINKING
                    "needsYou" -> WidgetBotState.NEEDS_YOU
                    else -> WidgetBotState.IDLE
                },
                line = json.text("line", 80),
                facePath = json.text("face", 512),
                openPayload = json.text("open", 4000) ?: return null,
            )
        }

        private fun approval(json: JSONObject): WidgetApproval? =
            WidgetApproval(
                requestId = json.text("rid", 256) ?: return null,
                title = json.text("title", 80) ?: "",
                text = json.text("text", 160) ?: "",
                facePath = json.text("face", 512),
                actionPayload = json.text("action", 4000) ?: return null,
                openPayload = json.text("open", 4000) ?: return null,
                canApprove = json.optBoolean("approve", true),
            )

        private fun room(json: JSONObject): WidgetRoom? =
            WidgetRoom(
                id = json.text("id", 256) ?: return null,
                name = json.text("name", 64) ?: "",
                working = json.optBoolean("working"),
                members = json.optJSONArray("members").objects().take(6).map {
                    WidgetRoomMember(
                        it.text("name", 48) ?: "",
                        it.text("state", 16) ?: "idle",
                        it.text("face", 512),
                    )
                },
                lastSpeaker = json.text("last_speaker", 48),
                lastMessage = json.text("last_message", 160),
                openPayload = json.text("open", 4000) ?: return null,
                stopPayload = json.text("stop", 4000),
            )
    }
}

private fun JSONObject.text(name: String, max: Int): String? =
    if (isNull(name)) null else optString(name, "").trim().takeIf { it.isNotEmpty() }?.take(max)

private fun JSONArray?.objects(): List<JSONObject> {
    this ?: return emptyList()
    return (0 until length()).mapNotNull { optJSONObject(it) }
}
