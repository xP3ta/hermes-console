package com.hermesagent.hermes_android

import android.app.Application
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the rich-notification channel on the foreground-service engine
 * too, so the background listener can post conversation cards / Live Updates
 * and execute notification actions while the UI is closed (boot included).
 */
class HermesApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(
            object : FlutterForegroundTaskLifecycleListener {
                private var channel: MethodChannel? = null

                override fun onEngineCreate(flutterEngine: FlutterEngine?) {
                    val engine = flutterEngine ?: return
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
