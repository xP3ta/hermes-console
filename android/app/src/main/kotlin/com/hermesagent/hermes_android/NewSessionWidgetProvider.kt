package com.hermesagent.hermes_android

import es.antonborri.home_widget.HomeWidgetGlanceWidgetReceiver

/**
 * Legacy receiver names are kept so launchers keep widgets placed before the
 * Bot Mode redesign (spec 070 Phase 7); each now renders a new-family widget
 * that fits its original cell span.
 */

/** Old 4x2 dashboard → Bots grid. */
class NewSessionWidgetProvider :
    HomeWidgetGlanceWidgetReceiver<HermesBotModeWidget>() {
    override val glanceAppWidget = HermesBotModeWidget(BotModeWidgetKind.BOTS)
}

/** Old 2x1 compact → Status (connection + working count). */
class HermesCompactWidgetProvider :
    HomeWidgetGlanceWidgetReceiver<HermesBotModeWidget>() {
    override val glanceAppWidget = HermesBotModeWidget(BotModeWidgetKind.STATUS)
}

/** Old 4x1 controls → Quick ask (face + "Ask <Bot>…" + mic). */
class HermesControlWidgetProvider :
    HomeWidgetGlanceWidgetReceiver<HermesBotModeWidget>() {
    override val glanceAppWidget = HermesBotModeWidget(BotModeWidgetKind.QUICK_ASK)
}
