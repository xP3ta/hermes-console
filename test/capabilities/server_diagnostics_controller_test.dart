// The read-only Diagnostics controller: one read per section on open and on
// refresh, doctor and audit followed only on demand and only while the screen
// is on show, nothing kept after dispose, and late answers of another profile
// dropped.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart'
    show CapabilityActionStatus;
import 'package:hermes_android/core/capabilities/server_diagnostics_controller.dart';
import 'package:hermes_android/core/capabilities/server_diagnostics_models.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_restart_signal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'capabilities_fakes.dart';

Map<String, dynamic> _status({
  bool running = false,
  int? exitCode,
  List<String> lines = const [],
  String name = 'doctor',
}) => {'name': name, 'running': running, 'exit_code': exitCode, 'lines': lines};

Map<String, dynamic> _usage(int days, {int sessions = 3}) => {
  'daily': <Object>[],
  'by_model': [
    {'model': 'model-a', 'input_tokens': 10, 'sessions': sessions},
  ],
  'totals': {'total_sessions': sessions, 'total_input': 10},
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
  ..gets['analytics/usage?days=30'] = _usage(30)
  ..gets['analytics/usage?days=7'] = _usage(7, sessions: 1)
  ..gets['analytics/usage?days=90'] = _usage(90, sessions: 9);

const _hosts = ['hermes.example.test'];

void main() {
  late ConnectionManager manager;
  late ActiveProfileScope scope;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ServerRestartSignals.resetForTesting();
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    scope = ActiveProfileScope.of(manager, 'conn-diag');
  });

  ServerDiagnosticsController controller(
    ScriptedRest rest, {
    Future<List<McpServerStatus>?> Function(CapabilitiesRepository repo)? mcp,
    Future<void> Function(Duration)? sleep,
  }) {
    final c = ServerDiagnosticsController(
      scope: scope,
      repoFor: (profile) => CapabilitiesRepository(
        rest: rest,
        profile: profile,
        sleep: sleep ?? (_) async {},
        actionPollInterval: Duration.zero,
      ),
      mcpReader: mcp ?? (_) async => const [],
      restartHosts: _hosts,
    );
    addTearDown(c.dispose);
    return c;
  }

  int count(ScriptedRest rest, String prefix) =>
      rest.calls.where((c) => c.startsWith(prefix)).length;

  group('open and refresh', () {
    test('reads every section once', () async {
      final rest = _server();
      var mcpReads = 0;
      final c = controller(
        rest,
        mcp: (_) async {
          mcpReads++;
          return const [
            McpServerStatus(
              name: 'docs',
              transport: 'http',
              tools: 3,
              state: McpServerState.connected,
            ),
          ];
        },
      );
      await c.load();

      expect(c.health!.version, '0.20.1');
      expect(c.idle!.idle, isFalse);
      expect(c.usage!.days, 30);
      expect(c.mcpServers.single.name, 'docs');
      expect(mcpReads, 1);
      expect(count(rest, 'GET health'), 2); // health + health/idle
      expect(count(rest, 'GET analytics/usage'), 1);
      expect(count(rest, 'GET actions/'), 0, reason: 'nothing runs on open');
      expect(rest.mutations, isEmpty);
    });

    test('a manual refresh reads again, once per section', () async {
      final rest = _server();
      var mcpReads = 0;
      final c = controller(
        rest,
        mcp: (_) async {
          mcpReads++;
          return const [];
        },
      );
      await c.load();
      await c.refresh();
      expect(mcpReads, 2);
      expect(count(rest, 'GET analytics/usage'), 2);
    });

    test(
      'no connected socket confirms nothing, so there is no section',
      () async {
        final rest = _server();
        var connected = false;
        final c = controller(
          rest,
          mcp: (_) async => connected ? const [] : null,
        );
        await c.load();
        expect(c.mcpPhase, DiagPhase.hidden);
        expect(c.mcpServers, isEmpty);

        // A chat connects; the next refresh gets a real answer.
        connected = true;
        await c.refresh();
        expect(c.mcpPhase, DiagPhase.ready);
      },
    );

    test('an MCP method the server lacks hides the section', () async {
      final rest = _server();
      final c = controller(
        rest,
        mcp: (repo) => repo.mcpLiveStatus(
          (m, p) async =>
              throw const CapabilityFailure(CapabilityFailureKind.unsupported),
        ),
      );
      await c.load();
      expect(c.mcpPhase, DiagPhase.hidden);
    });

    test('routes the server lacks are hidden, the rest still show', () async {
      final rest = ScriptedRest()
        ..gets['health'] = {'ok': true, 'version': '1'};
      final c = controller(rest);
      await c.load();
      expect(c.serverPhase, DiagPhase.ready);
      expect(c.usagePhase, DiagPhase.hidden);
      expect(c.idleSupported, isFalse);
      expect(c.doctorAvailable, isTrue, reason: 'unknown until probed');
    });

    for (final failure in [
      const DashboardHttpException(401),
      const DashboardHttpException(403),
      const DashboardHttpException(500),
      const DashboardHttpException(503),
      const DashboardHttpException(404),
    ]) {
      test(
        'usage ${failure.statusCode} before a good answer stays hidden',
        () async {
          final rest = _server()..gets['analytics/usage?days=30'] = failure;
          final c = controller(rest);
          await c.load();
          expect(c.usagePhase, DiagPhase.hidden);
          expect(c.usage, isNull);
        },
      );
    }

    test(
      'usage 503 after a good answer says it is not available now',
      () async {
        final rest = _server();
        final c = controller(rest);
        await c.load();
        expect(c.usagePhase, DiagPhase.ready);

        rest.gets['analytics/usage?days=7'] = const DashboardHttpException(503);
        await c.setUsageDays(7);

        expect(c.usagePhase, DiagPhase.unavailable);
        expect(c.usage, isNull);
      },
    );

    test('a 404 after a good answer hides the section again', () async {
      final rest = _server();
      final c = controller(rest);
      await c.load();
      rest.gets['analytics/usage?days=7'] = const DashboardHttpException(404);
      await c.setUsageDays(7);
      expect(c.usagePhase, DiagPhase.hidden);
      // ...and a later 503 does not bring it back: it was never confirmed
      // again.
      rest.gets['analytics/usage?days=90'] = const DashboardHttpException(503);
      await c.setUsageDays(90);
      expect(c.usagePhase, DiagPhase.hidden);
    });

    test('MCP and the server section follow the same rule', () async {
      final rest = _server()
        ..gets['health'] = const DashboardHttpException(500)
        ..gets['health/idle'] = const DashboardHttpException(500);
      var mcpOk = false;
      final c = controller(
        rest,
        mcp: (_) async {
          if (mcpOk) return const [];
          throw const CapabilityFailure(CapabilityFailureKind.rejected);
        },
      );
      await c.load();
      expect(c.serverPhase, DiagPhase.hidden);
      expect(c.mcpPhase, DiagPhase.hidden);

      mcpOk = true;
      await c.refresh();
      expect(c.mcpPhase, DiagPhase.ready);
      mcpOk = false;
      await c.refresh();
      expect(c.mcpPhase, DiagPhase.unavailable, reason: 'was confirmed');
    });

    test('changing the period makes one request', () async {
      final rest = _server();
      final c = controller(rest);
      await c.load();
      final before = count(rest, 'GET analytics/usage');
      await c.setUsageDays(7);
      expect(count(rest, 'GET analytics/usage'), before + 1);
      expect(c.usageDays, 7);
      expect(c.usage!.totals.sessions, 1);
    });

    test('an unknown period is ignored', () async {
      final rest = _server();
      final c = controller(rest);
      await c.load();
      await c.setUsageDays(12);
      expect(c.usageDays, 30);
    });

    test('the restart note comes from the passive store, no request', () async {
      final rest = _server();
      final c = controller(rest);
      await c.load();
      expect(c.restartNote, isNull);
      final calls = rest.calls.length;
      ServerRestartSignals.noteRpc(_hosts.first, 5098, 'old code');
      expect(c.restartNote, 'old code');
      expect(rest.calls.length, calls);
    });
  });

  group('doctor and audit', () {
    test('run reads the state, launches and shows the new output', () async {
      final rest = _server()
        ..posts['ops/doctor'] = {'ok': true, 'name': 'doctor'};
      rest.statusQueue.addAll([
        _status(exitCode: 0, lines: ['=== doctor started old ===', 'old']),
        _status(running: true, lines: ['=== doctor started new ===', 'a']),
        _status(
          exitCode: 0,
          lines: [
            '=== doctor started old ===',
            'old',
            '=== doctor started new ===',
            'a',
            'b',
          ],
        ),
      ]);
      final c = controller(rest);
      await c.runOps(OpsAction.doctor);

      final view = c.ops(OpsAction.doctor);
      expect(view.phase, OpsPhase.finished);
      expect(view.exitCode, 0);
      expect(view.lines, ['a', 'b']);
    });

    test('a run already going is attached, never posted', () async {
      final rest = _server();
      rest.statusQueue.addAll([
        _status(running: true, lines: ['=== doctor started t ===', 'a']),
        _status(exitCode: 1, lines: ['=== doctor started t ===', 'a', 'b']),
      ]);
      final c = controller(rest);
      await c.runOps(OpsAction.doctor);
      expect(rest.mutations, isEmpty);
      expect(c.ops(OpsAction.doctor).exitCode, 1);
    });

    test('a second tap while it is followed does nothing', () async {
      final gate = Completer<void>();
      final rest = _server()
        ..posts['ops/doctor'] = {'ok': true, 'name': 'doctor'};
      rest.statusQueue.addAll([
        _status(exitCode: 0),
        _status(running: true),
        _status(exitCode: 0, lines: ['x']),
      ]);
      final c = controller(rest, sleep: (_) => gate.future);
      final first = c.runOps(OpsAction.doctor);
      await Future<void>.delayed(Duration.zero);
      await c.runOps(OpsAction.doctor);
      gate.complete();
      await first;
      expect(rest.mutations, ['POST ops/doctor']);
    });

    test('a non-zero exit is a result, not a failure', () async {
      final rest = _server()
        ..posts['ops/security-audit'] = {'ok': true, 'name': 'security-audit'};
      rest.statusQueue.addAll([
        _status(name: 'security-audit', exitCode: 0),
        _status(name: 'security-audit', exitCode: 3, lines: ['finding']),
      ]);
      final c = controller(rest);
      await c.runOps(OpsAction.securityAudit);
      final view = c.ops(OpsAction.securityAudit);
      expect(view.phase, OpsPhase.finished);
      expect(view.exitCode, 3);
      expect(view.failure, isNull);
    });

    test('a 404 means the action is not there and hides it', () async {
      final rest = ScriptedRest();
      final c = controller(rest);
      await c.runOps(OpsAction.doctor);
      expect(c.doctorAvailable, isFalse);
      expect(rest.mutations, isEmpty);
    });

    test('pausing stops the follow: no read is left scheduled', () async {
      final steps = <Completer<void>>[];
      final rest = _server()
        ..posts['ops/doctor'] = {'ok': true, 'name': 'doctor'};
      rest.statusQueue.addAll([
        _status(exitCode: 0),
        for (var i = 0; i < 20; i++) _status(running: true, lines: ['line $i']),
      ]);
      final c = controller(
        rest,
        sleep: (_) {
          final gate = Completer<void>();
          steps.add(gate);
          return gate.future;
        },
      );
      unawaited(c.runOps(OpsAction.doctor));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(steps, isNotEmpty);

      c.pause();
      final readsAtPause = count(rest, 'GET actions/');
      steps.last.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(count(rest, 'GET actions/'), readsAtPause);
    });

    test(
      'coming back re-attaches by reading the state, never relaunching',
      () async {
        final steps = <Completer<void>>[];
        final rest = _server()
          ..posts['ops/doctor'] = {'ok': true, 'name': 'doctor'};
        rest.statusQueue.addAll([
          _status(exitCode: 0),
          _status(running: true, lines: ['=== doctor started t ===', 'a']),
        ]);
        final c = controller(
          rest,
          sleep: (_) {
            final gate = Completer<void>();
            steps.add(gate);
            return gate.future;
          },
        );
        unawaited(c.runOps(OpsAction.doctor));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        c.pause();
        steps.last.complete();
        await Future<void>.delayed(Duration.zero);

        rest.statusQueue.addAll([
          _status(running: true, lines: ['=== doctor started t ===', 'a', 'b']),
          _status(
            exitCode: 0,
            lines: ['=== doctor started t ===', 'a', 'b', 'c'],
          ),
        ]);
        final resumed = c.resume();
        await Future<void>.delayed(Duration.zero);
        while (steps.isNotEmpty && !steps.last.isCompleted) {
          steps.last.complete();
          await Future<void>.delayed(Duration.zero);
        }
        await resumed;

        expect(rest.mutations, ['POST ops/doctor']);
        expect(c.ops(OpsAction.doctor).phase, OpsPhase.finished);
        expect(c.ops(OpsAction.doctor).lines, ['a', 'b', 'c']);
      },
    );

    test('coming back while the paused loop is still unwinding still '
        're-attaches', () async {
      final steps = <Completer<void>>[];
      final rest = _server()
        ..posts['ops/doctor'] = {'ok': true, 'name': 'doctor'};
      rest.statusQueue.addAll([
        _status(exitCode: 0),
        _status(running: true, lines: ['=== doctor started t ===', 'a']),
      ]);
      ServerDiagnosticsController? controller;
      Future<void>? resumed;
      final c = ServerDiagnosticsController(
        scope: scope,
        repoFor: (profile) => _ResumeWhileUnwinding(
          rest: rest,
          profile: profile,
          sleep: (_) {
            final gate = Completer<void>();
            steps.add(gate);
            return gate.future;
          },
          // The old loop has seen the pause and returned, but the controller
          // has not cleaned it up yet: the screen comes back right here.
          onUnwinding: () {
            rest.statusQueue.addAll([
              _status(
                running: true,
                lines: ['=== doctor started t ===', 'a', 'b'],
              ),
              _status(
                exitCode: 0,
                lines: ['=== doctor started t ===', 'a', 'b', 'c'],
              ),
            ]);
            resumed = controller!.resume();
          },
        ),
        mcpReader: (_) async => const [],
        restartHosts: _hosts,
      );
      controller = c;
      addTearDown(c.dispose);

      unawaited(c.runOps(OpsAction.doctor));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      c.pause();
      steps.last.complete();
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(Duration.zero);
        if (steps.isNotEmpty && !steps.last.isCompleted) {
          steps.last.complete();
        }
      }
      await resumed;
      await Future<void>.delayed(Duration.zero);

      expect(
        c.ops(OpsAction.doctor).phase,
        OpsPhase.finished,
        reason: 'a stale running card must not be left behind',
      );
      expect(c.ops(OpsAction.doctor).lines, ['a', 'b', 'c']);
      expect(rest.mutations, ['POST ops/doctor'], reason: 'nothing relaunched');
    });

    test('dispose mid follow throws nothing and notifies nothing', () async {
      final gate = Completer<void>();
      final rest = _server()
        ..posts['ops/doctor'] = {'ok': true, 'name': 'doctor'};
      rest.statusQueue.addAll([
        _status(exitCode: 0),
        for (var i = 0; i < 5; i++) _status(running: true),
      ]);
      final c = ServerDiagnosticsController(
        scope: scope,
        repoFor: (p) => CapabilitiesRepository(
          rest: rest,
          profile: p,
          sleep: (_) => gate.future,
          actionPollInterval: Duration.zero,
        ),
        mcpReader: (_) async => const [],
        restartHosts: _hosts,
      );
      var notified = 0;
      c.addListener(() => notified++);
      unawaited(c.runOps(OpsAction.doctor));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      c.dispose();
      final before = notified;
      final readsAtDispose = count(rest, 'GET actions/');
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(notified, before);
      expect(
        count(rest, 'GET actions/'),
        readsAtDispose,
        reason: 'nothing is read after dispose',
      );
    });

    test(
      'a 401 mid follow is a sanitized failure and nothing is relaunched',
      () async {
        final rest = _server()
          ..posts['ops/doctor'] = {'ok': true, 'name': 'doctor'};
        rest.statusQueue.add(_status(exitCode: 0));
        // After the launch the status read fails with an auth error.
        rest.gets['actions/doctor/status'] = const DashboardHttpException(401);
        final c = controller(rest);
        await c.runOps(OpsAction.doctor);

        final view = c.ops(OpsAction.doctor);
        expect(view.phase, OpsPhase.failed);
        expect(view.failure, CapabilityFailureKind.forbidden);
        expect(rest.mutations, ['POST ops/doctor']);
      },
    );
  });

  group('profile', () {
    test(
      'a usage answer that lands after a profile switch is dropped',
      () async {
        final rest = _server();
        final gate = Completer<Map<String, dynamic>>();
        final slow = _SlowRest(rest, 'analytics/usage?days=30', gate);
        final c = ServerDiagnosticsController(
          scope: scope,
          repoFor: (profile) => CapabilitiesRepository(
            rest: slow,
            profile: profile,
            sleep: (_) async {},
            actionPollInterval: Duration.zero,
          ),
          mcpReader: (_) async => const [],
          restartHosts: _hosts,
        );
        addTearDown(c.dispose);
        final loading = c.load();
        await Future<void>.delayed(Duration.zero);

        await scope.switchTo('work');
        await Future<void>.delayed(Duration.zero);
        gate.complete(_usage(30, sessions: 99));
        await loading;
        await Future<void>.delayed(Duration.zero);

        expect(c.usage?.totals.sessions, isNot(99));
      },
    );

    test('the new profile is read with its own profile on the wire', () async {
      final rest = _server()
        ..gets['analytics/usage?days=30&profile=work'] = _usage(
          30,
          sessions: 5,
        );
      final c = controller(rest);
      await c.load();
      await scope.switchTo('work');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(rest.calls, contains('GET analytics/usage?days=30&profile=work'));
      expect(c.usage?.totals.sessions, 5);
    });
  });
}

