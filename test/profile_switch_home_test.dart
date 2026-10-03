import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gateway that answers each profile's session list on its own, so a test
/// can hold the previous profile's read on the wire across a switch.
final class _Server {
  final gates = <String, Completer<void>>{};
  final reads = <String>[];

  http.Client client() => MockClient((request) async {
    final path = request.url.path;
    if (path == '/health') return http.Response('{"status":"ok"}', 200);
    final match = RegExp(r'^(?:/p/([^/]+))?/api/sessions$').firstMatch(path);
    if (match == null) return http.Response('{}', 404);
    final profile = match.group(1) ?? 'default';
    reads.add(profile);
    final gate = gates[profile];
    if (gate != null) await gate.future;
    final title = '${profile[0].toUpperCase()}${profile.substring(1)} chat';
    return http.Response(
      '{"data":[{"id":"s-$profile","title":"$title","source":"cli",'
      '"started_at":1790000000,"last_active":1790000100}],'
      '"has_more":false}',
      200,
    );
  });
}

/// Holds the local agent token read Home does at the start of every reload
/// (it re-syncs the key of an on-device agent before refreshing).
Completer<void>? holdLocalTokenRead;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    holdLocalTokenRead = null;
    SharedPreferences.setMockInitialValues({});
    final secureValues = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          final args = call.arguments is Map
              ? Map<Object?, Object?>.from(call.arguments as Map)
              : const <Object?, Object?>{};
          switch (call.method) {
            case 'write':
              secureValues[args['key'] as String] = args['value'] as String;
              return null;
            case 'read':
              final hold = holdLocalTokenRead;
              if (args['key'] == 'local_agent_session_token' && hold != null) {
                await hold.future;
              }
              return secureValues[args['key']];
            case 'readAll':
              return Map<String, String>.of(secureValues);
            case 'delete':
              secureValues.remove(args['key']);
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<(ConnectionManager, ActiveProfileScope)> pumpHome(
    WidgetTester tester,
    _Server server, {
    void Function(ActiveProfileScope scope)? beforePump,
    bool withLocalAgent = false,
  }) async {
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    if (withLocalAgent) {
      await manager.upsertConnection(
        SavedConnection(
          id: 'local-agent',
          label: 'Local',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'local-key',
          kind: InstanceKind.localhost,
          onDeviceLoopback: true,
        ),
      );
    }
    await manager.saveConnection(
      'QA',
      '127.0.0.2',
      8642,
      'test-key',
      kind: InstanceKind.vps,
    );
    final connection = manager.getConnections().firstWhere(
      (c) => c.label == 'QA',
    );
    await manager.setActiveConnection(connection.id);
    await manager.setActiveProfile(connection.id, 'ana');
    final scope = ActiveProfileScope.of(manager, connection.id);
    beforePump?.call(scope);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: HomeDashboardScreen(
          connManager: manager,
          clientFactory: (conn) => ApiClient(
            baseUrl: conn.baseUrl,
            apiKey: conn.apiKey,
            httpClient: server.client(),
          ),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
        ),
      ),
    );
    return (manager, scope);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets('Home re-reads its recents for the new active profile', (
    tester,
  ) async {
    final server = _Server();
    final (_, scope) = await pumpHome(tester, server);
    await settle(tester);
    expect(find.text('Ana chat'), findsWidgets);
    await scope.switchTo('bob');
    await settle(tester);
    expect(server.reads, ['ana', 'bob']);
    expect(find.text('Bob chat'), findsWidgets);
    expect(find.text('Ana chat'), findsNothing);
    await unmount(tester);
  });

  testWidgets('a switch drops the previous recents before the new ones '
      'arrive', (tester) async {
    final server = _Server();
    final (_, scope) = await pumpHome(tester, server);
    await settle(tester);
    expect(find.text('Ana chat'), findsWidgets);
    final bobGate = server.gates['bob'] = Completer<void>();
    await scope.switchTo('bob');
    await settle(tester);
    expect(find.text('Ana chat'), findsNothing);
    bobGate.complete();
    await settle(tester);
    expect(find.text('Bob chat'), findsWidgets);
    await unmount(tester);
  });

  testWidgets('a late list of the previous profile never paints on the new '
      'one (answer after the new read)', (tester) async {
    final server = _Server()..gates['ana'] = Completer<void>();
    final (_, scope) = await pumpHome(tester, server);
    await settle(tester);
    expect(server.reads, ['ana']);
    await scope.switchTo('bob');
    await settle(tester);
    expect(find.text('Bob chat'), findsWidgets);
    server.gates['ana']!.complete();
    await settle(tester);
    expect(find.text('Ana chat'), findsNothing);
    expect(find.text('Bob chat'), findsWidgets);
    await unmount(tester);
  });

  testWidgets('a late list of the previous profile never paints on the new '
      'one (answer before the new read starts)', (tester) async {
    final anaGate = Completer<void>();
    final bobGate = Completer<void>();
    final server = _Server()
      ..gates['ana'] = anaGate
      ..gates['bob'] = bobGate;
    final (_, scope) = await pumpHome(
      tester,
      server,
      // Registered before Home: releases the old read in the same turn as
      // the switch, ahead of Home's own reload.
      beforePump: (scope) => scope.addListener(() {
        if (scope.owner == 'bob' && !anaGate.isCompleted) anaGate.complete();
      }),
    );
    await settle(tester);
    await scope.switchTo('bob');
    await settle(tester);
    expect(find.text('Ana chat'), findsNothing);
    bobGate.complete();
    await settle(tester);
    expect(find.text('Bob chat'), findsWidgets);
    expect(find.text('Ana chat'), findsNothing);
    await unmount(tester);
  });

  testWidgets('a late list of the previous profile never paints while the '
      'switch reload is still syncing the local agent', (tester) async {
    final anaGate = Completer<void>();
    final server = _Server()..gates['ana'] = anaGate;
    final (_, scope) = await pumpHome(tester, server, withLocalAgent: true);
    await settle(tester);
    // Home starts on ana (held), then moves to zoe and finishes loading.
    await scope.switchTo('zoe');
    await settle(tester);
    expect(find.text('Zoe chat'), findsWidgets);
    // Back to ana (held on the wire), then on to bob: bob's reload stops in
    // the local agent token sync, so the ana answer lands inside the window
    // before any bob status refresh has started.
    final anaAgain = Completer<void>();
    server.gates['ana'] = anaAgain;
    await scope.switchTo('ana');
    await settle(tester);
    holdLocalTokenRead = Completer<void>();
    await scope.switchTo('bob');
    await tester.pump();
    anaGate.complete();
    anaAgain.complete();
    await settle(tester);
    expect(server.reads.where((r) => r == 'bob'), isEmpty);
    expect(find.text('Ana chat'), findsNothing);
    holdLocalTokenRead!.complete();
    holdLocalTokenRead = null;
    await settle(tester);
    expect(find.text('Bob chat'), findsWidgets);
    expect(find.text('Ana chat'), findsNothing);
    await unmount(tester);
  });
}
