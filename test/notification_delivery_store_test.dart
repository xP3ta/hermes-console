import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

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
  });

  group('lossless source ingestion', () {
    test('stale cursor generations still ingest unseen material events', () async {
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
          lastState: 'complete',
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

      expect(await store.eventCount(), 2);
      expect(await store.sourceCursorGeneration('conn-generation/work/run/snapshot'), 2);
    });

    test('reused scopeKey with a different cursor identity is rejected', () async {
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
          scopeKey: 'shared-scope',
          connId: connId,
          profile: 'work',
          sourceKind: 'run',
          objectId: objectId,
          lastState: 'complete',
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
          update(connId: 'conn-b', objectId: 'run-9', generation: 1),
        ]),
        throwsArgumentError,
      );
      expect(await store.eventCount(), 1);
      expect(await store.sourceCursorGeneration('shared-scope'), 2);
    });

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

  group('retention and policy outcomes', () {
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

  group('NotificationDeliveryStore schema', () {
    test('opens schema v1 idempotently without sensitive columns', () async {
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

      expect(await first.schemaVersion(), 1);
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
      expect(await reopened.schemaVersion(), 1);
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
    lastState: 'material',
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
    lastState: 'complete',
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
    lastState: 'complete',
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
      lastState: 'waiting',
      lastVersion: 'v1',
      generation: 1,
      initialized: true,
      events: <DeliveryEventSpec>[
        DeliveryEventSpec(
          identity: approvalA,
          destinationKind: 'approval',
          runId: 'run-a',
        ),
        DeliveryEventSpec(
          identity: approvalB,
          destinationKind: 'approval',
          runId: 'run-b',
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
    lastState: 'complete',
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

class _MutableClock {
  _MutableClock(this.value);

  int value;

  int call() => value;

  void advance(Duration duration) {
    value += duration.inMilliseconds;
  }
}
