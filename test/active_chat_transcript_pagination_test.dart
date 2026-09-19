import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_compression_fence_store.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/subagent_transcript_projection.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/utils/chat_turn.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_fence_storage.dart';

/// Fake del canal Desktop que graba los flags de `session.resume` y permite
/// emitir eventos `session.resume_progress` como haría Hermes Agent 0.20.
class _DeferrableGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSubagentGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  DesktopSessionSnapshot? snapshot;
  DesktopSessionSnapshot? createSnapshot;
  Completer<DesktopSessionSnapshot>? resumeGate;
  Object? resumeError;
  int resumeExistingCalls = 0;
  bool? lastDeferHistory;
  bool? lastOmitMessages;
  final List<({String runtimeId, String subagentId})> subagentTailCalls = [];
  final List<({String runtimeId, String subagentId, String text})>
  subagentSteerCalls = [];
  final List<({String runtimeId, String subagentId})> subagentInterruptCalls =
      [];

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
    lastDeferHistory = deferHistory;
    lastOmitMessages = omitMessages;
    if (resumeError case final error?) throw error;
    return resumeGate?.future ?? snapshot!;
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async =>
      createSnapshot ?? (throw StateError('must not create while loading'));

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => throw StateError('legacy resume must not run while loading');

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<List<DesktopSubagentSnapshot>> listSubagents(
    String runtimeSessionId,
  ) async => const [];

  @override
  Future<DesktopSubagentTailResult> tailSubagent(
    String runtimeSessionId,
    String subagentId,
  ) async {
    subagentTailCalls.add((
      runtimeId: runtimeSessionId,
      subagentId: subagentId,
    ));
    return const DesktopSubagentTailResult(
      available: true,
      content: 'coherent live tail',
      truncated: false,
    );
  }

  @override
  Future<DesktopSubagentSteerResult> steerSubagent(
    String runtimeSessionId,
    String subagentId,
    String text,
  ) async {
    subagentSteerCalls.add((
      runtimeId: runtimeSessionId,
      subagentId: subagentId,
      text: text,
    ));
    return DesktopSubagentSteerResult(
      status: 'queued',
      subagentId: subagentId,
      text: text,
    );
  }

  @override
  Future<DesktopSubagentInterruptResult> interruptSubagent(
    String runtimeSessionId,
    String subagentId,
  ) {
    subagentInterruptCalls.add((
      runtimeId: runtimeSessionId,
      subagentId: subagentId,
    ));
    return Future.value(
      DesktopSubagentInterruptResult(found: true, subagentId: subagentId),
    );
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  void emitResumeProgress(String status, {int? messageCount}) {
    _events.add(
      TuiGatewayEvent(
        type: 'session.resume_progress',
        sessionId: snapshot!.runtimeSessionId,
        payload: {
          'phase': 'history',
          'status': status,
          'message_count': ?messageCount,
        },
      ),
    );
  }

  void emit(String type, {Map<String, dynamic> payload = const {}}) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: snapshot!.runtimeSessionId,
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _events.close();
  }
}

class _HistoryGateway extends _DeferrableGateway
    implements HermesDesktopSessionHistoryGateway {
  Future<SessionMessagesPage> Function()? loader;
  bool connected = true;
  final historyRequests = <({String sessionId, String? profile})>[];

  @override
  bool get isConnected => connected;

  @override
  Future<SessionMessagesPage> sessionHistory({
    required String sessionId,
    String? profile,
  }) async {
    historyRequests.add((sessionId: sessionId, profile: profile));
    return loader!();
  }
}

SavedConnection _connection(String id) => SavedConnection(
  id: id,
  label: id,
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-key',
  kind: InstanceKind.vps,
);

/// Servidor mock de `/api/sessions/{id}/messages` con la semántica
/// `order=latest` de Hermes Agent 0.20: `offset` hacia atrás desde el mensaje
/// más reciente y la página devuelta en orden cronológico. [paginate]=false
/// simula un gateway legacy que ignora la query y devuelve todo one-shot.
class _TranscriptServer {
  _TranscriptServer({required this.paginate});

