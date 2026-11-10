// What a running subagent's live transcript (`subagent.tail`) says, as rows.
//
// The gateway serves the end of the child's live log, written by
// `tools/delegation_live_log.py` (LiveTranscriptWriter), one event per line:
//
//   HH:MM:SS <role padded to 9>| <text>
//
// with `role` one of `user` (kickoff), `start`, `think`, `assistant`, `tool`,
// `result` and `final`, and `text` already whitespace-collapsed to one line
// and cut with ` …(+N chars)` past its budget. A tool line is
// `-> name(args preview)`; its result line `name ok|ERROR [N.Ns]: <result>`,
// where the result is usually the tool's JSON (`{"output": "…\n…",
// "exit_code": 0, "error": null, "cwd": "…"}`), cut mid-string more often
// than not. A header block (`=== Hermes subagent live transcript ===`,
// `delegation:`, `goal:`, `started:`) opens the file.
//
// [parseSubagentTailLog] turns that text into [SubagentTailEntry] rows: one
// per tool call (its result folded in: status, exit code, duration and the
// decoded output), the child's prose, and readable fallbacks for anything
// else. Every command and output line is masked here already
// ([subagentLiveTarget], [subagentLiveOutput]); which of it is shown is the
// widget's call (owner-wired surface only).
import 'dart:convert';

import 'subagent_finished_record.dart'
    show
        kSubagentLiveOutputMaxChars,
        kSubagentLiveOutputMaxLines,
        subagentLiveOutput,
        subagentLiveTarget;

enum SubagentTailKind {
  /// One tool call, with its result once it arrived.
  tool,

  /// What the child wrote (its reply text).
  text,

  /// What the child thought.
  thought,

  /// The child's run ended in an error.
  error,
}

/// One row of the live transcript.
final class SubagentTailEntry {
  const SubagentTailEntry({
    required this.id,
    required this.kind,
    this.time,
    this.tool,
    this.command,
    this.finished = false,
    this.failed = false,
    this.exitCode,
    this.durationSeconds,
    this.output = '',
    this.outputCut = false,
    this.text = '',
  });

  /// Stable while the row stays in the window: its time, kind and text.
  final String id;
  final SubagentTailKind kind;

  /// `HH:MM:SS` as the server wrote it (the start of a tool call).
  final String? time;

  /// The tool's registered name (`terminal`, `read_file`…).
  final String? tool;

  /// The call's one-line target (a command, a path), masked.
  final String? command;

  /// Whether its result arrived.
  final bool finished;
  final bool failed;
  final int? exitCode;
  final double? durationSeconds;

  /// What it printed, decoded and masked, several lines; may be empty.
  final String output;

  /// Whether [output] is not all of it (cut by the server or here).
  final bool outputCut;

  /// The prose of a text, thought or error row: one paragraph, masked.
  final String text;

  @override
  String toString() =>
      'SubagentTailEntry($kind, $time, $tool, $command, finished: $finished, '
      'failed: $failed, exit: $exitCode, output: $output, text: $text)';
}

/// The roles the server writes; anything else is not an event line.
const List<String> _roles = [
  'user',
  'start',
  'think',
  'assistant',
  'tool',
  'result',
  'final',
];

final RegExp _eventLine = RegExp(
  r'^(\d\d:\d\d:\d\d) (user|start|think|assistant|tool|result|final)\s*\| ?(.*)$',
);

// Where a second event starts when lines were joined (copied, re-wrapped):
// the server pads the role to 9 characters, so the exact padding is required.
final RegExp _joinedEvent = RegExp(
  ' (?=\\d\\d:\\d\\d:\\d\\d (?:${_roles.map((r) => RegExp.escape(r.padRight(9))).join('|')})\\|)',
);

final RegExp _cutMarker = RegExp(r'\s?…\(\+(\d+) chars\)$');
final RegExp _toolCall = RegExp(r'^->\s*([^\s(]+)\((.*)\)$');
final RegExp _toolCallCut = RegExp(r'^->\s*([^\s(]+)\((.*)$');
final RegExp _resultHead = RegExp(
  r'^([^\s:]+) (ok|ERROR)(?: (\d+(?:\.\d+)?)s)?: ?(.*)$',
);
final RegExp _exitPrefix = RegExp(r'^exit=(-?\d+)\s*(?:\r\n|\r|\n|$)');

/// Most characters of one prose row.
const int kSubagentTailTextMaxChars = 1200;

/// Whether [text] is the server's live transcript (has at least one event
/// line) rather than prose the watch mirrored.
bool isSubagentTailLog(String text) =>
    _lines(text).any((line) => _eventLine.hasMatch(line));

