import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/long_streaming_transcript_fixture.dart';

ActiveChat _chat(ActiveChatService service, String id) => service.attach(
  connection: SavedConnection(
    id: 'parity-$id',
    label: 'Parity',
    host: '10.0.0.1',
    port: 8642,
    apiKey: 'k',
  ),
  sessionId: 'parity-$id',
  sessionTitle: 'Parity',
  api: ApiClient(
    baseUrl: 'http://10.0.0.1:8642',
    apiKey: 'k',
    httpClient: MockClient((_) async => http.Response('not found', 404)),
  ),
);

/// Deep equality of public values with the leaf semantics of the service's
/// own retention (`==`). Completion cards have no `==` and compare by content.
bool _samePublic(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) ||
          !_samePublic(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_samePublic(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is SubagentCompletionCardData && b is SubagentCompletionCardData) {
    return a.completionKey == b.completionKey &&
        a.delegationId == b.delegationId &&
        a.taskCount == b.taskCount &&
        a.completedCount == b.completedCount &&
        a.failedCount == b.failedCount &&
        a.durationSeconds == b.durationSeconds &&
        a.subagentIds.join('\u0000') == b.subagentIds.join('\u0000');
  }
  return a == b;
}

Object? _deepCopy(Object? value) => switch (value) {
  final Map map => <String, dynamic>{
    for (final entry in map.entries)
      entry.key as String: _deepCopy(entry.value),
  },
  final List list => [for (final item in list) _deepCopy(item)],
  _ => value,
};

Map<String, dynamic> _copyRow(Map<String, dynamic> row) =>
    _deepCopy(row) as Map<String, dynamic>;

/// Scripted long stream over the internal transcript. Each event mutates the
/// rows the way production code paths do (replacement and in-place, shallow
/// and nested), then the memoized `messages` must equal a fresh projection.
final class _Script {
  _Script(this.random, this.chat);

  final Random random;
  final ActiveChat chat;
  var _nextId = 100000;
  final List<String> log = [];

  List<Map<String, dynamic>> get rows => chat.internalMessagesForTesting;

  int _randomIndex() => rows.isEmpty ? -1 : random.nextInt(rows.length);

  int _liveAssistant() => rows.indexWhere((row) => row['role'] == 'assistant');

  void _ensureLiveAssistant() {
    if (rows.isNotEmpty && rows.first['role'] == 'assistant') return;
    rows.insert(0, {'role': 'assistant', 'content': '', '_pipeline': true});
  }

  String _token() => const [
    'palabra ',
    'más ',
    '\n',
    '`code` ',
    '<think>',
    'oculto',
    '</think>',
    '<|channel|>analysis<|message|>',
    'priv',
    '<|end|>',
    'a < b ',
    '😀',
    '  ',
    'ñ',
    '1.',
    ' ',
  ][random.nextInt(16)];

