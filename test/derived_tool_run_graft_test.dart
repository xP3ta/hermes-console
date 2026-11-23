import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_context_breakdown.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/utils/chat_turn.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/test_api_client.dart';

class _MemoryCompressionFenceStorage implements CompressionRestoreStorage {
  String? value;
  int readCalls = 0;
  Completer<void>? firstReadGate;
  int? gatedReadCall;
  Completer<void>? readEntered;
  Completer<void>? readGate;
  int writeCalls = 0;
  Completer<void>? writeGate;
  Completer<void>? writeEntered;
  Set<int> failingWrites = <int>{};
  Object? readError;
  bool failAfterWrite = false;
  void Function()? onRead;

  @override
  Future<String?> read() async {
    readCalls += 1;
    onRead?.call();
    if (readError case final error?) throw error;
    if (readCalls == gatedReadCall) {
      if (readEntered?.isCompleted == false) readEntered!.complete();
      await readGate?.future;
    }
    if (readCalls == 1) await firstReadGate?.future;
    return value;
  }

  @override
  Future<void> write(String value) async {
    writeCalls += 1;
    if (writeEntered?.isCompleted == false) writeEntered!.complete();
    await writeGate?.future;
    if (failingWrites.contains(writeCalls)) {
      throw StateError('secure write unavailable');
    }
    this.value = value;
    if (failAfterWrite) throw StateError('uncertain write');
  }
}

