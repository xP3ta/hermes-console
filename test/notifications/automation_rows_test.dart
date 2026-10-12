// Cron, Kanban and goal results are plain rows Android folds: the item's own
// name, its state and the first line of the result; silent unless it failed
// or needs the user; "Silenciar" flips the item's own switch; no shortcut.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/notification_action_drain.dart';
import 'package:hermes_android/core/services/notifications/notification_action_ops.dart';
import 'package:hermes_android/core/services/notifications/notification_mute_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

const es = NotifL10n(true);
const en = NotifL10n(false);
const _open = NotificationOpen(connId: 'c1', sessionId: 'cron_j_1');

Map<String, Object?> _row({
  String title = 'Resumen de noticias',
  String line = 'Terminó · 3 novedades hoy',
  int accent = RichAccent.done,
  bool alert = false,
  bool hide = false,
  NotificationActionPayload? action = const NotificationActionPayload(
    route: NotificationActionRoute.cron,
    connId: 'c1',
    taskId: 'j',
  ),
}) => RichNotificationBuilder(es).automationRow(
  tag: 'tag',
  id: 7,
  title: title,
  line: line,
  source: 'Tareas programadas',
  open: _open,
  accent: accent,
  alert: alert,
  hideSensitive: hide,
  action: action,
  actions: const [
    RichAction('open', 'Ver resultado'),
    RichAction('mute', 'Silenciar'),
  ],
);