  void step() {
    final kind = random.nextInt(26);
    log.add('$kind');
    switch (kind) {
      case 0 || 1 || 2 || 3:
        // Token flush: production replaces the head map.
        _ensureLiveAssistant();
        rows[0] = {
          ...rows[0],
          'content': '${rows[0]['content'] ?? ''}${_token()}',
          '_pipeline': false,
        };
      case 4:
        // Duplicate delta: the same text appended twice.
        _ensureLiveAssistant();
        final token = _token();
        rows[0] = {...rows[0], 'content': '${rows[0]['content']}$token'};
        rows[0] = {...rows[0], 'content': '${rows[0]['content']}$token'};
      case 5:
        // In-place content mutation of the same map (identity kept).
        _ensureLiveAssistant();
        final head = Map<String, dynamic>.of(rows[0]);
        rows[0] = head;
        head['content'] = '${head['content']}${_token()}';
      case 6:
        // Reasoning delta: activity trace and joined reasoning.
        _ensureLiveAssistant();
        final trace = [
          ...((rows[0][assistantActivityTraceKey] as List?) ?? const []),
        ];
        if (trace.isNotEmpty &&
            (trace.last as Map)['kind'] == 'reasoning' &&
            random.nextBool()) {
          final last = Map<String, dynamic>.from(trace.last as Map);
          last['text'] = '${last['text']}${_token()}';
          trace[trace.length - 1] = last;
        } else {
          // Production never opens a reasoning step with blank text
          // (`_appendAssistantReasoningActivity` drops it).
          trace.add({
            'kind': 'reasoning',
            'text': 'paso ${_nextId++} ${_token()}',
            'status': 'running',
            'timestamp': 1700000000000 + _nextId,
          });
        }
        rows[0] = {
          ...rows[0],
          'reasoning': trace
              .where((step) => (step as Map)['kind'] == 'reasoning')
              .map((step) => (step as Map)['text'].toString().trim())
              .join('\n\n'),
          assistantActivityTraceKey: trace,
        };
      case 7:
        // Nested in-place: a running tool step completes inside the SAME
        // trace list and step map. Deep in-place edits only happen during a
        // live turn; the idle cache relies on that (shallow fingerprint).
        if (!chat.isStreaming) return;
        final index = _liveAssistant();
        if (index < 0) return;
        var trace = rows[index][assistantActivityTraceKey];
        if (trace is! List || trace.isEmpty) {
          trace = <dynamic>[
            <String, dynamic>{
              'kind': 'tool',
              'label': 'terminal',
              'status': 'running',
              'id': 'tool-${_nextId++}',
            },
          ];
          rows[index] = {...rows[index], assistantActivityTraceKey: trace};
          return;
        }
        final step = trace[random.nextInt(trace.length)];
        if (step is Map) {
          try {
            step['status'] = step['status'] == 'running'
                ? 'completed'
                : 'running';
          } on UnsupportedError {
            // Unmodifiable fixture step: nothing to mutate in place.
          }
        }
      case 8:
        // Tool call row plus its result, behind the live assistant.
        final id = 'call-${_nextId++}';
        rows.insert(0, {
          'role': 'tool',
          'tool_call_id': id,
          'name': 'read_file',
          'content': 'resultado $id',
          'id': _nextId++,
        });
        rows.insert(0, {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': id,
              'type': 'function',
              'function': {'name': 'read_file', 'arguments': '{}'},
            },
          ],
        });
      case 9:
        // New user turn.
        rows.insert(0, {
          'role': 'user',
          'content': 'Pregunta ${_nextId++}',
          'message_id': 'u-$_nextId',
        });
      case 10:
        // Edit + rewind: a user row is rewritten and every newer row drops.
        final users = [
          for (var i = 0; i < rows.length; i++)
            if (rows[i]['role'] == 'user') i,
        ];
        if (users.isEmpty) return;
        final index = users[random.nextInt(users.length)];
        rows.removeRange(0, index);
        rows[0] = {...rows[0], 'content': 'Editado ${_nextId++}'};
      case 11:
        // Compression: older rows replaced by a summary carrier.
        if (rows.length < 6) return;
        final keep = random.nextInt(rows.length ~/ 2) + 1;
        final tail = rows.sublist(0, keep);
        rows
          ..clear()
          ..addAll(tail)
          ..add({
            'role': 'user',
            'display_kind': 'compression_result',
            'content': '[PRIOR CONTEXT — resumen]',
            'display_metadata': {
              'removed': 10,
              'before_messages': 20,
              'after_messages': 10,
              'before_tokens': 900,
              'after_tokens': 300,
              'noop': false,
            },
          });
      case 12:
        // Reconnect replay: every row arrives again as a fresh deep copy.
        final copies = rows.map(_copyRow).toList();
        rows
          ..clear()
          ..addAll(copies);
      case 13:
        // Replay of a slice in a different order (out-of-order rows).
        if (rows.length < 3) return;
        final a = random.nextInt(rows.length);
        final b = random.nextInt(rows.length);
        final swap = rows[a];
        rows[a] = rows[b];
        rows[b] = swap;
      case 14:
        // A private classifier lands on an older row in place.
        final index = _randomIndex();
        if (index < 0) return;
        try {
          rows[index]['hidden'] = true;
        } on UnsupportedError {
          rows[index] = {...rows[index], 'hidden': true};
        }
      case 15:
        // Durable privacy evidence for an older row (vetoes by identity).
        final index = _randomIndex();
        if (index < 0) return;
        final row = rows[index];
        final messageId = row['message_id'];
        if (messageId is! String) return;
        chat.reducePrivacyEvidenceForTesting([
          {'message_id': messageId, 'role': 'assistant', 'hidden': true},
        ]);
      case 16:
        // Pipeline state flips: streaming, idle, completed.
        chat.state = const [
          ChatPipelineState.streaming,
          ChatPipelineState.executing,
          ChatPipelineState.idle,
          ChatPipelineState.completed,
          ChatPipelineState.waiting,
        ][random.nextInt(5)];
      case 17:
        // Delegation: dispatched tool result arrives after its completion
        // marker (cross-row projection).
        rows.insert(random.nextInt(rows.length + 1), {
          'role': 'tool',
          'name': 'delegate_task',
          'content': jsonEncode({
            'status': 'dispatched',
            'delegation_id': 'deleg_0000beef',
            'subagent_ids': ['sa-${random.nextInt(3)}'],
          }),
        });
        if (random.nextBool()) {
          rows.insert(0, {
            'role': 'user',
            'content': '[ASYNC DELEGATION COMPLETE — deleg_0000beef]\nok',
          });
        }
      case 18:
        // Numeric presentation change with an equal value.
        final index = _randomIndex();
        if (index < 0) return;
        final timestamp = rows[index]['timestamp'];
        rows[index] = {
          ...rows[index],
          'timestamp': timestamp is int ? timestamp.toDouble() : 1700000000,
        };
      case 19:
        // Responses API sidecar replaced on an assistant row.
        final index = _liveAssistant();
        if (index < 0) return;
        rows[index] = {
          ...rows[index],
          'content': '',
          'codex_message_items': jsonEncode([
            {
              'type': 'message',
              'role': 'assistant',
              'phase': random.nextBool() ? 'commentary' : null,
              'content': [
                {'type': 'output_text', 'text': _token()},
              ],
            },
          ]),
        };
      case 20:
        // Local error row with a legacy partial.
        rows.insert(0, {
          'role': 'assistant_error',
          'content': 'Fallo ${_nextId++}',
          '_prompt': 'p',
          '_legacyRecoveryPartialProjection': {
            'role': 'assistant',
            'content': 'parcial',
          },
        });
      case 21:
        // Row removed from the middle.
        final index = _randomIndex();
        if (index < 0) return;
        rows.removeAt(index);
      case 22:
        // Generated image metadata attached to the live assistant.
        final index = _liveAssistant();
        if (index < 0) return;
        rows[index] = {
          ...rows[index],
          '_generated_images': [
            {
              'tool_call_id': 'img-${random.nextInt(3)}',
              'kind': 'server_cache',
              'basename': 'img_${random.nextInt(3)}.png',
            },
          ],
        };
      case 23:
        // Nested in-place change in a tool call list.
        final index = rows.indexWhere((row) => row['tool_calls'] is List);
        if (index < 0) return;
        final calls = rows[index]['tool_calls'] as List;
        try {
          calls.add({
            'id': 'extra-${_nextId++}',
            'type': 'function',
            'function': {'name': 'terminal'},
          });
        } on UnsupportedError {
          return;
        }
      case 24:
        // Steer correction row and model switch editorial row.
        rows.insert(0, {
          'role': 'user',
          'content': random.nextBool() ? 'corrige' : 'Model switched',
          'display_kind': random.nextBool() ? 'steer' : 'model_switch',
        });
      default:
        // Whole transcript replaced with a different session window.
        if (random.nextInt(4) != 0) return;
        final fresh = longStreamingTranscriptNewestFirst(
          turns: 2 + random.nextInt(4),
          answerChars: 80,
        );
        rows
          ..clear()
          ..addAll(fresh);
    }
  }
}

