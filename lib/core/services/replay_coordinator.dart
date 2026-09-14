import 'dart:collection';

import 'json_rpc_wire.dart';
import 'recovery_proof.dart';
import 'replay_batch_proof.dart';

final class ReplayTransaction {
  final int generation;
  final Object channel;
  final String epoch;
  final String runtime;
  final int lastSeen;
  final List<SessionGatewayEvent> held = <SessionGatewayEvent>[];
  bool closed = false;

  ReplayTransaction({
    required this.generation,
    required this.channel,
    required this.epoch,
    required this.runtime,
    required this.lastSeen,
  });
}

final class _RecoveryTransaction {
  final Object identity = Object();
  final String runtime;
  int? socketGeneration;
  Object? channel;
  String? replayEpoch;
  String? connectionId;
  String? durableSessionId;
  String? profile;
  int? bindGeneration;
  int? sessionGeneration;
  int? turnGeneration;
  final List<SessionGatewayEvent> held = <SessionGatewayEvent>[];
  bool poisoned = false;

  _RecoveryTransaction({
    required this.runtime,
    this.socketGeneration,
    this.channel,
    this.replayEpoch,
  });

  bool bindWire({
    required int generation,
    required Object? channelIdentity,
    required String? epoch,
  }) {
    if (poisoned) return false;
    if (socketGeneration != null && socketGeneration != generation) {
      return false;
    }
    if (channel != null && !identical(channel, channelIdentity)) return false;
    if (replayEpoch != null && replayEpoch != epoch) return false;
    socketGeneration ??= generation;
    channel ??= channelIdentity;
    replayEpoch ??= epoch;
    return true;
  }

  bool bindAuthority({
    required String connection,
    required String durable,
    required String ownerProfile,
    required int bind,
    required int session,
    required int turn,
  }) {
    if (poisoned) return false;
    if ((connectionId != null && connectionId != connection) ||
        (durableSessionId != null && durableSessionId != durable) ||
        (profile != null && profile != ownerProfile) ||
        (bindGeneration != null && bindGeneration != bind) ||
        (sessionGeneration != null && sessionGeneration != session) ||
        (turnGeneration != null && turnGeneration != turn)) {
      return false;
    }
    connectionId ??= connection;
    durableSessionId ??= durable;
    profile ??= ownerProfile;
    bindGeneration ??= bind;
    sessionGeneration ??= session;
    turnGeneration ??= turn;
    return true;
  }
}

enum ReplayLiveDisposition { dispatch, held, ignored, quarantined }

final class ReplayCoordinator {
  static const int maxTrackedRuntimes = 32;
  static const int maxQuarantineEntries = 32;
  static const int maxRecoveryExceptions = 32;
  static const int maxHeldEvents = 64;
  static const int maxTotalHeldEvents = maxTrackedRuntimes * maxHeldEvents;

  final LinkedHashMap<String, int> _watermarks = LinkedHashMap<String, int>();
  final Set<String> _quarantine = <String>{};
  final Set<String> _recoveryExceptions = <String>{};
  final Map<String, ReplayTransaction> _transactions =
      <String, ReplayTransaction>{};
  final Map<String, _RecoveryTransaction> _recoveryTransactions =
      <String, _RecoveryTransaction>{};
  final Set<RecoveryProof> _outstandingRecoveryProofs =
      HashSet<RecoveryProof>.identity();
  final Map<String, List<SessionGatewayEvent>> _committedRecoveryEvents =
      <String, List<SessionGatewayEvent>>{};
  final Map<String, RecoveryProof> _committedRecoveryAuthorities =
      <String, RecoveryProof>{};
  bool _quarantineAll = false;
  bool _resourceOverflowed = false;
  int _totalHeldEvents = 0;
  final RecoveryProofAuthority _recoveryAuthority = RecoveryProofAuthority();

