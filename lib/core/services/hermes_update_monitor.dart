import 'dart:async';

import 'package:flutter/foundation.dart';

/// Seguimiento de `hermes update` lanzado desde Console vía Dashboard.
///
/// `POST /api/hermes/update` responde en cuanto LANZA el proceso (devuelve
/// `action_id`). La actualización real tarda minutos: descarga, instala
/// dependencias, imprime `=== hermes-update completed <id> ===` y DESPUÉS
/// reinicia gateway y Dashboard, verifica la flota y cierra su recibo
/// (`receipt.finished_at` + `outcome`). Solo el recibo cerrado prueba el
/// resultado: ni el marcador, ni "el Dashboard responde", ni "el gateway está
/// running". En el incidente del 25/09 el gateway viejo seguía running y la
/// app anunció éxito a los 3 s de una actualización de ~11 min.

/// Tiempo máximo que Console acompaña una actualización. El drenaje del
/// gateway puede esperar hasta ~30 min a turnos en curso (cap de Hermes), así
/// que la ventana debe cubrirlo; pasado este tiempo el resultado se declara
/// "no verificado", nunca éxito.
const Duration hermesUpdateMaxDuration = Duration(minutes: 45);

/// Con nuestro marcador visto, sin proceso vivo y sin recibo cerrado durante
/// este tiempo, el updater murió tras actualizar el código (p. ej. unidad
/// antigua del Dashboard sin `KillMode=process`). Se pasa a verificar por
/// versión en vez de esperar al límite.
const Duration hermesUpdateReceiptGrace = Duration(minutes: 5);

/// Margen para relojes de móvil y servidor desfasados al decidir si un
/// recibo pertenece a esta ejecución.
const Duration _clockSkew = Duration(minutes: 2);

/// Fase observada de la acción `hermes-update`.
enum HermesUpdateActionPhase {
  /// El proceso sigue vivo sin marcador: descarga, dependencias, build.
  running,

  /// El código ya se actualizó (marcador propio) y Hermes está reiniciando
  /// servicios / verificando la flota. Aún no hay resultado.
  restartingServices,

  /// Recibo de esta ejecución cerrado con `success` (o, en servidores sin
  /// recibos ni `action_id`, salida 0 del proceso).
  succeeded,

  /// Recibo cerrado con `partial`: código actualizado pero algún servicio no
  /// quedó verificado con la versión nueva.
  partial,

  /// El proceso o su recibo terminaron con error / rechazo.
  failed,

  /// Sin información atribuible a esta ejecución. Se sigue observando.
  unknown,
}

@immutable
class HermesUpdateActionObservation {
  final HermesUpdateActionPhase phase;

  /// Explicación breve para el usuario (última línea útil del log).
  final String? detail;

  /// Se vio el marcador de fin de NUESTRA ejecución.
  final bool ownMarker;

  /// El proceso `hermes update` sigue vivo según el Dashboard actual.
  final bool processRunning;

  const HermesUpdateActionObservation(
    this.phase, {
    this.detail,
    this.ownMarker = false,
    this.processRunning = false,
  });
}

final RegExp _completedMarker = RegExp(
  r'^=== hermes-update completed ([0-9a-f]{32}) ===$',
);

