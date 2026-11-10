// The board's columns: two on a phone, four on a wide screen (an unfolded
// foldable, a tablet), from the same stored layout. Nothing about the
// columns is written, so a board arranged on a phone opens unchanged on a
// wide screen and back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';
import 'package:hermes_android/core/home/board/home_board_store.dart';
import 'package:hermes_android/core/home/board/home_board_view.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/home_board_fixtures.dart';

HomeWidgetInstance _w(String id, HomeWidgetKind kind, HomeWidgetSize size) =>
    HomeWidgetInstance(id: id, kind: kind, size: size);

/// A phone board that is full: Ahora wide, Chats large, Cron and Tareas.
HomeBoardLayout _phoneBoard() => HomeBoardLayout([
  _w('now', HomeWidgetKind.now, HomeWidgetSize.wide),
  _w('chats', HomeWidgetKind.continueChats, HomeWidgetSize.large),
  _w('cron', HomeWidgetKind.cron, HomeWidgetSize.small),
  _w('tasks', HomeWidgetKind.tasks, HomeWidgetSize.small),
]);

/// The designed wide board: ten widgets that need four columns.
HomeBoardLayout _wideBoard() => HomeBoardLayout([
  _w('now', HomeWidgetKind.now, HomeWidgetSize.wide),
  _w('chats', HomeWidgetKind.continueChats, HomeWidgetSize.large),
  _w('cron', HomeWidgetKind.cron, HomeWidgetSize.small),
  _w('tasks', HomeWidgetKind.tasks, HomeWidgetSize.small),
  _w('bots', HomeWidgetKind.team, HomeWidgetSize.wide),
  _w('limits', HomeWidgetKind.planLimits, HomeWidgetSize.wide),
  _w('today', HomeWidgetKind.today, HomeWidgetSize.small),
  _w('server', HomeWidgetKind.server, HomeWidgetSize.small),
  _w('rooms', HomeWidgetKind.room, HomeWidgetSize.small),
  _w('bot', HomeWidgetKind.bot, HomeWidgetSize.small),
]);

