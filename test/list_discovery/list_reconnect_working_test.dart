// SPDX-License-Identifier: GPL-3.0-only
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

import '../support/test_api_client.dart';

/// LIST-DISCOVERY, the list's half: once its observer socket is known to be
/// dead (the foreground probe, `resume_probe_test.dart`), the list
/// reconnects and reads `session.active_list`, and a turn the server was
/// already running shows as "Working…" without opening the chat. With the
/// 5 s probe that bounds the foreground-to-"Working…" time to about 6 s on a
/// healthy network, as Desktop's (`use-gateway-boot.ts` `reconnectNow`).

const _connectionId = 'conn-discovery';
const _session = 'session-0';

class _Roster {
  int reads = 0;
  String status = 'idle';
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
  label: 'Discovery',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-key',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

final _running = find.byKey(const ValueKey('session-running-$_session'));

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

  testWidgets('a lost observer socket: the list reconnects, reads the '
      'roster and shows the running turn within 1 s', (tester) async {
    final aggregate = GlobalActivityAggregate.inMemory(
      now: () => tester.binding.clock.now(),
    );
    addTearDown(aggregate.dispose);
    final events = StreamController<TuiGatewayEvent>.broadcast();
    addTearDown(events.close);
    final roster = _Roster();
    var reconnects = 0;

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
          eventReconnectOverride: () async {
            reconnects++;
          },
          // The top of the first backoff step: 300 ms.
          eventReconnectRandomOverride: () => 1,
          activeSessionListLoader: () async {
            roster.reads++;
            return DesktopActiveSessionList(
              sessions: [
                DesktopActiveSession(
                  runtimeSessionId: 'desktop-runtime-0',
                  storedSessionId: _session,
                  status: roster.status,
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
    await tester.pump(const Duration(seconds: 1));
    expect(_running, findsNothing, reason: 'the roster said idle');

    // The server is running a turn; this list's socket turns out dead.
    roster.status = 'working';
    final readsBefore = roster.reads;
    final reconnectsBefore = reconnects;
    events.addError(StateError('Hermes Desktop probe timed out'));
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(reconnects, reconnectsBefore + 1, reason: 'one reconnect');
    expect(roster.reads, greaterThan(readsBefore), reason: 'roster re-read');
    expect(_running, findsOneWidget, reason: '"Working…" without the chat');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 61));
  });
}
