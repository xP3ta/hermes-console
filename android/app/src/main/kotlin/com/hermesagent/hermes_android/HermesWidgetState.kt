package com.hermesagent.hermes_android

import android.content.SharedPreferences
import kotlin.math.roundToInt
import org.json.JSONArray
import org.json.JSONObject

private const val PREFIX = "hermes_widget_"

/**
 * Schemas this build reads. 1 is what 1.2.13 and 1.2.14 wrote (one session);
 * 2 adds `active`, every chat running or waiting for the owner. A snapshot
 * left on disk by an older version keeps drawing until the app publishes.
 */
private val READABLE_SCHEMAS = setOf(1L, 2L)
private const val MAX_ACTIVE = 6
private const val ATOMIC_SNAPSHOT = "atomic_snapshot_v1"
internal const val STALE_AFTER_MS = 15 * 60 * 1000L
private val OPAQUE_ID = Regex("^[A-Za-z0-9._:@+-]+$")

internal enum class HermesWidgetConnectionState {
    UNCONFIGURED,
    NO_INSTANCE,
    CONNECTING,
    CONNECTED,
    ERROR,
    DISCONNECTED,
}

internal enum class HermesWidgetAgentState {
    IDLE,
    THINKING,
    STREAMING,
    TOOL_EXECUTION,
    WAITING_APPROVAL,
    ERROR,
    DISCONNECTED,
}

internal enum class HermesWidgetTheme {
    LIGHT,
    DARK,
    OLED,
}

/** Something a chat waits for the owner to answer (schema 2). */
internal data class HermesWidgetNeed(
    val requestId: String,
    val question: Boolean,
    val text: String?,
    /** Payload of Permitir / Rechazar; null when it can only be answered in the app. */
    val actionPayload: String?,
)

/** One chat that is running or waiting for the owner right now (schema 2). */
internal data class HermesWidgetChatActivity(
    val sessionId: String,
    val title: String?,
    val profile: String?,
    val state: HermesWidgetAgentState,
    /** The running tool in plain words; null while it thinks or answers. */
    val phase: String?,
    val startedAtMs: Long,
    val need: HermesWidgetNeed?,
) {
    val needsYou: Boolean get() = state == HermesWidgetAgentState.WAITING_APPROVAL
}

