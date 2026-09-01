import 'dart:convert';

import '../models/subagent_activity.dart';
import '../utils/chat_turn.dart';
import 'subagent_activity_reducer.dart';

final class SubagentTranscriptProjection {
  final String? turnAnchor;
  final SubagentActivityState? state;

  const SubagentTranscriptProjection({
    required this.turnAnchor,
    required this.state,
  });
}

SubagentTranscriptProjection projectSubagentsFromTranscript({
  required List<Map<String, dynamic>> messagesNewestFirst,
  required SubagentActivityScope scope,
  SubagentActivityState? current,
  String? currentTurnAnchor,
}) {
  final chronological = messagesNewestFirst.reversed
      .map(Map<String, dynamic>.from)
      .toList(growable: false);
  var startIndex = -1;
  String? turnAnchor;
  for (var index = 0; index < chronological.length; index += 1) {
    final message = chronological[index];
    if (!isRealUserTurn(message)) continue;
    startIndex = index;
    turnAnchor = _messageIdentity(message);
  }
  if (startIndex < 0 || turnAnchor == null) {
    return SubagentTranscriptProjection(turnAnchor: null, state: current);
  }

  final currentBelongsToTurn =
      current != null &&
      current.scope == scope &&
      (currentTurnAnchor == null ||
          _messageIdentitiesMatch(currentTurnAnchor, turnAnchor));
  var state = currentBelongsToTurn
      ? current
      : SubagentActivityState.empty(scope);
  final delegateNamesByCallId = <String, String>{};
  var observed = false;

  for (final message in chronological.skip(startIndex + 1)) {
    final role = (message['role'] ?? '').toString().trim().toLowerCase();
    if (role == 'assistant') {
      final toolCalls = _list(message['tool_calls']);
      for (final rawCall in toolCalls) {
        final call = _map(rawCall);
        final function = _map(call?['function']);
        final name = _normalizedToolName(
          function?['name'] ?? call?['name'] ?? message['tool_name'],
        );
        final callId = _opaque(call?['id'] ?? call?['tool_call_id']);
        if (name != 'delegate_task' || callId == null) continue;
        delegateNamesByCallId[callId] = 'delegate_task';
        final event = SubagentActivityEvent.tryParseLegacyDelegateTool(
          type: 'tool.start',
          scope: scope,
          payload: {'name': 'delegate_task', 'tool_id': callId},
          toolName: 'delegate_task',
          toolCallId: callId,
          eventId: _eventIdentity(message, 'delegate-start', callId),
        );
        if (event == null) continue;
        state = SubagentActivityReducer.reduce(state, event);
        observed = true;
      }
      continue;
    }

    if (_isToolRole(role)) {
      final callId = _opaque(
        message['tool_call_id'] ?? message['tool_id'] ?? message['call_id'],
      );
      final name =
          _normalizedToolName(message['tool_name']) ??
          (callId == null ? null : delegateNamesByCallId[callId]);
      if (name != 'delegate_task' || callId == null) continue;
      final result = _decodedMap(message['content']);
      final event = SubagentActivityEvent.tryParseLegacyDelegateTool(
        type: 'tool.complete',
        scope: scope,
        payload: {'name': name, 'tool_id': callId, 'result': ?result},
        toolName: name,
        toolCallId: callId,
        eventId: _eventIdentity(message, 'delegate-complete', callId),
      );
      if (event == null) continue;
      state = SubagentActivityReducer.reduce(state, event);
      observed = true;
      continue;
    }

    if (effectiveUserDisplayKind(message) == 'async_delegation_complete') {
      final metadata = _decodedMap(message['display_metadata']);
      final delegationId = _opaque(metadata?['delegation_id']);
      if (delegationId == null) continue;
      final failedCount = _nonNegativeInt(metadata?['failed_count']) ?? 0;
      final event = SubagentActivityEvent.tryParseNative(
        type: 'subagent.complete',
        scope: scope,
        payload: {
          'delegation_id': delegationId,
          'status': failedCount > 0 ? 'failed' : 'completed',
          'task_count': _positiveInt(metadata?['task_count']),
          'duration_seconds': metadata?['duration_seconds'],
        },
        eventId: _eventIdentity(message, 'delegation-complete', delegationId),
      );
      if (event == null) continue;
      state = SubagentActivityReducer.reduce(state, event);
      observed = true;
    }
  }

  return SubagentTranscriptProjection(
    turnAnchor: turnAnchor,
    state: observed || currentBelongsToTurn ? state : null,
  );
}

