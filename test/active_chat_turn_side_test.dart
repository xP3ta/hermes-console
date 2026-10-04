import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/utils/turn_control.dart';

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
    test('sends one prompt.btw while the reply streams and queues nothing', () async {
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
    });

    test('an empty question sends nothing', () async {
      final gateway = FakeTurnSideGateway();
      final chat = await _streamingChat(gateway);

      expect(await chat.askSideQuestion('   '), SideCommandOutcome.usage);
      expect(gateway.calls, isEmpty);
    });

    test('method-not-found is remembered and asks for the slash path', () async {
      final gateway = FakeTurnSideGateway()
        ..failures.add(
          const DesktopControlFailure(
            DesktopControlFailureKind.unsupported,
            code: -32601,
          ),
        );
      final chat = await _streamingChat(gateway);

      expect(await chat.askSideQuestion('hola'), SideCommandOutcome.unsupported);
      expect(chat.canRunSideAgents, isFalse);
      expect(await chat.askSideQuestion('otra vez'), SideCommandOutcome.unsupported);
      expect(gateway.callsTo('prompt.btw'), hasLength(1));
    });

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

      expect(await chat.askSideQuestion('hola'), SideCommandOutcome.unsupported);
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
      expect(row['content'], 'Las tres.');
      expect(row['display_metadata'], {
        'kind': 'btw',
        'question': '¿qué hora es?',
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
    test('sends one prompt.background while streaming and never queues', () async {
      final gateway = FakeTurnSideGateway();
      final chat = await _streamingChat(gateway);

      final outcome = await chat.startBackgroundPrompt('resume el repo');

      expect(outcome, SideCommandOutcome.started);
      expect(gateway.callsTo('prompt.background').map((call) => call.params), [
        {'session_id': 'runtime-side', 'text': 'resume el repo'},
      ]);
      expect(gateway.calls, hasLength(1));
      expect(chat.queuedMessages, isEmpty);
      expect(chat.isStreaming, isTrue);
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
}