  RecoveryProof mintRecoveryProof({
    required String connectionId,
    required String durableSessionId,
    required String runtimeSessionId,
    required String profile,
    required int socketGeneration,
    required Object channel,
    required int bindGeneration,
    required int sessionGeneration,
    required int turnGeneration,
    required String? replayEpoch,
    required bool created,
    required bool durableIdentityExplicit,
    required bool identityAliasesConsistent,
    required Set<RecoveryDomain> coverage,
    required int? postSnapshotSequence,
  }) {
    _outstandingRecoveryProofs.removeWhere(
      (candidate) => candidate.runtimeSessionId == runtimeSessionId,
    );
    final transaction = _recoveryTransactionFor(runtimeSessionId);
    if (transaction == null ||
        !transaction.bindWire(
          generation: socketGeneration,
          channelIdentity: channel,
          epoch: replayEpoch,
        ) ||
        !transaction.bindAuthority(
          connection: connectionId,
          durable: durableSessionId,
          ownerProfile: profile,
          bind: bindGeneration,
          session: sessionGeneration,
          turn: turnGeneration,
        )) {
      if (transaction != null) _poisonRecovery(transaction);
    }
    final proof = _recoveryAuthority.mint(
      transactionIdentity: transaction?.identity,
      channelIdentity: channel,
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
      coverage: coverage,
      postSnapshotSequence: postSnapshotSequence,
    );
    if (transaction != null && !transaction.poisoned && !_resourceOverflowed) {
      _outstandingRecoveryProofs.add(proof);
    }
    return proof;
  }

  List<SessionGatewayEvent> takeCommittedRecoveryEvents(String runtime) =>
      List<SessionGatewayEvent>.unmodifiable(
        _committedRecoveryEvents.remove(runtime) ??
            const <SessionGatewayEvent>[],
      );

  bool get hasWatermarks => _watermarks.isNotEmpty;
  Map<String, int> get watermarks => Map<String, int>.unmodifiable(_watermarks);
  bool isQuarantined(String runtime) =>
      _resourceOverflowed ||
      (_quarantineAll && !_recoveryExceptions.contains(runtime)) ||
      _quarantine.contains(runtime);

  List<MapEntry<String, int>> beginReconnect({
    required int generation,
    required Object channel,
    required String epoch,
  }) {
    _poisonWireMismatches(
      generation: generation,
      channel: channel,
      epoch: epoch,
    );
    final entries = _watermarks.entries.toList(growable: false);
    final overflow = entries.length - maxTrackedRuntimes;
    if (overflow > 0) {
      _poisonAllForResourceOverflow();
      return const <MapEntry<String, int>>[];
    }
    for (final entry in entries) {
      _transactions[entry.key] = ReplayTransaction(
        generation: generation,
        channel: channel,
        epoch: epoch,
        runtime: entry.key,
        lastSeen: entry.value,
      );
    }
    return entries;
  }

