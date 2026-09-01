import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_coordinator.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('failed database initialization can be retried', () async {
    final directory = await Directory.systemTemp.createTemp('delivery-open-');
    addTearDown(() => directory.delete(recursive: true));
    final store = _FailOnceOpenStore(
      '${directory.path}/notification_delivery_v1.db',
    );
    final coordinator = NotificationDeliveryCoordinator(
      store: store,
      presenter: _Presenter(0),
    );
    addTearDown(coordinator.close);

    await expectLater(coordinator.initialize(), throwsA(isA<StateError>()));
    await coordinator.initialize();

    expect(store.openAttempts, 2);
  });

  test('startup recovery applies durable retention before dispatch', () async {
    final directory = await Directory.systemTemp.createTemp(
      'delivery-retention-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = _RetentionTrackingStore(
      '${directory.path}/notification_delivery_v1.db',
    );
    final coordinator = NotificationDeliveryCoordinator(
      store: store,
      presenter: _Presenter(0),
    );
    addTearDown(coordinator.close);

    await coordinator.recoverAndDispatch();

    expect(store.pruneCalls, 1);
    expect(store.lastMaxAge, const Duration(days: 30));
    expect(store.lastMaxTombstones, 4096);
  });

  test('Desktop request A cancellation leaves request B presented', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final update = _desktopApprovals();

    await fixture.coordinator.ingestAndDispatch([update]);
    expect(fixture.presenter.shown, hasLength(2));
    expect(fixture.presenter.shown.map((event) => event.requestId).toSet(), {
      'request-A',
      'request-B',
    });
    expect(
      fixture.presenter.shown.every((event) => event.sessionId == 'desktop-1'),
      isTrue,
    );

    await fixture.coordinator.cancelApprovalForSession(
      connId: 'conn-a',
      profile: 'work',
      sessionId: 'desktop-1',
      requestId: 'request-A',
    );

    final events = await fixture.store.allEvents();
    expect(
      events.singleWhere((event) => event.requestId == 'request-A').status,
      DeliveryStatus.cancelled,
    );
    expect(
      events.singleWhere((event) => event.requestId == 'request-B').status,
      DeliveryStatus.presented,
    );
    expect(fixture.presenter.cancelled.map((event) => event.requestId), [
      'request-A',
    ]);
  });

  test(
    'ingests atomically then leases and presents with stable tag and id',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final update = _update('run-1');

      await fixture.coordinator.ingestAndDispatch(<SourceCursorUpdate>[update]);

      expect(fixture.presenter.shown, hasLength(1));
      final shown = fixture.presenter.shown.single;
      expect(shown.androidTag, startsWith('hermes.event.'));
      expect(shown.androidId, inInclusiveRange(0x40000000, 0x7fffffff));
      expect(
        (await fixture.store.eventByKey(
          update.events.single.identity.eventKey,
        ))!.status,
        DeliveryStatus.presented,
      );
    },
  );

  test('platform failure retries the same stable external identity', () async {
    final fixture = await _Fixture.create(failShows: 1);
    addTearDown(fixture.close);
    final update = _update('run-retry');

    await fixture.coordinator.ingestAndDispatch(<SourceCursorUpdate>[update]);
    expect(await fixture.store.countByStatus(DeliveryStatus.pending), 1);

    await fixture.coordinator.dispatch();

    expect(fixture.presenter.shown, hasLength(2));
    expect(
      fixture.presenter.shown[1].androidId,
      fixture.presenter.shown[0].androidId,
    );
    expect(
      fixture.presenter.shown[1].androidTag,
      fixture.presenter.shown[0].androidTag,
    );
    expect(await fixture.store.countByStatus(DeliveryStatus.presented), 1);
  });

  test('policy suppression becomes an explicit durable outcome', () async {
    final fixture = await _Fixture.create(
      presentation: DeliveryPresentation.suppressed,
    );
    addTearDown(fixture.close);

    await fixture.coordinator.ingestAndDispatch(<SourceCursorUpdate>[
      _update('run-suppressed'),
    ]);

    expect(await fixture.store.countByStatus(DeliveryStatus.suppressed), 1);
    expect(await fixture.store.countByStatus(DeliveryStatus.presented), 0);
  });

  test('genuine inline banner is durably presented inline', () async {
    final fixture = await _Fixture.create(
      presentation: DeliveryPresentation.inline,
    );
    addTearDown(fixture.close);
    final update = _update('run-inline');

    await fixture.coordinator.ingestAndDispatch(<SourceCursorUpdate>[update]);

    final event = await fixture.store.eventByKey(
      update.events.single.identity.eventKey,
    );
    expect(event!.status, DeliveryStatus.presented);
    expect(event.presentationSurface, 'inline');
  });

  test('transient presentation outcome remains pending for retry', () async {
    final fixture = await _Fixture.create(
      presentation: DeliveryPresentation.retry,
    );
    addTearDown(fixture.close);

    await fixture.coordinator.ingestAndDispatch(<SourceCursorUpdate>[
      _update('run-transient'),
    ]);

    expect(await fixture.store.countByStatus(DeliveryStatus.pending), 1);
    expect(await fixture.store.countByStatus(DeliveryStatus.presented), 0);
  });

  test(
    'losing the fence after show leaves stable identity for authoritative retry',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final update = _update('run-fence');
      fixture.presenter.afterShow = (event) async {
        fixture.clock.advance(const Duration(seconds: 31));
        await fixture.store.reclaimExpiredLeases();
      };

      await fixture.coordinator.ingestAndDispatch(<SourceCursorUpdate>[update]);

      expect(fixture.presenter.cancelled, isEmpty);
      final authoritative = await fixture.store.eventByKey(
        update.events.single.identity.eventKey,
      );
      expect(authoritative?.status, DeliveryStatus.pending);
      expect(
        authoritative?.androidTag,
        fixture.presenter.shown.single.androidTag,
      );
      expect(
        authoritative?.androidId,
        fixture.presenter.shown.single.androidId,
      );
    },
  );

  test(
    'expired owner cannot cancel presentation reclaimed and committed by new owner',
    () async {
      final fixture = await _Fixture.create(dispatchLimit: 1);
      addTearDown(fixture.close);
      final ownerAShowing = Completer<void>();
      final releaseOwnerA = Completer<void>();
      fixture.presenter.afterShow = (_) async {
        ownerAShowing.complete();
        await releaseOwnerA.future;
      };
      final update = _update('run-reclaimed-after-show');
      await fixture.coordinator.ingest(<SourceCursorUpdate>[update]);

      final ownerADispatch = fixture.coordinator.dispatch();
      await ownerAShowing.future;
      fixture.clock.advance(const Duration(seconds: 31));

      final ownerBStore = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${fixture.directory.path}/notification_delivery_v1.db',
        clock: fixture.clock.call,
        tokenFactory: () => 'owner-b',
      );
      final ownerBPresenter = _Presenter(0);
      final ownerB = NotificationDeliveryCoordinator(
        store: ownerBStore,
        presenter: ownerBPresenter,
        dispatchLimit: 1,
      );
      addTearDown(ownerB.close);
      await ownerB.recoverAndDispatch();
      expect(ownerBPresenter.shown, hasLength(1));
      expect(
        (await ownerBStore.eventByKey(
          update.events.single.identity.eventKey,
        ))!.status,
        DeliveryStatus.presented,
      );

      releaseOwnerA.complete();
      await ownerADispatch;

      expect(fixture.presenter.cancelled, isEmpty);
      expect(ownerBPresenter.cancelled, isEmpty);
      expect(
        (await ownerBStore.eventByKey(
          update.events.single.identity.eventKey,
        ))!.status,
        DeliveryStatus.presented,
      );
    },
  );

  test(
    'mark failure after show exact-cancels and retries the fenced lease',
    () async {
      var failMark = true;
      final fixture = await _Fixture.create(
        markPresentedFaultInjector: () {
          if (failMark) {
            failMark = false;
            throw StateError('injected mark failure');
          }
        },
      );
      addTearDown(fixture.close);
      final update = _update('run-mark-failure');

      await fixture.coordinator.ingestAndDispatch(<SourceCursorUpdate>[update]);

      expect(fixture.presenter.cancelled, hasLength(1));
      expect(
        fixture.presenter.cancelled.single.androidId,
        fixture.presenter.shown.single.androidId,
      );
      expect(
        fixture.presenter.cancelled.single.androidTag,
        fixture.presenter.shown.single.androidTag,
      );
      expect(await fixture.store.countByStatus(DeliveryStatus.pending), 1);

      await fixture.coordinator.dispatch();
      expect(await fixture.store.countByStatus(DeliveryStatus.presented), 1);
    },
  );

  test(
    'startup recovery reclaims expired leases and resumes dispatch',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final update = _update('run-recovered');
      await fixture.coordinator.ingest(<SourceCursorUpdate>[update]);
      expect(await fixture.store.leaseNext(), isNotNull);
      fixture.clock.advance(const Duration(seconds: 31));

      final recoveredStore = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${fixture.directory.path}/notification_delivery_v1.db',
        clock: fixture.clock.call,
        tokenFactory: () => 'recovered-owner',
      );
      final recoveredPresenter = _Presenter(0);
      final recoveredCoordinator = NotificationDeliveryCoordinator(
        store: recoveredStore,
        presenter: recoveredPresenter,
      );
      addTearDown(recoveredCoordinator.close);

      await recoveredCoordinator.recoverAndDispatch();

      expect(recoveredPresenter.shown, hasLength(1));
      expect(recoveredPresenter.shown.single.runId, 'run-recovered');
      expect(
        (await recoveredStore.eventByKey(
          update.events.single.identity.eventKey,
        ))!.status,
        DeliveryStatus.presented,
      );
    },
  );

  test(
    'discovery inserts suppression and cursor atomically across handles for 50 events',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'delivery-discovery-atomic-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/notification_delivery_v1.db';
      final inserted = Completer<void>();
      final release = Completer<void>();
      final writer = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: path,
        ingestFaultInjector: (index, _) async {
          if (index != 0) return;
          inserted.complete();
          await release.future;
        },
      );
      final competing = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: path,
        tokenFactory: () => 'competing-owner',
      );
      await writer.open();
      await competing.open();
      addTearDown(writer.close);
      addTearDown(competing.close);

      final ingest = writer.ingestDiscovery(
        scopeKey: 'conn-a/work/run/discovery',
        suppressByPolicy: false,
        buildUpdate: (previous) => _batchDiscoveryUpdate(
          count: 50,
          generation: (previous ?? 0) + 1,
          prefix: 'initial',
        ),
      );
      await inserted.future;
      var leaseCompleted = false;
      final competingLease = competing.leaseNext().whenComplete(
        () => leaseCompleted = true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        leaseCompleted,
        isFalse,
        reason: 'writer transaction must fence leasing',
      );
      release.complete();
      await ingest;

      expect(await competingLease, isNull);
      expect(await writer.countByStatus(DeliveryStatus.suppressed), 50);
      expect(await writer.countByStatus(DeliveryStatus.pending), 0);
      expect(
        await writer.sourceCursorGeneration('conn-a/work/run/discovery'),
        1,
      );
    },
  );

  test('close fences new work and drains every accepted operation', () async {
    final fixture = await _Fixture.create();
    final started = Completer<void>();
    final release = Completer<void>();
    fixture.presenter.afterShow = (_) async {
      started.complete();
      await release.future;
    };
    await fixture.coordinator.ingest(<SourceCursorUpdate>[
      _update('run-close-fence'),
    ]);

    final dispatch = fixture.coordinator.dispatch();
    await started.future;
    final close = fixture.coordinator.close();
    await expectLater(
      fixture.coordinator.ingest(<SourceCursorUpdate>[_update('too-late')]),
      throwsStateError,
    );
    release.complete();
    await dispatch;
    await close;
    expect(() => fixture.store.eventCount(), throwsStateError);
    await fixture.directory.delete(recursive: true);
  });

  test(
    'leased cancellation stays owner-fenced and owner compensates after show',
    () async {
      final fixture = await _Fixture.create(dispatchLimit: 1);
      addTearDown(fixture.close);
      final otherStore = NotificationDeliveryStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: '${fixture.directory.path}/notification_delivery_v1.db',
        clock: fixture.clock.call,
      );
      final otherPresenter = _Presenter(0);
      final other = NotificationDeliveryCoordinator(
        store: otherStore,
        presenter: otherPresenter,
      );
      await other.initialize();
      addTearDown(other.close);
      final update = _approvals();
      fixture.presenter.afterShow = (event) async {
        await other.cancelApprovalForRun(
          connId: event.connId,
          profile: event.profile,
          runId: event.runId!,
        );
        final pending = (await otherStore.eventByKey(event.eventKey))!;
        expect(pending.status, DeliveryStatus.cancelPending);
        expect(pending.leaseToken, isNotNull);
        expect(otherPresenter.cancelled, isEmpty);
      };

      await fixture.coordinator.ingestAndDispatch(<SourceCursorUpdate>[update]);

      final runA = (await fixture.store.allEvents()).singleWhere(
        (event) => event.runId == 'run-a',
      );
      expect(runA.status, DeliveryStatus.cancelled);
      expect(fixture.presenter.cancelled, hasLength(1));
      expect(otherPresenter.cancelled, isEmpty);
    },
  );

  test('expired cancel-pending lease is exact-cancelled on recovery', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final update = _approvals();
    await fixture.coordinator.ingest(<SourceCursorUpdate>[update]);
    final lease = (await fixture.store.leaseNext())!;
    expect(await fixture.store.markCancelPending(lease.event.eventKey), isTrue);
    fixture.clock.advance(const Duration(seconds: 31));

    final recoveryStore = NotificationDeliveryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: '${fixture.directory.path}/notification_delivery_v1.db',
      clock: fixture.clock.call,
    );
    final recoveryPresenter = _Presenter(0);
    final recovery = NotificationDeliveryCoordinator(
      store: recoveryStore,
      presenter: recoveryPresenter,
    );
    await recovery.initialize();
    addTearDown(recovery.close);
    await recovery.recoverAndDispatch();

    expect(
      recoveryPresenter.shown.where(
        (event) => event.eventKey == lease.event.eventKey,
      ),
      isEmpty,
    );
    expect(recoveryPresenter.cancelled, hasLength(1));
    expect(
      recoveryPresenter.cancelled.single.androidTag,
      lease.event.androidTag,
    );
    expect(recoveryPresenter.cancelled.single.androidId, lease.event.androidId);
    expect(
      (await recoveryStore.eventByKey(lease.event.eventKey))!.status,
      DeliveryStatus.cancelled,
    );
  });

  test(
    'targeted approval cancellation does not cancel a simultaneous approval',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final update = _approvals();
      await fixture.coordinator.ingest(<SourceCursorUpdate>[update]);

      await fixture.coordinator.cancelApprovalForRun(
        connId: 'conn-a',
        profile: 'work',
        runId: 'run-a',
      );

      expect(fixture.presenter.cancelled, hasLength(1));
      expect(fixture.presenter.cancelled.single.runId, 'run-a');
      final runB = (await fixture.store.allEvents()).singleWhere(
        (e) => e.runId == 'run-b',
      );
      expect(runB.status, DeliveryStatus.pending);
    },
  );
}

