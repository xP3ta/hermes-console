// The conversation of a code agent, read from the session file its tool keeps
// on the server (1.4.0): `~/.claude/projects/<folder>/<id>.jsonl` for Claude
// Code and `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` for Codex. Only the
// shapes seen in those files are read; any line that is cut, not JSON or of a
// kind not known here is skipped, and any field not known is ignored. Pure
// text work: nothing here runs anything, opens a file or sends the content
// anywhere. Text shown goes through [herdrMaskSecrets] first.
import 'dart:convert';

import '../capabilities/spp_safety.dart'
    show sppIsSecretName, sppLooksLikeSecret, sppMask;

/// Most characters of one message kept for the view.
const int herdrTextMax = 8000;

/// Most characters of a step's one-line summary and of its result preview.
const int herdrStepSummaryMax = 160;
const int herdrStepResultMax = 600;

/// Most turns a transcript keeps (the newest).
const int herdrTurnsMax = 300;

enum HerdrTurnKind { user, assistant, thinking, steps, question }

enum HerdrStepState { running, done, failed }

/// One tool call of the agent: what it is, a line about what it was asked,
/// what came back (a preview) and where it stands.
class HerdrStep {
  HerdrStep({required this.id, required this.name, required this.summary});

  final String id;
  final String name;
  final String summary;
  String? result;
  HerdrStepState state = HerdrStepState.running;
}

/// One block of the conversation, in order.
class HerdrTurn {
  HerdrTurn(
    this.kind, {
    required this.key,
    this.text = '',
    List<HerdrStep>? steps,
    this.options = const [],
    this.callId,
  }) : steps = steps ?? [];

  final HerdrTurnKind kind;

  /// Stable identity while the transcript grows (the line's own id).
  final String key;

  /// The message (user, assistant, thinking) or the question.
  final String text;

  /// The tool calls of a `steps` turn.
  final List<HerdrStep> steps;

  /// The options of a `question`, as the tool listed them.
  final List<String> options;

  /// The tool call a `question` came from.
  final String? callId;

  /// A `question` that has its answer in the file.
  bool answered = false;

  /// The state of a `steps` turn as a whole: running while any call is, failed
  /// when any failed, else done.
  HerdrStepState get overall {
    var failed = false;
    for (final step in steps) {
      if (step.state == HerdrStepState.running) return HerdrStepState.running;
      if (step.state == HerdrStepState.failed) failed = true;
    }
    return failed ? HerdrStepState.failed : HerdrStepState.done;
  }
}

final RegExp _secretValue = RegExp(
  r'''\b([A-Za-z_][A-Za-z0-9_.\-]*)(\s*[=:]\s*)("[^"\n]*"|'[^'\n]*'|[^\s"']+)''',
);
final RegExp _longToken = RegExp(r'[A-Za-z0-9_=\-.]{20,}');

/// [text] with the obvious secrets hidden: the value of anything named like a
/// credential (`API_KEY=…`, `password: …`) and any word shaped like a token.
/// It does not promise to find every secret; it is the same masking the
/// capability screens use, applied to what an agent's file says.
String herdrMaskSecrets(String text) {
  if (text.isEmpty) return text;
  final named = text.replaceAllMapped(
    _secretValue,
    (m) => sppIsSecretName(m.group(1)!)
        ? '${m.group(1)}${m.group(2)}$sppMask'
        : m.group(0)!,
  );
  return named.replaceAllMapped(
    _longToken,
    (m) => sppLooksLikeSecret(m.group(0)!) ? sppMask : m.group(0)!,
  );
}

String _cap(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max - 1)}…';

Map<String, Object?>? _decode(String raw) {
  final line = raw.trim();
  if (line.isEmpty || !line.startsWith('{')) return null;
  try {
    final value = jsonDecode(line);
    return value is Map<String, Object?> ? value : null;
  } catch (_) {
    return null;
  }
}

String? _string(Object? value) => value is String ? value : null;

