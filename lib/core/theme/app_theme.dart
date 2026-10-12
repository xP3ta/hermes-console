import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/tokens.dart' show HermesChrome;
import 'component_profile.dart';
import 'motion.dart';
import 'theme_contrast.dart';
import 'theme_profile.dart';

enum AppThemeMode {
  dark('dark'),
  oled('oled'),
  light('light'),
  hermesTeal('teal');

  const AppThemeMode(this.storageKey);

  final String storageKey;

  static AppThemeMode fromStorage(String? value) {
    return AppThemeMode.values.firstWhere(
      (mode) => mode.storageKey == value,
      orElse: () => AppThemeMode.dark,
    );
  }
}

@immutable
class HermesThemeColors extends ThemeExtension<HermesThemeColors> {
  const HermesThemeColors({
    required this.background,
    required this.surface,
    required this.surfaceVariant,
    required this.accent,
    required this.accentHover,
    required this.onAccent,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.error,
    required this.success,
    required this.warning,
    required this.divider,
    this.secondary = const Color(0xFFE8821C),
    this.uppercaseTitles = false,
    Color? accentText,
    Color? textTertiary,
    // El parámetro público se llama `accentText` (el token que consumirán
    // las pantallas); `this._accentText` rompería ese nombre de cara al
    // llamador, así que se asigna a mano en el initializer.
  })
    // ignore: prefer_initializing_formals
    : _accentText = accentText,
       // ignore: prefer_initializing_formals
       _textTertiary = textTertiary;

  final Color background;
  final Color surface;
  final Color surfaceVariant;
  final Color accent;
  final Color accentHover;
  final Color onAccent;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;
  final Color error;
  final Color success;
  final Color warning;
  final Color divider;

  /// Color de contraste de marca del tema: el segundo color que rompe el
  /// monocromo (FAB, enlaces, chips seleccionados, badges). Lo inyecta el
  /// preset en [AppTheme._baseTheme]; las paletas const no lo declaran.
  final Color secondary;

  /// Si el tema es de estética terminal: [HermesAppBar] muestra el título de
  /// pantalla en MAYÚSCULAS. Lo inyecta el preset; default false.
  final bool uppercaseTitles;

  /// Valor declarado por el preset para [accentText]; `null` cuando el preset
  /// no necesita anular el fallback (paletas oscuras, donde `accent` ya
  /// cumple AA de sobra sobre `background`).
  final Color? _accentText;

  /// Color de acento pensado para pintar TEXTO sobre `background` (no
  /// fondos/bordes, para eso sigue usándose [accent]). En temas oscuros
  /// coincide con `accent`. En temas claros cuyo `accent` no alcanza el
  /// contraste AA 4.5:1 sobre `background` (p. ej. el ámbar `#E8821C` da
  /// ~2.6:1 sobre `#F7F7F7`), el preset declara aquí una variante oscurecida
  /// que sí lo cumple. Auditoría 2026-07-02, hallazgo C5c.
  Color get accentText => _accentText ?? accent;

  /// Explicit tertiary ink (set by the presets); `null` derives it.
  final Color? _textTertiary;

  static final Expando<Color> _derivedTertiary = Expando<Color>('textTertiary');

  /// rt1215: ink for read-only tertiary text (timestamps, metadata,
  /// captions, counters, hints). [textDisabled] stays reserved for controls
  /// that cannot be used right now, which WCAG exempts; tertiary text is
  /// read, so it is [textDisabled] lifted towards black or white (same hue,
  /// smallest step) until it reaches AA 4.5:1 on the background, the surface
  /// and the surface variant. Every palette gets it, presets and custom
  /// profiles alike.
  Color get textTertiary =>
      _textTertiary ??
      (_derivedTertiary[this] ??= readableTertiary(
        textDisabled,
        background: background,
        surface: surface,
        surfaceVariant: surfaceVariant,
      ));

  /// Smallest lift of [disabled] that reads at AA on all three surfaces.
  static Color readableTertiary(
    Color disabled, {
    required Color background,
    required Color surface,
    required Color surfaceVariant,
  }) => ThemeContrast.adjustForContrast(disabled, [
    background,
    surface,
    surfaceVariant,
  ], minimum: 4.5);