class _Fixture {
  _Fixture(
    this.directory,
    this.clock,
    this.store,
    this.presenter,
    this.coordinator,
  );

  final Directory directory;
  final _Clock clock;
  final NotificationDeliveryStore store;
  final _Presenter presenter;
  final NotificationDeliveryCoordinator coordinator;

  static Future<_Fixture> create({
    int failShows = 0,
    int dispatchLimit = 5,
    void Function()? markPresentedFaultInjector,
    DeliveryPresentation presentation = DeliveryPresentation.alert,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'delivery-coordinator-',
    );
    final clock = _Clock(DateTime.utc(2026, 8, 29).millisecondsSinceEpoch);
    var token = 0;
    final store = NotificationDeliveryStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: '${directory.path}/notification_delivery_v1.db',
      clock: clock.call,
      tokenFactory: () => 'owner-${++token}',
      markPresentedFaultInjector: markPresentedFaultInjector,
    );
    final presenter = _Presenter(failShows, presentation: presentation);
    final coordinator = NotificationDeliveryCoordinator(
      store: store,
      presenter: presenter,
      dispatchLimit: dispatchLimit,
      retryDelay: Duration.zero,
    );
    await coordinator.initialize();
    return _Fixture(directory, clock, store, presenter, coordinator);
  }

  Future<void> close() async {
    await coordinator.close();
    await directory.delete(recursive: true);
  }
}

