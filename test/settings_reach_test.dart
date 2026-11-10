// «Todos los ajustes» is gone as a row: SettingsScreen stays as the engine of
// the deep links, so every part of it must still be reachable from Ajustes de
// la app, two taps at most (the row, then the screen of that part).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/about_screen.dart';
import 'package:hermes_android/core/screens/app_settings_screen.dart';
import 'package:hermes_android/core/screens/gateway_manager_screen.dart';
import 'package:hermes_android/core/screens/notification_settings_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/screens/tools_hub_screen.dart';
import 'package:hermes_android/core/screens/voice_settings_screen.dart';
import 'package:hermes_android/core/services/ssh_profile_presence.dart';
import 'package:hermes_android/core/settings/settings_sections.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/nav_harness.dart';

/// The row of Ajustes that leads to each part of the full list.
const _rowOf = <SettingsSection, String>{
  SettingsSection.connection: 'instances',
  SettingsSection.appearance: 'appearance-more',
  SettingsSection.chat: 'chat',
  SettingsSection.voice: 'voice-app',
  SettingsSection.notifications: 'notifications',
  SettingsSection.security: 'security',
  SettingsSection.system: 'maintenance',
  SettingsSection.data: 'data',
  SettingsSection.about: 'about',
};

/// A key each part's screen must show, proof that its cards came along.
const _proof = <SettingsSection, String>{
  SettingsSection.appearance: 'settings-dock',
  SettingsSection.chat: 'settings-reactions',
  SettingsSection.security: 'settings-vault',
  SettingsSection.system: 'maint-nav-test',
  SettingsSection.data: 'history-cleanup-normal',
};

Future<void> _pump(
  WidgetTester tester, {
  Locale locale = const Locale('es'),
  Size size = const Size(390, 3000),
  double scale = 1,
}) async {
  navView(tester, size: size, scale: scale);
  final manager = await navManager();
  await tester.pumpWidget(
    navApp(
      AppSettingsScreen(connection: navConnection(), connManager: manager),
      locale: locale,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SshProfilePresence.instance.value = false);

  test('every part of the full list has a row in Ajustes', () {
    expect(_rowOf.keys.toSet(), SettingsSection.values.toSet());
  });

  testWidgets('those rows exist, enabled, and none is the whole list', (
    tester,
  ) async {
    await _pump(tester);
    final ids = tester
        .widget<ToolsHubScreen>(find.byType(ToolsHubScreen))
        .destinations
        .map((d) => d.id)
        .toList();
    for (final entry in _rowOf.entries) {
      expect(ids, contains(entry.value), reason: entry.key.name);
    }
    expect(ids, isNot(contains('all-settings')));
    final strings = Strings.of(tester.element(find.byType(ToolsHubScreen)));
    expect(find.text('Todos los ajustes'), findsNothing);
    expect(find.text(strings.setTitle), findsWidgets);
  });

  for (final entry in _proof.entries) {
    testWidgets('${entry.key.name}: one tap on its row shows its cards', (
      tester,
    ) async {
      await _pump(tester, size: const Size(390, 6000));
      await tester.tap(find.byKey(ValueKey('tool-${_rowOf[entry.key]}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final screen = tester.widget<SettingsSectionScreen>(
        find.byType(SettingsSectionScreen),
      );
      expect(screen.section, entry.key);
      expect(find.byKey(ValueKey(entry.value)), findsOneWidget);
    });
  }

  testWidgets('Voz, which only the full list had, opens from its own row', (
    tester,
  ) async {
    await _pump(tester);
    final row = tester
        .widget<ToolsHubScreen>(find.byType(ToolsHubScreen))
        .destinations
        .singleWhere((d) => d.id == 'voice-app');
    expect(row.enabled, isTrue);
    final screen = row.builder(tester.element(find.byType(ToolsHubScreen)));
    expect(screen, isA<VoiceSettingsScreen>());
  });

  testWidgets('Instancias, Notificaciones and Acerca de open their pages', (
    tester,
  ) async {
    await _pump(tester);
    final rows = tester
        .widget<ToolsHubScreen>(find.byType(ToolsHubScreen))
        .destinations;
    final context = tester.element(find.byType(ToolsHubScreen));
    expect(
      rows.singleWhere((d) => d.id == 'instances').builder(context),
      isA<GatewayManagerScreen>(),
    );
    expect(
      rows.singleWhere((d) => d.id == 'notifications').builder(context),
      isA<NotificationSettingsScreen>(),
    );
    expect(
      rows.singleWhere((d) => d.id == 'about').builder(context),
      isA<AboutScreen>(),
    );
  });

  testWidgets('the update channel, which only the full list had, is in '
      'Acerca de', (tester) async {
    navView(tester, size: const Size(390, 3000));
    await tester.pumpWidget(navApp(const AboutScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('install-source-row')),
      200,
    );
    expect(find.byKey(const ValueKey('install-source-row')), findsOneWidget);
  });

  testWidgets('the full list itself is still there for the deep links', (
    tester,
  ) async {
    navView(tester, size: const Size(390, 30000));
    final manager = await navManager();
    await tester.pumpWidget(
      navApp(SettingsScreen(connection: navConnection(), connManager: manager)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('settings-all-badge')), findsNothing);
    for (final key in _proof.values) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
  });
}
