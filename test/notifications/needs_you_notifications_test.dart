// What stops the agent for the user: an approval and a question are cards
// that alert, show what is asked and can be answered from the tray. A normal
// chat gets the same card a Bot chat does.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const es = NotifL10n(true);
const en = NotifL10n(false);
const open = NotificationOpen(connId: 'conn-a', sessionId: 'sess-1');

List<Map<Object?, Object?>> actionsOf(Map<String, Object?> card) => [
  for (final a in card['actions']! as List) a as Map<Object?, Object?>,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;

  group('copy', () {
    test('an approval asks in the words of its buttons', () {
      expect(
        es.approvalNeedsOk('rm -rf build/', null),
        '¿Permitir «rm -rf build/»?',
      );
      expect(
        en.approvalNeedsOk('rm -rf build/', null),
        'Allow “rm -rf build/”?',
      );
      expect(
        es.approvalNeedsOk(null, 'editar 3 archivos'),
        'Pide permiso · editar 3 archivos',
      );
      expect(es.approvalNeedsOk(null, null), 'Pide permiso');
      expect(en.approvalNeedsOk('', ''), 'Asks permission');
      expect(es.actApprove, 'Permitir');
      expect(es.actDeny, 'Rechazar');
      expect(en.actApprove, 'Allow');
      expect(en.actDeny, 'Deny');
      expect(es.confirmApproved, 'Permitido');
      expect(es.confirmDenied, 'Rechazado');
    });
  });

  group('question card', () {
    Map<String, Object?> build({
      String? question = '¿Uso Sonnet 5.5 como modelo de reserva?',
      List<String> choices = const ['Sí, úsalo', 'No'],
      bool answerable = true,
      bool hide = false,
      NotifL10n t = es,
    }) => RichNotificationBuilder(t).question(
      tag: 'tag',
      conversationId: 'chat-1',
      conversationTitle: 'Arreglar el modelo de reserva',
      isGroup: true,
      botKey: 'hermes:default',
      botName: 'Hermes',
      requestId: 'srq-1',
      question: question,
      choices: choices,
      answerAction: answerable
          ? const NotificationActionPayload(
              route: NotificationActionRoute.session,
              connId: 'conn-a',
              sessionId: 'sess-1',
              requestId: 'srq-1',
            )
          : null,
      open: open,
      nowMs: 1,
      hideSensitive: hide,
    );

    test('the question, an inline answer with its choices, and open', () {
      final card = build();
      expect(card['channel'], 'approvals');
      expect(card['alert'], isTrue);
      expect(card['text'], '¿Uso Sonnet 5.5 como modelo de reserva?');
      expect(card['title'], 'Arreglar el modelo de reserva');
      final actions = actionsOf(card);
      expect([for (final a in actions) a['id']], ['answer', 'open']);
      expect(actions.first['label'], 'Responder');
      expect(actions.first['remoteInput'], isTrue);
      expect(actions.first['hint'], 'Responder a Hermes');
      expect(actions.first['choices'], ['Sí, úsalo', 'No']);
      final payload = NotificationActionPayload.tryParse(
        card['actionPayload'] as String,
      )!;
      expect(payload.route, NotificationActionRoute.session);
      expect(payload.requestId, 'srq-1');
      // One card per request, like an approval.
      expect(card['id'], RichNotificationIds.approval('srq-1'));
    });

    test('an open-ended question has no choices', () {
      final actions = actionsOf(build(choices: const []));
      expect(actions.first.containsKey('choices'), isFalse);
    });

    test('lock screen: who, and that it waits; never the question', () {
      final card = build();
      expect(card['publicTitle'], 'Hermes');
      expect(card['publicText'], 'Te necesita');
      expect(
        '${card['publicTitle']}${card['publicText']}',
        isNot(contains('Sonnet')),
      );
    });

    test('not answerable from the tray: it only opens the chat', () {
      final card = build(answerable: false);
      expect([for (final a in actionsOf(card)) a['id']], ['open']);
      expect(card.containsKey('actionPayload'), isFalse);
    });

    test('hidden content: no question, no inline answer', () {
      final card = build(hide: true);
      expect(card['text'], 'Tiene una pregunta');
      expect([for (final a in actionsOf(card)) a['id']], ['open']);
      expect(build(question: null)['text'], 'Tiene una pregunta');
      expect(build(question: null, t: en)['text'], 'Has a question');
    });
  });

  group('answering', () {
    PendingNotificationAction answer(String? text) => PendingNotificationAction(
      uid: 'u1',
      action: 'answer',
      payload: const NotificationActionPayload(
        route: NotificationActionRoute.session,
        connId: 'conn-a',
        sessionId: 'sess-1',
        requestId: 'srq-1',
      ),
      notificationId: 7,
      tag: 'tag',
      text: text,
    );

    test('the answer reaches the request once and the card says so', () async {
      final ops = _Ops();
      final sink = _Sink();
      final router = NotificationActionRouter(ops: ops, sink: sink, t: es);
      expect(await router.handle(answer('Sí, úsalo')), ActionOutcome.done);
      expect(ops.answers, ['srq-1:Sí, úsalo']);
      expect(sink.confirms, ['Enviado']);
      // A second tap (another engine) on the same request is not sent again.
      expect(await router.handle(answer('No')), ActionOutcome.ignored);
      expect(ops.answers, hasLength(1));
    });

    test('answered elsewhere meanwhile is not a failure', () async {
      final ops = _Ops()..error = StateError('question no longer pending');
      final sink = _Sink();
      final router = NotificationActionRouter(ops: ops, sink: sink, t: es);
      expect(await router.handle(answer('Sí')), ActionOutcome.alreadyAnswered);
      expect(sink.confirms, ['Ya estaba respondido']);
    });

    test('an empty answer does nothing', () async {
      final ops = _Ops();
      final router = NotificationActionRouter(ops: ops, sink: _Sink(), t: es);
      expect(await router.handle(answer('  ')), ActionOutcome.ignored);
      expect(ops.answers, isEmpty);
    });

    test(
      'a failed answer is reported, never rescued as a new message',
      () async {
        final ops = _Ops()..error = StateError('socket closed');
        final sink = _Sink();
        final phases = <String>[];
        final router = NotificationActionRouter(ops: ops, sink: sink, t: es);
        expect(
          await router.handle(
            answer('Sí'),
            checkpoint: (p) async => phases.add(p),
          ),
          ActionOutcome.failed,
        );
        expect(phases, ['confirmed']);
        expect(sink.confirms, ['No se pudo enviar · abre Hermes']);
      },
    );
  });

  group('a normal chat', () {
    late _Sink sink;
    late NotificationService service;
    late Directory dir;

    const plugin = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    Future<void> setUpService([Map<String, Object> extra = const {}]) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      messenger.setMockMethodCallHandler(plugin, (call) async {
        return switch (call.method) {
          'initialize' || 'areNotificationsEnabled' => true,
          'getNotificationAppLaunchDetails' => {
            'notificationLaunchedApp': false,
            'notificationResponse': null,
          },
          'getActiveNotifications' => const <Object?>[],
          _ => null,
        };
      });
      SharedPreferences.setMockInitialValues({
        'app_locale': 'es',
        'notif_perm_requested': true,
        'notif_background_listen': true,
        ...extra,
      });
      dir = await Directory.systemTemp.createTemp('needs-you-');
      sink = _Sink();
      service =
          NotificationService(
              await SharedPreferences.getInstance(),
              deliveryStore: NotificationDeliveryStore(
                databasePath: '${dir.path}/delivery.db',
              ),
            )
            ..setRichForTesting(
              sink,
              faces: BotFaceBitmapCache(directory: () async => dir),
            )
            ..appInForeground = false;
    }

    tearDown(() async {
      await service.closeDelivery();
      messenger.setMockMethodCallHandler(plugin, null);
      debugDefaultTargetPlatformOverride = null;
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    Future<void> approval({String? command = 'rm -rf build/'}) =>
        service.approvalPending(
          tool: command ?? 'una herramienta',
          connId: 'conn-a',
          sessionId: 'sess-1',
          sessionTitle: 'Diseño de píldora de estados',
          runId: 'runtime-1',
          approvalId: 'req-1',
          approvalChoices: const ['once', 'session', 'always', 'deny'],
          command: command,
        );

    test('approval: the command, Permitir / Rechazar, and it alerts', () async {
      await setUpService();
      await approval();
      final card = sink.posts.single;
      expect(card['channel'], 'approvals');
      expect(card['alert'], isTrue);
      expect(card['title'], 'Diseño de píldora de estados');
      expect(card['text'], '¿Permitir «rm -rf build/»?');
      final actions = actionsOf(card);
      expect([for (final a in actions) a['id']], ['approve', 'deny', 'open']);
      expect(
        [for (final a in actions) a['label']],
        ['Permitir', 'Rechazar', 'Abrir'],
      );
      expect(
        card['tag'],
        RichNotificationIds.chatTag('conn-a', 'default', 'sess-1'),
      );
      final payload = NotificationActionPayload.tryParse(
        card['actionPayload'] as String,
      )!;
      expect(payload.route, NotificationActionRoute.chat);
      expect(payload.sessionId, 'sess-1');
      expect(payload.requestId, 'req-1');
      // Lock screen: only who.
      expect(card['publicTitle'], 'Hermes');
      expect(card['publicText'], 'Te necesita');
      expect(
        '${card['publicTitle']}${card['publicText']}',
        isNot(contains('rm -rf')),
      );
    });

    test('a read-only connection can only open it', () async {
      await setUpService({
        'saved_connections': ['{"id":"conn-a","read_only":true}'],
      });
      await approval();
      expect([for (final a in actionsOf(sink.posts.single)) a['id']], ['open']);
    });

    test('hidden content: no command on the card', () async {
      await setUpService({'notif_hide_sensitive_content': true});
      await approval();
      expect(sink.posts.single['text'], 'Hermes te necesita');
      expect(sink.posts.single.toString(), isNot(contains('rm -rf')));
    });

    test('answered anywhere: the card leaves', () async {
      await setUpService();
      await approval();
      await service.cancelApproval(
        connId: 'conn-a',
        profile: 'default',
        runId: 'runtime-1',
        approvalId: 'req-1',
      );
      expect(
        sink.cancelled,
        contains(
          '${RichNotificationIds.chatTag('conn-a', 'default', 'sess-1')}'
          '#${RichNotificationIds.approval('req-1')}',
        ),
      );
    });

    test(
      'a question alerts with its inline answer; resolved, it leaves',
      () async {
        await setUpService();
        await service.questionPending(
          connId: 'conn-a',
          sessionId: 'sess-1',
          requestId: 'srq-9',
          sessionTitle: 'Arreglar el modelo de reserva',
          question: '¿Uso Sonnet 5.5 como modelo de reserva?',
          choices: const ['Sí, úsalo', 'No'],
        );
        final card = sink.posts.single;
        expect(card['alert'], isTrue);
        expect(card['text'], '¿Uso Sonnet 5.5 como modelo de reserva?');
        expect(actionsOf(card).first['id'], 'answer');
        expect(actionsOf(card).first['choices'], ['Sí, úsalo', 'No']);
        service.cancelQuestion('srq-9');
        await Future<void>.delayed(Duration.zero);
        expect(
          sink.cancelled,
          contains(
            '${RichNotificationIds.chatTag('conn-a', 'default', 'sess-1')}'
            '#${RichNotificationIds.approval('srq-9')}',
          ),
        );
      },
    );

    test('several questions, or a password prompt: open only', () async {
      await setUpService();
      await service.questionPending(
        connId: 'conn-a',
        sessionId: 'sess-1',
        requestId: 'srq-2',
        answerable: false,
      );
      final card = sink.posts.single;
      expect(card['text'], 'Tiene una pregunta');
      expect([for (final a in actionsOf(card)) a['id']], ['open']);
    });

    test(
      'in front of another chat: the in-app notice, no system card',
      () async {
        await setUpService();
        service
          ..appInForeground = true
          ..visibleSessionId = 'other';
        final notices = <InAppNotice>[];
        final sub = service.inAppNotices.listen(notices.add);
        await service.questionPending(
          connId: 'conn-a',
          sessionId: 'sess-1',
          requestId: 'srq-3',
          question: '¿Sigo?',
        );
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
        expect(sink.posts, isEmpty);
        expect(notices.single.title, 'Hermes te necesita');
        expect(notices.single.body, '¿Sigo?');
      },
    );

    test(
      'in front of this very chat: nothing (its own card is there)',
      () async {
        await setUpService();
        service
          ..appInForeground = true
          ..visibleSessionId = 'sess-1';
        final notices = <InAppNotice>[];
        final sub = service.inAppNotices.listen(notices.add);
        await service.questionPending(
          connId: 'conn-a',
          sessionId: 'sess-1',
          requestId: 'srq-4',
          question: '¿Sigo?',
        );
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
        expect(sink.posts, isEmpty);
        expect(notices, isEmpty);
      },
    );
  });

  test('native side: an answer needs text and unlocks like a reply', () {
    final kt = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/HermesRichNotifications.kt',
    ).readAsStringSync();
    expect(kt, contains('"reply", "answer", "retry"'));
    expect(
      kt,
      contains(
        'if ((actionId == "reply" || actionId == "answer") && text.isNullOrEmpty()) return',
      ),
    );
    expect(kt, contains('input.setChoices('));
    // Every tapped action still requires an unlocked device by default.
    expect(kt, contains('action["requiresUnlock"] != false'));
  });
}

final class _Sink implements RichNotificationSink {
  final posts = <Map<String, Object?>>[];
  final cancelled = <String>[];
  final confirms = <String>[];
  @override
  Future<void> cancel({required int id, String? tag}) async =>
      cancelled.add('$tag#$id');
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
  Future<bool> postConversation(Map<String, Object?> args) async {
    posts.add(args);
    return true;
  }

  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async {}
}

final class _Ops implements NotificationActionOps, ChatSessionActionOps {
  final answers = <String>[];
  Object? error;
  @override
  Future<void> sessionAnswer(NotificationActionPayload p, String answer) async {
    if (error != null) throw error!;
    answers.add('${p.requestId}:$answer');
  }

  @override
  Future<void> sessionStop(NotificationActionPayload p) async {}
  @override
  Future<void> sessionReply(
    NotificationActionPayload p,
    String text,
    String id,
  ) async {}
  @override
  Future<void> sessionMarkRead(NotificationActionPayload p) async {}
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
