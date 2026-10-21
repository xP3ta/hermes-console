// The live row of a chat turn: plain-word phases, the counts a turn has, a
// rail (one segment per task when there is a list), the lock-screen version,
// when it is posted, renewed and withdrawn, and its Stop.
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session_live_status.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/live_turn_notifications.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

const es = NotifL10n(true);
const en = NotifL10n(false);

LiveTurnSnapshot turn({
  String sessionId = 'sess-1',
  String title = 'Prueba con subagentes',
  String profile = 'default',
  NotificationChatSurface surface = NotificationChatSurface.normal,
  LiveTurnPhase phase = LiveTurnPhase.usingTool,
  String? tool = 'terminal',
  bool toolIsSkill = false,
  int done = 0,
  int total = 0,
  int subagents = 0,
  int tools = 0,
  int? startedAtMs = 1000,
  String? runId,
  bool readOnly = false,
  bool detailed = true,
}) => LiveTurnSnapshot(
  connId: 'conn-a',
  profile: profile,
  sessionId: sessionId,
  title: title,
  surface: surface,
  phase: phase,
  tasksDone: done,
  tasksTotal: total,
  subagents: subagents,
  tools: tools,
  tool: tool,
  toolIsSkill: toolIsSkill,
  startedAtMs: startedAtMs,
  runId: runId,
  readOnly: readOnly,
  detailed: detailed,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('phases', () {
    test('a tool is worded by the shared labeller, in both languages', () {
      expect(liveToolLine(es, 'terminal'), 'Ejecutando comando');
      expect(liveToolLine(en, 'terminal'), 'Running command');
      expect(liveToolLine(es, 'mcp__terminal'), 'Ejecutando comando');
      expect(liveToolLine(es, 'read_file'), 'Leyendo archivo');
      expect(liveToolLine(es, 'search_files'), 'Buscando archivos');
      // Never an id, whatever the tool.
      final unknown = liveToolLine(es, 'some_new_tool');
      expect(unknown, isNot(contains('_')));
      expect(unknown, isNotEmpty);
      // A skill is shown by its own name.
      expect(
        liveToolLine(es, 'Revisión de PR', isSkill: true),
        'Revisión de PR',
      );
    });

    test(
      'the chat status decides the phase; a wait says what it waits for',
      () {
        const waiting = SessionLiveStatus(
          phase: SessionLivePhase.waitingForUser,
        );
        expect(
          liveTurnPhaseOf(waiting, approvalPending: true),
          LiveTurnPhase.waitingForApproval,
        );
        expect(
          liveTurnPhaseOf(waiting, clarifyPending: true),
          LiveTurnPhase.needsClarification,
        );
        expect(liveTurnPhaseOf(waiting), LiveTurnPhase.waitingForYou);
        expect(
          liveTurnPhaseOf(
            const SessionLiveStatus(
              phase: SessionLivePhase.runningTool,
              toolLabel: 'terminal',
            ),
          ),
          LiveTurnPhase.usingTool,
        );
        expect(
          liveTurnPhaseOf(
            const SessionLiveStatus(phase: SessionLivePhase.responding),
          ),
          LiveTurnPhase.responding,
        );
        expect(
          liveTurnPhaseOf(
            const SessionLiveStatus(phase: SessionLivePhase.thinking),
          ),
          LiveTurnPhase.thinking,
        );
        // Another surface owns the detail: only "working" is honest.
        expect(
          liveTurnPhaseOf(
            const SessionLiveStatus(phase: SessionLivePhase.working),
          ),
          LiveTurnPhase.working,
        );
      },
    );

    test('every phase reads in plain words in both languages', () {
      expect(es.livePhase(LiveTurnPhase.thinking), 'Pensando');
      expect(en.livePhase(LiveTurnPhase.thinking), 'Thinking');
      // A tool whose name is not known is just work.
      expect(es.livePhase(LiveTurnPhase.usingTool), 'Trabajando');
      expect(en.livePhase(LiveTurnPhase.usingTool), 'Working');
      expect(es.livePhase(LiveTurnPhase.responding), 'Respondiendo');
      expect(
        es.livePhase(LiveTurnPhase.waitingForApproval),
        'Espera tu permiso',
      );
      expect(
        en.livePhase(LiveTurnPhase.needsClarification),
        'Needs clarification',
      );
      expect(es.livePhase(LiveTurnPhase.working), 'Trabajando');
      for (final t in [es, en]) {
        for (final phase in LiveTurnPhase.values) {
          final line = t.livePhase(phase);
          expect(line, isNotEmpty);
          // Never a tool id.
          expect(line, isNot(contains('_')));
          // Android cuts a chip longer than seven characters.
          expect(
            t.liveChip(phase).length,
            lessThanOrEqualTo(7),
            reason: '$phase',
          );
          expect(t.liveChip(phase), isNotEmpty);
        }
      }
    });
  });

  group('the row', () {
    test('conversation, who, one activity line, timer, Stop and open', () {
      final args = liveTurnArgs(es, turn(), who: 'Hermes');
      expect(args['id'], RichNotificationIds.live);
      expect(
        args['tag'],
        RichNotificationIds.chatTag('conn-a', 'default', 'sess-1'),
      );
      expect(args['title'], 'Prueba con subagentes');
      expect(args['subText'], 'Hermes');
      expect(args['text'], 'Ejecutando comando');
      expect(args['shortText'], 'Trabaja');
      expect(args['startedAtMs'], 1000);
      expect(args['stopLabel'], 'Parar');
      expect(args.containsKey('openLabel'), isFalse);
      final stop = NotificationActionPayload.tryParse(
        args['actionPayload'] as String,
      )!;
      expect(stop.route, NotificationActionRoute.session);
      expect(stop.sessionId, 'sess-1');
      final open = NotificationOpen.tryParse(args['openPayload'] as String)!;
      expect(open.sessionId, 'sess-1');
      expect(open.connId, 'conn-a');
      // Bound to the engine that can end it; a tapped Stop is not redrawn.
      expect(args['ownerBound'], isTrue);
      expect(args['yieldToActions'], isTrue);
    });

    test('counts only when the turn has them', () {
      final args = liveTurnArgs(
        es,
        turn(done: 3, total: 5, subagents: 2, tools: 3),
        who: 'Hermes',
      );
      expect(
        args['text'],
        'Ejecutando comando · Tareas 3 de 5 · 2 subagentes · 3 herramientas',
      );
      expect(
        liveTurnArgs(
          en,
          turn(done: 1, total: 4, subagents: 1, tools: 1),
          who: 'Hermes',
        )['text'],
        'Running command · Tasks 1 of 4 · 1 subagent · 1 tool',
      );
      expect(
        liveTurnArgs(es, turn(), who: 'Hermes')['text'],
        'Ejecutando comando',
      );
      // No tool name: it works, nothing invented.
      expect(
        liveTurnArgs(es, turn(tool: null), who: 'Hermes')['text'],
        'Trabajando',
      );
    });

    test('a task list measures the turn: one segment per task', () {
      final args = liveTurnArgs(es, turn(done: 3, total: 5), who: 'Hermes');
      expect(args['progressMax'], 5);
      expect(args['progress'], 3);
      expect(args['segments'], 5);
      // Too many to draw as segments: one exact bar.
      final many = liveTurnArgs(es, turn(done: 7, total: 20), who: 'Hermes');
      expect(many['progressMax'], 20);
      expect(many['progress'], 7);
      expect(many.containsKey('segments'), isFalse);
    });

    test('without a list the rail only follows the phase', () {
      int rail(LiveTurnPhase phase) =>
          liveTurnArgs(es, turn(phase: phase), who: 'Hermes')['progress']!
              as int;
      final args = liveTurnArgs(es, turn(), who: 'Hermes');
      expect(args['progressMax'], 100);
      expect(args.containsKey('segments'), isFalse);
      expect(
        rail(LiveTurnPhase.thinking),
        lessThan(rail(LiveTurnPhase.usingTool)),
      );
      expect(
        rail(LiveTurnPhase.usingTool),
        lessThan(rail(LiveTurnPhase.waitingForApproval)),
      );
      expect(
        rail(LiveTurnPhase.waitingForApproval),
        lessThan(rail(LiveTurnPhase.responding)),
      );
      expect(rail(LiveTurnPhase.responding), lessThan(100));
    });

    test('lock screen: who and the state, never the conversation', () {
      final args = liveTurnArgs(
        es,
        turn(title: 'Presupuesto secreto', done: 2, total: 4),
        who: 'Forja',
      );
      expect(args['publicTitle'], 'Forja está trabajando');
      // Not which tool, connector or skill: that it works, and the counts.
      expect(args['text'], 'Ejecutando comando · Tareas 2 de 4');
      expect(args['publicText'], 'Trabajando · Tareas 2 de 4');
      expect(
        '${args['publicTitle']}${args['publicText']}',
        isNot(contains('secreto')),
      );
    });

    test('hidden content: the row itself names nothing', () {
      final args = liveTurnArgs(
        es,
        turn(title: 'Presupuesto secreto'),
        who: 'Hermes',
        hideSensitive: true,
      );
      expect(args['title'], 'Hermes está trabajando');
      expect(args.containsKey('subText'), isFalse);
      // Nothing that is drawn names it (the open target is not drawn).
      for (final key in [
        'title',
        'text',
        'bigText',
        'publicTitle',
        'publicText',
      ]) {
        expect('${args[key]}', isNot(contains('Presupuesto')), reason: key);
      }
    });

    test('a read-only connection has no Stop', () {
      final args = liveTurnArgs(es, turn(readOnly: true), who: 'Hermes');
      expect(args.containsKey('stopLabel'), isFalse);
      expect(args.containsKey('actionPayload'), isFalse);
    });

    test('a Bot chat uses the address of its Bot', () {
      final args = liveTurnArgs(
        es,
        turn(profile: 'forja', surface: NotificationChatSurface.bot),
        who: 'Forja',
      );
      expect(args['tag'], RichNotificationIds.botTag('conn-a', 'forja'));
    });

    test('only "it runs" is known: the name and one honest word', () {
      final args = liveTurnArgs(
        es,
        turn(
          title: '',
          phase: LiveTurnPhase.working,
          detailed: false,
          startedAtMs: null,
        ),
        who: 'Hermes',
      );
      expect(args['title'], 'Hermes');
      expect(args['text'], 'Trabajando');
      expect(args['publicTitle'], 'Hermes');
      expect(args.containsKey('startedAtMs'), isFalse);
    });
  });

  group('presenter', () {
    late _Sink sink;
    late DateTime now;
    LiveTurnNotifications presenter() =>
        LiveTurnNotifications(sink: sink, strings: () => es, now: () => now);

    setUp(() {
      sink = _Sink();
      now = DateTime(2026, 10, 12, 8);
    });

    test('posts once; an unchanged turn is not posted again', () async {
      final live = presenter();
      await live.update('k', turn(), show: true);
      await live.update('k', turn(), show: true);
      expect(sink.live, hasLength(1));
      expect(live.shownKeys, {'k'});
    });

    test('a change inside the window waits and the newest state goes out', () {
      fakeAsync((async) {
        final live = LiveTurnNotifications(
          sink: sink,
          strings: () => es,
          now: () => now.add(async.elapsed),
        );
        live.update('k', turn(phase: LiveTurnPhase.thinking), show: true);
        async.flushMicrotasks();
        live.update('k', turn(phase: LiveTurnPhase.usingTool), show: true);
        live.update('k', turn(phase: LiveTurnPhase.responding), show: true);
        async.flushMicrotasks();
        expect(sink.live, hasLength(1));
        async.elapse(const Duration(seconds: 1));
        expect(sink.live, hasLength(2));
        expect(sink.live.last['text'], 'Respondiendo');
        async.elapse(const Duration(minutes: 1));
        expect(sink.live, hasLength(2));
      });
    });

    test('an unchanged row is renewed when an event arrives late', () async {
      final live = presenter();
      await live.update('k', turn(), show: true);
      now = now.add(const Duration(minutes: 11));
      await live.update('k', turn(), show: true);
      expect(sink.live, hasLength(2));
    });

    test('the turn ending withdraws the row', () async {
      final live = presenter();
      await live.update('k', turn(), show: true);
      await live.update('k', null, show: false);
      expect(sink.cancelled, [
        RichNotificationIds.chatTag('conn-a', 'default', 'sess-1'),
      ]);
      expect(live.shownKeys, isEmpty);
      // Nothing was shown: nothing to cancel.
      await live.update('other', null, show: false);
      expect(sink.cancelled, hasLength(1));
    });

    test('not allowed in the tray: withdrawn, and back when allowed', () async {
      final live = presenter();
      await live.update('k', turn(), show: true);
      await live.refresh((_) => false);
      expect(sink.cancelled, hasLength(1));
      expect(live.shownKeys, isEmpty);
      await live.refresh((_) => true);
      expect(sink.live, hasLength(2));
      expect(live.shownKeys, {'k'});
    });

    test('a turn that was never allowed posts nothing', () async {
      final live = presenter();
      await live.update('k', turn(), show: false);
      expect(sink.live, isEmpty);
      expect(sink.cancelled, isEmpty);
    });

    test(
      'the chat got its durable id mid-turn: the row moves with it',
      () async {
        final live = presenter();
        await live.update('k', turn(sessionId: 'mob-1'), show: true);
        now = now.add(const Duration(seconds: 2));
        await live.update('k', turn(sessionId: 'sess-9'), show: true);
        expect(sink.cancelled, [
          RichNotificationIds.chatTag('conn-a', 'default', 'mob-1'),
        ]);
        expect(
          sink.live.last['tag'],
          RichNotificationIds.chatTag('conn-a', 'default', 'sess-9'),
        );
      },
    );

    test('clear withdraws every row', () async {
      final live = presenter();
      await live.update('a', turn(sessionId: 'a'), show: true);
      await live.update('b', turn(sessionId: 'b'), show: true);
      await live.clear();
      expect(sink.cancelled, hasLength(2));
      expect(live.shownKeys, isEmpty);
    });
  });

  group('Stop', () {
    PendingNotificationAction stop(NotificationActionPayload p) =>
        PendingNotificationAction(
          uid: 'u1',
          action: 'stop',
          payload: p,
          notificationId: RichNotificationIds.live,
          tag: 'tag',
        );
    const payload = NotificationActionPayload(
      route: NotificationActionRoute.session,
      connId: 'conn-a',
      sessionId: 'sess-1',
    );

    test('stops the turn of that session and says so on the row', () async {
      final ops = _SessionOps();
      final sink = _Sink();
      final router = NotificationActionRouter(ops: ops, sink: sink, t: es);
      expect(await router.handle(stop(payload)), ActionOutcome.done);
      expect(ops.stopped, ['sess-1']);
      expect(sink.confirms, ['Deteniendo…']);
    });

    test('a turn that already ended is not a failure', () async {
      final ops = _SessionOps()..error = StateError('turn already finished');
      final sink = _Sink();
      final router = NotificationActionRouter(ops: ops, sink: sink, t: es);
      expect(await router.handle(stop(payload)), ActionOutcome.alreadyAnswered);
      expect(sink.confirms, ['Ya había terminado']);
    });

    test(
      'an executor without session actions answers "could not send"',
      () async {
        final sink = _Sink();
        final router = NotificationActionRouter(
          ops: _PlainOps(),
          sink: sink,
          t: es,
        );
        expect(await router.handle(stop(payload)), ActionOutcome.failed);
        expect(sink.confirms, ['No se pudo enviar · abre Hermes']);
      },
    );

    test('the payload survives the trip and needs a session', () {
      final back = NotificationActionPayload.tryParse(payload.encode())!;
      expect(back.route, NotificationActionRoute.session);
      expect(back.sessionId, 'sess-1');
      expect(
        NotificationActionPayload.tryParse(
          const NotificationActionPayload(
            route: NotificationActionRoute.session,
            connId: 'conn-a',
          ).encode(),
        ),
        isNull,
      );
    });
  });

  group('tray policy', () {
    late SharedPreferences prefs;
    late _Sink sink;
    late NotificationService service;
    late Directory dir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({'app_locale': 'es'});
      prefs = await SharedPreferences.getInstance();
      dir = await Directory.systemTemp.createTemp('live-turn-');
      sink = _Sink();
      service = NotificationService(prefs)
        ..setRichForTesting(
          sink,
          faces: BotFaceBitmapCache(directory: () async => dir),
        );
    });

    tearDown(() => dir.delete(recursive: true));

    /// The face of the row is rendered off the event loop: wait for what the
    /// test expects instead of a fixed time.
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 400 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    Future<void> quiet() =>
        Future<void>.delayed(const Duration(milliseconds: 300));

    test('no row while the app is in front; it appears on leaving', () async {
      service.liveTurnChanged('k', turn());
      await quiet();
      expect(sink.live, isEmpty);
      service.appInForeground = false;
      await until(() => sink.live.isNotEmpty);
      expect(sink.live, hasLength(1));
      expect(sink.live.single['title'], 'Prueba con subagentes');
      service.appInForeground = true;
      await until(() => sink.cancelled.isNotEmpty);
      expect(sink.cancelled, hasLength(1));
    });

    test('replies turned off: no row for the turn either', () async {
      await service.setNotifyReplies(false);
      service.appInForeground = false;
      service.liveTurnChanged('k', turn());
      await quiet();
      expect(sink.live, isEmpty);
    });

    test('hidden content is redacted on the row', () async {
      await service.setHideSensitiveContent(true);
      service.appInForeground = false;
      service.liveTurnChanged('k', turn(title: 'Presupuesto secreto'));
      await until(() => sink.live.isNotEmpty);
      expect(sink.live.single['title'], 'Hermes está trabajando');
    });

    test('the turn ending takes the row away', () async {
      service.appInForeground = false;
      service.liveTurnChanged('k', turn());
      await until(() => sink.live.isNotEmpty);
      service.liveTurnChanged('k', null);
      await until(() => sink.cancelled.isNotEmpty);
      expect(sink.cancelled, hasLength(1));
    });
  });
}

