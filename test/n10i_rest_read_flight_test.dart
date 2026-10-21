import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';

http.Response _page(String t) => http.Response(
  '{"data":[{"id":1,"message_id":"m1","role":"user","content":"$t"}]}',
  200,
  headers: {'content-type': 'application/json'},
);

class _Rig {
  _Rig() {
    chat = ActiveChat(
      compressionRestoreStore: testCompressionRestoreStore(),
      connection: SavedConnection(
        id: 'n10i',
        label: 'n10i',
        host: 'hermes.local',
        port: 8642,
        apiKey: 'k',
      ),
      sessionId: 'stored-n10i',
      sessionTitle: 'n10i',
      notifications: null,
      onTerminal: () {},
      api: ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'k',
        httpClient: MockClient((request) async {
          gets++;
          final first = gate;
          gate = null;
          return first?.future ?? _page(text);
        }),
      ),
    );
  }

  late final ActiveChat chat;
  Completer<http.Response>? gate, held;
  String text = 'texto';
  int gets = 0;

  Future<void> hold() async {
    addTearDown(chat.dispose);
    await chat.loadMessages();
    gets = 0;
    gate = held = Completer<http.Response>();
  }

  Future<void> finish(List<Future<void>> reads, [int status = 200]) async {
    held!.complete(status == 200 ? _page('texto') : http.Response('', status));
    await Future.wait(reads.map((r) => r.catchError((_) {})));
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('passive reads share one GET; a later one or a failure reads', () async {
    final rig = _Rig();
    await rig.hold();
    final reads = [
      rig.chat.loadMessages(passiveOnly: true),
      rig.chat.loadMessages(passiveOnly: true),
    ];
    await _settle();
    expect(rig.gets, 1);
    await rig.finish(reads, 500);
    await rig.chat.loadMessages(passiveOnly: true);
    expect(rig.gets, 2);
  });

  test('a read after a store change opens its own GET and shows it', () async {
    final rig = _Rig();
    await rig.hold();
    final first = rig.chat.loadMessages(passiveOnly: true);
    await _settle();
    rig.text = 'nuevo';
    rig.chat.adoptDesktopRuntimeForTesting('rt');
    rig.chat.deliverDesktopEventForTesting(
      const TuiGatewayEvent(
        type: 'sessions.changed',
        sessionId: 'rt',
        payload: {},
      ),
    );
    final second = rig.chat.loadMessages(passiveOnly: true);
    await _settle();
    expect(rig.gets, 2);
    await rig.finish([first, second]);
    expect(rig.chat.messages.map((m) => m['content']), contains('nuevo'));
  });

  test('explicit loads still read independently of each other', () async {
    final rig = _Rig();
    await rig.hold();
    final reads = [
      rig.chat.loadMessages(),
      rig.chat.loadMessages(expectedMessageCount: 1),
    ];
    await _settle();
    expect(rig.gets, 2);
    await rig.finish(reads);
  });
}
