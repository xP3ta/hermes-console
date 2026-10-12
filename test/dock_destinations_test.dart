// Every dock item goes where it says, from every screen, in both modes.
//
// Owner (2026-10-11): "Corregiría dónde va cada cosa, porque por ejemplo si
// estoy en modo bot y le doy a Inicio no me lleva a Inicio."
//
// | Item          | From General                 | From Bots                  |
// |---------------|------------------------------|----------------------------|
// | Inicio        | General Home                 | General Home               |
// | Bots          | Bots home                    | Bots home                  |
// | Chats         | conversation list / General  | conversation list / Bots   |
// | Proyectos     | Proyectos / General          | Proyectos / Bots           |
// | Ajustes       | Ajustes / General            | Ajustes / Bots             |
// | Herramientas  | Herramientas / General       | Herramientas / Bots        |
// | Cron, Tareas  | their screen / General       | their screen / Bots        |
// | Nuevo         | a new chat                   | a new chat                 |
// | Actividad     | its sheet                    | its sheet                  |
//
// "From General" is the General Home and any screen opened above it; "from
// Bots" is the Bots home (the real Mission Control here) and any screen
// opened above it. "X / General" means: X is on top and under it there is
// only the General Home; "X / Bots": under it, the Bots home and the
// General Home. Places never pile up.
//
// A previous fix in this area covered one mode and broke the other, so
// each item is checked from six starting points, and the last group pins
// the list of screens that mount a dock.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/gesture_dock_settings_screen.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/screens/tasks_screen.dart';
import 'package:hermes_android/core/screens/tools_hub_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/shell/dock_activity_sheet.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_mode.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_host.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/core/widgets/owned_resource_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'dock-destinations',
  label: 'Dock QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

class _Source implements MissionControlDataSource {
  @override
  Future<MissionBackendSnapshot> load() async => MissionBackendSnapshot(
    loadedAt: DateTime.fromMillisecondsSinceEpoch(0),
    profilesCapability: MissionCapabilityState.available,
  );

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;

  @override
  void close() {}
}

/// The routes on the navigator, bottom first.
class _Routes extends NavigatorObserver {
  final List<Route<dynamic>> stack = [];

  /// Screens only: a sheet or a menu is not one.
  int get screens => stack.whereType<MaterialPageRoute<dynamic>>().length;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      stack.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      stack.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      stack.remove(route);
}

const _places = [
  GestureDockTab.projects,
  GestureDockTab.settings,
  GestureDockTab.search,
  GestureDockTab.cron,
  GestureDockTab.tasks,
  GestureDockTab.tools,
];

late ConnectionManager _manager;
late List<String> _log;

/// The Bots home: the real Mission Control.
Widget _botsHome() => MissionControlScreen(
  connection: _connection,
  connManager: _manager,
  dataSource: _Source(),
);

/// The screen of a place: the real `GeneralDockShell`, called the way that
/// place's screen calls it ([tab] null: a screen that is no dock item, as
/// Perfiles, Instancias or Voz).
Widget _shellScreen(GestureDockTab? tab) => Scaffold(
  body: GeneralDockShell(
    connection: _connection,
    connManager: _manager,
    includeSettingsAction: tab != GestureDockTab.settings,
    includeSessionsAction: tab != GestureDockTab.search,
    currentDestination: switch (tab) {
      GestureDockTab.cron => DockItemId.cron,
      GestureDockTab.tasks => DockItemId.tasks,
      GestureDockTab.tools => DockItemId.tools,
      _ => null,
    },
    gestureTab: tab == GestureDockTab.projects ? GestureDockTab.projects : null,
    body: Center(
      child: Text(
        tab?.name ?? 'other',
        key: ValueKey('place-${tab?.name ?? 'other'}'),
      ),
    ),
  ),
);

Widget _place(BuildContext context, GestureDockTab tab) =>
    tab == GestureDockTab.bots ? _botsHome() : _shellScreen(tab);

/// The General Home: the first route, with the action map Home gives its
/// dock (Inicio is where you are; every other entry opens its screen
/// above Home).
class _GeneralHome extends StatelessWidget {
  const _GeneralHome();

