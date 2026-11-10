// The light behind the glass.
//
// Glass only shows when there is something to see through it: over a flat
// page the blur and the refraction of the header, the dock and the composer
// have nothing to bend. This paints, under every page, the page colour with
// one faint glow of that same colour (a few per cent lighter on a dark page,
// darker on a light one): nearly flat, with some depth. With the glass off,
// in high contrast and in the Outline style the page is completely flat.
//
// It is one layer under the route (a page and its own light move together
// when the route does), static, and drawn once: a scroll never repaints it.
// It leaves a plain page where the system asks for high contrast and in the
// terminal themes, whose look is flat on purpose.
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/glass_look.dart';
import '../theme/theme_contrast.dart';
import 'box_edge.dart';
import 'tokens.dart' show HermesGel, HermesType;

/// Whether the app paints its pages over the ambient light at all.
///
/// A switch, not a constant: a test that photographs a screen on its own
/// page colour turns it off, and a setting can offer it later.
abstract final class HermesAmbient {
  static bool enabled = true;
}

/// The glass the surfaces of [context] wear, or null when they wear none.
///
/// The level is the user's ([GlassLookScope]); the theme may bring it down
/// ([GlassMaterial.resolve]). High contrast, the themes that outline their
/// resting controls and a page painted without the ambient light stay flat:
/// glass over a flat page has nothing to show.
abstract final class HermesGlassLook {
  static GlassMaterial? of(BuildContext context) {
    if (!HermesAmbient.enabled || MediaQuery.highContrastOf(context)) {
      return null;
    }
    final theme = Theme.of(context);
    if (theme.hermesComponents.profile.border.outlinesRestingControls) {
      return null;
    }
    return GlassMaterial.resolve(theme.hermes, GlassLookScope.levelOf(context));
  }

  /// The body of a user's message bubble: [fallback] where the theme wears
  /// no glass, otherwise the theme's own bubble colour, opaque enough
  /// ([GlassMaterial.bubbleOpacity]) that its text does not depend on what is
  /// behind it.
  static Color bubbleFill(BuildContext context, Color surfaceVariant) =>
      of(context) == null
      ? surfaceVariant.withValues(alpha: 0.6)
      : surfaceVariant.withValues(alpha: GlassMaterial.bubbleOpacity);

  /// The body of a piece of glass with the glint at the top: [fill] all over,
  /// lit by [GlassMaterial.sheen] along the top. The glint is part of the
  /// body, under the ink and never over it: [GlassMaterial.sheen] is chosen
  /// so that every ink still reads through it.
  ///
  /// A [BoxDecoration] paints its gradient INSTEAD of its colour, so the
  /// gradient carries the fill itself: the box is [fill] everywhere and the
  /// glint is the only thing that changes along it.
  static LinearGradient sheen(GlassMaterial glass, {required Color fill}) =>
      LinearGradient(
        begin: const Alignment(-0.6, -1),
        end: const Alignment(0.6, 1),
        stops: const [0, 0.12],
        colors: [Color.alphaBlend(glass.sheen, fill), fill],
      );

  /// The body of a piece of glass: [fill] (the group or card body) with the
  /// glint of the top. Its contour, rims and shadow are [HermesBoxEdges]'s:
  /// the box leaves [HermesGel.rimWidth] all round for the contour.
  static BoxDecoration decoration(
    GlassMaterial glass,
    BorderRadius radius, {
    Color? fill,
  }) => BoxDecoration(
    color: fill ?? glass.groupFill,
    borderRadius: radius,
    gradient: sheen(glass, fill: fill ?? glass.groupFill),
  );

  /// The body of a small choice (a mode button, a chip-like option): the glass
  /// with its contour and short shadow ([HermesBoxEdges], with [line] the
  /// accent when chosen); chosen, the soft accent fill. The ink on it is the
  /// one the glass certifies.
  static BoxDecoration choice(
    GlassMaterial glass,
    BorderRadius radius, {
    required bool selected,
  }) => BoxDecoration(
    color: selected
        ? ThemeContrast.composite(glass.selected, glass.pieceFill)
        : glass.pieceFill,
    borderRadius: radius,
  );

