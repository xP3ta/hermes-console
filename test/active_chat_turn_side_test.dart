import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/utils/turn_control.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/turn_side_gateway.dart';

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'turn-side',
  label: 'Turn side',
  host: 'hermes.example.test',
  port: 8642,
  apiKey: 'test-key',
  readOnly: readOnly,
);

ActiveChat _chat(FakeTurnSideGateway gateway, {bool readOnly = false}) =>
    ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: _connection(readOnly: readOnly),
      sessionId: 'session-turn-side',
      sessionTitle: 'Turn side',
      notifications: null,
      onTerminal: () {},
      desktopGateway: gateway,
      initialStoredSessionId: 'session-turn-side',
    );

Future<ActiveChat> _streamingChat(FakeTurnSideGateway gateway) async {
  final chat = _chat(gateway);
  addTearDown(chat.dispose);
  addTearDown(gateway.close);
  expect(
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: []),
    isTrue,
  );
  expect(chat.isStreaming, isTrue);
  return chat;
}

Future<void> _pump() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('/btw', () {
    test(
      'sends one prompt.btw while the reply streams and queues nothing',
      () async {
        final gateway = FakeTurnSideGateway();
        final chat = await _streamingChat(gateway);
        chat.enqueue('después');

        final outcome = await chat.askSideQuestion('  ¿qué hora es?  ');

        expect(outcome, SideCommandOutcome.started);
        expect(gateway.callsTo('prompt.btw').map((call) => call.params), [
          {'session_id': 'runtime-side', 'text': '¿qué hora es?'},
        ]);
        expect(gateway.calls, hasLength(1));
        expect(gateway.interrupts, isEmpty);
        expect(gateway.submissions, ['hola']);
        expect(chat.isStreaming, isTrue);
        expect(chat.queuedMessages, ['después']);
      },
    );

    test('an empty question sends nothing', () async {
      final gateway = FakeTurnSideGateway();
      final chat = await _streamingChat(gateway);

      expect(await chat.askSideQuestion('   '), SideCommandOutcome.usage);
      expect(gateway.calls, isEmpty);
    });

    test(
      'method-not-found is remembered and asks for the slash path',
      () async {
        final gateway = FakeTurnSideGateway()
          ..failures.add(
            const DesktopControlFailure(
              DesktopControlFailureKind.unsupported,
              code: -32601,
            ),
          );
        final chat = await _streamingChat(gateway);

        expect(
          await chat.askSideQuestion('hola'),
          SideCommandOutcome.unsupported,
        );
        expect(chat.canRunSideAgents, isFalse);
        expect(
          await chat.askSideQuestion('otra vez'),
          SideCommandOutcome.unsupported,
        );
        expect(gateway.callsTo('prompt.btw'), hasLength(1));
      },
    );

    test('a read-only connection sends nothing', () async {
      final gateway = FakeTurnSideGateway();
      final chat = _chat(gateway, readOnly: true);
      addTearDown(chat.dispose);
      addTearDown(gateway.close);

      expect(await chat.askSideQuestion('hola'), SideCommandOutcome.readOnly);
      expect(chat.canRunSideAgents, isFalse);
      expect(gateway.calls, isEmpty);
    });

    test('a busy chat without a runtime never acquires one', () async {
      final gateway = FakeTurnSideGateway();
      final chat = _chat(gateway)..state = ChatPipelineState.streaming;
      addTearDown(chat.dispose);
      addTearDown(gateway.close);

      expect(
        await chat.askSideQuestion('hola'),
        SideCommandOutcome.unsupported,
      );
      expect(gateway.calls, isEmpty);
      expect(gateway.connectCalls, 0);
    });

    test('btw.complete appends a local row with the question', () async {
      final gateway = FakeTurnSideGateway();
      final chat = await _streamingChat(gateway);

      gateway.emit('btw.complete', {
        'task_id': 'btw-1',
        'question': '¿qué hora es?',
        'text': 'Las tres.',
      });
      await _pump();

      final row = chat.messages.firstWhere(
        (message) => message['display_kind'] == 'side_answer',
      );
      expect(row['role'], 'system');
      expect(row['content'], '[btw "¿qué hora es?" (btw-1)]\nLas tres.');
      expect(row['display_metadata'], {
        'kind': 'btw',
        'question': '¿qué hora es?',
        'answer': 'Las tres.',
        'is_error': false,
      });
      expect(chat.isStreaming, isTrue);

      gateway.emit('btw.complete', {
        'task_id': 'btw-2',
        'question': 'x',
        'text': 'error: boom',
      });
      await _pump();
      final failed = chat.messages.firstWhere(
        (message) => message['_btwTaskId'] == 'btw-2',
      );
      expect((failed['display_metadata'] as Map)['is_error'], isTrue);
    });

    test('a completion for another runtime is ignored', () async {
      final gateway = FakeTurnSideGateway();
      final chat = await _streamingChat(gateway);

      gateway.emit('btw.complete', {
        'task_id': 'btw-other',
        'text': 'no es mío',
      }, sessionId: 'runtime-elsewhere');
      await _pump();

      expect(
        chat.messages.where((m) => m['display_kind'] == 'side_answer'),
        isEmpty,
      );
    });

    test('a completion after dispose changes nothing', () async {
      final gateway = FakeTurnSideGateway();
      final chat = await _streamingChat(gateway);
      final events = <ActiveChatEvent>[];
      final subscription = chat.changes.listen(events.add);
      chat.dispose();
      events.clear();

      gateway.emit('btw.complete', {'task_id': 'late', 'text': 'tarde'});
      await _pump();
      await subscription.cancel();

      expect(events, isEmpty);
    });
  });

  group('/bg', () {
    test(
      'sends one prompt.background while streaming and never queues',
      () async {
        final gateway = FakeTurnSideGateway();
        final chat = await _streamingChat(gateway);

        final outcome = await chat.startBackgroundPrompt('resume el repo');

        expect(outcome, SideCommandOutcome.started);
        expect(
          gateway.callsTo('prompt.background').map((call) => call.params),
          [
            {'session_id': 'runtime-side', 'text': 'resume el repo'},
          ],
        );
        expect(gateway.calls, hasLength(1));
        expect(chat.queuedMessages, isEmpty);
        expect(chat.isStreaming, isTrue);
      },
    );

    test(
      'background.complete reaches the result strip and signals it',
      () async {
        final gateway = FakeTurnSideGateway();
        final chat = await _streamingChat(gateway);
        await chat.startBackgroundPrompt('resume el repo');
        final events = <ActiveChatEvent>[];
        final subscription = chat.changes.listen(events.add);

        gateway.emit('background.complete', {
          'task_id': 'bg-1',
          'text': 'Listo: 3 archivos.',
        });
        gateway.emit('background.complete', {
          'task_id': 'bg-2',
          'text': 'error: boom',
        });
        await _pump();
        await subscription.cancel();

        expect(chat.backgroundTaskOutcomes['bg-1'], (
          text: 'Listo: 3 archivos.',
          isError: false,
        ));
        expect(chat.backgroundTaskOutcomes['bg-2'], (
          text: 'error: boom',
          isError: true,
        ));
        expect(
          events.where(
            (event) => event == ActiveChatEvent.backgroundTaskComplete,
          ),
          hasLength(2),
        );
        expect(chat.queuedMessages, isEmpty);
        expect(chat.isStreaming, isTrue);

        chat.dismissBackgroundTaskOutcome('bg-1');
        expect(chat.backgroundTaskOutcomes.keys, ['bg-2']);
      },
    );

    test(
      'background.complete writes the canonical [bg task_id] system row',
      () async {
        final gateway = FakeTurnSideGateway();
        final chat = await _streamingChat(gateway);

        gateway.emit('background.complete', {
          'task_id': 'bg-task',
          'text': 'Listo: 3 archivos.',
        });
        await _pump();

        final row = chat.messages.singleWhere(
          (message) => message['display_kind'] == 'side_answer',
        );
        expect(row['role'], 'system');
        expect(row['content'], '[bg bg-task]\nListo: 3 archivos.');
        expect((row['display_metadata'] as Map)['kind'], 'bg');
        expect(chat.backgroundTaskOutcomes.keys, ['bg-task']);
      },
    );

    test('a completion for another runtime is ignored', () async {
      final gateway = FakeTurnSideGateway();
      final chat = await _streamingChat(gateway);

      gateway.emit('background.complete', {
        'task_id': 'bg-other',
        'text': 'no es mío',
      }, sessionId: 'runtime-elsewhere');
      await _pump();

      expect(chat.backgroundTaskOutcomes, isEmpty);
      expect(
        chat.messages.where((m) => m['display_kind'] == 'side_answer'),
        isEmpty,
      );
    });

    test(
      'a completion without a task id keeps the trimmed text as a system row',
      () async {
        final gateway = FakeTurnSideGateway();
        final chat = await _streamingChat(gateway);

        gateway.emit('background.complete', {'text': '  la respuesta \n'});
        gateway.emit('background.complete', {'text': '   '});
        await _pump();

        final rows = chat.messages.where(
          (message) => message['display_kind'] == 'side_answer',
        );
        expect(rows, hasLength(1));
        expect(rows.single['role'], 'system');
        expect(rows.single['content'], 'la respuesta');
        expect(chat.backgroundTaskOutcomes, isEmpty);
      },
    );

    test('the task text is trimmed before it is stored', () async {
      final gateway = FakeTurnSideGateway();
      final chat = await _streamingChat(gateway);

      gateway.emit('background.complete', {
        'task_id': 'bg-trim',
        'text': '\n  Hecho.  \n',
      });
      await _pump();

      expect(chat.backgroundTaskOutcomes['bg-trim']!.text, 'Hecho.');
      expect(
        chat.messages.any((m) => m['content'] == '[bg bg-trim]\nHecho.'),
        isTrue,
      );
    });

    test('empty, unsupported and read-only send nothing more', () async {
      final gateway = FakeTurnSideGateway()
        ..failures.add(
          const DesktopControlFailure(
            DesktopControlFailureKind.unsupported,
            code: -32601,
          ),
        );
      final chat = await _streamingChat(gateway);

      expect(await chat.startBackgroundPrompt(''), SideCommandOutcome.usage);
      expect(
        await chat.startBackgroundPrompt('x'),
        SideCommandOutcome.unsupported,
      );
      expect(
        await chat.startBackgroundPrompt('y'),
        SideCommandOutcome.unsupported,
      );
      expect(gateway.callsTo('prompt.background'), hasLength(1));
    });
  });

  group('side answers and transcript refresh', () {
    Future<ActiveChat> open() async {
      final gateway = FakeTurnSideGateway();
      final rows = [
        {'id': 1, 'message_id': 'm1', 'role': 'user', 'content': 'q1'},
        {'id': 2, 'message_id': 'm2', 'role': 'assistant', 'content': 'a1'},
      ];
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: _connection(),
        sessionId: 'session-turn-side',
        sessionTitle: 'Turn side',
        notifications: null,
        onTerminal: () {},
        api: ApiClient(
          baseUrl: 'http://127.0.0.1:8642',
          apiKey: 'test-key',
          httpClient: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'object': 'list',
                'session_id': 'session-turn-side',
                'messages': rows,
                'data': rows,
                'pagination': {
                  'limit': 120,
                  'offset': 0,
                  'order': 'latest',
                  'returned': rows.length,
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ),
        desktopGateway: gateway,
        initialStoredSessionId: 'session-turn-side',
        allowUnownedDesktopSnapshotForTesting: true,
      );
      addTearDown(chat.dispose);
      addTearDown(gateway.close);
      await chat.loadMessages();
      expect(
        await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
        isTrue,
      );
      chat.state = ChatPipelineState.completed;
      gateway.emit('btw.complete', {
        'task_id': 'btw-1',
        'question': 'hora',
        'text': 'Las tres.',
      });
      gateway.emit('background.complete', {
        'task_id': 'bg-task',
        'text': 'Hecho.',
      });
      await _pump();
      return chat;
    }

    test(
      'a transcript refresh keeps both rows in the Desktop format',
      () async {
        final chat = await open();
        expect(chat.messages.where(_isSide), hasLength(2));

        await chat.loadMessages();
        await _pump();

        expect(chat.messages.where(_isSide).map((m) => m['content']).toSet(), {
          '[btw "hora" (btw-1)]\nLas tres.',
          '[bg bg-task]\nHecho.',
        });
        expect(
          chat.messages.where(_isSide).every((m) => m['role'] == 'system'),
          isTrue,
        );
      },
    );

    test('they are not branch history', () async {
      final chat = await open();
      expect(chat.messages.where(isBranchHistoryRow), hasLength(2));
    });
  });
}

bool _isSide(Map<String, dynamic> message) =>
    message['display_kind'] == 'side_answer';
