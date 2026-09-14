// ignore_for_file: prefer_initializing_formals

enum RecoveryDomain {
  transcript,
  turn,
  liveOverlay,
  tools,
  subagents,
  interactivePrompts,
}

final class RecoveryProof {
  final Object? _issuer;
  final Object? transactionIdentity;
  final Object channelIdentity;
  final String connectionId;
  final String durableSessionId;
  final String runtimeSessionId;
  final String profile;
  final int socketGeneration;
  final int bindGeneration;
  final int sessionGeneration;
  final int turnGeneration;
  final String? replayEpoch;
  final bool created;
  final bool durableIdentityExplicit;
  final bool identityAliasesConsistent;
  final Set<RecoveryDomain> coverage;
  final int? postSnapshotSequence;

  const RecoveryProof._minted({
    required Object issuer,
    required this.transactionIdentity,
    required this.channelIdentity,
    required this.connectionId,
    required this.durableSessionId,
    required this.runtimeSessionId,
    required this.profile,
    required this.socketGeneration,
    required this.bindGeneration,
    required this.sessionGeneration,
    required this.turnGeneration,
    required this.replayEpoch,
    required this.created,
    required this.durableIdentityExplicit,
    required this.identityAliasesConsistent,
    required this.coverage,
    required this.postSnapshotSequence,
  }) : _issuer = issuer;

  bool get coversLostProjection =>
      RecoveryDomain.values.every(coverage.contains);

  bool isStructurallyAuthoritative() =>
      _issuer != null &&
      connectionId.isNotEmpty &&
      connectionId == connectionId.trim() &&
      durableSessionId.isNotEmpty &&
      durableSessionId == durableSessionId.trim() &&
      runtimeSessionId.isNotEmpty &&
      runtimeSessionId == runtimeSessionId.trim() &&
      !created &&
      durableIdentityExplicit &&
      identityAliasesConsistent &&
      coversLostProjection;

  bool wasMintedBy(RecoveryProofAuthority authority) =>
      identical(_issuer, authority._issuer);
}

final class RecoveryProofAuthority {
  final Object _issuer = Object();

  RecoveryProof mint({
    required Object? transactionIdentity,
    required Object channelIdentity,
    required String connectionId,
    required String durableSessionId,
    required String runtimeSessionId,
    required String profile,
    required int socketGeneration,
    required int bindGeneration,
    required int sessionGeneration,
    required int turnGeneration,
    required String? replayEpoch,
    required bool created,
    required bool durableIdentityExplicit,
    required bool identityAliasesConsistent,
    required Set<RecoveryDomain> coverage,
    required int? postSnapshotSequence,
  }) => RecoveryProof._minted(
    issuer: _issuer,
    transactionIdentity: transactionIdentity,
    channelIdentity: channelIdentity,
    connectionId: connectionId,
    durableSessionId: durableSessionId,
    runtimeSessionId: runtimeSessionId,
    profile: profile,
    socketGeneration: socketGeneration,
    bindGeneration: bindGeneration,
    sessionGeneration: sessionGeneration,
    turnGeneration: turnGeneration,
    replayEpoch: replayEpoch,
    created: created,
    durableIdentityExplicit: durableIdentityExplicit,
    identityAliasesConsistent: identityAliasesConsistent,
    coverage: Set<RecoveryDomain>.unmodifiable(coverage),
    postSnapshotSequence: postSnapshotSequence,
  );
}
