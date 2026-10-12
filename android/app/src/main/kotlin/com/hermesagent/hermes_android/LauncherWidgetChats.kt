package com.hermesagent.hermes_android

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/** Chats section of the launcher widgets (schema 1), published by Dart; read-only here. */
internal const val CHATS_SNAPSHOT_KEY = "hermes_widget_chats_v1"
internal const val CHATS_SCHEMA = 1

/** From this age on the widget says since when it has had no news of the list. */
internal const val CHATS_STALE_AFTER_MS = 15 * 60 * 1000L

private val CHAT_ID = Regex("^[A-Za-z0-9._:-]+$")

internal data class ChatWidgetChat(
    val id: String,
    val title: String,
    /** One line of the last answer; null when there is none or it is hidden. */
    val line: String?,
    val atMs: Long,
    val profile: String?,
)

/** A conversation with what it is doing right now, if anything. */
internal data class ChatWidgetRow(
    val chat: ChatWidgetChat,
    val activity: HermesWidgetChatActivity?,
) {
    val needsYou: Boolean get() = activity?.needsYou == true
    val running: Boolean get() = activity != null && !activity.needsYou
}

internal data class ChatsWidgetState(
    val connectionId: String? = null,
    val updatedAtMs: Long = 0,
    /** Most recent first. */
    val chats: List<ChatWidgetChat> = emptyList(),
) {
    /** The app has listed the conversations at least once. */
    val present: Boolean get() = connectionId != null

    fun isStale(nowMs: Long): Boolean = updatedAtMs <= 0 || nowMs - updatedAtMs > CHATS_STALE_AFTER_MS

    /** When a drawing made at [nowMs] stops being true by itself. */
    fun nextChangeAtMs(nowMs: Long): Long? =
        (updatedAtMs + CHATS_STALE_AFTER_MS + 1).takeIf { present && updatedAtMs > 0 && it > nowMs }

    /**
     * The list as the widget draws it: the conversations that wait for the
     * owner, then the ones that run, then the rest by last activity. [active]
     * is what runs or waits right now (empty when that is not known); one of
     * them that is not in the list yet (a chat just started) is added.
     */
    fun rows(active: List<HermesWidgetChatActivity>): List<ChatWidgetRow> {
        val live = active.associateBy { it.sessionId }
        val listed = chats.map { ChatWidgetRow(it, live[it.id]) }
        val known = chats.map { it.id }.toSet()
        val started =
            active
                .filter { it.sessionId !in known && !it.title.isNullOrEmpty() }
                .map { ChatWidgetRow(ChatWidgetChat(it.sessionId, it.title ?: "", null, it.startedAtMs, it.profile), it) }
        return (started + listed).sortedBy {
            when {
                it.needsYou -> 0
                it.running -> 1
                else -> 2
            }
        }
    }

    companion object {
        fun from(preferences: SharedPreferences): ChatsWidgetState =
            parse(
                try {
                    preferences.getString(CHATS_SNAPSHOT_KEY, null)
                } catch (_: ClassCastException) {
                    null
                },
            )

        fun parse(raw: String?): ChatsWidgetState {
            if (raw.isNullOrEmpty()) return ChatsWidgetState()
            return try {
                val json = JSONObject(raw)
                if (json.optInt("schema_version") != CHATS_SCHEMA) return ChatsWidgetState()
                ChatsWidgetState(
                    connectionId = json.chatText("conn_id", 256) ?: return ChatsWidgetState(),
                    updatedAtMs = json.optLong("updated_at_ms").coerceAtLeast(0),
                    chats = json.optJSONArray("chats").chatObjects().take(8).mapNotNull(::chat),
                )
            } catch (_: Exception) {
                ChatsWidgetState()
            }
        }

        private fun chat(json: JSONObject): ChatWidgetChat? =
            ChatWidgetChat(
                id = json.chatText("id", 256)?.takeIf { CHAT_ID.matches(it) } ?: return null,
                title = json.chatText("title", 120) ?: return null,
                line = json.chatText("line", 120),
                atMs = json.optLong("at_ms").coerceAtLeast(0),
                profile = json.chatText("profile", 64),
            )
    }
}

private fun JSONObject.chatText(name: String, max: Int): String? =
    if (isNull(name)) null else optString(name, "").trim().takeIf { it.isNotEmpty() }?.take(max)

private fun JSONArray?.chatObjects(): List<JSONObject> {
    this ?: return emptyList()
    return (0 until length()).mapNotNull { optJSONObject(it) }
}
