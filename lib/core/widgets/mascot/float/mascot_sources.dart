import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../../l10n/app_localizations.dart';
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

/// What a [MascotNotice] is about.
enum MascotNoticeKind {
  /// Another profile of this instance has replies or something waiting.
  profile,

  /// Another instance needs attention, went offline or came back.
  instance,

  /// A long task finished while the user was elsewhere.
  finished,

  /// Something failed while the user was elsewhere (a cron job).
  failed,

  /// A piece of help the user can refuse for good ("No sugerirme esto").
  suggestion,
}

/// One thing the mascot tells the user about, in a small bubble: a line of
/// text and at most one action that goes to the thing.
///
/// The source owns the list: a notice leaves it when it stops being true
/// (the profile was read, the instance was opened). The mascot shows each
/// [key] by itself once; after that it waits behind the badge until the user
/// taps the mascot.
@immutable
final class MascotNotice {
  const MascotNotice({
    required this.key,
    required this.kind,
    required this.text,
    this.action,
    this.onAction,
    this.onSeen,
    this.waiting = false,
  }) : assert((action == null) == (onAction == null));

  /// Stable identity: the same fact keeps the same key.
  final String key;
  final MascotNoticeKind kind;

  /// The one line, in the user's language.
  final String Function(Strings strings) text;

  /// Label of the one action.
  final String Function(Strings strings)? action;
  final VoidCallback? onAction;

  /// Called when the user has seen the bubble (it closed, or its action
  /// ran), so the source can stop reporting it.
  final VoidCallback? onSeen;

  /// Somebody waits for the user there: the mascot shows "te necesita".
  final bool waiting;

  bool get isSuggestion => kind == MascotNoticeKind.suggestion;
}

/// What the app tells the floating mascot. Tests use plain notifiers
/// through the same seam as the app.
class MascotSources {
  MascotSources({
    ValueListenable<List<MascotPermission>>? permissions,
    ValueListenable<bool>? needsCardVisible,
    ValueListenable<MascotState>? activity,
    ValueListenable<List<MascotNotice>>? notices,
  }) : permissions =
           permissions ?? ValueNotifier<List<MascotPermission>>(const []),
       needsCardVisible = needsCardVisible ?? ValueNotifier<bool>(false),
       activity = activity ?? ValueNotifier<MascotState>(MascotState.idle),
       notices = notices ?? ValueNotifier<List<MascotNotice>>(const []);

  /// The app-wide sources; replaced once at startup by the app.
  static MascotSources instance = MascotSources();

  final ValueListenable<List<MascotPermission>> permissions;

  /// True while the Inicio "Te necesita" card is on screen: the mascot then
  /// only hops and shows the count, it never opens a second bubble.
  final ValueListenable<bool> needsCardVisible;

  /// What Hermes is doing in the active profile.
  final ValueListenable<MascotState> activity;

  /// Things happening where the user is not looking, most important first.
  final ValueListenable<List<MascotNotice>> notices;
}

/// Menu actions that belong to the app (navigation), not to the overlay.
@immutable
final class MascotOverlayActions {
  const MascotOverlayActions({this.onTalk, this.onChange});

  /// "Hablar": open a new chat.
  final VoidCallback? onTalk;

  /// "Cambiar mascota": open the Mascotas screen.
  final VoidCallback? onChange;
}

/// What the floating mascot draws and whether it is on: the active
/// profile's pet, as the Mascotas screen has it. It notifies when any of
/// that changes.
abstract class MascotPet implements Listenable {
  /// Whether the mascot shows outside chats (presence "En toda la app",
  /// the pet loaded). False mounts nothing: no overlay, no timers.
  bool get shown;

  /// Name for the screen reader ("Mascota de …").
  String get name;

  /// The pet's own size setting (1 is [MascotFloatPhysics.baseSize]).
  double get scale;

  /// The pet in a [size] box standing on its bottom edge, drawing [state].
  /// [asleep] is its resting drawing, still, with no timer; [look] changes
  /// every time an idle pet should look around once; [airborne] is true
  /// while it falls (or springs up) to its place on the dock.
  Widget build(
    BuildContext context, {
    required MascotState state,
    required double size,
    required bool asleep,
    required int look,
    bool airborne = false,
  });

  /// "Ocultar": the pet leaves every screen but the chat.
  Future<void> hide();
}
