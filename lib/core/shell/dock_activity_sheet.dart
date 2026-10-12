import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/app_localizations.dart';
import '../home/board/home_board_data.dart';
import '../theme/app_theme.dart';
import '../design/modal.dart';

/// What the dock's "Actividad" sheet shows: the same summary as Home's
/// «De un vistazo» widget (what is running, what needs you, what you have
/// not read), published by Home every time its board data changes, plus
/// Home's own way to open each row. The sheet holds no dock destination:
/// those are on the dock already.
class DockActivityFeed extends ChangeNotifier {
  DockActivityFeed();

  static final DockActivityFeed instance = DockActivityFeed();

  HomeGlance _glance = HomeGlance.empty;
  void Function(HomeGlanceItem item)? _open;
  Object? _owner;

  HomeGlance get glance => _glance;

  /// Opens [item] the way Home does; null until Home published.
  void Function(HomeGlanceItem item)? get open => _open;

  /// Home publishes its summary and its opener.
  void publish(
    Object owner,
    HomeGlance glance,
    void Function(HomeGlanceItem item) open,
  ) {
    _owner = owner;
    _open = open;
    if (identical(glance, _glance)) return;
    _glance = glance;
    _notify();
  }

  /// Home publishes while it builds; listeners hear it after the frame.
  void _notify() {
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      scheduler.addPostFrameCallback((_) => notifyListeners());
      scheduler.ensureVisualUpdate();
    } else {
      notifyListeners();
    }
  }

  /// Home left (connection switch, dispose).
  void clear(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _open = null;
    _glance = HomeGlance.empty;
    _notify();
  }

  @visibleForTesting
  void resetForTesting() {
    _owner = null;
    _open = null;
    _glance = HomeGlance.empty;
  }
}

/// Opens the "Actividad" sheet (swipe up on the dock, its optional
/// destination, the long-press menu entry).
Future<void> showDockActivitySheet(
  BuildContext context, {
  DockActivityFeed? feed,
}) =>
    // The one floating modal surface (spec 080): never a bottom sheet.
    showHermesSurface<void>(
      context: context,
      surfaceKey: const ValueKey('dock-activity-surface'),
      maxHeightFactor: 0.8,
      builder: (_) =>
          DockActivitySheet(feed: feed ?? DockActivityFeed.instance),
    );

class DockActivitySheet extends StatelessWidget {
  final DockActivityFeed feed;

  const DockActivitySheet({required this.feed, super.key});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return ListenableBuilder(
      listenable: feed,
      builder: (context, _) {
        final g = feed.glance;
        final sections = [
          if (g.next.isNotEmpty)
            ('next', strings.hwKindGlance, g.next, colors.warning),
          if (g.running.isNotEmpty)
            ('running', strings.statusRunning, g.running, colors.accent),
        ];
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .7,
          ),
          child: ListView(
            key: const ValueKey('dock-activity-sheet'),
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  strings.gdActivityTitle,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (sections.isEmpty)
                ListTile(
                  key: const ValueKey('dock-activity-calm'),
                  leading: Icon(
                    Icons.check_circle_outline_rounded,
                    color: colors.success,
                  ),
                  title: Text(strings.hwGlanceCalm),
                  subtitle: Text(strings.hwNextNothingRunning),
                ),
              for (final (id, label, items, color) in sections) ...[
                Padding(
                  key: ValueKey('dock-activity-$id'),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
                  child: Text(
                    '$label · ${items.length}',
                    style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (final item in items)
                  ListTile(
                    key: ValueKey('dock-activity-item-${item.key}'),
                    leading: Icon(_iconOf(item.kind), color: color),
                    title: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: item.detail == null
                        ? null
                        : Text(
                            item.detail!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: item.count > 0 ? Text('${item.count}') : null,
                    onTap: feed.open == null
                        ? null
                        : () {
                            final open = feed.open!;
                            Navigator.of(context).pop();
                            open(item);
                          },
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  static IconData _iconOf(HomeGlanceKind kind) => switch (kind) {
    HomeGlanceKind.runningChat ||
    HomeGlanceKind.failedChat ||
    HomeGlanceKind.finished => Icons.chat_bubble_outline_rounded,
    HomeGlanceKind.runningBot ||
    HomeGlanceKind.botWaiting => Icons.smart_toy_outlined,
    HomeGlanceKind.runningRoom ||
    HomeGlanceKind.failedRoom ||
    HomeGlanceKind.roomNews ||
    HomeGlanceKind.roomReplies => Icons.groups_2_outlined,
    HomeGlanceKind.approval => Icons.verified_user_outlined,
    HomeGlanceKind.question => Icons.help_outline_rounded,
    HomeGlanceKind.failedAutomation => Icons.error_outline_rounded,
    HomeGlanceKind.pausedQueue => Icons.pause_circle_outline_rounded,
  };
}
