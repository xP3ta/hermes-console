// Slice S-A «Terminal authority» (spec 061, addendum-desktop-parity §2.1).
//
// Hermes Desktop polls `session.active_list` whether or not a turn is
// streaming and treats the disappearance of a runtime it saw live as the
// terminal fact the lost events never delivered
// (`rehydrateLiveSessionStatuses`). Console did the opposite: it disabled the
// passive probe while streaming, so nothing could ever contradict a stuck
// «working» flag. These tests pin the corrected policy:
//
//   * the roster probe runs while a turn is live;
//   * a runtime seen live and then absent from two consecutive complete
//     rosters settles the turn, sealing open tool parts and writing no error
//     bubble;
//   * a single absence, a failed probe, a malformed roster, a runtime never
//     seen live and a runtime still in the roster settle nothing;
//   * a durable snapshot that is neither failed nor running closes a stale
//     running state.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _runtimeId = 'runtime-terminal-authority';
const _storedId = 'stored-terminal-authority';

SavedConnection _connection(String id) => SavedConnection(
  id: id,
  label: 'Terminal authority',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

DesktopActiveSessionList _liveRoster({String status = 'working'}) =>
    DesktopActiveSessionList(
      sessions: [
        DesktopActiveSession(
          runtimeSessionId: _runtimeId,
          storedSessionId: _storedId,
          status: status,
        ),
      ],
    );

const _emptyRoster = DesktopActiveSessionList();
const _malformedRoster = DesktopActiveSessionList(hasMalformedRows: true);

const _durableRows = <Map<String, dynamic>>[
  {'message_id': 'durable-user', 'role': 'user', 'content': 'prompt'},
  {
    'message_id': 'durable-assistant',
    'role': 'assistant',
    'content': 'respuesta durable',
  },
];

/// Snapshot durable completo y bien formado: ni fallido ni corriendo.
DesktopSessionSnapshot _finishedSnapshot() => DesktopSessionSnapshot.fromJson(
  const {
    'session_id': _runtimeId,
    'stored_session_id': _storedId,
    'running': false,
    'status': 'completed',
    'message_count': 2,
    'messages': _durableRows,
  },
  requestedStoredSessionId: _storedId,
  created: false,
  method: 'session.resume',
);

class _TerminalAuthorityGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSessionActivityGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<String> calls = [];
  int activeListCalls = 0;
  Object? activeListError;
  Completer<DesktopActiveSessionList>? activeListGate;
  DesktopActiveSessionList activeList = _emptyRoster;
  DesktopSessionSnapshot? snapshot;

  DesktopSessionSnapshot get _binding =>
      snapshot ??
      const DesktopSessionBinding(
        runtimeSessionId: _runtimeId,
        storedSessionId: _storedId,
        created: false,
      );

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
    return _binding;
  }

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async {
    calls.add('activate:$runtimeSessionId');
    return _binding;
  }

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async {
    activeListCalls += 1;
    final gate = activeListGate;
    if (gate != null) {
      activeListGate = null;
      return gate.future;
    }
    if (activeListError case final error?) throw error;
    return activeList;
  }

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    calls.add('create');
    return _binding;
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    calls.add('submit:$runtimeSessionId');
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

  void emit(
    String type, [
    Map<String, dynamic> payload = const {},
    int? sequence,
    int? transportGeneration,
    Object? producerChannel,
  ]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: _runtimeId,
        sequence: sequence,
        transportGeneration: transportGeneration,
        producerChannel: producerChannel,
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() => _events.close();
}

