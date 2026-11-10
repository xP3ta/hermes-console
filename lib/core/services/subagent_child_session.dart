// A RUNNING subagent read from its own stored session, refreshed while its
// detail page is visible.
//
// The server streams no command output of a child to its parent: the live
// mirror and the `subagent.tail` log say a tool started and little else. The
// child's OWN session, though, is written as it works: Hermes persists the
// assistant tool-call turn before any tool runs and every tool result right
// after it (hermes-agent `agent/turn_tool_round.py`, «Persist the tool-call
// turn before any tool side effects», and `agent/tool_executor.py`
// `_flush_session_db_after_tool_progress`). So the detail page renders from a
// snapshot of that session (`GET /api/sessions/<child>/messages`, newest page,
// the same read the finished view and the transcript page use) and refreshes
// it every [SubagentChildFeed.interval] while the child runs, the cadence and
// the visibility rule of Hermes Desktop's subagent transcript
// (`apps/desktop/src/app/chat/composer/status-stack/subagent-transcript.tsx`:
// a 2 s timer, only while the pane is visible, never two reads at once).
//
// Privacy: owner surface only (the page builds a feed only for it). Tool
// arguments leave this file as one masked line ([subagentLiveTarget]), tool
// output masked and bounded ([subagentToolResult]), reasoning is dropped and
// nothing here is logged.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/subagent_activity.dart';
import '../utils/assistant_content.dart' show finalizedPublicAssistantText;
import '../utils/session_timestamp.dart' show normalizeEpochTimestamp;
import 'subagent_finished_record.dart'
    show SubagentFinishedRecord, subagentGoalsMatch, subagentLiveTarget;
import 'subagent_live_watch.dart' show SubagentWatchBlock;
import 'subagent_tail_log.dart';

/// Reads the newest stored messages of a child session (read-only, bounded).
typedef SubagentChildMessagesReader =
    Future<List<Map<String, dynamic>>> Function(String childSessionId);

/// Finds the stored id of a child whose events did not carry it yet; null
/// when it cannot be told (yet).
typedef SubagentChildSessionResolver =
    Future<String?> Function(SubagentActivity activity);

/// Same shape as the page's tail scheduler: runs [callback] after [delay],
/// returns the cancel.
typedef SubagentChildFeedScheduler =
    VoidCallback Function(Duration delay, VoidCallback callback);

/// What a child session holds so far, as rows of the live view.
@immutable
final class SubagentChildTranscript {
  const SubagentChildTranscript({
    this.goal = '',
    this.entries = const [],
    this.startedAt = const {},
    this.callIds = const {},
    this.signature = '',
  });

  static const SubagentChildTranscript empty = SubagentChildTranscript();

  /// The child's first prompt: its task.
  final String goal;

  /// Its words and tool calls, oldest first.
  final List<SubagentTailEntry> entries;

  /// When each tool call row began, by entry id (from the stored timestamps,
  /// so no device/server clock is compared).
  final Map<String, DateTime> startedAt;

  /// Stored tool call ids, by entry id: what the live mirror names a tool by.
  final Map<String, String> callIds;

  /// Equal for two reads that would paint the same rows.
  final String signature;

  /// The latest tool call still without its result.
  SubagentTailEntry? get runningTool {
    for (final entry in entries.reversed) {
      if (entry.kind == SubagentTailKind.tool) {
        return entry.finished ? null : entry;
      }
    }
    return null;
  }

  bool get isEmpty => goal.isEmpty && entries.isEmpty;
}

/// Most rows of a child kept for the view (the newest ones).
const int kSubagentChildMaxRows = 160;

/// Most characters of a stored tool result decoded per row.
const int _maxResultChars = 65536;