/// The one line that says what a tool call was asked: its command, file,
/// pattern or the like.
String herdrStepSummary(Object? input) {
  if (input is String) return _cap(herdrMaskSecrets(input.trim()), 160);
  if (input is! Map) return '';
  for (final key in const [
    'command',
    'cmd',
    'file_path',
    'path',
    'pattern',
    'url',
    'query',
    'description',
    'prompt',
  ]) {
    final value = input[key];
    final text = value is List ? value.whereType<String>().join(' ') : value;
    if (text is String && text.trim().isNotEmpty) {
      return _cap(herdrMaskSecrets(text.trim().replaceAll('\n', ' ')), 160);
    }
  }
  for (final value in input.values) {
    if (value is String && value.trim().isNotEmpty) {
      return _cap(herdrMaskSecrets(value.trim().replaceAll('\n', ' ')), 160);
    }
  }
  return '';
}

String _resultText(Object? content) {
  if (content is String) return content;
  if (content is List) {
    return content
        .map((b) => b is Map ? _string(b['text']) ?? '' : '')
        .where((t) => t.isNotEmpty)
        .join('\n');
  }
  return '';
}

class _Builder {
  final List<HerdrTurn> turns = [];
  final Map<String, HerdrStep> _steps = {};
  final Map<String, HerdrTurn> _questions = {};

  void user(String key, String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    turns.add(
      HerdrTurn(
        HerdrTurnKind.user,
        key: key,
        text: herdrMaskSecrets(_cap(clean, herdrTextMax)),
      ),
    );
  }

  void assistant(String key, String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    turns.add(
      HerdrTurn(
        HerdrTurnKind.assistant,
        key: key,
        text: herdrMaskSecrets(_cap(clean, herdrTextMax)),
      ),
    );
  }

  void thinking(String key, String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    turns.add(
      HerdrTurn(
        HerdrTurnKind.thinking,
        key: key,
        text: herdrMaskSecrets(_cap(clean, herdrTextMax)),
      ),
    );
  }

  void step(String key, String id, String name, Object? input) {
    final step = HerdrStep(
      id: id,
      name: name,
      summary: herdrStepSummary(input),
    );
    _steps[id] = step;
    if (turns.isNotEmpty && turns.last.kind == HerdrTurnKind.steps) {
      turns.last.steps.add(step);
    } else {
      turns.add(HerdrTurn(HerdrTurnKind.steps, key: key, steps: [step]));
    }
  }

  void question(String key, String id, String text, List<String> options) {
    final turn = HerdrTurn(
      HerdrTurnKind.question,
      key: key,
      text: herdrMaskSecrets(_cap(text, herdrTextMax)),
      options: [for (final o in options) herdrMaskSecrets(_cap(o, 200))],
      callId: id,
    );
    _questions[id] = turn;
    turns.add(turn);
  }

  void result(String id, String text, {required bool failed}) {
    final question = _questions[id];
    if (question != null) question.answered = true;
    final step = _steps[id];
    if (step == null) return;
    step.state = failed ? HerdrStepState.failed : HerdrStepState.done;
    final clean = text.trim();
    if (clean.isNotEmpty) {
      step.result = herdrMaskSecrets(_cap(clean, herdrStepResultMax));
    }
  }

  List<HerdrTurn> finish() => turns.length <= herdrTurnsMax
      ? turns
      : turns.sublist(turns.length - herdrTurnsMax);
}

bool _wrapper(String text) {
  final t = text.trimLeft();
  return t.startsWith('<local-command') ||
      t.startsWith('<command-') ||
      t.startsWith('<system-reminder') ||
      t.startsWith('Caveat: The messages below');
}

