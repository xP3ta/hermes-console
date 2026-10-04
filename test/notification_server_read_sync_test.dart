// A chat read on another device (Desktop) clears this phone's reply
// notification the next time the app reads the session list; nothing else.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/notifications/chat_notification_read_sync.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session _row(
  String id, {
  bool? unread = false,
  Object? lastReadAt = 200.0,
  String? profile = 'default',
  String? root,
}) => Session.fromJson({
  'id': id,
  'title': 'Chat $id',
  'model': 'm',
  'source': 'cli',
  'message_count': 2,
  'preview': '',
  'started_at': 1.0,
  'last_active': 100.0,
  '_lineage_root_id': ?root,
  'profile': ?profile,
  'unread': ?unread,
  'last_read_at': lastReadAt,
});

class _Cancels {
  final List<(int, String?)> calls = [];
  Future<void> call(int id, String? tag) async => calls.add((id, tag));
  List<int> get ids => [for (final c in calls) c.$1];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => SessionArchive.listReadObserver = null);

  group('Session read state', () {
    test('a row is read on the server only with a watermark', () {
      expect(_row('a').readOnServer, isTrue);
      expect(_row('a', unread: true).readOnServer, isFalse);
      // NULL watermark = never tracked: says nothing about this chat.
      expect(_row('a', lastReadAt: null).readOnServer, isFalse);
      expect(_row('a', lastReadAt: 0).readOnServer, isFalse);
      // An older server without the flag.
      expect(_row('a', unread: null).readOnServer, isFalse);
      expect(_row('a').lastReadAt, 200.0);
    });
  });

  group('ChatNotificationReadSync over list reads', () {
    late SharedPreferences prefs;
    late _Cancels cancels;
    late ChatNotificationReadSync sync;

    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      cancels = _Cancels();
      sync = ChatNotificationReadSync(prefs, cancel: cancels.call);
      SessionArchive.listReadObserver = sync;
    });

    test('read on the server cancels it on the next list read', () async {
      sync.record(id: 6100, connId: 'c1', profile: null, sessionId: 's1');
      final archive = await SessionArchive.load(prefs, 'c1');
      archive.beginListRead().end(rows: [_row('s1')]);
      await settle();
      expect(cancels.ids, [6100]);
      // Gone from the ledger: a later read does not cancel it again.
      archive.beginListRead().end(rows: [_row('s1')]);
      await settle();
      expect(cancels.ids, [6100]);
    });

    test('a chat still unread (or never tracked) keeps it', () async {
      sync.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 's1');
      sync.record(id: 6101, connId: 'c1', profile: 'default', sessionId: 's2');
      final archive = await SessionArchive.load(prefs, 'c1');
      archive.beginListRead().end(
        rows: [_row('s1', unread: true), _row('s2', lastReadAt: null)],
      );
      await settle();
      expect(cancels.calls, isEmpty);
    });

    test('another profile or connection is never touched', () async {
      sync.record(id: 6100, connId: 'c1', profile: 'work', sessionId: 's1');
      sync.record(id: 6101, connId: 'c2', profile: 'default', sessionId: 's2');
      final c1 = await SessionArchive.load(prefs, 'c1');
      // Same id read in the default profile of c1; s2 read on c1, not c2.
      c1.beginListRead().end(rows: [_row('s1'), _row('s2')]);
      // A row without a published profile proves nothing either, not even
      // for the default profile.
      sync.record(id: 6102, connId: 'c1', profile: null, sessionId: 's3');
      c1.beginListRead().end(
        rows: [_row('s1', profile: null), _row('s3', profile: null)],
      );
      await settle();
      expect(cancels.calls, isEmpty);
      c1.beginListRead().end(rows: [_row('s1', profile: 'Work')]);
      await settle();
      expect(cancels.ids, [6100]);
    });

    test('matches the compression lineage of the row', () async {
      sync.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 'r1');
      final archive = await SessionArchive.load(prefs, 'c1');
      archive.beginListRead().end(rows: [_row('tip', root: 'r1')]);
      await settle();
      expect(cancels.ids, [6100]);
    });

    test('a notification posted after the read began survives it', () async {
      final archive = await SessionArchive.load(prefs, 'c1');
      final stale = archive.beginListRead();
      // A new reply lands while the list is in flight.
      sync.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 's1');
      stale.end(rows: [_row('s1')]);
      await settle();
      expect(cancels.calls, isEmpty);
      // The same address re-posted after a read began is also newer.
      sync.record(id: 6101, connId: 'c1', profile: 'default', sessionId: 's2');
      final second = archive.beginListRead();
      sync.record(id: 6101, connId: 'c1', profile: 'default', sessionId: 's2');
      second.end(rows: [_row('s2')]);
      await settle();
      expect(cancels.calls, isEmpty);
      archive.beginListRead().end(rows: [_row('s1'), _row('s2')]);
      await settle();
      expect(cancels.ids..sort(), [6100, 6101]);
    });

    test('another notification at the same address drops the entry', () async {
      sync.record(id: 7200, connId: 'c1', profile: 'default', sessionId: 's1');
      sync.forget(7200, null);
      final archive = await SessionArchive.load(prefs, 'c1');
      archive.beginListRead().end(rows: [_row('s1')]);
      await settle();
      expect(cancels.calls, isEmpty);
    });

    test('the ledger survives a process restart', () async {
      sync.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 's1');
      await settle();
      final restarted = ChatNotificationReadSync(prefs, cancel: cancels.call);
      SessionArchive.listReadObserver = restarted;
      final early = restarted.listReadStarted();
      restarted.record(
        id: 6101,
        connId: 'c1',
        profile: 'default',
        sessionId: 's2',
      );
      restarted.listReadEnded('c1', early, [_row('s1'), _row('s2')]);
      await settle();
      expect(cancels.ids, [6100]);
    });

    test('opening the chat on the phone clears only that chat', () async {
      sync.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 's1');
      sync.record(id: 6101, connId: 'c1', profile: 'default', sessionId: 's2');
      sync.record(id: 6102, connId: 'c2', profile: 'default', sessionId: 's1');
      sync.record(id: 6103, connId: 'c1', profile: 'work', sessionId: 's1');
      await sync.clearSession(connId: 'c1', profile: '', sessionId: 's1');
      expect(cancels.ids, [6100]);
    });

    test('opening a chat clears the ids of its lineage too', () async {
      sync.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 'a');
      sync.record(id: 6101, connId: 'c1', profile: 'default', sessionId: 'b');
      sync.record(id: 6102, connId: 'c1', profile: 'default', sessionId: 'x');
      await sync.clearSession(
        connId: 'c1',
        sessionId: 'b',
        aliases: const ['root', 'a', ''],
      );
      await settle();
      expect(cancels.ids, [6100, 6101]);
    });

    test('App Lock holds a read until unlock, then runs it once', () async {
      final locked = ValueNotifier(true);
      final gated = ChatNotificationReadSync(
        prefs,
        cancel: cancels.call,
        locked: locked,
      );
      SessionArchive.listReadObserver = gated;
      gated.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 's1');
      gated.record(id: 6102, connId: 'c1', profile: 'default', sessionId: 's3');
      final archive = await SessionArchive.load(prefs, 'c1');
      archive.beginListRead().end(rows: [_row('s1'), _row('s3')]);
      await settle();
      expect(cancels.calls, isEmpty);
      // A new reply for s1 lands while the phone is still locked.
      gated.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 's1');
      locked.value = false;
      await settle();
      expect(cancels.ids, [6102]);
      // Once: locking and unlocking again replays nothing.
      locked.value = true;
      locked.value = false;
      await settle();
      expect(cancels.ids, [6102]);
    });

    test('App Lock holds an open until unlock and rechecks it then', () async {
      final locked = ValueNotifier(true);
      final gated = ChatNotificationReadSync(
        prefs,
        cancel: cancels.call,
        locked: locked,
      );
      gated.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 's1');
      gated.record(id: 6101, connId: 'c1', profile: 'default', sessionId: 's2');
      var s2InFront = false;
      await gated.clearSession(connId: 'c1', sessionId: 's1');
      await gated.clearSession(
        connId: 'c1',
        sessionId: 's2',
        stillWanted: () => s2InFront,
      );
      // Posted while locked, after the open: not part of what was seen.
      gated.record(id: 6103, connId: 'c1', profile: 'default', sessionId: 's1');
      // Opened again while still locked: the first fence stands.
      await gated.clearSession(connId: 'c1', sessionId: 's1');
      await settle();
      expect(cancels.calls, isEmpty);
      locked.value = false;
      await settle();
      // s2 left the front before unlock.
      expect(cancels.ids, [6100]);
      s2InFront = true;
      locked.value = true;
      locked.value = false;
      await settle();
      expect(cancels.ids, [6100]);
    });

    test('App Lock engaging mid-clear holds the rest until unlock', () async {
      final locked = ValueNotifier(false);
      final gate = <Completer<void>>[];
      final gated = ChatNotificationReadSync(
        prefs,
        cancel: (id, tag) {
          cancels.calls.add((id, tag));
          final done = Completer<void>();
          gate.add(done);
          return done.future;
        },
        locked: locked,
      );
      SessionArchive.listReadObserver = gated;
      gated.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 's1');
      gated.record(id: 6102, connId: 'c1', profile: 'default', sessionId: 's3');
      gated.record(id: 6105, connId: 'c1', profile: 'default', sessionId: 's5');
      final archive = await SessionArchive.load(prefs, 'c1');
      archive.beginListRead().end(rows: [_row('s1'), _row('s3'), _row('s5')]);
      await settle();
      expect(cancels.ids, [6100]);
      // The phone locks while the first cancel is on its way.
      locked.value = true;
      gate.single.complete();
      await settle();
      expect(cancels.ids, [6100]);
      // A new reply for s3 lands on the lock screen: not part of that read.
      gated.record(id: 6102, connId: 'c1', profile: 'default', sessionId: 's3');
      locked.value = false;
      await settle();
      expect(cancels.ids, [6100, 6105]);
      gate.last.complete();
      await settle();
      expect(cancels.ids, [6100, 6105]);
    });

    test('a cancel that fails keeps the entry for the next read', () async {
      var fail = true;
      final tried = <int>[];
      final flaky = ChatNotificationReadSync(
        prefs,
        cancel: (id, tag) async {
          tried.add(id);
          if (fail) throw StateError('plugin down');
        },
      );
      SessionArchive.listReadObserver = flaky;
      flaky.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 's1');
      final archive = await SessionArchive.load(prefs, 'c1');
      archive.beginListRead().end(rows: [_row('s1')]);
      await settle();
      expect(tried, [6100]);
      // Still in the tray: the next read tries again, and then it is gone.
      fail = false;
      archive.beginListRead().end(rows: [_row('s1')]);
      await settle();
      expect(tried, [6100, 6100]);
      archive.beginListRead().end(rows: [_row('s1')]);
      await settle();
      expect(tried, [6100, 6100]);
    });

    test('a repost recorded while the cancel is pending is kept', () async {
      final gate = <Completer<void>>[];
      final gated = ChatNotificationReadSync(
        prefs,
        cancel: (id, tag) {
          cancels.calls.add((id, tag));
          final done = Completer<void>();
          gate.add(done);
          return done.future;
        },
      );
      SessionArchive.listReadObserver = gated;
      gated.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 's1');
      final archive = await SessionArchive.load(prefs, 'c1');
      archive.beginListRead().end(rows: [_row('s1')]);
      await settle();
      expect(cancels.ids, [6100]);
      // A new reply lands at the same address before the cancel answers.
      gated.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 's1');
      gate.single.complete();
      await settle();
      // The answer of the old cancel does not drop the new one.
      archive.beginListRead().end(rows: [_row('s1')]);
      await settle();
      expect(cancels.ids, [6100, 6100]);
    });

    test('a post waits for a pending cancel at its address', () async {
      final gate = Completer<void>();
      final gated = ChatNotificationReadSync(
        prefs,
        cancel: (id, tag) {
          cancels.calls.add((id, tag));
          return gate.future;
        },
      );
      SessionArchive.listReadObserver = gated;
      gated.record(id: 6100, connId: 'c1', profile: 'default', sessionId: 's1');
      final archive = await SessionArchive.load(prefs, 'c1');
      archive.beginListRead().end(rows: [_row('s1')]);
      var posting = false;
      unawaited(gated.beginPost(6100, null).then((_) => posting = true));
      // Another address is not held back.
      var other = false;
      unawaited(gated.beginPost(6101, null).then((_) => other = true));
      await settle();
      expect(posting, isFalse);
      expect(other, isTrue);
      gate.complete();
      await settle();
      expect(posting, isTrue);
      gated.endPost(6100, null);
      gated.endPost(6101, null);
    });

    test('a cancel never lands on a post in flight', () async {
      final order = <String>[];
      final ordered = ChatNotificationReadSync(
        prefs,
        cancel: (id, tag) async => order.add('cancel $id'),
      );
      SessionArchive.listReadObserver = ordered;
      ordered.record(
        id: 6100,
        connId: 'c1',
        profile: 'default',
        sessionId: 's1',
      );
      final archive = await SessionArchive.load(prefs, 'c1');
      // The read answers and a repost starts in the same turn: the cancel
      // goes out before the post, never after it.
      archive.beginListRead().end(rows: [_row('s1')]);
      order.add('post');
      final post = ordered.beginPost(6100, null);
      await settle();
      await post;
      expect(order, ['cancel 6100', 'post']);
      // A read that ends while a post is on its way leaves the tray alone,
      // even for what it proves read.
      ordered.record(
        id: 6101,
        connId: 'c1',
        profile: 'default',
        sessionId: 's2',
      );
      await ordered.beginPost(6101, null);
      archive.beginListRead().end(rows: [_row('s2')]);
      await settle();
      expect(order, ['cancel 6100', 'post']);
      ordered.endPost(6101, null);
      archive.beginListRead().end(rows: [_row('s2')]);
      await settle();
      expect(order, ['cancel 6100', 'post', 'cancel 6101']);
      ordered.endPost(6100, null);
    });
  });

  group('NotificationService', () {
    late List<MethodCall> calls;
    var failCancels = 0;
    void Function()? onShow;
    setUp(() {
      failCancels = 0;
      onShow = null;
    });

    Future<NotificationService> service() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({
        'app_locale': 'en',
        'notif_perm_requested': true,
      });
      calls = <MethodCall>[];
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'show') onShow?.call();
        if (call.method == 'initialize' ||
            call.method == 'areNotificationsEnabled') {
          return true;
        }
        if (call.method == 'getActiveNotifications') return <Object?>[];
        if (call.method == 'cancel' && failCancels > 0) {
          failCancels--;
          throw PlatformException(code: 'error');
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final prefs = await SharedPreferences.getInstance();
      final service = NotificationService(prefs)..appInForeground = false;
      SessionArchive.listReadObserver = service.enableChatReadSync();
      return service;
    }

    List<int> ids(String method) => [
      for (final c in calls.where((c) => c.method == method))
        if ((c.arguments as Map)['id'] != 500)
          (c.arguments as Map)['id'] as int,
    ];

    Future<void> readList(List<Session> rows) async {
      final prefs = await SharedPreferences.getInstance();
      final archive = await SessionArchive.load(prefs, 'c1');
      archive.beginListRead().end(rows: rows);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('a reply notification is cancelled once Desktop read it', () async {
      final notif = await service();
      await notif.replyReady(
        preview: 'done',
        session: 'Plan',
        connId: 'c1',
        sessionId: 's1',
        profile: 'default',
      );
      await notif.replyReady(
        preview: 'done',
        session: 'Other',
        connId: 'c1',
        sessionId: 's2',
        profile: 'default',
      );
      final shown = ids('show');
      expect(shown, hasLength(2));
      await readList([_row('s1'), _row('s2', unread: true)]);
      expect(ids('cancel'), [shown.first]);
    });

    test(
      'a Bot Mode reply card is left to the tray, its fallback is not',
      () async {
        final notif = await service();
        final rich = _RichSink();
        notif.setRichForTesting(rich);
        Future<void> botReply() => notif.replyReady(
          preview: 'done',
          session: 'Radar',
          connId: 'c1',
          sessionId: 's1',
          profile: 'radar',
          surface: NotificationChatSurface.bot,
        );
        await botReply();
        // Posted as the Bot's conversation card, shared with its routines.
        expect(rich.posts, hasLength(1));
        expect(ids('show'), isEmpty);
        await readList([_row('s1', profile: 'radar')]);
        expect(calls.where((c) => c.method == 'cancel'), isEmpty);
        // Without the rich renderer the plain card is a chat notification.
        rich.accept = false;
        await botReply();
        final shown = ids('show');
        expect(shown, hasLength(1));
        await readList([_row('s1', profile: 'radar')]);
        expect(ids('cancel'), shown);
      },
    );

    test('a read that ends while a repost is being shown spares it', () async {
      final notif = await service();
      await notif.replyReady(
        preview: 'done',
        session: 'Plan',
        connId: 'c1',
        sessionId: 's1',
        profile: 'default',
      );
      final prefs = await SharedPreferences.getInstance();
      final archive = await SessionArchive.load(prefs, 'c1');
      // The phone's list read of the chat (read on Desktop) answers right
      // when the plugin is showing the next reply at the same address.
      onShow = () => archive.beginListRead().end(rows: [_row('s1')]);
      await notif.replyReady(
        preview: 'more',
        session: 'Plan',
        connId: 'c1',
        sessionId: 's1',
        profile: 'default',
      );
      onShow = null;
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(ids('show'), hasLength(2));
      expect(ids('cancel'), isEmpty);
    });

    test('a cancel the plugin refuses is retried on the next read', () async {
      final notif = await service();
      await notif.replyReady(
        preview: 'done',
        session: 'Plan',
        connId: 'c1',
        sessionId: 's1',
        profile: 'default',
      );
      final shown = ids('show');
      failCancels = 1;
      await readList([_row('s1')]);
      expect(ids('cancel'), shown);
      await readList([_row('s1')]);
      expect(ids('cancel'), [...shown, ...shown]);
      await readList([_row('s1')]);
      expect(ids('cancel'), [...shown, ...shown]);
    });

    test(
      'another notification posted at the same id is never retracted',
      () async {
        final notif = await service();
        NotificationService.setAutomationNotificationsEnabledForTest(true);
        addTearDown(
          () => NotificationService.setAutomationNotificationsEnabledForTest(
            false,
          ),
        );
        // A chat whose activity notification shares the local install id.
        final sid = [for (var i = 0; i < 100000; i++) 's$i'].firstWhere(
          (sid) =>
              NotificationService.eventNotificationId(
                base: 7000,
                span: 512,
                parts: ['c1', sid],
              ) ==
              7200,
        );
        await notif.sessionActivityFinished(
          phase: 'completed',
          connId: 'c1',
          sessionId: sid,
          profile: 'default',
        );
        await notif.localInstallFinished(ok: true);
        expect(ids('show'), [7200, 7200]);
        await readList([_row(sid)]);
        expect(ids('cancel'), isEmpty);
      },
    );
  });
}

final class _RichSink implements RichNotificationSink {
  final posts = <Map<String, Object?>>[];
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
  }) async {}
  @override
  Future<bool> postConversation(Map<String, Object?> args) async {
    if (!accept) return false;
    posts.add(args);
    return true;
  }

  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async {}
}