Iterable<String> _lines(String text) sync* {
  for (final physical in text.split(RegExp(r'\r\n|\r|\n'))) {
    if (physical.isEmpty) continue;
    yield* physical.split(_joinedEvent);
  }
}

/// Rows of the live transcript [text], oldest first. A first line cut by the
/// window ([truncated]) and the file's header are left out; a line that is
/// not an event reads as one short prose row, never as a raw blob.
List<SubagentTailEntry> parseSubagentTailLog(
  String text, {
  bool truncated = false,
}) {
  final rows = <_Row>[];
  final ids = <String, int>{};
  String idFor(String base) {
    final n = ids.update(base, (v) => v + 1, ifAbsent: () => 0);
    return n == 0 ? base : '$base#$n';
  }

  var first = true;
  var inHeader = false;
  for (final raw in _lines(text)) {
    final line = raw.trimRight();
    final isFirst = first;
    first = false;
    if (line.trim().isEmpty) continue;
    final match = _eventLine.firstMatch(line);
    if (match == null) {
      if (isFirst && truncated) continue;
      if (line.startsWith('=== Hermes subagent live transcript')) {
        inHeader = true;
        continue;
      }
      if (inHeader) {
        if (RegExp(r'^={8,}$').hasMatch(line.trim())) inHeader = false;
        continue;
      }
      if (_isHeaderLine(line)) continue;
      final prose = _prose(line);
      if (prose.isEmpty) continue;
      rows.add(
        _Row.text(idFor('x ${_hash(line)}'), SubagentTailKind.text, null, prose),
      );
      continue;
    }
    inHeader = false;
    final time = match[1]!;
    final role = match[2]!;
    final body = match[3]!;
    switch (role) {
      case 'user' || 'start':
        // The kickoff repeats the goal, shown as the prompt already.
        continue;
      case 'think' || 'assistant':
        final prose = _prose(body);
        if (prose.isEmpty) continue;
        final kind = role == 'think'
            ? SubagentTailKind.thought
            : SubagentTailKind.text;
        // The writer logs a thought cut short and then the same words in
        // full as its reply: keep the reply only.
        if (kind == SubagentTailKind.text &&
            rows.isNotEmpty &&
            rows.last.kind == SubagentTailKind.thought &&
            _samePrefix(rows.last.text, prose)) {
          rows.removeLast();
        }
        rows.add(_Row.text(idFor('$time $role ${_hash(body)}'), kind, time, prose));
      case 'tool':
        final call = _toolCall.firstMatch(body) ?? _toolCallCut.firstMatch(body);
        if (call == null) {
          final prose = _prose(body);
          if (prose.isNotEmpty) {
            rows.add(
              _Row.text(idFor('$time t ${_hash(body)}'), SubagentTailKind.text, time, prose),
            );
          }
          continue;
        }
        var args = call[2]!;
        var cut = false;
        final marker = _cutMarker.firstMatch(args);
        if (marker != null) {
          args = args.substring(0, marker.start);
          cut = true;
        }
        var command = subagentLiveTarget(args);
        if (command != null && cut && !command.endsWith('…')) {
          command = '$command…';
        }
        rows.add(
          _Row.tool(
            id: idFor('$time ${call[1]} ${_hash(body)}'),
            time: time,
            tool: call[1]!,
            command: command,
          ),
        );
      case 'result':
        final head = _resultHead.firstMatch(body);
        if (head == null) {
          final prose = _prose(body);
          if (prose.isNotEmpty) {
            rows.add(
              _Row.text(idFor('$time r ${_hash(body)}'), SubagentTailKind.text, time, prose),
            );
          }
          continue;
        }
        final name = head[1]!;
        final result = _decodeResult(head[4]!);
        final failed =
            head[2] == 'ERROR' ||
            (result.exitCode != null && result.exitCode != 0) ||
            result.errored;
        // The oldest call of that tool still waiting for its result; a
        // result whose call fell out of the window gets its own row.
        _Row? waiting;
        for (final row in rows) {
          if (row.kind == SubagentTailKind.tool &&
              !row.finished &&
              row.tool == name) {
            waiting = row;
            break;
          }
        }
        final _Row owner;
        if (waiting != null) {
          owner = waiting;
        } else {
          owner = _Row.tool(
            id: idFor('$time $name result ${_hash(body)}'),
            time: time,
            tool: name,
            command: null,
          );
          rows.add(owner);
        }
        owner
          ..finished = true
          ..failed = failed
          ..exitCode = result.exitCode
          ..durationSeconds = head[3] == null ? null : double.tryParse(head[3]!)
          ..output = result.output
          ..outputCut = result.cut;
      case 'final':
        // `status=… duration=… summary: …` repeats the result shown below
        // the log; `end status=… error: …` is the one worth a row.
        final error = RegExp(r'\berror: (.*)$').firstMatch(body);
        if (error != null) {
          final prose = _prose(error[1]!);
          if (prose.isNotEmpty) {
            rows.add(
              _Row.text(idFor('$time final ${_hash(body)}'), SubagentTailKind.error, time, prose),
            );
          }
        }
    }
  }
  return [for (final row in rows) row.freeze()];
}

