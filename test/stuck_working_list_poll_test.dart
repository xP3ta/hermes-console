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

import 'support/test_api_client.dart';

/// H1 (EMU-QA): after a force-stop with a turn running, the relaunched list
/// learns "busy" from `session.active_list` and the row stays "Working…" up
/// to [GlobalActivityAggregate.silentLivenessCeiling] after the server ended
/// the turn. The turn's terminal goes only to the socket of the chat that
/// runs it (none after a force-stop), so only a later roster read can clear
/// the row, and the list never asked again.

const _connectionId = 'conn-stuck';
const _session = 'session-0';

class _Probe {
  int activeList = 0;
  String rosterStatus = 'working';
  bool rosterFails = false;
}

http.Client _http() => MockClient((request) async {
  if (request.url.path == '/api/status') return http.Response('{}', 200);
  if (request.url.path == '/api/sessions') {
    return http.Response(
      jsonEncode({
        'sessions': [
          {
            'id': _session,
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
        'total': 1,
      }),
      200,
    );
  }
  return http.Response('{}', 404);
});

SavedConnection _connection() => SavedConnection(
  id: _connectionId,
  label: 'Stuck',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-key',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

/// The aggregate reads this clock; [_advance] moves it with the fake timers
/// (`DateTime.now()` does not follow `tester.pump`).
class _Clock {
  DateTime now = DateTime.utc(2026, 10, 24, 10);
}

Future<void> _advance(WidgetTester tester, _Clock clock, Duration by) async {
  const step = Duration(seconds: 1);
  for (var left = by; left > Duration.zero; left -= step) {
    clock.now = clock.now.add(step);
    await tester.pump(step);
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Probe probe,
  GlobalActivityAggregate aggregate,
  StreamController<TuiGatewayEvent> events,
) async {
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  final gateway = testApiClient(
    baseUrl: 'http://127.0.0.1:8642',
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
          if (probe.rosterFails) throw StateError('roster unavailable');
          return DesktopActiveSessionList(
            sessions: [
              DesktopActiveSession(
                runtimeSessionId: 'desktop-runtime-0',
                storedSessionId: _session,
                status: probe.rosterStatus,
              ),
            ],
          );
        },
        agentCenterSnapshotLoader: (_) async =>
            const AgentCenterSnapshot(snapshots: [], processes: []),
      ),
    ),
  );
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (find.text('Conversation 0').evaluate().isNotEmpty) break;
  }
  expect(find.text('Conversation 0'), findsOneWidget);
  // First-mount reads (init, health, connect) settle before any count.
  await tester.pump(const Duration(seconds: 1));
}

final _running = find.byKey(const ValueKey('session-running-$_session'));

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 61));
}

