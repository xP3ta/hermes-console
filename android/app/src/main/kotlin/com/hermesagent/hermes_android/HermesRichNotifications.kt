package com.hermesagent.hermes_android

import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.LocusIdCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import java.util.concurrent.CopyOnWriteArrayList
import org.json.JSONArray
import org.json.JSONObject

/**
 * Rich, interactive notifications for Bot Mode (spec 070 Phase 6).
 *
 * Kotlin is deliberately a thin renderer: Dart decides what to show (copy,
 * actions, redaction) and performs every server call. Notification and widget
 * actions only land in a durable inbox and wake whichever Flutter engine is
 * alive (UI or the background listener), which answers through the same path
 * as the in-app control.
 */
internal object HermesRichNotifications {
    const val CHANNEL_NAME = "hermes/rich_notifications"
    const val CH_CONVERSATIONS = "hermes_conversations"
    const val CH_LIVE = "hermes_live_updates"
    const val CH_APPROVALS = "hermes_approvals"
    const val REMOTE_INPUT_KEY = "hermes_reply_text"
    private const val TAG = "HermesRichNotif"
    private const val SELECT_NOTIFICATION = "SELECT_NOTIFICATION"
    private const val PAYLOAD = "payload"
    private const val NOTIFICATION_ID = "notificationId"
    private const val GROUP_PREFIX = "hermes.conv."

    private val channels = CopyOnWriteArrayList<MethodChannel>()
    private val main = Handler(Looper.getMainLooper())

    fun attach(context: Context, channel: MethodChannel, onDrainFinished: (() -> Unit)? = null) {
        val app = context.applicationContext
        channel.setMethodCallHandler { call, result ->
            if (call.method == "drainFinished") {
                onDrainFinished?.invoke()
                result.success(true)
            } else {
                handle(app, call, result)
            }
        }
        channels.add(channel)
    }

    fun detach(channel: MethodChannel) {
        channels.remove(channel)
        channel.setMethodCallHandler(null)
    }

    /** True while some Flutter engine (UI, listener or headless drain) can execute taps. */
    fun hasExecutor(): Boolean = channels.isNotEmpty()