class _FailOnceOpenStore extends NotificationDeliveryStore {
  _FailOnceOpenStore(String path)
    : super(databaseFactory: databaseFactoryFfi, databasePath: path);

  int openAttempts = 0;

  @override
  Future<void> open() async {
    openAttempts++;
    if (openAttempts == 1) throw StateError('injected open failure');
    await super.open();
  }
}

class _RetentionTrackingStore extends NotificationDeliveryStore {
  _RetentionTrackingStore(String path)
    : super(databaseFactory: databaseFactoryFfi, databasePath: path);

  int pruneCalls = 0;
  Duration? lastMaxAge;
  int? lastMaxTombstones;

  @override
  Future<int> pruneRetention({
    required Duration maxAge,
    required int maxTombstones,
  }) async {
    pruneCalls++;
    lastMaxAge = maxAge;
    lastMaxTombstones = maxTombstones;
    return 0;
  }
}

class _Presenter implements NotificationDeliveryPresenter {
  _Presenter(this.failShows, {this.presentation = DeliveryPresentation.alert});
  int failShows;
  final DeliveryPresentation presentation;
  final List<DeliveryEventRecord> shown = <DeliveryEventRecord>[];
  final List<DeliveryEventRecord> cancelled = <DeliveryEventRecord>[];
  Future<void> Function(DeliveryEventRecord event)? afterShow;

