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
  final ValueNotifier<bool> _menuOpen = ValueNotifier<bool>(false);
  final Map<Object, VoidCallback> _watchers = <Object, VoidCallback>{};
  final Map<Object, ({Route<dynamic> route, bool pet})> _screens =
      <Object, ({Route<dynamic> route, bool pet})>{};
  final ValueNotifier<int> _screensRevision = ValueNotifier<int>(0);
  Object? _owner;
  Object? _menuOwner;

  ValueListenable<Rect?> get rect => _rect;
  ValueListenable<bool> get hidden => _hidden;

  /// True while an item's long-press menu is open above the bar: whatever
  /// stands on the dock gets out of its way.
  ValueListenable<bool> get menuOpen => _menuOpen;

  /// Bumps whenever the set of routes that carry the dock changes.
  ValueListenable<int> get screensRevision => _screensRevision;

  /// Whether [route] is one of the screens the dock belongs to: a
  /// top-level destination that mounts it (Inicio, Chats, the Bots home,
  /// Herramientas, Ajustes...). That is a property of the screen, not of
  /// the bar: it holds while the bar is hidden by hand or switched off in
  /// settings. This is the one fact the floating mascot is shown by.
  bool carriesDock(Route<dynamic> route) =>
      _screens.values.any((screen) => identical(screen.route, route));

  /// Whether the floating mascot stands on [route]: it carries the dock and
  /// none of the screens that declared it opted the pet out (the pure
  /// configuration screens, which still have the dock but not the pet).
  bool carriesPet(Route<dynamic> route) {
    var carries = false;
    for (final screen in _screens.values) {
      if (!identical(screen.route, route)) continue;
      if (!screen.pet) return false;
      carries = true;
    }
    return carries;
  }

  /// [owner] (a `DockScreen`) declares that [route] carries the dock, and
  /// whether the pet stands on it ([pet]).
  void registerScreen(Object owner, Route<dynamic> route, {bool pet = true}) {
    final known = _screens[owner];
    if (known != null && identical(known.route, route) && known.pet == pet) {
      return;
    }
    _screens[owner] = (route: route, pet: pet);
    _screensRevision.value++;
  }

  /// [owner] no longer declares a route.
  void unregisterScreen(Object owner) {
    if (_screens.remove(owner) != null) _screensRevision.value++;
  }

  /// The dock [owner] opened or closed an item's menu.
  void setMenuOpen(Object owner, bool open) {
    if (open) {
      _menuOwner = owner;
      _menuOpen.value = true;
    } else if (identical(_menuOwner, owner)) {
      _menuOwner = null;
      _menuOpen.value = false;
    }
  }

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

  /// A dock on the visible route registers how to publish its geometry
  /// again ([republish] may wait for the next frame).
  void watch(Object owner, VoidCallback republish) =>
      _watchers[owner] = republish;

  void unwatch(Object owner) => _watchers.remove(owner);

  /// Asks the docks on screen to publish where they rest now. A dock first
  /// publishes while its route is still arriving; whoever needs the resting
  /// rect calls this once the navigator has settled.
  void refresh() {
    if (_watchers.isEmpty) return;
    for (final republish in _watchers.values.toList()) {
      republish();
    }
    // They publish after a frame: make sure there is one.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @visibleForTesting
  void resetForTesting() {
    _watchers.clear();
    _screens.clear();
    _screensRevision.value++;
    _menuOwner = null;
    _menuOpen.value = false;
    _owner = null;
    _rect.value = null;
    _hidden.value = false;
  }
}
