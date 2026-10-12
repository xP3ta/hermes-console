import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The floating dock sits over the bottom of every screen wrapped in
// GeneralDockShell (Tools, Settings, Cron, Tasks, Sessions…). Scrolled to
// the end, the last row must stay fully visible above it, whatever padding
// the screen itself uses.

final _connection = SavedConnection(
  id: 'dock-overlap',
  label: 'Dock QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

Widget _host(ConnectionManager manager, {bool ownPadding = true}) =>
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: Scaffold(
        body: GeneralDockShell(
          connection: _connection,
          connManager: manager,
          // The same shape as the Tools hub: a list with its own small bottom
          // padding.
          body: ListView(
            key: const ValueKey('overlap-list'),
            // Without its own padding a ListView pads by the ambient safe
            // area, so the shell must not report the system inset twice.
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
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final controller = DockPreferencesController.instance;
  // Process-wide singleton: back to the default (dock on) after each test.
  tearDown(() => controller.setUseDock(true));

  for (final (safeBottom, depth, ownPadding) in [
    (0.0, DockDepth.flat, true),
    (34.0, DockDepth.flat, true),
    (34.0, DockDepth.floating, true),
    (34.0, DockDepth.flat, false),
  ]) {
    testWidgets('the last row sits just above the dock '
        '(safe bottom $safeBottom, ${depth.name}, '
        '${ownPadding ? 'own padding' : 'default padding'})', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await controller.ensureLoaded();
      await controller.updateGeneral(
        (p) => p.copyWith(style: p.style.copyWith(depth: depth)),
        persist: false,
      );
      addTearDown(
        () => controller.updateGeneral(
          (p) => p.copyWith(style: p.style.copyWith(depth: DockDepth.flat)),
          persist: false,
        ),
      );
      tester.view.padding = FakeViewPadding(bottom: safeBottom * 3);
      tester.view.devicePixelRatio = 3;
      // A phone window (390x844): tablets put the dock in a side rail.
      tester.view.physicalSize = const Size(1170, 2532);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_host(manager, ownPadding: ownPadding));
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const ValueKey('overlap-list')),
        const Offset(0, -10000),
      );
      await tester.pumpAndSettle();

      final dock = tester.getRect(
        find.byKey(const ValueKey('general-mode-floating-dock')),
      );
      final list = tester.getRect(find.byKey(const ValueKey('overlap-list')));
      final last = tester.getRect(find.byKey(const ValueKey('row-29')));
      // Above the dock: nothing hidden under it…
      expect(
        last.bottom,
        lessThanOrEqualTo(dock.top),
        reason: 'last row ends at ${last.bottom}, dock starts at ${dock.top}',
      );
      // …and no dead band: the list ends a constant 8dp above the dock,
      // whatever the system inset or the style's lift.
      expect(dock.top - list.bottom, closeTo(8, 0.5));
      if (!ownPadding) {
        // The system inset is inside the dock's footprint already: no second
        // band of it between the last row and the end of the list.
        expect(list.bottom - last.bottom, closeTo(0, 0.5));
      }
    });
  }

  testWidgets('with the dock switched off nothing is reserved', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await controller.setUseDock(false);
    await tester.pumpWidget(_host(manager));
    await tester.pumpAndSettle();
    final list = tester.getRect(find.byKey(const ValueKey('overlap-list')));
    final screen = tester.getRect(find.byType(Scaffold));
    expect(list.bottom, screen.bottom);
  });
}