void main() {
  setUp(() => debugLivingBotFacesStill = true);

  group('the rule', () {
    test('two columns under 840 dp, four from there', () {
      expect(HomeBoardGridRule.columnsFor(320), 2);
      expect(HomeBoardGridRule.columnsFor(412), 2);
      expect(HomeBoardGridRule.columnsFor(600), 2);
      expect(HomeBoardGridRule.columnsFor(839.9), 2);
      expect(HomeBoardGridRule.columnsFor(840), 4);
      expect(HomeBoardGridRule.columnsFor(1100), 4);
      expect(HomeBoardGridRule.columnsFor(1248), 4);
    });

    test('a plan of four columns has sixteen slots on four rows and places '
        'the designed ten widgets', () {
      final plan = HomeBoardPlan.of(_wideBoard().items, 4, columns: 4);
      expect(plan.columns, 4);
      expect(plan.capacity, 16);
      expect(plan.hidden, isEmpty);
      expect(plan.placed, hasLength(10));
      // Dense first fit: Ahora takes the first two columns of the first
      // row, Chats the next two over two rows.
      expect(
        plan.slotOf('now'),
        const HomeBoardSlot(col: 0, row: 0, cols: 2, rows: 1),
      );
      expect(
        plan.slotOf('chats'),
        const HomeBoardSlot(col: 2, row: 0, cols: 2, rows: 2),
      );
      expect(
        plan.slotOf('cron'),
        const HomeBoardSlot(col: 0, row: 1, cols: 1, rows: 1),
      );
      expect(
        plan.slotOf('tasks'),
        const HomeBoardSlot(col: 1, row: 1, cols: 1, rows: 1),
      );
      for (final slot in plan.slots) {
        expect(slot.col + slot.cols, lessThanOrEqualTo(4));
        expect(slot.row + slot.rows, lessThanOrEqualTo(4));
      }
    });

    test('the same ten widgets on two columns: what has no place is hidden, '
        'in order, and comes back on four', () {
      final phone = HomeBoardPlan.of(_wideBoard().items, 4);
      expect(phone.columns, 2);
      expect(phone.capacity, 8);
      expect(phone.hidden, isNotEmpty);
      final wide = HomeBoardPlan.of(_wideBoard().items, 4, columns: 4);
      expect(wide.hidden, isEmpty);
      // Default columns are the phone's: callers that pass nothing keep
      // what they had.
      expect(HomeBoardPlan.of(_phoneBoard().items, 4).columns, 2);
    });

    test('fits and allows reason on the plan\'s own columns', () {
      final full = HomeBoardPlan.of(_phoneBoard().items, 4);
      expect(full.full, isTrue);
      expect(full.fits(HomeWidgetSize.small), isFalse);
      final wide = HomeBoardPlan.of(_phoneBoard().items, 4, columns: 4);
      expect(wide.full, isFalse);
      expect(wide.fits(HomeWidgetSize.large), isTrue);
      expect(
        HomeBoardPlan.allows(
          _phoneBoard().items,
          4,
          'cron',
          HomeWidgetSize.large,
        ),
        isFalse,
      );
      expect(
        HomeBoardPlan.allows(
          _phoneBoard().items,
          4,
          'cron',
          HomeWidgetSize.large,
          columns: 4,
        ),
        isTrue,
      );
    });
  });

  group('the stored layout', () {
    test('knows nothing of columns: the same JSON on a phone and on a wide '
        'screen, and a layout read back is the one that was stored', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = HomeBoardStore(prefs);
      final layout = _wideBoard();
      await store.save('c1', 'default', layout);
      final stored = prefs.getString(HomeBoardStore.keyFor('c1', 'default'))!;
      expect(stored, isNot(contains('columns')));
      final read = store.read('c1', 'default')!;
      // Planning it for either board writes nothing and changes nothing.
      HomeBoardPlan.of(read.items, 4);
      HomeBoardPlan.of(read.items, 4, columns: 4);
      expect(read.encode(), layout.encode());
      expect(prefs.getString(HomeBoardStore.keyFor('c1', 'default')), stored);
    });
  });

  group('the board', () {
    Future<(HomeBoardGeometry, List<String>)> pump(
      WidgetTester tester,
      Size size, {
      HomeBoardLayout? layout,
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final key = GlobalKey<HomeBoardViewState>();
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('es'),
          theme: AppTheme.fromId('console'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            body: HomeBoardView(
              key: key,
              layout: layout ?? _wideBoard(),
              data: homeData(
                chats: homeChats(),
                bots: homeBots(astraWaits: true),
                rooms: homeRooms(),
                approvals: [homeApproval()],
                automations: homeJobs(),
                tasks: homeTasksBoard(),
              ),
              actions: HomeCalls().actions,
              onChanged: (next) => changes.add(next.encode()),
              newId: () => 'new',
              clock: () => homeFixtureNow,
              bottomPadding: 82,
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull, reason: '$size');
      return (key.currentState!.geometry!, changes);
    }

    /// Every placed tile inside the page, clear of the dock, and none over
    /// another.
    void expectLaidOut(
      WidgetTester tester,
      HomeBoardGeometry geometry,
      Size size,
    ) {
      final rects = <String, Rect>{};
      for (final item in geometry.plan.placed) {
        final rect = tester.getRect(
          find.byKey(ValueKey('home-tile-${item.kind.name}-${item.id}')),
        );
        expect(rect.left, greaterThanOrEqualTo(0), reason: item.id);
        expect(rect.right, lessThanOrEqualTo(size.width), reason: item.id);
        expect(rect.top, greaterThanOrEqualTo(0), reason: item.id);
        expect(
          rect.bottom,
          lessThanOrEqualTo(size.height - 82 + 0.5),
          reason: item.id,
        );
        for (final other in rects.entries) {
          // The cards never overlap (the tile's box is the card's).
          final overlap = rect.intersect(other.value);
          expect(
            overlap.width <= 0.5 || overlap.height <= 0.5,
            isTrue,
            reason: '${item.id} over ${other.key}',
          );
        }
        rects[item.id] = rect;
      }
    }

    testWidgets('a phone keeps two columns; the widgets that do not fit stay '
        'hidden, nothing is written', (tester) async {
      for (final width in [320.0, 360.0, 390.0, 412.0, 600.0]) {
        final size = Size(width, 800);
        final (geometry, changes) = await pump(tester, size);
        expect(geometry.columns, 2, reason: '$width');
        expect(geometry.plan.capacity, lessThanOrEqualTo(10));
        expect(geometry.plan.hidden, isNotEmpty, reason: '$width');
        expect(changes, isEmpty);
        expectLaidOut(tester, geometry, size);
      }
    });

    testWidgets('a wide screen lays the same layout out in four columns, '
        'all ten widgets shown, nothing written', (tester) async {
      for (final width in [840.0, 1100.0, 1248.0]) {
        final size = Size(width, 800);
        final (geometry, changes) = await pump(tester, size);
        expect(geometry.columns, 4, reason: '$width');
        expect(geometry.plan.hidden, isEmpty, reason: '$width');
        expect(geometry.plan.placed, hasLength(10));
        expect(changes, isEmpty);
        // The cells are the width of a phone's, never stretched past the
        // board's ceiling.
        final board = geometry.cellWidth * 4 + HomeBoardMetrics.gap * 3;
        expect(board, lessThanOrEqualTo(HomeBoardMetrics.maxWidthFor(4) + 0.5));
        expect(geometry.cellWidth, greaterThan(180));
        expectLaidOut(tester, geometry, size);
      }
    });

    testWidgets('at 2x text the four columns hold too', (tester) async {
      final size = const Size(840, 800);
      final (geometry, _) = await pump(tester, size, textScale: 2);
      expect(geometry.columns, 4);
      expectLaidOut(tester, geometry, size);
    });

    testWidgets('a phone layout on a wide screen: its four widgets in four '
        'columns, the rest free; back on the phone, unchanged', (tester) async {
      final layout = _phoneBoard();
      final (wide, changesWide) = await pump(
        tester,
        const Size(840, 800),
        layout: layout,
      );
      expect(wide.columns, 4);
      expect(wide.plan.placed, hasLength(4));
      expect(wide.plan.free, 16 - 8);
      final (phone, changesPhone) = await pump(
        tester,
        const Size(390, 800),
        layout: layout,
      );
      expect(phone.columns, 2);
      expect(phone.plan.full, isTrue);
      expect(changesWide, isEmpty);
      expect(changesPhone, isEmpty);
    });
  });
}
