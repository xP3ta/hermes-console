// Read-only server diagnostics over the Capabilities repository: doctor and
// the security audit (attach when already running, never launch twice, follow
// until exit, stop when told), live MCP status, usage analytics and health.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_adapters.dart'
    show DashboardCapabilitiesRest;
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/capabilities/server_diagnostics_models.dart';
import 'package:hermes_android/core/capabilities/server_diagnostics_probe.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardClient, DashboardHttpException;
import 'package:hermes_android/core/services/tui_gateway_client.dart'
    show TuiGatewayClient, TuiGatewayRpcError;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'capabilities_fakes.dart';

Map<String, dynamic> _status({
  bool running = false,
  int? exitCode,
  List<String> lines = const [],
  String name = 'doctor',
}) => {
  'name': name,
  'running': running,
  'exit_code': exitCode,
  'pid': running ? 4242 : null,
  'lines': lines,
};

CapabilitiesRepository _repo(
  ScriptedRest rest, {
  String profile = '',
  DateTime Function()? clock,
  Duration timeout = const Duration(minutes: 10),
}) => CapabilitiesRepository(
  rest: rest,
  profile: profile,
  sleep: (_) async {},
  actionPollInterval: Duration.zero,
  actionTimeout: timeout,
  clock: clock,
);

