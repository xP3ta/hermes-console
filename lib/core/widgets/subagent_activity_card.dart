import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'compact_pill_text.dart';
import '../models/subagent_activity.dart';
import '../theme/app_theme.dart';
import 'hermes_premium_ui.dart';

/// Display-safe result returned by the owner-scoped tail callback.
final class SubagentTailView {
  final bool available;
  final String content;
  final bool truncated;

  const SubagentTailView({
    required this.available,
    required this.content,
    required this.truncated,
  });
}

/// Display-safe disposition for a steering request.
final class SubagentSteerView {
  final String status;

  const SubagentSteerView({required this.status});

  bool get queued => status == 'queued';
}

typedef SubagentTailLoader =
    Future<SubagentTailView> Function(SubagentActivity activity);
typedef SubagentSteerSender =
    Future<SubagentSteerView> Function(SubagentActivity activity, String text);
typedef SubagentStopRequester =
    Future<bool> Function(SubagentActivity activity);
typedef SubagentTailScheduler =
    VoidCallback Function(Duration delay, VoidCallback callback);

/// Lets the unified activity panel open this card's detail/control surface
/// (tail, steer, stop, open conversation) without showing the card's own pill.
class SubagentActivityController {
  void Function(SubagentActivity? selected)? _opener;

  /// Opens the detail surface, preselecting [activity] when given.
  void open([SubagentActivity? activity]) => _opener?.call(activity);
}

/// Compact, bounded mobile control surface for delegated work.
class SubagentActivityCard extends StatefulWidget {
  final List<SubagentActivity> activities;
  final bool Function(SubagentActivity activity)? canInterrupt;
  final bool Function(SubagentActivity activity)? canSteer;
  final bool Function(SubagentActivity activity)? isInterruptPending;
  final bool Function(SubagentActivity activity)? isOpenPending;
  final ValueChanged<SubagentActivity>? onOpenConversation;
  final ValueChanged<SubagentActivity>? onInterrupt;
  final SubagentStopRequester? onStopRequested;
  final SubagentSteerSender? onSteer;
  final SubagentTailLoader? onTail;
  final SubagentTailScheduler? scheduleTailPoll;
  final DateTime? now;
  final bool background;
  final bool appForeground;
  final int safeChildCount;
  // Called when the person taps the pill's × once every activity is
  // terminal. The owner (chat_screen.dart) decides what "dismissed" means
  // for its own display cache — this widget only offers the affordance
  // when there's nothing still live to hide.
  final VoidCallback? onDismiss;

  /// The unified activity pill owns the presentation: this card only keeps its
  /// state machinery (tail polling, steering, stop) alive and exposes it through
  /// [controller]. Renders nothing.
  final bool hidden;
  final SubagentActivityController? controller;

  const SubagentActivityCard({
    required this.activities,
    this.canInterrupt,
    this.canSteer,
    this.isInterruptPending,
    this.isOpenPending,
    this.onOpenConversation,
    this.onInterrupt,
    this.onStopRequested,
    this.onSteer,
    this.onTail,
    this.scheduleTailPoll,
    this.now,
    this.background = false,
    this.appForeground = true,
    this.safeChildCount = 0,
    this.onDismiss,
    this.hidden = false,
    this.controller,
    super.key,
  });

  @override
  State<SubagentActivityCard> createState() => _SubagentActivityCardState();
}

class _SubagentActivityCardState extends State<SubagentActivityCard> {
  bool _expanded = false;
  SubagentActivityKey? _selectedKey;
  SubagentTailView? _tail;
  bool _tailLoading = false;
  int _tailGeneration = 0;
  VoidCallback? _cancelTailPoll;
  final TextEditingController _steerController = TextEditingController();
  bool _steerPending = false;
  String? _steerNotice;
  final Set<SubagentActivityKey> _stopAwaitingTerminal = {};
  // Set while the detail bottom sheet is open: its content lives in a
  // separate element tree (the Navigator overlay), so this widget's own
  // setState does not reach it. Every state mutation below goes through
  // _rebuild so the open sheet (tail output, steer status, selection)
  // stays live instead of freezing at whatever it showed when it opened.
  void Function(VoidCallback fn)? _sheetRefresh;
  ModalRoute<void>? _detailRoute;
  bool _sheetMounted = false;

