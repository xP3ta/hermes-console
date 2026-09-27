package com.hermesagent.hermes_android

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/** Bot Mode widget snapshot (schema 2) published by Dart; read-only here. */
internal const val BOT_MODE_SNAPSHOT_KEY = "hermes_widget_botmode_v2"
internal const val BOT_MODE_SCHEMA = 2

/** The listener publishes at least every 5 min; older data is shown as stale. */
internal const val BOT_MODE_STALE_AFTER_MS = 12 * 60 * 1000L

/** "Listo" / "Falló" stay this long after work ends, then the Bot goes idle. */
internal const val BOT_MODE_OUTCOME_MS = 10 * 60 * 1000L

internal enum class WidgetBotState {
    IDLE, THINKING, WORKING, NEEDS_YOU, DONE, FAILED;

    val isLive: Boolean get() = this == THINKING || this == WORKING || this == NEEDS_YOU
    val isOutcome: Boolean get() = this == DONE || this == FAILED

    /** needs you > failed > working > done > idle (same as Dart). */
    val priority: Int
        get() = when (this) {
            NEEDS_YOU -> 0
            FAILED -> 1
            WORKING, THINKING -> 2
            DONE -> 3
            IDLE -> 4
        }

    companion object {
        fun parse(raw: String?): WidgetBotState =
            when (raw) {
                "working" -> WORKING
                "thinking" -> THINKING
                "needsYou", "needs_you" -> NEEDS_YOU
                "done" -> DONE
                "failed" -> FAILED
                else -> IDLE
            }
    }
}

internal data class WidgetBot(
    val profile: String,
    val name: String,
    val state: WidgetBotState,
    val line: String?,
    val facePath: String?,
    val openPayload: String,
    val idleFacePath: String? = null,
    val steps: List<String> = emptyList(),
    val sinceMs: Long = 0,
    val role: String? = null,
    val color: Int? = null,
    val roomId: String? = null,
    val roomName: String? = null,
) {
    fun demoted(): WidgetBot =
        copy(state = WidgetBotState.IDLE, line = null, steps = emptyList(), facePath = idleFacePath ?: facePath, roomId = null, roomName = null)
}

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
    val steps: List<String> = emptyList(),
    val phase: String = "idle",
    val sinceMs: Long = 0,
) {
    val state: WidgetBotState get() = WidgetBotState.parse(phase)
}

internal data class WidgetActiveRef(val kind: String, val id: String)

/** One resolved active item: a Bot or a room. */
internal sealed class WidgetActiveItem {
    abstract val state: WidgetBotState
    abstract val openPayload: String

    data class Bot(val bot: WidgetBot) : WidgetActiveItem() {
        override val state get() = bot.state
        override val openPayload get() = bot.openPayload
    }

    data class Room(val room: WidgetRoom) : WidgetActiveItem() {
        override val state get() = room.state
        override val openPayload get() = room.openPayload
    }
}

