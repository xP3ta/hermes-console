import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../design/floating.dart';
import '../design/gel_surface.dart';
import '../design/glass_strip.dart';
import '../design/liquid_glass.dart';
import '../design/modal.dart'
    show HermesAction, HermesMenuButton, showHermesMenu;
import '../design/tokens.dart';
import '../feedback/screen_help.dart' show ScreenHelpButton, showScreenHelp;
import '../theme/app_theme.dart';
import '../theme/glass_look.dart';
import '../theme/theme_contrast.dart';
import '../utils/responsive.dart';
import 'dock.dart' show dockRailFootprint;

/// Header of every screen that is not a chat: floating pieces, no band.
///
/// Same API as Material's [AppBar] for the parameters the app uses, and it
/// still builds one, so the status bar inset, the toolbar layout and the
/// header semantics are the framework's. What changes is what is painted:
///
///  * no background: the page shows through, and a list that passes
///    [hermesUnderHeader] as its `clipBehavior` keeps scrolling under it;
///  * the leading control (given, or the implied back, close or menu
///    button) is a round floating button;
///  * the title sits in a floating pill, centred. A composite title (a
///    name over a status line) keeps both lines inside it;
///  * the actions share one floating pill. Past [maxPillActions] the icon
///    buttons that say what they do (a tooltip) move into a "more" menu.
///    A text or filled button, or any widget this bar does not know, is
///    left as it is, outside the pill;
///  * the pieces are one [HermesGlassStrip] (Q9-CRISTAL): the composer's
///    glass, one blur for all of them, over a soft fade of the page colour
///    that keeps the status bar readable over rows passing underneath.
///    Without blur (the device, reduced motion, high contrast) they are the
///    chrome's lifted fill over the denser gradient of before. Nothing
///    listens to the scroll.
///
/// In the terminal themes ([HermesThemeColors.uppercaseTitles]) the title is
/// shown in capitals: a plain [Text], or the first [Text] of a [Column] or
/// [Row].
class HermesAppBar extends StatelessWidget implements PreferredSizeWidget {
  const HermesAppBar({
    super.key,
    this.title,
    this.leading,
    this.actions,
    this.bottom,
    this.centerTitle,
    this.backgroundColor,
    this.foregroundColor,
    this.elevation,
    this.scrolledUnderElevation,
    this.titleSpacing,
    this.shape,
    this.surfaceTintColor,
    this.iconTheme,
    this.titleTextStyle,
    this.systemOverlayStyle,
    this.automaticallyImplyLeading = true,
    this.toolbarHeight,
    this.maxPillActions = 3,
    this.titleBadge,
    this.titleInPill = false,
    this.actionsInPill = true,
    this.floatingLeading = true,
    this.scrim = true,
    this.glass = true,
  }) : assert(maxPillActions >= 2);

  /// The page's name, in one line. Anything else the header has to say goes
  /// in [titleBadge].
  final Widget? title;

  /// A small mark of a state that matters (a connection dot, «solo lectura»,
  /// the scope the page is limited to), shown in the pill after the name.
  /// Never a second line, and never the profile or instance the whole app is
  /// already on.
  final Widget? titleBadge;
  final Widget? leading;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;

  /// Colour of the page behind the header. It tints the scrim and decides
  /// the status bar icons; the header itself has no fill.
  final Color? backgroundColor;
  final Color? foregroundColor;
  final IconThemeData? iconTheme;
  final TextStyle? titleTextStyle;
  final SystemUiOverlayStyle? systemOverlayStyle;
  final bool automaticallyImplyLeading;

  /// Taller toolbar for composite titles; defaults to [kToolbarHeight].
  final double? toolbarHeight;

  /// Most icons the actions pill shows, the "more" button included.
  final int maxPillActions;

  /// True puts the title in a floating pill, centred. False (the default)
  /// leaves it as plain text at the start of the bar, 17 dp and semibold, with
  /// the glass kept for the round buttons and the actions: the page's name is
  /// not a button, so it is not drawn as one.
  final bool titleInPill;

  /// False leaves the actions as they come, for ones that are already
  /// floating pieces of their own (no chrome around chrome).
  final bool actionsInPill;

  /// False leaves the leading control a plain icon.
  final bool floatingLeading;

