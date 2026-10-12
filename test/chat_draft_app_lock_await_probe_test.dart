import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/app_lock_sensitive_read_fence.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  for (final relock in [false, true]) {
    test(
      'draft load waits for save then ${relock ? "refuses revoked read" : "restores under current unlock"}',
      () async {
        SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
        final values = <String, String>{};
        final writeStarted = Completer<void>();
        final writeRelease = Completer<void>();
        AppLockService? observedLock;
        var readsAdmittedLocked = 0;
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              final args = (call.arguments as Map?) ?? const {};
              final key = args['key'] as String? ?? '';
              switch (call.method) {
                case 'read':
                  if (key.startsWith('chat_draft_v3.') &&
                      observedLock?.locked.value == true) {
                    readsAdmittedLocked++;
                  }
                  return values[key];
                case 'write':
                  if (key.startsWith('chat_draft_v3.')) {
                    if (!writeStarted.isCompleted) writeStarted.complete();
                    await writeRelease.future;
                  }
                  values[key] = args['value'] as String;
                  return null;
                case 'delete':
                  values.remove(key);
                  return null;
                case 'readAll':
                  return Map<String, String>.from(values);
                case 'containsKey':
                  return values.containsKey(key);
              }
              return null;
            });
        try {
          final prefs = await SharedPreferences.getInstance();
          final lock = AppLockService(prefs);
          observedLock = lock;
          lock.unlock();
          final store = ChatDraftStore(
            prefs,
            mutationNamespaceForTesting: relock
                ? 'probe-revoked'
                : 'probe-current',
          );
          final save = store.save(
            'synthetic-connection',
            'mob-await-probe',
            'SYNTHETIC_AWAIT_DRAFT',
            const [],
          );
          await writeStarted.future;
          final load = store.load('synthetic-connection', 'mob-await-probe');
          // Let the real reader reach its admitted-save wait, without releasing I/O.
          await Future<void>.delayed(Duration.zero);
          if (relock) lock.lockNow();
          writeRelease.complete();
          expect(
            await save,
            isTrue,
            reason:
                'a write already handed to storage is allowed to finish honestly',
          );
          if (relock) {
            await expectLater(load, throwsA(isA<SensitiveReadUnavailable>()));
          } else {
            expect((await load).text, 'SYNTHETIC_AWAIT_DRAFT');
          }
          expect(
            readsAdmittedLocked,
            0,
            reason: 'load must revalidate unlock after its admitted-save await',
          );
        } finally {
          if (!writeRelease.isCompleted) writeRelease.complete();
          TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        }
      },
    );
  }
}