/// Interpreta `GET /api/actions/hermes-update/status`.
///
/// Orden de autoridad:
///  1. Recibo de ESTA ejecución (empezó tras la petición) y cerrado
///     (`finished_at`): su `outcome` es el resultado.
///  2. Proceso vivo en este Dashboard: en curso. Nunca éxito.
///  3. Salida no-cero del proceso lanzado por este Dashboard: fallo.
///  4. Marcador propio sin recibo cerrado: reiniciando servicios.
///  5. Servidor antiguo (sin `action_id` ni recibos): la salida 0 del proceso.
///  6. Todo lo demás (id de otra ejecución, `exit_code` derivado de un recibo
///     antiguo, Dashboard recién reiniciado sin datos): sin resultado.
HermesUpdateActionObservation classifyHermesUpdateAction(
  Map<String, dynamic> status, {
  required String? actionId,
  required DateTime requestedAt,
}) {
  final lines = <String>[
    for (final line in (status['lines'] as List<dynamic>? ?? const []))
      line.toString(),
  ];
  final ownId = (actionId ?? '').trim();
  final reportedId = (status['action_id'] ?? '').toString().trim();
  final running = status['running'] == true;

  var ownMarker = false;
  if (ownId.isNotEmpty) {
    ownMarker = reportedId == ownId;
    if (!ownMarker) {
      for (final line in lines) {
        final match = _completedMarker.firstMatch(line.trim());
        if (match != null && match.group(1) == ownId) {
          ownMarker = true;
          break;
        }
      }
    }
  }
  final detail = lastMeaningfulUpdateLine(lines);

  final receipt = status['receipt'];
  final receiptIsOurs = receipt is Map && _receiptIsOurs(receipt, requestedAt);
  if (receiptIsOurs) {
    final finished = (receipt['finished_at'] ?? '').toString().trim();
    if (finished.isNotEmpty) {
      final phase = switch ((receipt['outcome'] ?? '').toString()) {
        'success' => HermesUpdateActionPhase.succeeded,
        'partial' => HermesUpdateActionPhase.partial,
        'failed' || 'refused' => HermesUpdateActionPhase.failed,
        _ => HermesUpdateActionPhase.unknown,
      };
      if (phase != HermesUpdateActionPhase.unknown) {
        return HermesUpdateActionObservation(
          phase,
          detail: detail,
          ownMarker: ownMarker,
          processRunning: running,
        );
      }
    }
  }

  if (running) {
    return HermesUpdateActionObservation(
      ownMarker
          ? HermesUpdateActionPhase.restartingServices
          : HermesUpdateActionPhase.running,
      ownMarker: ownMarker,
      processRunning: true,
    );
  }

  // Id de otra ejecución: nada de lo que diga su exit_code es nuestro.
  if (ownId.isNotEmpty && reportedId.isNotEmpty && reportedId != ownId) {
    return const HermesUpdateActionObservation(HermesUpdateActionPhase.unknown);
  }

  final exitCode = status['exit_code'];
  final receiptPredates = receipt is Map && !receiptIsOurs;
  if (exitCode is int && exitCode != 0 && !receiptPredates) {
    return HermesUpdateActionObservation(
      HermesUpdateActionPhase.failed,
      detail: detail,
      ownMarker: ownMarker,
    );
  }

  if (ownMarker) {
    return const HermesUpdateActionObservation(
      HermesUpdateActionPhase.restartingServices,
      ownMarker: true,
    );
  }

  if (ownId.isEmpty && receipt == null && exitCode == 0) {
    return const HermesUpdateActionObservation(
      HermesUpdateActionPhase.succeeded,
    );
  }
  return const HermesUpdateActionObservation(HermesUpdateActionPhase.unknown);
}

bool _receiptIsOurs(Map<dynamic, dynamic> receipt, DateTime requestedAt) {
  final started = DateTime.tryParse((receipt['started_at'] ?? '').toString());
  if (started == null) return false;
  return !started.isBefore(requestedAt.toUtc().subtract(_clockSkew));
}

/// Última línea con contenido del log, sin marcadores internos ni ruido de
/// assets. Se usa solo para explicar un fallo.
String? lastMeaningfulUpdateLine(List<String> lines) {
  for (final raw in lines.reversed) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('===')) continue;
    if (line.contains('web_dist/assets')) continue;
    return line.length > 240 ? '${line.substring(0, 240)}…' : line;
  }
  return null;
}

// ── Sesión de actualización (independiente de la pantalla) ─────────────────

/// Paso visible de una actualización en curso.
enum HermesUpdateSessionStep { requesting, applying, restarting, verifying }

/// Resultado final.
enum HermesUpdateOutcome {
  /// Recibo `success` (o versión nueva probada en servidores sin recibos) y
  /// gateway de vuelta.
  confirmed,

  /// Código actualizado, pero Hermes no pudo verificar todos los servicios.
  partial,

  /// Sin prueba suficiente. Nunca se presenta como éxito.
  unverified,

  /// La actualización falló o fue rechazada.
  failed,
}

@immutable
class HermesUpdateResult {
  final HermesUpdateOutcome outcome;
  final String? detail;
  final String? version;

