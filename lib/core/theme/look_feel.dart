import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'box_fill.dart';
import 'component_profile.dart';
import 'glass_look.dart' show GlassMaterial;
import 'theme_contrast.dart';

/// Look & Feel: the short list of choices (appearance, accent, light and dark
/// background) from which a whole theme is derived. The 42 presets of the
/// catalogue stay as «Más temas»; whichever of the two the user chose last is
/// the one in force ([LookFeelSource]).
///
/// The derivation produces the very same [HermesThemeColors] tokens the
/// presets carry, so nothing downstream knows the difference. Contrast is
/// guaranteed by construction: every ink is searched against the page, the
/// surface and the raised surface of its background (see [LookFeel.preset]).

/// Which of the two theme systems is in force.
enum LookFeelSource {
  /// The Look & Feel choices below.
  derived,

  /// A theme of the catalogue (or a custom one), chosen in «Más temas».
  list,
}

enum LookAppearance { system, light, dark }

enum LookLightBackground { white, paper }

enum LookDarkBackground { midnight, black, gray }

/// One of the nine fixed accents. [seed] is the hue the user sees in the
/// circle; the colour actually painted is the seed nudged, only when needed,
/// until it reads on the chosen background ([LookFeel.accentFor]).
@immutable
final class LookAccent {
  const LookAccent(this.id, this.seed);

  final String id;
  final Color seed;
}

/// Id of the tenth circle, the free colour picker.
const String lookAccentCustomId = 'custom';

/// The page, surfaces and inks of one background. Dark and light alike.
@immutable
final class _Ground {
  const _Ground({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceVariant,
    required this.divider,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.error,
    required this.warning,
    required this.success,
  });

  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color surfaceVariant;
  final Color divider;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;
  final Color error;
  final Color warning;
  final Color success;
}

/// The immutable choices of the Look & Feel screen.
@immutable
final class LookFeelSettings {
  const LookFeelSettings({
    this.source = LookFeelSource.list,
    this.appearance = LookAppearance.system,
    this.accentId = 'terracotta',
    this.customAccent = const Color(0xFFC96442),
    this.lightBackground = LookLightBackground.paper,
    this.darkBackground = LookDarkBackground.gray,
  });

  final LookFeelSource source;
  final LookAppearance appearance;

  /// One of [LookFeel.accents]' ids, or [lookAccentCustomId].
  final String accentId;
  final Color customAccent;
  final LookLightBackground lightBackground;
  final LookDarkBackground darkBackground;

  bool get derived => source == LookFeelSource.derived;

  /// The colour the accent derives from.
  Color get accentSeed => accentId == lookAccentCustomId
      ? customAccent
      : LookFeel.accentById(accentId).seed;

  LookFeelSettings copyWith({
    LookFeelSource? source,
    LookAppearance? appearance,
    String? accentId,
    Color? customAccent,
    LookLightBackground? lightBackground,
    LookDarkBackground? darkBackground,
  }) => LookFeelSettings(
    source: source ?? this.source,
    appearance: appearance ?? this.appearance,
    accentId: accentId ?? this.accentId,
    customAccent: customAccent ?? this.customAccent,
    lightBackground: lightBackground ?? this.lightBackground,
    darkBackground: darkBackground ?? this.darkBackground,
  );

  /// The brightness the app shows for [platform] (the system's, when the
  /// appearance follows it).
  Brightness resolveBrightness(Brightness platform) => switch (appearance) {
    LookAppearance.system => platform,
    LookAppearance.light => Brightness.light,
    LookAppearance.dark => Brightness.dark,
  };

  @override
  bool operator ==(Object other) =>
      other is LookFeelSettings &&
      other.source == source &&
      other.appearance == appearance &&
      other.accentId == accentId &&
      other.customAccent == customAccent &&
      other.lightBackground == lightBackground &&
      other.darkBackground == darkBackground;

  @override
  int get hashCode => Object.hash(
    source,
    appearance,
    accentId,
    customAccent,
    lightBackground,
    darkBackground,
  );
}

