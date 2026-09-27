package com.hermesagent.hermes_android

import es.antonborri.home_widget.HomeWidgetGlanceWidgetReceiver

/**
 * Receiver name retained from the RemoteViews widget so launchers keep placed
 * widgets across the app update. It is the 4x2 dashboard variant.
 */
class NewSessionWidgetProvider :
    HomeWidgetGlanceWidgetReceiver<HermesConsoleGlanceWidget>() {
    override val glanceAppWidget = HermesConsoleGlanceWidget(HermesWidgetVariant.DASHBOARD)
}

/** Height-stable 2x1 status surface with adaptive horizontal sizing. */
class HermesCompactWidgetProvider :
    HomeWidgetGlanceWidgetReceiver<HermesConsoleGlanceWidget>() {
    override val glanceAppWidget = HermesConsoleGlanceWidget(HermesWidgetVariant.COMPACT)
}

/** Height-stable 4x1 context surface with adaptive horizontal sizing. */
class HermesControlWidgetProvider :
    HomeWidgetGlanceWidgetReceiver<HermesConsoleGlanceWidget>() {
    override val glanceAppWidget = HermesConsoleGlanceWidget(HermesWidgetVariant.CONTROL)
}
