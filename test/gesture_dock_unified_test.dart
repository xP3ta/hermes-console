// One dock for the whole app: the General Home and the Bots home (Mission
// Control) mount the same dock with the same items. Where each item goes
// from each of them is test/dock_destinations_test.dart; this file is about
// the dock being one and the same in both modes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/home/board/home_board_data.dart';
import 'package:hermes_android/core/shell/dock_activity_sheet.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_mode.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_host.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/core/widgets/dock_style.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'dock-unified',
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

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: home,
);

Widget _realBotsHome(ConnectionManager manager) => MissionControlScreen(
  connection: _connection,
  connManager: manager,
  dataSource: _Source(),
);

/// The General Home: its dock and a button that opens the Bots home the way
/// the app does (pushed above Home).
Widget _generalHome(
  ConnectionManager manager,
  WidgetBuilder botsHome, {
  List<String>? log,
}) => _app(
  Builder(
    builder: (context) {
      void openBots() => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: botsHome));
      return Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: ElevatedButton(
                key: const ValueKey('open-bots'),
                onPressed: openBots,
                child: const Text('Inicio general'),
              ),
            ),
            Dock(
              profileId: DockProfileId.general,
              connection: _connection,
              connManager: manager,
              actions: {
                DockItemId.home: const DockItemAction(selected: true),
                DockItemId.create: DockItemAction(
                  onTap: () => log?.add('general-new'),
                ),
                DockItemId.bots: DockItemAction(
                  onTap: () {
                    log?.add('bots');
                    openBots();
                  },
                ),
                DockItemId.settings: DockItemAction(onTap: () {}),
              },
            ),
          ],
        ),
      );
    },
  ),
);

/// Stand-in for Mission Control with recording actions: the same `Dock`
/// call Mission Control makes (Bots profile, create orbits, optional
/// shortcuts), anchored as the Bots home.
class _BotsHomeStandIn extends StatelessWidget {
  final ConnectionManager manager;
  final List<String> log;

