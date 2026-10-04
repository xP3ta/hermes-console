// Design system de Hermes Console — componentes base compartidos.
//
// Lenguaje visual (docs/design/): charcoal casi negro, bordes 1px sutiles,
// ámbar con moderación, iconos dentro de tiles cuadrados redondeados,
// headers de sección uppercase mono con tick ámbar, badges outline.
//
// Regla de renderizado: nunca combinar borderRadius con un Border no
// uniforme de colores distintos (ver AccentCard). Todos los bordes aquí
// son uniformes.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/component_profile.dart';

/// Escala de radios canónica de la consola. Usar SOLO estos tamaños para no
/// volver al caos de radios sueltos (había 14 valores distintos por el código).
///  - [chip]  chips/píldoras pequeñas, swatches.
///  - [field] inputs y elementos de formulario.
///  - [card]  tarjetas y filas agrupadas.
///  - [group] superficies de sección (grupos/paneles, hojas).
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
  final int maxLines;
  final bool autofocus;
  final List<TextInputFormatter>? inputFormatters;
  final String? errorText;
  final String? helperText;

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
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final components = Theme.of(context).hermesComponents.profile;
    final fieldRadius = components.shape.fieldRadius;
    final terminal = components.id == ComponentProfiles.terminal.id;
    final restingBorder = components.border.outlinesRestingControls
        ? BorderSide(color: colors.divider, width: components.border.width)
        : BorderSide.none;
    final InputBorder enabledInputBorder = terminal
        ? UnderlineInputBorder(
            borderSide: BorderSide(
              color: colors.divider,
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
            controller: controller,
            obscureText: obscure,
            onSubmitted: onSubmitted,
            onChanged: onChanged,
            keyboardType: keyboardType,
            autocorrect: autocorrect,
            enableSuggestions: enableSuggestions,
            enableIMEPersonalizedLearning: enableIMEPersonalizedLearning,
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
                fontSize: 12.5,
                height: 1.35,
              ),
              errorStyle: TextStyle(
                color: colors.error,
                fontSize: 12.5,
                height: 1.35,
              ),
              helperMaxLines: 3,
              hintStyle: TextStyle(color: colors.textSecondary, fontSize: 13.5),
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
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 16,
            endIndent: 16,
            color: colors.divider.withValues(alpha: 0.35),
          ),
        );
      }
      rows.add(children[i]);
    }
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(components.shape.groupRadius),
        border: components.border.outlinesRestingControls
            ? Border.all(color: colors.divider, width: components.border.width)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
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
        style: TextStyle(
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
              style: TextStyle(
                color: enabled ? colors.textSecondary : colors.textDisabled,
                fontSize: 12,
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
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(components.shape.groupRadius),
        border: components.border.outlinesRestingControls
            ? Border.all(color: colors.divider, width: components.border.width)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// Fila de navegación: icono tenue (no acento) + título + subtítulo a UNA línea
/// + chevron. Calmada y consistente, para usar dentro de un [HermesGroup].
class HermesNavRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  const HermesNavRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.textSecondary),
            const SizedBox(width: 15),
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 18, color: colors.textDisabled),
          ],
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
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
                color: colors.textSecondary,
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
    final radius = BorderRadius.circular(components.shape.cardRadius);
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
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: background ?? colors.surface,
        borderRadius: radius,
        border: Border.all(
          color: borderColor ?? colors.divider.withValues(alpha: 0.55),
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

  @override
  Widget build(BuildContext context) {
    final spokenLabel = label.toUpperCase();
    final radius = Theme.of(context).hermesComponents.profile.shape.chipRadius;
    return Semantics(
      label: spokenLabel,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.07),
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
                    color: color,
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
                HapticFeedback.selectionClick();
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

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration);
    _curve = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    if (widget.delayMs == 0) {
      _ctrl.forward();
    } else {
      Future.delayed(Duration(milliseconds: widget.delayMs), () {
        if (mounted) _ctrl.forward();
      });
    }
  }

  @override
  void dispose() {
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

/// Botón primario de la consola: ámbar, radius 10, glow suave, press scale.
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
    final enabledForeground = terminal ? colors.accentHover : colors.onAccent;
    return PressableScale(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 48),
        padding: padding,
        decoration: BoxDecoration(
          color: terminal
              ? colors.accent.withValues(alpha: enabled ? 0.11 : 0.035)
              : enabled
              ? colors.accent
              : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(components.shape.buttonRadius),
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
                Icon(
                  icon,
                  size: 18,
                  color: enabled ? enabledForeground : colors.textDisabled,
                ),
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
                  color: enabled ? enabledForeground : colors.textDisabled,
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
    return PressableScale(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: terminal ? fg.withValues(alpha: 0.045) : null,
          borderRadius: terminal
              ? BorderRadius.zero
              : BorderRadius.circular(components.shape.buttonRadius),
          border: terminal
              ? Border(
                  bottom: BorderSide(
                    color: fg.withValues(alpha: 0.55),
                    width: components.border.emphasizedWidth,
                  ),
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
    return SizedBox(
      width: double.infinity,
      child: Material(
        key: const ValueKey('hermes-info-banner-surface'),
        color: Color.alphaBlend(t.withValues(alpha: 0.055), colors.surface),
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.32),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: t.withValues(alpha: 0.24)),
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
                    fontSize: 12,
                    height: 1.42,
                    color: colors.textSecondary,
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