/// The Look & Feel derivation: seeds, backgrounds and the contrast rules.
abstract final class LookFeel {
  /// Contrast a control (the accent as a button fill, a selection ring) must
  /// reach against every surface it can sit on (WCAG 1.4.11).
  static const double componentContrast = 3.0;

  /// Contrast of text in the accent colour on the page and on every surface.
  static const double accentTextContrast = 4.5;

  /// Contrast of the label on the accent fill.
  static const double onAccentContrast = 4.5;

  /// Contrast of primary and secondary text on every surface. Above AA's 4.5
  /// so that a card fill that is a step lighter than today's still reads.
  static const double primaryContrast = 7.0;
  static const double secondaryContrast = 5.0;

  /// The nine fixed accents. Mid-luminance tones, so that the nudge needed
  /// on either a black or a white page is small and the circle looks like
  /// what is painted.
  static const List<LookAccent> accents = [
    LookAccent('terracotta', Color(0xFFC96442)),
    LookAccent('orange', Color(0xFFD9791A)),
    LookAccent('rose', Color(0xFFD6457A)),
    LookAccent('violet', Color(0xFF8A5CE0)),
    LookAccent('indigo', Color(0xFF5B6CFF)),
    LookAccent('blue', Color(0xFF2F80ED)),
    LookAccent('teal', Color(0xFF14A3A3)),
    LookAccent('green', Color(0xFF2E9E5B)),
    LookAccent('slate', Color(0xFF7A8794)),
  ];

  static LookAccent accentById(String id) => accents.firstWhere(
    (accent) => accent.id == id,
    orElse: () => accents.first,
  );

