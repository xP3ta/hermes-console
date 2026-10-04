// Settings › Advanced › Diagnostics: read-only server state. Nothing is read
// when Settings opens; Advanced probes three cheap routes to decide whether
// the Diagnostics row exists; Diagnostics reads each section once, follows
// doctor and the audit only after a tap and only while on show.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/server_diagnostics_models.dart';
import 'package:hermes_android/core/screens/advanced_settings_screen.dart';
import 'package:hermes_android/core/screens/server_diagnostics_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_restart_signal.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_pill.dart' show TuiLoader;
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'capabilities/capabilities_fakes.dart';

const _host = 'hermes.example.test';

Map<String, dynamic> _status({
  bool running = false,
  int? exitCode,
  List<String> lines = const [],
  String name = 'doctor',
}) => {'name': name, 'running': running, 'exit_code': exitCode, 'lines': lines};

Map<String, dynamic> _usage(int days, {int sessions = 3, int input = 1200}) => {
  'daily': [
    {'day': '2026-10-03', 'input_tokens': input, 'sessions': sessions},
  ],
  'by_model': [
    {
      'model': 'model-a',
      'input_tokens': input,
      'output_tokens': 40,
      'estimated_cost': 0.5,
      'sessions': sessions,
    },
  ],
  'totals': {
    'total_input': input,
    'total_output': 40,
    'total_cache_read': null,
    'total_reasoning': null,
    'total_estimated_cost': 0.5,
    'total_actual_cost': null,
    'total_sessions': sessions,
    'total_api_calls': 8,
  },
  'period_days': days,
};

ScriptedRest _server() => ScriptedRest()
  ..gets['health'] = {
    'ok': true,
    'version': '0.20.1',
    'displayVersion': 'v0.20.1',
  }
  ..gets['health/idle'] = {
    'ok': true,
    'idle': false,
    'reason': 'turn_in_flight',
  }
  ..gets['actions/doctor/status'] = _status(exitCode: 0)
  ..gets['actions/security-audit/status'] = _status(
    name: 'security-audit',
    exitCode: 0,
  )
  ..gets['analytics/usage?days=30'] = _usage(30)
  ..gets['analytics/usage?days=7'] = _usage(7, sessions: 1, input: 77)
  ..posts['ops/doctor'] = {'ok': true, 'name': 'doctor'}
  ..posts['ops/security-audit'] = {'ok': true, 'name': 'security-audit'};

