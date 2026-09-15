import 'dart:ui';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/dock_config.dart';
import '../theme/app_theme.dart';

/// Metadatos visuales de un elemento de catálogo, compartidos por el dock de
/// Bots, el de General y la lista de la pantalla de personalización, para
/// que los tres pinten siempre el mismo icono/etiqueta para un mismo id.
class DockItemVisual {
  final IconData icon;
  final IconData? selectedIcon;

  const DockItemVisual({required this.icon, this.selectedIcon});
}

const Map<DockItemId, DockItemVisual> _dockItemVisuals = {
  DockItemId.bots: DockItemVisual(
    icon: Icons.smart_toy_outlined,
    selectedIcon: Icons.smart_toy_rounded,
  ),
  DockItemId.work: DockItemVisual(
    icon: Icons.work_outline_rounded,
    selectedIcon: Icons.work_rounded,
  ),
  DockItemId.create: DockItemVisual(icon: Icons.add_rounded),
  DockItemId.home: DockItemVisual(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_rounded,
  ),
  DockItemId.settings: DockItemVisual(
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings_rounded,
  ),
  // Accesos directos opcionales (ocultos por defecto en ambos perfiles):
  // mismo icono que ya usa HermesDrawer para las mismas pantallas.
  DockItemId.cron: DockItemVisual(icon: Icons.schedule_outlined),
  DockItemId.tasks: DockItemVisual(icon: Icons.view_kanban_outlined),
  DockItemId.sessions: DockItemVisual(icon: Icons.forum_outlined),
  DockItemId.tools: DockItemVisual(icon: Icons.widgets_outlined),
};

DockItemVisual dockItemVisual(DockItemId id) =>
    _dockItemVisuals[id] ?? const DockItemVisual(icon: Icons.circle_outlined);

/// Icono del elemento contextual "Atrás": no vive en el catálogo (ver
/// [DockItemId]), así que no tiene entrada en [dockItemVisual].
const IconData dockBackIcon = Icons.arrow_back_rounded;

String dockItemLabel(Strings strings, DockItemId id) => switch (id) {
  DockItemId.bots => strings.missionBotsLabel,
  DockItemId.work => strings.missionWorkLabel,
  DockItemId.create => strings.missionCreateLabel,
  DockItemId.home => strings.dockHomeLabel,
  DockItemId.settings => strings.dockSettingsLabel,
  // Reutilizan las etiquetas ya localizadas (ES/EN) del drawer para las
  // mismas pantallas, en vez de duplicar strings nuevas para el mismo
  // destino.
  DockItemId.cron => strings.drawerCron,
  DockItemId.tasks => strings.drawerKanban,
  DockItemId.sessions => strings.drawerSessions,
  DockItemId.tools => strings.drawerTools,
};

/// Valores resueltos de un [DockStyle] listos para pintar: colores,
/// radios, sombras y desenfoque. Centraliza la traducción "ajuste →
/// píxeles" para que el dock de Bots y el de General (y la vista previa de
/// Ajustes › Dock) pinten exactamente lo mismo a partir del mismo estilo.
class DockVisual {
  final Color background;
  final Color border;
  final double outerRadius;
  final double innerRadius;
  final List<BoxShadow> shadows;
  final double blurSigma;

  /// Separación extra respecto al borde inferior que añade la profundidad
  /// "Flotante" (el dock se despega un poco más del filo de la pantalla).
  final double lift;

  const DockVisual({
    required this.background,
    required this.border,
    required this.outerRadius,
    required this.innerRadius,
    required this.shadows,
    required this.blurSigma,
    required this.lift,
  });
}

