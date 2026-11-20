// Doctor and security audit from Settings › System: the page starts the
// action with the profile named, follows its status route and shows the lines
// as the server writes them, over a loopback stand-in of
// `/api/ops/doctor`, `/api/ops/security-audit` and `/api/actions/<name>/status`.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/server_check_screen.dart';
import 'package:hermes_android/core/services/action_follower.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Server {
  final requests = <http.Request>[];
  int startStatus = 200;
  int statusStatus = 200;

  /// What the status route answers, one answer per read.
  final reads = <Map<String, dynamic>>[
    {
      'running': true,
      'lines': ['checking install'],
    },
    {
      'running': true,
      'lines': ['checking install', 'checking providers'],
    },
    {
      'running': false,
      'exit_code': 0,
      'lines': ['checking install', 'checking providers', 'all good'],
    },
  ];
  int _read = 0;

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'POST' &&
        (path == '/api/ops/doctor' || path == '/api/ops/security-audit')) {
      if (startStatus != 200) return http.Response('{}', startStatus);
      return http.Response(
        jsonEncode({'name': path.split('/').last, 'pid': 4321}),
        200,
      );
    }
    if (request.method == 'GET' && path.startsWith('/api/actions/')) {
      if (statusStatus != 200) return http.Response('{}', statusStatus);
      final answer = reads[_read < reads.length ? _read : reads.length - 1];
      _read += 1;
      return http.Response(jsonEncode(answer), 200);
    }
    return http.Response('{}', 404);
  }

  List<String> calls() => [
    for (final request in requests)
      '${request.method} ${request.url.path}'
          '${request.url.hasQuery ? '?${request.url.query}' : ''}',
  ];
}

final _connection = SavedConnection(
  id: 'check-test',
  label: 'QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: '',
);

FilledButton _runButton(WidgetTester tester) => tester.widget<FilledButton>(
  find.descendant(
    of: find.byKey(const ValueKey('server-check-run')),
    matching: find.byType(FilledButton),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_Server> open(
    WidgetTester tester,
    ServerCheck check, {
    _Server? server,
    Future<void> Function(Duration)? delay,
  }) async {
    final fake = server ?? _Server();
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'token',
      httpClientOverride: MockClient(fake.handle),
    );
    addTearDown(dashboard.close);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: ServerCheckScreen(
          check: check,
          connection: _connection,
          profile: 'research',
          client: dashboard,
          followerFor: (read) => ActionFollower(
            read: read,
            delay: delay ?? (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fake;
  }

  testWidgets('nothing is requested until Run is pressed', (tester) async {
    final server = await open(tester, ServerCheck.doctor);
    expect(server.requests, isEmpty);
    expect(
      find.text('Health-check the install, config, and providers'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('server-check-log')), findsNothing);
  });

  testWidgets('doctor starts for the profile and shows the log it follows', (
    tester,
  ) async {
    final server = await open(tester, ServerCheck.doctor);
    await tester.tap(find.byKey(const ValueKey('server-check-run')));
    await tester.pumpAndSettle();

    expect(server.calls().first, 'POST /api/ops/doctor?profile=research');
    expect(server.requests.first.body, '{}');
    expect(server.calls().skip(1).toSet(), {'GET /api/actions/doctor/status'});
    expect(server.calls().length, 4);
    expect(
      tester
          .widget<SelectableText>(
            find.descendant(
              of: find.byKey(const ValueKey('server-check-log')),
              matching: find.byType(SelectableText),
            ),
          )
          .data,
      'checking install\nchecking providers\nall good',
    );
    expect(find.byKey(const ValueKey('server-check-running')), findsNothing);
    expect(find.text('Finished'), findsOneWidget);
  });

  testWidgets('the security audit uses its own route and action', (
    tester,
  ) async {
    final server = await open(tester, ServerCheck.securityAudit);
    await tester.tap(find.byKey(const ValueKey('server-check-run')));
    await tester.pumpAndSettle();
    expect(
      server.calls().first,
      'POST /api/ops/security-audit?profile=research',
    );
    expect(server.calls().skip(1).toSet(), {
      'GET /api/actions/security-audit/status',
    });
  });

  testWidgets('a failing exit code is shown and Run is available again', (
    tester,
  ) async {
    final server = _Server();
    server.reads
      ..clear()
      ..add({
        'running': false,
        'exit_code': 2,
        'lines': ['1 warning'],
      });
    await open(tester, ServerCheck.doctor, server: server);
    await tester.tap(find.byKey(const ValueKey('server-check-run')));
    await tester.pumpAndSettle();
    expect(find.text('Finished with exit code 2'), findsOneWidget);
    expect(_runButton(tester).onPressed, isNotNull);
  });

  testWidgets('Run is disabled while the action goes on', (tester) async {
    final gate = Completer<void>();
    final server = await open(
      tester,
      ServerCheck.doctor,
      delay: (_) => gate.future,
    );
    await tester.tap(find.byKey(const ValueKey('server-check-run')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('server-check-running')), findsOneWidget);
    expect(_runButton(tester).onPressed, isNull);
    // A second tap while it runs starts nothing more.
    await tester.tap(find.byKey(const ValueKey('server-check-run')));
    await tester.pump();
    expect(
      server.calls().where((call) => call.startsWith('POST')),
      hasLength(1),
    );
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('server-check-running')), findsNothing);
    expect(_runButton(tester).onPressed, isNotNull);
  });

  testWidgets('a server without the route says so', (tester) async {
    final server = await open(
      tester,
      ServerCheck.doctor,
      server: _Server()..startStatus = 404,
    );
    await tester.tap(find.byKey(const ValueKey('server-check-run')));
    await tester.pumpAndSettle();
    expect(find.text('This server cannot run it.'), findsOneWidget);
    expect(server.calls(), ['POST /api/ops/doctor?profile=research']);
  });

  testWidgets('a status route that fails stops the tail with a note', (
    tester,
  ) async {
    await open(
      tester,
      ServerCheck.doctor,
      server: _Server()..statusStatus = 500,
    );
    await tester.tap(find.byKey(const ValueKey('server-check-run')));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not follow the run. Run it again to see its output.'),
      findsOneWidget,
    );
  });
}