void main() {
  group('opsActionOutput', () {
    test('keeps only what follows the last started marker', () {
      final lines = [
        '=== doctor started 2026-10-01 09:00:00 ===',
        'old problem',
        '=== doctor started 2026-10-04 12:00:00 ===',
        'Checking config… ok',
        'Checking git… ok',
      ];
      expect(opsActionOutput('doctor', lines), [
        'Checking config… ok',
        'Checking git… ok',
      ]);
    });

    test('a marker of another action is not a boundary', () {
      final lines = [
        '=== doctor started 2026-10-04 12:00:00 ===',
        '=== security-audit started 2026-10-04 12:01:00 ===',
        'finding',
      ];
      expect(opsActionOutput('doctor', lines), [
        '=== security-audit started 2026-10-04 12:01:00 ===',
        'finding',
      ]);
    });

    test('without a marker in the window every line is kept', () {
      expect(opsActionOutput('doctor', ['a', 'b']), ['a', 'b']);
    });

    test('a marker with nothing after it is an empty output', () {
      expect(
        opsActionOutput('doctor', [
          '=== doctor started 2026-10-04 12:00:00 ===',
        ]),
        isEmpty,
      );
    });
  });

  group('running doctor and the audit', () {
    test('reads the state first and launches when nothing runs', () async {
      final rest = ScriptedRest()
        ..gets['actions/doctor/status'] = _status(exitCode: 0)
        ..posts['ops/doctor'] = {'ok': true, 'pid': 77, 'name': 'doctor'};
      rest.statusQueue.addAll([
        _status(exitCode: 0),
        _status(running: true, lines: ['=== doctor started t ===', 'a']),
        _status(exitCode: 0, lines: ['=== doctor started t ===', 'a', 'b']),
      ]);
      final progress = <CapabilityActionStatus>[];
      final result = await _repo(
        rest,
      ).runOps(OpsAction.doctor, onProgress: progress.add);

      expect(result!.exitCode, 0);
      expect(rest.calls.first, 'GET actions/doctor/status?lines=200');
      expect(rest.calls.indexWhere((c) => c.startsWith('POST')), 1);
      expect(rest.mutations, ['POST ops/doctor']);
      expect(progress.last.running, isFalse);
    });

    test('attaches to a run in progress and never posts', () async {
      final rest = ScriptedRest()
        ..posts['ops/doctor'] = {'ok': true, 'name': 'doctor'};
      rest.statusQueue.addAll([
        _status(running: true, lines: ['=== doctor started t ===', 'a']),
        _status(running: true, lines: ['=== doctor started t ===', 'a', 'b']),
        _status(
          exitCode: 1,
          lines: ['=== doctor started t ===', 'a', 'b', 'c'],
        ),
      ]);
      final result = await _repo(rest).runOps(OpsAction.doctor);

      expect(result!.exitCode, 1);
      expect(rest.mutations, isEmpty);
    });

    test('attachOps follows a run in progress and never posts', () async {
      final rest = ScriptedRest();
      rest.statusQueue.addAll([
        _status(running: true, lines: ['=== doctor started t ===', 'a']),
        _status(running: true),
        _status(exitCode: 0, lines: ['=== doctor started t ===', 'a', 'b']),
      ]);
      final result = await _repo(rest).attachOps(OpsAction.doctor);
      expect(result!.exitCode, 0);
      expect(rest.mutations, isEmpty);
    });

    test('attachOps on a finished run returns it without launching', () async {
      final rest = ScriptedRest();
      rest.statusQueue.add(
        _status(exitCode: 2, lines: ['=== doctor started t ===', 'warn']),
      );
      final result = await _repo(rest).attachOps(OpsAction.doctor);
      expect(result!.exitCode, 2);
      expect(rest.mutations, isEmpty);
      expect(rest.calls, ['GET actions/doctor/status?lines=200']);
    });

    test('the profile travels on the launch', () async {
      final rest = ScriptedRest()
        ..posts['ops/security-audit?profile=work'] = {
          'ok': true,
          'name': 'security-audit',
        };
      rest.statusQueue.addAll([
        _status(name: 'security-audit', exitCode: 0),
        _status(name: 'security-audit', exitCode: 0),
      ]);
      await _repo(rest, profile: 'work').runOps(OpsAction.securityAudit);
      expect(rest.mutations, ['POST ops/security-audit?profile=work']);
    });

    test('a launch without ok is an invalid response', () async {
      final rest = ScriptedRest()
        ..gets['actions/doctor/status'] = _status(exitCode: 0)
        ..posts['ops/doctor'] = {'ok': false};
      await expectLater(
        _repo(rest).runOps(OpsAction.doctor),
        throwsA(
          isA<CapabilityFailure>().having(
            (f) => f.kind,
            'kind',
            CapabilityFailureKind.invalidResponse,
          ),
        ),
      );
    });

    test(
      '404 on the state read marks the action unsupported and posts nothing',
      () async {
        final rest = ScriptedRest();
        final repo = _repo(rest);
        await expectLater(
          repo.runOps(OpsAction.doctor),
          throwsA(
            isA<CapabilityFailure>().having(
              (f) => f.kind,
              'kind',
              CapabilityFailureKind.unsupported,
            ),
          ),
        );
        expect(repo.supports(CapabilityFeature.opsDoctor), isFalse);
        expect(rest.mutations, isEmpty);
      },
    );

    test('a 500 on the launch is unavailable', () async {
      final rest = ScriptedRest()
        ..gets['actions/doctor/status'] = _status(exitCode: 0)
        ..posts['ops/doctor'] = const DashboardHttpException(500);
      await expectLater(
        _repo(rest).runOps(OpsAction.doctor),
        throwsA(
          isA<CapabilityFailure>().having(
            (f) => f.kind,
            'kind',
            CapabilityFailureKind.unavailable,
          ),
        ),
      );
    });

    test('a read-only connection cannot launch', () async {
      final rest = ScriptedRest()
        ..gets['actions/doctor/status'] = _status(exitCode: 0)
        ..posts['ops/doctor'] = const DashboardHttpException(403);
      await expectLater(
        _repo(rest).runOps(OpsAction.doctor),
        throwsA(
          isA<CapabilityFailure>().having(
            (f) => f.kind,
            'kind',
            CapabilityFailureKind.forbidden,
          ),
        ),
      );
    });

    test('shouldStop ends the follow without another read', () async {
      final rest = ScriptedRest();
      rest.statusQueue.addAll([
        _status(running: true, lines: ['=== doctor started t ===', 'a']),
        _status(running: true),
        _status(running: true),
        _status(running: true),
      ]);
      var stop = false;
      var reads = 0;
      final result = await _repo(rest).runOps(
        OpsAction.doctor,
        onProgress: (_) {
          reads++;
          if (reads == 2) stop = true;
        },
        shouldStop: () => stop,
      );

      expect(result, isNull);
      expect(rest.calls.where((c) => c.startsWith('GET')).length, 2);
      expect(rest.mutations, isEmpty);
    });

    test('a run stopped before the first read touches nothing', () async {
      final rest = ScriptedRest();
      final result = await _repo(
        rest,
      ).runOps(OpsAction.doctor, shouldStop: () => true);
      expect(result, isNull);
      expect(rest.calls, isEmpty);
    });

    test(
      'the follow gives up at the time limit of the injected clock',
      () async {
        var now = DateTime(2026, 10, 4, 12);
        final rest = ScriptedRest();
        for (var i = 0; i < 50; i++) {
          rest.statusQueue.add(_status(running: true));
        }
        final repo = CapabilitiesRepository(
          rest: rest,
          sleep: (_) async => now = now.add(const Duration(minutes: 4)),
          actionPollInterval: const Duration(minutes: 4),
          actionTimeout: const Duration(minutes: 10),
          clock: () => now,
        );
        await expectLater(
          repo.runOps(OpsAction.doctor),
          throwsA(
            isA<CapabilityFailure>().having(
              (f) => f.kind,
              'kind',
              CapabilityFailureKind.unavailable,
            ),
          ),
        );
        expect(rest.calls.length, lessThan(10));
      },
    );

    test('the skills installer still follows its action as before', () async {
      final rest = ScriptedRest()
        ..posts['skills/hub/install'] = {'ok': true, 'name': 'skills-install'};
      rest.statusQueue.addAll([
        _status(running: true, name: 'skills-install'),
        _status(exitCode: 0, name: 'skills-install'),
      ]);
      final result = await _repo(rest).installSkill('official/x/y');
      expect(result.succeeded, isTrue);
    });
  });

  group('live MCP status', () {
    Future<Map<String, dynamic>> answer(
      String method,
      Map<String, dynamic> p,
    ) async => {
      'servers': [
        {
          'name': 'docs',
          'transport': 'http',
          'tools': 12,
          'connected': true,
          'disabled': false,
          'status': 'connected',
          'source': 'config',
          'plugin': null,
        },
        {
          'name': 'search',
          'transport': 'stdio',
          'tools': 0,
          'connected': false,
          'disabled': false,
          'status': 'failed',
          'source': 'plugin',
          'plugin': 'web-tools',
        },
        {
          'name': 'future',
          'transport': 'stdio',
          'tools': 'many',
          'status': 'quantum',
        },
        {'transport': 'stdio'},
      ],
      'checked_at': 1790000000000,
    };

    test(
      'parses servers with an integer tool count and known states',
      () async {
        final calls = <(String, Map<String, dynamic>)>[];
        final servers = await _repo(ScriptedRest(), profile: 'work')
            .mcpLiveStatus((method, params) {
              calls.add((method, params));
              return answer(method, params);
            });

        expect(calls.single.$1, 'mcp.servers.status');
        expect(calls.single.$2, {'profile': 'work'});
        expect(servers.map((s) => s.name), ['docs', 'search', 'future']);
        expect(servers[0].state, McpServerState.connected);
        expect(servers[0].tools, 12);
        expect(servers[0].source, McpServerSource.config);
        expect(servers[1].state, McpServerState.failed);
        expect(servers[1].source, McpServerSource.plugin);
        expect(servers[1].plugin, 'web-tools');
      },
    );

    test('an unknown state and a non-integer count stay safe', () async {
      final servers = await _repo(ScriptedRest()).mcpLiveStatus(answer);
      final future = servers.last;
      expect(future.state, McpServerState.unknown);
      expect(future.tools, 0);
      expect(future.source, isNull);
    });

    test('the six wire states map to their own state', () {
      for (final (wire, state) in const [
        ('connected', McpServerState.connected),
        ('disabled', McpServerState.disabled),
        ('connecting', McpServerState.connecting),
        ('failed', McpServerState.failed),
        ('lazy', McpServerState.lazy),
        ('configured', McpServerState.configured),
      ]) {
        expect(
          McpServerStatus.tryParse({
            'name': 'x',
            'transport': 'http',
            'status': wire,
          })!.state,
          state,
          reason: wire,
        );
      }
    });

    test('null optionals do not break the parse', () {
      final status = McpServerStatus.tryParse({
        'name': 'x',
        'transport': null,
        'tools': null,
        'connected': null,
        'disabled': null,
        'status': null,
        'source': null,
        'plugin': null,
      })!;
      expect(status.transport, '');
      expect(status.tools, 0);
      expect(status.state, McpServerState.unknown);
    });

    test('the default profile is not sent', () async {
      Map<String, dynamic>? seen;
      await _repo(ScriptedRest(), profile: 'default').mcpLiveStatus((
        m,
        p,
      ) async {
        seen = p;
        return {'servers': <Object>[]};
      });
      expect(seen, isEmpty);
    });

    test('-32601 marks it unsupported', () async {
      final repo = _repo(ScriptedRest());
      await expectLater(
        repo.mcpLiveStatus(
          (m, p) async => throw const TuiGatewayRpcError(
            'mcp.servers.status',
            'x',
            code: -32601,
          ),
        ),
        throwsA(
          isA<CapabilityFailure>().having(
            (f) => f.kind,
            'kind',
            CapabilityFailureKind.unsupported,
          ),
        ),
      );
      expect(repo.supports(CapabilityFeature.mcpLiveStatus), isFalse);
    });

    test('5024 is a failure that is not "unsupported"', () async {
      final repo = _repo(ScriptedRest());
      await expectLater(
        repo.mcpLiveStatus(
          (m, p) async => throw const TuiGatewayRpcError(
            'mcp.servers.status',
            'x',
            code: 5024,
          ),
        ),
        throwsA(
          isA<CapabilityFailure>().having(
            (f) => f.kind,
            'kind',
            CapabilityFailureKind.rejected,
          ),
        ),
      );
      expect(repo.supports(CapabilityFeature.mcpLiveStatus), isNot(false));
    });

    test('the gateway allows the read, also on a read-only connection', () {
      expect(
        TuiGatewayClient.capabilitiesRpcAllowed(
          'mcp.servers.status',
          readOnly: true,
        ),
        isTrue,
      );
      expect(
        TuiGatewayClient.capabilitiesRpcAllowed(
          'mcp.servers.status',
          readOnly: false,
        ),
        isTrue,
      );
    });
  });

  group('usage analytics', () {
    Map<String, dynamic> body() => {
      'daily': [
        {
          'day': '2026-10-03',
          'input_tokens': 100,
          'output_tokens': 50,
          'cache_read_tokens': null,
          'reasoning_tokens': 7,
          'estimated_cost': 0.25,
          'actual_cost': null,
          'sessions': 2,
          'api_calls': 5,
        },
      ],
      'by_model': [
        {
          'model': 'model-a',
          'input_tokens': 100,
          'output_tokens': 50,
          'estimated_cost': 0.25,
          'sessions': 2,
          'api_calls': 5,
        },
        {'model': '', 'input_tokens': 1},
      ],
      'totals': {
        'total_input': 100,
        'total_output': 50,
        'total_cache_read': null,
        'total_reasoning': 7,
        'total_estimated_cost': 0.25,
        'total_actual_cost': null,
        'total_sessions': 2,
        'total_api_calls': 5,
      },
      'period_days': 30,
    };

    test('parses totals, daily and per model rows', () async {
      final rest = ScriptedRest()..gets['analytics/usage?days=30'] = body();
      final usage = await _repo(rest).usage(30);
      expect(usage.days, 30);
      expect(usage.totals.input, 100);
      expect(usage.totals.output, 50);
      expect(usage.totals.reasoning, 7);
      expect(usage.totals.sessions, 2);
      expect(usage.totals.apiCalls, 5);
      expect(usage.totals.estimatedCost, 0.25);
      expect(usage.daily.single.day, '2026-10-03');
      expect(usage.byModel.single.model, 'model-a');
    });

    test('null sums are zero', () async {
      final rest = ScriptedRest()..gets['analytics/usage?days=30'] = body();
      final usage = await _repo(rest).usage(30);
      expect(usage.totals.cacheRead, 0);
      expect(usage.totals.actualCost, 0);
      expect(usage.daily.single.cacheRead, 0);
      expect(usage.daily.single.actualCost, 0);
    });

    test('an empty period is all zeros', () async {
      final rest = ScriptedRest()
        ..gets['analytics/usage?days=7'] = {
          'daily': <Object>[],
          'by_model': <Object>[],
          'totals': {
            'total_input': null,
            'total_output': null,
            'total_sessions': null,
          },
          'period_days': 7,
        };
      final usage = await _repo(rest).usage(7);
      expect(usage.totals.input, 0);
      expect(usage.totals.sessions, 0);
      expect(usage.daily, isEmpty);
    });

    test('only the 7, 30 and 90 day presets are asked for', () async {
      final rest = ScriptedRest()
        ..gets['analytics/usage?days=7'] = body()
        ..gets['analytics/usage?days=30'] = body()
        ..gets['analytics/usage?days=90'] = body();
      final repo = _repo(rest);
      await repo.usage(7);
      await repo.usage(30);
      await repo.usage(90);
      expect(rest.calls, [
        'GET analytics/usage?days=7',
        'GET analytics/usage?days=30',
        'GET analytics/usage?days=90',
      ]);
      await expectLater(repo.usage(12), throwsA(isA<ArgumentError>()));
    });

    test('the profile travels on the read', () async {
      final rest = ScriptedRest()
        ..gets['analytics/usage?days=30&profile=work'] = body();
      await _repo(rest, profile: 'work').usage(30);
      expect(rest.calls.single, 'GET analytics/usage?days=30&profile=work');
    });

    test(
      'an unreachable dashboard is unavailable, never a raw error',
      () async {
        final rest = ScriptedRest()
          ..gets['analytics/usage?days=30'] = Exception(
            'Dashboard not accessible',
          )
          ..gets['health'] = const SocketException('unreachable');
        final repo = _repo(rest);
        for (final read in [() => repo.usage(30), repo.serverHealth]) {
          await expectLater(
            read(),
            throwsA(
              isA<CapabilityFailure>().having(
                (f) => f.kind,
                'kind',
                CapabilityFailureKind.unavailable,
              ),
            ),
          );
        }
        expect(
          repo.supports(CapabilityFeature.usageAnalytics),
          isNot(false),
          reason: 'being unreachable says nothing about support',
        );
      },
    );

    test('503 is unavailable, 404 unsupported', () async {
      final unavailable = ScriptedRest()
        ..gets['analytics/usage?days=30'] = const DashboardHttpException(503);
      await expectLater(
        _repo(unavailable).usage(30),
        throwsA(
          isA<CapabilityFailure>().having(
            (f) => f.kind,
            'kind',
            CapabilityFailureKind.unavailable,
          ),
        ),
      );
      final repo = _repo(ScriptedRest());
      await expectLater(
        repo.usage(30),
        throwsA(
          isA<CapabilityFailure>().having(
            (f) => f.kind,
            'kind',
            CapabilityFailureKind.unsupported,
          ),
        ),
      );
      expect(repo.supports(CapabilityFeature.usageAnalytics), isFalse);
    });
  });

  group('health', () {
    test('reads the version', () async {
      final rest = ScriptedRest()
        ..gets['health'] = {
          'ok': true,
          'version': '0.20.1',
          'displayVersion': 'v0.20.1',
          'auth_required': false,
        };
      final health = await _repo(rest).serverHealth();
      expect(health.version, '0.20.1');
      expect(health.displayVersion, 'v0.20.1');
    });

    test('idle true, false and null', () async {
      Future<ServerIdle> read(Object? idle, [String? reason]) {
        final rest = ScriptedRest()
          ..gets['health/idle'] = {'ok': true, 'idle': idle, 'reason': reason};
        return _repo(rest).serverIdle();
      }

      expect((await read(true)).idle, isTrue);
      final busy = await read(false, 'turn_in_flight');
      expect(busy.idle, isFalse);
      expect(busy.reason, 'turn_in_flight');
      expect((await read(null, 'turn_probe_unavailable')).idle, isNull);
    });

    test('404 on idle is unsupported', () async {
      final repo = _repo(ScriptedRest());
      await expectLater(repo.serverIdle(), throwsA(isA<CapabilityFailure>()));
      expect(repo.supports(CapabilityFeature.serverIdle), isFalse);
    });
  });

  group('two launchers of the same action', () {
    CapabilitiesRepository launcher(
      _RacingRest rest, {
      String? scope = 'conn-1|work',
    }) => CapabilitiesRepository(
      rest: rest,
      profile: 'work',
      sleep: (_) async {},
      actionPollInterval: Duration.zero,
      launchScope: scope,
    );

    test('launch doctor once when both read "not running" first', () async {
      final rest = _RacingRest();
      final first = launcher(rest).runOps(OpsAction.doctor);
      final second = launcher(rest).runOps(OpsAction.doctor);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      rest.releasePost();
      await Future.wait([first, second]);

      expect(rest.posts, 1, reason: 'the second one attached instead');
    });

    test('also with several separate repository instances', () async {
      final rest = _RacingRest();
      final runs = [
        for (var i = 0; i < 4; i++) launcher(rest).runOps(OpsAction.doctor),
      ];
      await Future<void>.delayed(Duration.zero);
      rest.releasePost();
      await Future.wait(runs);
      expect(rest.posts, 1);
    });

    test('different actions do not wait for each other', () async {
      final rest = _RacingRest();
      final doctor = launcher(rest).runOps(OpsAction.doctor);
      final audit = launcher(rest).runOps(OpsAction.securityAudit);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(rest.posts, 2);
      rest.releasePost();
      await Future.wait([doctor, audit]);
    });

    test('different servers do not wait for each other', () async {
      final a = _RacingRest();
      final b = _RacingRest();
      final first = launcher(a, scope: 'conn-1|').runOps(OpsAction.doctor);
      final second = launcher(b, scope: 'conn-2|').runOps(OpsAction.doctor);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect([a.posts, b.posts], [1, 1]);
      a.releasePost();
      b.releasePost();
      await Future.wait([first, second]);
    });

    test('a failed launch does not block the next one', () async {
      final rest = _RacingRest()..failNextPost = true;
      await expectLater(
        launcher(rest).runOps(OpsAction.doctor),
        throwsA(isA<CapabilityFailure>()),
      );
      rest.releasePost();
      await launcher(rest).runOps(OpsAction.doctor);
      expect(rest.posts, 2);
    });
  });

  test(
    'every diagnostics read and run stays on the known read routes',
    () async {
      // Behavioral: everything the repository can send, through the real
      // Dashboard transport, must be one of these routes. A retirement call,
      // however its path is composed, is not in the list.
      const allowed = {
        'GET /api/health',
        'GET /api/health/idle',
        'GET /api/actions/doctor/status',
        'GET /api/actions/security-audit/status',
        'POST /api/ops/doctor',
        'POST /api/ops/security-audit',
        'GET /api/analytics/usage',
      };
      final sent = <String>[];
      var launched = false;
      final dashboard = DashboardClient(
        host: 'hermes.example.test',
        port: 9119,
        manualToken: 'synthetic-token',
        httpClientOverride: MockClient((request) async {
          final path = Uri.decodeFull(request.url.path);
          sent.add('${request.method} $path');
          if (request.method == 'POST') {
            launched = true;
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          if (path.startsWith('/api/actions/')) {
            return http.Response(
              jsonEncode({
                'name': path.split('/')[3],
                'running': false,
                'exit_code': launched ? 0 : null,
                'lines': <String>[],
              }),
              200,
            );
          }
          if (path == '/api/analytics/usage') {
            return http.Response(
              jsonEncode({
                'daily': [],
                'by_model': [],
                'totals': {},
                'period_days': 30,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({'ok': true, 'version': '1', 'idle': true}),
            200,
          );
        }),
      );
      addTearDown(dashboard.close);
      final repo = CapabilitiesRepository(
        rest: DashboardCapabilitiesRest(dashboard),
        profile: 'work',
        sleep: (_) async {},
        actionPollInterval: Duration.zero,
      );

      await repo.serverHealth();
      await repo.serverIdle();
      for (final action in OpsAction.values) {
        await repo.opsStatus(action);
        await repo.attachOps(action);
        launched = false;
        await repo.runOps(action);
      }
      for (final days in UsageAnalytics.presets) {
        await repo.usage(days);
      }
      await probeDiagnostics(repo);

      expect(sent, isNotEmpty);
      expect(sent.toSet().difference(allowed), isEmpty);
      expect(sent.where((r) => r.toLowerCase().contains('retire')), isEmpty);
    },
  );

  test('no Console code can call the retirement endpoint', () {
    // `/api/health/retirement` closes the backend's admission of new work.
    expect(
      Process.runSync('grep', ['-rn', 'health/retirement', 'lib']).stdout,
      isEmpty,
    );
  });
}

/// A Dashboard whose launches are held until [releasePost]; once launched the
/// action reads as running for a few reads, then finishes.
final class _RacingRest implements CapabilitiesRest {
  final Map<String, Completer<void>> _gates = {};
  final Set<String> _running = {};
  final Map<String, int> _reads = {};
  int posts = 0;
  bool failNextPost = false;

  Completer<void> _gate(String name) =>
      _gates.putIfAbsent(name, () => Completer<void>());

  void releasePost() {
    for (final name in ['doctor', 'security-audit']) {
      final gate = _gate(name);
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    final name = endpoint.split('?').first.split('/')[1];
    if (_running.contains(name)) {
      final reads = _reads[name] = (_reads[name] ?? 0) + 1;
      if (reads > 100) _running.remove(name);
      return {
        'name': name,
        'running': reads <= 100,
        'exit_code': reads <= 100 ? null : 0,
        'lines': <String>[],
      };
    }
    return {
      'name': name,
      'running': false,
      'exit_code': null,
      'lines': <String>[],
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic>? body,
    Duration? timeout,
  }) async {
    final name = endpoint.split('?').first.split('/').last;
    posts++;
    if (failNextPost) {
      failNextPost = false;
      throw const DashboardHttpException(500);
    }
    await _gate(name).future;
    _running.add(name);
    return {'ok': true, 'name': name};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
