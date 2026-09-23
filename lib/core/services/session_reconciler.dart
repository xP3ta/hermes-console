import 'dart:convert';

import '../models/activity_snapshot.dart' show activityToolDetail;
import '../models/desktop_session_snapshot.dart';
import '../models/transcript_privacy_state.dart';
import '../utils/assistant_content.dart';
import '../utils/chat_turn.dart';
import 'terminal_transcript_authority.dart';

final _unsafeDisplayTextPattern = RegExp(
  '[\\x00-\\x1f\\x7f'
  '${String.fromCharCode(0x2028)}${String.fromCharCode(0x2029)}'
  '${String.fromCharCode(0x202a)}-${String.fromCharCode(0x202e)}'
  '${String.fromCharCode(0x2066)}-${String.fromCharCode(0x2069)}]',
);

/// Pure projection of a Hermes Desktop 0.19 resume/activate snapshot into the
/// newest-first message shape consumed by [ActiveChat].
///
/// This class performs no I/O and deliberately carries no raw gateway payload.
/// `queued` remains a singleton: Hermes may merge multiple steer inputs with
/// two newlines, which is still one remotely queued prompt.
class DesktopSessionProjection {
  final List<Map<String, dynamic>> messagesNewestFirst;
  final String? queuedUser;
  final String? queuedSyntheticId;
  final bool running;
  final bool failed;
  final String? status;

  const DesktopSessionProjection({
    required this.messagesNewestFirst,
    required this.running,
    this.failed = false,
    this.queuedUser,
    this.queuedSyntheticId,
    this.status,
  });
}

const assistantActivityTraceKey = '_activity_trace';
const assistantToolResultEvidenceKey = '_activity_tool_results';

Map<String, dynamic>? normalizeAssistantActivityStep(Object? raw) {
  if (raw is! Map) return null;
  final kind = raw['kind']?.toString().trim().toLowerCase();
  if (kind == 'reasoning') {
    final text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    return Map<String, dynamic>.unmodifiable({
      'kind': 'reasoning',
      'text': text,
      'status': raw['status'] == 'running' ? 'running' : 'completed',
      if (raw['timestamp'] is num) 'timestamp': raw['timestamp'],
    });
  }
  if (kind != 'tool' && kind != 'skill') return null;
  final label = raw['label']?.toString().trim() ?? '';
  if (label.isEmpty ||
      label.length > 180 ||
      label.contains(_unsafeDisplayTextPattern)) {
    return null;
  }
  final id = raw['id']?.toString().trim();
  final status = switch (raw['status']?.toString().trim().toLowerCase()) {
    'running' => 'running',
    'failed' || 'error' => 'failed',
    _ => 'completed',
  };
  final rawDetail = raw['detail'];
  final detail = rawDetail is String ? rawDetail.trim() : '';
  return Map<String, dynamic>.unmodifiable({
    'kind': kind,
    'label': label,
    'status': status,
    if (id != null && id.isNotEmpty && id.length <= 180) 'id': id,
    if (raw['timestamp'] is num) 'timestamp': raw['timestamp'],
    if (raw['completed_at'] is num) 'completed_at': raw['completed_at'],
    if (detail.isNotEmpty &&
        detail.length <= 96 &&
        !detail.contains(_unsafeDisplayTextPattern))
      'detail': detail,
  });
}

List<Map<String, dynamic>> normalizeAssistantActivityTrace(Object? raw) {
  if (raw is! List) return const [];
  return List<Map<String, dynamic>>.unmodifiable(
    raw.take(256).map(normalizeAssistantActivityStep).whereType(),
  );
}

/// Una invocación de herramienta tal como debe verse en el historial.
typedef ActivityCallEntry = ({String label, String? id, Object? arguments});