internal data class HermesWidgetState(
    val schemaVersion: Int = 0,
    val configured: Boolean = false,
    val instanceId: String? = null,
    val instanceLabel: String? = null,
    val connectionState: HermesWidgetConnectionState =
        HermesWidgetConnectionState.UNCONFIGURED,
    val model: String? = null,
    val provider: String? = null,
    val sessionId: String? = null,
    val sessionTitle: String? = null,
    val agentState: HermesWidgetAgentState = HermesWidgetAgentState.DISCONNECTED,
    val toolName: String? = null,
    val contextUsed: Long? = null,
    val contextMax: Long? = null,
    val contextPercent: Int? = null,
    val inputTokens: Long? = null,
    val outputTokens: Long? = null,
    val cacheReadTokens: Long? = null,
    val cacheWriteTokens: Long? = null,
    val firstTokenLatencyMs: Long? = null,
    val lastActivityAtMs: Long? = null,
    val updatedAtMs: Long = 0,
    val theme: HermesWidgetTheme = HermesWidgetTheme.DARK,
    val showAdvancedMetrics: Boolean = true,
    /** Chats running or waiting for the owner (schema 2; empty in schema 1). */
    val active: List<HermesWidgetChatActivity> = emptyList(),
) {
    /** The snapshot lists every running chat itself, not only the last one that spoke. */
    val listsActivity: Boolean get() = schemaVersion >= 2

    fun isStale(nowMs: Long): Boolean =
        updatedAtMs <= 0 || nowMs - updatedAtMs > STALE_AFTER_MS

    /**
     * What may be drawn at [nowMs]. A snapshot older than the proved window
     * never looks alive: no live connection, no running agent, no tool.
     */
    fun trusted(nowMs: Long): HermesWidgetState {
        if (!isStale(nowMs)) return this
        val live =
            connectionState == HermesWidgetConnectionState.CONNECTED ||
                connectionState == HermesWidgetConnectionState.CONNECTING
        return copy(
            connectionState = if (live) HermesWidgetConnectionState.DISCONNECTED else connectionState,
            agentState = HermesWidgetAgentState.DISCONNECTED,
            toolName = null,
            active = emptyList(),
        )
    }

    fun staleAtMs(): Long? =
        updatedAtMs
            .takeIf { it > 0 && it <= Long.MAX_VALUE - STALE_AFTER_MS - 1 }
            ?.plus(STALE_AFTER_MS + 1)

    val cachePercent: Int?
        get() {
            val read = cacheReadTokens ?: return null
            val input = inputTokens ?: return null
            val prompt = input + read + (cacheWriteTokens ?: 0)
            if (read <= 0 || prompt <= 0) return null
            return ((read.toDouble() / prompt.toDouble()) * 100)
                .roundToInt()
                .coerceIn(0, 100)
        }

    companion object {
        fun from(preferences: SharedPreferences): HermesWidgetState {
            val atomic = preferences.atomicSnapshotValues()
            if (atomic != null) parse(atomic)?.let { return it }
            return parse(preferences.legacySnapshotValues()) ?: HermesWidgetState()
        }

        private fun parse(values: Map<String, Any?>): HermesWidgetState? {
            val schema = values.safeLong("schema_version")
            if (schema == null || schema !in READABLE_SCHEMAS) return null
            val used = values.safeNonNegativeLong("context_used")
            val max = values.safePositiveLong("context_max")
            val supplied = values.safeNonNegativeLong("context_percent")?.toInt()
            val percent =
                if (used == null || max == null) {
                    null
                } else {
                    (supplied ?: ((used.toDouble() / max) * 100).roundToInt())
                        .coerceIn(0, 100)
                }
            return HermesWidgetState(
                schemaVersion = schema.toInt(),
                configured = values["configured"] == true,
                instanceId = values.safeText("instance_id", 256, opaque = true),
                instanceLabel = values.safeText("instance_label", 64),
                connectionState =
                    enumValue(
                        values.safeText("connection_state", 32),
                        HermesWidgetConnectionState.UNCONFIGURED,
                    ),
                model = values.safeText("model", 96),
                provider = values.safeText("provider", 64),
                sessionId = values.safeText("session_id", 256, opaque = true),
                sessionTitle = values.safeText("session_title", 96),
                agentState =
                    enumValue(
                        values.safeText("agent_state", 32),
                        HermesWidgetAgentState.DISCONNECTED,
                    ),
                toolName = values.safeText("tool_name", 64),
                contextUsed = used,
                contextMax = max,
                contextPercent = percent,
                inputTokens = values.safeNonNegativeLong("input_tokens"),
                outputTokens = values.safeNonNegativeLong("output_tokens"),
                cacheReadTokens = values.safeNonNegativeLong("cache_read_tokens"),
                cacheWriteTokens = values.safeNonNegativeLong("cache_write_tokens"),
                firstTokenLatencyMs = values.safeNonNegativeLong("first_token_latency_ms"),
                lastActivityAtMs = values.safeNonNegativeLong("last_activity_at_ms"),
                updatedAtMs = values.safeNonNegativeLong("updated_at_ms") ?: 0,
                theme =
                    enumValue(
                        values.safeText("theme", 16),
                        HermesWidgetTheme.DARK,
                    ),
                showAdvancedMetrics = values["show_advanced_metrics"] as? Boolean ?: true,
                active = activity(values["active"] as? JSONArray),
            )
        }

        private fun activity(array: JSONArray?): List<HermesWidgetChatActivity> {
            array ?: return emptyList()
            return (0 until array.length())
                .mapNotNull { array.optJSONObject(it) }
                .take(MAX_ACTIVE)
                .mapNotNull(::chat)
        }

        private fun chat(json: JSONObject): HermesWidgetChatActivity? {
            val state = enumValue(json.jsonText("state", 32), HermesWidgetAgentState.IDLE)
            if (state !in ACTIVE_STATES) return null
            val need = json.optJSONObject("need")
            return HermesWidgetChatActivity(
                sessionId = json.jsonText("sid", 256)?.takeIf { OPAQUE_ID.matches(it) } ?: return null,
                title = json.jsonText("title", 96),
                profile = json.jsonText("profile", 64),
                state = state,
                phase = json.jsonText("phase", 48),
                startedAtMs = json.optLong("started_ms").coerceAtLeast(0),
                need =
                    need?.let {
                        HermesWidgetNeed(
                            requestId = it.jsonText("rid", 256) ?: return@let null,
                            question = it.optBoolean("question"),
                            text = it.jsonText("text", 160),
                            actionPayload = it.jsonText("action", 4000),
                        )
                    },
            )
        }

        private val ACTIVE_STATES =
            setOf(
                HermesWidgetAgentState.THINKING,
                HermesWidgetAgentState.STREAMING,
                HermesWidgetAgentState.TOOL_EXECUTION,
                HermesWidgetAgentState.WAITING_APPROVAL,
            )
    }
}

private fun JSONObject.jsonText(name: String, max: Int): String? =
    if (isNull(name)) null else optString(name, "").trim().takeIf { it.isNotEmpty() }?.take(max)

private fun key(name: String) = "$PREFIX$name"

private fun SharedPreferences.atomicSnapshotValues(): Map<String, Any?>? =
    try {
        val raw = getString(key(ATOMIC_SNAPSHOT), null) ?: return null
        val json = JSONObject(raw)
        buildMap {
            val names = json.keys()
            while (names.hasNext()) {
                val name = names.next()
                put(name, json.opt(name).takeUnless { it === JSONObject.NULL })
            }
        }
    } catch (_: Exception) {
        null
    }

private fun SharedPreferences.legacySnapshotValues(): Map<String, Any?> =
    try {
        buildMap {
            for ((storedKey, value) in all) {
                if (storedKey.startsWith(PREFIX)) {
                    put(storedKey.removePrefix(PREFIX), value)
                }
            }
        }
    } catch (_: RuntimeException) {
        emptyMap()
    }

private fun Map<String, Any?>.safeLong(name: String): Long? =
    when (val value = this[name]) {
        is Int -> value.toLong()
        is Long -> value
        is String -> value.toLongOrNull()
        else -> null
    }

private fun Map<String, Any?>.safeNonNegativeLong(name: String): Long? =
    safeLong(name)?.takeIf { it >= 0 }

private fun Map<String, Any?>.safePositiveLong(name: String): Long? =
    safeNonNegativeLong(name)?.takeIf { it > 0 }

private fun Map<String, Any?>.safeText(
    name: String,
    maxLength: Int,
    opaque: Boolean = false,
): String? =
    (this[name] as? String)
        ?.trim()
        ?.takeIf { it.isNotEmpty() && (!opaque || OPAQUE_ID.matches(it)) }
        ?.take(maxLength)

private inline fun <reified T : Enum<T>> enumValue(raw: String?, fallback: T): T {
    if (raw == null) return fallback
    val wire = raw.replace(Regex("([a-z])([A-Z])"), "$1_$2").uppercase()
    return enumValues<T>().firstOrNull { it.name == wire } ?: fallback
}
