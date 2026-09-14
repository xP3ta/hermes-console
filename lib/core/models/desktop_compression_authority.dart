import 'package:flutter/foundation.dart';

/// Immutable coordinates captured for one manual compression operation.
///
/// This value contains no I/O and is intentionally not serializable. Object
/// identities prevent equal textual ids from transferring authority between
/// ActiveChat, connection, or gateway instances.
@immutable
final class DesktopCompressionAuthorityState {
  const DesktopCompressionAuthorityState({
    required this.activeChatIdentity,
    required this.connectionIdentity,
    required this.gatewayIdentity,
    required this.disposed,
    required this.profileOwnerBound,
    required this.wireProfile,
    required this.storedSessionId,
    required this.runtimeSessionId,
    required this.bindEpoch,
    required this.sessionEpoch,
    required this.messageLoadEpoch,
    required this.tombstoneRevision,
    this.testingTainted = false,
  });

  final Object activeChatIdentity;
  final Object connectionIdentity;
  final Object? gatewayIdentity;
  final bool disposed;
  final bool profileOwnerBound;
  final String wireProfile;
  final String? storedSessionId;
  final String? runtimeSessionId;
  final int bindEpoch;
  final int sessionEpoch;
  final int messageLoadEpoch;
  final int tombstoneRevision;
  // Monotonic provenance, not ownership inferred from an equal binding id.
  final bool testingTainted;

  bool sameCoordinates(DesktopCompressionAuthorityState other) =>
      identical(activeChatIdentity, other.activeChatIdentity) &&
      identical(connectionIdentity, other.connectionIdentity) &&
      identical(gatewayIdentity, other.gatewayIdentity) &&
      disposed == other.disposed &&
      testingTainted == other.testingTainted &&
      profileOwnerBound == other.profileOwnerBound &&
      wireProfile == other.wireProfile &&
      storedSessionId == other.storedSessionId &&
      runtimeSessionId == other.runtimeSessionId &&
      bindEpoch == other.bindEpoch &&
      sessionEpoch == other.sessionEpoch &&
      messageLoadEpoch == other.messageLoadEpoch &&
      tombstoneRevision == other.tombstoneRevision;

  DesktopCompressionAuthorityState withBinding({
    String? storedSessionId,
    String? runtimeSessionId,
    required int bindEpoch,
    required int sessionEpoch,
    bool testingTainted = false,
  }) => DesktopCompressionAuthorityState(
    activeChatIdentity: activeChatIdentity,
    connectionIdentity: connectionIdentity,
    gatewayIdentity: gatewayIdentity,
    disposed: disposed,
    profileOwnerBound: profileOwnerBound,
    wireProfile: wireProfile,
    storedSessionId: storedSessionId,
    runtimeSessionId: runtimeSessionId,
    bindEpoch: bindEpoch,
    sessionEpoch: sessionEpoch,
    messageLoadEpoch: messageLoadEpoch,
    tombstoneRevision: tombstoneRevision,
    testingTainted: this.testingTainted || testingTainted,
  );

  DesktopCompressionAuthorityState withTombstoneRevision(int revision) =>
      DesktopCompressionAuthorityState(
        activeChatIdentity: activeChatIdentity,
        connectionIdentity: connectionIdentity,
        gatewayIdentity: gatewayIdentity,
        disposed: disposed,
        profileOwnerBound: profileOwnerBound,
        wireProfile: wireProfile,
        storedSessionId: storedSessionId,
        runtimeSessionId: runtimeSessionId,
        bindEpoch: bindEpoch,
        sessionEpoch: sessionEpoch,
        messageLoadEpoch: messageLoadEpoch,
        tombstoneRevision: revision,
        testingTainted: testingTainted,
      );
}

@immutable
final class DesktopCompressionAuthorityScope {
  const DesktopCompressionAuthorityScope({
    required this.connectionId,
    required this.profile,
    required this.logicalSessionId,
  });

  final String connectionId;
  final String profile;
  final String logicalSessionId;

  bool sameCoordinates(DesktopCompressionAuthorityScope other) =>
      connectionId == other.connectionId &&
      profile == other.profile &&
      logicalSessionId == other.logicalSessionId;
}

/// Captures intent before the operation's first await.
@immutable
final class DesktopCompressionAuthorityToken {
  const DesktopCompressionAuthorityToken.capture({
    required this.operationIdentity,
    required this.initialState,
    required this.requestedDurableId,
    required this.expectedRootId,
    required this.scope,
  });

  final Object operationIdentity;
  final DesktopCompressionAuthorityState initialState;
  final String requestedDurableId;
  final String? expectedRootId;
  final DesktopCompressionAuthorityScope scope;

