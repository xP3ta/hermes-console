// «Cambiar de perfil» in the profile hub (1.4.0, QA 9804): the pick becomes
// the app's active profile and the same page is made again for it, at once,
// with «Activo» following the real active profile («Hacer activo» when the
// page shows another one).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/profile_hub_screen.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/nav_harness.dart';
import '../support/profile_model_fakes.dart';

const _third = 'terceros';

BotRosterRegistry _registry(SavedConnection connection, {bool single = false}) {
  final registry = BotRosterRegistry();
  registry.publish(connection.id, connection.label, [
    const AgentProfile(name: 'default', isDefault: true, model: 'base-model'),
    if (!single) ...const [
      AgentProfile(
        name: navSecondary,
        description: 'Revisa pull requests y mantiene el changelog',
        model: 'gpt-5.5',
        provider: 'openai',
        skillCount: 7,
      ),
      AgentProfile(
        name: _third,
        description: 'Escribe notas de versión',
        model: 'claude-x',
        provider: 'anthropic',
      ),
    ],
  ]);
  return registry;
}

class _Rig {
  _Rig(this.manager, this.connection);

  final ConnectionManager manager;
  final SavedConnection connection;

  String get active => manager.activeProfileFor(connection.id);
}

Future<_Rig> _pump(
  WidgetTester tester, {
  String profile = 'default',
  String? active,
  bool readOnly = false,
  bool single = false,
  VoidCallback? onChat,
  VoidCallback? onOpenBotCard,
  Locale locale = const Locale('es'),
  Size size = const Size(390, 1800),
  double scale = 1,
}) async {
  navView(tester, size: size, scale: scale);
  final connection = navConnection(readOnly: readOnly);
  final manager = await navManager();
  if (active != null) {
    await tester.runAsync(
      () => manager.setActiveProfile(connection.id, active),
    );
  }
  final gateway = FakeModelGateway();
  await tester.pumpWidget(
    navApp(
      ProfileHubScreen(
        connection: connection,
        connManager: manager,
        profile: profile,
        rosterRegistry: _registry(connection, single: single),
        modelGateway: gateway,
        profileGateway: gateway,
        onChat: onChat,
        onOpenBotCard: onOpenBotCard,
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return _Rig(manager, connection);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

String _shownName(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('profile-hub-name'))).data!;

Future<void> _pick(WidgetTester tester, String profile) async {
  await tester.tap(find.byKey(const ValueKey('profile-hub-switch')));
  await _settle(tester);
  expect(find.byKey(const ValueKey('profile-switcher-sheet')), findsOneWidget);
  await tester.tap(find.byKey(ValueKey('profile-switcher-option-$profile')));
  await _settle(tester);
}

Strings _strings(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(ProfileHubScreen)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a pick in the sheet makes it the active profile and the page '
      'shows it at once, with its chip and a notice', (tester) async {
    final rig = await _pump(tester);
    expect(_shownName(tester), kMainProfileFallbackName);
    expect(find.byKey(const ValueKey('profile-hub-active')), findsOneWidget);

    await _pick(tester, navSecondary);

    // The app's active profile changed ...
    expect(rig.active, navSecondary);
    // ... and the page, still the same screen, shows that profile.
    expect(find.byType(ProfileHubScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-switcher-sheet')), findsNothing);
    expect(_shownName(tester), navSecondary);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('profile-hub-description')))
          .data,
      'Revisa pull requests y mantiene el changelog',
    );
    expect(find.textContaining('gpt-5.5'), findsWidgets);
    expect(find.byKey(const ValueKey('profile-hub-active')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-hub-make-active')), findsNothing);
    expect(
      find.text(_strings(tester).navActiveProfileNotice(navSecondary)),
      findsOneWidget,
    );

    // And back to the main profile.
    await _pick(tester, 'default');
    expect(rig.active, '');
    expect(_shownName(tester), kMainProfileFallbackName);
    expect(find.byKey(const ValueKey('profile-hub-active')), findsOneWidget);
  });

  testWidgets('a page of a profile that is not the active one offers «Hacer '
      'activo» instead of «Activo», and does the same', (tester) async {
    final rig = await _pump(tester, profile: navSecondary);
    final strings = _strings(tester);
    expect(rig.active, isEmpty);
    expect(find.byKey(const ValueKey('profile-hub-active')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('profile-hub-make-active')),
        matching: find.text(strings.psfMakeActive),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('profile-hub-make-active')));
    await _settle(tester);

    expect(rig.active, navSecondary);
    expect(_shownName(tester), navSecondary);
    expect(find.byKey(const ValueKey('profile-hub-active')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-hub-make-active')), findsNothing);
    expect(
      find.text(strings.navActiveProfileNotice(navSecondary)),
      findsOneWidget,
    );
  });

  testWidgets('from a page that is not the active one, picking the active '
      'profile moves the page to it and picking another one makes that one '
      'active', (tester) async {
    final rig = await _pump(tester, profile: navSecondary);
    await _pick(tester, 'default');
    expect(rig.active, '');
    expect(_shownName(tester), kMainProfileFallbackName);
    expect(find.byKey(const ValueKey('profile-hub-active')), findsOneWidget);

    await _pick(tester, _third);
    expect(rig.active, _third);
    expect(_shownName(tester), _third);
    expect(find.byKey(const ValueKey('profile-hub-active')), findsOneWidget);
  });

  testWidgets('the model row follows the profile the page shows', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.textContaining('base-model'), findsWidgets);
    expect(find.textContaining('gpt-5.5'), findsNothing);
    await _pick(tester, navSecondary);
    expect(find.textContaining('gpt-5.5'), findsWidgets);
    expect(find.textContaining('base-model'), findsNothing);
    await _pick(tester, _third);
    expect(find.textContaining('claude-x'), findsWidgets);
    expect(find.textContaining('gpt-5.5'), findsNothing);
  });

  testWidgets('a page that shows the active profile follows another part of '
      'the app switching it; a page about another profile stays', (
    tester,
  ) async {
    final rig = await _pump(tester);
    await tester.runAsync(
      () => rig.manager.setActiveProfile(rig.connection.id, navSecondary),
    );
    await _settle(tester);
    expect(_shownName(tester), navSecondary);
    expect(find.byKey(const ValueKey('profile-hub-active')), findsOneWidget);

    // The page now shows the active one; open another page about a profile
    // that is not active: a switch elsewhere does not move it.
    final other = await _pump(tester, profile: _third);
    await tester.runAsync(
      () => other.manager.setActiveProfile(other.connection.id, navSecondary),
    );
    await _settle(tester);
    expect(_shownName(tester), _third);
    expect(find.byKey(const ValueKey('profile-hub-active')), findsNothing);
    expect(
      find.byKey(const ValueKey('profile-hub-make-active')),
      findsOneWidget,
    );
  });

  testWidgets('the Chat pill and the bot card belong to the profile the page '
      'opened on: they leave with another one and come back', (tester) async {
    var chats = 0;
    await _pump(tester, onChat: () => chats++, onOpenBotCard: () {});
    expect(find.byKey(const ValueKey('profile-hub-chat')), findsOneWidget);
    await _pick(tester, navSecondary);
    expect(find.byKey(const ValueKey('profile-hub-chat')), findsNothing);
    await _pick(tester, 'default');
    await tester.tap(find.byKey(const ValueKey('profile-hub-chat')));
    expect(chats, 1);
  });

  testWidgets('with no other profile the sheet lists the main one and the '
      'page stays', (tester) async {
    final rig = await _pump(tester, single: true);
    await tester.tap(find.byKey(const ValueKey('profile-hub-switch')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('profile-switcher-option-default')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-switcher-option-$navSecondary')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('profile-switcher-search')), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('profile-switcher-option-default')),
    );
    await _settle(tester);
    expect(rig.active, '');
    expect(_shownName(tester), kMainProfileFallbackName);
    expect(find.byKey(const ValueKey('profile-hub-active')), findsOneWidget);
  });

  testWidgets('a read-only server can still switch the active profile, but '
      'not edit it', (tester) async {
    final rig = await _pump(tester, readOnly: true, profile: navSecondary);
    expect(
      find.byKey(const ValueKey('profile-hub-make-active')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('profile-hub-make-active')));
    await _settle(tester);
    expect(rig.active, navSecondary);
    await _pick(tester, 'default');
    expect(_shownName(tester), kMainProfileFallbackName);
    expect(rig.active, '');
    expect(
      find.byIcon(Icons.edit_outlined),
      findsNothing,
      reason: 'no edit affordance on a read-only server',
    );
  });

  testWidgets('Semantics: the pills are buttons with their label and 48 dp '
      'targets', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, profile: navSecondary);
    final strings = _strings(tester);
    final make = find.byKey(const ValueKey('profile-hub-make-active'));
    expect(
      tester.getSemantics(make),
      isSemantics(
        isButton: true,
        hasTapAction: true,
        label: strings.psfMakeActive,
      ),
    );
    final switcher = find.byKey(const ValueKey('profile-hub-switch'));
    expect(
      tester.getSemantics(switcher),
      isSemantics(
        isButton: true,
        hasTapAction: true,
        label: strings.navSwitchProfile,
      ),
    );
    for (final finder in [make, switcher]) {
      final size = tester.getSize(finder);
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
    }
    handle.dispose();
  });

  for (final locale in Strings.supportedLocales) {
    testWidgets('${locale.languageCode}: 2x text, phone width, the header '
        'with «Hacer activo» and the open sheet do not overflow', (
      tester,
    ) async {
      await _pump(
        tester,
        profile: navSecondary,
        locale: locale,
        scale: 2,
        size: const Size(360, 800),
        onChat: () {},
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('profile-hub-switch')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('profile-switcher-sheet')),
        findsOneWidget,
      );
    });
  }
}
