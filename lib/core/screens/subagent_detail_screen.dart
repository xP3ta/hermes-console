// Spec 080 step 7 — action-first detail page of ONE delegated subagent.
//
// Replaces the generic session "profile" (metric boxes, disabled buttons) that
// tapping a subagent used to open. The page answers: what is it doing, is it
// still working, and what can I do (Stop / Guide / read its conversation).
//
// Privacy: only bounded public-display fields are rendered (goal, phase,
// public tool name, counts, result summary, the owner-scoped
// `subagent.tail`). The owner-wired surface (the chat that holds the lease)
// may also show what the agent thinks (`detailPreview`, as clean prose) and
// the one-line target of each step or live tool, command lines included as
// the main chat shows them, with every secret masked
// ([subagentLiveTarget]); the finished view keeps a path or a URL only
// ([subagentPublicTarget]). Any other opener (`hideGoal`) gets none of them.
// Opaque identifiers are never shown.
//
// What the page shows, top to bottom: the assignment (whole, folded when
// long), the live output while it works (the last output once it ended), the
// steps seen so far, its thinking in a fold, and its result rendered as chat
// Markdown, partial while it still works and also when it failed or was
// stopped.
//
// Performance: the live tail is polled ONLY while this route (or its
// full-screen live page) is the visible route and the app is in foreground,
// with an adaptive 1.5 s → 5 s interval when nothing changes. It reuses the
// chat's own gateway client through [onTail]; no extra socket.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart' show hermesRouteObserver;
import '../design/hermes_design.dart';
import '../models/subagent_activity.dart';
import '../models/activity_snapshot.dart' show measuredActivityDuration;
import '../models/subagent_steps.dart';
import '../services/active_chat_service.dart'
    show ProfileTranscriptAccessRequired;
import '../services/subagent_child_session.dart';
import '../services/subagent_finished_record.dart';
import '../services/subagent_tail_log.dart'
    show isSubagentTailLog, parseSubagentTailLog;
import '../services/subagent_live_watch.dart';
import '../services/delegation_control.dart';
import '../theme/app_theme.dart';
import '../utils/assistant_content.dart' show finalizedPublicAssistantText;
import '../utils/plain_preview.dart';
import '../utils/reasoning_plain.dart';
import '../widgets/activity_pill.dart' show ActivityTicker, formatTurnElapsed;
import '../widgets/subagent_work_pill.dart';
import '../widgets/subagent_finished_view.dart';
import '../widgets/subagent_stream_view.dart';
import '../widgets/chat/chat_live_icon.dart';
import '../widgets/chat/chat_markdown_body.dart';
import '../widgets/delegation_pause_menu.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/console_loader.dart';
import '../widgets/subagent_activity_card.dart'
    show
        SubagentTailView,
        SubagentTailLoader,
        SubagentSteerSender,
        SubagentStopRequester,
        SubagentTailScheduler,
        SubagentLiveWatchOpener;
import '../feedback/feedback_policy.dart';

/// Human status of a subagent (label + tone), shared by the in-chat row, the
/// floating list and the detail page so the same entity reads the same way.
({String label, HermesStatusTone tone}) subagentHumanStatus(
  Strings s,
  SubagentActivity activity, {
  bool stopping = false,
}) {
  if (stopping && !activity.isTerminal) {
    return (label: s.subagentUiStatusStopping, tone: HermesStatusTone.warn);
  }
  return switch (activity.phase) {
    SubagentActivityPhase.requested => (
      label: s.subagentUiStatusQueued,
      tone: HermesStatusTone.active,
    ),
    SubagentActivityPhase.running => (
      label: s.subagentUiStatusWorking,
      tone: HermesStatusTone.active,
    ),
    SubagentActivityPhase.thinking => (
      label: s.subagentUiStatusThinking,
      tone: HermesStatusTone.active,
    ),
    SubagentActivityPhase.tool => (
      label: s.subagentUiStatusTool,
      tone: HermesStatusTone.active,
    ),
    SubagentActivityPhase.completed => (
      label: s.subagentUiStatusDone,
      tone: HermesStatusTone.ok,
    ),
    SubagentActivityPhase.failed => (
      label: s.subagentUiStatusFailed,
      tone: HermesStatusTone.error,
    ),
    SubagentActivityPhase.cancelled => (
      label: s.subagentUiStatusStopped,
      tone: HermesStatusTone.neutral,
    ),
    SubagentActivityPhase.unknown => (
      label: s.subagentUiStatusUnconfirmed,
      tone: HermesStatusTone.neutral,
    ),
  };
}

/// Elapsed (running) or total (finished) time from authoritative fields only.
Duration? subagentElapsed(SubagentActivity activity, DateTime now) {
  if (activity.phase == SubagentActivityPhase.unknown) return null;
  final details = activity.details;
  if (activity.isTerminal &&
      details.completedAt == null &&
      details.durationSeconds == null) {
    return null;
  }
  if (!activity.isTerminal && details.startedAt != null) {
    final elapsed = measuredActivityDuration(
      now.toUtc().difference(details.startedAt!),
    );
    if (elapsed != null) return elapsed;
  }
  if (details.durationSeconds case final seconds?) {
    if (seconds.isFinite &&
        seconds >= 0 &&
        seconds < const Duration(days: 1).inSeconds) {
      return Duration(milliseconds: (seconds * 1000).round());
    }
  }
  final started = details.startedAt;
  if (started == null) return null;
  final end = details.completedAt ?? now.toUtc();
  final elapsed = end.difference(started);
  return measuredActivityDuration(elapsed);
}

/// Wall-clock end supplied by the server/history, never the reconnect time.
String? subagentCompletionTime(SubagentActivity activity) {
  final end = activity.isTerminal
      ? activity.details.completedAt?.toLocal()
      : null;
  if (end == null) return null;
  return '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
}

/// Short human title: the public goal, or the generic noun.
String subagentTitle(Strings s, SubagentActivity activity, {int? maxChars}) {
  final goal = activity.goalPreview?.trim() ?? '';
  if (goal.isEmpty) return s.subagentUiRowTitle;
  // rt1215: a goal is agent Markdown; its title line is plain text.
  final line = plainPreview(goal.split('\n').first);
  if (line.isEmpty) return s.subagentUiRowTitle;
  if (maxChars != null && line.runes.length > maxChars) {
    return '${String.fromCharCodes(line.runes.take(maxChars)).trimRight()}…';
  }
  return line;
}

bool subagentIsLive(SubagentActivity a) =>
    !a.isTerminal && a.phase != SubagentActivityPhase.unknown;

/// Bounded, append-friendly model of the live tail.
final class SubagentLiveTail {
  static const int maxChars = 16384;
  static const int maxLines = 400;

  final List<String> lines;
  final bool available;
  final bool truncated;
  final bool loaded;
  final int revision;

  const SubagentLiveTail({
    this.lines = const [],
    this.available = false,
    this.truncated = false,
    this.loaded = false,
    this.revision = 0,
  });

  String get text => lines.join('\n');