ActiveChat _chat(
  _TerminalAuthorityGateway gateway, {
  required String id,
  StoredSessionMessageLoader? storedMessageLoader,
  int Function()? wallClockMs,
}) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: _connection('conn-$id'),
  sessionId: _storedId,
  initialStoredSessionId: _storedId,
  sessionTitle: 'Terminal authority',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:1',
    apiKey: 'test-key',
    httpClient: MockClient((_) async => http.Response('not found', 404)),
  ),
  desktopGateway: gateway,
  attachDesktopRuntimeOnLoad: true,
  storedMessageLoader: storedMessageLoader,
  wallClockMs: wallClockMs,
  terminalReconcileBudget: Duration.zero,
)..smoothStreaming = false;

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Starts a live turn and lets the runtime prove it began working, which is
/// Desktop's `sawAssistantPayload` precondition for reaping.
Future<ActiveChat> _liveTurn(
  _TerminalAuthorityGateway gateway, {
  required String id,
  bool withToolPart = true,
  StoredSessionMessageLoader? storedMessageLoader,
  int Function()? wallClockMs,
}) async {
  gateway.activeList = _liveRoster();
  final chat = _chat(
    gateway,
    id: id,
    storedMessageLoader: storedMessageLoader,
    wallClockMs: wallClockMs,
  );
  addTearDown(chat.dispose);
  expect(
    await chat.send(
      fullText: 'sigue trabajando',
      model: 'hermes-agent',
      history: const [],
    ),
    isTrue,
  );
  expect(chat.isStreaming, isTrue);
  if (withToolPart) {
    gateway.emit('tool.start', const {'name': 'execute_code'});
    await _waitUntil(() => chat.trace.isNotEmpty);
    expect(chat.trace.single.isDone, isFalse);
  }
  return chat;
}

