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

class _HealthyClient extends ApiClient {
  _HealthyClient()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<bool> healthReachable() => healthCheck();

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
  }) async => <Session>[];

  @override
  void close() {}
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

  Future<void> pumpHome(
    WidgetTester tester,
    DashboardAuthCheck auth, {
    Locale locale = const Locale('en'),
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
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => _HealthyClient(),
          dashboardAuthProbe: (_) async => auth,
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

  testWidgets('Home does not claim the agent is online with a rejected '
      'Dashboard password', (tester) async {
    await pumpHome(tester, DashboardAuthCheck.invalidCredentials);
    expect(find.text('agent online · QA'), findsNothing);
    expect(find.text('wrong Dashboard password · QA'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('Home shows a missing Dashboard login in Spanish', (
    tester,
  ) async {
    await pumpHome(
      tester,
      DashboardAuthCheck.loginRequired,
      locale: const Locale('es'),
    );
    expect(find.text('agent online · QA'), findsNothing);
    expect(find.text('falta iniciar sesión en Dashboard · QA'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('Home stays online when the Dashboard login is accepted', (
    tester,
  ) async {
    await pumpHome(tester, DashboardAuthCheck.ok);
    expect(find.text('agent online · QA'), findsOneWidget);
    await unmount(tester);
  });
}
