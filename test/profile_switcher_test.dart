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
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/core/widgets/profile_switcher.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/face_halo.dart';
import 'support/test_api_client.dart';

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
  if (path == '/api/status') return http.Response('{"status":"ok"}', 200);
  if (path != '/api/sessions') return http.Response('{}', 404);
  final profile = request.url.queryParameters['profile'] ?? 'default';
  reads.add(profile);
  return http.Response(
    '{"sessions":[{"id":"s-$profile","title":"$profile chat","source":"cli",'
    '"started_at":1790000000,"last_active":1790000100}],"total":1}',
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
          clientFactory: (conn) => testApiClient(
            baseUrl: conn.baseUrl,
            httpClient: _sessions(reads),
          ),
          dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
        ),
      ),
    );
    await settle(tester);
    // With bots, Home's board is Ahora, Bots, Salas and Cron: the profile's
    // chat is named in Ahora, as the last thing that finished.
    expect(find.textContaining('ana chat'), findsWidgets);
    // A tap on the avatar opens the switcher.
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
    expect(find.textContaining('bob chat'), findsWidgets);
    expect(find.textContaining('ana chat'), findsNothing);
    // The pick is announced and the avatar follows the new profile.
    expect(find.text('Active profile: bob'), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-face-bob')), findsWidgets);
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
            recentSessionsClientFactory: (saved) => testApiClient(
              baseUrl: saved.baseUrl,
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
    expect(find.text('Profile: Hermes'), findsOneWidget);
    expect(find.text('default chat'), findsOneWidget);
    expect(reads, ['ana', 'default']);
  });

  testWidgets('drawer: the main profile is named by its own name, the one of '
      'the Bots list, never by «Hermes» nor «default»', (tester) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await manager.setActiveProfile(connection.id, '');
    BotRosterRegistry.shared.publish(connection.id, 'QA', [
      const AgentProfile(
        name: 'default',
        isDefault: true,
        displayName: 'Hermes',
        botModeUiMeta: {'title': 'xPeta'},
      ),
      _profile('ana'),
    ]);
    final scaffoldKey = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(
      app(
        Scaffold(
          key: scaffoldKey,
          drawer: HermesDrawer(
            connection: connection,
            connManager: manager,
            current: DrawerSection.home,
            recentSessionsClientFactory: (saved) => testApiClient(
              baseUrl: saved.baseUrl,
              httpClient: _sessions(<String>[]),
            ),
          ),
          body: const SizedBox.shrink(),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await settle(tester);
    expect(find.text('Profile: xPeta'), findsOneWidget);
    expect(find.text('Profile: Hermes'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('profile-switcher-row')));
    await settle(tester);
    final main = find.byKey(const ValueKey('profile-switcher-option-default'));
    expect(
      find.descendant(of: main, matching: find.text('xPeta')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: main, matching: find.text('Hermes')),
      findsNothing,
    );
    // Another profile keeps its own name.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('profile-switcher-option-ana')),
        matching: find.text('ana'),
      ),
      findsOneWidget,
    );
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

  testWidgets('QA 9494: the button face sits straight on its fill, no dark '
      'backing squircle around it', (tester) async {
    tester.view.physicalSize = const Size(240, 120);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = AppTheme.fromId('console');
    final registry = BotRosterRegistry()
      ..publish(connection.id, 'QA', [
        _profile('default', isDefault: true),
        AgentProfile.fromJson({
          'name': 'ana',
          'path': '/home/u/.hermes/profiles/ana',
          'ui_meta': {
            'hermes-bots': {'shape': 'blobatar::cloud'},
          },
        }),
      ]);
    await tester.pumpWidget(
      RepaintBoundary(
        key: haloShotKey,
        child: MaterialApp(
          locale: const Locale('en'),
          theme: theme,
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            body: Center(
              child: ProfileSwitcherButton(
                connection: connection,
                connManager: manager,
                compact: true,
                rosterRegistry: registry,
                readRoster: () async => const [],
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    final colors = theme.hermes;
    final chip = Color.alphaBlend(
      colors.textPrimary.withValues(alpha: 0.06),
      colors.background,
    );
    // Only the fill is probed. The ring and the chevron badge are drawn on
    // purpose: there the scene's own pixels are what is expected.
    final ring = tester.getRect(
      find.byKey(const ValueKey('profile-switcher-avatar')),
    );
    final badge = tester
        .getRect(find.byKey(const ValueKey('profile-switcher-chevron')))
        .inflate(1);
    final scene = await grabShot(tester);
    final report = await probeHalo(
      tester,
      faces: find.descendant(
        of: find.byKey(const ValueKey('profile-switcher-avatar')),
        matching: find.byType(HermesBotFace),
      ),
      behind: (px, py) {
        final p = Offset((px + .5) / haloScale, (py + .5) / haloScale);
        final onFill =
            (p - ring.center).distance < ring.shortestSide / 2 - 3 &&
            !badge.contains(p);
        return onFill ? chip : scene.at(px, py);
      },
      theme: theme,
      band: 2,
    );
    expect(report.checked, greaterThan(500), reason: '$report');
    expect(
      report.bad,
      lessThanOrEqualTo(report.checked ~/ 100),
      reason: '$report',
    );
  });

  testWidgets('the button names the default profile as the switcher lists '
      'it, also when the roster lands after the button', (tester) async {
    final registry = BotRosterRegistry();
    final semantics = tester.ensureSemantics();
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
    final chip = find.byKey(const ValueKey('profile-switcher-compact'));
    // No roster yet: the localized default name. Spoken, never drawn.
    expect(tester.getSemantics(chip).label, 'Profile: Default');
    expect(
      find.descendant(of: chip, matching: find.byType(Text)),
      findsNothing,
    );
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
    expect(
      tester.getSemantics(chip),
      isSemantics(
        isButton: true,
        hasTapAction: true,
        label: 'Profile: Hermes',
        hint: 'Switch profile',
      ),
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
    semantics.dispose();
  });

  testWidgets('cold start: the button carries the cached display name '
      'first, never the generic default name while the roster read is slow', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
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
    expect(tester.getSemantics(chip).label, 'Profile: Hermes');
    expect(find.bySemanticsLabel(RegExp('Default')), findsNothing);
    semantics.dispose();
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
          clientFactory: (conn) =>
              testApiClient(baseUrl: conn.baseUrl, httpClient: _sessions([])),
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

  group('the sheet', () {
    Future<void> open(
      WidgetTester tester, {
      VoidCallback? onViewProfile,
    }) async {
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
          onViewProfile: onViewProfile,
        ),
      );
      await settle(tester);
    }

    List<AgentProfile> many(int count) => [
      _profile('default', isDefault: true),
      for (var i = 1; i < count; i++)
        _profile('bot-${i.toString().padLeft(2, '0')}'),
    ];

    testWidgets('lists every profile with its state: the active one says '
        'Active and carries the check, the others are free', (tester) async {
      await open(tester);
      final ana = find.byKey(const ValueKey('profile-switcher-option-ana'));
      expect(
        find.descendant(of: ana, matching: find.text('Active')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: ana, matching: find.byIcon(Icons.check_rounded)),
        findsOneWidget,
      );
      final bob = find.byKey(const ValueKey('profile-switcher-option-bob'));
      expect(
        find.descendant(of: bob, matching: find.text('free')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bob, matching: find.byIcon(Icons.check_rounded)),
        findsNothing,
      );
      // No «Ver perfil» unless the caller offers it.
      expect(
        find.byKey(const ValueKey('profile-switcher-view-profile')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('profile-switcher-search')),
        findsNothing,
      );
    });

    testWidgets('a single profile is listed and can be picked', (tester) async {
      BotRosterRegistry.shared.publish(connection.id, 'QA', [
        _profile('default', isDefault: true),
      ]);
      await open(tester);
      expect(
        find.byKey(const ValueKey('profile-switcher-option-default')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-switcher-option-ana')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('profile-switcher-option-default')),
      );
      await settle(tester);
      expect(manager.activeProfileFor(connection.id), '');
      expect(
        find.byKey(const ValueKey('profile-switcher-sheet')),
        findsNothing,
      );
    });

    testWidgets('«Ver perfil» closes the sheet and opens the page', (
      tester,
    ) async {
      var views = 0;
      await open(tester, onViewProfile: () => views++);
      await tester.tap(
        find.byKey(const ValueKey('profile-switcher-view-profile')),
      );
      await settle(tester);
      expect(views, 1);
      expect(
        find.byKey(const ValueKey('profile-switcher-sheet')),
        findsNothing,
      );
      // Nothing was switched.
      expect(manager.activeProfileFor(connection.id), 'ana');
    });

    testWidgets('eight profiles: no search; nine: a search that narrows the '
        'list and says when nothing matches', (tester) async {
      BotRosterRegistry.shared.publish(connection.id, 'QA', many(8));
      await open(tester);
      expect(
        find.byKey(const ValueKey('profile-switcher-search')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      BotRosterRegistry.shared.publish(connection.id, 'QA', many(12));
      await open(tester);
      final search = find.byKey(const ValueKey('profile-switcher-search'));
      expect(search, findsOneWidget);
      expect(tester.getSize(search).height, greaterThanOrEqualTo(48));
      await tester.enterText(search, 'bot-03');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('profile-switcher-option-bot-03')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-switcher-option-bot-04')),
        findsNothing,
      );
      await tester.enterText(search, 'zzz');
      await tester.pump();
      expect(find.text('No profile matches'), findsOneWidget);
      await tester.enterText(search, '');
      await tester.pump();
      expect(find.text('No profile matches'), findsNothing);
      expect(
        find.byKey(const ValueKey('profile-switcher-option-default')),
        findsOneWidget,
      );
    });

    testWidgets('many profiles scroll inside the sheet and the last one can '
        'be picked', (tester) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      BotRosterRegistry.shared.publish(connection.id, 'QA', many(30));
      await open(tester);
      expect(tester.takeException(), isNull);
      final last = find.byKey(const ValueKey('profile-switcher-option-bot-29'));
      expect(last, findsNothing);
      await tester.scrollUntilVisible(
        last,
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('profile-switcher-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(last);
      await settle(tester);
      expect(manager.activeProfileFor(connection.id), 'bot-29');
    });

    for (final locale in Strings.supportedLocales) {
      testWidgets('${locale.languageCode}: 2x text, phone width, the sheet '
          'with a search does not overflow and keeps 48 dp targets', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        BotRosterRegistry.shared.publish(connection.id, 'QA', many(12));
        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            theme: AppTheme.fromId('dark'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: Builder(
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
            onViewProfile: () {},
            onManage: () {},
          ),
        );
        await settle(tester);
        expect(tester.takeException(), isNull);
        for (final key in const [
          'profile-switcher-search',
          'profile-switcher-option-default',
          'profile-switcher-view-profile',
          'profile-switcher-manage',
        ]) {
          expect(
            tester.getSize(find.byKey(ValueKey(key))).height,
            greaterThanOrEqualTo(48),
            reason: key,
          );
        }
      });
    }
  });

  testWidgets('the avatar is a selector: a tap opens the sheet, a long press '
      'opens the page; Semantics announce both', (tester) async {
    final semantics = tester.ensureSemantics();
    var pages = 0;
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ProfileSwitcherButton(
            connection: connection,
            connManager: manager,
            compact: true,
            onOpenProfile: () => pages++,
          ),
        ),
      ),
    );
    await settle(tester);
    final chip = find.byKey(const ValueKey('profile-switcher-compact'));
    expect(
      find.byKey(const ValueKey('profile-switcher-chevron')),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(chip),
      isSemantics(
        isButton: true,
        hasTapAction: true,
        hasLongPressAction: true,
        label: 'Profile: ana',
        hint: 'Switch profile',
      ),
    );
    await tester.longPress(chip);
    await settle(tester);
    expect(pages, 1);
    expect(find.byKey(const ValueKey('profile-switcher-sheet')), findsNothing);
    await tester.tap(chip);
    await settle(tester);
    expect(
      find.byKey(const ValueKey('profile-switcher-sheet')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('profile-switcher-view-profile')),
    );
    await settle(tester);
    expect(pages, 2);
    semantics.dispose();
  });
}
