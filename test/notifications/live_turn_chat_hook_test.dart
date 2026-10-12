// A chat turn of this phone has a live row: the chat's own status (the one
// the pill, the list and Inicio read) reaches the tray, and the row leaves
// when the turn ends.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../session_identity_peer_test.dart' as peer;
import '../support/in_memory_compression_restore_storage.dart';

final _connection = SavedConnection(
  id: 'peer',
  label: 'Peer',
  host: 'example.invalid',
  port: 443,
  apiKey: 'k',
  useHttps: true,
  kind: InstanceKind.vps,
);

DesktopSessionSnapshot _running() => DesktopSessionSnapshot.fromJson(
  {
    'session_id': 'runtime-peer',
    'session_key': 'stored-peer',
    'message_count': 1,
    'messages': [peer.publicSnapshot],
    'running': true,
    'inflight': {'assistant': '', 'streaming': true},
    'todo_state': {
      'revision': 3,
      'todos': [
        {'id': '1', 'content': 'Leer el informe', 'status': 'completed'},
        {'id': '2', 'content': 'Arreglar la pastilla', 'status': 'in_progress'},
        {'id': '3', 'content': 'Probar en el móvil', 'status': 'pending'},
      ],
    },
  },
  requestedStoredSessionId: 'stored-peer',
  created: false,
  method: 'session.resume',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Sink sink;
  late NotificationService notifications;
  late ActiveChatService service;
  late peer.PeerGateway gateway;
  late ActiveChat chat;
  late Directory dir;

  /// The presenter never posts one chat more than once a second.
  Future<void> nextWindow() =>
      Future<void>.delayed(const Duration(milliseconds: 1300));

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 250));

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'app_locale': 'es',
      'notif_background_listen': true,
    });
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
    dir = await Directory.systemTemp.createTemp('live-hook-');
    sink = _Sink();
    notifications = NotificationService(await SharedPreferences.getInstance())
      ..setRichForTesting(
        sink,
        faces: BotFaceBitmapCache(directory: () async => dir),
      );
    service = ActiveChatService(
      notifications: notifications,
      compressionRestoreStore: testCompressionRestoreStore(),
      globalActivity: GlobalActivityAggregate.inMemory(),
    );
    gateway = peer.PeerGateway(_running());
    chat = service.attach(
      connection: _connection,
      sessionId: 'stored-peer',
      sessionTitle: 'Peer',
      api: ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('nf', 404)),
      ),
      desktopGateway: gateway,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
    );
    // The user opens a chat whose turn is already running, reads it...
    await chat.loadMessages();
    await settle();
    expect(sink.live, isEmpty, reason: 'no row while the app is in front');
    // ...and leaves the app. The first face is rendered off the event loop.
    notifications.appInForeground = false;
    for (var i = 0; i < 400 && sink.live.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  });

  tearDown(() async {
    service.dispose();
    await gateway.close();
    await dir.delete(recursive: true);
  });

  Future<void> emit(String type, Map<String, dynamic> payload) async {
    gateway.emit(type, payload);
    await Future<void>.delayed(Duration.zero);
  }

  test('a running turn has a row with its conversation, phase and tasks', () {
    expect(chat.isStreaming, isTrue);
    final row = sink.live.last;
    expect(row['title'], 'Peer');
    expect(row['subText'], 'Hermes');
    expect(row['text'], 'Pensando · Tareas 1 de 3');
    expect(row['progressMax'], 3);
    expect(row['progress'], 1);
    expect(row['segments'], 3);
    expect(
      row['tag'],
      RichNotificationIds.chatTag('peer', 'default', 'stored-peer'),
    );
    final stop = NotificationActionPayload.tryParse(
      row['actionPayload'] as String,
    )!;
    expect(stop.route, NotificationActionRoute.session);
    expect(stop.sessionId, 'stored-peer');
  });

  /// Waits for the tray to show what the test expects instead of a fixed
  /// time (the row is posted off the event loop).
  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  String lastText() => '${sink.live.last['text']}';
  final tag = RichNotificationIds.chatTag('peer', 'default', 'stored-peer');

  test('the row follows the turn: a tool, a task done, a request', () async {
    await nextWindow();
    await emit('tool.start', {
      'tool_id': 't1',
      'name': 'terminal',
      'args': {'command': 'pytest -q'},
    });
    await until(() => lastText().startsWith('Ejecutando'));
    expect(lastText(), startsWith('Ejecutando comando · Tareas 1 de 3'));
    expect(sink.live.last['shortText'], 'Trabaja');
    // The command itself never reaches the tray.
    expect(sink.live.last.values.join(' '), isNot(contains('pytest')));

    await nextWindow();
    await emit('todo.updated', {
      'revision': 4,
      'todos': [
        {'id': '1', 'content': 'Leer el informe', 'status': 'completed'},
        {'id': '2', 'content': 'Arreglar la pastilla', 'status': 'completed'},
        {'id': '3', 'content': 'Probar en el móvil', 'status': 'in_progress'},
      ],
    });
    await until(() => sink.live.last['progress'] == 2);
    expect(sink.live.last['progress'], 2);

    await nextWindow();
    await emit('approval.request', {
      'request_id': 'a1',
      'command': 'rm -rf build',
      'description': 'borrar',
    });
    await until(() => lastText().startsWith('Espera'));
    expect(lastText(), startsWith('Espera tu permiso'));
    expect(sink.live.last['shortText'], 'Permiso');
  });

  test('tokens do not post: only a change of what the row says does', () async {
    final before = sink.live.length;
    await nextWindow();
    for (var i = 0; i < 30; i++) {
      await emit('message.delta', {'text': 'palabra $i '});
    }
    await until(() => sink.live.length > before);
    await settle();
    // Thinking became responding once; thirty tokens are one post.
    expect(sink.live.length, before + 1);
    expect(lastText(), startsWith('Respondiendo'));
  });

  test('the turn ending takes the row away', () async {
    await emit('message.complete', {'text': 'Hecho'});
    await until(() => sink.cancelled.contains(tag));
    expect(chat.isStreaming, isFalse);
    expect(sink.cancelled, contains(tag));
  });

  test(
    'an approval is a card with the command and Permitir / Rechazar',
    () async {
      await emit('approval.request', {
        'request_id': 'a1',
        'command': 'rm -rf build',
        'description': 'borrar',
      });
      await until(() => sink.posts.isNotEmpty);
      final card = sink.posts.single;
      expect(card['channel'], 'approvals');
      expect(card['alert'], isTrue);
      expect(card['title'], 'Peer');
      expect(card['text'], '¿Permitir «rm -rf build»?');
      expect(card['tag'], tag);
      expect(
        [for (final a in card['actions']! as List) (a as Map)['label']],
        ['Permitir', 'Rechazar', 'Abrir'],
      );
      final payload = NotificationActionPayload.tryParse(
        card['actionPayload'] as String,
      )!;
      expect(payload.route, NotificationActionRoute.chat);
      expect(payload.sessionId, 'stored-peer');
      expect(payload.requestId, 'a1');
    },
  );

  test('a question is a card with its inline answer and choices', () async {
    await emit('clarify.request', {
      'request_id': 'c1',
      'question': '¿Sigo?',
      'choices': ['sí', 'no'],
    });
    await until(() => sink.posts.isNotEmpty);
    final card = sink.posts.single;
    expect(card['text'], '¿Sigo?');
    expect(card['alert'], isTrue);
    final answer = (card['actions']! as List).first as Map;
    expect(answer['id'], 'answer');
    expect(answer['choices'], ['sí', 'no']);
    final payload = NotificationActionPayload.tryParse(
      card['actionPayload'] as String,
    )!;
    expect(payload.route, NotificationActionRoute.session);
    expect(payload.requestId, 'c1');
    // The live row says what the turn waits for.
    await until(() => lastText().startsWith('Tiene'));
    expect(lastText(), startsWith('Tiene una pregunta'));
  });

  test('no row while the user is looking at that chat', () async {
    notifications.appInForeground = true;
    notifications.visibleSessionId = 'stored-peer';
    await until(() => sink.cancelled.contains(tag));
    expect(sink.cancelled, contains(tag));
    final posts = sink.live.length;
    await emit('tool.start', {'tool_id': 't9', 'name': 'terminal'});
    await settle();
    expect(sink.live.length, posts);
  });
}

final class _Sink implements RichNotificationSink {
  final live = <Map<String, Object?>>[];
  final cancelled = <String?>[];
  @override
  Future<void> cancel({required int id, String? tag}) async {
    if (id == RichNotificationIds.live) cancelled.add(tag);
  }

  @override
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs = 4000,
    bool onlyIfActive = false,
  }) async {}
  final posts = <Map<String, Object?>>[];
  @override
  Future<bool> postConversation(Map<String, Object?> args) async {
    posts.add(args);
    return true;
  }

  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async =>
      live.add(args);
}
