// The editor's missed-run choice (`catch_up`), as Desktop's CatchUpField:
// sent on create only when it is not the default, and on edit only when the
// user changed it (null puts the job back on the server default).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Server {
  final List<Map<String, dynamic>> jobs;
  final posts = <Map<String, dynamic>>[];
  final updates = <Map<String, dynamic>>[];

  _Server(this.jobs);

  DashboardClient client() => DashboardClient(
    host: 'hermes.local',
    manualToken: 'token',
    httpClientOverride: MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path == '/api/cron/jobs') {
        return http.Response(jsonEncode(jobs), 200);
      }
      if (request.method == 'POST' && path == '/api/cron/jobs') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        posts.add(body);
        final created = {
          'id': 'created-${posts.length}',
          'enabled': true,
          ...body,
        };
        jobs.add(created);
        return http.Response(jsonEncode(created), 200);
      }
      if (request.method == 'PUT' && path == '/api/cron/jobs/job1') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final changes = body['updates'] as Map<String, dynamic>;
        updates.add(changes);
        jobs[0] = {...jobs[0], ...changes};
        return http.Response(jsonEncode(jobs[0]), 200);
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

Future<void> _pump(WidgetTester tester, _Server server) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: CronScreen(
        connection: SavedConnection(
          id: 'cron-catch-up',
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
}

final _row = find.byKey(const ValueKey('cron-catch-up-row'));

Future<void> _choose(WidgetTester tester, String choice) async {
  await tester.ensureVisible(_row);
  await tester.tap(_row);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('cron-catch-up-$choice')));
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('cron-editor-submit')));
  await tester.pumpAndSettle();
}

Future<void> _openEditor(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('cron-job-menu-job1')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit'));
  await tester.pumpAndSettle();
}

Finder _rowShows(String label) =>
    find.descendant(of: _row, matching: find.text(label));

void main() {
  testWidgets('a new task sends the missed-run choice only when one is '
      'picked', (tester) async {
    final server = _Server([]);
    await _pump(tester, server);

    Future<void> create(String prompt, {String? choice}) async {
      await tester.tap(find.byKey(const ValueKey('cron-create')));
      await tester.pumpAndSettle();
      expect(_rowShows('Use the default'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('cron-prompt-field')),
          matching: find.byType(EditableText),
        ),
        prompt,
      );
      await tester.pump();
      if (choice != null) await _choose(tester, choice);
      await _submit(tester);
    }

    await create('Summarise the day', choice: 'skip');
    expect(server.posts.single['catch_up'], isFalse);

    await create('Back up the notes');
    expect(server.posts, hasLength(2));
    expect(server.posts.last.containsKey('catch_up'), isFalse);
  });

  testWidgets('an edit leaves an untouched policy alone and sends null to go '
      'back to the default', (tester) async {
    final server = _Server([
      {
        'id': 'job1',
        'name': 'Nightly digest',
        'prompt': 'Summarise the day',
        'schedule': {'kind': 'cron', 'expr': '0 21 * * *'},
        'enabled': true,
        'deliver': 'local',
        'catch_up': true,
      },
    ]);
    await _pump(tester, server);

    await _openEditor(tester);
    expect(_rowShows('Run once when back'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('cron-name-field')),
        matching: find.byType(EditableText),
      ),
      'Evening digest',
    );
    await tester.pump();
    await _submit(tester);
    expect(server.updates.single['name'], 'Evening digest');
    expect(server.updates.single.containsKey('catch_up'), isFalse);

    await _openEditor(tester);
    expect(_rowShows('Run once when back'), findsOneWidget);
    await _choose(tester, 'serverDefault');
    expect(_rowShows('Use the default'), findsOneWidget);
    await _submit(tester);
    expect(server.updates, hasLength(2));
    expect(server.updates.last.containsKey('catch_up'), isTrue);
    expect(server.updates.last['catch_up'], isNull);

    await _openEditor(tester);
    expect(_rowShows('Use the default'), findsOneWidget);
  });
}
