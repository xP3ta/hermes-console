import 'desktop_compression_result.dart';

/// Knowledge of this operation, independent of visual generation.
enum DesktopCompressionOutcome {
  notDispatched,
  routeUnavailable,
  terminalRejected,
  ownershipLost,
  lockHeld,
  acceptedPending,
  ambiguous,
  settled;

  bool get resolvesAttempt =>
      this == notDispatched ||
      this == terminalRejected ||
      this == lockHeld ||
      this == settled;
}

enum CompressionFailureOrigin { unknown, localPreflight, remoteRpc, malformed }

enum CompressionFailureReason {
  unknown,
  sessionNotOwned,
  exclusiveSubmitCapabilityDenied,
}

enum LegacyCompressionShape { unknown, outputOnly, exec, other, invalid }

enum LegacyCompressionStatus { absent, pending, other, invalid }

enum LegacyCompressionAcceptance { absent, accepted, rejected, invalid }

/// Bounded protocol evidence from a raw legacy command response.
/// Presentation text is deliberately excluded from authority decisions.
final class DesktopCompressionLegacyEvidence {
  final LegacyCompressionShape shape;
  final LegacyCompressionStatus status;
  final LegacyCompressionAcceptance acceptance;

  const DesktopCompressionLegacyEvidence({
    required this.shape,
    required this.status,
    required this.acceptance,
  });
  const DesktopCompressionLegacyEvidence.unknown()
    : shape = LegacyCompressionShape.unknown,
      status = LegacyCompressionStatus.absent,
      acceptance = LegacyCompressionAcceptance.absent;

  factory DesktopCompressionLegacyEvidence.fromWire(Object? value) {
    if (value is! Map) {
      return const DesktopCompressionLegacyEvidence(
        shape: LegacyCompressionShape.invalid,
        status: LegacyCompressionStatus.invalid,
        acceptance: LegacyCompressionAcceptance.invalid,
      );
    }
    final type = value['type'];
    final output = value['output'];
    final shape = type == null
        ? (output is String
              ? LegacyCompressionShape.outputOnly
              : output == null
              ? LegacyCompressionShape.unknown
              : LegacyCompressionShape.invalid)
        : type is! String
        ? LegacyCompressionShape.invalid
        : type.trim().toLowerCase() == 'exec'
        ? LegacyCompressionShape.exec
        : LegacyCompressionShape.other;
    final rawStatus = value['status'];
    final status = rawStatus == null
        ? LegacyCompressionStatus.absent
        : rawStatus is! String
        ? LegacyCompressionStatus.invalid
        : rawStatus.trim().toLowerCase() == 'pending'
        ? LegacyCompressionStatus.pending
        : LegacyCompressionStatus.other;
    final rawAccepted = value['accepted'];
    final acceptance = rawAccepted == null
        ? LegacyCompressionAcceptance.absent
        : rawAccepted is! bool
        ? LegacyCompressionAcceptance.invalid
        : rawAccepted
        ? LegacyCompressionAcceptance.accepted
        : LegacyCompressionAcceptance.rejected;
    return DesktopCompressionLegacyEvidence(
      shape: shape,
      status: status,
      acceptance: acceptance,
    );
  }

  DesktopCompressionOutcome get outcome {
    if (shape == LegacyCompressionShape.invalid ||
        shape == LegacyCompressionShape.other ||
        status == LegacyCompressionStatus.invalid ||
        status == LegacyCompressionStatus.other ||
        acceptance == LegacyCompressionAcceptance.invalid) {
      return DesktopCompressionOutcome.ambiguous;
    }
    if (acceptance == LegacyCompressionAcceptance.rejected) {
      return DesktopCompressionOutcome.ambiguous;
    }
    if (status == LegacyCompressionStatus.pending ||
        shape == LegacyCompressionShape.exec ||
        shape == LegacyCompressionShape.outputOnly ||
        acceptance == LegacyCompressionAcceptance.accepted) {
      return DesktopCompressionOutcome.acceptedPending;
    }
    return DesktopCompressionOutcome.ambiguous;
  }
}

final class DesktopCompressionEvidence {
  final DesktopCompressionOutcome outcome;
  final DesktopCompressionResult? nativeResult;
  const DesktopCompressionEvidence(this.outcome, {this.nativeResult});
}