class _SnapshotGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSessionActivityGateway,
        HermesDesktopCommandGateway,
        HermesDesktopContextUsageGateway,
        HermesDesktopRedirectGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  DesktopSessionSnapshot? snapshot;
  DesktopSessionSnapshot? omittedSnapshot;
  DesktopSessionSnapshot? deferredSnapshot;
  DesktopActiveSessionList? activeSessionList;
  Object? resumeExistingError;
  Completer<DesktopSessionSnapshot>? resumeGate;
  Completer<void>? resumeEntered;
  final List<Completer<DesktopSessionSnapshot>> resumeGates = [];
  DesktopSessionSnapshot? createSnapshot;
  int resumeExistingCalls = 0;
  int resumeLegacyCalls = 0;
  int createCalls = 0;
  bool activitySupported = false;
  int activateCalls = 0;
  int listActiveCalls = 0;
  int slashExecCalls = 0;
  int commandDispatchCalls = 0;
  int submitPromptCalls = 0;
  int steerCalls = 0;
  Future<void> Function()? onRedirect;
  DesktopRedirectDisposition redirectDisposition =
      DesktopRedirectDisposition.redirected;
  int contextBreakdownCalls = 0;
  String? slashRuntimeId;
  String? slashCommand;
  Object? slashError;
  Object? commandDispatchError;
  DesktopSessionSnapshot? snapshotAfterCommand;
  Completer<DesktopCommandRpcResult>? compressionGate;
  String? lastResumeProfile;
  bool? lastResumeOmitMessages;
  bool? lastResumeDeferHistory;
  String? lastCreateProfile;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumeExistingCalls++;
    if (resumeEntered?.isCompleted == false) resumeEntered!.complete();
    lastResumeProfile = profile;
    lastResumeOmitMessages = omitMessages;
    lastResumeDeferHistory = deferHistory;
    if (resumeExistingError case final error?) throw error;
    if (resumeGates.isNotEmpty) return resumeGates.removeAt(0).future;
    final gate = resumeGate;
    if (gate != null) return gate.future;
    if (deferHistory && deferredSnapshot != null) return deferredSnapshot!;
    if (omitMessages && omittedSnapshot != null) return omittedSnapshot!;
    return snapshot!;
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    createCalls++;
    lastCreateProfile = profile;
    return createSnapshot ??
        (throw StateError('must not create while loading'));
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    resumeLegacyCalls++;
    throw StateError('legacy resume must not run while loading');
  }

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => activitySupported
      ? DesktopGatewayCapabilityState.supported
      : DesktopGatewayCapabilityState.unsupported;

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async {
    activateCalls += 1;
    return snapshot!;
  }

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async {
    listActiveCalls += 1;
    final result = activeSessionList;
    if (result != null) return result;
    throw StateError('must not list active sessions while fenced');
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submitPromptCalls += 1;
  }

  @override
  Future<DesktopContextBreakdown> contextBreakdown(
    String runtimeSessionId,
  ) async {
    contextBreakdownCalls += 1;
    return const DesktopContextBreakdown(
      contextUsed: 42,
      contextMax: 100,
      contextPercent: 42,
    );
  }

  @override
  Future<DesktopCommandCatalog> commandsCatalog() async =>
      DesktopCommandCatalog.fromJson(const {'commands': <Object>[]});

  @override
  Future<SlashCompletionBatch> completeSlash(String text) async =>
      SlashCompletionBatch.fromJson(const {'items': <Object>[]}, input: text);

  @override
  Future<DesktopCommandRpcResult> slashExec(
    String runtimeSessionId,
    String command,
  ) async {
    slashExecCalls += 1;
    slashRuntimeId = runtimeSessionId;
    slashCommand = command;
    if (slashError case final error?) throw error;
    final gate = compressionGate;
    final result = gate == null
        ? const DesktopCommandRpcResult(
            kind: DesktopCommandDispatchKind.none,
            accepted: DesktopCommandAcceptance.accepted,
          )
        : await gate.future;
    final next = snapshotAfterCommand;
    if (next != null) snapshot = next;
    return result;
  }

  @override
  Future<DesktopCommandRpcResult> commandDispatch(
    String runtimeSessionId, {
    required String name,
    String arg = '',
  }) async {
    commandDispatchCalls += 1;
    if (commandDispatchError case final error?) throw error;
    return const DesktopCommandRpcResult(
      kind: DesktopCommandDispatchKind.none,
      accepted: DesktopCommandAcceptance.accepted,
    );
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    steerCalls += 1;
  }

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    steerCalls++;
    await onRedirect?.call();
    return redirectDisposition;
  }

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  void emit(
    String type, [
    Map<String, dynamic> payload = const {},
    int? sequence,
    int? transportGeneration,
    Object? producerChannel,
  ]) {
    emitForRuntime(
      snapshot!.runtimeSessionId,
      type,
      payload,
      sequence,
      transportGeneration,
      producerChannel,
    );
  }

  void emitForRuntime(
    String runtimeId,
    String type, [
    Map<String, dynamic> payload = const {},
    int? sequence,
    int? transportGeneration,
    Object? producerChannel,
  ]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: runtimeId,
        sequence: sequence,
        transportGeneration: transportGeneration,
        producerChannel: producerChannel,
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _events.close();
  }
}

SavedConnection _connection(String id, {bool readOnly = false}) =>
    SavedConnection(
      id: id,
      label: id,
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-key',
      kind: InstanceKind.vps,
      readOnly: readOnly,
    );

/// `session.history` devuelve el almacén durable con `display_metadata`.
class _DurableHistorySnapshotGateway extends _SnapshotGateway
    implements HermesDesktopSessionHistoryGateway {
  _DurableHistorySnapshotGateway(this.rows);

  final List<Map<String, dynamic>> Function() rows;
  int historyCalls = 0;

  /// Número de lecturas siguientes que fallan por transporte.
  int failNextHistoryReads = 0;

  /// El servidor no soporta `session.history` (error RPC permanente).
  bool historyAlwaysUnsupported = false;

  @override
  Future<SessionMessagesPage> sessionHistory({
    required String sessionId,
    String? profile,
  }) async {
    historyCalls += 1;
    if (historyAlwaysUnsupported) {
      throw const TuiGatewayRpcError(
        'session.history',
        'Method not found',
        code: -32601,
      );
    }
    if (failNextHistoryReads > 0) {
      failNextHistoryReads -= 1;
      throw const TuiGatewayRpcError(
        'session.history',
        'Hermes Desktop connection lost',
        failureKind: TuiGatewayRpcFailureKind.connectionLost,
      );
    }
    return SessionMessagesPage.fromRaw(
      rawMessages: rows(),
      pagination: null,
      paginationProvided: false,
    );
  }
}

