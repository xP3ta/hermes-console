package com.hermesagent.hermes_android

import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import java.util.UUID

enum class NewSessionLaunchTarget(val wireValue: String) {
    COMPOSER("composer"),
    CAMERA("camera"),
    GALLERY("gallery"),
    VOICE("voice"),
}

enum class HermesWidgetLaunchKind(val wireValue: String) {
    NEW_SESSION("new_session"),
    OPEN_APP("open_app"),
    OPEN_SESSION("open_session"),
    OPEN_SETUP("open_setup"),
}

internal fun parseNewSessionLaunchTarget(raw: String?): NewSessionLaunchTarget? =
    NewSessionLaunchTarget.entries.firstOrNull { it.wireValue == raw }

/**
 * Secret-free, allowlisted contract shared by the launcher shortcut and the
 * interactive widget. It intentionally has no URL, prompt, model or credential
 * fields.
 */
object NewSessionLaunchContract {
    const val ACTION_NEW_SESSION = "dev.xpetalab.hermesconsole.action.NEW_SESSION"
    const val ACTION_NEW_SESSION_CAMERA = "dev.xpetalab.hermesconsole.action.NEW_SESSION_CAMERA"
    const val ACTION_NEW_SESSION_GALLERY = "dev.xpetalab.hermesconsole.action.NEW_SESSION_GALLERY"
    const val ACTION_NEW_SESSION_VOICE = "dev.xpetalab.hermesconsole.action.NEW_SESSION_VOICE"
    const val ACTION_OPEN_APP = "dev.xpetalab.hermesconsole.action.OPEN_APP"
    const val ACTION_OPEN_SESSION = "dev.xpetalab.hermesconsole.action.OPEN_SESSION"
    const val ACTION_OPEN_SETUP = "dev.xpetalab.hermesconsole.action.OPEN_SETUP"
    const val CHANNEL_NAME = "hermes/new_session_launch"
    const val CONTRACT_VERSION = 1

    const val EXTRA_CONTRACT_VERSION = "contract_version"
    const val EXTRA_SOURCE = "source"
    const val EXTRA_NATIVE_EVENT_ID = "native_event_id"
    const val EXTRA_REQUESTED_INSTANCE_ID = "requested_instance_id"
    const val EXTRA_TARGET = "target"
    const val EXTRA_KIND = "kind"
    const val EXTRA_SESSION_ID = "session_id"

    const val SOURCE_SHORTCUT = "shortcut"
    const val SOURCE_WIDGET = "widget"

    /**
     * The Android assistant gesture or button (a `VoiceInteractionSession`).
     * It can only open a blank chat with the voice ready: no prompt, no
     * screen content, nothing is sent.
     */
    const val SOURCE_ASSISTANT = "assistant"

    private val opaqueId = Regex("^[A-Za-z0-9._:-]+$")

