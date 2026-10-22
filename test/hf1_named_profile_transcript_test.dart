import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/recording_desktop_gateway.dart';

const _profile = 'pi';
const _root = 'session-live';
const _tip = 'session-continuation';
const _connectionId = 'hf1-named-profile';
const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

class _Gateway extends RecordingDesktopGateway {
  final profiles = <String>[];

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) {
    profiles.add(profile);
    return super.createForFirstSubmit(
      profile: profile,
      seedMessages: seedMessages,
      model: model,
    );
  }
}

/// Two listeners: the profile gateway has no own API key; Dashboard resolves
/// the root to its continuation and includes the ancestor's first turn.
class _Server {
  final rows = <Map<String, dynamic>>[];
  final gatewayReads = <Uri>[];
  final dashboardReads = <Uri>[];
  final statuses = <int>[];
  int status = 200;
  String resolvedId = _root;

  void addTurn(String prompt, String answer) {
    final timestamp = DateTime.now().millisecondsSinceEpoch / 1000 - .25;
    for (final (role, content) in [('user', prompt), ('assistant', answer)]) {
      final id = rows.length + 1;
      rows.add({
        'id': id,
        'session_id': id <= 2 ? _root : _tip,
        'role': role,
        'content': content,
        'timestamp': timestamp + id / 1000,
      });
    }
  }

  http.Client gateway() => MockClient((request) async {
    gatewayReads.add(request.url);
    // The gateway never routes a named profile via ?profile=.
    expect(request.url.queryParameters, isNot(contains('profile')));
    expect(request.url.path, startsWith('/p/$_profile/api/sessions/'));
    return http.Response('{}', 401);
  });

  DashboardClient dashboard() => DashboardClient(
    host: 'example.invalid',
    useHttps: true,
    manualToken: 'test-only',
    httpClientOverride: MockClient((request) async {
      dashboardReads.add(request.url);
      expect(request.url.path, matches(r'^/api/sessions/[^/]+/messages$'));
      expect(request.url.queryParameters['profile'], _profile);
      statuses.add(status);
      if (status != 200) return http.Response('{}', status);
      final query = request.url.queryParameters;
      // The reference server also pages reads that omit limit (500 latest).
      final limit = int.parse(query['limit'] ?? '500');
      final offset = int.parse(query['offset'] ?? '0');
      final end = math.max(0, rows.length - offset);
      final page = rows.sublist(math.max(0, end - limit), end);
      return http.Response(
        jsonEncode({
          'session_id': resolvedId,
          'profile': _profile,
          'messages': page,
          'pagination': {
            'limit': limit,
            'offset': offset,
            'order': 'latest',
            'returned': page.length,
          },
        }),
        200,
      );
    }),
  );
}

ActiveChat _chat(_Server server, _Gateway gateway, {bool fresh = true}) {
  final dashboard = server.dashboard();
  addTearDown(dashboard.close);
  final chat = ActiveChat(
    connection: SavedConnection(
      id: _connectionId,
      label: 'Named profile regression',
      host: 'example.invalid',
      port: 8642,
      useHttps: true,
      apiKey: 'test-only',
      kind: InstanceKind.vps,
    ),
    sessionId: fresh ? 'mobile-draft' : _root,
    sessionProfile: _profile,
    sessionTitle: 'Named profile transcript',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'https://example.invalid:8642',
      apiKey: 'test-only',
      httpClient: server.gateway(),
      profileDashboard: dashboard,
    ),
    transcriptDashboard: dashboard,
    desktopGateway: gateway,
    compressionRestoreStore: testCompressionRestoreStore(),
    allowUnownedDesktopSnapshotForTesting: true,
  );
  if (fresh) chat.markStoredSessionMissing();
  addTearDown(chat.dispose);
  return chat;
}

