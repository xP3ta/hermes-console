// Design system de Hermes Console — componentes base compartidos.
//
// Lenguaje visual (docs/design/): charcoal casi negro, bordes 1px sutiles,
// ámbar con moderación, iconos dentro de tiles cuadrados redondeados,
// headers de sección uppercase mono con tick ámbar, badges outline.
//
// Regla de renderizado: nunca combinar borderRadius con un Border no
// uniforme de colores distintos (ver AccentCard). Todos los bordes aquí
// son uniformes.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/box_fill.dart';
import '../design/ambient_backdrop.dart';
import '../design/box_edge.dart' show HermesBoxEdges;
import '../design/liquid_sheen.dart';
import '../design/tokens.dart';
import '../theme/component_profile.dart';
import '../theme/lines.dart';
import '../theme/readable_ink.dart';
import '../theme/text_scale.dart';
import '../feedback/haptics.dart';

/// Escala de radios anterior. La escala única es `HermesRadius`
/// (`design/tokens.dart`, auditoría 1.4.0 §3.1); lo nuevo usa esa. Estos
/// valores siguen igual hasta que la ola de literales migre sus usos:
///  - [chip] 9: pasará a `HermesRadius.chip` (6) o `control` (12).
///  - [field] 12: es `HermesRadius.control`.
///  - [card] 14: pasará a `HermesRadius.row` (16).
///  - [group] 16: es `HermesRadius.row`.
abstract final class HermesRadii {
  static const double chip = 9;
  static const double field = 12;
  static const double card = 14;
  static const double group = 16;
}

