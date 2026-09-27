package com.hermesagent.hermes_android

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionSendBroadcast
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import es.antonborri.home_widget.HomeWidgetGlanceState
import es.antonborri.home_widget.HomeWidgetGlanceStateDefinition
import es.antonborri.home_widget.HomeWidgetGlanceWidgetReceiver
import es.antonborri.home_widget.HomeWidgetPlugin
import java.io.File

/**
 * Bot Mode widget family (spec 070 Phase 7): Bots, Needs you, Room, Quick
 * ask and Status. Every widget reads the single snapshot the background
 * listener publishes; widgets never poll. Three of the five reuse the legacy
 * receiver class names (same cell span), so widgets already placed on a home
 * screen migrate in place instead of disappearing or crashing:
 *  - NewSessionWidgetProvider (old 4x2 dashboard) → Bots (now 2x2..4x4)
 *  - HermesControlWidgetProvider (old 4x1 controls) → Quick ask
 *  - HermesCompactWidgetProvider (old 2x1 compact) → Status
 * Needs you and Room are new receivers.
 */
enum class BotModeWidgetKind { BOTS, NEEDS_YOU, ROOM, QUICK_ASK, STATUS }

class HermesBotModeWidget(private val kind: BotModeWidgetKind) : GlanceAppWidget() {
    override val stateDefinition = HomeWidgetGlanceStateDefinition()

    override val sizeMode: SizeMode =
        SizeMode.Responsive(
            when (kind) {
                BotModeWidgetKind.BOTS -> setOf(SMALL_SQUARE, WIDE, LARGE)
                BotModeWidgetKind.NEEDS_YOU -> setOf(SMALL_SQUARE, WIDE, LARGE)
                BotModeWidgetKind.ROOM -> setOf(SMALL_SQUARE, WIDE, LARGE)
                BotModeWidgetKind.QUICK_ASK -> setOf(STRIP_SMALL, STRIP_WIDE, WIDE)
                BotModeWidgetKind.STATUS -> setOf(STRIP_SMALL, STRIP_WIDE, SMALL_SQUARE)
            },
        )

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val published = BotModeWidgetState.from(HomeWidgetPlugin.getData(context))
        BotModeWidgetExpiryScheduler.replace(context, published)
        val onHomeScreen = isHomeScreenHost(context, id)
        provideContent {
            val prefs = currentState<HomeWidgetGlanceState>().preferences
            val now = System.currentTimeMillis()
            val trusted = BotModeWidgetState.from(prefs).trusted(now)
            val state = if (onHomeScreen) trusted else trusted.redactedForKeyguard()
            val legacy = HermesWidgetState.from(prefs)
            BotModeWidgetContent(context, kind, state, legacy, now)
        }
    }

    /** Unknown host = not the home screen (fail closed). */
    private fun isHomeScreenHost(context: Context, id: GlanceId): Boolean =
        try {
            val appWidgetId = GlanceAppWidgetManager(context).getAppWidgetId(id)
            val category =
                AppWidgetManager.getInstance(context)
                    .getAppWidgetOptions(appWidgetId)
                    .getInt(AppWidgetManager.OPTION_APPWIDGET_HOST_CATEGORY, -1)
            category == AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN
        } catch (_: Exception) {
            false
        }

    companion object {
        val STRIP_SMALL = DpSize(110.dp, 40.dp)
        val STRIP_WIDE = DpSize(250.dp, 40.dp)
        val SMALL_SQUARE = DpSize(110.dp, 110.dp)
        val WIDE = DpSize(250.dp, 110.dp)
        val LARGE = DpSize(250.dp, 250.dp)
    }
}

class HermesNeedsYouWidgetProvider : HomeWidgetGlanceWidgetReceiver<HermesBotModeWidget>() {
    override val glanceAppWidget = HermesBotModeWidget(BotModeWidgetKind.NEEDS_YOU)
}

class HermesRoomWidgetProvider : HomeWidgetGlanceWidgetReceiver<HermesBotModeWidget>() {
    override val glanceAppWidget = HermesBotModeWidget(BotModeWidgetKind.ROOM)
}

