import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../theme/readable_ink.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/dock_scroll_clearance.dart';

/// Page scaffold: one-line app-bar title (left, title style) + ONE vertical
/// page scroll with the reference padding. Never `title: Column`.
class HermesPage extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final Future<void> Function()? onRefresh;
  final ScrollController? controller;
  final Widget? floatingActionButton;

  final Key? listKey;

  /// Extra bottom inset (for example a floating dock).
  final double bottomInset;

  /// Wraps the scrolling body inside the page's scaffold, for pages that sit
  /// on a shell of their own (the General dock).
  final Widget Function(Widget body)? wrapBody;

  const HermesPage({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.onRefresh,
    this.controller,
    this.floatingActionButton,
    this.listKey,
    this.bottomInset = 0,
    this.wrapBody,
  });

  @override
  Widget build(BuildContext context) {
    final originalSafeBottom = MediaQuery.paddingOf(context).bottom;
    final list = Builder(
      builder: (context) {
        final dockClearance = DockScrollClearance.maybeOf(context);
        final bottom = dockClearance == null
            ? bottomInset + originalSafeBottom
            : dockClearance + MediaQuery.paddingOf(context).bottom;
        final scroll = ListView(
          key: listKey,
          controller: controller,
          clipBehavior: hermesUnderHeader,
          padding: EdgeInsets.fromLTRB(
            HermesSpace.pageH,
            HermesSpace.pageTop,
            HermesSpace.pageH,
            HermesSpace.pageBottom + bottom,
          ),
          children: children,
        );
        return onRefresh == null
            ? scroll
            : RefreshIndicator(onRefresh: onRefresh!, child: scroll);
      },
    );
    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: actions,
      ),
      floatingActionButton: floatingActionButton,
      body: wrapBody == null
          ? SafeArea(top: false, bottom: false, child: list)
          : wrapBody!(SafeArea(top: false, bottom: false, child: list)),
    );
  }
}

/// Action-first detail page (Bot profile pattern): display title, inline
/// status, optional short reason, one primary CTA (+ one secondary), then
/// sections — all in ONE page scroll. The title moves into the app bar once
/// the hero title scrolls under it.
class HermesDetailScaffold extends StatefulWidget {
  /// App-bar title while the hero is visible (usually empty or generic).
  final String? appBarTitle;
  final String title;

  /// Subtle line above the title (for example the owner bot).
  final Widget? eyebrow;
  final Widget? status;
  final String? reason;
  final Widget? primaryAction;
  final Widget? secondaryAction;
  final List<Widget> sections;
  final List<Widget>? actions;
  final Future<void> Function()? onRefresh;
  final Key? listKey;

  const HermesDetailScaffold({
    super.key,
    required this.title,
    required this.sections,
    this.appBarTitle,
    this.eyebrow,
    this.status,
    this.reason,
    this.primaryAction,
    this.secondaryAction,
    this.actions,
    this.onRefresh,
    this.listKey,
  });

  @override
  State<HermesDetailScaffold> createState() => _HermesDetailScaffoldState();
}

