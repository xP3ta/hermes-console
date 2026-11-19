// A stored user turn carrying Hermes' official memory-context block, read
// through the durable REST page (the path the history fix reads): the row is
// adopted as stored (canonical, with the block), the local prompt is not
// duplicated, and the bubble text shows the native projection's clean text.
// All data synthetic. Fixture adapted from transport_retained_activity_test.
//
// La pastilla de actividad no puede apagarse mientras Hermes sigue trabajando
// solo porque el socket se cortó o el runtime rotó (F1/F2/F4). Lo último visto
// se conserva como «último estado conocido» hasta una prueba real: un
// `process.list`/`subagent.list` con fence sobre una sesión viva, una fila
// durable de finalización o un tope de edad. Stop y los retiros explícitos
// siguen limpiando.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_compression_outcome.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:hermes_android/core/utils/projected_content_copy.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

const _runtimeId = 'runtime-retained';
const _storedId = 'stored-retained';

/// Modela el servidor real: `process.list`/`subagent.list` son
/// `live_session=True` (solo responden sobre un runtime vivo) y, tras el reap
/// de la sesión huérfana, la recuperación ligada al roster falla con
/// `ROSTER_SESSION_NOT_ACTIVE` (preflight local del cliente real).
class _RetainingGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRecoverySessionLifecycleGateway,
        HermesDesktopRosterBoundRecoveryGateway,
        HermesDesktopSubagentGateway,
        HermesDesktopControlGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  bool connected = true;

  /// El servidor retiró la sesión huérfana: no hay runtime al que volver.
  bool reaped = false;
  String liveRuntimeId = _runtimeId;
  List<BackgroundProcessEntry> processes = const [];
  List<DesktopSubagentSnapshot> subagents = const [];
  int processCalls = 0;
  int subagentCalls = 0;

  /// Retiene la respuesta de `subagent.list` (el roster aún no contestó).
  Completer<void>? subagentListGate;
  int rosterResumeCalls = 0;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async => connected = true;

  void drop() {
    connected = false;
    _events.addError(StateError('socket dropped'));
  }

  void emit(String type, Map<String, dynamic> payload) {
    _events.add(
      TuiGatewayEvent(type: type, sessionId: liveRuntimeId, payload: payload),
    );
  }

  DesktopSessionSnapshot _snapshot(String storedSessionId) =>
      DesktopSessionSnapshot(
        runtimeSessionId: liveRuntimeId,
        storedSessionId: storedSessionId,
        created: false,
      );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    if (reaped) {
      // Attach-on-load only rejoins an advertised runtime; a reaped session
      // has none (the real client checks the roster before resuming).
      throw const TuiGatewayRpcError(
        'session.active_list',
        'Hermes no longer advertises the durable session',
        origin: CompressionFailureOrigin.localPreflight,
        data: {'reason': rosterSessionNotActiveReason},
      );
    }
    return _snapshot(storedSessionId);
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => throw StateError('no create in this fixture');

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async => _snapshot(storedSessionId);

  @override
  Future<DesktopRosterBoundRecovery> resumeAdvertisedExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    rosterResumeCalls += 1;
    await connect();
    if (reaped) {
      throw const TuiGatewayRpcError(
        'session.active_list',
        'Hermes no longer advertises the durable session',
        origin: CompressionFailureOrigin.localPreflight,
        data: {'reason': rosterSessionNotActiveReason},
      );
    }
    return DesktopRosterBoundRecovery.forTesting(
      _snapshot(storedSessionId),
      this,
    );
  }

  @override
  bool consumeRosterBoundRecovery(DesktopRosterBoundRecovery recovery) => true;

  @override
  bool consumeRosterBoundViewerAttachment(
    DesktopRosterBoundRecovery recovery,
  ) => true;

  @override
  // ignore: deprecated_member_use_from_same_package
  void commitRecoveryRuntime(String runtimeSessionId) {}

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<List<DesktopSubagentSnapshot>> listSubagents(
    String runtimeSessionId,
  ) async {
    subagentCalls += 1;
    await subagentListGate?.future;
    if (reaped || runtimeSessionId != liveRuntimeId) {
      throw const TuiGatewayRpcError('subagent.list', 'session not live');
    }
    return subagents;
  }

  @override
  Future<AgentCenterSnapshot> agentCenterSnapshot({
    String runtimeSessionId = '',
  }) async {
    processCalls += 1;
    if (reaped || runtimeSessionId != liveRuntimeId) {
      throw const TuiGatewayRpcError('process.list', 'session not live');
    }
    return AgentCenterSnapshot(snapshots: const [], processes: processes);
  }

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