  /// Applies a new authoritative tail. When the new text extends the previous
  /// one only the new lines are appended (no full re-split of the history).
  SubagentLiveTail apply(SubagentTailView view) {
    if (!view.available) {
      return SubagentLiveTail(
        loaded: true,
        available: false,
        revision: lines.isEmpty && !available ? revision : revision + 1,
      );
    }
    var content = view.content;
    var truncated = view.truncated;
    if (content.length > maxChars) {
      content = content.substring(content.length - maxChars);
      truncated = true;
    }
    final previous = text;
    if (available && content == previous && truncated == this.truncated) {
      return SubagentLiveTail(
        lines: lines,
        available: true,
        truncated: truncated,
        loaded: true,
        revision: revision,
      );
    }
    List<String> next;
    if (available && previous.isNotEmpty && content.startsWith(previous)) {
      final suffix = content.substring(previous.length);
      next = [...lines];
      final parts = suffix.split('\n');
      if (next.isNotEmpty && parts.isNotEmpty) {
        next[next.length - 1] = next.last + parts.first;
        next.addAll(parts.skip(1));
      } else {
        next.addAll(parts);
      }
    } else {
      next = content.split('\n');
    }
    if (next.length > maxLines) {
      next = next.sublist(next.length - maxLines);
      truncated = true;
    }
    return SubagentLiveTail(
      lines: List.unmodifiable(next),
      available: true,
      truncated: truncated,
      loaded: true,
      revision: revision + 1,
    );
  }
}

/// Detail page of one subagent.
class SubagentDetailScreen extends StatefulWidget {
  /// Live roster owned by the chat; the page follows [activityKey] in it.
  final ValueListenable<List<SubagentActivity>> roster;
  final SubagentActivityKey activityKey;

  /// Title of the chat that delegated the work ("Pertenece a").
  final String parentTitle;

  final bool Function(SubagentActivity activity)? canInterrupt;
  final bool Function(SubagentActivity activity)? isInterruptPending;

  /// Asks for confirmation and stops; resolves `true` when acknowledged.
  final SubagentStopRequester? onStopRequested;
  final bool Function(SubagentActivity activity)? canSteer;
  final SubagentSteerSender? onSteer;
  final bool Function(SubagentActivity activity)? canTail;
  final SubagentTailLoader? onTail;
  final ValueChanged<SubagentActivity>? onOpenConversation;

  /// Puts a failed delegation's goal back into the composer to send again.
  final ValueChanged<String>? onRetryGoal;
  final bool Function(SubagentActivity activity)? isOpenPending;

  /// Holds the chat's subagent presentation lease while this page is up so
  /// the authoritative roster and controls stay valid when the chat is
  /// covered. Returns the release callback.
  final VoidCallback Function()? acquirePresentation;

  final SubagentTailScheduler? scheduleTailPoll;

  /// Live watch of the child's mirrored turn. While it is up the polled tail
  /// stays off; it is the fallback when the watch cannot be opened.
  final SubagentLiveWatchOpener? openLiveWatch;

  /// Server-wide "pause new subagents" switch, offered in the overflow menu.
  /// Null hides the menu.
  final HermesDelegationGateway? delegationControl;
  final DateTime Function()? clock;

  /// Route observer used to know when this page is covered (tests inject one).
  final RouteObserver<PageRoute<dynamic>>? routeObserver;

  /// When the opener is not the owner-wired live surface the public goal is
  /// withheld (generic title instead).
  final bool hideGoal;

  /// What the chat saw this agent do, step by step; null shows no steps.
  final SubagentStepLog? steps;

  /// Reads what a FINISHED agent did (its goal, steps and result) from
  /// storage when this page never saw its live output. Owner surface only.
  final SubagentFinishedRecordLoader? loadFinishedRecord;

  /// Reads the newest stored messages of the child session while it runs:
  /// the page renders from that snapshot, refreshed every
  /// [childRefresh] while visible ([SubagentChildFeed]). Owner surface only.
  final SubagentChildMessagesReader? readChildMessages;

  /// Finds the child's stored id when its events did not carry it yet.
  final SubagentChildSessionResolver? resolveChildSession;

  const SubagentDetailScreen({
    super.key,
    required this.roster,
    required this.activityKey,
    required this.parentTitle,
    this.canInterrupt,
    this.isInterruptPending,
    this.onStopRequested,
    this.canSteer,
    this.onSteer,
    this.canTail,
    this.onTail,
    this.onOpenConversation,
    this.onRetryGoal,
    this.isOpenPending,
    this.acquirePresentation,
    this.scheduleTailPoll,
    this.openLiveWatch,
    this.delegationControl,
    this.clock,
    this.routeObserver,
    this.hideGoal = false,
    this.steps,
    this.loadFinishedRecord,
    this.readChildMessages,
    this.resolveChildSession,
  });

  /// Hermes Desktop's refresh of a subagent's transcript (2 s,
  /// `subagent-transcript.tsx`).
  static const Duration childRefresh = Duration(seconds: 2);

  static const Duration tailFast = Duration(milliseconds: 1500);
  static const Duration tailSlow = Duration(seconds: 5);

  /// How long an open watch may stay quiet before the polled log fills in
  /// (and, with it, the command in hand, which the roster may report as
  /// «thinking» for its whole run).
  static const Duration watchQuietGrace = tailFast;

  @override
  State<SubagentDetailScreen> createState() => _SubagentDetailScreenState();
}

