// The dock after the navigation split: Inicio · Chats · Bots · Agentes ·
// Ajustes and «+». Agentes is on the bar only while the app has an SSH
// profile; Ajustes opens Ajustes de la app and is the selected item there.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/navigation/agents_destination.dart';
import 'package:hermes_android/core/screens/app_settings_screen.dart';
import 'package:hermes_android/core/screens/herdr_agents_screen.dart'
    show AgentsHomeScreen;
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/services/ssh_profile_presence.dart';
import 'package:hermes_android/core/shell/dock_activity_sheet.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_mode.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_host.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/nav_harness.dart';

class _Pushes extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

Widget _screen(ConnectionManager manager) => navApp(
  Scaffold(
    body: GeneralDockShell(
      connection: navConnection(),
      connManager: manager,
      body: const Center(child: Text('pantalla')),
    ),
  ),
);

/// The items of the dock in view, in the order a screen reader walks them.
List<String> _signature(WidgetTester tester) {
  final semantics = find
      .descendant(
        of: find.byType(GestureDock),
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
      '${(s.key! as ValueKey<String>).value.substring('gesture-dock-tab-'.length)}'
          ':${s.properties.label ?? ''}',
  ];
}

Finder _tab(GestureDockTab tab) =>
    find.byKey(ValueKey('gesture-dock-tab-${tab.name}'));