DesktopSessionSnapshot _snapshot(Map<String, dynamic> json) =>
    DesktopSessionSnapshot.fromJson(
      json,
      requestedStoredSessionId: 'stored-chat',
      created: false,
      method: 'session.resume',
    );

ActiveChat _chat(
  String id,
  _SnapshotGateway gateway, {
  http.Client? client,
  String? logicalSessionId,
  String sessionId = 'stored-chat',
  StoredSessionMessageLoader? storedMessageLoader,
  bool allowUnownedDesktopSnapshotForTesting = true,
  Duration compressionRestoreProbeInterval = const Duration(seconds: 5),
  List<SteerProjection> initialSteerProjections = const [],
  List<CancelledTurnTombstone> initialCancelledTurnTombstones = const [],
  Future<void> Function(CancelledTurnTombstone)? onCancelledTurn,
  CompressionRestoreStore? compressionRestoreStore,
  int Function()? wallClockMs,
  void Function(ActiveChatEvent)? onEvent,
  bool readOnly = false,
  Future<void> Function()? onForegroundKeepAlive,
}) => ActiveChat(
  connection: _connection(id, readOnly: readOnly),
  sessionId: sessionId,
  logicalSessionId: logicalSessionId,
  sessionTitle: 'Snapshot',
  notifications: null,
  onTerminal: () {},
  api: testApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    httpClient:
        client ??
        MockClient((_) async => http.Response('unexpected REST', 500)),
  ),
  desktopGateway: gateway,
  compressionRestoreStore:
      compressionRestoreStore ??
      CompressionRestoreStore(storage: _MemoryCompressionFenceStorage()),
  wallClockMs: wallClockMs,
  storedMessageLoader: storedMessageLoader,
  allowUnownedDesktopSnapshotForTesting: allowUnownedDesktopSnapshotForTesting,
  compressionRestoreProbeInterval: compressionRestoreProbeInterval,
  initialSteerProjections: initialSteerProjections,
  initialCancelledTurnTombstones: initialCancelledTurnTombstones,
  onCancelledTurn: onCancelledTurn,
  onEvent: onEvent,
  onForegroundKeepAlive: onForegroundKeepAlive,
);

String? _newestAssistantText(ActiveChat chat) {
  for (final m in chat.messages) {
    if (m['role'] == 'assistant' &&
        (m['content'] as String?)?.trim().isNotEmpty == true) {
      return m['content'] as String;
    }
  }
  return null;
}

int _count(ActiveChat chat, String text) =>
    chat.messages.where((m) => m['content'] == text).length;

class _ParkableHistoryGateway extends _DurableHistorySnapshotGateway
    implements HermesDesktopLifecycleGateway {
  _ParkableHistoryGateway(super.rows);
  bool connected = true;
  int parks = 0;
  @override
  bool get isConnected => connected;
  @override
  Future<void> connect() async {
    connected = true;
  }

  @override
  Future<void> disconnectIdle() {
    parks += 1;
    connected = false;
    return Future<void>.value();
  }
}

class _Server {
  _Server(this.history, this.rest);
  List<Map<String, dynamic>> history;
  List<Map<String, dynamic>> rest;
  final restRequests = <String>[];
  late final gateway = _ParkableHistoryGateway(() => history);
  void publish(List<Map<String, dynamic>> h, List<Map<String, dynamic>> r) {
    history = h;
    rest = r;
    gateway.snapshot = _snapshot({
      'session_id': 'runtime-h1h2',
      'session_key': 'stored-chat',
      'messages': h,
      'running': false,
      'status': 'idle',
    });
  }

