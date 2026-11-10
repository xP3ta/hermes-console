import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/gel_surface.dart';
import '../design/liquid_glass.dart';
import '../design/glass_strip.dart';
import '../design/smoked_glass.dart';
import '../design/tokens.dart' show HermesChrome, HermesGel;
import '../models/dock_config.dart';
import '../theme/app_theme.dart';
import '../theme/box_fill.dart' show HermesPageTint;
import '../theme/lines.dart';
import '../theme/theme_contrast.dart';
import '../theme/hermes_tokens.dart' show HermesIcon, HermesSize;
import 'frosted_backdrop.dart';

/// Metadatos visuales de un elemento de catálogo, compartidos por el dock
/// (`dock.dart`, un único componente para los dos perfiles) y la lista de la
/// pantalla de personalización, para que ambos pinten siempre el mismo
/// icono/etiqueta para un mismo id.
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
  DockItemId.agents: DockItemVisual(
    icon: Icons.terminal_outlined,
    selectedIcon: Icons.terminal_rounded,
  ),
};

DockItemVisual dockItemVisual(DockItemId id) =>
    _dockItemVisuals[id] ?? const DockItemVisual(icon: Icons.circle_outlined);

/// Icono del elemento contextual "Atrás": no vive en el catálogo (ver
/// [DockItemId]), así que no tiene entrada en [dockItemVisual].
const IconData dockBackIcon = Icons.arrow_back_rounded;

/// Qué elemento se pinta con el color de acento. Es una propiedad del
/// catálogo, no de la pantalla: vive aquí (y no en lo que cada pantalla le
/// pasa al dock) para que ningún contexto pueda decidir por su cuenta que
/// otro elemento es el destacado y volver a divergir del resto.
bool dockItemIsAccent(DockItemId id) => id == DockItemId.create;

/// Señal correcta para mostrar "Atrás" en el dock flotante: esta pantalla es
/// en sí misma una subpantalla (se llegó a ella con un push), no si algo se
/// apiló POR ENCIMA de ella. Lo segundo (rastreado antes con `RouteAware`
/// vía `didPushNext`/`didPopNext` en cada pantalla que integraba el dock)
/// solo se vuelve true justo cuando la pantalla queda tapada por la nueva
/// ruta — momento en el que su propio dock, con "Atrás" ya activado, es
/// invisible para el usuario. `Route.isFirst` sobre la ruta de ESTA
/// pantalla es la señal correcta y no necesita observar el Navigator en
/// absoluto (bug confirmado en dispositivo real en `GeneralDockShell`;
/// compartido aquí para que `MissionControlScreen`/otras pantallas con dock
/// no repitan el mismo criterio, o lo desincronicen).
///
/// Se lee con el aspecto `isFirst` y no con `ModalRoute.of(context)`: este
/// último suscribe a TODO el estado de la ruta (`isCurrent` cambia justo al
/// empujar otra pantalla encima o al volver) y reconstruía la pantalla entera
/// en el primer frame de cada transición del dock.
bool dockShowsBack(BuildContext context) =>
    ModalRoute.isFirstOf(context) != true;

String dockItemLabel(Strings strings, DockItemId id) => switch (id) {
  DockItemId.bots => strings.missionBotsLabel,
  DockItemId.create => strings.missionCreateLabel,
  DockItemId.home => strings.dockHomeLabel,
  DockItemId.settings => strings.dockSettingsLabel,
  // Reutilizan las etiquetas ya localizadas (ES/EN) del drawer para las
  // mismas pantallas, en vez de duplicar strings nuevas para el mismo
  // destino.
  DockItemId.cron => strings.drawerCron,
  DockItemId.tasks => strings.drawerKanban,
  DockItemId.sessions => strings.drawerSessions,
  DockItemId.agents => strings.navAgents,
};

