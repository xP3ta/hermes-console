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
}