internal data class BotModeWidgetState(
    val connectionId: String? = null,
    val connectionLabel: String? = null,
    val connected: Boolean = false,
    val workingCount: Int = 0,
    val needsYouCount: Int = 0,
    val bots: List<WidgetBot> = emptyList(),
    val approvals: List<WidgetApproval> = emptyList(),
    val rooms: List<WidgetRoom> = emptyList(),
    val quick: WidgetBot? = null,
    val active: List<WidgetActiveRef> = emptyList(),
    val hero: WidgetActiveRef? = null,
    val updatedAtMs: Long = 0,
) {
    val present: Boolean get() = connectionId != null
    val room: WidgetRoom? get() = rooms.firstOrNull()

    fun isStale(nowMs: Long): Boolean =
        updatedAtMs <= 0 || nowMs - updatedAtMs > BOT_MODE_STALE_AFTER_MS

    private fun resolve(ref: WidgetActiveRef): WidgetActiveItem? =
        when (ref.kind) {
            "bot" -> bots.firstOrNull { it.profile == ref.id }?.let { WidgetActiveItem.Bot(it) }
            "room" -> rooms.firstOrNull { it.id == ref.id }?.let { WidgetActiveItem.Room(it) }
            else -> null
        }?.takeIf { it.state != WidgetBotState.IDLE }

    /** Active items in priority order (Dart order, idle ones dropped). */
    fun activeItems(): List<WidgetActiveItem> = active.mapNotNull(::resolve)

    /** The 2x2 hero, or null for the overview grid. */
    fun heroItem(): WidgetActiveItem? = hero?.let(::resolve) ?: activeItems().firstOrNull()

    /** Earliest time the widget must redraw on its own (outcome / staleness expiry). */
    fun nextExpiryMs(nowMs: Long = 0): Long? {
        val times = buildList {
            if (updatedAtMs > 0) add(updatedAtMs + BOT_MODE_STALE_AFTER_MS + 1)
            for (b in bots) if (b.state.isOutcome && b.sinceMs > 0) add(b.sinceMs + BOT_MODE_OUTCOME_MS + 1)
            for (r in rooms) if (r.state.isOutcome && r.sinceMs > 0) add(r.sinceMs + BOT_MODE_OUTCOME_MS + 1)
        }
        return times.filter { it > nowMs }.minOrNull()
    }

    /** A done/failed outcome whose window already ended (redraw needed). */
    fun hasExpiredOutcome(nowMs: Long): Boolean =
        bots.any { it.state.isOutcome && nowMs - it.sinceMs > BOT_MODE_OUTCOME_MS } ||
            rooms.any { it.state.isOutcome && nowMs - it.sinceMs > BOT_MODE_OUTCOME_MS }

    /**
     * Never show "working" beyond the proved window: a stale snapshot demotes
     * every Bot to idle and drops the working count and room Stop. Done /
     * failed outcomes expire after [BOT_MODE_OUTCOME_MS] even when fresh.
     */
    fun trusted(nowMs: Long): BotModeWidgetState {
        fun outcomeExpired(state: WidgetBotState, since: Long) =
            state.isOutcome && (since <= 0 || nowMs - since > BOT_MODE_OUTCOME_MS || since > nowMs + 60_000)
        val stale = isStale(nowMs)
        val nextBots = bots.map {
            when {
                outcomeExpired(it.state, it.sinceMs) -> it.demoted()
                stale && it.state != WidgetBotState.NEEDS_YOU -> it.demoted()
                else -> it
            }
        }
        val nextRooms = rooms.map { r ->
            when {
                outcomeExpired(r.state, r.sinceMs) -> r.copy(phase = "idle", steps = emptyList())
                stale -> r.copy(
                    working = false,
                    stopPayload = null,
                    steps = emptyList(),
                    phase = if (r.state == WidgetBotState.NEEDS_YOU) r.phase else "idle",
                    members = r.members.map { it.copy(state = if (it.state == "needs_you") it.state else "idle") },
                )
                else -> r
            }
        }
        return copy(
            connected = connected && !stale,
            workingCount = if (stale) 0 else workingCount,
            bots = nextBots,
            rooms = nextRooms,
            quick = quick?.let { q -> if (stale) q.demoted() else q },
        )
    }

    /**
     * Lock screen / communal hub rendering: informational only. No command,
     * message, step or room text, and no action payloads (Approve / Deny /
     * Stop need an unlocked home screen; the receiver also refuses widget
     * taps while the keyguard shows).
     */
    fun redactedForKeyguard(): BotModeWidgetState =
        copy(
            bots = bots.map { it.copy(line = null, steps = emptyList(), roomName = null) },
            approvals = approvals.map { it.copy(text = "", canApprove = false) },
            rooms = rooms.map { it.copy(lastSpeaker = null, lastMessage = null, stopPayload = null, steps = emptyList()) },
            quick = quick?.copy(line = null, steps = emptyList()),
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
                val rooms = json.optJSONArray("rooms").objects().take(4).mapNotNull(::room)
                BotModeWidgetState(
                    connectionId = json.text("conn_id", 256),
                    connectionLabel = json.text("conn_label", 64),
                    connected = json.optBoolean("connected"),
                    workingCount = json.optInt("working_count").coerceAtLeast(0),
                    needsYouCount = json.optInt("needs_you_count").coerceAtLeast(0),
                    bots = json.optJSONArray("bots").objects().take(16).mapNotNull(::bot),
                    approvals = json.optJSONArray("approvals").objects().take(6).mapNotNull(::approval),
                    // Older snapshots carry only the single "room".
                    rooms = rooms.ifEmpty { listOfNotNull(json.optJSONObject("room")?.let(::room)) },
                    quick = json.optJSONObject("quick")?.let(::bot),
                    active = json.optJSONArray("active").objects().take(12).mapNotNull(::ref),
                    hero = json.optJSONObject("hero")?.let(::ref),
                    updatedAtMs = json.optLong("updated_at_ms"),
                )
            } catch (_: Exception) {
                BotModeWidgetState()
            }
        }

        private fun ref(json: JSONObject): WidgetActiveRef? {
            val kind = json.text("k", 8) ?: return null
            if (kind != "bot" && kind != "room") return null
            return WidgetActiveRef(kind, json.text("id", 256) ?: return null)
        }

        private fun steps(json: JSONObject): List<String> =
            json.optJSONArray("steps").strings().take(3).map { it.take(80) }

        private fun bot(json: JSONObject): WidgetBot? {
            val profile = json.text("profile", 64) ?: return null
            return WidgetBot(
                profile = profile,
                name = json.text("name", 48) ?: profile,
                state = WidgetBotState.parse(json.optString("state")),
                line = json.text("line", 80),
                facePath = json.text("face", 512),
                openPayload = json.text("open", 4000) ?: return null,
                idleFacePath = json.text("face_idle", 512),
                steps = steps(json),
                sinceMs = json.optLong("since_ms"),
                role = json.text("role", 48),
                color = if (json.has("color")) json.optLong("color").toInt() else null,
                roomId = json.text("room_id", 256),
                roomName = json.text("room_name", 64),
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
                steps = steps(json),
                phase = json.text("phase", 16) ?: if (json.optBoolean("working")) "working" else "idle",
                sinceMs = json.optLong("since_ms"),
            )
    }
}

private fun JSONObject.text(name: String, max: Int): String? =
    if (isNull(name)) null else optString(name, "").trim().takeIf { it.isNotEmpty() }?.take(max)

private fun JSONArray?.objects(): List<JSONObject> {
    this ?: return emptyList()
    return (0 until length()).mapNotNull { optJSONObject(it) }
}

private fun JSONArray?.strings(): List<String> {
    this ?: return emptyList()
    return (0 until length()).mapNotNull { optString(it, "").trim().takeIf { s -> s.isNotEmpty() } }
}