  /// False paints no scrim: a page that never scrolls under its header has
  /// nothing to keep away from it.
  final bool scrim;

  /// False keeps the pieces in the chrome of before, without blur: a page
  /// where nothing passes under the header (a terminal, an editor, a
  /// viewer, a search field above its list) pays for no blur it cannot
  /// show (Q9-CRISTAL).
  final bool glass;

  // Accepted so call sites keep compiling; a header without a band has no
  // elevation, shape or tint, and its title pill is always centred.
  final bool? centerTitle;
  final double? elevation;
  final double? scrolledUnderElevation;
  final double? titleSpacing;
  final ShapeBorder? shape;
  final Color? surfaceTintColor;

  /// Visual size of the round button and height of the pills.
  static const double pieceSize = 44;

  /// How far below the header its scrim runs.
  static const double scrimTail = HermesGlassStrip.fadeTail;

  /// How far below the header its veil fades out. It never reaches past the
  /// gap a page leaves under its header ([HermesSpace.pageTop]) nor the one
  /// its floating controls keep ([HermesSpace.x2]): the first row of a page
  /// at rest is never dimmed by it.
  static const double veilTail = HermesSpace.x2;

  /// The least contrast (WCAG AA) the title reads at over the glass band.
  static const double bandContrast = 4.5;

  /// How much denser the band is over the status bar than over the toolbar.
  static const double statusLift = 0.08;

  /// The band's page colour tint at the toolbar (the density that keeps the
  /// title at [bandContrast] over the worst content that can pass behind):
  /// the least alpha, from the strip's own fade floor
  /// ([HermesGlassStrip.fadeEdge]) up, at which the chrome's ink reads over
  /// the page colour at that alpha laid on white (a dark theme) or black (a
  /// light one). The blur gets no credit: a plain white card stays white.
  /// 1.0 means no translucency left (no theme does today; the test says so).
  static double bandAlpha(HermesThemeColors colors) =>
      _bandAlpha[colors] ??= _resolveBandAlpha(colors);

  static final Expando<double> _bandAlpha = Expando<double>('HermesAppBar');

  /// What the band's tint at [alpha] lays over the worst content: the page
  /// colour on white behind a dark theme, on black behind a light one.
  static Color bandUnder(HermesThemeColors colors, double alpha) {
    final worst = HermesChrome.of(colors).dark ? Colors.white : Colors.black;
    return ThemeContrast.composite(
      colors.background.withValues(alpha: alpha.clamp(0.0, 1.0)),
      worst,
    );
  }

  static double _resolveBandAlpha(HermesThemeColors colors) {
    final chrome = HermesChrome.of(colors);
    // The title (the chrome's ink) and, for the badge that sits on the band
    // with its own tint, the extreme of its side (white on a dark page,
    // black on a light one): the furthest its ink can be moved to.
    final badgeTint = chrome.ink.withValues(
      alpha: HermesTitleBadge.tintOpacity,
    );
    final extreme = chrome.dark ? Colors.white : Colors.black;
    // A little over the minimum: the painted alpha is quantised to 8 bits.
    const margin = 0.1;
    for (
      var alpha = HermesGlassStrip.fadeEdge;
      alpha < 1;
      alpha += bandAlphaStep
    ) {
      final under = bandUnder(colors, alpha);
      if (ThemeContrast.ratio(chrome.ink, under) >= bandContrast + margin &&
          ThemeContrast.ratio(
                extreme,
                ThemeContrast.composite(badgeTint, under),
              ) >=
              bandContrast + margin) {
        return alpha;
      }
    }
    return 1;
  }

  /// The step the band's density is searched in.
  static const double bandAlphaStep = 0.02;

  @override
  Size get preferredSize => Size.fromHeight(
    (toolbarHeight ?? kToolbarHeight) + (bottom?.preferredSize.height ?? 0.0),
  );

  /// The round floating look of the leading button (48 dp target); [fill]
  /// is a header strip's glass.
  static ButtonStyle roundButtonStyle(HermesChrome chrome, {Color? fill}) =>
      HermesFloatingIconButton.style(chrome, fill: fill);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final chrome = HermesChrome.of(colors);
    final resolvedTitle = colors.uppercaseTitles
        ? _applyUppercase(title)
        : title;
    final page = backgroundColor ?? colors.background;
    final dark = ThemeData.estimateBrightnessForColor(page) == Brightness.dark;

