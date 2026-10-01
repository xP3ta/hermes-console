// Issue #1215 ("sale en bucle el sin conexión cuando sí hay").
//
// Field evidence: with a large conversation open and idle, Console downloaded
// the newest 500 transcript rows (0.8–1.75 MB, ~2 s server time) every ~30 s
// and, around a reconnect, the same 1.75 MB page several times in a few
// seconds. Those reads saturate the phone's connection while /health stays
// healthy. These tests drive the real ChatScreen passive reader through the
// real ApiClient parser against a fake HTTP server and count requests/bytes.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _storedId = 'stored-bandwidth';

/// Durable transcript served like `/api/sessions/{id}/messages` on current
/// Hermes: integer row ids and `order=latest` offsets counted back from the
/// newest row (the endpoint has no `after_row_id`; only `/timeline` does).
/// With [honoursLimit] false it mimics an old gateway that ignores paging and
/// returns the whole transcript without `pagination`.
final class _TranscriptServer {
  _TranscriptServer({int rows = 1000, this.honoursLimit = true}) {
    for (var i = 1; i <= rows; i++) {
      append(i.isOdd ? 'user' : 'assistant');
    }
  }

  /// About 1.7 KB per row: 500 rows ≈ 0.9 MB, like the field transcripts.
  static const rowBytes = 1700;
  final bool honoursLimit;
  Duration latency = Duration.zero;

  /// When true, full pages (not the one-row probe) come back with every row
  /// malformed, like a proxy truncating or rewriting a large body.
  bool corruptFullPages = false;
  final List<Map<String, Object?>> _rows = [];
  final requests = <Uri>[];
  var bytes = 0;

  int get messageReads =>
      requests.where((uri) => uri.path.endsWith('/messages')).length;

  /// Reads that download a real page, as opposed to the one-row tail probe.
  int get heavyReads => requests
      .where(
        (uri) =>
            uri.path.endsWith('/messages') &&
            uri.queryParameters['limit'] != '1',
      )
      .length;

  /// In-place rewrite of the newest row (same durable id), as an edit of the
  /// tip or a display projection change would produce.
  void rewriteNewest(String content) {
    _rows.last = {..._rows.last, 'content': content};
  }

  /// Rewind/compaction shape: the newest rows disappear and new ones (new
  /// ids) take their place, so the visible count can stay the same.
  void replaceNewest(int count, String content) {
    final lastId = _rows.last['id']! as int;
    _rows.removeRange(_rows.length - count, _rows.length);
    for (var i = 1; i <= count; i++) {
      _rows.add({
        'id': lastId + i,
        'session_id': _storedId,
        'role': i.isOdd ? 'user' : 'assistant',
        'content': i == count ? content : 'replacement $i',
        'timestamp': 1790000000 + lastId + i,
      });
    }
  }

  void append(String role, {String? content}) {
    final id = _rows.length + 1;
    _rows.add({
      'id': id,
      'session_id': _storedId,
      'role': role,
      'content': content ?? '$role $id ${'x' * rowBytes}',
      'timestamp': 1790000000 + id,
    });
  }

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final path = request.url.path;
    if (path != '/api/sessions/$_storedId/messages') {
      return http.Response('{"error":"not found"}', 404);
    }
    final query = request.url.queryParameters;
    if (!honoursLimit) {
      final body = jsonEncode({
        'object': 'list',
        'session_id': _storedId,
        'data': _rows,
      });
      bytes += utf8.encode(body).length;
      return http.Response(body, 200);
    }
    final limit = int.parse(query['limit'] ?? '500').clamp(1, 500);
    final offset = int.parse(query['offset'] ?? '0');
    final end = (_rows.length - offset).clamp(0, _rows.length);
    final start = (end - limit).clamp(0, end);
    final page = corruptFullPages && limit > 1
        ? [for (var i = start; i < end; i++) 'corrupt-$i']
        : _rows.sublist(start, end);
    final body = jsonEncode({
      'object': 'list',
      'session_id': _storedId,
      'data': page,
      'pagination': {
        'limit': limit,
        'offset': offset,
        'order': 'latest',
        'returned': page.length,
      },
    });
    bytes += utf8.encode(body).length;
    return http.Response(body, 200);
  });
}

