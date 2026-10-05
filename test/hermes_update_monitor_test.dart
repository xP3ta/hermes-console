import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/hermes_update_monitor.dart';

/// Seguimiento honesto de `hermes update` lanzado desde Console.
///
/// Incidente real (25/09): la app anunció "Hermes actualizado" ~3 s después
/// del POST (el gateway viejo seguía "running") mientras `hermes update`
/// tardaba ~11 min, y lanzó mantenimiento del bridge en plena actualización.
void main() {
  const ownId = '0123456789abcdef0123456789abcdef';
  const otherId = 'ffffffffffffffffffffffffffffffff';
  final requestedAt = DateTime.utc(2026, 9, 25, 8, 45);
  const oldReceipt = {
    'outcome': 'success',
    'started_at': '2026-09-14T21:07:43+00:00',
    'finished_at': '2026-09-14T21:09:40+00:00',
  };
  Map<String, dynamic> ourReceipt(String outcome, {bool finished = true}) => {
    'outcome': outcome,
    'started_at': '2026-09-25T08:45:10+00:00',
    'finished_at': finished ? '2026-09-25T08:57:00+00:00' : null,
  };

  HermesUpdateActionObservation classify(
    Map<String, dynamic> status, {
    String? id = ownId,
  }) => classifyHermesUpdateAction(
    status,
    actionId: id,
    requestedAt: requestedAt,
  );

  group('classifyHermesUpdateAction', () {
    test('proceso vivo sin marcador: aplicando', () {
      expect(
        classify({
          'running': true,
          'lines': ['→ Fetching updates...'],
        }).phase,
        HermesUpdateActionPhase.running,
      );
    });

    test('own marker while the updater still runs: restarting services', () {
      // hermes update prints the marker before restarting the gateway and
      // the Dashboard; while its process lives the run is not over.
      expect(
        classify({
          'running': true,
          'action_id': ownId,
          'lines': ['=== hermes-update completed $ownId ==='],
          'receipt': ourReceipt('running', finished: false),
        }).phase,
        HermesUpdateActionPhase.restartingServices,
      );
    });

    test('own marker with the updater gone is success at once (Desktop '
        'completedAfterRestart), even without a closed receipt', () {
      for (final exitCode in [null, 0]) {
        final obs = classify({
          'running': false,
          'exit_code': exitCode,
          'action_id': ownId,
          'lines': ['=== hermes-update completed $ownId ==='],
          'receipt': ourReceipt('running', finished: false),
        });
        expect(obs.phase, HermesUpdateActionPhase.succeeded);
        expect(obs.ownMarker, isTrue);
      }
      // Marker only in the log tail (no durable action_id echoed).
      expect(
        classify({
          'running': false,
          'exit_code': null,
          'lines': ['=== hermes-update completed $ownId ==='],
        }).phase,
        HermesUpdateActionPhase.succeeded,
      );
    });

    test('solo el recibo propio cerrado da el resultado', () {
      expect(
        classify({
          'running': false,
          'action_id': ownId,
          'receipt': ourReceipt('success'),
        }).phase,
        HermesUpdateActionPhase.succeeded,
      );
      expect(
        classify({'running': false, 'receipt': ourReceipt('partial')}).phase,
        HermesUpdateActionPhase.partial,
      );
      expect(
        classify({'running': false, 'receipt': ourReceipt('failed')}).phase,
        HermesUpdateActionPhase.failed,
      );
    });

    test('marcador propio con salida no-cero es fallo, no éxito', () {
      expect(
        classify({
          'running': false,
          'exit_code': 1,
          'lines': [
            '=== hermes-update completed $ownId ===',
            '✗ gateway did not come back on the new version',
          ],
        }).phase,
        HermesUpdateActionPhase.failed,
      );
    });

    test('recibo ANTERIOR a la petición no se atribuye', () {
      expect(
        classify({
          'running': false,
          'exit_code': 0,
          'receipt': oldReceipt,
        }).phase,
        HermesUpdateActionPhase.unknown,
      );
    });

    test('id de OTRA ejecución no cuenta', () {
      expect(
        classify({
          'running': false,
          'exit_code': 0,
          'action_id': otherId,
          'lines': ['=== hermes-update completed $otherId ==='],
        }).phase,
        HermesUpdateActionPhase.unknown,
      );
    });

    test('Dashboard recién reiniciado sin datos: desconocido', () {
      expect(
        classify({'running': false, 'exit_code': null}).phase,
        HermesUpdateActionPhase.unknown,
      );
    });

    test('fallo explica la última línea útil', () {
      final obs = classify({
        'running': false,
        'exit_code': 1,
        'lines': [
          '→ Installing dependencies…',
          '✗ uv sync failed: network unreachable',
          '',
          '=== hermes-update started 2026-09-25 09:45:51 ===',
        ],
      });
      expect(obs.phase, HermesUpdateActionPhase.failed);
      expect(obs.detail, '✗ uv sync failed: network unreachable');
    });

    test('servidor antiguo sin id ni recibos: salida 0 del proceso', () {
      expect(
        classify({'running': false, 'exit_code': 0}, id: null).phase,
        HermesUpdateActionPhase.succeeded,
      );
    });
  });

  group('HermesUpdateSession', () {
    setUp(HermesUpdateSession.debugReset);

    test('reserva única por instancia y liberación al abandonar', () async {
      final a = HermesUpdateSession.reserve('a', previousVersion: '0.21.4');
      expect(a, isNotNull);
      expect(HermesUpdateGuard.isActive('a'), isTrue);
      expect(HermesUpdateGuard.isActive('b'), isFalse);
      expect(
        HermesUpdateSession.reserve('a', previousVersion: '0.21.4'),
        isNull,
      );
      a!.abandon(const HermesUpdateResult(HermesUpdateOutcome.failed));
      expect((await a.result).outcome, HermesUpdateOutcome.failed);
      expect(HermesUpdateGuard.isActive('a'), isFalse);
    });

    test('REGRESIÓN 25/09: no confirma hasta el recibo cerrado aunque el '
        'gateway viejo esté running desde el principio', () async {
      final session = HermesUpdateSession.reserve(
        'a',
        previousVersion: '0.21.4',
        now: requestedAt,
      )!..actionId = ownId;
      final script = <Map<String, dynamic>>[
        {'running': true, 'lines': <String>[]},
        {'running': true, 'lines': <String>[]},
        {
          'running': true,
          'lines': ['=== hermes-update completed $ownId ==='],
        },
        // Dashboard reiniciado: el updater sigue (KillMode=process).
        {
          'running': false,
          'action_id': ownId,
          'receipt': ourReceipt('running', finished: false),
        },
        {
          'running': false,
          'action_id': ownId,
          'receipt': ourReceipt('success'),
        },
      ];
      var polls = 0;
      var statusCalls = 0;
      final result = await session.track(
        HermesUpdateProbes(
          actionStatus: () async => script[polls++],
          serverStatus: () async {
            statusCalls++;
            return {'gateway_running': true, 'version': '0.21.5'};
          },
          updateStillAvailable: () async => false,
        ),
        pollInterval: Duration.zero,
      );
      expect(result.outcome, HermesUpdateOutcome.confirmed);
      expect(result.version, '0.21.5');
      // The marker with the updater gone settles it; the closed receipt is
      // not needed (Desktop parity).
      expect(polls, script.length - 1);
      // /api/status is only read once the run has a result.
      expect(statusCalls, 1);
      expect(HermesUpdateGuard.isActive('a'), isFalse);
    });

    test('espera a que el gateway vuelva antes de dar el resultado', () async {
      final session = HermesUpdateSession.reserve(
        'a',
        previousVersion: '0.21.4',
        now: requestedAt,
      )!..actionId = ownId;
      var status = 0;
      final result = await session.track(
        HermesUpdateProbes(
          actionStatus: () async => {'receipt': ourReceipt('success')},
          serverStatus: () async => ++status < 3
              ? {'gateway_running': false}
              : {'gateway_running': true, 'version': '0.21.5'},
          updateStillAvailable: () async => null,
        ),
        pollInterval: Duration.zero,
      );
      expect(result.outcome, HermesUpdateOutcome.confirmed);
      expect(status, 3);
    });

    test('receipt success with the gateway down ends partial within the '
        '2 min gateway check, never an endless spinner', () async {
      final t0 = DateTime(2026, 9, 25, 10);
      var now = t0;
      final session = HermesUpdateSession.reserve(
        'a',
        previousVersion: '0.21.4',
        now: requestedAt,
      )!..actionId = ownId;
      var actionPolls = 0;
      final result = await session.track(
        HermesUpdateProbes(
          actionStatus: () async {
            actionPolls++;
            return {'running': false, 'receipt': ourReceipt('success')};
          },
          serverStatus: () async {
            now = now.add(const Duration(seconds: 20));
            return {'gateway_running': false};
          },
          updateStillAvailable: () async => null,
        ),
        pollInterval: Duration.zero,
        clock: () => now,
      );
      expect(result.outcome, HermesUpdateOutcome.partial);
      expect(result.issue, HermesUpdateIssue.gatewayNotConfirmed);
      expect(actionPolls, 1);
      expect(
        now.difference(t0),
        lessThanOrEqualTo(
          hermesUpdateGatewayConfirmWindow + const Duration(seconds: 20),
        ),
      );
      expect(hermesUpdateGatewayConfirmWindow, const Duration(minutes: 2));
      expect(HermesUpdateGuard.isActive('a'), isFalse);
    });

    test('own marker with the gateway down never polls the gateway past '
        'its window', () async {
      final t0 = DateTime(2026, 9, 25, 10);
      var now = t0;
      final session = HermesUpdateSession.reserve(
        'a',
        previousVersion: '0.21.4',
        now: requestedAt,
      )!..actionId = ownId;
      final result = await session.track(
        HermesUpdateProbes(
          actionStatus: () async => {
            'running': false,
            'action_id': ownId,
            'exit_code': 0,
          },
          serverStatus: () async {
            now = now.add(const Duration(seconds: 30));
            return null;
          },
          updateStillAvailable: () async => null,
        ),
        pollInterval: Duration.zero,
        clock: () => now,
      );
      expect(result.outcome, HermesUpdateOutcome.partial);
      expect(result.issue, HermesUpdateIssue.gatewayNotConfirmed);
      expect(now.difference(t0), lessThan(const Duration(minutes: 3)));
    });

    test('el action_id fijado tras arrancar el seguimiento se usa', () async {
      final session = HermesUpdateSession.reserve(
        'a',
        previousVersion: '0.21.4',
        now: requestedAt,
      )!;
      var polls = 0;
      final future = session.track(
        HermesUpdateProbes(
          actionStatus: () async {
            polls++;
            // Before the POST answer the marker cannot be attributed.
            if (polls == 2) session.actionId = ownId;
            return {'running': false, 'action_id': ownId, 'exit_code': null};
          },
          serverStatus: () async => {'gateway_running': true},
          updateStillAvailable: () async => null,
        ),
        pollInterval: Duration.zero,
      );
      expect((await future).outcome, HermesUpdateOutcome.confirmed);
      expect(polls, 2);
    });

    test('recibo partial se comunica como parcial, no como éxito', () async {
      final session = HermesUpdateSession.reserve(
        'a',
        previousVersion: '0.21.4',
        now: requestedAt,
      )!..actionId = ownId;
      final result = await session.track(
        HermesUpdateProbes(
          actionStatus: () async => {'receipt': ourReceipt('partial')},
          serverStatus: () async => {'gateway_running': true},
          updateStillAvailable: () async => false,
        ),
        pollInterval: Duration.zero,
      );
      expect(result.outcome, HermesUpdateOutcome.partial);
    });

    test('updater muerto tras el marcador: verifica por versión', () async {
      final t0 = DateTime(2026, 9, 25, 10);
      var now = t0;
      final session = HermesUpdateSession.reserve(
        'a',
        previousVersion: '0.21.4',
        now: requestedAt,
      )!..actionId = ownId;
      final result = await session.track(
        HermesUpdateProbes(
          actionStatus: () async {
            now = now.add(const Duration(minutes: 1));
            return {
              'running': false,
              'action_id': ownId,
              'receipt': ourReceipt('running', finished: false),
            };
          },
          serverStatus: () async => {
            'gateway_running': true,
            'version': '0.21.5',
          },
          updateStillAvailable: () async => false,
        ),
        pollInterval: Duration.zero,
        clock: () => now,
      );
      expect(result.outcome, HermesUpdateOutcome.confirmed);
      expect(now.difference(t0), lessThan(const Duration(minutes: 10)));
    });

    test('sin endpoint de acciones y sin evidencia: no verificado', () async {
      var now = DateTime(2026, 9, 25, 10);
      final session = HermesUpdateSession.reserve(
        'a',
        previousVersion: '0.21.4',
        now: requestedAt,
      )!;
      final result = await session.track(
        HermesUpdateProbes(
          actionStatus: () async => throw const HermesUpdateEndpointMissing(),
          serverStatus: () async {
            now = now.add(const Duration(seconds: 20));
            return {'gateway_running': true, 'version': '0.21.4'};
          },
          updateStillAvailable: () async => true,
        ),
        pollInterval: Duration.zero,
        clock: () => now,
      );
      expect(result.outcome, HermesUpdateOutcome.unverified);
    });

    test(
      'nada atribuible hasta el límite: no verificado, nunca éxito',
      () async {
        var now = DateTime(2026, 9, 25, 10);
        final session = HermesUpdateSession.reserve(
          'a',
          previousVersion: '0.21.4',
        )!..actionId = ownId;
        final result = await session.track(
          HermesUpdateProbes(
            actionStatus: () async {
              now = now.add(const Duration(minutes: 5));
              return {'running': false, 'receipt': oldReceipt, 'exit_code': 0};
            },
            serverStatus: () async => {
              'gateway_running': true,
              'version': '0.21.5',
            },
            updateStillAvailable: () async => false,
          ),
          pollInterval: Duration.zero,
          clock: () => now,
        );
        expect(result.outcome, HermesUpdateOutcome.unverified);
        expect(HermesUpdateGuard.isActive('a'), isFalse);
      },
    );

    test('Desktop cadence: polls every 1.5–2 s, 6 min cap while the '
        'updater runs, 4 min restart window', () {
      expect(
        hermesUpdatePollInterval,
        greaterThanOrEqualTo(const Duration(milliseconds: 1500)),
      );
      expect(
        hermesUpdatePollInterval,
        lessThanOrEqualTo(const Duration(seconds: 2)),
      );
      expect(hermesUpdateActionMaxDuration, const Duration(minutes: 6));
      expect(hermesUpdateRestartWindow, const Duration(minutes: 4));
    });

    test('status probes failing for 4 min: restart window, then a '
        '"server did not come back" failure', () async {
      final t0 = DateTime(2026, 9, 25, 10);
      var now = t0;
      final session = HermesUpdateSession.reserve(
        'a',
        previousVersion: '0.21.4',
        now: requestedAt,
      )!..actionId = ownId;
      final steps = <HermesUpdateSessionStep>[];
      session.step.addListener(() => steps.add(session.step.value));
      var calls = 0;
      final result = await session.track(
        HermesUpdateProbes(
          actionStatus: () async {
            now = now.add(const Duration(seconds: 30));
            if (++calls == 1) return {'running': true, 'lines': <String>[]};
            throw const SocketException('connection refused');
          },
          serverStatus: () async => null,
          updateStillAvailable: () async => null,
        ),
        pollInterval: Duration.zero,
        clock: () => now,
      );
      expect(result.outcome, HermesUpdateOutcome.failed);
      expect(result.issue, HermesUpdateIssue.serverNoReturn);
      expect(steps, contains(HermesUpdateSessionStep.restarting));
      // First failure at t0+60 s, then the 4 min window.
      final elapsed = now.difference(t0);
      expect(elapsed, greaterThanOrEqualTo(const Duration(minutes: 5)));
      expect(elapsed, lessThan(const Duration(minutes: 6)));
      expect(HermesUpdateGuard.isActive('a'), isFalse);
    });

    test(
      'updater alive past 6 min without a drain: stop as unverified',
      () async {
        final t0 = DateTime(2026, 9, 25, 10);
        var now = t0;
        final session = HermesUpdateSession.reserve(
          'a',
          previousVersion: '0.21.4',
          now: requestedAt,
        )!..actionId = ownId;
        final result = await session.track(
          HermesUpdateProbes(
            actionStatus: () async {
              now = now.add(const Duration(minutes: 1));
              return {
                'running': true,
                'lines': ['→ Installing dependencies…'],
              };
            },
            serverStatus: () async => {'gateway_running': true},
            updateStillAvailable: () async => null,
          ),
          pollInterval: Duration.zero,
          clock: () => now,
        );
        expect(result.outcome, HermesUpdateOutcome.unverified);
        expect(result.issue, HermesUpdateIssue.timedOut);
        expect(
          now.difference(t0),
          lessThanOrEqualTo(const Duration(minutes: 7)),
        );
      },
    );

    test('a gateway drain in the log keeps the long window', () async {
      final t0 = DateTime(2026, 9, 25, 10);
      var now = t0;
      final session = HermesUpdateSession.reserve(
        'a',
        previousVersion: '0.21.4',
        now: requestedAt,
      )!..actionId = ownId;
      final result = await session.track(
        HermesUpdateProbes(
          actionStatus: () async {
            now = now.add(const Duration(minutes: 1));
            if (now.difference(t0) < const Duration(minutes: 20)) {
              return {
                'running': true,
                'lines': [
                  '→ Restarting gateways…',
                  '  → hermes-gateway: draining (up to 1800s)...',
                ],
              };
            }
            return {'running': false, 'receipt': ourReceipt('success')};
          },
          serverStatus: () async => {
            'gateway_running': true,
            'version': '0.21.5',
          },
          updateStillAvailable: () async => null,
        ),
        pollInterval: Duration.zero,
        clock: () => now,
      );
      expect(result.outcome, HermesUpdateOutcome.confirmed);
      expect(
        now.difference(t0),
        greaterThanOrEqualTo(const Duration(minutes: 20)),
      );
    });

    test('la ventana cubre el drenaje máximo del gateway (30 min)', () {
      expect(hermesUpdateMaxDuration, greaterThan(const Duration(minutes: 31)));
    });
  });

  group('runGatewayRestart', () {
    test('only a gateway seen running again is "back"', () async {
      final seen = <String>[];
      final outcome = await runGatewayRestart(
        restart: () async => seen.add('restart'),
        waitUntilBack: () async => true,
        onRequested: () => seen.add('requested'),
      );
      expect(outcome, GatewayRestartOutcome.back);
      expect(seen, ['restart', 'requested']);
    });

    test('a gateway that never came back is not "back"', () async {
      final outcome = await runGatewayRestart(
        restart: () async {},
        waitUntilBack: () async => false,
      );
      expect(outcome, GatewayRestartOutcome.notBack);
    });

    test('an error while waiting is "not back", never success', () async {
      final outcome = await runGatewayRestart(
        restart: () async {},
        waitUntilBack: () async => throw StateError('poll crashed'),
      );
      expect(outcome, GatewayRestartOutcome.notBack);
    });

    test('a failed request is "failed" and never waits', () async {
      var waited = false;
      var requested = false;
      final outcome = await runGatewayRestart(
        restart: () async => throw StateError('401'),
        waitUntilBack: () async => waited = true,
        onRequested: () => requested = true,
      );
      expect(outcome, GatewayRestartOutcome.failed);
      expect(waited, isFalse);
      expect(requested, isFalse);
    });
  });

  group('cableado (fuente)', () {
    final settings = File(
      'lib/core/screens/settings_screen.dart',
    ).readAsStringSync();

    test('Ajustes delega en la sesión y reserva antes del POST', () {
      final apply = settings.substring(
        settings.indexOf('Future<void> _applyUpdate('),
        settings.indexOf('Future<void> _presentHermesUpdate('),
      );
      final reserve = apply.indexOf('HermesUpdateSession.reserve(');
      final post = apply.indexOf('_client.applyUpdate()');
      expect(reserve, greaterThan(0));
      expect(post, greaterThan(reserve));
      expect(apply, contains('session.track('));
      expect(settings, contains('client.getUpdateActionStatus()'));
    });

    test('el bridge solo se mantiene tras confirmar la actualización', () {
      final present = settings.substring(
        settings.indexOf('Future<void> _presentHermesUpdate('),
        settings.indexOf('Future<void> _restartGateway()'),
      );
      final confirmed = present.indexOf('case HermesUpdateOutcome.confirmed');
      final bridge = present.indexOf('BridgeUpdateService.maintainIfEnabled');
      expect(confirmed, greaterThan(0));
      expect(bridge, greaterThan(confirmed));
    });

    test(
      'reiniciar gateway y mantenimiento del bridge respetan el candado',
      () {
        final restart = settings.substring(
          settings.indexOf('Future<void> _restartGateway()'),
          settings.indexOf('Future<void> _migrateConfig()'),
        );
        expect(restart, contains('HermesUpdateGuard.isActive'));
        final chat = File(
          'lib/core/screens/chat_screen.dart',
        ).readAsStringSync();
        final chatRestart = chat.substring(
          chat.indexOf('Future<void> _restartGatewayFromChat()'),
          chat.indexOf('client.restartGateway()'),
        );
        expect(chatRestart, contains('HermesUpdateGuard.isActive'));
        final bridge = File(
          'lib/core/services/bridge_update_service.dart',
        ).readAsStringSync();
        final maintain = bridge.substring(
          bridge.indexOf(
            'static Future<BridgeMaintenanceResult> maintainIfEnabled(',
          ),
          bridge.indexOf('final isEnabled = await'),
        );
        expect(maintain, contains('HermesUpdateGuard.isActive(conn.id)'));
      },
    );
  });
}