bool _isHeaderLine(String line) =>
    RegExp(r'^(delegation: \S+\s+task: \d+|started: \d{4}-\d\d-\d\d \d\d:\d\d:\d\d|\(append-only;.*)$')
        .hasMatch(line.trim());

bool _samePrefix(String thought, String reply) {
  var head = thought;
  if (head.endsWith('…')) head = head.substring(0, head.length - 1);
  head = head.trimRight();
  return head.isNotEmpty && reply.startsWith(head);
}

String _hash(String value) =>
    (value.length > 200 ? value.substring(0, 200) : value).hashCode
        .toRadixString(36);

/// One masked paragraph: the cut marker becomes `…`, escapes stay as text.
String _prose(String body) {
  var text = body.trim();
  var cut = false;
  final marker = _cutMarker.firstMatch(text);
  if (marker != null) {
    text = text.substring(0, marker.start).trimRight();
    cut = true;
  }
  if (text.length > kSubagentTailTextMaxChars) {
    text = text.substring(0, kSubagentTailTextMaxChars).trimRight();
    cut = true;
  }
  text = subagentLiveOutput(text).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return '';
  return cut && !text.endsWith('…') ? '$text…' : text;
}

final class _Decoded {
  const _Decoded({
    this.output = '',
    this.exitCode,
    this.errored = false,
    this.cut = false,
  });

  final String output;
  final int? exitCode;
  final bool errored;
  final bool cut;
}

/// The fields of a tool's result that say what it printed, in order.
const List<String> _outputFields = [
  'output',
  'content',
  'diff',
  'matches_text',
  'text',
  'stdout',
  'result',
  'message',
  'summary',
];

/// What a tool's stored result says (a child session's `tool` row), decoded
/// and masked like a result line of the live transcript: the output to show,
/// the exit code, whether it errored and whether [raw] was cut.
({String output, int? exitCode, bool errored, bool cut}) subagentToolResult(
  String raw,
) {
  final decoded = _decodeResult(raw);
  return (
    output: decoded.output,
    exitCode: decoded.exitCode,
    errored: decoded.errored,
    cut: decoded.cut,
  );
}

_Decoded _decodeResult(String raw) {
  var body = raw.trim();
  var cut = false;
  final marker = _cutMarker.firstMatch(body);
  if (marker != null) {
    body = body.substring(0, marker.start);
    cut = true;
  }
  Map<String, Object?>? fields;
  if (body.startsWith('{')) {
    if (!cut) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map) {
          fields = decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (_) {
        // A Python repr or a cut object: read it leniently below.
      }
    }
    if (fields == null) {
      final reader = _LenientObject(body);
      fields = reader.read();
      cut = cut || reader.cut;
    }
  }
  if (fields != null && fields.isEmpty) {
    // An object with nothing readable at its top (only nested data, or cut
    // before its first value): no output rather than raw braces.
    return _Decoded(cut: cut);
  }
  if (fields == null) {
    // Not JSON: the text itself (`Error executing tool …`), one paragraph.
    final text = _prose(body);
    return _Decoded(
      output: text,
      errored: RegExp(r'^(error|traceback)\b', caseSensitive: false)
          .hasMatch(text),
      cut: cut,
    );
  }
  int? exit = switch (fields['exit_code']) {
    final int v => v,
    final double v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };
  final error = switch (fields['error']) {
    final String v when v.trim().isNotEmpty => v,
    _ => null,
  };
  final success = fields['success'];
  var output = '';
  for (final key in _outputFields) {
    final value = fields[key];
    if (value is String && value.trim().isNotEmpty) {
      output = value;
      break;
    }
  }
  // A wrapped command reports its own status first: `exit=1\n…`.
  final prefix = _exitPrefix.firstMatch(output);
  if (prefix != null) {
    final inner = int.tryParse(prefix[1]!);
    if (exit == null || (exit == 0 && inner != null && inner != 0)) {
      exit = inner;
    }
    output = output.substring(prefix.end);
  }
  if (error != null) {
    output = output.trim().isEmpty ? error : '$output\n$error';
  }
  final capped =
      output.length > kSubagentLiveOutputMaxChars ||
      RegExp(r'\r\n|\r|\n').allMatches(output.trimRight()).length >=
          kSubagentLiveOutputMaxLines;
  return _Decoded(
    output: subagentLiveOutput(output),
    exitCode: exit,
    errored: error != null || success == false,
    cut: cut || capped,
  );
}

