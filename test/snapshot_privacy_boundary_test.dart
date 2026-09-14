import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_compression_fence_store.dart';
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

class _EmptyFenceStorage implements DesktopCompressionFenceStorage {
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

  test('raw private classifiers are rejected before snapshot projection', () {
    final projection = reconciler.project(
      _snapshot({
        'session_id': 'runtime-privacy',
        'session_key': 'stored-privacy',
        'messages': const [
          {'role': 'assistant', 'content': 'PRIVATE_HIDDEN', 'hidden': true},
          {
            'role': 'assistant',
            'content': 'PRIVATE_IS_HIDDEN',
            'is_hidden': true,
          },
          {
            'role': 'assistant',
            'content': 'PRIVATE_IS_REASONING',
            'is_reasoning': true,
          },
          {
            'role': 'assistant',
            'content': 'PRIVATE_REASONING_BOOL',
            'reasoning': true,
          },
          {
            'role': 'assistant',
            'content': 'PRIVATE_CHANNEL',
            'channel': 'analysis',
          },
          {'role': 'assistant', 'content': 'PRIVATE_KIND', 'kind': 'reasoning'},
          {
            'role': 'assistant',
            'content': 'PRIVATE_CONTENT_TYPE',
            'content_type': 'reasoning',
          },
          {'role': 'user', 'content': 'PUBLIC_USER'},
          {'role': 'assistant', 'content': 'PUBLIC_FINAL'},
        ],
      }),
    );

    final encoded = projection.messagesNewestFirst.toString();
    expect(encoded, isNot(contains('PRIVATE_')));
    expect(encoded, contains('PUBLIC_USER'));
    expect(encoded, contains('PUBLIC_FINAL'));
    expect(projection.messagesNewestFirst, hasLength(2));
  });

