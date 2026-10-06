import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/screens/settings_screen.dart'
    show GestureDockFlagTile;
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_host.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'gesture-shell',
  label: 'Gesture QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: home,
);

Widget _shell(
  ConnectionManager manager, {
  Widget? body,
  bool includeSettingsAction = true,
}) => _app(
  Scaffold(
    body: GeneralDockShell(
      connection: _connection,
      connManager: manager,
      includeSettingsAction: includeSettingsAction,
      body:
          body ??
          ListView(
            key: const ValueKey('list'),
            children: [
              for (var i = 0; i < 30; i++)
                SizedBox(
                  key: ValueKey('row-$i'),
                  height: 64,
                  child: Text('Fila $i'),
                ),
            ],
          ),
    ),
  ),
);

/// Home mounts the dock directly beside its content (no shell).
Widget _homeLike() => _app(
  Scaffold(
    body: Stack(
      fit: StackFit.expand,
      children: [
        const SizedBox.expand(),
        Dock(
          profileId: DockProfileId.general,
          actions: {
            DockItemId.home: const DockItemAction(selected: true),
            DockItemId.create: DockItemAction(onTap: () {}),
            DockItemId.bots: DockItemAction(onTap: () {}),
            DockItemId.settings: DockItemAction(onTap: () {}),
          },
        ),
      ],
    ),
  ),
);

void _phone(WidgetTester tester, {double safeBottom = 34}) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.padding = FakeViewPadding(bottom: safeBottom * 3);
  tester.view.viewPadding = FakeViewPadding(bottom: safeBottom * 3);
  addTearDown(tester.view.reset);
}