/// Campo de texto limpio del design system: etiqueta breve en mono ARRIBA +
/// campo relleno y redondeado, sin el outline ni el label flotante (que daban
/// el aspecto recargado/"de formulario genérico"). El foco se marca con un
/// borde de acento sutil. No impone lógica: usa tu controller y callbacks.
class HermesField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final Widget? suffix;
  final void Function(String)? onSubmitted;
  final void Function(String)? onChanged;
  final TextInputType? keyboardType;
  final bool autocorrect;
  final bool enableSuggestions;
  final bool enableIMEPersonalizedLearning;
  final int minLines;

  /// Null lets a multiline field grow with its content (use it on a page
  /// that scrolls, never inside a small floating card).
  final int? maxLines;
  final bool autofocus;
  final List<TextInputFormatter>? inputFormatters;
  final String? errorText;
  final String? helperText;
  final bool enabled;
  final TextInputAction? textInputAction;
  final int? maxLength;
  final FocusNode? focusNode;

  /// Key of the inner [TextField], for finders that read its controller.
  final Key? fieldKey;

  /// False keeps the platform's autofill service (password managers, the
  /// keyboard's saved entries) away from this field: secrets typed here must
  /// not be offered for saving anywhere else.
  final bool autofill;

  /// The selection menu of the field; null keeps the platform's. A field for
  /// a secret passes one without copy and cut.
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  /// What a [TextField] shows when it is given no menu of its own (the
  /// framework keeps that default private, so it is read off a bare one).
  static final EditableTextContextMenuBuilder? _platformMenu =
      const TextField().contextMenuBuilder;

  const HermesField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.suffix,
    this.onSubmitted,
    this.onChanged,
    this.keyboardType,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.enableIMEPersonalizedLearning = true,
    this.minLines = 1,
    this.maxLines = 1,
    this.autofocus = false,
    this.inputFormatters,
    this.errorText,
    this.helperText,
    this.enabled = true,
    this.textInputAction,
    this.maxLength,
    this.focusNode,
    this.fieldKey,
    this.autofill = true,
    this.contextMenuBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final components = Theme.of(context).hermesComponents.profile;
    final fieldRadius = components.shape.fieldRadius;
    final terminal = components.id == ComponentProfiles.terminal.id;
    // A resting field always shows its boundary ([controlBorder], 3:1 on
    // the body it sits on): a filled box alone was ~1.0:1 on the body of a
    // group in every dark theme, a box inside a box nobody could see.
    final restingBorder = components.border.outlinesRestingControls
        ? BorderSide(
            color: colors.controlBorder,
            width: components.border.width,
          )
        : BorderSide(color: colors.controlBorder);
    final InputBorder enabledInputBorder = terminal
        ? UnderlineInputBorder(
            borderSide: BorderSide(
              color: colors.controlBorder,
              width: components.border.width,
            ),
          )
        : OutlineInputBorder(
            borderRadius: BorderRadius.circular(fieldRadius),
            borderSide: restingBorder,
          );
    final InputBorder focusedInputBorder = terminal
        ? UnderlineInputBorder(
            borderSide: BorderSide(
              color: colors.accent.withValues(alpha: 0.8),
              width: components.border.emphasizedWidth,
            ),
          )
        : OutlineInputBorder(
            borderRadius: BorderRadius.circular(fieldRadius),
            borderSide: BorderSide(
              color: colors.accent.withValues(alpha: 0.6),
              width: components.border.emphasizedWidth,
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // La etiqueta visual se excluye del árbol de accesibilidad y se asocia
        // programáticamente al campo vía Semantics: TalkBack anuncia el nombre
        // del campo al enfocarlo sin cambiar el aspecto (spec 028 A-116).
        // Sentence case y una escala legible evitan que cada formulario parezca
        // una consola técnica distinta.
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
                color: colors.textSecondary,
              ),
            ),
          ),
        ),
        Semantics(
          label: label,
          child: TextField(
            key: fieldKey,
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            textInputAction: textInputAction,
            maxLength: maxLength,
            obscureText: obscure,
            onSubmitted: onSubmitted,
            onChanged: onChanged,
            keyboardType: keyboardType,
            autocorrect: autocorrect,
            enableSuggestions: enableSuggestions,
            enableIMEPersonalizedLearning: enableIMEPersonalizedLearning,
            autofillHints: autofill ? const <String>[] : null,
            contextMenuBuilder: contextMenuBuilder ?? _platformMenu,
            minLines: minLines,
            maxLines: obscure ? 1 : maxLines,
            autofocus: autofocus,
            inputFormatters: inputFormatters,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 14,
              fontFamily: terminal ? 'monospace' : null,
            ),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              errorText: errorText,
              helperText: helperText,
              // Helper/hint son texto informativo: textSecondary para cumplir
              // WCAG AA 4.5:1; textDisabled (3.69:1) queda reservado a
              // controles realmente deshabilitados (spec 028 A-112).
              helperStyle: TextStyle(
                color: colors.textSecondary,
                fontSize: HermesType.subtitleSize,
                height: 1.35,
              ),
              errorStyle: TextStyle(
                color: colors.error,
                fontSize: HermesType.subtitleSize,
                height: 1.35,
              ),
              helperMaxLines: 3,
              hintStyle: TextStyle(
                color: colors.textSecondary,
                fontSize: HermesType.hintSize,
              ),
              filled: true,
              fillColor: colors.surfaceVariant.withValues(
                alpha: terminal ? 0.16 : 0.3,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 13,
              ),
              border: enabledInputBorder,
              enabledBorder: enabledInputBorder,
              focusedBorder: focusedInputBorder,
              suffixIcon: suffix,
            ),
          ),
        ),
      ],
    );
  }
}

/// The "Apple light" look of groups, panels and cards on a light page: a
/// translucent white body with a soft, diffuse shadow instead of a hard
/// border, and generous radii. Dark themes, high contrast and profiles that
/// outline their resting controls keep what they had.
///
/// The body is [HermesChrome.fill] (white at 88 %), which is lighter than the
/// tint it replaces, so every ink that read on it reads better; the shadow is
/// static and only the few groups of a section paint one (a card does not:
/// a long list never pays a blur per row).
abstract final class HermesSoftLight {
  static bool applies(BuildContext context) {
    // The glass layer gives dark pages the same look as light ones.
    if (HermesGlassLook.of(context) != null) return true;
    final components = Theme.of(context).hermesComponents.profile;
    return !HermesChrome.ofContext(context).dark &&
        !MediaQuery.highContrastOf(context) &&
        !components.border.outlinesRestingControls;
  }

