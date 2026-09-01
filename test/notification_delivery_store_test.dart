import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test(
    'Android-compatible database configuration uses query pragmas',
    () async {
      final configured = <String>[];

      await configureNotificationDeliveryPragmas((sql) async {
        configured.add(sql);
        if (sql == 'PRAGMA journal_mode = WAL') {
          return const <Map<String, Object?>>[
            {'journal_mode': 'wal'},
          ];
        }
        return const <Map<String, Object?>>[];
      });

      expect(configured, [
        'PRAGMA busy_timeout = 2000',
        'PRAGMA journal_mode = WAL',
        'PRAGMA foreign_keys = ON',
        'PRAGMA synchronous = FULL',
      ]);
    },
  );

  test(
    'database configuration fails closed when WAL is not effective',
    () async {
      await expectLater(
        configureNotificationDeliveryPragmas((sql) async {
          if (sql == 'PRAGMA journal_mode = WAL') {
            return const <Map<String, Object?>>[
              {'journal_mode': 'delete'},
            ];
          }
          return const <Map<String, Object?>>[];
        }),
        throwsA(isA<StateError>()),
      );
    },
  );

  group('canonical event identity', () {
    test('separates connections and normalized profiles', () {
      const base = NotificationEventIdentity(
        connId: 'conn-a',
        profile: '  WORK ',
        sourceKind: 'run',
        objectId: 'run-42',
        eventKind: 'approval',
        sourceVersion: 'request-7',
      );
      const otherConnection = NotificationEventIdentity(
        connId: 'conn-b',
        profile: 'work',
        sourceKind: 'run',
        objectId: 'run-42',
        eventKind: 'approval',
        sourceVersion: 'request-7',
      );
      const otherProfile = NotificationEventIdentity(
        connId: 'conn-a',
        profile: 'personal',
        sourceKind: 'run',
        objectId: 'run-42',
        eventKind: 'approval',
        sourceVersion: 'request-7',
      );
      const normalizedEquivalent = NotificationEventIdentity(
        connId: 'conn-a',
        profile: 'work',
        sourceKind: 'run',
        objectId: 'run-42',
        eventKind: 'approval',
        sourceVersion: 'request-7',
      );

      expect(base.canonical, normalizedEquivalent.canonical);
      expect(base.eventKey, normalizedEquivalent.eventKey);
      expect(base.eventKey, isNot(otherConnection.eventKey));
      expect(base.eventKey, isNot(otherProfile.eventKey));
      expect(base.canonical, startsWith('6:conn-a|4:work|'));
    });
  });

  group('atomic leasing', () {
    test(
      'independent database handles yield exactly one lease owner',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-race-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}/notification_delivery_v1.db';
        final now = DateTime.utc(2026, 8, 28, 12).millisecondsSinceEpoch;
        final first = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: path,
          clock: () => now,
          tokenFactory: () => 'owner-a',
        );
        final second = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: path,
          clock: () => now,
          tokenFactory: () => 'owner-b',
        );
        await first.open();
        await second.open();
        addTearDown(first.close);
        addTearDown(second.close);

        const identity = NotificationEventIdentity(
          connId: 'conn-a',
          profile: 'work',
          sourceKind: 'run',
          objectId: 'run-1',
          eventKind: 'terminal',
          sourceVersion: 'v1',
        );
        await first.ingestSourceBatch(<SourceCursorUpdate>[
          const SourceCursorUpdate(
            scopeKey: 'conn-a/work/run/run-1',
            connId: 'conn-a',
            profile: 'work',
            sourceKind: 'run',
            objectId: 'run-1',
            lastState: 'completed',
            lastVersion: 'v1',
            generation: 1,
            initialized: true,
            events: <DeliveryEventSpec>[
              DeliveryEventSpec(
                identity: identity,
                destinationKind: 'run_terminal',
                runId: 'run-1',
              ),
            ],
          ),
        ]);

        final leases = await Future.wait(<Future<DeliveryLease?>>[
          first.leaseNext(),
          second.leaseNext(),
        ]);

        expect(leases.whereType<DeliveryLease>(), hasLength(1));
        expect(
          leases.whereType<DeliveryLease>().single.token,
          anyOf('owner-a', 'owner-b'),
        );
        expect(await first.countByStatus(DeliveryStatus.leased), 1);
        expect((await first.eventByKey(identity.eventKey))!.attemptCount, 1);
      },
    );
  });

  group('SQLITE_BUSY lease recovery', () {
    test(
      'retries a lease after another handle releases BEGIN EXCLUSIVE',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-busy-lease-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}/notification_delivery_v1.db';
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: path,
          tokenFactory: () => 'busy-retry-owner',
        );
        await store.open();
        addTearDown(store.close);

        const identity = NotificationEventIdentity(
          connId: 'conn-busy',
          profile: 'work',
          sourceKind: 'run',
          objectId: 'run-busy',
          eventKind: 'terminal',
          sourceVersion: 'v1',
        );
        await store.ingestSourceBatch(<SourceCursorUpdate>[
          _updateFor(identity),
        ]);

        final lockHolder = await databaseFactoryFfi.openDatabase(
          path,
          options: sqflite.OpenDatabaseOptions(singleInstance: false),
        );
        addTearDown(lockHolder.close);
        await lockHolder.execute('PRAGMA busy_timeout = 0');
        await lockHolder.execute('BEGIN EXCLUSIVE');

        final leased = store.leaseNext();
        await Future<void>.delayed(
          const Duration(
            milliseconds:
                NotificationDeliveryStore.busyTimeoutMilliseconds + 100,
          ),
        );
        await lockHolder.execute('COMMIT');

        final lease = await leased;
        expect(lease, isNotNull);
        expect(lease!.token, 'busy-retry-owner');
        expect(await store.countByStatus(DeliveryStatus.leased), 1);
        expect((await store.eventByKey(identity.eventKey))!.attemptCount, 1);
      },
    );
  });

  group('lease recovery and fencing', () {
    test(
      'expired lease is reclaimed and stale token cannot complete',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-fence-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final clock = _MutableClock(
          DateTime.utc(2026, 8, 28).millisecondsSinceEpoch,
        );
        final tokens = <String>[
          'old-owner',
          'new-owner',
          'retry-owner',
        ].iterator;
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
          clock: clock.call,
          tokenFactory: () {
            tokens.moveNext();
            return tokens.current;
          },
        );
        await store.open();
        addTearDown(store.close);
        const identity = NotificationEventIdentity(
          connId: 'conn-a',
          profile: 'work',
          sourceKind: 'run',
          objectId: 'run-fence',
          eventKind: 'terminal',
          sourceVersion: 'v1',
        );
        await store.ingestSourceBatch(<SourceCursorUpdate>[
          _updateFor(identity),
        ]);

        final oldLease = (await store.leaseNext())!;
        expect(
          await store.renewLease(identity.eventKey, oldLease.token),
          isTrue,
        );
        expect(
          await store.markPresented(identity.eventKey, 'wrong-token', 'alert'),
          isFalse,
        );

        clock.advance(const Duration(seconds: 31));
        final newLease = (await store.leaseNext())!;
        expect(newLease.token, 'new-owner');
        expect(
          await store.renewLease(identity.eventKey, oldLease.token),
          isFalse,
        );
        expect(
          await store.markPresented(identity.eventKey, oldLease.token, 'alert'),
          isFalse,
        );
        expect(
          await store.retry(
            identity.eventKey,
            newLease.token,
            delay: const Duration(seconds: 10),
            errorCode: 'platform_show',
          ),
          isTrue,
        );
        expect(await store.leaseNext(), isNull);
        clock.advance(const Duration(seconds: 10));
        final retryLease = (await store.leaseNext())!;
        expect(retryLease.token, 'retry-owner');
        expect(
          await store.markPresented(
            identity.eventKey,
            retryLease.token,
            'alert',
          ),
          isTrue,
        );
        expect(
          (await store.eventByKey(identity.eventKey))!.status,
          DeliveryStatus.presented,
        );
      },
    );

    test('lease implausibly far in the future is reclaimed', () async {
      final directory = await Directory.systemTemp.createTemp(
        'delivery-clock-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final clock = _MutableClock(
        DateTime.utc(2026, 8, 28).millisecondsSinceEpoch,
      );
      var token = 0;
      final store = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${directory.path}/notification_delivery_v1.db',
        clock: clock.call,
        tokenFactory: () => 'owner-${++token}',
      );
      await store.open();
      addTearDown(store.close);
      const identity = NotificationEventIdentity(
        connId: 'conn-a',
        profile: 'work',
        sourceKind: 'run',
        objectId: 'run-clock',
        eventKind: 'terminal',
        sourceVersion: 'v1',
      );
      await store.ingestSourceBatch(<SourceCursorUpdate>[_updateFor(identity)]);
      expect((await store.leaseNext())!.token, 'owner-1');

      clock.advance(const Duration(minutes: -5));

      expect((await store.leaseNext())!.token, 'owner-2');
    });

    test('constructor rejects invalid durations', () {
      expect(
        () => NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          leaseDuration: Duration.zero,
        ),
        throwsArgumentError,
      );
      expect(
        () => NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          leaseDuration: const Duration(seconds: 30),
          maximumFutureLease: const Duration(seconds: 10),
        ),
        throwsArgumentError,
      );
      expect(
        () => NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          leaseDuration: const Duration(seconds: 30),
          maximumFutureLease: const Duration(seconds: 30),
        ),
        throwsArgumentError,
      );
      expect(
        () => NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          pendingCapacity: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          mappingRetention: Duration.zero,
        ),
        throwsArgumentError,
      );
    });

    test('renewLease caps at maximumFutureLease', () async {
      final directory = await Directory.systemTemp.createTemp(
        'delivery-renew-cap-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final clock = _MutableClock(
        DateTime.utc(2026, 8, 28).millisecondsSinceEpoch,
      );
      final store = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${directory.path}/notification_delivery_v1.db',
        clock: clock.call,
        tokenFactory: () => 'owner',
      );
      await store.open();
      addTearDown(store.close);
      const identity = NotificationEventIdentity(
        connId: 'conn-a',
        profile: 'work',
        sourceKind: 'run',
        objectId: 'run-renew-cap',
        eventKind: 'terminal',
        sourceVersion: 'v1',
      );
      await store.ingestSourceBatch(<SourceCursorUpdate>[_updateFor(identity)]);
      final lease = (await store.leaseNext())!;
      expect(
        await store.renewLease(
          identity.eventKey,
          lease.token,
          duration: const Duration(minutes: 5),
        ),
        isTrue,
      );
      final record = await store.eventByKey(identity.eventKey);
      expect(
        record!.leaseUntil,
        clock.value + const Duration(minutes: 2).inMilliseconds,
      );
    });

    test('markPresented and retry reject implausibly future leases', () async {
      final directory = await Directory.systemTemp.createTemp(
        'delivery-future-lease-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final clock = _MutableClock(
        DateTime.utc(2026, 8, 28).millisecondsSinceEpoch,
      );
      final store = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${directory.path}/notification_delivery_v1.db',
        clock: clock.call,
        tokenFactory: () => 'owner',
      );
      await store.open();
      addTearDown(store.close);
      const identity = NotificationEventIdentity(
        connId: 'conn-a',
        profile: 'work',
        sourceKind: 'run',
        objectId: 'run-future-lease',
        eventKind: 'terminal',
        sourceVersion: 'v1',
      );
      await store.ingestSourceBatch(<SourceCursorUpdate>[_updateFor(identity)]);
      final lease = (await store.leaseNext())!;
      clock.advance(const Duration(minutes: -5));
      expect(
        await store.markPresented(identity.eventKey, lease.token, 'alert'),
        isFalse,
      );
      expect(
        await store.retry(
          identity.eventKey,
          lease.token,
          delay: const Duration(seconds: 5),
        ),
        isFalse,
      );
    });

    test('exact expiry is reclaimed, not presented', () async {
      final directory = await Directory.systemTemp.createTemp(
        'delivery-exact-expiry-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final clock = _MutableClock(
        DateTime.utc(2026, 8, 28).millisecondsSinceEpoch,
      );
      final store = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${directory.path}/notification_delivery_v1.db',
        clock: clock.call,
        tokenFactory: () => 'owner',
        leaseDuration: const Duration(seconds: 30),
      );
      await store.open();
      addTearDown(store.close);
      const identity = NotificationEventIdentity(
        connId: 'conn-a',
        profile: 'work',
        sourceKind: 'run',
        objectId: 'run-exact-expiry',
        eventKind: 'terminal',
        sourceVersion: 'v1',
      );
      await store.ingestSourceBatch(<SourceCursorUpdate>[_updateFor(identity)]);
      final lease = (await store.leaseNext())!;
      clock.advance(const Duration(seconds: 30));
      expect(
        await store.markPresented(identity.eventKey, lease.token, 'alert'),
        isFalse,
      );
      expect(await store.reclaimExpiredLeases(), 1);
      expect(await store.countByStatus(DeliveryStatus.leased), 0);
      expect(await store.countByStatus(DeliveryStatus.pending), 1);
    });
  });

  group('lossless source ingestion', () {
    test(
      'stale cursor generations are rejected before event insertion',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-generation-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
        );
        await store.open();
        addTearDown(store.close);

        const newer = NotificationEventIdentity(
          connId: 'conn-generation',
          profile: 'work',
          sourceKind: 'run',
          objectId: 'event-newer',
          eventKind: 'terminal',
          sourceVersion: 'v2',
        );
        const older = NotificationEventIdentity(
          connId: 'conn-generation',
          profile: 'work',
          sourceKind: 'run',
          objectId: 'event-older',
          eventKind: 'terminal',
          sourceVersion: 'v1',
        );
        SourceCursorUpdate update(
          int generation,
          NotificationEventIdentity identity,
        ) {
          return SourceCursorUpdate(
            scopeKey: 'conn-generation/work/run/snapshot',
            connId: 'conn-generation',
            profile: 'work',
            sourceKind: 'run',
            objectId: 'snapshot',
            lastState: 'completed',
            lastVersion: 'v$generation',
            generation: generation,
            initialized: true,
            events: <DeliveryEventSpec>[
              DeliveryEventSpec(
                identity: identity,
                destinationKind: 'run_terminal',
                runId: identity.objectId,
              ),
            ],
          );
        }

        await store.ingestSourceBatch(<SourceCursorUpdate>[update(2, newer)]);
        await store.ingestSourceBatch(<SourceCursorUpdate>[update(1, older)]);

        expect(await store.eventCount(), 1);
        expect(
          await store.sourceCursorGeneration(
            'conn-generation/work/run/snapshot',
          ),
          2,
        );
      },
    );

    test(
      'reused scopeKey with a different cursor identity is rejected',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-identity-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
        );
        await store.open();
        addTearDown(store.close);

        SourceCursorUpdate update({
          required String connId,
          required String objectId,
          required int generation,
          String? scopeKey,
        }) {
          final identity = NotificationEventIdentity(
            connId: connId,
            profile: 'work',
            sourceKind: 'run',
            objectId: objectId,
            eventKind: 'terminal',
            sourceVersion: 'v$generation',
          );
          return SourceCursorUpdate(
            scopeKey: scopeKey ?? '$connId/work/run/$objectId',
            connId: connId,
            profile: 'work',
            sourceKind: 'run',
            objectId: objectId,
            lastState: 'completed',
            lastVersion: 'v$generation',
            generation: generation,
            initialized: true,
            events: <DeliveryEventSpec>[
              DeliveryEventSpec(
                identity: identity,
                destinationKind: 'run_terminal',
                runId: objectId,
              ),
            ],
          );
        }

        await store.ingestSourceBatch(<SourceCursorUpdate>[
          update(connId: 'conn-a', objectId: 'run-1', generation: 2),
        ]);
        await expectLater(
          store.ingestSourceBatch(<SourceCursorUpdate>[
            update(
              connId: 'conn-b',
              objectId: 'run-9',
              generation: 1,
              scopeKey: 'conn-a/work/run/run-1',
            ),
          ]),
          throwsArgumentError,
        );
        expect(await store.eventCount(), 1);
        expect(await store.sourceCursorGeneration('conn-a/work/run/run-1'), 2);
      },
    );

    test(
      'six and fifty events enqueue fully while dispatch stays bounded',
      () async {
        for (final eventCount in <int>[6, 50]) {
          final directory = await Directory.systemTemp.createTemp(
            'delivery-batch-',
          );
          addTearDown(() => directory.delete(recursive: true));
          var token = 0;
          final store = NotificationDeliveryStore(
            databaseFactory: databaseFactoryFfi,
            databasePath: '${directory.path}/notification_delivery_v1.db',
            clock: () => DateTime.utc(2026, 8, 28).millisecondsSinceEpoch,
            tokenFactory: () => 'batch-${++token}',
          );
          await store.open();
          addTearDown(store.close);

          await store.ingestSourceBatch(<SourceCursorUpdate>[
            _batchUpdate(eventCount),
          ]);

          expect(await store.countByStatus(DeliveryStatus.pending), eventCount);
          final dispatchBatch = await store.leaseBatch(5);
          expect(dispatchBatch, hasLength(5));
          expect(await store.countByStatus(DeliveryStatus.leased), 5);
          expect(
            await store.countByStatus(DeliveryStatus.pending),
            eventCount - 5,
          );
        }
      },
    );
  });

  group('atomic ingestion rollback', () {
    test(
      'capacity and injected mid-batch failures roll back events and cursor',
      () async {
        for (final injectFailure in <bool>[false, true]) {
          final directory = await Directory.systemTemp.createTemp(
            'delivery-rollback-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final store = NotificationDeliveryStore(
            databaseFactory: databaseFactoryFfi,
            databasePath: '${directory.path}/notification_delivery_v1.db',
            pendingCapacity: injectFailure ? 100 : 5,
            ingestFaultInjector: injectFailure
                ? (index, event) {
                    if (index == 5) {
                      throw StateError('injected sixth insert failure');
                    }
                  }
                : null,
          );
          await store.open();
          addTearDown(store.close);
          final update = _batchUpdate(6);

          await expectLater(
            store.ingestSourceBatch(<SourceCursorUpdate>[update]),
            throwsA(
              injectFailure
                  ? isA<StateError>()
                  : isA<DeliveryCapacityException>(),
            ),
          );

          expect(await store.eventCount(), 0);
          expect(await store.sourceCursorGeneration(update.scopeKey), isNull);
        }
      },
    );
  });

  group('stable Android identity allocation', () {
    test(
      'forced digest candidate collision probes and survives reopen',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-collision-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}/notification_delivery_v1.db';
        List<int> collidingDigest(List<int> input) {
          final second = utf8.decode(input).contains('execution-b');
          final bytes = List<int>.filled(32, second ? 0xbb : 0xaa);
          bytes.setRange(0, 4, <int>[0x12, 0x34, 0x56, 0x78]);
          return bytes;
        }

        final first = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: path,
          digest: collidingDigest,
        );
        await first.open();
        await first.ingestSourceBatch(<SourceCursorUpdate>[_collisionUpdate()]);
        final allocated = await first.allEvents();
        expect(allocated, hasLength(2));
        expect(allocated.map((event) => event.androidId).toSet(), hasLength(2));
        expect(
          allocated.every(
            (event) =>
                event.androidId >= 0x40000000 && event.androidId <= 0x7fffffff,
          ),
          isTrue,
        );
        expect(
          allocated.every(
            (event) => event.androidTag.startsWith('hermes.event.'),
          ),
          isTrue,
        );
        final idsBefore = <String, int>{
          for (final event in allocated) event.objectId: event.androidId,
        };
        await first.close();

        final reopened = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: path,
          digest: collidingDigest,
        );
        await reopened.open();
        addTearDown(reopened.close);
        final idsAfter = <String, int>{
          for (final event in await reopened.allEvents())
            event.objectId: event.androidId,
        };
        expect(idsAfter, idsBefore);
      },
    );
  });

  group('targeted approval cancellation', () {
    test(
      'cancellation waits for active lease to avoid presentation race',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-cancel-lease-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
        );
        await store.open();
        addTearDown(store.close);
        final update = _approvalUpdate();
        await store.ingestSourceBatch(<SourceCursorUpdate>[update.$1]);
        final lease = (await store.leaseNext())!;
        expect(lease.event.destinationKind, 'approval');

        expect(await store.markCancelPending(lease.event.eventKey), isTrue);
        final cancelPending = (await store.eventByKey(lease.event.eventKey))!;
        expect(cancelPending.status, DeliveryStatus.cancelPending);
        expect(cancelPending.androidId, lease.event.androidId);
        expect(cancelPending.androidTag, lease.event.androidTag);

        expect(cancelPending.leaseToken, lease.token);
        expect(cancelPending.leaseUntil, isNotNull);
        expect(
          await store.markPresented(lease.event.eventKey, lease.token, 'alert'),
          isFalse,
        );

        expect(await store.markCancelPending(lease.event.eventKey), isFalse);
        expect(await store.markCancelled(lease.event.eventKey), isFalse);
        expect(
          await store.markCancelledByLease(
            lease.event.eventKey,
            'different-owner',
          ),
          isFalse,
        );
        expect(
          await store.markCancelledByLease(lease.event.eventKey, lease.token),
          isTrue,
        );
        expect(
          (await store.eventByKey(lease.event.eventKey))!.status,
          DeliveryStatus.cancelled,
        );
      },
    );

    test('resolving approval A leaves approval B pending', () async {
      final directory = await Directory.systemTemp.createTemp(
        'delivery-approval-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${directory.path}/notification_delivery_v1.db',
      );
      await store.open();
      addTearDown(store.close);
      final update = _approvalUpdate();
      await store.ingestSourceBatch(<SourceCursorUpdate>[update.$1]);

      expect(await store.countByStatus(DeliveryStatus.pending), 2);
      expect(await store.markCancelPending(update.$2.eventKey), isTrue);
      expect(
        (await store.eventByKey(update.$2.eventKey))!.status,
        DeliveryStatus.cancelPending,
      );
      expect(
        (await store.eventByKey(update.$3.eventKey))!.status,
        DeliveryStatus.pending,
      );
      expect(await store.markCancelled(update.$2.eventKey), isTrue);
      expect(
        await store.markApprovalsCancelPendingForRun(
          connId: 'conn-a',
          profile: 'work',
          runId: 'run-b',
        ),
        1,
      );
      expect(
        (await store.eventByKey(update.$3.eventKey))!.status,
        DeliveryStatus.cancelPending,
      );
    });
  });

  group('privacy boundary', () {
    test(
      'JWT-shaped lastState is rejected before DB access while machine states are allowed',
      () async {
        const jwtUpdate = SourceCursorUpdate(
          scopeKey: 'conn-a/work/run/run-jwt',
          connId: 'conn-a',
          profile: 'work',
          sourceKind: 'run',
          objectId: 'run-jwt',
          lastState:
              'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature8',
          lastVersion: 'v1',
          generation: 1,
          initialized: true,
          events: <DeliveryEventSpec>[],
        );
        final unopened = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '/must-not-be-opened/notification_delivery_v1.db',
        );

        await expectLater(
          unopened.ingestSourceBatch(const <SourceCursorUpdate>[jwtUpdate]),
          throwsArgumentError,
        );

        final directory = await Directory.systemTemp.createTemp(
          'delivery-machine-state-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
        );
        await store.open();
        addTearDown(store.close);
        for (final state in const <String>[
          'pending',
          'running',
          'completed',
          'failed',
        ]) {
          await store.ingestSourceBatch(<SourceCursorUpdate>[
            SourceCursorUpdate(
              scopeKey: 'conn-a/work/run/$state',
              connId: 'conn-a',
              profile: 'work',
              sourceKind: 'run',
              objectId: state,
              lastState: state,
              lastVersion: 'v1',
              generation: 1,
              initialized: true,
              events: const <DeliveryEventSpec>[],
            ),
          ]);
        }
      },
    );

    test(
      'lastState usa vocabulario cerrado específico por sourceKind',
      () async {
        SourceCursorUpdate update(String sourceKind, String state) =>
            SourceCursorUpdate(
              scopeKey: 'conn-a/work/$sourceKind/object-$state',
              connId: 'conn-a',
              profile: 'work',
              sourceKind: sourceKind,
              objectId: 'object-$state',
              lastState: state,
              lastVersion: 'v1',
              generation: 1,
              initialized: true,
              events: const <DeliveryEventSpec>[],
            );

        final unopened = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '/must-not-be-opened/notification_delivery_v2.db',
        );
        for (final invalid in <SourceCursorUpdate>[
          update('run', 'blocked'),
          update('cron', 'ready'),
          update('approval', 'running'),
          update('chat_reply', 'arbitrary_token'),
        ]) {
          await expectLater(
            unopened.ingestSourceBatch(<SourceCursorUpdate>[invalid]),
            throwsArgumentError,
          );
        }
      },
    );

    test(
      'secret-bearing or free-text values are rejected before persistence',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-privacy-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
        );
        await store.open();
        addTearDown(store.close);

        const identity = NotificationEventIdentity(
          connId: 'conn-a',
          profile: 'work',
          sourceKind: 'run',
          objectId: 'run-1',
          eventKind: 'terminal',
          sourceVersion: 'v1',
        );
        SourceCursorUpdate update({
          String destinationKind = 'run_terminal',
          String lastState = 'completed',
          String lastVersion = 'v1',
          String? runId = 'run-1',
        }) {
          return SourceCursorUpdate(
            scopeKey: 'conn-a/work/run/run-1',
            connId: 'conn-a',
            profile: 'work',
            sourceKind: 'run',
            objectId: 'run-1',
            lastState: lastState,
            lastVersion: lastVersion,
            generation: 1,
            initialized: true,
            events: <DeliveryEventSpec>[
              DeliveryEventSpec(
                identity: identity,
                destinationKind: destinationKind,
                runId: runId,
              ),
            ],
          );
        }

        await store.ingestSourceBatch(<SourceCursorUpdate>[update()]);
        expect(await store.eventCount(), 1);

        await expectLater(
          store.ingestSourceBatch(<SourceCursorUpdate>[
            update(destinationKind: 'bearer sk-live-secret'),
          ]),
          throwsArgumentError,
        );
        await expectLater(
          store.ingestSourceBatch(<SourceCursorUpdate>[
            update(lastState: 'failed with api key sk-123'),
          ]),
          throwsArgumentError,
        );
        await expectLater(
          store.ingestSourceBatch(<SourceCursorUpdate>[
            update(lastVersion: 'prompt: delete everything\nrm -rf'),
          ]),
          throwsArgumentError,
        );
        await expectLater(
          store.ingestSourceBatch(<SourceCursorUpdate>[
            update(runId: 'https://user:password@host.internal/path'),
          ]),
          throwsArgumentError,
        );
        await expectLater(
          store.ingestSourceBatch(<SourceCursorUpdate>[
            update(runId: 'sk-1234567890abcdefghijklmnopqrstuv'),
          ]),
          throwsArgumentError,
        );
        await expectLater(
          store.ingestSourceBatch(<SourceCursorUpdate>[
            update(runId: 'api_key_xyz123'),
          ]),
          throwsArgumentError,
        );

        final lease = (await store.leaseNext())!;
        await expectLater(
          store.markPresented(
            identity.eventKey,
            lease.token,
            'https://tracker.example/collect?token=abc',
          ),
          throwsArgumentError,
        );
        await expectLater(
          store.retry(
            identity.eventKey,
            lease.token,
            delay: const Duration(seconds: 5),
            errorCode: 'PlatformException(secret token abc123)',
          ),
          throwsArgumentError,
        );
        expect(
          await store.retry(
            identity.eventKey,
            lease.token,
            delay: const Duration(seconds: 5),
            errorCode: 'platform_show',
          ),
          isTrue,
        );
        expect(await store.eventCount(), 1);
      },
    );
    test('secret-shaped cursor values persist only as digests', () async {
      final directory = await Directory.systemTemp.createTemp(
        'delivery-shape-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/notification_delivery_v1.db';
      final store = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: path,
      );
      await store.open();
      const approvalId = 'request-safe';
      final sourceVersion = <String>[
        'xoxb',
        '123456789012',
        '123456789012',
        'abcdefghijklmnopqrstuvwx',
      ].join('-');
      const scopeKey =
          'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzY29wZSJ9.abcdefghijklmnop';
      const identity = NotificationEventIdentity(
        connId: 'conn-safe',
        profile: 'work',
        sourceKind: 'approval',
        objectId: 'run-safe',
        eventKind: 'pending',
        sourceVersion: approvalId,
      );
      await store.ingestSourceBatch(<SourceCursorUpdate>[
        SourceCursorUpdate(
          scopeKey: scopeKey,
          connId: 'conn-safe',
          profile: 'work',
          sourceKind: 'approval',
          objectId: 'snapshot',
          lastState: 'pending',
          lastVersion: sourceVersion,
          generation: 1,
          initialized: true,
          events: <DeliveryEventSpec>[
            DeliveryEventSpec(
              identity: identity,
              destinationKind: 'approval',
              runId: 'run-safe',
              requestId: 'request-safe',
            ),
          ],
        ),
      ]);
      await store.close();

      final bytes = <int>[
        ...await File(path).readAsBytes(),
        if (await File('$path-wal').exists())
          ...await File('$path-wal').readAsBytes(),
      ];
      final persisted = latin1.decode(bytes, allowInvalid: true);
      expect(persisted, contains(approvalId));
      expect(persisted, isNot(contains(sourceVersion)));
      expect(persisted, isNot(contains(scopeKey)));
    });
  });

  group('retention and policy outcomes', () {
    test(
      'cron job seen running dispatches its later terminal transition',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-cron-running-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
        );
        await store.open();
        addTearDown(store.close);

        const scope = 'conn-a/default/cron/job/job-running';
        SourceCursorUpdate update(
          int? generation, {
          required String state,
          required String version,
          NotificationEventIdentity? event,
        }) => SourceCursorUpdate(
          scopeKey: scope,
          connId: 'conn-a',
          profile: 'default',
          sourceKind: 'cron',
          objectId: 'job-running',
          lastState: state,
          lastVersion: version,
          generation: (generation ?? 0) + 1,
          initialized: true,
          events: event == null
              ? const <DeliveryEventSpec>[]
              : <DeliveryEventSpec>[
                  DeliveryEventSpec(
                    identity: event,
                    destinationKind: 'cron_terminal',
                    jobId: 'job-running',
                  ),
                ],
        );

        await store.ingestDiscovery(
          scopeKey: scope,
          suppressByPolicy: false,
          buildUpdate: (generation) => update(
            generation,
            state: 'running',
            version: 'execution-1.running',
          ),
        );
        const terminal = NotificationEventIdentity(
          connId: 'conn-a',
          profile: 'default',
          sourceKind: 'cron',
          objectId: 'execution-1',
          eventKind: 'terminal',
          sourceVersion: 'execution-1.completed',
        );
        await store.ingestDiscovery(
          scopeKey: scope,
          suppressByPolicy: false,
          buildUpdate: (generation) => update(
            generation,
            state: 'completed',
            version: terminal.sourceVersion,
            event: terminal,
          ),
        );

        final events = await store.allEvents();
        expect(events, hasLength(1));
        expect(events.single.status, DeliveryStatus.pending);
      },
    );

    test(
      'global cron baseline permits a newly discovered terminal job',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-cron-new-terminal-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
        );
        await store.open();
        addTearDown(store.close);

        const identity = NotificationEventIdentity(
          connId: 'conn-a',
          profile: 'default',
          sourceKind: 'cron',
          objectId: 'execution-fast',
          eventKind: 'terminal',
          sourceVersion: 'execution-fast.completed',
        );
        await store.ingestDiscovery(
          scopeKey: 'conn-a/default/cron/job/job-fast',
          suppressByPolicy: false,
          suppressInitialEvents: false,
          buildUpdate: (generation) => SourceCursorUpdate(
            scopeKey: 'conn-a/default/cron/job/job-fast',
            connId: 'conn-a',
            profile: 'default',
            sourceKind: 'cron',
            objectId: 'job-fast',
            lastState: 'completed',
            lastVersion: identity.sourceVersion,
            generation: (generation ?? 0) + 1,
            initialized: true,
            events: const <DeliveryEventSpec>[
              DeliveryEventSpec(
                identity: identity,
                destinationKind: 'cron_terminal',
                jobId: 'job-fast',
              ),
            ],
          ),
        );

        final events = await store.allEvents();
        expect(events, hasLength(1));
        expect(events.single.status, DeliveryStatus.pending);
      },
    );

    test(
      'initial unhydrated cron terminal stays silent after hydration',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-cron-unhydrated-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
        );
        await store.open();
        addTearDown(store.close);

        const scope = 'conn-a/default/cron/job/job-unhydrated';
        const identity = NotificationEventIdentity(
          connId: 'conn-a',
          profile: 'default',
          sourceKind: 'cron',
          objectId: 'execution-old',
          eventKind: 'terminal',
          sourceVersion: 'execution-old.completed',
        );
        SourceCursorUpdate update(
          int? generation,
          List<DeliveryEventSpec> events,
        ) => SourceCursorUpdate(
          scopeKey: scope,
          connId: 'conn-a',
          profile: 'default',
          sourceKind: 'cron',
          objectId: 'job-unhydrated',
          lastState: 'snapshot',
          lastVersion: identity.sourceVersion,
          generation: (generation ?? 0) + 1,
          initialized: true,
          events: events,
        );

        await store.ingestDiscovery(
          scopeKey: scope,
          suppressByPolicy: false,
          suppressEventsWhenVersionUnchanged: true,
          buildUpdate: (generation) =>
              update(generation, const <DeliveryEventSpec>[]),
        );
        await store.ingestDiscovery(
          scopeKey: scope,
          suppressByPolicy: false,
          suppressEventsWhenVersionUnchanged: true,
          buildUpdate: (generation) =>
              update(generation, const <DeliveryEventSpec>[
                DeliveryEventSpec(
                  identity: identity,
                  destinationKind: 'cron_terminal',
                  jobId: 'job-unhydrated',
                ),
              ]),
        );

        expect(await store.eventCount(), 0);
      },
    );

    test(
      'prune then same cron snapshot never redelivers an old execution',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-cron-retention-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final clock = _MutableClock(
          DateTime.utc(2026, 8, 28).millisecondsSinceEpoch,
        );
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
          clock: clock.call,
          tokenFactory: () => 'cron-retention-owner',
        );
        await store.open();
        addTearDown(store.close);

        const scope = 'conn-a/default/cron/job/job-1';
        SourceCursorUpdate update(
          int? previousGeneration,
          NotificationEventIdentity? identity,
        ) => SourceCursorUpdate(
          scopeKey: scope,
          connId: 'conn-a',
          profile: 'default',
          sourceKind: 'cron',
          objectId: 'job-1',
          lastState: 'snapshot',
          lastVersion: identity?.sourceVersion ?? 'empty',
          generation: (previousGeneration ?? 0) + 1,
          initialized: true,
          events: identity == null
              ? const <DeliveryEventSpec>[]
              : <DeliveryEventSpec>[
                  DeliveryEventSpec(
                    identity: identity,
                    destinationKind: 'cron_terminal',
                    jobId: 'job-1',
                  ),
                ],
        );

        await store.ingestDiscovery(
          scopeKey: scope,
          suppressByPolicy: false,
          suppressEventsWhenVersionUnchanged: true,
          buildUpdate: (generation) => update(generation, null),
        );
        const first = NotificationEventIdentity(
          connId: 'conn-a',
          profile: 'default',
          sourceKind: 'cron',
          objectId: 'execution-1',
          eventKind: 'terminal',
          sourceVersion: 'execution-1.completed',
        );
        await store.ingestDiscovery(
          scopeKey: scope,
          suppressByPolicy: false,
          suppressEventsWhenVersionUnchanged: true,
          buildUpdate: (generation) => update(generation, first),
        );
        final lease = (await store.leaseNext())!;
        expect(
          await store.markPresented(first.eventKey, lease.token, 'alert'),
          isTrue,
        );

        clock.advance(const Duration(days: 31));
        await store.pruneRetention(
          maxAge: const Duration(days: 30),
          maxTombstones: 0,
        );
        expect(await store.eventCount(), 0);
        expect(await store.androidMappingCount(), 0);

        await store.ingestDiscovery(
          scopeKey: scope,
          suppressByPolicy: false,
          suppressEventsWhenVersionUnchanged: true,
          buildUpdate: (generation) => update(generation, first),
        );
        expect(await store.eventCount(), 0);

        const next = NotificationEventIdentity(
          connId: 'conn-a',
          profile: 'default',
          sourceKind: 'cron',
          objectId: 'execution-2',
          eventKind: 'terminal',
          sourceVersion: 'execution-2.completed',
        );
        await store.ingestDiscovery(
          scopeKey: scope,
          suppressByPolicy: false,
          suppressEventsWhenVersionUnchanged: true,
          buildUpdate: (generation) => update(generation, next),
        );
        final events = await store.allEvents();
        expect(events, hasLength(1));
        expect(events.single.eventKey, next.eventKey);
        expect(events.single.status, DeliveryStatus.pending);
      },
    );

    test(
      'suppression is explicit and retention preserves active work',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-retention-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final clock = _MutableClock(
          DateTime.utc(2026, 8, 28).millisecondsSinceEpoch,
        );
        var token = 0;
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
          clock: clock.call,
          tokenFactory: () => 'retention-${++token}',
        );
        await store.open();
        addTearDown(store.close);
        await store.ingestSourceBatch(<SourceCursorUpdate>[_retentionUpdate()]);
        final leases = await store.leaseBatch(2);
        expect(
          await store.markPresented(
            leases.first.event.eventKey,
            leases.first.token,
            'alert',
          ),
          isTrue,
        );
        final untouched = (await store.allEvents())
            .where(
              (event) => !leases.any(
                (lease) => lease.event.eventKey == event.eventKey,
              ),
            )
            .toList();
        expect(await store.markCancelPending(untouched[0].eventKey), isTrue);
        expect(await store.suppress(untouched[1].eventKey), isTrue);
        expect(await store.expire(untouched[2].eventKey), isTrue);
        expect(await store.markCancelPending(untouched[3].eventKey), isTrue);
        expect(await store.markCancelled(untouched[3].eventKey), isTrue);

        expect(await store.countActiveWork(), 3);
        expect(await store.countTombstones(), 4);
        expect(
          await store.pruneRetention(
            maxAge: const Duration(days: 30),
            maxTombstones: 2,
          ),
          2,
        );
        expect(await store.countActiveWork(), 3);
        expect(await store.countTombstones(), 2);

        clock.advance(const Duration(days: 31));
        expect(
          await store.pruneRetention(
            maxAge: const Duration(days: 30),
            maxTombstones: 2,
          ),
          2,
        );
        expect(await store.countActiveWork(), 3);
        expect(await store.countTombstones(), 0);
        expect(await store.androidMappingCount(), 3);
      },
    );

    test(
      'tombstone removal keeps android_id_map authority so replay is suppressed',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'delivery-dedup-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final clock = _MutableClock(
          DateTime.utc(2026, 8, 28).millisecondsSinceEpoch,
        );
        final store = NotificationDeliveryStore(
          databaseFactory: databaseFactoryFfi,
          databasePath: '${directory.path}/notification_delivery_v1.db',
          clock: clock.call,
          tokenFactory: () => 'dedup-owner',
        );
        await store.open();
        addTearDown(store.close);
        const identity = NotificationEventIdentity(
          connId: 'conn-a',
          profile: 'work',
          sourceKind: 'run',
          objectId: 'run-dedup',
          eventKind: 'terminal',
          sourceVersion: 'v1',
        );
        final update = _updateFor(identity);
        await store.ingestSourceBatch(<SourceCursorUpdate>[update]);
        final lease = (await store.leaseNext())!;
        expect(
          await store.markPresented(identity.eventKey, lease.token, 'alert'),
          isTrue,
        );
        expect(await store.eventCount(), 1);

        await store.pruneRetention(
          maxAge: const Duration(days: 30),
          maxTombstones: 0,
        );
        expect(await store.eventCount(), 0);
        expect(await store.androidMappingCount(), 1);

        await store.ingestSourceBatch(<SourceCursorUpdate>[update]);
        expect(await store.eventCount(), 0);
        expect(await store.androidMappingCount(), 1);

        clock.advance(const Duration(days: 31));
        await store.pruneRetention(
          maxAge: const Duration(days: 30),
          maxTombstones: 0,
        );
        expect(await store.androidMappingCount(), 0);

        await store.ingestSourceBatch(<SourceCursorUpdate>[update]);
        // The source cursor remains authoritative after Android mapping
        // retention: an identical generation/snapshot is still a replay.
        expect(await store.eventCount(), 0);
      },
    );

    test('mapping overflow only retires mappings past retention age', () async {
      final directory = await Directory.systemTemp.createTemp(
        'delivery-mapping-retention-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final clock = _MutableClock(
        DateTime.utc(2026, 8, 28).millisecondsSinceEpoch,
      );
      final store = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${directory.path}/notification_delivery_v1.db',
        clock: clock.call,
        tokenFactory: () => 'mapping-owner',
        mappingRetention: const Duration(days: 7),
      );
      await store.open();
      addTearDown(store.close);

      for (var index = 0; index < 5; index++) {
        await store.ingestSourceBatch(<SourceCursorUpdate>[
          _updateFor(
            NotificationEventIdentity(
              connId: 'conn-a',
              profile: 'work',
              sourceKind: 'run',
              objectId: 'run-mapping-$index',
              eventKind: 'terminal',
              sourceVersion: 'v1',
            ),
          ),
        ]);
      }
      final leases = await store.leaseBatch(5);
      for (var index = 0; index < 5; index++) {
        await store.markPresented(
          leases[index].event.eventKey,
          leases[index].token,
          'alert',
        );
      }

      clock.advance(const Duration(days: 3));
      await store.pruneRetention(
        maxAge: const Duration(days: 30),
        maxTombstones: 0,
      );
      expect(await store.androidMappingCount(), 5);

      clock.advance(const Duration(days: 5));
      await store.pruneRetention(
        maxAge: const Duration(days: 30),
        maxTombstones: 0,
      );
      expect(await store.androidMappingCount(), 0);
    });
  });

  group('process-death persistence', () {
    test('pending and leased work survive close and reopen', () async {
      final directory = await Directory.systemTemp.createTemp(
        'delivery-reopen-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/notification_delivery_v1.db';
      final clock = _MutableClock(
        DateTime.utc(2026, 8, 28).millisecondsSinceEpoch,
      );
      const pendingIdentity = NotificationEventIdentity(
        connId: 'conn-a',
        profile: 'work',
        sourceKind: 'run',
        objectId: 'pending-after-death',
        eventKind: 'terminal',
        sourceVersion: 'v1',
      );
      const leasedIdentity = NotificationEventIdentity(
        connId: 'conn-a',
        profile: 'work',
        sourceKind: 'run',
        objectId: 'leased-after-death',
        eventKind: 'terminal',
        sourceVersion: 'v1',
      );
      final beforeDeath = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: path,
        clock: clock.call,
        tokenFactory: () => 'dead-owner',
      );
      await beforeDeath.open();
      await beforeDeath.ingestSourceBatch(<SourceCursorUpdate>[
        _updateFor(pendingIdentity),
        _updateFor(leasedIdentity),
      ]);
      final leased = await beforeDeath.leaseNext();
      expect(leased, isNotNull);
      await beforeDeath.close();

      final afterDeath = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: path,
        clock: clock.call,
        tokenFactory: () => 'recovered-owner',
      );
      await afterDeath.open();
      addTearDown(afterDeath.close);
      expect(await afterDeath.countByStatus(DeliveryStatus.pending), 1);
      expect(await afterDeath.countByStatus(DeliveryStatus.leased), 1);

      clock.advance(const Duration(seconds: 31));
      expect(await afterDeath.reclaimExpiredLeases(), 1);
      expect(await afterDeath.countByStatus(DeliveryStatus.pending), 2);
      expect(
        await afterDeath.markPresented(
          leased!.event.eventKey,
          leased.token,
          'alert',
        ),
        isFalse,
      );
    });
  });

  group('lifecycle serialization', () {
    test('concurrent open uses exactly one database handle', () async {
      final directory = await Directory.systemTemp.createTemp('delivery-open-');
      addTearDown(() => directory.delete(recursive: true));
      final factory = _CountingFactory(databaseFactoryFfi);
      final store = NotificationDeliveryStore(
        databaseFactory: factory,
        databasePath: '${directory.path}/notification_delivery_v1.db',
      );
      await Future.wait(<Future<void>>[store.open(), store.open()]);
      expect(factory.openCount, 1);
      await store.close();
      expect(factory.openCount, 1);
    });

    test('close waits for operations before nulling the handle', () async {
      final directory = await Directory.systemTemp.createTemp(
        'delivery-close-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${directory.path}/notification_delivery_v1.db',
      );
      await store.open();
      final query = store.eventCount();
      final close = Future<void>.delayed(Duration.zero, store.close);
      final results = await Future.wait(<Future<Object?>>[query, close]);
      expect(results[0], 0);
      expect(() => store.eventCount(), throwsA(isA<StateError>()));
    });
  });

  group('NotificationDeliveryStore schema', () {
    test('opens schema v2 idempotently without sensitive columns', () async {
      final directory = await Directory.systemTemp.createTemp(
        'delivery-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/notification_delivery_v1.db';

      final first = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: path,
      );
      await first.open();

      expect(await first.schemaVersion(), 2);
      expect(
        await first.tableNames(),
        containsAll(<String>[
          'delivery_event',
          'source_cursor',
          'android_id_map',
          'delivery_meta',
        ]),
      );
      final columns = await first.tableColumns('delivery_event');
      expect(
        columns,
        containsAll(<String>[
          'event_key',
          'conn_id',
          'profile',
          'source_kind',
          'object_id',
          'event_kind',
          'source_version',
          'request_id',
          'destination_kind',
          'status',
          'android_id',
          'android_tag',
          'attempt_count',
          'next_attempt_at',
          'lease_token',
          'lease_until',
        ]),
      );
      const forbidden = <String>{
        'title',
        'body',
        'prompt',
        'command',
        'preview',
        'token',
        'api_key',
        'raw_payload',
      };
      expect(columns.toSet().intersection(forbidden), isEmpty);
      expect(await first.pragmaValue('foreign_keys'), 1);
      expect(await first.pragmaValue('synchronous'), 2);
      expect(await first.pragmaValue('busy_timeout'), greaterThan(0));
      expect(
        (await first.pragmaValue('journal_mode')).toString().toLowerCase(),
        'wal',
      );
      await first.close();

      final reopened = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: path,
      );
      await reopened.open();
      expect(await reopened.schemaVersion(), 2);
      expect(await reopened.tableColumns('delivery_event'), columns);
      await reopened.close();
    });
  });
}

