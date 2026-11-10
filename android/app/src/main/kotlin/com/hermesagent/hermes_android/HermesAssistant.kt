package com.hermesagent.hermes_android

import android.content.Context
import android.os.Bundle
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import android.content.Intent
import android.speech.RecognitionService
import android.speech.SpeechRecognizer

/*
 * Android digital assistant entry (issue #217), deliberately minimal.
 *
 * Choosing Console under Settings > Default apps > Digital assistant app makes
 * the assistant gesture or button open Console on a NEW chat with the voice
 * ready, through the same allowlisted launch contract as the widget and the
 * quick tiles (NewSessionLaunchContract, source "assistant"). Flutter then
 * resolves the instance, shows onboarding when nothing is set up and honours
 * App Lock and the lock screen exactly as for any other launch.
 *
 * What it never does: read the screen, take a screenshot, read the content of
 * another app, send anything or keep anything running. The service asks the
 * system not to collect screen context for it, and the session ignores
 * whatever the system might still hand over.
 */

class HermesVoiceInteractionService : VoiceInteractionService() {
    override fun onReady() {
        super.onReady()
        try {
            // No assist data (view hierarchy, content, screenshot) is wanted.
            setDisabledShowContext(
                VoiceInteractionSession.SHOW_WITH_ASSIST or VoiceInteractionSession.SHOW_WITH_SCREENSHOT,
            )
        } catch (_: Exception) {
            // Best effort: the session below ignores the data anyway.
        }
    }
}

class HermesVoiceInteractionSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession =
        HermesVoiceInteractionSession(this)
}

class HermesVoiceInteractionSession(context: Context) : VoiceInteractionSession(context) {
    override fun onCreate() {
        super.onCreate()
        // Console has its own screen; the session needs no window.
        try {
            setUiEnabled(false)
        } catch (_: Exception) {
            // Keep the default.
        }
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        try {
            // Same task and activity as every other entry point: no second
            // Flutter engine in a separate assistant task.
            context.startActivity(
                NewSessionLaunchContract.newIntent(
                    context,
                    NewSessionLaunchContract.SOURCE_ASSISTANT,
                    NewSessionLaunchTarget.VOICE,
                ),
            )
        } catch (_: Exception) {
            // Nothing to show: the next invocation tries again.
        } finally {
            hide()
        }
    }
}

/*
 * The system only lists a voice-interaction service whose metadata also names a
 * recognition service (Settings > Digital assistant app skips it otherwise).
 * This one is a placeholder and never recognises anything: it has no intent
 * filter, so Console does not appear as a speech recogniser anywhere, and if it
 * were ever bound it answers every request with an error.
 */
class HermesAssistantRecognitionService : RecognitionService() {
    override fun onStartListening(recognizerIntent: Intent?, listener: Callback?) {
        try {
            listener?.error(SpeechRecognizer.ERROR_CLIENT)
        } catch (_: Exception) {
            // Nothing to report to.
        }
    }

    override fun onCancel(listener: Callback?) = Unit

    override fun onStopListening(listener: Callback?) = Unit
}
