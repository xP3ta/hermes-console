import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/motion.dart';

/// The «Respuesta háptica» switch of Settings. On by default; it only adds a
/// switch on top of the system's own («Respuesta táctil»), it never overrides
/// it: Android plays every tick through the view (`performHapticFeedback`), so
/// turning touch feedback off in the system silences Console too.
class HapticPrefs extends ChangeNotifier {
  HapticPrefs._(this._prefs) : _enabled = _prefs?.getBool(key) ?? true;

  static const String key = 'haptics_enabled';

  final SharedPreferences? _prefs;
  bool _enabled;

  static HapticPrefs? _shared;

  static HapticPrefs get shared => _shared ??= HapticPrefs._(null);

  static Future<HapticPrefs> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = HapticPrefs._(resolved);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static void debugUse(HapticPrefs? store) => _shared = store;

  bool get enabled => _enabled;

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    unawaited(syncNative());
    await _prefs?.setBool(key, value);
  }

  static const MethodChannel _channel = MethodChannel('hermes/haptics');

  /// Tells Android's Flutter view the setting, so the ticks the framework
  /// plays by itself (long press, text selection) obey it too. Quiet where
  /// there is no such channel (tests, other platforms).
  Future<void> syncNative() async {
    try {
      await _channel.invokeMethod<bool>('setEnabled', _enabled);
    } on Object {
      // No native side: the Dart ticks still obey the setting.
    }
  }
}

/// The app's touch feedback: the ONE way out to the vibrator. Every tick of
/// the app goes through here so the setting, the debounce and the choice of
/// strength live in one place.
///
/// Semantic events, from the softest:
/// - [selection]: a choice among several (segment, tab, key, option).
/// - [tap]: a light press of a control (button, pill, switch).
/// - [confirm]: an action that commits (send a message, grant an approval).
/// - [success]: something finished well (a turn ended).
/// - [warning]: a «no» that is not an error (denied, cannot do that).
/// - [error]: something failed.
///
/// Never call it for passive things (streaming text, scrolling, animations):
/// every call is a conscious answer to a finger.
abstract final class HermesHaptics {
  /// Events that come from the app, not from a finger ([success], [warning],
  /// [error]) wait this long between two: a burst of failures buzzes once.
  /// Finger events ([selection], [tap], [confirm]) are never held back: each
  /// key of the terminal ticks, as it always did.
  static const Duration statusCooldown = HermesMotion.hapticCooldown;

  static final Stopwatch _clock = Stopwatch()..start();
  static Duration? _lastStatusAt;
  static int _fired = 0;

  /// Counts the ticks played: [HermesTapHaptics] uses it to know whether a
  /// control already answered by itself.
  static int get firedCount => _fired;

  static bool get enabled => HapticPrefs.shared.enabled;

  @visibleForTesting
  static void debugReset() {
    _lastStatusAt = null;
    _fired = 0;
  }

  /// True when a finger-driven tick may play (the setting is on).
  static bool _fingerAdmit() {
    if (!enabled) return false;
    _fired++;
    return true;
  }

  /// True (and the cooldown restarts) when an app-driven tick may play now.
  static bool _statusAdmit() {
    if (!enabled) return false;
    final now = _clock.elapsed;
    final last = _lastStatusAt;
    if (last != null && now - last < statusCooldown) return false;
    _lastStatusAt = now;
    _fired++;
    return true;
  }

  static void _play(Future<void> Function() tick) =>
      unawaited(tick().catchError((_) {}));

  /// A choice among several.
  static void selection() {
    if (_fingerAdmit()) _play(HapticFeedback.selectionClick);
  }

  /// A light press of a control.
  static void tap() {
    if (_fingerAdmit()) _play(HapticFeedback.lightImpact);
  }

  /// An action that commits.
  static void confirm() {
    if (_fingerAdmit()) _play(HapticFeedback.mediumImpact);
  }

  /// Something finished well.
  static void success() {
    if (_statusAdmit()) _play(HapticFeedback.mediumImpact);
  }

  /// A «no» that is not an error (denied, cannot do that): one light tick,
  /// softer than [success] and than [error].
  static void warning() {
    if (_statusAdmit()) _play(HapticFeedback.lightImpact);
  }

  /// Something failed.
  static void error() {
    if (_statusAdmit()) _play(HapticFeedback.heavyImpact);
  }
}

/// Gives every tappable control of the app its light tick, without touching
/// the 700+ places that build one: when a finger lifts after a short tap on
/// an ENABLED button, switch, checkbox or radio (read from the semantics the
/// widgets already publish) and the control has not played a tick of its own
/// by the end of that same event, a [HermesHaptics.tap] plays. A control that answers by itself
/// (the send button's [HermesHaptics.confirm], an option's
/// [HermesHaptics.selection]) wins: the generic tick is only the fallback.
///
/// Scrolls, drags and long presses are not taps and never buzz.
class HermesTapHaptics extends StatefulWidget {
  const HermesTapHaptics({super.key, required this.child});

  final Widget child;

  @override
  State<HermesTapHaptics> createState() => _HermesTapHapticsState();
}

class _HermesTapHapticsState extends State<HermesTapHaptics> {
  final Map<int, _Press> _presses = <int, _Press>{};

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
    // The Flutter view exists by the first frame: apply the saved setting.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(HapticPrefs.shared.syncNative()),
    );
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_route);
    super.dispose();
  }

  void _route(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.stylus) {
      return;
    }
    if (event is PointerDownEvent) {
      if (!HermesHaptics.enabled) return;
      _presses[event.pointer] = _Press(
        at: event.position,
        control: _controlUnder(event),
        started: DateTime.now(),
        firedAtDown: HermesHaptics.firedCount,
      );
    } else if (event is PointerMoveEvent) {
      final press = _presses[event.pointer];
      if (press != null && (event.position - press.at).distance > kTouchSlop) {
        _presses.remove(event.pointer);
      }
    } else if (event is PointerCancelEvent) {
      _presses.remove(event.pointer);
    } else if (event is PointerUpEvent) {
      final press = _presses.remove(event.pointer);
      if (press == null || !press.control) return;
      if (DateTime.now().difference(press.started) >
          kLongPressTimeout + HermesMotion.tapGrace) {
        return;
      }
      // The control's own tap callback already ran (the recognizer's route
      // precedes the global ones): if a tick played since the finger came
      // down, it answered by itself and the fallback stays silent.
      final before = press.firedAtDown;
      scheduleMicrotask(() {
        if (HermesHaptics.firedCount == before) HermesHaptics.tap();
      });
    }
  }

  /// Whether an enabled button, switch, checkbox or radio is under the finger.
  bool _controlUnder(PointerDownEvent event) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderSemanticsAnnotations) {
        if (isActionableControl(target.properties)) return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// An enabled button, switch, checkbox or radio, from its semantics.
@visibleForTesting
bool isActionableControl(SemanticsProperties p) {
  if (p.enabled == false) return false;
  final isControl =
      p.button == true ||
      p.toggled != null ||
      p.checked != null ||
      p.inMutuallyExclusiveGroup == true && p.selected != null;
  if (!isControl) return false;
  // A text field or a slider is not a tap target.
  if (p.textField == true || p.slider == true) return false;
  return true;
}

class _Press {
  const _Press({
    required this.at,
    required this.control,
    required this.started,
    required this.firedAtDown,
  });

  final Offset at;
  final bool control;
  final DateTime started;
  final int firedAtDown;
}