String dockItemCompactLabel(Strings strings, DockItemId id) => switch (id) {
  DockItemId.cron => strings.dockCronLabel,
  DockItemId.sessions => strings.dockSessionsLabel,
  _ => dockItemLabel(strings, id),
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
  final blurSigma = transparency > 0 ? lerpDouble(6, 26, transparency)! : 0.0;

  // Every lift towards white keeps the page's hue on a tinted page
  // ([HermesPageTint.keepHue]); a neutral page gets the plain mix.
  final page = colors.background;
  Color lighten(Color from, double amount) => HermesPageTint.keepHue(
    Color.lerp(from, Colors.white, amount)!,
    of: from,
    page: page,
  );
  var background = lighten(colors.surface, transparency * 0.22);
  List<BoxShadow> shadows;
  var lift = 0.0;

  switch (style.depth) {
    case DockDepth.flat:
      shadows = const [];
    case DockDepth.elevated:
      // Un `BoxShadow` negro puro sobre el fondo ya casi negro de la app
      // (`colors.background`, #0B0B0B) es imperceptible por sí solo —
      // confirmado en dispositivo real ("no me da sensación de nada").
      // Igual que "Flotante" más abajo, parte del contraste tiene que venir
      // de aclarar la superficie/borde, aquí a la mitad de intensidad para
      // que "Elevada" quede claramente entre "Plana" y "Flotante" en vez de
      // fundirse con "Plana".
      background = lighten(background, 0.015);
      shadows = [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ];
    case DockDepth.floating:
      // Superficie/borde ligeramente más claros por encima de lo que ya
      // aporta la transparencia: en tema oscuro la sombra por sí sola apenas
      // se distingue, así que la profundidad "Flotante" también se lee por
      // contraste de superficie, no solo por sombra.
      background = lighten(background, 0.03);
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

  final fill = background.withValues(alpha: background.a * bgAlpha);
  // The border is the contour of the bar: the page's light (or the main
  // ink on a light page) raised until the edge of the bar reads against the
  // page at the edge ratio of a floating piece (3:1). The palette's divider lightened towards
  // white vanished on every light page and sat near 1.5:1 on the dark ones.
  final border = HermesLines.of(
    colors,
  ).edgeOn(ThemeContrast.composite(fill, page));
  return DockVisual(
    background: fill,
    border: border,
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
///
/// With [selectedIndex] set, the bar paints a single active indicator pill
/// beneath that slot and slides it to the new slot when the selection
/// changes (tiles should then pass `selectionBackground: false`). A thin
/// light hairline along the top edge completes the glass look.
class DockBar extends StatelessWidget {
  final DockStyle style;
  final List<Widget> children;

  /// Slot (index into [children]) under which the sliding active indicator
  /// sits; `null` paints no indicator.
  final int? selectedIndex;

  /// [Axis.vertical] lays the same tiles out as a navigation rail (tablets,
  /// see `Responsive.usesRail`); the default is the bottom bar.
  final Axis axis;

  /// Colour of the active indicator; the palette's `surfaceVariant` by
  /// default.
  final Color? indicatorColor;

  const DockBar({
    required this.style,
    required this.children,
    this.selectedIndex,
    this.axis = Axis.horizontal,
    this.indicatorColor,
    super.key,
  });

  /// Height of the bottom bar: the 48 dp touch target of every tile.
  static const barHeight = HermesSize.tap;

  /// Width of the vertical rail form and height of each of its slots.
  static const railWidth = 72.0;
  static const railSlotHeight = 60.0;

  /// Duration of the indicator slide between slots.
  static const indicatorDuration = Duration(milliseconds: 220);

  /// Widest the active indicator pill gets inside a slot.
  static const indicatorMaxWidth = 64.0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final visual = resolveDockVisual(colors, style);
    final tone = _dockBarTone(colors, visual);
    final radius = BorderRadius.circular(visual.outerRadius);
    final hairlineInset = math.min(visual.outerRadius, barHeight / 2) / 2;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final index = selectedIndex;
    if (axis == Axis.vertical) {
      return _buildRail(context, visual, radius, reduceMotion, index);
    }
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    Widget surface(BuildContext context, Color fill) => DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: visual.border),
        borderRadius: radius,
        boxShadow: HermesGlassStrip.of(context)?.tone != null
            ? null
            : visual.shadows,
      ),
      child: SizedBox(
        height: barHeight,
        child: Stack(
          children: [
            // Top hairline light: a soft highlight that fades out towards
            // the rounded corners, like light catching the edge of glass.
            // A pill's radius is cut to half the bar's height when painted;
            // the hairline keeps clear of that corner, not of the token.
            Positioned(
              key: const ValueKey('dock-top-hairline'),
              top: 0,
              left: hairlineInset,
              right: hairlineInset,
              height: 1,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0),
                        Colors.white.withValues(alpha: 0.16),
                        Colors.white.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // The gel's sheen and rims over the glass, under the tiles.
            Positioned.fill(
              child: IgnorePointer(
                child: HermesGelSurface(
                  shape: RoundedRectangleBorder(borderRadius: radius),
                  pressable: false,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            Positioned.fill(
              child: Padding(
                // Solo inset horizontal: el vertical se deja a 0 para que cada
                // elemento pueda ocupar los 48dp de alto completos (objetivo
                // táctil mínimo de accesibilidad) en vez de encogerse a ~40dp.
                // `stretch` fuerza esa altura completa en cada item de la fila.
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: index == null || index < 0 || index >= children.length
                    ? row
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final slotWidth =
                              constraints.maxWidth / children.length;
                          final width = (slotWidth - 8).clamp(
                            0.0,
                            indicatorMaxWidth,
                          );
                          return Stack(
                            children: [
                              AnimatedPositioned(
                                key: const ValueKey('dock-active-indicator'),
                                duration: reduceMotion
                                    ? Duration.zero
                                    : indicatorDuration,
                                curve: Curves.easeOutCubic,
                                top: 4,
                                bottom: 4,
                                left:
                                    slotWidth * index + (slotWidth - width) / 2,
                                width: width,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: HermesGel.glow(
                                      indicatorColor ?? colors.accent,
                                      BorderRadius.circular(visual.innerRadius),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned.fill(child: row),
                            ],
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
    return FrostedBackdrop(
      liquid: HermesLiquid.dock,
      tone: tone,
      toneInks: HermesSmokedGlass.dockInks(colors),
      zone: FrostedZone.bottom,
      sigma: visual.blurSigma,
      tint: visual.background,
      borderRadius: radius,
      builder: surface,
    );
  }

  Widget _buildRail(
    BuildContext context,
    DockVisual visual,
    BorderRadius radius,
    bool reduceMotion,
    int? index,
  ) {
    final colors = Theme.of(context).hermes;
    final tone = _dockBarTone(colors, visual);
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    Widget surface(BuildContext context, Color fill) => DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: visual.border),
        borderRadius: radius,
        boxShadow: HermesGlassStrip.of(context)?.tone != null
            ? null
            : visual.shadows,
      ),
      child: SizedBox(
        width: railWidth,
        height: railSlotHeight * children.length + 8,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Stack(
            children: [
              if (index != null && index >= 0 && index < children.length)
                AnimatedPositioned(
                  key: const ValueKey('dock-active-indicator'),
                  duration: reduceMotion ? Duration.zero : indicatorDuration,
                  curve: Curves.easeOutCubic,
                  left: 6,
                  right: 6,
                  top: railSlotHeight * index + 4,
                  height: railSlotHeight - 8,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: HermesGel.glow(
                        indicatorColor ?? colors.accent,
                        BorderRadius.circular(visual.innerRadius),
                      ),
                    ),
                  ),
                ),
              Positioned.fill(child: column),
            ],
          ),
        ),
      ),
    );
    return FrostedBackdrop(
      liquid: HermesLiquid.dock,
      tone: tone,
      toneInks: HermesSmokedGlass.dockInks(colors),
      zone: FrostedZone.bottom,
      sigma: visual.blurSigma,
      tint: visual.background,
      borderRadius: radius,
      builder: surface,
    );
  }

  HermesSmokedGlass? _dockBarTone(HermesThemeColors colors, DockVisual visual) {
    if (visual.background.a >= 1 || visual.blurSigma <= 0) return null;
    final chrome = HermesChrome.of(colors);
    final tone = HermesSmokedGlass.dockOf(
      chrome,
    ).withVeilFloor(visual.background.a);
    if (!tone.readsFor(colors, HermesSmokedGlass.dockInks(colors))) return null;
    // Classic/rail tiles retain their existing inks and actual indicator.
    // If an overlay cannot keep them readable, retain the previous material.
    for (final overlay in [
      indicatorColor ?? colors.surfaceVariant,
      colors.accent.withValues(alpha: .14),
      colors.accent.withValues(alpha: .26),
    ]) {
      final floor = math.max(
        3.05,
        math.min(
          4.5,
          ThemeContrast.ratio(
            colors.accentText,
            ThemeContrast.composite(overlay, chrome.opaque),
          ),
        ),
      );
      if (tone.worstRatio(colors.accentText, chrome, over: overlay) < floor) {
        return null;
      }
    }
    return tone;
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
  final String? compactLabel;
  final bool selected;
  final bool accent;
  final double innerRadius;
  final bool compact;
  final bool? toggled;
  final VoidCallback? onTap;
  final FocusNode? focusNode;

  /// Whether a selected tile paints its own background pill. The live dock
  /// sets this to false because [DockBar] paints one sliding indicator.
  final bool selectionBackground;

  /// Only the icon, no label in any state (QA 9709, the gesture dock's
  /// rail). The label stays for a screen reader and the tooltip.
  final bool iconOnly;

  /// Colour of an item that is neither selected nor the accent one; the
  /// palette's `textSecondary` by default.
  final Color? idleColor;

  const DockItemTile({
    required this.icon,
    required this.label,
    this.compactLabel,
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
    this.selectionBackground = true,
    this.iconOnly = false,
    this.idleColor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = accent
        ? colors.accentText
        : selected
        ? colors.textPrimary
        : idleColor ?? colors.textSecondary;
    // The active destination gets an accent icon over its indicator pill.
    final iconColor = selected ? colors.accentText : color;
    // The "+" stays a same-size tile; a faint accent pill marks it instead
    // of a bigger or elevated button.
    final background = accent
        ? colors.accent.withValues(alpha: toggled == true ? 0.26 : 0.14)
        : selected && selectionBackground
        ? colors.surfaceVariant
        : null;
    final displayIcon = selected && selectedIcon != null ? selectedIcon! : icon;
    return Expanded(
      child: Semantics(
        key: semanticsKey,
        button: true,
        enabled: onTap != null,
        selected: selected,
        toggled: toggled,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        child: Tooltip(
          message: label,
          child: _DockPressScale(
            enabled: onTap != null,
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
                    color: background,
                    borderRadius: BorderRadius.circular(innerRadius),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: compact ? 4 : 6,
                    ),
                    // `compact` (el dock real, ver dock.dart) apila el
                    // icono arriba y la etiqueta
                    // debajo: con 4+ items visibles, icono+etiqueta EN LÍNEA no
                    // cabe y Flutter corta el texto con "..." (confirmado por
                    // captura real del dispositivo). Apilar en vertical, no
                    // ocultar la etiqueta, resuelve lo mismo sin perder el
                    // texto — sigue con maxLines: 1 + ellipsis por si algún
                    // idioma/tamaño de fuente sigue sin caber en el ancho del
                    // segmento. El modo en línea (usado hoy solo por la vista
                    // previa de Ajustes › Dock, con más espacio disponible) se
                    // mantiene igual que antes.
                    child: iconOnly
                        ? Icon(
                            displayIcon,
                            size: HermesIcon.xl,
                            color: iconColor,
                          )
                        : compact
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(displayIcon, size: 21, color: iconColor),
                              const SizedBox(height: 2),
                              // Sin escalar con la fuente del sistema: el
                              // icono de encima tampoco escala, y a 2x el
                              // texto ya no cabe en la altura fija del tile
                              // (48dp) apilado bajo un icono de 21dp — se
                              // confirmó overflow real en los tests a 2.0x.
                              // La etiqueta sigue siendo accesible sin
                              // recorte propio vía Tooltip/Semantics.
                              Text(
                                compactLabel ?? label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textScaler: TextScaler.noScaling,
                                style: TextStyle(
                                  color: color,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  height: 1,
                                ),
                              ),
                            ],
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(displayIcon, size: 21, color: iconColor),
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
                          ),
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

/// Springy press feedback for a dock tile: shrinks the tile slightly while
/// a pointer is down and springs back with a small overshoot on release.
/// Uses a raw [Listener] so it never competes with the tile's own gestures,
/// and only animates on press/release (no idle ticker). With reduced motion
/// the tile never scales.
class _DockPressScale extends StatefulWidget {
  final bool enabled;
  final Widget child;

  const _DockPressScale({required this.enabled, required this.child});

  @override
  State<_DockPressScale> createState() => _DockPressScaleState();
}

class _DockPressScaleState extends State<_DockPressScale> {
  bool _pressed = false;

  void _set(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final pressed = _pressed && widget.enabled && !reduceMotion;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        key: const ValueKey('dock-press-scale'),
        scale: pressed ? dockPressedScale : 1,
        duration: reduceMotion
            ? Duration.zero
            : Duration(milliseconds: pressed ? 90 : 320),
        curve: pressed ? Curves.easeOutCubic : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}

/// Scale a dock tile shrinks to while pressed.
const double dockPressedScale = 0.92;