  @override
  Widget build(BuildContext context) {
    void open(GestureDockTab tab) => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (context) => _place(context, tab)));
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const Center(child: Text('home', key: ValueKey('general-home'))),
          Dock(
            profileId: DockProfileId.general,
            actions: {
              DockItemId.home: const DockItemAction(selected: true),
              DockItemId.create: DockItemAction(
                onTap: () => _log.add('new-chat'),
              ),
              DockItemId.bots: DockItemAction(
                onTap: () => open(GestureDockTab.bots),
              ),
              DockItemId.settings: DockItemAction(
                onTap: () => open(GestureDockTab.settings),
              ),
              DockItemId.cron: DockItemAction(
                onTap: () => open(GestureDockTab.cron),
              ),
              DockItemId.tasks: DockItemAction(
                onTap: () => open(GestureDockTab.tasks),
              ),
              DockItemId.sessions: DockItemAction(
                onTap: () => open(GestureDockTab.search),
              ),
              DockItemId.tools: DockItemAction(
                onTap: () => open(GestureDockTab.tools),
              ),
            },
          ),
        ],
      ),
    );
  }
}

/// Where a test starts from.
enum _From {
  generalHome(DockMode.general),
  generalSettings(DockMode.general),
  generalOther(DockMode.general),
  botsHome(DockMode.bots),
  botsSettings(DockMode.bots),
  botsOther(DockMode.bots);

  const _From(this.mode);
  final DockMode mode;

  /// The dock item the starting screen is, if any.
  GestureDockTab? get current => switch (this) {
    _From.generalHome => GestureDockTab.home,
    _From.botsHome => GestureDockTab.bots,
    _From.generalSettings || _From.botsSettings => GestureDockTab.settings,
    _From.generalOther || _From.botsOther => null,
  };

  /// Screens on the navigator at the start.
  int get depth => switch (this) {
    _From.generalHome => 1,
    _From.generalSettings || _From.generalOther || _From.botsHome => 2,
    _From.botsSettings || _From.botsOther => 3,
  };
}

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.padding = const FakeViewPadding(bottom: 34 * 3);
  tester.view.viewPadding = const FakeViewPadding(bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

void _layout(List<GestureDockTab> tabs) => GestureDockController.instance
    .resetForTesting(settings: GestureDockSettings(tabs: tabs));

/// The item [tab] of the dock in view.
Finder _item(GestureDockTab tab) =>
    find.byKey(ValueKey('gesture-dock-tab-${tab.name}')).hitTestable();

bool _selected(WidgetTester tester, GestureDockTab tab) =>
    tester.widget<Semantics>(_item(tab)).properties.selected ?? false;

Finder _onTop(String key) => find.byKey(ValueKey(key)).hitTestable();

Future<_Routes> _start(WidgetTester tester, _From from) async {
  _phone(tester);
  final routes = _Routes();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('classic-dark'),
      navigatorObservers: [routes],
      home: const _GeneralHome(),
    ),
  );
  await tester.pumpAndSettle();
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  void push(Widget screen) =>
      navigator.push(MaterialPageRoute<void>(builder: (_) => screen));
  if (from.mode == DockMode.bots) {
    push(_botsHome());
    await tester.pumpAndSettle();
  }
  switch (from) {
    case _From.generalSettings || _From.botsSettings:
      push(_shellScreen(GestureDockTab.settings));
    case _From.generalOther || _From.botsOther:
      push(_shellScreen(null));
    case _From.generalHome || _From.botsHome:
      break;
  }
  await tester.pumpAndSettle();
  expect(routes.screens, from.depth, reason: 'precondition');
  expect(DockModes.instance.mode, from.mode, reason: 'precondition');
  return routes;
}

Future<void> _hold(WidgetTester tester, GestureDockTab tab) async {
  final gesture = await tester.startGesture(tester.getCenter(_item(tab)));
  await tester.pump(const Duration(milliseconds: 500));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 250));
}

Finder _shortcut(String label) =>
    find.byKey(ValueKey('gesture-dock-shortcut-$label'));

List<String> _menu(WidgetTester tester) => [
  for (final element
      in find
          .descendant(
            of: find.byKey(const ValueKey('gesture-dock-popover')),
            matching: find.byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith(
                    'gesture-dock-shortcut-',
                  ),
            ),
          )
          .evaluate())
    (element.widget.key! as ValueKey<String>).value.substring(
      'gesture-dock-shortcut-'.length,
    ),
];

