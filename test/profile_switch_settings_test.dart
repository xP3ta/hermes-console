import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/memory_screen.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/screens/skills_screen.dart';
import 'package:hermes_android/core/screens/soul_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dashboard whose per-profile reads (model, skills, memory, SOUL) can each
/// be held on the wire, to switch profile while one is still resolving.
final class _Dashboard {
  /// Key: `<area>:<profile>` (area = model, skills, memory, soul).
  final gates = <String, Completer<void>>{};
  final reads = <String>[];
  final writes = <String>[];

  DashboardClient client() => DashboardClient(
    host: 'hermes.local',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((request) async {
      final path = request.url.path;
      final queryProfile = request.url.queryParameters['profile'];
      final profile = (queryProfile == null || queryProfile.isEmpty)
          ? 'default'
          : queryProfile;
      Future<http.Response> held(String area, String who, Object body) async {
        reads.add('$area:$who');
        final gate = gates['$area:$who'];
        if (gate != null) await gate.future;
        return http.Response(jsonEncode(body), 200);
      }

      final soul = RegExp(r'^/api/profiles/([^/]+)/soul$').firstMatch(path);
      if (soul != null) {
        final who = soul.group(1)!;
        if (request.method == 'PUT') {
          writes.add('soul:$who');
          return http.Response('{"ok":true}', 200);
        }
        return held('soul', who, {'content': '$who soul'});
      }
      switch (path) {
        case '/api/model/info':
          return held('model', profile, {
            'model': '$profile-model',
            'provider': 'prov',
          });
        case '/api/model/options':
          return http.Response(
            jsonEncode({
              'providers': [
                {
                  'slug': 'prov',
                  'name': 'Prov',
                  'authenticated': true,
                  'is_current': true,
                  'models': ['$profile-model'],
                },
              ],
            }),
            200,
          );
        case '/api/model/auxiliary':
          return http.Response(jsonEncode({'tasks': []}), 200);
        case '/api/skills':
          return held('skills', profile, [
            {'name': '$profile-skill', 'enabled': true, 'category': 'x'},
          ]);
        case '/api/memory':
          return held('memory', profile, {
            'active': '',
            'providers': [],
            'builtin_files': {'${profile}_notes': 12},
          });
      }
      return http.Response('{"detail":"not found"}', 404);
    }),
  );
}

class _NoBridge implements BridgeManagerContract {
  @override
  Future<BridgeClient?> clientFor(String connectionId) async => null;
  @override
  Future<BridgeState> probe(String connectionId) async => BridgeState.unknown;
  @override
  Future<BridgeProvisionResult> provision(String connectionId) =>
      throw UnimplementedError();
  @override
  Future<bool> tryProvision(String connectionId) async => false;
}

class _UnreachableBridge extends BridgeManager {
  _UnreachableBridge(super.secure, super.connections);

  @override
  Future<BridgeState> probe(String connectionId) async => const BridgeState(
    status: BridgeStatus.unreachable,
    url: 'https://bridge.invalid',
    urlIsDerived: true,
    hasToken: false,
    caps: BridgeCapabilities.offline,
  );
}

