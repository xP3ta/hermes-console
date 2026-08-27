import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';

void main() {
  const reconciler = DesktopSessionReconciler();

  DesktopSessionSnapshot snapshot(
    Map<String, dynamic> json, {
    String stored = 'stored-1',
  }) => DesktopSessionSnapshot.fromJson(
    json,
    requestedStoredSessionId: stored,
    created: false,
    method: 'session.resume',
  );

  test('proyecta transcript autoritativo en orden newest-first', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-1',
        'session_key': 'stored-1',
        'messages': [
          {'role': 'user', 'text': 'pregunta', 'row_id': 73},
          {'role': 'assistant', 'text': 'respuesta'},
          {'role': 'tool', 'name': 'web_search', 'context': 'consulta'},
        ],
        'running': false,
        'status': 'idle',
      }),
    );

    expect(result.messagesNewestFirst.map((message) => message['role']), [
      'tool',
      'assistant',
      'user',
    ]);
    expect(result.messagesNewestFirst.first['content'], 'consulta');
    expect(
      result.messagesNewestFirst.last['_desktopSnapshotKey'],
      'message-runtime-1-0',
    );
    expect(result.messagesNewestFirst.last['_desktopRowId'], 73);
    expect(result.running, isFalse);
    expect(result.status, 'idle');
  });

  test(
    'conserva identidad y ordinal del mensaje para saltos de artefactos',
    () {
      final result = reconciler.project(
        snapshot({
          'session_id': 'runtime-artifact',
          'session_key': 'stored-1',
          'messages': [
            {
              'role': 'assistant',
              'message_id': 'message-artifact-1',
              'content': 'resultado',
            },
          ],
        }),
      );

      expect(
        result.messagesNewestFirst.single['_desktopMessageId'],
        'message-artifact-1',
      );
      expect(result.messagesNewestFirst.single['_desktopMessageOrdinal'], 0);
    },
  );

  test('conserva display_kind para distinguir metadatos de un turno real', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-model-switch',
        'session_key': 'stored-1',
        'messages': [
          {
            'role': 'user',
            'content':
                '[System: The active model for this chat has changed to k3.]',
            'display_kind': 'model_switch',
          },
        ],
      }),
    );

    expect(result.messagesNewestFirst.single['display_kind'], 'model_switch');
  });

  test('sanea display_metadata de delegación en mapa o JSON legacy', () {
    DesktopSessionProjection project(Object metadata) => reconciler.project(
      snapshot({
        'session_id': 'runtime-delegation',
        'session_key': 'stored-1',
        'messages': [
          {
            'role': 'user',
            'content': '[ASYNC DELEGATION BATCH COMPLETE — interno]',
            'display_kind': 'async_delegation_complete',
            'display_metadata': metadata,
          },
        ],
      }),
    );

    final mapped =
        project({
              'task_count': 4,
              'completed_count': 3,
              'failed_count': 1,
              'duration_seconds': 42.5,
              'secret_path': '/home/demo-user/internal',
            }).messagesNewestFirst.single['display_metadata']
            as Map<String, dynamic>;
    expect(mapped, {
      'task_count': 4,
      'completed_count': 3,
      'failed_count': 1,
      'duration_seconds': 42.5,
    });

    final legacy =
        project(
              '{"task_count":2,"failed_count":0,"unknown":"drop"}',
            ).messagesNewestFirst.single['display_metadata']
            as Map<String, dynamic>;
    expect(legacy, {'task_count': 2, 'failed_count': 0});
  });

  test('superpone metadata de resume sobre la fila REST exacta', () {
    const raw = '[ASYNC DELEGATION BATCH COMPLETE — deleg_exact]';
    final persisted = DesktopSessionMessage.tryParse({
      'role': 'user',
      'content': raw,
      'display_kind': 'async_delegation_complete',
      'display_metadata': {
        'task_count': 1,
        'duration_seconds': 12,
        'private': '/home/demo-user',
      },
    })!;
    final rest = <Map<String, dynamic>>[
      {'role': 'assistant', 'content': 'Hecho'},
      {'role': 'user', 'content': raw},
    ];

    final merged = reconciler.overlayDurableDisplayMetadata(rest, [persisted]);

    expect(merged.first, same(rest.first));
    expect(merged.last['display_kind'], 'async_delegation_complete');
    expect(merged.last['display_metadata'], {
      'task_count': 1,
      'duration_seconds': 12,
    });
  });

  test('el contenido estructurado conserva enlaces y URLs de fuentes', () {
    const url = 'https://www.elmundo.es/noticia.html';
    final text = desktopSessionDisplayText(const [
      {'type': 'output_text', 'text': '[Fuente: El Mundo]($url)'},
      {'type': 'output_text', 'text': '\n$url'},
    ]);

    expect(text, '[Fuente: El Mundo]($url)\n$url');
  });

  test(
    'ordinal conserva el índice servidor aunque descarte filas inválidas',
    () {
      final result = reconciler.project(
        snapshot({
          'session_id': 'runtime-invalid-row',
          'session_key': 'stored-1',
          'messages': [
            {'content': 'sin rol'},
            {
              'role': 'assistant',
              'message_id': 'message-after-invalid',
              'content': 'visible',
            },
          ],
        }),
      );

      expect(result.messagesNewestFirst.single['_desktopMessageOrdinal'], 1);
    },
  );

  test('rehidrata inflight y conserva queued como un único prompt', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-live',
        'session_key': 'stored-1',
        'messages': [
          {'role': 'user', 'text': 'anterior'},
          {'role': 'assistant', 'text': 'hecho'},
        ],
        'inflight': {
          'user': 'turno actual',
          'assistant': 'respuesta parcial',
          'streaming': true,
        },
        'queued': {'user': 'primero\n\nsegundo'},
        'running': true,
      }),
    );

    expect(result.running, isTrue);
    expect(result.messagesNewestFirst.first['role'], 'assistant');
    expect(result.messagesNewestFirst.first['content'], 'respuesta parcial');
    expect(result.messagesNewestFirst[1]['content'], 'turno actual');
    expect(result.queuedUser, 'primero\n\nsegundo');
    expect(result.queuedSyntheticId, 'user-queued-runtime-live');
  });

  test('proyecta inflight fallido como error terminal recuperable', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-failed',
        'session_key': 'stored-1',
        'inflight': {
          'user': 'haz la tarea',
          'assistant': '',
          'streaming': false,
          'error': 'model call failed: 500',
          'status': 'error',
          'recoverable': true,
        },
        'running': false,
        'status': 'idle',
      }),
    );

    expect(result.running, isFalse);
    expect(result.failed, isTrue);
    expect(result.status, 'error');
    expect(result.messagesNewestFirst, hasLength(2));
    expect(result.messagesNewestFirst.first, {
      'role': 'assistant_error',
      'content': 'model call failed: 500',
      '_prompt': 'haz la tarea',
      'error': 'model call failed: 500',
      'partial': false,
      'recoverable': true,
      '_desktopSnapshotKey': 'assistant-error-runtime-failed',
      '_desktopSnapshotKind': 'inflight',
    });
    expect(result.messagesNewestFirst.last['role'], 'user');
  });

  test('inflight fallido conserva el parcial como interrumpido', () {
    final source = snapshot({
      'session_id': 'runtime-failed-partial',
      'session_key': 'stored-1',
      'inflight': {
        'user': 'haz la tarea',
        'assistant': 'respuesta parcial',
        'streaming': false,
        'error': 'connection reset',
        'status': 'error',
        'recoverable': true,
      },
      'running': false,
    });

    final first = reconciler.project(source);
    final second = reconciler.project(
      source,
      fallbackNewestFirst: first.messagesNewestFirst,
    );

    expect(first.messagesNewestFirst, hasLength(3));
    expect(first.messagesNewestFirst[0]['role'], 'assistant_error');
    expect(first.messagesNewestFirst[0]['partial'], isTrue);
    expect(first.messagesNewestFirst[1], containsPair('role', 'assistant'));
    expect(
      first.messagesNewestFirst[1],
      containsPair('content', 'respuesta parcial'),
    );
    expect(first.messagesNewestFirst[1]['_cancelled'], isTrue);
    expect(first.messagesNewestFirst[1]['_pipeline'], isFalse);
    expect(second.messagesNewestFirst, first.messagesNewestFirst);
  });

  test('proyecta prompt, correcciones y assistant en orden cronológico', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-corrections',
        'session_key': 'stored-1',
        'inflight': {
          'user': 'haz la auditoría',
          'corrections': ['y documéntala', 'incluye ejemplos'],
          'assistant': 'trabajando',
          'streaming': true,
        },
        'running': true,
      }),
    );

    final chronological = result.messagesNewestFirst.reversed.toList();
    expect(chronological.map((message) => message['content']), [
      'haz la auditoría',
      'y documéntala',
      'incluye ejemplos',
      'trabajando',
    ]);
    expect(
      chronological
          .where((message) => message['_steer'] == true)
          .map((message) => message['_desktopSnapshotKey']),
      [
        'user-inflight-correction-0-runtime-corrections',
        'user-inflight-correction-1-runtime-corrections',
      ],
    );
  });

  test('deduplica solo contra el último bloque user del turno vivo', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-latest-user-run',
        'session_key': 'stored-1',
        'messages': [
          {'role': 'user', 'text': 'repetida'},
          {'role': 'assistant', 'text': 'respuesta anterior'},
          {'role': 'user', 'text': 'turno actual'},
          {'role': 'user', 'text': 'ya persistida'},
        ],
        'inflight': {
          'user': 'turno actual',
          'corrections': ['ya persistida', 'repetida'],
          'assistant': 'parcial',
          'streaming': true,
        },
        'running': true,
      }),
    );

    final chronological = result.messagesNewestFirst.reversed.toList();
    expect(chronological.map((message) => message['content']), [
      'repetida',
      'respuesta anterior',
      'turno actual',
      'ya persistida',
      'repetida',
      'parcial',
    ]);
    expect(
      chronological
          .where((message) => message['_steer'] == true)
          .map((message) => message['content']),
      ['ya persistida', 'repetida'],
    );
  });

  test('deduplica el bloque user aunque exista una cola viva detrás', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-live-tail',
        'session_key': 'stored-1',
        'messages': [
          {'role': 'user', 'text': 'turno actual'},
          {'role': 'user', 'text': 'corrección persistida'},
          {'role': 'tool', 'name': 'web_search', 'context': 'en curso'},
        ],
        'inflight': {
          'user': 'turno actual',
          'corrections': ['corrección persistida'],
          'assistant': 'parcial',
          'streaming': true,
        },
        'running': true,
      }),
    );

    final userMessages = result.messagesNewestFirst.reversed
        .where((message) => message['role'] == 'user')
        .toList(growable: false);
    expect(userMessages.map((message) => message['content']), [
      'turno actual',
      'corrección persistida',
    ]);
    expect(userMessages.where((message) => message['_steer'] == true), [
      userMessages.last,
    ]);
  });

  test('dos hidrataciones consecutivas conservan la misma proyección', () {
    final source = snapshot({
      'session_id': 'runtime-idempotent',
      'session_key': 'stored-1',
      'inflight': {
        'user': 'turno actual',
        'corrections': ['corrección'],
        'assistant': 'parcial',
        'streaming': true,
      },
      'running': true,
    });

    final first = reconciler.project(source);
    final second = reconciler.project(
      source,
      fallbackNewestFirst: first.messagesNewestFirst,
    );

    expect(second.messagesNewestFirst, first.messagesNewestFirst);
  });

  test('no duplica el user inflight ya presente al final del transcript', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-dedup',
        'session_key': 'stored-1',
        'messages': [
          {'role': 'user', 'text': 'mismo turno'},
        ],
        'inflight': {'user': 'mismo turno', 'assistant': '', 'streaming': true},
        'running': true,
      }),
    );

    expect(
      result.messagesNewestFirst
          .where((message) => message['role'] == 'user')
          .map((message) => message['content']),
      ['mismo turno'],
    );
  });

  test('preserva fallback si messages es malformado o ausente', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-fallback',
        'session_key': 'stored-1',
        'messages': 'malformed',
      }),
      fallbackNewestFirst: const [
        {'role': 'assistant', 'content': 'no borrar'},
        {'role': 'user', 'content': 'pregunta'},
      ],
    );

    expect(result.messagesNewestFirst, hasLength(2));
    expect(result.messagesNewestFirst.first['content'], 'no borrar');
  });

  test('ids sintéticos son estables para la misma runtime y revisión', () {
    final source = snapshot({
      'session_id': 'runtime-stable',
      'session_key': 'stored-1',
      'messages': [
        {'role': 'user', 'text': 'hola'},
      ],
      'inflight': {'user': 'actual', 'assistant': 'parcial'},
      'queued': {'user': 'después'},
      'running': true,
    });

    final first = reconciler.project(source);
    final second = reconciler.project(source);

    expect(
      first.messagesNewestFirst
          .map((message) => message['_desktopSnapshotKey'])
          .toList(),
      second.messagesNewestFirst
          .map((message) => message['_desktopSnapshotKey'])
          .toList(),
    );
    expect(first.queuedSyntheticId, second.queuedSyntheticId);
  });

  test('la proyección no retiene system_prompt ni raw de sesión', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-private',
        'session_key': 'stored-1',
        'messages': [
          {'role': 'assistant', 'text': 'visible'},
        ],
        'info': {'system_prompt': 'no retener'},
        'unknown_prompt_payload': 'tampoco',
      }),
    );

    expect(result.messagesNewestFirst.single['content'], 'visible');
    expect(
      result.messagesNewestFirst.single.toString(),
      isNot(contains('no retener')),
    );
    expect(
      result.messagesNewestFirst.single.toString(),
      isNot(contains('tampoco')),
    );
  });

  group('bloques estructurados estilo Anthropic', () {
    test(
      'thinking y tool_use dentro de content se proyectan, no se descartan',
      () {
        final result = reconciler.project(
          snapshot({
            'session_id': 'runtime-anthropic',
            'session_key': 'stored-1',
            'messages': [
              {'role': 'user', 'text': 'lista los ficheros'},
              {
                'role': 'assistant',
                'content': [
                  {'type': 'thinking', 'thinking': 'uso el shell'},
                  {
                    'type': 'tool_use',
                    'id': 'toolu-1',
                    'name': 'exec',
                    'input': {'command': 'ls -la'},
                  },
                  {'type': 'text', 'text': 'Voy a listarlos.'},
                ],
              },
            ],
          }),
        );

        final assistant = result.messagesNewestFirst.firstWhere(
          (message) => message['role'] == 'assistant',
        );
        expect(assistant['content'], 'Voy a listarlos.');
        expect(assistant['reasoning'], 'uso el shell');
        final toolCalls = assistant['tool_calls'] as List;
        expect(toolCalls, hasLength(1));
        final fn = (toolCalls.single as Map)['function'] as Map;
        expect(fn['name'], 'exec');
        expect(fn['arguments'], contains('ls -la'));
      },
    );

    test(
      'un user formado solo por tool_result se proyecta como mensaje tool',
      () {
        final result = reconciler.project(
          snapshot({
            'session_id': 'runtime-tool-result',
            'session_key': 'stored-1',
            'messages': [
              {
                'role': 'assistant',
                'content': [
                  {
                    'type': 'tool_use',
                    'id': 'toolu-1',
                    'name': 'exec',
                    'input': {'command': 'ls'},
                  },
                ],
              },
              {
                'role': 'user',
                'content': [
                  {
                    'type': 'tool_result',
                    'tool_use_id': 'toolu-1',
                    'name': 'exec',
                    'content': [
                      {'type': 'text', 'text': 'fichero.txt'},
                    ],
                  },
                ],
              },
            ],
          }),
        );

        final roles = result.messagesNewestFirst
            .map((message) => message['role'])
            .toList();
        expect(roles, ['tool', 'assistant']);
        expect(result.messagesNewestFirst.first['content'], 'fichero.txt');
        expect(result.messagesNewestFirst.first['tool_call_id'], 'toolu-1');
        // Sin burbuja de usuario vacía: el turno no era un prompt real.
        expect(roles, isNot(contains('user')));
      },
    );

    test('redacted_thinking conserva la señal aunque no haya texto', () {
      final result = reconciler.project(
        snapshot({
          'session_id': 'runtime-redacted',
          'session_key': 'stored-1',
          'messages': [
            {
              'role': 'assistant',
              'content': [
                {'type': 'redacted_thinking', 'data': 'cifrado'},
                {'type': 'text', 'text': 'Respuesta.'},
              ],
            },
          ],
        }),
      );

      final assistant = result.messagesNewestFirst.single;
      expect(assistant['reasoning'], '(razonamiento redactado)');
      expect(assistant['content'], 'Respuesta.');
    });

    test('una imagen estructurada deja marcador en vez de perderse', () {
      final result = reconciler.project(
        snapshot({
          'session_id': 'runtime-image',
          'session_key': 'stored-1',
          'messages': [
            {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'Aquí está:'},
                {
                  'type': 'image',
                  'source': {'type': 'base64', 'data': 'AAAA'},
                },
              ],
            },
          ],
        }),
      );

      final content = result.messagesNewestFirst.single['content'] as String;
      expect(content, contains('Aquí está:'));
      expect(content, contains('imagen'));
    });
  });
}
