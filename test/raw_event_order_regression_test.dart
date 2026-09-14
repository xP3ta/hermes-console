import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final outbox in [false, true]) {
    test(
      '${outbox ? "outbox" : "draft"} save-before-delete with unrelated transcript IO',
      () async {
        SharedPreferences.setMockInitialValues({});
        TurnOutboxStore.resetSerializationForTesting();
        final secure = <String, String>{};
        final entered = Completer<void>(), release = Completer<void>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(
                'plugins.it_nomads.com/flutter_secure_storage',
              ),
              (call) async {
                final a = (call.arguments as Map).cast<String, dynamic>();
                if (call.method == 'read' &&
                    (a['key'] as String).startsWith('hermes.transcript.v3.')) {
                  if (!entered.isCompleted) entered.complete();
                  await release.future;
                }
                switch (call.method) {
                  case 'read':
                    return secure[a['key']];
                  case 'readAll':
                    return Map<String, String>.of(secure);
                  case 'write':
                    secure[a['key']] = a['value'];
                    return null;
                  case 'delete':
                    secure.remove(a['key']);
                    return null;
                }
                return null;
              },
            );
        final drafts = ChatDraftStore(await SharedPreferences.getInstance());
        final store = TurnOutboxStore();
        final blocker = LocalTranscriptStore.saveFromNewestFirst(
          'unrelated',
          's',
          const [
            {'role': 'assistant', 'content': 'unrelated'},
          ],
        );
        await entered.future;
        final turn = PreparedTurn(
          connectionId: 'c',
          sessionId: 's',
          clientTurnId: 't',
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          text: 'deleted content',
          attachments: const [],
          model: 'm',
          profile: 'p',
        );
        final saving = outbox
            ? store.save(turn)
            : drafts.save('c', 's', 'deleted content', const [], profile: 'p');
        if (outbox) {
          await store.deleteForChat('c', 's', profile: 'p');
        } else {
          await drafts.clear('c', 's', profile: 'p');
        }
        release.complete();
        await blocker;
        await saving;
        final content = outbox
            ? (await store.loadForChat('c', 's', profile: 'p'))?.text ?? ''
            : (await drafts.load('c', 's', profile: 'p')).text;
        expect(content, isEmpty);
      },
    );
  }
}