Future<void> _turn(
  ActiveChat chat,
  _Gateway gateway,
  _Server server,
  String prompt,
  String answer, {
  bool streaming = false,
}) async {
  expect(
    await chat.send(
      fullText: prompt,
      profile: _profile,
      model: 'hermes-agent',
      history: chat.buildHistory(),
    ),
    isTrue,
  );
  server.addTurn(prompt, answer);
  final done = chat.changes
      .firstWhere((event) => event == ActiveChatEvent.done)
      .timeout(const Duration(seconds: 5));
  if (streaming) {
    gateway.emit('message.start');
    gateway.emit('thinking.delta', {'text': 'Working'});
    gateway.emit('message.delta', {'text': answer});
    await Future<void>.delayed(Duration.zero);
  }
  gateway.emit('message.complete', {'text': answer});
  await done;
  await Future<void>.delayed(Duration.zero);
  expect(chat.state, ChatPipelineState.completed);
}

List<String> _contents(Iterable<Map<String, dynamic>> rows) => [
  for (final row in rows) '${row['role']}: ${row['content']}',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    LocalConversationCleanupFence.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async {
          final args = (call.arguments as Map).cast<String, dynamic>();
          switch (call.method) {
            case 'write':
              secure[args['key'] as String] = args['value'] as String;
              return null;
            case 'read':
              return secure[args['key']];
            case 'readAll':
              return Map<String, String>.of(secure);
            case 'delete':
              secure.remove(args['key']);
              return null;
          }
          return null;
        });
  });
  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
  });

  for (final persistence in ['ready', 'first-404', 'both-404']) {
    for (final streaming in [false, true]) {
      for (final identical in [false, true]) {
        test(
          'HF1 named profile two turns, persistence: $persistence, streaming: $streaming, '
          'identical legitimate turns: $identical',
          () async {
            final server = _Server()
              ..status = persistence == 'ready' ? 200 : 404;
            final gateway = _Gateway();
            final chat = _chat(server, gateway);
            final publications = <List<String>>[];
            final subscription = chat.changes.listen((_) {
              publications.add(
                _contents(
                  chat.messages.where(
                    (row) => (row['content'] as String? ?? '').isNotEmpty,
                  ),
                ),
              );
              expect(chat.messages, chat.uncachedPublicMessagesForTesting());
            });
            addTearDown(subscription.cancel);
            // Equal row ids in a different owner must not be borrowed.
            await LocalTranscriptStore.saveFromNewestFirst(
              _connectionId,
              _root,
              const [
                {
                  'id': 2,
                  'role': 'assistant',
                  'content': 'Other profile reply',
                },
                {'id': 1, 'role': 'user', 'content': 'Other profile prompt'},
              ],
              profile: 'default',
            );
            await _turn(
              chat,
              gateway,
              server,
              'Hello',
              'Hello back',
              streaming: streaming,
            );
            expect(_contents(chat.messages.reversed), [
              'user: Hello',
              'assistant: Hello back',
            ]);
            expect(chat.serverSessionId, _root);
            server
              ..status = persistence == 'both-404' ? 404 : 200
              ..resolvedId = _tip;
            final prompt = identical ? 'Hello' : 'New message';
            final answer = identical ? 'Hello back' : 'New reply';
            await _turn(
              chat,
              gateway,
              server,
              prompt,
              answer,
              streaming: streaming,
            );
            final expected = [
              'user: Hello',
              'assistant: Hello back',
              'user: $prompt',
              'assistant: $answer',
            ];
            expect(_contents(chat.messages.reversed), expected);
            server.status = 200;
            await chat.reconcileAfterResume();
            if (chat.hasEarlierMessages) await chat.loadEarlierMessages();
            expect(_contents(chat.messages.reversed), expected);
            expect(chat.messages.map((row) => row['id']).toSet(), {1, 2, 3, 4});
            expect(chat.hasEarlierMessages, isFalse);
            expect(chat.earlierMessagesLoadFailed, isFalse);
            expect(gateway.profiles, [_profile]);
            expect(server.gatewayReads, hasLength(1));
            expect(server.dashboardReads, isNotEmpty);
            expect(
              server.dashboardReads.first.queryParameters,
              containsPair('limit', '120'),
            );
            expect(
              server.dashboardReads.first.queryParameters,
              containsPair('order', 'latest'),
            );
            expect(
              server.dashboardReads.first.queryParameters,
              containsPair('offset', '0'),
            );
            if (persistence != 'ready') expect(server.statuses, contains(404));
            expect(publications, everyElement(hasLength(lessThanOrEqualTo(4))));
            await LocalTranscriptStore.saveFromNewestFirst(
              _connectionId,
              chat.serverSessionId,
              chat.messages,
              profile: _profile,
            );
            expect(
              _contents(
                await LocalTranscriptStore.load(
                  _connectionId,
                  chat.serverSessionId,
                  profile: _profile,
                ),
              ),
              expected,
            );
            expect(
              _contents(
                await LocalTranscriptStore.load(
                  _connectionId,
                  _root,
                  profile: 'default',
                ),
              ),
              ['user: Other profile prompt', 'assistant: Other profile reply'],
            );
            expect(
              await LocalTranscriptStore.load(
                _connectionId,
                chat.serverSessionId,
                profile: 'other',
              ),
              isEmpty,
            );
          },
        );
      }
    }
  }

  test(
    'HF1 named-profile latest-offset pages retain real earlier history',
    () async {
      final server = _Server()..resolvedId = _tip;
      for (var index = 0; index < 120; index++) {
        server.addTurn('Stored prompt $index', 'Stored reply $index');
      }
      final chat = _chat(server, _Gateway(), fresh: false);
      await chat.loadMessages(
        profile: _profile,
        expectedMessageCount: 240,
        passiveOnly: true,
      );
      expect(chat.messages, hasLength(120));
      expect(chat.hasEarlierMessages, isTrue);
      server.status = 503;
      expect(await chat.loadEarlierMessages(), isFalse);
      expect(chat.earlierMessagesLoadFailed, isTrue);
      server.status = 200;
      for (var page = 0; page < 4 && chat.hasEarlierMessages; page++) {
        await chat.loadEarlierMessages();
      }
      expect(chat.messages, hasLength(240));
      expect(chat.messages.map((row) => row['id']).toSet(), hasLength(240));
      expect(chat.hasEarlierMessages, isFalse);
      expect(chat.earlierMessagesLoadFailed, isFalse);
      expect(
        server.dashboardReads.map((uri) => uri.queryParameters['offset']),
        containsAllInOrder(['0', '120', '120', '240']),
      );
      expect(server.gatewayReads, hasLength(1));
    },
  );

  test(
    'HF1 a named-profile disk transcript is replaced by its resolved lineage',
    () async {
      final server = _Server()..resolvedId = _tip;
      server.addTurn('Hello', 'Hello back');
      server.addTurn('New message', 'New reply');
      await LocalTranscriptStore.saveFromNewestFirst(
        _connectionId,
        _root,
        server.rows.reversed.toList(),
        profile: _profile,
      );
      final disk = await LocalTranscriptStore.load(
        _connectionId,
        _root,
        profile: _profile,
      );
      // LocalTranscriptStore intentionally retains public content, not row ids.
      expect(disk.every((row) => !row.containsKey('id')), isTrue);
      final chat = _chat(server, _Gateway(), fresh: false);
      chat.seedReopenTranscript(disk.reversed.toList(), fromDisk: true);
      expect(chat.showingCachedTranscript, isTrue);
      expect(chat.bindSessionProfile('other'), _profile);
      await chat.loadMessages(
        profile: 'other',
        expectedMessageCount: 4,
        passiveOnly: true,
      );
      expect(_contents(chat.messages.reversed), _contents(server.rows));
      expect(chat.messages.map((row) => row['id']).toSet(), {1, 2, 3, 4});
      expect(chat.showingCachedTranscript, isFalse);
      expect(chat.hasEarlierMessages, isFalse);
      expect(chat.earlierMessagesLoadFailed, isFalse);
    },
  );
}