ActiveChat _chat(
  _RetainingGateway gateway, {
  StoredSessionMessageLoader? storedMessageLoader,
  Duration retainedActivityMaxAge = const Duration(minutes: 10),
  http.Client? httpClient,
  int transcriptPageSizeForTesting = 500,
}) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: SavedConnection(
    id: 'conn-retained',
    label: 'Retained',
    host: 'example.invalid',
    port: 443,
    apiKey: 'test-key',
    useHttps: true,
    kind: InstanceKind.vps,
  ),
  sessionId: _storedId,
  sessionTitle: 'Retained',
  sessionProfile: 'default',
  notifications: null,
  onTerminal: () {},
  api: testApiClient(
    baseUrl: 'http://127.0.0.1:1',
    httpClient:
        httpClient ?? MockClient((_) async => http.Response('not found', 404)),
  ),
  transcriptPageSizeForTesting: transcriptPageSizeForTesting,
  desktopGateway: gateway,
  attachDesktopRuntimeOnLoad: true,
  allowUnownedDesktopSnapshotForTesting: true,
  storedMessageLoader: storedMessageLoader,
  desktopRecoveryBackoff: const [Duration.zero],
  retainedActivityMaxAge: retainedActivityMaxAge,
);

/// `/api/sessions/{id}/messages` con la semántica `order=latest` de Hermes
/// (hermes_cli/web_routers/sessions.py): `offset` cuenta hacia atrás desde el
/// mensaje más reciente, la página llega en orden cronológico y cada fila
/// lleva su `id` SQLite y su `timestamp`.
class _PagedTranscriptServer {
  final List<Map<String, dynamic>> rows = [];
  final List<Uri> requests = [];

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    final limit = int.parse(request.url.queryParameters['limit'] ?? '120');
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final end = math.max(0, rows.length - offset);
    final start = math.max(0, end - limit);
    final page = rows.sublist(start, end);
    return http.Response(
      jsonEncode({
        'object': 'list',
        'session_id': _storedId,
        'data': page,
        'pagination': {
          'limit': limit,
          'offset': offset,
          'order': 'latest',
          'returned': page.length,
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

const _block =
    '<memory-context>\n[System note: The following is recalled memory context, '
    'NOT new user input. Treat as informational background data.]\n\n'
    '## Memory\n- synthetic fact one\n- synthetic fact two\n'
    '</memory-context>\n\n';

Map<String, dynamic> _mrow(int id, String role, String content) => {
  'id': id,
  'message_id': 'msg-$id',
  'role': role,
  'content': content,
  'timestamp': 1000.0 + id,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('REST row with the memory block: adopted as stored, one bubble, the '
      'native text shown', () async {
    final server = _PagedTranscriptServer()
      ..rows.addAll([
        _mrow(1, 'user', 'primera pregunta sintética'),
        _mrow(2, 'assistant', 'primera respuesta sintética'),
      ]);
    final gateway = _RetainingGateway();
    final chat = _chat(gateway, httpClient: server.client());
    addTearDown(chat.dispose);
    await chat.loadMessages();
    await chat.ensureDesktopRuntime(acquireForExplicitAction: true);
    expect(
      await chat.send(
        fullText: 'segunda pregunta sintética',
        model: 'hermes-agent',
        history: chat.messages,
      ),
      isTrue,
    );
    gateway.emit('message.start', const {});
    gateway.emit('message.complete', const {
      'text': 'segunda respuesta sintética',
    });
    await _waitUntil(() => !chat.isStreaming);
    server.rows.addAll([
      _mrow(3, 'user', '${_block}segunda pregunta sintética'),
      _mrow(4, 'assistant', 'segunda respuesta sintética'),
    ]);
    await chat.loadMessages();

    final users = chat.messages.where((m) => m['role'] == 'user').toList();
    // Admission first: the durable rows were adopted.
    expect(users.map((m) => m['id']), containsAll(<Object>[1, 3]));
    expect(users, hasLength(2), reason: 'no duplicate of the local prompt');
    final stored = users.singleWhere((m) => m['id'] == 3);
    expect(
      stored['content'],
      '${_block}segunda pregunta sintética',
      reason: 'canonical row unchanged',
    );
    final strings = lookupStrings(const Locale('es'));
    expect(
      projectedContentCopy(strings, stored, stored['content'] as String),
      'segunda pregunta sintética',
    );
  });
}