  // Backgrounds. Paper is the warm page already approved for light themes
  // (the Claude family's), White a clean one; Midnight is a deep night blue,
  // Black a near-black with a subtle step between page and surfaces, Gray a
  // charcoal.
  static const _white = _Ground(
    brightness: Brightness.light,
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFF5F6F8),
    surfaceVariant: Color(0xFFEAECF0),
    divider: Color(0xFFD5D8DE),
    textPrimary: Color(0xFF16181D),
    textSecondary: Color(0xFF4A505C),
    textDisabled: Color(0xFF8A909C),
    error: Color(0xFFB23A30),
    warning: Color(0xFF8F6420),
    success: Color(0xFF3F7048),
  );
  static const _paper = _Ground(
    brightness: Brightness.light,
    background: Color(0xFFFAF9F5),
    surface: Color(0xFFFFFFFF),
    surfaceVariant: Color(0xFFF0EEE6),
    divider: Color(0xFFE2DED2),
    textPrimary: Color(0xFF3D3D3A),
    textSecondary: Color(0xFF55534D),
    textDisabled: Color(0xFF8E8C82),
    error: Color(0xFFB23A30),
    warning: Color(0xFF8F6420),
    success: Color(0xFF3F7048),
  );
  static const _midnight = _Ground(
    brightness: Brightness.dark,
    background: Color(0xFF0A1020),
    surface: Color(0xFF111A2E),
    surfaceVariant: Color(0xFF1A2540),
    divider: Color(0xFF2A3860),
    textPrimary: Color(0xFFE9EDF8),
    textSecondary: Color(0xFFA9B4D0),
    textDisabled: Color(0xFF6D7898),
    error: Color(0xFFE5776B),
    warning: Color(0xFFD9A55F),
    success: Color(0xFF7FB88A),
  );
  static const _black = _Ground(
    brightness: Brightness.dark,
    background: Color(0xFF020202),
    surface: Color(0xFF0E0E0E),
    surfaceVariant: Color(0xFF181818),
    divider: Color(0xFF2B2B2B),
    textPrimary: Color(0xFFF1F1F1),
    textSecondary: Color(0xFFB0B0B0),
    textDisabled: Color(0xFF727272),
    error: Color(0xFFE5776B),
    warning: Color(0xFFD9A55F),
    success: Color(0xFF7FB88A),
  );
  static const _gray = _Ground(
    brightness: Brightness.dark,
    background: Color(0xFF1C1C1F),
    surface: Color(0xFF26262A),
    surfaceVariant: Color(0xFF313136),
    divider: Color(0xFF46464C),
    textPrimary: Color(0xFFF2F2F5),
    textSecondary: Color(0xFFB6B6BE),
    textDisabled: Color(0xFF7D7D86),
    error: Color(0xFFE5776B),
    warning: Color(0xFFD9A55F),
    success: Color(0xFF7FB88A),
  );

  static _Ground _groundFor(LookFeelSettings s, Brightness brightness) =>
      brightness == Brightness.light
      ? switch (s.lightBackground) {
          LookLightBackground.white => _white,
          LookLightBackground.paper => _paper,
        }
      : switch (s.darkBackground) {
          LookDarkBackground.midnight => _midnight,
          LookDarkBackground.black => _black,
          LookDarkBackground.gray => _gray,
        };

  /// Page, surface and raised surface of the background of [s] in
  /// [brightness], and the bodies lifted from the page (a group, a card,
  /// the track of a segmented control): what the inks and the accent are
  /// checked against. The bodies come from the page alone
  /// ([HermesBoxFill]), so they are known before any ink is.
  static List<Color> surfacesOf(LookFeelSettings s, Brightness brightness) {
    final ground = _groundFor(s, brightness);
    final seed = HermesThemeColors(
      background: ground.background,
      surface: ground.surface,
      surfaceVariant: ground.surfaceVariant,
      accent: ground.textPrimary,
      accentHover: ground.textPrimary,
      onAccent: ground.background,
      textPrimary: ground.textPrimary,
      textSecondary: ground.textSecondary,
      textDisabled: ground.textDisabled,
      error: ground.error,
      success: ground.success,
      warning: ground.warning,
      divider: ground.divider,
    );
    final boxes = HermesBoxFill.of(seed);
    return [
      ground.background,
      ground.surface,
      ground.surfaceVariant,
      boxes.group,
      boxes.card,
      GlassMaterial.pieceOverGroup(seed),
    ];
  }

  /// The swatch of the light [background]: page, surface.
  static (Color, Color) lightSwatch(LookLightBackground background) {
    final ground = switch (background) {
      LookLightBackground.white => _white,
      LookLightBackground.paper => _paper,
    };
    return (ground.background, ground.surface);
  }

  /// The swatch of the dark [background]: page, surface.
  static (Color, Color) darkSwatch(LookDarkBackground background) {
    final ground = switch (background) {
      LookDarkBackground.midnight => _midnight,
      LookDarkBackground.black => _black,
      LookDarkBackground.gray => _gray,
    };
    return (ground.background, ground.surface);
  }

  static Color _reach(Color ink, List<Color> surfaces, double minimum) =>
      ThemeContrast.adjustForContrast(ink, surfaces, minimum: minimum);

  /// The accent as a control fill for [seed] on [surfaces]: the seed itself
  /// when it already reads at [componentContrast], else the smallest step
  /// towards black or white that does.
  static Color accentFor(Color seed, List<Color> surfaces) =>
      _reach(seed.withValues(alpha: 1), surfaces, componentContrast + 0.05);

  /// The colour the accent circle of [accentId] shows on [s] in
  /// [brightness] (what the app will paint, after the readable ink pass of
  /// the preset), so the circle is honest.
  static Color accentShown(
    LookFeelSettings s,
    String accentId,
    Brightness brightness,
  ) => preset(s.copyWith(accentId: accentId), brightness).colors.accent;

  /// The tokens of [s] in [brightness]: the same [HermesThemeColors] a preset
  /// has. Every ink reaches its contrast against the page, the surface and
  /// the raised surface:
  ///
  ///  * primary text [primaryContrast], secondary [secondaryContrast]
  ///    (tertiary is derived by [HermesThemeColors] to AA);
  ///  * the accent fill [componentContrast], the accent as text
  ///    [accentTextContrast];
  ///  * the label on the accent fill [onAccentContrast].
  static HermesThemeColors colors(LookFeelSettings s, Brightness brightness) {
    final ground = _groundFor(s, brightness);
    final surfaces = surfacesOf(s, brightness);
    final dark = ground.brightness == Brightness.dark;
    final accent = accentFor(s.accentSeed, surfaces);
    final hover = ThemeContrast.blend(
      accent,
      dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
      0.16,
    );
    final accentText = _reach(accent, surfaces, accentTextContrast + 0.05);
    const nearBlack = Color(0xFF101114);
    const nearWhite = Color(0xFFFFFFFF);
    var onAccent =
        ThemeContrast.ratio(nearBlack, accent) >=
            ThemeContrast.ratio(nearWhite, accent)
        ? nearBlack
        : nearWhite;
    if (ThemeContrast.ratio(onAccent, accent) < onAccentContrast + 0.05) {
      onAccent = ThemeContrast.bestBlackOrWhite(accent);
    }
    return HermesThemeColors(
      background: ground.background,
      surface: ground.surface,
      surfaceVariant: ground.surfaceVariant,
      accent: accent,
      accentHover: hover,
      accentText: accentText,
      onAccent: onAccent,
      textPrimary: _reach(ground.textPrimary, surfaces, primaryContrast + 0.05),
      textSecondary: _reach(
        ground.textSecondary,
        surfaces,
        secondaryContrast + 0.05,
      ),
      textDisabled: ground.textDisabled,
      error: _reach(ground.error, surfaces, 4.55),
      warning: _reach(ground.warning, surfaces, 4.55),
      success: _reach(ground.success, surfaces, 4.55),
      divider: ground.divider,
    );
  }

  /// The theme preset of [s] in [brightness], run through the same readable
  /// ink pass as the catalogue's presets.
  static HermesThemePreset preset(LookFeelSettings s, Brightness brightness) =>
      AppTheme.readablePreset(
        HermesThemePreset(
          id: brightness == Brightness.dark ? 'look-dark' : 'look-light',
          name: 'Look & Feel',
          tagline: 'look & feel',
          brightness: brightness,
          colors: colors(s, brightness),
          fontFamily: 'Inter',
          radius: 16.0,
          titleWeight: FontWeight.w600,
        ),
      );

  /// The [ThemeData] of [s] in [brightness].
  static ThemeData themeData(
    LookFeelSettings s,
    Brightness brightness, {
    ComponentProfile componentProfile = ComponentProfiles.minimal,
  }) => AppTheme.fromPreset(
    preset(s, brightness),
    componentProfile: componentProfile,
  );

  /// What `MaterialApp.theme` and `darkTheme` take: with «Sistema» the light
  /// theme and the dark one (Material follows the system by itself), else one
  /// theme.
  static ({ThemeData theme, ThemeData? darkTheme}) materialThemes(
    LookFeelSettings s, {
    ComponentProfile componentProfile = ComponentProfiles.minimal,
  }) {
    ThemeData build(Brightness b) =>
        themeData(s, b, componentProfile: componentProfile);
    return switch (s.appearance) {
      LookAppearance.system => (
        theme: build(Brightness.light),
        darkTheme: build(Brightness.dark),
      ),
      LookAppearance.light => (theme: build(Brightness.light), darkTheme: null),
      LookAppearance.dark => (theme: build(Brightness.dark), darkTheme: null),
    };
  }
}

