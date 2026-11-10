// What a FINISHED subagent did, read back from the best source there is.
//
// A finished child often reaches the chat as a bare row: the parent
// transcript proves its identity (`delegate_task` dispatch) and its outcome
// (the aggregate `async_delegation_complete` metadata) but neither its goal,
// its result nor its stored session id. Its detail page then had nothing to
// render. This reads, in order:
//
//  1. the child's own stored conversation (goal, the tools it ran, its final
//     answer), once its stored id is known and its first prompt is this
//     task's goal (a goal-word search can return a sibling child);
//  2. the parent's record of the task: the dispatch goal and the completion
//     block (status, API calls, duration, model and the child's final text);
//  3. whatever the row itself carries (goal, `summary`, the `output_tail`
//     tool names of `subagent.complete`); otherwise nothing, said plainly.
//
// Bounded and private: tool arguments never leave this file except a short
// path/URL target (no commands, no query strings), reasoning is dropped,
// every text is clipped, and nothing here is logged. [subagentLiveTarget]
// (the owner's LIVE view) shows a command line too, with secrets masked.
import 'dart:convert';

import '../models/subagent_activity.dart';
import '../utils/assistant_content.dart' show finalizedPublicAssistantText;
import 'historical_delegation_rows.dart';
import 'release_log.dart' show redactLogLine;
import 'subagent_live_watch.dart' show SubagentWatchBlock, SubagentWatchTool;

/// Where a [SubagentFinishedRecord] came from.
enum SubagentRecordSource {
  /// The child's own stored conversation.
  child,

  /// The parent's dispatch and completion messages.
  parent,

  /// Only what the roster row carried.
  activity,

  /// Nothing to show.
  none,
}

typedef SubagentFinishedRecordLoader =
    Future<SubagentFinishedRecord> Function(SubagentActivity activity);

/// What a finished subagent was asked, what it ran and what it answered.
final class SubagentFinishedRecord {
  static const int maxBlocks = 160;
  static const int maxTextCharacters = 4000;
  static const int maxResultCharacters = 8000;
  static const int maxGoalCharacters = 4000;
  static const int maxTargetCharacters = 160;

  final SubagentRecordSource source;
  final String goal;

  /// Ordered steps (tool rows) and the prose between them.
  final List<SubagentWatchBlock> blocks;
  final String result;
  final double? durationSeconds;
  final String? model;
  final int? apiCalls;

  const SubagentFinishedRecord({
    required this.source,
    this.goal = '',
    this.blocks = const [],
    this.result = '',
    this.durationSeconds,
    this.model,
    this.apiCalls,
  });

  static const SubagentFinishedRecord empty = SubagentFinishedRecord(
    source: SubagentRecordSource.none,
  );

  bool get isEmpty => goal.isEmpty && blocks.isEmpty && result.isEmpty;
}

