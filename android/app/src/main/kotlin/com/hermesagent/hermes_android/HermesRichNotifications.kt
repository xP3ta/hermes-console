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

    private val channels = CopyOnWriteArrayList<MethodChannel>()
    private val main = Handler(Looper.getMainLooper())

    fun attach(context: Context, channel: MethodChannel, onDrainFinished: (() -> Unit)? = null) {
        val app = context.applicationContext
        channel.setMethodCallHandler { call, result ->
            if (call.method == "drainFinished") {
                onDrainFinished?.invoke()
                result.success(true)
            } else {
                handle(app, call, result, channel)
            }
        }
        channels.add(channel)
        cancelOrphanedLiveRows(app)
        dropAutomationShortcuts(app)
    }

    private var automationShortcutsDropped = false

    /**
     * Earlier builds pushed one long-lived conversation shortcut per
     * scheduled job, board task and goal. Automation results are plain rows
     * now: those shortcuts are withdrawn, once per process.
     */
    private fun dropAutomationShortcuts(context: Context) {
        if (automationShortcutsDropped) return
        automationShortcutsDropped = true
        try {
            val stale =
                ShortcutManagerCompat.getShortcuts(
                    context,
                    ShortcutManagerCompat.FLAG_MATCH_DYNAMIC or ShortcutManagerCompat.FLAG_MATCH_CACHED,
                ).map { it.id }.filter {
                    it.startsWith("hermes-cron-") || it.startsWith("hermes-task-") || it.startsWith("hermes-goal-")
                }
            if (stale.isNotEmpty()) ShortcutManagerCompat.removeLongLivedShortcuts(context, stale)
        } catch (_: Exception) {
        }
    }

    fun detach(channel: MethodChannel) {
        channels.remove(channel)
        channel.setMethodCallHandler(null)
        cancelLiveRowsOf(channel)
    }

    /**
     * Live rows that describe work only their engine can see (a chat turn of
     * the UI engine) are bound to it: when that engine goes away nobody can
     * update or end them, so they leave with it instead of claiming work.
     */
    private val liveOwners = java.util.concurrent.ConcurrentHashMap<String, MethodChannel>()
    private var liveContext: Context? = null

    /** Rows a tap just acted on: (tag, id) -> elapsed time until which a re-post waits. */
    private val liveHolds = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private const val EXTRA_OWNER_BOUND = "hermes.ownerBound"
    private const val LIVE_HOLD_MS = 20_000L

    private fun liveKey(tag: String?, id: Int): String = "${tag ?: ""}\u0000$id"

    /** A button of the row at tag + id was tapped: its confirmation stays. */
    fun holdLive(tag: String?, id: Int) {
        liveHolds[liveKey(tag, id)] = android.os.SystemClock.elapsedRealtime() + LIVE_HOLD_MS
    }

    private fun liveHeld(tag: String?, id: Int): Boolean {
        val key = liveKey(tag, id)
        val until = liveHolds[key] ?: return false
        if (android.os.SystemClock.elapsedRealtime() < until) return true
        liveHolds.remove(key)
        return false
    }

    private fun cancelLiveRowsOf(channel: MethodChannel) {
        val context = liveContext ?: return
        val manager = NotificationManagerCompat.from(context)
        for ((key, owner) in liveOwners.entries.toList()) {
            if (owner !== channel) continue
            liveOwners.remove(key)
            val split = key.lastIndexOf('\u0000')
            val tag = key.substring(0, split).ifEmpty { null }
            val id = key.substring(split + 1).toIntOrNull() ?: continue
            try {
                manager.cancel(tag, id)
            } catch (_: Exception) {
            }
        }
    }

    /** Engine-bound rows left by a process that died: nobody owns them now. */
    private fun cancelOrphanedLiveRows(context: Context) {
        liveContext = context
        try {
            val active =
                context.getSystemService(NotificationManager::class.java)?.activeNotifications ?: return
            val manager = NotificationManagerCompat.from(context)
            for (sbn in active) {
                if (!sbn.notification.extras.getBoolean(EXTRA_OWNER_BOUND)) continue
                if (liveOwners.containsKey(liveKey(sbn.tag, sbn.id))) continue
                manager.cancel(sbn.tag, sbn.id)
            }
        } catch (_: Exception) {
        }
    }

    /** True while some Flutter engine (UI, listener or headless drain) can execute taps. */
    fun hasExecutor(): Boolean = channels.isNotEmpty()

    /** Takes the card at tag + id down (its "Mark read" was tapped). */
    fun dismiss(context: Context, tag: String?, id: Int) {
        try {
            NotificationManagerCompat.from(context).cancel(tag, id)
        } catch (_: Exception) {
        }
        syncGroupSummary(context, tag)
    }

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

    private fun handle(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
        channel: MethodChannel? = null,
    ) {
        try {
            when (call.method) {
                "capabilities" -> result.success(capabilities(context))
                "postConversation" -> {
                    postConversation(context, call.arguments.asMap())
                    result.success(true)
                }
                "postLiveUpdate" -> result.success(postLiveUpdate(context, call.arguments.asMap(), channel))
                "decorateServiceNotification" -> result.success(decorateServiceNotification(context))
                "confirm" -> {
                    confirm(context, call.arguments.asMap())
                    result.success(true)
                }
                "cancel" -> {
                    val args = call.arguments.asMap()
                    liveOwners.remove(liveKey(args.str("tag"), args.int("id") ?: 0))
                    NotificationManagerCompat.from(context)
                        .cancel(args.str("tag"), args.int("id") ?: 0)
                    syncGroupSummary(context, args.str("tag"))
                    syncAutomationGroup(context)
                    result.success(true)
                }
                "takePendingActions" -> {
                    val routes = (call.argument<List<Any?>>("routes") ?: emptyList())
                        .mapNotNull { it as? String }
                        .toSet()
                    result.success(HermesNotificationActionInbox.take(context, routes))
                }
                "checkpointPendingAction" -> {
                    result.success(HermesNotificationActionInbox.checkpoint(context,
                        call.argument<String>("uid") ?: "", call.argument<String>("claimToken") ?: "",
                        call.argument<String>("expected") ?: "", call.argument<String>("phase") ?: ""))
                }
                "deferClaimedAction" -> {
                    result.success(HermesNotificationActionInbox.deferClaim(context,
                        call.argument<String>("uid") ?: "", call.argument<String>("claimToken") ?: ""))
                }
                "ackClaimedAction" -> {
                    result.success(HermesNotificationActionInbox.ackClaim(context,
                        call.argument<String>("uid") ?: "", call.argument<String>("claimToken") ?: ""))
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
                "openChannelSettings" ->
                    result.success(openChannelSettings(context, call.argument<String>("channel")))
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

    /**
     * Opens Android's own screen of one notification category of this app
     * (where the fixed connection card can be minimised or silenced). An
     * unknown category, or a system without per-category screens, opens the
     * app's notification settings instead.
     */
    private fun openChannelSettings(context: Context, channelId: String?): Boolean {
        val intents =
            buildList {
                if (Build.VERSION.SDK_INT >= 26) {
                    val known =
                        channelId != null &&
                            context.getSystemService(NotificationManager::class.java)
                                ?.getNotificationChannel(channelId) != null
                    if (known) {
                        add(
                            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                                .putExtra(Settings.EXTRA_CHANNEL_ID, channelId),
                        )
                    }
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

    /** Id of the shared foreground-service card (flutter_foreground_task). */
    const val SERVICE_NOTIFICATION_ID = 256

    /**
     * The background listener's ongoing card is posted by the foreground
     * service plugin with the launcher portrait as its large icon. Re-post
     * it with the neutral ">_" glyph instead: same id (the system keeps it
     * attached to the service), silent, only-alert-once.
     */
    fun decorateServiceNotification(context: Context): Boolean {
        return try {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return false
            val current = manager.activeNotifications.firstOrNull { it.id == SERVICE_NOTIFICATION_ID && it.tag == null }
                ?: return false
            if (current.notification.extras.getBoolean(EXTRA_GLYPH_DECORATED)) return true
            val glyph = glyphBitmap(context) ?: return false
            val builder = android.app.Notification.Builder.recoverBuilder(context, current.notification)
                .setLargeIcon(glyph)
                .setOnlyAlertOnce(true)
                .setColor(ACCENT)
            // Android 16's redesigned rows draw the APP icon (the launcher
            // portrait) in the avatar slot of every non-conversation card,
            // whatever the large icon. A conversation row draws its shortcut
            // / sender icon instead: make the ongoing card a quiet one-person
            // conversation spoken by the neutral ">_" glyph.
            if (Build.VERSION.SDK_INT >= 30) {
                val extras = current.notification.extras
                val title = extras.getCharSequence(android.app.Notification.EXTRA_TITLE)?.toString()
                    ?: context.getString(R.string.rich_brand)
                val text = extras.getCharSequence(android.app.Notification.EXTRA_TEXT)?.toString() ?: ""
                val icon = android.graphics.drawable.Icon.createWithBitmap(glyph)
                val speaker = android.app.Person.Builder().setKey(SERVICE_SHORTCUT_ID).setName(title).setIcon(icon).build()
                val me = android.app.Person.Builder().setKey("hermes-user")
                    .setName(context.getString(R.string.rich_you)).build()
                val style = android.app.Notification.MessagingStyle(me)
                    .setGroupConversation(false)
                    .addMessage(android.app.Notification.MessagingStyle.Message(text, current.notification.`when`.takeIf { it > 0 } ?: System.currentTimeMillis(), speaker))
                if (pushServiceShortcut(context, title)) {
                    builder.setStyle(style).setShortcutId(SERVICE_SHORTCUT_ID)
                    builder.extras.putParcelable(EXTRA_CONVERSATION_ICON, icon)
                }
            }
            builder.extras.putBoolean(EXTRA_GLYPH_DECORATED, true)
            manager.notify(SERVICE_NOTIFICATION_ID, builder.build())
            true
        } catch (error: Exception) {
            Log.w(TAG, "service decorate failed: ${error.javaClass.simpleName}")
            false
        }
    }

    private const val SERVICE_SHORTCUT_ID = "hermes-service"

    /** Conversation shortcut of the ongoing service card (">_" glyph). */
    private fun pushServiceShortcut(context: Context, title: String): Boolean =
        try {
            val shortcut =
                ShortcutInfoCompat.Builder(context, SERVICE_SHORTCUT_ID)
                    .setShortLabel(title.take(24))
                    .setLongLabel(title.take(64))
                    .setLongLived(true)
                    .setIntent(NewSessionLaunchContract.openAppIntent(context).setAction(Intent.ACTION_VIEW))
                    .setIcon(glyphIcon(context) ?: IconCompat.createWithResource(context, R.drawable.ic_hermes_glyph_large))
                    .setCategories(setOf("com.hermesagent.hermes_android.category.CONVERSATION"))
                    .build()
            ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
            true
        } catch (error: Exception) {
            Log.w(TAG, "service shortcut failed: ${error.javaClass.simpleName}")
            false
        }

    private const val EXTRA_GLYPH_DECORATED = "hermes.glyphDecorated"

    /** Neutral Hermes glyph on a dark disc (non-Bot cards' large icon). */
    fun glyphBitmap(context: Context): Bitmap? =
        try {
            val drawable = androidx.core.content.ContextCompat.getDrawable(context, R.drawable.ic_hermes_glyph_large) ?: null
            drawable?.let {
                val size = (64 * context.resources.displayMetrics.density).toInt()
                val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
                val canvas = android.graphics.Canvas(bitmap)
                it.setBounds(0, 0, size, size)
                it.draw(canvas)
                bitmap
            }
        } catch (_: Exception) {
            null
        }

    private var glyphIconCache: IconCompat? = null

    /** Neutral ">_" face as a Person/shortcut icon. */
    private fun glyphIcon(context: Context): IconCompat? =
        glyphIconCache ?: glyphBitmap(context)?.let { IconCompat.createWithBitmap(it) }?.also { glyphIconCache = it }

    private fun iconFor(path: String?): IconCompat? =
        loadBitmap(path)?.let { IconCompat.createWithAdaptiveBitmap(it) }

    private fun personIconFor(path: String?): IconCompat? =
        loadBitmap(path)?.let { IconCompat.createWithBitmap(it) }

    /**
     * Pushes the dynamic long-lived conversation shortcut the card points
     * at. Without a valid shortcut Android 11+ does not treat the card as a
     * conversation (no avatar in the shade, app icon instead), so a missing
     * open payload falls back to opening the app. Returns true when pushed.
     */
    private fun pushShortcut(context: Context, args: Map<String, Any?>, person: Person?): Boolean {
        val id = args.str("conversationId") ?: return false
        val name = args.str("conversationTitle") ?: args.str("title") ?: return false
        // Keeps SELECT_NOTIFICATION so the plugin routes the shortcut tap
        // exactly like a notification tap.
        val intent =
            args.str("openPayload")?.let { openActivityIntent(context, it) }
                ?: NewSessionLaunchContract.openAppIntent(context).setAction(Intent.ACTION_VIEW)
        val builder =
            ShortcutInfoCompat.Builder(context, id)
                .setShortLabel(name.take(24))
                .setLongLabel(name.take(64))
                .setLongLived(true)
                .setLocusId(LocusIdCompat(id))
                .setIntent(intent)
                .setCategories(setOf("com.hermesagent.hermes_android.category.CONVERSATION"))
        // Bot face (1:1) or room 2x2 tile (group): the shade's big avatar.
        val icon = iconFor(args.str("shortcutIconPath")) ?: iconFor(lastIconPath(args))
        builder.setIcon(icon ?: IconCompat.createWithResource(context, R.drawable.ic_hermes_glyph_large))
        if (person != null && args["isGroup"] != true) builder.setPerson(person)
        return try {
            ShortcutManagerCompat.pushDynamicShortcut(context, builder.build())
            true
        } catch (error: Exception) {
            Log.w(TAG, "shortcut push failed: ${error.javaClass.simpleName}")
            false
        }
    }

    private fun rememberTitle(
        context: Context,
        tag: String?,
        id: Int,
        title: String,
        channel: String,
        openPayload: String?,
        iconPath: String? = null,
        conversationId: String? = null,
    ) {
        HermesNotificationActionInbox.rememberPosted(
            context, tag, id, title, channel, openPayload, iconPath, conversationId,
        )
    }

    fun postConversation(context: Context, args: Map<String, Any?>) {
        ensureChannels(context)
        if (args.str("style") == "row") {
            postRow(context, args)
            return
        }
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
                            // Never setBot(true): Android 11+ refuses the
                            // conversation treatment when the shortcut's
                            // persons are all bots (NotificationRecord
                            // .isConversation → isOnlyBots) and falls back to
                            // the app icon inside the app's aggregate group.
                            // No icon = a letter avatar in the shade: fall
                            // back to the neutral ">_" face, never a letter
                            // or the app portrait.
                            .setIcon(personIconFor(message.str("iconPath")) ?: glyphIcon(context))
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
        val shortcutPushed = pushShortcut(context, args, firstPerson)
        val payload = args.str("actionPayload") ?: "{}"
        val alertKey = args.str("alertKey")
        // Same tag + id is an update of the SAME card: Android then honours
        // ONLY_ALERT_ONCE/SILENT against the already-seen record. News with a
        // new alertKey (a new room round) must alert again; a re-post of the
        // same key updates in place quietly.
        val alert = args["alert"] == true && !sameAlertKeyActive(context, tag, id, alertKey)
        val onlyAlertOnce = if (alertKey != null) !alert else args["onlyAlertOnce"] == true || !alert
        val accent = args.int("accent") ?: ACCENT
        val builder =
            NotificationCompat.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_stat_hermes)
                // State tint (done green, needs you amber, failed red); never
                // colorized, so the card stays a normal conversation.
                .setColor(accent)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(style)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setAutoCancel(true)
                .setOnlyAlertOnce(onlyAlertOnce)
                .setSilent(!alert)
                .setPriority(if (alert) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        // Quiet (non-approval) cards join ONE app-wide group while several
        // are shown, so the lock screen folds them into a single summary row
        // ("Hermes Console · 3 more"). A lone card stays ungrouped: Android
        // 16 folds single-child groups into an "Aggregate" bundle whose rows
        // lose the conversation avatar. Approvals never join it.
        val summaryLine = args.str("summaryLine")
        val quiet = summaryLine != null && channel == CH_CONVERSATIONS
        if (quiet && quietSiblingCount(context, tag, id) > 0) builder.setGroup(QUIET_GROUP)
        args.str("conversationId")?.takeIf { shortcutPushed }?.let {
            builder.setShortcutId(it)
            builder.setLocusId(LocusIdCompat(it))
        }
        args.str("subText")?.let { builder.setSubText(it) }
        args.long("timeoutMs")?.let { if (it > 0) builder.setTimeoutAfter(it) }
        openIntent(context, id, tag, args.str("openPayload"))?.let { builder.setContentIntent(it) }
        addCardActions(context, builder, args, id, tag, payload)
        val publicTitle = args.str("publicTitle")
        if (publicTitle != null) {
            // Lock screen: still a conversation (the Bot's state face as the
            // sender), but only the state line — no command or message text.
            val publicText = args.str("publicText") ?: ""
            val publicStyle = NotificationCompat.MessagingStyle(me).setGroupConversation(isGroup)
            if (isGroup) publicStyle.setConversationTitle(args.str("conversationTitle"))
            publicStyle.addMessage(
                NotificationCompat.MessagingStyle.Message(publicText, System.currentTimeMillis(), lastSender(persons, args)),
            )
            val publicBuilder =
                NotificationCompat.Builder(context, channel)
                    .setSmallIcon(R.drawable.ic_stat_hermes)
                    .setColor(accent)
                    .setContentTitle(publicTitle)
                    .setContentText(publicText)
                    .setStyle(publicStyle)
                    .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            args.str("conversationId")?.takeIf { shortcutPushed }?.let {
                publicBuilder.setShortcutId(it)
                publicBuilder.setLocusId(LocusIdCompat(it))
            }
            (loadBitmap(if (isGroup) args.str("shortcutIconPath") ?: lastIconPath(args) else lastIconPath(args)) ?: glyphBitmap(context))
                ?.let { publicBuilder.setLargeIcon(it) }
            builder.setPublicVersion(publicBuilder.build())
        }
        // Large icon = the speaker's state face (with badge) for launchers
        // that do not render MessagingStyle avatars; a room uses its 2x2 tile.
        val largeIconPath = if (isGroup) args.str("shortcutIconPath") ?: lastIconPath(args) else lastIconPath(args)
        (loadBitmap(largeIconPath) ?: glyphBitmap(context))?.let { builder.setLargeIcon(it) }
        rememberTitle(
            context, tag, id, title, channel, args.str("openPayload"),
            iconPath = args.str("shortcutIconPath") ?: lastIconPath(args),
            conversationId = args.str("conversationId")?.takeIf { shortcutPushed },
        )
        // A group conversation without an explicit conversation icon is drawn
        // as a face pile of the last senders (two faces + app badge). The room
        // tile is the one identity: set it as the conversation icon.
        val conversationIcon =
            if (isGroup && Build.VERSION.SDK_INT >= 30) personIconFor(args.str("shortcutIconPath"))?.toIcon(context) else null
        val summaryIcon = args.str("shortcutIconPath") ?: lastIconPath(args)
        notify(context, tag, id, builder) { notification ->
            conversationIcon?.let { notification.extras.putParcelable(EXTRA_CONVERSATION_ICON, it) }
            alertKey?.let { notification.extras.putString(EXTRA_ALERT_KEY, it) }
            if (quiet) {
                notification.extras.putString(EXTRA_SUMMARY_LINE, summaryLine)
                summaryIcon?.let { notification.extras.putString(EXTRA_SUMMARY_ICON, it) }
            }
        }
        syncGroupSummary(context, tag)
    }

    /** The buttons of a card: "open" brings the app up, the rest go to the action inbox. */
    private fun addCardActions(
        context: Context,
        builder: NotificationCompat.Builder,
        args: Map<String, Any?>,
        id: Int,
        tag: String?,
        payload: String,
    ) {
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
                    "reply", "answer" -> NotificationCompat.Action.SEMANTIC_ACTION_REPLY
                    "stop", "mute" -> NotificationCompat.Action.SEMANTIC_ACTION_MUTE
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
                val input = RemoteInput.Builder(REMOTE_INPUT_KEY).setLabel(action.str("hint") ?: label)
                // Answers the request itself offers: one-tap choices.
                val choices = action.list("choices").mapNotNull { (it as? String)?.takeIf { c -> c.isNotBlank() } }
                if (choices.isNotEmpty()) input.setChoices(choices.toTypedArray<CharSequence>())
                actionBuilder.addRemoteInput(input.build())
            }
            builder.addAction(actionBuilder.build())
        }
    }

    private const val AUTO_GROUP = "hermes.auto"

    /** Tag of the summary the automation rows fold under. */
    const val AUTO_TAG = "hermes.auto"
    private const val EXTRA_AUTO_ROW = "hermes.autoRow"
    private const val EXTRA_AUTO_LINE = "hermes.autoLine"

    /**
     * An automation result (a scheduled job, a board task, a goal) as a plain
     * row: its name, the state and the first line of the result. It is not a
     * conversation and pushes no shortcut; several fold under one summary
     * ([syncAutomationGroup]). Silent unless [args] say it alerts (a failure).
     */
    private fun postRow(context: Context, args: Map<String, Any?>) {
        val id = args.int("id") ?: return
        val tag = args.str("tag")
        val channel = channelFor(args.str("channel"))
        val title = args.str("title") ?: context.getString(R.string.rich_brand)
        val text = args.str("text") ?: ""
        val alert = args["alert"] == true
        val accent = args.int("accent") ?: ACCENT
        val builder =
            NotificationCompat.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_stat_hermes)
                .setColor(accent)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setCategory(if (alert) NotificationCompat.CATEGORY_ERROR else NotificationCompat.CATEGORY_STATUS)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .setSilent(!alert)
                .setPriority(if (alert) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_LOW)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        if (automationRows(context).any { !(it.tag == tag && it.id == id) }) builder.setGroup(AUTO_GROUP)
        args.str("subText")?.let { builder.setSubText(it) }
        // Only a Bot's face: a neutral row needs no picture beside the app's.
        loadBitmap(args.str("largeIconPath"))?.let { builder.setLargeIcon(it) }
        openIntent(context, id, tag, args.str("openPayload"))?.let { builder.setContentIntent(it) }
        addCardActions(context, builder, args, id, tag, args.str("actionPayload") ?: "{}")
        args.str("publicTitle")?.let { publicTitle ->
            // Lock screen: where it comes from and the state, never its name.
            builder.setPublicVersion(
                NotificationCompat.Builder(context, channel)
                    .setSmallIcon(R.drawable.ic_stat_hermes)
                    .setColor(accent)
                    .setContentTitle(publicTitle)
                    .setContentText(args.str("publicText") ?: "")
                    .setCategory(NotificationCompat.CATEGORY_STATUS)
                    .build(),
            )
        }
        rememberTitle(context, tag, id, title, channel, args.str("openPayload"), iconPath = args.str("largeIconPath"))
        val line = args.str("summaryLine")
        notify(context, tag, id, builder) { notification ->
            notification.extras.putBoolean(EXTRA_AUTO_ROW, true)
            line?.let { notification.extras.putString(EXTRA_AUTO_LINE, it) }
        }
        syncAutomationGroup(context)
    }

    private fun automationRows(context: Context): List<android.service.notification.StatusBarNotification> =
        try {
            context.getSystemService(NotificationManager::class.java)
                ?.activeNotifications
                ?.filter {
                    it.tag != AUTO_TAG &&
                        (it.notification.flags and android.app.Notification.FLAG_GROUP_SUMMARY) == 0 &&
                        it.notification.extras.getBoolean(EXTRA_AUTO_ROW)
                }
                ?.sortedByDescending { it.postTime }
                ?: emptyList()
        } catch (_: Exception) {
            emptyList()
        }

    /**
     * Keeps the automation rows folded: with two or more they share one group
     * under a silent summary ("3 automations"), whose lines are lock-safe. A
     * lone row stays ungrouped, and leaves the group before the summary is
     * cancelled (cancelling a summary takes its children with it).
     */
    fun syncAutomationGroup(context: Context) {
        val manager = NotificationManagerCompat.from(context)
        val rows = automationRows(context)
        fun regroup(sbn: android.service.notification.StatusBarNotification, group: String?) {
            try {
                manager.notify(
                    sbn.tag, sbn.id,
                    android.app.Notification.Builder.recoverBuilder(context, sbn.notification)
                        .setGroup(group).setOnlyAlertOnce(true).build(),
                )
            } catch (_: Exception) {
            }
        }
        if (rows.size < 2) {
            rows.filter { it.notification.group == AUTO_GROUP }.forEach { regroup(it, null) }
            manager.cancel(AUTO_TAG, SUMMARY_ID)
            return
        }
        rows.filter { it.notification.group != AUTO_GROUP }.forEach { regroup(it, AUTO_GROUP) }
        val lines = rows.mapNotNull { it.notification.extras.getString(EXTRA_AUTO_LINE) }
        val title = context.resources.getQuantityString(R.plurals.rich_auto_summary, rows.size, rows.size)
        val inbox = NotificationCompat.InboxStyle().setBigContentTitle(title)
        lines.take(5).forEach { inbox.addLine(it) }
        fun summary(): NotificationCompat.Builder =
            NotificationCompat.Builder(context, CH_CONVERSATIONS)
                .setSmallIcon(R.drawable.ic_stat_hermes)
                .setColor(ACCENT)
                .setContentTitle(title)
                .setContentText(lines.take(3).joinToString(" · "))
                .setStyle(inbox)
                .setGroup(AUTO_GROUP)
                .setGroupSummary(true)
                .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
                .setSilent(true)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
        val builder = summary()
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(summary().build())
        builder.setContentIntent(
            PendingIntent.getActivity(
                context,
                requestCode(AUTO_TAG, SUMMARY_ID, "open"),
                NewSessionLaunchContract.openAppIntent(context),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        notify(context, AUTO_TAG, SUMMARY_ID, builder)
    }

    private const val EXTRA_ALERT_KEY = "hermes.alertKey"

    /** The card at tag + id is still shown carrying the same news. */
    private fun sameAlertKeyActive(context: Context, tag: String?, id: Int, alertKey: String?): Boolean {
        alertKey ?: return false
        return try {
            context.getSystemService(NotificationManager::class.java)
                ?.activeNotifications
                ?.any { it.tag == tag && it.id == id && it.notification.extras.getString(EXTRA_ALERT_KEY) == alertKey }
                ?: false
        } catch (_: Exception) {
            false
        }
    }

    private fun lastSender(persons: Map<String, Person>, args: Map<String, Any?>): Person? =
        args.list("messages").map { it.asMap() }.lastOrNull { it.str("senderKey") != null }
            ?.str("senderKey")?.let { persons[it] }

    private fun lastIconPath(args: Map<String, Any?>): String? =
        args.list("messages").map { it.asMap() }.lastOrNull { it.str("iconPath") != null }?.str("iconPath")

    /** Quiet cards other than tag + id currently shown (summary excluded). */
    private fun quietSiblingCount(context: Context, tag: String?, id: Int): Int =
        quietCards(context).count { !(it.tag == tag && it.id == id) }

    /** Active quiet cards: rich conversation cards carrying a summary line. */
    private fun quietCards(context: Context): List<android.service.notification.StatusBarNotification> =
        try {
            context.getSystemService(NotificationManager::class.java)
                ?.activeNotifications
                ?.filter {
                    it.tag != QUIET_TAG &&
                        (it.notification.flags and android.app.Notification.FLAG_ONGOING_EVENT) == 0 &&
                        (it.notification.flags and android.app.Notification.FLAG_GROUP_SUMMARY) == 0 &&
                        it.notification.channelId == CH_CONVERSATIONS &&
                        it.notification.extras.getString(EXTRA_SUMMARY_LINE) != null
                }
                ?.sortedByDescending { it.postTime }
                ?: emptyList()
        } catch (_: Exception) {
            emptyList()
        }

    /** Group summary slot (legacy per-Bot/room summaries used it too). */
    const val SUMMARY_ID = 9

    /** Tag of the single app-wide quiet-group summary. */
    const val QUIET_TAG = "hermes.quiet"
    private const val QUIET_GROUP = "hermes.quiet"
    private const val EXTRA_SUMMARY_LINE = "hermes.summaryLine"
    private const val EXTRA_SUMMARY_ICON = "hermes.summaryIcon"

    /**
     * Keeps the one quiet group in sync with the shown cards. With two or
     * more quiet cards they all join [QUIET_GROUP] under one summary whose
     * icon is the stacked faces / room tiles of the newest cards and whose
     * line is lock-safe ("Radar · done · Nightly build · failed"); approvals
     * and Live Updates stay separate. Below two, the remaining card leaves
     * the group before the summary is cancelled (cancelling a summary
     * cascades to its children). The summary never carries actions.
     */
    fun syncGroupSummary(context: Context, @Suppress("UNUSED_PARAMETER") tag: String?) {
        val manager = NotificationManagerCompat.from(context)
        // Per-Bot/room summaries of the previous release: withdraw them
        // (their children are re-grouped below, so lift them out first).
        try {
            context.getSystemService(NotificationManager::class.java)
                ?.activeNotifications
                ?.filter {
                    it.id == SUMMARY_ID && it.tag != QUIET_TAG &&
                        (it.notification.flags and android.app.Notification.FLAG_GROUP_SUMMARY) != 0
                }
                ?.forEach { legacy ->
                    val group = legacy.notification.group
                    context.getSystemService(NotificationManager::class.java)
                        ?.activeNotifications
                        ?.filter { it.notification.group == group && it.id != SUMMARY_ID }
                        ?.forEach { child ->
                            manager.notify(
                                child.tag, child.id,
                                android.app.Notification.Builder.recoverBuilder(context, child.notification)
                                    .setGroup(null).setOnlyAlertOnce(true).build(),
                            )
                        }
                    manager.cancel(legacy.tag, SUMMARY_ID)
                }
        } catch (_: Exception) {
        }
        val cards = quietCards(context)
        if (cards.size < 2) {
            for (sbn in cards.filter { it.notification.group == QUIET_GROUP }) {
                try {
                    manager.notify(
                        sbn.tag, sbn.id,
                        android.app.Notification.Builder.recoverBuilder(context, sbn.notification)
                            .setGroup(null).setOnlyAlertOnce(true).build(),
                    )
                } catch (_: Exception) {
                }
            }
            manager.cancel(QUIET_TAG, SUMMARY_ID)
            return
        }
        // Cards posted before the group existed join it now, silently.
        for (sbn in cards.filter { it.notification.group != QUIET_GROUP }) {
            try {
                manager.notify(
                    sbn.tag, sbn.id,
                    android.app.Notification.Builder.recoverBuilder(context, sbn.notification)
                        .setGroup(QUIET_GROUP).setOnlyAlertOnce(true).build(),
                )
            } catch (_: Exception) {
            }
        }
        val lines = cards.mapNotNull { it.notification.extras.getString(EXTRA_SUMMARY_LINE) }
        val title = context.getString(R.string.rich_quiet_title)
        val more = context.resources.getQuantityString(R.plurals.rich_quiet_more, cards.size, cards.size)
        val oneLine = lines.take(3).joinToString(" · ")
        val inbox = NotificationCompat.InboxStyle()
            .setBigContentTitle("$title · $more")
            .setSummaryText(more)
        lines.take(5).forEach { inbox.addLine(it) }
        val faces = stackedFaces(
            context,
            cards.mapNotNull { it.notification.extras.getString(EXTRA_SUMMARY_ICON) }.distinct().take(3),
        )
        fun summary(): NotificationCompat.Builder =
            NotificationCompat.Builder(context, CH_CONVERSATIONS)
                .setSmallIcon(R.drawable.ic_stat_hermes)
                .setColor(ACCENT)
                .setContentTitle("$title · $more")
                .setContentText(oneLine)
                .setStyle(inbox)
                .setGroup(QUIET_GROUP)
                .setGroupSummary(true)
                .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
                .setSilent(true)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .apply { (faces ?: glyphBitmap(context))?.let { setLargeIcon(it) } }
        // Its lines are already lock-safe (names the public versions show
        // plus a state word): the lock screen gets the same summary.
        val builder = summary()
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(summary().build())
        NewSessionLaunchContract.openAppIntent(context).let { launch ->
            builder.setContentIntent(
                PendingIntent.getActivity(
                    context,
                    requestCode(QUIET_TAG, SUMMARY_ID, "open"),
                    launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        notify(context, QUIET_TAG, SUMMARY_ID, builder)
    }

    /**
     * Up to three faces / room tiles overlapped left to right (newest on
     * top) on a transparent square, each ringed in the shade's dark card
     * colour: the quiet summary's icon. Null when none could be decoded.
     */
    private fun stackedFaces(context: Context, paths: List<String>): Bitmap? {
        val faces = paths.mapNotNull { loadBitmap(it) }.take(3)
        if (faces.isEmpty()) return null
        val density = context.resources.displayMetrics.density
        val size = (64 * density).toInt()
        val face = when (faces.size) {
            1 -> size
            2 -> (size * 0.72f).toInt()
            else -> (size * 0.6f).toInt()
        }
        val step = if (faces.size == 1) 0f else (size - face).toFloat() / (faces.size - 1)
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(out)
        val ring = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#FF1F1F24") }
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG or android.graphics.Paint.FILTER_BITMAP_FLAG)
        val top = (size - face) / 2f
        // Oldest first so the newest face ends on top (left-most is newest).
        for ((index, bitmap) in faces.withIndex().reversed()) {
            val left = index * step
            val r = face / 2f
            canvas.drawCircle(left + r, top + r, r, ring)
            val inset = 1.5f * density
            val dst = android.graphics.RectF(left + inset, top + inset, left + face - inset, top + face - inset)
            val save = canvas.save()
            val clip = android.graphics.Path().apply { addOval(dst, android.graphics.Path.Direction.CW) }
            canvas.clipPath(clip)
            canvas.drawBitmap(bitmap, null, dst, paint)
            canvas.restoreToCount(save)
        }
        return out
    }

    /**
     * Android 16 Live Update: BigTextStyle (one line per member), ongoing,
     * requested promotion, no custom views, not colorized, not a group
     * summary. No progress bar on any release: room state is not a
     * measurable progress ("2 of 4 replied" is not 50 %), so it is text.
     */
    fun postLiveUpdate(
        context: Context,
        args: Map<String, Any?>,
        owner: MethodChannel? = null,
    ): Map<String, Any?> {
        ensureChannels(context)
        val id = args.int("id") ?: return mapOf("posted" to false)
        val tag = args.str("tag")
        val rowKey = liveKey(tag, id)
        // A tap on one of its buttons already changed the row.
        if (args["yieldToActions"] == true && liveHeld(tag, id)) return mapOf("posted" to false)
        // Another engine shows more about this work than this caller knows.
        if (args["yieldToOwner"] == true) {
            val current = liveOwners[rowKey]
            if (current != null && current !== owner && isActive(context, tag, id)) {
                return mapOf("posted" to false)
            }
        }
        val ownerBound = args["ownerBound"] == true && owner != null
        if (ownerBound && owner != null) {
            liveOwners[rowKey] = owner
        } else {
            liveOwners.remove(rowKey)
        }
        liveContext = context.applicationContext
        val title = args.str("title") ?: context.getString(R.string.rich_brand)
        // Never empty: the system rejects promotion for a blank Live Update.
        val text = args.str("text")?.takeIf { it.isNotBlank() }
            ?: context.getString(R.string.rich_thinking)
        val payload = args.str("actionPayload") ?: "{}"
        val startedAt = args.long("startedAtMs")
        val builder =
            NotificationCompat.Builder(context, CH_LIVE)
                .setSmallIcon(R.drawable.ic_stat_hermes)
                .setColor(args.int("accent") ?: WORKING)
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
            val publicBuilder =
                NotificationCompat.Builder(context, CH_LIVE)
                    .setSmallIcon(R.drawable.ic_stat_hermes)
                    .setColor(args.int("accent") ?: WORKING)
                    .setContentTitle(publicTitle)
                    .setContentText(args.str("publicText") ?: "")
                    .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                    .setOngoing(true)
            // Working face as large icon: identity by shape/colour only.
            loadBitmap(args.str("trackerIconPath"))?.let { publicBuilder.setLargeIcon(it) }
            if (startedAt != null && startedAt > 0) {
                publicBuilder.setWhen(startedAt).setShowWhen(true).setUsesChronometer(true)
            }
            args.int("progressMax")?.takeIf { it > 0 }?.let { max ->
                publicBuilder.setProgress(max, (args.int("progress") ?: 0).coerceIn(0, max), false)
            }
            builder.setPublicVersion(publicBuilder.build())
        }
        args.str("subText")?.let { builder.setSubText(it) }
        if (startedAt != null && startedAt > 0) {
            builder.setWhen(startedAt).setShowWhen(true).setUsesChronometer(true)
        }
        if (ownerBound) builder.addExtras(android.os.Bundle().apply { putBoolean(EXTRA_OWNER_BOUND, true) })
        // The rail of a chat turn: a plain bar here, segments on Android 16.
        val progressMax = args.int("progressMax")?.takeIf { it > 0 }
        val progress = (args.int("progress") ?: 0).coerceIn(0, progressMax ?: 0)
        if (progressMax != null) builder.setProgress(progressMax, progress, false)
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
        // "Open room": deep link to that room (same route as a tap).
        args.str("openLabel")?.let { label ->
            openIntent(context, id, tag, args.str("openPayload"))?.let { open ->
                builder.addAction(
                    NotificationCompat.Action.Builder(R.drawable.ic_stat_hermes, label, open)
                        .setShowsUserInterface(true)
                        .build(),
                )
            }
        }
        // Expanded member rows: one line per member ("builder · replied").
        // BigTextStyle is a promotable Live Update style on Android 16.
        val rowsText = args.str("bigText") ?: text
        // The multi-room summary is an ordinary ongoing card: only real
        // rooms become Live Updates (max two, decided in Dart).
        val promotedRequested = Build.VERSION.SDK_INT >= 36 && args["promote"] != false
        if (args["promote"] == false) {
            builder.setStyle(NotificationCompat.BigTextStyle().bigText(text))
            // Neutral Hermes glyph (not the app portrait) for the summary.
            builder.setLargeIcon(glyphBitmap(context))
        } else {
            builder.setStyle(NotificationCompat.BigTextStyle().bigText(rowsText))
            (loadBitmap(args.str("largeIconPath")) ?: loadBitmap(args.str("trackerIconPath")) ?: glyphBitmap(context))
                ?.let { builder.setLargeIcon(it) }
            if (promotedRequested) {
                builder.setRequestPromotedOngoing(true)
                args.str("shortText")?.let { builder.setShortCriticalText(it.take(7)) }
            }
        }
        rememberTitle(
            context, tag, id, title, CH_LIVE, args.str("openPayload"),
            iconPath = args.str("largeIconPath") ?: args.str("trackerIconPath"),
        )
        val styled =
            if (progressMax != null && Build.VERSION.SDK_INT >= 36 && args["promote"] != false) {
                progressStyled(context, builder.build(), args, progressMax, progress)
            } else {
                null
            }
        if (styled != null) notifyBuilt(context, tag, id, styled) else notify(context, tag, id, builder)
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

    /**
     * Android 16: the same row with `Notification.ProgressStyle` (still a
     * promotable Live Update). With `segments` the bar has one segment per
     * unit of work; without it, one continuous rail. Null when the platform
     * refuses it: the caller then posts the plain progress bar.
     */
    @androidx.annotation.RequiresApi(36)
    private fun progressStyled(
        context: Context,
        base: android.app.Notification,
        args: Map<String, Any?>,
        max: Int,
        progress: Int,
    ): android.app.Notification? =
        try {
            val accent = args.int("accent") ?: WORKING
            val segments = (args.int("segments") ?: 1).coerceIn(1, 24)
            val length = max / segments
            val style = android.app.Notification.ProgressStyle().setStyledByProgress(true)
            if (segments > 1 && length > 0 && length * segments == max) {
                style.setProgressSegments(
                    List(segments) { android.app.Notification.ProgressStyle.Segment(length).setColor(accent) },
                )
            } else {
                style.setProgressSegments(
                    listOf(android.app.Notification.ProgressStyle.Segment(max).setColor(accent)),
                )
            }
            style.setProgress(progress)
            loadBitmap(args.str("trackerIconPath"))?.let {
                style.setProgressTrackerIcon(android.graphics.drawable.Icon.createWithBitmap(it))
            }
            android.app.Notification.Builder.recoverBuilder(context, base).setStyle(style).build()
        } catch (error: Exception) {
            Log.w(TAG, "progress style failed: ${error.javaClass.simpleName}")
            null
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
            remembered?.iconPath,
            remembered?.conversationId,
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
        iconPath: String? = null,
        conversationId: String? = null,
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
        // Keep the card's identity (room tile / Bot face / glyph) while it
        // shows "Sending…" / "Approved": a bare template renders as an
        // iconless card titled only by the room.
        val icon = loadBitmap(iconPath) ?: glyphBitmap(context)
        icon?.let { builder.setLargeIcon(it) }
        var conversationIcon: android.graphics.drawable.Icon? = null
        if (conversationId != null && icon != null) {
            val speaker =
                Person.Builder()
                    .setKey("hermes-card:$conversationId")
                    .setName(title)
                    .setIcon(IconCompat.createWithBitmap(icon))
                    .build()
            val me = Person.Builder().setName(context.getString(R.string.rich_you)).setKey("hermes-user").build()
            builder.setStyle(
                NotificationCompat.MessagingStyle(me)
                    .setGroupConversation(true)
                    .setConversationTitle(title)
                    .addMessage(NotificationCompat.MessagingStyle.Message(text, System.currentTimeMillis(), speaker)),
            )
            builder.setCategory(NotificationCompat.CATEGORY_MESSAGE)
            builder.setShortcutId(conversationId)
            builder.setLocusId(LocusIdCompat(conversationId))
            if (Build.VERSION.SDK_INT >= 30) {
                conversationIcon = IconCompat.createWithBitmap(icon).toIcon(context)
            }
        }
        // 0 = stays until the user acts on it ("Couldn't send · open to retry").
        if (timeoutMs > 0) builder.setTimeoutAfter(timeoutMs)
        openIntent(context, id, tag, openPayload)?.let { builder.setContentIntent(it) }
        notify(context, tag, id, builder) { notification ->
            conversationIcon?.let { notification.extras.putParcelable(EXTRA_CONVERSATION_ICON, it) }
        }
        syncGroupSummary(context, tag)
        syncAutomationGroup(context)
    }

    private fun isActive(context: Context, tag: String?, id: Int): Boolean =
        try {
            context.getSystemService(NotificationManager::class.java)
                ?.activeNotifications
                ?.any { it.id == id && it.tag == tag } == true
        } catch (_: Exception) {
            false
        }

    private const val EXTRA_CONVERSATION_ICON = "android.conversationIcon"

    private fun notify(
        context: Context,
        tag: String?,
        id: Int,
        builder: NotificationCompat.Builder,
        decorate: (android.app.Notification) -> Unit = {},
    ) {
        val manager = NotificationManagerCompat.from(context)
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        try {
            manager.notify(tag, id, builder.build().also(decorate))
        } catch (error: SecurityException) {
            Log.w(TAG, "notify refused: ${error.javaClass.simpleName}")
        }
    }

    private fun notifyBuilt(context: Context, tag: String?, id: Int, notification: android.app.Notification) {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        try {
            NotificationManagerCompat.from(context).notify(tag, id, notification)
        } catch (error: SecurityException) {
            Log.w(TAG, "notify refused: ${error.javaClass.simpleName}")
        }
    }

    const val ACCENT = 0xFFE8821C.toInt()
    const val WORKING = 0xFF2F7CF6.toInt()
    const val DONE = 0xFF32D74B.toInt()
    const val NEEDS_YOU = 0xFFF5A623.toInt()
    const val FAILED = 0xFFEF4D4D.toInt()
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

    // The same encrypted inbox, with a process-shared transaction boundary.
    // SharedPreferences handles cache reads and cannot arbitrate engine/process
    // custody. Migrate v2 once under the file lock; no plaintext second store.
    private inline fun <T> transaction(context: Context, block: () -> T): T =
        synchronized(lock) {
            val file = java.io.File(context.filesDir, "notification_action_inbox.lock")
            java.io.RandomAccessFile(file, "rw").use { owner ->
                owner.channel.lock().use { block() }
            }
        }

    private fun actionFile(context: Context) = android.util.AtomicFile(
        java.io.File(context.filesDir, "notification_action_inbox_v2.json"))

    private fun readActions(context: Context): JSONArray {
        val file = actionFile(context)
        if (file.baseFile.exists() || java.io.File(file.baseFile.path + ".bak").exists()) {
            return file.openRead().bufferedReader().use { JSONArray(it.readText()) }
        }
        val legacy = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_ACTIONS, null)
        return if (legacy == null) JSONArray() else JSONArray(legacy)
    }

    private fun writeActions(context: Context, entries: JSONArray) {
        val file = actionFile(context)
        val stream = file.startWrite()
        try {
            stream.write(entries.toString().toByteArray(Charsets.UTF_8))
            file.finishWrite(stream)
        } catch (error: Throwable) {
            file.failWrite(stream)
            throw error
        }
        // Verification failure must retain the committed file, never failWrite it.
        check(file.openRead().bufferedReader().use { it.readText() } == entries.toString())
        check(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY_ACTIONS).commit())
    }

    private fun validClaim(entry: JSONObject, token: String): Boolean =
        token.isNotEmpty() && entry.optString("claimToken") == token &&
            System.currentTimeMillis() - entry.optLong("claimedAt") in 0 until CLAIM_LEASE_MS

    /** CAS on the exact live claim. An expired/predecessor engine has no authority. */
    fun checkpoint(context: Context, uid: String, token: String, expected: String, phase: String): Boolean =
        transaction(context) {
            val current = readActions(context)
            for (index in 0 until current.length()) {
                val entry = current.optJSONObject(index) ?: continue
                if (entry.optString("uid") != uid || !validClaim(entry, token)) continue
                val actual = entry.optString("phase", "prepared")
                if (actual != expected) return@transaction false
                val allowed = when (actual) {
                    "prepared" -> phase == "executing" || phase == "rescue_pending" || phase == "confirmed"
                    "executing" -> phase in setOf("confirmed", "rescue_pending", "uncertain")
                    "rescue_pending" -> phase == "rescued"
                    else -> false
                }
                if (!allowed) return@transaction false
                entry.put("phase", phase)
                writeActions(context, current)
                return@transaction true
            }
            false
        }

    fun deferClaim(context: Context, uid: String, token: String): Boolean = transaction(context) {
        val current = readActions(context)
        for (index in 0 until current.length()) {
            val entry = current.optJSONObject(index) ?: continue
            if (entry.optString("uid") == uid && validClaim(entry, token) && entry.optString("phase") == "rescue_pending") {
                entry.put("claimedAt", 0L).put("claimToken", "")
                writeActions(context, current)
                return@transaction true
            }
        }
        false
    }

    fun ackClaim(context: Context, uid: String, token: String): Boolean = transaction(context) {
        val current = readActions(context)
        val kept = JSONArray()
        var removed = false
        for (index in 0 until current.length()) {
            val entry = current.optJSONObject(index) ?: continue
            if (entry.optString("uid") == uid && validClaim(entry, token) &&
                entry.optString("phase") in setOf("confirmed", "rescued")) removed = true
            else kept.put(entry)
        }
        if (removed) writeActions(context, kept)
        removed
    }

    data class Posted(
        val title: String,
        val channel: String,
        val openPayload: String?,
        val iconPath: String? = null,
        val conversationId: String? = null,
    )

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
        transaction(context) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            // v1 kept reply text in clear: drop it on first write.
            if (prefs.contains(KEY_ACTIONS_V1)) prefs.edit().remove(KEY_ACTIONS_V1).commit()
            val current = readActions(context)
            val now = System.currentTimeMillis()
            val kept = JSONArray()
            for (index in 0 until current.length()) {
                val entry = current.optJSONObject(index) ?: continue
                kept.put(entry)
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
            // Never evict unacknowledged custody, including rescue/uncertainty.
            writeActions(context, kept)
        }
        return uid
    }

    fun take(context: Context, routes: Set<String>): List<Map<String, Any?>> {
        transaction(context) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val current = readActions(context)
            val now = System.currentTimeMillis()
            val taken = ArrayList<Map<String, Any?>>()
            val kept = JSONArray()
            for (index in 0 until current.length()) {
                val entry = current.optJSONObject(index) ?: continue
                val at = entry.optLong("at")
                // TTL is execution admission, never permission to erase custody.
                kept.put(entry)
                val route = entry.optString("route", "")
                if (routes.isNotEmpty() && route !in routes) continue
                val claimedAt = entry.optLong("claimedAt")
                if (claimedAt > 0 && now - claimedAt in 0 until CLAIM_LEASE_MS) continue
                var phase = entry.optString("phase", "prepared")
                if (claimedAt > 0 && phase in setOf("prepared", "executing")) phase = "uncertain"
                if (phase == "prepared" && (entry.optBoolean("expired") || now - at > TTL_MS)) phase = "rescue_pending"
                entry.put("phase", phase)
                val claimToken = UUID.randomUUID().toString()
                entry.put("claimToken", claimToken)
                entry.put("claimedAt", now)
                val text = entry.optString("enc", "").takeIf { it.isNotEmpty() }?.let(::decrypt)
                taken.add(
                    mapOf(
                        "uid" to entry.optString("uid"),
                        "claimToken" to claimToken,
                        "phase" to phase,
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
                writeActions(context, kept)
            }
            return taken
        }
    }

    /** Removes executed (or terminally failed) taps. */
    fun ack(context: Context, uids: Set<String>) {
        // Legacy uid-only ACKs cannot prove claim ownership; intentionally denied.
    }

    /**
     * Marks unexecuted taps as expired and replaces their "Sending…" card
     * with a persistent "Couldn't send · open to retry" that opens the
     * conversation. [all] = the headless executor could not start at all.
     * Reply text stays (encrypted) so the app moves it to the composer.
     */
    fun expireUnexecuted(context: Context, all: Boolean) {
        val failed = ArrayList<Triple<Int, String?, String>>()
        transaction(context) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val current = readActions(context)
            val now = System.currentTimeMillis()
            var changed = false
            for (index in 0 until current.length()) {
                val entry = current.optJSONObject(index) ?: continue
                if (entry.optBoolean("expired") || entry.optString("phase") in setOf("confirmed", "rescued", "uncertain", "rescue_pending")) continue;
                val claimedAt = entry.optLong("claimedAt")
                if (claimedAt > 0 && now - claimedAt in 0 until CLAIM_LEASE_MS) continue
                if (!all && now - entry.optLong("at") <= TTL_MS) continue
                entry.put("expired", true)
                changed = true
                // A "read" tap already took its card down: nothing to replace.
                if (entry.optString("source") == "notification" && entry.optString("action") != "read") {
                    failed.add(
                        Triple(
                            entry.optInt("notificationId"),
                            entry.opt("tag").takeUnless { it == JSONObject.NULL } as String?,
                            entry.optString("action"),
                        ),
                    )
                }
            }
            if (changed) writeActions(context, current)
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
                remembered?.iconPath,
                remembered?.conversationId,
            )
        }
    }

    fun hasPending(context: Context): Boolean = transaction(context) {
        readActions(context).length() > 0
    }

    fun rememberPosted(
        context: Context,
        tag: String?,
        id: Int,
        title: String,
        channel: String,
        openPayload: String? = null,
        iconPath: String? = null,
        conversationId: String? = null,
    ) {
        transaction(context) {
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
                    .put("o", openPayload?.takeIf { it.length <= 4_000 } ?: JSONObject.NULL)
                    .put("i", iconPath?.takeIf { it.length <= 512 } ?: JSONObject.NULL)
                    .put("v", conversationId?.takeIf { it.length <= 128 } ?: JSONObject.NULL),
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
                    entry.opt("i").takeUnless { it == JSONObject.NULL } as String?,
                    entry.opt("v").takeUnless { it == JSONObject.NULL } as String?,
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
        private val allowed =
            setOf("approve", "deny", "stop", "reply", "answer", "retry", "always", "session", "read", "mute")
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
        if ((actionId == "reply" || actionId == "answer") && text.isNullOrEmpty()) return
        // Widget buttons have no setAuthenticationRequired: they are refused
        // on every API level while the keyguard is showing (lock-screen and
        // communal-hub hosts). The widget itself hides them there too.
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        if (source == "widget" && (keyguard == null || keyguard.isKeyguardLocked)) return
        val remembered = HermesNotificationActionInbox.posted(context, tag, id)
        val appLock =
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.app_lock_enabled", false)
        val locked = appLock || (Build.VERSION.SDK_INT < 31 && keyguard?.isDeviceLocked == true)
        if (actionId == "read") {
            // "Mark read": the card goes at once and nothing is confirmed on
            // it. The chat's read mark on the server follows in the
            // background; behind a lock only the card goes (opening the chat
            // marks it read).
            if (source == "notification") HermesRichNotifications.dismiss(context, tag, id)
            if (locked) return
            HermesNotificationActionInbox.enqueue(context, actionId, payload, null, id, tag, source)
            HermesActionDrainScheduler.scheduleExpirySweep(context)
            if (HermesRichNotifications.hasExecutor()) {
                HermesRichNotifications.notifyActionsAvailable()
            } else {
                HermesActionDrainScheduler.drainNow(context)
            }
            return
        }
        if (locked) {
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
                    remembered?.iconPath,
                    remembered?.conversationId,
                )
            }
            return
        }
        HermesNotificationActionInbox.enqueue(context, actionId, payload, text, id, tag, source)
        if (source == "notification" && actionId == "stop") HermesRichNotifications.holdLive(tag, id)
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
                remembered?.iconPath,
                remembered?.conversationId,
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