  bool matchesInitialState(DesktopCompressionAuthorityState current) =>
      !current.disposed && initialState.sameCoordinates(current);

  DesktopCompressionAuthorityTransition? begin(
    DesktopCompressionAuthorityState current,
  ) {
    if (!matchesInitialState(current)) return null;
    return DesktopCompressionAuthorityTransition._(
      token: this,
      destination: current,
    );
  }

  DesktopCompressionAuthorityTransition? reserveOwnBind(
    DesktopCompressionAuthorityState current,
  ) => begin(current)?.reserveOwnBind(current);
}

/// The exact destination of an enumerated operation-owned transition.
@immutable
final class DesktopCompressionAuthorityTransition {
  const DesktopCompressionAuthorityTransition._({
    required this.token,
    required this.destination,
  });

  final DesktopCompressionAuthorityToken token;
  final DesktopCompressionAuthorityState destination;

  bool matches(DesktopCompressionAuthorityState current) =>
      !current.disposed && destination.sameCoordinates(current);

  DesktopCompressionAuthorityTransition? reserveOwnBind(
    DesktopCompressionAuthorityState current,
  ) {
    if (!matches(current)) return null;
    return DesktopCompressionAuthorityTransition._(
      token: token,
      destination: current.withBinding(
        storedSessionId: current.storedSessionId,
        runtimeSessionId: current.runtimeSessionId,
        bindEpoch: current.bindEpoch + 1,
        sessionEpoch: current.sessionEpoch,
      ),
    );
  }

  DesktopCompressionAuthorityTransition? acceptOwnTombstoneDelta(
    DesktopCompressionAuthorityState current,
  ) {
    if (!matches(current)) return null;
    return DesktopCompressionAuthorityTransition._(
      token: token,
      destination: current,
    );
  }

  DesktopCompressionAuthorityTransition? prepareOwnTombstoneRevision(
    DesktopCompressionAuthorityState current,
    int nextRevision,
  ) {
    if (!matches(current) || nextRevision != current.tombstoneRevision + 1) {
      return null;
    }
    return DesktopCompressionAuthorityTransition._(
      token: token,
      destination: current.withTombstoneRevision(nextRevision),
    );
  }
}

@immutable
final class DesktopCompressionAcquisitionEvidence {
  const DesktopCompressionAcquisitionEvidence({
    required this.runtimeSessionId,
    required this.storedSessionId,
    required this.storedSessionIdentityExplicit,
    required this.advertisedRootId,
    required this.identityAliasesConsistent,
    required this.created,
    this.compressionsAtStart,
  });

  final String runtimeSessionId;
  final String storedSessionId;
  final bool storedSessionIdentityExplicit;
  final String? advertisedRootId;
  final bool identityAliasesConsistent;
  final bool created;
  final int? compressionsAtStart;
}

enum DesktopCompressionReceiptProvenance {
  existingValidatedBinding,
  remoteExactDurable,
  remoteAdvertisedRoot,
  testingOnlyUnownedSnapshot,
}

/// A validated acquisition and the exact state it authorizes.
@immutable
final class DesktopCompressionAcquisitionReceipt {
  const DesktopCompressionAcquisitionReceipt._({
    required this.authority,
    required this.preimage,
    required this.destination,
    required this.evidence,
    required this.provenance,
  });

  final DesktopCompressionAuthorityToken authority;
  final DesktopCompressionAuthorityState preimage;
  final DesktopCompressionAuthorityState destination;
  final DesktopCompressionAcquisitionEvidence evidence;
  final DesktopCompressionReceiptProvenance provenance;

  String get runtimeSessionId => evidence.runtimeSessionId;
  String get storedSessionId => evidence.storedSessionId;
  String get wireProfile => authority.initialState.wireProfile;
  DesktopCompressionAuthorityScope get scope => authority.scope;

  static DesktopCompressionAcquisitionReceipt? forExistingBinding(
    DesktopCompressionAuthorityTransition transition, {
    int? compressionsAtStart,
  }) {
    final authority = transition.token;
    final initial = authority.initialState;
    final current = transition.destination;
    final runtime = current.runtimeSessionId;
    final stored = current.storedSessionId;
    if (initial.disposed ||
        initial.testingTainted ||
        current.testingTainted ||
        runtime == null ||
        stored == null ||
        stored != authority.requestedDurableId) {
      return null;
    }
    return DesktopCompressionAcquisitionReceipt._(
      authority: authority,
      preimage: current,
      destination: current,
      evidence: DesktopCompressionAcquisitionEvidence(
        runtimeSessionId: runtime,
        storedSessionId: stored,
        storedSessionIdentityExplicit: true,
        advertisedRootId: null,
        identityAliasesConsistent: true,
        created: false,
        compressionsAtStart: compressionsAtStart,
      ),
      provenance: DesktopCompressionReceiptProvenance.existingValidatedBinding,
    );
  }

