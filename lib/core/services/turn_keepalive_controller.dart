import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/services.dart';

import 'active_chat_service.dart';
import 'turn_keepalive_hold.dart';

/// Turn-bounded keep-alive: while a turn is running and the user leaves the
/// app, a short foreground service keeps the process (and the socket the
/// turn streams on) alive, so the turn keeps arriving and its live row stays
/// current. It replicates Hermes Desktop's «while working» holds:
///
/// * `apps/desktop/electron/power-save.ts`: `DEFAULT_KEEP_AWAKE_MODE =
///   'while-working'`, «Holding the blocker only while a turn runs costs
///   nothing at idle»; configurable (off / while-working / always).
/// * `apps/desktop/electron/stream-throttle.ts`: hidden chat windows keep
///   painting while any turn is in flight and are throttled again
///   `RETHROTTLE_DELAY_MS` (5 s) after the last turn ends.
/// * «Working» is Desktop's `busy` (`src/store/active-work.ts` reads
///   `$workingSessionIds`, `s => s.busy`), which a pending approval or
///   question does not clear (`server-requests.ts` only sets `needsInput`).
///   Here: a chat whose own turn is live (`isStreaming && turnLive`), the
///   same predicate as the live row, waiting-for-user included, or whose
///   subagents still run (REVISION-3 #2).
///
/// Android only allows the start right after the app leaves the foreground,
/// so the service starts only in [startDelay] after the hidden/paused edge,
/// once per background period, and never later. It stops [releaseGrace]
/// after the last turn ends, at once on return to the foreground, when the
/// setting is turned off, with App Lock (a lost socket no longer ends it:
/// the working chat redials and re-attaches under the hold, REVISION-4 B),
/// at [cap], or
/// when the system ends it (timeout, start refused).
class TurnKeepAliveController {
  TurnKeepAliveController({
    required this.platform,
    required this.working,
    required this.enabled,
    required this.appLocked,
    required this.notificationsAllowed,
    required this.copy,
    this.transportUp,
    this.allTransportUp,
    this.onReleasedMidTurn,
    this.startDelay = const Duration(seconds: 2),
    this.releaseGrace = const Duration(seconds: 5),
    this.cap = defaultCap,
    this.recheckEvery = const Duration(seconds: 15),
  }) {
    platform.onEnded = _onPlatformEnded;
  }

  /// Longest a single background period is held.
  static const Duration defaultCap = Duration(minutes: 30);



  final TurnKeepAlivePlatform platform;

  /// A turn is running (see the class comment).
  final bool Function() working;

  /// The sockets of the working chats are still up. A turn whose socket died
  /// behind the app is not helped by the hold (it does not redial there).
  final bool Function()? transportUp;

  /// EVERY working chat still has its socket. [transportUp] (any) keeps the
  /// hold alive while one chat is connected; this one notices the others:
  /// a working chat whose socket died behind the app does not redial, so
  /// the bounded background check gets a fresh window once ([_lostHandled])
  /// even though the hold goes on for the connected chat.
  final bool Function()? allTransportUp;

  /// «Mantener conexión mientras trabaja en segundo plano» (on by default).
  final bool Function() enabled;

  /// App Lock is on or locked: no hold (same rule as the background check).
  final bool Function() appLocked;

  /// POST_NOTIFICATIONS granted: without it there is no visible service.
  final Future<bool> Function() notificationsAllowed;

  /// The service notification's copy (no chat content).
  final ({String title, String text}) Function() copy;

  /// The hold ended while a turn was still running (cap, timeout, socket
  /// lost, refused): the bounded background check takes over.
  final VoidCallback? onReleasedMidTurn;

  final Duration startDelay;
  final Duration releaseGrace;
  final Duration cap;

  /// While holding, the in-memory state is re-read this often in case no
  /// listener fired (a socket that closed quietly). Never a server read.
  final Duration recheckEvery;

  TurnKeepAlivePhase _phase = TurnKeepAlivePhase.idle;
  TurnKeepAlivePhase get phase => _phase;

  bool _foreground = true;

  /// This background period already tried (or ended a hold): nothing starts
  /// again until the app has been in the foreground.
  bool _spent = false;

