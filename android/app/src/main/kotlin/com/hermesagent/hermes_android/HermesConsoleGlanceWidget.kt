package com.hermesagent.hermes_android

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.RowScope
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontStyle
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import es.antonborri.home_widget.HomeWidgetGlanceState
import es.antonborri.home_widget.HomeWidgetGlanceStateDefinition
import java.util.concurrent.TimeUnit

enum class HermesWidgetVariant {
    COMPACT,
    CONTROL,
    DASHBOARD,
}

internal enum class WidgetContentTier {
    MINIMAL,
    COMPACT,
    STANDARD,
    EXPANDED,
}

/**
 * Launcher grids do not agree on the physical dp represented by one cell.
 * Providers keep a stable cell span, while this profile adapts their internal
 * density to the exact bounds supplied by the current host.
 */
private data class WidgetLayoutProfile(
    val width: Dp,
    val height: Dp,
    val horizontalPadding: Dp,
    val verticalPadding: Dp,
    val tier: WidgetContentTier,
) {
    companion object {
        fun from(width: Dp, height: Dp, variant: HermesWidgetVariant): WidgetLayoutProfile {
            val availableTier =
                when {
                    width < 100.dp || height < 54.dp -> WidgetContentTier.MINIMAL
                    width < 190.dp || height < 100.dp -> WidgetContentTier.COMPACT
                    width < 270.dp || height < 190.dp -> WidgetContentTier.STANDARD
                    else -> WidgetContentTier.EXPANDED
                }
            val variantCeiling =
                when (variant) {
                    HermesWidgetVariant.COMPACT -> WidgetContentTier.COMPACT
                    HermesWidgetVariant.CONTROL -> WidgetContentTier.STANDARD
                    HermesWidgetVariant.DASHBOARD -> WidgetContentTier.EXPANDED
                }
            val tier =
                if (availableTier.ordinal <= variantCeiling.ordinal) {
                    availableTier
                } else {
                    variantCeiling
                }
            return WidgetLayoutProfile(
                width = width,
                height = height,
                tier = tier,
                horizontalPadding = if (tier <= WidgetContentTier.COMPACT) 8.dp else 12.dp,
                verticalPadding =
                    when (tier) {
                        WidgetContentTier.MINIMAL -> 5.dp
                        WidgetContentTier.COMPACT -> 7.dp
                        WidgetContentTier.STANDARD -> 10.dp
                        WidgetContentTier.EXPANDED -> 12.dp
                    },
            )
        }
    }
}

class HermesConsoleGlanceWidget(
    private val variant: HermesWidgetVariant = HermesWidgetVariant.DASHBOARD,
) : GlanceAppWidget() {
    override val stateDefinition = HomeWidgetGlanceStateDefinition()
    // Each provider has a fixed cell size. Exact absorbs launcher host padding
    // while the variant remains stable and cannot collapse into another UI.
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val published = HermesWidgetState.from(
            es.antonborri.home_widget.HomeWidgetPlugin.getData(context),
        )
        HermesWidgetExpiryScheduler.replace(context, published)
        provideContent {
            val state = HermesWidgetState.from(currentState<HomeWidgetGlanceState>().preferences)
            HermesWidget(context, state, variant)
        }
    }
}

private data class WidgetPalette(
    val background: ColorProvider,
    val surface: ColorProvider,
    val text: ColorProvider,
    val secondary: ColorProvider,
    val accent: ColorProvider,
    val onAccent: ColorProvider,
    val outline: ColorProvider,
    val success: ColorProvider,
    val warning: ColorProvider,
    val error: ColorProvider,
)

