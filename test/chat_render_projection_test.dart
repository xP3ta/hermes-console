import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_render_projection.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/utils/chat_turn.dart';

/// Carrier canónico que Hermes persiste junto a `display_kind: process_complete`
/// cuando termina un proceso en segundo plano.
const _processCompleteCarrier =
    '[IMPORTANT: Background process proc_0123456789ab exited (exit code 0).\n'
    'Command: node verify.mjs\n'
    'Output:\n'
    'verificacion completada\n'
    ']';

Map<String, dynamic> _message(
  String role,
  String content, {
  bool pipeline = false,
  bool steer = false,
}) => <String, dynamic>{
  'role': role,
  'content': content,
  if (pipeline) '_pipeline': true,
  if (steer) '_steer': true,
};

void main() {
  test('empty assistant tool-call row has no message bubble', () {
    final normalized = normalizeTranscriptMessageForDisplay(
      const {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call-1',
            'function': {'name': 'shell', 'arguments': '{}'},
          },
        ],
      },
      retainAssistantToolCalls: true,
    )!;
    final projection = ChatRenderProjection.build([normalized]);

    expect(projection.units.whereType<ChatMessageUnitPlan>(), isEmpty);
    expect(projection.assistantMessageIndexesNewestFirst, isEmpty);
  });

  test('artifact-only message navigates to its nearest rendered context', () {
    final messages = <Map<String, dynamic>>[
      {
        'role': 'assistant',
        'content': '',
        '_desktopMessageId': 'artifact-only',
      },
      {'role': 'user', 'content': 'create the artifact'},
      {'role': 'assistant', 'content': 'older answer'},
    ];

    final projection = ChatRenderProjection.build(messages);

    expect(projection.nearestRenderableMessageIndex(0), 1);
    expect(projection.nearestRenderableMessageIndex(1), 1);
  });

  test(
    'un flush de tokens reutiliza estructura pero resuelve el mapa nuevo',
    () {
      final messages = [
        _message('assistant', 'Hola'),
        _message('user', 'Pregunta'),
      ];
      final projection = ChatRenderProjection.build(messages);
      final replacement = _message('assistant', 'Hola, ya está completo');

      messages[0] = replacement;

      expect(projection.canReuseFor(messages), isTrue);
      expect(projection.assistantMessages(messages).single, same(replacement));
      final newest = projection.units.first as ChatMessageUnitPlan;
      expect(messages[newest.messageIndex], same(replacement));
    },
  );

  test(
    'la transición de placeholder al primer texto invalida la estructura',
    () {
      final messages = [
        _message('assistant', '', pipeline: true),
        _message('user', 'Pregunta'),
      ];
      final projection = ChatRenderProjection.build(messages);

      messages[0] = _message('assistant', 'Primera frase');

      expect(projection.canReuseFor(messages), isFalse);
    },
  );

  test('descarta placeholders históricos y conserva solo el vivo', () {
    final live = _message('assistant', '', pipeline: true);
    final stale = _message('assistant', '', pipeline: true);
    final projection = ChatRenderProjection.build([
      live,
      _message('user', 'segunda pregunta'),
      stale,
      _message('user', 'primera pregunta'),
    ]);

    final pipelineUnits = projection.units
        .whereType<ChatMessageUnitPlan>()
        .where((unit) => unit.messageIndex == 0 || unit.messageIndex == 2);
    expect(pipelineUnits.map((unit) => unit.messageIndex), [0]);
  });

  test('cambiar longitud o lista fuente invalida la proyección', () {
    final messages = [_message('user', 'Uno')];
    final projection = ChatRenderProjection.build(messages);

    messages.add(_message('assistant', 'Dos'));
    expect(projection.canReuseFor(messages), isFalse);
    expect(
      projection.canReuseFor(List<Map<String, dynamic>>.of(messages)),
      isFalse,
    );
  });

  test('cachea índices de respuestas y ordinales de usuario', () {
    final oldestUser = _message('user', 'Primera');
    final newestUser = _message('user', 'Segunda');
    final latestAssistant = _message('assistant', 'Respuesta dos');
    final messages = [
      latestAssistant,
      newestUser,
      _message('assistant', 'Respuesta uno'),
      oldestUser,
    ];

    final projection = ChatRenderProjection.build(messages);

    expect(projection.assistantMessageIndexesNewestFirst, [0, 2]);
    expect(projection.userOrdinalFor(oldestUser), 0);
    expect(projection.userOrdinalFor(newestUser), 1);
    expect(projection.visibleUserCount, 2);
  });

  test('ignora metadatos de modelo al calcular ordinales de usuario', () {
    final oldestUser = _message('user', 'Primera');
    final taggedModelSwitch = _message(
      'user',
      '[System: The active model for this chat has changed to k3.]',
    )..['display_kind'] = 'model_switch';
    final legacyModelSwitch = _message(
      'user',
      '[System: The active model for this chat has changed to k4.]',
    );
    final newestUser = _message('user', 'Segunda');
    final messages = [
      _message('assistant', 'Respuesta dos'),
      newestUser,
      legacyModelSwitch,
      taggedModelSwitch,
      _message('assistant', 'Respuesta uno'),
      oldestUser,
    ];

    final projection = ChatRenderProjection.build(messages);

    expect(projection.userOrdinalFor(oldestUser), 0);
    expect(projection.userOrdinalFor(taggedModelSwitch), isNull);
    expect(projection.userOrdinalFor(legacyModelSwitch), isNull);
    expect(projection.userOrdinalFor(newestUser), 1);
    expect(projection.latestUserMessage, same(newestUser));
    expect(projection.visibleUserCount, 2);
  });

  test(
    'proyecta delegación durable como sistema, no como turno de usuario',
    () {
      final event = _message(
        'user',
        '[ASYNC DELEGATION BATCH COMPLETE — interno]',
      )..['display_kind'] = 'async_delegation_complete';
      final realUser = _message('user', 'Pregunta real');
      final projection = ChatRenderProjection.build([
        _message('assistant', 'Respuesta'),
        event,
        realUser,
      ]);

      expect(projection.units.whereType<ChatMessageUnitPlan>(), hasLength(2));
      expect(projection.userOrdinalFor(event), isNull);
      expect(projection.userOrdinalFor(realUser), 0);
      expect(projection.visibleUserCount, 1);
    },
  );

  test('texto de usuario que solo menciona ASYNC sigue siendo un prompt', () {
    final user = _message(
      'user',
      '[ASYNC DELEGATION BATCH COMPLETE quizá] ¿Qué significa esto?',
    );

    final projection = ChatRenderProjection.build([user]);

    expect(projection.userOrdinalFor(user), 0);
    expect(projection.visibleUserCount, 1);
    expect(projection.units.single, isA<ChatUserTurnUnitPlan>());
  });

  test('solo repara el sentinel ASYNC reservado exacto', () {
    const batchMarker = '[ASYNC DELEGATION BATCH COMPLETE — deleg_8980456e]';
    const singleMarker = '[ASYNC DELEGATION COMPLETE — deleg_0123abcd]';
    for (final content in [
      batchMarker,
      '$batchMarker\nPayload interno',
      singleMarker,
    ]) {
      final event = _message('user', content)..['row_id'] = 42;
      expect(
        effectiveUserDisplayKind(event),
        'async_delegation_complete',
        reason: content,
      );
      expect(isRealUserTurn(event), isFalse, reason: content);
    }

    for (final content in [
      '$batchMarker ¿Qué significa?',
      batchMarker.toLowerCase(),
      '[ASYNC DELEGATION BATCH COMPLETE - deleg_8980456e]',
      ' $batchMarker',
      '[ASYNC DELEGATION BATCH COMPLETE — deleg_nothex12]',
      '[ASYNC DELEGATION BATCH COMPLETE — deleg_8980456e] citado',
    ]) {
      final user = _message('user', content)..['row_id'] = 42;
      expect(effectiveUserDisplayKind(user), isEmpty, reason: content);
      expect(isRealUserTurn(user), isTrue, reason: content);
      final projection = ChatRenderProjection.build([user]);
      expect(projection.visibleUserCount, 1, reason: content);
      expect(
        projection.units.single,
        isA<ChatUserTurnUnitPlan>(),
        reason: content,
      );
    }

    for (final optimistic in [
      _message('user', batchMarker)..['_optimistic'] = true,
      _message('user', batchMarker)..['_optimistic'] = true,
    ]) {
      expect(effectiveUserDisplayKind(optimistic), isEmpty);
      expect(isRealUserTurn(optimistic), isTrue);
    }

    const quoted =
        '¿Por qué aparece [ASYNC DELEGATION BATCH COMPLETE — deleg_8980456e]?';
    final userQuote = _message('user', quoted)..['row_id'] = 43;
    expect(effectiveUserDisplayKind(userQuote), isEmpty);
    expect(userQuote['content'], quoted);
  });

  test(
    'oculta el carrier exacto de background process sin artefactos de usuario',
    () {
      const raw =
          '[IMPORTANT: Background process proc_0b5fab8a4839 exited (exit code 1).\n'
          "Command: agent-cli -p 'Review /home/example/private/project and print TOKEN' "
          '--unsafe-mode\n'
          'Output:\n'
          '/home/example/private/project: failure\n'
          ']';
      final carrier = _message('user', raw)..['row_id'] = 1210;

      expect(effectiveUserDisplayKind(carrier), 'hidden');
      expect(isRealUserTurn(carrier), isFalse);

      final projection = ChatRenderProjection.build([carrier]);

      expect(projection.units, isEmpty);
      expect(projection.visibleUserCount, 0);
      expect(projection.userOrdinalFor(carrier), isNull);
      expect(carrier['content'], raw, reason: 'la historia durable no se muta');
    },
  );

  test(
    'una corrección durable display_kind=steer no crea un segundo turno de usuario',
    () {
      // Regresión: la corrección en vuelo («Añadido mientras Hermes trabajaba»)
      // se persiste como role=user con display_kind='steer'. Sin traducirla al
      // flag estructural `_steer`, la fila durable volvía como turno real:
      // duplicaba la burbuja ya colgada del turno padre y desplazaba todos los
      // ordinales de usuario posteriores.
      final prompt = normalizeTranscriptMessageForDisplay(<String, dynamic>{
        'row_id': 4101,
        'role': 'user',
        'content': 'revisa esta sesión',
      })!;
      final correction = normalizeTranscriptMessageForDisplay(
        <String, dynamic>{
          'row_id': 4102,
          'role': 'user',
          'content': 'y se duplica la burbuja',
          'display_kind': 'steer',
        },
      )!;

      expect(correction['_steer'], isTrue);
      expect(isRealUserTurn(correction), isFalse);
      // El flag estructural sustituye a la etiqueta editorial: una corrección
      // no es un envelope del runtime, es texto del usuario dentro del turno.
      expect(effectiveUserDisplayKind(correction), isEmpty);

      // Lista viva = más nuevo primero: la corrección precede a su prompt.
      final projection = ChatRenderProjection.build([correction, prompt]);

      // Una sola burbuja de usuario, con la corrección como suplemento.
      expect(projection.visibleUserCount, 1);
      expect(projection.userOrdinalFor(prompt), 0);
      expect(projection.userOrdinalFor(correction), isNull);
      final unit = projection.units.single;
      expect(unit, isA<ChatUserTurnUnitPlan>());
      expect((unit as ChatUserTurnUnitPlan).supplementMessageIndexes, [0]);
    },
  );

  test('un personality_switch durable conserva su etiqueta y nunca es turno de usuario', () {
    final normalized = normalizeTranscriptMessageForDisplay(<String, dynamic>{
      'row_id': 9098,
      'role': 'user',
      'content': '[System: The user has changed the assistant\'s personality to concise.]',
      'display_kind': 'personality_switch',
    });

    expect(normalized, isNotNull);
    expect(normalized!['display_kind'], 'personality_switch');
    expect(isRealUserTurn(normalized), isFalse);

    final projection = ChatRenderProjection.build([normalized]);
    expect(projection.units.single, isA<ChatMessageUnitPlan>());
    expect(projection.visibleUserCount, 0);
    expect(projection.userOrdinalFor(normalized), isNull);
  });

  test(
    'un auto_continue etiquetado conserva la autoridad estructural del backend',
    () {
      final normalized = normalizeTranscriptMessageForDisplay(<String, dynamic>{
        'row_id': 9099,
        'role': 'user',
        'content': '[Continuing toward your standing goal]\nGoal: termina las tareas\n\nContinue working toward this goal.',
        'display_kind': 'auto_continue',
      });

      expect(normalized, isNotNull);
      expect(normalized!['display_kind'], 'auto_continue');
      expect(isRealUserTurn(normalized), isFalse);

      final projection = ChatRenderProjection.build([normalized]);
      expect(projection.units.single, isA<ChatMessageUnitPlan>());
      expect(projection.visibleUserCount, 0);
      expect(projection.userOrdinalFor(normalized), isNull);
    },
  );

  test('un process_complete durable sobrevive a la normalización y se proyecta '
      'como evento del sistema', () {
    final normalized = normalizeTranscriptMessageForDisplay(<String, dynamic>{
      'row_id': 9100,
      'role': 'user',
      'content': _processCompleteCarrier,
      'display_kind': 'process_complete',
      'display_metadata': const {
        'display_text': 'Background Process Finished: node verify.mjs',
      },
    });

    expect(normalized, isNotNull);
    expect(normalized!['display_kind'], 'process_complete');
    expect(effectiveUserDisplayKind(normalized), 'process_complete');
    expect(normalized['display_metadata'], {
      'display_text': 'Background Process Finished: node verify.mjs',
    });

    final realUser = _message('user', 'Pregunta real');
    final projection = ChatRenderProjection.build([
      _message('assistant', 'Respuesta'),
      normalized,
      realUser,
    ]);

    // assistant + evento del sistema; el prompt real es la única burbuja.
    expect(projection.units.whereType<ChatMessageUnitPlan>(), hasLength(2));
    expect(
      projection.units
          .whereType<ChatUserTurnUnitPlan>()
          .single
          .primaryMessageIndex,
      2,
    );
  });

  test('un process_complete durable no cuenta ni se edita como turno', () {
    final normalized = normalizeTranscriptMessageForDisplay(<String, dynamic>{
      'row_id': 9101,
      'role': 'user',
      'content': _processCompleteCarrier,
      'display_kind': 'process_complete',
    })!;
    final realUser = _message('user', 'Pregunta real');

    expect(isRealUserTurn(normalized), isFalse);

    final projection = ChatRenderProjection.build([normalized, realUser]);

    // Visible como fila de sistema (ChatMessageUnitPlan), nunca como turno
    // editable: `ChatUserTurnUnitPlan` es el único plan con editar/rebobinar.
    expect(
      projection.units.whereType<ChatMessageUnitPlan>().single.messageIndex,
      0,
    );
    expect(projection.userOrdinalFor(normalized), isNull);
    expect(projection.userOrdinalFor(realUser), 0);
    expect(projection.visibleUserCount, 1);
    expect(projection.latestUserMessage, same(realUser));
    expect(projection.units.whereType<ChatUserTurnUnitPlan>(), hasLength(1));
  });

  test(
    'un carrier interno sin display_kind sigue oculto junto a process_complete',
    () {
      final carrier = _message('user', _processCompleteCarrier)
        ..['row_id'] = 9102;

      expect(effectiveUserDisplayKind(carrier), 'hidden');

      final hidden = _message('user', 'payload interno de otro carrier')
        ..['display_kind'] = 'hidden';

      expect(normalizeTranscriptMessageForDisplay(hidden), isNull);

      final projection = ChatRenderProjection.build([carrier, hidden]);

      expect(projection.units, isEmpty);
      expect(projection.visibleUserCount, 0);
    },
  );

  test(
    'un prompt real parecido a un aviso de proceso sigue siendo del usuario',
    () {
      final normalized = normalizeTranscriptMessageForDisplay(<String, dynamic>{
        'row_id': 9103,
        'role': 'user',
        'content':
            'Background Process Finished: node verify.mjs — ¿qué significa '
            'eso? El proceso proc_0123456789ab salió con exit code 0.',
      })!;

      expect(normalized.containsKey('display_kind'), isFalse);
      expect(effectiveUserDisplayKind(normalized), isEmpty);
      expect(isRealUserTurn(normalized), isTrue);

      final projection = ChatRenderProjection.build([normalized]);

      expect(projection.units.single, isA<ChatUserTurnUnitPlan>());
      expect(projection.visibleUserCount, 1);
    },
  );

  test('el fallback background preserva citas, prefijos inválidos y optimistas', () {
    const canonical =
        '[IMPORTANT: Background process proc_0b5fab8a4839 exited (exit code 137).\n'
        'Command: claude -p private\n'
        'Output:\n'
        'private\n'
        ']';
    for (final raw in const [
      '¿Qué significa [IMPORTANT: Background process ...]?',
      '[IMPORTANT: Background process proc_0b5fab8a4839 exited (exit code 1).',
      '[IMPORTANT: Background process proc_NOTCANON exited (exit code 1).\nCommand: x\nOutput:\ny\n]',
      '[IMPORTANT: Background process proc_0b5fab8a4839 exited (exit code 1). ¿qué significa?',
      'Cita en línea $canonical',
    ]) {
      final user = _message('user', raw);
      expect(projectedUserVisibleContent(user), raw, reason: raw);
      expect(effectiveUserDisplayKind(user), isEmpty, reason: raw);
    }

    final optimistic = _message('user', canonical)..['_optimistic'] = true;
    expect(projectedUserVisibleContent(optimistic), canonical);
    expect(effectiveUserDisplayKind(optimistic), isEmpty);

    for (final separator in const ['\n\n', '\r\n\r\n']) {
      final mixed = _message('user', 'Pregunta visible$separator$canonical');
      expect(projectedUserVisibleContent(mixed), 'Pregunta visible');
      expect(effectiveUserDisplayKind(mixed), isEmpty);
    }
  });

  test(
    'refresh invalida la caché al cambiar entre carrier oculto y prompt real',
    () {
      const carrier =
          '[IMPORTANT: Background process proc_0b5fab8a4839 exited (exit code 0).\n'
          'Command: claude -p private\n'
          'Output:\n'
          'done\n'
          ']';
      final messages = [_message('user', carrier)];
      final projection = ChatRenderProjection.build(messages);

      messages[0] = _message('user', 'Pregunta tras refresh');

      expect(projection.canReuseFor(messages), isFalse);
      expect(
        ChatRenderProjection.build(messages).units.single,
        isA<ChatUserTurnUnitPlan>(),
      );
    },
  );

  test('repara continuaciones de goal antiguas como evento del sistema', () {
    const continuation =
        '[Continuing toward your standing goal]\n'
        'Goal: termina las tareas\n\n'
        'Continue working toward this goal.';
    final event = _message('user', continuation)..['row_id'] = 44;

    expect(effectiveUserDisplayKind(event), 'auto_continue');
    expect(isRealUserTurn(event), isFalse);

    const quoted =
        '¿Qué significa [Continuing toward your standing goal] en Hermes?';
    final userQuote = _message('user', quoted)..['row_id'] = 45;
    expect(effectiveUserDisplayKind(userQuote), isEmpty);
    expect(isRealUserTurn(userQuote), isTrue);
  });

  test('display_kind hidden no crea una burbuja de usuario cruda', () {
    final hidden = _message('user', 'payload interno')
      ..['display_kind'] = 'hidden';

    final projection = ChatRenderProjection.build([hidden]);

    expect(projection.units, isEmpty);
    expect(projection.visibleUserCount, 0);
  });

  test(
    'calcula el fallback 4018 tras un prompt fusionado con model_switch',
    () {
      final newestUser = _message('user', 'Tercera pregunta');
      final messages = [
        _message('assistant', 'Tercera respuesta'),
        newestUser,
        _message('assistant', 'Segunda respuesta'),
        _message('user', 'Segunda pregunta'),
        _message(
          'user',
          '[System: The active model for this chat has changed to k3.]',
        )..['display_kind'] = 'model_switch',
        _message('assistant', 'Primera respuesta'),
        _message('user', 'Primera pregunta'),
      ];

      expect(
        modelSwitchRepairFallbackOrdinal(
          messages,
          newestUser,
          desktopOrdinal: 2,
        ),
        1,
      );
    },
  );

  test('calcula el fallback 4018 cuando REST omite display_kind', () {
    final newestUser = _message('user', 'Tercera pregunta');
    final messages = [
      _message('assistant', 'Tercera respuesta'),
      newestUser,
      _message('assistant', 'Segunda respuesta'),
      _message('user', 'Segunda pregunta'),
      _message(
        'user',
        '[System: The active model for this chat has changed to k3.]',
      ),
      _message('assistant', 'Primera respuesta'),
      _message('user', 'Primera pregunta'),
    ];

    expect(
      modelSwitchRepairFallbackOrdinal(messages, newestUser, desktopOrdinal: 2),
      1,
    );
  });

  test('no rebobina a ciegas un prompt absorbido por model_switch', () {
    final swallowedUser = _message('user', 'Segunda pregunta');
    final messages = [
      swallowedUser,
      _message(
        'user',
        '[System: The active model for this chat has changed to k3.]',
      )..['display_kind'] = 'model_switch',
      _message('assistant', 'Primera respuesta'),
      _message('user', 'Primera pregunta'),
    ];

    expect(
      modelSwitchRepairFallbackOrdinal(
        messages,
        swallowedUser,
        desktopOrdinal: 1,
      ),
      isNull,
    );
  });

  test('agrupa herramientas contiguas sin retener mapas de mensaje', () {
    final messages = [
      _message('assistant', 'Hecho'),
      _message('tool', '{"output":"ok","exit_code":0}'),
      _message('assistant', '')
        ..['tool_calls'] = [
          {
            'function': {'name': 'shell', 'arguments': '{"cmd":"pwd"}'},
          },
        ],
      _message('user', 'Ejecuta'),
    ];

    final projection = ChatRenderProjection.build(messages);

    expect(projection.units, hasLength(3));
    final tools = projection.units[1] as ChatToolActivityUnitPlan;
    expect(tools.events, hasLength(2));
    expect(tools.messageIndexes, [2, 1]);
  });

  test('delegate_task call y result no generan tool rows visibles', () {
    final projection = ChatRenderProjection.build([
      _message(
          'tool',
          '{"delegation_id":"deleg_private","path":"/home/private"}',
        )
        ..['tool_call_id'] = 'call-private'
        ..['tool_name'] = 'delegate_task',
      _message('assistant', '')
        ..['tool_calls'] = [
          {
            'id': 'call-private',
            'function': {
              'name': 'delegate_task',
              'arguments': '{"goal":"PRIVATE_GOAL"}',
            },
          },
        ],
      _message('user', 'Delega una revisión'),
    ]);

    expect(projection.units, hasLength(1));
    expect(projection.units.single, isA<ChatUserTurnUnitPlan>());
  });

  test('tool-call assistant con solo reasoning conserva su burbuja', () {
    final reasoner = _message('assistant', '')
      ..['reasoning'] = 'pensé paso a paso'
      ..['tool_calls'] = [
        {
          'id': 'call-reasoning',
          'function': {'name': 'shell', 'arguments': '{}'},
        },
      ];
    final projection = ChatRenderProjection.build([
      reasoner,
      _message('user', 'Pregunta'),
    ]);

    expect(projection.units.whereType<ChatMessageUnitPlan>(), hasLength(1));
    expect(projection.units.whereType<ChatUserTurnUnitPlan>(), hasLength(1));
    expect(projection.units.whereType<ChatToolActivityUnitPlan>(), hasLength(1));
    expect(projection.assistantMessageIndexesNewestFirst, [0]);
  });

  test('un assistant vacío sin razonamiento sigue evaporándose', () {
    final projection = ChatRenderProjection.build([
      _message('assistant', ''),
      _message('user', 'Pregunta'),
    ]);

    expect(projection.units, hasLength(1));
    expect(projection.assistantMessageIndexesNewestFirst, isEmpty);
  });

  test(
    'la llegada de razonamiento a la cabeza invalida la estructura cacheada',
    () {
      final messages = [
        _message('assistant', ''),
        _message('user', 'Pregunta'),
      ];
      final projection = ChatRenderProjection.build(messages);

      messages[0] = _message('assistant', '')
        ..['reasoning'] = 'razonamiento tardío';

      expect(projection.canReuseFor(messages), isFalse);
    },
  );
}
