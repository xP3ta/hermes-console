import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/live_turn_probe.dart';
import 'package:hermes_android/core/services/session_turn_registry.dart';

/// DISENO-REGISTRO-ESTADO R1: one row per input of §2, with the Desktop
/// reference each one replicates.
void main() {
  final t0 = DateTime.utc(2026, 11, 8, 12);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  SessionTurnRegistry live({bool started = true}) {
    final registry = SessionTurnRegistry()..apply(TurnSubmitted(at(0)));
    if (started) registry.apply(TurnMessageStart(at(1)));
    return registry;
  }

  group('arming', () {
    test('submit arms busy + awaiting and seeds the clock (types.ts:205-210)',
        () {
      final registry = SessionTurnRegistry();
      expect(registry.apply(TurnSubmitted(at(0))), isTrue);
      expect(registry.state.busy, isTrue);
      expect(registry.state.awaitingResponse, isTrue);
      expect(registry.state.turnLive, isFalse);
      expect(registry.state.turnStartedAt, at(0));
    });

    test('message.start makes it live and keeps the submit clock '
        '(message-stream.ts:175-212)', () {
      final registry = live();
      expect(registry.state.busy, isTrue);
      expect(registry.state.turnLive, isTrue);
      expect(registry.state.awaitingResponse, isFalse);
      expect(registry.state.turnStartedAt, at(0));
    });

    test('a start nobody sent here (another surface, async delegation) arms '
        'with the server clock', () {
      final registry = SessionTurnRegistry()
        ..apply(TurnMessageStart(at(5), serverStartedAt: at(2)));
      expect(registry.state.busy, isTrue);
      expect(registry.state.turnStartedAt, at(2));
    });

    test('message.start after Stop does not re-arm (interrupted latch)', () {
      final registry = live()..apply(const TurnInterrupt());
      expect(registry.state.interrupted, isTrue);
      expect(registry.state.busy, isTrue, reason: 'busy until the real close');
      registry.apply(const TurnCancelConfirmed());
      expect(registry.state.busy, isFalse);
      // A stale start of the stopped execution before its close is ignored.
      final stopped = live()..apply(const TurnInterrupt());
      stopped.apply(TurnMessageStart(at(9)));
      expect(stopped.state.turnStartedAt, at(0));
      expect(stopped.state.interrupted, isTrue);
    });

    test('info running:true arms like a start (session-info.ts:333-434)', () {
      final registry = SessionTurnRegistry()
        ..apply(TurnInfoRunning(true, at(3), serverStartedAt: at(1)));
      expect(registry.state.busy, isTrue);
      expect(registry.state.turnLive, isTrue);
      expect(registry.state.turnStartedAt, at(1));
    });
  });

  group('snapshot (resolveResumedBusy, resume-verdicts.ts:40-56)', () {
    test('running:true adopts a live turn with the server clock', () {
      final registry = SessionTurnRegistry()
        ..apply(TurnSnapshot(running: true, turnStartedAt: at(-30)));
      expect(registry.state.busy, isTrue);
      expect(registry.state.turnLive, isTrue);
      expect(registry.state.turnStartedAt, at(-30));
    });

    test('a stale running:false never rewinds a live busy', () {
      final registry = live()..apply(const TurnSnapshot(running: false));
      expect(registry.state.busy, isTrue);
    });

    test('running:false on an idle session stays idle', () {
      final registry = SessionTurnRegistry();
      expect(registry.apply(const TurnSnapshot(running: false)), isFalse);
      expect(registry.state.busy, isFalse);
    });

    test('open requests become needsInput', () {
      final registry = SessionTurnRegistry()
        ..apply(const TurnSnapshot(running: true, needsInput: true));
      expect(registry.state.needsInput, isTrue);
    });
  });

  group('closing: only the server', () {
    test('message.complete closes (message-stream.ts:72-84)', () {
      final registry = live()..apply(const TurnMessageComplete());
      expect(registry.state.busy, isFalse);
      expect(registry.state.lastClose, TurnCloseReason.complete);
      expect(registry.state.turnStartedAt, isNull);
      expect(registry.state.turnLive, isFalse);
    });

    test('message.complete status:error closes as an error', () {
      final registry = live()..apply(const TurnMessageComplete(error: true));
      expect(registry.state.busy, isFalse);
      expect(registry.state.lastClose, TurnCloseReason.error);
    });

    test('the error frame closes (status.ts:281-365)', () {
      final registry = live()..apply(const TurnGatewayError());
      expect(registry.state.busy, isFalse);
      expect(registry.state.lastClose, TurnCloseReason.error);
    });

    test('info running:false closes a live turn', () {
      final registry = live()..apply(TurnInfoRunning(false, at(2)));
      expect(registry.state.busy, isFalse);
      expect(registry.state.lastClose, TurnCloseReason.infoIdle);
    });

    test('info running:false before the turn went live is a pre-start '
        'report inside the 15 s grace (session-info.ts:390-440)', () {
      final registry = live(started: false)
        ..apply(TurnInfoRunning(false, at(3)));
      expect(registry.state.busy, isTrue);
      registry.apply(TurnInfoRunning(false, at(16)));
      expect(registry.state.busy, isFalse, reason: 'past the grace it ends');
    });

    test('active_list: ended closes; running and unknown keep '
        '(session-states.ts:515-544)', () {
      final registry = live()
        ..apply(const TurnActiveListVerdict(LiveTurnVerdict.running))
        ..apply(const TurnActiveListVerdict(LiveTurnVerdict.unknown));
      expect(registry.state.busy, isTrue);
      registry.apply(const TurnActiveListVerdict(LiveTurnVerdict.ended));
      expect(registry.state.busy, isFalse);
      expect(registry.state.lastClose, TurnCloseReason.verdictEnded);
    });

    test('activity and needs-input never close', () {
      final registry = live()
        ..apply(TurnActivity(at(4)))
        ..apply(const TurnNeedsInput(true))
        ..apply(const TurnNeedsInput(false));
      expect(registry.state.busy, isTrue);
      expect(registry.state.lastEventAt, at(4));
    });

    test('a refused submit restores the state before it '
        '(submit.ts:1373-1401)', () {
      final registry = SessionTurnRegistry()
        ..apply(TurnSubmitted(at(0)))
        ..apply(const TurnSubmitFailed());
      expect(registry.state.busy, isFalse);
      expect(registry.state.lastClose, TurnCloseReason.submitFailed);
    });

    test('closing an idle session is a no-op', () {
      final registry = SessionTurnRegistry();
      expect(registry.apply(const TurnMessageComplete()), isFalse);
      expect(registry.apply(const TurnGatewayError()), isFalse);
      expect(
        registry.apply(const TurnActiveListVerdict(LiveTurnVerdict.ended)),
        isFalse,
      );
    });
  });

  group('reconnect (session-states.ts:999-1054) as one transition', () {
    test('reset + idle snapshot close in a single publish', () {
      final registry = live();
      final edges = <SessionTurnState>[];
      registry.listenable.addListener(() => edges.add(registry.state));
      registry.apply(const TurnTransportReconnected());
      expect(edges, isEmpty, reason: 'the reset alone is not published');
      expect(registry.reconnectPending, isTrue);
      registry.apply(const TurnSnapshot(running: false));
      expect(edges, hasLength(1));
      expect(registry.state.busy, isFalse);
      expect(registry.state.lastClose, TurnCloseReason.reconnectReset);
    });

    test('reset + running snapshot keep the turn with one publish at most',
        () {
      final registry = live();
      final edges = <SessionTurnState>[];
      registry.listenable.addListener(() => edges.add(registry.state));
      registry
        ..apply(const TurnTransportReconnected())
        ..apply(TurnSnapshot(running: true, turnStartedAt: at(0)));
      expect(registry.state.busy, isTrue);
      expect(edges.where((s) => !s.busy), isEmpty, reason: 'no flicker');
    });

    test('a live frame before the snapshot cancels the reset', () {
      final registry = live()
        ..apply(const TurnTransportReconnected())
        ..apply(TurnActivity(at(7)))
        ..apply(const TurnSnapshot(running: false));
      expect(registry.state.busy, isTrue);
    });

    test('no snapshot: the reset is flushed on its own', () {
      final registry = live()..apply(const TurnTransportReconnected());
      expect(registry.flushReconnect(), isTrue);
      expect(registry.state.busy, isFalse);
      expect(registry.state.lastClose, TurnCloseReason.reconnectReset);
      expect(registry.flushReconnect(), isFalse);
    });

    test('a reconnect on an idle session does nothing', () {
      final registry = SessionTurnRegistry()
        ..apply(const TurnTransportReconnected());
      expect(registry.reconnectPending, isFalse);
    });
  });

  test('the flag follows the define (on by default) and is pinnable', () {
    addTearDown(() => debugSessionTurnRegistryOverride = null);
    expect(
      kSessionTurnRegistryDefault,
      const bool.fromEnvironment(
        'HERMES_SESSION_TURN_REGISTRY',
        defaultValue: true,
      ),
      reason: 'on unless the APK defines it false (rollback), since the Pixel '
          'harness passed with it on (9980)',
    );
    debugSessionTurnRegistryOverride = true;
    expect(kSessionTurnRegistryEnabled, isTrue);
    debugSessionTurnRegistryOverride = false;
    expect(kSessionTurnRegistryEnabled, isFalse);
    debugSessionTurnRegistryOverride = null;
    expect(kSessionTurnRegistryEnabled, kSessionTurnRegistryDefault);
  });
}