private fun palette(theme: HermesWidgetTheme): WidgetPalette =
    when (theme) {
        HermesWidgetTheme.LIGHT ->
            WidgetPalette(
                background = ColorProvider(Color(0xFFF7F4EC)),
                surface = ColorProvider(Color(0xFFECE7DC)),
                text = ColorProvider(Color(0xFF1E1B16)),
                secondary = ColorProvider(Color(0xFF6E675C)),
                accent = ColorProvider(Color(0xFF8A6500)),
                onAccent = ColorProvider(Color.White),
                outline = ColorProvider(Color(0xFFD2C9B9)),
                success = ColorProvider(Color(0xFF327A55)),
                warning = ColorProvider(Color(0xFF9B6500)),
                error = ColorProvider(Color(0xFFB3261E)),
            )
        HermesWidgetTheme.OLED -> darkPalette(background = Color.Black)
        HermesWidgetTheme.DARK -> darkPalette(background = Color(0xFF09090C))
    }

private fun darkPalette(background: Color) =
    WidgetPalette(
        background = ColorProvider(background),
        surface = ColorProvider(Color(0xFF1A191D)),
        text = ColorProvider(Color(0xFFF3F0E8)),
        secondary = ColorProvider(Color(0xFFB9B4A9)),
        accent = ColorProvider(Color(0xFFE3B94A)),
        onAccent = ColorProvider(Color(0xFF201800)),
        outline = ColorProvider(Color(0xFF3A383E)),
        success = ColorProvider(Color(0xFF78C99B)),
        warning = ColorProvider(Color(0xFFFFC66A)),
        error = ColorProvider(Color(0xFFFF8A80)),
    )

@Composable
private fun HermesWidget(
    context: Context,
    state: HermesWidgetState,
    variant: HermesWidgetVariant,
) {
    val colors = palette(state.theme)
    val hostSize = LocalSize.current
    val layout = WidgetLayoutProfile.from(hostSize.width, hostSize.height, variant)
    val content =
        GlanceModifier
            .fillMaxSize()
            .background(colors.background)
            .padding(
                horizontal = layout.horizontalPadding,
                vertical = layout.verticalPadding,
            )
            .clickable(actionStartActivity(NewSessionLaunchContract.openAppIntent(context)))
    Box(modifier = content, contentAlignment = Alignment.TopStart) {
        if (!state.configured || state.instanceId == null) {
            if (variant == HermesWidgetVariant.COMPACT) {
                CompactSetupContent(context, state, colors)
            } else {
                SetupContent(context, state, colors)
            }
        } else {
            when (variant) {
                HermesWidgetVariant.COMPACT -> CompactContent(context, state, colors, layout)
                HermesWidgetVariant.CONTROL -> ControlContent(context, state, colors, layout)
                HermesWidgetVariant.DASHBOARD -> ExpandedContent(context, state, colors, layout)
            }
        }
    }
}