  /// [child] on a piece of glass, with the finish of the gel at the scale of
  /// a box ([HermesBoxEdges]): the contour in two tones (lighter on top), the
  /// inner light of the top edge and shade of the bottom one, and, when
  /// [lifted], a short shadow outside the outline ([compact]: the shorter one
  /// of a card or a row of a list). [line] paints the whole contour in one
  /// colour (a selected row's accent). It is all painted, never blurred over
  /// the content and never under the ink.
  static Widget body(
    GlassMaterial glass,
    BorderRadius radius, {
    required Widget child,
    Color? fill,
    bool lifted = false,
    bool compact = false,
    Color? line,
    EdgeInsetsGeometry? margin,
  }) {
    final box = HermesBoxEdges(
      glass: glass,
      radius: radius,
      lifted: lifted,
      compact: compact,
      line: line,
      child: Container(
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.all(HermesGel.rimWidth),
        decoration: decoration(glass, radius, fill: fill),
        // The rows' ink (a pressed or focused row) paints here, over the
        // body and inside its rounded clip; on the page's Material it went
        // under the opaque body and showed only as square corners.
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
    return margin == null ? box : Padding(padding: margin, child: box);
  }

  /// [label] as a section shows it: in capitals where the theme's titles are
  /// (the screen reader keeps the name as written, see [sectionSemantics]).
  static String sectionText(BuildContext context, String label) =>
      Theme.of(context).hermes.uppercaseTitles ? label.toUpperCase() : label;

  /// The spoken name of a section label: the one as written.
  static String? sectionSemantics(BuildContext context, String label) =>
      Theme.of(context).hermes.uppercaseTitles ? label : null;

  /// [base] as the label of a section: small, bold and tracked, in small
  /// capitals where the font has them, on the full level; in the terminal
  /// looks and the Outline style, tracked, and the text itself is shown in
  /// capitals ([sectionText]).
  static TextStyle sectionLabel(
    BuildContext context,
    TextStyle base, {
    GlassMaterial? glass,
  }) {
    // The terminal looks (and the Outline style, which turns their flag on)
    // wear the small tracked label without the glass.
    if (Theme.of(context).hermes.uppercaseTitles) {
      return base.copyWith(
        fontSize: HermesType.sectionSize,
        fontWeight: FontWeight.w600,
        letterSpacing: HermesType.sectionTracking * 2,
      );
    }
    final material = glass ?? of(context);
    if (material == null || !material.isFull) return base;
    return base.copyWith(
      fontSize: HermesType.sectionSize,
      fontWeight: FontWeight.w600,
      letterSpacing: HermesType.sectionTracking,
      fontFeatures: const [
        FontFeature.enable('smcp'),
        FontFeature.enable('c2sc'),
      ],
    );
  }
}

/// The page colour with the theme's light behind [child].
///
/// A screen of long text (the chat's transcript) wraps itself in a
/// [HermesReadingZone]: the glow then gives way to a calm veil of the page
/// colour under the column of text and shows only at the top and the bottom.
class HermesAmbientBackdrop extends StatefulWidget {
  const HermesAmbientBackdrop({required this.child, super.key});

  final Widget child;

  @override
  State<HermesAmbientBackdrop> createState() => _HermesAmbientBackdropState();
}

/// The calm of one backdrop: 0 leaves the glow as it is, 1 is the full
/// reading veil.
class HermesReadingCalm extends ValueNotifier<double> {
  HermesReadingCalm() : super(0);
}

class _CalmScope extends InheritedWidget {
  const _CalmScope({required this.calm, required super.child});

  final HermesReadingCalm calm;

  @override
  bool updateShouldNotify(_CalmScope oldWidget) => calm != oldWidget.calm;
}

class _HermesAmbientBackdropState extends State<HermesAmbientBackdrop> {
  final HermesReadingCalm _calm = HermesReadingCalm();

  @override
  void dispose() {
    _calm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!HermesAmbient.enabled) return widget.child;
    final colors = Theme.of(context).hermes;
    final flat = MediaQuery.highContrastOf(context) || colors.outlined;
    // No glass (off, a theme whose ink does not read on it, high contrast,
    // Outline) is a flat page: there is no other light to paint.
    final glass = flat
        ? null
        : GlassMaterial.resolve(colors, GlassLookScope.levelOf(context));
    return _CalmScope(
      calm: _calm,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Only light: it never takes a touch from the page above it.
          IgnorePointer(
            child: RepaintBoundary(
              child: ValueListenableBuilder<double>(
                valueListenable: _calm,
                builder: (context, calm, _) => CustomPaint(
                  painter: _AmbientPainter(
                    base: colors.background,
                    glass: glass,
                    readingCalm: calm,
                  ),
                ),
              ),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}

/// Marks its [child] as a screen of long text: while it is on screen the
/// backdrop under it calms (see [HermesAmbientBackdrop]). It paints nothing
/// and changes no layout. With the reduced-motion setting the calm is set at
/// once, not faded.
class HermesReadingZone extends StatefulWidget {
  const HermesReadingZone({required this.child, super.key});

  final Widget child;

  @override
  State<HermesReadingZone> createState() => _HermesReadingZoneState();
}

class _HermesReadingZoneState extends State<HermesReadingZone> {
  HermesReadingCalm? _calm;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.getInheritedWidgetOfExactType<_CalmScope>()?.calm;
    if (next == _calm) return;
    _calm?.value = 0;
    _calm = next;
    // After the frame: the backdrop is above this widget and is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _calm?.value = 1;
    });
  }

  @override
  void dispose() {
    final calm = _calm;
    if (calm != null) {
      // The backdrop outlives its page when the route is popped on top of
      // another one; when it goes too it is already disposed and ignores it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          calm.value = 0;
        } catch (_) {
          // The backdrop was disposed with its route.
        }
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _AmbientPainter extends CustomPainter {
  const _AmbientPainter({required this.base, this.glass, this.readingCalm = 0});

  /// 0 leaves the glow; 1 lays the reading veil of the theme over it.
  final double readingCalm;

  final Color base;

  /// The glass of the theme; null paints the plain page colour.
  final GlassMaterial? glass;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = base);
    final derived = glass;
    if (derived == null || size.isEmpty) return;
    // One glow of the page's own colour, fading out like a blurred disc:
    // one layer, drawn once.
    final reach = math.max(size.width, size.height);
    final center = Offset(
      size.width * GlassMaterial.glowAt.dx,
      size.height * GlassMaterial.glowAt.dy,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader =
            RadialGradient(
              colors: [derived.glow, derived.glow.withValues(alpha: 0)],
            ).createShader(
              Rect.fromCircle(
                center: center,
                radius: reach * GlassMaterial.glowReach,
              ),
            ),
    );
    if (readingCalm > 0) {
      // One flat veil of the page colour under the column of text; it only
      // fades out at the top and the bottom, where the glow shows.
      final veil = derived.readingVeil * readingCalm;
      const edge = GlassMaterial.calmEdge;
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              base.withValues(alpha: 0),
              base.withValues(alpha: veil),
              base.withValues(alpha: veil),
              base.withValues(alpha: 0),
            ],
            stops: const [0, edge, 1 - edge, 1],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AmbientPainter oldDelegate) =>
      oldDelegate.base != base ||
      oldDelegate.glass != glass ||
      oldDelegate.readingCalm != readingCalm;
}

/// Puts [HermesAmbientBackdrop] under the page of every route, then lets
/// [base] animate it as it always did.
class HermesAmbientTransitions extends PageTransitionsBuilder {
  const HermesAmbientTransitions(this.base);

  final PageTransitionsBuilder base;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => base.buildTransitions<T>(
    route,
    context,
    animation,
    secondaryAnimation,
    HermesAmbientBackdrop(child: child),
  );
}

/// [theme] with transparent pages over the ambient light: every page keeps
/// the colour it had, now painted by [HermesAmbientBackdrop] under it.
///
/// On the full glass level the primary button also gets its gradient, from
/// the accent to the accent lightened ([level] defaults to the saved one).
ThemeData hermesAmbientTheme(ThemeData theme, {GlassLevel? level}) {
  if (!HermesAmbient.enabled) return theme;
  final builders = theme.pageTransitionsTheme.builders;
  final colors = theme.hermes;
  final glass = GlassMaterial.resolve(
    colors,
    level ?? GlassLookPrefs.shared.level,
  );
  final end = glass?.buttonEnd;
  final filled = theme.filledButtonTheme.style;
  return theme.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    segmentedButtonTheme: glass == null
        ? null
        : _glassSegmented(theme.segmentedButtonTheme, glass, colors),
    chipTheme: glass == null
        ? null
        : _glassChips(theme.chipTheme, glass, colors),
    dialogTheme: glass == null
        ? null
        : theme.dialogTheme.copyWith(
            shadowColor: glass.shadow,
            shape: _glassShape(theme.dialogTheme.shape, glass),
          ),
    popupMenuTheme: glass == null
        ? null
        : theme.popupMenuTheme.copyWith(
            shadowColor: glass.shadow,
            shape: _glassShape(theme.popupMenuTheme.shape, glass),
          ),
    bottomSheetTheme: glass == null
        ? null
        : theme.bottomSheetTheme.copyWith(
            shadowColor: glass.shadow,
            shape: _glassShape(theme.bottomSheetTheme.shape, glass),
          ),
    filledButtonTheme: end == null
        ? null
        : FilledButtonThemeData(
            style: (filled ?? const ButtonStyle()).copyWith(
              backgroundBuilder: (context, states, child) =>
                  states.contains(WidgetState.disabled)
                  ? child!
                  : Builder(
                      builder: (context) => _isPlainPrimary(context, colors)
                          // Ink, not a plain box: the press and hover tints
                          // are painted on the material and a box would hide
                          // them.
                          ? Ink(
                              // The gradient takes the button's own shape
                              // (the Material it sits in): as a plain
                              // rectangle it read as a square block on
                              // older engines that do not clip it (QA
                              // 1.4.0, SSH setup).
                              decoration: ShapeDecoration(
                                shape:
                                    context
                                        .findAncestorWidgetOfExactType<
                                          Material
                                        >()
                                        ?.shape ??
                                    const StadiumBorder(),
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [colors.accent, end],
                                ),
                              ),
                              child: child,
                            )
                          : child!,
                    ),
            ),
          ),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: HermesAmbientTransitions(
            builders[platform] ??
                (platform == TargetPlatform.iOS ||
                        platform == TargetPlatform.macOS
                    ? const CupertinoPageTransitionsBuilder()
                    : const ZoomPageTransitionsBuilder()),
          ),
      },
    ),
  );
}

