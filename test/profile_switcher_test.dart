import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart';
import 'package:hermes_android/core/widgets/profile_switcher.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

AgentProfile _profile(String name, {bool isDefault = false}) =>
    AgentProfile.fromJson({
      'name': name,
      'path': '/home/u/.hermes/profiles/$name',
      'is_default': isDefault,
    });

final _roster = [
  _profile('default', isDefault: true),
  _profile('ana'),
  _profile('bob'),
];

/// Session lists per profile, so a switch shows up in the recents.
http.Client _sessions(List<String> reads) => MockClient((request) async {
  final path = request.url.path;
  if (path == '/health') return http.Response('{"status":"ok"}', 200);
  final match = RegExp(r'^(?:/p/([^/]+))?/api/sessions$').firstMatch(path);
  if (match == null) return http.Response('{}', 404);
  final profile = match.group(1) ?? 'default';
  reads.add(profile);
  return http.Response(
    '{"data":[{"id":"s-$profile","title":"$profile chat","source":"cli",'
    '"started_at":1790000000,"last_active":1790000100}],"has_more":false}',
    200,
  );
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConnectionManager manager;
  late SavedConnection connection;

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
            }
            return null;
          },
        );
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.saveConnection(
      'QA',
      '127.0.0.2',
      8642,
      'test-key',
      kind: InstanceKind.vps,
    );
    connection = manager.getConnections().single;
    await manager.setActiveConnection(connection.id);
    await manager.setActiveProfile(connection.id, 'ana');
    // A live roster, as Bot Mode or Profiles leave it.
    BotRosterRegistry.shared.publish(connection.id, 'QA', _roster);
  });

  tearDown(() => BotRosterRegistry.shared.forget(connection.id));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Widget app(Widget home) => MaterialApp(
    locale: const Locale('en'),
    theme: AppTheme.fromId('dark'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: home,
  );

  testWidgets('Home: the switcher is one tap away and a pick re-scopes Home', (
    tester,
  ) async {
    final reads = <String>[];
    await tester.pumpWidget(
      app(
        HomeDashboardScreen(
          connManager: manager,
          clientFactory: (conn) => ApiClient(
            baseUrl: conn.baseUrl,
            apiKey: conn.apiKey,
            httpClient: _sessions(reads),
          ),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
        ),
      ),
    );
    await settle(tester);
    expect(find.text('ana chat'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('profile-switcher-compact')));
    await settle(tester);
    expect(
      find.byKey(const ValueKey('profile-switcher-sheet')),
      findsOneWidget,
    );
    // The active profile is marked; every profile is offered.
    for (final name in ['default', 'ana', 'bob']) {
      expect(
        find.byKey(ValueKey('profile-switcher-option-$name')),
        findsOneWidget,
      );
    }
    await tester.tap(find.byKey(const ValueKey('profile-switcher-option-bob')));
    await settle(tester);
    expect(manager.activeProfileFor(connection.id), 'bob');
    expect(find.byKey(const ValueKey('profile-switcher-sheet')), findsNothing);
    expect(find.text('bob chat'), findsWidgets);
    expect(find.text('ana chat'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('drawer: the switcher row shows the active profile and the '
      'default profile is picked as the empty name', (tester) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final reads = <String>[];
    final scaffoldKey = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(
      app(
        Scaffold(
          key: scaffoldKey,
          drawer: HermesDrawer(
            connection: connection,
            connManager: manager,
            current: DrawerSection.home,
            recentSessionsClientFactory: (saved) => ApiClient(
              baseUrl: saved.baseUrl,
              apiKey: saved.apiKey,
              httpClient: _sessions(reads),
            ),
          ),
          body: const SizedBox.shrink(),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await settle(tester);
    expect(find.text('Profile: ana'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-switcher-row')));
    await settle(tester);
    await tester.tap(
      find.byKey(const ValueKey('profile-switcher-option-default')),
    );
    await settle(tester);
    expect(manager.activeProfileFor(connection.id), '');
    expect(find.text('Profile: Default'), findsOneWidget);
    expect(find.text('default chat'), findsOneWidget);
    expect(reads, ['ana', 'default']);
  });

  testWidgets('the sheet reads the list only when no live roster exists', (
    tester,
  ) async {
    final registry = BotRosterRegistry();
    var reads = 0;
    final gate = Completer<void>();
    Future<List<AgentProfile>> read() async {
      reads++;
      await gate.future;
      return _roster;
    }

    late BuildContext ctx;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    unawaited(
      showProfileSwitcher(
        ctx,
        connection: connection,
        connManager: manager,
        rosterRegistry: registry,
        readRoster: read,
      ),
    );
    await settle(tester);
    expect(reads, 1);
    gate.complete();
    await settle(tester);
    expect(
      find.byKey(const ValueKey('profile-switcher-option-bob')),
      findsOneWidget,
    );
    Navigator.of(ctx).pop();
    await settle(tester);
    // Now live: opening again shows it without another read.
    unawaited(
      showProfileSwitcher(
        ctx,
        connection: connection,
        connManager: manager,
        rosterRegistry: registry,
        readRoster: read,
      ),
    );
    await settle(tester);
    expect(reads, 1);
    expect(ActiveProfileScope.of(manager, connection.id).owner, 'ana');
  });

  testWidgets('the chip names the default profile as the switcher lists it, '
      'also when the roster lands after the chip', (tester) async {
    final registry = BotRosterRegistry();
    await manager.setActiveProfile(connection.id, '');
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ProfileSwitcherButton(
            connection: connection,
            connManager: manager,
            compact: true,
            rosterRegistry: registry,
            readRoster: () async => const [],
          ),
        ),
      ),
    );
    await settle(tester);
    // No roster yet: the localized default name.
    expect(find.text('Default'), findsOneWidget);
    registry.publish(connection.id, 'QA', [
      AgentProfile.fromJson({
        'name': 'default',
        'path': '/home/u/.hermes',
        'is_default': true,
        'display_name': 'Hermes',
      }),
      _profile('ana'),
    ]);
    await tester.pump();
    final chip = find.byKey(const ValueKey('profile-switcher-compact'));
    expect(
      find.descendant(of: chip, matching: find.text('Hermes')),
      findsOneWidget,
    );
    await tester.tap(chip);
    await settle(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('profile-switcher-option-default')),
        matching: find.text('Hermes'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('cold start: the chip paints the cached display name first, '
      'never the generic default name while the roster read is slow', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await manager.setActiveProfile(connection.id, '');
    // Last session: a live read named the default profile 'Hermes'.
    final previous = BotRosterRegistry()
      ..attachPersistence(prefs, [connection]);
    previous.publish(connection.id, 'QA', [
      AgentProfile.fromJson({
        'name': 'default',
        'path': '/home/u/.hermes',
        'is_default': true,
        'display_name': 'Hermes',
      }),
      _profile('ana'),
    ]);
    await tester.pump();
    // Cold start: a fresh registry restored from the cache only, while the
    // live roster read never answers.
    final registry = BotRosterRegistry()
      ..attachPersistence(prefs, [connection]);
    final slowRead = Completer<List<AgentProfile>>();
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ProfileSwitcherButton(
            connection: connection,
            connManager: manager,
            compact: true,
            rosterRegistry: registry,
            readRoster: () => slowRead.future,
          ),
        ),
      ),
    );
    final chip = find.byKey(const ValueKey('profile-switcher-compact'));
    expect(
      find.descendant(of: chip, matching: find.text('Hermes')),
      findsOneWidget,
    );
    expect(find.text('Default'), findsNothing);
  });

  testWidgets('Home status line names the active profile like the chip, '
      'and follows a switch', (tester) async {
    BotRosterRegistry.shared.publish(connection.id, 'QA', [
      AgentProfile.fromJson({
        'name': 'default',
        'path': '/home/u/.hermes',
        'is_default': true,
        'display_name': 'Hermes',
      }),
      _profile('ana'),
      _profile('bob'),
    ]);
    await tester.pumpWidget(
      app(
        HomeDashboardScreen(
          connManager: manager,
          clientFactory: (conn) => ApiClient(
            baseUrl: conn.baseUrl,
            apiKey: conn.apiKey,
            httpClient: _sessions([]),
          ),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
        ),
      ),
    );
    await settle(tester);
    // The connection is 'QA'; the active profile is 'ana'.
    expect(find.text('online · ana'), findsOneWidget);
    expect(find.text('online · QA'), findsNothing);
    await manager.setActiveProfile(connection.id, 'bob');
    await settle(tester);
    expect(find.text('online · bob'), findsOneWidget);
    await manager.setActiveProfile(connection.id, '');
    await settle(tester);
    expect(find.text('online · Hermes'), findsOneWidget);
    // A roster landing after the paint renames the profile at once.
    BotRosterRegistry.shared.publish(connection.id, 'QA', [
      AgentProfile.fromJson({
        'name': 'default',
        'path': '/home/u/.hermes',
        'is_default': true,
        'display_name': 'Atlas',
      }),
      _profile('ana'),
      _profile('bob'),
    ]);
    await tester.pump();
    expect(find.text('online · Atlas'), findsOneWidget);
    await manager.setActiveProfile(connection.id, 'bob');
    await settle(tester);
    expect(find.text('online · bob'), findsOneWidget);
  });
}
