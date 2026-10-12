import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-wide reading preferences for code and text: the file viewer, chat
/// code blocks and diffs share them.
///
/// Wrap has no stored value until the user toggles it; until then phones
/// (narrower than [phoneMaxWidth]) wrap and tablets scroll sideways. The font
/// scale is the viewer's own zoom, multiplied by the system text scale and
/// bounded by [maxEffectiveScale] so huge accessibility scales stay usable.
class CodeViewPrefs extends ChangeNotifier {
  CodeViewPrefs._(this._prefs)
    : _wrap = _prefs?.getBool(wrapKey),
      _fontScale = _normalise(_prefs?.getDouble(fontScaleKey) ?? 1.0);

  static const String wrapKey = 'code_view_wrap';
  static const String fontScaleKey = 'code_view_font_scale';
  static const double phoneMaxWidth = 600;
  static const double minFontScale = 0.8;
  static const double maxFontScale = 1.6;
  static const double fontScaleStep = 0.1;
  static const double minEffectiveScale = 0.8;
  static const double maxEffectiveScale = 2.0;

  final SharedPreferences? _prefs;
  bool? _wrap;
  double _fontScale;

  static CodeViewPrefs? _shared;

  static CodeViewPrefs get shared => _shared ??= CodeViewPrefs._(null);

  static Future<CodeViewPrefs> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = CodeViewPrefs._(resolved);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static void debugUse(CodeViewPrefs? store) => _shared = store;

  /// Whether long lines wrap on a screen [screenWidth] logical pixels wide.
  bool wrapFor(double screenWidth) => _wrap ?? screenWidth < phoneMaxWidth;

  Future<void> setWrap(bool value) async {
    if (_wrap == value) return;
    _wrap = value;
    notifyListeners();
    await _prefs?.setBool(wrapKey, value);
  }

  double get fontScale => _fontScale;

  Future<void> setFontScale(double value) async {
    final next = _normalise(value);
    if (next == _fontScale) return;
    _fontScale = next;
    notifyListeners();
    await _prefs?.setDouble(fontScaleKey, next);
  }

  /// One step bigger (`direction > 0`) or smaller.
  Future<void> stepFont(int direction) =>
      setFontScale(_fontScale + direction.sign * fontScaleStep);

  bool get canGrow => _fontScale < maxFontScale;
  bool get canShrink => _fontScale > minFontScale;

  /// The text scale code is painted with.
  static double effectiveScale({required double system, required double user}) {
    final value = system * user;
    if (value.isNaN) return 1.0;
    return _round(value.clamp(minEffectiveScale, maxEffectiveScale));
  }

  static double _normalise(double value) {
    if (value.isNaN) return 1.0;
    return _round(value.clamp(minFontScale, maxFontScale));
  }

  /// Rounds to 1/100 so repeated steps never drift off the 0.1 grid.
  static double _round(double value) => (value * 100).roundToDouble() / 100;
}