/// [shape] with the border of the glass.
ShapeBorder? _glassShape(ShapeBorder? shape, GlassMaterial glass) =>
    shape is RoundedRectangleBorder
    ? shape.copyWith(side: BorderSide(color: glass.line))
    : shape;

/// The segmented control on glass: the selected segment is a soft fill of
/// the accent with the accent as its border and a bold label; the others are
/// the glass with its border.
SegmentedButtonThemeData _glassSegmented(
  SegmentedButtonThemeData base,
  GlassMaterial glass,
  HermesThemeColors colors,
) {
  final body = ThemeContrast.composite(glass.selected, glass.pieceFill);
  final style = base.style ?? const ButtonStyle();
  return SegmentedButtonThemeData(
    selectedIcon: base.selectedIcon,
    style: style.copyWith(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? body : glass.pieceFill,
      ),
      side: WidgetStateProperty.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.selected)
              ? glass.selectedLine
              : glass.line,
        ),
      ),
      textStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
        ),
      ),
    ),
  );
}

/// Chips on glass: the glass body and border; a selected chip is the soft
/// accent fill with a bold label in the main ink.
ChipThemeData _glassChips(
  ChipThemeData base,
  GlassMaterial glass,
  HermesThemeColors colors,
) {
  final body = ThemeContrast.composite(glass.selected, glass.pieceFill);
  return base.copyWith(
    backgroundColor: glass.pieceFill,
    selectedColor: body,
    secondarySelectedColor: body,
    side: BorderSide(color: glass.line),
    secondaryLabelStyle: TextStyle(
      color: colors.textPrimary,
      fontWeight: FontWeight.w700,
    ),
    checkmarkColor: colors.textPrimary,
  );
}

/// The style of a tonal filled button: it keeps the paint of its own variant
/// and does not take the primary button's gradient, which the theme lays on
/// every filled button.
final ButtonStyle hermesTonalButtonStyle = ButtonStyle(
  backgroundBuilder: (context, states, child) => child!,
);

/// Whether the button this is built in paints the accent as its body, which
/// is what the primary button does. A button that brings its own colour (a
/// destructive one in the error colour) keeps it. Read from the button's own
/// [Material], which holds the colour the style finally resolved to.
bool _isPlainPrimary(BuildContext context, HermesThemeColors colors) =>
    context.findAncestorWidgetOfExactType<Material>()?.color == colors.accent;