    fun parse(source: Intent?): Map<String, Any?>? {
        source ?: return null
        val expectedRoute = routeForAction(source.action) ?: return null

        val version =
            when (val raw = source.extras?.get(EXTRA_CONTRACT_VERSION)) {
                is Int -> raw
                is String -> raw.toIntOrNull()
                else -> null
            } ?: CONTRACT_VERSION
        if (version != CONTRACT_VERSION) return null

        val launchSource = source.getStringExtra(EXTRA_SOURCE) ?: SOURCE_SHORTCUT
        if (
            launchSource != SOURCE_SHORTCUT &&
            launchSource != SOURCE_WIDGET &&
            launchSource != SOURCE_ASSISTANT
        ) {
            return null
        }
        if (launchSource == SOURCE_ASSISTANT && source.action != ACTION_NEW_SESSION_VOICE) {
            return null
        }
        if (launchSource == SOURCE_SHORTCUT && source.action != ACTION_NEW_SESSION) {
            return null
        }

        val suppliedEventId = source.getStringExtra(EXTRA_NATIVE_EVENT_ID)
        val eventId =
            if (suppliedEventId == null && launchSource == SOURCE_SHORTCUT) {
                UUID.randomUUID().toString()
            } else if (isSafeOpaqueId(suppliedEventId, 128)) {
                suppliedEventId!!
            } else {
                return null
            }

        val requested = source.getStringExtra(EXTRA_REQUESTED_INSTANCE_ID)
        if (requested != null && !isSafeOpaqueId(requested, 256)) return null
        val kindRaw = source.getStringExtra(EXTRA_KIND)
        val kind =
            if (kindRaw == null && launchSource == SOURCE_SHORTCUT) {
                HermesWidgetLaunchKind.NEW_SESSION
            } else {
                HermesWidgetLaunchKind.entries.firstOrNull { it.wireValue == kindRaw }
                    ?: return null
            }
        if (kind != expectedRoute.first) return null
        val sessionId = source.getStringExtra(EXTRA_SESSION_ID)
        if (sessionId != null && !isSafeOpaqueId(sessionId, 256)) return null
        if (kind == HermesWidgetLaunchKind.OPEN_SESSION && sessionId == null) return null
        if (kind != HermesWidgetLaunchKind.OPEN_SESSION && sessionId != null) return null
        val rawTarget = source.getStringExtra(EXTRA_TARGET)
        val target =
            if (rawTarget == null) {
                NewSessionLaunchTarget.COMPOSER
            } else {
                parseNewSessionLaunchTarget(rawTarget) ?: return null
            }
        if (kind == HermesWidgetLaunchKind.NEW_SESSION && target != expectedRoute.second) {
            return null
        }
        if (kind != HermesWidgetLaunchKind.NEW_SESSION && rawTarget != null) return null
        if (launchSource == SOURCE_SHORTCUT) {
            if (source.data != null || target != NewSessionLaunchTarget.COMPOSER) {
                return null
            }
        } else if (
            !matchesLaunchUri(
                source.data,
                kind,
                if (kind == HermesWidgetLaunchKind.NEW_SESSION) target else null,
                sessionId,
                eventId,
            )
        ) {
            return null
        }

        return mapOf(
            "contract_version" to CONTRACT_VERSION,
            "kind" to kind.wireValue,
            "source" to launchSource,
            "native_event_id" to eventId,
            "requested_instance_id" to requested,
            "session_id" to sessionId,
            "target" to target.wireValue,
            "received_elapsed_ms" to SystemClock.elapsedRealtime(),
        )
    }

