package com.hermesagent.hermes_android

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

/**
 * The pictures of the launcher widgets, drawn by the app in its own theme.
 *
 * The app draws one PNG per placed widget and size and writes where they
 * are under [IMAGES_KEY]; this side shows the picture in an ImageView and
 * lays a transparent tap target over each zone the drawing named, so what
 * is tapped is exactly what is seen. The app learns the sizes to draw from
 * [LauncherWidgetSizes], written here on every redraw.
 *
 * A picture is only used while it is true: drawn from the snapshots now
 * stored (not older ones), at this screen's density and font scale, before
 * the moment the drawing said it stops being true, and within the bitmap
 * memory a RemoteViews may carry. Otherwise the native layouts draw, as they
 * always did, and the next publication from the app brings the picture back.
 */
internal const val LW_IMAGES_KEY = "hermes_widget_lw_images_v1"
internal const val LW_SIZES_KEY = "hermes_widget_lw_sizes_v1"

/** A tap target of a picture, in dp from the widget's top-left corner. */
internal data class LauncherWidgetZone(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
    val kind: String,
    val label: String,
    val payload: String?,
    val instanceId: String?,
    val sessionId: String?,
    val target: String?,
)

internal data class LauncherWidgetImage(
    val path: String,
    val widthPx: Int,
    val heightPx: Int,
    val dpWidth: Int,
    val dpHeight: Int,
    val description: String,
    val validUntilMs: Long?,
    val zones: List<LauncherWidgetZone>,
)

internal class LauncherWidgetImageManifest(
    val stampMs: Long,
    val sourcesMs: Long,
    val density: Float,
    val fontScale: Float,
    val images: Map<String, LauncherWidgetImage>,
) {
    fun find(subject: LauncherWidgetSubject, size: LauncherWidgetSize): LauncherWidgetImage? =
        images["${subject.key}:${Math.round(size.width)}x${Math.round(size.height)}"]

    /** The next moment one of the pictures stops being true, after [nowMs]. */
    fun nextExpiryMs(nowMs: Long): Long? =
        images.values.mapNotNull { it.validUntilMs }.filter { it > nowMs }.minOrNull()

    companion object {
        fun load(context: Context): LauncherWidgetImageManifest? =
            parse(
                try {
                    HomeWidgetPlugin.getData(context).getString(LW_IMAGES_KEY, null)
                } catch (_: Exception) {
                    null
                },
            )

        fun parse(raw: String?): LauncherWidgetImageManifest? {
            if (raw.isNullOrEmpty()) return null
            return try {
                val json = JSONObject(raw)
                if (json.optInt("v") != 1) return null
                val images = mutableMapOf<String, LauncherWidgetImage>()
                val listed = json.optJSONObject("images") ?: JSONObject()
                for (key in listed.keys()) {
                    val image = listed.optJSONObject(key) ?: continue
                    val path = image.optString("path").takeIf { it.isNotEmpty() } ?: continue
                    images[key] =
                        LauncherWidgetImage(
                            path = path,
                            widthPx = image.optInt("w"),
                            heightPx = image.optInt("h"),
                            dpWidth = image.optInt("dp_w"),
                            dpHeight = image.optInt("dp_h"),
                            description = image.optString("desc"),
                            validUntilMs = image.optLong("valid_until_ms").takeIf { it > 0 },
                            zones = image.optJSONArray("zones").zones(),
                        )
                }
                LauncherWidgetImageManifest(
                    stampMs = json.optLong("stamp_ms"),
                    sourcesMs = json.optLong("sources_ms"),
                    density = json.optDouble("density", 0.0).toFloat(),
                    fontScale = json.optDouble("font_scale", 1.0).toFloat(),
                    images = images,
                )
            } catch (_: Exception) {
                null
            }
        }

        private fun JSONArray?.zones(): List<LauncherWidgetZone> {
            this ?: return emptyList()
            return (0 until length()).mapNotNull { i ->
                val z = optJSONObject(i) ?: return@mapNotNull null
                LauncherWidgetZone(
                    left = z.optDouble("l").toFloat(),
                    top = z.optDouble("t").toFloat(),
                    right = z.optDouble("r").toFloat(),
                    bottom = z.optDouble("b").toFloat(),
                    kind = z.optString("kind"),
                    label = z.optString("label"),
                    payload = z.optString("payload").takeIf { z.has("payload") },
                    instanceId = z.optString("instance").takeIf { z.has("instance") },
                    sessionId = z.optString("session").takeIf { z.has("session") },
                    target = z.optString("target").takeIf { z.has("target") },
                )
            }.take(MAX_ZONES)
        }

        const val MAX_ZONES = 16
    }
}

