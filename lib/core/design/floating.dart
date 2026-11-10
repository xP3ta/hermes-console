import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/theme_contrast.dart';
import 'gel_surface.dart';
import 'glass_strip.dart';
import 'liquid_sheen.dart';
import 'tokens.dart';

/// The one surface of everything that floats in front of the page: header
/// buttons and pills, the dock, notices, sticky buttons, menus and sheets.
///
/// It paints the [HermesChrome] of the current theme: the lifted fill, the
/// hairline and the soft static shadow. Nothing here animates, so a list
/// scrolling behind it costs no extra work per frame; give each floating
/// group its own [RepaintBoundary].
///
/// Inside a [HermesGlassStrip] (a header, Q9-CRISTAL) it is one of the
/// strip's pieces: while the strip frosts, it wears the composer's veil
/// over the strip's one blur, without shadow; otherwise the chrome above.
///
/// Text and icons below it default to the chrome's ink. Ink splashes of
/// buttons inside it paint on this surface.
class HermesFloatingSurface extends StatelessWidget {
  const HermesFloatingSurface({
    required this.child,
    this.shape = const StadiumBorder(),
    this.modal = false,
    this.shadow = true,
    this.padding = EdgeInsets.zero,
    this.fill,
    this.onTap,
    this.onLongPress,
    this.clipBehavior = Clip.antiAlias,
    this.keepTextStyle = false,
    this.lifted = false,
    super.key,
  });

  final Widget child;

  /// A window that stands out over the page (the owner, the chat's final
  /// windows): a deeper shadow and a rim of light along its edge, the
  /// liquid glass's.
  final bool lifted;

  /// True keeps the text style the piece was given (a header title: one
  /// line that ellipsizes). Otherwise the text below is the theme's body
  /// text; a surface pushed as its own route has no style above it to keep.
  final bool keepTextStyle;

  /// Outline of the piece: a stadium (pills), a circle (round buttons) or a
  /// rounded rectangle (menus, sheets). Its side is replaced by the hairline.
  final OutlinedBorder shape;

  /// A modal surface (a menu, a dialog, a sheet, a popover) is always opaque:
  /// the theme's [HermesChrome.opaque], never frosted and never see-through,
  /// so what is under it can not be read through it. It keeps its border,
  /// its shadow and the rim of light.
  final bool modal;

  /// Whether the soft shadow is painted. Pieces that sit inside another
  /// floating piece pass false.
  final bool shadow;

  final EdgeInsetsGeometry padding;

  /// Replaces the fill, for a caller that resolves its own (a surface that
  /// goes through `FrostedBackdrop`).
  final Color? fill;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Clip clipBehavior;

  /// A lifted window's veil where it blurs (ventanas-final-png): dark,
  /// light.
  static const double _liftedVeilDark = 0.80;
  static const double _liftedVeilLight = 0.84;

  /// The glow of a lifted window's top third, under its content: dark,
  /// light.
  // At 0.06, the lightest dark palettes plus a selected row's tint left
  // even white below 4.5:1. Lower the painted glow as well as its contrast
  // model, leaving room for chromatic ink instead of washing it to white.
  static const double _glowDark = 0.04;
  static const double _glowLight = 0.18;

  static final Expando<Map<(int, int?), Color>> _windowInks = Expando(
    'windowInk',
  );

  /// [ink] made readable (4.5:1) on a window over the page, the same hue
  /// lighter or darker (REVIEW-Q9-VENT P2): on its opaque fill and, lifted,
  /// on its veil over the worst its blur can show behind it (white or
  /// black, under the lightest barrier, a menu's), with the glow of its top
  /// third; on [tint] over all of them when given (a row in the accent).
  static Color windowInk(HermesThemeColors colors, Color ink, {Color? tint}) {
    final inks = _windowInks[colors] ??= <(int, int?), Color>{};
    final key = (ink.toARGB32(), tint?.toARGB32());
    final cached = inks[key];
    if (cached != null) return cached;
    final chrome = HermesChrome.of(colors);
    final veil = chrome.opaque.withValues(
      alpha: chrome.dark ? _liftedVeilDark : _liftedVeilLight,
    );
    final glow = Colors.white.withValues(
      alpha: chrome.dark ? _glowDark : _glowLight,
    );
    final barrier = Colors.black.withValues(alpha: HermesChrome.scrimMenu);
    final backgrounds = <Color>[chrome.opaque];
    for (final behind in [Colors.white, Colors.black]) {
      final through = ThemeContrast.composite(
        veil,
        ThemeContrast.composite(barrier, behind),
      );
      backgrounds
        ..add(through)
        ..add(ThemeContrast.composite(glow, through));
    }
    return inks[key] = ThemeContrast.adjustForContrast(
      ink,
      [
        for (final background in backgrounds)
          tint == null ? background : ThemeContrast.composite(tint, background),
      ],
      minimum: 4.5,
      maximumHueShift: 2,
    );
  }

  /// A lifted window's shadow, in three layers (ventanas-final-png): the
  /// contact, the middle and the ambient one.
  static List<BoxShadow> _depth(HermesChrome chrome) {
    final dark = chrome.dark;
    BoxShadow layer(double alpha, double y, double blur) => BoxShadow(
      color: Colors.black.withValues(alpha: alpha),
      blurRadius: blur,
      offset: Offset(0, y),
    );
    return [
      layer(dark ? 0.30 : 0.08, 2, 4),
      layer(dark ? 0.38 : 0.14, 12, 28),
      layer(dark ? 0.34 : 0.12, 28, 60),
    ];
  }

  /// The glow of a lifted window's top third, painted on its fill and
  /// under its content (REVIEW-Q9-VENT P2-2: over the content it washed
  /// the text of the top third out).
  static Widget _withGlow(bool lifted, bool dark, Widget child) => lifted
      ? CustomPaint(
          painter: _LiftedGlow(dark: dark),
          child: child,
        )
      : child;