class _SubagentDetailScreenState extends State<SubagentDetailScreen>
    with WidgetsBindingObserver, RouteAware {
  SubagentActivity? _last;
  VoidCallback? _release;

  // Visibility: this route current (or its live page open) + app resumed.
  bool _routeCurrent = true;
  bool _livePageOpen = false;
  bool _appResumed = true;
  RouteObserver<PageRoute<dynamic>>? _observer;

  final ValueNotifier<SubagentLiveTail> _tail = ValueNotifier(
    const SubagentLiveTail(),
  );
  int _tailGeneration = 0;
  bool _tailInFlight = false;
  bool _tailDirty = false;
  VoidCallback? _cancelTailPoll;
  Duration _tailInterval = SubagentDetailScreen.tailFast;

  // Live watch of the child's mirrored turn. While it is up it is the only
  // source of the log; once it cannot be served the polled tail takes over
  // for the rest of this page's life.
  SubagentLiveWatch? _watch;
  bool _watchUnavailable = false;

  // Whether this page has shown live output of the child: then that log
  // stays once it ends; otherwise a finished child is read from storage.
  bool _sawLiveContent = false;

  // The running child read from its own stored session (owner only).
  SubagentChildFeed? _childFeed;

  final TextEditingController _steer = TextEditingController();
  bool _steerPending = false;
  String? _steerNotice;
  HermesStatusTone _steerTone = HermesStatusTone.neutral;
  bool _steerUnsupported = false;
  bool _stopAwaiting = false;
  bool _technicalOpen = false;
  final GlobalKey _moreKey = GlobalKey(debugLabel: 'subagent-detail-more');
  bool _delegationUnsupported = false;
  bool _delegationBusy = false;
  final ValueNotifier<int> _revision = ValueNotifier(0);
  final ValueNotifier<SubagentLiveWatchView> _liveView = ValueNotifier(
    const SubagentLiveWatchView(),
  );
  void _refresh() {
    if (mounted) _revision.value++;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _appResumed = state == null || state == AppLifecycleState.resumed;
    _release = widget.acquirePresentation?.call();
    widget.roster.addListener(_onRoster);
    widget.steps?.addListener(_onSteps);
    _last = _find();
    final read = widget.readChildMessages;
    if (read != null && !widget.hideGoal) {
      _childFeed = SubagentChildFeed(
        read: read,
        resolve: widget.resolveChildSession,
        schedule: widget.scheduleTailPoll ?? _timerScheduler,
        interval: SubagentDetailScreen.childRefresh,
      )..addListener(_onChildFeed);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTail());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final observer = widget.routeObserver ?? hermesRouteObserver;
    if (route is PageRoute && !identical(observer, _observer)) {
      _observer?.unsubscribe(this);
      _observer = observer;
      observer.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _observer?.unsubscribe(this);
    widget.roster.removeListener(_onRoster);
    widget.steps?.removeListener(_onSteps);
    _stopWatch();
    _stopTail();
    _childFeed
      ?..removeListener(_onChildFeed)
      ..dispose();
    _childFeed = null;
    _revision.dispose();
    _liveView.dispose();
    _release?.call();
    _release = null;
    _tail.dispose();
    _steer.dispose();
    super.dispose();
  }

  void _onSteps() {
    _refresh();
  }

  void _onChildFeed() {
    // Once the child's own rows are on screen they stay when it ends, as a
    // live log does: no swap to the record view and its scroll reset.
    if (_childFeed?.value.hasRows ?? false) _sawLiveContent = true;
  }

  /// Keeps the child's session snapshot fresh exactly while the page is
  /// visible and the child runs (one last read when it ends).
  void _syncChildFeed() {
    _childFeed?.sync(activity: _find() ?? _last, visible: _visible);
  }

  // ── Visibility ───────────────────────────────────────────────────────────

  @override
  void didPushNext() {
    _routeCurrent = false;
    _syncTail();
  }

  @override
  void didPopNext() {
    _routeCurrent = true;
    _syncTail();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _appResumed) return;
    _appResumed = resumed;
    if (!resumed) {
      // Presentation authority follows foreground: give the lease back.
      _release?.call();
      _release = null;
    } else {
      _release ??= widget.acquirePresentation?.call();
    }
    _syncTail();
  }

  bool get _visible => _appResumed && (_routeCurrent || _livePageOpen);

  // ── Roster ───────────────────────────────────────────────────────────────

  SubagentActivity? _find() {
    for (final a in widget.roster.value) {
      if (a.key == widget.activityKey) return a;
    }
    return null;
  }

  void _onRoster() {
    if (!mounted) return;
    final current = _find();
    // A new snapshot of this child means it emitted an event: its tail has
    // likely grown, so read it now instead of waiting out the poll backoff.
    final childChanged =
        current != null && _last != null && !identical(current, _last);
    // Keep the last known snapshot when the roster momentarily empties
    // (cover/poll gap): absence is not evidence of what the child did.
    if (current != null) {
      if (current.isTerminal) _stopAwaiting = false;
      _last = current;
    }
    _refresh();
    _syncChildFeed();
    if (childChanged) {
      _tailOnChildEvent();
    } else {
      _syncTail();
    }
  }

  /// Event-driven tail read, coalesced: a burst during an in-flight read
  /// yields exactly one follow-up read when it lands.
  void _tailOnChildEvent() {
    if (_watch != null) {
      // The watch is the source, but the roster still decides whether the
      // child is alive: a child that ended without message.complete must not
      // keep the runtime and the listener.
      _syncTail();
      return;
    }
    if (!_visible || !_canTailNow(_find())) {
      _syncTail();
      return;
    }
    _tailInterval = SubagentDetailScreen.tailFast;
    if (_tailInFlight) {
      _tailDirty = true;
      return;
    }
    _cancelTailPoll?.call();
    _cancelTailPoll = null;
    _pollTail();
  }

  // ── Live tail ────────────────────────────────────────────────────────────

  bool _canTailNow(SubagentActivity? a) =>
      a != null &&
      subagentIsLive(a) &&
      widget.onTail != null &&
      (widget.canTail?.call(a) ?? true);

  /// Whether the open watch has shown nothing yet: it was opened while the
  /// child already ran a tool, which the mirror does not replay.
  bool get _watchQuiet {
    final view = _liveView.value;
    return view.blocks.isEmpty && view.text.isEmpty;
  }

  void _syncTail() {
    if (!mounted) return;
    _syncChildFeed();
    if (_syncWatch()) {
      // The watch is the source. While it stays quiet the polled log says
      // what the child did so far, so the page is never a lone line over an
      // empty screen; the first thing the watch shows stops it ([_onWatch]).
      if (_watchQuiet && _visible && _canTailNow(_find())) {
        if (_cancelTailPoll == null && !_tailInFlight) {
          _scheduleNextTail(
            _tailGeneration,
            delay: SubagentDetailScreen.watchQuietGrace,
          );
        }
      } else {
        _stopTail();
      }
      return;
    }
    if (_visible && _canTailNow(_find())) {
      if (_cancelTailPoll == null && !_tailInFlight) _pollTail();
    } else {
      _stopTail();
    }
  }

  /// Keeps the live watch open exactly while the page is visible and the child
  /// is working. Returns whether the watch is the log's source right now.
  bool _syncWatch() {
    final activity = _find();
    final wanted =
        _visible &&
        activity != null &&
        subagentIsLive(activity) &&
        widget.openLiveWatch != null &&
        !_watchUnavailable;
    if (!wanted) {
      _stopWatch();
      return false;
    }
    if (_watch == null) {
      final watch = widget.openLiveWatch!(activity);
      if (watch == null) {
        _watchUnavailable = true;
        return false;
      }
      _watch = watch
        ..addListener(_onWatch)
        ..start();
    }
    return true;
  }

  void _stopWatch({bool fromListener = false}) {
    _liveView.value = const SubagentLiveWatchView();
    final watch = _watch;
    if (watch == null) return;
    _watch = null;
    watch.removeListener(_onWatch);
    // A notifier cannot be disposed while it is still notifying.
    if (fromListener) {
      scheduleMicrotask(watch.dispose);
    } else {
      watch.dispose();
    }
  }

  void _onWatch() {
    final watch = _watch;
    if (!mounted || watch == null) return;
    final view = watch.value;
    if (view.status == SubagentLiveWatchStatus.unavailable) {
      _liveView.value = const SubagentLiveWatchView();
      _stopWatch(fromListener: true);
      _watchUnavailable = true;
      // A read scheduled while the watch was quiet waits out its grace; the
      // polled tail is the source now and reads at once.
      _stopTail();
      _refresh();
      _syncTail();
      return;
    }
    _liveView.value = view;
    final hasContent = view.blocks.isNotEmpty || view.text.isNotEmpty;
    if (hasContent) {
      _sawLiveContent = true;
      // The watch speaks now: the log read while it was quiet gives way.
      if (_cancelTailPoll != null || _tailInFlight) _stopTail();
    }
    // An empty watch never wipes the log read while it was quiet.
    if (view.status != SubagentLiveWatchStatus.opening &&
        (hasContent || !_tail.value.available)) {
      _tail.value = _tail.value.apply(
        SubagentTailView(available: true, content: view.text, truncated: false),
      );
    }
  }

  void _stopTail() {
    _tailDirty = false;
    _tailGeneration++;
    _cancelTailPoll?.call();
    _cancelTailPoll = null;
    _tailInFlight = false;
  }

  void _pollTail() {
    final activity = _find();
    if (!mounted || !_visible || !_canTailNow(activity)) return;
    final generation = ++_tailGeneration;
    _tailInFlight = true;
    widget.onTail!(activity!)
        .then((view) {
          if (!mounted || generation != _tailGeneration) return;
          final before = _tail.value.revision;
          _tail.value = _tail.value.apply(view);
          if (_tail.value.lines.any((line) => line.isNotEmpty)) {
            _sawLiveContent = true;
          }
          final changed = _tail.value.revision != before;
          _tailInterval = changed
              ? SubagentDetailScreen.tailFast
              : Duration(
                  milliseconds: (_tailInterval.inMilliseconds * 1.6)
                      .round()
                      .clamp(
                        SubagentDetailScreen.tailFast.inMilliseconds,
                        SubagentDetailScreen.tailSlow.inMilliseconds,
                      ),
                );
        })
        .catchError((Object _) {
          // Transport failure is not `available: false`: keep the last tail.
          if (generation == _tailGeneration) {
            _tailInterval = SubagentDetailScreen.tailSlow;
          }
        })
        .whenComplete(() {
          if (!mounted || generation != _tailGeneration) return;
          _tailInFlight = false;
          if (_tailDirty) {
            _tailDirty = false;
            _tailInterval = SubagentDetailScreen.tailFast;
            _pollTail();
            return;
          }
          _scheduleNextTail(generation);
        });
  }

  void _scheduleNextTail(int generation, {Duration? delay}) {
    if (!_visible || generation != _tailGeneration) return;
    final scheduler = widget.scheduleTailPoll ?? _timerScheduler;
    _cancelTailPoll = scheduler(delay ?? _tailInterval, () {
      _cancelTailPoll = null;
      if (mounted && generation == _tailGeneration) _pollTail();
    });
  }

  static VoidCallback _timerScheduler(Duration delay, VoidCallback callback) {
    final timer = Timer(delay, callback);
    return timer.cancel;
  }

  Future<void> _openLivePage() async {
    final s = Strings.of(context);
    setState(() => _livePageOpen = true);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            SubagentLiveLogPage(
              title: s.subagentUiLiveTitle,
              tail: _tail,
              showTargets: !widget.hideGoal,
            ),
      ),
    );
    if (!mounted) return;
    setState(() => _livePageOpen = false);
    _syncTail();
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _stop(SubagentActivity activity) async {
    final requester = widget.onStopRequested;
    if (requester == null || _stopAwaiting) return;
    setState(() => _stopAwaiting = true);
    var acknowledged = false;
    try {
      acknowledged = await requester(activity);
    } catch (_) {
      acknowledged = false;
    }
    if (!mounted) return;
    if (!acknowledged) setState(() => _stopAwaiting = false);
  }

  Future<void> _sendSteer(SubagentActivity activity) async {
    final sender = widget.onSteer;
    final text = _steer.text.trim();
    if (sender == null || text.isEmpty || _steerPending) return;
    final s = Strings.of(context);
    setState(() {
      _steerPending = true;
      _steerNotice = null;
    });
    try {
      final result = await sender(activity, text);
      if (!mounted) return;
      setState(() {
        _steerPending = false;
        if (result.queued) {
          _steer.clear();
          _steerNotice = s.subagentUiGuideQueued;
          _steerTone = HermesStatusTone.ok;
        } else if (result.status == 'unsupported') {
          _steerUnsupported = true;
          _steerNotice = s.subagentUiGuideUnsupported;
          _steerTone = HermesStatusTone.neutral;
        } else {
          _steerNotice = s.subagentUiGuideRejected;
          _steerTone = HermesStatusTone.error;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _steerPending = false;
        _steerNotice = s.subagentUiGuideRejected;
        _steerTone = HermesStatusTone.error;
      });
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  Future<void> _openDelegationMenu() async {
    final control = widget.delegationControl;
    if (control == null || _delegationBusy) return;
    setState(() => _delegationBusy = true);
    final outcome = await showDelegationPauseMenu(
      context: context,
      anchorKey: _moreKey,
      control: control,
    );
    if (!mounted) return;
    setState(() {
      _delegationBusy = false;
      if (outcome == DelegationPauseOutcome.unsupported) {
        _delegationUnsupported = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: _revision,
    builder: (context, _, _) => _buildDetail(context),
  );

  Widget _buildDetail(BuildContext context) {
    final s = Strings.of(context);
    final activity = _find() ?? _last;
    if (activity == null) {
      return HermesPage(
        title: s.subagentUiRowTitle,
        children: [
          HermesEmptyStateView(
            icon: Icons.account_tree_outlined,
            title: s.subagentUiStatusUnknown,
          ),
        ],
      );
    }
    final now = widget.clock?.call() ?? DateTime.now();
    final live = subagentIsLive(activity);
    final stopping =
        _stopAwaiting || (widget.isInterruptPending?.call(activity) ?? false);
    final status = subagentHumanStatus(s, activity, stopping: stopping);
    final elapsed = subagentElapsed(activity, now);
    final canStop =
        live &&
        widget.onStopRequested != null &&
        (widget.canInterrupt?.call(activity) ?? false);
    final canOpen =
        activity.canResumeChildTranscript && widget.onOpenConversation != null;
    // A delegation that failed before it ever had a child: nothing to open
    // or resume, only the goal to send again.
    // The goal reaches the app clipped (512 or 1024 characters, by path):
    // one that may have been cut is not offered for a resend, which would
    // put half a task in the composer without saying so.
    final retryGoal = activity.goalPreview?.trim() ?? '';
    final canRetry =
        !widget.hideGoal &&
        widget.onRetryGoal != null &&
        activity.phase == SubagentActivityPhase.failed &&
        activity.subagentId == null &&
        activity.childSessionId == null &&
        retryGoal.isNotEmpty &&
        retryGoal.runes.length < SubagentPayloadLimits.goalCharacters;
    final opening = widget.isOpenPending?.call(activity) ?? false;
    final canSteer =
        live &&
        !_steerUnsupported &&
        widget.onSteer != null &&
        (widget.canSteer?.call(activity) ?? false);

    // the owner, style 1 of the action buttons: a glass pill, centred and loose;
    // «Detener» red only in its square outline and its words.
    Widget? primary;
    if (canStop || (live && stopping)) {
      primary = Center(
        child: HermesGlassActionButton(
          key: const ValueKey('subagent-detail-stop'),
          destructive: true,
          icon: Icons.crop_square_rounded,
          label: stopping ? s.subagentUiStatusStopping : s.subagentUiStop,
          onPressed: stopping ? null : () => _stop(activity),
        ),
      );
    } else if (canRetry) {
      primary = Center(
        child: HermesGlassActionButton(
          key: const ValueKey('subagent-detail-retry'),
          icon: Icons.refresh_rounded,
          label: s.subagentUiRetry,
          onPressed: () {
            widget.onRetryGoal!(retryGoal);
            Navigator.of(context).maybePop();
          },
        ),
      );
    } else if (!live && canOpen) {
      primary = Center(
        child: HermesGlassActionButton(
          key: const ValueKey('subagent-detail-open'),
          icon: Icons.forum_outlined,
          label: s.subagentUiOpenConversation,
          onPressed: opening
              ? null
              : () => widget.onOpenConversation!(activity),
        ),
      );
    }

    final owner = !widget.hideGoal;
    // The title already says a short goal; the assignment block is for the
    // whole text of a long one.
    final fullGoal = owner ? (activity.goalPreview?.trim() ?? '') : '';
    final goal = fullGoal.contains('\n') || fullGoal.runes.length > 60
        ? fullGoal
        : '';
    final steps = widget.steps?.stepsOf(activity.key) ?? const <SubagentStep>[];
    final thought = owner
        ? cleanReasoningTail(
            activity.details.detailPreview ?? '',
            keep: 1500,
            window: 4000,
          )
        : '';
    // The result of an agent that ended; while it still works, what it has
    // written so far, as a partial result.
    final ended = activity.isTerminal;
    final result = ended || owner ? (activity.resultPreview?.trim() ?? '') : '';
    final lastLog = _tail.value.available && _tail.value.lines.isNotEmpty;

    if (widget.openLiveWatch != null) {
      return Scaffold(
        key: const ValueKey('subagent-detail'),
        appBar: HermesAppBar(
          title: Text(
            widget.hideGoal ? s.subagentUiRowTitle : subagentTitle(s, activity),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (widget.delegationControl != null && !_delegationUnsupported)
              IconButton(
                key: _moreKey,
                tooltip: s.cphMore,
                icon: const Icon(Icons.more_vert_rounded),
                onPressed: _delegationBusy ? null : _openDelegationMenu,
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              // What the child does now, under the header: the official
              // app's «Using terminal» line of a running subagent's chat.
              if (live && _childFeed != null)
                ValueListenableBuilder<SubagentChildFeedView>(
                  valueListenable: _childFeed!,
                  builder: (context, feed, _) {
                    final tool = feed.transcript.runningTool;
                    final roster = _activityLabel(s, activity);
                    return _NowLine(
                      label: tool != null
                          ? s.subagentUiStepTool(tool.tool ?? '')
                          : roster.isNotEmpty
                          ? roster
                          : status.label,
                      detail: tool != null
                          ? tool.command ?? ''
                          : _activityDetail(activity),
                    );
                  },
                ),
              Expanded(
                child:
                    activity.isTerminal &&
                        !_sawLiveContent &&
                        widget.loadFinishedRecord != null &&
                        !widget.hideGoal
                    ? SubagentFinishedView(
                        key: ValueKey(
                          'subagent-finished-${activity.key.stableId}',
                        ),
                        load: () => widget.loadFinishedRecord!(activity),
                        showTargets: owner,
                      )
                    : SubagentStreamView(
                        tail: _tail,
                        live: _liveView,
                        prompt: widget.hideGoal ? '' : fullGoal,
                        working: live,
                        result: result,
                        showTargets: owner,
                        activityLabel: _activityLabel(s, activity),
                        activityDetail: owner ? _activityDetail(activity) : '',
                        activitySince: steps.isNotEmpty && steps.last.isOpen
                            ? steps.last.startedAt
                            : null,
                        active: _visible,
                        clock: widget.clock,
                        child: _childFeed,
                      ),
              ),
              if (activity.isTerminal)
                SizedBox(
                  height: HermesSpace.tap,
                  child: Center(
                    child: HermesStatusText(
                      label: status.label,
                      tone: status.tone,
                    ),
                  ),
                )
              else
                ValueListenableBuilder<SubagentLiveWatchView>(
                  valueListenable: _liveView,
                  // A sealed text stream is not proof that the child ended.
                  builder: (context, view, _) => SubagentWorkPill(
                    working:
                        live &&
                        view.status != SubagentLiveWatchStatus.reconnecting,
                    showCount: false,
                    unconfirmed:
                        activity.phase == SubagentActivityPhase.unknown ||
                        view.status == SubagentLiveWatchStatus.reconnecting,
                    count: SubagentGroupCount.none,
                    startedAt: activity.details.startedAt,
                    clock: widget.clock,
                    active: _visible,
                  ),
                ),
              if (canSteer)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HermesSpace.pageH,
                    vertical: HermesSpace.x2,
                  ),
                  child: _SteerField(
                    controller: _steer,
                    pending: _steerPending,
                    onSend: () => _sendSteer(activity),
                  ),
                ),
              if (_steerNotice != null)
                Text(_steerNotice!, style: HermesType.support),
              ?primary,
            ],
          ),
        ),
      );
    }
    return ActivityTicker(
      active: live && _visible,
      clock: widget.clock,
      builder: (context, now) => HermesDetailScaffold(
        listKey: const ValueKey('subagent-detail'),
        appBarTitle: s.subagentUiRowTitle,
        title: widget.hideGoal
            ? s.subagentUiRowTitle
            : subagentTitle(s, activity),
        status: HermesStatusText(
          key: const ValueKey('subagent-detail-status'),
          label: status.label,
          tone: status.tone,
          meta: subagentElapsed(activity, now) == null
              ? null
              : formatTurnElapsed(subagentElapsed(activity, now)!),
        ),
        primaryAction: primary,
        actions: [
          if (widget.delegationControl != null && !_delegationUnsupported)
            IconButton(
              key: _moreKey,
              tooltip: s.cphMore,
              icon: const Icon(Icons.more_vert_rounded),
              onPressed: _delegationBusy ? null : _openDelegationMenu,
            ),
        ],
        sections: [
          if (goal.isNotEmpty) ...[
            HermesSectionHeader(s.sv2TaskSection),
            HermesTextBlock(
              key: const ValueKey('subagent-detail-task'),
              text: goal,
              collapsedLines: 5,
              copyable: true,
              openTitle: s.sv2TaskSection,
            ),
          ],
          if (!live && lastLog) ...[
            HermesSectionHeader(s.sv2LastLog),
            _LivePanel(
              tail: _tail,
              onOpen: _openLivePage,
              paused: !_visible,
              showTargets: owner,
            ),
          ],
          if (live && widget.onTail != null) ...[
            HermesSectionHeader(
              s.subagentUiSectionLive,
              trailing: _LiveDot(active: _visible),
            ),
            _LivePanel(
              tail: _tail,
              onOpen: _openLivePage,
              paused: !_visible,
              showTargets: owner,
              reconnecting:
                  _watch?.value.status == SubagentLiveWatchStatus.reconnecting,
            ),
          ],
          if (canSteer) ...[
            HermesSectionHeader(s.subagentUiSectionGuide),
            _SteerField(
              controller: _steer,
              pending: _steerPending,
              onSend: () => _sendSteer(activity),
            ),
          ],
          if (_steerNotice != null) ...[
            const SizedBox(height: HermesSpace.x2),
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: HermesStatusText(
                key: const ValueKey('subagent-steer-notice'),
                label: _steerNotice!,
                tone: _steerTone,
                meta: _steerTone == HermesStatusTone.ok
                    ? s.subagentUiGuideMissedNote
                    : null,
                maxLines: 3,
              ),
            ),
          ],
          HermesSectionHeader(
            live ? s.subagentUiSectionNow : s.subagentUiSectionDid,
          ),
          _Timeline(activity: activity, now: now),
          HermesSectionHeader(s.sv2StepsSection),
          _Steps(steps: steps, now: now, showTargets: owner),
          if (thought.isNotEmpty) _Thought(text: thought),
          if (result.isNotEmpty) ...[
            HermesSectionHeader(
              ended ? s.subagentUiSectionResult : s.sv2ResultPartial,
            ),
            if (ended && activity.phase != SubagentActivityPhase.completed)
              _Note(text: s.sv2LeftBehind),
            _ResultBlock(text: result),
          ] else if (ended &&
              activity.phase == SubagentActivityPhase.completed) ...[
            HermesSectionHeader(s.subagentUiSectionResult),
            _Note(text: s.sv2NoResultYet),
          ],
          HermesSectionHeader(s.subagentUiSectionBelongs),
          HermesListGroup(
            children: [
              HermesListRow(
                key: const ValueKey('subagent-detail-parent'),
                icon: Icons.chat_bubble_outline_rounded,
                title: widget.parentTitle.trim().isEmpty
                    ? s.subagentUiParentChat
                    : widget.parentTitle,
                subtitle: s.subagentUiParentHint,
                onTap: () => Navigator.of(context).maybePop(),
              ),
              if (canOpen && live)
                HermesListRow(
                  key: const ValueKey('subagent-detail-open-row'),
                  icon: Icons.forum_outlined,
                  title: s.subagentUiOpenConversation,
                  subtitle: s.subagentUiOpenConversationHint,
                  onTap: opening
                      ? null
                      : () => widget.onOpenConversation!(activity),
                ),
            ],
          ),
          ..._technical(s, activity, elapsed),
        ],
      ),
    );
  }

  /// The roster's "now" for the live stream: only states the stream itself
  /// may not show (thinking, a tool the mirror does not list).
  static String _activityLabel(Strings s, SubagentActivity activity) {
    final tool = activity.details.activeToolName?.trim() ?? '';
    return switch (activity.phase) {
      SubagentActivityPhase.thinking => s.subagentUiStepThinking,
      SubagentActivityPhase.tool =>
        tool.isEmpty ? s.subagentUiStepToolGeneric : s.subagentUiStepTool(tool),
      _ => '',
    };
  }

  /// Owner-only: the end of its thought, or the target of its tool.
  static String _activityDetail(SubagentActivity activity) {
    final details = activity.details;
    return switch (activity.phase) {
      SubagentActivityPhase.thinking => cleanReasoningTail(
        details.detailPreview ?? '',
        keep: 240,
        window: 4000,
      ),
      SubagentActivityPhase.tool =>
        subagentLiveTarget(details.activeToolPreview) ?? '',
      _ => '',
    };
  }

  List<Widget> _technical(
    Strings s,
    SubagentActivity activity,
    Duration? elapsed,
  ) {
    final usage = activity.usage;
    final d = activity.details;
    final rows = <(String, String)>[
      if (d.model?.trim().isNotEmpty == true)
        (s.subagentUiTechModel, d.model!.trim()),
      if (usage?.inputTokens case final v?) (s.subagentUiTechTokensIn, '$v'),
      if (usage?.outputTokens case final v?) (s.subagentUiTechTokensOut, '$v'),
      if (usage?.reasoningTokens case final v?)
        (s.subagentUiTechReasoning, '$v'),
      if (usage?.apiCalls case final v?) (s.subagentUiTechCalls, '$v'),
      if (usage?.costUsd case final v?)
        (s.subagentUiTechCost, '\$${v.toStringAsFixed(4)}'),
      if (elapsed != null)
        (s.subagentUiTechDuration, formatTurnElapsed(elapsed)),
      if (d.toolsets.isNotEmpty)
        (s.subagentUiTechToolsets, d.toolsets.join(', ')),
      if (d.depth case final v?) (s.subagentUiTechDepth, '$v'),
    ];
    if (rows.isEmpty) return const [];
    return [
      const SizedBox(height: HermesSpace.x5),
      HermesListGroup(
        dividerIndent: HermesSpace.rowH,
        children: [
          HermesListRow(
            key: const ValueKey('subagent-detail-technical'),
            icon: Icons.tune_rounded,
            title: s.subagentUiTechnical,
            onTap: () => setState(() => _technicalOpen = !_technicalOpen),
            trailing: Icon(
              _technicalOpen
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded,
              size: 20,
              color: Theme.of(context).hermes.textSecondary,
            ),
          ),
          if (_technicalOpen)
            for (final (label, value) in rows)
              HermesListRow(title: label, value: value, muted: true),
        ],
      ),
    ];
  }
}

/// One line under the header while the child works: what it does now and,
/// for the owner, on what (its command, masked).
class _NowLine extends StatelessWidget {
  const _NowLine({required this.label, required this.detail});

  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final target = detail.trim();
    return Padding(
      key: const ValueKey('subagent-detail-now'),
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.pageH,
        HermesSpace.x1,
        HermesSpace.pageH,
        HermesSpace.x1,
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: label),
            if (target.isNotEmpty)
              TextSpan(
                text: ' · $target',
                style: TextStyle(
                  fontFamily: HermesType.monoFamily,
                  fontSize: 12,
                  color: colors.textSecondary,
                ),
              ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: HermesType.support.copyWith(color: colors.textSecondary),
      ),
    );
  }
}