/// Reads the top-level scalar fields of a JSON object that may be cut
/// anywhere: strings (escapes decoded; one cut short ends where the text
/// ends), numbers, `true`/`false`/`null`; nested values are skipped. Never
/// throws.
final class _LenientObject {
  _LenientObject(this.source);

  final String source;
  int _i = 0;

  /// Whether [read] hit the end of [source] inside the object.
  bool cut = false;

  Map<String, Object?> read() {
    final out = <String, Object?>{};
    try {
      _ws();
      if (!_eat('{')) return out;
      while (true) {
        _ws();
        if (_i >= source.length) {
          cut = true;
          break;
        }
        if (_eat('}')) break;
        if (_eat(',')) continue;
        final quote = _peek();
        if (quote != '"' && quote != "'") break;
        final (key, keyDone) = _string();
        if (!keyDone) {
          cut = true;
          break;
        }
        _ws();
        if (!_eat(':')) break;
        _ws();
        if (_i >= source.length) {
          cut = true;
          break;
        }
        final c = _peek();
        if (c == '"' || c == "'") {
          final (value, done) = _string();
          out[key] = value;
          if (!done) {
            cut = true;
            break;
          }
        } else if (c == '{' || c == '[') {
          if (!_skipNested()) {
            cut = true;
            break;
          }
        } else {
          final start = _i;
          while (_i < source.length && !',}'.contains(source[_i])) {
            _i++;
          }
          final literal = source.substring(start, _i).trim();
          out[key] = switch (literal) {
            'null' || 'None' => null,
            'true' || 'True' => true,
            'false' || 'False' => false,
            _ => num.tryParse(literal) ?? literal,
          };
        }
      }
    } catch (_) {
      // What was read so far is the answer.
    }
    return out;
  }

  String _peek() => source[_i];

  bool _eat(String c) {
    if (_i < source.length && source[_i] == c) {
      _i++;
      return true;
    }
    return false;
  }

  void _ws() {
    while (_i < source.length && ' \t\r\n'.contains(source[_i])) {
      _i++;
    }
  }

  /// A string literal from the quote at [_i]: its decoded text and whether
  /// its closing quote was there.
  (String, bool) _string() {
    final quote = source[_i++];
    final out = StringBuffer();
    while (_i < source.length) {
      final c = source[_i++];
      if (c == quote) return (out.toString(), true);
      if (c != r'\') {
        out.write(c);
        continue;
      }
      if (_i >= source.length) break;
      final e = source[_i++];
      switch (e) {
        case 'n':
          out.write('\n');
        case 'r':
          out.write('\r');
        case 't':
          out.write('\t');
        case 'b' || 'f':
          break;
        case 'u':
          if (_i + 4 > source.length) {
            _i = source.length;
            return (out.toString(), false);
          }
          final code = int.tryParse(source.substring(_i, _i + 4), radix: 16);
          _i += 4;
          if (code == null) continue;
          // A surrogate pair is two escapes; a lone half is dropped.
          if (code >= 0xD800 && code <= 0xDBFF) {
            if (_i + 6 <= source.length &&
                source[_i] == r'\' &&
                source[_i + 1] == 'u') {
              final low = int.tryParse(
                source.substring(_i + 2, _i + 6),
                radix: 16,
              );
              if (low != null && low >= 0xDC00 && low <= 0xDFFF) {
                _i += 6;
                out.writeCharCode(
                  0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00),
                );
              }
            }
            continue;
          }
          if (code >= 0xDC00 && code <= 0xDFFF) continue;
          out.writeCharCode(code);
        default:
          out.write(e);
      }
    }
    return (out.toString(), false);
  }

  /// Skips a nested object or array; false when the text ends inside it.
  bool _skipNested() {
    var depth = 0;
    while (_i < source.length) {
      final c = source[_i];
      if (c == '"' || c == "'") {
        final (_, done) = _string();
        if (!done) return false;
        continue;
      }
      _i++;
      if (c == '{' || c == '[') depth++;
      if (c == '}' || c == ']') {
        depth--;
        if (depth == 0) return true;
      }
    }
    return false;
  }
}

/// Mutable while parsing; frozen into a [SubagentTailEntry].
final class _Row {
  _Row.text(this.id, this.kind, this.time, this.text)
    : tool = null,
      command = null;

  _Row.tool({
    required this.id,
    required this.time,
    required this.tool,
    required this.command,
  }) : kind = SubagentTailKind.tool,
       text = '';

  final String id;
  final SubagentTailKind kind;
  final String? time;
  final String? tool;
  final String? command;
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
