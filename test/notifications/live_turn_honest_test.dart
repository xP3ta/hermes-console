// The live row of a chat turn in the background says only what the app
// knows (Pixel run of build 9960, REPORT-OFICIAL-VS-CONSOLE S3):
// - while a background check is only pending the row keeps the last real
//   state (phase, counts, elapsed time, Stop, 12 min expiry);
// - only reads that fail to reach the server twice in a row make it say
//   «Sin conexión · reintentando…», and a read that reaches it again brings
//   the real state back;
// - a turn the check finds over is told at once as «xPeta · terminó», over
//   the chat's title only when content may be shown, at the address of the
//   chat's own reply notice; App Lock: no check at all.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/live_turn_check.dart';
import 'package:hermes_android/core/services/notifications/live_turn_notifications.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/notifications/session_attention.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const es = NotifL10n(true);
const languages = ['es', 'en', 'de', 'fr', 'it', 'pt', 'ja', 'ko', 'zh'];
const started = 1800000000000;
const working = 'Trabajando · 2 herramientas';
const offline = 'Sin conexión · reintentando…';

LiveTurnSnapshot turn({
  String sessionId = 'sess-1',
  String title = 'Informe de ventas',
  int tools = 2,
  String profile = 'default',
  LiveTurnPhase phase = LiveTurnPhase.working,
}) => LiveTurnSnapshot(
  connId: 'conn-a',
  profile: profile,
  sessionId: sessionId,
  title: title,
  phase: phase,
  tools: tools,
  startedAtMs: started,
);

double at(int ms) => ms / 1000;

final runningRows = [
  {'role': 'user', 'content': 'x', 'timestamp': at(started + 100)},
];
final finishedRows = [
  {'role': 'user', 'content': 'x', 'timestamp': at(started + 100)},
  {'role': 'assistant', 'content': 'Listo', 'timestamp': at(started + 41000)},
];

