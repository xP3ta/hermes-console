import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/utils/chat_error.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/in_memory_compression_restore_storage.dart';
import 'hermes_fixture.dart';

class _RealHttp extends HttpOverrides {}

/// A default-profile chat on a remote instance (`allowTransportFallback` on).
ActiveChat _chat(FakeHermes hermes) {
  final chat = ActiveChat(
    connection: SavedConnection(
      id: 'remote-fixture',
      label: 'Fixture',
      host: '127.0.0.1',
      port: hermes.port,
      apiKey: 'fixture-key',
      dashboardUrl: 'http://127.0.0.1:${hermes.port}',
      kind: InstanceKind.vps,
    ),
    sessionId: 'stored-fixture',
    sessionTitle: 'Fixture',
    notifications: null,
    onTerminal: () {},
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  addTearDown(chat.dispose);
  return chat;
}

Future<bool> _send(ActiveChat chat, String text) => chat
    .send(fullText: text, model: 'hermes-agent', history: const [])
    .timeout(const Duration(seconds: 15));

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
  });
  void scenario(String name, Future<void> Function() body) => test(
    name,
    () => HttpOverrides.runZoned(
      body,
      createHttpClient: _RealHttp().createHttpClient,
    ),
  );

  // Criterion 1: a failure before prompt.submit ends in the official error.
  for (final (name, status, drop, expected) in [
    ('Dashboard 500', 500, false, officialChannelUnavailableError),
    ('Dashboard 404', 404, false, officialChannelUnavailableError),
    ('socket dropped on resume', null, true, officialChannelUnavailableError),
    ('Dashboard 401', 401, false, dashboardSignInRequiredError),
  ]) {
    scenario('$name: $expected, 0 REST, text kept', () async {
      final hermes = await FakeHermes.start(
        rootStatus: status,
        dropOnResume: drop,
      );
      addTearDown(hermes.close);
      final chat = _chat(hermes);
      expect(await _send(chat, 'keep this text'), isFalse);
      await _until(() => chat.state == ChatPipelineState.failed);
      expect(
        chat.messages.firstWhere((m) => m['role'] == 'assistant_error'),
        containsPair('content', expected),
      );
      expect(chat.lastPrompt, 'keep this text');
      expect(hermes.restHits, isEmpty, reason: '${hermes.paths}');
      expect(hermes.rpc('prompt.submit'), isEmpty);
    });
  }

  // Criteria 2-3: with a tool approval pending, only the socket is used.
  Future<(FakeHermes, ActiveChat)> pending() async {
    final hermes = await FakeHermes.start();
    addTearDown(hermes.close);
    hermes.events['prompt.submit'] = {
      'type': 'approval.request',
      'payload': {'request_id': 'approval-1', 'command': 'ls'},
    };
    final chat = _chat(hermes);
    expect(await _send(chat, 'run a tool'), isTrue);
    await _until(() => chat.pendingApproval != null);
    return (hermes, chat);
  }

  scenario('approve: approval.respond only', () async {
    final (hermes, chat) = await pending();
    await chat.resolveApproval('once');
    final params = hermes.rpc('approval.respond').single['params'] as Map;
    expect(params, containsPair('request_id', 'approval-1'));
    expect(params, containsPair('choice', 'once'));
    expect(chat.pendingApproval, isNull);
    expect(hermes.restHits, isEmpty, reason: '${hermes.paths}');
  });

  scenario('stop and voice barge-in: session.interrupt only', () async {
    for (final voice in [false, true]) {
      final (hermes, chat) = await pending();
      voice
          ? await chat.interruptForVoiceBarge(
              settleTimeout: const Duration(milliseconds: 300),
            )
          : await chat.cancel();
      expect(hermes.rpc('session.interrupt'), isNotEmpty);
      expect(hermes.restHits, isEmpty, reason: '${hermes.paths}');
    }
  });
}
