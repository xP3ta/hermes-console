package com.hermesagent.hermes_android

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.util.LruCache
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date

/**
 * Launcher (home-screen) widgets. One widget per subject; its SIZE decides
 * how much of that subject it shows, never a different widget:
 *
 * - Ahora: who needs you (with Permitir / Rechazar), what runs now, calm.
 * - Chat rápido: a new chat, the camera, the microphone.
 * - Cron: the next scheduled job; larger, all of them by next run.
 *
 * They are plain RemoteViews over the XML in `res/layout/lw_*.xml`, so every
 * size, padding and line box is in a resource a test can read and the
 * widget picker shows the very same layouts. Widgets only read the snapshots
 * Dart publishes (see [LauncherWidgetData]); they never talk to a server and
 * never wake anything up.
 */
enum class LauncherWidgetSubject { AHORA, QUICK, CRON, BOTS, ROOMS, TASKS, CHATS }

/**
 * Base of every launcher widget receiver. The three receivers shipped since
 * 1.2.13 keep their class names (a launcher binds a placed widget to its
 * receiver's name): they only changed what they draw.
 */
abstract class LauncherWidgetProvider(
    private val subject: LauncherWidgetSubject,
) : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        LauncherWidgets.update(context, appWidgetManager, subject, appWidgetIds)
    }

    /** A resize: the same subject, redrawn for the new size. */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        LauncherWidgets.update(context, appWidgetManager, subject, intArrayOf(appWidgetId))
    }
}

/** Every launcher widget receiver, for redraws that no publisher asked for. */
internal fun launcherWidgetReceivers(): List<Class<out AppWidgetProvider>> =
    listOf(
        NewSessionWidgetProvider::class.java,
        HermesCompactWidgetProvider::class.java,
        HermesControlWidgetProvider::class.java,
        HermesCronWidgetProvider::class.java,
        HermesBotsWidgetProvider::class.java,
        HermesRoomWidgetProvider::class.java,
        HermesTasksWidgetProvider::class.java,
        HermesChatsWidgetProvider::class.java,
    )

internal object LauncherWidgets {
    /** Below this height a widget is one row; from it on, it has a head and rows. */
    const val BOARD_MIN_HEIGHT = 110f

    /** From this width a widget is four cells wide. */
    const val WIDE_MIN_WIDTH = 250f

    fun update(
        context: Context,
        manager: AppWidgetManager,
        subject: LauncherWidgetSubject,
        ids: IntArray,
    ) {
        if (ids.isEmpty()) return
        val now = System.currentTimeMillis()
        val data = LauncherWidgetData.load(context, now)
        for (id in ids) {
            // A widget that cannot be drawn keeps its last drawing; it never
            // takes the receiver (or the other widgets) down with it.
            try {
                manager.updateAppWidget(id, views(context, manager, subject, data, id))
            } catch (_: Exception) {
            }
        }
        LauncherWidgetExpiry.schedule(
            context,
            data.nextChangeAtMs(
                withCron = placed(context, manager, HermesCronWidgetProvider::class.java),
                withTasks = placed(context, manager, HermesTasksWidgetProvider::class.java),
                withChats = placed(context, manager, HermesChatsWidgetProvider::class.java),
            ),
        )
    }

    /** A section's own clock only matters while its widget is on a home screen. */
    private fun placed(context: Context, manager: AppWidgetManager, receiver: Class<out AppWidgetProvider>): Boolean =
        try {
            manager.getAppWidgetIds(ComponentName(context, receiver)).isNotEmpty()
        } catch (_: Exception) {
            false
        }

    private fun views(
        context: Context,
        manager: AppWidgetManager,
        subject: LauncherWidgetSubject,
        data: LauncherWidgetData,
        id: Int,
    ): RemoteViews {
        val options = manager.getAppWidgetOptions(id)
        val category =
            options.getInt(
                AppWidgetManager.OPTION_APPWIDGET_HOST_CATEGORY,
                AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN,
            )
        val onLockScreen = category == AppWidgetProviderInfo.WIDGET_CATEGORY_KEYGUARD
        val sizes = LauncherWidgetSize.of(context, options)
        fun build(size: LauncherWidgetSize) =
            LauncherWidgetRenderer(context, data, size, onLockScreen).build(subject)
        if (Build.VERSION.SDK_INT >= 31 && sizes.size > 1) {
            // One drawing per orientation; the launcher picks.
            return RemoteViews(sizes.associate { SizeF(it.width, it.height) to build(it) })
        }
        return build(sizes.first())
    }

    /** Asks [receivers] to redraw their placed widgets (a local redraw only). */
    fun requestUpdate(context: Context, receivers: List<Class<out AppWidgetProvider>>) {
        val manager = AppWidgetManager.getInstance(context)
        for (receiver in receivers) {
            try {
                val ids = manager.getAppWidgetIds(ComponentName(context, receiver))
                if (ids.isEmpty()) continue
                context.sendBroadcast(
                    Intent(context, receiver)
                        .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids),
                )
            } catch (_: Exception) {
            }
        }
    }
}

/**
 * The background listener publishes the Bot Mode snapshot and redraws only
 * the Bot Mode receivers. Ahora shows the same approvals and the same working
 * bots, so it is redrawn when that snapshot changes. In-process only: the
 * listener's service runs in this process, and nothing is woken for it.
 */
internal object LauncherWidgetRefresh {
    private var listener: SharedPreferences.OnSharedPreferenceChangeListener? = null

    fun watch(context: Context) {
        if (listener != null) return
        val app = context.applicationContext
        val created =
            SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
                if (key == BOT_MODE_SNAPSHOT_KEY) {
                    // Bots and Salas are redrawn by the listener itself.
                    LauncherWidgets.requestUpdate(app, listOf(NewSessionWidgetProvider::class.java))
                }
            }
        try {
            HomeWidgetPlugin.getData(app).registerOnSharedPreferenceChangeListener(created)
            // SharedPreferences keeps listeners weakly: this field is what
            // keeps it alive.
            listener = created
        } catch (_: Exception) {
        }
    }
}

/** Size of a placed widget in dp, as its launcher reports it. */
internal data class LauncherWidgetSize(val width: Float, val height: Float) {
    val wide: Boolean get() = width >= LauncherWidgets.WIDE_MIN_WIDTH
    val board: Boolean get() = height >= LauncherWidgets.BOARD_MIN_HEIGHT

    companion object {
        /** A two-cell, one-row widget: what is drawn before a launcher reports a size. */
        val FALLBACK = LauncherWidgetSize(160f, 72f)

        fun of(context: Context, options: Bundle): List<LauncherWidgetSize> {
            if (Build.VERSION.SDK_INT >= 31) {
                @Suppress("DEPRECATION")
                val reported =
                    options.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES)
                val sizes =
                    reported
                        ?.filter { it.width > 0f && it.height > 0f }
                        ?.map { LauncherWidgetSize(it.width, it.height) }
                        ?.distinct()
                if (!sizes.isNullOrEmpty()) return sizes
            }
            val minWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
            val maxWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH)
            val minHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)
            val maxHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)
            // Portrait is the narrow, tall pair; landscape the wide, short one.
            val landscape =
                context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
            return when {
                landscape && maxWidth > 0 && minHeight > 0 ->
                    listOf(LauncherWidgetSize(maxWidth.toFloat(), minHeight.toFloat()))
                minWidth > 0 && maxHeight > 0 ->
                    listOf(LauncherWidgetSize(minWidth.toFloat(), maxHeight.toFloat()))
                else -> listOf(FALLBACK)
            }
        }
    }
}

/**
 * Everything the widgets read, taken once per redraw:
 * - [chat]: the conversation the app last showed (published by the app while
 *   it is alive; older than [STALE_AFTER_MS] it is not trusted).
 * - [bots]: bots, rooms and their pending approvals (published by the
 *   background listener, at most every 5 min; untrusted after 12 min).
 * - [cron]: the scheduled jobs, as last listed by the Cron screen or by the
 *   listener's own cron pass.
 */
internal class LauncherWidgetData(
    val nowMs: Long,
    val chat: HermesWidgetState,
    val bots: BotModeWidgetState,
    val cron: CronWidgetState = CronWidgetState(),
    val tasks: TasksWidgetState = TasksWidgetState(),
    val chats: ChatsWidgetState = ChatsWidgetState(),
) {
    val chatFresh: Boolean get() = chat.configured && chat.instanceId != null && !chat.isStale(nowMs)
    val botsFresh: Boolean get() = bots.present && !bots.isStale(nowMs)

    /** The app can reach its server right now, as far as it told us. */
    val chatOnline: Boolean
        get() =
            chatFresh &&
                (
                    chat.connectionState == HermesWidgetConnectionState.CONNECTED ||
                        chat.connectionState == HermesWidgetConnectionState.CONNECTING
                    )
    val botsOnline: Boolean get() = botsFresh && bots.connected

    /** Face of the agent that answers ordinary chats, once a listener drew it. */
    fun agentFace(): String? = botFace(DEFAULT_PROFILE)

    private fun bot(profile: String?): WidgetBot? =
        bots.bots.firstOrNull { it.profile == (profile ?: DEFAULT_PROFILE) }

    fun botFace(profile: String?): String? = bot(profile)?.let { it.idleFacePath ?: it.facePath }

    /** The name the owner gave the agent of [profile], when the roster is known. */
    fun botName(profile: String?): String? = bot(profile)?.name

    /**
     * When a drawing made now stops being true by itself: data becomes old,
     * an outcome expires, a job's time comes, the day changes under "hoy".
     */
    fun nextChangeAtMs(withCron: Boolean, withTasks: Boolean, withChats: Boolean): Long? =
        listOfNotNull(
            chat.staleAtMs().takeIf { chat.configured },
            bots.nextExpiryMs(nowMs),
            tasks.nextChangeAtMs(nowMs).takeIf { withTasks },
            chats.nextChangeAtMs(nowMs).takeIf { withChats },
            cron.nextChangeAtMs(nowMs).takeIf { withCron },
            LauncherWidgetDays.nextMidnight(nowMs).takeIf { withCron && cron.jobs.isNotEmpty() },
        ).filter { it > nowMs }.minOrNull()

    companion object {
        const val DEFAULT_PROFILE = "default"

        fun load(context: Context, nowMs: Long): LauncherWidgetData {
            val prefs =
                try {
                    HomeWidgetPlugin.getData(context)
                } catch (_: Exception) {
                    null
                }
            return LauncherWidgetData(
                nowMs = nowMs,
                chat = prefs?.let { safely { HermesWidgetState.from(it) } } ?: HermesWidgetState(),
                bots = prefs?.let { safely { BotModeWidgetState.from(it) } } ?: BotModeWidgetState(),
                cron = prefs?.let { safely { CronWidgetState.from(it) } } ?: CronWidgetState(),
                tasks = prefs?.let { safely { TasksWidgetState.from(it) } } ?: TasksWidgetState(),
                chats = prefs?.let { safely { ChatsWidgetState.from(it) } } ?: ChatsWidgetState(),
            )
        }

        private inline fun <T> safely(read: () -> T): T? =
            try {
                read()
            } catch (_: Exception) {
                null
            }
    }
}