final class _Sink implements RichNotificationSink {
  final live = <Map<String, Object?>>[];
  final cancelled = <String?>[];
  final confirms = <String>[];
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
  }) async => confirms.add(text);
  @override
  Future<bool> postConversation(Map<String, Object?> args) async => true;
  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async =>
      live.add(args);
}

base class _PlainOps implements NotificationActionOps {
  @override
  Future<void> roomApprove(NotificationActionPayload p, String choice) async {}
  @override
  Future<void> roomStop(NotificationActionPayload p) async {}
  @override
  Future<void> roomSend(
    NotificationActionPayload p,
    String text,
    String id,
  ) async {}
  @override
  Future<void> chatApprove(NotificationActionPayload p, String choice) async {}
  @override
  Future<void> botChatReply(
    NotificationActionPayload p,
    String text,
    String id,
  ) async {}
  @override
  Future<void> cronTrigger(NotificationActionPayload p) async {}
}

final class _SessionOps extends _PlainOps implements ChatSessionActionOps {
  final stopped = <String?>[];
  Object? error;
  @override
  Future<void> sessionStop(NotificationActionPayload p) async {
    if (error != null) throw error!;
    stopped.add(p.sessionId);
  }

  @override
  Future<void> sessionAnswer(
    NotificationActionPayload p,
    String answer,
  ) async {}
  @override
  Future<void> sessionReply(
    NotificationActionPayload p,
    String text,
    String id,
  ) async {}
  @override
  Future<void> sessionMarkRead(NotificationActionPayload p) async {}
}