internal data class BotWidgetPalette(
    val background: ColorProvider,
    val surface: ColorProvider,
    val text: ColorProvider,
    val secondary: ColorProvider,
    val accent: ColorProvider,
    val onAccent: ColorProvider,
    val success: ColorProvider,
    val warning: ColorProvider,
    val error: ColorProvider,
)

private fun botPalette(theme: HermesWidgetTheme): BotWidgetPalette =
    when (theme) {
        HermesWidgetTheme.LIGHT ->
            BotWidgetPalette(
                background = ColorProvider(Color(0xFFF7F4EC)),
                surface = ColorProvider(Color(0xFFECE7DC)),
                text = ColorProvider(Color(0xFF1E1B16)),
                secondary = ColorProvider(Color(0xFF6E675C)),
                accent = ColorProvider(Color(0xFFB4610A)),
                onAccent = ColorProvider(Color.White),
                success = ColorProvider(Color(0xFF327A55)),
                warning = ColorProvider(Color(0xFF9B6500)),
                error = ColorProvider(Color(0xFFB3261E)),
            )
        HermesWidgetTheme.OLED -> darkBotPalette(Color.Black)
        HermesWidgetTheme.DARK -> darkBotPalette(Color(0xFF09090C))
    }

private fun darkBotPalette(background: Color) =
    BotWidgetPalette(
        background = ColorProvider(background),
        surface = ColorProvider(Color(0xFF1A191D)),
        text = ColorProvider(Color(0xFFF3F0E8)),
        secondary = ColorProvider(Color(0xFFB9B4A9)),
        accent = ColorProvider(Color(0xFFE8821C)),
        onAccent = ColorProvider(Color(0xFF201000)),
        success = ColorProvider(Color(0xFF78C99B)),
        warning = ColorProvider(Color(0xFFFFC66A)),
        error = ColorProvider(Color(0xFFFF8A80)),
    )

/** Content-addressed face files never change, so the cache key is the path. */
private object FaceBitmaps {
    private val cache = object : LruCache<String, Bitmap>(4 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    fun load(path: String?): Bitmap? {
        if (path.isNullOrEmpty()) return null
        cache.get(path)?.let { return it }
        return try {
            val file = File(path)
            if (!file.isFile || file.length() > 1_000_000) return null
            BitmapFactory.decodeFile(path)?.also { cache.put(path, it) }
        } catch (_: Exception) {
            null
        }
    }
}

private fun openAction(context: Context, payload: String?): Action {
    val intent =
        payload?.let { HermesRichNotifications.openActivityIntent(context, it) }
            ?: NewSessionLaunchContract.openAppIntent(context)
    return actionStartActivity(intent)
}

private fun broadcastAction(context: Context, actionId: String, payload: String): Action =
    actionSendBroadcast(
        HermesRichNotifications.actionBroadcast(context, actionId, payload, 0, null, "widget")
            .setComponent(ComponentName(context, HermesNotificationActionReceiver::class.java)),
    )

@Composable
private fun BotModeWidgetContent(
    context: Context,
    kind: BotModeWidgetKind,
    state: BotModeWidgetState,
    legacy: HermesWidgetState,
    nowMs: Long,
) {
    val colors = botPalette(legacy.theme)
    val size = LocalSize.current
    val compact = size.height < 90.dp
    val root =
        GlanceModifier
            .fillMaxSize()
            .appWidgetBackground()
            .background(colors.background)
            .cornerRadius(android.R.dimen.system_app_widget_background_radius)
            .padding(horizontal = if (compact) 10.dp else 12.dp, vertical = if (compact) 6.dp else 12.dp)
    Box(modifier = root, contentAlignment = Alignment.TopStart) {
        if (!state.present && kind != BotModeWidgetKind.STATUS && kind != BotModeWidgetKind.QUICK_ASK) {
            EmptyState(context, colors, context.getString(R.string.botw_empty_setup), openAction(context, null))
        } else {
            when (kind) {
                BotModeWidgetKind.BOTS -> BotsContent(context, state, colors, size.width, size.height)
                BotModeWidgetKind.NEEDS_YOU -> NeedsYouContent(context, state, colors, size.height)
                BotModeWidgetKind.ROOM -> RoomContent(context, state, colors, size.height)
                BotModeWidgetKind.QUICK_ASK -> QuickAskContent(context, state, legacy, colors, size.width)
                BotModeWidgetKind.STATUS -> StatusContent(context, state, legacy, colors, nowMs)
            }
        }
    }
}

@Composable
private fun EmptyState(context: Context, colors: BotWidgetPalette, text: String, action: Action) {
    Column(
        modifier = GlanceModifier.fillMaxSize().clickable(action),
        verticalAlignment = Alignment.Vertical.CenterVertically,
        horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
    ) {
        Image(
            provider = ImageProvider(R.drawable.ic_stat_hermes),
            contentDescription = null,
            modifier = GlanceModifier.size(22.dp),
            colorFilter = ColorFilter.tint(colors.accent),
        )
        Spacer(GlanceModifier.height(6.dp))
        Text(
            text,
            maxLines = 2,
            style = TextStyle(color = colors.secondary, fontSize = 12.sp, textAlign = TextAlign.Center),
        )
    }
}

@Composable
private fun Header(title: String, colors: BotWidgetPalette, badge: Int = 0, trailing: String? = null) {
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Vertical.CenterVertically) {
        Text(
            title,
            maxLines = 1,
            style = TextStyle(color = colors.text, fontSize = 14.sp, fontWeight = FontWeight.Bold),
        )
        Spacer(GlanceModifier.defaultWeight())
        if (trailing != null) {
            Text(trailing, maxLines = 1, style = TextStyle(color = colors.secondary, fontSize = 11.sp))
        }
        if (badge > 0) {
            Spacer(GlanceModifier.width(6.dp))
            Box(
                modifier = GlanceModifier.height(20.dp).background(colors.warning).cornerRadius(10.dp).padding(horizontal = 7.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    badge.toString(),
                    style = TextStyle(color = ColorProvider(Color(0xFF201000)), fontSize = 11.sp, fontWeight = FontWeight.Bold),
                )
            }
        }
    }
}