/** Where a tap goes. Every destination is a deep link the app already had. */
internal sealed class LauncherWidgetOpen {
    object App : LauncherWidgetOpen()

    object Setup : LauncherWidgetOpen()

    /** A conversation of the ordinary chat list. */
    data class Session(val instanceId: String?, val sessionId: String) : LauncherWidgetOpen()

    /** A notification-style destination (bot chat, room, cron job, task). */
    data class Payload(val payload: String) : LauncherWidgetOpen()

    data class NewChat(val instanceId: String?, val target: NewSessionLaunchTarget) : LauncherWidgetOpen()
}

internal enum class AhoraMode { SETUP, OFFLINE, NEED, RUN, CALM }

/**
 * What is asked of the owner. Only a request the app described is called a
 * permission or a question; anything else is told as it is known: it needs you.
 */
internal enum class AhoraNeedKind { PERMISSION, QUESTION, UNKNOWN }

/** Something waiting for the owner. */
internal data class AhoraNeed(
    val who: String,
    val what: String,
    val kind: AhoraNeedKind,
    val facePath: String?,
    /** Payload of Permitir / Rechazar; null when it can only be answered in the app. */
    val answerPayload: String?,
    val open: LauncherWidgetOpen,
)

/** Something running right now. */
internal data class AhoraRun(
    val name: String,
    /** A plain word for what it is doing ("Terminal", "Responde"). */
    val phase: String,
    /** What it is about (the chat's title, the room's name). */
    val about: String?,
    val facePath: String?,
    val sinceMs: Long,
    val open: LauncherWidgetOpen,
)

/** Something that ended a moment ago. */
internal data class AhoraDone(
    val name: String,
    val about: String?,
    val facePath: String?,
    val atMs: Long,
    val failed: Boolean,
    val open: LauncherWidgetOpen,
)

internal data class AhoraModel(
    val mode: AhoraMode,
    val needs: List<AhoraNeed> = emptyList(),
    val runs: List<AhoraRun> = emptyList(),
    val recent: List<AhoraDone> = emptyList(),
    /** OFFLINE: the time of the last data. */
    val sinceMs: Long = 0,
) {
    companion object {
        fun from(context: Context, data: LauncherWidgetData): AhoraModel {
            val chat = data.chat
            val bots = data.bots.trusted(data.nowMs)
            val configured = (chat.configured && chat.instanceId != null) || bots.present
            if (!configured) return AhoraModel(AhoraMode.SETUP)
            val agent = context.getString(R.string.lw_agent)
            val chatOpen: LauncherWidgetOpen =
                chat.sessionId?.let { LauncherWidgetOpen.Session(chat.instanceId, it) }
                    ?: LauncherWidgetOpen.App
            val lastChat =
                chat.sessionTitle?.let { title ->
                    val at = chat.lastActivityAtMs ?: 0L
                    if (at <= 0) {
                        null
                    } else {
                        AhoraDone(
                            name = agent,
                            about = title,
                            facePath = data.agentFace(),
                            atMs = at,
                            failed = chat.agentState == HermesWidgetAgentState.ERROR,
                            open = chatOpen,
                        )
                    }
                }
            if (!data.chatOnline && !data.botsOnline) {
                // Nothing here is known to be true now: say since when, and
                // keep only what had already ended.
                return AhoraModel(
                    mode = AhoraMode.OFFLINE,
                    recent = listOfNotNull(lastChat),
                    sinceMs = maxOf(chat.updatedAtMs, data.bots.updatedAtMs),
                )
            }
            val needs = mutableListOf<AhoraNeed>()
            val runs = mutableListOf<AhoraRun>()
            val recent = mutableListOf<AhoraDone>()
            // Profiles whose work the chats already show: the same agent is
            // not listed a second time as a working bot.
            val shown = mutableSetOf<String>()
            if (data.chatOnline && chat.listsActivity) {
                for (activity in chat.active) {
                    val name = data.botName(activity.profile) ?: agent
                    val face = data.botFace(activity.profile)
                    val open = LauncherWidgetOpen.Session(chat.instanceId, activity.sessionId)
                    shown += activity.profile ?: LauncherWidgetData.DEFAULT_PROFILE
                    if (activity.needsYou) {
                        val need = activity.need
                        needs +=
                            AhoraNeed(
                                who = name,
                                what = need?.text ?: activity.title ?: "",
                                kind =
                                    when {
                                        need == null -> AhoraNeedKind.UNKNOWN
                                        need.question -> AhoraNeedKind.QUESTION
                                        else -> AhoraNeedKind.PERMISSION
                                    },
                                facePath = face,
                                answerPayload = need?.actionPayload,
                                open = open,
                            )
                    } else {
                        runs +=
                            AhoraRun(
                                name = name,
                                phase =
                                    when (activity.state) {
                                        HermesWidgetAgentState.THINKING -> context.getString(R.string.lw_thinking)
                                        HermesWidgetAgentState.STREAMING -> context.getString(R.string.lw_responding)
                                        else -> activity.phase ?: context.getString(R.string.lw_working)
                                    },
                                about = activity.title,
                                facePath = face,
                                sinceMs = activity.startedAtMs,
                                open = open,
                            )
                    }
                }
                if (chat.active.none { it.sessionId == chat.sessionId }) lastChat?.let { recent += it }
            } else if (data.chatOnline) {
                // A snapshot of schema 1: only the last chat that spoke.
                shown += LauncherWidgetData.DEFAULT_PROFILE.takeIf { chat.agentState in LIVE_STATES } ?: ""
                when (chat.agentState) {
                    HermesWidgetAgentState.WAITING_APPROVAL ->
                        needs +=
                            AhoraNeed(
                                who = agent,
                                what = chat.sessionTitle ?: "",
                                // Schema 1 only says it waits, not for what.
                                kind = AhoraNeedKind.UNKNOWN,
                                facePath = data.agentFace(),
                                answerPayload = null,
                                open = chatOpen,
                            )
                    HermesWidgetAgentState.THINKING,
                    HermesWidgetAgentState.STREAMING,
                    HermesWidgetAgentState.TOOL_EXECUTION,
                    ->
                        runs +=
                            AhoraRun(
                                name = agent,
                                phase = phase(context, chat),
                                about = chat.sessionTitle,
                                facePath = data.agentFace(),
                                sinceMs = 0,
                                open = chatOpen,
                            )
                    else -> lastChat?.let { recent += it }
                }
            }
            if (data.botsOnline) {
                for (approval in bots.approvals) {
                    needs +=
                        AhoraNeed(
                            who = approval.title,
                            what = approval.text,
                            kind = AhoraNeedKind.PERMISSION,
                            facePath = approval.facePath,
                            answerPayload = approval.actionPayload.takeIf { approval.canApprove },
                            open = LauncherWidgetOpen.Payload(approval.openPayload),
                        )
                }
                for (bot in bots.bots) {
                    val open = LauncherWidgetOpen.Payload(bot.openPayload)
                    when (bot.state) {
                        WidgetBotState.WORKING, WidgetBotState.THINKING ->
                            if (bot.profile !in shown) runs +=
                                AhoraRun(
                                    name = bot.name,
                                    phase =
                                        context.getString(
                                            if (bot.roomName != null) R.string.lw_responding else R.string.lw_working,
                                        ),
                                    about = bot.roomName ?: bot.steps.lastOrNull() ?: bot.line,
                                    facePath = bot.idleFacePath ?: bot.facePath,
                                    sinceMs = bot.sinceMs,
                                    open = open,
                                )
                        WidgetBotState.DONE, WidgetBotState.FAILED ->
                            recent +=
                                AhoraDone(
                                    name = bot.name,
                                    about = bot.roomName ?: bot.steps.lastOrNull() ?: bot.line,
                                    facePath = bot.idleFacePath ?: bot.facePath,
                                    atMs = bot.sinceMs,
                                    failed = bot.state == WidgetBotState.FAILED,
                                    open = open,
                                )
                        else -> Unit
                    }
                }
            }
            recent.sortByDescending { it.atMs }
            return AhoraModel(
                mode =
                    when {
                        needs.isNotEmpty() -> AhoraMode.NEED
                        runs.isNotEmpty() -> AhoraMode.RUN
                        else -> AhoraMode.CALM
                    },
                needs = needs,
                runs = runs,
                recent = recent,
            )
        }

        private val LIVE_STATES =
            setOf(
                HermesWidgetAgentState.THINKING,
                HermesWidgetAgentState.STREAMING,
                HermesWidgetAgentState.TOOL_EXECUTION,
                HermesWidgetAgentState.WAITING_APPROVAL,
            )

        /** What the agent is doing, in a word. */
        private fun phase(context: Context, chat: HermesWidgetState): String =
            when (chat.agentState) {
                HermesWidgetAgentState.THINKING -> context.getString(R.string.lw_thinking)
                HermesWidgetAgentState.STREAMING -> context.getString(R.string.lw_responding)
                else -> chat.toolName ?: context.getString(R.string.lw_working)
            }
    }
}