  void _rebuild(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
    _sheetRefresh?.call(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._opener = _openFromController;
  }

  void _openFromController(SubagentActivity? activity) {
    if (!mounted || _expanded || _sheetMounted) return;
    if (activity != null &&
        widget.activities.any((candidate) => candidate.key == activity.key) &&
        _selectedKey != activity.key) {
      _stopTail();
      _selectedKey = activity.key;
      _tail = null;
      _steerNotice = null;
      _steerController.clear();
    }
    unawaited(_openDetailSheet(context));
  }

  @override
  void didUpdateWidget(covariant SubagentActivityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._opener == _openFromController) {
        oldWidget.controller?._opener = null;
      }
      widget.controller?._opener = _openFromController;
    }
    _stopAwaitingTerminal.removeWhere(
      (key) => widget.activities.any((a) => a.key == key && a.isTerminal),
    );
    if (_selectedActivity == null) {
      _selectedKey = null;
      _tail = null;
      _stopTail();
    } else if (!widget.appForeground) {
      // Tail content is private display state. Revoke it synchronously with
      // foreground authority rather than merely stopping future polling.
      _tail = null;
      _stopTail();
    } else if (!_expanded) {
      _stopTail();
    } else if (!oldWidget.appForeground && widget.appForeground) {
      _startTail();
    }
    // The floating detail surface lives in its own route/element tree (see
    // _openDetailSheet), so this rebuild — triggered by the framework, not
    // by us — does not reach it on its own. Nudging its setState here would
    // hit "setState called during build" (didUpdateWidget runs mid-build);
    // defer it to right after this frame instead.
    if (_sheetRefresh != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _sheetRefresh?.call(() {});
      });
    }
  }

  @override
  void dispose() {
    if (widget.controller?._opener == _openFromController) {
      widget.controller?._opener = null;
    }
    _stopTail();
    _sheetRefresh = null;
    final route = _detailRoute;
    if (route != null) _closeDetailRoute(route);
    // The overlay's EditableText may outlive this pill. Its unmount callback
    // releases the controller after it has stopped using it.
    if (!_sheetMounted) _steerController.dispose();
    super.dispose();
  }

  void _closeDetailRoute(ModalRoute<void> route) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = route.navigator;
      if (navigator != null && navigator.mounted && route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  SubagentActivity? get _selectedActivity {
    for (final activity in widget.activities) {
      if (activity.key == _selectedKey) return activity;
    }
    return null;
  }

  void _setExpanded(bool expanded) {
    _rebuild(() {
      _expanded = expanded;
      if (expanded && widget.activities.length == 1) {
        _selectedKey = widget.activities.single.key;
      }
    });
    if (expanded) {
      _startTail();
    } else {
      _stopTail();
    }
  }

  void _select(SubagentActivity activity) {
    if (!mounted) return;
    if (_selectedKey == activity.key) return;
    _stopTail();
    _rebuild(() {
      _selectedKey = activity.key;
      _tail = null;
      _steerNotice = null;
      _steerController.clear();
    });
    _startTail();
  }

  void _stopTail() {
    _tailGeneration++;
    _cancelTailPoll?.call();
    _cancelTailPoll = null;
    _tailLoading = false;
  }

  void _startTail() {
    final activity = _selectedActivity;
    if (!mounted ||
        !_expanded ||
        !widget.appForeground ||
        activity == null ||
        activity.isTerminal ||
        activity.phase == SubagentActivityPhase.unknown ||
        widget.onTail == null ||
        _tailLoading) {
      return;
    }
    final generation = ++_tailGeneration;
    _tailLoading = true;
    widget.onTail!(activity)
        .then((result) {
          if (!mounted || generation != _tailGeneration) return;
          _rebuild(() {
            _tail = result;
            _tailLoading = false;
          });
          _scheduleNextTail(generation);
        })
        .onError((Object _, StackTrace _) {
          if (!mounted || generation != _tailGeneration) return;
          _rebuild(() {
            // A transport failure is not authoritative `available: false`.
            // Preserve the last valid tail so polling cannot make it flicker.
            _tailLoading = false;
          });
          _scheduleNextTail(generation);
        });
  }

  void _scheduleNextTail(int generation) {
    if (!_expanded || !widget.appForeground || generation != _tailGeneration) {
      return;
    }
    final scheduler = widget.scheduleTailPoll ?? _defaultTailScheduler;
    _cancelTailPoll = scheduler(const Duration(seconds: 2), () {
      _cancelTailPoll = null;
      if (mounted && generation == _tailGeneration) _startTail();
    });
  }

  static VoidCallback _defaultTailScheduler(
    Duration delay,
    VoidCallback callback,
  ) {
    final timer = Timer(delay, callback);
    return timer.cancel;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hidden) {
      return const SizedBox.shrink(key: ValueKey('subagent-card-hidden'));
    }
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final activities = widget.activities;
    final safeChildCount = widget.safeChildCount.clamp(0, 6);
    final displayCount = activities.length > safeChildCount
        ? activities.length
        : safeChildCount;
    if (!widget.background && displayCount == 0) {
      return const SizedBox.shrink(key: ValueKey('session-activity-idle'));
    }
    final genericOnly = activities.isEmpty;
    final live = activities
        .where((a) => !a.isTerminal && a.phase != SubagentActivityPhase.unknown)
        .length;
    final completed = activities.where((a) => a.isTerminal).length;
    final unknown = activities
        .where((a) => a.phase == SubagentActivityPhase.unknown)
        .length;
    final hasFailure = activities.any(
      (a) => a.phase == SubagentActivityPhase.failed,
    );
    final hasUnconfirmedSuccess = activities.any(
      (a) =>
          a.phase == SubagentActivityPhase.cancelled ||
          a.phase == SubagentActivityPhase.unknown,
    );
    final single = activities.length == 1 ? activities.single : null;
    final detailedSummary = single == null
        ? activities.isNotEmpty && unknown == activities.length
              ? strings.subagentActivityUnknown
              : [
                  if (live > 0 || completed > 0)
                    strings.subagentActivitySummary(live, completed),
                  if (unknown > 0) strings.subagentActivityUnknown,
                ].join(' · ')
        : [
            _phaseLabel(strings, single.phase),
            ?_formatDuration(_elapsedSeconds(single.details, widget.now)),
          ].join(' · ');
    final summary = genericOnly
        ? displayCount > 0
              ? strings.subagentActivitySummary(displayCount, 0)
              : strings.subagentActivityRunning
        : detailedSummary;
    final pillLabel = summary;
    final semanticLabel = widget.background
        ? strings.chaBackgroundWorkTitle
        : '${strings.subagentActivityTitle}, $displayCount';

    // True compact chip (mockup: icon + one line + chevron, sized to its
    // content, radius = stadium). The old shape reused HermesInlineActivity's
    // full editorial header (title + right-aligned status + a separate "ver
    // detalles" disclosure row), which forced full transcript width and
    // read as a banner, not a pill. Tapping now opens a real bottom sheet
    // instead of squeezing the detail into an ~180px inline sliver.
    // Only offer the × once nothing is still live: dismissing in-progress
    // work would hide a task someone might still want to steer or stop, and
    // the point of persisting the pill past completion (rather than letting
    // it vanish the moment `activities` empties out — see chat_screen.dart's
    // `_displaySubagentActivities`) is to leave the "what did it do" review
    // available until the person is done with it, not to auto-hide it.
    final showDismiss =
        !genericOnly && unknown == 0 && live <= 0 && widget.onDismiss != null;

    return Semantics(
      button: !genericOnly,
      label: semanticLabel,
      child: Material(
        key: const ValueKey('subagent-disclosure'),
        color: colors.surface,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.45),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InkWell(
                onTap: genericOnly ? null : () => _openDetailSheet(context),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      12,
                      9,
                      showDismiss ? 8 : 16,
                      9,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildLeadingIndicator(
                          colors: colors,
                          hasFailure: hasFailure,
                          hasUnconfirmedSuccess: hasUnconfirmedSuccess,
                          live: genericOnly ? (displayCount > 0 ? 1 : 0) : live,
                          completed: genericOnly ? 0 : completed,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 220),
                            child: CompactPillText(
                              label: pillLabel,
                              compactLabel: strings.subagentPillCount(
                                displayCount,
                              ),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: colors.textPrimary,
                              ),
                            ),
                          ),
                        ),
                        if (!genericOnly) ...[
                          const SizedBox(width: 2),
                          Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 18,
                            color: colors.textSecondary,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (showDismiss)
              Semantics(
                button: true,
                label: strings.inAppDismiss,
                child: InkWell(
                  onTap: widget.onDismiss,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: 48,
                      minWidth: 48,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 9, 12, 9),
                      child: Icon(
                        Icons.close_rounded,
                        size: 17,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openDetailSheet(BuildContext context) async {
    if (_expanded || _sheetMounted || !mounted) return;
    final strings = Strings.of(context);
    _setExpanded(true);
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('subagent-panel'),
      builder: (context) {
        final route = ModalRoute.of<void>(context)!;
        if (!mounted) {
          _closeDetailRoute(route);
          return const SizedBox.shrink();
        }
        _detailRoute = route;
        _sheetMounted = true;
        return _CallOnDispose(
          // The awaited push below only clears `_sheetRefresh` once its
          // Future resolves, which can lag behind the sheet's own element
          // actually leaving the tree (e.g. an ancestor route being replaced
          // out from under it) — that gap is enough for a deferred nudge
          // (see didUpdateWidget) to fire `setState` on an already-disposed
          // StatefulBuilder. Clearing it here, exactly on unmount, closes
          // that gap regardless of why the sheet went away.
          onDispose: () {
            _sheetRefresh = null;
            _detailRoute = null;
            _sheetMounted = false;
            if (!mounted) _steerController.dispose();
          },
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              if (!mounted) return const SizedBox.shrink();
              final colors = Theme.of(context).hermes;
              _sheetRefresh = setSheetState;
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                shrinkWrap: true,
                children: [
                  Text(
                    strings.subagentActivityTitle,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  for (var index = 0; index < widget.activities.length; index++)
                    _SubagentRow(
                      key: ValueKey(widget.activities[index].key),
                      activity: widget.activities[index],
                      index: index + 1,
                      selected: widget.activities[index].key == _selectedKey,
                      onSelect: () => _select(widget.activities[index]),
                    ),
                  if (_selectedActivity case final selected?)
                    _buildSelectedDetail(selected, colors, strings),
                ],
              );
            },
          ),
        );
      },
    );
    _sheetRefresh = null;
    if (mounted) _setExpanded(false);
  }

  // Small orange spinner (matches the pill mockup's "dot") instead of a
  // literal subagent glyph; a green check badge overlays it once at least
  // one activity has finished, and a plain check replaces it once none are
  // still live.
  Widget _buildLeadingIndicator({
    required HermesThemeColors colors,
    required bool hasFailure,
    required bool hasUnconfirmedSuccess,
    required int live,
    required int completed,
  }) {
    if (hasFailure) {
      return Icon(Icons.error_outline, size: 18, color: colors.error);
    }
    // Nothing live and nothing authoritatively completed (e.g. a batch
    // that is entirely `unknown`) is not the same as "done" — a green
    // check here would invent a success signal the data doesn't support.
    if (live <= 0 && (completed <= 0 || hasUnconfirmedSuccess)) {
      return Icon(
        Icons.account_tree_outlined,
        size: 18,
        color: colors.textSecondary,
      );
    }
    if (live <= 0) {
      return Icon(Icons.check_circle, size: 18, color: colors.success);
    }
    final spinner = SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2.2, color: colors.accent),
    );
    if (completed <= 0 || hasUnconfirmedSuccess) return spinner;
    return SizedBox(
      width: 18,
      height: 18,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(top: 1, left: 1, child: spinner),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                color: colors.surface,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check_circle, size: 12, color: colors.success),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedDetail(
    SubagentActivity activity,
    HermesThemeColors colors,
    Strings strings,
  ) {
    final index = widget.activities.indexOf(activity) + 1;
    // Only the owner-wired live surface may reveal bounded public metadata.
    final ownerWired = widget.canSteer != null;
    final goal = ownerWired ? activity.goalPreview?.trim() : null;
    final progress = activity.progress;
    final usage = activity.usage;
    final canOpen =
        activity.canResumeChildTranscript && widget.onOpenConversation != null;
    final canStop = widget.canInterrupt?.call(activity) ?? false;
    final stopping =
        _stopAwaitingTerminal.contains(activity.key) ||
        (widget.isInterruptPending?.call(activity) ?? false);
    final steerAllowed =
        (widget.canSteer?.call(activity) ?? false) && widget.onSteer != null;
    final tail = _tail;
    final steerNotice = _steerNotice;
    final toolCount = ownerWired ? activity.details.toolCount : null;
    final apiCalls = ownerWired ? usage?.apiCalls : null;
    final facts = <String>[
      if (ownerWired && progress != null)
        strings.subagentActivityProgress(
          progress.displayTaskIndex,
          progress.taskCount,
        ),
      if (toolCount case final count?) strings.subagentActivityToolCount(count),
      if (apiCalls case final calls?) strings.subagentActivityCallCount(calls),
      ?_formatDuration(_elapsedSeconds(activity.details, widget.now)),
    ];

    // Sin borde duro: hairline superior consistente con el resto de la app,
    // tipografía coherente (no monoespaciado genérico salvo la salida en
    // vivo, que recibe un tratamiento de bloque de código sutil).
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            strings.subagentActivityItem(index),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          if (goal != null && goal.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              goal,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: colors.textPrimary),
            ),
          ],
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              facts.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.textSecondary, fontSize: 11.5),
            ),
          ],
          if (tail != null) ...[
            const SizedBox(height: 10),
            if (!tail.available)
              Text(
                strings.subagentTailUnavailable,
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              )
            else ...[
              if (tail.content.trim().isNotEmpty)
                // Bloque de código sutil (surfaceVariant + radio) en vez de
                // SelectableText monoespaciado a secas: la salida en vivo del
                // subagente es contenido de log real, así que conserva el
                // tratamiento mono pero contenido, no crudo.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  decoration: BoxDecoration(
                    color: colors.surfaceVariant,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    tail.content,
                    maxLines: 6,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              if (tail.truncated)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    strings.subagentTailTruncated,
                    style: TextStyle(color: colors.textDisabled, fontSize: 11),
                  ),
                ),
            ],
          ],
          if (steerAllowed) ...[
            const SizedBox(height: 10),
            // Mismo estilo de campo que el composer/inputs del resto de la
            // app (InputDecorationTheme global: relleno surfaceVariant,
            // borde hairline, radio consistente).
            TextField(
              key: ValueKey('subagent-steer-input-${activity.key.stableId}'),
              controller: _steerController,
              minLines: 1,
              maxLines: 3,
              maxLength: 512,
              style: TextStyle(fontSize: 14, color: colors.textPrimary),
              decoration: InputDecoration(
                labelText: strings.subagentSteerLabel,
                counterText: '',
                isDense: true,
              ),
            ),
            if (steerNotice != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  steerNotice,
                  style: TextStyle(color: colors.textSecondary, fontSize: 12),
                ),
              ),
          ],
          if (canOpen || canStop || steerAllowed)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: 4,
                children: [
                  if (canOpen)
                    TextButton(
                      key: ValueKey('subagent-open-${activity.key.stableId}'),
                      onPressed: widget.isOpenPending?.call(activity) == true
                          ? null
                          : () {
                              if (mounted) widget.onOpenConversation!(activity);
                            },
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      child: widget.isOpenPending?.call(activity) == true
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox.square(
                                  dimension: 13,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(strings.subagentActivityOpening),
                              ],
                            )
                          : Text(strings.subagentActivityOpenConversation),
                    ),
                  if (steerAllowed)
                    TextButton(
                      key: ValueKey('subagent-steer-${activity.key.stableId}'),
                      onPressed: _steerPending
                          ? null
                          : () => _sendSteer(activity),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      child: Text(
                        _steerPending
                            ? strings.subagentSteerSending
                            : strings.subagentSteerLabel,
                      ),
                    ),
                  if (canStop || stopping)
                    TextButton(
                      key: ValueKey('subagent-stop-${activity.key.stableId}'),
                      onPressed: stopping ? null : () => _requestStop(activity),
                      style: TextButton.styleFrom(
                        foregroundColor: colors.error,
                        minimumSize: const Size(48, 48),
                      ),
                      child: stopping
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox.square(
                                  dimension: 13,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(strings.subagentActivityStopping),
                              ],
                            )
                          : Text(strings.subagentActivityStop),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _sendSteer(SubagentActivity activity) async {
    if (!mounted) return;
    final text = _steerController.text.trim();
    if (text.isEmpty || _steerPending || widget.onSteer == null) return;
    _rebuild(() {
      _steerPending = true;
      _steerNotice = null;
    });
    try {
      final result = await widget.onSteer!(activity, text);
      if (!mounted || _selectedKey != activity.key) return;
      _rebuild(() {
        _steerPending = false;
        if (result.queued) {
          _steerController.clear();
          _steerNotice = Strings.of(context).subagentSteerQueued;
        } else {
          _steerNotice = Strings.of(context).subagentSteerUnconfirmed;
        }
      });
    } catch (_) {
      if (!mounted || _selectedKey != activity.key) return;
      _rebuild(() {
        _steerPending = false;
        _steerNotice = Strings.of(context).subagentSteerUnconfirmed;
      });
    }
  }

  Future<void> _requestStop(SubagentActivity activity) async {
    if (!mounted) return;
    if (!_stopAwaitingTerminal.add(activity.key)) return;
    _rebuild(() {});
    final requester = widget.onStopRequested;
    if (requester == null) {
      widget.onInterrupt?.call(activity);
      return;
    }
    var acknowledged = false;
    try {
      acknowledged = await requester(activity);
    } catch (_) {
      acknowledged = false;
    }
    if (!mounted || acknowledged) return;
    _rebuild(() => _stopAwaitingTerminal.remove(activity.key));
  }
}

