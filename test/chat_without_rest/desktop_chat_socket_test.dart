import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

import '../support/desktop_chat_socket.dart';
import '../support/in_memory_compression_restore_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final connection = SavedConnection(
    id: 'local',
    label: 'Local',
    host: 'example.invalid',
    port: 443,
    apiKey: 'fixture',
    useHttps: true,
  );

  late DesktopChatSocket socket;
  late ActiveChat chat;
  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
    socket = DesktopChatSocket();
    chat = ActiveChat(
      connection: connection,
      sessionId: 'session',
      sessionTitle: 'Chat',
      sessionProfile: 'default',
      notifications: null,
      onTerminal: () {},
      desktopGateway: socket,
      compressionRestoreStore: testCompressionRestoreStore(),
      storedMessageLoader: (_, _) async => const [],
      terminalReconcileBudget: Duration.zero,
    );
    chat.smoothStreaming = false;
    addTearDown(chat.dispose);
    addTearDown(socket.close);
  });

  Future<void> send(String text) async => expect(
    await chat.send(fullText: text, model: 'hermes-agent', history: []),
    isTrue,
  );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  group('DesktopChatSocket', () {
    test('a turn records its submit and shows the scripted answer', () async {
      await send('hola');
      expect(socket.submitTexts, ['hola']);
      socket.token(1, 'Ho');
      socket.token(1, 'la');
      socket.complete(1, 'Hola');
      await settle();
      expect(
        chat.messages.where((m) => m['role'] == 'assistant').last['content'],
        'Hola',
      );
    });

    test(
      'toolStarted and approval reach the chat; approve answers by id',
      () async {
        await send('deploy');
        socket.toolStarted(1, 'terminal', context: 'git push');
        socket.approval(1, requestId: 'req-7');
        await settle();
        expect(chat.pendingApproval?['request_id'], 'req-7');
        await chat.resolveApproval('once');
        expect(socket.approvals, [
          (requestId: 'req-7', choice: 'once', all: false),
        ]);
        expect(chat.pendingApproval, isNull);
      },
    );

    test('Stop sends one session.interrupt', () async {
      await send('largo');
      socket.token(1, 'a');
      await settle();
      await chat.cancel();
      expect(socket.interrupts, 1);
    });

    test('fail ends the turn with the server error', () async {
      await send('x');
      socket.fail(1, 'provider down');
      await settle();
      expect(chat.state, ChatPipelineState.failed);
    });

    test('a turn that was never submitted is an error in the script', () {
      expect(() => socket.token(1, 'x'), throwsStateError);
    });

    test('submitError loses the prompt before it is recorded', () async {
      socket.submitError = StateError('socket down');
      await chat.send(fullText: 'x', model: 'hermes-agent', history: []);
      expect(socket.submits, isEmpty);
    });
  });

  group('HostCounter', () {
    test('counts requests per host:port and routes /v1/runs to 503', () async {
      final counter = HostCounter(
        handler: (_) async => http.Response(jsonEncode({'ok': true}), 200),
      );
      expect(
        (await counter.get(Uri.parse('https://a.invalid/api/x'))).statusCode,
        200,
      );
      await counter.get(Uri.parse('http://b.invalid:8642/api/y'));
      expect(counter.byHost, {'a.invalid:443': 1, 'b.invalid:8642': 1});
      expect(counter.runsRequests, isEmpty);
      counter.verify();
      final runs = await counter.post(
        Uri.parse('http://b.invalid:8642/v1/runs'),
      );
      expect(runs.statusCode, 503);
      expect(counter.runsRequests, ['b.invalid:8642 POST /v1/runs']);
      expect(counter.verify, throwsA(isA<TestFailure>()));
      // The tear down would fail this test: consume the evidence.
      counter.requests.clear();
    });

    test('the tear down check fails after a /v1/runs request', () async {
      late void Function() check;
      final counter = HostCounter(register: (fn) => check = fn);
      check();
      expect(counter.verifiedAtTearDown, isTrue);
      await counter.post(Uri.parse('http://b.invalid:8642/v1/runs'));
      expect(check, throwsA(isA<TestFailure>()));
    });

    HostCounter? first;
    test('the tear down check is registered', () => first = HostCounter());
    test('the previous test ran it', () {
      expect(first!.verifiedAtTearDown, isTrue);
    });
  });
}
