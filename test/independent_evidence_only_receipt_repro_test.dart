import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity_peer_test.dart' as peer;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('R3 evidence-only remote suppression has a durable receipt', () async {
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? const {};
            switch (call.method) {
              case 'read':
                return secure[args['key']];
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
                return null;
              case 'delete':
                secure.remove(args['key']);
                return null;
              case 'readAll':
                return Map<String, String>.of(secure);
            }
            return null;
          },
        );

    final chat = peer.chatFor(
      peer.PeerGateway(peer.snap([peer.privateSnapshot])),
    );
    expect(
      await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
      isTrue,
    );
    expect(chat.messages, isEmpty);

    final reopened = await LocalTranscriptStore.loadSnapshot(
      'peer',
      'stored-peer',
      profile: 'default',
    );
    expect(reopened.privacyCheckpoint, isNotNull);
    expect(reopened.privacyCheckpoint!.facts.single.negative, isTrue);
    expect(
      reopened.privacyCheckpoint!.suppressedWindow,
      isTrue,
      reason: 'the remote private-only window was suppressed in production',
    );
  });
}