@Composable
private fun Face(path: String?, sizeDp: Dp, colors: BotWidgetPalette, description: String?) {
    val bitmap = FaceBitmaps.load(path)
    if (bitmap != null) {
        Image(
            provider = ImageProvider(bitmap),
            contentDescription = description,
            modifier = GlanceModifier.size(sizeDp).cornerRadius(sizeDp / 2),
        )
    } else {
        Box(
            modifier = GlanceModifier.size(sizeDp).background(colors.surface).cornerRadius(sizeDp / 2),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                description?.take(1)?.uppercase() ?: "·",
                style = TextStyle(color = colors.accent, fontSize = (sizeDp.value * 0.42f).sp, fontWeight = FontWeight.Bold),
            )
        }
    }
}

private fun stateColor(state: WidgetBotState, colors: BotWidgetPalette): ColorProvider =
    when (state) {
        WidgetBotState.WORKING -> colors.accent
        WidgetBotState.THINKING -> colors.accent
        WidgetBotState.NEEDS_YOU -> colors.warning
        WidgetBotState.IDLE -> colors.secondary
    }

@Composable
private fun BotsContent(context: Context, state: BotModeWidgetState, colors: BotWidgetPalette, width: Dp, height: Dp) {
    val columns = if (width >= 240.dp) 4 else 2
    val rows = when {
        height >= 230.dp -> 3
        height >= 150.dp || columns == 2 -> 2
        else -> 1
    }
    val face = if (columns == 2 && height < 150.dp) 30.dp else 40.dp
    val bots = state.bots.take(columns * rows)
    Column(modifier = GlanceModifier.fillMaxSize()) {
        Header(
            context.getString(R.string.botw_bots_title),
            colors,
            badge = state.needsYouCount,
            trailing = if (state.workingCount > 0 && columns > 2) {
                context.getString(R.string.botw_working_count, state.workingCount)
            } else {
                null
            },
        )
        Spacer(GlanceModifier.height(6.dp))
        if (bots.isEmpty()) {
            EmptyState(context, colors, context.getString(R.string.botw_no_bots), openAction(context, null))
            return@Column
        }
        for (row in bots.chunked(columns)) {
            Row(modifier = GlanceModifier.fillMaxWidth().padding(bottom = 4.dp)) {
                for (bot in row) {
                    Column(
                        modifier = GlanceModifier.defaultWeight().clickable(openAction(context, bot.openPayload)),
                        horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
                    ) {
                        Face(bot.facePath, face, colors, bot.name)
                        Text(
                            bot.name,
                            maxLines = 1,
                            style = TextStyle(
                                color = if (bot.state == WidgetBotState.IDLE) colors.secondary else stateColor(bot.state, colors),
                                fontSize = 10.sp,
                                textAlign = TextAlign.Center,
                            ),
                        )
                    }
                }
                repeat(columns - row.size) { Spacer(GlanceModifier.defaultWeight()) }
            }
        }
        val working = state.bots.firstOrNull { it.state == WidgetBotState.WORKING || it.state == WidgetBotState.THINKING }
        if (working != null && (rows > 1 || columns > 2)) {
            Spacer(GlanceModifier.defaultWeight())
            Text(
                "${working.name} · ${working.line ?: context.getString(R.string.botw_working)}",
                maxLines = 1,
                style = TextStyle(color = colors.accent, fontSize = 11.sp),
                modifier = GlanceModifier.clickable(openAction(context, working.openPayload)),
            )
        }
    }
}