String _phaseLabel(Strings strings, SubagentActivityPhase phase) =>
    switch (phase) {
      SubagentActivityPhase.requested => strings.subagentActivityRequested,
      SubagentActivityPhase.running => strings.subagentActivityRunning,
      SubagentActivityPhase.thinking => strings.subagentActivityThinking,
      SubagentActivityPhase.tool => strings.subagentActivityTool,
      SubagentActivityPhase.completed => strings.subagentActivityCompleted,
      SubagentActivityPhase.failed => strings.subagentActivityFailed,
      SubagentActivityPhase.cancelled => strings.subagentActivityCancelled,
      SubagentActivityPhase.unknown => strings.subagentActivityUnknown,
    };

double? _elapsedSeconds(SubagentActivityDetails details, DateTime? now) {
  if (details.durationSeconds case final seconds?) return seconds;
  final startedAt = details.startedAt;
  if (startedAt == null) return null;
  final endedAt = details.completedAt ?? now ?? DateTime.now().toUtc();
  final elapsed = endedAt.difference(startedAt).inSeconds;
  return elapsed < 0 ? null : elapsed.toDouble();
}

String? _formatDuration(double? seconds) {
  if (seconds == null || !seconds.isFinite || seconds < 0) return null;
  final totalSeconds = seconds.round();
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final remainder = totalSeconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${remainder.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${remainder.toString().padLeft(2, '0')}';
}

/// Read-only projection of a durable delegation completion marker.
///
/// This widget deliberately does not accept callbacks and never renders opaque
/// identifiers or payload previews. It is historical evidence, not liveness.
class SubagentCompletionCard extends StatelessWidget {
  final SubagentCompletionCardData data;

  const SubagentCompletionCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final completed = data.completedCount;
    final failed = data.failedCount;
    final duration = _formatDuration(data.durationSeconds);
    final facts = <String>[
      if (completed != null) s.subagentActivityAggregateCompleted(completed),
      if (failed != null) s.subagentActivityAggregateFailed(failed),
      ?duration,
    ];

    // Historical evidence carries only aggregate counts: per-child rows would
    // repeat the summary (or read "unknown") and add no information.
    return HermesInlineActivity(
      title: s.subagentActivityTitle,
      summary: facts.isEmpty ? s.subagentActivityUnknown : facts.join(' · '),
      titleMaxLines: 2,
      summaryMaxLines: 1,
      leading: const Icon(Icons.account_tree_outlined, size: 19),
      semanticLabel: s.subagentActivityTitle,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
    );
  }
}

