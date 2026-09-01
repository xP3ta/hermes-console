import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

void main() {
  test('message_id inválido no se recorta para inventar una identidad', () {
    final invalid = DesktopSessionMessage.tryParse(const {
      'message_id': ' opaque-id ',
      'role': 'user',
      'content': 'mensaje',
    });
    final exact = DesktopSessionMessage.tryParse(const {
      'message_id': 'opaque-id',
      'role': 'user',
      'content': 'mensaje',
    });

    expect(invalid, isNotNull);
    expect(invalid!.stableId, isNull);
    expect(exact!.stableId, 'opaque-id');
  });

  test('conserva row ids numéricos exactos de todos los aliases Desktop', () {
    for (final alias in const ['row_id', '_row_id', 'id']) {
      final parsed = DesktopSessionMessage.tryParse({
        alias: 42,
        'role': 'user',
        'content': 'mensaje por fila',
      });

      expect(parsed, isNotNull, reason: alias);
      expect(parsed!.rowId, 42, reason: alias);
      expect(parsed.stableId, isNull, reason: alias);
    }
  });

  test('conserva juntas las coordenadas message id y row id', () {
    final parsed = DesktopSessionMessage.tryParse(const {
      'message_id': 'opaque-42',
      'row_id': 42,
      'role': 'assistant',
      'content': 'mensaje con identidad enriquecida',
    });

    expect(parsed, isNotNull);
    expect(parsed!.stableId, 'opaque-42');
    expect(parsed.rowId, 42);
  });

  test('aliases numéricos contradictorios invalidan la identidad', () {
    final parsed = DesktopSessionMessage.tryParse(const {
      'row_id': 41,
      'id': 42,
      'role': 'user',
      'content': 'mensaje contradictorio',
    });

    expect(parsed, isNotNull);
    expect(parsed!.stableId, isNull);
    expect(parsed.rowId, isNull);
  });

  test('marca incompleto un snapshot que descartó una fila malformada', () {
    final snapshot = DesktopSessionSnapshot.fromJson(
      const {
        'session_id': 'runtime-malformed-row',
        'session_key': 'stored-malformed-row',
        'messages': [
          {
            'message_id': 'missing-role',
            'content': 'fila que no se pudo proyectar',
          },
          {
            'message_id': 'valid-user',
            'role': 'user',
            'content': 'fila válida',
          },
        ],
      },
      requestedStoredSessionId: 'stored-malformed-row',
      created: false,
      method: 'session.resume',
    );

    expect(snapshot.messagesProvided, isTrue);
    expect(snapshot.messages, hasLength(1));
    expect(snapshot.messagesFullyParsed, isFalse);
  });

  test(
    'messages_omitted no acredita un transcript vacío como proporcionado',
    () {
      final snapshot = DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-omitted-messages',
          'session_key': 'stored-omitted-messages',
          'messages': <Object>[],
          'messages_omitted': true,
        },
        requestedStoredSessionId: 'stored-omitted-messages',
        created: false,
        method: 'session.resume',
      );

      expect(snapshot.messages, isEmpty);
      expect(snapshot.messagesProvided, isFalse);
      expect(snapshot.raw, isNot(contains('messages_omitted')));
      expect(
        DesktopSessionBinding.fromSnapshot(snapshot).messagesProvided,
        isFalse,
      );
    },
  );

  test('DesktopSessionBinding conserva el hueco de parseo del snapshot', () {
    final snapshot = DesktopSessionSnapshot.fromJson(
      const {
        'session_id': 'runtime-binding-malformed-row',
        'session_key': 'stored-binding-malformed-row',
        'messages': [
          {
            'message_id': 'missing-role',
            'content': 'fila que no se pudo proyectar',
          },
          {
            'message_id': 'valid-user',
            'role': 'user',
            'content': 'fila válida',
          },
        ],
      },
      requestedStoredSessionId: 'stored-binding-malformed-row',
      created: false,
      method: 'session.resume',
    );

    final binding = DesktopSessionBinding.fromSnapshot(snapshot);

    expect(snapshot.messagesFullyParsed, isFalse);
    expect(binding.messagesFullyParsed, isFalse);
  });

  test('DesktopSessionBinding conserva pending_clarify y su presencia', () {
    final snapshot = DesktopSessionSnapshot.fromJson(
      const {
        'session_id': 'runtime-binding-clarify',
        'session_key': 'stored-binding-clarify',
        'pending_clarify': {
          'request_id': 'clarify-opaque',
          'question': '¿Cuál destino?',
        },
      },
      requestedStoredSessionId: 'stored-binding-clarify',
      created: false,
      method: 'session.resume',
    );

    final binding = DesktopSessionBinding.fromSnapshot(snapshot);

    expect(binding.pendingClarifyProvided, isTrue);
    expect(binding.pendingClarify, snapshot.pendingClarify);
  });

  test('parsea turn_started_at del snapshot vivo real del Gateway', () {
    final snapshot = DesktopSessionSnapshot.fromJson(
      const {
        'session_id': 'runtime-live-turn',
        'session_key': 'stored-live-turn',
        'started_at': 10,
        'turn_started_at': 100.25,
        'running': true,
        'inflight': {'user': 'turno vivo', 'assistant': '', 'streaming': true},
      },
      requestedStoredSessionId: 'stored-live-turn',
      created: false,
      method: 'session.resume',
    );

    expect(
      snapshot.resolvedTurnStartedAt,
      DateTime.fromMillisecondsSinceEpoch(100250, isUtc: true),
    );
    expect(snapshot.raw, isNot(contains('turn_started_at')));
    expect(
      DesktopSessionBinding.fromSnapshot(snapshot).resolvedTurnStartedAt,
      snapshot.resolvedTurnStartedAt,
    );
  });

  test('rechaza dos inicios de turno contradictorios', () {
    final snapshot = DesktopSessionSnapshot.fromJson(
      const {
        'session_id': 'runtime-conflicting-turn',
        'session_key': 'stored-conflicting-turn',
        'turn_started_at': 100,
        'running': true,
        'inflight': {
          'user': 'turno vivo',
          'streaming': true,
          'started_at': 101,
        },
      },
      requestedStoredSessionId: 'stored-conflicting-turn',
      created: false,
      method: 'session.resume',
    );

    expect(snapshot.resolvedTurnStartedAt, isNull);
  });

  test(
    'pending_clarify malformado se marca presente sin duplicarlo en raw',
    () {
      final snapshot = DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-clarify-malformed',
          'session_key': 'stored-clarify-malformed',
          'pending_clarify': 'not-a-map',
          'extension_safe': 'kept',
        },
        requestedStoredSessionId: 'stored-clarify-malformed',
        created: false,
        method: 'session.resume',
      );

      expect(snapshot.pendingClarifyProvided, isTrue);
      expect(snapshot.pendingClarify, isNull);
      expect(snapshot.raw, {'extension_safe': 'kept'});
    },
  );

  group('DesktopInflightTurn corrections', () {
    test(
      'parsea el error terminal retenido sin conservar payload duplicado',
      () {
        final snapshot = DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-failed',
            'session_key': 'stored-failed',
            'inflight': {
              'assistant': 'respuesta parcial',
              'streaming': false,
              'user': 'haz la tarea',
              'error': 'model call failed: 500',
              'status': 'error',
              'recoverable': true,
            },
          },
          requestedStoredSessionId: 'stored-failed',
          created: false,
          method: 'session.resume',
        );

        final inflight = snapshot.inflight!;
        expect(inflight.error, 'model call failed: 500');
        expect(inflight.status, 'error');
        expect(inflight.recoverable, isTrue);
        expect(inflight.raw, isEmpty);
      },
    );

    test('un error terminal basta para materializar inflight', () {
      final snapshot = DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-error-only',
          'session_key': 'stored-error-only',
          'inflight': {
            'error': 'turn failed',
            'status': 'error',
            'recoverable': false,
          },
        },
        requestedStoredSessionId: 'stored-error-only',
        created: false,
        method: 'session.resume',
      );

      expect(snapshot.inflight?.error, 'turn failed');
      expect(snapshot.inflight?.recoverable, isFalse);
    });

    test('parsea, filtra y congela las correcciones oldest-first', () {
      final snapshot = DesktopSessionSnapshot.fromJson(
        {
          'session_id': 'runtime-corrections',
          'session_key': 'stored-corrections',
          'inflight': {
            'corrections': [
              '  primera corrección  ',
              '',
              42,
              {
                'text': 'segunda corrección',
                'created_at': 1785686400,
                'updated_at': 1785686460,
                'sequence': 2,
                'prompt_payload': 'no retener',
              },
              {'text': '   '},
              null,
            ],
          },
        },
        requestedStoredSessionId: 'stored-corrections',
        created: false,
        method: 'session.resume',
      );

      final inflight = snapshot.inflight!;
      expect(inflight.corrections.map((item) => item.text), [
        'primera corrección',
        'segunda corrección',
      ]);
      expect(
        inflight.corrections.last.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1785686400000, isUtc: true),
      );
      expect(
        inflight.corrections.last.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1785686460000, isUtc: true),
      );
      expect(inflight.corrections.last.raw, {'sequence': 2});
      expect(
        () => inflight.corrections.last.raw['sequence'] = 3,
        throwsUnsupportedError,
      );
      expect(inflight.raw, isNot(contains('corrections')));
      expect(inflight.corrections.clear, throwsUnsupportedError);
    });

    test('ignora una colección malformada sin inventar inflight', () {
      final snapshot = DesktopSessionSnapshot.fromJson(
        {
          'session_id': 'runtime-malformed',
          'session_key': 'stored-malformed',
          'inflight': {
            'corrections': {'text': 'no es una lista'},
          },
        },
        requestedStoredSessionId: 'stored-malformed',
        created: false,
        method: 'session.resume',
      );

      expect(snapshot.inflight, isNull);
    });

    test('recoverable aislado no inventa un turno vivo', () {
      final snapshot = DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-recoverable-only',
          'session_key': 'stored-recoverable-only',
          'inflight': {'recoverable': true},
        },
        requestedStoredSessionId: 'stored-recoverable-only',
        created: false,
        method: 'session.resume',
      );

      expect(snapshot.inflight, isNull);
    });
  });
}