@Composable
private fun Chip(label: String, background: ColorProvider, foreground: ColorProvider, action: Action, modifier: GlanceModifier = GlanceModifier) {
    Box(
        modifier = modifier.height(32.dp).background(background).cornerRadius(16.dp).clickable(action).padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            maxLines = 1,
            style = TextStyle(color = foreground, fontSize = 12.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center),
        )
    }
}

@Composable
private fun NeedsYouContent(context: Context, state: BotModeWidgetState, colors: BotWidgetPalette, height: Dp) {
    Column(modifier = GlanceModifier.fillMaxSize()) {
        Header(context.getString(R.string.botw_needs_you_title), colors, badge = state.needsYouCount)
        Spacer(GlanceModifier.height(6.dp))
        if (state.approvals.isEmpty()) {
            Column(
                modifier = GlanceModifier.fillMaxSize().clickable(openAction(context, null)),
                verticalAlignment = Alignment.Vertical.CenterVertically,
                horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
            ) {
                Text("✓", style = TextStyle(color = colors.success, fontSize = 22.sp, fontWeight = FontWeight.Bold))
                Text(context.getString(R.string.botw_all_clear), style = TextStyle(color = colors.secondary, fontSize = 12.sp))
            }
            return@Column
        }
        val max = if (height >= 230.dp) 3 else if (height >= 150.dp) 2 else 1
        for (approval in state.approvals.take(max)) {
            Column(
                modifier = GlanceModifier.fillMaxWidth().background(colors.surface).cornerRadius(14.dp).padding(8.dp),
            ) {
                Row(
                    modifier = GlanceModifier.fillMaxWidth().clickable(openAction(context, approval.openPayload)),
                    verticalAlignment = Alignment.Vertical.CenterVertically,
                ) {
                    Face(approval.facePath, 26.dp, colors, approval.title)
                    Spacer(GlanceModifier.width(8.dp))
                    Column(modifier = GlanceModifier.defaultWeight()) {
                        Text(approval.title, maxLines = 1, style = TextStyle(color = colors.text, fontSize = 12.sp, fontWeight = FontWeight.Medium))
                        if (approval.text.isNotEmpty()) {
                            Text(approval.text, maxLines = 1, style = TextStyle(color = colors.secondary, fontSize = 11.sp))
                        }
                    }
                }
                Spacer(GlanceModifier.height(6.dp))
                Row(modifier = GlanceModifier.fillMaxWidth()) {
                    if (approval.canApprove) {
                        Chip(
                            context.getString(R.string.botw_approve),
                            colors.accent,
                            colors.onAccent,
                            broadcastAction(context, "approve", approval.actionPayload),
                            GlanceModifier.defaultWeight(),
                        )
                        Spacer(GlanceModifier.width(6.dp))
                        Chip(
                            context.getString(R.string.botw_deny),
                            colors.background,
                            colors.text,
                            broadcastAction(context, "deny", approval.actionPayload),
                            GlanceModifier.defaultWeight(),
                        )
                    } else {
                        Chip(
                            context.getString(R.string.botw_open),
                            colors.accent,
                            colors.onAccent,
                            openAction(context, approval.openPayload),
                            GlanceModifier.defaultWeight(),
                        )
                    }
                }
            }
            Spacer(GlanceModifier.height(6.dp))
        }
    }
}