class _HermesDetailScaffoldState extends State<HermesDetailScaffold> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _titleKey = GlobalKey(debugLabel: 'hermes-detail-title');
  bool _titleInAppBar = false;
  bool _checkScheduled = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted) return;
      final ctx = _titleKey.currentContext;
      final box = ctx?.findRenderObject();
      final viewport = ctx == null
          ? null
          : Scrollable.maybeOf(ctx)?.context.findRenderObject();
      bool hidden;
      if (box is RenderBox &&
          box.attached &&
          box.hasSize &&
          viewport is RenderBox &&
          viewport.hasSize) {
        final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
        hidden = bottom <= viewport.localToGlobal(Offset.zero).dy;
      } else {
        hidden = _scroll.hasClients && _scroll.offset > 0;
      }
      if (hidden != _titleInAppBar) setState(() => _titleInAppBar = hidden);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final ctas = <Widget>[
      if (widget.primaryAction != null) Expanded(child: widget.primaryAction!),
      if (widget.primaryAction != null && widget.secondaryAction != null)
        const SizedBox(width: HermesSpace.x2),
      if (widget.secondaryAction != null)
        Expanded(child: widget.secondaryAction!),
    ];
    Widget list = ListView(
      key: widget.listKey,
      controller: _scroll,
      clipBehavior: hermesUnderHeader,
      padding: EdgeInsets.fromLTRB(
        HermesSpace.pageH,
        HermesSpace.x1,
        HermesSpace.pageH,
        HermesSpace.pageBottom + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        if (widget.eyebrow != null)
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: widget.eyebrow!,
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 2, top: 6),
          child: Semantics(
            header: true,
            child: Text(
              widget.title,
              key: _titleKey,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: HermesType.display.copyWith(color: colors.textPrimary),
            ),
          ),
        ),
        if (widget.status != null) ...[
          const SizedBox(height: HermesSpace.x1),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: widget.status!,
            ),
          ),
        ],
        if (widget.reason != null && widget.reason!.isNotEmpty) ...[
          const SizedBox(height: HermesSpace.x2),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              widget.reason!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
        if (ctas.isNotEmpty) ...[
          const SizedBox(height: 14),
          Row(children: ctas),
        ],
        ...widget.sections,
      ],
    );
    if (widget.onRefresh != null) {
      list = RefreshIndicator(onRefresh: widget.onRefresh!, child: list);
    }
    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(
          _titleInAppBar ? widget.title : (widget.appBarTitle ?? ''),
          key: ValueKey(
            _titleInAppBar
                ? 'hermes-detail-appbar-title'
                : 'hermes-detail-appbar',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: widget.actions,
      ),
      body: SafeArea(top: false, bottom: false, child: list),
    );
  }
}

/// Primary (filled) and secondary (tonal) CTA buttons of the detail header:
/// radius 12, 48 dp, equal width.
class HermesActionButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;

  const HermesActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(HermesRadius.control),
    );
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 6)],
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
    // Keep the theme family (Inter): a bare TextStyle drops it.
    final textStyle =
        (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        );
    if (primary) {
      return FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(HermesSpace.tap),
          shape: shape,
          backgroundColor: colors.accent,
          foregroundColor: colors.onAccent,
          textStyle: textStyle,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: child,
      );
    }
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size.fromHeight(HermesSpace.tap),
        shape: shape,
        backgroundColor: colors.surfaceVariant.withValues(alpha: .5),
        foregroundColor: colors.textPrimary,
        textStyle: textStyle,
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      child: child,
    );
  }
}

/// An action as a glass pill (the owner, style 1 of the action buttons: «Detener»,
/// «Reintentar», «Abrir conversación»): the language of the turn's pills,
/// 34 dp tall on a 48 dp target, the chrome's raised surface and its
/// hairline, icon and words. No coloured fill: colour goes only on the icon
/// and the words, and only when [destructive] (the theme's error colour).
/// Pressed, the surface takes the ink's overlay; disabled, the muted ink.
class HermesGlassActionButton extends StatelessWidget {
  const HermesGlassActionButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.destructive = false,
    super.key,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool destructive;

  /// How tall the pill looks; its target is [HermesSpace.tap].
  static const double height = 34;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    // REVIEW-Q9-VENT P2-1: the error's red made readable (4.5:1) on the
    // pill, its hue kept.
    final ink = destructive
        ? readableInkOnTint(colors.error, chrome.raised, colors)
        : chrome.ink;
    // Keep the theme family (Inter): a bare TextStyle drops it.
    final textStyle =
        (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
          fontSize: HermesType.valueSize,
          fontWeight: FontWeight.w600,
        );
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(HermesSpace.tap, height),
        tapTargetSize: MaterialTapTargetSize.padded,
        padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x4),
        shape: StadiumBorder(side: BorderSide(color: chrome.line)),
        backgroundColor: chrome.raised,
        foregroundColor: ink,
        disabledForegroundColor: chrome.mutedInk,
        disabledBackgroundColor: chrome.raised,
        textStyle: textStyle,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon case final glyph?) ...[
            Icon(glyph, size: HermesIcon.sm),
            const SizedBox(width: HermesSpace.x2),
          ],
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
