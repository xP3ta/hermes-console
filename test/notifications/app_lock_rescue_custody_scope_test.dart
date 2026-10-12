// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/app_lock_sensitive_read_fence.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_action_drain.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Scope probe: real drainer/router/dedupe; opaque synthetic reply and ids.
// No new durable reply store or native inbox implementation is introduced.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    AppLockSensitiveReadFence.bind(Object(), prefs, ValueNotifier(false));
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });
  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  test('suffix collision preserves both actions before custody ACK', () async {
    final prefs = await SharedPreferences.getInstance();
    final values = <String, String>{};
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?) ?? const {};
          final key = args['key'] as String? ?? '';
          switch (call.method) {
            case 'read':
              return values[key];
            case 'write':
              values[key] = args['value'] as String;
              return null;
            case 'delete':
              values.remove(key);
              return null;
            case 'readAll':
              return Map<String, String>.from(values);
          }
          return null;
        });
    final store = ChatDraftStore(prefs);
    final p = _reply().payload;
    final address = replyDraftAddress(p, activeProfile: '')!;
    await store.save(
      p.connId,
      address.sessionId,
      'unrelated synthetic reply',
      const [],
      profile: address.profile,
    );
    final inbox = _ClaimedInbox();
    await NotificationActionDrainer(
      inbox: inbox,
      router: NotificationActionRouter(
        ops: _Ops()..fail = true,
        sink: _Sink(),
        t: const NotifL10n(false),
      ),
      routes: allNotificationActionRoutes,
      rescue: DraftReplyRescue(prefs, store: store),
    ).drain();
    expect(
      (await store.load(
        p.connId,
        address.sessionId,
        profile: address.profile,
      )).text,
      'unrelated synthetic reply\nsynthetic reply',
    );
    expect(inbox.acked, isTrue);
  });

  test(
    'distinct equal replies survive concurrent atomic incorporation',
    () async {
      final f = await _DiskRescueFixture.create();
      try {
        await Future.wait([
          f.drain(_identifiedReply('action-a')),
          f.drain(_identifiedReply('action-b')),
        ]);
        final raw = f.durableDraft(_identifiedReply('action-a').payload);
        expect(raw['text'], 'synthetic reply\nsynthetic reply');
        expect((raw['rescuedActions'] as Map).keys.toSet(), {
          'action-a',
          'action-b',
        });
        await f.drain(_identifiedReply('action-a'));
        expect(
          f.durableDraft(_identifiedReply('action-a').payload)['text'],
          raw['text'],
        );
      } finally {
        await f.dispose();
      }
    },
  );

  test(
    'same UID is scoped to connection profile and session destination',
    () async {
      final f = await _DiskRescueFixture.create();
      final prefs = await SharedPreferences.getInstance();
      const first = NotificationActionPayload(
        route: NotificationActionRoute.room,
        connId: 'connection-a',
        roomId: 'room-a',
        authorityId: 'authority-a',
      );
      const second = NotificationActionPayload(
        route: NotificationActionRoute.room,
        connId: 'connection-b',
        roomId: 'room-a',
        authorityId: 'authority-a',
      );
      const third = NotificationActionPayload(
        route: NotificationActionRoute.room,
        connId: 'connection-a',
        roomId: 'room-b',
        authorityId: 'authority-a',
      );
      try {
        for (final p in [first, second, third]) {
          await f.drain(_identifiedReply('same-uid', payload: p));
          expect(f.durableDraft(p)['text'], 'synthetic reply');
        }
        await prefs.setString('active_profile_connection-a', 'other-profile');
        await f.drain(_identifiedReply('same-uid', payload: first));
        expect(
          f.durableDraft(first, profile: 'other-profile')['text'],
          'synthetic reply',
        );
        await prefs.remove('active_profile_connection-a');
        await f.drain(_identifiedReply('same-uid', payload: first));
        expect(f.durableDraft(first)['text'], 'synthetic reply');
        expect(f.values.length, 4);
      } finally {
        await f.dispose();
      }
    },
  );

  test(
    'legacy v3 metadata survives receipt addition and ordinary autosave',
    () async {
      final f = await _DiskRescueFixture.create();
      final p = _identifiedReply('action-a').payload;
      final address = replyDraftAddress(p, activeProfile: '')!;
      final store = ChatDraftStore(f.prefs);
      try {
        expect(
          await store.save(
            p.connId,
            address.sessionId,
            'legacy text ',
            const [],
            profile: address.profile,
            preparedTurnClientTurnId: 'prepared-id',
            preparedTurnText: 'legacy',
            submittedTurnClientTurnId: 'submitted-id',
            replyThreadId: 'thread-id',
          ),
          isTrue,
        );
        expect(f.durableDraft(p).containsKey('rescuedActions'), isFalse);
        await f.drain(_identifiedReply('action-a'));
        final raw = f.durableDraft(p);
        expect(raw['text'], 'legacy text \nsynthetic reply');
        expect(raw['preparedTurnClientTurnId'], 'prepared-id');
        expect(raw['preparedTurnText'], 'legacy');
        expect(raw['submittedTurnClientTurnId'], 'submitted-id');
        expect(raw['replyThreadId'], 'thread-id');
        await store.save(
          p.connId,
          address.sessionId,
          'edited draft',
          const [],
          profile: address.profile,
        );
        final before = f.durableDraft(p);
        await f.drain(_identifiedReply('action-a'));
        expect(
          f.durableDraft(p),
          before,
          reason: 'receipt survives an ordinary autosave, no duplicate append',
        );
        expect(
          f.prefs.getKeys().any(
            (key) => f.prefs.get(key).toString().contains('synthetic reply'),
          ),
          isFalse,
        );
      } finally {
        await f.dispose();
      }
    },
  );

  test('failed persistence keeps custody without rescued or ACK', () async {
    final prefs = await SharedPreferences.getInstance();
    final inbox = _ClaimedInbox()..reply = _identifiedReply('action-a');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            if (call.method == 'write') {
              throw PlatformException(code: 'synthetic_write_failure');
            }
            if (call.method == 'readAll') return <String, String>{};
            return null;
          },
        );
    await NotificationActionDrainer(
      inbox: inbox,
      router: NotificationActionRouter(
        ops: _Ops(),
        sink: _Sink(),
        t: const NotifL10n(false),
      ),
      routes: allNotificationActionRoutes,
      rescue: DraftReplyRescue(prefs),
    ).drain();
    expect(inbox.phases, ['rescue_pending']);
    expect(inbox.acked, isFalse);
  });

  test('durable restart after draft commit before rescued checkpoint', () async {
    final directory = Platform.environment['RESCUE_RESTART_DIR'];
    final stage = Platform.environment['RESCUE_RESTART_STAGE'];
    final f = await _DiskRescueFixture.create(path: directory);
    final action = _identifiedReply('action-b');
    try {
      if (stage != 'resume') {
        await f.drain(_identifiedReply('action-a'));
        final inbox = _ClaimedInbox()..reply = action;
        inbox.beforeCheckpoint = (next) async {
          if (next != 'rescued') return;
          // Synthetic disk adapter has already flushed the SAME encrypted
          // plugin value boundary containing both text and receipt.
          final raw = f.durableDraft(action.payload);
          expect(raw['text'], 'synthetic reply\nsynthetic reply');
          expect((raw['rescuedActions'] as Map)['action-b'], 'synthetic reply');
          await File('${f.directory.path}/custody.json').writeAsString(
            jsonEncode({
              'uid': action.uid,
              'phase': inbox.phase,
              'acked': inbox.acked,
            }),
            flush: true,
          );
          debugPrint(
            'CRASHPOINT draft+receipt durable; phase=${inbox.phase}; ack=${inbox.acked}',
          );
          if (stage == 'crash') exit(73);
          throw StateError('simulated process death before checkpoint');
        };
        await f.drain(action, inbox: inbox);
        expect(inbox.acked, isFalse);
      }
      // Read exclusively from files. New store/router/rescue and new claim.
      expect(
        File('${f.directory.path}/custody.json').existsSync(),
        isTrue,
        reason:
            'checkpoint crashpoint must see text + action receipt committed together',
      );
      final custody =
          jsonDecode(
                await File('${f.directory.path}/custody.json').readAsString(),
              )
              as Map;
      expect(custody, {
        'uid': 'action-b',
        'phase': 'rescue_pending',
        'acked': false,
      });
      final successor = _ClaimedInbox()
        ..reply = action
        ..phase = custody['phase'] as String;
      final before = await File(
        '${f.directory.path}/secure-values.json',
      ).readAsString();
      await f.drain(action, inbox: successor);
      expect(successor.acked, isTrue);
      expect(successor.phases, ['rescued']);
      expect(
        await File('${f.directory.path}/secure-values.json').readAsString(),
        before,
        reason: 'read proof without duplicate durable write',
      );
      await f.drain(_identifiedReply('action-c'));
      expect(
        f.durableDraft(action.payload)['text'],
        'synthetic reply\nsynthetic reply\nsynthetic reply',
      );
      debugPrint(
        'RESTART_GREEN action-b incorporated once; action-c equal text retained; ACK=true; RPC=0',
      );
    } finally {
      if (directory == null) await f.dispose();
    }
  });

  for (final boundary in [
    'rpc',
    'rescue_checkpoint',
    'load_read',
    'save_read',
    'save_write',
  ]) {
    for (final revoke in [false, true]) {
      test(
        'rescue $boundary ${revoke ? "revoked ABA retains custody" : "current control commits once"}',
        () async {
          SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
          const channel = MethodChannel(
            'plugins.it_nomads.com/flutter_secure_storage',
          );
          final messenger =
              TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
          final values = <String, String>{};
          final entered = Completer<void>();
          final release = Completer<void>();
          var armed = false;
          var reads = 0;
          var writes = 0;
          Future<void> pause() async {
            if (!entered.isCompleted) {
              entered.complete();
              await release.future;
            }
          }

          messenger.setMockMethodCallHandler(channel, (call) async {
            final args = (call.arguments as Map?) ?? const {};
            final key = args['key'] as String? ?? '';
            switch (call.method) {
              case 'read':
                if (armed && key.startsWith('chat_draft')) {
                  reads++;
                  if ((boundary == 'load_read' && reads == 1) ||
                      (boundary == 'save_read' && reads == 2)) {
                    await pause();
                  }
                }
                return values[key];
              case 'write':
                if (armed && key.startsWith('chat_draft')) {
                  writes++;
                  if (boundary == 'save_write') await pause();
                }
                values[key] = args['value'] as String;
                return null;
              case 'delete':
                values.remove(key);
                return null;
              case 'readAll':
                if (armed) reads++;
                return Map<String, String>.from(values);
              case 'containsKey':
                return values.containsKey(key);
            }
            return null;
          });
          final prefs = await SharedPreferences.getInstance();
          final lock = AppLockService(prefs)..unlock();
          final store = ChatDraftStore(
            prefs,
            mutationNamespaceForTesting: '$boundary-$revoke',
          );
          final p = _reply().payload;
          final address = replyDraftAddress(p, activeProfile: '')!;
          try {
            expect(
              await store.save(
                p.connId,
                address.sessionId,
                'existing synthetic draft',
                const [],
                profile: address.profile,
              ),
              isTrue,
            );
            armed = true;
            final inbox = _ClaimedInbox();
            if (boundary == 'rescue_checkpoint') {
              inbox.beforeCheckpoint = (next) async {
                if (next == 'rescue_pending') await pause();
              };
            }
            final ops = _Ops()..fail = true;
            if (boundary == 'rpc') ops.beforeSendResult = pause;
            NotificationActionDrainer engine() => NotificationActionDrainer(
              inbox: inbox,
              router: NotificationActionRouter(
                ops: ops,
                sink: _Sink(),
                t: const NotifL10n(false),
                dedupe: PrefsActionDedupeStore(prefs),
              ),
              routes: allNotificationActionRoutes,
              rescue: DraftReplyRescue(prefs, store: store),
            );
            final draining = engine().drain();
            await entered.future;
            final readsBeforeRevoke = reads;
            final old = AppLockSensitiveReadFence.capture(prefs);
            if (revoke) {
              lock.lockNow();
              lock.unlock();
              expect(old.isCurrent, isFalse);
            }
            release.complete();
            await draining;
            if (revoke) {
              expect(
                reads,
                readsBeforeRevoke,
                reason:
                    'revoked execution must initiate zero further sensitive reads',
              );
              expect(inbox.phases, ['executing', 'rescue_pending']);
              expect(inbox.acked, isFalse);
              expect(
                inbox.claimed,
                isFalse,
                reason: 'rescue-only successor must be able to claim',
              );
              if (boundary != 'save_write') expect(writes, 0);
            } else {
              expect(inbox.phases, ['executing', 'rescue_pending', 'rescued']);
              expect(inbox.acked, isTrue);
              expect(writes, 1);
            }
            expect(ops.roomSendAttempts, 1);
            // Fresh execution may read/commit; it must never re-run the rejected RPC.
            await engine().drain();
            expect(inbox.acked, isTrue);
            expect(inbox.phases, ['executing', 'rescue_pending', 'rescued']);
            expect(ops.roomSendAttempts, 1);
            expect(
              writes,
              1,
              reason: 'an in-flight committed write is not appended twice',
            );
            armed = false;
            expect(
              (await store.load(
                p.connId,
                address.sessionId,
                profile: address.profile,
              )).text,
              'existing synthetic draft\nsynthetic reply',
            );
            final readsAfterRecovery = reads;
            armed = true;
            await engine().drain();
            expect(reads, readsAfterRecovery);
            expect(writes, 1);
          } finally {
            if (!release.isCompleted) release.complete();
            lock.releaseDisclosure();
            messenger.setMockMethodCallHandler(channel, null);
          }
        },
      );
    }
  }

  test(
    'late custom rescue cannot confirm with a revoked original ticket',
    () async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      final prefs = await SharedPreferences.getInstance();
      final lock = AppLockService(prefs)..unlock();
      final inbox = _ClaimedInbox();
      final entered = Completer<void>();
      final release = Completer<void>();
      SensitiveReadTicket? original;
      SensitiveReadTicket? after;
      final rescue = _Rescue()
        ..beforeResult = () async {
          original = AppLockSensitiveReadFence.current;
          entered.complete();
          await release.future;
          after = AppLockSensitiveReadFence.current;
        };
      final ops = _Ops()..fail = true;
      final engine = NotificationActionDrainer(
        inbox: inbox,
        router: NotificationActionRouter(
          ops: ops,
          sink: _Sink(),
          t: const NotifL10n(false),
        ),
        routes: allNotificationActionRoutes,
        rescue: rescue,
      );
      final draining = engine.drain();
      await entered.future;
      lock.lockNow();
      lock.unlock();
      release.complete();
      await draining;
      expect(identical(original, after), isTrue);
      expect(original!.isCurrent, isFalse);
      expect(inbox.phases, ['executing', 'rescue_pending']);
      expect(inbox.acked, isFalse);
      expect(inbox.claimed, isFalse);
      lock.releaseDisclosure();
    },
  );

  test(
    'rescued checkpoint in flight cannot let revoked execution ACK',
    () async {
      SharedPreferences.setMockInitialValues({'app_lock_enabled': true});
      final prefs = await SharedPreferences.getInstance();
      final lock = AppLockService(prefs)..unlock();
      final entered = Completer<void>();
      final release = Completer<void>();
      final inbox = _ClaimedInbox()
        ..beforeCheckpoint = (next) async {
          if (next == 'rescued') {
            entered.complete();
            await release.future;
          }
        };
      final ops = _Ops()..fail = true;
      final rescue = _Rescue();
      NotificationActionDrainer engine() => NotificationActionDrainer(
        inbox: inbox,
        router: NotificationActionRouter(
          ops: ops,
          sink: _Sink(),
          t: const NotifL10n(false),
        ),
        routes: allNotificationActionRoutes,
        rescue: rescue,
      );
      final draining = engine().drain();
      await entered.future;
      lock.lockNow();
      lock.unlock();
      release.complete();
      await draining;
      // A checkpoint already handed to native custody cannot be cancelled.
      expect(inbox.phase, 'rescued');
      expect(inbox.acked, isFalse);
      expect(inbox.claimed, isFalse);
      await engine().drain();
      expect(inbox.acked, isTrue);
      expect(ops.roomSendAttempts, 1);
      expect(rescue.attempts, 1);
      lock.releaseDisclosure();
    },
  );

  test(
    'real drainer checkpoints failure and successor retries rescue only',
    () async {
      final inbox = _ClaimedInbox();
      final ops = _Ops()..fail = true;
      final rescue = _Rescue()..deferred = true;
      NotificationActionDrainer engine() => NotificationActionDrainer(
        inbox: inbox,
        router: NotificationActionRouter(
          ops: ops,
          sink: _Sink(),
          t: const NotifL10n(false),
        ),
        routes: allNotificationActionRoutes,
        rescue: rescue,
      );
      await engine().drain();
      expect(inbox.phases, ['executing', 'rescue_pending']);
      expect(inbox.acked, isFalse);
      expect(ops.roomSendAttempts, 1);
      rescue.deferred = false;
      await engine().drain();
      expect(ops.roomSendAttempts, 1);
      expect(rescue.attempts, 2);
      expect(inbox.phases, ['executing', 'rescue_pending', 'rescued']);
      expect(inbox.acked, isTrue);
    },
  );

  test(
    'confirmed checkpoint survives executor replacement before ACK without another send',
    () async {
      final inbox = _ClaimedInbox()..failAck = true;
      final ops = _Ops();
      NotificationActionDrainer engine() => NotificationActionDrainer(
        inbox: inbox,
        router: NotificationActionRouter(
          ops: ops,
          sink: _Sink(),
          t: const NotifL10n(false),
        ),
        routes: allNotificationActionRoutes,
        rescue: _Rescue(),
      );
      await engine().drain();
      expect(inbox.phases, ['executing', 'confirmed']);
      expect(inbox.acked, isFalse);
      inbox.release();
      inbox.failAck = false;
      await engine().drain();
      expect(ops.roomSendAttempts, 1);
      expect(inbox.acked, isTrue);
    },
  );

  test(
    'ambiguous send retains uncertainty without rejection, rescue or ACK',
    () async {
      final inbox = _ClaimedInbox();
      final ops = _Ops()..ambiguous = true;
      final rescue = _Rescue();
      NotificationActionDrainer engine() => NotificationActionDrainer(
        inbox: inbox,
        router: NotificationActionRouter(
          ops: ops,
          sink: _Sink(),
          t: const NotifL10n(false),
        ),
        routes: allNotificationActionRoutes,
        rescue: rescue,
      );
      await engine().drain();
      inbox.release();
      await engine().drain();
      expect(inbox.phases, ['executing', 'uncertain']);
      expect(ops.roomSendAttempts, 1);
      expect(rescue.attempts, 0);
      expect(inbox.acked, isFalse);
    },
  );

  test('existing dedupe retains both concurrent action checkpoints', () async {
    final prefs = await SharedPreferences.getInstance();
    final first = PrefsActionDedupeStore(prefs);
    final second = PrefsActionDedupeStore(prefs);
    final now = DateTime.utc(2026, 1, 1);
    await Future.wait([
      first.mark('opaque-action-a', 'inflight', now),
      second.mark('opaque-action-b', 'inflight', now),
    ]);
    expect(
      [
        await first.stateOf('opaque-action-a', now, const Duration(minutes: 2)),
        await second.stateOf(
          'opaque-action-b',
          now,
          const Duration(minutes: 2),
        ),
      ],
      ['inflight', 'inflight'],
      reason: 'custody cannot use a checkpoint that another action can erase',
    );
  });

  test(
    'an expired reply is not acknowledged when rescue is deferred',
    () async {
      final inbox = _Inbox(_reply(expired: true));
      final rescue = _Rescue()..deferred = true;
      final ops = _Ops();
      await NotificationActionDrainer(
        inbox: inbox,
        router: NotificationActionRouter(
          ops: ops,
          sink: _Sink(),
          t: const NotifL10n(false),
        ),
        routes: allNotificationActionRoutes,
        rescue: rescue,
      ).drain();
      expect(ops.roomSendAttempts, 0);
      expect(rescue.attempts, 1);
      expect(
        inbox.acked,
        isEmpty,
        reason: 'native custody must survive an unreadable destination draft',
      );
    },
  );

  test('failed reply retires only after a valid rescue', () async {
    final inbox = _Inbox(_reply());
    final rescue = _Rescue();
    final ops = _Ops()..fail = true;
    await NotificationActionDrainer(
      inbox: inbox,
      router: NotificationActionRouter(
        ops: ops,
        sink: _Sink(),
        t: const NotifL10n(false),
      ),
      routes: allNotificationActionRoutes,
      rescue: rescue,
    ).drain();
    expect(ops.roomSendAttempts, 1);
    expect(rescue.attempts, 1);
    expect(inbox.acked, ['opaque-reply']);
  });

  test(
    'existing dedupe identifies a failed reply as rescue-only on reclaim',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final ops = _Ops()..fail = true;
      NotificationActionRouter router() => NotificationActionRouter(
        ops: ops,
        sink: _Sink(),
        t: const NotifL10n(false),
        dedupe: PrefsActionDedupeStore(prefs),
      );
      final action = _reply();
      expect(await router().handle(action), ActionOutcome.failed);
      final retained = await PrefsActionDedupeStore(prefs).stateOf(
        NotificationActionRouter.semanticKey(action),
        DateTime.now(),
        const Duration(minutes: 2),
      );
      final reclaimed = _reply(reclaimed: true);
      await router().handle(reclaimed);
      expect(
        ops.roomSendAttempts,
        1,
        reason: 'a replacement executor must retry rescue, not the remote RPC',
      );
      expect(
        retained,
        isNotNull,
        reason: 'the existing failure path forgets the only durable checkpoint',
      );
    },
  );
}