  bool paginate;
  final List<Map<String, dynamic>> rows = [];
  final List<Uri> requests = [];
  bool healthy = true;

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    if (!healthy) {
      return http.Response('unavailable', 500);
    }
    if (!paginate) {
      return http.Response(
        jsonEncode({'object': 'list', 'data': rows}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    final limit = int.parse(request.url.queryParameters['limit'] ?? '120');
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final end = math.max(0, rows.length - offset);
    final start = math.max(0, end - limit);
    final page = rows.sublist(start, end);
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

class _CompactedTranscriptServer {
  final List<Map<String, dynamic>> activeRows;
  final List<Map<String, dynamic>> compactedRows;
  final List<Uri> requests = [];

  _CompactedTranscriptServer({
    required this.activeRows,
    required this.compactedRows,
  });

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    final includeCompacted =
        request.url.queryParameters['include_compacted'] == 'true';
    final source = <Map<String, dynamic>>[
      if (includeCompacted) ...compactedRows,
      ...activeRows,
    ];
    final seen = <Object?>{};
    final canonical = source
        .where((row) => seen.add(row['message_id'] ?? row['id']))
        .toList(growable: false);
    final limit = int.parse(request.url.queryParameters['limit'] ?? '120');
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final end = math.max(0, canonical.length - offset);
    final start = math.max(0, end - limit);
    final page = canonical.sublist(start, end);
    return http.Response(
      jsonEncode({
        'object': 'list',
        'session_id': 'stored-chat',
        'messages': page,
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

class _OutOfOrderTranscriptServer {
  final requests = <({Uri url, Completer<http.Response> response})>[];

  http.Client client() => MockClient((request) {
    final response = Completer<http.Response>();
    requests.add((url: request.url, response: response));
    return response.future;
  });

  Future<void> waitForRequests(int count) async {
    while (requests.length < count) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void complete(
    int index,
    List<Map<String, dynamic>> rows, {
    required bool paginated,
  }) {
    final requestedOffset = int.parse(
      requests[index].url.queryParameters['offset'] ?? '0',
    );
    requests[index].response.complete(
      http.Response(
        jsonEncode({
          'object': 'list',
          'data': rows,
          if (paginated)
            'pagination': {
              'limit': 120,
              'offset': requestedOffset,
              'order': 'latest',
              'returned': rows.length,
            },
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
  }
}

class _ControlledTranscriptServer {
  final requests = <({Uri url, Completer<http.Response> response})>[];

  http.Client client() => MockClient((request) {
    if (!request.url.path.endsWith('/messages')) {
      return Future.value(
        http.Response(
          jsonEncode(const <String, Object?>{}),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );
    }
    final response = Completer<http.Response>();
    requests.add((url: request.url, response: response));
    return response.future;
  });

  Future<void> waitForRequests(int count) async {
    while (requests.length < count) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void completePage(
    int index,
    List<Object?> rows, {
    Object? pagination,
    bool paginationProvided = true,
    String resolvedSessionId = 'stored-chat',
  }) {
    final requestedLimit = int.parse(
      requests[index].url.queryParameters['limit'] ?? '120',
    );
    final requestedOffset = int.parse(
      requests[index].url.queryParameters['offset'] ?? '0',
    );
    requests[index].response.complete(
      http.Response(
        jsonEncode({
          'object': 'list',
          'session_id': resolvedSessionId,
          'messages': rows,
          if (paginationProvided)
            'pagination':
                pagination ??
                {
                  'limit': requestedLimit,
                  'offset': requestedOffset,
                  'order': 'latest',
                  'returned': rows.length,
                },
        }),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );
  }

  void completeError(int index) {
    requests[index].response.complete(http.Response('unavailable', 503));
  }
}

List<Map<String, dynamic>> _rows(int count, {int from = 1}) => [
  for (var index = from; index < from + count; index++)
    {
      'id': index,
      'message_id': 'msg-$index',
      'role': index.isOdd ? 'user' : 'assistant',
      'content': 'msg $index',
    },
];

List<Map<String, dynamic>> _rowOnlyRows(int count, {int from = 1}) => [
  for (var index = from; index < from + count; index++)
    {
      'id': index,
      'role': index.isOdd ? 'user' : 'assistant',
      'content': 'row $index',
    },
];

ActiveChat _chat(
  String id,
  http.Client client, {
  String sessionId = 'stored-chat',
  String? logicalSessionId,
  String? initialStoredSessionId,
  _DeferrableGateway? gateway,
  List<CancelledTurnTombstone> initialCancelledTurnTombstones = const [],
  Future<void> Function(CancelledTurnTombstone)? onCancelledTurn,
  void Function()? onTerminal,
  DesktopCompressionFenceStore? compressionFenceStore,
  int transcriptPageSizeForTesting = 120,
}) => ActiveChat(
  compressionFenceStore: compressionFenceStore ?? testCompressionFenceStore(),
  transcriptPageSizeForTesting: transcriptPageSizeForTesting,
  connection: _connection(id),
  sessionId: sessionId,
  logicalSessionId: logicalSessionId,
  sessionTitle: 'Paginación',
  notifications: null,
  onTerminal: onTerminal ?? () {},
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    apiKey: 'test-key',
    httpClient: client,
  ),
  desktopGateway: gateway,
  initialStoredSessionId: initialStoredSessionId,
  allowUnownedDesktopSnapshotForTesting: true,
  initialCancelledTurnTombstones: initialCancelledTurnTombstones,
  onCancelledTurn: onCancelledTurn,
);

List<Map<String, dynamic>> _generatedImageRefs(Map<String, dynamic> message) {
  final raw = message['_generatedImages'];
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native history waits for resume and loads a profile whose REST is 401',
    () async {
      final rows = _rows(300);
      final gateway = _HistoryGateway()
        ..resumeGate = Completer<DesktopSessionSnapshot>()
        ..loader = () async => SessionMessagesPage.fromRaw(
          rawMessages: [
            for (final row in rows)
              {
                'role': row['role'],
                'text': row['content'],
                'row_id': row['id'],
              },
          ],
          pagination: null,
          paginationProvided: false,
        );
      var restCalls = 0;
      final chat = _chat(
        'native-profile-history',
        MockClient((_) async {
          restCalls++;
          return http.Response('Unauthorized', 401);
        }),
        gateway: gateway,
      );
      addTearDown(chat.dispose);
      final loading = chat.loadMessages(profile: 'builder');
      await Future<void>.delayed(Duration.zero);
      expect(gateway.historyRequests, isEmpty);
      expect(restCalls, 0);
      gateway.resumeGate!.complete(
        const DesktopSessionSnapshot(
          runtimeSessionId: 'resolved-runtime',
          storedSessionId: 'stored-chat',
          created: false,
          messageCount: 300,
        ),
      );
      await loading;
      expect(gateway.historyRequests, [
        (sessionId: 'resolved-runtime', profile: 'builder'),
      ]);
      expect(restCalls, 0);
      expect(
        chat.messages.map((row) => row['content']),
        rows.reversed.map((row) => row['content']),
      );
      expect(chat.transcriptExtentForTesting, 'complete');
      expect(chat.hasEarlierMessages, isFalse);
      expect(await chat.loadEarlierMessages(), isFalse);
      expect(gateway.historyRequests, hasLength(1));
    },
  );

  for (final disconnected in [false, true]) {
    test(
      'native history falls back to REST when ${disconnected ? 'disconnected' : 'RPC fails'}',
      () async {
        final server = _TranscriptServer(paginate: false)
          ..rows.addAll(_rows(4));
        final gateway = _HistoryGateway()
          ..connected = !disconnected
          ..snapshot = const DesktopSessionSnapshot(
            runtimeSessionId: 'runtime',
            storedSessionId: 'stored-chat',
            created: false,
          )
          ..loader = () async => throw const TuiGatewayRpcError(
            'session.history',
            'unsupported',
            code: -32601,
          );
        final chat = _chat(
          'native-fallback-$disconnected',
          server.client(),
          gateway: gateway,
        );
        addTearDown(chat.dispose);
        await chat.loadMessages();
        expect(server.requests, hasLength(1));
        expect(
          chat.messages.map((row) => row['content']),
          _rows(4).reversed.map((row) => row['content']),
        );
        expect(chat.hasEarlierMessages, isFalse);
        expect(gateway.historyRequests, hasLength(disconnected ? 0 : 1));
      },
    );
  }

  test(
    'late native history cannot publish after its load was invalidated',
    () async {
      final pending = Completer<SessionMessagesPage>();
      final gateway = _HistoryGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime',
          storedSessionId: 'stored-chat',
          created: false,
        )
        ..loader = () => pending.future;
      final chat = _chat(
        'native-stale',
        MockClient((_) async => http.Response('Unauthorized', 401)),
        gateway: gateway,
      );
      addTearDown(chat.dispose);
      final loading = chat.loadMessages();
      while (gateway.historyRequests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final previousExtent = chat.transcriptExtentForTesting;
      final previousEarlier = chat.hasEarlierMessages;
      chat.invalidatePassiveRead();
      pending.complete(
        SessionMessagesPage(messages: _rows(4), pagination: null),
      );
      await loading;
      expect(chat.messages, isEmpty);
      expect(chat.transcriptExtentForTesting, previousExtent);
      expect(chat.hasEarlierMessages, previousEarlier);
    },
  );

  test(
    'native full history replaces a REST tail during earlier-page load',
    () async {
      final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(300));
      final gateway = _HistoryGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime',
          storedSessionId: 'stored-chat',
          created: false,
        )
        ..loader = () async => throw StateError('temporarily unavailable');
      final chat = _chat('native-backfill', server.client(), gateway: gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();
      expect(chat.hasEarlierMessages, isTrue);
      gateway.loader = () async =>
          SessionMessagesPage(messages: _rows(300), pagination: null);
      await chat.loadEarlierMessages();
      expect(chat.messages, hasLength(300));
      expect(
        chat.messages.map((row) => row['content']).toSet(),
        hasLength(300),
      );
      expect(chat.transcriptExtentForTesting, 'complete');
      expect(chat.hasEarlierMessages, isFalse);
      expect(server.requests, hasLength(1));
    },
  );

  test('passive activity request is fenced by every authority coordinate', () {
    const baseline = (
      stored: 'stored-a',
      runtime: null,
      turn: 4,
      bind: 7,
      session: 9,
      request: 2,
    );
    bool current({
      String stored = 'stored-a',
      String? runtime,
      int turn = 4,
      int bind = 7,
      int session = 9,
      int request = 2,
    }) => activeChatPassiveActivityRequestStillCurrent(
      expectedStoredSessionId: baseline.stored,
      currentStoredSessionId: stored,
      expectedRuntimeSessionId: baseline.runtime,
      currentRuntimeSessionId: runtime,
      expectedTurnEpoch: baseline.turn,
      currentTurnEpoch: turn,
      expectedBindEpoch: baseline.bind,
      currentBindEpoch: bind,
      expectedSessionEpoch: baseline.session,
      currentSessionEpoch: session,
      expectedRequestGeneration: baseline.request,
      currentRequestGeneration: request,
    );

    expect(current(), isTrue);
    expect(current(stored: 'stored-b'), isFalse);
    expect(current(runtime: 'runtime-new'), isFalse);
    expect(current(turn: 5), isFalse);
    expect(current(bind: 8), isFalse);
    expect(current(session: 10), isFalse);
    expect(current(request: 3), isFalse);
  });

  test(
    '[console-state 5/7] active_list is tri-state and only unique idle drains',
    () {
      const idle = DesktopActiveSession(
        runtimeSessionId: 'runtime-idle',
        storedSessionId: 'stored-a',
        status: 'idle',
      );
      const working = DesktopActiveSession(
        runtimeSessionId: 'runtime-working',
        storedSessionId: 'stored-a',
        status: 'working',
      );
      const unknown = DesktopActiveSession(
        runtimeSessionId: 'runtime-unknown',
        storedSessionId: 'stored-a',
        status: 'future-state',
      );
      const missing = DesktopActiveSession(
        runtimeSessionId: 'runtime-missing',
        storedSessionId: 'stored-a',
      );
      const pending = DesktopActiveSession(
        runtimeSessionId: 'runtime-pending',
        storedSessionId: 'stored-a',
        status: 'pending',
      );
      const error = DesktopActiveSession(
        runtimeSessionId: 'runtime-error',
        storedSessionId: 'stored-a',
        status: 'error',
      );

      final matrix =
          <(List<DesktopActiveSession>, DesktopPassiveActivityState)>[
            (const [], DesktopPassiveActivityState.idle),
            (const [idle], DesktopPassiveActivityState.idle),
            (const [working], DesktopPassiveActivityState.busy),
            (const [idle, idle], DesktopPassiveActivityState.unknown),
            (const [pending], DesktopPassiveActivityState.unknown),
            (const [error], DesktopPassiveActivityState.unknown),
            (const [idle, working], DesktopPassiveActivityState.unknown),
            (const [idle, unknown], DesktopPassiveActivityState.unknown),
            (const [idle, missing], DesktopPassiveActivityState.unknown),
          ];
      for (final (rows, expected) in matrix) {
        expect(activeChatPassiveRowsState(rows), expected, reason: '$rows');
      }
      final malformed = DesktopActiveSessionList.fromJson(const {
        'sessions': [
          {'status': 'idle'},
        ],
      });
      expect(
        activeChatPassiveRowsState(
          malformed.sessions,
          hasMalformedRows: malformed.hasMalformedRows,
        ),
        DesktopPassiveActivityState.unknown,
      );
    },
  );

  test(
    'compacted display survives once and mixed page coverage fails closed',
    () async {
      final compacted = <Map<String, dynamic>>[
        const {
          'id': 'old-user',
          'message_id': 'old-user',
          'role': 'user',
          'content': 'Como va?',
          'active': 0,
          'compacted': 1,
        },
        const {
          'id': 'old-assistant',
          'message_id': 'old-assistant',
          'role': 'assistant',
          'content': 'earlier answer',
          'active': 0,
          'compacted': 1,
        },
        ..._rows(120, from: 1000),
      ];
      final active = <Map<String, dynamic>>[
        const {
          'id': 'summary',
          'message_id': 'summary',
          'role': 'system',
          'content': 'summary',
        },
        const {
          'id': 'current-user',
          'message_id': 'current-user',
          'role': 'user',
          'content': 'Todavía?',
        },
        const {
          'id': 'current-assistant',
          'message_id': 'current-assistant',
          'role': 'assistant',
          'content': 'GO',
        },
      ];
      final server = _CompactedTranscriptServer(
        activeRows: active,
        compactedRows: compacted,
      );
      final chat = _chat('compacted-pagination', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: active.length);

      expect(
        server.requests.single.queryParameters['include_compacted'],
        'true',
      );
      expect(chat.messages.any((row) => row['content'] == 'Todavía?'), isTrue);
      expect(chat.messages.any((row) => row['content'] == 'GO'), isTrue);
      expect(chat.hasEarlierMessages, isTrue);
      expect(chat.coreReadLineageComplete, isFalse);

      while (chat.hasEarlierMessages) {
        await chat.loadEarlierMessages();
      }

      final identities = chat.messages
          .map(canonicalTranscriptMessageId)
          .toList(growable: false);
      expect(chat.messages.any((row) => row['content'] == 'Como va?'), isTrue);
      expect(identities, hasLength(compacted.length + active.length - 1));
      expect(identities.toSet(), hasLength(identities.length));
      expect(identities.first, 'current-assistant');
      expect(identities.last, 'old-user');
      expect(chat.coreReadLineageComplete, isFalse);
      expect(chat.coreReadCoverage, {
        CoreReadCoverage.full,
        CoreReadCoverage.tipOnly,
        CoreReadCoverage.metadataPartial,
      });
    },
  );

  test(
    'authoritative compacted REST walks 500-row pages until returned is short',
    () async {
      final compacted = [
        for (final row in _rows(1000))
          <String, dynamic>{...row, 'active': 0, 'compacted': 1},
      ];
      final active = _rows(1, from: 1001);
      final server = _CompactedTranscriptServer(
        activeRows: active,
        compactedRows: compacted,
      );
      final chat = _chat(
        'compacted-500-pages',
        server.client(),
        transcriptPageSizeForTesting: 500,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 1001);
      while (chat.hasEarlierMessages) {
        expect(await chat.loadEarlierMessages(), isTrue);
      }

      expect(server.requests, hasLength(3));
      expect(
        server.requests.map((uri) => uri.queryParameters['limit']),
        everyElement('500'),
      );
      expect(server.requests.map((uri) => uri.queryParameters['offset']), [
        '0',
        '500',
        '1000',
      ]);
      expect(
        server.requests.map((uri) => uri.queryParameters['include_compacted']),
        everyElement('true'),
      );
      expect(
        server.requests.every(
          (uri) => !uri.queryParameters.containsKey('total'),
        ),
        isTrue,
      );
      expect(chat.messages, hasLength(1001));
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'direct rotated descendant compacted rows keep lineage coverage partial',
    () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'object': 'list',
            'session_id': 'rotated-tip',
            'messages': const [
              {
                'id': 'tip-compacted',
                'message_id': 'tip-compacted',
                'role': 'user',
                'content': 'tip-only compacted row',
                'active': 0,
                'compacted': 1,
              },
            ],
            'pagination': const {
              'limit': 120,
              'offset': 0,
              'order': 'latest',
              'returned': 1,
            },
          }),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );
      final chat = _chat(
        'direct-rotated-descendant',
        client,
        sessionId: 'rotated-tip',
        logicalSessionId: 'lineage-root',
        initialStoredSessionId: 'rotated-tip',
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 1);

      expect(chat.coreReadIdentity.logicalRootId, 'lineage-root');
      expect(chat.coreReadIdentity.storedId, 'rotated-tip');
      expect(chat.coreReadIdentity.resolvedTipId, 'rotated-tip');
      expect(chat.coreReadLineageComplete, isFalse);
      expect(chat.coreReadCoverageIsPartial, isTrue);
    },
  );

  test(
    'carga inicial salta paginas internas hasta hallar conversacion visible',
    () async {
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll(const [
          {
            'id': 'older-user',
            'message_id': 'older-user',
            'role': 'user',
            'content': 'Pregunta visible anterior',
          },
          {
            'id': 'older-assistant',
            'message_id': 'older-assistant',
            'role': 'assistant',
            'content': 'Respuesta visible anterior',
          },
        ])
        ..rows.addAll([
          for (var i = 0; i < 60; i++) ...[
            {
              'id': 'assistant-tool-$i',
              'message_id': 'assistant-tool-$i',
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'id': 'call-$i',
                  'type': 'function',
                  'function': {'name': 'execute_code', 'arguments': '{}'},
                },
              ],
            },
            {
              'id': 'tool-result-$i',
              'message_id': 'tool-result-$i',
              'role': 'tool',
              'tool_call_id': 'call-$i',
              'content': 'resultado interno',
            },
          ],
        ]);
      final chat = _chat('editorially-empty-tail', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 122);

      expect(server.requests.map((uri) => uri.queryParameters['offset']), [
        '0',
        '120',
      ]);
      expect(
        chat.messages.any(
          (row) => row['content'] == 'Pregunta visible anterior',
        ),
        isTrue,
      );
      expect(
        chat.messages.any(
          (row) => row['content'] == 'Respuesta visible anterior',
        ),
        isTrue,
      );
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'el presupuesto de backfill automatico no se reinicia en cada refresh',
    () async {
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll([
          {
            'id': 'older-user',
            'message_id': 'older-user',
            'role': 'user',
            'content': 'Pregunta visible anterior',
          },
          {
            'id': 'older-assistant',
            'message_id': 'older-assistant',
            'role': 'assistant',
            'content': 'Respuesta visible anterior',
          },
          for (var i = 0; i < 7800; i++)
            {
              'id': 'internal-$i',
              'message_id': 'internal-$i',
              'role': 'system',
              'content': 'interno $i',
            },
        ]);
      final chat = _chat('bounded-editorially-empty-tail', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 7802);
      expect(server.requests.length, 65);
      expect(chat.hasEarlierMessages, isTrue);

      await chat.loadMessages(expectedMessageCount: 7802, passiveOnly: true);

      expect(server.requests.length, 66);
      expect(server.requests.last.queryParameters['offset'], '0');
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test('respuesta tardia de backfill no altera su señal de error', () async {
    final server = _ControlledTranscriptServer();
    final chat = _chat('stale-backfill-error-state', server.client());
    addTearDown(chat.dispose);

    final initial = chat.loadMessages(expectedMessageCount: 480);
    await server.waitForRequests(1);
    server.completePage(0, _rows(120, from: 361));
    await initial;
    expect(chat.hasEarlierMessages, isTrue);
    expect(chat.earlierMessagesLoadFailed, isFalse);

    final failed = chat.loadEarlierMessages();
    await server.waitForRequests(2);
    server.completeError(1);
    expect(await failed, isFalse);
    expect(chat.earlierMessagesLoadFailed, isTrue);

    final staleSuccess = chat.loadEarlierMessages();
    await server.waitForRequests(3);
    chat.invalidatePassiveRead();
    server.completePage(2, _rows(120, from: 241));
    expect(await staleSuccess, isFalse);
    expect(chat.earlierMessagesLoadFailed, isTrue);

    final freshSuccess = chat.loadEarlierMessages();
    await server.waitForRequests(4);
    server.completePage(3, _rows(120, from: 241));
    expect(await freshSuccess, isTrue);
    expect(chat.earlierMessagesLoadFailed, isFalse);

    final staleFailure = chat.loadEarlierMessages();
    await server.waitForRequests(5);
    chat.invalidatePassiveRead();
    server.completeError(4);
    expect(await staleFailure, isFalse);
    expect(chat.earlierMessagesLoadFailed, isFalse);
  });

  test(
    'reapertura elimina una generacion user retirada sin deduplicar por texto',
    () async {
      Map<String, dynamic> assistantToolRow(String generation, int index) => {
        'id': '$generation-assistant-$index',
        'message_id': '$generation-assistant-$index',
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': '$generation-call-$index',
            'type': 'function',
            'function': {'name': 'execute_code', 'arguments': '{}'},
          },
        ],
      };

      final server = _TranscriptServer(paginate: true)
        ..rows.addAll([
          for (var i = 0; i < 108; i++) assistantToolRow('old', i),
          for (var i = 0; i < 11; i++)
            {
              'id': 'old-visible-$i',
              'message_id': 'old-visible-$i',
              'role': 'user',
              'content': 'Turno visible viejo $i',
            },
          const {
            'id': 'old-user-generation',
            'message_id': 'old-user-generation',
            'role': 'user',
            'content': 'El mismo prompt humano',
          },
        ]);
      final chat = _chat('generation-replacement', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 120);
      expect(
        chat.messages.where(
          (row) => row['content'] == 'El mismo prompt humano',
        ),
        hasLength(1),
      );

      server.rows
        ..clear()
        ..addAll([
          for (var i = 0; i < 240; i++) assistantToolRow('new', i),
          const {
            'id': 'new-user-generation',
            'message_id': 'new-user-generation',
            'role': 'user',
            'content': 'El mismo prompt humano',
          },
        ]);

      await chat.loadMessages(expectedMessageCount: 241);

      expect(
        chat.messages.where(
          (row) => row['content'] == 'El mismo prompt humano',
        ),
        hasLength(1),
      );
      expect(
        chat.messages.any((row) => row['message_id'] == 'new-user-generation'),
        isTrue,
      );
      expect(
        chat.messages.any((row) => row['message_id'] == 'old-user-generation'),
        isFalse,
      );
    },
  );

  test('hidrata solo la cola paginada y antepone páginas anteriores', () async {
    final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(300));
    final chat = _chat('tail', server.client());
    addTearDown(chat.dispose);
    final events = <ActiveChatEvent>[];
    final sub = chat.changes.listen(events.add);
    addTearDown(sub.cancel);

    await chat.loadMessages(expectedMessageCount: 300);

    expect(chat.messagesLoaded, isTrue);
    expect(chat.messages, hasLength(120));
    expect(chat.messages.first['content'], 'msg 300');
    expect(chat.messages.last['content'], 'msg 181');
    expect(chat.hasEarlierMessages, isTrue);
    expect(server.requests, hasLength(1));
    expect(server.requests.single.queryParameters['limit'], '120');
    expect(server.requests.single.queryParameters['order'], 'latest');
    expect(server.requests.single.queryParameters['offset'], '0');
    expect(chat.coreReadIdentity.storedId, 'stored-chat');
    expect(chat.coreReadIdentity.resolvedTipId, 'stored-chat');
    expect(chat.coreReadIdentity.runtimeId, isNull);
    expect(
      chat.coreReadCoverage.map((value) => value.toString()),
      containsAll([
        'CoreReadCoverage.tipOnly',
        'CoreReadCoverage.metadataPartial',
      ]),
    );

    expect(await chat.loadEarlierMessages(), isTrue);
    expect(chat.messages, hasLength(240));
    expect(chat.messages.last['content'], 'msg 61');
    expect(chat.hasEarlierMessages, isTrue);
    expect(server.requests.last.queryParameters['offset'], '120');

    // Última página parcial: el backfill se retira.
    expect(await chat.loadEarlierMessages(), isTrue);
    expect(chat.messages, hasLength(300));
    expect(chat.messages.last['content'], 'msg 1');
    expect(chat.hasEarlierMessages, isFalse);
    expect(await chat.loadEarlierMessages(), isFalse);
    expect(
      events.where((event) => event == ActiveChatEvent.earlierMessagesLoaded),
      hasLength(2),
    );
  });

  test('un gesto atraviesa paginas anteriores editorialmente vacias', () async {
    final server = _TranscriptServer(paginate: true)
      ..rows.addAll([
        ..._rows(2),
        for (var index = 0; index < 120; index++)
          {
            'id': 'internal-$index',
            'message_id': 'internal-$index',
            'role': 'system',
            'content': 'interno $index',
          },
        ..._rows(120, from: 1000),
      ]);
    final chat = _chat('scroll-empty-page', server.client());
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 242);
    expect(server.requests.map((uri) => uri.queryParameters['offset']), ['0']);

    expect(await chat.loadEarlierMessages(continuePastInvisible: true), isTrue);

    expect(server.requests.map((uri) => uri.queryParameters['offset']), [
      '0',
      '120',
      '240',
    ]);
    expect(
      chat.messages.any((message) => message['content'] == 'msg 1'),
      isTrue,
    );
    expect(
      chat.messages.any((message) => message['content'] == 'msg 2'),
      isTrue,
    );
  });

  test('un gesto atraviesa una pagina de delegaciones omitidas', () async {
    final server = _TranscriptServer(paginate: true)
      ..rows.addAll([
        ..._rows(2),
        for (var index = 0; index < 120; index++)
          {
            'id': 'delegate-$index',
            'message_id': 'delegate-$index',
            'role': 'assistant',
            'content': 'delegación interna $index',
            'tool_calls': [
              {
                'id': 'delegate-call-$index',
                'function': {'name': 'delegate_task'},
              },
            ],
          },
        ..._rows(120, from: 1000),
      ]);
    final chat = _chat('scroll-delegate-page', server.client());
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 242);
    expect(await chat.loadEarlierMessages(continuePastInvisible: true), isTrue);

    expect(server.requests.map((uri) => uri.queryParameters['offset']), [
      '0',
      '120',
      '240',
    ]);
    expect(
      chat.messages.any((message) => message['content'] == 'msg 1'),
      isTrue,
    );
  });

  test(
    'un gesto atraviesa delegacion privada y editorial con cursor raw',
    () async {
      final omitted = <Map<String, dynamic>>[
        for (var index = 0; index < 40; index++)
          {
            'id': 'hidden-$index',
            'message_id': 'hidden-$index',
            'role': 'user',
            'content': 'editorial privado $index',
            'display_kind': 'hidden',
          },
        for (var index = 0; index < 40; index++)
          {
            'id': 'private-$index',
            'message_id': 'private-$index',
            'role': 'assistant',
            'content': '',
            'reasoning': 'razonamiento privado $index',
          },
        for (var index = 0; index < 40; index++)
          {
            'id': 'delegate-mixed-$index',
            'message_id': 'delegate-mixed-$index',
            'role': 'assistant',
            'content': 'delegación omitida $index',
            'tool_calls': [
              {
                'id': 'delegate-mixed-call-$index',
                'function': {'name': 'delegate_task'},
              },
            ],
          },
      ];
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll([..._rows(2), ...omitted, ..._rows(120, from: 1000)]);
      final chat = _chat('mixed-omitted-page', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 242);
      expect(
        await chat.loadEarlierMessages(continuePastInvisible: true),
        isTrue,
      );

      expect(server.requests.map((uri) => uri.queryParameters['offset']), [
        '0',
        '120',
        '240',
      ]);
      expect(chat.messages.any((row) => row['content'] == 'msg 1'), isTrue);
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'un gesto termina tras una pagina omitida y un final realmente vacio',
    () async {
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll([
          for (var index = 0; index < 120; index++)
            {
              'id': 'empty-control-$index',
              'message_id': 'empty-control-$index',
              'role': 'user',
              'content': 'oculto $index',
              'display_kind': 'hidden',
            },
          ..._rows(120, from: 1000),
        ]);
      final chat = _chat('truly-empty-control', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 240);
      expect(
        await chat.loadEarlierMessages(continuePastInvisible: true),
        isTrue,
      );

      expect(server.requests.map((uri) => uri.queryParameters['offset']), [
        '0',
        '120',
        '240',
      ]);
      expect(chat.hasEarlierMessages, isFalse);
      expect(
        await chat.loadEarlierMessages(continuePastInvisible: true),
        isFalse,
      );
      expect(server.requests, hasLength(3));
    },
  );

  test(
    'un gesto tiene presupuesto finito ante paginas siempre omitidas',
    () async {
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll([
          for (var index = 0; index < 7800; index++)
            {
              'id': 'bounded-hidden-$index',
              'message_id': 'bounded-hidden-$index',
              'role': 'user',
              'content': 'oculto $index',
              'display_kind': 'hidden',
            },
          ..._rows(120, from: 10000),
        ]);
      final chat = _chat('bounded-explicit-gesture', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 7920);
      expect(
        await chat.loadEarlierMessages(continuePastInvisible: true),
        isTrue,
      );

      expect(server.requests, hasLength(65));
      expect(server.requests.first.queryParameters['offset'], '0');
      expect(
        server.requests.last.queryParameters['offset'],
        '${63 * 120 + 120}',
      );
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test('el polling pasivo conserva la pagina anterior y su cursor', () async {
    final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(300));
    final chat = _chat('passive-refresh-after-backfill', server.client());
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 300);
    expect(await chat.loadEarlierMessages(), isTrue);
    expect(chat.messages, hasLength(240));
    expect(chat.earlierMessagesNextOffsetForTesting, 240);

    await chat.loadMessages(expectedMessageCount: 300, passiveOnly: true);

    expect(chat.messages, hasLength(240));
    expect(chat.messages.last['content'], 'msg 61');
    expect(chat.earlierMessagesNextOffsetForTesting, 240);
    expect(chat.hasEarlierMessages, isTrue);

    expect(await chat.loadEarlierMessages(), isTrue);
    expect(server.requests.last.queryParameters['offset'], '240');
    expect(chat.messages, hasLength(300));
    expect(chat.messages.last['content'], 'msg 1');
  });

  test(
    'historical completion keeps identity across backfill and refresh',
    () async {
      final server = _TranscriptServer(paginate: true)
        ..rows.add({
          'id': 1,
          'message_id': 'paged-completion',
          'role': 'user',
          'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_c0ffee12]',
          'display_kind': 'async_delegation_complete',
          'display_metadata': {
            'delegation_id': 'deleg_c0ffee12',
            'task_count': 1,
            'completed_count': 1,
            'failed_count': 0,
            'subagent_ids': ['sa-paged-one'],
          },
        })
        ..rows.addAll(_rows(120, from: 2));
      final chat = _chat('paged-subagent', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 121);
      expect(
        chat.messages
            .map(historicalSubagentCompletionOf)
            .whereType<SubagentCompletionCardData>(),
        isEmpty,
      );

      expect(await chat.loadEarlierMessages(), isTrue);
      final afterBackfill = chat.messages
          .map(historicalSubagentCompletionOf)
          .whereType<SubagentCompletionCardData>()
          .toList();
      expect(afterBackfill, hasLength(1));
      final completionKey = afterBackfill.single.completionKey;

      await chat.loadMessages(expectedMessageCount: 121);
      final afterRefresh = chat.messages
          .map(historicalSubagentCompletionOf)
          .whereType<SubagentCompletionCardData>()
          .toList();
      expect(afterRefresh, hasLength(1));
      expect(afterRefresh.single.completionKey, completionKey);
    },
  );

  test(
    'refresh obsoleto no sobrescribe el bookkeeping paginado vigente',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final chat = _chat('overlapping-refresh', server.client());
      addTearDown(chat.dispose);

      final staleLoad = chat.loadMessages(expectedMessageCount: 2);
      await server.waitForRequests(1);
      final currentLoad = chat.loadMessages(expectedMessageCount: 120);
      await server.waitForRequests(2);

      final currentTail = _rows(120, from: 1001);
      server.complete(1, currentTail, paginated: true);
      await currentLoad;

      expect(chat.messages.first['content'], 'msg 1120');
      expect(chat.hasEarlierMessages, isTrue);

      server.complete(0, _rows(2), paginated: false);
      await staleLoad;

      expect(chat.messages.first['content'], 'msg 1120');
      expect(chat.messages.last['content'], 'msg 1001');
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'fila REST descartada conserva cursor bruto y nunca acredita completitud',
    () async {
      final requests = <Uri>[];
      final tail = <Object?>[
        const {
          'message_id': 'malformed-tail-first-user',
          'role': 'user',
          'content': 'prompt repetido tras fila malformada',
        },
        const {
          'message_id': 'malformed-tail-legitimate-answer',
          'role': 'assistant',
          'content': 'respuesta legítima que debe sobrevivir',
        },
        for (var index = 0; index < 117; index++)
          {
            'message_id': 'malformed-tail-context-$index',
            'role': 'system',
            'content': 'contexto $index',
          },
        'fila REST inválida',
      ];
      final client = MockClient((request) async {
        requests.add(request.url);
        final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
        final page = offset == 0 ? tail : const <Object?>[];
        return http.Response(
          jsonEncode({
            'object': 'list',
            'data': page,
            'pagination': {
              'limit': 120,
              'offset': offset,
              'order': 'latest',
              'returned': page.length,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: client,
      );
      final parsedTail = await api.getMessagesPage('stored-chat');
      expect(parsedTail.rawMessageCount, 120);
      expect(parsedTail.messages, hasLength(119));
      expect(parsedTail.messagesFullyParsed, isFalse);

      requests.clear();
      final chat = _chat(
        'malformed-rest-page',
        client,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido tras fila malformada',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 120);

      expect(chat.messages, hasLength(2));
      expect(
        chat.messages.any((message) => message['role'] == 'tool'),
        isFalse,
      );
      expect(chat.hasEarlierMessages, isTrue);
      expect(
        chat.messages.any(
          (message) =>
              message['message_id'] == 'malformed-tail-legitimate-answer',
        ),
        isTrue,
      );
      expect(
        chat.messages
            .singleWhere(
              (message) => message['message_id'] == 'malformed-tail-first-user',
            )
            .containsKey('_cancelledUser'),
        isFalse,
      );

      // El cursor usa las 120 filas brutas, no las 119 que se pudieron
      // proyectar. La página final no sana el hueco: rearma una lectura
      // autoritativa desde offset cero y mantiene `firstUser` diferido.
      expect(await chat.loadEarlierMessages(), isFalse);
      expect(requests.last.queryParameters['offset'], '120');
      expect(chat.hasEarlierMessages, isTrue);
      expect(chat.earlierMessagesNextOffsetForTesting, 0);
      expect(chat.needsTranscriptTailHydrationForTesting, isTrue);
      expect(
        chat.messages.any(
          (message) =>
              message['message_id'] == 'malformed-tail-legitimate-answer',
        ),
        isTrue,
      );
      expect(
        chat.messages
            .singleWhere(
              (message) => message['message_id'] == 'malformed-tail-first-user',
            )
            .containsKey('_cancelledUser'),
        isFalse,
      );
    },
  );

  test(
    'pagination metadata inconsistente conserva cobertura parcial',
    () async {
      for (final pagination in <Map<String, dynamic>>[
        const {'limit': 120, 'offset': 0, 'returned': 120},
        const {'limit': 120, 'offset': 120, 'returned': 1},
      ]) {
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({
              'object': 'list',
              'data': const [
                {
                  'message_id': 'only-row',
                  'role': 'user',
                  'content': 'fila visible',
                },
              ],
              'pagination': pagination,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          ),
        );
        final api = ApiClient(
          baseUrl: 'http://127.0.0.1:8642',
          apiKey: 'test-key',
          httpClient: client,
        );

        final page = await api.getMessagesPage('stored-chat');

        expect(page.messages, hasLength(1));
        expect(page.paginationProvided, isTrue);
        expect(page.paginationFullyParsed, isFalse);
      }
    },
  );

  test('malformed returned downgrades a previously complete lineage', () async {
    final malformedReturnedValues = <Object?>[
      '1',
      -1,
      1.5,
      null,
      const <Object?>[],
      const <String, Object?>{'value': 1},
    ];
    for (var index = 0; index < malformedReturnedValues.length; index++) {
      var request = 0;
      final client = MockClient((_) async {
        final pagination = <String, Object?>{
          'limit': 120,
          'offset': 0,
          'returned': request++ == 0 ? 1 : malformedReturnedValues[index],
        };
        return http.Response(
          jsonEncode({
            'session_id': 'stored-chat',
            'messages': const [
              {
                'message_id': 'compacted-row',
                'role': 'user',
                'content': 'historial',
                'compacted': 1,
                'active': 0,
              },
            ],
            'pagination': pagination,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final chat = _chat('malformed-returned-$index', client);
      addTearDown(chat.dispose);

      await chat.loadMessages();
      expect(chat.coreReadLineageComplete, isTrue, reason: 'case $index');
      await chat.loadMessages();
      expect(chat.coreReadLineageComplete, isFalse, reason: 'case $index');
      expect(chat.coreReadCoverageIsPartial, isTrue, reason: 'case $index');
    }
  });

  test(
    'all-discarded canonical page downgrades preserved complete lineage',
    () async {
      var request = 0;
      final requests = <http.Request>[];
      final client = MockClient((incoming) async {
        requests.add(incoming);
        final response = switch (request++) {
          0 => <Object?>[
            const {
              'message_id': 'durable-row',
              'role': 'user',
              'content': 'fila durable',
              'compacted': 1,
              'active': 0,
            },
          ],
          1 => <Object?>['fila no proyectable'],
          _ => <Object?>[
            const {
              'message_id': 'durable-row',
              'role': 'user',
              'content': 'fila durable',
              'compacted': 1,
              'active': 0,
            },
            const {
              'message_id': 'recovered-row',
              'role': 'assistant',
              'content': 'fila recuperada',
            },
          ],
        };
        return http.Response(
          jsonEncode({
            'session_id': 'stored-chat',
            'messages': response,
            'pagination': {
              'limit': 120,
              'offset': 0,
              'returned': response.length,
            },
            'coverage': ['full'],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final chat = _chat('all-discarded-lineage-downgrade', client);
      addTearDown(chat.dispose);

      await chat.loadMessages();
      expect(chat.coreReadLineageComplete, isTrue);
      expect(chat.coreReadCoverageIsPartial, isFalse);
      expect(chat.hasEarlierMessages, isFalse);

      await chat.loadMessages();
      expect(chat.messages.map(canonicalTranscriptMessageId), ['durable-row']);
      expect(chat.coreReadLineageComplete, isFalse);
      expect(chat.coreReadCoverageIsPartial, isTrue);
      expect(chat.hasEarlierMessages, isTrue);

      expect(await chat.loadEarlierMessages(), isTrue);
      expect(requests.last.url.queryParameters['offset'], '0');
      expect(
        chat.messages.map(canonicalTranscriptMessageId),
        containsAll(<String>['durable-row', 'recovered-row']),
      );
    },
  );

  test(
    'genuine empty canonical page preserves visible complete transcript',
    () async {
      var request = 0;
      final client = MockClient((_) async {
        final response = request++ == 0
            ? const <Object?>[
                {
                  'message_id': 'durable-row',
                  'role': 'user',
                  'content': 'fila durable',
                  'compacted': 1,
                  'active': 0,
                },
              ]
            : const <Object?>[];
        return http.Response(
          jsonEncode({
            'session_id': 'stored-chat',
            'messages': response,
            'pagination': {
              'limit': 120,
              'offset': 0,
              'returned': response.length,
            },
            'coverage': ['full'],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final chat = _chat('genuine-empty-preserves-transcript', client);
      addTearDown(chat.dispose);

      await chat.loadMessages();
      await chat.loadMessages();

      expect(chat.messages.map(canonicalTranscriptMessageId), ['durable-row']);
      expect(chat.coreReadLineageComplete, isTrue);
      // Una página sin filas no acredita metadata full por sí sola, pero tampoco
      // crea un hueco de parseo ni habilita un cursor de backfill inventado.
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test('empty canonical page keeps expected-count failure', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'session_id': 'stored-chat',
          'messages': const <Object?>[],
          'pagination': const {'limit': 120, 'offset': 0, 'returned': 0},
          'coverage': const ['full'],
        }),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );
    final chat = _chat('empty-expected-count-failure', client);
    addTearDown(chat.dispose);

    await expectLater(
      chat.loadMessages(expectedMessageCount: 1),
      throwsA(isA<StateError>()),
    );
    expect(chat.messagesLoaded, isFalse);
  });

  test(
    'canonical non-Map row downgrades a preserved complete lineage',
    () async {
      var request = 0;
      final client = MockClient((_) async {
        final response = switch (request++) {
          0 => <Object?>[
            const {
              'message_id': 'durable-row',
              'role': 'user',
              'content': 'fila durable',
              'compacted': 1,
              'active': 0,
            },
          ],
          1 => <Object?>[
            const {
              'message_id': 'durable-row',
              'role': 'user',
              'content': 'fila durable',
              'compacted': 1,
              'active': 0,
            },
            'fila no proyectable',
          ],
          _ => <Object?>[
            const {
              'message_id': 'durable-row',
              'role': 'user',
              'content': 'fila durable',
              'compacted': 1,
              'active': 0,
            },
            const {
              'message_id': 'hydrated-row',
              'role': 'assistant',
              'content': 'fila recuperada',
            },
          ],
        };
        return http.Response(
          jsonEncode({
            'session_id': 'stored-chat',
            'messages': response,
            'pagination': {
              'limit': 120,
              'offset': 0,
              'returned': response.length,
            },
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final chat = _chat('non-map-lineage-downgrade', client);
      addTearDown(chat.dispose);

      await chat.loadMessages();
      expect(chat.coreReadLineageComplete, isTrue);
      expect(chat.coreReadCoverageIsPartial, isFalse);

      // El refresh solapa exactamente la fila ya visible, así que la ruta real
      // conserva la cobertura existente aunque la respuesta raw tenga un hueco.
      await chat.loadMessages();
      expect(
        chat.messages.map(canonicalTranscriptMessageId),
        contains('durable-row'),
      );
      expect(chat.coreReadLineageComplete, isFalse);
      expect(chat.coreReadCoverageIsPartial, isTrue);
      expect(await chat.loadEarlierMessages(), isTrue);
      expect(chat.coreReadLineageComplete, isTrue);
      expect(chat.coreReadCoverageIsPartial, isFalse);

      // Otra lectura canónica conserva la reparación ya acreditada.
      await chat.loadMessages();
      expect(
        chat.messages.map(canonicalTranscriptMessageId),
        containsAll(<String>['durable-row', 'hydrated-row']),
      );
      expect(chat.coreReadLineageComplete, isTrue);
      expect(chat.coreReadCoverageIsPartial, isFalse);
    },
  );

  test(
    'ambiguous canonical identities downgrade a previously complete lineage',
    () async {
      final ambiguousResponses = <List<Map<String, Object?>>>[
        const [
          {
            'message_id': 'duplicate-id',
            'role': 'user',
            'content': 'primera fila',
            'compacted': 1,
            'active': 0,
          },
          {
            'message_id': 'duplicate-id',
            'role': 'assistant',
            'content': 'segunda fila distinta',
          },
        ],
        const [
          {
            'id': 'alias-a',
            'message_id': 'alias-b',
            'role': 'user',
            'content': 'aliases incompatibles',
            'compacted': 1,
            'active': 0,
          },
        ],
      ];
      for (var index = 0; index < ambiguousResponses.length; index++) {
        var request = 0;
        final client = MockClient((_) async {
          final response = request++ == 0
              ? const <Map<String, Object?>>[
                  {
                    'message_id': 'initial-row',
                    'role': 'user',
                    'content': 'historial inicial',
                    'compacted': 1,
                    'active': 0,
                  },
                ]
              : ambiguousResponses[index];
          return http.Response(
            jsonEncode({
              'session_id': 'stored-chat',
              'messages': response,
              'pagination': {
                'limit': 120,
                'offset': 0,
                'returned': response.length,
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        });
        final chat = _chat('ambiguous-lineage-$index', client);
        addTearDown(chat.dispose);

        await chat.loadMessages();
        expect(chat.coreReadLineageComplete, isTrue, reason: 'case $index');
        await chat.loadMessages();
        expect(chat.coreReadLineageComplete, isFalse, reason: 'case $index');
        expect(chat.coreReadCoverageIsPartial, isTrue, reason: 'case $index');
      }
    },
  );

  test('valid canonical full refresh preserves complete lineage', () async {
    var request = 0;
    final client = MockClient((_) async {
      final response = request++ == 0
          ? const <Map<String, Object?>>[
              {
                'message_id': 'valid-initial',
                'role': 'user',
                'content': 'historial inicial',
                'compacted': 1,
                'active': 0,
              },
            ]
          : const <Map<String, Object?>>[
              {
                'message_id': 'valid-initial',
                'role': 'user',
                'content': 'historial inicial',
                'compacted': 1,
                'active': 0,
              },
              {
                'message_id': 'valid-next',
                'role': 'assistant',
                'content': 'respuesta válida',
              },
            ];
      return http.Response(
        jsonEncode({
          'session_id': 'stored-chat',
          'messages': response,
          'pagination': {
            'limit': 120,
            'offset': 0,
            'returned': response.length,
          },
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final chat = _chat('valid-full-refresh', client);
    addTearDown(chat.dispose);

    await chat.loadMessages();
    expect(chat.coreReadLineageComplete, isTrue);
    expect(chat.coreReadCoverageIsPartial, isFalse);
    await chat.loadMessages();
    expect(chat.coreReadLineageComplete, isTrue);
    expect(chat.coreReadCoverageIsPartial, isFalse);
  });

  test(
    'response limit mismatch downgrades a previously complete lineage',
    () async {
      for (final responseLimit in <int>[500, 60]) {
        var requestCount = 0;
        final client = MockClient((request) async {
          expect(request.url.queryParameters['limit'], '120');
          expect(request.url.queryParameters['include_compacted'], 'true');
          final firstRequest = requestCount++ == 0;
          final messages = firstRequest
              ? const <Map<String, Object?>>[
                  {
                    'message_id': 'initial-compacted-row',
                    'role': 'user',
                    'content': 'historial inicial',
                    'compacted': 1,
                    'active': 0,
                  },
                ]
              : <Map<String, Object?>>[
                  const {
                    'message_id': 'mismatched-compacted-row',
                    'role': 'user',
                    'content': 'historial paginado',
                    'compacted': 1,
                    'active': 0,
                  },
                  for (var index = 1; index < 120; index++)
                    {
                      'message_id': 'mismatched-context-$index',
                      'role': 'system',
                      'content': 'contexto $index',
                    },
                ];
          return http.Response(
            jsonEncode({
              'session_id': 'stored-chat',
              'messages': messages,
              'pagination': {
                'limit': firstRequest ? 120 : responseLimit,
                'offset': 0,
                'returned': messages.length,
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        });
        final chat = _chat('limit-mismatch-$responseLimit', client);
        addTearDown(chat.dispose);

        await chat.loadMessages();
        expect(chat.coreReadLineageComplete, isTrue, reason: '$responseLimit');
        await chat.loadMessages();
        expect(chat.coreReadLineageComplete, isFalse, reason: '$responseLimit');
        expect(
          chat.coreReadCoverageIsPartial,
          isTrue,
          reason: '$responseLimit',
        );
      }
    },
  );

  test('invalid pagination downgrades a previously complete lineage', () async {
    for (final invalid in <Map<String, dynamic>>[
      const {'limit': 120, 'offset': 0, 'returned': 2},
      const {'limit': 120, 'offset': 120, 'returned': 1},
    ]) {
      var request = 0;
      final client = MockClient((_) async {
        final pagination = request++ == 0
            ? const {'limit': 120, 'offset': 0, 'returned': 1}
            : invalid;
        return http.Response(
          jsonEncode({
            'session_id': 'stored-chat',
            'messages': const [
              {
                'message_id': 'compacted-row',
                'role': 'user',
                'content': 'historial',
                'compacted': 1,
                'active': 0,
              },
            ],
            'pagination': pagination,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final chat = _chat('lineage-downgrade-${invalid['offset']}', client);
      addTearDown(chat.dispose);
      await chat.loadMessages();
      expect(chat.coreReadLineageComplete, isTrue);
      await chat.loadMessages();
      expect(chat.coreReadLineageComplete, isFalse);
      expect(chat.coreReadCoverageIsPartial, isTrue);
    }
  });

  test(
    'backfill iniciado tras refresh no aplica un cursor que el refresh rebobinó',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final chat = _chat('refresh-backfill-revision', server.client());
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(expectedMessageCount: 500);
      await server.waitForRequests(1);
      server.complete(0, _rows(120, from: 381), paginated: true);
      await initialLoad;

      final firstBackfill = chat.loadEarlierMessages();
      await server.waitForRequests(2);
      expect(server.requests[1].url.queryParameters['offset'], '120');
      server.complete(1, _rows(120, from: 261), paginated: true);
      expect(await firstBackfill, isTrue);
      expect(
        chat.messages.map((message) => message['id']),
        orderedEquals(List<int>.generate(240, (index) => 500 - index)),
      );

      final refresh = chat.loadMessages(expectedMessageCount: 500);
      await server.waitForRequests(3);
      final staleBackfill = chat.loadEarlierMessages();
      await server.waitForRequests(4);
      expect(server.requests[3].url.queryParameters['offset'], '240');

      // El refresh termina primero y vuelve a declarar que la cola autoritativa
      // empieza en offset cero. La página pedida con el cursor viejo ya no puede
      // modificar ni el orden visible ni el siguiente offset.
      server.complete(2, _rows(120, from: 381), paginated: true);
      await refresh;
      server.complete(3, _rows(120, from: 141), paginated: true);
      expect(await staleBackfill, isFalse);

      expect(
        chat.messages.map((message) => message['id']),
        orderedEquals(List<int>.generate(240, (index) => 500 - index)),
      );
      expect(chat.messages.any((message) => message['id'] == 260), isFalse);

      final retry = chat.loadEarlierMessages();
      await server.waitForRequests(5);
      expect(server.requests[4].url.queryParameters['offset'], '120');
      server.complete(4, _rows(120, from: 261), paginated: true);
      await retry;
    },
  );

  test(
    'Stop invalida un refresh pendiente y su snapshot running obsoleto',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final initialRows = const <Map<String, dynamic>>[
        {'message_id': 'old-user', 'role': 'user', 'content': 'anterior'},
        {
          'message_id': 'old-answer',
          'role': 'assistant',
          'content': 'respuesta anterior',
        },
      ];
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stop-refresh-race',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: 2,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
        );
      final chat = _chat(
        'stop-refresh-race',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(expectedMessageCount: 2);
      await server.waitForRequests(1);
      server.complete(0, initialRows, paginated: false);
      await initialLoad;
      await chat.send(
        fullText: 'turno que se detiene',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );

      final staleResume = Completer<DesktopSessionSnapshot>();
      gateway.resumeGate = staleResume;
      final staleRefresh = chat.loadMessages(expectedMessageCount: 2);
      await server.waitForRequests(2);

      await chat.cancel();
      expect(chat.state, ChatPipelineState.cancelled);
      server.complete(1, initialRows, paginated: false);
      staleResume.complete(
        DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stop-refresh-race',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: 2,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          running: true,
          inflight: DesktopInflightTurn(
            user: 'turno que se detiene',
            assistant: 'parcial obsoleto',
            streaming: true,
          ),
        ),
      );
      await staleRefresh;

      expect(chat.state, ChatPipelineState.cancelled);
      expect(
        chat.messages.any(
          (message) => message['content'] == 'parcial obsoleto',
        ),
        isFalse,
      );
      expect(
        chat.messages.singleWhere(
          (message) => message['content'] == 'turno que se detiene',
        )['_cancelledUser'],
        isTrue,
      );
    },
  );

  test(
    'lifecycle omitido más REST vacío prueba completitud para el primer Stop',
    () async {
      final server = _TranscriptServer(paginate: true);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-empty-complete',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 0,
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'empty-complete-first-stop',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 0);
      expect(chat.messagesLoaded, isTrue);
      expect(chat.hasEarlierMessages, isFalse);

      await chat.send(
        fullText: 'primer turno cancelado',
        model: 'hermes-agent',
        history: const [],
      );
      await chat.cancel();

      expect(recorded, hasLength(1));
      expect(recorded.single.firstUser, isTrue);
      expect(recorded.single.anchorMessageId, isNull);
    },
  );

  test(
    'primer Stop permite continuar tras el terminal sin esperar identidad REST',
    () async {
      final server = _TranscriptServer(paginate: true);
      final gateway = _DeferrableGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-first-stop-follow-up',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 0,
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'first-stop-follow-up',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 0);
      await chat.send(
        fullText: 'primer turno cancelado',
        model: 'hermes-agent',
        history: const [],
      );
      await chat.cancel();
      await Future<void>.delayed(Duration.zero);
      gateway.emit(
        'message.complete',
        payload: const {'text': 'Operation interrupted.'},
      );
      await Future<void>.delayed(Duration.zero);

      final accepted = await chat.send(
        fullText: 'puedes continuar',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );

      expect(accepted, isTrue);
      expect(recorded, hasLength(1));
      expect(recorded.single.firstUser, isTrue);
      expect(chat.lastPrompt, 'puedes continuar');
    },
  );

  test(
    'REST vacío conserva completitud llegando antes o después del snapshot',
    () async {
      for (final restFirst in <bool>[true, false]) {
        final server = _OutOfOrderTranscriptServer();
        final resumeGate = Completer<DesktopSessionSnapshot>();
        final gateway = _DeferrableGateway()
          ..snapshot = DesktopSessionSnapshot(
            runtimeSessionId: 'runtime-empty-order-$restFirst',
            storedSessionId: 'stored-chat',
            created: false,
            messagesProvided: false,
            messageCount: 0,
            running: !restFirst,
            inflight: restFirst
                ? null
                : DesktopInflightTurn(user: 'primer Stop false'),
          )
          ..resumeGate = resumeGate;
        final recorded = <CancelledTurnTombstone>[];
        final chat = _chat(
          'empty-order-$restFirst',
          server.client(),
          gateway: gateway,
          onCancelledTurn: (tombstone) async => recorded.add(tombstone),
        );
        addTearDown(chat.dispose);

        final load = chat.loadMessages(expectedMessageCount: 0);
        await server.waitForRequests(1);
        if (restFirst) {
          server.complete(0, const [], paginated: true);
          for (var tick = 0; tick < 5; tick++) {
            await Future<void>.delayed(Duration.zero);
          }
          resumeGate.complete(gateway.snapshot!);
        } else {
          resumeGate.complete(gateway.snapshot!);
          for (var tick = 0; tick < 5; tick++) {
            await Future<void>.delayed(Duration.zero);
          }
          server.complete(0, const [], paginated: true);
        }
        await load;

        expect(chat.messagesLoaded, isTrue, reason: 'restFirst=$restFirst');
        expect(
          chat.hasEarlierMessages,
          isFalse,
          reason: 'restFirst=$restFirst',
        );
        if (restFirst) {
          await chat.send(
            fullText: 'primer Stop true',
            model: 'hermes-agent',
            history: const [],
          );
        }
        await chat.cancel();
        expect(
          recorded.single.firstUser,
          isTrue,
          reason: 'restFirst=$restFirst',
        );
      }
    },
  );

  test(
    'REST vacío no borra el primer turno vivo mientras resume sigue pendiente',
    () async {
      const binding = DesktopSessionBinding(
        runtimeSessionId: 'runtime-live-over-empty-rest',
        storedSessionId: 'stored-chat',
        created: true,
      );
      final server = _OutOfOrderTranscriptServer();
      final gateway = _DeferrableGateway()
        ..snapshot = binding
        ..createSnapshot = binding;
      final chat = _chat(
        'live-over-empty-rest',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      chat.markStoredSessionMissing();
      await chat.send(
        fullText: 'primer turno todavía vivo',
        model: 'hermes-agent',
        history: const [],
      );

      final resumeGate = Completer<DesktopSessionSnapshot>();
      gateway.resumeGate = resumeGate;
      final refresh = chat.loadMessages(expectedMessageCount: 0);
      await server.waitForRequests(1);
      server.complete(0, const [], paginated: true);
      for (var tick = 0; tick < 10; tick++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(
        chat.messages.any(
          (message) => message['content'] == 'primer turno todavía vivo',
        ),
        isTrue,
      );
      expect(
        chat.messages.any(
          (message) =>
              message['role'] == 'assistant' && message['_pipeline'] == true,
        ),
        isTrue,
      );

      resumeGate.completeError(StateError('resume aún no disponible'));
      await refresh;
      expect(chat.isStreaming, isTrue);
      expect(
        chat.messages.any(
          (message) => message['content'] == 'primer turno todavía vivo',
        ),
        isTrue,
      );
      expect(
        chat.messages.any(
          (message) =>
              message['role'] == 'assistant' && message['_pipeline'] == true,
        ),
        isTrue,
      );
    },
  );

  test(
    'REST vacío con count cero no sella una cola durable parcial retenida',
    () async {
      final partialTail = <Map<String, dynamic>>[
        const {
          'id': 'partial-oldest-user-empty-rest',
          'role': 'user',
          'content': 'prompt repetido en cola durable parcial',
        },
        const {
          'id': 'partial-legitimate-answer-empty-rest',
          'role': 'assistant',
          'content': 'respuesta legítima de la cola parcial',
        },
        for (var index = 0; index < 118; index++)
          {
            'id': 'partial-context-empty-rest-$index',
            'role': 'system',
            'content': 'contexto parcial $index',
          },
      ];
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll(partialTail);
      final gateway = _DeferrableGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-partial-before-empty-rest',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 300,
        );
      final chat = _chat(
        'partial-durable-over-empty-rest',
        server.client(),
        gateway: gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido en cola durable parcial',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      expect(chat.hasEarlierMessages, isTrue);
      expect(
        chat.messages.any(
          (message) => message['id'] == 'partial-legitimate-answer-empty-rest',
        ),
        isTrue,
      );

      server.rows.clear();
      gateway.resumeError = StateError(
        'snapshot no disponible durante refresh',
      );
      await chat.loadMessages(expectedMessageCount: 0);

      expect(chat.hasEarlierMessages, isTrue);
      expect(
        chat.messages.any(
          (message) => message['id'] == 'partial-legitimate-answer-empty-rest',
        ),
        isTrue,
      );
      final oldestVisible = chat.messages.singleWhere(
        (message) => message['id'] == 'partial-oldest-user-empty-rest',
      );
      expect(oldestVisible.containsKey('_cancelledUser'), isFalse);
    },
  );

  test(
    'REST vacío nunca borra un snapshot Desktop completo no vacío',
    () async {
      for (final restFirst in <bool>[true, false]) {
        final server = _OutOfOrderTranscriptServer();
        final resumeGate = Completer<DesktopSessionSnapshot>();
        final snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-complete-over-empty-$restFirst',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: 2,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'message_id': 'snapshot-user',
              'role': 'user',
              'content': 'historial Desktop',
            })!,
            DesktopSessionMessage.tryParse(const {
              'message_id': 'snapshot-answer',
              'role': 'assistant',
              'content': 'respuesta Desktop',
            })!,
          ],
        );
        final gateway = _DeferrableGateway()
          ..snapshot = snapshot
          ..resumeGate = resumeGate;
        final chat = _chat(
          'complete-over-empty-$restFirst',
          server.client(),
          gateway: gateway,
        );
        addTearDown(chat.dispose);

        final load = chat.loadMessages(expectedMessageCount: 0);
        await server.waitForRequests(1);
        if (restFirst) {
          server.complete(0, const [], paginated: true);
          for (var tick = 0; tick < 5; tick++) {
            await Future<void>.delayed(Duration.zero);
          }
          resumeGate.complete(snapshot);
        } else {
          resumeGate.complete(snapshot);
          for (var tick = 0; tick < 5; tick++) {
            await Future<void>.delayed(Duration.zero);
          }
          server.complete(0, const [], paginated: true);
        }
        await load;

        expect(chat.messages, hasLength(2), reason: 'restFirst=$restFirst');
        expect(
          chat.internalMessagesForTesting.map(canonicalTranscriptMessageId),
          ['snapshot-answer', 'snapshot-user'],
          reason: 'restFirst=$restFirst',
        );
        expect(chat.hasEarlierMessages, isFalse);
      }
    },
  );

  test(
    'REST vacío conserva snapshot hydrating parcial en ambos órdenes',
    () async {
      for (final restFirst in <bool>[true, false]) {
        final server = _OutOfOrderTranscriptServer();
        final resumeGate = Completer<DesktopSessionSnapshot>();
        final snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-partial-over-empty-$restFirst',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: 4,
          hydrating: true,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'message_id': 'partial-user',
              'role': 'user',
              'content': 'cola parcial Desktop',
            })!,
            DesktopSessionMessage.tryParse(const {
              'message_id': 'partial-answer',
              'role': 'assistant',
              'content': 'respuesta parcial Desktop',
            })!,
          ],
        );
        final gateway = _DeferrableGateway()
          ..snapshot = snapshot
          ..resumeGate = resumeGate;
        final chat = _chat(
          'partial-over-empty-$restFirst',
          server.client(),
          gateway: gateway,
        );
        addTearDown(chat.dispose);

        final load = chat.loadMessages(expectedMessageCount: 0);
        await server.waitForRequests(1);
        if (restFirst) {
          server.complete(0, const [], paginated: true);
          for (var tick = 0; tick < 5; tick++) {
            await Future<void>.delayed(Duration.zero);
          }
          resumeGate.complete(snapshot);
        } else {
          resumeGate.complete(snapshot);
          for (var tick = 0; tick < 5; tick++) {
            await Future<void>.delayed(Duration.zero);
          }
          server.complete(0, const [], paginated: true);
        }
        await load;

        expect(chat.messages, hasLength(2), reason: 'restFirst=$restFirst');
        expect(
          chat.internalMessagesForTesting.map(canonicalTranscriptMessageId),
          ['partial-answer', 'partial-user'],
          reason: 'restFirst=$restFirst',
        );
        expect(chat.hasEarlierMessages, isTrue);
      }
    },
  );

  test(
    'REST vacío no sella un ack hydrating vacío con count positivo',
    () async {
      for (final restFirst in <bool>[true, false]) {
        final server = _OutOfOrderTranscriptServer();
        final resumeGate = Completer<DesktopSessionSnapshot>();
        final snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-empty-hydrating-$restFirst',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: 300,
          hydrating: true,
          running: true,
          inflight: DesktopInflightTurn(
            user: 'turno activo mientras llega el historial',
            streaming: true,
          ),
        );
        final gateway = _DeferrableGateway()
          ..snapshot = snapshot
          ..resumeGate = resumeGate;
        final chat = _chat(
          'empty-hydrating-count-$restFirst',
          server.client(),
          gateway: gateway,
        );
        addTearDown(chat.dispose);

        final load = chat.loadMessages(expectedMessageCount: 0);
        await server.waitForRequests(1);
        if (restFirst) {
          server.complete(0, const [], paginated: true);
          for (var tick = 0; tick < 5; tick++) {
            await Future<void>.delayed(Duration.zero);
          }
          resumeGate.complete(snapshot);
        } else {
          resumeGate.complete(snapshot);
          for (var tick = 0; tick < 5; tick++) {
            await Future<void>.delayed(Duration.zero);
          }
          server.complete(0, const [], paginated: true);
        }
        await load;

        expect(
          chat.internalMessagesForTesting.any(
            (message) => message['_desktopSnapshotKind'] == 'inflight',
          ),
          isTrue,
          reason: 'restFirst=$restFirst',
        );
        expect(chat.hasEarlierMessages, isTrue, reason: 'restFirst=$restFirst');

        gateway.emitResumeProgress('complete', messageCount: 300);
        for (
          var attempt = 0;
          attempt < 50 && server.requests.length < 2;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(server.requests, hasLength(2), reason: 'restFirst=$restFirst');
        expect(
          server.requests[1].url.queryParameters['offset'],
          '0',
          reason: 'restFirst=$restFirst',
        );
        server.complete(1, const [
          {'id': 299, 'role': 'user', 'content': 'pregunta durable'},
          {'id': 300, 'role': 'assistant', 'content': 'respuesta durable'},
        ], paginated: true);
        for (
          var attempt = 0;
          attempt < 50 && !chat.messages.any((message) => message['id'] == 300);
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(
          chat.messages.any((message) => message['id'] == 300),
          isTrue,
          reason: 'restFirst=$restFirst',
        );
        expect(chat.hasEarlierMessages, isTrue, reason: 'restFirst=$restFirst');
      }
    },
  );

  test('REST corto no acredita el count mayor de un ack hydrating', () async {
    for (final restFirst in <bool>[true, false]) {
      final server = _OutOfOrderTranscriptServer();
      final resumeGate = Completer<DesktopSessionSnapshot>();
      final snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-short-rest-hydrating-$restFirst',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: true,
        messages: const [],
        messageCount: 300,
        hydrating: true,
      );
      final gateway = _DeferrableGateway()
        ..snapshot = snapshot
        ..resumeGate = resumeGate;
      final chat = _chat(
        'short-rest-hydrating-$restFirst',
        server.client(),
        gateway: gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido durante hydration',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);
      final rows = <Map<String, dynamic>>[
        {
          'message_id': 'short-hydrating-user-$restFirst',
          'role': 'user',
          'content': 'prompt repetido durante hydration',
        },
        {
          'message_id': 'short-hydrating-answer-$restFirst',
          'role': 'assistant',
          'content': 'respuesta legítima de REST corto',
        },
      ];

      final load = chat.loadMessages(expectedMessageCount: 300);
      await server.waitForRequests(1);
      if (restFirst) {
        server.complete(0, rows, paginated: true);
        for (var tick = 0; tick < 5; tick++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(
          chat.messages.any(
            (message) =>
                canonicalTranscriptMessageId(message) ==
                'short-hydrating-answer-$restFirst',
          ),
          isTrue,
          reason: 'REST no debe ocultar antes de conocer el ack Desktop',
        );
        resumeGate.complete(snapshot);
      } else {
        resumeGate.complete(snapshot);
        for (var tick = 0; tick < 5; tick++) {
          await Future<void>.delayed(Duration.zero);
        }
        server.complete(0, rows, paginated: true);
      }
      await load;

      expect(
        chat.messages.any(
          (message) =>
              canonicalTranscriptMessageId(message) ==
                  'short-hydrating-answer-$restFirst' &&
              message['content'] == 'respuesta legítima de REST corto',
        ),
        isTrue,
        reason: 'restFirst=$restFirst',
      );
      expect(
        chat.messages
            .singleWhere(
              (message) =>
                  canonicalTranscriptMessageId(message) ==
                  'short-hydrating-user-$restFirst',
            )
            .containsKey('_cancelledUser'),
        isFalse,
        reason: 'restFirst=$restFirst',
      );
      expect(chat.hasEarlierMessages, isTrue, reason: 'restFirst=$restFirst');
    }
  });

  test(
    'resume_progress con REST aún vacío conserva cobertura parcial y Stop seguro',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-empty-progress-retry',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 300,
        hydrating: true,
        running: true,
        inflight: DesktopInflightTurn(
          user: 'turno sintético sin transcript durable',
          streaming: true,
        ),
      );
      final gateway = _DeferrableGateway()..snapshot = snapshot;
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'empty-progress-retry',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      final load = chat.loadMessages(expectedMessageCount: 300);
      await server.waitForRequests(1);
      server.complete(0, const [], paginated: true);
      await load;
      expect(chat.hasEarlierMessages, isTrue);

      gateway.emitResumeProgress('complete', messageCount: 300);
      await server.waitForRequests(2);
      expect(server.requests[1].url.queryParameters['offset'], '0');
      server.complete(1, const [], paginated: true);
      for (var tick = 0; tick < 20; tick++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(chat.hasEarlierMessages, isTrue);
      await expectLater(chat.cancel(), throwsStateError);
      expect(recorded.where((tombstone) => tombstone.firstUser), isEmpty);
      expect(chat.isStreaming, isTrue);
    },
  );

  test(
    'resume_progress complete sustituye count viejo tras compactación 300 a 2',
    () async {
      final server = _TranscriptServer(paginate: true);
      final gateway = _DeferrableGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-hydration-compacted-count',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 300,
          hydrating: true,
        );
      final chat = _chat(
        'hydration-compacted-count',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final load = chat.loadMessages(expectedMessageCount: 300);
      for (
        var attempt = 0;
        attempt < 100 && !chat.isHydratingDesktopHistory;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      server.rows.addAll(const [
        {'id': 'compact-user', 'role': 'user', 'content': 'turno compacto'},
        {
          'id': 'compact-answer',
          'role': 'assistant',
          'content': 'respuesta compacta',
        },
      ]);
      gateway.emitResumeProgress('complete', messageCount: 2);
      await load;

      expect(chat.messages, hasLength(2));
      expect(chat.messages.first['id'], 'compact-answer');
      expect(chat.hasEarlierMessages, isFalse);
      expect(server.requests, hasLength(2));
      expect(server.requests.last.queryParameters['offset'], '0');
    },
  );

  test(
    'scroll y resume_progress solapados no rebobinan la cola hidratada a offset cero',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final gateway = _DeferrableGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-overlapping-tail-hydration',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 300,
          hydrating: true,
        );
      final chat = _chat(
        'overlapping-tail-hydration',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(expectedMessageCount: 300);
      await server.waitForRequests(1);
      server.complete(0, _rows(120, from: 181), paginated: true);
      await initialLoad;
      expect(chat.hasEarlierMessages, isTrue);

      final scrollHydration = chat.loadEarlierMessages();
      await server.waitForRequests(2);
      expect(server.requests[1].url.queryParameters['offset'], '0');

      gateway.emitResumeProgress('complete', messageCount: 300);
      await server.waitForRequests(3);
      expect(server.requests[2].url.queryParameters['offset'], '0');

      // El gesto publica primero una cola válida llena (cursor siguiente 120).
      server.complete(1, _rows(120, from: 181), paginated: true);
      expect(await scrollHydration, isTrue);

      // La rehidratación diferida, pedida bajo la revisión anterior, termina
      // después con una cola corta todavía no lista. No puede rebobinar a 0.
      server.complete(2, const [
        {'id': 299, 'role': 'user', 'content': 'msg 299'},
        {'id': 300, 'role': 'assistant', 'content': 'msg 300'},
      ], paginated: true);
      for (var tick = 0; tick < 10; tick++) {
        await Future<void>.delayed(Duration.zero);
      }

      final nextBackfill = chat.loadEarlierMessages();
      await server.waitForRequests(4);
      expect(server.requests[3].url.queryParameters['offset'], '120');
      server.complete(3, _rows(120, from: 61), paginated: true);
      expect(await nextBackfill, isTrue);
    },
  );

  test(
    'snapshot running omitido sin ancla no revive el primer turno ya terminal',
    () async {
      final server = _TranscriptServer(paginate: true);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stale-first-running',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 2,
          hydrating: true,
          running: true,
          inflight: DesktopInflightTurn(
            user: 'primer turno todavía sintético',
            assistant: 'respuesta parcial',
            streaming: true,
          ),
        );
      final chat = _chat(
        'stale-first-running-without-anchor',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      expect(chat.isStreaming, isTrue);
      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta final local'},
      );
      for (
        var attempt = 0;
        attempt < 200 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(chat.state, ChatPipelineState.completed);

      // REST sigue vacío y Desktop repite el mismo ack running sin mensajes.
      // Sin ID, ancla ni transcript completo no existe autoridad para abrir
      // otro epoch ni para sustituir la respuesta terminal que ya vio el user.
      await chat.loadMessages(expectedMessageCount: 2);

      expect(chat.isStreaming, isFalse);
      expect(
        chat.messages.where(
          (message) => message['content'] == 'primer turno todavía sintético',
        ),
        hasLength(1),
      );
      expect(
        chat.messages.where(
          (message) => message['content'] == 'respuesta final local',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'REST con solo user canónico no borra el assistant terminal local sin ancla',
    () async {
      final server = _TranscriptServer(paginate: true);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-first-user-only-after-terminal',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 2,
          hydrating: true,
          running: true,
          inflight: DesktopInflightTurn(
            user: 'primer turno sin ancla durable',
            assistant: 'parcial local',
            streaming: true,
          ),
        );
      final chat = _chat(
        'first-user-only-after-terminal',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta final local sin ancla'},
      );
      for (
        var attempt = 0;
        attempt < 200 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(chat.state, ChatPipelineState.completed);

      server.rows.add(const {
        'id': 'first-user-canonical-only',
        'role': 'user',
        'content': 'primer turno sin ancla durable',
      });
      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-first-user-only-after-terminal',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 1,
      );
      await chat.loadMessages(expectedMessageCount: 1);

      expect(chat.isStreaming, isFalse);
      expect(
        chat.messages.where(
          (message) => message['content'] == 'respuesta final local sin ancla',
        ),
        hasLength(1),
      );
      expect(
        chat.messages.any(
          (message) => message['_localTerminalProjectionId'] != null,
        ),
        isFalse,
      );
    },
  );

  test(
    'REST histórico completo no borra un terminal local todavía sin ancla',
    () async {
      final server = _TranscriptServer(paginate: false);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stale-history-after-terminal',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 2,
          hydrating: true,
          running: true,
          inflight: DesktopInflightTurn(
            user: 'primer turno local sin ancla',
            assistant: 'respuesta parcial local',
            streaming: true,
          ),
        );
      final chat = _chat(
        'stale-history-after-terminal',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta final local todavía no persistida'},
      );
      for (
        var attempt = 0;
        attempt < 200 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(chat.state, ChatPipelineState.completed);

      // REST legacy aún solo conoce un turno histórico distinto y por eso lo
      // anuncia como transcript completo. Sin identidad, ancla u ordinal que
      // ubique el terminal local, ese contenido no demuestra un turno nuevo.
      server.rows.addAll(const [
        {
          'id': 'stale-old-user',
          'role': 'user',
          'content': 'turno histórico anterior',
        },
        {
          'id': 'stale-old-answer',
          'role': 'assistant',
          'content': 'respuesta histórica anterior',
        },
      ]);
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-stale-history-after-terminal',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 2,
      );
      await chat.loadMessages(expectedMessageCount: 2);

      expect(chat.isStreaming, isFalse);
      expect(
        chat.messages.where(
          (message) => message['content'] == 'primer turno local sin ancla',
        ),
        hasLength(1),
      );
      expect(
        chat.messages.where(
          (message) =>
              message['content'] ==
              'respuesta final local todavía no persistida',
        ),
        hasLength(1),
      );
      expect(
        chat.messages.any(
          (message) => message['_localTerminalProjectionId'] != null,
        ),
        isFalse,
      );
    },
  );

  test(
    'snapshot omitido no confunde inflight con un cancelado de igual texto',
    () async {
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(const [
          {
            'message_id': 'before-cancel',
            'role': 'assistant',
            'content': 'respuesta anterior',
          },
          {
            'message_id': 'cancelled-user',
            'role': 'user',
            'content': 'prompt repetido',
          },
          {
            'message_id': 'cancelled-answer',
            'role': 'assistant',
            'content': 'respuesta cancelada que no debe volver',
          },
        ]);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-repeated-inflight',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 3,
          hydrating: true,
          running: true,
          inflight: DesktopInflightTurn(user: 'prompt repetido'),
        );
      final chat = _chat(
        'repeated-cancelled-inflight',
        server.client(),
        gateway: gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido',
            anchorMessageId: 'before-cancel',
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 3);

      final repeatedUsers = chat.internalMessagesForTesting
          .where(
            (message) =>
                isRealUserTurn(message) &&
                message['content'] == 'prompt repetido',
          )
          .toList(growable: false);
      expect(repeatedUsers, hasLength(2));
      expect(
        repeatedUsers.singleWhere(
          (message) =>
              canonicalTranscriptMessageId(message) == 'cancelled-user',
        )['_cancelledUser'],
        isTrue,
      );
      expect(
        repeatedUsers.any(
          (message) => message['_desktopSnapshotKind'] == 'inflight',
        ),
        isTrue,
      );
      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'respuesta cancelada que no debe volver',
        ),
        isFalse,
      );
    },
  );

  test(
    'snapshot hydrating parcial rehidrata offset cero ante scroll temprano',
    () async {
      final server = _TranscriptServer(paginate: true)
        ..healthy = false
        ..rows.addAll(const [
          {'id': 1, 'role': 'user', 'content': 'uno'},
          {'id': 2, 'role': 'assistant', 'content': 'dos'},
          {'id': 3, 'role': 'user', 'content': 'tres'},
          {'id': 4, 'role': 'assistant', 'content': 'cuatro'},
        ]);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-hydrating-early-scroll',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: 4,
          hydrating: true,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'id': 3,
              'role': 'user',
              'content': 'tres',
            })!,
            DesktopSessionMessage.tryParse(const {
              'id': 4,
              'role': 'assistant',
              'content': 'cuatro',
            })!,
          ],
        );
      final chat = _chat(
        'hydrating-early-scroll',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 4);
      expect(chat.messages, hasLength(2));
      expect(chat.hasEarlierMessages, isTrue);

      server.healthy = true;
      expect(await chat.loadEarlierMessages(), isTrue);

      expect(server.requests.last.queryParameters['offset'], '0');
      expect(chat.messages, hasLength(4));
      expect(chat.messages.first['id'], 4);
      expect(chat.messages.last['id'], 1);
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'count hydrating bajo o exacto no sella una cola llena ni bloquea offset 120',
    () async {
      for (final announcedCount in const [2, 120]) {
        final server = _TranscriptServer(paginate: true)
          ..rows.addAll(_rows(240));
        final gateway = _DeferrableGateway()
          ..snapshot = DesktopSessionSnapshot(
            runtimeSessionId: 'runtime-stale-count-$announcedCount',
            storedSessionId: 'stored-chat',
            created: false,
            messagesProvided: false,
            messageCount: announcedCount,
            hydrating: true,
          );
        final chat = _chat(
          'stale-hydration-count-$announcedCount',
          server.client(),
          gateway: gateway,
        );
        addTearDown(chat.dispose);

        await chat.loadMessages(expectedMessageCount: announcedCount);
        expect(chat.hasEarlierMessages, isTrue, reason: '$announcedCount');

        expect(
          await chat.loadEarlierMessages(),
          isTrue,
          reason: '$announcedCount',
        );
        expect(server.requests.last.queryParameters['offset'], '0');
        expect(chat.hasEarlierMessages, isTrue, reason: '$announcedCount');

        expect(
          await chat.loadEarlierMessages(),
          isTrue,
          reason: '$announcedCount',
        );
        expect(server.requests.last.queryParameters['offset'], '120');
        expect(chat.messages.last['id'], 1, reason: '$announcedCount');
      }
    },
  );

  test(
    'refresh vacío con count duro conserva filas y arma recuperación',
    () async {
      final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(300));
      final chat = _chat('empty-refresh', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      expect(chat.messages, hasLength(120));
      expect(chat.hasEarlierMessages, isTrue);

      server.rows.clear();
      await expectLater(
        chat.loadMessages(expectedMessageCount: 300),
        throwsStateError,
      );

      expect(chat.messages, hasLength(120));
      expect(chat.messages.first['content'], 'msg 300');
      expect(chat.hasEarlierMessages, isTrue);
      expect(chat.earlierMessagesNextOffsetForTesting, 0);
      expect(chat.needsTranscriptTailHydrationForTesting, isTrue);
      server.rows.addAll(_rows(300));
      expect(await chat.loadEarlierMessages(), isTrue);
    },
  );

  test(
    'snapshot completo que llega primero no es recortado por la cola REST',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final snapshotRows = <Map<String, dynamic>>[
        for (var index = 1; index <= 300; index++)
          {
            'message_id': 'desktop-$index',
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'desktop msg $index',
          },
      ];
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-snapshot-first',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: snapshotRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 300,
        );
      final chat = _chat('snapshot-first', server.client(), gateway: gateway);
      addTearDown(chat.dispose);

      final load = chat.loadMessages(expectedMessageCount: 300);
      await server.waitForRequests(1);
      while (chat.messages.length != 300) {
        await Future<void>.delayed(Duration.zero);
      }

      server.complete(0, snapshotRows.sublist(180), paginated: true);
      await load;

      expect(chat.messages, hasLength(300));
      expect(chat.messages.first['content'], 'desktop msg 300');
      expect(chat.messages.last['content'], 'desktop msg 1');
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'snapshot completo que llega tras REST conserva toda su cobertura',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final snapshotRows = <Map<String, dynamic>>[
        for (var index = 1; index <= 300; index++)
          {
            'message_id': 'rest-first-$index',
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'rest first $index',
          },
      ];
      final resumeGate = Completer<DesktopSessionSnapshot>();
      final gateway = _DeferrableGateway()..resumeGate = resumeGate;
      final chat = _chat('rest-first', server.client(), gateway: gateway);
      addTearDown(chat.dispose);

      final load = chat.loadMessages(expectedMessageCount: 300);
      await server.waitForRequests(1);
      server.complete(0, snapshotRows.sublist(180), paginated: true);
      while (chat.messages.length != 120) {
        await Future<void>.delayed(Duration.zero);
      }
      resumeGate.complete(
        DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-rest-first',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: snapshotRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 300,
        ),
      );
      await load;

      expect(chat.messages, hasLength(300));
      expect(chat.messages.first['content'], 'rest first 300');
      expect(chat.messages.last['content'], 'rest first 1');
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'snapshot Desktop row_id injerta la cola REST id numérica exacta',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final restRows = <Map<String, dynamic>>[
        for (var index = 1; index <= 300; index++)
          {
            'id': index,
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'fila compartida $index',
          },
      ];
      final desktopRows = <Map<String, dynamic>>[
        for (var index = 1; index <= 300; index++)
          {
            'row_id': index,
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'fila compartida $index',
          },
      ];
      final resumeGate = Completer<DesktopSessionSnapshot>();
      final gateway = _DeferrableGateway()..resumeGate = resumeGate;
      final chat = _chat('rest-row-first', server.client(), gateway: gateway);
      addTearDown(chat.dispose);

      final load = chat.loadMessages(expectedMessageCount: 300);
      await server.waitForRequests(1);
      server.complete(0, restRows.sublist(180), paginated: true);
      while (chat.messages.length != 120) {
        await Future<void>.delayed(Duration.zero);
      }
      resumeGate.complete(
        DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-rest-row-first',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: desktopRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 300,
        ),
      );
      await load;

      expect(chat.messages, hasLength(300));
      expect(
        canonicalTranscriptRowId(chat.internalMessagesForTesting.first),
        300,
      );
      expect(canonicalTranscriptRowId(chat.internalMessagesForTesting.last), 1);
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'snapshot Desktop con dos coordenadas injerta REST por row id sin duplicar',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final restRows = <Map<String, dynamic>>[
        for (var index = 1; index <= 300; index++)
          {
            'id': index,
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'fila dual $index',
          },
      ];
      final desktopRows = <Map<String, dynamic>>[
        for (var index = 1; index <= 300; index++)
          {
            'message_id': 'message-$index',
            'row_id': index,
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'fila dual $index',
          },
      ];
      final resumeGate = Completer<DesktopSessionSnapshot>();
      final gateway = _DeferrableGateway()..resumeGate = resumeGate;
      final chat = _chat('rest-dual-first', server.client(), gateway: gateway);
      addTearDown(chat.dispose);

      final load = chat.loadMessages(expectedMessageCount: 300);
      await server.waitForRequests(1);
      server.complete(0, restRows.sublist(180), paginated: true);
      while (chat.messages.length != 120) {
        await Future<void>.delayed(Duration.zero);
      }
      resumeGate.complete(
        DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-rest-dual-first',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: desktopRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 300,
        ),
      );
      await load;

      expect(chat.messages, hasLength(300));
      expect(
        canonicalTranscriptRowId(chat.internalMessagesForTesting.first),
        300,
      );
      expect(canonicalTranscriptRowId(chat.internalMessagesForTesting.last), 1);
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'cola REST parcial nueva vence a snapshot completo viejo que llega primero',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final staleRows = <Map<String, dynamic>>[
        for (var index = 1; index <= 300; index++)
          {
            'message_id': '$index',
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'snapshot viejo $index',
          },
      ];
      final freshTail = <Map<String, dynamic>>[
        for (var index = 182; index <= 301; index++)
          {
            'message_id': '$index',
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'cola REST nueva $index',
          },
      ];
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stale-before-partial-rest',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: staleRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 300,
        );
      final chat = _chat(
        'partial-rest-after-stale-snapshot',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final load = chat.loadMessages(expectedMessageCount: 301);
      await server.waitForRequests(1);
      while (chat.messages.length != 300) {
        await Future<void>.delayed(Duration.zero);
      }
      server.complete(0, freshTail, paginated: true);
      await load;

      expect(canonicalTranscriptMessageId(chat.messages.first), '301');
      expect(
        canonicalTranscriptMessageId(chat.internalMessagesForTesting.last),
        '1',
      );
      expect(chat.messages, hasLength(301));
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'cola REST parcial nueva vence a snapshot completo viejo que llega después',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final resumeGate = Completer<DesktopSessionSnapshot>();
      final gateway = _DeferrableGateway()..resumeGate = resumeGate;
      final staleRows = <Map<String, dynamic>>[
        for (var index = 1; index <= 300; index++)
          {
            'message_id': '$index',
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'snapshot tardío viejo $index',
          },
      ];
      final freshTail = <Map<String, dynamic>>[
        for (var index = 182; index <= 301; index++)
          {
            'message_id': '$index',
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'cola REST primero $index',
          },
      ];
      final chat = _chat(
        'partial-rest-before-stale-snapshot',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final load = chat.loadMessages(expectedMessageCount: 301);
      await server.waitForRequests(1);
      server.complete(0, freshTail, paginated: true);
      while (chat.messages.length != 120) {
        await Future<void>.delayed(Duration.zero);
      }
      resumeGate.complete(
        DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stale-after-partial-rest',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: staleRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 300,
        ),
      );
      await load;

      expect(canonicalTranscriptMessageId(chat.messages.first), '301');
      expect(
        canonicalTranscriptMessageId(chat.internalMessagesForTesting.last),
        '1',
      );
      expect(chat.messages, hasLength(301));
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'REST completo compacto que llega tras snapshot vence al snapshot viejo',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final staleRows = <Map<String, dynamic>>[
        for (var index = 1; index <= 300; index++)
          {
            'message_id': 'stale-snapshot-$index',
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'snapshot viejo $index',
          },
      ];
      final compactRows = <Map<String, dynamic>>[
        {
          'message_id': 'rest-compact-user',
          'role': 'user',
          'content': 'resumen REST',
        },
        {
          'message_id': 'rest-compact-answer',
          'role': 'assistant',
          'content': 'respuesta REST compacta',
        },
      ];
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stale-snapshot-first',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: staleRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: staleRows.length,
        );
      final chat = _chat(
        'rest-compact-after-snapshot',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final load = chat.loadMessages(expectedMessageCount: staleRows.length);
      await server.waitForRequests(1);
      while (chat.messages.length != staleRows.length) {
        await Future<void>.delayed(Duration.zero);
      }
      server.complete(0, compactRows, paginated: false);
      await load;

      expect(chat.messages, hasLength(2));
      expect(chat.messages.first['message_id'], 'rest-compact-answer');
      expect(chat.messages.last['message_id'], 'rest-compact-user');
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'REST completo compacto sigue mandando si snapshot viejo llega después',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final resumeGate = Completer<DesktopSessionSnapshot>();
      final gateway = _DeferrableGateway()..resumeGate = resumeGate;
      final compactRows = <Map<String, dynamic>>[
        {
          'message_id': 'rest-first-compact-user',
          'role': 'user',
          'content': 'resumen REST primero',
        },
        {
          'message_id': 'rest-first-compact-answer',
          'role': 'assistant',
          'content': 'respuesta REST primero',
        },
      ];
      final staleRows = <Map<String, dynamic>>[
        for (var index = 1; index <= 300; index++)
          {
            'message_id': 'late-stale-snapshot-$index',
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'snapshot tardío viejo $index',
          },
      ];
      final chat = _chat(
        'rest-compact-before-snapshot',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final load = chat.loadMessages(expectedMessageCount: staleRows.length);
      await server.waitForRequests(1);
      server.complete(0, compactRows, paginated: false);
      while (chat.messages.length != compactRows.length) {
        await Future<void>.delayed(Duration.zero);
      }
      resumeGate.complete(
        DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stale-snapshot-late',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: staleRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: staleRows.length,
        ),
      );
      await load;

      expect(chat.messages, hasLength(2));
      expect(chat.messages.first['message_id'], 'rest-first-compact-answer');
      expect(chat.messages.last['message_id'], 'rest-first-compact-user');
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'refresh REST atrasado conserva user y placeholder del turno vivo',
    () async {
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(const [
          {'id': 'old-user', 'role': 'user', 'content': 'turno anterior'},
          {
            'id': 'old-answer',
            'role': 'assistant',
            'content': 'respuesta anterior',
          },
        ]);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-refresh-live',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: 2,
          messages: server.rows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
        );
      final chat = _chat(
        'refresh-live-local-tail',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      await chat.send(
        fullText: 'turno vivo todavía no persistido',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      final resumeGate = Completer<DesktopSessionSnapshot>();
      gateway.resumeGate = resumeGate;
      final refresh = chat.loadMessages(expectedMessageCount: 2);
      while (server.requests.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(Duration.zero);

      expect(chat.isStreaming, isTrue);
      expect(
        chat.messages.any(
          (message) => message['content'] == 'turno vivo todavía no persistido',
        ),
        isTrue,
      );
      expect(
        chat.messages.any(
          (message) =>
              message['role'] == 'assistant' && message['_pipeline'] == true,
        ),
        isTrue,
      );

      resumeGate.completeError(StateError('stale resume failed'));
      await refresh;
    },
  );

  for (final scenario in const [
    (
      name: 'REST primero',
      snapshotFirst: false,
      snapshotIncludesUser: false,
      snapshotRunning: false,
    ),
    (
      name: 'snapshot primero',
      snapshotFirst: true,
      snapshotIncludesUser: false,
      snapshotRunning: false,
    ),
    (
      name: 'snapshot con user sin assistant',
      snapshotFirst: true,
      snapshotIncludesUser: true,
      snapshotRunning: false,
    ),
    (
      name: 'snapshot running obsoleto',
      snapshotFirst: true,
      snapshotIncludesUser: false,
      snapshotRunning: true,
    ),
  ]) {
    test('refresh completo atrasado conserva un turno recién terminado '
        '(${scenario.name})', () async {
      const oldRows = <Map<String, dynamic>>[
        {'id': 'old-user', 'role': 'user', 'content': 'turno anterior'},
        {
          'id': 'old-answer',
          'role': 'assistant',
          'content': 'respuesta anterior',
        },
      ];
      final server = _OutOfOrderTranscriptServer();
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-refresh-terminal-stale',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: oldRows.length,
          messages: oldRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
        );
      final chat = _chat(
        'refresh-terminal-stale-${scenario.name}',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(
        expectedMessageCount: oldRows.length,
      );
      await server.waitForRequests(1);
      server.complete(0, oldRows, paginated: false);
      await initialLoad;
      await chat.send(
        fullText: 'turno terminado todavía no persistido',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta terminal todavía no persistida'},
      );
      await server.waitForRequests(2);
      server.complete(1, oldRows, paginated: false);
      for (
        var attempt = 0;
        attempt < 100 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(chat.state, ChatPipelineState.completed);
      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'turno terminado todavía no persistido',
        ),
        isTrue,
      );
      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'respuesta terminal todavía no persistida',
        ),
        isTrue,
      );

      final candidateRows = <Map<String, dynamic>>[
        ...oldRows,
        if (scenario.snapshotIncludesUser)
          const {
            'id': 'new-user',
            'role': 'user',
            'content': 'turno terminado todavía no persistido',
          },
      ];
      final resumeGate = Completer<DesktopSessionSnapshot>();
      gateway.resumeGate = resumeGate;
      var publications = 0;
      final refresh = chat.loadMessages(
        expectedMessageCount: candidateRows.length,
        onMessagesPublished: () => publications++,
      );
      await server.waitForRequests(3);
      final snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-refresh-terminal-stale',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: true,
        messageCount: candidateRows.length,
        messages: candidateRows
            .map((row) => DesktopSessionMessage.tryParse(row)!)
            .toList(growable: false),
        running: scenario.snapshotRunning,
        inflight: scenario.snapshotRunning
            ? DesktopInflightTurn(
                user: 'turno terminado todavía no persistido',
                assistant: 'parcial obsoleto',
              )
            : null,
      );

      if (scenario.snapshotFirst) {
        resumeGate.complete(snapshot);
      } else {
        server.complete(2, candidateRows, paginated: false);
      }
      for (var attempt = 0; attempt < 100 && publications == 0; attempt++) {
        await Future<void>.delayed(Duration.zero);
      }

      // REST positivo pero rechazado por la valla conserva la proyección sin
      // fingir una publicación. El snapshot sí puede publicarse por separado.
      expect(publications, scenario.snapshotFirst ? greaterThan(0) : 0);
      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'turno terminado todavía no persistido',
        ),
        isTrue,
      );
      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'respuesta terminal todavía no persistida',
        ),
        isTrue,
      );
      if (scenario.snapshotRunning) {
        expect(chat.isStreaming, isFalse);
      }

      if (scenario.snapshotFirst) {
        server.complete(2, candidateRows, paginated: false);
      } else {
        resumeGate.complete(snapshot);
      }
      await refresh;
      expect(publications, greaterThan(0));

      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'turno terminado todavía no persistido',
        ),
        isTrue,
      );
      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'respuesta terminal todavía no persistida',
        ),
        isTrue,
      );
      expect(chat.isStreaming, isFalse);
    });
  }

  test(
    'refresh externo conserva child vivo controles y una terminal exacta',
    () async {
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(const [
          {'id': 'old-user', 'role': 'user', 'content': 'turno anterior'},
          {
            'id': 'old-answer',
            'role': 'assistant',
            'content': 'respuesta anterior',
          },
        ]);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-refresh-external-turn',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: server.rows.length,
          messages: server.rows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
        );
      var terminalCallbacks = 0;
      final chat = _chat(
        'refresh-external-turn',
        server.client(),
        gateway: gateway,
        onTerminal: () => terminalCallbacks++,
      );
      addTearDown(chat.dispose);
      chat.acquireSubagentForegroundPresentation();

      await chat.loadMessages(expectedMessageCount: server.rows.length);
      await chat.send(
        fullText: 'turno local A',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit(
        'subagent.start',
        payload: const {
          'subagent_id': 'child-external-turn',
          'delegation_id': 'deleg_external_turn',
          'status': 'running',
          'accepting_steer': true,
          'output_tail': 'coherent live tail',
          'event_id': 'external-child-start',
          'event_revision': 1,
        },
      );
      await Future<void>.delayed(Duration.zero);
      final originalActivityKey = chat.subagentActivities.single.key;
      expect(chat.subagentActivities.single.isTerminal, isFalse);
      server.rows.addAll(const [
        {'id': 'user-a', 'role': 'user', 'content': 'turno local A'},
        {'id': 'answer-a', 'role': 'assistant', 'content': 'respuesta final A'},
      ]);
      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta final A'},
      );
      for (
        var attempt = 0;
        attempt < 100 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(chat.state, ChatPipelineState.completed);

      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-refresh-external-turn',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: true,
        messageCount: server.rows.length,
        messages: server.rows
            .map((row) => DesktopSessionMessage.tryParse(row)!)
            .toList(growable: false),
        running: true,
        inflight: DesktopInflightTurn(
          user: 'turno remoto B',
          assistant: 'respuesta parcial B',
        ),
      );
      await chat.loadMessages(expectedMessageCount: server.rows.length);

      expect(chat.isStreaming, isTrue);
      expect(chat.subagentActivities, hasLength(1));
      expect(chat.subagentActivities.single.key, originalActivityKey);
      expect(chat.subagentActivities.single.isTerminal, isFalse);
      expect(chat.canSteerSubagent(chat.subagentActivities.single), isTrue);
      expect(chat.canInterruptSubagent(chat.subagentActivities.single), isTrue);
      final live = chat.subagentActivities.single;
      final tail = await chat.tailSubagent(live);
      expect(tail.content, 'coherent live tail');
      final childSteer = await chat.steerSubagent(live, 'preserva identidad');
      expect(childSteer.queued, isTrue);
      final childInterrupt = await chat.interruptSubagent(live);
      expect(childInterrupt, isTrue);
      expect(gateway.subagentTailCalls, [
        (
          runtimeId: 'runtime-refresh-external-turn',
          subagentId: 'child-external-turn',
        ),
      ]);
      expect(gateway.subagentSteerCalls, [
        (
          runtimeId: 'runtime-refresh-external-turn',
          subagentId: 'child-external-turn',
          text: 'preserva identidad',
        ),
      ]);
      expect(gateway.subagentInterruptCalls, [
        (
          runtimeId: 'runtime-refresh-external-turn',
          subagentId: 'child-external-turn',
        ),
      ]);
      gateway.emit(
        'subagent.complete',
        payload: const {
          'subagent_id': 'child-external-turn',
          'delegation_id': 'deleg_external_turn',
          'status': 'completed',
          'event_id': 'external-child-complete',
          'event_revision': 2,
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(chat.subagentActivities, hasLength(1));
      expect(chat.subagentActivities.single.key, originalActivityKey);
      expect(chat.subagentActivities.single.isTerminal, isTrue);
      expect(
        chat.messages.any((message) => message['content'] == 'turno remoto B'),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 850));
      expect(terminalCallbacks, 0);

      server.rows.addAll(const [
        {'id': 'user-b', 'role': 'user', 'content': 'turno remoto B'},
        {'id': 'answer-b', 'role': 'assistant', 'content': 'respuesta final B'},
      ]);
      gateway.emit(
        'message.delta',
        payload: const {'text': 'respuesta final B'},
      );
      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta final B'},
      );
      for (
        var attempt = 0;
        attempt < 100 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(chat.state, ChatPipelineState.completed);
      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta final B',
        ),
        isTrue,
      );
    },
  );

  test(
    'dos refresh stale no limpian la valla y durable la retira sin bloquear cola',
    () async {
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(const [
          {'id': 'old-user', 'role': 'user', 'content': 'turno anterior'},
          {
            'id': 'old-answer',
            'role': 'assistant',
            'content': 'respuesta anterior',
          },
        ]);
      DesktopSessionSnapshot snapshotFor(List<Map<String, dynamic>> rows) =>
          DesktopSessionSnapshot(
            runtimeSessionId: 'runtime-terminal-fence-lifetime',
            storedSessionId: 'stored-chat',
            created: false,
            messagesProvided: true,
            messageCount: rows.length,
            messages: rows
                .map((row) => DesktopSessionMessage.tryParse(row)!)
                .toList(growable: false),
          );

      final gateway = _DeferrableGateway()..snapshot = snapshotFor(server.rows);
      final chat = _chat(
        'terminal-fence-lifetime',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: server.rows.length);
      await chat.send(
        fullText: 'turno A aún no persistido',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta final A aún local'},
      );
      for (
        var attempt = 0;
        attempt < 100 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(chat.state, ChatPipelineState.completed);

      await chat.send(
        fullText: 'turno B activo',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      for (var refresh = 0; refresh < 2; refresh++) {
        await chat.loadMessages(expectedMessageCount: server.rows.length);
        expect(
          chat.messages.any(
            (message) => message['content'] == 'turno A aún no persistido',
          ),
          isTrue,
        );
        expect(
          chat.messages.any(
            (message) => message['content'] == 'respuesta final A aún local',
          ),
          isTrue,
        );
        expect(
          chat.messages.any(
            (message) => message['_localTerminalProjectionId'] != null,
          ),
          isFalse,
        );
        expect(
          chat.coreReadLineageComplete,
          isFalse,
          reason:
              'un graft rechazado conserva filas visibles pero no completitud',
        );
        expect(
          chat.hasEarlierMessages,
          isTrue,
          reason: 'la reparación debe reiniciarse desde offset cero',
        );
      }

      server.rows.addAll(const [
        {'id': 'user-a', 'role': 'user', 'content': 'turno A ya durable'},
        {
          'id': 'answer-a',
          'role': 'assistant',
          'content': 'respuesta final A ya durable',
        },
      ]);
      gateway.snapshot = snapshotFor(server.rows);
      await chat.loadMessages(expectedMessageCount: server.rows.length);

      expect(
        chat.messages.any(
          (message) => message['_localTerminalProjectionId'] != null,
        ),
        isFalse,
      );

      final shiftedRows = _rows(130, from: 1000);
      server.paginate = true;
      server.rows
        ..clear()
        ..addAll(shiftedRows);
      gateway.snapshot = snapshotFor(shiftedRows);
      await chat.loadMessages(expectedMessageCount: shiftedRows.length);

      expect(chat.messages.any((message) => message['id'] == 1129), isTrue);
      expect(chat.hasEarlierMessages, isTrue);
      expect(await chat.loadEarlierMessages(), isTrue);
      expect(chat.messages.any((message) => message['id'] == 1000), isTrue);
    },
  );

  test(
    'valla terminal atraviesa más de 120 tools hasta acreditar su user canónico',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {'id': 'old-user', 'role': 'user', 'content': 'turno anterior'},
        {
          'id': 'old-answer',
          'role': 'assistant',
          'content': 'respuesta anterior',
        },
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-tool-overflow',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: initialRows.length,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
        );
      final chat = _chat(
        'terminal-tool-overflow',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: initialRows.length);
      await chat.send(
        fullText: 'turno A con muchas tools',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta final A'},
      );
      for (
        var attempt = 0;
        attempt < 100 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(chat.state, ChatPipelineState.completed);

      server
        ..paginate = true
        ..rows.addAll([
          const {
            'id': 'user-a-overflow',
            'role': 'user',
            'content': 'turno A con muchas tools',
          },
          const {
            'id': 'answer-a-overflow',
            'role': 'assistant',
            'content': 'respuesta final A',
          },
          for (var index = 0; index < 120; index++)
            {
              'id': 'tool-a-$index',
              'role': 'tool',
              'content': 'resultado tool $index',
            },
        ]);
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-terminal-tool-overflow',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: server.rows.length,
        hydrating: true,
      );

      await chat.loadMessages(expectedMessageCount: server.rows.length);
      expect(chat.hasEarlierMessages, isTrue);
      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta final A',
        ),
        isTrue,
      );

      expect(await chat.loadEarlierMessages(), isTrue);
      expect(server.requests.last.queryParameters['offset'], '0');
      expect(chat.hasEarlierMessages, isTrue);
      expect(
        chat.messages.any(
          (message) => message['_localTerminalProjectionId'] != null,
        ),
        isFalse,
      );

      expect(await chat.loadEarlierMessages(), isTrue);
      expect(server.requests.last.queryParameters['offset'], '120');
      expect(chat.hasEarlierMessages, isFalse);
      expect(
        chat.messages.any((message) => message['id'] == 'user-a-overflow'),
        isTrue,
      );
      expect(
        chat.messages.any(
          (message) => message['_localTerminalProjectionId'] != null,
        ),
        isFalse,
      );
    },
  );

  test(
    'valla provisional poda IDs viejos si la cola de 120 pertenece a una compactación',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {'id': 'ghost-user', 'role': 'user', 'content': 'turno compactado'},
        {
          'id': 'ghost-answer',
          'role': 'assistant',
          'content': 'respuesta compactada',
        },
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-tool-compaction',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: initialRows.length,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
        );
      final chat = _chat(
        'terminal-tool-compaction',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: initialRows.length);
      await chat.send(
        fullText: 'turno después de compactar',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta local tras compactar'},
      );
      for (
        var attempt = 0;
        attempt < 100 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      server.paginate = true;
      server.rows
        ..clear()
        ..addAll([
          const {
            'id': 'compact-current-user',
            'role': 'user',
            'content': 'turno después de compactar',
          },
          const {
            'id': 'compact-current-answer',
            'role': 'assistant',
            'content': 'respuesta local tras compactar',
          },
          for (var index = 0; index < 120; index++)
            {
              'id': 'compact-tool-$index',
              'role': 'tool',
              'content': 'tool compactada $index',
            },
        ]);
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-terminal-tool-compaction',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: server.rows.length,
        hydrating: true,
      );

      await chat.loadMessages(expectedMessageCount: server.rows.length);
      expect(await chat.loadEarlierMessages(), isTrue);
      expect(server.requests.last.queryParameters['offset'], '0');
      expect(await chat.loadEarlierMessages(), isTrue);
      expect(server.requests.last.queryParameters['offset'], '120');

      expect(chat.hasEarlierMessages, isFalse);
      expect(
        chat.messages.any((message) => message['id'] == 'ghost-user'),
        isFalse,
      );
      expect(
        chat.messages.any((message) => message['id'] == 'ghost-answer'),
        isFalse,
      );
      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta local tras compactar',
        ),
        isTrue,
      );
    },
  );

  test(
    'compactación conserva inflight y assistant terminal sin fusionarlo por texto',
    () async {
      final server = _TranscriptServer(paginate: true)..healthy = false;
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-canonical-terminal-compaction',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: 121,
          hydrating: true,
          messages: [
            DesktopSessionMessage.tryParse(const {
              'message_id': 'canonical-current-user',
              'role': 'user',
              'content': 'turno canónico aún no compactado',
            })!,
          ],
          running: true,
          inflight: DesktopInflightTurn(
            user: 'turno canónico aún no compactado',
            assistant: 'respuesta parcial de Desktop',
            streaming: true,
          ),
        );
      final chat = _chat(
        'canonical-terminal-compaction',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 121);
      expect(
        chat.internalMessagesForTesting.where(
          (message) =>
              canonicalTranscriptMessageId(message) == 'canonical-current-user',
        ),
        hasLength(1),
      );
      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta terminal local completa'},
      );
      for (
        var attempt = 0;
        attempt < 200 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(chat.state, ChatPipelineState.completed);

      // El transcript sufrió una compactación que ya no contiene el turno
      // terminal. La cola llena lo conserva provisionalmente y la página corta
      // acredita el inicio, pero no acredita esa valla concreta.
      server
        ..healthy = true
        ..rows.addAll(_rows(121, from: 5000));
      gateway.resumeError = StateError('snapshot todavía no disponible');
      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-canonical-terminal-compaction',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 121,
        hydrating: true,
      );

      await chat.loadMessages(expectedMessageCount: 121);
      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'respuesta terminal local completa',
        ),
        isTrue,
      );
      expect(await chat.loadEarlierMessages(), isTrue);
      expect(server.requests.last.queryParameters['offset'], '120');

      expect(chat.hasEarlierMessages, isFalse);
      expect(
        chat.internalMessagesForTesting.where(
          (message) =>
              canonicalTranscriptMessageId(message) == 'canonical-current-user',
        ),
        isEmpty,
      );
      expect(
        chat.messages.where(
          (message) =>
              message['content'] == 'respuesta terminal local completa',
        ),
        hasLength(1),
      );
      expect(
        chat.messages.where(
          (message) =>
              isRealUserTurn(message) &&
              message['content'] == 'turno canónico aún no compactado',
        ),
        hasLength(1),
      );
      final terminalAssistantIndex = chat.messages.indexWhere(
        (message) => message['content'] == 'respuesta terminal local completa',
      );
      final terminalUserIndex = chat.messages.indexWhere(
        (message) =>
            isRealUserTurn(message) &&
            message['content'] == 'turno canónico aún no compactado',
      );
      expect(terminalAssistantIndex + 1, terminalUserIndex);

      server.rows.addAll(const [
        {
          'id': 5121,
          'message_id': 'newer-durable-user',
          'role': 'user',
          'content': 'turno durable posterior',
        },
        {
          'id': 5122,
          'message_id': 'newer-durable-assistant',
          'role': 'assistant',
          'content': 'respuesta durable posterior',
        },
      ]);

      Future<void> expectStableChronology() async {
        await chat.loadMessages(expectedMessageCount: server.rows.length);
        final messages = chat.internalMessagesForTesting;
        final newerAssistant = messages.indexWhere(
          (message) => message['message_id'] == 'newer-durable-assistant',
        );
        final newerUser = messages.indexWhere(
          (message) => message['message_id'] == 'newer-durable-user',
        );
        final compactedAssistant = messages.indexWhere(
          (message) =>
              message['content'] == 'respuesta terminal local completa',
        );
        final compactedUser = messages.indexWhere(
          (message) =>
              isRealUserTurn(message) &&
              message['content'] == 'turno canónico aún no compactado',
        );
        expect(newerAssistant, greaterThanOrEqualTo(0));
        expect(newerUser, newerAssistant + 1);
        expect(compactedAssistant, greaterThan(newerUser));
        expect(compactedUser, compactedAssistant + 1);
        final compacted = messages.where(
          (message) => message['_localCompactedTerminalProjection'] != null,
        );
        expect(compacted, hasLength(2));
        expect(
          compacted.every(
            (message) =>
                canonicalTranscriptIdentity(message) == null &&
                message['_localTerminalProjectionId'] == null,
          ),
          isTrue,
        );
      }

      await expectStableChronology();
      await expectStableChronology();
      expect(
        chat.messages.where(
          (message) =>
              message['content'] == 'respuesta terminal local completa' ||
              (isRealUserTurn(message) &&
                  message['content'] == 'turno canónico aún no compactado'),
        ),
        hasLength(2),
      );
    },
  );

  test('tombstone huérfano no fuerza paginar fuera de la cola', () async {
    final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(300));
    final chat = _chat(
      'orphan-tail',
      server.client(),
      initialCancelledTurnTombstones: const [
        CancelledTurnTombstone(
          content: 'turno compactado',
          anchorMessageId: 'anchor-eliminada',
        ),
      ],
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 300);

    expect(server.requests, hasLength(1));
    expect(chat.messages, hasLength(120));
    expect(chat.messages.first['content'], 'msg 300');
    expect(chat.messages.last['content'], 'msg 181');
    expect(chat.hasEarlierMessages, isTrue);
  });

  test(
    'cola parcial no confunde firstUser con el usuario visible más viejo',
    () async {
      final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(300));
      final chat = _chat(
        'first-user-partial',
        server.client(),
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(content: 'msg 181', firstUser: true),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);

      expect(chat.messages, hasLength(120));
      expect(chat.messages.any((message) => message['id'] == 182), isTrue);
      expect(
        chat.messages
            .singleWhere((message) => message['id'] == 181)
            .containsKey('_cancelledUser'),
        isFalse,
      );
    },
  );

  test('página corta con identidad duplicada no acredita firstUser', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'object': 'list',
          'data': const [
            {
              'message_id': 'duplicate-row',
              'role': 'user',
              'content': 'prompt repetido',
            },
            {
              'message_id': 'duplicate-row',
              'role': 'assistant',
              'content': 'respuesta legítima',
            },
          ],
          'pagination': {'limit': 120, 'offset': 0},
        }),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );
    final chat = _chat(
      'duplicate-short-page',
      client,
      initialCancelledTurnTombstones: const [
        CancelledTurnTombstone(content: 'prompt repetido', firstUser: true),
      ],
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 2);

    expect(chat.messages, hasLength(2));
    expect(
      chat.messages.any(
        (message) => message['content'] == 'respuesta legítima',
      ),
      isTrue,
    );
    expect(
      chat.messages
          .singleWhere((message) => message['role'] == 'user')
          .containsKey('_cancelledUser'),
      isFalse,
    );
  });

  for (final malformedPagination in <String, Object>{
    'vacía': const <String, Object>{},
    'limit string': const <String, Object>{'limit': '120', 'offset': 0},
    'offset decimal': const <String, Object>{'limit': 120, 'offset': 0.5},
  }.entries) {
    test(
      'pagination ${malformedPagination.key} no acredita firstUser completo',
      () async {
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({
              'object': 'list',
              'data': const [
                {
                  'id': 'malformed-page-user',
                  'role': 'user',
                  'content': 'prompt repetido',
                },
                {
                  'id': 'malformed-page-answer',
                  'role': 'assistant',
                  'content': 'respuesta legítima',
                },
              ],
              'pagination': malformedPagination.value,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          ),
        );
        final chat = _chat(
          'malformed-pagination-${malformedPagination.key}',
          client,
          initialCancelledTurnTombstones: const [
            CancelledTurnTombstone(content: 'prompt repetido', firstUser: true),
          ],
        );
        addTearDown(chat.dispose);

        await chat.loadMessages(expectedMessageCount: 2);

        expect(
          chat.messages.any(
            (message) => message['id'] == 'malformed-page-answer',
          ),
          isTrue,
        );
        expect(
          chat.messages
              .singleWhere((message) => message['id'] == 'malformed-page-user')
              .containsKey('_cancelledUser'),
          isFalse,
        );
        expect(chat.hasEarlierMessages, isTrue);
      },
    );
  }

  test('página vacía confirma completitud y aplica firstUser exacto', () async {
    final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(120));
    final chat = _chat(
      'first-user-complete',
      server.client(),
      initialCancelledTurnTombstones: const [
        CancelledTurnTombstone(content: 'msg 1', firstUser: true),
      ],
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 120);

    expect(chat.messages.any((message) => message['id'] == 2), isTrue);
    expect(chat.hasEarlierMessages, isTrue);

    expect(await chat.loadEarlierMessages(), isTrue);

    expect(chat.hasEarlierMessages, isFalse);
    expect(chat.messages.any((message) => message['id'] == 2), isFalse);
    expect(
      chat.messages.singleWhere((message) => message['id'] == 1),
      containsPair('_cancelledUser', true),
    );
  });

  test(
    'Stop en chat largo ancla desde la cola parcial antes del siguiente envío',
    () async {
      final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(200));
      final gateway = _DeferrableGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-long-stop',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 200,
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'long-stop-anchor',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 200);
      await chat.send(
        fullText: 'turno detenido al final del chat largo',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      await chat.cancel();
      await Future<void>.delayed(Duration.zero);
      gateway.emit(
        'message.complete',
        payload: const {'text': 'Operation interrupted.'},
      );
      server.rows.add(const {
        'id': 201,
        'message_id': 'msg-201',
        'role': 'user',
        'content': 'turno detenido al final del chat largo',
      });

      final accepted = await chat.send(
        fullText: 'turno posterior todavía cancelable',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );

      expect(accepted, isTrue);
      expect(
        chat.messages.any(
          (message) =>
              message['id'] == 201 && message['_cancelledUser'] == true,
        ),
        isTrue,
      );
      expect(recorded.first.anchorMessageId, 'msg-200');
      expect(recorded.last.cancelledMessageId, 'msg-201');
    },
  );