/// Puts a live roster row of [connection]/[profile] into [aggregate].
void _seedLive(
  GlobalActivityAggregate aggregate,
  String profile,
  String id, {
  String connection = _connectionId,
}) {
  aggregate.applyRoster(
    connectionId: connection,
    profile: profile,
    replayEpoch: 'current',
    requestGeneration: aggregate.beginRosterRequest(connection, profile),
    roster: DesktopActiveSessionList(
      sessions: [
        DesktopActiveSession(
          runtimeSessionId: 'runtime-$id',
          storedSessionId: id,
          status: 'working',
        ),
      ],
    ),
  );
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

  testWidgets('a row learnt busy from the roster returns to rest once the '
      'roster says idle, with no event at all', (tester) async {
    final clock = _Clock();
    final aggregate = GlobalActivityAggregate.inMemory(now: () => clock.now);
    addTearDown(aggregate.dispose);
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final probe = _Probe();
    await _mount(tester, probe, aggregate, events);
    expect(aggregate.isActive(_connectionId, 'default', _session), isTrue);
    expect(_running, findsOneWidget);

    // The server ends the turn; its terminal never reaches this list.
    probe.rosterStatus = 'idle';
    await _advance(tester, clock, const Duration(seconds: 65));

    expect(
      aggregate.isActive(_connectionId, 'default', _session),
      isFalse,
      reason: 'two idle roster reads put the row back to rest',
    );
    expect(_running, findsNothing, reason: 'no "Working…" on the row');
    await _unmount(tester);
  });

  testWidgets('a live turn longer than the silent ceiling stays '
      'working', (tester) async {
    final clock = _Clock();
    final aggregate = GlobalActivityAggregate.inMemory(now: () => clock.now);
    addTearDown(aggregate.dispose);
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final probe = _Probe();
    await _mount(tester, probe, aggregate, events);

    await _advance(
      tester,
      clock,
      GlobalActivityAggregate.silentLivenessCeiling +
          const Duration(minutes: 1),
    );

    expect(
      aggregate.isActive(_connectionId, 'default', _session),
      isTrue,
      reason: 'the roster keeps proving the turn alive',
    );
    expect(_running, findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a pending question keeps "Waiting for your reply"', (
    tester,
  ) async {
    final clock = _Clock();
    final aggregate = GlobalActivityAggregate.inMemory(now: () => clock.now);
    addTearDown(aggregate.dispose);
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final probe = _Probe()..rosterStatus = 'waiting';
    await _mount(tester, probe, aggregate, events);

    await _advance(tester, clock, const Duration(minutes: 2));

    expect(aggregate.isActive(_connectionId, 'default', _session), isTrue);
    expect(
      aggregate.activityFor(_connectionId, 'default', _session)?.requiresAction,
      isTrue,
    );
    expect(tester.widget<Text>(_running).data, 'Waiting for your reply');
    await _unmount(tester);
  });

  testWidgets('a list at rest sends no extra roster read', (tester) async {
    final clock = _Clock();
    final aggregate = GlobalActivityAggregate.inMemory(now: () => clock.now);
    addTearDown(aggregate.dispose);
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final probe = _Probe()..rosterStatus = 'idle';
    await _mount(tester, probe, aggregate, events);

    final before = probe.activeList;
    await _advance(tester, clock, const Duration(minutes: 2));
    expect(probe.activeList - before, 0, reason: 'no live row, no polling');
    await _unmount(tester);
  });

  testWidgets('a live row of another profile or instance does not make '
      'this list poll', (tester) async {
    final clock = _Clock();
    final aggregate = GlobalActivityAggregate.inMemory(now: () => clock.now);
    addTearDown(aggregate.dispose);
    _seedLive(aggregate, 'qaone', 'qaone-session');
    _seedLive(aggregate, 'default', 'far-session', connection: 'conn-far');
    expect(aggregate.isActive(_connectionId, 'qaone', 'qaone-session'), isTrue);
    expect(aggregate.isActive('conn-far', 'default', 'far-session'), isTrue);
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final probe = _Probe()..rosterStatus = 'idle';
    await _mount(tester, probe, aggregate, events);

    final before = probe.activeList;
    await _advance(tester, clock, const Duration(minutes: 2));
    expect(
      probe.activeList - before,
      0,
      reason: 'only live rows of this list justify reading again',
    );
    await _unmount(tester);
  });

  testWidgets('an activity past its liveness ceiling does not keep the list '
      'polling', (tester) async {
    final clock = _Clock();
    final aggregate = GlobalActivityAggregate.inMemory(now: () => clock.now);
    addTearDown(aggregate.dispose);
    _seedLive(aggregate, 'default', _session);
    clock.now = clock.now.add(
      GlobalActivityAggregate.silentLivenessCeiling +
          const Duration(minutes: 1),
    );
    expect(aggregate.isActive(_connectionId, 'default', _session), isFalse);
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    // The roster cannot answer, so the expired entry stays in the aggregate.
    final probe = _Probe()..rosterFails = true;
    await _mount(tester, probe, aggregate, events);

    final before = probe.activeList;
    await _advance(tester, clock, const Duration(minutes: 2));
    expect(
      probe.activeList - before,
      0,
      reason: 'an entry that no longer claims liveness is not a live row',
    );
    await _unmount(tester);
  });

  testWidgets('a list in background does not poll', (tester) async {
    final clock = _Clock();
    final aggregate = GlobalActivityAggregate.inMemory(now: () => clock.now);
    addTearDown(aggregate.dispose);
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final probe = _Probe();
    await _mount(tester, probe, aggregate, events);
    expect(aggregate.isActive(_connectionId, 'default', _session), isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final before = probe.activeList;
    await _advance(tester, clock, const Duration(minutes: 2));
    expect(probe.activeList - before, 0, reason: 'no reads in background');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _unmount(tester);
  });
}