Future<ConnectionManager> _manager() async =>
    ConnectionManager.create(await SharedPreferences.getInstance());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.instance.resetForTesting();
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(welcomeSeen: true),
    );
    DockGeometry.instance.resetForTesting();
  });

  tearDown(() async {
    FeatureFlags.instance.resetForTesting();
    await DockPreferencesController.instance.setUseDock(true);
  });

  group('flag off (default)', () {
    testWidgets('the shell keeps the classic dock and mounts no gesture dock', (
      tester,
    ) async {
      _phone(tester);
      final manager = await _manager();
      await tester.pumpWidget(_shell(manager));
      await tester.pumpAndSettle();
      expect(FeatureFlags.instance.gestureDock.value, isFalse);
      expect(
        find.byKey(const ValueKey('general-mode-floating-dock')),
        findsOneWidget,
      );
      expect(find.byType(GestureDockHost), findsNothing);
      expect(find.byType(GestureDock), findsNothing);
      expect(find.byKey(const ValueKey('gesture-dock-pointer')), findsNothing);
      expect(find.byKey(const ValueKey('gesture-dock-line')), findsNothing);
      // Navigation unchanged: the classic items are all there.
      for (final id in ['home', 'create', 'bots', 'settings']) {
        expect(
          find.byKey(ValueKey('general-mode-dock-$id')),
          findsOneWidget,
          reason: id,
        );
      }
      // Padding unchanged: the list still ends 8 dp above the classic bar.
      final dock = tester.getRect(
        find.byKey(const ValueKey('general-mode-floating-dock')),
      );
      final list = tester.getRect(find.byKey(const ValueKey('list')));
      expect(dock.top - list.bottom, closeTo(8, .5));
      expect(DockGeometry.instance.rect.value, isNull);
    });

    testWidgets('Home keeps the classic dock too', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_homeLike());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('general-mode-floating-dock')),
        findsOneWidget,
      );
      expect(find.byType(GestureDock), findsNothing);
    });
  });

  group('flag on', () {
    setUp(() => FeatureFlags.instance.resetForTesting(gestureDock: true));

    testWidgets('the shell shows the gesture dock instead of the classic bar', (
      tester,
    ) async {
      _phone(tester);
      final manager = await _manager();
      await tester.pumpWidget(_shell(manager));
      await tester.pump();
      expect(find.byType(GestureDock), findsOneWidget);
      expect(
        find.byKey(const ValueKey('general-mode-floating-dock')),
        findsNothing,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('gesture-dock-pointer'))),
        // 390 wide, 34 dp inset: 14 dp sides, 14 dp above the inset.
        const Rect.fromLTWH(14, 844 - 34 - 14 - 60, 362, 60),
      );
      await tester.pumpWidget(const SizedBox());
    });

    for (final (safeBottom, ownPadding) in [
      (0.0, true),
      (34.0, true),
      (48.0, false),
    ]) {
      testWidgets('the last row ends 8 dp above the bar '
          '(inset $safeBottom, ${ownPadding ? 'own' : 'default'} padding)', (
        tester,
      ) async {
        _phone(tester, safeBottom: safeBottom);
        final manager = await _manager();
        await tester.pumpWidget(
          _shell(
            manager,
            body: ListView(
              key: const ValueKey('list'),
              padding: ownPadding
                  ? const EdgeInsets.fromLTRB(16, 16, 16, 28)
                  : null,
              children: [
                for (var i = 0; i < 30; i++)
                  SizedBox(
                    key: ValueKey('row-$i'),
                    height: 64,
                    child: Text('Fila $i'),
                  ),
              ],
            ),
          ),
        );
        await tester.pump();
        await tester.drag(
          find.byKey(const ValueKey('list')),
          const Offset(0, -10000),
        );
        await tester.pumpAndSettle();
        final bar = tester.getRect(
          find.byKey(const ValueKey('gesture-dock-pointer')),
        );
        final list = tester.getRect(find.byKey(const ValueKey('list')));
        final last = tester.getRect(find.byKey(const ValueKey('row-29')));
        expect(last.bottom, lessThanOrEqualTo(bar.top));
        expect(bar.top - list.bottom, closeTo(gestureDockBreathing, .5));
        if (!ownPadding) expect(list.bottom - last.bottom, closeTo(0, .5));
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('hiding the dock moves no content and rebuilds none', (
      tester,
    ) async {
      _phone(tester);
      final manager = await _manager();
      var builds = 0;
      await tester.pumpWidget(
        _shell(
          manager,
          body: Builder(
            builder: (_) {
              builds++;
              return const SizedBox.expand(key: ValueKey('content'));
            },
          ),
        ),
      );
      await tester.pump();
      final before = tester.getRect(find.byKey(const ValueKey('content')));
      final count = builds;
      GestureDockController.instance.setHidden(true);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getRect(find.byKey(const ValueKey('content'))), before);
      GestureDockController.instance.setHidden(false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(builds, count);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Ajustes is the current tab on the Settings shell', (
      tester,
    ) async {
      _phone(tester);
      final manager = await _manager();
      await tester.pumpWidget(_shell(manager, includeSettingsAction: false));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('gesture-dock-tab-settings')),
          matching: find.byKey(const ValueKey('gesture-dock-glow')),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Inicio from a pushed screen goes back to the first route', (
      tester,
    ) async {
      _phone(tester);
      final manager = await _manager();
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const ValueKey('open'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        body: GeneralDockShell(
                          connection: _connection,
                          connManager: manager,
                          body: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(find.byType(GestureDock), findsOneWidget);
      await tester.tapAt(const Offset(14 + 6 + 362 / 4 / 2 - 3, 844 - 34 - 44));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('open')), findsOneWidget);
      expect(find.byType(GestureDock), findsNothing);
    });

    testWidgets('geometry stays published across a push and a pop', (
      tester,
    ) async {
      _phone(tester);
      final manager = await _manager();
      Widget screen(String key) => Scaffold(
        body: GeneralDockShell(
          connection: _connection,
          connManager: manager,
          body: Center(child: Text(key, key: ValueKey(key))),
        ),
      );
      await tester.pumpWidget(_app(screen('first')));
      await tester.pumpAndSettle();
      final rect = DockGeometry.instance.rect.value;
      expect(rect, isNotNull);
      Navigator.of(
        tester.element(find.byKey(const ValueKey('first'))),
      ).push(MaterialPageRoute<void>(builder: (_) => screen('second')));
      await tester.pumpAndSettle();
      expect(DockGeometry.instance.rect.value, rect);
      Navigator.of(tester.element(find.byKey(const ValueKey('second')))).pop();
      await tester.pumpAndSettle();
      expect(DockGeometry.instance.rect.value, rect);
      await tester.pumpWidget(const SizedBox());
      expect(DockGeometry.instance.rect.value, isNull);
    });

    testWidgets('Home gets the gesture dock with Inicio as current', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_homeLike());
      await tester.pump();
      expect(find.byType(GestureDock), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('gesture-dock-tab-home')),
          matching: find.byKey(const ValueKey('gesture-dock-glow')),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tablet windows keep the classic side rail', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(2400, 1600);
      addTearDown(tester.view.reset);
      final manager = await _manager();
      await tester.pumpWidget(_shell(manager));
      await tester.pumpAndSettle();
      expect(find.byType(GestureDock), findsNothing);
      expect(
        find.byKey(const ValueKey('general-mode-dock-rail')),
        findsOneWidget,
      );
    });

    testWidgets('"Usar dock flotante" off still removes every dock', (
      tester,
    ) async {
      _phone(tester);
      final manager = await _manager();
      await DockPreferencesController.instance.setUseDock(false);
      await tester.pumpWidget(_shell(manager));
      await tester.pump();
      expect(find.byType(GestureDock), findsNothing);
      final list = tester.getRect(find.byKey(const ValueKey('list')));
      expect(list.bottom, 844);
    });
  });

  testWidgets('the experimental row is the switch, persisted per device', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const Scaffold(body: Center(child: GestureDockFlagTile()))),
    );
    await tester.pump();
    final toggle = find.byKey(const ValueKey('settings-gesture-dock-flag'));
    expect(toggle, findsOneWidget);
    expect(FeatureFlags.instance.gestureDock.value, isFalse);
    await tester.tap(toggle);
    await tester.pump();
    expect(FeatureFlags.instance.gestureDock.value, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(FeatureFlags.gestureDockKey), isTrue);
    await tester.tap(toggle);
    await tester.pump();
    expect(FeatureFlags.instance.gestureDock.value, isFalse);
    expect(prefs.containsKey(FeatureFlags.gestureDockKey), isFalse);
  });
}