    fun newIntent(
        context: android.content.Context,
        source: String,
        target: NewSessionLaunchTarget = NewSessionLaunchTarget.COMPOSER,
        requestedInstanceId: String? = null,
    ): Intent {
        require(
            source == SOURCE_SHORTCUT || source == SOURCE_WIDGET || source == SOURCE_ASSISTANT,
        )
        require(source != SOURCE_ASSISTANT || target == NewSessionLaunchTarget.VOICE)
        require(requestedInstanceId == null || isSafeOpaqueId(requestedInstanceId, 256))
        val eventId = UUID.randomUUID().toString()
        val kind = HermesWidgetLaunchKind.NEW_SESSION
        return Intent(context, MainActivity::class.java).apply {
            action = actionFor(kind, target)
            data = launchUri(kind, target, eventId)
            putExtra(EXTRA_CONTRACT_VERSION, CONTRACT_VERSION)
            putExtra(EXTRA_SOURCE, source)
            putExtra(EXTRA_NATIVE_EVENT_ID, eventId)
            putExtra(EXTRA_KIND, kind.wireValue)
            putExtra(EXTRA_TARGET, target.wireValue)
            requestedInstanceId?.let { putExtra(EXTRA_REQUESTED_INSTANCE_ID, it) }
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
    }

    fun openAppIntent(context: android.content.Context): Intent =
        routeIntent(context, HermesWidgetLaunchKind.OPEN_APP)

    fun openSetupIntent(context: android.content.Context): Intent =
        routeIntent(context, HermesWidgetLaunchKind.OPEN_SETUP)

    fun openSessionIntent(
        context: android.content.Context,
        requestedInstanceId: String?,
        sessionId: String,
    ): Intent {
        require(isSafeOpaqueId(sessionId, 256))
        return routeIntent(
            context,
            HermesWidgetLaunchKind.OPEN_SESSION,
            requestedInstanceId = requestedInstanceId,
            sessionId = sessionId,
        )
    }

    private fun routeIntent(
        context: android.content.Context,
        kind: HermesWidgetLaunchKind,
        requestedInstanceId: String? = null,
        sessionId: String? = null,
    ): Intent {
        require(kind != HermesWidgetLaunchKind.NEW_SESSION)
        require(requestedInstanceId == null || isSafeOpaqueId(requestedInstanceId, 256))
        val eventId = UUID.randomUUID().toString()
        return Intent(context, MainActivity::class.java).apply {
            action = actionFor(kind, NewSessionLaunchTarget.COMPOSER)
            data = launchUri(
                kind,
                null,
                eventId,
                sessionId = sessionId,
            )
            putExtra(EXTRA_CONTRACT_VERSION, CONTRACT_VERSION)
            putExtra(EXTRA_SOURCE, SOURCE_WIDGET)
            putExtra(EXTRA_NATIVE_EVENT_ID, eventId)
            putExtra(EXTRA_KIND, kind.wireValue)
            requestedInstanceId?.let { putExtra(EXTRA_REQUESTED_INSTANCE_ID, it) }
            sessionId?.let { putExtra(EXTRA_SESSION_ID, it) }
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
    }

    fun neutralize(intent: Intent?) {
        intent ?: return
        if (routeForAction(intent.action) == null) return
        intent.action = Intent.ACTION_MAIN
        intent.data = null
        intent.removeExtra(EXTRA_CONTRACT_VERSION)
        intent.removeExtra(EXTRA_SOURCE)
        intent.removeExtra(EXTRA_NATIVE_EVENT_ID)
        intent.removeExtra(EXTRA_REQUESTED_INSTANCE_ID)
        intent.removeExtra(EXTRA_TARGET)
        intent.removeExtra(EXTRA_KIND)
        intent.removeExtra(EXTRA_SESSION_ID)
    }

    private fun actionFor(
        kind: HermesWidgetLaunchKind,
        target: NewSessionLaunchTarget,
    ): String =
        when (kind) {
            HermesWidgetLaunchKind.NEW_SESSION ->
                when (target) {
                    NewSessionLaunchTarget.COMPOSER -> ACTION_NEW_SESSION
                    NewSessionLaunchTarget.CAMERA -> ACTION_NEW_SESSION_CAMERA
                    NewSessionLaunchTarget.GALLERY -> ACTION_NEW_SESSION_GALLERY
                    NewSessionLaunchTarget.VOICE -> ACTION_NEW_SESSION_VOICE
                }
            HermesWidgetLaunchKind.OPEN_APP -> ACTION_OPEN_APP
            HermesWidgetLaunchKind.OPEN_SESSION -> ACTION_OPEN_SESSION
            HermesWidgetLaunchKind.OPEN_SETUP -> ACTION_OPEN_SETUP
        }

    private fun routeForAction(action: String?): Pair<HermesWidgetLaunchKind, NewSessionLaunchTarget?>? =
        when (action) {
            ACTION_NEW_SESSION -> HermesWidgetLaunchKind.NEW_SESSION to NewSessionLaunchTarget.COMPOSER
            ACTION_NEW_SESSION_CAMERA -> HermesWidgetLaunchKind.NEW_SESSION to NewSessionLaunchTarget.CAMERA
            ACTION_NEW_SESSION_GALLERY -> HermesWidgetLaunchKind.NEW_SESSION to NewSessionLaunchTarget.GALLERY
            ACTION_NEW_SESSION_VOICE -> HermesWidgetLaunchKind.NEW_SESSION to NewSessionLaunchTarget.VOICE
            ACTION_OPEN_APP -> HermesWidgetLaunchKind.OPEN_APP to null
            ACTION_OPEN_SESSION -> HermesWidgetLaunchKind.OPEN_SESSION to null
            ACTION_OPEN_SETUP -> HermesWidgetLaunchKind.OPEN_SETUP to null
            else -> null
        }

    private fun launchUri(
        kind: HermesWidgetLaunchKind,
        target: NewSessionLaunchTarget?,
        eventId: String,
        sessionId: String? = null,
    ): Uri =
        Uri.Builder()
            .scheme("hermes-console-widget")
            .authority("launch")
            .appendPath(kind.wireValue)
            .apply {
                if (target != null) {
                    appendPath(target.wireValue)
                }
                if (sessionId != null) {
                    appendPath(sessionId)
                }
            }
            .appendPath(eventId)
            .build()

    private fun matchesLaunchUri(
        uri: Uri?,
        kind: HermesWidgetLaunchKind,
        target: NewSessionLaunchTarget?,
        sessionId: String?,
        eventId: String,
    ): Boolean {
        if (uri?.scheme != "hermes-console-widget" || uri.host != "launch") return false
        if (uri.encodedQuery != null || uri.fragment != null) return false
        val expected = mutableListOf(kind.wireValue)
        if (target != null) expected += target.wireValue
        if (sessionId != null) expected += sessionId
        expected += eventId
        return uri.pathSegments == expected
    }

    private fun isSafeOpaqueId(value: String?, maxLength: Int): Boolean =
        value != null &&
            value.isNotEmpty() &&
            value.length <= maxLength &&
            opaqueId.matches(value)
}
