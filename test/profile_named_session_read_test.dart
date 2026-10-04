import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One host with the two Hermes listeners a named profile meets: the API
/// server (:8642) and the Dashboard (:9119).
///
/// The API server answers `/p/<name>/api/sessions` exactly as Hermes does
/// when that profile has no `API_SERVER_KEY` of its own
/// (`gateway/platforms/api_server.py` `_check_auth`): 401 with the
/// `gateway_auth_failed` body, even with the connection's valid key.
final class _Hermes {
  final gatewayPaths = <String>[];
  final dashboardQueries = <Map<String, String>>[];
  int dashboardStatus = 200;

  http.Client client() => MockClient((request) async {
    final url = request.url;
    if (url.port == 9119) {
      if (url.path == '/') {
        return http.Response(
          '<html><script>window.__HERMES_SESSION_TOKEN__="dash";</script>',
          200,
        );
      }
      if (url.path != '/api/sessions') return http.Response('{}', 404);
      dashboardQueries.add(url.queryParameters);
      if (dashboardStatus != 200) {
        return http.Response('{"detail":"no"}', dashboardStatus);
      }
      final profile = url.queryParameters['profile'] ?? 'default';
      return http.Response(
        '{"sessions":[{"id":"s-$profile","title":"Builder chat",'
        '"source":"cli","started_at":1790000000,"last_active":1790000100,'
        '"profile":"$profile","is_default_profile":false}],'
        '"total":1,"limit":40,"offset":0,"storage":{}}',
        200,
      );
    }
    gatewayPaths.add(url.path);
    if (url.path == '/health') return http.Response('{"status":"ok"}', 200);
    if (url.path.startsWith('/p/')) {
      return http.Response(
        '{"error":{"message":"Invalid gateway API key (API_SERVER_KEY)",'
        '"type":"gateway_auth_error","code":"gateway_auth_failed"}}',
        401,
      );
    }
    return http.Response('{"data":[],"has_more":false}', 200);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DashboardClient.resetSharedPasswordSessionsForTesting();
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
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  ApiClient clientFor(SavedConnection conn, _Hermes hermes) => ApiClient(
    baseUrl: conn.baseUrl,
    apiKey: 'test-key',
    httpClient: hermes.client(),
    profileDashboard: DashboardClient(
      host: conn.dashboardHost,
      port: conn.dashboardPort,
      httpClientOverride: hermes.client(),
    ),
  );

  Future<ConnectionManager> pumpHome(
    WidgetTester tester,
    _Hermes hermes, {
    String profile = 'console-builder',
    ApiClient Function(SavedConnection conn)? clientFactory,
  }) async {
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
    await manager.setActiveProfile(connection.id, profile);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: HomeDashboardScreen(
          connManager: manager,
          clientFactory: clientFactory ?? (conn) => clientFor(conn, hermes),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
        ),
      ),
    );
    await settle(tester);
    return manager;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  group('a named profile list', () {
    test('is read from the Dashboard with the Desktop request shape', () async {
      final hermes = _Hermes();
      final conn = SavedConnection(
        id: 'c',
        label: 'QA',
        host: '127.0.0.2',
        port: 8642,
        apiKey: 'test-key',
        kind: InstanceKind.vps,
      );
      final client = clientFor(conn, hermes);
      final rows = await client.getSessions(
        profile: 'console-builder',
        pageSize: 40,
        maxPages: 3,
      );
      client.close();
      expect(rows.map((s) => (s.id, s.profile)), [
        ('s-console-builder', 'console-builder'),
      ]);
      expect(hermes.gatewayPaths, isEmpty);
      expect(hermes.dashboardQueries, [
        {
          'limit': '40',
          'offset': '0',
          'min_messages': '0',
          'archived': 'exclude',
          'order': 'recent',
          'profile': 'console-builder',
        },
      ]);
    });

    test('maps a Dashboard refusal to a typed read failure', () async {
      final hermes = _Hermes()..dashboardStatus = 403;
      final conn = SavedConnection(
        id: 'c',
        label: 'QA',
        host: '127.0.0.2',
        port: 8642,
        apiKey: 'test-key',
        kind: InstanceKind.vps,
      );
      final client = clientFor(conn, hermes);
      await expectLater(
        client.getSessions(profile: 'console-builder'),
        throwsA(
          isA<CoreReadException>()
              .having((e) => e.kind, 'kind', CoreReadErrorKind.forbidden)
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
      client.close();
    });

    test('the default profile keeps the API server route', () async {
      final hermes = _Hermes();
      final conn = SavedConnection(
        id: 'c',
        label: 'QA',
        host: '127.0.0.2',
        port: 8642,
        apiKey: 'test-key',
        kind: InstanceKind.vps,
      );
      final client = clientFor(conn, hermes);
      await client.getSessions(profile: 'default', pageSize: 40);
      client.close();
      expect(hermes.dashboardQueries, isEmpty);
      expect(hermes.gatewayPaths, ['/api/sessions']);
    });
  });

  testWidgets('Home on a named profile lists its chats and stays online', (
    tester,
  ) async {
    final hermes = _Hermes();
    await pumpHome(tester, hermes);
    expect(find.text('Builder chat'), findsWidgets);
    expect(find.byKey(const ValueKey('home-offline-retry')), findsNothing);
    expect(find.textContaining('offline ·'), findsNothing);
    expect(hermes.gatewayPaths.where((p) => p.startsWith('/p/')), isEmpty);
    await unmount(tester);
  });
}
