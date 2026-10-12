// tn1215: a tool goes by its registered name on every live surface, from the
// first frame that mentions it. Over Anthropic OAuth `tool.generating` names
// it by its wire id (`mcp__terminal`); the pill, the «Ahora» row, the list
// row and the Home card must read `terminal`, exactly like the finished rows.
// The step `tool.generating` opens is a draft the turn's next move replaces.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/session_live_status.dart';
import 'package:hermes_android/core/models/tool_name.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/widgets/activity_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity_peer_test.dart' as peer;

final Strings _es = StringsEs();

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

  group('canonicalToolName', () {
    test('a built-in tool loses the OAuth wire prefix', () {
      expect(canonicalToolName('mcp__terminal'), 'terminal');
      expect(canonicalToolName('mcp__todo_list'), 'todo_list');
      expect(canonicalToolName('mcp__tool_call'), 'tool_call');
      expect(canonicalToolName('mcp__read_file'), 'read_file');
      expect(canonicalToolName('  mcp__web_search '), 'web_search');
    });

    test('the tools Hermes renames on that wire get their own name back', () {
      expect(canonicalToolName('mcp__chat_history_lookup'), 'session_search');
      expect(canonicalToolName('mcp__context_notes'), 'memory');
    });

    test('a native MCP tool keeps its registered name', () {
      expect(
        canonicalToolName('mcp__linear__list_issues'),
        'mcp__linear__list_issues',
      );
      expect(
        canonicalToolName('mcp__my_server__get_thing'),
        'mcp__my_server__get_thing',
      );
    });

    test('a connector tool is not an MCP server called connectors', () {
      expect(
        canonicalToolName('mcp__connectors__github__create_issue'),
        'connectors__github__create_issue',
      );
    });

    test('plain names and odd input pass through', () {
      expect(canonicalToolName('terminal'), 'terminal');
      expect(canonicalToolName('tool_call'), 'tool_call');
      expect(canonicalToolName('mcp_legacy_tool'), 'mcp_legacy_tool');
      expect(canonicalToolName('mcp__'), 'mcp__');
      expect(canonicalToolName(''), '');
    });
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

    Future<void> emit(
      peer.PeerGateway gateway,
      String type,
      Map<String, dynamic> payload,
    ) async {
      gateway.emit(type, payload);
      await Future<void>.delayed(Duration.zero);
    }

    List<Map<String, dynamic>> liveTrace(ActiveChat chat) =>
        normalizeAssistantActivityTrace(
          chat.messages.firstWhere(
            (message) => message['role'] == 'assistant',
            orElse: () => const <String, dynamic>{},
          )[assistantActivityTraceKey],
        );

    Iterable<Object?> labels(ActiveChat chat) => [
      for (final step in liveTrace(chat))
        if (step['kind'] == 'tool') step['label'],
    ];

    ActivitySteps steps(ActiveChat chat) =>
        ActivitySnapshot.splitSteps(liveTrace(chat));

    /// The pill's headline, built as the chat builds it.
    String? pill(ActiveChat chat) {
      final split = steps(chat);
      final model = buildActivityPillModel(
        ActivitySnapshot(
          turnActive: chat.isStreaming,
          headline: 'Pensando…',
          current: split.current,
        ),
        _es,
        now: DateTime(2026),
        revealAfter: Duration.zero,
      );
      return model == null ? null : [model.action, ?model.detail].join(' · ');
    }

    test(
      'the wire id never reaches the pill, «Ahora» or the list row',
      () async {
        final (chat, gateway) = await running();
        await emit(gateway, 'tool.generating', {'name': 'mcp__terminal'});
        expect(steps(chat).current?.label, 'terminal');
        expect(pill(chat), 'Ejecutando comando');
        expect(chat.liveStatus.toolLabel, 'terminal');
        expect(
          sessionLiveStatusLabel(_es, chat.liveStatus),
          'Ejecutando comando',
        );
        expect(chat.trace.map((event) => event.label), ['terminal']);
        expect(chat.activeVoiceToolLabel, anyOf(isNull, 'terminal'));

        await emit(gateway, 'tool.start', {
          'tool_id': 'call_1',
          'name': 'terminal',
          'args': {'command': 'echo hola'},
        });
        expect(labels(chat), ['terminal'], reason: 'one step, not two');
        expect(pill(chat), 'Ejecutando · echo');
        expect(
          sessionLiveStatusLabel(_es, chat.liveStatus),
          'Ejecutando · echo',
        );

        await emit(gateway, 'tool.complete', {
          'tool_id': 'call_1',
          'name': 'terminal',
        });
        final settled = steps(chat);
        expect(settled.current, isNull, reason: 'nothing left running');
        expect(settled.done.map((step) => step.label), ['terminal']);
        expect(chat.liveStatus.toolLabel, isNull);
        expect(labels(chat).join(' '), isNot(contains('mcp__')));
      },
    );

    /// A turn this surface runs itself: Voice reads its tools.
    Future<(ActiveChat, peer.PeerGateway)> ownTurn() async {
      final (chat, gateway) = await running();
      chat.traceActive = true;
      return (chat, gateway);
    }

    // What Voice and the home-screen widget read: the tools still open.
    List<String> runningLines(ActiveChat chat) => [
      for (final line in chat.trace)
        if (line.status == 'running') line.label,
    ];

    test('the announced call is closed by the tool itself: nothing is left '
        'running for Voice or the home-screen widget', () async {
      final (chat, gateway) = await ownTurn();
      await emit(gateway, 'tool.generating', {'name': 'mcp__terminal'});
      expect(runningLines(chat), ['terminal']);
      expect(chat.activeVoiceToolLabel, 'terminal');

      await emit(gateway, 'tool.start', {
        'tool_id': 'call_1',
        'name': 'terminal',
        'args': {'command': 'echo hola'},
      });
      expect(runningLines(chat), ['terminal'], reason: 'one call, one line');
      expect(chat.activeVoiceToolLabel, 'terminal');

      await emit(gateway, 'tool.complete', {
        'tool_id': 'call_1',
        'name': 'terminal',
      });
      expect(runningLines(chat), isEmpty);
      expect(chat.activeVoiceToolLabel, isNull);
      expect(chat.trace.map((line) => '${line.label}:${line.status}'), [
        'terminal:completed',
      ]);
    });

    test(
      'a call that was only announced goes when another tool runs',
      () async {
        final (chat, gateway) = await ownTurn();
        await emit(gateway, 'tool.generating', {'name': 'mcp__read_file'});
        expect(runningLines(chat), ['read_file']);
        await emit(gateway, 'tool.start', {
          'tool_id': 'call_t',
          'name': 'terminal',
          'args': {'command': 'ls'},
        });
        expect(runningLines(chat), ['terminal']);
        expect(chat.activeVoiceToolLabel, 'terminal');
        await emit(gateway, 'tool.complete', {
          'tool_id': 'call_t',
          'name': 'terminal',
        });
        expect(runningLines(chat), isEmpty);
        expect(chat.activeVoiceToolLabel, isNull);
      },
    );

    test(
      'a result with no start seen still closes what was announced',
      () async {
        final (chat, gateway) = await ownTurn();
        await emit(gateway, 'tool.generating', {'name': 'mcp__terminal'});
        await emit(gateway, 'tool.complete', {
          'tool_id': 'call_1',
          'name': 'terminal',
        });
        expect(runningLines(chat), isEmpty);
        expect(chat.activeVoiceToolLabel, isNull);
      },
    );

    test('progress frames belong to the call that is open', () async {
      final (chat, gateway) = await ownTurn();
      await emit(gateway, 'tool.start', {
        'tool_id': 'call_1',
        'name': 'terminal',
        'args': {'command': 'sleep 5'},
      });
      await emit(gateway, 'tool.progress', {
        'tool_id': 'call_1',
        'name': 'terminal',
      });
      await emit(gateway, 'tool.progress', {
        'tool_id': 'call_1',
        'name': 'terminal',
      });
      expect(runningLines(chat), ['terminal']);
      await emit(gateway, 'tool.complete', {
        'tool_id': 'call_1',
        'name': 'terminal',
      });
      expect(runningLines(chat), isEmpty);
      expect(chat.activeVoiceToolLabel, isNull);
    });

    test('two calls of one tool at once are still two', () async {
      final (chat, gateway) = await ownTurn();
      await emit(gateway, 'tool.generating', {'name': 'mcp__terminal'});
      await emit(gateway, 'tool.start', {
        'tool_id': 'call_a',
        'name': 'terminal',
        'args': {'command': 'sleep 5'},
      });
      await emit(gateway, 'tool.start', {
        'tool_id': 'call_b',
        'name': 'terminal',
        'args': {'command': 'sleep 9'},
      });
      expect(runningLines(chat), ['terminal', 'terminal']);
      await emit(gateway, 'tool.complete', {
        'tool_id': 'call_a',
        'name': 'terminal',
      });
      expect(runningLines(chat), ['terminal']);
      expect(chat.activeVoiceToolLabel, 'terminal');
      await emit(gateway, 'tool.complete', {
        'tool_id': 'call_b',
        'name': 'terminal',
      });
      expect(runningLines(chat), isEmpty);
      expect(chat.activeVoiceToolLabel, isNull);
    });

    test('the task tool on the wire stays out of the steps', () async {
      final (chat, gateway) = await running();
      await emit(gateway, 'tool.generating', {'name': 'mcp__todo_list'});
      expect(steps(chat).current, isNull, reason: 'tasks have their own row');
      expect(chat.liveStatus.toolLabel, isNull);

      await emit(gateway, 'tool.start', {
        'tool_id': 'call_t',
        'name': 'todo_list',
        'args': {
          'todos': [
            {'id': '1', 'content': 'Leer', 'status': 'in_progress'},
          ],
        },
      });
      await emit(gateway, 'tool.complete', {
        'tool_id': 'call_t',
        'name': 'todo_list',
      });
      expect(labels(chat), ['todo_list']);
      expect(
        liveTrace(chat).where((step) => step['status'] == 'running'),
        isEmpty,
      );
    });

    test('a bridged call shows the wrapped tool, never the bridge', () async {
      final (chat, gateway) = await running();
      await emit(gateway, 'tool.generating', {'name': 'mcp__tool_call'});
      expect(steps(chat).current, isNull);
      expect(chat.liveStatus.toolLabel, isNull);

      await emit(gateway, 'tool.start', {
        'tool_id': 'call_b',
        'name': 'tool_call',
        'args': {
          'calls': [
            {
              'name': 'terminal',
              'arguments': {'command': 'ls -la'},
            },
          ],
        },
      });
      expect(labels(chat), ['terminal'], reason: 'the bridge draft is gone');
      expect(pill(chat), 'Ejecutando · ls');
      expect(chat.liveStatus.toolLabel, 'terminal');

      await emit(gateway, 'tool.complete', {
        'tool_id': 'call_b',
        'name': 'tool_call',
        'args': {
          'calls': [
            {
              'name': 'terminal',
              'arguments': {'command': 'ls -la'},
            },
          ],
        },
      });
      expect(steps(chat).current, isNull);
      expect(steps(chat).done.map((step) => step.label), ['terminal']);
    });

    test('a tool registered under another name replaces the draft', () async {
      final (chat, gateway) = await running();
      // A legacy MCP tool: `mcp_linear_get_issue` is `mcp__linear_get_issue`
      // on the wire, which cannot be told from a built-in.
      await emit(gateway, 'tool.generating', {'name': 'mcp__linear_get_issue'});
      expect(steps(chat).current?.label, 'linear_get_issue');

      await emit(gateway, 'tool.start', {
        'tool_id': 'call_m',
        'name': 'mcp_linear_get_issue',
        'args': const <String, dynamic>{},
      });
      expect(labels(chat), ['mcp_linear_get_issue']);

      await emit(gateway, 'tool.complete', {
        'tool_id': 'call_m',
        'name': 'mcp_linear_get_issue',
      });
      expect(steps(chat).current, isNull);
      expect(steps(chat).done.map((step) => step.label), [
        'mcp_linear_get_issue',
      ]);
    });

    test('text after a draft retires it', () async {
      final (chat, gateway) = await running();
      await emit(gateway, 'tool.generating', {'name': 'mcp__read_file'});
      expect(chat.liveStatus.phase, SessionLivePhase.runningTool);

      final events = <ActiveChatEvent>[];
      final sub = chat.changes.listen(events.add);
      addTearDown(sub.cancel);
      await emit(gateway, 'message.delta', {'text': 'Mejor te lo explico'});
      expect(labels(chat), isEmpty);
      expect(chat.liveStatus.toolLabel, isNull);
      expect(events, contains(ActiveChatEvent.toolProgress));
    });

    test('a draft is never a finished step of the turn', () async {
      final (chat, gateway) = await running();
      await emit(gateway, 'tool.start', {
        'tool_id': 'call_r',
        'name': 'read_file',
        'args': {'path': '/tmp/notas.md'},
      });
      await emit(gateway, 'tool.complete', {
        'tool_id': 'call_r',
        'name': 'read_file',
      });
      await emit(gateway, 'tool.generating', {'name': 'mcp__terminal'});
      expect(steps(chat).current?.label, 'terminal');

      await emit(gateway, 'message.complete', {'text': 'Hecho'});
      expect(chat.isStreaming, isFalse);
      final finished = [
        for (final message in chat.messages)
          if (message['role'] == 'assistant')
            for (final step in normalizeAssistantActivityTrace(
              message[assistantActivityTraceKey],
            ))
              if (step['kind'] == 'tool') '${step['label']}:${step['status']}',
      ];
      expect(finished, ['read_file:completed']);
    });

    test('an error ends the turn without leaving the draft running', () async {
      final (chat, gateway) = await running();
      await emit(gateway, 'tool.generating', {'name': 'mcp__terminal'});
      await emit(gateway, 'error', {'message': 'boom'});
      expect(chat.isStreaming, isFalse);
      for (final message in chat.messages) {
        final trace = normalizeAssistantActivityTrace(
          message[assistantActivityTraceKey],
        );
        expect(trace.where((step) => step['kind'] == 'tool'), isEmpty);
      }
    });
  });
}
