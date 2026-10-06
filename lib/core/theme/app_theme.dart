import 'dart:math' as math;

import 'package:flutter/material.dart';

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

  // Claude: inspirado en la app de Claude. Carbón cálido (no negro puro),
  // acento coral/arcilla, texto marfil. Sensación papel + calma, muy minimal.
  static const _claudeColors = HermesThemeColors(
    background: Color(0xFF262624),
    surface: Color(0xFF30302E),
    surfaceVariant: Color(0xFF3B3A37),
    accent: Color(0xFFC96442),
    accentHover: Color(0xFFD97757),
    onAccent: Color(0xFFFCF7F4),
    textPrimary: Color(0xFFF5F3EC),
    textSecondary: Color(0xFFABA899),
    // WCAG AA: dim subido de #6E6B61 (2.8:1) a ≥3:1 para iconos atenuados.
    textDisabled: Color(0xFF7E7B70),
    // WCAG AA: el rojo previo (#BF4D43, 3.15:1) fallaba como texto de error
    // normal; #E0695C alcanza 4.58:1 sobre el carbón cálido sin perder el tono.
    error: Color(0xFFE0695C),
    success: Color(0xFF7FA37F),
    warning: Color(0xFFD9A066),
    divider: Color(0xFF3B3A37),
  );

  // Claude Light: el papel cálido de Claude — crema, coral profundo, texto
  // tinta cálida. El claro más sereno del catálogo.
  static const _claudeLightColors = HermesThemeColors(
    background: Color(0xFFFAF9F5),
    surface: Color(0xFFFFFFFF),
    surfaceVariant: Color(0xFFF0EEE6),
    accent: Color(0xFFC15F3C),
    accentHover: Color(0xFFA94E30),
    onAccent: Color(0xFFFFFFFF),
    textPrimary: Color(0xFF3D3D3A),
    textSecondary: Color(0xFF73716A),
    textDisabled: Color(0xFFAAA89E),
    error: Color(0xFFB23A30),
    success: Color(0xFF5F8A63),
    warning: Color(0xFFB5803A),
    divider: Color(0xFFE7E4DA),
    // WCAG AA: el coral de marca (#C15F3C) da ~4.0:1 sobre este fondo, por
    // debajo de 4.5:1; #9C4A2C (misma familia, oscurecido) da ~5.8:1.
    accentText: Color(0xFF9C4A2C),
  );

  // ── Paletas premium adicionales ──────────────────────────────────────
  // Cada una tinta el texto y las superficies a su familia de color para
  // dar cohesión (lo que hace que se sienta "otra app", no un recolor).

  // Verde fósforo: terminal CRT, negro puro con verde brillante.
  static const _phosphorColors = HermesThemeColors(
    background: Color(0xFF000000),
    surface: Color(0xFF06120A),
    surfaceVariant: Color(0xFF0C1E12),
    accent: Color(0xFF36F58A),
    accentHover: Color(0xFF74FFB0),
    onAccent: Color(0xFF00140A),
    textPrimary: Color(0xFFCFEFD8),
    textSecondary: Color(0xFF5FA877),
    textDisabled: Color(0xFF2E5A3E),
    error: Color(0xFFFF6B6B),
    success: Color(0xFF36F58A),
    warning: Color(0xFFE2C84A),
    divider: Color(0xFF143523),
  );

  // Gruvbox: el clásico retro de vim — pardos cálidos y naranja tostado.
  // Retirado en U-10 y devuelto al catálogo en jul-2026 a petición del autor.
  static const _gruvboxColors = HermesThemeColors(
    background: Color(0xFF1D2021),
    surface: Color(0xFF282828),
    surfaceVariant: Color(0xFF3C3836),
    accent: Color(0xFFFE8019),
    accentHover: Color(0xFFFFA94D),
    onAccent: Color(0xFF1D2021),
    textPrimary: Color(0xFFEBDBB2),
    textSecondary: Color(0xFFA89984),
    textDisabled: Color(0xFF665C54),
    error: Color(0xFFFB4934),
    success: Color(0xFFB8BB26),
    warning: Color(0xFFFABD2F),
    divider: Color(0xFF32302F),
  );

  // Sage Garden: verde salvia apagado sobre un oscuro con tinte vegetal —
  // la calma de un invernadero de noche.
  static const _sageGardenColors = HermesThemeColors(
    background: Color(0xFF11150F),
    surface: Color(0xFF1A2018),
    surfaceVariant: Color(0xFF242D21),
    accent: Color(0xFFA9C29B),
    accentHover: Color(0xFFC4D8B8),
    onAccent: Color(0xFF131810),
    textPrimary: Color(0xFFE2E8DC),
    textSecondary: Color(0xFF93A38A),
    textDisabled: Color(0xFF4F5C48),
    error: Color(0xFFE08070),
    success: Color(0xFF9BCB84),
    warning: Color(0xFFD9C077),
    divider: Color(0xFF222B1F),
  );

  // Hermes Console: los colores del logo — negro azulado profundo, plata
  // metálica y azul eléctrico del glow.
  static const _hermesConsoleColors = HermesThemeColors(
    background: Color(0xFF060B14),
    surface: Color(0xFF0E1626),
    surfaceVariant: Color(0xFF16213A),
    accent: Color(0xFF36A6FF),
    accentHover: Color(0xFF74C3FF),
    onAccent: Color(0xFF04101F),
    textPrimary: Color(0xFFD6DEE9),
    textSecondary: Color(0xFF8694AB),
    textDisabled: Color(0xFF4A576E),
    error: Color(0xFFFF6B7D),
    success: Color(0xFF3FD6A8),
    warning: Color(0xFFF5C45A),
    divider: Color(0xFF1B2740),
  );

  // Catppuccin Mocha: el pastel oscuro más querido, acento malva.
  static const _mochaColors = HermesThemeColors(
    background: Color(0xFF1E1E2E),
    surface: Color(0xFF313244),
    surfaceVariant: Color(0xFF45475A),
    accent: Color(0xFFCBA6F7),
    accentHover: Color(0xFFDDBDFD),
    onAccent: Color(0xFF1E1E2E),
    textPrimary: Color(0xFFD5C4F7),
    textSecondary: Color(0xFFA6ADC8),
    textDisabled: Color(0xFF6C7086),
    error: Color(0xFFF38BA8),
    success: Color(0xFFA6E3A1),
    warning: Color(0xFFF9E2AF),
    divider: Color(0xFF45475A),
  );

  // Dracula: cian sobre slate oscuro — el clásico cyberpunk.
  static const _draculaColors = HermesThemeColors(
    background: Color(0xFF21222C),
    surface: Color(0xFF282A36),
    surfaceVariant: Color(0xFF383A4A),
    accent: Color(0xFF8BE9FD),
    accentHover: Color(0xFFB0F5FF),
    onAccent: Color(0xFF03202B),
    textPrimary: Color(0xFFF8F8F2),
    textSecondary: Color(0xFFA0C8D8),
    textDisabled: Color(0xFF6272A4),
    error: Color(0xFFFF5555),
    success: Color(0xFF50FA7B),
    warning: Color(0xFFF1FA8C),
    divider: Color(0xFF383A4A),
  );

  // Crimson: rojo apagado y elegante sobre charcoal con tinte cálido. El
  // acento es un rojo profundo (no agresivo); el texto en botones va claro
  // porque el acento es oscuro. Toda la paleta se tiñe a la familia roja.
  static const _crimsonColors = HermesThemeColors(
    background: Color(0xFF120D0D),
    surface: Color(0xFF1C1413),
    surfaceVariant: Color(0xFF261A19),
    accent: Color(0xFFC0392B),
    accentHover: Color(0xFFD8584A),
    onAccent: Color(0xFFFCEEEC),
    textPrimary: Color(0xFFECE0DF),
    textSecondary: Color(0xFFA98C89),
    textDisabled: Color(0xFF5C4744),
    error: Color(0xFFFF6B6B),
    success: Color(0xFF5CC98A),
    warning: Color(0xFFE0A33A),
    divider: Color(0xFF2D1F1D),
  );

  // Steel: acero frío — casi-negro azulado con acento azul acero desaturado.
  // Elegante y silencioso (nada de neón): el contrapunto frío al ámbar de
  // marca. Curación U-10 (spec 028). Contrastes WCAG calculados sobre esta
  // paleta: textPrimary/background 15.96:1, textPrimary/surface 14.86:1,
  // textPrimary/surfaceVariant 13.41:1, accent/background 8.99:1 (vale como
  // texto, ≥4.5), onAccent/accent 8.81:1, textSecondary/background 7.44:1,
  // secondary/background 9.04:1, textDisabled/background 3.45:1.
  static const _steelColors = HermesThemeColors(
    background: Color(0xFF0A0D11),
    surface: Color(0xFF12161D),
    surfaceVariant: Color(0xFF1A202A),
    accent: Color(0xFF8FB4D9),
    accentHover: Color(0xFFAECBE8),
    onAccent: Color(0xFF0B1017),
    textPrimary: Color(0xFFE4E9F0),
    textSecondary: Color(0xFF94A1B5),
    textDisabled: Color(0xFF5C687C),
    error: Color(0xFFFF6B7D),
    success: Color(0xFF4ED0A0),
    warning: Color(0xFFF5C45A),
    divider: Color(0xFF202836),
  );

  // Bordeaux: burdeos y cobre — negro-vino profundo con acento cobre suave
  // (desaturado, no el ámbar de marca) y contrapunto salvia. Cálido y de
  // terciopelo, entre Amber y Crimson. Curación U-10 (spec 028). Contrastes
  // WCAG calculados: textPrimary/background 15.67:1, textPrimary/surface
  // 14.73:1, textPrimary/surfaceVariant 13.56:1, accent/background 7.43:1
  // (vale como texto, ≥4.5), onAccent/accent 7.22:1, textSecondary/background
  // 6.56:1, secondary/background 9.23:1, textDisabled/background 3.11:1.
  static const _bordeauxColors = HermesThemeColors(
    background: Color(0xFF140A0F),
    surface: Color(0xFF1E1118),
    surfaceVariant: Color(0xFF291822),
    accent: Color(0xFFD98E68),
    accentHover: Color(0xFFE8AA8A),
    onAccent: Color(0xFF1C0D07),
    textPrimary: Color(0xFFF0E4E4),
    textSecondary: Color(0xFFAD8E96),
    textDisabled: Color(0xFF745964),
    error: Color(0xFFFF6B7D),
    success: Color(0xFF5CC98A),
    warning: Color(0xFFE8B45A),
    divider: Color(0xFF301C26),
  );

  // Graphite: monocromo puro — grises sobre casi-negro, acento plata. Sin
  // tinte de color (el contrapunto premium a todo el catálogo de acentos);
  // solo error/success/warning llevan color por necesidad semántica.
  static const _graphiteColors = HermesThemeColors(
    background: Color(0xFF08090A),
    surface: Color(0xFF141517),
    surfaceVariant: Color(0xFF1E1F22),
    accent: Color(0xFFEDEDEF),
    accentHover: Color(0xFFFFFFFF),
    onAccent: Color(0xFF0A0A0B),
    textPrimary: Color(0xFFF4F4F5),
    textSecondary: Color(0xFF9A9AA2),
    textDisabled: Color(0xFF55555C),
    error: Color(0xFFF87171),
    success: Color(0xFF4ADE80),
    warning: Color(0xFFFBBF24),
    divider: Color(0xFF26272B),
  );

  // ── Temas oficiales de Hermes Desktop ────────────────────────────────
  // Fuente canónica: apps/desktop/src/themes/presets.ts. Solo se adapta la
  // semántica de tokens (card→surface, muted→surfaceVariant, ring→accent);
  // los colores de identidad permanecen idénticos.
  static const _desktopNousAltColors = HermesThemeColors(
    background: Color(0xFFF8FAFF),
    surface: Color(0xFFFFFFFF),
    surfaceVariant: Color(0xFFF2F6FF),
    accent: Color(0xFF0053FD),
    accentHover: Color(0xFF1540B1),
    onAccent: Color(0xFFFCFCFC),
    textPrimary: Color(0xFF17171A),
    textSecondary: Color(0xFF666678),
    textDisabled: Color(0xFF8A8A98),
    error: Color(0xFFC72E4D),
    success: Color(0xFF18864B),
    warning: Color(0xFFA65C00),
    divider: Color(0xFFC7D9FF),
    accentText: Color(0xFF0053FD),
  );

  static const _desktopNousAltDarkColors = HermesThemeColors(
    background: Color(0xFF0D2F86),
    surface: Color(0xFF12378F),
    surfaceVariant: Color(0xFF183F9A),
    accent: Color(0xFFFFE6CB),
    accentHover: Color(0xFFFFFFFF),
    onAccent: Color(0xFF0D2F86),
    textPrimary: Color(0xFFFFE6CB),
    textSecondary: Color(0xFFB5C7F3),
    textDisabled: Color(0xFF8098D0),
    error: Color(0xFFC0473A),
    success: Color(0xFF77D79B),
    warning: Color(0xFFFFC66D),
    divider: Color(0xFF3158AD),
  );

  static const _desktopMidnightColors = HermesThemeColors(
    background: Color(0xFF08081C),
    surface: Color(0xFF0D0D28),
    surfaceVariant: Color(0xFF13133A),
    accent: Color(0xFF8B80E8),
    accentHover: Color(0xFFDDD6FF),
    onAccent: Color(0xFF08081C),
    textPrimary: Color(0xFFDDD6FF),
    textSecondary: Color(0xFF7C7AB0),
    textDisabled: Color(0xFF55537D),
    error: Color(0xFFB03060),
    success: Color(0xFF4ADE80),
    warning: Color(0xFFFBBF24),
    divider: Color(0xFF1E1E52),
  );

  static const _desktopEmberColors = HermesThemeColors(
    background: Color(0xFF160800),
    surface: Color(0xFF1E0E04),
    surfaceVariant: Color(0xFF2A1408),
    accent: Color(0xFFD97316),
    accentHover: Color(0xFFFFD8B0),
    onAccent: Color(0xFF160800),
    textPrimary: Color(0xFFFFD8B0),
    textSecondary: Color(0xFFAA7A56),
    textDisabled: Color(0xFF735139),
    error: Color(0xFFC43010),
    success: Color(0xFF69B86B),
    warning: Color(0xFFE9A33A),
    divider: Color(0xFF3A1C08),
  );

  static const _desktopMonoColors = HermesThemeColors(
    background: Color(0xFF0E0E0E),
    surface: Color(0xFF141414),
    surfaceVariant: Color(0xFF1E1E1E),
    accent: Color(0xFF9A9A9A),
    accentHover: Color(0xFFEAEAEA),
    onAccent: Color(0xFF0E0E0E),
    textPrimary: Color(0xFFEAEAEA),
    textSecondary: Color(0xFF808080),
    textDisabled: Color(0xFF5D5D5D),
    error: Color(0xFFA84040),
    success: Color(0xFF75A875),
    warning: Color(0xFFC5A15A),
    divider: Color(0xFF2A2A2A),
  );

  static const _desktopCyberpunkColors = HermesThemeColors(
    background: Color(0xFF000A00),
    surface: Color(0xFF001200),
    surfaceVariant: Color(0xFF001A00),
    accent: Color(0xFF00FF41),
    accentHover: Color(0xFF7AFF9C),
    onAccent: Color(0xFF000A00),
    textPrimary: Color(0xFF00FF41),
    textSecondary: Color(0xFF1A8A30),
    textDisabled: Color(0xFF176326),
    error: Color(0xFFFF003C),
    success: Color(0xFF00FF41),
    warning: Color(0xFFFFE600),
    divider: Color(0xFF003000),
  );

  static const _desktopSlateColors = HermesThemeColors(
    background: Color(0xFF0D1117),
    surface: Color(0xFF161B22),
    surfaceVariant: Color(0xFF21262D),
    accent: Color(0xFF58A6FF),
    accentHover: Color(0xFFC9D1D9),
    onAccent: Color(0xFF0D1117),
    textPrimary: Color(0xFFC9D1D9),
    textSecondary: Color(0xFF8B949E),
    textDisabled: Color(0xFF5E6670),
    error: Color(0xFFCF4848),
    success: Color(0xFF3FB950),
    warning: Color(0xFFD29922),
    divider: Color(0xFF30363D),
  );

  /// Maps a Desktop palette that ships its own colours (THEME_PRESET_PALETTES
  /// in apps/shared/src/theme-presets.ts) onto Console tokens with the same
  /// semantics as the presets above: card→surface, muted→surfaceVariant,
  /// ring→accent, border→divider, destructive→error. Desktop colours are kept
  /// byte-for-byte; only a token that misses Console's readability floor is
  /// nudged toward black/white (text 4.5:1 on every surface, muted text 3:1,
  /// button ink 4.5:1), exactly like the light synthesis below does for rings.
  /// Desktop has no disabled/success/warning tokens: disabled is the muted
  /// text faded 30% into the background, success/warning come from the
  /// theme's own terminal palette (lowered to 3:1 on its surfaces).
  static HermesThemeColors _desktopPalette({
    required Brightness brightness,
    required Color background,
    required Color foreground,
    required Color card,
    required Color muted,
    required Color mutedForeground,
    required Color primary,
    required Color ring,
    required Color midgroundForeground,
    required Color border,
    required Color destructive,
    required Color success,
    required Color warning,
  }) {
    final light = brightness == Brightness.light;
    final surfaces = [background, card, muted];
    final textPrimary = ThemeContrast.adjustForContrast(
      foreground,
      surfaces,
      minimum: 4.5,
    );
    // Catppuccin ships no separate muted ink (mutedForeground == foreground);
    // Console needs a distinct secondary tier, so fade it 25% into the page.
    final mutedSeed = mutedForeground == foreground
        ? ThemeContrast.blend(foreground, background, 0.25)
        : mutedForeground;
    final textSecondary = ThemeContrast.adjustForContrast(mutedSeed, [
      background,
      card,
    ], minimum: 3.0);
    final accent = ThemeContrast.adjustForContrast(ring, [
      background,
    ], minimum: 3.0);
    const ink = Color(0xFF161616);
    final onAccent =
        ThemeContrast.meets(midgroundForeground, accent, minimum: 4.5)
        ? midgroundForeground
        : (ThemeContrast.ratio(ink, accent) >=
                  ThemeContrast.ratio(Colors.white, accent)
              ? ink
              : Colors.white);
    // Status colours double as status TEXT (session tones lift them to AA on
    // the page). On skins whose body text is itself near AA (Everforest
    // light), that lift lands on the text colour and a status reads as a
    // title, so push such a tone further from the text, away from the page.
    final pole = light ? Colors.black : Colors.white;
    // Success/warning icons are non-text UI: 3:1 against every surface (WCAG
    // 1.4.11). The error token keeps Desktop's destructive colour.
    Color status(Color tone, {bool iconFloor = true}) {
      final asIcon = iconFloor
          ? ThemeContrast.adjustForContrast(tone, surfaces, minimum: 3.0)
          : tone;
      final asText = ThemeContrast.adjustForContrast(tone, [
        background,
      ], minimum: 4.5);
      if (ThemeContrast.ratio(asText, textPrimary) >= 1.3) return asIcon;
      for (var step = 1; step <= 20; step++) {
        final candidate = ThemeContrast.blend(asText, pole, step / 20);
        if (ThemeContrast.ratio(candidate, textPrimary) >= 1.3) {
          return candidate;
        }
      }
      return asIcon;
    }

    return HermesThemeColors(
      background: background,
      surface: card,
      surfaceVariant: muted,
      accent: accent,
      accentHover: primary != ring
          ? primary
          : ThemeContrast.blend(
              ring,
              light ? Colors.black : Colors.white,
              0.15,
            ),
      onAccent: onAccent,
      textPrimary: textPrimary,
      textSecondary: textSecondary,
      textDisabled: ThemeContrast.blend(textSecondary, background, 0.3),
      error: status(destructive, iconFloor: false),
      success: status(success),
      warning: status(warning),
      divider: border,
      accentText: ThemeContrast.adjustForContrast(accent, [
        background,
        card,
      ], minimum: 4.5),
    );
  }

  // GitHub Light/Dark Default chrome; `nous` re-seeds only the accent family.
  static final _desktopNousColors = _desktopPalette(
    brightness: Brightness.light,
    background: const Color(0xFFFFFFFF),
    foreground: const Color(0xFF1F2328),
    card: const Color(0xFFF6F8FA),
    muted: const Color(0xFFF6F6F6),
    mutedForeground: const Color(0xFF656D76),
    primary: const Color(0xFF0053FD),
    ring: const Color(0xFF0053FD),
    midgroundForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFFD0D7DE),
    destructive: const Color(0xFFCF222E),
    success: const Color(0xFF1A7F37),
    warning: const Color(0xFF9A6700),
  );
  static final _desktopNousDarkColors = _desktopPalette(
    brightness: Brightness.dark,
    background: const Color(0xFF0D1117),
    foreground: const Color(0xFFE6EDF3),
    card: const Color(0xFF010409),
    muted: const Color(0xFF1A1E24),
    mutedForeground: const Color(0xFF7D8590),
    primary: const Color(0xFF4A84FE),
    ring: const Color(0xFF4A84FE),
    midgroundForeground: const Color(0xFF161616),
    border: const Color(0xFF30363D),
    destructive: const Color(0xFFF85149),
    success: const Color(0xFF3FB950),
    warning: const Color(0xFFD29922),
  );
  static final _desktopGithubColors = _desktopPalette(
    brightness: Brightness.light,
    background: const Color(0xFFFFFFFF),
    foreground: const Color(0xFF1F2328),
    card: const Color(0xFFF6F8FA),
    muted: const Color(0xFFF6F6F6),
    mutedForeground: const Color(0xFF656D76),
    primary: const Color(0xFF196D31),
    ring: const Color(0xFF196D31),
    midgroundForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFFD0D7DE),
    destructive: const Color(0xFFCF222E),
    success: const Color(0xFF1A7F37),
    warning: const Color(0xFF9A6700),
  );
  static final _desktopGithubDarkColors = _desktopPalette(
    brightness: Brightness.dark,
    background: const Color(0xFF0D1117),
    foreground: const Color(0xFFE6EDF3),
    card: const Color(0xFF010409),
    muted: const Color(0xFF1A1E24),
    mutedForeground: const Color(0xFF7D8590),
    primary: const Color(0xFF4F9E5E),
    ring: const Color(0xFF4F9E5E),
    midgroundForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFF30363D),
    destructive: const Color(0xFFF85149),
    success: const Color(0xFF3FB950),
    warning: const Color(0xFFD29922),
  );
  static final _desktopCatppuccinColors = _desktopPalette(
    brightness: Brightness.light,
    background: const Color(0xFFEFF1F5),
    foreground: const Color(0xFF4C4F69),
    card: const Color(0xFFE6E9EF),
    muted: const Color(0xFFE8EBEF),
    mutedForeground: const Color(0xFF4C4F69),
    primary: const Color(0xFF6D2EBF),
    ring: const Color(0xFF6D2EBF),
    midgroundForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFFACB0BE),
    destructive: const Color(0xFFD20F39),
    success: const Color(0xFF40A02B),
    warning: const Color(0xFFDF8E1D),
  );
  static final _desktopCatppuccinDarkColors = _desktopPalette(
    brightness: Brightness.dark,
    background: const Color(0xFF1E1E2E),
    foreground: const Color(0xFFCDD6F4),
    card: const Color(0xFF181825),
    muted: const Color(0xFF29293A),
    mutedForeground: const Color(0xFFCDD6F4),
    primary: const Color(0xFFCBA6F7),
    ring: const Color(0xFFCBA6F7),
    midgroundForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFF585B70),
    destructive: const Color(0xFFF38BA8),
    success: const Color(0xFFA6E3A1),
    warning: const Color(0xFFF9E2AF),
  );
  static final _desktopEverforestColors = _desktopPalette(
    brightness: Brightness.light,
    background: const Color(0xFFFDF6E3),
    foreground: const Color(0xFF5C6A72),
    card: const Color(0xFFFDF6E3),
    muted: const Color(0xFFF7F0DE),
    mutedForeground: const Color(0xFF939F91),
    primary: const Color(0xFF586B35),
    ring: const Color(0xFF586B35),
    midgroundForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFFFDF6E3),
    destructive: const Color(0xFFF1706F),
    success: const Color(0xFF8DA101),
    warning: const Color(0xFFDFA000),
  );
  static final _desktopEverforestDarkColors = _desktopPalette(
    brightness: Brightness.dark,
    background: const Color(0xFF2D353B),
    foreground: const Color(0xFFD3C6AA),
    card: const Color(0xFF2D353B),
    muted: const Color(0xFF373E42),
    mutedForeground: const Color(0xFF859289),
    primary: const Color(0xFFA7C080),
    ring: const Color(0xFFA7C080),
    midgroundForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFF2D353B),
    destructive: const Color(0xFFDA6362),
    success: const Color(0xFFA7C080),
    warning: const Color(0xFFDBBC7F),
  );
  static final _desktopSolarizedColors = _desktopPalette(
    brightness: Brightness.light,
    background: const Color(0xFFFDF6E3),
    foreground: const Color(0xFF1F1F1F),
    card: const Color(0xFFD3CBB7),
    muted: const Color(0xFFF4EDDB),
    mutedForeground: const Color(0xFF9CA8A6),
    primary: const Color(0xFF675E34),
    ring: const Color(0xFF675E34),
    midgroundForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFFDDD6C1),
    destructive: const Color(0xFFE25563),
    success: const Color(0xFF859900),
    warning: const Color(0xFFB58900),
  );
  static final _desktopSolarizedDarkColors = _desktopPalette(
    brightness: Brightness.dark,
    background: const Color(0xFF002B36),
    foreground: const Color(0xFF839496),
    card: const Color(0xFF002B36),
    muted: const Color(0xFF08313C),
    mutedForeground: const Color(0xFF586E75),
    primary: const Color(0xFF6EA1C4),
    ring: const Color(0xFF6EA1C4),
    midgroundForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFF234751),
    destructive: const Color(0xFFE35957),
    success: const Color(0xFF859900),
    warning: const Color(0xFFB58900),
  );
  // Classic Hermes: Desktop runs the CLI `default` skin (and its light
  // overlay) through skinToDesktopTheme; these are that converter's outputs.
  static final _desktopClassicColors = _desktopPalette(
    brightness: Brightness.light,
    background: const Color(0xFFF5F5F5),
    foreground: const Color(0xFF2B2109),
    card: const Color(0xFFF0F0EF),
    muted: const Color(0xFFEDEDEC),
    mutedForeground: const Color(0xFFB8860B),
    primary: const Color(0xFF825D02),
    ring: const Color(0xFF825D02),
    midgroundForeground: const Color(0xFFFFFFFF),
    border: const Color(0xFFCD7F32),
    destructive: const Color(0xFFC62828),
    success: const Color(0xFF18864B),
    warning: const Color(0xFFA65C00),
  );
  static final _desktopClassicDarkColors = _desktopPalette(
    brightness: Brightness.dark,
    background: const Color(0xFF1A1A2E),
    foreground: const Color(0xFFFFF8DC),
    card: const Color(0xFF232335),
    muted: const Color(0xFF282738),
    mutedForeground: const Color(0xFFB8860B),
    primary: const Color(0xFFFFBF00),
    ring: const Color(0xFFFFBF00),
    midgroundForeground: const Color(0xFF161616),
    border: const Color(0xFFCD7F32),
    destructive: const Color(0xFFEF5350),
    success: const Color(0xFF4ADE80),
    warning: const Color(0xFFFBBF24),
  );

  /// Equivalente Android de `synthLightColors` en Hermes Desktop. Desktop
  /// separa skin y modo: cuando una skin no publica `darkColors`, conserva la
  /// paleta oscura como semilla y genera esta variante clara con su `ring`.
  static HermesThemeColors _desktopLightFrom(HermesThemeColors seed) {
    final sourceAccent = seed.accent;
    // CSS colors in Desktop are ultimately stored as 8-bit channels. Quantize
    // Flutter's floating-point interpolation as well so a generated preset is
    // byte-stable when Theme Studio persists and restores it.
    Color mix(Color from, Color to, double amount) =>
        Color(Color.lerp(from, to, amount)!.toARGB32());

    // Some Desktop rings are intentionally luminous on the dark skin (Mono,
    // Cyberpunk and Slate). On white they stop being legible as links/icons,
    // so preserve their hue while lowering only the light-mode tone to AA.
    var accent = sourceAccent;
    for (var step = 1; step <= 20; step++) {
      final luminance = accent.computeLuminance();
      final contrastOnWhite = 1.05 / (luminance + 0.05);
      if (contrastOnWhite >= 4.5) break;
      accent = mix(sourceAccent, Colors.black, step / 20);
    }
    final accentLuminance = accent.computeLuminance();
    final blackContrast = (accentLuminance + 0.05) / 0.05;
    final whiteContrast = 1.05 / (accentLuminance + 0.05);
    final onAccent = blackContrast >= whiteContrast
        ? const Color(0xFF161616)
        : Colors.white;
    final soft = mix(Colors.white, sourceAccent, 0.10);
    final softer = mix(Colors.white, sourceAccent, 0.06);
    final border = mix(const Color(0xFFECECEF), sourceAccent, 0.14);
    final mutedText = mix(const Color(0xFF6B6B70), sourceAccent, 0.16);
    return HermesThemeColors(
      background: Colors.white,
      surface: Colors.white,
      surfaceVariant: softer,
      accent: accent,
      accentHover: mix(accent, Colors.black, 0.10),
      onAccent: onAccent,
      textPrimary: const Color(0xFF161616),
      textSecondary: mutedText,
      textDisabled: mix(const Color(0xFF8A8A92), sourceAccent, 0.10),
      error: const Color(0xFFB94A3A),
      success: const Color(0xFF18864B),
      warning: const Color(0xFFA65C00),
      divider: border,
      secondary: soft,
      accentText: accent,
    );
  }

  static final _desktopMidnightLightColors = _desktopLightFrom(
    _desktopMidnightColors,
  );
  static final _desktopEmberLightColors = _desktopLightFrom(
    _desktopEmberColors,
  );
  static final _desktopMonoLightColors = _desktopLightFrom(_desktopMonoColors);
  static final _desktopCyberpunkLightColors = _desktopLightFrom(
    _desktopCyberpunkColors,
  );
  static final _desktopSlateLightColors = _desktopLightFrom(
    _desktopSlateColors,
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
  ///
  /// rt1215: every preset passes through [_withReadableInk], so secondary
  /// text and links reach AA on all of its surfaces.
  static final List<HermesThemePreset> presets = List.unmodifiable(
    _curatedPresets.map(_withReadableInk),
  );

  static final List<HermesThemePreset> _curatedPresets = List.unmodifiable([
    // ── Oscuros ──
    // Amber es el tema por defecto (la firma de Hermes) y va primero.
    HermesThemePreset(
      id: 'amber',
      name: 'Amber',
      tagline: 'deep charcoal · the signature',
      brightness: Brightness.dark,
      colors: _darkColors,
      fontFamily: 'Inter',
      radius: 10.0,
      secondary: Color(0xFF4FB8C9), // teal frío que contrasta el ámbar
      titleWeight: FontWeight.w700,
      titleSpacing: 0.5,
    ),
    HermesThemePreset(
      id: 'claude',
      name: 'Claude',
      tagline: 'warm charcoal · coral clay',
      brightness: Brightness.dark,
      colors: _claudeColors,
      fontFamily: 'Inter',
      radius: 16.0,
      secondary: Color(0xFF7C9CB3), // azul pizarra suave, contraste sereno
      titleWeight: FontWeight.w600,
      titleSpacing: 0.0,
    ),
    HermesThemePreset(
      id: 'amber-oled',
      name: 'Amber OLED',
      tagline: 'pure black · saves battery',
      brightness: Brightness.dark,
      colors: _oledColors,
      fontFamily: 'Inter',
      radius: 10.0,
      secondary: Color(0xFF4FB8C9),
      titleWeight: FontWeight.w700,
      titleSpacing: 0.5,
    ),
    HermesThemePreset(
      id: 'crimson',
      name: 'Crimson',
      tagline: 'muted red · elegant',
      brightness: Brightness.dark,
      colors: _crimsonColors,
      fontFamily: 'Inter',
      radius: 8.0,
      secondary: Color(
        0xFF4FB3A0,
      ), // jade complementario al rojo (no el oro cliché)
      titleWeight: FontWeight.w600,
      titleSpacing: 1.5, // tracking amplio = elegante
    ),
    HermesThemePreset(
      id: 'steel',
      name: 'Steel',
      tagline: 'cold steel blue · precision',
      brightness: Brightness.dark,
      colors: _steelColors,
      fontFamily: 'Inter',
      radius: 8.0,
      secondary: Color(0xFFD9A868), // latón cálido: eco del ámbar de marca
      titleWeight: FontWeight.w600,
      titleSpacing: 1.0,
    ),
    HermesThemePreset(
      id: 'bordeaux',
      name: 'Bordeaux',
      tagline: 'burgundy velvet · copper',
      brightness: Brightness.dark,
      colors: _bordeauxColors,
      fontFamily: 'Montserrat',
      radius: 10.0,
      secondary: Color(0xFF86BFA0), // salvia: contrapunto frío al cobre
      titleWeight: FontWeight.w600,
      titleSpacing: 1.2,
    ),
    HermesThemePreset(
      id: 'hermes-console',
      name: 'Hermes Console',
      tagline: 'logo colors · electric blue',
      brightness: Brightness.dark,
      colors: _hermesConsoleColors,
      fontFamily: 'JetBrainsMono',
      radius: 4.0,
      secondary: Color(0xFFF4B250), // ámbar HUD: cálido que contrasta el azul
      titleWeight: FontWeight.w700,
      titleSpacing: 2.0,
      uppercaseTitles: true,
    ),
    HermesThemePreset(
      id: 'mocha',
      name: 'Catppuccin Mocha',
      tagline: 'pastel mauve · the favorite',
      brightness: Brightness.dark,
      colors: _mochaColors,
      fontFamily: 'Inter',
      radius: 16.0,
      secondary: Color(0xFFFAB387), // durazno pastel
      titleWeight: FontWeight.w800,
      titleSpacing: 0.0,
    ),
    HermesThemePreset(
      id: 'dracula',
      name: 'Dracula',
      tagline: 'cyberpunk cyan · dark slate',
      brightness: Brightness.dark,
      colors: _draculaColors,
      fontFamily: 'JetBrainsMono',
      radius: 4.0,
      secondary: Color(0xFFFF79C6), // rosa neón
      titleWeight: FontWeight.w700,
      titleSpacing: 2.0,
      uppercaseTitles: true,
    ),
    HermesThemePreset(
      id: 'phosphor',
      name: 'Phosphor',
      tagline: 'green CRT terminal',
      brightness: Brightness.dark,
      colors: _phosphorColors,
      fontFamily: 'JetBrainsMono',
      radius: 2.0,
      secondary: Color(0xFFE2C84A), // ámbar CRT
      titleWeight: FontWeight.w700,
      titleSpacing: 3.0,
      uppercaseTitles: true,
    ),
    HermesThemePreset(
      id: 'gruvbox',
      name: 'Gruvbox',
      tagline: 'retro warm · vim classic',
      brightness: Brightness.dark,
      colors: _gruvboxColors,
      fontFamily: 'JetBrainsMono',
      radius: 6.0,
      secondary: Color(0xFF8EC07C), // aqua gruvbox: frío que templa el naranja
      titleWeight: FontWeight.w700,
      titleSpacing: 1.0,
    ),
    HermesThemePreset(
      id: 'graphite',
      name: 'Graphite',
      tagline: 'monochrome · pure dark',
      brightness: Brightness.dark,
      colors: _graphiteColors,
      fontFamily: 'Inter',
      radius: 12.0,
      secondary: Color(0xFF8A8A90), // gris neutro: mono de verdad, sin color
      titleWeight: FontWeight.w600,
      titleSpacing: 0.5,
    ),
    HermesThemePreset(
      id: 'sage-garden',
      name: 'Sage Garden',
      tagline: 'muted sage · quiet greenhouse',
      brightness: Brightness.dark,
      colors: _sageGardenColors,
      fontFamily: 'Inter',
      radius: 16.0,
      secondary: Color(0xFFC9A98A), // arena cálida: la tierra del jardín
      titleWeight: FontWeight.w700,
      titleSpacing: 0.0,
    ),
    // ── Catálogo oficial de Hermes Desktop ──
    // Mismo orden que BUILTIN_THEMES en apps/desktop/src/themes/presets.ts.
    HermesThemePreset(
      id: 'nous',
      name: 'Nous',
      tagline: 'GitHub chrome · Nous blue',
      brightness: Brightness.light,
      colors: _desktopNousColors,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF8250DF),
      desktopOfficial: true,
      desktopFamily: 'nous',
    ),
    HermesThemePreset(
      id: 'nous-dark',
      name: 'Nous',
      tagline: 'GitHub dark · Nous blue',
      brightness: Brightness.dark,
      colors: _desktopNousDarkColors,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFFBC8CFF),
      desktopOfficial: true,
      desktopFamily: 'nous',
    ),
    HermesThemePreset(
      id: 'github',
      name: 'GitHub',
      tagline: 'GitHub Light Default',
      brightness: Brightness.light,
      colors: _desktopGithubColors,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF8250DF),
      desktopOfficial: true,
      desktopFamily: 'github',
    ),
    HermesThemePreset(
      id: 'github-dark',
      name: 'GitHub',
      tagline: 'GitHub Dark Default',
      brightness: Brightness.dark,
      colors: _desktopGithubDarkColors,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFFBC8CFF),
      desktopOfficial: true,
      desktopFamily: 'github',
    ),
    HermesThemePreset(
      id: 'catppuccin',
      name: 'Catppuccin',
      tagline: 'soothing pastels · Latte',
      brightness: Brightness.light,
      colors: _desktopCatppuccinColors,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF1E66F5),
      desktopOfficial: true,
      desktopFamily: 'catppuccin',
    ),
    HermesThemePreset(
      id: 'catppuccin-dark',
      name: 'Catppuccin',
      tagline: 'soothing pastels · Mocha',
      brightness: Brightness.dark,
      colors: _desktopCatppuccinDarkColors,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF94E2D5),
      desktopOfficial: true,
      desktopFamily: 'catppuccin',
    ),
    HermesThemePreset(
      id: 'everforest',
      name: 'Everforest',
      tagline: 'warm, low-contrast forest greens',
      brightness: Brightness.light,
      colors: _desktopEverforestColors,
      fontFamily: 'Inter',
      radius: 12,
      // Everforest blue (#3A94C5) deepened 40% toward black: the light skin's
      // body text is only 5.2:1, so a tone lifted just to AA would land on
      // the text colour and activity labels would read as titles.
      secondary: Color(0xFF235976),
      desktopOfficial: true,
      desktopFamily: 'everforest',
    ),
    HermesThemePreset(
      id: 'everforest-dark',
      name: 'Everforest',
      tagline: 'warm, low-contrast forest greens',
      brightness: Brightness.dark,
      colors: _desktopEverforestDarkColors,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF7FBBB3),
      desktopOfficial: true,
      desktopFamily: 'everforest',
    ),
    HermesThemePreset(
      id: 'solarized',
      name: 'Solarized',
      tagline: 'fixed-contrast light',
      brightness: Brightness.light,
      colors: _desktopSolarizedColors,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF268BD2),
      desktopOfficial: true,
      desktopFamily: 'solarized',
    ),
    HermesThemePreset(
      id: 'solarized-dark',
      name: 'Solarized',
      tagline: 'fixed-contrast dark',
      brightness: Brightness.dark,
      colors: _desktopSolarizedDarkColors,
      fontFamily: 'Inter',
      radius: 12,
      // Solarized cyan (#2AA198) lifted 40% toward white: body text on the
      // dark skin sits near the plain cyan, so activity labels need the
      // lighter tone to stay distinct from titles.
      secondary: Color(0xFF7FC7C1),
      desktopOfficial: true,
      desktopFamily: 'solarized',
    ),
    HermesThemePreset(
      id: 'nous-alt',
      name: 'Nous Alt',
      tagline: 'glass neutrals · Nous blue',
      brightness: Brightness.light,
      colors: _desktopNousAltColors,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFF1540B1),
      desktopOfficial: true,
      desktopFamily: 'nous-alt',
    ),
    HermesThemePreset(
      id: 'nous-alt-dark',
      name: 'Nous Alt',
      tagline: 'deep Nous blue · psyche cream',
      brightness: Brightness.dark,
      colors: _desktopNousAltDarkColors,
      fontFamily: 'Inter',
      radius: 12,
      secondary: Color(0xFFB5C7F3),
      desktopOfficial: true,
      desktopFamily: 'nous-alt',
    ),
    HermesThemePreset(
      id: 'classic',
      name: 'Classic Hermes',
      tagline: 'gold on navy · the original CLI look',
      brightness: Brightness.light,
      colors: _desktopClassicColors,
      fontFamily: 'Inter',
      radius: 10,
      secondary: Color(0xFF1A1A2E),
      desktopOfficial: true,
      desktopFamily: 'classic',
    ),
    HermesThemePreset(
      id: 'classic-dark',
      name: 'Classic Hermes',
      tagline: 'gold on navy · the original CLI look',
      brightness: Brightness.dark,
      colors: _desktopClassicDarkColors,
      fontFamily: 'Inter',
      radius: 10,
      secondary: Color(0xFFCD7F32),
      desktopOfficial: true,
      desktopFamily: 'classic',
    ),
    HermesThemePreset(
      id: 'midnight-light',
      name: 'Midnight',
      tagline: 'cool violet · clear surface',
      brightness: Brightness.light,
      colors: _desktopMidnightLightColors,
      fontFamily: 'JetBrainsMono',
      radius: 10,
      secondary: Color(0xFF8B80E8),
      desktopOfficial: true,
      desktopFamily: 'midnight',
    ),
    HermesThemePreset(
      id: 'midnight',
      name: 'Midnight',
      tagline: 'deep blue-violet · cool accents',
      brightness: Brightness.dark,
      colors: _desktopMidnightColors,
      fontFamily: 'JetBrainsMono',
      radius: 10,
      secondary: Color(0xFFDDD6FF),
      desktopOfficial: true,
      desktopFamily: 'midnight',
    ),
    HermesThemePreset(
      id: 'ember-light',
      name: 'Ember',
      tagline: 'warm bronze · clear surface',
      brightness: Brightness.light,
      colors: _desktopEmberLightColors,
      fontFamily: 'JetBrainsMono',
      radius: 8,
      secondary: Color(0xFFD97316),
      desktopOfficial: true,
      desktopFamily: 'ember',
    ),
    HermesThemePreset(
      id: 'ember',
      name: 'Ember',
      tagline: 'warm crimson · bronze forge',
      brightness: Brightness.dark,
      colors: _desktopEmberColors,
      fontFamily: 'JetBrainsMono',
      radius: 8,
      secondary: Color(0xFFFFD8B0),
      desktopOfficial: true,
      desktopFamily: 'ember',
    ),
    HermesThemePreset(
      id: 'mono-light',
      name: 'Mono',
      tagline: 'clean grayscale · clear surface',
      brightness: Brightness.light,
      colors: _desktopMonoLightColors,
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
      colors: _desktopMonoColors,
      fontFamily: 'JetBrainsMono',
      radius: 8,
      secondary: Color(0xFFEAEAEA),
      desktopOfficial: true,
      desktopFamily: 'mono',
    ),
    HermesThemePreset(
      id: 'slate-light',
      name: 'Slate',
      tagline: 'cool slate · clear surface',
      brightness: Brightness.light,
      colors: _desktopSlateLightColors,
      fontFamily: 'JetBrainsMono',
      radius: 8,
      secondary: Color(0xFF376C9F),
      desktopOfficial: true,
      desktopFamily: 'slate',
    ),
    HermesThemePreset(
      id: 'slate',
      name: 'Slate',
      tagline: 'cool slate blue · developer focus',
      brightness: Brightness.dark,
      colors: _desktopSlateColors,
      fontFamily: 'JetBrainsMono',
      radius: 8,
      secondary: Color(0xFFC9D1D9),
      desktopOfficial: true,
      desktopFamily: 'slate',
    ),
    HermesThemePreset(
      id: 'cyberpunk-light',
      name: 'Cyberpunk',
      tagline: 'neon green · clear surface',
      brightness: Brightness.light,
      colors: _desktopCyberpunkLightColors,
      fontFamily: 'JetBrainsMono',
      radius: 3,
      secondary: Color(0xFF087A24),
      titleSpacing: 2,
      uppercaseTitles: true,
      desktopOfficial: true,
      desktopFamily: 'cyberpunk',
    ),
    HermesThemePreset(
      id: 'cyberpunk',
      name: 'Cyberpunk',
      tagline: 'neon green · matrix terminal',
      brightness: Brightness.dark,
      colors: _desktopCyberpunkColors,
      fontFamily: 'JetBrainsMono',
      radius: 3,
      secondary: Color(0xFFFFE600),
      titleSpacing: 2,
      uppercaseTitles: true,
      desktopOfficial: true,
      desktopFamily: 'cyberpunk',
    ),
    // ── Claros ──
    HermesThemePreset(
      id: 'claude-light',
      name: 'Claude Light',
      tagline: 'warm paper · deep coral',
      brightness: Brightness.light,
      colors: _claudeLightColors,
      fontFamily: 'Inter',
      radius: 16.0,
      secondary: Color(0xFF4F7088), // azul pizarra para enlaces/datos
      titleWeight: FontWeight.w600,
      titleSpacing: 0.0,
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
    );
  }

  /// Secondary text reads at least this much stronger than tertiary.
  static const double _hierarchyStep = 1.1;

  static const String defaultThemeId = 'amber';

  static HermesThemePreset presetById(String? id) {
    return presets.firstWhere((p) => p.id == id, orElse: () => presets.first);
  }

  /// Mapea las claves antiguas (`AppThemeMode`) y los ids de temas RETIRADOS
  /// a ids del catálogo actual. Es el punto único de migración de la pref
  /// `theme_mode`: un usuario con un tema retirado guardado cae al
  /// superviviente más parecido (nunca crashea ni resetea otras prefs).
  static String themeIdFromLegacy(String? legacy) {
    return switch (legacy) {
      // Claves de AppThemeMode (pre-catálogo).
      'oled' => 'amber-oled',
      'teal' => 'dracula',
      'light' => 'claude-light',
      'dark' => 'amber',
      // Ids retirados en la curación U-10 (spec 028) → el más parecido.
      'nous-aqua' => 'hermes-console', // azul eléctrico sobre navy
      'tokyo' => 'steel', // azul frío sobre oscuro
      'onedark' => 'steel', // azul editor sobre slate
      'cobalt2' => 'hermes-console', // azul profundo saturado
      'aguamarina' => 'steel', // sereno y frío
      'synthwave' => 'dracula', // neón cyberpunk
      'ayu-mirage' => 'amber', // melocotón cálido
      'latte' => 'claude-light',
      'solarized-light' => 'claude-light',
      'gruvbox-light' => 'claude-light',
      'manga' => 'claude-light',
      // Si ya es un id válido del catálogo, respétalo; si no, default.
      final v? => presets.any((p) => p.id == v) ? v : defaultThemeId,
      _ => defaultThemeId,
    };
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
    // en textPrimary (claro) NO se lee. Lo elegimos por luminancia (negro sobre
    // claro, blanco sobre oscuro) → contraste garantizado en todas las paletas.
    final onSec = sec.computeLuminance() > 0.45
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
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        showDragHandle: false,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
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
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
          backgroundColor: WidgetStatePropertyAll(c.surface),
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
          side: cardSide,
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
          side: cardSide,
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