Strings _strings(WidgetTester tester) =>
    Strings.of(tester.element(_item(GestureDockTab.home)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.instance.resetForTesting(gestureDock: true);
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(),
    );
    DockGeometry.instance.resetForTesting();
    DockModes.instance.resetForTesting();
    _manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    _log = [];
    GestureDockHost.debugPlace = _place;
    GestureDockHost.debugNewChat = () => _log.add('new-chat');
    GestureDockHost.debugFeed = DockActivityFeed();
    GestureDockHost.debugActivity = null;
  });

  tearDown(() async {
    FeatureFlags.instance.resetForTesting();
    GestureDockHost.debugPlace = null;
    GestureDockHost.debugNewChat = null;
    GestureDockHost.debugFeed = null;
    await DockPreferencesController.instance.setUseDock(true);
  });

  for (final from in _From.values) {
    group('from ${from.name}', () {
      testWidgets('Inicio opens the General Home', (tester) async {
        _layout([GestureDockTab.home, GestureDockTab.create]);
        final routes = await _start(tester, from);
        await tester.tap(_item(GestureDockTab.home), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(_onTop('general-home'), findsOneWidget);
        expect(routes.screens, 1, reason: 'nothing above the General Home');
        expect(DockModes.instance.mode, DockMode.general);
        expect(find.byKey(const ValueKey('mission-title')), findsNothing);
        expect(_selected(tester, GestureDockTab.home), isTrue);
      });

      testWidgets('Bots opens the Bots home', (tester) async {
        _layout([GestureDockTab.home, GestureDockTab.bots]);
        final routes = await _start(tester, from);
        await tester.tap(_item(GestureDockTab.bots), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(_onTop('mission-title'), findsOneWidget);
        expect(routes.screens, 2, reason: 'the Bots home above the Home');
        expect(DockModes.instance.mode, DockMode.bots);
        expect(_selected(tester, GestureDockTab.bots), isTrue);
        expect(_selected(tester, GestureDockTab.home), isFalse);
      });

      for (final place in _places) {
        testWidgets('${place.name} opens its screen, above the home of '
            'this mode', (tester) async {
          _layout([GestureDockTab.home, place]);
          final routes = await _start(tester, from);
          await tester.tap(_item(place), warnIfMissed: false);
          await tester.pumpAndSettle();
          expect(_onTop('place-${place.name}'), findsOneWidget);
          expect(
            routes.screens,
            from.mode == DockMode.bots ? 3 : 2,
            reason: 'one screen above the home: places do not pile up',
          );
          expect(DockModes.instance.mode, from.mode, reason: 'same mode');
          expect(_selected(tester, place), isTrue);
          expect(_selected(tester, GestureDockTab.home), isFalse);
          // And from there, a second tap on it stays put.
          await tester.tap(_item(place), warnIfMissed: false);
          await tester.pumpAndSettle();
          expect(routes.screens, from.mode == DockMode.bots ? 3 : 2);
        });
      }

      testWidgets('Nuevo creates a chat and moves nowhere', (tester) async {
        _layout([GestureDockTab.home, GestureDockTab.create]);
        final routes = await _start(tester, from);
        await tester.tap(_item(GestureDockTab.create));
        await tester.pumpAndSettle();
        expect(_log, ['new-chat']);
        expect(routes.screens, from.depth);
        expect(DockModes.instance.mode, from.mode);
        expect(_selected(tester, GestureDockTab.create), isFalse);
      });

      testWidgets('Actividad opens its sheet over the same screen', (
        tester,
      ) async {
        _layout([GestureDockTab.home, GestureDockTab.activity]);
        final routes = await _start(tester, from);
        await tester.tap(_item(GestureDockTab.activity));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('dock-activity-sheet')),
          findsOneWidget,
        );
        expect(routes.screens, from.depth);
        expect(DockModes.instance.mode, from.mode);
      });

      testWidgets('the item of the screen you are on is the selected one, '
          'and only that one', (tester) async {
        _layout([
          GestureDockTab.home,
          GestureDockTab.create,
          GestureDockTab.search,
          GestureDockTab.bots,
          GestureDockTab.settings,
        ]);
        await _start(tester, from);
        for (final tab in GestureDockController.instance.value.tabs) {
          expect(_selected(tester, tab), tab == from.current, reason: tab.name);
        }
      });
    });
  }

  group('long press', () {
    for (final from in [_From.generalHome, _From.botsHome, _From.botsOther]) {
      testWidgets('from ${from.name}: Inicio no longer offers "the other '
          'home"; with Bots on the bar its menu has no Bots entry', (
        tester,
      ) async {
        _layout([
          GestureDockTab.home,
          GestureDockTab.create,
          GestureDockTab.bots,
        ]);
        await _start(tester, from);
        final s = _strings(tester);
        await _hold(tester, GestureDockTab.home);
        final menu = _menu(tester);
        expect(menu, isNot(contains(s.missionBotsLabel)));
        expect(menu, isNot(contains('Inicio general')));
        expect(menu, isNot(contains('General home')));
        expect(
          menu,
          containsAll([s.gdActivityTitle, s.gdEditDock, s.gdHideDock]),
        );
      });

      testWidgets('from ${from.name}: a layout without Bots reaches the Bots '
          'home from Inicio\'s menu', (tester) async {
        _layout([GestureDockTab.home, GestureDockTab.create]);
        final routes = await _start(tester, from);
        final s = _strings(tester);
        await _hold(tester, GestureDockTab.home);
        if (from == _From.botsHome) {
          // Already there: nothing to offer.
          expect(_menu(tester), isNot(contains(s.missionBotsLabel)));
          return;
        }
        await tester.tap(_shortcut(s.missionBotsLabel));
        await tester.pumpAndSettle();
        expect(_onTop('mission-title'), findsOneWidget);
        expect(routes.screens, 2);
        expect(DockModes.instance.mode, DockMode.bots);
      });

      testWidgets('from ${from.name}: the menus\' places open above the home '
          'of this mode', (tester) async {
        _layout([
          GestureDockTab.home,
          GestureDockTab.create,
          GestureDockTab.projects,
          GestureDockTab.settings,
        ]);
        final routes = await _start(tester, from);
        final s = _strings(tester);
        final above = from.mode == DockMode.bots ? 3 : 2;
        for (final (holder, label, place) in [
          (GestureDockTab.home, s.dockSessionsLabel, GestureDockTab.search),
          (GestureDockTab.home, s.gdShortCron, GestureDockTab.cron),
          (GestureDockTab.create, s.dockSessionsLabel, GestureDockTab.search),
          (GestureDockTab.projects, s.gdShortTasks, GestureDockTab.tasks),
          (GestureDockTab.projects, s.gdTabProjects, GestureDockTab.projects),
          (GestureDockTab.settings, s.drawerTools, GestureDockTab.tools),
        ]) {
          await _hold(tester, holder);
          await tester.tap(_shortcut(label));
          await tester.pumpAndSettle();
          expect(
            _onTop('place-${place.name}'),
            findsOneWidget,
            reason: '${holder.name} > $label',
          );
          expect(routes.screens, above, reason: '${holder.name} > $label');
          expect(DockModes.instance.mode, from.mode);
        }
        await _hold(tester, GestureDockTab.settings);
        await tester.tap(_shortcut(s.gdSettingsTitle));
        await tester.pumpAndSettle();
        expect(find.byType(GestureDockSettingsScreen), findsOneWidget);
      });
    }

    testWidgets('Nuevo on the Bots home: a new chat, a new profile, a new '
        'room', (tester) async {
      _layout([GestureDockTab.home, GestureDockTab.create]);
      await _start(tester, _From.botsHome);
      final s = _strings(tester);
      await _hold(tester, GestureDockTab.create);
      expect(
        _menu(tester),
        containsAllInOrder([s.gdGotoNewChat, s.missionCreateBotLabel]),
      );
      await tester.tap(_shortcut(s.gdGotoNewChat));
      await tester.pumpAndSettle();
      expect(_log, ['new-chat']);
    });
  });

  // The stand-ins above replace the screens; these are the screens the app
  // opens. Each route is read before it builds (they need a server).
  group('the app\'s own screens', () {
    for (final (tab, screen) in const <(GestureDockTab, Type)>[
      (GestureDockTab.search, SessionListScreen),
      (GestureDockTab.bots, MissionControlScreen),
      (GestureDockTab.tools, ToolsHubScreen),
      (GestureDockTab.settings, SettingsScreen),
      (GestureDockTab.cron, CronScreen),
      (GestureDockTab.tasks, TasksScreen),
      (GestureDockTab.projects, OwnedResourceHost<TuiGatewayClient>),
    ]) {
      testWidgets('${tab.name} is $screen', (tester) async {
        _layout([GestureDockTab.home, tab]);
        await _start(tester, _From.generalOther);
        GestureDockHost.debugPlace = null;
        // Any change the dock listens to: it reads its screens again.
        await GestureDockController.instance.setOpaque(true);
        await tester.pump();
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        await tester.tap(_item(tab));
        Route<dynamic>? top;
        navigator.popUntil((route) {
          top = route;
          return true;
        });
        final built = (top! as MaterialPageRoute<dynamic>).builder(
          navigator.context,
        );
        expect(built.runtimeType, screen);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    }

    test('Chats: a chat bubble, the label "Chats", the stored name it '
        'always had', () {
      expect(GestureDockTab.search.name, 'search');
      expect(GestureDockTab.parse('search'), GestureDockTab.search);
      expect(
        gestureDockTabIcon(GestureDockTab.search),
        Icons.chat_bubble_outline_rounded,
      );
      expect(
        gestureDockTabIcon(GestureDockTab.search, selected: true),
        Icons.chat_bubble_rounded,
      );
      for (final tab in GestureDockTab.values) {
        for (final selected in [false, true]) {
          expect(
            gestureDockTabIcon(tab, selected: selected),
            isNot(anyOf(Icons.search, Icons.search_rounded)),
            reason: 'no magnifier on the dock: ${tab.name}',
          );
        }
      }
    });

    testWidgets('Chats is called "Chats" on the bar, in the editor and in '
        'the menus, in both languages', (tester) async {
      for (final (locale, label) in const [
        (Locale('es'), 'Chats'),
        (Locale('en'), 'Chats'),
      ]) {
        final strings = await Strings.delegate.load(locale);
        expect(gestureDockTabLabel(strings, GestureDockTab.search), label);
        expect(
          gestureDockTabLabel(strings, GestureDockTab.create),
          strings.gdGotoNewChat,
        );
      }
      _layout([GestureDockTab.home, GestureDockTab.create]);
      await _start(tester, _From.generalHome);
      await _hold(tester, GestureDockTab.home);
      expect(_menu(tester), contains('Chats'));
      expect(_menu(tester), isNot(contains('Buscar chats')));
    });
  });

  // Every screen that mounts a dock, and what it tells the dock it is. A
  // new mount site, or a screen that stops saying which item it is, has to
  // come through here (and through the table at the top).
  group('mount sites', () {
    Map<String, String> sources() => {
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart')))
        file.path.replaceAll('\\', '/'): file.readAsStringSync(),
    };

    test('the dock is mounted by Home, Mission Control and the shell only', () {
      final direct = [
        for (final entry in sources().entries)
          if (RegExp(
            r'(?<![A-Za-z_])Dock\(\s*\n?\s*profileId:',
          ).hasMatch(entry.value))
            entry.key,
      ]..sort();
      expect(direct, [
        'lib/core/screens/home_dashboard_screen.dart',
        'lib/core/screens/mission_control_screen.dart',
        'lib/core/widgets/general_dock_shell.dart',
      ]);
    });

    test('each shell screen says which item it is', () {
      const expected = {
        'lib/core/screens/cron_screen.dart':
            'currentDestination: DockItemId.cron',
        'lib/core/screens/tasks_screen.dart':
            'currentDestination: DockItemId.tasks',
        'lib/core/screens/tools_hub_screen.dart':
            'currentDestination: DockItemId.tools',
        'lib/core/screens/session_list_screen.dart':
            'includeSessionsAction: false',
        'lib/core/screens/settings_screen.dart': 'includeSettingsAction: false',
        'lib/core/screens/projects_center_screen.dart':
            'gestureTab: GestureDockTab.projects',
        // No dock item of their own.
        'lib/core/screens/gateway_manager_screen.dart': null,
        'lib/core/screens/profiles_screen.dart': null,
        'lib/core/screens/voice_settings_screen.dart': null,
      };
      final all = sources();
      final shells = [
        for (final entry in all.entries)
          if (entry.value.contains('GeneralDockShell(') &&
              !entry.key.endsWith('general_dock_shell.dart'))
            entry.key,
      ]..sort();
      expect(shells, expected.keys.toList()..sort());
      for (final MapEntry(key: path, value: marker) in expected.entries) {
        final source = all[path]!;
        if (marker != null) {
          expect(source, contains(marker), reason: path);
        } else {
          for (final other in expected.values.whereType<String>()) {
            expect(source, isNot(contains(other)), reason: '$path: $other');
          }
        }
      }
    });

    test('Home and Mission Control mark their own item and leave Inicio to '
        'the first route', () {
      final all = sources();
      final home = all['lib/core/screens/home_dashboard_screen.dart']!;
      expect(
        home,
        contains('DockItemId.home: const DockItemAction(selected: true)'),
      );
      final bots = all['lib/core/screens/mission_control_screen.dart']!;
      final actions = bots.substring(
        bots.indexOf('Map<DockItemId, DockItemAction> _botDockActions()'),
      );
      expect(
        actions.substring(0, actions.indexOf('DockItemId.create')),
        allOf(
          contains('popUntil((r) => r.isFirst)'),
          contains('selected: true'),
          contains("ValueKey('mission-destination-bots')"),
        ),
      );
      expect(bots, isNot(contains('gestureTab: GestureDockTab.home')));
    });
  });
}
