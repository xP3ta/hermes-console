import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts every request Home's status refresh sends to the Gateway.
final class _Server {
  _Server({this.sessionsStatus = 200, this.healthStatus = 200});

  final int sessionsStatus;
  final int healthStatus;
  final paths = <String>[];

  int count(String path) => paths.where((p) => p == path).length;

  http.Client client() => MockClient((request) async {
    paths.add(request.url.path);
    switch (request.url.path) {
      case '/health':
        return http.Response('{"status":"ok"}', healthStatus);
      case '/api/sessions':
        if (sessionsStatus != 200) return http.Response('{}', sessionsStatus);
        return http.Response(
          '{"data":[{"id":"s-1","title":"Hola","source":"cli",'
          '"started_at":1790000000,"last_active":1790000100}],'
          '"has_more":false}',
          200,
        );
    }
    return http.Response('{}', 404);
  });
}

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

  Future<void> pumpHome(WidgetTester tester, _Server server) async {
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.saveConnection(
      'QA',
      '127.0.0.2',
      8642,
      'test-key',
      kind: InstanceKind.vps,
    );
    final connection = manager.getConnections().single;
    await manager.setActiveConnection(connection.id);
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
            apiKey: 'test-key',
            httpClient: server.client(),
          ),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
        ),
      ),
    );
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  // The status refresh fetched /api/sessions twice in series: once inside
  // healthCheck as an auth proof, then again as the paged list. The list
  // read already proves the key works.
  testWidgets('a Home status refresh reads /api/sessions once', (tester) async {
    final server = _Server();
    await pumpHome(tester, server);
    expect(find.text('agent online · QA'), findsOneWidget);
    expect(find.text('Hola'), findsWidgets);
    expect(server.count('/health'), 1);
    expect(server.count('/api/sessions'), 1);
    await unmount(tester);
  });

  testWidgets('a rejected session list still shows Home offline', (
    tester,
  ) async {
    final server = _Server(sessionsStatus: 401);
    await pumpHome(tester, server);
    expect(find.text('agent online · QA'), findsNothing);
    expect(server.count('/api/sessions'), 1);
    await unmount(tester);
  });

  testWidgets('an unreachable /health keeps Home offline, no list read', (
    tester,
  ) async {
    final server = _Server(healthStatus: 503);
    await pumpHome(tester, server);
    expect(find.text('agent online · QA'), findsNothing);
    expect(server.count('/api/sessions'), 0);
    await unmount(tester);
  });
}