/// Holds back one GET until [gate] completes.
final class _SlowRest implements CapabilitiesRest {
  _SlowRest(this.inner, this.endpoint, this.gate);
  final ScriptedRest inner;
  final String endpoint;
  final Completer<Map<String, dynamic>> gate;

  @override
  Future<Map<String, dynamic>> get(String e) {
    if (e == endpoint) {
      inner.calls.add('GET $e');
      return gate.future;
    }
    return inner.get(e);
  }

  @override
  Future<Map<String, dynamic>> post(
    String e, {
    Map<String, dynamic>? body,
    Duration? timeout,
  }) => inner.post(e, body: body, timeout: timeout);

  @override
  Future<Map<String, dynamic>> put(String e, Map<String, dynamic> b) =>
      inner.put(e, b);

  @override
  Future<void> delete(String e) => inner.delete(e);
}

/// A repository whose `runOps` reports, right after the follow ended on the
/// pause and before returning to the controller, that the screen came back.
final class _ResumeWhileUnwinding extends CapabilitiesRepository {
  _ResumeWhileUnwinding({
    required super.rest,
    required super.profile,
    required super.sleep,
    required this.onUnwinding,
  }) : super(actionPollInterval: Duration.zero);

  final void Function() onUnwinding;

  @override
  Future<CapabilityActionStatus?> runOps(
    OpsAction action, {
    void Function(CapabilityActionStatus)? onProgress,
    bool Function()? shouldStop,
  }) async {
    final result = await super.runOps(
      action,
      onProgress: onProgress,
      shouldStop: shouldStop,
    );
    if (result == null) onUnwinding();
    return result;
  }
}
