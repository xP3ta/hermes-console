// Every notification Hermes Console posts is a rich conversation card: a
// face (owner Bot or neutral ">_" glyph, with the state badge), the state
// accent, verbs and a public version. The plain flutter_local_notifications
// template is only a fallback when the native renderer is unavailable.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_notification_presenter.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../bots/room/room_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  sqflite.databaseFactory = databaseFactoryFfi;
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('all-rich-');
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls = [];
    SharedPreferences.setMockInitialValues({
      'app_locale': 'es',
      'notif_perm_requested': true,
      'notif_background_listen': true,
      'notif_cron_results': true,
      'notif_kanban_results': true,
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
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
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    await dir.delete(recursive: true);
  });

  for (final rejection in ['false', 'missing', 'error']) {
    test('native batch ACK $rejection retains custody', () async {
      const native = MethodChannel(PlatformRichNotifications.channelName);
      messenger.setMockMethodCallHandler(native, (call) async {
        expect(call.method, 'ackPendingActions');
        expect(call.arguments, {
          'uids': ['synthetic-action'],
        });
        if (rejection == 'error') {
          throw PlatformException(code: 'synthetic_unavailable');
        }
        return rejection == 'false' ? false : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(native, null));
      await expectLater(
        PlatformRichNotifications().ackActions(['synthetic-action']),
        throwsStateError,
      );
    });
  }

  test('native batch ACK explicit true completes', () async {
    const native = MethodChannel(PlatformRichNotifications.channelName);
    messenger.setMockMethodCallHandler(native, (call) async {
      expect(call.method, 'ackPendingActions');
      expect(call.arguments, {
        'uids': ['synthetic-action'],
      });
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(native, null));
    await PlatformRichNotifications().ackActions(['synthetic-action']);
  });

  Future<(NotificationService, _Sink)> service() async {
    final prefs = await SharedPreferences.getInstance();
    final sink = _Sink();
    final s = NotificationService(
      prefs,
      deliveryStore: NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${dir.path}/d.db',
      ),
    )..appInForeground = false;
    s.setRichForTesting(
      sink,
      faces: BotFaceBitmapCache(directory: () async => dir),
    );
    addTearDown(s.closeDelivery);
    return (s, sink);
  }

  /// Every public producer of NotificationService, with realistic inputs.
  final kinds = <String, Future<void> Function(NotificationService s)>{
    'approval': (s) => s.approvalPending(
      tool: 'terminal',
      connId: 'c1',
      runId: 'r1',
      approvalId: 'a1',
    ),
    'runFinished': (s) => s.runFinished(
      title: 'Informe',
      ok: true,
      connId: 'c1',
      sessionId: 's1',
      runId: 'r2',
    ),
    'goal': (s) => s.goalTransition(
      title: 'Meta',
      status: 'done',
      connId: 'c1',
      sessionId: 's1',
    ),
    'cron ok': (s) => s.cronFinished(
      title: 'Resumen de noticias',
      ok: true,
      connId: 'c1',
      sessionId: 'cron_j_1',
      executionId: 'e1',
      jobId: 'j',
    ),
    'cron failed': (s) => s.cronFinished(
      title: 'Resumen de noticias',
      ok: false,
      connId: 'c1',
      sessionId: 'cron_j_2',
      executionId: 'e2',
      jobId: 'j',
    ),
    'kanban': (s) => s.kanbanTransition(
      connId: 'c1',
      taskId: 't1',
      title: 'Subir build',
      status: 'blocked',
      assignee: 'builder',
    ),
    'runLive': (s) =>
        s.runLive(runId: 'r3', title: 'Run', body: 'Paso 2', connId: 'c1'),
    'sessionActivity': (s) => s.sessionActivityFinished(
      phase: 'completed',
      connId: 'c1',
      sessionId: 's2',
    ),
    'backgroundTask': (s) => s.backgroundTaskFinished(
      isError: false,
      connId: 'c1',
      sessionId: 's3',
      taskId: 'bt1',
    ),
    'replyReady': (s) => s.replyReady(
      preview: 'Hecho',
      session: 'Chat',
      connId: 'c1',
      sessionId: 's4',
    ),
    'replyFailed': (s) =>
        s.replyFailed(session: 'Chat', connId: 'c1', sessionId: 's5'),
    'localInstall': (s) => s.localInstallFinished(ok: true),
    'localUninstall': (s) => s.localUninstallFinished(ok: false),
    'test': (s) => s.sendTest(),
  };

  for (final entry in kinds.entries) {
    test('${entry.key} is a rich card, never the plain template', () async {
      final (s, sink) = await service();
      await entry.value(s);
      expect(
        calls.where((c) => c.method == 'show'),
        isEmpty,
        reason: '${entry.key} used the plain builder',
      );
      expect(sink.posts, isNotEmpty, reason: entry.key);
      for (final card in sink.posts) {
        expect(card['accent'], isA<int>(), reason: entry.key);
        expect(card['publicTitle'], isNotNull, reason: entry.key);
        if (card['style'] == 'row') {
          // An automation result: a plain row, no conversation of its own.
          expect(card.containsKey('conversationId'), isFalse);
          expect(card.containsKey('messages'), isFalse);
          continue;
        }
        final msg = (card['messages'] as List).last as Map;
        // A face or the neutral glyph, never the app portrait.
        expect(msg['iconPath'], isA<String>(), reason: entry.key);
        expect(card['conversationId'], isNotNull, reason: entry.key);
      }
    });
  }

  test('kanban with an assignee: that Bot signs the row', () async {
    final (s, sink) = await service();
    await s.kanbanTransition(
      connId: 'c1',
      taskId: 't9',
      title: 'Subir build',
      status: 'blocked',
      assignee: 'builder',
    );
    final row = sink.posts.single;
    expect(row['style'], 'row');
    expect(row['title'], 'Subir build');
    expect(row['text'], 'Bloqueada');
    expect(row['subText'], 'builder');
    expect(row['largeIconPath'] as String, isNot(contains('glyph_')));
    expect(row['accent'], RichAccent.failed);
    expect(row['alert'], isTrue);
    expect(
      [for (final a in row['actions'] as List) (a as Map)['label']],
      ['Abrir tarea', 'Silenciar'],
    );
  });

  test('cron ok: the state and what it said first, silent', () async {
    final (s, sink) = await service();
    await s.cronFinished(
      title: 'QA aviso Console 2',
      ok: true,
      connId: 'c1',
      sessionId: 'cron_q_1',
      executionId: 'eq',
      jobId: 'q',
      preview: '**3 novedades** hoy\n- una\n- dos',
    );
    final row = sink.posts.single;
    expect(row['style'], 'row');
    expect(row['title'], 'QA aviso Console 2');
    expect(row['text'], 'Terminó · 3 novedades hoy');
    expect(row['subText'], 'Tareas programadas');
    expect(row.containsKey('largeIconPath'), isFalse);
    expect(row['accent'], RichAccent.done);
    expect(row['alert'], isFalse);
    expect(
      [for (final a in row['actions'] as List) (a as Map)['label']],
      ['Ver resultado', 'Silenciar'],
    );
  });

  test('kanban done without assignee: task title under Tareas', () async {
    final (s, sink) = await service();
    await s.kanbanTransition(
      connId: 'c1',
      taskId: 't7',
      title: 'QA aviso kanban done',
      status: 'done',
    );
    final row = sink.posts.single;
    expect(row['title'], 'QA aviso kanban done');
    expect(row['text'], 'Terminada');
    expect(row['subText'], 'Tareas');
    expect(row['alert'], isFalse);
    expect(
      [for (final a in row['actions'] as List) (a as Map)['label']],
      ['Abrir tarea', 'Silenciar'],
    );
  });

  test('renderer unavailable → plain fallback still delivers', () async {
    final (s, sink) = await service();
    sink.accept = false;
    await s.runFinished(
      title: 'Informe',
      ok: true,
      connId: 'c1',
      sessionId: 's1',
      runId: 'rx',
    );
    expect(calls.where((c) => c.method == 'show'), isNotEmpty);
  });

  group('room member names', () {
    test('raw handles become display names', () {
      expect(humanizeBotHandle('console-radar'), 'Radar');
      expect(humanizeBotHandle('atlas'), 'Atlas');
      expect(humanizeBotHandle('code_review'), 'Code review');
      final room = buildRoom(
        members: [
          memberJson('m1', 'radar', displayName: 'console-radar'),
          memberJson('m2', 'atlas'),
          memberJson('m3', 'lead', displayName: 'Lead QA'),
        ],
      );
      expect(memberName(room, 'm1'), 'Radar');
      expect(
        memberName(room, 'm1', nameFor: (p) => p == 'radar' ? 'Radar' : null),
        'Radar',
      );
      expect(memberName(room, 'm2'), 'Atlas');
      expect(memberName(room, 'm3'), 'Lead QA');
    });
  });
}

final class _Sink implements RichNotificationSink {
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
