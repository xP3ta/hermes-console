// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// Desktop keeps the model catalog in its query cache: reopening its model
// settings paints the last answer at once and refreshes behind. The server can
// take seconds to build `/api/model/options`, so Console reopened Models on a
// loader every time. These pin the cached first paint, its honest failure and
// its per-profile scope, plus the Home prewarm hand-over.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/models_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _connectionId = 'models-snapshot';

SavedConnection _connection() => SavedConnection(
  id: _connectionId,
  label: 'Synthetic snapshot',
  host: 'snapshot.example.test',
  port: 8642,
  apiKey: 'synthetic-gateway',
  kind: InstanceKind.vps,
);

class _Transport {
  Completer<void>? optionsGate;
  bool optionsFail = false;
  String providerName = 'Acme';
  int optionsReads = 0;
  final writes = <http.Request>[];
  bool keyDeleted = false;

  DashboardClient client() => DashboardClient(
    host: 'snapshot.example.test',
    manualToken: 'synthetic-snapshot-identity',
    httpClientOverride: MockClient((request) async {
      final profile = request.url.queryParameters['profile'] ?? 'default';
      if (request.method != 'GET') {
        writes.add(request);
        if (request.url.path == '/api/env') keyDeleted = true;
        return http.Response('{"ok":true,"found":true}', 200);
      }
      switch (request.url.path) {
        case '/api/model/info':
          return http.Response(
            jsonEncode({'model': '$profile-main', 'provider': 'acme'}),
            200,
          );
        case '/api/model/options':
          optionsReads++;
          final name = providerName;
          await optionsGate?.future;
          if (optionsFail) return http.Response('{"detail":"busy"}', 503);
          return http.Response(
            jsonEncode({
              'providers': [
                {
                  'slug': 'acme',
                  'name': '$name $profile',
                  'authenticated': true,
                  'is_current': true,
                  'models': ['$profile-main'],
                },
                // Connected by its key and not in use: it can be removed.
                if (!keyDeleted)
                  {
                    'slug': 'beta',
                    'name': 'Beta',
                    'authenticated': true,
                    'models': ['beta-1'],
                  },
              ],
            }),
            200,
          );
        case '/api/model/auxiliary':
          return http.Response(
            jsonEncode({
              'tasks': <Object>[],
              'main': {'provider': 'acme', 'model': '$profile-main'},
            }),
            200,
          );
        case '/api/env':
          return http.Response(
            jsonEncode({
              'BETA_API_KEY': {
                'is_set': !keyDeleted,
                'category': 'provider',
                'is_password': true,
                'provider': 'beta',
                'provider_label': 'Beta key',
                'provider_primary': true,
              },
            }),
            200,
          );
        case '/api/providers/custom-endpoints':
          return http.Response('{"endpoints":[]}', 200);
        case '/api/config':
          return http.Response('{"fallback_providers":[]}', 200);
        case '/api/providers/oauth':
          return http.Response('{"providers":[]}', 200);
        default:
          return http.Response('{}', 404);
      }
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConnectionManager manager;
  late ActiveProfileScope scope;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.setActiveProfile(_connectionId, 'ana');
    scope = ActiveProfileScope.of(manager, _connectionId);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(
    WidgetTester tester,
    _Transport transport,
    ModelsSnapshotCache cache, {
    ModelsSnapshotPrewarm? prewarm,
    DashboardClient? client,
  }) async {
    tester.view.physicalSize = const Size(412, 2400);
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
          key: UniqueKey(),
          connection: _connection(),
          profileScope: scope,
          dashboardClientForTesting: client ?? transport.client(),
          gatewayCatalogForTesting: () => null,
          snapshotCache: cache,
          snapshotPrewarm: prewarm,
        ),
      ),
    );
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets(
    'reopening paints the last catalog while the server rebuilds it',
    (tester) async {
      final transport = _Transport();
      final cache = ModelsSnapshotCache();
      await open(tester, transport, cache);
      await settle(tester);
      expect(find.text('Acme ana'), findsWidgets);
      await close(tester);

      transport
        ..optionsGate = Completer<void>()
        ..providerName = 'Renamed';
      await open(tester, transport, cache);
      await tester.pump();
      await tester.pump();
      expect(find.byType(ConsoleLoader), findsNothing);
      expect(find.text('Acme ana'), findsWidgets);

      transport.optionsGate!.complete();
      await settle(tester);
      expect(find.text('Renamed ana'), findsWidgets);
      expect(find.text('Acme ana'), findsNothing);
      await close(tester);
    },
  );

  testWidgets('a failed refresh keeps the last catalog and says it could not '
      'be refreshed', (tester) async {
    final transport = _Transport();
    final cache = ModelsSnapshotCache();
    await open(tester, transport, cache);
    await settle(tester);
    await close(tester);

    transport.optionsFail = true;
    await open(tester, transport, cache);
    await settle(tester);
    expect(find.text('Acme ana'), findsWidgets);
    final s = Strings.of(tester.element(find.byType(ModelsScreen)));
    expect(find.byKey(const ValueKey('models-load-failed')), findsOneWidget);
    expect(find.text(s.mdlLoadError), findsOneWidget);
    expect(find.text(s.mdlRetry), findsOneWidget);
    await close(tester);
  });

  testWidgets('another profile never paints the cached catalog of the first', (
    tester,
  ) async {
    final transport = _Transport();
    final cache = ModelsSnapshotCache();
    await open(tester, transport, cache);
    await settle(tester);
    await close(tester);

    transport.optionsGate = Completer<void>();
    await scope.switchTo('bob');
    await open(tester, transport, cache);
    await tester.pump();
    await tester.pump();
    expect(find.text('Acme ana'), findsNothing);
    expect(find.byType(ConsoleLoader), findsOneWidget);
    transport.optionsGate!.complete();
    await settle(tester);
    expect(find.text('Acme bob'), findsWidgets);
    await close(tester);
  });

  testWidgets(
    'Models takes over the read Home started instead of a second one',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final transport = _Transport()..optionsGate = Completer<void>();
      final cache = ModelsSnapshotCache();
      final prewarm = ModelsSnapshotPrewarm(
        cache: cache,
        clientFactory: (_) => transport.client(),
        idleDelay: Duration.zero,
      );
      prewarm.schedule(
        prefs: prefs,
        connection: _connection(),
        profileOwner: 'ana',
        stillIdle: () => true,
      );
      await tester.pump();
      expect(transport.optionsReads, 0, reason: 'never opened: no prewarm');

      await ModelsSnapshotPrewarm.markOpened(prefs, _connectionId);
      prewarm.schedule(
        prefs: prefs,
        connection: _connection(),
        profileOwner: 'ana',
        stillIdle: () => true,
      );
      await tester.pump(const Duration(milliseconds: 10));
      expect(transport.optionsReads, 1);

      await open(tester, transport, cache, prewarm: prewarm);
      await tester.pump();
      transport.optionsGate!.complete();
      await settle(tester);
      expect(find.text('Acme ana'), findsWidgets);
      expect(transport.optionsReads, 1, reason: 'the warm read is reused');
      expect(cache.read(_connection(), 'ana'), isNotNull);
      await close(tester);
    },
  );