  test(
    'ActiveChat hydration keeps raw privacy classifiers until projection',
    () async {
      final snapshot = _snapshot({
        'session_id': 'runtime-active-privacy',
        'session_key': 'stored-privacy',
        'messages': const [
          {'role': 'assistant', 'content': 'PRIVATE_HIDDEN', 'hidden': true},
          {
            'role': 'assistant',
            'content': 'PRIVATE_CHANNEL',
            'channel': 'analysis',
          },
          {
            'role': 'assistant',
            'content': 'PRIVATE_REASONING_BOOL',
            'reasoning': true,
          },
          {'role': 'user', 'content': 'PUBLIC_USER'},
          {'role': 'assistant', 'content': 'PUBLIC_FINAL'},
        ],
      });
      final gateway = _PrivacySnapshotGateway(snapshot);
      final chat = ActiveChat(
        connection: SavedConnection(
          id: 'active-privacy',
          label: 'Active privacy',
          host: '10.0.0.2',
          port: 8642,
          apiKey: '',
        ),
        sessionId: 'stored-privacy',
        sessionTitle: 'Privacy',
        notifications: null,
        onTerminal: () {},
        api: ApiClient(
          baseUrl: 'http://10.0.0.2:8642',
          apiKey: '',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        desktopGateway: gateway,
        compressionFenceStore: DesktopCompressionFenceStore(
          storage: _EmptyFenceStorage(),
        ),
        allowUnownedDesktopSnapshotForTesting: true,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      final encoded = jsonEncode(chat.messages);
      expect(encoded, isNot(contains('PRIVATE_')));
      expect(encoded, contains('PUBLIC_USER'));
      expect(encoded, contains('PUBLIC_FINAL'));
      expect(chat.messages, hasLength(2));
    },
  );

  test('Harmony channels publish only the typed public allowlist', () {
    const expectations = <String, String>{
      'final': 'PUBLIC_FINAL',
      'commentary': 'PUBLIC_COMMENTARY',
      'analysis': '',
      'reasoning': '',
      'think': '',
      'tool': '',
      'unknown': '',
      'future_channel': '',
      'future-channel': '',
      'future.channel': '',
      '123': '',
    };

    for (final entry in expectations.entries) {
      final body = entry.value.isEmpty
          ? 'PRIVATE_${entry.key.toUpperCase()}'
          : entry.value;
      final opener = '<｜channel｜>${entry.key}<｜message｜>';
      final raw = '$opener$body<｜end｜>';
      for (var boundary = 1; boundary <= raw.length; boundary++) {
        final visibleLength = (boundary - opener.length).clamp(0, body.length);
        expect(
          streamingPublicAssistantText(raw.substring(0, boundary)),
          entry.value.isEmpty ? '' : body.substring(0, visibleLength).trim(),
          reason: 'channel=${entry.key} boundary=$boundary',
        );
      }
    }
    expect(streamingPublicAssistantText('PUBLIC_USER'), 'PUBLIC_USER');
  });

  test(
    'DesktopSessionReconciler fails closed for fragmented private channels',
    () {
      for (final channel in const [
        'reasoning',
        'analysis',
        'think',
        'unknown',
        'future',
        'future-channel',
        'future.channel',
        '123',
      ]) {
        final raw =
            '<｜channel｜>$channel<｜message｜>PRIVATE_${channel.toUpperCase()}<｜end｜>'
            '<｜channel｜>final<｜message｜>PUBLIC_FINAL<｜end｜>';
        for (var boundary = 1; boundary <= raw.length; boundary++) {
          final projection = reconciler.project(
            _snapshot({
              'session_id': 'runtime-harmony-$channel-$boundary',
              'session_key': 'stored-privacy',
              'running': true,
              'inflight': {
                'streaming': true,
                'assistant': raw.substring(0, boundary),
              },
            }),
          );
          final encoded = jsonEncode(projection.messagesNewestFirst);
          expect(encoded, isNot(contains('PRIVATE_')));
        }
        expect(
          reconciler
              .project(
                _snapshot({
                  'session_id': 'runtime-harmony-$channel-final',
                  'session_key': 'stored-privacy',
                  'running': true,
                  'inflight': {'streaming': true, 'assistant': raw},
                }),
              )
              .messagesNewestFirst
              .first['content'],
          'PUBLIC_FINAL',
        );
      }
    },
  );

  test('Harmony preserves public body code units at every boundary', () {
    const body = 'PUBLIC ｜ prose | exact';
    const opener = '<｜channel｜>final<｜message｜>';
    const closer = '<｜end｜>';
    const raw = '$opener$body$closer';

    for (var boundary = 1; boundary <= raw.length; boundary++) {
      final visibleBodyLength = (boundary - opener.length).clamp(
        0,
        body.length,
      );
      expect(
        streamingPublicAssistantText(raw.substring(0, boundary)),
        body.substring(0, visibleBodyLength).trim(),
        reason: 'boundary=$boundary',
      );
    }
    expect(streamingPublicAssistantText('PUBLIC ｜ prose'), 'PUBLIC ｜ prose');
  });

  test('Harmony fullwidth remains private at every streaming boundary', () {
    const variants = [
      '<\uFF5Cstart\uFF5C>assistant<\uFF5Cchannel\uFF5C>analysis'
          '<\uFF5Cmessage\uFF5C>PRIVATE_HARMONY<\uFF5Cend\uFF5C>'
          '<\uFF5Cstart\uFF5C>assistant<\uFF5Cchannel\uFF5C>final'
          '<\uFF5Cmessage\uFF5C>PUBLIC_FINAL<\uFF5Cend\uFF5C>',
      '<｜start｜>assistant<｜channel｜>analysis<｜message｜>'
          'PRIVATE_HARMONY<｜end｜><｜start｜>assistant<｜channel｜>final<｜message｜>'
          'PUBLIC_FINAL<｜end｜>',
      '<｜start｜>assistant<｜channel｜>analysis<｜message｜>'
          'PRIVATE_HARMONY<｜end｜><｜channel｜>final<｜message｜>'
          'PUBLIC_FINAL<｜end｜>',
    ];

    for (final raw in variants) {
      final publicStart = raw.indexOf('PUBLIC_FINAL');
      for (var boundary = 1; boundary <= raw.length; boundary++) {
        final projected = streamingPublicAssistantText(
          raw.substring(0, boundary),
        );
        expect(projected, isNot(contains('PRIVATE_HARMONY')));
        expect(projected, isNot(contains('analysis')));
        expect(projected, isNot(contains('assistant')));
        if (boundary <= publicStart) {
          expect(
            projected,
            isEmpty,
            reason: 'boundary=$boundary raw=${raw.substring(0, boundary)}',
          );
        }
      }
      expect(streamingPublicAssistantText(raw), 'PUBLIC_FINAL', reason: raw);
    }
  });

  test(
    'snapshot inflight assistant publishes only clean final Harmony text',
    () {
      final projection = reconciler.project(
        _snapshot({
          'session_id': 'runtime-inflight-privacy',
          'session_key': 'stored-privacy',
          'running': true,
          'inflight': const {
            'streaming': true,
            'assistant':
                '<\uFF5Cstart\uFF5C>assistant<\uFF5Cchannel\uFF5C>analysis'
                '<\uFF5Cmessage\uFF5C>PRIVATE_INFLIGHT<\uFF5Cend\uFF5C>'
                '<\uFF5Cstart\uFF5C>assistant<\uFF5Cchannel\uFF5C>final'
                '<\uFF5Cmessage\uFF5C>PUBLIC_INFLIGHT<\uFF5Cend\uFF5C>',
          },
        }),
      );

      final encoded = projection.messagesNewestFirst.toString();
      expect(encoded, contains('PUBLIC_INFLIGHT'));
      expect(encoded, isNot(contains('PRIVATE_INFLIGHT')));
      expect(encoded, isNot(contains('｜')));
    },
  );

  test(
    'ActiveChat public snapshot cannot retain a newly-private stable row',
    () {
      final service = ActiveChatService();
      addTearDown(service.dispose);
      final chat = service.attach(
        connection: SavedConnection(
          id: 'snapshot-privacy',
          label: 'Snapshot privacy',
          host: '10.0.0.1',
          port: 8642,
          apiKey: 'test-key',
        ),
        sessionId: 'stored-privacy',
        sessionTitle: 'Snapshot privacy',
        api: ApiClient(
          baseUrl: 'http://10.0.0.1:8642',
          apiKey: 'test-key',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
      );
      final stableRow = <String, dynamic>{
        'message_id': 'stable-row',
        'role': 'assistant',
        'content': 'PUBLIC_CACHED',
      };
      chat.replaceInternalMessagesForTesting([stableRow]);

      final first = chat.messages;
      expect(first.single['content'], 'PUBLIC_CACHED');

      stableRow
        ..['content'] = 'PRIVATE_CACHED'
        ..['channel'] = 'analysis';
      final second = chat.messages;

      expect(second, isEmpty);
      expect(jsonEncode(second), isNot(contains('PRIVATE_CACHED')));
    },
  );

  test(
    'authoritative all-private snapshot clears an old public cache',
    () async {
      final snapshot = _snapshot({
        'session_id': 'runtime-all-private',
        'session_key': 'stored-privacy',
        'message_count': 1,
        'messages': const [
          {
            'row_id': 7,
            'role': 'assistant',
            'content': 'PRIVATE_ONLY',
            'channel': 'analysis',
          },
        ],
      });
      final chat = ActiveChat(
        connection: SavedConnection(
          id: 'all-private',
          label: 'All private',
          host: 'example.invalid',
          port: 443,
          apiKey: '',
          useHttps: true,
        ),
        sessionId: 'stored-privacy',
        sessionTitle: 'Privacy',
        notifications: null,
        onTerminal: () {},
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: '',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        desktopGateway: _PrivacySnapshotGateway(snapshot),
        compressionFenceStore: DesktopCompressionFenceStore(
          storage: _EmptyFenceStorage(),
        ),
        allowUnownedDesktopSnapshotForTesting: true,
      );
      addTearDown(chat.dispose);
      chat.replaceInternalMessagesForTesting(const [
        {'id': 7, 'role': 'assistant', 'content': 'PRIVATE_ONLY'},
      ]);

      await chat.loadMessages();

      expect(chat.messages, isEmpty);
    },
  );
}
