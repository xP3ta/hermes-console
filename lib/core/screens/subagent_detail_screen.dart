// Spec 080 step 7 — action-first detail page of ONE delegated subagent.
//
// Replaces the generic session "profile" (metric boxes, disabled buttons) that
// tapping a subagent used to open. The page answers: what is it doing, is it
// still working, and what can I do (Stop / Guide / read its conversation).
//
// Privacy: only bounded public-display fields are rendered (goal, phase,
// public tool name, counts, result summary once finished, the owner-scoped
// `subagent.tail`). Reasoning (`detailPreview`), tool arguments
// (`activeToolPreview`) and opaque identifiers are never shown.
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
import '../theme/app_theme.dart';
import '../utils/assistant_content.dart' show finalizedPublicAssistantText;
import '../widgets/activity_pill.dart' show formatTurnElapsed;
import '../widgets/chat/chat_markdown_body.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/subagent_activity_card.dart'
    show
        SubagentTailView,
        SubagentTailLoader,
        SubagentSteerSender,
        SubagentStopRequester,
        SubagentTailScheduler;

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
      label: s.subagentUiStatusUnknown,
      tone: HermesStatusTone.neutral,
    ),
  };
}

/// Elapsed (running) or total (finished) time from authoritative fields only.
Duration? subagentElapsed(SubagentActivity activity, DateTime now) {
  final details = activity.details;
  if (details.durationSeconds case final seconds?) {
    if (seconds.isFinite && seconds >= 0) {
      return Duration(milliseconds: (seconds * 1000).round());
    }
  }
  final started = details.startedAt;
  if (started == null) return null;
  final end = details.completedAt ?? now.toUtc();
  final elapsed = end.difference(started);
  return elapsed.isNegative ? null : elapsed;
}

