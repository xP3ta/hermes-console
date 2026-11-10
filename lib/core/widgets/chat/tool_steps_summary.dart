import 'package:flutter/foundation.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/activity_snapshot.dart' show measuredActivityDuration;
import '../../models/tool_name.dart' show canonicalToolName;

/// What a tool step did, for the summary bar of a turn. Declaration order is
/// the order the categories are matched in; [other] is always said last.
enum StepsBarCategory { commands, edit, readFiles, webSearch, webPages, other }

/// How the steps of one bar stand: said in words and tint, never by an icon.
enum StepsBarStatus { running, failed, done }

const _exact = <StepsBarCategory, List<String>>{
  StepsBarCategory.commands: ['terminal', 'bash', 'exec_command', 'shell'],
  StepsBarCategory.edit: ['write_file', 'edit_file', 'apply_patch', 'patch'],
  StepsBarCategory.readFiles: ['read_file', 'open_file'],
  StepsBarCategory.webSearch: ['web_search', 'search_query', 'browser_search'],
  StepsBarCategory.webPages: ['web_extract', 'web_fetch'],
};

/// The lowercase name with `-` turned into `_`.
@visibleForTesting
String normalizeStepsToolName(String? tool) =>
    (tool ?? '').trim().toLowerCase().replaceAll('-', '_');

/// The category of a tool by its normalized name: an exact match first, then
/// by prefix (the longest known name wins); no match is [StepsBarCategory.other].
StepsBarCategory stepsBarCategory(String? tool) {
  final name = normalizeStepsToolName(tool);
  if (name.isEmpty) return StepsBarCategory.other;
  for (final entry in _exact.entries) {
    if (entry.value.contains(name)) return entry.key;
  }
  StepsBarCategory? best;
  var bestLength = 0;
  for (final entry in _exact.entries) {
    for (final known in entry.value) {
      if (known.length > bestLength && name.startsWith(known)) {
        best = entry.key;
        bestLength = known.length;
      }
    }
  }
  return best ?? StepsBarCategory.other;
}

/// Running if any step still runs; failed if none runs and one failed;
/// done otherwise.
StepsBarStatus stepsBarStatus({
  required bool anyRunning,
  required bool anyFailed,
}) => anyRunning
    ? StepsBarStatus.running
    : anyFailed
    ? StepsBarStatus.failed
    : StepsBarStatus.done;

/// Count per category in order of first appearance, [StepsBarCategory.other]
/// last.
List<(StepsBarCategory, int)> stepsBarCounts(Iterable<String?> tools) {
  final counts = <StepsBarCategory, int>{};
  for (final tool in tools) {
    final category = stepsBarCategory(tool);
    counts[category] = (counts[category] ?? 0) + 1;
  }
  return [
    for (final entry in counts.entries)
      if (entry.key != StepsBarCategory.other) (entry.key, entry.value),
    if (counts[StepsBarCategory.other] case final other?)
      (StepsBarCategory.other, other),
  ];
}

String _phrase(Strings s, StepsBarCategory category, int count) =>
    switch (category) {
      StepsBarCategory.commands => s.stepsBarCommands(count),
      StepsBarCategory.edit => s.stepsBarEdits(count),
      StepsBarCategory.readFiles => s.stepsBarReads(count),
      StepsBarCategory.webSearch => s.stepsBarSearches(count),
      StepsBarCategory.webPages => s.stepsBarPages(count),
      StepsBarCategory.other => s.stepsBarOther(count),
    };

/// Items in the language's own list shape («a, b y c»).
String stepsBarJoinList(Strings s, List<String> items) {
  if (items.isEmpty) return '';
  if (items.length == 1) return items.single;
  if (items.length == 2) return s.stepsBarListPair(items[0], items[1]);
  final head = items.sublist(0, items.length - 1).join(s.stepsBarListSeparator);
  return s.stepsBarListLast(head, items.last);
}

/// «Ejecutó 2 comandos y leyó un archivo»: the counts of a bar, in order,
/// with the first letter in capitals.
String stepsBarSummaryText(Strings s, Iterable<String?> tools) {
  final text = stepsBarJoinList(s, [
    for (final (category, count) in stepsBarCounts(tools))
      _phrase(s, category, count),
  ]);
  if (text.isEmpty) return text;
  final first = String.fromCharCode(text.runes.first);
  return first.toUpperCase() + text.substring(first.length);
}