/// The rows of a child session [messages] (chronological). Reasoning,
/// inactive (compacted) rows and display-only rows are left out.
SubagentChildTranscript subagentChildTranscript(
  List<Map<String, dynamic>> messages,
) {
  var goal = '';
  final entries = <_ChildRow>[];
  final byCall = <String, _ChildRow>{};
  var sequence = 0;
  for (final message in messages) {
    final role = (message['role'] ?? '').toString().trim().toLowerCase();
    final active = message['active'];
    if (active == false || active == 0) continue;
    final at = _instant(message['timestamp']);
    final rowId = message['id']?.toString();
    if (role == 'user') {
      if (goal.isEmpty && message['display_kind'] == null) {
        goal = _clip(_text(message['content']), 4000);
      }
      continue;
    }
    if (role == 'assistant') {
      final text = finalizedPublicAssistantText(
        _text(message['content'] ?? message['text']),
      ).trim();
      if (text.isNotEmpty) {
        entries.add(
          _ChildRow.text(
            'child-text-${rowId ?? sequence}',
            _clip(text, SubagentFinishedRecord.maxTextCharacters),
          ),
        );
        sequence++;
      }
      for (final raw in _list(message['tool_calls'])) {
        final call = _map(raw);
        final function = _map(call?['function']);
        final name = _toolName(function?['name'] ?? call?['name']);
        if (name == null) continue;
        final callId = (call?['id'] ?? call?['tool_call_id'])?.toString();
        final validCall =
            callId != null && callId.isNotEmpty && callId.length <= 256;
        final row = _ChildRow.tool(
          id: validCall ? 'child-call-$callId' : 'child-call-${sequence++}',
          tool: name,
          command: _command(function?['arguments'] ?? call?['arguments']),
          time: at == null ? null : _clock(at),
          startedAt: at,
          callId: validCall ? callId : null,
        );
        if (validCall) byCall[callId] = row;
        entries.add(row);
      }
      continue;
    }
    if (role == 'tool' || role == 'tool_result' || role == 'function') {
      final callId = (message['tool_call_id'] ?? message['call_id'])
          ?.toString();
      final row = callId == null ? null : byCall[callId];
      if (row == null || row.finished) continue;
      var raw = _text(message['content'] ?? message['result']);
      if (raw.isEmpty && message['content'] is Map) {
        raw = jsonEncode(message['content']);
      }
      if (raw.length > _maxResultChars) raw = raw.substring(0, _maxResultChars);
      final result = subagentToolResult(raw);
      row
        ..finished = true
        ..failed =
            result.errored || (result.exitCode != null && result.exitCode != 0)
        ..exitCode = result.exitCode
        ..output = result.output
        ..outputCut = result.cut || raw.length >= _maxResultChars;
      final started = row.startedAt;
      if (started != null && at != null) {
        final seconds = at.difference(started).inMilliseconds / 1000;
        if (seconds >= 0 && seconds < const Duration(days: 1).inSeconds) {
          row.durationSeconds = seconds;
        }
      }
    }
  }
  final kept = entries.length > kSubagentChildMaxRows
      ? entries.sublist(entries.length - kSubagentChildMaxRows)
      : entries;
  final frozen = [for (final row in kept) row.freeze()];
  final last = frozen.isEmpty ? null : frozen.last;
  return SubagentChildTranscript(
    goal: goal,
    entries: List.unmodifiable(frozen),
    startedAt: Map.unmodifiable({
      for (final row in kept) row.id: ?row.startedAt,
    }),
    callIds: Map.unmodifiable({
      for (final row in kept) row.id: ?row.callId,
    }),
    signature: [
      goal.length,
      frozen.length,
      for (final entry in frozen)
        '${entry.id}:${entry.finished ? 1 : 0}${entry.failed ? 1 : 0}',
      last?.text.length ?? 0,
      last?.output.length ?? 0,
    ].join('|'),
  );
}

