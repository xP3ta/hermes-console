import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
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

final _connection = SavedConnection(
  id: 'conn-lists',
  label: 'QA',
  host: 'hermes.test',
  port: 443,
  apiKey: 'test-key',
  useHttps: true,
  kind: InstanceKind.vps,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  late ConnectionManager manager;
  late ActiveProfileScope scope;

  setUp(() async {
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
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.setActiveProfile(_connection.id, 'ana');
    scope = ActiveProfileScope.of(manager, _connection.id);
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Widget host(Widget child) => MaterialApp(
    locale: const Locale('en'),
    theme: AppTheme.fromId('dark'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: child,
  );

  group('Conversations', () {
    Future<void> pumpList(WidgetTester tester, _Server server) async {
      await tester.pumpWidget(
        host(
          SessionListScreen(
            connection: _connection,
            connManager: manager,
            clientOverride: ApiClient(
              baseUrl: _connection.baseUrl,
              apiKey: _connection.apiKey,
              httpClient: server.client(),
            ),
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets('a switch drops the old rows at once and lists the new '
        'profile', (tester) async {
      final server = _Server();
      await pumpList(tester, server);
      expect(find.text('Ana chat'), findsWidgets);
      server.gates['bob'] = Completer<void>();
      await scope.switchTo('bob');
      await settle(tester);
      // Bob is still loading: Ana's chats must already be gone.
      expect(find.text('Ana chat'), findsNothing);
      server.gates['bob']!.complete();
      await settle(tester);
      expect(find.text('Bob chat'), findsWidgets);
      expect(server.reads.last, 'bob');
    });

    testWidgets('a late list of the previous profile never paints on the '
        'new one', (tester) async {
      final anaGate = Completer<void>();
      final server = _Server()..gates['ana'] = anaGate;
      // The screen opens while ana's list is still on the wire...
      await pumpList(tester, server);
      expect(server.reads, contains('ana'));
      // ...when the user switches to bob, whose list answers first.
      await scope.switchTo('bob');
      await settle(tester);
      expect(find.text('Bob chat'), findsWidgets);
      anaGate.complete();
      await settle(tester);
      expect(find.text('Ana chat'), findsNothing);
      expect(find.text('Bob chat'), findsWidgets);
    });
  });

  group('Drawer recents', () {
    Future<void> pumpDrawer(WidgetTester tester, _Server server) async {
      // Tall enough for the drawer list to build its Recents rows.
      tester.view.physicalSize = const Size(600, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        host(
          Scaffold(
            key: scaffoldKey,
            drawer: HermesDrawer(
              connection: _connection,
              connManager: manager,
              current: DrawerSection.home,
              recentSessionsClientFactory: (saved) => ApiClient(
                baseUrl: saved.baseUrl,
                apiKey: saved.apiKey,
                httpClient: server.client(),
              ),
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      );
      scaffoldKey.currentState!.openDrawer();
      await settle(tester);
    }

    testWidgets('an open drawer follows a switch', (tester) async {
      final server = _Server();
      await pumpDrawer(tester, server);
      expect(find.text('Ana chat'), findsOneWidget);
      await scope.switchTo('bob');
      await settle(tester);
      expect(find.text('Bob chat'), findsOneWidget);
      expect(find.text('Ana chat'), findsNothing);
    });

    testWidgets('a late list of the previous profile never paints on the '
        'new one', (tester) async {
      final anaGate = Completer<void>();
      final server = _Server()..gates['ana'] = anaGate;
      await pumpDrawer(tester, server);
      expect(server.reads, ['ana']);
      await scope.switchTo('bob');
      await settle(tester);
      expect(find.text('Bob chat'), findsOneWidget);
      anaGate.complete();
      await settle(tester);
      expect(find.text('Ana chat'), findsNothing);
      expect(find.text('Bob chat'), findsOneWidget);
    });

    testWidgets('a late list of the previous profile never paints when it '
        'lands last', (tester) async {
      final anaGate = Completer<void>();
      final bobGate = Completer<void>();
      final server = _Server()
        ..gates['ana'] = anaGate
        ..gates['bob'] = bobGate;
      await pumpDrawer(tester, server);
      await scope.switchTo('bob');
      await settle(tester);
      bobGate.complete();
      await settle(tester);
      anaGate.complete();
      await settle(tester);
      expect(find.text('Ana chat'), findsNothing);
      expect(find.text('Bob chat'), findsOneWidget);
    });
  });
}