  Future<void> tapFirst(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target.first);
    await tester.pump();
    await tester.tap(target.first);
    await settle(tester);
  }

  testWidgets('leaving before the reload after a change lands never '
      'repaints the pre-change catalog on the next open', (tester) async {
    final transport = _Transport();
    final cache = ModelsSnapshotCache();
    await open(tester, transport, cache);
    await settle(tester);
    expect(find.text('Acme ana'), findsWidgets);

    // Remove Beta's key; the reload that follows is still being built.
    await tapFirst(
      tester,
      find.byKey(const ValueKey('configured-key-BETA_API_KEY')),
    );
    await tapFirst(
      tester,
      find.byKey(const ValueKey('models-key-remove-BETA_API_KEY')),
    );
    transport.optionsGate = Completer<void>();
    await tapFirst(
      tester,
      find.descendant(
        of: find.byKey(const ValueKey('hermes-dialog')),
        matching: find.text('Remove'),
      ),
    );
    expect(transport.writes.single.method, 'DELETE');
    await close(tester);
    transport.optionsGate!.complete();
    await settle(tester);

    // Next open: the loader, never the catalog read before the change.
    transport.optionsGate = Completer<void>();
    await open(tester, transport, cache);
    await tester.pump();
    await tester.pump();
    expect(find.byType(ConsoleLoader), findsOneWidget);
    expect(find.byKey(const ValueKey('mdl-revalidating')), findsNothing);
    transport.optionsGate!.complete();
    await settle(tester);
    await close(tester);
  });

  testWidgets('a seeded paint says it is refreshing until the server answers', (
    tester,
  ) async {
    final transport = _Transport();
    final cache = ModelsSnapshotCache();
    await open(tester, transport, cache);
    await settle(tester);
    expect(find.byKey(const ValueKey('mdl-revalidating')), findsNothing);
    await close(tester);

    transport.optionsGate = Completer<void>();
    await open(tester, transport, cache);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('mdl-revalidating')), findsOneWidget);
    transport.optionsGate!.complete();
    await settle(tester);
    expect(find.byKey(const ValueKey('mdl-revalidating')), findsNothing);
    await close(tester);
  });

  testWidgets('a change discards the read Home issued before it', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await ModelsSnapshotPrewarm.markOpened(prefs, _connectionId);
    final transport = _Transport()..optionsGate = Completer<void>();
    final cache = ModelsSnapshotCache();
    final prewarm = ModelsSnapshotPrewarm(
      cache: cache,
      clientFactory: (_) => transport.client(),
      idleDelay: Duration.zero,
    );
    prewarm.schedule(
      prefs: prefs,
      connection: _connection(),
      profileOwner: 'ana',
      stillIdle: () => true,
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(transport.optionsReads, 1);

    final claimed = prewarm.claim(_connection(), 'ana');
    expect(claimed, isNotNull);
    expect(
      prewarm.claim(_connection(), 'ana'),
      isNull,
      reason: 'a claimed read answers one load only',
    );
    prewarm.discard(_connection(), 'ana');
    transport.optionsGate!.complete();
    await tester.runAsync(() => claimed!.then((_) {}, onError: (_) {}));
    await tester.pump();
    expect(cache.read(_connection(), 'ana'), isNull);
  });

  testWidgets('opening Models marks the connection for the Home prewarm', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    expect(ModelsSnapshotPrewarm.wasOpened(prefs, _connectionId), isFalse);
    await open(tester, _Transport(), ModelsSnapshotCache());
    await settle(tester);
    expect(ModelsSnapshotPrewarm.wasOpened(prefs, _connectionId), isTrue);
    await close(tester);
  });
}