/// The conversation in a Claude Code session file (its lines, oldest
/// first). Messages of side chains and meta messages are left out.
List<HerdrTurn> herdrParseClaude(Iterable<String> lines) {
  final b = _Builder();
  var index = 0;
  for (final raw in lines) {
    index++;
    final obj = _decode(raw);
    if (obj == null) continue;
    if (obj['isSidechain'] == true || obj['isMeta'] == true) continue;
    final message = obj['message'];
    if (message is! Map) continue;
    final key = _string(obj['uuid']) ?? 'i$index';
    final content = message['content'];
    final type = obj['type'];
    if (type == 'user') {
      if (content is String) {
        if (!_wrapper(content)) b.user(key, content);
      } else if (content is List) {
        for (final block in content) {
          if (block is! Map) continue;
          final kind = block['type'];
          if (kind == 'text') {
            final text = _string(block['text']) ?? '';
            if (!_wrapper(text)) b.user(key, text);
          } else if (kind == 'tool_result') {
            final id = _string(block['tool_use_id']);
            if (id != null) {
              b.result(
                id,
                _resultText(block['content']),
                failed: block['is_error'] == true,
              );
            }
          }
        }
      }
    } else if (type == 'assistant') {
      if (content is String) {
        b.assistant(key, content);
      } else if (content is List) {
        for (final block in content) {
          if (block is! Map) continue;
          switch (block['type']) {
            case 'text':
              b.assistant(key, _string(block['text']) ?? '');
            case 'thinking':
              b.thinking(key, _string(block['thinking']) ?? '');
            case 'tool_use':
              final id = _string(block['id']) ?? 'u$index';
              final name = _string(block['name']) ?? '';
              final input = block['input'];
              final asked = name == 'AskUserQuestion' ? _asked(input) : null;
              if (asked != null) {
                b.question(key, id, asked.$1, asked.$2);
              } else {
                b.step(key, id, name, input);
              }
          }
        }
      }
    }
  }
  return b.finish();
}

/// The first question of an AskUserQuestion call and its option labels.
(String, List<String>)? _asked(Object? input) {
  if (input is! Map) return null;
  final questions = input['questions'];
  if (questions is! List || questions.isEmpty) return null;
  final first = questions.first;
  if (first is! Map) return null;
  final text = _string(first['question']);
  if (text == null || text.trim().isEmpty) return null;
  final options = first['options'];
  return (
    text,
    [
      if (options is List)
        for (final option in options)
          if (option is Map && _string(option['label']) != null)
            _string(option['label'])!,
    ],
  );
}

bool _codexContext(String text) {
  final t = text.trimLeft();
  return RegExp(r'^<[a-z_]+>').hasMatch(t) || t.startsWith('# AGENTS.md');
}

String _blocks(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  return content
      .map((b) => b is Map ? _string(b['text']) ?? '' : '')
      .where((t) => t.isNotEmpty)
      .join('\n');
}

/// The conversation in a Codex rollout file (its lines, oldest first).
List<HerdrTurn> herdrParseCodex(Iterable<String> lines) {
  final b = _Builder();
  var index = 0;
  for (final raw in lines) {
    index++;
    final obj = _decode(raw);
    if (obj == null || obj['type'] != 'response_item') continue;
    final p = obj['payload'];
    if (p is! Map) continue;
    final key = _string(p['id']) ?? 'i$index';
    switch (p['type']) {
      case 'message':
        final text = _blocks(p['content']);
        if (p['role'] == 'user') {
          if (!_codexContext(text)) b.user(key, text);
        } else if (p['role'] == 'assistant') {
          b.assistant(key, text);
        }
      case 'reasoning':
        final summary = p['summary'];
        if (summary is List) b.thinking(key, _blocks(summary));
      case 'function_call' || 'custom_tool_call' || 'local_shell_call':
        final id = _string(p['call_id']) ?? _string(p['id']) ?? 'c$index';
        Object? input = p['arguments'] ?? p['input'] ?? p['action'];
        if (input is String && input.trimLeft().startsWith('{')) {
          try {
            input = jsonDecode(input);
          } catch (_) {
            // Keep the text as it came.
          }
        }
        b.step(key, id, _string(p['name']) ?? 'shell', input);
      case 'function_call_output' || 'custom_tool_call_output':
        final id = _string(p['call_id']);
        if (id == null) continue;
        var output = p['output'];
        var failed = false;
        if (output is String && output.trimLeft().startsWith('{')) {
          try {
            final decoded = jsonDecode(output);
            if (decoded is Map) {
              final meta = decoded['metadata'];
              final code = meta is Map ? meta['exit_code'] : null;
              failed = code is int && code != 0;
              output = decoded['output'] ?? output;
            }
          } catch (_) {
            // Keep the text as it came.
          }
        }
        b.result(id, _resultText(output), failed: failed);
    }
  }
  return b.finish();
}
