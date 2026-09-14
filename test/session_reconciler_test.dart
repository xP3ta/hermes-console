import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_render_projection.dart';
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

  test('resume conserva el carrier durable pero no lo materializa en chat', () {
    const raw =
        '[IMPORTANT: Background process proc_0b5fab8a4839 exited (exit code 1).\n'
        'Command: claude -p private\n'
        'Output:\n'
        '/home/private output\n'
        ']';
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-background-carrier',
        'session_key': 'stored-1',
        'messages': const [
          {
            'role': 'user',
            'content': raw,
            'row_id': 9004,
            'message_id': 'background-carrier',
          },
        ],
      }),
    );

    expect(result.messagesNewestFirst.single['content'], raw);
    expect(result.messagesNewestFirst.single['_desktopRowId'], 9004);
    final projection = ChatRenderProjection.build(result.messagesNewestFirst);
    expect(projection.units, isEmpty);
    expect(projection.visibleUserCount, 0);
  });

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
      'assistant',
      'user',
    ]);
    expect(result.messagesNewestFirst.first['content'], 'respuesta');
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

  test('display_metadata subagent_ids usa allowlist atómica', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-delegation-ids',
        'session_key': 'stored-1',
        'messages': [
          {
            'role': 'user',
            'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_safeids]',
            'display_kind': 'async_delegation_complete',
            'display_metadata': {
              'delegation_id': 'deleg_safeids',
              'task_count': 2,
              'completed_count': 1,
              'failed_count': 1,
              'duration_seconds': 8.5,
              'subagent_ids': ['sa-safe-one', 'sa-safe-two'],
              'goal': 'private delegated prompt',
              'status': 'running',
              'model': 'private-model',
              'private_path': '/home/private/internal',
            },
          },
        ],
      }),
    );

    expect(result.messagesNewestFirst.single['display_metadata'], {
      'task_count': 2,
      'completed_count': 1,
      'failed_count': 1,
      'duration_seconds': 8.5,
      'delegation_id': 'deleg_safeids',
      'subagent_ids': ['sa-safe-one', 'sa-safe-two'],
    });
  });

  test('superpone metadata de resume sobre la fila REST exacta', () {
    const raw = '[ASYNC DELEGATION BATCH COMPLETE — deleg_exact]';
    final persisted = DesktopSessionMessage.tryParse({
      'message_id': 'deleg-exact-id',
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
      {'message_id': 'deleg-exact-id', 'role': 'user', 'content': raw},
    ];

    final merged = reconciler.overlayDurableDisplayMetadata(rest, [persisted]);

    expect(merged.first, same(rest.first));
    expect(merged.last['display_kind'], 'async_delegation_complete');
    expect(merged.last['display_metadata'], {
      'task_count': 1,
      'duration_seconds': 12,
    });
  });

  test(
    'veto privado por identidad elimina solo la fila fallback coincidente',
    () {
      final private = DesktopSessionMessage.tryParse(const {
        'row_id': 2,
        'role': 'assistant',
        'content': 'PRIVATE_REVOKED',
        'hidden': true,
      })!;
      final rest = <Map<String, dynamic>>[
        {'id': 3, 'role': 'assistant', 'content': 'PUBLIC_AFTER'},
        {'id': 2, 'role': 'assistant', 'content': 'PRIVATE_REVOKED'},
        {'id': 1, 'role': 'user', 'content': 'PUBLIC_BEFORE'},
        {'role': 'assistant', 'content': 'PUBLIC_IDLESS_FALLBACK'},
      ];

      final merged = reconciler.overlayDurableDisplayMetadata(rest, [private]);

      expect(merged.map((message) => message['content']), [
        'PUBLIC_AFTER',
        'PUBLIC_BEFORE',
        'PUBLIC_IDLESS_FALLBACK',
      ]);
    },
  );

  test('veto privado elimina todos los duplicados fallback exactos', () {
    final private = DesktopSessionMessage.tryParse(const {
      'row_id': 2,
      'role': 'assistant',
      'content': 'PRIVATE_REVOKED',
      'hidden': true,
    })!;
    final rest = <Map<String, dynamic>>[
      {'id': 2, 'role': 'assistant', 'content': 'PRIVATE_REVOKED'},
      {'id': 2, 'role': 'assistant', 'content': 'PRIVATE_REVOKED'},
      {'id': 1, 'role': 'user', 'content': 'PUBLIC_NEIGHBOR'},
    ];

    final merged = reconciler.overlayDurableDisplayMetadata(rest, [private]);

    expect(merged.map((message) => message['content']), ['PUBLIC_NEIGHBOR']);
  });

  test('superpone metadata entre Desktop row_id y REST id numérico', () {
    const raw = '[ASYNC DELEGATION BATCH COMPLETE — deleg_row_exact]';
    final persisted = DesktopSessionMessage.tryParse({
      'row_id': 74,
      'role': 'user',
      'content': raw,
      'display_kind': 'async_delegation_complete',
      'display_metadata': {'task_count': 2, 'completed_count': 2},
    })!;
    final rest = <Map<String, dynamic>>[
      {'id': 74, 'role': 'user', 'content': raw},
    ];

    final merged = reconciler.overlayDurableDisplayMetadata(rest, [persisted]);

    expect(merged.single['display_kind'], 'async_delegation_complete');
    expect(merged.single['display_metadata'], {
      'task_count': 2,
      'completed_count': 2,
    });
  });

  test('superpone metadata desde los aliases Desktop id y _row_id', () {
    const raw = '[ASYNC DELEGATION BATCH COMPLETE — deleg_row_alias]';
    for (final alias in const ['id', '_row_id']) {
      final persisted = DesktopSessionMessage.tryParse({
        alias: 74,
        'role': 'user',
        'content': raw,
        'display_kind': 'async_delegation_complete',
        'display_metadata': {'task_count': 2, 'completed_count': 2},
      })!;
      final rest = <Map<String, dynamic>>[
        {'id': 74, 'role': 'user', 'content': raw},
      ];

      final merged = reconciler.overlayDurableDisplayMetadata(rest, [
        persisted,
      ]);

      expect(
        merged.single['display_kind'],
        'async_delegation_complete',
        reason: alias,
      );
    }
  });

  test('fila Desktop enriquecida cruza con REST que solo conserva row id', () {
    const raw = '[ASYNC DELEGATION BATCH COMPLETE — deleg_dual_id]';
    final persisted = DesktopSessionMessage.tryParse({
      'message_id': 'deleg-message-74',
      'row_id': 74,
      'role': 'user',
      'content': raw,
      'display_kind': 'async_delegation_complete',
      'display_metadata': {'task_count': 1, 'completed_count': 1},
    })!;
    final rest = <Map<String, dynamic>>[
      {'id': 74, 'role': 'user', 'content': raw},
    ];

    final merged = reconciler.overlayDurableDisplayMetadata(rest, [persisted]);

    expect(merged.single['display_kind'], 'async_delegation_complete');
  });

  test('aliases Desktop contradictorios no superponen metadata', () {
    const raw = '[ASYNC DELEGATION BATCH COMPLETE — deleg_conflict]';
    final persisted = DesktopSessionMessage.tryParse({
      'row_id': 73,
      'id': 74,
      'role': 'user',
      'content': raw,
      'display_kind': 'async_delegation_complete',
      'display_metadata': {'task_count': 1},
    })!;
    final rest = <Map<String, dynamic>>[
      {'id': 73, 'role': 'user', 'content': raw},
    ];

    final merged = reconciler.overlayDurableDisplayMetadata(rest, [persisted]);

    expect(merged.single, same(rest.single));
    expect(merged.single, isNot(contains('display_kind')));
  });

  test('metadata no se superpone sobre identidades REST duplicadas', () {
    const marker = '[ASYNC DELEGATION BATCH COMPLETE — deleg_rest_dup]';
    final persisted = DesktopSessionMessage.tryParse({
      'message_id': 'duplicate-rest-id',
      'role': 'user',
      'content': marker,
      'display_kind': 'async_delegation_complete',
      'display_metadata': {'task_count': 1},
    })!;
    final rest = <Map<String, dynamic>>[
      {'message_id': 'duplicate-rest-id', 'role': 'user', 'content': marker},
      {
        'message_id': 'duplicate-rest-id',
        'role': 'user',
        'content': 'turno legítimo con id contradictorio',
      },
    ];

    final merged = reconciler.overlayDurableDisplayMetadata(rest, [persisted]);

    expect(
      merged.every((message) => !message.containsKey('display_kind')),
      isTrue,
    );
  });

  test('no superpone metadata si ambas filas carecen de identidad', () {
    const raw = '[ASYNC DELEGATION BATCH COMPLETE — sin identidad]';
    final persisted = DesktopSessionMessage.tryParse({
      'role': 'user',
      'content': raw,
      'display_kind': 'async_delegation_complete',
      'display_metadata': {'task_count': 1},
    })!;
    final rest = <Map<String, dynamic>>[
      {'role': 'user', 'content': raw},
    ];

    final merged = reconciler.overlayDurableDisplayMetadata(rest, [persisted]);

    expect(merged.single, same(rest.single));
    expect(merged.single, isNot(contains('display_kind')));
  });

  test('refresh no equipara un id REST numérico con un id Desktop string', () {
    const raw = '[ASYNC DELEGATION BATCH COMPLETE — deleg_numeric]';
    final persisted = DesktopSessionMessage.tryParse({
      'message_id': '42',
      'role': 'user',
      'content': raw,
      'display_kind': 'async_delegation_complete',
      'display_metadata': {'task_count': 1},
    })!;
    final rest = <Map<String, dynamic>>[
      {'message_id': 42, 'role': 'user', 'content': raw},
    ];

    final merged = reconciler.overlayDurableDisplayMetadata(rest, [persisted]);

    expect(merged.single, same(rest.single));
    expect(merged.single, isNot(contains('display_kind')));
  });

  test('no inventa identidad por contenido ante filas REST duplicadas', () {
    const raw = '[ASYNC DELEGATION BATCH COMPLETE — deleg_repeat]';
    final persisted = DesktopSessionMessage.tryParse({
      'role': 'user',
      'content': raw,
      'display_kind': 'async_delegation_complete',
      'display_metadata': {'task_count': 1},
    })!;
    final rest = <Map<String, dynamic>>[
      {'role': 'user', 'content': raw},
      {'role': 'user', 'content': raw},
    ];

    final merged = reconciler.overlayDurableDisplayMetadata(rest, [persisted]);

    expect(
      merged.every((message) => !message.containsKey('display_kind')),
      isTrue,
    );
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

  test('inflight fallido nunca publica el envelope Harmony crudo', () {
    const raw =
        '<｜channel｜>analysis<｜message｜>PRIVATE_FAILED<｜end｜>'
        '<｜channel｜>final<｜message｜>PUBLIC_FAILED<｜end｜>';
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-failed-private',
        'session_key': 'stored-1',
        'inflight': {
          'user': 'haz la tarea',
          'assistant': raw,
          'streaming': false,
          'error': 'connection reset',
          'status': 'error',
          'recoverable': true,
        },
        'running': false,
      }),
    );

    final partial = result.messagesNewestFirst.singleWhere(
      (message) => message['_cancelled'] == true,
    );
    expect(partial['content'], 'PUBLIC_FAILED');
    expect(
      result.messagesNewestFirst.toString(),
      isNot(contains('PRIVATE_FAILED')),
    );
    expect(result.messagesNewestFirst.toString(), isNot(contains('｜')));
  });

  test('correction offsets conservan estado Harmony entre segmentos', () {
    const raw =
        '<｜channel｜>analysis<｜message｜>PRIVATE_OFFSET<｜end｜>'
        '<｜channel｜>final<｜message｜>PUBLIC_OFFSET<｜end｜>';
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-correction-private',
        'session_key': 'stored-1',
        'inflight': {
          'user': 'p',
          'assistant': raw,
          'streaming': true,
          'corrections': ['corrige'],
          // Fragmenta dentro del payload privado: el sufijo no es público.
          'correction_offsets': [raw.indexOf('PRIVATE_OFFSET') + 4],
        },
        'running': true,
      }),
    );

    final chronological = result.messagesNewestFirst.reversed.toList();
    expect(chronological.map((message) => message['content']), [
      'p',
      'corrige',
      'PUBLIC_OFFSET',
    ]);
    expect(
      result.messagesNewestFirst.toString(),
      isNot(contains('ATE_OFFSET')),
    );
    expect(
      result.messagesNewestFirst.toString(),
      isNot(contains('PRIVATE_OFFSET')),
    );
    expect(result.messagesNewestFirst.toString(), isNot(contains('｜')));
  });

  test('intercala correcciones por los offsets autoritativos del Gateway', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-correction-offsets',
        'session_key': 'stored-1',
        'inflight': {
          'user': 'p',
          'assistant': 'Moving.Still.Done soon.',
          'streaming': true,
          'corrections': ['hurry up', 'and the worktree ones'],
          'correction_offsets': [7, 13],
        },
        'running': true,
      }),
    );

    final chronological = result.messagesNewestFirst.reversed.toList();
    expect(chronological.map((message) => message['content']), [
      'p',
      'Moving.',
      'hurry up',
      'Still.',
      'and the worktree ones',
      'Done soon.',
    ]);
    expect(chronological.last['_pipeline'], isTrue);
    expect(chronological[1]['_pipeline'], isFalse);
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
      'trabajando',
      'y documéntala',
      'incluye ejemplos',
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

  test('alinea por posición el prefijo durable del bloque vivo', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-latest-user-run',
        'session_key': 'stored-1',
        'messages': [
          {'message_id': 'previous-user', 'role': 'user', 'text': 'repetida'},
          {
            'message_id': 'previous-assistant',
            'role': 'assistant',
            'text': 'respuesta anterior',
          },
          {
            'message_id': 'current-user',
            'role': 'user',
            'text': 'turno actual',
          },
          {
            'message_id': 'current-correction',
            'role': 'user',
            'text': 'ya persistida',
          },
        ],
        'inflight': {
          'user': 'turno actual',
          'corrections': ['ya persistida', 'repetida'],
          'assistant': 'parcial',
          'streaming': true,
        },
        'running': true,
      }),
      previousNewestFirst: const [
        {
          'message_id': 'previous-assistant',
          'role': 'assistant',
          'content': 'respuesta anterior',
        },
        {'message_id': 'previous-user', 'role': 'user', 'content': 'repetida'},
      ],
    );

    final chronological = result.messagesNewestFirst.reversed.toList();
    expect(chronological.map((message) => message['content']), [
      'repetida',
      'respuesta anterior',
      'turno actual',
      'ya persistida',
      'parcial',
      'repetida',
    ]);
    expect(
      chronological
          .where((message) => message['_steer'] == true)
          .map((message) => message['content']),
      ['repetida'],
    );
  });

  test(
    'conserva prompt identico anterior y suprime solo el inflight actual',
    () {
      const prompt = 'mismo prompt legitimo';
      final result = reconciler.project(
        snapshot({
          'session_id': 'runtime-live',
          'turn_started_at': 100,
          'inflight': {'user': prompt},
        }),
        fallbackNewestFirst: const [
          {
            'id': 30,
            'message_id': 'current-user',
            'role': 'user',
            'content': prompt,
            'timestamp': 105,
          },
          {
            'id': 20,
            'message_id': 'previous-assistant',
            'role': 'assistant',
            'content': 'respuesta anterior',
            'timestamp': 60,
          },
          {
            'id': 10,
            'message_id': 'previous-user',
            'role': 'user',
            'content': prompt,
            'timestamp': 50,
          },
        ],
        previousNewestFirst: const [
          {
            'id': 20,
            'message_id': 'previous-assistant',
            'role': 'assistant',
            'content': 'respuesta anterior',
            'timestamp': 60,
          },
          {
            'id': 10,
            'message_id': 'previous-user',
            'role': 'user',
            'content': prompt,
            'timestamp': 50,
          },
        ],
      );

      expect(
        result.messagesNewestFirst.reversed
            .where((message) => message['role'] == 'user')
            .map((message) => message['id']),
        [10, 30],
      );
    },
  );

  test(
    'segundo refresh no reanade inflight sobre el usuario durable actual',
    () {
      const prompt = 'mismo prompt legitimo';
      const durableTail = <Map<String, dynamic>>[
        {
          'id': 30,
          'message_id': 'current-user',
          'role': 'user',
          'content': prompt,
          'timestamp': 105,
        },
        {
          'id': 20,
          'message_id': 'previous-assistant',
          'role': 'assistant',
          'content': 'respuesta anterior',
          'timestamp': 60,
        },
        {
          'id': 10,
          'message_id': 'previous-user',
          'role': 'user',
          'content': prompt,
          'timestamp': 50,
        },
      ];

      final result = reconciler.project(
        snapshot({
          'session_id': 'runtime-live-second-refresh',
          'turn_started_at': 100,
          'inflight': {
            'user': prompt,
            'assistant': 'respuesta parcial',
            'streaming': true,
          },
          'running': true,
        }),
        fallbackNewestFirst: durableTail,
        previousNewestFirst: durableTail,
      );

      final users = result.messagesNewestFirst
          .where((message) => message['role'] == 'user')
          .toList(growable: false);
      expect(users.map((message) => message['message_id']), [
        'current-user',
        'previous-user',
      ]);
      expect(
        users.where((message) => message['_desktopSnapshotKind'] == 'inflight'),
        isEmpty,
      );
    },
  );

  test(
    'prompt repetido con timestamp grueso igual conserva el nuevo inflight',
    () {
      const prompt = 'mismo prompt';
      final result = reconciler.project(
        snapshot({
          'session_id': 'runtime-equal-timestamp-repeat',
          'session_key': 'stored-1',
          'turn_started_at': 100,
          'inflight': {
            'user': prompt,
            'assistant': 'segunda respuesta parcial',
            'streaming': true,
          },
          'running': true,
        }),
        fallbackNewestFirst: const [
          {
            'message_id': 'old-answer',
            'role': 'assistant',
            'content': 'primera respuesta terminada',
            'timestamp': 100,
          },
          {
            'message_id': 'old-user',
            'role': 'user',
            'content': prompt,
            'timestamp': 100,
          },
        ],
      );

      final users = result.messagesNewestFirst
          .where((message) => message['role'] == 'user')
          .toList(growable: false);
      expect(
        users,
        hasLength(2),
        reason: 'el turno inflight actual debe seguir visible',
      );
      expect(
        users.where((message) => message['_desktopSnapshotKind'] == 'inflight'),
        hasLength(1),
      );
    },
  );

  test('usuario actual empatado sin frontera assistant falla cerrado', () {
    const prompt = 'prompt actual';
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-equal-current-corrections',
        'session_key': 'stored-1',
        'turn_started_at': 100,
        'inflight': {
          'user': prompt,
          'corrections': ['corrige A', 'corrige B'],
          'assistant': 'respuesta parcial',
          'streaming': true,
        },
        'running': true,
      }),
      fallbackNewestFirst: const [
        {
          'message_id': 'correction-b',
          'role': 'user',
          'content': 'corrige B',
          'timestamp': 100,
          '_steer': true,
        },
        {
          'message_id': 'correction-a',
          'role': 'user',
          'content': 'corrige A',
          'timestamp': 100,
          '_steer': true,
        },
        {
          'message_id': 'current-user',
          'role': 'user',
          'content': prompt,
          'timestamp': 100,
        },
      ],
    );

    expect(
      result.messagesNewestFirst.where(
        (message) => message['role'] == 'user' && message['content'] == prompt,
      ),
      hasLength(2),
    );
    expect(
      result.messagesNewestFirst
          .where((message) => message['_steer'] == true)
          .map((message) => message['content']),
      ['corrige B', 'corrige A', 'corrige B', 'corrige A'],
    );
  });

  test(
    'steer local posterior al snapshot conserva el prompt durable único',
    () {
      const prompt = 'prompt actual';
      final result = reconciler.project(
        snapshot({
          'session_id': 'runtime-live-correction',
          'turn_started_at': 100,
          'inflight': {
            'user': prompt,
            'assistant': 'respuesta parcial',
            'streaming': true,
          },
          'running': true,
        }),
        fallbackNewestFirst: const [
          {
            'id': 40,
            'message_id': 'durable-correction',
            'role': 'user',
            'content': 'corrección durable',
            'timestamp': 110,
            '_steer': true,
          },
          {
            'id': 30,
            'message_id': 'current-user',
            'role': 'user',
            'content': prompt,
            'timestamp': 105,
          },
          {
            'id': 20,
            'message_id': 'previous-answer',
            'role': 'assistant',
            'content': 'respuesta anterior',
            'timestamp': 90,
          },
        ],
        previousNewestFirst: const [
          {
            'id': 20,
            'message_id': 'previous-answer',
            'role': 'assistant',
            'content': 'respuesta anterior',
            'timestamp': 90,
          },
        ],
      );

      expect(
        result.messagesNewestFirst
            .where(
              (message) =>
                  message['role'] == 'user' && message['content'] == prompt,
            )
            .map((message) => message['id']),
        [30],
      );
      expect(
        result.messagesNewestFirst
            .where((message) => message['_steer'] == true)
            .map((message) => message['content']),
        ['corrección durable'],
      );
      expect(
        result.messagesNewestFirst.any(
          (message) =>
              message['role'] == 'assistant' &&
              message['content'] == 'respuesta parcial',
        ),
        isTrue,
      );
    },
  );

  test('conserva identidad separada aunque haya tools detrás del bloque', () {
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

  test('retains inflight without a durable turn identity', () {
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
      ['mismo turno', 'mismo turno'],
    );
    expect(
      result.messagesNewestFirst.where(
        (message) =>
            message['role'] == 'user' &&
            message['_desktopSnapshotKind'] == 'inflight',
      ),
      isNotEmpty,
    );
  });

  test(
    'no identifica inflight por texto contra un turno anterior ya respondido',
    () {
      final result = reconciler.project(
        snapshot({
          'session_id': 'runtime-repeated-completed-prompt',
          'session_key': 'stored-1',
          'messages': [
            {'message_id': 'old-user', 'role': 'user', 'text': 'mismo prompt'},
            {
              'message_id': 'old-answer',
              'role': 'assistant',
              'text': 'respuesta legítima anterior',
            },
          ],
          'inflight': {
            'user': 'mismo prompt',
            'assistant': 'respuesta nueva parcial',
            'streaming': true,
          },
          'running': true,
        }),
      );

      final chronological = result.messagesNewestFirst.reversed.toList();
      expect(chronological.map((message) => message['content']), [
        'mismo prompt',
        'respuesta legítima anterior',
        'mismo prompt',
        'respuesta nueva parcial',
      ]);
      expect(
        chronological.where((message) => message['role'] == 'user'),
        hasLength(2),
      );
    },
  );

  test('preserva un reenvío idéntico sin identidad de turno inflight', () {
    final result = reconciler.project(
      snapshot({
        'session_id': 'runtime-repeated-cancelled-prompt',
        'session_key': 'stored-1',
        'messages': [
          {
            'message_id': 'cancelled-user-a',
            'role': 'user',
            'text': 'mismo prompt',
          },
        ],
        'inflight': {
          'user': 'mismo prompt',
          'assistant': 'respuesta viva de B',
          'streaming': true,
        },
        'running': true,
      }),
    );

    final chronological = result.messagesNewestFirst.reversed.toList();
    expect(chronological.map((message) => message['content']), [
      'mismo prompt',
      'mismo prompt',
      'respuesta viva de B',
    ]);
    expect(
      chronological.where((message) => message['role'] == 'user'),
      hasLength(2),
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
      'thinking y tool_use se descartan pero conservan narración pública',
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
        expect(assistant, isNot(contains('reasoning')));
        expect(assistant, isNot(contains('tool_calls')));
        expect(assistant.toString(), isNot(contains('uso el shell')));
        expect(assistant.toString(), isNot(contains('ls -la')));
      },
    );

    test(
      'un user formado solo por tool_result no se proyecta como contenido',
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
        expect(roles, isEmpty);
        expect(
          result.messagesNewestFirst.toString(),
          isNot(contains('fichero.txt')),
        );
        expect(
          result.messagesNewestFirst.toString(),
          isNot(contains('toolu-1')),
        );
      },
    );

    test('redacted_thinking se descarta y conserva la respuesta pública', () {
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
      expect(assistant, isNot(contains('reasoning')));
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