  /// Android refused the service (start not allowed, the Android 15 dataSync
  /// budget spent, a channel error) or ended it on its timeout: no new
  /// attempt until this turn is over; the background check carries on.
  bool _refusedThisTurn = false;

  /// For tests and diagnostics: a refusal is waiting for the turn to end.
  bool get refusedThisTurn => _refusedThisTurn;

  /// The restart for a working chat that lost its socket was already asked
  /// for (once per loss; rearmed when every socket is up again, and by any
  /// release).
  bool _lostHandled = false;
  int _generation = 0;
  Timer? _startTimer;
  Timer? _graceTimer;
  Timer? _capTimer;
  Timer? _recheckTimer;
  Future<void> _tail = Future<void>.value();
  int _queued = 0;
  bool _platformStarted = false;
  bool _disposed = false;

  bool get holding =>
      _phase == TurnKeepAlivePhase.holding ||
      _phase == TurnKeepAlivePhase.releasing;

  bool _eligible() => enabled() && !appLocked();

  /// conn-registry (REVISION-3 #3, REVISION-4 B): once holding, the hold
  /// stays while there is work (a turn or live subagents), whatever the
  /// socket does: the working chat redials with backoff and re-attaches its
  /// session under the hold (ActiveChat._followKeepAliveHold), as Desktop
  /// reconnects during a turn (apps/desktop/src/store/gateway.ts:1103). The
  /// 30 min [cap] bounds it. A start still needs a live socket.
  bool _workingNow() {
    if (!working()) return false;
    if (holding) return true;
    return transportUp?.call() ?? true;
  }

  void _forgetRefusalAfterTurn() {
    if (!_refusedThisTurn) return;
    var turnRunning = true;
    try {
      turnRunning = working();
    } catch (_) {}
    if (!turnRunning) _refusedThisTurn = false;
  }

