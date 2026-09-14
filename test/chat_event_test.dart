import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';

void expectFailClosedToolCarrier(
  ChatEventInfo event,
  List<String> sentinels, {
  required String reason,
}) {
  expect(event.kind, ChatEventKind.toolEvent, reason: reason);
  expect(event.command, isNull, reason: reason);
  expect(event.description, isNull, reason: reason);
  expect(event.output, isNull, reason: reason);
  expect(event.exitCode, isNull, reason: reason);
  expect(event.runId, isNull, reason: reason);
  expect(event.patternKey, isNull, reason: reason);
  expect(event.text, isEmpty, reason: reason);

  final publicProjection = <Object?>[
    event.command,
    event.description,
    event.output,
    event.exitCode,
    event.runId,
    event.patternKey,
    event.text,
    event.toString(),
  ].join('\n');
  for (final sentinel in sentinels) {
    expect(publicProjection, isNot(contains(sentinel)), reason: reason);
  }
}

void main() {
  group('ChatEventInfo.classify', () {
    test('pending_approval JSON NO se trata como texto de chat', () {
      final msg = {
        'role': 'assistant',
        'content': jsonEncode({
          'command': 'rm -rf /var/data',
          'description': 'Borrar datos antiguos',
          'approval_pending': true,
          'pattern_key': 'fs.delete',
          'status': 'pending_approval',
          'run_id': 'run_123',
        }),
      };
      final ev = ChatEventInfo.classify(msg);
      expect(ev.kind, ChatEventKind.approval);
      expect(ev.approvalPending, isTrue);
      expect(ev.command, isNull);
      expect(ev.runId, isNull);
      expect(ev.text, isEmpty);
    });

    test('delegate_task nunca proyecta argumentos internos como comando', () {
      final event = ChatEventInfo.classify({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call-private-delegation',
            'function': {
              'name': 'delegate_task',
              'arguments': jsonEncode({
                'goal': 'PRIVATE_DELEGATE_GOAL',
                'context': 'PRIVATE_DELEGATE_CONTEXT',
              }),
            },
          },
        ],
      });

      expect(event.kind, ChatEventKind.toolEvent);
      expect(event.description, isNull);
      expect(event.command, isNull);
      expect(event.toString(), isNot(contains('PRIVATE_DELEGATE_GOAL')));
      expect(event.toString(), isNot(contains('PRIVATE_DELEGATE_CONTEXT')));
    });

    test('clasificación fail-closed no expone argumentos ni resultados', () {
      const marker = 'PRIVATE_TOOL_RESULT_/home/owner/session.jsonl';
      final invocation = ChatEventInfo.classify({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call-private',
            'function': {'name': 'shell', 'arguments': '{"command":"$marker"}'},
          },
        ],
      });
      final result = ChatEventInfo.classify({
        'role': 'tool',
        'tool_name': marker,
        'command': marker,
        'content': '{"output":"$marker","exit_code":0}',
      });
      final invalid = ChatEventInfo.classify({
        'content': marker,
        'trace': marker,
      });

      for (final event in [invocation, result, invalid]) {
        expect(event.toString(), isNot(contains(marker)));
        expect(event.command, isNull);
        expect(event.output, isNull);
        expect(event.text, isNot(contains(marker)));
      }
    });

    final adversarialToolCarriers =
        <({String name, Map<String, dynamic> message, List<String> sentinels})>[
          (
            name: 'texto plano sin patrones',
            message: {'role': 'tool', 'content': 'PRIVATE_UNPATTERNED_q7V4z'},
            sentinels: ['PRIVATE_UNPATTERNED_q7V4z'],
          ),
          (
            name: 'JSON con secreto y path privado',
            message: {
              'role': 'tool_result',
              'content': jsonEncode({
                'output': 'sk-private-A91 /home/owner/session.jsonl',
                'exit_code': 0,
              }),
            },
            sentinels: ['sk-private-A91', '/home/owner/session.jsonl'],
          ),
          (
            name: 'Map con secreto sin marcador reconocible',
            message: {
              'role': 'tool_use',
              'content': {
                'output': 'mango-river-velvet-2049',
                'path': '/srv/opaque/customer-17.bin',
              },
            },
            sentinels: [
              'mango-river-velvet-2049',
              '/srv/opaque/customer-17.bin',
            ],
          ),
          (
            name: 'JSON con sufijo',
            message: {
              'role': 'function',
              'content': '{"output":"PRIVATE_JSON_SUFFIX"}\n\nPRIVATE_LOOP_LOG',
            },
            sentinels: ['PRIVATE_JSON_SUFFIX', 'PRIVATE_LOOP_LOG'],
          ),
          (
            name: 'reasoning y logs en output y argumentos',
            message: {
              'role': 'function_call',
              'arguments': {
                'query': 'PRIVATE_ARGUMENT_QUERY',
                'reasoning': 'PRIVATE_ARGUMENT_REASONING',
              },
              'content': jsonEncode({
                'output': 'PRIVATE_OUTPUT_REASONING',
                'logs': ['PRIVATE_INTERNAL_LOG'],
              }),
            },
            sentinels: [
              'PRIVATE_ARGUMENT_QUERY',
              'PRIVATE_ARGUMENT_REASONING',
              'PRIVATE_OUTPUT_REASONING',
              'PRIVATE_INTERNAL_LOG',
            ],
          ),
          (
            name: 'Harmony ASCII',
            message: {
              'role': 'tool_call',
              'content':
                  '<\x7Cchannel\x7C>analysis<\x7Cmessage\x7C>'
                  'PRIVATE_HARMONY_ASCII<\x7Cend\x7C>',
            },
            sentinels: ['PRIVATE_HARMONY_ASCII'],
          ),
          (
            name: 'Harmony fullwidth',
            message: {
              'role': 'tool',
              'content':
                  '＜｜channel｜＞analysis＜｜message｜＞PRIVATE_HARMONY_FULLWIDTH',
            },
            sentinels: ['PRIVATE_HARMONY_FULLWIDTH'],
          ),
          (
            name: 'Harmony incompleto',
            message: {
              'role': 'tool',
              'content':
                  '<|channel|>analysis<|message|PRIVATE_HARMONY_INCOMPLETE',
            },
            sentinels: ['PRIVATE_HARMONY_INCOMPLETE'],
          ),
          (
            name: 'Harmony fragmentado dentro del carrier',
            message: {
              'role': 'tool',
              'content': jsonEncode({
                'chunks': [
                  '<|chan',
                  'nel|>analysis<|mes',
                  'sage|>PRIVATE_HARMONY_FRAGMENTED',
                ],
              }),
            },
            sentinels: ['PRIVATE_HARMONY_FRAGMENTED'],
          ),
          (
            name: 'delegate_task anidado',
            message: {
              'role': 'tool',
              'tool_name': 'delegate_task',
              'content': jsonEncode({
                'id': 'PRIVATE_DELEGATE_ID',
                'goal': 'PRIVATE_DELEGATE_GOAL_NESTED',
                'context': 'PRIVATE_DELEGATE_CONTEXT_NESTED',
                'result': {
                  'text': 'PRIVATE_DELEGATE_RESULT',
                  'children': [
                    {
                      'id': 'PRIVATE_CHILD_ID',
                      'path': '/private/delegate/path',
                    },
                  ],
                },
              }),
            },
            sentinels: [
              'PRIVATE_DELEGATE_ID',
              'PRIVATE_DELEGATE_GOAL_NESTED',
              'PRIVATE_DELEGATE_CONTEXT_NESTED',
              'PRIVATE_DELEGATE_RESULT',
              'PRIVATE_CHILD_ID',
              '/private/delegate/path',
            ],
          ),
          (
            name: 'exit cero y etiquetas safe public hostiles',
            message: {
              'role': 'tool',
              'safe': true,
              'public': true,
              'command': 'PRIVATE_SAFE_COMMAND',
              'description': 'PRIVATE_SAFE_DESCRIPTION',
              'output': 'PRIVATE_SAFE_TOP_LEVEL_OUTPUT',
              'exit_code': 0,
              'run_id': 'PRIVATE_SAFE_RUN_ID',
              'pattern_key': 'PRIVATE_SAFE_PATTERN_KEY',
              'content': jsonEncode({
                'safe': true,
                'public': true,
                'exit_code': 0,
                'output': 'PRIVATE_SAFE_CONTENT',
              }),
            },
            sentinels: [
              'PRIVATE_SAFE_COMMAND',
              'PRIVATE_SAFE_DESCRIPTION',
              'PRIVATE_SAFE_TOP_LEVEL_OUTPUT',
              'PRIVATE_SAFE_RUN_ID',
              'PRIVATE_SAFE_PATTERN_KEY',
              'PRIVATE_SAFE_CONTENT',
            ],
          ),
          (
            name: 'payload largo conserva privados inicio y final',
            message: {
              'role': 'tool',
              'content':
                  'PRIVATE_LONG_BEGIN_${List.filled(4096, 'x').join()}_PRIVATE_LONG_END',
            },
            sentinels: ['PRIVATE_LONG_BEGIN', 'PRIVATE_LONG_END'],
          ),
        ];

    for (final fixture in adversarialToolCarriers) {
      test('carrier tool fail-closed: ${fixture.name}', () {
        final event = ChatEventInfo.classify(fixture.message);
        expectFailClosedToolCarrier(
          event,
          fixture.sentinels,
          reason: fixture.name,
        );
      });
    }

    for (final role in const [
      'tool',
      'tool_result',
      'tool_use',
      'function',
      'function_call',
      'tool_call',
    ]) {
      test('rol tool admitido $role permanece fail-closed', () {
        final sentinel = 'PRIVATE_ROLE_${role.toUpperCase()}';
        final event = ChatEventInfo.classify({
          'role': role,
          'content': sentinel,
        });
        expectFailClosedToolCarrier(event, [sentinel], reason: role);
      });
    }

    test('salida de herramienta con exit_code → toolEvent, no burbuja', () {
      final msg = {
        'role': 'tool',
        'content': jsonEncode({
          'command': 'ls -la',
          'output': 'total 0\ndrwxr-xr-x ...',
          'exit_code': 0,
          'status': 'completed',
        }),
      };
      final ev = ChatEventInfo.classify(msg);
      expect(ev.kind, ChatEventKind.toolEvent);
      expect(ev.exitCode, isNull);
      expect(ev.output, isNull);
      expect(ev.text, isEmpty);
    });

    test('content como Map (no string) también se estructura', () {
      final msg = {
        'role': 'assistant',
        'content': {'command': 'systemctl restart nginx', 'exit_code': 1},
      };
      final ev = ChatEventInfo.classify(msg);
      expect(ev.kind, ChatEventKind.toolEvent);
      expect(ev.exitCode, isNull);
      expect(ev.text, isEmpty);
    });

    test('respuesta normal del asistente se mantiene como texto', () {
      final msg = {
        'role': 'assistant',
        'content': 'Claro, aquí tienes el resumen que pediste.',
      };
      final ev = ChatEventInfo.classify(msg);
      expect(ev.kind, ChatEventKind.text);
      expect(ev.text, contains('resumen'));
    });

    test('markdown con bloque de código NO se confunde con payload', () {
      final msg = {
        'role': 'assistant',
        'content': 'Ejecuta esto:\n```\nrm -rf build\n```\nY listo.',
      };
      final ev = ChatEventInfo.classify(msg);
      expect(ev.kind, ChatEventKind.text);
    });

    test(
      'JSON bare sin claves internas se trata como texto (sin falsos positivos)',
      () {
        final msg = {
          'role': 'assistant',
          'content': jsonEncode({'foo': 'bar', 'n': 1}),
        };
        final ev = ChatEventInfo.classify(msg);
        expect(ev.kind, ChatEventKind.text);
      },
    );

    test('mensaje de usuario nunca se estructura aunque parezca payload', () {
      // El llamador (chat) ya excluye role==user; aquí validamos que el rol
      // tool es la otra vía y que un user con JSON simple cae en texto.
      final msg = {'role': 'user', 'content': 'mi comando favorito es ls'};
      final ev = ChatEventInfo.classify(msg);
      expect(ev.kind, ChatEventKind.text);
    });
  });

  group('traceOutcome (TASK-017: errores de tool recuperados)', () {
    ChatTraceEvent ev(String status) =>
        ChatTraceEvent(id: status, label: status, status: status);

    test('run activo → working (sin importar fallos intermedios)', () {
      expect(
        traceOutcome(events: [ev('failed'), ev('running')], active: true),
        TraceOutcome.working,
      );
    });

    test('sin fallos y terminado → completed', () {
      expect(
        traceOutcome(events: [ev('completed'), ev('finished')], active: false),
        TraceOutcome.completed,
      );
    });

    test('failed + completed (terminado) → recovered, NO error crítico', () {
      expect(
        traceOutcome(events: [ev('failed'), ev('completed')], active: false),
        TraceOutcome.recovered,
      );
    });

    test('solo fallos y terminado → failed (error real)', () {
      expect(
        traceOutcome(events: [ev('failed'), ev('error')], active: false),
        TraceOutcome.failed,
      );
    });

    test('sin eventos y terminado → completed', () {
      expect(traceOutcome(events: [], active: false), TraceOutcome.completed);
    });
  });
}
