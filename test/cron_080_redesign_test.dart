import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _prompt =
    'Search today\'s news in Spain and send me a summary with the five most '
    'important headlines and a link to each one. Keep it short and skip '
    'sports. Group by topic: politics, economy, technology, culture and '
    'international. Add one sentence of context per headline. End with the '
    'weather in Madrid for tomorrow morning and evening.';

Map<String, dynamic> _job({String schedule = '30 18 * * 1-5'}) => {
  'id': 'news',
  'name': 'Daily news summary',
  'prompt': _prompt,
  'schedule': {'kind': 'cron', 'expr': schedule, 'display': schedule},
  'enabled': true,
  'state': 'scheduled',
  'deliver': 'local',
  'next_run_at': '2099-01-05T18:30:00',
};

class _Server {
  final requests = <http.Request>[];
  Map<String, dynamic> job = _job();

  DashboardClient client() => DashboardClient(
    host: 'hermes.local',
    manualToken: 'token',
    httpClientOverride: MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (request.method == 'GET' && path == '/api/cron/jobs') {
        return http.Response(jsonEncode([job]), 200);
      }
      if (request.method == 'GET' && path == '/api/cron/jobs/news') {
        return http.Response(jsonEncode(job), 200);
      }
      if (path == '/api/cron/jobs/news/runs') {
        return http.Response(jsonEncode({'runs': []}), 200);
      }
      if (request.method == 'PUT' && path == '/api/cron/jobs/news') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final updates = body['updates'] as Map<String, dynamic>;
        job = {...job, 'schedule': updates['schedule']};
        return http.Response(jsonEncode(job), 200);
      }
      if (path == '/api/cron/delivery-targets') {
        return http.Response(
          jsonEncode({
            'targets': [
              {'id': 'local', 'name': 'Local', 'home_target_set': true},
            ],
          }),
          200,
        );
      }
      if (path == '/api/model/options' || path == '/api/cron/blueprints') {
        return http.Response('{}', 200);
      }
      return http.Response('{}', 404);
    }),
  );
}

Future<_Server> _pump(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final server = _Server();
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: CronScreen(
        connection: SavedConnection(
          id: 'cron-080',
          label: 'QA',
          host: 'hermes.local',
          port: 8642,
          apiKey: 'k',
          useHttps: true,
        ),
        clientOverride: server.client(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return server;
}

void main() {
  testWidgets('list row: inline status + real schedule, no boxed pill', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Daily news summary'), findsOneWidget);
    expect(
      find.textContaining('Weekdays at 18:30', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('SCHEDULED'), findsNothing);
    expect(find.text('Every day at 9:00'), findsNothing);
  });

  testWidgets('detail is a page with one scroll and the mock sections', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('Daily news summary'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cron-job-detail')), findsOneWidget);
    // Page, not a floating card.
    expect(find.byKey(const ValueKey('cron-job-detail-surface')), findsNothing);
    expect(find.byKey(const ValueKey('cron-detail-run')), findsOneWidget);
    expect(find.byKey(const ValueKey('cron-detail-pause')), findsOneWidget);
    for (final header in const ['WHEN', 'WHAT IT DOES', 'NOTIFICATIONS']) {
      expect(find.text(header), findsOneWidget, reason: header);
    }
    expect(find.text('Weekdays at 18:30'), findsOneWidget);
    expect(find.text('Notify me when it finishes'), findsOneWidget);
    expect(find.text('Only if it fails'), findsOneWidget);
    expect(find.text('Show all'), findsOneWidget);
    // Exactly one vertical scrollable on the detail route.
    final vertical = tester
        .widgetList<Scrollable>(find.byType(Scrollable))
        .where((s) => axisDirectionToAxis(s.axisDirection) == Axis.vertical);
    expect(vertical, hasLength(1));
  });

  testWidgets('editing the schedule from the detail opens the builder', (
    tester,
  ) async {
    final server = await _pump(tester);
    await tester.tap(find.text('Daily news summary'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cron-detail-schedule')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('schedule-builder')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('schedule-day-6')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('schedule-apply')));
    await tester.pumpAndSettle();
    final put = server.requests.where((r) => r.method == 'PUT').single;
    expect(jsonDecode(put.body)['updates']['schedule'], '30 18 * * 1-6');
    expect(find.text('Monday to Saturday at 18:30'), findsOneWidget);
  });

  testWidgets('new job: builder instead of cron syntax; payload carries it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    await _pump(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cron-editor')), findsOneWidget);
    expect(find.text('Every day at 9:00'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.tap(find.byKey(const ValueKey('cron-schedule-row')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cron-editor')), findsOneWidget);
  });

  testWidgets('Spanish detail copy', (tester) async {
    await _pump(tester, locale: const Locale('es'));
    await tester.tap(find.text('Daily news summary'));
    await tester.pumpAndSettle();
    expect(find.text('Laborables a las 18:30'), findsOneWidget);
    expect(find.text('Notificarme al terminar'), findsOneWidget);
    expect(find.text('Solo si falla'), findsOneWidget);
    expect(find.text('QUÉ HACE'), findsOneWidget);
  });

  for (final size in const [Size(360, 800), Size(390, 844)]) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      testWidgets('list + detail + editor fit at $size ×$scale', (
        tester,
      ) async {
        await _pump(tester, size: size, scale: scale);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Daily news summary'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // Primary CTA is in the first viewport.
        final run = tester.getRect(
          find.byKey(const ValueKey('cron-detail-run')),
        );
        expect(run.bottom, lessThanOrEqualTo(size.height));
        expect(run.height, greaterThanOrEqualTo(48));
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