  void lifecycleChanged(AppLifecycleState state) {
    if (_disposed) return;
    _forgetRefusalAfterTurn();
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        _spent = false;
        _release(midTurn: false);
      case AppLifecycleState.paused ||
          AppLifecycleState.hidden ||
          AppLifecycleState.detached:
        if (!_foreground) return;
        _foreground = false;
        if (_spent || _refusedThisTurn || !_eligible()) {
          _spent = true;
          return;
        }
        _phase = TurnKeepAlivePhase.pending;
        final generation = ++_generation;
        _startTimer?.cancel();
        _startTimer = Timer(startDelay, () {
          _startTimer = null;
          unawaited(_tryStart(generation));
        });
      case AppLifecycleState.inactive:
        // Also a pulled-down shade: not a departure.
        break;
    }
  }

  /// The turn picture, the setting or App Lock may have changed.
  void reevaluate() {
    if (_disposed) return;
    _forgetRefusalAfterTurn();
    if (_foreground) return;
    switch (_phase) {
      case TurnKeepAlivePhase.idle || TurnKeepAlivePhase.pending:
        if (_phase == TurnKeepAlivePhase.pending && !_eligible()) {
          _spent = true;
          _release(midTurn: false);
        }
      case TurnKeepAlivePhase.holding || TurnKeepAlivePhase.releasing:
        if (!_eligible()) {
          _spent = true;
          _release(midTurn: working());
          return;
        }
        if (_workingNow()) {
          _noteLostSocket();
          if (_phase == TurnKeepAlivePhase.releasing) {
            // A successor turn (async_delegation_complete) inside the grace.
            _graceTimer?.cancel();
            _graceTimer = null;
            _phase = TurnKeepAlivePhase.holding;
          }
          return;
        }
        if (_phase == TurnKeepAlivePhase.releasing) return;
        _phase = TurnKeepAlivePhase.releasing;
        final generation = _generation;
        _graceTimer = Timer(releaseGrace, () {
          _graceTimer = null;
          if (generation != _generation || _disposed) return;
          if (_workingNow() && _eligible()) {
            _phase = TurnKeepAlivePhase.holding;
            return;
          }
          _spent = true;
          _release(midTurn: working());
        });
    }
  }

  /// Holding for a connected chat while another working chat lost its
  /// socket: nobody watches that one (no redial in the background), so the
  /// check restarts ONCE; Desktop reconnects and replays instead
  /// (`store/gateway.ts`), which a parked Android socket cannot do.
  void _noteLostSocket() {
    final all = allTransportUp;
    if (all == null) return;
    var allUp = true;
    try {
      allUp = all();
    } catch (_) {}
    if (allUp) {
      _lostHandled = false;
      return;
    }
    if (_lostHandled || _foreground) return;
    _lostHandled = true;
    onReleasedMidTurn?.call();
  }

  Future<void> _tryStart(int generation) async {
    if (generation != _generation || _foreground || _disposed) return;
    _spent = true;
    if (!_eligible() || !_workingNow()) {
      _phase = TurnKeepAlivePhase.idle;
      return;
    }
    var allowed = false;
    try {
      allowed = await notificationsAllowed();
    } catch (_) {}
    if (generation != _generation || _foreground || _disposed) return;
    if (!allowed || !_eligible() || !_workingNow()) {
      _phase = TurnKeepAlivePhase.idle;
      return;
    }
    ({String title, String text}) text;
    try {
      text = copy();
    } catch (_) {
      text = (title: '', text: '');
    }
    final started = await _serial(
      () => platform.start(title: text.title, text: text.text, cap: cap),
    );
    if (started) _platformStarted = true;
    if (generation != _generation || _foreground || _disposed) {
      // Came back (or stopped) while the start was in flight.
      if (started) unawaited(_stopPlatform());
      return;
    }
    if (!started) {
      // Refused or failed: nothing is held, no retry until the next turn.
      _phase = TurnKeepAlivePhase.idle;
      _refusedThisTurn = true;
      if (working()) onReleasedMidTurn?.call();
      return;
    }
    _phase = TurnKeepAlivePhase.holding;
    TurnKeepAliveHold.held = true;
    _capTimer = Timer(cap, () {
      _capTimer = null;
      if (generation != _generation) return;
      _release(midTurn: working());
    });
    _recheckTimer = Timer.periodic(recheckEvery, (_) => reevaluate());
    // The turn may have ended while the start was in flight.
    reevaluate();
  }

  void _onPlatformEnded(String reason) {
    if (_disposed) return;
    // The service is already gone: forget it without a stop call.
    _platformStarted = false;
    if (reason == 'refused' || reason == 'timeout') _refusedThisTurn = true;
    if (_phase == TurnKeepAlivePhase.idle) return;
    final midTurn = !_foreground && working();
    _spent = true;
    _release(midTurn: midTurn, platformGone: true);
  }

  void _release({required bool midTurn, bool platformGone = false}) {
    _generation++;
    _startTimer?.cancel();
    _startTimer = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    _capTimer?.cancel();
    _capTimer = null;
    _recheckTimer?.cancel();
    _recheckTimer = null;
    _lostHandled = false;
    final wasHolding = holding;
    _phase = TurnKeepAlivePhase.idle;
    TurnKeepAliveHold.held = false;
    if (_platformStarted && !platformGone) unawaited(_stopPlatform());
    if (wasHolding && midTurn && !_foreground) onReleasedMidTurn?.call();
  }

  Future<void> _stopPlatform() {
    _platformStarted = false;
    return _serial(() async {
      await platform.stop();
      return true;
    });
  }

  /// Start and stop reach the platform in order (a stop never overtakes the
  /// start it follows). With nothing queued the call is made right now,
  /// synchronously: a stop must reach the platform before the live-row
  /// cancels the same frame goes on to send (the service card shows the
  /// chat's row while it holds and puts it back under its own tag when it
  /// stops; the cancel that follows then takes it down).
  Future<bool> _serial(Future<bool> Function() call) {
    final completer = Completer<bool>();
    Future<void> run() async {
      try {
        completer.complete(await call());
      } catch (_) {
        completer.complete(false);
      }
    }

    if (_queued == 0) {
      _queued++;
      final started = run();
      _tail = started.whenComplete(() => _queued--);
    } else {
      _queued++;
      _tail = _tail.then((_) => run()).whenComplete(() => _queued--);
    }
    return completer.future;
  }

  void dispose() {
    if (_disposed) return;
    _release(midTurn: false);
    _disposed = true;
    platform.onEnded = null;
  }
}

