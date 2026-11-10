// One card while a turn works in the background (Pixel 9980, SC5off
// `single_live_card`: the keep-alive's own card, id 258, showed next to the
// live row on Android 16).
//
// The native side now shows the chat's live row AS the service card
// (HermesTurnKeepAliveService carries it: startForeground has no tag, so the
// row is drawn at the service's id while it holds and put back under its own
// tag when it stops). That only works if Dart keeps this contract, pinned
// here with the real LiveTurnNotifications and the real controller writing
// to one log:
//
// * every live row is a chat row the service can adopt: id 2, its chat tag,
//   the session id, owner-bound, the bounded background lifetime;
// * a turn that ends in the background withdraws its row (cancel) BEFORE the
//   service stops (5 s grace), and nothing posts the row after the cancel: the
//   native stop then has nothing to put back (no ghost);
// * back in the app the stop reaches the platform BEFORE the row's cancel:
//   the row put back under its tag is taken down by that cancel;
// * when the service ends with the turn still running (cap, system timeout)
//   Dart sends no cancel: the row the service put back stays, as it should.
import 'dart:async';
import 'dart:ui' show AppLifecycleState;

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/live_turn_notifications.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/turn_keepalive_controller.dart';
import 'package:hermes_android/core/services/turn_keepalive_hold.dart';

const es = NotifL10n(true);
const key = 'conn-a/default/sess-1';

LiveTurnSnapshot turn({
  LiveTurnPhase phase = LiveTurnPhase.thinking,
  int tools = 0,
}) => LiveTurnSnapshot(
  connId: 'conn-a',
  profile: 'default',
  sessionId: 'sess-1',
  title: 'Informe de ventas',
  phase: phase,
  tools: tools,
  startedAtMs: 1800000000000,
);

/// One ordered log for the tray (sink) and the service (platform), with the
/// fake clock's time of each entry.
class _Log {
  _Log(this.elapsed);
  final Duration Function() elapsed;
  final entries = <String>[];
  final at = <Duration>[];
  final posted = <Map<String, Object?>>[];

  void add(String entry) {
    entries.add(entry);
    at.add(elapsed());
  }

  Duration when(String entry) => at[entries.lastIndexOf(entry)];
}

class _Sink implements RichNotificationSink {
  _Sink(this.log);
  final _Log log;

  @override
  Future<void> cancel({required int id, String? tag}) async =>
      log.add('cancel $id $tag');

  @override
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs = 4000,
    bool onlyIfActive = false,
  }) async => log.add('confirm $id $tag');

  @override
  Future<bool> postConversation(Map<String, Object?> args) async {
    log.add('conversation ${args['id']} ${args['tag']}');
    return true;
  }

  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async {
    log.posted.add(args);
    log.add('post ${args['id']} ${args['tag']}');
  }
}

class _Platform implements TurnKeepAlivePlatform {
  _Platform(this.log);
  final _Log log;
  void Function(String reason)? _ended;

  @override
  set onEnded(void Function(String reason)? callback) => _ended = callback;

  void end(String reason) => _ended?.call(reason);

  @override
  Future<bool> start({
    required String title,
    required String text,
    required Duration cap,
  }) async {
    log.add('start');
    return true;
  }

  @override
  Future<void> stop() async => log.add('stop');
}

class _World {
  _World(FakeAsync time, {Duration cap = TurnKeepAliveController.defaultCap}) {
    final origin = DateTime.utc(2027, 1, 1);
    log = _Log(() => time.elapsed);
    live = LiveTurnNotifications(
      sink: _Sink(log),
      strings: () => es,
      now: () => origin.add(time.elapsed),
    );
    platform = _Platform(log);
    controller = TurnKeepAliveController(
      platform: platform,
      working: () => working,
      transportUp: () => true,
      allTransportUp: () => true,
      enabled: () => true,
      appLocked: () => false,
      notificationsAllowed: () async => true,
      copy: () => (title: 'Hermes está trabajando', text: 'Console mantiene'),
      onReleasedMidTurn: () => releasedMidTurn++,
      cap: cap,
    );
  }

  late final _Log log;
  late final LiveTurnNotifications live;
  late final _Platform platform;
  late final TurnKeepAliveController controller;
  bool working = true;
  int releasedMidTurn = 0;

  String get tag => liveTurnTag(turn());

  /// What main does on the hidden edge: the row goes to the tray (the app
  /// is away), then the keep-alive's 2 s window opens.
  Future<void> leave(LiveTurnSnapshot snapshot) async {
    controller.lifecycleChanged(AppLifecycleState.inactive);
    controller.lifecycleChanged(AppLifecycleState.hidden);
    controller.lifecycleChanged(AppLifecycleState.paused);
    await live.update(key, snapshot, show: true, background: true);
  }

