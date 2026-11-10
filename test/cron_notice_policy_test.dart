import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/cron_notice_policy.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_mute_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('read-only migration preserves explicit opt-outs and mutes', () async {
    for (final (saved, expected) in <(Map<String, Object>, CronNoticeMode)>[
      ({}, CronNoticeMode.automatic),
      ({'notif_cron_results': true}, CronNoticeMode.automatic),
      ({'notif_cron_results': false}, CronNoticeMode.off),
      ({'notif_background_listen': true}, CronNoticeMode.automatic),
      ({'notif_background_listen': false}, CronNoticeMode.off),
      (
        {'notif_background_listen': true, 'notif_cron_results': false},
        CronNoticeMode.off,
      ),
      (
        {'notif_cron_results': false, CronNoticePolicy.preferenceKey: 'all'},
        CronNoticeMode.all,
      ),
    ]) {
      final values = <String, Object>{
        ...saved,
        'notif_muted_cron_job_ids': ['legacy'],
        'notif_cron_job_policy_v2': ['a/work/job=failuresOnly'],
      };
      SharedPreferences.setMockInitialValues(values);
      final prefs = await SharedPreferences.getInstance();
      expect(CronNoticePolicy.read(prefs), expected);
      expect(prefs.getKeys(), values.keys.toSet());
      final mutes = NotificationMuteStore(prefs);
      expect(
        mutes.cronPolicy(connId: 'a', profile: 'work', jobId: 'job'),
        CronNotifyPolicy.failuresOnly,
      );
      expect(
        mutes.cronPolicy(connId: 'a', profile: 'work', jobId: 'legacy'),
        CronNotifyPolicy.off,
      );
    }
  });

  test('per-job all inherits global mode and stricter mutes remain', () {
    for (final mode in CronNoticeMode.values) {
      for (final ok in [true, false]) {
        expect(
          CronNoticePolicy.allows(mode, CronNotifyPolicy.all, ok: ok),
          mode != CronNoticeMode.off &&
              !(mode == CronNoticeMode.failuresOnly && ok),
        );
        expect(
          CronNoticePolicy.allows(mode, CronNotifyPolicy.off, ok: ok),
          isFalse,
        );
        expect(
          CronNoticePolicy.allows(mode, CronNotifyPolicy.failuresOnly, ok: ok),
          mode != CronNoticeMode.off && !ok,
        );
      }
    }
  });

  group('durable atomic reservations', () {
    late Directory directory;
    late String path;
    late int now;
    final stores = <NotificationDeliveryStore>[];

    Future<NotificationDeliveryStore> engine() async {
      final store = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: path,
        clock: () => now,
      );
      stores.add(store);
      await store.open();
      return store;
    }

    Future<bool> reserve(
      NotificationDeliveryStore store,
      String message, {
      bool ok = true,
      String conn = 'a',
      String profile = 'work',
      String job = 'daily',
      CronNoticeMode mode = CronNoticeMode.automatic,
      bool allowed = true,
    }) => store.reserveCronNotice(
      connId: conn,
      profile: profile,
      jobId: job,
      messageId: message,
      ok: ok,
      mode: mode,
      allowed: allowed,
    );

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('cron-quiet-');
      path = '${directory.path}/delivery.db';
      now = 1800000000000;
    });
    tearDown(() async {
      for (final store in stores) {
        await store.close();
      }
      stores.clear();
      await directory.delete(recursive: true);
    });

    test('12 successes per hour show once; exact 60 minute boundary', () async {
      final store = await engine();
      final start = now;
      var shown = 0;
      for (var n = 0; n < 12; n++) {
        now = start + n * 5 * 60 * 1000;
        if (await reserve(store, 'ok-$n')) shown++;
      }
      expect(shown, 1);
      now = start + CronNoticePolicy.successWindowMs - 1;
      expect(await reserve(store, 'before'), isFalse);
      now++;
      expect(await reserve(store, 'boundary'), isTrue);
      expect(await reserve(store, 'boundary'), isFalse);
    });

    test(
      'two different failures show twice; retransmission alone deduplicates',
      () async {
        final store = await engine();
        expect(await reserve(store, 'success'), isTrue);
        expect(await reserve(store, 'failure-1', ok: false), isTrue);
        expect(await reserve(store, 'failure-2', ok: false), isTrue);
        expect(await reserve(store, 'failure-1', ok: false), isFalse);
        expect(await reserve(store, 'success-2'), isFalse);
        expect(await reserve(store, 'failure-3', ok: false), isTrue);
        expect(
          await reserve(store, 'fresh-failure', ok: false, job: 'other'),
          isTrue,
        );
        expect(await reserve(store, 'fresh-success', job: 'other'), isTrue);
      },
    );

    test(
      'reopening preserves both window and suppressed-message tombstones',
      () async {
        final first = await engine();
        expect(await reserve(first, 'one'), isTrue);
        expect(await reserve(first, 'suppressed'), isFalse);
        await first.close();
        final restarted = await engine();
        expect(await reserve(restarted, 'two'), isFalse);
        expect(await reserve(restarted, 'one'), isFalse);
        now += CronNoticePolicy.successWindowMs;
        expect(await reserve(restarted, 'suppressed'), isFalse);
        expect(await reserve(restarted, 'three'), isTrue);
      },
    );

    test(
      'two engines share one success slot and one message reservation',
      () async {
        final foreground = await engine();
        final headless = await engine();
        final results = await Future.wait([
          for (var n = 0; n < 12; n++)
            reserve(n.isEven ? foreground : headless, 'success-$n'),
        ]);
        expect(results.where((shown) => shown), hasLength(1));
        final failures = await Future.wait([
          reserve(foreground, 'same-failure', ok: false),
          reserve(headless, 'same-failure', ok: false),
        ]);
        expect(failures.where((shown) => shown), hasLength(1));
      },
    );

    test(
      'same profiles/jobs in different connections have separate windows',
      () async {
        final store = await engine();
        expect(await reserve(store, 'one'), isTrue);
        expect(await reserve(store, 'one', conn: 'b'), isTrue);
        expect(await reserve(store, 'other-message', profile: 'other'), isTrue);
        expect(await reserve(store, 'two', profile: ' WORK '), isFalse);
      },
    );

    test(
      'All bypasses budget, Off and failures-only do not spend successes',
      () async {
        final store = await engine();
        for (var n = 0; n < 12; n++) {
          expect(
            await reserve(store, 'all-$n', mode: CronNoticeMode.all),
            isTrue,
          );
        }
        expect(
          await reserve(store, 'off', allowed: false, mode: CronNoticeMode.off),
          isFalse,
        );
        expect(
          await reserve(
            store,
            'fail-only-success',
            allowed: false,
            mode: CronNoticeMode.failuresOnly,
          ),
          isFalse,
        );
        expect(
          await reserve(
            store,
            'fail-only-failure',
            ok: false,
            mode: CronNoticeMode.failuresOnly,
          ),
          isTrue,
        );
        expect(await reserve(store, 'automatic'), isTrue);
      },
    );

    test('v2 database upgrades without resetting other delivery data', () async {
      final old = await databaseFactoryFfi.openDatabase(path);
      await old.execute(
        'CREATE TABLE delivery_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await old.insert('delivery_meta', {
        'key': 'schema_version',
        'value': '2',
      });
      await old.insert('delivery_meta', {'key': 'sentinel', 'value': 'keep'});
      await old.setVersion(2);
      await old.close();
      final store = await engine();
      expect(await store.schemaVersion(), 3);
      expect(
        await store.tableNames(),
        containsAll(['cron_notice_window', 'cron_notice_event']),
      );
      expect(await reserve(store, 'first'), isTrue);
      await store.close();
      final db = await databaseFactoryFfi.openDatabase(path);
      expect(
        (await db.query(
          'delivery_meta',
          where: 'key = ?',
          whereArgs: ['sentinel'],
        )).single['value'],
        'keep',
      );
      await db.close();
    });
  });
}