/// The child's conversation as a record, or null when it holds nothing
/// public to show (no prompt, no step, no answer).
SubagentFinishedRecord? subagentRecordFromChildMessages(
  List<Map<String, dynamic>> messages,
) {
  var goal = '';
  final blocks = <SubagentWatchBlock>[];
  final toolIndexByCall = <String, int>{};
  var sequence = 0;
  for (final message in messages) {
    final role = (message['role'] ?? '').toString().trim().toLowerCase();
    final active = message['active'];
    if (active == false || active == 0) continue;
    if (role == 'user') {
      if (goal.isEmpty && message['display_kind'] == null) {
        goal = _clip(_text(message['content']), _maxGoal);
      }
      continue;
    }
    if (role == 'assistant') {
      final text = finalizedPublicAssistantText(
        _text(message['content'] ?? message['text']),
      ).trim();
      if (text.isNotEmpty && blocks.length < SubagentFinishedRecord.maxBlocks) {
        blocks.add(
          SubagentWatchBlock.text(
            'text-${sequence++}',
            _clip(text, SubagentFinishedRecord.maxTextCharacters),
            closed: true,
          ),
        );
      }
      for (final raw in _list(message['tool_calls'])) {
        if (blocks.length >= SubagentFinishedRecord.maxBlocks) break;
        final call = _map(raw);
        final function = _map(call?['function']);
        final name = _toolName(function?['name'] ?? call?['name']);
        if (name == null) continue;
        final callId = (call?['id'] ?? call?['tool_call_id'])?.toString();
        final id = 'record-${sequence++}';
        if (callId != null && callId.isNotEmpty && callId.length <= 256) {
          toolIndexByCall[callId] = blocks.length;
        }
        blocks.add(
          SubagentWatchBlock.tool(
            SubagentWatchTool(
              id: id,
              name: name,
              preview: _target(function?['arguments'] ?? call?['arguments']),
              finished: true,
            ),
          ),
        );
      }
      continue;
    }
    if (role == 'tool' || role == 'tool_result' || role == 'function') {
      final callId = (message['tool_call_id'] ?? message['call_id'])
          ?.toString();
      final index = callId == null ? null : toolIndexByCall[callId];
      if (index == null || !_toolFailed(message['content'])) continue;
      final tool = blocks[index].tool!;
      blocks[index] = SubagentWatchBlock.tool(tool.finish(failed: true));
    }
  }
  // What it wrote after its last step is its answer, not a step.
  var result = '';
  if (blocks.isNotEmpty && blocks.last.tool == null) {
    result = blocks.removeLast().text;
  }
  if (goal.isEmpty && blocks.isEmpty && result.isEmpty) return null;
  return SubagentFinishedRecord(
    source: SubagentRecordSource.child,
    goal: goal,
    blocks: List.unmodifiable(blocks),
    result: _clip(result, SubagentFinishedRecord.maxResultCharacters),
  );
}

/// The batch that dispatched [subagentId] (or the `delegate_task` call
/// [toolCallId]) in [messages], or null.
String? delegationIdForSubagent(
  List<Map<String, dynamic>> messages, {
  String? subagentId,
  String? toolCallId,
}) {
  if (subagentId == null && toolCallId == null) return null;
  for (final message in messages) {
    final role = (message['role'] ?? '').toString().toLowerCase();
    if (role != 'tool' && role != 'tool_result' && role != 'function') {
      continue;
    }
    final name = (message['tool_name'] ?? message['name'] ?? '')
        .toString()
        .toLowerCase()
        .split('.')
        .last;
    if (name != 'delegate_task') continue;
    final result = _map(_decoded(message['content'] ?? message['result']));
    final id = result?['delegation_id']?.toString();
    if (id == null || id.isEmpty) continue;
    final ids = result?['subagent_ids'];
    if (subagentId != null && ids is List && ids.contains(subagentId)) {
      return id;
    }
    final callId = (message['tool_call_id'] ?? message['call_id'])?.toString();
    if (toolCallId != null && callId == toolCallId) return id;
  }
  return null;
}

/// Which task of [delegation] [activity] is, or null when it cannot be told.
HistoricalDelegationTask? subagentTaskOf(
  SubagentActivity activity,
  HistoricalDelegation delegation,
) {
  HistoricalDelegationTask? byIndex(int? index) {
    if (index == null) return null;
    for (final task in delegation.tasks) {
      if (task.index == index) return task;
    }
    return null;
  }

  final subagentId = activity.subagentId;
  if (subagentId != null) {
    final at = delegation.subagentIds.indexOf(subagentId);
    if (at >= 0) return byIndex(at);
    // Hermes names its children `sa-<task index>-<hex>`.
    final match = RegExp(r'^sa-(\d+)-').firstMatch(subagentId);
    if (match != null) return byIndex(int.tryParse(match.group(1)!));
  }
  final stable = RegExp(r'#(\d+)$').firstMatch(activity.key.stableId);
  if (stable != null && activity.delegationId == delegation.delegationId) {
    return byIndex(int.tryParse(stable.group(1)!));
  }
  if (activity.progress case final progress?) {
    return byIndex(progress.taskIndex);
  }
  return delegation.tasks.length == 1 ? delegation.tasks.single : null;
}

/// Shortest clipped goal trusted as a prefix of the other: shorter ones
/// («Revisa», «Fix the») are shared by siblings.
const int subagentGoalMinPrefix = 24;

