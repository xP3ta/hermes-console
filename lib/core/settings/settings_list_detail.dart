import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../utils/responsive.dart';
import 'settings_deep_link.dart';
import 'settings_sections.dart';

/// Settings laid out for the window size.
///
///  * compact and medium: the single long [list] (the phone layout).
///  * expanded (>= 840dp): the categories in a
///    [Responsive.settingsCategoryPaneWidth] pane on the left and the selected
///    category's rows on the right. The right pane is a nested [Navigator]:
///    the rows' own `Navigator.push` calls open their pages inside it, so
///    picking a category or opening a page never pushes an app route. Back
///    closes the open page first, then leaves Settings.
///
/// One source of truth for the selected category: this widget's state, which
/// survives rotation (the layout switch happens below it). A
/// [SettingsDeepLink] request selects its category in the right pane. A page
/// left open in the pane when the window shrinks stays open full width until
/// Back closes it.
class SettingsListDetail extends StatefulWidget {
  /// The rows of one category, built with the context they are shown in.
  final List<Widget> Function(BuildContext context, SettingsSection section)
  rowsFor;

  /// The phone layout: every category in one scrollable list.
  final Widget Function(BuildContext context, ScrollController scroll) list;

  /// Wraps the body in the screen's chrome (app bar, dock/rail).
  final Widget Function(BuildContext context, Widget body) scaffold;

  const SettingsListDetail({
    required this.rowsFor,
    required this.list,
    required this.scaffold,
    super.key,
  });

  @override
  State<SettingsListDetail> createState() => SettingsListDetailState();
}

class SettingsListDetailState extends State<SettingsListDetail> {
  final GlobalKey<NavigatorState> _paneKey = GlobalKey<NavigatorState>(
    debugLabel: 'settings-detail-navigator',
  );
  late final _PaneDepth _depth = _PaneDepth(_onDepth);

  SettingsSection _selected = SettingsSection.values.first;

  /// Pages open above the selected category in the right pane.
  int _pages = 0;

  /// The category shown on the right in expanded windows.
  SettingsSection get selected => _selected;

  void select(SettingsSection section) {
    if (_selected != section) setState(() => _selected = section);
    _paneKey.currentState?.popUntil((route) => route.isFirst);
  }

  void _onDepth(int pages) {
    if (_pages == pages) return;
    void apply() {
      if (mounted) setState(() => _pages = pages);
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _pages = pages;
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDeepLinkScope(
      sections: SettingsSection.values.toSet(),
      onReveal: select,
      builder: (context, scroll) =>
          widget.scaffold(context, _body(context, scroll)),
    );
  }

  Widget _pane() => KeyedSubtree(
    key: const ValueKey('settings-detail-pane'),
    child: HeroControllerScope.none(
      child: Navigator(
        key: _paneKey,
        observers: [_depth],
        onGenerateInitialRoutes: (_, _) {
          // A fresh navigator (the pane was rebuilt after a rotation): its
          // routes are new, forget the old ones.
          _depth.reset();
          return [
            PageRouteBuilder<void>(
              settings: const RouteSettings(name: 'settings-category'),
              pageBuilder: (_, _, _) =>
                  const CoveredRouteMediaQueryFreeze(child: _CategoryPage()),
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
            ),
          ];
        },
      ),
    ),
  );

  Widget _body(BuildContext context, ScrollController scroll) {
    final expanded = Responsive.isExpanded(context);
    final Widget layout;
    if (expanded) {
      layout = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            key: const ValueKey('settings-categories'),
            width: Responsive.settingsCategoryPaneWidth,
            child: _Categories(selected: _selected, onSelect: select),
          ),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: Theme.of(context).hermes.divider,
          ),
          Expanded(child: _pane()),
        ],
      );
    } else {
      // The single list. A page still open from an expanded window covers it
      // until Back closes it; the list keeps its place underneath.
      final open = _pages > 0;
      layout = Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: open,
            child: TickerMode(
              enabled: !open,
              child: widget.list(context, scroll),
            ),
          ),
          if (open) _pane(),
        ],
      );
    }
    return _PaneScope(
      state: this,
      selected: _selected,
      expanded: expanded,
      child: PopScope(
        canPop: _pages == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _paneKey.currentState?.maybePop();
        },
        child: layout,
      ),
    );
  }
}

class _PaneScope extends InheritedWidget {
  final SettingsListDetailState state;
  final SettingsSection selected;
  final bool expanded;

  const _PaneScope({
    required this.state,
    required this.selected,
    required this.expanded,
    required super.child,
  });

  // The rows are rebuilt whenever Settings is (connection edits, profile
  // switches), like the phone list.
  @override
  bool updateShouldNotify(_PaneScope oldWidget) => true;
}

/// Root page of the right pane: the selected category's rows.
class _CategoryPage extends StatelessWidget {
  const _CategoryPage();

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_PaneScope>();
    // Below an open page in a single-list window this page is kept but not
    // shown; building its rows there would duplicate the list's sections.
    if (scope == null || !scope.expanded) return const SizedBox.shrink();
    final section = scope.selected;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Material(
        type: MaterialType.transparency,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: Responsive.maxContentWidth,
            ),
            child: ListView(
              key: ValueKey('settings-section-${section.name}'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: scope.state.widget.rowsFor(context, section),
            ),
          ),
        ),
      ),
    );
  }
}

class _Categories extends StatelessWidget {
  final SettingsSection selected;
  final ValueChanged<SettingsSection> onSelect;

  const _Categories({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final section in SettingsSection.values)
          _CategoryRow(
            section: section,
            title: settingsSectionTitle(strings, section),
            selected: section == selected,
            onTap: () => onSelect(section),
          ),
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final SettingsSection section;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryRow({
    required this.section,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  static IconData _icon(SettingsSection section) => switch (section) {
    SettingsSection.connection => Icons.dns_outlined,
    SettingsSection.appearance => Icons.palette_outlined,
    SettingsSection.chat => Icons.chat_bubble_outline_rounded,
    SettingsSection.voice => Icons.mic_none_rounded,
    SettingsSection.notifications => Icons.notifications_none_rounded,
    SettingsSection.security => Icons.shield_outlined,
    SettingsSection.system => Icons.settings_suggest_outlined,
    SettingsSection.bridge => Icons.sync_alt_rounded,
    SettingsSection.data => Icons.storage_rounded,
    SettingsSection.about => Icons.info_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final radius = BorderRadius.circular(12);
    return Padding(
      key: ValueKey('settings-category-${section.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected
              ? colors.accent.withValues(alpha: .14)
              : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      _icon(section),
                      size: 20,
                      color: selected ? colors.accent : colors.textSecondary,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: colors.textPrimary,
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
    );
  }
}

/// Counts the pages open above the category page of the right pane.
class _PaneDepth extends NavigatorObserver {
  final ValueChanged<int> onDepth;
  _PaneDepth(this.onDepth);

  final List<Route<dynamic>> _stack = [];

  /// Forgets the routes of a previous navigator.
  void reset() => _stack.clear();

  void _report() => onDepth(_stack.isEmpty ? 0 : _stack.length - 1);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _report();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _report();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _report();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index >= 0 && newRoute != null) _stack[index] = newRoute;
    _report();
  }
}