/// The child's rows plus what the live sources saw that the stored session
/// does not hold yet: a tool the mirror started ([watch], matched by tool
/// call id) or a call of the polled log ([tail], matched in order by tool and
/// command, never by its server-local clock) newer than the last stored one.
/// A stored call still open that the log already saw end takes the log's
/// outcome.
List<SubagentTailEntry> mergeSubagentChildRows(
  SubagentChildTranscript child, {
  List<SubagentTailEntry>? tail,
  List<SubagentWatchBlock> watch = const [],
}) {
  final rows = [...child.entries];
  final tools = <int>[
    for (var i = 0; i < rows.length; i++)
      if (rows[i].kind == SubagentTailKind.tool) i,
  ];
  if (tail != null) {
    final tailTools = [
      for (final row in tail)
        if (row.kind == SubagentTailKind.tool) row,
    ];
    // Pair the log's calls with the stored ones in order: both are
    // chronological and the log's window only ever drops the oldest. A call
    // the ordered scan misses may still be a stored one: each stored call
    // answers at most one log call, so the page never shows it twice.
    final taken = <int>{};
    var matchedUpTo = -1;
    var from = 0;
    for (var t = 0; t < tailTools.length; t++) {
      var found = -1;
      for (var c = from; c < tools.length && found < 0; c++) {
        if (_sameCall(rows[tools[c]], tailTools[t])) found = c;
      }
      for (var c = 0; c < from && found < 0; c++) {
        if (!taken.contains(c) && _sameCall(rows[tools[c]], tailTools[t])) {
          found = c;
        }
      }
      if (found < 0) continue;
      final stored = rows[tools[found]];
      final seen = tailTools[t];
      if (!stored.finished && seen.finished) {
        rows[tools[found]] = _finishedFrom(stored, seen);
      }
      taken.add(found);
      matchedUpTo = t;
      if (found >= from) from = found + 1;
    }
    // Calls past the last stored one are newer than the snapshot.
    final storedCalls = tools.length;
    if (matchedUpTo >= 0 || storedCalls == 0) {
      for (var t = matchedUpTo + 1; t < tailTools.length; t++) {
        rows.add(tailTools[t]);
      }
    }
  }
  final known = child.callIds.values.toSet();
  // The mirror's ids are not always the stored call ids: a mirrored call
  // with an unknown id is still the stored (or already shown) call when it
  // names the same tool and command. Each row answers one mirrored call.
  final claimed = <int>{};
  for (final block in watch) {
    final tool = block.tool;
    if (tool == null) continue;
    final byId = rows.indexWhere((row) => child.callIds[row.id] == tool.id);
    if (byId >= 0) {
      claimed.add(byId);
      if (tool.finished && !rows[byId].finished) {
        rows[byId] = _finishedFrom(
          rows[byId],
          SubagentTailEntry(
            id: rows[byId].id,
            kind: SubagentTailKind.tool,
            finished: true,
            failed: tool.failed,
          ),
        );
      }
      continue;
    }
    if (known.contains(tool.id)) continue;
    final seen = SubagentTailEntry(
      id: 'watch-${tool.id}',
      kind: SubagentTailKind.tool,
      tool: tool.name,
      command: subagentLiveTarget(tool.preview),
      finished: tool.finished,
      failed: tool.failed,
    );
    if (rows.any((row) => row.id == seen.id)) continue;
    var at = -1;
    for (var i = 0; i < rows.length && at < 0; i++) {
      if (rows[i].kind == SubagentTailKind.tool &&
          !claimed.contains(i) &&
          _sameCall(rows[i], seen)) {
        at = i;
      }
    }
    if (at >= 0) {
      claimed.add(at);
      if (tool.finished && !rows[at].finished) {
        rows[at] = _finishedFrom(rows[at], seen);
      }
      continue;
    }
    rows.add(seen);
    claimed.add(rows.length - 1);
  }
  return rows;
}

bool _sameCall(SubagentTailEntry stored, SubagentTailEntry seen) {
  if (stored.tool != seen.tool) return false;
  final a = _bare(stored.command);
  final b = _bare(seen.command);
  if (a.isEmpty || b.isEmpty) return true;
  if (a == b) return true;
  // The log shows a shortened command line («for … + 3 comandos»): compare
  // its first command.
  final headA = _firstCommand(a);
  final headB = _firstCommand(b);
  if (headA.isNotEmpty && headA == headB) return true;
  final shorter = a.length <= b.length ? a : b;
  final longer = identical(shorter, a) ? b : a;
  return shorter.length >= 8 && longer.startsWith(shorter);
}