void expectStopAndExpiry(Map<String, Object?> args) {
  expect(args['stopLabel'], 'Parar');
  expect(args['actionPayload'], isA<String>());
  expect(
    args['timeoutMs'],
    LiveTurnNotifications.backgroundRowLifetime.inMilliseconds,
  );
  expect(LiveTurnNotifications.backgroundRowLifetime.inMinutes, 12);
  // The elapsed chip runs from the turn's own start.
  expect(args['startedAtMs'], started);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;

  group('row state machine', () {
    late _Sink sink;
    var now = DateTime.fromMillisecondsSinceEpoch(started);
    LiveTurnNotifications presenter() =>
        LiveTurnNotifications(sink: sink, strings: () => es, now: () => now);

    setUp(() {
      sink = _Sink();
      now = DateTime.fromMillisecondsSinceEpoch(started);
    });

    test('two failures in a row are needed', () {
      expect(LiveTurnNotifications.offlineAfterFailures, 2);
    });

    test('a pending check keeps the last real state; one failure is a blip',
        () async {
      final live = presenter();
      await live.update('k', turn(), show: true, background: true);
      expect(sink.live.single['text'], working);
      expectStopAndExpiry(sink.live.single);
      expect(await live.checkFailed('sess-1'), 0);
      expect(sink.live, hasLength(1), reason: 'nothing redrawn');
    });

    test('the second failure says «Sin conexión · reintentando…» at once, '
        'keeping Stop, expiry and elapsed time', () async {
      final live = presenter();
      await live.update('k', turn(), show: true, background: true);
      await live.checkFailed('sess-1');
      expect(await live.checkFailed('sess-1'), 1);
      expect(sink.live, hasLength(2), reason: 'not held by the rate window');
      final row = sink.live.last;
      expect(row['text'], offline);
      expect(row['publicText'], offline);
      expect(row['text'], isNot(contains('herramientas')));
      expectStopAndExpiry(row);
    });

    test('a read that reaches the server brings the real state back, at once',
        () async {
      final live = presenter();
      await live.update('k', turn(), show: true, background: true);
      await live.checkFailed('sess-1');
      await live.checkFailed('sess-1');
      expect(await live.checkReached('sess-1'), 1);
      expect(sink.live, hasLength(3));
      expect(sink.live.last['text'], working);
      expectStopAndExpiry(sink.live.last);
      // The count starts again: one more failure is a blip again.
      expect(await live.checkFailed('sess-1'), 0);
      expect(sink.live, hasLength(3));
      // A reached read on a row that was not offline redraws nothing.
      expect(await live.checkReached('sess-1'), 0);
      expect(sink.live, hasLength(3));
    });

    test('a success between failures resets the count', () async {
      final live = presenter();
      await live.update('k', turn(), show: true, background: true);
      await live.checkFailed('sess-1');
      await live.checkReached('sess-1');
      expect(await live.checkFailed('sess-1'), 0);
      expect(sink.live.last['text'], working);
    });

    test('failures of one chat leave the other alone; a settled row is not '
        'redrawn', () async {
      final live = presenter();
      await live.update('a', turn(), show: true, background: true);
      await live.update(
        'b',
        turn(sessionId: 'sess-2'),
        show: true,
        background: true,
      );
      await live.checkFailed('sess-2');
      expect(await live.checkFailed('sess-2'), 1);
      expect(
        sink.live.where((r) => r['sessionId'] == 'sess-1').last['text'],
        working,
      );
      await live.settle('sess-1');
      final posts = sink.live.length;
      await live.checkFailed('sess-1');
      await live.checkFailed('sess-1');
      expect(sink.live, hasLength(posts));
    });

    test('hidden content: the offline row names nobody\'s chat', () async {
      final live = presenter();
      await live.update(
        'k',
        turn(),
        show: true,
        background: true,
        hideSensitive: true,
      );
      await live.checkFailed('sess-1');
      await live.checkFailed('sess-1');
      final row = sink.live.last;
      expect(row['text'], offline);
      for (final key in const [
        'title',
        'text',
        'bigText',
        'subText',
        'publicTitle',
        'publicText',
      ]) {
        expect('${row[key]}', isNot(contains('Informe de ventas')), reason: key);
      }
    });
  });

  group('runs of the check drive the row', () {
    late SharedPreferences prefs;
    late _Sink sink;
    late _Scheduler scheduler;
    late NotificationService service;
    late Directory dir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'app_locale': 'es',
        'notif_hide_sensitive_content': false,
      });
      prefs = await SharedPreferences.getInstance();
      dir = await Directory.systemTemp.createTemp('live-honest-');
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

    LiveTurnBackgroundCheck check(
      Object? Function() rows, {
      Duration budget = LiveTurnCheckPolicy.runBudget,
    }) => LiveTurnBackgroundCheck(
      read: (_) async {
        final r = rows();
        if (r is Exception) throw r;
        return r;
      },
      appLocked: () => false,
      deliver: NotificationSessionAttentionSink(service).deliver,
      budget: budget,
    );

    test('unreachable, unreachable, reached: real → real → offline → real',
        () async {
      service.appInForeground = false;
      service.liveTurnChanged('k', turn());
      await until(() => sink.live.isNotEmpty);
      Object? rows = const SocketException('down');
      var answer = await service.checkLiveTurnsInBackground(
        check: check(() => rows),
      );
      expect(answer['pending'], 1);
      expect(sink.live.last['text'], working, reason: 'pending: last state');
      answer = await service.checkLiveTurnsInBackground(
        attempt: 1,
        elapsed: const Duration(seconds: 45),
        check: check(() => rows),
      );
      expect(answer['nextDelayMs'], 30000);
      expect(sink.live.last['text'], offline);
      expectStopAndExpiry(sink.live.last);
      rows = runningRows;
      await service.checkLiveTurnsInBackground(
        attempt: 2,
        elapsed: const Duration(seconds: 75),
        check: check(() => rows),
      );
      expect(sink.live.last['text'], working);
      expect(sink.conversations, isEmpty, reason: 'still running');
    });

    test('chats left for the next run (out of budget) count as neither',
        () async {
      service.appInForeground = false;
      service.liveTurnChanged('k', turn());
      await until(() => sink.live.isNotEmpty);
      for (var i = 0; i < 3; i++) {
        final answer = await service.checkLiveTurnsInBackground(
          attempt: i,
          check: check(() => const SocketException('down'),
              budget: Duration.zero),
        );
        expect(answer['pending'], 1);
      }
      expect(sink.live, hasLength(1));
      expect(sink.live.last['text'], working);
    });

    test('a finished turn is told at once and its row goes', () async {
      service.appInForeground = false;
      service.liveTurnChanged('k', turn());
      await until(() => sink.live.isNotEmpty);
      final tag = sink.live.single['tag'];
      final answer = await service.checkLiveTurnsInBackground(
        check: check(() => finishedRows),
      );
      expect(answer['pending'], 0);
      expect(sink.cancelled, contains(tag));
      final card = sink.conversations.single;
      expect(card['title'], 'Hermes · terminó');
      expect(card['text'], 'Informe de ventas');
    });

    test('a row the chat\'s own socket already ended is not told again',
        () async {
      service.appInForeground = false;
      service.liveTurnChanged('k', turn());
      await until(() => sink.live.isNotEmpty);
      await service.checkLiveTurnsInBackground(
        check: LiveTurnBackgroundCheck(
          read: (_) async {
            // The socket, still alive, reports the end while the read runs.
            service.liveTurnChanged('k', null);
            await until(() => sink.cancelled.isNotEmpty);
            return finishedRows;
          },
          appLocked: () => false,
          deliver: NotificationSessionAttentionSink(service).deliver,
        ),
      );
      expect(sink.conversations, isEmpty);
    });

    test('replies off: the row still goes, nothing is posted', () async {
      service.appInForeground = false;
      service.liveTurnChanged('k', turn());
      await until(() => sink.live.isNotEmpty);
      final tag = sink.live.single['tag'];
      await prefs.setBool('notif_replies', false);
      await service.checkLiveTurnsInBackground(
        check: check(() => finishedRows),
      );
      expect(sink.cancelled, contains(tag));
      expect(sink.conversations, isEmpty);
    });

    test('App Lock: no chain is scheduled and nothing is read', () async {
      await prefs.setBool('app_lock_enabled', true);
      service.liveTurnChanged('k', turn());
      service.appInForeground = false;
      await until(() => sink.live.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(scheduler.scheduled, isEmpty);
      var reads = 0;
      final pass = await LiveTurnBackgroundCheck(
        read: (_) async {
          reads++;
          return finishedRows;
        },
        appLocked: () => liveTurnAppLocked(prefs),
        deliver: (_) async {},
      ).run([turn()]);
      expect(reads, 0);
      expect(pass.pending, 0);
      // Without App Lock the chain starts ~25 s after leaving the screen.
      await prefs.setBool('app_lock_enabled', false);
      service.appInForeground = true;
      service.appInForeground = false;
      await until(() => scheduler.scheduled.isNotEmpty);
      expect(scheduler.scheduled, [const Duration(seconds: 25)]);
    });
  });

  group('completion notice copy', () {
    test('«xPeta · terminó» over the chat title only with content shown', () {
      final shown = liveTurnFinishedCopy(
        es,
        who: 'xPeta',
        chatTitle: 'Informe de ventas',
        hideSensitive: false,
      );
      expect(shown.title, 'xPeta · terminó');
      expect(shown.body, 'Informe de ventas');
      final hidden = liveTurnFinishedCopy(
        es,
        who: 'xPeta',
        chatTitle: 'Informe de ventas',
        hideSensitive: true,
      );
      expect(hidden.title, 'xPeta · terminó');
      expect(hidden.body, 'Nueva actividad en Hermes');
      expect(
        liveTurnFinishedCopy(
          es,
          who: 'xPeta',
          chatTitle: '  ',
          hideSensitive: false,
        ).body,
        'Nueva actividad en Hermes',
        reason: 'no title: the generic line',
      );
      expect(
        liveTurnFinishedCopy(
          es,
          who: '',
          chatTitle: 'x',
          hideSensitive: true,
        ).title,
        'Hermes · terminó',
      );
    });

    test('every language names who finished, with no stray placeholder', () {
      for (final lang in languages) {
        final t = NotifL10n(lang);
        final title = t.liveFinishedTitle('xPeta');
        expect(title, contains('xPeta'), reason: lang);
        expect(title, isNot(contains('{')), reason: lang);
        expect(t.liveOffline, isNot(contains('{')), reason: lang);
      }
      expect(const NotifL10n('en').liveFinishedTitle('xPeta'),
          'xPeta · finished');
      expect(es.liveOffline, offline);
    });

    test('the card: title, body and a lock screen without the chat', () {
      const open = NotificationOpen(connId: 'conn-a', sessionId: 's');
      Map<String, Object?> card({required bool hide}) =>
          RichNotificationBuilder(es).turnFinished(
            tag: hide ? null : 'chat-tag',
            id: hide ? 0x10000001 : RichNotificationIds.conversation,
            conversationId: 'chat-x',
            ownerKey: 'xpeta',
            who: 'xPeta',
            chatTitle: 'Informe de ventas',
            hideSensitive: hide,
            open: open,
            nowMs: started,
          );
      final shown = card(hide: false);
      expect(shown['tag'], 'chat-tag');
      expect(shown['id'], RichNotificationIds.conversation);
      expect(shown['title'], 'xPeta · terminó');
      expect(shown['text'], 'Informe de ventas');
      expect(shown['alert'], isFalse);
      expect(shown['accent'], RichAccent.done);
      expect(shown['publicTitle'], 'xPeta');
      expect(shown['publicText'], 'Terminó');
      expect('${shown['summaryLine']}', isNot(contains('Informe')));
      final hidden = card(hide: true);
      expect(hidden.containsKey('tag'), isFalse);
      expect(hidden['id'], 0x10000001);
      expect(hidden['title'], 'xPeta · terminó');
      expect(hidden['text'], 'Nueva actividad en Hermes');
      expect(jsonEncode(hidden), isNot(contains('Informe de ventas')));
    });
  });

  group('completion notice address = the reply notice of that chat', () {
    const plugin = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory dir;
    late _Sink sink;
    late NotificationService service;

    Future<void> setUpService({required bool hide}) async {
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
        'notif_hide_sensitive_content': hide,
        'notif_perm_requested': true,
      });
      dir = await Directory.systemTemp.createTemp('live-honest-addr-');
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

    Future<Map<String, Object?>> notice({required bool check}) async {
      final before = sink.conversations.length;
      await NotificationSessionAttentionSink(service).deliver(
        SessionAttentionSignal(
          kind: SessionAttentionKind.turnDone,
          connId: 'conn-a',
          profile: 'default',
          storedSessionId: 'sess-1',
          title: 'Informe de ventas',
          preview: 'Listo',
          endedAtMs: started + 41000,
          backgroundCheck: check,
        ),
      );
      expect(sink.conversations, hasLength(before + 1));
      return sink.conversations.last;
    }

    Future<void> showRow() async {
      service.liveTurnChanged('k', turn());
      for (var i = 0; i < 200 && sink.live.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(sink.live, isNotEmpty);
    }

    for (final hide in [true, false]) {
      test('hide content ${hide ? 'on' : 'off'}', () async {
        await setUpService(hide: hide);
        await showRow();
        final fromCheck = await notice(check: true);
        expect(fromCheck['title'], 'Hermes · terminó');
        expect(
          fromCheck['text'],
          hide ? 'Nueva actividad en Hermes' : 'Informe de ventas',
        );
        if (hide) {
          expect(jsonEncode(fromCheck), isNot(contains('Informe de ventas')));
        }
        final fromReply = await notice(check: false);
        expect(fromCheck['id'], fromReply['id']);
        expect(fromCheck['tag'], fromReply['tag']);
        expect(fromReply['title'], isNot(contains('terminó')),
            reason: 'the reply notice keeps its own copy');
      });
    }
  });
}

final class _Sink implements RichNotificationSink {
  final live = <Map<String, Object?>>[];
  final conversations = <Map<String, Object?>>[];
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
  Future<bool> postConversation(Map<String, Object?> args) async {
    conversations.add(args);
    return true;
  }

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
