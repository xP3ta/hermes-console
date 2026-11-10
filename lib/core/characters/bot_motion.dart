import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The "Animar bots" switch of Settings: whether bot faces may move at all.
/// On by default. It never overrides the system's reduced motion: a face
/// moves only when both allow it ([botMotionAllowed]).
class BotMotionPrefs extends ChangeNotifier {
  BotMotionPrefs._(this._prefs) : _animate = _prefs?.getBool(key) ?? true;

  static const String key = 'characters_animate_bots';

  final SharedPreferences? _prefs;
  bool _animate;

  static BotMotionPrefs? _shared;

  static BotMotionPrefs get shared => _shared ??= BotMotionPrefs._(null);

  static Future<BotMotionPrefs> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = BotMotionPrefs._(resolved);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static void debugUse(BotMotionPrefs? store) => _shared = store;

  bool get animate => _animate;

  Future<void> setAnimate(bool value) async {
    if (_animate == value) return;
    _animate = value;
    notifyListeners();
    await _prefs?.setBool(key, value);
  }
}

/// Publishes [BotMotionPrefs] to the tree so every face re-syncs its clock
/// when the switch changes. Without a scope faces animate as before.
class BotMotionScope extends InheritedNotifier<BotMotionPrefs> {
  BotMotionScope({super.key, BotMotionPrefs? prefs, required super.child})
    : super(notifier: prefs ?? BotMotionPrefs.shared);

  static bool animateOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<BotMotionScope>();
    return scope?.notifier?.animate ?? true;
  }
}

/// True when a bot face may run its clock here: "Animar bots" is on and the
/// system has not asked for reduced motion.
bool botMotionAllowed(BuildContext context) =>
    BotMotionScope.animateOf(context) &&
    !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