String _bare(String? command) {
  var text = (command ?? '').trim();
  if (text.endsWith('…')) text = text.substring(0, text.length - 1);
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

final RegExp _commandBreak = RegExp(r';|&&|\|\||\||\s\+\s\d+\s');

String _firstCommand(String line) {
  final cut = _commandBreak.firstMatch(line);
  return (cut == null ? line : line.substring(0, cut.start)).trim();
}

SubagentTailEntry _finishedFrom(
  SubagentTailEntry stored,
  SubagentTailEntry seen,
) => SubagentTailEntry(
  id: stored.id,
  kind: stored.kind,
  time: stored.time,
  tool: stored.tool,
  command: stored.command,
  finished: true,
  failed: seen.failed,
  exitCode: seen.exitCode,
  durationSeconds: seen.durationSeconds,
  output: seen.output,
  outputCut: seen.outputCut,
);

/// The one line a call works on: its command, else its path, URL or query.
String? _command(Object? rawArguments) {
  final arguments = _map(_decoded(rawArguments));
  if (arguments == null) return null;
  for (final key in const [
    'command',
    'cmd',
    'path',
    'file_path',
    'filename',
    'url',
    'query',
    'pattern',
    'goal',
  ]) {
    final value = arguments[key];
    if (value is String && value.trim().isNotEmpty) {
      return subagentLiveTarget(value);
    }
  }
  return null;
}

enum SubagentChildFeedStatus {
  /// Not started (hidden page, no reader).
  idle,

  /// The child's stored id is not known yet: «Esperando al subagente…».
  waiting,

  /// First read in flight.
  loading,

  /// At least one read landed.
  live,
}

@immutable
final class SubagentChildFeedView {
  const SubagentChildFeedView({
    this.status = SubagentChildFeedStatus.idle,
    this.transcript = SubagentChildTranscript.empty,
  });

  final SubagentChildFeedStatus status;
  final SubagentChildTranscript transcript;

  bool get hasRows => transcript.entries.isNotEmpty;
}

/// Keeps a snapshot of one child session fresh while its page is visible
/// and the child works. One read at a time; [interval] between reads, doubled
/// per failure up to [maxBackoff]; a read already landed is never wiped by a
/// failure. It notifies only when what it read changed.
class SubagentChildFeed extends ValueNotifier<SubagentChildFeedView> {
  SubagentChildFeed({
    required this.read,
    required this.schedule,
    this.resolve,
    this.interval = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 30),
    this.maxResolveAttempts = 6,
  }) : super(const SubagentChildFeedView());

  final SubagentChildMessagesReader read;
  final SubagentChildFeedScheduler schedule;
  final SubagentChildSessionResolver? resolve;
  final Duration interval;
  final Duration maxBackoff;
  final int maxResolveAttempts;

  String? _childId;
  bool _idTrusted = false;
  String _expectedGoal = '';
  SubagentActivity? _activity;
  bool _running = false;
  bool _visible = false;
  bool _finalReadDue = false;
  bool _disposed = false;

  int _generation = 0;
  bool _inFlight = false;
  VoidCallback? _cancel;
  int _failures = 0;
  int _resolveAttempts = 0;

  /// Reads done so far (tests and diagnostics; never logged).
  int get reads => _reads;
  int _reads = 0;

  /// Whether a read or a timer is pending.
  bool get active => _inFlight || _cancel != null;

  String? get childSessionId => _childId;

  /// Follows the page: the child [activity] (its stored id, whether it still
  /// runs) and whether the page is visible. Starts, keeps or stops reading.
  void sync({required SubagentActivity? activity, required bool visible}) {
    if (_disposed) return;
    final id = activity?.childSessionId?.trim() ?? '';
    if (activity != null) {
      _activity = activity;
      final goal = activity.goalPreview?.trim() ?? '';
      if (goal.isNotEmpty) _expectedGoal = goal;
    }
    if (id.isNotEmpty && (id != _childId || !_idTrusted)) {
      // The id the events carry wins over one a search found.
      _stop();
      _childId = id;
      _idTrusted = true;
      _failures = 0;
    }
    final running = activity != null && !activity.isTerminal;
    if (_running && !running) {
      // One more read now: the child's last rows are stored by then.
      _finalReadDue = true;
      _stop();
    }
    _running = running;
    _visible = visible;
    if (!_visible || (!_running && !_finalReadDue)) {
      _stop();
      return;
    }
    if (active) return;
    if (_childId == null) {
      _publish(SubagentChildFeedStatus.waiting, value.transcript);
      _scheduleResolve(Duration.zero);
      return;
    }
    if (value.status != SubagentChildFeedStatus.live) {
      _publish(SubagentChildFeedStatus.loading, value.transcript);
    }
    _read();
  }

  void _scheduleResolve(Duration delay) {
    final resolver = resolve;
    final activity = _activity;
    if (resolver == null ||
        activity == null ||
        _resolveAttempts >= maxResolveAttempts) {
      return;
    }
    final generation = ++_generation;
    void attempt() {
      _cancel = null;
      if (_disposed || generation != _generation || !_visible) return;
      _resolveAttempts++;
      _inFlight = true;
      Future<String?>.sync(() => resolver(activity))
          .then<String?>((id) => id, onError: (Object _) => null)
          .then((id) {
            if (_disposed || generation != _generation) return;
            _inFlight = false;
            final found = id?.trim() ?? '';
            if (found.isNotEmpty && found.length <= 256) {
              _childId = found;
              _idTrusted = false;
              _read();
              return;
            }
            // 1, 2, 4, 8… s between attempts; the roster may bring the id
            // first, and [sync] then reads at once.
            _scheduleResolve(
              Duration(seconds: 1 << _resolveAttempts.clamp(0, 4)),
            );
          });
    }

    if (delay == Duration.zero) {
      attempt();
    } else {
      _cancel = schedule(delay, attempt);
    }
  }

  void _read() {
    final id = _childId;
    if (_disposed || id == null) return;
    final generation = ++_generation;
    _inFlight = true;
    _reads++;
    Future<List<Map<String, dynamic>>>.sync(() => read(id))
        .then((rows) {
          if (_disposed || generation != _generation) return;
          final transcript = subagentChildTranscript(rows);
          // A search can land on a sibling: trust a found id only when its
          // first prompt is this task.
          if (!_idTrusted &&
              !subagentGoalsMatch(transcript.goal, _expectedGoal)) {
            _childId = null;
            _publish(SubagentChildFeedStatus.waiting, value.transcript);
            return;
          }
          _idTrusted = true;
          _failures = 0;
          if (value.status != SubagentChildFeedStatus.live ||
              transcript.signature != value.transcript.signature) {
            _publish(SubagentChildFeedStatus.live, transcript);
          }
        })
        .catchError((Object _) {
          if (generation == _generation) _failures++;
        })
        .whenComplete(() {
          if (_disposed || generation != _generation) return;
          _inFlight = false;
          if (_childId == null) {
            _scheduleResolve(const Duration(seconds: 1));
            return;
          }
          if (!_running) {
            // The read after the child ended: what it did last is in.
            if (_failures == 0) _finalReadDue = false;
            if (!_finalReadDue) return;
          }
          if (!_visible) return;
          _cancel = schedule(_nextDelay(), () {
            _cancel = null;
            if (!_disposed && generation == _generation && _visible) _read();
          });
        });
  }

  Duration _nextDelay() {
    if (_failures == 0) return interval;
    final factor = 1 << _failures.clamp(0, 5);
    final delay = interval * factor;
    return delay > maxBackoff ? maxBackoff : delay;
  }

  void _publish(
    SubagentChildFeedStatus status,
    SubagentChildTranscript transcript,
  ) {
    if (_disposed) return;
    if (status == value.status && identical(transcript, value.transcript)) {
      return;
    }
    value = SubagentChildFeedView(status: status, transcript: transcript);
  }

  void _stop() {
    _generation++;
    _cancel?.call();
    _cancel = null;
    _inFlight = false;
  }

  @override
  void dispose() {
    _stop();
    _disposed = true;
    super.dispose();
  }
}

