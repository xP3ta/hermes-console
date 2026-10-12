package com.hermesagent.hermes_android

/*
 * The three receivers shipped since 1.2.13. A launcher binds a placed widget
 * to its receiver's class name, so the names stay and only what they draw
 * changed: a widget somebody already has on a home screen becomes the new
 * one in place, at the size it had.
 */

/** Was "Hermes · Panel" (4x2). Now Ahora. */
class NewSessionWidgetProvider : LauncherWidgetProvider(LauncherWidgetSubject.AHORA)

/** Was "Hermes · Compacto" (2x1). Now Chat rápido, the one the picker offers. */
class HermesCompactWidgetProvider : LauncherWidgetProvider(LauncherWidgetSubject.QUICK)

/**
 * Was "Hermes · Controles" (4x1). Now Chat rápido as well: kept for the
 * widgets already placed and hidden from the picker, which offers Chat rápido
 * once (it grows to this same four-cell form when widened).
 */
class HermesControlWidgetProvider : LauncherWidgetProvider(LauncherWidgetSubject.QUICK)

/** Cron: the next scheduled job; larger, all of them by next run. New in 1.2.15. */
class HermesCronWidgetProvider : LauncherWidgetProvider(LauncherWidgetSubject.CRON)

/*
 * Bots and Salas were drafted in 1.2.14 as Glance widgets and never enabled in
 * a released manifest. They ship in 1.2.15 in the family's look, under the
 * receiver names the background listener already redraws.
 */

/** Bots: the faces of the team and who waits for you; larger, a row per bot. */
class HermesBotsWidgetProvider : LauncherWidgetProvider(LauncherWidgetSubject.BOTS)

/** Salas: the live room and who answers; larger, more rooms with their last line. */
class HermesRoomWidgetProvider : LauncherWidgetProvider(LauncherWidgetSubject.ROOMS)

/** Tareas: the card in progress; larger, in progress first and then the pending ones. New in 1.2.15. */
class HermesTasksWidgetProvider : LauncherWidgetProvider(LauncherWidgetSubject.TASKS)

/** Chats: the conversation that moves; larger, the recent ones with their state. New in 1.2.15. */
class HermesChatsWidgetProvider : LauncherWidgetProvider(LauncherWidgetSubject.CHATS)
