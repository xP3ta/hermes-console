// One dock.
//
// Until 1.2.15 Ajustes had a "Dock con gestos" switch that chose between
// the dock with gestures and the classic bar. With the gestures gone the
// choice meant nothing: the switch is removed and every screen mounts the
// same dock, whatever a device had stored.
//
// The dock stays optional ("Usar dock flotante"), and hidden or off it
// takes nothing with it: every destination is also in the drawer.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/screens/gesture_dock_settings_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_mode.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_host.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

GestureDockController get _c => GestureDockController.instance;

final _connection = SavedConnection(
  id: 'dock-single',
  label: 'Dock QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-only',
);

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('classic-dark'),
  home: home,
);

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.padding = const FakeViewPadding(bottom: 34 * 3);
  tester.view.viewPadding = const FakeViewPadding(bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

/// What a device that had turned "Dock con gestos" off has stored.
const _choseClassic = {FeatureFlags.gestureDockKey: false};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
    // The app as it starts: no test seam.
    FeatureFlags.instance.resetToDefaultForTesting();
    _c.resetForTesting(settings: const GestureDockSettings());
    DockGeometry.instance.resetForTesting();
    DockModes.instance.resetForTesting();
  });

  tearDown(() async {
    FeatureFlags.instance.resetForTesting();
    await DockPreferencesController.instance.setUseDock(true);
  });

  group('nothing stored chooses another dock', () {
    test('a device that had chosen the classic dock gets this one, and the '
        'stored choice is dropped', () async {
      SharedPreferences.setMockInitialValues(_choseClassic);
      FeatureFlags.instance.resetToDefaultForTesting();
      await FeatureFlags.instance.ensureLoaded();
      expect(FeatureFlags.instance.gestureDock.value, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(FeatureFlags.gestureDockKey), isFalse);
    });

    for (final stored in <Map<String, Object>>[
      const {},
      _choseClassic,
      const {FeatureFlags.gestureDockKey: true},
    ]) {
      testWidgets('stored $stored: Home, a shell screen and the Bots profile '
          'all mount the dock', (tester) async {
        _phone(tester);
        SharedPreferences.setMockInitialValues(stored);
        FeatureFlags.instance.resetToDefaultForTesting();
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        for (final screen in [
          // As Home mounts it.
          Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                Dock(
                  profileId: DockProfileId.general,
                  actions: {
                    DockItemId.home: const DockItemAction(selected: true),
                  },
                ),
              ],
            ),
          ),
          // As every other General screen does.
          Scaffold(
            body: GeneralDockShell(
              connection: _connection,
              connManager: manager,
              body: const SizedBox.expand(),
            ),
          ),
          // As Mission Control does.
          Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                Dock(
                  profileId: DockProfileId.bots,
                  actions: {
                    DockItemId.bots: DockItemAction(
                      onTap: () {},
                      selected: true,
                    ),
                    DockItemId.create: const DockItemAction(),
                  },
                ),
              ],
            ),
          ),
        ]) {
          await tester.pumpWidget(_app(screen));
          // The stored flags and the dock's settings are read.
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(find.byType(GestureDockHost), findsOneWidget);
          expect(find.byType(GestureDock), findsOneWidget);
          expect(
            find.byWidgetPredicate((w) {
              final key = w.key;
              return key is ValueKey<String> &&
                  (key.value.endsWith('-floating-dock') ||
                      key.value.endsWith('-dock-rail') &&
                          key.value != 'gesture-dock-rail');
            }),
            findsNothing,
            reason: 'no classic bar',
          );
          await tester.pumpWidget(const SizedBox());
        }
      });
    }
  });

  group('Ajustes', () {
    testWidgets('"Usar dock flotante" and "Dock"; no switch between docks; '
        'Dock opens the dock\'s own settings', (tester) async {
      _phone(tester);
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(
        _app(SettingsScreen(connection: _connection, connManager: manager)),
      );
      await tester.pump();
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-dock')),
        200,
        scrollable: list,
      );
      expect(find.byKey(const ValueKey('settings-use-dock')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-gesture-dock-flag')),
        findsNothing,
      );
      expect(find.text('Dock con gestos'), findsNothing);

      await tester.ensureVisible(find.byKey(const ValueKey('settings-dock')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('settings-dock')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(GestureDockSettingsScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Ajustes › Dock: solid surface, hide and edit; nothing about '
        'gestures, auto-hide, tricks or tours', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const GestureDockSettingsScreen()));
      await tester.pump();
      final strings = Strings.of(
        tester.element(find.byType(GestureDockSettingsScreen)),
      );
      expect(
        [
          for (final element
              in find
                  .byWidgetPredicate(
                    (w) =>
                        w.key is ValueKey<String> &&
                        (w.key! as ValueKey<String>).value.startsWith(
                          'gesture-dock-',
                        ),
                  )
                  .evaluate())
            (element.widget.key! as ValueKey<String>).value,
        ],
        ['gesture-dock-opaque', 'gesture-dock-hidden', 'gesture-dock-edit'],
      );
      expect(find.text(strings.gdOpaqueTitle), findsOneWidget);
      expect(find.text(strings.gdHideDock), findsOneWidget);
      expect(find.text(strings.gdEditDock), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(2));
      for (final gone in [
        'Gestos en el dock',
        'Ocultar automáticamente',
        'Trucos y gestos',
        'Avisos con trucos',
      ]) {
        expect(find.text(gone), findsNothing, reason: gone);
      }

      // Editing the items is here too.
      await tester.tap(find.byKey(const ValueKey('gesture-dock-edit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dock-edit-sheet')), findsOneWidget);
      final sheet = find.byKey(const ValueKey('dock-edit-sheet'));
      final onDock = _c.value.tabs;
      for (final tab in GestureDockTab.values) {
        final row = find.byKey(
          ValueKey(
            onDock.contains(tab)
                ? 'dock-edit-selected-${tab.name}'
                : 'dock-edit-available-${tab.name}',
          ),
        );
        await tester.scrollUntilVisible(
          row,
          80,
          scrollable: find
              .descendant(of: sheet, matching: find.byType(Scrollable))
              .first,
        );
        expect(row, findsOneWidget, reason: 'the editor offers ${tab.name}');
      }
    });

    testWidgets('"Esconder el dock" hides it now, shows it again, and is '
        'never stored', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const GestureDockSettingsScreen()));
      await tester.pump();
      final toggle = find.byKey(const ValueKey('gesture-dock-hidden'));
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pump();
      expect(_c.hidden.value, isTrue);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      // The handle shows it again and the switch follows.
      _c.setHidden(false);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pump();
      await _c.setOpaque(true);
      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString(GestureDockController.storageKey)!)
              as Map<String, dynamic>;
      expect(stored.keys, isNot(contains('hidden')));
      _c.setHidden(false);
    });
  });

  // The dock's "+" is a new chat. A screen with something of its own to
  // create keeps its own button, with the dock on, off or hidden: under the
  // classic bar Cron and Tareas hid it (that bar's "+" created in place),
  // which left no way to add a job or a task to a list that already had one.
  group('screens keep their own New button', () {
    DashboardClient cronClient() => DashboardClient(
      host: 'hermes.local',
      manualToken: 'token',
      httpClientOverride: MockClient((request) async {
        if (request.url.path == '/api/cron/jobs') {
          return http.Response('[]', 200);
        }
        if (request.url.path == '/api/cron/delivery-targets') {
          return http.Response(jsonEncode({'targets': <Object>[]}), 200);
        }
        if (request.url.path == '/api/model/options') {
          return http.Response(jsonEncode({'providers': <Object>[]}), 200);
        }
        if (request.url.path == '/api/cron/blueprints') {
          return http.Response(jsonEncode({'blueprints': <Object>[]}), 200);
        }
        return http.Response('{}', 404);
      }),
    );

    Future<void> pumpCron(WidgetTester tester) async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(
        _app(
          CronScreen(
            connection: _connection,
            connManager: manager,
            clientOverride: cronClient(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final create = find.byKey(const ValueKey('cron-create'));

    void expectInTopBar(WidgetTester tester) {
      expect(create, findsOneWidget);
      expect(
        find.ancestor(of: create, matching: find.byType(AppBar)),
        findsOneWidget,
        reason: 'the create action is a piece of the top bar',
      );
      expect(find.byType(FloatingActionButton), findsNothing);
    }

    testWidgets('Cron, dock on: its "+" is in the top bar, not over the list, '
        'and opens the editor', (tester) async {
      _phone(tester);
      await pumpCron(tester);
      final bar = find.byKey(const ValueKey('gesture-dock-pointer'));
      expect(bar, findsOneWidget);
      expectInTopBar(tester);
      expect(
        tester.getRect(create).bottom,
        lessThan(tester.getRect(bar).top - 400),
        reason: 'at the top of the screen, nowhere near the dock',
      );
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cron-prompt-field')), findsOneWidget);
    });

    testWidgets('Cron, dock hidden by hand: the "+" stays where it was', (
      tester,
    ) async {
      _phone(tester);
      await pumpCron(tester);
      final shown = tester.getRect(create);
      _c.setHidden(true);
      await tester.pumpAndSettle();
      expectInTopBar(tester);
      expect(tester.getRect(create), shown);
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cron-prompt-field')), findsOneWidget);
      _c.setHidden(false);
      await tester.pumpAndSettle();
    });

    testWidgets('Cron, dock off: the "+" is still in the top bar', (
      tester,
    ) async {
      _phone(tester);
      await DockPreferencesController.instance.setUseDock(false);
      await pumpCron(tester);
      expect(find.byType(GestureDock), findsNothing);
      expectInTopBar(tester);
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cron-prompt-field')), findsOneWidget);
    });

    test('Cron, Tareas, Ejecuciones, SFTP and Perfiles create from the top '
        'bar: no button over the list, and nothing that depends on the '
        'dock', () {
      for (final (path, key) in const [
        ('lib/core/screens/cron_screen.dart', 'cron-create'),
        ('lib/core/screens/tasks_screen.dart', 'kanban-create'),
        ('lib/core/screens/task_center_screen.dart', 'runs-create'),
        ('lib/core/screens/sftp_browser_screen.dart', 'sftp-upload'),
        ('lib/core/screens/profiles_screen.dart', 'profiles-new'),
      ]) {
        final source = File(path).readAsStringSync();
        expect(source, contains("ValueKey('$key')"), reason: path);
        expect(source, isNot(contains('floatingActionButton')), reason: path);
        expect(source, isNot(contains('dockActive')), reason: path);
        expect(source, isNot(contains('.useDock')), reason: path);
      }
    });
  });

  // Owner's hard requirement: with the dock off (or hidden) the app loses
  // nothing.
  group('without the dock nothing is lost', () {
    Future<void> openDrawer(WidgetTester tester) async {
      _phone(tester);
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final scaffold = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        _app(
          Scaffold(
            key: scaffold,
            drawer: HermesDrawer(
              connection: _connection,
              connManager: manager,
              current: DrawerSection.home,
              recentSessionsClientFactory: (saved) => ApiClient(
                baseUrl: saved.baseUrl,
                apiKey: saved.apiKey,
                httpClient: MockClient(
                  (request) async => http.Response(
                    jsonEncode({'object': 'list', 'data': <Object>[]}),
                    200,
                  ),
                ),
              ),
            ),
            body: Stack(
              fit: StackFit.expand,
              children: [
                Dock(
                  profileId: DockProfileId.general,
                  actions: {
                    DockItemId.home: const DockItemAction(selected: true),
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      scaffold.currentState!.openDrawer();
      await tester.pumpAndSettle();
    }

    for (final (name, arrange) in <(String, Future<void> Function())>[
      (
        '"Usar dock flotante" off',
        () => DockPreferencesController.instance.setUseDock(false),
      ),
      ('the dock hidden by hand', () async => _c.setHidden(true)),
    ]) {
      testWidgets('$name: every dock destination is in the drawer, ready to '
          'tap', (tester) async {
        await arrange();
        await openDrawer(tester);
        final strings = Strings.of(tester.element(find.byType(HermesDrawer)));
        if (name.startsWith('"Usar')) {
          expect(find.byType(GestureDock), findsNothing);
        }
        // Dock item -> the drawer row that opens the same place.
        final rows = <GestureDockTab, String>{
          GestureDockTab.home: strings.drawerHome,
          GestureDockTab.create: strings.drawerNewChat,
          GestureDockTab.search: strings.drawerSessions,
          GestureDockTab.projects: strings.drawerProjects,
          GestureDockTab.tasks: strings.drawerKanban,
          GestureDockTab.cron: strings.drawerCron,
          GestureDockTab.bots: 'Bots',
          GestureDockTab.tools: strings.drawerTools,
          GestureDockTab.settings: strings.drawerSettings,
        };
        // Actividad is Home's own «De un vistazo»; it has no screen.
        expect(
          rows.keys.toSet(),
          GestureDockTab.values.toSet()..remove(GestureDockTab.activity),
        );
        for (final MapEntry(key: tab, value: label) in rows.entries) {
          final row = find.descendant(
            of: find.byType(HermesDrawer),
            matching: find.text(label),
          );
          await tester.scrollUntilVisible(
            row.first,
            120,
            scrollable: find
                .descendant(
                  of: find.byKey(const ValueKey('drawer-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(row, findsWidgets, reason: tab.name);
          // A row of the drawer: a button that is enabled, with its tap.
          final button = find.ancestor(
            of: row.first,
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.button == true,
            ),
          );
          expect(
            tester.widget<Semantics>(button.first).properties.enabled,
            isTrue,
            reason: '${tab.name}: $label',
          );
          expect(
            find.ancestor(
              of: row.first,
              matching: find.byWidgetPredicate(
                (w) => w is InkWell && w.onTap != null,
              ),
            ),
            findsWidgets,
            reason: '${tab.name}: $label',
          );
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  });
}
