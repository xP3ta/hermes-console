import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/screens/task_center_screen.dart';
import 'package:hermes_android/core/screens/runs_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/run_registry.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  for (final result in ['accepted', '401', '404', '500', 'timeout']) {
    testWidgets('localhost FAB composer launch official owner: $result', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final connection = SavedConnection(
        id: 'existing',
        label: 'Existing',
        host: '127.0.0.1',
        port: 9131,
        apiKey: 'synthetic-gateway-key',
        kind: InstanceKind.localhost,
      );
      final before = connection.toMap();
      final hits = <http.Request>[];
      final client = MockClient((request) async {
        hits.add(request);
        if (request.url.path == '/p/work_bot/v1/runs' &&
            request.method == 'POST') {
          if (result == 'timeout') throw TimeoutException('synthetic timeout');
          return http.Response(
            result == 'accepted' ? '{"run_id":"official-run-1"}' : '{}',
            result == 'accepted' ? 200 : int.parse(result),
          );
        }
        if (request.url.path.endsWith('/events')) {
          return http.Response(
            '',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        if (request.url.path.endsWith('/official-run-1')) {
          return http.Response(
            '{"status":"completed","output":"Official result"}',
            200,
          );
        }
        return http.Response('{}', 404);
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.hermesRedDark,
            locale: const Locale('en'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: TaskCenterScreen(connection: connection, profile: 'work_bot'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('runs-create')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('run-composer-surface')),
          findsOneWidget,
        );
        await tester.enterText(
          find.byType(TextField).first,
          'Synthetic instruction',
        );
        final launch = find.text(
          Strings.of(
            tester.element(find.byType(TextField).first),
          ).runComposerLaunch,
        );
        await tester.ensureVisible(launch);
        await tester.tap(launch);
        await tester.pumpAndSettle();
        final starts = hits
            .where(
              (r) => r.method == 'POST' && r.url.path == '/p/work_bot/v1/runs',
            )
            .toList();
        expect(starts, hasLength(1));
        expect(starts.single.url.port, 9131);
        expect(
          starts.single.headers['Authorization'],
          'Bearer synthetic-gateway-key',
        );
        expect(
          jsonDecode(starts.single.body)['input'],
          'Synthetic instruction',
        );
        expect(hits.where((r) => r.url.path.startsWith('/bridge/')), isEmpty);
        final registry = await RunRegistry.load(
          await SharedPreferences.getInstance(),
          connection.id,
        );
        if (result == 'accepted') {
          expect(find.byType(RunDetailScreen), findsOneWidget);
          expect(registry.records.single.runId, 'official-run-1');
          expect(registry.records.single.profile, 'work_bot');
          expect(find.textContaining('Official result'), findsWidgets);
        } else {
          expect(find.byType(RunDetailScreen), findsNothing);
          expect(registry.records, isEmpty);
          expect(
            find.textContaining(
              result == 'timeout' ? 'synthetic timeout' : result,
            ),
            findsWidgets,
          );
        }
        expect(connection.toMap(), before);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }, () => client);
    });
  }
}
