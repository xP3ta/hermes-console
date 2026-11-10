// Ajustes de la app (1.4.0): what belongs to the app and the server, in the
// groups of the approved layout. Every row opens ITS screen from here; the
// ones that are a section of Settings open the screen of that section (only
// its own cards), never the whole list, which has no row (every setting is on
// the screen of its part).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/about_screen.dart';
import 'package:hermes_android/core/screens/activity_screen.dart';
import 'package:hermes_android/core/screens/app_settings_screen.dart';
import 'package:hermes_android/core/screens/companion/mascotas_screen.dart';
import 'package:hermes_android/core/screens/gateway_manager_screen.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/screens/notification_settings_screen.dart';
import 'package:hermes_android/core/screens/nous_account_screen.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/screens/voice_settings_screen.dart';
import 'package:hermes_android/core/screens/ssh_screen.dart';
import 'package:hermes_android/core/screens/look_feel_screen.dart';
import 'package:hermes_android/core/screens/tools_hub_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ssh_profile_presence.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/settings/settings_deep_link.dart';
import 'package:hermes_android/core/settings/settings_sections.dart';
import 'package:hermes_android/core/widgets/owned_resource_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/nav_harness.dart';

Future<ConnectionManager> _pump(
  WidgetTester tester, {
  SavedConnection? connection,
  Locale locale = const Locale('es'),
  Size size = const Size(390, 2400),
  double scale = 1,
}) async {
  navView(tester, size: size, scale: scale);
  final manager = await navManager();
  await tester.pumpWidget(
    navApp(
      AppSettingsScreen(connection: connection, connManager: manager),
      locale: locale,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return manager;
}

List<HermesToolDestination> _rows(WidgetTester tester) =>
    tester.widget<ToolsHubScreen>(find.byType(ToolsHubScreen)).destinations;

Widget _built(WidgetTester tester, String id) => _rows(tester)
    .singleWhere((d) => d.id == id)
    .builder(tester.element(find.byType(ToolsHubScreen)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SshProfilePresence.instance.value = false);
  tearDown(() {
    SshProfilePresence.instance.value = false;
    SettingsDeepLink.pending.value = null;
  });

  testWidgets('the groups of the approved layout, in order', (tester) async {
    await _pump(tester, connection: navConnection());
    final strings = Strings.of(tester.element(find.byType(ToolsHubScreen)));
    final labels = [
      strings.navGroupConnection,
      strings.navGroupSecurityData,
      strings.navGroupLook,
      strings.navGroupAlerts,
      strings.navGroupServer,
      strings.navGroupHelp,
    ];
    final tops = [
      for (final label in labels) tester.getTopLeft(find.text(label).first).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()), reason: '$labels');
    expect(
      tester.widget<ToolsHubScreen>(find.byType(ToolsHubScreen)).title,
      strings.setTitle,
    );
  });

  group('the table: every row opens its screen', () {
    // id -> the screen it builds (built, not mounted: they need a server).
    bool section(Widget w, SettingsSection of) =>
        w is SettingsSectionScreen && w.section == of;
    final screens = <String, bool Function(Widget)>{
      'instances': (w) => w is GatewayManagerScreen,
      'ssh': (w) => w is SshScreen,
      'security': (w) => section(w, SettingsSection.security),
      // Without the app's cache store the row opens the Data screen.
      'cache': (w) => section(w, SettingsSection.data),
      'data': (w) => section(w, SettingsSection.data),
      'appearance': (w) => w is LookFeelScreen,
      'mascotas': (w) => w is MascotasScreen,
      'chat': (w) => section(w, SettingsSection.chat),
      'appearance-more': (w) => section(w, SettingsSection.appearance),
      'notifications': (w) => w is NotificationSettingsScreen,
      'voice-app': (w) => w is VoiceSettingsScreen,
      'models': (w) => w is ModelsScreen,
      'nous-account': (w) => w is NousAccountScreen,
      'profiles': (w) => w is ProfilesScreen,
      'extensions': (w) => w is OwnedResourceHost<TuiGatewayClient>,
      'logs': (w) => w is ActivityScreen,
      'maintenance': (w) => section(w, SettingsSection.system),
      'about': (w) => w is AboutScreen,
    };

    for (final MapEntry(key: id, value: isScreen) in screens.entries) {
      testWidgets(id, (tester) async {
        await _pump(tester, connection: navConnection());
        final row = _rows(tester).singleWhere((d) => d.id == id);
        expect(row.enabled, isTrue, reason: id);
        expect(isScreen(_built(tester, id)), isTrue, reason: id);
        expect(find.byKey(ValueKey('tool-$id')), findsOneWidget, reason: id);
      });
    }

    testWidgets('the table has no row left out and none that is not here', (
      tester,
    ) async {
      await _pump(tester, connection: navConnection());
      expect(
        _rows(tester).map((d) => d.id).toList(),
        screens.keys.toList(),
        reason: 'the order of the rows is the order of the layout',
      );
    });

    // No row asks the whole list to scroll to it any more: each opens its
    // own screen, and the list is only the last row.
    for (final id in const [
      'security',
      'cache',
      'data',
      'chat',
      'appearance-more',
      'maintenance',
    ]) {
      testWidgets('$id does not ask for the whole list', (tester) async {
        await _pump(tester, connection: navConnection());
        final row = _rows(tester).singleWhere((d) => d.id == id);
        expect(row.beforeOpen, isNull, reason: id);
        expect(SettingsDeepLink.pending.value, isNull);
      });
    }

    testWidgets('there is no «Todos los ajustes» row, no «Lista completa» '
        'label, and Profiles is «Gestionar perfiles»', (tester) async {
      await _pump(tester, connection: navConnection());
      final strings = Strings.of(tester.element(find.byType(ToolsHubScreen)));
      final rows = _rows(tester);
      expect(rows.map((d) => d.id), isNot(contains('all-settings')));
      expect(rows.last.id, 'about');
      expect(find.byKey(const ValueKey('tool-all-settings')), findsNothing);
      expect(
        rows.singleWhere((d) => d.id == 'profiles').label,
        strings.pfuManageProfiles,
      );
      expect(strings.pfuManageProfiles, 'Gestionar perfiles');
    });
  });

  testWidgets('a tap on Seguridad opens its own screen with only its cards', (
    tester,
  ) async {
    await _pump(
      tester,
      connection: navConnection(),
      size: const Size(411, 915),
    );
    await tester.tap(find.byKey(const ValueKey('tool-security')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsSectionScreen), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
    final strings = Strings.of(
      tester.element(find.byType(SettingsSectionScreen)),
    );
    expect(find.text(strings.ssxTitleSecurity), findsWidgets);
    expect(
      find.byKey(const ValueKey('settings-security-info')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-reactions')), findsNothing);
    expect(find.byKey(const ValueKey('settings-backup')), findsNothing);
    expect(SettingsDeepLink.pending.value, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without an instance only what needs none works, and the rest '
      'says why', (tester) async {
    await _pump(tester);
    final strings = Strings.of(tester.element(find.byType(ToolsHubScreen)));
    for (final row in _rows(tester)) {
      final needsNone = const {
        'instances',
        'notifications',
        'about',
      }.contains(row.id);
      expect(row.enabled, needsNone, reason: row.id);
      if (!needsNone) {
        expect(row.disabledReason, strings.drawerNeedInstance, reason: row.id);
      }
    }
  });

  testWidgets('a server without logs or models disables those rows', (
    tester,
  ) async {
    final manager = await navManager();
    await manager.saveCapabilities(
      'nav-test',
      const CapabilityMatrix(modelsRead: CapState.no, logsRead: CapState.no),
    );
    navView(tester, size: const Size(390, 2400));
    await tester.pumpWidget(
      navApp(
        AppSettingsScreen(connection: navConnection(), connManager: manager),
      ),
    );
    await tester.pump();
    final strings = Strings.of(tester.element(find.byType(ToolsHubScreen)));
    for (final id in ['models', 'logs']) {
      final row = _rows(tester).singleWhere((d) => d.id == id);
      expect(row.enabled, isFalse, reason: id);
      expect(row.disabledReason, strings.drawerUnsupported, reason: id);
    }
  });

  testWidgets('the SSH row says how to start until there is an SSH profile; '
      'Agentes then shows in the dock', (tester) async {
    await _pump(tester, connection: navConnection());
    final strings = Strings.of(tester.element(find.byType(ToolsHubScreen)));
    expect(find.text(strings.navSshStartHint), findsOneWidget);
    SshProfilePresence.instance.value = true;
    await tester.pump();
    expect(find.text(strings.navSshStartHint), findsNothing);
  });

  group('accessibility', () {
    testWidgets('rows are at least 48 dp tall and named for TalkBack', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, connection: navConnection());
      for (final row in _rows(tester)) {
        final finder = find.byKey(ValueKey('tool-${row.id}'));
        expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
        final node = tester.getSemantics(
          find.byKey(ValueKey('tool-semantics-${row.id}')),
        );
        expect(node.label, isNotEmpty, reason: row.id);
      }
      handle.dispose();
    });

    for (final locale in Strings.supportedLocales) {
      testWidgets('${locale.languageCode}: 2x text, phone width, no '
          'overflow', (tester) async {
        await _pump(
          tester,
          connection: navConnection(),
          locale: locale,
          scale: 2,
          size: const Size(360, 800),
        );
        expect(tester.takeException(), isNull);
        await tester.drag(
          find.byKey(const ValueKey('tools-hub-list')),
          const Offset(0, -6000),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