  static DesktopCompressionAcquisitionReceipt? tryCreate({
    required DesktopCompressionAuthorityToken authority,
    required DesktopCompressionAuthorityState preimage,
    required DesktopCompressionAuthorityState destination,
    required DesktopCompressionAcquisitionEvidence evidence,
    bool allowTestingIdentityBypass = false,
  }) {
    if ((!allowTestingIdentityBypass &&
            (evidence.created || !evidence.identityAliasesConsistent)) ||
        evidence.runtimeSessionId.isEmpty ||
        evidence.storedSessionId.isEmpty ||
        destination.disposed ||
        destination.runtimeSessionId != evidence.runtimeSessionId ||
        destination.storedSessionId != evidence.storedSessionId ||
        !identical(
          authority.initialState.activeChatIdentity,
          destination.activeChatIdentity,
        ) ||
        !identical(
          authority.initialState.connectionIdentity,
          destination.connectionIdentity,
        ) ||
        !identical(
          authority.initialState.gatewayIdentity,
          destination.gatewayIdentity,
        ) ||
        !identical(
          preimage.activeChatIdentity,
          destination.activeChatIdentity,
        ) ||
        !identical(
          preimage.connectionIdentity,
          destination.connectionIdentity,
        ) ||
        !identical(preimage.gatewayIdentity, destination.gatewayIdentity) ||
        preimage.profileOwnerBound != destination.profileOwnerBound ||
        preimage.wireProfile != destination.wireProfile ||
        preimage.messageLoadEpoch != destination.messageLoadEpoch ||
        preimage.tombstoneRevision != destination.tombstoneRevision ||
        destination.bindEpoch < preimage.bindEpoch ||
        destination.sessionEpoch < preimage.sessionEpoch) {
      return null;
    }

    final root = evidence.advertisedRootId;
    if (!allowTestingIdentityBypass &&
        root != null &&
        root != authority.expectedRootId) {
      return null;
    }
    final remoteProvenance =
        evidence.storedSessionId == authority.requestedDurableId &&
            evidence.storedSessionIdentityExplicit
        ? DesktopCompressionReceiptProvenance.remoteExactDurable
        : root != null && root == authority.expectedRootId
        ? DesktopCompressionReceiptProvenance.remoteAdvertisedRoot
        : null;
    final testingTainted =
        allowTestingIdentityBypass ||
        authority.initialState.testingTainted ||
        preimage.testingTainted ||
        destination.testingTainted;
    final provenance = testingTainted
        ? DesktopCompressionReceiptProvenance.testingOnlyUnownedSnapshot
        : remoteProvenance;
    if (provenance == null) return null;

    return DesktopCompressionAcquisitionReceipt._(
      authority: authority,
      preimage: preimage,
      destination: destination.withBinding(
        storedSessionId: destination.storedSessionId,
        runtimeSessionId: destination.runtimeSessionId,
        bindEpoch: destination.bindEpoch,
        sessionEpoch: destination.sessionEpoch,
        testingTainted: testingTainted,
      ),
      evidence: evidence,
      provenance: provenance,
    );
  }

  bool canAuthorize(
    DesktopCompressionAuthorityToken consumer,
    DesktopCompressionAuthorityState current,
  ) {
    if (provenance ==
        DesktopCompressionReceiptProvenance.testingOnlyUnownedSnapshot) {
      return false;
    }
    final source = authority.initialState;
    final requested = consumer.initialState;
    if (current.disposed ||
        current.testingTainted ||
        requested.testingTainted ||
        !destination.sameCoordinates(current) ||
        !identical(source.activeChatIdentity, requested.activeChatIdentity) ||
        !identical(source.connectionIdentity, requested.connectionIdentity) ||
        !identical(source.gatewayIdentity, requested.gatewayIdentity) ||
        source.profileOwnerBound != requested.profileOwnerBound ||
        source.wireProfile != requested.wireProfile ||
        source.messageLoadEpoch != requested.messageLoadEpoch ||
        source.tombstoneRevision != requested.tombstoneRevision ||
        !authority.scope.sameCoordinates(consumer.scope)) {
      return false;
    }

    final root = evidence.advertisedRootId;
    if (root != null && root != consumer.expectedRootId) return false;
    return (evidence.storedSessionIdentityExplicit &&
            evidence.storedSessionId == consumer.requestedDurableId) ||
        (root != null && root == consumer.expectedRootId);
  }
}
