// Owner report (1.2.15): the notch sheet looked broken when swiped closed;
// "review the other pills". A notice is sampled frame by frame through a
// sideways swipe: once sent away it must not be seen again.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _frame = Duration(milliseconds: 16);
const _host = ValueKey('host');

Future<void> _pumpHost(WidgetTester tester) async {
  tester.view.physicalSize = const Size(412, 892);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: const Scaffold(body: SizedBox.expand(key: _host)),
    ),
  );
}

void main() {
  testWidgets('a notice swiped away does not come back while it leaves', (
    tester,
  ) async {
    await _pumpHost(tester);
    HermesNotice.of(tester.element(find.byKey(_host))).show(message: 'Copiado');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final card = find.byType(HermesNoticeCard);
    expect(card, findsOneWidget);
    final body = find.text('Copiado');
    double opacity() => tester
        .widget<Opacity>(
          find.ancestor(of: card, matching: find.byType(Opacity)).first,
        )
        .opacity;
    final rest = tester.getCenter(body).dx;
    final finger = await tester.startGesture(tester.getCenter(card));
    for (var i = 0; i < 10; i++) {
      await finger.moveBy(const Offset(-20, 0));
      await tester.pump(_frame);
    }
    var previous = tester.getCenter(body).dx;
    expect(previous, lessThan(rest - 150), reason: 'follows the finger');
    await finger.up();
    final log = StringBuffer('released at $previous\n');
    for (var i = 0; i < 40; i++) {
      await tester.pump(_frame);
      if (card.evaluate().isEmpty) break;
      final x = tester.getCenter(body).dx;
      final o = opacity();
      log.writeln('  $i: x=${x.toStringAsFixed(1)} opacity=$o');
      expect(
        o < 0.01 || x <= previous + 0.5,
        isTrue,
        reason: 'frame $i: it came back into view\n$log',
      );
      previous = x;
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsNothing, reason: '$log');
  });

  testWidgets('a swipe that lands while the notice is already leaving does '
      'not block the lane', (tester) async {
    await _pumpHost(tester);
    final notices = HermesNotice.of(tester.element(find.byKey(_host)));
    final first = notices.show(message: 'Uno')!;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final card = find.byType(HermesNoticeCard);
    // Its exit fade is under way when the swipe is reported.
    first.dismiss();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    tester.widget<HermesNoticeCard>(card).onSwipedAway!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsNothing);
    expect(first.isActive, isFalse);

    notices.show(message: 'Dos');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Dos'), findsOneWidget);
  });
}