  ReplayLiveDisposition acceptLive(
    SessionGatewayEvent event, {
    int? socketGeneration,
    Object? channel,
    String? replayEpoch,
  }) {
    final runtime = event.sessionId;
    if (_resourceOverflowed) return ReplayLiveDisposition.quarantined;
    if (isQuarantined(runtime)) {
      final held = _recoveryTransactionFor(
        runtime,
        socketGeneration: socketGeneration,
        channel: channel,
        replayEpoch: replayEpoch,
      );
      if (held == null || held.poisoned) {
        return ReplayLiveDisposition.quarantined;
      }
      if (socketGeneration != null &&
          !held.bindWire(
            generation: socketGeneration,
            channelIdentity: channel,
            epoch: replayEpoch,
          )) {
        _poisonRecovery(held);
        return ReplayLiveDisposition.quarantined;
      }
      if (held.held.length >= maxHeldEvents ||
          _totalHeldEvents >= maxTotalHeldEvents) {
        _poisonRecovery(held);
        return ReplayLiveDisposition.quarantined;
      }
      held.held.add(event);
      _totalHeldEvents += 1;
      return ReplayLiveDisposition.held;
    }
    final transaction = _transactions[runtime];
    if (transaction != null && !transaction.closed) {
      if ((socketGeneration != null &&
              transaction.generation != socketGeneration) ||
          (channel != null && !identical(transaction.channel, channel)) ||
          (replayEpoch != null && transaction.epoch != replayEpoch)) {
        abandonTransaction(runtime);
        return ReplayLiveDisposition.quarantined;
      }
      if (transaction.held.length >= maxHeldEvents ||
          _totalHeldEvents >= maxTotalHeldEvents) {
        abandonTransaction(runtime);
        return ReplayLiveDisposition.quarantined;
      }
      transaction.held.add(event);
      _totalHeldEvents += 1;
      return ReplayLiveDisposition.held;
    }
    final sequence = event.sequence!;
    final previous = _watermarks[runtime];
    if (previous == null) {
      _recordWatermark(runtime, sequence);
      return isQuarantined(runtime)
          ? ReplayLiveDisposition.quarantined
          : ReplayLiveDisposition.dispatch;
    }
    if (sequence <= previous) return ReplayLiveDisposition.ignored;
    if (sequence != previous + 1) {
      quarantine(runtime);
      return ReplayLiveDisposition.quarantined;
    }
    _recordWatermark(runtime, sequence);
    return ReplayLiveDisposition.dispatch;
  }

  ReplayBatchDecision validateReplay(String runtime, Object? result) {
    final transaction = _transactions[runtime];
    if (transaction == null || transaction.closed) {
      return const ReplayBatchQuarantine('replay transaction is not current');
    }
    final decision = ReplayBatchProof.validate(
      runtime: runtime,
      epoch: transaction.epoch,
      lastSeen: transaction.lastSeen,
      result: result,
      held: List<SessionGatewayEvent>.unmodifiable(transaction.held),
    );
    _totalHeldEvents -= transaction.held.length;
    transaction.held.clear();
    transaction.closed = true;
    _transactions.remove(runtime);
    quarantine(runtime);
    return decision;
  }

  void abandonTransaction(String runtime) {
    final transaction = _transactions.remove(runtime);
    if (transaction != null) {
      _totalHeldEvents -= transaction.held.length;
      transaction.held.clear();
      transaction.closed = true;
    }
    quarantine(runtime);
  }

  void abandonAllTransactions() {
    for (final runtime in _transactions.keys.toList(growable: false)) {
      abandonTransaction(runtime);
    }
  }

  void rotateEpoch() {
    final observed = <String>{
      ..._watermarks.keys,
      ..._transactions.keys,
      ..._recoveryTransactions.keys,
    };
    _watermarks.clear();
    for (final transaction in _transactions.values) {
      _totalHeldEvents -= transaction.held.length;
      transaction.held.clear();
      transaction.closed = true;
    }
    _transactions.clear();
    for (final transaction in _recoveryTransactions.values.toList()) {
      _poisonRecovery(transaction);
    }
    _recoveryTransactions.clear();
    _outstandingRecoveryProofs.clear();
    _committedRecoveryAuthorities.clear();
    for (final runtime in observed) {
      quarantine(runtime);
    }
  }

  void retireTransport({required int generation, required Object channel}) {
    _committedRecoveryAuthorities.removeWhere(
      (_, proof) =>
          proof.socketGeneration == generation &&
          identical(proof.channelIdentity, channel),
    );
    for (final transaction in _recoveryTransactions.values.toList()) {
      if (transaction.socketGeneration == generation &&
          identical(transaction.channel, channel)) {
        _poisonRecovery(transaction);
        if (identical(
          _recoveryTransactions[transaction.runtime],
          transaction,
        )) {
          _recoveryTransactions.remove(transaction.runtime);
        }
      }
    }
    for (final entry in _transactions.entries.toList()) {
      final transaction = entry.value;
      if (transaction.generation == generation &&
          identical(transaction.channel, channel)) {
        abandonTransaction(entry.key);
      }
    }
  }

