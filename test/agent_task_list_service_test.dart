// La lista de tareas del agente (`todo_list`) en ActiveChat: en vivo
// (`todo.updated`), reconstruida desde `todo_state` de session.resume, y sin
// contaminar la actividad de fondo.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/models/agent_task_list.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_restore_storage.dart';

SavedConnection _conn(String id) => SavedConnection(
  id: id,
  label: 'Test',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

class _Gateway implements HermesDesktopGateway {
  _Gateway({this.todoState});

  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  String runtimeId = 'runtime-a';
  AgentTaskList? todoState;

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
    todoState: todoState,
  );

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

  void emit(String type, [Map<String, dynamic> payload = const {}]) => _events
      .add(TuiGatewayEvent(type: type, sessionId: runtimeId, payload: payload));

  @override
  Future<void> close() => _events.close();
}

// Real-shaped `todo.updated` payloads (tui_gateway/tool_progress.py).
Map<String, dynamic> _todo(int revision, List<List<String>> rows) => {
  'revision': revision,
  'todos': [
    for (final row in rows) {'id': row[0], 'content': row[1], 'status': row[2]},
  ],
};

Future<ActiveChat> _chat(
  ActiveChatService service,
  _Gateway gateway,
  String id,
) async {
  final chat = service.attach(
    connection: _conn(id),
    sessionId: 'sess-$id',
    sessionTitle: 'Tareas',
    desktopGateway: gateway,
    disableForegroundKeepAlive: true,
  )..smoothStreaming = false;
  expect(
    await chat.send(
      fullText: 'haz el plan',
      model: 'hermes-agent',
      history: const [],
    ),
    isTrue,
  );
  return chat;
}

