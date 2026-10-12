import 'dart:convert';

// Transitive via flutter_test; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/home_widget_snapshot.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/home_widget_activity.dart';
import 'package:hermes_android/core/services/home_widget_publisher.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';

class _Store implements HomeWidgetStore {
  final values = <String, Object?>{};
  int redraws = 0;

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
  Future<void> requestUpdate() async => redraws++;

  /// What the Android widget reads.
  HermesHomeWidgetSnapshot get snapshot => HermesHomeWidgetSnapshot.fromMap(
    jsonDecode(values[HermesHomeWidgetSnapshot.atomicStorageKey]! as String)
        as Map,
  );
}

const _t0 = 2000000000000;

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'conn-1',
  label: 'Test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  readOnly: readOnly,
);

void main() {
  group('the snapshot is versioned and old ones still read', () {
    test('a snapshot written by 1.2.14 (schema 1) reads as before', () {
      final old = HermesHomeWidgetSnapshot.fromMap({
        'schema_version': 1,
        'configured': true,
        'instance_id': 'conn-1',
        'instance_label': 'Server',
        'connection_state': 'connected',
        'session_id': 'sess-1',
        'session_title': 'Saludo amistoso',
        'agent_state': 'toolExecution',
        'tool_name': 'terminal',
        'last_activity_at_ms': _t0 - 1000,
        'updated_at_ms': _t0,
      });
      expect(old.configured, isTrue);
      expect(old.sessionId, 'sess-1');
      expect(old.agentState, HomeWidgetAgentState.toolExecution);
      expect(old.toolName, 'terminal');
      expect(old.updatedAtMs, _t0);
      // Schema 1 had no list: there is none, not an error.
      expect(old.active, isEmpty);
    });

    test('schema 2 carries who runs and who waits, and round-trips', () {
      const snapshot = HermesHomeWidgetSnapshot(
        configured: true,
        instanceId: 'conn-1',
        connectionState: HomeWidgetConnectionState.connected,
        sessionId: 'sess-1',
        agentState: HomeWidgetAgentState.waitingApproval,
        updatedAtMs: _t0,
        active: [
          HomeWidgetChatActivity(
            sessionId: 'sess-1',
            state: HomeWidgetAgentState.waitingApproval,
            title: 'Limpiar el build',
            startedAtMs: _t0 - 42000,
            need: HomeWidgetNeed(
              requestId: 'req-9',
              text: 'rm -rf build/',
              actionPayload: '{"v":1}',
            ),
          ),
          HomeWidgetChatActivity(
            sessionId: 'sess-2',
            state: HomeWidgetAgentState.toolExecution,
            title: 'Prueba con subagentes',
            profile: 'forja',
            phase: 'Terminal',
            startedAtMs: _t0 - 134000,
          ),
        ],
      );
      expect(HermesHomeWidgetSnapshot.schemaVersion, 2);
      final wire = jsonDecode(snapshot.toAtomicStorageValue()) as Map;
      expect(wire['schema_version'], 2);
      final back = HermesHomeWidgetSnapshot.fromMap(wire);
      expect(back, snapshot);
      expect(back.active, hasLength(2));
      expect(back.active.first.needsYou, isTrue);
      expect(back.active.first.need!.requestId, 'req-9');
      expect(back.active.first.need!.text, 'rm -rf build/');
      expect(back.active.last.phase, 'Terminal');
      expect(back.active.last.profile, 'forja');
      expect(back.active.last.startedAtMs, _t0 - 134000);
      // The field-by-field mirror only holds plain values (the launcher
      // plugin cannot store a list); the list lives in the atomic copy.
      expect(
        snapshot.toStorageMap().values.whereType<List<Object?>>(),
        isEmpty,
      );
      expect(
        snapshot.toStorageMap().keys,
        isNot(contains('hermes_widget_active')),
      );
    });

    test('a later schema and broken entries fail closed', () {
      expect(
        HermesHomeWidgetSnapshot.fromMap({'schema_version': 3}),
        HermesHomeWidgetSnapshot.empty,
      );
      final parsed = HermesHomeWidgetSnapshot.fromMap({
        'schema_version': 2,
        'configured': true,
        'active': [
          // idle is not "running": never listed.
          {'sid': 'a', 'state': 'idle'},
          // no session, an id that is not opaque, not a map.
          {'state': 'streaming'},
          {'sid': '../../etc', 'state': 'streaming'},
          'nonsense',
          {
            'sid': 'ok',
            'state': 'waitingApproval',
            'need': {'text': 'no request id'},
          },
          {'sid': 'run', 'state': 'thinking', 'started_ms': -5},
        ],
      });
      expect(parsed.active.map((c) => c.sessionId), ['ok', 'run']);
      // Waiting without a known request: it still needs you, with no button.
      expect(parsed.active.first.needsYou, isTrue);
      expect(parsed.active.first.need, isNull);
      expect(parsed.active.last.startedAtMs, isNull);
      // "active" that is not a list is ignored.
      expect(
        HermesHomeWidgetSnapshot.fromMap({
          'schema_version': 2,
          'active': 'oops',
        }).active,
        isEmpty,
      );
    });

    test('equality sees inside the list', () {
      HermesHomeWidgetSnapshot at(String phase) => HermesHomeWidgetSnapshot(
        configured: true,
        active: [
          HomeWidgetChatActivity(
            sessionId: 's',
            state: HomeWidgetAgentState.toolExecution,
            phase: phase,
          ),
        ],
      );
      expect(at('Terminal'), at('Terminal'));
      expect(at('Terminal').hashCode, at('Terminal').hashCode);
      expect(at('Terminal'), isNot(at('Browser')));
    });

    test(
      'a schema 1 snapshot on disk is adopted and rewritten as schema 2',
      () async {
        final store = _Store()
          ..values[HermesHomeWidgetSnapshot.atomicStorageKey] = jsonEncode({
            'schema_version': 1,
            'configured': true,
            'instance_id': 'conn-1',
            'instance_label': 'Server',
            'connection_state': 'connected',
            'session_id': 'sess-1',
            'session_title': 'Saludo amistoso',
            'agent_state': 'idle',
            'updated_at_ms': _t0 - 5000,
          });
        final publisher = HermesHomeWidgetPublisher(
          store: store,
          nowMs: () => _t0,
        );
        await publisher.flush();
        expect(publisher.latest.sessionTitle, 'Saludo amistoso');
        // The first publication writes the current schema even with no change.
        await publisher.update((current) => current);
        expect(store.snapshot.sessionTitle, 'Saludo amistoso');
        expect(
          (jsonDecode(
                store.values[HermesHomeWidgetSnapshot.atomicStorageKey]!
                    as String,
              )
              as Map)['schema_version'],
          2,
        );
      },
    );
  });

  group('plain words for a running tool', () {
    test('the registered name, readable, never its arguments', () {
      expect(homeWidgetToolPhrase('terminal'), 'Terminal');
      // The OAuth wire name and its alias are the same tool.
      expect(homeWidgetToolPhrase('mcp__terminal'), 'Terminal');
      expect(
        homeWidgetToolPhrase('mcp__chat_history_lookup'),
        'Session search',
      );
      expect(homeWidgetToolPhrase('web_search'), 'Web search');
      // A native MCP tool: the tool is the word, not its server.
      expect(homeWidgetToolPhrase('mcp__github__create_issue'), 'Create issue');
      expect(homeWidgetToolPhrase('  '), isNull);
      expect(homeWidgetToolPhrase(null), isNull);
      expect(homeWidgetToolPhrase('x' * 80)!.length, lessThanOrEqualTo(40));
    });

    test('the shared wording of a tool is kept as it is', () {
      // What the chat service hands over (`toolOrSkillStepTitle`).
      expect(homeWidgetToolPhrase('Ejecutando comando'), 'Ejecutando comando');
      expect(
        homeWidgetToolPhrase('GitHub · create issue'),
        'GitHub · create issue',
      );
      expect(homeWidgetToolPhrase('Buscando en la web'), 'Buscando en la web');
      // Only bounded: a phase is one line beside a name and a timer.
      final long = homeWidgetToolPhrase(
        'Leyendo ${'un archivo muy ' * 6}largo',
      )!;
      expect(long.length, lessThanOrEqualTo(41));
      expect(long, endsWith('…'));
      // The tracker stores it untouched.
      final tracker = HomeWidgetActivityTracker()
        ..update(
          owner: Object(),
          sessionId: 's1',
          state: HomeWidgetAgentState.toolExecution,
          nowMs: _t0,
          toolName: 'Ejecutando comando',
        );
      expect(tracker.list.single.phase, 'Ejecutando comando');
    });
  });

  group('what a chat waits for', () {
    Map<String, dynamic> approval({
      Object? choices = const ['once', 'session', 'always', 'deny'],
    }) => {
      'request_id': 'req-9',
      'command': 'rm -rf build/\n# second line',
      'description': 'Borrar la carpeta de build',
      'choices': ?choices,
    };

    test('a permission carries the payload a notification button would', () {
      final need = homeWidgetNeedForApproval(
        approval: approval(),
        connectionId: 'conn-1',
        sessionId: 'sess-1',
        profile: null,
        readOnly: false,
      )!;
      expect(need.requestId, 'req-9');
      expect(need.question, isFalse);
      // One line of the command, nothing else.
      expect(need.text, 'rm -rf build/');
      final payload = NotificationActionPayload.tryParse(need.actionPayload)!;
      expect(payload.route, NotificationActionRoute.chat);
      expect(payload.connId, 'conn-1');
      expect(payload.sessionId, 'sess-1');
      expect(payload.requestId, 'req-9');
      expect(payload.profile, isNull);
      // "Permitir" is once and "Rechazar" is deny for the shared executor.
      expect(NotificationActionRouter.choiceFor('approve', payload), 'once');
      expect(NotificationActionRouter.choiceFor('deny', payload), 'deny');
    });

    test('no buttons where they could not work', () {
      // A read-only instance.
      expect(
        homeWidgetNeedForApproval(
          approval: approval(),
          connectionId: 'conn-1',
          sessionId: 'sess-1',
          profile: 'forja',
          readOnly: true,
        )!.actionPayload,
        isNull,
      );
      // The request does not permit both answers the widget offers.
      expect(
        homeWidgetNeedForApproval(
          approval: approval(choices: const ['once']),
          connectionId: 'conn-1',
          sessionId: 'sess-1',
          profile: null,
          readOnly: false,
        )!.actionPayload,
        isNull,
      );
      // A session id the executor would not accept back.
      expect(
        homeWidgetNeedForApproval(
          approval: approval(),
          connectionId: 'conn-1',
          sessionId: 'not an id',
          profile: null,
          readOnly: false,
        )!.actionPayload,
        isNull,
      );
      // No request id: nothing an answer could be for.
      expect(
        homeWidgetNeedForApproval(
          approval: {'command': 'ls'},
          connectionId: 'conn-1',
          sessionId: 'sess-1',
          profile: null,
          readOnly: false,
        ),
        isNull,
      );
      expect(
        homeWidgetNeedForApproval(
          approval: null,
          connectionId: 'conn-1',
          sessionId: 'sess-1',
          profile: null,
          readOnly: false,
        ),
        isNull,
      );
    });

    test('"hide sensitive content" keeps the command off the home screen', () {
      final need = homeWidgetNeedForApproval(
        approval: approval(),
        connectionId: 'conn-1',
        sessionId: 'sess-1',
        profile: null,
        readOnly: false,
        hideSensitive: true,
      )!;
      expect(need.text, isNull);
      // It can still be answered.
      expect(need.actionPayload, isNotNull);
    });
  });

  group('a question a chat asks', () {
    final key = InteractivePromptKey(
      runtimeSessionId: 'rt-1',
      requestId: 'clar-7',
    );

    test('it is described as a question, with no answer payload', () {
      final need = homeWidgetNeedForPrompt(
        ClarifyPromptRequest(
          key: key,
          question: '¿Uso el modelo de reserva?\nSi falla el principal.',
          choices: const ['Sí, úsalo', 'No'],
        ),
      )!;
      expect(need.question, isTrue);
      expect(need.requestId, 'clar-7');
      expect(need.text, '¿Uso el modelo de reserva?');
      // No route of the shared action path answers a question: the widget
      // shows it with "Abrir" and the choices are answered in the app.
      expect(need.actionPayload, isNull);
      // It survives the snapshot as a question.
      final back = HomeWidgetNeed.fromMap(need.toMap())!;
      expect(back.question, isTrue);
      expect(back.text, '¿Uso el modelo de reserva?');
    });

    test('several questions at once show the first one', () {
      final need = homeWidgetNeedForPrompt(
        ClarifyPromptRequest(
          key: key,
          questions: const [
            ClarifyQuestion(qid: 'q1', question: '¿Qué rama?'),
            ClarifyQuestion(qid: 'q2', question: '¿Con pruebas?'),
          ],
        ),
      )!;
      expect(need.text, '¿Qué rama?');
    });

    test('hidden content, and prompts that are not a question in words', () {
      expect(
        homeWidgetNeedForPrompt(
          ClarifyPromptRequest(key: key, question: '¿Borro la base de datos?'),
          hideSensitive: true,
        )!.text,
        isNull,
      );
      // No prompt, or one this function does not describe: "te necesita".
      expect(homeWidgetNeedForPrompt(null), isNull);
    });
  });

  group('the list of chats that run or wait', () {
    test('a turn keeps its start through its phases and its question', () {
      final tracker = HomeWidgetActivityTracker();
      final chat = Object();
      expect(
        tracker.update(
          owner: chat,
          sessionId: 's1',
          state: HomeWidgetAgentState.thinking,
          nowMs: _t0,
          title: 'Limpiar',
        ),
        isTrue,
      );
      tracker.update(
        owner: chat,
        sessionId: 's1',
        state: HomeWidgetAgentState.toolExecution,
        nowMs: _t0 + 5000,
        toolName: 'terminal',
      );
      var entry = tracker.list.single;
      expect(entry.phase, 'Terminal');
      expect(entry.startedAtMs, _t0);
      expect(entry.title, 'Limpiar', reason: 'a later event without a title');

      const need = HomeWidgetNeed(requestId: 'req-1', text: 'rm -rf build/');
      tracker.update(
        owner: chat,
        sessionId: 's1',
        state: HomeWidgetAgentState.waitingApproval,
        nowMs: _t0 + 9000,
        need: need,
      );
      entry = tracker.list.single;
      expect(entry.needsYou, isTrue);
      expect(entry.need!.requestId, 'req-1');
      expect(entry.phase, isNull);
      expect(entry.startedAtMs, _t0);

      // Answered: it goes on, the same turn, with nothing left to answer.
      tracker.update(
        owner: chat,
        sessionId: 's1',
        state: HomeWidgetAgentState.streaming,
        nowMs: _t0 + 20000,
      );
      entry = tracker.list.single;
      expect(entry.need, isNull);
      expect(entry.startedAtMs, _t0);

      // The same state again is not a change (no redraw for it).
      expect(
        tracker.update(
          owner: chat,
          sessionId: 's1',
          state: HomeWidgetAgentState.streaming,
          nowMs: _t0 + 21000,
        ),
        isFalse,
      );
      // Done: off the list. A next turn starts its own clock.
      expect(
        tracker.update(
          owner: chat,
          sessionId: 's1',
          state: HomeWidgetAgentState.idle,
          nowMs: _t0 + 30000,
        ),
        isTrue,
      );
      expect(tracker.list, isEmpty);
      tracker.update(
        owner: chat,
        sessionId: 's1',
        state: HomeWidgetAgentState.thinking,
        nowMs: _t0 + 60000,
      );
      expect(tracker.list.single.startedAtMs, _t0 + 60000);
    });

    test('the turn\'s own clock wins over the moment it was first seen', () {
      final tracker = HomeWidgetActivityTracker();
      final chat = Object();
      // First seen three minutes into the turn (the app came back to it).
      tracker.update(
        owner: chat,
        sessionId: 's1',
        state: HomeWidgetAgentState.streaming,
        nowMs: _t0 + 180000,
        turnStartedAtMs: _t0,
      );
      expect(tracker.list.single.startedAtMs, _t0);
      // The gateway then names an earlier start: the row follows it.
      expect(
        tracker.update(
          owner: chat,
          sessionId: 's1',
          state: HomeWidgetAgentState.streaming,
          nowMs: _t0 + 181000,
          turnStartedAtMs: _t0 - 5000,
        ),
        isTrue,
      );
      expect(tracker.list.single.startedAtMs, _t0 - 5000);
      // A phase that brings no clock keeps the one already known.
      tracker.update(
        owner: chat,
        sessionId: 's1',
        state: HomeWidgetAgentState.toolExecution,
        nowMs: _t0 + 182000,
        toolName: 'terminal',
      );
      expect(tracker.list.single.startedAtMs, _t0 - 5000);
      // The next turn of the same chat, with no pause between: its own start.
      tracker.update(
        owner: chat,
        sessionId: 's1',
        state: HomeWidgetAgentState.thinking,
        nowMs: _t0 + 200000,
        turnStartedAtMs: _t0 + 199000,
      );
      expect(tracker.list.single.startedAtMs, _t0 + 199000);
      // Two clocks that disagree: a start after "now" is not believed.
      final other = Object();
      tracker.update(
        owner: other,
        sessionId: 's2',
        state: HomeWidgetAgentState.streaming,
        nowMs: _t0,
        turnStartedAtMs: _t0 + 60000,
      );
      expect(
        tracker.list.firstWhere((e) => e.sessionId == 's2').startedAtMs,
        _t0,
      );
    });

    test(
      'who waits for you comes first; a chat keeps its row when its id changes',
      () {
        final tracker = HomeWidgetActivityTracker();
        final a = Object(), b = Object(), c = Object();
        tracker
          ..update(
            owner: a,
            sessionId: 'old',
            state: HomeWidgetAgentState.streaming,
            nowMs: _t0,
          )
          ..update(
            owner: b,
            sessionId: 'later',
            state: HomeWidgetAgentState.toolExecution,
            nowMs: _t0 + 1000,
          )
          ..update(
            owner: c,
            sessionId: 'asks',
            state: HomeWidgetAgentState.waitingApproval,
            nowMs: _t0 + 2000,
          );
        expect(tracker.list.map((e) => e.sessionId), ['asks', 'old', 'later']);
        // The provisional id became the durable one: one row, same start.
        tracker.update(
          owner: a,
          sessionId: 'durable',
          state: HomeWidgetAgentState.streaming,
          nowMs: _t0 + 3000,
        );
        expect(tracker.list.map((e) => e.sessionId), [
          'asks',
          'durable',
          'later',
        ]);
        expect(tracker.list[1].startedAtMs, _t0);
        expect(tracker.remove(c), isTrue);
        expect(tracker.remove(c), isFalse);
        expect(tracker.list.map((e) => e.sessionId), ['durable', 'later']);
        // Never more than the snapshot stores.
        for (var i = 0; i < 20; i++) {
          tracker.update(
            owner: Object(),
            sessionId: 's$i',
            state: HomeWidgetAgentState.thinking,
            nowMs: _t0 + 10000 + i,
          );
        }
        expect(tracker.list, hasLength(HermesHomeWidgetSnapshot.maxActive));
        tracker.clear();
        expect(tracker.list, isEmpty);
      },
    );
  });

  group('the chat service publishes it', () {
    late _Store store;
    late HermesHomeWidgetPublisher publisher;
    late ActiveChatService service;
    late FakeAsync clock;

    int now() => _t0 + clock.elapsed.inMilliseconds;

    ActiveChat boot(FakeAsync async, {bool readOnly = false}) {
      clock = async;
      store = _Store();
      publisher = HermesHomeWidgetPublisher(store: store, nowMs: now);
      service = ActiveChatService(homeWidgetNowMs: now)
        ..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1');
      final chat = service.attach(
        connection: _connection(readOnly: readOnly),
        sessionId: 'sess-1',
        sessionTitle: 'Limpiar el build',
        disableForegroundKeepAlive: true,
        wallClockMsForTesting: now,
      );
      async.flushMicrotasks();
      return chat;
    }

    test('a running turn is listed with its start; a finished one is not', () {
      fakeAsync((async) {
        final chat = boot(async);
        chat.state = ChatPipelineState.waiting;
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.started);
        async.flushMicrotasks();
        var active = store.snapshot.active;
        expect(active.single.sessionId, 'sess-1');
        expect(active.single.state, HomeWidgetAgentState.thinking);
        expect(active.single.title, 'Limpiar el build');
        expect(active.single.startedAtMs, _t0);

        async.elapse(const Duration(seconds: 42));
        chat.state = ChatPipelineState.streaming;
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.token);
        async.flushMicrotasks();
        active = store.snapshot.active;
        expect(active.single.state, HomeWidgetAgentState.streaming);
        // The timer counts from the turn's start, not from the last phase.
        expect(active.single.startedAtMs, _t0);

        chat.state = ChatPipelineState.completed;
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.done);
        async.flushMicrotasks();
        expect(store.snapshot.active, isEmpty);
        expect(store.snapshot.agentState, HomeWidgetAgentState.idle);
        // …and a late subagent refresh does not bring it back.
        service.debugHomeWidgetChatEvent(
          chat,
          ActiveChatEvent.subagentActivity,
        );
        async.flushMicrotasks();
        expect(store.snapshot.active, isEmpty);
        service.dispose();
      });
    });

    test('the timer starts at the turn\'s start, not at the first sight', () {
      fakeAsync((async) {
        final chat = boot(async);
        // The turn runs and the chat fixes its clock (what the in-app timer
        // counts from). The widget only hears of it forty seconds later.
        chat.state = ChatPipelineState.streaming;
        expect(chat.anchorTurnClock()!.millisecondsSinceEpoch, _t0);
        async.elapse(const Duration(seconds: 40));
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.token);
        async.flushMicrotasks();
        expect(store.snapshot.active.single.startedAtMs, _t0);
        service.dispose();
      });
    });

    test('a pending approval reaches the widget with its answer payload', () {
      fakeAsync((async) {
        final chat = boot(async);
        chat.state = ChatPipelineState.executing;
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.toolProgress);
        async.flushMicrotasks();
        chat.pendingApproval = {
          'request_id': 'req-9',
          'command': 'rm -rf build/',
          'choices': ['once', 'deny'],
        };
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.approvalRequest);
        async.flushMicrotasks();
        final waiting = store.snapshot.active.single;
        expect(waiting.needsYou, isTrue);
        expect(waiting.need!.requestId, 'req-9');
        expect(waiting.need!.text, 'rm -rf build/');
        final payload = NotificationActionPayload.tryParse(
          waiting.need!.actionPayload,
        )!;
        expect(payload.route, NotificationActionRoute.chat);
        expect(payload.connId, 'conn-1');
        expect(payload.sessionId, 'sess-1');
        expect(payload.requestId, 'req-9');
        expect(store.snapshot.agentState, HomeWidgetAgentState.waitingApproval);

        // Answered (here or anywhere): nothing left to answer on the widget.
        chat.pendingApproval = null;
        chat.state = ChatPipelineState.executing;
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.toolProgress);
        async.flushMicrotasks();
        expect(store.snapshot.active.single.need, isNull);
        expect(store.snapshot.active.single.needsYou, isFalse);
        service.dispose();
      });
    });

    test('a read-only instance shows the request without buttons', () {
      fakeAsync((async) {
        final chat = boot(async, readOnly: true);
        chat.state = ChatPipelineState.executing;
        chat.pendingApproval = {
          'request_id': 'req-9',
          'command': 'rm -rf build/',
          'choices': ['once', 'deny'],
        };
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.approvalRequest);
        async.flushMicrotasks();
        final waiting = store.snapshot.active.single;
        expect(waiting.need!.requestId, 'req-9');
        expect(waiting.need!.actionPayload, isNull);
        service.dispose();
      });
    });

    test('switching instance clears the other instance\'s activity', () {
      fakeAsync((async) {
        final chat = boot(async);
        chat.state = ChatPipelineState.streaming;
        service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.token);
        async.flushMicrotasks();
        expect(store.snapshot.active, hasLength(1));
        service.setHomeWidgetActiveConnection('conn-2');
        async.flushMicrotasks();
        expect(store.snapshot.active, isEmpty);
        service.dispose();
      });
    });
  });
}