  @override
  Future<DeliveryPresentation> show(DeliveryEventRecord event) async {
    shown.add(event);
    if (failShows > 0) {
      failShows--;
      throw const NotificationPresentationException('platform_show');
    }
    await afterShow?.call(event);
    return presentation;
  }

  @override
  Future<void> cancel(DeliveryEventRecord event) async => cancelled.add(event);
}

class _Clock {
  _Clock(this.value);
  int value;
  int call() => value;
  void advance(Duration duration) => value += duration.inMilliseconds;
}

SourceCursorUpdate _batchDiscoveryUpdate({
  required int count,
  required int generation,
  required String prefix,
}) {
  return SourceCursorUpdate(
    scopeKey: 'conn-a/work/run/discovery',
    connId: 'conn-a',
    profile: 'work',
    sourceKind: 'run',
    objectId: 'discovery',
    lastState: 'completed',
    lastVersion: '$prefix-$generation',
    generation: generation,
    initialized: true,
    events: <DeliveryEventSpec>[
      for (var index = 0; index < count; index++)
        DeliveryEventSpec(
          identity: NotificationEventIdentity(
            connId: 'conn-a',
            profile: 'work',
            sourceKind: 'run',
            objectId: '$prefix-$index',
            eventKind: 'terminal',
            sourceVersion: 'v$generation',
          ),
          destinationKind: 'run_terminal',
          runId: '$prefix-$index',
        ),
    ],
  );
}