    /** Wakes every attached engine; the inbox guarantees one executor. */
    fun notifyActionsAvailable() {
        main.post {
            for (channel in channels) {
                try {
                    channel.invokeMethod("actionsAvailable", null)
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "capabilities" -> result.success(capabilities(context))
                "postConversation" -> {
                    postConversation(context, call.arguments.asMap())
                    result.success(true)
                }
                "postLiveUpdate" -> result.success(postLiveUpdate(context, call.arguments.asMap()))
                "confirm" -> {
                    confirm(context, call.arguments.asMap())
                    result.success(true)
                }
                "cancel" -> {
                    val args = call.arguments.asMap()
                    NotificationManagerCompat.from(context)
                        .cancel(args.str("tag"), args.int("id") ?: 0)
                    result.success(true)
                }
                "takePendingActions" -> {
                    val routes = (call.argument<List<Any?>>("routes") ?: emptyList())
                        .mapNotNull { it as? String }
                        .toSet()
                    result.success(HermesNotificationActionInbox.take(context, routes))
                }
                "ackPendingActions" -> {
                    val uids = (call.argument<List<Any?>>("uids") ?: emptyList())
                        .mapNotNull { it as? String }
                        .toSet()
                    HermesNotificationActionInbox.ack(context, uids)
                    result.success(true)
                }
                "drainFinished" -> result.success(true)
                "openPromotionSettings" -> result.success(openPromotionSettings(context))
                "removeConversationShortcut" -> {
                    val id = call.argument<String>("conversationId")
                    if (id != null) {
                        ShortcutManagerCompat.removeLongLivedShortcuts(context, listOf(id))
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            Log.w(TAG, "${call.method} failed: ${error.javaClass.simpleName}")
            result.error("rich_notification_failed", error.javaClass.simpleName, null)
        }
    }

    private fun capabilities(context: Context): Map<String, Any?> {
        val manager = NotificationManagerCompat.from(context)
        val promoted =
            if (Build.VERSION.SDK_INT >= 36) {
                try {
                    manager.canPostPromotedNotifications()
                } catch (_: Exception) {
                    false
                }
            } else {
                false
            }
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "liveUpdates" to (Build.VERSION.SDK_INT >= 36),
            "canPostPromoted" to promoted,
            "notificationsEnabled" to manager.areNotificationsEnabled(),
            "conversations" to (Build.VERSION.SDK_INT >= 30),
        )
    }

    private fun openPromotionSettings(context: Context): Boolean {
        val intents =
            buildList {
                if (Build.VERSION.SDK_INT >= 36) {
                    add(
                        Intent(Settings.ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName),
                    )
                }
                if (Build.VERSION.SDK_INT >= 26) {
                    add(
                        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName),
                    )
                }
                add(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        .setData(Uri.fromParts("package", context.packageName, null)),
                )
            }
        for (intent in intents) {
            try {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: Exception) {
            }
        }
        return false
    }

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val strings = context.resources
        if (manager.getNotificationChannel(CH_CONVERSATIONS) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CH_CONVERSATIONS,
                    strings.getString(R.string.rich_channel_conversations),
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = strings.getString(R.string.rich_channel_conversations_desc)
                    enableLights(true)
                    lightColor = ACCENT
                },
            )
        }
        if (manager.getNotificationChannel(CH_LIVE) == null) {
            // IMPORTANCE_MIN channels can never be promoted to a Live Update.
            manager.createNotificationChannel(
                NotificationChannel(
                    CH_LIVE,
                    strings.getString(R.string.rich_channel_live),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = strings.getString(R.string.rich_channel_live_desc)
                    setSound(null, null)
                    enableVibration(false)
                },
            )
        }
        if (manager.getNotificationChannel(CH_APPROVALS) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CH_APPROVALS,
                    strings.getString(R.string.rich_channel_approvals),
                    NotificationManager.IMPORTANCE_HIGH,
                ),
            )
        }
    }

    private fun channelFor(raw: String?): String =
        when (raw) {
            "approvals" -> CH_APPROVALS
            "live" -> CH_LIVE
            else -> CH_CONVERSATIONS
        }

    private fun openIntent(context: Context, id: Int, tag: String?, payload: String?): PendingIntent? {
        if (payload.isNullOrEmpty()) return null
        val launch =
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: return null
        launch.action = SELECT_NOTIFICATION
        launch.putExtra(NOTIFICATION_ID, id)
        launch.putExtra(PAYLOAD, payload)
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            requestCode(tag, id, "open"),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** Public so the Glance widgets reuse exactly the notification tap route. */
    fun openActivityIntent(context: Context, payload: String): Intent? {
        val launch =
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: return null
        launch.action = SELECT_NOTIFICATION
        launch.putExtra(NOTIFICATION_ID, 0)
        launch.putExtra(PAYLOAD, payload)
        // No data URI: Flutter deep linking would try to push it as a route.
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return launch
    }

    fun actionBroadcast(
        context: Context,
        actionId: String,
        payload: String,
        notificationId: Int,
        tag: String?,
        source: String,
    ): Intent =
        Intent(context, HermesNotificationActionReceiver::class.java).apply {
            action = HermesNotificationActionReceiver.ACTION
            // A unique data URI keeps PendingIntents for different buttons apart.
            data = Uri.parse(
                "hermes-console-action://$source/$actionId/" +
                    "${notificationId}/${(tag ?: "").hashCode()}/${payload.hashCode()}",
            )
            putExtra(HermesNotificationActionReceiver.EXTRA_ACTION_ID, actionId)
            putExtra(HermesNotificationActionReceiver.EXTRA_PAYLOAD, payload)
            putExtra(HermesNotificationActionReceiver.EXTRA_NOTIFICATION_ID, notificationId)
            putExtra(HermesNotificationActionReceiver.EXTRA_NOTIFICATION_TAG, tag)
            putExtra(HermesNotificationActionReceiver.EXTRA_SOURCE, source)
        }

    private fun actionPendingIntent(
        context: Context,
        actionId: String,
        payload: String,
        id: Int,
        tag: String?,
        mutable: Boolean,
    ): PendingIntent {
        val flags =
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (mutable && Build.VERSION.SDK_INT >= 31) {
                    PendingIntent.FLAG_MUTABLE
                } else if (mutable) {
                    0
                } else {
                    PendingIntent.FLAG_IMMUTABLE
                }
        return PendingIntent.getBroadcast(
            context,
            requestCode(tag, id, actionId),
            actionBroadcast(context, actionId, payload, id, tag, "notification"),
            flags,
        )
    }

    private fun requestCode(tag: String?, id: Int, action: String): Int =
        31 * (31 * (tag ?: "").hashCode() + id) + action.hashCode()

    private fun loadBitmap(path: String?): Bitmap? {
        if (path.isNullOrEmpty()) return null
        return try {
            val file = File(path)
            if (!file.isFile || file.length() > 2_000_000) null else BitmapFactory.decodeFile(path)
        } catch (_: Exception) {
            null
        }
    }

    private fun iconFor(path: String?): IconCompat? =
        loadBitmap(path)?.let { IconCompat.createWithAdaptiveBitmap(it) }

    private fun personIconFor(path: String?): IconCompat? =
        loadBitmap(path)?.let { IconCompat.createWithBitmap(it) }

    private fun pushShortcut(context: Context, args: Map<String, Any?>, person: Person?) {
        val id = args.str("conversationId") ?: return
        val name = args.str("conversationTitle") ?: return
        val open = args.str("openPayload") ?: return
        // Keeps SELECT_NOTIFICATION so the plugin routes the shortcut tap
        // exactly like a notification tap.
        val intent = openActivityIntent(context, open) ?: return
        val builder =
            ShortcutInfoCompat.Builder(context, id)
                .setShortLabel(name.take(24))
                .setLongLabel(name.take(64))
                .setLongLived(true)
                .setLocusId(LocusIdCompat(id))
                .setIntent(intent)
                .setCategories(setOf("com.hermesagent.hermes_android.category.CONVERSATION"))
        val icon = iconFor(args.str("shortcutIconPath"))
        builder.setIcon(icon ?: IconCompat.createWithResource(context, R.mipmap.ic_launcher))
        if (person != null && args["isGroup"] != true) builder.setPerson(person)
        try {
            ShortcutManagerCompat.pushDynamicShortcut(context, builder.build())
        } catch (error: Exception) {
            Log.w(TAG, "shortcut push failed: ${error.javaClass.simpleName}")
        }
    }

    private fun rememberTitle(
        context: Context,
        tag: String?,
        id: Int,
        title: String,
        channel: String,
        openPayload: String?,
    ) {
        HermesNotificationActionInbox.rememberPosted(context, tag, id, title, channel, openPayload)
    }

    fun postConversation(context: Context, args: Map<String, Any?>) {
        ensureChannels(context)
        val id = args.int("id") ?: return
        val tag = args.str("tag")
        val channel = channelFor(args.str("channel"))
        val title = args.str("title") ?: context.getString(R.string.rich_brand)
        val text = args.str("text") ?: ""
        val selfName = args.str("selfName") ?: context.getString(R.string.rich_you)
        val me = Person.Builder().setName(selfName).setKey("hermes-user").build()
        val style = NotificationCompat.MessagingStyle(me)
        val isGroup = args["isGroup"] == true
        style.setGroupConversation(isGroup)
        if (isGroup) style.setConversationTitle(args.str("conversationTitle"))
        val persons = HashMap<String, Person>()
        var firstPerson: Person? = null
        for (raw in args.list("messages")) {
            val message = raw.asMap()
            val body = message.str("text") ?: continue
            val key = message.str("senderKey")
            val sender =
                if (key == null || key == "hermes-user") {
                    null
                } else {
                    persons.getOrPut(key) {
                        Person.Builder()
                            .setKey(key)
                            .setName(message.str("senderName") ?: key)
                            .setBot(true)
                            .apply { personIconFor(message.str("iconPath"))?.let { setIcon(it) } }
                            .build()
                    }
                }
            if (firstPerson == null && sender != null) firstPerson = sender
            style.addMessage(
                NotificationCompat.MessagingStyle.Message(
                    body,
                    message.long("timeMs") ?: System.currentTimeMillis(),
                    sender,
                ),
            )
        }
        if (style.messages.isEmpty()) {
            style.addMessage(NotificationCompat.MessagingStyle.Message(text, System.currentTimeMillis(), firstPerson))
        }
        pushShortcut(context, args, firstPerson)
        val payload = args.str("actionPayload") ?: "{}"
        val alert = args["alert"] == true
        val builder =
            NotificationCompat.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_stat_hermes)
                .setColor(ACCENT)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(style)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setAutoCancel(true)
                .setOnlyAlertOnce(args["onlyAlertOnce"] == true || !alert)
                .setSilent(!alert)
                .setPriority(if (alert) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
                .setGroup(GROUP_PREFIX + (args.str("groupKey") ?: args.str("conversationId") ?: "hermes"))
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        args.str("conversationId")?.let {
            builder.setShortcutId(it)
            builder.setLocusId(LocusIdCompat(it))
        }
        args.str("subText")?.let { builder.setSubText(it) }
        args.long("timeoutMs")?.let { if (it > 0) builder.setTimeoutAfter(it) }
        openIntent(context, id, tag, args.str("openPayload"))?.let { builder.setContentIntent(it) }
        for (raw in args.list("actions").take(3)) {
            val action = raw.asMap()
            val actionId = action.str("id") ?: continue
            val label = action.str("label") ?: continue
            if (actionId == "open") {
                val open = openIntent(context, id, tag, args.str("openPayload")) ?: continue
                builder.addAction(
                    NotificationCompat.Action.Builder(R.drawable.ic_stat_hermes, label, open)
                        .setShowsUserInterface(true)
                        .build(),
                )
                continue
            }
            val remote = action["remoteInput"] == true
            val intent = actionPendingIntent(context, actionId, payload, id, tag, mutable = remote)
            val semantic =
                when (actionId) {
                    "approve" -> NotificationCompat.Action.SEMANTIC_ACTION_NONE
                    "deny" -> NotificationCompat.Action.SEMANTIC_ACTION_DELETE
                    "reply" -> NotificationCompat.Action.SEMANTIC_ACTION_REPLY
                    "stop" -> NotificationCompat.Action.SEMANTIC_ACTION_MUTE
                    else -> NotificationCompat.Action.SEMANTIC_ACTION_NONE
                }
            val actionBuilder =
                NotificationCompat.Action.Builder(R.drawable.ic_stat_hermes, label, intent)
                    .setSemanticAction(semantic)
                    .setShowsUserInterface(false)
                    .setAllowGeneratedReplies(remote && action["smartReplies"] == true)
            if (Build.VERSION.SDK_INT >= 31 && action["requiresUnlock"] != false) {
                actionBuilder.setAuthenticationRequired(true)
            }
            if (remote) {
                actionBuilder.addRemoteInput(
                    RemoteInput.Builder(REMOTE_INPUT_KEY)
                        .setLabel(action.str("hint") ?: label)
                        .build(),
                )
            }
            builder.addAction(actionBuilder.build())
        }
        val publicTitle = args.str("publicTitle")
        if (publicTitle != null) {
            builder.setPublicVersion(
                NotificationCompat.Builder(context, channel)
                    .setSmallIcon(R.drawable.ic_stat_hermes)
                    .setColor(ACCENT)
                    .setContentTitle(publicTitle)
                    .setContentText(args.str("publicText") ?: "")
                    .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                    .build(),
            )
        }
        rememberTitle(context, tag, id, title, channel, args.str("openPayload"))
        notify(context, tag, id, builder)
    }

    /**
     * Android 16 Live Update: ProgressStyle, ongoing, requested promotion, no
     * custom views, not colorized, not a group summary. Older releases get an
     * ongoing notification with a determinate/indeterminate progress bar.
     */
    fun postLiveUpdate(context: Context, args: Map<String, Any?>): Map<String, Any?> {
        ensureChannels(context)
        val id = args.int("id") ?: return mapOf("posted" to false)
        val tag = args.str("tag")
        val title = args.str("title") ?: context.getString(R.string.rich_brand)
        // Never empty: the system rejects promotion for a blank Live Update.
        val text = args.str("text")?.takeIf { it.isNotBlank() }
            ?: context.getString(R.string.rich_thinking)
        val payload = args.str("actionPayload") ?: "{}"
        val segments = args.list("segments").map { it.asMap() }
        val done = segments.count { it.str("state") == "done" }
        val startedAt = args.long("startedAtMs")
        val builder =
            NotificationCompat.Builder(context, CH_LIVE)
                .setSmallIcon(R.drawable.ic_stat_hermes)
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                // Lock screen shows the redacted public version below.
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setColorized(false)
        // Every listener tick re-posts (renews) it; a listener that stops
        // ticking lets it expire instead of claiming work forever.
        builder.setTimeoutAfter(args.long("timeoutMs")?.takeIf { it > 0 } ?: LIVE_TIMEOUT_MS)
        args.str("publicTitle")?.let { publicTitle ->
            builder.setPublicVersion(
                NotificationCompat.Builder(context, CH_LIVE)
                    .setSmallIcon(R.drawable.ic_stat_hermes)
                    .setContentTitle(publicTitle)
                    .setContentText(args.str("publicText") ?: "")
                    .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                    .setOngoing(true)
                    .build(),
            )
        }
        args.str("subText")?.let { builder.setSubText(it) }
        if (startedAt != null && startedAt > 0) {
            builder.setWhen(startedAt).setShowWhen(true).setUsesChronometer(true)
        }
        args.str("conversationId")?.let {
            builder.setShortcutId(it)
            builder.setLocusId(LocusIdCompat(it))
        }
        openIntent(context, id, tag, args.str("openPayload"))?.let { builder.setContentIntent(it) }
        val stopPayload = args.str("actionPayload")
        args.str("stopLabel")?.takeIf { stopPayload != null }?.let { label ->
            val stop =
                NotificationCompat.Action.Builder(
                    R.drawable.ic_stat_hermes,
                    label,
                    actionPendingIntent(context, "stop", payload, id, tag, mutable = false),
                ).setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MUTE)
            // Stop is durable and destructive: never from the lock screen.
            // (<31: the receiver refuses while the device is locked.)
            if (Build.VERSION.SDK_INT >= 31) stop.setAuthenticationRequired(true)
            builder.addAction(stop.build())
        }
        val promotedRequested = Build.VERSION.SDK_INT >= 36
        if (promotedRequested) {
            val style = NotificationCompat.ProgressStyle().setStyledByProgress(true)
            if (segments.isEmpty()) {
                style.setProgressIndeterminate(true)
            } else {
                for (segment in segments.take(12)) {
                    style.addProgressSegment(
                        NotificationCompat.ProgressStyle.Segment(100)
                            .setColor(segmentColor(segment.str("state"))),
                    )
                }
                style.setProgress((done * 100).coerceAtMost(segments.size * 100))
            }
            iconFor(args.str("trackerIconPath"))?.let { style.setProgressTrackerIcon(it) }
            builder.setStyle(style)
            builder.setRequestPromotedOngoing(true)
            args.str("shortText")?.let { builder.setShortCriticalText(it.take(7)) }
        } else {
            if (segments.isEmpty()) {
                builder.setProgress(0, 0, true)
            } else {
                builder.setProgress(segments.size, done, false)
            }
            builder.setStyle(NotificationCompat.BigTextStyle().bigText(text))
            loadBitmap(args.str("trackerIconPath"))?.let { builder.setLargeIcon(it) }
        }
        rememberTitle(context, tag, id, title, CH_LIVE, args.str("openPayload"))
        notify(context, tag, id, builder)
        var promotable = false
        if (Build.VERSION.SDK_INT >= 36) {
            try {
                val manager = context.getSystemService(NotificationManager::class.java)
                promotable = manager?.canPostPromotedNotifications() == true
            } catch (_: Exception) {
            }
        }
        return mapOf("posted" to true, "promoted" to promotable)
    }

    private fun segmentColor(state: String?): Int =
        when (state) {
            "done" -> Color.parseColor("#78C99B")
            "working" -> ACCENT
            "needs_you" -> Color.parseColor("#FFC66A")
            "failed" -> Color.parseColor("#FF8A80")
            else -> Color.parseColor("#6E675C")
        }

    /** Replaces a card in place with a short confirmation that dismisses itself. */
    fun confirm(context: Context, args: Map<String, Any?>) {
        val id = args.int("id") ?: return
        val tag = args.str("tag")
        if (args["onlyIfActive"] == true && !isActive(context, tag, id)) return
        val remembered = HermesNotificationActionInbox.posted(context, tag, id)
        confirmWith(
            context,
            tag,
            id,
            args.str("title") ?: remembered?.title ?: context.getString(R.string.rich_brand),
            args.str("text") ?: context.getString(R.string.rich_done),
            remembered?.channel ?: CH_CONVERSATIONS,
            args.long("timeoutMs") ?: 4_000L,
            remembered?.openPayload,
        )
    }

    fun confirmWith(
        context: Context,
        tag: String?,
        id: Int,
        title: String,
        text: String,
        channel: String,
        timeoutMs: Long,
        openPayload: String? = null,
    ) {
        ensureChannels(context)
        val builder =
            NotificationCompat.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_stat_hermes)
                .setColor(ACCENT)
                .setContentTitle(title)
                .setContentText(text)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setOngoing(false)
                .setAutoCancel(true)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        // 0 = stays until the user acts on it ("Couldn't send · open to retry").
        if (timeoutMs > 0) builder.setTimeoutAfter(timeoutMs)
        openIntent(context, id, tag, openPayload)?.let { builder.setContentIntent(it) }
        notify(context, tag, id, builder)
    }

    private fun isActive(context: Context, tag: String?, id: Int): Boolean =
        try {
            context.getSystemService(NotificationManager::class.java)
                ?.activeNotifications
                ?.any { it.id == id && it.tag == tag } == true
        } catch (_: Exception) {
            false
        }

    private fun notify(context: Context, tag: String?, id: Int, builder: NotificationCompat.Builder) {
        val manager = NotificationManagerCompat.from(context)
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        try {
            manager.notify(tag, id, builder.build())
        } catch (error: SecurityException) {
            Log.w(TAG, "notify refused: ${error.javaClass.simpleName}")
        }
    }

    const val ACCENT = 0xFFE8821C.toInt()
    const val LIVE_TIMEOUT_MS = 90_000L
}

