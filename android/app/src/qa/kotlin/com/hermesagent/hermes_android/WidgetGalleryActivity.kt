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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.File

/**
 * QA-only widget gallery: renders the REAL launcher widgets (the renderer
 * the placed widgets use) with synthetic sample data for every state and
 * size, shows them and writes PNGs to
 * `getExternalFilesDir("widget-gallery")`. Never talks to a server and never
 * reads the owner's snapshot. Launch:
 * `adb shell am start -n <pkg>/com.hermesagent.hermes_android.WidgetGalleryActivity`
 */
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
        val refresh = intent?.getIntExtra("refresh", 0) ?: 0
        if (refresh > 0) {
            // QA: asks every placed launcher widget to redraw `refresh` times,
            // the way the app does when a snapshot changes (a shell cannot:
            // the receivers are not exported). Nothing is drawn here.
            scope.launch {
                repeat(refresh) {
                    LauncherWidgets.requestUpdate(applicationContext, launcherWidgetReceivers())
                    kotlinx.coroutines.delay(1500)
                }
                finish()
            }
            return
        }
        scope.launch {
            renderLauncherWidgets(column)
            renderPickerPreviews(column)
            if (intent?.getBooleanExtra("notifications", false) == true) {
                postSampleNotifications()
                renderPostedNotifications(column)
            }
            // What a capture script waits for.
            column.addView(
                TextView(this@WidgetGalleryActivity).apply { text = "done"; setTextColor(Color.WHITE); tag = "gallery-done" },
                ViewGroup.LayoutParams(-2, -2),
            )
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

    /**
     * The launcher widgets (Ahora, Chat rápido) through their REAL renderer,
     * with sample data, at the cell sizes of a Pixel: `lw_<name>.png`.
     */
    private fun renderLauncherWidgets(column: LinearLayout) {
        val out = getExternalFilesDir("widget-gallery")?.apply { mkdirs() }
        val now = System.currentTimeMillis()
        val chat = HermesWidgetState(
            configured = true,
            instanceId = "gallery",
            instanceLabel = "Home server",
            connectionState = HermesWidgetConnectionState.CONNECTED,
            sessionId = "gallery-session",
            sessionTitle = "Prueba con subagentes, herramientas y pensamiento",
            agentState = HermesWidgetAgentState.TOOL_EXECUTION,
            toolName = "Terminal",
            lastActivityAtMs = now - 42_000,
            updatedAtMs = now,
        )
        val bots = BotModeWidgetState(
            connectionId = "gallery",
            connectionLabel = "Home server",
            connected = true,
            bots = listOf(
                bot("builder", "Builder", WidgetBotState.WORKING, listOf("Console Devs"), room = "Console Devs"),
                bot("review", "Review", WidgetBotState.DONE, listOf("Diseño de píldora de estado")),
                bot("lead", "Lead", WidgetBotState.IDLE),
            ),
            approvals = listOf(
                WidgetApproval("a1", "Lead", "rm -rf build/", face("lead", "needs"), "{}", open("lead"), true),
            ),
            updatedAtMs = now,
        )
        val calm = chat.copy(agentState = HermesWidgetAgentState.IDLE, toolName = null)
        val quiet = bots.copy(approvals = emptyList(), bots = bots.bots.takeLast(2))
        val old = now - 3 * 60 * 60_000
        // Schema 2: the app lists every chat that runs or waits.
        val listed = chat.copy(
            schemaVersion = 2,
            agentState = HermesWidgetAgentState.WAITING_APPROVAL,
            toolName = null,
            active = listOf(
                HermesWidgetChatActivity(
                    "gallery-session", "Limpiar el build", null, HermesWidgetAgentState.WAITING_APPROVAL, null, now - 42_000,
                    HermesWidgetNeed("req-1", false, "rm -rf build/", "{}"),
                ),
                HermesWidgetChatActivity(
                    "gallery-other", "Prueba con subagentes, herramientas y pensamiento", "builder",
                    HermesWidgetAgentState.TOOL_EXECUTION, "Terminal", now - 134_000, null,
                ),
            ),
        )
        val samples = listOf(
            Triple("chat_need", listed, quietBots(bots)),
            Triple("chat_run", listed.copy(active = listed.active.drop(1), agentState = HermesWidgetAgentState.IDLE), quietBots(bots)),
            Triple("need", chat, bots),
            Triple("run", chat, quiet),
            Triple("calm", calm, quiet),
            Triple("offline", calm.copy(updatedAtMs = old, lastActivityAtMs = old), BotModeWidgetState()),
            Triple("setup", HermesWidgetState(), BotModeWidgetState()),
        )
        val sizes = listOf("2x1" to (184f to 98f), "4x1" to (380f to 98f), "2x2" to (184f to 208f), "4x2" to (380f to 208f), "4x3" to (380f to 318f),
            "5x3" to (395f to 288f), "3x2" to (235f to 190f), "5x4" to (395f to 384f), "2x3" to (160f to 288f))
        val scenes = mutableListOf<Scene>()
        fun shot(name: String, subject: LauncherWidgetSubject, data: LauncherWidgetData, size: LauncherWidgetSize) {
            scenes += Scene(name, subject, data, size)
            val host = FrameLayout(this)
            val view = LauncherWidgetRenderer(this, data, size, false).build(subject).apply(this, host)
            val w = dp(size.width.toInt())
            val h = dp(size.height.toInt())
            host.addView(view, FrameLayout.LayoutParams(w, h))
            host.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
            host.layout(0, 0, w, h)
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            host.draw(android.graphics.Canvas(bitmap))
            out?.let { dir -> File(dir, "lw_$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } }
            column.addView(TextView(this).apply { text = "lw_$name"; setTextColor(Color.WHITE) })
            column.addView(ImageView(this).apply { setImageBitmap(bitmap) }, LinearLayout.LayoutParams(w, h).apply { bottomMargin = dp(12) })
        }
        for ((state, chatState, botState) in samples) {
            val data = LauncherWidgetData(now, chatState, botState)
            for ((cells, pair) in sizes) {
                shot("ahora_${state}_$cells", LauncherWidgetSubject.AHORA, data, LauncherWidgetSize(pair.first, pair.second))
            }
        }
        val hour = 60 * 60_000L
        val cron = CronWidgetState(
            connectionId = "gallery",
            updatedAtMs = now,
            jobs = listOf(
                CronWidgetJob("j1", "Salida RRHH", now + 2 * hour, now - 70 * hour, CronWidgetResult.OK, false, null),
                CronWidgetJob("j2", "Resumen del día", now + 6 * hour, now - 18 * hour, CronWidgetResult.OK, false, null),
                CronWidgetJob("j3", "Copia de seguridad", now + 12 * hour, now - 5 * hour, CronWidgetResult.FAILED, false, null),
                CronWidgetJob("j4", "Entrada RRHH", now + 17 * hour, now - 1 * hour, CronWidgetResult.OK, false, null),
                CronWidgetJob("j5", "Informe semanal", now + 90 * hour, now - 78 * hour, CronWidgetResult.OK, false, null),
                CronWidgetJob("j6", "Limpieza", 0, 0, CronWidgetResult.NONE, true, null),
            ),
        )
        val data = LauncherWidgetData(now, chat, bots, cron)
        shot("quick_2x1", LauncherWidgetSubject.QUICK, data, LauncherWidgetSize(184f, 98f))
        shot("quick_4x1", LauncherWidgetSubject.QUICK, data, LauncherWidgetSize(380f, 98f))
        val oldCron = LauncherWidgetData(now, chat, bots, cron.copy(updatedAtMs = now - 3 * hour))
        val noCron = LauncherWidgetData(now, chat, bots)
        for ((cells, pair) in sizes) {
            val size = LauncherWidgetSize(pair.first, pair.second)
            shot("cron_$cells", LauncherWidgetSubject.CRON, data, size)
            shot("cron_old_$cells", LauncherWidgetSubject.CRON, oldCron, size)
        }
        shot("cron_none_2x1", LauncherWidgetSubject.CRON, noCron, LauncherWidgetSize(184f, 98f))
        shot("cron_none_4x2", LauncherWidgetSubject.CRON, noCron, LauncherWidgetSize(380f, 208f))
        // Bots and Salas: a team with every state, and the same one with old data.
        val devs = WidgetRoom(
            id = "r-devs", name = "Console Devs", working = true,
            members = listOf(member("builder", "Builder", "working"), member("review", "Review", "queued"), member("lead", "Lead", "idle"), member("scout", "Scout", "idle")),
            lastSpeaker = "Review", lastMessage = "Bien, un detalle de nombres.",
            openPayload = open("r-devs"), stopPayload = null, phase = "working", sinceMs = now - 134_000,
        )
        val ideas = WidgetRoom(
            id = "r-ideas", name = "Ideas", working = false,
            members = listOf(member("review", "Review", "idle"), member("scout", "Scout", "idle")),
            lastSpeaker = "Review", lastMessage = "¿Y si el sprite corre por encima de la píldora?",
            openPayload = open("r-ideas"), stopPayload = null,
        )
        val team = bots.copy(
            bots = listOf(
                bot("lead", "Lead", WidgetBotState.NEEDS_YOU, room = "Console Devs"),
                bot("builder", "Builder", WidgetBotState.WORKING, room = "Console Devs"),
                bot("review", "Review", WidgetBotState.DONE, listOf("Diseño de píldora de estados")),
                bot("scout", "Scout", WidgetBotState.IDLE, role = "Investigación"),
            ),
            rooms = listOf(devs, ideas),
        )
        val board = TasksWidgetState(
            connectionId = "gallery",
            updatedAtMs = now,
            running = 2,
            pending = 3,
            tasks = listOf(
                TaskWidgetTask("t1", "Publicar 1.2.15", TaskWidgetState.RUNNING, "Builder", null),
                TaskWidgetTask("t2", "Rediseñar Inicio", TaskWidgetState.RUNNING, "Lead", null),
                TaskWidgetTask("t3", "Probar GPT-Live con pantalla apagada", TaskWidgetState.PENDING, null, null),
                TaskWidgetTask("t4", "Notas de la versión 1.2.15", TaskWidgetState.PENDING, null, null),
                TaskWidgetTask("t5", "Revisar permisos de la sala Ideas", TaskWidgetState.PENDING, null, null),
            ),
        )
        val withTasks = LauncherWidgetData(now, chat, team, cron, board)
        val oldTasks = LauncherWidgetData(now, chat, team, cron, board.copy(updatedAtMs = now - 3 * hour))
        for ((cells, pair) in sizes) {
            val size = LauncherWidgetSize(pair.first, pair.second)
            shot("tareas_$cells", LauncherWidgetSubject.TASKS, withTasks, size)
            shot("tareas_old_$cells", LauncherWidgetSubject.TASKS, oldTasks, size)
        }
        val recent = ChatsWidgetState(
            connectionId = "gallery",
            updatedAtMs = now,
            chats = listOf(
                ChatWidgetChat("gallery-other", "Prueba con subagentes, herramientas y pensamiento", null, now - 60_000, null),
                ChatWidgetChat("gallery-session", "Limpiar el build", "Listo, el build está limpio", now - 5 * 60_000, null),
                ChatWidgetChat("c3", "Saludo amistoso", "¡Buenos días! ¿Qué hacemos hoy?", now - 2 * hour, null),
                ChatWidgetChat("c4", "Arreglar selección de modelo", "Ya elige el de reserva si falla", now - 26 * hour, null),
                ChatWidgetChat("c5", "Notas de la versión", "Aquí tienes el borrador", now - 50 * hour, null),
            ),
        )
        val long = ChatsWidgetState(
            connectionId = "gallery",
            updatedAtMs = now,
            chats = listOf(
                ChatWidgetChat("m1", "Revisar por qué el widget de chats repite las conversaciones cuando se actualiza varias veces", "Listo: era el contenedor que no se vaciaba", now - 3 * 60_000, null),
                ChatWidgetChat("m2", "Hola", null, now - 40 * 60_000, null),
                ChatWidgetChat("m3", "Saludo", "¡Buenos días!", now - 3 * hour, null),
                ChatWidgetChat("m4", "Plan de migración del servidor a otra máquina con más memoria", "Primero copiamos los datos y después probamos", now - 20 * hour, null),
                ChatWidgetChat("m5", "Receta", "Aquí tienes la receta completa", now - 30 * hour, null),
                ChatWidgetChat("m6", "Notas de la versión 1.2.15 para la tienda y para GitHub", "Borrador listo", now - 52 * hour, null),
                ChatWidgetChat("m7", "Pruebas", "Todo en verde", now - 80 * hour, null),
                ChatWidgetChat("m8", "Ideas para el widget de tareas", null, now - 200 * hour, null),
            ),
        )
        val noChat = LauncherWidgetData(now, calm, team, cron, board, ChatsWidgetState(connectionId = "gallery", updatedAtMs = now))
        val unknownChats = LauncherWidgetData(now, calm, team, cron, board)
        val longChats = LauncherWidgetData(now, chat.copy(schemaVersion = 2, active = listOf(
            HermesWidgetChatActivity("m2", "Hola", null, HermesWidgetAgentState.THINKING, null, now - 20_000, null),
        )), team, cron, board, long)
        val staleLong = LauncherWidgetData(now, calm, team, cron, board, long.copy(updatedAtMs = now - 3 * hour))
        for ((cells, pair) in sizes) {
            val size = LauncherWidgetSize(pair.first, pair.second)
            shot("chats_long_$cells", LauncherWidgetSubject.CHATS, longChats, size)
            shot("chats_stale8_$cells", LauncherWidgetSubject.CHATS, staleLong, size)
            shot("chats_none_$cells", LauncherWidgetSubject.CHATS, noChat, size)
            shot("chats_unknown_$cells", LauncherWidgetSubject.CHATS, unknownChats, size)
        }
        val withChats = LauncherWidgetData(now, listed, team, cron, board, recent)
        val oldChats = LauncherWidgetData(now, calm.copy(updatedAtMs = old, lastActivityAtMs = old), team, cron, board, recent.copy(updatedAtMs = now - 3 * hour))
        for ((cells, pair) in sizes) {
            val size = LauncherWidgetSize(pair.first, pair.second)
            shot("chats_$cells", LauncherWidgetSubject.CHATS, withChats, size)
            shot("chats_old_$cells", LauncherWidgetSubject.CHATS, oldChats, size)
        }
        val live = LauncherWidgetData(now, chat, team)
        val gone = LauncherWidgetData(now, chat, team.copy(updatedAtMs = now - 3 * hour))
        for ((cells, pair) in sizes) {
            val size = LauncherWidgetSize(pair.first, pair.second)
            shot("bots_$cells", LauncherWidgetSubject.BOTS, live, size)
            shot("bots_old_$cells", LauncherWidgetSubject.BOTS, gone, size)
            shot("salas_$cells", LauncherWidgetSubject.ROOMS, live, size)
            shot("salas_old_$cells", LauncherWidgetSubject.ROOMS, gone, size)
        }

        reapplyCheck(scenes, out)
    }

    private class Scene(val name: String, val subject: LauncherWidgetSubject, val data: LauncherWidgetData, val size: LauncherWidgetSize)

    /**
     * What a launcher does with an update: when the new drawing has the layout
     * it already shows, it applies the new actions onto the views it holds. A
     * drawing that only looks right on a fresh inflate is wrong on a phone.
     * Every scene of a subject and size is shown after every other one (and
     * the same one three times in a row) on ONE view held like that, and must
     * come out pixel-identical to a fresh inflate. Result: `reapply.txt`.
     */
    private fun reapplyCheck(scenes: List<Scene>, out: File?) {
        fun render(rv: android.widget.RemoteViews, size: LauncherWidgetSize, held: Pair<Int, View>?): Pair<Int, View> {
            val w = dp(size.width.toInt())
            val h = dp(size.height.toInt())
            val view: View
            if (held != null && held.first == rv.layoutId) {
                rv.reapply(this, held.second)
                view = held.second
            } else {
                view = rv.apply(this, FrameLayout(this))
            }
            view.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
            view.layout(0, 0, w, h)
            return rv.layoutId to view
        }
        fun draw(view: View, size: LauncherWidgetSize): Bitmap {
            val bitmap = Bitmap.createBitmap(dp(size.width.toInt()), dp(size.height.toInt()), Bitmap.Config.ARGB_8888)
            view.draw(android.graphics.Canvas(bitmap))
            return bitmap
        }
        val report = StringBuilder()
        var checked = 0
        var bad = 0
        for (group in scenes.groupBy { it.subject to it.size }.values) {
            val order = group + group.reversed() + listOf(group.first(), group.first(), group.first())
            var held: Pair<Int, View>? = null
            for (scene in order) {
                fun build() = LauncherWidgetRenderer(this, scene.data, scene.size, false).build(scene.subject)
                held = render(build(), scene.size, held)
                val got = draw(held.second, scene.size)
                val fresh = render(build(), scene.size, null)
                var want = draw(fresh.second, scene.size)
                checked++
                if (!got.sameAs(want)) {
                    // A running timer may have ticked between the two: look again.
                    held = render(build(), scene.size, held)
                    want = draw(render(build(), scene.size, null).second, scene.size)
                    if (!draw(held.second, scene.size).sameAs(want)) {
                        bad++
                        report.append("MISMATCH ${scene.name} ${scene.subject} ${scene.size}\n")
                        out?.let { dir ->
                            File(dir, "reapply_bad_${bad}_${scene.name}_got.png").outputStream().use { got.compress(Bitmap.CompressFormat.PNG, 100, it) }
                            File(dir, "reapply_bad_${bad}_${scene.name}_want.png").outputStream().use { want.compress(Bitmap.CompressFormat.PNG, 100, it) }
                        }
                    }
                }
            }
        }
        report.append("reapply: $checked drawings checked, $bad differ from a fresh inflate\n")
        out?.let { File(it, "reapply.txt").writeText(report.toString()) }
        android.util.Log.i("WidgetGallery", report.toString())
    }

    private fun quietBots(bots: BotModeWidgetState): BotModeWidgetState =
        bots.copy(approvals = emptyList(), bots = bots.bots.takeLast(2))

    /** Widget-picker previews: the real previewLayout XML, inflated. */
    private fun renderPickerPreviews(column: LinearLayout) {
        val out = getExternalFilesDir("widget-gallery")?.apply { mkdirs() }
        val previews = listOf(
            "picker_ahora" to Pair(R.layout.lw_preview_ahora, DpSize(380.dp, 98.dp)),
            "picker_chat_rapido" to Pair(R.layout.lw_quick_small, DpSize(184.dp, 98.dp)),
            "picker_cron" to Pair(R.layout.lw_strip, DpSize(184.dp, 98.dp)),
            "picker_bots" to Pair(R.layout.lw_preview_bots, DpSize(184.dp, 98.dp)),
            "picker_salas" to Pair(R.layout.lw_preview_rooms, DpSize(184.dp, 98.dp)),
            "picker_tareas" to Pair(R.layout.lw_preview_tasks, DpSize(184.dp, 98.dp)),
            "picker_chats" to Pair(R.layout.lw_preview_chats, DpSize(184.dp, 98.dp)),
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
}
