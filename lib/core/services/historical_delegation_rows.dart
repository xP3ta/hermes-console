// Rows for the subagents of a PAST turn, rebuilt from the parent transcript
// alone (nothing is fetched): Hermes persists the dispatch (`delegate_task`
// result: `delegation_id`, `goals`, `subagent_ids`) and, when the batch ends,
// a consolidated completion message with one block per task (goal, status,
// api calls, duration and the child's final text) plus the model and total
// duration. A reloaded chat only kept a text card for them; this gives the
// list and the detail screens the same data the live roster had.
//
// Bounded and defensive: a block that does not parse is dropped, never
// guessed, and an unparseable completion yields no rows (the caller says so).
import 'dart:convert';

import '../models/subagent_activity.dart';
import '../utils/chat_turn.dart';

/// Longest result text kept for one finished child (the detail clips it too).
const _maxResultCharacters = 4000;
const _maxGoalCharacters = SubagentPayloadLimits.goalCharacters;
const _maxChildren = 16;

/// One task of a finished batch, as the completion message states it.
final class HistoricalDelegationTask {
  final int index;
  final String goal;
  final String status;
  final int? apiCalls;
  final double? durationSeconds;
  final String result;

  const HistoricalDelegationTask({
    required this.index,
    required this.goal,
    required this.status,
    this.apiCalls,
    this.durationSeconds,
    this.result = '',
  });
}

/// A finished batch: its tasks plus what the header says about it.
final class HistoricalDelegation {
  final String delegationId;
  final String? model;
  final double? totalDurationSeconds;
  final DateTime? completedAt;
  final List<String> subagentIds;
  final List<HistoricalDelegationTask> tasks;

  const HistoricalDelegation({
    required this.delegationId,
    required this.tasks,
    this.model,
    this.totalDurationSeconds,
    this.completedAt,
    this.subagentIds = const [],
  });
}

final _taskHeader = RegExp(
  r'^--- \S+ TASK (\d+)/(\d+): (.+?)\s+\(status=([A-Za-z_]+)'
  r'(?:, api_calls=(\d+))?(?:, ([0-9.]+)s)?\) ---[ \t]*$',
  multiLine: true,
  dotAll: true,
);

/// The batch [delegationId] from [messages] (any order), or null when the
/// transcript no longer holds its completion message.
HistoricalDelegation? historicalDelegationFromMessages(
  List<Map<String, dynamic>> messages,
  String delegationId,
) {
  List<String> subagentIds = const [];
  List<String> dispatchedGoals = const [];
  Map<String, dynamic>? completion;
  for (final message in messages) {
    final role = (message['role'] ?? '').toString().toLowerCase();
    if (role == 'tool' || role == 'tool_result' || role == 'function') {
      final name = (message['tool_name'] ?? message['name'] ?? '')
          .toString()
          .toLowerCase()
          .split('.')
          .last;
      if (name != 'delegate_task') continue;
      final result = _decodedMap(message['content'] ?? message['result']);
      if (result?['delegation_id']?.toString() != delegationId) continue;
      subagentIds = _strings(result?['subagent_ids']);
      dispatchedGoals = _strings(result?['goals']);
    } else if (effectiveUserDisplayKind(message) ==
        'async_delegation_complete') {
      final content = (message['content'] ?? message['text'] ?? '').toString();
      final metadata = _decodedMap(message['display_metadata']);
      final id =
          metadata?['delegation_id']?.toString() ??
          RegExp(
            r'^\[ASYNC DELEGATION (?:BATCH )?COMPLETE — (deleg_[0-9a-f]{8})\]',
          ).firstMatch(content)?.group(1);
      if (id == delegationId) completion = message;
    }
  }
  if (completion == null) return null;
  final content = (completion['content'] ?? completion['text'] ?? '')
      .toString();
  final tasks = _parseTasks(content);
  if (tasks.isEmpty) return null;
  // Goals the dispatch kept are the full text; the completion block repeats
  // them but a long one can be cut. Prefer the dispatch when it is a superset.
  final merged = <HistoricalDelegationTask>[
    for (final task in tasks)
      HistoricalDelegationTask(
        index: task.index,
        goal: _fullerGoal(task.goal, dispatchedGoals, task.index),
        status: task.status,
        apiCalls: task.apiCalls,
        durationSeconds: task.durationSeconds,
        result: task.result,
      ),
  ];
  final header = content.split(_taskHeader).first;
  return HistoricalDelegation(
    delegationId: delegationId,
    model: _capture(header, r'Model:\s*(\S+)'),
    totalDurationSeconds: double.tryParse(
      _capture(header, r'Total duration:\s*([0-9.]+)s') ?? '',
    ),
    completedAt: _instant(completion['timestamp']),
    subagentIds: subagentIds,
    tasks: List.unmodifiable(merged),
  );
}

