// Usage: the analytics answer, the request it makes and the screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/usage_analytics_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/usage/usage_analytics.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _answer({
  double actual = 0,
  double estimated = 0.1234,
  int sessions = 7,
}) => {
  'period_days': 30,
  'daily': [
    {'day': '2026-10-30', 'input_tokens': 1000, 'output_tokens': 500},
    {'day': '2026-10-31', 'input_tokens': 3000, 'output_tokens': 1500},
    {'day': '2026-11-01', 'input_tokens': null, 'output_tokens': null},
  ],
  'by_model': [
    {
      'model': 'alpha-1',
      'input_tokens': 3000,
      'output_tokens': 1000,
      'estimated_cost': 0.1,
      'sessions': 4,
    },
    {
      'model': 'beta-2',
      'input_tokens': 1000,
      'output_tokens': 1000,
      'estimated_cost': 0.02,
      'sessions': 3,
    },
    {'model': null, 'input_tokens': null, 'output_tokens': null},
  ],
  'totals': {
    'total_input': 4000,
    'total_output': 2000,
    'total_sessions': sessions,
    'total_api_calls': 12,
    'total_estimated_cost': estimated,
    'total_actual_cost': actual,
  },
};

class _FakeUsage extends DashboardClient {
  _FakeUsage()
    : super(
        host: 'usage.example.test',
        manualToken: 'token',
        httpClientOverride: MockClient((_) async => http.Response('{}', 500)),
      );

  final endpoints = <String>[];
  Object? error;
  Map<String, dynamic> Function(int days)? answer;

  @override
  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    bool retried = false,
  }) async {
    endpoints.add(endpoint);
    final failure = error;
    if (failure != null) throw failure;
    final days = int.parse(
      Uri.parse('x:?${endpoint.split('?').last}').queryParameters['days']!,
    );
    return (answer ?? (_) => _answer())(days);
  }
}

SavedConnection get _connection => SavedConnection(
  id: 'usage',
  label: 'QA',
  host: 'usage.example.test',
  port: 8642,
  apiKey: '',
  useHttps: true,
);

