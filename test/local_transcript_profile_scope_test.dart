import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _FailingPrefs extends InMemorySharedPreferencesStore {
  _FailingPrefs(Map<String, Object> values)
    : super.withData({
        for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
      });

  bool returnFalse = false;
  bool throwOnRemove = false;

  @override
  Future<bool> remove(String key) async {
    if (throwOnRemove) throw StateError('remove failure');
    if (returnFalse) return false;
    return super.remove(key);
  }
}

class _FailingGetAllPrefs extends InMemorySharedPreferencesStore {
  _FailingGetAllPrefs() : super.empty();

  @override
  Future<Map<String, Object>> getAll() async {
    throw StateError('getAll failure');
  }
}

String _hex(String value) => value.codeUnits
    .map((unit) => unit.toRadixString(16).padLeft(4, '0'))
    .join();

String _v3Key(String connectionId, String profile, String sessionId) =>
    'hermes.transcript.v3.${_hex(connectionId)}.${_hex(profile)}.${_hex(sessionId)}';

String _v2Key(String connectionId, String profile, String sessionId) =>
    'local_transcript_v2.${base64Url.encode(utf8.encode(connectionId)).replaceAll('=', '')}.${base64Url.encode(utf8.encode(profile)).replaceAll('=', '')}.$sessionId';