/**
 * Durable action inbox. Delivery is at-least-once: [take] claims an entry
 * for a lease, [ack] removes it after the executor finished; an entry whose
 * executor died is handed out again flagged `reclaimed` (Dart replays only
 * server-idempotent routes). Reply text is AES-GCM encrypted at rest with an
 * Android Keystore key; payloads are opaque ids, validated again in Dart.
 */
internal object HermesNotificationActionInbox {
    private const val PREFS = "hermes_rich_notifications"
    private const val KEY_ACTIONS = "pending_actions_v2"
    private const val KEY_ACTIONS_V1 = "pending_actions_v1"
    private const val KEY_POSTED = "posted_titles_v1"
    private const val MAX_ACTIONS = 32
    private const val MAX_POSTED = 64

    /** A tap nobody executed within this window is reported as failed. */
    const val TTL_MS = 10 * 60 * 1000L

    /** An expired entry survives this long so the app can rescue a reply. */
    private const val HARD_TTL_MS = 24 * 60 * 60 * 1000L

    /** A claim older than this belongs to an executor that died. */
    private const val CLAIM_LEASE_MS = 3 * 60 * 1000L
    private const val KEY_ALIAS = "hermes_action_inbox_v1"
    private val lock = Any()

    data class Posted(val title: String, val channel: String, val openPayload: String?)