/// One measured action; raw arguments and previews never enter the summary.
typedef TurnSummaryAction = ({
  String? tool,
  String? target,
  bool failed,
  Duration? duration,
});

enum _TurnAction {
  edit,
  read,
  commands,
  code,
  fileSearch,
  webSearch,
  pages,
  delegated,
  other,
}

String _summaryTool(String? tool) =>
    normalizeStepsToolName(canonicalToolName(tool ?? ''));

bool isTurnAgentTool(String? tool) =>
    const {'delegate_task', 'spawn_agent'}.contains(_summaryTool(tool));

_TurnAction _turnAction(String? tool) {
  final name = _summaryTool(tool);
  if (isTurnAgentTool(tool)) return _TurnAction.delegated;
  if (name.startsWith('search_files') || name == 'grep' || name == 'glob') {
    return _TurnAction.fileSearch;
  }
  if (name == 'execute_code') return _TurnAction.code;
  if (name == 'browser_navigate') return _TurnAction.pages;
  return switch (stepsBarCategory(name)) {
    StepsBarCategory.edit => _TurnAction.edit,
    StepsBarCategory.readFiles => _TurnAction.read,
    StepsBarCategory.commands => _TurnAction.commands,
    StepsBarCategory.webSearch => _TurnAction.webSearch,
    StepsBarCategory.webPages => _TurnAction.pages,
    StepsBarCategory.other => _TurnAction.other,
  };
}

/// Whole-turn and step clocks share m:ss (h:mm:ss after an hour).
/// Unknown, negative and implausible measurements are omitted.
String? turnLineDuration(Duration? raw) {
  final value = measuredActivityDuration(raw);
  if (value == null || value.inSeconds < 1) return null;
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  final minutes = value.inMinutes;
  return minutes < 60
      ? '$minutes:$seconds'
      : '${value.inHours}:${(minutes % 60).toString().padLeft(2, '0')}:$seconds';
}

String _turnPhrase(
  Strings s,
  _TurnAction action,
  int count, {
  bool calls = false,
}) => switch (action) {
  _TurnAction.edit =>
    calls ? s.turnLineEditCalls(count) : s.turnLineEdited(count),
  _TurnAction.read =>
    calls ? s.turnLineReadCalls(count) : s.turnLineRead(count),
  _TurnAction.commands => s.turnLineRan(count),
  _TurnAction.code => s.turnLineExecutedCode(count),
  _TurnAction.fileSearch => s.turnLineSearchedFiles(count),
  _TurnAction.webSearch => s.turnLineSearchedWeb(count),
  _TurnAction.pages => s.turnLineOpened(count),
  _TurnAction.other => s.turnLineUsedTools(count),
  _TurnAction.delegated => s.turnLineDelegated(count),
};

/// Rank by number of actions, then measured time, then a stable relevance
/// order (edits, reads, commands/code, searches, pages, other tools).
/// Reads/edits count distinct safe targets; a missing target switches the
/// whole category to calls, so repeats never pretend to be unique files. The full
/// accessible summary retains categories hidden by the three-phrase limit.
({String label, String semanticsLabel}) turnLineSummary(
  Strings s,
  Iterable<TurnSummaryAction> actions, {
  Duration? duration,
  int agentCount = 0,
}) {
  final counts = <_TurnAction, int>{};
  final times = <_TurnAction, Duration>{};
  final targets = <_TurnAction, Set<String>>{};
  final callsOnly = <_TurnAction>{};
  var failed = 0;
  for (final action in actions) {
    if (action.failed) failed++;
    final category = _turnAction(action.tool);
    counts[category] = (counts[category] ?? 0) + 1;
    if (category == _TurnAction.read || category == _TurnAction.edit) {
      final target = action.target?.trim();
      if (target == null || target.isEmpty) {
        callsOnly.add(category);
      } else {
        (targets[category] ??= <String>{}).add(target);
      }
    }
    times[category] =
        (times[category] ?? Duration.zero) +
        (measuredActivityDuration(action.duration) ?? Duration.zero);
  }
  for (final category in targets.keys) {
    if (!callsOnly.contains(category)) {
      counts[category] = targets[category]!.length;
    }
  }
  final categories = counts.keys.toList()
    ..sort((a, b) {
      final count = counts[b]!.compareTo(counts[a]!);
      if (count != 0) return count;
      final time = times[b]!.compareTo(times[a]!);
      return time != 0 ? time : a.index.compareTo(b.index);
    });
  final time = turnLineDuration(duration);
  final onlyThought = counts.isEmpty && agentCount == 0 && failed == 0;
  final lead = onlyThought ? s.turnLineThought : s.turnLineWorked;
  final phrases = [
    for (final category in categories)
      _turnPhrase(
        s,
        category,
        counts[category]!,
        calls: callsOnly.contains(category),
      ),
  ];
  // A delegation call may launch many agents. Never infer a roster from calls.
  final agents = agentCount;
  final suffix = [
    if (failed > 0) s.turnLineFailed(failed),
    if (agents > 0) s.turnLineAgents(agents),
  ];
  final start = time == null ? lead : '$lead $time';
  return (
    label: [
      start,
      ...phrases.take(3),
      if (phrases.length > 3) s.turnLineMore(phrases.length - 3),
      ...suffix,
    ].join(' · '),
    semanticsLabel: [start, ...phrases, ...suffix].join(' · '),
  );
}

