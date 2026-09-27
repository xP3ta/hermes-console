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
import androidx.glance.layout.fillMaxHeight
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
 * listener publishes; widgets never poll. All five are new receivers: the
 * original Hermes Console widgets (NewSessionWidgetProvider,
 * HermesCompactWidgetProvider, HermesControlWidgetProvider) keep rendering
 * HermesConsoleGlanceWidget, so widgets already placed from 1.2.13 are never
 * replaced; both families coexist in the widget picker.
 *
 * Visual language v2 (Grok Bot reference): a near-black card (#07080A) where
 * the state colour appears ONLY as a soft glow rising from the bottom edge
 * (working blue, done green, needs you amber, failed red; idle pure black),
 * the Bot's configured face as the hero (≈58 % of a 2x2, badge baked into
 * the PNG by Dart), one dim title line "Bot · Room", and a three-line ticker
 * (oldest tiny and faded, current white with its key word in blue). Wide
 * widgets are plain rows with hairline dividers — no boxes inside the card.
 * Widgets cannot animate: expressions rotate between frames per update.
 */
enum class BotModeWidgetKind { BOTS, NEEDS_YOU, ROOM, QUICK_ASK, STATUS }

class HermesBotModeWidget(private val kind: BotModeWidgetKind) : GlanceAppWidget() {
    override val stateDefinition = HomeWidgetGlanceStateDefinition()

    override val sizeMode: SizeMode =
        SizeMode.Responsive(
            when (kind) {
                BotModeWidgetKind.BOTS -> setOf(SMALL_SQUARE, SQUARE, WIDE, LARGE)
                BotModeWidgetKind.NEEDS_YOU -> setOf(SMALL_SQUARE, SQUARE, WIDE, LARGE)
                BotModeWidgetKind.ROOM -> setOf(SMALL_SQUARE, SQUARE, WIDE, LARGE)
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
            BotModeWidgetContent(context, kind, state, legacy, now, LocalSize.current)
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

        /** Typical 2x2 on phones (Pixel launcher ≈ 160-180 dp). */
        val SQUARE = DpSize(150.dp, 150.dp)
        val WIDE = DpSize(250.dp, 110.dp)
        val LARGE = DpSize(250.dp, 250.dp)
    }
}

class HermesBotsWidgetProvider : HomeWidgetGlanceWidgetReceiver<HermesBotModeWidget>() {
    override val glanceAppWidget = HermesBotModeWidget(BotModeWidgetKind.BOTS)
}

class HermesQuickAskWidgetProvider : HomeWidgetGlanceWidgetReceiver<HermesBotModeWidget>() {
    override val glanceAppWidget = HermesBotModeWidget(BotModeWidgetKind.QUICK_ASK)
}

class HermesStatusWidgetProvider : HomeWidgetGlanceWidgetReceiver<HermesBotModeWidget>() {
    override val glanceAppWidget = HermesBotModeWidget(BotModeWidgetKind.STATUS)
}

class HermesNeedsYouWidgetProvider : HomeWidgetGlanceWidgetReceiver<HermesBotModeWidget>() {
    override val glanceAppWidget = HermesBotModeWidget(BotModeWidgetKind.NEEDS_YOU)
}

class HermesRoomWidgetProvider : HomeWidgetGlanceWidgetReceiver<HermesBotModeWidget>() {
    override val glanceAppWidget = HermesBotModeWidget(BotModeWidgetKind.ROOM)
}

internal object BotW {
    val text = ColorProvider(Color(0xFFF2F3F5))
    val title = ColorProvider(Color(0xB8FFFFFF))
    val secondary = ColorProvider(Color(0x80FFFFFF))
    val faint = ColorProvider(Color(0x80FFFFFF))
    val fainter = ColorProvider(Color(0x47FFFFFF))
    val key = ColorProvider(Color(0xFF79AEFD))
    val onState = ColorProvider(Color(0xFF07080A))
    val brand = ColorProvider(Color(0xFFE8821C))

    /** Dots and badges. */
    fun color(state: WidgetBotState): ColorProvider =
        ColorProvider(
            when (state) {
                WidgetBotState.WORKING, WidgetBotState.THINKING -> Color(0xFF2F7CF6)
                WidgetBotState.DONE -> Color(0xFF32D74B)
                WidgetBotState.NEEDS_YOU -> Color(0xFFF5A623)
                WidgetBotState.FAILED -> Color(0xFFEF4D4D)
                WidgetBotState.IDLE -> Color(0xFF5C6068)
            },
        )

    /** State words on black (a lighter tint of [color] for legibility). */
    fun textColor(state: WidgetBotState): ColorProvider =
        when (state) {
            WidgetBotState.WORKING, WidgetBotState.THINKING -> key
            WidgetBotState.DONE -> ColorProvider(Color(0xFF6FE0A0))
            WidgetBotState.NEEDS_YOU -> ColorProvider(Color(0xFFFFC764))
            WidgetBotState.FAILED -> ColorProvider(Color(0xFFFF8A8A))
            WidgetBotState.IDLE -> secondary
        }