SourceCursorUpdate _updateFor(NotificationEventIdentity identity) {
  return SourceCursorUpdate(
    scopeKey:
        '${identity.connId}/${identity.normalizedProfile}/'
        '${identity.sourceKind}/${identity.objectId}',
    connId: identity.connId,
    profile: identity.profile,
    sourceKind: identity.sourceKind,
    objectId: identity.objectId,
    lastState: 'completed',
    lastVersion: identity.sourceVersion,
    generation: 1,
    initialized: true,
    events: <DeliveryEventSpec>[
      DeliveryEventSpec(
        identity: identity,
        destinationKind: 'run_terminal',
        runId: identity.objectId,
      ),
    ],
  );
}

SourceCursorUpdate _batchUpdate(int count) {
  final events = List<DeliveryEventSpec>.generate(count, (index) {
    return DeliveryEventSpec(
      identity: NotificationEventIdentity(
        connId: 'conn-batch',
        profile: 'work',
        sourceKind: 'cron',
        objectId: 'execution-$index',
        eventKind: 'terminal',
        sourceVersion: 'v1',
      ),
      destinationKind: 'cron_terminal',
      jobId: 'job-$index',
    );
  });
  return SourceCursorUpdate(
    scopeKey: 'conn-batch/work/cron/snapshot-$count',
    connId: 'conn-batch',
    profile: 'work',
    sourceKind: 'cron',
    objectId: 'snapshot-$count',
    lastState: 'completed',
    lastVersion: 'v1',
    generation: 1,
    initialized: true,
    events: events,
  );
}

