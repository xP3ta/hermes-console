import 'package:flutter/foundation.dart';

import 'live_turn_probe.dart';

/// Per-session turn registry (DISENO-REGISTRO-ESTADO R1): ONE answer to
/// «is a turn running on this session?», derived from the server's snapshot
/// and events, as Desktop's `ClientSessionState`
/// (apps/desktop/src/app/types.ts:153-211). It is pure: no I/O, no timers;
/// ActiveChat does the I/O (resume, `session.active_list`, REST) and feeds
/// the results in as [TurnInput]s.
///
/// Only the server closes a turn: `message.complete`, `session.info`
/// `running:false`, an `ended` verdict of `session.active_list`, a server
/// error frame, a confirmed cancel, or a submit the server never accepted.
/// A REST read, a recovery loop giving up or a subagent never close nor arm
/// it.
///
/// Compile-time switch (DISENO-REGISTRO-ESTADO §5, phase R1-R6): ON by
/// default since the Pixel harness passed with it (9980, two rounds, SC16
/// and the rest; coordinator decision, REPORT-REVISION-4 MEDIO 2). Rollback:
/// `--dart-define=HERMES_SESSION_TURN_REGISTRY=false`.
const bool kSessionTurnRegistryDefault = bool.fromEnvironment(
  'HERMES_SESSION_TURN_REGISTRY',
  defaultValue: true,
);

/// Runtime view of the switch. Tests pin it per case with
/// [debugSessionTurnRegistryOverride]; production reads the define.
bool get kSessionTurnRegistryEnabled =>
    debugSessionTurnRegistryOverride ?? kSessionTurnRegistryDefault;

@visibleForTesting
bool? debugSessionTurnRegistryOverride;

/// How long a `running:false` that lands before the turn went live is a
/// pre-start report, not an end. Desktop `PRE_TURN_LIVE_SETTLE_GRACE_MS`
/// (apps/desktop/src/app/session/hooks/use-message-stream/utils.ts:133).
const preTurnLiveSettleGrace = Duration(seconds: 15);

/// Why the last turn closed.
enum TurnCloseReason {
  complete,
  error,
  infoIdle,
  verdictEnded,
  cancelled,
  reconnectReset,
  submitFailed,
}

@immutable
final class SessionTurnState {
  const SessionTurnState({
    this.busy = false,
    this.awaitingResponse = false,
    this.turnLive = false,
    this.turnStartedAt,
    this.needsInput = false,
    this.interrupted = false,
    this.lastEventAt,
    this.lastClose,
  });

  /// The one authority for «a turn is running».
  final bool busy;

  /// Sent, and the server has not reported the turn live yet.
  final bool awaitingResponse;

  /// Live proof: `message.start`, `running:true`, a live snapshot, a frame.
  final bool turnLive;

  /// The turn's clock: the server's `turn_started_at` when known, else the
  /// moment it was sent or first seen (Desktop: «seeded at send»).
  final DateTime? turnStartedAt;

  /// Waiting on the user (approval, clarify, open requests).
  final bool needsInput;

  /// The user pressed Stop: late starts of that execution do not re-arm.
  final bool interrupted;

  /// Last runtime frame (the silent-turn probe's clock).
  final DateTime? lastEventAt;
  final TurnCloseReason? lastClose;

  static const SessionTurnState idle = SessionTurnState();

  SessionTurnState _copy({
    bool? busy,
    bool? awaitingResponse,
    bool? turnLive,
    DateTime? Function()? turnStartedAt,
    bool? needsInput,
    bool? interrupted,
    DateTime? Function()? lastEventAt,
    TurnCloseReason? Function()? lastClose,
  }) => SessionTurnState(
    busy: busy ?? this.busy,
    awaitingResponse: awaitingResponse ?? this.awaitingResponse,
    turnLive: turnLive ?? this.turnLive,
    turnStartedAt: turnStartedAt == null ? this.turnStartedAt : turnStartedAt(),
    needsInput: needsInput ?? this.needsInput,
    interrupted: interrupted ?? this.interrupted,
    lastEventAt: lastEventAt == null ? this.lastEventAt : lastEventAt(),
    lastClose: lastClose == null ? this.lastClose : lastClose(),
  );

  /// The close every terminal input applies (Desktop `settleEndedLiveTurn`).
  SessionTurnState _closed(TurnCloseReason reason) => SessionTurnState(
    lastEventAt: lastEventAt,
    lastClose: reason,
  );

  @override
  bool operator ==(Object other) =>
      other is SessionTurnState &&
      other.busy == busy &&
      other.awaitingResponse == awaitingResponse &&
      other.turnLive == turnLive &&
      other.turnStartedAt == turnStartedAt &&
      other.needsInput == needsInput &&
      other.interrupted == interrupted &&
      other.lastEventAt == lastEventAt &&
      other.lastClose == lastClose;

  @override
  int get hashCode => Object.hash(
    busy,
    awaitingResponse,
    turnLive,
    turnStartedAt,
    needsInput,
    interrupted,
    lastEventAt,
    lastClose,
  );