@Composable
private fun CompactSetupContent(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
) {
    Column(modifier = GlanceModifier.fillMaxSize()) {
        StatusLabel(context, state, colors, compact = false, roomy = false)
        Spacer(GlanceModifier.height(5.dp))
        Text(
            if (state.configured) {
                context.getString(R.string.hermes_widget_no_instance)
            } else {
                context.getString(R.string.hermes_widget_not_configured)
            },
            maxLines = 1,
            style = TextStyle(color = colors.secondary, fontSize = 10.sp),
        )
        Spacer(GlanceModifier.defaultWeight())
        ActionChip(
            context = context,
            label = context.getString(R.string.hermes_widget_setup_action),
            icon = R.drawable.ic_stat_hermes,
            colors = colors,
            highlighted = true,
            intent = NewSessionLaunchContract.openSetupIntent(context),
            modifier = GlanceModifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun SetupContent(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
) {
    Column(modifier = GlanceModifier.fillMaxSize()) {
        Header(context, state, colors, compact = false)
        Spacer(GlanceModifier.height(7.dp))
        Text(
            if (state.configured) {
                context.getString(R.string.hermes_widget_no_instance)
            } else {
                context.getString(R.string.hermes_widget_not_configured)
            },
            maxLines = 2,
            style = TextStyle(color = colors.secondary, fontSize = 11.sp),
        )
        Spacer(GlanceModifier.defaultWeight())
        ActionChip(
            context = context,
            label = context.getString(R.string.hermes_widget_setup_action),
            icon = R.drawable.ic_stat_hermes,
            colors = colors,
            highlighted = true,
            intent = NewSessionLaunchContract.openSetupIntent(context),
            modifier = GlanceModifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun CompactContent(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    layout: WidgetLayoutProfile,
) {
    if (layout.tier <= WidgetContentTier.COMPACT && layout.height < 104.dp) {
        CompactHorizontalContent(context, state, colors, layout)
        return
    }
    val roomy = layout.height >= 128.dp
    Column(modifier = GlanceModifier.fillMaxSize()) {
        StatusLabel(context, state, colors, compact = false, roomy = roomy)
        Spacer(GlanceModifier.height(if (roomy) 7.dp else 4.dp))
        Text(
            state.instanceLabel ?: context.getString(R.string.hermes_widget_not_configured),
            maxLines = 1,
            style = TextStyle(
                color = colors.text,
                fontSize = if (roomy) 12.sp else 10.5.sp,
                fontWeight = FontWeight.Medium,
            ),
        )
        Spacer(GlanceModifier.height(if (roomy) 8.dp else 5.dp))
        Box(
            modifier =
                GlanceModifier
                    .fillMaxWidth()
                    .height(if (roomy) 30.dp else 24.dp)
                    .background(colors.surface)
                    .cornerRadius(10.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                agentStatusLabel(context, state),
                maxLines = 1,
                style = TextStyle(
                    color = colors.accent,
                    fontSize = if (roomy) 10.5.sp else 9.5.sp,
                    fontWeight = FontWeight.Medium,
                ),
            )
        }
        Spacer(GlanceModifier.defaultWeight())
        Row(modifier = GlanceModifier.fillMaxWidth()) {
            CompactActionButton(
                label = context.getString(R.string.hermes_widget_new_chat),
                icon = R.drawable.ic_new_session_widget_add,
                colors = colors,
                highlighted = true,
                intent = NewSessionLaunchContract.newIntent(
                    context,
                    NewSessionLaunchContract.SOURCE_WIDGET,
                    NewSessionLaunchTarget.COMPOSER,
                    requestedInstanceId = state.instanceId,
                ),
                modifier = GlanceModifier.defaultWeight(),
                height = if (roomy) 42.dp else 34.dp,
            )
            Spacer(GlanceModifier.width(6.dp))
            CompactActionButton(
                label = context.getString(R.string.hermes_widget_voice),
                icon = R.drawable.ic_new_session_widget_voice,
                colors = colors,
                highlighted = false,
                intent = NewSessionLaunchContract.newIntent(
                    context,
                    NewSessionLaunchContract.SOURCE_WIDGET,
                    NewSessionLaunchTarget.VOICE,
                    requestedInstanceId = state.instanceId,
                ),
                modifier = GlanceModifier.defaultWeight(),
                height = if (roomy) 42.dp else 34.dp,
            )
        }
    }
}

@Composable
private fun CompactHorizontalContent(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    layout: WidgetLayoutProfile,
) {
    val minimal = layout.tier == WidgetContentTier.MINIMAL
    val includeVoice = !minimal && layout.width >= 145.dp
    Row(
        modifier = GlanceModifier.fillMaxSize(),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        Column(modifier = GlanceModifier.defaultWeight()) {
            StatusLabel(context, state, colors, compact = minimal, roomy = false)
            if (!minimal) {
                Spacer(GlanceModifier.height(3.dp))
                Text(
                    state.instanceLabel ?: context.getString(R.string.hermes_widget_not_configured),
                    maxLines = 1,
                    style = TextStyle(
                        color = colors.text,
                        fontSize = 9.5.sp,
                        fontWeight = FontWeight.Medium,
                    ),
                )
            }
        }
        Spacer(GlanceModifier.width(6.dp))
        CompactActionButton(
            label = context.getString(R.string.hermes_widget_new_chat),
            icon = R.drawable.ic_new_session_widget_add,
            colors = colors,
            highlighted = true,
            intent = NewSessionLaunchContract.newIntent(
                context,
                NewSessionLaunchContract.SOURCE_WIDGET,
                NewSessionLaunchTarget.COMPOSER,
                requestedInstanceId = state.instanceId,
            ),
            modifier = GlanceModifier.width(32.dp),
            height = 32.dp,
        )
        if (includeVoice) {
            Spacer(GlanceModifier.width(5.dp))
            CompactActionButton(
                label = context.getString(R.string.hermes_widget_voice),
                icon = R.drawable.ic_new_session_widget_voice,
                colors = colors,
                highlighted = false,
                intent = NewSessionLaunchContract.newIntent(
                    context,
                    NewSessionLaunchContract.SOURCE_WIDGET,
                    NewSessionLaunchTarget.VOICE,
                    requestedInstanceId = state.instanceId,
                ),
                modifier = GlanceModifier.width(32.dp),
                height = 32.dp,
            )
        }
    }
}

@Composable
private fun CompactActionButton(
    label: String,
    icon: Int,
    colors: WidgetPalette,
    highlighted: Boolean,
    intent: android.content.Intent,
    modifier: GlanceModifier,
    height: Dp = 34.dp,
) {
    val background = if (highlighted) colors.accent else colors.surface
    val foreground = if (highlighted) colors.onAccent else colors.text
    Box(
        modifier =
            modifier
                .height(height)
                .background(background)
                .cornerRadius(11.dp)
                .clickable(actionStartActivity(intent)),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            provider = ImageProvider(icon),
            contentDescription = label,
            modifier = GlanceModifier.size(15.dp),
            colorFilter = ColorFilter.tint(foreground),
        )
    }
}

@Composable
private fun ControlContent(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    layout: WidgetLayoutProfile,
) {
    if (layout.tier == WidgetContentTier.MINIMAL) {
        CompactHorizontalContent(context, state, colors, layout)
        return
    }
    val roomy = layout.tier >= WidgetContentTier.STANDARD
    Column(modifier = GlanceModifier.fillMaxSize()) {
        Header(context, state, colors, roomy = roomy)
        Spacer(GlanceModifier.height(if (roomy) 5.dp else 4.dp))
        if (layout.tier >= WidgetContentTier.STANDARD) {
            InstanceAndModel(context, state, colors, roomy = true)
            if (!state.sessionTitle.isNullOrBlank()) {
                Spacer(GlanceModifier.height(3.dp))
                SessionOwner(context, state, colors)
            }
        } else {
            InstanceAndModel(context, state, colors)
        }
        if (layout.tier >= WidgetContentTier.STANDARD) {
            Spacer(GlanceModifier.height(6.dp))
            ContextRow(context, state, colors, roomy = roomy, stackAgent = false)
        }
        Spacer(GlanceModifier.defaultWeight())
        Spacer(GlanceModifier.height(if (roomy) 7.dp else 4.dp))
        Actions(context, state, colors, includeCurrent = false, roomy = roomy)
    }
}

@Composable
private fun SessionOwner(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
) {
    val title = state.sessionTitle ?: return
    Text(
        "${context.getString(R.string.hermes_widget_session)} · $title",
        maxLines = 1,
        style = TextStyle(color = colors.secondary, fontSize = 10.5.sp),
    )
}

@Composable
private fun ExpandedContent(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    layout: WidgetLayoutProfile,
) {
    if (layout.tier == WidgetContentTier.MINIMAL) {
        CompactHorizontalContent(context, state, colors, layout)
        return
    }
    if (layout.tier == WidgetContentTier.COMPACT) {
        ControlContent(context, state, colors, layout)
        return
    }
    val roomy = layout.tier == WidgetContentTier.EXPANDED
    Column(modifier = GlanceModifier.fillMaxSize()) {
        Header(context, state, colors, roomy = roomy)
        Spacer(GlanceModifier.height(if (roomy) 5.dp else 3.dp))
        InstanceAndModel(context, state, colors, roomy = roomy)
        Spacer(GlanceModifier.height(if (roomy) 9.dp else 6.dp))
        ExpandedStatusPanel(
            context = context,
            state = state,
            colors = colors,
            modifier = GlanceModifier.defaultWeight().fillMaxWidth(),
            roomy = roomy,
            showDetails = layout.tier == WidgetContentTier.EXPANDED,
        )
        Spacer(GlanceModifier.height(if (roomy) 9.dp else 6.dp))
        Actions(context, state, colors, includeCurrent = state.sessionId != null, roomy = roomy)
    }
}

@Composable
private fun ExpandedStatusPanel(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    modifier: GlanceModifier,
    roomy: Boolean,
    showDetails: Boolean,
) {
    Box(
        modifier =
            modifier
                .background(colors.surface)
                .cornerRadius(14.dp)
                .padding(if (roomy) 11.dp else 8.dp),
        contentAlignment = Alignment.TopStart,
    ) {
        Column(modifier = GlanceModifier.fillMaxWidth()) {
            ContextRow(context, state, colors, roomy = roomy, stackAgent = true)
            if (showDetails) ExpandedDetails(context, state, colors, roomy)
        }
    }
}

/**
 * Glance-backed columns accept at most ten direct children. Keeping the
 * optional session and metrics rows nested prevents the action row from being
 * silently truncated when both are present.
 */
@Composable
private fun ExpandedDetails(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    roomy: Boolean,
) {
    Column {
        if (!state.sessionTitle.isNullOrBlank()) {
            Spacer(GlanceModifier.height(if (roomy) 7.dp else 4.dp))
            SessionSummary(context, state, colors, roomy = roomy)
        }
        if (state.showAdvancedMetrics && hasAdvancedMetrics(state)) {
            Spacer(GlanceModifier.height(if (roomy) 7.dp else 4.dp))
            ExpandedMetrics(state, colors, roomy)
        }
    }
}

@Composable
private fun Header(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    compact: Boolean = false,
    roomy: Boolean = false,
) {
    Row(
        modifier = GlanceModifier.fillMaxWidth(),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        Text(
            context.getString(R.string.hermes_widget_brand),
            maxLines = 1,
            style = TextStyle(
                color = colors.text,
                fontSize = if (roomy) 15.sp else if (compact) 12.sp else 13.sp,
                fontWeight = FontWeight.Bold,
            ),
            modifier = GlanceModifier.defaultWeight(),
        )
        StatusLabel(context, state, colors, compact, roomy)
    }
}

@Composable
private fun StatusLabel(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    compact: Boolean,
    roomy: Boolean,
) {
    val stale = state.isStale(System.currentTimeMillis())
    val label = if (stale && state.configured) {
        context.getString(R.string.hermes_widget_stale_short)
    } else {
        connectionLabel(context, state.connectionState)
    }
    val tint = when {
        stale -> colors.warning
        state.connectionState == HermesWidgetConnectionState.CONNECTED -> colors.success
        state.connectionState == HermesWidgetConnectionState.CONNECTING -> colors.warning
        state.connectionState == HermesWidgetConnectionState.ERROR -> colors.error
        else -> colors.secondary
    }
    Row(verticalAlignment = Alignment.Vertical.CenterVertically) {
        Box(
            modifier = GlanceModifier.size(7.dp).background(tint).cornerRadius(4.dp),
        ) {}
        if (!compact) {
            Spacer(GlanceModifier.width(5.dp))
            Text(
                label,
                maxLines = 1,
                style = TextStyle(
                    color = tint,
                    fontSize = if (roomy) 10.5.sp else 9.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
        }
    }
}

@Composable
private fun InstanceAndModel(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    roomy: Boolean = false,
) {
    val instance = state.instanceLabel ?: context.getString(R.string.hermes_widget_not_configured)
    val model = state.model
    val value = if (model.isNullOrBlank()) instance else "$instance · $model"
    Text(
        "${context.getString(R.string.hermes_widget_instance)} · $value",
        maxLines = 1,
        style = TextStyle(color = colors.secondary, fontSize = if (roomy) 12.sp else 10.5.sp),
    )
}

@Composable
private fun ContextRow(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    roomy: Boolean = false,
    stackAgent: Boolean = false,
) {
    Column(modifier = GlanceModifier.fillMaxWidth()) {
      Row(
        modifier = GlanceModifier.fillMaxWidth(),
        verticalAlignment = Alignment.Vertical.CenterVertically,
      ) {
        Text(
            context.getString(R.string.hermes_widget_context),
            style = TextStyle(color = colors.secondary, fontSize = if (roomy) 11.sp else 9.5.sp),
        )
        Spacer(GlanceModifier.width(7.dp))
        if (state.contextPercent != null) {
            LinearProgressIndicator(
                progress = state.contextPercent / 100f,
                modifier = GlanceModifier.defaultWeight().height(5.dp),
                color = colors.accent,
                backgroundColor = colors.outline,
            )
            Spacer(GlanceModifier.width(7.dp))
            Text(
                "${state.contextPercent}%",
                style = TextStyle(
                    color = colors.text,
                    fontSize = if (roomy) 11.sp else 9.5.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
        } else {
            Text(
                context.getString(R.string.hermes_widget_unknown),
                style = TextStyle(color = colors.secondary, fontSize = 9.5.sp, fontStyle = FontStyle.Italic),
            )
        }
        if (!stackAgent) {
            Spacer(GlanceModifier.width(9.dp))
            Text(
                agentStatusLabel(context, state),
                maxLines = 1,
                style = TextStyle(color = colors.accent, fontSize = 9.5.sp),
            )
        }
      }
      if (stackAgent) {
          Spacer(GlanceModifier.height(4.dp))
          Row(
              modifier = GlanceModifier.fillMaxWidth(),
              verticalAlignment = Alignment.Vertical.CenterVertically,
          ) {
              if (!state.sessionTitle.isNullOrBlank()) {
                  Text(
                      "${context.getString(R.string.hermes_widget_session)} · ${state.sessionTitle}",
                      maxLines = 1,
                      style = TextStyle(color = colors.secondary, fontSize = 10.5.sp),
                      modifier = GlanceModifier.defaultWeight(),
                  )
                  Spacer(GlanceModifier.width(8.dp))
              }
              Text(
                  agentStatusLabel(context, state),
                  maxLines = 1,
                  style = TextStyle(
                      color = colors.accent,
                      fontSize = 10.5.sp,
                      fontWeight = FontWeight.Medium,
                  ),
              )
          }
      }
    }
}

@Composable
private fun SessionSummary(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    roomy: Boolean,
) {
    val title = state.sessionTitle ?: return
    Row(
        modifier = GlanceModifier.fillMaxWidth(),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        Image(
            provider = ImageProvider(R.drawable.ic_stat_hermes),
            contentDescription = null,
            modifier = GlanceModifier.size(if (roomy) 15.dp else 13.dp),
            colorFilter = ColorFilter.tint(colors.secondary),
        )
        Spacer(GlanceModifier.width(6.dp))
        Text(
            title,
            maxLines = 1,
            style = TextStyle(color = colors.text, fontSize = if (roomy) 11.5.sp else 11.sp),
            modifier = GlanceModifier.defaultWeight(),
        )
        Spacer(GlanceModifier.width(6.dp))
        LastActivity(context, state, colors, roomy = roomy)
    }
}

private fun hasAdvancedMetrics(state: HermesWidgetState): Boolean =
    state.inputTokens != null ||
        state.outputTokens != null ||
        state.cacheReadTokens != null ||
        state.cachePercent != null ||
        state.firstTokenLatencyMs != null

@Composable
private fun ExpandedMetrics(
    state: HermesWidgetState,
    colors: WidgetPalette,
    roomy: Boolean,
) {
    Column(modifier = GlanceModifier.fillMaxWidth()) {
        Row(modifier = GlanceModifier.fillMaxWidth()) {
            MetricTile("IN", state.inputTokens?.let(::compactNumber), colors, roomy)
            Spacer(GlanceModifier.width(5.dp))
            MetricTile("OUT", state.outputTokens?.let(::compactNumber), colors, roomy)
            Spacer(GlanceModifier.width(5.dp))
            MetricTile("TTFT", state.firstTokenLatencyMs?.let(::compactLatency), colors, roomy)
        }
        Spacer(GlanceModifier.height(5.dp))
        Row(modifier = GlanceModifier.fillMaxWidth()) {
            MetricTile("CACHE", state.cacheReadTokens?.let(::compactNumber), colors, roomy)
            Spacer(GlanceModifier.width(5.dp))
            MetricTile("CACHE %", state.cachePercent?.let { "$it%" }, colors, roomy)
        }
    }
}

@Composable
private fun RowScope.MetricTile(
    label: String,
    value: String?,
    colors: WidgetPalette,
    roomy: Boolean,
) {
    Column(
        modifier =
            GlanceModifier
                .defaultWeight()
                .height(if (roomy) 39.dp else 32.dp)
                .background(colors.background)
                .cornerRadius(10.dp)
                .padding(horizontal = if (roomy) 7.dp else 5.dp, vertical = 3.dp),
    ) {
        Text(
            label,
            maxLines = 1,
            style = TextStyle(color = colors.secondary, fontSize = if (roomy) 7.5.sp else 7.sp),
        )
        Spacer(GlanceModifier.height(1.dp))
        Text(
            value ?: "—",
            maxLines = 1,
            style = TextStyle(
                color = colors.text,
                fontSize = if (roomy) 11.5.sp else 10.sp,
                fontWeight = FontWeight.Bold,
            ),
        )
    }
}

@Composable
private fun LastActivity(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    roomy: Boolean = false,
) {
    val activityAt = state.lastActivityAtMs ?: return
    if (activityAt <= 0) return
    val minutes = TimeUnit.MILLISECONDS.toMinutes((System.currentTimeMillis() - activityAt).coerceAtLeast(0))
    val label = when {
        minutes < 1 -> context.getString(R.string.hermes_widget_now)
        minutes < 60 -> context.getString(R.string.hermes_widget_minutes, minutes)
        else -> context.getString(R.string.hermes_widget_hours, minutes / 60)
    }
    Text(label, style = TextStyle(color = colors.secondary, fontSize = if (roomy) 9.5.sp else 8.5.sp))
}

@Composable
private fun Actions(
    context: Context,
    state: HermesWidgetState,
    colors: WidgetPalette,
    includeCurrent: Boolean,
    roomy: Boolean = false,
) {
    Row(modifier = GlanceModifier.fillMaxWidth()) {
        ActionChip(
            context,
            context.getString(R.string.hermes_widget_new_short),
            R.drawable.ic_new_session_widget_add,
            colors,
            true,
            NewSessionLaunchContract.newIntent(
                context,
                NewSessionLaunchContract.SOURCE_WIDGET,
                NewSessionLaunchTarget.COMPOSER,
                requestedInstanceId = state.instanceId,
            ),
            modifier = GlanceModifier.defaultWeight(),
            roomy = roomy,
        )
        Spacer(GlanceModifier.width(7.dp))
        ActionChip(
            context,
            context.getString(R.string.hermes_widget_voice),
            R.drawable.ic_new_session_widget_voice,
            colors,
            false,
            NewSessionLaunchContract.newIntent(
                context,
                NewSessionLaunchContract.SOURCE_WIDGET,
                NewSessionLaunchTarget.VOICE,
                requestedInstanceId = state.instanceId,
            ),
            modifier = GlanceModifier.defaultWeight(),
            roomy = roomy,
        )
        Spacer(GlanceModifier.width(7.dp))
        val intent =
            if (includeCurrent && state.sessionId != null) {
                NewSessionLaunchContract.openSessionIntent(
                    context,
                    state.instanceId,
                    state.sessionId,
                )
            } else {
                NewSessionLaunchContract.openAppIntent(context)
            }
        ActionChip(
            context,
            if (includeCurrent) context.getString(R.string.hermes_widget_return) else context.getString(R.string.hermes_widget_open),
            R.drawable.ic_stat_hermes,
            colors,
            false,
            intent,
            modifier = GlanceModifier.defaultWeight(),
            roomy = roomy,
        )
    }
}

@Composable
private fun ActionChip(
    context: Context,
    label: String,
    icon: Int,
    colors: WidgetPalette,
    highlighted: Boolean,
    intent: android.content.Intent,
    modifier: GlanceModifier = GlanceModifier,
    roomy: Boolean = false,
) {
    val background = if (highlighted) colors.accent else colors.surface
    val foreground = if (highlighted) colors.onAccent else colors.text
    Box(
        modifier =
            modifier
                .height(if (roomy) 40.dp else 32.dp)
                .background(background)
                .cornerRadius(12.dp)
                .clickable(actionStartActivity(intent)),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            modifier = GlanceModifier.padding(horizontal = 8.dp),
            verticalAlignment = Alignment.Vertical.CenterVertically,
            horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
        ) {
            Image(
                provider = ImageProvider(icon),
                contentDescription = label,
                modifier = GlanceModifier.size(if (roomy) 16.dp else 14.dp),
                colorFilter = ColorFilter.tint(foreground),
            )
            Spacer(GlanceModifier.width(5.dp))
            Text(
                label,
                maxLines = 1,
                style = TextStyle(
                    color = foreground,
                    fontSize = if (roomy) 10.5.sp else 9.sp,
                    fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.Center,
                ),
            )
        }
    }
}

private fun connectionLabel(context: Context, state: HermesWidgetConnectionState): String =
    when (state) {
        HermesWidgetConnectionState.CONNECTED -> context.getString(R.string.hermes_widget_online)
        HermesWidgetConnectionState.CONNECTING -> context.getString(R.string.hermes_widget_connecting)
        HermesWidgetConnectionState.ERROR -> context.getString(R.string.hermes_widget_error)
        HermesWidgetConnectionState.DISCONNECTED -> context.getString(R.string.hermes_widget_offline)
        HermesWidgetConnectionState.NO_INSTANCE,
        HermesWidgetConnectionState.UNCONFIGURED,
        -> context.getString(R.string.hermes_widget_setup)
    }

private fun agentLabel(context: Context, state: HermesWidgetState): String =
    when (state.agentState) {
        HermesWidgetAgentState.IDLE -> context.getString(R.string.hermes_widget_idle)
        HermesWidgetAgentState.THINKING -> context.getString(R.string.hermes_widget_thinking)
        HermesWidgetAgentState.STREAMING -> context.getString(R.string.hermes_widget_streaming)
        HermesWidgetAgentState.TOOL_EXECUTION ->
            state.toolName ?: context.getString(R.string.hermes_widget_tool)
        HermesWidgetAgentState.WAITING_APPROVAL -> context.getString(R.string.hermes_widget_approval)
        HermesWidgetAgentState.ERROR -> context.getString(R.string.hermes_widget_error)
        HermesWidgetAgentState.DISCONNECTED -> context.getString(R.string.hermes_widget_offline)
    }

private fun agentStatusLabel(context: Context, state: HermesWidgetState): String =
    "${context.getString(R.string.hermes_widget_agent)} · ${agentLabel(context, state)}"

private fun compactNumber(value: Long): String =
    when {
        value >= 1_000_000 -> "${(value / 100_000) / 10.0}M"
        value >= 1_000 -> "${(value / 100) / 10.0}K"
        else -> value.toString()
    }

private fun compactLatency(value: Long): String =
    if (value < 1000) "${value}ms" else "${(value / 100) / 10.0}s"
