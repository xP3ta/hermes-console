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

    test('REGRESIÓN: el marcador propio NO es éxito (faltan reinicios)', () {
      // hermes update imprime el marcador ANTES de reiniciar gateway y
      // Dashboard y de verificar la flota.
      for (final running in [true, false]) {
        expect(
          classify({
            'running': running,
            'action_id': ownId,
            'lines': ['=== hermes-update completed $ownId ==='],
            'receipt': ourReceipt('running', finished: false),
          }).phase,
          HermesUpdateActionPhase.restartingServices,
        );
      }
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
      expect(polls, script.length);
      // /api/status solo se consulta tras el recibo cerrado.
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
            if (polls == 2) session.actionId = ownId;
            return {
              'running': false,
              'action_id': ownId,
              'exit_code': polls > 2 ? 1 : null,
            };
          },
          serverStatus: () async => {'gateway_running': true},
          updateStillAvailable: () async => null,
        ),
        pollInterval: Duration.zero,
      );
      expect((await future).outcome, HermesUpdateOutcome.failed);
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

    test('la ventana cubre el drenaje máximo del gateway (30 min)', () {
      expect(hermesUpdateMaxDuration, greaterThan(const Duration(minutes: 31)));
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