SourceCursorUpdate _collisionUpdate() {
  return const SourceCursorUpdate(
    scopeKey: 'conn/work/cron/collision-snapshot',
    connId: 'conn',
    profile: 'work',
    sourceKind: 'cron',
    objectId: 'collision-snapshot',
    lastState: 'completed',
    lastVersion: 'v1',
    generation: 1,
    initialized: true,
    events: <DeliveryEventSpec>[
      DeliveryEventSpec(
        identity: NotificationEventIdentity(
          connId: 'conn',
          profile: 'work',
          sourceKind: 'cron',
          objectId: 'execution-a',
          eventKind: 'terminal',
          sourceVersion: 'v1',
        ),
        destinationKind: 'cron_terminal',
        jobId: 'job-a',
      ),
      DeliveryEventSpec(
        identity: NotificationEventIdentity(
          connId: 'conn',
          profile: 'work',
          sourceKind: 'cron',
          objectId: 'execution-b',
          eventKind: 'terminal',
          sourceVersion: 'v1',
        ),
        destinationKind: 'cron_terminal',
        jobId: 'job-b',
      ),
    ],
  );
}

(SourceCursorUpdate, NotificationEventIdentity, NotificationEventIdentity)
_approvalUpdate() {
  const approvalA = NotificationEventIdentity(
    connId: 'conn-a',
    profile: 'work',
    sourceKind: 'approval',
    objectId: 'run-a',
    eventKind: 'pending',
    sourceVersion: 'request-a',
  );
  const approvalB = NotificationEventIdentity(
    connId: 'conn-a',
    profile: 'work',
    sourceKind: 'approval',
    objectId: 'run-b',
    eventKind: 'pending',
    sourceVersion: 'request-b',
  );
  return (
    const SourceCursorUpdate(
      scopeKey: 'conn-a/work/approval/snapshot',
      connId: 'conn-a',
      profile: 'work',
      sourceKind: 'approval',
      objectId: 'snapshot',
      lastState: 'pending',
      lastVersion: 'v1',
      generation: 1,
      initialized: true,
      events: <DeliveryEventSpec>[
        DeliveryEventSpec(
          identity: approvalA,
          destinationKind: 'approval',
          runId: 'run-a',
          requestId: 'request-a',
        ),
        DeliveryEventSpec(
          identity: approvalB,
          destinationKind: 'approval',
          runId: 'run-b',
          requestId: 'request-b',
        ),
      ],
    ),
    approvalA,
    approvalB,
  );
}