class _IdleGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSessionActivityGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final bool changeEventsAvailable = true;
  bool connected = true;

  void emit(String type) => _events.add(
    TuiGatewayEvent(type: type, sessionId: 'runtime-bw', payload: const {}),
  );

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-bw',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-bw',
    storedSessionId: storedSessionId,
    created: false,
    running: false,
    status: 'idle',
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-bw',
    storedSessionId: _storedId,
    created: true,
  );

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: runtimeSessionId,
    storedSessionId: storedSessionId,
    created: false,
    running: false,
    status: 'idle',
  );

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async => const DesktopActiveSessionList();

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> close() async {
    connected = false;
    if (!_events.isClosed) await _events.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _connection = SavedConnection(
  id: 'bandwidth-conn',
  label: 'Bandwidth',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  kind: InstanceKind.vps,
);

const _session = Session(
  id: _storedId,
  title: 'Large idle chat',
  model: 'hermes-agent',
  source: 'desktop',
  messageCount: 1000,
  isActive: true,
  preview: '',
  startedAt: 0,
);

class _Fixture {
  _Fixture(this.chat, this.gateway, this.activeChats);
  final ActiveChat chat;
  final _IdleGateway gateway;
  final ActiveChatService activeChats;
}

Future<_Fixture> _mount(
  WidgetTester tester,
  _TranscriptServer server, {
  bool attachRuntime = false,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final gateway = _IdleGateway();
  final activeChats = ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  final chat = activeChats.attach(
    connection: _connection,
    sessionId: _session.id,
    sessionTitle: _session.title,
    sessionSnapshot: _session,
    initialStoredSessionId: _storedId,
    api: ApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      apiKey: 'k',
      httpClient: server.client(),
    ),
    desktopGateway: gateway,
    attachDesktopRuntimeOnLoad: false,
    disableForegroundKeepAlive: true,
  );
  // First open: the current authoritative page size.
  await chat.loadMessages(expectedMessageCount: 1000);
  if (attachRuntime) {
    final attached = await chat.ensureDesktopRuntime(
      acquireForExplicitAction: true,
    );
    expect(attached, isTrue);
    expect(chat.desktopRuntimeSessionId, 'runtime-bw');
  }
  await tester.pumpWidget(
    HermesApp(
      connManager: manager,
      appLock: AppLockService(prefs),
      approvalPolicy: ApprovalPolicyService(prefs),
      fontSize: FontSizeService(prefs),
      bridgeManager: BridgeManager(secure, manager),
      sshManager: SshManager(secure, manager),
      sftpTransfers: SftpTransferService(
        SshManager(secure, manager),
        NotificationService(prefs),
      ),
      sshSessions: SshSessionService(SshManager(secure, manager)),
      notifications: NotificationService(prefs),
      activeChats: activeChats,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 4));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 500));
  final context = tester.element(find.byType(Navigator).first);
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => ChatScreen(
        connection: _connection,
        session: _session,
        initialStoredSessionId: chat.serverSessionId,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    identical(fixture0(activeChats), chat),
    isTrue,
    reason: 'ChatScreen must reuse the pre-attached chat',
  );
  return _Fixture(chat, gateway, activeChats);
}

ActiveChat? fixture0(ActiveChatService service) =>
    service.of(_connection.id, _session.id);

Future<void> _dispose(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  fixture.activeChats.dispose();
  await fixture.gateway.close();
}

