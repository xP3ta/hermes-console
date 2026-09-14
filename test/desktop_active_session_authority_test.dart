import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';

void main() {
  test(
    'active session accepts exact opaque runtime and durable identities',
    () {
      final list = DesktopActiveSessionList.fromJson(const {
        'sessions': [
          {
            'id': 'runtime-exact',
            'session_key': 'durable-exact',
            'status': 'running',
          },
        ],
      });

      expect(list.hasMalformedRows, isFalse);
      expect(list.sessions.single.runtimeSessionId, 'runtime-exact');
      expect(list.sessions.single.storedSessionId, 'durable-exact');
    },
  );

  test('active session rejects noncanonical runtime identities', () {
    for (final value in <Object?>[null, 7, '', ' runtime', 'runtime ', '   ']) {
      final list = DesktopActiveSessionList.fromJson({
        'sessions': [
          {'id': value, 'session_key': 'durable-exact'},
        ],
      });

      expect(list.sessions, isEmpty, reason: 'runtime=$value');
      expect(list.hasMalformedRows, isTrue, reason: 'runtime=$value');
    }
  });

  test('present malformed durable identity rejects the whole row', () {
    for (final value in <Object?>[null, 7, '', ' durable', 'durable ', '   ']) {
      final list = DesktopActiveSessionList.fromJson({
        'sessions': [
          {'id': 'runtime-exact', 'session_key': value},
        ],
      });

      expect(list.sessions, isEmpty, reason: 'durable=$value');
      expect(list.hasMalformedRows, isTrue, reason: 'durable=$value');
    }
  });

  test('absent durable identity remains a valid unrelated active row', () {
    final list = DesktopActiveSessionList.fromJson(const {
      'sessions': [
        {'id': 'runtime-exact', 'status': 'idle'},
      ],
    });

    expect(list.hasMalformedRows, isFalse);
    expect(list.sessions.single.storedSessionId, isNull);
  });
}
