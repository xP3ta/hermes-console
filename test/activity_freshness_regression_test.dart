import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

import 'support/in_memory_compression_restore_storage.dart';

import 'package:hermes_android/core/utils/assistant_content.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity_peer_test.dart' as peer;

const secret = 'PRIVATE_FRESH_REVIEW';
Map<String, dynamic> row(
  Map<String, dynamic> identity, {
  bool hidden = false,
  String content = secret,
  String role = 'assistant',
}) => {
  ...identity,
  'role': role,
  'content': content,
  if (hidden) 'hidden': true,
};
List<DesktopSessionMessage> parsed(List<Map<String, dynamic>> rows) =>
    rows.map((m) => DesktopSessionMessage.tryParse(m)!).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });
  const reconciler = DesktopSessionReconciler();

  for (final reverse in [false, true]) {
    test(
      'FRESH B3 complementary private snapshot identities order=$reverse',
      () {
        final partial = row({'row_id': 2}, hidden: true);
        final enriched = row({
          'row_id': 2,
          'message_id': 'opaque-A',
        }, hidden: true);
        final sources = reverse ? [enriched, partial] : [partial, enriched];
        final result = reconciler.overlayDurableDisplayMetadata([
          row({'message_id': 'opaque-A'}),
          row({'id': 2}),
          peer.publicUser,
        ], parsed(sources));
        expect(result.map((m) => m['content']), ['PUBLIC_USER']);
      },
    );
  }

  for (final firstByMessage in [false, true]) {
    test(
      'FRESH B3 enriched veto survives next incomplete snapshot firstByMessage=$firstByMessage',
      () async {
        final firstIdentity = firstByMessage
            ? {'message_id': 'opaque-A'}
            : {'row_id': 2};
        final lastIdentity = firstByMessage
            ? {'id': 2}
            : {'message_id': 'opaque-A'};
        final gateway = peer.PeerGateway(
          peer.snap([peer.publicSnapshot, row(firstIdentity, hidden: true)]),
        );
        var phase = 0;
        final chat = peer.chatFor(
          gateway,
          rest: (_) async => phase < 2
              ? http.Response('not found', 404)
              : peer.restRows([peer.publicUser, row(lastIdentity)]),
        );
        await chat.loadMessages();
        expect(jsonEncode(chat.messages), isNot(contains(secret)));
        phase = 1;
        gateway.snapshot = peer.snap([
          peer.publicSnapshot,
          row({'message_id': 'opaque-A', 'row_id': 2}, hidden: true),
        ]);
        await chat.loadMessages();
        expect(jsonEncode(chat.messages), isNot(contains(secret)));
        phase = 2;
        gateway.snapshot = peer.snap([peer.publicSnapshot], count: 3);
        final publications = <String>[];
        await chat.loadMessages(
          onMessagesPublished: () =>
              publications.add(jsonEncode(chat.messages)),
        );
        expect(publications, isNotEmpty);
        expect(jsonEncode(publications), isNot(contains(secret)));
        expect(jsonEncode(chat.messages), contains('PUBLIC_USER'));
      },
    );
  }

  test(
    'FRESH B3 replay of legitimate partial empty publication stays successful',
    () async {
      final gateway = peer.PeerGateway(
        peer.snap([peer.privateSnapshot], count: 2),
      );
      final chat = peer.chatFor(gateway);
      chat.replaceInternalMessagesForTesting([peer.privateRest]);
      var publications = 0;
      await chat.loadMessages(onMessagesPublished: () => publications++);
      expect(chat.messages, isEmpty);
      expect(chat.messagesLoaded, isTrue);
      expect(publications, greaterThan(0));
      await chat.loadMessages(onMessagesPublished: () => publications++);
      expect(chat.messages, isEmpty);
      expect(chat.messagesLoaded, isTrue);
    },
  );

  test(
    'FRESH B3 incremental revocations accumulate across omitted snapshots',
    () async {
      final gateway = peer.PeerGateway(
        peer.snap([peer.publicSnapshot, peer.privateSnapshot]),
      );
      var phase = 0;
      final chat = peer.chatFor(
        gateway,
        rest: (_) async => phase < 2
            ? http.Response('not found', 404)
            : peer.restRows([
                peer.publicUser,
                peer.privateRest,
                row({'id': 3}),
              ]),
      );
      await chat.loadMessages();
      phase = 1;
      gateway.snapshot = peer.snap([
        row({'row_id': 3}, hidden: true),
      ], count: 8);
      await chat.loadMessages();
      phase = 2;
      gateway.snapshot = peer.snap([], count: 8, omitted: true);
      final publications = <String>[];
      await chat.loadMessages(
        onMessagesPublished: () => publications.add(jsonEncode(chat.messages)),
      );
      expect(jsonEncode(publications), isNot(contains(secret)));
      expect(jsonEncode(publications), isNot(contains('PRIVATE_REVOKED')));
      expect(chat.messages.map((m) => m['content']), ['PUBLIC_USER']);
    },
  );

  test('FRESH B3 no identity or content-based cross-veto for public humans', () {
    const quoted =
        'Humano cita <|channel|>analysis<|message|>texto<|end|> y hidden:true';
    final publicRows = [
      row({'message_id': 'peer-B', 'row_id': 2}, content: quoted, role: 'user'),
      row(
        {'message_id': 'opaque-A', 'row_id': 3},
        content: quoted,
        role: 'user',
      ),
      row({'id': '2'}, content: quoted, role: 'user'),
      row({}, content: quoted, role: 'user'),
      row({'message_id': 'x', 'id': 'y'}, content: quoted, role: 'user'),
      row({'id': 99}, content: secret, role: 'user'),
    ];
    final result = reconciler.overlayDurableDisplayMetadata(
      publicRows,
      parsed([
        row({'message_id': 'opaque-A', 'row_id': 2}, hidden: true),
      ]),
    );
    expect(result, publicRows);
    expect(
      result
          .map((m) => normalizeTranscriptMessageForDisplay(m)!['content'])
          .toList(),
      publicRows.map((m) => m['content']).toList(),
    );
  });

  for (final conflictingRows in [
    [
      row({'message_id': 'A', 'row_id': 2}, hidden: true),
      row({'message_id': 'B', 'row_id': 2}, content: 'PUBLIC'),
    ],
    [
      row({'message_id': 'A', 'row_id': 2}, hidden: true),
      row({'message_id': 'A', 'row_id': 3}, content: 'PUBLIC'),
    ],
  ]) {
    test(
      'FRESH B3 contradictory coordinates do not classify ambiguous public peers ${jsonEncode(conflictingRows)}',
      () {
        final fallback = [
          row({'id': 2}, content: 'PUBLIC'),
          row({'message_id': 'A'}, content: 'PUBLIC'),
        ];
        expect(
          reconciler.overlayDurableDisplayMetadata(
            fallback,
            parsed(conflictingRows),
          ),
          fallback,
        );
      },
    );
  }

  test(
    'FRESH B3 explicit runtime snapshot must veto already cached private row',
    () async {
      final gateway = peer.PeerGateway(
        peer.snap([peer.publicSnapshot, peer.privateSnapshot]),
      );
      final chat = ActiveChat(
        connection: SavedConnection(
          id: 'peer',
          label: 'Peer',
          host: 'example.invalid',
          port: 443,
          apiKey: 'fixture',
          useHttps: true,
        ),
        sessionId: 'stored-peer',
        sessionTitle: 'Peer',
        notifications: null,
        onTerminal: () {},
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'fixture',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        desktopGateway: gateway,
        compressionRestoreStore: testCompressionRestoreStore(),
        // Production default: allowUnownedDesktopSnapshotForTesting=false.
      );
      addTearDown(chat.dispose);
      chat.replaceInternalMessagesForTesting([
        peer.privateRest,
        peer.publicUser,
      ]);
      expect(
        await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
        isTrue,
      );
      expect(jsonEncode(chat.messages), isNot(contains('PRIVATE_REVOKED')));
      expect(jsonEncode(chat.messages), contains('PUBLIC_USER'));
    },
  );

  const parserCases = {
    'classic mismatched closure':
        '<think>PRIVATE_HEAD</thinking>PRIVATE_FRESH_REVIEW',
    'nested harmony think':
        '<|think|>PRIVATE_HEAD<|think|>INNER<|/think|>PRIVATE_FRESH_REVIEW<|/think|>PUBLIC',
  };
  for (final entry in parserCases.entries) {
    test('FRESH B2 ${entry.key} cannot release private tail', () {
      final raw = entry.value;
      final finalText = finalizedPublicAssistantText(raw);
      final streamingText = streamingPublicAssistantText(raw);
      final persisted = reconciler.project(
        peer.snap([
          row({'id': 2}, content: raw),
        ]),
      );
      final display = normalizeTranscriptMessageForDisplay(
        row({'id': 2}, content: raw),
      );
      expect(finalText, isNot(contains(secret)));
      expect(streamingText, isNot(contains(secret)));
      expect(
        jsonEncode(persisted.messagesNewestFirst),
        isNot(contains(secret)),
      );
      expect(jsonEncode(display), isNot(contains(secret)));
    });
  }

  test(
    'FRESH B1 independent delimiter styles preserve public UTF16 and exclude private every prefix',
    () {
      const styles = ['<|NAME|>', '<|NAME｜>', '<｜NAME|>', '<｜NAME｜>'];
      for (final a in styles) {
        for (final b in styles) {
          for (final c in styles) {
            final raw =
                '${a.replaceAll('NAME', 'channel')}analysis${b.replaceAll('NAME', 'message')}$secret${c.replaceAll('NAME', 'end')}<|channel|>final<|message|>PUBLIC ｜ 😀<|end|>';
            for (var i = 0; i <= raw.length; i++) {
              expect(
                streamingPublicAssistantText(raw.substring(0, i)),
                isNot(contains(secret)),
                reason: '$a $b $c offset=$i',
              );
            }
            expect(finalizedPublicAssistantText(raw), 'PUBLIC ｜ 😀');
          }
        }
      }
    },
  );

  test(
    'FRESH O1 exact raw offset map and correction sides preserve code units',
    () {
      const prefix =
          '<|channel｜>analysis<｜message|>PRIVATE<|end｜><｜channel|>final<|message｜>';
      const body = 'A \t😀 B｜\nC';
      const suffix = '<｜end|>';
      const raw = '$prefix$body$suffix';
      final projection = projectPublicAssistantText(raw, streaming: true);
      for (var i = 0; i <= raw.length; i++) {
        final expected = (i - prefix.length).clamp(0, body.length);
        expect(
          projection.publicOffsetAtRawOffset(i),
          expected,
          reason: 'raw offset=$i',
        );
        expect(
          projection.text.substring(0, expected).codeUnits,
          body.substring(0, expected).codeUnits,
        );
      }
    },
  );

  for (final withFinalText in [false, true]) {
    test(
      'FRESH B4 terminal without valid envelope preserves literal withFinalText=$withFinalText',
      () async {
        final gateway = peer.PeerGateway(
          DesktopSessionSnapshot.fromJson(
            {
              'session_id': 'runtime-peer',
              'session_key': 'stored-peer',
              'message_count': 1,
              'messages': [peer.publicSnapshot],
              'running': true,
              'inflight': {'assistant': '', 'streaming': true},
            },
            requestedStoredSessionId: 'stored-peer',
            created: false,
            method: 'session.resume',
          ),
        );
        final chat = peer.chatFor(gateway);
        await chat.loadMessages();
        const raw = 'PUBLIC <｜start｜>not an envelope';
        gateway.emit('message.delta', {'text': raw});
        final flushed = chat.changes.firstWhere(
          (event) => event == ActiveChatEvent.toolProgress,
        );
        gateway.emit('tool.start', {'name': 'test'});
        await flushed.timeout(const Duration(seconds: 2));
        if (withFinalText) {
          final done = chat.changes.firstWhere(
            (event) => event == ActiveChatEvent.done,
          );
          gateway.emit('message.complete', {'text': raw});
          await done.timeout(const Duration(seconds: 2));
        } else {
          gateway.emit('message.complete', const {});
          await Future<void>.delayed(Duration.zero);
          expect(chat.state, isNot(ChatPipelineState.completed));
        }
        expect(
          chat.messages
              .where((m) => m['role'] == 'assistant')
              .single['content'],
          withFinalText ? raw : 'PUBLIC',
        );
      },
    );
  }
}
