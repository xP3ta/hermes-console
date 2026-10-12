import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/shell/dock_edit_sheet.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Dock edit mode (owner request after QA 9494): pick 2–5 destinations,
// Inicio always there, reorder by drag or with TalkBack actions,
// Restablecer, Listo; one layout for General and Bots, stored per device.

GestureDockController get _c => GestureDockController.instance;

Widget _app() => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          key: const ValueKey('open'),
          onPressed: () => showDockEditSheet(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

List<String> _selected(WidgetTester tester) {
  final rows = find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('dock-edit-selected-'),
  );
  final entries = [
    for (final e in rows.evaluate())
      (
        tester.getTopLeft(find.byWidget(e.widget)).dy,
        (e.widget.key! as ValueKey<String>).value.substring(
          'dock-edit-selected-'.length,
        ),
      ),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final e in entries) e.$2];
}

Future<void> _open(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 1400);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app());
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

IconButton _button(WidgetTester tester, String key) =>
    tester.widget<IconButton>(find.byKey(ValueKey(key)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _c.resetForTesting(
      settings: const GestureDockSettings(
        tabs: GestureDockTab.legacyDefaultLayout,
      ),
    );
  });

  tearDown(() => _c.resetForTesting());

  testWidgets('shows the current layout; Listo stores the edited one', (
    tester,
  ) async {
    await _open(tester);
    expect(_selected(tester), ['home', 'create', 'projects', 'settings']);
    await tester.tap(find.byKey(const ValueKey('dock-edit-add-activity')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dock-edit-remove-create')));
    await tester.pump();
    expect(_selected(tester), ['home', 'projects', 'settings', 'activity']);
    await tester.tap(find.byKey(const ValueKey('dock-edit-done')));
    await tester.pumpAndSettle();
    expect(_c.value.tabs, [
      GestureDockTab.home,
      GestureDockTab.projects,
      GestureDockTab.settings,
      GestureDockTab.activity,
    ]);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(GestureDockController.storageKey),
      contains('"tabs":["home","projects","settings","activity"]'),
    );
  });

  testWidgets('Inicio cannot be removed; at most 5, at least 2', (
    tester,
  ) async {
    await _open(tester);
    expect(_button(tester, 'dock-edit-remove-home').onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('dock-edit-add-bots')));
    await tester.pump();
    expect(_selected(tester), hasLength(5));
    expect(_button(tester, 'dock-edit-add-search').onPressed, isNull);
    for (final t in ['create', 'projects', 'settings']) {
      await tester.tap(find.byKey(ValueKey('dock-edit-remove-$t')));
      await tester.pump();
    }
    expect(_selected(tester), ['home', 'bots']);
    expect(_button(tester, 'dock-edit-remove-bots').onPressed, isNull);
  });

  testWidgets('Restablecer goes back to the default items', (tester) async {
    _c.resetForTesting(
      settings: const GestureDockSettings(
        tabs: [GestureDockTab.home, GestureDockTab.search],
      ),
    );
    await _open(tester);
    expect(_selected(tester), ['home', 'search']);
    await tester.tap(find.byKey(const ValueKey('dock-edit-reset')));
    await tester.pump();
    expect(_selected(tester), ['home', 'create', 'search', 'bots', 'tools']);
  });

  testWidgets('TalkBack reorders with move actions', (tester) async {
    final handle = tester.ensureSemantics();
    await _open(tester);
    final row = tester.getSemantics(
      find.byKey(const ValueKey('dock-edit-selected-settings')),
    );
    tester.semantics.customAction(
      find.semantics.byPredicate((n) => n.id == row.id),
      const CustomSemanticsAction(label: 'Mover antes'),
    );
    await tester.pump();
    expect(_selected(tester), ['home', 'create', 'settings', 'projects']);
    handle.dispose();
  });

  testWidgets('dragging a handle reorders', (tester) async {
    await _open(tester);
    final from = tester.getCenter(
      find.byKey(const ValueKey('dock-edit-drag-settings')),
    );
    final to = tester.getCenter(
      find.byKey(const ValueKey('dock-edit-drag-create')),
    );
    final g = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(Offset(0, (to.dy - from.dy - 8) / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(_selected(tester), ['home', 'settings', 'create', 'projects']);
  });
}
