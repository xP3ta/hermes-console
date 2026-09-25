// Tests del streaming de chat que sobrevive a 2º plano (ActiveChatService /
// ActiveChat). Cubren:
//   1. El ciclo run completo (send → run → tokens → completado) refresca los
//      mensajes desde el servidor y limpia la vigilancia en 2º plano.
//   2. Al arrancar un run se registra la vigilancia en 2º plano (BackgroundWatch
//      en SharedPreferences) para que el isolate del servicio pueda avisar
//      aunque el SO mate el proceso.
//   3. reconcileAfterResume re-sincroniza un turno que quedó a medias mientras
//      la app estaba suspendida, y no toca un chat ya finalizado ni uno vivo.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:hermes_android/core/models/home_widget_snapshot.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/services/attachment_uploader.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/home_widget_publisher.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/utils/chat_turn.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _kWatchKey = 'bg_watch_runs'; // BackgroundWatch._key (privado)
const _kObservedTtftKey = 'active_chat_observed_ttft_v1';

SavedConnection _conn({String id = 'conn-1'}) => SavedConnection(
  id: id,
  label: 'Test',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

class _CapturingRunApi extends ApiClient {
  _CapturingRunApi()
    : super(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('', 500)),
      );

  Duration? streamIdleTimeout;

  @override
  Future<String> startRun({
    required String input,
    String? sessionId,
    String? model,
    List<Map<String, dynamic>>? history,
    String? profile,
  }) async => 'run-watchdog';

  @override
  Future<void> streamRunEvents(
    String runId, {
    String? profile,
    required void Function(Map<String, dynamic> event) onEvent,
    required void Function() onDone,
    required void Function(String error) onError,
    Duration? idleTimeout = const Duration(seconds: 90),
  }) async {
    streamIdleTimeout = idleTimeout;
  }
}

class _StaticWebSocketAuthDashboardClient extends DashboardClient {
  _StaticWebSocketAuthDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'token',
        credential: 'demo-token',
      );
}

class _TeardownTestWebSocketSink implements WebSocketSink {
  _TeardownTestWebSocketSink({required this.blockClose});

  final bool blockClose;
  final Completer<void> closeStarted = Completer<void>();
  final Completer<void> _done = Completer<void>();
  final Completer<void> _blockedClose = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  void add(dynamic data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final _ in stream) {}
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    if (!closeStarted.isCompleted) closeStarted.complete();
    if (blockClose) return _blockedClose.future;
    if (!_done.isCompleted) _done.complete();
    return Future<void>.value();
  }
}

class _TeardownTestWebSocketChannel implements WebSocketChannel {
  _TeardownTestWebSocketChannel({this.readyError, required bool blockTeardown})
    : _sink = _TeardownTestWebSocketSink(blockClose: blockTeardown) {
    _stream = StreamController<dynamic>(
      onCancel: blockTeardown
          ? () {
              if (!cancelStarted.isCompleted) cancelStarted.complete();
              return _blockedCancel.future;
            }
          : null,
    );
  }

  final Object? readyError;
  final Completer<void> cancelStarted = Completer<void>();
  final Completer<void> _blockedCancel = Completer<void>();
  final _TeardownTestWebSocketSink _sink;
  late final StreamController<dynamic> _stream;

  @override
  Future<void> get ready {
    final error = readyError;
    return error == null ? Future<void>.value() : Future<void>.error(error);
  }

  @override
  Stream<dynamic> get stream => _stream.stream;

  @override
  WebSocketSink get sink => _sink;

