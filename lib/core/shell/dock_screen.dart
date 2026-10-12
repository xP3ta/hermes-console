import 'package:flutter/widgets.dart';

import 'dock_geometry.dart';

/// Marks the route it sits in as a screen the dock belongs to.
///
/// Every place that mounts the dock (`Dock`, `GeneralDockShell` even with
/// the dock switched off, the Bots home) wraps its screen in this, so
/// "this route carries the dock" is declared where the dock is, once, and
/// is true whether the bar is shown, hidden by hand or switched off. The
/// floating mascot is shown on exactly these routes
/// ([DockGeometry.carriesDock]); nothing else keeps a list of them.
class DockScreen extends StatefulWidget {
  const DockScreen({
    required this.child,
    this.carriesPet = true,
    this.geometry,
    super.key,
  });

  final Widget child;

  /// False on the pure configuration screens: they have the dock, but the
  /// floating mascot does not stand on them ([DockGeometry.carriesPet]).
  final bool carriesPet;

  /// Defaults to [DockGeometry.instance]; tests pass their own.
  final DockGeometry? geometry;

  @override
  State<DockScreen> createState() => _DockScreenState();
}

class _DockScreenState extends State<DockScreen> {
  DockGeometry? _registered;

  DockGeometry get _geometry => widget.geometry ?? DockGeometry.instance;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _declare();
  }

  @override
  void didUpdateWidget(DockScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.carriesPet != widget.carriesPet) _declare();
  }

  void _declare() {
    final route = ModalRoute.of(context);
    final geometry = _geometry;
    if (!identical(_registered, geometry)) _registered?.unregisterScreen(this);
    if (route == null) {
      geometry.unregisterScreen(this);
    } else {
      geometry.registerScreen(this, route, pet: widget.carriesPet);
    }
    _registered = geometry;
  }

  @override
  void dispose() {
    _registered?.unregisterScreen(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
