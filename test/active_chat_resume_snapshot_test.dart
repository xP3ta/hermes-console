import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';
import 'package:hermes_android/core/models/desktop_compression_result.dart';
import 'package:hermes_android/core/models/desktop_context_breakdown.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/screens/chat_render_projection.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _SnapshotGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopCommandGateway,
        HermesDesktopContextUsageGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  DesktopSessionSnapshot? snapshot;
  DesktopSessionSnapshot? omittedSnapshot;
  DesktopSessionSnapshot? deferredSnapshot;
  Object? resumeExistingError;
  Completer<DesktopSessionSnapshot>? resumeGate;
  final List<Completer<DesktopSessionSnapshot>> resumeGates = [];
  DesktopSessionSnapshot? createSnapshot;
  int resumeExistingCalls = 0;
  int resumeLegacyCalls = 0;
  int createCalls = 0;
  int slashExecCalls = 0;
  int commandDispatchCalls = 0;
  int steerCalls = 0;
  int contextBreakdownCalls = 0;
  String? slashRuntimeId;
  String? slashCommand;
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
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

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
  }) async {}

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
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

class _NativeCompressionGateway extends _SnapshotGateway
    implements HermesDesktopCompressionGateway {
  int compressSessionCalls = 0;
  String? compressRuntimeId;
  String? compressFocusTopic;
  Object? compressError;
  late DesktopCompressionResult compressionResult;

  @override
  Future<DesktopCompressionResult> compressSession(
    String runtimeSessionId, {
    String focusTopic = '',
  }) async {
    compressSessionCalls += 1;
    compressRuntimeId = runtimeSessionId;
    compressFocusTopic = focusTopic;
    if (compressError case final error?) throw error;
    return compressionResult;
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

ActiveChat _chat(
  String id,
  _SnapshotGateway gateway, {
  http.Client? client,
  String? logicalSessionId,
  String sessionId = 'stored-chat',
  StoredSessionMessageLoader? storedMessageLoader,
  List<SteerProjection> initialSteerProjections = const [],
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
  storedMessageLoader: storedMessageLoader,
  initialSteerProjections: initialSteerProjections,
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
    'reconexión conserva redirected y queued sin pérdida ni duplicado',
    () async {
      final gateway = _SnapshotGateway()
        ..snapshot = _snapshot({
          'session_id': 'runtime-reconnect-corrections',
          'session_key': 'stored-chat',
          'messages': [
            {'role': 'user', 'text': 'haz la auditoría'},
          ],
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
        'y documéntala',
        'trabajando',
      ]);
      expect(
        chat.messages.where((message) => message['_steer'] == true),
        hasLength(1),
      );
      expect(chat.queuedMessages, ['después publícala']);
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
            {'role': 'assistant', 'content': 'Respuesta snapshot'},
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
          {'role': 'user', 'content': raw},
          {'role': 'assistant', 'content': 'Respuesta REST autoritativa'},
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

    chat.messages = [
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
      ..resumeGates.addAll([resumeFirst, resumeSecond]);
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
    await Future<void>.delayed(Duration.zero);
    final newLoad = chat.loadMessages(expectedMessageCount: 2);
    await Future<void>.delayed(Duration.zero);

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
      chat.messages = [
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
          'error': 'model call failed: 500',
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
    expect(chat.messages.first['content'], 'model call failed: 500');
    expect(chat.messages.first['recoverable'], isTrue);
    expect(chat.messages[1]['content'], 'respuesta parcial');
    expect(chat.messages[1]['_cancelled'], isTrue);
  });

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
      chat.messages = [
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

    chat.cancel();

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
      expect(chat.messages, hasLength(2));
      expect(chat.messages.first['content'], 'Contexto nativo listo');
      expect(chat.messages.last['content'], 'Resumen nativo durable');
      expect(chat.desktopCompressionInFlight, isFalse);
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
      expect(chat.desktopCompressionInFlight, isFalse);
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
    'compresión adopta transcript, métricas e id durable autoritativos',
    () async {
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
      expect(chat.storedSessionId, 'stored-compressed');
      expect(chat.desktopRuntimeInfo.usage?.contextUsed, 3500);
      expect(chat.messages, hasLength(2));
      expect(chat.messages.first['content'], 'Contexto listo');
      expect(chat.messages.last['content'], 'Resumen durable');
      expect(chat.desktopCompressionInFlight, isFalse);
    },
  );

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
    expect(chat.desktopCompressionInFlight, isFalse);
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
      expect(chat.messages.first['_desktopMessageId'], 'message-artifact');
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
      expect(finalAssistant['content'], 'Aquí tienes la imagen.');
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
      isTrue,
    );
  });

  test('snapshot tardío tras dispose no muta mensajes', () async {
    final gate = Completer<DesktopSessionSnapshot>();
    final gateway = _SnapshotGateway()..resumeGate = gate;
    final chat = _chat('resume-dispose', gateway);
    chat.messages = [
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
}
