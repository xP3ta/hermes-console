import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Forwards notifications from [source] only while the subtree that bound it
/// is onstage.
///
/// A route covered by an opaque route keeps its state but is laid out
/// offstage, and the [Overlay] disables its [TickerMode]. Screens in the back
/// stack (Home, the session list) listen to service-wide activity notifiers
/// that fire on every subagent event during a run; rebuilding them while
/// hidden only adds work to the frames of the visible chat.
///
/// While offstage a notification is remembered instead of forwarded, and a
/// single notification is delivered as soon as the subtree is onstage again,
/// so the screen never shows stale activity once it is visible.
class OnstageGate extends ChangeNotifier {
  Listenable? _source;
  ValueListenable<TickerModeData>? _mode;
  bool _deferred = false;

  bool get onstage => _mode?.value.enabled ?? true;

  /// Binds the gate to [source] and to the ticker mode of [context]. Safe to
  /// call from every `didChangeDependencies`: rebinding keeps a pending
  /// deferred notification.
  void bind(BuildContext context, Listenable? source) {
    if (!identical(source, _source)) {
      _source?.removeListener(_onSource);
      _source = source;
      source?.addListener(_onSource);
    }
    final mode = TickerMode.getValuesNotifier(context);
    if (!identical(mode, _mode)) {
      _mode?.removeListener(_onMode);
      _mode = mode;
      mode.addListener(_onMode);
      _onMode();
    }
  }

  void _onSource() {
    if (onstage) {
      notifyListeners();
    } else {
      _deferred = true;
    }
  }

  void _onMode() {
    if (!_deferred || !onstage) return;
    _deferred = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _source?.removeListener(_onSource);
    _source = null;
    _mode?.removeListener(_onMode);
    _mode = null;
    super.dispose();
  }
}