/// What each bar remembers across rebuilds and reconnects: open or closed,
/// by the id of its first step (stable for the life of the turn). Bounded:
/// the oldest turns forget first.
class StepsBarMemory {
  StepsBarMemory._();

  static const int capacity = 200;
  static final Map<String, bool> _open = <String, bool>{};

  /// A bar nobody has touched starts closed. Tests of whole screens that read
  /// the rows flip this.
  @visibleForTesting
  static bool openByDefault = false;

  static bool isOpen(String firstStepId) => _open[firstStepId] ?? openByDefault;

  /// What the reader chose for this group, or null if they never touched it.
  static bool? recorded(String firstStepId) => _open[firstStepId];

  /// [isOpen], but a group nobody touched may start open for its own reason.
  static bool isOpenOr(String firstStepId, {required bool fallback}) =>
      _open[firstStepId] ?? (openByDefault || fallback);

  static void set(String firstStepId, bool open) {
    _open
      ..remove(firstStepId)
      ..[firstStepId] = open;
    while (_open.length > capacity) {
      _open.remove(_open.keys.first);
    }
  }

  @visibleForTesting
  static void reset() {
    _open.clear();
    openByDefault = false;
  }
}

/// The approved quiet summary: measured time, action counts and delegated
/// children, without changing the richer summaries used on other surfaces.
String inlineTurnSummary(
  Strings s,
  Iterable<TurnSummaryAction> actions, {
  Duration? duration,
  int agentCount = 0,
}) {
  final all = actions.toList();
  final commands = all
      .where((a) => _turnAction(a.tool) == _TurnAction.commands)
      .length;
  final delegated = all.where((a) => isTurnAgentTool(a.tool)).length;
  final other = all.length - commands - delegated;
  // Under a second is no measure of a turn: say «Trabajó» with no time
  // rather than «Trabajó 0 s».
  final measured = switch (measuredActivityDuration(duration)) {
    final d? when d >= const Duration(seconds: 1) => d,
    _ => null,
  };
  // The turn Hermes runs when its children end (`async_delegation_complete`)
  // ran no tool of its own and has no time of its own: it is that ending,
  // «✓ 2 subagentes terminados», never «Trabajó 0 s · 2 subagentes».
  if (all.isEmpty && agentCount > 0 && measured == null) {
    return s.delegatedCapsuleFinished(agentCount);
  }
  return [
    measured == null
        ? s.turnLineWorked
        : s.tk140WorkedFor(s.i18n131DurationSeconds('${measured.inSeconds}')),
    if (commands > 0) s.chatLiveCommands(commands),
    // Calls are not a child roster. Preserve their honest existing wording.
    if (agentCount > 0)
      s.chatLiveAgents(agentCount)
    else if (delegated > 0)
      s.turnLineDelegated(delegated),
    if (other > 0) s.turnLineUsedTools(other),
    if (all.any((a) => a.failed))
      s.turnLineFailed(all.where((a) => a.failed).length),
  ].join(' · ');
}