  http.Client client() => MockClient((request) async {
    restRequests.add(
      '${request.url.path.replaceAll(RegExp(r'/stored-chat'), '/:id')}'
      '?limit=${request.url.queryParameters['limit']}'
      '&offset=${request.url.queryParameters['offset']}',
    );
    if (!request.url.path.contains('/messages')) {
      return http.Response('unexpected REST', 500);
    }
    final limit = int.parse(request.url.queryParameters['limit'] ?? '500');
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final end = math.max(0, rest.length - offset);
    final start = math.max(0, end - limit);
    final page = rest.sublist(start, end);
    return http.Response(
      jsonEncode({
        'object': 'list',
        'session_id': 'stored-chat',
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

Future<ActiveChat> _opened(_Server server) async {
  server.publish(server.history, server.rest);
  final chat = _chat('derived', server.gateway, client: server.client())
    ..smoothStreaming = false;
  addTearDown(chat.dispose);
  await _step('open', chat, server, () async {
    await chat.loadMessages();
    return null;
  });
  return chat;
}

Future<void> _step(
  String label,
  ActiveChat chat,
  _Server server,
  Future<Object?> Function() action,
) async {
  await action();
}

Future<void> _reconcile(String label, ActiveChat chat, _Server server) => _step(
  '$label/reconcileAfterResume',
  chat,
  server,
  () async => 'changed=${await chat.reconcileAfterResume()}',
);

Future<void> _passive(String label, ActiveChat chat, _Server server) =>
    _step('$label/loadMessages(passiveOnly)', chat, server, () async {
      await chat.loadMessages(passiveOnly: true, observePassiveActivity: false);
      return null;
    });

// Derived tool-run rows (session_reconciler.dart `derivedToolRunCallIdsKey`):
// Hermes' display projection drops an assistant row that has tool calls but no
// text or detail, and ships its tool rows without a row id (measured on a real
// server: 175/175 tool rows with tool_call_id, 0/175 with row_id). Console opens
// an identity-less activity row for that run. On a partial page such a row used
// to stop every graft of the view (`canPartitionPrevious`), so a long chat
// froze on an old answer. Real route: REST through MockClient with Hermes'
// `order=latest` paging, session.history through the bound runtime,
// reconcileAfterResume and passive reads.
const _pad = 60;

Map<String, dynamic> _user(int id, String text, double ts) => {
  'id': id,
  'role': 'user',
  'content': text,
  'timestamp': ts,
  'message_uid': 'u$id',
};
Map<String, dynamic> _answer(int id, String text, double ts) => {
  'id': id,
  'role': 'assistant',
  'content': text,
  'timestamp': ts,
  'message_uid': 'u$id',
};
Map<String, dynamic> _notice(int id, double ts) => {
  'id': id,
  'role': 'user',
  'content': '[IMPORTANT: Background process done $id]',
  'timestamp': ts,
  'display_kind': 'process_complete',
  'display_metadata': {'display_text': 'done'},
  'message_uid': 'u$id',
};

/// A tool call without text: Hermes drops it from the display projection
/// unless it carries a detail sidecar (`keep`).
Map<String, dynamic> _caller(
  int id,
  String callId,
  double ts, {
  bool keep = false,
}) => {
  'id': id,
  'role': 'assistant',
  'content': '',
  'timestamp': ts,
  'message_uid': 'u$id',
  'tool_calls': [
    {
      'id': callId,
      'type': 'function',
      'function': {'name': 'terminal', 'arguments': '{}'},
    },
  ],
  if (keep) 'reasoning': 'r',
};
Map<String, dynamic> _tool(int id, String? callId, double ts) => {
  'id': id,
  'role': 'tool',
  'content': 'out',
  'tool_name': 'terminal',
  'timestamp': ts,
  'message_uid': 'u$id',
  'tool_call_id': ?callId,
};

List<Map<String, dynamic>> _padTurns(
  int firstId,
  double t0,
  int turns,
  String q,
  String a,
) => [
  for (var t = 0; t < turns; t++) ...[
    _user(firstId + t * 2, '$q$t', t0 + t * 10),
    _answer(firstId + t * 2 + 1, '$a$t', t0 + t * 10 + 5),
  ],
];

/// G1: pad turns, a background-process notice answered only by a tool run
/// (its caller dropped by the server unless [keepCaller]) and closed by QN/AN.
List<Map<String, dynamic>> _g1({
  bool keepCaller = false,
  String? callId = 'c122',
  int pad = _pad,
}) => [
  ..._padTurns(1, 1000, pad, 'Q', 'A'),
  _notice(121, 2000),
  _caller(122, callId ?? 'c122', 2001, keep: keepCaller),
  _tool(123, callId, 2002),
  _user(124, 'QN', 2010),
  _answer(125, 'AN', 2015),
];

List<Map<String, dynamic>> _later(int firstId, {int pad = _pad}) => [
  _notice(firstId, 3000),
  _answer(firstId + 1, 'APX', 3001),
  ..._padTurns(firstId + 2, 3010, pad, 'R', 'B'),
  _user(firstId + 2 + pad * 2, 'QNEW', 4000),
  _answer(firstId + 3 + pad * 2, 'ANEW', 4005),
];

String? _newest(ActiveChat chat) => _newestAssistantText(chat);

/// No loss, no duplicate: internal rows showing [callId].
int _internalRowsShowing(ActiveChat chat, String callId) => chat
    .internalMessagesForTesting
    .where((m) => m['role'] == 'assistant' && _toolCallIds(m).contains(callId))
    .length;

Set<String> _toolCallIds(Map<String, dynamic> m) => {
  for (final c in (m['tool_calls'] as List?) ?? const [])
    if (c is Map && c['id'] != null) c['id'].toString(),
  for (final s in (m[assistantActivityTraceKey] as List?) ?? const [])
    if (s is Map && s['id'] != null) s['id'].toString(),
};

/// Oracle: what a chat opened from scratch against the same server shows
/// (role, kind, text), compared over the whole common newest part.
Future<void> _expectMatchesColdOpen(ActiveChat chat, _Server server) async {
  final cold = await _opened(server);
  List<String> seq(ActiveChat c, int n) => [
    for (final m in c.messages.take(n))
      '${m['role']}|${m['display_kind'] ?? '-'}|${m['content']}',
  ];
  final n = math.min(chat.messages.length, cold.messages.length);
  expect(n, greaterThan(0));
  expect(seq(chat, n), seq(cold, n));
}

void _expectNoRepeatedDurableId(ActiveChat chat) {
  final seen = <int>{};
  for (final m in chat.internalMessagesForTesting) {
    final rowId = canonicalTranscriptIdentity(m)?.rowId;
    if (rowId != null) {
      expect(seen.add(rowId), isTrue, reason: 'row $rowId twice');
    }
  }
}

bool _internalHasId(ActiveChat chat, int id) => chat.internalMessagesForTesting
    .any((m) => canonicalTranscriptIdentity(m)?.rowId == id);

Future<void> _settle(ActiveChat chat) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  await Future<void>.delayed(const Duration(milliseconds: 50));
  while (chat.resumeReconciliationInFlight &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

/// Fold route: background park retires the runtime; the resume reconciles
/// with no runtime (REST) before any session.resume.
Future<void> _parkAndResume(
  ActiveChat chat,
  _Server server,
  List<Map<String, dynamic>> native,
  List<Map<String, dynamic>> rest,
) async {
  chat.didChangeAppLifecycleState(AppLifecycleState.paused);
  await Future<void>.delayed(
    chatTransportBackgroundGrace + const Duration(milliseconds: 500),
  );
  expect(chat.hasDesktopRuntime, isFalse);
  server.publish(native, rest);
  chat.didChangeAppLifecycleState(AppLifecycleState.resumed);
  await _settle(chat);
}

void _expectSettled(ActiveChat chat, String newest) {
  expect(_newest(chat), newest);
  expect(_count(chat, newest), 1);
  final top = chat.messages.first;
  expect(top['role'], 'assistant');
  expect(
    ((top['content'] as String?) ?? '').trim(),
    isNotEmpty,
    reason: 'an empty top would turn the next resume into a recovery',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('durable transcript as Hermes Desktop (REST truth, page always enters)', () {
    const t3 = Timeout(Duration(minutes: 3));

    test(
      'runtime bound, sources disagree: resume and passive read REST; the view follows REST',
      () async {
        final g1 = _g1();
        final server = _Server(_history(g1), _rest(g1));
        final chat = await _opened(server);
        expect(chat.hasDesktopRuntime, isTrue);
        final served = [...g1, ..._later(126)];
        server.publish(_history(served), _rest(served));
        final r0 = server.restRequests.length;
        await _reconcile('s', chat, server);
        expect(
          server.restRequests.length,
          greaterThan(r0),
          reason: 'resume read REST',
        );
        final r1 = server.restRequests.length;
        await _passive('s', chat, server);
        expect(
          server.restRequests.length,
          greaterThan(r1),
          reason: 'passive read REST',
        );
        _expectSettled(chat, 'ANEW');
        expect(
          _internalHasId(chat, 122),
          isTrue,
          reason: 'the caller row from REST',
        );
        expect(_internalRowsShowing(chat, 'c122'), 1);
        _expectNoRepeatedDurableId(chat);
        await _expectMatchesColdOpen(chat, server);
      },
      timeout: t3,
    );

    test(
      'Fold route, rewritten generation not served any more: the page replaces the view',
      () async {
        final g1 = _g1();
        final server = _Server(_history(g1), _rest(g1));
        final chat = await _opened(server);
        final g2 = _later(5000);
        await _parkAndResume(chat, server, _history(g2), _rest(g2));
        await _passive('a', chat, server);
        _expectSettled(chat, 'ANEW');
        for (final id in [121, 122, 124, 125]) {
          expect(
            _internalHasId(chat, id),
            isFalse,
            reason: 'G1 row $id is not served',
          );
        }
        expect(_count(chat, 'QN'), 0);
        _expectNoRepeatedDurableId(chat);
        // Whole view, both sides paged to the end: same rows as a cold open.
        final cold = await _opened(server);
        for (final c in [chat, cold]) {
          for (var i = 0; i < 10 && c.hasEarlierMessages; i++) {
            if (!await c.loadEarlierMessages()) break;
          }
          expect(c.hasEarlierMessages, isFalse);
        }
        expect(chat.messages.length, cold.messages.length);
        expect(
          [
            for (final m in chat.messages)
              '${m['role']}|${m['display_kind'] ?? '-'}|${m['content']}',
          ],
          [
            for (final m in cold.messages)
              '${m['role']}|${m['display_kind'] ?? '-'}|${m['content']}',
          ],
        );
      },
      timeout: t3,
    );

    test(
      'Fold route, compaction with archived rows served (include_compacted): history is kept',
      () async {
        final g1 = _g1();
        final server = _Server(_history(g1), _rest(g1));
        final chat = await _opened(server);
        final g2 = _later(5000);
        await _parkAndResume(chat, server, _history(g2), [
          ..._rest(g1),
          ..._rest(g2),
        ]);
        await _passive('a2', chat, server);
        _expectSettled(chat, 'ANEW');
        expect(_count(chat, 'QN'), 1);
        expect(_internalHasId(chat, 125), isTrue);
        expect(_internalRowsShowing(chat, 'c122'), 1);
        _expectNoRepeatedDurableId(chat);
        final ids = [
          for (final m in chat.internalMessagesForTesting.reversed)
            ?canonicalTranscriptIdentity(m)?.rowId,
        ];
        expect(
          ids,
          [...ids]..sort(),
          reason: 'stored rows in id order, G1 before G2',
        );
        await _expectMatchesColdOpen(chat, server);
      },
      timeout: t3,
    );

    test(
      'the tool results of a finished turn stay folded in its row whichever read published last',
      () async {
        // The changes chip and the diff cards of a settled turn are read
        // from this evidence. A publication that dropped it and a later
        // one that brought it back made them come and go on every open.
        final rows = [
          ..._padTurns(1, 1000, 2, 'Q', 'A'),
          _user(10, 'QT', 2000),
          _caller(11, 'cT', 2001),
          _tool(12, 'cT', 2002),
          _answer(13, 'AT', 2005),
        ];
        final server = _Server(_history(rows), _rest(rows));
        final chat = await _opened(server);
        bool folded() => chat.internalMessagesForTesting.any((m) {
          final evidence = m[assistantToolResultEvidenceKey];
          return evidence is List &&
              evidence.any((r) => r is Map && r['tool_call_id'] == 'cT');
        });
        expect(folded(), isTrue, reason: 'after the open');
        await _reconcile('s', chat, server);
        expect(folded(), isTrue, reason: 'after the resume');
        await _passive('s', chat, server);
        expect(folded(), isTrue, reason: 'after the passive read');
      },
      timeout: t3,
    );

    test('a tool row without a call id does not hold the view', () async {
      final g1 = _g1(callId: null);
      final server = _Server(_history(g1), _rest(g1));
      final chat = await _opened(server);
      final served = [...g1, ..._later(126)];
      server.publish(_history(served), _rest(served));
      await _reconcile('b', chat, server);
      await _passive('b', chat, server);
      _expectSettled(chat, 'ANEW');
      expect(_internalRowsShowing(chat, 'c122'), 1);
      _expectNoRepeatedDurableId(chat);
      await _expectMatchesColdOpen(chat, server);
    }, timeout: t3);

    test('a page that opens inside a tool run still enters', () async {
      final g1 = _g1(keepCaller: true);
      final server = _Server(_history(g1), _rest(g1));
      final chat = await _opened(server);
      final later = [
        _user(2999, 'QT', 2990),
        _caller(3000, 'cT', 2991),
        _tool(3001, 'cT', 2992),
        ..._padTurns(3002, 3010, 58, 'R', 'B'),
        _tool(3118, 'cU', 3999),
        _user(3119, 'QNEW', 4000),
        _answer(3120, 'ANEW', 4005),
      ];
      final served = [...g1, ...later];
      expect(_rest(served).reversed.take(120).last['id'], 3001);
      await _parkAndResume(chat, server, _history(served), _rest(served));
      await _passive('p', chat, server);
      _expectSettled(chat, 'ANEW');
      expect(_internalRowsShowing(chat, 'cT'), 1);
      _expectNoRepeatedDurableId(chat);
      await _expectMatchesColdOpen(chat, server);
    }, timeout: t3);

    // A terminal fence (this chat's own turn, kept local until a page proves
    // it) keeps today's graft: once the page covers the fenced turn, the rest
    // of the view is grafted without the fence and must not take the
    // Desktop fallback through the wrapper.
    List<Map<String, dynamic>> fencedView({required bool idlessRow}) => [
      {
        'role': 'assistant',
        'content': 'local answer',
        '_localTerminalProjectionId': 'p',
      },
      {
        'row_id': 20,
        'role': 'user',
        'content': 'local prompt',
        '_localTerminalProjectionId': 'p',
      },
      if (idlessRow)
        {
          'role': 'assistant',
          'content': '',
          assistantActivityTraceKey: [
            {
              'kind': 'tool',
              'label': 'terminal',
              'status': 'completed',
              'id': 'cx',
            },
          ],
        },
      {'row_id': 3, 'role': 'assistant', 'content': 'A1'},
      {'row_id': 2, 'role': 'user', 'content': 'Q1'},
    ];
    const coveringPage = <Map<String, dynamic>>[
      {'row_id': 21, 'role': 'assistant', 'content': 'local answer'},
      {'row_id': 20, 'role': 'user', 'content': 'local prompt'},
      {'row_id': 19, 'role': 'assistant', 'content': 'B'},
      {'row_id': 18, 'role': 'user', 'content': 'R'},
    ];

    test(
      'fence covered, an id-less row in the view: the page is refused as today',
      () {
        final chat = _chat(
          'fence-red',
          _DurableHistorySnapshotGateway(() => const []),
        );
        addTearDown(chat.dispose);
        final view = fencedView(idlessRow: true);
        final graft = chat.graftRefreshedTailForTesting(
          coveringPage,
          view,
          refreshedTranscriptComplete: false,
        );
        expect(graft.accepted, isFalse);
        expect(identical(graft.messages, view), isTrue);
      },
    );

    test(
      'fence covered, every row durable (control): the page is grafted as today',
      () {
        final chat = _chat(
          'fence-control',
          _DurableHistorySnapshotGateway(() => const []),
        );
        addTearDown(chat.dispose);
        final graft = chat.graftRefreshedTailForTesting(
          coveringPage,
          fencedView(idlessRow: false),
          refreshedTranscriptComplete: false,
        );
        expect(graft.accepted, isTrue);
        expect(
          [for (final m in graft.messages) m['row_id']],
          [21, 20, 19, 18, 3, 2],
        );
      },
    );

    test('a complete page keeps today\'s graft', () async {
      final g1 = _g1(pad: 10);
      final server = _Server(_history(g1), _rest(g1));
      final chat = await _opened(server);
      final served = [...g1, ..._later(126, pad: 5)];
      server.publish(_history(served), _rest(served));
      await _reconcile('c', chat, server);
      await _passive('c', chat, server);
      _expectSettled(chat, 'ANEW');
      expect(_internalRowsShowing(chat, 'c122'), 1);
      _expectNoRepeatedDurableId(chat);
      await _expectMatchesColdOpen(chat, server);
    }, timeout: t3);
  });
}

/// session_history.py:297-375 for these row shapes (text, tool, kinds).
List<Map<String, dynamic>> _history(List<Map<String, dynamic>> db) {
  final out = <Map<String, dynamic>>[];
  final names = <String, String>{};
  for (final m in db) {
    final role = m['role'] as String;
    if (role == 'assistant' && m['tool_calls'] is List) {
      for (final tc in m['tool_calls'] as List) {
        names[(tc as Map)['id'] as String] =
            (tc['function'] as Map)['name'] as String;
      }
    }
    if (role == 'tool') {
      out.add({
        'role': 'tool',
        'name': names[m['tool_call_id']] ?? m['tool_name'] ?? 'tool',
        'context': '',
        'tool_call_id': m['tool_call_id'],
        'timestamp': m['timestamp'],
      });
      continue;
    }
    final text = m['content'] as String;
    final hasDetail = role == 'assistant' && m['reasoning'] != null;
    if (text.trim().isEmpty && !hasDetail) continue;
    out.add({
      'role': role,
      'text': text,
      'timestamp': m['timestamp'],
      'row_id': m['id'],
      if (role == 'assistant' && m['reasoning'] != null)
        'reasoning': m['reasoning'],
      if (m['display_kind'] != null) 'display_kind': m['display_kind'],
      if (m['display_metadata'] != null)
        'display_metadata': m['display_metadata'],
    });
  }
  return out;
}

/// REST /api/sessions/{id}/messages: DB rows as stored.
List<Map<String, dynamic>> _rest(List<Map<String, dynamic>> db) => [
  for (final m in db)
    {
      ...m,
      'message_uid': 'uid-${m['id']}',
      if (m['role'] == 'assistant')
        'finish_reason': m['tool_calls'] == null ? 'stop' : 'tool_calls',
    },
];
