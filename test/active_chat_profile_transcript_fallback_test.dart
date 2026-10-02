import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryFenceStorage implements CompressionRestoreStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

/// Lifecycle gateway whose resume acknowledges a deferred (hydrating) history,
/// exactly like Hermes Agent 0.20 for a cold per-profile bot session.
class _HydratingGateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  int resumeCalls = 0;
  String? lastProfile;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

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
  }) async {
    resumeCalls += 1;
    lastProfile = profile;
    return DesktopSessionSnapshot.fromJson(
      const {
        'session_id': 'runtime-bot',
        'session_key': 'stored-bot',
        'message_count': 2,
        'hydrating': true,
        'messages': <Object>[],
      },
      requestedStoredSessionId: storedSessionId,
      created: false,
      method: 'session.resume',
    );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => throw StateError('must not create while loading');

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => throw StateError('legacy resume must not run while loading');

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
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

const _rows = [
  {'id': 1, 'role': 'user', 'content': 'hola bot'},
  {'id': 2, 'role': 'assistant', 'content': 'hola humano'},
];

Map<String, Object?> _page(http.Request request) => {
  'session_id': 'stored-bot',
  'messages': _rows,
  'pagination': {
    'limit': int.parse(request.url.queryParameters['limit']!),
    'offset': int.parse(request.url.queryParameters['offset']!),
    'order': 'latest',
    'returned': _rows.length,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final connection = SavedConnection(
    id: 'profile-fallback',
    label: 'profile-fallback',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'main-profile-key',
    kind: InstanceKind.vps,
  );

  ({
    ActiveChat chat,
    _HydratingGateway gateway,
    List<Uri> gatewayReads,
    List<Uri> dashboardReads,
    List<int> hydrationWaits,
  })
  build({required int gatewayStatus}) {
    final hydrationWaits = <int>[];
    final gatewayReads = <Uri>[];
    final dashboardReads = <Uri>[];
    final gateway = _HydratingGateway();
    final chat = ActiveChat(
      connection: connection,
      sessionId: 'stored-bot',
      sessionTitle: 'Bot',
      sessionProfile: 'research',
      notifications: null,
      onTerminal: () {},
      api: ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'main-profile-key',
        httpClient: MockClient((request) async {
          gatewayReads.add(request.url);
          if (gatewayStatus != 200) return http.Response('{}', gatewayStatus);
          return http.Response(jsonEncode(_page(request)), 200);
        }),
      ),
      transcriptDashboard: DashboardClient(
        host: '127.0.0.1',
        manualToken: 'dashboard-token',
        httpClientOverride: MockClient((request) async {
          dashboardReads.add(request.url);
          return http.Response(jsonEncode(_page(request)), 200);
        }),
      ),
      desktopGateway: gateway,
      compressionRestoreStore: CompressionRestoreStore(
        storage: _MemoryFenceStorage(),
      ),
      allowUnownedDesktopSnapshotForTesting: true,
      // The server-side hydration event never arrives in this harness: any
      // wait on it would hang the open instead of showing the Dashboard page.
      historyHydrationAwaiter: () {
        hydrationWaits.add(hydrationWaits.length);
        return Completer<bool>().future;
      },
    );
    return (
      chat: chat,
      gateway: gateway,
      gatewayReads: gatewayReads,
      dashboardReads: dashboardReads,
      hydrationWaits: hydrationWaits,
    );
  }

  test('an unauthorized profile gateway route falls back to the Dashboard '
      'immediately and is not retried', () async {
    final harness = build(gatewayStatus: 401);
    addTearDown(harness.chat.dispose);

    final stopwatch = Stopwatch()..start();
    await harness.chat
        .loadMessages(expectedMessageCount: 2, profile: 'research')
        .timeout(const Duration(seconds: 5));
    stopwatch.stop();

    expect(harness.chat.messages.map((m) => m['content']), [
      'hola humano',
      'hola bot',
    ]);
    expect(harness.hydrationWaits, isEmpty);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(harness.gatewayReads, hasLength(1));
    expect(harness.gatewayReads.single.path, contains('/p/research/'));
    expect(harness.dashboardReads, isNotEmpty);
    expect(
      harness.dashboardReads.first.path,
      '/api/sessions/stored-bot/messages',
    );
    expect(harness.dashboardReads.first.queryParameters['profile'], 'research');
    expect(harness.gateway.resumeCalls, 1);

    // A later refresh goes straight to the Dashboard: 401 is definitive.
    await harness.chat
        .loadMessages(
          expectedMessageCount: 2,
          profile: 'research',
          passiveOnly: true,
        )
        .timeout(const Duration(seconds: 5));
    expect(harness.gatewayReads, hasLength(1));
    expect(harness.chat.messages, hasLength(2));
  });

  test('a profile with its own gateway key keeps the gateway route', () async {
    final harness = build(gatewayStatus: 200);
    addTearDown(harness.chat.dispose);

    await harness.chat
        .loadMessages(expectedMessageCount: 2, profile: 'research')
        .timeout(const Duration(seconds: 5));

    expect(harness.chat.messages, hasLength(2));
    expect(harness.gatewayReads, isNotEmpty);
    expect(harness.dashboardReads, isEmpty);
    expect(harness.hydrationWaits, isEmpty);
  });
}
