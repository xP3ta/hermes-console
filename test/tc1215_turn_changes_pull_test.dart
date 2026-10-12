// Owner report (1.2.15): the notch sheet looked broken when swiped closed;
// "review the other pills". The turn changes sheet is sampled frame by frame
// while its header is pulled down and let go.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/unified_diff.dart';
import 'package:hermes_android/core/widgets/chat/turn_changes_sheet.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _frame = Duration(milliseconds: 16);
final _anchor = GlobalKey(debugLabel: 'anchor');

Future<void> _pumpHost(
  WidgetTester tester,
  void Function(BuildContext context) open, {
  bool reduce = false,
}) async {
  tester.view.physicalSize = const Size(412, 892);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Align(
            alignment: const Alignment(0, 0.8),
            child: GestureDetector(
              key: _anchor,
              onTap: () => open(context),
              child: const SizedBox(
                width: 48,
                height: 48,
                child: Center(child: Text('+')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('turn changes sheet, pulled down by its header', () {
    final files = [FileDiff('lib/a.dart', '@@ -1 +1 @@\n-x\n+y')];
    final done = find.byKey(const ValueKey('turn-changes-done'));

    Future<void> openSheet(WidgetTester tester, {bool reduce = false}) async {
      await _pumpHost(
        tester,
        (context) => showTurnChangesSheet(context, files),
        reduce: reduce,
      );
      await tester.tap(find.byKey(_anchor));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(done, findsOneWidget);
    }

    Future<TestGesture> pull(WidgetTester tester, double distance) async {
      final sheet = tester.getRect(
        find.byKey(const ValueKey('turn-changes-sheet')),
      );
      final finger = await tester.startGesture(
        sheet.topCenter + const Offset(0, 14),
      );
      for (var moved = 0.0; moved < distance; moved += 10) {
        await finger.moveBy(const Offset(0, 10));
        await tester.pump(_frame);
      }
      return finger;
    }

    testWidgets('released short, it returns over a few frames, never past '
        'its place', (tester) async {
      await openSheet(tester);
      final rest = tester.getTopLeft(done).dy;
      final finger = await pull(tester, 60);
      final pulled = tester.getTopLeft(done).dy;
      expect(pulled, greaterThan(rest + 30));
      await finger.up();
      final ys = <double>[];
      for (var i = 0; i < 30; i++) {
        await tester.pump(_frame);
        ys.add(tester.getTopLeft(done).dy);
      }
      expect(ys.first, greaterThan(rest + 5), reason: 'no snap: $ys');
      var previous = pulled;
      for (final y in ys) {
        expect(y, lessThanOrEqualTo(previous + 0.01), reason: '$ys');
        expect(y, greaterThanOrEqualTo(rest - 0.01), reason: '$ys');
        previous = y;
      }
      expect(ys.last, closeTo(rest, 0.01));
      expect(done, findsOneWidget);
    });

    testWidgets('reduced motion: released short, it is back at once', (
      tester,
    ) async {
      await openSheet(tester, reduce: true);
      final rest = tester.getTopLeft(done).dy;
      final finger = await pull(tester, 60);
      await finger.up();
      await tester.pump();
      expect(tester.getTopLeft(done).dy, closeTo(rest, 0.01));
    });

    testWidgets('released past the threshold, it closes where it was left', (
      tester,
    ) async {
      await openSheet(tester);
      final finger = await pull(tester, 130);
      final pulled = tester.getTopLeft(done).dy;
      await finger.up();
      // It leaves from where the finger let go, receding: it never goes
      // back up towards its resting place first.
      var previous = pulled;
      for (var i = 0; i < 30; i++) {
        await tester.pump(_frame);
        if (done.evaluate().isEmpty) break;
        final y = tester.getTopLeft(done).dy;
        expect(y, greaterThanOrEqualTo(pulled - 15), reason: 'f$i');
        expect(y, greaterThanOrEqualTo(previous - 0.01), reason: 'f$i');
        previous = y;
      }
      expect(done, findsNothing);
    });
  });
}
