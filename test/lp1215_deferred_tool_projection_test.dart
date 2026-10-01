// lp1215: tools invoked through Hermes' deferred-tool bridge
// (`tool_call({calls:[{name, arguments}]})`) must be projected as the real
// tool everywhere: durable history, the activity trace, the tool summary and
// the agent task panel (`todo_list` via the bridge, with merge semantics).
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/agent_task_list.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/widgets/agent_task_widgets.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity_peer_test.dart' as peer;

Map<String, dynamic> _wrappedCall(
  String id,
  List<Map<String, dynamic>> calls,
) => {
  'id': id,
  'type': 'function',
  'function': {
    'name': 'tool_call',
    'arguments': jsonEncode({'calls': calls}),
  },
};

Map<String, dynamic> _todoCall(
  String id,
  List<List<String>> rows, {
  bool? merge,
}) => _wrappedCall(id, [
  {
    'name': 'todo_list',
    'arguments': {
      'merge': ?merge,
      'todos': [
        for (final row in rows)
          {'id': row[0], 'content': row[1], 'status': row[2]},
      ],
    },
  },
]);

Map<String, dynamic> _todoResult(
  int rowId,
  String callId,
  int revision,
  List<List<String>> rows,
) => {
  'id': rowId,
  'role': 'tool',
  'tool_name': 'todo_list',
  'tool_call_id': callId,
  'content': jsonEncode({
    'todos': [
      for (final row in rows)
        {'id': row[0], 'content': row[1], 'status': row[2]},
    ],
    'revision': revision,
    'summary': {'total': rows.length},
  }),
};

