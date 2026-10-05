import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
///
/// Like Desktop, our marker with the updater process gone also settles the
/// run; whether the gateway came back is checked afterwards.

/// Tiempo máximo que Console acompaña una actualización. El drenaje del
/// gateway puede esperar hasta ~30 min a turnos en curso (cap de Hermes), así
/// que la ventana debe cubrirlo; pasado este tiempo el resultado se declara
/// "no verificado", nunca éxito.
const Duration hermesUpdateMaxDuration = Duration(minutes: 45);

/// Status poll cadence (Desktop `BACKEND_ACTION_POLL_MS` is 1.5 s).
const Duration hermesUpdatePollInterval = Duration(seconds: 2);

/// Cap while the updater runs and its log shows no gateway drain (Desktop
/// `BACKEND_ACTION_MAX_MS`). A drain keeps [hermesUpdateMaxDuration].
const Duration hermesUpdateActionMaxDuration = Duration(minutes: 6);

/// After the status endpoint stops answering (the Dashboard restarts), how
/// long Console waits for it to come back (Desktop `BACKEND_RETURN_MAX_MS`).
const Duration hermesUpdateRestartWindow = Duration(minutes: 4);

/// Once the run has a result, how long Console waits for the gateway to
/// report running again. Past it the result is "code updated, gateway not
/// confirmed" ([HermesUpdateIssue.gatewayNotConfirmed]), never a spinner.
const Duration hermesUpdateGatewayConfirmWindow = Duration(minutes: 2);