const _collisionKey = 'local_transcript_v2.YQ.ZGVmYXVsdA.s_t';
const _message = <String, dynamic>{
  'role': 'assistant',
  'content': 'sentinel histórico',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  String? failingReadKey;
  String? failingWriteKey;
  String? failingDeleteKey;
  int failReadAllCount = 0;
  final deletedSecureKeys = <String>[];

  setUp(() {
    LocalConversationCleanupFence.resetForTesting();
    secure.clear();
    failingReadKey = null;
    failingWriteKey = null;
    failingDeleteKey = null;
    failReadAllCount = 0;
    deletedSecureKeys.clear();
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                if (args['key'] == failingWriteKey) {
                  throw PlatformException(code: 'write-failure');
                }
                secure[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                if (args['key'] == failingReadKey) {
                  throw PlatformException(code: 'read-failure');
                }
                return secure[args['key'] as String];
              case 'delete':
                deletedSecureKeys.add(args['key'] as String);
                if (args['key'] == failingDeleteKey) {
                  throw PlatformException(code: 'delete-failure');
                }
                secure.remove(args['key'] as String);
                return null;
              case 'readAll':
                if (failReadAllCount > 0) {
                  failReadAllCount--;
                  throw PlatformException(code: 'read-all-failure');
                }
                return Map<String, String>.from(secure);
              case 'containsKey':
                return secure.containsKey(args['key'] as String);
            }
            return null;
          },
        );
  });

  group('REGRESSION_V2_LEGACY_EXACT_COLLISION', () {
    final payloads = <String>[
      jsonEncode(const [_message]),
      jsonEncode({
        'version': 1,
        'older_history_truncated': true,
        'messages': const [_message],
      }),
    ];

    Future<void> seed(String raw, int backend) async {
      if (backend != 1) secure[_collisionKey] = raw;
      if (backend != 0) {
        await (await SharedPreferences.getInstance()).setString(
          _collisionKey,
          raw,
        );
      }
    }

    Future<Map<String, Object?>> plainState() async {
      final prefs = await SharedPreferences.getInstance();
      return {for (final key in prefs.getKeys()) key: prefs.get(key)};
    }

    test(
      'load snapshot and list never attribute historical payloads',
      () async {
        for (final raw in payloads) {
          for (var backend = 0; backend < 3; backend++) {
            secure.clear();
            SharedPreferences.setMockInitialValues({});
            await seed(raw, backend);
            final beforeSecure = Map<String, String>.from(secure);
            final beforePlain = await plainState();
            for (final tuple in const [
              ('v2.YQ.ZGVmYXVsdA.s', 'default', 't'),
              ('a', 'default', 's_t'),
            ]) {
              expect(
                await LocalTranscriptStore.load(
                  tuple.$1,
                  tuple.$3,
                  profile: tuple.$2,
                ),
                isEmpty,
              );
              final snapshot = await LocalTranscriptStore.loadSnapshot(
                tuple.$1,
                tuple.$3,
                profile: tuple.$2,
              );
              expect(snapshot.messages, isEmpty);
              expect(snapshot.olderHistoryTruncated, isFalse);
              expect(
                await LocalTranscriptStore.listForConnection(tuple.$1),
                isEmpty,
              );
            }
            expect(secure, beforeSecure);
            expect(await plainState(), beforePlain);
          }
        }
      },
    );

    test('save clear and bulk deletion preserve historical bytes', () async {
      for (final raw in payloads) {
        for (var backend = 0; backend < 3; backend++) {
          secure.clear();
          SharedPreferences.setMockInitialValues({});
          await seed(raw, backend);
          final beforeSecure = Map<String, String>.from(secure);
          final beforePlain = await plainState();
          await LocalTranscriptStore.saveFromNewestFirst('a', 's_t', const [
            _message,
          ]);
          expect(secure[_v3Key('a', 'default', 's_t')], isNotNull);
          expect(secure[_collisionKey], beforeSecure[_collisionKey]);
          expect(
            (await plainState())[_collisionKey],
            beforePlain[_collisionKey],
          );
          await LocalTranscriptStore.clear('a', 's_t');
          expect(secure[_collisionKey], beforeSecure[_collisionKey]);
          expect(
            (await plainState())[_collisionKey],
            beforePlain[_collisionKey],
          );
          expect(await LocalTranscriptStore.deleteForProfile('a', ''), 0);
          expect(await LocalTranscriptStore.deleteForConnection('a'), 0);
          expect(secure, beforeSecure);
          expect(await plainState(), beforePlain);
        }
      }
    });

    test('legitimate v3 coexistence remains operational', () async {
      await seed(payloads.last, 2);
      await LocalTranscriptStore.saveFromNewestFirst('a', 's_t', const [
        {'role': 'assistant', 'content': 'v3 legítimo'},
      ]);
      expect(await LocalTranscriptStore.listForConnection('a'), hasLength(1));
      expect(await LocalTranscriptStore.deleteForConnection('a'), 1);
      expect(secure[_collisionKey], payloads.last);
      expect(
        (await SharedPreferences.getInstance()).getString(_collisionKey),
        payloads.last,
      );
    });
  });

  group('REGRESSION_LEGACY_PROFILE_OWNER_UNPROVEN', () {
    test('default does not claim a legacy key with a valid payload', () async {
      secure['local_transcript_a_s'] = jsonEncode(const [_message]);
      expect(await LocalTranscriptStore.load('a', 's'), isEmpty);
      expect(secure['local_transcript_a_s'], isNotNull);
    });

    test(
      'named profile does not claim a v2 key with a valid payload',
      () async {
        final key = _v2Key('a', 'manager', 's');
        secure[key] = jsonEncode(const [_message]);
        expect(
          await LocalTranscriptStore.load('a', 's', profile: 'manager'),
          isEmpty,
        );
        expect(secure[key], isNotNull);
      },
    );
  });

  group('REGRESSION_V2_ROUNDTRIP_INJECTIVE', () {
    test('counterexample tuples coexist and delete independently', () async {
      await LocalTranscriptStore.saveFromNewestFirst(
        'v2.YQ.ZGVmYXVsdA.s',
        't',
        const [
          {'role': 'assistant', 'content': 'legacy-shaped owner'},
        ],
      );
      await LocalTranscriptStore.saveFromNewestFirst('a', 's_t', const [
        {'role': 'assistant', 'content': 'v2-shaped owner'},
      ]);
      expect(
        await LocalTranscriptStore.load('v2.YQ.ZGVmYXVsdA.s', 't'),
        contains(predicate<Map>((m) => m['content'] == 'legacy-shaped owner')),
      );
      expect(
        await LocalTranscriptStore.load('a', 's_t'),
        contains(predicate<Map>((m) => m['content'] == 'v2-shaped owner')),
      );
      expect(await LocalTranscriptStore.deleteForConnection('a'), 1);
      expect(
        await LocalTranscriptStore.load('v2.YQ.ZGVmYXVsdA.s', 't'),
        isNotEmpty,
      );
    });

    test('UTF-16 corpus produces 2028 reversible identities', () async {
      final values = <String>[
        '',
        'a',
        'a_b',
        '.',
        '\u0000',
        'é',
        'e\u0301',
        '😀',
        String.fromCharCode(0xd800),
        String.fromCharCode(0xd801),
        '\ufffd',
        ' default ',
        'default',
      ];
      final expected = <(String, String, String)>{};
      final keys = <String>{};
      for (final connection in values) {
        for (final rawProfile in values) {
          final profile = rawProfile.isEmpty ? 'default' : rawProfile;
          for (final session in values) {
            expected.add((connection, profile, session));
            keys.add(_v3Key(connection, profile, session));
            await LocalTranscriptStore.saveFromNewestFirst(
              connection,
              session,
              const [_message],
              profile: rawProfile,
            );
          }
        }
      }
      expect(expected, hasLength(2028));
      expect(keys, hasLength(2028));
      expect(secure.keys.toSet(), keys);
      final recovered = <(String, String, String)>{};
      for (final connection in values) {
        for (final session in await LocalTranscriptStore.listForConnection(
          connection,
        )) {
          recovered.add((connection, session.profile!, session.id));
        }
      }
      expect(recovered, expected);
    });
  });

  group('REGRESSION_V3_CLOSED_PARSER', () {
    test(
      'profile canonicalization preserves spaces and list filter semantics',
      () async {
        for (final profile in const [
          '',
          'default',
          ' default ',
          'p',
          ' p ',
          ' ',
        ]) {
          await LocalTranscriptStore.saveFromNewestFirst('profiles', 'shared', [
            {'role': 'assistant', 'content': 'owner <$profile>'},
          ], profile: profile);
        }
        expect(
          (await LocalTranscriptStore.listForConnection(
            'profiles',
          )).map((session) => session.profile),
          unorderedEquals(['default', ' default ', 'p', ' p ', ' ']),
        );
        expect(
          (await LocalTranscriptStore.listForConnection(
            'profiles',
            profile: '',
          )).map((session) => session.profile),
          ['default'],
        );
        await LocalTranscriptStore.saveFromNewestFirst('', '', const [
          _message,
        ]);
        expect(await LocalTranscriptStore.load('', ''), isNotEmpty);
      },
    );

    test(
      'closed parser preserves malformed keys and prefix neighbors',
      () async {
        final raw = jsonEncode(const [_message]);
        final canonical = _v3Key('target', 'default', 'session');
        final malformed = <String, String>{
          '$canonical.extra': raw,
          _v3Key('.', 'default', 'session').replaceFirst('002e', '002E'): raw,
          canonical.replaceFirst('0074', '007g'): raw,
          canonical.replaceFirst('0074', '074'): raw,
          'hermes.transcript.v3.${_hex('target')}..${_hex('session')}': raw,
        };
        secure.addAll(malformed);
        final prefs = await SharedPreferences.getInstance();
        for (final entry in malformed.entries) {
          await prefs.setString(entry.key, entry.value);
        }
        await LocalTranscriptStore.saveFromNewestFirst(
          'target-neighbor',
          'session',
          const [_message],
        );
        await LocalTranscriptStore.saveFromNewestFirst(
          'target',
          'session-neighbor',
          const [_message],
        );
        expect(
          await LocalTranscriptStore.listForConnection('target'),
          hasLength(1),
        );
        expect(await LocalTranscriptStore.deleteForProfile('target', ''), 1);
        expect(await LocalTranscriptStore.listForConnection('.'), isEmpty);
        expect(await LocalTranscriptStore.deleteForConnection('.'), 0);
        for (final entry in malformed.entries) {
          expect(secure[entry.key], entry.value);
          expect(prefs.getString(entry.key), entry.value);
        }
        expect(
          await LocalTranscriptStore.listForConnection('target-neighbor'),
          hasLength(1),
        );
      },
    );

    test('same session id in distinct profiles is not deduplicated', () async {
      for (final profile in const ['a', 'b']) {
        await LocalTranscriptStore.saveFromNewestFirst('same', 'session', [
          {'role': 'assistant', 'content': profile},
        ], profile: profile);
      }
      expect(
        await LocalTranscriptStore.listForConnection('same'),
        hasLength(2),
      );
    });
  });

  group('REGRESSION_V4_PLAINTEXT_PRECEDENCE', () {
    test('plaintext-only v3 loads and lists without mutation', () async {
      final prefs = await SharedPreferences.getInstance();
      final key = _v3Key('plain', 'default', 'session');
      final raw = jsonEncode(const [_message]);
      await prefs.setString(key, raw);
      final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
      expect(await LocalTranscriptStore.load('plain', 'session'), isNotEmpty);
      expect(
        (await LocalTranscriptStore.loadSnapshot('plain', 'session')).messages,
        isNotEmpty,
      );
      expect(
        await LocalTranscriptStore.listForConnection('plain'),
        hasLength(1),
      );
      expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
      expect(secure, isEmpty);
    });

    test('unexpected plaintext type is ignored without mutation', () async {
      final key = _v3Key('typed', 'default', 'session');
      SharedPreferences.setMockInitialValues({key: 7});
      final prefs = await SharedPreferences.getInstance();
      expect(await LocalTranscriptStore.load('typed', 'session'), isEmpty);
      expect(prefs.getInt(key), 7);
    });

    test('secure presence wins even when empty or corrupt', () async {
      final prefs = await SharedPreferences.getInstance();
      final key = _v3Key('precedence', 'default', 'session');
      await prefs.setString(key, jsonEncode(const [_message]));
      secure[key] = jsonEncode(const [
        {'role': 'assistant', 'content': 'secure wins'},
      ]);
      expect(
        (await LocalTranscriptStore.load(
          'precedence',
          'session',
        )).single['content'],
        'secure wins',
      );
      for (final secureRaw in ['', 'not-json']) {
        secure[key] = secureRaw;
        expect(
          await LocalTranscriptStore.load('precedence', 'session'),
          isEmpty,
        );
        expect(
          await LocalTranscriptStore.listForConnection('precedence'),
          isEmpty,
        );
      }
      expect(prefs.getString(key), isNotNull);
    });

    test('save inherits sticky truncation from plaintext v3', () async {
      final prefs = await SharedPreferences.getInstance();
      final key = _v3Key('sticky', 'default', 'session');
      final raw = jsonEncode({
        'version': 1,
        'older_history_truncated': true,
        'messages': const [_message],
      });
      await prefs.setString(key, raw);
      await LocalTranscriptStore.saveFromNewestFirst(
        'sticky',
        'session',
        const [
          {'role': 'assistant', 'content': 'new'},
        ],
      );
      final envelope = jsonDecode(secure[key]!) as Map<String, dynamic>;
      expect(envelope['older_history_truncated'], isTrue);
      expect(prefs.getString(key), raw);
    });

    test('secure read and write failures never degrade to plaintext', () async {
      final prefs = await SharedPreferences.getInstance();
      final key = _v3Key('failure', 'default', 'session');
      final raw = jsonEncode(const [_message]);
      await prefs.setString(key, raw);
      failingReadKey = key;
      await expectLater(
        LocalTranscriptStore.load('failure', 'session'),
        throwsA(isA<PlatformException>()),
      );
      failingReadKey = null;
      failingWriteKey = key;
      await expectLater(
        LocalTranscriptStore.saveFromNewestFirst('failure', 'session', const [
          _message,
        ]),
        throwsA(isA<PlatformException>()),
      );
      expect(prefs.getString(key), raw);
      expect(secure[key], isNull);
    });
  });

  test(
    'callback transcript implícito no toma prestado el owner reemplazo',
    () async {
      final stale = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'borrow',
        profile: 'profile',
        sessionId: 'session',
      );
      expect(LocalConversationCleanupFence.rehydrate(stale), isTrue);
      Future<void> lateCallback() => LocalTranscriptStore.saveFromNewestFirst(
        'borrow',
        'session',
        const [_message],
        profile: 'profile',
      );
      await LocalTranscriptStore.deleteForProfile('borrow', 'profile');
      LocalConversationCleanupFence.endLifecycle(stale);
      final replacement = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'borrow',
        profile: 'profile',
        sessionId: 'session',
      );
      expect(LocalConversationCleanupFence.rehydrate(replacement), isTrue);

      await expectLater(
        lateCallback(),
        throwsA(isA<LocalConversationWriteRejected>()),
      );
      expect(secure, isEmpty);
    },
  );

  test(
    'lifecycle no autoriza un scope real de almacenamiento distinto',
    () async {
      final victim = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'victim',
        profile: 'profile',
        sessionId: 'session',
      );
      expect(LocalConversationCleanupFence.rehydrate(victim), isTrue);
      await LocalTranscriptStore.deleteForConnection('victim');
      final other = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'other',
        profile: 'profile',
        sessionId: 'session',
      );
      expect(LocalConversationCleanupFence.rehydrate(other), isTrue);

      await expectLater(
        LocalTranscriptStore.saveFromNewestFirst(
          'victim',
          'session',
          const [_message],
          profile: 'profile',
          lifecycle: other,
        ),
        throwsA(isA<LocalConversationWriteRejected>()),
      );
      expect(
        await LocalTranscriptStore.load(
          'victim',
          'session',
          profile: 'profile',
        ),
        isEmpty,
      );
    },
  );

  group('REGRESSION_V5_PARTIAL_FAILURES', () {
    test('bulk deletes count identities rather than physical copies', () async {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(const [_message]);
      final first = _v3Key('delete', 'default', 'one');
      final second = _v3Key('delete', 'default', 'two');
      secure[first] = raw;
      await prefs.setString(first, raw);
      secure[second] = raw;
      expect(await LocalTranscriptStore.deleteForConnection('delete'), 2);
      expect(secure, isEmpty);
      expect(prefs.getKeys(), isEmpty);
      final profileKey = _v3Key('delete', 'profile', 'three');
      secure[profileKey] = raw;
      await prefs.setString(profileKey, raw);
      expect(
        await LocalTranscriptStore.deleteForProfile('delete', 'profile'),
        1,
      );
      expect(secure, isEmpty);
      expect(prefs.getKeys(), isEmpty);
    });

    test(
      'cleanup continues across secure enumeration and delete failures',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final raw = jsonEncode(const [_message]);
        final first = _v3Key('partial', 'default', 'one');
        final second = _v3Key('partial', 'default', 'two');
        await prefs.setString(first, raw);
        failReadAllCount = 2;
        await expectLater(
          LocalTranscriptStore.listForConnection('partial'),
          throwsA(isA<PlatformException>()),
        );
        await expectLater(
          LocalTranscriptStore.deleteForConnection('partial'),
          throwsA(isA<PlatformException>()),
        );
        expect(prefs.containsKey(first), isFalse);
        failReadAllCount = 0;
        secure[first] = raw;
        secure[second] = raw;
        await prefs.setString(first, raw);
        await prefs.setString(second, raw);
        failingDeleteKey = first;
        await expectLater(
          LocalTranscriptStore.deleteForProfile('partial', ''),
          throwsA(isA<PlatformException>()),
        );
        expect(prefs.getKeys(), isEmpty);
        expect(secure[first], raw);
        expect(secure[second], isNull);
        final clearKey = _v3Key('partial', 'default', 'clear');
        secure[clearKey] = raw;
        await prefs.setString(clearKey, raw);
        failingDeleteKey = clearKey;
        await expectLater(
          LocalTranscriptStore.clear('partial', 'clear'),
          throwsA(isA<PlatformException>()),
        );
        expect(prefs.containsKey(clearKey), isFalse);
      },
    );

    test(
      'bulk cleanup continues secure after prefs initialization fails and preserves first error',
      () async {
        final key = _v3Key('prefs-failure', 'default', 'session');
        secure[key] = jsonEncode(const [_message]);
        failingDeleteKey = key;
        SharedPreferencesStorePlatform.instance = _FailingGetAllPrefs();
        SharedPreferences.resetStatic();

        await expectLater(
          LocalTranscriptStore.deleteForConnection('prefs-failure'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'getAll failure',
            ),
          ),
        );

        expect(deletedSecureKeys, contains(key));
        expect(secure[key], isNotNull);
      },
    );

    test('ConnectionManager deletion removes v3 transcript recovery', () async {
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      addTearDown(manager.dispose);
      await manager.saveConnection(
        'local',
        '127.0.0.1',
        9119,
        String.fromCharCodes(const [116, 101, 115, 116]),
        kind: InstanceKind.localhost,
      );
      final connection = manager.getConnections().single;
      await LocalTranscriptStore.saveFromNewestFirst(
        connection.id,
        'session_with_underscores',
        const [_message],
      );
      final key = _v3Key(connection.id, 'default', 'session_with_underscores');
      expect(secure[key], isNotNull);

      await manager.deleteConnection(connection.id);

      expect(secure[key], isNull);
    });

    test(
      'ConnectionManager continues v3 transcript cleanup after outbox read failure',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final manager = await ConnectionManager.create(prefs);
        addTearDown(manager.dispose);
        await manager.saveConnection(
          'local',
          '127.0.0.1',
          9119,
          String.fromCharCodes(const [116, 101, 115, 116]),
          kind: InstanceKind.localhost,
        );
        final connection = manager.getConnections().single;
        await LocalTranscriptStore.saveFromNewestFirst(
          connection.id,
          'session_after_failure',
          const [_message],
        );
        final key = _v3Key(connection.id, 'default', 'session_after_failure');
        expect(secure[key], isNotNull);
        failingReadKey = 'chat_turn_outbox_v1';

        await manager.deleteConnection(connection.id);

        expect(secure[key], isNull);
      },
    );

    test('clear reports false and thrown plaintext removal', () async {
      final key = _v3Key('remove', 'default', 'session');
      final raw = jsonEncode(const [_message]);
      for (final throws in [false, true]) {
        final platform = _FailingPrefs({key: raw})
          ..returnFalse = !throws
          ..throwOnRemove = throws;
        SharedPreferencesStorePlatform.instance = platform;
        SharedPreferences.resetStatic();
        await expectLater(
          LocalTranscriptStore.clear('remove', 'session'),
          throwsA(isA<StateError>()),
        );
      }
    });
  });
}
