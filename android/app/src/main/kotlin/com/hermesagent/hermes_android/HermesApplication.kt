package com.hermesagent.hermes_android

import android.app.Application
import android.content.res.Configuration
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the rich-notification channel on the foreground-service engine
 * too, so the Voice / Read Aloud card can be restyled from that isolate.
 */
class HermesApplication : Application() {
    /**
     * A new font scale, density or language while the process lives: the
     * pictures the app drew no longer match, so the widgets are redrawn
     * (natively until the app draws them again). No receiver is registered
     * for it; the system calls this on the running process only.
     */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        LauncherWidgets.requestUpdate(this, launcherWidgetReceivers())
    }

    override fun onCreate() {
        super.onCreate()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(
            object : FlutterForegroundTaskLifecycleListener {
                private var channel: MethodChannel? = null

                override fun onEngineCreate(flutterEngine: FlutterEngine?) {
                    val engine = flutterEngine ?: return
                    DurableSecretWriter.attach(this@HermesApplication, engine.dartExecutor.binaryMessenger)
                    channel?.let { HermesRichNotifications.detach(it) }
                    channel =
                        MethodChannel(
                            engine.dartExecutor.binaryMessenger,
                            HermesRichNotifications.CHANNEL_NAME,
                        ).also { HermesRichNotifications.attach(this@HermesApplication, it) }
                }

                override fun onTaskStart(starter: FlutterForegroundTaskStarter) = Unit

                override fun onTaskRepeatEvent() = Unit

                override fun onTaskDestroy() = Unit

                override fun onEngineWillDestroy() {
                    channel?.let { HermesRichNotifications.detach(it) }
                    channel = null
                }
            },
        )
    }
}