  const HermesUpdateResult(this.outcome, {this.detail, this.version});
}

/// El servidor no tiene `/api/actions/hermes-update/status` (404).
class HermesUpdateEndpointMissing implements Exception {
  const HermesUpdateEndpointMissing();
}

/// Fuentes de datos de la sesión (inyectables en tests).
@immutable
class HermesUpdateProbes {
  /// `GET /api/actions/hermes-update/status`; lanza
  /// [HermesUpdateEndpointMissing] si no existe.
  final Future<Map<String, dynamic>> Function() actionStatus;

  /// `/api/status` público, o null si no responde.
  final Future<Map<String, dynamic>?> Function() serverStatus;

  /// `update_available` de `/api/hermes/update/check?force=true`, o null.
  final Future<bool?> Function() updateStillAvailable;

  const HermesUpdateProbes({
    required this.actionStatus,
    required this.serverStatus,
    required this.updateStillAvailable,
  });
}

/// Una actualización en curso de una instancia. Vive FUERA de los widgets:
/// si el usuario sale de Ajustes el seguimiento continúa, la instancia se
/// libera en cuanto hay resultado y al volver se muestra el mismo progreso.
///
/// Mientras existe, [isActive] impide que la app reinicie el gateway, lance
/// otra actualización o mantenga el bridge de esa instancia: reiniciar el
/// gateway a mitad de `hermes update` lo arranca con dependencias a medio
/// instalar.
class HermesUpdateSession {
  HermesUpdateSession._({
    required this.connectionId,
    required this.requestedAt,
    required this.previousVersion,
  });

  static final Map<String, HermesUpdateSession> _sessions = {};

  final String connectionId;
  final DateTime requestedAt;
  final String previousVersion;

  /// `action_id` de Hermes; llega con la respuesta del POST. Se relee en
  /// cada sondeo, así que puede fijarse después de arrancar [track].
  String? actionId;

  /// El POST llegó a responder (false si el socket se cortó / timeout).
  bool responseConfirmed = true;

  final ValueNotifier<HermesUpdateSessionStep> step = ValueNotifier(
    HermesUpdateSessionStep.requesting,
  );
  final DateTime _createdAt = DateTime.now();
  final Completer<HermesUpdateResult> _result = Completer();
  bool _tracking = false;

  Future<HermesUpdateResult> get result => _result.future;
  bool get isFinished => _result.isCompleted;
  int get elapsedSeconds => DateTime.now().difference(_createdAt).inSeconds;

  /// Sesión sin terminar de la instancia.
  static HermesUpdateSession? of(String connectionId) {
    final session = _sessions[connectionId];
    if (session == null || session.isFinished) return null;
    return session;
  }

  static bool isActive(String connectionId) => of(connectionId) != null;

  /// Reserva la instancia ANTES del POST. Null si ya hay otra en curso.
  static HermesUpdateSession? reserve(
    String connectionId, {
    required String previousVersion,
    DateTime? now,
  }) {
    if (isActive(connectionId)) return null;
    final session = HermesUpdateSession._(
      connectionId: connectionId,
      requestedAt: now ?? DateTime.now(),
      previousVersion: previousVersion,
    );
    _sessions[connectionId] = session;
    return session;
  }

  /// El POST falló o fue rechazado: libera la instancia con ese resultado.
  void abandon(HermesUpdateResult result) => _finish(result);

  void _finish(HermesUpdateResult result) {
    if (!_result.isCompleted) _result.complete(result);
    if (identical(_sessions[connectionId], this)) {
      _sessions.remove(connectionId);
    }
  }

  /// Arranca el seguimiento (idempotente) y devuelve el resultado final.
  Future<HermesUpdateResult> track(
    HermesUpdateProbes probes, {
    Duration pollInterval = const Duration(seconds: 4),
    Duration maxDuration = hermesUpdateMaxDuration,
    Duration receiptGrace = hermesUpdateReceiptGrace,
    Duration legacyGrace = const Duration(seconds: 45),
    DateTime Function()? clock,
  }) {
    if (!_tracking && !isFinished) {
      _tracking = true;
      _run(
        probes,
        pollInterval: pollInterval,
        maxDuration: maxDuration,
        receiptGrace: receiptGrace,
        legacyGrace: legacyGrace,
        clock: clock ?? DateTime.now,
      ).then(
        _finish,
        onError: (Object e) => _finish(
          HermesUpdateResult(HermesUpdateOutcome.unverified, detail: '$e'),
        ),
      );
    }
    return result;
  }