DockVisual resolveDockVisual(HermesThemeColors colors, DockStyle style) {
  final transparency = style.transparency.clamp(0.0, 1.0);

  // `colors.surface` (#141414) y el fondo real detrás del dock
  // (`colors.background`, #0B0B0B) son dos negros casi idénticos: bajar solo
  // el alfa de un color ya casi negro sobre un fondo ya casi negro es
  // imperceptible (confirmado leyendo los tokens de `app_theme.dart`, no
  // solo esta fórmula) — el dock se "funde" con el fondo en vez de dejar
  // ver a través. Para que el ajuste se note en toda pantalla real (que
  // rara vez tiene un área clara justo detrás del dock), el efecto de
  // "cristal esmerilado" se construye con tres señales a la vez, todas
  // proporcionales a `transparency` en vez de un salto fijo:
  //  1. el color base se aclara hacia blanco (un velo de cristal, no una
  //     ventana perfecta), en vez de solo perder opacidad;
  //  2. nunca cae por debajo de un suelo de opacidad, así el dock conserva
  //     silueta propia incluso al máximo;
  //  3. el desenfoque de fondo escala con el valor en vez de un sigma fijo
  //     de 14, y se añade un resplandor de borde blanco muy sutil que crece
  //     con la transparencia, que es lo que de verdad se lee como "borde de
  //     cristal" contra un fondo oscuro sin contraste detrás.
  final bgAlpha = lerpDouble(1.0, 0.32, transparency)!;
  final borderAlpha = lerpDouble(0.62, 0.95, transparency)!;
  final blurSigma = transparency > 0 ? lerpDouble(6, 26, transparency)! : 0.0;

  var background = Color.lerp(colors.surface, Colors.white, transparency * 0.22)!;
  var border = Color.lerp(colors.divider, Colors.white, transparency * 0.4)!;
  List<BoxShadow> shadows;
  var lift = 0.0;

  switch (style.depth) {
    case DockDepth.flat:
      shadows = const [];
    case DockDepth.elevated:
      shadows = [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.28),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ];
    case DockDepth.floating:
      // Superficie/borde ligeramente más claros por encima de lo que ya
      // aporta la transparencia: en tema oscuro la sombra por sí sola apenas
      // se distingue, así que la profundidad "Flotante" también se lee por
      // contraste de superficie, no solo por sombra.
      background = Color.lerp(background, Colors.white, 0.03)!;
      border = Color.lerp(border, Colors.white, 0.06)!;
      lift = 6;
      shadows = [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.7),
          blurRadius: 40,
          offset: const Offset(0, 16),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.45),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ];
  }

  if (transparency > 0) {
    // Resplandor de borde muy sutil, independiente de la profundidad: es la
    // señal que de verdad vende "cristal esmerilado" cuando lo que hay
    // detrás del dock es oscuro y sin contraste (el caso típico en esta
    // app), donde el relleno aclarado y el blur por sí solos siguen siendo
    // discretos.
    shadows = [
      ...shadows,
      BoxShadow(
        color: Colors.white.withValues(alpha: 0.05 + transparency * 0.09),
        blurRadius: 18 + transparency * 14,
        spreadRadius: -2,
      ),
    ];
  }

  return DockVisual(
    background: background.withValues(alpha: background.a * bgAlpha),
    border: border.withValues(alpha: border.a * borderAlpha),
    outerRadius: style.borderShape.outerRadius,
    innerRadius: style.borderShape.innerRadius,
    shadows: shadows,
    blurSigma: blurSigma,
    lift: lift,
  );
}

/// Contenedor plano de la barra del dock: aplica [DockVisual] (color, borde,
/// radio, sombra y, si hay transparencia, desenfoque de fondo) a [children]
/// dispuestos en una fila a ras de borde a borde.
class DockBar extends StatelessWidget {
  final DockStyle style;
  final List<Widget> children;

  const DockBar({required this.style, required this.children, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final visual = resolveDockVisual(colors, style);
    final radius = BorderRadius.circular(visual.outerRadius);
    Widget bar = DecoratedBox(
      decoration: BoxDecoration(
        color: visual.background,
        border: Border.all(color: visual.border),
        borderRadius: radius,
        boxShadow: visual.shadows,
      ),
      child: SizedBox(
        height: 48,
        child: Padding(
          // Solo inset horizontal: el vertical se deja a 0 para que cada
          // elemento pueda ocupar los 48dp de alto completos (objetivo
          // táctil mínimo de accesibilidad) en vez de encogerse a ~40dp.
          // `stretch` fuerza esa altura completa en cada item de la fila.
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
    if (visual.blurSigma > 0) {
      bar = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: visual.blurSigma,
            sigmaY: visual.blurSigma,
          ),
          child: bar,
        ),
      );
    }
    return bar;
  }
}

/// Un elemento dentro de la barra: icono + etiqueta, a peso igual con el
/// resto (sin FAB elevado ni tamaños especiales). El elemento de acento
/// (el "+") se distingue solo por color, nunca por tamaño o elevación.
class DockItemTile extends StatelessWidget {
  final Key? controlKey;
  final Key? semanticsKey;
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final bool selected;
  final bool accent;
  final double innerRadius;
  final bool compact;
  final bool? toggled;
  final VoidCallback? onTap;
  final FocusNode? focusNode;

  const DockItemTile({
    required this.icon,
    required this.label,
    required this.innerRadius,
    this.controlKey,
    this.semanticsKey,
    this.selectedIcon,
    this.selected = false,
    this.accent = false,
    this.compact = false,
    this.toggled,
    this.onTap,
    this.focusNode,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = accent
        ? colors.accentText
        : selected
        ? colors.textPrimary
        : colors.textSecondary;
    final displayIcon = selected && selectedIcon != null ? selectedIcon! : icon;
    return Expanded(
      child: Semantics(
        key: semanticsKey,
        button: true,
        selected: selected,
        toggled: toggled,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        child: Tooltip(
          message: label,
          child: InkWell(
            key: controlKey,
            focusNode: focusNode,
            onTap: onTap,
            borderRadius: BorderRadius.circular(innerRadius),
            // El fondo del item seleccionado es una píldora AJUSTADA al
            // contenido (Center le da al DecoratedBox constraints sueltas en
            // vez de las tight que fuerza el `Expanded` padre), con un
            // margen interno consistente vía Padding. Antes el DecoratedBox
            // heredaba el ancho/alto completo del segmento del Row (48dp de
            // alto, ancho = lo que le tocara de `Expanded`), pintando un
            // bloque desproporcionado en vez de una píldora flotante
            // (confirmado por captura real del dispositivo).
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected && !accent ? colors.surfaceVariant : null,
                  borderRadius: BorderRadius.circular(innerRadius),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(displayIcon, size: 21, color: color),
                      if (!compact) ...[
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
