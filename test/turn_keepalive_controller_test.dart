// Turn-bounded keep-alive: when it starts and when it lets go. Reference:
// Hermes Desktop holds only while a turn works (apps/desktop/electron/
// power-save.ts 'while-working'; stream-throttle.ts re-throttles 5 s after
// the last turn).
import 'dart:async';
import 'dart:ui' show AppLifecycleState;

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/turn_keepalive_controller.dart';
import 'package:hermes_android/core/services/turn_keepalive_hold.dart';

class _FakePlatform implements TurnKeepAlivePlatform {
  final calls = <String>[];
  bool startResult = true;
  Object? startThrows;
  Completer<bool>? startGate;
  Duration? lastCap;
  String? lastTitle;
  String? lastText;
  void Function(String reason)? _ended;

  @override
  set onEnded(void Function(String reason)? callback) => _ended = callback;

  bool get hasEndedListener => _ended != null;

  void end(String reason) => _ended?.call(reason);

  @override
  Future<bool> start({
    required String title,
    required String text,
    required Duration cap,
  }) {
    calls.add('start');
    lastCap = cap;
    lastTitle = title;
    lastText = text;
    final error = startThrows;
    if (error != null) return Future<bool>.error(error);
    return startGate?.future ?? Future<bool>.value(startResult);
  }

  @override
  Future<void> stop() async => calls.add('stop');
}

class _Harness {
  _Harness({Duration cap = TurnKeepAliveController.defaultCap}) {
    controller = TurnKeepAliveController(
      platform: platform,
      working: () => working,
      transportUp: () => connected,
      allTransportUp: () => allConnected,
      enabled: () => enabled,
      appLocked: () => locked,
      notificationsAllowed: () async => notificationsAllowed,
      copy: () => (title: 'Hermes is working', text: 'keeps the connection'),
      onReleasedMidTurn: () => releasedMidTurn++,
      cap: cap,
    );
  }

  final platform = _FakePlatform();
  late final TurnKeepAliveController controller;
  bool working = true;
  bool connected = true;
  bool allConnected = true;
  bool enabled = true;
  bool locked = false;
  bool notificationsAllowed = true;
  int releasedMidTurn = 0;

  void leave() {
    controller.lifecycleChanged(AppLifecycleState.inactive);
    controller.lifecycleChanged(AppLifecycleState.hidden);
    controller.lifecycleChanged(AppLifecycleState.paused);
  }

  void back() {
    controller.lifecycleChanged(AppLifecycleState.inactive);
    controller.lifecycleChanged(AppLifecycleState.resumed);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(TurnKeepAliveHold.resetForTesting);
  tearDown(TurnKeepAliveHold.resetForTesting);

  test('starts 2 s after the app leaves with a turn running, not before', () {
    fakeAsync((time) {
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(milliseconds: 1900));
      expect(h.platform.calls, isEmpty);
      expect(TurnKeepAliveHold.held, isFalse);
      time.elapse(const Duration(milliseconds: 200));
      expect(h.platform.calls, ['start']);
      expect(h.controller.phase, TurnKeepAlivePhase.holding);
      expect(TurnKeepAliveHold.held, isTrue);
      // The cap travels to the native backstop; the copy names no chat.
      expect(h.platform.lastCap, TurnKeepAliveController.defaultCap);
      expect(h.platform.lastTitle, 'Hermes is working');
      h.controller.dispose();
    });
  });

  test('a pulled-down shade (inactive) is not a departure', () {
    fakeAsync((time) {
      final h = _Harness();
      h.controller.lifecycleChanged(AppLifecycleState.inactive);
      time.elapse(const Duration(seconds: 10));
      expect(h.platform.calls, isEmpty);
      h.controller.dispose();
    });
  });