/// Whether [childGoal] (the child's first prompt) is the task [taskGoal]:
/// the same text, or one is a prefix of the other at least
/// [subagentGoalMinPrefix] characters long (the completion block may clip
/// the goal). Without one of the two goals nothing can be compared: the
/// child is trusted only when its id came with the activity itself
/// ([idFromActivity]), never one a search found.
bool subagentGoalsMatch(
  String childGoal,
  String taskGoal, {
  bool idFromActivity = false,
}) {
  final a = _normalized(childGoal);
  final b = _normalized(taskGoal);
  if (a.isEmpty || b.isEmpty) return idFromActivity;
  if (a == b) return true;
  final shorter = a.length <= b.length ? a : b;
  final longer = identical(shorter, a) ? b : a;
  return shorter.length >= subagentGoalMinPrefix && longer.startsWith(shorter);
}

/// One page of the parent's stored transcript, read backwards from its
/// newest row (`order=latest`): [rows] in chronological order and the
/// offset of the next, older page (null: nothing older, or a server that
/// sent everything at once).
final class ParentTranscriptPage {
  const ParentTranscriptPage(this.rows, {this.nextOffset});

  final List<Map<String, dynamic>> rows;
  final int? nextOffset;
}

/// Bounds of the search for a batch in the parent transcript: a long chat
/// is several MB, and only the pages back to the batch are needed.
abstract final class ParentDelegationSearch {
  static const int pageRows = 200;
  static const int maxPages = 5;
}

/// Pages back through the parent transcript (at most
/// [ParentDelegationSearch.maxPages] pages) until it holds [delegationId]'s
/// completion and its dispatch (or, without an id, the dispatch that names
/// [subagentId] / [toolCallId]).
Future<(String?, HistoricalDelegation?)> _searchParentForDelegation(
  Future<ParentTranscriptPage> Function(int offset, int limit) readPage, {
  required String? delegationId,
  required String? subagentId,
  required String? toolCallId,
}) async {
  final pagesNewestFirst = <List<Map<String, dynamic>>>[];
  var id = delegationId;
  HistoricalDelegation? found;
  var offset = 0;
  for (var read = 0; read < ParentDelegationSearch.maxPages; read++) {
    final page = await readPage(offset, ParentDelegationSearch.pageRows);
    pagesNewestFirst.add(page.rows);
    final chronological = [
      for (final rows in pagesNewestFirst.reversed) ...rows,
    ];
    id ??= delegationIdForSubagent(
      chronological,
      subagentId: subagentId,
      toolCallId: toolCallId,
    );
    if (id != null) {
      found = historicalDelegationFromMessages(chronological, id) ?? found;
      // The dispatch (subagent ids, whole goals) comes before the
      // completion: with both in hand nothing older is needed.
      if (found != null && found.subagentIds.isNotEmpty) break;
    }
    final next = page.nextOffset;
    if (next == null || next <= offset || page.rows.isEmpty) break;
    offset = next;
  }
  return (id, found);
}