  /// Rounded rectangle of a floating group or menu.
  static OutlinedBorder rounded([double radius = HermesRadius.floating]) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));

  @override
  Widget build(BuildContext context) {
    final chrome = HermesChrome.ofContext(context);
    // Lifted, the rim of light is painted over the edge instead.
    final outlined = shape.copyWith(
      side: lifted ? BorderSide.none : BorderSide(color: chrome.line),
    );
    Widget content = Padding(padding: padding, child: child);
    if (onTap != null || onLongPress != null) {
      content = InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        customBorder: shape,
        child: content,
      );
    }
    // A Material resets the text style below it. The piece keeps the one it
    // was given (a header title must still be one line that ellipsizes), in
    // the chrome's ink.
    final text = keepTextStyle ? DefaultTextStyle.of(context) : null;
    // A modal surface never borrows a header's fill and is never see-through:
    // a [fill] of a caller goes over the opaque chrome.
    final inStrip = !modal && HermesGlassStrip.contains(context);
    final glass = inStrip ? HermesGlassStrip.of(context) : null;
    final surface = Material(
      color: modal
          ? (fill == null
                ? chrome.opaque
                : Color.alphaBlend(fill!, chrome.opaque))
          : fill ?? glass?.veil ?? chrome.fill,
      surfaceTintColor: Colors.transparent,
      shape: outlined,
      clipBehavior: clipBehavior,
      child: IconTheme.merge(
        data: IconThemeData(color: chrome.ink),
        child: _withGlow(
          lifted,
          chrome.dark,
          text == null
              ? DefaultTextStyle.merge(
                  style: TextStyle(color: chrome.ink),
                  child: content,
                )
              : DefaultTextStyle(
                  style: text.style.copyWith(color: chrome.ink),
                  textAlign: text.textAlign,
                  softWrap: text.softWrap,
                  overflow: text.overflow,
                  maxLines: text.maxLines,
                  textWidthBasis: text.textWidthBasis,
                  textHeightBehavior: text.textHeightBehavior,
                  child: content,
                ),
        ),
      ),
    );
    Widget body = surface;
    if (modal || lifted) body = HermesSheen(shape: shape, child: body);
    // The same widgets with or without the shadow: what sits on the piece
    // keeps its state when the strip starts or stops frosting.
    final piece = DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: !shadow || glass != null
            ? const []
            : lifted
            ? _depth(chrome)
            : chrome.shadow,
      ),
      child: body,
    );
    if (!inStrip) return shadow ? piece : body;
    return HermesGlassPiece(shape: shape, child: piece);
  }
}

/// A round floating button: 44 dp to look at, 48 dp to tap.
class HermesFloatingIconButton extends StatelessWidget {
  const HermesFloatingIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Colour of the icon when it says something (a filter that is on).
  final Color? color;

  /// Visual size of the button.
  static const double size = 44;

  /// The padding the 48 dp target leaves around the look.
  static const double gelInset = 2;

  /// [child] (the stack of this button: its shadow and the [IconButton])
  /// wearing the gel: rims, sheen and a press that compresses it.
  static Widget gel(Widget child) =>
      HermesGelSurface(inset: gelInset, child: child);

  /// The round floating look, for an [IconButton] or an [IconButtonTheme].
  /// [fill] replaces the chrome's: a header strip's glass
  /// ([HermesGlassStrip.of]).
  static ButtonStyle style(HermesChrome chrome, {Color? fill}) =>
      IconButton.styleFrom(
        fixedSize: const Size.square(size),
        minimumSize: const Size.square(size),
        tapTargetSize: MaterialTapTargetSize.padded,
        backgroundColor: fill ?? chrome.fill,
        foregroundColor: chrome.ink,
        shape: CircleBorder(side: BorderSide(color: chrome.line)),
      );

  /// The soft shadow under a round floating button, to stack behind it.
  /// Inside a [HermesGlassStrip] it is also the button's outline for the
  /// strip's blur, and has no shadow while the strip frosts.
  static Widget shadow(HermesChrome chrome) => _RoundShadow(chrome: chrome);

  @override
  Widget build(BuildContext context) {
    final chrome = HermesChrome.ofContext(context);
    return gel(
      Stack(
        alignment: Alignment.center,
        children: [
          shadow(chrome),
          IconButton(
            tooltip: tooltip,
            onPressed: onPressed,
            style: style(chrome, fill: HermesGlassStrip.of(context)?.veil),
            icon: Icon(icon, size: 21, color: color),
          ),
        ],
      ),
    );
  }
}

/// [HermesFloatingIconButton.shadow].
class _RoundShadow extends StatelessWidget {
  const _RoundShadow({required this.chrome});

  final HermesChrome chrome;

  @override
  Widget build(BuildContext context) {
    final glass = HermesGlassStrip.of(context);
    final shadow = SizedBox.square(
      dimension: HermesFloatingIconButton.size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: const CircleBorder(),
          shadows: glass == null ? chrome.shadow : const [],
        ),
      ),
    );
    if (!HermesGlassStrip.contains(context)) {
      return IgnorePointer(child: shadow);
    }
    return IgnorePointer(
      child: HermesGlassPiece(shape: const CircleBorder(), child: shadow),
    );
  }
}

/// A lifted window's glow in its top third, on its fill (clipped by it).
class _LiftedGlow extends CustomPainter {
  const _LiftedGlow({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(
              alpha: dark
                  ? HermesFloatingSurface._glowDark
                  : HermesFloatingSurface._glowLight,
            ),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0, 1 / 3],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_LiftedGlow oldDelegate) => oldDelegate.dark != dark;
}