  const _BotsHomeStandIn({required this.manager, required this.log});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return BotsHomeAnchor(
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            const Center(child: Text('bots', key: ValueKey('bots-home'))),
            Dock(
              profileId: DockProfileId.bots,
              connection: _connection,
              connManager: manager,
              onNewChat: () => log.add('create'),
              createOrbits: [
                DockCreateOrbit(
                  controlKey: const ValueKey('stand-in-create-bot'),
                  label: strings.missionCreateBotLabel,
                  icon: Icons.account_circle_outlined,
                  onTap: () => log.add('orbit:bot'),
                ),
                DockCreateOrbit(
                  controlKey: const ValueKey('stand-in-create-room'),
                  label: strings.missionCreateRoomLabel,
                  icon: Icons.groups_2_outlined,
                  onTap: () => log.add('orbit:room'),
                ),
              ],
              actions: {
                DockItemId.home: DockItemAction(
                  onTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
                ),
                DockItemId.bots: DockItemAction(onTap: () {}, selected: true),
                DockItemId.create: const DockItemAction(),
                DockItemId.cron: DockItemAction(onTap: () => log.add('cron')),
                DockItemId.tasks: DockItemAction(onTap: () => log.add('tasks')),
                DockItemId.sessions: DockItemAction(
                  onTap: () => log.add('sessions'),
                ),
                DockItemId.tools: DockItemAction(onTap: () => log.add('tools')),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// A General screen (Ajustes-like) pushed above whatever is on screen.
Widget _generalScreen(ConnectionManager manager) => Scaffold(
  body: GeneralDockShell(
    connection: _connection,
    connManager: manager,
    includeSettingsAction: false,
    body: const Center(child: Text('ajustes', key: ValueKey('general-screen'))),
  ),
);

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.padding = const FakeViewPadding(bottom: 34 * 3);
  tester.view.viewPadding = const FakeViewPadding(bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

Future<ConnectionManager> _manager() async =>
    ConnectionManager.create(await SharedPreferences.getInstance());

Strings _strings(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(GestureDock)));

Finder _tab(GestureDockTab tab) =>
    find.byKey(ValueKey('gesture-dock-tab-${tab.name}'));

/// Whether [tab] is the selected item of the dock in view.
bool _glows(GestureDockTab tab) =>
    (find.byKey(ValueKey('gesture-dock-tab-${tab.name}')).evaluate().last.widget
            as Semantics)
        .properties
        .selected ??
    false;

Future<void> _hold(WidgetTester tester, GestureDockTab tab) async {
  final gesture = await tester.startGesture(tester.getCenter(_tab(tab)));
  await tester.pump(const Duration(milliseconds: 500));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 250));
}

List<String> _popoverLabels(WidgetTester tester) => [
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

/// What the dock on screen shows: widget type, tab keys in order, labels.
List<String> _dockSignature(WidgetTester tester) {
  final dock = find.byType(GestureDock);
  expect(dock, findsOneWidget);
  final semantics = find
      .descendant(
        of: dock,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'gesture-dock-tab-',
              ),
        ),
      )
      .evaluate()
      .map((e) => e.widget as Semantics);
  return [
    for (final s in semantics)
      '${(s.key! as ValueKey<String>).value}:${s.properties.label}',
  ];
}

double _barOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .ancestor(
            of: _tab(GestureDockTab.home),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.instance.resetForTesting(gestureDock: true);
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(),
    );
    DockGeometry.instance.resetForTesting();
    DockModes.instance.resetForTesting();
    GestureDockHost.debugActivity = null;
    GestureDockHost.debugFeed = DockActivityFeed();
  });

  tearDown(() async {
    FeatureFlags.instance.resetForTesting();
    GestureDockHost.debugActivity = null;
    GestureDockHost.debugFeed = null;
    GestureDockHost.debugPlace = null;
    await DockPreferencesController.instance.setUseDock(true);
  });

  testWidgets('the Bots home mounts the gesture dock, not the Bots bar', (
    tester,
  ) async {
    _phone(tester);
    final manager = await _manager();
    await tester.pumpWidget(
      _generalHome(manager, (_) => _realBotsHome(manager)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-bots')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mission-title')), findsOneWidget);
    expect(find.byType(GestureDockHost), findsOneWidget);
    expect(find.byType(GestureDock), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-mode-floating-dock')), findsNothing);
    expect(find.byKey(const ValueKey('bot-mode-dock-back')), findsNothing);
    // Inicio is the General Home, not this screen.
    expect(_glows(GestureDockTab.home), isFalse);
    expect(DockModes.instance.mode, DockMode.bots);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the Bots home body keeps the unified dock\'s footprint', (
    tester,
  ) async {
    _phone(tester);
    final manager = await _manager();
    await tester.pumpWidget(
      _generalHome(manager, (_) => _realBotsHome(manager)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-bots')));
    await tester.pumpAndSettle();
    // 34 inset + 14 gap + 60 bar + 8 breathing, as on every General screen.
    const footprint = 34.0 + 14 + 60 + 8;
    expect(
      gestureDockFootprint(tester.element(find.byType(GestureDock))),
      footprint,
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Padding &&
            w.padding == const EdgeInsets.only(bottom: footprint),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('General Home and Bots home show the identical dock', (
    tester,
  ) async {
    _phone(tester);
    final manager = await _manager();
    await tester.pumpWidget(
      _generalHome(manager, (_) => _realBotsHome(manager)),
    );
    await tester.pumpAndSettle();
    final general = _dockSignature(tester);
    expect(general, [
      'gesture-dock-tab-home:Inicio',
      'gesture-dock-tab-create:Nuevo chat',
      'gesture-dock-tab-search:Chats',
      'gesture-dock-tab-bots:Bots',
      'gesture-dock-tab-tools:Herramientas',
    ]);
    final generalRect = tester.getRect(
      find.byKey(const ValueKey('gesture-dock-pointer')),
    );
    await tester.tap(find.byKey(const ValueKey('open-bots')));
    await tester.pumpAndSettle();
    expect(_dockSignature(tester), general);
    expect(
      tester.getRect(find.byKey(const ValueKey('gesture-dock-pointer'))),
      generalRect,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Mission Control offers every former Bots-bar shortcut', (
    tester,
  ) async {
    _phone(tester);
    // The four items whose menus held them.
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(
        tabs: GestureDockTab.legacyDefaultLayout,
      ),
    );
    final manager = await _manager();
    await tester.pumpWidget(
      _generalHome(manager, (_) => _realBotsHome(manager)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-bots')));
    await tester.pumpAndSettle();
    final s = _strings(tester);
    final expected = <GestureDockTab, List<String>>{
      GestureDockTab.home: [s.dockSessionsLabel, s.gdShortCron],
      GestureDockTab.create: [s.gdGotoNewChat, s.missionCreateBotLabel],
      GestureDockTab.projects: [s.gdShortTasks],
      GestureDockTab.settings: [s.drawerTools],
    };
    for (final MapEntry(key: tab, value: labels) in expected.entries) {
      await _hold(tester, tab);
      final shown = _popoverLabels(tester);
      for (final label in labels) {
        expect(shown, contains(label), reason: '${tab.name}: $shown');
      }
      await tester.tapAt(const Offset(195, 200));
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('leaving the Bots home returns the dock to General mode', (
    tester,
  ) async {
    _phone(tester);
    final manager = await _manager();
    await tester.pumpWidget(
      _generalHome(manager, (_) => _realBotsHome(manager)),
    );
    await tester.pumpAndSettle();
    expect(DockModes.instance.mode, DockMode.general);
    await tester.tap(find.byKey(const ValueKey('open-bots')));
    await tester.pumpAndSettle();
    expect(DockModes.instance.mode, DockMode.bots);
    Navigator.of(
      tester.element(find.byKey(const ValueKey('mission-title'))),
    ).pop();
    await tester.pump();
    // General again as soon as the pop starts, not after the exit animation.
    expect(DockModes.instance.mode, DockMode.general);
    await tester.pumpAndSettle();
    expect(DockModes.instance.mode, DockMode.general);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a mounted dock follows a mode change it did not cause', (
    tester,
  ) async {
    _phone(tester);
    final manager = await _manager();
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(
        tabs: [GestureDockTab.home, GestureDockTab.bots],
      ),
    );
    GestureDockHost.debugPlace = (context, tab) => Scaffold(
      body: Center(child: Text(tab.name, key: ValueKey('place-${tab.name}'))),
    );
    late StateSetter toggle;
    var anchored = false;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              StatefulBuilder(
                builder: (context, setState) {
                  toggle = setState;
                  return anchored
                      ? const BotsHomeAnchor(child: SizedBox.expand())
                      : const SizedBox.expand();
                },
              ),
              GestureDockHost(
                current: GestureDockTab.settings,
                connection: _connection,
                connManager: manager,
                actions: const {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    // General: Bots opens the Bots home.
    await tester.tap(_tab(GestureDockTab.bots));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('place-bots')), findsOneWidget);
    Navigator.of(
      tester.element(find.byKey(const ValueKey('place-bots'))),
    ).pop();
    await tester.pumpAndSettle();
    // This route becomes a Bots home: Bots is where it already is.
    toggle(() => anchored = true);
    await tester.pump();
    await tester.pump();
    await tester.tap(_tab(GestureDockTab.bots));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('place-bots')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  // QA 9494/9495 owner report: "estoy en Inicio y me lleva a Bots" (a swipe
  // up used to offer the other mode's home right under the thumb). The dock
  // has no swipe at all now; Actividad opens from any item's menu and holds
  // no dock destination.
  testWidgets('on General Home no swipe does anything; Actividad opens from '
      'a menu, with no dock destination in it', (tester) async {
    _phone(tester);
    final manager = await _manager();
    final log = <String>[];
    final feed = DockActivityFeed();
    GestureDockHost.debugFeed = feed;
    final owner = Object();
    feed.publish(
      owner,
      const HomeGlance(
        running: [
          HomeGlanceItem(
            key: 'chat:c1',
            kind: HomeGlanceKind.runningChat,
            title: 'Chat en marcha',
            target: 'c1',
          ),
        ],
      ),
      (item) => log.add('open:${item.key}'),
    );
    await tester.pumpWidget(
      _generalHome(
        manager,
        (_) => _BotsHomeStandIn(manager: manager, log: log),
        log: log,
      ),
    );
    await tester.pumpAndSettle();
    final center = tester.getCenter(
      find.byKey(const ValueKey('gesture-dock-pointer')),
    );
    final sheet = find.byKey(const ValueKey('dock-activity-sheet'));
    for (final step in const [
      Offset(10, 0),
      Offset(-10, 0),
      Offset(0, -10),
      Offset(0, 10),
    ]) {
      final g = await tester.startGesture(center);
      for (var i = 0; i < 6; i++) {
        await g.moveBy(step);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('open-bots')), findsOneWidget);
      expect(DockModes.instance.mode, DockMode.general);
      expect(sheet, findsNothing);
      expect(GestureDockController.instance.hidden.value, isFalse);
      expect(log, isEmpty);
    }

    await _hold(tester, GestureDockTab.home);
    await tester.tap(
      find.byKey(
        ValueKey('gesture-dock-shortcut-${_strings(tester).gdActivityTitle}'),
      ),
    );
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    expect(DockModes.instance.mode, DockMode.general);
    expect(log, isNot(contains('bots')));
    expect(
      find.descendant(of: sheet, matching: find.text('Chat en marcha')),
      findsOneWidget,
    );
    for (final label in [
      _strings(tester).missionBotsLabel,
      _strings(tester).gdTabProjects,
      _strings(tester).gdTabSettings,
    ]) {
      expect(
        find.descendant(of: sheet, matching: find.text(label)),
        findsNothing,
        reason: label,
      );
    }
    await tester.tap(find.text('Chat en marcha'));
    await tester.pumpAndSettle();
    expect(log, ['open:chat:c1']);
    expect(sheet, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('"Esconder el dock" is in every item\'s menu; the handle '
      'brings it back', (tester) async {
    _phone(tester);
    final manager = await _manager();
    await tester.pumpWidget(
      _generalHome(manager, (_) => _realBotsHome(manager)),
    );
    await tester.pumpAndSettle();
    final hide = _strings(tester).gdHideDock;
    for (final tab in GestureDockController.instance.value.tabs) {
      await _hold(tester, tab);
      expect(_popoverLabels(tester), contains(hide), reason: tab.name);
      await tester.tapAt(const Offset(195, 200));
      await tester.pumpAndSettle();
    }
    await _hold(tester, GestureDockTab.tools);
    await tester.tap(find.byKey(ValueKey('gesture-dock-shortcut-$hide')));
    await tester.pumpAndSettle();
    expect(GestureDockController.instance.hidden.value, isTrue);
    expect(_barOpacity(tester), 0);
    await tester.tap(find.byKey(const ValueKey('gesture-dock-handle')));
    await tester.pumpAndSettle();
    expect(GestureDockController.instance.hidden.value, isFalse);
    expect(_barOpacity(tester), 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a dock hidden by hand stays hidden across the mode switch', (
    tester,
  ) async {
    _phone(tester);
    final manager = await _manager();
    await tester.pumpWidget(
      _generalHome(manager, (_) => _realBotsHome(manager)),
    );
    await tester.pumpAndSettle();
    GestureDockController.instance.setHidden(true);
    await tester.pumpAndSettle();
    expect(_barOpacity(tester), 0);
    await tester.tap(find.byKey(const ValueKey('open-bots')));
    await tester.pumpAndSettle();
    // The Bots home opens with the dock still hidden, and its own handle.
    expect(find.byType(GestureDock), findsOneWidget);
    expect(_barOpacity(tester), 0);
    await tester.tap(
      find.byKey(const ValueKey('gesture-dock-handle')).hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(GestureDockController.instance.hidden.value, isFalse);
    expect(_barOpacity(tester), 1);
    Navigator.of(
      tester.element(find.byKey(const ValueKey('mission-title'))),
    ).pop();
    await tester.pumpAndSettle();
    expect(_barOpacity(tester), 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the amber dot shows what any profile needs, in Bot Mode too', (
    tester,
  ) async {
    _phone(tester);
    final manager = await _manager();
    final aggregate = GlobalActivityAggregate(
      journal: GlobalActivityJournal(
        read: () async => null,
        write: (_) async {},
      ),
    );
    addTearDown(aggregate.dispose);
    GestureDockHost.debugActivity = aggregate;
    final log = <String>[];
    await tester.pumpWidget(
      _generalHome(
        manager,
        (_) => _BotsHomeStandIn(manager: manager, log: log),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-bots')));
    await tester.pumpAndSettle();
    Navigator.of(
      tester.element(find.byKey(const ValueKey('bots-home'))),
    ).push(MaterialPageRoute<void>(builder: (_) => _generalScreen(manager)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gesture-dock-attention')), findsNothing);
    aggregate.applyRecoverySnapshot(
      scope: const GlobalActivityScope(
        connectionId: 'dock-unified',
        profile: 'another-bot',
        durableSessionId: 's1',
        runtimeSessionId: 'r1',
        replayEpoch: 'e1',
      ),
      running: true,
      waitingForUser: true,
      replayTruncated: false,
      processCount: 0,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('gesture-dock-attention')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the tablet rail lists the dock\'s items, same icons', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(2400, 1600);
    addTearDown(tester.view.reset);
    const layout = [
      GestureDockTab.home,
      GestureDockTab.create,
      GestureDockTab.search,
      GestureDockTab.bots,
      GestureDockTab.settings,
    ];
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(tabs: layout),
    );
    final manager = await _manager();
    await tester.pumpWidget(_app(_generalScreen(manager)));
    await tester.pumpAndSettle();
    expect(find.byType(GestureDock), findsNothing);
    expect(find.byKey(const ValueKey('general-mode-dock-rail')), findsNothing);
    final rail = find.byKey(const ValueKey('gesture-dock-rail'));
    expect(rail, findsOneWidget);
    final tiles = find.descendant(
      of: rail,
      matching: find.byType(DockItemTile),
    );
    final shown = [
      for (final e in tiles.evaluate()) (e.widget as DockItemTile),
    ];
    expect(
      [for (final t in shown) (t.controlKey! as ValueKey<String>).value],
      [for (final tab in layout) 'gesture-dock-rail-${tab.name}'],
    );
    for (final (i, tab) in layout.indexed) {
      expect(shown[i].icon, gestureDockTabIcon(tab), reason: tab.name);
      expect(
        shown[i].selectedIcon,
        gestureDockTabIcon(tab, selected: true),
        reason: tab.name,
      );
    }
    // The Settings-like screen is the current place, and the only one.
    expect(
      [for (final tile in shown) tile.selected],
      [false, false, false, false, true],
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the tablet rail carries the amber dot too', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(2400, 1600);
    addTearDown(tester.view.reset);
    final aggregate = GlobalActivityAggregate(
      journal: GlobalActivityJournal(
        read: () async => null,
        write: (_) async {},
      ),
    );
    addTearDown(aggregate.dispose);
    GestureDockHost.debugActivity = aggregate;
    final manager = await _manager();
    await tester.pumpWidget(_app(_generalScreen(manager)));
    await tester.pumpAndSettle();
    final dot = find.byKey(const ValueKey('gesture-dock-rail-attention'));
    expect(dot, findsNothing);
    aggregate.applyRecoverySnapshot(
      scope: const GlobalActivityScope(
        connectionId: 'dock-unified',
        profile: 'another-bot',
        durableSessionId: 's1',
        runtimeSessionId: 'r1',
        replayEpoch: 'e1',
      ),
      running: true,
      waitingForUser: true,
      replayTruncated: false,
      processCount: 0,
    );
    await tester.pump();
    expect(dot, findsOneWidget);
    final home = tester.getRect(
      find.byKey(const ValueKey('gesture-dock-rail-home')),
    );
    expect(home.overlaps(tester.getRect(dot)), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  // The classic Bots bar: unreachable in the app, mounted only through
  // the test seam (see dock_single_test.dart).
  group('classic bar (test seam only)', () {
    setUp(() => FeatureFlags.instance.resetForTesting());

    testWidgets('Mission Control keeps the Bots bar and no gesture dock', (
      tester,
    ) async {
      _phone(tester);
      final manager = await _manager();
      await tester.pumpWidget(
        _generalHome(manager, (_) => _realBotsHome(manager)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('general-mode-floating-dock')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('open-bots')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('bot-mode-floating-dock')),
        findsOneWidget,
      );
      for (final id in ['home', 'bots', 'create']) {
        expect(
          find.byKey(ValueKey('bot-mode-dock-$id')),
          findsOneWidget,
          reason: id,
        );
      }
      expect(find.byType(GestureDock), findsNothing);
      expect(find.byType(GestureDockHost), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
