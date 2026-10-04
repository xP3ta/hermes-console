// Pause delegation: process-global `delegation.status` / `delegation.pause`,
// offered only from the subagent detail overflow, read once per menu open.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/delegation_control.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/inter_font.dart';
import 'support/rpc_frame_helpers.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-delegation',
      );
}

TuiGatewayClient _clientFor(HttpServer server) => TuiGatewayClient(
  SavedConnection(
    id: 'conn-delegation',
    label: 'Delegation',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'gateway-key',
    dashboardUrl: 'http://127.0.0.1:${server.port}',
  ),
  dashboard: _TicketDashboardClient(),
);

Future<List<Map<String, dynamic>>> _serve(
  HttpServer server,
  Map<String, dynamic> Function(Map<String, dynamic> frame) reply,
) async {
  final frames = <Map<String, dynamic>>[];
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      if (isClientCapabilitiesFrame(frame)) {
        socket.add(jsonEncode(clientCapabilitiesResponse(frame)));
        continue;
      }
      frames.add(frame);
      socket.add(jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], ...reply(frame)}));
    }
  });
  return frames;
}

class _FakeDelegation implements HermesDelegationGateway {
  bool paused;
  Object? statusError;
  int statuses = 0;
  final pauses = <bool>[];

  _FakeDelegation({this.paused = false});

  @override
  Future<bool> delegationPaused() async {
    statuses++;
    if (statusError != null) throw statusError!;
    return paused;
  }

  @override
  Future<bool> setDelegationPaused(bool value) async {
    pauses.add(value);
    paused = value;
    return paused;
  }
}

final _scope = SubagentActivityScope(
  connectionId: 'c',
  parentSessionId: 'p',
  runtimeSessionId: 'r',
  turnEpoch: 1,
);

final _activity = SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: 'child',
  ),
  source: SubagentActivitySource.native,
  phase: SubagentActivityPhase.running,
  subagentId: 'child',
  details: const SubagentActivityDetails(goalPreview: 'Revisar'),
);

Future<void> _pump(WidgetTester tester, HermesDelegationGateway? control) async {
  final roster = ValueNotifier<List<SubagentActivity>>([_activity]);
  addTearDown(roster.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: SubagentDetailScreen(
        roster: roster,
        activityKey: _activity.key,
        parentTitle: 'Chat',
        delegationControl: control,
        clock: () => DateTime.utc(2026, 10, 4, 12),
        routeObserver: RouteObserver<PageRoute<dynamic>>(),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('subagent-detail-more')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadInterFont);

  group('gateway', () {
    test('delegation.status reads the global paused flag', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final frames = await _serve(
        server,
        (_) => {
          'result': {
            'active': <Object>[],
            'paused': true,
            'max_spawn_depth': 2,
            'max_concurrent_children': 3,
          },
        },
      );
      final client = _clientFor(server);
      addTearDown(client.close);

      expect(await client.delegationPaused(), isTrue);
      expect(frames.single['method'], 'delegation.status');
      expect(frames.single['params'], <String, dynamic>{});
    });

    test('delegation.pause sends the flag and returns the new state', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final frames = await _serve(
        server,
        (frame) => {
          'result': {'paused': (frame['params'] as Map)['paused']},
        },
      );
      final client = _clientFor(server);
      addTearDown(client.close);

      expect(await client.setDelegationPaused(true), isTrue);
      expect(await client.setDelegationPaused(false), isFalse);
      expect(frames.map((f) => f['method']), ['delegation.pause', 'delegation.pause']);
      expect(frames.map((f) => f['params']), [
        {'paused': true},
        {'paused': false},
      ]);
    });

    test('-32601 is cached as unsupported and not asked again', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final frames = await _serve(
        server,
        (_) => {
          'error': {'code': -32601, 'message': 'Method not found'},
        },
      );
      final client = _clientFor(server);
      addTearDown(client.close);

      await expectLater(client.delegationPaused(), throwsA(isA<TuiGatewayRpcError>()));
      await expectLater(client.delegationPaused(), throwsA(isA<TuiGatewayRpcError>()));
      expect(frames, hasLength(1));
      expect(
        client.capabilityState(DesktopGatewayCapability.delegationControl),
        DesktopGatewayCapabilityState.unsupported,
      );
    });

    test('a malformed answer invalidates only this capability', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      await _serve(server, (_) => {'result': {'paused': 'yes'}});
      final client = _clientFor(server);
      addTearDown(client.close);

      await expectLater(client.delegationPaused(), throwsA(isA<TuiGatewayRpcError>()));
      expect(
        client.capabilityState(DesktopGatewayCapability.delegationControl),
        DesktopGatewayCapabilityState.invalid,
      );
    });
  });

  group('subagent detail overflow', () {
    testWidgets('no control, no menu', (tester) async {
      await _pump(tester, null);
      expect(find.byKey(const ValueKey('subagent-detail-more')), findsNothing);
    });

    testWidgets('status is read once per open, toggling sends the flag', (
      tester,
    ) async {
      final control = _FakeDelegation();
      await _pump(tester, control);
      expect(control.statuses, 0);

      await _openMenu(tester);
      expect(control.statuses, 1);
      expect(find.text('Pausar nuevos subagentes'), findsOneWidget);
      // The scope is stated in the menu itself.
      expect(find.textContaining('todo el servidor'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('subagent-detail-pause')));
      await tester.pumpAndSettle();
      expect(control.pauses, [true]);

      await _openMenu(tester);
      expect(control.statuses, 2);
      expect(find.text('Reanudar nuevos subagentes'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('subagent-detail-pause')));
      await tester.pumpAndSettle();
      expect(control.pauses, [true, false]);
    });

    testWidgets('a server without delegation control hides the menu', (
      tester,
    ) async {
      final control = _FakeDelegation()
        ..statusError = const TuiGatewayRpcError(
          'delegation.status',
          'Method not found',
          code: -32601,
        );
      await _pump(tester, control);
      await _openMenu(tester);

      expect(control.pauses, isEmpty);
      expect(find.byKey(const ValueKey('subagent-detail-more')), findsNothing);
      expect(find.text('Pausar nuevos subagentes'), findsNothing);
    });
  });
}