/// Observed shape: every todo update goes through
/// the bridge, the last one completes every item with `merge: true`.
List<Map<String, dynamic>> _bridgedTranscript() => [
  {'id': 1, 'role': 'user', 'content': 'PUBLIC_PLAN'},
  {
    'id': 2,
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      _todoCall('call_a', [
        ['1', 'Leer', 'in_progress'],
        ['2', 'Arreglar', 'pending'],
        ['3', 'Probar', 'pending'],
      ]),
    ],
  },
  _todoResult(3, 'call_a', 1, [
    ['1', 'Leer', 'in_progress'],
    ['2', 'Arreglar', 'pending'],
    ['3', 'Probar', 'pending'],
  ]),
  {
    'id': 4,
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      _wrappedCall('call_v', [
        {'name': 'mcp__vault__list_items', 'arguments': <String, dynamic>{}},
      ]),
    ],
  },
  {
    'id': 5,
    'role': 'tool',
    'tool_name': 'tool_call',
    'tool_call_id': 'call_v',
    'content': '{}',
  },
  {
    'id': 6,
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      _todoCall('call_b', merge: true, [
        ['1', 'Leer', 'completed'],
        ['2', 'Arreglar', 'completed'],
        ['3', 'Probar', 'completed'],
      ]),
    ],
  },
  _todoResult(7, 'call_b', 2, [
    ['1', 'Leer', 'completed'],
    ['2', 'Arreglar', 'completed'],
    ['3', 'Probar', 'completed'],
  ]),
  {'id': 8, 'role': 'assistant', 'content': 'PUBLIC_DONE'},
];

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

  group('AgentTaskList bridge helpers', () {
    final base = AgentTaskList.tryParse({
      'revision': 4,
      'todos': [
        {'id': '1', 'content': 'Uno', 'status': 'in_progress'},
        {'id': '2', 'content': 'Dos', 'status': 'pending'},
      ],
    })!;

    test('merge updates only the provided fields and appends new ids', () {
      final next = base.applyWrite(
        jsonEncode({
          'merge': true,
          'todos': [
            {'id': '2', 'status': 'completed'},
            {'id': '9', 'status': 'pending'},
            {'status': 'completed'},
          ],
        }),
      )!;
      expect(next.items.map((item) => item.id), ['1', '2', '9']);
      expect(next.items[1].content, 'Dos');
      expect(next.items[1].status, AgentTaskStatus.completed);
      expect(next.items[2].content, '(no description)');
      expect(next.revision, 4);
    });

    test('a write without todos is not a write', () {
      expect(base.applyWrite({'merge': true}), isNull);
      expect(base.applyWrite('not json'), isNull);
      expect(base.applyWrite({'merge': true, 'todos': []}), isNull);
    });

    test('an unpaired or foreign todo result never seeds the panel', () {
      final result = _todoResult(2, 'orphan', 9, [
        ['1', 'Falso', 'completed'],
      ]);
      expect(
        AgentTaskList.latestFromTranscript([
          {'id': 1, 'role': 'user', 'content': 'x'},
          result,
        ]),
        isNull,
      );
      expect(
        AgentTaskList.latestFromTranscript([
          {
            'id': 1,
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              _wrappedCall('orphan', [
                {'name': 'terminal', 'arguments': {}},
              ]),
            ],
          },
          result,
        ]),
        isNull,
      );
    });
  });

  group('durable history (REST page)', () {
    Future<ActiveChat> load() async {
      final chat = peer.chatFor(
        peer.PeerGateway(null),
        rest: (_) async => peer.restRows(_bridgedTranscript()),
      );
      await chat.loadMessages();
      return chat;
    }

    test('bridged tools keep their real names in the activity trace', () async {
      final chat = await load();
      final assistant = chat.messages.firstWhere(
        (message) => message['role'] == 'assistant',
      );
      final trace = normalizeAssistantActivityTrace(
        assistant[assistantActivityTraceKey],
      );
      final labels = [
        for (final step in trace)
          if (step['kind'] == 'tool') step['label'],
      ];
      expect(labels, ['todo_list', 'mcp__vault__list_items', 'todo_list']);
      expect(labels, isNot(contains('tool_call')));
      final split = ActivitySnapshot.splitSteps(trace);
      expect(split.done.map((step) => step.label), ['mcp__vault__list_items']);
      expect(latestAgentTaskStepId(chat.messages), 'call_b:0');
    });

    test(
      'the task panel adopts the newest paired bridged todo result',
      () async {
        final chat = await load();
        expect(chat.agentTasks.total, 3);
        expect(chat.agentTasks.done, 3);
        expect(chat.agentTasks.isFinished, isTrue);
        expect(chat.agentTasks.revision, 2);
      },
    );
  });

  group('live gateway events', () {
    Future<(ActiveChat, peer.PeerGateway)> running() async {
      final gateway = peer.PeerGateway(
        DesktopSessionSnapshot.fromJson(
          {
            'session_id': 'runtime-peer',
            'session_key': 'stored-peer',
            'message_count': 1,
            'messages': [peer.publicSnapshot],
            'running': true,
            'inflight': {'assistant': '', 'streaming': true},
          },
          requestedStoredSessionId: 'stored-peer',
          created: false,
          method: 'session.resume',
        ),
      );
      final chat = peer.chatFor(gateway);
      await chat.loadMessages();
      expect(chat.isStreaming, isTrue);
      return (chat, gateway);
    }

    List<Map<String, dynamic>> liveTrace(ActiveChat chat) =>
        normalizeAssistantActivityTrace(
          chat.messages.firstWhere(
            (message) => message['role'] == 'assistant',
          )[assistantActivityTraceKey],
        );

    test('a bridged batch start shows each wrapped tool as running', () async {
      final (chat, gateway) = await running();
      gateway.emit('tool.start', {
        'tool_id': 'call_c',
        'name': 'tool_call',
        'args': {
          'calls': [
            {'name': 'mcp__linear__list_issues', 'arguments': {}},
            {'name': 'mcp__github__get_pr', 'arguments': {}},
          ],
        },
      });
      await Future<void>.delayed(Duration.zero);
      final split = ActivitySnapshot.splitSteps(liveTrace(chat));
      expect(split.current?.label, 'mcp__github__get_pr');
      expect(
        liveTrace(chat).map((step) => step['id']),
        containsAll(['call_c:0', 'call_c:1']),
      );

      gateway.emit('tool.complete', {
        'tool_id': 'call_c',
        'name': 'tool_call',
        'args': {
          'calls': [
            {'name': 'mcp__linear__list_issues', 'arguments': {}},
            {'name': 'mcp__github__get_pr', 'arguments': {}},
          ],
        },
      });
      await Future<void>.delayed(Duration.zero);
      final settled = ActivitySnapshot.splitSteps(liveTrace(chat));
      expect(settled.current, isNull);
      expect(settled.done.map((step) => step.label), [
        'mcp__github__get_pr',
        'mcp__linear__list_issues',
      ]);
    });

    test(
      'a bridged todo_list start merges by id; the result is authoritative',
      () async {
        final (chat, gateway) = await running();
        gateway.emit('todo.updated', {
          'revision': 1,
          'todos': [
            {'id': '1', 'content': 'Leer', 'status': 'in_progress'},
            {'id': '2', 'content': 'Arreglar', 'status': 'pending'},
          ],
        });
        await Future<void>.delayed(Duration.zero);
        expect(chat.agentTasks.done, 0);

        final mergeArgs = {
          'calls': [
            {
              'name': 'todo_list',
              'arguments': {
                'merge': true,
                'todos': [
                  {'id': '1', 'status': 'completed'},
                  {'id': '3', 'content': 'Probar', 'status': 'pending'},
                ],
              },
            },
          ],
        };
        gateway.emit('tool.start', {
          'tool_id': 'call_t',
          'name': 'tool_call',
          'args': mergeArgs,
        });
        await Future<void>.delayed(Duration.zero);
        expect(chat.agentTasks.items.map((item) => item.id), ['1', '2', '3']);
        expect(chat.agentTasks.items.first.content, 'Leer');
        expect(chat.agentTasks.done, 1);
        expect(chat.agentTasks.revision, 1, reason: 'a start never moves it');

        gateway.emit('tool.complete', {
          'tool_id': 'call_t',
          'name': 'todo_list',
          'args': mergeArgs['calls']!.single['arguments'],
          'revision': 2,
          'todos': [
            {'id': '1', 'content': 'Leer', 'status': 'completed'},
            {'id': '2', 'content': 'Arreglar', 'status': 'completed'},
            {'id': '3', 'content': 'Probar', 'status': 'completed'},
          ],
        });
        await Future<void>.delayed(Duration.zero);
        expect(chat.agentTasks.isFinished, isTrue);
        expect(chat.agentTasks.revision, 2);
      },
    );

    test('re-attaching to the running turn keeps the running tool', () async {
      final (chat, gateway) = await running();
      gateway.emit('tool.start', {
        'tool_id': 'call_s',
        'name': 'terminal',
        'args': {'command': 'sleep 30'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        ActivitySnapshot.splitSteps(liveTrace(chat)).current?.label,
        'terminal',
      );
      // Re-open/reattach: session.resume answers with the same running turn,
      // described only by `inflight`.
      await chat.loadMessages();
      final current = ActivitySnapshot.splitSteps(liveTrace(chat)).current;
      expect(current?.label, 'terminal');
      expect(current?.detail, 'sleep');
    });

    test(
      'tool.generating never leaves a finished tool as the running one',
      () async {
        final (chat, gateway) = await running();
        gateway.emit('tool.generating', {'name': 'terminal'});
        await Future<void>.delayed(Duration.zero);
        expect(
          ActivitySnapshot.splitSteps(liveTrace(chat)).current?.label,
          'terminal',
        );
        gateway.emit('tool.start', {
          'tool_id': 'call_g',
          'name': 'terminal',
          'args': {'command': 'ls'},
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          ActivitySnapshot.splitSteps(liveTrace(chat)).current?.detail,
          'ls',
        );
        gateway.emit('tool.complete', {
          'tool_id': 'call_g',
          'name': 'terminal',
        });
        await Future<void>.delayed(Duration.zero);
        final split = ActivitySnapshot.splitSteps(liveTrace(chat));
        expect(split.current, isNull);
        expect(split.done.map((step) => step.label), ['terminal']);
      },
    );

    test('a bridged todo_list without merge replaces the list', () async {
      final (chat, gateway) = await running();
      gateway.emit('todo.updated', {
        'revision': 1,
        'todos': [
          {'id': '1', 'content': 'Viejo', 'status': 'in_progress'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      gateway.emit('tool.start', {
        'tool_id': 'call_r',
        'name': 'tool_call',
        'args': {
          'calls': [
            {
              'name': 'todo_list',
              'arguments': {
                'todos': [
                  {'id': 'a', 'content': 'Nuevo', 'status': 'pending'},
                ],
              },
            },
          ],
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(chat.agentTasks.items.map((item) => item.content), ['Nuevo']);
    });
  });

  test('tool summary names the wrapped tools, not the bridge', () {
    final info = ChatEventInfo.classify({
      'role': 'assistant',
      'content': '',
      'tool_calls': [
        _wrappedCall('c1', [
          {
            'name': 'terminal',
            'arguments': {'command': 'ls'},
          },
          {
            'name': 'read_file',
            'arguments': {'path': 'a.md'},
          },
        ]),
      ],
    });
    expect(info.tools.map((tool) => tool.label), ['terminal', 'read_file']);
  });
}
