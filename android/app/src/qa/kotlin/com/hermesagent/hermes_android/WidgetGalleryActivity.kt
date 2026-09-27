package com.hermesagent.hermes_android

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Bundle
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.appwidget.ExperimentalGlanceRemoteViewsApi
import androidx.glance.appwidget.GlanceRemoteViews
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.File

/**
 * QA-only widget gallery: renders the REAL Bot Mode Glance composables
 * (same code as the placed widgets) with synthetic sample data for every
 * state and size, shows them and writes PNGs to
 * `getExternalFilesDir("widget-gallery")`. Never talks to a server and never
 * reads the owner's snapshot. Launch:
 * `adb shell am start -n <pkg>/com.hermesagent.hermes_android.WidgetGalleryActivity`
 */
@OptIn(ExperimentalGlanceRemoteViewsApi::class)
class WidgetGalleryActivity : Activity() {
    private val scope = CoroutineScope(Dispatchers.Main)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#FF3A1410"))
            setPadding(dp(12), dp(12), dp(12), dp(12))
        }
        setContentView(ScrollView(this).apply { addView(column) })
        if (intent?.getBooleanExtra("clear", false) == true) {
            val manager = androidx.core.app.NotificationManagerCompat.from(this)
            for (tag in listOf("gallery.room.devs", "gallery.room.ops", "gallery.bot.builder", "gallery.bot.lead", "gallery.bot.scout")) manager.cancel(tag, 1)
            for (tag in listOf("gallery.room.devs", "gallery.room.ops", "gallery.bot.builder", "gallery.bot.lead", "gallery.bot.scout")) manager.cancel(tag, HermesRichNotifications.SUMMARY_ID)
            androidx.core.content.pm.ShortcutManagerCompat.removeLongLivedShortcuts(
                this,
                listOf("gallery.room.devs", "gallery.room.ops", "gallery.bot.builder", "gallery.bot.lead", "gallery.bot.scout").map { "gallery-$it" },
            )
            for (tag in listOf("gallery.live.devs", "gallery.live.ops", "gallery.live.summary")) manager.cancel(tag, 2)
            // Re-derive (or withdraw) the quiet lock-screen summary.
            HermesRichNotifications.syncGroupSummary(this, null)
            finish()
            return
        }
        scope.launch {
            renderAll(column)
            renderPickerPreviews(column)
            if (intent?.getBooleanExtra("notifications", false) == true) {
                postSampleNotifications()
                renderPostedNotifications(column)
            }
        }
    }

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value.toFloat(), resources.displayMetrics).toInt()

    private val written = mutableSetOf<String>()

    private fun face(bot: String, state: String): String? {
        val name = "botw_sample_${bot}_$state"
        val id = resources.getIdentifier(name, "drawable", packageName)
        if (id == 0) return null
        // Rewritten once per process: sample PNGs change between builds.
        val file = File(cacheDir, "gallery/$name.png")
        if (!file.isFile || name !in written) {
            written += name
            file.parentFile?.mkdirs()
            val bitmap = BitmapFactory.decodeResource(resources, id) ?: return null
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        return file.path
    }

    /** Simple 2x2 room tile from the sample faces (the app renders it in Dart). */
    private fun tile(key: String, bots: List<String>): String? {
        val file = File(cacheDir, "gallery/tile_$key.png")
        val size = 160
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#FF1A191D") }
        canvas.drawRoundRect(0f, 0f, size.toFloat(), size.toFloat(), size * .26f, size * .26f, paint)
        val cell = (size - 24) / 2
        bots.take(4).forEachIndexed { i, bot ->
            val path = face(bot, "idle") ?: return@forEachIndexed
            val b = BitmapFactory.decodeFile(path) ?: return@forEachIndexed
            val x = 12 + (i % 2) * cell
            val y = if (bots.size <= 2) (size - cell) / 2 else 12 + (i / 2) * cell
            canvas.drawBitmap(b, null, android.graphics.Rect(x, y, x + cell, y + cell), null)
        }
        file.parentFile?.mkdirs()
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        return file.path
    }

    private fun open(target: String) = """{"conn":"gallery","sid":"$target"}"""

    private fun bot(
        profile: String,
        name: String,
        state: WidgetBotState,
        steps: List<String> = emptyList(),
        room: String? = null,
        role: String? = null,
    ): WidgetBot {
        val faceState = when (state) {
            WidgetBotState.WORKING, WidgetBotState.THINKING -> "working"
            WidgetBotState.NEEDS_YOU -> "needs"
            WidgetBotState.DONE -> "done"
            WidgetBotState.FAILED -> "failed"
            WidgetBotState.IDLE -> "idle"
        }
        return WidgetBot(
            profile = profile,
            name = name,
            state = state,
            line = steps.lastOrNull(),
            facePath = face(profile, faceState),
            openPayload = open(profile),
            idleFacePath = face(profile, "idle"),
            steps = steps,
            sinceMs = System.currentTimeMillis() - 4 * 60_000,
            role = role,
            roomId = room?.let { "r-$it" },
            roomName = room,
        )
    }

    private fun member(profile: String, name: String, state: String): WidgetRoomMember {
        val faceState = when (state) {
            "working", "queued" -> "working"
            "done" -> "done"
            "needs_you" -> "needs"
            else -> "idle"
        }
        return WidgetRoomMember(name, state, face(profile, faceState))
    }

    private fun scenarios(): List<Triple<String, BotModeWidgetKind, Pair<DpSize, BotModeWidgetState>>> {
        val now = System.currentTimeMillis()
        val base = BotModeWidgetState(connectionId = "gallery", connectionLabel = "Home server", connected = true, updatedAtMs = now)
        val idleBots = listOf(
            bot("builder", "Builder", WidgetBotState.IDLE, role = "Publica la app Android"),
            bot("scout", "Scout", WidgetBotState.IDLE, role = "Investigación"),
            bot("review", "Review", WidgetBotState.IDLE, role = "Revisión de código"),
            bot("lead", "Lead", WidgetBotState.IDLE, role = "Planifica la semana"),
        )
        val steps = listOf(getString(R.string.botw_preview_step_1), getString(R.string.botw_preview_step_2), getString(R.string.botw_preview_step_3))
        val working = bot("builder", "Builder", WidgetBotState.WORKING, steps, room = "Console Devs")
        val devsRoom = WidgetRoom(
            id = "r-devs", name = "Console Devs", working = true,
            members = listOf(member("builder", "builder", "working"), member("review", "review", "done"), member("lead", "lead", "idle")),
            lastSpeaker = "review", lastMessage = "Bien, un detalle de nombres.",
            openPayload = open("r-devs"), stopPayload = "{}",
            phase = "working", sinceMs = now - 90_000,
        )
        val opsRoom = WidgetRoom(
            id = "r-ops", name = "Atlas", working = false,
            members = listOf(member("lead", "lead", "needs_you"), member("scout", "scout", "done")),
            lastSpeaker = null, lastMessage = null, openPayload = open("r-ops"), stopPayload = null,
            phase = "needs_you", sinceMs = now - 30_000,
        )
        val sq = DpSize(170.dp, 170.dp)
        val wide = DpSize(350.dp, 170.dp)
        val large = DpSize(350.dp, 350.dp)
        val strip = DpSize(350.dp, 70.dp)
        val small = DpSize(170.dp, 70.dp)
        fun heroState(b: WidgetBot, others: List<WidgetActiveRef> = emptyList()) = base.copy(
            bots = listOf(b) + idleBots.filter { it.profile != b.profile },
            active = listOf(WidgetActiveRef("bot", b.profile)) + others,
            hero = WidgetActiveRef("bot", b.profile),
            workingCount = if (b.state == WidgetBotState.WORKING) 1 else 0,
        )
        val multi = base.copy(
            bots = listOf(
                bot("lead", "Lead", WidgetBotState.NEEDS_YOU, room = "Atlas"),
                working,
                bot("scout", "Scout", WidgetBotState.WORKING, listOf("Comparar Glance")),
                bot("review", "Review", WidgetBotState.DONE, room = "Console Devs"),
            ),
            rooms = listOf(opsRoom, devsRoom),
            active = listOf(
                WidgetActiveRef("room", "r-ops"),
                WidgetActiveRef("room", "r-devs"),
                WidgetActiveRef("bot", "scout"),
            ),
            hero = WidgetActiveRef("room", "r-ops"),
            workingCount = 2,
            needsYouCount = 1,
            approvals = listOf(
                WidgetApproval("a1", "lead · Atlas", "Quiere ejecutar “gh pr ready 51”", face("lead", "needs"), "{}", open("r-ops"), true),
                WidgetApproval("a2", "builder · Console Devs", "Necesita tu OK · editar 3 archivos", face("builder", "needs"), "{}", open("r-devs"), true),
            ),
            quick = working,
        )
        return listOf(
            Triple("bots_2x2_overview", BotModeWidgetKind.BOTS, sq to base.copy(bots = idleBots)),
            Triple("bots_2x2_working", BotModeWidgetKind.BOTS, sq to heroState(working, listOf(WidgetActiveRef("bot", "scout"), WidgetActiveRef("room", "r-ops")))),
            Triple("bots_2x2_done", BotModeWidgetKind.BOTS, sq to heroState(bot("builder", "Builder", WidgetBotState.DONE, steps))),
            Triple("bots_2x2_needs_you", BotModeWidgetKind.BOTS, sq to heroState(bot("lead", "Lead", WidgetBotState.NEEDS_YOU, room = "Atlas"))),
            Triple("bots_2x2_failed", BotModeWidgetKind.BOTS, sq to heroState(bot("scout", "Scout", WidgetBotState.FAILED))),
            Triple("bots_2x2_room_hero", BotModeWidgetKind.BOTS, sq to multi.copy(hero = WidgetActiveRef("room", "r-devs"))),
            Triple("bots_4x2_list_multi", BotModeWidgetKind.BOTS, wide to multi),
            Triple("bots_4x4_hero_list", BotModeWidgetKind.BOTS, large to multi.copy(hero = WidgetActiveRef("room", "r-devs"), active = listOf(WidgetActiveRef("room", "r-devs"), WidgetActiveRef("room", "r-ops"), WidgetActiveRef("bot", "scout")))),
            Triple("needs_you_2x2", BotModeWidgetKind.NEEDS_YOU, sq to multi),
            Triple("needs_you_4x2", BotModeWidgetKind.NEEDS_YOU, wide to multi),
            Triple("needs_you_clear", BotModeWidgetKind.NEEDS_YOU, sq to base.copy(bots = idleBots)),
            Triple("room_2x2", BotModeWidgetKind.ROOM, sq to multi.copy(rooms = listOf(devsRoom, opsRoom))),
            Triple("room_4x2", BotModeWidgetKind.ROOM, wide to multi.copy(rooms = listOf(devsRoom, opsRoom))),
            Triple("room_4x2_needs_you", BotModeWidgetKind.ROOM, wide to multi),
            Triple("quick_ask_4x1", BotModeWidgetKind.QUICK_ASK, strip to multi),
            Triple("status_2x1", BotModeWidgetKind.STATUS, small to multi),
            Triple("bots_4x4_idle", BotModeWidgetKind.BOTS, large to base.copy(bots = idleBots)),
            Triple("room_4x4", BotModeWidgetKind.ROOM, large to multi.copy(rooms = listOf(devsRoom, opsRoom))),
        )
    }

    /**
     * Sample cards through the REAL renderer (no actions, no server): two
     * rooms + two Bots as separate conversations, an approval, two room Live
     * Updates and the multi-room summary.
     */
    private fun postSampleNotifications() {
        val now = System.currentTimeMillis()
        fun msg(key: String, name: String, text: String, face: String?) =
            mapOf("senderKey" to key, "senderName" to name, "text" to text, "iconPath" to face, "timeMs" to now)
        fun conv(tag: String, title: String, group: Boolean, accent: Int, messages: List<Map<String, Any?>>, tile: String? = null) =
            mapOf(
                "shortcutIconPath" to (tile ?: messages.last()["iconPath"]),
                "openPayload" to open(tag),
                "id" to 1, "tag" to tag, "channel" to "conversations", "title" to title,
                "text" to (messages.last()["text"] as String), "selfName" to "Tú", "isGroup" to group,
                "conversationId" to "gallery-$tag", "conversationTitle" to title, "groupKey" to "gallery-$tag",
                "alert" to false, "messages" to messages, "actions" to emptyList<Any?>(),
                "accent" to accent, "summaryLabel" to "avisos",
                "summaryLine" to "$title · " + when (accent) {
                    HermesRichNotifications.DONE -> "hecho"
                    HermesRichNotifications.FAILED -> "falló"
                    else -> "te necesita"
                },
                "publicTitle" to title, "publicText" to when (accent) {
                    HermesRichNotifications.DONE -> "Terminó"
                    HermesRichNotifications.FAILED -> "No pudo terminar"
                    else -> "Te necesita"
                },
            )
        HermesRichNotifications.postConversation(
            this,
            conv("gallery.room.devs", "Console Devs", true, HermesRichNotifications.DONE, listOf(
                msg("m-review", "review", "Ronda terminada · review respondió", face("review", "done")),
            ), tile = tile("devs", listOf("builder", "review", "lead"))),
        )
        HermesRichNotifications.postConversation(
            this,
            conv("gallery.room.ops", "Atlas", true, HermesRichNotifications.FAILED, listOf(
                msg("m-scout", "scout", "scout no pudo terminar", face("scout", "failed")),
            ), tile = tile("ops", listOf("lead", "scout", "review", "builder", "builder"))),
        )
        HermesRichNotifications.postConversation(
            this,
            conv("gallery.bot.builder", "Builder", false, HermesRichNotifications.DONE, listOf(
                msg("bot:builder", "Builder", "Terminó · el test de login ya pasa", face("builder", "done")),
            )),
        )
        HermesRichNotifications.postConversation(
            this,
            conv("gallery.bot.scout", "Scout", false, HermesRichNotifications.DONE, listOf(
                msg("bot:scout", "Scout", "Terminó «Resumen diario» · 3 novedades", face("scout", "done")),
            )),
        )
        HermesRichNotifications.postConversation(
            this,
            conv("gallery.bot.lead", "Lead", false, HermesRichNotifications.NEEDS_YOU, listOf(
                msg("bot:lead", "Lead", "Necesita tu OK para ejecutar “gh pr ready 51”", face("lead", "needs")),
            )) + mapOf("channel" to "approvals"),
        )
        fun live(tag: String, title: String, who: String, segments: List<String>, rows: List<Pair<String, String>>) =
            mapOf(
                "id" to 2, "tag" to tag, "title" to title,
                "text" to (listOf("$who está trabajando…") + rows.filter { it.first != who }.map { "${it.first} ${it.second.lowercase()}" }).joinToString(" · "),
                "bigText" to rows.joinToString("\n") { "${it.first} · ${it.second}" },
                // Real renderer, fake room: Stop is refused by the executor
                // (unknown connection); Open room opens the app.
                "stopLabel" to "Parar ronda", "openLabel" to "Abrir sala",
                "openPayload" to open(tag), "actionPayload" to """{"v":1,"route":"room","conn":"gallery","room":"$tag"}""",
                "subText" to "Ronda 1 · 1 de ${segments.size} trabajando",
                "segments" to segments.map { mapOf("state" to it) },
                "trackerIconPath" to face(who, "working"), "startedAtMs" to now - 95_000,
                "largeIconPath" to tile(tag, listOf(who, "review", "lead")),
                "shortText" to who.take(7), "timeoutMs" to 120_000L, "accent" to HermesRichNotifications.WORKING,
                "publicTitle" to "Trabajando…", "publicText" to "Ronda 1 · 1 de ${segments.size} trabajando",
            )
        HermesRichNotifications.postLiveUpdate(
            this,
            live("gallery.live.devs", "Console Devs", "builder", listOf("done", "working", "idle"),
                listOf("review" to "Respondió · 00:41", "builder" to "Escribiendo…", "lead" to "En espera")),
        )
        HermesRichNotifications.postLiveUpdate(
            this,
            live("gallery.live.ops", "Atlas", "scout", listOf("working", "needs_you"),
                listOf("scout" to "Escribiendo…", "lead" to "Te necesita")),
        )
        HermesRichNotifications.postLiveUpdate(
            this,
            mapOf(
                "id" to 2, "tag" to "gallery.live.summary", "title" to "3 salas trabajando",
                "text" to "Console Devs · Atlas · Research", "segments" to emptyList<Any?>(), "promote" to false,
                "timeoutMs" to 120_000L, "accent" to HermesRichNotifications.WORKING,
                "publicTitle" to "Trabajando…", "publicText" to "Nueva actividad",
            ),
        )
    }

    /**
     * The phone may be locked (the shade then shows only the redacted
     * public versions): render the posted cards' real system templates
     * (`recoverBuilder` → big content view) to PNG as evidence.
     */
    private fun renderPostedNotifications(column: LinearLayout) {
        val out = getExternalFilesDir("widget-gallery")?.apply { mkdirs() }
        val manager = getSystemService(android.app.NotificationManager::class.java) ?: return
        val w = dp(392)
        for (sbn in manager.activeNotifications.filter { it.tag?.startsWith("gallery.") == true }.sortedBy { it.tag }) {
            try {
                val builder = android.app.Notification.Builder.recoverBuilder(this, sbn.notification)
                val remote = builder.createBigContentView() ?: builder.createContentView()
                val frame = FrameLayout(this).apply { setBackgroundColor(Color.parseColor("#FF1F1F24")); setPadding(dp(12), dp(12), dp(12), dp(12)) }
                frame.addView(remote.apply(this, frame))
                frame.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
                frame.layout(0, 0, w, frame.measuredHeight)
                val bitmap = Bitmap.createBitmap(w, frame.measuredHeight.coerceAtLeast(1), Bitmap.Config.ARGB_8888)
                frame.draw(android.graphics.Canvas(bitmap))
                out?.let { dir -> File(dir, "notif_${sbn.tag}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } }
                column.addView(ImageView(this).apply { setImageBitmap(bitmap) }, LinearLayout.LayoutParams(w, bitmap.height))
            } catch (error: Exception) {
                column.addView(TextView(this).apply { text = "${sbn.tag}: ${error.javaClass.simpleName}"; setTextColor(Color.RED) })
            }
        }
    }

    /** Widget-picker previews: the real previewLayout XML, inflated. */
    private fun renderPickerPreviews(column: LinearLayout) {
        val out = getExternalFilesDir("widget-gallery")?.apply { mkdirs() }
        val previews = listOf(
            "picker_bots" to Pair(R.layout.botw_preview_bots, DpSize(170.dp, 170.dp)),
            "picker_needs_you" to Pair(R.layout.botw_preview_needs_you, DpSize(350.dp, 170.dp)),
            "picker_room" to Pair(R.layout.botw_preview_room, DpSize(350.dp, 170.dp)),
            "picker_quick_ask" to Pair(R.layout.botw_preview_quick_ask, DpSize(350.dp, 70.dp)),
            "picker_status" to Pair(R.layout.botw_preview_status, DpSize(170.dp, 70.dp)),
        )
        for ((name, pair) in previews) {
            val (layout, size) = pair
            val w = dp(size.width.value.toInt())
            val h = dp(size.height.value.toInt())
            val view = android.widget.RemoteViews(packageName, layout).apply(this, FrameLayout(this))
            view.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
            view.layout(0, 0, w, h)
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            view.draw(android.graphics.Canvas(bitmap))
            out?.let { dir -> File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } }
            column.addView(TextView(this).apply { text = name; setTextColor(Color.WHITE) })
            column.addView(ImageView(this).apply { setImageBitmap(bitmap) }, LinearLayout.LayoutParams(w, h))
        }
    }

    private suspend fun renderAll(column: LinearLayout) {
        val out = getExternalFilesDir("widget-gallery")?.apply { mkdirs() }
        val legacy = HermesWidgetState.from(getSharedPreferences("gallery", MODE_PRIVATE))
        for ((name, kind, pair) in scenarios()) {
            val (size, state) = pair
            val result = GlanceRemoteViews().compose(this, size) {
                BotModeWidgetContent(this@WidgetGalleryActivity, kind, state, legacy, System.currentTimeMillis(), size)
            }
            val host = FrameLayout(this)
            val view = result.remoteViews.apply(this, host)
            val w = dp(size.width.value.toInt())
            val h = dp(size.height.value.toInt())
            view.layoutParams = FrameLayout.LayoutParams(w, h)
            host.addView(view)
            host.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
            host.layout(0, 0, w, h)
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            host.draw(android.graphics.Canvas(bitmap))
            out?.let { dir -> File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } }
            column.addView(TextView(this).apply { text = name; setTextColor(Color.WHITE) })
            column.addView(
                ImageView(this).apply { setImageBitmap(bitmap) },
                LinearLayout.LayoutParams(w, h).apply { bottomMargin = dp(12) },
            )
        }
        column.addView(TextView(this).apply { text = "done"; setTextColor(Color.WHITE); tag = "gallery-done" }, ViewGroup.LayoutParams(-2, -2))
    }
}
