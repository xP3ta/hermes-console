import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/desktop_compression_fence_store.dart';

class _MemoryFenceStorage implements DesktopCompressionFenceStorage {
  String? value;
  int writeCalls = 0;
  Set<int> failingWrites = <int>{};
  Object? readError;

  @override
  Future<String?> read() async {
    if (readError case final error?) throw error;
    return value;
  }

  @override
  Future<void> write(String value) async {
    writeCalls += 1;
    if (failingWrites.contains(writeCalls)) {
      throw StateError('write unavailable');
    }
    this.value = value;
  }
}

class _BlockingWriteFenceStorage extends _MemoryFenceStorage {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> write(String value) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    await super.write(value);
  }
}

void main() {
  test(
    'independent test mutation namespaces do not block each other',
    () async {
      final blockedStorage = _BlockingWriteFenceStorage();
      final scopeA = DesktopCompressionFenceScope(
        connectionId: 'connection-a',
        profile: 'default',
        logicalSessionId: 'root-a',
      );
      final blockedArm =
          DesktopCompressionFenceStore(
            storage: blockedStorage,
            attemptId: () => 'attempt-a',
            mutationNamespaceForTesting: 'blocked-test-store',
          ).arm(
            scopeA,
            tipAtStart: 'tip-a',
            compressionsAtStart: null,
            createdAtMs: 100,
            reconcileUntilMs: 200,
          );
      await blockedStorage.entered.future;

      final independent =
          await DesktopCompressionFenceStore(
            storage: _MemoryFenceStorage(),
            attemptId: () => 'attempt-b',
            mutationNamespaceForTesting: 'independent-test-store',
          ).arm(
            DesktopCompressionFenceScope(
              connectionId: 'connection-b',
              profile: 'default',
              logicalSessionId: 'root-b',
            ),
            tipAtStart: 'tip-b',
            compressionsAtStart: null,
            createdAtMs: 100,
            reconcileUntilMs: 200,
          );

      expect(independent.claimed, isTrue);
      blockedStorage.release.complete();
      expect((await blockedArm).claimed, isTrue);
    },
  );

  test('an armed fence survives a new store instance', () async {
    final storage = _MemoryFenceStorage();
    final scope = DesktopCompressionFenceScope(
      connectionId: 'connection-a',
      profile: 'default',
      logicalSessionId: 'root-a',
    );
    final first = DesktopCompressionFenceStore(
      storage: storage,
      attemptId: () => 'attempt-a',
    );

    final armed = await first.arm(
      scope,
      tipAtStart: 'tip-a',
      compressionsAtStart: 4,
      createdAtMs: 100,
      reconcileUntilMs: 200,
    );
    final reopened = DesktopCompressionFenceStore(storage: storage);
    final lookup = await reopened.lookup(scope);

    expect(armed.claimed, isTrue);
    expect(lookup.status, DesktopCompressionFenceLookupStatus.present);
    expect(lookup.record?.attemptId, 'attempt-a');
    expect(lookup.record?.phase, DesktopCompressionFencePhase.armed);
  });

  test('strict decoding fails closed for noncanonical durable data', () async {
    final validRecord = <String, Object?>{
      'connection_id': 'connection-a',
      'profile': 'default',
      'logical_session_id': 'root-a',
      'attempt_id': 'attempt-a',
      'phase': 'armed',
      'tip_at_start': 'tip-a',
      'compressions_at_start': 4,
      'created_at_ms': 100,
      'reconcile_until_ms': 200,
    };
    final malformed = <Object?>[
      'not-json',
      {'v': 2, 'records': <Object?>[]},
      {'v': 1, 'records': 'not-a-list'},
      {
        'v': 1,
        'records': [validRecord, validRecord],
      },
      {
        'v': 1,
        'records': [
          {...validRecord, 'unexpected': 'private transcript sentinel'},
        ],
      },
      {
        'v': 1,
        'records': [
          {...validRecord, 'profile': ' default '},
        ],
      },
      {
        'v': 1,
        'records': [
          {...validRecord, 'compressions_at_start': -1},
        ],
      },
      {
        'v': 1,
        'records': [
          {...validRecord, 'messages_at_start': -1},
        ],
      },
      {
        'v': 1,
        'records': [
          {...validRecord, 'messages_at_start': '38'},
        ],
      },
      {
        'v': 1,
        'records': [
          {...validRecord, 'reconcile_until_ms': 99},
        ],
      },
    ];

    for (final value in malformed) {
      final storage = _MemoryFenceStorage()
        ..value = value is String ? value : jsonEncode(value);
      final lookup = await DesktopCompressionFenceStore(storage: storage)
          .lookup(
            DesktopCompressionFenceScope(
              connectionId: 'connection-a',
              profile: 'default',
              logicalSessionId: 'root-a',
            ),
          );
      expect(
        lookup.status,
        DesktopCompressionFenceLookupStatus.unavailable,
        reason: '$value',
      );
    }
  });

  test(
    'strict decoding rejects oversized containers and record sets',
    () async {
      Map<String, Object?> record(String root) => <String, Object?>{
        'connection_id': 'connection-a',
        'profile': 'default',
        'logical_session_id': root,
        'attempt_id': 'attempt-$root',
        'phase': 'armed',
        'tip_at_start': 'tip-$root',
        'compressions_at_start': 4,
        'created_at_ms': 100,
        'reconcile_until_ms': 200,
      };
      final scope = DesktopCompressionFenceScope(
        connectionId: 'connection-a',
        profile: 'default',
        logicalSessionId: 'root-a',
      );
      final tooMany = _MemoryFenceStorage()
        ..value = jsonEncode({
          'v': 1,
          'records': [record('root-a'), record('root-b')],
        });
      final oversized = _MemoryFenceStorage()
        ..value =
            '${' ' * (256 * 1024)}${jsonEncode({
              'v': 1,
              'records': [record('root-a')],
            })}';

      expect(
        (await DesktopCompressionFenceStore(
          storage: tooMany,
          maxRecords: 1,
        ).lookup(scope)).status,
        DesktopCompressionFenceLookupStatus.unavailable,
      );
      expect(
        (await DesktopCompressionFenceStore(
          storage: oversized,
        ).lookup(scope)).status,
        DesktopCompressionFenceLookupStatus.unavailable,
      );
    },
  );

  test('phase and deadline transitions require the current attempt id', () async {
    final storage = _MemoryFenceStorage();
    final scope = DesktopCompressionFenceScope(
      connectionId: 'connection-a',
      profile: 'default',
      logicalSessionId: 'root-a',
    );
    final store = DesktopCompressionFenceStore(
      storage: storage,
      attemptId: () => 'attempt-current',
    );
    await store.arm(
      scope,
      tipAtStart: 'tip-a',
      compressionsAtStart: null,
      createdAtMs: 100,
      reconcileUntilMs: 200,
    );

    expect(
      await store.transitionAttempt(
        scope,
        attemptId: 'attempt-stale',
        phase: DesktopCompressionFencePhase.serverPending,
        reconcileUntilMs: 900,
      ),
      isNull,
    );
    final unchanged = (await store.lookup(scope)).record!;
    expect(unchanged.phase, DesktopCompressionFencePhase.armed);
    expect(unchanged.reconcileUntilMs, 200);

    final transitioned = await store.transitionAttempt(
      scope,
      attemptId: 'attempt-current',
      phase: DesktopCompressionFencePhase.serverPending,
      reconcileUntilMs: 900,
    );
    expect(transitioned?.attemptId, 'attempt-current');
    expect(transitioned?.phase, DesktopCompressionFencePhase.serverPending);
    expect(transitioned?.reconcileUntilMs, 900);
    expect(
      await store.deleteAttempt(scope, attemptId: 'attempt-stale'),
      isFalse,
    );
    expect((await store.lookup(scope)).isFenced, isTrue);
    expect(
      await store.deleteAttempt(scope, attemptId: 'attempt-current'),
      isTrue,
    );
    expect((await store.lookup(scope)).isFenced, isFalse);
  });

  test(
    'REGRESSION_COMP_UNCERTAIN stale completion cannot clear a newer attempt',
    () async {
      final storage = _MemoryFenceStorage();
      final scope = DesktopCompressionFenceScope(
        connectionId: 'connection-a',
        profile: 'default',
        logicalSessionId: 'root-a',
      );
      var serial = 0;
      final store = DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'attempt-${++serial}',
      );
      final old = await store.arm(
        scope,
        tipAtStart: 'tip-old',
        compressionsAtStart: 1,
        createdAtMs: 100,
        reconcileUntilMs: 200,
      );
      expect(
        await store.deleteAttempt(
          scope,
          attemptId: old.lookup.record!.attemptId,
        ),
        isTrue,
      );
      final current = await store.arm(
        scope,
        tipAtStart: 'tip-new',
        compressionsAtStart: 2,
        createdAtMs: 300,
        reconcileUntilMs: 400,
      );

      expect(
        await store.deleteAttempt(
          scope,
          attemptId: old.lookup.record!.attemptId,
        ),
        isFalse,
      );
      expect(
        (await store.lookup(scope)).record?.attemptId,
        current.lookup.record?.attemptId,
      );
    },
  );

  test(
    'REGRESSION_COMP_UNCERTAIN contradictory root aliases never prove settlement',
    () {
      final record = DesktopCompressionFenceRecord(
        scope: DesktopCompressionFenceScope(
          connectionId: 'connection-a',
          profile: 'default',
          logicalSessionId: 'root-A',
        ),
        attemptId: 'attempt-A',
        phase: DesktopCompressionFencePhase.transportUnknown,
        tipAtStart: 'tip-before',
        compressionsAtStart: 1,
        createdAtMs: 100,
        reconcileUntilMs: 200,
      );

      final evidence = DesktopCompressionFenceEvidence.evaluate(record, {
        'id': 'tip-foreign',
        '_lineage_root_id': 'root-A',
        'lineage_root_id': 'root-B',
      });
      expect(evidence.provesSettlement, isFalse);
      expect(evidence.authoritativeTip, isNull);
    },
  );

  test(
    'capacity exhaustion fences new scopes without evicting unresolved records',
    () async {
      final storage = _MemoryFenceStorage();
      var attempt = 0;
      final store = DesktopCompressionFenceStore(
        storage: storage,
        maxRecords: 2,
        attemptId: () => 'attempt-${++attempt}',
      );
      DesktopCompressionFenceScope scope(String root) =>
          DesktopCompressionFenceScope(
            connectionId: 'connection-a',
            profile: 'default',
            logicalSessionId: root,
          );

      for (final root in ['root-a', 'root-b']) {
        expect(
          (await store.arm(
            scope(root),
            tipAtStart: root,
            compressionsAtStart: null,
            createdAtMs: 100,
            reconcileUntilMs: 200,
          )).claimed,
          isTrue,
        );
      }
      final exhausted = await store.arm(
        scope('root-c'),
        tipAtStart: 'root-c',
        compressionsAtStart: null,
        createdAtMs: 100,
        reconcileUntilMs: 200,
      );

      expect(exhausted.claimed, isFalse);
      expect(
        exhausted.lookup.status,
        DesktopCompressionFenceLookupStatus.unavailable,
      );
      expect((await store.lookup(scope('root-a'))).isFenced, isTrue);
      expect((await store.lookup(scope('root-b'))).isFenced, isTrue);
      expect((await store.lookup(scope('root-c'))).isFenced, isFalse);
    },
  );

  test('exact session and connection cleanup preserve other scopes', () async {
    final storage = _MemoryFenceStorage();
    var serial = 0;
    final store = DesktopCompressionFenceStore(
      storage: storage,
      attemptId: () => 'attempt-${++serial}',
    );
    final scopes = [
      DesktopCompressionFenceScope(
        connectionId: 'connection-a',
        profile: 'default',
        logicalSessionId: 'root-a',
      ),
      DesktopCompressionFenceScope(
        connectionId: 'connection-a',
        profile: 'private',
        logicalSessionId: 'root-a',
      ),
      DesktopCompressionFenceScope(
        connectionId: 'connection-a',
        profile: 'default',
        logicalSessionId: 'root-b',
      ),
      DesktopCompressionFenceScope(
        connectionId: 'connection-b',
        profile: 'default',
        logicalSessionId: 'root-a',
      ),
    ];
    for (final scope in scopes) {
      expect(
        (await store.arm(
          scope,
          tipAtStart: scope.logicalSessionId,
          compressionsAtStart: null,
          createdAtMs: 100,
          reconcileUntilMs: 200,
        )).claimed,
        isTrue,
      );
    }

    expect(await store.clearSession(scopes.first), 1);
    expect((await store.lookup(scopes.first)).isFenced, isFalse);
    for (final scope in scopes.skip(1)) {
      expect((await store.lookup(scope)).isFenced, isTrue);
    }

    expect(await store.clearConnection('connection-a'), 2);
    expect((await store.lookup(scopes[1])).isFenced, isFalse);
    expect((await store.lookup(scopes[2])).isFenced, isFalse);
    expect((await store.lookup(scopes[3])).isFenced, isTrue);
  });

  test(
    'REGRESSION_COMP_TYPED_SETTLEMENT_DUPLICATE identical aliases settle',
    () {
      final record = DesktopCompressionFenceRecord(
        scope: DesktopCompressionFenceScope(
          connectionId: 'connection-a',
          profile: 'default',
          logicalSessionId: 'root-a',
        ),
        attemptId: 'attempt-a',
        phase: DesktopCompressionFencePhase.transportUnknown,
        tipAtStart: 'tip-before',
        compressionsAtStart: 4,
        createdAtMs: 100,
        reconcileUntilMs: 200,
      );
      final evidence = DesktopCompressionFenceEvidence.evaluate(record, {
        'session': {
          'id': 'tip-after',
          'stored_session_id': 'tip-after',
          '_lineage_root_id': 'root-a',
          'lineage_root_id': 'root-a',
          'usage': {'compressions': 5},
          'info': {
            'stored_session_id': 'tip-after',
            'lineage_root': 'root-a',
            'usage': {'compressions': 5},
          },
        },
      });
      expect(evidence.provesSettlement, isTrue);
      expect(evidence.authoritativeTip, 'tip-after');
    },
  );

  test(
    'REGRESSION_COMP_TYPED_SETTLEMENT_CONTRADICTION invalidates changed tip',
    () {
      final record = DesktopCompressionFenceRecord(
        scope: DesktopCompressionFenceScope(
          connectionId: 'connection-a',
          profile: 'default',
          logicalSessionId: 'root-a',
        ),
        attemptId: 'attempt-a',
        phase: DesktopCompressionFencePhase.transportUnknown,
        tipAtStart: 'tip-before',
        compressionsAtStart: 4,
        createdAtMs: 100,
        reconcileUntilMs: 200,
      );
      final evidence = DesktopCompressionFenceEvidence.evaluate(record, {
        'session': {
          'id': 'tip-after',
          '_lineage_root_id': 'root-a',
          'usage': {'compressions': 5},
          'info': {
            'stored_session_id': 'tip-after',
            'lineage_root_id': 'root-a',
            'usage': {'compressions': 6},
          },
        },
      });
      expect(evidence.provesSettlement, isFalse);
      expect(evidence.authoritativeTip, isNull);
    },
  );

  test(
    'REGRESSION_COMP_TYPED_SETTLEMENT_INFO_SHAPE invalidates changed tip',
    () {
      final record = DesktopCompressionFenceRecord(
        scope: DesktopCompressionFenceScope(
          connectionId: 'connection-a',
          profile: 'default',
          logicalSessionId: 'root-a',
        ),
        attemptId: 'attempt-a',
        phase: DesktopCompressionFencePhase.transportUnknown,
        tipAtStart: 'tip-before',
        compressionsAtStart: 4,
        createdAtMs: 100,
        reconcileUntilMs: 200,
      );
      final evidence = DesktopCompressionFenceEvidence.evaluate(record, {
        'session': {
          'id': 'tip-after',
          '_lineage_root_id': 'root-a',
          'info': 'malformed',
        },
      });
      expect(evidence.provesSettlement, isFalse);
      expect(evidence.authoritativeTip, isNull);
    },
  );

  test(
    'REGRESSION_COMP_TYPED_SETTLEMENT_USAGE_SHAPE invalidates changed tip',
    () {
      final record = DesktopCompressionFenceRecord(
        scope: DesktopCompressionFenceScope(
          connectionId: 'connection-a',
          profile: 'default',
          logicalSessionId: 'root-a',
        ),
        attemptId: 'attempt-a',
        phase: DesktopCompressionFencePhase.transportUnknown,
        tipAtStart: 'tip-before',
        compressionsAtStart: 4,
        createdAtMs: 100,
        reconcileUntilMs: 200,
      );
      final evidence = DesktopCompressionFenceEvidence.evaluate(record, {
        'session': {
          'id': 'tip-after',
          '_lineage_root_id': 'root-a',
          'usage': 'malformed',
        },
      });
      expect(evidence.provesSettlement, isFalse);
      expect(evidence.authoritativeTip, isNull);
    },
  );

  test('exact authoritative root plus changed tip proves settlement', () async {
    final storage = _MemoryFenceStorage();
    final scope = DesktopCompressionFenceScope(
      connectionId: 'connection-a',
      profile: 'default',
      logicalSessionId: 'root-a',
    );
    final store = DesktopCompressionFenceStore(
      storage: storage,
      attemptId: () => 'attempt-a',
    );
    await store.arm(
      scope,
      tipAtStart: 'tip-before',
      compressionsAtStart: 4,
      createdAtMs: 100,
      reconcileUntilMs: 200,
    );
    final record = (await store.lookup(scope)).record!;

    final evidence = DesktopCompressionFenceEvidence.evaluate(record, {
      'session': {'id': 'tip-after', '_lineage_root_id': 'root-a'},
    });

    expect(evidence.provesSettlement, isTrue);
    expect(evidence.authoritativeTip, 'tip-after');
  });

  test(
    'exact authoritative root plus increased counter proves settlement',
    () async {
      final scope = DesktopCompressionFenceScope(
        connectionId: 'connection-a',
        profile: 'default',
        logicalSessionId: 'root-a',
      );
      final record = DesktopCompressionFenceRecord(
        scope: scope,
        attemptId: 'attempt-a',
        phase: DesktopCompressionFencePhase.transportUnknown,
        tipAtStart: 'tip-before',
        compressionsAtStart: 4,
        createdAtMs: 100,
        reconcileUntilMs: 200,
      );

      final evidence = DesktopCompressionFenceEvidence.evaluate(record, {
        'info': {
          '_lineage_root_id': 'root-a',
          'stored_session_id': 'tip-before',
          'usage': {'compressions': 5},
        },
      });

      expect(evidence.provesSettlement, isTrue);
      expect(evidence.authoritativeTip, isNull);
    },
  );

  test(
    'REGRESSION_COMP_IN_PLACE an exact REST read with fewer stored messages '
    'proves an in-place compaction settled',
    () {
      DesktopCompressionFenceRecord record({int? messages = 38}) =>
          DesktopCompressionFenceRecord(
            scope: DesktopCompressionFenceScope(
              connectionId: 'connection-a',
              profile: 'default',
              logicalSessionId: 'root-a',
            ),
            attemptId: 'attempt-a',
            phase: DesktopCompressionFencePhase.armed,
            tipAtStart: 'root-a',
            compressionsAtStart: null,
            messagesAtStart: messages,
            createdAtMs: 100,
            reconcileUntilMs: 200,
          );
      // `GET /api/sessions/{id}` as the real server answers it: no lineage
      // root, no compression counter, only the durable row.
      final settled = DesktopCompressionFenceEvidence.evaluate(record(), {
        'object': 'hermes.session',
        'session': {'id': 'root-a', 'message_count': 35},
      });
      expect(settled.provesSettlement, isTrue);
      expect(settled.authoritativeTip, isNull);
      // Flat dashboard shape is the same evidence.
      expect(
        DesktopCompressionFenceEvidence.evaluate(record(), {
          'id': 'root-a',
          'message_count': 35,
        }).provesSettlement,
        isTrue,
      );

      for (final payload in <Map<String, dynamic>>[
        {
          'session': {'id': 'root-a', 'message_count': 38},
        },
        {
          'session': {'id': 'root-a', 'message_count': 40},
        },
        {
          'session': {'id': 'other-root', 'message_count': 3},
        },
        {
          'session': {'id': 'root-a', 'message_count': '3'},
        },
        {
          'session': {
            'id': 'root-a',
            'message_count': 3,
            '_lineage_root_id': 'root-b',
          },
        },
        {
          'session': {'message_count': 3},
        },
      ]) {
        expect(
          DesktopCompressionFenceEvidence.evaluate(
            record(),
            payload,
          ).provesSettlement,
          isFalse,
          reason: '$payload',
        );
      }
      expect(
        DesktopCompressionFenceEvidence.evaluate(record(messages: null), {
          'session': {'id': 'root-a', 'message_count': 3},
        }).provesSettlement,
        isFalse,
      );
    },
  );

  test(
    'message baseline round-trips and legacy records without it still decode',
    () async {
      final storage = _MemoryFenceStorage();
      final scope = DesktopCompressionFenceScope(
        connectionId: 'connection-a',
        profile: 'default',
        logicalSessionId: 'root-a',
      );
      await DesktopCompressionFenceStore(
        storage: storage,
        attemptId: () => 'attempt-a',
      ).arm(
        scope,
        tipAtStart: 'root-a',
        compressionsAtStart: null,
        messagesAtStart: 38,
        createdAtMs: 100,
        reconcileUntilMs: 200,
      );
      final reopened = await DesktopCompressionFenceStore(
        storage: storage,
      ).lookup(scope);
      expect(reopened.record?.messagesAtStart, 38);

      final legacy = _MemoryFenceStorage()
        ..value = jsonEncode({
          'v': 1,
          'records': [
            {
              'connection_id': 'connection-a',
              'profile': 'default',
              'logical_session_id': 'root-a',
              'attempt_id': 'attempt-a',
              'phase': 'armed',
              'tip_at_start': 'root-a',
              'compressions_at_start': null,
              'created_at_ms': 100,
              'reconcile_until_ms': 200,
            },
          ],
        });
      final legacyLookup = await DesktopCompressionFenceStore(
        storage: legacy,
      ).lookup(scope);
      expect(legacyLookup.status, DesktopCompressionFenceLookupStatus.present);
      expect(legacyLookup.record?.messagesAtStart, isNull);
    },
  );

  test('read write phase and delete failures all fail closed', () async {
    final readFailure = _MemoryFenceStorage()..readError = StateError('read');
    final scope = DesktopCompressionFenceScope(
      connectionId: 'connection-a',
      profile: 'default',
      logicalSessionId: 'root-a',
    );
    expect(
      (await DesktopCompressionFenceStore(
        storage: readFailure,
      ).lookup(scope)).status,
      DesktopCompressionFenceLookupStatus.unavailable,
    );

    final armFailure = _MemoryFenceStorage()..failingWrites = {1};
    final failedArm = await DesktopCompressionFenceStore(storage: armFailure)
        .arm(
          scope,
          tipAtStart: 'tip-a',
          compressionsAtStart: null,
          createdAtMs: 100,
          reconcileUntilMs: 200,
        );
    expect(failedArm.claimed, isFalse);
    expect(
      failedArm.lookup.status,
      DesktopCompressionFenceLookupStatus.unavailable,
    );

    final mutationFailure = _MemoryFenceStorage()..failingWrites = {2, 3};
    final store = DesktopCompressionFenceStore(
      storage: mutationFailure,
      attemptId: () => 'attempt-a',
    );
    await store.arm(
      scope,
      tipAtStart: 'tip-a',
      compressionsAtStart: null,
      createdAtMs: 100,
      reconcileUntilMs: 200,
    );
    expect(
      await store.updatePhase(
        scope,
        attemptId: 'attempt-a',
        phase: DesktopCompressionFencePhase.serverPending,
      ),
      isFalse,
    );
    expect(await store.deleteAttempt(scope, attemptId: 'attempt-a'), isFalse);
    mutationFailure.failingWrites.clear();
    final retained = await store.lookup(scope);
    expect(retained.record?.phase, DesktopCompressionFencePhase.armed);
    expect(retained.record?.attemptId, 'attempt-a');
  });

  test('serialized durable JSON has only bounded metadata fields', () async {
    final storage = _MemoryFenceStorage();
    final store = DesktopCompressionFenceStore(
      storage: storage,
      attemptId: () => 'attempt-a',
    );
    await store.arm(
      DesktopCompressionFenceScope(
        connectionId: 'connection-a',
        profile: 'private',
        logicalSessionId: 'root-a',
      ),
      tipAtStart: 'tip-a',
      compressionsAtStart: 4,
      createdAtMs: 100,
      reconcileUntilMs: 200,
    );

    final decoded = jsonDecode(storage.value!) as Map<String, dynamic>;
    final record = (decoded['records'] as List).single as Map<String, dynamic>;
    expect(decoded.keys.toSet(), {'v', 'records'});
    expect(record.keys.toSet(), {
      'connection_id',
      'profile',
      'logical_session_id',
      'attempt_id',
      'phase',
      'tip_at_start',
      'compressions_at_start',
      'created_at_ms',
      'reconcile_until_ms',
    });
    final serialized = storage.value!;
    for (final sentinel in [
      'focus topic',
      'RPC error',
      'transcript body',
      '/private/path',
      'holder',
      'credential',
      'prompt',
      'title',
    ]) {
      expect(serialized, isNot(contains(sentinel)));
    }
    expect(serialized.length, lessThan(1024));
  });

  test(
    'invalid or free-form arm metadata is rejected before serialization',
    () async {
      final cases =
          <({DesktopCompressionFenceScope scope, String tip, String attempt})>[
            (
              scope: DesktopCompressionFenceScope(
                connectionId: 'connection-a',
                profile: 'default',
                logicalSessionId: 'root-a',
              ),
              tip: 'tip-a',
              attempt: 'credential secret',
            ),
            (
              scope: DesktopCompressionFenceScope(
                connectionId: 'connection-a',
                profile: 'default',
                logicalSessionId: 'root-a',
              ),
              tip: 'prompt body',
              attempt: 'attempt-a',
            ),
            (
              scope: DesktopCompressionFenceScope(
                connectionId: 'connection-a',
                profile: 'default',
                logicalSessionId: 'root transcript',
              ),
              tip: 'tip-a',
              attempt: 'attempt-a',
            ),
          ];

      for (final item in cases) {
        final storage = _MemoryFenceStorage();
        final result =
            await DesktopCompressionFenceStore(
              storage: storage,
              attemptId: () => item.attempt,
            ).arm(
              item.scope,
              tipAtStart: item.tip,
              compressionsAtStart: null,
              createdAtMs: 100,
              reconcileUntilMs: 200,
            );
        expect(result.claimed, isFalse);
        expect(
          result.lookup.status,
          DesktopCompressionFenceLookupStatus.unavailable,
        );
        expect(storage.value, isNull);
      }
    },
  );

  test(
    'non-authoritative and conflicting evidence never proves settlement',
    () {
      DesktopCompressionFenceRecord record({int? baseline = 4}) =>
          DesktopCompressionFenceRecord(
            scope: DesktopCompressionFenceScope(
              connectionId: 'connection-a',
              profile: 'default',
              logicalSessionId: 'root-a',
            ),
            attemptId: 'attempt-a',
            phase: DesktopCompressionFencePhase.transportUnknown,
            tipAtStart: 'tip-before',
            compressionsAtStart: baseline,
            createdAtMs: 100,
            reconcileUntilMs: 200,
          );
      final cases =
          <
            ({
              DesktopCompressionFenceRecord fence,
              Map<String, dynamic> payload,
            })
          >[
            (fence: record(), payload: const {}),
            (
              fence: record(),
              payload: const {'id': 'tip-after', '_lineage_root_id': 'root-b'},
            ),
            (
              fence: record(),
              payload: const {
                'id': 'tip-after',
                '_lineage_root_id': 'root-a',
                'lineage_root_id': 'root-b',
              },
            ),
            (
              fence: record(),
              payload: const {'id': 'tip-before', '_lineage_root_id': 'root-a'},
            ),
            (
              fence: record(),
              payload: const {
                'id': ' tip-after ',
                '_lineage_root_id': 'root-a',
              },
            ),
            (
              fence: record(),
              payload: const {
                'id': 'tip-after',
                '_lineage_root_id': 'root-a',
                'info': {
                  '_lineage_root_id': 'root-a',
                  'stored_session_id': 'tip-conflict',
                },
              },
            ),
            (
              fence: record(baseline: null),
              payload: const {
                'info': {
                  '_lineage_root_id': 'root-a',
                  'usage': {'compressions': 5},
                },
              },
            ),
            for (final count in <Object?>[4, 3, -1, '5', true, null])
              (
                fence: record(),
                payload: {
                  'info': {
                    '_lineage_root_id': 'root-a',
                    'usage': {'compressions': count},
                  },
                },
              ),
            (
              fence: record(),
              payload: const {
                '_lineage_root_id': 'root-a',
                'compacted': true,
                'running': false,
              },
            ),
          ];

      for (final item in cases) {
        final evidence = DesktopCompressionFenceEvidence.evaluate(
          item.fence,
          item.payload,
        );
        expect(evidence.provesSettlement, isFalse, reason: '${item.payload}');
        expect(evidence.authoritativeTip, isNull, reason: '${item.payload}');
      }
    },
  );
}