  @override
  String toString() =>
      'SessionTurnState(busy: $busy, awaiting: $awaitingResponse, '
      'live: $turnLive, needsInput: $needsInput, interrupted: $interrupted, '
      'lastClose: ${lastClose?.name})';
}

/// What can change a session's turn.
sealed class TurnInput {
  const TurnInput();

  /// Content-free name for the `[turn-registry]` trace.
  String get name;
}

/// The user sent a prompt (Desktop seeds busy and the clock at send:
/// types.ts:205-210).
final class TurnSubmitted extends TurnInput {
  const TurnSubmitted(this.at);
  final DateTime at;
  @override
  String get name => 'submitted';
}

/// The server never accepted the prompt: the state before it comes back
/// (Desktop submit.ts:1373-1401; the error row is ActiveChat's).
final class TurnSubmitFailed extends TurnInput {
  const TurnSubmitFailed();
  @override
  String get name => 'submit_failed';
}

/// A `session.resume` / `session.activate` snapshot. `busy = running ||
/// busy` (Desktop `resolveResumedBusy`, resume-verdicts.ts:40-56): a stale
/// `running:false` never rewinds a live turn. A retained failure is a row
/// ActiveChat regenerates, not state (use-session-actions/utils.ts:
/// 1204-1208).
final class TurnSnapshot extends TurnInput {
  const TurnSnapshot({
    required this.running,
    this.turnStartedAt,
    this.needsInput = false,
  });
  final bool running;
  final DateTime? turnStartedAt;
  final bool needsInput;
  @override
  String get name => 'snapshot';
}

/// `message.start`: arms unless the user stopped this execution (Desktop
/// message-stream.ts:175-212).
final class TurnMessageStart extends TurnInput {
  const TurnMessageStart(this.at, {this.serverStartedAt});
  final DateTime at;
  final DateTime? serverStartedAt;
  @override
  String get name => 'message_start';
}

/// Any other runtime frame of the turn (delta, tool, thinking, progress).
final class TurnActivity extends TurnInput {
  const TurnActivity(this.at);
  final DateTime at;
  @override
  String get name => 'activity';
}

final class TurnNeedsInput extends TurnInput {
  const TurnNeedsInput(this.value);
  final bool value;
  @override
  String get name => 'needs_input';
}

/// `session.info` `running` (Desktop session-info.ts:333-434): true arms
/// like a start; false closes, except while a just-sent turn has not gone
/// live yet (pre-start report, [preTurnLiveSettleGrace]).
final class TurnInfoRunning extends TurnInput {
  const TurnInfoRunning(this.running, this.at, {this.serverStartedAt});
  final bool running;
  final DateTime at;
  final DateTime? serverStartedAt;
  @override
  String get name => running ? 'info_running' : 'info_idle';
}

/// `message.complete` (with `status:error` it closes as an error).
final class TurnMessageComplete extends TurnInput {
  const TurnMessageComplete({this.error = false});
  final bool error;
  @override
  String get name => error ? 'complete_error' : 'complete';
}

/// The server's `error` frame for this turn (Desktop status.ts:281-365).
final class TurnGatewayError extends TurnInput {
  const TurnGatewayError();
  @override
  String get name => 'gateway_error';
}

/// One `session.active_list` verdict (Desktop session-states.ts:515-544).
final class TurnActiveListVerdict extends TurnInput {
  const TurnActiveListVerdict(this.verdict);
  final LiveTurnVerdict verdict;
  @override
  String get name => 'verdict_${verdict.name}';
}

/// Stop pressed: busy stays until the real close.
final class TurnInterrupt extends TurnInput {
  const TurnInterrupt();
  @override
  String get name => 'interrupt';
}

/// The server confirmed the cancel.
final class TurnCancelConfirmed extends TurnInput {
  const TurnCancelConfirmed();
  @override
  String get name => 'cancel_confirmed';
}

/// The chat's socket came back (Desktop resets busy on every reconnect and
/// lets the resume re-arm it: session-states.ts:999-1054). Applied together
/// with the next [TurnSnapshot] as ONE transition, so nothing flickers; a
/// live frame before it cancels it; [SessionTurnRegistry.flushReconnect]
/// publishes it alone when no snapshot comes.
final class TurnTransportReconnected extends TurnInput {
  const TurnTransportReconnected();
  @override
  String get name => 'reconnected';
}

/// One registry per durable session (key: the stored session id).
class SessionTurnRegistry {
  SessionTurnRegistry({SessionTurnState initial = SessionTurnState.idle})
    : _listenable = ValueNotifier<SessionTurnState>(initial);

  final ValueNotifier<SessionTurnState> _listenable;
  SessionTurnState? _beforeSubmit;
  bool _reconnectPending = false;
  bool _disposed = false;

  SessionTurnState get state => _listenable.value;
  ValueListenable<SessionTurnState> get listenable => _listenable;
  bool get busy => state.busy;

