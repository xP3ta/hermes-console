import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart' show CoveredRouteMediaQueryFreeze;
import 'gesture_dock.dart';
import 'gesture_dock_state.dart';

/// A damped spring: overshoots about 13 % around a third of the way in
/// and settles by the end, like the mockup's sheet.
class DockSpringCurve extends Curve {
  const DockSpringCurve();

  @override
  double transformInternal(double t) => 1 - math.exp(-7 * t) * math.cos(11 * t);
}

/// One recent chat offered by "Ir a".
@immutable
class GotoRecent {
  final String id;
  final String title;
  final String subtitle;
  final VoidCallback onOpen;

  const GotoRecent({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.onOpen,
  });
}

/// What "Ir a" can do on the current screen.
@immutable
class GotoSheetActions {
  final Future<List<GotoRecent>> Function() loadRecents;
  final VoidCallback? onNewChat;

  /// Opens the full chat list (search over every chat, not only recents).
  final VoidCallback? onSearchAll;
  final Map<GestureDockTab, VoidCallback?> places;
  final GestureDockTab? current;

  const GotoSheetActions({
    required this.loadRecents,
    required this.places,
    this.onNewChat,
    this.onSearchAll,
    this.current,
  });
}

/// Opens "Ir a": a sheet that grows out of [origin] (the dock) with a
/// spring, and closes back into it. No springs with reduced motion.
Future<void> showGotoSheet(
  BuildContext context, {
  required GotoSheetActions actions,
  Rect? origin,
  GestureDockController? controller,
}) async {
  final c = controller ?? GestureDockController.instance;
  final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final size = MediaQuery.sizeOf(context);
  final strings = Strings.of(context);
  final anchor = origin == null
      ? Alignment.bottomCenter
      : Alignment(
          (origin.center.dx / size.width) * 2 - 1,
          (origin.top / size.height) * 2 - 1,
        );
  c.sheetOpen = true;
  try {
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: true,
        barrierLabel: strings.gdGotoClose,
        barrierColor: const Color(0x73000000),
        transitionDuration: reduced
            ? Duration.zero
            : const Duration(milliseconds: 800),
        reverseTransitionDuration: reduced
            ? Duration.zero
            : const Duration(milliseconds: 340),
        pageBuilder: (context, _, _) =>
            CoveredRouteMediaQueryFreeze(child: GotoSheet(actions: actions)),
        transitionsBuilder: (context, animation, _, child) {
          if (reduced) return child;
          final scale = CurvedAnimation(
            parent: animation,
            curve: const DockSpringCurve(),
            reverseCurve: const Cubic(.45, 0, .2, 1),
          );
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: const Interval(0, .3),
            ),
            child: ScaleTransition(
              scale: Tween<double>(begin: .84, end: 1).animate(scale),
              alignment: anchor,
              child: child,
            ),
          );
        },
      ),
    );
  } finally {
    c.sheetOpen = false;
  }
}

class GotoSheet extends StatefulWidget {
  final GotoSheetActions actions;

  const GotoSheet({required this.actions, super.key});

  @override
  State<GotoSheet> createState() => _GotoSheetState();
}

