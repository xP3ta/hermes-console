import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/rpc_frame_helpers.dart';

class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(queryName: 'ticket', credential: 'test');
}

void main() {
  for (final malformed in [false, true]) {
    test('session.history read contract, malformed=$malformed', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
          }),
        );
        await for (final raw in socket) {
          final rpc = jsonDecode(raw as String) as Map<String, dynamic>;
          if (isClientCapabilitiesFrame(rpc)) {
            socket.add(jsonEncode(clientCapabilitiesResponse(rpc)));
            continue;
          }
          requests.add(rpc);
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': rpc['id'],
              'result': {
                // Count is pre-projection; it need not equal messages.length.
                'count': 3,
                'messages': malformed
                    ? 'invalid'
                    : [
                        {
                          'role': 'user',
                          'text': 'Hello',
                          'row_id': 11,
                          'timestamp': 123.0,
                        },
                        {
                          'role': 'assistant',
                          'text': 'Hi',
                          'row_id': 12,
                          'reasoning': 'private reasoning',
                          'display_metadata': {'source': 'fixture'},
                        },
                      ],
              },
            }),
          );
        }
      });
      final client = TuiGatewayClient(
        SavedConnection(
          id: 'history',
          label: 'History',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'owner-key',
          dashboardUrl: 'http://127.0.0.1:${server.port}',
        ),
        dashboard: _Dashboard(),
      );
      addTearDown(client.close);
      await client.connect();
      final read = client.sessionHistory(
        sessionId: 'runtime-resolved',
        profile: 'builder',
      );
      if (malformed) {
        await expectLater(read, throwsFormatException);
      } else {
        final page = await read;
        expect(page.paginationProvided, isFalse);
        expect(page.paginationFullyParsed, isTrue);
        expect(page.messagesFullyParsed, isTrue);
        expect(page.offset, 0);
        expect(page.limit, isNull);
        expect(page.rawMessageCount, 2);
        expect(page.messages.last['display_metadata'], {'source': 'fixture'});
        expect(
          normalizeTranscriptMessageForDisplay(page.messages.first),
          normalizeTranscriptMessageForDisplay({
            'role': 'user',
            'content': 'Hello',
            'row_id': 11,
            'timestamp': 123.0,
          }),
        );
      }
      expect(requests.map((rpc) => rpc['method']), ['session.history']);
      expect(requests.single['params'], {
        'session_id': 'runtime-resolved',
        'profile': 'builder',
      });
    });
  }
}
