// How a normal chat's turn ends in the tray: the first line of the reply in
// that chat's own conversation (silent, with Reply and Mark read), or a
// failure that alerts. The lock screen names who, never the chat.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardClient;
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/live_turn_notifications.dart';
import 'package:hermes_android/core/services/notifications/notification_action_drain.dart';
import 'package:hermes_android/core/services/notifications/notification_action_ops.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const es = NotifL10n(true);
const en = NotifL10n(false);

List<Map<Object?, Object?>> actionsOf(Map<String, Object?> card) => [
  for (final a in card['actions']! as List) a as Map<Object?, Object?>,
];

const _session = NotificationActionPayload(
  route: NotificationActionRoute.session,
  connId: 'conn-a',
  profile: 'default',
  sessionId: 'sess-1',
);

PendingNotificationAction _tap(
  String action, {
  String uid = 'u1',
  String? text,
  NotificationActionPayload payload = _session,
  bool reclaimed = false,
}) => PendingNotificationAction(
  uid: uid,
  action: action,
  payload: payload,
  notificationId: RichNotificationIds.conversation,
  tag: 'tag',
  text: text,
  reclaimed: reclaimed,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;

  group('the card', () {
    const plugin = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory dir;
    late _Sink sink;
    late NotificationService service;
    late List<MethodCall> pluginCalls;

    Future<void> setUpService([Map<String, Object> extra = const {}]) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      pluginCalls = [];
      messenger.setMockMethodCallHandler(plugin, (call) async {
        pluginCalls.add(call);
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
        ...extra,
      });
      dir = await Directory.systemTemp.createTemp('chat-result-');
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

    Future<void> reply({
      String preview =
          '**Arreglado.** El modelo de reserva ya es Sonnet.\n'
          '- detalle que no cabe',
      bool replyable = true,
      String? profile,
    }) => service.replyReady(
      preview: preview,
      instance: 'Servidor de casa',
      session: 'Arreglar el modelo de reserva',
      connId: 'conn-a',
      sessionId: 'sess-1',
      profile: profile,
      replyable: replyable,
    );

    Future<void> failure() => service.replyFailed(
      instance: 'Servidor de casa',
      session: 'Arreglar el modelo de reserva',
      detail: 'HTTP 500 en /v1/runs con token-secreto',
      connId: 'conn-a',
      sessionId: 'sess-1',
    );

    final tag = RichNotificationIds.chatTag('conn-a', 'default', 'sess-1');

    test('a reply: its first line, in the chat, silent', () async {
      await setUpService();
      await reply();
      final card = sink.posts.single;
      expect(card['tag'], tag);
      expect(card['id'], RichNotificationIds.conversation);
      expect(card['channel'], 'conversations');
      expect(card['title'], 'Arreglar el modelo de reserva');
      expect(card['isGroup'], isTrue);
      expect(card['text'], 'Arreglado. El modelo de reserva ya es Sonnet.');
      expect(card['subText'], 'Listo');
      expect(card['alert'], isFalse);
      expect(card['accent'], RichAccent.done);
      final message = (card['messages']! as List).single as Map;
      expect(message['senderName'], 'Hermes');
      expect(message['iconPath'], isA<String>());
      expect(card.toString(), isNot(contains('detalle que no cabe')));
      expect(card.toString(), isNot(contains('**')));
      // Never the plain template next to it.
      expect(pluginCalls.where((c) => c.method == 'show'), isEmpty);
    });

    test('Responder, Marcar leído and Abrir act on that session', () async {
      await setUpService();
      await reply();
      final card = sink.posts.single;
      expect(
        [for (final a in actionsOf(card)) a['id']],
        ['reply', 'read', 'open'],
      );
      expect(
        [for (final a in actionsOf(card)) a['label']],
        ['Responder', 'Marcar leído', 'Abrir'],
      );
      expect(actionsOf(card).first['remoteInput'], isTrue);
      expect(actionsOf(card).first['hint'], 'Responder a Hermes');
      final payload = NotificationActionPayload.tryParse(
        card['actionPayload'] as String,
      )!;
      expect(payload.route, NotificationActionRoute.session);
      expect(payload.connId, 'conn-a');
      expect(payload.sessionId, 'sess-1');
      expect(payload.profile, 'default');
      final open = jsonDecode(card['openPayload']! as String) as Map;
      expect(open['conn'], 'conn-a');
      expect(open['sid'], 'sess-1');
    });

    test('a session that cannot take a message has no Responder', () async {
      await setUpService();
      await reply(replyable: false);
      expect(
        [for (final a in actionsOf(sink.posts.single)) a['id']],
        ['read', 'open'],
      );
    });

    test('a read-only connection can only open it', () async {
      await setUpService({
        'saved_connections': ['{"id":"conn-a","read_only":true}'],
      });
      await reply();
      final card = sink.posts.single;
      expect([for (final a in actionsOf(card)) a['id']], ['open']);
      expect(card.containsKey('actionPayload'), isFalse);
    });

    test('the lock screen names who and the state, nothing else', () async {
      await setUpService();
      await reply();
      final card = sink.posts.single;
      expect(card['publicTitle'], 'Hermes');
      expect(card['publicText'], 'Terminó');
      expect(card['summaryLine'], 'Hermes · hecho');
      for (final key in ['publicTitle', 'publicText', 'summaryLine']) {
        expect(card[key], isNot(contains('Arreglar')));
        expect(card[key], isNot(contains('Sonnet')));
      }
    });

    test('a reply with no plain first line still says it is ready', () async {
      await setUpService();
      await reply(preview: '\n\n   \n');
      expect(sink.posts.single['text'], 'Respuesta lista. Toca para abrir.');
    });

    test('a failed turn alerts, without the reason', () async {
      await setUpService();
      await failure();
      final card = sink.posts.single;
      expect(card['tag'], tag);
      expect(card['id'], RichNotificationIds.conversation);
      expect(card['alert'], isTrue);
      expect(card['accent'], RichAccent.failed);
      expect(card['title'], 'Arreglar el modelo de reserva');
      expect(card['text'], 'No pudo terminar');
      expect(card.containsKey('subText'), isFalse);
      expect([for (final a in actionsOf(card)) a['id']], ['open']);
      expect(actionsOf(card).single['label'], 'Ver motivo');
      expect(card['publicTitle'], 'Hermes');
      expect(card['publicText'], 'No pudo terminar');
      expect(card.toString(), isNot(contains('token-secreto')));
      expect(card.toString(), isNot(contains('HTTP 500')));
    });

    test('the result takes the address of the live row', () async {
      await setUpService();
      await reply();
      for (final profile in ['', 'default', ' Default ']) {
        expect(
          liveTurnTag(
            LiveTurnSnapshot(
              connId: 'conn-a',
              profile: profile,
              sessionId: 'sess-1',
              title: 'Arreglar el modelo de reserva',
              surface: NotificationChatSurface.normal,
              phase: LiveTurnPhase.responding,
            ),
          ),
          sink.posts.single['tag'],
        );
      }
    });

    test('a profile chat is signed by that profile', () async {
      await setUpService();
      await reply(profile: 'Builder');
      final card = sink.posts.single;
      expect(
        card['tag'],
        RichNotificationIds.chatTag('conn-a', 'builder', 'sess-1'),
      );
      expect(card['publicTitle'], 'builder');
      expect(
        NotificationActionPayload.tryParse(
          card['actionPayload'] as String,
        )!.profile,
        'builder',
      );
    });

    test('hidden content: the generic card, no text and no actions', () async {
      await setUpService({'notif_hide_sensitive_content': true});
      await reply();
      final card = sink.posts.single;
      expect(card.toString(), isNot(contains('Sonnet')));
      // (The open payload still knows which chat to open.)
      for (final key in ['title', 'text', 'messages', 'conversationTitle']) {
        expect('${card[key]}', isNot(contains('Arreglar')), reason: key);
      }
      expect([
        for (final a in actionsOf(card)) a['id'],
      ], isNot(contains('reply')));
      expect([
        for (final a in actionsOf(card)) a['id'],
      ], isNot(contains('read')));
      expect(card['alert'], isFalse);
    });

    test('hidden content: a failure still alerts', () async {
      await setUpService({'notif_hide_sensitive_content': true});
      await failure();
      final card = sink.posts.single;
      expect(card['alert'], isTrue);
      expect(card['accent'], RichAccent.failed);
      for (final key in ['title', 'text', 'messages', 'conversationTitle']) {
        expect('${card[key]}', isNot(contains('Arreglar')), reason: key);
      }
      expect(card.toString(), isNot(contains('token-secreto')));
    });

    test('renderer unavailable: the plain card, and a failure too', () async {
      await setUpService();
      sink.accept = false;
      await reply();
      await failure();
      final shown = pluginCalls.where((c) => c.method == 'show').toList();
      expect(shown, hasLength(2));
      for (final call in shown) {
        expect(jsonEncode(call.arguments), isNot(contains('Sonnet')));
        expect(jsonEncode(call.arguments), isNot(contains('token-secreto')));
      }
    });

    test('in front of another chat: the in-app notice only', () async {
      await setUpService();
      service
        ..appInForeground = true
        ..visibleSessionId = 'other';
      final notices = <InAppNotice>[];
      final sub = service.inAppNotices.listen(notices.add);
      await reply();
      await failure();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(sink.posts, isEmpty);
      expect(notices, hasLength(2));
    });

    test('in front of this very chat: nothing', () async {
      await setUpService();
      service
        ..appInForeground = true
        ..visibleSessionId = 'sess-1';
      final notices = <InAppNotice>[];
      final sub = service.inAppNotices.listen(notices.add);
      await reply();
      await failure();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(sink.posts, isEmpty);
      expect(notices, isEmpty);
      expect(pluginCalls.where((c) => c.method == 'show'), isEmpty);
    });

    test('replies turned off: nothing at all', () async {
      await setUpService({'notif_replies': false});
      await reply();
      await failure();
      expect(sink.posts, isEmpty);
    });

    test('a Bot chat keeps its own conversation', () async {
      await setUpService();
      await service.replyReady(
        preview: 'Hecho',
        session: 'Atlas',
        connId: 'conn-a',
        sessionId: 'sess-1',
        surface: NotificationChatSurface.bot,
        profile: 'atlas',
      );
      expect(
        sink.posts.single['tag'],
        RichNotificationIds.botTag('conn-a', 'atlas'),
      );
    });

    test('opening the chat takes its result down', () async {
      await setUpService();
      service.enableChatReadSync();
      await reply();
      await service.clearChatNotifications(
        connId: 'conn-a',
        sessionId: 'sess-1',
      );
      final cancels = pluginCalls.where((c) => c.method == 'cancel').toList();
      expect(cancels, hasLength(1));
      final args = Map<Object?, Object?>.from(cancels.single.arguments as Map);
      expect(args['id'], RichNotificationIds.conversation);
      expect(args['tag'], tag);
    });
  });

  group('from the tray', () {
    late _Ops ops;
    late _Sink sink;
    late NotificationActionRouter router;

    setUp(() {
      ops = _Ops();
      sink = _Sink();
      router = NotificationActionRouter(ops: ops, sink: sink, t: es);
    });

    test('Responder sends the text to that session', () async {
      final outcome = await router.handle(_tap('reply', text: ' sigue  '));
      expect(outcome, ActionOutcome.done);
      expect(ops.replies, ['sess-1:sigue:notif-u1']);
      expect(sink.confirms, ['Enviado']);
    });

    test('an empty reply is nothing', () async {
      expect(
        await router.handle(_tap('reply', text: '  ')),
        ActionOutcome.ignored,
      );
      expect(ops.replies, isEmpty);
      expect(sink.confirms, isEmpty);
    });

    test('a reply that did not leave waits in the chat composer', () async {
      ops.error = StateError('connection unavailable');
      final outcome = await router.handle(_tap('reply', text: 'sigue'));
      expect(outcome, ActionOutcome.failed);
      expect(sink.confirms, ['No se pudo enviar · abre para reintentar']);
      expect(replyDraftAddress(_session, activeProfile: 'otro'), (
        sessionId: 'sess-1',
        profile: 'default',
      ));
      expect(
        replyDraftAddress(
          const NotificationActionPayload(
            route: NotificationActionRoute.session,
            connId: 'conn-a',
            profile: 'work',
            sessionId: 'sess-2',
          ),
          activeProfile: '',
        ),
        (sessionId: 'sess-2', profile: 'work'),
      );
      expect(
        replyDraftAddress(
          const NotificationActionPayload(
            route: NotificationActionRoute.session,
            connId: 'conn-a',
            sessionId: 'sess-3',
          ),
          activeProfile: 'work',
        ),
        (sessionId: 'sess-3', profile: 'default'),
      );
    });

    test('a reply whose executor died is never sent twice', () async {
      final outcome = await router.handle(
        _tap('reply', text: 'sigue', reclaimed: true),
      );
      expect(outcome, ActionOutcome.maybeDone);
      expect(ops.replies, isEmpty);
      expect(sink.confirms, ['Enviado · abre Hermes para verlo']);
    });

    test('an unverified acknowledgement is not sent again', () async {
      ops.error = const AmbiguousDeliveryError('timeout');
      expect(
        await router.handle(_tap('reply', text: 'sigue')),
        ActionOutcome.maybeDone,
      );
      expect(sink.confirms, ['Enviado · abre Hermes para verlo']);
    });

    test('Marcar leído marks the chat read and confirms nothing', () async {
      expect(await router.handle(_tap('read')), ActionOutcome.done);
      expect(ops.read, ['sess-1']);
      expect(sink.confirms, isEmpty);
      // The next reply of the same chat can be marked read right away.
      expect(await router.handle(_tap('read', uid: 'u2')), ActionOutcome.done);
      expect(ops.read, ['sess-1', 'sess-1']);
    });

    test('Marcar leído that cannot reach the server shows nothing', () async {
      ops.error = StateError('HTTP 401');
      final phases = <String>[];
      final outcome = await router.handle(
        _tap('read'),
        checkpoint: (phase) async => phases.add(phase),
      );
      expect(outcome, ActionOutcome.done);
      expect(phases, ['confirmed']);
      expect(sink.confirms, isEmpty);
    });

    test(
      'an executor without session actions: read is quiet, a reply fails',
      () async {
        final plain = NotificationActionRouter(
          ops: _PlainOps(),
          sink: sink,
          t: es,
        );
        expect(await plain.handle(_tap('read')), ActionOutcome.done);
        expect(sink.confirms, isEmpty);
        expect(
          await plain.handle(_tap('reply', text: 'sigue')),
          ActionOutcome.failed,
        );
      },
    );

    test('every executor claims the session route', () {
      expect(
        allNotificationActionRoutes,
        contains(NotificationActionRoute.session),
      );
    });
  });

  group('on the server', () {
    final connection = SavedConnection(
      id: 'conn-a',
      label: 'Casa',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'unused',
      dashboardUrl: 'http://127.0.0.1:9119',
    );

    test('Marcar leído is the Dashboard row toggle', () async {
      late _ClosingClient client;
      final seen = <String>[];
      client = _ClosingClient((request) async {
        seen.add('${request.method} ${request.url.path} ${request.body}');
        if (request.url.path.endsWith('/mutation-snapshot')) {
          return http.Response(
            '{"session_id":"sess-1","exists":true,"runtime_revision":3,'
            '"runtime_generation":0}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{"unread": false}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final ops = GatewayNotificationActionOps(
        resolveConnection: (_) => connection,
        dashboardFactory: (c) => DashboardClient(
          host: c.dashboardHost,
          port: c.dashboardPort,
          manualToken: 'token',
          httpClientOverride: client,
        ),
      );
      await ops.sessionMarkRead(
        const NotificationActionPayload(
          route: NotificationActionRoute.session,
          connId: 'conn-a',
          profile: 'work',
          sessionId: 'sess-1',
        ),
      );
      expect(seen, hasLength(2));
      expect(
        seen.first,
        startsWith('GET /api/sessions/sess-1/mutation-snapshot'),
      );
      expect(seen.last, startsWith('PATCH /api/sessions/sess-1 '));
      expect(jsonDecode(seen.last.split(' ').skip(2).join(' ')), {
        'unread': false,
        'profile': 'work',
        'request_id': isA<String>(),
        'expected_revision': 3,
        'expected_generation': 0,
      });
      expect(client.closeCalls, 1);
    });

    test('a read-only connection is never written', () async {
      final ops = GatewayNotificationActionOps(
        resolveConnection: (_) => connection.copyWith(readOnly: true),
        dashboardFactory: (_) => fail('no client for a read-only connection'),
      );
      await expectLater(ops.sessionMarkRead(_session), throwsStateError);
    });
  });

  group('copy', () {
    test('es / en', () {
      expect(es.actMarkRead, 'Marcar leído');
      expect(en.actMarkRead, 'Mark read');
      expect(es.resultDone, 'Listo');
      expect(en.resultDone, 'Complete');
      expect(es.resultFailedLine, 'No pudo terminar');
      expect(en.resultFailedLine, 'Couldn’t finish');
    });
  });

  test('native side: Mark read takes the card down and confirms nothing', () {
    final kt = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/HermesRichNotifications.kt',
    ).readAsStringSync();
    expect(kt, contains('"always", "session", "read", "mute")'));
    final read = kt.substring(
      kt.indexOf('if (actionId == "read") {'),
      kt.indexOf('if (locked) {'),
    );
    expect(read, contains('HermesRichNotifications.dismiss(context, tag, id)'));
    // Behind App Lock only the card goes.
    expect(read, contains('if (locked) return'));
    expect(read.indexOf('dismiss('), lessThan(read.indexOf('if (locked)')));
    expect(read, contains('HermesNotificationActionInbox.enqueue('));
    expect(read, isNot(contains('confirmWith(')));
    // Nor does an unexecuted one come back as a failure card.
    expect(kt, contains('entry.optString("action") != "read"'));
  });
}

final class _Sink implements RichNotificationSink {
  final posts = <Map<String, Object?>>[];
  final confirms = <String>[];
  bool accept = true;
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
  Future<bool> postConversation(Map<String, Object?> args) async {
    if (!accept) return false;
    posts.add(args);
    return true;
  }

  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async {}
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
  Future<void> runApprove(NotificationActionPayload p, String choice) async {}
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

final class _Ops extends _PlainOps implements ChatSessionActionOps {
  final replies = <String>[];
  final read = <String?>[];
  Object? error;
  @override
  Future<void> sessionReply(
    NotificationActionPayload p,
    String text,
    String clientTurnId,
  ) async {
    if (error != null) throw error!;
    replies.add('${p.sessionId}:$text:$clientTurnId');
  }

  @override
  Future<void> sessionMarkRead(NotificationActionPayload p) async {
    if (error != null) throw error!;
    read.add(p.sessionId);
  }

  @override
  Future<void> sessionStop(NotificationActionPayload p) async {}
  @override
  Future<void> sessionAnswer(
    NotificationActionPayload p,
    String answer,
  ) async {}
}

class _ClosingClient extends MockClient {
  _ClosingClient(super.fn);

  int closeCalls = 0;

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}