SourceCursorUpdate _update(String runId) {
  final identity = NotificationEventIdentity(
    connId: 'conn-a',
    profile: 'work',
    sourceKind: 'run',
    objectId: runId,
    eventKind: 'terminal',
    sourceVersion: 'v1',
  );
  return SourceCursorUpdate(
    scopeKey: 'conn-a/work/run/$runId',
    connId: 'conn-a',
    profile: 'work',
    sourceKind: 'run',
    objectId: runId,
    lastState: 'completed',
    lastVersion: 'v1',
    generation: 1,
    initialized: true,
    events: <DeliveryEventSpec>[
      DeliveryEventSpec(
        identity: identity,
        destinationKind: 'run_terminal',
        runId: runId,
      ),
    ],
  );
}

SourceCursorUpdate _desktopApprovals() => SourceCursorUpdate(
  scopeKey: 'conn-a/work/approval/desktop-1',
  connId: 'conn-a',
  profile: 'work',
  sourceKind: 'approval',
  objectId: 'desktop-1',
  lastState: 'pending',
  lastVersion: 'request-B',
  generation: 1,
  initialized: true,
  events: const [
    DeliveryEventSpec(
      identity: NotificationEventIdentity(
        connId: 'conn-a',
        profile: 'work',
        sourceKind: 'approval',
        objectId: 'desktop-1',
        eventKind: 'pending',
        sourceVersion: 'request-A',
      ),
      destinationKind: 'approval',
      sessionId: 'desktop-1',
      requestId: 'request-A',
    ),
    DeliveryEventSpec(
      identity: NotificationEventIdentity(
        connId: 'conn-a',
        profile: 'work',
        sourceKind: 'approval',
        objectId: 'desktop-1',
        eventKind: 'pending',
        sourceVersion: 'request-B',
      ),
      destinationKind: 'approval',
      sessionId: 'desktop-1',
      requestId: 'request-B',
    ),
  ],
);

SourceCursorUpdate _approvals() {
  DeliveryEventSpec event(String runId) => DeliveryEventSpec(
    identity: NotificationEventIdentity(
      connId: 'conn-a',
      profile: 'work',
      sourceKind: 'approval',
      objectId: runId,
      eventKind: 'pending',
      sourceVersion: 'request-$runId',
    ),
    destinationKind: 'approval',
    runId: runId,
    requestId: 'request-$runId',
  );
  return SourceCursorUpdate(
    scopeKey: 'conn-a/work/approval/snapshot',
    connId: 'conn-a',
    profile: 'work',
    sourceKind: 'approval',
    objectId: 'snapshot',
    lastState: 'pending',
    lastVersion: 'v1',
    generation: 1,
    initialized: true,
    events: <DeliveryEventSpec>[event('run-a'), event('run-b')],
  );
}
