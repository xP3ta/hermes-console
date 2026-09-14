import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'exact turn delete preserves different admitted turn in same chat',
    () async {
      SharedPreferences.setMockInitialValues({});
      TurnOutboxStore.resetSerializationForTesting();
      final secure = <String, String>{};
      final entered = Completer<void>(), release = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              final args = (call.arguments as Map).cast<String, dynamic>();
              if (call.method == 'read' &&
                  (args['key'] as String).startsWith('hermes.transcript.v3.')) {
                if (!entered.isCompleted) entered.complete();
                await release.future;
              }
              switch (call.method) {
                case 'read':
                  return secure[args['key']];
                case 'readAll':
                  return Map<String, String>.of(secure);
                case 'write':
                  secure[args['key']] = args['value'];
                  return null;
                case 'delete':
                  secure.remove(args['key']);
                  return null;
              }
              return null;
            },
          );
      PreparedTurn turn(String id) => PreparedTurn(
        connectionId: 'c',
        sessionId: 's',
        profile: 'p',
        clientTurnId: id,
        text: id,
        attachments: const [],
        model: 'm',
        queued: true,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      final store = TurnOutboxStore();
      final old = turn('old'), fresh = turn('fresh');
      await store.save(old);
      final blocker = LocalTranscriptStore.saveFromNewestFirst(
        'other',
        's',
        const [
          {'role': 'user', 'content': 'block'},
        ],
      );
      await entered.future;
      final saving = store.save(fresh);
      await store.delete(old);
      release.complete();
      await blocker;
      await saving;
      final loaded = await store.loadAllForChat('c', 's', profile: 'p');
      expect(loaded.map((t) => t.clientTurnId), ['fresh']);
    },
  );
}
