import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../models/subagent_activity.dart';
import '../models/activity_snapshot.dart';
import '../models/subagent_steps.dart';
import '../screens/subagent_detail_screen.dart';
import '../services/subagent_child_session.dart'
    show SubagentChildMessagesReader, SubagentChildSessionResolver;
import '../services/subagent_finished_record.dart';
import '../services/subagent_live_watch.dart';
import '../services/delegation_control.dart';
import '../theme/app_theme.dart';
import '../utils/plain_preview.dart';
import 'activity_pill.dart' show ActivityTicker, formatTurnElapsed;
import 'delegation_pause_menu.dart';
import 'subagent_work_pill.dart';
import 'chat/delegated_child_cards.dart' show delegatedChildState;
import 'chat/delegated_icons.dart';
import 'chat/delegated_work_pill.dart';

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

typedef SubagentTailLoader = Future<SubagentTailView> Function(
  SubagentActivity activity,
);
typedef SubagentSteerSender = Future<SubagentSteerView> Function(
  SubagentActivity activity,
  String text,
);
typedef SubagentStopRequester = Future<bool> Function(
  SubagentActivity activity,
);
typedef SubagentTailScheduler = VoidCallback Function(
  Duration delay,
  VoidCallback callback,
);

/// Opens a live watch of the child, or null when none can be offered (no
/// child session, no watch-capable gateway). The detail page owns the result
/// and closes it when it is covered or left.
typedef SubagentLiveWatchOpener = SubagentLiveWatch? Function(
  SubagentActivity activity,
);

/// Lets the unified activity panel open a subagent (detail page, or the
/// floating list when several and none is preselected).
class SubagentActivityController {
  void Function(SubagentActivity? selected)? _opener;

  void open([SubagentActivity? activity]) => _opener?.call(activity);

  /// Finished / total subagents of the card this controller serves, kept up
  /// to date (after the frame, never during a build) whether the card is
  /// shown or hidden. The live pill reads it for «n/N agentes». «Finished»
  /// includes failed and stopped children; the total counts a roster that
  /// is only known by number as 0/N.
  final ValueNotifier<SubagentGroupCount> counts = ValueNotifier(
    SubagentGroupCount.none,
  );
}

/// Owns the roster, detail lease and controls; its sole chat surface is the
/// compact work pill. The sheet and open detail follow this same roster.
class SubagentActivityCard extends StatefulWidget {
  final List<SubagentActivity> activities;
  final String? headerName;

  /// Design B: this card is the capsule above the composer, not the header's
  /// pill. The header stays identity only; this one draws nothing at rest and
  /// opens the same anchored sheet over itself.
  final bool capsule;

  /// The capsule's outside margin (the composer's side insets).
  final EdgeInsetsGeometry capsulePadding;
  final Widget? headerIdle;
  final bool headerPriority;
  final bool Function(SubagentActivity activity)? canInterrupt;
  final bool Function(SubagentActivity activity)? canSteer;
  final bool Function(SubagentActivity activity)? canTail;
  final bool Function(SubagentActivity activity)? isInterruptPending;
  final bool Function(SubagentActivity activity)? isOpenPending;
  final ValueChanged<SubagentActivity>? onOpenConversation;

  /// Puts a failed delegation's goal back into the composer to send again.
  final ValueChanged<String>? onRetryGoal;

  /// Legacy immediate stop (no confirmation); prefer [onStopRequested].
  final ValueChanged<SubagentActivity>? onInterrupt;
  final SubagentStopRequester? onStopRequested;
  final SubagentSteerSender? onSteer;
  final SubagentTailLoader? onTail;
  final SubagentTailScheduler? scheduleTailPoll;
  final SubagentLiveWatchOpener? openLiveWatch;

  /// Reads what a finished agent did, for its detail page (owner only).
  final SubagentFinishedRecordLoader? loadFinishedRecord;

  /// Reads a running child's stored session for its detail page (owner
  /// only), and finds its id when its events did not carry it.
  final SubagentChildMessagesReader? readChildMessages;
  final SubagentChildSessionResolver? resolveChildSession;

  /// Server-wide pause switch, handed to the detail's overflow.
  final HermesDelegationGateway? delegationControl;

