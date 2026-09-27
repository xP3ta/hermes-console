import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart'
    show HermesSegmentedControl;
import 'package:hermes_android/l10n/app_localizations.dart';

final _now = DateTime(2026, 9, 26, 21, 40); // Saturday

Future<Future<String?>> _open(
  WidgetTester tester,
  String cron, {
  Size size = const Size(390, 844),
  double scale = 1,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (c) {
          ctx = c;
          return const Scaffold();
        },
      ),
    ),
  );
  final result = showHermesScheduleBuilder(
    ctx,
    initialCron: cron,
    now: () => _now,
  );
  await tester.pumpAndSettle();
  return result;
}

String _summary(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('schedule-summary'))).data!;

void main() {
  testWidgets('opens on the real schedule (18:30 weekdays, not 09:00)', (
    tester,
  ) async {
    await _open(tester, '30 18 * * 1-5');
    expect(find.text('18'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(_summary(tester), 'Weekdays at 18:30 · next: Mon 28, 18:30');
    // Cron syntax stays hidden until Advanced.
    expect(find.byKey(const ValueKey('schedule-cron-field')), findsNothing);
  });

  testWidgets('day chips edit the days and the live summary', (tester) async {
    final result = await _open(tester, '30 18 * * 1-5');
    await tester.tap(find.byKey(const ValueKey('schedule-day-6')));
    await tester.pump();
    expect(_summary(tester), startsWith('Monday to Saturday at 18:30'));
    await tester.tap(find.byKey(const ValueKey('schedule-apply')));
    await tester.pumpAndSettle();
    expect(await result, '30 18 * * 1-6');
  });

  testWidgets('no day selected disables apply', (tester) async {
    await _open(tester, '0 9 * * 1');
    await tester.tap(find.byKey(const ValueKey('schedule-day-1')));
    await tester.pump();
    final apply = tester.widget<IconButton>(
      find.byKey(const ValueKey('schedule-apply')),
    );
    expect(apply.onPressed, isNull);
    expect(_summary(tester), 'Pick at least one day.');
  });

  testWidgets('switching modes keeps the chosen time', (tester) async {
    final result = await _open(tester, '15 7 * * *');
    await tester.tap(find.byKey(const ValueKey('schedule-mode-month')));
    await tester.pumpAndSettle();
    expect(_summary(tester), startsWith('On day 1 of every month at 7:15'));
    await tester.tap(find.byKey(const ValueKey('schedule-apply')));
    await tester.pumpAndSettle();
    expect(await result, '15 7 1 * *');
  });

  testWidgets('interval presets', (tester) async {
    final result = await _open(tester, '0 9 * * *');
    await tester.tap(find.byKey(const ValueKey('schedule-mode-interval')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-interval-15')));
    await tester.pump();
    expect(_summary(tester), 'Every 15 min · next: 21:45');
    await tester.tap(find.byKey(const ValueKey('schedule-apply')));
    await tester.pumpAndSettle();
    expect(await result, '*/15 * * * *');
  });

  testWidgets('presets apply in one tap', (tester) async {
    final result = await _open(tester, '*/5 * * * *');
    await tester.tap(find.byKey(const ValueKey('schedule-preset-morning')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('schedule-apply')));
    await tester.pumpAndSettle();
    expect(await result, '0 8 * * *');
  });

  testWidgets('time picker changes the hour', (tester) async {
    final result = await _open(tester, '0 9 * * *');
    await tester.tap(find.byKey(const ValueKey('schedule-time')));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    // Switch to keyboard entry for a deterministic edit.
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '18');
    await tester.enterText(fields.at(1), '30');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-apply')));
    await tester.pumpAndSettle();
    expect(await result, '30 18 * * *');
  });

  testWidgets('custom shapes keep Advanced collapsed and never show syntax', (
    tester,
  ) async {
    final result = await _open(tester, '1,7,13,44 2,5,9,22 * * *');
    expect(find.byKey(const ValueKey('schedule-cron-field')), findsNothing);
    expect(find.textContaining('*'), findsNothing);
    expect(_summary(tester), startsWith('Custom schedule'));
    // Only after asking for Advanced the raw text appears.
    await tester.tap(find.byKey(const ValueKey('schedule-advanced')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('schedule-cron-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('schedule-cron-field')),
      'nope',
    );
    await tester.pump();
    expect(
      find.text('This is not a valid cron expression (5 fields).'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('schedule-cron-field')),
      '0 20 * * 5',
    );
    await tester.pump();
    expect(_summary(tester), startsWith('Every Friday at 20:00'));
    await tester.tap(find.byKey(const ValueKey('schedule-apply')));
    await tester.pumpAndSettle();
    expect(await result, '0 20 * * 5');
  });

  group('real jobs open in the right mode with their fields', () {
    Finder selected(String mode) => find.descendant(
      of: find.byKey(ValueKey('schedule-mode-$mode')),
      matching: find.byType(Text),
    );

    testWidgets('*/5 14-17 * * 1-5 → Repeat, 5 min, 14:00–18:00, Mon–Fri', (
      tester,
    ) async {
      final result = await _open(
        tester,
        '*/5 14-17 * * 1-5',
        locale: const Locale('es'),
      );
      expect(find.byKey(const ValueKey('schedule-cron-field')), findsNothing);
      expect(find.textContaining('*/5'), findsNothing);
      expect(selected('interval'), findsOneWidget);
      final segments = tester
          .widget<HermesSegmentedControl<HermesScheduleMode>>(
            find.byType(HermesSegmentedControl<HermesScheduleMode>),
          );
      expect(segments.value, HermesScheduleMode.interval);
      final five = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('schedule-interval-5')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(five.properties.selected, isTrue);
      final window = tester.widget<Switch>(
        find.byKey(const ValueKey('schedule-window-switch')),
      );
      expect(window.value, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('schedule-window-start')),
          matching: find.text('14:00'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('schedule-window-end')),
          matching: find.text('18:00'),
        ),
        findsOneWidget,
      );
      expect(
        _summary(tester),
        'Cada 5 min, de 14:00 a 17:55, laborables · próxima: lun 28, 14:00',
      );
      // Unchanged apply returns the same schedule.
      await tester.tap(find.byKey(const ValueKey('schedule-apply')));
      await tester.pumpAndSettle();
      expect(await result, '*/5 14-17 * * 1-5');
    });

    testWidgets('*/5 7-9 * * 1-5 round-trips', (tester) async {
      final result = await _open(tester, '*/5 7-9 * * 1-5');
      expect(
        _summary(tester),
        'Every 5 min from 7:00 to 9:55 on weekdays · next: Mon 28, 7:00',
      );
      await tester.tap(find.byKey(const ValueKey('schedule-apply')));
      await tester.pumpAndSettle();
      expect(await result, '*/5 7-9 * * 1-5');
    });

    testWidgets('every 60m stays the Hermes native interval', (tester) async {
      final result = await _open(tester, 'every 60m');
      expect(find.textContaining('60m'), findsNothing);
      final segments = tester
          .widget<HermesSegmentedControl<HermesScheduleMode>>(
            find.byType(HermesSegmentedControl<HermesScheduleMode>),
          );
      expect(segments.value, HermesScheduleMode.interval);
      expect(_summary(tester), 'Every hour');
      await tester.tap(find.byKey(const ValueKey('schedule-apply')));
      await tester.pumpAndSettle();
      expect(await result, 'every 60m');
    });

    testWidgets('a window turns the interval into a clock cron', (
      tester,
    ) async {
      final result = await _open(tester, 'every 60m');
      await tester.tap(find.byKey(const ValueKey('schedule-window-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-day-6')));
      await tester.tap(find.byKey(const ValueKey('schedule-day-7')));
      await tester.pump();
      expect(
        _summary(tester),
        startsWith('Every hour from 9:00 to 17:00 on weekdays'),
      );
      await tester.tap(find.byKey(const ValueKey('schedule-apply')));
      await tester.pumpAndSettle();
      expect(await result, '0 9-17 * * 1-5');
    });

    testWidgets('building */5 14-17 * * 1-5 from scratch', (tester) async {
      final result = await _open(tester, '0 9 * * *');
      await tester.tap(find.byKey(const ValueKey('schedule-mode-interval')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-interval-5')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('schedule-window-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-window-start')));
      await tester.pumpAndSettle();
      final startOption = find.byKey(
        const ValueKey('schedule-window-start-14'),
      );
      await tester.scrollUntilVisible(
        startOption,
        60,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('schedule-window-start-surface')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(startOption);
      await tester.pumpAndSettle();
      await tester.tap(startOption);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-window-end')));
      await tester.pumpAndSettle();
      final endOption = find.byKey(const ValueKey('schedule-window-end-18'));
      await tester.scrollUntilVisible(
        endOption,
        60,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('schedule-window-end-surface')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(endOption);
      await tester.pumpAndSettle();
      await tester.tap(endOption);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-day-6')));
      await tester.tap(find.byKey(const ValueKey('schedule-day-7')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('schedule-apply')));
      await tester.pumpAndSettle();
      expect(await result, '*/5 14-17 * * 1-5');
    });

    for (final (raw, mode) in const [
      ('0 9 * * *', HermesScheduleMode.daily),
      ('30 18 * * 1-5', HermesScheduleMode.days),
      ('0 */2 * * *', HermesScheduleMode.interval),
      ('0 9 1 * *', HermesScheduleMode.month),
    ]) {
      testWidgets('"$raw" opens in $mode and applies unchanged', (
        tester,
      ) async {
        final result = await _open(tester, raw);
        final segments = tester
            .widget<HermesSegmentedControl<HermesScheduleMode>>(
              find.byType(HermesSegmentedControl<HermesScheduleMode>),
            );
        expect(segments.value, mode);
        expect(find.byKey(const ValueKey('schedule-cron-field')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('schedule-apply')));
        await tester.pumpAndSettle();
        expect(await result, raw);
      });
    }
  });

  testWidgets('cancel returns null', (tester) async {
    final result = await _open(tester, '0 9 * * *');
    await tester.tap(find.byKey(const ValueKey('schedule-cancel')));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('Spanish copy', (tester) async {
    await _open(tester, '30 18 * * 1-5', locale: const Locale('es'));
    expect(find.text('Cuándo'), findsOneWidget);
    expect(find.text('L'), findsOneWidget);
    expect(find.text('X'), findsOneWidget);
    expect(_summary(tester), 'Laborables a las 18:30 · próxima: lun 28, 18:30');
  });

  for (final size in const [Size(360, 800), Size(390, 844)]) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      testWidgets('no layout exceptions at $size ×$scale', (tester) async {
        await _open(tester, '30 18 * * 1-5', size: size, scale: scale);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('schedule-mode-interval')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final chip = find.byKey(const ValueKey('schedule-interval-5'));
        expect(tester.getSize(chip).height, greaterThanOrEqualTo(40));
        // Chips are compact, several per line.
        expect(
          tester.getSize(chip).width,
          lessThan(size.width / (scale > 1.5 ? 2 : 3)),
        );
        final fifteen = find.byKey(const ValueKey('schedule-interval-15'));
        if (scale == 1.0) {
          expect(tester.getCenter(fifteen).dy, tester.getCenter(chip).dy);
        }
      });
    }
  }
}
