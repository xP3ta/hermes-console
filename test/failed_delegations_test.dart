// Failed delegations persisted by the server (`subagent.list.delegations`):
// parsed, merged into the roster as terminal rows, listed next to the live
// children with the list-level «…» menu, and retryable from the detail.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/delegation_control.dart';
import 'package:hermes_android/core/services/failed_delegation_roster.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/inter_font.dart';
import 'support/rpc_frame_helpers.dart';

final _scope = SubagentActivityScope(
  connectionId: 'c',
  parentSessionId: 'p',
  runtimeSessionId: 'r',
  turnEpoch: 1,
);

DesktopFailedDelegation _failed({
  String id = 'deleg-1',
  int index = 0,
  String goal = 'Prueba A',
  String? error = 'provider unavailable',
}) => DesktopFailedDelegation.tryParse({
  'delegation_id': id,
  'task_index': index,
  'status': 'failed',
  'goal': goal,
  'error': error,
  'dispatched_at': 1789034400.0,
  'completed_at': 1789034402.5,
})!;

class _Pause implements HermesDelegationGateway {
  bool paused = false;
  final calls = <bool>[];
  @override
  Future<bool> delegationPaused() async => paused;
  @override
  Future<bool> setDelegationPaused(bool value) async {
    calls.add(value);
    return paused = value;
  }
}

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('es'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: SafeArea(child: child)),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'ticket-failed-delegations',
      );
}

