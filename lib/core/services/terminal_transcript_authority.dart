import '../utils/chat_turn.dart';

enum TerminalAuthorityKind {
  authoritativeSuccess,
  authoritativeFailure,
  incompleteAwaitingAssistant,
  malformed,
  stale,
}

enum TerminalAuthorityReason {
  staleAuthorityFence,
  compactionFence,
  missingExpectedUser,
  conflictingIdentity,
  duplicateIdentity,
  invalidRole,
  malformedToolCalls,
  malformedToolCall,
  conflictingToolLink,
  orphanToolLink,
  explicitTransportError,
  durableAssistantError,
  finalAssistant,
  openToolInvocation,
  legacyDirectTool,
  incompleteEvidence,
}

enum TerminalEvidenceSource {
  durableTranscript,
  desktopSnapshot,
  liveTransport,
}

final class TerminalAuthorityDecision {
  const TerminalAuthorityDecision({
    required this.kind,
    required this.reason,
    required this.latestUserIndex,
    this.assistantText,
    required this.mayReplaceVisibleProjection,
    required this.mayPublishDone,
    required this.mayDrainQueue,
    required this.needsRecovery,
  });

  final TerminalAuthorityKind kind;
  final TerminalAuthorityReason reason;
  final int latestUserIndex;
  final String? assistantText;
  final bool mayReplaceVisibleProjection;
  final bool mayPublishDone;
  final bool mayDrainQueue;
  final bool needsRecovery;

  bool get isAuthoritative =>
      kind == TerminalAuthorityKind.authoritativeSuccess ||
      kind == TerminalAuthorityKind.authoritativeFailure;
}

