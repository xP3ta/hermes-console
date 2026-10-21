import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart' show hermesRouteObserver;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// N10d: the Conversations list mounted under a chat must not poll. Unrouted
/// runtime events used to trigger `session.active_list` plus one
/// `spawn_tree.list`/`process.list` pair per roster row on every event, with
/// the list hidden. Desktop polls only a visible panel (about every 30 s with
/// events), so the hidden list marks itself dirty and refreshes once on return.

const _connectionId = 'conn-n10d';

class _Probe {
  int activeList = 0;
  int agentCenter = 0;
  final List<String> agentCenterRuntimes = [];
  String rosterStatus = 'working';
  String rosterRuntime = 'desktop-runtime-0';
}

http.Client _http() => MockClient((request) async {
  if (request.url.path == '/health') return http.Response('{}', 200);
  if (request.url.path == '/api/sessions') {
    return http.Response(
      jsonEncode({
        'data': [
          {
            'id': 'session-0',
            '_lineage_root_id': 'root-0',
            'title': 'Conversation 0',
            'preview': 'Preview 0',
            'model': 'model-a',
            'source': 'mobile',
            'message_count': 2,
            'is_active': false,
            'started_at': 1784499970,
            'ended_at': 1784499999,
            'last_active': 1784500000,
            'archived': false,
          },
        ],
        'has_more': false,
      }),
      200,
    );
  }
  return http.Response('{}', 404);
});

SavedConnection _connection() => SavedConnection(
  id: _connectionId,
  label: 'N10d',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-key',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ConnectionManager.create(prefs);
}

Future<void> _mount(
  WidgetTester tester,
  _Probe probe,
  StreamController<TuiGatewayEvent> events,
  GlobalActivityAggregate aggregate,
) async {
  final manager = await _manager();
  final gateway = ApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    apiKey: 'test-key',
    connectionId: _connectionId,
    httpClient: _http(),
  );
  final dashboard = DashboardClient(
    host: '127.0.0.1',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((_) async => http.Response('{}', 503)),
  );
  final repository = SessionRepository(dashboard, gateway);
  addTearDown(() {
    repository.close();
    dashboard.close();
  });
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      navigatorObservers: [hermesRouteObserver],
      home: SessionListScreen(
        connection: _connection(),
        connManager: manager,
        clientOverride: gateway,
        repositoryOverride: repository,
        eventStreamOverride: events.stream,
        globalActivityOverride: aggregate,
        eventReconnectOverride: () async {},
        activeSessionListLoader: () async {
          probe.activeList++;
          return DesktopActiveSessionList(
            sessions: [
              DesktopActiveSession(
                runtimeSessionId: probe.rosterRuntime,
                storedSessionId: 'session-0',
                status: probe.rosterStatus,
              ),
            ],
          );
        },
        agentCenterSnapshotLoader: (runtime) async {
          probe.agentCenter++;
          probe.agentCenterRuntimes.add(runtime);
          return const AgentCenterSnapshot(snapshots: [], processes: []);
        },
      ),
    ),
  );
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (find.text('Conversation 0').evaluate().isNotEmpty) break;
  }
  expect(find.text('Conversation 0'), findsOneWidget);
  // Let the first-mount reads settle before the counters are taken.
  await tester.pump(const Duration(seconds: 1));
}

/// 60 events of a runtime the roster does not route, spread over 120 s.
Future<void> _noise(
  WidgetTester tester,
  StreamController<TuiGatewayEvent> events,
) async {
  for (var i = 0; i < 60; i++) {
    events.add(
      const TuiGatewayEvent(
        type: 'tool.progress',
        sessionId: 'unrouted-runtime',
        payload: {'name': 'terminal'},
      ),
    );
    await tester.pump(const Duration(seconds: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  testWidgets('a hidden list sends no active_list or agentCenter reads, then '
      'refreshes once when it is uncovered', (tester) async {
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(aggregate.dispose);
    final probe = _Probe();
    await _mount(tester, probe, events, aggregate);

    final context = tester.element(find.byType(SessionListScreen));
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('chat above the list')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('chat above the list'), findsOneWidget);

    final activeBefore = probe.activeList;
    final agentBefore = probe.agentCenter;
    await _noise(tester, events);
    expect(
      probe.activeList - activeBefore,
      0,
      reason: 'a hidden list must not ask session.active_list',
    );
    expect(
      probe.agentCenter - agentBefore,
      0,
      reason: 'a hidden list must not ask spawn_tree.list/process.list',
    );

    Navigator.of(context).pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('chat above the list'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(
      probe.activeList - activeBefore,
      1,
      reason: 'the list refreshes the roster once when it is uncovered',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('a visible list asks active_list at most twice a minute for '
      'unrouted events', (tester) async {
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(aggregate.dispose);
    final probe = _Probe();
    await _mount(tester, probe, events, aggregate);

    final activeBefore = probe.activeList;
    await _noise(tester, events);
    expect(
      probe.activeList - activeBefore,
      lessThanOrEqualTo(4),
      reason: 'at most 2 per minute over the 120 s window',
    );
    expect(
      probe.activeList - activeBefore,
      greaterThanOrEqualTo(1),
      reason: 'events still refresh a visible list (30 s backstop)',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('agentCenter reads only cover busy rows or rows with known live '
      'processes', (tester) async {
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(aggregate.dispose);
    final probe = _Probe()..rosterStatus = 'idle';
    await _mount(tester, probe, events, aggregate);

    expect(
      probe.agentCenter,
      0,
      reason: 'an idle row with no known live process is not probed',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('an event of a routed runtime still updates its row within a '
      'second', (tester) async {
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(aggregate.dispose);
    final probe = _Probe();
    await _mount(tester, probe, events, aggregate);
    expect(aggregate.isActive(_connectionId, 'default', 'session-0'), isTrue);

    final context = tester.element(find.byType(SessionListScreen));
    unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const Scaffold())),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    events.add(
      const TuiGatewayEvent(
        type: 'message.complete',
        sessionId: 'desktop-runtime-0',
        payload: {'text': 'ok'},
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(
      aggregate.isActive(_connectionId, 'default', 'session-0'),
      isFalse,
      reason: 'routed events keep updating the aggregate while hidden',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 61));
  });
}