    Widget? lead = leading;
    if (lead == null && automaticallyImplyLeading) {
      final route = ModalRoute.of(context);
      if (Scaffold.maybeOf(context)?.hasDrawer ?? false) {
        lead = const DrawerButton();
      } else if (route?.impliesAppBarDismissal ?? false) {
        lead = route is PageRoute<dynamic> && route.fullscreenDialog
            ? const CloseButton()
            : const BackButton();
      }
    }

    final baseTitle =
        titleTextStyle ??
        (theme.appBarTheme.titleTextStyle ?? const TextStyle()).copyWith(
          fontSize: titleInPill ? 14.5 : HermesType.titleSize,
          fontWeight: titleInPill ? FontWeight.w700 : FontWeight.w600,
        );
    final shown = actions ?? const <Widget>[];
    // The glass level asked for: off is the solid veil of before (the band
    // only exists where the strip frosts it).
    final band =
        scrim && glass && GlassLookScope.levelOf(context) != GlassLevel.off;
    // One layer for the whole header: rows scrolling under it repaint their
    // own layer only. Its pieces are one strip of glass where rows pass
    // under it (the scrim says so).
    return RepaintBoundary(
      child: HermesGlassStrip(
        enabled: scrim && glass,
        liquid: HermesLiquid.header,
        backdropFade: HermesGlassStrip.fadeEdge,
        band: band,
        child: AppBar(
          automaticallyImplyLeading: false,
          leading: lead == null || !floatingLeading
              ? lead
              : _FloatingLeading(child: lead),
          leadingWidth: kToolbarHeight,
          title: !_hasTitle(resolvedTitle)
              ? null
              : titleInPill
              ? _TitlePill(badge: titleBadge, child: resolvedTitle!)
              : _PlainTitle(badge: titleBadge, child: resolvedTitle!),
          centerTitle: titleInPill,
          titleSpacing: titleInPill ? 8 : titleSpacing,
          actions: shown.isEmpty
              ? null
              : actionsInPill
              ? [_FloatingActions(actions: shown, max: maxPillActions)]
              : shown,
          bottom: bottom,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          foregroundColor: foregroundColor ?? chrome.ink,
          elevation: 0,
          scrolledUnderElevation: 0,
          forceMaterialTransparency: true,
          iconTheme: iconTheme,
          titleTextStyle: baseTitle.copyWith(
            color: baseTitle.color ?? chrome.ink,
          ),
          systemOverlayStyle:
              systemOverlayStyle ??
              SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: dark
                    ? Brightness.light
                    : Brightness.dark,
                statusBarBrightness: dark ? Brightness.dark : Brightness.light,
              ),
          toolbarHeight: toolbarHeight,
          flexibleSpace: scrim ? _HeaderScrim(color: page, band: band) : null,
        ),
      ),
    );
  }

  static bool _hasTitle(Widget? title) =>
      title != null && !(title is Text && (title.data ?? '').isEmpty);

  /// Pone el título en MAYÚSCULAS. Soporta el [Text] simple y los títulos
  /// compuestos de dos líneas ([Column]/[Row]): en esos solo transforma el
  /// primer [Text] (el título), dejando intacto el subtítulo.
  Widget? _applyUppercase(Widget? w) {
    if (w is Text) return _upText(w);
    if (w is Column) {
      var done = false;
      return Column(
        key: w.key,
        mainAxisAlignment: w.mainAxisAlignment,
        mainAxisSize: w.mainAxisSize,
        crossAxisAlignment: w.crossAxisAlignment,
        textDirection: w.textDirection,
        verticalDirection: w.verticalDirection,
        textBaseline: w.textBaseline,
        children: w.children.map((c) {
          if (!done && c is Text && c.data != null) {
            done = true;
            return _upText(c);
          }
          return c;
        }).toList(),
      );
    }
    if (w is Row) {
      var done = false;
      return Row(
        key: w.key,
        mainAxisAlignment: w.mainAxisAlignment,
        mainAxisSize: w.mainAxisSize,
        crossAxisAlignment: w.crossAxisAlignment,
        textDirection: w.textDirection,
        verticalDirection: w.verticalDirection,
        textBaseline: w.textBaseline,
        children: w.children.map((c) {
          if (!done && c is Text && c.data != null) {
            done = true;
            return _upText(c);
          }
          return c;
        }).toList(),
      );
    }
    return w;
  }

  Text _upText(Text t) => Text(
    (t.data ?? '').toUpperCase(),
    style: t.style,
    textAlign: t.textAlign,
    overflow: t.overflow,
    maxLines: t.maxLines,
    softWrap: t.softWrap,
    semanticsLabel: t.semanticsLabel ?? t.data,
  );
}

