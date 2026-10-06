import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Where the floating dock sits on screen, for overlays that live around it
/// (the floating mascot rests on its top edge and steps out of its way).
///
/// [rect] is in global logical pixels: the resting bar while the dock is
/// shown, the thin accent line while it is hidden, and null while no dock
/// is on the visible route (chats, the flag off, the keyboard open).
/// It reports resting geometry, not each animation frame, so listeners are
/// not woken up for every frame of a hide or show.
class DockGeometry {
  DockGeometry();

  /// The app-wide instance the gesture dock publishes to.
  static final DockGeometry instance = DockGeometry();

  final ValueNotifier<Rect?> _rect = ValueNotifier<Rect?>(null);
  final ValueNotifier<bool> _hidden = ValueNotifier<bool>(false);
  Object? _owner;

  ValueListenable<Rect?> get rect => _rect;
  ValueListenable<bool> get hidden => _hidden;

  /// Publishes [rect] for [owner]; the last visible dock to publish wins.
  void publish(Object owner, Rect? rect, {required bool hidden}) {
    _owner = owner;
    if (_rect.value != rect) _rect.value = rect;
    if (_hidden.value != hidden) _hidden.value = hidden;
  }

  /// Clears the geometry when [owner] is still the one that published it.
  void clear(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _rect.value = null;
    _hidden.value = false;
  }

  @visibleForTesting
  void resetForTesting() {
    _owner = null;
    _rect.value = null;
    _hidden.value = false;
  }
}
