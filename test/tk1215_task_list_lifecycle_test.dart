// tk1215: the agent's task list follows Hermes Desktop's `store/todos.ts`.
// It shows the plan of the turn in flight and goes away with it: a finished
// list after a short linger, an unfinished one at once. Stored history never
// pins an unfinished list again; a session still running on the server
// restores its plan; the last confirmed list stays consultable as history.
import 'dart:async';
import 'dart:convert';

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_task_list.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/session_live_status.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity_peer_test.dart' as peer;
import 'support/in_memory_compression_restore_storage.dart';

final Strings _es = StringsEs();

SavedConnection _conn(String id) => SavedConnection(
  id: id,
  label: 'Test',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

/// A session this client binds when it sends: `session.resume` answers with
/// the server's `todo_state` and whether its turn is `running`.
class _Gateway implements HermesDesktopGateway {
  _Gateway({this.todoState, this.running = false});

  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final AgentTaskList? todoState;
  final bool running;

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
    runtimeSessionId: 'runtime-a',
    storedSessionId: storedSessionId,
    created: false,
    todoState: todoState,
    running: running,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  /// Hermes confirms a stop with a blank interrupted terminal.
  @override
  Future<void> interrupt(String runtimeSessionId) async =>
      emit('message.complete', const {'text': '', 'status': 'interrupted'});

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  void emit(String type, [Map<String, dynamic> payload = const {}]) =>
      _events.add(
        TuiGatewayEvent(type: type, sessionId: 'runtime-a', payload: payload),
      );

  @override
  Future<void> close() => _events.close();
}

// Real-shaped `todo.updated` / `todo_state` payloads
// (tui_gateway/tool_progress.py).
Map<String, dynamic> _todo(int revision, List<List<String>> rows) => {
  'revision': revision,
  'todos': [
    for (final row in rows) {'id': row[0], 'content': row[1], 'status': row[2]},
  ],
};

/// The plan the owner saw stuck: four done, one optional item left.
Map<String, dynamic> _fourOfFive(int revision) => _todo(revision, [
  ['1', 'Leer el informe', 'completed'],
  ['2', 'Arreglar el parser', 'completed'],
  ['3', 'Probar en el móvil', 'completed'],
  ['4', 'Actualizar el changelog', 'completed'],
  ['5', 'Opcional: limpiar logs', 'in_progress'],
]);

Map<String, dynamic> _allDone(int revision) => _todo(revision, [
  ['1', 'Leer el informe', 'completed'],
  ['2', 'Arreglar el parser', 'completed'],
]);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  group('a turn of this chat', () {
    late ActiveChatService service;
    setUp(() {
      service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
    });
    tearDown(() => service.dispose());

    Future<bool> prompt(ActiveChat chat) =>
        chat.send(fullText: 'haz el plan', model: 'hermes-agent', history: []);

    Future<ActiveChat> turn(_Gateway gateway, String id) async {
      final chat = service.attach(
        connection: _conn(id),
        sessionId: 'sess-$id',
        sessionTitle: 'Tareas',
        api: ApiClient(
          baseUrl: 'https://example.invalid',
          apiKey: 'k',
          httpClient: MockClient((_) async => http.Response('nf', 404)),
        ),
        desktopGateway: gateway,
        disableForegroundKeepAlive: true,
      )..smoothStreaming = false;
      expect(await prompt(chat), isTrue);
      return chat;
    }

    test('ends with an unfinished list: it drops at once', () async {
      final gateway = _Gateway();
      addTearDown(gateway.close);
      final chat = await turn(gateway, 'open');
      gateway.emit('todo.updated', _fourOfFive(1));
      await _settle();
      expect(chat.agentTasks.done, 4);
      expect(chat.agentTasks.total, 5);
      expect(chat.liveStatus.tasks?.done, 4);
      expect(chat.sessionActivity.pendingTasks, hasLength(1));

      gateway.emit('message.complete', const {'text': 'listo'});
      await _settle();
      expect(chat.isStreaming, isFalse);
      expect(chat.agentTasks.isEmpty, isTrue, reason: 'no pinned «4/5»');
      expect(chat.liveStatus.tasks, isNull);
      expect(chat.sessionActivity.pendingTasks, isEmpty);
      expect(chat.sessionActivity.active, isFalse);
    });

    test('that errors drops an unfinished list too', () async {
      final gateway = _Gateway();
      addTearDown(gateway.close);
      final chat = await turn(gateway, 'error');
      gateway.emit('todo.updated', _fourOfFive(1));
      await _settle();
      expect(chat.agentTasks.hasOpen, isTrue);

      gateway.emit('error', const {'message': 'boom'});
      await _settle();
      expect(chat.isStreaming, isFalse);
      expect(chat.agentTasks.isEmpty, isTrue);
      expect(chat.sessionActivity.active, isFalse);
    });

    test('that is stopped drops its list and ignores a late update', () async {
      final gateway = _Gateway();
      addTearDown(gateway.close);
      final chat = await turn(gateway, 'stop');
      gateway.emit('todo.updated', _fourOfFive(1));
      await _settle();
      expect(chat.agentTasks.hasOpen, isTrue);

      await chat.cancel();
      await _settle();
      expect(chat.isStreaming, isFalse);
      expect(chat.agentTasks.isEmpty, isTrue);

      // A frame the backend emitted before it noticed the stop.
      gateway.emit('todo.updated', _fourOfFive(2));
      await _settle();
      expect(chat.agentTasks.isEmpty, isTrue, reason: 'the plan was stopped');
      expect(chat.sessionActivity.active, isFalse);
    });

    test('a finished list lingers 4 s after the turn, then drops', () {
      fakeAsync((async) {
        final gateway = _Gateway();
        late ActiveChat chat;
        turn(gateway, 'linger').then((value) => chat = value);
        async.elapse(const Duration(milliseconds: 50));

        gateway.emit('todo.updated', _allDone(1));
        async.flushMicrotasks();
        gateway.emit('message.complete', const {'text': 'listo'});
        async.elapse(const Duration(milliseconds: 500));
        expect(chat.isStreaming, isFalse);
        expect(chat.agentTasks.isFinished, isTrue, reason: 'last checkmark');

        async.elapse(const Duration(seconds: 3));
        expect(
          chat.agentTasks.isFinished,
          isTrue,
          reason: '3.5 s: still there',
        );

        async.elapse(const Duration(seconds: 1));
        expect(chat.agentTasks.isEmpty, isTrue, reason: 'gone after 4 s');
        expect(chat.retainedAgentTasks.isFinished, isTrue);
        gateway.close();
      });
    });

    test(
      'a list that finishes mid-turn drops after its linger and says so',
      () {
        fakeAsync((async) {
          final gateway = _Gateway();
          late ActiveChat chat;
          turn(gateway, 'midturn').then((value) => chat = value);
          async.elapse(const Duration(milliseconds: 50));
          gateway.emit('todo.updated', _allDone(1));
          async.flushMicrotasks();
          expect(chat.liveStatus.tasks?.done, 2);

          final events = <ActiveChatEvent>[];
          final sub = chat.changes.listen(events.add);
          async.elapse(const Duration(seconds: 5));
          expect(chat.isStreaming, isTrue);
          expect(chat.agentTasks.isEmpty, isTrue);
          expect(chat.liveStatus.tasks, isNull);
          expect(events, contains(ActiveChatEvent.subagentActivity));
          sub.cancel();
          gateway.close();
        });
      },
    );

    test('the next turn starts without the old plan', () async {
      final gateway = _Gateway();
      addTearDown(gateway.close);
      final chat = await turn(gateway, 'next');
      gateway.emit('todo.updated', _fourOfFive(3));
      await _settle();
      gateway.emit('message.complete', const {'text': 'listo'});
      await _settle();
      expect(chat.agentTasks.isEmpty, isTrue);

      expect(await prompt(chat), isTrue);
      gateway.emit('message.start');
      await _settle();
      expect(chat.isStreaming, isTrue);
      expect(chat.agentTasks.isEmpty, isTrue, reason: 'no «4/5» from before');
      expect(chat.liveStatus.tasks, isNull);

      // An older revision can never bring it back; the new plan shows.
      gateway.emit('todo.updated', _fourOfFive(2));
      await _settle();
      expect(chat.agentTasks.isEmpty, isTrue);
      gateway.emit(
        'todo.updated',
        _todo(4, [
          ['a', 'Plan nuevo', 'in_progress'],
        ]),
      );
      await _settle();
      expect(chat.agentTasks.items.single.content, 'Plan nuevo');
    });

    test('a replayed update of the plan that ended does not pin it', () async {
      final gateway = _Gateway();
      addTearDown(gateway.close);
      final chat = await turn(gateway, 'replay');
      gateway.emit('todo.updated', _fourOfFive(3));
      await _settle();
      gateway.emit('message.complete', const {'text': 'listo'});
      await _settle();
      expect(chat.agentTasks.isEmpty, isTrue);

      // A reconnect replays the frame this chat already settled.
      gateway.emit('todo.updated', _fourOfFive(3));
      await _settle();
      expect(chat.agentTasks.isEmpty, isTrue);
      expect(chat.sessionActivity.active, isFalse);

      // The same replay during the next turn is still the old plan.
      expect(await prompt(chat), isTrue);
      gateway.emit('message.start');
      gateway.emit('todo.updated', _fourOfFive(3));
      await _settle();
      expect(chat.isStreaming, isTrue);
      expect(chat.agentTasks.isEmpty, isTrue);
      expect(chat.liveStatus.tasks, isNull);
    });

    test('the last list stays consultable as history, never as live', () async {
      final gateway = _Gateway();
      addTearDown(gateway.close);
      final chat = await turn(gateway, 'history');
      gateway.emit('todo.updated', _fourOfFive(1));
      await _settle();
      expect(
        chat.transcriptAgentTasks.current?.id,
        '5',
        reason: 'the live list while the turn runs',
      );

      gateway.emit('message.complete', const {'text': 'listo'});
      await _settle();
      final retained = chat.retainedAgentTasks;
      expect(retained.done, 4);
      expect(retained.total, 5);
      expect(retained.hasOpen, isTrue, reason: 'annotated «incompleta»');
      expect(
        retained.current,
        isNull,
        reason: 'nothing is in progress once the turn ended',
      );
      expect(chat.transcriptAgentTasks, same(retained));
      expect(chat.agentTasks.isEmpty, isTrue);
    });

    test(
      'an idle session never gets an unfinished todo_state pinned',
      () async {
        final gateway = _Gateway(
          todoState: AgentTaskList.tryParse(_fourOfFive(7)),
        );
        addTearDown(gateway.close);
        final chat = await turn(gateway, 'idle');
        expect(chat.isStreaming, isTrue, reason: 'the prompt just sent');
        expect(chat.agentTasks.isEmpty, isTrue, reason: 'last turn\'s plan');
        expect(chat.liveStatus.tasks, isNull);
        expect(chat.retainedAgentTasks.total, 5);

        // The watermark is kept: only a newer revision is this turn's plan.
        gateway.emit('todo.updated', _fourOfFive(6));
        await _settle();
        expect(chat.agentTasks.isEmpty, isTrue);
        gateway.emit('todo.updated', _fourOfFive(8));
        await _settle();
        expect(chat.agentTasks.done, 4);
      },
    );

    test('a session still running on the server restores its plan', () async {
      final gateway = _Gateway(
        todoState: AgentTaskList.tryParse(_fourOfFive(7)),
        running: true,
      );
      addTearDown(gateway.close);
      final chat = await turn(gateway, 'running');
      expect(chat.agentTasks.done, 4);
      expect(chat.agentTasks.total, 5);
      expect(chat.agentTasks.current?.id, '5');
      expect(chat.liveStatus.tasks?.total, 5);
    });
  });

  group('opening a chat', () {
    late ActiveChatService service;

    setUp(() {
      service = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
        globalActivity: GlobalActivityAggregate.inMemory(),
      );
      addTearDown(service.dispose);
    });

    DesktopSessionSnapshot snapshot({
      required bool running,
      Map<String, dynamic>? todos,
    }) => DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-peer',
        'session_key': 'stored-peer',
        'message_count': 1,
        'messages': [peer.publicSnapshot],
        'running': running,
        if (running) 'inflight': {'assistant': '', 'streaming': true},
        'todo_state': ?todos,
      },
      requestedStoredSessionId: 'stored-peer',
      created: false,
      method: 'session.resume',
    );

    ActiveChat attach(
      peer.PeerGateway gateway, {
      Future<http.Response> Function(http.Request)? rest,
    }) => service.attach(
      connection: SavedConnection(
        id: 'peer',
        label: 'Peer',
        host: 'example.invalid',
        port: 443,
        apiKey: 'k',
        useHttps: true,
        kind: InstanceKind.vps,
      ),
      sessionId: 'stored-peer',
      sessionTitle: 'Peer',
      api: ApiClient(
        baseUrl: 'https://example.invalid',
        apiKey: 'k',
        httpClient: MockClient(rest ?? (_) async => http.Response('nf', 404)),
      ),
      desktopGateway: gateway,
      allowUnownedDesktopSnapshotForTesting: true,
      disableForegroundKeepAlive: true,
    );

    /// What the Conversaciones row and the Home card resolve.
    SessionLiveStatus listStatus() {
      final chat = service.of('peer', 'stored-peer');
      final global =
          service.globalActivity.isActive('peer', 'default', 'stored-peer')
          ? service.globalActivity.activityFor('peer', 'default', 'stored-peer')
          : null;
      return resolveSessionLiveStatus(
        chat: chat?.liveStatus,
        chatAuthoritative:
            chat != null &&
            (chat.hasDesktopRuntime || chat.lastTerminalAt != null),
        chatSettledAt: chat?.lastTerminalAt,
        global: global,
      );
    }

    test(
      'idle, unfinished todo_state: nothing pinned after a restart',
      () async {
        final gateway = peer.PeerGateway(
          snapshot(running: false, todos: _fourOfFive(9)),
        );
        addTearDown(gateway.close);
        final chat = attach(gateway);
        await chat.loadMessages();
        expect(chat.isStreaming, isFalse);
        expect(chat.agentTasks.isEmpty, isTrue);
        expect(chat.liveStatus.isLive, isFalse);
        expect(chat.sessionActivity.active, isFalse);
        expect(listStatus().tasks, isNull);
        expect(sessionLiveStatusLabel(_es, listStatus()), isEmpty);
        expect(service.activeIds.value, isEmpty);
        expect(chat.retainedAgentTasks.total, 5, reason: 'still consultable');
      },
    );

    test('running on the server: the plan in flight is restored', () async {
      final gateway = peer.PeerGateway(
        snapshot(running: true, todos: _fourOfFive(9)),
      );
      addTearDown(gateway.close);
      final chat = attach(gateway);
      await chat.loadMessages();
      expect(chat.isStreaming, isTrue);
      expect(chat.agentTasks.done, 4);
      expect(chat.agentTasks.current?.id, '5');
      expect(listStatus().tasks?.total, 5);
      expect(
        sessionLiveStatusLabel(_es, listStatus()),
        'Pensando… · 4/5 tareas',
      );
    });

    test(
      'Conversaciones and Home count tasks from the live list only',
      () async {
        final gateway = peer.PeerGateway(
          snapshot(running: true, todos: _fourOfFive(9)),
        );
        addTearDown(gateway.close);
        final chat = attach(gateway);
        await chat.loadMessages();
        expect(listStatus().hasOpenTasks, isTrue);
        expect(service.activeIds.value, isNotEmpty);

        // The server's store still holds the unfinished list after the turn.
        gateway.snapshot = snapshot(running: false, todos: _fourOfFive(9));
        gateway.emit('message.complete', const {'text': 'Hecho'});
        await _settle();
        expect(chat.isStreaming, isFalse);
        expect(listStatus().tasks, isNull, reason: 'the row loses its «4/5»');
        expect(listStatus().isLive, isFalse);
        expect(sessionLiveStatusLabel(_es, listStatus()), isEmpty);
        expect(chat.sessionActivity.pendingTasks, isEmpty);
        expect(
          service.activeIds.value,
          isEmpty,
          reason: 'pending tasks of a finished turn are not activity',
        );
        expect(chat.retainedAgentTasks.total, 5);
      },
    );

    test(
      'another surface\'s turn ends: its unfinished list goes too',
      () async {
        final gateway = peer.PeerGateway(snapshot(running: false));
        addTearDown(gateway.close);
        final chat = attach(gateway);
        await chat.loadMessages();
        expect(chat.isStreaming, isFalse);

        // The other surface's turn reports its plan over the shared runtime.
        gateway.emit('todo.updated', _fourOfFive(3));
        await _settle();
        expect(chat.agentTasks.hasOpen, isTrue);

        gateway.emit('message.complete', const {'text': 'Hecho'});
        await _settle();
        expect(chat.agentTasks.isEmpty, isTrue);
        expect(chat.sessionActivity.active, isFalse);
        expect(service.activeIds.value, isEmpty);
      },
    );

    Map<String, dynamic> todoCall(String id) => {
      'id': id,
      'type': 'function',
      'function': {'name': 'todo_list', 'arguments': '{}'},
    };

    Map<String, dynamic> todoResult(
      int rowId,
      String callId,
      Map<String, dynamic> state,
    ) => {
      'id': rowId,
      'role': 'tool',
      'tool_name': 'todo_list',
      'tool_call_id': callId,
      'content': jsonEncode(state),
    };

    List<Map<String, dynamic>> transcript(Map<String, dynamic> state) => [
      {'id': 1, 'role': 'user', 'content': 'PUBLIC_PLAN'},
      {
        'id': 2,
        'role': 'assistant',
        'content': '',
        'tool_calls': [todoCall('call_a')],
      },
      todoResult(3, 'call_a', state),
      {'id': 4, 'role': 'assistant', 'content': 'PUBLIC_DONE'},
    ];

    test(
      'an unfinished list in the transcript is not adopted when idle',
      () async {
        final chat = attach(
          peer.PeerGateway(null),
          rest: (_) async => peer.restRows(transcript(_fourOfFive(5))),
        );
        await chat.loadMessages();
        expect(chat.isStreaming, isFalse);
        expect(
          chat.agentTasks.isEmpty,
          isTrue,
          reason: 'stale: its turn ended',
        );
        expect(chat.sessionActivity.active, isFalse);
        expect(chat.retainedAgentTasks.done, 4);
        expect(chat.retainedAgentTasks.total, 5);
        expect(chat.transcriptAgentTasks.total, 5);

        // Reading the same history again changes nothing.
        await chat.loadMessages();
        expect(chat.agentTasks.isEmpty, isTrue);
      },
    );

    test('a finished list in storage is history too, with no linger', () async {
      final chat = attach(
        peer.PeerGateway(null),
        rest: (_) async => peer.restRows(transcript(_allDone(5))),
      );
      await chat.loadMessages();
      expect(chat.agentTasks.isEmpty, isTrue, reason: 'nothing is in flight');
      expect(chat.retainedAgentTasks.isFinished, isTrue);
      expect(chat.retainedAgentTasks.revision, 5);
      expect(chat.transcriptAgentTasks.done, 2);
    });

    test('idle, finished todo_state: retained, not pinned', () async {
      final gateway = peer.PeerGateway(
        snapshot(running: false, todos: _allDone(9)),
      );
      addTearDown(gateway.close);
      final chat = attach(gateway);
      await chat.loadMessages();
      expect(chat.agentTasks.isEmpty, isTrue);
      expect(chat.retainedAgentTasks.isFinished, isTrue);
      expect(chat.sessionActivity.active, isFalse);
    });
  });

  test('roster rows never carry a task count of their own', () {
    final service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
      globalActivity: GlobalActivityAggregate.inMemory(),
    );
    addTearDown(service.dispose);
    service.globalActivity.applyRoster(
      connectionId: 'peer',
      profile: 'default',
      replayEpoch: 'current',
      requestGeneration: service.globalActivity.beginRosterRequest(
        'peer',
        'default',
      ),
      roster: DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-peer',
            storedSessionId: 'stored-peer',
            status: 'working',
          ),
        ],
      ),
    );
    final status = sessionLiveStatusFromGlobal(
      service.globalActivity.activityFor('peer', 'default', 'stored-peer'),
    );
    expect(status.isLive, isTrue);
    expect(status.tasks, isNull);
  });

  test('history view of a list: nothing stays in progress', () {
    final live = AgentTaskList.tryParse(_fourOfFive(1))!;
    final history = live.asHistory;
    expect(history.current, isNull);
    expect(history.hasOpen, isTrue);
    expect(history.done, 4);
    expect(history.total, 5);
    expect(history.revision, 1);
    expect(history.items.last.status, AgentTaskStatus.pending);
    final finished = AgentTaskList.tryParse(_allDone(2))!;
    expect(finished.asHistory, same(finished));
  });
}