/// `clipBehavior` of a page's own list under a [HermesAppBar].
///
/// The list keeps its place and its size: the first row rests below the
/// header and pull-to-refresh starts where it always did. It only stops
/// cutting what it paints at its upper edge, so rows scrolled past it stay
/// visible under the floating header until its scrim fades them out.
///
/// Only for a list that is the first thing in the page. One with a search
/// field or a view switch above it would paint its rows over them.
const Clip hermesUnderHeader = Clip.none;

/// What is behind the floating pieces.
///
/// With glass (the strip frosts, or only lost the zone to another strip) the
/// header is a BAND of glass, as the dock is: the strip's one blur fills the
/// measured rectangle of the header (status bar and bottom included) and a
/// tint of the page colour, [HermesAppBar.bandAlpha] over the toolbar and a
/// little more over the status bar, keeps the title at AA over any content
/// that passes behind; it melts into the page in [HermesAppBar.veilTail]. No
/// blur of its own and no listener to the scroll.
///
/// Without glass (high contrast, reduced motion, the policy: the strip is the
/// chrome of before) it is the scrim ([HermesGlassStrip.fade]'s denser
/// gradient) with the page colour SOLID from the top of the screen to the
/// foot of the header and the same short fade below it: a row scrolled under
/// the title never reads through it.
///
/// Both ignore pointers. Where a side rail is on screen the fade leaves its
/// column alone: the rail sits in the body right under the header and a fade
/// over its first control would dim it.
class _HeaderScrim extends StatelessWidget {
  const _HeaderScrim({required this.color, required this.band});

  final Color color;

