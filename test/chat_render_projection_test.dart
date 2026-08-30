import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_render_projection.dart';
import 'package:hermes_android/core/utils/chat_turn.dart';

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

      expect(projection.units[1], isA<ChatMessageUnitPlan>());
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
    const marker =
        '[ASYNC DELEGATION BATCH COMPLETE — deleg_8980456e]';
    for (final content in [marker, '$marker\nPayload interno']) {
      final event = _message('user', content);
      expect(
        effectiveUserDisplayKind(event),
        'async_delegation_complete',
        reason: content,
      );
      expect(isRealUserTurn(event), isFalse, reason: content);
    }

    for (final content in [
      '$marker ¿Qué significa?',
      marker.toLowerCase(),
      '[ASYNC DELEGATION BATCH COMPLETE - deleg_8980456e]',
      ' $marker',
    ]) {
      final user = _message('user', content);
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

  test(
    'un assistant con razonamiento estructurado y content vacío no se evapora',
    () {
      final reasoner = _message('assistant', '')
        ..['reasoning_content'] = 'pensé paso a paso';
      final projection = ChatRenderProjection.build([
        reasoner,
        _message('user', 'Pregunta'),
      ]);

      expect(projection.units, hasLength(2));
      expect(projection.assistantMessageIndexesNewestFirst, [0]);
    },
  );

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
        ..['reasoning_content'] = 'razonamiento tardío';

      expect(projection.canReuseFor(messages), isFalse);
    },
  );
}