void main() {
  test('memoized messages equal a fresh full projection after every event', () {
    var events = 0;
    for (var seed = 0; seed < 40; seed++) {
      final service = ActiveChatService();
      addTearDown(service.dispose);
      final chat = _chat(service, '$seed');
      final random = Random(seed);
      chat.replaceInternalMessagesForTesting(
        longStreamingTranscriptNewestFirst(
          turns: 6 + random.nextInt(10),
          answerChars: 200,
        ),
      );
      chat.state = ChatPipelineState.streaming;
      final script = _Script(random, chat);
      List<Map<String, dynamic>>? previous;
      for (var step = 0; step < 250; step++) {
        script.step();
        events++;
        final reads = 1 + random.nextInt(3);
        for (var read = 0; read < reads; read++) {
          final memoized = chat.messages;
          final fresh = chat.uncachedPublicMessagesForTesting();
          if (!_samePublic(memoized, fresh)) {
            fail(
              'seed=$seed step=$step read=$read events=${script.log}\n'
              'memoized=$memoized\nfresh=$fresh',
            );
          }
          if (read > 0) {
            expect(identical(memoized, previous), isTrue);
          }
          previous = memoized;
        }
      }
    }
    expect(events, 40 * 250);
  });

  test('unchanged rows keep their public identity across streaming ticks', () {
    final service = ActiveChatService();
    addTearDown(service.dispose);
    final chat = _chat(service, 'identity');
    chat.replaceInternalMessagesForTesting([
      {'role': 'assistant', 'content': '', '_pipeline': true},
      ...longStreamingTranscriptNewestFirst(turns: 4, answerChars: 120),
    ]);
    chat.state = ChatPipelineState.streaming;
    final before = chat.messages;
    final rows = chat.internalMessagesForTesting;
    rows[0] = {...rows[0], 'content': 'Hola', '_pipeline': false};
    final after = chat.messages;
    expect(after.first['content'], 'Hola');
    expect(identical(after.first, before.first), isFalse);
    for (var i = 1; i < after.length; i++) {
      expect(identical(after[i], before[i]), isTrue, reason: 'row $i');
    }
  });

  test(
    'a private classifier injected into an older row mid-stream hides it',
    () {
      final service = ActiveChatService();
      addTearDown(service.dispose);
      final chat = _chat(service, 'veto');
      final older = <String, dynamic>{
        'role': 'assistant',
        'content': 'Respuesta antigua',
        'message_id': 'old',
      };
      chat.replaceInternalMessagesForTesting([
        {'role': 'assistant', 'content': 'vivo'},
        {'role': 'user', 'content': 'Pregunta'},
        older,
      ]);
      chat.state = ChatPipelineState.streaming;
      expect(
        chat.messages.map((row) => row['content']),
        contains('Respuesta antigua'),
      );
      older['channel'] = 'analysis';
      expect(
        chat.messages.map((row) => row['content']),
        isNot(contains('Respuesta antigua')),
      );
      older.remove('channel');
      chat.reducePrivacyEvidenceForTesting([
        {'message_id': 'old', 'role': 'assistant', 'hidden': true},
      ]);
      expect(
        chat.messages.map((row) => row['content']),
        isNot(contains('Respuesta antigua')),
      );
    },
  );

  test('a nested in-place edit of an older row is republished mid-stream', () {
    final service = ActiveChatService();
    addTearDown(service.dispose);
    final chat = _chat(service, 'nested');
    final step = <String, dynamic>{
      'kind': 'tool',
      'label': 'terminal',
      'status': 'running',
    };
    chat.replaceInternalMessagesForTesting([
      {'role': 'assistant', 'content': 'vivo'},
      {
        'role': 'assistant',
        'content': 'antes',
        assistantActivityTraceKey: [step],
      },
    ]);
    chat.state = ChatPipelineState.streaming;
    expect(
      (chat.messages.last[assistantActivityTraceKey] as List).single['status'],
      'running',
    );
    step['status'] = 'failed';
    expect(
      (chat.messages.last[assistantActivityTraceKey] as List).single['status'],
      'failed',
    );
  });

  test('a row whose public form is unchanged keeps its public identity', () {
    final service = ActiveChatService();
    addTearDown(service.dispose);
    final chat = _chat(service, 'retain');
    final older = <String, dynamic>{
      'role': 'assistant',
      'content': 'Respuesta',
      '_desktopRowId': 7,
    };
    chat.replaceInternalMessagesForTesting([
      {'role': 'assistant', 'content': 'vivo'},
      older,
    ]);
    chat.state = ChatPipelineState.streaming;
    final before = chat.messages.last;
    older['_desktopRowId'] = 8;
    // The live row changes in the same tick, so the list itself is new.
    final rows = chat.internalMessagesForTesting;
    rows[0] = {...rows[0], 'content': 'vivo más'};
    final after = chat.messages.last;
    expect(chat.messages.first['content'], 'vivo más');
    expect(after, before);
    expect(identical(after, before), isTrue);
  });

  group('row change detection', () {
    Object? randomValue(Random random, int depth) {
      switch (random.nextInt(depth > 2 ? 6 : 9)) {
        case 0:
          return null;
        case 1:
          return const ['a', 'b', '', 'content', 'role'][random.nextInt(5)];
        case 2:
          return random.nextInt(3);
        case 3:
          return const [0.0, -0.0, 1.0, 2.5][random.nextInt(4)];
        case 4:
          return random.nextBool();
        case 5:
          return 'texto ${random.nextInt(3)}';
        case 6 || 7:
          return <String, dynamic>{
            for (var i = 0; i < random.nextInt(4); i++)
              const ['a', 'b', 'c', 'content'][random.nextInt(4)]: randomValue(
                random,
                depth + 1,
              ),
          };
        default:
          return [
            for (var i = 0; i < random.nextInt(4); i++)
              randomValue(random, depth + 1),
          ];
      }
    }

    // Strict structural equality: same order, same runtime types.
    bool strictlyEqual(Object? a, Object? b) {
      if (a is Map && b is Map) {
        if (a.length != b.length) return false;
        final ak = a.keys.toList();
        final bk = b.keys.toList();
        for (var i = 0; i < ak.length; i++) {
          if (ak[i] != bk[i] || !strictlyEqual(a[ak[i]], b[bk[i]])) {
            return false;
          }
        }
        return true;
      }
      if (a is List && b is List) {
        if (a.length != b.length) return false;
        for (var i = 0; i < a.length; i++) {
          if (!strictlyEqual(a[i], b[i])) return false;
        }
        return true;
      }
      if (a is Map || b is Map || a is List || b is List) return false;
      if (a is double && b is double) {
        return a == b && a.isNegative == b.isNegative;
      }
      return a.runtimeType == b.runtimeType && a == b;
    }

    // Fresh copy with fresh string instances, so equal strings are not
    // identical.
    Object? freshCopy(Object? value) => switch (value) {
      final Map map => <String, dynamic>{
        for (final entry in map.entries)
          String.fromCharCodes((entry.key as String).codeUnits): freshCopy(
            entry.value,
          ),
      },
      final List list => [for (final item in list) freshCopy(item)],
      final String text => String.fromCharCodes(text.codeUnits),
      _ => value,
    };

    Map<String, dynamic> nearMiss(Random random, Map<String, dynamic> row) {
      // Walk to a random container and replace, add or drop one entry.
      Object? container = row;
      for (var depth = 0; depth < 3; depth++) {
        final children = switch (container) {
          final Map map => map.values.whereType<Object>().toList(),
          final List list => list.whereType<Object>().toList(),
          _ => const <Object>[],
        }.where((child) => child is Map || child is List).toList();
        if (children.isEmpty || random.nextBool()) break;
        container = children[random.nextInt(children.length)];
      }
      final value = randomValue(random, 2);
      if (container is Map) {
        final keys = container.keys.toList();
        if (keys.isNotEmpty && random.nextBool()) {
          final key = keys[random.nextInt(keys.length)];
          random.nextBool() ? container.remove(key) : container[key] = value;
        } else {
          container['n${random.nextInt(3)}'] = value;
        }
      } else if (container is List) {
        if (container.isNotEmpty && random.nextBool()) {
          random.nextBool()
              ? container.removeAt(random.nextInt(container.length))
              : container[random.nextInt(container.length)] = value;
        } else {
          container.add(value);
        }
      }
      return row;
    }

    test('matches exactly when the row is strictly equal', () {
      var equal = 0;
      var different = 0;
      for (var seed = 0; seed < 6000; seed++) {
        final random = Random(seed);
        final a = randomValue(random, 0);
        final row = a is Map<String, dynamic> ? a : {'v': a};
        final other = switch (random.nextInt(3)) {
          // Equal content, fresh instances.
          0 => freshCopy(row) as Map<String, dynamic>,
          // One leaf or container somewhere replaced: a near miss.
          1 => nearMiss(random, freshCopy(row) as Map<String, dynamic>),
          _ => <String, dynamic>{'v': randomValue(random, 1)},
        };
        final expected = strictlyEqual(other, row);
        expect(
          debugRowShapeMatches(other, row),
          expected,
          reason: 'recorded=$row current=$other',
        );
        expected ? equal++ : different++;
      }
      expect(equal, greaterThan(1000));
      expect(different, greaterThan(1000));
    });

    test('a value moved across nesting levels is a change', () {
      final recorded = <String, dynamic>{
        'x': {'a': 1, 'b': 1},
      };
      final moved = <String, dynamic>{
        'x': {'a': 1},
        'b': 1,
      };
      expect(debugRowShapeMatches(moved, recorded), isFalse);
      final listRecorded = <String, dynamic>{
        'x': [
          ['a'],
          'b',
        ],
      };
      final listMoved = <String, dynamic>{
        'x': [
          ['a', 'b'],
        ],
      };
      expect(debugRowShapeMatches(listMoved, listRecorded), isFalse);
      expect(debugRowShapeMatches({'x': 1}, {'x': 1, 'y': 2}), isFalse);
    });

    test('equal strings that are different instances still match', () {
      final recorded = <String, dynamic>{'content': 'hola mundo'};
      final copy = <String, dynamic>{
        'content': String.fromCharCodes('hola mundo'.codeUnits),
      };
      expect(debugRowShapeMatches(copy, recorded), isTrue);
    });
  });
}
