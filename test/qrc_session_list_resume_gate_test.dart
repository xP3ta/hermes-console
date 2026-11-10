import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart' show hermesRouteObserver;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_api_client.dart';

/// qrc: the session list covered by a chat does not probe the server on a
/// resume (its probe would only compete with the chat's own recovery); it
/// probes once it is uncovered again.
const _connectionId = 'conn-qrc-list-gate';

SavedConnection _connection() => SavedConnection(
  id: _connectionId,
  label: 'qrc list',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'key',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
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
    for (var attempt = 0; attempt < 30; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a covered list does not probe on resume; it does once back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var statusProbes = 0;
    final gateway = testApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      connectionId: _connectionId,
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/status') statusProbes += 1;
        if (request.url.path == '/api/status' ||
            request.url.path == '/api/sessions') {
          return http.Response('{}', 200);
        }
        return http.Response('{}', 404);
      }),
    );
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/sessions') {
          return http.Response(
            jsonEncode({
              'sessions': <Object>[],
              'total': 0,
              'limit': 50,
              'offset': 0,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(aggregate.dispose);
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
          globalActivityOverride: aggregate,
        ),
      ),
    );
    await settle(tester);
    expect(statusProbes, greaterThan(0), reason: 'the first probe ran');

    WidgetsBindingObserver list() =>
        tester.state(find.byType(SessionListScreen, skipOffstage: false))
            as WidgetsBindingObserver;

    final visibleBefore = statusProbes;
    list().didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle(tester);
    expect(statusProbes, visibleBefore + 1, reason: 'a visible list probes');

    final context = tester.element(find.byType(SessionListScreen));
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('chat over the list')),
        ),
      ),
    );
    await settle(tester);
    expect(find.text('chat over the list'), findsOneWidget);
    final coveredBefore = statusProbes;
    list().didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle(tester);
    expect(statusProbes, coveredBefore, reason: 'covered: no probe');

    Navigator.of(context).pop();
    await settle(tester);
    expect(
      statusProbes,
      coveredBefore + 1,
      reason: 'the probe owed by the covered resume runs once uncovered',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