  test(
    '[console-state 4/7] terminal override survives tombstone metadata await',
    () async {
      final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(200));
      final gateway = _DeferrableGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stop-binding-terminal',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 200,
        );
      final bindingPersistStarted = Completer<void>();
      final bindingPersistGate = Completer<void>();
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'stop-binding-terminal',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) {
          recorded.add(tombstone);
          if (tombstone.cancelledMessageId != null) {
            if (!bindingPersistStarted.isCompleted) {
              bindingPersistStarted.complete();
            }
            return bindingPersistGate.future;
          }
          return Future<void>.value();
        },
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 200);
      await chat.send(
        fullText: 'turno detenido que aún no tiene id',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      await chat.cancel();
      gateway.emit(
        'message.complete',
        payload: const {'text': 'Operation interrupted.'},
      );
      server.rows.add(const {
        'id': 201,
        'message_id': 'msg-201',
        'role': 'user',
        'content': 'turno detenido que aún no tiene id',
      });

      final accepted = await chat.send(
        fullText: 'turno siguiente con respuesta inmediata',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      expect(accepted, isTrue);
      await bindingPersistStarted.future;
      expect(recorded.last.cancelledMessageId, 'msg-201');

      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta inmediata y durable'},
      );
      await Future<void>.delayed(Duration.zero);
      expect(chat.isStreaming, isTrue);

      bindingPersistGate.complete();
      for (
        var attempt = 0;
        attempt < 100 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(chat.state, ChatPipelineState.completed);
      expect(chat.hasPendingDurableCancellation, isFalse);
      expect(
        chat.messages.firstWhere(
          (message) => message['role'] == 'assistant',
        )['content'],
        'respuesta inmediata y durable',
      );
    },
  );

  test(
    'refresh conserva Stop local ante REST stale y lo sustituye al persistirse',
    () async {
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(const [
          {
            'id': 1,
            'message_id': 'msg-1',
            'role': 'user',
            'content': 'turno anterior',
          },
          {
            'id': 2,
            'message_id': 'msg-2',
            'role': 'assistant',
            'content': 'respuesta anterior',
          },
        ]);
      final gateway = _DeferrableGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stale-cancelled-refresh',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 2,
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'stale-cancelled-refresh',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      await chat.send(
        fullText: 'prompt recién detenido',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      await chat.cancel();
      gateway.emit(
        'message.complete',
        payload: const {'text': 'Operation interrupted.'},
      );

      await chat.loadMessages(expectedMessageCount: 2);
      var stoppedPrompts = chat.messages
          .where((message) => message['content'] == 'prompt recién detenido')
          .toList(growable: false);
      expect(stoppedPrompts, hasLength(1));
      expect(canonicalTranscriptMessageId(stoppedPrompts.single), isNull);
      expect(stoppedPrompts.single['_cancelledUser'], isTrue);

      server.rows.add(const {
        'id': 3,
        'message_id': 'msg-3',
        'role': 'user',
        'content': 'prompt recién detenido',
      });
      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-stale-cancelled-refresh',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 3,
      );
      await chat.loadMessages(expectedMessageCount: 3);

      stoppedPrompts = chat.messages
          .where((message) => message['content'] == 'prompt recién detenido')
          .toList(growable: false);
      expect(stoppedPrompts, hasLength(1));
      expect(canonicalTranscriptMessageId(stoppedPrompts.single), 'msg-3');
      expect(stoppedPrompts.single['_cancelledUser'], isTrue);
      expect(recorded.last.cancelledMessageId, 'msg-3');
    },
  );

  test(
    'backfill ancla Stop fuera de la cola 120 y desbloquea el siguiente turno',
    () async {
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(const [
          {
            'id': 1,
            'message_id': 'msg-1',
            'role': 'user',
            'content': 'turno anterior',
          },
          {
            'id': 2,
            'message_id': 'msg-2',
            'role': 'assistant',
            'content': 'respuesta anterior',
          },
        ]);
      final gateway = _DeferrableGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stop-outside-tail',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 2,
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'stop-outside-tail',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      await chat.send(
        fullText: 'cancelado fuera de la cola',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      await chat.cancel();
      gateway.emit(
        'message.complete',
        payload: const {'text': 'Operation interrupted.'},
      );

      server
        ..paginate = true
        ..rows.addAll([
          const {
            'id': 3,
            'message_id': 'msg-3',
            'role': 'user',
            'content': 'cancelado fuera de la cola',
          },
          for (var id = 4; id <= 133; id++)
            {
              'id': id,
              'message_id': 'msg-$id',
              'role': 'tool',
              'content': 'actividad $id',
            },
        ]);
      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-stop-outside-tail',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 133,
      );

      await chat.loadMessages(expectedMessageCount: 133);
      expect(chat.messages.any((message) => message['id'] == 3), isFalse);
      for (
        var attempt = 0;
        attempt < 3 && !chat.messages.any((message) => message['id'] == 3);
        attempt++
      ) {
        expect(await chat.loadEarlierMessages(), isTrue);
      }
      final cancelled = chat.messages.singleWhere(
        (message) => message['id'] == 3,
      );
      expect(cancelled['_cancelledUser'], isTrue);
      expect(
        chat.messages.where(
          (message) => message['content'] == 'cancelado fuera de la cola',
        ),
        hasLength(1),
      );
      expect(recorded.last.cancelledMessageId, 'msg-3');

      final accepted = await chat.send(
        fullText: 'turno posterior al backfill',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      expect(accepted, isTrue);
    },
  );

  test('backfill aplica el tombstone exacto al alcanzar su ancla', () async {
    final server = _TranscriptServer(paginate: true)
      ..rows.addAll([
        for (var id = 1; id <= 178; id++)
          {
            'id': id,
            'message_id': 'msg-$id',
            'role': 'system',
            'content': 'relleno $id',
          },
        {
          'id': 179,
          'message_id': 'msg-179',
          'role': 'assistant',
          'content': 'respuesta anterior',
        },
        {
          'id': 180,
          'message_id': 'msg-180',
          'role': 'user',
          'content': 'prompt repetido',
        },
        {
          'id': 181,
          'message_id': 'msg-181',
          'role': 'assistant',
          'content': 'respuesta cancelada tardía',
        },
        {
          'id': 182,
          'message_id': 'msg-182',
          'role': 'user',
          'content': 'prompt repetido',
        },
        {
          'id': 183,
          'message_id': 'msg-183',
          'role': 'assistant',
          'content': 'respuesta legítima',
        },
        for (var id = 184; id <= 300; id++)
          {
            'id': id,
            'message_id': 'msg-$id',
            'role': 'system',
            'content': 'relleno $id',
          },
      ]);
    final chat = _chat(
      'exact-backfill',
      server.client(),
      initialCancelledTurnTombstones: const [
        CancelledTurnTombstone(
          content: 'prompt repetido',
          anchorMessageId: 'msg-179',
        ),
      ],
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 300);

    expect(server.requests, hasLength(1));
    expect(chat.messages.any((message) => message['id'] == 181), isTrue);

    expect(await chat.loadEarlierMessages(), isTrue);

    expect(server.requests, hasLength(2));
    expect(chat.messages.any((message) => message['id'] == 181), isFalse);
    expect(
      chat.messages.singleWhere((message) => message['id'] == 180),
      containsPair('_cancelledUser', true),
    );
    expect(
      chat.messages.singleWhere((message) => message['id'] == 183),
      containsPair('content', 'respuesta legítima'),
    );
    expect(
      chat.messages.singleWhere((message) => message['id'] == 182),
      containsPair('content', 'prompt repetido'),
    );
    expect(chat.messages.any((message) => message['id'] == 179), isTrue);
  });

  test(
    'backfill asocia tool result con su image_generate al cruzar el corte de página',
    () async {
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll([
          for (var id = 1; id <= 178; id++)
            {'id': id, 'role': 'system', 'content': 'relleno $id'},
          {'id': 179, 'role': 'user', 'content': 'genera una imagen'},
          {
            'id': 180,
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'call-page-image',
                'type': 'function',
                'function': {
                  'name': 'image_generate',
                  'arguments': '{"prompt":"page boundary"}',
                },
              },
            ],
          },
          {
            'id': 181,
            'role': 'tool',
            'tool_call_id': 'call-page-image',
            'content':
                '{"success":true,"host_image":"/home/hermes/.hermes/cache/images/page-boundary.png"}',
          },
          {'id': 182, 'role': 'assistant', 'content': 'Imagen terminada.'},
          for (var id = 183; id <= 300; id++)
            {'id': id, 'role': 'system', 'content': 'relleno $id'},
        ]);
      final chat = _chat('image-page-boundary', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);

      final finalAssistant = chat.messages.singleWhere(
        (message) => message['id'] == 182,
      );
      final initialRefs = _generatedImageRefs(finalAssistant);
      expect(initialRefs, hasLength(1));
      expect(initialRefs.single['basename'], 'page-boundary.png');
      expect(initialRefs.single['tool_call_id'], 'call-page-image');

      expect(await chat.loadEarlierMessages(), isTrue);

      final hydratedAssistant = chat.messages.singleWhere(
        (message) => message['id'] == 182,
      );
      final refs = _generatedImageRefs(hydratedAssistant);
      expect(refs, hasLength(1));
      expect(refs.single['basename'], 'page-boundary.png');
      expect(refs.single['tool_call_id'], 'call-page-image');
    },
  );

  test('gateway legacy sin metadata pagination: transcript one-shot', () async {
    final server = _TranscriptServer(paginate: false)..rows.addAll(_rows(300));
    final chat = _chat('legacy', server.client());
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 300);

    expect(chat.messages, hasLength(300));
    expect(chat.messages.first['content'], 'msg 300');
    expect(chat.hasEarlierMessages, isFalse);
    expect(await chat.loadEarlierMessages(), isFalse);
    expect(chat.coreReadLineageComplete, isFalse);
    expect(chat.coreReadCoverageIsPartial, isTrue);
    expect(
      chat.coreReadCoverage,
      containsAll(<CoreReadCoverage>{
        CoreReadCoverage.tipOnly,
        CoreReadCoverage.metadataPartial,
      }),
    );
    expect(server.requests, hasLength(1));
  });

  test('transcript REST completo adopta una compactación sin ancla', () async {
    final server = _TranscriptServer(paginate: false)..rows.addAll(_rows(300));
    final chat = _chat('legacy-compaction', server.client());
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 300);
    expect(chat.messages, hasLength(300));

    server.rows
      ..clear()
      ..addAll([
        {'id': 'compact-user', 'role': 'user', 'content': 'resumen compacto'},
        {
          'id': 'compact-answer',
          'role': 'assistant',
          'content': 'respuesta compacta',
        },
      ]);
    await chat.loadMessages(expectedMessageCount: 2);

    expect(chat.messages, hasLength(2));
    expect(chat.messages.first['id'], 'compact-answer');
    expect(chat.messages.last['id'], 'compact-user');
    expect(chat.hasEarlierMessages, isFalse);
  });

  test(
    'refresh conserva lo visible y adopta una cola nueva sin solape estable',
    () async {
      final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(2));
      final chat = _chat('disjoint-new-tail', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      expect(chat.messages, hasLength(2));
      expect(chat.hasEarlierMessages, isFalse);

      server.rows.addAll(_rows(120, from: 3));
      await chat.loadMessages(expectedMessageCount: 122);

      expect(chat.messages, hasLength(122));
      expect(chat.messages.first['content'], 'msg 122');
      expect(chat.messages.last['content'], 'msg 1');
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test('refresh de cola parcial injerta un único mensaje nuevo', () async {
    final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(300));
    final chat = _chat('partial-tail-append-one', server.client());
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 300);
    expect(chat.messages, hasLength(120));
    expect(chat.messages.last['id'], 181);

    server.rows.addAll(_rows(1, from: 301));
    await chat.loadMessages(expectedMessageCount: 301);

    expect(chat.messages, hasLength(121));
    expect(chat.messages.first['id'], 301);
    expect(chat.messages.last['id'], 181);
    expect(chat.hasEarlierMessages, isTrue);
  });

  test(
    'refresh disjunto conserva una cola parcial hasta confirmarla por backfill',
    () async {
      final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(300));
      final chat = _chat('partial-disjoint-append', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      server.rows.addAll(_rows(120, from: 301));
      await chat.loadMessages(expectedMessageCount: 420);

      expect(chat.messages, hasLength(240));
      expect(chat.messages.first['id'], 420);
      expect(chat.messages.last['id'], 181);

      expect(await chat.loadEarlierMessages(), isTrue);
      expect(chat.messages, hasLength(240));
      expect(
        chat.messages.map((message) => message['id']).toSet(),
        hasLength(240),
      );
      expect(await chat.loadEarlierMessages(), isTrue);
      expect(await chat.loadEarlierMessages(), isTrue);
      expect(chat.messages, hasLength(420));
      expect(chat.messages.last['id'], 1);
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'backfill menos enriquecido no confirma un graft con pares conflictivos',
    () async {
      var requestCount = 0;
      final initialTail = <Map<String, dynamic>>[
        for (var index = 0; index < 119; index++)
          {
            'message_id': 'retained-$index',
            'row_id': 1000 + index,
            'role': 'assistant',
            'content': 'retained $index',
          },
        {
          'message_id': 'shared-message',
          'row_id': 42,
          'role': 'assistant',
          'content': 'retained conflicting row',
        },
      ];
      final refreshedTail = <Map<String, dynamic>>[
        for (var index = 0; index < 119; index++)
          {
            'message_id': 'refreshed-$index',
            'row_id': 2000 + index,
            'role': 'assistant',
            'content': 'refreshed $index',
          },
        {
          'message_id': 'shared-message',
          'row_id': 43,
          'role': 'assistant',
          'content': 'current conflicting row',
        },
      ];
      final client = MockClient((request) async {
        requestCount++;
        final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
        final page = switch (requestCount) {
          1 => initialTail,
          2 => refreshedTail,
          _ => const <Map<String, dynamic>>[
            {
              'message_id': 'shared-message',
              'role': 'assistant',
              'content': 'less enriched backfill row',
            },
          ],
        };
        return http.Response(
          jsonEncode({
            'object': 'list',
            'data': page,
            'pagination': {
              'limit': 120,
              'offset': offset,
              'order': 'latest',
              'returned': page.length,
            },
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final chat = _chat('partial-pair-conflict', client);
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 240);
      await chat.loadMessages(expectedMessageCount: 240);

      expect(chat.messages, hasLength(240));
      expect(
        chat.messages
            .where(
              (message) =>
                  canonicalTranscriptMessageId(message) == 'shared-message',
            )
            .map(canonicalTranscriptRowId),
        unorderedEquals([42, 43]),
      );

      expect(await chat.loadEarlierMessages(), isTrue);

      expect(chat.hasEarlierMessages, isFalse);
      expect(
        chat.messages.where(
          (message) =>
              canonicalTranscriptMessageId(message) == 'shared-message',
        ),
        hasLength(1),
      );
      expect(
        canonicalTranscriptRowId(
          chat.messages.singleWhere(
            (message) =>
                canonicalTranscriptMessageId(message) == 'shared-message',
          ),
        ),
        43,
      );
    },
  );

  test(
    'backfill intercala el hueco antes del prefijo provisional disjunto',
    () async {
      final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(300));
      final chat = _chat('partial-disjoint-gap', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      server.rows.addAll(_rows(200, from: 301));
      await chat.loadMessages(expectedMessageCount: 500);

      expect(chat.messages.map((message) => message['id']), [
        for (var id = 500; id >= 381; id--) id,
        for (var id = 300; id >= 181; id--) id,
      ]);

      expect(await chat.loadEarlierMessages(), isTrue);
      expect(chat.messages.map((message) => message['id']), [
        for (var id = 500; id >= 181; id--) id,
      ]);
      expect(
        chat.messages.map((message) => message['id']).toSet(),
        hasLength(320),
      );
    },
  );

  test(
    'prefijo anclado queda provisional hasta descartar filas compactadas',
    () async {
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(_rows(300));
      final chat = _chat('anchored-compaction', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      server.paginate = true;
      server.rows
        ..removeRange(0, 100)
        ..addAll(_rows(100, from: 301));
      await chat.loadMessages(expectedMessageCount: 300);

      expect(chat.messages.first['id'], 400);
      expect(chat.messages.any((message) => message['id'] == 1), isTrue);
      expect(chat.hasEarlierMessages, isTrue);

      expect(await chat.loadEarlierMessages(), isTrue);
      expect(await chat.loadEarlierMessages(), isTrue);

      expect(chat.messages, hasLength(300));
      expect(chat.messages.first['id'], 400);
      expect(chat.messages.last['id'], 101);
      expect(chat.messages.any((message) => message['id'] == 1), isFalse);
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'refresh descarta un tool privado sin id y adopta la fila pública nueva',
    () async {
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(_rows(120));
      final chat = _chat('anchored-idless-prefix', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 120);
      chat.internalMessagesForTesting.add(const {
        'role': 'tool',
        'content': 'resultado histórico legítimo sin identidad durable',
      });
      server
        ..paginate = true
        ..rows.addAll(_rows(1, from: 121));

      await chat.loadMessages(expectedMessageCount: 121);

      expect(
        chat.messages.any(
          (message) =>
              message['content'] ==
              'resultado histórico legítimo sin identidad durable',
        ),
        isFalse,
      );
      expect(chat.messages.any((message) => message['id'] == 121), isFalse);
      expect(chat.messages.any((message) => message['id'] == 120), isTrue);
    },
  );

  test(
    'refresh descarta un tool privado nuevo sin id y conserva la cola pública',
    () async {
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(_rows(120));
      final chat = _chat('anchored-newer-idless-row', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 120);
      chat.internalMessagesForTesting.insert(0, const {
        'role': 'tool',
        'content': 'tool visible sin id delante del ancla',
      });
      server
        ..paginate = true
        ..rows.addAll(_rows(1, from: 121));

      await chat.loadMessages(expectedMessageCount: 121);

      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'tool visible sin id delante del ancla',
        ),
        isFalse,
      );
      expect(chat.messages.any((message) => message['id'] == 121), isFalse);
      expect(chat.messages.any((message) => message['id'] == 120), isTrue);
    },
  );

  test(
    'cola disjunta adopta IDs nuevos y conserva un error local id-less',
    () async {
      final server = _TranscriptServer(paginate: false)..rows.addAll(_rows(2));
      final chat = _chat('disjoint-with-local-error', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      chat.internalMessagesForTesting.insertAll(0, [
        {
          'role': 'assistant_error',
          'content': 'sin conexión',
          '_prompt': 'turno local pendiente',
        },
        {'role': 'user', 'content': 'turno local pendiente'},
      ]);
      server.paginate = true;
      server.rows
        ..clear()
        ..addAll([
          for (var index = 1; index <= 120; index++)
            {
              'id': 'new-tail-$index',
              'role': index.isOdd ? 'user' : 'assistant',
              'content': 'new tail $index',
            },
        ]);

      await chat.loadMessages(expectedMessageCount: 120);

      expect(chat.messages.first['role'], 'assistant_error');
      expect(
        chat.messages.any((message) => message['id'] == 'new-tail-120'),
        isTrue,
      );
      expect(chat.messages.any((message) => message['id'] == 1), isTrue);
      expect(await chat.loadEarlierMessages(), isTrue);
      expect(chat.messages.any((message) => message['id'] == 1), isFalse);
      expect(chat.messages.first['role'], 'assistant_error');
    },
  );

  test(
    'refresh parcial no reubica ni resucita una respuesta local cancelada',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {
          'id': 'cancel-anchor',
          'role': 'assistant',
          'content': 'respuesta anterior al turno detenido',
        },
        {'id': 'cancelled-user', 'role': 'user', 'content': 'turno detenido'},
        {'id': 'later-user', 'role': 'user', 'content': 'turno posterior'},
        {
          'id': 'later-answer',
          'role': 'assistant',
          'content': 'respuesta legítima posterior',
        },
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final chat = _chat(
        'cancelled-partial-refresh',
        server.client(),
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'turno detenido',
            anchorMessageId: 'cancel-anchor',
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 4);
      chat.internalMessagesForTesting.insert(2, const {
        'role': 'assistant',
        'content': 'parcial local que Stop debe retirar',
        '_cancelled': true,
        '_pipeline': false,
      });
      server.paginate = true;
      server.rows
        ..clear()
        ..addAll([
          initialRows.first,
          initialRows[1],
          const {
            'id': 'server-cancelled-answer',
            'role': 'assistant',
            'content': 'respuesta cancelada persistida por el servidor',
          },
          for (var index = 0; index < 115; index++)
            {
              'id': 'cancelled-tool-$index',
              'role': 'tool',
              'content': 'actividad cancelada $index',
            },
          initialRows[2],
          initialRows[3],
        ]);

      await chat.loadMessages(expectedMessageCount: 120);

      expect(chat.messages.first['id'], 'later-answer');
      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'parcial local que Stop debe retirar',
        ),
        isFalse,
      );
      expect(
        chat.messages.any(
          (message) => message['id'] == 'server-cancelled-answer',
        ),
        isFalse,
      );
      expect(
        chat.messages.singleWhere(
          (message) => message['id'] == 'cancelled-user',
        )['_cancelledUser'],
        isTrue,
      );
    },
  );

  test(
    'refresh conserva el user local de un error aunque repita texto histórico',
    () async {
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(const [
          {'id': 'old-user', 'role': 'user', 'content': 'mismo prompt'},
          {
            'id': 'old-answer',
            'role': 'assistant',
            'content': 'respuesta histórica',
          },
        ]);
      final chat = _chat('local-error-repeated-user', server.client());
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting.addAll(const [
        {
          'role': 'assistant_error',
          'content': 'fallo local recuperable',
          '_prompt': 'mismo prompt',
        },
        {'role': 'user', 'content': 'mismo prompt'},
        {
          'id': 'old-answer',
          'role': 'assistant',
          'content': 'respuesta histórica',
        },
        {'id': 'old-user', 'role': 'user', 'content': 'mismo prompt'},
      ]);

      await chat.loadMessages(expectedMessageCount: 2);

      expect(
        chat.messages.where(
          (message) =>
              message['role'] == 'user' && message['content'] == 'mismo prompt',
        ),
        hasLength(2),
      );
      expect(
        chat.messages.any(
          (message) =>
              message['role'] == 'user' &&
              canonicalTranscriptMessageId(message) == null,
        ),
        isTrue,
      );
    },
  );

  test(
    'refresh conserva dos reintentos fallidos idénticos como turnos distintos',
    () async {
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(const [
          {'id': 'old-user', 'role': 'user', 'content': 'mismo prompt'},
          {
            'id': 'old-answer',
            'role': 'assistant',
            'content': 'respuesta histórica',
          },
        ]);
      final chat = _chat('two-identical-local-errors', server.client());
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting.addAll([
        {
          'role': 'assistant_error',
          'content': 'sin conexión',
          '_prompt': 'mismo prompt',
        },
        {'role': 'user', 'content': 'mismo prompt'},
        {
          'role': 'assistant_error',
          'content': 'sin conexión',
          '_prompt': 'mismo prompt',
        },
        {'role': 'user', 'content': 'mismo prompt'},
        {
          'id': 'old-answer',
          'role': 'assistant',
          'content': 'respuesta histórica',
        },
        {'id': 'old-user', 'role': 'user', 'content': 'mismo prompt'},
      ]);

      await chat.loadMessages(expectedMessageCount: 2);

      expect(
        chat.messages.where((message) => message['role'] == 'assistant_error'),
        hasLength(2),
      );
      expect(
        chat.messages.where(
          (message) =>
              message['role'] == 'user' && message['content'] == 'mismo prompt',
        ),
        hasLength(3),
      );
      expect(
        chat.internalMessagesForTesting
            .where((message) => message['role'] == 'assistant_error')
            .map((message) => message['_localTranscriptProjectionId'])
            .toSet(),
        hasLength(2),
      );
    },
  );

  test(
    'backfill vacío retira filas viejas tras compactación paginada disjunta',
    () async {
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(_rows(300));
      final chat = _chat('paginated-disjoint-compaction', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      expect(chat.messages, hasLength(300));

      server.paginate = true;
      server.rows
        ..clear()
        ..addAll([
          for (var index = 1; index <= 120; index++)
            {
              'id': 'compact-page-$index',
              'role': index.isOdd ? 'user' : 'assistant',
              'content': 'compact page $index',
            },
        ]);
      await chat.loadMessages(expectedMessageCount: 120);
      expect(chat.hasEarlierMessages, isTrue);

      expect(await chat.loadEarlierMessages(), isTrue);

      expect(chat.messages, hasLength(120));
      expect(chat.messages.first['id'], 'compact-page-120');
      expect(chat.messages.last['id'], 'compact-page-1');
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'snapshot completo adopta una compactación frente a fallback viejo',
    () async {
      final oldRows = <Map<String, dynamic>>[
        for (var index = 1; index <= 300; index++)
          {
            'message_id': 'old-snapshot-$index',
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'historial viejo $index',
          },
      ];
      final compactRows = <Map<String, dynamic>>[
        {
          'message_id': 'compact-snapshot-user',
          'role': 'user',
          'content': 'resumen Desktop',
        },
        {
          'message_id': 'compact-snapshot-answer',
          'role': 'assistant',
          'content': 'respuesta Desktop compacta',
        },
      ];
      final server = _TranscriptServer(paginate: false)..rows.addAll(oldRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-old-snapshot',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: oldRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 300,
        );
      final chat = _chat(
        'snapshot-compaction',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      expect(chat.messages, hasLength(300));

      server.healthy = false;
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-compact-snapshot',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: true,
        messages: compactRows
            .map((row) => DesktopSessionMessage.tryParse(row)!)
            .toList(growable: false),
        messageCount: 2,
      );
      await chat.loadMessages(expectedMessageCount: 2);

      expect(chat.messages, hasLength(2));
      expect(chat.messages.first['content'], 'respuesta Desktop compacta');
      expect(chat.messages.last['content'], 'resumen Desktop');
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test('backfill deduplica el solape por drift de offsets', () async {
    final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(300));
    final chat = _chat('drift', server.client());
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 300);
    // El servidor persiste 5 mensajes nuevos tras la hidratación: la página
    // pedida con offset=120 solapa 5 filas ya visibles.
    server.rows.addAll(_rows(5, from: 301));

    expect(await chat.loadEarlierMessages(), isTrue);
    final ids = chat.messages.map((message) => message['id']).toList();
    expect(ids.toSet(), hasLength(ids.length));
    expect(chat.messages, hasLength(235));
    expect(chat.messages.first['content'], 'msg 300');
    expect(chat.messages.last['content'], 'msg 66');
  });

  test('backfill deduplica el solape por row id REST tipado', () async {
    final server = _TranscriptServer(paginate: true)
      ..rows.addAll(_rowOnlyRows(300));
    final chat = _chat('row-id-drift', server.client());
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 300);
    server.rows.addAll(_rowOnlyRows(5, from: 301));

    expect(await chat.loadEarlierMessages(), isTrue);
    final ids = chat.messages.map((message) => message['id']).toList();
    expect(ids.toSet(), hasLength(ids.length));
    expect(chat.messages, hasLength(235));
    expect(chat.messages.first['id'], 300);
    expect(chat.messages.last['id'], 66);
  });

  test(
    'refresh parcial injerta filas REST identificadas solo por row id',
    () async {
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll(_rowOnlyRows(300));
      final chat = _chat('row-id-refresh', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      expect(chat.messages, hasLength(120));

      server.rows.addAll(_rowOnlyRows(1, from: 301));
      await chat.loadMessages(expectedMessageCount: 301);

      expect(chat.messages, hasLength(121));
      expect(chat.messages.first['id'], 301);
      expect(chat.messages.last['id'], 181);
    },
  );

  test('backfill no confunde row id numérico con message id string', () async {
    final server = _TranscriptServer(paginate: true)
      ..rows.addAll([
        const {'id': 42, 'role': 'assistant', 'content': 'fila numérica'},
        const {'id': '42', 'role': 'assistant', 'content': 'token opaco'},
        for (var index = 0; index < 119; index++)
          {'role': 'tool', 'content': 'fila sin identidad $index'},
      ]);
    final chat = _chat('typed-id-namespaces', server.client());
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 121);
    expect(await chat.loadEarlierMessages(), isTrue);

    expect(chat.messages, hasLength(2));
    expect(chat.messages.any((message) => message['role'] == 'tool'), isFalse);
    expect(
      chat.messages.where((message) => message['content'] == 'fila numérica'),
      hasLength(1),
    );
    expect(
      chat.messages.where((message) => message['content'] == 'token opaco'),
      hasLength(1),
    );
  });

  test(
    'backfill conserva filas legítimas idénticas cuando no tienen id',
    () async {
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll([
          for (var index = 0; index < 121; index++)
            const {'role': 'assistant', 'content': 'respuesta idéntica'},
        ]);
      final chat = _chat('idless-duplicates', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 121);
      expect(chat.messages, hasLength(120));
      expect(chat.hasEarlierMessages, isTrue);

      expect(await chat.loadEarlierMessages(), isTrue);
      expect(chat.messages, hasLength(121));
      expect(
        chat.messages.where(
          (message) => message['content'] == 'respuesta idéntica',
        ),
        hasLength(121),
      );
    },
  );

  test(
    'refresh id-less tras backfill no duplica y mantiene reparación abierta',
    () async {
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll([
          for (var index = 0; index < 121; index++)
            const {'role': 'assistant', 'content': 'respuesta idéntica'},
        ]);
      final chat = _chat('idless-refresh', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 121);
      expect(await chat.loadEarlierMessages(), isTrue);
      expect(chat.messages, hasLength(121));

      await chat.loadMessages(expectedMessageCount: 121);

      expect(chat.messages, hasLength(121));
      expect(chat.hasEarlierMessages, isTrue);
      expect(chat.coreReadLineageComplete, isFalse);
    },
  );

  test(
    'página vacía tras múltiplo exacto conserva el backfill al refrescar',
    () async {
      final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(240));
      final chat = _chat('empty-page-refresh', server.client());
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 240);
      expect(await chat.loadEarlierMessages(), isTrue);
      expect(chat.messages, hasLength(240));
      expect(chat.hasEarlierMessages, isTrue);

      expect(await chat.loadEarlierMessages(), isFalse);
      expect(chat.hasEarlierMessages, isFalse);

      await chat.loadMessages(expectedMessageCount: 240);

      expect(chat.messages, hasLength(240));
      expect(chat.messages.first['content'], 'msg 240');
      expect(chat.messages.last['content'], 'msg 1');
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test('resume diferido: ack hydrating + resume_progress complete aplica el '
      'historial aunque el primer REST falle', () async {
    final gateway = _DeferrableGateway()
      ..snapshot = DesktopSessionSnapshot.fromJson(
        {
          'session_id': 'runtime-deferred',
          'session_key': 'stored-chat',
          'hydrating': true,
          'message_count': 2,
          'messages': <Object>[],
        },
        requestedStoredSessionId: 'stored-chat',
        created: false,
        method: 'session.resume',
      );
    final server = _TranscriptServer(paginate: true)
      ..rows.addAll([
        {'id': 1, 'role': 'user', 'content': 'pregunta'},
        {'id': 2, 'role': 'assistant', 'content': 'respuesta'},
      ])
      ..healthy = false;
    final chat = _chat('deferred', server.client(), gateway: gateway);
    addTearDown(chat.dispose);

    final load = chat.loadMessages(expectedMessageCount: 2);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(gateway.lastDeferHistory, isTrue);
    expect(chat.isHydratingDesktopHistory, isTrue);
    expect(chat.messagesLoaded, isFalse);

    server.healthy = true;
    gateway.emitResumeProgress('complete', messageCount: 2);
    await load;

    expect(chat.messagesLoaded, isTrue);
    expect(chat.isHydratingDesktopHistory, isFalse);
    expect(chat.messages, hasLength(2));
    expect(chat.messages.first['content'], 'respuesta');
    // Prefetch fallido + reintento tras el resume_progress.
    expect(server.requests, hasLength(2));
  });

  test(
    'resume_progress sustituye inflight ya terminal sin duplicar el turno',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {'id': 'old-user', 'role': 'user', 'content': 'turno anterior'},
        {
          'id': 'old-answer',
          'role': 'assistant',
          'content': 'respuesta anterior',
        },
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-hydration',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: initialRows.length,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
        );
      final chat = _chat(
        'terminal-hydration-no-duplicate',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: initialRows.length);
      server.healthy = false;
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-terminal-hydration',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 4,
        hydrating: true,
        running: true,
        inflight: DesktopInflightTurn(
          user: 'turno hidratado',
          assistant: 'respuesta parcial hidratada',
          streaming: true,
        ),
      );
      await chat.loadMessages(expectedMessageCount: 4);
      expect(chat.isHydratingDesktopHistory, isTrue);
      expect(chat.isStreaming, isTrue);

      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta final hidratada'},
      );
      for (
        var attempt = 0;
        attempt < 100 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(chat.state, ChatPipelineState.completed);

      server
        ..healthy = true
        ..rows.addAll(const [
          {'id': 'hydrated-user', 'role': 'user', 'content': 'turno hidratado'},
          {
            'id': 'hydrated-answer',
            'role': 'assistant',
            'content': 'respuesta final hidratada',
          },
        ]);
      gateway.emitResumeProgress('complete', messageCount: 4);
      for (
        var attempt = 0;
        attempt < 100 &&
            !chat.messages.any((message) => message['id'] == 'hydrated-answer');
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(
        chat.messages.where(
          (message) => message['content'] == 'turno hidratado',
        ),
        hasLength(1),
      );
      expect(
        chat.messages.where(
          (message) => message['content'] == 'respuesta final hidratada',
        ),
        hasLength(1),
      );
      expect(
        chat.messages.singleWhere(
          (message) => message['content'] == 'turno hidratado',
        )['id'],
        'hydrated-user',
      );
    },
  );

  test(
    'resume_progress sustituye el terminal usando el row id del ancla',
    () async {
      final initialRows = _rowOnlyRows(300);
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-terminal-row-id',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 300,
        );
      final chat = _chat(
        'terminal-row-id-no-duplicate',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: initialRows.length);
      expect(chat.hasEarlierMessages, isTrue);
      server.healthy = false;
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-terminal-row-id',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 302,
        hydrating: true,
        running: true,
        inflight: DesktopInflightTurn(
          user: 'turno hidratado por fila',
          assistant: 'respuesta parcial por fila',
          streaming: true,
        ),
      );
      await chat.loadMessages(expectedMessageCount: 302);

      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta final por fila'},
      );
      for (
        var attempt = 0;
        attempt < 100 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(chat.state, ChatPipelineState.completed);

      server
        ..healthy = true
        ..rows.addAll(const [
          {'id': 301, 'role': 'user', 'content': 'turno hidratado por fila'},
          {
            'id': 302,
            'role': 'assistant',
            'content': 'respuesta final por fila',
          },
        ]);
      gateway.emitResumeProgress('complete', messageCount: 302);
      for (
        var attempt = 0;
        attempt < 100 && !chat.messages.any((message) => message['id'] == 302);
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(
        chat.messages.where(
          (message) => message['content'] == 'turno hidratado por fila',
        ),
        hasLength(1),
      );
      expect(
        chat.messages.where(
          (message) => message['content'] == 'respuesta final por fila',
        ),
        hasLength(1),
      );
      expect(
        chat.messages.singleWhere(
          (message) => message['content'] == 'turno hidratado por fila',
        )['id'],
        301,
      );
    },
  );

  test(
    'resume_progress no fusiona canonical e inflight idénticos sin ID compartido',
    () async {
      final server = _TranscriptServer(paginate: true);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-live-canonical-overlay',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 2,
          hydrating: true,
          running: true,
          inflight: DesktopInflightTurn(
            user: 'turno current canónico',
            assistant: 'respuesta parcial current suficientemente larga',
            streaming: true,
          ),
        );
      final chat = _chat(
        'live-canonical-overlay',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      server.rows.addAll(const [
        {
          'id': 'current-user',
          'role': 'user',
          'content': 'turno current canónico',
        },
        {
          'id': 'current-answer',
          'role': 'assistant',
          'content': 'respuesta parcial current suficientemente larga',
        },
      ]);
      gateway.emitResumeProgress('complete', messageCount: 2);
      for (
        var attempt = 0;
        attempt < 100 && server.requests.length < 2;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      for (var attempt = 0; attempt < 20; attempt++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(
        chat.messages.where(
          (message) => message['content'] == 'turno current canónico',
        ),
        hasLength(2),
      );
      expect(
        chat.messages.where(
          (message) =>
              message['content'] ==
              'respuesta parcial current suficientemente larga',
        ),
        hasLength(2),
      );
      expect(chat.isStreaming, isTrue);
      expect(
        chat.internalMessagesForTesting.where(
          (message) => message['_desktopSnapshotKind'] == 'inflight',
        ),
        hasLength(2),
      );
      expect(
        chat.messages.where((message) => message['id'] == 'current-user'),
        hasLength(1),
      );
      expect(
        chat.messages.where((message) => message['id'] == 'current-answer'),
        hasLength(1),
      );
    },
  );

  test(
    'hidratación live no inventa equivalencia si falta assistant o cambia su texto',
    () async {
      for (final durableRows in <List<Map<String, dynamic>>>[
        const [
          {
            'id': 'ambiguous-user-only',
            'role': 'user',
            'content': 'prompt repetido ambiguo',
          },
        ],
        const [
          {
            'id': 'old-repeated-user',
            'role': 'user',
            'content': 'prompt repetido ambiguo',
          },
          {
            'id': 'old-repeated-answer',
            'role': 'assistant',
            'content': 'respuesta anterior distinta',
          },
        ],
      ]) {
        final server = _TranscriptServer(paginate: true);
        final suffix = durableRows.length;
        final gateway = _DeferrableGateway()
          ..snapshot = DesktopSessionSnapshot(
            runtimeSessionId: 'runtime-ambiguous-live-$suffix',
            storedSessionId: 'stored-chat',
            created: false,
            messagesProvided: false,
            messageCount: durableRows.length,
            hydrating: true,
            running: true,
            inflight: DesktopInflightTurn(
              user: 'prompt repetido ambiguo',
              assistant: 'respuesta nueva current claramente distinta',
              streaming: true,
            ),
          );
        final chat = _chat(
          'ambiguous-live-$suffix',
          server.client(),
          gateway: gateway,
        );
        addTearDown(chat.dispose);

        await chat.loadMessages(expectedMessageCount: durableRows.length);
        server.rows.addAll(durableRows);
        gateway.emitResumeProgress(
          'complete',
          messageCount: durableRows.length,
        );
        for (
          var attempt = 0;
          attempt < 100 && server.requests.length < 2;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        for (var attempt = 0; attempt < 20; attempt++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          chat.messages.where(
            (message) => message['content'] == 'prompt repetido ambiguo',
          ),
          hasLength(2),
          reason: 'durableRows=${durableRows.length}',
        );
      }
    },
  );

  test('REST id-less más inflight homónimo falla cerrado ante Stop', () async {
    final rows = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'primer turno detenido'},
    ];
    final server = _TranscriptServer(paginate: false)..rows.addAll(rows);
    final resumeGate = Completer<DesktopSessionSnapshot>();
    final gateway = _DeferrableGateway()..resumeGate = resumeGate;
    final recorded = <CancelledTurnTombstone>[];
    final chat = _chat(
      'complete-rest-hydrating-empty-messages',
      server.client(),
      gateway: gateway,
      onCancelledTurn: (tombstone) async => recorded.add(tombstone),
    );
    addTearDown(chat.dispose);

    final load = chat.loadMessages(expectedMessageCount: 1);
    while (chat.messages.length != 1) {
      await Future<void>.delayed(Duration.zero);
    }
    resumeGate.complete(
      DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-complete-rest-hydrating',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: true,
        messages: [],
        messageCount: 1,
        hydrating: true,
        inflight: DesktopInflightTurn(
          user: 'primer turno detenido',
          streaming: true,
        ),
        running: true,
      ),
    );
    await load;

    expect(chat.hasEarlierMessages, isFalse);
    expect(chat.isStreaming, isTrue);
    await expectLater(chat.cancel(), throwsStateError);

    expect(recorded, isEmpty);
    expect(chat.isStreaming, isTrue);
  });

  test(
    'Stop no ancla inflight id-less dentro del mismo turno durable',
    () async {
      final rows = <Map<String, dynamic>>[
        {'id': 301, 'role': 'user', 'content': 'turno current durable'},
        {
          'id': 302,
          'role': 'assistant',
          'content': 'respuesta parcial current',
        },
      ];
      final server = _TranscriptServer(paginate: false)..rows.addAll(rows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-current-durable-and-inflight',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 2,
          hydrating: true,
          running: true,
          inflight: DesktopInflightTurn(
            user: 'turno current durable',
            assistant: 'respuesta parcial current',
            streaming: true,
          ),
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'current-durable-and-inflight-stop',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      expect(chat.isStreaming, isTrue);
      expect(
        chat.messages.where(
          (message) => message['content'] == 'turno current durable',
        ),
        hasLength(2),
      );

      await expectLater(chat.cancel(), throwsStateError);

      expect(recorded, isEmpty);
      expect(chat.isStreaming, isTrue);
    },
  );

  test(
    'Stop no enlaza por posición una fila aparecida tras el submit local',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {'id': 101, 'role': 'user', 'content': 'turno anterior'},
        {'id': 102, 'role': 'assistant', 'content': 'respuesta anterior'},
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-local-submit-stop',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: initialRows.length,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'local-submit-durable-stop',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: initialRows.length);
      await chat.send(
        fullText: 'turno current durable',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );

      final liveRows = <Map<String, dynamic>>[
        ...initialRows,
        {'id': 301, 'role': 'user', 'content': 'turno current durable'},
        {
          'id': 302,
          'role': 'assistant',
          'content': 'respuesta parcial current',
        },
      ];
      server.rows
        ..clear()
        ..addAll(liveRows);
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-local-submit-stop',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: liveRows.length,
        hydrating: true,
        running: true,
        inflight: DesktopInflightTurn(
          user: 'turno current durable',
          assistant: 'respuesta parcial current',
          streaming: true,
        ),
      );
      await chat.loadMessages(expectedMessageCount: liveRows.length);

      expect(chat.isStreaming, isTrue);
      expect(
        chat.messages.where(
          (message) => message['content'] == 'turno current durable',
        ),
        hasLength(2),
        reason:
            'Console posee este mismo turno: optimista y durable sobreviven, '
            'pero el inflight ya representado no añade una tercera burbuja',
      );

      await expectLater(chat.cancel(), throwsStateError);

      expect(recorded, isEmpty);
      expect(chat.isStreaming, isTrue);
    },
  );

  test(
    'Stop no confunde con el turno actual una fila histórica tardía homónima',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {
          'id': 101,
          'role': 'user',
          'content': 'turno anterior',
          'timestamp': 10,
        },
        {
          'id': 102,
          'role': 'assistant',
          'content': 'respuesta anterior',
          'timestamp': 20,
        },
        {
          'role': 'user',
          'content': 'turno histórico sin identidad',
          'timestamp': 30,
        },
      ];
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-used-session-stop',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: initialRows.length,
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'used-session-stop',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: initialRows.length);
      await chat.send(
        fullText: 'turno actual que debe parar',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      server.rows.add(const {
        'id': 301,
        'role': 'user',
        'content': 'turno actual que debe parar',
        'timestamp': 99,
      });
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-used-session-stop',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: server.rows.length,
        running: true,
        inflight: DesktopInflightTurn(
          user: 'turno actual que debe parar',
          streaming: true,
          startedAt: DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
        ),
      );

      final requestsBeforeStop = server.requests.length;
      await expectLater(chat.cancel(), throwsStateError);

      expect(recorded, isEmpty);
      expect(chat.isStreaming, isTrue);
      expect(
        server.requests,
        hasLength(requestsBeforeStop + 1),
        reason:
            'la página se consulta, pero su fila anterior a inflight.started_at '
            'no acredita el turno vivo',
      );
    },
  );

  test(
    'Stop acepta una frontera homónima acreditada antes del submit',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {
          'id': 301,
          'role': 'user',
          'content': 'prompt repetido en sesión usada',
          'timestamp': 99,
        },
      ];
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-used-repeated-stop',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: initialRows.length,
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'used-repeated-stop',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: initialRows.length);
      await chat.send(
        fullText: 'prompt repetido en sesión usada',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-used-repeated-stop',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: initialRows.length,
        running: true,
        inflight: DesktopInflightTurn(
          user: 'prompt repetido en sesión usada',
          streaming: true,
          startedAt: DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
        ),
      );

      await chat.cancel();

      expect(recorded, hasLength(1));
      expect(recorded.single.anchorRowId, 301);
      expect(recorded.single.cancelledRowId, isNull);
      expect(chat.state, ChatPipelineState.cancelled);
    },
  );

  test('Stop invalida la frontera si create repinea el stored id', () async {
    final historical = const {
      'id': 301,
      'role': 'user',
      'content': 'prompt repetido antes del repin',
      'timestamp': 99,
    };
    final server = _TranscriptServer(paginate: true)..rows.add(historical);
    final gateway = _DeferrableGateway()
      ..createSnapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-repinned-stop',
        storedSessionId: 'stored-chat',
        created: true,
        messagesProvided: false,
      );
    final recorded = <CancelledTurnTombstone>[];
    final chat = _chat(
      'repinned-stop-boundary',
      server.client(),
      sessionId: 'mobile-route-before-create',
      gateway: gateway,
      onCancelledTurn: (tombstone) async => recorded.add(tombstone),
    );
    addTearDown(chat.dispose);
    chat.markStoredSessionMissing();
    chat.internalMessagesForTesting.add(Map<String, dynamic>.of(historical));

    final accepted = await chat.send(
      fullText: 'prompt repetido antes del repin',
      model: 'hermes-agent',
      history: chat.buildHistory(),
    );
    expect(accepted, isTrue);
    expect(chat.serverSessionId, 'stored-chat');
    gateway.snapshot = DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-repinned-stop',
      storedSessionId: 'stored-chat',
      created: false,
      messagesProvided: false,
      messageCount: 1,
      running: true,
      inflight: DesktopInflightTurn(
        user: 'prompt repetido antes del repin',
        streaming: true,
        startedAt: DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
      ),
    );

    await expectLater(chat.cancel(), throwsStateError);

    expect(recorded, isEmpty);
    expect(chat.isStreaming, isTrue);
  });

  test(
    'Stop no atraviesa un turno local intermedio para capturar un ancla vieja',
    () async {
      final server = _TranscriptServer(paginate: true)
        ..rows.add(const {
          'id': 101,
          'role': 'user',
          'content': 'turno durable A',
          'timestamp': 10,
        });
      final gateway = _DeferrableGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-local-boundary-gap',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 1,
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'local-boundary-gap',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 1);
      await chat.send(
        fullText: 'turno local B aún no durable',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.emit(
        'message.complete',
        payload: const {'text': 'respuesta local B legítima'},
      );
      for (
        var attempt = 0;
        attempt < 100 && chat.state != ChatPipelineState.completed;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(chat.state, ChatPipelineState.completed);

      final accepted = await chat.send(
        fullText: 'turno local C que debe parar',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      expect(accepted, isTrue);
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-local-boundary-gap',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 1,
        running: true,
        inflight: DesktopInflightTurn(
          user: 'turno local C que debe parar',
          streaming: true,
          startedAt: DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
        ),
      );

      await expectLater(chat.cancel(), throwsStateError);

      expect(recorded, isEmpty);
      expect(chat.isStreaming, isTrue);
      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta local B legítima',
        ),
        isTrue,
      );
    },
  );

  test(
    'Stop liga por timestamp e ID el turno vivo detrás de historia id-less',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {
          'id': 101,
          'role': 'assistant',
          'content': 'respuesta anterior',
          'timestamp': 20,
        },
        {
          'role': 'user',
          'content': 'turno histórico sin identidad',
          'timestamp': 30,
        },
      ];
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-used-session-stop-safe',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: initialRows.length,
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'used-session-stop-safe',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: initialRows.length);
      await chat.send(
        fullText: 'turno actual seguro',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      server.rows.add(const {
        'id': 301,
        'role': 'user',
        'content': 'turno actual seguro',
        'timestamp': 101,
      });
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-used-session-stop-safe',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: server.rows.length,
        running: true,
        inflight: DesktopInflightTurn(
          user: 'turno actual seguro',
          streaming: true,
          startedAt: DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
        ),
      );

      await chat.cancel();

      expect(recorded, hasLength(1));
      expect(recorded.single.cancelledRowId, 301);
      expect(chat.state, ChatPipelineState.cancelled);
    },
  );

  test(
    'Stop usa turn_started_at real del Gateway en una sesión ya usada',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {
          'id': 101,
          'role': 'assistant',
          'content': 'respuesta anterior',
          'timestamp': 20,
        },
        {
          'role': 'user',
          'content': 'turno anterior sin identidad',
          'timestamp': 30,
        },
      ];
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-real-gateway-stop',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: initialRows.length,
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'real-gateway-stop',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: initialRows.length);
      await chat.send(
        fullText: 'turno actual con contrato real',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      server.rows.add(const {
        'id': 301,
        'role': 'user',
        'content': 'turno actual con contrato real',
        'timestamp': 101,
      });
      gateway.snapshot = DesktopSessionSnapshot.fromJson(
        const {
          'session_id': 'runtime-real-gateway-stop',
          'session_key': 'stored-chat',
          'messages': <Object>[],
          'messages_omitted': true,
          'message_count': 3,
          'running': true,
          'turn_started_at': 100,
          'inflight': {
            'user': 'turno actual con contrato real',
            'assistant': '',
            'streaming': true,
          },
        },
        requestedStoredSessionId: 'stored-chat',
        created: false,
        method: 'session.resume',
      );

      await chat.cancel();

      expect(recorded, hasLength(1));
      expect(recorded.single.cancelledRowId, 301);
      expect(chat.state, ChatPipelineState.cancelled);
    },
  );

  test(
    'refresh concurrente invalida la prueba de identidad de Stop por epoch',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final initialRows = <Map<String, dynamic>>[
        {
          'id': 101,
          'role': 'assistant',
          'content': 'respuesta anterior',
          'timestamp': 20,
        },
        {
          'role': 'user',
          'content': 'turno histórico sin identidad',
          'timestamp': 30,
        },
      ];
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stop-proof-race',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: initialRows.length,
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'stop-proof-race',
        server.client(),
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(
        expectedMessageCount: initialRows.length,
      );
      await server.waitForRequests(1);
      server.complete(0, initialRows, paginated: true);
      await initialLoad;

      await chat.send(
        fullText: 'turno actual en carrera',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      final currentRows = <Map<String, dynamic>>[
        ...initialRows,
        {
          'id': 301,
          'role': 'user',
          'content': 'turno actual en carrera',
          'timestamp': 101,
        },
      ];
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-stop-proof-race',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: currentRows.length,
        running: true,
        inflight: DesktopInflightTurn(
          user: 'turno actual en carrera',
          streaming: true,
          startedAt: DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
        ),
      );

      final cancellation = chat.cancel();
      await server.waitForRequests(2);
      final refresh = chat.loadMessages(
        expectedMessageCount: currentRows.length,
      );
      await server.waitForRequests(3);

      server.complete(1, currentRows, paginated: true);
      await expectLater(cancellation, throwsStateError);
      expect(recorded, isEmpty);
      expect(chat.isStreaming, isTrue);

      server.complete(2, currentRows, paginated: true);
      await refresh;
    },
  );

  test('Stop rechaza páginas no acreditadas para enlazar identidad', () async {
    for (final invalid in const [
      'offset-no-cero',
      'fila-malformada',
      'pagination-malformada',
    ]) {
      var requests = 0;
      final initialRows = <Map<String, dynamic>>[
        {
          'id': 101,
          'role': 'assistant',
          'content': 'respuesta anterior',
          'timestamp': 20,
        },
        {
          'role': 'user',
          'content': 'turno histórico sin identidad',
          'timestamp': 30,
        },
      ];
      final currentRows = <Map<String, dynamic>>[
        ...initialRows,
        {
          'id': 301,
          'role': 'user',
          'content': 'turno actual $invalid',
          'timestamp': 101,
        },
      ];
      final client = MockClient((request) async {
        requests++;
        final stopping = requests > 1;
        final data = <Object?>[
          ...(stopping ? currentRows : initialRows),
          if (stopping && invalid == 'fila-malformada') 'fila inválida',
        ];
        final pagination = invalid == 'pagination-malformada' && stopping
            ? <String, Object?>{'limit': 120, 'offset': '0'}
            : <String, Object?>{
                'limit': 120,
                'offset': stopping && invalid == 'offset-no-cero' ? 1 : 0,
                'order': 'latest',
                'returned': data.length,
              };
        return http.Response(
          jsonEncode({
            'object': 'list',
            'data': data,
            'pagination': pagination,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-stop-invalid-$invalid',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: initialRows.length,
        );
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'stop-invalid-$invalid',
        client,
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );

      await chat.loadMessages(expectedMessageCount: initialRows.length);
      await chat.send(
        fullText: 'turno actual $invalid',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-stop-invalid-$invalid',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: currentRows.length,
        running: true,
        inflight: DesktopInflightTurn(
          user: 'turno actual $invalid',
          streaming: true,
          startedAt: DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
        ),
      );

      await expectLater(chat.cancel(), throwsStateError, reason: invalid);
      expect(recorded, isEmpty, reason: invalid);
      expect(chat.isStreaming, isTrue, reason: invalid);
      chat.dispose();
      client.close();
    }
  });

  test(
    'resume_progress hidrata también cuando ya hay fallback durable visible',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {'id': 1, 'role': 'user', 'content': 'pregunta anterior'},
        {'id': 2, 'role': 'assistant', 'content': 'respuesta anterior'},
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-before-visible-progress',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 2,
        );
      final chat = _chat(
        'visible-fallback-progress',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      server.healthy = false;
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-visible-progress',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 3,
        hydrating: true,
      );
      await chat.loadMessages(expectedMessageCount: 3);
      expect(chat.messages.first['id'], 2);

      server
        ..healthy = true
        ..paginate = false;
      server.rows.add({
        'id': 3,
        'role': 'assistant',
        'content': 'historial hidratado automáticamente',
      });
      gateway.emitResumeProgress('complete', messageCount: 3);
      while (chat.messages.first['id'] != 3) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(chat.messages, hasLength(3));
      expect(
        chat.messages.first['content'],
        'historial hidratado automáticamente',
      );
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'ack hydrating no aplica firstUser sobre un fallback completo pero viejo',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {
          'id': 1,
          'message_id': 'msg-1',
          'role': 'user',
          'content': 'prompt todavía no cancelado',
        },
        {
          'id': 2,
          'message_id': 'msg-2',
          'role': 'assistant',
          'content': 'respuesta legítima visible durante hydration',
        },
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-before-stale-hydration',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 2,
        );
      final chat = _chat(
        'stale-complete-hydration',
        server.client(),
        gateway: gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(content: 'prompt repetido', firstUser: true),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      chat.internalMessagesForTesting[1] = {
        ...chat.messages[1],
        'content': 'prompt repetido',
      };
      server.healthy = false;
      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-stale-hydration',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 2,
        hydrating: true,
      );

      await chat.loadMessages(expectedMessageCount: 2);

      expect(chat.isHydratingDesktopHistory, isTrue);
      expect(chat.messages.any((message) => message['id'] == 2), isTrue);
      expect(chat.messages[1].containsKey('_cancelledUser'), isFalse);

      server.healthy = true;
      server.rows
        ..clear()
        ..addAll([
          {
            'id': 1,
            'message_id': 'msg-1',
            'role': 'user',
            'content': 'prompt repetido',
          },
          {
            'id': 2,
            'message_id': 'msg-2',
            'role': 'assistant',
            'content': 'respuesta que el tombstone debe retirar',
          },
        ]);
      gateway.emitResumeProgress('complete', messageCount: 2);
      for (
        var attempt = 0;
        attempt < 200 && chat.messages.any((message) => message['id'] == 2);
        attempt++
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(chat.isHydratingDesktopHistory, isFalse);
      expect(chat.messages.any((message) => message['id'] == 2), isFalse);
      expect(chat.messages.single['_cancelledUser'], isTrue);
    },
  );

  test(
    'resume_progress de epoch nuevo no queda bloqueado por hidratación vieja',
    () async {
      final server = _OutOfOrderTranscriptServer();
      final initialRows = <Map<String, dynamic>>[
        {'id': 1, 'role': 'user', 'content': 'inicial'},
        {'id': 2, 'role': 'assistant', 'content': 'inicial completa'},
      ];
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-hydration-epochs',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 2,
        );
      final chat = _chat(
        'hydration-flight-epochs',
        server.client(),
        gateway: gateway,
      );
      addTearDown(() {
        for (final request in server.requests) {
          if (!request.response.isCompleted) {
            request.response.complete(
              http.Response(
                jsonEncode({'object': 'list', 'data': <Object>[]}),
                200,
                headers: {'content-type': 'application/json'},
              ),
            );
          }
        }
        chat.dispose();
      });

      final initialLoad = chat.loadMessages(expectedMessageCount: 2);
      await server.waitForRequests(1);
      server.complete(0, initialRows, paginated: false);
      await initialLoad;

      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-hydration-epochs',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 3,
        hydrating: true,
      );
      final firstHydratingLoad = chat.loadMessages(expectedMessageCount: 3);
      await server.waitForRequests(2);
      server.complete(1, const [], paginated: true);
      await firstHydratingLoad;
      gateway.emitResumeProgress('complete', messageCount: 3);
      await server.waitForRequests(3);

      final secondHydratingLoad = chat.loadMessages(expectedMessageCount: 3);
      await server.waitForRequests(4);
      server.complete(3, const [], paginated: true);
      await secondHydratingLoad;
      gateway.emitResumeProgress('complete', messageCount: 3);
      await server.waitForRequests(5);

      final currentRows = <Map<String, dynamic>>[
        ...initialRows,
        {'id': 3, 'role': 'assistant', 'content': 'epoch vigente'},
      ];
      server.complete(4, currentRows, paginated: false);
      while (chat.messages.first['id'] != 3) {
        await Future<void>.delayed(Duration.zero);
      }
      server.complete(2, [
        {'id': 99, 'role': 'assistant', 'content': 'epoch obsoleto'},
      ], paginated: false);
      await Future<void>.delayed(Duration.zero);

      expect(chat.messages.first['id'], 3);
      expect(chat.messages.any((message) => message['id'] == 99), isFalse);
    },
  );

  test(
    'snapshot omitido conserva backfill pendiente aunque muestre inflight',
    () async {
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-omitted-history',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 300,
          inflight: DesktopInflightTurn(
            user: 'turno activo sin historial',
            streaming: true,
          ),
          running: true,
        );
      final server = _TranscriptServer(paginate: true)..healthy = false;
      final chat = _chat('omitted-history', server.client(), gateway: gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);

      expect(chat.messages, isNotEmpty);
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'snapshot omitido sin messageCount también permite buscar historial',
    () async {
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-omitted-unknown-count',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          inflight: DesktopInflightTurn(
            user: 'turno activo con contador ausente',
            streaming: true,
          ),
          running: true,
        );
      final server = _TranscriptServer(paginate: true)..healthy = false;
      final chat = _chat(
        'omitted-unknown-count',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      expect(chat.messages, isNotEmpty);
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'snapshot omitido con count mayor degrada un fallback completo sin borrarlo',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {'message_id': 'fallback-user', 'role': 'user', 'content': 'pregunta'},
        {
          'message_id': 'fallback-answer',
          'role': 'assistant',
          'content': 'respuesta',
        },
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-fallback-complete',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 2,
        );
      final chat = _chat(
        'omitted-larger-count',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      expect(chat.messages, hasLength(2));
      expect(chat.hasEarlierMessages, isFalse);

      server.healthy = false;
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-fallback-omitted',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 300,
        inflight: DesktopInflightTurn(
          user: 'turno posterior activo',
          streaming: true,
        ),
        running: true,
      );
      await chat.loadMessages(expectedMessageCount: 300);

      expect(
        chat.messages.any(
          (message) => message['message_id'] == 'fallback-answer',
        ),
        isTrue,
      );
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'snapshot omitido con count menor degrada un fallback completo sin borrarlo',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {
          'message_id': 'compacted-fallback-user',
          'role': 'user',
          'content': 'prompt original',
        },
        {
          'message_id': 'compacted-fallback-answer',
          'role': 'assistant',
          'content': 'respuesta legítima',
        },
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-before-compaction',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 2,
        );
      final chat = _chat(
        'omitted-smaller-count',
        server.client(),
        gateway: gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido tras compactación',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      expect(chat.messages, hasLength(2));
      expect(chat.hasEarlierMessages, isFalse);

      final userIndex = chat.messages.indexWhere(
        (message) => message['message_id'] == 'compacted-fallback-user',
      );
      chat.internalMessagesForTesting[userIndex] = {
        ...chat.messages[userIndex],
        'content': 'prompt repetido tras compactación',
      };
      server.healthy = false;
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-after-compaction',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 1,
      );

      await chat.loadMessages(expectedMessageCount: 1);

      expect(
        chat.messages.any(
          (message) =>
              message['message_id'] == 'compacted-fallback-answer' &&
              message['content'] == 'respuesta legítima',
        ),
        isTrue,
      );
      expect(
        chat.messages
            .singleWhere(
              (message) => message['message_id'] == 'compacted-fallback-user',
            )
            .containsKey('_cancelledUser'),
        isFalse,
      );
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'snapshot omitido no acredita count contra una fila durable sin id',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {
          'message_id': 'idless-coverage-user',
          'role': 'user',
          'content': 'prompt original',
        },
        {'role': 'assistant', 'content': 'respuesta legítima durable sin id'},
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-before-idless-count',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 2,
        );
      final chat = _chat(
        'omitted-idless-coverage',
        server.client(),
        gateway: gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido tras compactación idless',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      expect(chat.messages, hasLength(2));
      expect(chat.hasEarlierMessages, isFalse);
      final userIndex = chat.messages.indexWhere(
        (message) => message['message_id'] == 'idless-coverage-user',
      );
      chat.internalMessagesForTesting[userIndex] = {
        ...chat.messages[userIndex],
        'content': 'prompt repetido tras compactación idless',
      };

      server.healthy = false;
      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-after-idless-count',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 1,
      );
      await chat.loadMessages(expectedMessageCount: 1);

      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'respuesta legítima durable sin id',
        ),
        isTrue,
      );
      expect(
        chat.messages
            .singleWhere(
              (message) => message['message_id'] == 'idless-coverage-user',
            )
            .containsKey('_cancelledUser'),
        isFalse,
      );
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'snapshot provisto con count distinto no acredita transcript completo',
    () async {
      final snapshotRows = <Map<String, dynamic>>[
        {
          'message_id': 'provided-mismatch-user',
          'role': 'user',
          'content': 'prompt repetido con count desigual',
        },
        {
          'message_id': 'provided-mismatch-answer',
          'role': 'assistant',
          'content': 'respuesta legítima con count desigual',
        },
      ];
      final server = _TranscriptServer(paginate: true)..healthy = false;
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-provided-count-mismatch',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: snapshotRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 1,
        );
      final chat = _chat(
        'provided-count-mismatch',
        server.client(),
        gateway: gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido con count desigual',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 1);

      expect(
        chat.internalMessagesForTesting.any(
          (message) =>
              canonicalTranscriptMessageId(message) ==
                  'provided-mismatch-answer' &&
              message['content'] == 'respuesta legítima con count desigual',
        ),
        isTrue,
      );
      expect(
        chat.internalMessagesForTesting
            .singleWhere(
              (message) =>
                  canonicalTranscriptMessageId(message) ==
                  'provided-mismatch-user',
            )
            .containsKey('_cancelledUser'),
        isFalse,
      );
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'snapshot provisto vacío degrada el fallback visible que conserva',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {
          'message_id': 'provided-empty-fallback-user',
          'role': 'user',
          'content': 'prompt original',
        },
        {
          'message_id': 'provided-empty-fallback-answer',
          'role': 'assistant',
          'content': 'respuesta legítima antes del snapshot vacío',
        },
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-before-provided-empty',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 2,
        );
      final chat = _chat(
        'provided-empty-over-fallback',
        server.client(),
        gateway: gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(
            content: 'prompt repetido antes del snapshot vacío',
            firstUser: true,
          ),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      final userIndex = chat.messages.indexWhere(
        (message) =>
            canonicalTranscriptMessageId(message) ==
            'provided-empty-fallback-user',
      );
      chat.internalMessagesForTesting[userIndex] = {
        ...chat.messages[userIndex],
        'content': 'prompt repetido antes del snapshot vacío',
      };
      server.healthy = false;
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-provided-empty',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: true,
        messages: [],
        messageCount: 0,
        inflight: DesktopInflightTurn(
          user: 'turno activo posterior al snapshot vacío',
          streaming: true,
        ),
        running: true,
      );

      await chat.loadMessages(expectedMessageCount: 0);

      expect(
        chat.messages.any(
          (message) =>
              canonicalTranscriptMessageId(message) ==
                  'provided-empty-fallback-answer' &&
              message['content'] ==
                  'respuesta legítima antes del snapshot vacío',
        ),
        isTrue,
      );
      expect(
        chat.messages
            .singleWhere(
              (message) =>
                  canonicalTranscriptMessageId(message) ==
                  'provided-empty-fallback-user',
            )
            .containsKey('_cancelledUser'),
        isFalse,
      );
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'snapshot nuevo reemplaza el count hydrating viejo tras compactación',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {'message_id': 'before-compact-user', 'role': 'user', 'content': 'old'},
        {
          'message_id': 'before-compact-answer',
          'role': 'assistant',
          'content': 'old answer',
        },
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-before-hydrating-compact',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 2,
        );
      final chat = _chat(
        'hydrating-count-replaced',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      server.healthy = false;
      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-hydrating-old-generation',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 300,
        hydrating: true,
      );
      await chat.loadMessages(expectedMessageCount: 300);
      expect(chat.hasEarlierMessages, isTrue);

      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-compacted-new-generation',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 1,
      );
      await chat.loadMessages(expectedMessageCount: 1);
      expect(chat.hasEarlierMessages, isTrue);

      server
        ..healthy = true
        ..paginate = true;
      server.rows
        ..clear()
        ..add(const {
          'message_id': 'after-compact-only-row',
          'role': 'assistant',
          'content': 'compacted transcript',
        });

      expect(await chat.loadEarlierMessages(), isTrue);
      expect(server.requests.last.queryParameters['offset'], '0');
      expect(
        chat.messages.any(
          (message) => message['message_id'] == 'after-compact-only-row',
        ),
        isTrue,
      );
      expect(chat.hasEarlierMessages, isFalse);
    },
  );

  test(
    'snapshot hydrating parcial degrada un fallback completo sin borrarlo',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {'message_id': 'hydrating-user', 'role': 'user', 'content': 'pregunta'},
        {
          'message_id': 'hydrating-answer',
          'role': 'assistant',
          'content': 'respuesta legítima',
        },
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-before-partial-hydration',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 2,
        );
      final chat = _chat(
        'partial-hydration-over-complete',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      expect(chat.hasEarlierMessages, isFalse);

      server.healthy = false;
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-partial-hydration',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: true,
        messages: [
          DesktopSessionMessage.tryParse(const {
            'message_id': 'hydrating-partial-row',
            'role': 'user',
            'content': 'fila todavía parcial',
          })!,
        ],
        messageCount: 300,
        hydrating: true,
      );
      await chat.loadMessages(expectedMessageCount: 300);

      expect(
        chat.messages.any(
          (message) => message['message_id'] == 'hydrating-answer',
        ),
        isTrue,
      );
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test('snapshot omitido no cuenta inflight como cobertura durable', () async {
    final initialRows = <Map<String, dynamic>>[
      {'message_id': 'coverage-user', 'role': 'user', 'content': 'pregunta'},
      {
        'message_id': 'coverage-answer',
        'role': 'assistant',
        'content': 'respuesta',
      },
    ];
    final server = _TranscriptServer(paginate: false)..rows.addAll(initialRows);
    final gateway = _DeferrableGateway()
      ..snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-coverage-complete',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: true,
        messages: initialRows
            .map((row) => DesktopSessionMessage.tryParse(row)!)
            .toList(growable: false),
        messageCount: 2,
      );
    final chat = _chat(
      'inflight-is-not-durable-coverage',
      server.client(),
      gateway: gateway,
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 2);
    server.healthy = false;
    gateway.snapshot = DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-coverage-inflight',
      storedSessionId: 'stored-chat',
      created: false,
      messagesProvided: false,
      messageCount: 2,
      inflight: DesktopInflightTurn(
        user: 'turno sintético',
        assistant: 'parcial sintético',
        streaming: true,
      ),
      running: true,
    );
    await chat.loadMessages(expectedMessageCount: 2);
    expect(chat.messages, hasLength(4));
    expect(chat.hasEarlierMessages, isFalse);

    gateway.snapshot = DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-coverage-inflight',
      storedSessionId: 'stored-chat',
      created: false,
      messagesProvided: false,
      messageCount: 4,
      inflight: DesktopInflightTurn(
        user: 'turno sintético',
        assistant: 'parcial sintético',
        streaming: true,
      ),
      running: true,
    );
    await chat.loadMessages(expectedMessageCount: 4);

    expect(chat.hasEarlierMessages, isTrue);
  });

  test(
    'backfill offset cero hidrata la cola omitida antes de paginar',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {'id': 1, 'message_id': 'msg-1', 'role': 'user', 'content': 'msg 1'},
        {
          'id': 2,
          'message_id': 'msg-2',
          'role': 'assistant',
          'content': 'msg 2',
        },
      ];
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-tail-before-omission',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
          messageCount: 2,
        );
      final chat = _chat(
        'hydrate-omitted-tail',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      server.healthy = false;
      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-tail-omitted',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 122,
      );
      await chat.loadMessages(expectedMessageCount: 122);
      expect(chat.hasEarlierMessages, isTrue);

      server
        ..healthy = true
        ..paginate = true;
      server.rows
        ..clear()
        ..addAll(_rows(122));
      expect(await chat.loadEarlierMessages(), isTrue);

      expect(chat.messages, hasLength(122));
      expect(chat.messages.first['id'], 122);
      expect(chat.messages.last['id'], 1);
      expect(chat.hasEarlierMessages, isTrue);
      expect(server.requests.last.queryParameters['offset'], '0');
    },
  );

  test(
    'snapshot omitido rehidrata offset cero antes de continuar backfill',
    () async {
      final server = _TranscriptServer(paginate: true)..rows.addAll(_rows(300));
      final gateway = _DeferrableGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-proven-tail',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 300,
        );
      final chat = _chat(
        'preserve-proven-offset',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 300);
      expect(chat.hasEarlierMessages, isTrue);

      server.healthy = false;
      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-proven-tail-omitted',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 400,
      );
      await chat.loadMessages(expectedMessageCount: 400);

      server
        ..healthy = true
        ..rows.addAll(_rows(100, from: 301));
      expect(await chat.loadEarlierMessages(), isTrue);

      expect(server.requests.last.queryParameters['offset'], '0');
      expect(chat.messages.first['id'], 400);
      expect(chat.messages.any((message) => message['id'] == 301), isTrue);
      expect(chat.messages.any((message) => message['id'] == 181), isTrue);

      expect(await chat.loadEarlierMessages(), isTrue);
      expect(server.requests.last.queryParameters['offset'], '120');
      expect(chat.messages.any((message) => message['id'] == 161), isTrue);
    },
  );

  test(
    'resume_progress hidrata aunque ya haya filas inflight sintéticas',
    () async {
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-hydrating-inflight',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 2,
          hydrating: true,
          inflight: DesktopInflightTurn(
            user: 'turno activo mientras hidrata',
            streaming: true,
          ),
          running: true,
        );
      final server = _TranscriptServer(paginate: true)
        ..rows.addAll([
          {'id': 1, 'role': 'user', 'content': 'pregunta durable'},
          {'id': 2, 'role': 'assistant', 'content': 'respuesta durable'},
        ])
        ..healthy = false;
      final chat = _chat(
        'hydrating-inflight',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      expect(chat.messages, isNotEmpty);
      server.healthy = true;
      gateway.emitResumeProgress('complete', messageCount: 2);
      for (var attempt = 0; attempt < 100; attempt++) {
        if (chat.messages.any((message) => message['id'] == 2)) break;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }

      expect(chat.messages.any((message) => message['id'] == 2), isTrue);
      expect(server.requests, hasLength(2));
    },
  );

  test(
    'resume_progress reconstruye el subagente completado desde el transcript',
    () async {
      final initialRows = <Map<String, dynamic>>[
        {'id': 'prior-user', 'role': 'user', 'content': 'turno anterior'},
        {
          'id': 'prior-answer',
          'role': 'assistant',
          'content': 'respuesta anterior',
        },
      ];
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-before-hydrating-subagent',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messageCount: 2,
          messages: initialRows
              .map((row) => DesktopSessionMessage.tryParse(row)!)
              .toList(growable: false),
        );
      final server = _TranscriptServer(paginate: false)
        ..rows.addAll(initialRows);
      final chat = _chat(
        'hydrating-subagent',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);
      server.healthy = false;
      gateway.snapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-hydrating-subagent',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 4,
        hydrating: true,
      );
      await chat.loadMessages(expectedMessageCount: 4);
      server
        ..healthy = true
        ..rows.clear()
        ..rows.addAll([
          {
            'id': 'subagent-user',
            'role': 'user',
            'content': 'delega durante hydration',
          },
          {
            'id': 'subagent-call',
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'call-hydrated',
                'function': {'name': 'delegate_task', 'arguments': '{}'},
              },
            ],
          },
          {
            'id': 'subagent-dispatched',
            'role': 'tool',
            'tool_call_id': 'call-hydrated',
            'tool_name': 'delegate_task',
            'content': jsonEncode({
              'status': 'dispatched',
              'delegation_id': 'deleg_hydrated',
              'subagent_ids': ['sa-hydrated'],
            }),
          },
          {
            'id': 'subagent-complete',
            'role': 'user',
            'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_hydrated]',
            'display_kind': 'async_delegation_complete',
            'display_metadata': jsonEncode({
              'delegation_id': 'deleg_hydrated',
              'task_count': 1,
              'completed_count': 1,
              'failed_count': 0,
            }),
          },
        ]);
      gateway.emitResumeProgress('complete', messageCount: 4);
      SubagentCompletionCardData? completion;
      for (var attempt = 0; attempt < 100; attempt++) {
        final projected = chat.messages
            .map(historicalSubagentCompletionOf)
            .whereType<SubagentCompletionCardData>()
            .toList(growable: false);
        if (projected.isNotEmpty) {
          completion = projected.single;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }

      expect(chat.subagentActivities, isEmpty);
      expect(completion, isNotNull);
      expect(completion?.delegationId, 'deleg_hydrated');
      expect(completion?.subagentIds, ['sa-hydrated']);
      expect(completion?.completedCount, 1);
      expect(completion?.failedCount, 0);
    },
  );

  test(
    'resume diferido: server sin defer_history conserva el path actual',
    () async {
      final gateway = _DeferrableGateway()
        ..snapshot = DesktopSessionSnapshot.fromJson(
          {
            'session_id': 'runtime-legacy',
            'session_key': 'stored-chat',
            'message_count': 2,
            'messages': [
              {'role': 'user', 'content': 'pregunta'},
              {'role': 'assistant', 'content': 'respuesta'},
            ],
          },
          requestedStoredSessionId: 'stored-chat',
          created: false,
          method: 'session.resume',
        );
      final server = _TranscriptServer(paginate: false)..healthy = false;
      final chat = _chat('no-defer', server.client(), gateway: gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);

      expect(gateway.lastDeferHistory, isTrue);
      expect(chat.messagesLoaded, isTrue);
      expect(chat.isHydratingDesktopHistory, isFalse);
      expect(chat.messages, hasLength(2));
      expect(chat.messages.first['content'], 'respuesta');
      expect(chat.messages.last['content'], 'pregunta');
    },
  );

  group('OBJ A SessionMessagesPage evidence transition', () {
    const durableRow = <String, Object?>{
      'message_id': 'obj-a-durable',
      'role': 'user',
      'content': 'fila durable OBJ A',
      'compacted': 1,
      'active': 0,
    };

    DesktopSessionSnapshot completeSnapshot(String runtimeId) =>
        DesktopSessionSnapshot(
          runtimeSessionId: runtimeId,
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: true,
          messages: [DesktopSessionMessage.tryParse(durableRow)!],
          messageCount: 1,
        );

    test(
      'RED invalid empty returned/limit degrades a visible transcript',
      () async {
        final invalidPagination = <({String name, Object pagination})>[
          (
            name: 'returned',
            pagination: const <String, Object?>{
              'limit': 120,
              'offset': 0,
              'returned': '0',
            },
          ),
          (
            name: 'limit',
            pagination: const <String, Object?>{
              'limit': 500,
              'offset': 0,
              'returned': 0,
            },
          ),
        ];
        for (final invalid in invalidPagination) {
          final server = _ControlledTranscriptServer();
          final chat = _chat(
            'obj-a-invalid-empty-${invalid.name}',
            server.client(),
          );
          addTearDown(chat.dispose);

          final initialLoad = chat.loadMessages();
          await server.waitForRequests(1);
          server.completePage(0, const [durableRow]);
          await initialLoad;
          expect(chat.coreReadLineageComplete, isTrue, reason: invalid.name);
          final revisionBeforeInvalid =
              chat.transcriptCoverageRevisionForTesting;

          final invalidLoad = chat.loadMessages();
          await server.waitForRequests(2);
          server.completePage(
            1,
            const <Object?>[],
            pagination: invalid.pagination,
          );
          await invalidLoad;

          expect(chat.messages.map(canonicalTranscriptMessageId), [
            'obj-a-durable',
          ], reason: invalid.name);
          expect(chat.coreReadLineageComplete, isFalse, reason: invalid.name);
          expect(chat.coreReadCoverageIsPartial, isTrue, reason: invalid.name);
          expect(chat.hasEarlierMessages, isTrue, reason: invalid.name);
          expect(
            chat.transcriptCoverageRevisionForTesting,
            revisionBeforeInvalid + 1,
            reason: invalid.name,
          );
          expect(
            chat.transcriptExtentForTesting,
            'partial',
            reason: invalid.name,
          );
          expect(
            chat.transcriptCoverageHasParseGapForTesting,
            isTrue,
            reason: invalid.name,
          );
          expect(
            chat.earlierMessagesNextOffsetForTesting,
            0,
            reason: invalid.name,
          );
          expect(
            chat.needsTranscriptTailHydrationForTesting,
            isTrue,
            reason: invalid.name,
          );
          expect(
            chat.desktopHistoryNeedsHydrationForTesting,
            isTrue,
            reason: invalid.name,
          );

          final recovery = chat.loadEarlierMessages();
          await server.waitForRequests(3);
          expect(
            server.requests[2].url.queryParameters['offset'],
            '0',
            reason: invalid.name,
          );
          server.completePage(2, const [durableRow]);
          expect(await recovery, isTrue, reason: invalid.name);
        }
      },
    );

    test(
      'RED hard expected count precedes preservation of visible rows',
      () async {
        final server = _ControlledTranscriptServer();
        final chat = _chat('obj-a-hard-expected-visible', server.client());
        addTearDown(chat.dispose);
        chat.replaceInternalMessagesForTesting([
          Map<String, dynamic>.from(durableRow),
        ]);
        final revisionBeforeLoad = chat.transcriptCoverageRevisionForTesting;
        var publications = 0;

        final load = chat.loadMessages(
          expectedMessageCount: 1,
          onMessagesPublished: () => publications++,
        );
        await server.waitForRequests(1);
        server.completePage(0, const <Object?>[]);

        await expectLater(load, throwsStateError);
        expect(chat.messagesLoaded, isFalse);
        expect(chat.messages.map(canonicalTranscriptMessageId), [
          'obj-a-durable',
        ]);
        expect(chat.coreReadLineageComplete, isFalse);
        expect(chat.hasEarlierMessages, isTrue);
        expect(publications, 0);
        expect(
          chat.transcriptCoverageRevisionForTesting,
          revisionBeforeLoad + 1,
        );
        expect(chat.transcriptExtentForTesting, 'partial');
        expect(chat.transcriptCoverageHasParseGapForTesting, isTrue);
        expect(chat.earlierMessagesNextOffsetForTesting, 0);
        expect(chat.needsTranscriptTailHydrationForTesting, isTrue);
        expect(chat.desktopHistoryNeedsHydrationForTesting, isTrue);
      },
    );

    test('RED valid empty preserves all prior core evidence', () async {
      final server = _ControlledTranscriptServer();
      final chat = _chat('obj-a-valid-empty-neutral', server.client());
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages();
      await server.waitForRequests(1);
      server.completePage(0, const [durableRow]);
      await initialLoad;
      final identityBefore = chat.coreReadIdentity;
      final coverageBefore = chat.coreReadCoverage;
      final revisionBefore = chat.transcriptCoverageRevisionForTesting;
      final extentBefore = chat.transcriptExtentForTesting;
      final gapBefore = chat.transcriptCoverageHasParseGapForTesting;
      final earlierBefore = chat.hasEarlierMessages;
      final offsetBefore = chat.earlierMessagesNextOffsetForTesting;
      final tailHydrationBefore = chat.needsTranscriptTailHydrationForTesting;
      final desktopHydrationBefore =
          chat.desktopHistoryNeedsHydrationForTesting;
      expect(chat.coreReadLineageComplete, isTrue);

      final emptyRefresh = chat.loadMessages(expectedMessageCount: 0);
      await server.waitForRequests(2);
      server.completePage(1, const <Object?>[]);
      await emptyRefresh;

      expect(chat.messages.map(canonicalTranscriptMessageId), [
        'obj-a-durable',
      ]);
      expect(chat.coreReadIdentity, same(identityBefore));
      expect(chat.coreReadCoverage, same(coverageBefore));
      expect(chat.coreReadCoverage, {CoreReadCoverage.full});
      expect(chat.coreReadLineageComplete, isTrue);
      expect(chat.transcriptCoverageRevisionForTesting, revisionBefore);
      expect(chat.transcriptExtentForTesting, extentBefore);
      expect(chat.transcriptCoverageHasParseGapForTesting, gapBefore);
      expect(chat.hasEarlierMessages, earlierBefore);
      expect(chat.earlierMessagesNextOffsetForTesting, offsetBefore);
      expect(chat.needsTranscriptTailHydrationForTesting, tailHydrationBefore);
      expect(
        chat.desktopHistoryNeedsHydrationForTesting,
        desktopHydrationBefore,
      );
    });

    test('RED stale page cannot mutate core identity or coverage', () async {
      final server = _ControlledTranscriptServer();
      final chat = _chat('obj-a-stale-core', server.client());
      addTearDown(chat.dispose);

      final staleLoad = chat.loadMessages(expectedMessageCount: 1);
      await server.waitForRequests(1);
      final currentLoad = chat.loadMessages(expectedMessageCount: 1);
      await server.waitForRequests(2);
      server.completePage(1, const [durableRow]);
      await currentLoad;

      final identityBeforeStale = chat.coreReadIdentity;
      final coverageBeforeStale = chat.coreReadCoverage;
      final revisionBeforeStale = chat.transcriptCoverageRevisionForTesting;
      final extentBeforeStale = chat.transcriptExtentForTesting;
      final gapBeforeStale = chat.transcriptCoverageHasParseGapForTesting;
      final earlierBeforeStale = chat.hasEarlierMessages;
      final offsetBeforeStale = chat.earlierMessagesNextOffsetForTesting;
      final tailHydrationBeforeStale =
          chat.needsTranscriptTailHydrationForTesting;
      final desktopHydrationBeforeStale =
          chat.desktopHistoryNeedsHydrationForTesting;
      expect(identityBeforeStale.resolvedTipId, 'stored-chat');
      expect(coverageBeforeStale, {CoreReadCoverage.full});
      expect(chat.coreReadLineageComplete, isTrue);

      server.completePage(0, const [
        <String, Object?>{
          'message_id': 'obj-a-stale-row',
          'role': 'assistant',
          'content': 'respuesta obsoleta',
        },
      ], resolvedSessionId: 'obj-a-stale-tip');
      await staleLoad;

      expect(chat.coreReadIdentity, same(identityBeforeStale));
      expect(chat.coreReadCoverage, same(coverageBeforeStale));
      expect(chat.coreReadLineageComplete, isTrue);
      expect(chat.transcriptCoverageRevisionForTesting, revisionBeforeStale);
      expect(chat.transcriptExtentForTesting, extentBeforeStale);
      expect(chat.transcriptCoverageHasParseGapForTesting, gapBeforeStale);
      expect(chat.hasEarlierMessages, earlierBeforeStale);
      expect(chat.earlierMessagesNextOffsetForTesting, offsetBeforeStale);
      expect(
        chat.needsTranscriptTailHydrationForTesting,
        tailHydrationBeforeStale,
      );
      expect(
        chat.desktopHistoryNeedsHydrationForTesting,
        desktopHydrationBeforeStale,
      );
      expect(chat.messages.map(canonicalTranscriptMessageId), [
        'obj-a-durable',
      ]);
    });

    test('disposed page is a no-op and emits no hydration event', () async {
      final server = _ControlledTranscriptServer();
      final chat = _chat('obj-a-disposed-page', server.client());
      final events = <ActiveChatEvent>[];
      final subscription = chat.changes.listen(events.add);

      final load = chat.loadMessages(expectedMessageCount: 1);
      await server.waitForRequests(1);
      chat.dispose();
      final identityAfterDispose = chat.coreReadIdentity;
      final coverageAfterDispose = chat.coreReadCoverage;
      final revisionAfterDispose = chat.transcriptCoverageRevisionForTesting;
      final extentAfterDispose = chat.transcriptExtentForTesting;
      final gapAfterDispose = chat.transcriptCoverageHasParseGapForTesting;
      final earlierAfterDispose = chat.hasEarlierMessages;
      final offsetAfterDispose = chat.earlierMessagesNextOffsetForTesting;
      final tailHydrationAfterDispose =
          chat.needsTranscriptTailHydrationForTesting;
      final desktopHydrationAfterDispose =
          chat.desktopHistoryNeedsHydrationForTesting;
      server.completePage(0, const [durableRow]);
      await load;
      await subscription.cancel();

      expect(chat.coreReadIdentity, same(identityAfterDispose));
      expect(chat.coreReadCoverage, same(coverageAfterDispose));
      expect(chat.transcriptCoverageRevisionForTesting, revisionAfterDispose);
      expect(chat.transcriptExtentForTesting, extentAfterDispose);
      expect(chat.transcriptCoverageHasParseGapForTesting, gapAfterDispose);
      expect(chat.hasEarlierMessages, earlierAfterDispose);
      expect(chat.earlierMessagesNextOffsetForTesting, offsetAfterDispose);
      expect(
        chat.needsTranscriptTailHydrationForTesting,
        tailHydrationAfterDispose,
      );
      expect(
        chat.desktopHistoryNeedsHydrationForTesting,
        desktopHydrationAfterDispose,
      );
      expect(chat.messages, isEmpty);
      expect(chat.messagesLoaded, isFalse);
      expect(events, isEmpty);
    });

    test('stored-session repin makes the received page stale', () async {
      final server = _ControlledTranscriptServer();
      final chat = _chat('obj-a-repinned-page', server.client());
      addTearDown(chat.dispose);
      var publications = 0;

      final load = chat.loadMessages(
        expectedMessageCount: 1,
        onMessagesPublished: () => publications++,
      );
      await server.waitForRequests(1);
      expect(chat.bindKnownStoredSession('stored-chat-repinned'), isTrue);
      final identityAfterRepin = chat.coreReadIdentity;
      final coverageAfterRepin = chat.coreReadCoverage;
      final revisionAfterRepin = chat.transcriptCoverageRevisionForTesting;
      final extentAfterRepin = chat.transcriptExtentForTesting;
      final gapAfterRepin = chat.transcriptCoverageHasParseGapForTesting;
      final offsetAfterRepin = chat.earlierMessagesNextOffsetForTesting;
      final tailHydrationAfterRepin =
          chat.needsTranscriptTailHydrationForTesting;
      final desktopHydrationAfterRepin =
          chat.desktopHistoryNeedsHydrationForTesting;

      server.completePage(0, const [durableRow]);
      await load;

      expect(chat.coreReadIdentity, same(identityAfterRepin));
      expect(chat.coreReadCoverage, same(coverageAfterRepin));
      expect(chat.transcriptCoverageRevisionForTesting, revisionAfterRepin);
      expect(chat.transcriptExtentForTesting, extentAfterRepin);
      expect(chat.transcriptCoverageHasParseGapForTesting, gapAfterRepin);
      expect(chat.earlierMessagesNextOffsetForTesting, offsetAfterRepin);
      expect(
        chat.needsTranscriptTailHydrationForTesting,
        tailHydrationAfterRepin,
      );
      expect(
        chat.desktopHistoryNeedsHydrationForTesting,
        desktopHydrationAfterRepin,
      );
      expect(chat.messages, isEmpty);
      expect(publications, 0);
    });

    test('RED parse gap remains sticky and repairs from offset zero', () async {
      final server = _ControlledTranscriptServer();
      final chat = _chat('obj-a-sticky-gap', server.client());
      addTearDown(chat.dispose);
      final partialTail = <Object?>[
        {...durableRow, 'message_id': 'obj-a-partial-1'},
        for (var index = 2; index < 120; index++)
          {
            'message_id': 'obj-a-partial-$index',
            'role': index.isOdd ? 'user' : 'assistant',
            'content': 'fila parcial $index',
          },
        'fila descartada',
      ];

      final initialLoad = chat.loadMessages(expectedMessageCount: 120);
      await server.waitForRequests(1);
      server.completePage(0, partialTail);
      await initialLoad;
      expect(chat.hasEarlierMessages, isTrue);

      final terminalBackfill = chat.loadEarlierMessages();
      await server.waitForRequests(2);
      expect(server.requests[1].url.queryParameters['offset'], '120');
      server.completePage(1, const [
        <String, Object?>{
          'message_id': 'obj-a-older-row',
          'role': 'assistant',
          'content': 'fila anterior válida',
          'compacted': 1,
          'active': 0,
        },
      ]);
      expect(await terminalBackfill, isFalse);
      expect(chat.coreReadLineageComplete, isFalse);
      expect(chat.hasEarlierMessages, isTrue);

      final repair = chat.loadEarlierMessages();
      await server.waitForRequests(3);
      expect(server.requests[2].url.queryParameters['offset'], '0');
      server.completePage(2, const [durableRow]);
      expect(await repair, isTrue);
      expect(chat.coreReadLineageComplete, isTrue);
      expect(chat.hasEarlierMessages, isFalse);
    });

    test('RED soft announced-count shortfall retries the tail', () async {
      final server = _ControlledTranscriptServer();
      final gateway = _DeferrableGateway()
        ..snapshot = const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-obj-a-soft-shortfall',
          storedSessionId: 'stored-chat',
          created: false,
          messagesProvided: false,
          messageCount: 300,
          hydrating: true,
        );
      final chat = _chat(
        'obj-a-soft-shortfall',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(expectedMessageCount: 300);
      await server.waitForRequests(1);
      server.completePage(0, _rows(120, from: 181));
      await initialLoad;

      final tailHydration = chat.loadEarlierMessages();
      await server.waitForRequests(2);
      expect(server.requests[1].url.queryParameters['offset'], '0');
      server.completePage(1, _rows(120, from: 181));
      expect(await tailHydration, isTrue);

      final shortBackfill = chat.loadEarlierMessages();
      await server.waitForRequests(3);
      expect(server.requests[2].url.queryParameters['offset'], '120');
      server.completePage(2, const [
        <String, Object?>{
          'message_id': 'obj-a-shortfall-row',
          'role': 'user',
          'content': 'cobertura todavía corta',
        },
      ]);
      expect(await shortBackfill, isFalse);
      expect(chat.hasEarlierMessages, isTrue);

      final retry = chat.loadEarlierMessages();
      await server.waitForRequests(4);
      expect(server.requests[3].url.queryParameters['offset'], '0');
      server.completePage(3, _rows(120, from: 181));
      expect(await retry, isTrue);
    });

    test('full positive page remains authoritative', () async {
      final server = _ControlledTranscriptServer();
      final chat = _chat('obj-a-full-positive', server.client());
      addTearDown(chat.dispose);

      final load = chat.loadMessages(expectedMessageCount: 1);
      await server.waitForRequests(1);
      server.completePage(0, const [durableRow]);
      await load;

      expect(chat.messages.map(canonicalTranscriptMessageId), [
        'obj-a-durable',
      ]);
      expect(chat.coreReadCoverage, {CoreReadCoverage.full});
      expect(chat.coreReadCoverageIsPartial, isFalse);
      expect(chat.coreReadLineageComplete, isTrue);
      expect(chat.hasEarlierMessages, isFalse);
    });

    test('RED all-discarded is consumed by compression-fenced load', () async {
      final server = _ControlledTranscriptServer();
      final storage = InMemoryDesktopCompressionFenceStorage();
      final store = DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'obj-a-compression-attempt',
      );
      final chat = _chat(
        'obj-a-compression-consumer',
        server.client(),
        compressionFenceStore: store,
      );
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages();
      await server.waitForRequests(1);
      server.completePage(0, const [durableRow]);
      await initialLoad;
      expect(chat.coreReadLineageComplete, isTrue);

      final now = DateTime.now().millisecondsSinceEpoch;
      expect(
        (await store.arm(
          DesktopCompressionFenceScope(
            connectionId: 'obj-a-compression-consumer',
            profile: 'default',
            logicalSessionId: 'stored-chat',
          ),
          tipAtStart: 'stored-chat',
          compressionsAtStart: 0,
          createdAtMs: now,
          reconcileUntilMs: now + 120000,
        )).claimed,
        isTrue,
      );

      final fencedLoad = chat.loadMessages(expectedMessageCount: 0);
      await server.waitForRequests(2);
      server.completePage(1, const <Object?>['discarded']);
      await fencedLoad;

      expect(chat.messages.map(canonicalTranscriptMessageId), [
        'obj-a-durable',
      ]);
      expect(chat.coreReadLineageComplete, isFalse);
      expect(chat.hasEarlierMessages, isTrue);
    });

    test('RED all-discarded is consumed by lifecycle prefetch', () async {
      final server = _ControlledTranscriptServer();
      final gateway = _DeferrableGateway()
        ..snapshot = completeSnapshot('runtime-obj-a-prefetch');
      final chat = _chat(
        'obj-a-prefetch-consumer',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(expectedMessageCount: 1);
      await server.waitForRequests(1);
      server.completePage(0, const [durableRow]);
      await initialLoad;
      expect(chat.coreReadLineageComplete, isTrue);

      final refresh = chat.loadMessages(expectedMessageCount: 0);
      await server.waitForRequests(2);
      for (var tick = 0; tick < 5; tick++) {
        await Future<void>.delayed(Duration.zero);
      }
      server.completePage(1, const <Object?>['discarded']);
      await refresh;

      expect(chat.messages.map(canonicalTranscriptMessageId), [
        'obj-a-durable',
      ]);
      expect(chat.coreReadLineageComplete, isFalse);
      expect(chat.hasEarlierMessages, isTrue);
    });

    test('RED all-discarded is consumed by resume-progress retry', () async {
      final server = _ControlledTranscriptServer();
      final gateway = _DeferrableGateway()
        ..snapshot = completeSnapshot('runtime-obj-a-resume-initial');
      final chat = _chat(
        'obj-a-resume-retry-consumer',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(expectedMessageCount: 1);
      await server.waitForRequests(1);
      server.completePage(0, const [durableRow]);
      await initialLoad;
      expect(chat.coreReadLineageComplete, isTrue);
      chat.replaceInternalMessagesForTesting(const []);

      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-obj-a-resume-retry',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 1,
        hydrating: true,
      );
      final load = chat.loadMessages(expectedMessageCount: 0);
      await server.waitForRequests(2);
      server.completeError(1);
      for (var tick = 0; tick < 20; tick++) {
        await Future<void>.delayed(Duration.zero);
      }
      gateway.emitResumeProgress('complete', messageCount: 1);
      await server.waitForRequests(3);
      server.completePage(2, const <Object?>['discarded']);

      await expectLater(load, throwsStateError);
      expect(chat.coreReadLineageComplete, isFalse);
      expect(chat.hasEarlierMessages, isTrue);
    });

    test('RED all-discarded is consumed by tail-hydration backfill', () async {
      final server = _ControlledTranscriptServer();
      final gateway = _DeferrableGateway()
        ..snapshot = completeSnapshot('runtime-obj-a-tail-initial');
      final chat = _chat(
        'obj-a-tail-consumer',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(expectedMessageCount: 1);
      await server.waitForRequests(1);
      server.completePage(0, const [durableRow]);
      await initialLoad;
      expect(chat.coreReadLineageComplete, isTrue);

      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-obj-a-tail-retry',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 2,
      );
      final omittedLoad = chat.loadMessages(expectedMessageCount: 2);
      await server.waitForRequests(2);
      server.completeError(1);
      await omittedLoad;
      expect(chat.hasEarlierMessages, isTrue);

      final hydration = chat.loadEarlierMessages();
      await server.waitForRequests(3);
      expect(server.requests[2].url.queryParameters['offset'], '0');
      server.completePage(2, const <Object?>['discarded']);
      expect(await hydration, isFalse);
      expect(chat.coreReadLineageComplete, isFalse);
      expect(chat.messages.map(canonicalTranscriptMessageId), [
        'obj-a-durable',
      ]);
    });

    test('RED all-discarded is consumed by normal backfill', () async {
      final server = _ControlledTranscriptServer();
      final chat = _chat('obj-a-backfill-consumer', server.client());
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(expectedMessageCount: 120);
      await server.waitForRequests(1);
      server.completePage(0, _rows(120));
      await initialLoad;
      expect(chat.hasEarlierMessages, isTrue);

      final discarded = chat.loadEarlierMessages();
      await server.waitForRequests(2);
      expect(server.requests[1].url.queryParameters['offset'], '120');
      server.completePage(1, const <Object?>['discarded']);
      expect(await discarded, isFalse);
      expect(chat.hasEarlierMessages, isTrue);

      final retry = chat.loadEarlierMessages();
      await server.waitForRequests(3);
      expect(server.requests[2].url.queryParameters['offset'], '0');
      server.completePage(2, _rows(120));
      expect(await retry, isTrue);
    });

    test('RED all-discarded is consumed by scheduled hydration', () async {
      final server = _ControlledTranscriptServer();
      final gateway = _DeferrableGateway()
        ..snapshot = completeSnapshot('runtime-obj-a-scheduled-initial');
      final chat = _chat(
        'obj-a-scheduled-consumer',
        server.client(),
        gateway: gateway,
      );
      addTearDown(chat.dispose);

      final initialLoad = chat.loadMessages(expectedMessageCount: 1);
      await server.waitForRequests(1);
      server.completePage(0, const [durableRow]);
      await initialLoad;
      expect(chat.coreReadLineageComplete, isTrue);

      gateway.snapshot = const DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-obj-a-scheduled',
        storedSessionId: 'stored-chat',
        created: false,
        messagesProvided: false,
        messageCount: 2,
        hydrating: true,
      );
      final hydratingLoad = chat.loadMessages(expectedMessageCount: 2);
      await server.waitForRequests(2);
      server.completeError(1);
      await hydratingLoad;

      gateway.emitResumeProgress('complete', messageCount: 2);
      await server.waitForRequests(3);
      server.completePage(2, const <Object?>['discarded']);
      for (var tick = 0; tick < 20; tick++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(chat.coreReadLineageComplete, isFalse);
      expect(chat.messages.map(canonicalTranscriptMessageId), [
        'obj-a-durable',
      ]);
      expect(chat.hasEarlierMessages, isTrue);
    });

    test('RED all-discarded is consumed by cancelled-anchor repair', () async {
      var discardPages = false;
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        if (!request.url.path.endsWith('/messages')) {
          return http.Response(
            jsonEncode(const <String, Object?>{}),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        final rows = discardPages
            ? const <Object?>['discarded']
            : const <Object?>[durableRow];
        return http.Response(
          jsonEncode({
            'object': 'list',
            'session_id': 'stored-chat',
            'messages': rows,
            'pagination': {'limit': 120, 'offset': 0, 'returned': rows.length},
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final gateway = _DeferrableGateway()
        ..snapshot = completeSnapshot('runtime-obj-a-anchor');
      final recorded = <CancelledTurnTombstone>[];
      final chat = _chat(
        'obj-a-anchor-consumer',
        client,
        gateway: gateway,
        onCancelledTurn: (tombstone) async => recorded.add(tombstone),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 1);
      expect(chat.coreReadLineageComplete, isTrue);
      expect(
        await chat.send(
          fullText: 'turno cancelado OBJ A',
          model: 'hermes-agent',
          history: chat.buildHistory(),
        ),
        isTrue,
      );
      await chat.cancel();
      gateway.emit(
        'message.complete',
        payload: const {'text': 'Operation interrupted.'},
      );
      for (var tick = 0; tick < 20; tick++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(recorded, isNotEmpty);
      expect(
        chat.messages.any(
          (message) =>
              message['content'] == 'turno cancelado OBJ A' &&
              message['_cancelledUser'] == true &&
              canonicalTranscriptMessageId(message) == null &&
              canonicalTranscriptRowId(message) == null,
        ),
        isTrue,
      );

      discardPages = true;
      final accepted = await chat.send(
        fullText: 'turno posterior al Stop',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );

      // La reparación sigue intentándose y consume su página, pero ya no puede
      // secuestrar la sesión: un Stop correcto no deja el chat inservible.
      expect(accepted, isTrue);
      expect(chat.coreReadLineageComplete, isFalse);
      expect(chat.hasEarlierMessages, isTrue);
      expect(
        chat.messages.any(
          (message) => message['content'] == 'turno posterior al Stop',
        ),
        isTrue,
      );
      expect(requests.where((uri) => uri.path.endsWith('/messages')).length, 2);

      // La ambigüedad que esto protegía sigue cerrada donde toca: el tombstone
      // del turno nuevo no se puede anclar cruzando la fila detenida sin
      // identidad, así que Stop falla de forma visible y reintentable.
      await expectLater(chat.cancel(), throwsA(isA<StateError>()));
      expect(chat.stopConfirmationState, StopConfirmationState.failed);
    });
  });
}
