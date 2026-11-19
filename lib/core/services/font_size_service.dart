import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show TextScaler;
import 'package:shared_preferences/shared_preferences.dart';

/// The app's text scaler: Hermes' own size ([FontSizeService.scale]) applied
/// to the font size, then Android's accessibility scale ([system]) with its
/// own curve — Android 14+ scales text non-linearly (large text grows less),
/// which `system.scale(1.0) * app` used to flatten into a straight line.
/// Never a cap: at app scale ≥ 1 every size is at least what the system
/// alone gives.
///
/// The system curve is sampled when composed, at the font sizes of
/// Android's non-linear table (and around them), and interpolated: the
/// result is a value, like the linear scaler it replaces. Flutter's system
/// scaler reads the live platform setting on every call, so wrapping it
/// would let a route kept on a frozen MediaQuery (CoveredRouteMediaQueryFreeze)
/// change size behind its own data.
TextScaler composeAppTextScaler(TextScaler system, double appScale) =>
    _AppTextScaler(appScale, [
      for (final size in _AppTextScaler.samples) system.scale(size),
    ]);

final class _AppTextScaler extends TextScaler {
  _AppTextScaler(this.appScale, List<double> scaled)
    : _scaled = List.unmodifiable(scaled);

  /// Font sizes the system curve is read at: Android's FontScaleConverter
  /// table points (8–100 sp) plus the ends. Between them the platform itself
  /// interpolates linearly, so the samples reproduce its curve.
  static const List<double> samples = [
    1, 8, 10, 12, 14, 18, 20, 24, 30, 48, 64, 100, 200,
  ];

  final double appScale;
  final List<double> _scaled;

  @override
  double scale(double fontSize) {
    final x = fontSize * appScale;
    if (x <= 0) return 0;
    if (x <= samples.first) return x * _scaled.first / samples.first;
    for (var i = 1; i < samples.length; i++) {
      if (x <= samples[i]) {
        final t = (x - samples[i - 1]) / (samples[i] - samples[i - 1]);
        return _scaled[i - 1] + t * (_scaled[i] - _scaled[i - 1]);
      }
    }
    return x * _scaled.last / samples.last;
  }

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is _AppTextScaler &&
      other.appScale == appScale &&
      listEquals(other._scaled, _scaled);

  @override
  int get hashCode => Object.hash(appScale, Object.hashAll(_scaled));

  @override
  String toString() => 'app($appScale) then system ${_scaled[4] / 14}x@14';
}

/// Hermes text size: the app density ([defaultScale], shown as 100 %) times
/// the reader's own [factor], chosen in Ajustes → Aspecto → Look & Feel.
///
/// The result is multiplied by Android's accessibility text scale in
/// `MaterialApp.builder`, so it never limits the size set in the system.
///
/// The range ([minFactor]–[maxFactor]) is the one the layout was checked at
/// on narrow phones, Fold and tablets (test/text_size_range_test.dart).
class FontSizeService extends ChangeNotifier {
  /// The density Hermes ships with: what «100 %» means in Settings.
  static const double defaultScale = 1.10;

  /// The default density (kept for callers that size against it).
  static const double fixedScale = defaultScale;

  /// From the sweep (test/text_size_range_test.dart): Settings, a room chat
  /// with the keyboard up, the Bots list with its New menu and the two real
  /// confirmations with the longest labels lay out without overflow from
  /// 0.85 to 1.50 on 360×640, 412×915, Fold cover/inner and tablet, in
  /// English and in es/de/fr/pt/it/ja/zh, and still at Android 130 %/200 %
  /// on top of 1.50.
  static const double minFactor = 0.85;
  static const double maxFactor = 1.50;
  static const double step = 0.05;

  /// A new key: values a 1.3 build stored under `font_size_scale` (before
  /// the size was fixed) must not come back unasked.
  static const String prefsKey = 'app_text_size_factor';

  final SharedPreferences _prefs;
  double _factor;

  FontSizeService(this._prefs) : _factor = _read(_prefs);

  static double _read(SharedPreferences prefs) {
    try {
      final stored = prefs.getDouble(prefsKey);
      return stored == null ? 1.0 : normalizeFactor(stored);
    } catch (_) {
      return 1.0;
    }
  }

  /// The reader's factor over [defaultScale] (1.0 = 100 %).
  double get factor => _factor;

  /// The app text scale before Android's own (see the class comment).
  double get scale => defaultScale * _factor;

  bool get isDefault => _factor == 1.0;

  /// Steps the slider offers between [minFactor] and [maxFactor].
  static int get divisions => ((maxFactor - minFactor) / step).round();

  /// [value] clamped to the range and snapped to a [step]; 1.0 when it is
  /// not a number.
  static double normalizeFactor(double value) {
    if (!value.isFinite) return 1.0;
    final clamped = value.clamp(minFactor, maxFactor).toDouble();
    final steps = ((clamped - minFactor) / step).round();
    final snapped = minFactor + steps * step;
    return double.parse(snapped.toStringAsFixed(2));
  }

  Future<void> setFactor(double value) async {
    final next = normalizeFactor(value);
    if (next == _factor) return;
    _factor = next;
    notifyListeners();
    if (next == 1.0) {
      await _prefs.remove(prefsKey);
    } else {
      await _prefs.setDouble(prefsKey, next);
    }
  }

  Future<void> reset() => setFactor(1.0);
}