Future<void> _idle(WidgetTester tester, Duration total) async {
  const step = Duration(seconds: 1);
  for (var elapsed = Duration.zero; elapsed < total; elapsed += step) {
    await tester.pump(step);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final secure = <String, String>{};
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        switch (call.method) {
          case 'read':
            return secure[args['key']];
          case 'write':
            secure[args['key'] as String] = args['value'] as String;
          case 'delete':
            secure.remove(args['key']);
          case 'readAll':
            return Map<String, String>.from(secure);
          case 'containsKey':
            return secure.containsKey(args['key']);
        }
        return null;
      },
    );
    for (final name in [
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/background',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async => call.method == 'isRunningService' ? false : null,
    );
  });

  testWidgets(
    'idle 1000-message chat: passive backstop never re-downloads the page',
    (tester) async {
      final server = _TranscriptServer();
      final fixture = await _mount(tester, server);
      expect(fixture.chat.messages, hasLength(500));
      final readsAfterOpen = server.messageReads;
      final bytesAfterOpen = server.bytes;

      await _idle(tester, const Duration(minutes: 5));

      final reads = server.messageReads - readsAfterOpen;
      final bytes = server.bytes - bytesAfterOpen;
      // ignore: avoid_print
      print('[#1215] idle 5 min: message reads=$reads bytes=$bytes');
      expect(fixture.chat.messages, hasLength(500));
      expect(
        bytes,
        lessThan(64 * 1024),
        reason:
            'an unchanged transcript must be checked with a tiny tail read, '
            'not by downloading the newest 500 rows again',
      );
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'idle chat under a sessions.changed storm from other sessions stays cheap',
    (tester) async {
      // `sessions.changed` is session-less: any agent writing state.db fires
      // it (floored to one per 2 s). The open chat did not change at all.
      final server = _TranscriptServer();
      final fixture = await _mount(tester, server, attachRuntime: true);
      final readsAfterOpen = server.messageReads;
      final bytesAfterOpen = server.bytes;

      for (var second = 0; second < 300; second += 2) {
        fixture.gateway.emit('sessions.changed');
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
      }

      final reads = server.messageReads - readsAfterOpen;
      final bytes = server.bytes - bytesAfterOpen;
      // ignore: avoid_print
      print('[#1215] storm 5 min: message reads=$reads bytes=$bytes');
      expect(fixture.chat.messages, hasLength(500));
      expect(bytes, lessThan(512 * 1024));
      await _dispose(tester, fixture);
    },
  );

  testWidgets('idle backstop picks up a row appended elsewhere exactly once', (
    tester,
  ) async {
    final server = _TranscriptServer();
    final fixture = await _mount(tester, server, attachRuntime: true);
    final heavyAfterOpen = server.heavyReads;

    server.append('user', content: 'Asked from Desktop');
    server.append('assistant', content: 'Answered on Desktop');
    fixture.gateway.emit('sessions.changed');
    await tester.pump();
    await _idle(tester, const Duration(seconds: 3));

    expect(find.text('Answered on Desktop'), findsOneWidget);
    expect(find.text('Asked from Desktop'), findsOneWidget);
    final contents = fixture.chat.messages
        .map((message) => message['content'])
        .toList();
    expect(
      contents.where((content) => content == 'Answered on Desktop'),
      hasLength(1),
    );
    expect(contents.first, 'Answered on Desktop');
    expect(contents[1], 'Asked from Desktop');
    expect(contents[2], startsWith('assistant 1000 '));
    // `/messages` has no keyset cursor on current Hermes: a real change
    // costs exactly one page read, then the tail probe settles again.
    expect(server.heavyReads - heavyAfterOpen, 1);
    await _idle(tester, const Duration(minutes: 2));
    expect(server.heavyReads - heavyAfterOpen, 1);
    await _dispose(tester, fixture);
  });

  testWidgets('an in-place rewrite of the newest row is still picked up', (
    tester,
  ) async {
    final server = _TranscriptServer();
    final fixture = await _mount(tester, server, attachRuntime: true);
    await _idle(tester, const Duration(seconds: 40));
    final heavy = server.heavyReads;

    server.rewriteNewest('Edited tip from Desktop');
    fixture.gateway.emit('sessions.changed');
    await tester.pump();
    await _idle(tester, const Duration(seconds: 3));

    expect(server.heavyReads - heavy, 1);
    expect(fixture.chat.messages.first['content'], 'Edited tip from Desktop');
    expect(fixture.chat.messages, hasLength(500));
    await _dispose(tester, fixture);
  });

  testWidgets('a rewind that keeps the row count is still picked up', (
    tester,
  ) async {
    final server = _TranscriptServer();
    final fixture = await _mount(tester, server, attachRuntime: true);
    await _idle(tester, const Duration(seconds: 40));
    final heavy = server.heavyReads;

    server.replaceNewest(2, 'Rewound answer');
    fixture.gateway.emit('sessions.changed');
    await tester.pump();
    await _idle(tester, const Duration(seconds: 3));

    expect(server.heavyReads - heavy, 1);
    final contents = fixture.chat.messages.map((m) => m['content']).toList();
    expect(contents.first, 'Rewound answer');
    expect(contents[1], 'replacement 1');
    expect(contents.where((c) => '$c'.startsWith('assistant 1000 ')), isEmpty);
    expect(contents.where((c) => '$c'.startsWith('user 999 ')), isEmpty);
    await _dispose(tester, fixture);
  });

  testWidgets('a full read that publishes nothing never confirms the tail', (
    tester,
  ) async {
    final server = _TranscriptServer();
    final fixture = await _mount(tester, server, attachRuntime: true);
    await _idle(tester, const Duration(seconds: 40));

    server.append('assistant', content: 'Reply behind a broken page');
    server.corruptFullPages = true;
    fixture.gateway.emit('sessions.changed');
    await tester.pump();
    await _idle(tester, const Duration(seconds: 3));
    expect(find.text('Reply behind a broken page'), findsNothing);

    // The page heals and another session's write fires the session-less
    // `sessions.changed` again. The open chat's tail is the same one the
    // broken read saw, but that read proved nothing: it must read again.
    server.corruptFullPages = false;
    await _idle(tester, const Duration(seconds: 5));
    fixture.gateway.emit('sessions.changed');
    await tester.pump();
    await _idle(tester, const Duration(seconds: 3));
    expect(
      fixture.chat.messages.first['content'],
      'Reply behind a broken page',
    );
    await _dispose(tester, fixture);
  });

  testWidgets('a local transcript change forces the next full read', (
    tester,
  ) async {
    final server = _TranscriptServer();
    final fixture = await _mount(tester, server, attachRuntime: true);
    await _idle(tester, const Duration(seconds: 40));
    final heavy = server.heavyReads;

    // Local projection diverged (a local edit/rewind, a reconnect merge):
    // the durable tail alone can no longer prove the screen is current.
    fixture.chat.internalMessagesForTesting = fixture.chat.messages
        .skip(1)
        .map(Map<String, dynamic>.from)
        .toList();
    fixture.gateway.emit('sessions.changed');
    await tester.pump();
    await _idle(tester, const Duration(seconds: 3));

    expect(server.heavyReads - heavy, 1);
    expect(
      fixture.chat.messages.first['content'],
      startsWith('assistant 1000'),
    );
    await _dispose(tester, fixture);
  });

  testWidgets(
    'a server that ignores paging still converges without duplicates',
    (tester) async {
      final server = _TranscriptServer(rows: 40, honoursLimit: false);
      final fixture = await _mount(tester, server, attachRuntime: true);

      server.append('assistant', content: 'Legacy appended reply');
      fixture.gateway.emit('sessions.changed');
      await tester.pump();
      await _idle(tester, const Duration(seconds: 3));

      final contents = fixture.chat.messages
          .map((message) => message['content'])
          .toList();
      expect(
        contents.where((content) => content == 'Legacy appended reply'),
        hasLength(1),
      );
      expect(contents.first, 'Legacy appended reply');
      final ids = fixture.chat.messages.map((m) => m['id']).toList();
      expect(ids.toSet(), hasLength(ids.length));
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'a slow 2 s heavy read never overlaps nor bursts the same transcript',
    (tester) async {
      final server = _TranscriptServer();
      final fixture = await _mount(tester, server, attachRuntime: true);
      server.latency = const Duration(seconds: 2);
      server.append('assistant', content: 'Slow durable change');
      final start = server.messageReads;

      for (var i = 0; i < 5; i++) {
        fixture.gateway.emit('sessions.changed');
        await tester.pump(const Duration(milliseconds: 500));
      }
      await _idle(tester, const Duration(seconds: 10));

      final reads = server.messageReads - start;
      // ignore: avoid_print
      print(
        '[#1215] 5 sessions.changed in 2.5 s with 2 s reads: '
        'reads=$reads transport=${fixture.chat.transportStatus.state}',
      );
      expect(reads, lessThanOrEqualTo(2));
      expect(fixture.chat.transportStatus.isConnected, isTrue);
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'a resume after a dropped socket probes the tail instead of re-reading '
    'an unchanged 500-row page, and still picks up a real change',
    (tester) async {
      // Field log: several sockets closed together and reopened; every
      // resume re-downloaded the newest 500 rows of each open chat.
      final server = _TranscriptServer();
      final fixture = await _mount(tester, server, attachRuntime: true);
      // Let the first backstop settle so the burst below is the only traffic.
      await _idle(tester, const Duration(seconds: 2));
      final heavyBefore = server.heavyReads;
      final bytesBefore = server.bytes;

      for (var resume = 0; resume < 3; resume++) {
        expect(await fixture.chat.reconcileAfterResume(), isFalse);
        await tester.pump();
      }
      // ignore: avoid_print
      print(
        '[#1215] 3 resumes unchanged: heavy='
        '${server.heavyReads - heavyBefore} '
        'bytes=${server.bytes - bytesBefore}',
      );
      expect(server.heavyReads - heavyBefore, 0);
      expect(fixture.chat.messages, hasLength(500));

      server.append('assistant', content: 'Written while the socket was down');
      expect(await fixture.chat.reconcileAfterResume(), isTrue);
      await tester.pump();
      expect(server.heavyReads - heavyBefore, 1);
      expect(
        fixture.chat.messages.first['content'],
        'Written while the socket was down',
      );
      // The read that published the change re-arms the probe.
      expect(await fixture.chat.reconcileAfterResume(), isFalse);
      expect(server.heavyReads - heavyBefore, 1);
      await _dispose(tester, fixture);
    },
  );
}
