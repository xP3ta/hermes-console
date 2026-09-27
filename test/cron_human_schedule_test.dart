import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Three representative jobs, exactly as the Hermes dashboard serves them.
final _jobs = <Map<String, dynamic>>[
  {
    'id': 'radar',
    'name': '[bot:console-radar] Hourly issue and PR triage',
    'prompt': 'Act as Console Radar. Read-only.',
    'schedule': {'kind': 'interval', 'minutes': 60, 'display': 'every 60m'},
    'schedule_display': 'every 60m',
    'enabled': true,
    'state': 'scheduled',
    'deliver': 'bot-chat:console-radar',
    'profile': 'default',
    'next_run_at': '2099-01-05T19:05:00',
  },
  {
    'id': 'in',
    'name': '[bot:atlas] Morning check-in',
    'prompt': 'Check the current timetable every five minutes.',
    'schedule': {
      'kind': 'cron',
      'expr': '*/5 7-9 * * 1-5',
      'display': '*/5 7-9 * * 1-5',
    },
    'schedule_display': '*/5 7-9 * * 1-5',
    'enabled': true,
    'state': 'scheduled',
    'deliver': 'bot-chat:atlas',
    'profile': 'default',
    'next_run_at': '2099-01-05T07:00:00',
  },
  {
    'id': 'out',
    'name': '[bot:atlas] Evening wrap-up',
    'prompt': 'Check the current timetable every five minutes.',
    'schedule': {
      'kind': 'cron',
      'expr': '*/5 14-17 * * 1-5',
      'display': '*/5 14-17 * * 1-5',
    },
    'schedule_display': '*/5 14-17 * * 1-5',
    'enabled': true,
    'state': 'scheduled',
    'deliver': 'bot-chat:atlas',
    'profile': 'default',
    'next_run_at': '2099-01-05T14:00:00',
  },
];

/// Anything that looks like cron / interval syntax or a technical label.
final _technical = RegExp(
  r'\*/|\d-\d+ \*|\bevery \d+m\b|\[bot:|bot-chat|perfil:|profile:',
);

final _profiles = {
  'profiles': [
    {'name': 'default', 'is_default': true},
    {
      'name': 'console-radar',
      'ui_meta': {
        'hermes-bots': {'title': 'Radar', 'shape': 'round'},
      },
    },
    {'name': 'atlas'},
  ],
};

DashboardClient _client() => DashboardClient(
  host: 'hermes.local',
  manualToken: 'token',
  httpClientOverride: MockClient((request) async {
    final path = request.url.path;
    if (path == '/api/cron/jobs') {
      return http.Response(jsonEncode(_jobs), 200);
    }
    if (path == '/api/profiles') {
      return http.Response(jsonEncode(_profiles), 200);
    }
    for (final job in _jobs) {
      if (path == '/api/cron/jobs/${job['id']}') {
        return http.Response(jsonEncode(job), 200);
      }
      if (path == '/api/cron/jobs/${job['id']}/runs') {
        return http.Response(jsonEncode({'runs': []}), 200);
      }
    }
    return http.Response('{}', 404);
  }),
);

Future<void> _pump(WidgetTester tester, Locale locale) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: CronScreen(
        connection: SavedConnection(
          id: 'human',
          label: 'QA',
          host: 'hermes.local',
          port: 8642,
          apiKey: 'k',
          useHttps: true,
        ),
        clientOverride: _client(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<String> _visibleTexts(WidgetTester tester) => [
  for (final w in tester.widgetList<Text>(find.byType(Text)))
    w.data ?? w.textSpan?.toPlainText() ?? '',
  for (final w in tester.widgetList<RichText>(find.byType(RichText)))
    w.text.toPlainText(),
];

void _expectNoTechnicalText(WidgetTester tester) {
  for (final text in _visibleTexts(tester)) {
    expect(_technical.hasMatch(text), isFalse, reason: text);
  }
}

void main() {
  test('the model keeps the canonical schedule and strips the owner', () {
    final radar = CronJob.fromJson(_jobs[0]);
    expect(radar.scheduleExpression, 'every 60m');
    expect(radar.title, 'Hourly issue and PR triage');
    expect(radar.ownerBot, 'console-radar');
    final plain = CronJob.fromJson({..._jobs[2], 'name': 'Backup'});
    expect(plain.ownerBot, isNull);
    expect(plain.title, 'Backup');
  });

  test('run sessions drop the [bot:] prefix too', () {
    final session = Session.tryParse({
      'id': 'cron_abc_20260925_090051',
      'title': '[bot:product-scout] Vigilancia repos · Sep 25 09:04',
      'source': 'cron',
    })!;
    expect(session.displayTitle, 'Vigilancia repos · Sep 25 09:04');
  });

  testWidgets('list: human schedules, clean titles, owner faces (es)', (
    tester,
  ) async {
    await _pump(tester, const Locale('es'));
    expect(find.text('Evening wrap-up'), findsOneWidget);
    expect(find.text('Morning check-in'), findsOneWidget);
    expect(find.text('Hourly issue and PR triage'), findsOneWidget);
    expect(
      find.textContaining(
        'Cada 5 min, de 14:00 a 17:55, laborables',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Cada 5 min, de 7:00 a 9:55, laborables',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Cada hora', findRichText: true),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('cron-job-owner-out')), findsOneWidget);
    expect(find.textContaining('Radar ·'), findsOneWidget);
    expect(find.textContaining('Atlas ·'), findsNWidgets(2));
    // Human scope labels.
    expect(find.text('Este perfil'), findsOneWidget);
    expect(find.text('Todos'), findsOneWidget);
    _expectNoTechnicalText(tester);
  });

  for (final (id, title, es, en) in const [
    (
      'out',
      'Evening wrap-up',
      'Cada 5 min, de 14:00 a 17:55, laborables',
      'Every 5 min from 14:00 to 17:55 on weekdays',
    ),
    (
      'in',
      'Morning check-in',
      'Cada 5 min, de 7:00 a 9:55, laborables',
      'Every 5 min from 7:00 to 9:55 on weekdays',
    ),
    ('radar', 'Hourly issue and PR triage', 'Cada hora', 'Every hour'),
  ]) {
    testWidgets('detail of "$title" is human (es)', (tester) async {
      await _pump(tester, const Locale('es'));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('cron-detail-schedule')),
          matching: find.text(es),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('cron-detail-owner')), findsOneWidget);
      final bot = id == 'radar' ? 'Radar' : 'Atlas';
      expect(find.text('Rutina de $bot'), findsOneWidget);
      final delivery = find.byKey(const ValueKey('cron-detail-delivery'));
      await tester.ensureVisible(delivery);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: delivery, matching: find.text('Chat de $bot')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('cron-detail-profile')),
          matching: find.text('Default'),
        ),
        findsOneWidget,
      );
      expect(find.text('Perfil'), findsOneWidget);
      _expectNoTechnicalText(tester);

      // The builder opens on the real schedule, Advanced collapsed.
      final row = find.byKey(const ValueKey('cron-detail-schedule'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('schedule-builder')), findsOneWidget);
      expect(find.byKey(const ValueKey('schedule-cron-field')), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('schedule-summary')))
            .data,
        startsWith(es),
      );
      _expectNoTechnicalText(tester);
      await tester.tap(find.byKey(const ValueKey('schedule-cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('detail of "$title" is human (en)', (tester) async {
      await _pump(tester, const Locale('en'));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.text(en), findsOneWidget);
      final bot = id == 'radar' ? 'Radar' : 'Atlas';
      expect(find.text("$bot's routine"), findsOneWidget);
      _expectNoTechnicalText(tester);
    });
  }
}