/// Reads the record of a finished [activity]. Never throws: every source
/// that fails is skipped and the next one is used.
///
/// - [loadedDelegation]: the batch from the transcript the chat already has.
/// - [parentTranscriptPage]: a page of the parent's stored transcript, read
///   backwards and bounded ([ParentDelegationSearch]) only when the loaded
///   part no longer holds the batch.
/// - [resolveChildSessions]: stored child id by task index.
/// - [loadChild]: the child's stored messages (read-only).
Future<SubagentFinishedRecord> loadSubagentFinishedRecord({
  required SubagentActivity activity,
  required HistoricalDelegation? Function(String delegationId) loadedDelegation,
  required Future<ParentTranscriptPage> Function(int offset, int limit)
  parentTranscriptPage,
  required Future<Map<int, String>> Function(HistoricalDelegation delegation)
  resolveChildSessions,
  required Future<List<Map<String, dynamic>>> Function(String childSessionId)
  loadChild,
  Duration timeout = const Duration(seconds: 25),
}) async {
  var delegationId = activity.delegationId;
  HistoricalDelegation? delegation;
  if (delegationId != null) {
    try {
      delegation = loadedDelegation(delegationId);
    } catch (_) {
      delegation = null;
    }
  }
  if (delegation == null &&
      (delegationId != null ||
          activity.subagentId != null ||
          activity.legacyToolCallId != null)) {
    try {
      final (id, found) = await _searchParentForDelegation(
        parentTranscriptPage,
        delegationId: delegationId,
        subagentId: activity.subagentId,
        toolCallId: activity.legacyToolCallId,
      ).timeout(timeout);
      delegationId ??= id;
      delegation = found;
    } catch (_) {
      delegation = null;
    }
  }
  final task = delegation == null ? null : subagentTaskOf(activity, delegation);

  var childId = activity.childSessionId?.trim() ?? '';
  final idFromActivity = childId.isNotEmpty;
  if (childId.isEmpty && delegation != null && task != null) {
    try {
      final ids = await resolveChildSessions(
        HistoricalDelegation(
          delegationId: delegation.delegationId,
          tasks: [task],
          subagentIds: delegation.subagentIds,
        ),
      ).timeout(timeout);
      childId = ids[task.index]?.trim() ?? '';
    } catch (_) {
      childId = '';
    }
  }
  SubagentFinishedRecord? child;
  if (childId.isNotEmpty) {
    try {
      child = subagentRecordFromChildMessages(
        await loadChild(childId).timeout(timeout),
      );
    } catch (_) {
      child = null;
    }
    // A search by goal words can land on a sibling: trust the child only
    // when its first prompt is this task's goal.
    final expected = task?.goal ?? activity.goalPreview ?? '';
    if (child != null &&
        !subagentGoalsMatch(
          child.goal,
          expected,
          idFromActivity: idFromActivity,
        )) {
      child = null;
    }
  }

  final details = activity.details;
  String pick(Iterable<String?> values) {
    for (final value in values) {
      final text = value?.trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  final goal = pick([child?.goal, task?.goal, activity.goalPreview]);
  final result = pick([child?.result, task?.result, activity.resultPreview]);
  // Without its conversation, the last tools it ran as `subagent.complete`
  // reported them (`output_tail`), when this chat saw that event.
  final blocks =
      child?.blocks ??
      [
        for (final (i, tool) in details.outputTailTools.indexed)
          SubagentWatchBlock.tool(
            SubagentWatchTool(
              id: 'tail-$i',
              name: tool.name,
              finished: true,
              failed: tool.failed,
            ),
          ),
      ];
  final model = pick([details.model, delegation?.model]);
  final source = child != null
      ? SubagentRecordSource.child
      : task != null
      ? SubagentRecordSource.parent
      : goal.isNotEmpty || result.isNotEmpty || blocks.isNotEmpty
      ? SubagentRecordSource.activity
      : SubagentRecordSource.none;
  return SubagentFinishedRecord(
    source: source,
    goal: _clip(goal, _maxGoal),
    blocks: blocks,
    result: _clip(result, SubagentFinishedRecord.maxResultCharacters),
    durationSeconds:
        details.durationSeconds ??
        task?.durationSeconds ??
        delegation?.totalDurationSeconds,
    model: model.isEmpty ? null : model,
    apiCalls: activity.usage?.apiCalls ?? task?.apiCalls,
  );
}

const int _maxGoal = SubagentFinishedRecord.maxGoalCharacters;

String _normalized(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();

String _text(Object? content) {
  if (content is String) return content;
  if (content is List) {
    return content
        .whereType<Map>()
        .where((part) => part['type'] == 'text' && part['text'] is String)
        .map((part) => part['text'] as String)
        .join('\n');
  }
  return '';
}

String _clip(String value, int max) {
  final text = value.trim();
  final runes = text.runes;
  return runes.length <= max ? text : String.fromCharCodes(runes.take(max));
}

String? _toolName(Object? raw) {
  if (raw is! String) return null;
  final name = raw.trim();
  if (name.isEmpty ||
      name.length > 80 ||
      name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return null;
  }
  return name;
}

/// What the finished view may show of a tool's free-form one-line preview,
/// as [_target] does: a file path or a URL without credentials, query or
/// fragment. A command line (tokens, URLs with credentials, secrets in flags)
/// or anything else is dropped: null. The live view of the owner uses
/// [subagentLiveTarget] instead.
String? subagentPublicTarget(String? preview) {
  final line = (preview ?? '').split('\n').first.trim();
  if (line.isEmpty) return null;
  final uri = Uri.tryParse(line);
  if (uri != null &&
      uri.hasScheme &&
      uri.host.isNotEmpty &&
      !line.contains(RegExp(r'\s'))) {
    return _clippedTarget(
      Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
      ).toString(),
    );
  }
  // A bare path: one word, no shell or query syntax, a directory or an
  // extension. `ls`, `sk-…`, `KEY=…`, `a && b` are not paths.
  if (line.contains(RegExp(r'''[\s=@?&;|$`'"<>*(){}\[\]\\,:]'''))) {
    return null;
  }
  if (!line.contains('/') && !RegExp(r'\.[A-Za-z0-9]{1,8}$').hasMatch(line)) {
    return null;
  }
  return _clippedTarget(line);
}

/// Longest one-line target of the live view, ellipsis included.
const int kSubagentLiveTargetMaxChars = 140;

const String _liveMask = '•••';

// A value after a secret's name is a quoted string (maybe cut before its
// closing quote) or a bare word; a preview cut upstream ends in `…`, which a
// bare value swallows too.
final RegExp _livePem = RegExp(r'-----BEGIN.*$');
final RegExp _liveUserinfo = RegExp(
  r'''([a-zA-Z][a-zA-Z0-9+.-]*://)[^/?#\s@"']+@''',
);
final RegExp _liveSecretQuery = RegExp(
  r'''([?&;#][A-Za-z0-9_.\-]*(?:token|key|secret|passw|pwd|auth|sig|session|credential|code)[A-Za-z0-9_.\-]*=)[^&#\s"']*''',
  caseSensitive: false,
);
final RegExp _liveAuthorization = RegExp(
  r'''\b((?:proxy-)?authorization)(\s*[:=]\s*)(?:(bearer|basic|token|digest|negotiate)\s+)?'''
  r'''("[^"]*"?|'[^']*'?|[^\s"']+)''',
  caseSensitive: false,
);
final RegExp _liveBearer = RegExp(
  r'''\b(bearer)\s+[^\s"']+''',
  caseSensitive: false,
);
final RegExp _liveNamedValue = RegExp(
  r'''(?<![A-Za-z0-9_./\-])(["']?)([A-Za-z0-9_.\-]*(?:token|secret|passw|pwd|api[_-]?key|apikey|access[_-]?key|private[_-]?key|credential|cookie|session|auth)[A-Za-z0-9_.\-]*)\1(\s*:\s*)'''
  r'''("[^"]*"?|'[^']*'?|[^\s"']+)''',
  caseSensitive: false,
);
final RegExp _liveFlag = RegExp(
  r'''(?<![^\s"'])(--?[A-Za-z0-9_\-]*?(?:token|secret|passw|pwd|api[_-]?key|apikey|access[_-]?key|private[_-]?key|credential|auth|key)[A-Za-z0-9_\-]*)'''
  r'''(?:=("[^"]*"?|'[^']*'?|[^\s"']+)|\s+("[^"]*"?|'[^']*'?|[^\s"'\-][^\s"']*))''',
  caseSensitive: false,
);
final RegExp _liveAssignment = RegExp(
  r'''(?<![A-Za-z0-9_\-])([A-Za-z0-9_]*(?:key|token|secret|passw|pass|pwd|auth|credential|session|cookie)[A-Za-z0-9_]*)=("[^"]*"?|'[^']*'?|[^\s"'&]+)''',
  caseSensitive: false,
);
final List<RegExp> _liveSecretShapes = [
  // JWTs, also cut before their second dot.
  RegExp(r'eyJ[A-Za-z0-9_\-]{8,}(?:\.[A-Za-z0-9_\-]*){0,2}'),
  // AWS access key ids.
  RegExp(r'(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{12,}'),
  // Provider key prefixes.
  RegExp(
    r'(?<![A-Za-z0-9])(?:sk-[A-Za-z0-9_\-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|'
    r'github_pat_[A-Za-z0-9_]{8,}|glpat-[A-Za-z0-9_\-]{8,}|'
    r'xox[abprs]-[A-Za-z0-9\-]{8,}|AIza[0-9A-Za-z_\-]{20,})',
  ),
  // Hex digests and keys.
  RegExp(r'(?<![A-Za-z0-9])[0-9a-fA-F]{40,}(?![A-Za-z0-9])'),
];
// A base64 run of 40+ characters; [_liveBlob] decides whether it is a key.
final RegExp _liveBase64 = RegExp(r'(?<![A-Za-z0-9+/_=\-])[A-Za-z0-9+/_\-]{40,}={0,2}');

bool _liveBlob(String run) {
  if (!run.contains(RegExp(r'\d')) ||
      !run.contains(RegExp(r'[a-z]')) ||
      !run.contains(RegExp(r'[A-Z]'))) {
    return false;
  }
  // A path has short segments; a key is one long run.
  return run.split('/').any((segment) => segment.length >= 20);
}

/// What the owner-wired live view shows of a running tool or step: the first
/// non-empty line of its preview, command lines included (the main chat
/// shows the owner its commands too), on one line, capped at
/// [kSubagentLiveTargetMaxChars] and with every secret masked: credentials
/// and sensitive queries of URLs, `Authorization`/`Bearer` values, values of
/// `--token`-like flags and `*KEY*=`-like assignments, JWTs, AWS and provider
/// keys, PEM blocks and long hex or base64 runs, plus what [redactLogLine]
/// hides (e-mails, IPs, long tokens). Null when there is nothing to show.
/// Any other opener (`hideGoal`) and the finished view never call this.
String? subagentLiveTarget(String? raw) {
  if (raw == null) return null;
  var line = '';
  for (final candidate in raw.split(RegExp(r'\r\n|\r|\n'))) {
    if (candidate.trim().isNotEmpty) {
      line = candidate;
      break;
    }
  }
  if (line.length > 4096) line = line.substring(0, 4096);
  line = line
      .replaceAll(_liveControl, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (line.isEmpty) return null;

  line = _maskLiveLine(line);

  final runes = line.runes;
  if (runes.length <= kSubagentLiveTargetMaxChars) return line;
  return '${String.fromCharCodes(runes.take(kSubagentLiveTargetMaxChars - 1)).trimRight()}\u2026';
}

/// Most lines of a tool's output the owner-wired live view keeps.
const int kSubagentLiveOutputMaxLines = 60;

/// Most characters of a tool's output the owner-wired live view keeps.
const int kSubagentLiveOutputMaxChars = 8192;

final RegExp _liveControl = RegExp(
  r'[\x00-\x1f\x7f\u200b-\u200f\u202a-\u202e\u2066-\u2069]',
);

// A path into the server's own live transcripts (the log this view is read
// from) says nothing to the reader and is never shown.
final RegExp _liveServerLog = RegExp(
  r'''[^\s"'`]*cache/delegation/live[^\s"'`]*''',
);

/// What the owner-wired live view shows of a tool's output: its lines as they
/// are (indentation kept, tabs as spaces, control characters dropped), capped
/// at [kSubagentLiveOutputMaxLines] lines and [kSubagentLiveOutputMaxChars]
/// characters, each line masked as [subagentLiveTarget] masks its one line
/// (secrets, e-mails, IPs, long tokens), every line of a PEM block hidden and
/// the server's own transcript paths withheld. Empty when nothing is left.
/// Any other opener (`hideGoal`) and the finished view never call this.
String subagentLiveOutput(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final source = raw.length > kSubagentLiveOutputMaxChars * 2
      ? raw.substring(0, kSubagentLiveOutputMaxChars * 2)
      : raw;
  final out = <String>[];
  var chars = 0;
  var inPem = false;
  for (final rawLine in source.split(RegExp(r'\r\n|\r|\n'))) {
    if (out.length >= kSubagentLiveOutputMaxLines ||
        chars >= kSubagentLiveOutputMaxChars) {
      break;
    }
    var line = rawLine
        .replaceAll('\t', '  ')
        .replaceAll(_liveControl, ' ')
        .trimRight();
    if (line.length > 1024) line = '${line.substring(0, 1023)}\u2026';
    if (inPem) {
      if (line.contains('-----END')) inPem = false;
      line = line.trim().isEmpty ? '' : _liveMask;
    } else if (line.contains('-----BEGIN')) {
      inPem = !line.contains('-----END');
      line = _maskLiveLine(line);
    } else if (line.trim().isNotEmpty) {
      line = _maskLiveLine(line);
    }
    chars += line.length + 1;
    out.add(line);
  }
  while (out.isNotEmpty && out.last.trim().isEmpty) {
    out.removeLast();
  }
  while (out.isNotEmpty && out.first.trim().isEmpty) {
    out.removeAt(0);
  }
  return out.join('\n');
}

/// The masking of [subagentLiveTarget] and [subagentLiveOutput] on one line
/// already free of control characters; its spacing is kept.
String _maskLiveLine(String input) {
  var line = input
      .replaceAll(_liveServerLog, _liveMask)
      .replaceAll(_livePem, '-----BEGIN $_liveMask')
      .replaceAllMapped(_liveUserinfo, (m) => '${m[1]}$_liveMask@')
      .replaceAllMapped(_liveSecretQuery, (m) => '${m[1]}$_liveMask')
      .replaceAllMapped(
        _liveAuthorization,
        (m) => '${m[1]}${m[2]}${m[3] == null ? '' : '${m[3]} '}$_liveMask',
      )
      .replaceAllMapped(_liveBearer, (m) => '${m[1]} $_liveMask')
      .replaceAllMapped(
        _liveNamedValue,
        (m) => m[2]!.toLowerCase().endsWith('authorization')
            ? m[0]!
            : '${m[1]}${m[2]}${m[1]}${m[3]}$_liveMask',
      )
      .replaceAllMapped(
        _liveFlag,
        (m) => m[2] != null
            ? '${m[1]}=$_liveMask'
            : '${m[1]} $_liveMask',
      )
      .replaceAllMapped(_liveAssignment, (m) => '${m[1]}=$_liveMask');
  for (final shape in _liveSecretShapes) {
    line = line.replaceAll(shape, _liveMask);
  }
  line = line.replaceAllMapped(
    _liveBase64,
    (m) => _liveBlob(m[0]!) ? _liveMask : m[0]!,
  );
  // E-mails, IPs and long tokens, word by word (a URL keeps its sanitized
  // form instead of becoming `<url>`).
  return line
      .split(' ')
      .map((word) => word.contains('://') ? word : redactLogLine(word))
      .join(' ');
}

String? _clippedTarget(String value) {
  final line = value
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r' {2,}'), ' ')
      .trim();
  if (line.isEmpty) return null;
  final runes = line.runes;
  if (runes.length <= SubagentFinishedRecord.maxTargetCharacters) {
    return line;
  }
  return '${String.fromCharCodes(runes.take(SubagentFinishedRecord.maxTargetCharacters)).trimRight()}…';
}

/// A short, harmless target of a call: a file path or a URL without its
/// query. Commands, queries and every other argument stay out.
String? _target(Object? rawArguments) {
  final arguments = _map(_decoded(rawArguments));
  if (arguments == null) return null;
  for (final key in const ['path', 'file_path', 'filename', 'url']) {
    final value = arguments[key];
    if (value is! String) continue;
    var line = value.split('\n').first.trim();
    if (key == 'url') {
      // Scheme, host and path only: no credentials, query or fragment.
      final uri = Uri.tryParse(line);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) continue;
      line = Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
      ).toString();
    }
    line = line
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
    if (line.isEmpty) continue;
    final runes = line.runes;
    if (runes.length <= SubagentFinishedRecord.maxTargetCharacters) {
      return line;
    }
    return '${String.fromCharCodes(runes.take(SubagentFinishedRecord.maxTargetCharacters)).trimRight()}…';
  }
  return null;
}

bool _toolFailed(Object? content) {
  final result = _map(_decoded(content));
  if (result == null) return false;
  if (result['success'] == false) return true;
  final error = result['error'];
  if (error != null && error != false && error.toString().trim().isNotEmpty) {
    return true;
  }
  final exit = result['exit_code'];
  return exit is int && exit != 0;
}

Object? _decoded(Object? value) {
  if (value is! String) return value;
  final text = value.trim();
  if (text.isEmpty || text.length > 262144 || !text.startsWith('{')) {
    return null;
  }
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

List<Object?> _list(Object? value) {
  if (value is List) return value;
  final decoded = value is String && value.trim().startsWith('[')
      ? (() {
          try {
            return jsonDecode(value);
          } catch (_) {
            return null;
          }
        })()
      : null;
  return decoded is List ? decoded : const [];
}

Map<String, dynamic>? _map(Object? value) {
  if (value is! Map) return null;
  return value.map((key, item) => MapEntry(key.toString(), item));
}