private fun memberStateLabel(context: Context, state: String): String =
    when (state) {
        "working" -> context.getString(R.string.botw_state_working)
        "done" -> context.getString(R.string.botw_state_replied)
        "needs_you" -> context.getString(R.string.botw_state_needs_you)
        "queued" -> context.getString(R.string.botw_state_queued)
        else -> ""
    }

@Composable
private fun RoomContent(context: Context, state: BotModeWidgetState, colors: BotWidgetPalette, height: Dp) {
    val room = state.room
    if (room == null) {
        EmptyState(context, colors, context.getString(R.string.botw_no_rooms), openAction(context, null))
        return
    }
    Column(modifier = GlanceModifier.fillMaxSize().clickable(openAction(context, room.openPayload))) {
        Header(
            room.name,
            colors,
            trailing = if (room.working) context.getString(R.string.botw_room_working) else null,
        )
        Spacer(GlanceModifier.height(6.dp))
        Row(modifier = GlanceModifier.fillMaxWidth()) {
            for (member in room.members.take(5)) {
                Column(
                    modifier = GlanceModifier.defaultWeight(),
                    horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
                ) {
                    Face(member.facePath, 28.dp, colors, member.name)
                    val label = memberStateLabel(context, member.state)
                    Text(
                        if (label.isEmpty()) member.name else label,
                        maxLines = 1,
                        style = TextStyle(
                            color = when (member.state) {
                                "working" -> colors.accent
                                "needs_you" -> colors.warning
                                "done" -> colors.success
                                else -> colors.secondary
                            },
                            fontSize = 9.sp,
                            textAlign = TextAlign.Center,
                        ),
                    )
                }
            }
        }
        if (height >= 150.dp && room.lastMessage != null) {
            Spacer(GlanceModifier.height(6.dp))
            Text(
                listOfNotNull(room.lastSpeaker, room.lastMessage).joinToString(": "),
                maxLines = if (height >= 230.dp) 4 else 2,
                style = TextStyle(color = colors.text, fontSize = 12.sp),
            )
        }
        Spacer(GlanceModifier.defaultWeight())
        val stop = room.stopPayload
        if (stop != null) {
            Chip(
                context.getString(R.string.botw_stop),
                colors.surface,
                colors.error,
                broadcastAction(context, "stop", stop),
                GlanceModifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun QuickAskContent(
    context: Context,
    state: BotModeWidgetState,
    legacy: HermesWidgetState,
    colors: BotWidgetPalette,
    width: Dp,
) {
    val bot = state.quick
    val name = bot?.name ?: context.getString(R.string.rich_brand)
    val ask = openAction(context, bot?.openPayload)
    val voice =
        actionStartActivity(
            NewSessionLaunchContract.newIntent(
                context,
                NewSessionLaunchContract.SOURCE_WIDGET,
                NewSessionLaunchTarget.VOICE,
                requestedInstanceId = legacy.instanceId,
            ),
        )
    val composer =
        if (bot == null) {
            actionStartActivity(
                NewSessionLaunchContract.newIntent(
                    context,
                    NewSessionLaunchContract.SOURCE_WIDGET,
                    NewSessionLaunchTarget.COMPOSER,
                    requestedInstanceId = legacy.instanceId,
                ),
            )
        } else {
            ask
        }
    Row(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.Vertical.CenterVertically) {
        Box(modifier = GlanceModifier.clickable(composer)) { Face(bot?.facePath, 30.dp, colors, name) }
        Spacer(GlanceModifier.width(8.dp))
        if (width >= 180.dp) {
            Box(
                modifier = GlanceModifier.defaultWeight().height(36.dp).background(colors.surface).cornerRadius(18.dp)
                    .clickable(composer).padding(horizontal = 14.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                Text(
                    context.getString(R.string.botw_ask, name),
                    maxLines = 1,
                    style = TextStyle(color = colors.secondary, fontSize = 13.sp),
                )
            }
            Spacer(GlanceModifier.width(8.dp))
        } else {
            Spacer(GlanceModifier.defaultWeight())
        }
        Box(
            modifier = GlanceModifier.size(36.dp).background(colors.accent).cornerRadius(18.dp).clickable(voice),
            contentAlignment = Alignment.Center,
        ) {
            Image(
                provider = ImageProvider(R.drawable.ic_new_session_widget_voice),
                contentDescription = context.getString(R.string.botw_dictate),
                modifier = GlanceModifier.size(18.dp),
                colorFilter = ColorFilter.tint(colors.onAccent),
            )
        }
    }
}

@Composable
private fun StatusContent(
    context: Context,
    state: BotModeWidgetState,
    legacy: HermesWidgetState,
    colors: BotWidgetPalette,
    nowMs: Long,
) {
    val configured = state.present || (legacy.configured && legacy.instanceId != null)
    val online =
        if (state.present && !state.isStale(nowMs)) {
            state.connected
        } else {
            legacy.connectionState == HermesWidgetConnectionState.CONNECTED && !legacy.isStale(nowMs)
        }
    val label = state.connectionLabel ?: legacy.instanceLabel ?: context.getString(R.string.rich_brand)
    Column(
        modifier = GlanceModifier.fillMaxSize().clickable(
            actionStartActivity(
                if (configured) NewSessionLaunchContract.openAppIntent(context) else NewSessionLaunchContract.openSetupIntent(context),
            ),
        ),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        Row(verticalAlignment = Alignment.Vertical.CenterVertically) {
            Box(
                modifier = GlanceModifier.size(8.dp).background(if (online) colors.success else colors.secondary).cornerRadius(4.dp),
            ) {}
            Spacer(GlanceModifier.width(6.dp))
            Text(
                if (!configured) context.getString(R.string.hermes_widget_not_configured) else label,
                maxLines = 1,
                style = TextStyle(color = colors.text, fontSize = 13.sp, fontWeight = FontWeight.Medium),
            )
        }
        Text(
            when {
                !configured -> context.getString(R.string.hermes_widget_setup_action)
                !online -> context.getString(R.string.botw_offline)
                state.needsYouCount > 0 -> context.getString(R.string.botw_needs_you_count, state.needsYouCount)
                state.workingCount > 0 -> context.getString(R.string.botw_working_count, state.workingCount)
                else -> context.getString(R.string.botw_all_idle)
            },
            maxLines = 1,
            style = TextStyle(
                color = if (state.needsYouCount > 0) colors.warning else if (state.workingCount > 0) colors.accent else colors.secondary,
                fontSize = 11.sp,
            ),
        )
    }
}

/** Redraws once when the published snapshot passes the proved window. */
internal object BotModeWidgetExpiryScheduler {
    private const val WORK_NAME = "hermes-botmode-widget-expiry-v1"

    fun replace(context: Context, state: BotModeWidgetState, nowMs: Long = System.currentTimeMillis()) {
        if (state.updatedAtMs <= 0) return
        val delayMs = state.updatedAtMs + BOT_MODE_STALE_AFTER_MS + 1 - nowMs
        if (delayMs <= 0) return
        val request =
            androidx.work.OneTimeWorkRequestBuilder<HermesWidgetExpiryWorker>()
                .setInitialDelay(delayMs, java.util.concurrent.TimeUnit.MILLISECONDS)
                .build()
        androidx.work.WorkManager
            .getInstance(context.applicationContext)
            .enqueueUniqueWork(WORK_NAME, androidx.work.ExistingWorkPolicy.REPLACE, request)
    }
}

internal fun botModeWidgetReceivers(): List<Class<out HomeWidgetGlanceWidgetReceiver<*>>> =
    listOf(
        NewSessionWidgetProvider::class.java,
        HermesNeedsYouWidgetProvider::class.java,
        HermesRoomWidgetProvider::class.java,
        HermesCompactWidgetProvider::class.java,
        HermesControlWidgetProvider::class.java,
    )