  /// The same live snapshot used by the transcript, including provisional
  /// state on re-entry. The pill only complements ordinary transcript work.
  final ActivitySnapshot? turnSnapshot;
  final bool turnWorking;
  final DateTime? turnStartedAt;
  final DateTime Function()? clock;
  final DateTime? now;
  final bool background;
  final bool unconfirmed;
  final bool appForeground;
  final int safeChildCount;
  final VoidCallback? onDismiss;

  /// Title of the delegating chat for the detail's "Belongs to" row.
  final String parentTitle;

  /// Keeps the chat's subagent presentation lease while a detail is open.
  final VoidCallback Function()? acquirePresentation;

  /// The group is hidden from the chat (the person closed it): render
  /// nothing, but keep following the agents and serve [controller], so the
  /// list and every detail can still be reopened.
  final bool hidden;
  final VoidCallback? onStop;
  final int queuedCount;
  final bool queuePaused;
  final VoidCallback? onResumeQueue;
  final bool interactionsLocked;

  /// Queue contents/capabilities that changed without changing their count.
  final Object? sectionSignature;
  final WidgetBuilder? queueSectionBuilder;
  final Widget Function(BuildContext, VoidCallback)? backgroundSectionBuilder;
  final SubagentActivityController? controller;

  /// Agents (by id) closed from the collapsed group. They remain reachable
  /// in Activity; closing them cannot hide the parent's other work.
  final Set<String> closedIds;

  /// Agents that are not in [activities] any more (closed in an earlier
  /// turn) but that [controller] still opens, in the list and in the detail.
  final List<SubagentActivity> reopenable;

  const SubagentActivityCard({
    required this.activities,
    this.headerName,
    this.headerIdle,
    this.headerPriority = false,
    this.capsule = false,
    this.capsulePadding = EdgeInsets.zero,
    this.canInterrupt,
    this.canSteer,
    this.canTail,
    this.isInterruptPending,
    this.isOpenPending,
    this.onOpenConversation,
    this.onRetryGoal,
    this.onInterrupt,
    this.onStopRequested,
    this.onSteer,
    this.onTail,
    this.scheduleTailPoll,
    this.openLiveWatch,
    this.loadFinishedRecord,
    this.readChildMessages,
    this.resolveChildSession,
    this.delegationControl,
    this.turnSnapshot,
    this.turnWorking = false,
    this.turnStartedAt,
    this.clock,
    this.now,
    this.background = false,
    this.unconfirmed = false,
    this.appForeground = true,
    this.safeChildCount = 0,
    this.onDismiss,
    this.parentTitle = '',
    this.acquirePresentation,
    this.hidden = false,
    this.onStop,
    this.queuedCount = 0,
    this.queuePaused = false,
    this.onResumeQueue,
    this.interactionsLocked = false,
    this.sectionSignature,
    this.queueSectionBuilder,
    this.backgroundSectionBuilder,
    this.controller,
    this.closedIds = const <String>{},
    this.reopenable = const <SubagentActivity>[],
    super.key,
  });

  @override
  State<SubagentActivityCard> createState() => _SubagentActivityCardState();
}

class _SubagentActivityCardState extends State<SubagentActivityCard> {
  late List<SubagentActivity> _reachable;
  late ActivitySnapshot _agentsSignature;
  late ActivitySnapshot _reopenableSignature;
  late Object _sheetSignature;
  final ValueNotifier<int> _sheetRevision = ValueNotifier(0);
  bool _publicationScheduled = false;
  bool _rosterDirty = false;
  bool _sheetDirty = false;
  late final ValueNotifier<List<SubagentActivity>> _roster = ValueNotifier(
    _reachable,
  );

  /// What the controller can open: the agents of the turn and the closed
  /// ones of earlier turns.
  List<SubagentActivity> _collectReachable() => [
    ...widget.activities,
    for (final a in widget.reopenable)
      if (!widget.activities.any((current) => current.key == a.key)) a,
  ];

  // A closed child remains reachable even after the parent starts another
  // turn. Count exactly the identities that the activity sheet can list.
  List<SubagentActivity> get _presentation => _reachable;

  int get _genericRowCount =>
      (widget.safeChildCount.clamp(0, 6) - _presentation.length).clamp(0, 6);