TerminalAuthorityDecision decideTerminalAuthority({
  required List<Map<String, dynamic>> chronological,
  required int expectedUsers,
  required TerminalEvidenceSource source,
  required bool sourceTranscriptComplete,
  required bool transportTerminalObserved,
  required bool transportTerminalIsError,
  required bool compactionFenceActive,
  required bool currentAuthorityFence,
  required bool visibleAssistantTextPresent,
  required bool allowLegacyDirectToolTerminal,
}) {
  TerminalAuthorityDecision decision(
    TerminalAuthorityKind kind,
    TerminalAuthorityReason reason, {
    int latestUserIndex = -1,
    String? assistantText,
    bool mayReplace = false,
    bool needsRecovery = false,
  }) {
    final publishable = kind == TerminalAuthorityKind.authoritativeSuccess;
    return TerminalAuthorityDecision(
      kind: kind,
      reason: reason,
      latestUserIndex: latestUserIndex,
      assistantText: assistantText,
      mayReplaceVisibleProjection: mayReplace,
      mayPublishDone: publishable,
      mayDrainQueue: publishable,
      needsRecovery: needsRecovery,
    );
  }

  // Causal authority is checked before content. Stale bytes cannot regain
  // authority by looking structurally convincing.
  if (!currentAuthorityFence) {
    return decision(
      TerminalAuthorityKind.stale,
      TerminalAuthorityReason.staleAuthorityFence,
    );
  }
  if (compactionFenceActive) {
    return decision(
      TerminalAuthorityKind.stale,
      TerminalAuthorityReason.compactionFence,
    );
  }

  var userCount = 0;
  var latestUserIndex = -1;
  for (var index = 0; index < chronological.length; index++) {
    if (isRealUserTurn(chronological[index])) {
      userCount++;
      latestUserIndex = index;
    }
  }
  if (expectedUsers <= 0 || userCount < expectedUsers || latestUserIndex < 0) {
    return decision(
      TerminalAuthorityKind.malformed,
      TerminalAuthorityReason.missingExpectedUser,
      latestUserIndex: latestUserIndex,
    );
  }

  final seenMessageIds = <String>{};
  final seenRowIds = <int>{};
  for (final message in chronological) {
    if (!transcriptIdentityAliasesAreConsistent(message)) {
      return decision(
        TerminalAuthorityKind.malformed,
        TerminalAuthorityReason.conflictingIdentity,
        latestUserIndex: latestUserIndex,
      );
    }
    final identity = canonicalTranscriptIdentity(message);
    final messageId = identity?.messageId;
    if (messageId != null && !seenMessageIds.add(messageId)) {
      return decision(
        TerminalAuthorityKind.malformed,
        TerminalAuthorityReason.duplicateIdentity,
        latestUserIndex: latestUserIndex,
      );
    }
    final rowId = identity?.rowId;
    if (rowId != null && !seenRowIds.add(rowId)) {
      return decision(
        TerminalAuthorityKind.malformed,
        TerminalAuthorityReason.duplicateIdentity,
        latestUserIndex: latestUserIndex,
      );
    }
  }

  final tail = chronological.sublist(latestUserIndex + 1);
  final declaredCallIds = <String>{};
  var sawAssistantMarker = false;
  var sawOpenInvocation = false;
  var sawDirectToolCandidate = false;
  Map<String, dynamic>? directTool;
  String? finalAssistantText;

  // Structural integrity is global and precedes every terminal interpretation.
  for (final message in tail) {
    final role = message['role'];
    if (role is! String ||
        !const {'assistant', 'assistant_error', 'tool'}.contains(role)) {
      return decision(
        TerminalAuthorityKind.malformed,
        TerminalAuthorityReason.invalidRole,
        latestUserIndex: latestUserIndex,
      );
    }
    if (role == 'assistant' || role == 'assistant_error') {
      sawAssistantMarker = true;
      final rawCalls = message['tool_calls'];
      if (rawCalls != null && rawCalls is! List) {
        return decision(
          TerminalAuthorityKind.malformed,
          TerminalAuthorityReason.malformedToolCalls,
          latestUserIndex: latestUserIndex,
        );
      }
      if (rawCalls is List && rawCalls.isNotEmpty) {
        for (final rawCall in rawCalls) {
          if (rawCall is! Map) {
            return decision(
              TerminalAuthorityKind.malformed,
              TerminalAuthorityReason.malformedToolCall,
              latestUserIndex: latestUserIndex,
            );
          }
          final id = rawCall['id'];
          final function = rawCall['function'];
          final directName = rawCall['name'];
          final functionName = function is Map ? function['name'] : null;
          final name = directName is String ? directName : functionName;
          if (id is! String ||
              id.trim().isEmpty ||
              name is! String ||
              name.trim().isEmpty ||
              !declaredCallIds.add(id)) {
            return decision(
              TerminalAuthorityKind.malformed,
              TerminalAuthorityReason.malformedToolCall,
              latestUserIndex: latestUserIndex,
            );
          }
        }
        sawOpenInvocation = true;
        finalAssistantText = null;
      } else if (role == 'assistant') {
        final content = message['content'];
        if (content is String && content.trim().isNotEmpty) {
          finalAssistantText = content.trim();
          sawOpenInvocation = false;
        }
      }
      continue;
    }

    final linked = message['tool_call_id'] ?? message['call_id'];
    final linkedId = linked is String ? linked.trim() : '';
    if (linked != null && (linked is! String || linkedId.isEmpty)) {
      return decision(
        TerminalAuthorityKind.malformed,
        TerminalAuthorityReason.orphanToolLink,
        latestUserIndex: latestUserIndex,
      );
    }
    if (sawOpenInvocation) {
      if (linkedId.isNotEmpty && !declaredCallIds.contains(linkedId)) {
        return decision(
          TerminalAuthorityKind.malformed,
          TerminalAuthorityReason.conflictingToolLink,
          latestUserIndex: latestUserIndex,
        );
      }
      continue;
    }
    if (linkedId.isNotEmpty) {
      return decision(
        TerminalAuthorityKind.malformed,
        TerminalAuthorityReason.orphanToolLink,
        latestUserIndex: latestUserIndex,
      );
    }
    if (!sawAssistantMarker) {
      sawDirectToolCandidate = true;
      directTool = message;
    }
  }

  if (transportTerminalObserved && transportTerminalIsError) {
    return decision(
      TerminalAuthorityKind.authoritativeFailure,
      TerminalAuthorityReason.explicitTransportError,
      latestUserIndex: latestUserIndex,
    );
  }
  for (final message in tail.reversed) {
    if (message['role'] == 'assistant_error') {
      return decision(
        TerminalAuthorityKind.authoritativeFailure,
        TerminalAuthorityReason.durableAssistantError,
        latestUserIndex: latestUserIndex,
      );
    }
  }

  if (finalAssistantText != null && !sawOpenInvocation) {
    final completeEnough =
        sourceTranscriptComplete ||
        canonicalTranscriptIdentity(chronological[latestUserIndex]) != null;
    if (completeEnough) {
      return decision(
        TerminalAuthorityKind.authoritativeSuccess,
        TerminalAuthorityReason.finalAssistant,
        latestUserIndex: latestUserIndex,
        assistantText: finalAssistantText,
        mayReplace: sourceTranscriptComplete || !visibleAssistantTextPresent,
      );
    }
  }

  if (sawOpenInvocation) {
    return decision(
      TerminalAuthorityKind.incompleteAwaitingAssistant,
      TerminalAuthorityReason.openToolInvocation,
      latestUserIndex: latestUserIndex,
      needsRecovery: transportTerminalObserved,
    );
  }

  if (sawDirectToolCandidate && directTool != null) {
    final userIdentity = canonicalTranscriptIdentity(
      chronological[latestUserIndex],
    );
    final toolIdentity = canonicalTranscriptIdentity(directTool);
    final name = (directTool['name'] ?? directTool['tool_name']);
    final content = directTool['content'];
    final durableSource =
        source == TerminalEvidenceSource.durableTranscript ||
        source == TerminalEvidenceSource.desktopSnapshot;
    final validLegacy =
        allowLegacyDirectToolTerminal &&
        sourceTranscriptComplete &&
        durableSource &&
        userIdentity != null &&
        toolIdentity != null &&
        name is String &&
        name.trim().isNotEmpty &&
        content is String &&
        content.trim().isNotEmpty;
    if (validLegacy) {
      return decision(
        TerminalAuthorityKind.authoritativeSuccess,
        TerminalAuthorityReason.legacyDirectTool,
        latestUserIndex: latestUserIndex,
        mayReplace: !visibleAssistantTextPresent,
      );
    }
    final identitiesMissing = userIdentity == null || toolIdentity == null;
    return decision(
      identitiesMissing
          ? TerminalAuthorityKind.malformed
          : TerminalAuthorityKind.incompleteAwaitingAssistant,
      TerminalAuthorityReason.incompleteEvidence,
      latestUserIndex: latestUserIndex,
      needsRecovery: transportTerminalObserved,
    );
  }

  return decision(
    TerminalAuthorityKind.incompleteAwaitingAssistant,
    TerminalAuthorityReason.incompleteEvidence,
    latestUserIndex: latestUserIndex,
    needsRecovery: transportTerminalObserved,
  );
}
