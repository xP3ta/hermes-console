import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// R4: a Cron create the server already accepted must never be reported as a
/// failed save nor leave the editor open for a second Save (a second POST
/// creates the job twice). The editor shows server text only for validation
/// rejections, bounded and on one line.
void main() {
  DashboardClient fakeServer({
    required void Function() onCreate,
    http.Response Function()? createResponse,
  }) {
    return DashboardClient(
      host: 'hermes.local',
      manualToken: 'synthetic-token',
      httpClientOverride: MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/api/cron/jobs') {
          return http.Response('[]', 200);
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
        if (path == '/api/model/options') {
          return http.Response(jsonEncode({'providers': []}), 200);
        }
        if (path == '/api/cron/blueprints') {
          return http.Response(jsonEncode({'blueprints': []}), 200);
        }
        if (request.method == 'POST' && path == '/api/cron/jobs') {
          onCreate();
          if (createResponse != null) return createResponse();
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'created-1',
              'prompt': body['prompt'],
              'schedule': body['schedule'],
              'deliver': body['deliver'],
              'enabled': true,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
  }

  Future<void> pumpCron(
    WidgetTester tester,
    DashboardClient client, {
    CronPolicyWriter? policyWriter,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
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
            id: 'cron-r4',
            label: 'QA',
            host: 'hermes.local',
            port: 8642,
            apiKey: 'synthetic-key',
            useHttps: true,
          ),
          clientOverride: client,
          cronPolicyWriterOverride: policyWriter,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fillAndSave(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'New task'));
    await tester.pumpAndSettle();
    final promptField = find.descendant(
      of: find.byKey(const ValueKey('cron-prompt-field')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(promptField, 'Summarize the day');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cron-editor-submit')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'accepted create + failing local policy write: one POST, editor closed, '
    'no failed-save report',
    (tester) async {
      var posts = 0;
      var policyWrites = 0;
      await pumpCron(
        tester,
        fakeServer(onCreate: () => posts++),
        policyWriter:
            ({
              required connId,
              required profile,
              required jobId,
              required policy,
            }) async {
              policyWrites++;
              throw StateError('synthetic local storage failure');
            },
      );
      await fillAndSave(tester);

      expect(posts, 1);
      expect(policyWrites, 1);
      // The editor is gone, so there is no second Save that would POST again.
      expect(find.byKey(const ValueKey('cron-editor-submit')), findsNothing);
      // Not reported as a failed creation.
      expect(find.textContaining('Failed to add job'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'control: accepted create + successful policy write closes once',
    (tester) async {
      var posts = 0;
      var policyWrites = 0;
      await pumpCron(
        tester,
        fakeServer(onCreate: () => posts++),
        policyWriter:
            ({
              required connId,
              required profile,
              required jobId,
              required policy,
            }) async {
              policyWrites++;
              expect(jobId, 'created-1');
            },
      );
      await fillAndSave(tester);
      expect(posts, 1);
      expect(policyWrites, 1);
      expect(find.byKey(const ValueKey('cron-editor-submit')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('control: a rejected create keeps the editor open for a retry', (
    tester,
  ) async {
    var posts = 0;
    await pumpCron(
      tester,
      fakeServer(
        onCreate: () => posts++,
        createResponse: () =>
            http.Response(jsonEncode({'detail': 'Invalid schedule'}), 422),
      ),
      policyWriter:
          ({
            required connId,
            required profile,
            required jobId,
            required policy,
          }) async => fail('no policy write for a rejected create'),
    );
    await fillAndSave(tester);
    expect(posts, 1);
    expect(find.byKey(const ValueKey('cron-editor-submit')), findsOneWidget);
    expect(find.textContaining('Invalid schedule'), findsNothing);
    expect(find.byKey(const ValueKey('cron-editor-error')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor error text never shows the server body, any status', (
    tester,
  ) async {
    late Strings s;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Builder(
          builder: (context) {
            s = Strings.of(context);
            return const SizedBox();
          },
        ),
      ),
    );

    const canary = 'SYNTHETIC_CANARY /srv/hermes/secret_path.py';
    final bodies = <String>[
      jsonEncode({'detail': canary}),
      jsonEncode({'message': canary}),
      jsonEncode({'error': canary}),
      jsonEncode({
        'detail': [
          {
            'msg': canary,
            'loc': ['body', 'schedule'],
          },
        ],
      }),
      '<html><body><pre>$canary</pre></body></html>',
      canary,
    ];
    for (final status in [400, 401, 403, 404, 409, 422, 500, 502]) {
      for (final body in bodies) {
        final text = cronEditorErrorText(
          s,
          DashboardHttpException(status, body: body),
        );
        expect(
          text,
          isNot(contains('SYNTHETIC_CANARY')),
          reason: '$status $body',
        );
        expect(text, isNot(contains('/srv/hermes')), reason: '$status $body');
        expect(text.trim(), isNotEmpty, reason: '$status $body');
      }
    }
  });
}