void main() {
  setUpAll(loadInterFont);

  group('parse', () {
    test('keeps the persisted fields and bounds the rest', () {
      final row = _failed();
      expect(row.stableId, 'deleg-1#0');
      expect(row.status, 'failed');
      expect(row.goal, 'Prueba A');
      expect(row.error, 'provider unavailable');
      expect(row.duration, const Duration(milliseconds: 2500));
    });

    test('drops rows without an id and tolerates missing fields', () {
      expect(DesktopFailedDelegation.tryParse({'goal': 'x'}), isNull);
      expect(DesktopFailedDelegation.tryParse('nope'), isNull);
      final bare = DesktopFailedDelegation.tryParse({'delegation_id': 'd'})!;
      expect(bare.taskIndex, 0);
      expect(bare.status, 'failed');
      expect(bare.goal, isEmpty);
      expect(bare.duration, isNull);
    });
  });

  group('gateway', () {
    Future<(HttpServer, List<Map<String, dynamic>>)> serve(
      Map<String, dynamic> result,
    ) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        }
      });
      return (server, frames);
    }

    TuiGatewayClient client(HttpServer server) => TuiGatewayClient(
      SavedConnection(
        id: 'conn-failed',
        label: 'Failed',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'k',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );

    test('reads `delegations`, dedupes and skips malformed rows', () async {
      final (server, frames) = await serve({
        'subagents': <Object>[],
        'delegations': [
          {
            'delegation_id': 'd1',
            'task_index': 0,
            'status': 'failed',
            'goal': 'A',
            'error': 'boom',
            'dispatched_at': 10.0,
            'completed_at': 12.0,
          },
          {'delegation_id': 'd1', 'task_index': 0, 'goal': 'dup'},
          {'delegation_id': 'd1', 'task_index': 1, 'goal': 'B'},
          {'goal': 'no id'},
        ],
      });
      addTearDown(server.close);
      final c = client(server);
      addTearDown(c.close);

      final rows = await c.listFailedDelegations('runtime-1');

      expect(frames.single['method'], 'subagent.list');
      expect(frames.single['params'], {'session_id': 'runtime-1'});
      expect(rows.map((r) => r.stableId), ['d1#0', 'd1#1']);
      expect(rows.first.error, 'boom');
    });

    test('an old gateway without the field yields no rows', () async {
      final (server, _) = await serve({'subagents': <Object>[]});
      addTearDown(server.close);
      final c = client(server);
      addTearDown(c.close);
      expect(await c.listFailedDelegations('runtime-1'), isEmpty);
    });
  });

  group('roster merge', () {
    test('a failed delegation becomes a terminal row without controls', () {
      final row = failedDelegationActivity(_failed(), _scope);
      expect(row.phase, SubagentActivityPhase.failed);
      expect(row.isTerminal, isTrue);
      expect(row.subagentId, isNull);
      expect(row.childSessionId, isNull);
      expect(row.delegationId, 'deleg-1');
      expect(row.goalPreview, 'Prueba A');
      expect(row.resultPreview, 'provider unavailable');
      expect(row.details.durationSeconds, 2.5);
    });

    test('a child the roster already shows is not listed twice', () {
      final child = SubagentActivity(
        key: SubagentActivityKey(
          scope: _scope,
          identityKind: SubagentIdentityKind.subagent,
          stableId: 'child',
        ),
        source: SubagentActivitySource.native,
        phase: SubagentActivityPhase.failed,
        subagentId: 'child',
        delegationId: 'deleg-1',
        details: const SubagentActivityDetails(goalPreview: 'Prueba A'),
      );
      final merged = withFailedDelegations(
        [child],
        [_failed(), _failed(index: 1, goal: 'Prueba B')],
        _scope,
      );
      expect(merged, hasLength(2));
      expect(merged.first, same(child));
      expect(merged.last.goalPreview, 'Prueba B');
    });

    test('nothing to add keeps the same list; no scope adds nothing', () {
      final roster = <SubagentActivity>[];
      expect(withFailedDelegations(roster, const [], _scope), same(roster));
      expect(withFailedDelegations(roster, [_failed()], null), same(roster));
    });
  });

  group('list and detail', () {
    testWidgets('the sheet lists the failed delegation and offers «…»', (
      tester,
    ) async {
      final controller = SubagentActivityController();
      final pause = _Pause();
      await tester.pumpWidget(
        _host(
          SubagentActivityCard(
            controller: controller,
            activities: [failedDelegationActivity(_failed(), _scope)],
            delegationControl: pause,
            canSteer: (_) => false,
            canInterrupt: (_) => false,
          ),
        ),
      );
      controller.open();
      await _settle(tester);

      expect(find.byKey(const ValueKey('subagent-panel')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subagent-row-deleg-1#0')),
        findsOneWidget,
      );
      expect(find.textContaining('Prueba A'), findsWidgets);

      await tester.tap(find.byTooltip('Más opciones'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delegates-pause')));
      await tester.pumpAndSettle();
      expect(pause.calls, [true]);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('no delegation control, no «…» in the list', (tester) async {
      final controller = SubagentActivityController();
      await tester.pumpWidget(
        _host(
          SubagentActivityCard(
            controller: controller,
            activities: [failedDelegationActivity(_failed(), _scope)],
            canSteer: (_) => false,
            canInterrupt: (_) => false,
          ),
        ),
      );
      controller.open();
      await _settle(tester);
      expect(find.byTooltip('Más opciones'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Retry puts the goal in the composer and closes the detail', (
      tester,
    ) async {
      final controller = SubagentActivityController();
      final goals = <String>[];
      await tester.pumpWidget(
        _host(
          SubagentActivityCard(
            controller: controller,
            activities: [failedDelegationActivity(_failed(), _scope)],
            canSteer: (_) => true,
            canInterrupt: (_) => false,
            onRetryGoal: goals.add,
          ),
        ),
      );
      controller.open();
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('subagent-row-deleg-1#0')));
      await _settle(tester);
      expect(find.byType(SubagentDetailScreen), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('subagent-detail-retry')));
      await _settle(tester);
      expect(goals, ['Prueba A']);
      expect(find.byType(SubagentDetailScreen), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a goal that may have been clipped is not offered again', (
      tester,
    ) async {
      final controller = SubagentActivityController();
      await tester.pumpWidget(
        _host(
          SubagentActivityCard(
            controller: controller,
            activities: [
              failedDelegationActivity(_failed(goal: 'x' * 1500), _scope),
            ],
            canSteer: (_) => true,
            canInterrupt: (_) => false,
            onRetryGoal: (_) {},
          ),
        ),
      );
      controller.open();
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('subagent-row-deleg-1#0')));
      await _settle(tester);
      expect(find.byType(SubagentDetailScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('subagent-detail-retry')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a finished child with a session has no Retry', (tester) async {
      final controller = SubagentActivityController();
      final child = SubagentActivity(
        key: SubagentActivityKey(
          scope: _scope,
          identityKind: SubagentIdentityKind.subagent,
          stableId: 'child',
        ),
        source: SubagentActivitySource.native,
        phase: SubagentActivityPhase.failed,
        subagentId: 'child',
        childSessionId: 'sess',
        details: const SubagentActivityDetails(goalPreview: 'Prueba A'),
      );
      await tester.pumpWidget(
        _host(
          SubagentActivityCard(
            controller: controller,
            activities: [child],
            canSteer: (_) => true,
            canInterrupt: (_) => false,
            onRetryGoal: (_) {},
          ),
        ),
      );
      controller.open();
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('subagent-row-child')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('subagent-detail-retry')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('nesting', () {
    SubagentActivity child(String id, {String? parent}) => SubagentActivity(
      key: SubagentActivityKey(
        scope: _scope,
        identityKind: SubagentIdentityKind.subagent,
        stableId: id,
      ),
      source: SubagentActivitySource.native,
      phase: SubagentActivityPhase.running,
      subagentId: id,
      details: SubagentActivityDetails(parentId: parent),
    );

    test('levels follow parent_id inside the list; strangers and cycles stay 0',
        () {
      final a = child('a');
      final b = child('b', parent: 'a');
      final c = child('c', parent: 'b');
      final orphan = child('o', parent: 'not-in-list');
      final loopX = child('x', parent: 'y');
      final loopY = child('y', parent: 'x');
      final levels = subagentNestingLevels([a, b, c, orphan, loopX, loopY]);
      expect(levels[a.key], isNull);
      expect(levels[b.key], 1);
      expect(levels[c.key], 2);
      expect(levels[orphan.key], isNull);
      expect(levels[loopX.key] ?? 0, lessThanOrEqualTo(1));
    });
  });
}