/// Persistence of the Look & Feel choices (SharedPreferences), the same
/// ChangeNotifier shape as the other app-wide preferences.
///
/// Migration: an install that never chose anything here has no
/// [sourceKey], which reads as [LookFeelSource.list]: the preset and mode it
/// had keep painting exactly as before and the screen shows them as «Tema: X».
/// The appearance a later «Volver al Look & Feel» starts from is taken from
/// that preset: its mode, or «Sistema» when it followed the system.
class LookFeelPrefs extends ChangeNotifier {
  LookFeelPrefs(this._prefs) : _settings = read(_prefs);

  static const String sourceKey = 'lfl_source';
  static const String appearanceKey = 'lfl_appearance';
  static const String accentKey = 'lfl_accent';
  static const String customAccentKey = 'lfl_accent_custom';
  static const String lightBackgroundKey = 'lfl_light_background';
  static const String darkBackgroundKey = 'lfl_dark_background';

  // The theme preferences of before Look & Feel (read only).
  static const String _activeThemeKey = 'active_theme_profile_id';
  static const String _legacyThemeKey = 'theme_mode';
  static const String _followSystemKey = 'theme_follow_system';

  final SharedPreferences _prefs;
  LookFeelSettings _settings;

  LookFeelSettings get settings => _settings;

