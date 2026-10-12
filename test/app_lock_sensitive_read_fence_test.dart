// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/app_lock_sensitive_read_fence.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(secure, null);
  });

  test(
    'each independent internal draft mutation refuses locked storage, not empty or success',
    () async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      final prefs = await SharedPreferences.getInstance();
      final lock = AppLockService(prefs);
      final store = ChatDraftStore(prefs);
      var reads = 0;
      var mutations = 0;
      messenger.setMockMethodCallHandler(secure, (call) async {
        if (call.method == 'readAll' ||
            (call.method == 'read' &&
                ((call.arguments as Map)['key'] as String).startsWith(
                  'chat_draft',
                ))) {
          reads++;
        }
        if (call.method == 'write' || call.method == 'delete') mutations++;
        return null;
      });
      final attempts = <Future<Object?> Function()>[
        () => store.load('c', 's'),
        () => store.listForConnection('c'),
        () => store.save('c', 's', 'sensitive', const []),
        () => store.clear('c', 's'),
        () => store.clear('c', 's', onlyPreparedTurnClientTurnId: 't'),
        () => store.clearForSession('c', 's'),
        () => store.deleteForProfile('c', 'p'),
        () => store.deleteForConnection('c'),
      ];
      for (final attempt in attempts) {
        await expectLater(attempt(), throwsA(isA<SensitiveReadUnavailable>()));
      }
      expect(reads, 0);
      expect(mutations, 0);
      expect(lock.locked.value, isTrue);
    },
  );

  test(
    'load rejects an in-flight lock-unlock ABA without decode or cleanup and recovers fresh',
    () async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      final prefs = await SharedPreferences.getInstance();
      final lock = AppLockService(prefs)..unlock();
      final entered = Completer<void>();
      final release = Completer<void>();
      var deletes = 0;
      messenger.setMockMethodCallHandler(secure, (call) async {
        if (call.method == 'read' &&
            ((call.arguments as Map)['key'] as String).startsWith(
              'chat_draft',
            )) {
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
          return 'CORRUPT_SYNTHETIC_PRIVATE_RAW';
        }
        if (call.method == 'delete') deletes++;
        return null;
      });
      final store = ChatDraftStore(prefs);
      final read = store.load('c', 's');
      final assertion = expectLater(
        read,
        throwsA(isA<SensitiveReadUnavailable>()),
      );
      await entered.future;
      lock.lockNow();
      lock.unlock();
      release.complete();
      await assertion;
      expect(deletes, 0);
      expect((await store.load('c', 's')).text, isEmpty);
      expect(deletes, 1);
    },
  );

  test('queued save does not recapture after lock-unlock ABA', () async {
    SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    final lock = AppLockService(prefs)..unlock();
    final wait = Completer<bool>();
    var reads = 0;
    messenger.setMockMethodCallHandler(secure, (call) async {
      if (call.method == 'read' &&
          ((call.arguments as Map)['key'] as String).startsWith('chat_draft')) {
        reads++;
      }
      return null;
    });
    final result = ChatDraftStore(
      prefs,
    ).save('c', 's', 'synthetic', const [], afterSave: wait.future);
    final assertion = expectLater(
      result,
      throwsA(isA<SensitiveReadUnavailable>()),
    );
    lock.lockNow();
    lock.unlock();
    wait.complete(true);
    await assertion;
    expect(reads, 0);
  });

  test(
    'enabled-lock issuer replacement cannot recover a queued save',
    () async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      final prefs = await SharedPreferences.getInstance();
      AppLockService(prefs).unlock();
      final wait = Completer<bool>();
      var reads = 0;
      messenger.setMockMethodCallHandler(secure, (call) async {
        if (call.method == 'read' &&
            ((call.arguments as Map)['key'] as String).startsWith(
              'chat_draft',
            )) {
          reads++;
        }
        return null;
      });
      final result = ChatDraftStore(
        prefs,
      ).save('c', 's', 'synthetic', const [], afterSave: wait.future);
      final assertion = expectLater(
        result,
        throwsA(isA<SensitiveReadUnavailable>()),
      );
      AppLockService(prefs).unlock();
      wait.complete(true);
      await assertion;
      expect(reads, 0);
    },
  );

  test(
    'issuer replacement and foreground retirement revoke old tickets without ABA renewal',
    () async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      final prefs = await SharedPreferences.getInstance();
      final first = AppLockService(prefs)..unlock();
      final old = AppLockSensitiveReadFence.capture(prefs);
      final second = AppLockService(prefs)..unlock();
      expect(old.isCurrent, isFalse);
      first.releaseDisclosure();
      expect(AppLockSensitiveReadFence.capture(prefs).isCurrent, isTrue);
      final foreground = AppLockSensitiveReadFence.capture(prefs);
      second.onAppPaused();
      second.onAppResumed();
      expect(foreground.isCurrent, isFalse);
      second.releaseDisclosure();
      expect(AppLockSensitiveReadFence.capture(prefs).isCurrent, isFalse);
      await expectLater(
        ChatDraftStore(prefs).load('c', 's'),
        throwsA(isA<SensitiveReadUnavailable>()),
      );
    },
  );

  test(
    'native inbox takes have no new sensitive handoff while locked or headless',
    () async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      final prefs = await SharedPreferences.getInstance();
      final lock = AppLockService(prefs);
      const channel = MethodChannel('hermes/rich_notifications');
      var takes = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'takePendingActions') takes++;
        return <Object?>[];
      });
      try {
        final inbox = PlatformRichNotifications(channel: channel);
        await expectLater(
          inbox.takePendingActions({NotificationActionRoute.room}),
          throwsA(isA<SensitiveReadUnavailable>()),
        );
        lock.releaseDisclosure();
        await expectLater(
          inbox.takePendingActions({NotificationActionRoute.room}),
          throwsA(isA<SensitiveReadUnavailable>()),
        );
        expect(takes, 0);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
}
