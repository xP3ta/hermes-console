import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Which of the app's two homes the user is under: the General Home (the
/// first route) or the Bots home (Mission Control, pushed above it).
///
/// The dock is the same widget with the same items in both. "Inicio" is
/// always the General Home and "Bots" the Bots home; the mode only decides
/// which of the two a place (Ajustes, Chats, Proyectos...) opens above.
enum DockMode { general, bots }

/// Tracks the Bots home routes on the navigator so every dock knows which
/// mode it is in: Bot Mode while a Bots home is on the stack, General
/// otherwise. Screens pushed above the Bots home (Ajustes, Proyectos...)
/// stay in Bot Mode: their "Bots" goes back to the Bots home and their
/// "Inicio" leaves for the General Home.
class DockModes extends ChangeNotifier {
  DockModes._();

  static final DockModes instance = DockModes._();

  final List<Route<dynamic>> _botsHomes = [];

  /// The topmost Bots home still on the navigator, if any.
  Route<dynamic>? get botsHome {
    for (final route in _botsHomes.reversed) {
      if (route.isActive) return route;
    }
    return null;
  }

  /// The current mode.
  DockMode get mode => botsHome == null ? DockMode.general : DockMode.bots;

  void _enter(Route<dynamic> route) {
    if (_botsHomes.contains(route)) return;
    _botsHomes.add(route);
    _notify();
  }

  void _leave(Route<dynamic> route) {
    if (!_botsHomes.remove(route)) return;
    _notify();
  }

  /// Anchors enter and leave while the tree is being built or finalized;
  /// docks listening then rebuild on the next frame instead of mid-build.
  void _notify() {
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      scheduler.addPostFrameCallback((_) => notifyListeners());
      scheduler.ensureVisualUpdate();
    } else {
      notifyListeners();
    }
  }

  @visibleForTesting
  void resetForTesting() => _botsHomes.clear();
}

/// Marks the route it lives in as the Bots home (Mission Control wraps its
/// screen in it).
class BotsHomeAnchor extends StatefulWidget {
  final Widget child;

  const BotsHomeAnchor({required this.child, super.key});

  @override
  State<BotsHomeAnchor> createState() => _BotsHomeAnchorState();
}

class _BotsHomeAnchorState extends State<BotsHomeAnchor> {
  Route<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    final previous = _route;
    _route = route;
    if (previous != null) DockModes.instance._leave(previous);
    if (route == null) return;
    // A popped route stops counting as active at once ([botsHome] skips
    // it); listeners hear about it when the screen is disposed.
    DockModes.instance._enter(route);
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null) DockModes.instance._leave(route);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
