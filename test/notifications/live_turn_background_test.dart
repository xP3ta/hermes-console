// The live row of a chat turn when the app is in the background and Android
// cut its socket: the background check ends it, its lifetime is
// bounded, it keeps the last real state while a check is pending and says
// «no connection · retrying» only after reads failed to reach the server,
// and the check never announces a running turn as finished.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/live_turn_check.dart';
import 'package:hermes_android/core/services/notifications/live_turn_notifications.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/notifications/session_attention.dart';
import 'package:shared_preferences/shared_preferences.dart';

const es = NotifL10n(true);
const languages = ['es', 'en', 'de', 'fr', 'it', 'pt', 'ja', 'ko', 'zh'];

const started = 1800000000000;

LiveTurnSnapshot turn({
  String sessionId = 'sess-1',
  String title = 'Informe de ventas',
  int? startedAtMs = started,
  LiveTurnPhase phase = LiveTurnPhase.thinking,
  int tools = 0,
  String profile = 'default',
}) => LiveTurnSnapshot(
  connId: 'conn-a',
  profile: profile,
  sessionId: sessionId,
  title: title,
  phase: phase,
  tools: tools,
  startedAtMs: startedAtMs,
);

/// Seconds since the epoch, as Hermes stores message timestamps.
double at(int ms) => ms / 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('copy', () {
    test('every language has the offline line and a chip of ≤ 7 chars', () {
      for (final lang in languages) {
        final t = NotifL10n(lang);
        expect(t.liveOffline, isNotEmpty, reason: lang);
        expect(t.liveOffline, isNot(contains('{')), reason: lang);
        expect(t.liveOffline, isNot(t.livePhase(LiveTurnPhase.thinking)));
        expect(
          t.liveOfflineChip.runes.length,
          lessThanOrEqualTo(7),
          reason: lang,
        );
      }
      expect(es.liveOffline, 'Sin conexión · reintentando…');
    });

    test('an offline row says so, without stale counts, also when hidden', () {
      final online = liveTurnArgs(es, turn(tools: 3), who: 'Hermes');
      expect(online['text'], 'Pensando · 3 herramientas');
      expect(online['sessionId'], 'sess-1');
      final offline = liveTurnArgs(
        es,
        turn(tools: 3),
        who: 'Hermes',
        offline: true,
      );
      expect(offline['text'], 'Sin conexión · reintentando…');
      expect(offline['bigText'], 'Sin conexión · reintentando…');
      expect(offline['publicText'], 'Sin conexión · reintentando…');
      expect(offline['shortText'], 'Sin red');
      expect(offline['title'], 'Informe de ventas');
      final hidden = liveTurnArgs(
        es,
        turn(tools: 3),
        who: 'Hermes',
        offline: true,
        hideSensitive: true,
      );
      expect(
        hidden['title'],
        'Hermes',
        reason: 'offline it does not claim that it works',
      );
      expect(hidden['publicTitle'], 'Hermes');
      expect(hidden['text'], 'Sin conexión · reintentando…');
      for (final key in const [
        'title',
        'text',
        'bigText',
        'subText',
        'publicTitle',
        'publicText',
      ]) {
        expect(
          '${hidden[key]}',
          isNot(contains('Informe de ventas')),
          reason: key,
        );
      }
    });
  });

  group('presenter', () {
    late _Sink sink;
    var now = DateTime.fromMillisecondsSinceEpoch(started);
    LiveTurnNotifications presenter() =>
        LiveTurnNotifications(sink: sink, strings: () => es, now: () => now);

    setUp(() {
      sink = _Sink();
      now = DateTime.fromMillisecondsSinceEpoch(started);
    });

    test('a background row lives 12 min; in front 30 min', () async {
      final live = presenter();
      await live.update('k', turn(), show: true);
      expect(
        sink.live.last['timeoutMs'],
        LiveTurnNotifications.rowLifetime.inMilliseconds,
      );
      // Leaving the screen re-posts at once (not after the rate window).
      await live.refresh((_) => true, background: true);
      expect(sink.live, hasLength(2));
      expect(
        sink.live.last['timeoutMs'],
        LiveTurnNotifications.backgroundRowLifetime.inMilliseconds,
      );
      expect(
        LiveTurnNotifications.backgroundRowLifetime,
        greaterThan(LiveTurnCheckPolicy.window),
      );
    });

    test(
      'an external end: the row goes and the same turn is not drawn again',
      () async {
        final live = presenter();
        await live.update('k', turn(), show: true, background: true);
        final tag = sink.live.single['tag'];
        expect(await live.settle('sess-1', endedAtMs: started + 27000), 1);
        expect(sink.cancelled, [tag]);
        expect(live.shownKeys, isEmpty);
        // The chat, still unaware, reports the same turn (presence, renew).
        now = now.add(const Duration(minutes: 11));
        await live.update('k', turn(), show: true, background: true);
        await live.refresh((_) => true, background: true);
        await live.refresh((_) => true);
        expect(sink.live, hasLength(1));
        // A new turn of the same chat is drawn.
        await live.update('k', turn(startedAtMs: started + 60000), show: true);
        expect(sink.live, hasLength(2));
      },
    );

    test('a row ended by mistake comes back when the same turn moves on',
        () async {
      final live = presenter();
      await live.update('k', turn(), show: true);
      expect(await live.settle('sess-1'), 1);
      expect(live.shownKeys, isEmpty);
      // The same report again, or only a new title, proves nothing.
      now = now.add(const Duration(seconds: 6));
      await live.update('k', turn(), show: true);
      await live.update('k', turn(title: 'Otro título'), show: true);
      expect(sink.live, hasLength(1));
      // A new phase of the same turn: the socket sees it running.
      await live.update(
        'k',
        turn(title: 'Otro título', phase: LiveTurnPhase.responding),
        show: true,
      );
      expect(sink.live, hasLength(2));
      expect(sink.live.last['text'], 'Respondiendo');
      expect(live.shownKeys, {'k'});
      now = now.add(const Duration(seconds: 6));
      await live.update(
        'k',
        turn(
          title: 'Otro título',
          phase: LiveTurnPhase.responding,
          tools: 1,
        ),
        show: true,
      );
      expect(sink.live, hasLength(3));
    });

    test('a row ended under the chat\'s old id (compression) comes back '
        'under the new one', () async {
      final live = presenter();
      await live.update('k', turn(), show: true);
      expect(await live.settle('sess-1'), 1);
      await live.update('k', turn(sessionId: 'sess-2'), show: true);
      expect(sink.live, hasLength(2));
      expect(sink.live.last['sessionId'], 'sess-2');
    });

    test('the end of a turn never takes the row of the next one', () async {
      final live = presenter();
      await live.update('k', turn(), show: true);
      expect(await live.settle('sess-1', endedAtMs: started - 60000), 0);
      // A follow-up sent one second after the previous turn ended.
      expect(await live.settle('sess-1', endedAtMs: started - 1000), 0);
      expect(sink.cancelled, isEmpty);
      expect(live.shownKeys, {'k'});
      expect(await live.settle('sess-1', endedAtMs: started + 27000), 1);
    });

    test('another chat is not touched', () async {
      final live = presenter();
      await live.update('k', turn(), show: true);
      expect(await live.settle('sess-2'), 0);
      expect(sink.cancelled, isEmpty);
    });

    test(
      'offline: at once after the failures; news from the socket or the '
      'foreground clear it',
      () async {
        final live = presenter();
        await live.update('k', turn(), show: true, background: true);
        expect(await live.checkFailed('sess-1'), 0, reason: 'one blip');
        expect(await live.checkFailed('sess-1'), 1);
        expect(sink.live, hasLength(2), reason: 'not held by the rate window');
        expect(sink.live.last['text'], 'Sin conexión · reintentando…');
        expect(await live.checkFailed('sess-1'), 0, reason: 'already offline');
        // The same turn reported again proves nothing.
        now = now.add(const Duration(seconds: 6));
        await live.update('k', turn(), show: true, background: true);
        expect(sink.live.last['text'], 'Sin conexión · reintentando…');
        // A changed turn is news from the socket.
        now = now.add(const Duration(seconds: 6));
        await live.update(
          'k',
          turn(phase: LiveTurnPhase.responding),
          show: true,
          background: true,
        );
        expect(sink.live.last['text'], 'Respondiendo');
        // ...and the failures count again from zero.
        expect(await live.checkFailed('sess-1'), 0);
        expect(await live.checkFailed('sess-1'), 1);
        await live.refresh((_) => true);
        expect(sink.live.last['text'], 'Respondiendo');
        expect(await live.checkFailed('sess-1'), 0, reason: 'reset in front');
      },
    );
  });

  group('turn outcome from the durable rows', () {
    Map<String, Object?> user(int ms, [String text = 'hola']) => {
      'role': 'user',
      'content': text,
      'timestamp': at(ms),
    };
    Map<String, Object?> assistant(int ms, String text, {bool tool = false}) =>
        {
          'role': 'assistant',
          'content': text,
          'timestamp': at(ms),
          if (tool)
            'tool_calls': [
              {'id': 'c1'},
            ],
        };

    test('no start or no rows: unknown', () {
      expect(
        liveTurnOutcomeOf([user(started)], startedAtMs: null).state,
        LiveTurnRemoteState.unknown,
      );
      expect(
        liveTurnOutcomeOf(null, startedAtMs: started).state,
        LiveTurnRemoteState.unknown,
      );
      expect(
        liveTurnOutcomeOf([
          assistant(started + 9000, 'listo'),
        ], startedAtMs: started).state,
        LiveTurnRemoteState.unknown,
        reason: 'no prompt in the window: cannot be attributed',
      );
    });

    test('the previous turn finished, this prompt not saved yet: running', () {
      final rows = [
        user(started - 90000, 'anterior'),
        assistant(started - 80000, 'respuesta anterior'),
      ];
      expect(
        liveTurnOutcomeOf(rows, startedAtMs: started).state,
        LiveTurnRemoteState.running,
      );
    });

    test('a tool still pending: running', () {
      expect(
        liveTurnOutcomeOf([
          user(started + 500),
          assistant(started + 3000, '', tool: true),
        ], startedAtMs: started).state,
        LiveTurnRemoteState.running,
      );
      expect(
        liveTurnOutcomeOf([
          user(started + 500),
          assistant(started + 3000, '', tool: true),
          {'role': 'tool', 'content': 'ok', 'timestamp': at(started + 4000)},
        ], startedAtMs: started).state,
        LiveTurnRemoteState.running,
      );
      expect(
        liveTurnOutcomeOf([user(started + 500)], startedAtMs: started).state,
        LiveTurnRemoteState.running,
      );
    });

    test('a final answer after this prompt: finished, preview redacted', () {
      final outcome = liveTurnOutcomeOf([
        user(started + 500),
        assistant(started + 3000, '', tool: true),
        {'role': 'tool', 'content': 'ok', 'timestamp': at(started + 4000)},
        assistant(started + 27000, 'Hecho. La clave es sk-abcdefghijklmnop'),
      ], startedAtMs: started);
      expect(outcome.state, LiveTurnRemoteState.finished);
      expect(outcome.endedAtMs, started + 27000);
      expect(outcome.preview, startsWith('Hecho.'));
      expect(outcome.preview, isNot(contains('sk-abcdefghijklmnop')));
    });

    test('a reply sent < 5 s after the previous answer, not saved yet: the '
        'previous answer does not end it', () {
      // Within the clock skew the previous prompt looks like this turn's;
      // only the answer's own time (before this start) tells them apart.
      final rows = [
        user(started - 4000, 'anterior'),
        assistant(started - 2000, 'respuesta anterior'),
      ];
      final outcome = liveTurnOutcomeOf(rows, startedAtMs: started);
      expect(outcome.state, LiveTurnRemoteState.running);
      expect(outcome.preview, isEmpty);
      expect(
        liveTurnOutcomeOf([
          user(started - 4000, 'anterior'),
          {'role': 'assistant', 'content': 'sin hora'},
        ], startedAtMs: started).state,
        LiveTurnRemoteState.running,
        reason: 'an answer without a time proves nothing',
      );
      expect(
        liveTurnOutcomeOf([
          user(started - 4000, 'anterior'),
          {
            'role': 'assistant',
            'content': 'x',
            'error': 'boom',
            'timestamp': at(started - 1000),
          },
        ], startedAtMs: started).state,
        LiveTurnRemoteState.running,
        reason: 'neither does an earlier error',
      );
    });

    test('event notices and corrections do not open the turn', () {
      // A runtime notice saved after this turn's start is not its prompt:
      // the previous answer below it does not end this turn.
      final rows = [
        user(started - 90000, 'anterior'),
        assistant(started - 80000, 'respuesta anterior'),
        {
          'role': 'user',
          'content': '[ASYNC DELEGATION COMPLETE — deleg_0a1b2c3d]\nhecho',
          'display_kind': 'async_delegation_complete',
          'timestamp': at(started + 200),
        },
        {
          'role': 'user',
          'content': 'y también esto',
          'display_kind': 'steer',
          'timestamp': at(started + 300),
        },
        assistant(started + 400, 'respuesta al aviso'),
      ];
      expect(
        liveTurnOutcomeOf(rows, startedAtMs: started).state,
        LiveTurnRemoteState.running,
      );
    });

    test('an error row: failed, without preview', () {
      final outcome = liveTurnOutcomeOf([
        user(started + 500),
        {
          'role': 'assistant',
          'content': 'Traceback secreto',
          'error': 'boom',
          'timestamp': at(started + 9000),
        },
      ], startedAtMs: started);
      expect(outcome.state, LiveTurnRemoteState.failed);
      expect(outcome.preview, isEmpty);
    });
  });

  group('one run of the check', () {
    final signals = <SessionAttentionSignal>[];
    var reads = 0;
    var locked = false;
    Object? rows;
    Object? error;

    LiveTurnBackgroundCheck check() => LiveTurnBackgroundCheck(
      read: (turn) async {
        reads++;
        if (error != null) throw error!;
        return rows;
      },
      appLocked: () => locked,
      deliver: (signal) async => signals.add(signal),
    );

    setUp(() {
      signals.clear();
      reads = 0;
      locked = false;
      error = null;
      rows = [
        {'role': 'user', 'content': 'x', 'timestamp': at(started + 100)},
        {
          'role': 'assistant',
          'content': 'Listo',
          'timestamp': at(started + 27000),
        },
      ];
    });

    test('App Lock: nothing is asked of the server', () async {
      locked = true;
      final pass = await check().run([turn()]);
      expect(reads, 0);
      expect(pass.pending, 0);
      expect(signals, isEmpty);
    });

    test('a running turn keeps the check reading until it is over '
        '(the Pixel run: the chain ended after one run)', () async {
      rows = [
        {'role': 'user', 'content': 'x', 'timestamp': at(started + 100)},
      ];
      final running = await check().run([turn()]);
      expect(reads, 1);
      expect(running.pending, 1, reason: 'still running: keep checking');
      expect(signals, isEmpty);
      rows = [
        {'role': 'user', 'content': 'x', 'timestamp': at(started + 100)},
        {
          'role': 'assistant',
          'content': 'Listo',
          'timestamp': at(started + 41000),
        },
      ];
      final done = await check().run([turn()]);
      expect(done.pending, 0);
      expect(done.ended, ['sess-1']);
      expect(signals.single.kind, SessionAttentionKind.turnDone);
      expect(signals.single.endedAtMs, started + 41000);
    });

    test(
      'a finished turn is announced with its preview and end time',
      () async {
        final pass = await check().run([turn(profile: 'Work')]);
        expect(reads, 1);
        expect(pass.pending, 0);
        expect(pass.ended, ['sess-1']);
        final signal = signals.single;
        expect(signal.kind, SessionAttentionKind.turnDone);
        expect(signal.storedSessionId, 'sess-1');
        expect(signal.profile, 'work');
        expect(signal.preview, 'Listo');
        expect(signal.endedAtMs, started + 27000);
      },
    );

    test('a failed turn alerts as a failure', () async {
      rows = [
        {'role': 'user', 'content': 'x', 'timestamp': at(started + 100)},
        {
          'role': 'assistant_error',
          'content': 'x',
          'timestamp': at(started + 900),
        },
      ];
      await check().run([turn()]);
      expect(signals.single.kind, SessionAttentionKind.turnError);
    });

    test(
      'no network or a running turn: keep checking, announce nothing',
      () async {
        error = const SocketException('down');
        expect((await check().run([turn()])).pending, 1);
        error = null;
        rows = [
          {'role': 'user', 'content': 'x', 'timestamp': at(started + 100)},
        ];
        expect((await check().run([turn()])).pending, 1);
        expect(signals, isEmpty);
      },
    );

    test('one run answers within its budget, well before the worker gives '
        'up (45 s)', () async {
      expect(
        LiveTurnCheckPolicy.runBudget,
        lessThan(const Duration(seconds: 35)),
      );
      final asked = <String>[];
      final hung = LiveTurnBackgroundCheck(
        read: (turn) {
          asked.add(turn.sessionId);
          return Completer<Object?>().future; // a server that never answers
        },
        appLocked: () => false,
        deliver: (_) async {},
        budget: const Duration(milliseconds: 250),
        readTimeout: const Duration(milliseconds: 100),
      );
      final turns = [for (var i = 0; i < 6; i++) turn(sessionId: 's$i')];
      final clock = Stopwatch()..start();
      final pass = await hung.run(turns);
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      expect(pass.pending, 6, reason: 'unread chats wait for the next run');
      expect(asked.length, lessThan(6));
      // The next run starts elsewhere: no chat is starved by a hung one.
      asked.clear();
      await hung.run(turns, attempt: 1);
      expect(asked.first, 's1');
    });

    test('cadence: first run ~25 s, then 20/30/45 s, 10 min cap', () {
      expect(LiveTurnCheckPolicy.firstDelay, const Duration(seconds: 25));
      expect(LiveTurnCheckPolicy.cadence, const [
        Duration(seconds: 20),
        Duration(seconds: 30),
        Duration(seconds: 45),
      ]);
      expect(LiveTurnCheckPolicy.window, const Duration(minutes: 10));
      Duration? next(int attempt, Duration elapsed, {int pending = 1}) =>
          LiveTurnCheckPolicy.next(
            attempt: attempt,
            elapsed: elapsed,
            pending: pending,
          );
      const first = LiveTurnCheckPolicy.firstDelay;
      expect(next(0, first), const Duration(seconds: 20));
      expect(next(1, const Duration(seconds: 45)), const Duration(seconds: 30));
      expect(next(2, const Duration(seconds: 75)), const Duration(seconds: 45));
      expect(next(9, const Duration(minutes: 6)), const Duration(seconds: 45));
      expect(next(0, first, pending: 0), isNull, reason: 'nothing pending');
      expect(
        next(12, const Duration(minutes: 9, seconds: 30)),
        isNull,
        reason: 'the next run would pass the window',
      );
      // A turn that never ends: a bounded number of runs, never past the
      // window (battery bound).
      var elapsed = first;
      var runs = 1;
      for (var attempt = 0; ; attempt++) {
        final delay = next(attempt, elapsed);
        if (delay == null) break;
        elapsed += delay;
        runs++;
      }
      expect(elapsed, lessThanOrEqualTo(LiveTurnCheckPolicy.window));
      expect(runs, 14);
      // The rows outlive the chain: the row's own 12 min expiry stays.
      expect(
        LiveTurnNotifications.backgroundRowLifetime,
        const Duration(minutes: 12),
      );
    });
  });

  group('service', () {
    late SharedPreferences prefs;
    late _Sink sink;
    late _Scheduler scheduler;
    late NotificationService service;
    late Directory dir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'app_locale': 'es',
        'notif_hide_sensitive_content': true,
      });
      prefs = await SharedPreferences.getInstance();
      dir = await Directory.systemTemp.createTemp('live-bg-');
      sink = _Sink();
      scheduler = _Scheduler();
      service = NotificationService(prefs)
        ..setRichForTesting(
          sink,
          faces: BotFaceBitmapCache(directory: () async => dir),
        )
        ..liveTurnCheckSchedulerForTesting = scheduler;
    });

    tearDown(() => dir.delete(recursive: true));

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 400 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    test(
      'the check is scheduled in the background and cancelled in front',
      () async {
        service.liveTurnChanged('k', turn());
        service.appInForeground = false;
        await until(() => scheduler.scheduled.isNotEmpty);
        expect(scheduler.scheduled, [LiveTurnCheckPolicy.firstDelay]);
        service.appInForeground = true;
        await until(() => scheduler.cancelled > 0);
        expect(scheduler.cancelled, 1);
      },
    );

    test('an external turn end ends the live row in the UI engine', () async {
      service.appInForeground = false;
      service.liveTurnChanged('k', turn());
      await until(() => sink.live.isNotEmpty);
      final tag = sink.live.single['tag'];
      await NotificationSessionAttentionSink(service).deliver(
        const SessionAttentionSignal(
          kind: SessionAttentionKind.turnDone,
          connId: 'conn-a',
          profile: 'default',
          storedSessionId: 'sess-1',
          endedAtMs: started + 27000,
        ),
      );
      expect(sink.cancelled, contains(tag));
      // The chat, unaware, reports the turn again: it stays withdrawn.
      service.liveTurnChanged('k', turn());
      service.appInForeground = true;
      service.appInForeground = false;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(sink.live, hasLength(1));
    });

    test('a run keeps the real state; a finished turn ends it at once',
        () async {
      service.appInForeground = false;
      service.liveTurnChanged('k', turn());
      await until(() => sink.live.isNotEmpty);
      final announced = <SessionAttentionSignal>[];
      Object? rows = [
        {'role': 'user', 'content': 'x', 'timestamp': at(started + 100)},
      ];
      LiveTurnBackgroundCheck check() => LiveTurnBackgroundCheck(
        read: (_) async => rows,
        appLocked: () => false,
        deliver: (signal) async {
          announced.add(signal);
          await NotificationSessionAttentionSink(service).deliver(signal);
        },
      );
      final first = await service.checkLiveTurnsInBackground(check: check());
      expect(first['pending'], 1);
      expect(first['nextDelayMs'], 20000);
      expect(sink.live, hasLength(1), reason: 'running: nothing to redraw');
      expect(sink.live.last['text'], 'Pensando');
      rows = [
        {'role': 'user', 'content': 'x', 'timestamp': at(started + 100)},
        {
          'role': 'assistant',
          'content': 'Listo',
          'timestamp': at(started + 27000),
        },
      ];
      final second = await service.checkLiveTurnsInBackground(
        attempt: 1,
        elapsed: const Duration(seconds: 60),
        check: check(),
      );
      expect(second['pending'], 0);
      expect(announced.single.kind, SessionAttentionKind.turnDone);
      expect(sink.cancelled, contains(sink.live.first['tag']));
      expect(
        (await service.checkLiveTurnsInBackground(check: check()))['pending'],
        0,
        reason: 'no row left: the chain ends',
      );
    });

    test('a worker that never calls back does not leave the check marked '
        'as scheduled', () async {
      service.liveCheckWatchdogAfter = (_) => const Duration(milliseconds: 50);
      service.liveTurnChanged('k', turn());
      service.appInForeground = false;
      await until(() => scheduler.scheduled.isNotEmpty);
      // No `checkLiveTurns` ever arrives: a new chain is asked for.
      await until(() => scheduler.scheduled.length >= 2);
      expect(scheduler.scheduled, hasLength(greaterThanOrEqualTo(2)));
      // A run that answers with a next delay arms it again.
      final before = scheduler.scheduled.length;
      final answer = await service.checkLiveTurnsInBackground(
        check: LiveTurnBackgroundCheck(
          read: (_) async => [
            {'role': 'user', 'content': 'x', 'timestamp': at(started + 100)},
          ],
          appLocked: () => false,
          deliver: (_) async {},
        ),
      );
      expect(answer['nextDelayMs'], 20000);
      await until(() => scheduler.scheduled.length > before);
      expect(scheduler.scheduled.length, greaterThan(before));
      service.appInForeground = true;
      await until(() => scheduler.cancelled > 0);
      final settled = scheduler.scheduled.length;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        scheduler.scheduled,
        hasLength(settled),
        reason: 'in front nothing is rescheduled',
      );
    });

    test('the chain starts at the first delay and goes on while the turn '
        'runs', () async {
      service.liveTurnChanged('k', turn());
      service.appInForeground = false;
      await until(() => scheduler.scheduled.isNotEmpty);
      expect(scheduler.scheduled, [LiveTurnCheckPolicy.firstDelay]);
      await until(() => sink.live.isNotEmpty);
      var reads = 0;
      final answer = await service.checkLiveTurnsInBackground(
        elapsed: LiveTurnCheckPolicy.firstDelay,
        inTray: {'sess-1'},
        check: LiveTurnBackgroundCheck(
          read: (_) async {
            reads++;
            return [
              {'role': 'user', 'content': 'x', 'timestamp': at(started + 100)},
            ];
          },
          appLocked: () => false,
          deliver: (_) async {},
        ),
      );
      expect(reads, 1);
      expect(answer['pending'], 1, reason: 'the worker enqueues another run');
      expect(answer['nextDelayMs'], 20000);
    });

    test('a row the native side already withdrew is settled without a read '
        'or a second notice', () async {
      service.appInForeground = false;
      service.liveTurnChanged('k', turn());
      await until(() => sink.live.isNotEmpty);
      final tag = sink.live.single['tag'];
      final announced = <SessionAttentionSignal>[];
      final answer = await service.checkLiveTurnsInBackground(
        inTray: const {},
        check: LiveTurnBackgroundCheck(
          read: (_) => throw StateError('must not read'),
          appLocked: () => false,
          deliver: (signal) async => announced.add(signal),
        ),
      );
      expect(answer['pending'], 0);
      expect(announced, isEmpty);
      expect(sink.cancelled, contains(tag));
      expect(
        sink.live.where((args) => args['text'] == 'Sin conexión · reintentando…'),
        isEmpty,
        reason: 'not drawn again as offline',
      );
    });

    test('an older native side (no tray list) keeps checking every row',
        () async {
      service.appInForeground = false;
      service.liveTurnChanged('k', turn());
      await until(() => sink.live.isNotEmpty);
      var reads = 0;
      await service.checkLiveTurnsInBackground(
        check: LiveTurnBackgroundCheck(
          read: (_) async {
            reads++;
            return const [];
          },
          appLocked: () => false,
          deliver: (_) async {},
        ),
      );
      expect(reads, 1);
    });

    test('in front the check does nothing', () async {
      service.liveTurnChanged('k', turn());
      final answer = await service.checkLiveTurnsInBackground(
        check: LiveTurnBackgroundCheck(
          read: (_) => throw StateError('must not read'),
          appLocked: () => false,
          deliver: (_) async {},
        ),
      );
      expect(answer['pending'], 0);
    });
  });
}

final class _Sink implements RichNotificationSink {
  final live = <Map<String, Object?>>[];
  final cancelled = <String?>[];
  @override
  Future<void> cancel({required int id, String? tag}) async =>
      cancelled.add(tag);
  @override
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs = 4000,
    bool onlyIfActive = false,
  }) async {}
  @override
  Future<bool> postConversation(Map<String, Object?> args) async => true;
  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async =>
      live.add(args);
}

final class _Scheduler implements LiveTurnCheckScheduler {
  final scheduled = <Duration>[];
  var cancelled = 0;
  @override
  Future<void> schedule(Duration delay) async => scheduled.add(delay);
  @override
  Future<void> cancel() async => cancelled++;
}
