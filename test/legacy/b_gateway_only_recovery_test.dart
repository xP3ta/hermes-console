import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/onboarding/manual_setup_page.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/hermes_setup_commands.dart';
import 'package:hermes_android/core/services/official_dashboard_command.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A 1.2.x connection that only ever had the Gateway (port 8642 and its key,
/// no Dashboard address, no Dashboard secrets) while the Dashboard is not
/// running on the computer.
class _Client extends ApiClient {
  _Client({required this.reachable})
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  final bool reachable;
  @override
  Future<bool> healthCheck() async => reachable;
  @override
  Future<bool> healthReachable() => healthCheck();
  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => <Session>[];

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final retry = find.byKey(const ValueKey('home-offline-retry'));
  final setup = find.byKey(const ValueKey('home-offline-dashboard-setup'));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?) ?? const {};
          switch (call.method) {
            case 'read':
              return secure[args['key']];
            case 'write':
              secure[args['key'] as String] = args['value'] as String;
            case 'readAll':
              return Map<String, String>.from(secure);
          }
          return null;
        });
  });
  tearDown(
    () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  Future<void> pumpHome(WidgetTester t, {required bool reachable}) async {
    t.view.physicalSize = const Size(390, 844) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final manager = (await t.runAsync(
      () => SharedPreferences.getInstance().then(ConnectionManager.create),
    ))!;
    await t.runAsync(() async {
      await manager.saveConnection(
        'Casa',
        '127.0.0.2',
        8642,
        'gateway-key',
        kind: InstanceKind.vps,
      );
      await manager.setActiveConnection(manager.getConnections().single.id);
    });
    await t.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('amber'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => _Client(reachable: reachable),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
          eventStreamOverride: const Stream.empty(),
          activeSessionListLoader: () async => const DesktopActiveSessionList(),
          cronJobsLoader: (_, _) async => const [],
          tasksLoader: (_) async => const KanbanBoard(columns: []),
        ),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('B1: the offline card offers the official Dashboard command '
      'in one tap, without expanding', (t) async {
    await pumpHome(t, reachable: false);
    expect(retry, findsOneWidget);
    expect(setup, findsOneWidget);
    await t.tap(setup);
    await t.pumpAndSettle();
    expect(find.byType(ManualSetupPage), findsOneWidget);
    expect(
      find.text(dashboardSetupCommand(SetupHostSystem.unix)),
      findsOneWidget,
    );
    expect(find.textContaining('0.0.0.0'), findsNothing);
  });

  testWidgets('a Dashboard that answers shows neither the card nor the '
      'button', (t) async {
    await pumpHome(t, reachable: true);
    expect(retry, findsNothing);
    expect(setup, findsNothing);
  });

  test(
    'the Dashboard messages no longer say the chat works or is connected',
    () {
      final claim = RegExp(
        r'chat funciona|chat est[aá] conectado|chat works|chat is connected',
        caseSensitive: false,
      );
      for (final s in <Strings>[StringsEs(), StringsEn()]) {
        for (final text in [s.o2MissingDashboard, s.sDashboardUnreachable]) {
          expect(claim.hasMatch(text), isFalse, reason: text);
        }
      }
    },
  );
}
