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
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/attachment_uploader.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/home_widget_publisher.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

const _kWatchKey = 'bg_watch_runs'; // BackgroundWatch._key (privado)
const _kObservedTtftKey = 'active_chat_observed_ttft_v1';

SavedConnection _conn({String id = 'conn-1'}) => SavedConnection(
  id: id,
  label: 'Test',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

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
  connection: _conn(id: 'conn-attachment'),
  sessionId: 'sess-attachment',
  sessionTitle: 'Adjuntos',
  notifications: null,
  onTerminal: () {},
  desktopGateway: gateway,
);

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
  test('desktop recovery never exposes technical errors in UI', () {
    final secrets = <Object>[
      StateError('state-secret'),
      SocketException('socket-secret'),
      TuiGatewayRpcError('session.resume', 'rpc-secret', code: 4999),
    ];

    for (final error in secrets) {
      final ui = activeChatDesktopRecoveryUiMessage(error);
      final diagnostic = activeChatDesktopRecoveryDiagnostic(error);
      expect(ui, 'Could not recover the turn. Please try again.');
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
      'Could not recover the turn. Please try again.',
    );
  });

  test('prompt admission uses structured reasons without exposing detail', () {
    const expected = <String, String>{
      'SESSION_NOT_OWNED':
          'This conversation is open in another window or device. '
          'Close it there and try again.',
      'MAX_CONCURRENT_SESSIONS':
          'Hermes has reached its maximum number of active sessions. '
          'Close another session and try again.',
      'SESSION_COORDINATION_UNAVAILABLE':
          'Hermes could not reserve this conversation safely. '
          'Check the server and try again.',
    };

    for (final entry in expected.entries) {
      final error = TuiGatewayRpcError(
        'prompt.submit',
        'private session id and process detail',
        code: 4090,
        data: {'reason': entry.key},
      );
      expect(activeChatPromptWasRejectedBeforeAcceptance(error), isTrue);
      expect(activeChatPromptFailureUiMessage(error), entry.value);
      expect(
        activeChatPromptFailureUiMessage(error),
        isNot(contains('private')),
      );
    }

    const unknown = TuiGatewayRpcError(
      'prompt.submit',
      'private provider detail',
      code: 5001,
    );
    expect(activeChatPromptWasRejectedBeforeAcceptance(unknown), isFalse);
    expect(
      activeChatPromptFailureUiMessage(unknown),
      'Could not send the message. Please try again.',
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
      'Hermes could not reserve this conversation. '
      'Check other active sessions and try again.',
    );
    expect(safe, isNot(contains('TuiGatewayRpcError')));
    expect(safe, isNot(contains('private-id')));
    expect(activeChatStoredErrorUiMessage(ordinary), ordinary);
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  test('known stored binding is stable and rejects retargeting', () {
    final chat = ActiveChat(
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
    final service = ActiveChatService();
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

      final service = ActiveChatService(cancelledTurnStore: store);
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

      final service = ActiveChatService(prefs: prefs);
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
      final service = ActiveChatService();
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

  test('expone actividad real y la conserva durante una reconexión', () {
    final service = ActiveChatService();
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
      final service = ActiveChatService()
        ..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1');

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
        final service = ActiveChatService()
          ..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1');

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
      final service = ActiveChatService(prefs: prefs)
        ..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1');
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

      final restored = ActiveChatService(prefs: prefs);
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
        final service = ActiveChatService()
          ..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1');
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
      final service = ActiveChatService()
        ..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1');
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
      'colecciona intermedios y final una vez sin narrar tools ni logs',
      () async {
        final gateway = _AttachmentDesktopGateway();
        final chat = ActiveChat(
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
        await emitAndWait('message.delta', const {
          'text': 'RAZONAMIENTO_INTERNO',
          'channel': 'reasoning',
        }, ActiveChatEvent.token);
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
      'Desktop conserva final, interim y usuario en orden sin duplicados',
      () async {
        final gateway = _AttachmentDesktopGateway();
        final chat = ActiveChat(
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
          (role: 'assistant', content: 'Resumen final del proyecto.'),
          (role: 'assistant', content: 'Voy a revisar los archivos.'),
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
        var channelFactoryCalls = 0;
        final desktop = TuiGatewayClient(
          connection,
          dashboard: _StaticWebSocketAuthDashboardClient(),
          channelFactory: (_, _) {
            channelFactoryCalls++;
            return channelFactoryCalls == 1
                ? blockedChannel
                : _TeardownTestWebSocketChannel(blockTeardown: false);
          },
        );
        final chat = ActiveChat(
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
        await desktop.connect().timeout(const Duration(milliseconds: 250));
        expect(channelFactoryCalls, 2);
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
      final service = ActiveChatService();
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
        final service = ActiveChatService();
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

        final service = ActiveChatService();
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
            if (messageReads == 1) return http.Response('not found', 404);
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
        final service = ActiveChatService();
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
        expect(messageReads, 1);

        await _waitFor(() => messageReads >= 2);
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
        connection: _conn(),
        sessionId: 'sess-1',
        sessionTitle: 'X',
        notifications: null,
        onTerminal: () {},
        api: api,
      );
    }

    test('re-sincroniza un turno a medias (placeholder sin cerrar)', () async {
      final chat = chatWith([
        {'role': 'user', 'content': 'hola'},
        {'role': 'assistant', 'content': 'respuesta completa del servidor'},
      ]);
      // Simula el estado tras volver de 2º plano con el SSE cortado: burbuja
      // del asistente vacía en pipeline.
      chat.messages = [
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
        chat.messages = [
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
        <String, dynamic>{'role': 'user', 'content': 'ejecuta la herramienta'},
        <String, dynamic>{'role': 'tool', 'name': 'status', 'content': 'ok'},
      ];
      final chat = chatWith(serverMessages);
      chat.messages = serverMessages.reversed
          .map(Map<String, dynamic>.of)
          .toList(growable: false);
      chat.state = ChatPipelineState.completed;
      final before = chat.messages;

      final changed = await chat.reconcileAfterResume();

      expect(changed, isFalse);
      expect(chat.messages, same(before));
      expect(chat.messages.first['role'], 'tool');
      chat.dispose();
    });

    test(
      'reapertura sustituye el placeholder por un terminal tool-only',
      () async {
        final chat = chatWith([
          {'role': 'user', 'content': 'consulta el estado'},
          {'role': 'tool', 'name': 'status', 'content': 'ok'},
        ]);
        chat.messages = [
          {'role': 'assistant', 'content': '', '_pipeline': true},
          {'role': 'user', 'content': 'consulta el estado'},
        ];
        chat.state = ChatPipelineState.idle;

        final changed = await chat.reconcileAfterResume();

        expect(changed, isTrue);
        expect(chat.messages.first['role'], 'tool');
        expect(chat.messages.first['content'], 'ok');
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
      chat.messages = [
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
      chat.messages = [
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
      chat.messages = [
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