/**
 * The bitmap bytes one widget update may still carry. A RemoteViews is
 * allowed about 1.5 times the screen in bitmap bytes, counted over every
 * size of one update (Android 12 sends one drawing per orientation in the
 * same update); this keeps a margin under that limit.
 */
internal class LauncherWidgetImageBudget(var remainingBytes: Long) {
    companion object {
        /** Share of the system limit one update uses. */
        const val SHARE = 0.8f

        fun forScreen(widthPx: Int, heightPx: Int): LauncherWidgetImageBudget =
            LauncherWidgetImageBudget((1.5f * widthPx * heightPx * 4 * SHARE).toLong())

        fun of(context: Context): LauncherWidgetImageBudget {
            val metrics = context.resources.displayMetrics
            return forScreen(metrics.widthPixels, metrics.heightPixels)
        }
    }
}

/** Builds the RemoteViews of a picture, or null when the picture cannot be used. */
internal object LauncherWidgetImages {
    /** Density and font scale must match the drawing's within this. */
    private const val SCALE_TOLERANCE = 0.02f

    fun views(
        context: Context,
        manifest: LauncherWidgetImageManifest?,
        data: LauncherWidgetData,
        subject: LauncherWidgetSubject,
        size: LauncherWidgetSize,
        renderer: LauncherWidgetRenderer,
        budget: LauncherWidgetImageBudget,
    ): RemoteViews? {
        manifest ?: return null
        val image = manifest.find(subject, size) ?: return null
        if (!current(context, manifest, image, data)) return null
        val density = context.resources.displayMetrics.density
        val bitmap = decode(image, budget) ?: return null
        val views = RemoteViews(context.packageName, R.layout.lw_image)
        views.setImageViewBitmap(R.id.lw_picture, bitmap)
        views.setContentDescription(R.id.lw_picture, image.description)
        // The launcher draws this onto the views it already holds.
        views.removeAllViews(R.id.lw_zones)
        val widthPx = Math.round(size.width * density)
        val heightPx = Math.round(size.height * density)
        for (zone in image.zones) {
            val intent = renderer.intentFor(zone) ?: continue
            val hit = RemoteViews(context.packageName, R.layout.lw_zone)
            hit.setViewPadding(
                R.id.lw_zone,
                Math.round(zone.left * density).coerceIn(0, widthPx),
                Math.round(zone.top * density).coerceIn(0, heightPx),
                (widthPx - Math.round(zone.right * density)).coerceIn(0, widthPx),
                (heightPx - Math.round(zone.bottom * density)).coerceIn(0, heightPx),
            )
            hit.setContentDescription(R.id.lw_zone_hit, zone.label)
            hit.setOnClickPendingIntent(R.id.lw_zone_hit, intent)
            views.addView(R.id.lw_zones, hit)
        }
        return views
    }

    /** The picture still tells the truth about what is stored now, here. */
    internal fun current(
        context: Context,
        manifest: LauncherWidgetImageManifest,
        image: LauncherWidgetImage,
        data: LauncherWidgetData,
    ): Boolean {
        val config = context.resources.configuration
        val density = context.resources.displayMetrics.density
        return matches(manifest, image, data.latestSourceMs, data.nowMs, density, config.fontScale)
    }

    /** [current] without a context, for the tests. */
    internal fun matches(
        manifest: LauncherWidgetImageManifest,
        image: LauncherWidgetImage,
        latestSourceMs: Long,
        nowMs: Long,
        density: Float,
        fontScale: Float,
    ): Boolean {
        if (manifest.sourcesMs < latestSourceMs) return false
        image.validUntilMs?.let { if (nowMs >= it) return false }
        return near(manifest.density, density) && near(manifest.fontScale, fontScale)
    }

