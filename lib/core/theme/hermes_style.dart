// The "Style" of the app: how every theme is built.
//
// Glass (the enum's `soft`) is the style, FIXED for everybody: the Style
// selector was taken out of the app, so the real store ignores any value an
// older install saved (Outline, from a 9800/9801 build) and cannot be
// changed; only a store made with [HermesStylePrefs.inMemory], a test seam,
// can hold Outline. Glass is the structure of the terminal looks (thin
// outlines, tracked small-capital section labels, a vivid accent) with the
// glass material on the surfaces. Outline is the flat alternative, kept in
// code and reachable only from tests.
//
// Outline gives any theme the structure of the terminal looks: flat surfaces
// with a thin outline, no clouds of colour behind them, no glass, and titles
// and section labels in capitals with tracking. Only the colours change from
// one theme to the next. Glass respects the Glass level.
//
// Outline does not add a second mechanism: it turns on, for the active theme,
// the flag the terminal presets already carry
// ([HermesThemeColors.uppercaseTitles]), which is what the header, the
// section labels, the backdrop, the primary button and the glass layer read.
// Palettes, the chosen font and the radii are never touched.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';

/// How the surfaces and the titles of a theme are built.
enum HermesStyle {
  contour,
  soft;

  static HermesStyle fromName(String? name) {
    for (final style in values) {
      if (style.name == name) return style;
    }
    return HermesStyle.soft;
  }
}

/// The device setting: one style for the whole app. It is fixed on
/// [HermesStyle.soft], the Glass style (see the file header): a store read
/// from disk ignores the saved value and [setStyle] does nothing on it.
class HermesStylePrefs extends ChangeNotifier {
  HermesStylePrefs._(this._prefs, {required bool fixed})
    : _fixed = fixed,
      _style = fixed
          ? HermesStyle.soft
          : HermesStyle.fromName(_prefs?.getString(styleKey));

  /// The key older builds saved the choice under. It is no longer read.
  static const String styleKey = 'hermes_style';

  final SharedPreferences? _prefs;
  final bool _fixed;
  HermesStyle _style;

  static HermesStylePrefs? _shared;

  static HermesStylePrefs get shared =>
      _shared ??= HermesStylePrefs._(null, fixed: true);

  static Future<HermesStylePrefs> load([SharedPreferences? prefs]) async {
    final resolved = prefs ?? await SharedPreferences.getInstance();
    final store = HermesStylePrefs._(resolved, fixed: true);
    final previous = _shared;
    _shared = store;
    previous?.notifyListeners();
    return store;
  }

  @visibleForTesting
  static void debugUse(HermesStylePrefs? store) => _shared = store;

  /// A store that lives in memory, for a test. Unlike the real one it can
  /// hold and change to any style, so Outline stays testable.
  @visibleForTesting
  factory HermesStylePrefs.inMemory([HermesStyle style = HermesStyle.soft]) =>
      HermesStylePrefs._(null, fixed: false).._style = style;

  HermesStyle get style => _style;

  bool get isContour => _style == HermesStyle.contour;

  /// No effect on the real store (the style is fixed, see the file header).
  Future<void> setStyle(HermesStyle value) async {
    if (_fixed || _style == value) return;
    _style = value;
    notifyListeners();
    await _prefs?.setString(styleKey, value.name);
  }
}

/// Hands the style to the tree. Without one above (a test, a lone widget)
/// the shared store answers.
class HermesStyleScope extends InheritedNotifier<HermesStylePrefs> {
  const HermesStyleScope({
    required HermesStylePrefs prefs,
    required super.child,
    super.key,
  }) : super(notifier: prefs);

  /// The style the user asked for; it listens.
  static HermesStyle styleOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<HermesStyleScope>();
    return (scope?.notifier ?? HermesStylePrefs.shared).style;
  }
}

/// [theme] built in [style]. Soft returns it as it is; Outline turns on the
/// capitals-and-flat flag of the terminal looks on its colours, whatever the
/// preset or the Theme Studio profile it came from.
ThemeData applyHermesStyle(ThemeData theme, HermesStyle style) {
  if (style != HermesStyle.contour) return theme;
  final colors = theme.hermes;
  if (colors.outlined) return theme;
  // `extensions` replaces the whole set: carry the others along. Typed as
  // objects and cast, as in AppTheme, to avoid the generic widening of a
  // spread of heterogeneous extensions.
  final extensions = <Object>[
    for (final extension in theme.extensions.values)
      if (extension is! HermesThemeColors) extension,
    colors.copyWith(uppercaseTitles: true, outlined: true),
  ].cast<ThemeExtension<dynamic>>();
  return theme.copyWith(extensions: extensions);
}
