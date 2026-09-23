import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/compaction_progress.dart';

/// Sigue la compactación (automática o manual) de la sesión abierta.
///
/// El chat le pasa cada cambio de estado con [sync]; el tracker mide el tiempo
/// local y conserva el resultado unos segundos tras el fin ([linger]) para que
/// la barra pueda enseñar «Compactado · A → B». No estima nada.
class CompactionTracker extends ChangeNotifier {
  CompactionTracker({
    DateTime Function()? clock,
    this.linger = const Duration(seconds: 3),
    this.settleWait = const Duration(seconds: 3),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// Cuánto se enseña el resultado tras terminar.
  final Duration linger;

  /// Cuánto se espera al resultado de un `/compress` cuya bandera ya se apagó.
  final Duration settleWait;

  CompactionProgress? _current;
  Timer? _lingerTimer;
  Timer? _settleTimer;
  bool _awaitingResult = false;
  bool _disposed = false;

  /// Compactación en curso o recién terminada (dentro del [linger]).
  CompactionProgress? get current => _current;

  /// Compactación todavía en marcha (no terminada).
  bool get running => _current != null && !_current!.isFinished;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Refleja el estado del chat. Idempotente: llamarlo en cada evento es barato.
  void sync({
    required bool active,
    required bool manual,
    DateTime? startedAt,
    int? tokensBefore,
    int? messagesBefore,
    int? chunkIndex,
    int? chunkCount,
  }) {
    if (_disposed) return;
    final now = _clock();
    final current = _current;
    if (active) {
      _settleTimer?.cancel();
      _settleTimer = null;
      _awaitingResult = false;
      if (current == null || current.isFinished) {
        _lingerTimer?.cancel();
        _lingerTimer = null;
        _current = CompactionProgress(
          startedAt: startedAt ?? now,
          manual: manual,
          tokensBefore: tokensBefore,
          messagesBefore: messagesBefore,
          chunkIndex: chunkIndex,
          chunkCount: chunkCount,
        );
        _notify();
        return;
      }
      final knowsMore =
          (tokensBefore != null && tokensBefore != current.tokensBefore) ||
          (messagesBefore != null &&
              messagesBefore != current.messagesBefore) ||
          (chunkIndex != null && chunkIndex != current.chunkIndex) ||
          (chunkCount != null && chunkCount != current.chunkCount) ||
          (manual && !current.manual);
      if (knowsMore) {
        _current = CompactionProgress(
          startedAt: current.startedAt,
          manual: manual || current.manual,
          tokensBefore: tokensBefore ?? current.tokensBefore,
          messagesBefore: messagesBefore ?? current.messagesBefore,
          chunkIndex: chunkIndex ?? current.chunkIndex,
          chunkCount: chunkCount ?? current.chunkCount,
        );
        _notify();
      }
      return;
    }
    if (current == null || current.isFinished) return;
    // La bandera se apagó, pero un final REAL (`compacted`, o el resultado del
    // RPC) suele llegar justo después: se le concede un margen. Sin él (abort,
    // lock_held, `ready`/idle, sesión reiniciada) la barra se retira en silencio:
    // nunca se afirma un éxito que nadie ha reportado.
    if (_awaitingResult) return;
    _awaitingResult = true;
    _settleTimer?.cancel();
    _settleTimer = Timer(settleWait, () {
      _settleTimer = null;
      _awaitingResult = false;
      if (running) _clear();
    });
  }

  /// Resultado numérico exacto de un `session.compress`, o solo el fin de una
  /// compactación cuyo resultado llegó tarde (sin cifras).
  void reportResult({
    int? tokensBefore,
    int? tokensAfter,
    int? messagesBefore,
    int? messagesAfter,
    bool noop = false,
    DateTime? startedAt,
  }) {
    if (_disposed) return;
    var current = _current;
    if (current != null && current.isFinished) return;
    if (current == null) {
      // An outcome learned after the fact (restored compression): the pill
      // still gets its one result frame.
      if (startedAt == null) return;
      current = _current = CompactionProgress(
        startedAt: startedAt,
        manual: true,
      );
    }
    _settleTimer?.cancel();
    _settleTimer = null;
    _awaitingResult = false;
    _finish(
      _clock(),
      tokensBefore: tokensBefore,
      tokensAfter: tokensAfter,
      messagesBefore: messagesBefore,
      messagesAfter: messagesAfter,
      noop: noop,
    );
  }

  void _finish(
    DateTime now, {
    int? tokensBefore,
    int? tokensAfter,
    int? messagesBefore,
    int? messagesAfter,
    bool noop = false,
  }) {
    final current = _current;
    if (current == null) return;
    _current = current.copyWith(
      finishedAt: now,
      tokensBefore: tokensBefore,
      tokensAfter: tokensAfter,
      messagesBefore: messagesBefore,
      messagesAfter: messagesAfter,
      noop: noop,
    );
    _lingerTimer?.cancel();
    _lingerTimer = Timer(linger, () {
      _lingerTimer = null;
      _clear();
    });
    _notify();
  }

  void _clear() {
    _lingerTimer?.cancel();
    _lingerTimer = null;
    _settleTimer?.cancel();
    _settleTimer = null;
    _awaitingResult = false;
    if (_current == null) return;
    _current = null;
    _notify();
  }

  /// Descarta cualquier estado (cambio de sesión, cierre de pantalla).
  void reset() => _clear();

  @override
  void dispose() {
    _disposed = true;
    _lingerTimer?.cancel();
    _settleTimer?.cancel();
    super.dispose();
  }
}