  void quarantine(String runtime) {
    _committedRecoveryEvents.remove(runtime);
    _committedRecoveryAuthorities.remove(runtime);
    _outstandingRecoveryProofs.removeWhere(
      (proof) => proof.runtimeSessionId == runtime,
    );
    _watermarks.remove(runtime);
    final replay = _transactions.remove(runtime);
    if (replay != null) {
      _totalHeldEvents -= replay.held.length;
      replay.held.clear();
      replay.closed = true;
    }
    if (_resourceOverflowed) return;
    final known = <String>{
      ..._quarantine,
      ..._watermarks.keys,
      ..._transactions.keys,
      ..._recoveryTransactions.keys,
    };
    if (!known.contains(runtime) && known.length >= maxTrackedRuntimes) {
      _poisonAllForResourceOverflow();
      return;
    }
    if (_quarantineAll) {
      _recoveryExceptions.remove(runtime);
      return;
    }
    _quarantine.add(runtime);
    if (_quarantine.length > maxQuarantineEntries) {
      _poisonAllForResourceOverflow();
    }
  }

  bool commitRecovery(
    RecoveryProof proof, {
    required int socketGeneration,
    required Object channel,
    required String? replayEpoch,
  }) {
    if (!canCommitRecovery(
      proof,
      socketGeneration: socketGeneration,
      channel: channel,
      replayEpoch: replayEpoch,
    )) {
      _outstandingRecoveryProofs.remove(proof);
      return false;
    }
    _outstandingRecoveryProofs.remove(proof);
    final runtime = proof.runtimeSessionId;
    final transaction = _recoveryTransactions[runtime]!;
    final baseline = proof.postSnapshotSequence!;
    final released = <SessionGatewayEvent>[];
    for (final event in transaction.held) {
      if (event.sequence! > baseline) released.add(event);
    }
    _totalHeldEvents -= transaction.held.length;
    transaction.held.clear();
    _recoveryTransactions.remove(runtime);
    _quarantine.remove(runtime);
    if (_quarantineAll) {
      _recoveryExceptions.add(runtime);
      if (_recoveryExceptions.length > maxRecoveryExceptions) {
        _recoveryExceptions.remove(_recoveryExceptions.first);
      }
    }
    _recordWatermark(
      runtime,
      released.isEmpty ? baseline : released.last.sequence!,
    );
    if (released.isNotEmpty) {
      _committedRecoveryEvents[runtime] =
          List<SessionGatewayEvent>.unmodifiable(released);
    }
    _committedRecoveryAuthorities[runtime] = proof;
    return true;
  }

  bool isRecoveryAuthorityCurrent(
    RecoveryProof proof, {
    required int socketGeneration,
    required Object channel,
    required String? replayEpoch,
  }) =>
      identical(_committedRecoveryAuthorities[proof.runtimeSessionId], proof) &&
      proof.wasMintedBy(_recoveryAuthority) &&
      proof.isStructurallyAuthoritative() &&
      proof.socketGeneration == socketGeneration &&
      identical(proof.channelIdentity, channel) &&
      proof.replayEpoch == replayEpoch &&
      !isQuarantined(proof.runtimeSessionId);

