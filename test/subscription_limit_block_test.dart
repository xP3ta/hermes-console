import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart';
import 'package:hermes_android/core/widgets/subscription_limit_block.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final _now = DateTime.utc(2026, 10, 6, 12);

SubscriptionLimitWindow _w(String label, double used, {Duration? resetIn}) =>
    SubscriptionLimitWindow(
      label: label,
      usedPercent: used,
      resetAt: resetIn == null ? null : _now.add(resetIn),
    );

void main() {
  group('level', () {
    test('the fullest window decides: <80 none, ≥80 near, ≥100 reached', () {
      SubscriptionLimitLevel level(List<double> used) => SubscriptionLimits(
        kind: SubscriptionLimitKind.windows,
        windows: [for (final u in used) _w('w', u)],
      ).level;
      expect(level([]), SubscriptionLimitLevel.none);
      expect(level([10, 79.9]), SubscriptionLimitLevel.none);
      expect(level([10, 80]), SubscriptionLimitLevel.near);
      expect(level([99.4, 3]), SubscriptionLimitLevel.near);
      expect(level([3, 100]), SubscriptionLimitLevel.reached);
      expect(level([120]), SubscriptionLimitLevel.reached);
    });

    test('local and no-data never light the dot', () {
      expect(
        const SubscriptionLimits(kind: SubscriptionLimitKind.local).level,
        SubscriptionLimitLevel.none,
      );
      expect(
        const SubscriptionLimits(kind: SubscriptionLimitKind.noData).level,
        SubscriptionLimitLevel.none,
      );
    });
  });

  test('reset text: minutes, hours and minutes, days', () {
    expect(formatLimitDuration(const Duration(minutes: 35)), '35 min');
    expect(
      formatLimitDuration(const Duration(hours: 1, minutes: 48)),
      '1 h 48 min',
    );
    expect(formatLimitDuration(const Duration(hours: 3)), '3 h');
    expect(formatLimitDuration(const Duration(days: 2, hours: 5)), '2 d 5 h');
    expect(formatLimitDuration(const Duration(seconds: 20)), '1 min');
  });

  testWidgets('plan chip, one bar per window, reset and extra usage', (
    tester,
  ) async {
    final colors = AppTheme.fromId('amber').hermes;
    await _pump(
      tester,
      SubscriptionLimits(
        kind: SubscriptionLimitKind.windows,
        plan: 'Claude Max 5x',
        windows: [
          _w(
            'Current session',
            62,
            resetIn: const Duration(hours: 1, minutes: 48),
          ),
          _w('Current week', 38),
          _w('Opus week', 81, resetIn: const Duration(days: 2, hours: 5)),
        ],
        extraUsed: '4.20',
        extraLimit: '50.00',
        extraCurrency: 'USD',
      ),
    );

    expect(find.text('Límite de tu suscripción'), findsOneWidget);
    expect(find.text('Claude Max 5x'), findsOneWidget);
    expect(find.text('62% usado'), findsOneWidget);
    expect(find.text('38% usado'), findsOneWidget);
    expect(find.text('81% usado'), findsOneWidget);
    expect(find.text('se restablece en 1 h 48 min'), findsOneWidget);
    expect(find.text('se restablece en 2 d 5 h'), findsOneWidget);
    expect(find.text('Uso extra: 4.20 / 50.00 USD'), findsOneWidget);
    expect(find.text('Agotado'), findsNothing);
    expect(find.byKey(const ValueKey('limit-banner')), findsNothing);

    final bars = tester
        .widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        )
        .toList();
    expect(bars, hasLength(3));
    expect(bars[0].value, closeTo(0.62, 0.001));
    expect(bars[0].color, colors.accent);
    expect(bars[1].color, colors.accent);
    expect(bars[2].color, colors.warning);
  });

  testWidgets('a full window is red, says Agotado and raises the banner', (
    tester,
  ) async {
    final colors = AppTheme.fromId('amber').hermes;
    await _pump(
      tester,
      SubscriptionLimits(
        kind: SubscriptionLimitKind.windows,
        windows: [
          _w('Current session', 100, resetIn: const Duration(minutes: 35)),
          _w('Current week', 79),
        ],
      ),
    );
    expect(find.text('Agotado'), findsOneWidget);
    expect(find.text('100% usado'), findsNothing);
    final bars = tester
        .widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        )
        .toList();
    expect(bars[0].color, colors.error);
    expect(bars[0].value, 1);
    expect(bars[1].color, colors.accent);
    expect(
      find.text('Límite alcanzado. Se restablece en 35 min'),
      findsOneWidget,
    );
  });

  testWidgets('a full window without reset time still raises the banner', (
    tester,
  ) async {
    await _pump(
      tester,
      SubscriptionLimits(
        kind: SubscriptionLimitKind.windows,
        windows: [_w('Weekly', 100)],
      ),
    );
    expect(find.text('Límite alcanzado.'), findsOneWidget);
  });

  testWidgets('local model and no data are plain honest lines', (tester) async {
    await _pump(
      tester,
      const SubscriptionLimits(kind: SubscriptionLimitKind.local),
    );
    expect(
      find.text('Modelo local: sin límite de uso ni coste.'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await _pump(
      tester,
      const SubscriptionLimits(kind: SubscriptionLimitKind.noData),
    );
    expect(
      find.text('Sin datos de límite para este proveedor.'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('fits at 320 dp with text at 200 %', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      SubscriptionLimits(
        kind: SubscriptionLimitKind.windows,
        plan: 'ChatGPT Plus Business Annual',
        windows: [
          _w(
            'Current session window label',
            100,
            resetIn: const Duration(hours: 4, minutes: 2),
          ),
        ],
        extraUsed: '1234.56',
        extraLimit: '5000.00',
        extraCurrency: 'USD',
      ),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  SubscriptionLimits limits, {
  double textScale = 1,
}) {
  return tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('amber'),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SubscriptionLimitBlock(limits: limits, now: () => _now),
        ),
      ),
    ),
  );
}
