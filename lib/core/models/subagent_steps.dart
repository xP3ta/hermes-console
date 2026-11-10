import 'package:flutter/foundation.dart';

import 'subagent_activity.dart';

/// One thing a subagent was seen doing: thinking, working on something, or
/// using a tool on a target. Display data only (the tool's public name and a
/// bounded one-line target); it never holds a tool's raw arguments.
@immutable
final class SubagentStep {
  const SubagentStep({
    required this.phase,
    required this.startedAt,
    this.endedAt,
    this.tool,
    this.target,
  });

  /// `requested`, `running`, `thinking` or `tool`.
  final SubagentActivityPhase phase;

  /// Public name of the tool in hand (phase `tool`).
  final String? tool;

  /// What the tool works on, one short line («a file», «an address»).
  final String? target;
  final DateTime startedAt;

  /// Null while this is the step in hand.
  final DateTime? endedAt;

  bool get isOpen => endedAt == null;

  /// How long it took (so far, while open).
  Duration durationAt(DateTime now) {
    final d = (endedAt ?? now).difference(startedAt);
    return d.isNegative ? Duration.zero : d;
  }

  SubagentStep closedAt(DateTime at) => SubagentStep(
    phase: phase,
    tool: tool,
    target: target,
    startedAt: startedAt,
    endedAt: at.isBefore(startedAt) ? startedAt : at,
  );

  bool sameWork(SubagentStep other) =>
      phase == other.phase && tool == other.tool && target == other.target;
}

/// What each subagent of a chat was seen doing, step by step.
///
/// The gateway reports a subagent's CURRENT phase and tool, not a history, so
/// the log is built from what the chat sees go by: every roster update calls
/// [observe]. It therefore starts when the group first appears in the chat;
/// a step that happened before that is not known (the detail page says so).
/// Bounded: [maxSteps] per agent, [maxAgents] agents (the oldest go first).
///
/// Listeners are told through [publish], which the owner calls after the
/// frame (never while building).
class SubagentStepLog extends ChangeNotifier {
  static const int maxSteps = 40;
  static const int maxAgents = 24;

  final Map<SubagentActivityKey, List<SubagentStep>> _steps = {};

  /// The steps seen for [key], oldest first. Unmodifiable.
  List<SubagentStep> stepsOf(SubagentActivityKey key) =>
      List.unmodifiable(_steps[key] ?? const <SubagentStep>[]);

  bool get isEmpty => _steps.isEmpty;

  /// Folds in the latest snapshot of every agent. Returns whether the log
  /// changed (the owner then [publish]es).
  bool observeAll(Iterable<SubagentActivity> activities, DateTime now) {
    var changed = false;
    for (final activity in activities) {
      if (observe(activity, now)) changed = true;
    }
    return changed;
  }

  /// Folds in one snapshot of [activity] seen at [now].
  bool observe(SubagentActivity activity, DateTime now) {
    final list = _steps[activity.key];
    final phase = activity.phase;
    if (phase == SubagentActivityPhase.unknown) return false;
    if (phase.isTerminal) {
      // The end closes the step in hand; the end itself is the agent's
      // status, not a step.
      if (list == null || list.isEmpty || !list.last.isOpen) return false;
      final end = activity.details.completedAt?.toLocal() ?? now;
      list[list.length - 1] = list.last.closedAt(end);
      return true;
    }
    final tool = phase == SubagentActivityPhase.tool
        ? _clean(activity.details.activeToolName, 60)
        : null;
    final target = phase == SubagentActivityPhase.tool
        ? _firstLine(activity.details.activeToolPreview, 90)
        : null;
    final next = SubagentStep(
      phase: phase,
      tool: tool,
      target: target,
      startedAt: now,
    );
    if (list == null) {
      if (_steps.length >= maxAgents) _steps.remove(_steps.keys.first);
      _steps[activity.key] = [next];
      return true;
    }
    if (list.isNotEmpty && list.last.isOpen && list.last.sameWork(next)) {
      return false;
    }
    if (list.isNotEmpty && list.last.isOpen) {
      list[list.length - 1] = list.last.closedAt(now);
    }
    list.add(next);
    if (list.length > maxSteps) list.removeRange(0, list.length - maxSteps);
    return true;
  }

  /// Tells the listeners (call after the frame).
  void publish() => notifyListeners();

  static String? _clean(String? raw, int max) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return null;
    return _cut(value, max);
  }

  static String? _firstLine(String? raw, int max) {
    final line = (raw ?? '').trim().split('\n').first.trim();
    if (line.isEmpty) return null;
    return _cut(line, max);
  }

  static String _cut(String value, int max) => value.runes.length <= max
      ? value
      : '${String.fromCharCodes(value.runes.take(max)).trimRight()}…';
}