PendingNotificationAction _identifiedReply(
  String uid, {
  NotificationActionPayload? payload,
}) => PendingNotificationAction(
  uid: uid,
  action: 'reply',
  payload: payload ?? _reply().payload,
  notificationId: 1,
  text: 'synthetic reply',
  expired: true,
);

// Disk-backed METHOD-CHANNEL TEST ADAPTER: opaque synthetic data only.
// This is not a product plaintext store and does not emulate Android crypto.
final class _DiskRescueFixture {
  _DiskRescueFixture(this.directory, this.prefs);
  final Directory directory;
  final SharedPreferences prefs;
  Map<String, String> get values => Map<String, String>.from(
    jsonDecode(File('${directory.path}/secure-values.json').readAsStringSync())
        as Map,
  );
  static Future<_DiskRescueFixture> create({String? path}) async {
    final root = Directory(
      path ?? '${Directory.current.path}/build/rescue-probes',
    );
    await root.create(recursive: true);
    final directory = path == null ? await root.createTemp('synthetic-') : root;
    final f = _DiskRescueFixture(
      directory,
      await SharedPreferences.getInstance(),
    );
    final file = File('${directory.path}/secure-values.json');
    if (!await file.exists()) await file.writeAsString('{}', flush: true);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? const {};
            final key = args['key'] as String? ?? '';
            final values = f.values;
            switch (call.method) {
              case 'read':
                return values[key];
              case 'readAll':
                return values;
              case 'write':
                values[key] = args['value'] as String;
                final staged = File('${file.path}.staged');
                await staged.writeAsString(jsonEncode(values), flush: true);
                await staged.rename(file.path);
                return null;
              case 'delete':
                values.remove(key);
                await file.writeAsString(jsonEncode(values), flush: true);
                return null;
            }
            return null;
          },
        );
    return f;
  }

  Map durableDraft(NotificationActionPayload p, {String profile = 'default'}) {
    final address = replyDraftAddress(p, activeProfile: profile)!;
    return jsonDecode(
          values[ChatDraftStore.keyForTesting(
            p.connId,
            address.sessionId,
            profile: address.profile,
          )]!,
        )
        as Map;
  }

  Future<void> drain(
    PendingNotificationAction action, {
    _ClaimedInbox? inbox,
  }) async {
    final ops = _Ops();
    await NotificationActionDrainer(
      inbox: inbox ?? _Inbox(action),
      router: NotificationActionRouter(
        ops: ops,
        sink: _Sink(),
        t: const NotifL10n(false),
      ),
      routes: allNotificationActionRoutes,
      rescue: DraftReplyRescue(prefs, store: ChatDraftStore(prefs)),
    ).drain();
    expect(ops.roomSendAttempts, 0);
  }

  Future<void> dispose() => directory.delete(recursive: true);
}