class _LiveDot extends StatelessWidget {
  final bool active;
  const _LiveDot({required this.active});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      width: 7,
      height: 7,
      margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(
        color: active ? colors.error : colors.textDisabled,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Last lines of the live tail in the page (no own scroll: the page scrolls
/// once; the full, auto-following view is [SubagentLiveLogPage]).
class _LivePanel extends StatelessWidget {
  final ValueListenable<SubagentLiveTail> tail;
  final VoidCallback onOpen;
  final bool paused;
  final bool reconnecting;

  /// Commands, outputs and the child's words: the owner's only.
  final bool showTargets;

  static const int visibleLines = 10;

  /// Rows of the server's live transcript the panel shows, newest last.
  static const int visibleRows = 4;

  const _LivePanel({
    required this.tail,
    required this.onOpen,
    required this.paused,
    this.showTargets = false,
    this.reconnecting = false,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return ValueListenableBuilder<SubagentLiveTail>(
      valueListenable: tail,
      builder: (context, value, _) {
        String? note;
        Widget body;
        if (!value.loaded) {
          note = paused ? s.subagentUiLivePaused : s.subagentUiLiveWaiting;
          body = const SizedBox.shrink();
        } else if (!value.available) {
          note = s.subagentUiLiveUnavailable;
          body = const SizedBox.shrink();
        } else {
          final lines = value.lines;
          final start = lines.length > visibleLines
              ? lines.length - visibleLines
              : 0;
          final visible = lines.sublist(start).join('\n').trimRight();
          note = reconnecting
              ? s.islandReconnecting
              : paused
              ? s.subagentUiLivePaused
              : value.truncated || start > 0
              ? s.subagentUiLiveTruncated
              : null;
          // The server's live transcript reads as rows, never as raw log.
          final rows = isSubagentTailLog(value.text)
              ? [
                  for (final row in parseSubagentTailLog(
                    value.text,
                    truncated: value.truncated,
                  ))
                    ?subagentTailRow(row, showTargets: showTargets),
                ]
              : null;
          body = rows != null
              ? Column(
                  key: const ValueKey('subagent-live-rows'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows.length > visibleRows
                      ? rows.sublist(rows.length - visibleRows)
                      : rows,
                )
              : visible.isEmpty
              ? const SizedBox.shrink()
              : Text(
                  visible,
                  key: const ValueKey('subagent-live-text'),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.45,
                    color: colors.textPrimary,
                  ),
                );
        }
        return RepaintBoundary(
          child: HermesListGroup(
            key: const ValueKey('subagent-live-panel'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HermesSpace.rowH,
                  HermesSpace.x3,
                  HermesSpace.rowH,
                  HermesSpace.x1,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    body,
                    if (note != null)
                      Padding(
                        padding: EdgeInsets.only(
                          top: body is SizedBox ? 0 : HermesSpace.x2,
                        ),
                        child: Text(
                          note,
                          key: const ValueKey('subagent-live-note'),
                          style: HermesType.support.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    if (value.available && value.lines.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          key: const ValueKey('subagent-live-open'),
                          onPressed: onOpen,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 44),
                            padding: EdgeInsets.zero,
                            foregroundColor: colors.accentText,
                          ),
                          child: Text(s.subagentUiLiveOpen),
                        ),
                      )
                    else
                      const SizedBox(height: HermesSpace.x2),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SteerField extends StatelessWidget {
  final TextEditingController controller;
  final bool pending;
  final VoidCallback onSend;

  const _SteerField({
    required this.controller,
    required this.pending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    // A pill: the field and its «Enviar» pill share one thin outline.
    return DecoratedBox(
      key: const ValueKey('subagent-steer-pill'),
      decoration: ShapeDecoration(
        color: chrome.raised,
        shape: StadiumBorder(side: BorderSide(color: chrome.line)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: HermesSpace.x4,
          end: HermesSpace.x1,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('subagent-steer-input'),
                controller: controller,
                enabled: !pending,
                maxLines: 1,
                maxLength: 512,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                style: HermesType.text.copyWith(color: colors.textPrimary),
                decoration: InputDecoration(
                  hintText: s.subFGuideHint,
                  counterText: '',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: HermesSpace.x4,
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) => Tooltip(
                message: s.subagentUiGuideSend,
                child: HermesGlassActionButton(
                  key: const ValueKey('subagent-steer-send'),
                  label: s.subFGuideSend,
                  onPressed: pending || value.text.trim().isEmpty
                      ? null
                      : onSend,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The edge of a step's mark in this page: the chat timeline's own size.
const double _stepIconSize = 16;

/// What a subagent's step was doing, as one of the chat's icons: the same
/// terminal / wrench / reasoning glyphs the chat's own steps show.
ChatLiveGlyph _stepGlyph(SubagentActivityPhase phase, String? tool) =>
    switch (phase) {
      SubagentActivityPhase.tool => chatLiveGlyphForTool(tool),
      SubagentActivityPhase.thinking => ChatLiveGlyph.reasoning,
      SubagentActivityPhase.requested => ChatLiveGlyph.queued,
      _ => ChatLiveGlyph.delegateTask,
    };

/// The mark of the step in hand: its glyph, playing while it runs; the
/// outline check once it ended well, the outline error sign in the error ink
/// when it failed (and in the quiet ink when it was stopped), and the quiet
/// question mark when its state is not known. One outline family, one quiet
/// ink, never a filled badge.
Widget _subagentPhaseIcon(HermesThemeColors colors, SubagentActivity activity) {
  const key = ValueKey('subagent-detail-current-icon');
  final phase = activity.phase;
  if (phase == SubagentActivityPhase.unknown) {
    return Icon(
      Icons.help_outline_rounded,
      key: key,
      size: _stepIconSize,
      color: colors.textTertiary,
    );
  }
  final (glyph, live, ink) = switch (phase) {
    SubagentActivityPhase.completed => (
      ChatLiveGlyph.check,
      false,
      colors.textSecondary,
    ),
    SubagentActivityPhase.failed => (ChatLiveGlyph.error, false, colors.error),
    SubagentActivityPhase.cancelled => (
      ChatLiveGlyph.error,
      false,
      colors.textSecondary,
    ),
    _ => (
      _stepGlyph(phase, activity.details.activeToolName?.trim()),
      true,
      colors.textSecondary,
    ),
  };
  return ChatLiveIcon(
    key: key,
    glyph,
    live: live,
    size: _stepIconSize,
    color: ink,
  );
}

class _Timeline extends StatelessWidget {
  final SubagentActivity activity;
  final DateTime now;

  const _Timeline({required this.activity, required this.now});

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final d = activity.details;
    final rows =
        <({String title, String? value, HermesStatusTone tone, ChatLiveGlyph? glyph})>[];
    if (d.startedAt case final started?) {
      final local = started.toLocal();
      final hh = local.hour.toString().padLeft(2, '0');
      final mm = local.minute.toString().padLeft(2, '0');
      rows.add((
        title: s.subagentUiStepStarted,
        value: '$hh:$mm',
        tone: HermesStatusTone.neutral,
        glyph: ChatLiveGlyph.delegateTask,
      ));
    }
    if (subagentCompletionTime(activity) case final ended?) {
      rows.add((
        title: s.subagentUiStepFinished,
        value: ended,
        tone: HermesStatusTone.neutral,
        glyph: ChatLiveGlyph.check,
      ));
    }
    if (activity.progress case final p?) {
      rows.add((
        title: s.subagentActivityProgress(p.displayTaskIndex, p.taskCount),
        value: null,
        tone: HermesStatusTone.neutral,
        glyph: ChatLiveGlyph.parallelTools,
      ));
    }
    if (d.toolCount case final count? when count > 0) {
      rows.add((
        title: s.subagentUiStepTools(count),
        value: null,
        tone: HermesStatusTone.neutral,
        glyph: ChatLiveGlyph.toolCall,
      ));
    }
    final read = d.filesReadCount;
    final written = d.filesWrittenCount;
    if ((read ?? 0) > 0 || (written ?? 0) > 0) {
      rows.add((
        title: s.subagentUiStepFiles('${read ?? 0}', '${written ?? 0}'),
        value: null,
        tone: HermesStatusTone.neutral,
        glyph: ChatLiveGlyph.toolCall,
      ));
    }
    final tool = d.activeToolName?.trim();
    final current = switch (activity.phase) {
      SubagentActivityPhase.requested => (
        s.subagentUiStepQueued,
        HermesStatusTone.active,
      ),
      SubagentActivityPhase.running => (
        s.subagentUiStepWorking,
        HermesStatusTone.active,
      ),
      SubagentActivityPhase.thinking => (
        s.subagentUiStepThinking,
        HermesStatusTone.active,
      ),
      SubagentActivityPhase.tool => (
        tool == null || tool.isEmpty
            ? s.subagentUiStepToolGeneric
            : s.subagentUiStepTool(tool),
        HermesStatusTone.active,
      ),
      // Its value is how long it took, so the row says «Duración 0:04»;
      // «Terminó» is the wall-clock row above it.
      SubagentActivityPhase.completed => (
        subagentElapsed(activity, now) == null
            ? s.subagentUiStepFinished
            : s.subagentUiTechDuration,
        HermesStatusTone.ok,
      ),
      SubagentActivityPhase.failed => (
        s.subagentUiStepFailed,
        HermesStatusTone.error,
      ),
      SubagentActivityPhase.cancelled => (
        s.subagentUiStepStopped,
        HermesStatusTone.neutral,
      ),
      SubagentActivityPhase.unknown => (
        s.subagentUiStatusUnknown,
        HermesStatusTone.neutral,
      ),
    };
    final elapsed = subagentElapsed(activity, now);
    rows.add((
      title: current.$1,
      value: elapsed == null ? null : formatTurnElapsed(elapsed),
      tone: current.$2,
      glyph: null,
    ));
    return HermesListGroup(
      key: const ValueKey('subagent-detail-timeline'),
      dividerIndent: 40,
      children: [
        for (var i = 0; i < rows.length; i++)
          HermesListRow(
            key: i == rows.length - 1
                ? const ValueKey('subagent-detail-current-step')
                : null,
            // Every row has its mark, in the chat's one outline family and
            // its quiet ink: the facts (started, ended, tools, files) rest,
            // the step in hand plays while it runs.
            leading: SizedBox.square(
              dimension: _stepIconSize,
              child: i == rows.length - 1
                  ? _subagentPhaseIcon(colors, activity)
                  : ChatLiveIcon(
                      key: ValueKey('subagent-detail-fact-icon-$i'),
                      rows[i].glyph ?? ChatLiveGlyph.delegateTask,
                      size: _stepIconSize,
                      color: colors.textSecondary,
                    ),
            ),
            title: rows[i].title,
            muted: i != rows.length - 1,
            value: rows[i].value,
          ),
      ],
    );
  }
}

/// A small supporting line under a section header.
class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HermesSpace.rowH,
        vertical: HermesSpace.x1,
      ),
      child: Text(
        text,
        style: HermesType.support.copyWith(color: colors.textSecondary),
      ),
    );
  }
}

/// The steps seen, marked with the chat's own step icons: a verb (what it
/// was doing), its target and how long it took; the step in
/// hand last, with its clock running. When few are known it says why.
class _Steps extends StatelessWidget {
  const _Steps({
    required this.steps,
    required this.now,
    required this.showTargets,
  });

  final List<SubagentStep> steps;
  final DateTime now;
  final bool showTargets;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    if (steps.isEmpty) {
      return _Note(text: s.sv2StepsPartial);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesListGroup(
          key: const ValueKey('subagent-detail-steps'),
          dividerIndent: 40,
          children: [
            for (final (i, step) in steps.indexed)
              HermesListRow(
                key: ValueKey('subagent-detail-step-$i'),
                leading: SizedBox.square(
                  dimension: _stepIconSize,
                  child: ChatLiveIcon(
                    key: ValueKey('subagent-detail-step-icon-$i'),
                    _stepGlyph(step.phase, step.tool),
                    live: step.isOpen,
                    size: _stepIconSize,
                    color: colors.textSecondary,
                  ),
                ),
                title: _verb(s, step),
                subtitle: showTargets
                    ? subagentLiveTarget(step.target)
                    : null,
                muted: !step.isOpen,
                value: formatTurnElapsed(step.durationAt(now)),
              ),
          ],
        ),
        if (steps.length < 3) _Note(text: s.sv2StepsPartial),
      ],
    );
  }

  static String _verb(Strings s, SubagentStep step) => switch (step.phase) {
    SubagentActivityPhase.tool =>
      step.tool == null
          ? s.subagentUiStepToolGeneric
          : s.subagentUiStepTool(step.tool!),
    SubagentActivityPhase.thinking => s.subagentUiStatusThinking,
    SubagentActivityPhase.requested => s.subagentUiStepQueued,
    _ => s.subagentUiStepWorking,
  };
}

/// What the agent thinks, as clean prose in a fold (closed by default: the
/// result is what matters; the thought is there to be read when asked).
class _Thought extends StatefulWidget {
  const _Thought({required this.text});

  final String text;

  @override
  State<_Thought> createState() => _ThoughtState();
}

class _ThoughtState extends State<_Thought> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.only(top: HermesSpace.x4),
      child: HermesListGroup(
        children: [
          HermesListRow(
            key: const ValueKey('subagent-detail-thought-toggle'),
            icon: Icons.psychology_outlined,
            title: s.sv2ThoughtSection,
            onTap: () => setState(() => _open = !_open),
            trailing: Icon(
              _open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 20,
              color: colors.textSecondary,
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HermesSpace.rowH,
                HermesSpace.x1,
                HermesSpace.rowH,
                HermesSpace.x3,
              ),
              child: Text(
                widget.text,
                key: const ValueKey('subagent-detail-thought'),
                style: HermesType.support.copyWith(
                  color: colors.textSecondary,
                  height: 1.45,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The result as the chat renders an answer (Markdown), not as raw text.
class _ResultBlock extends StatelessWidget {
  const _ResultBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return HermesListGroup(
      key: const ValueKey('subagent-detail-result'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HermesSpace.rowH,
            vertical: HermesSpace.x3,
          ),
          child: ChatMarkdownBody(data: text),
        ),
      ],
    );
  }
}

/// Full-screen, auto-following live output. Follows the bottom unless the
/// person scrolls up; "Follow" jumps back. Append-only list rendering.
class SubagentLiveLogPage extends StatefulWidget {
  final String title;
  final ValueListenable<SubagentLiveTail> tail;

  /// Commands, outputs and the child's words: the owner's only.
  final bool showTargets;

  const SubagentLiveLogPage({
    super.key,
    required this.title,
    required this.tail,
    this.showTargets = false,
  });

  @override
  State<SubagentLiveLogPage> createState() => _SubagentLiveLogPageState();
}

class _SubagentLiveLogPageState extends State<SubagentLiveLogPage> {
  final ScrollController _scroll = ScrollController();
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    widget.tail.addListener(_onTail);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jump());
  }

  @override
  void dispose() {
    widget.tail.removeListener(_onTail);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atEnd =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 24;
    if (atEnd != _follow) setState(() => _follow = atEnd);
  }

  void _onTail() {
    if (_follow) WidgetsBinding.instance.addPostFrameCallback((_) => _jump());
  }

  void _jump() {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12.5,
      height: 1.5,
      color: colors.textPrimary,
    );
    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: s.commonCopy,
            icon: const Icon(Icons.copy_rounded),
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: widget.tail.value.text),
              );
              if (context.mounted) {
                AppFeedback.of(
                  context,
                ).notify(FeedbackKind.routine, s.designCopied);
              }
            },
          ),
        ],
      ),
      floatingActionButton: _follow
          ? null
          : FloatingActionButton.small(
              key: const ValueKey('subagent-live-follow'),
              tooltip: s.subagentUiLiveFollow,
              onPressed: () {
                setState(() => _follow = true);
                _jump();
              },
              child: const Icon(Icons.arrow_downward_rounded),
            ),
      body: SafeArea(
        top: false,
        child: ValueListenableBuilder<SubagentLiveTail>(
          valueListenable: widget.tail,
          builder: (context, value, _) {
            // The server's live transcript reads as rows, never as raw log.
            final rows = isSubagentTailLog(value.text)
                ? [
                    for (final row in parseSubagentTailLog(
                      value.text,
                      truncated: value.truncated,
                    ))
                      ?subagentTailRow(row, showTargets: widget.showTargets),
                  ]
                : null;
            return ListView.builder(
              clipBehavior: hermesUnderHeader,
              key: const ValueKey('subagent-live-log'),
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(
                HermesSpace.pageH,
                HermesSpace.pageTop,
                HermesSpace.pageH,
                HermesSpace.pageBottom,
              ),
              itemCount: rows?.length ?? value.lines.length,
              itemBuilder: (context, i) =>
                  rows?[i] ?? Text(value.lines[i], style: style),
            );
          },
        ),
      ),
    );
  }
}

/// Read-only transcript of a finished (or running) child conversation. The
/// loader uses a read-only connection copy; there is no composer and no
/// mutation affordance.
class SubagentTranscriptPage extends StatefulWidget {
  final String title;
  final Future<List<Map<String, dynamic>>> Function() load;

  const SubagentTranscriptPage({
    super.key,
    required this.title,
    required this.load,
  });

  @override
  State<SubagentTranscriptPage> createState() => _SubagentTranscriptPageState();
}

class _SubagentTranscriptPageState extends State<SubagentTranscriptPage> {
  late Future<List<Map<String, dynamic>>> _future = widget.load();

  static String _text(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .whereType<Map>()
          .where((p) => p['type'] == 'text' && p['text'] is String)
          .map((p) => p['text'] as String)
          .join('\n');
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snap) {
        final children = <Widget>[];
        if (snap.connectionState != ConnectionState.done) {
          children.add(
            Padding(
              padding: const EdgeInsets.all(HermesSpace.x8),
              child: Center(
                child: ConsoleLoader.medium(
                  showLabel: true,
                  label: s.subagentUiLiveWaiting,
                ),
              ),
            ),
          );
        } else if (snap.hasError) {
          children.add(
            HermesEmptyStateView(
              icon: Icons.cloud_off_rounded,
              title: snap.error is ProfileTranscriptAccessRequired
                  ? s.chaErrProfileDashboardAccess
                  : s.subagentUiTranscriptError,
              actionLabel: s.subagentUiRetry,
              onAction: () {
                // FutureBuilder subscribes on the next frame: keep a failed
                // retry from surfacing as an uncaught error before then.
                final retry = widget.load()..ignore();
                setState(() {
                  _future = retry;
                });
              },
            ),
          );
        } else {
          var firstUser = true;
          for (final m in snap.data ?? const <Map<String, dynamic>>[]) {
            final role = m['role'];
            if (role != 'user' && role != 'assistant') continue;
            final raw = _text(m['content']);
            final text = role == 'assistant'
                ? finalizedPublicAssistantText(raw).trim()
                : raw.trim();
            if (text.isEmpty) continue;
            if (role == 'user') {
              children.add(
                HermesSectionHeader(
                  firstUser ? s.subagentUiTranscriptTask : s.sesUiMessages,
                ),
              );
              children.add(HermesTextBlock(text: text, collapsedLines: 8));
              firstUser = false;
            } else {
              children.add(const SizedBox(height: HermesSpace.x4));
              children.add(
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChatMarkdownBody(data: text),
                ),
              );
            }
          }
          if (children.isEmpty) {
            children.add(
              HermesEmptyStateView(
                icon: Icons.forum_outlined,
                title: s.subagentUiTranscriptEmpty,
              ),
            );
          }
        }
        return HermesPage(
          title: widget.title,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: HermesTag(
                  label: s.subagentUiTranscriptReadOnly,
                  tone: HermesStatusTone.neutral,
                ),
              ),
            ),
          ],
          children: [
            DefaultTextStyle.merge(
              style: TextStyle(color: colors.textPrimary),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ],
        );
      },
    );
  }
}