/// One terminal row per task of [delegation]. [childSessionIds] maps a task
/// index to the stored session id of its child when it could be resolved.
List<SubagentActivity> historicalDelegationRows(
  HistoricalDelegation delegation,
  SubagentActivityScope scope, {
  Map<int, String> childSessionIds = const {},
}) {
  final rows = <SubagentActivity>[];
  for (final task in delegation.tasks.take(_maxChildren)) {
    final subagentId = task.index < delegation.subagentIds.length
        ? delegation.subagentIds[task.index]
        : null;
    final failed = !const {
      'completed',
      'complete',
      'success',
      'ok',
    }.contains(task.status.toLowerCase());
    final cancelled = const {
      'cancelled',
      'canceled',
      'interrupted',
    }.contains(task.status.toLowerCase());
    final end = delegation.completedAt;
    final duration = task.durationSeconds ?? delegation.totalDurationSeconds;
    rows.add(
      SubagentActivity(
        key: SubagentActivityKey(
          scope: scope,
          identityKind: SubagentIdentityKind.delegation,
          stableId: '${delegation.delegationId}#${task.index}',
        ),
        source: SubagentActivitySource.native,
        phase: cancelled
            ? SubagentActivityPhase.cancelled
            : failed
            ? SubagentActivityPhase.failed
            : SubagentActivityPhase.completed,
        subagentId: subagentId,
        delegationId: delegation.delegationId,
        childSessionId: childSessionIds[task.index],
        details: SubagentActivityDetails(
          goalPreview: _clip(task.goal, _maxGoalCharacters),
          summaryPreview: task.result.isEmpty
              ? null
              : _clip(task.result, _maxResultCharacters),
          model: delegation.model,
          durationSeconds: duration,
          completedAt: end,
          startedAt: end != null && duration != null
              ? end.subtract(Duration(milliseconds: (duration * 1000).round()))
              : null,
          usage: task.apiCalls == null
              ? null
              : SubagentUsage(apiCalls: task.apiCalls),
        ),
      ),
    );
  }
  return List.unmodifiable(rows);
}

/// Words of a goal fit for the server's text search: letters and digits only,
/// the first few, so punctuation can never reach the query syntax.
String searchWordsOf(String goal, {int words = 6}) => goal
    .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
    .where((word) => word.length > 1)
    .take(words)
    .join(' ');

List<HistoricalDelegationTask> _parseTasks(String content) {
  final matches = _taskHeader.allMatches(content).toList(growable: false);
  final tasks = <HistoricalDelegationTask>[];
  for (var i = 0; i < matches.length && i < _maxChildren; i++) {
    final m = matches[i];
    final index = (int.tryParse(m.group(1)!) ?? 1) - 1;
    final bodyEnd = i + 1 < matches.length
        ? matches[i + 1].start
        : content.length;
    var body = content.substring(m.end, bodyEnd).trim();
    // The pointer to the server-side trace is not part of the result.
    body = body
        .replaceAll(
          RegExp(r'^Full live transcript[^\n]*$', multiLine: true),
          '',
        )
        .trim();
    tasks.add(
      HistoricalDelegationTask(
        index: index < 0 ? i : index,
        goal: m.group(3)!.trim(),
        status: m.group(4)!.trim(),
        apiCalls: int.tryParse(m.group(5) ?? ''),
        durationSeconds: double.tryParse(m.group(6) ?? ''),
        result: body,
      ),
    );
  }
  return tasks;
}

String _fullerGoal(String fromCompletion, List<String> dispatched, int index) {
  if (index >= 0 && index < dispatched.length) {
    final full = dispatched[index].trim();
    if (full.startsWith(fromCompletion.trim()) ||
        fromCompletion.trim().startsWith(full)) {
      return full.length >= fromCompletion.trim().length
          ? full
          : fromCompletion.trim();
    }
  }
  return fromCompletion;
}

String? _capture(String text, String pattern) =>
    RegExp(pattern).firstMatch(text)?.group(1);

List<String> _strings(Object? raw) {
  if (raw is! List) return const [];
  return List.unmodifiable([
    for (final value in raw.take(64))
      if (value is String && value.trim().isNotEmpty && value.length < 4096)
        value,
  ]);
}

String _clip(String value, int max) {
  final runes = value.trim().runes;
  return runes.length <= max
      ? value.trim()
      : String.fromCharCodes(runes.take(max));
}

DateTime? _instant(Object? value) {
  if (value is num && value.isFinite && value > 0) {
    final ms = value < 1e11 ? value * 1000 : value;
    // A nonsense timestamp (past DateTime's ±8.64e15 ms) reads as unknown
    // instead of throwing on the card's tap.
    if (ms > 8.64e15) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms.round(), isUtc: true);
  }
  if (value is String) return DateTime.tryParse(value)?.toUtc();
  return null;
}

Map<String, dynamic>? _decodedMap(Object? value) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }
  if (value is! String || value.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(value);
    return decoded is Map ? _decodedMap(decoded) : null;
  } catch (_) {
    return null;
  }
}