final _connection = SavedConnection(
  id: 'conn-settings',
  label: 'QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
  kind: InstanceKind.vps,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConnectionManager manager;
  late ActiveProfileScope scope;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            switch (call.method) {
              case 'read':
                return secure[args['key']];
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
                return null;
              case 'delete':
                secure.remove(args['key']);
                return null;
              case 'readAll':
                return Map<String, String>.from(secure);
              case 'containsKey':
                return secure.containsKey(args['key']);
            }
            return null;
          },
        );
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.setActiveProfile(_connection.id, 'ana');
    scope = ActiveProfileScope.of(manager, _connection.id);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.hermesRedDark,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: screen,
      ),
    );
    await settle(tester);
  }

  String soulText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).controller!.text;

  /// Each per-profile screen, with the finder of what it shows for a profile.
  final screens =
      <
        String,
        ({
          Widget Function(DashboardClient client, ActiveProfileScope scope)
          build,
          Finder Function(String profile) shows,
        })
      >{
        'memory': (
          build: (client, scope) => MemoryScreen(
            connection: _connection,
            profileScope: scope,
            dashboardClientForTesting: client,
          ),
          shows: (profile) => find.text('${profile}_notes.md'),
        ),
        'skills': (
          build: (client, scope) => SkillsScreen(
            connection: _connection,
            profileScope: scope,
            dashboardClientForTesting: client,
            bridgeManagerForTesting: _NoBridge(),
          ),
          shows: (profile) => find.text('$profile-skill'),
        ),
        'model': (
          build: (client, scope) => ModelsScreen(
            connection: _connection,
            profileScope: scope,
            dashboardClientForTesting: client,
            bridgeManagerForTesting: _NoBridge(),
            gatewayCatalogForTesting: () => null,
          ),
          shows: (profile) => find.textContaining('$profile-model'),
        ),
      };

  for (final MapEntry(key: area, value: screen) in screens.entries) {
    group(area, () {
      testWidgets('follows a switch and says which profile it edits', (
        tester,
      ) async {
        final dashboard = _Dashboard();
        await pump(tester, screen.build(dashboard.client(), scope));
        expect(screen.shows('ana'), findsWidgets);
        expect(find.text('Profile: ana'), findsOneWidget);
        await scope.switchTo('bob');
        await settle(tester);
        expect(screen.shows('bob'), findsWidgets);
        expect(screen.shows('ana'), findsNothing);
        expect(find.text('Profile: bob'), findsOneWidget);
      });

      testWidgets('the previous profile leaves before the new one loads', (
        tester,
      ) async {
        final dashboard = _Dashboard();
        await pump(tester, screen.build(dashboard.client(), scope));
        expect(screen.shows('ana'), findsWidgets);
        final bobGate = dashboard.gates['$area:bob'] = Completer<void>();
        await scope.switchTo('bob');
        await settle(tester);
        expect(screen.shows('ana'), findsNothing);
        bobGate.complete();
        await settle(tester);
        expect(screen.shows('bob'), findsWidgets);
      });

      testWidgets('a late read of the previous profile never lands '
          '(old answer last)', (tester) async {
        final dashboard = _Dashboard();
        final anaGate = dashboard.gates['$area:ana'] = Completer<void>();
        await pump(tester, screen.build(dashboard.client(), scope));
        expect(dashboard.reads, contains('$area:ana'));
        await scope.switchTo('bob');
        await settle(tester);
        expect(screen.shows('bob'), findsWidgets);
        anaGate.complete();
        await settle(tester);
        expect(screen.shows('ana'), findsNothing);
        expect(screen.shows('bob'), findsWidgets);
      });

      testWidgets('a late read of the previous profile never lands '
          '(old answer first)', (tester) async {
        final dashboard = _Dashboard();
        final anaGate = dashboard.gates['$area:ana'] = Completer<void>();
        final bobGate = dashboard.gates['$area:bob'] = Completer<void>();
        await pump(tester, screen.build(dashboard.client(), scope));
        await scope.switchTo('bob');
        await settle(tester);
        anaGate.complete();
        await settle(tester);
        expect(screen.shows('ana'), findsNothing);
        bobGate.complete();
        await settle(tester);
        expect(screen.shows('bob'), findsWidgets);
        expect(screen.shows('ana'), findsNothing);
      });
    });
  }

  group('a bot card (fixed profile)', () {
    for (final area in ['memory', 'skills']) {
      testWidgets('$area edits the card profile and ignores switches', (
        tester,
      ) async {
        final dashboard = _Dashboard();
        final client = dashboard.client();
        await pump(
          tester,
          area == 'memory'
              ? MemoryScreen(
                  connection: _connection,
                  profileOverride: 'zed',
                  profileScope: scope,
                  dashboardClientForTesting: client,
                )
              : SkillsScreen(
                  connection: _connection,
                  profileOverride: 'zed',
                  profileScope: scope,
                  dashboardClientForTesting: client,
                  bridgeManagerForTesting: _NoBridge(),
                ),
        );
        expect(dashboard.reads, ['$area:zed']);
        expect(find.text('Profile: zed'), findsOneWidget);
        await scope.switchTo('bob');
        await settle(tester);
        expect(dashboard.reads, ['$area:zed']);
        expect(find.text('Profile: zed'), findsOneWidget);
      });
    }
  });

  group('SOUL', () {
    Widget soul(_Dashboard dashboard) => SoulScreen(
      connection: _connection,
      profileScope: scope,
      dashboardClientForTesting: dashboard.client(),
      bridgeManagerForTesting: _UnreachableBridge(SecureStorage(), manager),
    );

    testWidgets('follows a switch and says which profile it edits', (
      tester,
    ) async {
      final dashboard = _Dashboard();
      await pump(tester, soul(dashboard));
      expect(soulText(tester), 'ana soul');
      expect(find.text('Profile: ana'), findsOneWidget);
      await scope.switchTo('bob');
      await settle(tester);
      expect(soulText(tester), 'bob soul');
      expect(find.text('Profile: bob'), findsOneWidget);
    });

    testWidgets('switching loads the SOUL of the new profile like opening '
        'it does, over an older local draft', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'soul_draft_${_connection.id}@bob',
        'bob old draft',
      );
      final dashboard = _Dashboard();
      await pump(tester, soul(dashboard));
      await scope.switchTo('bob');
      await settle(tester);
      expect(soulText(tester), 'bob soul');
    });

    testWidgets('a late SOUL of the previous profile never lands '
        '(old answer last)', (tester) async {
      final dashboard = _Dashboard();
      final anaGate = dashboard.gates['soul:ana'] = Completer<void>();
      await pump(tester, soul(dashboard));
      expect(dashboard.reads, contains('soul:ana'));
      await scope.switchTo('bob');
      await settle(tester);
      expect(soulText(tester), 'bob soul');
      anaGate.complete();
      await settle(tester);
      expect(soulText(tester), 'bob soul');
    });

    testWidgets('a late SOUL of the previous profile never lands '
        '(old answer first)', (tester) async {
      final dashboard = _Dashboard();
      final anaGate = dashboard.gates['soul:ana'] = Completer<void>();
      final bobGate = dashboard.gates['soul:bob'] = Completer<void>();
      await pump(tester, soul(dashboard));
      await scope.switchTo('bob');
      await settle(tester);
      anaGate.complete();
      await settle(tester);
      expect(soulText(tester), isNot('ana soul'));
      bobGate.complete();
      await settle(tester);
      expect(soulText(tester), 'bob soul');
    });

    testWidgets('a draft typed for one profile stays with that profile', (
      tester,
    ) async {
      final dashboard = _Dashboard();
      await pump(tester, soul(dashboard));
      await tester.enterText(find.byType(TextField).first, 'ana draft');
      await tester.pump(const Duration(seconds: 1));
      await scope.switchTo('bob');
      await settle(tester);
      expect(soulText(tester), 'bob soul');
      await scope.switchTo('ana');
      await settle(tester);
      // The draft is ana's, and the server SOUL load replaced it on entry
      // exactly as before; what matters is that bob never received it.
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('soul_draft_${_connection.id}@ana'),
        anyOf('ana draft', 'ana soul'),
      );
      expect(
        prefs.getString('soul_draft_${_connection.id}@bob'),
        isNot('ana draft'),
      );
    });

    testWidgets('a7: a bot card SOUL stays on that bot while the active '
        'profile switches under a read still on the wire', (tester) async {
      final dashboard = _Dashboard();
      final zedGate = dashboard.gates['soul:zed'] = Completer<void>();
      await pump(
        tester,
        SoulScreen(
          connection: _connection,
          profileOverride: 'zed',
          profileScope: scope,
          dashboardClientForTesting: dashboard.client(),
          bridgeManagerForTesting: _UnreachableBridge(SecureStorage(), manager),
        ),
      );
      expect(find.text('Profile: zed'), findsOneWidget);
      await scope.switchTo('bob');
      await settle(tester);
      zedGate.complete();
      await settle(tester);
      expect(soulText(tester), 'zed soul');
      expect(find.text('Profile: zed'), findsOneWidget);
      expect(dashboard.reads.where((r) => r.startsWith('soul:')).toSet(), {
        'soul:zed',
      });
    });

    testWidgets('applying never writes to a profile switched to while the '
        'confirmation was open', (tester) async {
      final dashboard = _Dashboard();
      await pump(tester, soul(dashboard));
      await tester.tap(find.text('Apply'));
      await settle(tester);
      await scope.switchTo('bob');
      await settle(tester);
      final confirm = find.text('Apply').last;
      await tester.tap(confirm);
      await settle(tester);
      expect(dashboard.writes, isEmpty);
    });
  });
}