/** Draws one widget at one size. */
internal class LauncherWidgetRenderer(
    private val context: Context,
    private val data: LauncherWidgetData,
    private val size: LauncherWidgetSize,
    private val onLockScreen: Boolean,
) {
    private val pkg: String = context.packageName
    private val density: Float = context.resources.displayMetrics.density

    /** Text boxes are in sp: a larger system font needs taller rows. */
    private val fontScale: Float = context.resources.configuration.fontScale.coerceIn(1f, 2f)

    fun build(subject: LauncherWidgetSubject): RemoteViews =
        when (subject) {
            LauncherWidgetSubject.AHORA -> ahora()
            LauncherWidgetSubject.QUICK -> quick()
            LauncherWidgetSubject.CRON -> if (size.board) cronBoard() else cronStrip()
            LauncherWidgetSubject.BOTS -> bots()
            LauncherWidgetSubject.ROOMS -> rooms()
            LauncherWidgetSubject.TASKS -> tasks()
            LauncherWidgetSubject.CHATS -> chats()
        }

    // ---------------------------------------------------------------- Chat rápido

    private fun quick(): RemoteViews {
        val instance = data.chat.instanceId
        val ready = data.chat.configured && instance != null
        fun newChat(target: NewSessionLaunchTarget): LauncherWidgetOpen =
            if (ready) LauncherWidgetOpen.NewChat(instance, target) else LauncherWidgetOpen.Setup
        val views = RemoteViews(pkg, if (size.wide) R.layout.lw_quick_wide else R.layout.lw_quick_small)
        views.setOnClickPendingIntent(R.id.lw_quick_new, pending(newChat(NewSessionLaunchTarget.COMPOSER)))
        views.setOnClickPendingIntent(R.id.lw_quick_voice, pending(newChat(NewSessionLaunchTarget.VOICE)))
        if (size.wide) {
            views.setOnClickPendingIntent(R.id.lw_quick_camera, pending(newChat(NewSessionLaunchTarget.CAMERA)))
            views.setOnClickPendingIntent(
                R.id.lw_quick_agent,
                pending(if (ready) LauncherWidgetOpen.App else LauncherWidgetOpen.Setup),
            )
            face(views, R.id.lw_quick_face, R.id.lw_quick_glyph, data.agentFace(), 38f)
        } else {
            // The label stays only while it fits with the same room on both
            // sides; a pill too narrow for it keeps the "+" alone, centred.
            val label = context.getString(R.string.lw_new)
            val pill = size.width - 2 * dp(R.dimen.lw_quick_pad) - dp(R.dimen.lw_quick_gap) - dp(R.dimen.lw_touch)
            val needed =
                2 * dp(R.dimen.lw_quick_pill_pad) + dp(R.dimen.lw_quick_icon) +
                    dp(R.dimen.lw_quick_icon_gap) + textWidth(label, R.dimen.lw_text_title)
            views.setViewVisibility(
                R.id.lw_quick_new_label,
                if (needed <= pill) View.VISIBLE else View.GONE,
            )
        }
        return views
    }

    // ---------------------------------------------------------------- Ahora

    private fun ahora(): RemoteViews {
        val model = AhoraModel.from(context, data)
        if (onLockScreen) return ahoraLocked(model)
        if (!size.board) return ahoraStrip(model)
        // The answer buttons need their own row: a board too short for it
        // shows the one-row form instead of squeezing them.
        if (model.mode == AhoraMode.NEED && size.height < NEED_BOARD_MIN_HEIGHT * fontScale) {
            return ahoraStrip(model)
        }
        return ahoraBoard(model)
    }

    /** Lock screen: how many, never who or what, and nothing to tap but the app. */
    private fun ahoraLocked(model: AhoraModel): RemoteViews {
        val views = stripViews()
        val needs = model.needs.size
        val runs = model.runs.size
        glyph(views, R.id.lw_lead_glyph, R.drawable.lw_okc_gold, R.drawable.lw_ic_lock, R.color.lw_gold)
        val lines =
            listOfNotNull(
                plural(R.plurals.lw_needs_you, needs).takeIf { needs > 0 },
                plural(R.plurals.lw_running, runs).takeIf { runs > 0 },
            )
        text(
            views,
            title =
                lines.firstOrNull()
                    ?: context.getString(
                        if (model.mode == AhoraMode.OFFLINE) R.string.lw_no_connection else R.string.lw_calm,
                    ),
            sub = lines.getOrNull(1),
        )
        views.setOnClickPendingIntent(android.R.id.background, pending(LauncherWidgetOpen.App))
        return views
    }

    private fun ahoraStrip(model: AhoraModel): RemoteViews =
        when (model.mode) {
            AhoraMode.NEED -> needStrip(model.needs.first())
            AhoraMode.RUN -> runStrip(model.runs.first())
            AhoraMode.CALM -> {
                val views = stripViews()
                glyph(views, R.id.lw_lead_glyph, R.drawable.lw_okc_green, R.drawable.lw_ic_check, R.color.lw_green)
                val last = model.recent.firstOrNull()
                text(
                    views,
                    title = context.getString(R.string.lw_calm),
                    sub =
                        last
                            ?.takeIf { size.wide && !it.failed }
                            ?.let { context.getString(R.string.lw_finished_at, it.name, moment(it.atMs)) },
                )
                views.setOnClickPendingIntent(android.R.id.background, pending(last?.open ?: LauncherWidgetOpen.App))
                views
            }
            AhoraMode.OFFLINE -> {
                val views = stripViews()
                views.setInt(android.R.id.background, "setBackgroundResource", R.drawable.lw_card_stale)
                glyph(views, R.id.lw_lead_glyph, R.drawable.lw_okc_amber, R.drawable.lw_ic_cloud_off, R.color.lw_amber)
                text(
                    views,
                    title = context.getString(R.string.lw_no_connection),
                    sub = since(model.sinceMs),
                    subColor = R.color.lw_amber,
                )
                views.setOnClickPendingIntent(android.R.id.background, pending(LauncherWidgetOpen.App))
                views
            }
            AhoraMode.SETUP -> {
                val views = stripViews()
                face(views, R.id.lw_lead_face, R.id.lw_lead_glyph, null, LEAD)
                text(
                    views,
                    title = context.getString(R.string.lw_setup),
                    sub = context.getString(R.string.lw_setup_hint),
                )
                views.setOnClickPendingIntent(android.R.id.background, pending(LauncherWidgetOpen.Setup))
                views
            }
        }

    private fun needStrip(need: AhoraNeed): RemoteViews {
        if (size.wide && size.height >= ASK_STRIP_MIN_HEIGHT) return askStrip(need)
        val views = stripViews()
        views.setInt(android.R.id.background, "setBackgroundResource", R.drawable.lw_card_hero)
        face(views, R.id.lw_lead_face, R.id.lw_lead_glyph, need.facePath, LEAD)
        text(
            views,
            title = need.who,
            sub =
                context.getString(
                    when (need.kind) {
                        AhoraNeedKind.QUESTION -> R.string.lw_asks_you_short
                        AhoraNeedKind.PERMISSION -> R.string.lw_asks_permission_short
                        AhoraNeedKind.UNKNOWN -> R.string.lw_needs_you_short
                    },
                ),
            subColor = R.color.lw_gold,
        )
        views.setOnClickPendingIntent(android.R.id.background, pending(need.open))
        return views
    }

    private fun runStrip(run: AhoraRun): RemoteViews {
        val views = stripViews()
        face(views, R.id.lw_lead_face, R.id.lw_lead_glyph, run.facePath, LEAD)
        if (size.wide) {
            text(views, title = "${run.name} · ${run.phase}", sub = run.about)
            timer(views, R.id.lw_end_timer, run.sinceMs)
        } else if (run.sinceMs > 0) {
            text(views, title = run.name, sub = "${run.phase} · ")
            timer(views, R.id.lw_sub_timer, run.sinceMs)
        } else {
            text(views, title = run.name, sub = run.phase)
        }
        views.setOnClickPendingIntent(android.R.id.background, pending(run.open))
        return views
    }

    /** One row, four cells: who asks and what, with its answer buttons. */
    private fun askStrip(need: AhoraNeed): RemoteViews {
        val views = RemoteViews(pkg, R.layout.lw_ask_strip)
        face(views, R.id.lw_ask_face, R.id.lw_ask_glyph, need.facePath, 24f)
        views.setTextViewText(R.id.lw_ask_title, askTitle(need))
        views.setTextViewText(R.id.lw_ask_detail, need.what)
        buttons(views, need, withOpen = true)
        views.setOnClickPendingIntent(android.R.id.background, pending(need.open))
        return views
    }

    /** Both words of the two equal pills of a narrow card fit, with the pill's own padding. */
    private fun answersFit(): Boolean {
        val pill = (size.width - 2 * dp(R.dimen.lw_pad_h) - dp(R.dimen.lw_button_gap)) / 2
        val needed = textWidth(context.getString(R.string.lw_deny), R.dimen.lw_text_button) + 2 * ANSWER_PAD
        return needed <= pill
    }

    private fun askTitle(need: AhoraNeed): String =
        context.getString(
            when (need.kind) {
                AhoraNeedKind.QUESTION -> R.string.lw_asks_you
                AhoraNeedKind.PERMISSION -> R.string.lw_asks_permission
                AhoraNeedKind.UNKNOWN -> R.string.lw_needs_you_who
            },
            need.who,
        )

    /**
     * Permitir / Rechazar go through the same broadcast as a notification's
     * buttons (source "widget": the receiver refuses them while the device is
     * locked). Without an answer payload only "Abrir" is offered.
     */
    private fun buttons(views: RemoteViews, need: AhoraNeed, withOpen: Boolean, short: Boolean = false) {
        val payload = need.answerPayload
        if (payload != null) {
            views.setOnClickPendingIntent(R.id.lw_button_yes, answer("approve", payload))
            views.setOnClickPendingIntent(R.id.lw_button_no, answer("deny", payload))
            views.setTextViewText(
                R.id.lw_button_yes_label,
                context.getString(if (short) R.string.lw_allow_short else R.string.lw_allow),
            )
            views.setTextViewText(
                R.id.lw_button_no_label,
                context.getString(if (short) R.string.lw_deny_short else R.string.lw_deny),
            )
            views.setViewVisibility(R.id.lw_button_no, View.VISIBLE)
            views.setViewVisibility(R.id.lw_button_open, if (withOpen) View.VISIBLE else View.GONE)
            if (withOpen) views.setOnClickPendingIntent(R.id.lw_button_open, pending(need.open))
        } else {
            // Nothing can be answered from here: one button, the gold one,
            // opens the conversation where it can.
            views.setTextViewText(R.id.lw_button_yes_label, context.getString(R.string.lw_open))
            views.setOnClickPendingIntent(R.id.lw_button_yes, pending(need.open))
            views.setViewVisibility(R.id.lw_button_no, View.GONE)
            views.setViewVisibility(R.id.lw_button_open, View.GONE)
        }
    }

    private fun ahoraBoard(model: AhoraModel): RemoteViews {
        val active = model.mode == AhoraMode.NEED || model.mode == AhoraMode.RUN
        val counts =
            listOfNotNull(
                plural(R.plurals.lw_for_you, model.needs.size).takeIf { model.needs.isNotEmpty() },
                plural(R.plurals.lw_running, model.runs.size).takeIf { model.runs.isNotEmpty() },
            ).joinToString(" · ")
        val views =
            board(
                card =
                    when (model.mode) {
                        AhoraMode.NEED -> R.drawable.lw_card_hero
                        AhoraMode.OFFLINE -> R.drawable.lw_card_stale
                        else -> R.drawable.lw_card
                    },
                icon = R.drawable.lw_ic_bolt,
                gold = active,
                label = context.getString(R.string.lw_ahora_name),
                right =
                    when {
                        model.mode == AhoraMode.OFFLINE -> moment(model.sinceMs).takeIf { model.sinceMs > 0 }
                        size.wide -> counts.takeIf { it.isNotEmpty() }
                        else -> null
                    },
                rightColor = if (model.mode == AhoraMode.OFFLINE) R.color.lw_amber else null,
                rightIcon = model.mode == AhoraMode.OFFLINE,
            )
        var room = bodyHeight()
        val rows = mutableListOf<RemoteViews>()
        when (model.mode) {
            AhoraMode.NEED -> {
                val need = model.needs.first()
                val ask = RemoteViews(pkg, R.layout.lw_ask)
                face(ask, R.id.lw_ask_face, R.id.lw_ask_glyph, need.facePath, LEAD)
                ask.setTextViewText(R.id.lw_ask_title, askTitle(need))
                ask.setTextViewText(R.id.lw_ask_detail, need.what)
                ask.setOnClickPendingIntent(R.id.lw_ask, pending(need.open))
                views.addView(R.id.lw_body, ask)
                val answers = RemoteViews(pkg, if (size.wide) R.layout.lw_buttons else R.layout.lw_buttons_even)
                buttons(answers, need, withOpen = false, short = !size.wide && !answersFit())
                views.addView(R.id.lw_body, answers)
                room -= ASK_HEIGHT * fontScale + dp(R.dimen.lw_touch)
            }
            AhoraMode.CALM, AhoraMode.OFFLINE, AhoraMode.SETUP -> {
                val calm = RemoteViews(pkg, R.layout.lw_calm)
                when (model.mode) {
                    AhoraMode.OFFLINE -> {
                        glyph(calm, R.id.lw_calm_mark, R.drawable.lw_okc_amber, R.drawable.lw_ic_cloud_off, R.color.lw_amber)
                        calm.setTextViewText(R.id.lw_calm_title, context.getString(R.string.lw_no_connection))
                    }
                    AhoraMode.SETUP -> {
                        glyph(calm, R.id.lw_calm_mark, R.drawable.lw_okc_chip, R.drawable.ic_console_mark, null)
                        calm.setTextViewText(R.id.lw_calm_title, context.getString(R.string.lw_setup))
                        if (size.wide) {
                            calm.setTextViewText(R.id.lw_calm_sub, context.getString(R.string.lw_setup_hint))
                            calm.setViewVisibility(R.id.lw_calm_sub, View.VISIBLE)
                        }
                    }
                    else -> glyph(calm, R.id.lw_calm_mark, R.drawable.lw_okc_green, R.drawable.lw_ic_check, R.color.lw_green)
                }
                views.addView(R.id.lw_body, calm)
                room -= dp(R.dimen.lw_touch)
            }
            AhoraMode.RUN -> Unit
        }
        val fit = (room / rowHeight()).toInt().coerceIn(0, MAX_ROWS)
        for (run in model.runs.take(fit)) rows += runRow(run)
        for (done in model.recent.take(fit - rows.size)) rows += doneRow(done, dim = model.mode == AhoraMode.OFFLINE)
        if (rows.isNotEmpty() && model.mode != AhoraMode.RUN) views.addView(R.id.lw_body, RemoteViews(pkg, R.layout.lw_line))
        addRows(views, rows, room)
        views.setOnClickPendingIntent(
            android.R.id.background,
            pending(if (model.mode == AhoraMode.SETUP) LauncherWidgetOpen.Setup else LauncherWidgetOpen.App),
        )
        return views
    }

    private fun runRow(run: AhoraRun): RemoteViews {
        val row = RemoteViews(pkg, R.layout.lw_row)
        face(row, R.id.lw_row_face, R.id.lw_row_glyph, run.facePath, LEAD)
        row.setTextViewText(R.id.lw_row_title, run.name)
        row.setTextViewText(R.id.lw_row_sub, listOfNotNull(run.phase, run.about).joinToString(" · "))
        row.setImageViewResource(R.id.lw_row_mark, R.drawable.lw_dot)
        row.setViewVisibility(R.id.lw_row_mark, View.VISIBLE)
        timer(row, R.id.lw_row_timer, run.sinceMs)
        row.setOnClickPendingIntent(R.id.lw_row, pending(run.open))
        return row
    }

    private fun doneRow(done: AhoraDone, dim: Boolean): RemoteViews {
        val row = RemoteViews(pkg, R.layout.lw_row)
        face(row, R.id.lw_row_face, R.id.lw_row_glyph, done.facePath, LEAD)
        row.setTextViewText(R.id.lw_row_title, done.name)
        val word = context.getString(if (done.failed) R.string.lw_failed else R.string.lw_finished)
        row.setTextViewText(R.id.lw_row_sub, listOfNotNull(word, done.about).joinToString(" · "))
        if (done.failed) {
            row.setTextColor(R.id.lw_row_sub, color(R.color.lw_red))
        } else {
            row.setImageViewResource(R.id.lw_row_mark, R.drawable.lw_ic_check)
            row.setInt(R.id.lw_row_mark, "setColorFilter", color(R.color.lw_green))
            row.setViewVisibility(R.id.lw_row_mark, View.VISIBLE)
        }
        if (done.atMs > 0) {
            row.setTextViewText(R.id.lw_row_time, moment(done.atMs))
            row.setViewVisibility(R.id.lw_row_time, View.VISIBLE)
        }
        if (dim) dim(row)
        row.setOnClickPendingIntent(R.id.lw_row, pending(done.open))
        return row
    }

    // ---------------------------------------------------------------- Cron

    /** A job opens in the app's Cron screen; without a link, the app itself. */
    private fun cronOpen(job: CronWidgetJob?): LauncherWidgetOpen =
        job?.openPayload?.let { LauncherWidgetOpen.Payload(it) } ?: LauncherWidgetOpen.App

    /** One row: the next job. Under it, what is wrong, if anything is. */
    private fun cronStrip(): RemoteViews {
        val cron = data.cron
        val views = stripViews()
        val next = cron.ordered(data.nowMs).firstOrNull()
        val stale = cron.present && cron.isStale(data.nowMs)
        if (stale) {
            // The schedule is still a schedule, but it has had no news.
            views.setInt(android.R.id.background, "setBackgroundResource", R.drawable.lw_card_stale)
            glyph(views, R.id.lw_lead_glyph, R.drawable.lw_icb, R.drawable.lw_ic_cloud_off, R.color.lw_amber)
        } else {
            glyph(views, R.id.lw_lead_glyph, R.drawable.lw_icb, R.drawable.lw_ic_clock, R.color.lw_muted)
        }
        // The third line only when the card is tall enough for three.
        val third = size.height >= THREE_LINES_MIN_HEIGHT * fontScale
        val failed = cron.failedCount
        val note: Pair<String, Int>? =
            when {
                stale -> since(cron.updatedAtMs)?.let { it to R.color.lw_amber }
                failed > 0 -> plural(R.plurals.lw_cron_failed, failed) to R.color.lw_red
                else -> null
            }
        when {
            next == null ->
                text(
                    views,
                    title = context.getString(R.string.lw_cron),
                    sub =
                        context.getString(
                            when {
                                cron.present -> R.string.lw_cron_empty
                                size.wide -> R.string.lw_cron_unknown
                                else -> R.string.lw_cron_unknown_short
                            },
                        ),
                )
            next.scheduledAfter(data.nowMs) ->
                text(
                    views,
                    title = next.name,
                    sub = cronWhen(next.nextMs),
                    sub2 = note?.first.takeIf { third },
                    sub2Color = note?.second,
                )
            else ->
                text(
                    views,
                    title = next.name,
                    sub = cronResult(next).first,
                    subColor = cronResult(next).second,
                    sub2 = note?.first.takeIf { third && stale },
                    sub2Color = note?.second,
                )
        }
        views.setOnClickPendingIntent(android.R.id.background, pending(cronOpen(next)))
        return views
    }

    /** Two rows or more: every job by next run, as many as fit. */
    private fun cronBoard(): RemoteViews {
        val cron = data.cron
        val stale = cron.present && cron.isStale(data.nowMs)
        val failed = cron.failedCount
        val views =
            board(
                card = if (stale) R.drawable.lw_card_stale else R.drawable.lw_card,
                icon = R.drawable.lw_ic_clock,
                gold = false,
                label = context.getString(R.string.lw_cron),
                right =
                    when {
                        stale -> moment(cron.updatedAtMs).takeIf { cron.updatedAtMs > 0 }
                        failed > 0 -> plural(R.plurals.lw_cron_failed, failed)
                        else -> null
                    },
                rightColor = if (stale) R.color.lw_amber else R.color.lw_red,
                rightIcon = stale,
            )
        val room = bodyHeight()
        val fit = (room / rowHeight()).toInt().coerceIn(0, MAX_ROWS)
        val jobs = cron.rows(data.nowMs, fit)
        if (jobs.isEmpty()) {
            val empty = RemoteViews(pkg, R.layout.lw_calm)
            glyph(empty, R.id.lw_calm_mark, R.drawable.lw_okc_chip, R.drawable.lw_ic_clock, R.color.lw_muted)
            empty.setTextViewText(
                R.id.lw_calm_title,
                context.getString(if (cron.present) R.string.lw_cron_empty else R.string.lw_cron_unknown),
            )
            views.addView(R.id.lw_body, empty)
            addRows(views, emptyList(), room - dp(R.dimen.lw_touch))
        } else {
            addRows(views, jobs.map(::cronRow), room)
        }
        views.setOnClickPendingIntent(android.R.id.background, pending(cronOpen(jobs.firstOrNull())))
        return views
    }

    private fun cronRow(job: CronWidgetJob): RemoteViews {
        val row = RemoteViews(pkg, R.layout.lw_row_cron)
        val ahead = job.scheduledAfter(data.nowMs)
        row.setTextViewText(R.id.lw_cron_time, if (ahead) clock(job.nextMs) else NO_TIME)
        row.setTextViewText(R.id.lw_cron_day, if (ahead) LauncherWidgetDays.day(context, job.nextMs, data.nowMs) else "")
        row.setTextViewText(R.id.lw_row_title, job.name)
        val (line, tone) = cronResult(job)
        row.setTextViewText(R.id.lw_row_sub, line)
        if (tone != null) row.setTextColor(R.id.lw_row_sub, color(tone))
        if (job.last == CronWidgetResult.FAILED) {
            // A failure is read from across the room: time and name too.
            row.setTextColor(R.id.lw_cron_time, color(R.color.lw_red))
            row.setTextColor(R.id.lw_row_title, color(R.color.lw_red))
        }
        row.setViewVisibility(
            R.id.lw_row_mark,
            if (job.last == CronWidgetResult.OK && !job.paused) View.VISIBLE else View.GONE,
        )
        row.setOnClickPendingIntent(R.id.lw_row, pending(cronOpen(job)))
        return row
    }

    /** "hoy 17:00", "mar 3:00". */
    private fun cronWhen(atMs: Long): String =
        context.getString(R.string.lw_day_time, LauncherWidgetDays.day(context, atMs, data.nowMs), clock(atMs))

    /** How the last run went, in a line, and its colour (null: the usual one). */
    private fun cronResult(job: CronWidgetJob): Pair<String, Int?> =
        when {
            job.last == CronWidgetResult.FAILED ->
                context.getString(R.string.lw_cron_failed_at, cronLast(job.lastMs, withTime = true)).trim() to R.color.lw_red
            job.paused -> context.getString(R.string.lw_cron_paused) to null
            job.last == CronWidgetResult.RUNNING -> context.getString(R.string.lw_cron_running) to R.color.lw_gold
            job.last == CronWidgetResult.OK && job.lastMs > 0 ->
                context.getString(R.string.lw_cron_last, cronLast(job.lastMs, withTime = false)) to null
            else -> context.getString(R.string.lw_cron_never) to null
        }

    /**
     * When a run happened: "hoy 8:00" / "hoy a las 3:00", "ayer", "vie", "25 sept".
     * The time of day is only given for today and yesterday, where it tells something.
     */
    private fun cronLast(atMs: Long, withTime: Boolean): String {
        if (atMs <= 0) return ""
        val day = LauncherWidgetDays.day(context, atMs, data.nowMs)
        val offset = LauncherWidgetDays.offset(atMs, data.nowMs)
        if (offset < -1 || offset > 0) return day
        val time = clock(atMs)
        if (!withTime) return if (offset == 0) context.getString(R.string.lw_day_time, day, time) else day
        val one = time.startsWith("1:") || time.startsWith("01:")
        return context.getString(if (one) R.string.lw_day_at_time_one else R.string.lw_day_at_time, day, time)
    }

    // ---------------------------------------------------------------- Bots

    /** A subject the app has never published: what it is, and where to look. */
    private fun unknown(icon: Int, label: Int, hint: Int, hintShort: Int): RemoteViews {
        if (!size.board) {
            val views = stripViews()
            glyph(views, R.id.lw_lead_glyph, R.drawable.lw_icb, icon, R.color.lw_muted)
            text(
                views,
                title = context.getString(label),
                sub = context.getString(if (size.wide) hint else hintShort),
            )
            views.setOnClickPendingIntent(android.R.id.background, pending(LauncherWidgetOpen.App))
            return views
        }
        val views =
            board(
                card = R.drawable.lw_card,
                icon = icon,
                gold = false,
                label = context.getString(label),
                right = null,
                rightColor = null,
                rightIcon = false,
            )
        emptyLine(views, icon, context.getString(if (size.wide) hint else hintShort))
        views.setOnClickPendingIntent(android.R.id.background, pending(LauncherWidgetOpen.App))
        return views
    }

    /** The only line of a board with nothing to list. */
    private fun emptyLine(views: RemoteViews, icon: Int, line: String) {
        val empty = RemoteViews(pkg, R.layout.lw_calm)
        glyph(empty, R.id.lw_calm_mark, R.drawable.lw_okc_chip, icon, R.color.lw_muted)
        empty.setTextViewText(R.id.lw_calm_title, line)
        views.addView(R.id.lw_body, empty)
        addRows(views, emptyList(), bodyHeight() - dp(R.dimen.lw_touch))
    }

    private fun bots(): RemoteViews {
        if (!data.bots.present) {
            return unknown(R.drawable.lw_ic_team, R.string.lw_bots, R.string.lw_bots_unknown, R.string.lw_bots_unknown_short)
        }
        // Without recent news nobody is shown as working or waiting.
        val offline = !data.botsOnline
        val bots = data.bots.trusted(data.nowMs).bots.sortedBy { if (offline) 0 else it.state.priority }
        return if (size.board) botsBoard(bots, offline) else botsStrip(bots, offline)
    }

    private fun WidgetBot.working(): Boolean = state == WidgetBotState.WORKING || state == WidgetBotState.THINKING

    /** One row: the faces of the team and, under them, who waits for you. */
    private fun botsStrip(bots: List<WidgetBot>, offline: Boolean): RemoteViews {
        val views = RemoteViews(pkg, R.layout.lw_faces)
        views.removeAllViews(R.id.lw_faces)
        views.setInt(
            android.R.id.background,
            "setBackgroundResource",
            if (offline) R.drawable.lw_card_stale else R.drawable.lw_card,
        )
        val side = dp(R.dimen.lw_face)
        val gap = dp(R.dimen.lw_face_gap)
        val fit = ((size.width - 2 * dp(R.dimen.lw_pad_h) + gap) / (side + gap)).toInt().coerceIn(1, MAX_FACES)
        for (bot in bots.take(fit)) {
            val face = RemoteViews(pkg, R.layout.lw_face)
            val bitmap = LauncherWidgetFaces.load(bot.idleFacePath ?: bot.facePath, (side * density).toInt())
            if (bitmap != null) {
                face.setImageViewBitmap(R.id.lw_face_image, bitmap)
                face.setViewVisibility(R.id.lw_face_image, View.VISIBLE)
                face.setViewVisibility(R.id.lw_face_glyph, View.GONE)
            }
            if (offline) {
                face.setInt(R.id.lw_face_image, "setImageAlpha", DIM_ALPHA)
                face.setInt(R.id.lw_face_glyph, "setImageAlpha", DIM_ALPHA)
            } else if (bot.state == WidgetBotState.NEEDS_YOU || bot.working()) {
                face.setImageViewResource(
                    R.id.lw_face_mark,
                    if (bot.state == WidgetBotState.NEEDS_YOU) R.drawable.lw_mark_waits else R.drawable.lw_mark_works,
                )
                face.setViewVisibility(R.id.lw_face_mark, View.VISIBLE)
            }
            views.addView(R.id.lw_faces, face)
        }
        val waiting = bots.firstOrNull { !offline && it.state == WidgetBotState.NEEDS_YOU }
        val working = bots.filter { !offline && it.working() }
        val line =
            when {
                offline ->
                    listOfNotNull(
                        context.getString(R.string.lw_no_connection),
                        since(data.bots.updatedAtMs).takeIf { size.wide },
                    ).joinToString(" · ")
                waiting != null -> context.getString(R.string.lw_bot_waits, waiting.name)
                working.size == 1 -> context.getString(R.string.lw_bot_works, working.first().name)
                working.size > 1 -> plural(R.plurals.lw_bots_working, working.size)
                bots.isEmpty() -> context.getString(R.string.lw_bots_empty)
                else -> context.getString(R.string.lw_bots_calm)
            }
        views.setTextViewText(R.id.lw_faces_title, line)
        views.setTextColor(R.id.lw_faces_title, color(if (offline) R.color.lw_amber else R.color.lw_ink))
        views.setOnClickPendingIntent(
            android.R.id.background,
            pending(waiting?.let { LauncherWidgetOpen.Payload(it.openPayload) } ?: LauncherWidgetOpen.App),
        )
        return views
    }

    /** Two rows or more: one row per bot with what it does or did. */
    private fun botsBoard(bots: List<WidgetBot>, offline: Boolean): RemoteViews {
        val working = bots.count { !offline && it.working() }
        val waiting = bots.count { !offline && it.state == WidgetBotState.NEEDS_YOU }
        val counts =
            listOfNotNull(
                plural(R.plurals.lw_bots_working, working).takeIf { working > 0 },
                plural(R.plurals.lw_bots_waiting, waiting).takeIf { waiting > 0 },
            ).joinToString(" · ")
        val views =
            board(
                card = if (offline) R.drawable.lw_card_stale else R.drawable.lw_card,
                icon = R.drawable.lw_ic_team,
                gold = false,
                label = context.getString(R.string.lw_bots),
                right =
                    when {
                        offline -> moment(data.bots.updatedAtMs).takeIf { data.bots.updatedAtMs > 0 }
                        size.wide -> counts.takeIf { it.isNotEmpty() }
                        else -> null
                    },
                rightColor = if (offline) R.color.lw_amber else null,
                rightIcon = offline,
            )
        if (bots.isEmpty()) {
            emptyLine(views, R.drawable.lw_ic_team, context.getString(R.string.lw_bots_empty))
        } else {
            val room = bodyHeight()
            val fit = (room / rowHeight()).toInt().coerceIn(0, MAX_ROWS)
            addRows(views, bots.take(fit).map { botRow(it, offline) }, room)
        }
        views.setOnClickPendingIntent(android.R.id.background, pending(LauncherWidgetOpen.App))
        return views
    }

    private fun botRow(bot: WidgetBot, offline: Boolean): RemoteViews {
        val row = RemoteViews(pkg, R.layout.lw_row)
        face(row, R.id.lw_row_face, R.id.lw_row_glyph, bot.idleFacePath ?: bot.facePath, LEAD)
        row.setTextViewText(R.id.lw_row_title, bot.name)
        // What it is about is only said where there is room for it.
        val about = (bot.roomName ?: bot.steps.lastOrNull() ?: bot.line).takeIf { size.wide }
        when (if (offline) WidgetBotState.IDLE else bot.state) {
            WidgetBotState.NEEDS_YOU -> {
                val lead = context.getString(R.string.lw_bot_needs_you)
                val line = SpannableString(listOfNotNull(lead, about).joinToString(" · "))
                line.setSpan(ForegroundColorSpan(color(R.color.lw_gold)), 0, lead.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                row.setTextViewText(R.id.lw_row_sub, line)
            }
            WidgetBotState.WORKING, WidgetBotState.THINKING -> {
                val word = context.getString(if (bot.roomName != null) R.string.lw_responding else R.string.lw_working)
                row.setTextViewText(R.id.lw_row_sub, listOfNotNull(word, about).joinToString(" · "))
                row.setImageViewResource(R.id.lw_row_mark, R.drawable.lw_dot)
                row.setViewVisibility(R.id.lw_row_mark, View.VISIBLE)
                timer(row, R.id.lw_row_timer, bot.sinceMs)
            }
            WidgetBotState.DONE -> {
                row.setTextViewText(R.id.lw_row_sub, about ?: context.getString(R.string.lw_finished))
                row.setImageViewResource(R.id.lw_row_mark, R.drawable.lw_ic_check)
                row.setInt(R.id.lw_row_mark, "setColorFilter", color(R.color.lw_green))
                row.setViewVisibility(R.id.lw_row_mark, View.VISIBLE)
                rowTime(row, bot.sinceMs)
            }
            WidgetBotState.FAILED -> {
                row.setTextViewText(
                    R.id.lw_row_sub,
                    listOfNotNull(context.getString(R.string.lw_failed), about).joinToString(" · "),
                )
                row.setTextColor(R.id.lw_row_sub, color(R.color.lw_red))
                rowTime(row, bot.sinceMs)
            }
            WidgetBotState.IDLE ->
                row.setTextViewText(R.id.lw_row_sub, bot.role ?: context.getString(R.string.lw_bot_free))
        }
        if (offline) dim(row)
        row.setOnClickPendingIntent(R.id.lw_row, pending(LauncherWidgetOpen.Payload(bot.openPayload)))
        return row
    }

    private fun rowTime(row: RemoteViews, atMs: Long) {
        if (atMs <= 0) return
        row.setTextViewText(R.id.lw_row_time, moment(atMs))
        row.setViewVisibility(R.id.lw_row_time, View.VISIBLE)
    }

    /** Last known, not current: everything in the row steps back. */
    private fun dim(row: RemoteViews) {
        row.setTextColor(R.id.lw_row_title, color(R.color.lw_faint))
        row.setTextColor(R.id.lw_row_sub, color(R.color.lw_faint))
        row.setInt(R.id.lw_row_face, "setImageAlpha", DIM_ALPHA)
        row.setInt(R.id.lw_row_glyph, "setImageAlpha", DIM_ALPHA)
        row.setInt(R.id.lw_row_mark, "setImageAlpha", DIM_ALPHA)
    }

    // ---------------------------------------------------------------- Salas

    private fun rooms(): RemoteViews {
        if (!data.bots.present) {
            return unknown(R.drawable.lw_ic_rooms, R.string.lw_rooms, R.string.lw_bots_unknown, R.string.lw_bots_unknown_short)
        }
        val offline = !data.botsOnline
        // Already by relevance: the one that needs you, then the one that works.
        val rooms = data.bots.trusted(data.nowMs).rooms
        return if (size.board) roomsBoard(rooms, offline) else roomsStrip(rooms, offline)
    }

    /**
     * What happens in a room, in a line: who needs you, who answers (and who
     * is next), else the last thing said. True when it is happening now.
     */
    private fun roomLine(room: WidgetRoom, offline: Boolean): Pair<String, Boolean> {
        val asking = room.members.firstOrNull { !offline && it.state == "needs_you" }
        val answering = room.members.firstOrNull { !offline && it.state == "working" }
        val next = room.members.firstOrNull { !offline && it.state == "queued" }
        val message = room.lastMessage
        return when {
            asking != null -> context.getString(R.string.lw_room_needs_you, asking.name) to true
            answering != null ->
                listOfNotNull(
                    context.getString(R.string.lw_room_answers, answering.name),
                    next?.takeIf { size.wide }?.let { context.getString(R.string.lw_room_then, it.name) },
                ).joinToString(" · ") to true
            message != null ->
                (room.lastSpeaker?.let { context.getString(R.string.lw_room_said, it, message) } ?: message) to false
            else -> context.getString(R.string.lw_room_quiet) to false
        }
    }

    /** One row: the live room and who answers. */
    private fun roomsStrip(rooms: List<WidgetRoom>, offline: Boolean): RemoteViews {
        val views = stripViews()
        if (offline) {
            views.setInt(android.R.id.background, "setBackgroundResource", R.drawable.lw_card_stale)
            glyph(views, R.id.lw_lead_glyph, R.drawable.lw_icb, R.drawable.lw_ic_cloud_off, R.color.lw_amber)
        } else {
            glyph(views, R.id.lw_lead_glyph, R.drawable.lw_icb, R.drawable.lw_ic_rooms, R.color.lw_muted)
        }
        val room = rooms.firstOrNull()
        if (room == null) {
            text(views, title = context.getString(R.string.lw_rooms), sub = context.getString(R.string.lw_rooms_empty))
        } else {
            val (line, live) = roomLine(room, offline)
            text(
                views,
                title = room.name,
                sub = if (offline) since(data.bots.updatedAtMs) ?: line else line,
                subColor =
                    when {
                        offline -> R.color.lw_amber
                        live -> R.color.lw_gold
                        else -> null
                    },
            )
        }
        views.setOnClickPendingIntent(
            android.R.id.background,
            pending(room?.let { LauncherWidgetOpen.Payload(it.openPayload) } ?: LauncherWidgetOpen.App),
        )
        return views
    }

    /** Two rows or more: more rooms, each with its members and its last line. */
    private fun roomsBoard(rooms: List<WidgetRoom>, offline: Boolean): RemoteViews {
        val answering = rooms.count { !offline && it.state == WidgetBotState.WORKING }
        val waiting = rooms.count { !offline && it.state == WidgetBotState.NEEDS_YOU }
        val counts =
            listOfNotNull(
                plural(R.plurals.lw_rooms_waiting, waiting).takeIf { waiting > 0 },
                plural(R.plurals.lw_rooms_answering, answering).takeIf { answering > 0 },
            ).joinToString(" · ")
        val views =
            board(
                card = if (offline) R.drawable.lw_card_stale else R.drawable.lw_card,
                icon = R.drawable.lw_ic_rooms,
                gold = false,
                label = context.getString(R.string.lw_rooms),
                right =
                    when {
                        offline -> moment(data.bots.updatedAtMs).takeIf { data.bots.updatedAtMs > 0 }
                        size.wide -> counts.takeIf { it.isNotEmpty() }
                        else -> null
                    },
                rightColor = if (offline) R.color.lw_amber else null,
                rightIcon = offline,
            )
        if (rooms.isEmpty()) {
            emptyLine(views, R.drawable.lw_ic_rooms, context.getString(R.string.lw_rooms_empty))
        } else {
            val room = bodyHeight()
            val fit = (room / rowHeight()).toInt().coerceIn(0, MAX_ROWS)
            addRows(views, rooms.take(fit).map { roomRow(it, offline) }, room)
        }
        views.setOnClickPendingIntent(
            android.R.id.background,
            pending(rooms.firstOrNull()?.let { LauncherWidgetOpen.Payload(it.openPayload) } ?: LauncherWidgetOpen.App),
        )
        return views
    }

    private fun roomRow(room: WidgetRoom, offline: Boolean): RemoteViews {
        val row = RemoteViews(pkg, R.layout.lw_row_room)
        val side = (dp(R.dimen.lw_room_face) * density).toInt()
        val shown = room.members.take(if (size.wide) MAX_ROOM_FACES else MAX_ROOM_FACES - 1)
        shown.forEachIndexed { index, member ->
            val face = RemoteViews(pkg, if (index == 0) R.layout.lw_room_face else R.layout.lw_room_face_next)
            val bitmap = LauncherWidgetFaces.load(member.facePath, side)
            if (bitmap != null) {
                face.setImageViewBitmap(R.id.lw_room_face, bitmap)
            } else {
                face.setInt(R.id.lw_room_face, "setBackgroundResource", R.drawable.lw_okc_chip)
                face.setImageViewResource(R.id.lw_room_face, R.drawable.ic_console_mark)
                val inset = (side * 0.27f).toInt()
                face.setViewPadding(R.id.lw_room_face, inset, inset, inset, inset)
            }
            if (offline) face.setInt(R.id.lw_room_face, "setImageAlpha", DIM_ALPHA)
            row.addView(R.id.lw_room_faces, face)
        }
        // A narrow card keeps the room's name readable: the faces, the name
        // and its line, without "+2" and without the timer beside them.
        val more = room.members.size - shown.size
        if (more > 0 && size.wide) {
            row.setTextViewText(R.id.lw_room_more, "+$more")
            row.setViewVisibility(R.id.lw_room_more, View.VISIBLE)
        }
        row.setTextViewText(R.id.lw_row_title, room.name)
        val (line, live) = roomLine(room, offline)
        row.setTextViewText(R.id.lw_row_sub, line)
        if (live && room.state == WidgetBotState.NEEDS_YOU) {
            row.setTextColor(R.id.lw_row_sub, color(R.color.lw_gold))
        } else if (live) {
            row.setViewVisibility(R.id.lw_row_mark, View.VISIBLE)
            if (size.wide) timer(row, R.id.lw_row_timer, room.sinceMs)
        }
        if (offline) {
            row.setTextColor(R.id.lw_row_title, color(R.color.lw_faint))
            row.setTextColor(R.id.lw_row_sub, color(R.color.lw_faint))
        }
        row.setOnClickPendingIntent(R.id.lw_row, pending(LauncherWidgetOpen.Payload(room.openPayload)))
        return row
    }

    // ---------------------------------------------------------------- Tareas

    private fun tasks(): RemoteViews {
        val kanban = data.tasks
        if (!kanban.present) {
            return unknown(R.drawable.lw_ic_kanban, R.string.lw_tasks, R.string.lw_tasks_unknown, R.string.lw_bots_unknown_short)
        }
        return if (size.board) tasksBoard(kanban) else tasksStrip(kanban)
    }

    /** Where a card stands, in a line, and its colour (null: the usual one). */
    private fun taskLine(task: TaskWidgetTask): Pair<String, Int?> =
        when (task.state) {
            TaskWidgetState.RUNNING ->
                listOfNotNull(task.assignee, context.getString(R.string.lw_task_running)).joinToString(" · ") to R.color.lw_gold
            TaskWidgetState.ATTENTION -> context.getString(R.string.lw_task_attention) to R.color.lw_gold
            TaskWidgetState.PENDING -> context.getString(R.string.lw_task_pending) to null
        }

    private fun taskOpen(task: TaskWidgetTask?): LauncherWidgetOpen =
        task?.openPayload?.let { LauncherWidgetOpen.Payload(it) } ?: LauncherWidgetOpen.App

    /** One row: the card in progress (or the first pending one, and how many more). */
    private fun tasksStrip(kanban: TasksWidgetState): RemoteViews {
        val views = stripViews()
        val stale = kanban.isStale(data.nowMs)
        if (stale) {
            views.setInt(android.R.id.background, "setBackgroundResource", R.drawable.lw_card_stale)
            glyph(views, R.id.lw_lead_glyph, R.drawable.lw_icb, R.drawable.lw_ic_cloud_off, R.color.lw_amber)
        } else {
            glyph(views, R.id.lw_lead_glyph, R.drawable.lw_icb, R.drawable.lw_ic_kanban, R.color.lw_muted)
        }
        // "desde las 8:00" only when the card is tall enough for three lines.
        val note = since(kanban.updatedAtMs).takeIf { stale && size.height >= THREE_LINES_MIN_HEIGHT * fontScale }
        val first = kanban.tasks.firstOrNull()
        if (first == null) {
            text(
                views,
                title = context.getString(R.string.lw_tasks),
                sub = context.getString(R.string.lw_tasks_empty),
                sub2 = note,
                sub2Color = R.color.lw_amber,
            )
        } else {
            val (line, tone) = taskLine(first)
            val more = kanban.open - 1
            text(
                views,
                title = first.title,
                sub =
                    if (first.state == TaskWidgetState.PENDING && more > 0) {
                        plural(R.plurals.lw_task_pending_more, more)
                    } else {
                        line
                    },
                subColor = tone.takeIf { !stale },
                sub2 = note,
                sub2Color = R.color.lw_amber,
            )
        }
        views.setOnClickPendingIntent(android.R.id.background, pending(taskOpen(first)))
        return views
    }

    /** Two rows or more: the cards in progress first, then the pending ones. */
    private fun tasksBoard(kanban: TasksWidgetState): RemoteViews {
        val stale = kanban.isStale(data.nowMs)
        val counts =
            listOfNotNull(
                plural(R.plurals.lw_tasks_running, kanban.running).takeIf { kanban.running > 0 },
                plural(R.plurals.lw_tasks_attention, kanban.attention).takeIf { kanban.attention > 0 },
                plural(R.plurals.lw_tasks_pending, kanban.pending).takeIf { kanban.pending > 0 },
            ).take(2).joinToString(" · ")
        val views =
            board(
                card = if (stale) R.drawable.lw_card_stale else R.drawable.lw_card,
                icon = R.drawable.lw_ic_kanban,
                gold = false,
                label = context.getString(R.string.lw_tasks),
                right =
                    when {
                        stale -> moment(kanban.updatedAtMs).takeIf { kanban.updatedAtMs > 0 }
                        size.wide -> counts.takeIf { it.isNotEmpty() }
                        else -> null
                    },
                rightColor = if (stale) R.color.lw_amber else null,
                rightIcon = stale,
            )
        if (kanban.tasks.isEmpty()) {
            emptyLine(views, R.drawable.lw_ic_kanban, context.getString(R.string.lw_tasks_empty))
        } else {
            val room = bodyHeight()
            val fit = (room / rowHeight()).toInt().coerceIn(0, MAX_ROWS)
            addRows(views, kanban.tasks.take(fit).map { taskRow(it, stale) }, room)
        }
        views.setOnClickPendingIntent(android.R.id.background, pending(taskOpen(kanban.tasks.firstOrNull())))
        return views
    }

    private fun taskRow(task: TaskWidgetTask, stale: Boolean): RemoteViews {
        val row = RemoteViews(pkg, R.layout.lw_row)
        // A mark, not a face: a turning arc while a worker is on it, a ring
        // while it waits.
        row.setViewVisibility(R.id.lw_row_face, View.GONE)
        val live = !stale && task.state != TaskWidgetState.PENDING
        glyph(
            row,
            R.id.lw_row_glyph,
            0,
            if (task.state == TaskWidgetState.RUNNING) R.drawable.lw_ic_spin else R.drawable.lw_ic_ring,
            if (live) R.color.lw_gold else R.color.lw_muted,
        )
        row.setTextViewText(R.id.lw_row_title, task.title)
        val (line, tone) = taskLine(task)
        row.setTextViewText(R.id.lw_row_sub, line)
        if (tone != null && !stale) row.setTextColor(R.id.lw_row_sub, color(tone))
        if (stale) dim(row)
        row.setOnClickPendingIntent(R.id.lw_row, pending(taskOpen(task)))
        return row
    }

    // ---------------------------------------------------------------- Chats

    private fun chats(): RemoteViews {
        val list = data.chats
        if (!list.present) {
            return unknown(R.drawable.lw_ic_history, R.string.lw_chats, R.string.lw_chats_unknown, R.string.lw_bots_unknown_short)
        }
        // What runs or waits right now is only known from a fresh snapshot
        // of the app; without one every conversation is just a conversation.
        val active = if (data.chatOnline && data.chat.listsActivity) data.chat.active else emptyList()
        val rows = list.rows(active)
        return if (size.board) chatsBoard(list, rows) else chatsStrip(list, rows)
    }

    private fun chatOpen(row: ChatWidgetRow?): LauncherWidgetOpen =
        row?.let { LauncherWidgetOpen.Session(data.chats.connectionId, it.chat.id) } ?: LauncherWidgetOpen.App

    /** What a running chat is doing, in a word. */
    private fun phaseWord(activity: HermesWidgetChatActivity): String =
        when (activity.state) {
            HermesWidgetAgentState.THINKING -> context.getString(R.string.lw_thinking)
            HermesWidgetAgentState.STREAMING -> context.getString(R.string.lw_responding)
            else -> activity.phase ?: context.getString(R.string.lw_working)
        }

    /** "Pide permiso" / "Te pregunta". */
    private fun asksWord(activity: HermesWidgetChatActivity): String =
        context.getString(
            when {
                activity.need == null -> R.string.lw_needs_you_word
                activity.need.question -> R.string.lw_asks_you_word
                else -> R.string.lw_asks_permission_word
            },
        )

    /** One row: the conversation that moves (it waits for you, or it runs), else the last one. */
    private fun chatsStrip(list: ChatsWidgetState, rows: List<ChatWidgetRow>): RemoteViews {
        val views = stripViews()
        val stale = list.isStale(data.nowMs)
        if (stale) {
            views.setInt(android.R.id.background, "setBackgroundResource", R.drawable.lw_card_stale)
            glyph(views, R.id.lw_lead_glyph, R.drawable.lw_icb, R.drawable.lw_ic_cloud_off, R.color.lw_amber)
        } else {
            glyph(views, R.id.lw_lead_glyph, R.drawable.lw_icb, R.drawable.lw_ic_history, R.color.lw_muted)
        }
        val note = since(list.updatedAtMs).takeIf { stale && size.height >= THREE_LINES_MIN_HEIGHT * fontScale }
        val row = rows.firstOrNull()
        val activity = row?.activity
        when {
            row == null ->
                text(
                    views,
                    title = context.getString(R.string.lw_chats),
                    sub = context.getString(R.string.lw_chats_empty),
                    sub2 = note,
                    sub2Color = R.color.lw_amber,
                )
            activity != null && activity.needsYou ->
                text(views, title = row.chat.title, sub = asksWord(activity), subColor = R.color.lw_gold)
            activity != null -> {
                val timed = activity.startedAtMs > 0
                text(
                    views,
                    title = row.chat.title,
                    // Two cells: the short word, so the timer fits beside it.
                    sub =
                        context.getString(if (size.wide) R.string.lw_chat_working else R.string.lw_working) +
                            if (timed) " · " else "",
                    subColor = R.color.lw_gold,
                )
                timer(views, R.id.lw_sub_timer, activity.startedAtMs)
            }
            else ->
                text(
                    views,
                    title = row.chat.title,
                    sub = row.chat.atMs.takeIf { it > 0 }?.let { moment(it) } ?: row.chat.line,
                    sub2 = note,
                    sub2Color = R.color.lw_amber,
                )
        }
        views.setOnClickPendingIntent(android.R.id.background, pending(chatOpen(row)))
        return views
    }

    /** Two rows or more: the conversations with their state, as many as fit. */
    private fun chatsBoard(list: ChatsWidgetState, rows: List<ChatWidgetRow>): RemoteViews {
        val stale = list.isStale(data.nowMs)
        val views =
            board(
                card = if (stale) R.drawable.lw_card_stale else R.drawable.lw_card,
                icon = R.drawable.lw_ic_history,
                gold = false,
                label = context.getString(R.string.lw_chats),
                right = moment(list.updatedAtMs).takeIf { stale && list.updatedAtMs > 0 },
                rightColor = R.color.lw_amber,
                rightIcon = stale,
            )
        if (rows.isEmpty()) {
            emptyLine(views, R.drawable.lw_ic_history, context.getString(R.string.lw_chats_empty))
        } else {
            val room = bodyHeight()
            val fit = (room / rowHeight()).toInt().coerceIn(0, MAX_ROWS)
            addRows(views, rows.take(fit).map { chatRow(it, stale) }, room)
        }
        views.setOnClickPendingIntent(android.R.id.background, pending(chatOpen(rows.firstOrNull())))
        return views
    }

    private fun chatRow(item: ChatWidgetRow, stale: Boolean): RemoteViews {
        val row = RemoteViews(pkg, R.layout.lw_row_chat)
        row.setTextViewText(R.id.lw_row_title, item.chat.title)
        val activity = item.activity
        when {
            activity != null && activity.needsYou -> {
                // What is asked is only said where there is room for it.
                val what = activity.need?.text?.takeIf { size.wide }
                row.setTextViewText(R.id.lw_row_sub, listOfNotNull(asksWord(activity), what).joinToString(" · "))
                row.setViewVisibility(R.id.lw_row_mark, View.VISIBLE)
                row.setViewVisibility(R.id.lw_row_view, View.VISIBLE)
            }
            activity != null -> {
                row.setTextViewText(
                    R.id.lw_row_sub,
                    listOfNotNull(context.getString(R.string.lw_chat_working), phaseWord(activity)).joinToString(" · "),
                )
                row.setViewVisibility(R.id.lw_row_mark, View.VISIBLE)
                timer(row, R.id.lw_row_timer, activity.startedAtMs)
            }
            else -> {
                val line = item.chat.line
                if (line != null) {
                    row.setTextViewText(R.id.lw_row_sub, context.getString(R.string.lw_chat_finished, line))
                    row.setImageViewResource(R.id.lw_row_mark, R.drawable.lw_ic_check)
                    row.setInt(R.id.lw_row_mark, "setColorFilter", color(R.color.lw_green))
                    row.setViewVisibility(R.id.lw_row_mark, View.VISIBLE)
                } else {
                    row.setTextViewText(R.id.lw_row_sub, context.getString(R.string.lw_finished))
                }
                if (item.chat.atMs > 0) {
                    row.setTextViewText(R.id.lw_row_time, moment(item.chat.atMs))
                    row.setViewVisibility(R.id.lw_row_time, View.VISIBLE)
                }
            }
        }
        if (stale) {
            row.setTextColor(R.id.lw_row_title, color(R.color.lw_faint))
            row.setTextColor(R.id.lw_row_sub, color(R.color.lw_faint))
            row.setInt(R.id.lw_row_mark, "setImageAlpha", DIM_ALPHA)
        }
        row.setOnClickPendingIntent(R.id.lw_row, pending(chatOpen(item)))
        return row
    }

    // ---------------------------------------------------------------- shared pieces

    /** A board: the card, its head, an empty body. */
    private fun board(
        card: Int,
        icon: Int,
        gold: Boolean,
        label: String,
        right: String?,
        rightColor: Int?,
        rightIcon: Boolean,
    ): RemoteViews {
        val views = RemoteViews(pkg, R.layout.lw_board)
        // The launcher draws this onto the body it already holds: without
        // this, every update would add its rows under the previous ones.
        views.removeAllViews(R.id.lw_body)
        views.setInt(android.R.id.background, "setBackgroundResource", card)
        glyph(
            views,
            R.id.lw_head_chip,
            if (gold) R.drawable.lw_chip_gold else R.drawable.lw_chip,
            icon,
            if (gold) R.color.lw_gold else R.color.lw_muted,
        )
        views.setTextViewText(R.id.lw_head_label, label)
        views.setTextViewText(R.id.lw_head_right, right ?: "")
        views.setViewVisibility(R.id.lw_head_right, if (right == null) View.GONE else View.VISIBLE)
        views.setTextColor(R.id.lw_head_right, color(rightColor ?: R.color.lw_faint))
        views.setViewVisibility(R.id.lw_head_right_icon, if (rightIcon && right != null) View.VISIBLE else View.GONE)
        return views
    }

    /** Height left under the head, in dp. */
    private fun bodyHeight(): Float =
        size.height - dp(R.dimen.lw_pad_top) - dp(R.dimen.lw_pad_bottom) -
            dp(R.dimen.lw_head_height) - dp(R.dimen.lw_head_gap)

    /** A row is a tap target (48 dp) and holds two lines of text at the current font size. */
    private fun rowHeight(): Float = maxOf(dp(R.dimen.lw_row_min), TEXT_BLOCK * fontScale + 8f)

    /**
     * Adds [rows] with a hairline between them. Rows share the height in equal
     * parts; when there are fewer rows than fit, empty parts keep them at
     * their natural height instead of stretching them over the whole card.
     */
    private fun addRows(views: RemoteViews, rows: List<RemoteViews>, room: Float) {
        rows.forEachIndexed { index, row ->
            if (index > 0) views.addView(R.id.lw_body, RemoteViews(pkg, R.layout.lw_line))
            views.addView(R.id.lw_body, row)
        }
        val parts = (room / rowHeight()).toInt()
        repeat((parts - rows.size).coerceIn(0, MAX_FILL)) {
            views.addView(R.id.lw_body, RemoteViews(pkg, R.layout.lw_fill))
        }
    }

    /**
     * A one-row card in its resting state. A launcher draws a new update onto
     * the views it already inflated (it re-applies it when the layout is the
     * same), so whatever a previous drawing changed and this one does not
     * mention would stay: every property a branch below may change is set
     * here first, and the branch only overrides what it needs.
     */
    private fun stripViews(): RemoteViews {
        val views = RemoteViews(pkg, R.layout.lw_strip)
        views.setInt(android.R.id.background, "setBackgroundResource", R.drawable.lw_card)
        glyph(views, R.id.lw_lead_glyph, R.drawable.lw_icb, R.drawable.lw_ic_clock, R.color.lw_muted)
        val inset = (LEAD_GLYPH_INSET * density).toInt()
        views.setViewPadding(R.id.lw_lead_glyph, inset, inset, inset, inset)
        views.setViewVisibility(R.id.lw_lead_glyph, View.VISIBLE)
        views.setViewVisibility(R.id.lw_lead_face, View.GONE)
        views.setViewVisibility(R.id.lw_sub_row, View.VISIBLE)
        views.setTextColor(R.id.lw_sub, color(R.color.lw_muted))
        views.setViewVisibility(R.id.lw_sub_timer, View.GONE)
        views.setViewVisibility(R.id.lw_sub2, View.GONE)
        views.setTextColor(R.id.lw_sub2, color(R.color.lw_muted))
        views.setViewVisibility(R.id.lw_end_timer, View.GONE)
        views.setViewVisibility(R.id.lw_end_time, View.GONE)
        return views
    }

    /** The two (or three) lines of a strip. */
    private fun text(
        views: RemoteViews,
        title: String,
        sub: String?,
        subColor: Int? = null,
        sub2: String? = null,
        sub2Color: Int? = null,
    ) {
        views.setTextViewText(R.id.lw_title, title)
        views.setTextViewText(R.id.lw_sub, sub ?: "")
        views.setViewVisibility(R.id.lw_sub_row, if (sub.isNullOrEmpty()) View.GONE else View.VISIBLE)
        views.setTextColor(R.id.lw_sub, color(subColor ?: R.color.lw_muted))
        views.setTextViewText(R.id.lw_sub2, sub2 ?: "")
        views.setViewVisibility(R.id.lw_sub2, if (sub2.isNullOrEmpty()) View.GONE else View.VISIBLE)
        views.setTextColor(R.id.lw_sub2, color(sub2Color ?: R.color.lw_muted))
    }

    /** An icon on a tinted chip or disc. A null [tint] keeps the icon's own colours. */
    private fun glyph(views: RemoteViews, id: Int, background: Int, icon: Int, tint: Int?) {
        views.setInt(id, "setBackgroundResource", background)
        views.setImageViewResource(id, icon)
        // A colour filter replaces the tint the layout gave its sample icon;
        // a transparent one leaves the icon as drawn.
        views.setInt(id, "setColorFilter", if (tint == null) 0 else color(tint))
    }

    /** A bot's face in [faceId]; the Console mark on a disc in [glyphId] while there is none. */
    private fun face(views: RemoteViews, faceId: Int, glyphId: Int, path: String?, boxDp: Float) {
        val bitmap = LauncherWidgetFaces.load(path, (boxDp * density).toInt())
        if (bitmap != null) {
            views.setImageViewBitmap(faceId, bitmap)
            views.setViewVisibility(faceId, View.VISIBLE)
            views.setViewVisibility(glyphId, View.GONE)
        } else {
            glyph(views, glyphId, R.drawable.lw_okc_chip, R.drawable.ic_console_mark, null)
            val inset = (boxDp * 0.27f * density).toInt()
            views.setViewPadding(glyphId, inset, inset, inset, inset)
            views.setViewVisibility(glyphId, View.VISIBLE)
            views.setViewVisibility(faceId, View.GONE)
        }
    }

    /** A running timer the launcher itself ticks: no redraw per second. */
    private fun timer(views: RemoteViews, id: Int, sinceMs: Long) {
        val elapsed = data.nowMs - sinceMs
        if (sinceMs <= 0 || elapsed < 0 || elapsed > MAX_TIMER_MS) {
            views.setViewVisibility(id, View.GONE)
            return
        }
        views.setChronometer(id, SystemClock.elapsedRealtime() - elapsed, null, true)
        views.setViewVisibility(id, View.VISIBLE)
    }

    private fun pending(open: LauncherWidgetOpen): PendingIntent {
        val intent: Intent
        val key: String
        when (open) {
            is LauncherWidgetOpen.App -> {
                intent = NewSessionLaunchContract.openAppIntent(context)
                key = "app"
            }
            is LauncherWidgetOpen.Setup -> {
                intent = NewSessionLaunchContract.openSetupIntent(context)
                key = "setup"
            }
            is LauncherWidgetOpen.Session -> {
                intent =
                    try {
                        NewSessionLaunchContract.openSessionIntent(context, open.instanceId, open.sessionId)
                    } catch (_: IllegalArgumentException) {
                        NewSessionLaunchContract.openAppIntent(context)
                    }
                key = "session/${open.sessionId}"
            }
            is LauncherWidgetOpen.Payload -> {
                intent =
                    HermesRichNotifications.openActivityIntent(context, open.payload)
                        ?: NewSessionLaunchContract.openAppIntent(context)
                key = "payload/${open.payload}"
            }
            is LauncherWidgetOpen.NewChat -> {
                intent =
                    NewSessionLaunchContract.newIntent(
                        context,
                        NewSessionLaunchContract.SOURCE_WIDGET,
                        open.target,
                        requestedInstanceId = open.instanceId,
                    )
                key = "new/${open.target.wireValue}"
            }
        }
        return PendingIntent.getActivity(
            context,
            key.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun answer(actionId: String, payload: String): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            0,
            HermesRichNotifications.actionBroadcast(context, actionId, payload, 0, null, "widget"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun color(id: Int): Int = context.getColor(id)

    private fun dp(id: Int): Float = context.resources.getDimension(id) / density

    private fun plural(id: Int, count: Int): String = context.resources.getQuantityString(id, count, count)

    /** A time of day in the device's own 12/24 h format. */
    private fun clock(atMs: Long): String =
        android.text.format.DateFormat.getTimeFormat(context).format(Date(atMs))

    /**
     * A past moment, short: its time when it was today, else its day ("ayer",
     * "vie", "25 sept"). A bare "18:32" must never be read as today's.
     */
    private fun moment(atMs: Long): String =
        if (LauncherWidgetDays.offset(atMs, data.nowMs) >= 0) {
            clock(atMs)
        } else {
            LauncherWidgetDays.day(context, atMs, data.nowMs)
        }

    /** "desde las 6:05" ("desde la 1:05"); from another day, "desde ayer", "desde el vie". */
    private fun since(atMs: Long): String? {
        if (atMs <= 0) return null
        val days = LauncherWidgetDays.offset(atMs, data.nowMs)
        if (days == -1) return context.getString(R.string.lw_since_yesterday)
        if (days < -1) {
            return context.getString(R.string.lw_since_day, LauncherWidgetDays.day(context, atMs, data.nowMs))
        }
        val time = clock(atMs)
        val one = time.startsWith("1:") || time.startsWith("01:")
        return context.getString(if (one) R.string.lw_since_one else R.string.lw_since, time)
    }

    /** Width of [label] in dp at the widget's medium weight. */
    private fun textWidth(label: String, sizeDimen: Int): Float {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        paint.textSize = context.resources.getDimension(sizeDimen)
        return paint.measureText(label) / density + LABEL_SLACK
    }

    private companion object {
        /** Side of the lead box of a strip or a row, in dp (`lw_lead`). */
        const val LEAD = 34f

        /** Padding of a label in the narrow card's pills (`lw_buttons_even`), in dp. */
        const val ANSWER_PAD = 4f

        /** Inset of the icon in the lead of a strip (`lw_strip`), in dp. */
        const val LEAD_GLYPH_INSET = 8f

        /** Two lines of text, in sp (`lw_line_title` + `lw_line_sub`). */
        const val TEXT_BLOCK = 36f

        /** The ask block of a board: 3 margin + 38 block + 1, in dp at font scale 1. */
        const val ASK_HEIGHT = 42f

        /** The one-row ask needs 8 + 26 + 44 dp to keep its buttons whole. */
        const val ASK_STRIP_MIN_HEIGHT = 78f

        /** Paddings (9 + 10), head (22 + 3), ask (42) and buttons (48) of a board. */
        const val NEED_BOARD_MIN_HEIGHT = 134f

        const val MAX_ROWS = 8

        /** Faces in the one-row Bots card, and member faces of a room row. */
        const val MAX_FACES = 8
        const val MAX_ROOM_FACES = 3

        /** Three lines of text (19 + 17 + 17 sp) with a little air, in dp at font scale 1. */
        const val THREE_LINES_MIN_HEIGHT = 60f

        /** In place of a time, for a job with no next run. */
        const val NO_TIME = "—"
        const val MAX_FILL = 12
        const val DIM_ALPHA = 115
        const val MAX_TIMER_MS = 24 * 60 * 60 * 1000L

        /** Room for the launcher's font being a little wider than ours. */
        const val LABEL_SLACK = 4f
    }
}

/** Calendar words for a moment, in the device's time zone and language. */
internal object LauncherWidgetDays {
    private fun startOfDay(atMs: Long): Calendar =
        Calendar.getInstance().apply {
            timeInMillis = atMs
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }

    /** Whole days from today to [atMs]: 0 today, 1 tomorrow, -1 yesterday. */
    fun offset(atMs: Long, nowMs: Long): Int {
        val then = startOfDay(atMs)
        val today = startOfDay(nowMs)
        // Noon to noon, so a daylight-saving day of 23 or 25 hours still counts as one.
        val diff = (then.timeInMillis + HALF_DAY_MS) - (today.timeInMillis + HALF_DAY_MS)
        return Math.round(diff / DAY_MS.toDouble()).toInt()
    }

    /** "hoy", "mañana", "ayer", a weekday within the week, else "25 sept". */
    fun day(context: Context, atMs: Long, nowMs: Long): String {
        val locale = context.resources.configuration.locales[0]
        return when (val days = offset(atMs, nowMs)) {
            0 -> context.getString(R.string.lw_today)
            1 -> context.getString(R.string.lw_tomorrow)
            -1 -> context.getString(R.string.lw_yesterday)
            else ->
                SimpleDateFormat(if (days in -6..6) "EEE" else "d MMM", locale)
                    .format(Date(atMs))
                    .replace(".", "")
        }
    }

    /** The first instant of tomorrow: "hoy" turns into "ayer" there. */
    fun nextMidnight(nowMs: Long): Long = startOfDay(nowMs).apply { add(Calendar.DAY_OF_YEAR, 1) }.timeInMillis

    private const val DAY_MS = 24 * 60 * 60 * 1000L
    private const val HALF_DAY_MS = DAY_MS / 2
}

/** Bot faces are files Dart already drew; they are decoded near their display size. */
internal object LauncherWidgetFaces {
    private val cache =
        object : LruCache<String, Bitmap>(2 * 1024 * 1024) {
            override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
        }

    fun load(path: String?, targetPx: Int): Bitmap? {
        if (path.isNullOrEmpty() || targetPx <= 0) return null
        val key = "$path@$targetPx"
        cache.get(key)?.let { return it }
        return try {
            val file = File(path)
            if (!file.isFile || file.length() > 1_000_000) return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= targetPx) sample *= 2
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            BitmapFactory.decodeFile(path, options)?.also { cache.put(key, it) }
        } catch (_: Exception) {
            null
        }
    }
}