  Future<HermesUpdateResult> _run(
    HermesUpdateProbes probes, {
    required Duration pollInterval,
    required Duration maxDuration,
    required Duration receiptGrace,
    required Duration legacyGrace,
    required DateTime Function() clock,
  }) async {
    final deadline = clock().add(maxDuration);
    var missingEndpoint = 0;
    // Sin recibo utilizable: verificación por versión y `update_available`.
    DateTime? versionCheckSince;
    DateTime? markerWithoutProcessSince;
    step.value = HermesUpdateSessionStep.applying;

    while (clock().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);

      HermesUpdateOutcome? receiptOutcome;
      String? detail;
      if (versionCheckSince == null) {
        HermesUpdateActionObservation? obs;
        try {
          obs = classifyHermesUpdateAction(
            await probes.actionStatus(),
            actionId: actionId,
            requestedAt: requestedAt,
          );
          missingEndpoint = 0;
        } on HermesUpdateEndpointMissing {
          if (++missingEndpoint >= 3) versionCheckSince = clock();
        } catch (_) {
          // Dashboard reiniciándose, 401 por sesión rotada, 502…: normal.
        }
        detail = obs?.detail;
        switch (obs?.phase) {
          case HermesUpdateActionPhase.failed:
            return HermesUpdateResult(
              HermesUpdateOutcome.failed,
              detail: obs?.detail,
            );
          case HermesUpdateActionPhase.succeeded:
            receiptOutcome = HermesUpdateOutcome.confirmed;
          case HermesUpdateActionPhase.partial:
            receiptOutcome = HermesUpdateOutcome.partial;
          case HermesUpdateActionPhase.restartingServices:
            step.value = HermesUpdateSessionStep.restarting;
            if (!obs!.processRunning) {
              markerWithoutProcessSince ??= clock();
              if (clock().difference(markerWithoutProcessSince) >=
                  receiptGrace) {
                versionCheckSince = clock();
              }
            } else {
              markerWithoutProcessSince = null;
            }
          case HermesUpdateActionPhase.running:
            step.value = HermesUpdateSessionStep.applying;
            markerWithoutProcessSince = null;
          case HermesUpdateActionPhase.unknown:
          case null:
            break;
        }
        if (receiptOutcome == null && versionCheckSince == null) continue;
      }

      // Verificación final: gateway de vuelta.
      step.value = HermesUpdateSessionStep.verifying;
      final status = await probes.serverStatus();
      final gatewayRunning =
          status != null &&
          (status['gateway_running'] == true ||
              status['gateway_state'] == 'running');
      if (!gatewayRunning) {
        step.value = HermesUpdateSessionStep.restarting;
        continue;
      }
      final version = (status['version'] ?? '').toString().trim();
      if (receiptOutcome != null) {
        return HermesUpdateResult(
          receiptOutcome,
          detail: detail,
          version: version,
        );
      }
      final stillAvailable = await probes.updateStillAvailable();
      final versionChanged =
          previousVersion.isNotEmpty &&
          version.isNotEmpty &&
          version != previousVersion;
      if (stillAvailable == false ||
          (versionChanged && stillAvailable != true)) {
        return HermesUpdateResult(
          HermesUpdateOutcome.confirmed,
          version: version,
        );
      }
      if (clock().difference(versionCheckSince!) >= legacyGrace) {
        return HermesUpdateResult(
          HermesUpdateOutcome.unverified,
          version: version,
        );
      }
    }
    return const HermesUpdateResult(HermesUpdateOutcome.unverified);
  }

  @visibleForTesting
  static void debugReset() => _sessions.clear();
}

/// Fachada usada por el resto de la app para respetar una actualización en
/// curso sin depender de la pantalla que la lanzó.
abstract final class HermesUpdateGuard {
  static bool isActive(String connectionId) =>
      HermesUpdateSession.isActive(connectionId);
}
