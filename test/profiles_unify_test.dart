// Perfiles (1.4.0 «pfu»): no longer a dead end. Each row shows the profile's
// real face and visible name, a tap opens its hub (model, skills,
// integrations…), the active one is checked and the menu keeps the server
// administration (identity, make active, chat, rename, clone, delete). The
// Ajustes entry is «Gestionar perfiles».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/profile_hub_screen.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/bot_create_screen.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/profile_face.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/bot_roster_fakes.dart';
import 'support/nav_harness.dart';
import 'support/profile_model_fakes.dart';

const _forge = AgentProfile(
  name: 'console-builder',
  description: 'Construye la app',
  model: 'gpt-5.5',
  provider: 'openai',
  skillCount: 7,
  botModeUiMeta: {'title': 'Forja'},
);
const _profiles = [
  AgentProfile(name: 'default', isDefault: true, model: 'base-model'),
  _forge,
  AgentProfile(name: 'oficina'),
];

late SavedConnection _conn;
late ConnectionManager _manager;
final _chats = <String>[];

Future<void> _pumpProfiles(
  WidgetTester tester, {
  Locale locale = const Locale('es'),
  Size size = const Size(390, 1800),
  double scale = 1,
  SavedConnection? connection,
  String? active,
}) async {
  navView(tester, size: size, scale: scale);
  _conn = connection ?? navConnection();
  _manager = await navManager();
  if (active != null) await _manager.setActiveProfile(_conn.id, active);
  await tester.pumpWidget(
    navApp(
      ProfilesScreen(
        connection: _conn,
        connManager: _manager,
        rosterRegistry: BotRosterRegistry(),
        clientOverride: FakeProfilesServer().client,
        gatewayProfilesOverride: () async => _profiles,
        chatOpenerOverride: (p) async => _chats.add(p.name),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Finder _row(String name) => find.byKey(ValueKey('profile-row-$name'));
Finder _more(String name) => find.byKey(ValueKey('profile-more-$name'));

Future<void> _openMenu(WidgetTester tester, String name) async {
  // The list builds lazily: at 2x text the last rows start below the fold.
  if (_more(name).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      _more(name),
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.tap(_more(name));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// An item of the open menu, scrolled to (the menu is a list: at 2x text the
/// last items start below the fold).
Future<Finder> _menuItem(WidgetTester tester, String key) async {
  final item = find.byKey(ValueKey(key));
  if (item.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      item,
      80,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('profile-more-menu')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  return item;
}

void main() {
  setUp(() {
    _chats.clear();
    ProfileFace.debugResetAvatarCaches();
    ProfileHubScreen.debugGateway = FakeModelGateway();
  });
  tearDown(() {
    ProfileHubScreen.debugGateway = null;
    ProfileFace.debugResetAvatarCaches();
  });

  testWidgets('each row shows the profile\'s face, its visible name and its '
      'description', (tester) async {
    await _pumpProfiles(tester);
    // The same face component as the drawer and the switcher, never a
    // generic icon.
    expect(
      find.descendant(
        of: _row('console-builder'),
        matching: find.byKey(const ValueKey('profile-face-console-builder')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _row('console-builder'),
        matching: find.text('Forja'),
      ),
      findsOneWidget,
    );
    // The server's name, the model and the description go under it.
    final subtitle = find.descendant(
      of: _row('console-builder'),
      matching: find.textContaining('console-builder'),
    );
    expect(subtitle, findsOneWidget);
    final text = tester.widget<Text>(subtitle).data!;
    expect(text, contains('gpt-5.5'));
    expect(text, contains('Construye la app'));
    expect(find.byType(ProfileFace), findsNWidgets(3));
  });

  testWidgets('a tap on a row opens that profile\'s hub, not nothing', (
    tester,
  ) async {
    await _pumpProfiles(tester);
    await tester.tap(_row('console-builder'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final hub = tester.widget<ProfileHubScreen>(find.byType(ProfileHubScreen));
    expect(hub.profile, 'console-builder');
    // The hub's own header names the profile with its visible name.
    expect(
      find.descendant(
        of: find.byType(ProfileHubScreen),
        matching: find.text('Forja'),
      ),
      findsWidgets,
    );
  });

  testWidgets('the active row opens its hub too', (tester) async {
    await _pumpProfiles(tester, active: 'console-builder');
    await tester.tap(_row('console-builder'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ProfileHubScreen), findsOneWidget);
  });

  testWidgets('the hub of a profile from Perfiles opens Skills of THAT '
      'profile', (tester) async {
    await _pumpProfiles(tester);
    await tester.tap(_row('console-builder'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('tool-skills')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final screen = tester.widget<CapabilitiesScreen>(
      find.byType(CapabilitiesScreen),
    );
    expect(screen.destinationLabel, contains('console-builder'));
    expect(_manager.activeProfileFor(_conn.id), isNot('console-builder'));
  });

  testWidgets('only the active profile wears the check', (tester) async {
    await _pumpProfiles(tester, active: 'console-builder');
    expect(
      find.byKey(const ValueKey('profile-active-check-console-builder')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-active-check-oficina')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('profile-active-check-default')),
      findsNothing,
    );
  });

  group('the menu keeps the administration', () {
    testWidgets('a secondary profile: everything', (tester) async {
      await _pumpProfiles(tester);
      await _openMenu(tester, 'oficina');
      for (final key in [
        'profile-edit-bot',
        'profile-make-active',
        'profile-open-chat',
        'profile-rename',
        'profile-clone',
        'profile-delete',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
    });

    testWidgets('the active one has nothing to make active; the default one '
        'cannot be deleted', (tester) async {
      await _pumpProfiles(tester, active: 'oficina');
      await _openMenu(tester, 'oficina');
      expect(find.byKey(const ValueKey('profile-make-active')), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      await _openMenu(tester, 'default');
      expect(find.byKey(const ValueKey('profile-delete')), findsNothing);
      expect(find.byKey(const ValueKey('profile-clone')), findsOneWidget);
    });

    testWidgets('«Hacer activo» moves the check', (tester) async {
      await _pumpProfiles(tester);
      await _openMenu(tester, 'console-builder');
      await tester.tap(find.byKey(const ValueKey('profile-make-active')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_manager.activeProfileFor(_conn.id), 'console-builder');
      expect(
        find.byKey(const ValueKey('profile-active-check-console-builder')),
        findsOneWidget,
      );
    });

    testWidgets('«Abrir chat» makes it active and opens its chat', (
      tester,
    ) async {
      await _pumpProfiles(tester);
      await _openMenu(tester, 'oficina');
      await tester.tap(find.byKey(const ValueKey('profile-open-chat')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_chats, ['oficina']);
      expect(_manager.activeProfileFor(_conn.id), 'oficina');
    });

    testWidgets('«Clonar» opens the create form with that profile as the '
        'source', (tester) async {
      await _pumpProfiles(tester);
      await _openMenu(tester, 'console-builder');
      await tester.tap(find.byKey(const ValueKey('profile-clone')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final form = tester.widget<BotCreateScreen>(find.byType(BotCreateScreen));
      expect(form.initialCloneFrom, 'console-builder');
    });

    testWidgets('a read-only instance cannot edit or clone', (tester) async {
      await _pumpProfiles(tester, connection: navConnection(readOnly: true));
      await _openMenu(tester, 'oficina');
      expect(find.byKey(const ValueKey('profile-edit-bot')), findsNothing);
      expect(find.byKey(const ValueKey('profile-clone')), findsNothing);
      expect(find.byKey(const ValueKey('profile-rename')), findsOneWidget);
    });
  });

  testWidgets('the screen is called «Gestionar perfiles»', (tester) async {
    await _pumpProfiles(tester);
    final strings = Strings.of(tester.element(find.byType(ProfilesScreen)));
    expect(find.text(strings.pfuManageProfiles), findsOneWidget);
  });

  group('accessibility', () {
    testWidgets('rows and menus are 48 dp, named and say they open', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpProfiles(tester);
      for (final name in ['default', 'console-builder', 'oficina']) {
        expect(
          tester.getSize(_row(name)).height,
          greaterThanOrEqualTo(48),
          reason: name,
        );
        expect(tester.getSize(_more(name)).height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(_row(name)).label, isNotEmpty);
      }
      handle.dispose();
    });

    for (final locale in Strings.supportedLocales) {
      testWidgets('${locale.languageCode}: 2x text on a phone, no overflow', (
        tester,
      ) async {
        await _pumpProfiles(
          tester,
          locale: locale,
          size: const Size(360, 800),
          scale: 2,
          active: 'console-builder',
        );
        expect(tester.takeException(), isNull);
        await _openMenu(tester, 'oficina');
        expect(await _menuItem(tester, 'profile-clone'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