  /// Whether the header is a band of glass (see [HermesAppBar.build]).
  final bool band;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final statusBar = MediaQuery.paddingOf(context).top;
    final glass = band && HermesGlassStrip.of(context) != null;
    final railColumn = Responsive.usesRail(context)
        ? dockRailFootprint(context)
        : 0.0;
    final alpha = HermesAppBar.bandAlpha(colors);
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final extent = constraints.maxHeight + HermesAppBar.scrimTail;
          final statusStop = extent.isFinite && extent > 0
              ? (statusBar / extent).clamp(0.0, 0.6)
              : 0.0;
          final foot = glass ? alpha : 1.0;
          final Widget body;
          if (glass && constraints.maxHeight.isFinite) {
            final bandStop = constraints.maxHeight > 0
                ? (statusBar / constraints.maxHeight).clamp(0.0, 1.0)
                : 0.0;
            body = HermesGlassPiece.band(
              child: DecoratedBox(
                key: const ValueKey('hermes-app-bar-glass'),
                position: DecorationPosition.background,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      color.withValues(
                        alpha: (alpha + HermesAppBar.statusLift).clamp(
                          0.0,
                          1.0,
                        ),
                      ),
                      color.withValues(alpha: alpha),
                      color.withValues(alpha: alpha),
                    ],
                    stops: [0, bandStop, 1],
                  ),
                ),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    height: 1,
                    width: double.infinity,
                    child: DecoratedBox(
                      key: const ValueKey('hermes-app-bar-glass-edge'),
                      decoration: BoxDecoration(
                        color: HermesGlassRim.edgeOf(HermesChrome.of(colors)),
                      ),
                    ),
                  ),
                ),
              ),
            );
          } else {
            body = ColoredBox(
              key: const ValueKey('hermes-app-bar-veil'),
              color: color,
            );
          }
          return Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              if (!glass)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  bottom: -HermesAppBar.scrimTail,
                  child: DecoratedBox(
                    key: const ValueKey('hermes-app-bar-scrim'),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          color.withValues(alpha: 0.97),
                          color.withValues(alpha: 0.9),
                          color.withValues(alpha: 0.62),
                          color.withValues(alpha: 0),
                        ],
                        stops: [0, statusStop, 0.68, 1],
                      ),
                    ),
                  ),
                ),
              Positioned.fill(child: body),
              Positioned(
                left: railColumn,
                right: 0,
                bottom: -HermesAppBar.veilTail,
                height: HermesAppBar.veilTail,
                child: DecoratedBox(
                  key: const ValueKey('hermes-app-bar-veil-tail'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        color.withValues(alpha: foot),
                        color.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FloatingLeading extends StatelessWidget {
  const _FloatingLeading({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final chrome = HermesChrome.ofContext(context);
    return Center(
      child: HermesFloatingIconButton.gel(
        Stack(
          alignment: Alignment.center,
          children: [
            HermesFloatingIconButton.shadow(chrome),
            IconButtonTheme(
              key: const ValueKey('hermes-app-bar-leading'),
              data: IconButtonThemeData(
                style: HermesAppBar.roundButtonStyle(
                  chrome,
                  fill: HermesGlassStrip.of(context)?.veil,
                ),
              ),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

/// The page's name as plain text at the start of the bar. A state badge
/// (read only, the scope the page is limited to) still follows it: moving the
/// name out of the pill must not take the mark of what matters with it.
class _PlainTitle extends StatelessWidget {
  const _PlainTitle({required this.child, this.badge});

  final Widget child;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    // One line, whatever the page passes: a long name is cut, not wrapped.
    final name = DefaultTextStyle.merge(
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      child: child,
    );
    return KeyedSubtree(
      key: const ValueKey('hermes-app-bar-plain-title'),
      child: badge == null
          ? name
          : LayoutBuilder(
              // The badge never runs past the bar: it gets what is left of
              // the title's least and adapts to it, as it did in the pill.
              builder: (context, constraints) {
                final room = _TitlePill._badgeRoom(constraints.maxWidth);
                if (room < 1) return name;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: name),
                    const SizedBox(width: _TitlePill._badgeGap),
                    KeyedSubtree(
                      key: const ValueKey('hermes-app-bar-title-badge'),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: room),
                        child: badge!,
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _TitlePill extends StatelessWidget {
  const _TitlePill({required this.child, this.badge});

  static const double _badgeGap = 8;

  /// The least the title keeps: a word and its ellipsis. QA 9709: on the
  /// open Fold's list column the title went down to nothing and the pill
  /// was left empty around the connection dot.
  static const double minTitleWidth = HermesSpace.tap;

  /// What the badge may take of [width]: all but the gap and the title's
  /// least. The badge never runs past the pill (gint51), and the title is
  /// never squeezed out of it: a pill always says what it is.
  static double _badgeRoom(double width) {
    if (width == double.infinity) return width;
    final room = width - _badgeGap - math.min(minTitleWidth, width);
    return room < 0 ? 0 : room;
  }

  final Widget child;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    // One line, whatever the page passes: a long name is cut, not wrapped.
    final name = DefaultTextStyle.merge(
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      child: child,
    );
    return HermesFloatingSurface(
      key: const ValueKey('hermes-app-bar-title'),
      keepTextStyle: true,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      // As tall as the buttons beside it: the header reads as one row.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: HermesAppBar.pieceSize),
        child: Align(
          widthFactor: 1,
          heightFactor: 1,
          child: badge == null
              ? name
              : LayoutBuilder(
                  // The badge never runs past the pill: it gets what is left
                  // and adapts to it (gint51: a read-only badge overflowed
                  // by 32 dp).
                  builder: (context, constraints) {
                    final room = _badgeRoom(constraints.maxWidth);
                    // No room for the badge beside the title's least: the
                    // title alone, never an empty pill around the badge.
                    if (room < 1) return name;
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(child: name),
                        const SizedBox(width: _badgeGap),
                        KeyedSubtree(
                          key: const ValueKey('hermes-app-bar-title-badge'),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: room),
                            child: badge!,
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }
}

/// A word inside the title pill: the scope a page is limited to (a bot's
/// profile, an organisation). Compact, one line, cut when long.
class HermesTitleBadge extends StatelessWidget {
  const HermesTitleBadge(this.label, {this.semanticsLabel, super.key});

  final String label;

  /// What a screen reader says instead of the bare word.
  final String? semanticsLabel;

  /// How much of the chrome's ink tints the badge.
  static const double tintOpacity = 0.08;

  /// The badge's ink for [colors]: the chrome's muted ink, moved just as
  /// far as AA (4.5) needs over its tint on every surface it can sit on:
  /// the chrome of before ([HermesChrome.opaque]), and the header's glass
  /// over the worst page and over its own (REVIEW-Q9-CRISTAL C1; the dark
  /// themes fell short even before the glass). One ink for all of them, so
  /// the badge does not change as its header goes in or out of glass.
  static Color inkFor(HermesThemeColors colors) =>
      _ink[colors] ??= _resolveInk(colors);

  static final Expando<Color> _ink = Expando<Color>('HermesTitleBadge');

  /// [inkFor] moved, if it must, just as far as AA (4.5) needs over the
  /// header's band at its worst ([HermesAppBar.bandUnder]) and the badge's own
  /// tint: a title's badge has no piece of its own, it sits on the band. Only
  /// ever towards more contrast, so everything [inkFor] reads on still reads.
  static Color inkOnBand(HermesThemeColors colors) =>
      _bandInk[colors] ??= _resolveBandInk(colors);

  static final Expando<Color> _bandInk = Expando<Color>('HermesTitleBadgeBand');

  static Color _resolveInk(HermesThemeColors colors) {
    final chrome = HermesChrome.of(colors);
    final tint = chrome.ink.withValues(alpha: tintOpacity);
    Color on(Color under) => ThemeContrast.composite(tint, under);
    final under = [
      on(chrome.opaque),
      on(HermesGlassStrip.worstUnder(colors)),
      on(HermesGlassStrip.ownUnder(colors)),
    ];
    return ThemeContrast.adjustForContrast(
      chrome.mutedInk,
      under,
      minimum: 4.5,
    );
  }

  static Color _resolveBandInk(HermesThemeColors colors) {
    final chrome = HermesChrome.of(colors);
    final tint = chrome.ink.withValues(alpha: tintOpacity);
    final under = ThemeContrast.composite(
      tint,
      HermesAppBar.bandUnder(colors, HermesAppBar.bandAlpha(colors)),
    );
    // Towards the ink's own side only (white on a dark page, black on a
    // light one): never across, so the chrome it already reads on keeps it.
    final start = inkFor(colors);
    final end = chrome.dark ? Colors.white : Colors.black;
    for (var step = 0; step <= 50; step++) {
      final ink = ThemeContrast.blend(start, end, step / 50);
      if (ThemeContrast.ratio(ink, under) >= HermesAppBar.bandContrast) {
        return ink;
      }
    }
    return end;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    return Container(
      constraints: const BoxConstraints(maxWidth: 104),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: ShapeDecoration(
        color: chrome.ink.withValues(alpha: tintOpacity),
        shape: StadiumBorder(side: BorderSide(color: chrome.line)),
      ),
      child: Text(
        label,
        semanticsLabel: semanticsLabel,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          height: 1.25,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
          color: inkOnBand(colors),
        ),
      ),
    );
  }
}

/// The actions of the header: icon actions together in one pill, anything
/// else as it came.
class _FloatingActions extends StatelessWidget {
  const _FloatingActions({required this.actions, required this.max});

  final List<Widget> actions;
  final int max;

  static Widget _core(Widget widget) {
    var current = widget;
    while (true) {
      final Widget? child = switch (current) {
        Padding(:final child) => child,
        Semantics(:final child) => child,
        KeyedSubtree(:final child) => child,
        Tooltip(:final child) => child,
        Center(:final child) => child,
        _ => null,
      };
      if (child == null) return current;
      current = child;
    }
  }

  static bool _inPill(Widget widget) {
    final core = _core(widget);
    return core is IconButton ||
        core is HermesMenuButton ||
        core is ScreenHelpButton;
  }

  /// What the "more" menu can stand in for: an icon button with a name, a
  /// plain icon and something to do, or the screen's help.
  static _Movable? _movable(BuildContext context, Widget widget) {
    final core = _core(widget);
    if (core is ScreenHelpButton) {
      return _Movable(
        label:
            Localizations.of<Strings>(context, Strings)?.kanbanHelpTooltip ??
            '?',
        icon: Icons.help_outline_rounded,
        help: true,
        run: () => showScreenHelp(
          context,
          paragraphs: core.paragraphs,
          title: core.title,
          helpKey: core.helpKey,
        ),
      );
    }
    if (core is IconButton) {
      final icon = core.icon;
      final label = core.tooltip ?? '';
      if (icon is Icon && icon.icon != null && label.isNotEmpty) {
        return _Movable(label: label, icon: icon.icon!, run: core.onPressed);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final groups = <Widget>[];
    var run = <Widget>[];
    void flush() {
      if (run.isEmpty) return;
      groups.add(_ActionsPill(actions: run, max: max));
      run = <Widget>[];
    }

    for (final action in actions) {
      if (_inPill(action)) {
        run.add(action);
      } else {
        flush();
        groups.add(action);
      }
    }
    final endsInPill = run.isNotEmpty;
    flush();
    return Padding(
      padding: EdgeInsetsDirectional.only(end: endsInPill ? 8 : 0),
      child: Row(mainAxisSize: MainAxisSize.min, children: groups),
    );
  }
}

/// An action as an entry of the "more" menu.
class _Movable {
  const _Movable({
    required this.label,
    required this.icon,
    required this.run,
    this.help = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? run;

  /// The screen's help: the first one to leave the pill.
  final bool help;
}

class _ActionsPill extends StatelessWidget {
  const _ActionsPill({required this.actions, required this.max});

  final List<Widget> actions;
  final int max;

  @override
  Widget build(BuildContext context) {
    final chrome = HermesChrome.ofContext(context);
    var shown = actions;
    var more = const <_Movable>[];
    if (actions.length > max) {
      // What cannot be named in a menu stays. Of the rest, the first ones
      // keep their place (the help last of all) and the others go behind
      // "more".
      final entries = [
        for (final action in actions)
          _FloatingActions._movable(context, action),
      ];
      final fixed = entries.where((e) => e == null).length;
      final room = (max - 1 - fixed).clamp(0, max);
      final order = [
        for (var i = 0; i < entries.length; i++)
          if (entries[i] != null && !entries[i]!.help) i,
        for (var i = 0; i < entries.length; i++)
          if (entries[i] != null && entries[i]!.help) i,
      ];
      final stay = order.take(room).toSet();
      final moved = [
        for (var i = 0; i < entries.length; i++)
          if (entries[i] != null && !stay.contains(i)) entries[i]!,
      ];
      if (moved.length > 1) {
        shown = [
          for (var i = 0; i < actions.length; i++)
            if (entries[i] == null || stay.contains(i)) actions[i],
        ];
        more = moved;
      }
    }
    return SizedBox(
      height: 48,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: (48 - HermesAppBar.pieceSize) / 2,
            bottom: (48 - HermesAppBar.pieceSize) / 2,
            child: const HermesFloatingSurface(
              key: ValueKey('hermes-app-bar-actions'),
              // The capsule's gel: its sheen over the one blur of the strip.
              child: HermesGelSurface(
                shape: StadiumBorder(),
                pressable: false,
                child: SizedBox.expand(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: IconButtonTheme(
              data: IconButtonThemeData(
                style: IconButton.styleFrom(
                  foregroundColor: chrome.ink,
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [...shown, if (more.isNotEmpty) _MoreButton(more)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MoreButton extends StatelessWidget {
  const _MoreButton(this.actions);

  final List<_Movable> actions;

  @override
  Widget build(BuildContext context) {
    final enabled = [
      for (final action in actions)
        if (action.run != null) action,
    ];
    return IconButton(
      key: const ValueKey('hermes-app-bar-more'),
      tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
      icon: const Icon(Icons.more_horiz_rounded),
      onPressed: enabled.isEmpty
          ? null
          : () async {
              final picked = await showHermesMenu<int>(
                context: context,
                surfaceKey: const ValueKey('hermes-app-bar-more-menu'),
                actions: [
                  for (var i = 0; i < enabled.length; i++)
                    HermesAction(
                      value: i,
                      label: enabled[i].label,
                      icon: enabled[i].icon,
                    ),
                ],
              );
              if (picked != null) enabled[picked].run?.call();
            },
    );
  }
}