  /// Body of a group or panel: the glass of the theme when it wears one, and
  /// where it does not (high contrast, a level that is off) the same solid
  /// body, derived from the page ([HermesBoxFill]): never a transparency.
  static Color fill(BuildContext context) =>
      HermesGlassLook.of(context)?.groupFill ??
      HermesBoxFill.of(Theme.of(context).hermes).group;

  /// Body of a card (solid, as [fill]).
  static Color cardFill(BuildContext context, HermesThemeColors colors) =>
      HermesGlassLook.of(context)?.cardFill ?? HermesBoxFill.of(colors).card;

  /// Whether the boxes of [context] take a solid body: every style but the
  /// ones that outline their resting controls (Outline), which stay flat on
  /// purpose.
  static bool solid(BuildContext context) {
    final theme = Theme.of(context);
    return !theme.hermes.outlined &&
        !theme.hermesComponents.profile.border.outlinesRestingControls;
  }

  /// The shadow of a group or panel: none on dark glass, where it would only
  /// be a hard edge.
  static List<BoxShadow>? shadowFor(
    BuildContext context,
    HermesThemeColors colors,
  ) {
    final glass = HermesGlassLook.of(context);
    return glass != null && glass.dark ? null : shadow(colors);
  }

  /// The soft shadow: the ink of the page at a few percent, wide and low.
  static List<BoxShadow> shadow(HermesThemeColors colors) => [
    BoxShadow(
      color: colors.textPrimary.withValues(alpha: 0.07),
      blurRadius: 24,
      spreadRadius: -6,
      offset: const Offset(0, 8),
    ),
    BoxShadow(
      color: colors.textPrimary.withValues(alpha: 0.04),
      blurRadius: 3,
      offset: const Offset(0, 1),
    ),
  ];

  /// A radius at least as generous as a card of the floating chrome's row.
  static double radius(double base) => math.max(base, HermesRadius.row);

  /// How opaque the resting card's body is.
  static const double cardOpacity = 0.78;

  /// How much of its hairline a card keeps.
  static const double cardLine = 0.30;
}

/// Contenedor único de una sección: UNA superficie sutil con las filas
/// separadas por líneas finas, en vez de una caja por elemento. Base del look
/// limpio (menos cajas, jerarquía por espaciado). Compartido por todas las
/// pantallas (Ajustes, Notificaciones, etc.).
class HermesGroup extends StatelessWidget {
  final List<Widget> children;
  const HermesGroup({required this.children, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final components = Theme.of(context).hermesComponents.profile;
    final rows = <Widget>[];
    // The divider between two rows: the least line that is seen on the
    // group's body in this theme ([HermesLines.dividerRatio]); 35 % of the
    // palette's divider sat near 1.1:1 on a charcoal body.
    final divider = HermesLines.of(colors).divider;
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 16,
            endIndent: 16,
            color: divider,
          ),
        );
      }
      rows.add(children[i]);
    }
    final glass = HermesGlassLook.of(context);
    final soft = HermesSoftLight.applies(context);
    final radius = soft
        ? HermesSoftLight.radius(components.shape.groupRadius)
        : components.shape.groupRadius;
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
    if (glass != null) {
      return HermesGlassLook.body(
        glass,
        BorderRadius.circular(radius),
        fill: glass.groupFill,
        lifted: true,
        child: column,
      );
    }
    return HermesSheen(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: HermesSoftLight.solid(context)
              ? HermesSoftLight.fill(context)
              : colors.surfaceVariant.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(radius),
          boxShadow: soft ? HermesSoftLight.shadowFor(context, colors) : null,
          gradient: glass == null
              ? null
              : HermesGlassLook.sheen(glass, fill: glass.groupFill),
          border: glass != null
              ? Border.all(color: glass.line)
              : components.border.outlinesRestingControls
              ? Border.all(
                  color: colors.divider,
                  width: components.border.width,
                )
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: column,
      ),
    );
  }
}