Future<void> _pump(
  WidgetTester tester,
  _FakeUsage client, {
  String profile = '',
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: UsageAnalyticsScreen(
        connection: _connection,
        profile: profile,
        clientOverride: client,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('parse', () {
    test('reads totals, models and days; nulls are zero', () {
      final usage = parseUsageAnalytics(_answer());
      expect(usage.totals.tokens, 6000);
      expect(usage.totals.inputTokens, 4000);
      expect(usage.totals.sessions, 7);
      expect(usage.models.map((m) => m.model), [
        'alpha-1',
        'beta-2',
        'unknown',
      ]);
      expect(usage.models.last.tokens, 0);
      expect(usage.days.map((d) => d.tokens), [1500, 4500, 0]);
      expect(usage.isEmpty, isFalse);
    });

    test('an answer made of nulls is empty and does not throw', () {
      final usage = parseUsageAnalytics({
        'daily': <dynamic>[],
        'by_model': <dynamic>[],
        'totals': {
          'total_input': null,
          'total_output': null,
          'total_sessions': 0,
          'total_estimated_cost': 0,
          'total_actual_cost': 0,
        },
      }, fallbackDays: 7);
      expect(usage.isEmpty, isTrue);
      expect(usage.periodDays, 7);
      expect(parseUsageAnalytics(const {}).isEmpty, isTrue);
    });

    test('cost: the real one wins, an estimate is flagged, none is hidden', () {
      expect(parseUsageAnalytics(_answer(actual: 0.5)).totals.cost, 0.5);
      expect(
        parseUsageAnalytics(_answer(actual: 0.5)).totals.costIsEstimate,
        isFalse,
      );
      final estimated = parseUsageAnalytics(_answer()).totals;
      expect(estimated.cost, 0.1234);
      expect(estimated.costIsEstimate, isTrue);
      expect(parseUsageAnalytics(_answer(estimated: 0)).totals.cost, 0);
    });

    test('formatting', () {
      expect(formatCompactCount(0), '0');
      expect(formatCompactCount(999), '999');
      expect(formatCompactCount(1200), '1.2k');
      expect(formatCompactCount(1000), '1k');
      expect(formatCompactCount(250000), '250k');
      expect(formatCompactCount(3400000), '3.4M');
      expect(formatCompactCount(2100000000), '2.1B');
      expect(formatUsageCost(1.234), '\$1.23');
      expect(formatUsageCost(0.004), '\$0.0040');
    });
  });

  group('request', () {
    test(
      'asks for the period and, for a secondary profile, the profile',
      () async {
        final client = _FakeUsage();
        await fetchUsageAnalytics(client, days: 7);
        await fetchUsageAnalytics(client, days: 90, profile: 'work');
        await fetchUsageAnalytics(client, days: 30, profile: 'default');
        expect(client.endpoints, [
          'analytics/usage?days=7',
          'analytics/usage?days=90&profile=work',
          'analytics/usage?days=30',
        ]);
      },
    );
  });

  group('screen', () {
    testWidgets('shows totals, the days and the models', (tester) async {
      final client = _FakeUsage();
      await _pump(tester, client);
      final s = await Strings.delegate.load(const Locale('es'));

      expect(client.endpoints, ['analytics/usage?days=30']);
      expect(find.text(s.kluUsageTokens), findsOneWidget);
      expect(find.text('6k'), findsOneWidget);
      expect(find.text('4k'), findsWidgets);
      expect(find.text('7'), findsOneWidget);
      expect(find.text(s.kluUsageCostEstimated), findsOneWidget);
      expect(find.text('\$0.12'), findsOneWidget);
      expect(find.byKey(const ValueKey('usage-daily')), findsOneWidget);
      expect(find.text('alpha-1'), findsOneWidget);
      expect(find.text(s.kluUsageSessionsCount(4)), findsOneWidget);
    });

    testWidgets('a secondary profile is asked for', (tester) async {
      final client = _FakeUsage();
      await _pump(tester, client, profile: 'work');
      expect(client.endpoints.single, 'analytics/usage?days=30&profile=work');
    });

    testWidgets('the period buttons read 7, 30 and 90 days', (tester) async {
      final client = _FakeUsage();
      await _pump(tester, client);
      await tester.tap(find.byKey(const ValueKey('usage-period-7')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('usage-period-90')));
      await tester.pumpAndSettle();
      expect(client.endpoints, [
        'analytics/usage?days=30',
        'analytics/usage?days=7',
        'analytics/usage?days=90',
      ]);
      // Choosing the period already shown reads nothing.
      await tester.tap(find.byKey(const ValueKey('usage-period-90')));
      await tester.pumpAndSettle();
      expect(client.endpoints, hasLength(3));
    });

    testWidgets(
      'the period buttons are 48 dp targets and say which is chosen',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, _FakeUsage());
        for (final days in kUsagePeriods) {
          final size = tester.getSize(
            find.byKey(ValueKey('usage-period-$days')),
          );
          expect(size.height, greaterThanOrEqualTo(48));
        }
        final chosen = tester.getSemantics(
          find.byKey(const ValueKey('usage-period-30')),
        );
        expect(chosen, isSemantics(isSelected: true));
        handle.dispose();
      },
    );

    testWidgets('no cost card when the server gives no cost', (tester) async {
      final client = _FakeUsage()..answer = (_) => _answer(estimated: 0);
      await _pump(tester, client);
      final s = await Strings.delegate.load(const Locale('es'));
      expect(find.text(s.kluUsageCostEstimated), findsNothing);
      expect(find.text(s.kluUsageCost), findsNothing);
    });

    testWidgets('the real cost is not called an estimate', (tester) async {
      final client = _FakeUsage()..answer = (_) => _answer(actual: 2.5);
      await _pump(tester, client);
      final s = await Strings.delegate.load(const Locale('es'));
      expect(find.text(s.kluUsageCost), findsOneWidget);
      expect(find.text('\$2.50'), findsOneWidget);
    });

    testWidgets('empty period', (tester) async {
      final client = _FakeUsage()
        ..answer = (_) => {
          'daily': <dynamic>[],
          'by_model': <dynamic>[],
          'totals': {'total_input': null, 'total_sessions': 0},
        };
      await _pump(tester, client);
      expect(
        find.text(
          (await Strings.delegate.load(const Locale('es'))).kluUsageEmpty,
        ),
        findsOneWidget,
      );
    });

    testWidgets('an error says so and a refresh reads again', (tester) async {
      final client = _FakeUsage()..error = const DashboardHttpException(500);
      await _pump(tester, client);
      final s = await Strings.delegate.load(const Locale('es'));
      expect(find.text(s.kluUsageLoadError), findsOneWidget);
      expect(find.text(s.apiErrorServer), findsOneWidget);
    });

    testWidgets('a server without the route says it is not offered', (
      tester,
    ) async {
      final client = _FakeUsage()..error = const DashboardHttpException(404);
      await _pump(tester, client);
      final s = await Strings.delegate.load(const Locale('es'));
      expect(find.text(s.kluUsageUnsupported), findsOneWidget);
    });

    testWidgets('twice the text size does not overflow', (tester) async {
      await _pump(tester, _FakeUsage(), scale: 2);
      expect(tester.takeException(), isNull);
    });
  });
}