/// Short human title: the public goal, or the generic noun.
String subagentTitle(Strings s, SubagentActivity activity, {int? maxChars}) {
  final goal = activity.goalPreview?.trim() ?? '';
  if (goal.isEmpty) return s.subagentUiRowTitle;
  final line = goal.split('\n').first.trim();
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
  final bool Function(SubagentActivity activity)? isOpenPending;

  /// Holds the chat's subagent presentation lease while this page is up so
  /// the authoritative roster and controls stay valid when the chat is
  /// covered. Returns the release callback.
  final VoidCallback Function()? acquirePresentation;

  final SubagentTailScheduler? scheduleTailPoll;
  final DateTime Function()? clock;

  /// Route observer used to know when this page is covered (tests inject one).
  final RouteObserver<PageRoute<dynamic>>? routeObserver;

  /// When the opener is not the owner-wired live surface the public goal is
  /// withheld (generic title instead).
  final bool hideGoal;

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
    this.isOpenPending,
    this.acquirePresentation,
    this.scheduleTailPoll,
    this.clock,
    this.routeObserver,
    this.hideGoal = false,
  });

  static const Duration tailFast = Duration(milliseconds: 1500);
  static const Duration tailSlow = Duration(seconds: 5);

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
  VoidCallback? _cancelTailPoll;
  Duration _tailInterval = SubagentDetailScreen.tailFast;

  final TextEditingController _steer = TextEditingController();
  bool _steerPending = false;
  String? _steerNotice;
  HermesStatusTone _steerTone = HermesStatusTone.neutral;
  bool _steerUnsupported = false;
  bool _stopAwaiting = false;
  bool _technicalOpen = false;
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _appResumed = state == null || state == AppLifecycleState.resumed;
    _release = widget.acquirePresentation?.call();
    widget.roster.addListener(_onRoster);
    _last = _find();
    _syncClock();
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
    _stopTail();
    _clockTimer?.cancel();
    _release?.call();
    _release = null;
    _tail.dispose();
    _steer.dispose();
    super.dispose();
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
    _syncClock();
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
    // Keep the last known snapshot when the roster momentarily empties
    // (cover/poll gap): absence is not evidence of what the child did.
    if (current != null) {
      if (current.isTerminal) _stopAwaiting = false;
      _last = current;
    }
    setState(() {});
    _syncClock();
    _syncTail();
  }

  void _syncClock() {
    final live = _last != null && subagentIsLive(_last!) && _appResumed;
    if (live && _clockTimer == null && widget.clock == null) {
      _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _routeCurrent) setState(() {});
      });
    } else if (!live) {
      _clockTimer?.cancel();
      _clockTimer = null;
    }
  }

  // ── Live tail ────────────────────────────────────────────────────────────

  bool _canTailNow(SubagentActivity? a) =>
      a != null &&
      subagentIsLive(a) &&
      widget.onTail != null &&
      (widget.canTail?.call(a) ?? true);

  void _syncTail() {
    if (!mounted) return;
    if (_visible && _canTailNow(_find())) {
      if (_cancelTailPoll == null && !_tailInFlight) _pollTail();
    } else {
      _stopTail();
    }
  }

  void _stopTail() {
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
          _scheduleNextTail(generation);
        });
  }

  void _scheduleNextTail(int generation) {
    if (!_visible || generation != _tailGeneration) return;
    final scheduler = widget.scheduleTailPoll ?? _timerScheduler;
    _cancelTailPoll = scheduler(_tailInterval, () {
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
            SubagentLiveLogPage(title: s.subagentUiLiveTitle, tail: _tail),
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

  @override
  Widget build(BuildContext context) {
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
    final opening = widget.isOpenPending?.call(activity) ?? false;
    final canSteer =
        live &&
        !_steerUnsupported &&
        widget.onSteer != null &&
        (widget.canSteer?.call(activity) ?? false);

    Widget? primary;
    if (canStop || (live && stopping)) {
      primary = HermesActionButton(
        key: const ValueKey('subagent-detail-stop'),
        primary: true,
        icon: Icons.stop_rounded,
        label: stopping ? s.subagentUiStatusStopping : s.subagentUiStop,
        onPressed: stopping ? null : () => _stop(activity),
      );
    } else if (!live && canOpen) {
      primary = HermesActionButton(
        key: const ValueKey('subagent-detail-open'),
        primary: true,
        icon: Icons.forum_outlined,
        label: s.subagentUiOpenConversation,
        onPressed: opening ? null : () => widget.onOpenConversation!(activity),
      );
    }

    final result = activity.isTerminal ? activity.resultPreview?.trim() : null;

    return HermesDetailScaffold(
      listKey: const ValueKey('subagent-detail'),
      appBarTitle: s.subagentUiRowTitle,
      title: widget.hideGoal
          ? s.subagentUiRowTitle
          : subagentTitle(s, activity),
      status: HermesStatusText(
        key: const ValueKey('subagent-detail-status'),
        label: status.label,
        tone: status.tone,
        meta: elapsed == null ? null : formatTurnElapsed(elapsed),
      ),
      primaryAction: primary,
      sections: [
        if (live && widget.onTail != null) ...[
          HermesSectionHeader(
            s.subagentUiSectionLive,
            trailing: _LiveDot(active: _visible),
          ),
          _LivePanel(tail: _tail, onOpen: _openLivePage, paused: !_visible),
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
        if (result != null && result.isNotEmpty) ...[
          HermesSectionHeader(s.subagentUiSectionResult),
          HermesTextBlock(
            key: const ValueKey('subagent-detail-result'),
            text: result,
            copyable: true,
            openTitle: s.subagentUiSectionResult,
          ),
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
    );
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

  static const int visibleLines = 10;

  const _LivePanel({
    required this.tail,
    required this.onOpen,
    required this.paused,
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
          note = paused
              ? s.subagentUiLivePaused
              : value.truncated || start > 0
              ? s.subagentUiLiveTruncated
              : null;
          body = visible.isEmpty
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
    return HermesListGroup(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: HermesSpace.rowH, right: 4),
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
                    hintText: s.subagentUiGuideHint,
                    counterText: '',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) => IconButton(
                  key: const ValueKey('subagent-steer-send'),
                  tooltip: s.subagentUiGuideSend,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  color: colors.accentText,
                  onPressed: pending || value.text.trim().isEmpty
                      ? null
                      : onSend,
                  icon: pending
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded, size: 20),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
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
    final rows = <({String title, String? value, HermesStatusTone tone})>[];
    if (d.startedAt case final started?) {
      final local = started.toLocal();
      final hh = local.hour.toString().padLeft(2, '0');
      final mm = local.minute.toString().padLeft(2, '0');
      rows.add((
        title: s.subagentUiStepStarted,
        value: '$hh:$mm',
        tone: HermesStatusTone.neutral,
      ));
    }
    if (activity.progress case final p?) {
      rows.add((
        title: s.subagentActivityProgress(p.displayTaskIndex, p.taskCount),
        value: null,
        tone: HermesStatusTone.neutral,
      ));
    }
    if (d.toolCount case final count? when count > 0) {
      rows.add((
        title: s.subagentUiStepTools(count),
        value: null,
        tone: HermesStatusTone.neutral,
      ));
    }
    final read = d.filesReadCount;
    final written = d.filesWrittenCount;
    if ((read ?? 0) > 0 || (written ?? 0) > 0) {
      rows.add((
        title: s.subagentUiStepFiles('${read ?? 0}', '${written ?? 0}'),
        value: null,
        tone: HermesStatusTone.neutral,
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
      SubagentActivityPhase.completed => (
        s.subagentUiStepFinished,
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
            leading: SizedBox(
              width: 10,
              child: Center(
                child: Container(
                  width: i == rows.length - 1 ? 8 : 6,
                  height: i == rows.length - 1 ? 8 : 6,
                  decoration: BoxDecoration(
                    color: i == rows.length - 1
                        ? rows[i].tone.colorIn(colors)
                        : colors.textDisabled,
                    shape: BoxShape.circle,
                  ),
                ),
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

/// Full-screen, auto-following live output. Follows the bottom unless the
/// person scrolls up; "Follow" jumps back. Append-only list rendering.
class SubagentLiveLogPage extends StatefulWidget {
  final String title;
  final ValueListenable<SubagentLiveTail> tail;

  const SubagentLiveLogPage({
    super.key,
    required this.title,
    required this.tail,
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
                HermesNotice.show(
                  context,
                  message: s.designCopied,
                  kind: HermesNoticeKind.success,
                );
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
          builder: (context, value, _) => ListView.builder(
            key: const ValueKey('subagent-live-log'),
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.pageH,
              HermesSpace.pageTop,
              HermesSpace.pageH,
              HermesSpace.pageBottom,
            ),
            itemCount: value.lines.length,
            itemBuilder: (context, i) => Text(value.lines[i], style: style),
          ),
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
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        } else if (snap.hasError) {
          children.add(
            HermesEmptyStateView(
              icon: Icons.cloud_off_rounded,
              title: s.subagentUiTranscriptError,
              actionLabel: s.subagentUiRetry,
              onAction: () => setState(() => _future = widget.load()),
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