SourceCursorUpdate _retentionUpdate() {
  return SourceCursorUpdate(
    scopeKey: 'conn/work/run/retention-snapshot',
    connId: 'conn',
    profile: 'work',
    sourceKind: 'run',
    objectId: 'retention-snapshot',
    lastState: 'completed',
    lastVersion: 'v1',
    generation: 1,
    initialized: true,
    events: List<DeliveryEventSpec>.generate(7, (index) {
      return DeliveryEventSpec(
        identity: NotificationEventIdentity(
          connId: 'conn',
          profile: 'work',
          sourceKind: 'run',
          objectId: 'retention-$index',
          eventKind: 'terminal',
          sourceVersion: 'v1',
        ),
        destinationKind: 'run_terminal',
        runId: 'retention-$index',
      );
    }),
  );
}

class _CountingFactory implements sqflite.DatabaseFactory {
  _CountingFactory(this._inner);

  final sqflite.DatabaseFactory _inner;
  int openCount = 0;

  @override
  Future<sqflite.Database> openDatabase(
    String path, {
    sqflite.OpenDatabaseOptions? options,
  }) async {
    openCount += 1;
    return _inner.openDatabase(path, options: options);
  }

  @override
  Future<String> getDatabasesPath() => _inner.getDatabasesPath();

  @override
  Future<bool> databaseExists(String path) => _inner.databaseExists(path);

  @override
  Future<void> deleteDatabase(String path) => _inner.deleteDatabase(path);

  @override
  Future<Uint8List> readDatabaseBytes(String path) =>
      _inner.readDatabaseBytes(path);

  @override
  Future<void> setDatabasesPath(String path) => _inner.setDatabasesPath(path);

  @override
  Future<void> writeDatabaseBytes(String path, Uint8List bytes) =>
      _inner.writeDatabaseBytes(path, bytes);
}

class _MutableClock {
  _MutableClock(this.value);

  int value;

  int call() => value;

  void advance(Duration duration) {
    value += duration.inMilliseconds;
  }
}