  /// Reads [prefs]; pure, so it doubles as the migration under test.
  static LookFeelSettings read(SharedPreferences prefs) {
    T pick<T extends Enum>(List<T> values, String key, T fallback) {
      final raw = prefs.getString(key);
      for (final value in values) {
        if (value.name == raw) return value;
      }
      return fallback;
    }

    const defaults = LookFeelSettings();
    final accentRaw = prefs.getString(accentKey);
    final accentOk =
        accentRaw == lookAccentCustomId ||
        LookFeel.accents.any((a) => a.id == accentRaw);
    final custom = prefs.getInt(customAccentKey);
    final storedAppearance = prefs.getString(appearanceKey);
    return LookFeelSettings(
      source: pick(LookFeelSource.values, sourceKey, LookFeelSource.list),
      appearance: storedAppearance == null
          ? _legacyAppearance(prefs)
          : pick(LookAppearance.values, appearanceKey, defaults.appearance),
      accentId: accentOk ? accentRaw! : defaults.accentId,
      customAccent: custom == null
          ? defaults.customAccent
          : Color(custom | 0xFF000000),
      lightBackground: pick(
        LookLightBackground.values,
        lightBackgroundKey,
        defaults.lightBackground,
      ),
      darkBackground: pick(
        LookDarkBackground.values,
        darkBackgroundKey,
        defaults.darkBackground,
      ),
    );
  }

  /// The mode of the preset the user has today.
  static LookAppearance _legacyAppearance(SharedPreferences prefs) {
    if (prefs.getBool(_followSystemKey) ?? false) return LookAppearance.system;
    final stored =
        prefs.getString(_activeThemeKey) ?? prefs.getString(_legacyThemeKey);
    if (stored == null) return LookAppearance.system;
    final id = AppTheme.migrateStoredThemeId(stored);
    final preset = AppTheme.presets.where((p) => p.id == id).firstOrNull;
    if (preset == null) return LookAppearance.system;
    return preset.isDark ? LookAppearance.dark : LookAppearance.light;
  }

  /// Applies [next] and stores it. Every key is written, so a restart reads
  /// exactly this.
  Future<void> update(LookFeelSettings next) async {
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    await _prefs.setString(sourceKey, next.source.name);
    await _prefs.setString(appearanceKey, next.appearance.name);
    await _prefs.setString(accentKey, next.accentId);
    await _prefs.setInt(customAccentKey, next.customAccent.toARGB32());
    await _prefs.setString(lightBackgroundKey, next.lightBackground.name);
    await _prefs.setString(darkBackgroundKey, next.darkBackground.name);
  }

  /// A change of a Look & Feel choice puts Look & Feel in force.
  Future<void> setAppearance(LookAppearance value) => update(
    _settings.copyWith(source: LookFeelSource.derived, appearance: value),
  );

  Future<void> setAccent(String id) =>
      update(_settings.copyWith(source: LookFeelSource.derived, accentId: id));

  Future<void> setCustomAccent(Color color) => update(
    _settings.copyWith(
      source: LookFeelSource.derived,
      accentId: lookAccentCustomId,
      customAccent: color.withValues(alpha: 1),
    ),
  );

  Future<void> setLightBackground(LookLightBackground value) => update(
    _settings.copyWith(source: LookFeelSource.derived, lightBackground: value),
  );

  Future<void> setDarkBackground(LookDarkBackground value) => update(
    _settings.copyWith(source: LookFeelSource.derived, darkBackground: value),
  );

  /// «Volver al Look & Feel»: the last choices, in force again.
  Future<void> returnToLookFeel() =>
      update(_settings.copyWith(source: LookFeelSource.derived));

  /// A theme of the catalogue was chosen in «Más temas».
  Future<void> useList() =>
      update(_settings.copyWith(source: LookFeelSource.list));
}
