import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
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

  @override
  void didUpdateWidget(covariant SubagentActivityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
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
  }

  @override
  void dispose() {
    _stopTail();
    _steerController.dispose();
    super.dispose();
  }

  SubagentActivity? get _selectedActivity {
    for (final activity in widget.activities) {
      if (activity.key == _selectedKey) return activity;
    }
    return null;
  }

  void _setExpanded(bool expanded) {
    setState(() {
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
    if (_selectedKey == activity.key) return;
    _stopTail();
    setState(() {
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
    if (!_expanded ||
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
          setState(() {
            _tail = result;
            _tailLoading = false;
          });
          _scheduleNextTail(generation);
        })
        .onError((Object _, StackTrace _) {
          if (!mounted || generation != _tailGeneration) return;
          setState(() {
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
    final viewData = MediaQueryData.fromView(View.of(context));
    final visibleHeight = viewData.size.height - viewData.viewInsets.bottom;
    final maxPanelHeight = (visibleHeight * 0.32).clamp(88.0, 180.0);
    final selectedActivity = _selectedActivity;

    return HermesInlineActivity(
      key: const ValueKey('subagent-disclosure'),
      title: genericOnly
          ? strings.chaBackgroundWorkTitle
          : strings.subagentActivityTitle,
      summary: widget.background && !genericOnly
          ? '$displayCount · $summary'
          : summary,
      titleMaxLines: 1,
      summaryMaxLines: 1,
      leading: Icon(
        Icons.account_tree_outlined,
        color: hasFailure
            ? colors.error
            : (genericOnly ? displayCount > 0 : widget.background || live > 0)
            ? colors.accent
            : colors.textSecondary,
      ),
      status: Text(
        genericOnly
            ? displayCount > 0
                  ? '$displayCount'
                  : strings.subagentActivityRunning
            : widget.background
            ? strings.chaBackgroundWorkTitle
            : '$displayCount',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      detail: genericOnly
          ? null
          : ConstrainedBox(
              key: const ValueKey('subagent-panel'),
              constraints: BoxConstraints(maxHeight: maxPanelHeight),
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var index = 0; index < activities.length; index++)
                      _SubagentRow(
                        key: ValueKey(activities[index].key),
                        activity: activities[index],
                        index: index + 1,
                        selected: activities[index].key == _selectedKey,
                        onSelect: () => _select(activities[index]),
                      ),
                    if (selectedActivity != null)
                      _buildSelectedDetail(selectedActivity, colors, strings),
                  ],
                ),
              ),
            ),
      expanded: !genericOnly && _expanded,
      onExpansionChanged: genericOnly ? null : _setExpanded,
      disclosureLabel: genericOnly
          ? null
          : _expanded
          ? strings.chaErrHideDetails
          : strings.chaErrViewDetails,
      semanticLabel: widget.background
          ? strings.chaBackgroundWorkTitle
          : '${strings.subagentActivityTitle}, $displayCount',
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
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
                          : () => widget.onOpenConversation!(activity),
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
    final text = _steerController.text.trim();
    if (text.isEmpty || _steerPending || widget.onSteer == null) return;
    setState(() {
      _steerPending = true;
      _steerNotice = null;
    });
    try {
      final result = await widget.onSteer!(activity, text);
      if (!mounted || _selectedKey != activity.key) return;
      setState(() {
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
      setState(() {
        _steerPending = false;
        _steerNotice = Strings.of(context).subagentSteerUnconfirmed;
      });
    }
  }

  Future<void> _requestStop(SubagentActivity activity) async {
    if (!_stopAwaitingTerminal.add(activity.key)) return;
    setState(() {});
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
    setState(() => _stopAwaitingTerminal.remove(activity.key));
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
    final rowCount = (data.taskCount ?? data.subagentIds.length).clamp(0, 64);
    final homogeneousCompleted =
        data.taskCount != null &&
        data.completedCount == data.taskCount &&
        data.failedCount == 0;
    final homogeneousFailed =
        data.taskCount != null &&
        data.failedCount == data.taskCount &&
        data.completedCount == 0;
    final rowStatus = homogeneousCompleted
        ? s.subagentActivityCompleted
        : homogeneousFailed
        ? s.subagentActivityFailed
        : s.subagentActivityUnknown;
    final facts = <String>[
      if (completed != null) s.subagentActivityAggregateCompleted(completed),
      if (failed != null) s.subagentActivityAggregateFailed(failed),
      ?duration,
    ];

    return HermesInlineActivity(
      title: s.subagentActivityTitle,
      summary: facts.isEmpty ? s.subagentActivityUnknown : facts.join(' · '),
      titleMaxLines: 2,
      summaryMaxLines: 1,
      leading: const Icon(Icons.account_tree_outlined, size: 19),
      detail: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 1; index <= rowCount; index++) ...[
            if (index > 1) const SizedBox(height: 8),
            Text(
              s.subagentActivityItem(index),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(rowStatus, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
          if (rowCount > 0) const SizedBox(height: 8),
          Text(s.subagentActivityMetadataUnavailable),
        ],
      ),
      semanticLabel: s.subagentActivityTitle,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
    );
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