    fun glow(state: WidgetBotState): Int =
        when (state) {
            WidgetBotState.WORKING, WidgetBotState.THINKING -> R.drawable.botw_glow_working
            WidgetBotState.DONE -> R.drawable.botw_glow_done
            WidgetBotState.NEEDS_YOU -> R.drawable.botw_glow_needs_you
            WidgetBotState.FAILED -> R.drawable.botw_glow_failed
            WidgetBotState.IDLE -> R.drawable.botw_glow_idle
        }

    fun dot(state: WidgetBotState): Int =
        when (state) {
            WidgetBotState.WORKING, WidgetBotState.THINKING -> R.drawable.botw_dot_working
            WidgetBotState.DONE -> R.drawable.botw_dot_done
            WidgetBotState.NEEDS_YOU -> R.drawable.botw_dot_needs_you
            WidgetBotState.FAILED -> R.drawable.botw_dot_failed
            WidgetBotState.IDLE -> R.drawable.botw_dot_idle
        }

    fun roomMemberState(state: String): WidgetBotState =
        when (state) {
            "working", "queued" -> WidgetBotState.WORKING
            "done" -> WidgetBotState.DONE
            "needs_you" -> WidgetBotState.NEEDS_YOU
            "failed" -> WidgetBotState.FAILED
            else -> WidgetBotState.IDLE
        }