/// Toggle canónico de la app. Centraliza tipografía, espaciado y colores para
/// que ningún ajuste vuelva a dibujar un switch o una jerarquía distinta.
class HermesSwitchTile extends StatelessWidget {
  final Key? controlKey;
  final String title;
  final String? subtitle;
  final int? subtitleMaxLines;
  final Widget? secondary;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry contentPadding;
  final bool dense;

  const HermesSwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.controlKey,
    this.subtitle,
    this.subtitleMaxLines,
    this.secondary,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: 16),
    this.dense = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final enabled = onChanged != null;
    return SwitchListTile(
      key: controlKey,
      contentPadding: contentPadding,
      dense: dense,
      secondary: secondary,
      title: Text(
        title,
        style: Theme.of(context).textTheme.bodyLarge!.copyWith(
          color: enabled ? colors.textPrimary : colors.textDisabled,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.25,
          letterSpacing: 0,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: subtitleMaxLines,
              overflow: subtitleMaxLines == null ? null : TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                color: enabled ? colors.textSecondary : colors.textDisabled,
                fontSize: HermesType.subtitleSize,
                fontWeight: FontWeight.w400,
                height: 1.35,
                letterSpacing: 0,
              ),
            ),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// Panel suelto con la MISMA estética que [HermesGroup] para secciones de un
/// solo bloque que aún no son una lista de filas. Así nada desentona.
class HermesPanel extends StatelessWidget {
  final Widget child;
  const HermesPanel({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final components = Theme.of(context).hermesComponents.profile;
    final glass = HermesGlassLook.of(context);
    final soft = HermesSoftLight.applies(context);
    final radius = soft
        ? HermesSoftLight.radius(components.shape.groupRadius)
        : components.shape.groupRadius;
    if (glass != null) {
      return HermesGlassLook.body(
        glass,
        BorderRadius.circular(radius),
        fill: glass.groupFill,
        lifted: true,
        margin: const EdgeInsets.symmetric(vertical: 3),
        child: child,
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: HermesSoftLight.solid(context)
            ? HermesSoftLight.fill(context)
            : colors.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: soft ? HermesSoftLight.shadowFor(context, colors) : null,
        gradient: glass == null
            ? null
            : HermesGlassLook.sheen(glass, fill: glass.groupFill),
        border: glass != null
            ? Border.all(color: glass.line)
            : components.border.outlinesRestingControls
            ? Border.all(color: colors.divider, width: components.border.width)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// Fila de navegación: icono tenue (no acento) + título + subtítulo de hasta
/// dos líneas (tres con el texto agrandado) + chevron. Calmada y consistente,
/// para usar dentro de un [HermesGroup].
class HermesNavRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Current value, right-aligned before the chevron (one line).
  final String? value;

  /// Takes the chevron's place (a spinner while the row works); null keeps
  /// the chevron.
  final Widget? trailing;
  final VoidCallback onTap;

  /// The most of the row the value takes; the title has all the rest.
  static const double _valueShare = 0.4;

  const HermesNavRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.value,
    this.trailing,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: LayoutBuilder(
          builder: (context, row) => Row(
            children: [
              Icon(icon, size: 20, color: colors.textSecondary),
              const SizedBox(width: 15),
              // The value has its own width, next to the chevron, and the
              // title all the rest (two equal shares wrapped «Gestionar
              // instancias» and left «0 ›» floating mid-row).
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        // A subtitle is a sentence: two lines before it is
                        // cut (one line left «protección de crede…»).
                        maxLines: math.max(2, labelMaxLines(context, large: 3)),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: HermesType.subtitleSize,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: row.maxWidth * _valueShare,
                  ),
                  child: Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 13, color: colors.textSecondary),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              // The chevron says the row opens: an informative glyph, 3:1 on
              // the body (the disabled ink sat at ~2.3:1 on a dark card).
              trailing ??
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: colors.textTertiary,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Header de sección sobrio y legible, con acción opcional a la derecha.
class HermesSectionHeader extends StatelessWidget {
  final String label;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const HermesSectionHeader(
    this.label, {
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(2, 18, 2, 8),
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          // Minimalista: sin barrita ni acento decorativo. La jerarquía sale
          // del peso y del espaciado, no de microtipografía en mayúsculas.
          // TalkBack jumps between headings: a section is one.
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                HermesGlassLook.sectionText(context, label),
                semanticsLabel: HermesGlassLook.sectionSemantics(
                  context,
                  label,
                ),
                style: HermesGlassLook.sectionLabel(
                  context,
                  TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Icono dentro de un tile cuadrado redondeado con borde sutil — el motivo
/// recurrente de las referencias (sesiones, instancias, quick actions).
class HermesIconTile extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color? color;
  final bool active;

  const HermesIconTile(
    this.icon, {
    this.size = 36,
    this.color,
    this.active = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final fg = color ?? (active ? colors.accentHover : colors.textSecondary);
    // Minimalista: icono limpio sin caja (ni fondo ni borde). Conserva el
    // footprint `size` para no romper layouts; el estado activo se distingue
    // por el color, no por una cajita.
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Icon(icon, size: size * 0.62, color: fg),
      ),
    );
  }
}

/// Card estándar de la consola: surface + borde 1px + radius 10, con tap
/// opcional y glow ámbar opcional para elementos protagonistas.
class HermesCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool glow;
  final Color? borderColor;
  final Color? background;

  const HermesCard({
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin,
    this.onTap,
    this.onLongPress,
    this.glow = false,
    this.borderColor,
    this.background,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final components = Theme.of(context).hermesComponents.profile;
    final glass = background == null ? HermesGlassLook.of(context) : null;
    final soft = HermesSoftLight.applies(context) && background == null;
    final radius = BorderRadius.circular(
      soft
          ? HermesSoftLight.radius(components.shape.cardRadius)
          : components.shape.cardRadius,
    );
    Widget content = Padding(padding: padding, child: child);
    if (onTap != null || onLongPress != null) {
      // Rol de botón solo cuando la card es accionable (spec 028 A-103).
      content = Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            onLongPress: onLongPress,
            child: content,
          ),
        ),
      );
    }
    if (glass != null && borderColor == null && !glow) {
      return HermesGlassLook.body(
        glass,
        radius,
        fill: glass.cardFill,
        lifted: true,
        compact: true,
        margin: margin,
        child: content,
      );
    }
    final body =
        background ??
        (HermesSoftLight.solid(context)
            ? HermesSoftLight.cardFill(context, colors)
            : colors.surface);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: body,
        borderRadius: radius,
        gradient: glass == null
            ? null
            : HermesGlassLook.sheen(glass, fill: body),
        border: Border.all(
          color:
              borderColor ??
              glass?.line ??
              colors.divider.withValues(
                alpha: soft ? HermesSoftLight.cardLine : 0.55,
              ),
          width: components.border.width == 0 ? 1 : components.border.width,
        ),
        boxShadow: glow || components.effects.usesStaticShadow
            ? [
                BoxShadow(
                  color: glow
                      ? colors.accent.withValues(alpha: 0.07)
                      : Colors.black.withValues(alpha: 0.22),
                  blurRadius: glow ? 18 : 10,
                  spreadRadius: glow ? 1 : -3,
                  offset: Offset(0, components.elevation.resting),
                ),
              ]
            : null,
      ),
      child: ClipRRect(borderRadius: radius, child: content),
    );
  }
}

/// Badge outline uppercase estilo "LIVE / READ ONLY / OFFLINE" de las
/// referencias: sin relleno fuerte, solo borde + texto del color de estado.
class HermesBadge extends StatelessWidget {
  final String label;
  final Color color;
  final bool dot;

  const HermesBadge(
    this.label, {
    required this.color,
    this.dot = true,
    super.key,
  });

  /// How much of [color] tints the badge.
  static const double tint = 0.07;

  /// [color] made readable as the badge's 10 px label on its own tint: an
  /// accent badge on a light page fell to 2.6:1.
  static Color readableInk(Color color, HermesThemeColors colors) =>
      readableInkOnTint(color, color.withValues(alpha: tint), colors);

  @override
  Widget build(BuildContext context) {
    final spokenLabel = label.toUpperCase();
    final ink = readableInk(color, Theme.of(context).hermes);
    final radius = Theme.of(context).hermesComponents.profile.shape.chipRadius;
    return Semantics(
      label: spokenLabel,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: tint),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: color.withValues(alpha: 0.40),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dot) ...[
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  spokenLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    // 10px como base mínima legible de las pills (spec 028 A-113).
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                    color: ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Feedback de presión: escala sutil al pulsar (premium, no juguete).
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double? pressedScale;

  const PressableScale({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale,
    super.key,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final profile = Theme.of(context).hermesComponents.profile;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final motion = profile.motion.resolve(reducedMotion: reducedMotion);
    final curve = switch (profile.motion.curve) {
      ComponentMotionCurve.linear => Curves.linear,
      ComponentMotionCurve.easeOut => Curves.easeOut,
      ComponentMotionCurve.easeOutCubic => Curves.easeOutCubic,
    };
    // Rol de botón para TalkBack: el GestureDetector pelado leía solo el texto
    // interior sin anunciar "botón" ni el estado deshabilitado. Al ser la base
    // de todos los CTA del design system, esto arregla toda la app de golpe
    // (spec 028 A-103).
    return Semantics(
      button: true,
      enabled: widget.onTap != null || widget.onLongPress != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap == null
            ? null
            : () {
                HermesHaptics.selection();
                widget.onTap!();
              },
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _pressed ? (widget.pressedScale ?? motion.pressedScale) : 1.0,
          duration: Duration(milliseconds: motion.pressDurationMs),
          curve: curve,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Aparición suave (fade + leve desplazamiento) para secciones y cards.
/// [delayMs] permite escalonar la entrada de una lista.
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final int delayMs;
  final Duration duration;

  const FadeSlideIn({
    required this.child,
    this.delayMs = 0,
    this.duration = const Duration(milliseconds: 320),
    super.key,
  });

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final CurvedAnimation _curve;
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration);
    _curve = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    if (widget.delayMs == 0) {
      _ctrl.forward();
    } else {
      // A Timer (not Future.delayed) so leaving the screen first cancels it.
      _delay = Timer(Duration(milliseconds: widget.delayMs), () {
        if (mounted) _ctrl.forward();
      });
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      builder: (_, child) => Opacity(
        opacity: _curve.value,
        child: Transform.translate(
          offset: Offset(0, 7 * (1 - _curve.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// Any radius beyond half the height reads as a pill.
const double _pillRadius = 999;

/// Botón primario de la consola: ámbar, pill, glow suave, press scale.
class HermesPrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  const HermesPrimaryButton({
    required this.label,
    required this.onTap,
    this.icon,
    this.padding = const EdgeInsets.symmetric(vertical: 14),
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final components = Theme.of(context).hermesComponents.profile;
    final enabled = onTap != null;
    final terminal = components.id == ComponentProfiles.terminal.id;
    final enabledForeground = terminal ? colors.accentText : colors.onAccent;
    final fill = terminal
        ? colors.accent.withValues(alpha: enabled ? 0.11 : 0.035)
        : enabled
        ? colors.accent
        : colors.surfaceVariant;
    // A disabled label still reads (3:1) on the disabled fill.
    final foreground = enabled ? enabledForeground : colors.disabledInkOn(fill);
    return PressableScale(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 48),
        padding: padding,
        decoration: BoxDecoration(
          color: fill,
          // The terminal profile's square button is a pill; the others keep
          // their radius.
          borderRadius: BorderRadius.circular(
            terminal ? _pillRadius : components.shape.buttonRadius,
          ),
          border: !terminal && components.border.outlinesRestingControls
              ? Border.all(
                  color: enabled ? colors.accentHover : colors.divider,
                  width: components.border.width,
                )
              : null,
          boxShadow: enabled && components.effects.usesStaticShadow
              ? [
                  BoxShadow(
                    color: colors.accent.withValues(alpha: 0.22),
                    blurRadius: 12,
                    offset: Offset(0, components.elevation.resting),
                  ),
                ]
              : null,
        ),
        // FittedBox(scaleDown): si la etiqueta no cabe (mono + letterSpacing),
        // se reduce en vez de desbordar el botón. Row con mainAxisSize.min para
        // medir el contenido bajo las constraints sin acotar de FittedBox.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (terminal && enabled) ...[
                Container(width: 2, height: 18, color: colors.accent),
                const SizedBox(width: 9),
              ],
              if (icon != null) ...[
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: 9),
              ],
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: terminal ? FontWeight.w600 : FontWeight.w700,
                  letterSpacing: terminal ? 0.55 : 0.8,
                  fontFamily: terminal ? 'monospace' : null,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botón secundario: outline sutil, texto mono.
class HermesSecondaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? color;

  const HermesSecondaryButton({
    required this.label,
    required this.onTap,
    this.icon,
    this.color,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final components = Theme.of(context).hermesComponents.profile;
    final enabled = onTap != null;
    final terminal = components.id == ComponentProfiles.terminal.id;
    // Deshabilitado (onTap null) → texto/borde atenuados para que se lea como
    // inactivo (p.ej. acciones write bajo modo solo lectura).
    final fg = enabled
        ? (color ?? colors.textSecondary)
        : colors.textDisabled.withValues(alpha: 0.5);
    // On glass an active button has a body, a border and a short shadow; a
    // disabled one stays the faint outline it was.
    final glass = enabled && !terminal ? HermesGlassLook.of(context) : null;
    return PressableScale(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color:
              glass?.pieceFill ??
              (terminal ? fg.withValues(alpha: 0.045) : null),
          boxShadow: glass == null || glass.shadow == null
              ? null
              : [
                  BoxShadow(
                    color: glass.shadow!,
                    blurRadius: 8,
                    spreadRadius: -2,
                    offset: const Offset(0, 2),
                  ),
                ],
          borderRadius: BorderRadius.circular(
            terminal ? _pillRadius : components.shape.buttonRadius,
          ),
          border: glass != null
              ? Border.all(
                  color: glass.line,
                  width: components.border.emphasizedWidth,
                )
              : terminal
              ? Border.all(
                  color: fg.withValues(alpha: 0.55),
                  width: components.border.emphasizedWidth,
                )
              : Border.all(
                  color: fg.withValues(alpha: 0.35),
                  width: components.border.emphasizedWidth,
                ),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 7),
              ],
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: terminal ? 0.65 : 0.5,
                  fontFamily: terminal ? 'monospace' : null,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Banner informativo compacto — sustituye las cajas grises "muertas".
/// [tone] tiñe el borde y el icono; el texto permanece legible y discreto.
class HermesInfoBanner extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color? tone;

  const HermesInfoBanner(
    this.text, {
    this.icon = Icons.info_outline,
    this.tone,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final t = tone ?? colors.accent;
    final glass = HermesGlassLook.of(context);
    final radius = BorderRadius.circular(14);
    final notice = Material(
      key: const ValueKey('hermes-info-banner-surface'),
      color: glass == null
          ? Color.alphaBlend(
              t.withValues(alpha: 0.055),
              HermesSoftLight.solid(context)
                  ? HermesSoftLight.cardFill(context, colors)
                  : colors.surface,
            )
          : Color.alphaBlend(t.withValues(alpha: 0.06), glass.cardFill),
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shadowColor: glass?.shadow ?? Colors.black.withValues(alpha: 0.32),
      // On glass the contour is the box's own, in two tones
      // ([HermesBoxEdges]); the Material keeps the elevation's shadow.
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: glass == null
            ? BorderSide(color: t.withValues(alpha: 0.24))
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: t.withValues(alpha: 0.88)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: HermesType.subtitleSize,
                  height: 1.42,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return SizedBox(
      width: double.infinity,
      child: glass == null
          ? notice
          : HermesBoxEdges(glass: glass, radius: radius, child: notice),
    );
  }
}
