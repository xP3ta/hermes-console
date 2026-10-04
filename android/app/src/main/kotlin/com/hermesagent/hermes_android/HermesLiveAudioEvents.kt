package com.hermesagent.hermes_android

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.cloudwebrtc.webrtc.audio.AudioSwitchManager
import io.flutter.plugin.common.EventChannel

// Tells Dart when a GPT-Live session lost audio focus or when a headset or
// Bluetooth output appeared or disappeared, so the session can be closed
// instead of continuing on an unexpected route. Dart listens only while a
// live session is open.
class HermesLiveAudioEvents(context: Context) : EventChannel.StreamHandler {
    private companion object {
        const val TAG = "HermesLiveAudio"
    }

    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var baseline: Set<Int> = emptySet()

    private val deviceCallback =
        object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) =
                checkRoute()

            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) =
                checkRoute()
        }

    // flutter_webrtc creates AudioSwitchManager.instance when its plugin
    // attaches to the engine (FlutterWebRTCPlugin.startListening), which runs
    // inside super.configureFlutterEngine, and it hands audioFocusChangeListener
    // to its AudioSwitch only when that is first created (microphone open). The
    // listener is therefore installed after the instance exists and before it
    // is read; a missing instance is logged instead of failing silently.
    fun installFocusListener() {
        val manager = AudioSwitchManager.instance
        if (manager == null) {
            Log.w(TAG, "AudioSwitchManager not ready: audio focus loss will not close live voice")
            return
        }
        manager.audioFocusChangeListener =
            AudioManager.OnAudioFocusChangeListener { change ->
                if (change == AudioManager.AUDIOFOCUS_LOSS ||
                    change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
                ) {
                    emit("focusLost")
                }
            }
    }

    private fun outputIds(): Set<Int> =
        audioManager
            .getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .map { it.id }
            .toSet()

    private fun checkRoute() {
        if (outputIds() != baseline) emit("routeChanged")
    }

    private fun emit(event: String) {
        main.post { sink?.success(event) }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        baseline = outputIds()
        audioManager.registerAudioDeviceCallback(deviceCallback, main)
    }

    override fun onCancel(arguments: Any?) {
        audioManager.unregisterAudioDeviceCallback(deviceCallback)
        sink = null
    }
}
