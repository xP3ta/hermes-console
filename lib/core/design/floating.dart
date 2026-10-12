import 'package:flutter/material.dart';

import 'tokens.dart';

/// The one surface of everything that floats in front of the page: header
/// buttons and pills, the dock, notices, sticky buttons, menus and sheets.
///
/// It paints the [HermesChrome] of the current theme: the lifted fill, the
/// hairline and the soft static shadow. Nothing is blurred and nothing here
/// animates, so a list scrolling behind it costs no extra work per frame;
/// give each floating group its own [RepaintBoundary].
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
    super.key,
  });

  final Widget child;

  /// True keeps the text style the piece was given (a header title: one
  /// line that ellipsizes). Otherwise the text below is the theme's body
  /// text; a surface pushed as its own route has no style above it to keep.
  final bool keepTextStyle;

  /// Outline of the piece: a stadium (pills), a circle (round buttons) or a
  /// rounded rectangle (menus, sheets). Its side is replaced by the hairline.
  final OutlinedBorder shape;

  /// Modal surfaces (menus, sheets, dialogs) are opaque: rows never show
  /// through a surface that carries a list of its own.
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

  /// Rounded rectangle of a floating group or menu.
  static OutlinedBorder rounded([double radius = HermesRadius.floating]) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));

  @override
  Widget build(BuildContext context) {
    final chrome = HermesChrome.ofContext(context);
    final outlined = shape.copyWith(side: BorderSide(color: chrome.line));
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
    final surface = Material(
      color: fill ?? (modal ? chrome.opaque : chrome.fill),
      surfaceTintColor: Colors.transparent,
      shape: outlined,
      clipBehavior: clipBehavior,
      child: IconTheme.merge(
        data: IconThemeData(color: chrome.ink),
        child: text == null
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
    );
    if (!shadow) return surface;
    return DecoratedBox(
      decoration: ShapeDecoration(shape: shape, shadows: chrome.shadow),
      child: surface,
    );
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

  /// The round floating look, for an [IconButton] or an [IconButtonTheme].
  static ButtonStyle style(HermesChrome chrome) => IconButton.styleFrom(
    fixedSize: const Size.square(size),
    minimumSize: const Size.square(size),
    tapTargetSize: MaterialTapTargetSize.padded,
    backgroundColor: chrome.fill,
    foregroundColor: chrome.ink,
    shape: CircleBorder(side: BorderSide(color: chrome.line)),
  );

  /// The soft shadow under a round floating button, to stack behind it.
  static Widget shadow(HermesChrome chrome) => IgnorePointer(
    child: SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: const CircleBorder(),
          shadows: chrome.shadow,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final chrome = HermesChrome.ofContext(context);
    return Stack(
      alignment: Alignment.center,
      children: [
        shadow(chrome),
        IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          style: style(chrome),
          icon: Icon(icon, size: 21, color: color),
        ),
      ],
    );
  }
}