PendingNotificationAction _tap(NotificationActionPayload payload) =>
    PendingNotificationAction(
      uid: 'u1',
      action: 'mute',
      payload: payload,
      notificationId: 7,
      tag: 'tag',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the row', () {
    test('its name, the state and the first line; not a conversation', () {
      final row = _row();
      expect(row['style'], 'row');
      expect(row['title'], 'Resumen de noticias');
      expect(row['text'], 'Terminó · 3 novedades hoy');
      expect(row['subText'], 'Tareas programadas');
      expect(row['alert'], isFalse);
      // Nothing that would make Android keep a conversation for it.
      for (final key in ['conversationId', 'messages', 'shortcutIconPath']) {
        expect(row.containsKey(key), isFalse, reason: key);
      }
    });

    test('the lock screen and the folded summary never name it', () {
      final row = _row();
      expect(row['publicTitle'], 'Tareas programadas');
      expect(row['publicText'], 'Terminó');
      expect(row['summaryLine'], 'Tareas programadas · hecho');
      final failed = _row(accent: RichAccent.failed, alert: true);
      expect(failed['publicText'], 'No pudo terminar');
      expect(failed['summaryLine'], 'Tareas programadas · falló');
      expect(failed['alert'], isTrue);
    });

    test('hidden content: where it comes from, and only Open', () {
      final row = _row(hide: true);
      expect(row['title'], 'Tareas programadas');
      expect(row['text'], 'Nueva actividad');
      expect(row.containsKey('subText'), isFalse);
      expect(
        [for (final a in row['actions']! as List) (a as Map)['id']],
        ['open'],
      );
    });

    test('without an executor payload there is nothing to press but Open', () {
      final row = _row(action: null);
      expect(
        [for (final a in row['actions']! as List) (a as Map)['id']],
        ['open'],
      );
      expect(row.containsKey('actionPayload'), isFalse);
    });
  });

  group('what each automation says', () {
    test('a scheduled job: state, then what it said (never its name)', () {
      final ok = NotificationService.cronRichSpec(
        t: es,
        title: 'Resumen de noticias',
        ok: true,
        jobId: 'j',
        profile: 'default',
        preview: '**3 novedades** hoy\n- una\n- dos',
      );
      expect(ok.row, isTrue);
      expect(ok.line, 'Terminó · 3 novedades hoy');
      expect(ok.conversationTitle, 'Resumen de noticias');
      expect(ok.muteJobId, 'j');
      expect(ok.conversationKey, isNull);
      // The run only echoed the job name, or said nothing: just the state.
      for (final preview in ['Resumen de noticias', '', null]) {
        expect(
          NotificationService.cronRichSpec(
            t: es,
            title: 'Resumen de noticias',
            ok: true,
            jobId: 'j',
            preview: preview,
          ).line,
          'Terminó',
        );
      }
      final failed = NotificationService.cronRichSpec(
        t: en,
        title: 'News digest',
        ok: false,
        jobId: 'j',
        profile: 'work',
        preview: 'Could not reach the feed',
      );
      expect(failed.line, 'Failed · Could not reach the feed');
      expect(failed.state, BotFaceBitmapState.failed);
      expect(failed.retryJobId, 'j');
      expect(failed.muteProfile, 'work');
    });

    test('a board task: why it stopped, in plain words', () {
      String head(
        String status, {
        Set<String> kinds = const {},
        String? retry,
      }) => NotificationService.kanbanRichSpec(
        t: es,
        title: 'Subir build',
        status: status,
        taskId: 't1',
        eventKinds: kinds,
        retry: retry,
      ).line;
      expect(head('done'), 'Terminada');
      expect(head('blocked'), 'Bloqueada');
      expect(head('blocked', kinds: {'gave_up'}), 'Detenida');
      expect(head('triage'), 'Te necesita');
      expect(
        head('triage', kinds: {'block_loop_detected'}),
        'Necesita que decidas',
      );
      expect(head('blocked', retry: 'crashed'), 'Falló; se va a reintentar');
      expect(
        head('blocked', retry: 'timed_out'),
        'Tardó demasiado; se va a reintentar',
      );
      final spec = NotificationService.kanbanRichSpec(
        t: es,
        title: 'Subir build',
        status: 'done',
        taskId: 't1',
      );
      expect(spec.row, isTrue);
      expect(spec.muteTaskId, 't1');
      expect(spec.conversationKey, isNull);
    });

    test('a goal: its text and state; only a blocked one alerts', () {
      BotFaceBitmapState state(String status) =>
          NotificationService.goalRichSpec(
            t: es,
            title: 'Publicar la 1.2.15',
            status: status,
          ).state;
      final done = NotificationService.goalRichSpec(
        t: es,
        title: 'Publicar la 1.2.15',
        status: 'done',
      );
      expect(done.row, isTrue);
      expect(done.conversationTitle, 'Publicar la 1.2.15');
      expect(done.line, 'Cumplido');
      expect(done.senderLabel, 'Objetivos');
      expect(done.muteJobId ?? done.muteTaskId, isNull);
      expect(state('paused'), BotFaceBitmapState.idle);
      expect(state('waiting'), BotFaceBitmapState.idle);
      expect(state('blocked'), BotFaceBitmapState.failed);
      expect(en.goalHead('blocked'), 'Blocked');
      expect(en.goalHead('done'), 'Reached');
    });
  });

  group('Silenciar', () {
    late SharedPreferences prefs;
    late GatewayNotificationActionOps ops;
    late _Sink sink;
    late NotificationActionRouter router;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      ops = GatewayNotificationActionOps(
        resolveConnection: (_) => null,
        prefsForMute: () async => prefs,
      );
      sink = _Sink();
      router = NotificationActionRouter(ops: ops, sink: sink, t: es);
    });

    test('a job: its own switch goes off, and can be turned back on', () async {
      final outcome = await router.handle(
        _tap(
          const NotificationActionPayload(
            route: NotificationActionRoute.cron,
            connId: 'c1',
            profile: 'work',
            taskId: 'j',
          ),
        ),
      );
      expect(outcome, ActionOutcome.done);
      expect(sink.confirms, ['Silenciada']);
      final store = NotificationMuteStore(prefs);
      expect(
        store.cronPolicy(connId: 'c1', profile: 'work', jobId: 'j'),
        CronNotifyPolicy.off,
      );
      expect(
        store.shouldDeliverCron(
          connId: 'c1',
          profile: 'work',
          jobId: 'j',
          ok: false,
        ),
        isFalse,
      );
      // Another job, or the same id in another profile, is untouched.
      expect(
        store.cronPolicy(connId: 'c1', profile: 'default', jobId: 'j'),
        CronNotifyPolicy.all,
      );
      // The job's screen writes the same store: reachable from there.
      await store.setCronPolicy(
        connId: 'c1',
        profile: 'work',
        jobId: 'j',
        policy: CronNotifyPolicy.all,
      );
      expect(
        store.shouldDeliverCron(
          connId: 'c1',
          profile: 'work',
          jobId: 'j',
          ok: true,
        ),
        isTrue,
      );
    });

    test('a job of the default profile', () async {
      await router.handle(
        _tap(
          const NotificationActionPayload(
            route: NotificationActionRoute.cron,
            connId: 'c1',
            taskId: 'j',
          ),
        ),
      );
      expect(
        NotificationMuteStore(
          prefs,
        ).cronPolicy(connId: 'c1', profile: 'default', jobId: 'j'),
        CronNotifyPolicy.off,
      );
    });

    test('a task: its own switch', () async {
      final outcome = await router.handle(
        _tap(
          const NotificationActionPayload(
            route: NotificationActionRoute.kanban,
            connId: 'c1',
            taskId: 't1',
          ),
        ),
      );
      expect(outcome, ActionOutcome.done);
      final store = NotificationMuteStore(prefs);
      expect(store.kanbanMuted(connId: 'c1', taskId: 't1'), isTrue);
      expect(store.kanbanMuted(connId: 'c1', taskId: 't2'), isFalse);
      await store.setKanbanMuted(connId: 'c1', taskId: 't1', muted: false);
      expect(store.kanbanMuted(connId: 'c1', taskId: 't1'), isFalse);
    });

    test('nothing else can be muted from a row', () async {
      final outcome = await router.handle(
        _tap(
          const NotificationActionPayload(
            route: NotificationActionRoute.session,
            connId: 'c1',
            sessionId: 's1',
          ),
        ),
      );
      expect(outcome, ActionOutcome.failed);
    });

    test('every executor claims a task tap', () {
      expect(
        allNotificationActionRoutes,
        contains(NotificationActionRoute.kanban),
      );
      expect(
        NotificationActionPayload.tryParse(
          const NotificationActionPayload(
            route: NotificationActionRoute.kanban,
            connId: 'c1',
            taskId: 't1',
          ).encode(),
        )?.taskId,
        't1',
      );
    });
  });

  test('native side: a row, folded, with no shortcut', () {
    final kt = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/HermesRichNotifications.kt',
    ).readAsStringSync();
    final start = kt.indexOf('private fun postRow(context: Context');
    final row = kt.substring(
      start,
      kt.indexOf('private fun automationRows(', start),
    );
    expect(row, contains('BigTextStyle()'));
    expect(row, contains('.setSilent(!alert)'));
    expect(row, contains('setGroup(AUTO_GROUP)'));
    expect(row, contains('syncAutomationGroup(context)'));
    expect(row, contains('setPublicVersion('));
    // Not a conversation: no MessagingStyle, no shortcut pushed or attached.
    for (final never in ['MessagingStyle', 'pushShortcut', 'setShortcutId']) {
      expect(row, isNot(contains(never)), reason: never);
    }
    final group = kt.substring(
      kt.indexOf('fun syncAutomationGroup(context: Context)'),
      kt.indexOf('private const val EXTRA_ALERT_KEY'),
    );
    expect(group, contains('if (rows.size < 2) {'));
    expect(group, contains('.setGroupSummary(true)'));
    expect(group, contains('GROUP_ALERT_CHILDREN'));
    expect(group, contains('R.plurals.rich_auto_summary'));
    // The per-job / per-task shortcuts of earlier builds are withdrawn.
    expect(kt, contains('it.startsWith("hermes-cron-")'));
    expect(kt, contains('it.startsWith("hermes-task-")'));
    expect(kt, contains('"read", "mute")'));
    for (final file in ['values', 'values-es']) {
      expect(
        File('android/app/src/main/res/$file/strings.xml').readAsStringSync(),
        contains('<plurals name="rich_auto_summary">'),
      );
    }
  });
}

final class _Sink implements RichNotificationSink {
  final confirms = <String>[];
  @override
  Future<void> cancel({required int id, String? tag}) async {}
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
  Future<void> postLiveUpdate(Map<String, Object?> args) async {}
}