/// Mutable while reading; frozen into a [SubagentTailEntry].
final class _ChildRow {
  _ChildRow.text(this.id, this.text)
    : kind = SubagentTailKind.text,
      tool = null,
      command = null,
      time = null,
      startedAt = null,
      callId = null;

  _ChildRow.tool({
    required this.id,
    required this.tool,
    required this.command,
    required this.time,
    required this.startedAt,
    required this.callId,
  }) : kind = SubagentTailKind.tool,
       text = '';

  final String id;
  final SubagentTailKind kind;
  final String? tool;
  final String? command;
  final String? time;
  final DateTime? startedAt;
  final String? callId;
  final String text;
  bool finished = false;
  bool failed = false;
  int? exitCode;
  double? durationSeconds;
  String output = '';
  bool outputCut = false;

  SubagentTailEntry freeze() => SubagentTailEntry(
    id: id,
    kind: kind,
    time: time,
    tool: tool,
    command: command,
    finished: finished,
    failed: failed,
    exitCode: exitCode,
    durationSeconds: durationSeconds,
    output: output,
    outputCut: outputCut,
    text: text,
  );
}

DateTime? _instant(Object? raw) {
  final seconds = normalizeEpochTimestamp(raw);
  if (seconds != null && seconds > 0) {
    return DateTime.fromMillisecondsSinceEpoch(
      (seconds * 1000).round(),
      isUtc: true,
    );
  }
  if (raw is String && raw.trim().isNotEmpty) {
    return DateTime.tryParse(raw.trim())?.toUtc();
  }
  return null;
}

String _clock(DateTime at) {
  final local = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

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
  if (value is String && value.trim().startsWith('[')) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) return decoded;
    } catch (_) {
      return const [];
    }
  }
  return const [];
}

Map<String, dynamic>? _map(Object? value) {
  if (value is! Map) return null;
  return value.map((key, item) => MapEntry(key.toString(), item));
}
