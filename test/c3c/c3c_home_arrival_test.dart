// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/onboarding_arrival.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records the routes Home pushes. ChatScreen needs the whole app above it,
/// so the test reads what the route would build instead of mounting it.
class _Pushes extends NavigatorObserver {
  final List<Route<dynamic>> routes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) routes.add(route);
  }

  List<ChatScreen> chats(BuildContext context) => [
    for (final route in routes)
      if (route is MaterialPageRoute<dynamic>)
        if (route.builder(context) case final ChatScreen chat) chat,
  ];
}

class _Healthy extends ApiClient {
  _Healthy()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'synthetic-key',
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final values = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments is Map
              ? Map<Object?, Object?>.from(call.arguments as Map)
              : const <Object?, Object?>{};
          switch (call.method) {
            case 'write':
              values[args['key'] as String] = args['value'] as String;
              return null;
            case 'read':
              return values[args['key']];
            case 'readAll':
              return Map<String, String>.of(values);
            case 'delete':
              values.remove(args['key']);
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    OnboardingArrival.reset();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// Home with two connections, `other` first and `fresh` active, like a
  /// phone that just finished the onboarding for `fresh`.
  Future<(ConnectionManager, String)> pumpHome(
    WidgetTester tester, {
    required void Function(String freshId, String otherId) before,
    required _Pushes pushes,
  }) async {
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.saveConnection(
      'Other',
      '127.0.0.3',
      8642,
      'synthetic-key',
      kind: InstanceKind.vps,
    );
    await manager.saveConnection(
      'Fresh',
      '127.0.0.2',
      8642,
      'synthetic-key',
      kind: InstanceKind.vps,
    );
    final other = manager.getConnections().firstWhere(
      (c) => c.label == 'Other',
    );
    final fresh = manager.getConnections().firstWhere(
      (c) => c.label == 'Fresh',
    );
    await manager.setActiveConnection(fresh.id);
    await manager.setActiveProfile(other.id, 'work');
    before(fresh.id, other.id);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        navigatorObservers: [pushes],
        home: HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => _Healthy(),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return (manager, fresh.id);
  }

  testWidgets('RED 1/6: no request, Home opens no chat', (tester) async {
    final pushes = _Pushes();
    await pumpHome(tester, pushes: pushes, before: (_, _) {});
    expect(pushes.routes, isEmpty);
  });

  testWidgets('RED 5: the request opens one new chat of the new connection '
      'and leaves the other one’s profile alone', (tester) async {
    final pushes = _Pushes();
    final (manager, freshId) = await pumpHome(
      tester,
      pushes: pushes,
      before: (fresh, _) => OnboardingArrival.request(fresh),
    );
    // The chat itself cannot mount without the app above it.
    tester.takeException();
    final context = tester.element(find.byType(MaterialApp));
    final chat = pushes.chats(context).single;
    expect(chat.connection.id, freshId);
    expect(chat.session.messageCount, 0);
    expect(manager.activeProfileFor(freshId), '');
    expect(
      manager.activeProfileFor(
        manager.getConnections().firstWhere((c) => c.id != freshId).id,
      ),
      'work',
    );
    // One-shot: nothing is left to open a second chat.
    expect(OnboardingArrival.take(freshId), isFalse);
  });

  testWidgets('RED 6: a request for another connection opens nothing', (
    tester,
  ) async {
    final pushes = _Pushes();
    await pumpHome(
      tester,
      pushes: pushes,
      before: (_, other) => OnboardingArrival.request(other),
    );
    expect(pushes.routes, isEmpty);
  });

  testWidgets('RED 6: a request older than 30 s opens nothing', (tester) async {
    final pushes = _Pushes();
    await pumpHome(
      tester,
      pushes: pushes,
      before: (fresh, _) {
        var now = DateTime(2026, 10, 18, 12);
        OnboardingArrival.now = () => now;
        OnboardingArrival.request(fresh);
        now = now.add(const Duration(seconds: 45));
      },
    );
    expect(pushes.routes, isEmpty);
  });
}
