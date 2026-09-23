import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/utils/assistant_content.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

DesktopSessionSnapshot _snapshot(Map<String, dynamic> json) =>
    DesktopSessionSnapshot.fromJson(
      json,
      requestedStoredSessionId: 'stored-privacy',
      created: false,
      method: 'session.resume',
    );

class _EmptyFenceStorage implements CompressionRestoreStorage {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

class _PrivacySnapshotGateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final DesktopSessionSnapshot privacySnapshot;

  _PrivacySnapshotGateway(this.privacySnapshot);

  @override
  Stream<TuiGatewayEvent> get events => const Stream<TuiGatewayEvent>.empty();

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => privacySnapshot;

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => throw UnsupportedError('create is outside this privacy test');

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => throw UnsupportedError('legacy resume is outside this privacy test');

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> close() async {}
}

void main() {
  const reconciler = DesktopSessionReconciler();
  const cases = <String, String>{
    'mixed-bars': '<|channel｜>analysis<|message｜>PRIVATE_MIXED<|end｜>',
    'mixed-message': '<｜channel｜>analysis<|message｜>PRIVATE_MIXED<｜end｜>',
    'public-to-private-start':
        '<｜start｜>assistant<｜channel｜>final<｜message｜>PUBLIC<｜start｜>assistant<｜channel｜>analysis<｜message｜>PRIVATE_NESTED<｜end｜>',
    'nested-channel':
        '<｜channel｜>final<｜message｜>PUBLIC<｜channel｜>analysis<｜message｜>PRIVATE_NESTED<｜end｜>',
    'future-with-less-than':
        '<｜channel｜>future<x<｜message｜>PRIVATE_UNKNOWN<｜end｜><｜channel｜>final<｜message｜>PUBLIC<｜end｜>',
  };
  for (final entry in cases.entries) {
    test(
      'adversarial fail closed ${entry.key} through persisted/inflight/display',
      () {
        final raw = entry.value;
        final projection = reconciler.project(
          _snapshot({
            'session_id': 'runtime-adversarial',
            'messages': [
              {'role': 'assistant', 'content': raw},
            ],
            'inflight': {'assistant': raw, 'streaming': true},
            'running': true,
          }),
        );
        final publicRows = projection.messagesNewestFirst
            .map((m) => normalizeTranscriptMessageForDisplay(m))
            .toList();
        expect(
          jsonEncode(publicRows),
          isNot(contains('PRIVATE')),
          reason: entry.key,
        );
      },
    );
  }
  test('adversarial private to public start without end preserves final', () {
    const raw =
        '<｜start｜>assistant<｜channel｜>analysis<｜message｜>PRIVATE<｜start｜>assistant<｜channel｜>final<｜message｜>PUBLIC<｜end｜>';
    expect(streamingPublicAssistantText(raw), 'PUBLIC');
  });
  test(
    'adversarial persisted ordinary text with no valid envelope preserved',
    () {
      const raw = 'PUBLIC <｜start｜>not an envelope';
      final display = normalizeTranscriptMessageForDisplay({
        'role': 'assistant',
        'content': raw,
      });
      expect(display?['content'], raw);
    },
  );
  test('adversarial correction preserves public whitespace ownership', () {
    const raw = '<｜channel｜>final<｜message｜>A B<｜end｜>';
    final projection = reconciler.project(
      _snapshot({
        'session_id': 'runtime-offset',
        'inflight': {
          'assistant': raw,
          'streaming': true,
          'corrections': ['CORRECT'],
          'correction_offsets': [raw.indexOf('A B') + 2],
        },
        'running': true,
      }),
    );
    expect(
      projection.messagesNewestFirst.reversed.map((m) => m['content']).toList(),
      ['A ', 'CORRECT', 'B'],
    );
  });
  test(
    'adversarial classified snapshot vetoes same-id unclassified REST',
    () async {
      final snap = _snapshot({
        'session_id': 'runtime-rest-privacy',
        'session_key': 'stored-privacy',
        'message_count': 2,
        'messages': [
          {'role': 'user', 'content': 'PUBLIC_USER', 'row_id': 1},
          {
            'role': 'assistant',
            'content': 'PRIVATE_REST',
            'row_id': 2,
            'hidden': true,
          },
        ],
      });
      final requests = <String>[];
      final chat = ActiveChat(
        connection: SavedConnection(
          id: 'peer-rest',
          label: 'Peer',
          host: 'example.invalid',
          port: 443,
          apiKey: 'test',
          useHttps: true,
        ),
        sessionId: 'stored-privacy',
        sessionTitle: 'Privacy',
        notifications: null,
        onTerminal: () {},
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'test',
          httpClient: MockClient((request) async {
            requests.add(request.url.path);
            return http.Response(
              jsonEncode({
                'messages': [
                  {'role': 'user', 'content': 'PUBLIC_USER', 'id': 1},
                  {'role': 'assistant', 'content': 'PRIVATE_REST', 'id': 2},
                ],
                'total': 2,
                'has_more': false,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
        desktopGateway: _PrivacySnapshotGateway(snap),
        compressionRestoreStore: CompressionRestoreStore(
          storage: _EmptyFenceStorage(),
        ),
        allowUnownedDesktopSnapshotForTesting: true,
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      expect(requests, isNotEmpty);
      expect(
        jsonEncode(chat.messages),
        isNot(contains('PRIVATE_REST')),
        reason: requests.toString(),
      );
      expect(jsonEncode(chat.messages), contains('PUBLIC_USER'));
    },
  );
  for (final classifier in <Map<String, dynamic>>[
    {'hidden': true},
    {'channel': 'analysis'},
    {'reasoning': true},
  ]) {
    test('cached row revoked by authoritative snapshot $classifier', () async {
      final snap = _snapshot({
        'session_id': 'runtime-cache-revoke',
        'session_key': 'stored-privacy',
        'message_count': 2,
        'messages': [
          {'role': 'user', 'content': 'PUBLIC_USER', 'row_id': 1},
          {
            'role': 'assistant',
            'content': 'PRIVATE_REVOKED',
            'row_id': 2,
            ...classifier,
          },
        ],
      });
      final chat = ActiveChat(
        connection: SavedConnection(
          id: 'peer-cache',
          label: 'Peer',
          host: 'example.invalid',
          port: 443,
          apiKey: 'test',
          useHttps: true,
        ),
        sessionId: 'stored-privacy',
        sessionTitle: 'Privacy',
        notifications: null,
        onTerminal: () {},
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'test',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        desktopGateway: _PrivacySnapshotGateway(snap),
        compressionRestoreStore: CompressionRestoreStore(
          storage: _EmptyFenceStorage(),
        ),
        allowUnownedDesktopSnapshotForTesting: true,
      );
      addTearDown(chat.dispose);
      chat.replaceInternalMessagesForTesting([
        {'role': 'assistant', 'content': 'PRIVATE_REVOKED', 'id': 2},
        {'role': 'user', 'content': 'PUBLIC_USER', 'id': 1},
      ]);
      expect(jsonEncode(chat.messages), contains('PRIVATE_REVOKED'));
      await chat.loadMessages();
      expect(jsonEncode(chat.messages), contains('PUBLIC_USER'));
      expect(jsonEncode(chat.messages), isNot(contains('PRIVATE_REVOKED')));
    });
  }
  test(
    'adversarial matrix case whitespace future and fullwidth every offset',
    () {
      for (final bars in const ['|', '｜']) {
        String token(String name) => '<$bars$name$bars>';
        for (final channel in const [
          '',
          ' ',
          ' AnAlYsIs\n',
          'reasoning',
          'think',
          'tool',
          'unknown',
          'future-channel',
          'finаl',
          'final\u200b',
        ]) {
          final raw =
              '${token('start')}assistant${token('channel')}$channel${token('message')}PRIVATE${token('end')}${token('channel')}final${token('message')}PUBLIC ｜ prose${token('end')}';
          for (var boundary = 0; boundary <= raw.length; boundary++) {
            expect(
              streamingPublicAssistantText(raw.substring(0, boundary)),
              isNot(contains('PRIVATE')),
              reason: '$channel $boundary',
            );
          }
          expect(streamingPublicAssistantText(raw), 'PUBLIC ｜ prose');
        }
      }
    },
  );
  test(
    'adversarial corrections every offset preserve fullstream public content',
    () {
      const raw =
          '<｜channel｜>analysis<｜message｜>PRIVATE<｜end｜><｜channel｜>final<｜message｜>PUBLIC ｜ 😀<｜end｜>';
      for (var boundary = 0; boundary <= raw.length; boundary++) {
        final rows = reconciler
            .project(
              _snapshot({
                'session_id': 'runtime-all-offsets',
                'running': true,
                'inflight': {
                  'assistant': raw,
                  'streaming': true,
                  'corrections': ['CORRECT'],
                  'correction_offsets': [boundary],
                },
              }),
            )
            .messagesNewestFirst;
        final text = rows.reversed
            .where((m) => m['role'] == 'assistant')
            .map((m) => m['content'])
            .join();
        expect(text, 'PUBLIC ｜ 😀', reason: 'offset=$boundary');
        expect(rows.where((m) => m['_steer'] == true).length, 1);
      }
    },
  );
  test(
    'adversarial public channels case whitespace and Unicode every offset',
    () {
      for (final channel in const [' FINAL \n', ' CoMmEnTaRy ']) {
        final opener = '<｜channel｜>$channel<｜message｜>';
        const body = 'PUBLIC ｜ 😀';
        final raw = '$opener$body<｜end｜>';
        for (var boundary = 0; boundary <= raw.length; boundary++) {
          expect(
            streamingPublicAssistantText(raw.substring(0, boundary)),
            body
                .substring(0, (boundary - opener.length).clamp(0, body.length))
                .trim(),
          );
        }
      }
    },
  );
  test('adversarial contradictory row metadata fails closed', () {
    for (final fields in <Map<String, dynamic>>[
      {'hidden': false, 'channel': 'final', 'reasoning': true},
      {'hidden': true, 'channel': 'final'},
      {'hidden': null, 'reasoning': false},
      {'channel': '', 'display_kind': 'public'},
    ]) {
      final rows = reconciler
          .project(
            _snapshot({
              'session_id': 'runtime-conflict',
              'messages': [
                {'role': 'assistant', 'content': 'PRIVATE', ...fields},
                {'role': 'user', 'content': 'PUBLIC_USER'},
              ],
            }),
          )
          .messagesNewestFirst;
      expect(jsonEncode(rows), isNot(contains('PRIVATE')));
      expect(jsonEncode(rows), contains('PUBLIC_USER'));
    }
  });
}
