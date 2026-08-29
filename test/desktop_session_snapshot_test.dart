import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';

void main() {
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