    private fun near(a: Float, b: Float): Boolean = a > 0 && b > 0 && Math.abs(a - b) / b <= SCALE_TOLERANCE

    /**
     * The sample size that brings a [width] x [height] picture within
     * [budgetBytes] (1, 2, 4 or 8: the launcher stretches it back to the
     * cell), or null when even an eighth does not fit.
     */
    internal fun sampleFor(width: Int, height: Int, budgetBytes: Long): Int? {
        var sample = 1
        while (bytesOf(width, height, sample) > budgetBytes && sample < 8) sample *= 2
        return sample.takeIf { bytesOf(width, height, it) <= budgetBytes }
    }

    /** The bitmap within what the update may still carry; null when it cannot fit. */
    private fun decode(image: LauncherWidgetImage, budget: LauncherWidgetImageBudget): Bitmap? {
        val file = File(image.path)
        if (!file.isFile || file.length() > MAX_FILE_BYTES) return null
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(image.path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            val sample = sampleFor(bounds.outWidth, bounds.outHeight, budget.remainingBytes) ?: return null
            val bitmap =
                BitmapFactory.decodeFile(image.path, BitmapFactory.Options().apply { inSampleSize = sample })
                    ?: return null
            budget.remainingBytes -= bitmap.allocationByteCount.toLong()
            bitmap
        } catch (_: Exception) {
            null
        }
    }

    internal fun bytesOf(width: Int, height: Int, sample: Int): Long =
        (width / sample).toLong() * (height / sample).toLong() * 4L

    private const val MAX_FILE_BYTES = 4_000_000L
}

/**
 * Tells the app the sizes to draw: every placed widget's sizes in dp, per
 * subject, with the density and font scale they are shown at. Written on
 * every redraw, only when it changed.
 */
internal object LauncherWidgetSizes {
    /** Called when the stored sizes changed, while the app's engine is alive. */
    @Volatile
    var onChanged: (() -> Unit)? = null

    private val receivers: Map<Class<out AppWidgetProvider>, LauncherWidgetSubject> =
        mapOf(
            NewSessionWidgetProvider::class.java to LauncherWidgetSubject.AHORA,
            HermesCompactWidgetProvider::class.java to LauncherWidgetSubject.QUICK,
            HermesControlWidgetProvider::class.java to LauncherWidgetSubject.QUICK,
            HermesCronWidgetProvider::class.java to LauncherWidgetSubject.CRON,
            HermesTasksWidgetProvider::class.java to LauncherWidgetSubject.TASKS,
            HermesChatsWidgetProvider::class.java to LauncherWidgetSubject.CHATS,
        )

    fun record(context: Context, manager: AppWidgetManager) {
        val sizes = linkedMapOf<String, MutableList<LauncherWidgetSize>>()
        for ((receiver, subject) in receivers) {
            val ids =
                try {
                    manager.getAppWidgetIds(ComponentName(context, receiver))
                } catch (_: Exception) {
                    IntArray(0)
                }
            for (id in ids) {
                val options =
                    try {
                        manager.getAppWidgetOptions(id)
                    } catch (_: Exception) {
                        continue
                    }
                val list = sizes.getOrPut(subject.key) { mutableListOf() }
                for (size in LauncherWidgetSize.of(context, options)) {
                    val rounded = LauncherWidgetSize(Math.round(size.width).toFloat(), Math.round(size.height).toFloat())
                    if (rounded !in list) list += rounded
                }
            }
        }
        val json =
            JSONObject().apply {
                put("v", 1)
                put("density", context.resources.displayMetrics.density.toDouble())
                put("font_scale", context.resources.configuration.fontScale.toDouble())
                put("locale", context.resources.configuration.locales[0].toLanguageTag())
                put(
                    "sizes",
                    JSONObject().apply {
                        for ((key, list) in sizes) {
                            put(key, JSONArray().apply { for (s in list) put(JSONArray().put(s.width.toInt()).put(s.height.toInt())) })
                        }
                    },
                )
            }.toString()
        try {
            val prefs = HomeWidgetPlugin.getData(context)
            if (prefs.getString(LW_SIZES_KEY, null) == json) return
            prefs.edit().putString(LW_SIZES_KEY, json).apply()
        } catch (_: Exception) {
            return
        }
        onChanged?.invoke()
    }
}