    fun enqueue(
        context: Context,
        actionId: String,
        payload: String,
        text: String?,
        notificationId: Int,
        tag: String?,
        source: String,
    ): String {
        val uid = UUID.randomUUID().toString()
        synchronized(lock) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            // v1 kept reply text in clear: drop it on first write.
            if (prefs.contains(KEY_ACTIONS_V1)) prefs.edit().remove(KEY_ACTIONS_V1).commit()
            val current = parse(prefs.getString(KEY_ACTIONS, null))
            val now = System.currentTimeMillis()
            val kept = JSONArray()
            for (index in 0 until current.length()) {
                val entry = current.optJSONObject(index) ?: continue
                if (now - entry.optLong("at") <= HARD_TTL_MS) kept.put(entry)
            }
            val route = try {
                JSONObject(payload).optString("route", "")
            } catch (_: Exception) {
                ""
            }
            val entry =
                JSONObject()
                    .put("uid", uid)
                    .put("action", actionId)
                    .put("payload", payload)
                    .put("route", route)
                    .put("notificationId", notificationId)
                    .put("tag", tag ?: JSONObject.NULL)
                    .put("source", source)
                    .put("at", now)
                    .put("claimedAt", 0L)
            if (!text.isNullOrEmpty()) entry.put("enc", encrypt(text) ?: return uid)
            kept.put(entry)
            while (kept.length() > MAX_ACTIONS) kept.remove(0)
            prefs.edit().putString(KEY_ACTIONS, kept.toString()).commit()
        }
        return uid
    }

    fun take(context: Context, routes: Set<String>): List<Map<String, Any?>> {
        synchronized(lock) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val current = parse(prefs.getString(KEY_ACTIONS, null))
            val now = System.currentTimeMillis()
            val taken = ArrayList<Map<String, Any?>>()
            val kept = JSONArray()
            for (index in 0 until current.length()) {
                val entry = current.optJSONObject(index) ?: continue
                val at = entry.optLong("at")
                if (now - at > HARD_TTL_MS) continue
                kept.put(entry)
                val route = entry.optString("route", "")
                if (routes.isNotEmpty() && route !in routes) continue
                val claimedAt = entry.optLong("claimedAt")
                if (claimedAt > 0 && now - claimedAt < CLAIM_LEASE_MS) continue
                entry.put("claimedAt", now)
                val text = entry.optString("enc", "").takeIf { it.isNotEmpty() }?.let(::decrypt)
                taken.add(
                    mapOf(
                        "uid" to entry.optString("uid"),
                        "action" to entry.optString("action"),
                        "payload" to entry.optString("payload"),
                        "text" to text,
                        "notificationId" to entry.optInt("notificationId"),
                        "tag" to entry.opt("tag").takeUnless { it == JSONObject.NULL },
                        "source" to entry.optString("source"),
                        "atMs" to at,
                        "reclaimed" to (claimedAt > 0),
                        "expired" to (entry.optBoolean("expired") || now - at > TTL_MS),
                    ),
                )
            }
            if (taken.isNotEmpty()) {
                prefs.edit().putString(KEY_ACTIONS, kept.toString()).commit()
            }
            return taken
        }
    }

    /** Removes executed (or terminally failed) taps. */
    fun ack(context: Context, uids: Set<String>) {
        if (uids.isEmpty()) return
        synchronized(lock) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val current = parse(prefs.getString(KEY_ACTIONS, null))
            val kept = JSONArray()
            for (index in 0 until current.length()) {
                val entry = current.optJSONObject(index) ?: continue
                if (entry.optString("uid") !in uids) kept.put(entry)
            }
            prefs.edit().putString(KEY_ACTIONS, kept.toString()).commit()
        }
    }

    /**
     * Marks unexecuted taps as expired and replaces their "Sending…" card
     * with a persistent "Couldn't send · open to retry" that opens the
     * conversation. [all] = the headless executor could not start at all.
     * Reply text stays (encrypted) so the app moves it to the composer.
     */
    fun expireUnexecuted(context: Context, all: Boolean) {
        val failed = ArrayList<Triple<Int, String?, String>>()
        synchronized(lock) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val current = parse(prefs.getString(KEY_ACTIONS, null))
            val now = System.currentTimeMillis()
            var changed = false
            for (index in 0 until current.length()) {
                val entry = current.optJSONObject(index) ?: continue
                if (entry.optBoolean("expired")) continue
                val claimedAt = entry.optLong("claimedAt")
                if (claimedAt > 0 && now - claimedAt < CLAIM_LEASE_MS) continue
                if (!all && now - entry.optLong("at") <= TTL_MS) continue
                entry.put("expired", true)
                changed = true
                if (entry.optString("source") == "notification") {
                    failed.add(
                        Triple(
                            entry.optInt("notificationId"),
                            entry.opt("tag").takeUnless { it == JSONObject.NULL } as String?,
                            entry.optString("action"),
                        ),
                    )
                }
            }
            if (changed) prefs.edit().putString(KEY_ACTIONS, current.toString()).commit()
        }
        for ((id, tag, action) in failed) {
            val remembered = posted(context, tag, id)
            HermesRichNotifications.confirmWith(
                context,
                tag,
                id,
                remembered?.title ?: context.getString(R.string.rich_brand),
                context.getString(
                    if (action == "reply") R.string.rich_reply_failed else R.string.rich_action_failed,
                ),
                remembered?.channel ?: HermesRichNotifications.CH_CONVERSATIONS,
                0L,
                remembered?.openPayload,
            )
        }
    }

    fun hasPending(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val current = parse(prefs.getString(KEY_ACTIONS, null))
        for (index in 0 until current.length()) {
            val entry = current.optJSONObject(index) ?: continue
            if (!entry.optBoolean("expired")) return true
        }
        return false
    }

    fun rememberPosted(
        context: Context,
        tag: String?,
        id: Int,
        title: String,
        channel: String,
        openPayload: String? = null,
    ) {
        synchronized(lock) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val current = parse(prefs.getString(KEY_POSTED, null))
            val key = "${tag ?: ""}#$id"
            val kept = JSONArray()
            for (index in 0 until current.length()) {
                val entry = current.optJSONObject(index) ?: continue
                if (entry.optString("k") != key) kept.put(entry)
            }
            kept.put(
                JSONObject()
                    .put("k", key)
                    .put("t", title.take(80))
                    .put("c", channel)
                    .put("o", openPayload?.takeIf { it.length <= 4_000 } ?: JSONObject.NULL),
            )
            while (kept.length() > MAX_POSTED) kept.remove(0)
            prefs.edit().putString(KEY_POSTED, kept.toString()).apply()
        }
    }

    fun postedTitle(context: Context, tag: String?, id: Int): Pair<String, String>? =
        posted(context, tag, id)?.let { it.title to it.channel }

    fun posted(context: Context, tag: String?, id: Int): Posted? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val current = parse(prefs.getString(KEY_POSTED, null))
        val key = "${tag ?: ""}#$id"
        for (index in current.length() - 1 downTo 0) {
            val entry = current.optJSONObject(index) ?: continue
            if (entry.optString("k") == key) {
                return Posted(
                    entry.optString("t"),
                    entry.optString("c"),
                    entry.opt("o").takeUnless { it == JSONObject.NULL } as String?,
                )
            }
        }
        return null
    }

    private fun key(): SecretKey? =
        try {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (store.getKey(KEY_ALIAS, null) as? SecretKey) ?: KeyGenerator
                .getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
                .apply {
                    init(
                        KeyGenParameterSpec.Builder(
                            KEY_ALIAS,
                            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                        )
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .setKeySize(256)
                            .build(),
                    )
                }.generateKey()
        } catch (error: Exception) {
            Log.w("HermesRichNotif", "inbox key unavailable: ${error.javaClass.simpleName}")
            null
        }

    private fun encrypt(text: String): String? {
        val secret = key() ?: return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secret)
            val sealed = cipher.iv + cipher.doFinal(text.toByteArray(Charsets.UTF_8))
            Base64.encodeToString(sealed, Base64.NO_WRAP)
        } catch (_: Exception) {
            null
        }
    }

    private fun decrypt(raw: String): String? {
        val secret = key() ?: return null
        return try {
            val sealed = Base64.decode(raw, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, sealed, 0, 12))
            String(cipher.doFinal(sealed, 12, sealed.size - 12), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }

    private fun parse(raw: String?): JSONArray =
        try {
            if (raw == null) JSONArray() else JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
}

/**
 * Receives Approve / Deny / Stop / Reply from notifications and widgets. It
 * never calls the server: it records the intent, shows "Sending…" in place
 * and wakes Flutter. When no engine is alive it starts the headless drain
 * worker; if that cannot run, the tap expires into a visible "Couldn't
 * send · open to retry" (never a silent loss). Android 12+ forbids activity
 * trampolines from here.
 */
class HermesNotificationActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION = "dev.xpetalab.hermesconsole.action.RICH_NOTIFICATION"
        const val EXTRA_ACTION_ID = "rich_action_id"
        const val EXTRA_PAYLOAD = "rich_payload"
        const val EXTRA_NOTIFICATION_ID = "rich_notification_id"
        const val EXTRA_NOTIFICATION_TAG = "rich_notification_tag"
        const val EXTRA_SOURCE = "rich_source"
        private val allowed = setOf("approve", "deny", "stop", "reply", "retry", "always", "session")
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val actionId = intent.getStringExtra(EXTRA_ACTION_ID) ?: return
        if (actionId !in allowed) return
        val payload = intent.getStringExtra(EXTRA_PAYLOAD) ?: return
        if (payload.length > 8_000) return
        val id = intent.getIntExtra(EXTRA_NOTIFICATION_ID, 0)
        val tag = intent.getStringExtra(EXTRA_NOTIFICATION_TAG)
        val source = intent.getStringExtra(EXTRA_SOURCE) ?: "notification"
        val text =
            RemoteInput.getResultsFromIntent(intent)
                ?.getCharSequence(HermesRichNotifications.REMOTE_INPUT_KEY)
                ?.toString()
                ?.trim()
                ?.take(4_000)
        if (actionId == "reply" && text.isNullOrEmpty()) return
        // Widget buttons have no setAuthenticationRequired: they are refused
        // on every API level while the keyguard is showing (lock-screen and
        // communal-hub hosts). The widget itself hides them there too.
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        if (source == "widget" && (keyguard == null || keyguard.isKeyguardLocked)) return
        val remembered = HermesNotificationActionInbox.posted(context, tag, id)
        val appLock =
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.app_lock_enabled", false)
        if (appLock || (Build.VERSION.SDK_INT < 31 && keyguard?.isDeviceLocked == true)) {
            if (source == "notification") {
                HermesRichNotifications.confirmWith(
                    context,
                    tag,
                    id,
                    remembered?.title ?: context.getString(R.string.rich_brand),
                    context.getString(R.string.rich_unlock_to_answer),
                    remembered?.channel ?: HermesRichNotifications.CH_CONVERSATIONS,
                    8_000L,
                    remembered?.openPayload,
                )
            }
            return
        }
        HermesNotificationActionInbox.enqueue(context, actionId, payload, text, id, tag, source)
        if (source == "notification") {
            HermesRichNotifications.confirmWith(
                context,
                tag,
                id,
                remembered?.title ?: context.getString(R.string.rich_brand),
                context.getString(R.string.rich_sending),
                remembered?.channel ?: HermesRichNotifications.CH_CONVERSATIONS,
                // The expiry sweep replaces it before this ever lapses.
                HermesNotificationActionInbox.TTL_MS + 5 * 60_000L,
                remembered?.openPayload,
            )
        }
        HermesActionDrainScheduler.scheduleExpirySweep(context)
        if (HermesRichNotifications.hasExecutor()) {
            HermesRichNotifications.notifyActionsAvailable()
        } else {
            HermesActionDrainScheduler.drainNow(context)
        }
    }
}

@Suppress("UNCHECKED_CAST")
private fun Any?.asMap(): Map<String, Any?> = (this as? Map<String, Any?>) ?: emptyMap()

private fun Map<String, Any?>.str(key: String): String? = (this[key] as? String)?.takeIf { it.isNotEmpty() }

private fun Map<String, Any?>.int(key: String): Int? =
    when (val value = this[key]) {
        is Int -> value
        is Long -> value.toInt()
        else -> null
    }

private fun Map<String, Any?>.long(key: String): Long? =
    when (val value = this[key]) {
        is Int -> value.toLong()
        is Long -> value
        else -> null
    }

private fun Map<String, Any?>.list(key: String): List<Any?> = (this[key] as? List<Any?>) ?: emptyList()