  Object _activitySheetSignature() {
    final turn = widget.turnSnapshot;
    return (
      _agentsSignature,
      _reopenableSignature,
      ActivitySnapshot(
        processes: turn?.processes ?? const [],
        schedules: turn?.schedules ?? const [],
        goal: turn?.goal,
        processesStale: turn?.processesStale ?? false,
        subagentsStale: turn?.subagentsStale ?? false,
      ),
      widget.sectionSignature,
      widget.queuedCount,
      widget.queuePaused,
      widget.safeChildCount,
      widget.interactionsLocked,
      widget.appForeground,
      widget.onDismiss != null,
      widget.now,
    );
  }

  void _schedulePublication() {
    if (_publicationScheduled) return;
    _publicationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _publicationScheduled = false;
      if (!mounted) return;
      if (_rosterDirty) _roster.value = _reachable;
      if (_sheetDirty && _surfaceOpen) _sheetRevision.value++;
      _rosterDirty = _sheetDirty = false;
    });
  }

  bool _surfaceOpen = false;

  /// What finished children did, read back for the rows that reached the
  /// chat bare (no goal, no model): the parent's dispatch and completion
  /// say both. Read once per child, only for the owner-wired sheet.
  final Map<String, SubagentFinishedRecord> _records = {};
  final Set<String> _recordsInFlight = {};

  bool _needsRecord(SubagentActivity activity) =>
      activity.isTerminal &&
      ((activity.goalPreview?.trim().isEmpty ?? true) ||
          (activity.details.model?.trim().isEmpty ?? true));

  void _readFinishedRecords() {
    final load = widget.loadFinishedRecord;
    if (load == null || !_ownerWired) return;
    for (final activity in _presentation) {
      final id = activity.key.stableId;
      if (!_needsRecord(activity) ||
          _records.containsKey(id) ||
          !_recordsInFlight.add(id)) {
        continue;
      }
      unawaited(() async {
        SubagentFinishedRecord record;
        try {
          record = await load(activity);
        } catch (_) {
          record = SubagentFinishedRecord.empty;
        }
        _recordsInFlight.remove(id);
        if (!mounted) return;
        _records[id] = record;
        if (_surfaceOpen) _sheetRevision.value++;
      }());
    }
  }

  /// Something in the sheet can still be stopped: a child that has not
  /// ended (or is not known to have), one known only by its number, or a
  /// background process. Once every child ended, «Parar» has nothing to do.
  bool get _sheetCanStop =>
      _presentation.any((a) => !a.isTerminal) ||
      _genericRowCount > 0 ||
      (widget.turnSnapshot?.backgroundCount ?? 0) > 0;

  /// What each agent was seen doing, for the detail page's «Pasos».
  final SubagentStepLog _steps = SubagentStepLog();

  @override
  void initState() {
    super.initState();
    _reachable = _collectReachable();
    _agentsSignature = ActivitySnapshot(subagents: widget.activities);
    _reopenableSignature = ActivitySnapshot(subagents: widget.reopenable);
    _sheetSignature = _activitySheetSignature();
    widget.controller?._opener = _openFromController;
    _observeSteps();
    _publishCounts();
  }

  void _observeSteps() {
    final changed = _steps.observeAll(
      widget.activities,
      widget.now ?? DateTime.now(),
    );
    if (!changed) return;
    // Listeners (an open detail page) must not rebuild mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _steps.publish();
    });
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
    final agents = ActivitySnapshot(subagents: widget.activities);
    final reopenable = ActivitySnapshot(subagents: widget.reopenable);
    if (agents != _agentsSignature || reopenable != _reopenableSignature) {
      _agentsSignature = agents;
      _reopenableSignature = reopenable;
      _reachable = _collectReachable();
      _rosterDirty = true;
      _observeSteps();
    }
    _publishCounts();
    final signature = _activitySheetSignature();
    if (signature != _sheetSignature) {
      _sheetSignature = signature;
      _sheetDirty = true;
    }
    if (_rosterDirty || (_sheetDirty && _surfaceOpen)) _schedulePublication();
    if (_surfaceOpen) _readFinishedRecords();
  }

  @override
  void dispose() {
    if (widget.controller?._opener == _openFromController) {
      widget.controller?._opener = null;
    }
    _roster.dispose();
    _sheetRevision.dispose();
    _steps.dispose();
    super.dispose();
  }

  void _publishCounts() {
    final controller = widget.controller;
    if (controller == null) return;
    final next = SubagentGroupCount.of(
      _presentation,
      genericTotal: widget.safeChildCount.clamp(0, 6),
    );
    if (controller.counts.value == next) return;
    // Listeners may sit above this card: never notify mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller == controller) {
        controller.counts.value = next;
      }
    });
  }

  void _openFromController(SubagentActivity? activity) {
    if (!mounted || widget.interactionsLocked) return;
    final reachable = _reachable;
    if (activity != null &&
        reachable.any((candidate) => candidate.key == activity.key)) {
      unawaited(_openDetail(activity));
    } else {
      unawaited(_openList());
    }
  }

  SubagentStopRequester? get _stopRequester {
    if (widget.onStopRequested != null) return widget.onStopRequested;
    final legacy = widget.onInterrupt;
    if (legacy == null) return null;
    return (activity) async {
      legacy(activity);
      return true;
    };
  }

  /// Goals are bounded public-display metadata, but only the owner-wired live
  /// surface (the chat that holds the lease) may reveal them.
  bool get _ownerWired => widget.canSteer != null;

  Future<void> _openDetail(SubagentActivity activity) async {
    if (!mounted) return;
    final releasePresentation = widget.acquirePresentation?.call();
    _roster.value = _reachable;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => SubagentDetailScreen(
            roster: _roster,
            activityKey: activity.key,
            parentTitle: widget.parentTitle,
            canInterrupt: widget.canInterrupt,
            isInterruptPending: widget.isInterruptPending,
            onStopRequested: _stopRequester,
            canSteer: widget.canSteer,
            onSteer: widget.onSteer,
            canTail: widget.canTail,
            onTail: widget.onTail,
            onOpenConversation: widget.onOpenConversation,
            onRetryGoal: widget.onRetryGoal,
            isOpenPending: widget.isOpenPending,
            acquirePresentation: widget.acquirePresentation,
            scheduleTailPoll: widget.scheduleTailPoll,
            openLiveWatch: widget.openLiveWatch,
            delegationControl: widget.delegationControl,
            clock: widget.now == null ? null : () => widget.now!,
            hideGoal: !_ownerWired,
            steps: _steps,
            loadFinishedRecord: _ownerWired ? widget.loadFinishedRecord : null,
            readChildMessages: _ownerWired ? widget.readChildMessages : null,
            resolveChildSession: _ownerWired
                ? widget.resolveChildSession
                : null,
          ),
        ),
      );
    } finally {
      releasePresentation?.call();
    }
  }

  /// The header's sheet says what it holds and for how long, like the
  /// approved video: «En segundo plano · 0:04» while work runs, «Delegado ·
  /// 0:06» once it ended. Other surfaces keep the plain «Actividad».
  String _sheetTitle(Strings s, DateTime now) {
    if (widget.headerName == null && !widget.capsule) {
      return s.activitySheetTitle;
    }
    Duration? longest;
    for (final activity in _presentation) {
      final elapsed = subagentElapsed(activity, now);
      if (elapsed != null && (longest == null || elapsed > longest)) {
        longest = elapsed;
      }
    }
    if (longest == null) return s.activitySheetTitle;
    final clock = formatTurnElapsed(longest);
    return _presentation.any(subagentIsLive)
        ? s.chatDelegatesSheetLive(clock)
        : s.chatDelegatesSheetDone(clock);
  }

  Future<void> _openList() async {
    if (_surfaceOpen || !mounted || widget.interactionsLocked) return;
    _surfaceOpen = true;
    _sheetDirty = false;
    final releasePresentation = widget.acquirePresentation?.call();
    final s = Strings.of(context);
    _roster.value = _reachable;
    _readFinishedRecords();
    try {
      releaseTextFocusIfKeyboardHidden(context);
      Widget panel(BuildContext surfaceContext) => SafeArea(
        top: false,
        child: ConstrainedBox(
          key: const ValueKey('subagent-panel'),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(surfaceContext).height * .7,
          ),
          child: ValueListenableBuilder(
            valueListenable: _sheetRevision,
            builder: (context, _, child) => IgnorePointer(
              ignoring: widget.interactionsLocked,
              child: ExcludeSemantics(
                excluding: widget.interactionsLocked,
                child: ActivityTicker(
                  active:
                      widget.appForeground && _presentation.any(subagentIsLive),
                  clock:
                      widget.clock ??
                      (widget.now == null ? null : () => widget.now!),
                  builder: (context, now) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      HermesSurfaceHeader(
                        title: _sheetTitle(s, now),
                        actions: [
                          if (_presentation.isNotEmpty)
                            ExcludeSemantics(
                              child: delegatedSheetIcon(
                                context,
                                _presentation.any(subagentIsLive)
                                    ? DelegatedIconState.running
                                    : _presentation.any(
                                        (a) =>
                                            delegatedChildState(a) ==
                                            DelegatedIconState.failed,
                                      )
                                    ? DelegatedIconState.failed
                                    : DelegatedIconState.done,
                                color: Theme.of(context).hermes.textSecondary,
                              ),
                            ),
                          if ((widget.headerName != null || widget.capsule) &&
                              widget.onStop != null &&
                              _sheetCanStop)
                            TextButton(
                              key: const ValueKey('delegates-stop'),
                              onPressed: widget.onStop,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              child: Text(s.activityStop),
                            ),
                          if (widget.delegationControl != null &&
                              !_delegationUnsupported)
                            IconButton(
                              key: _listMoreKey,
                              tooltip: s.cphMore,
                              constraints: const BoxConstraints(
                                minWidth: HermesSpace.tap,
                                minHeight: HermesSpace.tap,
                              ),
                              icon: const Icon(Icons.more_horiz_rounded),
                              onPressed: _delegationBusy
                                  ? null
                                  : () => unawaited(
                                      _openListDelegationMenu(surfaceContext),
                                    ),
                            ),
                          if (widget.onDismiss != null &&
                              _presentation.isNotEmpty)
                            IconButton(
                              key: const ValueKey('subagent-group-dismiss'),
                              tooltip: s.sv2CloseHint,
                              constraints: const BoxConstraints(
                                minWidth: HermesSpace.tap,
                                minHeight: HermesSpace.tap,
                              ),
                              icon: const Icon(Icons.visibility_off_outlined),
                              onPressed: () {
                                widget.onDismiss?.call();
                                Navigator.of(surfaceContext).pop();
                              },
                            ),
                        ],
                      ),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.only(
                            bottom: HermesSpace.x2,
                          ),
                          children: [
                            if (_presentation.isNotEmpty ||
                                _genericRowCount > 0)
                              HermesSurfaceHeader(title: s.subagentPillAgents),
                            if (_genericRowCount > 0)
                              Padding(
                                padding: const EdgeInsets.all(HermesSpace.x4),
                                child: Text(
                                  '${s.activityAgentCount(_genericRowCount)} · ${s.subagentUiStatusUnconfirmed}',
                                  style: HermesType.support.copyWith(
                                    color: Theme.of(context)
                                        .hermes
                                        .textSecondary,
                                  ),
                                ),
                              ),
                            for (final (index, activity)
                                in _presentation.indexed)
                              _SubagentListRow(
                                key: ValueKey(activity.key),
                                activity: activity,
                                level: subagentNestingLevels(_presentation)[activity.key] ?? 0,
                                ordinal: _presentation.length > 1
                                    ? index + 1
                                    : null,
                                now: now,
                                showGoal: _ownerWired,
                                record: _records[activity.key.stableId],
                                stopping:
                                    (widget.isInterruptPending?.call(
                                          activity,
                                        ) ??
                                        false) ||
                                    _stopping.contains(activity.key),
                                onStop:
                                    subagentIsLive(activity) &&
                                        (widget.canInterrupt?.call(activity) ??
                                            false) &&
                                        _stopRequester != null
                                    ? () => _stopFromList(activity)
                                    : null,
                                onTap: () =>
                                    Navigator.of(surfaceContext).pop(activity),
                              ),
                            if (widget.backgroundSectionBuilder
                                case final builder?)
                              builder(
                                context,
                                () => Navigator.of(surfaceContext).pop(),
                              ),
                            if (widget.headerName == null &&
                                !widget.capsule &&
                                widget.queuedCount > 0 &&
                                widget.queueSectionBuilder != null)
                              widget.queueSectionBuilder!(context),
                          ],
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
      final picked = widget.headerName != null || widget.capsule
          ? await showHermesSurface<SubagentActivity>(
              context: context,
              coversPage: false,
              originRect: hermesOriginOf(context),
              surfaceKey: const ValueKey('delegates-sheet'),
              maxWidth: 480,
              builder: panel,
            )
          : await showModalBottomSheet<SubagentActivity>(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              showDragHandle: true,
              backgroundColor: HermesChrome.of(Theme.of(context).hermes).opaque,
              constraints: const BoxConstraints(maxWidth: 480),
              builder: panel,
            );
      if (picked != null && mounted) await _openDetail(picked);
    } finally {
      releasePresentation?.call();
      _surfaceOpen = false;
    }
  }

  final Set<SubagentActivityKey> _stopping = {};

  final GlobalKey _listMoreKey = GlobalKey(debugLabel: 'delegates-more');
  bool _delegationUnsupported = false;
  bool _delegationBusy = false;

  /// «…» of the list, as in the official Background Work sheet: pause or
  /// resume NEW subagents for the whole server.
  Future<void> _openListDelegationMenu(BuildContext surfaceContext) async {
    final control = widget.delegationControl;
    if (control == null || _delegationBusy) return;
    _delegationBusy = true;
    _sheetRevision.value++;
    final outcome = await showDelegationPauseMenu(
      context: surfaceContext,
      anchorKey: _listMoreKey,
      control: control,
      actionKey: const ValueKey('delegates-pause'),
    );
    _delegationBusy = false;
    if (outcome == DelegationPauseOutcome.unsupported) {
      _delegationUnsupported = true;
    }
    if (mounted) _sheetRevision.value++;
  }

  Future<void> _stopFromList(SubagentActivity activity) async {
    if (!_stopping.add(activity.key)) return;
    _sheetRevision.value++;
    try {
      await _stopRequester?.call(activity);
    } finally {
      _stopping.remove(activity.key);
      if (mounted) _sheetRevision.value++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = SubagentGroupCount.of(
      _presentation,
      genericTotal: widget.safeChildCount.clamp(0, 6),
    );
    final unknown =
        widget.unconfirmed ||
        _presentation.any((a) => a.phase == SubagentActivityPhase.unknown);
    final starts =
        widget.activities
            .map((a) => a.details.startedAt)
            .whereType<DateTime>()
            .toList()
          ..sort();
    final turn = widget.turnSnapshot;
    final s = Strings.of(context);
    final pending = count.total - count.finished;
    final processes = turn?.backgroundCount ?? 0;
    final waiting = turn?.waitingForUser ?? false;
    final agentsClosed =
        _presentation.isNotEmpty &&
        !widget.activities.any(
          (a) => !widget.closedIds.contains(a.key.stableId),
        );
    final supplemental =
        pending > 0 || processes > 0 || widget.queuedCount > 0 || waiting;
    final label = waiting
        ? s.liveWaitingForUser
        : pending > 0
        ? (widget.queuedCount > 0 || processes > 0
              ? s.activityAgentCount(pending)
              : s.activityWaitingAgents(pending))
        : processes > 0
        ? s.activityProcessCount(processes)
        : s.queuePillCount(widget.queuedCount);
    if (widget.capsule || widget.headerName != null) {
      return DelegatedWorkPill(
        name: widget.headerName ?? '',
        capsule: widget.capsule,
        parentTurnEnded: turn != null && !turn.turnActive,
        padding: widget.capsulePadding,
        idle: widget.headerIdle,
        showIdle: widget.headerPriority,
        hidden: widget.hidden || (agentsClosed && processes == 0),
        clock: widget.clock ?? (widget.now == null ? null : () => widget.now!),
        onOpen: _openList,
        snapshot: ActivitySnapshot(
          subagents: widget.activities
              .where((a) => !widget.closedIds.contains(a.key.stableId))
              .toList(),
          subagentGenericCount: widget.safeChildCount,
          subagentsStale: widget.unconfirmed || (turn?.subagentsStale ?? false),
          processes: turn?.processes ?? const [],
          schedules: turn?.schedules ?? const [],
          goal: turn?.goal,
          backgroundStartedAt: turn?.backgroundStartedAt,
          processesStale: turn?.processesStale ?? false,
        ),
      );
    }
    return KeyedSubtree(
      key: const ValueKey('chat-activity-toggle'),
      child: SubagentWorkPill(
        queuedCount: widget.queuedCount,
        processCount: processes,
        agentIcon: true,
        waitingForUser: waiting,
        onStop: widget.onStop,
        showCompletion: false,
        queuePaused: widget.queuePaused,
        onResumeQueue: widget.onResumeQueue,
        statusLabel: label,
        working: pending > 0 || processes > 0 || waiting,
        unconfirmed: unknown && pending > 0,
        count: count,
        showCount: pending > 0,
        startedAt: widget.turnStartedAt ?? starts.firstOrNull,
        clock: widget.clock ?? (widget.now == null ? null : () => widget.now!),
        active: widget.appForeground,
        hidden:
            !supplemental ||
            widget.hidden ||
            (agentsClosed &&
                processes == 0 &&
                widget.queuedCount == 0 &&
                !waiting),
        onTap: () => unawaited(_openList()),
      ),
    );
  }
}

/// How deep each child sits under another child of the same list, by
/// `parent_id` → `subagent_id` (0 = a direct child of the chat's agent).
/// Capped so a long chain stays readable; cycles and unknown parents count 0.
Map<SubagentActivityKey, int> subagentNestingLevels(
  List<SubagentActivity> activities,
) {
  final byId = <String, SubagentActivity>{
    for (final a in activities)
      if (a.subagentId != null) a.subagentId!: a,
  };
  final levels = <SubagentActivityKey, int>{};
  for (final activity in activities) {
    var level = 0;
    var parent = activity.details.parentId;
    final seen = <String>{?activity.subagentId};
    while (parent != null && level < 3 && seen.add(parent)) {
      final up = byId[parent];
      if (up == null) break;
      level++;
      parent = up.details.parentId;
    }
    if (level > 0) levels[activity.key] = level;
  }
  return levels;
}

class _SubagentListRow extends StatelessWidget {
  final SubagentActivity activity;
  final int level;
  final DateTime now;
  final bool showGoal;
  final int? ordinal;
  final bool stopping;
  final VoidCallback onTap;
  final VoidCallback? onStop;

  /// What the finished child did, read back when its row came bare: the
  /// goal, the model and the duration the row itself does not carry.
  final SubagentFinishedRecord? record;

  const _SubagentListRow({
    required this.activity,
    this.level = 0,
    required this.now,
    required this.showGoal,
    this.record,
    this.ordinal,
    required this.stopping,
    required this.onTap,
    this.onStop,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final status =
        subagentIsLive(activity) &&
            activity.phase != SubagentActivityPhase.unknown &&
            !stopping
        ? (label: s.subagentPillWorking, tone: HermesStatusTone.active)
        : subagentHumanStatus(s, activity, stopping: stopping);
    final recordSeconds = record?.durationSeconds;
    final elapsed =
        subagentElapsed(activity, now) ??
        (activity.isTerminal &&
                recordSeconds != null &&
                recordSeconds.isFinite &&
                recordSeconds >= 0 &&
                recordSeconds < const Duration(days: 1).inSeconds
            ? Duration(milliseconds: (recordSeconds * 1000).round())
            : null);
    final ownGoal = activity.goalPreview?.trim().isNotEmpty ?? false;
    // A bare finished row borrows its goal from the record: its first line,
    // as plain text (it is agent Markdown), masked and ellipsized.
    final borrowed = showGoal && !ownGoal ? record?.goal : null;
    final recordGoal = borrowed == null
        ? null
        : maskedGoalLine(plainPreview(borrowed.split('\n').first), max: 90);
    final title = showGoal
        ? recordGoal ?? subagentTitle(s, activity, maxChars: 90)
        : ordinal == null
        ? s.subagentUiRowTitle
        : '${s.subagentUiRowTitle} $ordinal';
    String? filled(String? value) =>
        value == null || value.trim().isEmpty ? null : value.trim();
    final model = filled(activity.details.model) ?? filled(record?.model);
    // A finished row is one line, as in the official sheet: «Terminado ·
    // 0:35 · modelo». A working one keeps its model above its state.
    final meta = [
      if (elapsed != null) formatTurnElapsed(elapsed),
      if (model != null && activity.isTerminal) model,
    ];
    // «Con descripción» (the approved video): the public goal's first line,
    // masked; the title is the generic name only when the goal is not it.
    final description = maskedGoalLine(activity.details.goalPreview);
    return Semantics(
      container: true,
      child: InkWell(
        key: ValueKey('subagent-row-${activity.key.stableId}'),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HermesSpace.tap),
          child: Padding(
            padding: EdgeInsets.only(
              left: HermesSpace.rowH + level * HermesSpace.x4,
              right: HermesSpace.rowH,
              top: HermesSpace.x2,
              bottom: HermesSpace.x2,
            ),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: delegatedChildIcon(
                    context,
                    delegatedChildState(activity),
                    // One quiet ink for every row; only a failure tints.
                    color: delegatedIconInk(
                      colors,
                      delegatedChildState(activity),
                    ),
                    size: 18,
                  ),
                ),
                const SizedBox(width: HermesSpace.x2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        key: ValueKey(
                          'subagent-row-title-${activity.key.stableId}',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.body.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      if (!showGoal && description != null)
                        Text(
                          description,
                          key: ValueKey(
                            'subagent-row-description-${activity.key.stableId}',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HermesType.support.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      const SizedBox(height: HermesSpace.x1),
                      if (model != null && !activity.isTerminal)
                        Text(
                          model,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: HermesType.support.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      HermesStatusText(
                        key: ValueKey(
                          'subagent-row-status-${activity.key.stableId}',
                        ),
                        label: status.label,
                        tone: status.tone,
                        meta: meta.isEmpty ? null : meta.join(' · '),
                        maxLines: 1,
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        key: ValueKey(
                          'delegate-row-progress-${activity.key.stableId}',
                        ),
                        value: activity.phase == SubagentActivityPhase.unknown
                            ? 0
                            : activity.isTerminal
                            ? 1
                            : activity.progress?.displayFraction ?? 0,
                        minHeight: 3,
                        color: status.tone.colorIn(colors),
                        backgroundColor: colors.divider,
                      ),
                    ],
                  ),
                ),
                if (onStop != null)
                  IconButton(
                    key: ValueKey('subagent-stop-${activity.key.stableId}'),
                    constraints: const BoxConstraints(
                      minWidth: HermesSpace.tap,
                      minHeight: HermesSpace.tap,
                    ),
                    tooltip: s.subagentUiStop,
                    onPressed: stopping ? null : onStop,
                    icon: Icon(Icons.stop_rounded, color: colors.textSecondary),
                  ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colors.textDisabled,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Read-only projection of a durable delegation completion marker, in the
/// group's own look (the number-only mode of work pill: no faces,
/// no unfolding), so a reloaded chat shows the same «Subagentes · n/N» as a
/// live one. The chat paints it only when no live group covers the marker.
/// No callbacks, no identifiers, no payloads.
class SubagentCompletionCard extends StatelessWidget {
  final SubagentCompletionCardData data;

  /// Opens the finished subagents (list → detail). Null keeps the card plain.
  final VoidCallback? onTap;

  /// The children are being looked up after the tap.
  final bool busy;

  const SubagentCompletionCard({
    super.key,
    required this.data,
    this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final completed = data.completedCount ?? 0;
    final failed = data.failedCount ?? 0;
    final total =
        data.taskCount ?? (completed + failed == 0 ? 0 : completed + failed);
    final duration = data.durationSeconds;
    final meta = [
      if (duration != null &&
          duration.isFinite &&
          duration >= 0 &&
          duration < const Duration(days: 1).inSeconds)
        formatTurnElapsed(Duration(milliseconds: (duration * 1000).round())),
    ];
    final known = data.completedCount != null || data.failedCount != null;
    final what = [
      if (failed > 0) s.subagentActivityAggregateFailed(failed),
      if (data.completedCount != null && (completed > 0 || failed == 0))
        s.subagentActivityAggregateCompleted(completed),
      if (!known) s.subagentActivityUnknown,
    ];
    final colors = Theme.of(context).hermes;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          total == 0
              ? s.subagentActivityTitle
              : s.subFTitle(completed + failed, total),
          style: HermesType.support.copyWith(color: colors.textSecondary),
        ),
        Text(
          [...what, ...meta].join(' · '),
          style: HermesType.support.copyWith(color: colors.textSecondary),
        ),
      ],
    );
    final tap = onTap;
    if (tap == null) {
      return Padding(
        key: const ValueKey('subagent-completion-group'),
        padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
        child: text,
      );
    }
    return Padding(
      key: const ValueKey('subagent-completion-group'),
      padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
      child: Semantics(
        button: true,
        child: Material(
          color: HermesChrome.of(colors).fill,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('subagent-completion-open'),
            onTap: busy ? null : tap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: HermesSpace.tap),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x4,
                  vertical: HermesSpace.x2,
                ),
                child: Row(
                  children: [
                    Expanded(child: text),
                    if (busy)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: colors.textDisabled,
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