  @override
  HermesThemeColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceVariant,
    Color? accent,
    Color? accentHover,
    Color? onAccent,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDisabled,
    Color? error,
    Color? success,
    Color? warning,
    Color? divider,
    Color? secondary,
    bool? uppercaseTitles,
    Color? accentText,
    Color? textTertiary,
  }) {
    // A new page or disabled ink invalidates an explicit tertiary: let the
    // copy derive its own.
    final keepTertiary =
        background == null &&
        surface == null &&
        surfaceVariant == null &&
        textDisabled == null;
    return HermesThemeColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceVariant: surfaceVariant ?? this.surfaceVariant,
      accent: accent ?? this.accent,
      accentHover: accentHover ?? this.accentHover,
      onAccent: onAccent ?? this.onAccent,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textDisabled: textDisabled ?? this.textDisabled,
      error: error ?? this.error,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      divider: divider ?? this.divider,
      secondary: secondary ?? this.secondary,
      uppercaseTitles: uppercaseTitles ?? this.uppercaseTitles,
      accentText: accentText ?? _accentText,
      textTertiary: textTertiary ?? (keepTertiary ? _textTertiary : null),
    );
  }

  @override
  HermesThemeColors lerp(ThemeExtension<HermesThemeColors>? other, double t) {
    if (other is! HermesThemeColors) return this;
    return HermesThemeColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceVariant: Color.lerp(surfaceVariant, other.surfaceVariant, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentHover: Color.lerp(accentHover, other.accentHover, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      error: Color.lerp(error, other.error, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      uppercaseTitles: t < 0.5 ? uppercaseTitles : other.uppercaseTitles,
      accentText: Color.lerp(accentText, other.accentText, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
    );
  }
}

extension HermesThemeExtension on ThemeData {
  HermesThemeColors get hermes =>
      extension<HermesThemeColors>() ?? AppTheme._darkColors;

  HermesComponentTheme get hermesComponents =>
      extension<HermesComponentTheme>() ??
      const HermesComponentTheme(ComponentProfiles.minimal);
}

/// Component-shape/motion tokens kept separate from theme color and typography.
@immutable
final class HermesComponentTheme extends ThemeExtension<HermesComponentTheme> {
  final ComponentProfile profile;

  const HermesComponentTheme(this.profile);

  @override
  HermesComponentTheme copyWith({ComponentProfile? profile}) =>
      HermesComponentTheme(profile ?? this.profile);

  @override
  HermesComponentTheme lerp(
    covariant ThemeExtension<HermesComponentTheme>? other,
    double t,
  ) => other is HermesComponentTheme && t >= 0.5 ? other : this;
}

/// Un tema con identidad propia: paleta completa (incluido el color del texto,
/// tintado a la familia del acento) para que cambiar de tema se sienta como
/// usar otra app, no solo recolorear un botón. Todos los temas son gratuitos;
/// el proyecto se sostiene exclusivamente mediante donaciones voluntarias.
@immutable
class HermesThemePreset {
  const HermesThemePreset({
    required this.id,
    required this.name,
    required this.tagline,
    required this.brightness,
    required this.colors,
    this.fontFamily = 'Inter',
    this.radius = 10.0,
    this.secondary,
    this.titleWeight = FontWeight.w600,
    this.titleSpacing = 0.0,
    this.uppercaseTitles = false,
    this.desktopOfficial = false,
    this.desktopFamily,
    this.family,
  });

  final String id;
  final String name;
  final String tagline;
  final Brightness brightness;
  final HermesThemeColors colors;
  final String fontFamily;
  final double radius;

  /// Color de contraste del tema. Si es null, cae a `colors.accentHover`.
  final Color? secondary;

  /// Carácter tipográfico de los títulos: peso y tracking. Junto con
  /// [fontFamily] dan personalidad sin tocar cada pantalla (tracking alto +
  /// fuente mono = aire terminal; peso alto + redondo = orgánico).
  final FontWeight titleWeight;
  final double titleSpacing;

  /// Títulos de pantalla en MAYÚSCULAS (estética terminal). Lo aplica
  /// [HermesAppBar] leyendo el flag desde el tema.
  final bool uppercaseTitles;

  /// Preset integrado oficialmente en Hermes Desktop. Android conserva sus
  /// colores canónicos, adaptados a los tokens Material/Hermes equivalentes.
  final bool desktopOfficial;

  /// Familia oficial de Hermes Desktop. Una familia puede publicar una
  /// variante clara y otra oscura sin duplicarse como si fueran temas
  /// independientes en el selector.
  final String? desktopFamily;

  /// Family of a Console theme (its light and dark variant share it).
  final String? family;

  /// One card per family in the Themes screen, with a Light/Dark selector.
  String get familyId => family ?? desktopFamily ?? id;

  bool get isDark => brightness == Brightness.dark;
}

class AppTheme {
  AppTheme._();

  // Hermes Teal palette — accent #4DD0E1 from official Hermes brand
  static const _backgroundTeal = Color(0xFF050E0F);
  static const _surfaceTeal = Color(0xFF0B1A1C);
  static const _surfaceVariantTeal = Color(0xFF112426);
  static const _accentTeal = Color(0xFF4DD0E1);
  static const _accentHoverTeal = Color(0xFF80DEEA);
  static const _onAccentTeal = Color(0xFF00191D);
  static const _textPrimaryTeal = Color(0xFFB2EBF2);
  static const _textSecondaryTeal = Color(0xFF4EABB7);
  static const _textDisabledTeal = Color(0xFF2A5F69);
  static const _dividerTeal = Color(0xFF112F33);

  // Charcoal profundo: las superficies se separan del fondo por bordes
  // sutiles, no por contraste de relleno (look consola premium de docs/design).
  static const _backgroundDark = Color(0xFF0B0B0B);
  static const _backgroundOled = Color(0xFF000000);
  static const _surface = Color(0xFF141414);
  static const _surfaceVariant = Color(0xFF1D1D1D);
  static const _accent = Color(0xFFE8821C);
  static const _accentHover = Color(0xFFF0A848);
  static const _onAccent = Color(0xFF0D0D0D);
  static const _textPrimary = Color(0xFFE8E8E8);
  static const _textSecondary = Color(0xFF8A8A8A);
  // WCAG AA: el dim previo (#4A4A4A, 2.2:1) no llegaba ni a 3:1 para iconos
  // desactivados/timestamps sobre el charcoal. #6B6B6B alcanza ≥3:1 sobre
  // background y surfaceVariant manteniendo la jerarquía atenuada.
  static const _textDisabled = Color(0xFF6B6B6B);
  static const _error = Color(0xFFFF4444);
  static const _success = Color(0xFF22CC44);
  static const _warning = Color(0xFFFFAA00);
  static const _divider = Color(0xFF242424);

  // Variante OLED: superficies aún más cercanas al negro puro.
  static const _surfaceOled = Color(0xFF0E0E0E);
  static const _surfaceVariantOled = Color(0xFF161616);
  static const _dividerOled = Color(0xFF1F1F1F);

  static const _darkColors = HermesThemeColors(
    background: _backgroundDark,
    surface: _surface,
    surfaceVariant: _surfaceVariant,
    accent: _accent,
    accentHover: _accentHover,
    onAccent: _onAccent,
    textPrimary: _textPrimary,
    textSecondary: _textSecondary,
    textDisabled: _textDisabled,
    error: _error,
    success: _success,
    warning: _warning,
    divider: _divider,
  );

  static const _oledColors = HermesThemeColors(
    background: _backgroundOled,
    surface: _surfaceOled,
    surfaceVariant: _surfaceVariantOled,
    accent: _accent,
    accentHover: _accentHover,
    onAccent: _onAccent,
    textPrimary: _textPrimary,
    textSecondary: _textSecondary,
    textDisabled: _textDisabled,
    error: _error,
    success: _success,
    warning: _warning,
    divider: _dividerOled,
  );

  static const _tealColors = HermesThemeColors(
    background: _backgroundTeal,
    surface: _surfaceTeal,
    surfaceVariant: _surfaceVariantTeal,
    accent: _accentTeal,
    accentHover: _accentHoverTeal,
    onAccent: _onAccentTeal,
    textPrimary: _textPrimaryTeal,
    textSecondary: _textSecondaryTeal,
    textDisabled: _textDisabledTeal,
    error: Color(0xFFEF5350),
    success: Color(0xFF4CAF50),
    warning: Color(0xFFFFA726),
    divider: _dividerTeal,
  );

  static const _lightColors = HermesThemeColors(
    background: Color(0xFFF7F7F7),
    surface: Color(0xFFFFFFFF),
    surfaceVariant: Color(0xFFEDEDED),
    accent: _accent,
    accentHover: _accentHover,
    onAccent: _onAccent,
    textPrimary: Color(0xFF151515),
    textSecondary: Color(0xFF5E5E5E),
    textDisabled: Color(0xFF9A9A9A),
    error: Color(0xFFB3261E),
    success: Color(0xFF137A2A),
    warning: Color(0xFFB26F00),
    divider: Color(0xFFDADADA),
    // WCAG AA: el ámbar de marca (#E8821C) da ~2.6:1 sobre este fondo, muy
    // por debajo de 4.5:1; #9A5300 (misma familia, oscurecido) da ~5.4:1.
    accentText: Color(0xFF9A5300),
  );

  // ── Soft palettes (1.2.15) ───────────────────────────────────────────
  // Owner direction: every theme feels like Claude's — graphite pages that
  // are never pure black or white, surfaces layered in small lightness
  // steps, a calm accent, quiet status colours and subtle hairlines. The
  // bands are measured on the Claude presets and checked for every preset
  // in theme_claude_bands_test; each family keeps its own hue.
  //
  // Console (the default) is Claude's structure in the icon's colours: the
  // graphite #26262A page and the terracotta #D97757 mark.
  //
  // Desktop families keep their names, modes and hues but are softened to
  // the same bands (owner priority over byte parity); the per-family
  // deviation from Desktop is documented in the design README. Every text
  // token reaches AA as declared, so [_withReadableInk] is a no-op on these.
  static const _consolePalette = HermesThemeColors(
    background: Color(0xFF26262A),
    surface: Color(0xFF2F2F34),
    surfaceVariant: Color(0xFF39393F),
    accent: Color(0xFFC86443),
    accentHover: Color(0xFFD97757),
    onAccent: Color(0xFF20120E),
    accentText: Color(0xFFEE8A69),
    textPrimary: Color(0xFFF2F2F5),
    textSecondary: Color(0xFFB5B5BD),
    textDisabled: Color(0xFF7B7B83),
    divider: Color(0xFF39393F),
    error: Color(0xFFE0695C),
    warning: Color(0xFFD9A066),
    success: Color(0xFF7FA37F),
  );
  static const _consoleLightPalette = HermesThemeColors(
    background: Color(0xFFF8F8FB),
    surface: Color(0xFFFFFFFF),
    surfaceVariant: Color(0xFFECECF2),
    accent: Color(0xFFB05233),
    accentHover: Color(0xFF9C4A2E),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF9C4A2E),
    textPrimary: Color(0xFF353539),
    textSecondary: Color(0xFF62626A),
    textDisabled: Color(0xFFA4A4AC),
    divider: Color(0xFFE2E2E9),
    error: Color(0xFFB23A30),
    warning: Color(0xFF8F6420),
    success: Color(0xFF4A7550),
  );
  static const _amberPalette = HermesThemeColors(
    background: Color(0xFF202020),
    surface: Color(0xFF292929),
    surfaceVariant: Color(0xFF313131),
    accent: Color(0xFFE39960),
    accentHover: Color(0xFFE5B173),
    onAccent: Color(0xFF25170C),
    accentText: Color(0xFFE39960),
    textPrimary: Color(0xFFE8E8E8),
    textSecondary: Color(0xFFA7A7A7),
    textDisabled: Color(0xFF707070),
    divider: Color(0xFF3A3A3A),
    error: Color(0xFFDD8179),
    warning: Color(0xFFEBB265),
    success: Color(0xFF7ABE7D),
  );
  static const _amberLightPalette = HermesThemeColors(
    background: Color(0xFFF7F7F5),
    surface: Color(0xFFFCFCFC),
    surfaceVariant: Color(0xFFECECE7),
    accent: Color(0xFFA5642C),
    accentHover: Color(0xFF935419),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF98581E),
    textPrimary: Color(0xFF303030),
    textSecondary: Color(0xFF595959),
    textDisabled: Color(0xFF808080),
    divider: Color(0xFFE1E1DA),
    error: Color(0xFF9E4238),
    warning: Color(0xFF885E27),
    success: Color(0xFF307639),
  );
  static const _claudePalette = HermesThemeColors(
    background: Color(0xFF262624),
    surface: Color(0xFF30302E),
    surfaceVariant: Color(0xFF3B3A37),
    accent: Color(0xFFC96442),
    accentHover: Color(0xFFD97757),
    onAccent: Color(0xFF1F120D),
    accentText: Color(0xFFD9927A),
    textPrimary: Color(0xFFF5F3EC),
    textSecondary: Color(0xFFAEAC9D),
    textDisabled: Color(0xFF7E7B70),
    divider: Color(0xFF3B3A37),
    error: Color(0xFFE0695C),
    warning: Color(0xFFD9A066),
    success: Color(0xFF7FA37F),
  );
  static const _claudeLightPalette = HermesThemeColors(
    background: Color(0xFFFAF9F5),
    surface: Color(0xFFFFFFFF),
    surfaceVariant: Color(0xFFF0EEE6),
    accent: Color(0xFFB0532F),
    accentHover: Color(0xFF9C4A2C),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF9C4A2C),
    textPrimary: Color(0xFF3D3D3A),
    textSecondary: Color(0xFF67655F),
    textDisabled: Color(0xFFAAA89E),
    divider: Color(0xFFE7E4DA),
    error: Color(0xFFB23A30),
    warning: Color(0xFF8F6420),
    success: Color(0xFF4A7550),
  );
  static const _steelPalette = HermesThemeColors(
    background: Color(0xFF1F2123),
    surface: Color(0xFF27292C),
    surfaceVariant: Color(0xFF2F3235),
    accent: Color(0xFFA3C0DD),
    accentHover: Color(0xFFB9CFE6),
    onAccent: Color(0xFF151B22),
    accentText: Color(0xFFA3C0DD),
    textPrimary: Color(0xFFE4E9F0),
    textSecondary: Color(0xFF9DA9BB),
    textDisabled: Color(0xFF667182),
    divider: Color(0xFF383B3E),
    error: Color(0xFFE2848B),
    warning: Color(0xFFDBB973),
    success: Color(0xFF76C9A6),
  );
  static const _steelLightPalette = HermesThemeColors(
    background: Color(0xFFF5F7F9),
    surface: Color(0xFFFCFCFD),
    surfaceVariant: Color(0xFFE9ECF1),
    accent: Color(0xFF486A8D),
    accentHover: Color(0xFF395A7C),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF486A8D),
    textPrimary: Color(0xFF2A313A),
    textSecondary: Color(0xFF4C5868),
    textDisabled: Color(0xFF778190),
    divider: Color(0xFFDCE1E7),
    error: Color(0xFF9F4248),
    warning: Color(0xFF835D26),
    success: Color(0xFF2E7254),
  );
  static const _bordeauxPalette = HermesThemeColors(
    background: Color(0xFF251E21),
    surface: Color(0xFF2E272A),
    surfaceVariant: Color(0xFF372F33),
    accent: Color(0xFFDBA082),
    accentHover: Color(0xFFE4B39A),
    onAccent: Color(0xFF251710),
    accentText: Color(0xFFDBA082),
    textPrimary: Color(0xFFF0E4E4),
    textSecondary: Color(0xFFBAA1A7),
    textDisabled: Color(0xFF7F6A72),
    divider: Color(0xFF40383C),
    error: Color(0xFFE2848B),
    warning: Color(0xFFDDB77B),
    success: Color(0xFF7AC295),
  );
  static const _bordeauxLightPalette = HermesThemeColors(
    background: Color(0xFFF9F6F5),
    surface: Color(0xFFFDFCFC),
    surfaceVariant: Color(0xFFF1EAE8),
    accent: Color(0xFF9A5B46),
    accentHover: Color(0xFF894B37),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF965742),
    textPrimary: Color(0xFF392C30),
    textSecondary: Color(0xFF66525A),
    textDisabled: Color(0xFF8F7982),
    divider: Color(0xFFE7DEDC),
    error: Color(0xFFA04247),
    warning: Color(0xFF835B26),
    success: Color(0xFF3B7254),
  );
  static const _draculaPalette = HermesThemeColors(
    background: Color(0xFF222228),
    surface: Color(0xFF2A2B31),
    surfaceVariant: Color(0xFF33343A),
    accent: Color(0xFF92D8E7),
    accentHover: Color(0xFFB5E9F0),
    onAccent: Color(0xFF0D1D21),
    accentText: Color(0xFF92D8E7),
    textPrimary: Color(0xFFEFEFE9),
    textSecondary: Color(0xFFADC5CF),
    textDisabled: Color(0xFF6D7487),
    divider: Color(0xFF3C3D44),
    error: Color(0xFFDD817B),
    warning: Color(0xFFBEC57B),
    success: Color(0xFF89D293),
  );
  static const _draculaLightPalette = HermesThemeColors(
    background: Color(0xFFFAF7EC),
    surface: Color(0xFFFEFCF7),
    surfaceVariant: Color(0xFFF0ECDC),
    accent: Color(0xFF2A698C),
    accentHover: Color(0xFF17597B),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF2A698C),
    textPrimary: Color(0xFF303030),
    textSecondary: Color(0xFF5B5643),
    textDisabled: Color(0xFF86806C),
    divider: Color(0xFFE5E1CE),
    error: Color(0xFFAE5043),
    warning: Color(0xFF7D6C2F),
    success: Color(0xFF2D6E27),
  );
  static const _gruvboxPalette = HermesThemeColors(
    background: Color(0xFF1F2121),
    surface: Color(0xFF27292A),
    surfaceVariant: Color(0xFF303233),
    accent: Color(0xFFEF9F6E),
    accentHover: Color(0xFFF2B77E),
    onAccent: Color(0xFF26170D),
    accentText: Color(0xFFEF9F6E),
    textPrimary: Color(0xFFE7E1D1),
    textSecondary: Color(0xFFB5A997),
    textDisabled: Color(0xFF796F67),
    divider: Color(0xFF393B3C),
    error: Color(0xFFDD8273),
    warning: Color(0xFFE2B762),
    success: Color(0xFFB6B960),
  );
  static const _gruvboxLightPalette = HermesThemeColors(
    background: Color(0xFFF5F1DF),
    surface: Color(0xFFF8F6ED),
    surfaceVariant: Color(0xFFEBE6D1),
    accent: Color(0xFF9D4C31),
    accentHover: Color(0xFF8B3C21),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF9D4C31),
    textPrimary: Color(0xFF3C3836),
    textSecondary: Color(0xFF5A524C),
    textDisabled: Color(0xFF887E76),
    divider: Color(0xFFDFDAC4),
    error: Color(0xFF8A3028),
    warning: Color(0xFF835D2B),
    success: Color(0xFF5E5C24),
  );
  static const _sageGardenPalette = HermesThemeColors(
    background: Color(0xFF1F211E),
    surface: Color(0xFF272A26),
    surfaceVariant: Color(0xFF30332E),
    accent: Color(0xFFB9CDAE),
    accentHover: Color(0xFFCCDCC3),
    onAccent: Color(0xFF181C15),
    accentText: Color(0xFFB9CDAE),
    textPrimary: Color(0xFFE2E8DC),
    textSecondary: Color(0xFFA0AC99),
    textDisabled: Color(0xFF687462),
    divider: Color(0xFF393C37),
    error: Color(0xFFCF8A7E),
    warning: Color(0xFFCEBD8A),
    success: Color(0xFFA4C794),
  );
  static const _sageGardenLightPalette = HermesThemeColors(
    background: Color(0xFFF5F7F3),
    surface: Color(0xFFFCFCFB),
    surfaceVariant: Color(0xFFEAECE5),
    accent: Color(0xFF53694A),
    accentHover: Color(0xFF44593B),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF53694A),
    textPrimary: Color(0xFF2C3329),
    textSecondary: Color(0xFF4F5A4A),
    textDisabled: Color(0xFF798473),
    divider: Color(0xFFDEE1D8),
    error: Color(0xFF9D4B3C),
    warning: Color(0xFF785F29),
    success: Color(0xFF406D38),
  );
  static const _nousPalette = HermesThemeColors(
    background: Color(0xFFF7F7F7),
    surface: Color(0xFFFCFCFC),
    surfaceVariant: Color(0xFFEDECE9),
    accent: Color(0xFF4769AD),
    accentHover: Color(0xFF38599B),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF4567AB),
    textPrimary: Color(0xFF2D3136),
    textSecondary: Color(0xFF586068),
    textDisabled: Color(0xFF93999F),
    divider: Color(0xFFE2E0DC),
    error: Color(0xFFAE504B),
    warning: Color(0xFF8E6527),
    success: Color(0xFF357B43),
  );
  static const _nousDarkPalette = HermesThemeColors(
    background: Color(0xFF1E2125),
    surface: Color(0xFF26292D),
    surfaceVariant: Color(0xFF2F3236),
    accent: Color(0xFF789DE6),
    accentHover: Color(0xFF90B1F1),
    onAccent: Color(0xFF131B29),
    accentText: Color(0xFF789DE6),
    textPrimary: Color(0xFFE6EDF3),
    textSecondary: Color(0xFFA0A9B3),
    textDisabled: Color(0xFF6A717B),
    divider: Color(0xFF383B3F),
    error: Color(0xFFDD8177),
    warning: Color(0xFFC69D57),
    success: Color(0xFF6EB172),
  );
  static const _githubPalette = HermesThemeColors(
    background: Color(0xFFF7F7F7),
    surface: Color(0xFFFCFCFC),
    surfaceVariant: Color(0xFFEDECE9),
    accent: Color(0xFF2E6A3B),
    accentHover: Color(0xFF1D5A2C),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF2E6A3B),
    textPrimary: Color(0xFF2D3136),
    textSecondary: Color(0xFF586068),
    textDisabled: Color(0xFF93999F),
    divider: Color(0xFFE2E0DC),
    error: Color(0xFFAE504B),
    warning: Color(0xFF8E6527),
    success: Color(0xFF357B43),
  );
  static const _githubDarkPalette = HermesThemeColors(
    background: Color(0xFF1E2125),
    surface: Color(0xFF26292D),
    surfaceVariant: Color(0xFF2F3236),
    accent: Color(0xFF74AF7D),
    accentHover: Color(0xFF8CC094),
    onAccent: Color(0xFF111E13),
    accentText: Color(0xFF74AF7D),
    textPrimary: Color(0xFFE6EDF3),
    textSecondary: Color(0xFFA0A9B3),
    textDisabled: Color(0xFF6A717B),
    divider: Color(0xFF383B3F),
    error: Color(0xFFDD8177),
    warning: Color(0xFFC69D57),
    success: Color(0xFF6EB172),
  );
  static const _catppuccinPalette = HermesThemeColors(
    background: Color(0xFFF0F1F4),
    surface: Color(0xFFF6F7F8),
    surfaceVariant: Color(0xFFE3E6EC),
    accent: Color(0xFF644B93),
    accentHover: Color(0xFF553B82),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF644B93),
    textPrimary: Color(0xFF3B3C48),
    textSecondary: Color(0xFF585A6B),
    textDisabled: Color(0xFF9597A7),
    divider: Color(0xFFD7DBE2),
    error: Color(0xFFAB4B50),
    warning: Color(0xFF915E19),
    success: Color(0xFF39772D),
  );
  static const _catppuccinDarkPalette = HermesThemeColors(
    background: Color(0xFF1F1F29),
    surface: Color(0xFF282832),
    surfaceVariant: Color(0xFF30303B),
    accent: Color(0xFFD4B8F7),
    accentHover: Color(0xFFE3CAFF),
    onAccent: Color(0xFF1E1726),
    accentText: Color(0xFFD4B8F7),
    textPrimary: Color(0xFFDCE1F0),
    textSecondary: Color(0xFFA3A8BD),
    textDisabled: Color(0xFF7B7F93),
    divider: Color(0xFF393944),
    error: Color(0xFFE297AA),
    warning: Color(0xFFD3BB8A),
    success: Color(0xFFA1C89F),
  );
  static const _everforestPalette = HermesThemeColors(
    background: Color(0xFFFBF6E9),
    surface: Color(0xFFFFFCF6),
    surfaceVariant: Color(0xFFF2EBD8),
    accent: Color(0xFF5A6A40),
    accentHover: Color(0xFF4B5A31),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF5A6A40),
    textPrimary: Color(0xFF333F46),
    textSecondary: Color(0xFF586058),
    textDisabled: Color(0xFF959B8D),
    divider: Color(0xFFE7DFCA),
    error: Color(0xFF7F4443),
    warning: Color(0xFF6A521F),
    success: Color(0xFF50591F),
  );
  static const _everforestDarkPalette = HermesThemeColors(
    background: Color(0xFF262B2E),
    surface: Color(0xFF2F3437),
    surfaceVariant: Color(0xFF373D40),
    accent: Color(0xFFB7CB99),
    accentHover: Color(0xFFC9DAB0),
    onAccent: Color(0xFF181D11),
    accentText: Color(0xFFB7CB99),
    textPrimary: Color(0xFFE8E1D1),
    textSecondary: Color(0xFFAFB8B1),
    textDisabled: Color(0xFF737E7A),
    divider: Color(0xFF41464A),
    error: Color(0xFFDA837F),
    warning: Color(0xFFD3BB8A),
    success: Color(0xFFB4C694),
  );
  static const _solarizedPalette = HermesThemeColors(
    background: Color(0xFFFBF6E9),
    surface: Color(0xFFFFFCF6),
    surfaceVariant: Color(0xFFF2EBD8),
    accent: Color(0xFF655E3E),
    accentHover: Color(0xFF564F2F),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF655E3E),
    textPrimary: Color(0xFF303030),
    textSecondary: Color(0xFF4C5151),
    textDisabled: Color(0xFF969993),
    divider: Color(0xFFE7DFCA),
    error: Color(0xFFAE4E56),
    warning: Color(0xFF846927),
    success: Color(0xFF667326),
  );
  static const _solarizedDarkPalette = HermesThemeColors(
    background: Color(0xFF152930),
    surface: Color(0xFF1D3238),
    surfaceVariant: Color(0xFF263B42),
    accent: Color(0xFF85ACC8),
    accentHover: Color(0xFF9ABBD3),
    onAccent: Color(0xFF131C22),
    accentText: Color(0xFF85ACC8),
    textPrimary: Color(0xFFD4E5E7),
    textSecondary: Color(0xFFA2B3B8),
    textDisabled: Color(0xFF647A83),
    divider: Color(0xFF2F444B),
    error: Color(0xFFDD9C9A),
    warning: Color(0xFFC0A966),
    success: Color(0xFFA5B165),
  );
  static const _nousAltPalette = HermesThemeColors(
    background: Color(0xFFF5F7FA),
    surface: Color(0xFFFCFCFE),
    surfaceVariant: Color(0xFFE9ECF3),
    accent: Color(0xFF4769AD),
    accentHover: Color(0xFF38599B),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF4567AA),
    textPrimary: Color(0xFF303033),
    textSecondary: Color(0xFF5D5D6F),
    textDisabled: Color(0xFF8A8A98),
    divider: Color(0xFFDDE0E9),
    error: Color(0xFFAE4F5A),
    warning: Color(0xFF996029),
    success: Color(0xFF307B4D),
  );
  static const _nousAltDarkPalette = HermesThemeColors(
    background: Color(0xFF232A39),
    surface: Color(0xFF2B3342),
    surfaceVariant: Color(0xFF343C4B),
    accent: Color(0xFFDAC7B3),
    accentHover: Color(0xFFDEDEDE),
    onAccent: Color(0xFF1E1A15),
    accentText: Color(0xFFDAC7B3),
    textPrimary: Color(0xFFF5E8DB),
    textSecondary: Color(0xFFBFC7DC),
    textDisabled: Color(0xFF9199AC),
    divider: Color(0xFF3D4555),
    error: Color(0xFFEDA498),
    warning: Color(0xFFDFB77B),
    success: Color(0xFF8ECFA4),
  );
  static const _classicPalette = HermesThemeColors(
    background: Color(0xFFF5F5F5),
    surface: Color(0xFFFBFBFB),
    surfaceVariant: Color(0xFFEBEAE7),
    accent: Color(0xFF7C5F27),
    accentHover: Color(0xFF6C4F15),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF7C5F27),
    textPrimary: Color(0xFF353025),
    textSecondary: Color(0xFF665D4B),
    textDisabled: Color(0xFFA09884),
    divider: Color(0xFFE0DEDA),
    error: Color(0xFFAB4D45),
    warning: Color(0xFF985F28),
    success: Color(0xFF2E7A4C),
  );
  static const _classicDarkPalette = HermesThemeColors(
    background: Color(0xFF1F1F2B),
    surface: Color(0xFF272834),
    surfaceVariant: Color(0xFF30303E),
    accent: Color(0xFFEEC46E),
    accentHover: Color(0xFFF6D78C),
    onAccent: Color(0xFF211909),
    accentText: Color(0xFFEEC46E),
    textPrimary: Color(0xFFF3EFDE),
    textSecondary: Color(0xFFB1A793),
    textDisabled: Color(0xFF796F5D),
    divider: Color(0xFF383947),
    error: Color(0xFFDD817A),
    warning: Color(0xFFE0B861),
    success: Color(0xFF83D399),
  );
  static const _midnightLightPalette = HermesThemeColors(
    background: Color(0xFFF7F7F7),
    surface: Color(0xFFFCFCFC),
    surfaceVariant: Color(0xFFEDECE9),
    accent: Color(0xFF6F6AAC),
    accentHover: Color(0xFF605A9B),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF6560A1),
    textPrimary: Color(0xFF303030),
    textSecondary: Color(0xFF5F5D71),
    textDisabled: Color(0xFF8A899B),
    divider: Color(0xFFE2E0DC),
    error: Color(0xFFAB5345),
    warning: Color(0xFF9A602A),
    success: Color(0xFF307B4D),
  );
  static const _midnightPalette = HermesThemeColors(
    background: Color(0xFF1E1F2C),
    surface: Color(0xFF262835),
    surfaceVariant: Color(0xFF2F303F),
    accent: Color(0xFF9993E3),
    accentHover: Color(0xFFDDD7F7),
    onAccent: Color(0xFF191828),
    accentText: Color(0xFF9993E3),
    textPrimary: Color(0xFFE1DFEF),
    textSecondary: Color(0xFFA6A6BB),
    textDisabled: Color(0xFF6F6E82),
    divider: Color(0xFF373948),
    error: Color(0xFFD97F98),
    warning: Color(0xFFE0B861),
    success: Color(0xFF7FCF95),
  );
  static const _emberLightPalette = HermesThemeColors(
    background: Color(0xFFF7F7F7),
    surface: Color(0xFFFCFCFC),
    surfaceVariant: Color(0xFFEDECE9),
    accent: Color(0xFFA46332),
    accentHover: Color(0xFF925320),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF995827),
    textPrimary: Color(0xFF303030),
    textSecondary: Color(0xFF6C5B52),
    textDisabled: Color(0xFF928886),
    divider: Color(0xFFE2E0DC),
    error: Color(0xFFAB5345),
    warning: Color(0xFF9A602A),
    success: Color(0xFF307B4D),
  );
  static const _emberPalette = HermesThemeColors(
    background: Color(0xFF281E16),
    surface: Color(0xFF31271E),
    surfaceVariant: Color(0xFF3A2F26),
    accent: Color(0xFFD58A55),
    accentHover: Color(0xFFF6D8B9),
    onAccent: Color(0xFF25170D),
    accentText: Color(0xFFD58A55),
    textPrimary: Color(0xFFECDFD2),
    textSecondary: Color(0xFFB7A496),
    textDisabled: Color(0xFF7E6C60),
    divider: Color(0xFF43382F),
    error: Color(0xFFDC836F),
    warning: Color(0xFFDBA967),
    success: Color(0xFF7CB27C),
  );
  static const _monoLightPalette = HermesThemeColors(
    background: Color(0xFFF7F7F7),
    surface: Color(0xFFFCFCFC),
    surfaceVariant: Color(0xFFEDECE9),
    accent: Color(0xFF737373),
    accentHover: Color(0xFF636363),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF686868),
    textPrimary: Color(0xFF303030),
    textSecondary: Color(0xFF5E5E62),
    textDisabled: Color(0xFF8C8C93),
    divider: Color(0xFFE2E0DC),
    error: Color(0xFFAB5345),
    warning: Color(0xFF9A602A),
    success: Color(0xFF307B4D),
  );
  static const _monoPalette = HermesThemeColors(
    background: Color(0xFF202020),
    surface: Color(0xFF292929),
    surfaceVariant: Color(0xFF313131),
    accent: Color(0xFFA6A6A6),
    accentHover: Color(0xFFDEDEDE),
    onAccent: Color(0xFF1B1B1B),
    accentText: Color(0xFFA6A6A6),
    textPrimary: Color(0xFFEAEAEA),
    textSecondary: Color(0xFFA7A7A7),
    textDisabled: Color(0xFF707070),
    divider: Color(0xFF3A3A3A),
    error: Color(0xFFD58581),
    warning: Color(0xFFBDA373),
    success: Color(0xFF84AA83),
  );
  static const _slateLightPalette = HermesThemeColors(
    background: Color(0xFFF7F7F7),
    surface: Color(0xFFFCFCFC),
    surfaceVariant: Color(0xFFEDECE9),
    accent: Color(0xFF4A74A6),
    accentHover: Color(0xFF3A6495),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF406A9B),
    textPrimary: Color(0xFF303030),
    textSecondary: Color(0xFF555F70),
    textDisabled: Color(0xFF858D9D),
    divider: Color(0xFFE2E0DC),
    error: Color(0xFFAB5345),
    warning: Color(0xFF9A602A),
    success: Color(0xFF307B4D),
  );
  static const _slatePalette = HermesThemeColors(
    background: Color(0xFF1E2125),
    surface: Color(0xFF26292D),
    surfaceVariant: Color(0xFF2F3236),
    accent: Color(0xFF7AB3F7),
    accentHover: Color(0xFFCBD1D7),
    onAccent: Color(0xFF101B28),
    accentText: Color(0xFF7AB3F7),
    textPrimary: Color(0xFFDAE2EA),
    textSecondary: Color(0xFFA0A9B2),
    textDisabled: Color(0xFF69717B),
    divider: Color(0xFF383B3F),
    error: Color(0xFFDD817B),
    warning: Color(0xFFC69D57),
    success: Color(0xFF6EB172),
  );
  static const _cyberpunkLightPalette = HermesThemeColors(
    background: Color(0xFFF7F7F7),
    surface: Color(0xFFFCFCFC),
    surfaceVariant: Color(0xFFEDECE9),
    accent: Color(0xFF387A3D),
    accentHover: Color(0xFF276A2D),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF337538),
    textPrimary: Color(0xFF303030),
    textSecondary: Color(0xFF526357),
    textDisabled: Color(0xFF7F958B),
    divider: Color(0xFFE2E0DC),
    error: Color(0xFFAB5345),
    warning: Color(0xFF9A602A),
    success: Color(0xFF307B4D),
  );
  static const _cyberpunkPalette = HermesThemeColors(
    background: Color(0xFF192418),
    surface: Color(0xFF222C21),
    surfaceVariant: Color(0xFF2A3529),
    accent: Color(0xFF9BDF9B),
    accentHover: Color(0xFFAEF1BB),
    onAccent: Color(0xFF121E12),
    accentText: Color(0xFF9BDF9B),
    textPrimary: Color(0xFFD9E5D8),
    textSecondary: Color(0xFF9CAD9D),
    textDisabled: Color(0xFF657566),
    divider: Color(0xFF333E31),
    error: Color(0xFFDD807E),
    warning: Color(0xFFCDC064),
    success: Color(0xFF8CCF8D),
  );

  /// Catálogo de temas, en orden de presentación. El primero es el default.
  ///
  /// Curado en la spec 028 (U-10): la identidad de la app es dark/OLED con el
  /// ámbar de marca; se retiraron los presets redundantes entre sí o fuera de
  /// identidad (nous-aqua, aguamarina, tokyo, synthwave,
  /// solarized-dark, onedark, everforest, cobalt2, ayu-mirage, latte,
  /// solarized-light, gruvbox-light, manga) y se añadieron Steel y Bordeaux.
  /// Los ids retirados migran en [themeIdFromLegacy] al superviviente más
  /// parecido — no eliminar esas entradas del switch.
  /// Jul-2026: Gruvbox vuelve al catálogo a petición del autor (y sale de la
  /// migración legacy), se añade Sage Garden y se incorporan los seis presets
  /// oficiales de Hermes Desktop. Ember vuelve con su paleta canónica Desktop.
  /// Oct-2026: el catálogo Desktop sigue a BUILTIN_THEMES de Hermes Desktop
  /// (12 familias, mismo orden). `nous` pasa a ser el Nous sobre GitHub como
  /// en Desktop y la paleta anterior vive como `nous-alt`; `everforest` y
  /// `solarized-dark` vuelven a ser temas reales y salen de la migración.
  /// 1.2.15: one card per family, every family in light and dark. The
  /// Console duplicates (amber-oled, crimson, hermes-console, mocha,
  /// phosphor, graphite) migrate in [retiredThemeIds]; amber, steel,
  /// bordeaux, dracula, gruvbox and sage-garden gain a light variant and
  /// Claude becomes one family (claude + claude-light). Console (the app's
  /// icon colours on Claude's structure) is the default for new installs;
  /// a saved choice, Amber included, is never moved.
  ///
  /// rt1215: every preset passes through [_withReadableInk], so secondary
  /// text and links reach AA on all of its surfaces.
  static final List<HermesThemePreset> presets = List.unmodifiable(
    _curatedPresets.map(_withReadableInk),
  );

  static final List<HermesThemePreset> _curatedPresets = List.unmodifiable([
    // ── Console: the default, in the icon's graphite and terracotta ──
    HermesThemePreset(
      id: 'console',
      name: 'Console',
      tagline: 'graphite · terracotta',
      brightness: Brightness.dark,
      colors: _consolePalette,
      fontFamily: 'Inter',
      radius: 16.0,
      secondary: Color(0xFF88A9C0),
      titleWeight: FontWeight.w600,
      titleSpacing: 0.0,
      family: 'console',
    ),
    HermesThemePreset(
      id: 'console-light',
      name: 'Console',
      tagline: 'porcelain · terracotta',
      brightness: Brightness.light,
      colors: _consoleLightPalette,
      fontFamily: 'Inter',
      radius: 16.0,
      secondary: Color(0xFF4C6D85),
      titleWeight: FontWeight.w600,
      titleSpacing: 0.0,
      family: 'console',
    ),
    // ── Console families: dark, then light ──
    HermesThemePreset(
      id: 'amber',
      name: 'Amber',
      tagline: 'soft graphite · the signature',
      brightness: Brightness.dark,
      colors: _amberPalette,
      fontFamily: 'Inter',
      radius: 10.0,
      secondary: Color(0xFF69B5C2),
      titleWeight: FontWeight.w700,
      titleSpacing: 0.5,
      family: 'amber',
    ),
    HermesThemePreset(
      id: 'amber-light',
      name: 'Amber',
      tagline: 'warm paper · the signature',
      brightness: Brightness.light,
      colors: _amberLightPalette,
      fontFamily: 'Inter',
      radius: 10.0,
      secondary: Color(0xFF326973),
      titleWeight: FontWeight.w700,
      titleSpacing: 0.5,
      family: 'amber',
    ),
    HermesThemePreset(
      id: 'claude',
      name: 'Claude',
      tagline: 'warm charcoal · coral clay',
      brightness: Brightness.dark,
      colors: _claudePalette,
      fontFamily: 'Inter',
      radius: 16.0,
      secondary: Color(0xFF7C9CB3),
      titleWeight: FontWeight.w600,
      titleSpacing: 0.0,
      family: 'claude',
    ),
    HermesThemePreset(
      id: 'claude-light',
      name: 'Claude',
      tagline: 'warm paper · deep coral',
      brightness: Brightness.light,
      colors: _claudeLightPalette,
      fontFamily: 'Inter',
      radius: 16.0,
      secondary: Color(0xFF4F7088),
      titleWeight: FontWeight.w600,
      titleSpacing: 0.0,
      family: 'claude',
    ),
    HermesThemePreset(
      id: 'steel',
      name: 'Steel',
      tagline: 'cold steel blue · precision',
      brightness: Brightness.dark,
      colors: _steelPalette,
      fontFamily: 'Inter',
      radius: 8.0,
      secondary: Color(0xFFD1AB7A),
      titleWeight: FontWeight.w600,
      titleSpacing: 1.0,
      family: 'steel',
    ),
    HermesThemePreset(
      id: 'steel-light',
      name: 'Steel',
      tagline: 'cool paper · steel blue',
      brightness: Brightness.light,
      colors: _steelLightPalette,
      fontFamily: 'Inter',
      radius: 8.0,
      secondary: Color(0xFF79572C),
      titleWeight: FontWeight.w600,
      titleSpacing: 1.0,
      family: 'steel',
    ),
    HermesThemePreset(
      id: 'bordeaux',
      name: 'Bordeaux',
      tagline: 'burgundy velvet · copper',
      brightness: Brightness.dark,
      colors: _bordeauxPalette,
      fontFamily: 'Montserrat',
      radius: 10.0,
      secondary: Color(0xFF90BCA4),
      titleWeight: FontWeight.w600,
      titleSpacing: 1.2,
      family: 'bordeaux',
    ),
    HermesThemePreset(
      id: 'bordeaux-light',
      name: 'Bordeaux',
      tagline: 'blush paper · copper',
      brightness: Brightness.light,
      colors: _bordeauxLightPalette,
      fontFamily: 'Montserrat',
      radius: 10.0,
      secondary: Color(0xFF416D53),
      titleWeight: FontWeight.w600,
      titleSpacing: 1.2,
      family: 'bordeaux',
    ),
    HermesThemePreset(
      id: 'dracula',
      name: 'Dracula',
      tagline: 'soft cyan · dusk slate',
      brightness: Brightness.dark,
      colors: _draculaPalette,
      fontFamily: 'JetBrainsMono',
      radius: 4.0,
      secondary: Color(0xFFD89ABA),
      titleWeight: FontWeight.w700,
      titleSpacing: 2.0,
      uppercaseTitles: true,
      family: 'dracula',
    ),
    HermesThemePreset(
      id: 'dracula-light',
      name: 'Dracula',
      tagline: 'Alucard · official light',
      brightness: Brightness.light,
      colors: _draculaLightPalette,
      fontFamily: 'JetBrainsMono',
      radius: 4.0,
      secondary: Color(0xFF824554),
      titleWeight: FontWeight.w700,
      titleSpacing: 2.0,
      uppercaseTitles: true,
      family: 'dracula',
    ),
    HermesThemePreset(
      id: 'gruvbox',
      name: 'Gruvbox',
      tagline: 'retro warm · vim classic',
      brightness: Brightness.dark,
      colors: _gruvboxPalette,
      fontFamily: 'JetBrainsMono',
      radius: 6.0,
      secondary: Color(0xFF96BD88),
      titleWeight: FontWeight.w700,
      titleSpacing: 1.0,
      family: 'gruvbox',
    ),
    HermesThemePreset(
      id: 'gruvbox-light',
      name: 'Gruvbox',
      tagline: 'retro warm · light',
      brightness: Brightness.light,
      colors: _gruvboxLightPalette,
      fontFamily: 'JetBrainsMono',
      radius: 6.0,
      secondary: Color(0xFF497158),
      titleWeight: FontWeight.w700,
      titleSpacing: 1.0,
      family: 'gruvbox',
    ),
    HermesThemePreset(
      id: 'sage-garden',
      name: 'Sage Garden',
      tagline: 'muted sage · quiet greenhouse',
      brightness: Brightness.dark,
      colors: _sageGardenPalette,
      fontFamily: 'Inter',
      radius: 16.0,
      secondary: Color(0xFFC4AB93),
      titleWeight: FontWeight.w700,
      titleSpacing: 0.0,
      family: 'sage-garden',
    ),
    HermesThemePreset(
      id: 'sage-garden-light',
      name: 'Sage Garden',
      tagline: 'pale sage · greenhouse by day',
      brightness: Brightness.light,
      colors: _sageGardenLightPalette,
      fontFamily: 'Inter',
      radius: 16.0,
      secondary: Color(0xFF755C44),
      titleWeight: FontWeight.w700,
      titleSpacing: 0.0,
      family: 'sage-garden',
    ),
    // ── Catálogo oficial de Hermes Desktop ──
    // Mismo orden que BUILTIN_THEMES en apps/desktop/src/themes/presets.ts.
    HermesThemePreset(
      id: 'nous',
      name: 'Nous',
      tagline: 'GitHub chrome · Nous blue',
      brightness: Brightness.light,
      colors: _nousPalette,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF786AA1),
      desktopOfficial: true,
      desktopFamily: 'nous',
    ),
    HermesThemePreset(
      id: 'nous-dark',
      name: 'Nous',
      tagline: 'GitHub dark · Nous blue',
      brightness: Brightness.dark,
      colors: _nousDarkPalette,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFFB29CD6),
      desktopOfficial: true,
      desktopFamily: 'nous',
    ),
    HermesThemePreset(
      id: 'github',
      name: 'GitHub',
      tagline: 'GitHub Light Default',
      brightness: Brightness.light,
      colors: _githubPalette,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF786AA1),
      desktopOfficial: true,
      desktopFamily: 'github',
    ),
    HermesThemePreset(
      id: 'github-dark',
      name: 'GitHub',
      tagline: 'GitHub Dark Default',
      brightness: Brightness.dark,
      colors: _githubDarkPalette,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFFB29CD6),
      desktopOfficial: true,
      desktopFamily: 'github',
    ),
    HermesThemePreset(
      id: 'catppuccin',
      name: 'Catppuccin',
      tagline: 'soothing pastels · Latte',
      brightness: Brightness.light,
      colors: _catppuccinPalette,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF5974A6),
      desktopOfficial: true,
      desktopFamily: 'catppuccin',
    ),
    HermesThemePreset(
      id: 'catppuccin-dark',
      name: 'Catppuccin',
      tagline: 'soothing pastels · Mocha',
      brightness: Brightness.dark,
      colors: _catppuccinDarkPalette,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFFA1DCD1),
      desktopOfficial: true,
      desktopFamily: 'catppuccin',
    ),
    HermesThemePreset(
      id: 'everforest',
      name: 'Everforest',
      tagline: 'warm, low-contrast forest greens',
      brightness: Brightness.light,
      colors: _everforestPalette,
      fontFamily: 'Inter',
      radius: 12,
      // Everforest blue (#3A94C5) deepened 40% toward black: the light skin's
      // body text is only 5.2:1, so a tone lifted just to AA would land on
      // the text colour and activity labels would read as titles.
      secondary: Color(0xFF30586F),
      desktopOfficial: true,
      desktopFamily: 'everforest',
    ),
    HermesThemePreset(
      id: 'everforest-dark',
      name: 'Everforest',
      tagline: 'warm, low-contrast forest greens',
      brightness: Brightness.dark,
      colors: _everforestDarkPalette,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF8BB8B2),
      desktopOfficial: true,
      desktopFamily: 'everforest',
    ),
    HermesThemePreset(
      id: 'solarized',
      name: 'Solarized',
      tagline: 'fixed-contrast light',
      brightness: Brightness.light,
      colors: _solarizedPalette,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF4779A3),
      desktopOfficial: true,
      desktopFamily: 'solarized',
    ),
    HermesThemePreset(
      id: 'solarized-dark',
      name: 'Solarized',
      tagline: 'fixed-contrast dark',
      brightness: Brightness.dark,
      colors: _solarizedDarkPalette,
      fontFamily: 'Inter',
      radius: 12,
      // Solarized cyan (#2AA198) lifted 40% toward white: body text on the
      // dark skin sits near the plain cyan, so activity labels need the
      // lighter tone to stay distinct from titles.
      secondary: Color(0xFF8EC4BF),
      desktopOfficial: true,
      desktopFamily: 'solarized',
    ),
    HermesThemePreset(
      id: 'nous-alt',
      name: 'Nous Alt',
      tagline: 'glass neutrals · Nous blue',
      brightness: Brightness.light,
      colors: _nousAltPalette,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF364D7C),
      desktopOfficial: true,
      desktopFamily: 'nous-alt',
    ),
    HermesThemePreset(
      id: 'nous-alt-dark',
      name: 'Nous Alt',
      tagline: 'deep Nous blue · psyche cream',
      brightness: Brightness.dark,
      colors: _nousAltDarkPalette,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFFB9C7EA),
      desktopOfficial: true,
      desktopFamily: 'nous-alt',
    ),
    HermesThemePreset(
      id: 'classic',
      name: 'Classic Hermes',
      tagline: 'gold on navy · the original CLI look',
      brightness: Brightness.light,
      colors: _classicPalette,
      fontFamily: 'Inter',
      radius: 10,
      secondary: Color(0xFF4A4B5E),
      desktopOfficial: true,
      desktopFamily: 'classic',
    ),
    HermesThemePreset(
      id: 'classic-dark',
      name: 'Classic Hermes',
      tagline: 'gold on navy · the original CLI look',
      brightness: Brightness.dark,
      colors: _classicDarkPalette,
      fontFamily: 'Inter',
      radius: 10,
      secondary: Color(0xFFC59267),
      desktopOfficial: true,
      desktopFamily: 'classic',
    ),
    HermesThemePreset(
      id: 'midnight-light',
      name: 'Midnight',
      tagline: 'cool violet · clear surface',
      brightness: Brightness.light,
      colors: _midnightLightPalette,
      fontFamily: 'JetBrainsMono',
      radius: 10,
      secondary: Color(0xFF706DA4),
      desktopOfficial: true,
      desktopFamily: 'midnight',
    ),
    HermesThemePreset(
      id: 'midnight',
      name: 'Midnight',
      tagline: 'deep blue-violet · cool accents',
      brightness: Brightness.dark,
      colors: _midnightPalette,
      fontFamily: 'JetBrainsMono',
      radius: 10,
      secondary: Color(0xFFCEC9E9),
      desktopOfficial: true,
      desktopFamily: 'midnight',
    ),
    HermesThemePreset(
      id: 'ember-light',
      name: 'Ember',
      tagline: 'warm bronze · clear surface',
      brightness: Brightness.light,
      colors: _emberLightPalette,
      fontFamily: 'JetBrainsMono',
      radius: 8,
      secondary: Color(0xFF9B6742),
      desktopOfficial: true,
      desktopFamily: 'ember',
    ),
    HermesThemePreset(
      id: 'ember',
      name: 'Ember',
      tagline: 'warm crimson · bronze forge',
      brightness: Brightness.dark,
      colors: _emberPalette,
      fontFamily: 'JetBrainsMono',
      radius: 8,
      secondary: Color(0xFFE6C8A9),
      desktopOfficial: true,
      desktopFamily: 'ember',
    ),
    HermesThemePreset(
      id: 'mono-light',
      name: 'Mono',
      tagline: 'clean grayscale · clear surface',
      brightness: Brightness.light,
      colors: _monoLightPalette,
      fontFamily: 'JetBrainsMono',
      radius: 8,
      secondary: Color(0xFF606060),
      desktopOfficial: true,
      desktopFamily: 'mono',
    ),
    HermesThemePreset(
      id: 'mono',
      name: 'Mono',
      tagline: 'clean grayscale · minimal focus',
      brightness: Brightness.dark,
      colors: _monoPalette,
      fontFamily: 'JetBrainsMono',
      radius: 8,
      secondary: Color(0xFFCECECE),
      desktopOfficial: true,
      desktopFamily: 'mono',
    ),
    HermesThemePreset(
      id: 'slate-light',
      name: 'Slate',
      tagline: 'cool slate · clear surface',
      brightness: Brightness.light,
      colors: _slateLightPalette,
      fontFamily: 'JetBrainsMono',
      radius: 8,
      secondary: Color(0xFF436C94),
      desktopOfficial: true,
      desktopFamily: 'slate',
    ),
    HermesThemePreset(
      id: 'slate',
      name: 'Slate',
      tagline: 'cool slate blue · developer focus',
      brightness: Brightness.dark,
      colors: _slatePalette,
      fontFamily: 'JetBrainsMono',
      radius: 8,
      secondary: Color(0xFFC8CFD5),
      desktopOfficial: true,
      desktopFamily: 'slate',
    ),
    HermesThemePreset(
      id: 'cyberpunk-light',
      name: 'Cyberpunk',
      tagline: 'muted green · clear surface',
      brightness: Brightness.light,
      colors: _cyberpunkLightPalette,
      fontFamily: 'JetBrainsMono',
      radius: 3,
      secondary: Color(0xFF437246),
      titleSpacing: 2,
      uppercaseTitles: true,
      desktopOfficial: true,
      desktopFamily: 'cyberpunk',
    ),
    HermesThemePreset(
      id: 'cyberpunk',
      name: 'Cyberpunk',
      tagline: 'muted green · terminal',
      brightness: Brightness.dark,
      colors: _cyberpunkPalette,
      fontFamily: 'JetBrainsMono',
      radius: 3,
      secondary: Color(0xFFD9D08F),
      titleSpacing: 2,
      uppercaseTitles: true,
      desktopOfficial: true,
      desktopFamily: 'cyberpunk',
    ),
  ]);

  /// rt1215: secondary text (`onSurfaceVariant`), tertiary text and links
  /// are read; nudge them, only when needed, to WCAG AA 4.5:1 on the
  /// background, the surface and the surface variant. Tertiary is the
  /// disabled ink lifted to AA; secondary then keeps a visible step above it
  /// ([_hierarchyStep]), never past the theme's own primary text. Identity
  /// colours (background, surfaces, primary text, accent) stay as designed.
  static HermesThemePreset _withReadableInk(HermesThemePreset p) {
    final c = p.colors;
    final surfaces = [c.background, c.surface, c.surfaceVariant];
    double worst(Color ink) =>
        surfaces.map((bg) => ThemeContrast.ratio(ink, bg)).reduce(math.min);
    final tertiary = HermesThemeColors.readableTertiary(
      c.textDisabled,
      background: c.background,
      surface: c.surface,
      surfaceVariant: c.surfaceVariant,
    );
    final secondary = ThemeContrast.adjustForContrast(
      c.textSecondary,
      surfaces,
      minimum: math.max(
        4.5,
        math.min(worst(tertiary) * _hierarchyStep, worst(c.textPrimary)),
      ),
    );
    final link = ThemeContrast.adjustForContrast(
      c.accentText,
      surfaces,
      minimum: 4.5,
    );
    return HermesThemePreset(
      id: p.id,
      name: p.name,
      tagline: p.tagline,
      brightness: p.brightness,
      colors: c.copyWith(
        textSecondary: secondary,
        accentText: link == c.accentText ? null : link,
        textTertiary: tertiary,
      ),
      fontFamily: p.fontFamily,
      radius: p.radius,
      secondary: p.secondary,
      titleWeight: p.titleWeight,
      titleSpacing: p.titleSpacing,
      uppercaseTitles: p.uppercaseTitles,
      desktopOfficial: p.desktopOfficial,
      desktopFamily: p.desktopFamily,
      family: p.family,
    );
  }

  /// Secondary text reads at least this much stronger than tertiary.
  static const double _hierarchyStep = 1.1;

  static const String defaultThemeId = 'console';

  static HermesThemePreset presetById(String? id) {
    return presets.firstWhere((p) => p.id == id, orElse: () => presets.first);
  }

  /// The member of [id]'s family in [brightness] ("Auto" picks the variant
  /// the system shows). Ids outside the catalogue are returned unchanged.
  static String variantFor(String id, Brightness brightness) {
    final family = presets.where((p) => p.id == id).firstOrNull?.familyId;
    if (family == null) return id;
    return presets
            .where((p) => p.familyId == family && p.brightness == brightness)
            .firstOrNull
            ?.id ??
        id;
  }

  /// Number of theme families (one card each, with a Light/Dark selector).
  static int get familyCount =>
      presets.map((preset) => preset.familyId).toSet().length;

  /// Saved ids that no longer exist → the closest survivor, in the mode the
  /// user had. Single source for the store, the first frame and the home
  /// widget. Never remove an entry: an install that has not been opened
  /// since that id was retired still carries it.
  static const Map<String, String> retiredThemeIds = {
    // Removed in 1.2.15 (Console duplicates of a Desktop family or of
    // another Console theme).
    'amber-oled': 'amber', // same palette except the pure black page
    'crimson': 'bordeaux', // same wine register; red accent read as error
    'hermes-console': 'slate', // electric blue on navy ≈ Slate
    'mocha': 'catppuccin-dark', // Catppuccin Mocha is Desktop's Catppuccin
    'phosphor': 'cyberpunk', // same green CRT terminal concept
    'graphite': 'mono', // same monochrome on near-black
    // Claves de AppThemeMode (pre-catálogo).
    'oled': 'amber',
    'teal': 'dracula',
    'light': 'amber-light', // literally the amber light palette
    'dark': 'amber',
    // Ids retirados en la curación U-10 (spec 028) → el más parecido.
    'nous-aqua': 'slate', // azul eléctrico sobre navy
    'tokyo': 'steel', // azul frío sobre oscuro
    'onedark': 'steel', // azul editor sobre slate
    'cobalt2': 'slate', // azul profundo saturado
    'aguamarina': 'steel', // sereno y frío
    'synthwave': 'dracula', // neón cyberpunk
    'ayu-mirage': 'amber', // melocotón cálido
    'latte': 'catppuccin', // Latte is Catppuccin light
    'solarized-light': 'solarized',
    'manga': 'claude-light',
    // `gruvbox-light` is a real theme again since 1.2.15: no entry.
  };

  /// A saved id with retired ids replaced by their survivor. Anything else
  /// (a valid preset, a custom profile id, garbage) is returned unchanged so
  /// the caller decides how to treat it.
  static String migrateStoredThemeId(String id) => retiredThemeIds[id] ?? id;

  /// Mapea las claves antiguas (`AppThemeMode`) y los ids de temas RETIRADOS
  /// a ids del catálogo actual. Es el punto único de migración de la pref
  /// `theme_mode`: un usuario con un tema retirado guardado cae al
  /// superviviente más parecido (nunca crashea ni resetea otras prefs).
  static String themeIdFromLegacy(String? legacy) {
    if (legacy == null) return defaultThemeId;
    final id = migrateStoredThemeId(legacy);
    // Si ya es un id válido del catálogo, respétalo; si no, default.
    return presets.any((p) => p.id == id) ? id : defaultThemeId;
  }

  /// Construye el [ThemeData] de un tema por id (mecanismo principal).
  static ThemeData fromId(
    String? id, {
    ComponentProfile componentProfile = ComponentProfiles.minimal,
  }) {
    final preset = presetById(id);
    final base = preset.isDark
        ? _buildRichDark(
            preset.colors,
            fontFamily: preset.fontFamily,
            radius: preset.radius,
            secondary: preset.secondary,
            titleWeight: preset.titleWeight,
            titleSpacing: preset.titleSpacing,
            uppercaseTitles: preset.uppercaseTitles,
          )
        : _buildLight(
            preset.colors,
            fontFamily: preset.fontFamily,
            radius: preset.radius,
            secondary: preset.secondary,
            titleWeight: preset.titleWeight,
            titleSpacing: preset.titleSpacing,
            uppercaseTitles: preset.uppercaseTitles,
          );
    return _applyComponentProfile(
      base,
      componentProfile,
      preserveMinimalBaseline: true,
    );
  }

  /// Builds ThemeData from an explicit custom profile. No remote resource is
  /// loaded: every font and color was already normalized by ThemeProfileCodec.
  static ThemeData fromProfile(
    ThemeProfile profile, {
    ComponentProfile? componentProfile,
  }) {
    final components =
        componentProfile ?? ComponentProfiles.byId(profile.componentProfileId);
    final palette = profile.palette;
    final colors = HermesThemeColors(
      background: palette.background,
      surface: palette.surface,
      surfaceVariant: palette.surfaceVariant,
      accent: palette.accent,
      accentHover: palette.accentHover,
      accentText: palette.accentText,
      secondary: palette.secondary,
      onAccent: palette.onAccent,
      textPrimary: palette.textPrimary,
      textSecondary: palette.textSecondary,
      textDisabled: palette.textDisabled,
      error: palette.error,
      success: palette.success,
      warning: palette.warning,
      divider: palette.divider,
      uppercaseTitles: profile.typography.uppercaseTitles,
    );
    final weight = FontWeight.values.firstWhere(
      (candidate) => candidate.value == profile.typography.titleWeight,
      orElse: () => FontWeight.w600,
    );
    final base = profile.brightness == ThemeProfileBrightness.dark
        ? _buildRichDark(
            colors,
            fontFamily: profile.typography.fontFamily,
            radius: components.shape.fieldRadius,
            secondary: palette.secondary,
            titleWeight: weight,
            titleSpacing: profile.typography.titleSpacing,
            uppercaseTitles: profile.typography.uppercaseTitles,
          )
        : _buildLight(
            colors,
            fontFamily: profile.typography.fontFamily,
            radius: components.shape.fieldRadius,
            secondary: palette.secondary,
            titleWeight: weight,
            titleSpacing: profile.typography.titleSpacing,
            uppercaseTitles: profile.typography.uppercaseTitles,
          );
    return _applyComponentProfile(base, components);
  }

  static ThemeData get hermesRedDark => _buildDark(_darkColors);
  static ThemeData get hermesRedOled => _buildDark(_oledColors);
  static ThemeData get hermesRedLight => _buildLight(_lightColors);
  static ThemeData get hermesTealTheme => _buildRichDark(_tealColors);

  static ThemeData fromMode(AppThemeMode mode) {
    return switch (mode) {
      AppThemeMode.dark => hermesRedDark,
      AppThemeMode.oled => hermesRedOled,
      AppThemeMode.light => hermesRedLight,
      AppThemeMode.hermesTeal => hermesTealTheme,
    };
  }

  static ThemeData _buildDark(
    HermesThemeColors colors, {
    String fontFamily = 'Inter',
    double radius = 10.0,
    Color? secondary,
    FontWeight titleWeight = FontWeight.w600,
    double titleSpacing = 0.0,
    bool uppercaseTitles = false,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: colors.accent,
      brightness: Brightness.dark,
      primary: colors.accent,
      onPrimary: colors.onAccent,
      secondary: colors.accentHover,
      onSecondary: colors.onAccent,
      surface: colors.surface,
      onSurface: colors.textPrimary,
      error: colors.error,
      onError: colors.onAccent,
    );

    return _baseTheme(
      colors,
      scheme,
      Brightness.dark,
      fontFamily: fontFamily,
      radius: radius,
      secondary: secondary,
      titleWeight: titleWeight,
      titleSpacing: titleSpacing,
      uppercaseTitles: uppercaseTitles,
    );
  }

  static ThemeData _buildRichDark(
    HermesThemeColors colors, {
    String fontFamily = 'Inter',
    double radius = 10.0,
    Color? secondary,
    FontWeight titleWeight = FontWeight.w600,
    double titleSpacing = 0.0,
    bool uppercaseTitles = false,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: colors.accent,
      brightness: Brightness.dark,
      primary: colors.accent,
      onPrimary: colors.onAccent,
      primaryContainer: colors.surfaceVariant,
      onPrimaryContainer: colors.textPrimary,
      secondary: colors.accentHover,
      onSecondary: colors.onAccent,
      secondaryContainer: colors.accent,
      onSecondaryContainer: colors.onAccent,
      tertiary: colors.success,
      onTertiary: colors.onAccent,
      tertiaryContainer: colors.surfaceVariant,
      onTertiaryContainer: colors.textPrimary,
      error: colors.error,
      onError: colors.onAccent,
      surface: colors.surface,
      onSurface: colors.textPrimary,
      surfaceDim: colors.background,
      surfaceBright: colors.surfaceVariant,
      surfaceContainerLowest: colors.background,
      surfaceContainerLow: colors.surface,
      surfaceContainer: colors.surface,
      surfaceContainerHigh: colors.surfaceVariant,
      surfaceContainerHighest: colors.surfaceVariant,
      onSurfaceVariant: colors.textSecondary,
      outline: colors.divider,
      outlineVariant: colors.divider,
      inverseSurface: colors.textPrimary,
      onInverseSurface: colors.background,
      inversePrimary: colors.accentHover,
      surfaceTint: colors.accent,
    );

    return _baseTheme(
      colors,
      scheme,
      Brightness.dark,
      fontFamily: fontFamily,
      radius: radius,
      secondary: secondary,
      titleWeight: titleWeight,
      titleSpacing: titleSpacing,
      uppercaseTitles: uppercaseTitles,
    );
  }

  static ThemeData _buildLight(
    HermesThemeColors colors, {
    String fontFamily = 'Inter',
    double radius = 10.0,
    Color? secondary,
    FontWeight titleWeight = FontWeight.w600,
    double titleSpacing = 0.0,
    bool uppercaseTitles = false,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: colors.accent,
      brightness: Brightness.light,
      primary: colors.accent,
      onPrimary: colors.onAccent,
      secondary: colors.accentHover,
      onSecondary: colors.onAccent,
      surface: colors.surface,
      onSurface: colors.textPrimary,
      error: colors.error,
      onError: colors.onAccent,
    );

    return _baseTheme(
      colors,
      scheme,
      Brightness.light,
      fontFamily: fontFamily,
      radius: radius,
      secondary: secondary,
      titleWeight: titleWeight,
      titleSpacing: titleSpacing,
      uppercaseTitles: uppercaseTitles,
    );
  }

  static ThemeData _baseTheme(
    HermesThemeColors colors,
    ColorScheme scheme,
    Brightness brightness, {
    String fontFamily = 'Inter',
    double radius = 10.0,
    Color? secondary,
    FontWeight titleWeight = FontWeight.w600,
    double titleSpacing = 0.0,
    bool uppercaseTitles = false,
  }) {
    // El color de contraste cae al accentHover si el preset no lo define, para
    // que los temas legacy (fromMode) sigan luciendo coherentes.
    final sec = secondary ?? colors.accentHover;
    // Color de texto/iconos LEGIBLE sobre `sec` (el color de "seleccionado").
    // En varios temas `sec` es un amarillo/ámbar muy claro: si el label se queda
    // en textPrimary (claro) NO se lee. Black or white, whichever reads
    // better: the old luminance > 0.45 cut painted white on mid-tone
    // teal/brass/sage at 2.1–2.9:1.
    final onSec = ThemeContrast.bestBlackOrWhite(sec) == Colors.black
        ? const Color(0xFF0A0A0A)
        : Colors.white;
    final c = colors.copyWith(secondary: sec, uppercaseTitles: uppercaseTitles);
    final scheme2 = scheme.copyWith(
      secondary: sec,
      onSecondary: c.onAccent,
      tertiary: sec,
      onTertiary: c.onAccent,
      // Fija los campos núcleo del esquema a los tokens del tema.
      // `ColorScheme.fromSeed` respeta estos overrides para brillo OSCURO pero
      // los REARMONIZA en brillo CLARO (genera surface tintado por el seed,
      // onSurface más apagado y outline propio), dejando los temas claros
      // incoherentes con su propia paleta y con los oscuros. Forzarlos aquí
      // iguala ambos: todo tema usa accent/surface/textPrimary/divider de su
      // paleta. Para los oscuros es un no-op (ya coincidían). No rompe Claude.
      primary: c.accent,
      onPrimary: c.onAccent,
      surface: c.surface,
      onSurface: c.textPrimary,
      outline: c.divider,
      surfaceTint: c.accent,
    );

    final base = ThemeData(
      colorScheme: scheme2,
      brightness: brightness,
      useMaterial3: true,
      scaffoldBackgroundColor: c.background,
      extensions: [c],
      fontFamily: fontFamily,
    );
    final controlTextStyle = TextStyle(
      color: c.textPrimary,
      fontSize: 14,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    );

    final chrome = HermesChrome.of(c);
    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        foregroundColor: c.textPrimary,
        elevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: c.textPrimary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
          fontSize: 17,
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: HermesPageTransitionsBuilder(),
          TargetPlatform.iOS: HermesPageTransitionsBuilder(),
        },
      ),
      cardTheme: CardThemeData(
        color: colors.surfaceVariant.withValues(alpha: 0.22),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        margin: const EdgeInsets.symmetric(vertical: 3),
        // Tarjetas planas estilo Claude: panel suave sin borde ni elevación.
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: chrome.opaque,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        showDragHandle: false,
      ),
      // Dialogs and menus are floating surfaces: the chrome's opaque
      // tone, its hairline, and the dialog scrim.
      dialogTheme: DialogThemeData(
        backgroundColor: chrome.opaque,
        surfaceTintColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: HermesChrome.scrimDialog),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: chrome.line),
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: colors.background,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: DividerThemeData(color: colors.divider),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: sec,
        foregroundColor: onSec,
        // FAB ("+") siempre circular.
        shape: const CircleBorder(),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.accent,
          foregroundColor: colors.onAccent,
          disabledBackgroundColor: colors.textDisabled,
          disabledForegroundColor: colors.textSecondary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colors.surfaceVariant,
          foregroundColor: colors.textPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: sec),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: colors.divider.withValues(alpha: 0.55)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: colors.divider.withValues(alpha: 0.55)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: colors.accent.withValues(alpha: 0.55)),
        ),
        labelStyle: TextStyle(color: colors.textSecondary),
        hintStyle: TextStyle(color: colors.textSecondary),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: colors.surfaceVariant,
        disabledColor: colors.textDisabled,
        selectedColor: sec,
        secondarySelectedColor: sec,
        labelStyle: TextStyle(color: colors.textPrimary),
        // SELECCIONADO: el label usa secondaryLabelStyle → color con contraste
        // sobre `sec` (antes se quedaba claro sobre amarillo = ilegible).
        secondaryLabelStyle: TextStyle(color: onSec),
        checkmarkColor: onSec,
        side: BorderSide(color: colors.divider.withValues(alpha: 0.55)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colors.textSecondary,
        textColor: colors.textPrimary,
        titleTextStyle: controlTextStyle.copyWith(fontWeight: FontWeight.w600),
        subtitleTextStyle: controlTextStyle.copyWith(
          color: colors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w400,
          height: 1.35,
        ),
        minTileHeight: 52,
        minVerticalPadding: 10,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: chrome.opaque,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: chrome.line),
        ),
        textStyle: controlTextStyle,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => controlTextStyle.copyWith(
            color: states.contains(WidgetState.disabled)
                ? c.textDisabled
                : c.textPrimary,
          ),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: controlTextStyle,
        disabledColor: c.textDisabled,
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(chrome.opaque),
          elevation: const WidgetStatePropertyAll(6.0),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return colors.textPrimary;
            }
            return colors.textSecondary;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return colors.surface;
            return colors.surfaceVariant.withValues(alpha: 0.42);
          }),
          side: WidgetStateProperty.all(
            BorderSide(color: colors.divider.withValues(alpha: 0.38)),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.surface,
        contentTextStyle: TextStyle(
          color: colors.textPrimary,
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
          height: 1.35,
        ),
        actionTextColor: sec,
        disabledActionTextColor: colors.textDisabled,
        elevation: 8,
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.divider.withValues(alpha: 0.78)),
        ),
        closeIconColor: colors.textSecondary,
      ),
      switchTheme: SwitchThemeData(
        // Standard Material 3 switch: a round thumb (no glyph icon — the old
        // `Icons.square_rounded` rendered as a black square on device) on the
        // theme's accent track. The selected thumb is white on every accent,
        // the idle one uses the secondary text tone like M3's outline thumb.
        thumbIcon: const WidgetStatePropertyAll<Icon?>(null),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          if (states.contains(WidgetState.disabled)) {
            return selected
                ? Colors.white.withValues(alpha: 0.7)
                : colors.textDisabled;
          }
          return selected ? Colors.white : colors.textSecondary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return colors.surfaceVariant.withValues(alpha: 0.45);
          }
          if (states.contains(WidgetState.selected)) return colors.accent;
          return colors.surfaceVariant;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.transparent;
          return colors.textDisabled;
        }),
        trackOutlineWidth: const WidgetStatePropertyAll(1.5),
        overlayColor: WidgetStatePropertyAll(
          colors.accent.withValues(alpha: 0.12),
        ),
        splashRadius: 20,
      ),
      textTheme: _titledTextTheme(
        base.textTheme.apply(
          bodyColor: c.textPrimary,
          displayColor: c.textPrimary,
          fontFamily: fontFamily,
        ),
        // Spec 080: titles never use the accent colour; accent is reserved
        // for actions and active state.
        titleColor: c.textPrimary,
        titleWeight: titleWeight,
        titleSpacing: titleSpacing,
      ),
      iconTheme: IconThemeData(color: colors.textSecondary),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.accentHover,
      ),
    );
  }

  static ThemeData _applyComponentProfile(
    ThemeData base,
    ComponentProfile profile, {
    bool preserveMinimalBaseline = false,
  }) {
    // AppTheme owns the complete extension set (colors + component tokens).
    // Keeping this explicit also avoids the self-referential generic widening
    // that Dart applies when spreading heterogeneous ThemeExtension values.
    final extensions = <Object>[
      base.hermes,
      HermesComponentTheme(profile),
    ].cast<ThemeExtension<dynamic>>();
    if (preserveMinimalBaseline && profile.id == ComponentProfiles.minimal.id) {
      return base.copyWith(extensions: extensions);
    }

    final colors = base.hermes;
    final terminal = profile.id == ComponentProfiles.terminal.id;
    final shape = WidgetStatePropertyAll<OutlinedBorder>(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(profile.shape.buttonRadius),
      ),
    );
    final padding = WidgetStatePropertyAll<EdgeInsetsGeometry>(
      EdgeInsets.symmetric(
        horizontal: 16 * profile.density.visualPaddingScale,
        vertical: 12 * profile.density.visualPaddingScale,
      ),
    );
    final minimumSize = const WidgetStatePropertyAll(Size(48, 48));
    final elevation = WidgetStateProperty.resolveWith<double?>((states) {
      if (states.contains(WidgetState.pressed)) {
        return profile.elevation.pressed;
      }
      return profile.elevation.resting;
    });
    final overlay = WidgetStateProperty.resolveWith<Color?>((states) {
      if (!states.contains(WidgetState.pressed) &&
          !states.contains(WidgetState.focused)) {
        return null;
      }
      return colors.accent.withValues(alpha: profile.effects.staticTintOpacity);
    });

    ButtonStyle tune(
      ButtonStyle? current, {
      bool outlined = false,
      bool forceBorderless = false,
    }) {
      final borderWidth = outlined
          ? profile.border.emphasizedWidth.clamp(1.0, 3.0)
          : profile.border.width;
      final currentTextStyle = current?.textStyle?.resolve(
        const <WidgetState>{},
      );
      final side =
          forceBorderless ||
              (terminal && !outlined) ||
              (!outlined && !profile.border.outlinesRestingControls)
          ? const WidgetStatePropertyAll<BorderSide?>(BorderSide.none)
          : WidgetStatePropertyAll<BorderSide?>(
              BorderSide(color: colors.divider, width: borderWidth),
            );
      return (current ?? const ButtonStyle()).copyWith(
        shape: shape,
        padding: padding,
        minimumSize: minimumSize,
        elevation: elevation,
        overlayColor: overlay,
        side: side,
        textStyle: terminal
            ? WidgetStatePropertyAll<TextStyle?>(
                (currentTextStyle ?? const TextStyle()).copyWith(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.55,
                ),
              )
            : null,
        animationDuration: Duration(
          milliseconds: profile.motion.stateDurationMs,
        ),
        tapTargetSize: MaterialTapTargetSize.padded,
      );
    }

    BorderSide boundary(Color color, double width) =>
        width <= 0 ? BorderSide.none : BorderSide(color: color, width: width);

    final fieldRadius = BorderRadius.circular(profile.shape.fieldRadius);
    final InputBorder fieldBorder = terminal
        ? UnderlineInputBorder(
            borderSide: boundary(colors.divider, profile.border.width),
          )
        : OutlineInputBorder(
            borderRadius: fieldRadius,
            borderSide: boundary(colors.divider, profile.border.width),
          );
    final InputBorder focusedFieldBorder = terminal
        ? UnderlineInputBorder(
            borderSide: boundary(
              colors.accent,
              profile.border.emphasizedWidth.clamp(1.0, 3.0),
            ),
          )
        : OutlineInputBorder(
            borderRadius: fieldRadius,
            borderSide: boundary(
              colors.accent,
              profile.border.emphasizedWidth.clamp(1.0, 3.0),
            ),
          );
    final cardSide = profile.border.outlinesRestingControls
        ? BorderSide(color: colors.divider, width: profile.border.width)
        : BorderSide.none;
    // Floating surfaces always keep the chrome's hairline.
    final floatingSide = BorderSide(color: HermesChrome.of(colors).line);

    return base.copyWith(
      extensions: extensions,
      filledButtonTheme: FilledButtonThemeData(
        style: tune(base.filledButtonTheme.style),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: tune(base.elevatedButtonTheme.style),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: tune(base.outlinedButtonTheme.style, outlined: true),
      ),
      textButtonTheme: TextButtonThemeData(
        style: tune(base.textButtonTheme.style, forceBorderless: terminal),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: tune(base.iconButtonTheme.style, forceBorderless: terminal),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        fillColor: colors.surfaceVariant.withValues(
          alpha: 0.35 + profile.effects.staticTintOpacity,
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: 14 * profile.density.visualPaddingScale,
          vertical: 13 * profile.density.visualPaddingScale,
        ),
        border: fieldBorder,
        enabledBorder: fieldBorder,
        focusedBorder: focusedFieldBorder,
      ),
      cardTheme: base.cardTheme.copyWith(
        elevation: profile.elevation.resting,
        shadowColor: profile.effects.usesStaticShadow
            ? Colors.black.withValues(alpha: 0.28)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(profile.shape.cardRadius),
          side: cardSide,
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        padding: EdgeInsets.symmetric(
          horizontal: 8 * profile.density.visualPaddingScale,
          vertical: 4 * profile.density.visualPaddingScale,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(profile.shape.chipRadius),
        ),
        side: boundary(colors.divider, profile.border.width),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        elevation: profile.elevation.modal,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(profile.shape.groupRadius),
          side: floatingSide,
        ),
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        elevation: profile.elevation.modal,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(profile.shape.groupRadius),
          ),
        ),
      ),
      popupMenuTheme: base.popupMenuTheme.copyWith(
        elevation: profile.elevation.modal,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(profile.shape.groupRadius),
          side: floatingSide,
        ),
      ),
    );
  }

  /// Tiñe los títulos con [titleColor] (textPrimary, spec 080) y les aplica el peso y el
  /// tracking de su personalidad, dejando el cuerpo de texto sin tocar. Es lo
  /// que hace que la jerarquía se "sienta" distinta entre temas, no solo
  /// recoloreada.
  static TextTheme _titledTextTheme(
    TextTheme tt, {
    required Color titleColor,
    required FontWeight titleWeight,
    required double titleSpacing,
  }) {
    TextStyle? title(TextStyle? s) => s?.copyWith(
      color: titleColor,
      fontWeight: titleWeight,
      letterSpacing: titleSpacing,
    );
    TextStyle? head(TextStyle? s) =>
        s?.copyWith(fontWeight: titleWeight, letterSpacing: titleSpacing);
    return tt.copyWith(
      headlineLarge: head(tt.headlineLarge),
      headlineMedium: head(tt.headlineMedium),
      headlineSmall: head(tt.headlineSmall),
      titleLarge: title(tt.titleLarge),
      // Los controles neutralizan su texto en sus temas específicos. Mantener
      // aquí la jerarquía global evita encoger títulos de contenido/Markdown.
      titleMedium: title(tt.titleMedium),
    );
  }
}
