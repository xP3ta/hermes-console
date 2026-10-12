import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../design/floating.dart';
import '../design/modal.dart'
    show HermesAction, HermesMenuButton, showHermesMenu;
import '../design/tokens.dart';
import '../feedback/screen_help.dart' show ScreenHelpButton, showScreenHelp;
import '../theme/app_theme.dart';

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
///  * a gradient of the page colour behind the pieces keeps them and the
///    status bar readable over rows passing underneath. Nothing is blurred
///    and nothing listens to the scroll.
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
    this.titleInPill = true,
    this.actionsInPill = true,
    this.floatingLeading = true,
    this.scrim = true,
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

  /// False leaves the title as plain text at the start of the bar, for a
  /// page that never scrolls anything under its header.
  final bool titleInPill;

  /// False leaves the actions as they come, for ones that are already
  /// floating pieces of their own (no chrome around chrome).
  final bool actionsInPill;

  /// False leaves the leading control a plain icon.
  final bool floatingLeading;

  /// False paints no scrim: a page that never scrolls under its header has
  /// nothing to keep away from it.
  final bool scrim;

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
  static const double scrimTail = 20;

  @override
  Size get preferredSize => Size.fromHeight(
    (toolbarHeight ?? kToolbarHeight) + (bottom?.preferredSize.height ?? 0.0),
  );

  /// The round floating look of the leading button (48 dp target).
  static ButtonStyle roundButtonStyle(HermesChrome chrome) =>
      HermesFloatingIconButton.style(chrome);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final chrome = HermesChrome.of(colors);
    final resolvedTitle = colors.uppercaseTitles
        ? _applyUppercase(title)
        : title;
    final page = backgroundColor ?? theme.scaffoldBackgroundColor;
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
          fontSize: 14.5,
          fontWeight: FontWeight.w700,
        );
    final shown = actions ?? const <Widget>[];
    // One layer for the whole header: rows scrolling under it repaint their
    // own layer only.
    return RepaintBoundary(
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
            : resolvedTitle,
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
        flexibleSpace: scrim ? _HeaderScrim(color: page) : null,
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

/// The scrim behind the floating pieces: the page colour, dense over the
/// status bar and gone [HermesAppBar.scrimTail] below the header.
class _HeaderScrim extends StatelessWidget {
  const _HeaderScrim({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final statusBar = MediaQuery.paddingOf(context).top;
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final extent = constraints.maxHeight + HermesAppBar.scrimTail;
          final statusStop = extent.isFinite && extent > 0
              ? (statusBar / extent).clamp(0.0, 0.6)
              : 0.0;
          return Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
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
      child: Stack(
        alignment: Alignment.center,
        children: [
          HermesFloatingIconButton.shadow(chrome),
          IconButtonTheme(
            key: const ValueKey('hermes-app-bar-leading'),
            data: IconButtonThemeData(
              style: HermesAppBar.roundButtonStyle(chrome),
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _TitlePill extends StatelessWidget {
  const _TitlePill({required this.child, this.badge});

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
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: name),
                    const SizedBox(width: 8),
                    KeyedSubtree(
                      key: const ValueKey('hermes-app-bar-title-badge'),
                      child: badge!,
                    ),
                  ],
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

  @override
  Widget build(BuildContext context) {
    final chrome = HermesChrome.ofContext(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 104),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: ShapeDecoration(
        color: chrome.ink.withValues(alpha: 0.08),
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
          color: chrome.mutedInk,
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
              child: SizedBox.expand(),
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
