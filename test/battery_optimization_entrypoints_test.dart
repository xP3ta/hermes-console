import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/battery_optimization_prompt.dart';
import 'package:hermes_android/core/widgets/battery_optimization_row.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_api_client.dart';

const _title = 'Mantén Console conectada en segundo plano';
const _restoreKey = ValueKey('battery-prompt-restore');

class _HomeClient extends ApiClient {
  _HomeClient()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
        profileDashboard: testDashboardClient(
          baseUrl: 'http://127.0.0.1:8642',
          httpClient: MockClient((_) async => http.Response('{}', 404)),
        ),
      );

  @override
  Future<bool> healthCheck() async => true;
  @override
  Future<bool> healthReachable() async => true;
  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => [];
  @override
  void close() {}
}

Widget _host(Widget child, {bool scroll = true}) => MaterialApp(
  locale: const Locale('es'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: scroll ? Scaffold(body: SingleChildScrollView(child: child)) : child,
);

void _testAndroid(String name, WidgetTesterCallback body) => testWidgets(
  name,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.android),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const richChannel = MethodChannel(PlatformRichNotifications.channelName);
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  late SharedPreferences prefs;
  late List<String> calls;
  Object? status;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    calls = [];
    status = {'ignoringOptimizations': false, 'backgroundRestricted': false};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(richChannel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'batteryStatus' => status,
        'openBatterySettings' => true,
        _ => null,
      };
    });
    final secureValues = <String, String>{};
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      final args = call.arguments as Map;
      switch (call.method) {
        case 'write':
          secureValues[args['key'] as String] = args['value'] as String;
        case 'read':
          return secureValues[args['key']];
        case 'readAll':
          return Map<String, String>.of(secureValues);
        case 'delete':
          secureValues.remove(args['key']);
      }
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(richChannel, null);
    messenger.setMockMethodCallHandler(secureChannel, null);
  });

  Future<ConnectionManager> manager({bool configured = true}) async {
    final manager = await ConnectionManager.create(prefs);
    if (configured) {
      await manager.saveConnection(
        'QA',
        '127.0.0.2',
        8642,
        'test-key',
        kind: InstanceKind.vps,
      );
      await manager.setActiveConnection(manager.getConnections().single.id);
    }
    return manager;
  }

  Future<void> pumpHome(WidgetTester tester, ConnectionManager manager) async {
    await tester.pumpWidget(
      _host(
        HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => _HomeClient(),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
        ),
        scroll: false,
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  _testAndroid('real Home includes the reminder after a connection is saved', (
    tester,
  ) async {
    await pumpHome(tester, await manager());
    final shown = find.text(_title).evaluate().length;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(shown, 1);
  });

  _testAndroid('real Home without connections has no battery reminder', (
    tester,
  ) async {
    await pumpHome(tester, await manager(configured: false));
    expect(find.text(_title), findsNothing);
    expect(calls, isNot(contains('batteryStatus')));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  _testAndroid('Settings restores a dismissed Home reminder persistently', (
    tester,
  ) async {
    await prefs.setBool(kBatteryPromptDismissedPref, true);
    final rich = PlatformRichNotifications();
    await tester.pumpWidget(
      _host(
        BatteryOptimizationRow(
          prefs: prefs,
          load: rich.batteryStatus,
          openSettings: rich.openBatterySettings,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_restoreKey));
    await tester.pumpAndSettle();
    expect(prefs.getBool(kBatteryPromptDismissedPref) ?? false, isFalse);
    expect(find.byKey(_restoreKey), findsNothing);
    expect(calls.where((c) => c != 'batteryStatus'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      _host(BatteryOptimizationPrompt(prefs: prefs, hasConnection: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text(_title), findsOneWidget);
  });
}