enum TurnKeepAlivePhase { idle, pending, holding, releasing }

/// The native side of the keep-alive (`HermesTurnKeepAliveService`).
abstract class TurnKeepAlivePlatform {
  Future<bool> start({
    required String title,
    required String text,
    required Duration cap,
  });

  Future<void> stop();

  /// The service ended by itself: `timeout`, `cap` or `refused`.
  set onEnded(void Function(String reason)? callback);
}

class MethodChannelTurnKeepAlivePlatform implements TurnKeepAlivePlatform {
  MethodChannelTurnKeepAlivePlatform([
    this._channel = const MethodChannel('hermes/turn_keepalive'),
  ]) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'ended') {
        final args = call.arguments;
        final reason = args is Map ? '${args['reason'] ?? ''}' : '';
        try {
          _onEnded?.call(reason);
        } catch (_) {}
      }
      return null;
    });
  }

  final MethodChannel _channel;
  void Function(String reason)? _onEnded;

  @override
  set onEnded(void Function(String reason)? callback) => _onEnded = callback;

  @override
  Future<bool> start({
    required String title,
    required String text,
    required Duration cap,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('start', {
            'title': title,
            'text': text,
            'capMs': cap.inMilliseconds,
          }) ==
          true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      // Android refused it (ForegroundServiceStartNotAllowedException, the
      // dataSync budget, SecurityException): not holding, never a crash.
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Not Android, or the engine is going away.
    } on PlatformException {
      // Nothing to stop.
    } catch (_) {
      // A failed stop leaves the native backstop and stopWithTask.
    }
  }
}

/// Whether any chat of [service] runs a turn of its own right now: the live
/// row's predicate (`ActiveChatService._liveTurnOf`), waiting-for-user
/// included, like Desktop's `busy`.
bool anyChatTurnWorking(ActiveChatService service) =>
    _workingChats(service).isNotEmpty;

/// Some chat with a working turn still has its socket (the others' turns
/// are left to the background check and the return to the app).
bool workingChatsConnected(ActiveChatService service) =>
    _workingChats(service).any((chat) => chat.gatewayConnected);

/// Every chat with a working turn still has its socket (true with none).
bool allWorkingChatsConnected(ActiveChatService service) =>
    _workingChats(service).every((chat) => chat.gatewayConnected);

List<ActiveChat> _workingChats(ActiveChatService service) {
  final seen = <ActiveChat>{};
  for (final rawId in service.activeIds.value) {
    try {
      final decoded = jsonDecode(rawId);
      if (decoded is! List || decoded.length != 3) continue;
      final connectionId = decoded[0];
      final profile = decoded[1];
      final sessionId = decoded[2];
      if (connectionId is! String ||
          profile is! String ||
          sessionId is! String) {
        continue;
      }
      final chat = service.of(connectionId, sessionId, profile: profile);
      if (chat == null || !seen.add(chat)) continue;
    } catch (_) {
      // Opaque internal ids: a malformed one is skipped.
    }
  }
  return [
    for (final chat in seen)
      if (chatHoldsBackgroundWork(chat)) chat,
  ];
}

/// What keeps the process and the chat's socket while the app is away: the
/// chat's own live turn (the live row's predicate, like Desktop's `busy`)
/// or, conn-registry (REVISION-3 #2), subagents still running on its
/// session roster after the parent turn closed. Desktop never closes its
/// socket when hidden, so the successor turn Hermes opens when a child ends
/// (`async_delegation_complete`) reaches it (apps/desktop/src/store/
/// gateway.ts:1103); here the hold keeps that socket for it, still bounded
/// by the 30 min cap. Only for the hold: the composer and the live row keep
/// reading the parent alone.
bool chatHoldsBackgroundWork(ActiveChat chat) =>
    // REVISION-4 BAJO 3 / B: subagents the roster shows running (or a count a
    // cut retained while the session is being re-attached), not a stale one.
    chat.holdsBackgroundWork;
