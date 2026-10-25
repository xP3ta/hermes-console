import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/recording_desktop_gateway.dart';

/// The profile picked in the profile switcher: not the default one.
const _profile = 'social-writer';
const _session = 'session-live';

/// What onboarding saves since 1.3.0: the Dashboard address alone, no
/// Gateway port and no API key.
SavedConnection _dashboardOnly() => SavedConnection(
  id: 'hf1-dashboard-only',
  label: 'Dashboard only',
  host: '127.0.0.2',
  port: 9119,
  apiKey: '',
  dashboardUrl: 'http://127.0.0.2:9119',
  kind: InstanceKind.vps,
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

/// The Dashboard listener in the shapes of the reference server:
/// `hermes_cli/web_routers/sessions.py` `get_session_messages` reads the
/// store of `?profile=` and answers 404 «Session not found» from any other
/// store; a path outside `/api/` (such as `/p/<profile>/api/...`) is the SPA
/// catch-all of `hermes_cli/web_server_dashboard.py` `serve_spa`, which
/// returns `index.html`, or a JSON 404 on a headless server.
class _Dashboard {
  _Dashboard({this.headless = false});

  final bool headless;
  final rows = <Map<String, dynamic>>[];
  final messageReads = <Uri>[];
  final outsideApi = <Uri>[];

  void addTurn(String prompt, String answer) {
    final timestamp = DateTime.now().millisecondsSinceEpoch / 1000 - .25;
    for (final (role, content) in [('user', prompt), ('assistant', answer)]) {
      final id = rows.length + 1;
      rows.add({
        'id': id,
        'session_id': _session,
        'role': role,
        'content': content,
        'timestamp': timestamp + id / 1000,
      });
    }
  }

  http.Client client() => MockClient((request) async {
    final url = request.url;
    expect(
      url.port,
      9119,
      reason: 'a Dashboard-only connection has no Gateway',
    );
    if (url.path == '/') {
      return http.Response(
        '<script>window.__HERMES_SESSION_TOKEN__="t";</script>',
        200,
      );
    }
    if (!url.path.startsWith('/api/')) {
      outsideApi.add(url);
      return headless
          ? http.Response('{"error":"headless"}', 404)
          : http.Response('<!doctype html><html><body></body></html>', 200);
    }
    if (url.path == '/api/sessions/$_session/messages') {
      messageReads.add(url);
      final query = url.queryParameters;
      if (query['profile'] != _profile || rows.isEmpty) {
        return http.Response('{"detail":"Session not found"}', 404);
      }
      final limit = math.min(int.parse(query['limit'] ?? '500'), 500);
      final offset = int.parse(query['offset'] ?? '0');
      final end = math.max(0, rows.length - offset);
      final page = rows.sublist(math.max(0, end - limit), end);
      return http.Response(
        jsonEncode({
          'session_id': _session,
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
    }
    return http.Response('{"detail":"Not Found"}', 404);
  });
}

/// The chat ChatScreen opens after the switcher: owner pinned to the
/// switched profile, the connection's own [ApiClient.forConnection] client.
ActiveChat _chat(
  _Dashboard dashboard,
  _Gateway gateway, {
  bool fresh = true,
}) {
  final connection = _dashboardOnly();
  final transcriptDashboard = DashboardClient.lazy(
    connection,
    httpClientOverride: dashboard.client(),
  );
  addTearDown(transcriptDashboard.close);
  final chat = ActiveChat(
    connection: connection,
    sessionId: fresh ? 'mob-draft' : _session,
    sessionProfile: _profile,
    sessionTitle: 'Dashboard-only named profile',
    notifications: null,
    onTerminal: () {},
    api: ApiClient.forConnection(connection, httpClient: dashboard.client()),
    transcriptDashboard: transcriptDashboard,
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
  _Dashboard dashboard,
  String prompt,
  String answer,
) async {
  expect(
    await chat.send(
      fullText: prompt,
      profile: _profile,
      model: 'hermes-agent',
      history: chat.buildHistory(),
    ),
    isTrue,
  );
  dashboard.addTurn(prompt, answer);
  final done = chat.changes
      .firstWhere((event) => event == ActiveChatEvent.done)
      .timeout(const Duration(seconds: 5));
  gateway.emit('message.complete', {'text': answer});
  await done;
  await Future<void>.delayed(Duration.zero);
  expect(chat.state, ChatPipelineState.completed);
}

/// What the chat screen does once the turn settles: the resume refresh and,
/// while the island offers it, «Load earlier messages».
Future<void> _settle(ActiveChat chat) async {
  await chat.reconcileAfterResume();
  for (var i = 0; i < 3 && chat.hasEarlierMessages; i++) {
    await chat.loadEarlierMessages();
  }
}

List<String> _contents(Iterable<Map<String, dynamic>> rows) => [
  for (final row in rows) '${row['role']}: ${row['content']}',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    LocalConversationCleanupFence.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    DashboardClient.resetSharedPasswordSessionsForTesting();
  });

  group('ApiClient on a Dashboard-only connection', () {
    test('a named-profile transcript page is read from the Dashboard with '
        '?profile=, never from /p/<profile>/', () async {
      final dashboard = _Dashboard()
        ..addTurn('Hola', 'Hola, soy social-writer');
      final client = ApiClient.forConnection(
        _dashboardOnly(),
        httpClient: dashboard.client(),
      );
      addTearDown(client.close);

      final page = await client.getMessagesPage(_session, profile: _profile);

      expect(dashboard.outsideApi, isEmpty);
      expect(page.messages.map((row) => row['id']), [1, 2]);
      expect(dashboard.messageReads.single.queryParameters, {
        'limit': '120',
        'order': 'latest',
        'offset': '0',
        'include_compacted': 'true',
        'profile': _profile,
      });
      final whole = await client.getMessages(_session, profile: _profile);
      expect(whole.map((row) => row['id']), [1, 2]);
      expect(dashboard.outsideApi, isEmpty);
    });

    test('a default-profile page still carries no profile query', () async {
      final dashboard = _Dashboard();
      final client = ApiClient.forConnection(
        _dashboardOnly(),
        httpClient: dashboard.client(),
      );
      addTearDown(client.close);

      await expectLater(
        client.getMessagesPage(_session),
        throwsA(
          isA<CoreReadException>().having(
            (e) => e.kind,
            'kind',
            CoreReadErrorKind.notFound,
          ),
        ),
      );
      expect(
        dashboard.messageReads.single.queryParameters,
        isNot(contains('profile')),
      );
    });

    test('a named-profile 404 keeps its existing classification', () async {
      final client = ApiClient.forConnection(
        _dashboardOnly(),
        httpClient: _Dashboard().client(),
      );
      addTearDown(client.close);

      await expectLater(
        client.getMessagesPage(_session, profile: _profile),
        throwsA(
          isA<CoreReadException>().having(
            (e) => e.kind,
            'kind',
            CoreReadErrorKind.profileUnavailable,
          ),
        ),
      );
    });
  });

  for (final headless in [false, true]) {
    test('HF1 switcher -> new $_profile chat -> one turn shows no '
        'Messages missing on a Dashboard-only connection '
        '(headless: $headless)', () async {
      final dashboard = _Dashboard(headless: headless);
      final gateway = _Gateway();
      final chat = _chat(dashboard, gateway);

      await _turn(chat, gateway, dashboard, 'Hola', 'Hola, soy social-writer');
      await _settle(chat);

      expect(gateway.profiles, [_profile]);
      expect(dashboard.outsideApi, isEmpty);
      expect(dashboard.messageReads, isNotEmpty);
      expect(
        dashboard.messageReads.map((uri) => uri.queryParameters['profile']),
        everyElement(_profile),
      );
      expect(_contents(chat.messages.reversed), [
        'user: Hola',
        'assistant: Hola, soy social-writer',
      ]);
      expect(chat.messages.map((row) => row['id']).toSet(), {1, 2});
      expect(chat.hasEarlierMessages, isFalse);
      expect(chat.earlierMessagesLoadFailed, isFalse);
    });
  }

  test('HF1 two legitimately identical turns stay two turns', () async {
    final dashboard = _Dashboard();
    final gateway = _Gateway();
    final chat = _chat(dashboard, gateway);

    await _turn(chat, gateway, dashboard, 'Hola', 'Hola de nuevo');
    await _turn(chat, gateway, dashboard, 'Hola', 'Hola de nuevo');
    const expected = [
      'user: Hola',
      'assistant: Hola de nuevo',
      'user: Hola',
      'assistant: Hola de nuevo',
    ];
    expect(_contents(chat.messages.reversed), expected);
    await _settle(chat);

    expect(_contents(chat.messages.reversed), expected);
    expect(chat.messages.map((row) => row['id']).toSet(), {1, 2, 3, 4});
    expect(chat.hasEarlierMessages, isFalse);
    expect(chat.earlierMessagesLoadFailed, isFalse);
    expect(dashboard.outsideApi, isEmpty);
  });

  test('HF1 real earlier history of a named profile still loads', () async {
    final dashboard = _Dashboard();
    for (var index = 0; index < 120; index++) {
      dashboard.addTurn('Stored prompt $index', 'Stored reply $index');
    }
    final chat = _chat(dashboard, _Gateway(), fresh: false);

    await chat.loadMessages(
      profile: _profile,
      expectedMessageCount: 240,
      passiveOnly: true,
    );
    expect(chat.messages, hasLength(120));
    expect(chat.hasEarlierMessages, isTrue);
    expect(chat.earlierMessagesLoadFailed, isFalse);

    for (var page = 0; page < 3 && chat.hasEarlierMessages; page++) {
      await chat.loadEarlierMessages();
    }

    expect(chat.messages, hasLength(240));
    expect(chat.messages.map((row) => row['id']).toSet(), hasLength(240));
    expect(chat.hasEarlierMessages, isFalse);
    expect(chat.earlierMessagesLoadFailed, isFalse);
    expect(
      dashboard.messageReads.map((uri) => uri.queryParameters['offset']),
      containsAllInOrder(['0', '120']),
    );
    expect(
      dashboard.messageReads.map((uri) => uri.queryParameters['profile']),
      everyElement(_profile),
    );
    expect(dashboard.outsideApi, isEmpty);
  });
}