Object? _decodedArguments(Object? raw) {
  if (raw is! String) return raw;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

/// Entradas visibles de una llamada. Hermes puede exponer solo tres
/// herramientas puente (`tool_search`, `tool_describe`, `tool_call`) y llamar a
/// la real dentro de `tool_call({calls:[{name, arguments}]})`: se desenvuelve
/// para que el historial diga «terminal · sleep» y no «tool_call». Si no se
/// puede desenvolver, queda la llamada original (que la vista oculta).
List<ActivityCallEntry> activityCallEntries(
  String label,
  String? id,
  Object? rawArguments,
) {
  final arguments = _decodedArguments(rawArguments);
  if (label.trim().toLowerCase() != 'tool_call' || arguments is! Map) {
    return [(label: label, id: id, arguments: arguments)];
  }
  final calls = arguments['calls'];
  final candidates = calls is List ? calls : [arguments];
  final entries = <ActivityCallEntry>[];
  for (var i = 0; i < candidates.length && i < 32; i++) {
    final candidate = candidates[i];
    if (candidate is! Map) continue;
    final name = candidate['name']?.toString().trim() ?? '';
    if (name.isEmpty ||
        name.length > 180 ||
        name.contains(_unsafeDisplayTextPattern)) {
      continue;
    }
    entries.add((
      label: name,
      id: id == null ? null : '$id:$i',
      arguments: _decodedArguments(candidate['arguments']),
    ));
  }
  return entries.isEmpty
      ? [(label: label, id: id, arguments: arguments)]
      : entries;
}

List<Map<String, dynamic>> assistantActivityFromToolCalls(
  Object? raw, {
  String status = 'running',
  num? timestamp,
}) {
  if (raw is! List) return const [];
  final steps = <Map<String, dynamic>>[];
  for (final value in raw.take(256)) {
    if (value is! Map) continue;
    final function = value['function'];
    final label = function is Map
        ? function['name']?.toString().trim() ?? ''
        : value['name']?.toString().trim() ?? '';
    if (label.isEmpty ||
        label.length > 180 ||
        label.contains(_unsafeDisplayTextPattern)) {
      continue;
    }
    final id = value['id']?.toString().trim();
    final rawKind = value['kind']?.toString().trim().toLowerCase();
    final kind =
        rawKind == 'skill' ||
            value['type']?.toString().trim().toLowerCase() == 'skill'
        ? 'skill'
        : 'tool';
    final rawArguments = function is Map
        ? function['arguments']
        : value['arguments'];
    for (final entry in activityCallEntries(
      label,
      id != null && id.isNotEmpty && id.length <= 180 ? id : null,
      rawArguments,
    )) {
      final step = normalizeAssistantActivityStep({
        'kind': kind,
        'label': entry.label,
        'status': status,
        'id': ?entry.id,
        'timestamp': ?timestamp,
        'detail': ?activityToolDetail(entry.label, entry.arguments),
      });
      if (step != null) steps.add(step);
    }
  }
  return List<Map<String, dynamic>>.unmodifiable(steps);
}

List<Map<String, dynamic>> coalesceAssistantTurnsNewestFirst(
  Iterable<Map<String, dynamic>> messagesNewestFirst,
) {
  final chronological = messagesNewestFirst.toList(growable: false).reversed;
  final result = <Map<String, dynamic>>[];
  Map<String, dynamic>? assistant;
  final textParts = <String>[];
  final reasoningParts = <String>[];
  final activity = <Map<String, dynamic>>[];
  final toolCalls = <Map<String, dynamic>>[];
  final toolResults = <Map<String, dynamic>>[];
  final delegateTaskCallIds = <String>{};

  num? timestampOf(Map<String, dynamic> message) {
    final raw = message['timestamp'];
    return raw is num ? raw : null;
  }

  void appendReasoning(String text, Map<String, dynamic> message) {
    if (text.trim().isEmpty) return;
    reasoningParts.add(text.trim());
    activity.add({
      'kind': 'reasoning',
      'text': text,
      'status': message['_pipeline'] == true ? 'running' : 'completed',
      'timestamp': ?timestampOf(message),
    });
  }

  void appendToolCallEvidence(Map raw) {
    final function = raw['function'];
    final label = function is Map
        ? function['name']?.toString().trim() ?? ''
        : raw['name']?.toString().trim() ?? '';
    if (label.isEmpty ||
        label.length > 180 ||
        label.contains(_unsafeDisplayTextPattern)) {
      return;
    }
    final id = raw['id']?.toString().trim();
    if (id != null &&
        id.isNotEmpty &&
        toolCalls.any((call) => call['id']?.toString() == id)) {
      return;
    }
    toolCalls.add({
      if (id != null && id.isNotEmpty && id.length <= 180) 'id': id,
      'type': 'function',
      'function': {'name': label},
    });
  }

  void appendToolCall(Map raw, Map<String, dynamic> message) {
    final function = raw['function'];
    final label = function is Map
        ? function['name']?.toString().trim() ?? ''
        : raw['name']?.toString().trim() ?? '';
    if (label.isEmpty ||
        label.length > 180 ||
        label.contains(_unsafeDisplayTextPattern)) {
      return;
    }
    final id = raw['id']?.toString().trim();
    if (id != null &&
        id.isNotEmpty &&
        activity.any(
          (step) =>
              (step['kind'] == 'tool' || step['kind'] == 'skill') &&
              step['id']?.toString() == id,
        )) {
      return;
    }
    final rawArguments = function is Map
        ? function['arguments']
        : raw['arguments'];
    final safeId = id != null && id.isNotEmpty && id.length <= 180 ? id : null;
    for (final entry in activityCallEntries(label, safeId, rawArguments)) {
      final detail = activityToolDetail(entry.label, entry.arguments);
      activity.add({
        'kind': 'tool',
        'label': entry.label,
        'status': 'running',
        'id': ?entry.id,
        'timestamp': ?timestampOf(message),
        'detail': ?detail,
      });
    }
    appendToolCallEvidence(raw);
  }

  void completeTool(Map<String, dynamic> message) {
    toolResults.add(message);
    final id = message['tool_call_id']?.toString().trim();
    var index = -1;
    if (id != null && id.isNotEmpty) {
      // También las entradas desenvueltas de una llamada puente (`id:0`, …).
      final endedAt = timestampOf(message);
      var matched = false;
      for (var i = 0; i < activity.length; i++) {
        final step = activity[i];
        final stepId = step['id']?.toString();
        if (step['kind'] != 'tool' ||
            stepId == null ||
            !(stepId == id || stepId.startsWith('$id:'))) {
          continue;
        }
        matched = true;
        activity[i] = {
          ...step,
          'status': 'completed',
          if (endedAt != null && step['completed_at'] == null)
            'completed_at': endedAt,
        };
      }
      if (matched) return;
    }
    if (index < 0) {
      if ((id == null || id.isEmpty) &&
          activity.any(
            (step) =>
                (step['kind'] == 'tool' || step['kind'] == 'skill') &&
                step['status'] == 'running',
          )) {
        return;
      }
      final label =
          message['tool_name']?.toString().trim() ??
          message['name']?.toString().trim() ??
          '';
      if (label.isEmpty ||
          label.length > 180 ||
          label.contains(_unsafeDisplayTextPattern)) {
        return;
      }
      activity.add({
        'kind': 'tool',
        'label': label,
        'status': 'completed',
        if (id != null && id.isNotEmpty && id.length <= 180) 'id': id,
        'timestamp': ?timestampOf(message),
      });
      return;
    }
    activity[index] = {...activity[index], 'status': 'completed'};
  }

  void absorbAssistant(Map<String, dynamic> message) {
    assistant = {...?assistant, ...message};
    final content = message['content'];
    if (content is String && content.trim().isNotEmpty) {
      if (textParts.isEmpty || textParts.last != content) {
        textParts.add(content);
      }
    }
    final existingToolResults = message[assistantToolResultEvidenceKey];
    if (existingToolResults is List) {
      toolResults.addAll(
        existingToolResults.whereType<Map>().map(Map<String, dynamic>.from),
      );
    }

    final existingActivity = normalizeAssistantActivityTrace(
      message[assistantActivityTraceKey],
    );
    if (existingActivity.isNotEmpty) {
      final hasReasoningStep = existingActivity.any(
        (step) => step['kind'] == 'reasoning',
      );
      final reasoning = message['reasoning'];
      if (!hasReasoningStep && reasoning is String) {
        appendReasoning(reasoning, message);
      }
      activity.addAll(existingActivity.map(Map<String, dynamic>.from));
      for (final step in existingActivity) {
        if (step['kind'] == 'reasoning') {
          final text = step['text']?.toString().trim() ?? '';
          if (text.isNotEmpty) reasoningParts.add(text);
        }
      }
      final calls = message['tool_calls'];
      if (calls is List) {
        for (final raw in calls) {
          if (raw is Map) appendToolCallEvidence(raw);
        }
      }
      return;
    }

    final reasoning = message['reasoning'];
    if (reasoning is String) appendReasoning(reasoning, message);
    final calls = message['tool_calls'];
    if (calls is List) {
      for (final raw in calls) {
        if (raw is Map) appendToolCall(raw, message);
      }
    }
  }

  void flushAssistant() {
    final current = assistant;
    if (current == null) return;
    final hasMedia =
        current['_generatedImages'] is List &&
        (current['_generatedImages'] as List).isNotEmpty;
    final keep =
        textParts.isNotEmpty ||
        activity.isNotEmpty ||
        current['_pipeline'] == true ||
        hasMedia;
    if (keep) {
      final merged = <String, dynamic>{
        ...current,
        'content': textParts.join('\n\n'),
      };
      if (reasoningParts.isEmpty) {
        merged.remove('reasoning');
      } else {
        merged['reasoning'] = reasoningParts.join('\n\n');
      }
      if (activity.isEmpty) {
        merged.remove(assistantActivityTraceKey);
      } else {
        merged[assistantActivityTraceKey] =
            List<Map<String, dynamic>>.unmodifiable(
              activity.map((step) => Map<String, dynamic>.unmodifiable(step)),
            );
      }
      if (toolCalls.isEmpty) {
        merged.remove('tool_calls');
      } else {
        merged['tool_calls'] = List<Map<String, dynamic>>.unmodifiable(
          toolCalls.map((call) => Map<String, dynamic>.unmodifiable(call)),
        );
      }
      if (toolResults.isEmpty) {
        merged.remove(assistantToolResultEvidenceKey);
      } else {
        merged[assistantToolResultEvidenceKey] =
            List<Map<String, dynamic>>.unmodifiable(toolResults);
      }
      result.add(merged);
    }
    assistant = null;
    textParts.clear();
    reasoningParts.clear();
    activity.clear();
    toolCalls.clear();
    toolResults.clear();
  }

  for (final message in chronological) {
    final role = message['role']?.toString().trim().toLowerCase() ?? '';
    final displayKind = message['display_kind']?.toString().trim() ?? '';
    if (role == 'assistant' && displayKind.isEmpty) {
      final calls = message['tool_calls'];
      final isDelegateTask =
          calls is List &&
          calls.any((raw) {
            if (raw is! Map) return false;
            final function = raw['function'];
            final name = function is Map ? function['name'] : raw['name'];
            return name?.toString().trim().toLowerCase() == 'delegate_task';
          });
      if (isDelegateTask) {
        for (final raw in calls) {
          if (raw is! Map) continue;
          final function = raw['function'];
          final name = function is Map ? function['name'] : raw['name'];
          if (name?.toString().trim().toLowerCase() != 'delegate_task') {
            continue;
          }
          final id = raw['id']?.toString().trim();
          if (id != null && id.isNotEmpty) delegateTaskCallIds.add(id);
        }
        flushAssistant();
        result.add(Map<String, dynamic>.from(message));
        continue;
      }
      final incomingContent = message['content'];
      final incomingHasText =
          incomingContent is String && incomingContent.trim().isNotEmpty;
      if (assistant != null && textParts.isNotEmpty && incomingHasText) {
        flushAssistant();
      }
      absorbAssistant(message);
      continue;
    }
    if (role == 'tool') {
      final toolName =
          message['tool_name']?.toString().trim().toLowerCase() ??
          message['name']?.toString().trim().toLowerCase() ??
          '';
      final callId = message['tool_call_id']?.toString().trim();
      if (toolName == 'delegate_task' ||
          (callId != null && delegateTaskCallIds.contains(callId))) {
        flushAssistant();
        result.add(Map<String, dynamic>.from(message));
        continue;
      }
      assistant ??= {'role': 'assistant', 'content': ''};
      completeTool(message);
      continue;
    }
    final repeatsOpenTurnInput =
        role == 'user' &&
        message['_desktopSnapshotKind'] == 'inflight' &&
        message['_steer'] != true &&
        assistant != null &&
        textParts.isEmpty &&
        result.isNotEmpty &&
        result.last['role'] == 'user' &&
        result.last['content'] == message['content'];
    if (repeatsOpenTurnInput) continue;
    flushAssistant();
    if (role != 'tool') result.add(Map<String, dynamic>.from(message));
  }
  flushAssistant();

  return result.reversed.toList();
}

enum _LiveUserProjectionProof { none, exactAnchorPrefix, openTurn }

class _LiveUserProjectionPlan {
  final int representedPrefixLength;
  final _LiveUserProjectionProof proof;

  const _LiveUserProjectionPlan({
    required this.representedPrefixLength,
    required this.proof,
  });

  static const none = _LiveUserProjectionPlan(
    representedPrefixLength: 0,
    proof: _LiveUserProjectionProof.none,
  );

  bool emits(int liveUserIndex) =>
      proof == _LiveUserProjectionProof.none ||
      liveUserIndex >= representedPrefixLength;
}

TranscriptMessageIdentity? _desktopTranscriptIdentity(
  DesktopSessionMessage message,
) {
  if (!message.identityAliasesConsistent) return null;
  final identity = TranscriptMessageIdentity(
    messageId: message.stableId,
    rowId: message.rowId,
  );
  return identity.isDurable ? identity : null;
}

class DesktopSessionReconciler {
  const DesktopSessionReconciler();

  static bool _isDurableTerminalAssistant(Map<String, dynamic> message) {
    final role = message['role']?.toString().trim().toLowerCase();
    if (role != 'assistant' && role != 'assistant_error') return false;
    if (message['_desktopSnapshotKind'] == 'inflight' ||
        message['_pipeline'] == true ||
        message['_interim'] == true) {
      return false;
    }
    final isDurable =
        message['_desktopSnapshotKind'] == 'persisted' ||
        canonicalTranscriptMessageId(message) != null ||
        canonicalTranscriptRowId(message) != null;
    if (!isDurable) return false;
    final authority = decideTerminalAuthority(
      chronological: [
        const {
          'message_id': '__desktop_reconciler_terminal_anchor__',
          'role': 'user',
          'content': '',
        },
        message,
      ],
      expectedUsers: 1,
      source: TerminalEvidenceSource.desktopSnapshot,
      sourceTranscriptComplete: true,
      transportTerminalObserved: false,
      transportTerminalIsError: false,
      compactionFenceActive: false,
      currentAuthorityFence: true,
      visibleAssistantTextPresent: false,
      allowLegacyDirectToolTerminal: false,
    );
    return authority.isAuthoritative;
  }

  static bool _isCrossableNonUserLiveProjection(Map<String, dynamic> message) {
    if (message['role'] == 'user') return false;
    return message['_desktopSnapshotKind'] == 'inflight' ||
        message['_pipeline'] == true;
  }

  static bool _isBridgeableOwnedLiveUserProjection(
    Map<String, dynamic> message,
  ) =>
      message['role'] == 'user' &&
      (message['_desktopSnapshotKind'] == 'inflight' ||
          message['_optimistic'] == true ||
          message['_steer'] == true);

  /// Filas durables que el runtime envió como turno sintético (hoy solo el
  /// aviso de proceso en segundo plano). Se limita a ese tipo a propósito: otros
  /// `display_kind` (`model_switch`, `compression_result`…) no son la entrada
  /// del turno en vuelo y, contados aquí, podrían suprimir un mensaje real.
  static bool _isStructuredUserEvent(Map<String, dynamic> message) =>
      message['role'] == 'user' &&
      message['display_kind']?.toString().trim() == 'process_complete';

  static bool _isDurableOpenInput(Map<String, dynamic> message) =>
      isRealUserTurn(message) ||
      (message['role'] == 'user' && message['_steer'] == true) ||
      _isStructuredUserEvent(message);

  static bool _matchesDurableStructuredInput(
    Map<String, dynamic> message,
    String content,
  ) =>
      _isStructuredUserEvent(message) &&
      message['content']?.toString() == content &&
      (message['_desktopSnapshotKind'] == 'persisted' ||
          canonicalTranscriptIdentity(message) != null);

  static int? _exactPreviousAnchorIndex(
    List<Map<String, dynamic>> chronological,
    List<Map<String, dynamic>> previousNewestFirst,
    bool bridgeOwnedLiveUser,
  ) {
    TranscriptMessageIdentity? anchor;
    for (final previous in previousNewestFirst) {
      if (_isCrossableNonUserLiveProjection(previous)) continue;
      if (bridgeOwnedLiveUser &&
          _isBridgeableOwnedLiveUserProjection(previous)) {
        continue;
      }
      anchor = canonicalTranscriptIdentity(previous);
      // Never cross an id-less durable-looking survivor to recover an older
      // anchor: that row could be the unanswered repeated prompt.
      if (anchor == null) return null;
      break;
    }
    if (anchor == null) return null;

    int? matchedIndex;
    for (var index = 0; index < chronological.length; index++) {
      final candidate = chronological[index];
      if (!transcriptIdentityAliasesShareExactCoordinate(candidate, anchor)) {
        continue;
      }
      final candidateIdentity = canonicalTranscriptIdentity(candidate);
      if (candidateIdentity == null || !candidateIdentity.matches(anchor)) {
        return null;
      }
      if (matchedIndex != null) return null;
      matchedIndex = index;
    }
    return matchedIndex;
  }

  static DateTime? _projectedTimestamp(Map<String, dynamic> message) {
    final value = message['timestamp'];
    if (value is! num || !value.isFinite || value < 0) return null;
    try {
      return DateTime.fromMicrosecondsSinceEpoch(
        (value * Duration.microsecondsPerSecond).round(),
      );
    } on RangeError {
      return null;
    }
  }

  static bool _isDurableOpenTurnActivity(Map<String, dynamic> message) {
    final role = message['role']?.toString().trim().toLowerCase();
    if (role != 'assistant' && role != 'tool') return false;
    // Rows that come from the durable history do not always carry an id (the
    // tool-call assistant row of `session.history` has neither `id` nor
    // `message_id` on a real device), so identity cannot be required here.
    // What must be excluded is anything this client synthesised itself.
    if (message['_desktopSnapshotKind'] == 'inflight' ||
        message['_pipeline'] == true ||
        message['_optimistic'] == true ||
        message['_interim'] == true) {
      return false;
    }
    return role == 'tool' || !_isDurableTerminalAssistant(message);
  }

  /// Structural recognition of the open turn when no exact previous anchor can
  /// be proven. It deliberately does NOT depend on the client's previous
  /// projection being empty: reopening mid-turn hydrates several times, and from
  /// the second pass the client already holds its own projection of the same
  /// durable rows, which used to bring the inflight user twin back.
  static _LiveUserProjectionPlan _firstOpenTurnPlan(
    List<Map<String, dynamic>> chronological,
  ) {
    var terminalBoundary = -1;
    for (var index = 0; index < chronological.length; index++) {
      if (_isDurableTerminalAssistant(chronological[index])) {
        terminalBoundary = index;
      }
    }
    final openInputs = <int>[];
    for (
      var index = terminalBoundary + 1;
      index < chronological.length;
      index++
    ) {
      final message = chronological[index];
      if (_isDurableOpenInput(message) &&
          canonicalTranscriptIdentity(message) != null) {
        openInputs.add(index);
      }
    }
    if (openInputs.length != 1) return _LiveUserProjectionPlan.none;
    final inputIndex = openInputs.single;
    final hasOpenActivity = chronological
        .skip(inputIndex + 1)
        .any(_isDurableOpenTurnActivity);
    if (!hasOpenActivity) return _LiveUserProjectionPlan.none;
    return const _LiveUserProjectionPlan(
      representedPrefixLength: 1,
      proof: _LiveUserProjectionProof.openTurn,
    );
  }

  static _LiveUserProjectionPlan _liveUserProjectionPlan(
    List<Map<String, dynamic>> chronological,
    List<Map<String, dynamic>> previousNewestFirst,
    DesktopInflightTurn? inflight,
    bool bridgeOwnedLiveUser,
    DateTime? turnStartedAt,
  ) {
    if (inflight == null) return _LiveUserProjectionPlan.none;
    final liveUsers = <String>[
      if (inflight.user?.trim().isNotEmpty == true) inflight.user!,
      ...inflight.corrections.map((correction) => correction.text),
    ];
    if (liveUsers.isEmpty) return _LiveUserProjectionPlan.none;

    final anchorIndex = _exactPreviousAnchorIndex(
      chronological,
      previousNewestFirst,
      bridgeOwnedLiveUser,
    );
    if (anchorIndex == null) {
      return _firstOpenTurnPlan(chronological);
    }

    var terminalBoundary = anchorIndex;
    var terminalFoundAfterAnchor = false;
    for (var index = anchorIndex + 1; index < chronological.length; index++) {
      if (_isDurableTerminalAssistant(chronological[index])) {
        terminalBoundary = index;
        terminalFoundAfterAnchor = true;
      }
    }

    // On the next passive refresh, the latest previous row can already be the
    // durable form of the active input itself. Treat that exact, uniquely
    // anchored open tail as part of the current inflight turn; otherwise the
    // reconciler appends the same synthetic user again on every later snapshot.
    // A previous terminal assistant still wins, so an identical completed
    // prompt remains a distinct new turn.
    final anchoredMessage = chronological[anchorIndex];
    final anchoredAt = _projectedTimestamp(anchoredMessage);
    final anchorIsDurableOpenInput =
        !terminalFoundAfterAnchor &&
        turnStartedAt != null &&
        anchoredAt != null &&
        anchoredAt.isAfter(turnStartedAt) &&
        canonicalTranscriptIdentity(anchoredMessage) != null &&
        _isDurableOpenInput(anchoredMessage);
    if (anchorIsDurableOpenInput) {
      terminalBoundary = -1;
      for (var index = anchorIndex - 1; index >= 0; index--) {
        if (_isDurableTerminalAssistant(chronological[index])) {
          terminalBoundary = index;
          break;
        }
      }
    }

    final durableOpenInputs = <Map<String, dynamic>>[];
    for (
      var index = terminalBoundary + 1;
      index < chronological.length;
      index++
    ) {
      final message = chronological[index];
      if (_isDurableOpenInput(message)) durableOpenInputs.add(message);
    }
    if (durableOpenInputs.isEmpty) return _LiveUserProjectionPlan.none;

    final sharedLength = durableOpenInputs.length < liveUsers.length
        ? durableOpenInputs.length
        : liveUsers.length;
    for (var index = 0; index < sharedLength; index++) {
      if (durableOpenInputs[index]['content']?.toString() != liveUsers[index]) {
        return _LiveUserProjectionPlan.none;
      }
    }
    if (durableOpenInputs.length > liveUsers.length &&
        durableOpenInputs
            .skip(liveUsers.length)
            .any((message) => message['_steer'] != true)) {
      return _LiveUserProjectionPlan.none;
    }
    return _LiveUserProjectionPlan(
      representedPrefixLength: sharedLength,
      proof: _LiveUserProjectionProof.exactAnchorPrefix,
    );
  }

  /// Extrae vetos privados de identidades durables no contradictorias.
  ///
  /// Repetir exactamente una fila no revoca evidencia negativa. En cambio, dos
  /// identidades que comparten una coordenada y contradicen la otra quedan
  /// aisladas: ninguna se usa para clasificar filas de otra superficie.
  List<TranscriptMessageIdentity> privateTranscriptIdentityVetoes(
    List<DesktopSessionMessage> persistedChronological,
  ) {
    final identities = <DesktopSessionMessage, TranscriptMessageIdentity>{};
    final conflicting = <DesktopSessionMessage>{};
    for (final candidate in persistedChronological) {
      final identity = _desktopTranscriptIdentity(candidate);
      if (identity == null) continue;
      for (final entry in identities.entries) {
        if (!identity.sharesExactCoordinate(entry.value) ||
            identity.matches(entry.value)) {
          continue;
        }
        conflicting
          ..add(candidate)
          ..add(entry.key);
      }
      identities[candidate] = identity;
    }

    final vetoes = <TranscriptMessageIdentity>[];
    for (final entry in identities.entries) {
      if (entry.key.publiclyRenderable || conflicting.contains(entry.key)) {
        continue;
      }
      if (!vetoes.any(entry.value.matches)) vetoes.add(entry.value);
    }
    return List<TranscriptMessageIdentity>.unmodifiable(vetoes);
  }

  /// REST 0.19 conserva el contenido autoritativo pero puede omitir los campos
  /// editoriales que sí entrega `session.resume`. Superpone esos campos solo
  /// cuando el mismo mensaje se identifica por id estable. El contenido no es
  /// identidad: dos turnos legítimos pueden tener exactamente el mismo texto.
  List<Map<String, dynamic>> overlayDurableDisplayMetadata(
    List<Map<String, dynamic>> fallbackNewestFirst,
    List<DesktopSessionMessage> persistedChronological,
  ) {
    if (fallbackNewestFirst.isEmpty || persistedChronological.isEmpty) {
      return fallbackNewestFirst;
    }

    final graph = TranscriptPrivacyGraph([
      ...persistedChronological.map((row) => row.transcriptPrivacyObservation),
      ...fallbackNewestFirst.map(TranscriptPrivacyObservation.fromRaw),
    ]);

    final identities = <DesktopSessionMessage, TranscriptMessageIdentity>{};
    final ambiguous = <DesktopSessionMessage>{};
    for (final candidate in persistedChronological) {
      final identity = _desktopTranscriptIdentity(candidate);
      if (identity == null) continue;
      for (final entry in identities.entries) {
        if (!identity.sharesExactCoordinate(entry.value)) continue;
        ambiguous
          ..add(candidate)
          ..add(entry.key);
      }
      identities[candidate] = identity;
    }
    final fallbackIdentities =
        <Map<String, dynamic>, TranscriptMessageIdentity>{};
    final ambiguousFallback = <Map<String, dynamic>>{};
    for (final message in fallbackNewestFirst) {
      final identity = canonicalTranscriptIdentity(message);
      if (identity == null) continue;
      for (final entry in fallbackIdentities.entries) {
        if (!identity.sharesExactCoordinate(entry.value)) continue;
        ambiguousFallback
          ..add(message)
          ..add(entry.key);
      }
      fallbackIdentities[message] = identity;
    }

    final merged = <Map<String, dynamic>>[];
    for (final message in fallbackNewestFirst) {
      final identity = canonicalTranscriptIdentity(message);
      // El veto es una operación de conjunto: todos los duplicados exactos de
      // una identidad privada se eliminan. La ambigüedad sigue bloqueando solo
      // la superposición positiva de metadata, no convierte un duplicado en
      // autorización para mostrar contenido sin classifier.
      final observation = TranscriptPrivacyObservation.fromRaw(message);
      if (graph.excludes(observation)) continue;
      if (ambiguousFallback.contains(message)) {
        merged.add(message);
        continue;
      }
      DesktopSessionMessage? candidate;
      if (identity != null && graph.permitsPartialInference(observation)) {
        for (final entry in identities.entries) {
          if (ambiguous.contains(entry.key) || !identity.matches(entry.value)) {
            continue;
          }
          if (candidate != null) {
            candidate = null;
            break;
          }
          candidate = entry.key;
        }
      }
      if (candidate == null) {
        merged.add(message);
        continue;
      }

      // La clasificación del snapshot es evidencia autoritativa negativa. Una
      // identidad igual permite vetar o superponer metadata, nunca convertir el
      // contenido REST/cache sin classifier en permiso público.
      if (!candidate.publiclyRenderable) continue;
      if (message['_steer'] == true) {
        merged.add(message);
        continue;
      }
      final displayKind =
          candidate.raw['display_kind']?.toString().trim() ?? '';
      if (displayKind.isEmpty) {
        merged.add(message);
        continue;
      }
      final next = Map<String, dynamic>.from(message)
        ..['display_kind'] = displayKind;
      final metadata = sanitizeDelegationDisplayMetadata(
        candidate.displayMetadata,
      );
      if (metadata == null) {
        next.remove('display_metadata');
      } else {
        next['display_metadata'] = metadata;
      }
      merged.add(Map<String, dynamic>.unmodifiable(next));
    }
    return List<Map<String, dynamic>>.unmodifiable(merged);
  }

  DesktopSessionProjection project(
    DesktopSessionSnapshot snapshot, {
    List<Map<String, dynamic>> fallbackNewestFirst = const [],
    List<Map<String, dynamic>> previousNewestFirst = const [],
    bool bridgeOwnedLiveUser = false,
    bool retainMediaEvidence = false,
  }) {
    final chronological = snapshot.messagesProvided
        ? <Map<String, dynamic>>[
            for (var index = 0; index < snapshot.messages.length; index++)
              ..._projectPersistedMessage(
                snapshot.messages[index],
                runtimeSessionId: snapshot.runtimeSessionId,
                ordinal: snapshot.messages[index].serverOrdinal ?? index,
                retainMediaEvidence: retainMediaEvidence,
              ),
          ]
        : fallbackNewestFirst.reversed
              .map<Map<String, dynamic>>(_copyMessage)
              .toList(growable: true);

    // A repeated resume may feed the previous live projection back as fallback.
    // Replace those synthetic rows with the current snapshot instead of
    // appending another prompt/correction/assistant tail on every hydration.
    if (!snapshot.messagesProvided) {
      chronological.removeWhere(
        (message) => message['_desktopSnapshotKind'] == 'inflight',
      );
    }

    final inflight = snapshot.inflight;
    final inflightUser = inflight?.user;
    final inflightError = inflight?.error?.trim() ?? '';
    final inflightStatus = inflight?.status?.trim().toLowerCase() ?? '';
    final inflightFailed =
        inflightError.isNotEmpty || inflightStatus == 'error';
    final liveUserPlan = _liveUserProjectionPlan(
      chronological,
      previousNewestFirst,
      inflight,
      bridgeOwnedLiveUser,
      snapshot.resolvedTurnStartedAt,
    );
    final hasInflightUser = inflightUser?.trim().isNotEmpty == true;
    final durableStructuredInflight =
        inflightUser != null &&
        chronological.any(
          (message) => _matchesDurableStructuredInput(message, inflightUser),
        );
    // The Gateway does not link inflight users to durable row IDs. Suppress an
    // ordinary user only from an exact prior anchor or one unambiguous durable
    // open turn; a classified durable row carries its own structural identity.
    if (inflightUser != null &&
        inflightUser.trim().isNotEmpty &&
        liveUserPlan.emits(0) &&
        !durableStructuredInflight) {
      chronological.add(
        Map<String, dynamic>.unmodifiable({
          'role': 'user',
          'content': inflightUser,
          '_desktopSnapshotKey': 'user-inflight-${snapshot.runtimeSessionId}',
          '_desktopSnapshotKind': 'inflight',
        }),
      );
    }

    final inflightCorrections =
        inflight?.corrections ?? const <DesktopInflightCorrection>[];
    final inflightAssistant = inflight?.assistant;
    final hasInflight =
        !inflightFailed &&
        (inflight != null || snapshot.running || inflight?.streaming == true);
    final correctionOffsets = inflight?.correctionOffsets ?? const <int?>[];
    final correctionOffsetsUsable =
        !inflightFailed &&
        inflightAssistant != null &&
        inflightAssistant.isNotEmpty &&
        inflightCorrections.isNotEmpty &&
        correctionOffsets.length >= inflightCorrections.length &&
        correctionOffsets
            .take(inflightCorrections.length)
            .every((offset) => offset != null);

    Map<String, dynamic> correctionMessage(
      DesktopInflightCorrection correction,
      int index,
    ) => Map<String, dynamic>.unmodifiable({
      'role': 'user',
      'content': correction.text,
      '_steer': true,
      '_desktopSnapshotKey':
          'user-inflight-correction-$index-${snapshot.runtimeSessionId}',
      '_desktopSnapshotKind': 'inflight',
    });

    Map<String, dynamic> assistantMessage(
      String content, {
      required String key,
      required bool live,
    }) => Map<String, dynamic>.unmodifiable({
      'role': 'assistant',
      'content': content,
      '_pipeline': live,
      if (!live) '_interim': true,
      '_desktopSnapshotKey': key,
      '_desktopSnapshotKind': 'inflight',
    });

    if (correctionOffsetsUsable) {
      final publicProjection = projectPublicAssistantText(
        inflightAssistant,
        streaming: true,
      );
      final publicAssistant = publicProjection.text;
      var cursor = 0;
      var publicCursor = 0;
      for (var index = 0; index < inflightCorrections.length; index++) {
        final boundary = correctionOffsets[index]!.clamp(
          cursor,
          inflightAssistant.length,
        );
        var safeBoundary = publicProjection.publicOffsetAtRawOffset(boundary);
        if (safeBoundary < publicCursor) safeBoundary = publicCursor;
        final segment = publicAssistant.substring(publicCursor, safeBoundary);
        if (segment.isNotEmpty) {
          chronological.add(
            assistantMessage(
              segment,
              key:
                  'assistant-stream-segment-$index-${snapshot.runtimeSessionId}',
              live: false,
            ),
          );
        }
        cursor = boundary;
        publicCursor = safeBoundary;
        final liveUserIndex = (hasInflightUser ? 1 : 0) + index;
        if (liveUserPlan.emits(liveUserIndex)) {
          chronological.add(
            correctionMessage(inflightCorrections[index], index),
          );
        }
      }
      chronological.add(
        assistantMessage(
          publicAssistant.substring(publicCursor),
          key: 'assistant-stream-${snapshot.runtimeSessionId}',
          live: true,
        ),
      );
    } else {
      if (hasInflight &&
          (inflightAssistant != null ||
              inflightUser != null ||
              inflightCorrections.isNotEmpty ||
              snapshot.running)) {
        chronological.add(
          assistantMessage(
            streamingPublicAssistantText(inflightAssistant ?? ''),
            key: 'assistant-stream-${snapshot.runtimeSessionId}',
            live: true,
          ),
        );
      }
      for (var index = 0; index < inflightCorrections.length; index++) {
        final liveUserIndex = (hasInflightUser ? 1 : 0) + index;
        if (liveUserPlan.emits(liveUserIndex)) {
          chronological.add(
            correctionMessage(inflightCorrections[index], index),
          );
        }
      }
    }

    if (inflightFailed) {
      final partial = streamingPublicAssistantText(
        inflightAssistant ?? '',
      ).trim();
      if (partial.isNotEmpty) {
        chronological.add(
          Map<String, dynamic>.unmodifiable({
            'role': 'assistant',
            'content': partial,
            '_cancelled': true,
            '_pipeline': false,
            '_desktopSnapshotKey':
                'assistant-stream-${snapshot.runtimeSessionId}',
            '_desktopSnapshotKind': 'inflight',
          }),
        );
      }
      final error = inflightError.isEmpty
          ? 'Hermes reported an error'
          : inflightError;
      chronological.add(
        Map<String, dynamic>.unmodifiable({
          'role': 'assistant_error',
          'content': error,
          if (inflightUser?.trim().isNotEmpty == true)
            '_prompt': inflightUser!.trim(),
          'error': error,
          'partial': partial.isNotEmpty,
          'recoverable': ?inflight?.recoverable,
          '_desktopSnapshotKey': 'assistant-error-${snapshot.runtimeSessionId}',
          '_desktopSnapshotKind': 'inflight',
        }),
      );
    }

    final queuedUser = snapshot.queued?.user;
    final newestFirst = coalesceAssistantTurnsNewestFirst(
      chronological.reversed.map<Map<String, dynamic>>(_copyMessage),
    );
    return DesktopSessionProjection(
      messagesNewestFirst: newestFirst,
      queuedUser: queuedUser,
      queuedSyntheticId: queuedUser == null
          ? null
          : 'user-queued-${snapshot.runtimeSessionId}',
      running: !inflightFailed && (snapshot.running || inflight != null),
      failed: inflightFailed,
      status: inflightFailed ? 'error' : snapshot.status,
    );
  }

  List<Map<String, dynamic>> _projectPersistedMessage(
    DesktopSessionMessage message, {
    required String runtimeSessionId,
    required int ordinal,
    required bool retainMediaEvidence,
  }) {
    if (!message.publiclyRenderable) return const [];
    final role = switch (message.role) {
      DesktopSessionMessageRole.system => 'system',
      DesktopSessionMessageRole.user => 'user',
      DesktopSessionMessageRole.assistant => 'assistant',
      DesktopSessionMessageRole.tool => 'tool',
      DesktopSessionMessageRole.unknown => message.rawRole.toLowerCase(),
    };
    final displayKind = message.raw['display_kind']?.toString().trim() ?? '';
    final displayMetadata = sanitizeDelegationDisplayMetadata(
      message.displayMetadata,
    );
    if (role != 'user' && role != 'assistant' && role != 'tool') {
      return const [];
    }

    // Bloques estructurados estilo Anthropic dentro de `content: [...]`.
    // Solo el texto narrativo es público; thinking, tool_use y tool_result se
    // eliminan aquí. La ruta de medios puede conservar temporalmente la forma
    // mínima de herramientas para asociar adjuntos y la proyección final la
    // vuelve a retirar.
    final blocks = message.content is List ? message.content as List : null;
    final synthesizedToolCalls = <Map<String, dynamic>>[];
    final toolResultBlocks = <Map<dynamic, dynamic>>[];
    var imageCount = 0;
    Object? displaySource = message.content;
    if (blocks != null) {
      final textBlocks = <Object?>[];
      var droppedAny = false;
      for (final block in blocks) {
        if (block is! Map) {
          textBlocks.add(block);
          continue;
        }
        final type = (block['type'] ?? '').toString().trim().toLowerCase();
        switch (type) {
          case 'thinking':
          case 'redacted_thinking':
            droppedAny = true;
          case 'tool_use':
            droppedAny = true;
            final name = block['name']?.toString().trim() ?? '';
            if (name.isNotEmpty) {
              final input = block['input'];
              synthesizedToolCalls.add(
                Map<String, dynamic>.unmodifiable({
                  if (block['id'] != null) 'id': block['id'].toString(),
                  'type': 'function',
                  'function': Map<String, dynamic>.unmodifiable({
                    'name': name,
                    'arguments': input is String
                        ? input
                        : jsonEncode(input ?? const {}),
                  }),
                }),
              );
            }
          case 'tool_result':
            droppedAny = true;
            toolResultBlocks.add(block);
          case 'image':
          case 'input_image':
            droppedAny = true;
            imageCount++;
          default:
            textBlocks.add(block);
        }
      }
      if (droppedAny) displaySource = textBlocks;
    }

    var content =
        message.text ??
        desktopSessionDisplayText(displaySource) ??
        desktopSessionDisplayText(message.context) ??
        '';
    if (role == 'assistant' && content.trim().isEmpty) {
      content = codexMessageItemText(message.codexMessageItems);
    }
    final reasoning = role == 'assistant'
        ? durableAssistantReasoningText({
            'reasoning': message.reasoning,
            'reasoning_content': message.reasoningContent,
            'reasoning_details': message.reasoningDetails,
            'codex_message_items': message.codexMessageItems,
          })
        : '';
    final projectedToolCalls = message.toolCalls is List
        ? message.toolCalls
        : synthesizedToolCalls;
    final toolActivity = role == 'assistant'
        ? assistantActivityFromToolCalls(
            projectedToolCalls,
            timestamp: message.timestamp == null
                ? null
                : message.timestamp!.millisecondsSinceEpoch / 1000,
          )
        : const <Map<String, dynamic>>[];
    if (imageCount > 0) {
      // Aún no hay tarjeta para imágenes de bloques estructurados; el marcador
      // conserva al menos la señal de que el turno incluía una imagen.
      const marker = '*(imagen adjunta)*';
      content = content.isEmpty ? marker : '$content\n\n$marker';
    }

    final toolResultMessages = <Map<String, dynamic>>[
      for (var index = 0; index < toolResultBlocks.length; index++)
        Map<String, dynamic>.unmodifiable({
          'role': 'tool',
          'content': retainMediaEvidence
              ? desktopSessionDisplayText(toolResultBlocks[index]['content']) ??
                    ''
              : '',
          if (toolResultBlocks[index]['name'] != null)
            'tool_name': toolResultBlocks[index]['name'].toString(),
          if (toolResultBlocks[index]['tool_use_id'] != null)
            'tool_call_id': toolResultBlocks[index]['tool_use_id'].toString(),
          '_desktopSnapshotKey':
              'message-$runtimeSessionId-$ordinal-toolresult-$index',
          '_desktopSnapshotKind': 'persisted',
        }),
    ];

    // Un mensaje user cuyo contenido eran SOLO bloques tool_result (formato
    // Anthropic) no es un prompt real: se proyecta como mensajes tool y no
    // deja una burbuja de usuario vacía.
    if (role == 'assistant') content = finalizedPublicAssistantText(content);
    final dropMain =
        (role == 'user' && content.isEmpty && toolResultBlocks.isNotEmpty) ||
        (role == 'assistant' &&
            content.trim().isEmpty &&
            reasoning.isEmpty &&
            toolActivity.isEmpty);
    final main = Map<String, dynamic>.unmodifiable({
      'role': role,
      'content': role == 'tool' && !retainMediaEvidence ? '' : content,
      if (reasoning.isNotEmpty) 'reasoning': reasoning,
      if (toolActivity.isNotEmpty) assistantActivityTraceKey: toolActivity,
      '_desktopSnapshotKey': 'message-$runtimeSessionId-$ordinal',
      '_desktopSnapshotKind': 'persisted',
      '_desktopMessageOrdinal': ordinal,
      if (message.rowId != null) '_desktopRowId': message.rowId,
      if (message.stableId != null) '_desktopMessageId': message.stableId,
      if (displayKind.isNotEmpty) 'display_kind': displayKind,
      'display_metadata': ?displayMetadata,
      if (retainMediaEvidence && message.name != null) 'name': message.name,
      if (retainMediaEvidence && message.toolName != null)
        'tool_name': message.toolName,
      if (retainMediaEvidence && message.toolCallId != null)
        'tool_call_id': message.toolCallId,
      if (retainMediaEvidence && message.toolCalls != null)
        'tool_calls': message.toolCalls
      else if (retainMediaEvidence && synthesizedToolCalls.isNotEmpty)
        'tool_calls': synthesizedToolCalls,
      if (message.timestamp != null)
        'timestamp': message.timestamp!.millisecondsSinceEpoch / 1000,
    });
    return dropMain ? toolResultMessages : [main, ...toolResultMessages];
  }
}

/// Conserva únicamente el pequeño contrato editorial que Hermes Desktop usa
/// para resumir eventos duraderos. Algunos gateways antiguos serializan el
/// objeto como JSON; nunca propagamos campos arbitrarios al árbol de widgets.
Map<String, dynamic>? sanitizeDelegationDisplayMetadata(Object? raw) {
  Object? decoded = raw;
  if (raw is String) {
    final value = raw.trim();
    if (value.isEmpty || value.length > 4096) return null;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return null;
    }
  }
  if (decoded is! Map) return null;

  const countKeys = {'task_count', 'completed_count', 'failed_count'};
  final safe = <String, dynamic>{};
  for (final key in countKeys) {
    final value = decoded[key];
    if (value is int && value >= 0 && value <= 10000) {
      safe[key] = value;
    }
  }
  // Título compacto que el runtime ya redactó para la UI (lo mismo que pinta
  // Hermes Desktop). Se acepta como una sola línea acotada: nunca sustituye al
  // contenido durable ni se reconstruye leyendo el texto del mensaje.
  final displayText = decoded['display_text'];
  if (displayText is String) {
    final text = displayText.trim();
    if (text.isNotEmpty &&
        text.length <= 200 &&
        !text.contains(_unsafeDisplayTextPattern)) {
      safe['display_text'] = text;
    }
  }
  final duration = decoded['duration_seconds'];
  if (duration is num &&
      duration.isFinite &&
      duration >= 0 &&
      duration <= 604800) {
    safe['duration_seconds'] = duration;
  }
  final delegationId = decoded['delegation_id'];
  if (delegationId is String &&
      delegationId.isNotEmpty &&
      delegationId.length <= 180 &&
      RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(delegationId)) {
    safe['delegation_id'] = delegationId;
  }
  final rawSubagentIds = decoded['subagent_ids'];
  if (rawSubagentIds is List &&
      rawSubagentIds.isNotEmpty &&
      rawSubagentIds.length <= 64) {
    final ids = <String>[];
    var valid = true;
    for (final rawId in rawSubagentIds) {
      if (rawId is! String) {
        valid = false;
        break;
      }
      final id = rawId.trim();
      if (id.isEmpty ||
          id.length > 180 ||
          !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(id) ||
          ids.contains(id)) {
        valid = false;
        break;
      }
      ids.add(id);
    }
    final taskCount = safe['task_count'];
    if (valid && (taskCount == null || taskCount == ids.length)) {
      safe['subagent_ids'] = List<String>.unmodifiable(ids);
    }
  }
  return safe.isEmpty ? null : Map<String, dynamic>.unmodifiable(safe);
}

