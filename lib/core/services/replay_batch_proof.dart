import 'json_rpc_wire.dart';

sealed class ReplayBatchDecision {
  const ReplayBatchDecision();
}

final class ReplayBatchCommit extends ReplayBatchDecision {
  final List<SessionGatewayEvent> replay;
  final List<SessionGatewayEvent> held;
  final int newWatermark;

  const ReplayBatchCommit(this.replay, this.held, this.newWatermark);
}

final class ReplayBatchQuarantine extends ReplayBatchDecision {
  final String reason;
  final bool recoveryRequired;

  const ReplayBatchQuarantine(this.reason, {this.recoveryRequired = true});
}

final class ReplayBatchRetireTransport extends ReplayBatchDecision {
  final String reason;

  const ReplayBatchRetireTransport(this.reason);
}

abstract final class ReplayBatchProof {
  static ReplayBatchDecision validate({
    required String runtime,
    required String epoch,
    required int lastSeen,
    required Object? result,
    required List<SessionGatewayEvent> held,
  }) {
    if (runtime.isEmpty ||
        runtime != runtime.trim() ||
        epoch.isEmpty ||
        epoch != epoch.trim()) {
      return const ReplayBatchRetireTransport(
        'invalid captured replay authority',
      );
    }
    if (result is! Map<String, dynamic>) {
      return const ReplayBatchQuarantine('invalid replay result shape');
    }
    final rawEpoch = result['epoch'];
    final truncated = result['truncated'];
    final rawEvents = result['events'];
    if (rawEpoch is! String ||
        rawEpoch.isEmpty ||
        rawEpoch != rawEpoch.trim() ||
        truncated is! bool ||
        rawEvents is! List<dynamic> ||
        !result.containsKey('latest_seq')) {
      return const ReplayBatchQuarantine('incomplete replay proof');
    }
    if (rawEpoch != epoch) {
      return const ReplayBatchQuarantine('replay epoch mismatch');
    }
    int latest;
    try {
      latest = SafeJsonInt.require(result['latest_seq'], positive: true);
    } on JsonRpcWireFormatException {
      return const ReplayBatchQuarantine('invalid latest sequence');
    }
    if (latest < lastSeen) {
      return const ReplayBatchQuarantine('stale latest sequence');
    }
    if (result.containsKey('count')) {
      int count;
      try {
        count = SafeJsonInt.require(result['count'], nonNegative: true);
      } on JsonRpcWireFormatException {
        return const ReplayBatchQuarantine('invalid replay count');
      }
      if (count != rawEvents.length) {
        return const ReplayBatchQuarantine('replay count mismatch');
      }
    }
    if (truncated) {
      return const ReplayBatchQuarantine('replay truncated');
    }

    final replay = <SessionGatewayEvent>[];
    var expected = lastSeen + 1;
    for (final rawRow in rawEvents) {
      if (rawRow is! Map<String, dynamic>) {
        return const ReplayBatchQuarantine('invalid replay row');
      }
      try {
        final parsed = EventEnvelopeParser.parse(
          rawRow,
          replayCapable: true,
          requiredReplaySessionId: runtime,
        );
        if (parsed is! SessionGatewayEvent || parsed.sequence != expected) {
          return const ReplayBatchQuarantine('non-contiguous replay rows');
        }
        replay.add(parsed);
        expected += 1;
      } on JsonRpcWireFormatException {
        return const ReplayBatchQuarantine('invalid replay event');
      }
    }
    if (expected - 1 != latest) {
      return const ReplayBatchQuarantine('latest sequence gap');
    }

    final acceptedHeld = <SessionGatewayEvent>[];
    var heldExpected = latest + 1;
    for (final event in held) {
      if (event.sessionId != runtime) {
        return const ReplayBatchQuarantine('held runtime mismatch');
      }
      final sequence = event.sequence!;
      if (sequence <= lastSeen) continue;
      if (sequence <= latest) {
        final replayEvent = replay[sequence - lastSeen - 1];
        if (!sameEvent(replayEvent, event)) {
          return const ReplayBatchQuarantine('conflicting replay overlap');
        }
        continue;
      }
      if (sequence != heldExpected) {
        return const ReplayBatchQuarantine('non-contiguous held tail');
      }
      acceptedHeld.add(event);
      heldExpected += 1;
    }
    return ReplayBatchCommit(
      List<SessionGatewayEvent>.unmodifiable(replay),
      List<SessionGatewayEvent>.unmodifiable(acceptedHeld),
      heldExpected - 1,
    );
  }

  static bool sameEvent(SessionGatewayEvent left, SessionGatewayEvent right) =>
      left.type == right.type &&
      left.sessionId == right.sessionId &&
      left.sequence == right.sequence &&
      _deepEqual(left.payload, right.payload);

  static bool _deepEqual(Object? left, Object? right) {
    if (identical(left, right) || left == right) return true;
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var i = 0; i < left.length; i++) {
        if (!_deepEqual(left[i], right[i])) return false;
      }
      return true;
    }
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      for (final key in left.keys) {
        if (!right.containsKey(key) || !_deepEqual(left[key], right[key])) {
          return false;
        }
      }
      return true;
    }
    return false;
  }
}