class _GotoSheetState extends State<GotoSheet> {
  final TextEditingController _query = TextEditingController();
  List<GotoRecent>? _recents;
  double _dragDown = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    unawaited(_load());
  }

  Future<void> _load() async {
    List<GotoRecent> rows;
    try {
      rows = await widget.actions.loadRecents();
    } catch (_) {
      rows = const [];
    }
    if (mounted) setState(() => _recents = rows);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _go(VoidCallback? action) {
    if (action == null) return;
    Navigator.of(context).pop();
    action();
  }

  List<GotoRecent> get _visible {
    final all = _recents ?? const <GotoRecent>[];
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return all.take(3).toList();
    return all.where((r) => r.title.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final bottom = keyboard > 0
        ? keyboard + 12
        : gestureDockFootprint(context) + 4;
    final searching = _query.text.trim().isNotEmpty;
    final visible = _visible;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 48, 12, bottom),
        child: Material(
          key: const ValueKey('goto-sheet'),
          color: colors.surface,
          elevation: 12,
          borderRadius: BorderRadius.circular(28),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    button: true,
                    label: strings.gdGotoClose,
                    onTap: () => Navigator.of(context).pop(),
                    excludeSemantics: true,
                    child: GestureDetector(
                      key: const ValueKey('goto-sheet-grab'),
                      behavior: HitTestBehavior.opaque,
                      // Count the drag from the touch, slop included.
                      dragStartBehavior: DragStartBehavior.down,
                      onTap: () => Navigator.of(context).pop(),
                      onVerticalDragStart: (_) => _dragDown = 0,
                      onVerticalDragUpdate: (d) => _dragDown += d.delta.dy,
                      onVerticalDragEnd: (_) {
                        if (_dragDown > 26) Navigator.of(context).pop();
                      },
                      child: SizedBox(
                        height: 28,
                        child: Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: colors.textDisabled,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  TextField(
                    key: const ValueKey('goto-sheet-search'),
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) {
                      final first = visible.isEmpty ? null : visible.first;
                      _go(first?.onOpen ?? widget.actions.onSearchAll);
                    },
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      hintText: strings.gdGotoSearch,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (widget.actions.onNewChat != null)
                    FilledButton.icon(
                      key: const ValueKey('goto-sheet-new'),
                      onPressed: () => _go(widget.actions.onNewChat),
                      icon: const Icon(Icons.add_rounded),
                      label: Text(strings.gdGotoNewChat),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  _Label(
                    searching ? strings.gdGotoResults : strings.gdGotoRecents,
                  ),
                  if (_recents == null)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Center(
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else if (visible.isEmpty && searching)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        strings.gdGotoNoMatch,
                        style: TextStyle(color: colors.textSecondary),
                      ),
                    ),
                  for (final recent in visible)
                    ListTile(
                      key: ValueKey('goto-sheet-recent-${recent.id}'),
                      contentPadding: EdgeInsets.zero,
                      minTileHeight: 48,
                      leading: Icon(
                        Icons.chat_bubble_outline_rounded,
                        color: colors.textSecondary,
                      ),
                      title: Text(
                        recent.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(recent.subtitle),
                      onTap: () => _go(recent.onOpen),
                    ),
                  if (searching && widget.actions.onSearchAll != null)
                    ListTile(
                      key: const ValueKey('goto-sheet-search-all'),
                      contentPadding: EdgeInsets.zero,
                      minTileHeight: 48,
                      leading: Icon(
                        Icons.manage_search_rounded,
                        color: colors.accent,
                      ),
                      title: Text(strings.gdGotoAllChats),
                      onTap: () => _go(widget.actions.onSearchAll),
                    ),
                  _Label(strings.gdGotoPlaces),
                  Row(
                    children: [
                      for (final tab in const [
                        GestureDockTab.home,
                        GestureDockTab.projects,
                        GestureDockTab.settings,
                      ])
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: _PlaceTile(
                              tab: tab,
                              selected: widget.actions.current == tab,
                              onTap: widget.actions.places[tab] == null
                                  ? null
                                  : () => _go(widget.actions.places[tab]),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;

  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: 11,
          letterSpacing: 1.6,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PlaceTile extends StatelessWidget {
  final GestureDockTab tab;
  final bool selected;
  final VoidCallback? onTap;

  const _PlaceTile({required this.tab, required this.selected, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final icon = switch (tab) {
      GestureDockTab.home => Icons.home_outlined,
      GestureDockTab.projects => Icons.folder_outlined,
      _ => Icons.settings_outlined,
    };
    return Material(
      color: selected
          ? colors.accent.withValues(alpha: .14)
          : colors.surfaceVariant,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: ValueKey('goto-sheet-place-${tab.name}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: selected ? colors.accent : colors.textPrimary),
              const SizedBox(height: 4),
              Text(
                gestureDockTabLabel(strings, tab),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textPrimary, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