bool _hasErrorBubble(ActiveChat chat) =>
    chat.messages.any((message) => message['role'] == 'assistant_error');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  test('A1 roster probe runs while a turn is streaming', () async {
    final gateway = _TerminalAuthorityGateway();
    addTearDown(gateway.close);
    final chat = await _liveTurn(gateway, id: 'a1', withToolPart: false);

    final before = gateway.activeListCalls;
    await chat.refreshPassiveRemoteActivity();

    expect(chat.isStreaming, isTrue);
    expect(gateway.activeListCalls, greaterThan(before));
  });

  test(
    'A2 runtime absent from a complete roster settles a busy turn',
    () async {
      final gateway = _TerminalAuthorityGateway();
      addTearDown(gateway.close);
      final chat = await _liveTurn(gateway, id: 'a2');

      await chat.refreshPassiveRemoteActivity(); // seen live
      gateway.activeList = _emptyRoster;
      await chat.refreshPassiveRemoteActivity(); // first absence
      await chat.refreshPassiveRemoteActivity(); // confirmed absence

      await _waitUntil(() => !chat.isStreaming);
      expect(chat.state, isNot(ChatPipelineState.streaming));
      expect(chat.state, isNot(ChatPipelineState.executing));
      expect(chat.state, isNot(ChatPipelineState.failed));
      expect(chat.trace.single.isDone, isTrue);
      expect(_hasErrorBubble(chat), isFalse);
    },
  );

  test('A2b a single absence does not settle a busy turn', () async {
    final gateway = _TerminalAuthorityGateway();
    addTearDown(gateway.close);
    final chat = await _liveTurn(gateway, id: 'a2b');

    await chat.refreshPassiveRemoteActivity(); // seen live
    gateway.activeList = _emptyRoster;
    await chat.refreshPassiveRemoteActivity(); // first absence
    await _settle();

    expect(chat.isStreaming, isTrue);
    expect(chat.trace.single.isDone, isFalse);
  });

  test('A2c a failed probe is never evidence of absence', () async {
    final gateway = _TerminalAuthorityGateway();
    addTearDown(gateway.close);
    final chat = await _liveTurn(gateway, id: 'a2c');

    await chat.refreshPassiveRemoteActivity(); // seen live
    gateway.activeListError = StateError('gateway unreachable');
    await chat.refreshPassiveRemoteActivity();
    await chat.refreshPassiveRemoteActivity();
    await chat.refreshPassiveRemoteActivity();
    await _settle();

    expect(chat.isStreaming, isTrue);
    expect(chat.trace.single.isDone, isFalse);
  });

  test('A3 a stale roster response cannot settle a newer turn', () async {
    final gateway = _TerminalAuthorityGateway();
    addTearDown(gateway.close);
    final chat = await _liveTurn(gateway, id: 'a3');

    await chat.refreshPassiveRemoteActivity(); // seen live

    final gate = Completer<DesktopActiveSessionList>();
    gateway.activeListGate = gate;
    final stale = chat.refreshPassiveRemoteActivity();
    final done = chat.changes.firstWhere(
      (event) => event == ActiveChatEvent.done,
    );
    gateway.emit('message.complete', const {'text': 'turno cerrado'});
    await done.timeout(const Duration(seconds: 2));
    gateway.activeList = _liveRoster();
    expect(
      await chat.send(
        fullText: 'turno nuevo',
        model: 'hermes-agent',
        history: const [],
      ),
      isTrue,
    );
    gateway.emit('tool.start', const {'name': 'execute_code'});
    await _waitUntil(() => chat.trace.isNotEmpty);

    // The response of the request issued for the previous turn lands now.
    gate.complete(_emptyRoster);
    await stale;
    await _settle();

    expect(chat.isStreaming, isTrue);

    // The stale absence contributed no evidence: the newer turn still needs a
    // full confirmation streak of its own.
    gateway.activeList = _emptyRoster;
    await chat.refreshPassiveRemoteActivity();
    await _settle();
    expect(chat.isStreaming, isTrue);
  });

  test('A4 just-submitted turn is not reaped before it produces', () async {
    final gateway = _TerminalAuthorityGateway();
    addTearDown(gateway.close);
    final chat = await _liveTurn(gateway, id: 'a4', withToolPart: false);

    gateway.activeList = _liveRoster(status: 'idle');
    await chat.refreshPassiveRemoteActivity(); // seen live, still spinning up
    gateway.activeList = _emptyRoster;
    await chat.refreshPassiveRemoteActivity();
    await chat.refreshPassiveRemoteActivity();
    await _settle();

    expect(chat.isStreaming, isTrue);
  });

  test('A4b pre-start absence settles after the 15 second grace', () async {
    final gateway = _TerminalAuthorityGateway();
    addTearDown(gateway.close);
    var nowMs = 1000;
    final chat = await _liveTurn(
      gateway,
      id: 'a4b',
      withToolPart: false,
      wallClockMs: () => nowMs,
    );

    gateway.activeList = _emptyRoster;
    await chat.refreshPassiveRemoteActivity();
    await chat.refreshPassiveRemoteActivity();
    expect(chat.isStreaming, isTrue);

    nowMs += 15000;
    await chat.refreshPassiveRemoteActivity();
    await chat.refreshPassiveRemoteActivity();
    await _waitUntil(() => !chat.isStreaming);

    expect(chat.state, isNot(ChatPipelineState.failed));
    expect(_hasErrorBubble(chat), isFalse);
  });

  test(
    'A4c a listed pre-start runtime stays running after the grace',
    () async {
      final gateway = _TerminalAuthorityGateway();
      addTearDown(gateway.close);
      var nowMs = 1000;
      final chat = await _liveTurn(
        gateway,
        id: 'a4c',
        withToolPart: false,
        wallClockMs: () => nowMs,
      );

      nowMs += 15001;
      await chat.refreshPassiveRemoteActivity();
      await chat.refreshPassiveRemoteActivity();
      await _settle();

      expect(chat.isStreaming, isTrue);
      expect(_hasErrorBubble(chat), isFalse);
    },
  );

  test(
    'A5 loadMessages settles a neither-failed-nor-running snapshot',
    () async {
      final gateway = _TerminalAuthorityGateway();
      addTearDown(gateway.close);
      // El turno arrancó de verdad (el runtime ya produjo trabajo) y el roster
      // lo sigue anunciando: solo el estado durable prueba que terminó.
      final chat = await _liveTurn(
        gateway,
        id: 'a5',
        storedMessageLoader: (_, _) async => _durableRows,
      );
      gateway.snapshot = _finishedSnapshot();

      await chat.loadMessages(profile: 'default');

      await _waitUntil(() => !chat.isStreaming);
      expect(chat.state, isNot(ChatPipelineState.streaming));
      expect(chat.state, isNot(ChatPipelineState.executing));
      expect(chat.state, isNot(ChatPipelineState.failed));
      expect(_hasErrorBubble(chat), isFalse);
      expect(gateway.activeList.sessions, isNotEmpty);
    },
  );

  test('a still-live runtime keeps the turn busy', () async {
    final gateway = _TerminalAuthorityGateway();
    addTearDown(gateway.close);
    final chat = await _liveTurn(gateway, id: 'live');

    await chat.refreshPassiveRemoteActivity();
    await chat.refreshPassiveRemoteActivity();
    await chat.refreshPassiveRemoteActivity();
    await _settle();

    expect(chat.isStreaming, isTrue);
    expect(chat.trace.single.isDone, isFalse);
  });

  test('an incomplete roster reaps nothing', () async {
    final gateway = _TerminalAuthorityGateway();
    addTearDown(gateway.close);
    final chat = await _liveTurn(gateway, id: 'malformed');

    await chat.refreshPassiveRemoteActivity(); // seen live
    gateway.activeList = _malformedRoster;
    await chat.refreshPassiveRemoteActivity();
    await chat.refreshPassiveRemoteActivity();
    await chat.refreshPassiveRemoteActivity();
    await _settle();

    expect(chat.isStreaming, isTrue);
    expect(chat.trace.single.isDone, isFalse);
  });

  test('a runtime never reported live is not settled', () async {
    final gateway = _TerminalAuthorityGateway();
    addTearDown(gateway.close);
    final chat = await _liveTurn(gateway, id: 'never-live');

    gateway.activeList = _emptyRoster;
    await chat.refreshPassiveRemoteActivity();
    await chat.refreshPassiveRemoteActivity();
    await chat.refreshPassiveRemoteActivity();
    await _settle();

    expect(chat.isStreaming, isTrue);
    expect(chat.trace.single.isDone, isFalse);
  });

  test('probing while streaming never resumes or activates', () async {
    final gateway = _TerminalAuthorityGateway();
    addTearDown(gateway.close);
    final chat = await _liveTurn(gateway, id: 'passive');

    final callsBeforeProbes = List<String>.from(gateway.calls);
    await chat.refreshPassiveRemoteActivity();
    gateway.activeList = _emptyRoster;
    await chat.refreshPassiveRemoteActivity();
    await chat.refreshPassiveRemoteActivity();
    await _settle();

    final probeCalls = gateway.calls.sublist(callsBeforeProbes.length);
    expect(probeCalls.where((call) => call.startsWith('resume:')), isEmpty);
    expect(probeCalls.where((call) => call.startsWith('activate:')), isEmpty);
    expect(probeCalls.where((call) => call == 'create'), isEmpty);
  });

  test(
    'a causally later backend turn reopens without hiding process completion',
    () async {
      final gateway = _TerminalAuthorityGateway();
      addTearDown(gateway.close);
      final chat = await _liveTurn(gateway, id: 'backend-successor');
      final producerChannel = Object();

      final parentDone = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit(
        'message.complete',
        const {'text': 'parent complete'},
        40,
        7,
        producerChannel,
      );
      await parentDone.timeout(const Duration(seconds: 2));

      const processComplete = <String, dynamic>{
        'message_id': 'process-complete-1',
        'role': 'user',
        'content': 'Background process finished',
        'display_kind': 'process_complete',
        'display_metadata': {
          'display_text': 'Background Process Finished: verify.mjs',
        },
      };
      chat.replaceInternalMessagesForTesting([processComplete]);

      gateway.emit('message.start');
      await _settle();
      expect(chat.sessionActivity.foregroundTurn, isFalse);
      expect(chat.messages.single['display_kind'], 'process_complete');

      gateway.emit('message.start', const {}, 41, 7, producerChannel);
      await _waitUntil(() => chat.sessionActivity.foregroundTurn);
      expect(
        chat.messages.any(
          (message) => message['display_kind'] == 'process_complete',
        ),
        isTrue,
      );

      gateway.emit(
        'message.delta',
        const {'text': 'successor output'},
        42,
        7,
        producerChannel,
      );
      await _waitUntil(() => chat.assistantContent.contains('successor output'));
      expect(
        chat.messages.any(
          (message) => message['display_kind'] == 'process_complete',
        ),
        isTrue,
      );

      final successorDone = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit(
        'message.complete',
        const {'text': 'successor output'},
        43,
        7,
        producerChannel,
      );
      await successorDone.timeout(const Duration(seconds: 2));
      expect(chat.sessionActivity.foregroundTurn, isFalse);
      expect(
        chat.messages.any(
          (message) => message['display_kind'] == 'process_complete',
        ),
        isTrue,
      );
    },
  );
}
