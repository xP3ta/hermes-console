import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/mission_snapshot_cache.dart';
import 'package:hermes_android/core/services/mission_snapshot_prewarm.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts every request Home's status refresh sends to the Gateway.
final class _Server {
  _Server({this.sessionsStatus = 200, this.healthStatus = 200});

  int sessionsStatus;
  final int healthStatus;

  /// Delay of the authenticated list read: a server busy serving other
  /// clients answers /health at once but the paged list late (#1215).
  Duration sessionsDelay = Duration.zero;
  final paths = <String>[];

  int count(String path) => paths.where((p) => p == path).length;

  http.Client client() => MockClient((request) async {
    paths.add(request.url.path);
    switch (request.url.path) {
      case '/health':
        return http.Response('{"status":"ok"}', healthStatus);
      case '/api/sessions':
        if (sessionsDelay > Duration.zero) {
          await Future<void>.delayed(sessionsDelay);
        }
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

  Future<void> pumpHome(
    WidgetTester tester,
    _Server server, {
    MissionSnapshotPrewarm? prewarm,
    bool botModeOpened = false,
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
    if (botModeOpened) {
      await MissionSnapshotPrewarm.markOpened(manager.prefs, connection.id);
    }
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
          missionPrewarm: prewarm,
        ),
      ),
    );
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> settleHome(WidgetTester tester) async {
    for (var attempt = 0; attempt < 30; attempt++) {
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
    await settleHome(tester);
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
    await settleHome(tester);
    expect(find.text('agent online · QA'), findsNothing);
    expect(server.count('/api/sessions'), 1);
    await unmount(tester);
  });

  // #1215: /health answered 200 throughout while a slow or overloaded server
  // made the paged list read time out or fail with 5xx. Home flipped to
  // "offline · QA" on every such refresh and back on the next one.
  for (final failure in ['503', 'timeout']) {
    testWidgets('a reachable server with a slow list read stays online '
        '($failure)', (tester) async {
      final server = _Server();
      await pumpHome(tester, server);
      await settleHome(tester);
      expect(find.text('agent online · QA'), findsOneWidget);
      expect(find.text('Hola'), findsWidgets);

      if (failure == '503') {
        server.sessionsStatus = 503;
      } else {
        server.sessionsDelay = const Duration(seconds: 20);
      }
      final state = tester.state(find.byType(HomeDashboardScreen));
      // Same entry point as a resume or a sessions.changed refresh.
      (state as WidgetsBindingObserver).didChangeAppLifecycleState(
        AppLifecycleState.resumed,
      );
      var offlineSeconds = 0;
      for (var second = 0; second < 25; second++) {
        await tester.pump(const Duration(seconds: 1));
        if (find.text('offline · QA').evaluate().isNotEmpty) {
          offlineSeconds += 1;
        }
      }

      // ignore: avoid_print
      print('[#1215] home $failure: seconds shown offline=$offlineSeconds');
      expect(offlineSeconds, 0);
      expect(find.text('offline · QA'), findsNothing);
      expect(find.text('agent online · QA'), findsOneWidget);
      expect(find.text('Hola'), findsWidgets, reason: 'keep the known list');
      await unmount(tester);
    });
  }

  testWidgets('an unreachable /health keeps Home offline, no list read', (
    tester,
  ) async {
    final server = _Server(healthStatus: 503);
    await pumpHome(tester, server);
    await settleHome(tester);
    expect(find.text('agent online · QA'), findsNothing);
    expect(server.count('/api/sessions'), 0);
    await unmount(tester);
  });

  group('Bot Mode prewarm from Home', () {
    ({MissionSnapshotPrewarm warm, List<_WarmSource> built}) prewarm({
      Completer<void>? hold,
    }) {
      final built = <_WarmSource>[];
      final warm = MissionSnapshotPrewarm(
        cache: MissionSnapshotCache(),
        sourceFactory: (_) {
          final source = _WarmSource(hold: hold);
          built.add(source);
          return source;
        },
      );
      return (warm: warm, built: built);
    }

    testWidgets('Bot Mode used before: one background read once Home idles', (
      tester,
    ) async {
      final p = prewarm();
      await pumpHome(tester, _Server(), prewarm: p.warm, botModeOpened: true);
      expect(p.built, isEmpty, reason: 'not before Home is idle');
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(p.built, hasLength(1));
      expect(p.built.single.loads, 1);
      await tester.pump(const Duration(seconds: 10));
      expect(p.built, hasLength(1), reason: 'never periodic');
      await unmount(tester);
    });

    testWidgets('Bot Mode never used here: no prewarm, no extra network', (
      tester,
    ) async {
      final p = prewarm();
      final server = _Server();
      await pumpHome(tester, server, prewarm: p.warm);
      await tester.pump(const Duration(seconds: 5));
      expect(p.built, isEmpty);
      expect(server.count('/api/sessions'), 1);
      await unmount(tester);
    });

    testWidgets('going to background before Home idles cancels it', (
      tester,
    ) async {
      final p = prewarm();
      await pumpHome(tester, _Server(), prewarm: p.warm, botModeOpened: true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 5));
      expect(p.built, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      // Back in front: Home refreshes and, once idle, warms exactly once.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(p.built, hasLength(1));
      await unmount(tester);
    });

    testWidgets('going to background mid-read tears the read down', (
      tester,
    ) async {
      final hold = Completer<void>();
      final p = prewarm(hold: hold);
      await pumpHome(tester, _Server(), prewarm: p.warm, botModeOpened: true);
      await tester.pump(const Duration(seconds: 2));
      expect(p.built.single.loads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(p.built.single.closes, 1);
      hold.complete();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await unmount(tester);
    });

    testWidgets('an offline instance is not prewarmed', (tester) async {
      final p = prewarm();
      await pumpHome(
        tester,
        _Server(healthStatus: 503),
        prewarm: p.warm,
        botModeOpened: true,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(p.built, isEmpty);
      await unmount(tester);
    });
  });
}

final class _WarmSource implements MissionControlDataSource {
  _WarmSource({this.hold});
  final Completer<void>? hold;
  var loads = 0;
  var closes = 0;

  @override
  Future<MissionBackendSnapshot> load() async {
    loads++;
    await hold?.future;
    return MissionBackendSnapshot(loadedAt: DateTime(2026));
  }

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;
  @override
  void close() => closes++;
}