    /**
     * Face PNGs are 100-unit boxes whose face circle has r = 42 (the badge
     * sits in the top-left margin): image side for a face of [diameter].
     */
    fun faceImage(diameter: Float): Dp = (diameter / 0.84f).dp
}

/** Content-addressed face files never change, so the cache key is the path. */
private object FaceBitmaps {
    private val cache = object : LruCache<String, Bitmap>(6 * 1024 * 1024) {
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

/** State whose bottom glow the widget takes (idle = pure black). */
internal fun widgetGlowState(kind: BotModeWidgetKind, state: BotModeWidgetState, width: Dp): WidgetBotState =
    when (kind) {
        // Lists stay black: colour is a signal on each row's dot and word.
        BotModeWidgetKind.BOTS -> if (width >= 240.dp) WidgetBotState.IDLE else state.heroItem()?.state ?: WidgetBotState.IDLE
        BotModeWidgetKind.NEEDS_YOU -> if (state.approvals.isNotEmpty()) WidgetBotState.NEEDS_YOU else WidgetBotState.IDLE
        BotModeWidgetKind.ROOM -> state.room?.state ?: WidgetBotState.IDLE
        BotModeWidgetKind.QUICK_ASK -> WidgetBotState.IDLE
        BotModeWidgetKind.STATUS -> WidgetBotState.IDLE
    }

@Composable
internal fun BotModeWidgetContent(
    context: Context,
    kind: BotModeWidgetKind,
    state: BotModeWidgetState,
    legacy: HermesWidgetState,
    nowMs: Long,
    size: DpSize,
) {
    val compact = size.height < 90.dp
    val glow = widgetGlowState(kind, state, size.width)
    val root =
        GlanceModifier
            .fillMaxSize()
            .appWidgetBackground()
            .background(ImageProvider(BotW.glow(glow)))
            .cornerRadius(android.R.dimen.system_app_widget_background_radius)
            .padding(horizontal = if (compact) 12.dp else 14.dp, vertical = if (compact) 6.dp else 11.dp)
    Box(modifier = root, contentAlignment = Alignment.TopStart) {
        if (!state.present && kind != BotModeWidgetKind.STATUS && kind != BotModeWidgetKind.QUICK_ASK) {
            EmptyState(context, context.getString(R.string.botw_empty_setup), openAction(context, null))
        } else {
            when (kind) {
                BotModeWidgetKind.BOTS -> BotsContent(context, state, size, nowMs)
                BotModeWidgetKind.NEEDS_YOU -> NeedsYouContent(context, state, size)
                BotModeWidgetKind.ROOM -> RoomContent(context, state, size)
                BotModeWidgetKind.QUICK_ASK -> QuickAskContent(context, state, legacy, size.width)
                BotModeWidgetKind.STATUS -> StatusContent(context, state, legacy, nowMs)
            }
        }
    }
}

@Composable
private fun EmptyState(context: Context, text: String, action: Action) {
    Column(
        modifier = GlanceModifier.fillMaxSize().clickable(action),
        verticalAlignment = Alignment.Vertical.CenterVertically,
        horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
    ) {
        Image(
            provider = ImageProvider(R.drawable.ic_stat_hermes),
            contentDescription = null,
            modifier = GlanceModifier.size(22.dp),
            colorFilter = ColorFilter.tint(BotW.secondary),
        )
        Spacer(GlanceModifier.height(6.dp))
        Text(
            text,
            maxLines = 2,
            style = TextStyle(color = BotW.secondary, fontSize = 12.sp, textAlign = TextAlign.Center),
        )
    }
}

/** Face PNG (badge baked in) at [sizeDp]; neutral dark disc if missing. */
@Composable
private fun Face(path: String?, sizeDp: Dp, description: String?, state: WidgetBotState = WidgetBotState.IDLE) {
    val bitmap = FaceBitmaps.load(path)
    if (bitmap != null) {
        Image(
            provider = ImageProvider(bitmap),
            contentDescription = description,
            modifier = GlanceModifier.size(sizeDp),
        )
    } else {
        // Neutral fallback (no letters or invented identity) + state dot.
        val inset = (sizeDp.value * 0.08f).dp
        Box(modifier = GlanceModifier.size(sizeDp), contentAlignment = Alignment.TopStart) {
            Box(modifier = GlanceModifier.fillMaxSize().padding(inset)) {
                Box(modifier = GlanceModifier.fillMaxSize().background(ImageProvider(R.drawable.botw_preview_circle_surface))) {}
            }
            if (state != WidgetBotState.IDLE) StateDot(state, (sizeDp.value * 0.18f).dp)
        }
    }
}

@Composable
private fun StateDot(state: WidgetBotState, size: Dp) {
    Image(
        provider = ImageProvider(BotW.dot(state)),
        contentDescription = null,
        modifier = GlanceModifier.size(size),
    )
}

@Composable
private fun MorePill(count: Int) {
    if (count <= 0) return
    Box(
        modifier = GlanceModifier.height(17.dp).background(ImageProvider(R.drawable.botw_pill_glass)).padding(horizontal = 7.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "+$count",
            maxLines = 1,
            style = TextStyle(color = BotW.title, fontSize = 10.5.sp, fontWeight = FontWeight.Bold),
        )
    }
}

@Composable
private fun Hairline() {
    Box(modifier = GlanceModifier.fillMaxWidth().height(1.dp).background(ImageProvider(R.drawable.botw_hairline))) {}
}

/** Short state word for rows and member columns. */
private fun stateWord(context: Context, state: WidgetBotState): String? =
    when (state) {
        WidgetBotState.DONE -> context.getString(R.string.botw_state_done)
        WidgetBotState.FAILED -> context.getString(R.string.botw_failed)
        WidgetBotState.NEEDS_YOU -> context.getString(R.string.botw_needs_you_short)
        WidgetBotState.WORKING, WidgetBotState.THINKING -> context.getString(R.string.botw_state_working)
        WidgetBotState.IDLE -> null
    }

/** Outcome line under a hero: "✓ Listo · 4 min", "Te necesita", "Falló". */
private fun outcomeLine(context: Context, state: WidgetBotState, sinceMs: Long, nowMs: Long): String? =
    when (state) {
        WidgetBotState.DONE -> {
            val minutes = if (sinceMs > 0) ((nowMs - sinceMs) / 60_000L).toInt() else 0
            if (minutes >= 1) context.getString(R.string.botw_done_ago, minutes) else context.getString(R.string.botw_done)
        }
        WidgetBotState.FAILED -> context.getString(R.string.botw_failed)
        WidgetBotState.NEEDS_YOU -> context.getString(R.string.botw_needs_you_short)
        else -> null
    }

/** Short room name for the title line ("Design Review" → "Review"). */
internal fun shortRoomName(name: String): String {
    val trimmed = name.trim()
    if (trimmed.length <= 10) return trimmed
    return trimmed.split(Regex("\\s+")).lastOrNull()?.takeIf { it.isNotEmpty() } ?: trimmed
}

/** ONE dim title line: "Builder · Devs" (name brighter, room dimmer). */
@Composable
private fun HeroTitle(name: String, room: String?) {
    Row(
        modifier = GlanceModifier.fillMaxWidth().padding(horizontal = 18.dp),
        horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        Text(name, maxLines = 1, style = TextStyle(color = BotW.title, fontSize = 11.5.sp, fontWeight = FontWeight.Medium))
        if (!room.isNullOrEmpty()) {
            Text(" · ${shortRoomName(room)}", maxLines = 1, style = TextStyle(color = BotW.secondary, fontSize = 11.5.sp))
        }
    }
}

/**
 * Ticker: oldest step tiny and faded, middle dim, current white with its
 * key (last) word in blue and a small leading icon. Steps arrive already
 * shortened on whole words by Dart (≤ 4 words).
 */
@Composable
private fun Ticker(steps: List<String>, lines: Int, align: Alignment.Horizontal) {
    val shown = steps.takeLast(lines)
    val older = shown.dropLast(1)
    val current = shown.lastOrNull() ?: return
    val textAlign = if (align == Alignment.Horizontal.CenterHorizontally) TextAlign.Center else TextAlign.Start
    older.forEachIndexed { index, step ->
        val far = older.size - index >= 2
        Text(
            step,
            maxLines = 1,
            modifier = GlanceModifier.fillMaxWidth(),
            style = TextStyle(
                color = if (far) BotW.fainter else BotW.faint,
                fontSize = if (far) 10.sp else 11.sp,
                textAlign = textAlign,
            ),
        )
    }
    val split = current.lastIndexOf(' ')
    Row(
        modifier = GlanceModifier.fillMaxWidth().padding(top = 1.dp),
        horizontalAlignment = align,
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        Image(
            provider = ImageProvider(R.drawable.botw_ic_step),
            contentDescription = null,
            modifier = GlanceModifier.size(width = 12.dp, height = 10.dp),
            colorFilter = ColorFilter.tint(BotW.text),
        )
        Spacer(GlanceModifier.width(5.dp))
        if (split in 1 until current.length - 1) {
            Text(
                current.substring(0, split + 1),
                maxLines = 1,
                style = TextStyle(color = BotW.text, fontSize = 13.sp, fontWeight = FontWeight.Medium),
            )
            Text(
                current.substring(split + 1),
                maxLines = 1,
                style = TextStyle(color = BotW.key, fontSize = 13.sp, fontWeight = FontWeight.Medium),
            )
        } else {
            Text(
                current,
                maxLines = 1,
                style = TextStyle(color = BotW.key, fontSize = 13.sp, fontWeight = FontWeight.Medium),
            )
        }
    }
}

/** Bottom of a hero: ticker while working, one outcome line otherwise. */
@Composable
private fun HeroFooter(context: Context, state: WidgetBotState, steps: List<String>, lines: Int, sinceMs: Long, nowMs: Long) {
    when (state) {
        WidgetBotState.WORKING, WidgetBotState.THINKING ->
            Ticker(steps.ifEmpty { listOf(context.getString(R.string.botw_working_now)) }, lines, Alignment.Horizontal.CenterHorizontally)
        else -> {
            val label = outcomeLine(context, state, sinceMs, nowMs) ?: return
            Text(
                label,
                maxLines = 1,
                modifier = GlanceModifier.fillMaxWidth(),
                style = TextStyle(
                    color = if (state == WidgetBotState.DONE) BotW.text else BotW.textColor(state),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.Center,
                ),
            )
        }
    }
}

/** Hero face geometry for a widget of [size] (content box after padding). */
internal data class HeroGeometry(val faceDiameter: Float, val faceTop: Float)

internal fun heroGeometry(size: DpSize, working: Boolean): HeroGeometry {
    val w = size.width.value
    val h = size.height.value
    // Reference: face ≈ 58 % of the widget (done), ≈ 50 % while the 3-line
    // ticker needs the bottom third.
    val d = if (working) minOf(w * 0.60f, h * 0.56f) else minOf(w * 0.66f, h * 0.64f)
    // Centre slightly above the middle (reference ≈ 41 % / 47 % of height);
    // the ticker may overlap the face's lower edge, as in the reference.
    val centre = h * (if (working) 0.43f else 0.47f)
    return HeroGeometry(d, centre - d / 2f)
}

/** Single-item hero (Bot or room member), used by the 2x2 and on top of 4x4. */
@Composable
private fun Hero(context: Context, item: WidgetActiveItem, others: Int, size: DpSize, nowMs: Long, modifier: GlanceModifier) {
    val content = DpSize(size.width - 28.dp, size.height - 22.dp)
    val lines = if (content.height >= 130.dp) 3 else 2
    val title: String
    val room: String?
    val facePath: String?
    val state: WidgetBotState
    val steps: List<String>
    val since: Long
    when (item) {
        is WidgetActiveItem.Bot -> {
            val bot = item.bot
            title = bot.name
            room = bot.roomName
            facePath = bot.facePath
            state = bot.state
            steps = bot.steps.ifEmpty { listOfNotNull(bot.line) }
            since = bot.sinceMs
        }
        is WidgetActiveItem.Room -> {
            val r = item.room
            // The room is represented by its most relevant member's face.
            val lead = r.members.minByOrNull { BotW.roomMemberState(it.state).priority }
            title = lead?.name ?: r.name
            room = if (lead != null) r.name else null
            facePath = lead?.facePath
            state = r.state
            steps = roomSteps(context, r).ifEmpty { listOf(context.getString(R.string.botw_working_now)) }
            since = r.sinceMs
        }
    }
    val geo = heroGeometry(content, state == WidgetBotState.WORKING || state == WidgetBotState.THINKING)
    val image = BotW.faceImage(geo.faceDiameter)
    // The PNG has an 8 % transparent margin above the face circle.
    val imageTop = (geo.faceTop - image.value * 0.08f).coerceAtLeast(0f).dp
    Box(modifier = modifier.clickable(openAction(context, item.openPayload)), contentAlignment = Alignment.TopCenter) {
        Box(modifier = GlanceModifier.fillMaxSize().padding(top = imageTop), contentAlignment = Alignment.TopCenter) {
            Face(facePath, image, title, state)
        }
        Box(modifier = GlanceModifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            HeroTitle(title, room)
        }
        if (others > 0) {
            Box(modifier = GlanceModifier.fillMaxSize(), contentAlignment = Alignment.TopEnd) { MorePill(others) }
        }
        Box(modifier = GlanceModifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
            Column(modifier = GlanceModifier.fillMaxWidth(), horizontalAlignment = Alignment.Horizontal.CenterHorizontally) {
                HeroFooter(context, state, steps, lines, since, nowMs)
            }
        }
    }
}

/**
 * Round ticker built on the widget side from member states with localized
 * resources (never Dart/English templates): replied → working → needs you.
 */
internal fun roomSteps(context: Context, room: WidgetRoom): List<String> {
    val steps = buildList {
        for (m in room.members) if (m.state == "done") add(context.getString(R.string.botw_step_replied, m.name))
        for (m in room.members) if (m.state == "working" || m.state == "queued") add(context.getString(R.string.botw_step_working, m.name))
        for (m in room.members) if (m.state == "needs_you") add(context.getString(R.string.botw_step_needs_you, m.name))
    }
    return steps.takeLast(3)
}

/**
 * Room avatar tile (same as the app roster): a rounded square with up to
 * four mini faces in a non-overlapping 2x2 grid; the last cell shows "+n"
 * when more members exist.
 */
@Composable
private fun RoomTile(members: List<WidgetRoomMember>, size: Dp) {
    val cell = ((size.value - 4f) / 2f).dp
    val sorted = members.sortedBy { BotW.roomMemberState(it.state).priority }
    val overflow = sorted.size > 4
    val faces = if (overflow) sorted.take(3) else sorted.take(4)
    Box(
        modifier = GlanceModifier.size(size).background(ImageProvider(R.drawable.botw_tile)).padding(2.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column {
            val cells: List<WidgetRoomMember?> = faces + if (overflow) listOf(null) else emptyList()
            for (row in cells.chunked(2)) {
                Row {
                    for (m in row) {
                        if (m == null) {
                            Box(modifier = GlanceModifier.size(cell), contentAlignment = Alignment.Center) {
                                Text(
                                    "+${sorted.size - 3}",
                                    style = TextStyle(color = BotW.text, fontSize = 9.sp, fontWeight = FontWeight.Bold),
                                )
                            }
                        } else {
                            Face(m.facePath, cell, m.name, WidgetBotState.IDLE)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun BotsContent(context: Context, state: BotModeWidgetState, size: DpSize, nowMs: Long) {
    val items = state.activeItems()
    val hero = state.heroItem()
    val others = (items.size - 1).coerceAtLeast(0)
    when {
        // 4x4: hero on top + plain rows below.
        size.width >= 240.dp && size.height >= 230.dp -> Column(modifier = GlanceModifier.fillMaxSize()) {
            if (hero != null) {
                val heroHeight = size.height * 0.52f
                Hero(context, hero, 0, DpSize(size.width, heroHeight), nowMs, GlanceModifier.fillMaxWidth().height(heroHeight - 11.dp))
                Hairline()
                ActiveList(context, state, exclude = hero, max = 3, more = others)
            } else {
                ActiveList(context, state, exclude = null, max = 5, more = 0)
            }
        }
        // 4x2: plain rows.
        size.width >= 240.dp ->
            ActiveList(context, state, exclude = null, max = ((size.height.value - 22f) / 48f).toInt().coerceIn(1, 5), more = -1)
        // 2x2: hero when something is active, else overview grid.
        hero != null -> Hero(context, hero, others, size, nowMs, GlanceModifier.fillMaxSize())
        else -> OverviewGrid(context, state, size)
    }
}

@Composable
private fun OverviewGrid(context: Context, state: BotModeWidgetState, size: DpSize) {
    val bots = state.bots.take(4)
    if (bots.isEmpty()) {
        EmptyState(context, context.getString(R.string.botw_no_bots), openAction(context, null))
        return
    }
    // Reference: 54 dp faces in a 176 dp widget (≈ 31 %).
    val face = BotW.faceImage((minOf(size.width.value, size.height.value) * 0.31f).coerceIn(30f, 64f))
    Column(
        modifier = GlanceModifier.fillMaxSize().padding(horizontal = 4.dp, vertical = 4.dp),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        for (row in bots.chunked(2)) {
            Row(modifier = GlanceModifier.fillMaxWidth().defaultWeight(), verticalAlignment = Alignment.Vertical.CenterVertically) {
                for (bot in row) {
                    Box(
                        modifier = GlanceModifier.defaultWeight().fillMaxHeight().clickable(openAction(context, bot.openPayload)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Face(bot.facePath, face, bot.name, bot.state)
                    }
                }
                if (row.size == 1) Spacer(GlanceModifier.defaultWeight())
            }
        }
    }
}

/**
 * Plain rows (no boxes): every active item (priority order), then idle Bots
 * to fill. Bot row: 34 dp face · bold name + one dim line · coloured dot +
 * state word. Room row: 2x2 member tile · room name + round step. Hairline
 * dividers; "+N" of the hidden active items top-right ([more] < 0 = auto).
 */
@Composable
private fun ActiveList(context: Context, state: BotModeWidgetState, exclude: WidgetActiveItem?, max: Int, more: Int) {
    val active = state.activeItems().filter { it != exclude }
    val shownBots = active.mapNotNull { (it as? WidgetActiveItem.Bot)?.bot?.profile }.toSet() +
        listOfNotNull((exclude as? WidgetActiveItem.Bot)?.bot?.profile)
    val idle = state.bots.filter { it.state == WidgetBotState.IDLE && it.profile !in shownBots }
        .map { WidgetActiveItem.Bot(it) }
    val rows = (active + idle).take(max)
    if (rows.isEmpty()) {
        if (exclude == null) EmptyState(context, context.getString(R.string.botw_no_bots), openAction(context, null))
        return
    }
    val hidden = if (more >= 0) 0 else active.size - rows.count { it.state != WidgetBotState.IDLE }
    Box(modifier = GlanceModifier.fillMaxWidth(), contentAlignment = Alignment.TopEnd) {
        Column(modifier = GlanceModifier.fillMaxWidth()) {
            rows.forEachIndexed { index, item ->
                if (index > 0) Hairline()
                ListRow(context, item)
            }
        }
        if (hidden > 0) MorePill(hidden)
    }
}

@Composable
private fun ListRow(context: Context, item: WidgetActiveItem) {
    val (title, line) =
        when (item) {
            is WidgetActiveItem.Bot -> {
                val bot = item.bot
                val room = bot.roomName?.let { shortRoomName(it) }
                val detail = when (bot.state) {
                    WidgetBotState.IDLE -> bot.role ?: context.getString(R.string.botw_idle)
                    WidgetBotState.WORKING, WidgetBotState.THINKING ->
                        listOfNotNull(room, bot.steps.lastOrNull() ?: bot.line ?: context.getString(R.string.botw_working_now)).joinToString(" · ")
                    else -> listOfNotNull(room, bot.steps.lastOrNull() ?: bot.role).joinToString(" · ")
                }
                bot.name to detail
            }
            is WidgetActiveItem.Room -> {
                val room = item.room
                room.name to (roomSteps(context, room).lastOrNull() ?: room.lastMessage ?: "")
            }
        }
    Row(
        modifier = GlanceModifier.fillMaxWidth().height(48.dp).clickable(openAction(context, item.openPayload)),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        when (item) {
            is WidgetActiveItem.Bot -> Face(item.bot.facePath, BotW.faceImage(34f), item.bot.name, item.bot.state)
            is WidgetActiveItem.Room -> Box(modifier = GlanceModifier.size(BotW.faceImage(34f)), contentAlignment = Alignment.Center) {
                RoomTile(item.room.members, 34.dp)
            }
        }
        Spacer(GlanceModifier.width(8.dp))
        Column(modifier = GlanceModifier.defaultWeight()) {
            Text(title, maxLines = 1, style = TextStyle(color = BotW.text, fontSize = 13.5.sp, fontWeight = FontWeight.Bold))
            if (line.isNotEmpty()) {
                Text(line, maxLines = 1, style = TextStyle(color = BotW.secondary, fontSize = 11.5.sp))
            }
        }
        val word = stateWord(context, item.state)
        if (word != null) {
            Spacer(GlanceModifier.width(8.dp))
            StateDot(item.state, 7.dp)
            Spacer(GlanceModifier.width(5.dp))
            Text(word, maxLines = 1, style = TextStyle(color = BotW.textColor(item.state), fontSize = 11.sp, fontWeight = FontWeight.Bold))
        }
    }
}

@Composable
private fun Pill(label: String, background: Int, foreground: ColorProvider, action: Action, modifier: GlanceModifier = GlanceModifier) {
    // Drawable backgrounds keep their rounded corners on every host
    // (cornerRadius needs API 31 and a cooperating host).
    Box(
        modifier = modifier.height(30.dp).background(ImageProvider(background)).clickable(action).padding(horizontal = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            maxLines = 1,
            style = TextStyle(color = foreground, fontSize = 12.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center),
        )
    }
}

@Composable
private fun NeedsYouContent(context: Context, state: BotModeWidgetState, size: DpSize) {
    if (state.approvals.isEmpty()) {
        Column(
            modifier = GlanceModifier.fillMaxSize().clickable(openAction(context, null)),
            verticalAlignment = Alignment.Vertical.CenterVertically,
            horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
        ) {
            Text("✓", style = TextStyle(color = BotW.textColor(WidgetBotState.DONE), fontSize = 22.sp, fontWeight = FontWeight.Bold))
            Text(context.getString(R.string.botw_all_clear), style = TextStyle(color = BotW.secondary, fontSize = 12.sp))
        }
        return
    }
    val first = state.approvals.first()
    if (size.width < 240.dp) {
        // 2x2: one approval as a hero (face + who + Approve/Deny).
        val (who, room) = splitApprovalTitle(first.title)
        Column(modifier = GlanceModifier.fillMaxSize(), horizontalAlignment = Alignment.Horizontal.CenterHorizontally) {
            Box(modifier = GlanceModifier.fillMaxWidth(), contentAlignment = Alignment.TopEnd) {
                HeroTitle(who, room)
                MorePill(state.approvals.size - 1)
            }
            Box(
                modifier = GlanceModifier.fillMaxWidth().defaultWeight().clickable(openAction(context, first.openPayload)),
                contentAlignment = Alignment.Center,
            ) {
                Face(first.facePath, BotW.faceImage(minOf(size.width.value * 0.40f, size.height.value * 0.34f)), first.title, WidgetBotState.NEEDS_YOU)
            }
            if (first.text.isNotEmpty() && size.height >= 150.dp) {
                Text(first.text, maxLines = 1, modifier = GlanceModifier.fillMaxWidth(), style = TextStyle(color = BotW.secondary, fontSize = 11.sp, textAlign = TextAlign.Center))
                Spacer(GlanceModifier.height(6.dp))
            }
            ApprovalButtons(context, first)
        }
        return
    }
    val max = if (size.height >= 230.dp) 3 else 1
    Box(modifier = GlanceModifier.fillMaxSize(), contentAlignment = Alignment.TopEnd) {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            state.approvals.take(max).forEachIndexed { index, approval ->
                if (index > 0) {
                    Spacer(GlanceModifier.height(6.dp))
                    Hairline()
                    Spacer(GlanceModifier.height(6.dp))
                }
                Row(
                    modifier = GlanceModifier.fillMaxWidth().clickable(openAction(context, approval.openPayload)),
                    verticalAlignment = Alignment.Vertical.CenterVertically,
                ) {
                    Face(approval.facePath, BotW.faceImage(34f), approval.title, WidgetBotState.NEEDS_YOU)
                    Spacer(GlanceModifier.width(8.dp))
                    Column(modifier = GlanceModifier.defaultWeight()) {
                        Text(approval.title, maxLines = 1, style = TextStyle(color = BotW.text, fontSize = 13.5.sp, fontWeight = FontWeight.Bold))
                        if (approval.text.isNotEmpty()) {
                            Text(approval.text, maxLines = 2, style = TextStyle(color = BotW.secondary, fontSize = 11.5.sp))
                        }
                    }
                }
                Spacer(GlanceModifier.height(8.dp))
                ApprovalButtons(context, approval)
            }
        }
        MorePill(state.approvals.size - max)
    }
}

/** "lead · Atlas" → ("lead", "Atlas"). */
private fun splitApprovalTitle(title: String): Pair<String, String?> {
    val index = title.indexOf(" · ")
    return if (index <= 0) title to null else title.substring(0, index) to title.substring(index + 3)
}

@Composable
private fun ApprovalButtons(context: Context, approval: WidgetApproval) {
    Row(modifier = GlanceModifier.fillMaxWidth()) {
        if (approval.canApprove) {
            Pill(context.getString(R.string.botw_approve), R.drawable.botw_pill_amber, BotW.onState, broadcastAction(context, "approve", approval.actionPayload), GlanceModifier.defaultWeight())
            Spacer(GlanceModifier.width(6.dp))
            Pill(context.getString(R.string.botw_deny), R.drawable.botw_pill_glass, BotW.text, broadcastAction(context, "deny", approval.actionPayload), GlanceModifier.defaultWeight())
        } else {
            Pill(context.getString(R.string.botw_open), R.drawable.botw_pill_amber, BotW.onState, openAction(context, approval.openPayload), GlanceModifier.defaultWeight())
        }
    }
}

private fun memberStateLabel(context: Context, state: String): String =
    when (state) {
        "working" -> context.getString(R.string.botw_state_working)
        "done" -> context.getString(R.string.botw_state_replied)
        "needs_you" -> context.getString(R.string.botw_state_needs_you)
        "queued" -> context.getString(R.string.botw_state_queued)
        "failed" -> context.getString(R.string.botw_failed)
        else -> context.getString(R.string.botw_idle)
    }

@Composable
private fun RoomContent(context: Context, state: BotModeWidgetState, size: DpSize) {
    val room = state.room
    if (room == null) {
        EmptyState(context, context.getString(R.string.botw_no_rooms), openAction(context, null))
        return
    }
    val others = state.rooms.size - 1
    val wide = size.width >= 240.dp
    val open = openAction(context, room.openPayload)
    Column(modifier = GlanceModifier.fillMaxSize()) {
        Row(modifier = GlanceModifier.fillMaxWidth().clickable(open), verticalAlignment = Alignment.Vertical.CenterVertically) {
            Text(
                room.name,
                maxLines = 1,
                modifier = GlanceModifier.defaultWeight(),
                style = TextStyle(color = BotW.title, fontSize = 12.sp, fontWeight = FontWeight.Medium),
            )
            MorePill(others)
        }
        // Member faces in a clean row, state word under each.
        val max = if (wide) 5 else 3
        val face = when {
            size.height >= 230.dp -> 60f
            size.height >= 150.dp -> if (wide) 44f else 38f
            else -> 30f
        }
        Row(
            modifier = GlanceModifier.fillMaxWidth().defaultWeight().clickable(open),
            horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
            verticalAlignment = Alignment.Vertical.CenterVertically,
        ) {
            for ((index, member) in room.members.take(max).withIndex()) {
                if (index > 0) Spacer(GlanceModifier.width(if (wide) 12.dp else 4.dp))
                val memberState = BotW.roomMemberState(member.state)
                Column(horizontalAlignment = Alignment.Horizontal.CenterHorizontally) {
                    Face(member.facePath, BotW.faceImage(face), member.name, memberState)
                    Text(
                        if (wide) member.name else memberStateLabel(context, member.state),
                        maxLines = 1,
                        style = TextStyle(color = if (wide) BotW.title else BotW.textColor(memberState), fontSize = 10.sp, textAlign = TextAlign.Center),
                    )
                    if (wide) {
                        Text(
                            memberStateLabel(context, member.state),
                            maxLines = 1,
                            style = TextStyle(color = BotW.textColor(memberState), fontSize = 9.5.sp, textAlign = TextAlign.Center),
                        )
                    }
                }
            }
        }
        // Last message line + discreet stop.
        val line = if (room.lastMessage != null) {
            listOfNotNull(room.lastSpeaker, room.lastMessage).joinToString(": ")
        } else {
            roomSteps(context, room).lastOrNull() ?: outcomeLine(context, room.state, room.sinceMs, System.currentTimeMillis())
        }
        Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Vertical.CenterVertically) {
            Text(
                line ?: "",
                maxLines = if (size.height >= 230.dp) 2 else 1,
                modifier = GlanceModifier.defaultWeight().clickable(open),
                style = TextStyle(color = BotW.secondary, fontSize = 11.5.sp),
            )
            val stop = room.stopPayload
            if (stop != null) {
                Spacer(GlanceModifier.width(8.dp))
                Row(
                    modifier = GlanceModifier.height(28.dp).clickable(broadcastAction(context, "stop", stop)).padding(horizontal = 4.dp),
                    verticalAlignment = Alignment.Vertical.CenterVertically,
                ) {
                    Image(
                        provider = ImageProvider(R.drawable.botw_ic_stop),
                        contentDescription = context.getString(R.string.botw_stop),
                        modifier = GlanceModifier.size(14.dp),
                        colorFilter = ColorFilter.tint(BotW.secondary),
                    )
                    if (wide) {
                        Spacer(GlanceModifier.width(4.dp))
                        Text(context.getString(R.string.botw_stop), maxLines = 1, style = TextStyle(color = BotW.secondary, fontSize = 11.sp))
                    }
                }
            }
        }
    }
}

@Composable
private fun QuickAskContent(
    context: Context,
    state: BotModeWidgetState,
    legacy: HermesWidgetState,
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
        Box(modifier = GlanceModifier.clickable(composer)) { Face(bot?.facePath, BotW.faceImage(34f), name, bot?.state ?: WidgetBotState.IDLE) }
        Spacer(GlanceModifier.width(8.dp))
        if (width >= 180.dp) {
            Box(
                modifier = GlanceModifier.defaultWeight().height(36.dp).background(ImageProvider(R.drawable.botw_pill_glass))
                    .clickable(composer).padding(horizontal = 14.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                Text(
                    context.getString(R.string.botw_ask, name),
                    maxLines = 1,
                    style = TextStyle(color = BotW.secondary, fontSize = 13.sp),
                )
            }
            Spacer(GlanceModifier.width(8.dp))
        } else {
            Spacer(GlanceModifier.defaultWeight())
        }
        Box(
            modifier = GlanceModifier.size(36.dp).background(ImageProvider(R.drawable.botw_preview_circle_accent)).clickable(voice),
            contentAlignment = Alignment.Center,
        ) {
            Image(
                provider = ImageProvider(R.drawable.ic_new_session_widget_voice),
                contentDescription = context.getString(R.string.botw_dictate),
                modifier = GlanceModifier.size(18.dp),
                colorFilter = ColorFilter.tint(BotW.onState),
            )
        }
    }
}

@Composable
private fun StatusContent(
    context: Context,
    state: BotModeWidgetState,
    legacy: HermesWidgetState,
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
    val tone = when {
        !online -> WidgetBotState.IDLE
        state.needsYouCount > 0 -> WidgetBotState.NEEDS_YOU
        state.workingCount > 0 -> WidgetBotState.WORKING
        else -> WidgetBotState.DONE
    }
    Column(
        modifier = GlanceModifier.fillMaxSize().clickable(
            actionStartActivity(
                if (configured) NewSessionLaunchContract.openAppIntent(context) else NewSessionLaunchContract.openSetupIntent(context),
            ),
        ),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        Row(verticalAlignment = Alignment.Vertical.CenterVertically) {
            StateDot(tone, 8.dp)
            Spacer(GlanceModifier.width(7.dp))
            Text(
                if (!configured) context.getString(R.string.hermes_widget_not_configured) else label,
                maxLines = 1,
                style = TextStyle(color = BotW.text, fontSize = 13.sp, fontWeight = FontWeight.Bold),
            )
        }
        Text(
            when {
                !configured -> context.getString(R.string.hermes_widget_setup_action)
                !online -> context.getString(R.string.botw_offline)
                state.needsYouCount > 0 -> context.resources.getQuantityString(R.plurals.botw_needs_you_n, state.needsYouCount, state.needsYouCount)
                state.workingCount > 0 -> context.getString(R.string.botw_working_count, state.workingCount)
                else -> context.getString(R.string.botw_all_idle)
            },
            maxLines = 1,
            modifier = GlanceModifier.padding(start = 15.dp),
            style = TextStyle(color = if (tone == WidgetBotState.IDLE || tone == WidgetBotState.DONE) BotW.secondary else BotW.textColor(tone), fontSize = 11.5.sp, fontWeight = FontWeight.Medium),
        )
    }
}

/** Redraws once when the published snapshot passes the proved window. */
internal object BotModeWidgetExpiryScheduler {
    private const val WORK_NAME = "hermes-botmode-widget-expiry-v1"

    fun replace(context: Context, state: BotModeWidgetState, nowMs: Long = System.currentTimeMillis()) {
        if (state.updatedAtMs <= 0) return
        // Stale window, or the end of a done/failed outcome window.
        val due = state.nextExpiryMs(nowMs) ?: return
        val delayMs = due - nowMs
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
        HermesBotsWidgetProvider::class.java,
        HermesNeedsYouWidgetProvider::class.java,
        HermesRoomWidgetProvider::class.java,
        HermesStatusWidgetProvider::class.java,
        HermesQuickAskWidgetProvider::class.java,
    )
