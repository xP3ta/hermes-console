import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'approval_policy.dart';

/// An acknowledgement applies only to the exact request the user saw.
/// Transport errors remain exceptions; ignored authority changes are explicit.
enum ApprovalSendResult { accepted, ignored, error }

final class ApprovalTarget {
  const ApprovalTarget(this.requestId, this.commandHash);

  factory ApprovalTarget.of(Map<String, dynamic> approval) {
    final choices = permittedApprovalChoices(approval).toList()..sort();
    return ApprovalTarget(
      (approval['request_id'] ?? approval['approval_id'] ?? '')
          .toString()
          .trim(),
      sha256
          .convert(
            utf8.encode(
              jsonEncode([
                // Hash the sources of the displayed command and scope, before redaction:
                // changing a hidden credential must also invalidate an old decision.
                (approval['command'] ?? approval['code'] ?? '').toString(),
                (approval['description'] ?? '').toString(),
                (approval['tool'] ?? '').toString(),
                (approval['pattern_key'] ?? '').toString(),
                choices,
              ]),
            ),
          )
          .toString(),
    );
  }

  final String requestId;
  final String commandHash;

  bool matches(Map<String, dynamic>? approval) =>
      requestId.isNotEmpty &&
      approval != null &&
      this == ApprovalTarget.of(approval);

  @override
  bool operator ==(Object other) =>
      other is ApprovalTarget &&
      requestId == other.requestId &&
      commandHash == other.commandHash;

  @override
  int get hashCode => Object.hash(requestId, commandHash);
}

final class ApprovalSubmission {
  const ApprovalSubmission(this.target, this.choice);
  final ApprovalTarget target;
  final String choice;
}