PendingNotificationAction _reply({
  bool expired = false,
  bool reclaimed = false,
}) => PendingNotificationAction(
  uid: 'opaque-reply',
  action: 'reply',
  payload: const NotificationActionPayload(
    route: NotificationActionRoute.room,
    connId: 'opaque-connection',
    roomId: 'opaque-room',
    authorityId: 'opaque-authority',
  ),
  notificationId: 1,
  text: 'synthetic reply',
  expired: expired,
  reclaimed: reclaimed,
);

final class _Inbox implements NotificationActionInbox {
  _Inbox(this.next);
  PendingNotificationAction? next;
  final acked = <String>[];
  @override
  Future<List<PendingNotificationAction>> takePendingActions(
    Set<NotificationActionRoute> routes,
  ) async {
    final action = next;
    next = null;
    return action == null ? [] : [action];
  }

  @override
  Future<void> ackActions(Iterable<String> uids) async => acked.addAll(uids);
  @override
  void listen(void Function() onActions) {}
}

final class _ClaimedInbox
    implements NotificationActionInbox, ClaimedNotificationActionInbox {
  String phase = 'prepared';
  PendingNotificationAction? reply;
  bool claimed = false;
  bool acked = false;
  bool failAck = false;
  int generation = 0;
  final phases = <String>[];
  Future<void> Function(String)? beforeCheckpoint;
  void release() {
    claimed = false;
  }

  @override
  Future<List<PendingNotificationAction>> takePendingActions(
    Set<NotificationActionRoute> routes,
  ) async {
    if (claimed || acked) return [];
    claimed = true;
    generation++;
    final p = reply ?? _reply();
    return [
      PendingNotificationAction(
        uid: p.uid,
        action: p.action,
        payload: p.payload,
        notificationId: p.notificationId,
        text: p.text,
        expired: p.expired,
        phase: phase,
        claimToken: '$generation',
      ),
    ];
  }

  @override
  Future<bool> checkpoint(
    PendingNotificationAction action,
    String expected,
    String next,
  ) async {
    if (!claimed || action.claimToken != '$generation' || phase != expected) {
      return false;
    }
    await beforeCheckpoint?.call(next);
    phase = next;
    phases.add(next);
    return true;
  }

  @override
  Future<bool> deferClaim(PendingNotificationAction action) async {
    if (action.claimToken != '$generation') return false;
    release();
    return true;
  }

  @override
  Future<bool> ackClaim(PendingNotificationAction action) async {
    if (failAck) throw StateError('executor retired before ACK');
    if (action.claimToken != '$generation' ||
        !['confirmed', 'rescued'].contains(phase)) {
      return false;
    }
    acked = true;
    return true;
  }

  @override
  Future<void> ackActions(Iterable<String> uids) async {
    throw StateError('uid-only ACK forbidden');
  }

  @override
  void listen(void Function() callback) {}
}