bool _isToolRole(String role) =>
    const {'tool', 'tool_result', 'function', 'function_call'}.contains(role);

String? _normalizedToolName(Object? value) {
  final text = value?.toString().trim().toLowerCase() ?? '';
  if (text.isEmpty) return null;
  return text.split('.').last;
}

String? _opaque(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text.length > 180) return null;
  return RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(text) ? text : null;
}

String? _messageIdentity(Map<String, dynamic> message) {
  final identity = canonicalTranscriptIdentity(message);
  if (identity?.messageId != null && identity?.rowId != null) {
    return 'pair:${jsonEncode([identity!.messageId, identity.rowId])}';
  }
  if (identity?.messageId != null) return 'canonical:${identity!.messageId}';
  if (identity?.rowId != null) return 'row:${identity!.rowId}';
  final platform = message['platform_message_id'];
  if (platform != null) {
    final value = platform.toString();
    if (value.isNotEmpty && value.length <= 180) return 'platform:$value';
  }
  return null;
}

TranscriptMessageIdentity? _typedMessageIdentity(String value) {
  if (value.startsWith('canonical:')) {
    final messageId = value.substring('canonical:'.length);
    return messageId.isEmpty
        ? null
        : TranscriptMessageIdentity(messageId: messageId);
  }
  if (value.startsWith('row:')) {
    final rowId = int.tryParse(value.substring('row:'.length));
    return rowId == null || rowId <= 0
        ? null
        : TranscriptMessageIdentity(rowId: rowId);
  }
  if (!value.startsWith('pair:')) return null;
  try {
    final decoded = jsonDecode(value.substring('pair:'.length));
    if (decoded is! List || decoded.length != 2) return null;
    final messageId = decoded[0];
    final rowId = decoded[1];
    if (messageId is! String ||
        messageId.isEmpty ||
        rowId is! int ||
        rowId <= 0) {
      return null;
    }
    return TranscriptMessageIdentity(messageId: messageId, rowId: rowId);
  } catch (_) {
    return null;
  }
}

bool _messageIdentitiesMatch(String left, String right) {
  if (left == right) return true;
  final leftIdentity = _typedMessageIdentity(left);
  final rightIdentity = _typedMessageIdentity(right);
  return leftIdentity != null &&
      rightIdentity != null &&
      leftIdentity.matches(rightIdentity);
}

String _eventIdentity(
  Map<String, dynamic> message,
  String kind,
  String stableId,
) {
  final identity = canonicalTranscriptIdentity(message);
  final row = identity?.rowId != null
      ? 'row:${identity!.rowId}'
      : identity?.messageId != null
      ? 'canonical:${identity!.messageId}'
      : _messageIdentity(message) ?? 'unknown';
  return 'transcript:$row:$kind:$stableId';
}

List<Object?> _list(Object? value) {
  if (value is List) return value;
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      return decoded is List ? decoded : const [];
    } catch (_) {
      return const [];
    }
  }
  return const [];
}

Map<String, dynamic>? _map(Object? value) {
  if (value is! Map) return null;
  return value.map((key, item) => MapEntry(key.toString(), item));
}

Map<String, dynamic>? _decodedMap(Object? value) {
  final direct = _map(value);
  if (direct != null) return direct;
  if (value is! String || value.trim().isEmpty) return null;
  try {
    return _map(jsonDecode(value));
  } catch (_) {
    return null;
  }
}

int? _nonNegativeInt(Object? value) {
  final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
  return parsed != null && parsed >= 0 ? parsed : null;
}

int? _positiveInt(Object? value) {
  final parsed = _nonNegativeInt(value);
  return parsed != null && parsed > 0 ? parsed : null;
}