/// Runs [onDispose] exactly when [child] actually leaves the tree, not on a
/// timing guess about when its owning route finishes closing.
class _CallOnDispose extends StatefulWidget {
  const _CallOnDispose({required this.onDispose, required this.child});

  final VoidCallback onDispose;
  final Widget child;

  @override
  State<_CallOnDispose> createState() => _CallOnDisposeState();
}

class _CallOnDisposeState extends State<_CallOnDispose> {
  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }
}

class _SubagentRow extends StatelessWidget {
  final SubagentActivity activity;
  final int index;
  final bool selected;
  final VoidCallback onSelect;

  const _SubagentRow({
    required this.activity,
    required this.index,
    required this.selected,
    required this.onSelect,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final label = _phaseLabel(strings, activity.phase);
    final title = strings.subagentActivityItem(index);
    final duration = _formatDuration(_elapsedSeconds(activity.details, null));
    final color = switch (activity.phase) {
      SubagentActivityPhase.failed => colors.error,
      SubagentActivityPhase.requested ||
      SubagentActivityPhase.running ||
      SubagentActivityPhase.thinking ||
      SubagentActivityPhase.tool => colors.accent,
      _ => colors.textSecondary,
    };

    return Semantics(
      button: true,
      selected: selected,
      label: '$title, $label',
      child: Material(
        // Tinte suave de superficie en la fila seleccionada, sin borde:
        // mismo lenguaje visual que el resto de listas rediseñadas.
        color: selected
            ? colors.surfaceVariant.withValues(alpha: 0.55)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: ValueKey('subagent-row-${activity.key.stableId}'),
          onTap: onSelect,
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: colors.textPrimary,
                          ),
                        ),
                        Text(
                          [label, ?duration].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: color, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.chevron_right
                        : Icons.chevron_right_outlined,
                    color: colors.textSecondary,
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
