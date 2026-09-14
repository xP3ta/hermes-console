import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_compression_authority.dart';

void main() {
  final chat = Object();
  final connection = Object();
  final gateway = Object();

  DesktopCompressionAuthorityState state({
    Object? chatIdentity,
    Object? connectionIdentity,
    Object? gatewayIdentity,
    bool disposed = false,
    bool profileOwnerBound = false,
    String wireProfile = '',
    String? storedSessionId,
    String? runtimeSessionId,
    int bindEpoch = 7,
    int sessionEpoch = 11,
    int messageLoadEpoch = 13,
    int tombstoneRevision = 17,
  }) => DesktopCompressionAuthorityState(
    activeChatIdentity: chatIdentity ?? chat,
    connectionIdentity: connectionIdentity ?? connection,
    gatewayIdentity: gatewayIdentity ?? gateway,
    disposed: disposed,
    profileOwnerBound: profileOwnerBound,
    wireProfile: wireProfile,
    storedSessionId: storedSessionId,
    runtimeSessionId: runtimeSessionId,
    bindEpoch: bindEpoch,
    sessionEpoch: sessionEpoch,
    messageLoadEpoch: messageLoadEpoch,
    tombstoneRevision: tombstoneRevision,
  );

  DesktopCompressionAuthorityToken token({
    DesktopCompressionAuthorityState? initial,
    String requestedDurableId = 'stored-A',
    String? expectedRootId = 'stored-A',
    String scopeProfile = 'default',
  }) => DesktopCompressionAuthorityToken.capture(
    operationIdentity: Object(),
    initialState: initial ?? state(),
    requestedDurableId: requestedDurableId,
    expectedRootId: expectedRootId,
    scope: DesktopCompressionAuthorityScope(
      connectionId: 'conn-A',
      profile: scopeProfile,
      logicalSessionId: 'stored-A',
    ),
  );

  group('Desktop compression authority token', () {
    test('matches only the complete captured tuple', () {
      final authority = token();
      expect(authority.matchesInitialState(state()), isTrue);

      final variants = <DesktopCompressionAuthorityState>[
        state(chatIdentity: Object()),
        state(connectionIdentity: Object()),
        state(gatewayIdentity: Object()),
        state(disposed: true),
        state(profileOwnerBound: true),
        state(wireProfile: 'profile-B'),
        state(storedSessionId: 'stored-B'),
        state(runtimeSessionId: 'runtime-A'),
        state(bindEpoch: 8),
        state(sessionEpoch: 12),
        state(messageLoadEpoch: 14),
        state(tombstoneRevision: 18),
      ];
      for (final variant in variants) {
        expect(authority.matchesInitialState(variant), isFalse);
      }
    });

    test('owner unset and explicit default are distinct', () {
      final unset = token(initial: state());
      expect(
        unset.matchesInitialState(
          state(profileOwnerBound: true, wireProfile: 'default'),
        ),
        isFalse,
      );
    });

    test('own bind reservation and exact tombstone delta are explicit', () {
      final authority = token();
      final reservation = authority.reserveOwnBind(state());
      expect(reservation, isNotNull);
      expect(reservation!.destination.bindEpoch, 8);
      expect(
        reservation.acceptOwnTombstoneDelta(
          state(bindEpoch: 8, tombstoneRevision: 19),
        ),
        isNull,
      );
      expect(
        reservation.acceptOwnTombstoneDelta(
          state(bindEpoch: 8, messageLoadEpoch: 14, tombstoneRevision: 19),
        ),
        isNull,
      );
      final planned = reservation.prepareOwnTombstoneRevision(
        state(bindEpoch: 8),
        18,
      );
      expect(planned, isNotNull);
      expect(
        planned!.matches(state(bindEpoch: 8, tombstoneRevision: 18)),
        isTrue,
      );
      expect(
        planned.acceptOwnTombstoneDelta(
          state(bindEpoch: 8, tombstoneRevision: 18),
        ),
        isNotNull,
      );
      expect(
        reservation.prepareOwnTombstoneRevision(state(bindEpoch: 8), 19),
        isNull,
      );
    });

    test('external preparation refresh cannot advance authority', () {
      final authority = token().begin(state())!;
      for (final load in [14, 15, 100]) {
        final refreshed = state(messageLoadEpoch: load);
        expect(authority.matches(refreshed), isFalse);
        expect(authority.reserveOwnBind(refreshed), isNull);
        expect(authority.prepareOwnTombstoneRevision(refreshed, 18), isNull);
      }
      expect(authority.destination.messageLoadEpoch, 13);
    });
  });

  group('Desktop compression acquisition receipt', () {
    DesktopCompressionAcquisitionReceipt? receipt({
      DesktopCompressionAuthorityToken? authority,
      String runtime = 'runtime-A',
      String stored = 'stored-A',
      bool explicitStored = true,
      String? root,
      bool aliasesConsistent = true,
      bool created = false,
      bool testingBypass = false,
      DesktopCompressionAuthorityState? destination,
    }) {
      final captured = authority ?? token();
      final reserved = captured.reserveOwnBind(captured.initialState)!;
      return DesktopCompressionAcquisitionReceipt.tryCreate(
        authority: captured,
        preimage: reserved.destination,
        destination:
            destination ??
            state(
              storedSessionId: stored,
              runtimeSessionId: runtime,
              bindEpoch: 9,
              sessionEpoch: 13,
            ),
        evidence: DesktopCompressionAcquisitionEvidence(
          runtimeSessionId: runtime,
          storedSessionId: stored,
          storedSessionIdentityExplicit: explicitStored,
          advertisedRootId: root,
          identityAliasesConsistent: aliasesConsistent,
          created: created,
        ),
        allowTestingIdentityBypass: testingBypass,
      );
    }

    test('exact durable and advertised same-root tip retain provenance', () {
      final exact = receipt();
      expect(exact, isNotNull);
      expect(
        exact!.provenance,
        DesktopCompressionReceiptProvenance.remoteExactDurable,
      );

      final rotated = receipt(stored: 'stored-tip-B', root: 'stored-A');
      expect(rotated, isNotNull);
      expect(
        rotated!.provenance,
        DesktopCompressionReceiptProvenance.remoteAdvertisedRoot,
      );
    });

    test(
      'missing, foreign, contradictory, ambiguous and created evidence fail',
      () {
        expect(receipt(stored: 'stored-B', root: null), isNull);
        expect(receipt(stored: 'stored-A', root: 'stored-B'), isNull);
        expect(receipt(stored: 'stored-A', aliasesConsistent: false), isNull);
        expect(receipt(stored: 'stored-A', explicitStored: false), isNull);
        expect(receipt(stored: 'stored-A', created: true), isNull);
      },
    );

    test('testing seam receipt can adopt but never authorize compression', () {
      final authority = token();
      final seam = receipt(
        authority: authority,
        stored: 'stored-B',
        aliasesConsistent: false,
        testingBypass: true,
      );
      expect(seam, isNotNull);
      expect(
        seam!.provenance,
        DesktopCompressionReceiptProvenance.testingOnlyUnownedSnapshot,
      );
      expect(seam.canAuthorize(authority, seam.destination), isFalse);
    });

    for (final kind in ['exact', 'created', 'aliases', 'foreign-root']) {
      test('testing bypass taints even favorable evidence $kind', () {
        final authority = token();
        final acquired = receipt(
          authority: authority,
          testingBypass: true,
          created: kind == 'created',
          aliasesConsistent: kind != 'aliases',
          root: kind == 'foreign-root' ? 'foreign-root' : null,
        )!;
        expect(acquired.canAuthorize(authority, acquired.destination), isFalse);
      });
    }

    test('testing taint survives fresh binding and own transitions', () {
      final acquired = receipt(stored: 'stored-B', testingBypass: true)!;
      final rebound = acquired.destination
          .withBinding(
            storedSessionId: 'stored-B',
            runtimeSessionId: 'runtime-B',
            bindEpoch: 20,
            sessionEpoch: 30,
          )
          .withTombstoneRevision(40);
      final fresh = token(initial: rebound, requestedDurableId: 'stored-B');
      expect(
        DesktopCompressionAcquisitionReceipt.forExistingBinding(
          fresh.begin(rebound)!,
        ),
        isNull,
        reason: 'adoption cannot promote testing evidence into authority',
      );
    });

    test('concurrent receipt serves only original durable or proved root', () {
      final original = token();
      final concurrent = token(
        initial: state(storedSessionId: 'stored-B', bindEpoch: 8),
        requestedDurableId: 'stored-B',
      );
      final exactB = receipt(
        authority: concurrent,
        runtime: 'runtime-B',
        stored: 'stored-B',
        destination: state(
          storedSessionId: 'stored-B',
          runtimeSessionId: 'runtime-B',
          bindEpoch: 10,
          sessionEpoch: 13,
        ),
      )!;
      expect(exactB.canAuthorize(original, exactB.destination), isFalse);

      final sameRoot = receipt(
        authority: concurrent,
        runtime: 'runtime-B',
        stored: 'stored-tip-B',
        root: 'stored-A',
        destination: state(
          storedSessionId: 'stored-tip-B',
          runtimeSessionId: 'runtime-B',
          bindEpoch: 10,
          sessionEpoch: 13,
        ),
      )!;
      expect(sameRoot.canAuthorize(original, sameRoot.destination), isTrue);
    });

    test('ready receipt rejects every non-transferable destination change', () {
      final authority = token();
      final acquired = receipt(authority: authority)!;
      expect(acquired.canAuthorize(authority, acquired.destination), isTrue);
      expect(
        acquired.canAuthorize(
          authority,
          state(
            storedSessionId: 'stored-A',
            runtimeSessionId: 'runtime-A',
            bindEpoch: 9,
            sessionEpoch: 13,
            messageLoadEpoch: 14,
          ),
        ),
        isFalse,
      );
      expect(
        acquired.canAuthorize(
          token(
            initial: state(profileOwnerBound: true, wireProfile: 'default'),
          ),
          acquired.destination,
        ),
        isFalse,
      );
    });
  });
}
