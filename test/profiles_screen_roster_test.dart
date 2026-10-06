import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/services/bot_roster_cache.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/bot_roster_fakes.dart';

Finder inScreen(String key, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(key)), matching: matching);

Widget twoScreens(
  ConnectionManager manager,
  BotRosterRegistry registry,
  FakeProfilesServer a,
  FakeProfilesServer b,
) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: Row(
    children: [
      for (final (key, server) in [('A', a), ('B', b)])
        Expanded(
          child: KeyedSubtree(
            key: ValueKey(key),
            child: ProfilesScreen(
              connection: connection,
              connManager: manager,
              rosterRegistry: registry,
              clientOverride: server.client,
            ),
          ),
        ),
    ],
  ),
);

void main() {
  testWidgets(
    'rename on one Profiles screen shows on another at once, and a late older read cannot undo it',
    (tester) async {
      tester.view.physicalSize = const Size(2400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final registry = BotRosterRegistry();
      final a = FakeProfilesServer();
      final b = FakeProfilesServer();
      await tester.pumpWidget(twoScreens(await manager(), registry, a, b));
      await tester.pump();
      a.reads.single.complete(roster(['default', 'ops']));
      await tester.pumpAndSettle();
      // B's first read is still on the wire, yet B already paints A's roster.
      expect(b.reads, hasLength(1));
      expect(inScreen('B', find.text('ops')), findsOneWidget);

      await tester.tap(inScreen('A', find.byTooltip('Rename')).at(1));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ops2');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await tester.pump();
      expect(a.mutations, 1);
      // Same frame as the confirmation: B shows it with no read of its own.
      expect(inScreen('B', find.text('ops2')), findsOneWidget);
      expect(inScreen('B', find.text('ops')), findsNothing);
      expect(b.reads, hasLength(1));

      // B's read started before the rename and lands late with the old name.
      b.reads.single.complete(roster(['default', 'ops']));
      await tester.pumpAndSettle();
      expect(inScreen('A', find.text('ops2')), findsOneWidget);
      expect(inScreen('B', find.text('ops2')), findsOneWidget);
      expect(find.text('ops'), findsNothing);

      // A's post-rename revalidation is authoritative.
      a.reads.last.complete(roster(['default', 'ops2', 'new']));
      await tester.pumpAndSettle();
      expect(inScreen('B', find.text('new')), findsOneWidget);
      expect(b.reads, hasLength(1));
    },
  );

  testWidgets('delete and create on one screen show on the other at once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final registry = BotRosterRegistry();
    final a = FakeProfilesServer();
    final b = FakeProfilesServer();
    await tester.pumpWidget(twoScreens(await manager(), registry, a, b));
    await tester.pump();
    for (final read in [...a.reads, ...b.reads]) {
      read.complete(roster(['default', 'ops']));
    }
    await tester.pumpAndSettle();

    await tester.tap(inScreen('A', find.byTooltip('Delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pump();
    await tester.pump();
    expect(a.mutations, 1);
    expect(inScreen('B', find.text('ops')), findsNothing);
    expect(b.reads, hasLength(1));

    // Creation is confirmed by the builder; the store gets it right away.
    registry.profileCreated(connection.id, const AgentProfile(name: 'made'));
    await tester.pump();
    expect(inScreen('B', find.text('made')), findsOneWidget);
    expect(b.reads, hasLength(1));
    a.reads.last.complete(roster(['default', 'made']));
    await tester.pumpAndSettle();
  });

  testWidgets('cold start shows the cached roster while the read is pending', (
    tester,
  ) async {
    final manager0 = await manager();
    final prefs = manager0.prefs;
    await BotRosterCache(
      prefs,
    ).write(connection, const [AgentProfile(name: 'cached')]);
    final registry = BotRosterRegistry()..attachPersistence(prefs, const []);
    final server = FakeProfilesServer();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: ProfilesScreen(
          connection: connection,
          connManager: manager0,
          rosterRegistry: registry,
          clientOverride: server.client,
        ),
      ),
    );
    await tester.pump();
    expect(server.reads, hasLength(1));
    expect(find.text('cached'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ConsoleLoader), findsNothing);
    server.reads.single.complete(roster(['default', 'live']));
    await tester.pumpAndSettle();
    expect(find.text('live'), findsOneWidget);
    expect(find.text('cached'), findsNothing);
  });
  testWidgets(
    'a server with neither profile list retracts the cached roster everywhere',
    (tester) async {
      final manager0 = await manager();
      final prefs = manager0.prefs;
      await BotRosterCache(
        prefs,
      ).write(connection, const [AgentProfile(name: 'cached')]);
      final registry = BotRosterRegistry()
        ..attachPersistence(prefs, [connection]);
      // Old Dashboard: no /api/profiles.
      final dashboard = DashboardClient(
        host: 'hermes.local',
        manualToken: 'token',
        httpClientOverride: MockClient((_) async => http.Response('{}', 404)),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: ProfilesScreen(
            connection: connection,
            connManager: manager0,
            rosterRegistry: registry,
            clientOverride: dashboard,
            // Old Gateway: no profiles.list.
            gatewayProfilesOverride: () async => throw const TuiGatewayRpcError(
              'profiles.list',
              'Method not found',
              code: -32601,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('cached'), findsNothing);
      expect(registry.store(connection.id).snapshot, isNull);
      expect(BotRosterCache(prefs).read(connection), isEmpty);
    },
  );

  testWidgets('a Gateway failure that is not unsupported keeps the cache', (
    tester,
  ) async {
    final manager0 = await manager();
    final prefs = manager0.prefs;
    await BotRosterCache(
      prefs,
    ).write(connection, const [AgentProfile(name: 'cached')]);
    final registry = BotRosterRegistry()
      ..attachPersistence(prefs, [connection]);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: ProfilesScreen(
          connection: connection,
          connManager: manager0,
          rosterRegistry: registry,
          clientOverride: DashboardClient(
            host: 'hermes.local',
            manualToken: 'token',
            httpClientOverride: MockClient(
              (_) async => http.Response('{}', 404),
            ),
          ),
          gatewayProfilesOverride: () async =>
              throw const TuiGatewayRpcError('profiles.list', 'timeout'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(registry.store(connection.id).profiles.single.name, 'cached');
    expect(BotRosterCache(prefs).read(connection).single.name, 'cached');
  });

  testWidgets('a supported Gateway keeps the cold-start roster flow', (
    tester,
  ) async {
    final manager0 = await manager();
    final prefs = manager0.prefs;
    await BotRosterCache(
      prefs,
    ).write(connection, const [AgentProfile(name: 'cached')]);
    final registry = BotRosterRegistry()
      ..attachPersistence(prefs, [connection]);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: ProfilesScreen(
          connection: connection,
          connManager: manager0,
          rosterRegistry: registry,
          clientOverride: FakeProfilesServer().client,
          gatewayProfilesOverride: () async => const [
            AgentProfile(name: 'live'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('live'), findsOneWidget);
    expect(registry.store(connection.id).isLive, isTrue);
  });
}