/// Margen para relojes de móvil y servidor desfasados al decidir si un
/// recibo pertenece a esta ejecución (Desktop uses 60 s; [requestedAt] is the
/// server's own clock when the POST answer carried a `Date` header).
const Duration _clockSkew = Duration(seconds: 60);

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
///  4. Own marker with the updater gone: success (Desktop parity); the
///     gateway is confirmed afterwards as a separate, bounded step.
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

  // Our marker with the updater gone settles the run, like Desktop's
  // `completedAfterRestart`: the gateway check that follows is separate.
  if (ownMarker) {
    return HermesUpdateActionObservation(
      HermesUpdateActionPhase.succeeded,
      detail: detail,
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

final RegExp _gatewayDrainLine = RegExp(r'\bdrain', caseSensitive: false);

/// The updater is draining a gateway (`→ <label>: draining (up to Ns)...`),
/// which may legitimately wait for running turns up to Hermes' drain cap.
bool _logShowsGatewayDrain(Map<String, dynamic> status) {
  for (final line in (status['lines'] as List<dynamic>? ?? const [])) {
    final text = line.toString().trim();
    if (text.startsWith('===')) continue;
    if (_gatewayDrainLine.hasMatch(text)) return true;
  }
  return false;
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

/// Why a result is not a plain success or failure.
enum HermesUpdateIssue {
  /// The update finished but the gateway was not seen running again within
  /// [hermesUpdateGatewayConfirmWindow].
  gatewayNotConfirmed,

  /// The status endpoint stopped answering and did not come back within
  /// [hermesUpdateRestartWindow].
  serverNoReturn,

  /// Nothing attributable to this run before the deadline.
  timedOut,
}

@immutable
class HermesUpdateResult {
  final HermesUpdateOutcome outcome;
  final String? detail;
  final String? version;
  final HermesUpdateIssue? issue;

  const HermesUpdateResult(
    this.outcome, {
    this.detail,
    this.version,
    this.issue,
  });
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
    required DateTime requestedAt,
    required this.previousVersion,
  }) : _requestedAt = requestedAt.toUtc();

  /// SharedPreferences key prefix of the persisted session of a connection
  /// (`<prefix><connectionId>`). Holds no chat data: ids, times, version.
  static const String prefsPrefix = 'hermes_update_session_v1.';

  /// A persisted record older than this is not resumed: no update runs for
  /// hours, so it can only be a leftover.
  static const Duration _resumeHorizon = Duration(hours: 6);

  static final Map<String, HermesUpdateSession> _sessions = {};

  /// App-wide reconnect of the gateway sockets of a connection, set by the
  /// app shell. Fired once when an update ends with updated code: the
  /// restarted gateway strands the old sockets (often half-open over
  /// tunnels), like Desktop's `reconnectGateway()` after a backend update.
  static void Function(String connectionId)? reconnectGateway;

  final String connectionId;
  final String previousVersion;

  /// When this run was requested, on the server clock when known (see
  /// [adoptServerTime]). Receipts that started before it (minus a 60 s
  /// margin) belong to an earlier run.
  DateTime get requestedAt => _requestedAt;
  DateTime _requestedAt;

  /// The POST answered `already_running`: this session follows a run that
  /// started before our request.
  bool get attachedToRunningUpdate => _attachedToRunningUpdate;
  set attachedToRunningUpdate(bool value) {
    _attachedToRunningUpdate = value;
    _persist();
  }

  bool _attachedToRunningUpdate = false;

  /// Anchors [requestedAt] on the server clock of the POST answer, so a
  /// phone clock running ahead does not disown our own receipt.
  void adoptServerTime(DateTime? serverDate) {
    if (serverDate == null) return;
    _requestedAt = serverDate.toUtc();
    _persist();
  }

  /// Attached to a run already in progress: its own receipt, open while the
  /// updater lives, tells when it started; adopt that as the request time.
  void _adoptAttachedRunStart(Map<String, dynamic> status) {
    final receipt = status['receipt'];
    if (status['running'] != true || receipt is! Map) return;
    if ((receipt['finished_at'] ?? '').toString().trim().isNotEmpty) return;
    final started = DateTime.tryParse((receipt['started_at'] ?? '').toString());
    if (started == null || !started.isBefore(_requestedAt)) return;
    _requestedAt = started.toUtc();
    _persist();
  }

  /// `action_id` de Hermes; llega con la respuesta del POST. Se relee en
  /// cada sondeo, así que puede fijarse después de arrancar [track].
  String? get actionId => _actionId;
  set actionId(String? value) {
    _actionId = value;
    _persist();
  }

  String? _actionId;

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
    session._persist();
    return session;
  }

  /// El POST falló o fue rechazado: libera la instancia con ese resultado.
  void abandon(HermesUpdateResult result) => _finish(result);

  void _finish(HermesUpdateResult result) {
    if (!_result.isCompleted) _result.complete(result);
    if (identical(_sessions[connectionId], this)) {
      _sessions.remove(connectionId);
      _store((prefs) => prefs.remove('$prefsPrefix$connectionId'));
    }
  }

  // ── Persistence: survive Android killing the process ───────────────────

  static Future<void> _storeTail = Future<void>.value();

  /// Serializes every write so a late save never lands after the clear.
  static Future<void> _store(
    Future<Object?> Function(SharedPreferences prefs) write,
  ) {
    final next = _storeTail.then((_) async {
      try {
        await write(await SharedPreferences.getInstance());
      } catch (error) {
        debugPrint('[hermes-update] store failed (${error.runtimeType})');
      }
    });
    _storeTail = next;
    return next;
  }

  void _persist() {
    if (isFinished || !identical(_sessions[connectionId], this)) return;
    final record = jsonEncode({
      'connectionId': connectionId,
      'actionId': _actionId,
      'requestedAt': _requestedAt.toIso8601String(),
      'previousVersion': previousVersion,
      'attached': _attachedToRunningUpdate,
    });
    _store((prefs) => prefs.setString('$prefsPrefix$connectionId', record));
  }

  static HermesUpdateSession? _decode(String connectionId, String? raw) {
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map || data['connectionId'] != connectionId) return null;
      final requestedAt = DateTime.tryParse('${data['requestedAt']}');
      final previousVersion = data['previousVersion'];
      final actionId = data['actionId'];
      if (requestedAt == null || previousVersion is! String) return null;
      if (actionId != null &&
          (actionId is! String ||
              !RegExp(r'^[0-9a-f]{32}$').hasMatch(actionId))) {
        return null;
      }
      return HermesUpdateSession._(
          connectionId: connectionId,
          requestedAt: requestedAt,
          previousVersion: previousVersion,
        )
        .._actionId = actionId as String?
        .._attachedToRunningUpdate = data['attached'] == true;
    } on FormatException {
      return null;
    }
  }

  /// Arranca el seguimiento (idempotente) y devuelve el resultado final.
  Future<HermesUpdateResult> track(
    HermesUpdateProbes probes, {
    Duration pollInterval = hermesUpdatePollInterval,
    Duration maxDuration = hermesUpdateMaxDuration,
    Duration actionMaxDuration = hermesUpdateActionMaxDuration,
    Duration restartWindow = hermesUpdateRestartWindow,
    Duration legacyGrace = const Duration(seconds: 45),
    Duration gatewayConfirmWindow = hermesUpdateGatewayConfirmWindow,
    DateTime Function()? clock,
    void Function(String connectionId)? reconnect,
  }) {
    if (!_tracking && !isFinished) {
      _tracking = true;
      _run(
        probes,
        pollInterval: pollInterval,
        maxDuration: maxDuration,
        actionMaxDuration: actionMaxDuration,
        restartWindow: restartWindow,
        legacyGrace: legacyGrace,
        gatewayConfirmWindow: gatewayConfirmWindow,
        clock: clock ?? DateTime.now,
      ).then(
        (result) {
          // Only the first track() runs this, so the reconnect fires once.
          if (result.outcome == HermesUpdateOutcome.confirmed ||
              result.outcome == HermesUpdateOutcome.partial) {
            try {
              (reconnect ?? reconnectGateway)?.call(connectionId);
            } catch (error) {
              debugPrint(
                '[hermes-update] reconnect failed (${error.runtimeType})',
              );
            }
          }
          _finish(result);
        },
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
    required Duration actionMaxDuration,
    required Duration restartWindow,
    required Duration legacyGrace,
    required Duration gatewayConfirmWindow,
    required DateTime Function() clock,
  }) async {
    // Desktop deadlines: [actionMaxDuration] while the updater runs, the
    // long [maxDuration] only once its log shows a gateway drain, and
    // [restartWindow] from the first failed status read (the Dashboard
    // restarting) until the updater is seen running again.
    final started = clock();
    var drainSeen = false;
    DateTime? restartUntil;
    var lastReadFailed = false;
    DateTime deadline() =>
        restartUntil ??
        started.add(drainSeen ? maxDuration : actionMaxDuration);
    var missingEndpoint = 0;
    // Sin recibo utilizable: verificación por versión y `update_available`.
    DateTime? versionCheckSince;
    step.value = HermesUpdateSessionStep.applying;

    while (clock().isBefore(deadline())) {
      await Future<void>.delayed(pollInterval);

      if (versionCheckSince == null) {
        HermesUpdateActionObservation? obs;
        try {
          final raw = await probes.actionStatus();
          lastReadFailed = false;
          if (!drainSeen && _logShowsGatewayDrain(raw)) drainSeen = true;
          if (attachedToRunningUpdate) _adoptAttachedRunStart(raw);
          obs = classifyHermesUpdateAction(
            raw,
            actionId: actionId,
            requestedAt: requestedAt,
          );
          missingEndpoint = 0;
        } on HermesUpdateEndpointMissing {
          lastReadFailed = false;
          if (++missingEndpoint >= 3) versionCheckSince = clock();
        } catch (_) {
          // Dashboard reiniciándose, 401 por sesión rotada, 502…: normal,
          // but only for [restartWindow].
          lastReadFailed = true;
          if (restartUntil == null) {
            restartUntil = clock().add(restartWindow);
            step.value = HermesUpdateSessionStep.restarting;
          }
        }
        switch (obs?.phase) {
          case HermesUpdateActionPhase.failed:
            return HermesUpdateResult(
              HermesUpdateOutcome.failed,
              detail: obs?.detail,
            );
          case HermesUpdateActionPhase.succeeded:
            return _confirmGateway(
              probes,
              HermesUpdateOutcome.confirmed,
              detail: obs?.detail,
              pollInterval: pollInterval,
              window: gatewayConfirmWindow,
              clock: clock,
            );
          case HermesUpdateActionPhase.partial:
            return _confirmGateway(
              probes,
              HermesUpdateOutcome.partial,
              detail: obs?.detail,
              pollInterval: pollInterval,
              window: gatewayConfirmWindow,
              clock: clock,
            );
          case HermesUpdateActionPhase.restartingServices:
            step.value = HermesUpdateSessionStep.restarting;
            restartUntil = null;
          case HermesUpdateActionPhase.running:
            step.value = HermesUpdateSessionStep.applying;
            restartUntil = null;
          case HermesUpdateActionPhase.unknown:
          case null:
            break;
        }
        if (versionCheckSince == null) continue;
      }

      // Legacy server: no receipt, prove the new version once the gateway
      // is back.
      step.value = HermesUpdateSessionStep.verifying;
      final status = await _serverStatus(probes);
      if (!_gatewayRunning(status)) {
        step.value = HermesUpdateSessionStep.restarting;
        lastReadFailed = status == null;
        if (lastReadFailed) restartUntil ??= clock().add(restartWindow);
        continue;
      }
      lastReadFailed = false;
      restartUntil = null;
      final version = (status!['version'] ?? '').toString().trim();
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
      if (clock().difference(versionCheckSince) >= legacyGrace) {
        return HermesUpdateResult(
          HermesUpdateOutcome.unverified,
          version: version,
        );
      }
    }
    if (lastReadFailed) {
      return const HermesUpdateResult(
        HermesUpdateOutcome.failed,
        issue: HermesUpdateIssue.serverNoReturn,
      );
    }
    return const HermesUpdateResult(
      HermesUpdateOutcome.unverified,
      issue: HermesUpdateIssue.timedOut,
    );
  }

  /// The run is over ([outcome] comes from its receipt or marker); this only
  /// waits, for at most [window], for the gateway to report running again.
  /// If it does not, the code is updated but the gateway is unconfirmed:
  /// a partial result the user can re-check, never an endless wait.
  Future<HermesUpdateResult> _confirmGateway(
    HermesUpdateProbes probes,
    HermesUpdateOutcome outcome, {
    required String? detail,
    required Duration pollInterval,
    required Duration window,
    required DateTime Function() clock,
  }) async {
    step.value = HermesUpdateSessionStep.verifying;
    final until = clock().add(window);
    while (true) {
      final status = await _serverStatus(probes);
      if (_gatewayRunning(status)) {
        return HermesUpdateResult(
          outcome,
          detail: detail,
          version: (status!['version'] ?? '').toString().trim(),
        );
      }
      if (!clock().isBefore(until)) break;
      await Future<void>.delayed(pollInterval);
    }
    return HermesUpdateResult(
      HermesUpdateOutcome.partial,
      detail: detail,
      issue: HermesUpdateIssue.gatewayNotConfirmed,
    );
  }

  static Future<Map<String, dynamic>?> _serverStatus(
    HermesUpdateProbes probes,
  ) async {
    try {
      return await probes.serverStatus();
    } catch (_) {
      return null;
    }
  }

  static bool _gatewayRunning(Map<String, dynamic>? status) =>
      status != null &&
      (status['gateway_running'] == true ||
          status['gateway_state'] == 'running');

  /// Connections with a persisted, unfinished update.
  static Future<List<String>> persistedConnectionIds() async {
    await _storeTail;
    final prefs = await SharedPreferences.getInstance();
    return [
      for (final key in prefs.getKeys())
        if (key.startsWith(prefsPrefix)) key.substring(prefsPrefix.length),
    ];
  }

  /// Rebuilds the session of [connectionId] persisted before the process
  /// died, or returns the live one. Null when there is nothing to resume; an
  /// unreadable or stale record is dropped. The caller starts [track].
  static Future<HermesUpdateSession?> resumePersisted(
    String connectionId, {
    DateTime? now,
  }) async {
    final live = of(connectionId);
    if (live != null) return live;
    await _storeTail;
    final prefs = await SharedPreferences.getInstance();
    final key = '$prefsPrefix$connectionId';
    final restored = _decode(connectionId, prefs.getString(key));
    final raced = of(connectionId);
    if (raced != null) return raced;
    if (restored == null ||
        (now ?? DateTime.now()).toUtc().difference(restored.requestedAt) >
            _resumeHorizon) {
      if (prefs.containsKey(key)) await _store((p) => p.remove(key));
      return null;
    }
    restored.step.value = HermesUpdateSessionStep.applying;
    _sessions[connectionId] = restored;
    return restored;
  }

  /// Drops a persisted record without resuming it (connection deleted).
  static Future<void> discardPersisted(String connectionId) =>
      _store((prefs) => prefs.remove('$prefsPrefix$connectionId'));

  @visibleForTesting
  static Future<void> debugFlushStore() => _storeTail;

  /// Forgets the in-memory sessions only (a killed process).
  @visibleForTesting
  static void debugReset() => _sessions.clear();
}

/// Fachada usada por el resto de la app para respetar una actualización en
/// curso sin depender de la pantalla que la lanzó.
abstract final class HermesUpdateGuard {
  static bool isActive(String connectionId) =>
      HermesUpdateSession.isActive(connectionId);
}

/// Outcome of "Restart gateway": the request itself failed, it was sent but
/// the gateway was never seen running again, or it came back.
enum GatewayRestartOutcome { failed, notBack, back }

/// Sends the restart and waits for the gateway to come back. Only a
/// confirmed return is [GatewayRestartOutcome.back]; the wait's own errors
/// count as not back, never as success.
Future<GatewayRestartOutcome> runGatewayRestart({
  required Future<void> Function() restart,
  required Future<bool> Function() waitUntilBack,
  void Function()? onRequested,
}) async {
  try {
    await restart();
  } catch (_) {
    return GatewayRestartOutcome.failed;
  }
  onRequested?.call();
  try {
    return await waitUntilBack()
        ? GatewayRestartOutcome.back
        : GatewayRestartOutcome.notBack;
  } catch (_) {
    return GatewayRestartOutcome.notBack;
  }
}
