// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/session_live_status.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/session_row_stop_control.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart' show hermesRouteObserver;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity_peer_test.dart' as peer;
import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

const _connectionId = 'conn-live-clear';
const _sessionA = 'session-a';
const _sessionB = 'session-b';

SavedConnection _connection() => SavedConnection(
  id: _connectionId,
  label: 'Live Clear',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-key',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

http.Client _http() => MockClient((request) async {
  if (request.url.path == '/api/status') return http.Response('{}', 200);
  if (request.url.path == '/api/sessions') {
    return http.Response(
      jsonEncode({
        'sessions': [
          {
            'id': _sessionA,
            '_lineage_root_id': 'root-a',
            'title': 'Conversacion A',
            'preview': 'Preview A',
            'model': 'model-a',
            'source': 'mobile',
            'message_count': 4,
            'is_active': false,
            'started_at': 1700000010,
            'ended_at': 1700000020,
            'last_active': 1700000020,
            'archived': false,
          },
          {
            'id': _sessionB,
            '_lineage_root_id': 'root-b',
            'title': 'Conversacion B',
            'preview': 'Preview B',
            'model': 'model-a',
            'source': 'desktop',
            'message_count': 4,
            'is_active': false,
            'started_at': 1700000000,
            'ended_at': 1700000010,
            'last_active': 1700000010,
            'archived': false,
          },
        ],
        'total': 2,
      }),
      200,
    );
  }
  return http.Response('{}', 404);
});

class _RosterProbe {
  int reads = 0;
  List<DesktopActiveSession> rows = const [
    DesktopActiveSession(
      runtimeSessionId: 'runtime-a',
      storedSessionId: _sessionA,
      status: 'working',
    ),
    DesktopActiveSession(
      runtimeSessionId: 'runtime-b',
      storedSessionId: _sessionB,
      status: 'working',
    ),
  ];
}

Future<void> _mountList(
  WidgetTester tester, {
  required GlobalActivityAggregate aggregate,
  required StreamController<TuiGatewayEvent> events,
  required _RosterProbe probe,
  Future<AgentCenterSnapshot> Function(String runtimeSessionId)?
  agentCenterSnapshotLoader,
  Future<void> Function()? eventReconnectOverride,
}) async {
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
      locale: const Locale('es'),
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
        eventReconnectOverride: eventReconnectOverride ?? () async {},
        eventReconnectRandomOverride: () => 1,
        activeSessionListLoader: () async {
          probe.reads++;
          return DesktopActiveSessionList(sessions: probe.rows);
        },
        agentCenterSnapshotLoader:
            agentCenterSnapshotLoader ??
            (_) async =>
                const AgentCenterSnapshot(snapshots: [], processes: []),
      ),
    ),
  );
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (find.text('Conversacion A').evaluate().isNotEmpty) break;
  }
  expect(find.text('Conversacion A'), findsOneWidget);
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 61));
}