  test('coming back within 2 s starts nothing', () {
    fakeAsync((time) {
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(seconds: 1));
      h.back();
      time.elapse(const Duration(seconds: 10));
      expect(h.platform.calls, isEmpty);
      expect(TurnKeepAliveHold.held, isFalse);
      h.controller.dispose();
    });
  });

  test('no turn when the window opens: nothing for the rest of the period', () {
    fakeAsync((time) {
      final h = _Harness()..working = false;
      h.leave();
      time.elapse(const Duration(seconds: 3));
      h.working = true;
      h.controller.reevaluate();
      time.elapse(const Duration(minutes: 1));
      expect(h.platform.calls, isEmpty);
      // The next departure is a new period.
      h.back();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      expect(h.platform.calls, ['start']);
      h.controller.dispose();
    });
  });

  test('turn end releases after the 5 s grace; a successor inside it keeps '
      'holding', () {
    fakeAsync((time) {
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      h.working = false;
      h.controller.reevaluate();
      expect(h.controller.phase, TurnKeepAlivePhase.releasing);
      expect(TurnKeepAliveHold.held, isTrue);
      time.elapse(const Duration(seconds: 3));
      // async_delegation_complete opens a successor turn.
      h.working = true;
      h.controller.reevaluate();
      expect(h.controller.phase, TurnKeepAlivePhase.holding);
      time.elapse(const Duration(seconds: 10));
      expect(h.platform.calls, ['start']);
      h.working = false;
      h.controller.reevaluate();
      time.elapse(const Duration(milliseconds: 4900));
      expect(h.platform.calls, ['start']);
      time.elapse(const Duration(milliseconds: 200));
      expect(h.platform.calls, ['start', 'stop']);
      expect(TurnKeepAliveHold.held, isFalse);
      expect(h.controller.phase, TurnKeepAlivePhase.idle);
      // The turn ended: nothing left for the background check to take over.
      expect(h.releasedMidTurn, 0);
      h.controller.dispose();
    });
  });

  test('a waiting-for-user turn keeps holding (Desktop busy)', () {
    fakeAsync((time) {
      // `working` is the live row's predicate; an approval keeps it true.
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      time.elapse(const Duration(minutes: 5));
      h.controller.reevaluate();
      expect(h.controller.phase, TurnKeepAlivePhase.holding);
      expect(h.platform.calls, ['start']);
      h.controller.dispose();
    });
  });

  test('return to the app stops at once', () {
    fakeAsync((time) {
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      h.back();
      time.flushMicrotasks();
      expect(h.platform.calls, ['start', 'stop']);
      expect(TurnKeepAliveHold.held, isFalse);
      expect(h.releasedMidTurn, 0);
      h.controller.dispose();
    });
  });

  test('return to the app: the stop reaches the platform before anything the '
      'same frame sends (no microtask in between)', () {
    fakeAsync((time) {
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      expect(h.platform.calls, ['start']);
      // What main does on resume: release the hold, then the notification
      // service withdraws the live row (a cancel on the same channel).
      h.platform.calls.add('mark');
      h.back();
      h.platform.calls.add('cancel-row');
      expect(h.platform.calls, ['start', 'mark', 'stop', 'cancel-row']);
      h.controller.dispose();
    });
  });

  test('a stop queued behind a start in flight still follows it', () {
    fakeAsync((time) {
      final h = _Harness();
      h.platform.startGate = Completer<bool>();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      h.back();
      time.flushMicrotasks();
      expect(h.platform.calls, ['start']);
      h.platform.startGate!.complete(true);
      time.flushMicrotasks();
      expect(h.platform.calls, ['start', 'stop']);
      h.controller.dispose();
    });
  });

  test('the cap releases mid-turn, hands over to the background check and '
      'does not start again until the app was in front', () {
    fakeAsync((time) {
      final h = _Harness(cap: const Duration(minutes: 30));
      h.leave();
      time.elapse(const Duration(seconds: 3));
      time.elapse(const Duration(minutes: 30));
      expect(h.platform.calls, ['start', 'stop']);
      expect(TurnKeepAliveHold.held, isFalse);
      expect(h.releasedMidTurn, 1);
      h.controller.reevaluate();
      time.elapse(const Duration(minutes: 5));
      expect(h.platform.calls, ['start', 'stop']);
      h.back();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      expect(h.platform.calls, ['start', 'stop', 'start']);
      h.controller.dispose();
    });
  });

  test('the system ends it (timeout): no stop call, the check takes over', () {
    fakeAsync((time) {
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      h.platform.end('timeout');
      time.flushMicrotasks();
      expect(h.platform.calls, ['start']);
      expect(TurnKeepAliveHold.held, isFalse);
      expect(h.controller.phase, TurnKeepAlivePhase.idle);
      expect(h.releasedMidTurn, 1);
      time.elapse(const Duration(minutes: 1));
      expect(h.platform.calls, ['start']);
      h.controller.dispose();
    });
  });

  test('setting off: never starts; turned off while holding: stops', () {
    fakeAsync((time) {
      final h = _Harness()..enabled = false;
      h.leave();
      time.elapse(const Duration(seconds: 10));
      expect(h.platform.calls, isEmpty);
      h.back();
      h.enabled = true;
      h.leave();
      time.elapse(const Duration(seconds: 3));
      expect(h.platform.calls, ['start']);
      h.enabled = false;
      h.controller.reevaluate();
      time.flushMicrotasks();
      expect(h.platform.calls, ['start', 'stop']);
      expect(TurnKeepAliveHold.held, isFalse);
      h.controller.dispose();
    });
  });

  test('App Lock: never starts; locking while holding stops', () {
    fakeAsync((time) {
      final h = _Harness()..locked = true;
      h.leave();
      time.elapse(const Duration(seconds: 10));
      expect(h.platform.calls, isEmpty);
      h.back();
      h.locked = false;
      h.leave();
      time.elapse(const Duration(seconds: 3));
      h.locked = true;
      h.controller.reevaluate();
      time.flushMicrotasks();
      expect(h.platform.calls, ['start', 'stop']);
      expect(TurnKeepAliveHold.held, isFalse);
      h.controller.dispose();
    });
  });

  test('App Lock turned on during the 2 s window: nothing starts', () {
    fakeAsync((time) {
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(seconds: 1));
      h.locked = true;
      h.controller.reevaluate();
      time.elapse(const Duration(seconds: 5));
      expect(h.platform.calls, isEmpty);
      h.controller.dispose();
    });
  });

  test('notifications denied: no service, the existing fallback stays', () {
    fakeAsync((time) {
      final h = _Harness()..notificationsAllowed = false;
      h.leave();
      time.elapse(const Duration(seconds: 10));
      expect(h.platform.calls, isEmpty);
      expect(TurnKeepAliveHold.held, isFalse);
      h.controller.dispose();
    });
  });

  test('a refused start (Android grace over, budget spent) holds nothing', () {
    fakeAsync((time) {
      final h = _Harness();
      h.platform.startResult = false;
      h.leave();
      time.elapse(const Duration(seconds: 3));
      expect(h.platform.calls, ['start']);
      expect(TurnKeepAliveHold.held, isFalse);
      expect(h.controller.phase, TurnKeepAlivePhase.idle);
      expect(h.releasedMidTurn, 1);
      time.elapse(const Duration(minutes: 1));
      expect(h.platform.calls, ['start']);
      h.controller.dispose();
    });
  });

  // conn-registry (REVISION-3 #3 / REVISION-4 B, coordinator: «la retención
  // debe permanecer mientras haya turno o hijos vivos y reintentar con
  // backoff»): a lost socket no longer ends the hold; the working chat
  // redials and re-attaches under it (Desktop reconnects during a turn:
  // apps/desktop/src/store/gateway.ts:1103). The check restarts once and
  // the 30 min cap still bounds it.
  test('the socket of the turn is lost and stays down: the hold stays while '
      'the turn works, the check restarts once, the cap still ends it', () {
    fakeAsync((time) {
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      h.connected = false;
      h.allConnected = false;
      time.elapse(const Duration(minutes: 5));
      expect(h.controller.phase, TurnKeepAlivePhase.holding);
      expect(TurnKeepAliveHold.held, isTrue);
      expect(h.platform.calls, ['start']);
      expect(h.releasedMidTurn, 1, reason: 'the check restarts once');
      time.elapse(TurnKeepAliveController.defaultCap);
      expect(TurnKeepAliveHold.held, isFalse);
      expect(h.platform.calls, ['start', 'stop']);
      h.controller.dispose();
    });
  });

  test('a socket cut DURING the hold keeps it before, during and after the '
      'cut (Wi-Fi to mobile data)', () {
    fakeAsync((time) {
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      expect(TurnKeepAliveHold.held, isTrue, reason: 'held before the cut');
      h.connected = false;
      h.allConnected = false;
      h.controller.reevaluate(); // the registry change, as main.dart wires it
      time.elapse(const Duration(minutes: 2));
      expect(h.controller.phase, TurnKeepAlivePhase.holding);
      expect(TurnKeepAliveHold.held, isTrue, reason: 'held during the cut');
      h.connected = true;
      h.allConnected = true;
      h.controller.reevaluate();
      time.elapse(const Duration(minutes: 3));
      expect(TurnKeepAliveHold.held, isTrue, reason: 'held after the cut');
      expect(h.platform.calls, ['start']);
      // The turn ends: the usual 5 s grace releases it.
      h.working = false;
      h.controller.reevaluate();
      time.elapse(const Duration(seconds: 6));
      expect(TurnKeepAliveHold.held, isFalse);
      h.controller.dispose();
    });
  });

  test('a start still needs a live socket', () {
    fakeAsync((time) {
      final h = _Harness()..connected = false;
      h.leave();
      time.elapse(const Duration(seconds: 3));
      expect(h.platform.calls, isEmpty);
      expect(TurnKeepAliveHold.held, isFalse);
      h.controller.dispose();
    });
  });

  test('two chats, two servers: one socket lost while the other holds -> the '
      'check restarts once, the hold goes on', () {
    fakeAsync((time) {
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      expect(h.releasedMidTurn, 0);
      // Chat B (server Y) loses its socket; chat A (server X) is still up.
      h.allConnected = false;
      time.elapse(const Duration(seconds: 15));
      expect(h.releasedMidTurn, 1);
      expect(h.controller.phase, TurnKeepAlivePhase.holding);
      expect(TurnKeepAliveHold.held, isTrue);
      // Only once while it lasts.
      time.elapse(const Duration(minutes: 2));
      expect(h.releasedMidTurn, 1);
      expect(h.platform.calls, ['start']);
      h.controller.dispose();
    });
  });

  test('a second loss after everything was up again restarts the check '
      'again; losing the last socket keeps the hold while the turn works', () {
    fakeAsync((time) {
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      h.allConnected = false;
      time.elapse(const Duration(seconds: 15));
      expect(h.releasedMidTurn, 1);
      h.allConnected = true;
      time.elapse(const Duration(seconds: 15));
      h.allConnected = false;
      time.elapse(const Duration(seconds: 15));
      expect(h.releasedMidTurn, 2);
      // The last socket goes too: the hold stays while the turn works
      // (REVISION-4 B); the turn's end releases it and hands over once.
      h.connected = false;
      time.elapse(const Duration(seconds: 20));
      expect(TurnKeepAliveHold.held, isTrue);
      expect(h.platform.calls, ['start']);
      h.working = false;
      h.controller.reevaluate();
      time.elapse(const Duration(seconds: 6));
      expect(h.platform.calls, ['start', 'stop']);
      h.controller.dispose();
    });
  });

  test('back while the start is in flight: the stop follows the start', () {
    fakeAsync((time) {
      final h = _Harness();
      final gate = Completer<bool>();
      h.platform.startGate = gate;
      h.leave();
      time.elapse(const Duration(seconds: 2));
      expect(h.platform.calls, ['start']);
      h.back();
      time.flushMicrotasks();
      expect(h.platform.calls, ['start']);
      gate.complete(true);
      time.flushMicrotasks();
      expect(h.platform.calls, ['start', 'stop']);
      expect(TurnKeepAliveHold.held, isFalse);
      expect(h.controller.phase, TurnKeepAlivePhase.idle);
      h.controller.dispose();
    });
  });

  test('dispose stops a hold and leaves no timer behind', () {
    fakeAsync((time) {
      final h = _Harness();
      h.leave();
      time.elapse(const Duration(seconds: 3));
      h.controller.dispose();
      time.flushMicrotasks();
      expect(h.platform.calls, ['start', 'stop']);
      expect(TurnKeepAliveHold.held, isFalse);
      expect(h.platform.hasEndedListener, isFalse);
      expect(time.pendingTimers, isEmpty);
    });
  });

  group('a refused start never takes the app down', () {
    const channel = MethodChannel('hermes/turn_keepalive');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('the channel throws (dataSync budget, not allowed, security): '
        'start answers false, stop is quiet', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'ForegroundServiceStartNotAllowedException',
        );
      });
      final platform = MethodChannelTurnKeepAlivePlatform();
      expect(
        await platform.start(
          title: 't',
          text: 'x',
          cap: const Duration(minutes: 30),
        ),
        isFalse,
      );
      await expectLater(platform.stop(), completes);
    });

    test('no native side at all: false, no exception', () async {
      final platform = MethodChannelTurnKeepAlivePlatform();
      expect(
        await platform.start(
          title: 't',
          text: 'x',
          cap: const Duration(minutes: 30),
        ),
        isFalse,
      );
    });

    test('a throwing platform: not holding, no retry until the next turn, '
        'the background check takes over', () {
      fakeAsync((time) {
        final h = _Harness();
        h.platform.startThrows = StateError('ForegroundServiceStartNotAllowed');
        h.leave();
        time.elapse(const Duration(seconds: 3));
        expect(h.platform.calls, ['start']);
        expect(h.controller.phase, TurnKeepAlivePhase.idle);
        expect(h.controller.holding, isFalse);
        expect(TurnKeepAliveHold.held, isFalse);
        expect(h.controller.refusedThisTurn, isTrue);
        expect(h.releasedMidTurn, 1);
        // Same turn, another departure: no new attempt.
        h.platform.startThrows = null;
        h.back();
        h.leave();
        time.elapse(const Duration(seconds: 5));
        expect(h.platform.calls, ['start']);
        // The turn ends; the next one may try again.
        h.back();
        h.working = false;
        h.controller.reevaluate();
        expect(h.controller.refusedThisTurn, isFalse);
        h.working = true;
        h.leave();
        time.elapse(const Duration(seconds: 3));
        expect(h.platform.calls, ['start', 'start']);
        expect(TurnKeepAliveHold.held, isTrue);
        h.controller.dispose();
      });
    });

    test('the native side refuses after the start call: released, no retry '
        'in this turn', () {
      fakeAsync((time) {
        final h = _Harness();
        h.leave();
        time.elapse(const Duration(seconds: 3));
        expect(TurnKeepAliveHold.held, isTrue);
        h.platform.end('refused');
        time.flushMicrotasks();
        expect(TurnKeepAliveHold.held, isFalse);
        expect(h.controller.phase, TurnKeepAlivePhase.idle);
        expect(h.platform.calls, ['start']);
        expect(h.releasedMidTurn, 1);
        h.back();
        h.leave();
        time.elapse(const Duration(seconds: 5));
        expect(h.platform.calls, ['start']);
        h.controller.dispose();
      });
    });
  });
}
