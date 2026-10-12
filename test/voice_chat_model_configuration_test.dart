import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LoopbackHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late IOClient io;
  late DashboardClient dashboard;
  late SavedConnection connection;
  late ActiveProfileScope scope;
  final writes = <Map<String, dynamic>>[];
  final reads = <String>[];
  final state = <String, Map<String, dynamic>>{};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    writes.clear();
    reads.clear();
    state
      ..clear()
      ..addAll({
        'a': {
          'task': 'voice_chat',
          'provider': 'auto',
          'model': '',
          'reasoning_effort': 'none',
        },
        'b': {
          'task': 'voice_chat',
          'provider': 'synthetic',
          'model': 'voice-b',
          'reasoning_effort': 'low',
        },
      });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Created before testWidgets installs its rejecting HTTP override.
    io = IOClient(
      HttpOverrides.runWithHttpOverrides(() => HttpClient(), _LoopbackHttp()),
    );
    dashboard = DashboardClient(
      host: '127.0.0.1',
      port: server.port,
      manualToken: 'synthetic',
      httpClientOverride: io,
    );
    connection = SavedConnection(
      id: 'voice-config',
      label: 'Synthetic',
      host: '127.0.0.1',
      port: 8642,
      apiKey: '',
      kind: InstanceKind.vps,
    );
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.setActiveProfile(connection.id, 'a');
    scope = ActiveProfileScope.of(manager, connection.id);
    server.listen((request) async {
      reads.add(request.uri.toString());
      final profile = request.uri.queryParameters['profile'] ?? 'default';
      Object response = {};
      switch (request.uri.path) {
        case '/api/model/info':
          response = {'model': 'main-$profile', 'provider': 'synthetic'};
        case '/api/model/options':
          response = {
            'providers': [
              {
                'slug': 'synthetic',
                'name': 'Synthetic',
                'authenticated': true,
                'models': ['voice-b', 'main-a', 'main-b'],
              },
            ],
          };
        case '/api/model/auxiliary':
          response = {
            'tasks': [
              state[profile]!,
              {
                'task': 'vision',
                'provider': 'synthetic',
                'model': 'unchanged-vision',
                'reasoning_effort': 'high',
              },
            ],
          };
        case '/api/model/set':
          final body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          writes.add({'profile': profile, ...body});
          expect(body['scope'], 'auxiliary');
          expect(body['task'], 'voice_chat');
          final current = state[profile]!;
          current['provider'] = body['provider'];
          current['model'] = body['model'];
          if (body.containsKey('reasoning_effort')) {
            current['reasoning_effort'] = body['reasoning_effort'];
          }
          response = {'ok': true};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
  });
  tearDown(() async {
    dashboard.close();
    io.close();
    await server.close(force: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> mount(WidgetTester tester) async {
    dashboard.close();
    io.close();
    io = IOClient(
      HttpOverrides.runWithHttpOverrides(() => HttpClient(), _LoopbackHttp()),
    );
    dashboard = DashboardClient(
      host: '127.0.0.1',
      port: server.port,
      manualToken: 'synthetic',
      httpClientOverride: io,
    );
    tester.view.physicalSize = const Size(600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.hermesRedDark,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: ModelsScreen(
          connection: connection,
          profileScope: scope,
          dashboardClientForTesting: dashboard,
          gatewayCatalogForTesting: () => null,
        ),
      ),
    );
    await settle(tester);
    final section = find.text('Models by function');
    expect(
      reads.any(
        (url) =>
            url.contains('/api/model/auxiliary') && url.contains('profile=a'),
      ),
      isTrue,
      reason: '$reads',
    );
    if (section.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        section,
        300,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(section);
    await tester.tap(section);
    await settle(tester);
    expect(find.text('Voice conversation'), findsOneWidget);
  }

  Future<void> pick(WidgetTester tester, String label) async {
    final finder = find.byKey(const ValueKey('voice-chat-reasoning'));
    if (finder.evaluate().isEmpty) {
      await tester.ensureVisible(find.text('Models by function'));
      await tester.tap(find.text('Models by function'));
      await settle(tester);
    }
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await settle(tester);
  }

  testWidgets(
    'voice reasoning saves nullable inherit per profile and preserves model/main/other role',
    (tester) async {
      await mount(tester);
      expect(
        find.byKey(const ValueKey('voice-chat-reasoning')),
        findsOneWidget,
      );
      expect(writes, isEmpty);
      await pick(tester, 'Use general setting');
      expect(writes.single, {
        'profile': 'a',
        'provider': 'auto',
        'model': '',
        'scope': 'auxiliary',
        'task': 'voice_chat',
        'reasoning_effort': null,
      });
      expect(state['a']!['reasoning_effort'], isNull);
      await tester.runAsync(() => scope.switchTo('b'));
      await settle(tester);
      expect(state['b']!['reasoning_effort'], 'low');
      await pick(tester, 'Off');
      expect(writes.last, {
        'profile': 'b',
        'provider': 'synthetic',
        'model': 'voice-b',
        'scope': 'auxiliary',
        'task': 'voice_chat',
        'reasoning_effort': 'none',
      });
      await tester.runAsync(() => scope.switchTo('a'));
      await settle(tester);
      await tester.ensureVisible(find.text('Models by function'));
      await tester.tap(find.text('Models by function'));
      await settle(tester);
      expect(find.text('Use general setting'), findsWidgets);
      await pick(tester, 'Off');
      expect(writes.last['profile'], 'a');
      expect(writes.last['reasoning_effort'], 'none');
      await tester.pumpWidget(const SizedBox());
      await mount(tester);
      expect(find.text('Off'), findsWidgets);
      expect(writes, hasLength(3));
      expect(state['b']!['model'], 'voice-b');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'voice model picker save/load and automatic preserve the reasoning assignment',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('Voice conversation'));
      await settle(tester);
      await tester.tap(
        find.byKey(const ValueKey('models-picker-synthetic-voice-b')),
      );
      await settle(tester);
      expect(writes.single, {
        'profile': 'a',
        'provider': 'synthetic',
        'model': 'voice-b',
        'scope': 'auxiliary',
        'task': 'voice_chat',
      });
      expect(state['a']!['reasoning_effort'], 'none');
      if (find.text('Voice conversation').evaluate().isEmpty) {
        await tester.tap(find.text('Models by function'));
        await settle(tester);
      }
      expect(find.text('voice-b · synthetic'), findsOneWidget);
      await tester.tap(find.text('Voice conversation'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('models-picker-default')));
      await settle(tester);
      expect(writes.last, {
        'profile': 'a',
        'provider': 'auto',
        'model': '',
        'scope': 'auxiliary',
        'task': 'voice_chat',
      });
      expect(state['a']!['reasoning_effort'], 'none');
      expect(state['b']!['model'], 'voice-b');
      expect(writes, hasLength(2));
      await tester.pumpWidget(const SizedBox());
      await mount(tester);
      expect(find.text('Off'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