  void emitGatewayReady() {
    _stream.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
      }),
    );
  }

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// MockClient que simula el gateway: POST /v1/runs, el SSE de eventos y el
/// refetch de mensajes. [events] es el cuerpo SSE servido en /events.
MockClient _gateway({
  required String events,
  required List<Map<String, dynamic>> finalMessages,
  List<String>? hitLog,
  void Function()? beforeEvents,
}) {
  return MockClient((request) async {
    final path = request.url.path;
    hitLog?.add('${request.method} $path');
    if (request.method == 'POST' && path == '/v1/runs') {
      return http.Response(jsonEncode({'run_id': 'run_1'}), 200);
    }
    if (request.method == 'GET' && path == '/v1/runs/run_1/events') {
      beforeEvents?.call();
      return http.Response(
        events,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    if (request.method == 'POST' && path == '/v1/runs/run_1/approval') {
      return http.Response(jsonEncode({'ok': true}), 200);
    }
    if (request.method == 'GET' && path == '/api/sessions/sess-1/messages') {
      return http.Response(
        jsonEncode({'data': finalMessages}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('not found', 404);
  });
}

String _sse(List<Map<String, dynamic>> frames) =>
    frames.map((f) => 'data: ${jsonEncode(f)}\n\n').join();

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

class _ApprovalRaceClient extends http.BaseClient {
  final events = StreamController<List<int>>();
  final releaseA = Completer<void>();
  final releaseB = Completer<void>();
  final approvalBodies = <Map<String, dynamic>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (request.method == 'POST' && path == '/v1/runs') {
      return _response({'run_id': 'run_1'});
    }
    if (request.method == 'GET' && path == '/v1/runs/run_1/events') {
      return http.StreamedResponse(
        events.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    if (request.method == 'POST' && path == '/v1/runs/run_1/approval') {
      final body =
          jsonDecode((request as http.Request).body) as Map<String, dynamic>;
      approvalBodies.add(body);
      if (body['request_id'] == 'request-a') await releaseA.future;
      if (body['request_id'] == 'request-b') await releaseB.future;
      return _response({'ok': true});
    }
    return _response({}, statusCode: 404);
  }

  http.StreamedResponse _response(
    Map<String, dynamic> body, {
    int statusCode = 200,
  }) => http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
    statusCode,
    headers: {'content-type': 'application/json'},
  );

  void emit(Map<String, dynamic> event) {
    events.add(utf8.encode('data: ${jsonEncode(event)}\n\n'));
  }

  @override
  void close() {
    events.close();
    super.close();
  }
}

class _WidgetRecordingStore implements HomeWidgetStore {
  final values = <String, Object?>{};
  final snapshots = <Map<String, Object?>>[];

  @override
  Future<Object?> read(String key) async => values[key];

  @override
  Future<void> write(String key, Object? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> requestUpdate() async {
    snapshots.add(Map<String, Object?>.from(values));
  }
}

class _AttachmentMemoryOutbox implements TurnOutboxPersistence {
  _AttachmentMemoryOutbox({this.eventLog, this.failOnSaveCall});

  final List<String>? eventLog;
  final int? failOnSaveCall;
  final List<PreparedTurn> writes = [];
  final List<PreparedTurn> deletes = [];
  int saveCalls = 0;

  @override
  Future<void> save(PreparedTurn turn) async {
    saveCalls++;
    writes.add(turn);
    final attachmentState = turn.attachments.isEmpty
        ? 'none'
        : turn.attachments.first.uploadState.name;
    eventLog?.add('persist:${turn.state.name}:$attachmentState');
    if (saveCalls == failOnSaveCall) {
      throw StateError('test persistence failure');
    }
  }

  @override
  Future<void> delete(PreparedTurn turn) async => deletes.add(turn);
}

class _AttachmentDesktopGateway
    implements HermesDesktopGateway, HermesDesktopAttachmentGateway {
  _AttachmentDesktopGateway({this.eventLog});

  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<String>? eventLog;
  String runtimeId = 'runtime-a';
  int fileAttachCalls = 0;
  int imageAttachCalls = 0;
  int submitCalls = 0;
  bool failNextSubmit = false;
  Completer<void>? attachGate;
  int? gateOnImageAttachCall;
  final List<(String, String)> detachedImages = [];

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: runtimeId,
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopAttachmentResult> attachFileBytes(
    String runtimeSessionId, {
    required String filename,
    required String mimeType,
    required String contentBase64,
  }) async {
    fileAttachCalls++;
    eventLog?.add('rpc:file.attach');
    await attachGate?.future;
    return DesktopAttachmentResult(
      path: '/remote/$filename',
      refText: '@file:.hermes/$filename',
    );
  }

  @override
  Future<DesktopAttachmentResult> attachImageBytes(
    String runtimeSessionId, {
    required String filename,
    required String contentBase64,
  }) async {
    imageAttachCalls++;
    eventLog?.add('rpc:image.attach_bytes');
    if (attachGate != null &&
        (gateOnImageAttachCall == null ||
            gateOnImageAttachCall == imageAttachCalls)) {
      await attachGate!.future;
    }
    return DesktopAttachmentResult(path: '/remote/$filename');
  }

  @override
  Future<void> detachImage(String runtimeSessionId, String path) async {
    eventLog?.add('rpc:image.detach');
    detachedImages.add((runtimeSessionId, path));
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submitCalls++;
    eventLog?.add('rpc:prompt.submit');
    if (failNextSubmit) {
      failNextSubmit = false;
      throw const TuiGatewayRpcError(
        'prompt.submit',
        'test failure',
        code: 500,
      );
    }
  }

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

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    _events.add(
      TuiGatewayEvent(type: type, sessionId: runtimeId, payload: payload),
    );
  }

  @override
  Future<void> close() => _events.close();
}

class _DelayedProcessGateway extends _AttachmentDesktopGateway
    implements HermesDesktopControlGateway {
  Completer<AgentCenterSnapshot> processSnapshot = Completer();
  bool connected = true;

  @override
  bool get isConnected => connected;

  @override
  Future<AgentCenterSnapshot> agentCenterSnapshot({
    String runtimeSessionId = '',
  }) => processSnapshot.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NativeSessionSplitGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSessionActivityGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<String> calls = [];
  final List<({String runtimeId, String text})> submissions = [];
  int interrupts = 0;
  DesktopSessionSnapshot? resumeSnapshot;
  DesktopActiveSessionList activeList = const DesktopActiveSessionList();

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    calls.add('resume-fallback:$storedSessionId');
    throw StateError('legacy resume fallback must not be used');
  }

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    calls.add('resume:$storedSessionId');
    return resumeSnapshot ??
        DesktopSessionBinding(
          runtimeSessionId: 'runtime-$storedSessionId',
          storedSessionId: storedSessionId,
          created: false,
        );
  }

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async =>
      resumeSnapshot ??
      DesktopSessionBinding(
        runtimeSessionId: runtimeSessionId,
        storedSessionId: storedSessionId,
        created: false,
      );

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async => activeList;

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    calls.add('create');
    return const DesktopSessionBinding(
      runtimeSessionId: 'runtime-created-b',
      storedSessionId: 'stored-created-b',
      created: true,
    );
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    calls.add('submit:$runtimeSessionId');
    submissions.add((runtimeId: runtimeSessionId, text: text));
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interrupts += 1;
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    final runtimeId =
        resumeSnapshot?.runtimeSessionId ?? 'runtime-stored-observer';
    _events.add(
      TuiGatewayEvent(type: type, sessionId: runtimeId, payload: payload),
    );
  }

  @override
  Future<void> close() => _events.close();
}

class _AuthWarmGateway extends _AttachmentDesktopGateway {
  Object? connectError;
  bool connected = false;
  final List<Future<void> Function()> connectAttempts = [];

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async {
    if (connectAttempts.isNotEmpty) {
      await connectAttempts.removeAt(0)();
      connected = true;
      return;
    }
    final error = connectError;
    if (error != null) throw error;
    connected = true;
  }
}

class _AttachmentBridgeClient extends BridgeClient {
  _AttachmentBridgeClient()
    : super(baseUrl: 'http://127.0.0.1:9131', token: 'bridge-token');

  int uploadCalls = 0;
  int streamCalls = 0;
  int fallbackChatCalls = 0;
  final List<String> chatProfiles = [];
  BridgeException? nextStreamFailure;
  Completer<void>? uploadGate;

  @override
  Future<String> uploadAttachment(
    File file, {
    required String filename,
    String mimeType = 'application/octet-stream',
    Duration timeout = const Duration(seconds: 45),
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    uploadCalls++;
    await uploadGate?.future;
    return '/bridge/$filename';
  }

  @override
  Stream<String> chatStream(
    String prompt, {
    List<Map<String, dynamic>> history = const [],
    List<String> attachmentPaths = const [],
    Duration timeout = const Duration(minutes: 5),
    String profile = '',
  }) async* {
    streamCalls++;
    chatProfiles.add(profile);
    final failure = nextStreamFailure;
    if (failure != null) {
      nextStreamFailure = null;
      throw failure;
    }
    yield 'respuesta';
  }

  @override
  Future<String> chat(
    String prompt, {
    List<Map<String, dynamic>> history = const [],
    List<String> attachmentPaths = const [],
    Duration timeout = const Duration(minutes: 5),
    String profile = '',
  }) async {
    fallbackChatCalls++;
    chatProfiles.add(profile);
    return 'respuesta';
  }

  @override
  void close() {}
}

PreparedTurn _attachmentTurn(AttachmentDraft attachment) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return PreparedTurn(
    connectionId: 'conn-attachment',
    sessionId: 'sess-attachment',
    clientTurnId: 'turn-attachment',
    createdAtMs: now,
    updatedAtMs: now,
    text: 'revisa',
    attachments: [attachment],
    model: 'hermes-agent',
    profile: '',
  );
}

ActiveChat _attachmentChat(_AttachmentDesktopGateway gateway) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: _conn(id: 'conn-attachment'),
  sessionId: 'sess-attachment',
  sessionTitle: 'Adjuntos',
  notifications: null,
  onTerminal: () {},
  desktopGateway: gateway,
);

bool _noActivityHint(ActiveChat chat) => chat.noActivityHint;

bool _hasAssistantError(ActiveChat chat) =>
    chat.messages.any((message) => message['role'] == 'assistant_error');

Future<ActiveChat> _startWatchdogTurn(
  WidgetTester tester,
  _AttachmentDesktopGateway gateway,
) async {
  final chat = _attachmentChat(gateway)..smoothStreaming = false;
  addTearDown(chat.dispose);
  expect(
    await chat.send(
      fullText: 'trabaja en silencio',
      model: 'hermes-agent',
      history: const [],
    ),
    isTrue,
  );
  await tester.pump();
  expect(chat.isStreaming, isTrue);
  return chat;
}

Future<AttachmentDraft> _privateTestAttachment(
  Directory directory, {
  required String localId,
  AttachmentType type = AttachmentType.document,
}) async {
  final isImage = type == AttachmentType.image;
  final name = isImage ? '$localId.png' : '$localId.pdf';
  final file = File('${directory.path}/$name');
  await file.writeAsBytes(const [1, 2, 3]);
  return AttachmentDraft(
    localId: localId,
    type: type,
    name: name,
    mimeType: isImage ? 'image/png' : 'application/pdf',
    sizeBytes: 3,
    localPath: file.path,
  );
}

Session _widgetSession() => const Session(
  id: 'sess-1',
  title: 'Auditoría widget',
  model: 'gpt-5.5',
  source: 'mobile',
  messageCount: 4,
  isActive: false,
  preview: '',
  startedAt: 1700000000,
  updatedAt: 1700000010,
  inputTokens: 1200,
  outputTokens: 300,
  cacheReadTokens: 500,
  cacheWriteTokens: 50,
);

void main() {
  group('desktop activity watchdog', () {
    testWidgets('B1 a 120 second foreground tool does not fail the turn', (
      tester,
    ) async {
      final gateway = _AttachmentDesktopGateway();
      final chat = await _startWatchdogTurn(tester, gateway);

      gateway.emit('tool.start', const {'name': 'execute_code'});
      await tester.pump();
      await tester.pump(const Duration(seconds: 120));

      expect(chat.isStreaming, isTrue);
      expect(chat.state, isNot(ChatPipelineState.failed));
      expect(_hasAssistantError(chat), isFalse);
      chat.dispose();
    });

    testWidgets('B2 five minutes of silence shows a non-terminal hint', (
      tester,
    ) async {
      final gateway = _AttachmentDesktopGateway();
      final chat = await _startWatchdogTurn(tester, gateway);

      await tester.pump(const Duration(minutes: 5) - Duration(milliseconds: 1));
      expect(_noActivityHint(chat), isFalse);
      await tester.pump(const Duration(milliseconds: 1));

      expect(_noActivityHint(chat), isTrue);
      expect(chat.isStreaming, isTrue);
      expect(chat.state, isNot(ChatPipelineState.failed));
      expect(_hasAssistantError(chat), isFalse);
    });

    testWidgets(
      'B3 runtime activity clears the hint and completion stays normal',
      (tester) async {
        final gateway = _AttachmentDesktopGateway();
        final chat = await _startWatchdogTurn(tester, gateway);

        await tester.pump(const Duration(minutes: 5));
        expect(_noActivityHint(chat), isTrue);

        gateway.emit('status.update', const {'text': 'working'});
        await tester.pump();
        expect(_noActivityHint(chat), isFalse);

        gateway.emit('message.complete', const {'text': 'terminado'});
        await tester.pump();
        expect(chat.state, ChatPipelineState.completed);
        expect(_hasAssistantError(chat), isFalse);
        chat.dispose();
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets('B4 a post-first-token stall is still watched', (tester) async {
      final gateway = _AttachmentDesktopGateway();
      final chat = await _startWatchdogTurn(tester, gateway);

      gateway.emit('message.delta', const {'text': 'inicio'});
      await tester.pump(const Duration(milliseconds: 40));
      expect(chat.state, ChatPipelineState.streaming);

      await tester.pump(const Duration(minutes: 5));

      expect(_noActivityHint(chat), isTrue);
      expect(chat.isStreaming, isTrue);
      expect(chat.state, isNot(ChatPipelineState.failed));
    });

    testWidgets('B5 a ten minute tool remains a live turn with a hint', (
      tester,
    ) async {
      final gateway = _AttachmentDesktopGateway();
      final chat = await _startWatchdogTurn(tester, gateway);

      gateway.emit('tool.start', const {'name': 'execute_code'});
      await tester.pump();
      await tester.pump(const Duration(minutes: 10));

      expect(_noActivityHint(chat), isTrue);
      expect(chat.isStreaming, isTrue);
      expect(chat.state, isNot(ChatPipelineState.failed));
      expect(_hasAssistantError(chat), isFalse);
    });

    testWidgets('B6 silence without tool events only shows the hint', (
      tester,
    ) async {
      final gateway = _AttachmentDesktopGateway();
      final chat = await _startWatchdogTurn(tester, gateway);

      await tester.pump(const Duration(minutes: 10));

      expect(_noActivityHint(chat), isTrue);
      expect(chat.isStreaming, isTrue);
      expect(chat.state, isNot(ChatPipelineState.failed));
      expect(_hasAssistantError(chat), isFalse);
    });

    testWidgets('transport pong does not clear model inactivity', (
      tester,
    ) async {
      final gateway = _AttachmentDesktopGateway();
      final chat = await _startWatchdogTurn(tester, gateway);

      await tester.pump(const Duration(minutes: 5));
      expect(_noActivityHint(chat), isTrue);

      gateway.emit('gateway.pong');
      await tester.pump();

      expect(_noActivityHint(chat), isTrue);
      expect(chat.isStreaming, isTrue);
    });

    for (final terminal in const [
      ('B7 message.complete error remains terminal', 'message.complete'),
      ('B7 standalone error remains terminal', 'error'),
    ]) {
      testWidgets(terminal.$1, (tester) async {
        final gateway = _AttachmentDesktopGateway();
        final chat = await _startWatchdogTurn(tester, gateway);

        gateway.emit(terminal.$2, const {
          'status': 'error',
          'message': 'server rejected the turn',
        });
        await tester.pump();

        expect(chat.state, ChatPipelineState.failed);
        expect(chat.isStreaming, isFalse);
        expect(_hasAssistantError(chat), isTrue);
      });
    }
  });

  test(
    'compacted terminal groups skip identities removed in the same pass',
    () {
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-multi-compaction'),
        sessionId: 'sess-multi-compaction',
        sessionTitle: 'Multi compaction',
        notifications: null,
        onTerminal: () {},
      );
      addTearDown(chat.dispose);
      const newerProjection = 'terminal-newer';
      const olderProjection = 'terminal-older';
      final candidate = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': 'newer local answer',
          '_localTerminalProjectionId': newerProjection,
        },
        {
          'message_id': 'newer-removed-user',
          'role': 'user',
          'content': 'newer local prompt',
          '_localTerminalProjectionId': newerProjection,
        },
        {
          'role': 'assistant',
          'content': 'older local answer',
          '_localTerminalProjectionId': olderProjection,
        },
        {
          'message_id': 'older-removed-user',
          'role': 'user',
          'content': 'older local prompt',
          '_localTerminalProjectionId': olderProjection,
        },
        {
          'message_id': 'confirmed-older-anchor',
          'role': 'assistant',
          'content': 'confirmed historical answer',
        },
      ];

      final compacted = chat
          .pruneCompactedTerminalRowsForTesting(candidate, const [
            TranscriptMessageIdentity(messageId: 'newer-removed-user'),
            TranscriptMessageIdentity(messageId: 'older-removed-user'),
          ]);

      expect(
        compacted.where(
          (message) => message['_localCompactedTerminalProjection'] != null,
        ),
        hasLength(4),
      );
      expect(
        compacted
            .take(4)
            .every(
              (message) =>
                  canonicalTranscriptIdentity(message) == null &&
                  message['_localCompactedTerminalAnchorMessageId'] ==
                      'confirmed-older-anchor',
            ),
        isTrue,
      );

      final merged = chat.mergeCompactedTerminalRowsForTesting(
        compacted.take(4).toList(growable: false),
        const [
          {
            'message_id': 'later-assistant',
            'role': 'assistant',
            'content': 'later durable answer',
          },
          {
            'message_id': 'later-user',
            'role': 'user',
            'content': 'later durable prompt',
          },
          {
            'message_id': 'confirmed-older-anchor',
            'role': 'assistant',
            'content': 'confirmed historical answer',
          },
        ],
      );
      expect(merged.map((message) => message['content']), const [
        'later durable answer',
        'later durable prompt',
        'newer local answer',
        'newer local prompt',
        'older local answer',
        'older local prompt',
        'confirmed historical answer',
      ]);
    },
  );

  test(
    'passive REST replaces anchored inflight user with durable identity',
    () async {
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-passive-inflight-user'),
        sessionId: 'sess-passive-inflight-user',
        sessionTitle: 'Passive inflight replacement',
        notifications: null,
        onTerminal: () {},
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'older-anchor',
            'role': 'assistant',
            'content': 'older terminal',
          },
          {
            'message_id': 'remote-durable-user',
            'role': 'user',
            'content': 'same remote turn',
          },
        ],
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = const [
        {
          'role': 'user',
          'content': 'same remote turn',
          '_desktopSnapshotKind': 'inflight',
          '_desktopSnapshotKey': 'user-inflight-runtime-remote',
        },
        {
          'message_id': 'older-anchor',
          'role': 'assistant',
          'content': 'older terminal',
        },
      ];

      await chat.loadMessages(passiveOnly: true);

      expect(
        chat.messages.where(
          (message) => message['content'] == 'same remote turn',
        ),
        hasLength(1),
      );
      expect(chat.messages.first['message_id'], 'remote-durable-user');
      expect(chat.messages.first['_desktopSnapshotKind'], isNull);
    },
  );

  test(
    'terminal REST replaces live user when its first durable anchor is that user',
    () async {
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-terminal-inflight-user'),
        sessionId: 'sess-terminal-inflight-user',
        sessionTitle: 'Terminal inflight replacement',
        notifications: null,
        onTerminal: () {},
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'older-anchor',
            'role': 'assistant',
            'content': 'older terminal',
          },
          {
            'message_id': 'remote-durable-user',
            'role': 'user',
            'content': 'same remote turn',
          },
          {
            'message_id': 'remote-durable-assistant',
            'role': 'assistant',
            'content': 'remote terminal',
          },
        ],
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = const [
        {'role': 'assistant', 'content': 'remote terminal', '_pipeline': true},
        {
          'role': 'user',
          'content': 'same remote turn',
          '_desktopSnapshotKind': 'inflight',
          '_desktopSnapshotKey': 'user-inflight-runtime-remote',
        },
        {
          'message_id': 'remote-durable-user',
          'role': 'user',
          'content': 'same remote turn',
        },
        {
          'message_id': 'older-anchor',
          'role': 'assistant',
          'content': 'older terminal',
        },
      ];

      await chat.loadMessages(passiveOnly: true);

      expect(
        chat.messages.where(
          (message) => message['content'] == 'same remote turn',
        ),
        hasLength(1),
      );
      expect(
        chat.messages.singleWhere(
          (message) => message['content'] == 'same remote turn',
        )['message_id'],
        'remote-durable-user',
      );
    },
  );

  test(
    'message.complete removes live user already represented by durable tail',
    () async {
      final gateway = _AttachmentDesktopGateway();
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-terminal-live-user'),
        sessionId: 'sess-terminal-live-user',
        sessionTitle: 'Terminal live user',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
        terminalReconcileBudget: Duration.zero,
      )..smoothStreaming = false;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      expect(
        await chat.send(
          fullText: 'same remote turn',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      chat.internalMessagesForTesting = const [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {'role': 'user', 'content': 'same remote turn'},
        {
          'message_id': 'remote-durable-user',
          'role': 'user',
          'content': 'same remote turn',
        },
        {
          'message_id': 'older-anchor',
          'role': 'assistant',
          'content': 'older terminal',
        },
      ];
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );

      gateway.emit('message.complete', const {'text': 'remote terminal'});
      await done.timeout(const Duration(seconds: 1));

      expect(
        chat.messages.where(
          (message) => message['content'] == 'same remote turn',
        ),
        hasLength(1),
      );
      expect(
        chat.messages.singleWhere(
          (message) => message['content'] == 'same remote turn',
        )['message_id'],
        'remote-durable-user',
      );
    },
  );

  test(
    'message.complete uses pre-submit boundary for physical terminal pair',
    () async {
      final gateway = _AttachmentDesktopGateway();
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-terminal-physical-pair'),
        sessionId: 'sess-terminal-physical-pair',
        sessionTitle: 'Terminal physical pair',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
        terminalReconcileBudget: Duration.zero,
      )..smoothStreaming = false;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      chat.internalMessagesForTesting = const [
        {
          'message_id': 'prior-durable-assistant',
          'role': 'assistant',
          'content': 'prior terminal',
        },
        {
          'message_id': 'prior-durable-user',
          'role': 'user',
          'content': 'prior prompt',
        },
      ];
      expect(
        await chat.send(
          fullText: 'same remote turn',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      // Exact newest-first shape observed on the Pixel at terminal closure:
      // live assistant + live user + current durable assistant/user + prior tail.
      chat.internalMessagesForTesting = const [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {
          'role': 'user',
          'content': 'same remote turn',
          '_desktopSnapshotKind': 'inflight',
          '_desktopSnapshotKey': 'user-inflight-runtime-current',
        },
        {
          'message_id': 'current-durable-assistant',
          'role': 'assistant',
          'content': 'current terminal',
        },
        {
          'message_id': 'current-durable-user',
          'role': 'user',
          'content': 'same remote turn',
        },
        {
          'message_id': 'prior-durable-assistant',
          'role': 'assistant',
          'content': 'prior terminal',
        },
        {
          'message_id': 'prior-durable-user',
          'role': 'user',
          'content': 'prior prompt',
        },
      ];
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );

      gateway.emit('message.complete', const {'text': 'current terminal'});
      await done.timeout(const Duration(seconds: 1));

      final currentUsers = chat.messages.where(
        (message) => message['content'] == 'same remote turn',
      );
      expect(currentUsers, hasLength(1));
      expect(currentUsers.single['message_id'], 'current-durable-user');
    },
  );

  test(
    'passive observer settles physical terminal pair from busy-edge boundary',
    () async {
      final gateway = _NativeSessionSplitGateway()
        ..activeList = const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-stored-observer',
              storedSessionId: 'stored-observer',
              status: 'working',
            ),
          ],
        );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-terminal-observer-pair'),
        sessionId: 'stored-observer',
        initialStoredSessionId: 'stored-observer',
        sessionTitle: 'Terminal observer pair',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      chat.internalMessagesForTesting = const [
        {
          'message_id': 'prior-durable-assistant',
          'role': 'assistant',
          'content': 'prior terminal',
        },
        {
          'message_id': 'prior-durable-user',
          'role': 'user',
          'content': 'prior prompt',
        },
      ];

      await chat.refreshPassiveRemoteActivity();
      expect(chat.hasAuthoritativePassiveRemoteActivity, isTrue);

      // Exact newest-first terminal ordering observed on the Pixel observer.
      chat.internalMessagesForTesting = const [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {
          'role': 'user',
          'content': 'same remote turn',
          '_desktopSnapshotKind': 'inflight',
          '_desktopSnapshotKey': 'user-inflight-runtime-stored-observer',
        },
        {
          'message_id': 'current-durable-assistant',
          'role': 'assistant',
          'content': 'current terminal',
        },
        {
          'message_id': 'current-durable-user',
          'role': 'user',
          'content': 'same remote turn',
        },
        {
          'message_id': 'prior-durable-assistant',
          'role': 'assistant',
          'content': 'prior terminal',
        },
        {
          'message_id': 'prior-durable-user',
          'role': 'user',
          'content': 'prior prompt',
        },
      ];

      chat.settleLiveUsersAlreadyRepresentedByDurableTailForTesting();

      final currentUsers = chat.messages.where(
        (message) => message['content'] == 'same remote turn',
      );
      expect(currentUsers, hasLength(1));
      expect(currentUsers.single['message_id'], 'current-durable-user');
    },
  );

  test(
    'passive REST removes live user after boundary before terminal event',
    () async {
      final gateway = _NativeSessionSplitGateway()
        ..activeList = const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-rest-boundary',
              storedSessionId: 'stored-rest-boundary',
              status: 'working',
            ),
          ],
        );
      const refreshed = <Map<String, dynamic>>[
        {
          'message_id': 'prior-durable-user',
          'role': 'user',
          'content': 'prior prompt',
        },
        {
          'message_id': 'prior-durable-assistant',
          'role': 'assistant',
          'content': 'prior terminal',
        },
        {
          'message_id': 'current-durable-user',
          'role': 'user',
          'content': 'same remote turn',
        },
      ];
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-rest-boundary'),
        sessionId: 'sess-rest-boundary',
        initialStoredSessionId: 'stored-rest-boundary',
        sessionProfile: 'default',
        sessionTitle: 'REST boundary',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
        storedMessageLoader: (_, _) async => refreshed,
        terminalReconcileBudget: Duration.zero,
      );
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      chat.internalMessagesForTesting = const [
        {
          'message_id': 'prior-durable-assistant',
          'role': 'assistant',
          'content': 'prior terminal',
        },
        {
          'message_id': 'prior-durable-user',
          'role': 'user',
          'content': 'prior prompt',
        },
      ];
      await chat.refreshPassiveRemoteActivity();
      chat.internalMessagesForTesting = const [
        {
          'role': 'user',
          'content': 'same remote turn',
          '_desktopSnapshotKind': 'inflight',
        },
        {
          'message_id': 'current-durable-user',
          'role': 'user',
          'content': 'same remote turn',
        },
        {
          'message_id': 'prior-durable-assistant',
          'role': 'assistant',
          'content': 'prior terminal',
        },
        {
          'message_id': 'prior-durable-user',
          'role': 'user',
          'content': 'prior prompt',
        },
      ];

      await chat.loadMessages(passiveOnly: true);

      final currentUsers = chat.messages.where(
        (message) => message['content'] == 'same remote turn',
      );
      expect(currentUsers, hasLength(1));
      expect(currentUsers.single['message_id'], 'current-durable-user');
    },
  );

  test(
    'message.complete preserves legitimate equal resend across durable boundary',
    () async {
      final gateway = _AttachmentDesktopGateway();
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-terminal-equal-resend'),
        sessionId: 'sess-terminal-equal-resend',
        sessionTitle: 'Terminal equal resend',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
        terminalReconcileBudget: Duration.zero,
      )..smoothStreaming = false;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      chat.internalMessagesForTesting = const [
        {
          'message_id': 'prior-durable-assistant',
          'role': 'assistant',
          'content': 'prior terminal',
        },
        {
          'message_id': 'prior-durable-user',
          'role': 'user',
          'content': 'same remote turn',
        },
      ];
      expect(
        await chat.send(
          fullText: 'same remote turn',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      chat.internalMessagesForTesting = const [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {
          'role': 'user',
          'content': 'same remote turn',
          '_desktopSnapshotKind': 'inflight',
          '_desktopSnapshotKey': 'user-inflight-runtime-current',
        },
        {
          'message_id': 'current-durable-assistant',
          'role': 'assistant',
          'content': 'current terminal',
        },
        {
          'message_id': 'current-durable-user',
          'role': 'user',
          'content': 'same remote turn',
        },
        {
          'message_id': 'prior-durable-assistant',
          'role': 'assistant',
          'content': 'prior terminal',
        },
        {
          'message_id': 'prior-durable-user',
          'role': 'user',
          'content': 'same remote turn',
        },
      ];
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );

      gateway.emit('message.complete', const {'text': 'current terminal'});
      await done.timeout(const Duration(seconds: 1));

      expect(
        chat.messages.where(
          (message) => message['content'] == 'same remote turn',
        ),
        hasLength(2),
      );
    },
  );

  test('known-missing flag cannot cross a disallowed boundary capture', () {
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: _conn(id: 'conn-known-missing-boundary'),
      sessionId: 'draft-known-missing-boundary',
      sessionTitle: 'Known missing boundary',
      notifications: null,
      onTerminal: () {},
    );
    addTearDown(chat.dispose);
    chat.markStoredSessionMissing();
    expect(chat.storedSessionKnownMissing, isTrue);
    chat.internalMessagesForTesting = const [
      {
        'role': 'user',
        'content': 'queued current turn',
        '_desktopSnapshotKind': 'inflight',
        '_desktopSnapshotKey': 'queued-current-live',
      },
      {
        'message_id': 'unrelated-durable-user',
        'role': 'user',
        'content': 'queued current turn',
      },
    ];

    chat.captureActiveTurnTranscriptBoundaryForTesting(
      allowExistingTranscript: false,
    );
    expect(
      chat.liveUserProjectionIndexesAfterActiveTurnBoundaryForTesting(),
      isEmpty,
    );
  });

  test(
    'stale passive boundary is not rebased after a newer durable user lands',
    () async {
      final gateway = _NativeSessionSplitGateway()
        ..activeList = const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-stale-passive',
              storedSessionId: 'stored-stale-passive',
              status: 'working',
            ),
          ],
        );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-stale-passive'),
        sessionId: 'stored-stale-passive',
        initialStoredSessionId: 'stored-stale-passive',
        sessionTitle: 'Stale passive boundary',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      chat.internalMessagesForTesting = const [
        {
          'message_id': 'older-durable-assistant',
          'role': 'assistant',
          'content': 'older terminal',
        },
        {
          'message_id': 'older-durable-user',
          'role': 'user',
          'content': 'older prompt',
        },
      ];
      await chat.refreshPassiveRemoteActivity();

      chat.internalMessagesForTesting = const [
        {
          'message_id': 'turn-a-durable-user',
          'role': 'user',
          'content': 'same repeated prompt',
        },
        {
          'message_id': 'older-durable-assistant',
          'role': 'assistant',
          'content': 'older terminal',
        },
        {
          'message_id': 'older-durable-user',
          'role': 'user',
          'content': 'older prompt',
        },
      ];
      chat.beginExternallyObservedDesktopTurnForTesting(
        const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stale-passive',
          storedSessionId: 'stored-stale-passive',
          created: false,
          running: true,
          status: 'working',
        ),
      );
      chat.internalMessagesForTesting = const [
        {
          'role': 'user',
          'content': 'same repeated prompt',
          '_desktopSnapshotKind': 'inflight',
          '_desktopSnapshotKey': 'turn-b-live-user',
        },
        {
          'message_id': 'turn-a-durable-user',
          'role': 'user',
          'content': 'same repeated prompt',
        },
        {
          'message_id': 'older-durable-user',
          'role': 'user',
          'content': 'older prompt',
        },
      ];

      expect(
        chat.liveUserProjectionIndexesAfterActiveTurnBoundaryForTesting(),
        isEmpty,
      );
    },
  );

  test('ambiguous boundary alias claim fails closed', () async {
    final gateway = _NativeSessionSplitGateway()
      ..activeList = const DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-ambiguous-boundary',
            storedSessionId: 'stored-ambiguous-boundary',
            status: 'working',
          ),
        ],
      );
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: _conn(id: 'conn-ambiguous-boundary'),
      sessionId: 'stored-ambiguous-boundary',
      initialStoredSessionId: 'stored-ambiguous-boundary',
      sessionTitle: 'Ambiguous boundary',
      notifications: null,
      onTerminal: () {},
      desktopGateway: gateway,
    );
    addTearDown(chat.dispose);
    addTearDown(gateway.close);
    chat.internalMessagesForTesting = const [
      {
        'message_id': 'prior-boundary-user',
        'role': 'user',
        'content': 'prior prompt',
      },
    ];
    await chat.refreshPassiveRemoteActivity();
    chat.internalMessagesForTesting = const [
      {
        'role': 'user',
        'content': 'current prompt',
        '_desktopSnapshotKind': 'inflight',
        '_desktopSnapshotKey': 'current-live-user',
      },
      {
        'message_id': 'current-durable-user',
        'role': 'user',
        'content': 'current prompt',
      },
      {
        'message_id': 'prior-boundary-user',
        '_row_id': 'conflicting-row-id',
        'role': 'assistant',
        'content': 'ambiguous claimant',
      },
      {
        'message_id': 'prior-boundary-user',
        'role': 'user',
        'content': 'prior prompt',
      },
    ];

    expect(
      chat.liveUserProjectionIndexesAfterActiveTurnBoundaryForTesting(),
      isEmpty,
    );
  });

  test(
    'passive REST never deduplicates equal text without exact durable anchor',
    () async {
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-passive-unproven-user'),
        sessionId: 'sess-passive-unproven-user',
        sessionTitle: 'Passive fail closed',
        notifications: null,
        onTerminal: () {},
        storedMessageLoader: (_, _) async => const [
          {
            'message_id': 'different-anchor',
            'role': 'assistant',
            'content': 'different terminal',
          },
          {
            'message_id': 'other-durable-user',
            'role': 'user',
            'content': 'repeated prompt',
          },
        ],
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = const [
        {
          'role': 'user',
          'content': 'repeated prompt',
          '_desktopSnapshotKind': 'inflight',
          '_desktopSnapshotKey': 'user-inflight-unproven',
        },
        {
          'message_id': 'original-anchor',
          'role': 'assistant',
          'content': 'original terminal',
        },
      ];

      await chat.loadMessages(passiveOnly: true);

      expect(
        chat.messages.where(
          (message) => message['content'] == 'repeated prompt',
        ),
        hasLength(2),
      );
    },
  );

  test(
    'Desktop warm-up publishes auth-required and clears only after recovery',
    () async {
      final gateway = _AuthWarmGateway()
        ..connectError = const DashboardAuthException(
          DashboardAuthFailureCode.loginRequired,
        );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-dashboard-auth-warm'),
        sessionId: 'sess-dashboard-auth-warm',
        sessionTitle: 'Auth warm-up',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);
      final events = <ActiveChatEvent>[];
      final subscription = chat.changes.listen(events.add);
      addTearDown(subscription.cancel);
      chat.internalMessagesForTesting = [
        {'role': 'assistant', 'content': 'durable REST transcript'},
      ];

      await chat.warmDesktopGateway();
      await Future<void>.delayed(Duration.zero);

      expect(chat.dashboardAuthRequired, isTrue);
      expect(chat.messages.single['content'], 'durable REST transcript');

      gateway.connectError = const SocketException('temporary outage');
      await chat.warmDesktopGateway();
      expect(
        chat.dashboardAuthRequired,
        isTrue,
        reason: 'only a successful reconnect proves auth recovered',
      );

      gateway.connectError = null;
      await chat.warmDesktopGateway();
      await Future<void>.delayed(Duration.zero);

      expect(chat.dashboardAuthRequired, isFalse);
      expect(
        events.where((event) => event == ActiveChatEvent.dashboardAuthChanged),
        hasLength(2),
      );
      expect(chat.messages.single['content'], 'durable REST transcript');
    },
  );

  test(
    'a stale auth failure cannot replace a newer successful recovery',
    () async {
      final gateway = _AuthWarmGateway()
        ..connectError = const DashboardAuthException(
          DashboardAuthFailureCode.loginRequired,
        );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-dashboard-auth-race'),
        sessionId: 'sess-dashboard-auth-race',
        sessionTitle: 'Auth recovery race',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.warmDesktopGateway();
      expect(chat.dashboardAuthRequired, isTrue);

      final releaseStaleFailure = Completer<void>();
      gateway
        ..connectError = null
        ..connectAttempts.addAll([
          () async {
            await releaseStaleFailure.future;
            throw const DashboardAuthException(
              DashboardAuthFailureCode.loginRequired,
            );
          },
          () async {},
        ]);
      final staleAttempt = chat.warmDesktopGateway();
      final recoveredAttempt = chat.warmDesktopGateway();
      await recoveredAttempt;
      expect(chat.dashboardAuthRequired, isFalse);

      releaseStaleFailure.complete();
      await staleAttempt;

      expect(chat.dashboardAuthRequired, isFalse);
    },
  );

  test('desktop recovery never exposes technical errors in UI', () {
    final secrets = <Object>[
      StateError('state-secret'),
      SocketException('socket-secret'),
      TuiGatewayRpcError('session.resume', 'rpc-secret', code: 4999),
    ];

    for (final error in secrets) {
      final ui = activeChatDesktopRecoveryUiMessage(error);
      final diagnostic = activeChatDesktopRecoveryDiagnostic(error);
      expect(ui, 'No se pudo recuperar el turno. Inténtalo de nuevo.');
      expect(ui, isNot(contains('secret')));
      expect(diagnostic, isNot(contains('secret')));
      expect(diagnostic, contains(error.runtimeType.toString()));
    }
    expect(
      activeChatDesktopRecoveryDiagnostic(secrets.last),
      contains('code=4999'),
    );

    expect(
      activeChatDesktopSnapshotFailureUiMessage(
        'model call failed: 500 private-upstream-detail',
      ),
      'No se pudo recuperar el turno. Inténtalo de nuevo.',
    );
  });

  test('prompt admission uses localized structured reasons without unsafe advice', () {
    const expectedEs = <String, String>{
      'SESSION_NOT_OWNED':
          'No se puede continuar en directo porque esta conversación pertenece '
          'a otro gateway o proceso. El historial se conserva y puedes iniciar '
          'un chat nuevo.',
      'MAX_CONCURRENT_SESSIONS':
          'Hermes alcanzó el límite configurado de sesiones activas. '
          'Espera a que termine una sesión o ajusta el límite.',
      'SESSION_COORDINATION_UNAVAILABLE':
          'Hermes no pudo reservar esta conversación con seguridad. '
          'Revisa el servidor y vuelve a intentarlo.',
    };
    const expectedEn = <String, String>{
      'SESSION_NOT_OWNED':
          'This conversation can’t continue live because it belongs to another '
          'gateway or process. Its history remains available, and you can still '
          'start a new chat.',
      'MAX_CONCURRENT_SESSIONS':
          'Hermes reached the configured active-session limit. Wait for a '
          'session to finish or adjust the limit.',
      'SESSION_COORDINATION_UNAVAILABLE':
          'Hermes could not safely reserve this conversation. Check the server '
          'and try again.',
    };

    for (final locale in {'es': expectedEs, 'en': expectedEn}.entries) {
      for (final entry in locale.value.entries) {
        final error = TuiGatewayRpcError(
          'prompt.submit',
          'private session id and process detail',
          code: 4090,
          data: {'reason': entry.key},
        );
        final message = activeChatPromptFailureUiMessage(
          error,
          languageCode: locale.key,
        );
        expect(activeChatPromptWasRejectedBeforeAcceptance(error), isTrue);
        expect(message, entry.value);
        expect(message, isNot(contains('private')));
        if (entry.key == 'SESSION_NOT_OWNED') {
          expect(message.toLowerCase(), isNot(contains('close another')));
          expect(message, isNot(contains('Ciérrala allí')));
        }
      }
    }

    const unknown = TuiGatewayRpcError(
      'prompt.submit',
      'private provider detail',
      code: 5001,
    );
    expect(activeChatPromptWasRejectedBeforeAcceptance(unknown), isFalse);
    expect(
      activeChatPromptFailureUiMessage(unknown, languageCode: 'es'),
      'No se pudo enviar el mensaje. Inténtalo de nuevo.',
    );
    expect(
      activeChatPromptFailureUiMessage(unknown, languageCode: 'en'),
      'The message could not be sent. Try again.',
    );
  });

  test('stored 4090 errors from older builds are redacted for display', () {
    const legacy =
        'TuiGatewayRpcError(prompt.submit, 4090): Session private-id '
        'already has a live owner (desktop, pid 1234)';
    const ordinary = 'No se pudo conectar con Hermes.';

    final safe = activeChatStoredErrorUiMessage(legacy);
    expect(
      safe,
      'No se puede continuar esta conversación en directo. '
      'El historial se conserva y puedes iniciar un chat nuevo.',
    );
    expect(safe, isNot(contains('TuiGatewayRpcError')));
    expect(safe, isNot(contains('private-id')));
    expect(activeChatStoredErrorUiMessage(ordinary), ordinary);
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('REST silence has no client-side terminal timeout', () async {
    final api = _CapturingRunApi();
    final service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(service.dispose);
    final chat = service.attach(
      connection: _conn(id: 'conn-rest-watchdog'),
      sessionId: 'session-rest-watchdog',
      sessionTitle: 'REST watchdog',
      api: api,
    );

    expect(
      await chat
          .send(
            fullText: 'trabaja en silencio',
            model: 'hermes-agent',
            history: const [],
          )
          .timeout(const Duration(seconds: 2)),
      isTrue,
    );

    expect(api.streamIdleTimeout, isNull);
    expect(chat.isStreaming, isTrue);
    expect(chat.state, isNot(ChatPipelineState.failed));
    expect(_hasAssistantError(chat), isFalse);
  });

  group('ActiveTurnDelivery — FSM de adjuntos', () {
    const pending = AttachmentDraft(
      localId: 'attachment-a',
      type: AttachmentType.document,
      name: 'informe.pdf',
      mimeType: 'application/pdf',
      sizeBytes: 3,
      localPath: '/private/informe.pdf',
    );

    test('rechazo explícito nunca degrada después a entrega ambigua', () async {
      final store = _AttachmentMemoryOutbox();
      final delivery = ActiveTurnDelivery(
        prepared: _attachmentTurn(pending),
        store: store,
      );

      expect(
        await delivery.beginTransport(PreparedTurnTransport.desktop),
        isTrue,
      );
      await delivery.markRejectedBeforeAcceptance();
      await delivery.markUnaccepted();

      expect(delivery.current.state, PreparedTurnState.failedBeforeAcceptance);
    });

    test(
      'attempt fence impide que un callback tardío reviva removed',
      () async {
        final store = _AttachmentMemoryOutbox();
        final observed = <AttachmentUploadState>[];
        final delivery = ActiveTurnDelivery(
          prepared: _attachmentTurn(pending),
          store: store,
          onAttachmentsChanged: (items) {
            observed.add(items.single.uploadState);
          },
        );

        final uploading = await delivery.beginAttachmentUpload(
          'attachment-a',
          remoteSessionId: 'runtime-a',
          transport: AttachmentRemoteTransport.desktop,
        );
        expect(uploading?.uploadState, AttachmentUploadState.uploading);
        expect(uploading?.attempt, 1);
        await delivery.removeAttachment('attachment-a');
        final accepted = await delivery.markAttachmentAttached(
          'attachment-a',
          attempt: 1,
          remoteSessionId: 'runtime-a',
          transport: AttachmentRemoteTransport.desktop,
          remoteRef: '@file:.hermes/informe.pdf',
        );

        expect(accepted, isFalse);
        expect(
          delivery.current.attachments.single.uploadState,
          AttachmentUploadState.removed,
        );
        expect(observed, [
          AttachmentUploadState.uploading,
          AttachmentUploadState.removed,
        ]);
      },
    );

    test('reusa mismo owner pero invalida ref al cambiar runtime', () async {
      final attached = pending.copyWith(
        uploadState: AttachmentUploadState.attached,
        attempt: 1,
        remoteRef: '@file:.hermes/informe.pdf',
        remoteSessionId: 'runtime-a',
        remoteTransport: AttachmentRemoteTransport.desktop,
      );
      final store = _AttachmentMemoryOutbox();
      final delivery = ActiveTurnDelivery(
        prepared: _attachmentTurn(attached),
        store: store,
      );

      final reused = await delivery.beginAttachmentUpload(
        'attachment-a',
        remoteSessionId: 'runtime-a',
        transport: AttachmentRemoteTransport.desktop,
      );
      expect(reused?.uploadState, AttachmentUploadState.attached);
      expect(store.writes, isEmpty);

      final rebound = await delivery.beginAttachmentUpload(
        'attachment-a',
        remoteSessionId: 'runtime-b',
        transport: AttachmentRemoteTransport.desktop,
      );
      expect(rebound?.uploadState, AttachmentUploadState.uploading);
      expect(rebound?.attempt, 2);
      expect(rebound?.remoteRef, isNull);
      expect(rebound?.remoteSessionId, 'runtime-b');
    });

    test(
      'submit fallido reintenta en el mismo runtime sin duplicar file.attach',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'hermes-attachment-retry-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final attachment = await _privateTestAttachment(
          directory,
          localId: 'attachment-retry',
        );
        final store = _AttachmentMemoryOutbox();
        final delivery = ActiveTurnDelivery(
          prepared: _attachmentTurn(attachment),
          store: store,
        );
        final gateway = _AttachmentDesktopGateway()..failNextSubmit = true;
        final chat = _attachmentChat(gateway);
        addTearDown(chat.dispose);

        final firstAccepted = await chat.send(
          fullText: 'revisa',
          model: 'hermes-agent',
          history: const [],
          nativeAttachments: [attachment],
          delivery: delivery,
        );
        expect(firstAccepted, isFalse);
        expect(delivery.current.state, PreparedTurnState.ambiguous);
        expect(gateway.fileAttachCalls, 1);

        final retryAccepted = await chat.send(
          fullText: 'revisa',
          model: 'hermes-agent',
          history: const [],
          nativeAttachments: delivery.current.activeAttachments,
          delivery: delivery,
        );

        expect(retryAccepted, isTrue);
        expect(gateway.fileAttachCalls, 1);
        expect(gateway.submitCalls, 2);
        expect(
          delivery.current.attachments.single.uploadState,
          AttachmentUploadState.attached,
        );
      },
    );

    test('un runtime nuevo vuelve a adjuntar el mismo lote', () async {
      final directory = await Directory.systemTemp.createTemp(
        'hermes-attachment-runtime-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final attachment = await _privateTestAttachment(
        directory,
        localId: 'attachment-runtime',
      );
      final delivery = ActiveTurnDelivery(
        prepared: _attachmentTurn(attachment),
        store: _AttachmentMemoryOutbox(),
      );
      final gateway = _AttachmentDesktopGateway()..failNextSubmit = true;
      final chat = _attachmentChat(gateway);
      addTearDown(chat.dispose);

      expect(
        await chat.send(
          fullText: 'revisa',
          model: 'hermes-agent',
          history: const [],
          nativeAttachments: [attachment],
          delivery: delivery,
        ),
        isFalse,
      );
      gateway.runtimeId = 'runtime-b';

      expect(
        await chat.send(
          fullText: 'revisa',
          model: 'hermes-agent',
          history: const [],
          nativeAttachments: delivery.current.activeAttachments,
          delivery: delivery,
        ),
        isTrue,
      );

      expect(gateway.fileAttachCalls, 2);
      expect(delivery.current.attachments.single.remoteSessionId, 'runtime-b');
      expect(delivery.current.attachments.single.attempt, 2);
    });

    test(
      'remove durante file.attach impide callback tardío y prompt.submit',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'hermes-attachment-remove-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final attachment = await _privateTestAttachment(
          directory,
          localId: 'attachment-remove',
        );
        final delivery = ActiveTurnDelivery(
          prepared: _attachmentTurn(attachment),
          store: _AttachmentMemoryOutbox(),
        );
        final gateway = _AttachmentDesktopGateway()
          ..attachGate = Completer<void>();
        final chat = _attachmentChat(gateway);
        addTearDown(chat.dispose);

        final send = chat.send(
          fullText: 'revisa',
          model: 'hermes-agent',
          history: const [],
          nativeAttachments: [attachment],
          delivery: delivery,
        );
        await _waitFor(() => gateway.fileAttachCalls == 1);
        await delivery.removeAttachment('attachment-remove');
        gateway.attachGate!.complete();

        expect(await send, isFalse);
        expect(gateway.submitCalls, 0);
        expect(
          delivery.current.attachments.single.uploadState,
          AttachmentUploadState.removed,
        );
      },
    );

    test('imagen retirada tarde ejecuta detach best-effort', () async {
      final directory = await Directory.systemTemp.createTemp(
        'hermes-attachment-detach-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final attachment = await _privateTestAttachment(
        directory,
        localId: 'attachment-image',
        type: AttachmentType.image,
      );
      final delivery = ActiveTurnDelivery(
        prepared: _attachmentTurn(attachment),
        store: _AttachmentMemoryOutbox(),
      );
      final gateway = _AttachmentDesktopGateway()
        ..attachGate = Completer<void>();
      final chat = _attachmentChat(gateway);
      addTearDown(chat.dispose);

      final send = chat.send(
        fullText: 'revisa',
        model: 'hermes-agent',
        history: const [],
        nativeAttachments: [attachment],
        delivery: delivery,
      );
      await _waitFor(() => gateway.imageAttachCalls == 1);
      await delivery.removeAttachment('attachment-image');
      gateway.attachGate!.complete();

      expect(await send, isFalse);
      expect(gateway.submitCalls, 0);
      expect(gateway.detachedImages, [
        ('runtime-a', '/remote/attachment-image.png'),
      ]);
    });

    test(
      'retirar una imagen ya attached hace detach antes del reintento',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'hermes-attachment-detach-after-attach-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final first = await _privateTestAttachment(
          directory,
          localId: 'attachment-image-first',
          type: AttachmentType.image,
        );
        final second = await _privateTestAttachment(
          directory,
          localId: 'attachment-image-second',
          type: AttachmentType.image,
        );
        final delivery = ActiveTurnDelivery(
          prepared: _attachmentTurn(
            first,
          ).copyWith(attachments: [first, second]),
          store: _AttachmentMemoryOutbox(),
        );
        final gateway = _AttachmentDesktopGateway()
          ..attachGate = Completer<void>()
          ..gateOnImageAttachCall = 2;
        final chat = _attachmentChat(gateway);
        addTearDown(chat.dispose);

        final send = chat.send(
          fullText: 'revisa',
          model: 'hermes-agent',
          history: const [],
          nativeAttachments: [first, second],
          delivery: delivery,
        );
        await _waitFor(
          () =>
              gateway.imageAttachCalls == 2 &&
              delivery.current.attachments.first.uploadState ==
                  AttachmentUploadState.attached,
        );

        expect(
          await chat.removeActiveAttachment('attachment-image-first'),
          isTrue,
        );
        gateway.attachGate!.complete();

        expect(await send, isFalse);
        expect(gateway.submitCalls, 0);
        expect(gateway.detachedImages, [
          ('runtime-a', '/remote/attachment-image-first.png'),
        ]);
      },
    );

    test(
      'fallo al persistir attached invalida la ref y obliga a re-adjuntar',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'hermes-attachment-persist-failure-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final attachment = await _privateTestAttachment(
          directory,
          localId: 'attachment-persist-failure',
          type: AttachmentType.image,
        );
        final store = _AttachmentMemoryOutbox(failOnSaveCall: 3);
        final delivery = ActiveTurnDelivery(
          prepared: _attachmentTurn(attachment),
          store: store,
        );
        final gateway = _AttachmentDesktopGateway();
        final chat = _attachmentChat(gateway);
        addTearDown(chat.dispose);

        expect(
          await chat.send(
            fullText: 'revisa',
            model: 'hermes-agent',
            history: const [],
            nativeAttachments: [attachment],
            delivery: delivery,
          ),
          isFalse,
        );
        final failed = delivery.current.attachments.single;
        expect(failed.uploadState, AttachmentUploadState.error);
        expect(failed.errorKind, AttachmentErrorKind.persistence);
        expect(failed.remoteRef, isNull);
        expect(gateway.detachedImages, [
          ('runtime-a', '/remote/attachment-persist-failure.png'),
        ]);

        expect(
          await delivery.retryAttachment('attachment-persist-failure'),
          isTrue,
        );
        expect(
          await chat.send(
            fullText: 'revisa',
            model: 'hermes-agent',
            history: const [],
            nativeAttachments: delivery.current.activeAttachments,
            delivery: delivery,
          ),
          isTrue,
        );
        expect(gateway.imageAttachCalls, 2);
      },
    );

    test(
      'persiste submitting y estados del item antes de cada mutación remota',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'hermes-attachment-order-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final attachment = await _privateTestAttachment(
          directory,
          localId: 'attachment-order',
        );
        final events = <String>[];
        final delivery = ActiveTurnDelivery(
          prepared: _attachmentTurn(attachment),
          store: _AttachmentMemoryOutbox(eventLog: events),
        );
        final gateway = _AttachmentDesktopGateway(eventLog: events);
        final chat = _attachmentChat(gateway);
        addTearDown(chat.dispose);

        expect(
          await chat.send(
            fullText: 'revisa',
            model: 'hermes-agent',
            history: const [],
            nativeAttachments: [attachment],
            delivery: delivery,
          ),
          isTrue,
        );

        expect(events.take(5), [
          'persist:submitting:pending',
          'persist:submitting:uploading',
          'rpc:file.attach',
          'persist:submitting:attached',
          'rpc:prompt.submit',
        ]);
      },
    );

    test(
      'REST persiste managedPath y lo reusa tras un startRun fallido',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'hermes-attachment-rest-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final attachment = await _privateTestAttachment(
          directory,
          localId: 'attachment-rest',
        );
        final events = <String>[];
        var uploadCalls = 0;
        var runCalls = 0;
        final client = MockClient((request) async {
          if (request.method == 'POST' && request.url.path == '/v1/runs') {
            runCalls++;
            events.add('rpc:runs');
            expect(request.body, contains('/managed/attachment-rest.pdf'));
            if (runCalls == 1) return http.Response('test failure', 500);
            return http.Response(jsonEncode({'run_id': 'run-rest'}), 200);
          }
          if (request.method == 'GET' &&
              request.url.path == '/v1/runs/run-rest/events') {
            return http.Response(
              '',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return http.Response('not found', 404);
        });
        final connection = _conn(id: 'conn-attachment');
        final api = ApiClient(
          baseUrl: connection.baseUrl,
          apiKey: connection.apiKey,
          httpClient: client,
        );
        final delivery = ActiveTurnDelivery(
          prepared: _attachmentTurn(attachment),
          store: _AttachmentMemoryOutbox(eventLog: events),
        );
        final chat = ActiveChat(
          compressionRestoreStore: testCompressionRestoreStore(),
          connection: connection,
          sessionId: 'sess-attachment',
          sessionTitle: 'Adjuntos REST',
          notifications: null,
          onTerminal: () {},
          api: api,
          attachmentUploader: (_, item) async {
            uploadCalls++;
            events.add('upload:rest');
            return AttachmentUploadResult.success('/managed/${item.name}');
          },
        );
        addTearDown(chat.dispose);

        expect(
          await chat.send(
            fullText: 'revisa',
            model: 'hermes-agent',
            history: const [],
            nativeAttachments: [attachment],
            delivery: delivery,
          ),
          isFalse,
        );
        expect(delivery.current.state, PreparedTurnState.ambiguous);
        expect(uploadCalls, 1);
        expect(events.take(5), [
          'persist:submitting:pending',
          'persist:submitting:uploading',
          'upload:rest',
          'persist:submitting:attached',
          'rpc:runs',
        ]);

        expect(
          await chat.send(
            fullText: 'revisa',
            model: 'hermes-agent',
            history: const [],
            nativeAttachments: delivery.current.activeAttachments,
            delivery: delivery,
          ),
          isTrue,
        );
        expect(uploadCalls, 1);
        expect(runCalls, 2);
        expect(
          delivery.current.attachments.single.remoteTransport,
          AttachmentRemoteTransport.rest,
        );
      },
    );

    test('REST no inicia el run si retiran el item durante upload', () async {
      final directory = await Directory.systemTemp.createTemp(
        'hermes-attachment-rest-remove-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final attachment = await _privateTestAttachment(
        directory,
        localId: 'attachment-rest-remove',
      );
      var runCalls = 0;
      final api = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/runs') runCalls++;
          return http.Response(jsonEncode({'run_id': 'unexpected'}), 200);
        }),
      );
      final uploadGate = Completer<AttachmentUploadResult>();
      var uploadCalls = 0;
      final delivery = ActiveTurnDelivery(
        prepared: _attachmentTurn(attachment),
        store: _AttachmentMemoryOutbox(),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(id: 'conn-attachment'),
        sessionId: 'sess-attachment',
        sessionTitle: 'Adjuntos REST',
        notifications: null,
        onTerminal: () {},
        api: api,
        attachmentUploader: (_, _) {
          uploadCalls++;
          return uploadGate.future;
        },
      );
      addTearDown(chat.dispose);

      final send = chat.send(
        fullText: 'revisa',
        model: 'hermes-agent',
        history: const [],
        nativeAttachments: [attachment],
        delivery: delivery,
      );
      await _waitFor(() => uploadCalls == 1);
      await delivery.removeAttachment('attachment-rest-remove');
      uploadGate.complete(
        const AttachmentUploadResult.success('/managed/removed.pdf'),
      );

      expect(await send, isFalse);
      expect(runCalls, 0);
      expect(
        delivery.current.attachments.single.uploadState,
        AttachmentUploadState.removed,
      );
    });

    test(
      'Bridge no reejecuta tras error SSE y reusa la ruta al reintentar',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'hermes-attachment-bridge-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final attachment = await _privateTestAttachment(
          directory,
          localId: 'attachment-bridge',
        );
        final delivery = ActiveTurnDelivery(
          prepared: _attachmentTurn(attachment),
          store: _AttachmentMemoryOutbox(),
        );
        final bridge = _AttachmentBridgeClient()
          ..nextStreamFailure = const BridgeException(
            'chat_stream_failed',
            'error SSE posterior al HTTP 200',
          );
        final connection = SavedConnection(
          id: 'conn-attachment',
          label: 'Local test',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'test-key',
          kind: InstanceKind.localhost,
          onDeviceLoopback: true,
        );
        final chat = ActiveChat(
          compressionRestoreStore: testCompressionRestoreStore(),
          connection: connection,
          sessionId: 'sess-attachment',
          sessionTitle: 'Adjuntos Bridge',
          notifications: null,
          onTerminal: () {},
          bridgeProvisioner: (_, _) async => 'bridge-token',
          bridgeClientFactory: ({required baseUrl, required token}) => bridge,
        );
        addTearDown(chat.dispose);

        expect(
          await chat.send(
            fullText: 'revisa',
            model: 'hermes-agent',
            history: const [],
            nativeAttachments: [attachment],
            delivery: delivery,
          ),
          isFalse,
        );
        expect(delivery.current.state, PreparedTurnState.ambiguous);
        expect(bridge.uploadCalls, 1);

        expect(
          await chat.send(
            fullText: 'revisa',
            model: 'hermes-agent',
            history: const [],
            nativeAttachments: delivery.current.activeAttachments,
            delivery: delivery,
          ),
          isTrue,
        );

        expect(bridge.uploadCalls, 1);
        expect(bridge.streamCalls, 2);
        expect(bridge.fallbackChatCalls, 0);
        expect(
          delivery.current.attachments.single.remoteTransport,
          AttachmentRemoteTransport.bridgeLocal,
        );
      },
    );

    test('Bridge antiguo con 404 previo usa fallback una sola vez', () async {
      final directory = await Directory.systemTemp.createTemp(
        'hermes-attachment-bridge-legacy-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final attachment = await _privateTestAttachment(
        directory,
        localId: 'attachment-bridge-legacy',
      );
      final delivery = ActiveTurnDelivery(
        prepared: _attachmentTurn(attachment),
        store: _AttachmentMemoryOutbox(),
      );
      final bridge = _AttachmentBridgeClient()
        ..nextStreamFailure = const BridgeException(
          'http_404',
          'stream endpoint unavailable',
          kind: BridgeErrorKind.notFound,
          status: 404,
        );
      final connection = SavedConnection(
        id: 'conn-attachment',
        label: 'Local test',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'test-key',
        kind: InstanceKind.localhost,
        onDeviceLoopback: true,
        localChatMode: LocalChatMode.agent,
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: connection,
        sessionId: 'sess-attachment',
        sessionTitle: 'Adjuntos Bridge legacy',
        notifications: null,
        onTerminal: () {},
        bridgeProvisioner: (_, _) async => 'bridge-token',
        bridgeClientFactory: ({required baseUrl, required token}) => bridge,
      );
      addTearDown(chat.dispose);

      expect(
        await chat.send(
          fullText: 'revisa',
          model: 'hermes-agent',
          history: const [],
          nativeAttachments: [attachment],
          delivery: delivery,
        ),
        isTrue,
      );
      expect(bridge.streamCalls, 1);
      expect(bridge.fallbackChatCalls, 1);
    });

    test('Bridge local receives the sealed default manager profile', () async {
      final bridge = _AttachmentBridgeClient();
      final connection = SavedConnection(
        id: 'conn-room-default-profile',
        label: 'Local room test',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'test-key',
        kind: InstanceKind.localhost,
        onDeviceLoopback: true,
        localChatMode: LocalChatMode.agent,
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: connection,
        sessionId: 'mob-room-default',
        sessionTitle: '#homelab',
        sessionProfile: 'default',
        notifications: null,
        onTerminal: () {},
        bridgeProvisioner: (_, _) async => 'bridge-token',
        bridgeClientFactory: ({required baseUrl, required token}) => bridge,
      );
      addTearDown(chat.dispose);

      expect(
        await chat.send(
          fullText: 'prepara el plan',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );

      expect(bridge.chatProfiles, ['default']);
    });
  });

  test(
    'new mob draft creates directly while another durable chat keeps working',
    () async {
      final gateway = _NativeSessionSplitGateway();
      final connection = _conn(id: 'conn-native-session-split');
      final durable = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: connection,
        sessionId: 'stored-a',
        initialStoredSessionId: 'stored-a',
        sessionTitle: 'A',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
      );
      final draft = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: connection,
        sessionId: 'mob-b',
        sessionTitle: 'B',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
      );
      addTearDown(durable.dispose);
      addTearDown(draft.dispose);

      expect(
        await durable.send(
          fullText: 'turno A',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      expect(durable.state, ChatPipelineState.waiting);

      expect(
        await draft.send(
          fullText: 'turno B',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );

      expect(gateway.calls, [
        'resume:stored-a',
        'submit:runtime-stored-a',
        'create',
        'submit:runtime-created-b',
      ]);
      expect(draft.storedSessionId, 'stored-created-b');
      expect(draft.desktopRuntimeSessionId, 'runtime-created-b');
      expect(durable.state, ChatPipelineState.waiting);
      expect(gateway.interrupts, 0);
    },
  );

  test('durable first submit resumes the exact id and never creates', () async {
    final gateway = _NativeSessionSplitGateway();
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: _conn(id: 'conn-native-existing-only'),
      sessionId: 'mob-route',
      initialStoredSessionId: 'stored-exact',
      sessionTitle: 'Exact durable',
      notifications: null,
      onTerminal: () {},
      desktopGateway: gateway,
    );
    addTearDown(chat.dispose);

    expect(
      await chat.send(
        fullText: 'continúa',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );

    expect(gateway.calls, [
      'resume:stored-exact',
      'submit:runtime-stored-exact',
    ]);
    expect(gateway.interrupts, 0);
  });

  test('known stored binding is stable and rejects retargeting', () {
    final chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: _conn(id: 'conn-known-binding'),
      sessionId: 'mob-bot-manager',
      sessionTitle: 'Bot Chat',
      sessionProfile: 'manager',
      initialStoredSessionId: 'stored-bot-a',
      notifications: null,
      onTerminal: () {},
      api: ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'test-key',
        httpClient: _gateway(events: '', finalMessages: const []),
      ),
    );
    addTearDown(chat.dispose);

    expect(chat.storedSessionId, 'stored-bot-a');
    expect(
      chat.bindKnownStoredSession('stored-bot-a', authoritative: true),
      isTrue,
    );
    expect(
      chat.bindKnownStoredSession('stored-bot-b', authoritative: true),
      isFalse,
    );
    expect(chat.storedSessionId, 'stored-bot-a');
  });

  test('authoritative repin creates a fresh ActiveChat binding', () {
    final service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(service.dispose);
    final connection = _conn(id: 'conn-repin');
    ApiClient api() => ApiClient(
      baseUrl: 'http://hermes.local:8642',
      apiKey: 'test-key',
      httpClient: _gateway(events: '', finalMessages: const []),
    );

    final first = service.attach(
      connection: connection,
      sessionId: 'mob-bot-manager',
      sessionTitle: 'Bot Chat',
      sessionProfile: 'manager',
      initialStoredSessionId: 'stored-bot-a',
      authoritativeStoredSessionBinding: true,
      api: api(),
    );
    final repinned = service.attach(
      connection: connection,
      sessionId: 'mob-bot-manager',
      sessionTitle: 'Bot Chat',
      sessionProfile: 'manager',
      initialStoredSessionId: 'stored-bot-b',
      authoritativeStoredSessionBinding: true,
      api: api(),
    );

    expect(repinned, isNot(same(first)));
    expect(repinned.storedSessionId, 'stored-bot-b');
    expect(
      service.of(connection.id, 'mob-bot-manager', profile: 'manager'),
      same(repinned),
    );
  });

  test(
    'reapertura durable restaura Stop desde el alias lógico del primer chat',
    () async {
      String? payload;
      final store = CancelledTurnTombstoneStore(
        read: () async => payload,
        write: (value) async => payload = value,
        nowMs: () => 1000,
      );
      await store.initialize();
      final connection = _conn(id: 'conn-stop-logical-alias');
      final generation = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                connection.id,
                connection.kind.name,
                connection.host,
                connection.port,
                connection.useHttps,
                connection.gatewayAuthMode.storageKey,
                connection.apiKey,
              ]),
            ),
          )
          .toString();
      await store.add(
        connectionId: connection.id,
        profile: 'default',
        sessionId: 'mobile-first-route',
        generation: generation,
        tombstone: const CancelledTurnTombstone(
          content: 'cuento cancelado',
          firstUser: true,
        ),
      );

      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
        cancelledTurnStore: store,
      );
      addTearDown(service.dispose);
      final chat = service.attach(
        connection: connection,
        sessionId: 'stored-desktop-route',
        logicalSessionId: 'mobile-first-route',
        sessionTitle: 'Cuento',
        sessionProfile: 'default',
        initialStoredSessionId: 'stored-desktop-route',
        api: ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'test-key',
          httpClient: _gateway(events: '', finalMessages: const []),
        ),
        storedMessageLoader: (_, _) async => const [
          {'id': 1, 'role': 'user', 'content': 'cuento cancelado'},
          {
            'id': 2,
            'role': 'assistant',
            'content': 'respuesta que no debe resucitar',
          },
        ],
      );

      await chat.loadMessages(expectedMessageCount: 2);

      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta que no debe resucitar',
        ),
        isFalse,
      );
      expect(
        chat.messages.singleWhere(
          (message) => message['content'] == 'cuento cancelado',
        )['_cancelledUser'],
        isTrue,
      );
    },
  );

  test(
    'TTFT persistido queda aislado por perfil y migra solo default',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final profileAKey = jsonEncode(const [
        'conn-1',
        'profile-a',
        'sess-shared',
      ]);
      final profileBKey = jsonEncode(const [
        'conn-1',
        'profile-b',
        'sess-shared',
      ]);
      await prefs.setString(
        _kObservedTtftKey,
        jsonEncode({
          profileAKey: 410,
          profileBKey: 920,
          // Formato anterior a la identidad por perfil. Solo puede migrar al
          // owner `default`; reutilizarlo para otro perfil mezclaría métricas.
          'conn-1::sess-legacy': 770,
        }),
      );

      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
        prefs: prefs,
      );
      expect(
        service.observedFirstTokenLatencyMs(
          'conn-1',
          'sess-shared',
          profile: 'profile-a',
        ),
        410,
      );
      expect(
        service.observedFirstTokenLatencyMs(
          'conn-1',
          'sess-shared',
          profile: 'profile-b',
        ),
        920,
      );
      expect(
        service.observedFirstTokenLatencyMs(
          'conn-1',
          'sess-legacy',
          profile: 'profile-a',
        ),
        isNull,
      );
      expect(
        service.observedFirstTokenLatencyMs(
          'conn-1',
          'sess-legacy',
          profile: 'default',
        ),
        770,
      );

      final chatA = service.attach(
        connection: _conn(),
        sessionId: 'sess-shared',
        sessionTitle: 'Perfil A',
        sessionProfile: 'profile-a',
      );
      final chatB = service.attach(
        connection: _conn(),
        sessionId: 'sess-shared',
        sessionTitle: 'Perfil B',
        sessionProfile: 'profile-b',
      );
      expect(chatA, isNot(same(chatB)));
      expect(chatA.observedFirstTokenLatencyMs, 410);
      expect(chatB.observedFirstTokenLatencyMs, 920);
      service.dispose();
    },
  );

  test(
    'activeIds notifica al terminar solo uno de dos perfiles colisionados',
    () {
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      final connection = _conn(id: 'conn-profile-activity');
      final first = service.attach(
        connection: connection,
        sessionId: 'sess-shared',
        sessionTitle: 'Perfil A',
        sessionProfile: 'profile-a',
      );
      final second = service.attach(
        connection: connection,
        sessionId: 'sess-shared',
        sessionTitle: 'Perfil B',
        sessionProfile: 'profile-b',
      );
      var notifications = 0;
      service.activeIds.addListener(() => notifications++);

      first.state = ChatPipelineState.executing;
      service.markStarted(connection.id, first.sessionId);
      second.state = ChatPipelineState.executing;
      service.markStarted(connection.id, second.sessionId);

      expect(service.activeIds.value, hasLength(2));
      expect(
        service.isActive(connection.id, 'sess-shared', profile: 'profile-a'),
        isTrue,
      );
      expect(
        service.isActive(connection.id, 'sess-shared', profile: 'profile-b'),
        isTrue,
      );
      final beforeFirstStops = notifications;

      first.state = ChatPipelineState.idle;
      service.markStarted(connection.id, first.sessionId);

      expect(notifications, beforeFirstStops + 1);
      expect(service.activeIds.value, hasLength(1));
      expect(
        service.isActive(connection.id, 'sess-shared', profile: 'profile-a'),
        isFalse,
      );
      expect(
        service.isActive(connection.id, 'sess-shared', profile: 'profile-b'),
        isTrue,
      );
      // Una superficie sin perfil solo pregunta si existe algún run para pintar
      // un indicador; no selecciona ni devuelve contenido de ningún chat.
      expect(service.isActive(connection.id, 'sess-shared'), isTrue);
      service.dispose();
    },
  );

  test(
    'control y tareas pendientes mantienen visible el trabajo de fondo',
    () async {
      final gateway = _AttachmentDesktopGateway();
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(service.dispose);
      addTearDown(gateway.close);
      final connection = _conn(id: 'conn-control-activity');
      final chat = service.attach(
        connection: connection,
        sessionId: 'sess-control-activity',
        sessionTitle: 'Control activo',
        desktopGateway: gateway,
        disableForegroundKeepAlive: true,
      )..smoothStreaming = false;
      expect(
        await chat.send(
          fullText: 'programa el seguimiento',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit('message.complete', const {
        'text': 'seguimiento programado',
      });
      await done.timeout(const Duration(seconds: 1));
      expect(chat.sessionActivity.active, isFalse);

      gateway.emit('session.control.update', const {
        'control': {
          'loop': {
            'status': 'active',
            'interval_seconds': 300,
            'last_fired_at': 1720000000,
            'next_due_at': 1720000300,
            'ticks_fired': 2,
          },
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.sessionActivity.active, isTrue);

      gateway.emit('session.control.update', const {
        'control': {'loop': null, 'heartbeat': null, 'goal': null},
      });
      gateway.emit('todo.updated', const {
        'revision': 4,
        'todos': [
          {
            'id': 'task-1',
            'content': 'Esperar el despliegue',
            'status': 'pending',
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.sessionActivity.active, isTrue);
    },
  );

  test(
    'terminal espera process.list pendiente y conserva trabajo de fondo',
    () async {
      final gateway = _DelayedProcessGateway();
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(service.dispose);
      addTearDown(gateway.close);
      final connection = _conn(id: 'conn-terminal-process');
      final chat = service.attach(
        connection: connection,
        sessionId: 'sess-terminal-process',
        sessionTitle: 'Proceso terminal',
        desktopGateway: gateway,
        disableForegroundKeepAlive: true,
      )..smoothStreaming = false;
      expect(
        await chat.send(
          fullText: 'lanza el proceso',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      final processRefresh = chat.refreshBackgroundProcessesForTesting();
      service.release(connection.id, chat.sessionId);
      gateway.connected = false;
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );

      gateway.emit('message.complete', const {'text': 'proceso iniciado'});
      await done.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(
        service.of(connection.id, chat.sessionId),
        same(chat),
        reason: 'la lista pendiente todavía puede probar trabajo de fondo',
      );

      gateway.processSnapshot.complete(
        const AgentCenterSnapshot(
          snapshots: [],
          processes: [
            BackgroundProcessEntry(
              opaqueId: 'process-1',
              status: AgentCenterStatus.running,
              uptimeSeconds: 2,
            ),
          ],
        ),
      );
      await processRefresh;
      await Future<void>.delayed(Duration.zero);

      expect(service.isActive(connection.id, chat.sessionId), isTrue);
      expect(service.of(connection.id, chat.sessionId), same(chat));

      gateway.processSnapshot = Completer<AgentCenterSnapshot>();
      final terminalRefresh = chat.refreshBackgroundProcessesForTesting();
      gateway.processSnapshot.complete(
        const AgentCenterSnapshot(
          snapshots: [],
          processes: [
            BackgroundProcessEntry(
              opaqueId: 'process-1',
              status: AgentCenterStatus.completed,
              uptimeSeconds: 3,
            ),
          ],
        ),
      );
      await terminalRefresh;
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(service.of(connection.id, chat.sessionId), isNull);
    },
  );

  test('expone actividad real y la conserva durante una reconexión', () {
    final service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    final chat = service.attach(
      connection: _conn(id: 'conn-activity'),
      sessionId: 'sess-activity',
      sessionTitle: 'Actividad',
      api: ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'test-key',
        httpClient: _gateway(events: '', finalMessages: const []),
      ),
    );

    chat.state = ChatPipelineState.executing;
    expect(chat.activityKind, ChatActivityKind.usingTools);

    chat.state = ChatPipelineState.connecting;
    expect(chat.activityKind, ChatActivityKind.usingTools);

    chat.pendingApproval = {'id': 'approval-1'};
    expect(chat.activityKind, ChatActivityKind.awaitingApproval);

    chat.pendingApproval = null;
    chat.state = ChatPipelineState.completed;
    expect(chat.activityKind, isNull);
    service.dispose();
  });

  group('ActiveChatService — proyección semántica del widget', () {
    test('publica una sesión antigua en cuanto se abre', () async {
      final store = _WidgetRecordingStore();
      final publisher = HermesHomeWidgetPublisher(
        store: store,
        nowMs: () => 2000000000000,
      );
      await publisher.publish(
        const HermesHomeWidgetSnapshot(
          configured: true,
          instanceId: 'conn-1',
          instanceLabel: 'Test',
          connectionState: HomeWidgetConnectionState.connected,
        ),
      );
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      )..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1');

      service.attach(
        connection: _conn(),
        sessionId: 'sess-1',
        sessionTitle: 'Auditoría widget',
        sessionSnapshot: _widgetSession(),
        selectedProvider: 'openai-codex',
        api: ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'test-key',
          httpClient: _gateway(events: '', finalMessages: const []),
        ),
      );
      await publisher.flush();

      expect(publisher.latest.sessionId, 'sess-1');
      expect(publisher.latest.sessionTitle, 'Auditoría widget');
      expect(publisher.latest.model, 'gpt-5.5');
      expect(publisher.latest.provider, 'openai-codex');
      expect(publisher.latest.inputTokens, 1200);
      expect(publisher.latest.outputTokens, 300);
      expect(publisher.latest.cacheReadTokens, 500);
      expect(publisher.latest.cacheWriteTokens, 50);
      expect(publisher.latest.agentState, HomeWidgetAgentState.idle);
      service.dispose();
    });

    test(
      'un borrador móvil vacío no reemplaza la última sesión real del widget',
      () async {
        final store = _WidgetRecordingStore();
        final publisher = HermesHomeWidgetPublisher(
          store: store,
          nowMs: () => 2000000000000,
        );
        await publisher.publish(
          const HermesHomeWidgetSnapshot(
            configured: true,
            instanceId: 'conn-1',
            instanceLabel: 'Test',
            connectionState: HomeWidgetConnectionState.connected,
            sessionId: 'sess-real',
            sessionTitle: 'Última conversación real',
            agentState: HomeWidgetAgentState.idle,
          ),
        );
        final publishedBeforeDraft = store.snapshots.length;
        final service = ActiveChatService(
          compressionRestoreStore: testCompressionRestoreStore(),
        )..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1');

        service.attach(
          connection: _conn(),
          sessionId: 'mob-empty-draft',
          sessionTitle: 'Nueva conversación',
          api: ApiClient(
            baseUrl: 'http://hermes.local:8642',
            apiKey: 'test-key',
            httpClient: _gateway(events: '', finalMessages: const []),
          ),
        );
        await publisher.flush();

        expect(publisher.latest.sessionId, 'sess-real');
        expect(publisher.latest.sessionTitle, 'Última conversación real');
        expect(store.snapshots, hasLength(publishedBeforeDraft));
        service.dispose();
      },
    );

    test('reduce estados del run y no publica por cada token', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = _WidgetRecordingStore();
      final publisher = HermesHomeWidgetPublisher(
        store: store,
        nowMs: () => 2000000000000,
      );
      await publisher.publish(
        const HermesHomeWidgetSnapshot(
          configured: true,
          instanceId: 'conn-1',
          instanceLabel: 'Test',
          connectionState: HomeWidgetConnectionState.connected,
        ),
      );
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
        prefs: prefs,
      )..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1');
      final chat = service.attach(
        connection: _conn(),
        sessionId: 'sess-1',
        sessionTitle: 'Estados',
        sessionSnapshot: _widgetSession(),
        api: ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'test-key',
          httpClient: _gateway(
            events: _sse([
              {'event': 'tool.started', 'tool': 'shell'},
              {
                'event': 'approval.request',
                'request_id': 'approval-1',
                'command': 'echo ok',
              },
              {'event': 'message.delta', 'delta': 'Hola'},
              {'event': 'message.delta', 'delta': ' mundo'},
              {'event': 'run.completed', 'output': 'Hola mundo'},
            ]),
            finalMessages: const [
              {'role': 'user', 'content': 'di hola'},
              {'role': 'assistant', 'content': 'Hola mundo'},
            ],
          ),
        ),
      );
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );

      await chat.send(fullText: 'di hola', model: 'gpt-5.5', history: const []);
      await done.timeout(const Duration(seconds: 5));
      await publisher.flush();

      final states = store.snapshots
          .map((snapshot) => snapshot['hermes_widget_agent_state'])
          .whereType<String>()
          .toList();
      expect(states, contains(HomeWidgetAgentState.thinking.name));
      expect(states, contains(HomeWidgetAgentState.toolExecution.name));
      expect(states, contains(HomeWidgetAgentState.waitingApproval.name));
      expect(states, contains(HomeWidgetAgentState.streaming.name));
      expect(states.last, HomeWidgetAgentState.idle.name);
      expect(
        states.where((state) => state == HomeWidgetAgentState.streaming.name),
        hasLength(1),
      );
      expect(publisher.latest.firstTokenLatencyMs, isNotNull);
      expect(publisher.latest.firstTokenLatencyMs, greaterThanOrEqualTo(0));
      expect(publisher.latest.toolName, isNull);
      await Future<void>.delayed(Duration.zero);
      final persisted = jsonDecode(prefs.getString(_kObservedTtftKey)!);
      expect(
        persisted[jsonEncode(const ['conn-1', 'default', 'sess-1'])],
        publisher.latest.firstTokenLatencyMs,
      );
      service.dispose();

      final restored = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
        prefs: prefs,
      );
      expect(
        restored.observedFirstTokenLatencyMs('conn-1', 'sess-1'),
        publisher.latest.firstTokenLatencyMs,
      );
      restored.dispose();
    });

    test(
      'limpia la sesión y bloquea eventos tardíos al cambiar instancia',
      () async {
        final store = _WidgetRecordingStore();
        final publisher = HermesHomeWidgetPublisher(
          store: store,
          nowMs: () => 2000000000000,
        );
        final service = ActiveChatService(
          compressionRestoreStore: testCompressionRestoreStore(),
        )..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1');
        final chat = service.attach(
          connection: _conn(),
          sessionId: 'sess-1',
          sessionTitle: 'Vieja',
          sessionSnapshot: _widgetSession(),
          api: ApiClient(
            baseUrl: 'http://hermes.local:8642',
            apiKey: 'test-key',
            httpClient: _gateway(events: '', finalMessages: const []),
          ),
        );
        await publisher.flush();

        await service.setHomeWidgetActiveConnection('conn-2');
        service.updateHomeWidgetSessionMetadata(chat, model: 'modelo-tardío');
        await publisher.flush();

        expect(publisher.latest.sessionId, isNull);
        expect(publisher.latest.sessionTitle, isNull);
        expect(publisher.latest.model, isNull);
        expect(publisher.latest.contextUsed, isNull);
        expect(publisher.latest.firstTokenLatencyMs, isNull);
        expect(publisher.latest.agentState, HomeWidgetAgentState.disconnected);
        service.dispose();
      },
    );

    test('publica el error terminal sin confundirlo con desconexión', () async {
      final publisher = HermesHomeWidgetPublisher(
        store: _WidgetRecordingStore(),
        nowMs: () => 2000000000000,
      );
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      )..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1');
      final chat = service.attach(
        connection: _conn(),
        sessionId: 'sess-1',
        sessionTitle: 'Error',
        sessionSnapshot: _widgetSession(),
        api: ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'test-key',
          httpClient: _gateway(
            events: _sse([
              {'event': 'run.failed', 'error': 'provider unavailable'},
            ]),
            finalMessages: const [],
          ),
        ),
      );
      final failed = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.error,
      );

      await chat.send(fullText: 'hola', model: 'gpt-5.5', history: const []);
      await failed.timeout(const Duration(seconds: 5));
      await publisher.flush();

      expect(publisher.latest.agentState, HomeWidgetAgentState.error);
      expect(
        publisher.latest.connectionState,
        isNot(HomeWidgetConnectionState.disconnected),
      );
      service.dispose();
    });
  });

  group('ActiveChat — ciclo run con streaming', () {
    test(
      'reasoning, tools y respuesta final comparten un solo mensaje assistant',
      () async {
        final gateway = _AttachmentDesktopGateway();
        final chat = ActiveChat(
          compressionRestoreStore: testCompressionRestoreStore(),
          connection: _conn(id: 'conn-desktop-one-bubble'),
          sessionId: 'sess-desktop-one-bubble',
          sessionTitle: 'Un solo turno',
          notifications: null,
          onTerminal: () {},
          desktopGateway: gateway,
          terminalReconcileBudget: Duration.zero,
        )..smoothStreaming = false;
        addTearDown(chat.dispose);
        addTearDown(gateway.close);

        expect(
          await chat.send(
            fullText: 'Resuelve el problema',
            model: 'hermes-agent',
            history: const [],
          ),
          isTrue,
        );
        final done = chat.changes.firstWhere(
          (event) => event == ActiveChatEvent.done,
        );

        gateway.emit('reasoning.delta', const {'text': 'Primero '});
        gateway.emit('thinking.delta', const {'text': 'inspecciono. '});
        gateway.emit('reasoning.available', const {
          'text': 'Primero inspecciono. ',
        });
        gateway.emit('reasoning.delta', const {'text': 'Luego verifico.'});
        gateway.emit('tool.start', const {
          'tool_id': 'call-1',
          'name': 'read_file',
        });
        gateway.emit('tool.complete', const {
          'tool_id': 'call-1',
          'name': 'read_file',
        });
        gateway.emit('tool.start', const {
          'tool_id': 'call-2',
          'name': 'review_changes',
          'type': 'skill',
        });
        gateway.emit('tool.complete', const {
          'tool_id': 'call-2',
          'name': 'review_changes',
          'type': 'skill',
        });
        gateway.emit('message.delta', const {'text': 'Respuesta final.'});
        gateway.emit('message.complete', const {
          'text': 'Respuesta final.',
          'response_previewed': true,
        });
        await done.timeout(const Duration(seconds: 1));

        final assistants = chat.messages
            .where((message) => message['role'] == 'assistant')
            .toList(growable: false);
        expect(assistants, hasLength(1));
        expect(
          assistants.single['reasoning'],
          'Primero inspecciono. Luego verifico.',
        );
        expect(assistants.single['content'], 'Respuesta final.');
        final activity =
            assistants.single[assistantActivityTraceKey] as List<dynamic>;
        expect(activity.map((step) => step['kind']), [
          'reasoning',
          'tool',
          'skill',
        ]);
        expect(
          activity.map((step) => step['status']),
          everyElement('completed'),
        );
        expect(
          activity.where((step) => step['kind'] == 'reasoning').single['text'],
          'Primero inspecciono. Luego verifico.',
        );
      },
    );

    test(
      'colecciona intermedios y final una vez sin narrar tools ni logs',
      () async {
        final gateway = _AttachmentDesktopGateway();
        final chat = ActiveChat(
          compressionRestoreStore: testCompressionRestoreStore(),
          connection: _conn(id: 'conn-desktop-narration-order'),
          sessionId: 'sess-desktop-narration-order',
          sessionTitle: 'Narración Desktop',
          notifications: null,
          onTerminal: () {},
          desktopGateway: gateway,
          terminalReconcileBudget: Duration.zero,
        )..smoothStreaming = false;
        addTearDown(chat.dispose);
        addTearDown(gateway.close);

        final accepted = await chat.send(
          fullText: 'Revisa el proyecto',
          model: 'hermes-agent',
          history: const [],
        );
        expect(accepted, isTrue);

        Future<void> emitAndWait(
          String type,
          Map<String, dynamic> payload,
          ActiveChatEvent expected,
        ) async {
          final observed = chat.changes.firstWhere(
            (event) => event == expected,
          );
          gateway.emit(type, payload);
          await observed.timeout(const Duration(seconds: 1));
        }

        await emitAndWait('message.delta', const {
          'text': 'Voy a revisar los archivos.',
        }, ActiveChatEvent.token);
        await emitAndWait('message.interim', const {
          'text': 'Voy a revisar los archivos.',
        }, ActiveChatEvent.toolProgress);
        await emitAndWait('tool.start', const {
          'name': 'shell',
          'preview': 'rg --files /home/private',
        }, ActiveChatEvent.toolProgress);
        await emitAndWait('tool.complete', const {
          'name': 'shell',
          'result': 'TOKEN_TECNICO_SECRETO',
        }, ActiveChatEvent.toolProgress);
        final reasoningEvents = <ActiveChatEvent>[];
        final reasoningSubscription = chat.changes.listen(reasoningEvents.add);
        gateway.emit('message.delta', const {
          'text': 'RAZONAMIENTO_INTERNO',
          'channel': 'reasoning',
        });
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await reasoningSubscription.cancel();
        expect(reasoningEvents, isNot(contains(ActiveChatEvent.token)));
        await emitAndWait('message.delta', const {
          'text': ' No hay errores críticos.',
        }, ActiveChatEvent.token);
        await emitAndWait('message.complete', const {
          'text': 'Voy a revisar los archivos. No hay errores críticos.',
          'response_previewed': true,
        }, ActiveChatEvent.done);

        expect(
          chat.assistantNarrationContent,
          'Voy a revisar los archivos. No hay errores críticos.',
        );
        expect(
          RegExp(
            'Voy a revisar los archivos',
          ).allMatches(chat.assistantNarrationContent),
          hasLength(1),
        );
        expect(chat.assistantNarrationContent, isNot(contains('shell')));
        expect(
          chat.assistantNarrationContent,
          isNot(contains('TOKEN_TECNICO_SECRETO')),
        );
        expect(
          chat.assistantNarrationContent,
          isNot(contains('RAZONAMIENTO_INTERNO')),
        );
        expect(
          chat.assistantNarrationContent,
          isNot(contains('/home/private')),
        );
      },
    );

    test(
      'message.complete warning preserves final and requests durable reconciliation once',
      () async {
        final gateway = _AttachmentDesktopGateway();
        final requests = <Uri>[];
        final api = ApiClient(
          baseUrl: 'http://127.0.0.1:8642',
          apiKey: String.fromCharCodes(const [113, 97]),
          httpClient: MockClient((request) async {
            requests.add(request.url);
            return http.Response(
              jsonEncode({
                'object': 'list',
                'session_id': 'sess-warning-terminal',
                'messages': const [
                  {
                    'id': 'user-warning',
                    'message_id': 'user-warning',
                    'role': 'user',
                    'content': 'Revisa',
                  },
                  {
                    'id': 'assistant-warning',
                    'message_id': 'assistant-warning',
                    'role': 'assistant',
                    'content': 'Resultado visible',
                  },
                ],
                'pagination': const {
                  'limit': 500,
                  'offset': 0,
                  'order': 'latest',
                  'returned': 2,
                },
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }),
        );
        var terminalCalls = 0;
        final chat = ActiveChat(
          compressionRestoreStore: testCompressionRestoreStore(),
          connection: _conn(id: 'conn-warning-terminal'),
          sessionId: 'sess-warning-terminal',
          sessionTitle: 'Warning terminal',
          notifications: null,
          onTerminal: () => terminalCalls += 1,
          desktopGateway: gateway,
          api: api,
          terminalReconcileBudget: const Duration(seconds: 1),
        )..smoothStreaming = false;
        addTearDown(chat.dispose);
        addTearDown(gateway.close);
        final events = <ActiveChatEvent>[];
        final subscription = chat.changes.listen(events.add);
        addTearDown(subscription.cancel);

        expect(
          await chat.send(
            fullText: 'Revisa',
            model: 'hermes-agent',
            history: const [],
          ),
          isTrue,
        );
        final done = chat.changes.firstWhere(
          (event) => event == ActiveChatEvent.done,
        );
        final terminalSettled = chat.changes.firstWhere(
          (event) => event == ActiveChatEvent.messagesHydrated,
        );
        gateway.emit('message.complete', {
          'text': 'Resultado visible',
          'warning':
              'History changed while turn was running; '
              '${List.filled(40, 'history resynchronized').join(' ')}',
        });

        await done.timeout(const Duration(seconds: 2));
        await terminalSettled.timeout(const Duration(seconds: 2));

        expect(chat.assistantContent, 'Resultado visible');
        expect(events.where((event) => event.name == 'warning'), hasLength(1));
        final warning = (chat as dynamic).takeTerminalWarning() as String?;
        expect(warning, isNotNull);
        expect(warning!.length, lessThanOrEqualTo(240));
        expect(warning, contains('History changed'));
        expect(terminalCalls, 1);
        expect(requests, isNotEmpty);
        expect(requests.first.queryParameters, containsPair('limit', '500'));
        expect(
          requests.first.queryParameters,
          containsPair('include_compacted', 'true'),
        );
        expect(chat.messages.first['content'], 'Resultado visible');
      },
    );

    test(
      'Desktop conserva final, interim y usuario en orden sin duplicados',
      () async {
        final gateway = _AttachmentDesktopGateway();
        final chat = ActiveChat(
          compressionRestoreStore: testCompressionRestoreStore(),
          connection: _conn(id: 'conn-desktop-transcript-order'),
          sessionId: 'sess-desktop-transcript-order',
          sessionTitle: 'Orden Desktop',
          notifications: null,
          onTerminal: () {},
          desktopGateway: gateway,
          terminalReconcileBudget: Duration.zero,
        )..smoothStreaming = false;
        addTearDown(chat.dispose);
        addTearDown(gateway.close);

        final accepted = await chat.send(
          fullText: 'Revisa el proyecto',
          model: 'hermes-agent',
          history: const [],
        );
        expect(accepted, isTrue);

        Future<void> emitAndWait(
          String type,
          Map<String, dynamic> payload,
          ActiveChatEvent expected,
        ) async {
          final observed = chat.changes.firstWhere(
            (event) => event == expected,
          );
          gateway.emit(type, payload);
          await observed.timeout(const Duration(seconds: 1));
        }

        await emitAndWait('message.delta', const {
          'text': 'Preparando la revisión.',
        }, ActiveChatEvent.token);
        await emitAndWait('message.interim', const {
          'text': 'Voy a revisar los archivos.',
        }, ActiveChatEvent.toolProgress);
        await emitAndWait('tool.start', const {
          'name': 'shell',
          'preview': 'rg --files',
        }, ActiveChatEvent.toolProgress);
        await emitAndWait('message.delta', const {
          'text': 'La revisión ha terminado.',
        }, ActiveChatEvent.token);
        await emitAndWait('message.complete', const {
          'text': 'Resumen final del proyecto.',
        }, ActiveChatEvent.done);

        final transcript = chat.messages
            .map(
              (message) => (role: message['role'], content: message['content']),
            )
            .toList(growable: false);
        expect(transcript, const [
          (
            role: 'assistant',
            content:
                'Voy a revisar los archivos.\n\nResumen final del proyecto.',
          ),
          (role: 'user', content: 'Revisa el proyecto'),
        ]);
      },
    );

    test(
      'handshake Desktop rechazado libera el canal y cae a /v1/runs',
      () async {
        final hits = <String>[];
        final httpClient = MockClient((request) async {
          hits.add('${request.method} ${request.url.path}');
          if (request.method == 'POST' && request.url.path == '/v1/runs') {
            return http.Response(jsonEncode({'run_id': 'run-fallback'}), 202);
          }
          if (request.method == 'GET' &&
              request.url.path == '/v1/runs/run-fallback/events') {
            return http.Response(
              _sse([
                {'event': 'message.delta', 'delta': 'Fallback listo'},
                {'event': 'run.completed', 'output': 'Fallback listo'},
              ]),
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/sessions/sess-legacy/messages') {
            return http.Response(
              jsonEncode({
                'data': [
                  {'role': 'user', 'content': 'hola'},
                  {'role': 'assistant', 'content': 'Fallback listo'},
                ],
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        });
        final connection = _conn(id: 'conn-legacy');
        final blockedChannel = _TeardownTestWebSocketChannel(
          readyError: StateError('HTTP 401'),
          blockTeardown: true,
        );
        final fallbackChannel = _TeardownTestWebSocketChannel(
          blockTeardown: false,
        );
        final fallbackChannelCreated = Completer<void>();
        var channelFactoryCalls = 0;
        final desktop = TuiGatewayClient(
          connection,
          dashboard: _StaticWebSocketAuthDashboardClient(),
          channelFactory: (_, _) {
            channelFactoryCalls++;
            if (channelFactoryCalls == 1) return blockedChannel;
            if (!fallbackChannelCreated.isCompleted) {
              fallbackChannelCreated.complete();
            }
            return fallbackChannel;
          },
        );
        final chat = ActiveChat(
          compressionRestoreStore: testCompressionRestoreStore(),
          connection: connection,
          sessionId: 'sess-legacy',
          sessionTitle: 'Legacy',
          notifications: null,
          onTerminal: () {},
          api: ApiClient(
            baseUrl: connection.baseUrl,
            apiKey: connection.apiKey,
            httpClient: httpClient,
          ),
          desktopGateway: desktop,
        );
        addTearDown(chat.dispose);
        final done = Completer<void>();
        final changes = chat.changes.listen((event) {
          if (event == ActiveChatEvent.done && !done.isCompleted) {
            done.complete();
          }
        });
        addTearDown(changes.cancel);

        final accepted = await chat
            .send(fullText: 'hola', model: 'hermes-demo', history: const [])
            .timeout(const Duration(milliseconds: 1500));
        await done.future.timeout(const Duration(seconds: 3));

        expect(accepted, isTrue);
        expect(hits, contains('POST /v1/runs'));
        expect(chat.assistantContent, 'Fallback listo');
        expect(blockedChannel._sink.closeStarted.isCompleted, isTrue);
        expect(blockedChannel.cancelStarted.isCompleted, isTrue);

        // La conexión fallida no puede conservar `_connecting`: un segundo
        // intento debe usar un canal nuevo inmediatamente.
        var reconnectCompleted = false;
        final reconnect = desktop.connect().whenComplete(() {
          reconnectCompleted = true;
        });
        await fallbackChannelCreated.future;
        expect(channelFactoryCalls, 2);
        expect(reconnectCompleted, isFalse);
        fallbackChannel.emitGatewayReady();
        await reconnect;
        expect(desktop.isConnected, isTrue);
      },
    );

    test('mide submit hasta el primer contenido una sola vez', () async {
      var nowMicros = 1000000;
      final observed = <int?>[];
      final api = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'test-key',
        httpClient: _gateway(
          beforeEvents: () => nowMicros = 1840000,
          events: _sse([
            {'event': 'message.delta', 'delta': 'Hola'},
            {'event': 'message.delta', 'delta': ' mundo'},
            {'event': 'run.completed', 'output': 'Hola mundo'},
          ]),
          finalMessages: const [
            {'role': 'user', 'content': 'di hola'},
            {'role': 'assistant', 'content': 'Hola mundo'},
          ],
        ),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(),
        sessionId: 'sess-1',
        sessionTitle: 'TTFT',
        notifications: null,
        onTerminal: () {},
        api: api,
        monotonicMicros: () => nowMicros,
        onObservedFirstTokenLatency: observed.add,
      );
      final done = chat.changes.firstWhere((e) => e == ActiveChatEvent.done);
      final metricsChanged = chat.changes.firstWhere(
        (e) => e == ActiveChatEvent.responseMetrics,
      );

      chat.send(fullText: 'di hola', model: 'm', history: const []);
      await metricsChanged.timeout(const Duration(seconds: 5));
      await done.timeout(const Duration(seconds: 5));

      expect(chat.observedFirstTokenLatencyMs, 840);
      expect(observed, [null, 840]);
      chat.dispose();
    });

    test('una ráfaga grande se publica completa en un único batch', () async {
      const response =
          '## Título **importante**\n\n'
          '- lista estable\n'
          '- café e\u0301 👩‍💻';
      final api = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'test-key',
        httpClient: _gateway(
          events: _sse([
            {'event': 'message.delta', 'delta': response},
            {'event': 'run.completed', 'output': response},
          ]),
          finalMessages: [
            {'role': 'user', 'content': 'responde'},
            {'role': 'assistant', 'content': response},
          ],
        ),
      );
      final service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      final chat = service.attach(
        connection: _conn(id: 'conn-smooth'),
        sessionId: 'sess-1',
        sessionTitle: 'Suave',
        api: api,
      );
      chat.smoothStreaming = true;
      final revealedLengths = <int>[];
      final completed = Completer<void>();
      final sub = chat.changes.listen((event) {
        if (event == ActiveChatEvent.token) {
          revealedLengths.add(chat.assistantContent.length);
        }
        if (event == ActiveChatEvent.done && !completed.isCompleted) {
          completed.complete();
        }
      });

      chat.send(fullText: 'responde', model: 'hermes-agent', history: const []);
      await completed.future.timeout(const Duration(seconds: 5));

      expect(
        revealedLengths.every((length) => length == response.length),
        isTrue,
        reason:
            'si el mock entrega delta y terminal en la misma microtarea puede '
            'colapsarlos; cualquier batch visible debe ser el delta completo',
      );
      expect(chat.assistantContent, response);
      await sub.cancel();
      service.dispose();
    });

    test(
      'reduce-motion vuelca cada delta sin animación de caracteres',
      () async {
        const response = 'Respuesta sin animacion';
        final api = ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'test-key',
          httpClient: _gateway(
            events: _sse([
              {'event': 'message.delta', 'delta': response},
              {'event': 'run.completed', 'output': response},
            ]),
            finalMessages: const [
              {'role': 'user', 'content': 'responde'},
              {'role': 'assistant', 'content': response},
            ],
          ),
        );
        final service = ActiveChatService(
          compressionRestoreStore: testCompressionRestoreStore(),
        );
        final chat = service.attach(
          connection: _conn(id: 'conn-reduce-motion'),
          sessionId: 'sess-1',
          sessionTitle: 'Sin animación',
          api: api,
        );
        chat.smoothStreaming = false;
        final lengths = <int>[];
        final sub = chat.changes.listen((event) {
          if (event == ActiveChatEvent.token) {
            lengths.add(chat.assistantContent.length);
          }
        });
        final done = chat.changes.firstWhere((e) => e == ActiveChatEvent.done);

        chat.send(
          fullText: 'responde',
          model: 'hermes-agent',
          history: const [],
        );
        await done.timeout(const Duration(seconds: 5));

        expect(lengths, [response.length]);
        await sub.cancel();
        service.dispose();
      },
    );

    test(
      'send → tokens → run.completed refresca mensajes sin vigilancia diferida',
      () async {
        final hits = <String>[];
        final api = ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'test-key',
          httpClient: _gateway(
            hitLog: hits,
            events: _sse([
              {'event': 'message.delta', 'delta': 'Hola'},
              {'event': 'message.delta', 'delta': ' mundo'},
              {'event': 'run.completed', 'output': 'Hola mundo'},
            ]),
            finalMessages: [
              {'role': 'user', 'content': 'di hola'},
              {'role': 'assistant', 'content': 'Hola mundo'},
            ],
          ),
        );

        final service = ActiveChatService(
          compressionRestoreStore: testCompressionRestoreStore(),
        );
        final chat = service.attach(
          connection: _conn(),
          sessionId: 'sess-1',
          sessionTitle: 'Saludo',
          api: api,
        );

        final done = chat.changes.firstWhere((e) => e == ActiveChatEvent.done);

        chat.send(
          fullText: 'di hola',
          model: 'hermes-agent',
          history: const [],
        );

        // En la candidata conservadora no se persiste vigilancia automática.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final prefsMid = await SharedPreferences.getInstance();
        await prefsMid.reload();
        expect(
          prefsMid.getString(_kWatchKey),
          anyOf(isNull, equals('[]')),
          reason: '1.2.8 difiere la vigilancia automática',
        );

        await done.timeout(const Duration(seconds: 5));

        // Estado final: mensajes refrescados desde el servidor, pipeline cerrado.
        expect(chat.state, ChatPipelineState.completed);
        expect(chat.messages.first['role'], 'assistant');
        expect(chat.messages.first['content'], 'Hola mundo');
        expect(hits, contains('GET /api/sessions/sess-1/messages'));

        // La limpieza terminal (_onTerminal) ocurre ~800ms tras `done`; esperamos
        // a que la vigilancia en 2º plano se retire (no debe acumular runs).
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        final prefsEnd = await SharedPreferences.getInstance();
        await prefsEnd.reload();
        final raw = prefsEnd.getString(_kWatchKey) ?? '[]';
        expect(
          raw.contains('run_1'),
          isFalse,
          reason: 'al terminar debe dejar de vigilarse el run',
        );

        service.dispose();
      },
    );

    test(
      'un 404 terminal transitorio conserva el chat y reconcilia después',
      () async {
        var messageReads = 0;
        final firstReadStarted = Completer<void>();
        final releaseFirstRead = Completer<void>();
        final secondReadStarted = Completer<void>();
        final httpClient = MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'POST' && path == '/v1/runs') {
            return http.Response(jsonEncode({'run_id': 'run_1'}), 200);
          }
          if (request.method == 'GET' && path == '/v1/runs/run_1/events') {
            return http.Response(
              _sse([
                {'event': 'message.delta', 'delta': 'Respuesta por streaming'},
                {'event': 'run.completed', 'output': 'Respuesta por streaming'},
              ]),
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          if (request.method == 'GET' &&
              path == '/api/sessions/sess-1/messages') {
            messageReads++;
            if (messageReads == 1) {
              firstReadStarted.complete();
              await releaseFirstRead.future;
              return http.Response('not found', 404);
            }
            if (!secondReadStarted.isCompleted) secondReadStarted.complete();
            return http.Response(
              jsonEncode({
                'data': [
                  {'role': 'user', 'content': 'consulta'},
                  {'role': 'assistant', 'content': 'Respuesta persistida'},
                ],
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        });
        final service = ActiveChatService(
          compressionRestoreStore: testCompressionRestoreStore(),
        );
        final chat = service.attach(
          connection: _conn(id: 'conn-terminal-race'),
          sessionId: 'sess-1',
          sessionTitle: 'Carrera terminal',
          api: ApiClient(
            baseUrl: 'http://hermes.local:8642',
            apiKey: 'test-key',
            httpClient: httpClient,
          ),
        );
        final firstDone = chat.changes.firstWhere(
          (event) => event == ActiveChatEvent.done,
        );

        await chat.send(
          fullText: 'consulta',
          model: 'hermes-agent',
          history: const [],
        );
        await firstDone.timeout(const Duration(seconds: 3));
        expect(chat.assistantContent, 'Respuesta por streaming');
        await firstReadStarted.future;
        expect(messageReads, 1);
        releaseFirstRead.complete();
        await secondReadStarted.future;
        expect(messageReads, 2);
        await _waitFor(() => chat.assistantContent == 'Respuesta persistida');
        expect(chat.assistantContent, 'Respuesta persistida');
        service.dispose();
      },
    );
  });

  group('ActiveChat — política de aprobaciones (YOLO se aplica en el chat)', () {
    Future<ApprovalPolicyService> policyWith(ApprovalMode mode) async {
      final prefs = await SharedPreferences.getInstance();
      final policy = ApprovalPolicyService(prefs);
      await policy.setGlobalMode(mode);
      return policy;
    }

    ActiveChat chatWithPolicy(
      ApprovalPolicyService policy, {
      required String events,
      List<String>? hits,
    }) {
      final api = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'k',
        httpClient: _gateway(
          hitLog: hits,
          events: events,
          finalMessages: const [
            {'role': 'assistant', 'content': 'ok'},
          ],
        ),
      );
      return ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(),
        sessionId: 'sess-1',
        sessionTitle: 'X',
        notifications: null,
        onTerminal: () {},
        policy: policy,
        api: api,
      );
    }

    test('YOLO auto-aprueba sin tarjeta ni notificación', () async {
      final policy = await policyWith(ApprovalMode.yolo);
      final hits = <String>[];
      final chat = chatWithPolicy(
        policy,
        hits: hits,
        events: _sse([
          {
            'event': 'approval.request',
            'request_id': 'request-yolo',
            'command': 'ls -la',
            'pattern_key': 'ls',
          },
          {'event': 'run.completed', 'output': 'ok'},
        ]),
      );
      final events = <ActiveChatEvent>[];
      chat.changes.listen(events.add);

      chat.send(fullText: 'lista', model: 'm', history: const []);
      await chat.changes
          .firstWhere((e) => e == ActiveChatEvent.done)
          .timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        hits,
        contains('POST /v1/runs/run_1/approval'),
        reason: 'YOLO debe resolver la aprobación automáticamente',
      );
      expect(
        events.contains(ActiveChatEvent.approvalRequest),
        isFalse,
        reason: 'YOLO no debe mostrar la tarjeta de aprobación',
      );
      expect(chat.pendingApproval, isNull);
      chat.dispose();
    });

    test(
      'YOLO resuelve A por request_id sin borrar B que llega durante el await',
      () async {
        final policy = await policyWith(ApprovalMode.yolo);
        final race = _ApprovalRaceClient();
        final api = ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'k',
          httpClient: race,
        );
        final chat = ActiveChat(
          compressionRestoreStore: testCompressionRestoreStore(),
          connection: _conn(),
          sessionId: 'sess-1',
          sessionTitle: 'X',
          notifications: null,
          onTerminal: () {},
          policy: policy,
          api: api,
        );
        addTearDown(chat.dispose);

        chat.send(fullText: 'lista', model: 'm', history: const []);
        await _waitFor(() => chat.currentRunId == 'run_1');
        race.emit(const {
          'event': 'approval.request',
          'request_id': 'request-a',
          'command': 'ls a',
        });
        race.emit(const {
          'event': 'approval.request',
          'request_id': 'request-b',
          'command': 'ls b',
        });
        await _waitFor(() => race.approvalBodies.length == 2);
        expect(race.approvalBodies.map((body) => body['request_id']), [
          'request-a',
          'request-b',
        ]);
        expect(chat.pendingApproval?['request_id'], 'request-b');

        race.releaseA.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(chat.pendingApproval?['request_id'], 'request-b');
        race.releaseB.complete();
      },
    );

    test('solo lectura resuelve exactamente el request recibido', () async {
      final policy = await policyWith(ApprovalMode.readOnly);
      Map<String, dynamic>? approvalBody;
      final api = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'k',
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path == '/v1/runs') {
            return http.Response(jsonEncode({'run_id': 'run_1'}), 200);
          }
          if (request.method == 'GET' &&
              request.url.path == '/v1/runs/run_1/events') {
            return http.Response(
              _sse(const [
                {
                  'event': 'approval.request',
                  'request_id': 'request-read-only',
                  'command': 'rm x',
                },
              ]),
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/v1/runs/run_1/approval') {
            approvalBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('{}', 404);
        }),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(),
        sessionId: 'sess-1',
        sessionTitle: 'X',
        notifications: null,
        onTerminal: () {},
        policy: policy,
        api: api,
      );
      addTearDown(chat.dispose);

      chat.send(fullText: 'borra', model: 'm', history: const []);
      await _waitFor(() => approvalBody != null);
      expect(approvalBody, {
        'choice': 'deny',
        'request_id': 'request-read-only',
      });
    });

    test(
      'Preguntar (interactive) muestra la tarjeta y NO auto-resuelve',
      () async {
        final policy = await policyWith(ApprovalMode.interactive);
        final hits = <String>[];
        final chat = chatWithPolicy(
          policy,
          hits: hits,
          events: _sse([
            {
              'event': 'approval.request',
              'request_id': 'request-interactive',
              'command': 'rm archivo',
              'pattern_key': 'rm',
            },
          ]),
        );
        final events = <ActiveChatEvent>[];
        chat.changes.listen(events.add);

        chat.send(fullText: 'borra', model: 'm', history: const []);
        await chat.changes
            .firstWhere((e) => e == ActiveChatEvent.approvalRequest)
            .timeout(const Duration(seconds: 5));

        expect(
          hits.any((h) => h.contains('/approval')),
          isFalse,
          reason: 'modo Preguntar no debe auto-resolver',
        );
        expect(chat.pendingApproval, isNotNull);
        chat.dispose();
      },
    );

    test(
      'la aprobación del id persistido sigue perteneciendo al chat visible',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final policy = ApprovalPolicyService(prefs);
        await policy.setGlobalMode(ApprovalMode.interactive);
        final notifications = NotificationService(prefs)
          ..appInForeground = true
          ..visibleSessionId = 'sess-persistida';
        final inAppNotices = <InAppNotice>[];
        final noticeSub = notifications.inAppNotices.listen(inAppNotices.add);
        final api = ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'k',
          httpClient: _gateway(
            events: _sse([
              {
                'event': 'approval.request',
                'request_id': 'request-visible',
                'command': 'curl ejemplo.test',
                'pattern_key': 'curl',
              },
            ]),
            finalMessages: const [],
          ),
        );
        final chat = ActiveChat(
          compressionRestoreStore: testCompressionRestoreStore(),
          connection: _conn(),
          sessionId: 'mob-provisional',
          sessionTitle: 'Noticias',
          notifications: notifications,
          onTerminal: () {},
          policy: policy,
          api: api,
        );

        chat.send(
          fullText: 'busca noticias',
          model: 'm',
          history: const [],
          serverSessionId: 'sess-persistida',
        );
        await chat.changes
            .firstWhere((e) => e == ActiveChatEvent.approvalRequest)
            .timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(chat.serverSessionId, 'sess-persistida');
        expect(
          inAppNotices,
          isEmpty,
          reason:
              'la aprobación del chat visible no puede desviarse al banner '
              'de "otro chat"',
        );
        await noticeSub.cancel();
        chat.dispose();
      },
    );

    test('Solo lectura deniega automáticamente', () async {
      final policy = await policyWith(ApprovalMode.readOnly);
      final hits = <String>[];
      final chat = chatWithPolicy(
        policy,
        hits: hits,
        events: _sse([
          {
            'event': 'approval.request',
            'request_id': 'request-read-only-old',
            'command': 'rm x',
            'pattern_key': 'rm',
          },
          {'event': 'run.completed', 'output': 'ok'},
        ]),
      );
      final events = <ActiveChatEvent>[];
      chat.changes.listen(events.add);

      chat.send(fullText: 'borra', model: 'm', history: const []);
      await chat.changes
          .firstWhere((e) => e == ActiveChatEvent.done)
          .timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(hits, contains('POST /v1/runs/run_1/approval'));
      expect(events.contains(ActiveChatEvent.approvalRequest), isFalse);
      expect(chat.pendingApproval, isNull);
      chat.dispose();
    });
  });

  group('ActiveChat.reconcileAfterResume', () {
    ActiveChat chatWith(List<Map<String, dynamic>> serverMessages) {
      final api = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'k',
        httpClient: _gateway(events: '', finalMessages: serverMessages),
      );
      return ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(),
        sessionId: 'sess-1',
        sessionTitle: 'X',
        notifications: null,
        onTerminal: () {},
        api: api,
      );
    }

    ActiveChat chatWithLoader(StoredSessionMessageLoader loader) {
      final api = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      );
      return ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(),
        sessionId: 'sess-1',
        sessionTitle: 'X',
        sessionProfile: 'default',
        notifications: null,
        onTerminal: () {},
        api: api,
        storedMessageLoader: loader,
      );
    }

    test(
      'RED-A consulta un tail assistant final y adopta un turno externo una vez',
      () async {
        var serverMessages = <Map<String, dynamic>>[
          {'message_id': 'user-1', 'role': 'user', 'content': 'Primer turno'},
          {
            'message_id': 'assistant-1',
            'role': 'assistant',
            'content': 'Primera respuesta',
          },
        ];
        var reads = 0;
        final chat = chatWithLoader((sessionId, profile) async {
          expect(sessionId, 'sess-1');
          expect(profile, 'default');
          reads += 1;
          return serverMessages;
        });
        addTearDown(chat.dispose);

        await chat.loadMessages(profile: 'default');
        chat.state = ChatPipelineState.completed;
        reads = 0;
        final events = <ActiveChatEvent>[];
        final subscription = chat.changes.listen(events.add);
        addTearDown(subscription.cancel);

        serverMessages = <Map<String, dynamic>>[
          ...serverMessages,
          {'message_id': 'user-2', 'role': 'user', 'content': 'Turno externo'},
          {
            'message_id': 'assistant-2',
            'role': 'assistant',
            'content': 'Respuesta externa',
          },
        ];

        final changed = await chat.reconcileAfterResume();
        await Future<void>.delayed(Duration.zero);

        expect(changed, isTrue);
        expect(reads, 1);
        expect(
          chat.messages.where(
            (message) => message['content'] == 'Turno externo',
          ),
          hasLength(1),
        );
        expect(
          chat.messages.where(
            (message) => message['content'] == 'Respuesta externa',
          ),
          hasLength(1),
        );
        expect(
          events.where((event) => event == ActiveChatEvent.messagesHydrated),
          hasLength(1),
        );
      },
    );

    test(
      'RED-D el servicio retenido converge como una instancia nueva y es idempotente',
      () async {
        var serverMessages = <Map<String, dynamic>>[
          {
            'message_id': 'cached-user-1',
            'role': 'user',
            'content': 'Turno cacheado',
          },
          {
            'message_id': 'cached-assistant-1',
            'role': 'assistant',
            'content': 'Respuesta cacheada',
          },
        ];
        var retainedReads = 0;
        Future<List<Map<String, dynamic>>> retainedLoader(
          String sessionId,
          String profile,
        ) async {
          retainedReads += 1;
          return serverMessages;
        }

        ActiveChat attach(
          ActiveChatService service,
          StoredSessionMessageLoader loader,
        ) => service.attach(
          connection: _conn(id: 'resume-cache-connection'),
          sessionId: 'resume-cache-session',
          sessionTitle: 'Resume cache',
          sessionProfile: 'default',
          api: ApiClient(
            baseUrl: 'http://hermes.local:8642',
            apiKey: 'k',
            httpClient: MockClient(
              (_) async => http.Response('not found', 404),
            ),
          ),
          storedMessageLoader: loader,
          disableForegroundKeepAlive: true,
        );

        final retainedService = ActiveChatService();
        final freshService = ActiveChatService();
        addTearDown(retainedService.dispose);
        addTearDown(freshService.dispose);
        final retained = attach(retainedService, retainedLoader);
        await retained.loadMessages(profile: 'default');
        retained.state = ChatPipelineState.completed;
        retainedReads = 0;

        serverMessages = <Map<String, dynamic>>[
          ...serverMessages,
          {
            'message_id': 'cached-user-2',
            'role': 'user',
            'content': 'Turno durable externo',
          },
          {
            'message_id': 'cached-assistant-2',
            'role': 'assistant',
            'content': 'Terminal durable externo',
          },
        ];
        final fresh = attach(freshService, (_, _) async => serverMessages);
        await fresh.loadMessages(profile: 'default');

        await retainedService.reconcileAfterResume();

        final reattached = attach(retainedService, retainedLoader);
        expect(reattached, same(retained));
        expect(retained.messages, fresh.messages);
        expect(retainedReads, 1);

        await retainedService.reconcileAfterResume();

        expect(retainedReads, 2);
        expect(retained.messages, fresh.messages);
        expect(
          retained.messages.where(
            (message) => message['content'] == 'Terminal durable externo',
          ),
          hasLength(1),
        );
      },
    );

    test('re-sincroniza un turno a medias (placeholder sin cerrar)', () async {
      final chat = chatWith([
        {'role': 'user', 'content': 'hola'},
        {'role': 'assistant', 'content': 'respuesta completa del servidor'},
      ]);
      // Simula el estado tras volver de 2º plano con el SSE cortado: burbuja
      // del asistente vacía en pipeline.
      chat.internalMessagesForTesting = [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {'role': 'user', 'content': 'hola'},
      ];
      chat.state = ChatPipelineState.idle;

      final changed = await chat.reconcileAfterResume();

      expect(changed, isTrue);
      expect(chat.messages.first['role'], 'assistant');
      expect(chat.messages.first['content'], 'respuesta completa del servidor');
      expect(chat.state, ChatPipelineState.completed);
      chat.dispose();
    });

    test(
      'reapertura hidrata el final que llegó después de una cola de tools',
      () async {
        final chat = chatWith([
          {'role': 'user', 'content': 'busca las noticias'},
          {
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'search-call',
                'function': {'name': 'web_search', 'arguments': '{}'},
              },
            ],
          },
          {
            'role': 'tool',
            'tool_call_id': 'search-call',
            'content': 'resultados encontrados',
          },
          {
            'role': 'assistant',
            'content': 'Aquí tienes las noticias completas.',
          },
        ]);
        // La app se cerró cuando el transcript durable todavía acababa en la
        // herramienta. Al volver no queda placeholder assistant en cabeza: la
        // proyección visible termina en `tool`, aunque el servidor ya publicó
        // después la respuesta final.
        chat.internalMessagesForTesting = [
          {
            'role': 'tool',
            'tool_call_id': 'search-call',
            'content': 'resultados encontrados',
          },
          {
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'search-call',
                'function': {'name': 'web_search', 'arguments': '{}'},
              },
            ],
          },
          {'role': 'user', 'content': 'busca las noticias'},
        ];
        chat.state = ChatPipelineState.completed;

        final changed = await chat.reconcileAfterResume();

        expect(changed, isTrue);
        expect(chat.messages.first['role'], 'assistant');
        expect(
          chat.messages.first['content'],
          'Aquí tienes las noticias completas.',
        );
        chat.dispose();
      },
    );

    test('reapertura conserva un turno canónico realmente tool-only', () async {
      final serverMessages = [
        <String, dynamic>{
          'message_id': 'canonical-tool-user',
          'role': 'user',
          'content': 'ejecuta la herramienta',
        },
        <String, dynamic>{
          'message_id': 'canonical-tool-result',
          'role': 'tool',
          'name': 'status',
          'content': 'ok',
        },
      ];
      final chat = chatWith(serverMessages);
      chat.internalMessagesForTesting = serverMessages.reversed
          .map(Map<String, dynamic>.of)
          .toList(growable: false);
      chat.state = ChatPipelineState.completed;
      final before = chat.internalMessagesForTesting;

      final changed = await chat.reconcileAfterResume();

      expect(changed, isTrue);
      expect(chat.internalMessagesForTesting, isNot(same(before)));
      expect(chat.internalMessagesForTesting.first['role'], 'assistant');
      final activity =
          chat.internalMessagesForTesting.first[assistantActivityTraceKey]
              as List<dynamic>;
      expect(activity, hasLength(1));
      expect(activity.single['status'], 'completed');
      chat.dispose();
    });

    test(
      'reapertura sustituye el placeholder por un terminal tool-only',
      () async {
        final chat = chatWith([
          {
            'message_id': 'placeholder-tool-user',
            'role': 'user',
            'content': 'consulta el estado',
          },
          {
            'message_id': 'placeholder-tool-result',
            'role': 'tool',
            'name': 'status',
            'content': 'ok',
          },
        ]);
        chat.internalMessagesForTesting = [
          {'role': 'assistant', 'content': '', '_pipeline': true},
          {'role': 'user', 'content': 'consulta el estado'},
        ];
        chat.state = ChatPipelineState.idle;

        final changed = await chat.reconcileAfterResume();

        expect(changed, isTrue);
        expect(chat.messages.first['role'], 'assistant');
        expect(chat.messages.first['content'], isEmpty);
        final activity =
            chat.messages.first[assistantActivityTraceKey] as List<dynamic>;
        expect(activity, hasLength(1));
        expect(activity.single['status'], 'completed');
        expect(chat.messages.toString(), isNot(contains('ok')));
        expect(
          chat.messages.any((message) => message['_pipeline'] == true),
          isFalse,
        );
        expect(chat.state, ChatPipelineState.completed);
        chat.dispose();
      },
    );

    test('no toca un chat ya finalizado correctamente', () async {
      final chat = chatWith([
        {'role': 'assistant', 'content': 'OTRO contenido del servidor'},
      ]);
      chat.internalMessagesForTesting = [
        {'role': 'assistant', 'content': 'respuesta ya recibida'},
        {'role': 'user', 'content': 'hola'},
      ];
      chat.state = ChatPipelineState.completed;

      final changed = await chat.reconcileAfterResume();

      expect(changed, isFalse);
      expect(chat.messages.first['content'], 'respuesta ya recibida');
      chat.dispose();
    });

    test('no toca un chat con stream vivo', () async {
      final chat = chatWith([
        {'role': 'assistant', 'content': 'no debería usarse'},
      ]);
      chat.internalMessagesForTesting = [
        {'role': 'assistant', 'content': '', '_pipeline': true},
      ];
      chat.state = ChatPipelineState.streaming; // vivo

      final changed = await chat.reconcileAfterResume();

      expect(changed, isFalse);
      expect(chat.state, ChatPipelineState.streaming);
      chat.dispose();
    });

    test('GET de resume obsoleto no borra un turno enviado después', () async {
      final getStarted = Completer<void>();
      final oldGet = Completer<http.Response>();
      final streamGate = Completer<http.Response>();
      final api = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'k',
        httpClient: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path.endsWith('/messages')) {
            if (!getStarted.isCompleted) getStarted.complete();
            return oldGet.future;
          }
          if (request.method == 'POST' && request.url.path == '/v1/runs') {
            return http.Response(
              jsonEncode({'run_id': 'run-after-resume'}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path.endsWith('/events')) return streamGate.future;
          return http.Response('not found', 404);
        }),
      );
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _conn(),
        sessionId: 'resume-race',
        sessionTitle: 'Resume race',
        notifications: null,
        onTerminal: () {},
        api: api,
      );
      addTearDown(() {
        if (!streamGate.isCompleted) {
          streamGate.complete(http.Response('', 200));
        }
        chat.dispose();
      });
      chat.internalMessagesForTesting = [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {'role': 'user', 'content': 'turno anterior'},
      ];
      chat.state = ChatPipelineState.idle;

      final staleResume = chat.reconcileAfterResume();
      await getStarted.future;
      unawaited(
        chat.send(
          fullText: 'turno nuevo que debe sobrevivir',
          model: 'm',
          history: const [],
        ),
      );
      while (!chat.isStreaming) {
        await Future<void>.delayed(Duration.zero);
      }
      oldGet.complete(
        http.Response(
          jsonEncode({
            'data': [
              {'role': 'user', 'content': 'turno anterior'},
              {'role': 'assistant', 'content': 'respuesta antigua'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      expect(await staleResume, isFalse);
      expect(
        chat.messages.any(
          (message) => message['content'] == 'turno nuevo que debe sobrevivir',
        ),
        isTrue,
      );
      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta antigua',
        ),
        isFalse,
      );
    });
  });

  group('ActiveChatService durable session invalidation', () {
    test(
      'RED-B1 matches connection profile and session and coalesces one flight',
      () async {
        final service = ActiveChatService();
        addTearDown(service.dispose);
        final reads = <String, int>{};
        final transcripts = <String, List<Map<String, dynamic>>>{};
        Completer<List<Map<String, dynamic>>>? targetGate;

        ActiveChat attach({
          required String connectionId,
          required String sessionId,
          required String logicalSessionId,
          required String profile,
        }) {
          final key = '$connectionId/$profile/$sessionId';
          transcripts[key] = <Map<String, dynamic>>[
            {
              'message_id': '$key-user-1',
              'role': 'user',
              'content': 'Pregunta de $key',
            },
            {
              'message_id': '$key-assistant-1',
              'role': 'assistant',
              'content': 'Respuesta de $key',
            },
          ];
          return service.attach(
            connection: _conn(id: connectionId),
            sessionId: sessionId,
            logicalSessionId: logicalSessionId,
            sessionTitle: key,
            sessionProfile: profile,
            api: ApiClient(
              baseUrl: 'http://hermes.local:8642',
              apiKey: 'k',
              httpClient: MockClient(
                (_) async => http.Response('not found', 404),
              ),
            ),
            storedMessageLoader: (_, _) async {
              reads[key] = (reads[key] ?? 0) + 1;
              if (key == 'invalidate-conn/profile-a/target-session' &&
                  targetGate != null) {
                return targetGate.future;
              }
              return transcripts[key]!;
            },
            disableForegroundKeepAlive: true,
          );
        }

        final target = attach(
          connectionId: 'invalidate-conn',
          sessionId: 'target-session',
          logicalSessionId: 'target-root',
          profile: 'profile-a',
        );
        final otherSession = attach(
          connectionId: 'invalidate-conn',
          sessionId: 'other-session',
          logicalSessionId: 'other-root',
          profile: 'profile-a',
        );
        final otherProfile = attach(
          connectionId: 'invalidate-conn',
          sessionId: 'target-session',
          logicalSessionId: 'target-root',
          profile: 'profile-b',
        );
        final otherConnection = attach(
          connectionId: 'other-conn',
          sessionId: 'target-session',
          logicalSessionId: 'target-root',
          profile: 'profile-a',
        );
        for (final chat in [
          target,
          otherSession,
          otherProfile,
          otherConnection,
        ]) {
          await chat.loadMessages(profile: chat.sessionProfile);
          chat.state = ChatPipelineState.completed;
        }
        reads.updateAll((_, _) => 0);

        targetGate = Completer<List<Map<String, dynamic>>>();
        final first = service.invalidateDurableSession(
          connectionId: 'invalidate-conn',
          profile: 'profile-a',
          sessionId: 'target-session',
          logicalSessionId: 'target-root',
        );
        final coalesced = service.invalidateDurableSession(
          connectionId: 'invalidate-conn',
          profile: 'profile-a',
          sessionId: 'target-session',
          logicalSessionId: 'target-root',
        );
        await _waitFor(
          () => reads['invalidate-conn/profile-a/target-session'] == 1,
        );

        expect(
          await service.invalidateDurableSession(
            connectionId: 'invalidate-conn',
            profile: 'profile-a',
            sessionId: 'other-missing-session',
            logicalSessionId: 'other-missing-root',
          ),
          isFalse,
        );
        expect(
          await service.invalidateDurableSession(
            connectionId: 'invalidate-conn',
            profile: 'missing-profile',
            sessionId: 'target-session',
            logicalSessionId: 'target-root',
          ),
          isFalse,
        );
        expect(
          await service.invalidateDurableSession(
            connectionId: 'missing-connection',
            profile: 'profile-a',
            sessionId: 'target-session',
            logicalSessionId: 'target-root',
          ),
          isFalse,
        );

        targetGate.complete(<Map<String, dynamic>>[
          ...transcripts['invalidate-conn/profile-a/target-session']!,
          {
            'message_id': 'target-user-2',
            'role': 'user',
            'content': 'Turno externo exacto',
          },
          {
            'message_id': 'target-assistant-2',
            'role': 'assistant',
            'content': 'Respuesta externa exacta',
          },
        ]);

        expect(await first, isTrue);
        expect(await coalesced, isTrue);
        expect(reads['invalidate-conn/profile-a/target-session'], 1);
        expect(reads['invalidate-conn/profile-a/other-session'], 0);
        expect(reads['invalidate-conn/profile-b/target-session'], 0);
        expect(reads['other-conn/profile-a/target-session'], 0);
        expect(
          target.messages.where(
            (message) => message['content'] == 'Respuesta externa exacta',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'a disposed invalidation cannot overwrite a replacement chat',
      () async {
        final service = ActiveChatService();
        addTearDown(service.dispose);
        final staleGate = Completer<List<Map<String, dynamic>>>();
        var useGate = false;
        final connection = _conn(id: 'lifecycle-fence-conn');
        final old = service.attach(
          connection: connection,
          sessionId: 'lifecycle-session',
          logicalSessionId: 'lifecycle-root',
          sessionTitle: 'Old binding',
          sessionProfile: 'default',
          api: ApiClient(
            baseUrl: 'http://hermes.local:8642',
            apiKey: 'k',
            httpClient: MockClient(
              (_) async => http.Response('not found', 404),
            ),
          ),
          storedMessageLoader: (_, _) async => useGate
              ? staleGate.future
              : <Map<String, dynamic>>[
                  {
                    'message_id': 'old-user',
                    'role': 'user',
                    'content': 'Old user',
                  },
                  {
                    'message_id': 'old-assistant',
                    'role': 'assistant',
                    'content': 'Old assistant',
                  },
                ],
          disableForegroundKeepAlive: true,
        );
        await old.loadMessages(profile: 'default');
        old.state = ChatPipelineState.completed;
        useGate = true;

        final stale = service.invalidateDurableSession(
          connectionId: connection.id,
          profile: 'default',
          sessionId: 'lifecycle-session',
          logicalSessionId: 'lifecycle-root',
        );
        await Future<void>.delayed(Duration.zero);
        service.release(connection.id, 'lifecycle-session', profile: 'default');
        final replacement = service.attach(
          connection: connection,
          sessionId: 'lifecycle-session',
          logicalSessionId: 'lifecycle-root',
          sessionTitle: 'Replacement binding',
          sessionProfile: 'default',
          api: ApiClient(
            baseUrl: 'http://hermes.local:8642',
            apiKey: 'k',
            httpClient: MockClient(
              (_) async => http.Response('not found', 404),
            ),
          ),
          storedMessageLoader: (_, _) async => <Map<String, dynamic>>[
            {'message_id': 'new-user', 'role': 'user', 'content': 'New user'},
            {
              'message_id': 'new-assistant',
              'role': 'assistant',
              'content': 'New assistant',
            },
          ],
          disableForegroundKeepAlive: true,
        );
        await replacement.loadMessages(profile: 'default');
        staleGate.complete(<Map<String, dynamic>>[
          {'message_id': 'stale-user', 'role': 'user', 'content': 'Stale user'},
          {
            'message_id': 'stale-assistant',
            'role': 'assistant',
            'content': 'Stale assistant',
          },
        ]);

        expect(await stale, isFalse);
        expect(
          service.of(connection.id, 'lifecycle-session'),
          same(replacement),
        );
        expect(replacement.messages.first['content'], 'New assistant');
        expect(replacement.messages.toString(), isNot(contains('Stale')));
      },
    );

    test('an unreadable compression restore store fails open and never keeps a '
        'released chat alive', () async {
      // A keystore that cannot be read (the default in the test VM, or a
      // device whose keystore read fails) used to fail closed into a
      // permanent "compactando". Fail-open: nothing is shown, and
      // release() disposes the chat so the next attach() gets a fresh one
      // (`SessionActivity.compacting` never counts toward `active`).
      final service = ActiveChatService(
        compressionRestoreStore: CompressionRestoreStore(
          storage: _UnreadableFenceStorage(),
        ),
      );
      addTearDown(service.dispose);
      final connection = _conn(id: 'compacting-release-conn');
      ActiveChat attach() => service.attach(
        connection: connection,
        sessionId: 'compacting-release-session',
        logicalSessionId: 'compacting-release-root',
        sessionTitle: 'Compacting',
        sessionProfile: 'default',
        api: ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'k',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        storedMessageLoader: (_, _) async => <Map<String, dynamic>>[],
        disableForegroundKeepAlive: true,
      );
      final first = attach();
      await Future<void>.delayed(Duration.zero);

      expect(first.desktopCompressionInFlight, isFalse);
      expect(first.sessionActivity.compacting, isFalse);
      expect(first.sessionActivity.active, isFalse);
      expect(
        service.isActive(
          connection.id,
          'compacting-release-session',
          profile: 'default',
        ),
        isFalse,
      );

      service.release(
        connection.id,
        'compacting-release-session',
        profile: 'default',
      );
      expect(service.of(connection.id, 'compacting-release-session'), isNull);
      final second = attach();
      expect(second, isNot(same(first)));
    });
  });

  test('redacta errores de socket persistidos antes de proyectarlos en chat', () {
    const raw =
        'ClientException with SocketException: Connection failed '
        '(OS Error: Network is unreachable, errno = 101)';
    expect(
      activeChatStoredErrorUiMessage(raw),
      'Se perdió la conexión con Hermes. El mensaje no se confirmó; revisa el borrador y reintenta.',
    );
  });

  group('activeChatSteerFailureIsSafeToQueue', () {
    test('solo encola rechazos RPC que prueban que steering no existe', () {
      expect(
        activeChatSteerFailureIsSafeToQueue(
          const TuiGatewayRpcError(
            'session.redirect',
            'method not found',
            code: -32601,
          ),
        ),
        isTrue,
      );
      expect(
        activeChatSteerFailureIsSafeToQueue(
          const TuiGatewayRpcError(
            'session.redirect',
            'session not found',
            code: 4007,
          ),
        ),
        isTrue,
      );
      expect(
        activeChatSteerFailureIsSafeToQueue(
          const TuiGatewayRpcError('session.redirect', 'timeout'),
        ),
        isFalse,
      );
    });

    test(
      'encola únicamente la ausencia determinista de transporte steering',
      () {
        expect(
          activeChatSteerFailureIsSafeToQueue(
            StateError('steer_desktop_gateway_unavailable'),
          ),
          isTrue,
        );
        expect(
          activeChatSteerFailureIsSafeToQueue(
            StateError('steer_not_available_for_local_bridge'),
          ),
          isTrue,
        );
        expect(
          activeChatSteerFailureIsSafeToQueue(
            StateError('Hermes Desktop WebSocket is not connected'),
          ),
          isFalse,
        );
        expect(
          activeChatSteerFailureIsSafeToQueue(Exception('network down')),
          isFalse,
        );
      },
    );
  });

  group('ActiveChat.historyWithSoul (inyección de personalidad)', () {
    final history = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'hola'},
      {'role': 'assistant', 'content': 'qué tal'},
    ];

    test('SOUL presente → se antepone como mensaje system', () {
      final out = ActiveChat.historyWithSoul('Eres un pirata.', history);
      expect(out.length, history.length + 1);
      expect(out.first['role'], 'system');
      expect(out.first['content'], 'Eres un pirata.');
      // El resto del historial se conserva en orden.
      expect(out[1], history[0]);
      expect(out[2], history[1]);
    });

    test('SOUL null o vacío → history intacto (degrada, no rompe)', () {
      expect(ActiveChat.historyWithSoul(null, history), same(history));
      expect(ActiveChat.historyWithSoul('', history), same(history));
      expect(ActiveChat.historyWithSoul('   ', history), same(history));
    });

    test('no muta el history original', () {
      final original = List<Map<String, dynamic>>.from(history);
      ActiveChat.historyWithSoul('alma', history);
      expect(history, original);
    });
  });
}

final class _UnreadableFenceStorage implements CompressionRestoreStorage {
  @override
  Future<String?> read() async => throw StateError('keystore unavailable');

  @override
  Future<void> write(String value) async =>
      throw StateError('keystore unavailable');
}