  bool canCommitRecovery(
    RecoveryProof proof, {
    required int socketGeneration,
    required Object channel,
    required String? replayEpoch,
  }) {
    final transaction = _recoveryTransactions[proof.runtimeSessionId];
    if (_resourceOverflowed ||
        transaction == null ||
        transaction.poisoned ||
        !_outstandingRecoveryProofs.contains(proof) ||
        !proof.wasMintedBy(_recoveryAuthority) ||
        !identical(proof.transactionIdentity, transaction.identity) ||
        !proof.isStructurallyAuthoritative() ||
        proof.socketGeneration != socketGeneration ||
        proof.replayEpoch != replayEpoch ||
        !identical(proof.channelIdentity, channel) ||
        transaction.socketGeneration != socketGeneration ||
        transaction.replayEpoch != replayEpoch ||
        (transaction.channel != null &&
            !identical(transaction.channel, channel)) ||
        transaction.connectionId != proof.connectionId ||
        transaction.durableSessionId != proof.durableSessionId ||
        transaction.profile != proof.profile ||
        transaction.bindGeneration != proof.bindGeneration ||
        transaction.sessionGeneration != proof.sessionGeneration ||
        transaction.turnGeneration != proof.turnGeneration ||
        !isQuarantined(proof.runtimeSessionId) ||
        proof.postSnapshotSequence == null ||
        proof.postSnapshotSequence! <= 0) {
      return false;
    }
    final baseline = proof.postSnapshotSequence!;
    var expected = baseline + 1;
    for (final event in transaction.held) {
      final sequence = event.sequence;
      if (sequence == null) return false;
      if (sequence <= baseline) continue;
      if (sequence != expected) return false;
      expected += 1;
    }
    return true;
  }

  _RecoveryTransaction? _recoveryTransactionFor(
    String runtime, {
    int? socketGeneration,
    Object? channel,
    String? replayEpoch,
  }) {
    final existing = _recoveryTransactions[runtime];
    if (existing != null) return existing;
    final known = <String>{
      ..._quarantine,
      ..._watermarks.keys,
      ..._transactions.keys,
      ..._recoveryTransactions.keys,
    };
    if (!known.contains(runtime) && known.length >= maxTrackedRuntimes) {
      _poisonAllForResourceOverflow();
      return null;
    }
    final transaction = _RecoveryTransaction(
      runtime: runtime,
      socketGeneration: socketGeneration,
      channel: channel,
      replayEpoch: replayEpoch,
    );
    _recoveryTransactions[runtime] = transaction;
    return transaction;
  }

  void _poisonWireMismatches({
    required int generation,
    required Object channel,
    required String epoch,
  }) {
    for (final transaction in _recoveryTransactions.values.toList()) {
      if ((transaction.socketGeneration != null &&
              transaction.socketGeneration != generation) ||
          (transaction.channel != null &&
              !identical(transaction.channel, channel)) ||
          (transaction.replayEpoch != null &&
              transaction.replayEpoch != epoch)) {
        _poisonRecovery(transaction);
      }
    }
  }

  void _poisonRecovery(_RecoveryTransaction transaction) {
    if (!transaction.poisoned) {
      _totalHeldEvents -= transaction.held.length;
      transaction.held.clear();
      transaction.poisoned = true;
    }
    _committedRecoveryEvents.remove(transaction.runtime);
    _committedRecoveryAuthorities.remove(transaction.runtime);
    _outstandingRecoveryProofs.removeWhere(
      (proof) => proof.runtimeSessionId == transaction.runtime,
    );
    _quarantine.add(transaction.runtime);
  }

  void _poisonAllForResourceOverflow() {
    _resourceOverflowed = true;
    _quarantineAll = true;
    _quarantine.clear();
    _recoveryExceptions.clear();
    _watermarks.clear();
    for (final transaction in _transactions.values) {
      transaction.held.clear();
      transaction.closed = true;
    }
    _transactions.clear();
    for (final transaction in _recoveryTransactions.values) {
      transaction.held.clear();
      transaction.poisoned = true;
    }
    _recoveryTransactions.clear();
    _outstandingRecoveryProofs.clear();
    _committedRecoveryEvents.clear();
    _committedRecoveryAuthorities.clear();
    _totalHeldEvents = 0;
  }

  void _recordWatermark(String runtime, int sequence) {
    _watermarks.remove(runtime);
    if (_watermarks.length >= maxTrackedRuntimes) {
      _poisonAllForResourceOverflow();
      return;
    }
    if (isQuarantined(runtime)) return;
    _watermarks[runtime] = sequence;
  }
}
