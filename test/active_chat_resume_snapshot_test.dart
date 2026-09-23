import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_compression_result.dart';
import 'package:hermes_android/core/models/desktop_compression_outcome.dart';
import 'package:hermes_android/core/models/desktop_context_breakdown.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/models/session_activity.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/chat_render_projection.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/desktop_compression_fence_store.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/services/subagent_transcript_projection.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryCompressionFenceStorage implements DesktopCompressionFenceStorage {
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
        HermesDesktopContextUsageGateway {
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

class _NativeCompressionGateway extends _SnapshotGateway
    implements HermesDesktopCompressionGateway {
  int compressSessionCalls = 0;
  String? compressRuntimeId;
  String? compressFocusTopic;
  Object? compressError;
  Completer<DesktopCompressionResult>? nativeCompressionGate;
  Map<String, dynamic>? compressionWireResult;
  late DesktopCompressionResult compressionResult;
  final compressionEntered = Completer<void>();

  @override
  Future<DesktopCompressionResult> compressSession(
    String runtimeSessionId, {
    String focusTopic = '',
  }) async {
    compressSessionCalls += 1;
    if (!compressionEntered.isCompleted) compressionEntered.complete();
    compressRuntimeId = runtimeSessionId;
    compressFocusTopic = focusTopic;
    if (compressError case final error?) throw error;
    final wire = compressionWireResult;
    return nativeCompressionGate?.future ??
        (wire == null
            ? compressionResult
            : DesktopCompressionResult.fromJson(wire));
  }
}

class _ReplayProbeGateway extends _SnapshotGateway
    implements HermesDesktopCompressionStatusGateway {
  _ReplayProbeGateway(this.replay);

  Map<String, dynamic> Function() replay;
  final replayRuntimeIds = <String>[];

  @override
  Future<Map<String, dynamic>> compressionEventReplay(
    String runtimeSessionId,
  ) async {
    replayRuntimeIds.add(runtimeSessionId);
    return replay();
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

DesktopSessionSnapshot _snapshot(Map<String, dynamic> json) =>
    DesktopSessionSnapshot.fromJson(
      json,
      requestedStoredSessionId: 'stored-chat',
      created: false,
      method: 'session.resume',
    );

DesktopSessionSnapshot _compressedSnapshot() => _snapshot({
  'session_id': 'runtime-compress',
  'session_key': 'stored-compressed',
  'info': {
    'stored_session_id': 'stored-compressed',
    'model': 'openai/gpt-5.5-codex',
    'usage': {'context_used': 3500, 'context_max': 200000},
  },
  'messages': [
    {'role': 'user', 'content': 'Resumen durable'},
    {'role': 'assistant', 'content': 'Contexto listo'},
  ],
});

DesktopCompressionResult _nativeCompressionResult() =>
    DesktopCompressionResult.fromJson({
      'status': 'compressed',
      'removed': 2,
      'before_messages': 4,
      'after_messages': 2,
      'before_tokens': 96022,
      'after_tokens': 4821,
      'summary': {
        'noop': false,
        'headline': 'Compressed: 4 → 2 messages',
        'token_line': 'Approx request size: ~96,022 → ~4,821 tokens',
      },
      'usage': {'context_used': 4821, 'context_max': 200000},
      'info': {
        'stored_session_id': 'stored-native-compressed',
        'model': 'openai/gpt-5.5-codex',
        'usage': {'context_used': 4821, 'context_max': 200000},
      },
      'messages': [
        {'role': 'user', 'content': 'Resumen nativo durable'},
        {'role': 'assistant', 'content': 'Contexto nativo listo'},
      ],
    });

DesktopCompressionResult _nativeAbortedCompressionResult() =>
    DesktopCompressionResult.fromJson({
      'status': 'aborted',
      'removed': 0,
      'before_messages': 4,
      'after_messages': 4,
      'before_tokens': 96022,
      'after_tokens': 96022,
      'summary': {
        'aborted': true,
        'headline': 'Compression aborted: authoritative transcript preserved',
      },
      'info': {'stored_session_id': 'stored-native-aborted'},
      'messages': [
        {'role': 'user', 'content': 'Resumen previo'},
        {'role': 'assistant', 'content': 'Estado abortado autoritativo'},
        {'role': 'user', 'content': 'Pregunta conservada'},
        {'role': 'assistant', 'content': 'Respuesta conservada'},
      ],
    });

DesktopCompressionResult _nativePendingCompressionResult() =>
    DesktopCompressionResult.fromJson({
      'status': 'pending',
      'turn_isolation': true,
      'message': 'compression still running in the background',
    });

DesktopCompressionResult _nativeLockHeldCompressionResult() =>
    DesktopCompressionResult.fromJson({
      'compressed': false,
      'lock_held': true,
      'message': 'private holder metadata must not reach Console',
    });

DesktopCompressionFenceStore _lockHeldFenceStore(
  _MemoryCompressionFenceStorage storage,
  String attemptId,
) => DesktopCompressionFenceStore(storage: storage, attemptId: () => attemptId);

_NativeCompressionGateway _lockHeldGateway(String runtimeId) =>
    _NativeCompressionGateway()
      ..snapshot = _snapshot({
        'session_id': runtimeId,
        'session_key': 'stored-chat',
        'messages': <Object>[],
      })
      ..compressionResult = _nativeLockHeldCompressionResult();

final _lockHeldBusy = throwsA(
  isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
);

ActiveChat _chat(
  String id,
  _SnapshotGateway gateway, {
  http.Client? client,
  String? logicalSessionId,
  String sessionId = 'stored-chat',
  StoredSessionMessageLoader? storedMessageLoader,
  bool allowUnownedDesktopSnapshotForTesting = true,
  Duration desktopCompressionReconciliationDelay = const Duration(seconds: 20),
  Duration desktopCompressionReconciliationWindow = const Duration(minutes: 12),
  List<SteerProjection> initialSteerProjections = const [],
  List<CancelledTurnTombstone> initialCancelledTurnTombstones = const [],
  Future<void> Function(CancelledTurnTombstone)? onCancelledTurn,
  DesktopCompressionFenceStore? compressionFenceStore,
  int Function()? wallClockMs,
  void Function(ActiveChatEvent)? onEvent,
}) => ActiveChat(
  connection: _connection(id),
  sessionId: sessionId,
  logicalSessionId: logicalSessionId,
  sessionTitle: 'Snapshot',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    apiKey: 'test-key',
    httpClient:
        client ??
        MockClient((_) async => http.Response('unexpected REST', 500)),
  ),
  desktopGateway: gateway,
  compressionFenceStore:
      compressionFenceStore ??
      DesktopCompressionFenceStore(storage: _MemoryCompressionFenceStorage()),
  wallClockMs: wallClockMs,
  storedMessageLoader: storedMessageLoader,
  allowUnownedDesktopSnapshotForTesting: allowUnownedDesktopSnapshotForTesting,
  desktopCompressionReconciliationDelay: desktopCompressionReconciliationDelay,
  desktopCompressionReconciliationWindow:
      desktopCompressionReconciliationWindow,
  initialSteerProjections: initialSteerProjections,
  initialCancelledTurnTombstones: initialCancelledTurnTombstones,
  onCancelledTurn: onCancelledTurn,
  onEvent: onEvent,
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

  test('confirmed cleanup clears only the exact fence scope', () async {
    final storage = _MemoryCompressionFenceStorage();
    final store = DesktopCompressionFenceStore(
      storage: storage,
      attemptId: () => 'cleanup-attempt',
    );
    final scope = DesktopCompressionFenceScope(
      connectionId: 'conn-a',
      profile: 'main',
      logicalSessionId: 'root-a',
    );
    expect(
      (await store.arm(
        scope,
        tipAtStart: 'tip-a',
        compressionsAtStart: null,
        createdAtMs: 1,
        reconcileUntilMs: 2,
      )).claimed,
      isTrue,
    );
    final service = ActiveChatService(compressionFenceStore: store);

    await service.clearCompressionFenceForSession(
      connectionId: 'conn-a',
      profile: 'main',
      logicalSessionId: 'root-a',
    );

    expect(
      (await store.lookup(scope)).status,
      DesktopCompressionFenceLookupStatus.absent,
    );
  });

  test(
    'snapshot publica solo narración y tarjetas públicas allowlisted',
    () async {
      const reasoningMarker = 'DURABLE_SNAPSHOT_REASONING';
      const privateMarker = 'PRIVATE_SNAPSHOT_OWNER_PID_991_/home/private';
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-private-snapshot',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'Pregunta pública', 'row_id': 1},
            {
              'role': 'assistant',
              'content': '<think>$privateMarker</think>Respuesta pública.',
              'reasoning': reasoningMarker,
              'reasoning_content': 'IGNORED_REASONING_FALLBACK',
              'reasoning_details': [
                {'text': privateMarker},
              ],
              'trace': privateMarker,
              'owner_pid': 991,
              'path': '/home/private',
              'tool_calls': [
                {
                  'id': 'call-private',
                  'function': {
                    'name': 'shell',
                    'arguments': '{"command":"$privateMarker"}',
                  },
                },
              ],
            },
            {
              'role': 'tool',
              'tool_call_id': 'call-private',
              'tool_name': 'shell',
              'content': '{"output":"$privateMarker"}',
            },
            {'role': 'analysis', 'content': privateMarker},
            {
              'role': 'user',
              'content': '[ASYNC DELEGATION BATCH COMPLETE — deleg_deadbeef]',
              'display_kind': 'async_delegation_complete',
              'display_metadata': {
                'delegation_id': 'deleg_deadbeef',
                'task_count': 1,
                'completed_count': 1,
                'failed_count': 0,
                'subagent_ids': ['sa-safe'],
                'goal': privateMarker,
                'owner_pid': 991,
                'path': '/home/private',
              },
            },
          ],
        });
      final chat = _chat('private-snapshot', gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages();

      expect(chat.messages.map((message) => message['content']), [
        '[ASYNC DELEGATION BATCH COMPLETE — deleg_deadbeef]',
        'Respuesta pública.',
        'Pregunta pública',
      ]);
      final assistant = chat.messages.singleWhere(
        (message) => message['role'] == 'assistant',
      );
      expect(assistant['reasoning'], reasoningMarker);
      expect(chat.messages.toString(), isNot(contains(privateMarker)));
      expect(chat.messages.toString(), isNot(contains('/home/private')));
      expect(
        chat.messages.toString(),
        isNot(contains('IGNORED_REASONING_FALLBACK')),
      );
      expect(
        chat.messages.where((message) => message['role'] == 'tool'),
        isEmpty,
      );
      for (final message in chat.messages) {
        expect(message['content'].toString(), isNot(contains(reasoningMarker)));
        for (final entry in message.entries) {
          if (identical(message, assistant) &&
              (entry.key == 'reasoning' ||
                  entry.key == assistantActivityTraceKey)) {
            continue;
          }
          expect(
            entry.value.toString(),
            isNot(contains(reasoningMarker)),
            reason: entry.key,
          );
        }
      }
      for (final forbidden in const [
        'reasoning_content',
        'reasoning_details',
        'tool_calls',
        'tool_name',
        'tool_call_id',
        'analysis',
        'trace',
        'owner_pid',
        'path',
      ]) {
        expect(
          chat.messages.any((message) => message.containsKey(forbidden)),
          isFalse,
          reason: forbidden,
        );
      }
      expect(chat.messages.first['display_metadata'], {
        'delegation_id': 'deleg_deadbeef',
        'task_count': 1,
        'completed_count': 1,
        'failed_count': 0,
        'subagent_ids': ['sa-safe'],
      });
    },
  );

  test('REST publica narración sin roles ni metadata privados', () async {
    const reasoningMarker = 'DURABLE_REST_REASONING';
    const privateMarker = 'PRIVATE_REST_TRACE_/srv/hermes/session.jsonl';
    final gateway = _SnapshotGateway()
      ..resumeExistingError = const TuiGatewayRpcError(
        'session.resume',
        'not found',
        code: 4007,
      );
    final chat = _chat(
      'private-rest',
      gateway,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': [
              {'id': 1, 'role': 'user', 'content': 'Pregunta REST pública'},
              {
                'id': 2,
                'role': 'assistant',
                'content':
                    '<think>$privateMarker</think>Respuesta REST pública.',
                'reasoning': reasoningMarker,
                'reasoning_details': [
                  {'text': privateMarker},
                ],
                'analysis': privateMarker,
                'trace': privateMarker,
                'owner_pid': 744,
                'tool_calls': [
                  {
                    'id': 'rest-call-private',
                    'function': {
                      'name': 'terminal',
                      'arguments': '{"path":"$privateMarker"}',
                    },
                  },
                ],
              },
              {
                'id': 3,
                'role': 'tool',
                'tool_call_id': 'rest-call-private',
                'content': privateMarker,
              },
              {'id': 4, 'role': 'analysis', 'content': privateMarker},
            ],
          }),
          200,
        ),
      ),
    );
    addTearDown(chat.dispose);

    await chat.loadMessages();

    expect(chat.messages.map((message) => message['content']), [
      'Respuesta REST pública.',
      'Pregunta REST pública',
    ]);
    final assistant = chat.messages.singleWhere(
      (message) => message['role'] == 'assistant',
    );
    expect(assistant['reasoning'], reasoningMarker);
    expect(chat.messages.toString(), isNot(contains(privateMarker)));
    expect(
      chat.messages.any(
        (message) =>
            message['role'] == 'tool' || message.containsKey('tool_calls'),
      ),
      isFalse,
    );
    for (final message in chat.messages) {
      expect(message['content'].toString(), isNot(contains(reasoningMarker)));
      for (final entry in message.entries) {
        if (identical(message, assistant) &&
            (entry.key == 'reasoning' ||
                entry.key == assistantActivityTraceKey)) {
          continue;
        }
        expect(
          entry.value.toString(),
          isNot(contains(reasoningMarker)),
          reason: entry.key,
        );
      }
    }
    for (final forbidden in const [
      'reasoning_content',
      'reasoning_details',
      'tool_calls',
      'tool_name',
      'tool_call_id',
      'analysis',
      'trace',
      'owner_pid',
    ]) {
      expect(
        chat.messages.any((message) => message.containsKey(forbidden)),
        isFalse,
        reason: forbidden,
      );
    }
  });

  test(
    'visible service cold open attaches the exact durable session by default',
    () async {
      final gateway = _SnapshotGateway()
        ..activeSessionList = const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-advertised',
              storedSessionId: 'stored-chat',
            ),
          ],
        )
        ..snapshot = _snapshot({
          'session_id': 'runtime-advertised',
          'session_key': 'stored-chat',
          'messages': const <Map<String, dynamic>>[
            {'role': 'user', 'content': 'pregunta durable'},
            {'role': 'assistant', 'content': 'respuesta durable'},
          ],
        });
      final service = ActiveChatService(
        compressionFenceStore: DesktopCompressionFenceStore(
          storage: _MemoryCompressionFenceStorage(),
        ),
      );
      addTearDown(service.dispose);
      final chat = service.attach(
        connection: _connection('native-cold-open'),
        sessionId: 'stored-chat',
        sessionTitle: 'Sesión compartida',
        desktopGateway: gateway,
        storedMessageLoader: (_, _) async => const <Map<String, dynamic>>[
          {'role': 'user', 'content': 'pregunta durable'},
          {'role': 'assistant', 'content': 'respuesta durable'},
        ],
        disableForegroundKeepAlive: true,
      );

      await chat.loadMessages(profile: 'default');

      expect(gateway.listActiveCalls, 1);
      expect(gateway.activateCalls, 1);
      expect(gateway.resumeExistingCalls, 0);
      expect(gateway.createCalls, 0);
      expect(chat.desktopRuntimeSessionId, 'runtime-advertised');
      expect(chat.storedSessionId, 'stored-chat');
    },
  );

  test(
    'visible cold open rejects a mismatched runtime before projection',
    () async {
      const privateMarker = 'FOREIGN_RUNTIME_PRIVATE_MARKER';
      final gateway = _SnapshotGateway()
        ..activeSessionList = const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-advertised',
              storedSessionId: 'stored-chat',
            ),
          ],
        )
        ..snapshot = _snapshot({
          'session_id': 'runtime-foreign',
          'session_key': 'stored-chat',
          'messages': const <Map<String, dynamic>>[
            {'role': 'assistant', 'content': privateMarker},
          ],
        });
      final service = ActiveChatService(
        compressionFenceStore: DesktopCompressionFenceStore(
          storage: _MemoryCompressionFenceStorage(),
        ),
      );
      addTearDown(service.dispose);
      final chat = service.attach(
        connection: _connection('native-runtime-mismatch'),
        sessionId: 'stored-chat',
        sessionTitle: 'Sesión compartida',
        desktopGateway: gateway,
        storedMessageLoader: (_, _) async => const <Map<String, dynamic>>[
          {'role': 'assistant', 'content': 'historial durable correcto'},
        ],
        disableForegroundKeepAlive: true,
      );

      await chat.loadMessages(profile: 'default');

      expect(gateway.listActiveCalls, 1);
      expect(gateway.activateCalls, 1);
      expect(gateway.resumeExistingCalls, 0);
      expect(chat.desktopRuntimeSessionId, isNull);
      expect(chat.messages.toString(), isNot(contains(privateMarker)));
      expect(chat.messages.single['content'], 'historial durable correcto');
      expect(gateway.submitPromptCalls, 0);
      expect(gateway.createCalls, 0);
    },
  );

  test(
    'visible cold open rejects a mismatched durable snapshot before projection',
    () async {
      const privateMarker = 'FOREIGN_SESSION_PRIVATE_MARKER';
      final gateway = _SnapshotGateway()
        ..activeSessionList = const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-advertised',
              storedSessionId: 'stored-chat',
            ),
          ],
        )
        ..snapshot = _snapshot({
          'session_id': 'runtime-foreign',
          'session_key': 'different-stored-session',
          'messages': const <Map<String, dynamic>>[
            {'role': 'assistant', 'content': privateMarker},
          ],
        });
      final service = ActiveChatService(
        compressionFenceStore: DesktopCompressionFenceStore(
          storage: _MemoryCompressionFenceStorage(),
        ),
      );
      addTearDown(service.dispose);
      final chat = service.attach(
        connection: _connection('native-mismatch'),
        sessionId: 'stored-chat',
        sessionTitle: 'Sesión compartida',
        desktopGateway: gateway,
        storedMessageLoader: (_, _) async => const <Map<String, dynamic>>[
          {'role': 'assistant', 'content': 'historial durable correcto'},
        ],
        disableForegroundKeepAlive: true,
      );

      await chat.loadMessages(profile: 'default');

      expect(gateway.listActiveCalls, 1);
      expect(gateway.activateCalls, 1);
      expect(gateway.resumeExistingCalls, 0);
      expect(chat.desktopRuntimeSessionId, isNull);
      expect(chat.storedSessionId, isNot('different-stored-session'));
      expect(chat.messages.toString(), isNot(contains(privateMarker)));
      expect(chat.messages.single['content'], 'historial durable correcto');
      expect(gateway.submitPromptCalls, 0);
      expect(gateway.createCalls, 0);
    },
  );

  test(
    'visible cold open rejects untrusted resume identity evidence',
    () async {
      final cases = <String, DesktopSessionSnapshot>{
        'created': DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-created',
            'session_key': 'stored-chat',
            'messages': <Object>[],
          },
          requestedStoredSessionId: 'stored-chat',
          created: true,
          method: 'session.resume',
        ),
        'contradictory aliases': DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-aliases',
            'stored_session_id': 'stored-chat',
            'session_key': 'different-stored-session',
            'messages': <Object>[],
          },
          requestedStoredSessionId: 'stored-chat',
          created: false,
          method: 'session.resume',
        ),
        'foreign lineage': DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-lineage',
            'session_key': 'stored-chat',
            'lineage_root_id': 'foreign-root',
            'messages': <Object>[],
          },
          requestedStoredSessionId: 'stored-chat',
          created: false,
          method: 'session.resume',
        ),
      };

      for (final entry in cases.entries) {
        final gateway = _SnapshotGateway()..snapshot = entry.value;
        final service = ActiveChatService(
          compressionFenceStore: DesktopCompressionFenceStore(
            storage: _MemoryCompressionFenceStorage(),
          ),
        );
        final chat = service.attach(
          connection: _connection('native-untrusted-${entry.key}'),
          sessionId: 'stored-chat',
          logicalSessionId: 'stored-chat',
          sessionTitle: 'Sesión compartida',
          desktopGateway: gateway,
          storedMessageLoader: (_, _) async => const <Map<String, dynamic>>[
            {'role': 'assistant', 'content': 'historial durable correcto'},
          ],
          disableForegroundKeepAlive: true,
        );

        await chat.loadMessages(profile: 'default');

        expect(chat.desktopRuntimeSessionId, isNull, reason: entry.key);
        expect(chat.messages.single['content'], 'historial durable correcto');
        expect(gateway.submitPromptCalls, 0, reason: entry.key);
        expect(gateway.createCalls, 0, reason: entry.key);
        service.dispose();
      }
    },
  );

  test(
    'explicit passive cold open publishes REST without acquiring a runtime',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-must-not-bind',
          'session_key': 'stored-chat',
          'messages': const <Map<String, dynamic>>[
            {'role': 'user', 'content': 'pregunta durable'},
            {'role': 'assistant', 'content': 'respuesta durable'},
          ],
        });
      final chat = _chat(
        'passive-cold-open',
        gateway,
        storedMessageLoader: (_, _) async => const <Map<String, dynamic>>[
          {'role': 'user', 'content': 'pregunta durable'},
          {'role': 'assistant', 'content': 'respuesta durable'},
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(passiveOnly: true);

      expect(gateway.resumeExistingCalls, 0);
      expect(gateway.resumeLegacyCalls, 0);
      expect(gateway.createCalls, 0);
      expect(chat.desktopRuntimeSessionId, isNull);
      expect(chat.coreReadIdentity.logicalRootId, 'stored-chat');
      expect(chat.coreReadIdentity.storedId, 'stored-chat');
      expect(chat.coreReadIdentity.runtimeId, isNull);
      expect(chat.messagesLoaded, isTrue);
      expect(chat.messages.map((message) => message['content']), [
        'respuesta durable',
        'pregunta durable',
      ]);
    },
  );

  test(
    'passiveOnly publica REST aunque el bypass de snapshot este habilitado',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-must-not-bind',
          'session_key': 'stored-chat',
          'inflight': {'user': 'no debe proyectarse', 'streaming': true},
          'running': true,
        });
      final chat = _chat(
        'passive-rest-only',
        gateway,
        storedMessageLoader: (_, _) async => const [
          {
            'id': 41,
            'message_id': 'rest-only-user',
            'role': 'user',
            'content': 'historial REST',
          },
        ],
        allowUnownedDesktopSnapshotForTesting: true,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(passiveOnly: true);

      expect(gateway.resumeExistingCalls, 0);
      expect(gateway.resumeLegacyCalls, 0);
      expect(gateway.createCalls, 0);
      expect(chat.desktopRuntimeSessionId, isNull);
      expect(chat.messages.single['content'], 'historial REST');
    },
  );

  test('invalidar una lectura pasiva descarta su respuesta tardia', () async {
    final lateRead = Completer<List<Map<String, dynamic>>>();
    var loads = 0;
    final chat = _chat(
      'passive-late-result',
      _SnapshotGateway(),
      storedMessageLoader: (_, _) {
        loads += 1;
        if (loads == 1) {
          return Future.value(const [
            {
              'id': 51,
              'message_id': 'visible-before-background',
              'role': 'user',
              'content': 'visible antes de background',
            },
          ]);
        }
        return lateRead.future;
      },
      allowUnownedDesktopSnapshotForTesting: false,
    );
    addTearDown(chat.dispose);
    await chat.loadMessages();

    final pending = chat.loadMessages(passiveOnly: true);
    await Future<void>.delayed(Duration.zero);
    expect(loads, 2);
    chat.invalidatePassiveRead();
    lateRead.complete(const [
      {
        'id': 52,
        'message_id': 'late-after-background',
        'role': 'assistant',
        'content': 'no debe publicarse',
      },
    ]);
    await pending;

    expect(chat.messages.map((message) => message['content']), [
      'visible antes de background',
    ]);
    expect(chat.hasRecentPassiveRemoteActivity, isFalse);
  });

  test(
    'cold open structurally suppresses the first inflight user twin',
    () async {
      const prompt = 'prompt actual repetido';
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-live-user',
          'session_key': 'stored-chat',
          'turn_started_at': 100.0,
          'inflight': {
            'user': prompt,
            'assistant': 'parcial vivo',
            'streaming': true,
          },
          'running': true,
          'status': 'working',
        });
      final chat = _chat(
        'rest-inflight-same-turn',
        gateway,
        storedMessageLoader: (_, _) async => const [
          {
            'id': 298292,
            'message_id': 'durable-current-user',
            'role': 'user',
            'content': prompt,
            'timestamp': 101.0,
          },
          {
            'id': 298293,
            'message_id': 'durable-current-reasoning',
            'role': 'assistant',
            'content': '',
            'reasoning': 'Voy a consultar el estado.',
            'tool_calls': [
              {
                'id': 'durable-current-tool-call',
                'function': {'name': 'shell', 'arguments': '{}'},
              },
            ],
          },
          {
            'id': 298294,
            'message_id': 'durable-current-tool-result',
            'role': 'tool',
            'tool_call_id': 'durable-current-tool-call',
            'content': 'todavía trabajando',
          },
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      final users = chat.messages
          .where((message) => message['role'] == 'user')
          .toList(growable: false);
      expect(users, hasLength(1));
      expect(users.single['content'], prompt);
      expect(users.single['id'], 298292);
      expect(
        chat.messages.where((message) => message['role'] == 'assistant'),
        contains(
          predicate<Map<String, dynamic>>(
            (message) => message['content'] == 'parcial vivo',
          ),
        ),
      );
    },
  );

  test(
    'cold open suppresses the inflight user twin when the REST assistant row has no identity',
    () async {
      // Shape measured on a real device: `session.history` returns the user
      // row with only a numeric id and the tool-call assistant row with no id
      // and no message_id at all.
      const prompt = 'prompt actual sin identidad en el asistente';
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-live-noid',
          'session_key': 'stored-chat',
          'turn_started_at': 100.0,
          'inflight': {'user': prompt, 'streaming': true},
          'running': true,
          'status': 'working',
        });
      final chat = _chat(
        'rest-inflight-assistant-without-identity',
        gateway,
        storedMessageLoader: (_, _) async => const [
          {'id': 401, 'role': 'user', 'content': prompt, 'timestamp': 101.0},
          {
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'call-without-row-identity',
                'function': {'name': 'terminal', 'arguments': '{}'},
              },
            ],
          },
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      final users = chat.messages
          .where((message) => message['role'] == 'user')
          .toList(growable: false);
      expect(users, hasLength(1), reason: 'one bubble for the open first turn');
      expect(users.single['content'], prompt);
    },
  );

  test('warm REST suffix uses the exact previous anchor once', () async {
    const prompt = 'prompt actual con anchor';
    var includeCurrent = false;
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-warm-anchor',
        'session_key': 'stored-chat',
        'messages_omitted': true,
        'running': false,
        'status': 'idle',
      });
    final chat = _chat(
      'rest-inflight-warm-anchor',
      gateway,
      storedMessageLoader: (_, _) async {
        return [
          const {
            'id': 101,
            'message_id': 'previous-user',
            'role': 'user',
            'content': 'pregunta previa',
            'timestamp': 98.0,
          },
          const {
            'id': 102,
            'message_id': 'previous-final',
            'role': 'assistant',
            'content': 'respuesta previa',
            'timestamp': 99.0,
          },
          if (includeCurrent)
            const {
              'id': 103,
              'message_id': 'durable-current-user',
              'role': 'user',
              'content': prompt,
              'timestamp': 101.0,
            },
        ];
      },
    );
    addTearDown(chat.dispose);

    await chat.loadMessages();
    includeCurrent = true;
    gateway.snapshot = _snapshot({
      'session_id': 'runtime-warm-anchor',
      'session_key': 'stored-chat',
      'turn_started_at': 100.0,
      'inflight': {
        'user': prompt,
        'assistant': 'parcial vivo',
        'streaming': true,
      },
      'running': true,
      'status': 'working',
    });

    await chat.loadMessages();

    final currentUsers = chat.messages
        .where(
          (message) =>
              message['role'] == 'user' && message['content'] == prompt,
        )
        .toList(growable: false);
    expect(currentUsers, hasLength(1));
    expect(currentUsers.single['id'], 103);
    expect(currentUsers.single['_desktopSnapshotKind'], isNot('inflight'));
  });

  test('loadMessages aplica resume 0.19 con inflight, queued e info', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-live',
        'session_key': 'stored-chat',
        'messages': [
          {'role': 'user', 'text': 'anterior'},
          {'role': 'assistant', 'text': 'hecho'},
        ],
        'inflight': {
          'user': 'actual',
          'assistant': 'parcial',
          'streaming': true,
        },
        'queued': {'user': 'después'},
        'running': true,
        'status': 'working',
        'started_at': 1784542500,
        'info': {
          'title': 'Título autoritativo',
          'model': 'gpt-5.5',
          'provider': 'openai-codex',
          'usage': {'context_used': 500, 'context_max': 1000},
        },
      });
    final chat = _chat('resume-live', gateway);
    addTearDown(chat.dispose);

    await chat.loadMessages();

    expect(gateway.resumeExistingCalls, 1);
    expect(gateway.resumeLegacyCalls, 0);
    expect(gateway.createCalls, 0);
    expect(chat.messagesLoaded, isTrue);
    expect(chat.messages.first['content'], 'parcial');
    expect(chat.queuedMessages, ['después']);
    expect(chat.state, ChatPipelineState.streaming);
    expect(chat.storedSessionId, 'stored-chat');
    expect(chat.serverSessionId, 'stored-chat');
    expect(chat.sessionTitle, 'Título autoritativo');
    expect(chat.desktopRuntimeInfo.model, 'gpt-5.5');
    expect(chat.desktopLiveStatus, 'working');
    expect(chat.desktopStartedAt, isNotNull);
    // `snapshot.started_at` pertenece al runtime y no debe falsear el reloj
    // del turno si el inflight no trae un inicio propio.
    expect(chat.desktopTurnStartedAt, isNull);
  });

  test(
    'loadMessages adopta turn_started_at top-level del Gateway real',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-top-level-turn',
          'session_key': 'stored-chat',
          'messages': <Object>[],
          'running': true,
          'turn_started_at': 100.25,
          'inflight': {
            'user': 'turno vivo',
            'assistant': '',
            'streaming': true,
          },
        });
      final chat = _chat('resume-top-level-turn', gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages();

      expect(
        chat.desktopTurnStartedAt,
        DateTime.fromMillisecondsSinceEpoch(100250, isUtc: true),
      );
    },
  );

  test('default runtime warmup never resumes a stored session', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-must-not-warm',
        'session_key': 'stored-chat',
        'messages': <Object>[],
      });
    final chat = _chat(
      'passive-runtime-warmup',
      gateway,
      allowUnownedDesktopSnapshotForTesting: false,
    );
    addTearDown(chat.dispose);

    expect(await chat.ensureDesktopRuntime(), isFalse);
    expect(gateway.resumeExistingCalls, 0);
    expect(gateway.resumeLegacyCalls, 0);
    expect(gateway.createCalls, 0);
    expect(chat.desktopRuntimeSessionId, isNull);
  });

  test(
    'compacted transcript rehydrates completion card on every reopen',
    () async {
      MockClient client() => MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'data': [
                {
                  'message_id': 'compacted-marker',
                  'role': 'user',
                  'content':
                      '[ASYNC DELEGATION BATCH COMPLETE — deleg_c0ffee12]',
                  'display_kind': 'async_delegation_complete',
                  'display_metadata': {
                    'delegation_id': 'deleg_c0ffee12',
                    'task_count': 1,
                    'completed_count': 1,
                    'failed_count': 0,
                    'subagent_ids': ['sa-compacted-one'],
                  },
                },
              ],
            }),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      );

      for (var reopen = 0; reopen < 2; reopen++) {
        final chat = _chat(
          'compacted-reopen-$reopen',
          _SnapshotGateway(),
          allowUnownedDesktopSnapshotForTesting: false,
          client: client(),
        );
        await chat.loadMessages();

        final cards = chat.messages
            .map(historicalSubagentCompletionOf)
            .whereType<SubagentCompletionCardData>()
            .toList(growable: false);
        expect(cards, hasLength(1));
        expect(cards.single.subagentIds, ['sa-compacted-one']);
        expect(chat.subagentActivities, isEmpty);
        chat.dispose();
      }
    },
  );

  test(
    'warm loadMessages stays passive after an explicitly acquired runtime',
    () async {
      final gateway = _SnapshotGateway()
        ..createSnapshot = DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-warm-passive',
            'session_key': 'stored-warm-passive',
            'messages': <Object>[],
          },
          requestedStoredSessionId: '',
          created: true,
          method: 'session.create',
        )
        ..snapshot = DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-warm-passive',
            'session_key': 'stored-warm-passive',
            'messages': <Object>[],
          },
          requestedStoredSessionId: 'stored-warm-passive',
          created: false,
          method: 'session.resume',
        );
      final chat = _chat(
        'warm-passive-refresh',
        gateway,
        sessionId: 'mob-warm-passive',
        allowUnownedDesktopSnapshotForTesting: false,
        storedMessageLoader: (_, _) async => const [
          {'id': 1, 'role': 'user', 'content': 'durable'},
        ],
      );
      addTearDown(chat.dispose);
      chat.markStoredSessionMissing();

      expect(
        await chat.send(
          fullText: 'turno explícito',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      final resumesAfterExplicitSubmit = gateway.resumeExistingCalls;

      await chat.loadMessages(expectedMessageCount: 1);

      expect(gateway.resumeExistingCalls, resumesAfterExplicitSubmit);
      expect(
        chat.messages.where((message) => message['content'] == 'durable'),
        hasLength(1),
      );
    },
  );

  test(
    'test-only snapshot seam never authorizes passive runtime acquisition',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-test-seam-must-not-bind',
          'session_key': 'stored-chat',
          'messages': <Object>[],
        });
      final chat = _chat('passive-test-seam', gateway);
      addTearDown(chat.dispose);

      expect(await chat.ensureDesktopRuntime(), isFalse);
      expect(gateway.resumeExistingCalls, 0);
      expect(gateway.resumeLegacyCalls, 0);
      expect(gateway.createCalls, 0);
      expect(chat.desktopRuntimeSessionId, isNull);
    },
  );

  test('ensureDesktopRuntime adopta turn_started_at top-level', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-ensure-top-level-turn',
        'session_key': 'stored-chat',
        'messages': <Object>[],
        'running': true,
        'turn_started_at': 200.5,
        'inflight': {'user': 'turno vivo', 'assistant': '', 'streaming': true},
      });
    final chat = _chat('ensure-top-level-turn', gateway);
    addTearDown(chat.dispose);

    expect(
      await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
      isTrue,
    );
    expect(
      chat.desktopTurnStartedAt,
      DateTime.fromMillisecondsSinceEpoch(200500, isUtc: true),
    );
  });

  test('explicit cold-open compression acquires one runtime', () async {
    final gateway = _NativeCompressionGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-explicit-compress',
        'session_key': 'stored-chat',
        'messages': <Object>[],
      })
      ..compressionResult = _nativeCompressionResult();
    final chat = _chat(
      'explicit-cold-compress',
      gateway,
      allowUnownedDesktopSnapshotForTesting: false,
      storedMessageLoader: (_, _) async => const <Map<String, dynamic>>[],
    );
    addTearDown(chat.dispose);

    final result = await chat.compressDesktopSession();

    expect(result.accepted, DesktopCommandAcceptance.accepted);
    expect(gateway.resumeExistingCalls, 1);
    expect(gateway.createCalls, 0);
    expect(gateway.compressSessionCalls, 1);
    expect(gateway.compressRuntimeId, 'runtime-explicit-compress');
  });

  test('durable arm write failure sends zero compression RPCs', () async {
    final storage = _MemoryCompressionFenceStorage()..failingWrites = {1};
    final gateway = _NativeCompressionGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-arm-write-failure',
        'session_key': 'stored-chat',
        'messages': <Object>[],
      })
      ..compressionResult = _nativeCompressionResult();
    final chat = _chat(
      'arm-write-failure',
      gateway,
      compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
    );
    addTearDown(chat.dispose);
    await chat.loadMessages();

    await expectLater(
      chat.compressDesktopSession(),
      throwsA(
        isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
      ),
    );

    expect(gateway.compressSessionCalls, 0);
    expect(gateway.slashExecCalls, 0);
    expect(gateway.commandDispatchCalls, 0);
  });

  test('legacy snapshot alone cannot resolve its durable attempt', () async {
    final storage = _MemoryCompressionFenceStorage();
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-legacy-clear',
        'session_key': 'stored-chat',
        'messages': <Object>[],
      })
      ..snapshotAfterCommand = _compressedSnapshot();
    final chat = _chat(
      'legacy-clear',
      gateway,
      compressionFenceStore: DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'legacy-clear-attempt',
      ),
    );
    addTearDown(chat.dispose);
    await chat.loadMessages();

    await chat.compressDesktopSession();

    final lookup = await DesktopCompressionFenceStore(storage: storage).lookup(
      DesktopCompressionFenceScope(
        connectionId: 'legacy-clear',
        profile: 'default',
        logicalSessionId: 'stored-chat',
      ),
    );
    expect(lookup.status, DesktopCompressionFenceLookupStatus.present);
  });

  test(
    'resume conserva un inflight nuevo que repite texto histórico',
    () async {
      const history = [
        {
          'id': 203187,
          'role': 'user',
          'content': 'continue',
          'timestamp': 1789167000.0,
        },
        {
          'id': 203188,
          'role': 'assistant',
          'content': 'turn finished',
          'finish_reason': 'stop',
        },
      ];
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-repeated-inflight',
          'session_key': 'stored-chat',
          'message_count': history.length,
          'messages': history,
          'inflight': {'user': 'continue', 'assistant': '', 'streaming': true},
          'running': true,
          'status': 'working',
        });
      final chat = _chat(
        'repeated-inflight',
        gateway,
        storedMessageLoader: (_, _) async => history,
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: history.length);

      expect(
        chat.messages.where(
          (message) =>
              message['role'] == 'user' && message['content'] == 'continue',
        ),
        hasLength(2),
      );
    },
  );

  test(
    'messages_omitted vacío sin contador conserva completitud desconocida',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-omitted-empty',
          'session_key': 'stored-chat',
          'messages': <Object>[],
          'messages_omitted': true,
        });
      final chat = _chat('resume-omitted-empty', gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages();

      expect(chat.messages, isEmpty);
      expect(chat.hasEarlierMessages, isTrue);
    },
  );

  test(
    'fallo real al cargar página anterior queda marcado para recuperación UI',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-omitted-failure',
          'session_key': 'stored-chat',
          'messages': <Object>[],
          'messages_omitted': true,
        });
      final chat = _chat('resume-omitted-failure', gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages();
      expect(chat.hasEarlierMessages, isTrue);
      expect(chat.earlierMessagesLoadFailed, isFalse);

      expect(await chat.loadEarlierMessages(), isFalse);
      expect(chat.earlierMessagesLoadFailed, isTrue);
    },
  );

  test(
    'recovery rechaza inicios de turno contradictorios sin fallback previo',
    () async {
      const toolTail = <Map<String, dynamic>>[
        {
          'message_id': 'conflicting-turn-user',
          'role': 'user',
          'content': 'continúa el trabajo',
        },
        {
          'message_id': 'conflicting-turn-call',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'conflicting-turn-tool-call',
              'function': {'name': 'status', 'arguments': '{}'},
            },
          ],
        },
        {
          'message_id': 'conflicting-turn-result',
          'role': 'tool',
          'tool_call_id': 'conflicting-turn-tool-call',
          'content': 'trabajo parcial',
        },
      ];
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-conflicting-recovery-turn',
          'session_key': 'stored-chat',
          'messages': toolTail,
          'running': true,
          'turn_started_at': 300,
          'inflight': {
            'user': 'continúa el trabajo',
            'assistant': '',
            'streaming': true,
            'started_at': 301,
          },
        });
      final chat = _chat(
        'recovery-conflicting-turn',
        gateway,
        storedMessageLoader: (_, _) async => toolTail,
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = toolTail.reversed
          .map(Map<String, dynamic>.of)
          .toList(growable: false);
      chat.messagesLoaded = true;
      chat.state = ChatPipelineState.completed;

      expect(await chat.reconcileAfterResume(), isTrue);
      expect(chat.desktopTurnStartedAt, isNull);
    },
  );

  test(
    'reconexión conserva redirected y queued sin pérdida ni duplicado',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-reconnect-corrections',
          'session_key': 'stored-chat',
          // Desktop mantiene el turno vivo en `inflight`; no publica además
          // una fila durable sin ID para que Console la fusione por texto.
          'messages': <Map<String, dynamic>>[],
          'inflight': {
            'user': 'haz la auditoría',
            'corrections': ['y documéntala'],
            'assistant': 'trabajando',
            'streaming': true,
          },
          'queued': {'user': 'después publícala'},
          'running': true,
        });
      final chat = _chat(
        'resume-corrections',
        gateway,
        initialSteerProjections: const [
          (anchorUserOrdinal: 0, content: 'y documéntala'),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();
      final firstProjection = chat.messages
          .map(Map<String, dynamic>.from)
          .toList(growable: false);
      await chat.loadMessages();

      expect(chat.messages, firstProjection);
      expect(chat.messages.reversed.map((message) => message['content']), [
        'haz la auditoría',
        'trabajando',
        'y documéntala',
      ]);
      expect(
        chat.messages.where((message) => message['_steer'] == true),
        hasLength(1),
      );
      expect(chat.queuedMessages, ['después publícala']);
    },
  );

  test(
    'merge local conserva el offset autoritativo de la corrección',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-correction-offset-merge',
          'session_key': 'stored-chat',
          'messages': <Map<String, dynamic>>[],
          'inflight': {
            'user': 'avanza',
            'assistant': 'Moving.Still.',
            'streaming': true,
            'corrections': ['más rápido'],
            'correction_offsets': [7],
          },
          'running': true,
        });
      final chat = _chat(
        'resume-correction-offset-merge',
        gateway,
        initialSteerProjections: const [
          (anchorUserOrdinal: 0, content: 'más rápido'),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      expect(chat.messages.reversed.map((message) => message['content']), [
        'avanza',
        'Moving.',
        'más rápido',
        'Still.',
      ]);
      expect(
        chat.messages.where((message) => message['content'] == 'más rápido'),
        hasLength(1),
      );
    },
  );

  test(
    'deduplicación de corrección autoritativa respeta el turno ancla',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-correction-scope',
          'session_key': 'stored-chat',
          'message_count': 7,
          'messages': [
            {'role': 'user', 'content': 'primer turno'},
            {'role': 'assistant', 'content': 'Cerrado.'},
            {'role': 'user', 'content': 'segundo turno'},
            {
              'role': 'user',
              'content': 'cambio interno',
              'display_kind': 'model_switch',
            },
          ],
          'inflight': {
            'assistant': 'Moving.Still.',
            'streaming': true,
            'corrections': ['igual'],
            'correction_offsets': [7],
          },
          'running': true,
        });
      final chat = _chat(
        'resume-correction-scope',
        gateway,
        initialSteerProjections: const [
          (anchorUserOrdinal: 0, content: 'igual'),
          (anchorUserOrdinal: 1, content: 'igual'),
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      expect(chat.messages.reversed.map((message) => message['content']), [
        'primer turno',
        'igual',
        'Cerrado.',
        'segundo turno',
        'cambio interno',
        'Moving.',
        'igual',
        'Still.',
      ]);
      expect(
        chat.messages.where((message) => message['content'] == 'igual'),
        hasLength(2),
      );
    },
  );

  test(
    'prefetch REST pinta antes de resume y un snapshot vacío no lo borra',
    () async {
      final resumeGate = Completer<DesktopSessionSnapshot>();
      final gateway = _SnapshotGateway()..resumeGate = resumeGate;
      final chat = _chat(
        'resume-prefetch',
        gateway,
        client: MockClient(
          (_) async => http.Response(
            '{"data":[{"role":"user","content":"hola"},'
            '{"role":"assistant","content":"historial REST"}]}',
            200,
          ),
        ),
      );
      addTearDown(chat.dispose);
      final events = <ActiveChatEvent>[];
      final subscription = chat.changes.listen(events.add);
      addTearDown(subscription.cancel);
      var finished = false;

      final loading = chat
          .loadMessages(expectedMessageCount: 2)
          .whenComplete(() => finished = true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(finished, isFalse);
      expect(chat.messagesLoaded, isTrue);
      expect(chat.assistantContent, 'historial REST');
      expect(events, contains(ActiveChatEvent.messagesHydrated));
      // El owner RPC es explícito, pero el perfil principal conserva el
      // transporte Gateway en vez de depender de credenciales Dashboard.
      expect(gateway.lastResumeProfile, 'default');
      // REST carga antes el contenido, pero no conserva metadata editorial;
      // una sesión no vacía debe pedir el transcript completo al Gateway.
      expect(gateway.lastResumeOmitMessages, isFalse);

      resumeGate.complete(
        _snapshot({
          'session_id': 'runtime-prefetch',
          'session_key': 'stored-chat',
          'message_count': 2,
          'messages': <Object>[],
          'messages_omitted': true,
        }),
      );
      await loading;

      expect(chat.assistantContent, 'historial REST');
      expect(chat.messages, hasLength(2));
      expect(chat.hasDesktopRuntime, isTrue);
      expect(gateway.lastResumeOmitMessages, isFalse);
    },
  );

  test('sesión no vacía rechaza REST y resume vacíos', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-empty',
        'session_key': 'stored-chat',
        'message_count': 2,
        'messages': <Object>[],
      });
    final chat = _chat(
      'resume-empty-guard',
      gateway,
      client: MockClient((_) async => http.Response('{"data":[]}', 200)),
    );
    addTearDown(chat.dispose);

    await expectLater(
      chat.loadMessages(expectedMessageCount: 2),
      throwsA(isA<StateError>()),
    );

    expect(chat.messages, isEmpty);
    expect(chat.messagesLoaded, isFalse);
    expect(gateway.lastResumeOmitMessages, isFalse);
  });

  test(
    'resume rápido pinta sin esperar a REST y REST conserva precedencia final',
    () async {
      final restGate = Completer<List<Map<String, dynamic>>>();
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-fast-resume',
          'session_key': 'stored-chat',
          'message_count': 2,
          'messages': [
            {'role': 'user', 'content': 'hola desde resume'},
            {'role': 'assistant', 'content': 'snapshot rápido'},
          ],
        });
      final chat = _chat(
        'resume-first',
        gateway,
        storedMessageLoader: (_, _) => restGate.future,
      );
      addTearDown(chat.dispose);
      final hydrated = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.messagesHydrated,
      );
      var finished = false;

      final loading = chat
          .loadMessages(expectedMessageCount: 2)
          .whenComplete(() => finished = true);
      await hydrated.timeout(const Duration(seconds: 1));

      expect(finished, isFalse);
      expect(chat.assistantContent, 'snapshot rápido');
      expect(gateway.lastResumeOmitMessages, isFalse);

      restGate.complete([
        {'role': 'user', 'content': 'hola desde REST'},
        {'role': 'assistant', 'content': 'REST autoritativo'},
      ]);
      await loading;

      expect(chat.assistantContent, 'REST autoritativo');
      expect(chat.messages, hasLength(2));
      expect(gateway.resumeExistingCalls, 1);
    },
  );

  test(
    'REST conserva su contenido y resume aporta metadata editorial durable',
    () async {
      const raw = '[ASYNC DELEGATION BATCH COMPLETE — deleg_real]';
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-display-metadata',
          'session_key': 'stored-chat',
          'message_count': 2,
          'messages': [
            {
              'message_id': 'deleg-real-user',
              'role': 'user',
              'content': raw,
              'display_kind': 'async_delegation_complete',
              'display_metadata': {
                'task_count': 2,
                'completed_count': 2,
                'failed_count': 0,
                'duration_seconds': 18,
              },
            },
            {
              'message_id': 'deleg-real-answer',
              'role': 'assistant',
              'content': 'Respuesta snapshot',
            },
          ],
        })
        // El Gateway real cumple omit_messages: no devuelve precisamente la
        // metadata editorial que REST omite. El fake debe respetar el contrato
        // para que la prueba pueda detectar el muro ASYNC DELEGATION.
        ..omittedSnapshot = _snapshot({
          'session_id': 'runtime-display-metadata',
          'session_key': 'stored-chat',
          'message_count': 2,
          'messages': <Object>[],
          'messages_omitted': true,
        });
      final chat = _chat(
        'resume-display-metadata',
        gateway,
        storedMessageLoader: (_, _) async => [
          {'message_id': 'deleg-real-user', 'role': 'user', 'content': raw},
          {
            'message_id': 'deleg-real-answer',
            'role': 'assistant',
            'content': 'Respuesta REST autoritativa',
          },
        ],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 2);

      expect(
        gateway.lastResumeOmitMessages,
        isFalse,
        reason:
            'REST no conserva display_kind/display_metadata; session.resume debe '
            'entregar el transcript editorial aunque el prefetch ya haya acabado',
      );
      expect(chat.assistantContent, 'Respuesta REST autoritativa');
      final event = chat.messages.singleWhere(
        (message) => message['content'] == raw,
      );
      expect(event['display_kind'], 'async_delegation_complete');
      expect(event['display_metadata'], {
        'task_count': 2,
        'completed_count': 2,
        'failed_count': 0,
        'duration_seconds': 18,
      });
      final projection = ChatRenderProjection.build(chat.messages);
      expect(projection.visibleUserCount, 0);
      expect(projection.units.last, isA<ChatMessageUnitPlan>());
    },
  );

  test(
    'sesión existente con contador desconocido no omite historial',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-unknown-count',
          'session_key': 'stored-chat',
          'message_count': 2,
          'messages': [
            {'role': 'user', 'content': 'Pregunta recuperada'},
            {'role': 'assistant', 'content': 'Respuesta recuperada'},
          ],
        })
        ..omittedSnapshot = _snapshot({
          'session_id': 'runtime-unknown-count',
          'session_key': 'stored-chat',
          'message_count': 2,
          'messages': <Object>[],
          'messages_omitted': true,
        });
      final chat = _chat(
        'resume-unknown-count',
        gateway,
        storedMessageLoader: (_, _) async => <Map<String, dynamic>>[],
      );
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 0);

      expect(gateway.lastResumeOmitMessages, isFalse);
      expect(gateway.lastResumeDeferHistory, isTrue);
      expect(
        chat.messages.map((message) => message['content']),
        containsAll(['Pregunta recuperada', 'Respuesta recuperada']),
      );
    },
  );

  test('REST repara marker editorial mientras resume 0.20 hidrata', () async {
    const raw = '[ASYNC DELEGATION BATCH COMPLETE — deleg_0d84d484]';
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-display-deferred',
        'session_key': 'stored-chat',
        'message_count': 2,
        'messages': [
          {
            'role': 'user',
            'content': raw,
            'display_kind': 'async_delegation_complete',
          },
          {'role': 'assistant', 'content': 'Respuesta snapshot'},
        ],
      })
      ..deferredSnapshot = _snapshot({
        'session_id': 'runtime-display-deferred',
        'session_key': 'stored-chat',
        'message_count': 2,
        'hydrating': true,
        'messages': <Object>[],
      });
    final chat = _chat(
      'resume-display-deferred',
      gateway,
      storedMessageLoader: (_, _) async => [
        {'role': 'user', 'content': raw},
        {'role': 'assistant', 'content': 'Respuesta REST autoritativa'},
      ],
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 2);

    expect(gateway.lastResumeDeferHistory, isTrue);
    final event = chat.messages.singleWhere(
      (message) => message['content'] == raw,
    );
    expect(event['display_kind'], 'async_delegation_complete');
    expect(event['display_metadata'], isNull);
    final projection = ChatRenderProjection.build(chat.messages);
    expect(projection.visibleUserCount, 0);
    expect(projection.units.last, isA<ChatMessageUnitPlan>());
  });

  test('perfil llega tanto a Dashboard REST como a session.resume', () async {
    final requestedProfiles = <String>[];
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-profile',
        'session_key': 'stored-chat',
        'message_count': 2,
        'messages': <Object>[],
      });
    final chat = _chat(
      'resume-profile',
      gateway,
      storedMessageLoader: (sessionId, profile) async {
        expect(sessionId, 'stored-chat');
        requestedProfiles.add(profile);
        return [
          {'role': 'user', 'content': 'perfil'},
          {'role': 'assistant', 'content': 'aislado'},
        ];
      },
    );
    addTearDown(chat.dispose);

    await chat.loadMessages(expectedMessageCount: 2, profile: 'research');

    expect(gateway.lastResumeProfile, 'research');
    expect(requestedProfiles, ['research']);

    chat.internalMessagesForTesting = [
      {'role': 'assistant', 'content': '', '_pipeline': true},
      {'role': 'user', 'content': 'perfil'},
    ];
    expect(await chat.reconcileAfterResume(), isTrue);
    expect(requestedProfiles, ['research', 'research']);
  });

  test('storedSessionId no cruza perfiles por un alias coincidente', () async {
    final service = ActiveChatService();
    final connection = _connection('profile-alias');
    final firstGateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-profile-a',
        'session_key': 'shared-stored-id',
        'info': {'lineage_root_id': 'mobile-profile-a'},
        'messages': <Object>[],
      });
    final first = service.attach(
      connection: connection,
      sessionId: 'mobile-profile-a',
      sessionTitle: 'Perfil A',
      sessionProfile: 'profile-a',
      desktopGateway: firstGateway,
      storedMessageLoader: (_, _) async => <Map<String, dynamic>>[],
    );

    expect(
      await first.ensureDesktopRuntime(acquireForExplicitAction: true),
      isTrue,
    );
    await first.loadMessages(profile: 'profile-a');
    expect(first.storedSessionId, 'shared-stored-id');

    final second = service.attach(
      connection: connection,
      sessionId: 'shared-stored-id',
      sessionTitle: 'Perfil B',
      sessionProfile: 'profile-b',
      desktopGateway: _SnapshotGateway(),
      storedMessageLoader: (_, _) async => <Map<String, dynamic>>[],
    );

    expect(second, isNot(same(first)));
    expect(second.sessionProfile, 'profile-b');
    expect(
      service.of(connection.id, 'shared-stored-id', profile: 'profile-a'),
      same(first),
    );
    expect(
      service.of(connection.id, 'shared-stored-id', profile: 'profile-b'),
      same(second),
    );
    expect(service.of(connection.id, 'shared-stored-id'), isNull);
    service.dispose();
  });

  test(
    'borrador móvil no hace lecturas y el primer submit crea sin resume',
    () async {
      var restReads = 0;
      final gateway = _SnapshotGateway()
        ..createSnapshot = DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-created',
            'session_key': 'stored-created',
            'messages': <Object>[],
          },
          requestedStoredSessionId: '',
          created: true,
          method: 'session.create',
        );
      final chat = _chat(
        'mobile-draft',
        gateway,
        sessionId: 'mob-123-test',
        storedMessageLoader: (_, _) async {
          restReads += 1;
          return const [];
        },
      );
      addTearDown(chat.dispose);

      chat.markStoredSessionMissing();
      await chat.loadMessages();

      expect(restReads, 0);
      expect(gateway.resumeExistingCalls, 0);
      expect(gateway.resumeLegacyCalls, 0);

      final accepted = await chat.send(
        fullText: 'primer mensaje',
        model: 'hermes-agent',
        history: const [],
      );

      expect(accepted, isTrue);
      expect(gateway.createCalls, 1);
      expect(gateway.resumeExistingCalls, 0);
      expect(gateway.resumeLegacyCalls, 0);
      expect(chat.storedSessionId, 'stored-created');
      expect(chat.storedSessionKnownMissing, isFalse);
    },
  );

  test('dos cargas fuera de orden no dejan aterrizar la más antigua', () async {
    final resumeFirst = Completer<DesktopSessionSnapshot>();
    final resumeSecond = Completer<DesktopSessionSnapshot>();
    final restFirst = Completer<List<Map<String, dynamic>>>();
    final restSecond = Completer<List<Map<String, dynamic>>>();
    var restCalls = 0;
    final gateway = _SnapshotGateway()
      ..resumeGates.addAll([resumeFirst, resumeSecond])
      ..resumeEntered = Completer<void>();
    final chat = _chat(
      'resume-epoch',
      gateway,
      storedMessageLoader: (_, _) {
        restCalls += 1;
        return restCalls == 1 ? restFirst.future : restSecond.future;
      },
    );
    addTearDown(chat.dispose);

    final oldLoad = chat.loadMessages(expectedMessageCount: 2);
    await gateway.resumeEntered!.future;
    gateway.resumeEntered = Completer<void>();
    final newLoad = chat.loadMessages(expectedMessageCount: 2);
    await gateway.resumeEntered!.future;

    resumeSecond.complete(
      _snapshot({
        'session_id': 'runtime-new',
        'session_key': 'stored-chat',
        'message_count': 2,
        'messages': <Object>[],
      }),
    );
    restSecond.complete([
      {'role': 'user', 'content': 'nuevo prompt'},
      {'role': 'assistant', 'content': 'nuevo resultado'},
    ]);
    await newLoad;

    resumeFirst.complete(
      _snapshot({
        'session_id': 'runtime-old',
        'session_key': 'stored-chat',
        'message_count': 2,
        'messages': <Object>[],
      }),
    );
    restFirst.complete([
      {'role': 'user', 'content': 'viejo prompt'},
      {'role': 'assistant', 'content': 'viejo resultado'},
    ]);
    await oldLoad;

    expect(chat.assistantContent, 'nuevo resultado');
    expect(chat.messages, hasLength(2));
  });

  test(
    'la reparación local conserva junta la pareja usuario y error',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-error-pair',
          'session_key': 'stored-chat',
          'message_count': 2,
          'messages': <Object>[],
        });
      final chat = _chat(
        'resume-error-pair',
        gateway,
        storedMessageLoader: (_, _) async => [
          {'role': 'user', 'content': 'turno anterior'},
          {'role': 'assistant', 'content': 'respuesta anterior'},
        ],
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = [
        {
          'role': 'assistant_error',
          'content': 'sin conexión',
          '_prompt': 'mensaje sin persistir',
        },
        {'role': 'user', 'content': 'mensaje sin persistir'},
      ];

      await chat.loadMessages(expectedMessageCount: 2);

      expect(chat.messages[0]['role'], 'assistant_error');
      expect(chat.messages[1]['role'], 'user');
      expect(chat.messages[1]['content'], 'mensaje sin persistir');
      expect(
        chat.messages.where(
          (message) => message['content'] == 'mensaje sin persistir',
        ),
        hasLength(1),
      );
    },
  );

  test('resume retenido fallido deja el chat terminal y recuperable', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-retained-failure',
        'session_key': 'stored-chat',
        'messages': <Object>[],
        'running': false,
        'status': 'idle',
        'inflight': {
          'user': 'haz la tarea',
          'assistant': 'respuesta parcial',
          'streaming': false,
          'error': 'StateError: /home/private-user/secret failed: 500',
          'status': 'error',
          'recoverable': true,
        },
      });
    final chat = _chat(
      'resume-retained-failure',
      gateway,
      client: MockClient((_) async => http.Response('{"data":[]}', 200)),
    );
    addTearDown(chat.dispose);

    await chat.loadMessages();

    expect(chat.state, ChatPipelineState.failed);
    expect(chat.isStreaming, isFalse);
    expect(chat.messages.map((message) => message['role']), [
      'assistant_error',
      'assistant',
      'user',
    ]);
    expect(
      chat.messages.first['content'],
      'No se pudo recuperar el turno. Inténtalo de nuevo.',
    );
    expect(
      chat.messages.first['content'],
      isNot(contains('/home/private-user')),
    );
    expect(chat.messages.first['error'], isNot(contains('/home/private-user')));
    expect(chat.messages.first['recoverable'], isTrue);
    expect(chat.messages[1]['content'], 'respuesta parcial');
    expect(chat.messages[1]['_cancelled'], isTrue);
  });

  test(
    'reanudación recupera un turno durable tras agotar la ventana offline',
    () async {
      final gateway = _SnapshotGateway();
      final chat = _chat(
        'resume-after-offline-budget',
        gateway,
        storedMessageLoader: (_, _) async => [
          {'role': 'user', 'content': 'espera y responde'},
          {'role': 'assistant', 'content': 'respuesta durable final'},
        ],
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = [
        {
          'role': 'assistant_error',
          'content': 'No se pudo recuperar el turno. Inténtalo de nuevo.',
          '_prompt': 'espera y responde',
          '_awaitingDurableTurnRecovery': true,
        },
        {'role': 'user', 'content': 'espera y responde'},
      ];
      chat.messagesLoaded = true;
      chat.state = ChatPipelineState.failed;

      final changed = await chat.reconcileAfterResume();

      expect(changed, isTrue);
      expect(chat.state, ChatPipelineState.completed);
      expect(chat.messages.first['role'], 'assistant');
      expect(chat.messages.first['content'], 'respuesta durable final');
      expect(
        chat.messages.where((message) => message['role'] == 'assistant_error'),
        isEmpty,
      );
    },
  );

  test(
    'reanudación de app no sustituye el turno local por REST vacío',
    () async {
      final gateway = _SnapshotGateway();
      final chat = _chat(
        'resume-app-empty',
        gateway,
        client: MockClient((_) async => http.Response('{"data":[]}', 200)),
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {'role': 'user', 'content': 'conservar esta conversación'},
      ];
      final before = chat.messages;

      final changed = await chat.reconcileAfterResume();

      expect(changed, isFalse);
      expect(chat.messages, same(before));
      expect(chat.messages, hasLength(2));
    },
  );

  test(
    'cold open converges from roster absence to one durable final refresh',
    () async {
      const toolTail = <Map<String, dynamic>>[
        {
          'message_id': 'roster-final-user',
          'role': 'user',
          'content': 'espera el resultado',
        },
        {
          'message_id': 'roster-final-reasoning',
          'role': 'assistant',
          'content': '',
          'reasoning': 'Esperando el proceso.',
          'tool_calls': [
            {
              'id': 'roster-final-call',
              'function': {'name': 'shell', 'arguments': '{}'},
            },
          ],
        },
        {
          'message_id': 'roster-final-tool',
          'role': 'tool',
          'tool_call_id': 'roster-final-call',
          'content': 'proceso iniciado',
        },
      ];
      var durableTranscript = toolTail;
      var transcriptReads = 0;
      final gateway = _SnapshotGateway()
        ..activitySupported = true
        ..activeSessionList = const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-roster-final',
              storedSessionId: 'stored-chat',
              status: 'working',
            ),
          ],
        )
        ..snapshot = _snapshot({
          'session_id': 'runtime-roster-final',
          'session_key': 'stored-chat',
          'messages': toolTail,
          'turn_started_at': 100.0,
          'inflight': {
            'user': 'espera el resultado',
            'assistant': '',
            'streaming': true,
          },
          'running': true,
          'status': 'working',
        });
      final chat = _chat(
        'roster-final-refresh',
        gateway,
        storedMessageLoader: (_, _) async {
          transcriptReads += 1;
          return durableTranscript;
        },
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();
      expect(chat.isStreaming, isTrue);
      await chat.refreshPassiveRemoteActivity();

      durableTranscript = const [
        ...toolTail,
        {
          'message_id': 'roster-final-assistant',
          'role': 'assistant',
          'content': 'resultado durable final',
        },
      ];
      gateway.activeSessionList = const DesktopActiveSessionList();
      await chat.refreshPassiveRemoteActivity();
      expect(chat.isStreaming, isTrue);
      await chat.refreshPassiveRemoteActivity();

      expect(chat.state, ChatPipelineState.completed);
      expect(chat.isStreaming, isFalse);
      expect(chat.assistantContent, 'resultado durable final');
      expect(transcriptReads, 2);
    },
  );

  test(
    'failed cold resume settles from durable final and authoritative absence',
    () async {
      const toolTail = <Map<String, dynamic>>[
        {
          'message_id': 'unbound-final-user',
          'role': 'user',
          'content': 'continúa aunque cierre la app',
        },
        {
          'message_id': 'unbound-final-reasoning',
          'role': 'assistant',
          'content': '',
          'reasoning': 'Trabajo en curso.',
          'tool_calls': [
            {
              'id': 'unbound-final-call',
              'function': {'name': 'shell', 'arguments': '{}'},
            },
          ],
        },
        {
          'message_id': 'unbound-final-tool',
          'role': 'tool',
          'tool_call_id': 'unbound-final-call',
          'content': 'proceso iniciado',
        },
      ];
      var durableTranscript = toolTail;
      var transcriptReads = 0;
      final gateway = _SnapshotGateway()
        ..activitySupported = true
        ..activeSessionList = const DesktopActiveSessionList()
        ..resumeExistingError = StateError('core read unavailable');
      final chat = _chat(
        'unbound-final-refresh',
        gateway,
        storedMessageLoader: (_, _) async {
          transcriptReads += 1;
          return durableTranscript;
        },
      );
      addTearDown(chat.dispose);
      chat.state = ChatPipelineState.connecting;

      await chat.loadMessages();
      expect(chat.desktopRuntimeSessionId, isNull);
      expect(chat.isStreaming, isTrue);

      durableTranscript = const [
        ...toolTail,
        {
          'message_id': 'unbound-final-assistant',
          'role': 'assistant',
          'content': 'la app volvió y el turno terminó',
        },
      ];
      await chat.refreshPassiveRemoteActivity();
      expect(chat.isStreaming, isTrue);
      await chat.refreshPassiveRemoteActivity();

      expect(chat.state, ChatPipelineState.completed);
      expect(chat.isStreaming, isFalse);
      expect(chat.assistantContent, 'la app volvió y el turno terminó');
      expect(transcriptReads, 2);
      expect(gateway.listActiveCalls, 2);
    },
  );

  test(
    'reapertura tras tools reatacha el runtime y recibe el assistant final',
    () async {
      const toolTail = <Map<String, dynamic>>[
        {
          'message_id': 'reopen-tools-user',
          'role': 'user',
          'content': 'busca las noticias',
        },
        {
          'message_id': 'reopen-tools-call',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'reopen-search-call',
              'function': {'name': 'web_search', 'arguments': '{}'},
            },
          ],
        },
        {
          'message_id': 'reopen-tools-result',
          'role': 'tool',
          'tool_call_id': 'reopen-search-call',
          'content': 'resultados encontrados',
        },
      ];
      var canonicalTranscript = toolTail;
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-reopen-tools',
          'session_key': 'stored-chat',
          'messages': toolTail,
          'inflight': {
            'user': 'busca las noticias',
            'assistant': '',
            'streaming': true,
          },
          'running': true,
          'status': 'working',
        });
      final chat = _chat(
        'resume-tools-live',
        gateway,
        storedMessageLoader: (_, _) async => canonicalTranscript,
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = toolTail.reversed
          .map(Map<String, dynamic>.of)
          .toList(growable: false);
      chat.messagesLoaded = true;
      chat.state = ChatPipelineState.completed;

      final changed = await chat.reconcileAfterResume();

      expect(changed, isTrue);
      expect(gateway.resumeExistingCalls, 1);
      expect(chat.isStreaming, isTrue);

      canonicalTranscript = const <Map<String, dynamic>>[
        ...toolTail,
        {
          'message_id': 'reopen-tools-final',
          'role': 'assistant',
          'content': 'Aquí tienes las noticias completas.',
        },
      ];
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit('message.complete', {
        'text': 'Aquí tienes las noticias completas.',
      });
      await done.timeout(const Duration(seconds: 1));

      expect(chat.assistantContent, 'Aquí tienes las noticias completas.');
      expect(chat.state, ChatPipelineState.completed);
    },
  );

  test(
    'reapertura con assistant call y tool sin call id sigue esperando final',
    () async {
      const toolTail = <Map<String, dynamic>>[
        {
          'message_id': 'reopen-unlinked-user',
          'role': 'user',
          'content': 'busca sin linkage',
        },
        {
          'message_id': 'reopen-unlinked-call',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'A',
              'function': {'name': 'web_search', 'arguments': '{}'},
            },
          ],
        },
        {
          'message_id': 'reopen-unlinked-result',
          'role': 'tool',
          'name': 'web_search',
          'content': 'resultado todavía intermedio',
        },
      ];
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-reopen-unlinked',
          'session_key': 'stored-chat',
          'messages': toolTail,
          'inflight': {
            'user': 'busca sin linkage',
            'assistant': '',
            'streaming': true,
          },
          'running': true,
          'status': 'working',
        });
      final chat = _chat(
        'resume-tools-unlinked-live',
        gateway,
        storedMessageLoader: (_, _) async => toolTail,
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = toolTail.reversed
          .map(Map<String, dynamic>.of)
          .toList(growable: false);
      chat.messagesLoaded = true;
      chat.state = ChatPipelineState.completed;

      final changed = await chat.reconcileAfterResume();

      expect(changed, isTrue);
      expect(gateway.resumeExistingCalls, 1);
      expect(chat.isStreaming, isTrue);
      expect(
        chat.internalMessagesForTesting.any(
          (message) => message['role'] == 'tool',
        ),
        isFalse,
      );
      final assistant = chat.internalMessagesForTesting.singleWhere(
        (message) => message['role'] == 'assistant',
      );
      final activity = assistant[assistantActivityTraceKey] as List<dynamic>;
      expect(activity, hasLength(1));
      expect(activity.single['status'], 'running');
    },
  );

  test(
    'reapertura Desktop no consulta un terminal canónico tool-only',
    () async {
      const toolOnly = <Map<String, dynamic>>[
        {
          'message_id': 'tool-only-user',
          'role': 'user',
          'content': 'consulta el estado',
        },
        {
          'message_id': 'tool-only-result',
          'role': 'tool',
          'name': 'status',
          'content': 'ok',
        },
      ];
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-tool-only',
          'session_key': 'stored-chat',
          'messages': toolOnly,
          'running': false,
        });
      final chat = _chat(
        'resume-tool-only',
        gateway,
        storedMessageLoader: (_, _) async => toolOnly,
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = toolOnly.reversed
          .map(Map<String, dynamic>.of)
          .toList(growable: false);
      chat.messagesLoaded = true;
      chat.state = ChatPipelineState.completed;

      final changed = await chat.reconcileAfterResume();

      expect(changed, isTrue);
      expect(gateway.resumeExistingCalls, 0);
      expect(chat.state, ChatPipelineState.completed);
      expect(chat.internalMessagesForTesting.first['role'], 'assistant');
      final activity =
          chat.internalMessagesForTesting.first[assistantActivityTraceKey]
              as List<dynamic>;
      expect(activity, hasLength(1));
      expect(activity.single['status'], 'completed');
    },
  );

  test(
    'Stop asentado no reatacha un snapshot running obsoleto tras tools',
    () async {
      const toolTail = <Map<String, dynamic>>[
        {
          'message_id': 'cancelled-tool-user',
          'role': 'user',
          'content': 'busca las noticias',
        },
        {
          'message_id': 'cancelled-tool-call',
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'cancelled-search-call',
              'function': {'name': 'web_search', 'arguments': '{}'},
            },
          ],
        },
        {
          'message_id': 'cancelled-tool-result',
          'role': 'tool',
          'tool_call_id': 'cancelled-search-call',
          'content': 'resultado parcial',
        },
      ];
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-cancelled-tools',
          'session_key': 'stored-chat',
          'messages': toolTail,
          'inflight': {
            'user': 'busca las noticias',
            'assistant': '',
            'streaming': true,
          },
          'running': true,
        });
      final chat = _chat(
        'resume-cancelled-tools',
        gateway,
        storedMessageLoader: (_, _) async => toolTail,
      );
      addTearDown(chat.dispose);
      chat.internalMessagesForTesting = toolTail.reversed
          .map(Map<String, dynamic>.of)
          .toList(growable: false);
      chat.messagesLoaded = true;
      chat.state = ChatPipelineState.completed;
      await chat.cancel();
      expect(chat.state, ChatPipelineState.cancelled);
      expect(
        chat.messages.singleWhere(
          (message) => message['message_id'] == 'cancelled-tool-user',
        )['_cancelledUser'],
        isTrue,
      );

      final changed = await chat.reconcileAfterResume();

      expect(changed, isFalse);
      expect(gateway.resumeExistingCalls, 0);
      expect(chat.state, ChatPipelineState.cancelled);
    },
  );

  test('Stop invalida el reconcile lifecycle pendiente tras tools', () async {
    const toolTail = <Map<String, dynamic>>[
      {
        'message_id': 'race-tool-user',
        'role': 'user',
        'content': 'busca las noticias',
      },
      {
        'message_id': 'race-tool-call',
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'race-search-call',
            'function': {'name': 'web_search', 'arguments': '{}'},
          },
        ],
      },
      {
        'message_id': 'race-tool-result',
        'role': 'tool',
        'tool_call_id': 'race-search-call',
        'content': 'resultado parcial',
      },
    ];
    final resumeGate = Completer<DesktopSessionSnapshot>();
    final gateway = _SnapshotGateway()..resumeGate = resumeGate;
    final chat = _chat(
      'resume-stop-race',
      gateway,
      storedMessageLoader: (_, _) async => toolTail,
    );
    addTearDown(chat.dispose);
    chat.internalMessagesForTesting = toolTail.reversed
        .map(Map<String, dynamic>.of)
        .toList(growable: false);
    chat.messagesLoaded = true;
    chat.state = ChatPipelineState.completed;

    final staleReconcile = chat.reconcileAfterResume();
    while (gateway.resumeExistingCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await chat.cancel();
    resumeGate.complete(
      _snapshot({
        'session_id': 'runtime-stop-race',
        'session_key': 'stored-chat',
        'messages': toolTail,
        'running': false,
      }),
    );

    expect(await staleReconcile, isFalse);
    expect(gateway.resumeExistingCalls, 1);
    expect(chat.state, ChatPipelineState.cancelled);
    expect(
      chat.messages.singleWhere(
        (message) => message['message_id'] == 'race-tool-user',
      )['_cancelledUser'],
      isTrue,
    );
  });

  test(
    'message.start gobierna el reloj de turno y terminal lo limpia',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-timer',
          'session_key': 'stored-chat',
          'running': true,
          'started_at': 1700000000,
          'inflight': {'assistant': '', 'streaming': true},
        });
      final chat = _chat('resume-timer', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      expect(chat.desktopStartedAt, isNotNull);
      expect(chat.desktopTurnStartedAt, isNull);

      gateway.emit('message.start');
      await Future<void>.delayed(Duration.zero);
      expect(chat.desktopTurnStartedAt, isNotNull);

      gateway.emit('error', {'message': 'test terminal'});
      await Future<void>.delayed(Duration.zero);
      expect(chat.desktopTurnStartedAt, isNull);
      expect(chat.state, ChatPipelineState.failed);
    },
  );

  test(
    'message.start tardío sin corte causal conserva el terminal y herramientas',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-late-start',
          'session_key': 'stored-chat',
          'running': true,
          'inflight': {'assistant': '', 'streaming': true},
        });
      final chat = _chat('resume-late-start', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      gateway.emit('tool.start', const {
        'tool_id': 'terminal-tool',
        'name': 'terminal',
        'preview': 'resultado conservado',
      });
      gateway.emit('message.complete', const {'text': 'terminal estable'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final terminalTrace = List.of(chat.trace);

      gateway.emit('message.start');
      await Future<void>.delayed(Duration.zero);

      expect(chat.state, ChatPipelineState.completed);
      expect(chat.isStreaming, isFalse);
      expect(chat.assistantContent, 'terminal estable');
      expect(chat.trace, terminalTrace);
    },
  );

  test(
    'message.start secuenciado posterior del mismo productor abre turno externo',
    () async {
      final producer = Object();
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-causal-start',
          'session_key': 'stored-chat',
          'running': true,
          'inflight': {'assistant': '', 'streaming': true},
        });
      final chat = _chat('resume-causal-start', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      gateway.emit(
        'message.complete',
        const {'text': 'terminal anterior'},
        40,
        7,
        producer,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gateway.emit('message.start', const {}, 41, 7, producer);
      await Future<void>.delayed(Duration.zero);

      expect(chat.state, ChatPipelineState.waiting);
      expect(chat.isStreaming, isTrue);
      expect(chat.desktopTurnStartedAt, isNotNull);
    },
  );

  test(
    'backend-started turn appends after process completion and converges',
    () async {
      SharedPreferences.setMockInitialValues({});
      const processPayload =
          '[IMPORTANT: Background process proc_0123456789ab exited '
          '(exit code 0).]';
      var durable = <Map<String, dynamic>>[
        {
          'message_id': 'turn-1-user',
          'role': 'user',
          'content': 'Lanza el proceso',
          'timestamp': 100,
        },
        {
          'message_id': 'turn-1-assistant',
          'role': 'assistant',
          'content': 'Lanzado en segundo plano con aviso al terminar.',
          'timestamp': 101,
        },
      ];
      final producer = Object();
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-backend-turn',
          'session_key': 'stored-chat',
          'messages': durable,
          'inflight': {'assistant': '', 'streaming': true},
          'running': true,
          'status': 'working',
        });
      final chat = _chat(
        'resume-backend-turn',
        gateway,
        storedMessageLoader: (_, _) async => durable,
      )..smoothStreaming = false;
      addTearDown(chat.dispose);
      await chat.loadMessages();
      final turnOneDone = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit(
        'message.complete',
        const {'text': 'Lanzado en segundo plano con aviso al terminar.'},
        40,
        7,
        producer,
      );
      await turnOneDone.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      durable = <Map<String, dynamic>>[
        ...durable,
        {
          'message_id': 'process-complete',
          'role': 'user',
          'content': processPayload,
          'display_kind': 'process_complete',
          'display_metadata': {'display_text': 'Background Process Finished'},
          'timestamp': 118,
        },
      ];
      chat.internalMessagesForTesting = durable.reversed
          .map(Map<String, dynamic>.of)
          .toList(growable: false);
      gateway.emit('message.start', const {}, 41, 7, producer);
      gateway.emit(
        'message.delta',
        const {'text': 'Terminó correctamente: HECHO-BG.'},
        42,
        7,
        producer,
      );
      await Future<void>.delayed(Duration.zero);

      final liveChronological = chat.messages.reversed.toList(growable: false);
      expect(liveChronological.map((message) => message['content']), const [
        'Lanza el proceso',
        'Lanzado en segundo plano con aviso al terminar.',
        processPayload,
        'Terminó correctamente: HECHO-BG.',
      ]);
      expect(liveChronological[1]['message_id'], 'turn-1-assistant');
      expect(liveChronological[1]['timestamp'], 101);
      expect(liveChronological[2]['display_kind'], 'process_complete');
      expect(liveChronological[3]['message_id'], isNull);
      expect(liveChronological[3]['timestamp'], isNull);

      durable = <Map<String, dynamic>>[
        ...durable,
        {
          'message_id': 'turn-2-assistant',
          'role': 'assistant',
          'content': 'Terminó correctamente: HECHO-BG.',
          'timestamp': 124,
        },
      ];
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit(
        'message.complete',
        const {'text': 'Terminó correctamente: HECHO-BG.'},
        43,
        7,
        producer,
      );
      await done.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      await chat.loadMessages(passiveOnly: true);

      expect(
        chat.messages.reversed.map((message) => message['message_id']),
        durable.map((message) => message['message_id']),
      );
      expect(
        chat.messages.reversed.map((message) => message['content']),
        durable.map((message) => message['content']),
      );
      expect(
        chat.messages.reversed.map((message) => message['timestamp']),
        durable.map((message) => message['timestamp']),
      );
    },
  );

  test(
    'message.start stale o de otro transporte no cruza el terminal causal',
    () async {
      for (final candidate in <(int, int, Object)>[
        (40, 7, Object()),
        (39, 7, Object()),
        (41, 8, Object()),
      ]) {
        final terminalProducer = candidate.$3;
        final startProducer = candidate.$1 == 40 ? Object() : terminalProducer;
        final gateway = _SnapshotGateway()
          ..snapshot = _snapshot({
            'session_id': 'runtime-stale-${candidate.$1}-${candidate.$2}',
            'session_key': 'stored-chat',
            'running': true,
            'inflight': {'assistant': '', 'streaming': true},
          });
        final chat = _chat(
          'resume-stale-${candidate.$1}-${candidate.$2}',
          gateway,
        );
        addTearDown(chat.dispose);
        await chat.loadMessages();

        gateway.emit(
          'message.complete',
          const {'text': 'terminal estable'},
          40,
          7,
          terminalProducer,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        gateway.emit(
          'message.start',
          const {},
          candidate.$1,
          candidate.$2,
          startProducer,
        );
        await Future<void>.delayed(Duration.zero);

        expect(chat.state, ChatPipelineState.completed);
        expect(chat.assistantContent, 'terminal estable');
      }
    },
  );

  test(
    'auto compaction protege el transcript vivo frente a hidratación REST obsoleta',
    () async {
      var restReads = 0;
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-auto-compact',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'turno anterior'},
          ],
          'inflight': {
            'user': 'turno actual',
            'assistant': '',
            'streaming': true,
          },
          'running': true,
          'status': 'working',
        });
      final client = MockClient((_) async {
        restReads += 1;
        return http.Response(
          '[{"role":"assistant","content":"snapshot obsoleto"}]',
          200,
        );
      });
      final chat = _chat('auto-compact', gateway, client: client);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      gateway.emit('status.update', {
        'kind': 'compacting',
        '_lineage_root_id': 'lineage-rotated',
      });
      gateway.emit('status.update', {
        'kind': 'compacting',
        '_lineage_root_id': 'lineage-rotated',
      });
      gateway.emit('status.update', {
        'kind': 'compacting',
        '_lineage_root_id': 'lineage-rotated',
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.desktopAutoCompacting, isTrue);
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(chat.desktopCompactionLineageId, 'lineage-rotated');

      await expectLater(
        chat.steer('no inyectar durante compactacion'),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      expect(gateway.steerCalls, 0);

      gateway.emit('message.start');
      gateway.emit('message.complete', {'text': 'respuesta viva'});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(chat.desktopAutoCompacting, isFalse);
      expect(chat.assistantContent, 'respuesta viva');
      expect(
        chat.messages.any((message) => message['content'] == 'turno anterior'),
        isTrue,
      );
      expect(
        chat.messages.any((message) => message['content'] == 'turno actual'),
        isTrue,
      );
      // Una lectura pertenece al prefetch inicial, en paralelo a resume. La
      // compactación no debe lanzar otra hidratación REST obsoleta.
      expect(restReads, 1);
    },
  );

  test(
    'auto compaction bloquea nuevos turnos antes de mutar el transcript',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-auto-send',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'assistant', 'content': 'estado estable'},
          ],
        });
      final chat = _chat('auto-send-busy', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();
      final before = List<Map<String, dynamic>>.from(chat.messages);

      gateway.emit('status.update', const {
        'kind': 'compacting',
        '_lineage_root_id': 'lineage-auto-send',
      });
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        chat.send(
          fullText: 'no enviar',
          model: 'hermes-agent',
          history: const [],
        ),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      expect(chat.messages, before);
      expect(chat.desktopCompactionLineageId, 'lineage-auto-send');
    },
  );

  test('auto compaction bloquea compresion manual sin despachar RPC', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-auto-manual',
        'session_key': 'stored-chat',
        'messages': [
          {'role': 'user', 'content': 'uno'},
          {'role': 'assistant', 'content': 'dos'},
          {'role': 'user', 'content': 'tres'},
          {'role': 'assistant', 'content': 'cuatro'},
        ],
      });
    final chat = _chat('auto-manual-busy', gateway);
    addTearDown(chat.dispose);
    await chat.loadMessages();

    gateway.emit('status.update', const {
      'kind': 'compacting',
      '_lineage_root_id': 'lineage-auto-manual',
    });
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      chat.compressDesktopSession(),
      throwsA(
        isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
      ),
    );
    expect(gateway.slashExecCalls, 0);
    expect(gateway.commandDispatchCalls, 0);
    expect(chat.desktopCompactionLineageId, 'lineage-auto-manual');
  });

  test('cancelar limpia autocompactacion pero conserva lineage', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-auto-cancel',
        'session_key': 'stored-chat',
        'inflight': {
          'user': 'turno actual',
          'assistant': '',
          'streaming': true,
        },
        'running': true,
      });
    final chat = _chat('auto-cancel', gateway);
    addTearDown(chat.dispose);
    await chat.loadMessages();

    gateway.emit('status.update', const {
      'kind': 'compacting',
      '_lineage_root_id': 'lineage-after-cancel',
    });
    await Future<void>.delayed(Duration.zero);
    expect(chat.desktopAutoCompacting, isTrue);

    await chat.cancel();

    expect(chat.desktopAutoCompacting, isFalse);
    expect(chat.desktopCompactionLineageId, 'lineage-after-cancel');
  });

  test(
    'session.info idle limpia autocompactacion sin esperar otro terminal',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-auto-idle',
          'session_key': 'stored-chat',
          'running': true,
        });
      final chat = _chat('auto-idle', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      gateway.emit('status.update', const {
        'kind': 'compacting',
        '_lineage_root_id': 'lineage-auto-idle',
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.desktopAutoCompacting, isTrue);

      gateway.emit('session.info', const {
        'info': {'running': false},
      });
      await Future<void>.delayed(Duration.zero);

      expect(chat.desktopAutoCompacting, isFalse);
      expect(chat.desktopCompressionInFlight, isFalse);
      expect(chat.desktopCompactionLineageId, 'lineage-auto-idle');
    },
  );

  test(
    'desglose de contexto usa el runtime adoptado sin crear sesión',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-context',
          'session_key': 'stored-chat',
        });
      final chat = _chat('resume-context', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      final breakdown = await chat.loadDesktopContextBreakdown();

      expect(breakdown?.contextUsed, 42);
      expect(gateway.contextBreakdownCalls, 1);
      expect(gateway.createCalls, 0);
    },
  );

  test(
    'compresión usa session.compress y adopta su respuesta autoritativa',
    () async {
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-native-compress',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'uno'},
            {'role': 'assistant', 'content': 'dos'},
            {'role': 'user', 'content': 'tres'},
            {'role': 'assistant', 'content': 'cuatro'},
          ],
        })
        ..compressionResult = _nativeCompressionResult();
      final chat = _chat('native-compression-success', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      final result = await chat.compressDesktopSession(
        focusTopic: 'decisiones de release',
      );

      expect(result.accepted, DesktopCommandAcceptance.accepted);
      expect(result.attemptedRoute, DesktopCommandRoute.sessionCompress);
      expect(result.fallbackUsed, isFalse);
      expect(gateway.compressSessionCalls, 1);
      expect(gateway.compressRuntimeId, 'runtime-native-compress');
      expect(gateway.compressFocusTopic, 'decisiones de release');
      expect(gateway.slashExecCalls, 0);
      expect(gateway.commandDispatchCalls, 0);
      expect(chat.storedSessionId, 'stored-native-compressed');
      expect(chat.desktopRuntimeInfo.usage?.contextUsed, 4821);
      // Exact, complete terminal authority replaces the stale display transcript
      // immediately and appends one bounded editorial result for this runtime.
      expect(chat.messages.map((message) => message['content']), [
        'Compressed: 4 → 2 messages\nApprox request size: ~96,022 → ~4,821 tokens',
        'Contexto nativo listo',
        'Resumen nativo durable',
      ]);
      expect(chat.messages.first['display_kind'], 'compression_result');
      expect(chat.buildHistory(), [
        {'role': 'user', 'content': 'Resumen nativo durable'},
        {'role': 'assistant', 'content': 'Contexto nativo listo'},
      ]);
      expect(chat.desktopCompressionInFlight, isFalse);
    },
  );

  test(
    'REGRESSION_COMP_UNCERTAIN malformed post-dispatch ACK survives recreation',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-malformed-ack',
          'session_key': 'stored-chat',
        })
        // The server executed the mutation, then its malformed envelope could
        // not be parsed by TuiGatewayClient into a typed compression result.
        ..compressError = const TuiGatewayRpcError(
          'session.compress',
          'Hermes returned an invalid session compression result',
        );
      final store = DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'malformed-ack-attempt',
      );
      final first = _chat(
        'malformed-ack',
        gateway,
        compressionFenceStore: store,
      );
      await first.loadMessages();

      await expectLater(
        first.compressDesktopSession(),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      expect(gateway.compressSessionCalls, 1);
      first.dispose();

      final recreated = _chat(
        'malformed-ack',
        gateway,
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
      );
      addTearDown(recreated.dispose);
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        recreated.compressDesktopSession(),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      expect(gateway.compressSessionCalls, 1);
    },
  );

  test(
    'phase update failure leaves the durable armed fence blocking retries',
    () async {
      final storage = _MemoryCompressionFenceStorage()..failingWrites = {2};
      final store = DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'phase-failure-attempt',
      );
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-phase-failure',
          'session_key': 'stored-chat',
        })
        ..compressionResult = _nativePendingCompressionResult();
      final chat = _chat(
        'phase-update-failure',
        gateway,
        compressionFenceStore: store,
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();

      await chat.compressDesktopSession();
      while (storage.writeCalls < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      final persisted = await DesktopCompressionFenceStore(storage: storage)
          .lookup(
            DesktopCompressionFenceScope(
              connectionId: 'phase-update-failure',
              profile: 'default',
              logicalSessionId: 'stored-chat',
            ),
          );

      expect(persisted.record?.phase, DesktopCompressionFencePhase.armed);
      await expectLater(
        chat.compressDesktopSession(),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      expect(gateway.compressSessionCalls, 1);
    },
  );

  test(
    'correlated terminal native result clears only its durable attempt',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      var attempt = 0;
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-terminal-clear',
          'session_key': 'stored-chat',
          'messages': <Object>[],
        })
        ..compressionResult = _nativeCompressionResult();
      final chat = _chat(
        'terminal-compression-clear',
        gateway,
        compressionFenceStore: DesktopCompressionFenceStore(
          storage: storage,
          attemptId: () => 'terminal-attempt-${++attempt}',
        ),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();

      await chat.compressDesktopSession();
      await chat.compressDesktopSession();

      expect(gateway.compressSessionCalls, 2);
      expect(storage.value, isNot(contains('terminal-attempt-1')));
      expect(storage.value, isNot(contains('terminal-attempt-2')));
    },
  );

  test('settlement delete failure keeps memory and storage fenced', () async {
    final storage = _MemoryCompressionFenceStorage()..failingWrites = {2};
    final gateway = _NativeCompressionGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-delete-failure',
        'session_key': 'stored-chat',
        'messages': <Object>[],
      })
      ..compressionResult = _nativeCompressionResult();
    final chat = _chat(
      'settlement-delete-failure',
      gateway,
      compressionFenceStore: DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'delete-failure-attempt',
      ),
    );
    addTearDown(chat.dispose);
    await chat.loadMessages();

    await chat.compressDesktopSession();

    expect(chat.desktopCompressionInFlight, isTrue);
    expect(storage.value, contains('delete-failure-attempt'));
    await expectLater(
      chat.compressDesktopSession(),
      throwsA(
        isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
      ),
    );
    expect(gateway.compressSessionCalls, 1);
  });

  test(
    'aborted nativo reconcilia autoridad pero nunca comunica éxito',
    () async {
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-native-aborted',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'uno'},
            {'role': 'assistant', 'content': 'dos'},
            {'role': 'user', 'content': 'tres'},
            {'role': 'assistant', 'content': 'cuatro'},
          ],
        })
        ..compressionResult = _nativeAbortedCompressionResult();
      final chat = _chat('native-compression-aborted', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      final result = await chat.compressDesktopSession();

      expect(result.compressionStatus, DesktopCompressionStatus.aborted);
      expect(result.accepted, DesktopCommandAcceptance.rejected);
      expect(result.output, isNull);
      expect(result.failure?.kind, CommandFailureKind.remote);
      expect(chat.storedSessionId, 'stored-native-aborted');
      expect(chat.messages.map((message) => message['content']), [
        'cuatro',
        'tres',
        'dos',
        'uno',
      ]);
      expect(gateway.slashExecCalls, 0);
      expect(gateway.commandDispatchCalls, 0);
      expect(chat.desktopCompressionInFlight, isFalse);
    },
  );

  test(
    'COMP2 no-progress autoritativo retira pending y conserva el transcript',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-comp2-no-progress',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'pregunta uno'},
            {'role': 'assistant', 'content': 'respuesta uno'},
            {'role': 'user', 'content': 'pregunta dos'},
            {'role': 'assistant', 'content': 'respuesta dos'},
          ],
        })
        // Hermes counts six model-facing rows, while its public transcript
        // projection authoritatively retains the four displayable rows.
        ..compressionWireResult = {
          'status': 'compressed',
          'removed': 0,
          'before_messages': 6,
          'after_messages': 6,
          'before_tokens': 16618,
          'after_tokens': 16618,
          'summary': {
            'noop': true,
            'aborted': false,
            'refused_would_grow': false,
            'fallback_used': false,
            'headline': 'No changes from compression: 6 messages',
            'token_line': 'Approx request size: ~16,618 tokens (unchanged)',
            'note': null,
          },
          'usage': {'context_used': 16618, 'context_max': 272000},
          'info': {'stored_session_id': 'stored-chat'},
          'messages': [
            {'role': 'user', 'content': 'pregunta uno'},
            {'role': 'assistant', 'content': 'respuesta uno'},
            {'role': 'user', 'content': 'pregunta dos'},
            {'role': 'assistant', 'content': 'respuesta dos'},
          ],
        };
      final chat = _chat(
        'comp2-no-progress',
        gateway,
        compressionFenceStore: DesktopCompressionFenceStore(
          storage: storage,
          attemptId: () => 'comp2-no-progress-attempt',
        ),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      final before = chat.messages
          .map((message) => message['content'])
          .toList(growable: false);

      final presentation = await chat.compressDesktopSessionForPresentation(
        focusTopic: 'E2E1210COMP2',
      );

      expect(presentation.failure, isNull);
      expect(
        presentation.command?.compressionStatus,
        DesktopCompressionStatus.noOp,
      );
      expect(presentation.command?.accepted, DesktopCommandAcceptance.accepted);
      expect(presentation.command?.failure, isNull);
      expect(chat.desktopCompressionInFlight, isFalse);
      expect(chat.desktopCompressionAwaitingReconciliation, isFalse);
      expect(storage.value, isNot(contains('comp2-no-progress-attempt')));
      expect(
        chat.messages.map((message) => message['content']),
        orderedEquals([
          'Nothing to compress: 6 messages · ~16618 tokens',
          ...before,
        ]),
      );
      expect(chat.messages.first['display_kind'], 'compression_result');
      expect(gateway.compressSessionCalls, 1);
      expect(gateway.slashExecCalls + gateway.commandDispatchCalls, 0);
    },
  );

  test('lock_held nativo es busy/deferred y no toca el transcript', () async {
    final gateway = _NativeCompressionGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-native-lock-held',
        'session_key': 'stored-chat',
        'messages': [
          {'role': 'user', 'content': 'uno'},
          {'role': 'assistant', 'content': 'dos'},
        ],
      })
      ..compressionResult = _nativeLockHeldCompressionResult();
    final chat = _chat('native-compression-lock-held', gateway);
    addTearDown(chat.dispose);
    await chat.loadMessages();
    final before = List<Map<String, dynamic>>.from(chat.messages);

    final result = await chat.compressDesktopSession();

    expect(result.compressionStatus, DesktopCompressionStatus.lockHeld);
    expect(result.accepted, DesktopCommandAcceptance.rejected);
    expect(result.failure?.kind, CommandFailureKind.conflict);
    expect(result.output, isNull);
    expect(chat.messages, before);
    expect(chat.storedSessionId, 'stored-chat');
    expect(gateway.slashExecCalls, 0);
    expect(gateway.commandDispatchCalls, 0);
    expect(chat.desktopCompressionInFlight, isFalse);
  });

  for (final stale in [false, true]) {
    for (final kind in [
      'settled',
      'preflight',
      'format',
      'unknown',
      'no-code',
      'ownership',
      'malformed',
    ]) {
      test('REGRESSION_COMP_TYPED_BOUNDARY $kind stale=$stale', () async {
        final storage = _MemoryCompressionFenceStorage();
        final gate = Completer<DesktopCompressionResult>();
        final gateway = _lockHeldGateway('runtime-boundary')
          ..nativeCompressionGate = gate;
        final chat = _chat(
          'typed-boundary',
          gateway,
          compressionFenceStore: _lockHeldFenceStore(
            storage,
            'boundary-attempt',
          ),
        );
        addTearDown(chat.dispose);
        await chat.loadMessages();
        final pending = chat.compressDesktopSession();
        final done = kind == 'settled'
            ? pending
            : expectLater(pending, throwsA(anything));
        await gateway.compressionEntered.future;
        if (stale) await chat.loadMessages();
        final before = List<Map<String, dynamic>>.from(chat.messages);
        if (kind == 'settled') {
          gate.complete(_nativeAbortedCompressionResult());
        } else {
          gate.completeError(switch (kind) {
            'preflight' => const TuiGatewayRpcError(
              'session.compress',
              'denied',
              origin: CompressionFailureOrigin.localPreflight,
            ),
            'ownership' => const TuiGatewayRpcError(
              'session.compress',
              'sesión ajena',
              code: 4090,
            ),
            'malformed' => const TuiGatewayRpcError(
              'session.compress',
              'invalid',
              code: 4090,
              origin: CompressionFailureOrigin.malformed,
            ),
            'format' => const FormatException('invalid'),
            'unknown' => const TuiGatewayRpcError(
              'session.compress',
              'neutral',
              code: 5555,
            ),
            _ => const TuiGatewayRpcError('session.compress', 'neutral'),
          });
        }
        await done;
        final retained = kind != 'settled' && kind != 'preflight';
        expect(storage.value?.contains('boundary-attempt'), retained);
        expect(chat.desktopCompressionInFlight, retained);
        if (stale || kind != 'settled') expect(chat.messages, before);
        if (retained) {
          chat.dispose();
          final recreated = _chat(
            'typed-boundary',
            gateway,
            compressionFenceStore: _lockHeldFenceStore(storage, 'other'),
          );
          addTearDown(recreated.dispose);
          await expectLater(recreated.compressDesktopSession(), _lockHeldBusy);
          expect(recreated.desktopCompressionInFlight, isTrue);
        }
        expect(gateway.slashExecCalls + gateway.commandDispatchCalls, 0);
      });
    }
  }

  test(
    'REGRESSION_COMP_TYPED_ARM_UNCLAIMED preserves B inserted before arm',
    () async {
      final storage = _MemoryCompressionFenceStorage(),
          foreign = _MemoryCompressionFenceStorage();
      final gateway = _lockHeldGateway('runtime-unclaimed');
      await _lockHeldFenceStore(foreign, 'B').arm(
        DesktopCompressionFenceScope(
          connectionId: 'typed-unclaimed',
          profile: 'default',
          logicalSessionId: 'stored-chat',
        ),
        tipAtStart: 'stored-chat',
        compressionsAtStart: null,
        createdAtMs: 1,
        reconcileUntilMs: 2,
      );
      final chat = _chat(
        'typed-unclaimed',
        gateway,
        compressionFenceStore: _lockHeldFenceStore(storage, 'A'),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      final armRead = storage.readCalls + 2;
      storage.onRead = () {
        if (storage.readCalls == armRead) storage.value = foreign.value;
      };
      await expectLater(chat.compressDesktopSession(), _lockHeldBusy);
      expect(storage.value, foreign.value);
      expect(storage.writeCalls, 0);
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(
        gateway.compressSessionCalls +
            gateway.slashExecCalls +
            gateway.commandDispatchCalls,
        0,
      );
    },
  );

  test(
    'REGRESSION_COMP_TYPED_ARM_UNCERTAIN never deletes an unclaimed record',
    () async {
      final storage = _MemoryCompressionFenceStorage()..failAfterWrite = true;
      final gateway = _lockHeldGateway('runtime-uncertain');
      final chat = _chat(
        'typed-uncertain',
        gateway,
        compressionFenceStore: _lockHeldFenceStore(
          storage,
          'uncertain-attempt',
        ),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      await expectLater(chat.compressDesktopSession(), _lockHeldBusy);
      expect(storage.value, contains('uncertain-attempt'));
      expect(storage.writeCalls, 1);
      expect(chat.desktopCompressionInFlight, isTrue);
      await expectLater(chat.compressDesktopSession(), _lockHeldBusy);
      expect(
        gateway.compressSessionCalls +
            gateway.slashExecCalls +
            gateway.commandDispatchCalls,
        0,
      );
    },
  );

  test(
    'REGRESSION_COMP_TYPED_ARM_ABORT claimed undispatched is cleaned',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final gateway = _lockHeldGateway('runtime-arm');
      final chat = _chat(
        'typed-arm',
        gateway,
        compressionFenceStore: _lockHeldFenceStore(storage, 'arm-attempt'),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      storage.writeGate = Completer<void>();
      storage.writeEntered = Completer<void>();
      final pending = expectLater(
        chat.compressDesktopSession(),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      await storage.writeEntered!.future;
      await chat.loadMessages();
      storage.writeGate!.complete();
      await pending;
      expect(storage.value, isNot(contains('arm-attempt')));
      expect(chat.desktopCompressionInFlight, isFalse);
      expect(gateway.compressSessionCalls, 0);
      expect(gateway.slashExecCalls + gateway.commandDispatchCalls, 0);
    },
  );

  for (final unknown in [false, true]) {
    test('REGRESSION_COMP_TYPED_STALE_PENDING unknown=$unknown', () async {
      final storage = _MemoryCompressionFenceStorage();
      final gate = Completer<DesktopCompressionResult>();
      final gateway = _lockHeldGateway('runtime-stale')
        ..nativeCompressionGate = gate;
      final chat = _chat(
        'typed-stale',
        gateway,
        compressionFenceStore: _lockHeldFenceStore(storage, 'stale-attempt'),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      final pending = chat.compressDesktopSession();
      final completed = unknown
          ? expectLater(pending, throwsA(isA<TuiGatewayRpcError>()))
          : pending;
      await gateway.compressionEntered.future;
      await chat.loadMessages();
      final before = List<Map<String, dynamic>>.from(chat.messages);
      if (unknown) {
        gate.completeError(
          const TuiGatewayRpcError('session.compress', 'neutral', code: 5555),
        );
      } else {
        gate.complete(_nativePendingCompressionResult());
      }
      await completed;
      expect(storage.value, contains('stale-attempt'));
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(chat.messages, before);
      expect(gateway.slashExecCalls + gateway.commandDispatchCalls, 0);
    });
  }

  for (final message in ['neutral', 'timeout', 'transport', 'sesión ajena']) {
    test(
      'REGRESSION_COMP_TYPED_NATIVE_4090 $message retains its attempt without fallback',
      () async {
        final storage = _MemoryCompressionFenceStorage();
        final gateway = _lockHeldGateway('runtime-4090')
          ..compressError = TuiGatewayRpcError(
            'session.compress',
            message,
            code: 4090,
          );
        final chat = _chat(
          'typed-4090',
          gateway,
          compressionFenceStore: _lockHeldFenceStore(storage, 'typed-attempt'),
        );
        addTearDown(chat.dispose);
        await chat.loadMessages();
        final before = List<Map<String, dynamic>>.from(chat.messages);
        final resumes = gateway.resumeExistingCalls;
        await expectLater(
          chat.compressDesktopSession(),
          throwsA(isA<TuiGatewayRpcError>()),
        );
        expect(storage.value, contains('typed-attempt'));
        expect(chat.desktopCompressionInFlight, isTrue);
        expect(chat.desktopCompressionTransportUncertain, isFalse);
        expect(chat.messages, before);
        expect(gateway.compressSessionCalls, 1);
        expect(gateway.slashExecCalls + gateway.commandDispatchCalls, 0);
        expect(gateway.resumeExistingCalls, resumes);
        expect(gateway.createCalls, 0);
        chat.dispose();
        final recreated = _chat(
          'typed-4090',
          gateway,
          compressionFenceStore: _lockHeldFenceStore(storage, 'other-attempt'),
        );
        addTearDown(recreated.dispose);
        await expectLater(recreated.compressDesktopSession(), _lockHeldBusy);
        expect(recreated.desktopCompressionInFlight, isTrue);
        expect(gateway.compressSessionCalls, 1);
      },
    );
  }

  test(
    'REGRESSION_COMP_FIX1_SERVICE_STALE_LOCK_HELD_RESOLVES_EXACT_ATTEMPT',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final gate = Completer<DesktopCompressionResult>();
      final gateway = _lockHeldGateway('runtime-fix1-service')
        ..nativeCompressionGate = gate;
      final chat = _chat(
        'fix1-service-stale',
        gateway,
        compressionFenceStore: _lockHeldFenceStore(storage, 'fix1-attempt-A'),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();

      final pending = chat.compressDesktopSessionForPresentation();
      await gateway.compressionEntered.future;
      expect(storage.value, contains('fix1-attempt-A'));
      await chat.loadMessages();
      gate.complete(_nativeLockHeldCompressionResult());
      final presentation = await pending;

      expect(
        presentation.command?.compressionStatus,
        DesktopCompressionStatus.lockHeld,
      );
      expect(presentation.failure, isNull);
      expect(presentation.projection.isCurrent, isFalse);
      expect(
        presentation.projection.isCurrent,
        isFalse,
        reason: 'an invalidated opaque projection cannot become current again',
      );
      expect(storage.value, isNot(contains('fix1-attempt-A')));
      expect(chat.desktopCompressionInFlight, isFalse);
    },
  );

  test(
    'REGRESSION_COMP_FIX3_LEGACY_CONTRADICTION_RETAINS_EXACT_FENCE',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-fix3-legacy',
          'session_key': 'stored-chat',
          'messages': <Object>[],
        })
        ..compressionGate = (Completer<DesktopCommandRpcResult>()
          ..complete(
            DesktopCommandRpcResult.fromJson({
              'type': 'exec',
              'accepted': false,
              'status': 'pending',
              'output': 'queued',
            }),
          ));
      final chat = _chat(
        'fix3-legacy',
        gateway,
        compressionFenceStore: _lockHeldFenceStore(storage, 'legacy-attempt-A'),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      final presentation = await chat.compressDesktopSessionForPresentation();
      expect(presentation.failure, isNull);
      expect(presentation.projection.isCurrent, isTrue);
      expect(storage.value, contains('legacy-attempt-A'));
      expect(chat.desktopCompressionInFlight, isTrue);
      await expectLater(chat.compressDesktopSession(), _lockHeldBusy);
      expect(gateway.slashExecCalls, 1);
      expect(gateway.commandDispatchCalls, 0);
    },
  );

  test(
    'REGRESSION_COMP_FIX3_LEGACY_REJECTION_DELETES_ONLY_ITS_FENCE',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      await _lockHeldFenceStore(storage, 'foreign-attempt').arm(
        DesktopCompressionFenceScope(
          connectionId: 'foreign',
          profile: 'default',
          logicalSessionId: 'foreign',
        ),
        tipAtStart: 'foreign-tip',
        compressionsAtStart: null,
        createdAtMs: 1,
        reconcileUntilMs: 2,
      );
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-fix3-rejected',
          'session_key': 'stored-chat',
          'messages': <Object>[],
        })
        ..compressionGate = (Completer<DesktopCommandRpcResult>()
          ..complete(
            DesktopCommandRpcResult.fromJson({
              'type': 'error',
              'accepted': false,
              'status': 'rejected',
            }),
          ));
      final chat = _chat(
        'fix3-rejected',
        gateway,
        compressionFenceStore: _lockHeldFenceStore(
          storage,
          'rejected-attempt-A',
        ),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      final presentation = await chat.compressDesktopSessionForPresentation();
      expect(presentation.command?.accepted, DesktopCommandAcceptance.rejected);
      expect(presentation.projection.isCurrent, isTrue);
      expect(storage.value, isNot(contains('rejected-attempt-A')));
      expect(storage.value, contains('foreign-attempt'));
      expect(chat.desktopCompressionInFlight, isFalse);
      await chat.compressDesktopSession();
      expect(gateway.slashExecCalls, 2);
      expect(gateway.commandDispatchCalls, 0);
      expect(storage.value, contains('foreign-attempt'));
    },
  );

  for (final withContextProjection in [true, false]) {
    test(
      'REGRESSION_COMP_FIX3_REENTRANT_HYDRATION_NEVER_RECAPTURES_LOAD context=$withContextProjection',
      () async {
        final storage = _MemoryCompressionFenceStorage();
        final gateway = _lockHeldGateway('runtime-fix3-reentrant')
          ..compressionResult = withContextProjection
              ? _nativeCompressionResult()
              : DesktopCompressionResult.fromJson({
                  'status': 'compressed',
                  'info': {'stored_session_id': 'stored-native-compressed'},
                });
        var armed = false;
        var callbacks = 0;
        Future<void>? refresh;
        late final ActiveChat chat;
        chat = _chat(
          'fix3-reentrant',
          gateway,
          compressionFenceStore: _lockHeldFenceStore(storage, 'fix3-attempt'),
          onEvent: (emitted) {
            if (!armed ||
                emitted != ActiveChatEvent.sessionInfo ||
                chat.storedSessionId != 'stored-native-compressed') {
              return;
            }
            armed = false;
            callbacks++;
            storage
              ..gatedReadCall = storage.readCalls + 1
              ..readEntered = Completer<void>()
              ..readGate = Completer<void>();
            refresh = chat.loadMessages();
          },
        );
        addTearDown(chat.dispose);
        await chat.loadMessages();
        armed = true;
        final presentation = await chat.compressDesktopSessionForPresentation();
        await storage.readEntered!.future;
        try {
          expect(callbacks, 1);
          expect(gateway.compressSessionCalls, 1);
          expect(
            presentation.command?.compressionStatus,
            DesktopCompressionStatus.compressed,
          );
          expect(presentation.failure, isNull);
          expect(
            storage.value,
            isNot(contains('fix3-attempt')),
            reason: 'durable settlement does not depend on presentation',
          );
          expect(
            presentation.projection.isCurrent,
            isFalse,
            reason:
                'external load epoch must not be recaptured while lookup waits',
          );
          expect(presentation.projection.isCurrent, isFalse);
        } finally {
          storage.readGate!.complete();
          await refresh;
        }
        expect(
          presentation.projection.isCurrent,
          isFalse,
          reason: 'finishing the refresh cannot revive A',
        );
        await chat.loadMessages();
        expect(presentation.projection.isCurrent, isFalse);
        chat.dispose();
        expect(presentation.projection.isCurrent, isFalse);
      },
    );
  }

  test(
    'REGRESSION_COMP_FIX2_PRESENTATION_STAYS_STALE_AFTER_PREDISPATCH_LOOKUP',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final gateway = _lockHeldGateway('runtime-fix2-predispatch')
        ..compressionResult = _nativeCompressionResult();
      final chat = _chat(
        'fix2-predispatch-stale',
        gateway,
        compressionFenceStore: _lockHeldFenceStore(storage, 'fix2-predispatch'),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();

      storage
        ..gatedReadCall = storage.readCalls + 1
        ..readEntered = Completer<void>()
        ..readGate = Completer<void>();
      final pending = chat.compressDesktopSessionForPresentation();
      await storage.readEntered!.future;

      await chat.loadMessages();
      storage.readGate!.complete();
      final presentation = await pending;

      expect(gateway.compressSessionCalls, 0);
      expect(gateway.slashExecCalls + gateway.commandDispatchCalls, 0);
      expect(
        storage.writeCalls,
        0,
        reason: 'external load revokes arm authority',
      );
      expect(presentation.command, isNull);
      expect(presentation.failure, isA<TuiGatewayRpcError>());
      expect(presentation.projection.isCurrent, isFalse);
      expect(
        presentation.projection.isCurrent,
        isFalse,
        reason: 'a pre-dispatch invalidation must remain sticky',
      );
      expect(chat.desktopCompressionInFlight, isFalse);
    },
  );

  test(
    'REGRESSION_COMP_FIX2_CURRENT_RUNTIME_ACQUISITION_ERROR_IS_PRESENTABLE',
    () async {
      final gateway = _lockHeldGateway('runtime-fix2-acquisition-error')
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'typed acquisition failure',
          code: 5555,
        );
      final chat = _chat(
        'fix2-current-acquisition-error',
        gateway,
        allowUnownedDesktopSnapshotForTesting: false,
      );
      addTearDown(chat.dispose);

      final presentation = await chat.compressDesktopSessionForPresentation();

      expect(
        presentation.failure,
        isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 5555),
      );
      expect(presentation.command, isNull);
      expect(presentation.projection.isCurrent, isTrue);
      expect(presentation.projection.isCurrent, isTrue);
      expect(gateway.compressSessionCalls, 0);
      expect(gateway.slashExecCalls + gateway.commandDispatchCalls, 0);
    },
  );

  test(
    'REGRESSION_COMP_FIX2_OVERLAPPED_RUNTIME_ACQUISITION_STAYS_STALE',
    () async {
      final acquisitionA = Completer<DesktopSessionSnapshot>();
      final acquisitionB = Completer<DesktopSessionSnapshot>()
        ..complete(
          _snapshot({
            'session_id': 'runtime-fix2-external-B',
            'session_key': 'stored-chat',
            'messages': <Object>[],
          }),
        );
      final gateway = _lockHeldGateway('runtime-fix2-default')
        ..compressionResult = _nativeCompressionResult()
        ..resumeEntered = Completer<void>()
        ..resumeGates.addAll([acquisitionA, acquisitionB]);
      final chat = _chat(
        'fix2-overlapped-acquisition',
        gateway,
        allowUnownedDesktopSnapshotForTesting: false,
      );
      addTearDown(chat.dispose);

      final pending = chat.compressDesktopSessionForPresentation();
      await gateway.resumeEntered!.future;
      expect(
        await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
        isTrue,
      );
      expect(chat.desktopRuntimeSessionId, 'runtime-fix2-external-B');

      acquisitionA.complete(
        _snapshot({
          'session_id': 'runtime-fix2-acquisition-A',
          'session_key': 'stored-chat',
          'messages': <Object>[],
        }),
      );
      final presentation = await pending;

      expect(gateway.compressRuntimeId, 'runtime-fix2-external-B');
      expect(
        presentation.command?.compressionStatus,
        DesktopCompressionStatus.compressed,
      );
      expect(presentation.failure, isNull);
      expect(presentation.projection.isCurrent, isFalse);
      expect(
        presentation.projection.isCurrent,
        isFalse,
        reason: 'A cannot adopt the external acquisition B as its own delta',
      );
      expect(chat.desktopCompressionInFlight, isFalse);
    },
  );

  test('REGRESSION_COMP_LOCK_HELD validated ACK deletes only its own attempt '
      'before idle', () async {
    final storage = _MemoryCompressionFenceStorage();
    await _lockHeldFenceStore(storage, 'foreign-attempt').arm(
      DesktopCompressionFenceScope(
        connectionId: 'foreign-conn',
        profile: 'default',
        logicalSessionId: 'foreign-chat',
      ),
      tipAtStart: 'foreign-tip',
      compressionsAtStart: null,
      createdAtMs: 1,
      reconcileUntilMs: 2,
    );
    final gateway = _lockHeldGateway('runtime-lock-held-own');
    final chat = _chat(
      'lock-held-own',
      gateway,
      compressionFenceStore: _lockHeldFenceStore(storage, 'own-attempt'),
    );
    addTearDown(chat.dispose);
    await chat.loadMessages();

    final first = await chat.compressDesktopSession();

    expect(first.compressionStatus, DesktopCompressionStatus.lockHeld);
    expect(first.accepted, DesktopCommandAcceptance.rejected);
    expect(first.failure?.kind, CommandFailureKind.conflict);
    expect(chat.desktopCompressionInFlight, isFalse);
    expect(storage.value, isNot(contains('own-attempt')));
    expect(storage.value, contains('foreign-attempt'));

    final second = await chat.compressDesktopSession();

    expect(second.compressionStatus, DesktopCompressionStatus.lockHeld);
    expect(gateway.compressSessionCalls, 2);
    expect(storage.value, isNot(contains('own-attempt')));
    expect(storage.value, contains('foreign-attempt'));
  });

  test(
    'REGRESSION_COMP_LOCK_HELD delete failure keeps UI fenced and recreation '
    'blocked',
    () async {
      final storage = _MemoryCompressionFenceStorage()..failingWrites = {2};
      final gateway = _lockHeldGateway('runtime-lock-held-stuck');
      final first = _chat(
        'lock-held-stuck',
        gateway,
        compressionFenceStore: _lockHeldFenceStore(storage, 'stuck-attempt'),
      );
      await first.loadMessages();

      final result = await first.compressDesktopSession();

      expect(result.compressionStatus, DesktopCompressionStatus.lockHeld);
      expect(first.desktopCompressionInFlight, isTrue);
      expect(storage.value, contains('stuck-attempt'));
      await expectLater(first.compressDesktopSession(), _lockHeldBusy);
      expect(gateway.compressSessionCalls, 1);
      first.dispose();

      final recreated = _chat(
        'lock-held-stuck',
        gateway,
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
      );
      addTearDown(recreated.dispose);
      await Future<void>.delayed(Duration.zero);
      await expectLater(recreated.compressDesktopSession(), _lockHeldBusy);
      expect(gateway.compressSessionCalls, 1);
    },
  );

  test('REGRESSION_COMP_LOCK_HELD recreation with same store is unfenced after '
      'cleanup', () async {
    final storage = _MemoryCompressionFenceStorage();
    final gateway = _lockHeldGateway('runtime-lock-held-recreated');
    final first = _chat(
      'lock-held-recreated',
      gateway,
      compressionFenceStore: _lockHeldFenceStore(storage, 'first-attempt'),
    );
    await first.loadMessages();
    await first.compressDesktopSession();
    expect(storage.value, isNot(contains('first-attempt')));
    first.dispose();

    final recreated = _chat(
      'lock-held-recreated',
      gateway,
      compressionFenceStore: _lockHeldFenceStore(storage, 'second-attempt'),
    );
    addTearDown(recreated.dispose);
    await Future<void>.delayed(Duration.zero);

    final result = await recreated.compressDesktopSession();

    expect(result.compressionStatus, DesktopCompressionStatus.lockHeld);
    expect(gateway.compressSessionCalls, 2);
    expect(storage.value, isNot(contains('second-attempt')));
  });

  test(
    'REGRESSION_COMP_LOCK_HELD cleanup honors exact ownership and generation',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      var metadataReads = 0;
      Completer<void>? nextMetadata;
      final gate = Completer<DesktopCompressionResult>();
      final gateway = _lockHeldGateway('runtime-lock-held-generation')
        ..nativeCompressionGate = gate;
      final chat = _chat(
        'lock-held-generation',
        gateway,
        desktopCompressionReconciliationDelay: const Duration(milliseconds: 1),
        client: MockClient((_) async {
          metadataReads++;
          if (nextMetadata?.isCompleted == false) nextMetadata!.complete();
          return http.Response('unavailable', 500);
        }),
        compressionFenceStore: _lockHeldFenceStore(storage, 'gen-1-attempt'),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();

      final pending = chat.compressDesktopSession();
      await gateway.compressionEntered.future;
      expect(storage.value, contains('gen-1-attempt'));

      // A newer generation owned by another writer replaces the durable
      // record while the validated ACK is still in flight.
      final scope = DesktopCompressionFenceScope(
        connectionId: 'lock-held-generation',
        profile: 'default',
        logicalSessionId: 'stored-chat',
      );
      final rotated = _lockHeldFenceStore(storage, 'gen-2-attempt');
      await rotated.clearSession(scope);
      await rotated.arm(
        scope,
        tipAtStart: 'stored-chat',
        compressionsAtStart: null,
        createdAtMs: 1,
        reconcileUntilMs: DateTime.now().millisecondsSinceEpoch + 120000,
      );

      await chat.loadMessages();
      final readsBeforeCas = storage.readCalls;
      nextMetadata = Completer<void>();
      gate.complete(_nativeLockHeldCompressionResult());
      final result = await pending;

      expect(result.compressionStatus, DesktopCompressionStatus.lockHeld);
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(
        storage.readCalls,
        greaterThanOrEqualTo(readsBeforeCas + 2),
        reason: 'CAS=false must reload B rather than reinstall A',
      );
      expect(storage.value, contains('gen-2-attempt'));
      expect(storage.value, isNot(contains('gen-1-attempt')));
      final readsBeforeTimer = metadataReads;
      await nextMetadata.future;
      expect(
        metadataReads,
        greaterThan(readsBeforeTimer),
        reason: 'B reconciliation must continue',
      );
      await expectLater(chat.compressDesktopSession(), _lockHeldBusy);
      expect(gateway.compressSessionCalls, 1);
    },
  );

  test(
    'REGRESSION_COMP_LOCK_HELD method-not-found never runs the validated ACK '
    'cleanup',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final gateway = _lockHeldGateway('runtime-lock-held-mnf')
        ..compressError = const TuiGatewayRpcError(
          'session.compress',
          'Method not found',
          code: -32601,
        )
        ..slashError = TimeoutException('slash transport timeout');
      final chat = _chat(
        'lock-held-mnf',
        gateway,
        compressionFenceStore: _lockHeldFenceStore(storage, 'mnf-attempt'),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();

      final result = await chat.compressDesktopSession();

      expect(result.attemptedRoute, DesktopCommandRoute.slashExec);
      expect(result.accepted, DesktopCommandAcceptance.unknown);
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(storage.value, contains('mnf-attempt'));
    },
  );

  test('REGRESSION_COMP_LOCK_HELD invalidated refresh still deletes its exact '
      'durable attempt', () async {
    final storage = _MemoryCompressionFenceStorage();
    final gate = Completer<DesktopCompressionResult>();
    final gateway = _lockHeldGateway('runtime-lock-held-invalidated')
      ..nativeCompressionGate = gate;
    final chat = _chat(
      'lock-held-invalidated',
      gateway,
      compressionFenceStore: _lockHeldFenceStore(
        storage,
        'invalidated-attempt',
      ),
    );
    addTearDown(chat.dispose);
    await chat.loadMessages();

    final pending = chat.compressDesktopSession();
    while (gateway.compressSessionCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(storage.value, contains('invalidated-attempt'));

    // Un refresh posterior incrementa messageLoadEpoch mientras el ACK
    // lockHeld sigue bloqueado: la validez del fence caduca, pero el
    // attempt durable propio sigue siendo de este dispatcher y el ACK
    // validado debe borrarlo con ownership/generation exactos (CAS).
    await chat.loadMessages();

    gate.complete(_nativeLockHeldCompressionResult());
    final result = await pending;

    expect(result.compressionStatus, DesktopCompressionStatus.lockHeld);
    expect(storage.value, isNot(contains('invalidated-attempt')));
    expect(chat.desktopCompressionInFlight, isFalse);

    // Tras la limpieza durable, un nuevo intento vuelve a armar y borrar
    // solo su propio attempt aunque la generación anterior caducó.
    final second = await chat.compressDesktopSession();
    expect(second.compressionStatus, DesktopCompressionStatus.lockHeld);
    expect(gateway.compressSessionCalls, 2);
    expect(storage.value, isNot(contains('invalidated-attempt')));
  });

  test(
    'REGRESSION_COMP_TYPED_SETTLEMENT_RACE A cannot project its tip over durable B',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final scope = DesktopCompressionFenceScope(
        connectionId: 'settlement-race',
        profile: 'default',
        logicalSessionId: 'root-race',
      );
      final storeA = DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'attempt-a',
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      await storeA.arm(
        scope,
        tipAtStart: 'tip-before',
        compressionsAtStart: 4,
        createdAtMs: now,
        reconcileUntilMs: now + 120000,
      );
      final firstRead = Completer<void>();
      final releaseA = Completer<void>();
      final bRead = Completer<void>();
      var reads = 0;
      final client = MockClient((_) async {
        reads += 1;
        if (reads == 1) {
          firstRead.complete();
          await releaseA.future;
          return http.Response(
            '{"session":{"id":"tip-from-a","_lineage_root_id":"root-race","info":{"usage":{"compressions":5}}}}',
            200,
          );
        }
        if (!bRead.isCompleted) bRead.complete();
        return http.Response(
          '{"session":{"id":"tip-owned-by-b","_lineage_root_id":"root-race","info":{"usage":{"compressions":4}}}}',
          200,
        );
      });
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-settlement-race',
          'session_key': 'tip-before',
        });
      final chat = _chat(
        'settlement-race',
        gateway,
        client: client,
        logicalSessionId: 'root-race',
        sessionId: 'tip-before',
        compressionFenceStore: storeA,
        desktopCompressionReconciliationDelay: const Duration(milliseconds: 1),
      );
      addTearDown(chat.dispose);
      await firstRead.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () =>
            throw StateError('initial reconciliation did not start'),
      );
      final storeB = DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'attempt-b',
      );
      await storeB.clearSession(scope);
      await storeB.arm(
        scope,
        tipAtStart: 'tip-owned-by-b',
        compressionsAtStart: 4,
        createdAtMs: now,
        reconcileUntilMs: now + 120000,
      );
      releaseA.complete();
      await bRead.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('B reconciliation did not continue'),
      );
      expect(storage.value, contains('attempt-b'));
      expect(storage.value, isNot(contains('attempt-a')));
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(chat.storedSessionId, isNot('tip-from-a'));
    },
  );

  test(
    'REGRESSION_COMP_TYPED_EVENT_SETTLEMENT_RACE waits for exact CAS before projecting tip',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final gateway = _lockHeldGateway('runtime-event-race')
        ..compressionResult = _nativePendingCompressionResult();
      final storeA = _lockHeldFenceStore(storage, 'event-attempt-a');
      final chat = _chat(
        'event-race',
        gateway,
        logicalSessionId: 'root-event-race',
        sessionId: 'tip-before',
        compressionFenceStore: storeA,
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      await chat.compressDesktopSession();
      final tipBeforeEvent = chat.storedSessionId;

      final scope = DesktopCompressionFenceScope(
        connectionId: 'event-race',
        profile: 'default',
        logicalSessionId: 'root-event-race',
      );
      final storeB = _lockHeldFenceStore(storage, 'event-attempt-b');
      await storeB.clearSession(scope);
      final now = DateTime.now().millisecondsSinceEpoch;
      await storeB.arm(
        scope,
        tipAtStart: 'tip-owned-by-b',
        compressionsAtStart: 4,
        createdAtMs: now,
        reconcileUntilMs: now + 120000,
      );

      storage.gatedReadCall = storage.readCalls + 1;
      storage.readEntered = Completer<void>();
      storage.readGate = Completer<void>();
      gateway.emit('session.info', const {
        'info': {
          'stored_session_id': 'tip-from-a',
          '_lineage_root_id': 'root-event-race',
          'usage': {'compressions': 5},
        },
      });
      await storage.readEntered!.future;

      expect(chat.storedSessionId, tipBeforeEvent);
      expect(storage.value, contains('event-attempt-b'));
      storage.readGate!.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(chat.storedSessionId, tipBeforeEvent);
      expect(storage.value, contains('event-attempt-b'));
      expect(chat.desktopCompressionInFlight, isTrue);
    },
  );

  test(
    'COMP_CONVERGENCE official uncorrelated metadata cannot settle lost reply',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final store = _lockHeldFenceStore(storage, 'lost-wire-attempt');
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-lost-wire',
          'session_key': 'stored-chat',
          'info': {
            'usage': {'compressions': 1},
          },
          'messages': [
            {'role': 'assistant', 'content': 'Historial conservado'},
          ],
        })
        ..compressError = TimeoutException('lost reply');
      final chat = _chat(
        'lost-wire',
        gateway,
        compressionFenceStore: store,
        // Official GET detail is a DB row, not a correlated compress receipt.
        client: MockClient(
          (_) async => http.Response(
            '{"id":"stored-chat","profile":"default","message_count":2}',
            200,
          ),
        ),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      final baselineResumes = gateway.resumeExistingCalls;
      await expectLater(
        chat.compressDesktopSession(),
        throwsA(isA<TimeoutException>()),
      );
      // Official session.info has stored_session_id + usage, but no lineage root
      // or compression attempt identifier. Neither a counter nor ready is proof.
      gateway.emit('session.info', const {
        'stored_session_id': 'stored-chat',
        'usage': {'compressions': 2},
      });
      gateway.emit('status.update', const {'kind': 'ready'});
      await Future<void>.delayed(Duration.zero);
      await expectLater(chat.compressDesktopSession(), _lockHeldBusy);
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(storage.value, contains('lost-wire-attempt'));
      expect(gateway.compressSessionCalls, 1);
      expect(gateway.slashExecCalls, 0);
      expect(gateway.commandDispatchCalls, 0);
      expect(gateway.resumeExistingCalls, baselineResumes);
      expect(chat.messages.single['content'], 'Historial conservado');
    },
  );

  test(
    'pending refreshes the same durable attempt beyond the native RPC budget',
    () async {
      var nowMs = 1000;
      final storage = _MemoryCompressionFenceStorage();
      final store = DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'long-native-attempt',
      );
      final gate = Completer<DesktopCompressionResult>();
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-native-long',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'uno'},
            {'role': 'assistant', 'content': 'dos'},
          ],
        })
        ..compressionResult = _nativePendingCompressionResult()
        ..nativeCompressionGate = gate;
      final chat = _chat(
        'native-compression-long',
        gateway,
        compressionFenceStore: store,
        wallClockMs: () => nowMs,
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();

      final dispatch = chat.compressDesktopSession();
      await gateway.compressionEntered.future;
      final scope = DesktopCompressionFenceScope(
        connectionId: 'native-compression-long',
        profile: 'default',
        logicalSessionId: 'stored-chat',
      );
      final armed = (await store.lookup(scope)).record!;
      expect(armed.attemptId, 'long-native-attempt');
      expect(armed.reconcileUntilMs - armed.createdAtMs, 720000);

      nowMs += 700000;
      gate.complete(_nativePendingCompressionResult());
      expect(
        (await dispatch).compressionStatus,
        DesktopCompressionStatus.pending,
      );
      final pending = (await store.lookup(scope)).record!;
      expect(pending.attemptId, armed.attemptId);
      expect(pending.phase, DesktopCompressionFencePhase.serverPending);
      expect(pending.reconcileUntilMs, nowMs + 720000);
    },
  );

  test(
    'transport unknown refreshes the same durable attempt beyond the RPC budget',
    () async {
      var nowMs = 1000;
      final storage = _MemoryCompressionFenceStorage();
      final store = DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'long-transport-attempt',
      );
      final gate = Completer<DesktopCompressionResult>();
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-transport-long',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'uno'},
            {'role': 'assistant', 'content': 'dos'},
          ],
        })
        ..nativeCompressionGate = gate;
      final chat = _chat(
        'native-compression-transport-long',
        gateway,
        compressionFenceStore: store,
        wallClockMs: () => nowMs,
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();

      final dispatch = chat.compressDesktopSession();
      await gateway.compressionEntered.future;
      final scope = DesktopCompressionFenceScope(
        connectionId: 'native-compression-transport-long',
        profile: 'default',
        logicalSessionId: 'stored-chat',
      );
      final armed = (await store.lookup(scope)).record!;

      nowMs += 700000;
      gate.completeError(TimeoutException('lost transport reply'));
      await expectLater(dispatch, throwsA(isA<TimeoutException>()));
      final pending = (await store.lookup(scope)).record!;
      expect(pending.attemptId, armed.attemptId);
      expect(pending.phase, DesktopCompressionFencePhase.transportUnknown);
      expect(pending.reconcileUntilMs, nowMs + 720000);
    },
  );

  test(
    'pending nativo suprime duplicados hasta un evento terminal del runtime',
    () async {
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-native-pending',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'uno'},
            {'role': 'assistant', 'content': 'dos'},
          ],
        })
        ..compressionResult = _nativePendingCompressionResult();
      final chat = _chat('native-compression-pending', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();
      final baselineResumes = gateway.resumeExistingCalls;

      final result = await chat.compressDesktopSession();

      expect(result.compressionStatus, DesktopCompressionStatus.pending);
      expect(result.accepted, DesktopCommandAcceptance.unknown);
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(chat.desktopCompressionAwaitingReconciliation, isTrue);
      expect(chat.desktopCompressionTransportUncertain, isFalse);
      await expectLater(
        chat.compressDesktopSession(),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      expect(gateway.compressSessionCalls, 1);

      // A stale session.info cannot complete a pending operation for this
      // runtime, and an unrelated same-runtime info update is not proof either.
      gateway.emitForRuntime('runtime-other', 'session.info', const {
        'info': {'stored_session_id': 'other-tip'},
      });
      gateway.emit('session.info', const {
        'info': {'model': 'unrelated-update'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(chat.desktopCompressionAwaitingReconciliation, isTrue);
      expect(gateway.resumeExistingCalls, baselineResumes);

      // A bare late acknowledgement is not identity-scoped terminal evidence.
      gateway.emit('status.update', const {'kind': 'compacted'});
      await Future<void>.delayed(Duration.zero);
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(chat.desktopCompressionAwaitingReconciliation, isTrue);

      // It settles only once the gateway supplies the same root and a resolved
      // tip change. It does not resume or claim a new runtime, and it is never
      // rendered as a success result.
      gateway.emit('session.info', const {
        'info': {
          '_lineage_root_id': 'stored-chat',
          'stored_session_id': 'stored-chat-compacted-tip',
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.storedSessionId, 'stored-chat-compacted-tip');
      expect(chat.desktopCompressionInFlight, isFalse);
      expect(chat.desktopCompressionAwaitingReconciliation, isFalse);
      expect(gateway.compressSessionCalls, 1);
      expect(gateway.resumeExistingCalls, baselineResumes);
    },
  );

  test(
    'reconciliación acotada acepta solo root y tip exactos sin session.resume',
    () async {
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path == '/api/sessions/root-native-pending') {
          return http.Response(
            '{"session":{"id":"tip-native-pending","_lineage_root_id":"root-native-pending"}}',
            200,
          );
        }
        return http.Response('unexpected REST', 500);
      });
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-native-reconcile',
          'session_key': 'stored-chat',
        })
        ..compressionResult = _nativePendingCompressionResult();
      final chat = _chat(
        'native-compression-reconcile',
        gateway,
        client: client,
        logicalSessionId: 'root-native-pending',
        desktopCompressionReconciliationDelay: const Duration(milliseconds: 1),
        desktopCompressionReconciliationWindow: const Duration(
          milliseconds: 200,
        ),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      final baselineResumes = gateway.resumeExistingCalls;

      final result = await chat.compressDesktopSession();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(result.compressionStatus, DesktopCompressionStatus.pending);
      expect(requests, contains('/api/sessions/root-native-pending'));
      expect(chat.storedSessionId, 'tip-native-pending');
      expect(chat.desktopCompressionInFlight, isFalse);
      expect(chat.desktopCompressionAwaitingReconciliation, isFalse);
      expect(gateway.resumeExistingCalls, baselineResumes);
      expect(gateway.compressSessionCalls, 1);
    },
  );

  test(
    'restored settled fence hydrates archived rows from stored display history',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final store = DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'restored-hydration-attempt',
      );
      final scope = DesktopCompressionFenceScope(
        connectionId: 'restored-hydration',
        profile: 'default',
        logicalSessionId: 'root-restored-hydration',
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      await store.arm(
        scope,
        tipAtStart: 'tip-before-hydration',
        compressionsAtStart: 1,
        createdAtMs: now,
        reconcileUntilMs: now + 120000,
      );
      final storedRead = Completer<void>();
      final chat = _chat(
        'restored-hydration',
        _SnapshotGateway(),
        logicalSessionId: 'root-restored-hydration',
        sessionId: 'tip-before-hydration',
        compressionFenceStore: store,
        client: MockClient(
          (_) async => http.Response(
            '{"session":{"id":"tip-after-hydration","_lineage_root_id":"root-restored-hydration"}}',
            200,
          ),
        ),
        storedMessageLoader: (_, _) async {
          if (!storedRead.isCompleted) storedRead.complete();
          return const [
            {
              'id': 'archived-compacted-row',
              'role': 'user',
              'content': 'Archived compacted row',
              'compacted': 1,
            },
            {
              'id': 'current-row',
              'role': 'assistant',
              'content': 'Current row',
            },
          ];
        },
      );
      addTearDown(chat.dispose);

      await storedRead.future;
      await Future<void>.delayed(Duration.zero);

      expect(chat.storedSessionId, 'tip-after-hydration');
      expect(chat.messages.map((message) => message['content']), [
        'Current row',
        'Archived compacted row',
      ]);
      expect(
        (await store.lookup(scope)).status,
        DesktopCompressionFenceLookupStatus.absent,
      );
    },
  );

  test(
    'fenced passive attach load refresh and timer never acquire a runtime',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final now = DateTime.now().millisecondsSinceEpoch;
      final store = DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'passive-attempt',
      );
      await store.arm(
        DesktopCompressionFenceScope(
          connectionId: 'passive-fence',
          profile: 'default',
          logicalSessionId: 'root-passive',
        ),
        tipAtStart: 'tip-passive',
        compressionsAtStart: 2,
        createdAtMs: now,
        reconcileUntilMs: now + 80,
      );
      var metadataReads = 0;
      final client = MockClient((_) async {
        metadataReads += 1;
        return http.Response(
          '{"session":{"id":"tip-passive","_lineage_root_id":"root-passive","info":{"usage":{"compressions":2}}}}',
          200,
        );
      });
      final gateway = _NativeCompressionGateway()
        ..activitySupported = true
        ..snapshot = _snapshot({
          'session_id': 'must-not-resume-passive',
          'session_key': 'tip-passive',
        })
        ..compressionResult = _nativeCompressionResult();
      final chat = _chat(
        'passive-fence',
        gateway,
        client: client,
        logicalSessionId: 'root-passive',
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
        desktopCompressionReconciliationDelay: const Duration(milliseconds: 10),
        desktopCompressionReconciliationWindow: const Duration(
          milliseconds: 80,
        ),
      );
      addTearDown(chat.dispose);

      await Future<void>.delayed(Duration.zero);
      await chat.loadMessages();
      await chat.loadMessages();
      await Future<void>.delayed(const Duration(milliseconds: 35));

      expect(metadataReads, greaterThan(0));
      expect(gateway.resumeExistingCalls, 0);
      expect(gateway.resumeLegacyCalls, 0);
      expect(gateway.activateCalls, 0);
      expect(gateway.listActiveCalls, 0);
      expect(gateway.createCalls, 0);
      expect(gateway.compressSessionCalls, 0);
    },
  );

  test(
    'expired durable fence stops polling and releases compression and send',
    () async {
      // Policy (Hermes Desktop has no fence at all): past its deadline an
      // unproven fence stops polling and stops holding anything; the chat is
      // left with a dismissible "could not confirm" notice.
      final storage = _MemoryCompressionFenceStorage();
      final now = DateTime.now().millisecondsSinceEpoch;
      final scope = DesktopCompressionFenceScope(
        connectionId: 'expired-fence',
        profile: 'default',
        logicalSessionId: 'root-expired',
      );
      await DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'expired-attempt',
      ).arm(
        scope,
        tipAtStart: 'tip-expired',
        compressionsAtStart: 1,
        createdAtMs: now - 200,
        reconcileUntilMs: now - 100,
      );
      var reads = 0;
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'must-not-resume-expired',
          'session_key': 'tip-expired',
        })
        ..compressionResult = _nativeCompressionResult();
      final chat = _chat(
        'expired-fence',
        gateway,
        logicalSessionId: 'root-expired',
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
        client: MockClient((_) async {
          reads += 1;
          return http.Response('not found', 404);
        }),
        desktopCompressionReconciliationDelay: const Duration(milliseconds: 1),
      );
      addTearDown(chat.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final readsAfterAttach = reads;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(reads, readsAfterAttach);

      expect(chat.desktopCompressionInFlight, isFalse);
      expect(chat.desktopCompressionNeedsConfirmation, isTrue);
      expect(gateway.compressSessionCalls, 0);
      expect(
        (await DesktopCompressionFenceStore(
          storage: storage,
        ).lookup(scope)).isFenced,
        isFalse,
      );
    },
  );

  test(
    'REGRESSION_COMP_CLOCK_RESTART restoring an unresolved durable fence '
    'reports the real elapsed start time, not a fresh one',
    () async {
      // Real case: close the app mid-/compress, reopen minutes later — a
      // fresh ActiveChatService has no memory of when this attempt actually
      // started. Without reading the fence's own `createdAtMs`, the dock's
      // elapsed clock silently restarts at 0 instead of showing the real
      // elapsed time.
      final storage = _MemoryCompressionFenceStorage();
      final now = DateTime.now().millisecondsSinceEpoch;
      final startedAtMs = now - 90000; // 90 s ago
      final scope = DesktopCompressionFenceScope(
        connectionId: 'clock-restart',
        profile: 'default',
        logicalSessionId: 'root-clock-restart',
      );
      await DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'clock-restart-attempt',
      ).arm(
        scope,
        tipAtStart: 'tip-clock-restart',
        compressionsAtStart: 1,
        createdAtMs: startedAtMs,
        reconcileUntilMs: now + 600000,
      );
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-clock-restart',
          'session_key': 'tip-clock-restart',
        });
      final chat = _chat(
        'clock-restart',
        gateway,
        logicalSessionId: 'root-clock-restart',
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
        client: MockClient((_) async => http.Response('not found', 404)),
        desktopCompressionReconciliationDelay: const Duration(minutes: 5),
      );
      addTearDown(chat.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(chat.desktopCompressionInFlight, isTrue);
      expect(
        chat.desktopCompactionStartedAt,
        DateTime.fromMillisecondsSinceEpoch(startedAtMs),
      );
    },
  );

  test(
    'REGRESSION_COMP_SESSION_ACTIVITY a restored durable /compress fence '
    'surfaces as compacting in sessionActivity without counting as active',
    () async {
      // Real case: reopen the app mid-/compress. The in-chat dock already
      // showed it (desktopCompressionInFlight), but Home/Conversaciones read
      // sessionActivity, which only looked at automatic compaction.
      final storage = _MemoryCompressionFenceStorage();
      final now = DateTime.now().millisecondsSinceEpoch;
      final scope = DesktopCompressionFenceScope(
        connectionId: 'activity-restore',
        profile: 'default',
        logicalSessionId: 'root-activity-restore',
      );
      await DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'activity-restore-attempt',
      ).arm(
        scope,
        tipAtStart: 'tip-activity-restore',
        compressionsAtStart: 1,
        createdAtMs: now - 30000,
        reconcileUntilMs: now + 600000,
      );
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-activity-restore',
          'session_key': 'tip-activity-restore',
        });
      final chat = _chat(
        'activity-restore',
        gateway,
        logicalSessionId: 'root-activity-restore',
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
        client: MockClient((_) async => http.Response('not found', 404)),
        desktopCompressionReconciliationDelay: const Duration(minutes: 5),
      );
      addTearDown(chat.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(chat.desktopCompressionInFlight, isTrue);
      expect(chat.desktopAutoCompacting, isFalse);
      final activity = chat.sessionActivity;
      expect(activity.compacting, isTrue);
      expect(activity.kind, SessionActivityKind.compacting);
      expect(activity.showsActivity, isTrue);
      // Presentation only: `active` is ActiveChatService's retention signal
      // (release/unused/settle), so a compaction must not pin the chat.
      expect(activity.active, isFalse);
    },
  );

  test(
    'REGRESSION_COMP_SESSION_ACTIVITY a manual /compress in flight surfaces '
    'as compacting in sessionActivity, and clears when it settles',
    () async {
      final compressionGate = Completer<DesktopCompressionResult>();
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-activity-manual',
          'session_key': 'stored-chat',
          'messages': const <Map<String, dynamic>>[],
        })
        ..compressionResult = _nativeCompressionResult()
        ..nativeCompressionGate = compressionGate;
      final chat = _chat('activity-manual', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();
      expect(chat.sessionActivity.compacting, isFalse);
      expect(chat.sessionActivity.kind, SessionActivityKind.idle);

      final compression = chat.compressDesktopSession();
      while (gateway.compressSessionCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      // Manual /compress never opens a turn, so foregroundTurn stays false:
      // the old `_desktopAutoCompacting`-only check could not see it at all.
      expect(chat.isStreaming, isFalse);
      expect(chat.desktopAutoCompacting, isFalse);
      expect(chat.sessionActivity.foregroundTurn, isFalse);
      expect(chat.sessionActivity.kind, SessionActivityKind.compacting);
      expect(chat.sessionActivity.showsActivity, isTrue);
      expect(chat.sessionActivity.active, isFalse);

      compressionGate.complete(gateway.compressionResult);
      await compression;

      expect(chat.desktopCompressionInFlight, isFalse);
      expect(chat.sessionActivity.compacting, isFalse);
      expect(chat.sessionActivity.kind, SessionActivityKind.idle);
    },
  );

  test(
    'REGRESSION_COMP_STUCK_FOREVER durable fence already expired on restore '
    'surfaces the unconfirmed warning instead of polling silently forever',
    () async {
      // Real case: a manual /compress whose reply never reached this device
      // (server-side it aborted almost instantly), then the app was closed
      // and reopened hours later. Restoring a fence whose deadline already
      // ran out must not just quietly stop polling and leave the UI saying
      // "still working" with nothing to ever change that.
      final storage = _MemoryCompressionFenceStorage();
      final now = DateTime.now().millisecondsSinceEpoch;
      final scope = DesktopCompressionFenceScope(
        connectionId: 'stuck-forever',
        profile: 'default',
        logicalSessionId: 'root-stuck-forever',
      );
      await DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'stuck-forever-attempt',
      ).arm(
        scope,
        tipAtStart: 'tip-stuck-forever',
        compressionsAtStart: 1,
        createdAtMs: now - 800000,
        reconcileUntilMs: now - 100,
      );
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-stuck-forever',
          'session_key': 'tip-stuck-forever',
        });
      final chat = _chat(
        'stuck-forever',
        gateway,
        logicalSessionId: 'root-stuck-forever',
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
        client: MockClient((_) async => http.Response('not found', 404)),
        desktopCompressionReconciliationDelay: const Duration(milliseconds: 1),
      );
      addTearDown(chat.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Hermes Desktop never blocks input on a compression it cannot see:
      // an expired, unproven fence becomes a dismissible notice, not a lock
      // on the composer or a permanent "compactando" on Home/Conversaciones.
      expect(chat.desktopCompressionInFlight, isFalse);
      expect(chat.desktopManualCompressionInFlight, isFalse);
      expect(chat.sessionActivity.compacting, isFalse);
      expect(chat.desktopCompressionNeedsConfirmation, isTrue);
      expect(
        (await DesktopCompressionFenceStore(storage: storage).lookup(scope))
            .status,
        DesktopCompressionFenceLookupStatus.absent,
      );

      chat.dismissCompressionConfirmation();
      expect(chat.desktopCompressionNeedsConfirmation, isFalse);
    },
  );

  test(
    'REGRESSION_COMP_IN_PLACE_KILL a fence restored after the app was killed '
    'settles when the server compacted in place (same id, fewer messages)',
    () async {
      // Real case (Pixel, 1.2.12+9260): /compress, app killed mid-way, the
      // server finished in place: same session id, no lineage/tip change and
      // no compression counter in `GET /api/sessions/{id}` — only
      // `message_count` dropped 38 -> 35. The fence never settled and the
      // chat stayed locked for the whole 12-minute window.
      final storage = _MemoryCompressionFenceStorage();
      final now = DateTime.now().millisecondsSinceEpoch;
      final scope = DesktopCompressionFenceScope(
        connectionId: 'in-place-kill',
        profile: 'default',
        logicalSessionId: 'stored-chat',
      );
      await DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'in-place-kill-attempt',
      ).arm(
        scope,
        tipAtStart: 'stored-chat',
        compressionsAtStart: null,
        messagesAtStart: 38,
        createdAtMs: now - 60000,
        reconcileUntilMs: now + 600000,
      );
      final chat = _chat(
        'in-place-kill',
        _SnapshotGateway()
          ..snapshot = _snapshot({
            'session_id': 'runtime-in-place-kill',
            'session_key': 'stored-chat',
          }),
        logicalSessionId: 'stored-chat',
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
        client: MockClient((request) async {
          if (request.url.path == '/api/sessions/stored-chat') {
            return http.Response(
              jsonEncode({
                'object': 'hermes.session',
                'session': {
                  'id': 'stored-chat',
                  'message_count': 35,
                  'parent_session_id': null,
                },
              }),
              200,
            );
          }
          return http.Response('unexpected REST', 500);
        }),
        storedMessageLoader: (_, _) async => const [
          {'id': 'row-1', 'role': 'user', 'content': 'Hola'},
          {'id': 'row-2', 'role': 'assistant', 'content': 'Compactado'},
        ],
      );
      addTearDown(chat.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(chat.desktopCompressionInFlight, isFalse);
      expect(chat.sessionActivity.compacting, isFalse);
      expect(chat.desktopCompressionNeedsConfirmation, isFalse);
      expect(
        (await DesktopCompressionFenceStore(storage: storage).lookup(scope))
            .status,
        DesktopCompressionFenceLookupStatus.absent,
      );
    },
  );

  test(
    'REGRESSION_COMP_FENCED_READ_LOOP a caller-owned read while fenced does '
    'not echo messagesHydrated back as an external change',
    () async {
      // Real case: with a fence restored the chat has no runtime, so the
      // screen's passive reader polls REST. Every fenced read emitted
      // `messagesHydrated`, which reached the screen after its own refresh
      // had finished and was taken as a new external change: an immediate
      // re-read, forever (~1000 session + messages reads per minute).
      final storage = _MemoryCompressionFenceStorage();
      final now = DateTime.now().millisecondsSinceEpoch;
      await DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'fenced-read-loop',
      ).arm(
        DesktopCompressionFenceScope(
          connectionId: 'fenced-read-loop',
          profile: 'default',
          logicalSessionId: 'stored-chat',
        ),
        tipAtStart: 'stored-chat',
        compressionsAtStart: null,
        createdAtMs: now,
        reconcileUntilMs: now + 600000,
      );
      final events = <ActiveChatEvent>[];
      final chat = _chat(
        'fenced-read-loop',
        _SnapshotGateway(),
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'session': {'id': 'stored-chat', 'message_count': 2},
            }),
            200,
          ),
        ),
        storedMessageLoader: (_, _) async => const [
          {'id': 'row-1', 'role': 'user', 'content': 'Hola'},
          {'id': 'row-2', 'role': 'assistant', 'content': 'Respuesta'},
        ],
        onEvent: events.add,
      );
      addTearDown(chat.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat.desktopCompressionInFlight, isTrue);

      events.clear();
      var published = 0;
      await chat.loadMessages(
        passiveOnly: true,
        onMessagesPublished: () => published++,
      );

      expect(published, 1);
      expect(chat.messages, hasLength(2));
      expect(events, isNot(contains(ActiveChatEvent.messagesHydrated)));
    },
  );

  test(
    'REGRESSION_COMP_KILL_ABORTED a restored fence settles from the gateway '
    'replay ring when the compression ended without shrinking the transcript',
    () async {
      // Real case (Pixel, build 9270): app killed 4 s into /compress; the
      // server refused the compaction ("compressed transcript would be
      // larger"), message_count stayed 35, and the chat stayed locked for the
      // whole window. The gateway's replay ring for the runtime that ran it
      // holds "compressing" and the always-emitted "ready".
      final storage = _MemoryCompressionFenceStorage();
      final now = DateTime.now().millisecondsSinceEpoch;
      final scope = DesktopCompressionFenceScope(
        connectionId: 'kill-aborted',
        profile: 'default',
        logicalSessionId: 'stored-chat',
      );
      await DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'kill-aborted-attempt',
      ).arm(
        scope,
        tipAtStart: 'stored-chat',
        compressionsAtStart: null,
        messagesAtStart: 35,
        runtimeAtStart: 'runtime-killed',
        createdAtMs: now - 60000,
        reconcileUntilMs: now + 600000,
      );
      var replayState = 'running';
      final gateway = _ReplayProbeGateway(
        () => {
          'events': [
            {
              'type': 'status.update',
              'session_id': 'runtime-killed',
              'seq': 1,
              'payload': {'kind': 'compressing', 'text': 'compressing 35'},
            },
            if (replayState == 'done')
              {
                'type': 'status.update',
                'session_id': 'runtime-killed',
                'seq': 2,
                'payload': {'kind': 'status', 'text': 'ready'},
              },
          ],
          'latest_seq': replayState == 'done' ? 2 : 1,
          'truncated': false,
          'epoch': 'epoch-a',
        },
      );
      final chat = _chat(
        'kill-aborted',
        gateway,
        logicalSessionId: 'stored-chat',
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
        desktopCompressionReconciliationDelay: const Duration(milliseconds: 5),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'session': {'id': 'stored-chat', 'message_count': 35},
            }),
            200,
          ),
        ),
        storedMessageLoader: (_, _) async => const [
          {'id': 'row-1', 'role': 'user', 'content': 'Hola'},
        ],
      );
      addTearDown(chat.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Still pinned "compressing" on the server: stay fenced.
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(gateway.replayRuntimeIds, contains('runtime-killed'));

      replayState = 'done';
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(chat.desktopCompressionInFlight, isFalse);
      expect(chat.sessionActivity.compacting, isFalse);
      expect(chat.desktopCompressionNeedsConfirmation, isFalse);
      expect(
        (await DesktopCompressionFenceStore(storage: storage).lookup(scope))
            .status,
        DesktopCompressionFenceLookupStatus.absent,
      );
      final outcome = chat.takeRestoredCompressionOutcome();
      expect(outcome?.changed, isFalse);
      expect(outcome?.messagesBefore, 35);
      expect(chat.takeRestoredCompressionOutcome(), isNull);
    },
  );

  test(
    'REGRESSION_COMP_KILL_CREATED_CHAT a chat created in this process keeps '
    'its /compress fence after a restart that reopens it by stored id',
    () async {
      // Real case (Pixel, build 9280): a chat created via the share intent
      // (provisional `mob-` id), one turn, /compress, app killed; reopened
      // from Conversaciones by its stored id. The fence had been keyed by the
      // provisional id, so the new process never found it: no dock, composer
      // unlocked, no outcome.
      final storage = _MemoryCompressionFenceStorage();
      final compressionGate = Completer<DesktopCompressionResult>();
      final gateway = _NativeCompressionGateway()
        ..createSnapshot = DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-created',
            'session_key': 'stored-created',
            'messages': <Object>[],
          },
          requestedStoredSessionId: '',
          created: true,
          method: 'session.create',
        )
        ..snapshot = DesktopSessionSnapshot.fromJson(
          const {
            'session_id': 'runtime-created',
            'session_key': 'stored-created',
            'messages': <Object>[],
          },
          requestedStoredSessionId: 'stored-created',
          created: false,
          method: 'session.resume',
        )
        ..compressionResult = _nativeCompressionResult()
        ..nativeCompressionGate = compressionGate;
      final first = _chat(
        'created-chat-compress',
        gateway,
        sessionId: 'mob-created-compress',
        allowUnownedDesktopSnapshotForTesting: false,
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
      );
      addTearDown(first.dispose);
      first.markStoredSessionMissing();
      expect(
        await first.send(
          fullText: 'primer turno',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      gateway.emit('message.complete', const {'text': 'hecho'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(first.storedSessionId, 'stored-created');

      final compression = first.compressDesktopSession();
      while (gateway.compressSessionCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(first.desktopCompressionInFlight, isTrue);

      // "Kill": a new process attaches the same chat by its stored id.
      final reopened = _chat(
        'created-chat-compress',
        _SnapshotGateway(),
        sessionId: 'stored-created',
        logicalSessionId: 'stored-created',
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'session': {'id': 'stored-created', 'message_count': 2},
            }),
            200,
          ),
        ),
      );
      addTearDown(reopened.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(storage.value, contains('"logical_session_id":"stored-created"'));
      expect(reopened.desktopCompressionInFlight, isTrue);
      expect(reopened.sessionActivity.compacting, isTrue);
      expect(reopened.desktopCompactionStartedAt, isNotNull);

      compressionGate.complete(gateway.compressionResult);
      await compression;
    },
  );

  test(
    'REGRESSION_COMP_KILL_COMPACTED an in-place settle reports before -> after',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final now = DateTime.now().millisecondsSinceEpoch;
      await DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'kill-compacted',
      ).arm(
        DesktopCompressionFenceScope(
          connectionId: 'kill-compacted',
          profile: 'default',
          logicalSessionId: 'stored-chat',
        ),
        tipAtStart: 'stored-chat',
        compressionsAtStart: null,
        messagesAtStart: 38,
        createdAtMs: now - 60000,
        reconcileUntilMs: now + 600000,
      );
      final chat = _chat(
        'kill-compacted',
        _SnapshotGateway(),
        logicalSessionId: 'stored-chat',
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'session': {'id': 'stored-chat', 'message_count': 35},
            }),
            200,
          ),
        ),
        storedMessageLoader: (_, _) async => const [
          {'id': 'row-1', 'role': 'user', 'content': 'Hola'},
        ],
      );
      addTearDown(chat.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final outcome = chat.takeRestoredCompressionOutcome();
      expect(outcome?.changed, isTrue);
      expect(outcome?.messagesBefore, 38);
      expect(outcome?.messagesAfter, 35);
    },
  );

  test(
    'REGRESSION_COMP_IN_PLACE_BASELINE /compress records the stored message '
    'count as the in-place settlement baseline',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final compressionGate = Completer<DesktopCompressionResult>();
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-baseline',
          'session_key': 'stored-chat',
          'messages': const <Map<String, dynamic>>[],
        })
        ..compressionResult = _nativeCompressionResult()
        ..nativeCompressionGate = compressionGate;
      final chat = _chat(
        'in-place-baseline',
        gateway,
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
        client: MockClient((request) async {
          if (request.url.path == '/api/sessions/stored-chat') {
            return http.Response(
              jsonEncode({
                'session': {'id': 'stored-chat', 'message_count': 38},
              }),
              200,
            );
          }
          return http.Response('unexpected REST', 500);
        }),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();

      final compression = chat.compressDesktopSession();
      while (gateway.compressSessionCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final lookup = await DesktopCompressionFenceStore(storage: storage)
          .lookup(
            DesktopCompressionFenceScope(
              connectionId: 'in-place-baseline',
              profile: 'default',
              logicalSessionId: 'stored-chat',
            ),
          );
      expect(lookup.record?.messagesAtStart, 38);

      compressionGate.complete(gateway.compressionResult);
      await compression;
    },
  );

  test(
    'pending solo acepta usage.compressions creciente con un root exacto',
    () async {
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-native-pending-usage',
          'session_key': 'stored-chat',
          'info': {
            'usage': {'compressions': 1},
          },
        })
        ..compressionResult = _nativePendingCompressionResult();
      final chat = _chat(
        'native-compression-pending-usage',
        gateway,
        logicalSessionId: 'root-pending-usage',
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();

      await chat.compressDesktopSession();
      expect(chat.desktopCompressionInFlight, isTrue);

      gateway.emit('session.info', const {
        'info': {
          'usage': {'compressions': 2},
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(chat.desktopCompressionAwaitingReconciliation, isTrue);

      gateway.emit('session.info', const {
        'info': {
          '_lineage_root_id': 'foreign-pending-usage',
          'usage': {'compressions': 3},
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.desktopCompressionInFlight, isTrue);

      gateway.emit('session.info', const {
        'info': {
          '_lineage_root_id': 'root-pending-usage',
          'usage': {'compressions': 2},
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.desktopCompressionInFlight, isFalse);
      expect(chat.desktopCompressionAwaitingReconciliation, isFalse);
      expect(gateway.compressSessionCalls, 1);
    },
  );

  test(
    'pending fence survives new service and store before runtime acquisition',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final connection = _connection('durable-restart-connection');
      final firstGateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-native-dispose',
          'session_key': 'tip-before',
        })
        ..compressionResult = _nativePendingCompressionResult();
      final firstService = ActiveChatService(
        compressionFenceStore: DesktopCompressionFenceStore(
          storage: storage,
          attemptId: () => 'restart-attempt',
        ),
      );
      final first = firstService.attach(
        connection: connection,
        sessionId: 'stored-chat',
        logicalSessionId: 'root-restart',
        initialStoredSessionId: 'tip-before',
        sessionProfile: 'default',
        sessionTitle: 'Restart',
        desktopGateway: firstGateway,
        api: ApiClient(
          baseUrl: connection.baseUrl,
          apiKey: connection.apiKey,
          httpClient: MockClient(
            (_) async => http.Response('unavailable', 503),
          ),
        ),
        allowUnownedDesktopSnapshotForTesting: true,
        disableForegroundKeepAlive: true,
      );
      await first.loadMessages();
      await first.compressDesktopSession();
      expect(firstGateway.compressSessionCalls, 1);
      await firstGateway.close();
      await Future<void>.delayed(Duration.zero);
      firstService.release(connection.id, 'stored-chat', profile: 'default');
      final retainedAfterRelease =
          await DesktopCompressionFenceStore(storage: storage).lookup(
            DesktopCompressionFenceScope(
              connectionId: connection.id,
              profile: 'default',
              logicalSessionId: 'root-restart',
            ),
          );
      expect(retainedAfterRelease.isFenced, isTrue);
      firstService.dispose();

      final restartedGateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'must-not-resume',
          'session_key': 'tip-before',
        })
        ..compressionResult = _nativeCompressionResult();
      final restartedService = ActiveChatService(
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
      );
      addTearDown(restartedService.dispose);
      final restarted = restartedService.attach(
        connection: connection,
        sessionId: 'stored-chat',
        logicalSessionId: 'root-restart',
        initialStoredSessionId: 'tip-before',
        sessionProfile: 'default',
        sessionTitle: 'Restart',
        desktopGateway: restartedGateway,
        api: ApiClient(
          baseUrl: connection.baseUrl,
          apiKey: connection.apiKey,
          httpClient: MockClient(
            (_) async => http.Response('unavailable', 503),
          ),
        ),
        allowUnownedDesktopSnapshotForTesting: false,
        disableForegroundKeepAlive: true,
      );

      expect(restartedGateway.resumeExistingCalls, 0);
      expect(restartedGateway.createCalls, 0);
      await expectLater(
        restarted.compressDesktopSession(),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      await expectLater(
        restarted.send(
          fullText: 'blocked after restart',
          model: 'model-a',
          history: const [],
        ),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      expect(restartedGateway.resumeExistingCalls, 0);
      expect(restartedGateway.createCalls, 0);
      expect(restartedGateway.compressSessionCalls, 0);
      expect(restartedGateway.submitPromptCalls, 0);
    },
  );

  test(
    'armed crash blocks send and compression before runtime acquisition after restart',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final scope = DesktopCompressionFenceScope(
        connectionId: 'durable-send-connection',
        profile: 'private',
        logicalSessionId: 'root-send',
      );
      final seedStore = DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'send-attempt',
      );
      // Still inside its reconciliation window: an expired one is released.
      final armedAt = DateTime.now().millisecondsSinceEpoch;
      final armed = await seedStore.arm(
        scope,
        tipAtStart: 'tip-send',
        compressionsAtStart: null,
        createdAtMs: armedAt,
        reconcileUntilMs: armedAt + 600000,
      );
      expect(armed.claimed, isTrue);
      storage
        ..readCalls = 0
        ..firstReadGate = Completer<void>();

      final connection = _connection('durable-send-connection');
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'must-not-resume-send',
          'session_key': 'tip-send',
          'messages': <Object>[],
        });
      final service = ActiveChatService(
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
      );
      addTearDown(service.dispose);
      final chat = service.attach(
        connection: connection,
        sessionId: 'stored-chat',
        logicalSessionId: 'root-send',
        initialStoredSessionId: 'tip-send',
        sessionProfile: 'private',
        sessionTitle: 'Send',
        desktopGateway: gateway,
        api: ApiClient(
          baseUrl: connection.baseUrl,
          apiKey: connection.apiKey,
          httpClient: MockClient(
            (_) async => http.Response('unavailable', 503),
          ),
        ),
        disableForegroundKeepAlive: true,
      );

      final send = chat.send(
        fullText: 'PRIVATE_TRANSCRIPT_SENTINEL',
        model: 'model-a',
        history: const [],
        profile: 'private',
      );
      await expectLater(
        send,
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      await expectLater(
        chat.compressDesktopSession(),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      expect(gateway.resumeExistingCalls, 0);
      expect(gateway.resumeLegacyCalls, 0);
      expect(gateway.createCalls, 0);
      expect(gateway.submitPromptCalls, 0);
      expect(chat.internalMessagesForTesting, isEmpty);
      storage.firstReadGate!.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'resultado nativo de otro root falla antes de cambiar autoridad',
    () async {
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-native-foreign-root',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'mantener'},
            {'role': 'assistant', 'content': 'sin cambio'},
          ],
        })
        ..compressionResult = DesktopCompressionResult.fromJson({
          'status': 'compressed',
          'turn_isolation': true,
          'info': {
            'stored_session_id': 'foreign-tip',
            '_lineage_root_id': 'foreign-root',
          },
          'messages': [
            {'role': 'assistant', 'content': 'no debe aplicarse'},
          ],
        });
      final chat = _chat(
        'native-compression-foreign-root',
        gateway,
        logicalSessionId: 'expected-root',
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      final before = List<Map<String, dynamic>>.from(chat.messages);

      await expectLater(
        chat.compressDesktopSession(),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4004),
        ),
      );

      expect(chat.messages, before);
      expect(chat.storedSessionId, 'stored-chat');
      expect(gateway.slashExecCalls, 0);
      expect(gateway.commandDispatchCalls, 0);
    },
  );

  test(
    'compresión espera y reintenta la migración durable del tombstone',
    () async {
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-compress-durable-tombstone',
          'session_key': 'stored-chat',
          'messages': [
            {
              'message_id': 'cancelled-user-id',
              'role': 'user',
              'content': 'turno cancelado',
            },
            {
              'message_id': 'cancelled-answer-id',
              'role': 'assistant',
              'content': 'respuesta que Stop oculta',
            },
          ],
        })
        ..compressionResult = _nativeCompressionResult();
      final retryGate = Completer<void>();
      final persisted = <CancelledTurnTombstone>[];
      var persistCalls = 0;
      final chat = _chat(
        'compression-durable-tombstone',
        gateway,
        initialCancelledTurnTombstones: const [
          CancelledTurnTombstone(content: 'turno cancelado', firstUser: true),
        ],
        onCancelledTurn: (tombstone) async {
          persistCalls++;
          persisted.add(tombstone);
          if (persistCalls == 1) {
            throw StateError('secure storage temporarily unavailable');
          }
          await retryGate.future;
        },
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();
      while (persistCalls < 1) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(Duration.zero);

      final compression = chat.compressDesktopSession();
      while (persistCalls < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(gateway.compressSessionCalls, 0);
      retryGate.complete();

      final result = await compression;
      expect(result.accepted, DesktopCommandAcceptance.accepted);
      expect(gateway.compressSessionCalls, 1);
      expect(persisted.last.cancelledMessageId, 'cancelled-user-id');
    },
  );

  test('compresión acepta un Stop durable ligado solo por row id', () async {
    final gateway = _NativeCompressionGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-compress-row-tombstone',
        'session_key': 'stored-chat',
        'messages': [
          {'row_id': 73, 'role': 'user', 'content': 'turno detenido'},
          {'row_id': 74, 'role': 'assistant', 'content': 'respuesta cancelada'},
        ],
      })
      ..compressionResult = _nativeCompressionResult();
    final chat = _chat(
      'compression-row-tombstone',
      gateway,
      initialCancelledTurnTombstones: const [
        CancelledTurnTombstone(content: 'turno detenido', cancelledRowId: 73),
      ],
    );
    addTearDown(chat.dispose);

    await chat.loadMessages();
    final result = await chat.compressDesktopSession();

    expect(result.accepted, DesktopCommandAcceptance.accepted);
    expect(gateway.compressSessionCalls, 1);
  });

  test(
    'resultado de compresión no pisa un refresh nuevo mientras persiste metadata',
    () async {
      const initialRows = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'uno'},
        {'role': 'assistant', 'content': 'dos'},
      ];
      const refreshedRows = <Map<String, dynamic>>[
        {
          'message_id': 'refresh-user',
          'role': 'user',
          'content': 'estado posterior al refresh',
        },
        {
          'message_id': 'refresh-answer',
          'role': 'assistant',
          'content': 'respuesta posterior al refresh',
        },
      ];
      var storedRows = initialRows;
      final compressionGate = Completer<DesktopCompressionResult>();
      final persisted = <CancelledTurnTombstone>[];
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-compression-refresh-race',
          'session_key': 'stored-chat',
          'messages': initialRows,
        })
        ..compressionResult = _nativeCompressionResult()
        ..nativeCompressionGate = compressionGate;
      final chat = _chat(
        'compression-refresh-race',
        gateway,
        storedMessageLoader: (_, _) async => storedRows,
        onCancelledTurn: (tombstone) async => persisted.add(tombstone),
      );
      addTearDown(chat.dispose);
      await chat.loadMessages(expectedMessageCount: initialRows.length);

      final compression = chat.compressDesktopSession();
      while (gateway.compressSessionCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      // Simula un tombstone creado mientras el RPC remoto ya está en curso.
      // El resultado viejo no puede invalidarlo ni publicarse por encima de un
      // Refresh que ya ganó el epoch mientras el RPC seguía pendiente.
      await chat.cancel();
      expect(persisted, hasLength(1));
      expect(persisted.single.invalidated, isFalse);

      storedRows = refreshedRows;
      gateway.snapshot = _snapshot({
        'session_id': 'runtime-compression-refresh-race',
        'session_key': 'stored-chat',
        'messages': refreshedRows,
      });
      await chat.loadMessages(expectedMessageCount: refreshedRows.length);
      expect(
        chat.messages.map((message) => message['content']),
        contains('respuesta posterior al refresh'),
      );

      compressionGate.complete(gateway.compressionResult);
      await compression;

      expect(
        chat.messages.map((message) => message['content']),
        containsAll(const [
          'respuesta posterior al refresh',
          'estado posterior al refresh',
        ]),
      );
      expect(chat.storedSessionId, 'stored-chat');
      expect(persisted, hasLength(1));
      expect(persisted.single.invalidated, isFalse);
      expect(persisted.single.cancelledMessageId, isNull);
    },
  );

  test(
    'timeout ambiguo de session.compress no reintenta por otra ruta',
    () async {
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-native-timeout',
          'session_key': 'stored-chat',
        })
        ..compressionResult = _nativeCompressionResult()
        ..compressError = const TuiGatewayRpcError(
          'session.compress',
          'Timeout waiting for JSON-RPC response',
        );
      final chat = _chat('native-compression-timeout', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      await expectLater(
        chat.compressDesktopSession(),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (error) => error.method,
            'method',
            'session.compress',
          ),
        ),
      );

      expect(gateway.compressSessionCalls, 1);
      expect(gateway.slashExecCalls, 0);
      expect(gateway.commandDispatchCalls, 0);
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(chat.desktopCompressionAwaitingReconciliation, isTrue);
      expect(chat.desktopCompressionTransportUncertain, isTrue);
      await expectLater(
        chat.compressDesktopSession(),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      expect(gateway.compressSessionCalls, 1);

      gateway.emit('session.info', const {
        'info': {
          '_lineage_root_id': 'stored-chat',
          'stored_session_id': 'stored-native-timeout-tip',
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.storedSessionId, 'stored-native-timeout-tip');
      expect(chat.desktopCompressionInFlight, isFalse);
      expect(chat.desktopCompressionAwaitingReconciliation, isFalse);
      expect(chat.desktopCompressionTransportUncertain, isFalse);
    },
  );

  test('unclassified coded rejection retains its armed attempt', () async {
    final storage = _MemoryCompressionFenceStorage();
    final gateway = _NativeCompressionGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-definitive-reject',
        'session_key': 'stored-chat',
      })
      ..compressionResult = _nativeCompressionResult()
      ..compressError = const TuiGatewayRpcError(
        'session.compress',
        'request rejected',
        code: 4004,
      );
    final chat = _chat(
      'definitive-reject',
      gateway,
      compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
    );
    addTearDown(chat.dispose);
    await chat.loadMessages();

    await expectLater(
      chat.compressDesktopSession(),
      throwsA(
        isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4004),
      ),
    );
    gateway.compressError = null;
    await expectLater(chat.compressDesktopSession(), _lockHeldBusy);

    expect(gateway.compressSessionCalls, 1);
  });

  test(
    'timeout fence survives service and store recreation without a second RPC',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final connection = _connection('timeout-restart-connection');
      final firstGateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-timeout-restart',
          'session_key': 'tip-timeout',
        })
        ..compressionResult = _nativeCompressionResult()
        ..compressError = const TuiGatewayRpcError(
          'session.compress',
          'Timeout waiting for JSON-RPC response',
        );
      final firstService = ActiveChatService(
        compressionFenceStore: DesktopCompressionFenceStore(
          storage: storage,
          attemptId: () => 'timeout-restart-attempt',
        ),
      );
      final first = firstService.attach(
        connection: connection,
        sessionId: 'stored-chat',
        logicalSessionId: 'root-timeout-restart',
        initialStoredSessionId: 'tip-timeout',
        sessionProfile: 'default',
        sessionTitle: 'Timeout',
        desktopGateway: firstGateway,
        api: ApiClient(
          baseUrl: connection.baseUrl,
          apiKey: connection.apiKey,
          httpClient: MockClient(
            (_) async => http.Response('unavailable', 503),
          ),
        ),
        allowUnownedDesktopSnapshotForTesting: true,
        disableForegroundKeepAlive: true,
      );
      await first.loadMessages();
      await expectLater(
        first.compressDesktopSession(),
        throwsA(isA<TuiGatewayRpcError>()),
      );
      while (storage.writeCalls < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(storage.value, contains('transport_unknown'));
      firstService.dispose();

      final restartedGateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'must-not-resume-timeout',
          'session_key': 'tip-timeout',
        })
        ..compressionResult = _nativeCompressionResult();
      final restarted = ActiveChatService(
        compressionFenceStore: DesktopCompressionFenceStore(storage: storage),
      );
      addTearDown(restarted.dispose);
      final chat = restarted.attach(
        connection: connection,
        sessionId: 'stored-chat',
        logicalSessionId: 'root-timeout-restart',
        initialStoredSessionId: 'tip-timeout',
        sessionProfile: 'default',
        sessionTitle: 'Timeout',
        desktopGateway: restartedGateway,
        api: ApiClient(
          baseUrl: connection.baseUrl,
          apiKey: connection.apiKey,
          httpClient: MockClient(
            (_) async => http.Response('unavailable', 503),
          ),
        ),
        disableForegroundKeepAlive: true,
      );

      await expectLater(
        chat.compressDesktopSession(),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      await expectLater(
        chat.send(
          fullText: 'blocked after timeout restart',
          model: 'model-a',
          history: const [],
        ),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      expect(restartedGateway.resumeExistingCalls, 0);
      expect(restartedGateway.createCalls, 0);
      expect(restartedGateway.compressSessionCalls, 0);
      expect(restartedGateway.submitPromptCalls, 0);
    },
  );

  test(
    'timeout legacy de slash conserva la supresión sin command.dispatch',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-legacy-timeout',
          'session_key': 'stored-chat',
        })
        ..slashError = TimeoutException('transport lost after slash.exec');
      final chat = _chat('legacy-compression-timeout', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      final result = await chat.compressDesktopSession();

      expect(result.accepted, DesktopCommandAcceptance.unknown);
      expect(result.failure?.kind, CommandFailureKind.timeout);
      expect(gateway.slashExecCalls, 1);
      expect(gateway.commandDispatchCalls, 0);
      expect(chat.desktopCompressionInFlight, isTrue);
      expect(chat.desktopCompressionTransportUncertain, isTrue);
      await expectLater(
        chat.compressDesktopSession(),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );
      expect(gateway.slashExecCalls, 1);

      gateway.emit('status.update', const {
        'kind': 'compacted',
        'info': {
          '_lineage_root_id': 'stored-chat',
          'stored_session_id': 'stored-legacy-timeout-tip',
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.desktopCompressionInFlight, isFalse);
      expect(chat.desktopCompressionTransportUncertain, isFalse);
    },
  );

  test(
    'method not found de session.compress usa compatibilidad antigua una vez',
    () async {
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-native-legacy',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'uno'},
            {'role': 'assistant', 'content': 'dos'},
          ],
        })
        ..snapshotAfterCommand = _compressedSnapshot()
        ..compressionResult = _nativeCompressionResult()
        ..compressError = const TuiGatewayRpcError(
          'session.compress',
          'Method not found',
          code: -32601,
        );
      final chat = _chat('native-compression-legacy', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      final result = await chat.compressDesktopSession();

      expect(result.attemptedRoute, DesktopCommandRoute.slashExec);
      expect(gateway.compressSessionCalls, 1);
      expect(gateway.slashExecCalls, 1);
      expect(gateway.commandDispatchCalls, 0);
    },
  );

  test(
    'reconciliación legacy de compresión sanea error inflight remoto',
    () async {
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-compression-private-error',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'historial público'},
          ],
        })
        ..snapshotAfterCommand = _snapshot({
          'session_id': 'runtime-compression-private-error',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'historial público'},
          ],
          'inflight': {
            'user': 'continúa',
            'assistant': '',
            'streaming': false,
            'error': 'PRIVATE_COMPRESSION_SNAPSHOT_ERROR',
            'status': 'error',
            'recoverable': true,
          },
        })
        ..compressionResult = _nativeCompressionResult()
        ..compressError = const TuiGatewayRpcError(
          'session.compress',
          'Method not found',
          code: -32601,
        );
      final chat = _chat('compression-private-snapshot', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      final result = await chat.compressDesktopSession();

      expect(result.accepted, DesktopCommandAcceptance.accepted);
      expect(gateway.compressSessionCalls, 1);
      expect(gateway.slashExecCalls, 1);
      final serialized = chat.messages.toString();
      expect(serialized, isNot(contains('PRIVATE_COMPRESSION_SNAPSHOT_ERROR')));
      expect(serialized, contains('historial público'));
      expect(
        chat.messages.where((m) => m['role'] == 'assistant_error'),
        isEmpty,
      );
      expect(chat.desktopCompressionInFlight, isTrue);
    },
  );

  test(
    'refresh durante method-not-found nativo cancela el fallback remoto',
    () async {
      const initialRows = <Map<String, dynamic>>[
        {'message_id': 'initial-user', 'role': 'user', 'content': 'uno'},
        {'message_id': 'initial-answer', 'role': 'assistant', 'content': 'dos'},
      ];
      const refreshedRows = <Map<String, dynamic>>[
        {
          'message_id': 'refreshed-user',
          'role': 'user',
          'content': 'estado nuevo',
        },
        {
          'message_id': 'refreshed-answer',
          'role': 'assistant',
          'content': 'respuesta nueva',
        },
      ];
      var storedRows = initialRows;
      final nativeGate = Completer<DesktopCompressionResult>();
      final gateway = _NativeCompressionGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-native-fallback-race',
          'session_key': 'stored-chat',
          'messages': initialRows,
        })
        ..compressionResult = _nativeCompressionResult()
        ..nativeCompressionGate = nativeGate;
      final chat = _chat(
        'native-fallback-race',
        gateway,
        storedMessageLoader: (_, _) async => storedRows,
      );
      addTearDown(chat.dispose);
      await chat.loadMessages(expectedMessageCount: initialRows.length);

      final compression = chat.compressDesktopSession();
      while (gateway.compressSessionCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      storedRows = refreshedRows;
      gateway.snapshot = _snapshot({
        'session_id': 'runtime-native-fallback-race',
        'session_key': 'stored-chat',
        'messages': refreshedRows,
      });
      await chat.loadMessages(expectedMessageCount: refreshedRows.length);

      nativeGate.completeError(
        const TuiGatewayRpcError(
          'session.compress',
          'Method not found',
          code: -32601,
        ),
      );
      await expectLater(
        compression,
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
        ),
      );

      expect(gateway.slashExecCalls, 0);
      expect(gateway.commandDispatchCalls, 0);
      expect(
        chat.messages.map((message) => message['content']),
        containsAll(const ['estado nuevo', 'respuesta nueva']),
      );
    },
  );

  test('legacy acceptance does not project an uncorrelated snapshot', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-compress',
        'session_key': 'stored-chat',
        'messages': [
          {'role': 'user', 'content': 'uno'},
          {'role': 'assistant', 'content': 'dos'},
          {'role': 'user', 'content': 'tres'},
          {'role': 'assistant', 'content': 'cuatro'},
        ],
      })
      ..snapshotAfterCommand = _compressedSnapshot();
    final chat = _chat('compression-success', gateway);
    addTearDown(chat.dispose);
    await chat.loadMessages();

    final result = await chat.compressDesktopSession(
      focusTopic: 'decisiones de release',
    );

    expect(result.accepted, DesktopCommandAcceptance.accepted);
    expect(result.attemptedRoute, DesktopCommandRoute.slashExec);
    expect(result.fallbackUsed, isFalse);
    expect(gateway.slashExecCalls, 1);
    expect(gateway.commandDispatchCalls, 0);
    expect(gateway.slashRuntimeId, 'runtime-compress');
    expect(gateway.slashCommand, 'compress decisiones de release');
    expect(chat.storedSessionId, 'stored-chat');
    expect(chat.messages, hasLength(4));
    expect(chat.messages.first['content'], 'cuatro');
    expect(chat.messages.last['content'], 'uno');
    expect(chat.desktopCompressionInFlight, isTrue);
  });

  test(
    'comando remoto rechaza argumentos mayores de 500 antes del RPC',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-command-limit',
          'session_key': 'stored-chat',
        });
      final chat = _chat('command-limit', gateway);
      addTearDown(chat.dispose);
      await chat.loadMessages();

      await expectLater(
        chat.executeDesktopSlash(
          'usage',
          arg: List<String>.filled(501, 'x').join(),
        ),
        throwsA(
          isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4004),
        ),
      );
      expect(gateway.slashExecCalls, 0);
    },
  );

  test('compresión bloquea otra compresión y nuevos turnos', () async {
    final gate = Completer<DesktopCommandRpcResult>();
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-compress-busy',
        'session_key': 'stored-chat',
        'messages': [
          {'role': 'user', 'content': 'uno'},
          {'role': 'assistant', 'content': 'dos'},
          {'role': 'user', 'content': 'tres'},
          {'role': 'assistant', 'content': 'cuatro'},
        ],
      })
      ..snapshotAfterCommand = _compressedSnapshot()
      ..compressionGate = gate;
    final chat = _chat('compression-busy', gateway);
    addTearDown(chat.dispose);
    await chat.loadMessages();

    final running = chat.compressDesktopSession();
    await Future<void>.delayed(Duration.zero);
    expect(chat.desktopCompressionInFlight, isTrue);

    await expectLater(
      chat.compressDesktopSession(),
      throwsA(
        isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
      ),
    );
    await expectLater(
      chat.send(
        fullText: 'no enviar',
        model: 'hermes-agent',
        history: const [],
      ),
      throwsA(
        isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
      ),
    );
    await expectLater(
      chat.steer('no steering durante compresion manual'),
      throwsA(
        isA<TuiGatewayRpcError>().having((error) => error.code, 'code', 4009),
      ),
    );
    expect(gateway.steerCalls, 0);

    gate.complete(
      const DesktopCommandRpcResult(
        kind: DesktopCommandDispatchKind.none,
        accepted: DesktopCommandAcceptance.accepted,
      ),
    );
    await running;
    expect(chat.desktopCompressionInFlight, isTrue);
  });

  test(
    'artefactos se indexan al abrir sin otra lectura ni transcript textual',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-artifacts',
          'session_key': 'stored-chat',
          'messages': [
            {
              'role': 'user',
              'message_id': 'message-text',
              'content': 'solo texto',
            },
            {
              'role': 'assistant',
              'message_id': 'message-artifact',
              'content': [
                {'type': 'text', 'text': 'resultado'},
                {
                  'type': 'document',
                  'artifact_id': 'artifact-1',
                  'name': 'resultado.pdf',
                },
              ],
            },
          ],
        });
      final chat = _chat(
        'resume-artifacts',
        gateway,
        logicalSessionId: 'lineage-root',
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      expect(chat.resolvedArtifactIndex, isNull);
      expect(gateway.resumeExistingCalls, 1);
      final artifacts = chat.resolveSessionArtifacts();
      final firstIndex = chat.resolvedArtifactIndex;

      expect(artifacts.single.id, 'artifact-1');
      expect(artifacts.single.primarySource.messageId, 'message-artifact');
      expect(firstIndex?.buildStats.inspectedMessages, 1);
      expect(firstIndex?.revision.scope.logicalSessionId, 'lineage-root');
      expect(
        chat.internalMessagesForTesting.first['_desktopMessageId'],
        'message-artifact',
      );
      expect(chat.messages.first.containsKey('_desktopMessageId'), isFalse);
      expect(chat.resolveSessionArtifacts(), same(artifacts));
      expect(chat.resolvedArtifactIndex, same(firstIndex));
      await chat.loadMessages();
      expect(chat.resolveSessionArtifacts(), same(artifacts));
      expect(chat.resolvedArtifactIndex, same(firstIndex));
      expect(gateway.resumeExistingCalls, 2);
    },
  );

  test('4007 al cargar usa REST pero nunca crea', () async {
    final gateway = _SnapshotGateway()
      ..resumeExistingError = const TuiGatewayRpcError(
        'session.resume',
        'not found',
        code: 4007,
      );
    final chat = _chat(
      'resume-fallback',
      gateway,
      client: MockClient(
        (_) async => http.Response(
          '{"data":[{"role":"assistant","content":"REST"}]}',
          200,
        ),
      ),
    );
    addTearDown(chat.dispose);

    await chat.loadMessages();

    expect(chat.assistantContent, 'REST');
    expect(gateway.resumeExistingCalls, 1);
    expect(gateway.resumeLegacyCalls, 0);
    expect(gateway.createCalls, 0);
  });

  test(
    'fallback REST separa texto renderizable de artefactos estructurados',
    () async {
      final gateway = _SnapshotGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'not found',
          code: 4007,
        );
      final chat = _chat(
        'resume-rest-artifact',
        gateway,
        logicalSessionId: 'lineage-rest',
        client: MockClient(
          (_) async => http.Response(
            '''{"data":[{"role":"assistant","message_id":"message-rest","content":[{"type":"text","text":"resultado"},{"type":"file","artifact_id":"artifact-rest","name":"resultado.pdf"}]}]}''',
            200,
          ),
        ),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      expect(chat.messages.single['content'], 'resultado');
      expect(
        chat.messages.every((message) => message['content'] is String),
        isTrue,
      );
      expect(ChatRenderProjection.build(chat.messages).units, hasLength(1));
      final artifact = chat.resolveSessionArtifacts().single;
      expect(artifact.id, 'artifact-rest');
      expect(artifact.primarySource.messageId, 'message-rest');
      expect(gateway.createCalls, 0);
    },
  );

  test(
    'REST asocia image_generate por tool_call_id con el asistente final',
    () async {
      final gateway = _SnapshotGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'not found',
          code: 4007,
        );
      final chat = _chat(
        'resume-generated-image-rest',
        gateway,
        client: MockClient(
          (_) async => http.Response(
            '''{"data":[{"id":1,"role":"user","content":"genera un pavo real"},{"id":2,"role":"assistant","content":"","tool_calls":[{"id":"call-image-1","type":"function","function":{"name":"image_generate","arguments":"{\\"prompt\\":\\"peacock\\"}"}}]},{"id":3,"role":"tool","tool_call_id":"call-image-1","tool_name":"image_generate","content":"{\\"success\\":true,\\"host_image\\":\\"/home/hermes/.hermes/cache/images/peacock.png\\",\\"image\\":\\"/home/hermes/.hermes/cache/images/peacock.png\\",\\"agent_visible_image\\":\\"/sandbox/cache/peacock.png\\"}"},{"id":4,"role":"assistant","content":"Aquí tienes la imagen."}]}''',
            200,
          ),
        ),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      final finalAssistant = chat.messages.singleWhere(
        (message) => message['id'] == 4,
      );
      final refs = _generatedImageRefs(finalAssistant);
      expect(refs, hasLength(1));
      expect(refs.single['basename'], 'peacock.png');
      expect(refs.single['tool_call_id'], 'call-image-1');
      expect(chat.messages.toString(), isNot(contains('/home/hermes')));
      expect(chat.messages.toString(), isNot(contains('/sandbox/cache')));
      expect(finalAssistant['content'], 'Aquí tienes la imagen.');
      expect(
        chat.messages
            .where((message) => message['id'] != 4)
            .expand(_generatedImageRefs),
        isEmpty,
      );
    },
  );

  test(
    'REST asocia video_generate por tool_call_id con el asistente final',
    () async {
      final gateway = _SnapshotGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'not found',
          code: 4007,
        );
      final chat = _chat(
        'resume-generated-video-rest',
        gateway,
        client: MockClient(
          (_) async => http.Response(
            '''{"data":[{"id":1,"role":"user","content":"genera un vídeo"},{"id":2,"role":"assistant","content":"","tool_calls":[{"id":"call-video-1","type":"function","function":{"name":"video_generate","arguments":"{}"}}]},{"id":3,"role":"tool","tool_call_id":"call-video-1","tool_name":"video_generate","content":"{\\"success\\":true,\\"video\\":\\"/home/hermes/.hermes/cache/videos/generated.mp4\\"}"},{"id":4,"role":"assistant","content":"Aquí está el vídeo."}]}''',
            200,
          ),
        ),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      final finalAssistant = chat.messages.singleWhere(
        (message) => message['id'] == 4,
      );
      final refs = _generatedImageRefs(finalAssistant);
      expect(refs, hasLength(1));
      expect(refs.single['media_kind'], 'video');
      expect(refs.single['kind'], 'serverPath');
      expect(refs.single['source'], endsWith('/cache/videos/generated.mp4'));
      expect(refs.single['tool_call_id'], 'call-video-1');
      expect(finalAssistant['content'], 'Aquí está el vídeo.');
      expect(
        chat.messages
            .where((message) => message['id'] != 4)
            .expand(_generatedImageRefs),
        isEmpty,
      );
    },
  );

  test('REST rehidrata image_generate con fuente HTTPS', () async {
    final gateway = _SnapshotGateway()
      ..resumeExistingError = const TuiGatewayRpcError(
        'session.resume',
        'not found',
        code: 4007,
      );
    final chat = _chat(
      'resume-generated-image-https',
      gateway,
      client: MockClient(
        (_) async => http.Response(
          '''{"data":[{"id":1,"role":"user","content":"genera una imagen"},{"id":2,"role":"assistant","content":"","tool_calls":[{"id":"call-image-https","type":"function","function":{"name":"image_generate","arguments":"{}"}}]},{"id":3,"role":"tool","tool_call_id":"call-image-https","tool_name":"image_generate","content":"{\\"success\\":true,\\"image\\":\\"https://cdn.example/generated.png?sig=private#preview\\"}"},{"id":4,"role":"assistant","content":"Aquí está."}]}''',
          200,
        ),
      ),
    );
    addTearDown(chat.dispose);

    await chat.loadMessages();

    final refs = _generatedImageRefs(
      chat.messages.singleWhere((message) => message['id'] == 4),
    );
    expect(refs, hasLength(1));
    expect(refs.single['kind'], 'https');
    expect(
      refs.single['source'],
      'https://cdn.example/generated.png?sig=private',
    );
    expect(refs.single['tool_call_id'], 'call-image-https');
  });

  test(
    'REST no hereda un resultado image_generate huerfano al turno siguiente',
    () async {
      final gateway = _SnapshotGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'not found',
          code: 4007,
        );
      final chat = _chat(
        'resume-generated-image-orphan',
        gateway,
        client: MockClient(
          (_) async => http.Response(
            '''{"data":[{"id":1,"role":"user","content":"genera una imagen"},{"id":2,"role":"assistant","content":"","tool_calls":[{"id":"call-image-orphan","type":"function","function":{"name":"image_generate","arguments":"{\\"prompt\\":\\"orphan\\"}"}}]},{"id":3,"role":"tool","tool_call_id":"call-image-orphan","tool_name":"image_generate","content":"{\\"success\\":true,\\"host_image\\":\\"/home/hermes/.hermes/cache/images/orphan.png\\"}"},{"id":4,"role":"user","content":"explica el estado"},{"id":5,"role":"assistant","content":"No hay una imagen final para el turno anterior."}]}''',
            200,
          ),
        ),
      );
      addTearDown(chat.dispose);

      await chat.loadMessages();

      final nextAssistant = chat.messages.singleWhere(
        (message) => message['id'] == 5,
      );
      expect(
        nextAssistant['content'],
        'No hay una imagen final para el turno anterior.',
      );
      expect(_generatedImageRefs(nextAssistant), isEmpty);
      expect(chat.messages.expand(_generatedImageRefs), isEmpty);
    },
  );

  test('snapshot con image_generate pendiente no inventa una imagen', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-image-pending',
        'session_key': 'stored-chat',
        'messages': [
          {'role': 'user', 'content': 'genera una imagen'},
          {
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'call-image-pending',
                'type': 'function',
                'function': {
                  'name': 'image_generate',
                  'arguments': '{"prompt":"pending"}',
                },
              },
            ],
          },
        ],
      });
    final chat = _chat('resume-generated-image-pending', gateway);
    addTearDown(chat.dispose);

    await chat.loadMessages();

    expect(chat.messages.expand(_generatedImageRefs), isEmpty);
    expect(
      chat.messages.any((message) => message['tool_calls'] is List),
      isFalse,
    );
  });

  test('snapshot tardío tras dispose no muta mensajes', () async {
    final gate = Completer<DesktopSessionSnapshot>();
    final gateway = _SnapshotGateway()..resumeGate = gate;
    final chat = _chat('resume-dispose', gateway);
    chat.internalMessagesForTesting = [
      {'role': 'assistant', 'content': 'conservar'},
    ];

    final loading = chat.loadMessages();
    await Future<void>.delayed(Duration.zero);
    chat.dispose();
    gate.complete(
      _snapshot({
        'session_id': 'runtime-late',
        'session_key': 'stored-chat',
        'messages': [
          {'role': 'assistant', 'text': 'tardío'},
        ],
      }),
    );
    await loading;

    expect(chat.assistantContent, 'conservar');
    expect(chat.messagesLoaded, isFalse);
  });

  test('resume restores pending batch clarify from snapshot', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-clarify',
        'session_key': 'stored-chat',
        'messages': [
          {'role': 'user', 'content': 'hola'},
        ],
        'pending_clarify': {
          'request_id': 'batch-resume',
          'questions': [
            {
              'qid': 'q0',
              'question': '¿Bebida?',
              'choices': ['Coffee', 'Tea'],
            },
          ],
        },
      });
    final chat = _chat('resume-clarify', gateway);
    addTearDown(chat.dispose);

    await chat.loadMessages();

    expect(chat.pendingInteractivePrompt, isNotNull);
    final request =
        chat.pendingInteractivePrompt!.request! as ClarifyPromptRequest;
    expect(request.isBatch, isTrue);
    expect(request.questions.single.qid, 'q0');
    expect(request.questions.single.question, '¿Bebida?');
  });

  test('resume restores locked answers inside pending clarify', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-locked',
        'session_key': 'stored-chat',
        'messages': [
          {'role': 'user', 'content': 'hola'},
        ],
        'pending_clarify': {
          'request_id': 'batch-locked',
          'questions': [
            {
              'qid': 'q0',
              'question': '¿Bebida?',
              'choices': ['Coffee', 'Tea'],
            },
          ],
          'answers': {'q0': 'Coffee'},
        },
      });
    final chat = _chat('resume-locked', gateway);
    addTearDown(chat.dispose);

    await chat.loadMessages();

    final request =
        chat.pendingInteractivePrompt!.request! as ClarifyPromptRequest;
    expect(request.lockedAnswers, {'q0': 'Coffee'});
  });

  test(
    'authoritative snapshot replaces a different pending request in its runtime',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-authoritative',
          'session_key': 'stored-chat',
          'messages': const <Object>[],
          'pending_clarify': {
            'request_id': 'old-request',
            'questions': [
              {
                'qid': 'old-q',
                'question': 'Old?',
                'choices': ['A', 'B'],
              },
            ],
          },
        });
      final chat = _chat('resume-authoritative', gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages();
      expect(chat.pendingInteractivePrompt?.key.requestId, 'old-request');

      gateway.snapshot = _snapshot({
        'session_id': 'runtime-authoritative',
        'session_key': 'stored-chat',
        'messages': const <Object>[],
        'pending_clarify': {
          'request_id': 'new-request',
          'questions': [
            {
              'qid': 'new-q',
              'question': 'New?',
              'choices': ['C', 'D'],
            },
          ],
        },
      });
      await chat.loadMessages();

      expect(chat.pendingInteractivePrompt?.key.requestId, 'new-request');
      expect(
        chat.interactivePrompts.entries.entries
            .where(
              (entry) =>
                  entry.key.runtimeSessionId == 'runtime-authoritative' &&
                  entry.value.status == InteractivePromptStatus.pending,
            )
            .map((entry) => entry.key.requestId),
        ['new-request'],
      );
    },
  );

  test('authoritative conflicting definition fails closed', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-conflict',
        'session_key': 'stored-chat',
        'messages': const <Object>[],
        'pending_clarify': {
          'request_id': 'same-request',
          'questions': [
            {
              'qid': 'q0',
              'question': 'Original?',
              'choices': ['A', 'B'],
            },
          ],
        },
      });
    final chat = _chat('resume-conflict', gateway);
    addTearDown(chat.dispose);

    await chat.loadMessages();
    expect(chat.pendingInteractivePrompt, isNotNull);

    gateway.snapshot = _snapshot({
      'session_id': 'runtime-conflict',
      'session_key': 'stored-chat',
      'messages': const <Object>[],
      'pending_clarify': {
        'request_id': 'same-request',
        'questions': [
          {
            'qid': 'q0',
            'question': 'Changed?',
            'choices': ['A', 'B'],
          },
        ],
      },
    });
    await chat.loadMessages();

    expect(chat.pendingInteractivePrompt, isNull);
  });

  test('explicit empty pending_clarify clears the local request', () async {
    final gateway = _SnapshotGateway()
      ..snapshot = _snapshot({
        'session_id': 'runtime-cleared',
        'session_key': 'stored-chat',
        'messages': const <Object>[],
        'pending_clarify': {
          'request_id': 'request-to-clear',
          'questions': [
            {
              'qid': 'q0',
              'question': 'Pending?',
              'choices': ['A', 'B'],
            },
          ],
        },
      });
    final chat = _chat('resume-cleared', gateway);
    addTearDown(chat.dispose);

    await chat.loadMessages();
    expect(chat.pendingInteractivePrompt, isNotNull);

    gateway.snapshot = _snapshot({
      'session_id': 'runtime-cleared',
      'session_key': 'stored-chat',
      'messages': const <Object>[],
      'pending_clarify': null,
    });
    await chat.loadMessages();

    expect(chat.pendingInteractivePrompt, isNull);
  });

  test(
    'malformed authoritative pending_clarify expires the local clarify',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-malformed-authority',
          'stored_session_id': 'stored-malformed-authority',
          'created': false,
          'pending_clarify': {
            'request_id': 'clarify-old',
            'question': '¿Pregunta anterior?',
          },
        });
      final chat = _chat(
        'conn-malformed-authority',
        gateway,
        sessionId: 'stored-malformed-authority',
      );
      addTearDown(chat.dispose);
      await chat.loadMessages();
      final oldKey = chat.pendingInteractivePrompt!.key;

      gateway.snapshot = _snapshot({
        'session_id': 'runtime-malformed-authority',
        'stored_session_id': 'stored-malformed-authority',
        'created': false,
        'pending_clarify': {
          'request_id': 'clarify-old',
          'questions': 'not-a-list',
        },
      });
      await chat.loadMessages();

      expect(chat.pendingInteractivePrompt, isNull);
      expect(
        chat.interactivePrompts[oldKey]?.status,
        InteractivePromptStatus.expired,
      );
    },
  );

  test(
    'snapshot without pending_clarify does not erase a restored clarify',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-no-clarify',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'content': 'hola'},
          ],
          'pending_clarify': {
            'request_id': 'restored-batch',
            'questions': [
              {
                'qid': 'q0',
                'question': '¿Bebida?',
                'choices': ['Coffee', 'Tea'],
              },
            ],
          },
        });
      final chat = _chat('resume-no-clarify', gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages();
      expect(chat.pendingInteractivePrompt, isNotNull);

      gateway.snapshot = _snapshot({
        'session_id': 'runtime-no-clarify',
        'session_key': 'stored-chat',
        'messages': [
          {'role': 'user', 'content': 'hola'},
        ],
      });
      await chat.loadMessages();

      expect(chat.pendingInteractivePrompt, isNotNull);
      final request =
          chat.pendingInteractivePrompt!.request! as ClarifyPromptRequest;
      expect(request.questions.single.qid, 'q0');
    },
  );

  test(
    'REGRESSION_COMP2A arm invalidation cleans only original authority attempt',
    () async {
      final storage = _MemoryCompressionFenceStorage();
      final foreign = _lockHeldFenceStore(storage, 'attempt-B');
      await foreign.arm(
        DesktopCompressionFenceScope(
          connectionId: 'authority-arm-profile',
          profile: 'profile-B',
          logicalSessionId: 'stored-chat',
        ),
        tipAtStart: 'stored-B',
        compressionsAtStart: null,
        createdAtMs: 1,
        reconcileUntilMs: 2,
      );
      final gateway = _lockHeldGateway('runtime-authority-arm');
      final chat = _chat(
        'authority-arm-profile',
        gateway,
        compressionFenceStore: _lockHeldFenceStore(storage, 'attempt-A'),
      );
      addTearDown(chat.dispose);
      storage
        ..writeGate = Completer<void>()
        ..writeEntered = Completer<void>();

      final pending = chat.compressDesktopSessionForPresentation();
      await storage.writeEntered!.future;
      expect(chat.bindSessionProfile('profile-B'), 'profile-B');
      storage.writeGate!.complete();
      final presentation = await pending;

      expect(gateway.compressSessionCalls, 0);
      expect(gateway.slashExecCalls + gateway.commandDispatchCalls, 0);
      expect(presentation.failure, isA<TuiGatewayRpcError>());
      expect(storage.value, isNot(contains('attempt-A')));
      expect(storage.value, contains('attempt-B'));
      expect(chat.desktopCompressionInFlight, isFalse);
    },
  );
}