final class _Rescue implements ReplyRescue {
  bool deferred = false;
  int attempts = 0;
  Future<void> Function()? beforeResult;
  @override
  Future<void> keep(NotificationActionPayload payload, String text) async {
    attempts++;
    await beforeResult?.call();
    if (deferred) throw StateError('destination unavailable');
  }
}

final class _Ops implements NotificationActionOps {
  bool fail = false;
  bool ambiguous = false;
  int roomSendAttempts = 0;
  Future<void> Function()? beforeSendResult;
  @override
  Future<void> roomSend(
    NotificationActionPayload p,
    String text,
    String id,
  ) async {
    roomSendAttempts++;
    await beforeSendResult?.call();
    if (ambiguous) {
      throw AmbiguousDeliveryError(StateError('synthetic uncertainty'));
    }
    if (fail) throw StateError('pre-acceptance rejection');
  }

  @override
  Future<void> roomApprove(NotificationActionPayload p, String choice) async {}
  @override
  Future<void> roomStop(NotificationActionPayload p) async {}
  @override
  Future<void> runApprove(NotificationActionPayload p, String choice) async {}
  @override
  Future<void> chatApprove(NotificationActionPayload p, String choice) async {}
  @override
  Future<void> botChatReply(
    NotificationActionPayload p,
    String text,
    String id,
  ) async {}
  @override
  Future<void> cronTrigger(NotificationActionPayload p) async {}
}

final class _Sink implements RichNotificationSink {
  @override
  Future<void> cancel({required int id, String? tag}) async {}
  @override
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs = 4000,
    bool onlyIfActive = false,
  }) async {}
  @override
  Future<bool> postConversation(Map<String, Object?> args) async => true;
  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async {}
}