String? _subtitleText(WidgetTester tester) {
  final finder = find.byKey(const ValueKey('session-list-subtitle'));
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<Text>(finder).data;
}

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

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  testWidgets(
    'two live chats clear row, stop button and header within 1 s of '
    'sessions.changed even inside the 10 s REST refresh gap',
    (tester) async {
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => tester.binding.clock.now(),
      );
      addTearDown(aggregate.dispose);
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      final probe = _RosterProbe();

      await _mountList(
        tester,
        aggregate: aggregate,
        events: events,
        probe: probe,
      );

      expect(_subtitleText(tester), contains('2 en vivo'));
      expect(
        find.byKey(const ValueKey('session-running-$_sessionA')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-running-$_sessionB')),
        findsOneWidget,
      );
      expect(find.byType(SessionRowStopControl), findsNWidgets(2));

      // First turn finishes: roster reports idle for session A, still working
      // for session B. One sessions.changed clears A immediately.
      probe.rows = const [
        DesktopActiveSession(
          runtimeSessionId: 'runtime-a',
          storedSessionId: _sessionA,
          status: 'idle',
        ),
        DesktopActiveSession(
          runtimeSessionId: 'runtime-b',
          storedSessionId: _sessionB,
          status: 'working',
        ),
      ];
      events.add(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byKey(const ValueKey('session-running-$_sessionA')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('session-running-$_sessionB')),
        findsOneWidget,
      );
      expect(find.byType(SessionRowStopControl), findsOneWidget);
      expect(_subtitleText(tester), contains('1 en vivo'));

      // Only 2 s later (inside the 10 s REST gap), second turn finishes and
      // disappears from active_list. It must clear without waiting for a poll.
      await tester.pump(const Duration(seconds: 2));
      probe.rows = const [];
      events.add(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byKey(const ValueKey('session-running-$_sessionB')),
        findsNothing,
      );
      expect(find.byType(SessionRowStopControl), findsNothing);
      expect(_subtitleText(tester) ?? '', isNot(contains('en vivo')));

      await _unmount(tester);
    },
  );

  testWidgets(
    'a burst of sessions.changed costs two activity reads, the second with '
    'the final state, and one process snapshot per working row at a time',
    (tester) async {
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => tester.binding.clock.now(),
      );
      addTearDown(aggregate.dispose);
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      final probe = _RosterProbe();
      final snapshots = <String>[];
      final held = <Completer<AgentCenterSnapshot>>[];

      await _mountList(
        tester,
        aggregate: aggregate,
        events: events,
        probe: probe,
        // Slow snapshots: they are still on the wire when the next read ends.
        agentCenterSnapshotLoader: (runtime) {
          snapshots.add(runtime);
          final answer = Completer<AgentCenterSnapshot>();
          held.add(answer);
          return answer.future;
        },
      );
      // Let the reads of mounting settle and count from here.
      await tester.pump(sessionActivityRefreshGap * 2);
      final readsBefore = probe.reads;
      final snapshotsBefore = snapshots.length;

      // An agent at work: twenty events in well under the gap.
      for (var i = 0; i < 20; i++) {
        events.add(
          const TuiGatewayEvent(
            type: 'sessions.changed',
            sessionId: '',
            payload: {},
          ),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(
        probe.reads - readsBefore,
        1,
        reason: 'the first event reads at once; the rest wait for the gap',
      );

      // The burst ends with A finished: the one trailing read must see it.
      probe.rows = const [
        DesktopActiveSession(
          runtimeSessionId: 'runtime-b',
          storedSessionId: _sessionB,
          status: 'working',
        ),
      ];
      await tester.pump(sessionActivityRefreshGap);
      await tester.pump(const Duration(milliseconds: 100));
      expect(probe.reads - readsBefore, 2);
      expect(
        find.byKey(const ValueKey('session-running-$_sessionA')),
        findsNothing,
        reason: 'the trailing read carried the final state',
      );

      // No third read once the events stop.
      await tester.pump(sessionActivityRefreshGap * 2);
      expect(probe.reads - readsBefore, 2);

      // The snapshots never answered: each row was asked once, not once
      // per read.
      final asked = snapshots.sublist(snapshotsBefore);
      expect(asked.toSet().length, asked.length, reason: '$asked');

      for (final answer in held) {
        answer.complete(const AgentCenterSnapshot(snapshots: [], processes: []));
      }
      await _unmount(tester);
    },
  );

  testWidgets(
    'session.info with running false clears row, stop button and header '
    'immediately without polling active_list',
    (tester) async {
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => tester.binding.clock.now(),
      );
      addTearDown(aggregate.dispose);
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      final probe = _RosterProbe()
        ..rows = const [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-a',
            storedSessionId: _sessionA,
            status: 'working',
          ),
        ];

      await _mountList(
        tester,
        aggregate: aggregate,
        events: events,
        probe: probe,
      );

      expect(_subtitleText(tester), contains('1 en vivo'));
      expect(find.byType(SessionRowStopControl), findsOneWidget);
      final readsBefore = probe.reads;

      events.add(
        const TuiGatewayEvent(
          type: 'session.info',
          sessionId: 'runtime-a',
          payload: {'running': false},
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.byKey(const ValueKey('session-running-$_sessionA')),
        findsNothing,
      );
      expect(find.byType(SessionRowStopControl), findsNothing);
      expect(_subtitleText(tester) ?? '', isNot(contains('en vivo')));
      expect(probe.reads, readsBefore);

      await _unmount(tester);
    },
  );

  testWidgets(
    'working and waiting turns stay live across a list refresh without flicker',
    (tester) async {
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => tester.binding.clock.now(),
      );
      addTearDown(aggregate.dispose);
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      final probe = _RosterProbe()
        ..rows = const [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-a',
            storedSessionId: _sessionA,
            status: 'working',
          ),
          DesktopActiveSession(
            runtimeSessionId: 'runtime-b',
            storedSessionId: _sessionB,
            status: 'waiting',
          ),
        ];

      await _mountList(
        tester,
        aggregate: aggregate,
        events: events,
        probe: probe,
      );

      expect(_subtitleText(tester), contains('2 en vivo'));
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('session-running-$_sessionA')),
            )
            .data,
        'Trabajando…',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('session-running-$_sessionB')),
            )
            .data,
        'Esperando tu respuesta',
      );
      expect(find.byType(SessionRowStopControl), findsNWidgets(2));

      events.add(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(_subtitleText(tester), contains('2 en vivo'));
      expect(
        find.byKey(const ValueKey('session-running-$_sessionA')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-running-$_sessionB')),
        findsOneWidget,
      );
      expect(find.byType(SessionRowStopControl), findsNWidgets(2));

      await _unmount(tester);
    },
  );

  testWidgets(
    'reconnect and late process.list snapshot never resurrect a finished turn',
    (tester) async {
      final aggregate = GlobalActivityAggregate.inMemory(
        now: () => tester.binding.clock.now(),
      );
      addTearDown(aggregate.dispose);
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      final probe = _RosterProbe()
        ..rows = const [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-a',
            storedSessionId: _sessionA,
            status: 'working',
          ),
        ];
      Completer<AgentCenterSnapshot>? nextProcessProbe;
      Completer<AgentCenterSnapshot>? inFlightProbe;

      await _mountList(
        tester,
        aggregate: aggregate,
        events: events,
        probe: probe,
        agentCenterSnapshotLoader: (_) {
          final completer = nextProcessProbe;
          if (completer != null) {
            nextProcessProbe = null;
            inFlightProbe = completer;
            return completer.future;
          }
          return Future.value(
            const AgentCenterSnapshot(snapshots: [], processes: []),
          );
        },
      );

      expect(
        find.byKey(const ValueKey('session-running-$_sessionA')),
        findsOneWidget,
      );

      // Reconnect reads active_list while still working and starts a
      // process.list probe under transport recovery.
      nextProcessProbe = Completer<AgentCenterSnapshot>();
      events.addError(StateError('socket dropped'));
      await tester.pump(const Duration(milliseconds: 1000));
      expect(inFlightProbe, isNotNull);

      // Before that process.list returns, the turn finishes and active_list
      // clears it.
      probe.rows = const [];
      events.add(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.byKey(const ValueKey('session-running-$_sessionA')),
        findsNothing,
      );

      // Completing the late recovery process.list must not resurrect it.
      inFlightProbe!.complete(
        const AgentCenterSnapshot(snapshots: [], processes: []),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.byKey(const ValueKey('session-running-$_sessionA')),
        findsNothing,
      );

      // A second reconnect with an empty roster keeps the finished turn clear.
      events.addError(StateError('socket dropped again'));
      await tester.pump(const Duration(milliseconds: 1000));
      expect(
        find.byKey(const ValueKey('session-running-$_sessionA')),
        findsNothing,
      );
      expect(find.byType(SessionRowStopControl), findsNothing);
      expect(_subtitleText(tester) ?? '', isNot(contains('en vivo')));

      await _unmount(tester);
    },
  );

  test(
    'non-running resume snapshot settles active chat and global activity',
    () async {
      final clock = DateTime.utc(2026);
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
        globalActivity: GlobalActivityAggregate.inMemory(now: () => clock),
      );
      addTearDown(service.dispose);

      final peerConn = SavedConnection(
        id: 'peer',
        label: 'Peer',
        host: 'example.invalid',
        port: 443,
        apiKey: 'k',
        useHttps: true,
        kind: InstanceKind.vps,
      );

      DesktopSessionSnapshot snapshot({required bool running}) =>
          DesktopSessionSnapshot.fromJson(
            {
              'session_id': 'runtime-peer',
              'session_key': 'stored-peer',
              'message_count': 1,
              'messages': [peer.publicSnapshot],
              'running': running,
              if (running) 'inflight': {'assistant': '', 'streaming': true},
            },
            requestedStoredSessionId: 'stored-peer',
            created: false,
            method: 'session.resume',
          );

      service.globalActivity.applyRoster(
        connectionId: 'peer',
        profile: 'default',
        replayEpoch: 'current',
        requestGeneration: service.globalActivity.beginRosterRequest(
          'peer',
          'default',
        ),
        roster: const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-peer',
              storedSessionId: 'stored-peer',
              status: 'working',
            ),
          ],
        ),
      );

      final gateway = peer.PeerGateway(snapshot(running: true));
      addTearDown(gateway.close);
      final chat = service.attach(
        connection: peerConn,
        sessionId: 'stored-peer',
        sessionTitle: 'Peer',
        api: testApiClient(
          baseUrl: 'https://example.invalid',
          httpClient: MockClient((_) async => http.Response('nf', 404)),
        ),
        desktopGateway: gateway,
        allowUnownedDesktopSnapshotForTesting: true,
        disableForegroundKeepAlive: true,
      );
      await chat.loadMessages();
      expect(chat.isStreaming, isTrue);

      // The turn ends silently; the next complete non-running snapshot settles
      // both ActiveChat and GlobalActivityAggregate immediately.
      gateway.snapshot = snapshot(running: false);
      await chat.loadMessages();

      expect(chat.isStreaming, isFalse);
      expect(chat.lastTerminalAt, isNotNull);
      expect(
        service.globalActivity.isActive('peer', 'default', 'stored-peer'),
        isFalse,
      );

      service.debugDisposeChatForTesting('peer', 'stored-peer');
      final resolved = resolveSessionLiveStatus(
        chat: null,
        chatAuthoritative: false,
        chatSettledAt: null,
        global:
            service.globalActivity.isActive('peer', 'default', 'stored-peer')
            ? service.globalActivity.activityFor(
                'peer',
                'default',
                'stored-peer',
              )
            : null,
      );
      expect(resolved.isLive, isFalse);
    },
  );
}
