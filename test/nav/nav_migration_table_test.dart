// The migration table of the navigation split (artifact
// nav-migration-2026-11-02.md): «Herramientas» had three levels in one tab,
// and now each entry is at its new place. Nothing is lost: this walks the
// table and checks that every old entry is reachable from where it moved.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/profile_hub_screen.dart';
import 'package:hermes_android/core/screens/app_settings_screen.dart';
import 'package:hermes_android/core/services/ssh_profile_presence.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';

import '../support/nav_harness.dart';

/// Where an old entry went.
enum _Place { appSettings, profileHub }

/// One line of the table: the old «Herramientas» entry, where it lives now
/// and the id of its row there.
typedef _Move = ({String old, _Place place, String id});

const _toolsHubMoves = <_Move>[
  (old: 'appearance', place: _Place.appSettings, id: 'appearance'),
  (old: 'mascotas', place: _Place.appSettings, id: 'mascotas'),
  (old: 'instances', place: _Place.appSettings, id: 'instances'),
  (old: 'models', place: _Place.appSettings, id: 'models'),
  (old: 'keys', place: _Place.profileHub, id: 'keys'),
  (old: 'ssh', place: _Place.appSettings, id: 'ssh'),
  (old: 'bot-screen', place: _Place.profileHub, id: 'bot-screen'),
  (old: 'profiles', place: _Place.appSettings, id: 'profiles'),
  (old: 'capabilities', place: _Place.profileHub, id: 'skills'),
  (old: 'memory', place: _Place.profileHub, id: 'memory'),
  (old: 'cron', place: _Place.profileHub, id: 'routines'),
  (old: 'soul', place: _Place.profileHub, id: 'soul'),
  (old: 'usage', place: _Place.profileHub, id: 'usage'),
  (old: 'task-center', place: _Place.profileHub, id: 'task-center'),
  (old: 'activity', place: _Place.profileHub, id: 'logs'),
];

/// What the old Settings screen had that now has an entry in Ajustes de la
/// app. The screen itself stays as the engine of the deep links but has no
/// row («Todos los ajustes» is gone): every part of it is on its own screen.
const _settingsMoves = <_Move>[
  (old: 'connection', place: _Place.appSettings, id: 'instances'),
  (old: 'appearance', place: _Place.appSettings, id: 'appearance-more'),
  (old: 'chat', place: _Place.appSettings, id: 'chat'),
  (old: 'voice', place: _Place.appSettings, id: 'voice-app'),
  (old: 'notifications', place: _Place.appSettings, id: 'notifications'),
  (old: 'security', place: _Place.appSettings, id: 'security'),
  (old: 'vault', place: _Place.profileHub, id: 'vault'),
  (old: 'system', place: _Place.appSettings, id: 'maintenance'),
  (old: 'data', place: _Place.appSettings, id: 'data'),
  (old: 'cache', place: _Place.appSettings, id: 'cache'),
  (old: 'backup', place: _Place.profileHub, id: 'backup'),
  (old: 'about', place: _Place.appSettings, id: 'about'),
];

/// Profiles (pfu): Bots = your bots (bot mode, live state, chat); the screen
/// of Ajustes «Gestionar perfiles» = the server's profiles (create, clone,
/// rename, delete). Its rows open the profile hub; Bots reaches it from its
/// «+» menu, not through a second list.
const _profilesMoves = <_Move>[
  (old: 'profiles', place: _Place.appSettings, id: 'profiles'),
];

/// What the drawer's «Trabajo» had; it stays there and the profile repeats
/// it with its own profile.
const _drawerWorkMoves = <_Move>[
  (old: 'projects', place: _Place.profileHub, id: 'projects'),
  (old: 'kanban', place: _Place.profileHub, id: 'kanban'),
  (old: 'artifacts', place: _Place.profileHub, id: 'artifacts'),
  (old: 'cron', place: _Place.profileHub, id: 'routines'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => SshProfilePresence.instance.value = false);

  Future<(Set<String>, Set<String>)> idsAtNewPlaces(WidgetTester tester) async {
    navView(tester, size: const Size(390, 2400));
    final connection = navConnection();
    final manager = await navManager();
    SshProfilePresence.instance.value = true;
    late BuildContext context;
    await tester.pumpWidget(
      navApp(
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    final settings = buildAppSettingsDestinations(
      context: context,
      connection: connection,
      connManager: manager,
      capabilities: manager.loadCapabilities(connection.id),
    );
    final hub = buildProfileHubEntries(
      context: context,
      connection: connection,
      connManager: manager,
      profile: navSecondary,
      agentProfile: null,
      isActive: false,
      makeActive: () async {},
      profileGateway: null,
      onOpenBotCard: () {},
      hasSshProfile: true,
    );
    return (
      {for (final row in settings) row.id},
      {
        // Model and Skills are the card at the top; the rest are entries.
        'model',
        'skills',
        for (final entry in hub) entry.destination.id,
      },
    );
  }

  testWidgets('every old Herramientas entry is at its new place', (
    tester,
  ) async {
    final (settings, hub) = await idsAtNewPlaces(tester);
    for (final move in _toolsHubMoves) {
      final ids = move.place == _Place.appSettings ? settings : hub;
      expect(ids, contains(move.id), reason: '${move.old} -> ${move.place}');
    }
    // 15 entries, none dropped.
    expect(_toolsHubMoves.map((m) => m.old).toSet(), hasLength(15));
  });

  testWidgets('every old Settings area is reachable from its new place', (
    tester,
  ) async {
    final (settings, hub) = await idsAtNewPlaces(tester);
    for (final move in _settingsMoves) {
      final ids = move.place == _Place.appSettings ? settings : hub;
      expect(ids, contains(move.id), reason: '${move.old} -> ${move.place}');
    }
    // The old screen has no row of its own any more.
    expect(settings, isNot(contains('all-settings')));
  });

  testWidgets('the server\'s profiles are managed from Ajustes, and the old '
      'voice row of the full list has its own row there', (tester) async {
    final (settings, _) = await idsAtNewPlaces(tester);
    for (final move in _profilesMoves) {
      expect(settings, contains(move.id), reason: move.old);
    }
    expect(settings, contains('voice-app'));
  });

  testWidgets('what the drawer\'s Trabajo had is repeated in the profile', (
    tester,
  ) async {
    final (_, hub) = await idsAtNewPlaces(tester);
    for (final move in _drawerWorkMoves) {
      expect(hub, contains(move.id), reason: move.old);
    }
  });

  testWidgets('no row is in both places, and the profile\'s rows are not in '
      'Ajustes', (tester) async {
    final (settings, hub) = await idsAtNewPlaces(tester);
    // `logs`, `models` style names that exist in both are server views in
    // Ajustes and profile views in the hub; the ids that name one thing must
    // not be in both.
    for (final profileOnly in const [
      'memory',
      'soul',
      'usage',
      'keys',
      'vault',
      'voice',
      'routines',
      'task-center',
    ]) {
      expect(settings, isNot(contains(profileOnly)), reason: profileOnly);
    }
    for (final appOnly in const [
      'instances',
      'ssh',
      'profiles',
      'extensions',
      'notifications',
    ]) {
      expect(hub, isNot(contains(appOnly)), reason: appOnly);
    }
  });

  test('the dock\'s destinations: Herramientas is gone, Ajustes and '
      'Agentes are in', () {
    expect(GestureDockTab.defaultLayout.map((t) => t.name), [
      'home',
      'create',
      'search',
      'bots',
      'agents',
      'settings',
    ]);
    expect(GestureDockTab.values.map((t) => t.name), isNot(contains('tools')));
  });
}