bool _selected(WidgetTester tester, GestureDockTab tab) =>
    tester.widget<Semantics>(_tab(tab)).properties.selected ?? false;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FeatureFlags.instance.resetForTesting(gestureDock: true);
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(),
    );
    DockGeometry.instance.resetForTesting();
    DockModes.instance.resetForTesting();
    GestureDockHost.debugActivity = null;
    GestureDockHost.debugFeed = DockActivityFeed();
    GestureDockHost.debugPlace = (context, tab) => Scaffold(
      body: Text('lugar-${tab.name}', key: ValueKey('place-${tab.name}')),
    );
    SshProfilePresence.instance.value = false;
  });

  tearDown(() async {
    SshProfilePresence.instance.value = false;
    FeatureFlags.instance.resetForTesting();
    GestureDockHost.debugPlace = null;
    GestureDockHost.debugFeed = null;
    await DockPreferencesController.instance.setUseDock(true);
  });

  testWidgets('without an SSH profile: Inicio · Chats · Bots · Ajustes and '
      '«+»', (tester) async {
    navView(tester, size: const Size(390, 800));
    await tester.pumpWidget(_screen(await navManager()));
    await tester.pumpAndSettle();
    expect(_signature(tester), [
      'home:Inicio',
      'search:Chats',
      'bots:Bots',
      'settings:Ajustes',
      'create:Nuevo chat',
    ]);
    expect(_tab(GestureDockTab.agents), findsNothing);
  });

  testWidgets('with an SSH profile: Agentes sits between Bots and Ajustes', (
    tester,
  ) async {
    SshProfilePresence.instance.value = true;
    navView(tester, size: const Size(390, 800));
    await tester.pumpWidget(_screen(await navManager()));
    await tester.pumpAndSettle();
    expect(_signature(tester), [
      'home:Inicio',
      'search:Chats',
      'bots:Bots',
      'agents:Agentes',
      'settings:Ajustes',
      'create:Nuevo chat',
    ]);
  });

  testWidgets('an SSH profile saved later brings Agentes in without '
      'remounting; removing the last one takes it out', (tester) async {
    navView(tester, size: const Size(390, 800));
    await tester.pumpWidget(_screen(await navManager()));
    await tester.pumpAndSettle();
    expect(_tab(GestureDockTab.agents), findsNothing);
    SshProfilePresence.instance.noteSaved();
    await tester.pumpAndSettle();
    expect(_tab(GestureDockTab.agents), findsOneWidget);
    SshProfilePresence.instance.value = false;
    await tester.pumpAndSettle();
    expect(_tab(GestureDockTab.agents), findsNothing);
  });

  testWidgets('Agentes opens its own section: no chat is needed', (
    tester,
  ) async {
    SshProfilePresence.instance.value = true;
    final observer = _Pushes();
    navView(tester, size: const Size(390, 800));
    final manager = await navManager();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        navigatorObservers: [observer],
        home: Scaffold(
          body: GeneralDockShell(
            connection: navConnection(),
            connManager: manager,
            body: const Center(child: Text('pantalla')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = observer.pushes;
    await tester.tap(_tab(GestureDockTab.agents));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('place-agents')), findsOneWidget);
    expect(observer.pushes, before + 1);
  });

  testWidgets('the Agentes destination is the terminal\'s agents view in '
      'the dock\'s own shell', (tester) async {
    final manager = await navManager();
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
    final screen =
        buildAgentsDestination(
              context,
              connection: navConnection(),
              connManager: manager,
            )
            as Scaffold;
    final shell = screen.body! as GeneralDockShell;
    expect(shell.currentDestination, DockItemId.agents);
    expect(shell.gestureTab, GestureDockTab.agents);
    expect(shell.body, isA<AgentsHomeScreen>());
    // Without an instance it says so instead.
    final none = buildAgentsDestination(context) as Scaffold;
    expect(none.body, isNot(isA<GeneralDockShell>()));
  });

  testWidgets('Ajustes opens Ajustes de la app; there it is the selected '
      'item and a second tap stays put', (tester) async {
    final observer = _Pushes();
    navView(tester, size: const Size(390, 800));
    final manager = await navManager();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        navigatorObservers: [observer],
        home: AppSettingsScreen(
          connection: navConnection(),
          connManager: manager,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_selected(tester, GestureDockTab.settings), isTrue);
    expect(_selected(tester, GestureDockTab.home), isFalse);
    final before = observer.pushes;
    await tester.tap(_tab(GestureDockTab.settings), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(observer.pushes, before, reason: 'no copy of Ajustes on top');
  });

  testWidgets('from another screen, the Ajustes item opens Ajustes de la '
      'app (not the old Settings screen)', (tester) async {
    navView(tester, size: const Size(390, 800));
    final manager = await navManager();
    GestureDockHost.debugPlace = null;
    await tester.pumpWidget(_screen(manager));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await tester.tap(_tab(GestureDockTab.settings));
    Route<dynamic>? top;
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    final built = (top! as MaterialPageRoute<dynamic>).builder(
      navigator.context,
    );
    expect(built, isA<AppSettingsScreen>());
    await tester.pumpWidget(const SizedBox());
  });

  group('every item is named and sized', () {
    for (final width in const [320.0, 360.0, 412.0, 673.0, 884.0]) {
      for (final scale in const [1.0, 2.0]) {
        testWidgets('${width.toInt()} dp, text ${scale}x: five places and '
            '«+», 48 dp, named for TalkBack, inside the window', (
          tester,
        ) async {
          SshProfilePresence.instance.value = true;
          navView(tester, size: Size(width, 800), scale: scale);
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(_screen(await navManager()));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final strings = Strings.of(
            tester.element(find.byType(GeneralDockShell)),
          );
          for (final tab in [
            GestureDockTab.home,
            GestureDockTab.search,
            GestureDockTab.bots,
            GestureDockTab.agents,
            GestureDockTab.settings,
            GestureDockTab.create,
          ]) {
            // A bar on a phone, a rail on a wider window.
            final bar = _tab(tab);
            final rail = find.byKey(ValueKey('gesture-dock-rail-${tab.name}'));
            final finder = bar.evaluate().isNotEmpty ? bar : rail;
            expect(finder, findsOneWidget, reason: tab.name);
            final rect = tester.getRect(finder);
            expect(rect.width, greaterThanOrEqualTo(48), reason: tab.name);
            expect(rect.height, greaterThanOrEqualTo(48), reason: tab.name);
            expect(rect.left, greaterThanOrEqualTo(0), reason: tab.name);
            expect(rect.right, lessThanOrEqualTo(width), reason: tab.name);
            expect(
              find.bySemanticsLabel(gestureDockTabLabel(strings, tab)),
              findsWidgets,
              reason: tab.name,
            );
          }
          handle.dispose();
        });
      }
    }

    testWidgets('a name on hover (tooltip) and one for TalkBack on each '
        'place', (tester) async {
      SshProfilePresence.instance.value = true;
      navView(tester, size: const Size(412, 800));
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_screen(await navManager()));
      await tester.pumpAndSettle();
      final strings = Strings.of(tester.element(find.byType(GestureDock)));
      for (final tab in [
        GestureDockTab.home,
        GestureDockTab.search,
        GestureDockTab.bots,
        GestureDockTab.agents,
        GestureDockTab.settings,
      ]) {
        final label = gestureDockTabLabel(strings, tab);
        expect(find.byTooltip(label), findsOneWidget, reason: tab.name);
        expect(
          tester.widget<Semantics>(_tab(tab)).properties.label,
          label,
          reason: tab.name,
        );
        expect(tester.widget<Semantics>(_tab(tab)).properties.button, isTrue);
      }
      handle.dispose();
    });
  });
}
