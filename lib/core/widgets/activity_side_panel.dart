import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import 'activity_panel.dart';
import 'activity_pill.dart';

/// Hosts the chat's activity panel as a persistent side panel on tablets.
///
/// Wraps the whole chat screen (header, transcript, approvals, composer), so
/// the panel sits beside all of it and covers none of it. When the window is
/// expanded (>= 840dp, by size only) AND this chat is wide enough to keep a
/// [Responsive.minChatColumnWidth] column beside a
/// [Responsive.activitySidePanelWidth] panel, the activity pill opens the
/// panel here, on the right, instead of the modal that grows out of the
/// pill. The panel is not modal: the conversation, the approvals and the
/// composer keep working beside it. It closes with its close button, with
/// the pill, or by itself when nothing is live any more.
///
/// Phones, medium windows and narrow chats (a chat beside the list pane on a
/// small tablet) keep the modal. The open state survives a rotation: the
/// panel hides while there is no room and comes back when there is.
class ActivitySidePanelHost extends StatefulWidget {
  final Widget child;

  const ActivitySidePanelHost({required this.child, super.key});

  /// The host around [context], if any. Does not create a dependency.
  static ActivitySidePanelHostState? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_SidePanelScope>()?.state;

  @override
  State<ActivitySidePanelHost> createState() => ActivitySidePanelHostState();
}

class ActivitySidePanelHostState extends State<ActivitySidePanelHost> {
  final ValueNotifier<ActivityPanelState?> _state = ValueNotifier(null);
  Object? _owner;
  DateTime Function()? _clock;
  bool _fits = false;

  /// Whether the last layout had room for the side panel.
  bool get fits => _fits;

  /// Whether [owner] has the panel open (shown or waiting for room).
  bool isOpenFor(Object owner) => _owner != null && identical(_owner, owner);

  void open({
    required Object owner,
    required ActivityPanelState state,
    DateTime Function()? clock,
  }) {
    _state.value = state;
    setState(() {
      _owner = owner;
      _clock = clock;
    });
  }

  /// New live state from the owner of the open panel.
  void update(Object owner, ActivityPanelState state) {
    if (isOpenFor(owner)) _state.value = state;
  }

  void close(Object owner) {
    if (!isOpenFor(owner)) return;
    setState(_clear);
  }

  /// The owner is going away (its chat closes): drop the panel without
  /// rebuilding now, the tree may be locked.
  void release(Object owner) {
    if (!isOpenFor(owner)) return;
    _clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _clear() {
    _owner = null;
    _clock = null;
    _state.value = null;
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expanded = Responsive.isExpanded(context);
    return _SidePanelScope(
      state: this,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _fits =
              expanded &&
              constraints.maxWidth >=
                  Responsive.activitySidePanelWidth +
                      Responsive.minChatColumnWidth;
          final show = _fits && _owner != null && _state.value != null;
          final owner = _owner;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: widget.child),
              if (show) ...[
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Theme.of(context).hermes.divider,
                ),
                SizedBox(
                  key: const ValueKey('activity-side-panel'),
                  width: Responsive.activitySidePanelWidth,
                  child: _ActivitySidePanel(
                    state: _state,
                    clock: _clock,
                    onClose: () {
                      if (owner != null) close(owner);
                    },
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SidePanelScope extends InheritedWidget {
  final ActivitySidePanelHostState state;

  const _SidePanelScope({required this.state, required super.child});

  @override
  bool updateShouldNotify(_SidePanelScope oldWidget) =>
      state != oldWidget.state;
}

class _ActivitySidePanel extends StatelessWidget {
  final ValueListenable<ActivityPanelState?> state;
  final DateTime Function()? clock;
  final VoidCallback onClose;

  const _ActivitySidePanel({
    required this.state,
    required this.clock,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final lang = Localizations.localeOf(context).languageCode;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: strings.liveActivityTitle,
      child: Material(
        color: colors.surface,
        child: SafeArea(
          left: false,
          child: ActivityTicker(
            active: true,
            clock: clock,
            builder: (context, now) =>
                ValueListenableBuilder<ActivityPanelState?>(
                  valueListenable: state,
                  builder: (context, current, _) {
                    final model = current == null
                        ? null
                        : buildActivityPillModel(
                            current.snapshot,
                            strings,
                            now: now,
                            languageCode: lang,
                            revealAfter: Duration.zero,
                          );
                    if (current == null || model == null) {
                      // Nothing live: the panel retires, like the modal.
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => onClose(),
                      );
                      return const SizedBox.shrink();
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                          child: ActivityCardTitleRow(
                            closeKey: const ValueKey(
                              'activity-side-panel-close',
                            ),
                            onClose: onClose,
                          ),
                        ),
                        ExcludeSemantics(
                          child: ActivityPillRow(
                            model: model,
                            now: now,
                            fill: true,
                          ),
                        ),
                        Divider(height: 1, thickness: 1, color: colors.divider),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            child: ActivityPanelBody(
                              snapshot: current.snapshot,
                              actions: current.actions,
                              now: now,
                            ),
                          ),
                        ),
                        // dc1215: not modal, so the composer actions keep
                        // the panel open beside the chat.
                        ?activityActionsBarFor(
                          current.snapshot,
                          current.actions,
                        ),
                      ],
                    );
                  },
                ),
          ),
        ),
      ),
    );
  }
}
