import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity_peer_test.dart' as peer;
import 'support/in_memory_compression_restore_storage.dart';

ActiveChat productionChat(peer.PeerGateway gateway) => ActiveChat(
  connection: SavedConnection(
    id: 'peer',
    label: 'Peer',
    host: 'example.invalid',
    port: 443,
    apiKey: 'fixture',
    useHttps: true,
  ),
  sessionId: 'stored-peer',
  sessionTitle: 'Peer',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'fixture',
    httpClient: MockClient((_) async => http.Response('not found', 404)),
  ),
  desktopGateway: gateway,
  compressionRestoreStore: testCompressionRestoreStore(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'acquisition revokes synchronously and awaits durable privacy checkpoint',
    () async {
      SharedPreferences.setMockInitialValues({});
      final storage = <String, String>{};
      final writeStarted = Completer<void>();
      final release = Completer<void>();
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              final args = (call.arguments as Map?) ?? {};
              switch (call.method) {
                case 'read':
                  return storage[args['key']];
                case 'readAll':
                  return Map<String, String>.of(storage);
                case 'write':
                  if (!writeStarted.isCompleted) writeStarted.complete();
                  await release.future;
                  storage[args['key'] as String] = args['value'] as String;
              }
              return null;
            },
          );
      final gateway = peer.PeerGateway(
        peer.snap([peer.publicSnapshot, peer.privateSnapshot]),
      );
      final chat = productionChat(gateway);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        chat.dispose();
      });
      chat.replaceInternalMessagesForTesting([
        peer.privateRest,
        peer.publicUser,
      ]);
      var returned = false;
      final acquisition = chat
          .ensureDesktopRuntime(acquireForExplicitAction: true)
          .then((value) {
            returned = true;
            return value;
          });
      // A finite event-loop drain tests the absence of early success without
      // depending on a timeout of the awaited operation as the failure oracle.
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        returned,
        isFalse,
        reason: 'success must wait for durable evidence',
      );
      expect(writeStarted.isCompleted, isTrue);
      expect(jsonEncode(chat.messages), isNot(contains('PRIVATE_REVOKED')));
      expect(jsonEncode(chat.messages), contains('PUBLIC_USER'));
      release.complete();
      expect(await acquisition, isTrue);
      expect(storage, isNotEmpty);
      expect(jsonEncode(storage), isNot(contains('PRIVATE_REVOKED')));
    },
  );

  test(
    'request-fallback binding cannot rebase a different durable scope',
    () async {
      SharedPreferences.setMockInitialValues({});
      final gateway = peer.PeerGateway(
        const DesktopSessionSnapshot(
          runtimeSessionId: 'runtime-other',
          storedSessionId: 'different-stored',
          created: false,
        ),
      );
      final chat = productionChat(gateway);
      addTearDown(chat.dispose);
      expect(
        await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
        isFalse,
      );
      expect(chat.desktopRuntimeSessionId, isNull);
    },
  );

  test('binding forwards typed stored identity provenance', () {
    final snapshot = DesktopSessionSnapshot.fromJson(
      const {
        'session_id': 'runtime',
        'session_key': 'stored',
        'messages': <Object>[],
      },
      requestedStoredSessionId: 'request',
      created: false,
      method: 'session.resume',
    );
    final binding = DesktopSessionBinding.fromSnapshot(snapshot);
    expect(
      binding.storedSessionIdProvenance,
      DesktopStoredSessionIdProvenance.sessionKey,
    );
  });
}
