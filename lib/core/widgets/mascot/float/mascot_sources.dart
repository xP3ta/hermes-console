import 'package:flutter/foundation.dart';

import '../mascot_state.dart';

/// A pending permission, as the Inicio "Te necesita" card shows it.
///
/// The card and the floating mascot read the SAME [MascotSources.permissions]
/// list and answer through the same [resolve]: answering in one place removes
/// the item from the shared list, so it disappears from the other at once.
@immutable
final class MascotPermission {
  const MascotPermission({
    required this.key,
    required this.title,
    required this.resolve,
    this.command,
    this.openChat,
  });

  /// Stable identity of the request (session + request id).
  final String key;

  /// Chat or bot that asks.
  final String title;

  /// The full command, when the request carries one.
  final String? command;

  /// Answers the request: true allows it (once), false denies it.
  final Future<void> Function(bool allow) resolve;

  /// Opens the chat that owns the request.
  final VoidCallback? openChat;
}

/// A suggestion that comes from the server (never invented on the phone).
@immutable
final class MascotSuggestion {
  const MascotSuggestion({
    required this.key,
    required this.text,
    required this.actionLabel,
    required this.onAction,
    this.onNotNow,
    this.onNever,
  });

  final String key;
  final String text;
  final String actionLabel;
  final VoidCallback onAction;
  final VoidCallback? onNotNow;

  /// "No sugerirme esto": silences this category.
  final VoidCallback? onNever;
}

/// Everything the floating mascot shows, behind one seam so the app wires
/// its real sources once (Inicio approvals, global activity, server
/// suggestions) and tests use plain notifiers.
///
/// The default instance is empty: no permissions, no suggestions, idle.
/// Suggestions are server-sourced only. In particular the "same safe
/// command allowed 3 times → automate it?" proposal needs a server-provided
/// list of safe commands; upstream has none today, so the mascot never
/// offers it.
class MascotSources {
  MascotSources({
    ValueListenable<List<MascotPermission>>? permissions,
    ValueListenable<bool>? needsCardVisible,
    ValueListenable<List<MascotSuggestion>>? suggestions,
    ValueListenable<MascotState>? activity,
    ValueListenable<String?>? activitySummary,
  }) : permissions =
           permissions ?? ValueNotifier<List<MascotPermission>>(const []),
       needsCardVisible = needsCardVisible ?? ValueNotifier<bool>(false),
       suggestions =
           suggestions ?? ValueNotifier<List<MascotSuggestion>>(const []),
       activity = activity ?? ValueNotifier<MascotState>(MascotState.idle),
       activitySummary = activitySummary ?? ValueNotifier<String?>(null);

  /// The app-wide sources; replaced once at startup by the integration.
  static MascotSources instance = MascotSources();

  final ValueListenable<List<MascotPermission>> permissions;

  /// True while the Inicio "Te necesita" card is on screen: the mascot then
  /// only hops and shows the count, it never opens a second bubble.
  final ValueListenable<bool> needsCardVisible;

  final ValueListenable<List<MascotSuggestion>> suggestions;
  final ValueListenable<MascotState> activity;

  /// One line for "¿Qué haces?" (null: nothing running).
  final ValueListenable<String?> activitySummary;
}

/// Menu actions that belong to the app (navigation), not to the overlay.
@immutable
final class MascotOverlayActions {
  const MascotOverlayActions({this.onTalk, this.onKnowledge, this.onSettings});

  /// "Hablar": open a new chat.
  final VoidCallback? onTalk;

  /// "Lo que sé de ti": open the memory/profile screen.
  final VoidCallback? onKnowledge;

  /// "Ajustes de la mascota".
  final VoidCallback? onSettings;
}
