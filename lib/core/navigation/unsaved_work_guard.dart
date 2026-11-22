import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/modal.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;

/// Work the user has not saved, held by a screen that a navigation could
/// throw away ([UnsavedWorkGuard.hold]).
class UnsavedWorkHold {
  UnsavedWorkHold._(this._navigator, this._onDiscarded);

  final NavigatorState _navigator;
  final VoidCallback _onDiscarded;
  bool _released = false;

  /// The work was saved or given up where it was being edited.
  void release() {
    if (_released) return;
    _released = true;
    UnsavedWorkGuard._holds.remove(this);
  }
}

/// Asks before a navigation discards unsaved work.
///
/// A chat can hold a file being edited in its Files panel. Leaving the chat
/// (Back, a new chat, another conversation, the dock, a notification)
/// removes its route and the text with it. Every navigation that removes
/// routes in bulk goes through [leave] or [leaveWith]: with nothing unsaved
/// under that navigator they run at once, exactly as before; otherwise the
/// user is asked first and the navigation only happens if they discard.
abstract final class UnsavedWorkGuard {
  static final Set<UnsavedWorkHold> _holds = <UnsavedWorkHold>{};
  static Future<bool>? _asking;

  /// The action of the dialog that discards the work.
  static const Key discardKey = ValueKey<String>('unsaved-work-discard');

  /// The action of the dialog that stays.
  static const Key keepKey = ValueKey<String>('unsaved-work-keep');

  /// Registers unsaved work in a screen of [navigator]. [onDiscarded] runs
  /// when the user agrees to lose it, before the navigation goes on.
  static UnsavedWorkHold hold(
    NavigatorState navigator, {
    required VoidCallback onDiscarded,
  }) {
    final hold = UnsavedWorkHold._(navigator, onDiscarded);
    _holds.add(hold);
    return hold;
  }

  /// The holds a navigation on [navigator] would throw away: those of its
  /// own routes and of the navigators nested in them.
  static List<UnsavedWorkHold> _under(NavigatorState navigator) {
    final found = <UnsavedWorkHold>[];
    for (final hold in _holds) {
      NavigatorState? owner = hold._navigator;
      while (owner != null && owner.mounted) {
        if (identical(owner, navigator)) {
          found.add(hold);
          break;
        }
        owner = owner.context.findAncestorStateOfType<NavigatorState>();
      }
    }
    return found;
  }

  /// Whether leaving routes of [navigator] would lose unsaved work.
  static bool affects(NavigatorState navigator) => _under(navigator).isNotEmpty;

  /// True when nothing is unsaved under [navigator] or the user chose to
  /// discard it; false when they stay.
  static Future<bool> confirm(NavigatorState navigator) async {
    final held = _under(navigator);
    if (held.isEmpty) return true;
    final context = navigator.overlay?.context;
    if (context == null) return false;
    final discard = await (_asking ??= _ask(
      context,
    ).whenComplete(() => _asking = null));
    if (!discard) return false;
    for (final hold in held) {
      if (hold._released) continue;
      hold.release();
      hold._onDiscarded();
    }
    return true;
  }

  static Future<bool> _ask(BuildContext context) async {
    final strings = Strings.of(context);
    return await showHermesDialog<bool>(
          context: context,
          title: strings.pw1215DiscardTitle,
          message: strings.pw1215DiscardBody,
          // Over the whole window, also when asked for a pane's navigator.
          useRootNavigator: true,
          actions: [
            HermesDialogAction(
              key: keepKey,
              label: strings.pw1215KeepEditing,
              value: false,
              style: HermesDialogActionStyle.cancel,
            ),
            HermesDialogAction(
              key: discardKey,
              label: strings.pw1215Discard,
              value: true,
              style: HermesDialogActionStyle.destructive,
            ),
          ],
        ) ==
        true;
  }

  /// Runs [action], a navigation that removes routes of [navigator]: now
  /// when nothing is unsaved there, after the user's answer otherwise (and
  /// not at all if they stay).
  static void leave(NavigatorState navigator, VoidCallback action) {
    if (!affects(navigator)) {
      action();
      return;
    }
    confirm(navigator).then((discard) {
      if (discard && navigator.mounted) action();
    });
  }

  /// Back to the first route of [navigator], asking first if needed.
  static void popToFirst(NavigatorState navigator) =>
      leave(navigator, () => navigator.popUntil((route) => route.isFirst));

  /// [leave] for a navigation with a result; null when the user stays.
  static Future<T?> leaveWith<T>(
    NavigatorState navigator,
    Future<T?> Function() action,
  ) {
    if (!affects(navigator)) return action();
    return confirm(
      navigator,
    ).then((discard) => discard && navigator.mounted ? action() : null);
  }
}
