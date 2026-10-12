import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/companion_mood.dart';

/// Eventos de app que afectan al ánimo de la presencia (feature 006).
enum PresenceEvent {
  appOpened,
  messageSent,
  approvalNeeded,
  responseCompleted,
  runFailed,
  petTapped,
}

/// Estado de conexión simplificado para la presencia (la capa de cableado
/// traduce el estado real de la app a esto, para no acoplar el controller).
enum PresenceConnection { online, connecting, offline }

/// Fuente **central** de ánimo del Companion (feature 006). Traduce eventos de
/// app + estado de conexión a un [CompanionMood], reutilizando el mapeo
/// `companionStateForMood` existente (sin estados/animaciones nuevos).
///
/// Modelo de "overlay":
/// - **Base** (persistente): `approval`(waiting) > `run`(thinking) > conexión
///   (offline/connecting) > `idle`.
/// - **Transitorio** (one-shot con decay): `success`/`error`/saludo, que se
///   muestra **encima** de la base durante una duración y luego se disuelve.
///
/// Prioridad efectiva: error(transitorio) > approval(waiting) > thinking >
/// connecting/offline > success(transitorio) > idle.
///
/// Sin red, sin IA, sin voz. Decay con [Timer]; `replayToken` reinicia one-shots.
class CompanionPresenceController extends ChangeNotifier {
  CompanionPresenceController({
    this.successDuration = const Duration(milliseconds: 1200),
    this.errorDuration = const Duration(milliseconds: 2500),
    this.greetDuration = const Duration(milliseconds: 1200),
    this.jumpDuration = const Duration(milliseconds: 700),
  });

  /// Duración del overlay `success` antes de disolverse (D5: ~1.2 s).
  final Duration successDuration;

  /// Duración del overlay `error` (D5: ~2.5 s).
  final Duration errorDuration;

  /// Duración del saludo (tap / appOpened).
  final Duration greetDuration;

  /// Duración del gesto de salto (al enviar un mensaje) antes de pasar a pensar.
  final Duration jumpDuration;

  // --- estado base (persistente) ---
  PresenceConnection _connection = PresenceConnection.online;
  bool _runActive = false; // entre messageSent y responseCompleted/failed
  bool _approvalPending = false; // entre approvalNeeded y resolución

  // --- overlay transitorio ---
  CompanionMood? _transient; // success | error
  Timer? _decayTimer;
  int _replayToken = 0;

  /// Ánimo actual resuelto por prioridad.
  CompanionMood get mood {
    final overlay = _transient;
    if (overlay == CompanionMood.error) return CompanionMood.error;
    if (_approvalPending) return CompanionMood.waiting;
    // Salto breve al enviar: se muestra por encima de "pensando" y decae a él.
    if (overlay == CompanionMood.jump) return CompanionMood.jump;
    if (_runActive) return CompanionMood.thinking;
    if (overlay == CompanionMood.success) return CompanionMood.success;
    switch (_connection) {
      case PresenceConnection.offline:
        return CompanionMood.offline;
      case PresenceConnection.connecting:
        return CompanionMood.connecting;
      case PresenceConnection.online:
        return CompanionMood.idle;
    }
  }

  /// Token para reiniciar animaciones one-shot (wave/failed) en el render.
  int get replayToken => _replayToken;

  /// Actualiza el estado de conexión (la presencia lo refleja como base).
  void setConnectionStatus(PresenceConnection status) {
    if (_connection == status) return;
    _connection = status;
    _emit();
  }

  /// Procesa un evento de app.
  void onEvent(PresenceEvent event) {
    switch (event) {
      case PresenceEvent.appOpened:
      case PresenceEvent.petTapped:
        _setTransient(CompanionMood.success, greetDuration);
        break;
      case PresenceEvent.messageSent:
        _runActive = true;
        // Gesto de salto breve que luego revela "pensando" (run).
        _setTransient(CompanionMood.jump, jumpDuration);
        break;
      case PresenceEvent.approvalNeeded:
        _approvalPending = true;
        _clearTransient();
        _emit();
        break;
      case PresenceEvent.responseCompleted:
        _runActive = false;
        _approvalPending = false;
        _setTransient(CompanionMood.success, successDuration);
        break;
      case PresenceEvent.runFailed:
        _runActive = false;
        _approvalPending = false;
        _setTransient(CompanionMood.error, errorDuration);
        break;
    }
  }

  void _setTransient(CompanionMood overlay, Duration duration) {
    _transient = overlay;
    _replayToken++; // reinicia el one-shot en el render
    _decayTimer?.cancel();
    _decayTimer = Timer(duration, () {
      _transient = null;
      _emit();
    });
    _emit();
  }

  void _clearTransient() {
    _decayTimer?.cancel();
    _decayTimer = null;
    _transient = null;
  }

  CompanionMood _lastEmitted = CompanionMood.idle;

  void _emit() {
    final next = mood;
    // Debounce: no notifica si el ánimo resuelto no cambió (anti-parpadeo).
    if (next == _lastEmitted && _transient == null) return;
    _lastEmitted = next;
    notifyListeners();
  }

  /// Solo para tests: disuelve el overlay transitorio de inmediato.
  @visibleForTesting
  void debugSettleTransient() {
    if (_transient != null) {
      _decayTimer?.cancel();
      _decayTimer = null;
      _transient = null;
      _emit();
    }
  }

  @override
  void dispose() {
    _decayTimer?.cancel();
    super.dispose();
  }
}
