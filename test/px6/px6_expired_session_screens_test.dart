// SPDX-License-Identifier: GPL-3.0-only
// PX6: a Dashboard that refuses the saved login (401 session_expired) must
// read the same on Home, Conversations and the instance panel: a plain
// sentence and a Sign in button, never «CoreReadException» / «HTTP 401».
// Other failures (503) keep their Retry.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _expiredBody =
    'Your session on this Hermes has expired. Sign in again with your browser.';
const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// What Hermes answers on /api/sessions when the session is gone.
http.Response _answer(int status) => status == 401
    ? http.Response(jsonEncode({'error': 'session_expired'}), 401)
    : http.Response(jsonEncode({'detail': 'unavailable'}), status);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('en'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: home,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          final args = call.arguments is Map
              ? Map<Object?, Object?>.from(call.arguments as Map)
              : const <Object?, Object?>{};
          switch (call.method) {
            case 'write':
              secure[args['key'] as String] = args['value'] as String;
              return null;
            case 'read':
              return secure[args['key']];
            case 'readAll':
              return Map<String, String>.of(secure);
            case 'delete':
              secure.remove(args['key']);
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<(ConnectionManager, SavedConnection)> manager({
    String profile = 'default',
  }) async {
    final m = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await m.saveConnection(
      'QA',
      '127.0.0.2',
      8642,
      'test-key',
      kind: InstanceKind.vps,
    );
    final c = m.getConnections().single;
    await m.setActiveConnection(c.id);
    await m.setActiveProfile(c.id, profile);
    return (m, c);
  }

  // ── Home ────────────────────────────────────────────────────────────────

  Future<void> pumpHome(
    WidgetTester tester, {
    required int listStatus,
    required String profile,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (m, _) = await manager(profile: profile);
    await tester.pumpWidget(
      _app(
        HomeDashboardScreen(
          connManager: m,
          clientFactory: (conn) => ApiClient(
            baseUrl: conn.baseUrl,
            apiKey: 'test-key',
            httpClient: MockClient((request) async {
              if (request.url.path == '/health') {
                return http.Response('{"status":"ok"}', 200);
              }
              return _answer(listStatus);
            }),
          ),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
        ),
      ),
    );
    await _settle(tester);
  }

  final homeCard = find.byKey(const ValueKey('home-profile-list-error'));
  Finder inCard(Finder what) => find.descendant(of: homeCard, matching: what);

  for (final profile in ['default', 'console-builder']) {
    testWidgets('Home ($profile): an expired session reads plainly and '
        'offers Sign in', (tester) async {
      await pumpHome(tester, listStatus: 401, profile: profile);
      expect(homeCard, findsOneWidget);
      expect(inCard(find.text(_expiredBody)), findsOneWidget);
      expect(inCard(find.textContaining('refused')), findsNothing);
      expect(inCard(find.text('Retry')), findsNothing);
      await tester.tap(inCard(find.text('Sign in')));
      await _settle(tester);
      expect(find.byType(DashboardSetupScreen), findsOneWidget);
      await _unmount(tester);
    });
  }

  testWidgets('Home: a 503 keeps its Retry and no Sign in', (tester) async {
    await pumpHome(tester, listStatus: 503, profile: 'default');
    expect(homeCard, findsOneWidget);
    expect(inCard(find.text('Retry')), findsOneWidget);
    expect(inCard(find.text('Sign in')), findsNothing);
    await _unmount(tester);
  });

  // ── Conversations ───────────────────────────────────────────────────────

  Future<void> pumpList(WidgetTester tester, {required int listStatus}) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (m, conn) = await manager();
    // A Dashboard-only connection: liveness is the public /api/status, the
    // list read is the proof of the login (as on a real Hermes).
    final dashboard = DashboardClient(
      host: '127.0.0.2',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient((request) async {
        if (request.url.path == '/api/status') {
          return http.Response('{}', 200);
        }
        return _answer(listStatus);
      }),
    );
    final gateway = ApiClient(
      baseUrl: conn.baseUrl,
      apiKey: 'test-key',
      connectionId: conn.id,
      profileDashboard: dashboard,
      httpClient: MockClient((request) async => _answer(listStatus)),
    );
    final repository = SessionRepository(dashboard, gateway);
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(() {
      repository.close();
      dashboard.close();
      aggregate.dispose();
    });
    await tester.pumpWidget(
      _app(
        SessionListScreen(
          connection: conn,
          connManager: m,
          clientOverride: gateway,
          repositoryOverride: repository,
          globalActivityOverride: aggregate,
        ),
      ),
    );
    await _settle(tester);
  }

  testWidgets('Conversations: an expired session reads plainly and offers '
      'Sign in', (tester) async {
    await pumpList(tester, listStatus: 401);
    expect(find.text(_expiredBody), findsOneWidget);
    expect(find.textContaining('CoreReadException'), findsNothing);
    expect(find.textContaining('HTTP 401'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
    await tester.tap(find.text('Sign in'));
    await _settle(tester);
    expect(find.byType(DashboardSetupScreen), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('Conversations: a 503 keeps Retry, in plain words, no Sign in', (
    tester,
  ) async {
    await pumpList(tester, listStatus: 503);
    expect(find.text('retry'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('HTTP'), findsNothing);
    expect(
      find.text("Couldn't load the list. Check the connection and try again."),
      findsOneWidget,
    );
    await _unmount(tester);
  });

  // ── Instance panel ──────────────────────────────────────────────────────

  Future<void> pumpPanel(
    WidgetTester tester, {
    required DashboardAuthCheck auth,
  }) async {
    final (m, conn) = await manager();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          Strings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: InstanceStatusPanel(
              connection: conn,
              connManager: m,
              reachable: (_) async => true,
              dashboardAuth: (_) async => auth,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Panel: a refused login offers Sign in', (tester) async {
    await pumpPanel(tester, auth: DashboardAuthCheck.loginRequired);
    expect(find.text('Sign in'), findsOneWidget);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(DashboardSetupScreen), findsOneWidget);
  });

  testWidgets('Panel: a working login has no Sign in', (tester) async {
    await pumpPanel(tester, auth: DashboardAuthCheck.ok);
    expect(find.text('Sign in'), findsNothing);
  });
}
