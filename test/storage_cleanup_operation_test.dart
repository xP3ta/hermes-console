import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/session_deletion.dart';

void main() {
  setUp(LocalConversationCleanupFence.resetForTesting);

  test('revoked operation cannot hand off a prepared effect', () async {
    final life = LocalConversationCleanupFence.beginLifecycle(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
    );
    final resource = LocalConversationResourceKey(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
      physicalKey: 'draft-key',
    );
    final operation = LocalConversationCleanupFence.admitOperation(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
      lifecycle: life,
      kind: LocalConversationOperationKind.save,
      resources: [resource],
    );
    LocalConversationCleanupFence.endLifecycle(life);
    var mutations = 0;

    await expectLater(
      LocalConversationCleanupFence.commitEffect(
        operation: operation,
        resource: resource,
        mutation: () async => mutations++,
      ),
      throwsA(isA<LocalConversationWriteRejected>()),
    );
    expect(mutations, 0);
  });

  test('dispose after handoff does not cancel the storage result', () async {
    final life = LocalConversationCleanupFence.beginLifecycle(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
    );
    final resource = LocalConversationResourceKey(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
      physicalKey: 'draft-key',
    );
    final operation = LocalConversationCleanupFence.admitOperation(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
      lifecycle: life,
      kind: LocalConversationOperationKind.save,
      resources: [resource],
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final committing = LocalConversationCleanupFence.commitEffect(
      operation: operation,
      resource: resource,
      mutation: () async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;
    LocalConversationCleanupFence.endLifecycle(life);
    release.complete();
    expect(await committing, isTrue);
  });

  test(
    'session cutoff supersedes old prepared effects but not newer commits',
    () async {
      LocalConversationResourceKey resource(String profile) =>
          LocalConversationResourceKey(
            connectionId: 'c',
            profile: profile,
            sessionId: 's',
            physicalKey: 'draft-$profile',
          );
      final old = LocalConversationCleanupFence.admitOperation(
        connectionId: 'c',
        profile: 'p',
        sessionId: 's',
        kind: LocalConversationOperationKind.save,
        resources: [resource('p')],
      );
      final clear = LocalConversationCleanupFence.admitSessionClear(
        connectionId: 'c',
        sessionId: 's',
      );
      final newer = LocalConversationCleanupFence.admitOperation(
        connectionId: 'c',
        profile: 'p',
        sessionId: 's',
        kind: LocalConversationOperationKind.save,
        resources: [resource('p')],
      );
      var oldMutations = 0;
      expect(
        await LocalConversationCleanupFence.commitEffect(
          operation: old,
          resource: resource('p'),
          mutation: () async => oldMutations++,
        ),
        isFalse,
      );
      expect(oldMutations, 0);
      expect(
        await LocalConversationCleanupFence.commitEffect(
          operation: newer,
          resource: resource('p'),
          mutation: () async {},
        ),
        isTrue,
      );
      expect(
        LocalConversationCleanupFence.hasConfirmedCommitAfter(
          resource('p'),
          clear.admissionSequence,
        ),
        isTrue,
      );
    },
  );
  test('an admitted but unconfirmed save is not a committed version', () {
    final resource = LocalConversationResourceKey(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
      physicalKey: 'draft-p',
    );
    final clear = LocalConversationCleanupFence.admitSessionClear(
      connectionId: 'c',
      sessionId: 's',
    );
    LocalConversationCleanupFence.admitOperation(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
      kind: LocalConversationOperationKind.save,
      resources: [resource],
    );

    expect(
      LocalConversationCleanupFence.hasConfirmedCommitAfter(
        resource,
        clear.admissionSequence,
      ),
      isFalse,
    );
  });

  test('clear waits for an earlier delivered effect to settle', () async {
    final resource = LocalConversationResourceKey(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
      physicalKey: 'draft-p',
    );
    final save = LocalConversationCleanupFence.admitOperation(
      connectionId: 'c',
      profile: 'p',
      sessionId: 's',
      kind: LocalConversationOperationKind.save,
      resources: [resource],
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final committing = LocalConversationCleanupFence.commitEffect(
      operation: save,
      resource: resource,
      mutation: () async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;
    final clear = LocalConversationCleanupFence.admitSessionClear(
      connectionId: 'c',
      sessionId: 's',
    );
    var settled = false;
    final settling = LocalConversationCleanupFence.settleDeliveredEffectsBefore(
      clear,
    ).then((_) => settled = true);

    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    release.complete();
    await settling;
    expect(settled, isTrue);
    expect(await committing, isTrue);
  });

  group('operation journal stays bounded in a long-lived process', () {
    LocalConversationResourceKey key(String session) =>
        LocalConversationResourceKey(
          connectionId: 'c',
          profile: 'p',
          sessionId: session,
          physicalKey: 'draft-$session',
        );

    Future<void> completedSave(
      LocalConversationLifecycle life,
      String session,
    ) async {
      assert(life.sessionId == session);
      final operation = LocalConversationCleanupFence.admitOperation(
        connectionId: 'c',
        profile: 'p',
        sessionId: session,
        lifecycle: life,
        kind: LocalConversationOperationKind.save,
        resources: [key(session)],
      );
      expect(
        await LocalConversationCleanupFence.commitEffect(
          operation: operation,
          resource: key(session),
          mutation: () async {},
        ),
        isTrue,
      );
    }

    test('thousands of finished saves do not accumulate', () async {
      final life = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'c',
        profile: 'p',
        sessionId: 's',
      );
      for (var i = 0; i < 2000; i++) {
        await completedSave(life, 's');
      }
      expect(
        LocalConversationCleanupFence.operationJournalLengthForTesting,
        lessThan(5),
      );
    });

    test('saves of a closed screen that never ran are dropped', () async {
      for (var i = 0; i < 200; i++) {
        final life = LocalConversationCleanupFence.beginLifecycle(
          connectionId: 'c',
          profile: 'p',
          sessionId: 's',
        );
        LocalConversationCleanupFence.admitOperation(
          connectionId: 'c',
          profile: 'p',
          sessionId: 's',
          lifecycle: life,
          kind: LocalConversationOperationKind.save,
          resources: [key('s')],
        );
        LocalConversationCleanupFence.endLifecycle(life);
      }
      expect(
        LocalConversationCleanupFence.operationJournalLengthForTesting,
        lessThan(5),
      );
    });

    test('a save still waiting to run survives pruning and is superseded '
        'by a later session clear', () async {
      final life = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'c',
        profile: 'p',
        sessionId: 's',
      );
      final pending = LocalConversationCleanupFence.admitOperation(
        connectionId: 'c',
        profile: 'p',
        sessionId: 's',
        lifecycle: life,
        kind: LocalConversationOperationKind.save,
        resources: [key('s')],
      );
      final other = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'c',
        profile: 'p',
        sessionId: 'other',
      );
      for (var i = 0; i < 50; i++) {
        await completedSave(other, 'other');
      }
      final clear = LocalConversationCleanupFence.admitSessionClear(
        connectionId: 'c',
        sessionId: 's',
      );
      expect(LocalConversationCleanupFence.resourcesBefore(clear), [key('s')]);
      var mutations = 0;
      expect(
        await LocalConversationCleanupFence.commitEffect(
          operation: pending,
          resource: key('s'),
          mutation: () async => mutations++,
        ),
        isFalse,
      );
      expect(mutations, 0);
    });

    test('an unfinished session clear keeps blocking readers', () async {
      final clear = LocalConversationCleanupFence.admitSessionClear(
        connectionId: 'c',
        sessionId: 's',
      );
      final other = LocalConversationCleanupFence.beginLifecycle(
        connectionId: 'c',
        profile: 'p',
        sessionId: 'other',
      );
      for (var i = 0; i < 50; i++) {
        await completedSave(other, 'other');
      }
      var released = false;
      final waiting = LocalConversationCleanupFence.waitForSessionClears(
        connectionId: 'c',
        sessionId: 's',
      ).then((_) => released = true);
      await Future<void>.delayed(Duration.zero);
      expect(released, isFalse);

      LocalConversationCleanupFence.completeOperation(clear);
      await waiting;
      await completedSave(other, 'other');
      expect(
        LocalConversationCleanupFence.operationJournalLengthForTesting,
        lessThan(5),
      );
    });
  });
}