Map<String, dynamic> _copyMessage(Map<String, dynamic> value) =>
    Map<String, dynamic>.unmodifiable(Map<String, dynamic>.from(value));

/// Proyecta contenido estructurado del contrato Desktop/REST a texto seguro
/// para la UI. Los adjuntos permanecen en el índice estructural y nunca se
/// serializan como mapas dentro de las burbujas del chat.
String? desktopSessionDisplayText(Object? value) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  if (value is List) {
    final out = StringBuffer();
    var previousWasTextPart = false;
    for (final item in value) {
      final part = desktopSessionDisplayText(item);
      if (part == null || part.trim().isEmpty) continue;
      final isTextPart = _isStructuredTextPart(item);
      if (out.isNotEmpty && !(previousWasTextPart && isTextPart)) {
        out.write('\n');
      }
      out.write(part);
      previousWasTextPart = isTextPart;
    }
    return out.isEmpty ? null : out.toString();
  }
  if (value is Map) {
    final text = value['text'] ?? value['content'];
    return desktopSessionDisplayText(text);
  }
  return null;
}

bool _isStructuredTextPart(Object? value) {
  if (value is! Map) return false;
  final type = (value['type'] ?? '').toString().trim().toLowerCase();
  return type.isEmpty ||
      type == 'text' ||
      type == 'input_text' ||
      type == 'output_text' ||
      type == 'summary_text';
}