  /// A reconnect reset waits for its snapshot.
  bool get reconnectPending => _reconnectPending;

  /// Applies [input]; returns whether the state changed. Deterministic.
  bool apply(TurnInput input) {
    if (_disposed) return false;
    final next = reduce(state, input);
    if (identical(next, state) || next == state) return false;
    _listenable.value = next;
    return true;
  }

  /// The reconnect reset published on its own (no snapshot arrived).
  bool flushReconnect() {
    if (_disposed || !_reconnectPending) return false;
    _reconnectPending = false;
    final current = state;
    if (!current.busy && !current.awaitingResponse) return false;
    _listenable.value = current._closed(TurnCloseReason.reconnectReset);
    return true;
  }

  /// Pure transition, except for the two registry memories it keeps (the
  /// state before a submit, a pending reconnect reset).
  @visibleForTesting
  SessionTurnState reduce(SessionTurnState s, TurnInput input) {
    switch (input) {
      case TurnSubmitted(:final at):
        _beforeSubmit = s;
        _reconnectPending = false;
        return s._copy(
          busy: true,
          awaitingResponse: true,
          turnStartedAt: () => s.busy ? (s.turnStartedAt ?? at) : at,
          interrupted: false,
          lastClose: () => null,
        );
      case TurnSubmitFailed():
        final before = _beforeSubmit;
        _beforeSubmit = null;
        if (before != null && !before.busy) {
          return before._copy(lastClose: () => TurnCloseReason.submitFailed);
        }
        return before ?? s._closed(TurnCloseReason.submitFailed);
      case TurnSnapshot(:final running, :final turnStartedAt, :final needsInput):
        var base = s;
        if (_reconnectPending) {
          // The reset and this snapshot are one transition.
          _reconnectPending = false;
          if (base.busy || base.awaitingResponse) {
            base = base._closed(TurnCloseReason.reconnectReset);
          }
        }
        final busy = running || base.busy;
        if (!busy) {
          return base.needsInput == needsInput
              ? base
              : base._copy(needsInput: needsInput);
        }
        return base._copy(
          busy: true,
          turnLive: base.turnLive || running,
          awaitingResponse: running ? false : base.awaitingResponse,
          turnStartedAt: () => turnStartedAt ?? base.turnStartedAt,
          needsInput: needsInput,
          lastClose: () => null,
        );
      case TurnMessageStart(:final at, :final serverStartedAt):
        _reconnectPending = false;
        if (s.interrupted) return s;
        return s._copy(
          busy: true,
          turnLive: true,
          awaitingResponse: false,
          turnStartedAt: () => s.turnStartedAt ?? serverStartedAt ?? at,
          lastEventAt: () => at,
          lastClose: () => null,
        );
      case TurnActivity(:final at):
        if (!s.busy) return s._copy(lastEventAt: () => at);
        // A live frame after a reconnect proves the turn: no reset.
        _reconnectPending = false;
        return s._copy(turnLive: true, lastEventAt: () => at);
      case TurnNeedsInput(:final value):
        return s.needsInput == value ? s : s._copy(needsInput: value);
      case TurnInfoRunning(:final running, :final at, :final serverStartedAt):
        if (running) {
          _reconnectPending = false;
          if (s.interrupted) return s;
          return s._copy(
            busy: true,
            turnLive: true,
            turnStartedAt: () => s.turnStartedAt ?? serverStartedAt ?? at,
            lastClose: () => null,
          );
        }
        if (!s.busy && !s.awaitingResponse) return s;
        final armedAt = s.turnStartedAt;
        final preStart =
            s.awaitingResponse &&
            !s.turnLive &&
            armedAt != null &&
            at.difference(armedAt) < preTurnLiveSettleGrace;
        if (preStart) return s;
        return s._closed(TurnCloseReason.infoIdle);
      case TurnMessageComplete(:final error):
        if (!s.busy && !s.awaitingResponse) {
          return s.interrupted ? s._copy(interrupted: false) : s;
        }
        return s._closed(
          error ? TurnCloseReason.error : TurnCloseReason.complete,
        );
      case TurnGatewayError():
        if (!s.busy && !s.awaitingResponse) return s;
        return s._closed(TurnCloseReason.error);
      case TurnActiveListVerdict(:final verdict):
        if (verdict != LiveTurnVerdict.ended) return s;
        if (!s.busy && !s.awaitingResponse) return s;
        return s._closed(TurnCloseReason.verdictEnded);
      case TurnInterrupt():
        if (!s.busy && !s.awaitingResponse) return s;
        return s._copy(interrupted: true);
      case TurnCancelConfirmed():
        if (!s.busy && !s.awaitingResponse) {
          return s.interrupted ? s._copy(interrupted: false) : s;
        }
        return s._closed(TurnCloseReason.cancelled);
      case TurnTransportReconnected():
        if (s.busy || s.awaitingResponse) _reconnectPending = true;
        return s;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listenable.dispose();
  }
}