void main() {
  late ActiveChatService service;
  setUp(() {
    service = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
    );
  });
  tearDown(() => service.dispose());

  test(
    'live: create, progress and complete arrive as full snapshots',
    () async {
      final gateway = _Gateway();
      addTearDown(gateway.close);
      final chat = await _chat(service, gateway, 'live');
      expect(chat.agentTasks.isEmpty, isTrue);

      final events = <ActiveChatEvent>[];
      final sub = chat.changes.listen(events.add);
      addTearDown(sub.cancel);

      gateway.emit(
        'todo.updated',
        _todo(1, [
          ['1', 'Leer el test', 'in_progress'],
          ['2', 'Arreglar el parser', 'pending'],
          ['3', 'Actualizar el changelog', 'pending'],
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(chat.agentTasks.total, 3);
      expect(chat.agentTasks.done, 0);
      expect(chat.agentTasks.current?.content, 'Leer el test');

      gateway.emit(
        'todo.updated',
        _todo(2, [
          ['1', 'Leer el test', 'completed'],
          ['2', 'Arreglar el parser', 'in_progress'],
          ['3', 'Actualizar el changelog', 'pending'],
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(chat.agentTasks.done, 1);
      expect(chat.agentTasks.current?.id, '2');

      gateway.emit(
        'todo.updated',
        _todo(3, [
          ['1', 'Leer el test', 'completed'],
          ['2', 'Arreglar el parser', 'completed'],
          ['3', 'Actualizar el changelog', 'completed'],
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(chat.agentTasks.isFinished, isTrue);
      expect(chat.agentTasks.revision, 3);
      expect(
        events.where((e) => e == ActiveChatEvent.subagentActivity),
        hasLength(3),
      );
    },
  );

  test(
    'a stale revision never overwrites a newer list; the same one is idempotent',
    () async {
      final gateway = _Gateway();
      addTearDown(gateway.close);
      final chat = await _chat(service, gateway, 'stale');
      gateway.emit(
        'todo.updated',
        _todo(5, [
          ['1', 'Nuevo', 'in_progress'],
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      final events = <ActiveChatEvent>[];
      final sub = chat.changes.listen(events.add);
      addTearDown(sub.cancel);

      gateway.emit(
        'todo.updated',
        _todo(4, [
          ['1', 'Viejo', 'pending'],
        ]),
      );
      gateway.emit(
        'todo.updated',
        _todo(5, [
          ['1', 'Nuevo', 'in_progress'],
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(chat.agentTasks.items.single.content, 'Nuevo');
      expect(events, isEmpty, reason: 'no redundant rebuilds');
    },
  );

  test('an empty list at a newer revision clears the checklist', () async {
    final gateway = _Gateway();
    addTearDown(gateway.close);
    final chat = await _chat(service, gateway, 'clear');
    gateway.emit(
      'todo.updated',
      _todo(1, [
        ['1', 'Algo', 'pending'],
      ]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(chat.agentTasks.isNotEmpty, isTrue);
    gateway.emit('todo.updated', {'revision': 2, 'todos': <Object>[]});
    await Future<void>.delayed(Duration.zero);
    expect(chat.agentTasks.isEmpty, isTrue);
    expect(chat.sessionActivity.tasks, isEmpty);
  });

  test('malformed payloads are ignored without throwing', () async {
    final gateway = _Gateway();
    addTearDown(gateway.close);
    final chat = await _chat(service, gateway, 'junk');
    gateway.emit('todo.updated', {'revision': 1, 'todos': 'nope'});
    gateway.emit('todo.updated', {
      'todos': [42, null, 'x'],
    });
    gateway.emit('todo.updated');
    await Future<void>.delayed(Duration.zero);
    expect(chat.agentTasks.isEmpty, isTrue);
  });

  test('reopen: session.resume todo_state rebuilds the list', () async {
    // Real shape of the resume payload: todo_state = {todos, revision}.
    final snapshot = DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-a',
        'stored_session_id': 'sess-reopen',
        'messages': const [],
        'todo_state': _todo(7, [
          ['1', 'Leer el test', 'completed'],
          ['2', 'Arreglar el parser', 'completed'],
          ['3', 'Probar el flag de caché', 'cancelled'],
        ]),
      },
      requestedStoredSessionId: 'sess-reopen',
      created: false,
      method: 'session.resume',
    );
    expect(snapshot.todoState, isNotNull);
    expect(snapshot.todoState!.revision, 7);
    expect(snapshot.todoState!.isFinished, isTrue);

    final gateway = _Gateway(todoState: snapshot.todoState);
    addTearDown(gateway.close);
    final chat = await _chat(service, gateway, 'reopen');
    expect(chat.agentTasks.revision, 7);
    expect(chat.agentTasks.done, 2);
    expect(chat.agentTasks.cancelledCount, 1);
    // ...but a rebuilt list is presentation only: it must not make an idle
    // chat look like it still has background work.
    expect(chat.sessionActivity.tasks, isEmpty);
  });

  test(
    'reconnect: a fresher todo_state wins, an older one is ignored',
    () async {
      final gateway = _Gateway(
        todoState: AgentTaskList.tryParse(
          _todo(3, [
            ['1', 'Uno', 'in_progress'],
          ]),
        ),
      );
      addTearDown(gateway.close);
      final chat = await _chat(service, gateway, 'reconnect');
      expect(chat.agentTasks.revision, 3);

      gateway.emit(
        'todo.updated',
        _todo(4, [
          ['1', 'Uno', 'completed'],
          ['2', 'Dos', 'in_progress'],
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(chat.agentTasks.total, 2);

      // A stale snapshot (older revision) from a lagging reconnect is ignored.
      gateway.emit(
        'todo.updated',
        _todo(3, [
          ['1', 'Uno', 'in_progress'],
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(chat.agentTasks.revision, 4);
      expect(chat.agentTasks.total, 2);
    },
  );

  test('snapshots without todo_state, or with junk, carry no list', () {
    DesktopSessionSnapshot parse(Map<String, dynamic> extra) =>
        DesktopSessionSnapshot.fromJson(
          {'session_id': 'r', 'stored_session_id': 's', ...extra},
          requestedStoredSessionId: 's',
          created: false,
          method: 'session.resume',
        );
    expect(parse(const {}).todoState, isNull);
    expect(parse({'todo_state': 'junk'}).todoState, isNull);
    expect(
      parse({
        'todo_state': {'todos': [], 'revision': 0},
      }).todoState,
      isNull,
    );
    // typed field only: the todo text never leaks into the scalar-only `raw`.
    expect(
      parse({
        'todo_state': _todo(1, [
          ['1', 'secreto', 'pending'],
        ]),
      }).raw.keys,
      isNot(contains('todo_state')),
    );
  });

  test('pending tasks stay activity but leave the background count', () async {
    final gateway = _Gateway();
    addTearDown(gateway.close);
    final chat = await _chat(service, gateway, 'activity');
    gateway.emit('message.complete', const {'text': 'listo'});
    await Future<void>.delayed(Duration.zero);
    gateway.emit(
      'todo.updated',
      _todo(1, [
        ['1', 'Pendiente', 'pending'],
      ]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(chat.sessionActivity.backgroundItemCount, 0);
    expect(chat.sessionActivity.pendingTasks, hasLength(1));
    expect(chat.sessionActivity.active, isTrue);
  });
}