SavedConnection _connection() => SavedConnection(
  id: 'conn-sd1215',
  label: 'Diag QA',
  host: _host,
  port: 8642,
  apiKey: 'k',
  kind: InstanceKind.vps,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ConnectionManager manager;
  final copied = <String>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ServerRestartSignals.resetForTesting();
    copied.clear();
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  CapabilitiesRepository Function(String) repos(
    ScriptedRest rest, {
    Future<void> Function(Duration)? sleep,
  }) =>
      (profile) => CapabilitiesRepository(
        rest: rest,
        profile: profile,
        sleep: sleep ?? (_) async {},
        actionPollInterval: Duration.zero,
      );

  Future<void> pumpApp(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1170, 4200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: home,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> pumpDiagnostics(
    WidgetTester tester,
    ScriptedRest rest, {
    Future<List<McpServerStatus>?> Function(CapabilitiesRepository repo)? mcp,
    Future<void> Function(Duration)? sleep,
  }) => pumpApp(
    tester,
    ServerDiagnosticsScreen(
      connection: _connection(),
      connManager: manager,
      repositoryFor: repos(rest, sleep: sleep),
      mcpReader: mcp ?? (_) async => const [],
    ),
  );

  int count(ScriptedRest rest, String prefix) =>
      rest.calls.where((c) => c.startsWith(prefix)).length;

  Strings strings(WidgetTester tester) =>
      Strings.of(tester.element(find.byType(Scaffold).first));

  group('Advanced', () {
    Future<void> pumpAdvanced(WidgetTester tester, ScriptedRest rest) =>
        pumpApp(
          tester,
          AdvancedSettingsScreen(
            connection: _connection(),
            connManager: manager,
            repositoryFor: repos(rest),
            mcpReader: (_) async => const [],
          ),
        );

    testWidgets('probes three cheap reads and shows the Diagnostics row', (
      tester,
    ) async {
      final rest = _server();
      await pumpAdvanced(tester, rest);

      expect(find.text(strings(tester).sd1215Diagnostics), findsOneWidget);
      expect(rest.calls, [
        'GET actions/doctor/status?lines=200',
        'GET actions/security-audit/status?lines=200',
        'GET health',
      ]);
      expect(rest.mutations, isEmpty);
    });

    testWidgets('a server with none of them has no Diagnostics row', (
      tester,
    ) async {
      await pumpAdvanced(tester, ScriptedRest());
      final s = strings(tester);
      expect(find.text(s.sd1215Diagnostics), findsNothing);
      expect(find.text(s.sd1215NothingToShow), findsOneWidget);
    });

    testWidgets('an unreachable dashboard ends the probe and keeps the row', (
      tester,
    ) async {
      final rest = ScriptedRest()
        ..gets['actions/doctor/status'] = Exception('Dashboard not accessible')
        ..gets['actions/security-audit/status'] = Exception('unreachable')
        ..gets['health'] = Exception('unreachable');
      await pumpAdvanced(tester, rest);

      final s = strings(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(TuiLoader), findsNothing);
      // Unreachable proves nothing about support, like a 5xx: Diagnostics
      // itself reports the sections as unavailable.
      expect(find.text(s.sd1215Diagnostics), findsOneWidget);
      expect(find.text(s.sd1215NothingToShow), findsNothing);
    });

    testWidgets('one route is enough to keep the row', (tester) async {
      final rest = ScriptedRest()
        ..gets['health'] = {'ok': true, 'version': '1'};
      await pumpAdvanced(tester, rest);
      expect(find.text(strings(tester).sd1215Diagnostics), findsOneWidget);
    });

    testWidgets('opening Diagnostics does not probe health again', (
      tester,
    ) async {
      final rest = _server();
      await pumpAdvanced(tester, rest);
      await tester.tap(find.text(strings(tester).sd1215Diagnostics));
      await tester.pumpAndSettle();

      expect(count(rest, 'GET health'), 2, reason: 'probe + idle, no repeat');
      expect(find.text('v0.20.1'), findsOneWidget);
    });
  });

  group('Diagnostics', () {
    testWidgets('shows every section the server has', (tester) async {
      final rest = _server();
      await pumpDiagnostics(tester, rest);
      final s = strings(tester);

      expect(find.text(s.sd1215Doctor), findsOneWidget);
      expect(find.text(s.sd1215Audit), findsOneWidget);
      expect(find.text(s.sd1215Mcp), findsOneWidget);
      expect(find.text(s.sd1215Server), findsOneWidget);
      expect(find.text(s.sd1215Usage), findsOneWidget);
      expect(find.text('v0.20.1'), findsOneWidget);
      expect(find.text(s.sd1215ServerBusy), findsOneWidget);
    });

    testWidgets('opening reads and runs nothing', (tester) async {
      final rest = _server();
      await pumpDiagnostics(tester, rest);
      expect(rest.mutations, isEmpty);
      expect(count(rest, 'GET actions/'), 0);
    });

    testWidgets('idle null reads as unknown, idle true as free', (
      tester,
    ) async {
      final rest = _server()
        ..gets['health/idle'] = {
          'ok': true,
          'idle': null,
          'reason': 'turn_probe_unavailable',
        };
      await pumpDiagnostics(tester, rest);
      expect(find.text(strings(tester).sd1215ServerUnknown), findsOneWidget);
    });

    testWidgets('a server with only some routes shows only those', (
      tester,
    ) async {
      final rest = ScriptedRest()
        ..gets['health'] = {'ok': true, 'version': '1.0'};
      await pumpDiagnostics(tester, rest);
      final s = strings(tester);
      expect(find.text(s.sd1215Server), findsOneWidget);
      expect(find.text(s.sd1215Usage), findsNothing);
    });

    testWidgets('the restart note shows once the model call reported it', (
      tester,
    ) async {
      ServerRestartSignals.noteRpc(_host, 5098, 'Restart required: old code');
      final rest = _server();
      await pumpDiagnostics(tester, rest);
      final s = strings(tester);
      expect(find.text(s.sd1215RestartRequired), findsOneWidget);
      expect(find.textContaining('Restart required: old code'), findsOneWidget);
    });

    testWidgets('no restart note without a report', (tester) async {
      await pumpDiagnostics(tester, _server());
      expect(find.text(strings(tester).sd1215RestartRequired), findsNothing);
    });
  });

  group('doctor and audit', () {
    testWidgets('Run with a run in progress posts nothing and shows its '
        'output', (tester) async {
      final rest = _server();
      rest.statusQueue.addAll([
        _status(
          running: true,
          lines: ['=== doctor started t ===', 'checking config'],
        ),
        _status(
          running: true,
          lines: [
            '=== doctor started t ===',
            'checking config',
            'checking git',
          ],
        ),
        _status(
          exitCode: 0,
          lines: [
            '=== doctor started t ===',
            'checking config',
            'checking git',
            'all good',
          ],
        ),
      ]);
      await pumpDiagnostics(tester, rest);
      await tester.tap(find.byKey(const ValueKey('sd1215-run-doctor')));
      await tester.pumpAndSettle();

      expect(rest.mutations, isEmpty);
      expect(find.textContaining('all good'), findsOneWidget);
      expect(find.text(strings(tester).sd1215NoIssues), findsOneWidget);
    });

    testWidgets('the output starts after the last started marker', (
      tester,
    ) async {
      final rest = _server();
      rest.statusQueue.addAll([
        _status(exitCode: 0),
        _status(
          exitCode: 1,
          lines: [
            '=== doctor started 2026-10-01 ===',
            'OLD RUN LINE',
            '=== doctor started 2026-10-04 ===',
            'NEW RUN LINE',
          ],
        ),
      ]);
      await pumpDiagnostics(tester, rest);
      await tester.tap(find.byKey(const ValueKey('sd1215-run-doctor')));
      await tester.pumpAndSettle();

      expect(find.textContaining('NEW RUN LINE'), findsOneWidget);
      expect(find.textContaining('OLD RUN LINE'), findsNothing);
      expect(find.text(strings(tester).sd1215ExitWarnings(1)), findsOneWidget);
    });

    testWidgets('Copy puts the output on the clipboard and nothing else '
        'happens', (tester) async {
      final rest = _server();
      rest.statusQueue.addAll([
        _status(exitCode: 0),
        _status(
          exitCode: 0,
          lines: ['=== doctor started t ===', 'line one', 'line two'],
        ),
      ]);
      await pumpDiagnostics(tester, rest);
      await tester.tap(find.byKey(const ValueKey('sd1215-run-doctor')));
      await tester.pumpAndSettle();
      final callsBefore = rest.calls.length;

      await tester.tap(find.byKey(const ValueKey('sd1215-copy-doctor')));
      await tester.pump();

      expect(copied, ['line one\nline two']);
      expect(rest.calls.length, callsBefore);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('leaving the screen leaves no read in flight or scheduled', (
      tester,
    ) async {
      final steps = <Completer<void>>[];
      final rest = _server();
      rest.statusQueue.addAll([
        _status(exitCode: 0),
        for (var i = 0; i < 30; i++) _status(running: true, lines: ['line $i']),
      ]);
      await pumpDiagnostics(
        tester,
        rest,
        sleep: (_) {
          final gate = Completer<void>();
          steps.add(gate);
          return gate.future;
        },
      );
      await tester.tap(find.byKey(const ValueKey('sd1215-run-doctor')));
      await tester.pump();
      await tester.pump();
      expect(steps, isNotEmpty);

      await tester.pumpWidget(const SizedBox());
      final reads = count(rest, 'GET actions/');
      for (final gate in steps) {
        if (!gate.isCompleted) gate.complete();
      }
      await tester.pump(const Duration(seconds: 5));

      expect(count(rest, 'GET actions/'), reads);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the app going to the background stops the follow', (
      tester,
    ) async {
      final steps = <Completer<void>>[];
      final rest = _server();
      rest.statusQueue.addAll([
        _status(exitCode: 0),
        for (var i = 0; i < 30; i++) _status(running: true, lines: ['line $i']),
      ]);
      await pumpDiagnostics(
        tester,
        rest,
        sleep: (_) {
          final gate = Completer<void>();
          steps.add(gate);
          return gate.future;
        },
      );
      await tester.tap(find.byKey(const ValueKey('sd1215-run-doctor')));
      await tester.pump();
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final reads = count(rest, 'GET actions/');
      steps.last.complete();
      await tester.pump(const Duration(seconds: 3));

      expect(count(rest, 'GET actions/'), reads);
      // Leave nothing pending for the test harness.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      for (final gate in steps) {
        if (!gate.isCompleted) gate.complete();
      }
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a launch the server refuses says it could not run', (
      tester,
    ) async {
      final rest = _server()
        ..posts['ops/doctor'] = const DashboardHttpException(500);
      rest.statusQueue.add(_status(exitCode: 0));
      await pumpDiagnostics(tester, rest);
      await tester.tap(find.byKey(const ValueKey('sd1215-run-doctor')));
      await tester.pumpAndSettle();
      expect(find.text(strings(tester).sd1215RunFailed), findsOneWidget);
    });
  });

  group('MCP', () {
    testWidgets('one read per opening and one per pull to refresh', (
      tester,
    ) async {
      var reads = 0;
      await pumpDiagnostics(
        tester,
        _server(),
        mcp: (_) async {
          reads++;
          return const [
            McpServerStatus(
              name: 'docs',
              transport: 'http',
              tools: 12,
              state: McpServerState.connected,
              source: McpServerSource.config,
            ),
          ];
        },
      );
      expect(reads, 1);

      await tester.fling(
        find.byType(ListView).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(reads, 2);
    });

    testWidgets('rows carry the name, translated state, tools and origin', (
      tester,
    ) async {
      await pumpDiagnostics(
        tester,
        _server(),
        mcp: (_) async => const [
          McpServerStatus(
            name: 'docs',
            transport: 'http',
            tools: 12,
            state: McpServerState.connected,
            source: McpServerSource.config,
          ),
          McpServerStatus(
            name: 'search',
            transport: 'stdio',
            tools: 0,
            state: McpServerState.failed,
            source: McpServerSource.plugin,
            plugin: 'web-tools',
          ),
        ],
      );
      final s = strings(tester);
      expect(find.text('docs'), findsOneWidget);
      expect(find.textContaining(s.sd1215McpConnected), findsOneWidget);
      expect(find.textContaining(s.sd1215McpTools(12)), findsOneWidget);
      expect(find.textContaining(s.sd1215McpFromConfig), findsOneWidget);
      expect(find.textContaining(s.sd1215McpFailed), findsOneWidget);
      expect(
        find.textContaining(s.sd1215McpFromPlugin('web-tools')),
        findsOneWidget,
      );
    });

    testWidgets('with no connected socket it says so', (tester) async {
      await pumpDiagnostics(tester, _server(), mcp: (_) async => null);
      expect(find.text(strings(tester).sd1215McpNoSocket), findsOneWidget);
    });

    testWidgets('a server without the method hides the section', (
      tester,
    ) async {
      await pumpDiagnostics(
        tester,
        _server(),
        mcp: (repo) => repo.mcpLiveStatus(
          (m, p) async =>
              throw const CapabilityFailure(CapabilityFailureKind.unsupported),
        ),
      );
      expect(find.text(strings(tester).sd1215Mcp), findsNothing);
    });
  });

  group('usage', () {
    testWidgets('shows totals with null sums as zero and the models', (
      tester,
    ) async {
      await pumpDiagnostics(tester, _server());
      final s = strings(tester);
      expect(find.text(s.sd1215UsageInput), findsOneWidget);
      expect(find.text('1200'), findsWidgets);
      expect(find.text(s.sd1215UsageCache), findsOneWidget);
      expect(find.text('0'), findsWidgets);
      expect(find.text('model-a'), findsOneWidget);
    });

    testWidgets('switching 30 to 7 days makes a single request', (
      tester,
    ) async {
      final rest = _server();
      await pumpDiagnostics(tester, rest);
      final before = count(rest, 'GET analytics/usage');
      await tester.tap(find.text(strings(tester).sd1215Days7));
      await tester.pumpAndSettle();

      expect(count(rest, 'GET analytics/usage'), before + 1);
      expect(rest.calls.last, 'GET analytics/usage?days=7');
      expect(find.text('77'), findsWidgets);
    });

    testWidgets('503 says the history is not available now', (tester) async {
      final rest = _server()
        ..gets['analytics/usage?days=30'] = const DashboardHttpException(503);
      await pumpDiagnostics(tester, rest);
      expect(
        find.text(strings(tester).sd1215HistoryUnavailable),
        findsOneWidget,
      );
    });
  });
}
