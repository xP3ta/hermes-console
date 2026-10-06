import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/shell/goto_sheet.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> log;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(welcomeSeen: true),
    );
    log = [];
  });

  GotoSheetActions actions() => GotoSheetActions(
    loadRecents: () async => [
      for (final (id, title) in [
        ('a', 'Notas de viaje'),
        ('b', 'Receta de pan'),
        ('c', 'Lista de la compra'),
        ('d', 'Ideas para el jardín'),
      ])
        GotoRecent(
          id: id,
          title: title,
          subtitle: 'ayer',
          onOpen: () => log.add('open $id'),
        ),
    ],
    onNewChat: () => log.add('new'),
    onSearchAll: () => log.add('all'),
    current: GestureDockTab.home,
    places: {
      GestureDockTab.home: null,
      GestureDockTab.projects: () => log.add('projects'),
      GestureDockTab.settings: () => log.add('settings'),
    },
  );

  Widget app({bool reduceMotion = false}) => MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.fromId('dark'),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const ValueKey('open'),
                onPressed: () => showGotoSheet(
                  context,
                  actions: actions(),
                  origin: const Rect.fromLTWH(14, 700, 332, 60),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('shows search, Nuevo chat, 3 recents and the places', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(GestureDockController.instance.sheetOpen, isTrue);
    expect(find.byKey(const ValueKey('goto-sheet-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('goto-sheet-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('goto-sheet-recent-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('goto-sheet-recent-c')), findsOneWidget);
    expect(find.byKey(const ValueKey('goto-sheet-recent-d')), findsNothing);
    for (final place in ['home', 'projects', 'settings']) {
      expect(find.byKey(ValueKey('goto-sheet-place-$place')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('goto-sheet-place-projects')));
    await tester.pumpAndSettle();
    expect(log, ['projects']);
    expect(find.byKey(const ValueKey('goto-sheet')), findsNothing);
    expect(GestureDockController.instance.sheetOpen, isFalse);
  });

  testWidgets('search filters recents and offers all chats', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('goto-sheet-search')),
      'jardín',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('goto-sheet-recent-d')), findsOneWidget);
    expect(find.byKey(const ValueKey('goto-sheet-recent-a')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('goto-sheet-search')),
      'zzz',
    );
    await tester.pump();
    expect(find.text('Ningún chat reciente se llama así'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('goto-sheet-search-all')));
    await tester.pumpAndSettle();
    expect(log, ['all']);
  });

  testWidgets('dragging the handle down more than 26 dp closes it', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('goto-sheet-grab')),
      const Offset(0, 20),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goto-sheet')), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('goto-sheet-grab')),
      const Offset(0, 40),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goto-sheet')), findsNothing);
  });

  testWidgets(
    'grows from the dock with a spring; instant with reduced motion',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      final mid = tester.widget<ScaleTransition>(
        find.ancestor(
          of: find.byKey(const ValueKey('goto-sheet')),
          matching: find.byType(ScaleTransition),
        ),
      );
      // The spring overshoots 1 on the way in.
      expect(mid.scale.value, greaterThan(1));
      // Anchored at the dock, near the bottom of the screen.
      expect(mid.alignment.y, greaterThan(0.5));
      await tester.pumpAndSettle();
      Navigator.of(
        tester.element(find.byKey(const ValueKey('goto-sheet'))),
      ).pop();
      await tester.pumpAndSettle();

      await tester.pumpWidget(app(reduceMotion: true));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('goto-sheet')), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('goto-sheet')),
          matching: find.byType(ScaleTransition),
        ),
        findsNothing,
      );
    },
  );
}
