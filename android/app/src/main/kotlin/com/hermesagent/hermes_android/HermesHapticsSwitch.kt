package com.hermesagent.hermes_android

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Channel "hermes/haptics": the «Respuesta háptica» switch of Settings.
 *
 * The engine plays the framework's ticks (long press, text selection,
 * LongPressDraggable, `HapticFeedback.*`) through the activity's DECOR VIEW
 * (`PlatformPlugin` calls `window.decorView.performHapticFeedback`), not the
 * FlutterView. `View.setHapticFeedbackEnabled(false)` makes that call do
 * nothing, so the switch is applied to the decor view and, for anything that
 * vibrates through it, to the FlutterView as well. It never forces a tick on:
 * with the setting on, the system's own «Respuesta táctil» still decides, as
 * for any app.
 *
 * - `setEnabled(bool)`: applies the setting to the decor and Flutter views.
 */
object HermesHapticsSwitch {
    const val CHANNEL = "hermes/haptics"

    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    val enabled = call.arguments as? Boolean ?: true
                    val decor = activity.window.decorView
                    decor.isHapticFeedbackEnabled = enabled
                    result.success(apply(decor, enabled))
                }
                else -> result.notImplemented()
            }
        }
    }

    /** True when a Flutter view was found and set. */
    private fun apply(root: View, enabled: Boolean): Boolean {
        if (root is FlutterView) {
            root.isHapticFeedbackEnabled = enabled
            return true
        }
        var found = false
        if (root is ViewGroup) {
            for (i in 0 until root.childCount) {
                if (apply(root.getChildAt(i), enabled)) found = true
            }
        }
        return found
    }
}