  /// The chat's turn moved on (or ended: null) while the app is away.
  Future<void> report(LiveTurnSnapshot? snapshot) async {
    working = snapshot != null;
    await live.update(key, snapshot, show: true, background: true);
    controller.reevaluate();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(TurnKeepAliveHold.resetForTesting);
  tearDown(TurnKeepAliveHold.resetForTesting);

  test('every row is an adoptable chat row: id 2, chat tag, session, '
      'owner-bound, bounded lifetime', () {
    fakeAsync((time) {
      final w = _World(time);
      unawaited(w.leave(turn()));
      time.elapse(const Duration(seconds: 3));
      unawaited(w.report(turn(phase: LiveTurnPhase.usingTool, tools: 2)));
      time.elapse(const Duration(seconds: 6));
      expect(w.log.posted, hasLength(2));
      for (final args in w.log.posted) {
        expect(args['id'], RichNotificationIds.live);
        expect(args['id'], 2);
        expect(args['tag'], w.tag);
        expect('${args['tag']}', startsWith('hermes.chat.'));
        // The native side tells a chat row (adoptable) by its session.
        expect(args['sessionId'], 'sess-1');
        expect(args['ownerBound'], isTrue);
        expect(
          args['timeoutMs'],
          LiveTurnNotifications.backgroundRowLifetime.inMilliseconds,
        );
        // Silent card with Stop: what the service card shows.
        expect(args['stopLabel'], isNotNull);
      }
      w.controller.dispose();
    });
  });

  test('turn ends in the background: the row is cancelled first, the service '
      'stops 5 s later, and nothing posts the row in between', () {
    fakeAsync((time) {
      final w = _World(time);
      unawaited(w.leave(turn()));
      time.elapse(const Duration(seconds: 3));
      unawaited(w.report(turn(phase: LiveTurnPhase.usingTool, tools: 2)));
      time.elapse(const Duration(seconds: 30));
      unawaited(w.report(null));
      time.elapse(const Duration(seconds: 10));
      final cancel = 'cancel 2 ${w.tag}';
      final post = 'post 2 ${w.tag}';
      expect(w.log.entries, [post, 'start', post, cancel, 'stop']);
      expect(
        w.log.when('stop') - w.log.when(cancel),
        greaterThanOrEqualTo(const Duration(seconds: 5)),
      );
      // Nothing for the background check to take over: the turn is over.
      expect(w.releasedMidTurn, 0);
      expect(w.live.shownKeys, isEmpty);
      w.controller.dispose();
    });
  });

  test('back in the app: the stop reaches the platform before the row is '
      'withdrawn', () {
    fakeAsync((time) {
      final w = _World(time);
      unawaited(w.leave(turn()));
      time.elapse(const Duration(seconds: 3));
      // What main does on resume: the controller first, then the tray policy
      // takes the row down (the app is on screen).
      w.controller.lifecycleChanged(AppLifecycleState.inactive);
      w.controller.lifecycleChanged(AppLifecycleState.resumed);
      unawaited(w.live.refresh((_) => false));
      time.flushMicrotasks();
      final cancel = 'cancel 2 ${w.tag}';
      expect(w.log.entries, ['post 2 ${w.tag}', 'start', 'stop', cancel]);
      expect(w.log.entries.indexOf('stop'), lessThan(w.log.entries.indexOf(cancel)));
      w.controller.dispose();
    });
  });

  test('the cap ends the hold mid-turn: a stop and no cancel (the row the '
      'service puts back stays and keeps updating)', () {
    fakeAsync((time) {
      final w = _World(time, cap: const Duration(minutes: 1));
      unawaited(w.leave(turn()));
      time.elapse(const Duration(seconds: 3));
      time.elapse(const Duration(minutes: 1));
      expect(w.log.entries, ['post 2 ${w.tag}', 'start', 'stop']);
      expect(w.live.shownKeys, {key});
      expect(w.releasedMidTurn, 1);
      // Later news of the same turn goes to the same address.
      unawaited(w.report(turn(phase: LiveTurnPhase.responding)));
      time.elapse(const Duration(seconds: 6));
      expect(w.log.entries.last, 'post 2 ${w.tag}');
      expect(w.log.entries.where((e) => e.startsWith('cancel')), isEmpty);
      w.controller.dispose();
    });
  });

  test('the system ends the service (timeout): neither a stop call nor a '
      'cancel from Dart; the row stays', () {
    fakeAsync((time) {
      final w = _World(time);
      unawaited(w.leave(turn()));
      time.elapse(const Duration(seconds: 3));
      w.platform.end('timeout');
      time.elapse(const Duration(seconds: 10));
      expect(w.log.entries, ['post 2 ${w.tag}', 'start']);
      expect(w.live.shownKeys, {key});
      expect(w.releasedMidTurn, 1);
      w.controller.dispose();
    });
  });

  test('content hidden: the row the service shows is the redacted one', () {
    fakeAsync((time) {
      final w = _World(time);
      w.controller.lifecycleChanged(AppLifecycleState.hidden);
      unawaited(
        w.live.update(
          key,
          turn(phase: LiveTurnPhase.usingTool, tools: 2),
          show: true,
          hideSensitive: true,
          background: true,
        ),
      );
      time.elapse(const Duration(seconds: 3));
      expect(w.log.entries, ['post 2 ${w.tag}', 'start']);
      final args = w.log.posted.single;
      expect(args['title'], isNot(contains('Informe de ventas')));
      expect(args['text'], args['publicText']);
      expect(args['subText'], isNull);
      w.controller.dispose();
    });
  });
}
