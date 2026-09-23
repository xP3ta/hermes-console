import '../models/bot_mention.dart';
import 'bot_mention_roster.dart';
// Servicio singleton que posee el streaming SSE de los chats. Vive por encima
// del Navigator (en HermesAppState), así que la respuesta/ejecución del agente
// CONTINÚA aunque el usuario salga de la pantalla del chat. La pantalla del chat
// se "engancha" a un [ActiveChat] al abrirse y se "suelta" al cerrarse, sin
// cancelar el stream. La lista de sesiones observa [activeIds] para pintar el
// indicador de "chat en curso".
//
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../widgets/chat_event_cards.dart';
import '../models/activity_snapshot.dart' show activityToolDetail;
import '../models/agent_task_list.dart';
import '../models/attachment_draft.dart';
import '../models/compaction_progress.dart' show parseCompactionChunks;
import '../models/command_descriptor.dart';
import '../models/core_read.dart';
import '../models/desktop_compression_authority.dart';
import '../models/desktop_active_session.dart';
import '../models/desktop_compression_result.dart';
import '../models/desktop_compression_outcome.dart';
import '../models/desktop_context_breakdown.dart';
import '../models/desktop_control_center.dart';
import '../models/desktop_model_catalog.dart';
import '../models/desktop_session_config.dart';
import '../models/desktop_session_snapshot.dart';
import '../models/home_widget_snapshot.dart';
import '../models/interactive_prompt.dart';
import '../models/prepared_turn.dart';
import '../models/session_activity.dart';
import '../models/session_artifact.dart';
import '../models/subagent_activity.dart';
import '../models/transcript_privacy_state.dart';
import '../screens/chat_render_projection.dart';
import '../utils/assistant_content.dart';
import '../utils/chat_turn.dart';
import 'approval_policy.dart';
import 'artifact_index.dart';
import 'attachment_uploader.dart';
import 'bridge_client.dart';
import 'bridge_version.dart';
import 'capability_payload_sanitizer.dart';
import 'command_risk.dart';
import 'compression_dispatcher.dart';
import 'connection_manager.dart';
import 'desktop_compression_fence_store.dart';
import 'desktop_control_gateway.dart';
import 'desktop_gateway_capabilities.dart';
import 'home_widget_publisher.dart';
import 'generated_image_service.dart';
import 'generated_media_service.dart';
import 'global_activity_aggregate.dart';
import 'local_transcript_store.dart';
import 'interactive_prompt_reducer.dart';
import 'profile_chat_mode.dart';
import 'recovery_proof.dart';
import 'notifications/background_listener.dart';
import 'notifications/notification_service.dart';
import 'run_registry.dart';
import 'session_config_reducer.dart';
import 'session_deletion.dart';
import 'session_reconciler.dart';
import 'transcript_publication_coordinator.dart';
import 'subagent_activity_reducer.dart';
import 'subagent_transcript_projection.dart';
import 'terminal_transcript_authority.dart';
import 'tui_gateway_client.dart';
import 'turn_outbox_store.dart';

/// Hermes Desktop espera hasta cinco segundos a que el turno interrumpido deje
/// de estar busy antes de entregar la corrección capturada por barge-in.
@visibleForTesting
const activeChatVoiceBargeSettleTimeout = Duration(seconds: 5);

/// Plazo máximo que un envío explícito espera al ACK de `session.interrupt`
/// cuando el Stop que estacionó la cola sigue vivo. Mismo orden de magnitud que
/// el drenaje de interrupción de `rewrite()`, y por la misma razón: un gateway
/// antiguo puede no publicar nunca ese terminal.
@visibleForTesting
const activeChatStopAdmissionSettleTimeout = Duration(seconds: 3);

const _activeChatRewindBusyRetryInterval = Duration(milliseconds: 150);
const _activeChatRewindBusyRetryTimeout = Duration(seconds: 6);

@visibleForTesting
String activeChatDesktopRecoveryUiMessage(Object _) =>
    'No se pudo recuperar el turno. Inténtalo de nuevo.';

@visibleForTesting
String activeChatDesktopSnapshotFailureUiMessage(String? _) =>
    'No se pudo recuperar el turno. Inténtalo de nuevo.';

const _activeChatDesktopFailureFallback =
    'No se pudo completar la respuesta. Inténtalo de nuevo.';

/// Longitud de causa que llega a la UI.
const _activeChatDesktopFailureCauseLimit = 180;

/// Ventana inspeccionada antes de acotar. Basta con cubrir de sobra la causa
/// proyectada para que ningún secreto quede partido dentro de ella, y sigue
/// siendo un tope fijo frente a un `message` remoto enorme.
const _activeChatDesktopFailureCauseScanLimit = 4096;

/// Projects only the Gateway's official `message` cause. Free-form sibling
/// fields can contain partial output, provider payloads, paths, or credentials.
@visibleForTesting
String activeChatDesktopEventFailureUiMessage(Object? rawMessage) {
  // Se inspecciona una ventana mucho mayor que la proyectada: acotar primero
  // partiría un identificador opaco justo en el límite y el fragmento restante
  // ya no alcanzaría `{24,}`, colándose como si fuera prosa.
  final scanned = const CapabilityPayloadSanitizer().boundedText(
    rawMessage,
    _activeChatDesktopFailureCauseScanLimit,
  );
  if (scanned == null) return _activeChatDesktopFailureFallback;
  final normalized = scanned.replaceAll(RegExp(r'\s+'), ' ').trim();
  final sensitive = RegExp(
    r'''(?:^|\s)(?:~[/\\]|/(?:home|users|root|data|storage|sdcard|private|var|tmp|etc)(?:[/\\]|\b))|[a-z]:[/\\]|https?://|\b(?:authorization|bearer|api[_ -]?key|token|password|passwd|secret|cookie|session[_ -]?id)\b|\b[A-Za-z0-9_+/=-]{24,}\b''',
    caseSensitive: false,
  );
  if (normalized.isEmpty || sensitive.hasMatch(normalized)) {
    return _activeChatDesktopFailureFallback;
  }
  final projected = normalized.length <= _activeChatDesktopFailureCauseLimit
      ? normalized
      : normalized.substring(0, _activeChatDesktopFailureCauseLimit);
  return 'No se pudo completar la respuesta: $projected';
}

@visibleForTesting
String activeChatDesktopRecoveryDiagnostic(Object error) {
  final code = error is TuiGatewayRpcError ? ', code=${error.code}' : '';
  return '[active-chat] gave up reason kind=${error.runtimeType}$code';
}

@visibleForTesting
String activeChatBridgeErrorUiMessage(Object error) {
  final low = error.toString().toLowerCase();
  if (low.contains('connection closed') ||
      low.contains('before full header') ||
      low.contains('connection reset') ||
      low.contains('connection refused') ||
      low.contains('socketexception')) {
    return 'El agente local se detuvo durante la respuesta (el proceso se '
        'cerró, normalmente por falta de memoria). Vuelve a arrancar el '
        'agente local y reintenta. Si se repite, usa un modelo más pequeño o '
        'da más RAM al dispositivo/emulador.';
  }
  if (low.contains('timeout') || low.contains('timed out')) {
    return 'El agente local tardó demasiado en responder. El modelo puede '
        'estar cargándose; espera unos segundos y reintenta.';
  }
  return 'No se pudo completar la respuesta local. Reintenta.';
}

const _sessionNotOwnedReason = 'SESSION_NOT_OWNED';
const _maxConcurrentSessionsReason = 'MAX_CONCURRENT_SESSIONS';
const _sessionCoordinationUnavailableReason =
    'SESSION_COORDINATION_UNAVAILABLE';
const _awaitingDurableTurnRecoveryKey = '_awaitingDurableTurnRecovery';
const _legacyRecoveryPartialProjectionKey = '_legacyRecoveryPartialProjection';

bool _isRecoverablePromptSessionRejection(Object error) =>
    error is TuiGatewayRpcError &&
    error.method == 'prompt.submit' &&
    error.code == 4001;

bool _isKnownPromptAdmissionRejection(Object error) =>
    error is TuiGatewayRpcError &&
    error.method == 'prompt.submit' &&
    (error.code == 4001 ||
        (error.code == 4090 &&
            (error.reason == _sessionNotOwnedReason ||
                error.reason == _maxConcurrentSessionsReason ||
                error.reason == _sessionCoordinationUnavailableReason)));

@visibleForTesting
bool activeChatPromptWasRejectedBeforeAcceptance(Object error) =>
    _isKnownPromptAdmissionRejection(error);

bool activeChatSteerFailureIsSafeToQueue(Object error) {
  if (error is TuiGatewayRpcError) {
    // The transport proved steering is unsupported or the session cannot be
    // redirected, so a next-turn queue cannot duplicate an accepted steer.
    return error.code == -32601 ||
        error.code == 4007 ||
        error.code == 4009 ||
        error.code == 4010;
  }
  if (error is StateError) {
    // Only deterministic "there is no steering transport" failures are safe.
    // Socket/reconnect StateErrors stay ambiguous and must remain a draft.
    return error.message == 'steer_not_available_for_local_bridge' ||
        error.message == 'steer_desktop_gateway_unavailable';
  }
  return false;
}

@visibleForTesting
bool activeChatRejectedRuntimeStillCurrent({
  required int expectedSessionEpoch,
  required int currentSessionEpoch,
  required int expectedBindEpoch,
  required int currentBindEpoch,
  required String rejectedRuntimeId,
  required String? currentRuntimeId,
}) =>
    expectedSessionEpoch == currentSessionEpoch &&
    expectedBindEpoch == currentBindEpoch &&
    rejectedRuntimeId == currentRuntimeId;

@visibleForTesting
bool activeChatPassiveActivityRequestStillCurrent({
  required String expectedStoredSessionId,
  required String? currentStoredSessionId,
  required String? expectedRuntimeSessionId,
  required String? currentRuntimeSessionId,
  required int expectedTurnEpoch,
  required int currentTurnEpoch,
  required int expectedBindEpoch,
  required int currentBindEpoch,
  required int expectedSessionEpoch,
  required int currentSessionEpoch,
  required int expectedRequestGeneration,
  required int currentRequestGeneration,
}) =>
    expectedStoredSessionId == currentStoredSessionId &&
    expectedRuntimeSessionId == currentRuntimeSessionId &&
    expectedTurnEpoch == currentTurnEpoch &&
    expectedBindEpoch == currentBindEpoch &&
    expectedSessionEpoch == currentSessionEpoch &&
    expectedRequestGeneration == currentRequestGeneration;

enum DesktopPassiveActivityState { idle, busy, unknown }

/// Bounded display-safe summary of durable passive work.
///
/// Opaque tool-call identities stay private to [ActiveChat]. The UI receives
/// counts only, never transcript labels, arguments, paths, models, or IDs.
@immutable
final class PassiveActivityAggregate {
  const PassiveActivityAggregate({
    required this.total,
    required this.active,
    required this.completed,
  });

  static const empty = PassiveActivityAggregate(
    total: 0,
    active: 0,
    completed: 0,
  );

  final int total;
  final int active;
  final int completed;
}

final class _PassiveDurableActivity {
  _PassiveDurableActivity({required this.opaqueKey, required this.completed});

  final String opaqueKey;
  bool completed;
}

@visibleForTesting
DesktopPassiveActivityState activeChatPassiveRowsState(
  Iterable<DesktopActiveSession> rows, {
  bool hasMalformedRows = false,
}) {
  if (hasMalformedRows) return DesktopPassiveActivityState.unknown;
  final materialized = rows.toList(growable: false);
  if (materialized.isEmpty) return DesktopPassiveActivityState.idle;
  if (materialized.length != 1) return DesktopPassiveActivityState.unknown;
  final row = materialized.single;
  if (row.runtimeSessionId.trim().isEmpty) {
    return DesktopPassiveActivityState.unknown;
  }
  return switch (row.status?.trim().toLowerCase()) {
    'idle' => DesktopPassiveActivityState.idle,
    'working' ||
    'running' ||
    'active' ||
    'busy' => DesktopPassiveActivityState.busy,
    _ => DesktopPassiveActivityState.unknown,
  };
}

@visibleForTesting
String activeChatPromptFailureUiMessage(
  Object error, {
  String languageCode = 'es',
}) {
  final english = languageCode.toLowerCase().startsWith('en');
  if (error is TuiGatewayRpcError && error.method == 'prompt.submit') {
    return switch (error.reason) {
      _sessionNotOwnedReason =>
        english
            ? 'This conversation can’t continue live because it belongs to '
                  'another gateway or process. Its history remains available, '
                  'and you can still start a new chat.'
            : 'No se puede continuar en directo porque esta conversación '
                  'pertenece a otro gateway o proceso. El historial se conserva '
                  'y puedes iniciar un chat nuevo.',
      _maxConcurrentSessionsReason =>
        english
            ? 'Hermes reached the configured active-session limit. Wait for a '
                  'session to finish or adjust the limit.'
            : 'Hermes alcanzó el límite configurado de sesiones activas. '
                  'Espera a que termine una sesión o ajusta el límite.',
      _sessionCoordinationUnavailableReason =>
        english
            ? 'Hermes could not safely reserve this conversation. Check the '
                  'server and try again.'
            : 'Hermes no pudo reservar esta conversación con seguridad. '
                  'Revisa el servidor y vuelve a intentarlo.',
      _ =>
        english
            ? 'The message could not be sent. Try again.'
            : 'No se pudo enviar el mensaje. Inténtalo de nuevo.',
    };
  }
  return english
      ? 'The message could not be sent. Try again.'
      : 'No se pudo enviar el mensaje. Inténtalo de nuevo.';
}

/// Redacta únicamente el formato técnico que builds antiguas pudieron guardar
/// en el transcript local. No se usa para decidir entrega ni reintentos: esas
/// decisiones dependen del código y `error.data.reason` estructurados.
String activeChatStoredErrorUiMessage(String error) {
  final normalized = error.trimLeft();
  if (normalized.startsWith('TuiGatewayRpcError(prompt.submit, 4090):')) {
    return 'No se puede continuar esta conversación en directo. '
        'El historial se conserva y puedes iniciar un chat nuevo.';
  }
  final lower = normalized.toLowerCase();
  if (lower == 'hermes reported an error') {
    return 'No se pudo completar la respuesta. Inténtalo de nuevo.';
  }
  if (lower.contains('socketexception') ||
      lower.contains('clientexception with socketexception') ||
      lower.contains('websocket closed')) {
    return 'Se perdió la conexión con Hermes. El mensaje no se confirmó; '
        'revisa el borrador y reintenta.';
  }
  return error;
}

List<Map<String, dynamic>> _sanitizeDesktopFailureProjection(
  Iterable<Map<String, dynamic>> projected,
) => projected
    .map((message) {
      if (message['role'] != 'assistant_error' ||
          message['_desktopSnapshotKind'] != 'inflight') {
        return message;
      }
      final safe = activeChatDesktopSnapshotFailureUiMessage(null);
      return Map<String, dynamic>.unmodifiable({
        ...message,
        'content': safe,
        'error': safe,
      });
    })
    .toList(growable: true);

@visibleForTesting
bool activeChatVoiceBargeRunIsTerminal(Map<String, dynamic> snapshot) =>
    const <String>{
      'completed',
      'failed',
      'cancelled',
    }.contains((snapshot['status'] ?? '').toString().trim().toLowerCase());

/// Espera pollable para el transporte REST, cuyo `/stop` oficial responde
/// `stopping` antes de que el run sea realmente terminal.
@visibleForTesting
Future<void> waitForActiveChatVoiceBargeTerminal({
  required Future<Map<String, dynamic>> Function() readStatus,
  Duration timeout = activeChatVoiceBargeSettleTimeout,
  Duration pollInterval = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return;
    Map<String, dynamic> snapshot;
    try {
      snapshot = await readStatus().timeout(remaining);
    } catch (_) {
      // 404 significa que el run ya salió del registro; red/gateway antiguo
      // degradan al mismo timeout best-effort que Desktop.
      return;
    }
    if (activeChatVoiceBargeRunIsTerminal(snapshot)) return;
    final afterRead = deadline.difference(DateTime.now());
    if (afterRead <= Duration.zero) return;
    final delay = pollInterval < afterRead ? pollInterval : afterRead;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
  }
}

/// Los marcadores `⟦img:…⟧` solo sirven para reconstruir miniaturas locales.
/// Nunca deben cruzar al servidor: contienen rutas privadas de Android que el
/// agente no puede leer y que pueden reaparecer desde el historial.
@visibleForTesting
String sanitizeRemoteChatText(String text) => text
    .split('\n')
    .where((line) => !RegExp(r'^\s*⟦img:[^⟧]+⟧\s*$').hasMatch(line))
    .join('\n')
    .trimRight();

/// `hermes-agent` es el alias del endpoint OpenAI-compatible, no un modelo de
/// proveedor válido para `/v1/runs`. Omitirlo deja que Hermes use su modelo
/// activo real.
@visibleForTesting
String? explicitRunModel(String model) {
  final value = model.trim();
  if (value.isEmpty || value.toLowerCase() == 'hermes-agent') return null;
  return value;
}

const _artifactContainerKeys = <String>{
  'attachment',
  'attachments',
  'artifact',
  'artifacts',
  'generated_image',
  'generated_images',
  'tool_result',
  'tool_results',
};

bool _rawMessageMayContainArtifact(Map<String, dynamic> message) {
  final content = message['content'];
  if (content is Map || content is List) return true;
  final role = message['role']?.toString().toLowerCase();
  final context = message['context'];
  if (role == 'tool' && (context is Map || context is List)) return true;
  for (final key in _artifactContainerKeys) {
    final value = message[key];
    if (value is Map || value is List) return true;
  }
  return false;
}

bool _messageMayContainArtifact(DesktopSessionMessage message) =>
    message.content is Map ||
    message.content is List ||
    message.artifactContainers.isNotEmpty ||
    (message.role == DesktopSessionMessageRole.tool &&
        (message.context is Map || message.context is List));

@visibleForTesting
Map<String, dynamic>? normalizeTranscriptMessageForDisplay(
  Map<String, dynamic> message, {
  bool retainMediaEvidence = false,
  bool retainUserMentionNote = false,
  bool retainProjectionState = false,
  bool retainAssistantToolCalls = false,
  bool retainEmptyAssistant = false,
}) {
  final rawRole = message['role'];
  if (rawRole is! String) return null;
  final role = rawRole.trim().toLowerCase();
  final isPrivateTransportRole = role == 'tool';
  final isLocalError = role == 'assistant_error' && retainProjectionState;
  if (role != 'user' &&
      role != 'assistant' &&
      !isLocalError &&
      !(retainMediaEvidence && isPrivateTransportRole)) {
    return null;
  }
  if (hasPrivateTranscriptClassifier(message)) return null;
  final rawDisplayKind = message['display_kind']?.toString().trim() ?? '';
  if (rawDisplayKind == 'hidden') return null;

  // Display reads project compaction carriers into `display_content` and
  // keep the model-facing text ("[PRIOR CONTEXT — …]") in `content`; Hermes
  // Desktop renders the projection whenever the server sends one.
  final displayContent = message['display_content'];
  final rawContent = displayContent != null
      ? desktopSessionDisplayText(displayContent) ?? ''
      : desktopSessionDisplayText(message['content']) ??
            desktopSessionDisplayText(message['text']) ??
            '';
  var content = rawContent;
  if (role == 'assistant') {
    if (rawContent.trim().isEmpty) {
      content = codexMessageItemText(message['codex_message_items']);
    }
    content = finalizedPublicAssistantText(content);
  }
  final reasoning = role == 'assistant'
      ? durableAssistantReasoningText(message)
      : '';
  // Internal Stop/recovery evidence must retain the exact submitted prompt.
  if (role == 'user' && !retainUserMentionNote) {
    content = stripBotMentionNote(content);
  }
  final activity = role == 'assistant'
      ? normalizeAssistantActivityTrace(message[assistantActivityTraceKey])
      : const <Map<String, dynamic>>[];
  final normalized = <String, dynamic>{
    'role': role,
    'content': content,
    if (reasoning.isNotEmpty) 'reasoning': reasoning,
    if (activity.isNotEmpty) assistantActivityTraceKey: activity,
  };
  final activityDuration = message['_activity_duration_seconds'];
  if (activityDuration is num &&
      activityDuration.isFinite &&
      activityDuration > 0 &&
      activityDuration <= 604800) {
    normalized['_activity_duration_seconds'] = activityDuration;
  }
  for (final key in const ['id', 'message_id', 'row_id']) {
    final value = message[key];
    if (value is int && value > 0) {
      normalized[key] = value;
    } else if (value is String &&
        value.trim().isNotEmpty &&
        value.length <= 180) {
      normalized[key] = value;
    }
  }
  for (final key in const ['timestamp', 'created_at', 'createdAt']) {
    final value = message[key];
    if (value is num && value.isFinite && value >= 0) {
      normalized[key] = value;
    } else if (value is String && value.length <= 64) {
      normalized[key] = value;
    }
  }
  if (retainMediaEvidence) {
    for (final key in const ['name', 'tool_call_id', 'tool_name']) {
      final value = message[key];
      if (value is String && value.trim().isNotEmpty && value.length <= 180) {
        normalized[key] = value;
      }
    }
  }
  final rawCalls = message['tool_calls'];
  if ((retainMediaEvidence || retainAssistantToolCalls) &&
      role == 'assistant' &&
      rawCalls is List) {
    final calls = <Map<String, dynamic>>[];
    for (final raw in rawCalls.take(64)) {
      if (raw is! Map) continue;
      final rawId = raw['id'];
      final function = raw['function'];
      final rawName = function is Map ? function['name'] : null;
      final id =
          rawId is String && rawId.trim().isNotEmpty && rawId.length <= 180
          ? rawId
          : null;
      final name =
          rawName is String &&
              rawName.trim().isNotEmpty &&
              rawName.length <= 180
          ? rawName
          : null;
      if (id == null && name == null) continue;
      final call = <String, dynamic>{};
      if (id != null) call['id'] = id;
      if (raw['type'] == 'function') call['type'] = 'function';
      if (name != null) call['function'] = {'name': name};
      calls.add(call);
    }
    if (calls.isNotEmpty) normalized['tool_calls'] = calls;
  }
  // Estos eventos viajan como `role=user`; su clasificación estructural es la
  // que impide que el transcript los atribuya a la persona.
  final displayKind =
      rawDisplayKind == 'model_switch' ||
          rawDisplayKind == 'personality_switch' ||
          rawDisplayKind == 'auto_continue' ||
          rawDisplayKind == 'async_delegation_complete' ||
          rawDisplayKind == 'compression_result' ||
          rawDisplayKind == 'process_complete'
      ? rawDisplayKind
      : effectiveUserDisplayKind(normalized);
  if (displayKind == 'model_switch' ||
      displayKind == 'personality_switch' ||
      displayKind == 'auto_continue') {
    normalized['display_kind'] = displayKind;
  } else if (displayKind == 'async_delegation_complete' ||
      displayKind == 'process_complete') {
    normalized['display_kind'] = displayKind;
    final metadata = sanitizeDelegationDisplayMetadata(
      message['display_metadata'],
    );
    if (metadata?.isNotEmpty == true) {
      normalized['display_metadata'] = metadata;
    }
  } else if (displayKind == 'compression_result') {
    final metadata = _compressionResultDisplayMetadata(
      message['display_metadata'],
    );
    if (metadata == null) return null;
    normalized['display_kind'] = displayKind;
    normalized['display_metadata'] = metadata;
  }

  final generatedImages = _generatedImageMetadataOf(message);
  if (generatedImages.isNotEmpty) {
    normalized[_generatedImagesMetadataKey] = generatedImages;
  }
  final toolResultEvidence = message[assistantToolResultEvidenceKey];
  if (retainMediaEvidence &&
      role == 'assistant' &&
      toolResultEvidence is List) {
    normalized[assistantToolResultEvidenceKey] = toolResultEvidence
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList(growable: false);
  }
  if (retainProjectionState) {
    for (final key in const [
      '_pipeline',
      '_interim',
      '_cancelled',
      '_stopped',
      '_cancelledUser',
      '_steer',
      '_optimistic',
      '_desktopInterim',
      '_desktopInterimPublic',
      '_desktopAcceptedQueued',
      _awaitingDurableTurnRecoveryKey,
      'partial',
      'recoverable',
    ]) {
      final value = message[key];
      if (value is bool) normalized[key] = value;
    }
    if (isLocalError) {
      final prompt = message['_prompt'];
      if (prompt is String) normalized['_prompt'] = prompt;
      normalized['error'] = content;
      final legacyPartial = message[_legacyRecoveryPartialProjectionKey];
      if (legacyPartial is Map<String, dynamic>) {
        final normalizedPartial = normalizeTranscriptMessageForDisplay(
          legacyPartial,
          retainProjectionState: true,
          retainEmptyAssistant: true,
        );
        if (normalizedPartial != null &&
            normalizedPartial['role'] == 'assistant') {
          normalized[_legacyRecoveryPartialProjectionKey] = normalizedPartial;
        }
      }
    }
    final subagentCompletion = historicalSubagentCompletionOf(message);
    if (subagentCompletion != null) {
      normalized['_subagent_completion_card'] = subagentCompletion;
      if (subagentCompletion.subagentIds.isNotEmpty) {
        final metadata = Map<String, dynamic>.from(
          normalized['display_metadata'] is Map
              ? normalized['display_metadata'] as Map
              : const <String, dynamic>{},
        );
        metadata['subagent_ids'] = subagentCompletion.subagentIds;
        normalized['display_metadata'] = Map<String, dynamic>.unmodifiable(
          metadata,
        );
      }
    }
  }

  final isEditorial = normalized.containsKey('display_kind');
  final isLivePlaceholder =
      retainProjectionState && normalized['_pipeline'] == true;
  final isRetainedEmptyAssistant = retainEmptyAssistant && role == 'assistant';
  final assistantToolCalls = normalized['tool_calls'];
  final hasAssistantToolCalls =
      assistantToolCalls is List && assistantToolCalls.isNotEmpty;
  if (content.trim().isEmpty &&
      reasoning.isEmpty &&
      activity.isEmpty &&
      generatedImages.isEmpty &&
      !isEditorial &&
      !isLivePlaceholder &&
      !isRetainedEmptyAssistant &&
      !hasAssistantToolCalls) {
    return null;
  }
  return normalized;
}

Map<String, dynamic>? _compressionResultDisplayMetadata(Object? raw) {
  if (raw is! Map) return null;
  final result = <String, dynamic>{};
  for (final key in const [
    'removed',
    'before_messages',
    'after_messages',
    'before_tokens',
    'after_tokens',
  ]) {
    final value = raw[key];
    if (value is! int || value < 0) return null;
    result[key] = value;
  }
  final noop = raw['noop'];
  if (noop is! bool) return null;
  result['noop'] = noop;
  return Map<String, dynamic>.unmodifiable(result);
}

// Compare only sanitized presentation values. Normalization recreates nested
// tool-call/media lists, so shallow Map equality cannot retain a live row.
bool _samePublicTranscriptValue(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_samePublicTranscriptValue(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_samePublicTranscriptValue(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

List<Map<String, dynamic>> _projectTranscriptForDisplay(
  Iterable<Map<String, dynamic>> messages, {
  bool retainEmptyAssistant = false,
  Map<Map<String, dynamic>, Map<String, dynamic>>? retainedBySource,
}) {
  final sources = messages.toList(growable: false);
  final projectedCompletions = projectHistoricalSubagentCompletions(
    messagesNewestFirst: sources,
  );
  final result = <Map<String, dynamic>>[];
  final publishedSources = HashSet<Map<String, dynamic>>.identity();
  // The editorial pass preserves source positions. Associate each public row
  // before filtering: tool/private rows must not disable identity retention
  // for the unrelated live assistant, nor shift it onto a different source.
  for (var index = 0; index < projectedCompletions.length; index++) {
    final projected = normalizeTranscriptMessageForDisplay(
      projectedCompletions[index],
      retainProjectionState: true,
      retainAssistantToolCalls: retainEmptyAssistant,
      retainEmptyAssistant: retainEmptyAssistant,
    );
    if (projected == null) continue;
    if (projected['role'] == 'assistant_error') projected.remove('error');
    final source = sources[index];
    final retained = retainedBySource?[source];
    final public =
        retained != null && _samePublicTranscriptValue(retained, projected)
        ? retained
        : Map<String, dynamic>.unmodifiable(projected);
    result.add(public);
    if (retainedBySource != null) {
      retainedBySource[source] = public;
      publishedSources.add(source);
    }
  }
  retainedBySource?.removeWhere(
    (source, _) => !publishedSources.contains(source),
  );
  return result;
}

const _privateTranscriptProjectionKeys = <String>{
  '_desktopSnapshotKey',
  '_desktopSnapshotKind',
  '_desktopMessageOrdinal',
  '_desktopRowId',
  '_desktopMessageId',
  '_clientTurnId',
  '_desktopInterimKey',
  '_desktopPostInterimKey',
  '_localTranscriptProjectionId',
  '_localTranscriptPairId',
  '_localTerminalProjectionId',
  '_localTerminalAnchorMessageId',
  '_localTerminalAnchorRowId',
  '_localTerminalOrdinalAfterAnchor',
  '_localTerminalAbsoluteUserOrdinal',
  '_localCompactedTerminalProjection',
  '_localCompactedTerminalAnchorMessageId',
  '_localCompactedTerminalAnchorRowId',
  '_localStopProofAnchorMessageId',
  '_localStopProofAnchorRowId',
};

List<Map<String, dynamic>> _projectTranscriptForInternalState(
  Iterable<Map<String, dynamic>> messages,
) {
  final projectedCompletions = projectHistoricalSubagentCompletions(
    messagesNewestFirst: messages.toList(growable: false),
  );
  final projected = projectedCompletions
      .map((message) {
        final public = normalizeTranscriptMessageForDisplay(
          message,
          retainMediaEvidence: true,
          retainUserMentionNote: true,
          retainProjectionState: true,
          retainAssistantToolCalls: true,
        );
        if (public == null) return null;
        final internal = Map<String, dynamic>.from(public);
        for (final key in _privateTranscriptProjectionKeys) {
          if (message.containsKey(key)) internal[key] = message[key];
        }
        return internal;
      })
      .whereType<Map<String, dynamic>>()
      .toList(growable: true);
  for (var index = 0; index < projected.length; index++) {
    final partial = projected[index][_legacyRecoveryPartialProjectionKey];
    if (partial is! Map<String, dynamic>) continue;
    final normalizedPartial = normalizeTranscriptMessageForDisplay(
      partial,
      retainMediaEvidence: true,
      retainProjectionState: true,
      retainAssistantToolCalls: true,
    );
    if (normalizedPartial != null && normalizedPartial['role'] == 'assistant') {
      projected.insert(index + 1, normalizedPartial);
      index += 1;
    }
  }
  return coalesceAssistantTurnsNewestFirst(
    _associateGeneratedImagesNewestFirst(projected),
  );
}

List<Map<String, dynamic>> _normalizedNewestFirst(
  Iterable<Map<String, dynamic>> chronological,
) => _associateGeneratedImagesNewestFirst(
  chronological
      .map(
        (message) => normalizeTranscriptMessageForDisplay(
          message,
          retainMediaEvidence: true,
          retainUserMentionNote: true,
        ),
      )
      .whereType<Map<String, dynamic>>()
      .toList(growable: false)
      .reversed
      .toList(growable: true),
);

const _generatedImagesMetadataKey = '_generatedImages';

String? _nonEmptyMetadataString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _toolCallId(
  Map<String, dynamic> value, {
  bool allowGenericId = false,
}) => _nonEmptyMetadataString(
  value['tool_call_id'] ??
      value['tool_id'] ??
      value['call_id'] ??
      (allowGenericId ? value['id'] : null),
);

String? _toolName(Map<String, dynamic> value) => _nonEmptyMetadataString(
  value['tool_name'] ?? value['name'] ?? value['tool'],
);

bool _isImageGenerateName(String? value) =>
    value?.trim().toLowerCase() == 'image_generate';

bool _isVideoGenerateName(String? value) =>
    value?.trim().toLowerCase() == 'video_generate';

bool _isGeneratedMediaProducerName(String? value) =>
    _isImageGenerateName(value) || _isVideoGenerateName(value);

Iterable<({String id, String name})> _messageToolCalls(
  Map<String, dynamic> message,
) sync* {
  final rawCalls = message['tool_calls'];
  if (rawCalls is! List) return;
  for (final raw in rawCalls) {
    if (raw is! Map) continue;
    final call = Map<String, dynamic>.from(raw);
    final function = call['function'];
    final functionMap = function is Map
        ? Map<String, dynamic>.from(function)
        : const <String, dynamic>{};
    final id = _toolCallId(call, allowGenericId: true);
    final name = _nonEmptyMetadataString(
      functionMap['name'] ?? call['name'] ?? call['tool_name'],
    );
    if (id != null && name != null) yield (id: id, name: name);
  }
}

Map<String, dynamic> _generatedImageMetadata(
  GeneratedImageReference reference,
  String toolCallId,
) => Map<String, dynamic>.unmodifiable({
  'kind': reference.kind.name,
  'source': reference.source,
  if (reference.basename != null) 'basename': reference.basename,
  'tool_call_id': toolCallId,
  if (reference.echoSources.isNotEmpty)
    'echo_sources': List<String>.unmodifiable(reference.echoSources),
});

Map<String, dynamic> _generatedVideoMetadata(
  GeneratedMediaReference reference,
  String toolCallId,
) => Map<String, dynamic>.unmodifiable({
  'media_kind': GeneratedMediaKind.video.name,
  'kind': reference.sourceKind.name,
  'source': reference.source,
  'tool_call_id': toolCallId,
  'echo_sources': List<String>.unmodifiable([reference.source]),
});

final RegExp _generatedImageBasenameRe = RegExp(
  r'^[A-Za-z0-9._-]+\.(?:png|jpe?g|webp)$',
  caseSensitive: false,
);

Map<String, dynamic>? _normalizedGeneratedImageMetadata(
  Map<String, dynamic> value,
) {
  final toolCallId = _nonEmptyMetadataString(value['tool_call_id']);
  if (toolCallId == null) return null;
  final rawKind = _nonEmptyMetadataString(value['kind']);
  final rawSource = _nonEmptyMetadataString(value['source']);
  final rawBasename = _nonEmptyMetadataString(value['basename']);
  final mediaKind = _nonEmptyMetadataString(value['media_kind']);

  if (mediaKind == GeneratedMediaKind.video.name) {
    if (rawSource == null) return null;
    final reference = GeneratedMediaService.referenceFromSource(rawSource);
    if (reference == null || reference.kind != GeneratedMediaKind.video) {
      return null;
    }
    final safeEchoSources = <String>{};
    final rawEchoSources = value['echo_sources'];
    if (rawEchoSources is List) {
      for (final rawEcho in rawEchoSources.whereType<String>()) {
        final echoReference = GeneratedMediaService.referenceFromSource(
          rawEcho,
        );
        if (echoReference != null &&
            echoReference.kind == GeneratedMediaKind.video) {
          safeEchoSources.add(echoReference.source);
        }
      }
    }
    return Map<String, dynamic>.unmodifiable({
      'media_kind': GeneratedMediaKind.video.name,
      'kind': reference.sourceKind.name,
      'source': reference.source,
      'tool_call_id': toolCallId,
      if (safeEchoSources.isNotEmpty)
        'echo_sources': List<String>.unmodifiable(safeEchoSources),
    });
  }

  late final GeneratedImageSourceKind kind;
  late final String source;
  String? basename;
  if (rawKind == GeneratedImageSourceKind.https.name) {
    if (rawSource == null) return null;
    final parsed = GeneratedImageService.imageReferencesFromResult({
      'success': true,
      'image': rawSource,
    });
    if (parsed.isEmpty ||
        parsed.single.kind != GeneratedImageSourceKind.https) {
      return null;
    }
    kind = GeneratedImageSourceKind.https;
    source = parsed.single.source;
  } else if (rawKind == null ||
      rawKind == GeneratedImageSourceKind.serverCache.name) {
    // Compatibilidad con snapshots previos a `kind`/`source`: un basename
    // válido siempre representaba el cache del servidor servido por Bridge.
    if (rawBasename == null ||
        !_generatedImageBasenameRe.hasMatch(rawBasename)) {
      return null;
    }
    kind = GeneratedImageSourceKind.serverCache;
    basename = rawBasename;
    // Public state addresses Bridge's cache by basename; never retain the
    // host/sandbox path that the tool returned.
    source = rawBasename;
  } else {
    return null;
  }

  final echoSources = value['echo_sources'];
  final safeEchoSources = <String>{};
  if (echoSources is List) {
    for (final rawEcho in echoSources.whereType<String>()) {
      final echo = rawEcho.trim();
      if (echo.isEmpty) continue;
      if (kind == GeneratedImageSourceKind.serverCache) {
        if (echo == basename) safeEchoSources.add(echo);
        continue;
      }
      final parsed = GeneratedImageService.imageReferencesFromResult({
        'success': true,
        'image': echo,
      });
      if (parsed.length == 1 &&
          parsed.single.kind == GeneratedImageSourceKind.https) {
        safeEchoSources.add(parsed.single.source);
      }
    }
  }
  return Map<String, dynamic>.unmodifiable({
    'kind': kind.name,
    'source': source,
    'basename': ?basename,
    'tool_call_id': toolCallId,
    if (safeEchoSources.isNotEmpty)
      'echo_sources': List<String>.unmodifiable(safeEchoSources),
  });
}

List<Map<String, dynamic>> _generatedImageMetadataOf(
  Map<String, dynamic> message,
) {
  final raw = message[_generatedImagesMetadataKey];
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map<Map<String, dynamic>>((value) => Map<String, dynamic>.from(value))
      .map(_normalizedGeneratedImageMetadata)
      .whereType<Map<String, dynamic>>()
      .toList(growable: false);
}

List<Map<String, dynamic>> _mergeGeneratedImageMetadata(
  Iterable<Map<String, dynamic>> current,
  Iterable<Map<String, dynamic>> incoming,
) {
  final merged = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final value in [...current, ...incoming]) {
    final normalized = _normalizedGeneratedImageMetadata(value);
    if (normalized == null) continue;
    final toolCallId = normalized['tool_call_id'] as String;
    final source = normalized['source'] as String;
    final mediaKind = normalized['media_kind']?.toString() ?? 'image';
    if (!seen.add('$mediaKind\u0000$toolCallId\u0000$source')) continue;
    merged.add(normalized);
  }
  return List<Map<String, dynamic>>.unmodifiable(merged);
}

/// Asocia resultados persistidos de `image_generate` con la siguiente
/// respuesta final del asistente. La entrada y la salida son newest-first; el
/// escaneo se hace cronológicamente para respetar tool_call → tool result →
/// assistant incluso cuando las filas llegan tras un backfill.
List<Map<String, dynamic>> _associateGeneratedImagesNewestFirst(
  List<Map<String, dynamic>> messages,
) {
  if (messages.isEmpty) return messages;
  final mediaCallNames = <String, String>{};
  final pending = <Map<String, dynamic>>[];
  final additions = <int, List<Map<String, dynamic>>>{};

  void collectToolResult(Map<String, dynamic> message) {
    final callId = _toolCallId(message);
    if (callId == null) return;
    final name = _toolName(message) ?? mediaCallNames[callId];
    final rawResult =
        message['result'] ?? message['output'] ?? message['content'];
    final isVideoResult =
        _isVideoGenerateName(name) ||
        (name == null && _looksLikeGeneratedVideoResult(rawResult));
    final videoReferences = isVideoResult
        ? GeneratedMediaService.referencesFromToolResult(
            'video_generate',
            rawResult,
          )
        : const <GeneratedMediaReference>[];
    if (videoReferences.isNotEmpty &&
        (mediaCallNames.containsKey(callId) ||
            _isVideoGenerateName(name) ||
            _looksLikeGeneratedVideoResult(rawResult))) {
      for (final reference in videoReferences) {
        pending.add(_generatedVideoMetadata(reference, callId));
      }
      return;
    }

    final references = GeneratedImageService.imageReferencesFromResult(
      rawResult,
    );
    if (references.isEmpty ||
        (!mediaCallNames.containsKey(callId) &&
            !_isImageGenerateName(name) &&
            !_looksLikeGeneratedImageResult(rawResult))) {
      return;
    }
    for (final reference in references) {
      pending.add(_generatedImageMetadata(reference, callId));
    }
  }

  for (var index = messages.length - 1; index >= 0; index--) {
    final message = messages[index];
    final role = message['role']?.toString().trim().toLowerCase();
    if (role == 'user' && message['_steer'] != true) {
      // Un resultado sin cierre pertenece como máximo al turno anterior. No
      // puede atravesar una nueva petición y terminar dentro de la respuesta
      // siguiente. Las correcciones `_steer` sí forman parte del mismo turno.
      pending.clear();
      mediaCallNames.clear();
      continue;
    }
    if (role == 'assistant') {
      final calls = _messageToolCalls(message).toList(growable: false);
      if (pending.isNotEmpty && calls.isEmpty && message['_pipeline'] != true) {
        additions[index] = List<Map<String, dynamic>>.of(pending);
        pending.clear();
      }
      for (final call in calls) {
        if (_isGeneratedMediaProducerName(call.name)) {
          mediaCallNames[call.id] = call.name;
        }
      }
      final nestedResults = message[assistantToolResultEvidenceKey];
      if (nestedResults is List) {
        for (final raw in nestedResults) {
          if (raw is Map) collectToolResult(Map<String, dynamic>.from(raw));
        }
        final content = message['content'];
        if (pending.isNotEmpty &&
            message['_pipeline'] != true &&
            content is String &&
            content.trim().isNotEmpty) {
          additions[index] = List<Map<String, dynamic>>.of(pending);
          pending.clear();
        }
      }
      continue;
    }
    if (role != 'tool') continue;
    collectToolResult(message);
  }

  final projected = List<Map<String, dynamic>>.of(messages);
  for (var index = 0; index < projected.length; index++) {
    if (!projected[index].containsKey(assistantToolResultEvidenceKey)) continue;
    final sanitized = Map<String, dynamic>.from(projected[index])
      ..remove(assistantToolResultEvidenceKey);
    projected[index] = Map<String, dynamic>.unmodifiable(sanitized);
  }
  if (additions.isEmpty) return projected;
  for (final entry in additions.entries) {
    final message = projected[entry.key];
    final merged = _mergeGeneratedImageMetadata(
      _generatedImageMetadataOf(message),
      entry.value,
    );
    if (merged.isEmpty) continue;
    projected[entry.key] = Map<String, dynamic>.unmodifiable({
      ...message,
      _generatedImagesMetadataKey: merged,
    });
  }
  return projected;
}

bool _looksLikeGeneratedVideoResult(Object? rawResult) {
  Object? decoded = rawResult;
  if (rawResult is String) {
    try {
      decoded = jsonDecode(rawResult);
    } catch (_) {
      return false;
    }
  }
  return decoded is Map &&
      decoded['success'] == true &&
      decoded['video'] is String;
}

bool _looksLikeGeneratedImageResult(Object? rawResult) {
  Object? decoded = rawResult;
  if (rawResult is String) {
    try {
      decoded = jsonDecode(rawResult);
    } catch (_) {
      return false;
    }
  }
  if (decoded is! Map || decoded['success'] != true) return false;
  return decoded.containsKey('host_image') ||
      decoded.containsKey('image') ||
      decoded.containsKey('images');
}

/// Identidad para deduplicar filas del transcript entre páginas.
///
/// Sin un id durable no existe evidencia de igualdad: dos filas con el mismo
/// rol/contenido pueden ser turnos legítimos distintos y deben conservarse.
bool _desktopSnapshotTranscriptIsComplete(DesktopSessionSnapshot snapshot) {
  if (!snapshot.messagesProvided ||
      !snapshot.messagesFullyParsed ||
      snapshot.hydrating ||
      !_desktopSnapshotIdentitiesAreUnambiguous(snapshot.messages)) {
    return false;
  }
  final expectedCount = snapshot.messageCount;
  return expectedCount == null || snapshot.messages.length == expectedCount;
}

bool _desktopSnapshotIdentitiesAreUnambiguous(
  Iterable<DesktopSessionMessage> messages,
) {
  final seen = <TranscriptMessageIdentity>[];
  for (final message in messages) {
    if (!message.identityAliasesConsistent) return false;
    final identity = _desktopSnapshotTranscriptIdentity(message);
    if (identity == null) continue;
    if (seen.any(identity.sharesExactCoordinate)) return false;
    seen.add(identity);
  }
  return true;
}

bool _fallbackExactlyMatchesDesktopSnapshot(
  List<Map<String, dynamic>> fallbackNewestFirst,
  DesktopSessionSnapshot snapshot,
) {
  if (snapshot.messages.isEmpty ||
      fallbackNewestFirst.length != snapshot.messages.length ||
      !_transcriptRowsHaveUnambiguousIdentityEvidence(fallbackNewestFirst) ||
      !_desktopSnapshotIdentitiesAreUnambiguous(snapshot.messages)) {
    return false;
  }
  for (var index = 0; index < fallbackNewestFirst.length; index++) {
    final fallbackIdentity = _transcriptMessageIdentity(
      fallbackNewestFirst[index],
    );
    final snapshotIdentity = _desktopSnapshotTranscriptIdentity(
      snapshot.messages[snapshot.messages.length - index - 1],
    );
    if (fallbackIdentity == null ||
        snapshotIdentity == null ||
        !fallbackIdentity.matches(snapshotIdentity)) {
      return false;
    }
  }
  return true;
}

bool _tailPageProvesTranscriptComplete(SessionMessagesPage page) {
  if (page.offset != 0 ||
      !page.messagesFullyParsed ||
      !page.paginationFullyParsed ||
      !_transcriptRowsHaveUnambiguousIdentityEvidence(page.messages)) {
    return false;
  }
  if (page.hasEarlier case final hasEarlier?) return !hasEarlier;
  final limit = page.limit;
  return limit == null || limit <= 0 || page.returned < limit;
}

TranscriptMessageIdentity? _transcriptMessageIdentity(
  Map<String, dynamic> message,
) => canonicalTranscriptIdentity(message);

DateTime? _transcriptTimestamp(Map<String, dynamic> message) {
  final value = message['timestamp'];
  if (value is! num || !value.isFinite || value < 0) return null;
  try {
    return DateTime.fromMicrosecondsSinceEpoch(
      (value.toDouble() * Duration.microsecondsPerSecond).round(),
      isUtc: true,
    );
  } on RangeError {
    return null;
  }
}

TranscriptMessageIdentity? _desktopSnapshotTranscriptIdentity(
  DesktopSessionMessage message,
) {
  if (!message.identityAliasesConsistent) return null;
  final identity = TranscriptMessageIdentity(
    messageId: message.stableId,
    rowId: message.rowId,
  );
  return identity.isDurable ? identity : null;
}

bool _identityCollectionContains(
  Iterable<TranscriptMessageIdentity> identities,
  TranscriptMessageIdentity candidate,
) => identities.any(candidate.matches);

bool _removeMatchingIdentities(
  List<TranscriptMessageIdentity> identities,
  TranscriptMessageIdentity candidate,
) {
  final overlaps = identities
      .where(candidate.sharesExactCoordinate)
      .toList(growable: false);
  if (overlaps.length != 1 || !candidate.matches(overlaps.single)) {
    return false;
  }
  return identities.remove(overlaps.single);
}

TranscriptMessageIdentity? _uniqueTranscriptIdentityMatch(
  TranscriptMessageIdentity candidate,
  Iterable<Map<String, dynamic>> transcript,
) {
  TranscriptMessageIdentity? found;
  for (final message in transcript) {
    if (!transcriptIdentityAliasesAreConsistent(message)) {
      if (transcriptIdentityAliasesShareExactCoordinate(message, candidate)) {
        return null;
      }
      continue;
    }
    final identity = _transcriptMessageIdentity(message);
    if (identity == null || !candidate.sharesExactCoordinate(identity)) {
      continue;
    }
    if (!candidate.matches(identity) || found != null) return null;
    found = identity;
  }
  final match = found;
  if (match == null) return null;

  // La página entrante puede declarar solo una coordenada. Verifica también
  // la otra coordenada de la fila visible enriquecida para no confirmar, por
  // ejemplo, (m1, 42) si el transcript contiene además (m2, 42).
  var overlaps = 0;
  for (final message in transcript) {
    if (!transcriptIdentityAliasesAreConsistent(message)) {
      if (transcriptIdentityAliasesShareExactCoordinate(message, match)) {
        return null;
      }
      continue;
    }
    final identity = _transcriptMessageIdentity(message);
    if (identity == null || !match.sharesExactCoordinate(identity)) continue;
    if (!match.matches(identity)) return null;
    overlaps++;
  }
  return overlaps == 1 ? match : null;
}

List<TranscriptMessageIdentity> _transcriptIdentities(
  Iterable<Map<String, dynamic>> messages,
) => <TranscriptMessageIdentity>[
  for (final message in messages) ?_transcriptMessageIdentity(message),
];

bool _hasDurableTranscriptIdentity(Map<String, dynamic> message) =>
    _transcriptMessageIdentity(message) != null;

bool _allTranscriptRowsHaveDurableIds(Iterable<Map<String, dynamic>> messages) {
  final seen = <TranscriptMessageIdentity>[];
  for (final message in messages) {
    final identity = _transcriptMessageIdentity(message);
    if (identity == null || seen.any(identity.sharesExactCoordinate)) {
      return false;
    }
    seen.add(identity);
  }
  return true;
}

bool _transcriptRowsHaveUnambiguousIdentityEvidence(
  Iterable<Map<String, dynamic>> messages,
) {
  final seen = <TranscriptMessageIdentity>[];
  for (final message in messages) {
    if (!transcriptIdentityAliasesAreConsistent(message)) return false;
    final identity = _transcriptMessageIdentity(message);
    if (identity == null) continue;
    if (seen.any(identity.sharesExactCoordinate)) return false;
    seen.add(identity);
  }
  return true;
}

bool _isKnownLocalTranscriptProjection(
  List<Map<String, dynamic>> newestFirst,
  int index,
) {
  final message = newestFirst[index];
  if (message['role'] == 'assistant_error' ||
      message['_steer'] == true ||
      message['_pipeline'] == true ||
      message['_desktopInterim'] == true ||
      message['_desktopSnapshotKind'] == 'inflight' ||
      message[_localCompactedTerminalProjectionKey] != null ||
      message['_cancelled'] == true ||
      message['_cancelledUser'] == true) {
    return true;
  }
  if (!isRealUserTurn(message) || index == 0) return false;
  final newer = newestFirst[index - 1];
  if (newer['role'] == 'assistant_error') {
    return (newer['_prompt'] ?? '').toString() ==
        (message['content'] ?? '').toString();
  }
  return newer['role'] == 'assistant' &&
      (newer['_pipeline'] == true ||
          newer['_desktopSnapshotKind'] == 'inflight');
}

bool _isLiveTranscriptProjection(Map<String, dynamic> message) =>
    message['_desktopSnapshotKind'] == 'inflight' ||
    message['_pipeline'] == true ||
    message['_optimistic'] == true;

Set<int> _liveUserProjectionIndexesRepresentedByRefreshedTail(
  List<Map<String, dynamic>> refreshedNewestFirst,
  List<Map<String, dynamic>> previousNewestFirst, {
  required bool refreshedTranscriptComplete,
  required bool currentTransportTerminalObserved,
}) {
  final liveUserIndexesNewestFirst = <int>[];
  TranscriptMessageIdentity? anchor;
  for (var index = 0; index < previousNewestFirst.length; index++) {
    final previous = previousNewestFirst[index];
    if (_isLiveTranscriptProjection(previous)) {
      if (previous['role'] == 'user' &&
          !_hasDurableTranscriptIdentity(previous)) {
        liveUserIndexesNewestFirst.add(index);
      }
      continue;
    }
    anchor = canonicalTranscriptIdentity(previous);
    // No cruza una fila durable-looking sin identidad: podría ser otro turno
    // legítimo con el mismo texto que el inflight observado.
    if (anchor == null) return const <int>{};
    break;
  }
  if (anchor == null || liveUserIndexesNewestFirst.isEmpty) {
    return const <int>{};
  }

  int? refreshedAnchorIndex;
  for (var index = 0; index < refreshedNewestFirst.length; index++) {
    final candidate = refreshedNewestFirst[index];
    if (!transcriptIdentityAliasesShareExactCoordinate(candidate, anchor)) {
      continue;
    }
    final identity = canonicalTranscriptIdentity(candidate);
    if (identity == null ||
        !identity.matches(anchor) ||
        refreshedAnchorIndex != null) {
      return const <int>{};
    }
    refreshedAnchorIndex = index;
  }
  if (refreshedAnchorIndex == null) return const <int>{};

  final anchorTurn = refreshedNewestFirst
      .sublist(0, refreshedAnchorIndex + 1)
      .reversed
      .toList(growable: false);
  final anchorCompletesDurableTurn =
      refreshedTranscriptComplete &&
      decideTerminalAuthority(
            chronological: anchorTurn,
            expectedUsers: 1,
            source: TerminalEvidenceSource.durableTranscript,
            sourceTranscriptComplete: true,
            transportTerminalObserved: false,
            transportTerminalIsError: false,
            compactionFenceActive: false,
            currentAuthorityFence: true,
            visibleAssistantTextPresent: false,
            allowLegacyDirectToolTerminal: true,
          ).kind ==
          TerminalAuthorityKind.authoritativeSuccess;
  final anchorHasTerminalProof =
      currentTransportTerminalObserved || anchorCompletesDurableTurn;
  // El ancla delimita lo ya conocido y solo puede acreditarse a sí misma si
  // el refresh trae su pareja terminal durable completa o el evento terminal
  // vigente ya cerró ese turno. En otro caso se conserva la proyección.
  final durableOpenInputs = refreshedNewestFirst
      .take(
        anchorHasTerminalProof
            ? refreshedAnchorIndex + 1
            : refreshedAnchorIndex,
      )
      .where(
        (message) =>
            isRealUserTurn(message) ||
            (message['role'] == 'user' && message['_steer'] == true),
      )
      .toList(growable: false)
      .reversed
      .toList(growable: false);
  if (durableOpenInputs.isEmpty ||
      durableOpenInputs.any(
        (message) => !_hasDurableTranscriptIdentity(message),
      )) {
    return const <int>{};
  }

  final liveUserIndexesChronological = liveUserIndexesNewestFirst.reversed
      .toList(growable: false);
  final sharedLength = math.min(
    durableOpenInputs.length,
    liveUserIndexesChronological.length,
  );
  for (var index = 0; index < sharedLength; index++) {
    final live = previousNewestFirst[liveUserIndexesChronological[index]];
    if (durableOpenInputs[index]['content']?.toString() !=
        live['content']?.toString()) {
      return const <int>{};
    }
  }
  if (durableOpenInputs.length > liveUserIndexesChronological.length &&
      durableOpenInputs
          .skip(liveUserIndexesChronological.length)
          .any((message) => message['_steer'] != true)) {
    return const <int>{};
  }

  // El contenido solo confirma el orden después de un ancla durable exacta y
  // única. Nunca se usa por sí mismo como identidad del turno.
  return Set<int>.unmodifiable(liveUserIndexesChronological.take(sharedLength));
}

int? _durableTranscriptCoverageCount(Iterable<Map<String, dynamic>> messages) {
  final identities = <TranscriptMessageIdentity>[];
  for (final message in messages) {
    if (_isLiveTranscriptProjection(message)) continue;
    final identity = _transcriptMessageIdentity(message);
    // Una fila durable sin identidad sigue ocupando una posición real del
    // transcript, pero no se puede comparar de forma segura con messageCount.
    // Ignorarla haría que 2 filas visibles pareciesen coincidir con count=1.
    if (identity == null || identities.any(identity.sharesExactCoordinate)) {
      return null;
    }
    identities.add(identity);
  }
  return identities.length;
}

/// Antepone una página de mensajes ANTERIORES a la lista viva (newest-first:
/// los más antiguos van al final), deduplicando filas ya presentes. El drift
/// de offsets (mensajes persistidos tras la hidratación) hace normal el
/// solape; conserva la identidad de referencia cuando no cambia nada.
List<Map<String, dynamic>> _mergeOlderTranscriptPage(
  List<Map<String, dynamic>> existingNewestFirst,
  List<Map<String, dynamic>> olderPageNewestFirst,
) {
  if (existingNewestFirst.isEmpty) return olderPageNewestFirst;
  if (olderPageNewestFirst.isEmpty) {
    return existingNewestFirst;
  }
  final existingIdentities = _transcriptIdentities(existingNewestFirst);
  final fresh = olderPageNewestFirst
      .where((message) {
        final identity = _transcriptMessageIdentity(message);
        if (identity == null) return true;
        final overlaps = existingIdentities
            .where(identity.sharesExactCoordinate)
            .toList(growable: false);
        if (overlaps.length == 1 && identity.matches(overlaps.single)) {
          return false;
        }
        return true;
      })
      .toList(growable: false);
  if (fresh.isEmpty) return existingNewestFirst;
  return <Map<String, dynamic>>[...existingNewestFirst, ...fresh];
}

@immutable
class CancelledTurnTombstone {
  const CancelledTurnTombstone({
    required this.content,
    this.anchorMessageId,
    this.anchorRowId,
    this.firstUser = false,
    this.cancelledMessageId,
    this.cancelledRowId,
    this.invalidated = false,
    this.createdAtMs,
  });

  final String content;
  final String? anchorMessageId;
  final int? anchorRowId;
  final bool firstUser;
  final String? cancelledMessageId;
  final int? cancelledRowId;
  final bool invalidated;
  final int? createdAtMs;

  bool get hasAnchorIdentity => anchorMessageId != null || anchorRowId != null;
  bool get hasTargetIdentity =>
      cancelledMessageId != null || cancelledRowId != null;

  bool matchesContent(String candidate) => content == candidate;

  CancelledTurnTombstone stamped(int timestampMs) => CancelledTurnTombstone(
    content: content,
    anchorMessageId: anchorMessageId,
    anchorRowId: anchorRowId,
    firstUser: firstUser,
    cancelledMessageId: cancelledMessageId,
    cancelledRowId: cancelledRowId,
    invalidated: invalidated,
    createdAtMs: createdAtMs ?? timestampMs,
  );

  CancelledTurnTombstone bindToMessage({String? messageId, int? rowId}) =>
      CancelledTurnTombstone(
        content: content,
        anchorMessageId: anchorMessageId,
        anchorRowId: anchorRowId,
        firstUser: firstUser,
        cancelledMessageId: cancelledMessageId ?? messageId,
        cancelledRowId: cancelledRowId ?? rowId,
        invalidated: false,
        createdAtMs: createdAtMs,
      );

  CancelledTurnTombstone invalidate() => CancelledTurnTombstone(
    content: content,
    anchorMessageId: anchorMessageId,
    anchorRowId: anchorRowId,
    firstUser: firstUser,
    cancelledMessageId: cancelledMessageId,
    cancelledRowId: cancelledRowId,
    invalidated: true,
    createdAtMs: createdAtMs,
  );

  Map<String, dynamic> toJson() => {
    'content': content,
    'anchor_message_id': anchorMessageId,
    'anchor_row_id': anchorRowId,
    'first_user': firstUser,
    'cancelled_message_id': cancelledMessageId,
    'cancelled_row_id': cancelledRowId,
    'invalidated': invalidated,
    'created_at_ms': createdAtMs,
  };

  static CancelledTurnTombstone? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final content = raw['content'];
    final anchor = raw['anchor_message_id'];
    final anchorRowId = raw['anchor_row_id'];
    final firstUser = raw['first_user'];
    final cancelledMessageId = raw['cancelled_message_id'];
    final cancelledRowId = raw['cancelled_row_id'];
    final invalidated = raw['invalidated'];
    final createdAtMs = raw['created_at_ms'];
    final durableAnchor = anchor is String && anchor.trim().isNotEmpty
        ? anchor
        : null;
    final durableCancelledMessageId =
        cancelledMessageId is String && cancelledMessageId.isNotEmpty
        ? cancelledMessageId
        : null;
    final durableAnchorRowId = anchorRowId is int && anchorRowId > 0
        ? anchorRowId
        : null;
    final durableCancelledRowId = cancelledRowId is int && cancelledRowId > 0
        ? cancelledRowId
        : null;
    final hasAnchor = durableAnchor != null || durableAnchorRowId != null;
    final hasTarget =
        durableCancelledMessageId != null || durableCancelledRowId != null;
    if (content is! String ||
        content.isEmpty ||
        firstUser is! bool ||
        (!hasAnchor && !firstUser && !hasTarget) ||
        (hasAnchor && firstUser) ||
        (invalidated != null && invalidated is! bool) ||
        createdAtMs is! int ||
        createdAtMs < 0) {
      return null;
    }
    return CancelledTurnTombstone(
      content: content,
      anchorMessageId: durableAnchor,
      anchorRowId: durableAnchorRowId,
      firstUser: firstUser,
      cancelledMessageId: durableCancelledMessageId,
      cancelledRowId: durableCancelledRowId,
      invalidated: invalidated == true,
      createdAtMs: createdAtMs,
    );
  }
}

bool _exactIdentityPairsMatch({
  required String? leftMessageId,
  required int? leftRowId,
  required String? rightMessageId,
  required int? rightRowId,
}) {
  if (leftMessageId != null &&
      rightMessageId != null &&
      leftMessageId != rightMessageId) {
    return false;
  }
  if (leftRowId != null && rightRowId != null && leftRowId != rightRowId) {
    return false;
  }
  return (leftMessageId != null && leftMessageId == rightMessageId) ||
      (leftRowId != null && leftRowId == rightRowId);
}

bool _sameCancelledTurnIdentity(
  CancelledTurnTombstone left,
  CancelledTurnTombstone right,
) {
  if (left.content != right.content || left.firstUser != right.firstUser) {
    return false;
  }
  if (left.hasAnchorIdentity != right.hasAnchorIdentity) return false;
  if (left.hasAnchorIdentity) {
    return _exactIdentityPairsMatch(
      leftMessageId: left.anchorMessageId,
      leftRowId: left.anchorRowId,
      rightMessageId: right.anchorMessageId,
      rightRowId: right.anchorRowId,
    );
  }
  if (left.firstUser) return true;
  return _exactIdentityPairsMatch(
    leftMessageId: left.cancelledMessageId,
    leftRowId: left.cancelledRowId,
    rightMessageId: right.cancelledMessageId,
    rightRowId: right.cancelledRowId,
  );
}

class CancelledTurnTombstoneStore {
  CancelledTurnTombstoneStore({
    required Future<String?> Function() read,
    required Future<void> Function(String value) write,
    int Function()? nowMs,
  }) : _read = read,
       _write = write,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  factory CancelledTurnTombstoneStore.secure({
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
  }) => CancelledTurnTombstoneStore(
    read: () => secureStorage.read(key: _storageKey),
    write: (value) => secureStorage.write(key: _storageKey, value: value),
  );

  static const _storageKey = 'cancelled_turn_tombstones_v2';

  final Future<String?> Function() _read;
  final Future<void> Function(String value) _write;
  final int Function() _nowMs;
  Future<void> _writeTail = Future<void>.value();
  Map<String, dynamic> _root = <String, dynamic>{};
  bool _initialized = false;

  String _scopeKey({
    required String connectionId,
    required String profile,
    required String sessionId,
    String generation = '',
  }) => jsonEncode([connectionId, generation, profile, sessionId]);

  bool _scopeKeyIsValid(Object? raw) {
    if (raw is! String) return false;
    try {
      final parts = jsonDecode(raw);
      return parts is List &&
          parts.length == 4 &&
          parts.every((part) => part is String) &&
          (parts[0] as String).isNotEmpty &&
          (parts[2] as String).isNotEmpty &&
          (parts[3] as String).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> initialize() async {
    if (_initialized) return;
    final raw = await _read();
    final decoded = raw == null || raw.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('invalid cancelled-turn tombstone root');
    }
    final candidate = <String, dynamic>{};
    for (final entry in decoded.entries) {
      if (!_scopeKeyIsValid(entry.key)) continue;
      final value = entry.value;
      // Algunas QA anteriores escribieron un único tombstone directamente en
      // el scope. Migra esa forma sin tocar todavía el payload cifrado.
      final rawItems = value is List
          ? List<Object?>.from(value)
          : value is Map
          ? <Object?>[value]
          : null;
      // Un scope ilegible no puede aplicarse con seguridad. Se omite solo en
      // memoria para no bloquear el arranque ni destruir los scopes válidos;
      // initialize() no sobrescribe el almacenamiento cifrado.
      if (rawItems != null &&
          rawItems.every(
            (item) => CancelledTurnTombstone.fromJson(item) != null,
          )) {
        candidate[entry.key as String] = rawItems;
      }
    }
    _root = candidate;
    _initialized = true;
  }

  List<CancelledTurnTombstone> load({
    required String connectionId,
    required String profile,
    required String sessionId,
    String generation = '',
  }) {
    if (!_initialized) {
      throw StateError('cancelled-turn tombstone store not initialized');
    }
    final raw =
        _root[_scopeKey(
          connectionId: connectionId,
          profile: profile,
          sessionId: sessionId,
          generation: generation,
        )];
    if (raw is! List) return const [];
    return raw
        .map(CancelledTurnTombstone.fromJson)
        .whereType<CancelledTurnTombstone>()
        .toList(growable: false);
  }

  List<CancelledTurnTombstone> loadAliases({
    required String connectionId,
    required String profile,
    required Iterable<String> sessionIds,
    String generation = '',
  }) {
    final restored = <CancelledTurnTombstone>[];
    for (final sessionId in sessionIds.where((id) => id.isNotEmpty).toSet()) {
      for (final tombstone in load(
        connectionId: connectionId,
        profile: profile,
        sessionId: sessionId,
        generation: generation,
      )) {
        final existingIndex = restored.indexWhere(
          (item) => _sameCancelledTurnIdentity(item, tombstone),
        );
        if (existingIndex < 0) {
          restored.add(tombstone);
          continue;
        }
        final existing = restored[existingIndex];
        if ((!existing.invalidated && tombstone.invalidated) ||
            (existing.invalidated == tombstone.invalidated &&
                !existing.hasTargetIdentity &&
                tombstone.hasTargetIdentity)) {
          restored[existingIndex] = tombstone;
        }
      }
    }
    return List<CancelledTurnTombstone>.unmodifiable(restored);
  }

  Future<void> add({
    required String connectionId,
    required String profile,
    required String sessionId,
    required CancelledTurnTombstone tombstone,
    String generation = '',
  }) => addAliases(
    connectionId: connectionId,
    profile: profile,
    sessionIds: [sessionId],
    tombstone: tombstone,
    generation: generation,
  );

  Future<void> addAliases({
    required String connectionId,
    required String profile,
    required Iterable<String> sessionIds,
    required CancelledTurnTombstone tombstone,
    String generation = '',
  }) {
    final exactSessionIds = sessionIds.where((id) => id.isNotEmpty).toSet();
    if (exactSessionIds.isEmpty) {
      return Future<void>.error(
        ArgumentError.value(sessionIds, 'sessionIds', 'must not be empty'),
      );
    }
    final operation = _writeTail.then((_) async {
      if (!_initialized) await initialize();
      final candidate = Map<String, dynamic>.from(_root);
      final durable = tombstone.stamped(_nowMs());
      for (final sessionId in exactSessionIds) {
        final scope = _scopeKey(
          connectionId: connectionId,
          profile: profile,
          sessionId: sessionId,
          generation: generation,
        );
        final current = candidate[scope] is List
            ? List<Object?>.from(candidate[scope] as List)
            : <Object?>[];
        current.removeWhere((raw) {
          final item = CancelledTurnTombstone.fromJson(raw);
          return item != null && _sameCancelledTurnIdentity(item, durable);
        });
        current.add(durable.toJson());
        candidate[scope] = current;
      }
      await _write(jsonEncode(candidate));
      _root = candidate;
    });
    _writeTail = operation.catchError((_) {});
    return operation;
  }

  Future<int> removeSession({
    required String connectionId,
    required String profile,
    required String sessionId,
  }) => _removeScopes((scope) {
    try {
      final parts = jsonDecode(scope);
      return parts is List &&
          parts.length == 4 &&
          parts[0] == connectionId &&
          parts[2] == profile &&
          parts[3] == sessionId;
    } catch (_) {
      return false;
    }
  });

  Future<int> removeConnection(String connectionId) => _removeScopes((scope) {
    try {
      final parts = jsonDecode(scope);
      return parts is List && parts.isNotEmpty && parts.first == connectionId;
    } catch (_) {
      return false;
    }
  });

  Future<int> _removeScopes(bool Function(String scope) matches) {
    var removed = 0;
    final operation = _writeTail.then((_) async {
      if (!_initialized) await initialize();
      final candidate = Map<String, dynamic>.from(_root);
      for (final scope in candidate.keys.toList(growable: false)) {
        if (!matches(scope)) continue;
        final value = candidate.remove(scope);
        if (value is List) removed += value.length;
      }
      if (removed == 0) return;
      await _write(jsonEncode(candidate));
      _root = candidate;
    });
    _writeTail = operation.catchError((_) {});
    return operation.then((_) => removed);
  }
}

/// Reaplica los tombstones locales de Stop sobre un transcript canónico.
///
/// Las listas están en orden newest-first. El transcript entrante es la
/// autoridad: un tombstone sin evidencia de identidad se ignora en esa ventana,
/// nunca sustituye el transcript por [existingNewestFirst]. Para cada usuario
/// detenido identificado elimina exclusivamente el bloque de respuesta situado
/// entre ese usuario y el turno de usuario posterior; así una respuesta que el
/// servidor terminó mientras el móvil estaba offline no reaparece al
/// reconciliar, sin tocar turnos nuevos. [incomingTranscriptComplete] debe ser
/// evidencia explícita de que la ventana alcanza el inicio absoluto antes de
/// proyectar un tombstone `firstUser` sin ancla.
@visibleForTesting
List<Map<String, dynamic>> projectCancelledTurnTombstones({
  required List<Map<String, dynamic>> existingNewestFirst,
  required List<Map<String, dynamic>> incomingNewestFirst,
  required bool incomingTranscriptComplete,
  List<CancelledTurnTombstone> durableTombstones = const [],
}) {
  if (durableTombstones.isEmpty) return incomingNewestFirst;

  final projected = incomingNewestFirst
      .map((message) => Map<String, dynamic>.of(message))
      .toList();
  for (final tombstone in durableTombstones) {
    var userIndex = _cancelledTurnUserIndex(
      projected,
      tombstone,
      incomingTranscriptComplete: incomingTranscriptComplete,
    );
    if (userIndex < 0) continue;

    var newerUserIndex = -1;
    for (var index = userIndex - 1; index >= 0; index--) {
      if (isRealUserTurn(projected[index])) {
        newerUserIndex = index;
        break;
      }
    }
    final responseStart = newerUserIndex + 1;
    if (responseStart < userIndex) {
      final preservedMetadata = projected
          .sublist(responseStart, userIndex)
          .where((message) => message['role'] != 'assistant')
          .toList(growable: false);
      projected.replaceRange(responseStart, userIndex, preservedMetadata);
      userIndex = responseStart + preservedMetadata.length;
    }
    projected[userIndex] = {...projected[userIndex], '_cancelledUser': true};
  }
  return projected;
}

enum _TranscriptIdentityResolutionKind { absent, unique, conflicting }

typedef _TranscriptIdentityResolution = ({
  _TranscriptIdentityResolutionKind kind,
  int index,
});

bool _rawMessageSharesRequestedCoordinate(
  Map<String, dynamic> message,
  TranscriptMessageIdentity requested,
) {
  if (requested.messageId != null) {
    for (final key in const ['_desktopMessageId', 'message_id', 'id']) {
      if (message[key] == requested.messageId) return true;
    }
  }
  if (requested.rowId != null) {
    for (final key in const ['_desktopRowId', 'row_id', '_row_id', 'id']) {
      if (message[key] == requested.rowId) return true;
    }
  }
  return false;
}

_TranscriptIdentityResolution _resolveTranscriptIdentity(
  List<Map<String, dynamic>> newestFirst, {
  required String? messageId,
  required int? rowId,
  required bool Function(Map<String, dynamic> message) accepts,
}) {
  final requested = TranscriptMessageIdentity(
    messageId: messageId,
    rowId: rowId,
  );
  if (!requested.isDurable) {
    return (kind: _TranscriptIdentityResolutionKind.absent, index: -1);
  }
  var found = -1;
  for (var index = 0; index < newestFirst.length; index++) {
    final message = newestFirst[index];
    if (!accepts(message)) continue;
    final candidate = _transcriptMessageIdentity(message);
    if (candidate == null) {
      if (!transcriptIdentityAliasesAreConsistent(message) &&
          _rawMessageSharesRequestedCoordinate(message, requested)) {
        return (kind: _TranscriptIdentityResolutionKind.conflicting, index: -1);
      }
      continue;
    }
    if (!requested.sharesExactCoordinate(candidate)) {
      continue;
    }
    // Una coordenada común con la otra coordenada contradictoria no es una
    // coincidencia parcial: invalida toda la búsqueda.
    if (!requested.matches(candidate) || found >= 0) {
      return (kind: _TranscriptIdentityResolutionKind.conflicting, index: -1);
    }
    found = index;
  }
  return found < 0
      ? (kind: _TranscriptIdentityResolutionKind.absent, index: -1)
      : (kind: _TranscriptIdentityResolutionKind.unique, index: found);
}

int _cancelledTurnUserIndex(
  List<Map<String, dynamic>> newestFirst,
  CancelledTurnTombstone tombstone, {
  required bool incomingTranscriptComplete,
}) {
  if (tombstone.invalidated) return -1;
  if (tombstone.hasTargetIdentity) {
    final target = _resolveTranscriptIdentity(
      newestFirst,
      messageId: tombstone.cancelledMessageId,
      rowId: tombstone.cancelledRowId,
      accepts: (message) =>
          isRealUserTurn(message) && !_isLiveTranscriptProjection(message),
    );
    if (target.kind == _TranscriptIdentityResolutionKind.unique) {
      return target.index;
    }
    if (target.kind == _TranscriptIdentityResolutionKind.conflicting ||
        !tombstone.hasAnchorIdentity) {
      return -1;
    }
    // Algunas superficies exponen solo message_id y otras solo row_id. Si el
    // target enriquecido no está representado en esta proyección, el ancla
    // original sigue siendo una dirección durable válida para re-enlazarlo.
  }
  if (tombstone.firstUser) {
    // Un tombstone sin ancla solo identifica al primer usuario absoluto. En
    // una cola paginada, el usuario más antiguo visible no prueba esa
    // identidad y no debe suprimirse por coincidencia de texto.
    if (!incomingTranscriptComplete) return -1;
    for (var index = newestFirst.length - 1; index >= 0; index--) {
      final message = newestFirst[index];
      if (!isRealUserTurn(message) || _isLiveTranscriptProjection(message)) {
        continue;
      }
      if (canonicalTranscriptMessageId(message) == null &&
          canonicalTranscriptRowId(message) == null) {
        return -1;
      }
      return tombstone.matchesContent((message['content'] ?? '').toString())
          ? index
          : -1;
    }
    return -1;
  }

  final anchor = _resolveTranscriptIdentity(
    newestFirst,
    messageId: tombstone.anchorMessageId,
    rowId: tombstone.anchorRowId,
    accepts: (message) => !_isLiveTranscriptProjection(message),
  );
  if (anchor.kind != _TranscriptIdentityResolutionKind.unique) return -1;
  for (var index = anchor.index - 1; index >= 0; index--) {
    final message = newestFirst[index];
    if (!isRealUserTurn(message)) continue;
    if (_isLiveTranscriptProjection(message) ||
        (canonicalTranscriptMessageId(message) == null &&
            canonicalTranscriptRowId(message) == null)) {
      return -1;
    }
    return tombstone.matchesContent((message['content'] ?? '').toString())
        ? index
        : -1;
  }
  return -1;
}

bool _sameTranscriptProjection(
  List<Map<String, dynamic>> left,
  List<Map<String, dynamic>> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!_artifactValueEquals(left[index], right[index])) return false;
  }
  return true;
}

String _artifactEntryIdentity(String? stableId, int ordinal) =>
    stableId == null ? 'ordinal:$ordinal' : 'message:$stableId';

bool _sameArtifactTranscript(
  List<ArtifactTranscriptEntry> current,
  List<ArtifactTranscriptEntry> previous,
) {
  for (var index = 0; index < current.length; index++) {
    final candidate = current[index];
    final prior = previous[index];
    if (candidate.messageOrdinal != prior.messageOrdinal ||
        candidate.stableMessageId != prior.stableMessageId ||
        !_sameArtifactMessage(candidate.message, prior.message)) {
      return false;
    }
  }
  return true;
}

bool _sameArtifactMessage(
  DesktopSessionMessage left,
  DesktopSessionMessage right,
) =>
    left.stableId == right.stableId &&
    left.role == right.role &&
    _artifactValueEquals(left.content, right.content) &&
    _artifactValueEquals(left.context, right.context) &&
    _artifactValueEquals(left.artifactContainers, right.artifactContainers);

bool _artifactValueEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_artifactValueEquals(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_artifactValueEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}

/// Propietario de la evidencia local mientras un turno vive fuera de la ruta.
/// La escritura `submitting` siempre termina antes de tocar el transporte; un
/// fallo ahí bloquea el request. Un corte posterior queda ambiguo y nunca se
/// degrada a «no enviado».
class ActiveTurnDelivery {
  ActiveTurnDelivery({
    required PreparedTurn prepared,
    required TurnOutboxPersistence store,
    int Function()? nowMs,
    ValueChanged<List<AttachmentDraft>>? onAttachmentsChanged,
  }) : _current = prepared,
       _store = store,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (onAttachmentsChanged != null) {
      _attachmentListeners.add(onAttachmentsChanged);
    }
    // Al reconstruir una entrega desde la outbox también hay que reconstruir
    // sus fronteras internas. De lo contrario un accepted/running restaurado
    // recibe el terminal real, pero se niega a borrarse porque el nuevo objeto
    // olvidó que ya existía ACK antes del process death.
    _transportStarted = switch (prepared.state) {
      PreparedTurnState.prepared ||
      PreparedTurnState.failedBeforeAcceptance => false,
      PreparedTurnState.submitting ||
      PreparedTurnState.accepted ||
      PreparedTurnState.running ||
      PreparedTurnState.ambiguous ||
      PreparedTurnState.terminal => true,
    };
    _acknowledged = switch (prepared.state) {
      PreparedTurnState.accepted ||
      PreparedTurnState.running ||
      PreparedTurnState.terminal => true,
      PreparedTurnState.prepared ||
      PreparedTurnState.submitting ||
      PreparedTurnState.ambiguous ||
      PreparedTurnState.failedBeforeAcceptance => false,
    };
  }

  final TurnOutboxPersistence _store;
  final int Function() _nowMs;
  final Set<ValueChanged<List<AttachmentDraft>>> _attachmentListeners = {};
  PreparedTurn _current;
  bool _transportStarted = false;
  bool _acknowledged = false;
  bool _discarded = false;
  bool _persistenceFailed = false;
  Future<void> _mutationTail = Future<void>.value();

  PreparedTurn get current => _current;
  bool get transportStarted => _transportStarted;
  bool get acknowledged => _acknowledged;
  bool get discarded => _discarded;
  bool get persistenceFailed => _persistenceFailed;

  /// Fija el orden durable antes de la primera escritura de una admisión.
  /// Nunca reordena un turno restaurado ni uno cuyo transporte ya empezó.
  bool assignQueueOrder(int queueOrder) {
    if (_discarded ||
        queueOrder < 0 ||
        _transportStarted ||
        _current.queueOrder != null) {
      return _current.queueOrder == queueOrder;
    }
    _current = _current.copyWith(queueOrder: queueOrder);
    return true;
  }

  Future<bool> persistPrepared() => _serializeMutation(() async {
    if (_discarded || _transportStarted || _acknowledged) return false;
    try {
      await _store.save(_current);
      return true;
    } catch (_) {
      _persistenceFailed = true;
      return false;
    }
  });

  Future<bool> updatePreparedText(String text) => _serializeMutation(() async {
    final normalized = text.trim();
    if (_discarded ||
        _transportStarted ||
        _acknowledged ||
        normalized.isEmpty) {
      return false;
    }
    if (_current.text == normalized) return true;
    String updateProjection(String source) => source.startsWith(_current.text)
        ? '$normalized${source.substring(_current.text.length)}'
        : normalized;
    final mentions = BotMentionRoster.shared
        .resolver(_current.connectionId, _current.profile)
        .resolve(normalized);
    final next = _current.copyWith(
      updatedAtMs: _nowMs(),
      mentions: List.unmodifiable(mentions),
      mentionAnnotation: buildBotMentionAnnotation(mentions),
      text: normalized,
      fullText: updateProjection(_current.fullText),
      desktopText: _current.desktopText == null
          ? null
          : updateProjection(_current.desktopText!),
    );
    try {
      await _store.save(next);
      _current = next;
      return true;
    } catch (_) {
      _persistenceFailed = true;
      return false;
    }
  });

  Future<bool> discardPrepared() => _serializeMutation(() async {
    if (_discarded) return true;
    if (_transportStarted || _acknowledged) return false;
    try {
      await _store.delete(_current);
      return true;
    } catch (_) {
      _persistenceFailed = true;
      return false;
    }
  });

  /// Cancela una entrega aún no enviada sin depender del borrado físico.
  /// El tombstone durable es la frontera de seguridad; delete solo compacta.
  Future<bool> markPreparedTerminalAndDelete() => _serializeMutation(() async {
    if (_discarded) return true;
    if (_transportStarted || _acknowledged) return false;
    if (_current.state == PreparedTurnState.terminal) return true;
    final terminal = _current.copyWith(
      updatedAtMs: _nowMs(),
      state: PreparedTurnState.terminal,
    );
    try {
      await _store.save(terminal);
    } catch (_) {
      _persistenceFailed = true;
      return false;
    }
    _current = terminal;
    try {
      await _store.delete(terminal);
    } catch (_) {
      _persistenceFailed = true;
    }
    return true;
  });

  /// Retira un rechazo demostrado y revoca este productor exacto.
  ///
  /// La implementación de producción persiste primero un tombstone; el flag
  /// local corta además callbacks que ya estaban reteniendo este objeto. Stores
  /// de prueba antiguos conservan un fallback a delete, sin prometer durabilidad.
  Future<bool> discardFailedBeforeAcceptance() => _serializeMutation(() async {
    if (_discarded) return true;
    if (_acknowledged ||
        _current.state != PreparedTurnState.failedBeforeAcceptance ||
        !_current.restoresComposer) {
      return false;
    }
    try {
      final store = _store;
      final discarded = store is FailedPreparedTurnDiscardPersistence
          ? await (store as FailedPreparedTurnDiscardPersistence)
                .discardFailedBeforeAcceptance(_current)
          : await (() async {
              await store.delete(_current);
              return true;
            })();
      if (!discarded) return false;
      _discarded = true;
      _transportStarted = false;
      return true;
    } catch (_) {
      _persistenceFailed = true;
      return false;
    }
  });

  void addAttachmentListener(
    ValueChanged<List<AttachmentDraft>> listener, {
    bool notifyImmediately = false,
  }) {
    _attachmentListeners.add(listener);
    if (notifyImmediately) {
      listener(List<AttachmentDraft>.unmodifiable(_current.attachments));
    }
  }

  void removeAttachmentListener(ValueChanged<List<AttachmentDraft>> listener) {
    _attachmentListeners.remove(listener);
  }

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  void _notifyAttachments() {
    final snapshot = List<AttachmentDraft>.unmodifiable(_current.attachments);
    for (final listener in _attachmentListeners.toList(growable: false)) {
      try {
        listener(snapshot);
      } catch (_) {
        // La proyección visual nunca gobierna la evidencia persistida.
      }
    }
  }

  int _attachmentIndex(String localId) =>
      _current.attachments.indexWhere((item) => item.localId == localId);

  PreparedTurn _withAttachment(int index, AttachmentDraft attachment) {
    final nextAttachments = List<AttachmentDraft>.of(_current.attachments);
    nextAttachments[index] = attachment;
    return _current.copyWith(
      updatedAtMs: _nowMs(),
      attachments: nextAttachments,
    );
  }

  Future<bool> beginTransport(PreparedTurnTransport transport) =>
      _serializeMutation(() async {
        if (_discarded) return false;
        if (_transportStarted) return true;
        final next = _current.copyWith(
          updatedAtMs: _nowMs(),
          transport: transport,
          state: PreparedTurnState.submitting,
        );
        try {
          await _store.save(next);
          _current = next;
          _transportStarted = true;
          return true;
        } catch (_) {
          _persistenceFailed = true;
          return false;
        }
      });

  Future<AttachmentDraft?> beginAttachmentUpload(
    String localId, {
    required String remoteSessionId,
    required AttachmentRemoteTransport transport,
  }) => _serializeMutation(() async {
    if (_discarded) return null;
    final index = _attachmentIndex(localId);
    if (index < 0) return null;
    final current = _current.attachments[index];
    if (current.uploadState == AttachmentUploadState.removed) return null;
    final rebound = current.resetForRemoteOwner(
      remoteSessionId: remoteSessionId,
      transport: transport,
    );
    if (rebound.isAttachedTo(remoteSessionId, transport: transport)) {
      return rebound;
    }
    if (rebound.uploadState == AttachmentUploadState.uploading &&
        rebound.remoteSessionId == remoteSessionId &&
        rebound.remoteTransport == transport) {
      return rebound;
    }
    final uploading = rebound.copyWith(
      uploadState: AttachmentUploadState.uploading,
      attempt: rebound.attempt + 1,
      errorKind: null,
      remoteRef: null,
      remoteSessionId: remoteSessionId,
      remoteTransport: transport,
    );
    final next = _withAttachment(index, uploading);
    try {
      await _store.save(next);
      _current = next;
      _notifyAttachments();
      return uploading;
    } catch (_) {
      _persistenceFailed = true;
      return null;
    }
  });

  Future<bool> markAttachmentAttached(
    String localId, {
    required int attempt,
    required String remoteSessionId,
    required AttachmentRemoteTransport transport,
    required String remoteRef,
  }) => _serializeMutation(() async {
    if (_discarded) return false;
    if (remoteRef.isEmpty) return false;
    final index = _attachmentIndex(localId);
    if (index < 0) return false;
    final current = _current.attachments[index];
    if (!current.acceptsCallback(localId: localId, attempt: attempt) ||
        current.remoteSessionId != remoteSessionId ||
        current.remoteTransport != transport) {
      return false;
    }
    final attached = current.copyWith(
      uploadState: AttachmentUploadState.attached,
      errorKind: null,
      remoteRef: remoteRef,
    );
    final next = _withAttachment(index, attached);
    try {
      await _store.save(next);
      _current = next;
      _notifyAttachments();
      return true;
    } catch (_) {
      _persistenceFailed = true;
      // El caller revoca la asociación remota. No conservar en memoria una ref
      // que ya fue detached: un retry en este mismo proceso debe subir de nuevo.
      final failed = current.copyWith(
        uploadState: AttachmentUploadState.error,
        errorKind: AttachmentErrorKind.persistence,
        remoteRef: null,
      );
      _current = _withAttachment(index, failed);
      _notifyAttachments();
      return false;
    }
  });

  Future<bool> markAttachmentFailed(
    String localId, {
    required int attempt,
    required AttachmentErrorKind errorKind,
  }) => _serializeMutation(() async {
    if (_discarded) return false;
    final index = _attachmentIndex(localId);
    if (index < 0) return false;
    final current = _current.attachments[index];
    if (!current.acceptsCallback(localId: localId, attempt: attempt)) {
      return false;
    }
    final failed = current.copyWith(
      uploadState: AttachmentUploadState.error,
      errorKind: errorKind,
      remoteRef: null,
    );
    final next = _withAttachment(index, failed);
    _current = next;
    _notifyAttachments();
    try {
      await _store.save(next);
      return true;
    } catch (_) {
      _persistenceFailed = true;
      return false;
    }
  });

  /// Persiste primero el tombstone. Devuelve el item previo para que el owner
  /// del transporte pueda ejecutar un detach best-effort si existe.
  Future<AttachmentDraft?> removeAttachment(String localId) =>
      _serializeMutation(() async {
        if (_discarded) return null;
        final index = _attachmentIndex(localId);
        if (index < 0) return null;
        final current = _current.attachments[index];
        if (current.uploadState == AttachmentUploadState.removed) return null;
        final removed = current.copyWith(
          uploadState: AttachmentUploadState.removed,
          attempt: current.attempt + 1,
          errorKind: null,
        );
        final next = _withAttachment(index, removed);
        _current = next;
        _notifyAttachments();
        try {
          await _store.save(next);
        } catch (_) {
          _persistenceFailed = true;
        }
        return current;
      });

  Future<bool> retryAttachment(String localId) => _serializeMutation(() async {
    if (_discarded) return false;
    final index = _attachmentIndex(localId);
    if (index < 0) return false;
    final current = _current.attachments[index];
    if (current.uploadState != AttachmentUploadState.error) return false;
    final pending = current.copyWith(
      uploadState: AttachmentUploadState.pending,
      errorKind: null,
      remoteRef: null,
      remoteSessionId: null,
      remoteTransport: null,
    );
    final next = _withAttachment(index, pending);
    _current = next;
    _notifyAttachments();
    try {
      await _store.save(next);
      return true;
    } catch (_) {
      _persistenceFailed = true;
      return false;
    }
  });

  Future<void> waitForAttachmentMutations() => _mutationTail;

  Future<void> markAccepted() => _serializeMutation(() async {
    if (_discarded) return;
    _acknowledged = true;
    final next = _current.copyWith(
      updatedAtMs: _nowMs(),
      state: PreparedTurnState.accepted,
    );
    _current = next;
    try {
      await _store.save(next);
    } catch (_) {
      // El ACK es verdad aunque Keystore falle. La UI no debe ofrecer este lote
      // como no enviado ni volver a tocar el transporte.
      _persistenceFailed = true;
    }
  });

  Future<void> markRunning() => _serializeMutation(() async {
    if (_discarded) return;
    if (!_acknowledged || _current.state == PreparedTurnState.running) return;
    final next = _current.copyWith(
      updatedAtMs: _nowMs(),
      state: PreparedTurnState.running,
    );
    _current = next;
    try {
      await _store.save(next);
    } catch (_) {
      _persistenceFailed = true;
    }
  });

  Future<void> markTerminalAndDelete() => _serializeMutation(() async {
    if (_discarded) return;
    if (!_acknowledged) return;
    final next = _current.copyWith(
      updatedAtMs: _nowMs(),
      state: PreparedTurnState.terminal,
    );
    _current = next;
    try {
      await _store.save(next);
      await _store.delete(next);
    } catch (_) {
      _persistenceFailed = true;
    }
  });

  Future<void> markUnaccepted() => _serializeMutation(() async {
    if (_discarded || _acknowledged) return;
    final next = _current.copyWith(
      updatedAtMs: _nowMs(),
      state: _current.state == PreparedTurnState.failedBeforeAcceptance
          ? PreparedTurnState.failedBeforeAcceptance
          : _transportStarted
          ? PreparedTurnState.ambiguous
          : PreparedTurnState.failedBeforeAcceptance,
    );
    _current = next;
    try {
      await _store.save(next);
    } catch (_) {
      _persistenceFailed = true;
    }
  });

  /// El servidor respondió con un rechazo que garantiza que no persistió ni
  /// inició el turno. Aunque el request cruzó el transporte, conservarlo como
  /// `ambiguous` sería falso y obligaría a tratar un retry seguro como posible
  /// duplicado.
  Future<void> markRejectedBeforeAcceptance({
    String? invalidateRemoteSessionId,
    AttachmentRemoteTransport? invalidateTransport,
  }) => _serializeMutation(() async {
    if (_discarded || _acknowledged) return;
    var attachmentsChanged = false;
    final remoteSessionId = invalidateRemoteSessionId?.trim() ?? '';
    final attachments = remoteSessionId.isEmpty || invalidateTransport == null
        ? _current.attachments
        : _current.attachments
              .map<AttachmentDraft>((attachment) {
                if (attachment.uploadState == AttachmentUploadState.removed ||
                    attachment.remoteSessionId != remoteSessionId ||
                    attachment.remoteTransport != invalidateTransport) {
                  return attachment;
                }
                attachmentsChanged = true;
                return attachment.copyWith(
                  uploadState: AttachmentUploadState.pending,
                  errorKind: null,
                  remoteRef: null,
                  remoteSessionId: null,
                  remoteTransport: null,
                );
              })
              .toList(growable: false);
    final next = _current.copyWith(
      updatedAtMs: _nowMs(),
      state: PreparedTurnState.failedBeforeAcceptance,
      attachments: attachments,
    );
    _current = next;
    _transportStarted = false;
    if (attachmentsChanged) _notifyAttachments();
    try {
      await _store.save(next);
    } catch (_) {
      _persistenceFailed = true;
    }
  });
}

class _PreparedTurnOwner {
  _PreparedTurnOwner({
    required this.delivery,
    required this.queueOrder,
    required this.allowTransportFallback,
    required this.state,
  });

  final ActiveTurnDelivery delivery;
  int queueOrder;
  final bool allowTransportFallback;
  _PreparedTurnOwnershipState state;
  Future<bool>? cancellation;

  String get id => delivery.current.clientTurnId;

  QueuedPreparedTurn get queued => QueuedPreparedTurn(
    delivery,
    queueOrder: queueOrder,
    allowTransportFallback: allowTransportFallback,
  );
}

enum _PreparedTurnOwnershipState { pendingSave, queued, cancelling, terminal }

class QueuedPreparedTurn {
  const QueuedPreparedTurn(
    this.delivery, {
    required this.queueOrder,
    required this.allowTransportFallback,
  });

  final ActiveTurnDelivery delivery;
  final int queueOrder;
  final bool allowTransportFallback;
  PreparedTurn get turn => delivery.current;
}

enum QueuedEntryKind { desktopAccepted, text, prepared }

enum QueuedSteerOutcome { accepted, rejected, unconfirmed, queueRemovalFailed }

/// Proyección única y estable de la cola. La UI y el drenaje consumen el mismo
/// `queueOrder`; `id` no depende de la posición visible.
class QueuedEntryView {
  const QueuedEntryView({
    required this.id,
    required this.kind,
    required this.queueOrder,
    required this.text,
    this.attachments = const [],
    this.blocked = false,
  });

  final String id;
  final QueuedEntryKind kind;
  final int queueOrder;
  final String text;
  final List<AttachmentDraft> attachments;
  final bool blocked;

  bool get isSteerable =>
      text.trim().isNotEmpty &&
      attachments.isEmpty &&
      !text.trimLeft().startsWith('/');
}

class _QueuedTextTurn {
  const _QueuedTextTurn(
    this.text,
    this.queueOrder, {
    required this.id,
    required this.allowTransportFallback,
  });

  final String id;
  final String text;
  final int queueOrder;
  final bool allowTransportFallback;
}

/// Estados del pipeline del chat — solo estados respaldados por señales reales.
///
///   idle        — sin petición activa
///   connecting  — petición HTTP enviada, esperando cabeceras del servidor
///   waiting     — HTTP 200 recibido (onConnected), aún sin token/herramienta
///   executing   — llegan frames hermes.tool.progress (onToolProgress)
///   streaming   — llegan tokens de contenido (onToken)
///   completed   — onDone recibido, mensajes refrescados
///   failed      — onError recibido; error guardado en el mensaje assistant_error
///   cancelled   — el usuario tocó parar; contenido parcial preservado
enum ChatPipelineState {
  idle,
  connecting,
  waiting,
  executing,
  streaming,
  completed,
  failed,
  cancelled,
}

enum ChatTransportState { connected, reconnecting, offline }

@immutable
final class ChatTransportStatus {
  const ChatTransportStatus(this.state, {this.disconnectedSince});

  final ChatTransportState state;
  final DateTime? disconnectedSince;

  bool get isConnected => state == ChatTransportState.connected;
}

const _stopEscalationBudget = Duration(seconds: 8);
const _stopInterruptAttemptLimit = 3;
const _stopSettlingPollInterval = Duration(milliseconds: 500);

enum StopConfirmationState { idle, stopping, retrying, confirmed, failed }

final class SessionStopResult {
  const SessionStopResult({
    required this.remainingSubagents,
    required this.remainingProcesses,
  });

  final int remainingSubagents;
  final int remainingProcesses;

  int get remainingBackgroundTasks =>
      remainingSubagents + remainingProcesses;
  bool get allBackgroundWorkStopped => remainingBackgroundTasks == 0;
}

enum QueueLease { active, parked, resumeRequested }

enum _StopTransitionState {
  stopping,
  interrupting,
  recovering,
  settling,
  confirmed,
  failed,
  superseded,
}

/// The single authority record for one user Stop gesture.
final class _StopTransitionCoordinator {
  _StopTransitionCoordinator({
    required this.turnEpoch,
    required this.runtimeId,
    required this.gateway,
    required this.queueGeneration,
    required this.deadlineMs,
    required this.affectsLiveTurn,
  });

  final int turnEpoch;
  final String? runtimeId;
  final HermesDesktopGateway? gateway;
  final int queueGeneration;
  final int deadlineMs;
  final bool affectsLiveTurn;
  final Completer<void> terminal = Completer<void>();
  _StopTransitionState state = _StopTransitionState.stopping;
  int interruptAttempts = 0;
  bool agentStartingRetryUsed = false;
  bool sessionNotFoundRecoveryUsed = false;
  Object? lastInterruptError;

  bool get isFinal => const {
    _StopTransitionState.confirmed,
    _StopTransitionState.failed,
    _StopTransitionState.superseded,
  }.contains(state);
}

/// Estado compacto y comprobable que otras superficies pueden mostrar sin
/// interpretar mensajes del modelo ni inventar progreso.
enum ChatActivityKind { thinking, usingTools, responding, awaitingApproval }

/// Tipo de cambio emitido por un [ActiveChat] hacia sus oyentes (la pantalla).
enum ActiveChatEvent {
  started,
  connected,
  waiting,
  messagesHydrated,
  earlierMessagesLoaded,
  responseMetrics,
  token,
  toolProgress,
  approvalRequest,
  interactiveRequest,
  sessionInfo,
  warning,
  subagentActivity,
  done,
  error,
  cancelled,
  queueChanged,
  dashboardAuthChanged,
  goalUpdated,
  backgroundTaskComplete,
}

Future<({Object? error, T? value})> _captureAsync<T>(
  Future<T> Function() operation,
) async {
  try {
    return (error: null, value: await operation());
  } catch (error) {
    return (error: error, value: null);
  }
}

typedef SteerProjection = ({int anchorUserOrdinal, String content});

class _RewriteReservation {
  _RewriteReservation({
    required this.transcriptRevision,
    required this.turnEpoch,
    required this.runtimeSessionId,
  });

  int transcriptRevision;
  int turnEpoch;
  String? runtimeSessionId;
  bool transportStarted = false;
  bool terminalNotificationDeferred = false;
  Object? rejection;
}

typedef StoredSessionMessageLoader =
    Future<List<Map<String, dynamic>>> Function(
      String sessionId,
      String profile,
    );

typedef _CompressionProjectionAuthority = ({
  bool disposed,
  String? runtime,
  String? stored,
  String profile,
  int bind,
  int session,
  int load,
  int tombstones,
});

class DesktopCompressionProjection {
  DesktopCompressionProjection._(this._read) : _expected = _read();
  final _CompressionProjectionAuthority Function() _read;
  _CompressionProjectionAuthority _expected;
  bool _valid = true;
  bool _ownTransitionPrepared = false;
  bool get isCurrent =>
      _valid = _valid && !_expected.disposed && _expected == _read();

  /// Whether the attempt this projection tracks ever reached the gateway
  /// (the RPC call itself started), regardless of its outcome. Distinguishes
  /// "went stale before we even tried" from "went stale after we already
  /// asked the backend" — both surface as `!isCurrent` to a caller racing a
  /// concurrent refresh, but only the latter means the command is genuinely
  /// out there; the former never left this device.
  bool dispatchAttempted = false;

  // The destination is fixed BEFORE application can notify external listeners.
  // Acceptance compares against it; it never captures post-callback authority.
  void _beginOwnTransition(_CompressionProjectionAuthority expected) {
    _ownTransitionPrepared = isCurrent;
    if (_ownTransitionPrepared) _expected = expected;
  }

  void _acceptOwn({bool runtimeOnly = false}) {
    if (runtimeOnly) {
      final before = _expected;
      _expected = (
        disposed: before.disposed,
        runtime: before.runtime,
        stored: before.stored,
        profile: before.profile,
        bind: before.bind + 1,
        session: before.session,
        load: before.load,
        tombstones: before.tombstones,
      );
    } else {
      _valid = _valid && _ownTransitionPrepared;
      _ownTransitionPrepared = false;
    }
    _valid = isCurrent;
  }
}

class DesktopCompressionPresentation {
  const DesktopCompressionPresentation._(
    this.projection, {
    this.command,
    this.failure,
  }) : assert((command == null) != (failure == null));
  final DesktopCompressionProjection projection;
  final DesktopCommandDispatch? command;
  final Object? failure;
}

/// Proyección oral monotónica del turno actual.
///
/// Es deliberadamente independiente de [ActiveChat._messages]: el transcript
/// puede reconciliar o reemplazar un `message.interim`, pero el audio que ya se
/// aceptó no puede des-oírse. Solo entran eventos assistant naturales; tools,
/// logs, reasoning y resultados técnicos nunca llaman a este colector.
class _AssistantNarrationProjection {
  String _content = '';

  String get content => _content;

  void reset() => _content = '';

  void appendDelta(String value) {
    if (value.isEmpty) return;
    // `message.delta` es una pieza nueva, no un snapshot acumulado. Aplicar
    // dedupe aquí perdería repeticiones legítimas ("ja" + " ja"). La
    // reconciliación pertenece solo a interim/final, que sí son autoritativos.
    _content += value;
  }

  void sealInterim(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    _content = _appendWithOverlap(_content, trimmed);
  }

  void settleFinal(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return;
    _content = _appendWithOverlap(_content, trimmed);
  }

  static String _appendWithOverlap(String current, String incoming) {
    if (current.isEmpty) return incoming;
    if (incoming.isEmpty || current.endsWith(incoming)) return current;
    if (incoming.startsWith(current)) return incoming;

    // Un final puede decorar delante de un cuerpo ya aceptado ("¡Listo! …").
    // Si el cuerpo completo reaparece de forma inequívoca, conserva lo ya
    // narrado y añade únicamente su cola autoritativa.
    if (current.length >= 48 &&
        current.trim().split(RegExp(r'\s+')).length >= 6) {
      final acceptedStart = incoming.indexOf(current);
      if (acceptedStart >= 0) {
        final acceptedEnd = acceptedStart + current.length;
        return current + incoming.substring(acceptedEnd);
      }
    }

    final lastBoundary = current.lastIndexOf('\n\n');
    final lastSegment = lastBoundary < 0
        ? current
        : current.substring(lastBoundary + 2);
    if (lastSegment.isNotEmpty && incoming.startsWith(lastSegment)) {
      return current + incoming.substring(lastSegment.length);
    }

    final limit = current.length < incoming.length
        ? current.length
        : incoming.length;
    var overlap = 0;
    for (var length = limit; length >= 8; length--) {
      if (current.substring(current.length - length) ==
          incoming.substring(0, length)) {
        overlap = length;
        break;
      }
    }
    if (overlap > 0) return current + incoming.substring(overlap);

    final separator =
        RegExp(r'\s$').hasMatch(current) || RegExp(r'^\s').hasMatch(incoming)
        ? ''
        : '\n\n';
    return '$current$separator$incoming';
  }
}

enum _TranscriptExtent { unknown, partial, complete }

enum _SessionMessagesPageConsumer {
  compressionFenced,
  lifecyclePrefetch,
  resumeProgressRetry,
  directLoad,
  loadEarlier,
  scheduledHydration,
  cancelledAnchorRepair,
}

enum _SessionMessagesPageAction {
  stale,
  publish,
  preserveVisible,
  retryTail,
  continueBackfill,
  throwExpectedCount,
}

enum _SessionMessagesPageProjectionDisposition { publish, preserve, reject }

final class _NativeSessionHistoryPage extends SessionMessagesPage {
  _NativeSessionHistoryPage(SessionMessagesPage page, {bool? hasEarlier})
    : super(
        messages: page.messages,
        pagination: null,
        paginationProvided: false,
        rawMessageCount: page.rawMessageCount,
        messagesFullyParsed: page.messagesFullyParsed,
        resolvedTipId: page.resolvedTipId,
        coverage: page.coverage,
        hasEarlier: hasEarlier ?? page.hasEarlier,
      );
}

final class _SessionMessagesPageReadContext {
  const _SessionMessagesPageReadContext({
    required this.consumer,
    required this.profile,
    required this.requestedStoredSessionId,
    required this.loadEpoch,
    required this.requestedLimit,
    required this.requestedOffset,
    required this.hardExpectedMessageCount,
    required this.announcedMessageCount,
    required this.fenceCoverageState,
    required this.coverageRevision,
    required this.tailHydration,
    required this.nextOffset,
    required this.extent,
    required this.earlierMessagesAvailable,
  });

  final _SessionMessagesPageConsumer consumer;
  final String profile;
  final String requestedStoredSessionId;
  final int loadEpoch;
  final int requestedLimit;
  final int requestedOffset;
  final int? hardExpectedMessageCount;
  final int? announcedMessageCount;
  final bool fenceCoverageState;
  final int coverageRevision;
  final bool tailHydration;
  final int nextOffset;
  final _TranscriptExtent extent;
  final bool earlierMessagesAvailable;
}

final class _SessionMessagesPageProjection {
  const _SessionMessagesPageProjection._({
    required this.disposition,
    required this.refreshedNewestFirst,
    required this.preservesExistingCoverage,
    required this.retainsExistingRows,
    required this.unconfirmedRetainedIdentities,
    required this.confirmedRows,
  });

  const _SessionMessagesPageProjection.publish({
    this.refreshedNewestFirst = const <Map<String, dynamic>>[],
    this.preservesExistingCoverage = false,
    this.retainsExistingRows = false,
    this.unconfirmedRetainedIdentities = const <TranscriptMessageIdentity>[],
    this.confirmedRows = const <Map<String, dynamic>>[],
  }) : disposition = _SessionMessagesPageProjectionDisposition.publish;

  const _SessionMessagesPageProjection.preserve()
    : this._(
        disposition: _SessionMessagesPageProjectionDisposition.preserve,
        refreshedNewestFirst: const <Map<String, dynamic>>[],
        preservesExistingCoverage: true,
        retainsExistingRows: true,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
        confirmedRows: const <Map<String, dynamic>>[],
      );

  const _SessionMessagesPageProjection.reject({
    this.refreshedNewestFirst = const <Map<String, dynamic>>[],
  }) : disposition = _SessionMessagesPageProjectionDisposition.reject,
       preservesExistingCoverage = true,
       retainsExistingRows = true,
       unconfirmedRetainedIdentities = const <TranscriptMessageIdentity>[],
       confirmedRows = const <Map<String, dynamic>>[];

  factory _SessionMessagesPageProjection.fromGraft(
    List<Map<String, dynamic>> refreshedNewestFirst,
    _RefreshedTranscriptGraft graft,
  ) => graft.acceptedRefreshed
      ? _SessionMessagesPageProjection.publish(
          refreshedNewestFirst: refreshedNewestFirst,
          preservesExistingCoverage: graft.preservesExistingCoverage,
          retainsExistingRows: graft.retainsExistingRows,
          unconfirmedRetainedIdentities: graft.unconfirmedRetainedIdentities,
        )
      : _SessionMessagesPageProjection.reject(
          refreshedNewestFirst: refreshedNewestFirst,
        );

  final _SessionMessagesPageProjectionDisposition disposition;
  final List<Map<String, dynamic>> refreshedNewestFirst;
  final bool preservesExistingCoverage;
  final bool retainsExistingRows;
  final List<TranscriptMessageIdentity> unconfirmedRetainedIdentities;
  final List<Map<String, dynamic>> confirmedRows;
}

final class _SessionMessagesPageTransitionResult {
  const _SessionMessagesPageTransitionResult({
    required this.action,
    required this.projection,
  });

  final _SessionMessagesPageAction action;
  final _SessionMessagesPageProjection projection;

  bool get publishesProjection =>
      projection.disposition ==
          _SessionMessagesPageProjectionDisposition.publish &&
      (action == _SessionMessagesPageAction.publish ||
          action == _SessionMessagesPageAction.continueBackfill);

  bool get preservesAsSuccess =>
      action == _SessionMessagesPageAction.preserveVisible &&
      projection.disposition ==
          _SessionMessagesPageProjectionDisposition.preserve;
}

const _terminalProjectionIdKey = '_localTerminalProjectionId';
const _terminalProjectionAnchorKey = '_localTerminalAnchorMessageId';
const _terminalProjectionAnchorRowKey = '_localTerminalAnchorRowId';
const _terminalProjectionAnchorOrdinalKey = '_localTerminalOrdinalAfterAnchor';
const _terminalProjectionAbsoluteOrdinalKey =
    '_localTerminalAbsoluteUserOrdinal';
const _localCompactedTerminalProjectionKey =
    '_localCompactedTerminalProjection';
const _localCompactedTerminalAnchorMessageIdKey =
    '_localCompactedTerminalAnchorMessageId';
const _localCompactedTerminalAnchorRowIdKey =
    '_localCompactedTerminalAnchorRowId';
const _stopProofAnchorMessageIdKey = '_localStopProofAnchorMessageId';
const _stopProofAnchorRowIdKey = '_localStopProofAnchorRowId';

class _TerminalProjectionFence {
  const _TerminalProjectionFence({
    required this.projectionId,
    required this.userMessageId,
    required this.userRowId,
    required this.anchorMessageId,
    required this.anchorRowId,
    required this.ordinalAfterAnchor,
    required this.absoluteUserOrdinal,
    required this.localAssistantText,
  });

  final String projectionId;
  final String? userMessageId;
  final int? userRowId;
  final String? anchorMessageId;
  final int? anchorRowId;
  final int? ordinalAfterAnchor;
  final int? absoluteUserOrdinal;
  final String? localAssistantText;
}

typedef _TerminalTurnEvidence = ({
  bool complete,
  List<int> projectionIndices,
  String? assistantText,
});

typedef _RefreshedTranscriptGraft = ({
  List<Map<String, dynamic>> messages,
  bool preservesExistingCoverage,
  bool acceptedRefreshed,
  bool retainsExistingRows,
  List<TranscriptMessageIdentity> unconfirmedRetainedIdentities,
});

enum _DesktopCompressionPendingCause { serverPending, ambiguousTransport }

final class _SubagentReconnectAlias {
  const _SubagentReconnectAlias({
    required this.lineage,
    required this.targetRuntimeId,
    required this.subagentId,
    required this.childSessionId,
    required this.delegationId,
    required this.previousRevision,
    required this.goalPreview,
  });

  final SubagentActivityLineageKey lineage;
  final String targetRuntimeId;
  final String subagentId;
  final String? childSessionId;
  final String? delegationId;
  final int previousRevision;
  final String goalPreview;

  bool targetsSubagent(SubagentActivityEvent event) =>
      event.scope.durableLineageKey == lineage &&
      event.scope.runtimeSessionId == targetRuntimeId &&
      event.subagentId == subagentId;

  bool isSameOpaqueChild(SubagentActivityEvent event) {
    if (!targetsSubagent(event)) return false;
    final childSessionMatches =
        childSessionId != null && event.childSessionId == childSessionId;
    final delegationMatches =
        delegationId != null && event.delegationId == delegationId;
    return childSessionMatches || delegationMatches;
  }

  bool provesContinuation(SubagentActivityEvent event) =>
      isSameOpaqueChild(event) &&
      event.eventRevision != null &&
      event.eventRevision! > previousRevision;
}

final class _PendingSubagentInterrupt {
  const _PendingSubagentInterrupt({
    required this.token,
    required this.key,
    required this.gateway,
    required this.connectionId,
    required this.profile,
    required this.durableSessionId,
    required this.runtimeSessionId,
    required this.bindEpoch,
    required this.sessionEpoch,
    required this.turnEpoch,
    required this.presentationGeneration,
  });

  final Object token;
  final SubagentActivityKey key;
  final Object gateway;
  final Object? connectionId;
  final Object? profile;
  final Object? durableSessionId;
  final String runtimeSessionId;
  final int bindEpoch;
  final int sessionEpoch;
  final int turnEpoch;
  final int presentationGeneration;
}

final class _SubagentRefreshAuthority {
  const _SubagentRefreshAuthority({
    required this.gateway,
    required this.connectionId,
    required this.profile,
    required this.durableSessionId,
    required this.runtimeSessionId,
    required this.bindEpoch,
    required this.sessionEpoch,
    required this.turnEpoch,
    required this.presentationLeased,
    required this.presentationGeneration,
  });

  final Object? gateway;
  final Object? connectionId;
  final Object? profile;
  final Object? durableSessionId;
  final String? runtimeSessionId;
  final int bindEpoch;
  final int sessionEpoch;
  final int turnEpoch;
  final bool presentationLeased;
  final int presentationGeneration;

  bool sameAs(_SubagentRefreshAuthority other) =>
      identical(gateway, other.gateway) &&
      connectionId == other.connectionId &&
      profile == other.profile &&
      durableSessionId == other.durableSessionId &&
      runtimeSessionId == other.runtimeSessionId &&
      bindEpoch == other.bindEpoch &&
      sessionEpoch == other.sessionEpoch &&
      turnEpoch == other.turnEpoch &&
      presentationLeased == other.presentationLeased &&
      presentationGeneration == other.presentationGeneration;
}

/// A manually requested server-side compression that Console must not submit
/// again while it waits for authoritative completion evidence.
final class _PendingDesktopCompression {
  const _PendingDesktopCompression({
    required this.durableRecord,
    required this.runtimeSessionId,
    required this.rootDurableId,
    required this.bindEpoch,
    required this.sessionEpoch,
    required this.deadline,
    required this.cause,
  });

  final DesktopCompressionFenceRecord durableRecord;
  final String runtimeSessionId;
  final String rootDurableId;
  final int bindEpoch;
  final int sessionEpoch;
  final DateTime deadline;
  final _DesktopCompressionPendingCause cause;
}

enum _ViewerAttachmentDisposition {
  retryTransient,
  stopTerminal,
  stopAmbiguous,
}

enum RuntimeReleaseBlocker {
  exactIdentity,
  notCurrent,
  notIdle,
  streaming,
  submit,
  delivery,
  queue,
  drain,
  approval,
  interactivePrompt,
  toolOrSubagent,
  compression,
  reconciliation,
  stop,
  mutation,
  staleEpoch,
}

final class RuntimeReleaseSafetyState {
  final bool exactUniqueRuntimeAndDurable;
  final bool current;
  final bool idle;
  final bool noStreaming;
  final bool noSubmit;
  final bool noDelivery;
  final bool noQueue;
  final bool noDrain;
  final bool noApproval;
  final bool noInteractivePrompt;
  final bool noToolOrSubagent;
  final bool noCompression;
  final bool noReconciliation;
  final bool noStop;
  final bool noMutation;
  final bool epochsCurrent;

  const RuntimeReleaseSafetyState({
    required this.exactUniqueRuntimeAndDurable,
    required this.current,
    required this.idle,
    required this.noStreaming,
    required this.noSubmit,
    required this.noDelivery,
    required this.noQueue,
    required this.noDrain,
    required this.noApproval,
    required this.noInteractivePrompt,
    required this.noToolOrSubagent,
    required this.noCompression,
    required this.noReconciliation,
    required this.noStop,
    required this.noMutation,
    required this.epochsCurrent,
  });

  RuntimeReleaseSafetyState copyWith({
    bool? exactUniqueRuntimeAndDurable,
    bool? current,
    bool? idle,
    bool? noStreaming,
    bool? noSubmit,
    bool? noDelivery,
    bool? noQueue,
    bool? noDrain,
    bool? noApproval,
    bool? noInteractivePrompt,
    bool? noToolOrSubagent,
    bool? noCompression,
    bool? noReconciliation,
    bool? noStop,
    bool? noMutation,
    bool? epochsCurrent,
  }) => RuntimeReleaseSafetyState(
    exactUniqueRuntimeAndDurable:
        exactUniqueRuntimeAndDurable ?? this.exactUniqueRuntimeAndDurable,
    current: current ?? this.current,
    idle: idle ?? this.idle,
    noStreaming: noStreaming ?? this.noStreaming,
    noSubmit: noSubmit ?? this.noSubmit,
    noDelivery: noDelivery ?? this.noDelivery,
    noQueue: noQueue ?? this.noQueue,
    noDrain: noDrain ?? this.noDrain,
    noApproval: noApproval ?? this.noApproval,
    noInteractivePrompt: noInteractivePrompt ?? this.noInteractivePrompt,
    noToolOrSubagent: noToolOrSubagent ?? this.noToolOrSubagent,
    noCompression: noCompression ?? this.noCompression,
    noReconciliation: noReconciliation ?? this.noReconciliation,
    noStop: noStop ?? this.noStop,
    noMutation: noMutation ?? this.noMutation,
    epochsCurrent: epochsCurrent ?? this.epochsCurrent,
  );
}

Set<RuntimeReleaseBlocker> runtimeReleaseBlockers(
  RuntimeReleaseSafetyState state,
) => {
  if (!state.exactUniqueRuntimeAndDurable) RuntimeReleaseBlocker.exactIdentity,
  if (!state.current) RuntimeReleaseBlocker.notCurrent,
  if (!state.idle) RuntimeReleaseBlocker.notIdle,
  if (!state.noStreaming) RuntimeReleaseBlocker.streaming,
  if (!state.noSubmit) RuntimeReleaseBlocker.submit,
  if (!state.noDelivery) RuntimeReleaseBlocker.delivery,
  if (!state.noQueue) RuntimeReleaseBlocker.queue,
  if (!state.noDrain) RuntimeReleaseBlocker.drain,
  if (!state.noApproval) RuntimeReleaseBlocker.approval,
  if (!state.noInteractivePrompt) RuntimeReleaseBlocker.interactivePrompt,
  if (!state.noToolOrSubagent) RuntimeReleaseBlocker.toolOrSubagent,
  if (!state.noCompression) RuntimeReleaseBlocker.compression,
  if (!state.noReconciliation) RuntimeReleaseBlocker.reconciliation,
  if (!state.noStop) RuntimeReleaseBlocker.stop,
  if (!state.noMutation) RuntimeReleaseBlocker.mutation,
  if (!state.epochsCurrent) RuntimeReleaseBlocker.staleEpoch,
};

enum _DesktopRuntimeBindingOrigin {
  none,
  viewerActivated,
  availabilityResumed,
  consoleOwned,
}

final class _DesktopRuntimeOwnershipReceipt {
  _DesktopRuntimeOwnershipReceipt({
    required this.gateway,
    required this.connectionId,
    required this.profile,
    required this.durableSessionId,
    required this.runtimeSessionId,
    required this.bindEpoch,
    required this.sessionEpoch,
  });

  final HermesDesktopGateway gateway;
  final String connectionId;
  final String profile;
  final String durableSessionId;
  final String runtimeSessionId;
  final int bindEpoch;
  final int sessionEpoch;
  int? transportGeneration;
  Object? producerChannel;
}

enum _OwnershipMutationAdmission {
  open,
  conflictReadOnly,
  rechecking,
  pendingManualProbe,
  manualProbeInFlight,
}

class _ClosedViewerRecoveryScope {
  const _ClosedViewerRecoveryScope({
    required this.gateway,
    required this.connectionId,
    required this.logicalSessionId,
    required this.serverSessionId,
    required this.storedSessionId,
    required this.profile,
    required this.turnEpoch,
    required this.bindEpoch,
    required this.sessionEpoch,
  });

  final HermesDesktopGateway gateway;
  final String connectionId;
  final String logicalSessionId;
  final String serverSessionId;
  final String storedSessionId;
  final String profile;
  final int turnEpoch;
  final int bindEpoch;
  final int sessionEpoch;
}

/// Estado vivo de un chat con streaming. Es la fuente de verdad de los mensajes,
/// el trace y el estado del pipeline mientras el chat está activo. Sobrevive al
/// pop de la ruta del chat porque lo posee [ActiveChatService], no el widget.
final class SubagentPresentationOwnerToken {
  SubagentPresentationOwnerToken._(this._issuer);

  final Object _issuer;
}

enum _SubagentPresentationState {
  unowned,
  foregroundPendingProof,
  foregroundCurrent,
}

class ActiveChat {
  static const int _maxInitialBackfillPages = 64;
  static const int _authoritativeTranscriptPageSize = 500;
  static final Stopwatch _defaultMonotonicClock = Stopwatch()..start();
  static const Duration _voiceBargeHandoffRetention = Duration(seconds: 30);
  static const Duration _desktopRecoveryDelayCap = Duration(seconds: 15);
  static const Duration _desktopRecoveryFallbackDelay = Duration(seconds: 1);
  static const Duration _desktopCompressionReconcileRpcBudget = Duration(
    seconds: 10,
  );
  static const Duration _desktopCompressionReconciliationFallback = Duration(
    minutes: 12,
  );

  static Duration _normalizedDesktopCompressionReconciliationDelay(
    Duration configured,
  ) => configured > Duration.zero ? configured : const Duration(seconds: 20);

  static Duration _normalizedDesktopCompressionReconciliationWindow(
    Duration configured,
    Duration delay,
  ) => configured > delay
      ? configured
      : _desktopCompressionReconciliationFallback;

  static List<Duration> _normalizeDesktopRecoveryBackoff(
    List<Duration> configured,
  ) {
    final normalized = <Duration>[];
    for (final delay in configured) {
      if (delay <= Duration.zero) {
        if (normalized.isEmpty) normalized.add(Duration.zero);
        continue;
      }
      normalized.add(
        delay > _desktopRecoveryDelayCap ? _desktopRecoveryDelayCap : delay,
      );
    }
    if (normalized.isEmpty || normalized.first > Duration.zero) {
      normalized.insert(0, Duration.zero);
    }
    if (normalized.last <= Duration.zero) {
      normalized.add(_desktopRecoveryFallbackDelay);
    }
    return List<Duration>.unmodifiable(normalized);
  }

  Duration _desktopRecoveryDelayForAttempt(int attempt) {
    if (attempt <= 0) return Duration.zero;
    final cap =
        _desktopRecoveryBackoff[attempt.clamp(
          0,
          _desktopRecoveryBackoff.length - 1,
        )];
    if (cap <= Duration.zero) return Duration.zero;
    final sample = _desktopRecoveryRandom();
    final bounded = sample.isFinite ? sample.clamp(0.0, 1.0) : 0.0;
    return Duration(microseconds: (cap.inMicroseconds * bounded).floor());
  }

  @visibleForTesting
  Duration desktopRecoveryDelayForTesting(int attempt) =>
      _desktopRecoveryDelayForAttempt(attempt);

  final SavedConnection connection;
  final String sessionId;
  final String logicalSessionId;
  late SessionIdentity _coreReadIdentity;
  Set<CoreReadCoverage> _coreReadCoverage = const <CoreReadCoverage>{};
  bool? _coreReadLineageComplete;
  SessionIdentity get coreReadIdentity => _coreReadIdentity;
  Set<CoreReadCoverage> get coreReadCoverage => _coreReadCoverage;
  String sessionTitle;
  NotificationChatSurface notificationSurface;
  String? notificationRoomId;

  final NotificationService? _notifications;
  bool? _notifyRepliesOverride;

  /// Resultados de `prompt.background` recibidos como `background.complete`
  /// en esta sesión, indexados por `task_id`. Solo vive en memoria — no hay
  /// endpoint del gateway para reconstruirlos tras un reinicio del proceso,
  /// así que un relanzamiento de la app los pierde (limitación conocida,
  /// igual que la actividad cross-surface de [GlobalActivityAggregate]).
  final Map<String, ({String text, bool isError})> _backgroundTaskOutcomes = {};
  Map<String, ({String text, bool isError})> get backgroundTaskOutcomes =>
      Map.unmodifiable(_backgroundTaskOutcomes);

  /// El usuario ya vio/descartó este resultado — lo quita del strip.
  void dismissBackgroundTaskOutcome(String taskId) {
    if (_backgroundTaskOutcomes.remove(taskId) != null) {
      _emit(ActiveChatEvent.backgroundTaskComplete);
    }
  }

  final ApprovalPolicyService? _policy;
  final VoidCallback _onTerminal;
  final VoidCallback? _onUnused;
  final Future<void> Function()? _beforeTerminalNotification;
  final Future<void> Function()? _beforePrivacyCheckpointSave;
  final Future<void> Function()? _beforePrivacySnapshotLoad;
  final Future<bool> Function()? _historyHydrationAwaiter;

  /// Se invoca cuando el run obtiene su id. La capa de servicio lo usa para
  /// arrancar el foreground service y registrar la vigilancia en 2º plano, de
  /// modo que el proceso (y con él el SSE) siga vivo aunque la app pase atrás.
  final void Function(String runId)? _onRunStarted;

  /// Solo arranca el foreground service (sin vigilancia de runs). Lo usa el chat
  /// LOCAL por el bridge: su turno es una llamada HTTP larga a `hermes -z`, no un
  /// run pollable, pero el proceso debe seguir vivo si la app pasa a 2º plano.
  final Future<void> Function()? _onForegroundKeepAlive;
  final ValueChanged<int?>? _onObservedFirstTokenLatency;
  final ValueChanged<ActiveChatEvent>? _onEvent;
  final List<CancelledTurnTombstone> _cancelledTurnTombstones;
  final Future<void> Function(CancelledTurnTombstone)? _onCancelledTurn;
  Future<void> _cancelledTurnPersistence = Future<void>.value();
  bool _cancelledTurnPersistencePending = false;
  bool _cancelledTurnPersistenceFailed = false;
  final Map<String, CancelledTurnTombstone> _pendingCancelledTombstoneUpdates =
      {};
  int _cancelledTombstoneRevision = 0;
  Future<void>? _cancelledTombstoneUpdateFlight;
  Future<void>? _durableCancelFlight;
  Future<SessionStopResult>? _sessionStopFlight;
  StopConfirmationState _stopConfirmationState = StopConfirmationState.idle;
  bool _lastStopAffectedLiveTurn = true;
  bool _backgroundStopVerificationInFlight = false;
  int? _backgroundStopRemainingTasks;
  StopConfirmationState get stopConfirmationState => _stopConfirmationState;
  bool get backgroundStopVerificationInFlight =>
      _backgroundStopVerificationInFlight;
  int? get backgroundStopRemainingTasks => _backgroundStopRemainingTasks;
  bool get stopConfirmationOnlyBackground =>
      _stopConfirmationState == StopConfirmationState.confirmed &&
      !_backgroundStopVerificationInFlight &&
      // Null means no background inventory existed, so nothing remains.
      (_backgroundStopRemainingTasks ?? 0) == 0 &&
      !_lastStopAffectedLiveTurn;
  final int Function() _monotonicMicros;
  int? _responseStartedAtMicros;
  int? _observedFirstTokenLatencyMs;

  late ApiClient _api;
  final StoredSessionMessageLoader? _storedMessageLoader;
  final bool _attachDesktopRuntimeOnLoad;
  final bool _allowUnownedDesktopSnapshotForTesting;
  LocalConversationLifecycle? _localConversationLifecycle;
  final Map<String, LocalConversationOperation> _localTranscriptOperations = {};
  final Set<String> _confirmedLocalTranscriptOperations = {};
  String? _sessionProfileOwner;
  String _storedSessionProfile = '';
  bool _desktopStoredSessionKnownMissing = false;

  /// Canal oficial de Hermes Desktop (`/api/ws`). En producción es el camino
  /// remoto preferido; en tests que inyectan [ApiClient] queda desactivado salvo
  /// que se inyecte explícitamente un fake.
  final HermesDesktopGateway? _desktopGateway;
  final DesktopCompressionFenceStore _compressionFenceStore;
  final int Function() _wallClockMs;
  final List<Duration> _backgroundStopRecheckDelays;
  final Future<AttachmentUploadResult> Function(
    SavedConnection,
    AttachmentDraft,
  )
  _attachmentUploader;
  final BridgeClientFactory _bridgeClientFactory;
  final BridgeProvisioner _bridgeProvisioner;
  final Future<bool> Function() _turnIdempotencyCapability;
  bool? _turnIdempotencySupported;
  bool _turnIdempotencyInvalid = false;
  StreamSubscription<TuiGatewayEvent>? _desktopEventSubscription;
  int? _desktopTerminalSequence;
  int? _desktopTerminalTransportGeneration;
  Object? _desktopTerminalProducerChannel;
  Completer<void>? _desktopInterruptDrain;
  bool _discardLateInterruptTerminal = false;
  Timer? _voiceBargeHandoffTimer;
  bool _voiceBargeHandoffPending = false;
  String? _desktopRuntimeSessionId;
  String? _retiringDesktopRuntimeSessionId;
  String? _desktopStoredSessionId;
  _OwnershipMutationAdmission _ownershipMutationAdmission =
      _OwnershipMutationAdmission.open;
  String? _pendingManualOwnershipProbeClientTurnId;
  bool _runtimeReleaseInFlight = false;
  int _ownershipConflictGeneration = 0;
  _DesktopRuntimeBindingOrigin _desktopRuntimeBindingOrigin =
      _DesktopRuntimeBindingOrigin.none;
  _DesktopRuntimeOwnershipReceipt? _desktopRuntimeOwnershipReceipt;
  final Object _desktopCompressionAuthorityIdentity = Object();
  DesktopCompressionAcquisitionReceipt? _validatedDesktopAcquisition;
  // A testing acquisition may adopt, but no later binding can wash its taint.
  // Deliberately never reset during this ActiveChat's lifetime.
  bool _desktopCompressionTestingTainted = false;
  bool _usingDesktopGateway = false;
  int? _recoveringDesktopTurnEpoch;
  Future<void>? _desktopTurnRecovery;
  Future<void>? _desktopAutomaticReattach;
  int _desktopAutomaticReattachGeneration = 0;
  _ClosedViewerRecoveryScope? _closedViewerRecoveryScope;
  Future<bool>? _resumeReconcileFlight;
  int _resumeReconcileReservations = 0;
  int _messageLoadEpoch = 0;
  int _desktopBindEpoch = 0;
  int? _activeTurnTranscriptBoundaryEpoch;
  bool _activeTurnStartedFromKnownMissing = false;
  TranscriptMessageIdentity? _activeTurnTranscriptBoundaryIdentity;
  String? _activeTurnTranscriptBoundarySessionId;
  String? _activeTurnTranscriptBoundaryProfile;
  bool _passiveTurnBoundaryFresh = false;
  int _desktopInterimSerial = 0;
  int _localTranscriptProjectionSerial = 0;
  String? _pendingDesktopInterimKey;
  final _AssistantNarrationProjection _assistantNarration =
      _AssistantNarrationProjection();
  int _desktopSessionEpoch = 0;
  int _sessionConfigRequestEpoch = 0;
  int _sessionInfoEpoch = 0;
  int _sessionConfigRequestsInFlight = 0;
  int _runtimeMutationsInFlight = 0;
  bool _desktopCompressionInFlight = false;
  bool _desktopCompressionRpcInFlight = false;
  DesktopCompressionFenceRecord? _durableCompressionFence;
  _PendingDesktopCompression? _pendingDesktopCompression;
  Timer? _desktopCompressionReconciliationTimer;
  // Set only by an actual abandoned reconciliation (a tracked pending
  // attempt whose deadline ran out); cleared on a fresh dispatch or a clean
  // settle. Deliberately NOT derived from `_pendingDesktopCompression == null`
  // alone: that is also true for an attempt whose fence went stale before it
  // was ever tracked as pending (e.g. superseded by a concurrent refresh),
  // which must stay silent rather than surface a false "can't confirm".
  bool _desktopCompressionUnconfirmable = false;
  bool _desktopAutoCompacting = false;

  /// Hermes repite `compacting` cada ~60 s mientras dura; si dejan de llegar
  /// (desconexión que se comió el `compacted`, servidor caído) la bandera no
  /// puede quedarse para siempre bloqueando el chat.
  Timer? _autoCompactionStaleTimer;
  static const Duration _autoCompactionStaleAfter = Duration(minutes: 3);
  DateTime? _desktopCompactionStartedAt;
  int? _desktopCompactionTokensBefore;
  int? _desktopCompactionMessagesBefore;
  int? _desktopCompactionChunkIndex;
  int? _desktopCompactionChunkCount;
  int _desktopCompactedEdgeCount = 0;
  bool _suppressTerminalHydrationAfterCompaction = false;
  String? _desktopCompactionLineageId;
  SessionConfigScope? _sessionConfigScope;
  SessionConfigReducerState _sessionConfigState =
      const SessionConfigReducerState.empty();

  DesktopSessionRuntimeInfo _desktopRuntimeInfo =
      const DesktopSessionRuntimeInfo();
  String? _desktopLiveStatus;
  bool _offerStaleResumedSessionStop = false;
  ChatActivityKind? _lastLiveActivityKind;
  // `snapshot.started_at` es el inicio del runtime, no del turno actual.
  DateTime? _desktopStartedAt;
  DateTime? _desktopTurnStartedAt;
  InteractivePromptState _interactivePrompts =
      const InteractivePromptState.empty();
  final Map<InteractivePromptKey, Future<DesktopPromptResponse>> _batchLocks =
      {};
  SubagentActivityState? _subagentActivities;
  // Set once a fully fenced `subagent.list` for the current runtime has been
  // applied. Only such a response proves what is still live: a delegation
  // started with `background` outlives the turn that spawned it, so a turn
  // that ended proves nothing, and a list that failed proves nothing either.
  // Cleared whenever the roster's scope rotates, so proof never crosses
  // runtimes.
  bool _subagentLiveRosterConfirmed = false;
  String? _subagentTranscriptTurnAnchor;
  final Map<SubagentActivityKey, _PendingSubagentInterrupt>
  _pendingSubagentInterrupts = {};
  final Set<SubagentActivityKey> _subagentControlAuthority = {};
  final List<SubagentActivity> _retiredSubagentTerminals = [];
  final List<SubagentActivity> _subagentHistoricalEvidence = [];
  final List<_SubagentReconnectAlias> _subagentReconnectAliases = [];
  int _subagentListRequestGeneration = 0;
  int _subagentMutationGeneration = 0;
  final Set<SubagentPresentationOwnerToken> _subagentPresentationOwners = {};
  bool get _subagentForegroundPresentationLeased =>
      _subagentPresentationOwners.isNotEmpty;
  int _subagentForegroundPresentationGeneration = 0;
  _SubagentPresentationState _subagentPresentationState =
      _SubagentPresentationState.unowned;
  List<SubagentActivity> _subagentPublicActivities = const [];
  final Set<SubagentActivityKey> _subagentPublicEligibleKeys = {};
  Future<void>? _subagentRefreshFlight;
  _SubagentRefreshAuthority? _subagentRefreshAuthority;
  List<SessionActivityProcess> _backgroundProcesses = const [];
  final Map<String, int> _backgroundProcessAbsenceStreaks = {};
  int _backgroundProcessListRequestGeneration = 0;
  int _backgroundProcessMutationGeneration = 0;
  bool _backgroundProcessesStale = false;
  bool _backgroundProcessLiveRosterConfirmed = false;
  DateTime? _backgroundProcessesObservedAt;
  Future<void>? _backgroundProcessRefreshFlight;
  bool _backgroundProcessRefreshRequested = false;
  int _adaptiveRefreshEventRevision = 0;
  int _adaptiveFullRefreshRevision = 0;
  int _adaptiveSubagentRepairRevision = 0;
  int _adaptiveProcessRepairRevision = 0;
  int _adaptiveControlRepairRevision = 0;
  int _adaptiveSnapshotFailureRevision = 0;
  ArtifactIndexSnapshot? _artifactIndex;
  ArtifactIndexScope? _artifactScope;
  List<ArtifactTranscriptEntry> _pendingArtifactTranscript = const [];
  int _artifactTranscriptRevision = 0;

  bool get turnIdempotencyInvalid => _turnIdempotencyInvalid;

  /// `null` hereda el ajuste global; `false` silencia únicamente este lineage.
  /// Un `true` no puede saltarse un ajuste global desactivado: esa política
  /// sigue aplicándose dentro de [NotificationService].
  set notifyRepliesOverride(bool? value) => _notifyRepliesOverride = value;
  bool get _shouldNotifyReplies => _notifyRepliesOverride != false;

  DesktopSessionRuntimeInfo get desktopRuntimeInfo => _desktopRuntimeInfo;
  String? get desktopRuntimeSessionId => _desktopRuntimeSessionId;
  @visibleForTesting
  int get desktopBindEpochForTesting => _desktopBindEpoch;
  String? get desktopLiveStatus => _desktopLiveStatus;
  bool get offerStaleResumedSessionStop => _offerStaleResumedSessionStop;

  void clearStaleResumedSessionStopOffer() {
    if (!_offerStaleResumedSessionStop) return;
    _offerStaleResumedSessionStop = false;
    _emit(ActiveChatEvent.sessionInfo);
  }

  bool _clearFailedStopConfirmation() {
    if (_stopConfirmationState != StopConfirmationState.failed) return false;
    _stopConfirmationState = StopConfirmationState.idle;
    _lastStopAffectedLiveTurn = true;
    _backgroundStopVerificationInFlight = false;
    _backgroundStopRemainingTasks = null;
    return true;
  }

  bool get conflictReadOnly =>
      _ownershipMutationAdmission != _OwnershipMutationAdmission.open;
  bool get ownershipRecheckInFlight =>
      _ownershipMutationAdmission == _OwnershipMutationAdmission.rechecking;
  bool get manualOwnershipProbeAvailable =>
      _ownershipMutationAdmission ==
      _OwnershipMutationAdmission.pendingManualProbe;
  bool get ownershipRecheckAvailable => true;
  bool get mutationsBlockedByOwnershipConflict =>
      _ownershipMutationAdmission != _OwnershipMutationAdmission.open ||
      _runtimeReleaseInFlight;

  bool get showReleaseToDesktopControl => _desktopOwnershipReceiptIsCurrent();

  bool _desktopOwnershipReceiptIsCurrent() {
    final receipt = _desktopRuntimeOwnershipReceipt;
    return !_disposed &&
        receipt != null &&
        identical(receipt.gateway, _desktopGateway) &&
        receipt.gateway.isConnected &&
        receipt.connectionId == connection.id &&
        receipt.profile == _storedSessionProfile &&
        receipt.durableSessionId == _desktopStoredSessionId &&
        receipt.runtimeSessionId == _desktopRuntimeSessionId &&
        receipt.bindEpoch == _desktopBindEpoch &&
        receipt.sessionEpoch == _desktopSessionEpoch;
  }

  void _revokeDesktopRuntimeOwnership() {
    if (_desktopRuntimeOwnershipReceipt == null) return;
    _desktopRuntimeOwnershipReceipt = null;
    if (_desktopRuntimeBindingOrigin ==
        _DesktopRuntimeBindingOrigin.consoleOwned) {
      _desktopRuntimeBindingOrigin = _DesktopRuntimeBindingOrigin.none;
    }
    if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
  }

  void _observeDesktopOwnershipTransport(TuiGatewayEvent event) {
    final receipt = _desktopRuntimeOwnershipReceipt;
    final generation = event.transportGeneration;
    final channel = event.producerChannel;
    if (receipt == null || generation == null || channel == null) return;
    final previousGeneration = receipt.transportGeneration;
    final previousChannel = receipt.producerChannel;
    if (previousGeneration == null && previousChannel == null) {
      receipt.transportGeneration = generation;
      receipt.producerChannel = channel;
      return;
    }
    if (previousGeneration != generation ||
        !identical(previousChannel, channel)) {
      _revokeDesktopRuntimeOwnership();
    }
  }

  bool get canReleaseToDesktop => _releasePreconditionsSatisfied();
  bool get runtimeReleaseInFlight => _runtimeReleaseInFlight;

  bool _releasePreconditionsSatisfied({bool ignoreReleaseInFlight = false}) {
    final gateway = _desktopGateway;
    final runtimeId = _desktopRuntimeSessionId;
    final durableId = _desktopStoredSessionId;
    final deliveryState = _activeTurnDelivery?.current.state;
    final hasPendingDelivery =
        deliveryState != null && deliveryState != PreparedTurnState.terminal;
    final exactIdentity =
        runtimeId != null &&
        runtimeId.isNotEmpty &&
        runtimeId == runtimeId.trim() &&
        durableId != null &&
        durableId.isNotEmpty &&
        durableId == durableId.trim();
    final configSession = _sessionConfigScope == null
        ? null
        : _sessionConfigState[_sessionConfigScope!];
    final hasUnsettledConfigChange =
        configSession?.changes.values.any(
          (change) => change.status.canBeSuperseded,
        ) ??
        false;
    final blockers = runtimeReleaseBlockers(
      RuntimeReleaseSafetyState(
        exactUniqueRuntimeAndDurable: exactIdentity,
        current: true,
        idle: true,
        noStreaming: !isStreaming,
        noSubmit: state != ChatPipelineState.connecting,
        noDelivery: !hasPendingDelivery,
        noQueue:
            _messageQueue.isEmpty &&
            _preparedTurnQueue.isEmpty &&
            _pendingPreparedQueueOrders.isEmpty &&
            _pendingPreparedTurnIds.isEmpty &&
            _preparedTurnOwners.isEmpty &&
            _preparedTurnCancellationsInFlight.isEmpty &&
            _desktopAcceptedQueuedPrompt == null,
        noDrain:
            !_preparedTurnDrainInFlight &&
            !_desktopQueueAuthorityCheckInFlight &&
            _queueAdmissionToken == null,
        noApproval: pendingApproval == null,
        noInteractivePrompt:
            pendingInteractivePrompt == null && _batchLocks.isEmpty,
        noToolOrSubagent:
            !traceActive &&
            _activeVoiceTools.isEmpty &&
            !(_subagentActivities?.activities.any(
                  (activity) => !activity.isTerminal,
                ) ??
                false) &&
            _pendingSubagentInterrupts.isEmpty,
        noCompression:
            !desktopCompressionInFlight &&
            !_desktopCompressionRpcInFlight &&
            _durableCompressionFence == null,
        noReconciliation:
            !resumeReconciliationInFlight &&
            _recoveringDesktopTurnEpoch == null &&
            _desktopTurnRecovery == null &&
            _desktopAutomaticReattach == null &&
            _terminalTranscriptRecovery == null &&
            _pendingAuthoritativeTerminalEpoch == null &&
            _desktopCompressionReconciliationTimer == null,
        noStop:
            !_cancelling &&
            // Un Stop terminal ya no es trabajo en vuelo. Sólo un coordinador
            // vivo —o un Stop que no llegó a confirmarse— puede retener la
            // liberación del runtime.
            (_stopTransition?.isFinal ?? true) &&
            (_stopConfirmationState == StopConfirmationState.idle ||
                _stopConfirmationState == StopConfirmationState.confirmed) &&
            _desktopInterruptDrain == null &&
            _durableCancelFlight == null &&
            _cancelledTombstoneUpdateFlight == null,
        noMutation:
            _sessionConfigRequestsInFlight == 0 &&
            _runtimeMutationsInFlight == 0 &&
            _activeRewrite == null &&
            !hasUnsettledConfigChange,
        epochsCurrent: true,
      ),
    );
    return !_disposed &&
        _desktopOwnershipReceiptIsCurrent() &&
        gateway is HermesDesktopSessionActivityGateway &&
        gateway is HermesDesktopSessionLifecycleGateway &&
        gateway is HermesDesktopSessionCloseGateway &&
        gateway != null &&
        gateway.isConnected &&
        _ownershipMutationAdmission == _OwnershipMutationAdmission.open &&
        (ignoreReleaseInFlight || !_runtimeReleaseInFlight) &&
        blockers.isEmpty;
  }

  TuiGatewayRpcError _ownershipConflictError(String method) =>
      TuiGatewayRpcError(
        method,
        'Session is open on another surface',
        code: 4090,
        data: const {'reason': 'SESSION_NOT_OWNED'},
      );

  Future<T> _trackRuntimeMutation<T>(Future<T> Function() operation) {
    _runtimeMutationsInFlight += 1;
    if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
    return Future<T>.sync(operation).whenComplete(() {
      _runtimeMutationsInFlight -= 1;
      if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
    });
  }

  static const _staleResumedTurnWindow = Duration(minutes: 15);

  void _rememberDesktopLiveStatus(
    String? value, {
    required bool running,
    DateTime? turnStartedAt,
    bool coldOpen = false,
  }) {
    final normalized = value?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      _desktopLiveStatus = normalized;
    } else if (!running) {
      _desktopLiveStatus = null;
    }
    if (!running) {
      _offerStaleResumedSessionStop = false;
    } else if (coldOpen) {
      final startedAt = turnStartedAt;
      _offerStaleResumedSessionStop =
          startedAt != null &&
          DateTime.fromMillisecondsSinceEpoch(
            _wallClockMs(),
          ).difference(startedAt) >=
              _staleResumedTurnWindow;
    }
  }

  void _mintDesktopRuntimeOwnershipAfterAcceptedSubmit({
    required HermesDesktopGateway gateway,
    required String connectionId,
    required String profile,
    required String durableSessionId,
    required String runtimeSessionId,
    required int bindEpoch,
    required int sessionEpoch,
    required int turnEpoch,
  }) {
    if (_disposed ||
        !identical(gateway, _desktopGateway) ||
        !gateway.isConnected ||
        connection.id != connectionId ||
        _storedSessionProfile != profile ||
        _desktopStoredSessionId != durableSessionId ||
        _desktopRuntimeSessionId != runtimeSessionId ||
        _desktopBindEpoch != bindEpoch ||
        _desktopSessionEpoch != sessionEpoch ||
        _turnEpoch != turnEpoch) {
      return;
    }
    _desktopRuntimeBindingOrigin = _DesktopRuntimeBindingOrigin.consoleOwned;
    _desktopRuntimeOwnershipReceipt = _DesktopRuntimeOwnershipReceipt(
      gateway: gateway,
      connectionId: connectionId,
      profile: profile,
      durableSessionId: durableSessionId,
      runtimeSessionId: runtimeSessionId,
      bindEpoch: bindEpoch,
      sessionEpoch: sessionEpoch,
    );
    _emit(ActiveChatEvent.sessionInfo);
  }

  HermesDesktopControlGateway? get desktopControlGateway {
    final gateway = _desktopGateway;
    return gateway is HermesDesktopControlGateway
        ? gateway as HermesDesktopControlGateway
        : null;
  }

  bool get desktopChangeEventsAvailable {
    final gateway = _desktopGateway;
    if (gateway == null) return false;
    try {
      return (gateway as dynamic).changeEventsAvailable == true;
    } on NoSuchMethodError {
      return false;
    }
  }

  int get adaptiveRefreshEventRevision => _adaptiveRefreshEventRevision;
  int get adaptiveFullRefreshRevision => _adaptiveFullRefreshRevision;
  int get adaptiveSubagentRepairRevision => _adaptiveSubagentRepairRevision;
  int get adaptiveProcessRepairRevision => _adaptiveProcessRepairRevision;
  int get adaptiveControlRepairRevision => _adaptiveControlRepairRevision;
  int get adaptiveSnapshotFailureRevision =>
      _adaptiveSnapshotFailureRevision;

  void _signalAdaptiveRefresh({
    bool full = false,
    bool subagents = false,
    bool processes = false,
    bool control = false,
  }) {
    _adaptiveRefreshEventRevision += 1;
    if (full) _adaptiveFullRefreshRevision += 1;
    if (subagents) _adaptiveSubagentRepairRevision += 1;
    if (processes) _adaptiveProcessRepairRevision += 1;
    if (control) _adaptiveControlRepairRevision += 1;
  }

  void _requestPostControlRepair() {
    _signalAdaptiveRefresh(full: true);
    _emit(ActiveChatEvent.subagentActivity);
  }

  bool _subagentEventNeedsRosterRepair(
    String type,
    Map<String, dynamic> payload,
  ) {
    if (!const {
      'subagent.spawn_requested',
      'subagent.start',
      'subagent.progress',
      'subagent.thinking',
      'subagent.tool',
      'subagent.complete',
    }.contains(type)) {
      return false;
    }
    final subagentId = payload['subagent_id']?.toString().trim() ?? '';
    if (subagentId.isEmpty) return true;
    final activity = _subagentActivities?.activities
        .where((candidate) => candidate.subagentId == subagentId)
        .firstOrNull;
    if (activity == null) return true;
    if (type == 'subagent.complete') return !activity.isTerminal;
    return activity.isTerminal;
  }

  DesktopGatewayCapabilityState desktopCapabilityState(
    DesktopGatewayCapability capability,
  ) {
    final gateway = _desktopGateway;
    return gateway is HermesDesktopSessionActivityGateway
        ? (gateway as HermesDesktopSessionActivityGateway).capabilityState(
            capability,
          )
        : DesktopGatewayCapabilityState.unknown;
  }

  /// Inicio del runtime remoto (equivalente a sessionStartedAt en Desktop).
  DateTime? get desktopStartedAt => _desktopStartedAt;

  /// Inicio del turno visible (equivalente a turnStartedAt en Desktop).
  DateTime? get desktopTurnStartedAt => _desktopTurnStartedAt;
  bool get hasDesktopTransport => _desktopGateway != null;
  bool get hasDesktopRuntime => _desktopRuntimeSessionId != null;
  bool get resumeReconciliationInFlight =>
      _resumeReconcileReservations > 0 || _resumeReconcileFlight != null;

  void _reserveResumeReconciliation() {
    if (!_disposed) _resumeReconcileReservations += 1;
  }

  void _releaseResumeReconciliation() {
    if (_resumeReconcileReservations > 0) _resumeReconcileReservations -= 1;
  }

  static const Duration _passiveRemoteActivityWindow = Duration(seconds: 9);

  /// Rachas de ausencia exigidas antes de dar por terminado un runtime que el
  /// roster ya no anuncia. Una sola lectura puede perder la fila por una
  /// carrera de la lista; dos seguidas ya no.
  static const int _terminalAuthorityAbsenceStreak = 2;

  /// Último runtime que este chat vio anunciado por un roster completo.
  String? _rosterLiveRuntimeSessionId;
  int _rosterRuntimeAbsenceStreak = 0;
  int? _viewerTurnConvergenceEpoch;

  /// Equivalente a `sawAssistantPayload` de Desktop: prueba de que el runtime
  /// llegó a arrancar este turno. Recién enviado, el backend informa la sesión
  /// como inactiva mientras el stream local ya espera su primer frame, y
  /// cosecharlo ahí apagaría un turno que está a punto de producir.
  bool get _turnSawRuntimePayload =>
      _streamingConfirmed || _desktopTurnStartedAt != null || trace.isNotEmpty;

  bool get _clientSubmittedCurrentTurn {
    final delivery = _activeTurnDelivery;
    return _turnSubmittedAtMs != null ||
        (delivery != null &&
            delivery.current.state != PreparedTurnState.terminal);
  }

  bool get _viewerTurnConvergenceIsCurrent =>
      _viewerTurnConvergenceEpoch == _turnEpoch &&
      isStreaming &&
      !_runTerminal &&
      !_clientSubmittedCurrentTurn;

  PassiveActivityAggregate get passiveActivityAggregate {
    if (_passiveDurableToolActivity.isEmpty) {
      return PassiveActivityAggregate.empty;
    }
    final completed = _passiveDurableToolActivity.values
        .where((activity) => activity.completed)
        .length;
    return PassiveActivityAggregate(
      total: _passiveDurableToolActivity.length,
      active: _passiveDurableToolActivity.length - completed,
      completed: completed,
    );
  }

  bool get hasRecentPassiveRemoteActivity =>
      !isStreaming && _passiveActivityVisible;

  /// A live roster row can prove that another surface owns the current turn
  /// even while this client still retains an attached runtime handle. Holding
  /// that handle does not prove that this transport is still the event sink.
  bool get remoteSurfaceOwnsLiveTurn =>
      !isStreaming &&
      _passiveRemoteActivityState == DesktopPassiveActivityState.busy;

  bool get canStopSessionWork {
    final schedules = sessionActivity.schedules;
    return isStreaming ||
        remoteSurfaceOwnsLiveTurn ||
        safeActiveSubagentCount > 0 ||
        _backgroundProcesses.isNotEmpty ||
        schedules.any(
          (schedule) => !const {
            'paused',
            'stopped',
            'completed',
            'failed',
            'cancelled',
            'idle',
            'cleared',
          }.contains(schedule.status.trim().toLowerCase()),
        );
  }

  bool get gatewayConnected =>
      _desktopGateway?.isConnected ?? _transportStatus.isConnected;

  bool get hasAuthoritativePassiveRemoteActivity => remoteSurfaceOwnsLiveTurn;

  /// A privacy-safe liveness aggregate may survive presentation-lease loss.
  /// Detailed rows and every action remain governed by [subagentActivities]
  /// and the existing foreground proof/control guards.
  int get safeActiveSubagentCount {
    final count =
        _subagentActivities?.activities
            .where(
              (activity) =>
                  !activity.isTerminal &&
                  activity.phase != SubagentActivityPhase.unknown,
            )
            .length ??
        0;
    return count.clamp(0, 6);
  }

  void _cancelPassiveActivityExpiry() {
    _passiveActivityExpiryGeneration += 1;
    _passiveActivityExpiryTimer?.cancel();
    _passiveActivityExpiryTimer = null;
  }

  void _schedulePassiveActivityExpiry() {
    _cancelPassiveActivityExpiry();
    final generation = _passiveActivityExpiryGeneration;
    _passiveActivityExpiryTimer = Timer(_passiveRemoteActivityWindow, () {
      _passiveActivityExpiryTimer = null;
      if (_disposed ||
          generation != _passiveActivityExpiryGeneration ||
          !_passiveActivityVisible ||
          _passiveRemoteActivityState == DesktopPassiveActivityState.busy) {
        return;
      }
      _passiveActivityVisible = false;
      _emit(ActiveChatEvent.sessionInfo);
    });
  }

  bool _applyPassiveActivityState(DesktopPassiveActivityState next) {
    final previousState = _passiveRemoteActivityState;
    final previousVisible = _passiveActivityVisible;
    _passiveRemoteActivityState = next;
    switch (next) {
      case DesktopPassiveActivityState.busy:
        _passiveActivityVisible = true;
        _cancelPassiveActivityExpiry();
      case DesktopPassiveActivityState.idle:
        _passiveActivityVisible = false;
        _cancelPassiveActivityExpiry();
        _passiveDurableToolActivity.clear();
      case DesktopPassiveActivityState.unknown:
        if (_passiveActivityVisible &&
            previousState != DesktopPassiveActivityState.unknown) {
          _schedulePassiveActivityExpiry();
        }
    }
    return previousState != next || previousVisible != _passiveActivityVisible;
  }

  String? get _passiveRosterStoredSessionId =>
      (_desktopStoredSessionId ??
              (_viewerTurnConvergenceEpoch == _turnEpoch
                  ? serverSessionId
                  : null))
          ?.trim();

  bool _passiveRemoteActivityRequestStillCurrent({
    required String storedSessionId,
    required String? runtimeSessionId,
    required int turnEpoch,
    required int bindEpoch,
    required int sessionEpoch,
    required int requestGeneration,
    required bool streaming,
  }) =>
      !_disposed &&
      // El roster es una instantánea asíncrona: si el turno arrancó o terminó
      // entre la petición y su respuesta, el estado local es más nuevo.
      isStreaming == streaming &&
      activeChatPassiveActivityRequestStillCurrent(
        expectedStoredSessionId: storedSessionId,
        currentStoredSessionId: _passiveRosterStoredSessionId,
        expectedRuntimeSessionId: runtimeSessionId,
        currentRuntimeSessionId: _desktopRuntimeSessionId,
        expectedTurnEpoch: turnEpoch,
        currentTurnEpoch: _turnEpoch,
        expectedBindEpoch: bindEpoch,
        currentBindEpoch: _desktopBindEpoch,
        expectedSessionEpoch: sessionEpoch,
        currentSessionEpoch: _desktopSessionEpoch,
        expectedRequestGeneration: requestGeneration,
        currentRequestGeneration: _passiveRemoteActivityRequestGeneration,
      );

  Future<void> refreshPassiveRemoteActivity() async {
    if (_disposed) return;
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopSessionActivityGateway) return;
    final activityGateway = gateway as HermesDesktopSessionActivityGateway;
    final storedId = _passiveRosterStoredSessionId;
    if (storedId == null || storedId.isEmpty) return;
    final requestGeneration = ++_passiveRemoteActivityRequestGeneration;
    final requestRuntimeSessionId = _desktopRuntimeSessionId;
    final requestTurnEpoch = _turnEpoch;
    final requestBindEpoch = _desktopBindEpoch;
    final requestSessionEpoch = _desktopSessionEpoch;
    final requestStreaming = isStreaming;
    try {
      final active = await activityGateway.listActiveSessions();
      if (!_passiveRemoteActivityRequestStillCurrent(
        storedSessionId: storedId,
        runtimeSessionId: requestRuntimeSessionId,
        turnEpoch: requestTurnEpoch,
        bindEpoch: requestBindEpoch,
        sessionEpoch: requestSessionEpoch,
        requestGeneration: requestGeneration,
        streaming: requestStreaming,
      )) {
        return;
      }
      await applyAuthoritativeActiveSessionList(active);
      // Con un turno propio vivo el roster solo aporta autoridad terminal: la
      // máquina de presentación pasiva describe la actividad de otra superficie.
      if (isStreaming) return;
      final rows = active.sessions.where(
        (candidate) => candidate.storedSessionId == storedId,
      );
      // `active_list` puede contener varias generaciones del mismo durable ID.
      // Solo una lista vacía o filas explícitamente `idle` prueban reposo; un
      // estado nuevo/ausente se conserva como activo para no drenar a ciegas.
      final activityState = activeChatPassiveRowsState(
        rows,
        hasMalformedRows: active.hasMalformedRows,
      );
      if (activityState == DesktopPassiveActivityState.busy &&
          _passiveRemoteActivityState != DesktopPassiveActivityState.busy) {
        // This read-only busy edge is the observer's last causal instant before
        // its REST refresh can publish the remote turn's durable rows.
        _captureActiveTurnTranscriptBoundary(_turnEpoch);
        _passiveTurnBoundaryFresh = true;
      }
      final activityChanged = _applyPassiveActivityState(activityState);
      final staleStopCleared =
          activityState == DesktopPassiveActivityState.idle &&
          !canStopSessionWork &&
          _clearFailedStopConfirmation();
      if (activityChanged || staleStopCleared) {
        _emit(ActiveChatEvent.sessionInfo);
      }
      if (activityState == DesktopPassiveActivityState.idle &&
          !_queueDrainSuspended &&
          !hasDesktopRuntime &&
          !isStreaming) {
        // The inventory result is already authoritative for this generation.
        // Start the async drain directly: a zero-delay Timer can outlive a
        // disposed widget even when there is no queued work to process.
        unawaited(_drainQueue());
      }
    } catch (_) {
      // Capability absence or a transient inventory failure cannot prove idle,
      // and it is never evidence of absence for the terminal authority either.
      if (!isStreaming &&
          _passiveRemoteActivityRequestStillCurrent(
            storedSessionId: storedId,
            runtimeSessionId: requestRuntimeSessionId,
            turnEpoch: requestTurnEpoch,
            bindEpoch: requestBindEpoch,
            sessionEpoch: requestSessionEpoch,
            requestGeneration: requestGeneration,
            streaming: requestStreaming,
          )) {
        _applyPassiveActivityState(DesktopPassiveActivityState.unknown);
      }
    }
  }

  /// Applies one complete roster result already fetched by another activity
  /// owner, so Home and an open chat can share the same liveness authority.
  Future<void> applyAuthoritativeActiveSessionList(
    DesktopActiveSessionList roster,
  ) async {
    if (roster.hasMalformedRows) return;
    if (_viewerTurnConvergenceIsCurrent) {
      await _settleViewerTurnFromRoster(roster);
      return;
    }
    final runtimeId = _desktopRuntimeSessionId;
    if (runtimeId == null) return;
    if (roster.sessions.any((row) => row.runtimeSessionId == runtimeId)) {
      _rosterLiveRuntimeSessionId = runtimeId;
      _rosterRuntimeAbsenceStreak = 0;
      return;
    }
    if (!isStreaming || _runTerminal) return;
    if (!_turnSawRuntimePayload) {
      final submittedAtMs = _turnSubmittedAtMs;
      if (submittedAtMs == null ||
          _wallClockMs() - submittedAtMs <
              _preTurnLiveSettleGrace.inMilliseconds) {
        _rosterRuntimeAbsenceStreak = 0;
        return;
      }
    } else if (_rosterLiveRuntimeSessionId != runtimeId) {
      return;
    }
    if (++_rosterRuntimeAbsenceStreak < _terminalAuthorityAbsenceStreak) return;
    _rosterRuntimeAbsenceStreak = 0;
    _rosterLiveRuntimeSessionId = null;
    _sealRecoveredLiveActivity(completed: true);
    await _completeRun(
      finalOutput: assistantContent.isEmpty ? null : assistantContent,
      finalOutputNarratable: false,
    );
  }

  Future<void> _settleViewerTurnFromRoster(
    DesktopActiveSessionList roster,
  ) async {
    if (!_viewerTurnConvergenceIsCurrent) return;
    final storedId = (_desktopStoredSessionId ?? serverSessionId).trim();
    if (storedId.isEmpty) return;
    final matchingRows = roster.sessions.where(
      (row) => row.storedSessionId == storedId,
    );
    if (matchingRows.any((row) => rosterStatusIsBusy(row.status))) {
      _rosterRuntimeAbsenceStreak = 0;
      return;
    }
    if (++_rosterRuntimeAbsenceStreak < _terminalAuthorityAbsenceStreak) return;
    _rosterRuntimeAbsenceStreak = 0;
    _rosterLiveRuntimeSessionId = null;
    _viewerTurnConvergenceEpoch = null;
    _desktopAutomaticReattachGeneration += 1;
    _sealRecoveredLiveActivity(completed: true);
    await _completeRun(
      finalOutput: assistantContent.isEmpty ? null : assistantContent,
      finalOutputNarratable: false,
    );
  }

  bool get desktopManualCompressionInFlight => _desktopCompressionInFlight;
  // A retained safety fence is not evidence that the server is still working.
  // Once the reconciliation window runs out without proof the fence is
  // released (Hermes Desktop never locks input on compression); what remains
  // is this dismissible "could not confirm" notice.
  bool get desktopCompressionNeedsConfirmation =>
      !_desktopCompressionRpcInFlight &&
      _pendingDesktopCompression == null &&
      _desktopCompressionUnconfirmable;

  /// The user acknowledged the "could not confirm" notice.
  void dismissCompressionConfirmation() {
    if (!_desktopCompressionUnconfirmable) return;
    _desktopCompressionUnconfirmable = false;
    if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
  }

  bool get desktopCompressionAwaitingReconciliation =>
      _pendingDesktopCompression != null;
  bool get desktopCompressionTransportUncertain =>
      _pendingDesktopCompression?.cause ==
      _DesktopCompressionPendingCause.ambiguousTransport;
  bool get desktopCompressionInFlight =>
      _desktopCompressionInFlight || _desktopAutoCompacting;
  bool get desktopAutoCompacting => _desktopAutoCompacting;

  /// Cuántas veces se ha compactado esta sesión en total, según el propio
  /// contador durable del backend (`usage.compressions`). A diferencia de
  /// [desktopCompressionInFlight] o del `CompactionTracker` de la pantalla,
  /// esto no es transitorio: sobrevive a reconexiones y a reabrir la app, así
  /// que es la fuente correcta para una señal persistente de "esta sesión se
  /// compactó alguna vez", no solo mientras dura o justo termina una.
  int get desktopSessionCompressionCount =>
      _compressionCountFromInfo(_desktopRuntimeInfo) ?? 0;

  /// Inicio (reloj local) de la compactación en curso, automática o manual;
  /// `null` si no hay ninguna. Hermes no publica progreso: la pastilla mide el
  /// tiempo desde aquí y estima el resto del historial local.
  DateTime? get desktopCompactionStartedAt =>
      desktopCompressionInFlight ? _desktopCompactionStartedAt : null;

  /// Tamaño de partida que Hermes fija en la línea `compressing N messages
  /// (~T tok)` del `/compress` en curso.
  int? get desktopCompactionTokensBefore =>
      desktopCompressionInFlight ? _desktopCompactionTokensBefore : null;
  int? get desktopCompactionMessagesBefore =>
      desktopCompressionInFlight ? _desktopCompactionMessagesBefore : null;

  /// Progreso determinado real (trozo / total) si el backend lo publica en el
  /// estado de compactación. El actual NO lo envía: casi siempre es `null`.
  int? get desktopCompactionChunkIndex =>
      desktopCompressionInFlight ? _desktopCompactionChunkIndex : null;
  int? get desktopCompactionChunkCount =>
      desktopCompressionInFlight ? _desktopCompactionChunkCount : null;

  /// Cuántos `status.update(compacted)` ha visto esta sesión. Es la señal de
  /// fin de una compactación cuyo resultado llega tarde (compute host): el RPC
  /// respondió `pending` y el final solo se sabe por este borde.
  int get desktopCompactedEdgeCount => _desktopCompactedEdgeCount;
  String get desktopCompactionLineageId =>
      _desktopCompactionLineageId ?? logicalSessionId;
  bool get canLoadDesktopContextBreakdown =>
      _desktopRuntimeSessionId != null &&
      _desktopGateway is HermesDesktopContextUsageGateway;
  bool get canCompressDesktopSession =>
      !connection.readOnly &&
      !mutationsBlockedByOwnershipConflict &&
      _desktopRuntimeSessionId != null &&
      (_desktopGateway is HermesDesktopCompressionGateway ||
          _desktopGateway is HermesDesktopCommandGateway);
  bool get canConfigureDesktopSession =>
      !connection.readOnly &&
      !mutationsBlockedByOwnershipConflict &&
      _desktopRuntimeSessionId != null &&
      _desktopGateway is HermesDesktopSessionConfigGateway;

  SessionEffectiveConfig get effectiveSessionConfig {
    final scope = _sessionConfigScope;
    return scope == null
        ? const SessionEffectiveConfig()
        : _sessionConfigState[scope]?.effective ??
              const SessionEffectiveConfig();
  }

  PendingSessionConfigChange? pendingSessionConfigChange(
    DesktopSessionConfigKey key,
  ) {
    final scope = _sessionConfigScope;
    return scope == null ? null : _sessionConfigState.changeFor(scope, key);
  }

  void stageFirstSubmitConfig(DesktopSessionCreateConfig config) {
    if (mutationsBlockedByOwnershipConflict) return;
    if (_desktopRuntimeSessionId == null) _stagedFirstSubmitConfig = config;
  }

  InteractivePromptState get interactivePrompts => _interactivePrompts;

  /// First live prompt owned by the currently attached runtime. Other chats
  /// keep their own parked state in their own [ActiveChat] instance.
  InteractivePromptEntry? get pendingInteractivePrompt {
    final runtimeId = _desktopRuntimeSessionId;
    if (runtimeId == null) return null;
    for (final entry in _interactivePrompts.forRuntime(runtimeId)) {
      if (entry.needsInput && entry.request != null) return entry;
    }
    return null;
  }

  bool get needsInput =>
      pendingApproval != null ||
      pendingInteractivePrompt != null ||
      _desktopContinuationRequired;

  @visibleForTesting
  bool get activityWatchdogArmed => _activityWatchdogTimer != null;
  bool get noActivityHint => _noActivityHint;

  // Live control state refreshed by reads and `session.control.update` pushes.
  SessionGoalSnapshot? _goal;
  SessionLoopSnapshot? _loop;
  SessionHeartbeatSnapshot? _heartbeat;
  List<SessionActivityTask> _sessionTasks = const [];
  int _sessionTaskRevision = -1;

  /// Lista de tareas del agente (`todo_list`) de la sesión, o vacía.
  AgentTaskList _agentTasks = AgentTaskList.empty;
  AgentTaskList get agentTasks => _agentTasks;
  bool _sessionControlStale = false;
  int _sessionControlAbsenceStreak = 0;
  Future<void>? _sessionControlRefreshFlight;
  bool _sessionControlRefreshQueued = false;
  SessionGoalSnapshot? get goal => _goal;
  String? _lastNotifiedGoalStatus;

  bool get _hasSessionControl =>
      _goal != null || _loop != null || _heartbeat != null;

  void _applySessionControl(
    SessionControlSnapshot snapshot, {
    required bool authoritativePush,
  }) {
    final absent =
        snapshot.goal == null &&
        snapshot.loop == null &&
        snapshot.heartbeat == null;
    if (!authoritativePush && absent && _hasSessionControl) {
      _sessionControlAbsenceStreak += 1;
      if (_sessionControlAbsenceStreak < 2) return;
    } else {
      _sessionControlAbsenceStreak = 0;
    }
    _goal = snapshot.goal;
    _loop = snapshot.loop;
    _heartbeat = snapshot.heartbeat;
    _sessionControlStale = false;
    _syncGoalWatch();
    _emit(ActiveChatEvent.goalUpdated);
  }

  void _applySessionControlUpdate(Object? control) {
    if (control is! Map) return;
    _applySessionControl(
      SessionControlSnapshot.fromJson(control),
      authoritativePush: true,
    );
  }

  void _applyTodoUpdate(Map<String, dynamic> payload) {
    _adoptAgentTasks(AgentTaskList.tryParse(payload), live: true);
  }

  /// Reconstruye la lista desde el `todo_state` de un resume/activate/recovery.
  /// Solo alimenta la presentación: el trabajo pendiente de una lista rancia
  /// no convierte un chat en reposo en «actividad» (eso solo lo hace la lista
  /// que llegó en vivo con un turno en marcha).
  void _hydrateAgentTasks(AgentTaskList? state) =>
      _adoptAgentTasks(state, live: false);

  void _adoptAgentTasks(AgentTaskList? next, {required bool live}) {
    if (next == null) return;
    final revision = next.revision;
    // Una revisión anterior nunca pisa a una posterior; la misma es idempotente.
    if (revision != null && revision < _sessionTaskRevision) return;
    if (revision != null) _sessionTaskRevision = revision;
    var changed = false;
    if (!next.sameContentAs(_agentTasks)) {
      _agentTasks = next;
      changed = true;
    }
    if (live) {
      final tasks = List<SessionActivityTask>.unmodifiable([
        for (final item in next.items)
          SessionActivityTask(
            id: item.id,
            content: item.content,
            status: switch (item.status) {
              AgentTaskStatus.pending => SessionActivityTaskStatus.pending,
              AgentTaskStatus.inProgress =>
                SessionActivityTaskStatus.inProgress,
              AgentTaskStatus.completed => SessionActivityTaskStatus.completed,
              AgentTaskStatus.cancelled => SessionActivityTaskStatus.cancelled,
            },
          ),
      ]);
      var tasksChanged = _sessionTasks.length != tasks.length;
      for (var i = 0; !tasksChanged && i < tasks.length; i++) {
        tasksChanged =
            _sessionTasks[i].id != tasks[i].id ||
            _sessionTasks[i].content != tasks[i].content ||
            _sessionTasks[i].status != tasks[i].status;
      }
      if (tasksChanged) {
        _sessionTasks = tasks;
        changed = true;
      }
    }
    if (changed) _emit(ActiveChatEvent.subagentActivity);
  }

  /// Registers/unregisters this session with [BackgroundGoalWatch] so the
  /// background service polls it for status-transition notifications while
  /// the app isn't in the foreground. A cleared/done goal stops the watch —
  /// there is nothing left to notify about.
  static const _notifiableGoalStates = {'paused', 'done', 'waiting', 'blocked'};

  /// Notifies on a goal state *transition* only — not on every `continue`
  /// turn (which leaves `status` at `active` throughout) and not twice for
  /// the same state. `last_verdict: blocked` takes priority over `status`,
  /// same as Desktop's red-state rule in `session-control-goal.tsx`.
  void _syncGoalWatch() {
    final storedId = _desktopStoredSessionId;
    final goal = _goal;
    if (storedId == null || storedId.isEmpty || goal == null) {
      _lastNotifiedGoalStatus = null;
      return;
    }
    final key = goal.isBlocked ? 'blocked' : goal.status;
    if (key == _lastNotifiedGoalStatus) return;
    _lastNotifiedGoalStatus = key;
    if (!_notifiableGoalStates.contains(key)) return;
    unawaited(() async {
      try {
        await _notifications?.goalTransition(
          title: goal.title,
          status: key,
          connId: connection.id,
          sessionId: storedId,
          profile: _storedSessionProfile,
        );
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[active-chat] goal transition notify failed (${error.runtimeType})',
          );
        }
      }
    }());
  }

  Future<void> _hydrateSessionControl(String runtimeSessionId) async {
    if (!_usingDesktopGateway) return;
    try {
      final gateway = _desktopGateway;
      final snapshot = gateway is HermesDesktopSessionControlGateway
          ? await (gateway as HermesDesktopSessionControlGateway)
                .readSessionControl(runtimeSessionId)
          : SessionControlSnapshot(
              goal: await desktopControlGateway?.readSessionGoal(
                runtimeSessionId,
              ),
              loop: null,
              heartbeat: null,
              revision: '',
              updatedAt: null,
            );
      if (_disposed || _desktopRuntimeSessionId != runtimeSessionId) return;
      _applySessionControl(snapshot, authoritativePush: false);
    } catch (_) {
      if (_disposed || _desktopRuntimeSessionId != runtimeSessionId) return;
      _adaptiveSnapshotFailureRevision += 1;
      if (_hasSessionControl && !_sessionControlStale) {
        _sessionControlStale = true;
        _emit(ActiveChatEvent.goalUpdated);
      }
    }
  }

  Future<void> refreshSessionControl() {
    final activeFlight = _sessionControlRefreshFlight;
    if (activeFlight != null) {
      _sessionControlRefreshQueued = true;
      return activeFlight;
    }
    final runtimeId = _desktopRuntimeSessionId;
    if (runtimeId == null) return Future.value();
    late final Future<void> flight;
    flight = _hydrateSessionControl(runtimeId).whenComplete(() {
      if (!identical(_sessionControlRefreshFlight, flight)) return;
      _sessionControlRefreshFlight = null;
      if (_sessionControlRefreshQueued) {
        _sessionControlRefreshQueued = false;
        unawaited(refreshSessionControl());
      }
    });
    _sessionControlRefreshFlight = flight;
    return flight;
  }

  /// Sends a `session.control` goal action (pause/resume/unwait/clear). The
  /// live state updates from the next `session.control.update` push, not
  /// optimistically here — Console shows what the server confirms, not what
  /// it hopes happened.
  Future<void> sendGoalAction(String action) async {
    final runtimeId = _desktopRuntimeSessionId;
    if (runtimeId == null) return;
    final gateway = _desktopGateway;
    if (gateway is HermesDesktopSessionControlGateway) {
      await (gateway as HermesDesktopSessionControlGateway)
          .sendSessionControlAction(runtimeId, action);
      return;
    }
    await desktopControlGateway?.sendGoalAction(runtimeId, action);
  }

  Future<void> sendSessionControlAction(String action) async {
    final runtimeId = _desktopRuntimeSessionId;
    if (runtimeId == null) {
      throw const TuiGatewayRpcError(
        'session.control',
        'No live runtime is available',
        code: 4007,
      );
    }
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopSessionControlGateway) {
      throw const TuiGatewayRpcError(
        'session.control',
        'Session controls are unavailable',
        code: -32601,
      );
    }
    await (gateway as HermesDesktopSessionControlGateway)
        .sendSessionControlAction(runtimeId, action);
    _requestPostControlRepair();
  }

  Future<void> stopBackgroundProcess(String processId) async {
    final runtimeId = _desktopRuntimeSessionId;
    if (runtimeId == null) {
      throw const TuiGatewayRpcError(
        'process.kill',
        'No live runtime is available',
        code: 4007,
      );
    }
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopControlGateway) {
      throw const TuiGatewayRpcError(
        'process.kill',
        'Background process controls are unavailable',
        code: -32601,
      );
    }
    await (gateway as HermesDesktopControlGateway).killBackgroundProcess(
      runtimeId,
      processId,
    );
    await refreshBackgroundProcesses();
    _requestPostControlRepair();
  }

  Future<void> _bestEffortBackgroundStopRpc(
    Future<void> Function() request,
  ) async {
    try {
      await request().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Set<String> _activeSubagentIdsForStop() => {
    for (final activity
        in _subagentActivities?.activities ?? const <SubagentActivity>[])
      if (!activity.isTerminal &&
          activity.subagentId?.trim().isNotEmpty == true)
        activity.subagentId!.trim(),
  };

  Future<SessionStopResult> stopSessionWork() {
    final existing = _sessionStopFlight;
    if (existing != null) return existing;
    late final Future<SessionStopResult> operation;
    operation = _stopSessionWork().whenComplete(() {
      if (identical(_sessionStopFlight, operation)) _sessionStopFlight = null;
    });
    _sessionStopFlight = operation;
    return operation;
  }

  Future<SessionStopResult> _stopSessionWork() async {
    final runtimeId = _desktopRuntimeSessionId;
    final gateway = _desktopGateway;
    final HermesDesktopSubagentGateway? subagentGateway =
        gateway is HermesDesktopSubagentGateway
        ? gateway as HermesDesktopSubagentGateway
        : null;
    final HermesDesktopProcessStopGateway? processStopGateway =
        gateway is HermesDesktopProcessStopGateway
        ? gateway as HermesDesktopProcessStopGateway
        : null;
    final HermesDesktopControlGateway? controlGateway =
        gateway is HermesDesktopControlGateway
        ? gateway as HermesDesktopControlGateway
        : null;
    final subagentIds = _activeSubagentIdsForStop();
    final processIds = _backgroundProcesses
        .map((process) => process.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    final verifiesBackgroundWork =
        runtimeId != null &&
        gateway != null &&
        (subagentIds.isNotEmpty || processIds.isNotEmpty);
    var result = SessionStopResult(
      remainingSubagents: subagentIds.length,
      remainingProcesses: processIds.length,
    );
    if (verifiesBackgroundWork) {
      _backgroundStopVerificationInFlight = true;
      _backgroundStopRemainingTasks = null;
      _emit(ActiveChatEvent.queueChanged);
    }

    try {
      await cancel();
      if (!verifiesBackgroundWork) {
        return const SessionStopResult(
          remainingSubagents: 0,
          remainingProcesses: 0,
        );
      }

      final requests = <Future<void>>[
        if (subagentGateway != null)
          for (final subagentId in subagentIds)
            _bestEffortBackgroundStopRpc(
              () => subagentGateway
                  .interruptSubagent(runtimeId, subagentId)
                  .then<void>((_) {}),
            ),
        if (processStopGateway != null)
          _bestEffortBackgroundStopRpc(
            () => processStopGateway.stopBackgroundProcesses(runtimeId),
          ),
      ];
      await Future.wait(requests);

      for (final delay in _backgroundStopRecheckDelays) {
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        if (_disposed ||
            !identical(gateway, _desktopGateway) ||
            _desktopRuntimeSessionId != runtimeId) {
          break;
        }
        await Future.wait<void>([
          if (subagentGateway != null) refreshSubagents(),
          if (controlGateway != null) refreshBackgroundProcesses(),
        ]);
        final subagentsCleared =
            subagentIds.isEmpty ||
            (subagentGateway != null &&
                _subagentLiveRosterConfirmed &&
                safeActiveSubagentCount == 0);
        final processesCleared =
            processIds.isEmpty ||
            (controlGateway != null &&
                _backgroundProcessLiveRosterConfirmed &&
                _backgroundProcesses.isEmpty);
        result = SessionStopResult(
          remainingSubagents: subagentsCleared ? 0 : safeActiveSubagentCount,
          remainingProcesses: processesCleared
              ? 0
              : _backgroundProcesses.length,
        );
        if (subagentsCleared && processesCleared) break;
      }
      return result;
    } finally {
      if (verifiesBackgroundWork) {
        _backgroundStopVerificationInFlight = false;
        _backgroundStopRemainingTasks = result.remainingBackgroundTasks;
        if (!_disposed) _emit(ActiveChatEvent.queueChanged);
      }
    }
  }

  bool get canControlGoal =>
      !connection.readOnly &&
      !mutationsBlockedByOwnershipConflict &&
      (_desktopGateway is HermesDesktopSessionControlGateway ||
          desktopControlGateway != null);

  bool get canControlSessionActivity =>
      !connection.readOnly &&
      _desktopGateway is HermesDesktopSessionControlGateway;

  bool get canStopBackgroundProcesses =>
      !connection.readOnly && _desktopGateway is HermesDesktopControlGateway;

  List<SubagentActivity> get subagentActivities {
    if (_disposed ||
        !_subagentForegroundPresentationLeased ||
        _subagentPresentationState !=
            _SubagentPresentationState.foregroundCurrent) {
      return const [];
    }
    final publicActivities = _subagentPublicActivities;
    final durableCompletions = <SubagentCompletionCardData>[
      for (final message in _messages)
        if (historicalSubagentCompletionOf(message)
            case final SubagentCompletionCardData completion)
          completion,
    ];
    if (durableCompletions.isEmpty) return publicActivities;
    return publicActivities
        .where(
          (activity) => !durableCompletions.any(
            (completion) =>
                activity.delegationId != null &&
                activity.delegationId == completion.delegationId &&
                activity.subagentId != null &&
                completion.subagentIds.contains(activity.subagentId),
          ),
        )
        .toList(growable: false);
  }

  List<SubagentActivity> _collectPrivateSubagentProjection() {
    final visible = <SubagentActivity>[];
    final visibleKeys = <SubagentActivityKey>{};
    void addVisible(SubagentActivity activity) {
      if (visibleKeys.contains(activity.key) ||
          visible.any(
            (shown) => _sameDurableSubagentIdentity(shown, activity),
          )) {
        return;
      }
      visibleKeys.add(activity.key);
      visible.add(activity);
    }

    for (final activity
        in _subagentActivities?.activities ?? const <SubagentActivity>[]) {
      if (_subagentPublicEligibleKeys.contains(activity.key)) {
        addVisible(activity);
      }
    }
    for (final activity in _subagentHistoricalEvidence) {
      if (_subagentPublicEligibleKeys.contains(activity.key)) {
        addVisible(activity);
      }
    }
    for (final activity in _retiredSubagentTerminals) {
      if (_subagentPublicEligibleKeys.contains(activity.key)) {
        addVisible(activity);
      }
    }
    if (visible.isEmpty) return const [];
    final durableCompletions = <SubagentCompletionCardData>[
      for (final message in _messages)
        if (historicalSubagentCompletionOf(message)
            case final SubagentCompletionCardData completion)
          completion,
    ];
    if (durableCompletions.isEmpty) {
      return List<SubagentActivity>.unmodifiable(visible);
    }
    return visible
        .where(
          (activity) => !durableCompletions.any(
            (completion) =>
                activity.delegationId != null &&
                activity.delegationId == completion.delegationId &&
                activity.subagentId != null &&
                completion.subagentIds.contains(activity.subagentId),
          ),
        )
        .toList(growable: false);
  }

  void _refreshCurrentSubagentPublicProjection() {
    if (_subagentForegroundPresentationLeased &&
        _subagentPresentationState ==
            _SubagentPresentationState.foregroundCurrent) {
      _subagentPublicActivities = _collectPrivateSubagentProjection();
    }
  }

  SubagentActivityAggregate get subagentAggregate =>
      SubagentActivityAggregate.fromActivities(
        _subagentActivities?.activities ?? const <SubagentActivity>[],
      );

  int get activeSubagentCount => subagentActivities
      .where(
        (activity) =>
            !activity.isTerminal &&
            activity.phase != SubagentActivityPhase.unknown,
      )
      .length;

  List<SessionActivityProcess> get backgroundProcesses => _backgroundProcesses;
  bool get hasActiveBackgroundProcesses => _backgroundProcesses.isNotEmpty;

  SessionActivity get sessionActivity {
    final foregroundKind = _desktopAutoCompacting
        ? SessionActivityKind.compacting
        : switch (activityKind) {
            ChatActivityKind.thinking => SessionActivityKind.generating,
            ChatActivityKind.usingTools => SessionActivityKind.usingTools,
            ChatActivityKind.responding => SessionActivityKind.responding,
            ChatActivityKind.awaitingApproval =>
              SessionActivityKind.waitingForUser,
            null => SessionActivityKind.idle,
          };
    final schedules = <SessionActivitySchedule>[
      if (_loop case final loop?)
        SessionActivitySchedule(
          kind: SessionActivityScheduleKind.loop,
          status: loop.status,
          interval: loop.interval,
          lastRunAt: loop.lastRunAt,
          nextDueAt: loop.nextDueAt,
          runCount: loop.ticksFired,
          awaitingResponse: loop.awaitingResponse,
          deferredByGoal: loop.deferredByGoal,
        ),
      if (_heartbeat case final heartbeat?)
        SessionActivitySchedule(
          kind: SessionActivityScheduleKind.heartbeat,
          status: heartbeat.status,
          interval: heartbeat.interval,
          lastRunAt: heartbeat.lastRunAt,
          nextDueAt: heartbeat.nextDueAt,
          runCount: heartbeat.fireCount,
        ),
    ];
    return SessionActivity(
      foregroundTurn: isStreaming,
      rosterTurn: remoteSurfaceOwnsLiveTurn,
      subagentCount: safeActiveSubagentCount,
      processes: _backgroundProcesses,
      schedules: schedules,
      goal: _goal == null
          ? null
          : SessionActivityGoal(title: _goal!.title, status: _goal!.status),
      tasks: _sessionTasks,
      foregroundKind: foregroundKind,
      // Misma señal combinada que el CompactionDock del chat: un `/compress`
      // manual o una valla durable restaurada no tocan
      // `_desktopAutoCompacting` ni abren turno, así que solo por aquí llegan
      // a Home/Conversaciones. Es de presentación y no entra en `active`
      // (ver SessionActivity.compacting).
      compacting: desktopCompressionInFlight,
      observedAt: _backgroundProcessesObservedAt ?? _desktopTurnStartedAt,
      stale: _backgroundProcessesStale || _sessionControlStale,
    );
  }

  bool _backgroundProcessRequestStillCurrent({
    required Object gateway,
    required String connectionId,
    required String profile,
    required String durableSessionId,
    required String runtimeSessionId,
    required int bindEpoch,
    required int sessionEpoch,
    required int turnEpoch,
    required int requestGeneration,
    required int mutationGeneration,
  }) =>
      !_disposed &&
      identical(_desktopGateway, gateway) &&
      connection.id == connectionId &&
      _storedSessionProfile == profile &&
      serverSessionId == durableSessionId &&
      _desktopRuntimeSessionId == runtimeSessionId &&
      _desktopBindEpoch == bindEpoch &&
      _desktopSessionEpoch == sessionEpoch &&
      _turnEpoch == turnEpoch &&
      _backgroundProcessListRequestGeneration == requestGeneration &&
      _backgroundProcessMutationGeneration == mutationGeneration;

  static bool _sameBackgroundProcess(
    SessionActivityProcess left,
    SessionActivityProcess right,
  ) =>
      left.id == right.id &&
      left.command == right.command &&
      left.notifyOnComplete == right.notifyOnComplete &&
      left.startedAt == right.startedAt &&
      left.watchHit == right.watchHit &&
      listEquals(left.watchPatterns, right.watchPatterns);

  bool get hasPendingBackgroundProcessRefresh =>
      _backgroundProcessRefreshFlight != null;

  Future<void> refreshBackgroundProcesses() {
    _backgroundProcessRefreshRequested = true;
    final current = _backgroundProcessRefreshFlight;
    if (current != null) return current;

    late final Future<void> flight;
    flight = _drainBackgroundProcessRefreshes().whenComplete(() {
      if (!identical(_backgroundProcessRefreshFlight, flight)) return;
      _backgroundProcessRefreshFlight = null;
      if (!_disposed) _onUnused?.call();
    });
    _backgroundProcessRefreshFlight = flight;
    return flight;
  }

  Future<void> _drainBackgroundProcessRefreshes() async {
    while (_backgroundProcessRefreshRequested && !_disposed) {
      _backgroundProcessRefreshRequested = false;
      await _performBackgroundProcessRefresh();
    }
  }

  Future<void> _performBackgroundProcessRefresh() async {
    final desktopGateway = _desktopGateway;
    final processGateway = desktopGateway is HermesDesktopControlGateway
        ? desktopGateway as HermesDesktopControlGateway
        : null;
    final runtimeId = _desktopRuntimeSessionId;
    if (processGateway == null || runtimeId == null) return;

    final requestGeneration = ++_backgroundProcessListRequestGeneration;
    final connectionId = connection.id;
    final profile = _storedSessionProfile;
    final durableId = serverSessionId;
    final bindEpoch = _desktopBindEpoch;
    final sessionEpoch = _desktopSessionEpoch;
    final turnEpoch = _turnEpoch;
    final mutationGeneration = _backgroundProcessMutationGeneration;
    late final AgentCenterSnapshot snapshot;
    try {
      snapshot = await processGateway.agentCenterSnapshot(
        runtimeSessionId: runtimeId,
      );
    } catch (_) {
      if (_backgroundProcessRequestStillCurrent(
        gateway: processGateway,
        connectionId: connectionId,
        profile: profile,
        durableSessionId: durableId,
        runtimeSessionId: runtimeId,
        bindEpoch: bindEpoch,
        sessionEpoch: sessionEpoch,
        turnEpoch: turnEpoch,
        requestGeneration: requestGeneration,
        mutationGeneration: mutationGeneration,
      )) {
        _adaptiveSnapshotFailureRevision += 1;
        final nextStale = _backgroundProcesses.isNotEmpty;
        if (_backgroundProcessesStale != nextStale) {
          _backgroundProcessesStale = nextStale;
          _emit(ActiveChatEvent.subagentActivity);
        }
      }
      return;
    }
    if (!_backgroundProcessRequestStillCurrent(
          gateway: processGateway,
          connectionId: connectionId,
          profile: profile,
          durableSessionId: durableId,
          runtimeSessionId: runtimeId,
          bindEpoch: bindEpoch,
          sessionEpoch: sessionEpoch,
          turnEpoch: turnEpoch,
          requestGeneration: requestGeneration,
          mutationGeneration: mutationGeneration,
        ) ||
        !snapshot.processesFullyParsed) {
      return;
    }

    final now = DateTime.now();
    final currentById = {
      for (final process in _backgroundProcesses) process.id: process,
    };
    final activeRows = <String, BackgroundProcessEntry>{};
    final terminalIds = <String>{};
    for (final row in snapshot.processes) {
      switch (row.status) {
        case AgentCenterStatus.requested:
        case AgentCenterStatus.running:
        case AgentCenterStatus.thinking:
        case AgentCenterStatus.tool:
          activeRows[row.opaqueId] = row;
        case AgentCenterStatus.completed:
        case AgentCenterStatus.failed:
        case AgentCenterStatus.cancelled:
        case AgentCenterStatus.stopped:
          terminalIds.add(row.opaqueId);
        case AgentCenterStatus.unknown:
          break;
      }
    }

    final next = <SessionActivityProcess>[];
    for (final row in activeRows.values) {
      final current = currentById[row.opaqueId];
      _backgroundProcessAbsenceStreaks.remove(row.opaqueId);
      next.add(
        SessionActivityProcess(
          id: row.opaqueId,
          command: row.command.isEmpty ? current?.command ?? '' : row.command,
          notifyOnComplete: row.notifyOnComplete,
          startedAt:
              row.startedAt ??
              current?.startedAt ??
              now.subtract(Duration(seconds: row.uptimeSeconds)),
          watchPatterns: row.watchPatterns.isEmpty
              ? current?.watchPatterns ?? const []
              : row.watchPatterns,
          watchHit: row.watchHit,
        ),
      );
    }
    for (final current in _backgroundProcesses) {
      if (activeRows.containsKey(current.id) ||
          terminalIds.contains(current.id)) {
        _backgroundProcessAbsenceStreaks.remove(current.id);
        continue;
      }
      final absenceStreak =
          (_backgroundProcessAbsenceStreaks[current.id] ?? 0) + 1;
      if (absenceStreak < 2) {
        _backgroundProcessAbsenceStreaks[current.id] = absenceStreak;
        next.add(current);
      } else {
        _backgroundProcessAbsenceStreaks.remove(current.id);
      }
    }
    next.sort((left, right) => left.id.compareTo(right.id));
    final changed =
        next.length != _backgroundProcesses.length ||
        List.generate(
          next.length,
          (index) =>
              !_sameBackgroundProcess(next[index], _backgroundProcesses[index]),
        ).any((different) => different);
    final staleChanged = _backgroundProcessesStale;
    _backgroundProcessesObservedAt = now;
    _backgroundProcessesStale = false;
    _backgroundProcessLiveRosterConfirmed = true;
    if (!changed && !staleChanged) return;
    _backgroundProcesses = List.unmodifiable(next);
    _backgroundProcessMutationGeneration += 1;
    _emit(ActiveChatEvent.subagentActivity);
  }

  @visibleForTesting
  Future<void> refreshBackgroundProcessesForTesting() =>
      refreshBackgroundProcesses();

  _SubagentRefreshAuthority _currentSubagentRefreshAuthority() =>
      _SubagentRefreshAuthority(
        gateway: _desktopGateway,
        connectionId: connection.id,
        profile: _storedSessionProfile,
        durableSessionId: serverSessionId,
        runtimeSessionId: _desktopRuntimeSessionId,
        bindEpoch: _desktopBindEpoch,
        sessionEpoch: _desktopSessionEpoch,
        turnEpoch: _turnEpoch,
        presentationLeased: _subagentForegroundPresentationLeased,
        presentationGeneration: _subagentForegroundPresentationGeneration,
      );

  Future<void> _hydrateSubagentsForCurrentRuntime() {
    final authority = _currentSubagentRefreshAuthority();
    final inFlight = _subagentRefreshFlight;
    final inFlightAuthority = _subagentRefreshAuthority;
    if (inFlight != null &&
        inFlightAuthority != null &&
        inFlightAuthority.sameAs(authority)) {
      return inFlight;
    }

    late final Future<void> refresh;
    final Future<void> request;
    if (inFlight == null) {
      request = _performSubagentHydration();
    } else {
      request = inFlight.then<void>((_) async {
        if (!_currentSubagentRefreshAuthority().sameAs(authority)) {
          return;
        }
        await _performSubagentHydration();
      });
    }
    refresh = request.whenComplete(() {
      if (identical(_subagentRefreshFlight, refresh)) {
        _subagentRefreshFlight = null;
        _subagentRefreshAuthority = null;
      }
    });
    _subagentRefreshAuthority = authority;
    _subagentRefreshFlight = refresh;
    return refresh;
  }

  Future<void> _performSubagentHydration() async {
    final gateway = _desktopGateway;
    final runtimeId = _desktopRuntimeSessionId;
    if (gateway is! HermesDesktopSubagentGateway || runtimeId == null) {
      return;
    }
    final requestGeneration = ++_subagentListRequestGeneration;
    final connectionId = connection.id;
    final profile = _storedSessionProfile;
    final durableId = serverSessionId;
    final bindEpoch = _desktopBindEpoch;
    final sessionEpoch = _desktopSessionEpoch;
    final turnEpoch = _turnEpoch;
    final mutationGeneration = _subagentMutationGeneration;
    final presentationGeneration = _subagentForegroundPresentationGeneration;
    late final List<DesktopSubagentSnapshot> rows;
    try {
      rows = await (gateway as HermesDesktopSubagentGateway).listSubagents(
        runtimeId,
      );
    } catch (_) {
      if (!_disposed &&
          identical(_desktopGateway, gateway) &&
          _desktopRuntimeSessionId == runtimeId) {
        _adaptiveSnapshotFailureRevision += 1;
      }
      return;
    }
    if (_disposed ||
        !identical(_desktopGateway, gateway) ||
        connection.id != connectionId ||
        _storedSessionProfile != profile ||
        serverSessionId != durableId ||
        _desktopRuntimeSessionId != runtimeId ||
        _desktopBindEpoch != bindEpoch ||
        _desktopSessionEpoch != sessionEpoch ||
        _turnEpoch != turnEpoch ||
        _subagentListRequestGeneration != requestGeneration ||
        _subagentMutationGeneration != mutationGeneration) {
      return;
    }
    // A fully fenced list is the live-roster authority for this runtime. Local
    // terminal evidence survives, but an absent nonterminal row is not live.
    final hadControlAuthority = _subagentControlAuthority.any(
      (key) => key.scope.runtimeSessionId == runtimeId,
    );
    _subagentControlAuthority.removeWhere(
      (key) => key.scope.runtimeSessionId == runtimeId,
    );
    var rosterChanged = false;
    final current = _subagentActivities;
    if (current != null && current.scope.runtimeSessionId == runtimeId) {
      final liveIds = rows.map((row) => row.subagentId).toSet();
      final retained = <SubagentActivityKey, SubagentActivity>{
        for (final activity in current.activities)
          if (activity.isTerminal ||
              (activity.subagentId != null &&
                  liveIds.contains(activity.subagentId)))
            activity.key: activity,
      };
      if (retained.length != current.entries.length) {
        _subagentActivities = SubagentActivityState.withEntries(
          current.scope,
          retained,
        );
        _subagentMutationGeneration += 1;
        rosterChanged = true;
      }
    }
    for (final row in rows) {
      final type = switch (row.status) {
        'thinking' => 'subagent.thinking',
        'tool' || 'using_tool' => 'subagent.tool',
        _ => 'subagent.start',
      };
      _handleNativeSubagentEvent(type, runtimeId, <String, dynamic>{
        'subagent_id': row.subagentId,
        if (row.parentId != null) 'parent_id': row.parentId,
        if (row.depth != null) 'depth': row.depth,
        if (row.goal != null) 'goal': row.goal,
        if (row.delegationId != null) 'delegation_id': row.delegationId,
        if (row.model != null) 'model': row.model,
        if (row.startedAt != null)
          'started_at': row.startedAt!.toIso8601String(),
        'status': row.status,
        if (row.toolCount != null) 'tool_count': row.toolCount,
        if (row.lastTool != null) 'tool_name': row.lastTool,
        if (row.acceptingSteer != null) 'accepting_steer': row.acceptingSteer,
      }, presentationProof: false);
    }
    final canProvePresentation =
        _subagentForegroundPresentationLeased &&
        _subagentForegroundPresentationGeneration == presentationGeneration;
    if (canProvePresentation) {
      _subagentPresentationState = _SubagentPresentationState.foregroundCurrent;
      _subagentControlAuthority.clear();
      final liveIds = rows.map((row) => row.subagentId).toSet();
      _subagentPublicEligibleKeys.clear();
      for (final activity
          in _subagentActivities?.activities ?? const <SubagentActivity>[]) {
        if (activity.isTerminal ||
            (activity.subagentId != null &&
                liveIds.contains(activity.subagentId))) {
          _subagentPublicEligibleKeys.add(activity.key);
        }
        if (!activity.isTerminal &&
            activity.subagentId != null &&
            liveIds.contains(activity.subagentId)) {
          _subagentControlAuthority.add(activity.key);
        }
      }
      _subagentPublicActivities = _collectPrivateSubagentProjection();
    }
    // Every fence above held and the roster was applied, so this response is
    // authority over what is still live for this runtime. Record that, since
    // it is the only evidence presentation may settle a row on.
    _subagentLiveRosterConfirmed = true;
    if (canProvePresentation ||
        ((hadControlAuthority || rosterChanged) && rows.isEmpty)) {
      _emit(ActiveChatEvent.subagentActivity);
    }
  }

  /// A fenced `subagent.list` has been applied for the current runtime and no
  /// live child remains in it. This — not a turn that ended — is the evidence
  /// that outstanding delegated work is over: a background delegation keeps
  /// running past its parent turn, and a failed or never-answered list is
  /// never evidence of absence.
  bool get subagentLiveRosterConfirmedEmpty =>
      _subagentLiveRosterConfirmed && safeActiveSubagentCount == 0;

  Future<void> refreshSubagents() => _hydrateSubagentsForCurrentRuntime();

  SubagentPresentationOwnerToken acquireSubagentForegroundPresentation() {
    if (_disposed) {
      throw StateError('Subagent presentation owner is unavailable');
    }
    final token = SubagentPresentationOwnerToken._(this);
    final wasUnowned = _subagentPresentationOwners.isEmpty;
    _subagentPresentationOwners.add(token);
    if (wasUnowned) {
      _subagentForegroundPresentationGeneration += 1;
      _subagentPresentationState =
          _SubagentPresentationState.foregroundPendingProof;
      _subagentPublicActivities = const [];
      _subagentPublicEligibleKeys.clear();
      _subagentControlAuthority.clear();
      _pendingSubagentInterrupts.clear();
    }
    return token;
  }

  bool releaseSubagentForegroundPresentation(
    SubagentPresentationOwnerToken token,
  ) {
    if (!identical(token._issuer, this) ||
        !_subagentPresentationOwners.remove(token)) {
      return false;
    }
    if (_subagentPresentationOwners.isNotEmpty) return true;
    suspendSubagentForegroundPresentation();
    return true;
  }

  void suspendSubagentForegroundPresentation() {
    final hadPublicProjection = _subagentPublicActivities.isNotEmpty;
    _subagentPresentationOwners.clear();
    _subagentForegroundPresentationGeneration += 1;
    _subagentPresentationState = _SubagentPresentationState.unowned;
    _subagentPublicActivities = const [];
    _subagentPublicEligibleKeys.clear();
    final changed =
        hadPublicProjection ||
        _subagentControlAuthority.isNotEmpty ||
        _pendingSubagentInterrupts.isNotEmpty;
    _subagentControlAuthority.clear();
    _pendingSubagentInterrupts.clear();
    _subagentMutationGeneration += 1;
    if (changed && !_disposed) _emit(ActiveChatEvent.subagentActivity);
  }

  @visibleForTesting
  Future<void> refreshSubagentsForTesting() => refreshSubagents();

  bool _ownsCurrentSubagent(SubagentActivity activity) {
    final current = _subagentActivities;
    final runtimeId = _desktopRuntimeSessionId;
    return runtimeId != null &&
        activity.subagentId != null &&
        current != null &&
        current.scope.runtimeSessionId == runtimeId &&
        current.scope == activity.key.scope &&
        identical(current[activity.key], activity) &&
        _subagentControlAuthority.contains(activity.key);
  }

  bool get canSteerLiveTurn =>
      connection.kind != InstanceKind.localhost &&
      _usingDesktopGateway &&
      _desktopGateway != null;

  bool canSteerSubagent(SubagentActivity activity) =>
      !connection.readOnly &&
      !mutationsBlockedByOwnershipConflict &&
      !activity.isTerminal &&
      activity.phase != SubagentActivityPhase.unknown &&
      activity.details.acceptingSteer != false &&
      _desktopGateway is HermesDesktopSubagentGateway &&
      _ownsCurrentSubagent(activity);

  Future<DesktopSubagentSteerResult> steerSubagent(
    SubagentActivity activity,
    String text,
  ) => _trackRuntimeMutation(() => _steerSubagent(activity, text));

  Future<DesktopSubagentSteerResult> _steerSubagent(
    SubagentActivity activity,
    String text,
  ) async {
    if (!canSteerSubagent(activity)) {
      throw StateError('Subagent steer is unavailable');
    }
    final gateway = _desktopGateway as HermesDesktopSubagentGateway;
    final runtimeId = _desktopRuntimeSessionId!;
    final bindEpoch = _desktopBindEpoch;
    final sessionEpoch = _desktopSessionEpoch;
    final presentationGeneration = _subagentForegroundPresentationGeneration;
    final result = await gateway.steerSubagent(
      runtimeId,
      activity.subagentId!,
      text,
    );
    if (_disposed ||
        _desktopRuntimeSessionId != runtimeId ||
        _desktopBindEpoch != bindEpoch ||
        _desktopSessionEpoch != sessionEpoch ||
        !_subagentForegroundPresentationLeased ||
        _subagentForegroundPresentationGeneration != presentationGeneration ||
        !_ownsCurrentSubagent(activity)) {
      throw StateError('Subagent steer result is stale');
    }
    return result;
  }

  Future<DesktopSubagentTailResult> tailSubagent(
    SubagentActivity activity,
  ) async {
    if (!canTailSubagent(activity)) {
      throw StateError('Subagent tail is unavailable');
    }
    final gateway = _desktopGateway as HermesDesktopSubagentGateway;
    final runtimeId = _desktopRuntimeSessionId!;
    final bindEpoch = _desktopBindEpoch;
    final sessionEpoch = _desktopSessionEpoch;
    final presentationGeneration = _subagentForegroundPresentationGeneration;
    final result = await gateway.tailSubagent(runtimeId, activity.subagentId!);
    if (_disposed ||
        _desktopRuntimeSessionId != runtimeId ||
        _desktopBindEpoch != bindEpoch ||
        _desktopSessionEpoch != sessionEpoch ||
        !_subagentForegroundPresentationLeased ||
        _subagentForegroundPresentationGeneration != presentationGeneration ||
        !_ownsCurrentSubagent(activity)) {
      throw StateError('Subagent tail result is stale');
    }
    return result;
  }

  bool canTailSubagent(SubagentActivity activity) =>
      !activity.isTerminal &&
      activity.phase != SubagentActivityPhase.unknown &&
      _desktopGateway is HermesDesktopSubagentGateway &&
      _ownsCurrentSubagent(activity);

  bool isSubagentInterruptPending(SubagentActivity activity) =>
      _pendingSubagentInterrupts.containsKey(activity.key);

  bool canInterruptSubagent(SubagentActivity activity) {
    final phase = activity.phase;
    final hasAuthoritativeLivePhase =
        phase == SubagentActivityPhase.running ||
        phase == SubagentActivityPhase.thinking ||
        phase == SubagentActivityPhase.tool;
    if (connection.readOnly ||
        !hasAuthoritativeLivePhase ||
        activity.subagentId == null) {
      return false;
    }
    final current = _subagentActivities;
    if (current == null || current.scope != activity.key.scope) return false;
    if (!identical(current[activity.key], activity) ||
        !_subagentControlAuthority.contains(activity.key)) {
      return false;
    }
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopSubagentGateway) return false;
    final capability = (gateway as HermesDesktopSubagentGateway)
        .capabilityState(DesktopGatewayCapability.subagentInterrupt);
    return capability != DesktopGatewayCapabilityState.unsupported &&
        capability != DesktopGatewayCapabilityState.invalid;
  }

  /// Detiene un único hijo mediante el RPC oficial. El reducer no cambia a
  /// cancelado hasta recibir un evento autoritativo del servidor.
  Future<bool> interruptSubagent(SubagentActivity activity) async {
    if (!canInterruptSubagent(activity) ||
        _pendingSubagentInterrupts.containsKey(activity.key)) {
      throw StateError('Subagent interrupt is unavailable');
    }
    final gateway = _desktopGateway as HermesDesktopSubagentGateway;
    final runtimeId = _desktopRuntimeSessionId!;
    final pending = _PendingSubagentInterrupt(
      token: Object(),
      key: activity.key,
      gateway: gateway,
      connectionId: connection.id,
      profile: _storedSessionProfile,
      durableSessionId: serverSessionId,
      runtimeSessionId: runtimeId,
      bindEpoch: _desktopBindEpoch,
      sessionEpoch: _desktopSessionEpoch,
      turnEpoch: _turnEpoch,
      presentationGeneration: _subagentForegroundPresentationGeneration,
    );
    _pendingSubagentInterrupts[activity.key] = pending;
    _emit(ActiveChatEvent.subagentActivity);
    try {
      final result = await gateway.interruptSubagent(
        runtimeId,
        activity.subagentId!,
      );
      final isCurrent =
          identical(_pendingSubagentInterrupts[activity.key], pending) &&
          identical(
            _pendingSubagentInterrupts[activity.key]?.token,
            pending.token,
          ) &&
          !_disposed &&
          identical(_desktopGateway, pending.gateway) &&
          connection.id == pending.connectionId &&
          _storedSessionProfile == pending.profile &&
          serverSessionId == pending.durableSessionId &&
          _desktopRuntimeSessionId == pending.runtimeSessionId &&
          _desktopBindEpoch == pending.bindEpoch &&
          _desktopSessionEpoch == pending.sessionEpoch &&
          _turnEpoch == pending.turnEpoch &&
          _subagentForegroundPresentationLeased &&
          _subagentForegroundPresentationGeneration ==
              pending.presentationGeneration &&
          _subagentActivities?.scope == pending.key.scope;
      final found = isCurrent && result.found;
      if (found) _requestPostControlRepair();
      return found;
    } finally {
      final current = _pendingSubagentInterrupts[activity.key];
      final changed = identical(current, pending);
      if (changed) _pendingSubagentInterrupts.remove(activity.key);
      if (changed && !_disposed) _emit(ActiveChatEvent.subagentActivity);
    }
  }

  /// Builds the session artifact index only when its view is opened. The
  /// pending input contains structured messages only, never the full text
  /// transcript, and comes from a snapshot/REST response already loaded by the
  /// chat. Reopening the same revision returns the cached immutable result.
  List<SessionArtifact> resolveSessionArtifacts() {
    final scope = _artifactScope;
    if (scope == null) return const [];
    final policy = _artifactPolicy();
    _artifactIndex = ArtifactIndex.resolve(
      previous: _artifactIndex,
      scope: scope,
      transcriptRevision: _artifactTranscriptRevision,
      transcript: _pendingArtifactTranscript,
      policy: policy,
    );
    return _artifactIndex!.artifacts;
  }

  @visibleForTesting
  ArtifactIndexSnapshot? get resolvedArtifactIndex => _artifactIndex;

  /// Internal newest-first transcript. Reconciliation metadata stays on these
  /// exact maps so dedupe and viewport-sensitive updates preserve identity.
  List<Map<String, dynamic>> _messages = [];
  String? _terminalWarning;
  int? _terminalWarningEpoch;
  String? _lastDurableTailIdentity;
  bool _passiveActivityVisible = false;
  Timer? _passiveActivityExpiryTimer;
  int _passiveActivityExpiryGeneration = 0;
  final LinkedHashMap<String, _PassiveDurableActivity>
  _passiveDurableToolActivity = LinkedHashMap();
  DesktopPassiveActivityState _passiveRemoteActivityState =
      DesktopPassiveActivityState.unknown;
  bool _desktopQueueAuthorityCheckInFlight = false;
  bool _desktopTerminalRequiresLifecycleEvidence = false;
  int _passiveRemoteActivityRequestGeneration = 0;
  final TranscriptPublicationCoordinator _transcriptPublication =
      TranscriptPublicationCoordinator();
  List<Map<String, dynamic>>? _publicMessagesSnapshot;
  List<Map<String, dynamic>>? _publicMessagesSources;
  final HashMap<Map<String, dynamic>, Map<String, dynamic>>
  _publicMessageByInternalIdentity =
      HashMap<Map<String, dynamic>, Map<String, dynamic>>.identity();

  /// Sanitized read-only presentation snapshot. No reconciliation-only key is
  /// observable through the production ActiveChat API. Stable internal rows
  /// retain their public map identity while their presentation is unchanged.
  List<Map<String, dynamic>> get messages {
    final displaySources = _applyDurablePrivateTranscriptVetoes(_messages);
    final projected = _projectTranscriptForDisplay(
      displaySources,
      retainEmptyAssistant: isStreaming,
      retainedBySource: _publicMessageByInternalIdentity,
    );
    final previous = _publicMessagesSnapshot;
    final previousSources = _publicMessagesSources;
    if (previous != null &&
        previousSources != null &&
        previousSources.length == displaySources.length &&
        projected.length == previous.length) {
      final sameSources = Iterable<int>.generate(displaySources.length).every(
        (index) => identical(previousSources[index], displaySources[index]),
      );
      if (sameSources &&
          Iterable<int>.generate(
            projected.length,
          ).every((index) => mapEquals(previous[index], projected[index]))) {
        return previous;
      }
    }
    final snapshot = List<Map<String, dynamic>>.unmodifiable(projected);
    _publicMessagesSources = List<Map<String, dynamic>>.of(displaySources);
    _publicMessagesSnapshot = snapshot;
    return snapshot;
  }

  List<Map<String, dynamic>> _applyDurablePrivateTranscriptVetoes(
    List<Map<String, dynamic>> source,
  ) => _transcriptPublication.project(source);

  /// Conserva evidencia negativa fuera de las filas visibles para que REST,
  /// cache, recovery y settlement posteriores no puedan resucitar la identidad.
  /// Devuelve true cuando el snapshot retiró una fila interna ya publicada.
  bool _recordDurablePrivateTranscriptVetoes(
    Iterable<DesktopSessionMessage> messages,
  ) {
    _transcriptPublication.reduce(
      messages.map((row) => row.transcriptPrivacyObservation),
    );
    final safe = _applyDurablePrivateTranscriptVetoes(_messages);
    if (identical(safe, _messages)) return false;
    _messages = safe;
    return true;
  }

  @visibleForTesting
  List<Map<String, dynamic>> get internalMessagesForTesting => _messages;

  /// Consumes the bounded, non-fatal producer warning exactly once for the
  /// mounted chat surface. It is diagnostic state, never assistant content.
  String? takeTerminalWarning() {
    final warning = _terminalWarning;
    _terminalWarning = null;
    return warning;
  }

  @visibleForTesting
  set internalMessagesForTesting(List<Map<String, dynamic>> value) {
    _messages = value.toList(growable: true);
  }

  @visibleForTesting
  List<Map<String, dynamic>> pruneCompactedTerminalRowsForTesting(
    List<Map<String, dynamic>> candidate,
    List<TranscriptMessageIdentity> unconfirmed,
  ) {
    _transcriptExtent = _TranscriptExtent.complete;
    _transcriptCoverageHasParseGap = false;
    _unconfirmedRetainedTranscriptIdentities
      ..clear()
      ..addAll(unconfirmed);
    return _pruneUnconfirmedRowsAtTranscriptStart(candidate);
  }

  @visibleForTesting
  List<Map<String, dynamic>> mergeCompactedTerminalRowsForTesting(
    List<Map<String, dynamic>> retainedLocal,
    List<Map<String, dynamic>> durableNewestFirst,
  ) => _mergeRetainedLocalWithDurable(retainedLocal, durableNewestFirst);

  @visibleForTesting
  void settleLiveUsersAlreadyRepresentedByDurableTailForTesting() {
    _settleLiveUsersAlreadyRepresentedByDurableTail();
  }

  @visibleForTesting
  Set<int> liveUserProjectionIndexesAfterActiveTurnBoundaryForTesting() =>
      _liveUserProjectionIndexesAfterActiveTurnBoundary(_messages);

  @visibleForTesting
  void captureActiveTurnTranscriptBoundaryForTesting({
    bool allowExistingTranscript = true,
  }) {
    _captureActiveTurnTranscriptBoundary(
      _turnEpoch,
      allowExistingTranscript: allowExistingTranscript,
    );
  }

  @visibleForTesting
  void beginExternallyObservedDesktopTurnForTesting(
    DesktopSessionSnapshot snapshot,
  ) {
    _beginExternallyObservedDesktopTurn(snapshot);
  }

  @visibleForTesting
  void replaceInternalMessagesForTesting(List<Map<String, dynamic>> value) {
    _messages = value.toList(growable: true);
  }

  bool messagesLoaded = false;
  bool _localTranscriptOlderHistoryTruncated = false;

  /// Reconciliation-only state for terminal projections. These fences used to
  /// ride on display message maps; the privacy projector deliberately strips
  /// those private keys before UI publication, so retain the minimum identity
  /// evidence out-of-band instead of leaking it through [_messages].
  final List<_TerminalProjectionFence> _privateTerminalProjectionFences = [];

  /// The encrypted local cache contains only a retained recent suffix.
  bool get localTranscriptOlderHistoryTruncated =>
      _localTranscriptOlderHistoryTruncated;

  /// Bookkeeping de la hidratación paginada del transcript. REST is the
  /// durable authority, so each request uses the Dashboard hard maximum and
  /// advances by the raw returned count until a short page proves the end.
  /// Offsets are measured backwards from the newest message; no `total` oracle
  /// exists upstream.
  final int _transcriptPageSize;
  bool _earlierMessagesAvailable = false;
  int _earlierMessagesNextOffset = 0;
  bool _earlierMessagesInFlight = false;
  int _remainingInitialBackfillPages = _maxInitialBackfillPages;

  /// Solo se eleva a UI tras un intento real de backfill que no obtuvo una
  /// página legible. La cobertura meramente desconocida no es un error.
  bool _earlierMessagesLoadFailed = false;

  /// Un snapshot que omite mensajes puede demostrar que la proyección visible
  /// ya no cubre la cola actual. En ese caso el siguiente gesto debe hidratar
  /// `offset=0` antes de continuar con las páginas anteriores.
  bool _needsTranscriptTailHydration = false;

  /// Filas conservadas provisionalmente cuando una cola paginada nueva no
  /// comparte ancla con lo visible. Si una página posterior no confirma sus
  /// ids antes de alcanzar el inicio absoluto, pertenecían a una proyección
  /// compactada vieja y se retiran entonces, nunca durante el refresh.
  final List<TranscriptMessageIdentity>
  _unconfirmedRetainedTranscriptIdentities = <TranscriptMessageIdentity>[];

  /// Evidencia sobre el alcance de la ventana visible. `unknown` y `partial`
  /// fallan cerrado: solo una lectura one-shot, una página final o un snapshot
  /// que incluya mensajes permiten proyectar un tombstone `firstUser`.
  _TranscriptExtent _transcriptExtent = _TranscriptExtent.unknown;

  /// Una fila REST descartada deja un hueco durable aunque páginas posteriores
  /// alcancen el inicio absoluto. Se limpia únicamente cuando una fuente
  /// autoritativa y completa sustituye toda la cobertura, no al terminar el
  /// backfill que contiene el hueco.
  bool _transcriptCoverageHasParseGap = false;

  /// Revisión transaccional del cursor/cobertura. Un refresh y un backfill
  /// pueden compartir `_messageLoadEpoch` cuando el gesto de scroll empieza
  /// después del refresh; esta revisión impide que la respuesta pedida con el
  /// cursor anterior aterrice sobre el bookkeeping que el refresh ya reemplazó.
  int _transcriptCoverageRevision = 0;

  /// Resume diferido (Hermes Agent 0.20, upstream 60be8ef26): el ack de
  /// `session.resume` llega con `hydrating:true` y el historial se carga en
  /// segundo plano; `session.resume_progress` anuncia el desenlace.
  bool _desktopHistoryHydrating = false;
  bool _desktopHistoryNeedsHydration = false;
  int? _desktopHydrationExpectedMessageCount;

  /// From [loadMessages] `expectedMessageCount`. Snapshot hydration may
  /// null `_desktopHydrationExpectedMessageCount`; this must survive until
  /// a complete transcript replaces coverage.
  int? _hardExpectedStoredMessageCount;
  Future<void>? _desktopHistoryHydrationFlight;
  int? _desktopHistoryHydrationFlightEpoch;
  bool? _desktopHydrationOutcome;
  Completer<bool>? _desktopHydrationWaiter;

  /// Quedan mensajes anteriores en el servidor más allá de lo ya cargado.
  bool get hasEarlierMessages => _earlierMessagesAvailable;

  /// El último intento de cargar una página anterior falló. Es la única causa
  /// para mostrar la recuperación flotante de historial.
  bool get earlierMessagesLoadFailed => _earlierMessagesLoadFailed;

  @visibleForTesting
  int get transcriptCoverageRevisionForTesting => _transcriptCoverageRevision;

  @visibleForTesting
  String get transcriptExtentForTesting => _transcriptExtent.name;

  @visibleForTesting
  bool get transcriptCoverageHasParseGapForTesting =>
      _transcriptCoverageHasParseGap;

  @visibleForTesting
  int get earlierMessagesNextOffsetForTesting => _earlierMessagesNextOffset;

  @visibleForTesting
  bool get needsTranscriptTailHydrationForTesting =>
      _needsTranscriptTailHydration;

  @visibleForTesting
  bool get desktopHistoryNeedsHydrationForTesting =>
      _desktopHistoryNeedsHydration;

  /// Whether the visible read model proves a complete, lossless lineage.
  /// A terminal short REST page closes only tip pagination; it does not prove
  /// that compressed ancestors or display metadata were returned.
  bool get coreReadLineageComplete => _coreReadLineageComplete == true;

  bool get coreReadCoverageIsPartial =>
      (_coreReadCoverage.contains(CoreReadCoverage.full) &&
          !coreReadLineageComplete) ||
      _coreReadCoverage.any(
        <CoreReadCoverage>{
          CoreReadCoverage.tipOnly,
          CoreReadCoverage.metadataPartial,
          CoreReadCoverage.aggregateOnly,
          CoreReadCoverage.unsupported,
        }.contains,
      );

  bool get _transcriptIsComplete =>
      _transcriptExtent == _TranscriptExtent.complete &&
      !_transcriptCoverageHasParseGap;

  /// El runtime enlazado está hidratando su historial en segundo plano.
  bool get isHydratingDesktopHistory => _desktopHistoryHydrating;

  final List<ChatTraceEvent> trace = [];
  // Projection-only tracker for Voz. It intentionally does not rewrite the
  // approved chat trace: progress frames are coalesced here while the visible
  // cards keep their established semantics.
  final List<({String? callId, String label})> _activeVoiceTools = [];
  bool traceActive = false;
  ChatPipelineState state = ChatPipelineState.idle;
  String lastPrompt = '';

  /// Modelo y perfil del último turno. Los reutiliza el fallback de cola para
  /// enviar una indicación como turno siguiente cuando `session.redirect` no está
  /// disponible o el agente ya no puede aceptarla en el turno vivo.
  String _lastModel = '';
  String _turnProfile = '';
  DesktopSessionCreateConfig _turnSessionConfig =
      const DesktopSessionCreateConfig();
  DesktopSessionCreateConfig _stagedFirstSubmitConfig =
      const DesktopSessionCreateConfig();
  Object? _queueAdmissionToken;
  bool? _queueAdmissionAllowTransportFallback;

  ActiveTurnDelivery? _activeTurnDelivery;

  /// Evidencia viva del turno, accesible al reenganchar una pantalla. Mientras
  /// exista, la reapertura no debe reinterpretar `submitting` como process death.
  ActiveTurnDelivery? get activeTurnDelivery => _activeTurnDelivery;

  /// Retira un adjunto del turno vivo y revoca la asociación de imagen que ya
  /// hubiese aceptado Desktop. Un remove durante el RPC queda cubierto por el
  /// attempt fence del callback; este camino cubre el intervalo posterior al
  /// ACK de `image.attach_bytes` y anterior a `prompt.submit`.
  Future<bool> removeActiveAttachment(String localId) async {
    if (mutationsBlockedByOwnershipConflict) return false;
    return _trackRuntimeMutation(() => _removeActiveAttachment(localId));
  }

  Future<bool> _removeActiveAttachment(String localId) async {
    final delivery = _activeTurnDelivery;
    if (delivery == null) return false;
    final previous = await delivery.removeAttachment(localId);
    if (previous == null) return false;
    final remoteRef = previous.remoteRef;
    final remoteSessionId = previous.remoteSessionId;
    final gateway = _desktopGateway;
    if (previous.isImage &&
        previous.remoteTransport == AttachmentRemoteTransport.desktop &&
        remoteRef != null &&
        remoteRef.isNotEmpty &&
        remoteSessionId != null &&
        remoteSessionId.isNotEmpty &&
        gateway is HermesDesktopAttachmentGateway) {
      try {
        await (gateway as HermesDesktopAttachmentGateway).detachImage(
          remoteSessionId,
          remoteRef,
        );
      } catch (error) {
        debugPrint('[attachment] image detach failed (${error.runtimeType})');
      }
    }
    return true;
  }

  void releaseTurnDelivery(ActiveTurnDelivery delivery) {
    if (identical(_activeTurnDelivery, delivery)) _activeTurnDelivery = null;
  }

  /// Fallback compatible con cualquier instancia. Hermes Desktop también
  /// conserva en cola el texto cuando la corrección viva se rechaza o falla.
  final Queue<_QueuedTextTurn> _messageQueue = Queue<_QueuedTextTurn>();
  final Queue<QueuedPreparedTurn> _preparedTurnQueue =
      Queue<QueuedPreparedTurn>();
  final SplayTreeSet<int> _pendingPreparedQueueOrders = SplayTreeSet<int>();
  final Set<String> _pendingPreparedTurnIds = <String>{};
  final Map<String, _PreparedTurnOwner> _preparedTurnOwners = {};
  final Set<String> _preparedTurnCancellationsInFlight = <String>{};
  int _nextQueueOrder = 0;
  int _queueGeneration = 0;
  int _queueParkGeneration = 0;
  bool _preparedTurnDrainInFlight = false;
  bool _queueDrainSuspended = false;
  bool _queueAdmissionFrozen = false;
  QueueLease _queueLease = QueueLease.active;
  Future<void> _queuedRestoreTail = Future<void>.value();
  int? _reusableQueueStopGeneration;
  String? _blockedPreparedTurnId;
  Timer? _queuedRetryTimer;
  Timer? _queuedTextRetryTimer;
  final Map<String, int> _queuedRetryAttempts = {};
  // Entradas cuyo reintento automático se agotó: siguen en el panel esperando
  // un envío manual. Desktop avisa con un toast (`queueStuckTitle`) al llegar
  // aquí; este conjunto es lo que la UI observa para hacer lo mismo una única
  // vez por entrada. Ver `_scheduleQueuedTextRetry` / `_scheduleQueuedRetry`.
  final Set<String> _queuedRetriesExhausted = <String>{};
  // Mismo techo que `MAX_AUTO_DRAIN_ATTEMPTS` gobierna en Desktop.
  static const int _maxQueuedRetryAttempts = 3;
  String? _desktopAcceptedQueuedPrompt;

  /// Ids de entradas en cola que agotaron su reintento automático.
  ///
  /// Réplica de `MAX_AUTO_DRAIN_ATTEMPTS` en `composer-queue.ts`: la entrada no
  /// se pierde (sigue encolada para un envío manual), pero deja de reintentarse
  /// sola, así que alguien tiene que decírselo al usuario.
  /// Las claves son el id de la entrada de texto o el `clientTurnId` del turno
  /// preparado, no el `QueuedEntryView.id` (que prefija `prepared:`): son las
  /// mismas con las que se contaron los intentos.
  ///
  /// Una entrada que ya salió de la cola (enviada a mano, borrada, purgada por
  /// un cambio de generación) deja de estar agotada por definición, así que se
  /// poda contra la cola viva en lugar de acumularse durante toda la sesión.
  Set<String> get queuedRetriesExhausted {
    final live = <String>{
      ..._messageQueue.map((item) => item.id),
      ..._preparedTurnQueue.map((item) => item.turn.clientTurnId),
    };
    _queuedRetriesExhausted.retainWhere(live.contains);
    _queuedRetryAttempts.removeWhere((id, _) => !live.contains(id));
    return Set<String>.unmodifiable(_queuedRetriesExhausted);
  }

  /// Lleva una entrada al estado «agotada» sin tener que provocar los tres
  /// rechazos reales de transporte, que dependen de la admisión de ownership y
  /// del park de Stop. El aviso al usuario se dispara desde
  /// [ActiveChatEvent.queueChanged], así que esto reproduce exactamente lo que
  /// la UI observa al final de la escalera.
  @visibleForTesting
  void markQueuedRetryExhaustedForTesting(String id) {
    _queuedRetryAttempts[id] = _maxQueuedRetryAttempts + 1;
    _queuedRetriesExhausted.add(id);
    _emit(ActiveChatEvent.queueChanged);
  }

  /// Olvida el estado de reintento de una entrada que ya avanzó o desapareció.
  void _clearQueuedRetryState(String id) {
    _queuedRetryAttempts.remove(id);
    _queuedRetriesExhausted.remove(id);
  }

  List<String> get queuedTextMessages => List<String>.unmodifiable([
    if (_desktopAcceptedQueuedPrompt != null)
      stripBotMentionNote(_desktopAcceptedQueuedPrompt!),
    ..._messageQueue.map((item) => stripBotMentionNote(item.text)),
  ]);

  List<String> get queuedMessages {
    final local = <({int order, String text})>[
      ..._messageQueue.map(
        (item) =>
            (order: item.queueOrder, text: stripBotMentionNote(item.text)),
      ),
      ..._preparedTurnQueue.map(
        (item) => (order: item.queueOrder, text: item.turn.text),
      ),
    ]..sort((left, right) => left.order.compareTo(right.order));
    return List<String>.unmodifiable([
      if (_desktopAcceptedQueuedPrompt != null)
        stripBotMentionNote(_desktopAcceptedQueuedPrompt!),
      ...local.map((item) => item.text),
    ]);
  }

  List<QueuedEntryView> get queuedEntries {
    final entries = <QueuedEntryView>[
      ..._messageQueue.map(
        (item) => QueuedEntryView(
          id: item.id,
          kind: QueuedEntryKind.text,
          queueOrder: item.queueOrder,
          text: stripBotMentionNote(item.text),
        ),
      ),
      ..._preparedTurnQueue.map(
        (item) => QueuedEntryView(
          id: 'prepared:${item.turn.clientTurnId}',
          kind: QueuedEntryKind.prepared,
          queueOrder: item.queueOrder,
          text: item.turn.text,
          attachments: List<AttachmentDraft>.unmodifiable(
            item.turn.activeAttachments,
          ),
          blocked: _blockedPreparedTurnId == item.turn.clientTurnId,
        ),
      ),
    ]..sort((left, right) => left.queueOrder.compareTo(right.queueOrder));
    final accepted = _desktopAcceptedQueuedPrompt;
    if (accepted != null) {
      final firstOrder = entries.isEmpty ? 0 : entries.first.queueOrder - 1;
      entries.insert(
        0,
        QueuedEntryView(
          id: 'desktop-accepted',
          kind: QueuedEntryKind.desktopAccepted,
          queueOrder: firstOrder,
          text: stripBotMentionNote(accepted),
        ),
      );
    }
    return List<QueuedEntryView>.unmodifiable(entries);
  }

  List<QueuedPreparedTurn> get queuedTurns =>
      List<QueuedPreparedTurn>.unmodifiable(_preparedTurnQueue);

  bool get queueParked => _queueLease == QueueLease.parked;

  /// El park sólo puede frenar el drenaje automático; esta bandera es la que
  /// realmente lo suspende, así que las pruebas la observan por separado.
  @visibleForTesting
  bool get queueDrainSuspendedForTesting => _queueDrainSuspended;

  /// Levanta el park. El park es un gate del drenaje automático, así que
  /// cualquier gesto explícito del usuario lo retira; nunca decide admisión.
  /// Sólo revierte la suspensión que puso el propio park: otras suspensiones
  /// (conflicto de propiedad, admisión congelada) tienen su propio dueño.
  void _unparkQueueLease() {
    if (_disposed || _queueLease != QueueLease.parked) return;
    _queueLease = QueueLease.resumeRequested;
    _queueDrainSuspended = false;
    _emit(ActiveChatEvent.queueChanged);
  }

  /// Retira un park que ya no sostiene nada. Réplica de `writeSession`
  /// (`composer-queue.ts:91-106`): una cola vacía no tiene nada que frenar y el
  /// park sólo quedaría como gate rancio para entradas muy posteriores. Aquí el
  /// lease vuelve a `active`: no hay nada que reanudar.
  void _unparkQueueLeaseIfEmpty() {
    if (_disposed || _hasQueuedWork) return;
    if (_queueLease == QueueLease.parked) {
      _queueLease = QueueLease.active;
      _queueDrainSuspended = false;
      _emit(ActiveChatEvent.queueChanged);
      return;
    }
    // Un lease de reanudación agotado tampoco tiene ya nada que reanudar.
    if (_queueLease == QueueLease.resumeRequested) {
      _queueLease = QueueLease.active;
    }
  }

  /// Hay algo que un park pueda retener de verdad.
  bool get _hasQueuedWork =>
      _messageQueue.isNotEmpty ||
      _preparedTurnQueue.isNotEmpty ||
      _pendingPreparedQueueOrders.isNotEmpty ||
      _desktopAcceptedQueuedPrompt != null;

  /// Admite un gesto explícito del usuario a través de una cola estacionada.
  ///
  /// El park nunca decide admisión: sólo frena el drenaje automático. Si el
  /// Stop que lo puso sigue vivo se espera su ACK de interrupción, pero de
  /// forma acotada — un gateway antiguo puede no publicarlo nunca.
  Future<void> _admitThroughParkedQueue() async {
    if (_disposed || _queueLease != QueueLease.parked) return;
    final stop = _stopTransition;
    if (stop != null && !stop.isFinal) {
      try {
        await stop.terminal.future.timeout(
          activeChatStopAdmissionSettleTimeout,
        );
      } on TimeoutException {
        // Gateway sin terminal de interrupción: el gesto del usuario manda y
        // el guard de `_onDesktopEvent` descarta un terminal tardío.
      }
      if (_disposed || _queueLease != QueueLease.parked) return;
    }
    _unparkQueueLease();
  }

  /// Reanuda explícitamente la cola que Stop dejó estacionada. Nunca se llama
  /// desde un terminal: el usuario conserva la decisión de volver a enviarla.
  void resumeParkedQueue() {
    if (mutationsBlockedByOwnershipConflict) return;
    if (_queueLease != QueueLease.parked || _disposed) return;
    // Un coordinador terminal —`confirmed`, `failed` o `superseded`— ya no
    // gobierna nada; sólo un Stop todavía en vuelo puede retener la reanudación.
    final stop = _stopTransition;
    if (stop != null && !stop.isFinal) return;
    _queueLease = QueueLease.resumeRequested;
    _queueDrainSuspended = false;
    _emit(ActiveChatEvent.queueChanged);
    if (!isStreaming) Timer.run(_drainQueue);
  }

  static const _activityHintTimeout = Duration(minutes: 5);
  static const _preTurnLiveSettleGrace = Duration(seconds: 15);

  /// Identidad monotónica del turno. Al cancelar/iniciar otro se incrementa;
  /// cualquier callback tardío del transporte anterior queda invalidado y no
  /// puede escribir sobre el estado del nuevo run.
  int _turnEpoch = 0;
  int? _turnSubmittedAtMs;
  Completer<void> _turnEpochInvalidated = Completer<void>();
  int _transcriptRevision = 0;
  _RewriteReservation? _activeRewrite;

  /// Run en curso (motor /v1/runs). Necesario para resolver aprobaciones y
  /// para cancelar.
  String? currentRunId;

  /// Override de la sesión server-side para el turno en curso (lo fija [send]).
  /// null = usar [sessionId]. El modo voz lo usa para rotar su sesión al cancelar.
  String? _serverSessionOverride;

  /// Solicitud de aprobación pendiente del agente (`approval.request`), o null.
  /// La pantalla la pinta como tarjeta con los scopes autorizados por Desktop.
  Map<String, dynamic>? _pendingApproval;
  bool _desktopContinuationRequired = false;
  int _approvalGeneration = 0;

  Map<String, dynamic>? get pendingApproval => _pendingApproval;
  bool get desktopContinuationRequired => _desktopContinuationRequired;

  set pendingApproval(Map<String, dynamic>? value) {
    if (identical(_pendingApproval, value)) return;
    _pendingApproval = value;
    _approvalGeneration += 1;
  }

  // Batching de tokens: acumula y vuelca cada ~33ms para evitar reconstrucciones
  // por token. Vive aquí para que el streaming no dependa del widget.
  static const _desktopStreamCadence = Duration(milliseconds: 33);
  final StringBuffer _tokenBuffer = StringBuffer();
  final StringBuffer _assistantRawStream = StringBuffer();
  String _assistantPublicStream = '';
  Timer? _tokenFlushTimer;
  Timer? _terminalTimer;
  Future<void>? _terminalTranscriptRecovery;
  int? _terminalTranscriptRecoveryEpoch;
  Completer<void> _detachedIdleParked = Completer<void>();
  Completer<void> _desktopRecoveryWake = Completer<void>();
  _TerminalCommitGate _terminalCommitGate = _TerminalCommitGate(0);
  // Por defecto conserva la cadencia histórica que consumen modo voz y tareas
  // sin pantalla. ChatScreen activa el modo fluido o inmediato explícitamente.
  bool _fluidStreaming = false;
  bool _immediateStreaming = false;

  /// La pantalla visible puede desactivar el typewriter cuando Android pide
  /// reducir movimiento. Al apagarlo, vuelca inmediatamente lo pendiente.
  set smoothStreaming(bool value) {
    final changed = _fluidStreaming != value || _immediateStreaming == value;
    if (!changed) return;
    _fluidStreaming = value;
    _immediateStreaming = !value;
    if (_immediateStreaming && _tokenBuffer.isNotEmpty) {
      _flushTokenBuffer();
      state = ChatPipelineState.streaming;
      _emit(ActiveChatEvent.token);
    }
  }

  bool _streamingConfirmed = false;
  bool _cancelling = false;
  bool _disposed = false;
  final Completer<void> _disposeSignal = Completer<void>();
  final Duration _terminalReconcileBudget;
  final Duration _desktopRecoveryAttemptTimeout;
  final List<Duration> _desktopRecoveryBackoff;
  final double Function() _desktopRecoveryRandom;
  final Duration _desktopCompressionReconciliationDelay;
  final Duration _desktopCompressionReconciliationWindow;
  _StopTransitionCoordinator? _stopTransition;

  /// Epoch del último Stop que alcanzó estado terminal. Sobrevive al
  /// desenganche de `_stopTransition` para que `_canRecoverTurn` siga cerrando
  /// la recuperación de ese turno exacto.
  int? _finalizedStopTurnEpoch;
  // Se marca cuando el run llega a un estado terminal (completed/failed/
  // cancelled) para que el cierre del SSE no lo procese dos veces.
  bool _runTerminal = false;
  int? _pendingAuthoritativeTerminalEpoch;
  String? _pendingAuthoritativeTerminalOutput;
  bool _releaseRequested = false;
  List<Map<String, dynamic>>? _rewindRollbackMessages;
  ChatPipelineState? _rewindRollbackState;
  int? _rewind4018FallbackOrdinal;
  bool _rewindRestoredOnError = false;
  bool _rewindDashboardAuthRequired = false;
  bool _dashboardAuthRequired = false;
  int _dashboardAuthAttemptEpoch = 0;
  ChatTransportStatus _transportStatus = const ChatTransportStatus(
    ChatTransportState.connected,
  );
  final ValueNotifier<ChatTransportStatus> _transportStatusListenable =
      ValueNotifier(
        const ChatTransportStatus(ChatTransportState.connected),
      );

  ChatTransportStatus get transportStatus => _transportStatus;
  ValueListenable<ChatTransportStatus> get transportStatusListenable =>
      _transportStatusListenable;

  void _publishTransportState(ChatTransportState state) {
    if (_disposed || _transportStatus.state == state) return;
    final disconnectedSince = state == ChatTransportState.connected
        ? null
        : _transportStatus.disconnectedSince ??
              DateTime.fromMillisecondsSinceEpoch(_wallClockMs());
    _transportStatus = ChatTransportStatus(
      state,
      disconnectedSince: disconnectedSince,
    );
    _transportStatusListenable.value = _transportStatus;
  }

  /// El transcript puede seguir siendo legible por REST aunque el Dashboard no
  /// permita reanudar el canal vivo. La UI observa esta señal no destructiva.
  bool get dashboardAuthRequired => _dashboardAuthRequired;

  void _setDashboardAuthRequired(bool value, {required int attemptEpoch}) {
    if (attemptEpoch != _dashboardAuthAttemptEpoch) return;
    if (_dashboardAuthRequired == value) return;
    _dashboardAuthRequired = value;
    _emit(ActiveChatEvent.dashboardAuthChanged);
  }

  void _publishDashboardAuthRequired(bool value) {
    final attemptEpoch = ++_dashboardAuthAttemptEpoch;
    _setDashboardAuthRequired(value, attemptEpoch: attemptEpoch);
  }

  static bool _isDashboardAuthRequired(Object error) =>
      (error is DashboardAuthException &&
          const {
            DashboardAuthFailureCode.loginRequired,
            DashboardAuthFailureCode.invalidCredentials,
            DashboardAuthFailureCode.sessionCookieMissing,
          }.contains(error.code)) ||
      (error is DashboardWebSocketAuthException &&
          (error.statusCode == 401 || error.statusCode == 403));

  /// La pantalla consume esta señal para explicar que la edición falló pero la
  /// línea temporal original ya fue restaurada.
  bool takeRewindRestoredOnError() {
    final value = _rewindRestoredOnError;
    _rewindRestoredOnError = false;
    return value;
  }

  bool takeRewindDashboardAuthRequired() {
    final value = _rewindDashboardAuthRequired;
    _rewindDashboardAuthRequired = false;
    return value;
  }

  // `/steer` no aparece como mensaje user independiente en el transcript del
  // Gateway (vive dentro de un tool-result). Conservamos una proyección local
  // anclada al ordinal del prompt user para reinsertarla en su posición correcta
  // tras cada refetch, incluso con prompts idénticos o más turnos posteriores.
  final List<SteerProjection> _steerRecords = [];

  // Silence is only a presentation signal. The server remains authoritative
  // over whether the turn is running or failed.
  Timer? _activityWatchdogTimer;
  bool _noActivityHint = false;

  late final StreamController<ActiveChatEvent> _changes;

  ActiveChat({
    required this.connection,
    required this.sessionId,
    String? logicalSessionId,
    required this.sessionTitle,
    this.notificationSurface = NotificationChatSurface.normal,
    this.notificationRoomId,
    required NotificationService? notifications,
    required VoidCallback onTerminal,
    VoidCallback? onUnused,
    Future<void> Function()? beforeTerminalNotification,
    @visibleForTesting Future<void> Function()? beforePrivacyCheckpointSave,
    @visibleForTesting Future<void> Function()? beforePrivacySnapshotLoad,
    @visibleForTesting Future<bool> Function()? historyHydrationAwaiter,
    ApprovalPolicyService? policy,
    void Function(String runId)? onRunStarted,
    Future<void> Function()? onForegroundKeepAlive,
    ValueChanged<int?>? onObservedFirstTokenLatency,
    ValueChanged<ActiveChatEvent>? onEvent,
    int Function()? monotonicMicros,
    int? initialObservedFirstTokenLatencyMs,
    ApiClient? api,
    HermesDesktopGateway? desktopGateway,
    DesktopCompressionFenceStore? compressionFenceStore,
    int Function()? wallClockMs,
    Future<AttachmentUploadResult> Function(SavedConnection, AttachmentDraft)?
    attachmentUploader,
    BridgeClientFactory? bridgeClientFactory,
    BridgeProvisioner? bridgeProvisioner,
    String? sessionProfile,
    String? initialStoredSessionId,
    StoredSessionMessageLoader? storedMessageLoader,
    LocalConversationLifecycle? localConversationLifecycle,
    bool attachDesktopRuntimeOnLoad = false,
    @visibleForTesting bool allowUnownedDesktopSnapshotForTesting = false,
    Future<bool> Function()? turnIdempotencyCapability,
    List<SteerProjection> initialSteerProjections = const [],
    List<CancelledTurnTombstone> initialCancelledTurnTombstones = const [],
    Future<void> Function(CancelledTurnTombstone)? onCancelledTurn,
    Duration terminalReconcileBudget = const Duration(seconds: 4),
    Duration desktopRecoveryAttemptTimeout = const Duration(seconds: 15),
    Duration desktopCompressionReconciliationDelay = const Duration(
      seconds: 20,
    ),
    Duration desktopCompressionReconciliationWindow =
        _desktopCompressionReconciliationFallback,
    @visibleForTesting
    List<Duration> backgroundStopRecheckDelays = const [
      Duration.zero,
      Duration(milliseconds: 1500),
      Duration(milliseconds: 2500),
    ],
    @visibleForTesting
    int transcriptPageSizeForTesting = _authoritativeTranscriptPageSize,
    @visibleForTesting double Function()? desktopRecoveryRandom,
    List<Duration> desktopRecoveryBackoff = const [
      Duration.zero,
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
    ],
  }) : logicalSessionId = logicalSessionId ?? sessionId,
       assert(
         transcriptPageSizeForTesting > 0 &&
             transcriptPageSizeForTesting <= 500,
       ),
       _transcriptPageSize = transcriptPageSizeForTesting,
       _notifications = notifications,
       _policy = policy,
       _onTerminal = onTerminal,
       _onUnused = onUnused,
       _beforeTerminalNotification = beforeTerminalNotification,
       _beforePrivacyCheckpointSave = beforePrivacyCheckpointSave,
       _beforePrivacySnapshotLoad = beforePrivacySnapshotLoad,
       _historyHydrationAwaiter = historyHydrationAwaiter,
       _onRunStarted = onRunStarted,
       _onForegroundKeepAlive = onForegroundKeepAlive,
       _onObservedFirstTokenLatency = onObservedFirstTokenLatency,
       _onEvent = onEvent,
       _cancelledTurnTombstones = List<CancelledTurnTombstone>.of(
         initialCancelledTurnTombstones,
       ),
       _onCancelledTurn = onCancelledTurn,
       _monotonicMicros =
           monotonicMicros ??
           (() => _defaultMonotonicClock.elapsedMicroseconds),
       _observedFirstTokenLatencyMs = initialObservedFirstTokenLatencyMs,
       _terminalReconcileBudget = terminalReconcileBudget,
       _desktopRecoveryAttemptTimeout =
           desktopRecoveryAttemptTimeout > Duration.zero
           ? desktopRecoveryAttemptTimeout
           : const Duration(seconds: 15),
       _desktopCompressionReconciliationDelay =
           _normalizedDesktopCompressionReconciliationDelay(
             desktopCompressionReconciliationDelay,
           ),
       _desktopCompressionReconciliationWindow =
           _normalizedDesktopCompressionReconciliationWindow(
             desktopCompressionReconciliationWindow,
             _normalizedDesktopCompressionReconciliationDelay(
               desktopCompressionReconciliationDelay,
             ),
           ),
       _desktopRecoveryBackoff = _normalizeDesktopRecoveryBackoff(
         desktopRecoveryBackoff,
       ),
       _desktopRecoveryRandom =
           desktopRecoveryRandom ?? math.Random().nextDouble,
       _turnIdempotencyCapability =
           turnIdempotencyCapability ??
           (() => ConnectionManager.isTurnIdempotencySupported(connection.id)),
       _storedMessageLoader = storedMessageLoader,
       _localConversationLifecycle = localConversationLifecycle,
       _attachDesktopRuntimeOnLoad = attachDesktopRuntimeOnLoad,
       _allowUnownedDesktopSnapshotForTesting =
           allowUnownedDesktopSnapshotForTesting,
       _compressionFenceStore =
           compressionFenceStore ?? DesktopCompressionFenceStore(),
       _wallClockMs =
           wallClockMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _backgroundStopRecheckDelays = List<Duration>.unmodifiable(
         backgroundStopRecheckDelays,
       ),
       _desktopGateway =
           desktopGateway ??
           (api == null &&
                   !(connection.kind == InstanceKind.localhost &&
                       connection.onDeviceLoopback)
               ? TuiGatewayClient(connection)
               : null),
       _attachmentUploader = attachmentUploader ?? AttachmentUploader.upload,
       _bridgeClientFactory =
           bridgeClientFactory ??
           (({required baseUrl, required token}) =>
               BridgeClient(baseUrl: baseUrl, token: token)),
       _bridgeProvisioner = bridgeProvisioner ?? BridgeClient.provision {
    _steerRecords.addAll(initialSteerProjections);
    _changes = StreamController<ActiveChatEvent>.broadcast(
      onCancel: _handleLastListenerCancelled,
    );
    _api =
        api ??
        ApiClient(baseUrl: connection.baseUrl, apiKey: connection.apiKey);
    _coreReadIdentity = SessionIdentity(
      logicalRootId: logicalSessionId ?? sessionId,
      storedId: initialStoredSessionId ?? sessionId,
    );
    if (sessionProfile != null) _bindSessionProfile(sessionProfile);
    bindKnownStoredSession(initialStoredSessionId);
    unawaited(_restoreDurableCompressionFence());
  }

  /// Adopts a durable state.db identity without ever retargeting a live runtime.
  ///
  /// Bot Mode and Mission Rooms keep a stable mobile route while Hermes owns an
  /// opaque stored id. Reopening that route may repeat the same binding, but a
  /// different authoritative id must get a fresh [ActiveChat] instead of mixing
  /// transcript, usage and prompt delivery across two server conversations.
  bool bindKnownStoredSession(
    String? storedSessionId, {
    bool authoritative = false,
  }) {
    final durable = authoritative ? storedSessionId : storedSessionId?.trim();
    if (authoritative && durable != null && durable != durable.trim()) {
      return false;
    }
    if (durable == null || durable.isEmpty) {
      if (!authoritative) return true;
      return _desktopStoredSessionId == null &&
          _desktopRuntimeSessionId == null;
    }
    final current = _desktopStoredSessionId;
    if (current != null && current != durable) return false;
    if (authoritative && current == null && _desktopRuntimeSessionId != null) {
      return false;
    }
    _desktopStoredSessionId = durable;
    if (_coreReadIdentity.storedId != durable) {
      _coreReadIdentity = _coreReadIdentity.withStored(durable);
    }
    _desktopStoredSessionKnownMissing = false;
    return true;
  }

  /// Perfil propietario fijado en el binding de esta sesión.
  ///
  /// Es inmutable después de la primera fuente autoritativa (snapshot, carga o
  /// primer submit). Así un cambio posterior de `active_profile_<connId>` no
  /// puede reubicar un resume, rewrite o turno de Voz en otro home.
  String get sessionProfile => _sessionProfileOwner ?? '';

  /// Fija el owner únicamente si este chat todavía no estaba enlazado.
  /// Repetirlo con otro perfil devuelve el owner original y no lo sustituye.
  String bindSessionProfile(String profile) => _bindSessionProfile(profile);

  void bindNotificationTarget(
    NotificationChatSurface surface, {
    String? roomId,
  }) {
    // Una apertura genérica nunca degrada una superficie dedicada que ya
    // conoce su propietario. Bot/Room sí pueden completar un binding legacy.
    if (surface == NotificationChatSurface.normal &&
        notificationSurface != NotificationChatSurface.normal) {
      return;
    }
    notificationSurface = surface;
    notificationRoomId = surface == NotificationChatSurface.room
        ? roomId
        : null;
  }

  String _bindSessionProfile(String requested) {
    final current = _sessionProfileOwner;
    if (current != null) return current;
    final owner = Session.profileOwner(requested);
    _sessionProfileOwner = owner;
    _storedSessionProfile = owner;
    return owner;
  }

  /// Marca un id móvil que todavía no existe en state.db. Además de evitar I/O
  /// al abrir el borrador, permite que el primer submit vaya directamente a
  /// session.create sin pagar antes un session.resume destinado a devolver 4007.
  void markStoredSessionMissing() {
    if (_desktopRuntimeSessionId != null ||
        _desktopStoredSessionId != null ||
        _messages.isNotEmpty) {
      return;
    }
    _desktopStoredSessionKnownMissing = true;
    messagesLoaded = true;
    _markTranscriptComplete(visibleCount: 0);
  }

  /// The pinned stored session was verifiably deleted (its row and its
  /// transcript both 404). Like Hermes Desktop's gone-session fallback, the
  /// chat becomes a fresh draft: the next submit creates a new session
  /// instead of resuming a dead id.
  void markStoredSessionGone() {
    if (_desktopRuntimeSessionId != null || _messages.isNotEmpty) return;
    _desktopStoredSessionId = null;
    _desktopStoredSessionKnownMissing = true;
    messagesLoaded = true;
    _markTranscriptComplete(visibleCount: 0);
  }

  @visibleForTesting
  bool get storedSessionKnownMissing => _desktopStoredSessionKnownMissing;

  /// Stream de cambios. La pantalla se suscribe para re-renderizar; al cerrarse
  /// cancela la suscripción SIN cancelar el stream del agente.
  Stream<ActiveChatEvent> get changes => _changes.stream;

  @visibleForTesting
  void debugEmitMessagesHydrated() => _emit(ActiveChatEvent.messagesHydrated);

  /// Tiempo de respuesta observado por Android para el último turno. Incluye
  /// red, cola y herramientas previas al primer contenido; no es una métrica
  /// publicada por el modelo ni por Hermes.
  int? get observedFirstTokenLatencyMs => _observedFirstTokenLatencyMs;

  void _beginObservedResponseTiming() {
    _responseStartedAtMicros = _monotonicMicros();
    _observedFirstTokenLatencyMs = null;
    _onObservedFirstTokenLatency?.call(null);
  }

  void _observeFirstResponseContent(String? content) {
    if (_observedFirstTokenLatencyMs != null ||
        content == null ||
        content.trim().isEmpty) {
      return;
    }
    final startedAt = _responseStartedAtMicros;
    if (startedAt == null) return;
    final elapsedMicros = math.max(0, _monotonicMicros() - startedAt);
    final latencyMs = elapsedMicros ~/ Duration.microsecondsPerMillisecond;
    _observedFirstTokenLatencyMs = latencyMs;
    _onObservedFirstTokenLatency?.call(latencyMs);
    // TTFT is independent from transcript rendering. Some Hermes transports
    // expose the first visible content through an interim or terminal frame,
    // so waiting for a later token/done event can leave the context panel on
    // its previous null snapshot even though the metric is already persisted.
    _emit(ActiveChatEvent.responseMetrics);
  }

  bool get hasListeners => _changes.hasListener;

  void requestReleaseWhenUnused() {
    _releaseRequested = true;
    if (!_changes.hasListener && !isStreaming) {
      _parkDetachedIdleLifecycle();
    }
  }

  void _markAttached() {
    _releaseRequested = false;
    if (_detachedIdleParked.isCompleted) {
      _detachedIdleParked = Completer<void>();
    }
  }

  bool get releaseRequested => _releaseRequested;

  void _handleLastListenerCancelled() {
    if (_disposed || !_releaseRequested) return;
    scheduleMicrotask(() {
      if (_disposed || _changes.hasListener || !_releaseRequested) return;
      if (!isStreaming) _parkDetachedIdleLifecycle();
      _onUnused?.call();
    });
  }

  bool get _isDetachedIdle =>
      _releaseRequested && !_changes.hasListener && !isStreaming;

  /// A Console-owned idle chat remains in the service so its in-process
  /// ownership receipt can still authorize an explicit release after reopen.
  /// Once its last viewer detaches, however, UI settling and best-effort
  /// transcript retries must not keep timers alive. A turn that was still
  /// streaming at detach reaches its normal terminal commit first and parks at
  /// that boundary; disposal and the durable server transcript remain
  /// independent.
  void _parkDetachedIdleLifecycle({bool terminalJustCompleted = false}) {
    if (_disposed || !_isDetachedIdle) return;
    if (!_detachedIdleParked.isCompleted) _detachedIdleParked.complete();
    final terminalWasPending = _terminalTimer != null;
    _terminalTimer?.cancel();
    _terminalTimer = null;
    if (state == ChatPipelineState.completed) {
      state = ChatPipelineState.idle;
    }
    if (terminalWasPending || terminalJustCompleted) _onTerminal();
  }

  /// Mantiene el mismo runtime vivo entre el corte inmediato por VAD y el
  /// prompt que llega después de transcribir. Sin esta retención, una voz en
  /// segundo plano podía dejar el chat momentáneamente sin oyentes y el
  /// servicio cerraba el socket antes del `prompt.submit(interrupted: true)`.
  bool get voiceBargeHandoffPending => _voiceBargeHandoffPending;

  /// El runtime conserva todavía la valla que separa el terminal del turno
  /// interrumpido de los eventos del reemplazo. Es diagnóstico de protocolo;
  /// la retención del chat se gobierna por [voiceBargeHandoffPending].
  bool get hasPendingDesktopInterruptHandoff =>
      _voiceBargeHandoffPending ||
      _desktopInterruptDrain != null ||
      _discardLateInterruptTerminal;

  List<SteerProjection> get steerProjections =>
      List<SteerProjection>.unmodifiable(_steerRecords);

  /// ID persistido que devuelve session.resume. En chats recién creados puede
  /// diferir del ID móvil con el que se abrió la primera pantalla.
  String? get storedSessionId => _desktopStoredSessionId;

  // Local recovery may follow only the create response for this exact chat,
  // never constructor metadata, logicalId, passive snapshots or a voice tip.
  String? _createdDraftSessionId;
  String? get createdDraftSessionId => _createdDraftSessionId;

  /// Mission Rooms require Hermes' canonical create/resume lifecycle so their
  /// manager pin can be replaced with a server-confirmed stored id. Endpoint
  /// location is not evidence: a modern Gateway reached through localhost or
  /// adb reverse is valid, while a stateless Bridge/REST transport is not.
  bool get canBindDurableMissionSession =>
      _desktopGateway is HermesDesktopSessionLifecycleGateway;

  /// Identidad real que debe usarse contra el historial del servidor.
  ///
  /// `session.resume` puede convertir el id provisional `mob-…` en un id
  /// persistido distinto. Desde ese momento el persistido gana para lecturas,
  /// reanudaciones y borrado; seguir consultando [sessionId] produciría un 404
  /// transitorio y haría que el chat pareciese desaparecer.
  String get serverSessionId =>
      _desktopStoredSessionId ?? _serverSessionOverride ?? sessionId;

  /// Reads the same persisted session snapshot used by Session Details.
  ///
  /// This is intentionally on-demand (screen attach / terminal event / context
  /// panel), never polling. It lets the chat chrome consume usage fields that
  /// Hermes publishes through REST but older `session.info` events omit.
  Future<Session?> loadPersistedSessionSnapshot() async {
    final requestedId = serverSessionId;
    final snapshot = await _api.getSession(
      requestedId,
      profile: sessionProfile,
    );
    if (_disposed || serverSessionId != requestedId) return null;
    return snapshot;
  }

  ArtifactAuthorizationPolicy _artifactPolicy() {
    final host = Uri.tryParse(connection.baseUrl)?.host.trim().toLowerCase();
    return ArtifactAuthorizationPolicy(
      revision: 1,
      allowedManagedUriSchemes: host == null || host.isEmpty
          ? const ['hermes']
          : const ['hermes', 'http', 'https'],
      allowedManagedHosts: host == null || host.isEmpty ? const [] : [host],
    );
  }

  void _captureArtifactMessages(
    Iterable<DesktopSessionMessage> transcript, {
    required String logicalSessionId,
  }) {
    late final ArtifactIndexScope scope;
    try {
      scope = ArtifactIndexScope(
        connectionId: connection.id,
        profileOwner: Session.profileOwner(sessionProfile),
        logicalSessionId: logicalSessionId,
      );
    } on FormatException {
      _artifactScope = null;
      _pendingArtifactTranscript = const [];
      _artifactIndex = null;
      return;
    }

    final candidates = <ArtifactTranscriptEntry>[];
    var fallbackOrdinal = 0;
    for (final message in transcript) {
      if (_messageMayContainArtifact(message)) {
        candidates.add(
          ArtifactTranscriptEntry(
            message: message,
            messageOrdinal: message.serverOrdinal ?? fallbackOrdinal,
            messageRevision: 0,
            stableMessageId: message.stableId,
          ),
        );
      }
      fallbackOrdinal++;
    }

    final sameScope = _artifactScope == scope;
    if (sameScope &&
        candidates.length == _pendingArtifactTranscript.length &&
        _sameArtifactTranscript(candidates, _pendingArtifactTranscript)) {
      return;
    }

    final revision = ++_artifactTranscriptRevision;
    final previousByIdentity = <String, ArtifactTranscriptEntry>{};
    if (sameScope) {
      for (final entry in _pendingArtifactTranscript) {
        previousByIdentity[_artifactEntryIdentity(
              entry.stableMessageId,
              entry.messageOrdinal,
            )] =
            entry;
      }
    }
    final structured = <ArtifactTranscriptEntry>[];
    for (final candidate in candidates) {
      final previous =
          previousByIdentity[_artifactEntryIdentity(
            candidate.stableMessageId,
            candidate.messageOrdinal,
          )];
      final unchanged =
          previous != null &&
          _sameArtifactMessage(previous.message, candidate.message);
      structured.add(
        candidate.withMessageRevision(
          unchanged ? previous.messageRevision : revision,
        ),
      );
    }
    _artifactScope = scope;
    _pendingArtifactTranscript = List.unmodifiable(structured);
  }

  void _captureArtifactMaps(
    Iterable<Map<String, dynamic>> transcript, {
    required String logicalSessionId,
  }) {
    final parsed = <DesktopSessionMessage>[];
    var ordinal = 0;
    for (final message in transcript) {
      if (!_rawMessageMayContainArtifact(message)) {
        ordinal++;
        continue;
      }
      final value = DesktopSessionMessage.tryParse(
        message,
        serverOrdinal: ordinal,
      );
      if (value != null) parsed.add(value);
      ordinal++;
    }
    _captureArtifactMessages(parsed, logicalSessionId: logicalSessionId);
  }

  void clearCancelledTurnTombstones() {
    if (_cancelledTurnTombstones.isNotEmpty) {
      _cancelledTombstoneRevision += 1;
    }
    _cancelledTurnTombstones.clear();
    _pendingCancelledTombstoneUpdates.clear();
    for (var index = 0; index < _messages.length; index++) {
      if (_messages[index]['_cancelledUser'] != true) continue;
      final cleaned = Map<String, dynamic>.of(_messages[index])
        ..remove('_cancelledUser')
        ..remove('_cancelledTurnAnchorMessageId')
        ..remove('_cancelledTurnAnchorRowId')
        ..remove('_cancelledTurnFirstUser')
        ..remove('_cancelledTurnMessageId')
        ..remove('_cancelledTurnRowId');
      _messages[index] = cleaned;
    }
  }

  bool get hasPendingDurableCancellation =>
      _cancelledTurnPersistencePending ||
      _cancelledTurnPersistenceFailed ||
      _pendingCancelledTombstoneUpdates.isNotEmpty ||
      _cancelledTombstoneUpdateFlight != null ||
      _durableCancelFlight != null;

  bool get _hasPendingActiveTurnCancellation =>
      _cancelledTurnPersistencePending || _durableCancelFlight != null;

  bool get _hasPendingTombstoneMetadataUpdate =>
      _pendingCancelledTombstoneUpdates.isNotEmpty;

  /// ¿Hay una petición/ejecución viva en el gateway?
  bool get isStreaming =>
      state == ChatPipelineState.connecting ||
      state == ChatPipelineState.waiting ||
      state == ChatPipelineState.executing ||
      state == ChatPipelineState.streaming;

  /// Estado "enviando" derivado (para deshabilitar el composer, mostrar spinner).
  bool get sending =>
      state != ChatPipelineState.idle &&
      state != ChatPipelineState.completed &&
      state != ChatPipelineState.failed &&
      state != ChatPipelineState.cancelled;

  bool get awaitingDurableTurnRecovery =>
      state == ChatPipelineState.failed &&
      _messages.isNotEmpty &&
      _messages.first['role'] == 'assistant_error' &&
      _messages.first[_awaitingDurableTurnRecoveryKey] == true;

  /// Texto del último mensaje del asistente (index 0 si es assistant).
  String get assistantContent =>
      (_messages.isNotEmpty && _messages.first['role'] == 'assistant')
      ? ((_messages.first['content'] as String?) ?? '')
      : '';

  /// Removes the newest local failed-turn projection without exposing its
  /// private pairing token through [messages].
  bool removeLatestFailedPromptProjection(
    String prompt, {
    bool allowLegacyContentPair = false,
  }) {
    if (_messages.isEmpty) return false;
    final error = _messages.first;
    if (error['role'] != 'assistant_error' ||
        (error['_prompt'] ?? '').toString() != prompt) {
      return false;
    }
    final projectionId = error['_localTranscriptProjectionId'];
    _messages.removeAt(0);
    if (_messages.isEmpty || _messages.first['role'] != 'user') return true;
    final user = _messages.first;
    final paired =
        projectionId is String &&
        projectionId.isNotEmpty &&
        user['_localTranscriptPairId'] == projectionId;
    final legacyPair =
        allowLegacyContentPair &&
        projectionId == null &&
        (user['content'] ?? '').toString() == prompt;
    if (paired || legacyPair) _messages.removeAt(0);
    return true;
  }

  /// Texto assistant natural aceptado para Voz durante el turno actual.
  ///
  /// A diferencia de [assistantContent], conserva intermedios ya sellados y no
  /// deriva nada de trace/tools/logs. No modifica el transcript ni su render.
  String get assistantNarrationContent => _assistantNarration.content;

  /// Último comentario assistant público del turno vivo (`message.interim`).
  ///
  /// Desktop lo mantiene visible como una burbuja antes/alrededor de las
  /// herramientas. Voz Android puede proyectarlo en su única línea sin buscar
  /// texto en reasoning, tools, previews o turnos históricos.
  String get assistantPublicCommentary {
    final currentTurnPrefix = 'assistant-interim-$_turnEpoch-';
    for (final message in _messages) {
      final key = message['_desktopInterimKey'];
      if (message['role'] != 'assistant' ||
          message['_desktopInterim'] != true ||
          key is! String ||
          !key.startsWith(currentTurnPrefix)) {
        continue;
      }
      // `messages` is newest-first. The latest interim owns the projection:
      // an explicitly classified payload must clear an older public line
      // instead of letting Voz repeat stale commentary.
      if (message['_desktopInterimPublic'] != true) return '';
      final content = message['content'];
      if (content is String && content.trim().isNotEmpty) {
        return content.trim();
      }
    }
    return '';
  }

  /// Latest live tool name for the compact Voice projection.
  ///
  /// This multiset is separate from [trace], so Voice can close concurrent or
  /// progress-only tool lifecycles without changing chat cards or their order.
  String? get activeVoiceToolLabel =>
      traceActive && _activeVoiceTools.isNotEmpty
      ? _activeVoiceTools.last.label
      : null;

  ChatActivityKind? get activityKind {
    if (pendingApproval != null) {
      return _lastLiveActivityKind = ChatActivityKind.awaitingApproval;
    }
    if (!isStreaming) return null;
    return switch (state) {
      ChatPipelineState.executing =>
        _lastLiveActivityKind = ChatActivityKind.usingTools,
      ChatPipelineState.streaming =>
        _lastLiveActivityKind = ChatActivityKind.responding,
      ChatPipelineState.connecting || ChatPipelineState.waiting =>
        _lastLiveActivityKind ?? ChatActivityKind.thinking,
      _ => null,
    };
  }

  void _emit(ActiveChatEvent e) {
    if (const {
      ActiveChatEvent.started,
      ActiveChatEvent.messagesHydrated,
      ActiveChatEvent.earlierMessagesLoaded,
      ActiveChatEvent.token,
      ActiveChatEvent.toolProgress,
      ActiveChatEvent.done,
      ActiveChatEvent.error,
      ActiveChatEvent.cancelled,
    }.contains(e)) {
      _transcriptRevision += 1;
    }
    switch (e) {
      case ActiveChatEvent.started:
        _lastLiveActivityKind = ChatActivityKind.thinking;
        break;
      case ActiveChatEvent.approvalRequest:
        _lastLiveActivityKind = ChatActivityKind.awaitingApproval;
        break;
      case ActiveChatEvent.toolProgress:
        _lastLiveActivityKind = ChatActivityKind.usingTools;
        break;
      case ActiveChatEvent.token:
        _lastLiveActivityKind = ChatActivityKind.responding;
        break;
      case ActiveChatEvent.done:
      case ActiveChatEvent.error:
      case ActiveChatEvent.cancelled:
        _lastLiveActivityKind = null;
        break;
      default:
        break;
    }
    _onEvent?.call(e);
    if (!_changes.isClosed) _changes.add(e);
  }

  bool _desktopRuntimeNeedsAdoption(String runtimeId, String storedId) {
    final scope = _sessionConfigScope;
    final profile = _storedSessionProfile.isEmpty
        ? 'default'
        : _storedSessionProfile;
    return _desktopRuntimeSessionId != runtimeId ||
        scope == null ||
        scope.storedSessionId != storedId ||
        scope.profileName != profile;
  }

  void _adoptDesktopRuntime(
    String runtimeSessionId, {
    DesktopSessionRuntimeInfo? info,
  }) {
    final runtimeId = runtimeSessionId;
    if (runtimeId.isEmpty || runtimeId != runtimeId.trim()) {
      throw const TuiGatewayRpcError(
        'session',
        'Hermes returned an empty runtime session identity',
      );
    }
    final profile = _storedSessionProfile.isEmpty
        ? 'default'
        : _storedSessionProfile;
    final didAdopt = _desktopRuntimeNeedsAdoption(runtimeId, serverSessionId);
    if (didAdopt) {
      _retireDesktopRuntime();
      _desktopRuntimeSessionId = runtimeId;
      _retiringDesktopRuntimeSessionId = null;
      if (!_viewerTurnConvergenceIsCurrent) {
        _viewerTurnConvergenceEpoch = null;
      }
      _rosterRuntimeAbsenceStreak = 0;
      _coreReadIdentity = _coreReadIdentity.withRuntime(runtimeId);
      _desktopSessionEpoch += 1;
      _sessionInfoEpoch = 0;
      _sessionConfigScope = SessionConfigScope(
        connectionId: connection.id,
        storedSessionId: serverSessionId,
        runtimeSessionId: runtimeId,
        profileName: profile,
        sessionEpoch: _desktopSessionEpoch,
      );
      _rebaseSubagentActivityScope(runtimeId);
    }
    if (info != null) {
      _observeSessionConfigInfo(info);
      _adoptDesktopSessionTitle(info);
    }
    if (didAdopt) {
      unawaited(_hydrateSubagentsForCurrentRuntime());
      unawaited(_hydrateSessionControl(runtimeId));
    }
  }

  @visibleForTesting
  void adoptDesktopRuntimeForTesting(String runtimeSessionId) {
    _adoptDesktopRuntime(runtimeSessionId);
  }

  @visibleForTesting
  void markCurrentTurnClientSubmittedForTesting() {
    if (!isStreaming || _runTerminal) {
      throw StateError('A live turn is required before marking its owner');
    }
    _turnSubmittedAtMs = _wallClockMs();
  }

  @visibleForTesting
  void markDesktopRuntimeConsoleOwnedForTesting() {
    final gateway = _desktopGateway;
    final runtimeId = _desktopRuntimeSessionId;
    final durableId = _desktopStoredSessionId;
    if (gateway == null || runtimeId == null || durableId == null) {
      throw StateError('A runtime must be bound before marking ownership');
    }
    _desktopRuntimeBindingOrigin = _DesktopRuntimeBindingOrigin.consoleOwned;
    _desktopRuntimeOwnershipReceipt = _DesktopRuntimeOwnershipReceipt(
      gateway: gateway,
      connectionId: connection.id,
      profile: _storedSessionProfile,
      durableSessionId: durableId,
      runtimeSessionId: runtimeId,
      bindEpoch: _desktopBindEpoch,
      sessionEpoch: _desktopSessionEpoch,
    );
  }

  bool _adoptDesktopSessionTitle(DesktopSessionRuntimeInfo info) {
    final title = info.title?.trim() ?? '';
    if (title.isEmpty || title == sessionTitle) return false;
    sessionTitle = title;
    return true;
  }

  void _retireDesktopRuntime() {
    // A process/runtime lifecycle transition cannot safely retain an in-memory
    // pending RPC guard. The next explicitly opened runtime must reconcile
    // authority; it must never inherit a stuck or presumed-success request.
    _abandonPendingDesktopCompression();
    _desktopBindEpoch += 1;
    _goal = null;
    _loop = null;
    _heartbeat = null;
    _sessionTasks = const [];
    _agentTasks = AgentTaskList.empty;
    _sessionTaskRevision = -1;
    _sessionControlStale = false;
    _sessionControlAbsenceStreak = 0;
    _sessionControlRefreshFlight = null;
    _sessionControlRefreshQueued = false;
    _lastNotifiedGoalStatus = null;
    final retiredRuntimeId = _desktopRuntimeSessionId;
    if (retiredRuntimeId != null) {
      // The reducer emits callbacks synchronously. Fence and detach first so a
      // callback cannot register or submit new work for the retiring runtime.
      _retiringDesktopRuntimeSessionId = retiredRuntimeId;
      _desktopRuntimeSessionId = null;
      _expireInteractivePromptsForRuntime(retiredRuntimeId);
    }
    final scope = _sessionConfigScope;
    if (scope != null) {
      _sessionConfigState = SessionConfigReducer.reduce(
        _sessionConfigState,
        SessionConfigScopeSuperseded(scope),
      );
    }
    _sessionConfigScope = null;
    _desktopRuntimeSessionId = null;
    _desktopRuntimeBindingOrigin = _DesktopRuntimeBindingOrigin.none;
    _desktopRuntimeOwnershipReceipt = null;
    _coreReadIdentity = _coreReadIdentity.withoutRuntime();
    _desktopAutoCompacting = false;
    _autoCompactionStaleTimer?.cancel();
    _autoCompactionStaleTimer = null;
    _suppressTerminalHydrationAfterCompaction = false;
    // The indicator belongs to the retired runtime, but the lineage is durable
    // session authority and must survive Stop/runtime retirement.
    _desktopSessionEpoch += 1;
    _sessionInfoEpoch = 0;
    _pendingSubagentInterrupts.clear();
    _subagentControlAuthority.clear();
    _subagentPublicEligibleKeys.clear();
    _backgroundProcessListRequestGeneration += 1;
    _backgroundProcessMutationGeneration += 1;
    _backgroundProcesses = const [];
    _backgroundProcessAbsenceStreaks.clear();
    _backgroundProcessesStale = false;
    _backgroundProcessLiveRosterConfirmed = false;
    _backgroundProcessesObservedAt = null;
    if (_subagentForegroundPresentationLeased) {
      _subagentForegroundPresentationGeneration += 1;
      _subagentPresentationState =
          _SubagentPresentationState.foregroundPendingProof;
      _subagentPublicActivities = const [];
    }
  }

  bool _observeSessionConfigInfo(DesktopSessionRuntimeInfo info) {
    final scope = _sessionConfigScope;
    if (scope == null) return false;
    final before = _sessionConfigState[scope];
    _sessionConfigState = SessionConfigReducer.reduce(
      _sessionConfigState,
      SessionConfigInfoObserved(
        scope: scope,
        infoEpoch: ++_sessionInfoEpoch,
        observedRequestEpoch: _sessionConfigRequestEpoch,
        info: SessionConfigAuthoritativeInfo.fromRuntimeInfo(info),
      ),
    );
    final after = _sessionConfigState[scope];
    if (before?.effective != after?.effective) return true;
    for (final key in DesktopSessionConfigKey.values) {
      if (!identical(before?[key], after?[key])) return true;
    }
    return false;
  }

  List<Map<String, dynamic>> _applyCancelledTurnTombstones(
    List<Map<String, dynamic>> incoming, {
    required bool incomingTranscriptComplete,
  }) {
    _bindTombstonesToDurableIds(
      incoming,
      incomingTranscriptComplete: incomingTranscriptComplete,
    );
    if (_pendingCancelledTombstoneUpdates.isNotEmpty) {
      unawaited(_flushPendingCancelledTombstoneUpdates().catchError((_) {}));
    }
    final withoutSupersededLocalUsers = incoming
        .asMap()
        .entries
        .where((entry) {
          final message = entry.value;
          if (message['_cancelledUser'] != true ||
              canonicalTranscriptMessageId(message) != null ||
              canonicalTranscriptRowId(message) != null) {
            return true;
          }
          final tombstone = _durableTombstoneForLocalCancelledUser(
            incoming,
            entry.key,
          );
          if (tombstone == null) return true;
          final durableIndex = _cancelledTurnUserIndex(
            incoming,
            tombstone,
            incomingTranscriptComplete: incomingTranscriptComplete,
          );
          return durableIndex < 0 ||
              (canonicalTranscriptMessageId(incoming[durableIndex]) == null &&
                  canonicalTranscriptRowId(incoming[durableIndex]) == null);
        })
        .map((entry) => entry.value)
        .toList(growable: true);
    return projectCancelledTurnTombstones(
      existingNewestFirst: _messages,
      incomingNewestFirst: withoutSupersededLocalUsers,
      durableTombstones: _cancelledTurnTombstones,
      incomingTranscriptComplete: incomingTranscriptComplete,
    );
  }

  List<Map<String, dynamic>> _applyCancelledTurnTombstonesForDisplay(
    List<Map<String, dynamic>> incoming, {
    required bool incomingTranscriptComplete,
  }) => _projectTranscriptForInternalState(
    _applyDurablePrivateTranscriptVetoes(
      _applyCancelledTurnTombstones(
        incoming,
        incomingTranscriptComplete: incomingTranscriptComplete,
      ),
    ),
  );

  void _persistUpdatedTombstone(CancelledTurnTombstone tombstone) {
    final persist = _onCancelledTurn;
    if (persist == null) return;
    final key = jsonEncode([
      tombstone.content,
      tombstone.anchorMessageId,
      tombstone.anchorRowId,
      tombstone.firstUser,
      if (!tombstone.hasAnchorIdentity && !tombstone.firstUser) ...[
        tombstone.cancelledMessageId,
        tombstone.cancelledRowId,
      ],
    ]);
    _pendingCancelledTombstoneUpdates[key] = tombstone;
    unawaited(_flushPendingCancelledTombstoneUpdates().catchError((_) {}));
  }

  Future<void> _flushPendingCancelledTombstoneUpdates() {
    final persist = _onCancelledTurn;
    if (persist == null || _pendingCancelledTombstoneUpdates.isEmpty) {
      return Future<void>.value();
    }
    final existing = _cancelledTombstoneUpdateFlight;
    if (existing != null) return existing;

    late final Future<void> operation;
    operation = () async {
      while (_pendingCancelledTombstoneUpdates.isNotEmpty) {
        final entry = _pendingCancelledTombstoneUpdates.entries.first;
        final expected = entry.value;
        await persist(expected);
        if (identical(_pendingCancelledTombstoneUpdates[entry.key], expected)) {
          _pendingCancelledTombstoneUpdates.remove(entry.key);
        }
      }
    }();
    _cancelledTombstoneUpdateFlight = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_cancelledTombstoneUpdateFlight, operation)) {
            _cancelledTombstoneUpdateFlight = null;
          }
        },
        onError: (Object _, StackTrace _) {
          // Keep the exact update queued. The next hydration, compression or
          // send retries it instead of silently reverting to an ambiguous
          // content/position tombstone after process recreation.
          if (identical(_cancelledTombstoneUpdateFlight, operation)) {
            _cancelledTombstoneUpdateFlight = null;
          }
        },
      ),
    );
    return operation;
  }

  Future<bool> _settleTombstoneMetadataBeforeTerminal(
    int expectedTurnEpoch,
  ) async {
    if (!_hasPendingTombstoneMetadataUpdate) return true;
    try {
      await _flushPendingCancelledTombstoneUpdates();
    } catch (_) {
      // La identidad anterior sigue en cola durable. No publiques un terminal
      // que permita liberar el chat mientras esa migración continúa ambigua.
      return false;
    }
    return !_disposed && expectedTurnEpoch == _turnEpoch && !_runTerminal;
  }

  void _bindTombstonesToDurableIds(
    List<Map<String, dynamic>> incoming, {
    required bool incomingTranscriptComplete,
    void Function(int nextRevision)? beforeOwnRevision,
    VoidCallback? afterOwnRevision,
  }) {
    for (var index = 0; index < _cancelledTurnTombstones.length; index++) {
      final tombstone = _cancelledTurnTombstones[index];
      if (tombstone.invalidated) continue;
      final userIndex = _cancelledTurnUserIndex(
        incoming,
        tombstone,
        incomingTranscriptComplete: incomingTranscriptComplete,
      );
      if (userIndex < 0) continue;
      final messageId = canonicalTranscriptMessageId(incoming[userIndex]);
      final rowId = canonicalTranscriptRowId(incoming[userIndex]);
      if (messageId == null && rowId == null) continue;
      final bound = tombstone.bindToMessage(messageId: messageId, rowId: rowId);
      if (bound.cancelledMessageId == tombstone.cancelledMessageId &&
          bound.cancelledRowId == tombstone.cancelledRowId) {
        continue;
      }
      beforeOwnRevision?.call(_cancelledTombstoneRevision + 1);
      _cancelledTurnTombstones[index] = bound;
      _cancelledTombstoneRevision += 1;
      afterOwnRevision?.call();
      _persistUpdatedTombstone(bound);
    }
  }

  Future<void> _loadMessagesWhileCompressionFenced(
    int loadEpoch, {
    int? expectedMessageCount,
    VoidCallback? onMessagesPublished,
    bool forceStoredDisplay = false,
    required bool Function() stillAuthorized,
  }) async {
    try {
      if (!stillAuthorized()) return;
      final context = _captureSessionMessagesPageRead(
        consumer: _SessionMessagesPageConsumer.compressionFenced,
        loadEpoch: loadEpoch,
        profile: _storedSessionProfile,
        hardExpectedMessageCount: expectedMessageCount,
      );
      final page = await _fetchStoredMessagesPage(
        context,
        allowNativeHistory: !forceStoredDisplay,
      );
      if (!stillAuthorized()) return;
      var projected = const <Map<String, dynamic>>[];
      _RefreshedTranscriptGraft? graft;
      final transition = _consumeSessionMessagesPageEvidence(
        page,
        context,
        projector: (pageProvesComplete) {
          final normalized = _normalizedNewestFirst(page.messages);
          projected = _applyCancelledTurnTombstones(
            _associateGeneratedImagesNewestFirst(normalized),
            incomingTranscriptComplete: pageProvesComplete,
          );
          final candidate = _graftRefreshedTail(
            projected,
            _messages,
            refreshedTranscriptComplete: pageProvesComplete,
          );
          graft = candidate;
          return _SessionMessagesPageProjection.fromGraft(projected, candidate);
        },
      );
      if (!stillAuthorized() ||
          transition.action == _SessionMessagesPageAction.stale) {
        return;
      }
      if (transition.action == _SessionMessagesPageAction.throwExpectedCount) {
        throw StateError(
          'Hermes returned an empty transcript for a non-empty session',
        );
      }
      if (transition.action == _SessionMessagesPageAction.retryTail) return;
      final acceptedGraft = graft;
      if (transition.publishesProjection && acceptedGraft != null) {
        if (!stillAuthorized()) return;
        _captureArtifactMaps(page.messages, logicalSessionId: logicalSessionId);
        _messages = _projectTranscriptForInternalState(
          _preserveLocalAssistantErrors(acceptedGraft.messages, _messages),
        );
        _mergeSteerRecords();
        _reconcileSubagentsFromTranscript();
      }
      if (!stillAuthorized()) return;
      messagesLoaded = true;
      if (transition.publishesProjection || transition.preservesAsSuccess) {
        // Like the unfenced load: a caller-owned read is announced only to its
        // caller. Echoing `messagesHydrated` too reached the chat screen after
        // its refresh had ended and read as an external change, re-arming an
        // immediate passive read forever while the fence was up.
        if (onMessagesPublished != null) {
          onMessagesPublished();
        } else {
          _emit(ActiveChatEvent.messagesHydrated);
        }
      }
    } on StateError {
      rethrow;
    } catch (_) {
      if (stillAuthorized()) messagesLoaded = true;
    }
  }

  /// Carga el historial (lectura). No toca el stream.
  ///
  /// Instancia LOCAL (bridge): el agente oneshot no conserva el historial
  /// server-side, así que `getMessages` daría vacío. Reconstruimos el chat
  /// desde el transcript persistido localmente ([LocalTranscriptStore]).
  void invalidatePassiveRead() {
    _messageLoadEpoch += 1;
  }

  Future<void> loadMessages({
    int? expectedMessageCount,
    String profile = '',
    VoidCallback? onMessagesPublished,
    bool passiveOnly = false,
    bool Function()? stillOwningVisible,
  }) async {
    final loadEpoch = ++_messageLoadEpoch;
    final coldOpen = !messagesLoaded;
    if (expectedMessageCount != null && expectedMessageCount > 0) {
      _hardExpectedStoredMessageCount = expectedMessageCount;
    }
    bool viewerAuthorized() =>
        passiveOnly || (stillOwningVisible?.call() ?? true);
    bool loadStillAuthorized() =>
        !_disposed && loadEpoch == _messageLoadEpoch && viewerAuthorized();
    _ensureLocalAssistantErrorIdentities();
    final previousMessagesNewestFirst = List<Map<String, dynamic>>.unmodifiable(
      _messages.map(
        (message) => Map<String, dynamic>.unmodifiable(
          Map<String, dynamic>.from(message),
        ),
      ),
    );
    final bridgeOwnedLiveUser =
        _usingDesktopGateway && isStreaming && !_runTerminal;
    final loadTerminalFences = _terminalReconciliationFences(_messages);
    final loadApprovalGeneration = _approvalGeneration;
    _storedSessionProfile = _bindSessionProfile(profile);
    final requestedStoredSessionId = serverSessionId;
    final requestedLogicalSessionId = logicalSessionId;
    final requestedProfile = _storedSessionProfile;
    final privacyOwner = _storedSessionProfile.isEmpty
        ? 'default'
        : _storedSessionProfile;
    final privacySnapshotFuture = () async {
      try {
        if (!loadStillAuthorized()) return null;
        final beforeLoad = _beforePrivacySnapshotLoad;
        if (beforeLoad != null) {
          await beforeLoad();
          if (!loadStillAuthorized()) return null;
        }
        final snapshot = await LocalTranscriptStore.loadSnapshot(
          connection.id,
          serverSessionId,
          profile: privacyOwner,
        );
        return loadStillAuthorized() ? snapshot : null;
      } catch (error) {
        final unavailableHostStorage =
            error is MissingPluginException ||
            (error is FlutterError &&
                error.toString().contains(
                  'Binding has not yet been initialized',
                ));
        if (!unavailableHostStorage) rethrow;
        return null;
      }
    }();
    var privacyRestored = false;
    void restorePrivacy(TranscriptPrivacyCheckpoint? checkpoint) {
      if (privacyRestored) return;
      privacyRestored = true;
      if (checkpoint == null ||
          checkpoint.connectionId != connection.id ||
          checkpoint.profile != privacyOwner ||
          checkpoint.storedSessionId != serverSessionId) {
        return;
      }
      _transcriptPublication.restore(checkpoint);
      _messages = _applyDurablePrivateTranscriptVetoes(_messages);
    }

    if (!loadStillAuthorized()) return;
    final hasCompressionFence = await _hasUnresolvedDurableCompressionFence();
    if (!loadStillAuthorized()) return;
    if (hasCompressionFence) {
      final privacySnapshot = await privacySnapshotFuture;
      if (!loadStillAuthorized()) return;
      restorePrivacy(privacySnapshot?.privacyCheckpoint);
      await _loadMessagesWhileCompressionFenced(
        loadEpoch,
        expectedMessageCount: expectedMessageCount,
        onMessagesPublished: onMessagesPublished,
        stillAuthorized: loadStillAuthorized,
      );
      return;
    }
    if (!passiveOnly) {
      if (_desktopAutomaticReattach != null) {
        _desktopAutomaticReattachGeneration += 1;
        _desktopAutomaticReattach = null;
      }
      if (_closedViewerRecoveryScope != null) {
        _closedViewerRecoveryScope = null;
        _desktopStoredSessionKnownMissing = false;
      }
    }
    if (_desktopStoredSessionKnownMissing) {
      messagesLoaded = true;
      return;
    }
    final gateway = _desktopGateway;
    final lifecycleGateway = gateway is HermesDesktopSessionLifecycleGateway
        ? gateway as HermesDesktopSessionLifecycleGateway
        : null;
    if (connection.kind == InstanceKind.localhost && lifecycleGateway == null) {
      final savedSnapshot = await privacySnapshotFuture;
      if (!loadStillAuthorized()) return;
      final saved =
          savedSnapshot ??
          const LocalTranscriptSnapshot(
            messages: [],
            olderHistoryTruncated: false,
          );
      restorePrivacy(saved.privacyCheckpoint);
      // Guardado en orden cronológico; index 0 = más nuevo en la lista viva.
      _recordLocalTranscriptCoverage(saved);
      _messages = _applyCancelledTurnTombstonesForDisplay(
        _normalizedNewestFirst(saved.messages),
        incomingTranscriptComplete: !saved.olderHistoryTruncated,
      );
      messagesLoaded = true;
      onMessagesPublished?.call();
      return;
    }

    if (!passiveOnly &&
        viewerAuthorized() &&
        gateway != null &&
        lifecycleGateway != null &&
        (_attachDesktopRuntimeOnLoad ||
            _allowUnownedDesktopSnapshotForTesting)) {
      _listenToDesktopGateway(gateway);
      final dashboardAuthAttempt = ++_dashboardAuthAttemptEpoch;

      // REST-only transports may prefetch concurrently. Native history must
      // wait for the existing resume/activate to resolve its runtime identity.
      ({Object? error, SessionMessagesPage? value})?
      prefetchCompletedBeforeResume;
      final prefetchContext = _captureSessionMessagesPageRead(
        consumer: _SessionMessagesPageConsumer.lifecyclePrefetch,
        loadEpoch: loadEpoch,
        profile: _storedSessionProfile,
        hardExpectedMessageCount: expectedMessageCount,
      );
      late final Future<({Object? error, SessionMessagesPage? value})>
      prefetchFuture;
      final resumeFuture = _captureAsync<DesktopSessionSnapshot?>(() async {
        if (!loadStillAuthorized()) {
          throw StateError('Viewer ownership revoked');
        }
        await gateway.connect();
        if (!loadStillAuthorized()) {
          throw StateError('Viewer ownership revoked');
        }
        String? advertisedRuntimeId;
        if (_attachDesktopRuntimeOnLoad &&
            !_allowUnownedDesktopSnapshotForTesting) {
          final advertisedRuntimes = await _gatewayAdvertisesDurableRuntime(
            gateway,
            requestedStoredSessionId,
            stillAuthorized: loadStillAuthorized,
          );
          if (advertisedRuntimes == null || advertisedRuntimes.length > 1) {
            return null;
          }
          advertisedRuntimeId = advertisedRuntimes.singleOrNull;
        }
        if (!loadStillAuthorized()) {
          throw StateError('Viewer ownership revoked');
        }
        if (gateway is! HermesDesktopSessionHistoryGateway &&
            prefetchCompletedBeforeResume == null) {
          // Damos una vuelta de event loop al REST que ya terminó en memoria o
          // caché. Una lectura de red todavía pendiente no bloquea el binding.
          await Future.any<void>([
            prefetchFuture.then<void>((_) {}),
            Future<void>.delayed(Duration.zero),
          ]);
          if (!loadStillAuthorized()) {
            throw StateError('Viewer ownership revoked');
          }
        }
        // Join the advertised runtime; only dormant durable sessions resume.
        // Native history below reads that resolved runtime after this reply.
        final activityGateway = gateway is HermesDesktopSessionActivityGateway
            ? gateway as HermesDesktopSessionActivityGateway
            : null;
        final snapshot = advertisedRuntimeId != null && activityGateway != null
            ? await activityGateway.activateSession(
                advertisedRuntimeId,
                storedSessionId: requestedStoredSessionId,
              )
            : await lifecycleGateway.resumeExisting(
                requestedStoredSessionId,
                profile: requestedProfile,
                omitMessages: false,
                // Hermes Agent 0.20 puede devolver un ack inmediato y completar
                // la hidratación mediante `session.resume_progress`.
                deferHistory: true,
              );
        if (!loadStillAuthorized()) {
          throw StateError('Viewer ownership revoked');
        }
        if (advertisedRuntimeId != null &&
            snapshot.runtimeSessionId != advertisedRuntimeId) {
          throw StateError(
            'Desktop activation returned a runtime not advertised for this session',
          );
        }
        return snapshot;
      });

      prefetchFuture =
          _captureAsync<SessionMessagesPage>(() async {
            String? runtimeId;
            if (gateway is HermesDesktopSessionHistoryGateway &&
                _storedMessageLoader == null) {
              final resumed = await resumeFuture;
              if (!loadStillAuthorized()) {
                throw StateError('Viewer ownership revoked');
              }
              final snapshot = resumed.value;
              if (snapshot != null &&
                  !snapshot.created &&
                  snapshot.identityAliasesConsistent &&
                  snapshot.storedSessionIdentityExplicit &&
                  snapshot.storedSessionId == requestedStoredSessionId &&
                  (snapshot.lineageRootId == null ||
                      snapshot.lineageRootId == requestedLogicalSessionId ||
                      snapshot.lineageRootId == requestedStoredSessionId) &&
                  _storedSessionProfile == requestedProfile &&
                  serverSessionId == requestedStoredSessionId) {
                runtimeId = snapshot.runtimeSessionId;
              }
            }
            return _fetchStoredMessagesPage(
              prefetchContext,
              runtimeSessionId: runtimeId,
            );
          }).then((result) {
            prefetchCompletedBeforeResume = result;
            return result;
          });

      List<Map<String, dynamic>>? prefetchedNewestFirst;
      var prefetchedTranscriptAccepted = false;
      var prefetchedTranscriptComplete = false;
      int? prefetchedRawMessageCount;
      DesktopSessionSnapshot? resumedSnapshot;
      Object? prefetchError;
      Object? resumeError;
      var snapshotVetoPublishedEmpty = false;

      void publishMessages(
        List<Map<String, dynamic>> next, {
        required bool incomingTranscriptComplete,
      }) {
        if (_disposed ||
            loadEpoch != _messageLoadEpoch ||
            !viewerAuthorized()) {
          return;
        }
        final fencedNext = _carryNewestTerminalFence(
          _messages,
          next,
          candidateTranscriptComplete: incomingTranscriptComplete,
        );
        _messages = _applyCancelledTurnTombstonesForDisplay(
          _associateGeneratedImagesNewestFirst(
            _preserveLocalAssistantErrors(fencedNext, _messages),
          ),
          incomingTranscriptComplete: incomingTranscriptComplete,
        );
        _mergeSteerRecords();
        _reconcileSubagentsFromTranscript();
        messagesLoaded = true;
        onMessagesPublished?.call();
        _emit(ActiveChatEvent.messagesHydrated);
      }

      void publishSnapshot(DesktopSessionSnapshot snapshot) {
        if (_disposed ||
            loadEpoch != _messageLoadEpoch ||
            !viewerAuthorized()) {
          return;
        }
        final snapshotRemovedPublishedPrivateRow =
            _recordDurablePrivateTranscriptVetoes(snapshot.messages);
        // Ack diferido de Hermes Agent 0.20: el historial llega en segundo
        // plano; un ack nuevo reinicia el desenlace registrado.
        _desktopHistoryHydrating = snapshot.hydrating;
        if (snapshot.hydrating) _desktopHydrationOutcome = null;
        _rememberDesktopHydrationExpectation(snapshot);
        final snapshotTranscriptComplete = _desktopSnapshotTranscriptIsComplete(
          snapshot,
        );
        const reconciler = DesktopSessionReconciler();
        final visibleTerminalFences = <_TerminalProjectionFence>[];
        final visibleFenceIds = <String>{};
        for (final fence in <_TerminalProjectionFence>[
          ...loadTerminalFences,
          ..._terminalReconciliationFences(_messages),
        ]) {
          if (visibleFenceIds.add(fence.projectionId)) {
            visibleTerminalFences.add(fence);
          }
        }
        final durableSnapshotProjection = reconciler.project(
          _withoutLiveDesktopProjection(snapshot),
        );
        final snapshotCoversVisibleTerminal = _terminalFencesAreCovered(
          durableSnapshotProjection.messagesNewestFirst,
          visibleTerminalFences,
          candidateTranscriptComplete: snapshotTranscriptComplete,
        );
        final snapshotRejectedByTerminalFence =
            visibleTerminalFences.isNotEmpty && !snapshotCoversVisibleTerminal;
        final liveAuthorityFences = <_TerminalProjectionFence>[
          ...visibleTerminalFences,
        ];
        final liveAuthorityFenceIds = <String>{
          for (final fence in liveAuthorityFences) fence.projectionId,
        };
        for (final fence in _terminalReconciliationFences(
          _messages,
          includeSettledTerminalBoundary: true,
        )) {
          if (liveAuthorityFenceIds.add(fence.projectionId)) {
            liveAuthorityFences.add(fence);
          }
        }
        final snapshotCoversLiveTerminal = _terminalFencesAreCovered(
          durableSnapshotProjection.messagesNewestFirst,
          liveAuthorityFences,
          candidateTranscriptComplete: snapshotTranscriptComplete,
        );
        final liveSnapshotProjection = reconciler.project(
          snapshot,
          previousNewestFirst: previousMessagesNewestFirst,
          bridgeOwnedLiveUser: bridgeOwnedLiveUser,
        );
        final snapshotHasDistinctInflightUser = liveSnapshotProjection
            .messagesNewestFirst
            .any(
              (message) =>
                  isRealUserTurn(message) &&
                  message['_desktopSnapshotKind'] == 'inflight',
            );
        final snapshotHasLiveActivity =
            snapshot.running || snapshot.inflight != null;
        final rejectSnapshotLiveActivity =
            snapshotHasLiveActivity &&
            (snapshotRejectedByTerminalFence ||
                (_runTerminal &&
                    (liveAuthorityFences.isEmpty ||
                        !snapshotCoversLiveTerminal ||
                        !snapshotHasDistinctInflightUser)));
        var rawFallback = prefetchedNewestFirst ?? _messages;
        final snapshotAllowsAuthoritativeEmptyRest =
            snapshot.messages.isEmpty &&
            !snapshot.hydrating &&
            (snapshot.messageCount ?? 0) <= 0;
        final restPrefetchIsAuthoritative =
            prefetchedTranscriptAccepted &&
            prefetchedNewestFirst != null &&
            (prefetchedNewestFirst!.isNotEmpty ||
                snapshotAllowsAuthoritativeEmptyRest);
        // Si REST terminó primero con una cola parcial nueva, injértala sobre
        // el snapshot completo para conservar su prefijo antiguo sin permitir
        // que el snapshot stale tape IDs más recientes.
        if (restPrefetchIsAuthoritative &&
            !prefetchedTranscriptComplete &&
            snapshotTranscriptComplete &&
            snapshot.messagesProvided) {
          final restTail = prefetchedNewestFirst!;
          final snapshotProjection = reconciler.project(
            _withoutLiveDesktopProjection(snapshot),
          );
          final combined = _graftRefreshedTail(
            restTail,
            snapshotProjection.messagesNewestFirst,
            refreshedTranscriptComplete: false,
            requiredTerminalFences: loadTerminalFences,
          );
          if (combined.acceptedRefreshed) {
            rawFallback = _preserveLocalAssistantErrors(
              combined.messages,
              _messages,
            );
            prefetchedNewestFirst = rawFallback;
          }
        }
        final announcedHydrationCount = snapshot.messageCount;
        final completeRestMatchesHydrationCount =
            !snapshot.hydrating ||
            announcedHydrationCount == null ||
            prefetchedRawMessageCount == announcedHydrationCount;
        final completeRestCoversHydration =
            restPrefetchIsAuthoritative &&
            prefetchedTranscriptComplete &&
            completeRestMatchesHydrationCount;
        _desktopHistoryNeedsHydration =
            snapshot.hydrating && !completeRestCoversHydration;
        final fallbackExactlyMatchesSnapshot =
            snapshotTranscriptComplete &&
            _fallbackExactlyMatchesDesktopSnapshot(rawFallback, snapshot);
        final preferFallback =
            snapshotRejectedByTerminalFence ||
            (restPrefetchIsAuthoritative && prefetchedTranscriptComplete) ||
            (rawFallback.isNotEmpty &&
                (restPrefetchIsAuthoritative ||
                    !snapshotTranscriptComplete ||
                    snapshot.messages.isEmpty ||
                    fallbackExactlyMatchesSnapshot));
        final fallback = preferFallback && snapshot.messagesProvided
            ? reconciler.overlayDurableDisplayMetadata(
                rawFallback,
                snapshot.messages,
              )
            : rawFallback;
        final snapshotVetoedFallback = fallback.length < rawFallback.length;
        var projectionSource = preferFallback
            ? _withoutPersistedMessages(snapshot)
            : snapshot;
        if (rejectSnapshotLiveActivity) {
          projectionSource = _withoutLiveDesktopProjection(projectionSource);
        }
        if (snapshot.messagesProvided) {
          _captureArtifactMessages(
            snapshot.messages,
            logicalSessionId: logicalSessionId,
          );
          if (!preferFallback || fallbackExactlyMatchesSnapshot) {
            _recordDesktopSnapshotTranscript(snapshot);
          } else if ((!snapshotTranscriptComplete ||
                  snapshot.messages.isEmpty) &&
              !completeRestCoversHydration) {
            _recordDesktopSnapshotTranscript(
              snapshot,
              preserveVisibleFallback: true,
            );
          }
        } else {
          final announcedCount = snapshot.messageCount;
          final durableFallbackCount = _durableTranscriptCoverageCount(
            rawFallback,
          );
          // An omitted count cannot invalidate complete history fetched in
          // this load. Older fallback rows still need snapshot evidence.
          final fallbackCoverageIsInsufficient = announcedCount == null
              ? !completeRestCoversHydration
              : durableFallbackCount == null ||
                    announcedCount != durableFallbackCount;
          if (!preferFallback ||
              fallbackCoverageIsInsufficient ||
              _desktopHistoryNeedsHydration) {
            _recordDesktopSnapshotTranscript(
              snapshot,
              preserveVisibleFallback: preferFallback,
            );
          }
        }
        final projection = reconciler.project(
          projectionSource,
          fallbackNewestFirst: fallback,
          previousNewestFirst: previousMessagesNewestFirst,
          bridgeOwnedLiveUser: bridgeOwnedLiveUser,
          retainMediaEvidence: true,
        );
        final projected = _sanitizeDesktopFailureProjection(
          projection.messagesNewestFirst.map(Map<String, dynamic>.from),
        );
        if (_runTerminal && (projection.running || projection.failed)) {
          _beginExternallyObservedDesktopTurn(snapshot);
        }
        final expectsTranscript =
            (expectedMessageCount ?? 0) > 0 || (snapshot.messageCount ?? 0) > 0;
        final authoritativeSnapshotMayProjectEmpty =
            snapshotTranscriptComplete && snapshot.messagesProvided;
        if (projected.isNotEmpty ||
            !expectsTranscript ||
            authoritativeSnapshotMayProjectEmpty ||
            snapshotRemovedPublishedPrivateRow ||
            snapshotVetoedFallback) {
          if (projected.isEmpty &&
              (snapshotRemovedPublishedPrivateRow || snapshotVetoedFallback)) {
            snapshotVetoPublishedEmpty = true;
          }
          publishMessages(
            projected,
            incomingTranscriptComplete: preferFallback
                ? _transcriptIsComplete
                : snapshotTranscriptComplete,
          );
        }
        if (!loadStillAuthorized()) return;
        _desktopStoredSessionId = snapshot.storedSessionId;
        if (_coreReadIdentity.storedId != snapshot.storedSessionId) {
          _coreReadIdentity = _coreReadIdentity.withStored(
            snapshot.storedSessionId,
          );
        }
        if (!loadStillAuthorized()) return;
        _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
        _hydrateAgentTasks(snapshot.todoState);
        _reconcileSubagentsFromTranscript();
        _restorePendingClarify(snapshot);
        _restorePendingApproval(
          snapshot,
          expectedGeneration: loadApprovalGeneration,
        );
        _desktopStoredSessionKnownMissing = false;
        _desktopRuntimeInfo = snapshot.info;
        _rememberDesktopLiveStatus(
          projection.status,
          running: projection.running,
          turnStartedAt: snapshot.resolvedTurnStartedAt,
          coldOpen: coldOpen,
        );
        _desktopStartedAt = snapshot.startedAt;
        _desktopTurnStartedAt = projection.running
            ? snapshot.resolvedTurnStartedAt
            : null;
        _replaceDesktopAcceptedQueue(projection.queuedUser);
        if (projection.failed) {
          _turnSubmittedAtMs = null;
          _activityWatchdogTimer?.cancel();
          _activityWatchdogTimer = null;
          _setNoActivityHint(false);
          _usingDesktopGateway = false;
          _runTerminal = true;
          traceActive = false;
          pendingApproval = null;
          _cancelling = false;
          state = ChatPipelineState.failed;
        } else if (projection.running) {
          _usingDesktopGateway = true;
          state = snapshot.inflight?.assistant?.isNotEmpty == true
              ? ChatPipelineState.streaming
              : ChatPipelineState.executing;
        } else if (isStreaming &&
            !_runTerminal &&
            _turnSawRuntimePayload &&
            !rejectSnapshotLiveActivity &&
            snapshotTranscriptComplete) {
          // Un snapshot completo y bien formado que no está ni fallido ni
          // corriendo es el hecho terminal durable: el turno acabó en silencio
          // y un estado local vivo no puede sobrevivirle. Un turno recién
          // enviado que todavía no produjo nada es más nuevo que el snapshot
          // (mismo veto de pre-arranque que la cosecha por roster), así que no
          // lo cierra.
          _turnSubmittedAtMs = null;
          _activityWatchdogTimer?.cancel();
          _activityWatchdogTimer = null;
          _setNoActivityHint(false);
          _desktopTurnStartedAt = null;
          _sealRecoveredLiveActivity(completed: true);
          _runTerminal = true;
          traceActive = false;
          pendingApproval = null;
          _cancelling = false;
          state = ChatPipelineState.completed;
          _emit(ActiveChatEvent.sessionInfo);
        }
      }

      // Ambas ramas publican en cuanto traen un transcript útil. La última en
      // terminar vuelve a proyectar con todos los datos disponibles: REST tiene
      // precedencia para lo persistido y el snapshot conserva inflight/queued.
      final prefetchTask = () async {
        final prefetch = await prefetchFuture;
        if (!loadStillAuthorized()) return;
        final privacySnapshot = await privacySnapshotFuture;
        if (!loadStillAuthorized()) return;
        final privacyCheckpoint = privacySnapshot?.privacyCheckpoint;
        prefetchError = prefetch.error;
        if (prefetch.value case final page?) {
          var normalized = const <Map<String, dynamic>>[];
          _RefreshedTranscriptGraft? graft;
          final transition = _consumeSessionMessagesPageEvidence(
            page,
            prefetchContext,
            prepareProjection: () => restorePrivacy(privacyCheckpoint),
            projector: (pageProvesComplete) {
              normalized = _normalizedNewestFirst(page.messages);
              final candidate = _graftRefreshedTail(
                normalized,
                _messages,
                refreshedTranscriptComplete: pageProvesComplete,
                requiredTerminalFences: loadTerminalFences,
              );
              graft = candidate;
              return _SessionMessagesPageProjection.fromGraft(
                normalized,
                candidate,
              );
            },
          );
          if (transition.action == _SessionMessagesPageAction.stale) return;
          if (transition.action ==
              _SessionMessagesPageAction.throwExpectedCount) {
            // Esta rama forma una lectura compuesta con session.resume. El
            // snapshot concurrente todavía puede acreditar el count duro; si
            // no lo hace, el cierre común de loadMessages lanza el StateError.
            return;
          }
          if (!transition.publishesProjection) return;

          final authoritativeEmptyPage = page.messages.isEmpty;
          final acceptedGraft = graft;
          if (!authoritativeEmptyPage && acceptedGraft == null) return;
          _captureArtifactMaps(
            page.messages,
            logicalSessionId: logicalSessionId,
          );
          prefetchedTranscriptAccepted = true;
          // Es una página REST pura: el count bruto incluye filas id-less sin
          // inventarles identidad y excluye proyecciones live solo de la UI.
          prefetchedRawMessageCount = page.returned;
          prefetchedTranscriptComplete =
              transition.publishesProjection && _transcriptIsComplete;
          prefetchedNewestFirst = authoritativeEmptyPage
              ? _preserveLocalAssistantErrors(
                  acceptedGraft?.messages ?? const <Map<String, dynamic>>[],
                  _messages,
                )
              : _preserveLocalAssistantErrors(
                  acceptedGraft!.messages,
                  _messages,
                );
          final snapshot = resumedSnapshot;
          if (snapshot == null) {
            publishMessages(
              prefetchedNewestFirst!,
              // El lifecycle aún puede responder con un ack hydrating cuyo
              // count demuestre que esta cola corta es provisional. Aplica
              // anchors durables ya, pero difiere firstUser hasta conocerlo.
              incomingTranscriptComplete: false,
            );
          } else {
            publishSnapshot(snapshot);
          }
        } else if (!_disposed && loadEpoch == _messageLoadEpoch) {
          restorePrivacy(privacyCheckpoint);
        }
      }();

      final resumeTask = () async {
        final resumed = await resumeFuture;
        if (!loadStillAuthorized()) return;
        final privacySnapshot = await privacySnapshotFuture;
        if (!loadStillAuthorized()) return;
        restorePrivacy(privacySnapshot?.privacyCheckpoint);
        resumeError = resumed.error;
        if (resumed.value case final snapshot?) {
          final advertisedRoot = snapshot.lineageRootId;
          final snapshotIdentityAccepted =
              !snapshot.created &&
              snapshot.identityAliasesConsistent &&
              snapshot.storedSessionIdentityExplicit &&
              snapshot.storedSessionId == requestedStoredSessionId &&
              (advertisedRoot == null ||
                  advertisedRoot == requestedLogicalSessionId ||
                  advertisedRoot == requestedStoredSessionId) &&
              _storedSessionProfile == requestedProfile &&
              serverSessionId == requestedStoredSessionId;
          if (_attachDesktopRuntimeOnLoad && !snapshotIdentityAccepted) {
            resumeError = StateError(
              'Desktop resume returned an untrusted session identity',
            );
            return;
          }
          _setDashboardAuthRequired(false, attemptEpoch: dashboardAuthAttempt);
          resumedSnapshot = snapshot;
          publishSnapshot(snapshot);
          if (snapshot.storedSessionId == serverSessionId) {
            final owner = _storedSessionProfile.isEmpty
                ? 'default'
                : _storedSessionProfile;
            final coverage = !snapshot.messagesProvided
                ? TranscriptPrivacyCoverage.omitted
                : snapshot.messagesFullyParsed &&
                      snapshot.messageCount == snapshot.messages.length
                ? TranscriptPrivacyCoverage.complete
                : TranscriptPrivacyCoverage.partial;
            try {
              if (!loadStillAuthorized()) return;
              final beforeSave = _beforePrivacyCheckpointSave;
              if (beforeSave != null) {
                await beforeSave();
                if (!loadStillAuthorized()) return;
              }
              await LocalTranscriptStore.savePrivacyCheckpoint(
                connection.id,
                serverSessionId,
                _transcriptPublication.checkpoint(
                  connectionId: connection.id,
                  profile: owner,
                  storedSessionId: serverSessionId,
                  coverage: coverage,
                ),
                profile: owner,
                lifecycle: _localConversationLifecycle,
              );
              if (!loadStillAuthorized()) return;
            } catch (error) {
              final unavailableHostStorage =
                  error is MissingPluginException ||
                  (error is FlutterError &&
                      error.toString().contains(
                        'Binding has not yet been initialized',
                      ));
              if (!unavailableHostStorage) rethrow;
              // See the read path above: no plaintext fallback is permitted.
            }
          }
        } else if (resumed.error case final error?
            when _isDashboardAuthRequired(error)) {
          _setDashboardAuthRequired(true, attemptEpoch: dashboardAuthAttempt);
        }
      }();

      await Future.wait<void>([prefetchTask, resumeTask]);
      if (!loadStillAuthorized()) return;

      final capturedResumeError = resumeError;
      _finalizeColdOpenViewerAttachment(
        gateway,
        capturedResumeError,
        durableHistoryIsEmpty: prefetchedNewestFirst?.isEmpty == true,
        durableHistoryLoaded: prefetchError == null,
      );

      final snapshot = resumedSnapshot;
      if (snapshot != null) {
        final expectsTranscript =
            (expectedMessageCount ?? 0) > 0 || (snapshot.messageCount ?? 0) > 0;
        if (expectsTranscript &&
            _messages.isEmpty &&
            !snapshotVetoPublishedEmpty &&
            !_transcriptPublication.hasSuppressedWindow &&
            !(_desktopSnapshotTranscriptIsComplete(snapshot) &&
                snapshot.messagesProvided)) {
          // Ack diferido sin transcript y REST no pintó nada: el historial se
          // está cargando server-side en segundo plano. Espera el
          // `session.resume_progress` y reintenta la cola paginada ya lista.
          if (snapshot.hydrating) {
            if (!loadStillAuthorized()) return;
            final hydrated =
                await (_historyHydrationAwaiter?.call() ??
                    _awaitDesktopHistoryHydration());
            if (!loadStillAuthorized()) return;
            if (hydrated) {
              final deferredContext = _captureSessionMessagesPageRead(
                consumer: _SessionMessagesPageConsumer.resumeProgressRetry,
                loadEpoch: loadEpoch,
                profile: _storedSessionProfile,
                hardExpectedMessageCount: expectedMessageCount,
                fenceCoverageState: true,
              );
              final deferredPage = await _fetchStoredMessagesPage(
                deferredContext,
              );
              if (!loadStillAuthorized()) return;
              var deferred = const <Map<String, dynamic>>[];
              final transition = _consumeSessionMessagesPageEvidence(
                deferredPage,
                deferredContext,
                projector: (pageProvesComplete) {
                  deferred = _normalizedNewestFirst(deferredPage.messages);
                  return _SessionMessagesPageProjection.publish(
                    refreshedNewestFirst: deferred,
                  );
                },
              );
              if (transition.action == _SessionMessagesPageAction.stale) {
                return;
              }
              if (transition.action ==
                  _SessionMessagesPageAction.throwExpectedCount) {
                messagesLoaded = false;
                throw StateError(
                  'Hermes returned an empty transcript for a non-empty session',
                );
              }
              if (transition.publishesProjection && deferred.isNotEmpty) {
                if (!loadStillAuthorized()) return;
                _captureArtifactMaps(
                  deferredPage.messages,
                  logicalSessionId: logicalSessionId,
                );
                _messages = _applyCancelledTurnTombstonesForDisplay(
                  _associateGeneratedImagesNewestFirst(
                    _preserveLocalAssistantErrors(deferred, _messages),
                  ),
                  incomingTranscriptComplete: _transcriptIsComplete,
                );
                _mergeSteerRecords();
                _reconcileSubagentsFromTranscript();
                messagesLoaded = true;
                onMessagesPublished?.call();
                _emit(ActiveChatEvent.messagesHydrated);
                return;
              }
            }
          }
          messagesLoaded = false;
          throw StateError(
            'Hermes returned an empty transcript for a non-empty session',
          );
        }
        if (!messagesLoaded) {
          messagesLoaded = true;
          onMessagesPublished?.call();
          _emit(ActiveChatEvent.messagesHydrated);
        }
        return;
      }

      if (capturedResumeError is TuiGatewayRpcError) {
        // Un borrador local no existe todavía hasta su primer prompt y los
        // gateways antiguos pueden carecer del lifecycle 0.19. REST conserva
        // compatibilidad; esta ruta de lectura nunca crea una sesión.
        if (capturedResumeError.code != 4007 &&
            capturedResumeError.code != -32601) {
          debugPrint(
            '[active-chat] Desktop resume unavailable '
            '(${capturedResumeError.runtimeType}, '
            'code=${capturedResumeError.code})',
          );
        }
      } else if (capturedResumeError != null) {
        debugPrint(
          '[active-chat] Desktop snapshot unavailable '
          '(${capturedResumeError.runtimeType})',
        );
      }

      // Si REST ya pintó un transcript legible, un fallo del canal vivo no lo
      // vuelve a ocultar. El próximo envío/reintento podrá enlazar el runtime.
      if (prefetchedNewestFirst?.isNotEmpty == true || _messages.isNotEmpty) {
        if (capturedResumeError != null &&
            _desktopRuntimeSessionId == null &&
            isStreaming &&
            !_runTerminal) {
          _viewerTurnConvergenceEpoch = _turnEpoch;
          _rosterRuntimeAbsenceStreak = 0;
        }
        if (prefetchedTranscriptComplete && _transcriptIsComplete) {
          final projected = _applyCancelledTurnTombstones(
            _messages,
            incomingTranscriptComplete: true,
          );
          if (!_sameTranscriptProjection(projected, _messages)) {
            _messages = projected;
            _mergeSteerRecords();
            _reconcileSubagentsFromTranscript();
            onMessagesPublished?.call();
            _emit(ActiveChatEvent.messagesHydrated);
          }
        }
        messagesLoaded = true;
        return;
      }
      if (prefetchError == null) {
        if ((expectedMessageCount ?? 0) > 0) {
          throw StateError(
            'Hermes returned an empty transcript for a non-empty session',
          );
        }
        messagesLoaded = true;
        return;
      }
      throw capturedResumeError ??
          prefetchError ??
          StateError('Chat load failed');
    }

    final context = _captureSessionMessagesPageRead(
      consumer: _SessionMessagesPageConsumer.directLoad,
      loadEpoch: loadEpoch,
      profile: _storedSessionProfile,
      hardExpectedMessageCount: expectedMessageCount,
    );
    final page = await _fetchStoredMessagesPage(context);
    if (!loadStillAuthorized()) return;
    var normalized = const <Map<String, dynamic>>[];
    _RefreshedTranscriptGraft? graft;
    final transition = _consumeSessionMessagesPageEvidence(
      page,
      context,
      projector: (pageProvesComplete) {
        normalized = _normalizedNewestFirst(page.messages);
        final candidate = _graftRefreshedTail(
          normalized,
          _messages,
          refreshedTranscriptComplete: pageProvesComplete,
          requiredTerminalFences: loadTerminalFences,
          preservePartialExactTailCoverage: passiveOnly,
        );
        graft = candidate;
        return _SessionMessagesPageProjection.fromGraft(normalized, candidate);
      },
    );
    if (!loadStillAuthorized() ||
        transition.action == _SessionMessagesPageAction.stale) {
      return;
    }
    _observeDurableTail(page.messages, passiveObservation: passiveOnly);
    if (transition.action == _SessionMessagesPageAction.throwExpectedCount) {
      throw StateError(
        'Hermes returned an empty transcript for a non-empty session',
      );
    }
    if (transition.action == _SessionMessagesPageAction.retryTail) return;
    if (!transition.publishesProjection) {
      if (!loadStillAuthorized()) return;
      messagesLoaded = true;
      return;
    }
    final acceptedGraft = graft;
    if (page.messages.isEmpty || acceptedGraft == null) {
      if (!loadStillAuthorized()) return;
      messagesLoaded = true;
      onMessagesPublished?.call();
      return;
    }
    if (!loadStillAuthorized()) return;
    final verifyPotentialUserGenerationReplacement =
        _hasPotentialUserGenerationReplacement(normalized, acceptedGraft);
    _captureArtifactMaps(page.messages, logicalSessionId: logicalSessionId);
    // API devuelve más antiguo primero; lo invertimos: index 0 = más nuevo.
    _messages = _applyCancelledTurnTombstonesForDisplay(
      _associateGeneratedImagesNewestFirst(
        _preserveLocalAssistantErrors(acceptedGraft.messages, _messages),
      ),
      incomingTranscriptComplete: _transcriptIsComplete,
    );
    _mergeSteerRecords();
    _reconcileSubagentsFromTranscript();
    messagesLoaded = true;
    await _backfillInitialConversationWindow(
      refreshedPageHadVisibleConversation:
          _visibleConversationMessageCountIn(normalized) > 0,
      verifyPotentialUserGenerationReplacement:
          verifyPotentialUserGenerationReplacement,
    );
    if (!loadStillAuthorized()) return;
    onMessagesPublished?.call();
  }

  Future<List<Map<String, dynamic>>> _loadStoredMessages(String profile) async {
    final normalizedProfile = profile.trim();
    final injected = _storedMessageLoader;
    if (injected != null) {
      return injected(serverSessionId, normalizedProfile);
    }
    return _api.getMessages(serverSessionId, profile: normalizedProfile);
  }

  _SessionMessagesPageReadContext _captureSessionMessagesPageRead({
    required _SessionMessagesPageConsumer consumer,
    required int loadEpoch,
    required String profile,
    int? limit,
    int offset = 0,
    int? hardExpectedMessageCount,
    bool fenceCoverageState = false,
  }) => _SessionMessagesPageReadContext(
    consumer: consumer,
    profile: profile.trim(),
    requestedStoredSessionId: serverSessionId,
    loadEpoch: loadEpoch,
    requestedLimit: limit ?? _transcriptPageSize,
    requestedOffset: offset,
    hardExpectedMessageCount: hardExpectedMessageCount,
    announcedMessageCount: _desktopHydrationExpectedMessageCount,
    fenceCoverageState: fenceCoverageState,
    coverageRevision: _transcriptCoverageRevision,
    tailHydration: _needsTranscriptTailHydration,
    nextOffset: _earlierMessagesNextOffset,
    extent: _transcriptExtent,
    earlierMessagesAvailable: _earlierMessagesAvailable,
  );

  bool _sessionMessagesPageReadIsFresh(
    _SessionMessagesPageReadContext context,
  ) =>
      !_disposed &&
      context.loadEpoch == _messageLoadEpoch &&
      context.requestedStoredSessionId == serverSessionId &&
      (!context.fenceCoverageState ||
          (context.coverageRevision == _transcriptCoverageRevision &&
              context.tailHydration == _needsTranscriptTailHydration &&
              context.nextOffset == _earlierMessagesNextOffset &&
              context.extent == _transcriptExtent &&
              context.earlierMessagesAvailable == _earlierMessagesAvailable));

  /// Pure transport read. Every state change driven by the returned page is
  /// committed later by [_consumeSessionMessagesPageEvidence], after freshness
  /// has been checked against the exact request context.
  Future<SessionMessagesPage> _fetchStoredMessagesPage(
    _SessionMessagesPageReadContext context, {
    String? runtimeSessionId,
    bool allowNativeHistory = true,
  }) async {
    final page = await _requestStoredMessagesPage(
      storedSessionId: context.requestedStoredSessionId,
      profile: context.profile,
      limit: context.requestedLimit,
      offset: context.requestedOffset,
      runtimeSessionId: runtimeSessionId,
      allowNativeHistory:
          allowNativeHistory &&
          context.consumer != _SessionMessagesPageConsumer.loadEarlier,
    );
    final expectedCount = context.hardExpectedMessageCount;
    final needsExactBoundaryProbe =
        page is _NativeSessionHistoryPage &&
        page.hasEarlier == true &&
        context.requestedOffset == 0 &&
        expectedCount != null &&
        expectedCount == page.rawMessageCount &&
        page.rawMessageCount == context.requestedLimit &&
        page.messagesFullyParsed;
    if (!needsExactBoundaryProbe) return page;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final lookahead = await _requestStoredMessagesPage(
          storedSessionId: context.requestedStoredSessionId,
          profile: context.profile,
          limit: 1,
          offset: context.requestedLimit,
          allowNativeHistory: false,
        );
        final lookaheadProvesEnd =
            lookahead.rawMessageCount == 0 &&
            lookahead.messagesFullyParsed &&
            lookahead.paginationFullyParsed &&
            (lookahead.resolvedTipId == null ||
                page.resolvedTipId == null ||
                lookahead.resolvedTipId == page.resolvedTipId);
        return lookaheadProvesEnd
            ? _NativeSessionHistoryPage(page, hasEarlier: false)
            : page;
      } on TimeoutException {
        if (attempt == 1) rethrow;
      } on SocketException {
        if (attempt == 1) rethrow;
      } on HttpException {
        if (attempt == 1) rethrow;
      } on http.ClientException {
        if (attempt == 1) rethrow;
      } on CoreReadException catch (error) {
        if (error.kind != CoreReadErrorKind.temporarilyUnavailable ||
            attempt == 1) {
          rethrow;
        }
      }
    }
    throw StateError('Stored message lookahead retry exhausted');
  }

  Future<SessionMessagesPage> _requestStoredMessagesPage({
    required String storedSessionId,
    required String profile,
    int? limit,
    int offset = 0,
    String? runtimeSessionId,
    bool allowNativeHistory = true,
  }) async {
    final injected = _storedMessageLoader;
    if (injected != null) {
      return SessionMessagesPage(
        messages: await injected(storedSessionId, profile),
        pagination: null,
      );
    }
    final gateway = _desktopGateway;
    final runtime =
        runtimeSessionId ??
        (storedSessionId == serverSessionId &&
                profile.trim() == _storedSessionProfile
            ? _desktopRuntimeSessionId
            : null);
    // Keep the same automatic gateway opt-in as loadMessages: a runtime bound
    // by an explicit action does not authorize RPCs from a REST-only load.
    if (allowNativeHistory &&
        (_attachDesktopRuntimeOnLoad ||
            _allowUnownedDesktopSnapshotForTesting) &&
        gateway != null &&
        gateway.isConnected &&
        gateway is HermesDesktopSessionHistoryGateway &&
        runtime != null) {
      _NativeSessionHistoryPage? nativePage;
      try {
        nativePage = _NativeSessionHistoryPage(
          await (gateway as HermesDesktopSessionHistoryGateway).sessionHistory(
            sessionId: runtime,
            profile: profile,
          ),
        );
      } catch (_) {
        // Older gateways and transient RPC failures retain the REST path.
        // Do not log remote payloads or profile credentials.
      }
      if (nativePage != null) {
        final requestedLimit = limit ?? _transcriptPageSize;
        if (nativePage.rawMessageCount > requestedLimit ||
            (_transcriptIsComplete && _messages.isNotEmpty)) {
          return nativePage;
        }
        try {
          final canonicalPage = await _api.getMessagesPage(
            storedSessionId,
            profile: profile,
            limit: requestedLimit,
            offset: offset,
          );
          final canonicalPageIsUsable =
              canonicalPage.messagesFullyParsed &&
              canonicalPage.paginationFullyParsed &&
              (canonicalPage.messages.isNotEmpty ||
                  nativePage.messages.isEmpty) &&
              (!canonicalPage.paginationProvided ||
                  _transcriptRowsHaveUnambiguousIdentityEvidence(
                    canonicalPage.messages,
                  ));
          if (canonicalPageIsUsable) {
            final canonicalLimit = canonicalPage.limit;
            final canonicalHasEarlier = canonicalPage.hasEarlier ??
                (canonicalPage.paginationProvided &&
                    canonicalLimit != null &&
                    canonicalPage.returned >= canonicalLimit);
            return _NativeSessionHistoryPage(
              nativePage,
              hasEarlier: canonicalHasEarlier,
            );
          }
        } on Object {
          // Native history remains usable while canonical REST is unavailable.
        }
        return nativePage;
      }
    }
    return _api.getMessagesPage(
      storedSessionId,
      profile: profile,
      limit: limit ?? _transcriptPageSize,
      offset: offset,
    );
  }

  _SessionMessagesPageTransitionResult _consumeSessionMessagesPageEvidence(
    SessionMessagesPage page,
    _SessionMessagesPageReadContext context, {
    VoidCallback? prepareProjection,
    required _SessionMessagesPageProjection Function(
      bool pageProvesWholeTranscript,
    )
    projector,
  }) {
    const rejectedProjection = _SessionMessagesPageProjection.reject();
    if (!_sessionMessagesPageReadIsFresh(context)) {
      return const _SessionMessagesPageTransitionResult(
        action: _SessionMessagesPageAction.stale,
        projection: rejectedProjection,
      );
    }
    prepareProjection?.call();

    final nativeSessionHistory = page is _NativeSessionHistoryPage;
    final legacyPage = !page.paginationProvided;
    final limit = page.limit;
    final advertisedHasEarlier = page.hasEarlier;
    final terminalPage = advertisedHasEarlier != null
        ? !advertisedHasEarlier
        : legacyPage ||
              (page.paginationFullyParsed &&
                  limit != null &&
                  page.returned < limit);
    final rowsHaveSafePaginationIdentity =
        legacyPage ||
        _transcriptRowsHaveUnambiguousIdentityEvidence(page.messages);
    final pageFullyValid =
        page.messagesFullyParsed &&
        page.paginationFullyParsed &&
        rowsHaveSafePaginationIdentity;
    final pageProvesWholeTranscript =
        page.offset == 0 &&
        terminalPage &&
        pageFullyValid &&
        (!nativeSessionHistory || page.hasEarlier == false);
    final incomingTip = page.resolvedTipId;
    final currentTip = _coreReadIdentity.resolvedTipId;
    final emptyIdentityIsCompatible =
        incomingTip == null ||
        incomingTip == currentTip ||
        (currentTip == null && incomingTip == context.requestedStoredSessionId);
    final hasDurableVisibleTranscript = _messages.any(
      (message) =>
          !_isLiveTranscriptProjection(message) &&
          _hasDurableTranscriptIdentity(message),
    );
    final hardExpectedCountMismatch =
        context.requestedOffset == 0 &&
        (context.hardExpectedMessageCount ?? 0) > 0 &&
        page.rawMessageCount == 0;
    final announcedCount =
        context.announcedMessageCount ?? _desktopHydrationExpectedMessageCount;
    final softExpectedCountMismatch =
        announcedCount != null &&
        terminalPage &&
        page.paginationFullyParsed &&
        page.offset + page.returned < announcedCount;
    final allRowsDiscarded =
        page.rawMessageCount > 0 &&
        page.messages.isEmpty &&
        !page.messagesFullyParsed;
    final consumesAsBackfill =
        context.consumer == _SessionMessagesPageConsumer.loadEarlier &&
        !context.tailHydration;
    final validEmptyAtTail =
        page.rawMessageCount == 0 &&
        page.messagesFullyParsed &&
        page.paginationFullyParsed &&
        emptyIdentityIsCompatible &&
        terminalPage &&
        context.requestedOffset == 0 &&
        !consumesAsBackfill;

    if (validEmptyAtTail &&
        !nativeSessionHistory &&
        !hardExpectedCountMismatch &&
        !softExpectedCountMismatch &&
        hasDurableVisibleTranscript) {
      return const _SessionMessagesPageTransitionResult(
        action: _SessionMessagesPageAction.preserveVisible,
        projection: _SessionMessagesPageProjection.preserve(),
      );
    }

    final validEmptyPage =
        page.rawMessageCount == 0 &&
        page.messagesFullyParsed &&
        page.paginationFullyParsed &&
        emptyIdentityIsCompatible &&
        terminalPage;
    final shouldPrepareProjection =
        page.messages.isNotEmpty ||
        (validEmptyPage &&
            (!hasDurableVisibleTranscript || consumesAsBackfill));
    var projection = shouldPrepareProjection
        ? projector(pageProvesWholeTranscript)
        : const _SessionMessagesPageProjection.preserve();
    if (validEmptyAtTail &&
        !hardExpectedCountMismatch &&
        !softExpectedCountMismatch &&
        !hasDurableVisibleTranscript) {
      projection = const _SessionMessagesPageProjection.publish();
    }
    var nextIdentity = _coreReadIdentity;
    var nextCoverage = _coreReadCoverage;
    var nextLineageComplete = _coreReadLineageComplete;
    var nextExtent = _transcriptExtent;
    var nextParseGap = _transcriptCoverageHasParseGap;
    var nextEarlierAvailable = _earlierMessagesAvailable;
    var nextOffset = _earlierMessagesNextOffset;
    var nextTailHydration = _needsTranscriptTailHydration;
    var nextDesktopHydration = _desktopHistoryNeedsHydration;
    var nextHydrationExpectation = _desktopHydrationExpectedMessageCount;
    var nextUnconfirmed = List<TranscriptMessageIdentity>.of(
      _unconfirmedRetainedTranscriptIdentities,
    );
    var action = _SessionMessagesPageAction.preserveVisible;
    var mutates = false;

    bool coverageHasPartialClaim(Set<CoreReadCoverage> coverage) =>
        coverage.any(
          const <CoreReadCoverage>{
            CoreReadCoverage.tipOnly,
            CoreReadCoverage.metadataPartial,
            CoreReadCoverage.aggregateOnly,
            CoreReadCoverage.unsupported,
          }.contains,
        );

    void applyCoreEvidence({required bool replaceCoverage}) {
      if (incomingTip != null) {
        nextIdentity = nextIdentity.withResolvedTip(incomingTip);
      }
      if (page.coverage.isNotEmpty) {
        nextCoverage = Set<CoreReadCoverage>.unmodifiable(
          replaceCoverage
              ? page.coverage
              : <CoreReadCoverage>{...nextCoverage, ...page.coverage},
        );
      }
      if (coverageHasPartialClaim(nextCoverage)) {
        nextLineageComplete = false;
      }
    }

    void armTailRecovery({required bool recordsParseGap}) {
      nextLineageComplete = false;
      if (recordsParseGap) nextParseGap = true;
      nextExtent = _TranscriptExtent.partial;
      nextEarlierAvailable = true;
      nextOffset = 0;
      nextTailHydration = true;
      nextDesktopHydration = true;
      action = _SessionMessagesPageAction.retryTail;
      mutates = true;
    }

    void acceptProjectionEvidence() {
      if (projection.disposition !=
          _SessionMessagesPageProjectionDisposition.publish) {
        return;
      }
      for (final row in projection.confirmedRows) {
        final identity = _transcriptMessageIdentity(row);
        if (identity == null) continue;
        final visibleIdentity = _uniqueTranscriptIdentityMatch(
          identity,
          _messages,
        );
        if (visibleIdentity != null) {
          _removeMatchingIdentities(nextUnconfirmed, visibleIdentity);
        }
      }
      final refreshedIdentities = _transcriptIdentities(
        projection.refreshedNewestFirst,
      );
      if (!projection.retainsExistingRows) {
        nextUnconfirmed = <TranscriptMessageIdentity>[];
      } else {
        for (final identity in refreshedIdentities) {
          _removeMatchingIdentities(nextUnconfirmed, identity);
        }
      }
      for (final identity in projection.unconfirmedRetainedIdentities) {
        if (!_identityCollectionContains(nextUnconfirmed, identity)) {
          nextUnconfirmed.add(identity);
        }
      }
    }

    void publishUsableTailWhileRecovering() {
      if (context.requestedOffset != 0 ||
          page.messages.isEmpty ||
          projection.disposition !=
              _SessionMessagesPageProjectionDisposition.publish) {
        return;
      }
      acceptProjectionEvidence();
      action = _SessionMessagesPageAction.publish;
    }

    if (hardExpectedCountMismatch) {
      applyCoreEvidence(replaceCoverage: false);
      armTailRecovery(recordsParseGap: true);
      action = _SessionMessagesPageAction.throwExpectedCount;
    } else if (allRowsDiscarded) {
      applyCoreEvidence(replaceCoverage: false);
      armTailRecovery(recordsParseGap: true);
    } else if (page.rawMessageCount == 0 &&
        (!page.messagesFullyParsed ||
            !page.paginationFullyParsed ||
            !emptyIdentityIsCompatible)) {
      applyCoreEvidence(replaceCoverage: false);
      armTailRecovery(recordsParseGap: true);
    } else if (softExpectedCountMismatch) {
      applyCoreEvidence(replaceCoverage: false);
      armTailRecovery(recordsParseGap: false);
      publishUsableTailWhileRecovering();
    } else if (page.messages.isNotEmpty &&
        (!page.paginationFullyParsed || !rowsHaveSafePaginationIdentity)) {
      applyCoreEvidence(replaceCoverage: false);
      armTailRecovery(recordsParseGap: true);
      publishUsableTailWhileRecovering();
    } else if (!page.messagesFullyParsed) {
      applyCoreEvidence(replaceCoverage: false);
      nextLineageComplete = false;
      nextParseGap = true;
      nextExtent = _TranscriptExtent.partial;
      mutates = true;
      if (terminalPage ||
          projection.disposition !=
              _SessionMessagesPageProjectionDisposition.publish) {
        armTailRecovery(recordsParseGap: true);
        publishUsableTailWhileRecovering();
      } else {
        nextEarlierAvailable = true;
        nextOffset = page.offset + page.returned;
        nextTailHydration = false;
        nextDesktopHydration = false;
        action = _SessionMessagesPageAction.continueBackfill;
        acceptProjectionEvidence();
      }
    } else if (projection.disposition ==
        _SessionMessagesPageProjectionDisposition.reject) {
      // Preservar las filas visibles no acredita que esta revisión pueda
      // publicar la página. Un graft rechazado deja un hueco de autoridad aunque
      // la metadata REST diga `full`: degrada conjuntamente toda la evidencia y
      // repara siempre desde offset cero.
      applyCoreEvidence(replaceCoverage: false);
      armTailRecovery(recordsParseGap: true);
    } else if (nativeSessionHistory) {
      applyCoreEvidence(replaceCoverage: false);
      nextLineageComplete = false;
      if (page.hasEarlier == false) {
        nextExtent = _TranscriptExtent.complete;
        nextEarlierAvailable = false;
        nextOffset = page.rawMessageCount;
        nextTailHydration = false;
        nextDesktopHydration = false;
        nextHydrationExpectation = null;
      } else {
        nextExtent = _TranscriptExtent.partial;
        nextEarlierAvailable = true;
        nextOffset = 0;
        nextTailHydration = true;
      }
      if (projection.disposition ==
          _SessionMessagesPageProjectionDisposition.publish) {
        acceptProjectionEvidence();
        action = _SessionMessagesPageAction.publish;
      } else {
        action = _SessionMessagesPageAction.preserveVisible;
      }
      mutates = true;
    } else if (projection.preservesExistingCoverage &&
        page.messages.isNotEmpty) {
      applyCoreEvidence(replaceCoverage: false);
      if (coverageHasPartialClaim(page.coverage)) {
        nextLineageComplete = false;
      }
      acceptProjectionEvidence();
      action = terminalPage
          ? _SessionMessagesPageAction.publish
          : _SessionMessagesPageAction.continueBackfill;
      mutates = true;
    } else if (!terminalPage) {
      applyCoreEvidence(
        replaceCoverage:
            page.offset == 0 &&
            projection.disposition ==
                _SessionMessagesPageProjectionDisposition.publish,
      );
      nextLineageComplete = false;
      nextExtent = _TranscriptExtent.partial;
      nextEarlierAvailable = true;
      nextOffset = page.offset + page.returned;
      nextTailHydration = false;
      nextDesktopHydration = false;
      acceptProjectionEvidence();
      action = _SessionMessagesPageAction.continueBackfill;
      mutates = true;
    } else if (nextParseGap && page.offset > 0) {
      applyCoreEvidence(replaceCoverage: false);
      armTailRecovery(recordsParseGap: true);
    } else {
      applyCoreEvidence(
        replaceCoverage:
            page.offset == 0 &&
            projection.disposition ==
                _SessionMessagesPageProjectionDisposition.publish,
      );
      if (page.offset == 0 && pageProvesWholeTranscript) {
        nextParseGap = false;
      }
      if (nextParseGap) {
        armTailRecovery(recordsParseGap: true);
      } else {
        nextExtent = _TranscriptExtent.complete;
        nextEarlierAvailable = false;
        nextOffset = page.offset + page.returned;
        nextTailHydration = false;
        nextDesktopHydration = false;
        nextHydrationExpectation = null;
        acceptProjectionEvidence();
        final fullCoverage =
            nextCoverage.contains(CoreReadCoverage.full) &&
            !coverageHasPartialClaim(nextCoverage);
        final sameLineage = nextIdentity.logicalRootId == nextIdentity.storedId;
        nextLineageComplete =
            fullCoverage &&
            sameLineage &&
            rowsHaveSafePaginationIdentity &&
            projection.disposition ==
                _SessionMessagesPageProjectionDisposition.publish;
        action = _SessionMessagesPageAction.publish;
        mutates = true;
      }
    }

    if (!mutates) {
      return _SessionMessagesPageTransitionResult(
        action: action,
        projection: projection,
      );
    }

    _coreReadIdentity = nextIdentity;
    _coreReadCoverage = nextCoverage;
    _coreReadLineageComplete = nextLineageComplete;
    _transcriptExtent = nextExtent;
    _transcriptCoverageHasParseGap = nextParseGap;
    _earlierMessagesAvailable = nextEarlierAvailable;
    _earlierMessagesNextOffset = nextOffset;
    _needsTranscriptTailHydration = nextTailHydration;
    _desktopHistoryNeedsHydration = nextDesktopHydration;
    _desktopHydrationExpectedMessageCount = nextHydrationExpectation;
    _unconfirmedRetainedTranscriptIdentities
      ..clear()
      ..addAll(nextUnconfirmed);
    _transcriptCoverageRevision += 1;
    return _SessionMessagesPageTransitionResult(
      action: action,
      projection: projection,
    );
  }

  /// Actualiza el bookkeeping de la cola paginada tras cada página recibida.
  /// Sin metadata `pagination` (gateway legacy) la respuesta ES el transcript
  /// completo: no queda nada anterior que pedir.
  void _markTranscriptComplete({required int visibleCount}) {
    _transcriptCoverageRevision += 1;
    _transcriptCoverageHasParseGap = false;
    _transcriptExtent = _TranscriptExtent.complete;
    _earlierMessagesAvailable = false;
    _earlierMessagesNextOffset = visibleCount;
    _needsTranscriptTailHydration = false;
    _desktopHydrationExpectedMessageCount = null;
    if (_hardExpectedStoredMessageCount != null &&
        visibleCount >= _hardExpectedStoredMessageCount!) {
      _hardExpectedStoredMessageCount = null;
    }
    _unconfirmedRetainedTranscriptIdentities.clear();
  }

  void _recordLocalTranscriptCoverage(LocalTranscriptSnapshot snapshot) {
    _localTranscriptOlderHistoryTruncated = snapshot.olderHistoryTruncated;
    if (!snapshot.olderHistoryTruncated) {
      _markTranscriptComplete(visibleCount: snapshot.messages.length);
      return;
    }
    _transcriptCoverageRevision += 1;
    _transcriptExtent = _TranscriptExtent.partial;
    _transcriptCoverageHasParseGap = true;
    _earlierMessagesAvailable = true;
    _earlierMessagesNextOffset = 0;
    _needsTranscriptTailHydration = true;
    _desktopHydrationExpectedMessageCount = null;
    _unconfirmedRetainedTranscriptIdentities.clear();
  }

  void _rememberDesktopHydrationExpectation(DesktopSessionSnapshot snapshot) {
    final announced = snapshot.messageCount;
    if (_desktopSnapshotTranscriptIsComplete(snapshot)) {
      _desktopHydrationExpectedMessageCount = null;
      return;
    }
    if (!snapshot.hydrating) {
      // Un snapshot posterior ya fuera de hydration pertenece a la generación
      // vigente. Su count (también null) sustituye cualquier expectativa alta
      // de un ack hydrating anterior; conservar el máximo bloquearía para
      // siempre una compactación 300 -> 1 aunque REST acreditase esa única fila.
      _desktopHydrationExpectedMessageCount = announced;
    } else if (announced != null && announced > snapshot.messages.length) {
      _desktopHydrationExpectedMessageCount = math.max(
        _desktopHydrationExpectedMessageCount ?? 0,
        announced,
      );
    }
  }

  bool _preserveInflightOutsideHydrationGraft(Map<String, dynamic> message) =>
      message['_desktopSnapshotKind'] == 'inflight' &&
      message[_terminalProjectionIdKey] == null;

  void _recordDesktopSnapshotTranscript(
    DesktopSessionSnapshot snapshot, {
    bool preserveVisibleFallback = false,
  }) {
    _rememberDesktopHydrationExpectation(snapshot);
    final visibleCount = snapshot.messages.length;
    if (_desktopSnapshotTranscriptIsComplete(snapshot) &&
        !preserveVisibleFallback) {
      final hard = _hardExpectedStoredMessageCount;
      if (hard == null || visibleCount >= hard) {
        _markTranscriptComplete(visibleCount: visibleCount);
        return;
      }
    }
    _transcriptCoverageRevision += 1;

    // Un fallback paginado con offset positivo ya demuestra qué cola se leyó.
    // Un snapshot que omite mensajes no puede rebobinarlo a cero: hacerlo
    // mezclaría la cola actual con una página anterior interpretada como tail.
    if (preserveVisibleFallback &&
        _transcriptExtent == _TranscriptExtent.partial &&
        _earlierMessagesNextOffset > 0) {
      _earlierMessagesAvailable = true;
      _needsTranscriptTailHydration = true;
      return;
    }

    _transcriptExtent = _TranscriptExtent.partial;
    final expectedCount = snapshot.messageCount;
    final snapshotCoverageIsUncertain =
        !snapshot.messagesFullyParsed ||
        !_desktopSnapshotIdentitiesAreUnambiguous(snapshot.messages) ||
        (expectedCount != null && expectedCount < visibleCount);
    _earlierMessagesNextOffset =
        preserveVisibleFallback ||
            snapshot.hydrating ||
            snapshotCoverageIsUncertain
        ? 0
        : snapshot.messagesProvided
        ? visibleCount
        : 0;
    _earlierMessagesAvailable =
        preserveVisibleFallback ||
        !snapshot.messagesProvided ||
        snapshot.hydrating ||
        snapshotCoverageIsUncertain ||
        (expectedCount != null && expectedCount > visibleCount);
    _needsTranscriptTailHydration =
        preserveVisibleFallback ||
        snapshot.hydrating ||
        !snapshot.messagesProvided ||
        snapshotCoverageIsUncertain;
  }

  CancelledTurnTombstone? _durableTombstoneForLocalCancelledUser(
    List<Map<String, dynamic>> newestFirst,
    int userIndex,
  ) {
    final message = newestFirst[userIndex];
    if (!isRealUserTurn(message) || message['_cancelledUser'] != true) {
      return null;
    }
    final content = (message['content'] ?? '').toString();
    if (content.isEmpty) return null;
    final matchingBoundTombstones = _cancelledTurnTombstones
        .where((durable) {
          if (durable.invalidated || durable.content != content) return false;
          final target = _resolveTranscriptIdentity(
            newestFirst,
            messageId: durable.cancelledMessageId,
            rowId: durable.cancelledRowId,
            accepts: isRealUserTurn,
          );
          return target.kind == _TranscriptIdentityResolutionKind.unique &&
              target.index != userIndex;
        })
        .toList(growable: false);
    if (matchingBoundTombstones.length == 1) {
      return matchingBoundTombstones.single;
    }
    final projectedAnchor = message['_cancelledTurnAnchorMessageId'];
    final projectedAnchorRow = message['_cancelledTurnAnchorRowId'];
    final projectedFirstUser = message['_cancelledTurnFirstUser'] == true;
    final projectedTarget = message['_cancelledTurnMessageId'];
    final projectedTargetRow = message['_cancelledTurnRowId'];
    final targetMessageId =
        projectedTarget is String && projectedTarget.isNotEmpty
        ? projectedTarget
        : canonicalTranscriptMessageId(message);
    final targetRowId = projectedTargetRow is int && projectedTargetRow > 0
        ? projectedTargetRow
        : canonicalTranscriptRowId(message);
    final anchorMessageId =
        projectedAnchor is String && projectedAnchor.isNotEmpty
        ? projectedAnchor
        : null;
    final anchorRowId = projectedAnchorRow is int && projectedAnchorRow > 0
        ? projectedAnchorRow
        : null;
    if (targetMessageId != null ||
        targetRowId != null ||
        anchorMessageId != null ||
        anchorRowId != null ||
        projectedFirstUser) {
      final candidate = CancelledTurnTombstone(
        content: content,
        anchorMessageId: anchorMessageId,
        anchorRowId: anchorRowId,
        firstUser: projectedFirstUser,
        cancelledMessageId: targetMessageId,
        cancelledRowId: targetRowId,
      );
      for (final durable in _cancelledTurnTombstones) {
        if (!durable.invalidated && _sameCancelledTurn(durable, candidate)) {
          return durable;
        }
      }
      return null;
    }
    String? olderAnchorMessageId;
    int? olderAnchorRowId;
    for (var older = userIndex + 1; older < newestFirst.length; older++) {
      final olderMessage = newestFirst[older];
      olderAnchorMessageId = canonicalTranscriptMessageId(olderMessage);
      olderAnchorRowId = canonicalTranscriptRowId(olderMessage);
      if (olderAnchorMessageId != null || olderAnchorRowId != null) break;
      if (isRealUserTurn(olderMessage)) return null;
    }
    final hasOlderRealUser = newestFirst
        .skip(userIndex + 1)
        .any(isRealUserTurn);
    final candidate = olderAnchorMessageId != null || olderAnchorRowId != null
        ? CancelledTurnTombstone(
            content: content,
            anchorMessageId: olderAnchorMessageId,
            anchorRowId: olderAnchorRowId,
          )
        : !hasOlderRealUser && _transcriptIsComplete
        ? CancelledTurnTombstone(content: content, firstUser: true)
        : null;
    if (candidate == null) return null;
    for (final durable in _cancelledTurnTombstones) {
      if (!durable.invalidated && _sameCancelledTurn(durable, candidate)) {
        return durable;
      }
    }
    return null;
  }

  bool _refreshedTranscriptReplacesLocalCancelledUser(
    List<Map<String, dynamic>> previous,
    int previousIndex,
    List<Map<String, dynamic>> refreshed, {
    required bool refreshedTranscriptComplete,
  }) {
    final tombstone = _durableTombstoneForLocalCancelledUser(
      previous,
      previousIndex,
    );
    if (tombstone == null) return false;
    final refreshedIndex = _cancelledTurnUserIndex(
      refreshed,
      tombstone,
      incomingTranscriptComplete: refreshedTranscriptComplete,
    );
    return refreshedIndex >= 0 &&
        (canonicalTranscriptMessageId(refreshed[refreshedIndex]) != null ||
            canonicalTranscriptRowId(refreshed[refreshedIndex]) != null);
  }

  int? _terminalProjectionInt(Object? value) => switch (value) {
    int number => number,
    num number => number.toInt(),
    _ => null,
  };

  int? _terminalProjectionRowId(Object? value) =>
      value is int && value > 0 ? value : null;

  _TerminalTurnEvidence _terminalTurnEvidence(
    List<Map<String, dynamic>> newestFirst,
    int userIndex, {
    required bool transcriptComplete,
  }) {
    final projectionIndices = <int>[userIndex];
    var newestTurnIndex = userIndex;
    for (var index = userIndex - 1; index >= 0; index--) {
      final message = newestFirst[index];
      if (isRealUserTurn(message)) break;
      projectionIndices.add(index);
      newestTurnIndex = index;
    }
    final chronological = newestFirst
        .sublist(newestTurnIndex, userIndex + 1)
        .reversed
        .toList(growable: false);
    final authority = _terminalAuthority(
      chronological,
      1,
      sourceTranscriptComplete: transcriptComplete,
    );
    return (
      complete: authority.isAuthoritative,
      projectionIndices: projectionIndices,
      assistantText: authority.assistantText,
    );
  }

  List<_TerminalProjectionFence> _terminalProjectionFences(
    List<Map<String, dynamic>> newestFirst,
  ) {
    final fences = <_TerminalProjectionFence>[];
    final seen = <String>{};
    for (var index = 0; index < newestFirst.length; index++) {
      final message = newestFirst[index];
      if (!isRealUserTurn(message)) continue;
      final rawProjectionId = message[_terminalProjectionIdKey];
      if (rawProjectionId is! String ||
          rawProjectionId.isEmpty ||
          !seen.add(rawProjectionId)) {
        continue;
      }
      final anchor = message[_terminalProjectionAnchorKey];
      final evidence = _terminalTurnEvidence(
        newestFirst,
        index,
        transcriptComplete: _transcriptIsComplete,
      );
      fences.add(
        _TerminalProjectionFence(
          projectionId: rawProjectionId,
          userMessageId: canonicalTranscriptMessageId(message),
          userRowId: canonicalTranscriptRowId(message),
          anchorMessageId: anchor is String && anchor.isNotEmpty
              ? anchor
              : null,
          anchorRowId: _terminalProjectionRowId(
            message[_terminalProjectionAnchorRowKey],
          ),
          ordinalAfterAnchor: _terminalProjectionInt(
            message[_terminalProjectionAnchorOrdinalKey],
          ),
          absoluteUserOrdinal: _terminalProjectionInt(
            message[_terminalProjectionAbsoluteOrdinalKey],
          ),
          localAssistantText: evidence.assistantText,
        ),
      );
    }
    return fences;
  }

  List<_TerminalProjectionFence> _terminalReconciliationFences(
    List<Map<String, dynamic>> newestFirst, {
    bool includeSettledTerminalBoundary = false,
  }) {
    final explicit = _terminalProjectionFences(newestFirst);
    final retained = <_TerminalProjectionFence>[];
    final seen = <String>{};
    for (final fence in <_TerminalProjectionFence>[
      ...explicit,
      ..._privateTerminalProjectionFences,
    ]) {
      if (seen.add(fence.projectionId)) retained.add(fence);
    }
    if (retained.isNotEmpty ||
        !_runTerminal ||
        (!includeSettledTerminalBoundary &&
            state != ChatPipelineState.completed)) {
      return retained;
    }
    final userIndex = newestFirst.indexWhere(isRealUserTurn);
    if (userIndex < 0) return const [];
    final user = newestFirst[userIndex];
    final evidence = _terminalTurnEvidence(
      newestFirst,
      userIndex,
      transcriptComplete: _transcriptIsComplete,
    );
    final userMessageId = canonicalTranscriptMessageId(user);
    final userRowId = canonicalTranscriptRowId(user);
    var anchorIndex = -1;
    String? anchorMessageId;
    int? anchorRowId;
    for (var index = userIndex + 1; index < newestFirst.length; index++) {
      final candidateId = canonicalTranscriptMessageId(newestFirst[index]);
      final candidateRowId = canonicalTranscriptRowId(newestFirst[index]);
      if (candidateId == null && candidateRowId == null) continue;
      anchorIndex = index;
      anchorMessageId = candidateId;
      anchorRowId = candidateRowId;
      break;
    }
    final ordinalAfterAnchor = anchorIndex < 0
        ? null
        : newestFirst
              .sublist(0, anchorIndex)
              .where(
                (message) =>
                    isRealUserTurn(message) &&
                    !_isLiveTranscriptProjection(message),
              )
              .length;
    final absoluteUserOrdinal = _transcriptIsComplete
        ? newestFirst
              .where(
                (message) =>
                    isRealUserTurn(message) &&
                    !_isLiveTranscriptProjection(message),
              )
              .length
        : null;
    if (userMessageId == null &&
        userRowId == null &&
        anchorMessageId == null &&
        anchorRowId == null &&
        absoluteUserOrdinal == null) {
      return const [];
    }
    return [
      _TerminalProjectionFence(
        projectionId: 'terminal-boundary-$_turnEpoch',
        userMessageId: userMessageId,
        userRowId: userRowId,
        anchorMessageId: anchorMessageId,
        anchorRowId: anchorRowId,
        ordinalAfterAnchor: ordinalAfterAnchor,
        absoluteUserOrdinal: absoluteUserOrdinal,
        localAssistantText: evidence.assistantText,
      ),
    ];
  }

  int _terminalFenceTargetIndex(
    List<Map<String, dynamic>> candidateNewestFirst,
    _TerminalProjectionFence fence, {
    required bool candidateTranscriptComplete,
  }) {
    if (fence.userMessageId != null || fence.userRowId != null) {
      final exact = _resolveTranscriptIdentity(
        candidateNewestFirst,
        messageId: fence.userMessageId,
        rowId: fence.userRowId,
        accepts: isRealUserTurn,
      );
      if (exact.kind == _TranscriptIdentityResolutionKind.unique) {
        return exact.index;
      }
      if (exact.kind == _TranscriptIdentityResolutionKind.conflicting) {
        return -1;
      }
    }

    final hasAnchorIdentity =
        fence.anchorMessageId != null || fence.anchorRowId != null;
    final ordinalAfterAnchor = fence.ordinalAfterAnchor;
    if (hasAnchorIdentity &&
        ordinalAfterAnchor != null &&
        ordinalAfterAnchor > 0) {
      final anchor = _resolveTranscriptIdentity(
        candidateNewestFirst,
        messageId: fence.anchorMessageId,
        rowId: fence.anchorRowId,
        accepts: (_) => true,
      );
      if (anchor.kind == _TranscriptIdentityResolutionKind.conflicting) {
        return -1;
      }
      if (anchor.kind == _TranscriptIdentityResolutionKind.unique) {
        var ordinal = 0;
        for (var index = anchor.index - 1; index >= 0; index--) {
          if (!isRealUserTurn(candidateNewestFirst[index])) continue;
          ordinal++;
          if (ordinal == ordinalAfterAnchor) return index;
        }
        // El ancla exacta sí resolvió, pero el usuario causalmente posterior
        // todavía no existe en este candidato. Un ordinal absoluto más débil
        // no puede reanclar la valla sobre un turno histórico.
        return -1;
      }
    }

    final absoluteUserOrdinal = fence.absoluteUserOrdinal;
    if (!hasAnchorIdentity &&
        candidateTranscriptComplete &&
        absoluteUserOrdinal != null &&
        absoluteUserOrdinal > 0) {
      var ordinal = 0;
      for (var index = candidateNewestFirst.length - 1; index >= 0; index--) {
        if (!isRealUserTurn(candidateNewestFirst[index])) continue;
        ordinal++;
        if (ordinal == absoluteUserOrdinal) return index;
      }
    }
    return -1;
  }

  bool _terminalFenceIsCovered(
    List<Map<String, dynamic>> candidateNewestFirst,
    _TerminalProjectionFence fence, {
    required bool candidateTranscriptComplete,
  }) {
    final userIndex = _terminalFenceTargetIndex(
      candidateNewestFirst,
      fence,
      candidateTranscriptComplete: candidateTranscriptComplete,
    );
    if (userIndex < 0) return false;
    final evidence = _terminalTurnEvidence(
      candidateNewestFirst,
      userIndex,
      transcriptComplete: candidateTranscriptComplete,
    );
    if (evidence.projectionIndices.any(
      (index) =>
          candidateNewestFirst[index][_terminalProjectionIdKey] ==
          fence.projectionId,
    )) {
      // Un fallback local no puede acreditarse a sí mismo como persistido.
      return false;
    }
    if (!evidence.complete) return false;
    final local = fence.localAssistantText?.replaceAll(RegExp(r'\s+'), ' ');
    if (local == null || local.isEmpty) return true;
    final remote = evidence.assistantText?.replaceAll(RegExp(r'\s+'), ' ');
    if (remote == null || remote.isEmpty) return false;
    // El contenido no identifica mensajes. Solo evita sustituir una respuesta
    // visible por un prefijo demostrablemente anterior de esa misma posición.
    return !(remote.length < local.length && local.startsWith(remote));
  }

  bool _terminalFencesAreCovered(
    List<Map<String, dynamic>> candidateNewestFirst,
    List<_TerminalProjectionFence> fences, {
    required bool candidateTranscriptComplete,
  }) => fences.every(
    (fence) => _terminalFenceIsCovered(
      candidateNewestFirst,
      fence,
      candidateTranscriptComplete: candidateTranscriptComplete,
    ),
  );

  List<Map<String, dynamic>> _carryNewestTerminalFence(
    List<Map<String, dynamic>> previous,
    List<Map<String, dynamic>> candidateNewestFirst, {
    required bool candidateTranscriptComplete,
  }) {
    final fences = _terminalReconciliationFences(previous);
    if (fences.isEmpty ||
        !_terminalFencesAreCovered(
          candidateNewestFirst,
          fences,
          candidateTranscriptComplete: candidateTranscriptComplete,
        )) {
      return candidateNewestFirst;
    }
    final coveredIds = {for (final fence in fences) fence.projectionId};
    _privateTerminalProjectionFences.removeWhere(
      (fence) => coveredIds.contains(fence.projectionId),
    );
    return candidateNewestFirst
        .map((message) {
          if (message[_terminalProjectionIdKey] == null &&
              message[_terminalProjectionAnchorKey] == null &&
              message[_terminalProjectionAnchorRowKey] == null &&
              message[_terminalProjectionAnchorOrdinalKey] == null &&
              message[_terminalProjectionAbsoluteOrdinalKey] == null) {
            return message;
          }
          return Map<String, dynamic>.of(message)
            ..remove(_terminalProjectionIdKey)
            ..remove(_terminalProjectionAnchorKey)
            ..remove(_terminalProjectionAnchorRowKey)
            ..remove(_terminalProjectionAnchorOrdinalKey)
            ..remove(_terminalProjectionAbsoluteOrdinalKey);
        })
        .toList(growable: true);
  }

  void _attachTerminalProjectionMetadata(
    int index,
    Map<String, dynamic> metadata,
  ) {
    final message = _messages[index];
    try {
      // Las burbujas vivas usan la identidad del mapa para retener su host de
      // viewport. Añadir metadata privada in-place conserva esa identidad.
      message.addAll(metadata);
    } on UnsupportedError {
      // Las filas proyectadas por Desktop son inmutables; su copia sigue
      // siendo segura porque no existe un host local que deba conservarse.
      _messages[index] = {...message, ...metadata};
    }
  }

  void _markCurrentTurnAwaitingTranscript() {
    final userIndex = _messages.indexWhere(isRealUserTurn);
    if (userIndex < 0) return;
    final currentProjection = _messages.take(userIndex + 1);
    final hasLiveEvidence = currentProjection.any(
      (message) =>
          message['_optimistic'] == true ||
          message['_pipeline'] == true ||
          message['_desktopSnapshotKind'] == 'inflight' ||
          message['_desktopInterim'] == true,
    );
    if (!hasLiveEvidence) return;

    var anchorIndex = -1;
    String? anchorMessageId;
    int? anchorRowId;
    for (var index = userIndex + 1; index < _messages.length; index++) {
      final candidateId = canonicalTranscriptMessageId(_messages[index]);
      final candidateRowId = canonicalTranscriptRowId(_messages[index]);
      if (candidateId == null && candidateRowId == null) continue;
      anchorIndex = index;
      anchorMessageId = candidateId;
      anchorRowId = candidateRowId;
      break;
    }
    final ordinalAfterAnchor = anchorIndex < 0
        ? null
        : _messages.sublist(0, anchorIndex).where(isRealUserTurn).length;
    final absoluteUserOrdinal = _transcriptIsComplete
        ? _messages
              .where(
                (message) =>
                    isRealUserTurn(message) &&
                    !_isLiveTranscriptProjection(message),
              )
              .length
        : null;
    final projectionId = 'terminal-$_turnEpoch';
    for (var index = 0; index <= userIndex; index++) {
      _attachTerminalProjectionMetadata(index, {
        _terminalProjectionIdKey: projectionId,
      });
    }
    _attachTerminalProjectionMetadata(userIndex, {
      _terminalProjectionIdKey: projectionId,
      _terminalProjectionAnchorKey: ?anchorMessageId,
      _terminalProjectionAnchorRowKey: ?anchorRowId,
      _terminalProjectionAnchorOrdinalKey: ?ordinalAfterAnchor,
      _terminalProjectionAbsoluteOrdinalKey: ?absoluteUserOrdinal,
    });
    final marked = _terminalProjectionFences(_messages);
    for (final fence in marked) {
      _privateTerminalProjectionFences.removeWhere(
        (candidate) => candidate.projectionId == fence.projectionId,
      );
      _privateTerminalProjectionFences.add(fence);
    }
  }

  List<Map<String, dynamic>> _mergeRetainedLocalWithDurable(
    List<Map<String, dynamic>> retainedLocal,
    List<Map<String, dynamic>> durableNewestFirst,
  ) {
    if (retainedLocal.isEmpty) return durableNewestFirst;
    final ordinary = <Map<String, dynamic>>[];
    final compactedGroups = <String, List<Map<String, dynamic>>>{};
    for (final message in retainedLocal) {
      final projectionId = message[_localCompactedTerminalProjectionKey];
      if (projectionId is! String || projectionId.isEmpty) {
        ordinary.add(message);
        continue;
      }
      compactedGroups.putIfAbsent(projectionId, () => []).add(message);
    }
    final merged = <Map<String, dynamic>>[...ordinary, ...durableNewestFirst];
    for (final group in compactedGroups.values) {
      String? anchorMessageId;
      int? anchorRowId;
      for (final message in group) {
        final rawMessageId = message[_localCompactedTerminalAnchorMessageIdKey];
        final rawRowId = message[_localCompactedTerminalAnchorRowIdKey];
        if (rawMessageId is String && rawMessageId.isNotEmpty) {
          anchorMessageId = rawMessageId;
        }
        if (rawRowId is int && rawRowId > 0) anchorRowId = rawRowId;
      }
      final anchor = _resolveTranscriptIdentity(
        merged,
        messageId: anchorMessageId,
        rowId: anchorRowId,
        accepts: (_) => true,
      );
      // Sin un ancla exacta, una proyección histórica nunca vuelve a ocupar la
      // posición del turno actual: se conserva al final hasta recuperar prueba.
      final insertionIndex =
          anchor.kind == _TranscriptIdentityResolutionKind.unique
          ? anchor.index
          : merged.length;
      merged.insertAll(insertionIndex, group);
    }
    return merged;
  }

  /// Re-ancla una cola refrescada sobre un transcript al que ya se le
  /// cargaron páginas anteriores. Sustituir la lista por la cola nueva
  /// descartaría el prefijo recuperado con [loadEarlierMessages]. Solo adopta
  /// cobertura solapada o disjunta cuando sus IDs permiten demostrar y podar
  /// el prefijo; ante filas históricas sin identidad falla cerrado.
  _RefreshedTranscriptGraft _graftRefreshedTail(
    List<Map<String, dynamic>> refreshedNewestFirst,
    List<Map<String, dynamic>> previous, {
    required bool refreshedTranscriptComplete,
    List<_TerminalProjectionFence> requiredTerminalFences = const [],
    bool enforceTerminalFences = true,
    bool preservePartialExactTailCoverage = false,
  }) {
    final representedLiveUserIndexes = <int>{
      ..._liveUserProjectionIndexesRepresentedByRefreshedTail(
        refreshedNewestFirst,
        previous,
        refreshedTranscriptComplete: refreshedTranscriptComplete,
        currentTransportTerminalObserved: false,
      ),
      ..._liveUserProjectionIndexesRepresentedAfterActiveTurnBoundary(
        refreshedNewestFirst,
        previous,
      ),
    };
    final terminalFences = <_TerminalProjectionFence>[];
    if (enforceTerminalFences) {
      final seen = <String>{};
      for (final fence in <_TerminalProjectionFence>[
        ...requiredTerminalFences,
        ..._terminalReconciliationFences(previous),
      ]) {
        if (seen.add(fence.projectionId)) terminalFences.add(fence);
      }
    }
    if (terminalFences.isNotEmpty) {
      if (!_terminalFencesAreCovered(
        refreshedNewestFirst,
        terminalFences,
        candidateTranscriptComplete: refreshedTranscriptComplete,
      )) {
        // Un único turno puede producir más de una página de tools antes de
        // que offset=120 alcance su user canónico. La cola durable puede
        // avanzar provisionalmente, pero la proyección terminal local sigue
        // vallada y visible hasta que una página posterior acredite el turno.
        if (!refreshedTranscriptComplete &&
            refreshedNewestFirst.isNotEmpty &&
            _allTranscriptRowsHaveDurableIds(refreshedNewestFirst)) {
          final fenceIds = {
            for (final fence in terminalFences) fence.projectionId,
          };
          var terminalUserIndex = previous.indexWhere(
            (message) =>
                isRealUserTurn(message) &&
                fenceIds.contains(message[_terminalProjectionIdKey]),
          );
          if (terminalUserIndex < 0) {
            for (final fence in terminalFences) {
              final candidateIndex = _terminalFenceTargetIndex(
                previous,
                fence,
                candidateTranscriptComplete: _transcriptIsComplete,
              );
              if (candidateIndex > terminalUserIndex) {
                terminalUserIndex = candidateIndex;
              }
            }
          }
          if (terminalUserIndex >= 0) {
            final prefix = previous.sublist(0, terminalUserIndex);
            final terminalProjectionId =
                previous[terminalUserIndex][_terminalProjectionIdKey];
            final protectedPrefix = previous
                .take(terminalUserIndex + 1)
                .where(
                  (message) =>
                      !_hasDurableTranscriptIdentity(message) ||
                      message[_terminalProjectionIdKey] == terminalProjectionId,
                )
                .toList(growable: false);
            final durablePrefix = prefix
                .where(
                  (message) =>
                      _hasDurableTranscriptIdentity(message) &&
                      message[_terminalProjectionIdKey] != terminalProjectionId,
                )
                .toList(growable: false);
            final refreshedAndKnown = _mergeOlderTranscriptPage(
              refreshedNewestFirst,
              durablePrefix,
            );
            final protectedIdentities = _transcriptIdentities(protectedPrefix);
            final refreshedAndKnownPrefix = refreshedAndKnown
                .where((message) {
                  final identity = _transcriptMessageIdentity(message);
                  return identity == null ||
                      !_identityCollectionContains(
                        protectedIdentities,
                        identity,
                      );
                })
                .toList(growable: false);
            final refreshedIdentities = _transcriptIdentities(
              refreshedNewestFirst,
            );
            final provisionalPreviousIdentities =
                _transcriptIdentities(previous)
                    .where(
                      (identity) => !_identityCollectionContains(
                        refreshedIdentities,
                        identity,
                      ),
                    )
                    .toList(growable: false);
            final knownIdentities = _transcriptIdentities(
              refreshedAndKnownPrefix,
            );
            final older = previous
                .skip(terminalUserIndex + 1)
                .where((message) {
                  final identity = _transcriptMessageIdentity(message);
                  return identity == null ||
                      !_identityCollectionContains(knownIdentities, identity);
                })
                .toList(growable: false);
            return (
              messages: <Map<String, dynamic>>[
                ...protectedPrefix,
                ...refreshedAndKnownPrefix,
                ...older,
              ],
              preservesExistingCoverage: false,
              acceptedRefreshed: true,
              retainsExistingRows: true,
              unconfirmedRetainedIdentities: provisionalPreviousIdentities,
            );
          }
        }
        return (
          messages: previous,
          preservesExistingCoverage: true,
          acceptedRefreshed: false,
          retainsExistingRows: true,
          unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
        );
      }
      final withoutCoveredTerminal = previous
          .where((message) => message[_terminalProjectionIdKey] == null)
          .toList(growable: false);
      final reconciled = _graftRefreshedTail(
        refreshedNewestFirst,
        withoutCoveredTerminal,
        refreshedTranscriptComplete: refreshedTranscriptComplete,
        enforceTerminalFences: false,
        preservePartialExactTailCoverage: preservePartialExactTailCoverage,
      );
      if (!reconciled.acceptedRefreshed) {
        return (
          messages: previous,
          preservesExistingCoverage: true,
          acceptedRefreshed: false,
          retainsExistingRows: true,
          unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
        );
      }
      return (
        messages: _carryNewestTerminalFence(
          previous,
          reconciled.messages,
          candidateTranscriptComplete: refreshedTranscriptComplete,
        ),
        preservesExistingCoverage: reconciled.preservesExistingCoverage,
        acceptedRefreshed: true,
        retainsExistingRows: reconciled.retainsExistingRows,
        unconfirmedRetainedIdentities: reconciled.unconfirmedRetainedIdentities,
      );
    }
    if (refreshedTranscriptComplete && refreshedNewestFirst.isNotEmpty) {
      final retainedLocal = <Map<String, dynamic>>[
        for (var index = 0; index < previous.length; index++)
          if (!representedLiveUserIndexes.contains(index) &&
              !_hasDurableTranscriptIdentity(previous[index]) &&
              _isKnownLocalTranscriptProjection(previous, index) &&
              previous[index]['_steer'] != true &&
              previous[index]['_cancelled'] != true &&
              !_refreshedTranscriptReplacesLocalCancelledUser(
                previous,
                index,
                refreshedNewestFirst,
                refreshedTranscriptComplete: refreshedTranscriptComplete,
              ))
            previous[index],
      ];
      return (
        messages: _mergeRetainedLocalWithDurable(
          retainedLocal,
          refreshedNewestFirst,
        ),
        preservesExistingCoverage: false,
        acceptedRefreshed: true,
        retainsExistingRows: retainedLocal.isNotEmpty,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }
    if (previous.isEmpty) {
      return (
        messages: refreshedNewestFirst,
        preservesExistingCoverage: false,
        acceptedRefreshed: true,
        retainsExistingRows: false,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }
    if (refreshedNewestFirst.isEmpty) {
      return (
        messages: previous,
        preservesExistingCoverage: true,
        acceptedRefreshed: false,
        retainsExistingRows: true,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }

    final canPartitionPrevious =
        <int>[
          for (var index = 0; index < previous.length; index++) index,
        ].every(
          (index) =>
              _hasDurableTranscriptIdentity(previous[index]) ||
              _isKnownLocalTranscriptProjection(previous, index),
        );
    final durablePrevious = canPartitionPrevious
        ? previous.where(_hasDurableTranscriptIdentity).toList(growable: false)
        : previous;
    final retainedLocal = canPartitionPrevious
        ? <Map<String, dynamic>>[
            for (var index = 0; index < previous.length; index++)
              if (!representedLiveUserIndexes.contains(index) &&
                  !_hasDurableTranscriptIdentity(previous[index]) &&
                  previous[index]['_steer'] != true &&
                  previous[index]['_cancelled'] != true &&
                  !_refreshedTranscriptReplacesLocalCancelledUser(
                    previous,
                    index,
                    refreshedNewestFirst,
                    refreshedTranscriptComplete: refreshedTranscriptComplete,
                  ))
                previous[index],
          ]
        : const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> withRetainedLocal(
      List<Map<String, dynamic>> durable,
    ) => _mergeRetainedLocalWithDurable(retainedLocal, durable);

    final exactlyMatchesKnownTail =
        (_transcriptIsComplete || preservePartialExactTailCoverage) &&
        refreshedNewestFirst.length <= durablePrevious.length &&
        <int>[
          for (var index = 0; index < refreshedNewestFirst.length; index++)
            index,
        ].every((index) {
          final refreshedIdentity = _transcriptMessageIdentity(
            refreshedNewestFirst[index],
          );
          final previousIdentity = _transcriptMessageIdentity(
            durablePrevious[index],
          );
          return refreshedIdentity != null &&
              previousIdentity != null &&
              refreshedIdentity.matches(previousIdentity);
        });
    if (exactlyMatchesKnownTail) {
      final stableRefreshed = <Map<String, dynamic>>[
        for (var index = 0; index < refreshedNewestFirst.length; index++)
          mapEquals(refreshedNewestFirst[index], durablePrevious[index])
              ? durablePrevious[index]
              : refreshedNewestFirst[index],
      ];
      return (
        messages: withRetainedLocal(<Map<String, dynamic>>[
          ...stableRefreshed,
          ...durablePrevious.sublist(refreshedNewestFirst.length),
        ]),
        preservesExistingCoverage: true,
        acceptedRefreshed: true,
        retainsExistingRows:
            durablePrevious.length > refreshedNewestFirst.length ||
            retainedLocal.isNotEmpty,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }

    final anchor = _transcriptMessageIdentity(refreshedNewestFirst.last);
    if (anchor == null) {
      return (
        messages: previous,
        preservesExistingCoverage: true,
        acceptedRefreshed: false,
        retainsExistingRows: true,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }
    var index = -1;
    for (
      var candidateIndex = 0;
      candidateIndex < durablePrevious.length;
      candidateIndex++
    ) {
      final candidateIdentity = _transcriptMessageIdentity(
        durablePrevious[candidateIndex],
      );
      if (candidateIdentity == null ||
          !anchor.sharesExactCoordinate(candidateIdentity)) {
        continue;
      }
      if (!anchor.matches(candidateIdentity) || index >= 0) {
        index = -2;
        break;
      }
      index = candidateIndex;
    }
    if (index < 0) {
      if (_allTranscriptRowsHaveDurableIds(refreshedNewestFirst) &&
          canPartitionPrevious &&
          _allTranscriptRowsHaveDurableIds(durablePrevious)) {
        final refreshedIdentities = _transcriptIdentities(refreshedNewestFirst);
        final unconfirmedRetainedIdentities = _transcriptIdentities(
          durablePrevious,
        ).where(
          (identity) => !_identityCollectionContains(
            refreshedIdentities,
            identity,
          ),
        ).toList(growable: false);
        return (
          messages: withRetainedLocal(
            _mergeOlderTranscriptPage(refreshedNewestFirst, durablePrevious),
          ),
          preservesExistingCoverage: false,
          acceptedRefreshed: true,
          retainsExistingRows:
              durablePrevious.isNotEmpty || retainedLocal.isNotEmpty,
          unconfirmedRetainedIdentities: unconfirmedRetainedIdentities,
        );
      }
      return (
        messages: previous,
        preservesExistingCoverage: true,
        acceptedRefreshed: false,
        retainsExistingRows: true,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }
    if (!canPartitionPrevious) {
      return (
        messages: previous,
        preservesExistingCoverage: true,
        acceptedRefreshed: false,
        retainsExistingRows: true,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }
    final retainedPrefix = durablePrevious.sublist(index + 1);
    if (!_allTranscriptRowsHaveDurableIds(retainedPrefix)) {
      return (
        messages: previous,
        preservesExistingCoverage: true,
        acceptedRefreshed: false,
        retainsExistingRows: true,
        unconfirmedRetainedIdentities: const <TranscriptMessageIdentity>[],
      );
    }
    return (
      messages: withRetainedLocal(<Map<String, dynamic>>[
        ...refreshedNewestFirst,
        ...retainedPrefix,
      ]),
      preservesExistingCoverage: false,
      acceptedRefreshed: true,
      retainsExistingRows:
          retainedPrefix.isNotEmpty || retainedLocal.isNotEmpty,
      unconfirmedRetainedIdentities: _transcriptIdentities(retainedPrefix),
    );
  }

  List<Map<String, dynamic>> _reconcileCoveredTerminalProjection(
    List<Map<String, dynamic>> candidateNewestFirst, {
    required bool candidateTranscriptComplete,
  }) {
    final fences = _terminalReconciliationFences(_messages);
    if (fences.isEmpty) return candidateNewestFirst;
    final withoutLocalProjection = <Map<String, dynamic>>[];
    for (final message in candidateNewestFirst) {
      if (message[_terminalProjectionIdKey] == null) {
        withoutLocalProjection.add(message);
        continue;
      }
      final messageIdentity = _transcriptMessageIdentity(message);
      if (messageIdentity == null ||
          _identityCollectionContains(
            _unconfirmedRetainedTranscriptIdentities,
            messageIdentity,
          )) {
        continue;
      }
      withoutLocalProjection.add(
        Map<String, dynamic>.of(message)
          ..remove(_terminalProjectionIdKey)
          ..remove(_terminalProjectionAnchorKey)
          ..remove(_terminalProjectionAnchorRowKey)
          ..remove(_terminalProjectionAnchorOrdinalKey)
          ..remove(_terminalProjectionAbsoluteOrdinalKey),
      );
    }
    if (!_terminalFencesAreCovered(
      withoutLocalProjection,
      fences,
      candidateTranscriptComplete: candidateTranscriptComplete,
    )) {
      return candidateNewestFirst;
    }
    return _carryNewestTerminalFence(
      _messages,
      withoutLocalProjection,
      candidateTranscriptComplete: candidateTranscriptComplete,
    );
  }

  void _commitRefreshedTailEvidence(
    List<Map<String, dynamic>> refreshedNewestFirst,
    _RefreshedTranscriptGraft graft, {
    bool preserveTailHydration = false,
  }) {
    if (!graft.acceptedRefreshed) return;
    _transcriptCoverageRevision += 1;
    final refreshedIdentities = _transcriptIdentities(refreshedNewestFirst);
    if (!graft.retainsExistingRows) {
      _unconfirmedRetainedTranscriptIdentities.clear();
    } else {
      for (final identity in refreshedIdentities) {
        _removeMatchingIdentities(
          _unconfirmedRetainedTranscriptIdentities,
          identity,
        );
      }
    }
    for (final identity in graft.unconfirmedRetainedIdentities) {
      if (!_identityCollectionContains(
        _unconfirmedRetainedTranscriptIdentities,
        identity,
      )) {
        _unconfirmedRetainedTranscriptIdentities.add(identity);
      }
    }
    if (!preserveTailHydration) _needsTranscriptTailHydration = false;
  }

  List<Map<String, dynamic>> _mergeOlderPageBeforeUnconfirmedPrefix(
    List<Map<String, dynamic>> existingNewestFirst,
    List<Map<String, dynamic>> olderPageNewestFirst,
  ) {
    if (_unconfirmedRetainedTranscriptIdentities.isEmpty) {
      return _mergeOlderTranscriptPage(
        existingNewestFirst,
        olderPageNewestFirst,
      );
    }
    final confirmed = <Map<String, dynamic>>[];
    final provisional = <Map<String, dynamic>>[];
    final olderPageIdentities = _transcriptIdentities(olderPageNewestFirst);
    for (final message in existingNewestFirst) {
      final identity = _transcriptMessageIdentity(message);
      final terminalProjectionStillMissing =
          message[_terminalProjectionIdKey] != null &&
          identity != null &&
          !_identityCollectionContains(olderPageIdentities, identity);
      if (identity != null &&
          _identityCollectionContains(
            _unconfirmedRetainedTranscriptIdentities,
            identity,
          ) &&
          !terminalProjectionStillMissing) {
        provisional.add(message);
      } else {
        confirmed.add(message);
      }
    }
    return _mergeOlderTranscriptPage(
      _mergeOlderTranscriptPage(confirmed, olderPageNewestFirst),
      provisional,
    );
  }

  List<Map<String, dynamic>> _pruneUnconfirmedRowsAtTranscriptStart(
    List<Map<String, dynamic>> candidate,
  ) {
    if (!_transcriptIsComplete ||
        _unconfirmedRetainedTranscriptIdentities.isEmpty) {
      return candidate;
    }
    final compactedProjectionIds = <String>{};
    for (final message in candidate) {
      final identity = _transcriptMessageIdentity(message);
      final projectionId = message[_terminalProjectionIdKey];
      if (identity != null &&
          projectionId is String &&
          projectionId.isNotEmpty &&
          _identityCollectionContains(
            _unconfirmedRetainedTranscriptIdentities,
            identity,
          )) {
        compactedProjectionIds.add(projectionId);
      }
    }
    final compactedAnchors = <String, TranscriptMessageIdentity?>{};
    for (final projectionId in compactedProjectionIds) {
      final pairEnd = candidate.lastIndexWhere(
        (message) => message[_terminalProjectionIdKey] == projectionId,
      );
      TranscriptMessageIdentity? olderAnchor;
      for (var index = pairEnd + 1; index < candidate.length; index++) {
        final candidateMessage = candidate[index];
        final candidateProjectionId =
            candidateMessage[_terminalProjectionIdKey];
        if (candidateProjectionId is String &&
            compactedProjectionIds.contains(candidateProjectionId)) {
          continue;
        }
        final candidateIdentity = _transcriptMessageIdentity(candidateMessage);
        if (candidateIdentity != null &&
            !_identityCollectionContains(
              _unconfirmedRetainedTranscriptIdentities,
              candidateIdentity,
            )) {
          olderAnchor = candidateIdentity;
          break;
        }
      }
      compactedAnchors[projectionId] = olderAnchor;
    }
    final projected = <Map<String, dynamic>>[];
    for (final message in candidate) {
      final identity = _transcriptMessageIdentity(message);
      final unconfirmed =
          identity != null &&
          _identityCollectionContains(
            _unconfirmedRetainedTranscriptIdentities,
            identity,
          );
      final projectionId = message[_terminalProjectionIdKey];
      final compactedTerminalPair =
          projectionId is String &&
          compactedProjectionIds.contains(projectionId);
      if (unconfirmed && !compactedTerminalPair) continue;
      if (!compactedTerminalPair) {
        projected.add(message);
        continue;
      }
      // Llegar al inicio absoluto sin reencontrar la identidad prueba que la
      // compactación la retiró. Conserva el par local, pero ya como proyección
      // histórica id-less: no debe seguir reclamando identidad durable ni
      // bloquear para siempre refreshes posteriores mediante una valla huérfana.
      final olderAnchor = compactedAnchors[projectionId];
      final compacted = Map<String, dynamic>.of(message)
        ..remove('_desktopMessageId')
        ..remove('message_id')
        ..remove('_desktopRowId')
        ..remove('row_id')
        ..remove('_row_id')
        ..remove('id')
        ..remove(_terminalProjectionIdKey)
        ..remove(_terminalProjectionAnchorKey)
        ..remove(_terminalProjectionAnchorRowKey)
        ..remove(_terminalProjectionAnchorOrdinalKey)
        ..remove(_terminalProjectionAbsoluteOrdinalKey)
        ..[_localCompactedTerminalProjectionKey] = projectionId;
      if (olderAnchor?.messageId case final messageId?) {
        compacted[_localCompactedTerminalAnchorMessageIdKey] = messageId;
      }
      if (olderAnchor?.rowId case final rowId?) {
        compacted[_localCompactedTerminalAnchorRowIdKey] = rowId;
      }
      projected.add(compacted);
    }
    _privateTerminalProjectionFences.removeWhere(
      (fence) => compactedProjectionIds.contains(fence.projectionId),
    );
    _unconfirmedRetainedTranscriptIdentities.clear();
    return projected;
  }

  int _visibleConversationMessageCountIn(List<Map<String, dynamic>> messages) =>
      messages.where((message) {
        final role = message['role']?.toString();
        if (role != 'user' && role != 'assistant') return false;
        final content = message['content'];
        return content is String && content.trim().isNotEmpty;
      }).length;

  String? _visibleConversationIdentity(Map<String, dynamic> message) {
    final role = message['role']?.toString();
    final content = message['content'];
    if ((role != 'user' && role != 'assistant') ||
        content is! String ||
        content.trim().isEmpty) {
      return null;
    }
    final messageId = canonicalTranscriptMessageId(message);
    final rowId = canonicalTranscriptRowId(message);
    if (messageId != null || rowId != null) {
      return '${messageId ?? ''}\u0000${rowId ?? ''}';
    }
    return 'idless\u0000$role\u0000$content\u0000${message['timestamp'] ?? ''}';
  }

  bool _hasPotentialUserGenerationReplacement(
    List<Map<String, dynamic>> refreshedNewestFirst,
    _RefreshedTranscriptGraft graft,
  ) {
    if (graft.unconfirmedRetainedIdentities.isEmpty) return false;
    final provisionalUsers = _messages.where((message) {
      if (message['role'] != 'user' || message['content'] is! String) {
        return false;
      }
      final identity = _transcriptMessageIdentity(message);
      return identity != null &&
          _identityCollectionContains(
            graft.unconfirmedRetainedIdentities,
            identity,
          );
    });
    for (final refreshed in refreshedNewestFirst) {
      if (refreshed['role'] != 'user' || refreshed['content'] is! String) {
        continue;
      }
      final refreshedIdentity = _transcriptMessageIdentity(refreshed);
      if (refreshedIdentity == null) continue;
      for (final provisional in provisionalUsers) {
        final provisionalIdentity = _transcriptMessageIdentity(provisional);
        if (provisionalIdentity != null &&
            !refreshedIdentity.matches(provisionalIdentity) &&
            refreshed['content'] == provisional['content']) {
          return true;
        }
      }
    }
    return false;
  }

  String? _durableTailIdentity(List<Map<String, dynamic>> rows) {
    for (final row in rows.reversed) {
      final messageId = canonicalTranscriptMessageId(row);
      final rowId = canonicalTranscriptRowId(row);
      if (messageId == null && rowId == null) continue;
      return '${messageId ?? ''}\u0000${rowId ?? ''}';
    }
    return null;
  }

  void _projectPassiveDurableToolActivity(
    List<Map<String, dynamic>> rows, {
    required bool passiveObservation,
  }) {
    if (!passiveObservation || hasDesktopRuntime || isStreaming) {
      _passiveDurableToolActivity.clear();
      return;
    }
    final lastUserIndex = rows.lastIndexWhere(isRealUserTurn);
    if (lastUserIndex < 0 || lastUserIndex == rows.length - 1) {
      _passiveDurableToolActivity.clear();
      return;
    }
    final turnRows = rows.sublist(lastUserIndex + 1);
    final hasFinalAssistant = turnRows.any((row) {
      if (row['role'] != 'assistant') return false;
      final content = row['content'];
      final calls = row['tool_calls'];
      return content is String &&
          content.trim().isNotEmpty &&
          (calls is! List || calls.isEmpty);
    });
    if (hasFinalAssistant) {
      _passiveDurableToolActivity.clear();
      return;
    }

    final completedCallIds = <String>{};
    for (final row in turnRows) {
      if (row['role'] != 'tool') continue;
      final callId = _toolCallId(row);
      if (callId != null) completedCallIds.add(callId);
    }
    final projected = <(String, bool)>[];
    for (final row in turnRows) {
      if (row['role'] != 'assistant') continue;
      final rawCalls = row['tool_calls'];
      if (rawCalls is! List) continue;
      final messageIdentity =
          canonicalTranscriptMessageId(row) ?? canonicalTranscriptRowId(row);
      for (var callIndex = 0; callIndex < rawCalls.length; callIndex++) {
        final rawCall = rawCalls[callIndex];
        if (rawCall is! Map) continue;
        final call = Map<String, dynamic>.from(rawCall);
        final callId = _toolCallId(call, allowGenericId: true);
        final opaqueKey =
            callId ??
            (messageIdentity == null ? null : '$messageIdentity:$callIndex');
        if (opaqueKey == null) continue;
        projected.add((
          opaqueKey,
          callId != null && completedCallIds.contains(callId),
        ));
      }
    }
    final bounded = projected.length <= 6
        ? projected
        : projected.sublist(projected.length - 6);
    final boundedKeys = bounded.map((entry) => entry.$1).toSet();
    _passiveDurableToolActivity.removeWhere(
      (key, _) => !boundedKeys.contains(key),
    );
    for (final (opaqueKey, completed) in bounded) {
      final retained = _passiveDurableToolActivity[opaqueKey];
      if (retained == null) {
        _passiveDurableToolActivity[opaqueKey] = _PassiveDurableActivity(
          opaqueKey: opaqueKey,
          completed: completed,
        );
      } else {
        retained.completed = completed;
      }
    }
  }

  void _observeDurableTail(
    List<Map<String, dynamic>> rows, {
    required bool passiveObservation,
  }) {
    _projectPassiveDurableToolActivity(
      rows,
      passiveObservation: passiveObservation,
    );
    final nextIdentity = _durableTailIdentity(rows);
    if (nextIdentity == null) return;
    final previousIdentity = _lastDurableTailIdentity;
    _lastDurableTailIdentity = nextIdentity;
    if (passiveObservation &&
        previousIdentity != null &&
        previousIdentity != nextIdentity &&
        !hasDesktopRuntime &&
        !isStreaming) {
      final becameVisible = !_passiveActivityVisible;
      _passiveActivityVisible = true;
      if (_passiveRemoteActivityState != DesktopPassiveActivityState.busy) {
        _schedulePassiveActivityExpiry();
      }
      if (becameVisible) _emit(ActiveChatEvent.sessionInfo);
    }
  }

  Future<void> _backfillInitialConversationWindow({
    required bool refreshedPageHadVisibleConversation,
    required bool verifyPotentialUserGenerationReplacement,
  }) async {
    if (refreshedPageHadVisibleConversation &&
        !verifyPotentialUserGenerationReplacement) {
      return;
    }
    final retainedVisibleIdentities = <String>{
      for (final message in _messages) ?_visibleConversationIdentity(message),
    };
    while (!_disposed &&
        _earlierMessagesAvailable &&
        _remainingInitialBackfillPages > 0) {
      final loaded = await loadEarlierMessages();
      if (!loaded) return;
      _remainingInitialBackfillPages -= 1;
      final foundVisibleConversation = _messages.any((message) {
        final identity = _visibleConversationIdentity(message);
        return identity != null &&
            !retainedVisibleIdentities.contains(identity);
      });
      if ((verifyPotentialUserGenerationReplacement &&
              _unconfirmedRetainedTranscriptIdentities.isEmpty) ||
          (!verifyPotentialUserGenerationReplacement &&
              foundVisibleConversation)) {
        return;
      }
    }
  }

  /// Carga bajo demanda hasta la siguiente ventana ANTERIOR que añade una
  /// unidad conversacional visible. Una página puede contener exclusivamente
  /// filas internas (tools/system); en ese caso un único gesto debe atravesarla
  /// porque la lista no cambia de geometría y no generará otro evento de scroll.
  Future<bool> loadEarlierMessages({bool continuePastInvisible = false}) async {
    if (!continuePastInvisible) return _loadEarlierMessagesPage();
    var visibleUnitCount = ChatRenderProjection.build(_messages).units.length;
    var loadedAnyPage = false;
    var remainingPages = _maxInitialBackfillPages;
    while (!_disposed && _earlierMessagesAvailable && remainingPages > 0) {
      final loaded = await _loadEarlierMessagesPage();
      if (!loaded) return loadedAnyPage;
      loadedAnyPage = true;
      remainingPages -= 1;
      final nextVisibleUnitCount = ChatRenderProjection.build(
        _messages,
      ).units.length;
      if (nextVisibleUnitCount > visibleUnitCount) return true;
      visibleUnitCount = nextVisibleUnitCount;
    }
    return loadedAnyPage;
  }

  /// Consume una página REST anterior. Una petición en vuelo por chat; un fallo
  /// no es fatal y el siguiente gesto puede reintentarlo.
  Future<bool> _loadEarlierMessagesPage() async {
    if (_disposed ||
        !_earlierMessagesAvailable ||
        _earlierMessagesInFlight) {
      return false;
    }
    _earlierMessagesInFlight = true;
    final loadEpoch = _messageLoadEpoch;
    final requestedTailHydration = _needsTranscriptTailHydration;
    final requestedNextOffset = _earlierMessagesNextOffset;
    final context = _captureSessionMessagesPageRead(
      consumer: _SessionMessagesPageConsumer.loadEarlier,
      loadEpoch: loadEpoch,
      profile: _storedSessionProfile,
      offset: requestedTailHydration ? 0 : requestedNextOffset,
      fenceCoverageState: true,
    );
    try {
      final page = await _fetchStoredMessagesPage(context);
      // Tail repair starts at REST offset zero; legacy REST can still return a
      // complete one-shot transcript without pagination metadata.
      final replacesTranscript =
          requestedTailHydration || !page.paginationProvided;
      var normalized = const <Map<String, dynamic>>[];
      var inflight = const <Map<String, dynamic>>[];
      var durableFallback = const <Map<String, dynamic>>[];
      List<Map<String, dynamic>>? mergedWithPage;
      _RefreshedTranscriptGraft? graft;
      final transition = _consumeSessionMessagesPageEvidence(
        page,
        context,
        projector: (pageProvesComplete) {
          normalized = _normalizedNewestFirst(page.messages);
          if (!replacesTranscript) {
            mergedWithPage = _mergeOlderPageBeforeUnconfirmedPrefix(
              _messages,
              normalized,
            );
            return _SessionMessagesPageProjection.publish(
              retainsExistingRows: true,
              confirmedRows: normalized,
            );
          }
          inflight = _messages
              .where(_preserveInflightOutsideHydrationGraft)
              .toList(growable: false);
          durableFallback = _messages
              .where(
                (message) => !_preserveInflightOutsideHydrationGraft(message),
              )
              .toList(growable: false);
          final candidate = _graftRefreshedTail(
            normalized,
            durableFallback,
            refreshedTranscriptComplete: pageProvesComplete,
          );
          graft = candidate;
          return _SessionMessagesPageProjection.fromGraft(
            normalized,
            candidate,
          );
        },
      );
      if (transition.action == _SessionMessagesPageAction.stale) {
        return false;
      }
      _earlierMessagesLoadFailed = false;
      if (transition.action == _SessionMessagesPageAction.retryTail ||
          transition.action == _SessionMessagesPageAction.throwExpectedCount) {
        return false;
      }

      if (replacesTranscript) {
        // Un snapshot omitido no aportó transcript. Esta lectura de offset 0
        // es la cola actual, no una página más antigua: reconcíliala con el
        // fallback conservado y solo después habilita el backfill normal.
        if (page.messages.isEmpty) {
          if (!transition.publishesProjection) return false;
          messagesLoaded = true;
          _emit(ActiveChatEvent.earlierMessagesLoaded);
          return true;
        }
        final acceptedGraft = graft;
        if (!transition.publishesProjection || acceptedGraft == null) {
          return false;
        }
        _captureArtifactMaps(page.messages, logicalSessionId: logicalSessionId);
        final hydrated = <Map<String, dynamic>>[
          ...inflight,
          ..._preserveLocalAssistantErrors(
            acceptedGraft.messages,
            durableFallback,
          ),
        ];
        final projected = _applyCancelledTurnTombstonesForDisplay(
          _associateGeneratedImagesNewestFirst(
            _pruneUnconfirmedRowsAtTranscriptStart(hydrated),
          ),
          incomingTranscriptComplete: _transcriptIsComplete,
        );
        _messages = projected;
        _mergeSteerRecords();
        _reconcileSubagentsFromTranscript();
        _emit(ActiveChatEvent.earlierMessagesLoaded);
        return true;
      }

      if (!transition.publishesProjection) return false;
      if (page.messages.isNotEmpty) {
        _captureArtifactMaps(page.messages, logicalSessionId: logicalSessionId);
      }
      var merged = _pruneUnconfirmedRowsAtTranscriptStart(
        mergedWithPage ?? _messages,
      );
      merged = _reconcileCoveredTerminalProjection(
        merged,
        candidateTranscriptComplete: _transcriptIsComplete,
      );
      final projectedMerged = _applyCancelledTurnTombstonesForDisplay(
        _associateGeneratedImagesNewestFirst(merged),
        incomingTranscriptComplete: _transcriptIsComplete,
      );
      final changed = !_sameTranscriptProjection(projectedMerged, _messages);
      if (!changed && page.messages.isEmpty) return false;
      if (changed) _messages = projectedMerged;
      if (changed || page.messages.isNotEmpty) {
        _mergeSteerRecords();
        _reconcileSubagentsFromTranscript();
        _emit(ActiveChatEvent.earlierMessagesLoaded);
        return true;
      }
      return false;
    } catch (error) {
      if (!_sessionMessagesPageReadIsFresh(context)) return false;
      debugPrint(
        '[active-chat] earlier transcript page unavailable '
        '(${error.runtimeType})',
      );
      _earlierMessagesLoadFailed = true;
      _emit(ActiveChatEvent.earlierMessagesLoaded);
      return false;
    } finally {
      _earlierMessagesInFlight = false;
    }
  }

  /// Espera el desenlace de una hidratación diferida del historial
  /// (`session.resume_progress`), con un tope para no colgar la apertura del
  /// chat si el evento nunca llega.
  Future<bool> _awaitDesktopHistoryHydration() {
    final recorded = _desktopHydrationOutcome;
    if (recorded != null) return Future.value(recorded);
    final waiter = Completer<bool>();
    _desktopHydrationWaiter = waiter;
    return waiter.future
        .timeout(const Duration(seconds: 30), onTimeout: () => false)
        .whenComplete(() {
          if (identical(_desktopHydrationWaiter, waiter)) {
            _desktopHydrationWaiter = null;
          }
        });
  }

  void _handleDesktopResumeProgress(Map<String, dynamic> payload) {
    final status = (payload['status'] ?? '').toString().trim().toLowerCase();
    final announced = _terminalProjectionInt(payload['message_count']);
    if (status == 'complete' && announced != null && announced >= 0) {
      // Este evento es posterior al ack de resume y puede anunciar una
      // compactación 300→2. Sustituye la expectativa vieja; usar max dejaría
      // offset=0 en reintento eterno aunque la cola nueva ya esté completa.
      _desktopHydrationExpectedMessageCount = announced > 0 ? announced : null;
    } else if (announced != null && announced > 0) {
      _desktopHydrationExpectedMessageCount = math.max(
        _desktopHydrationExpectedMessageCount ?? 0,
        announced,
      );
    }
    switch (status) {
      case 'loading':
        _desktopHistoryHydrating = true;
        _desktopHydrationOutcome = null;
      case 'complete':
        _desktopHistoryHydrating = false;
        _desktopHydrationOutcome = true;
        final waiter = _desktopHydrationWaiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete(true);
        // Si loadMessages ya no está esperando y REST no había pintado nada,
        // el historial ya está listo server-side: recupéralo ahora.
        if (waiter == null && _desktopHistoryNeedsHydration && !_disposed) {
          _scheduleDeferredDesktopHistoryHydration();
        }
      case 'failed':
        _desktopHistoryHydrating = false;
        _desktopHistoryNeedsHydration = false;
        _desktopHydrationOutcome = false;
        final waiter = _desktopHydrationWaiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete(false);
    }
  }

  void _scheduleDeferredDesktopHistoryHydration() {
    final loadEpoch = _messageLoadEpoch;
    if (_disposed ||
        !_desktopHistoryNeedsHydration ||
        (_desktopHistoryHydrationFlight != null &&
            _desktopHistoryHydrationFlightEpoch == loadEpoch)) {
      return;
    }
    late final Future<void> flight;
    flight = _hydrateDeferredDesktopHistory().whenComplete(() {
      if (identical(_desktopHistoryHydrationFlight, flight)) {
        _desktopHistoryHydrationFlight = null;
        _desktopHistoryHydrationFlightEpoch = null;
      }
    });
    _desktopHistoryHydrationFlight = flight;
    _desktopHistoryHydrationFlightEpoch = loadEpoch;
    unawaited(flight);
  }

  Future<void> _hydrateDeferredDesktopHistory() async {
    final loadEpoch = _messageLoadEpoch;
    final context = _captureSessionMessagesPageRead(
      consumer: _SessionMessagesPageConsumer.scheduledHydration,
      loadEpoch: loadEpoch,
      profile: _storedSessionProfile,
      fenceCoverageState: true,
    );
    try {
      final page = await _fetchStoredMessagesPage(context);
      var normalized = const <Map<String, dynamic>>[];
      var inflight = const <Map<String, dynamic>>[];
      var durableFallback = const <Map<String, dynamic>>[];
      _RefreshedTranscriptGraft? graft;
      final transition = _consumeSessionMessagesPageEvidence(
        page,
        context,
        projector: (pageProvesComplete) {
          normalized = _normalizedNewestFirst(page.messages);
          inflight = _messages
              .where(_preserveInflightOutsideHydrationGraft)
              .toList(growable: false);
          durableFallback = _messages
              .where(
                (message) => !_preserveInflightOutsideHydrationGraft(message),
              )
              .toList(growable: false);
          final candidate = _graftRefreshedTail(
            normalized,
            durableFallback,
            refreshedTranscriptComplete: pageProvesComplete,
          );
          graft = candidate;
          return _SessionMessagesPageProjection.fromGraft(
            normalized,
            candidate,
          );
        },
      );
      if (transition.action == _SessionMessagesPageAction.stale ||
          transition.action == _SessionMessagesPageAction.retryTail ||
          transition.action == _SessionMessagesPageAction.throwExpectedCount) {
        return;
      }
      if (page.messages.isEmpty) {
        if (!transition.publishesProjection) return;
        messagesLoaded = true;
        _emit(ActiveChatEvent.messagesHydrated);
        return;
      }
      final acceptedGraft = graft;
      if (!transition.publishesProjection || acceptedGraft == null) return;
      _captureArtifactMaps(page.messages, logicalSessionId: logicalSessionId);
      final hydrated = <Map<String, dynamic>>[
        ...inflight,
        ..._preserveLocalAssistantErrors(
          acceptedGraft.messages,
          durableFallback,
        ),
      ];
      _messages = _applyCancelledTurnTombstonesForDisplay(
        _associateGeneratedImagesNewestFirst(hydrated),
        incomingTranscriptComplete: _transcriptIsComplete,
      );
      _mergeSteerRecords();
      _reconcileSubagentsFromTranscript();
      messagesLoaded = true;
      _emit(ActiveChatEvent.messagesHydrated);
    } catch (error) {
      debugPrint(
        '[active-chat] deferred history hydration failed '
        '(${error.runtimeType})',
      );
    }
  }

  DesktopSessionSnapshot _withoutPersistedMessages(
    DesktopSessionSnapshot snapshot,
  ) => snapshot.withoutPersistedMessages();

  DesktopSessionSnapshot _withoutLiveDesktopProjection(
    DesktopSessionSnapshot snapshot,
  ) => DesktopSessionSnapshot(
    runtimeSessionId: snapshot.runtimeSessionId,
    storedSessionId: snapshot.storedSessionId,
    storedSessionIdProvenance: snapshot.storedSessionIdProvenance,
    created: snapshot.created,
    lineageRootId: snapshot.lineageRootId,
    identityAliasesConsistent: snapshot.identityAliasesConsistent,
    storedSessionIdentityExplicit: snapshot.storedSessionIdentityExplicit,
    messages: snapshot.messages,
    messagesProvided: snapshot.messagesProvided,
    messagesFullyParsed: snapshot.messagesFullyParsed,
    messageCount: snapshot.messageCount,
    hydrating: snapshot.hydrating,
    running: false,
    status: snapshot.status,
    startedAt: snapshot.startedAt,
    turnStartedAt: snapshot.turnStartedAt,
    info: snapshot.info,
    pendingClarify: snapshot.pendingClarify,
    pendingClarifyProvided: snapshot.pendingClarifyProvided,
    raw: snapshot.raw,
  );

  List<Map<String, dynamic>> _preserveLocalAssistantErrors(
    List<Map<String, dynamic>> next,
    List<Map<String, dynamic>> current,
  ) {
    const projectionIdKey = '_localTranscriptProjectionId';
    const pairIdKey = '_localTranscriptPairId';
    final currentProjectionIds =
        HashMap<Map<String, dynamic>, String>.identity();
    for (final message in current) {
      if (message['role'] != 'assistant_error') continue;
      final existingId = message[projectionIdKey];
      currentProjectionIds[message] =
          existingId is String && existingId.isNotEmpty
          ? existingId
          : _nextLocalTranscriptProjectionId();
    }
    final normalizedNext = List<Map<String, dynamic>>.of(next);
    final existing = <String>{};
    for (var index = 0; index < normalizedNext.length; index++) {
      final message = normalizedNext[index];
      if (message['role'] != 'assistant_error') continue;
      final rawId = message[projectionIdKey];
      final projectionId = rawId is String && rawId.isNotEmpty
          ? rawId
          : currentProjectionIds[message] ?? _nextLocalTranscriptProjectionId();
      existing.add(projectionId);
      if (rawId != projectionId) {
        normalizedNext[index] = {...message, projectionIdKey: projectionId};
      }
    }
    final existingUserIdentities = <TranscriptMessageIdentity>[
      for (final message in normalizedNext)
        if (isRealUserTurn(message)) ?_transcriptMessageIdentity(message),
    ];
    final existingPairIds = <String>{
      for (final message in normalizedNext)
        if (message[pairIdKey] case final String pairId)
          if (pairId.isNotEmpty) pairId,
    };
    final preserved = <Map<String, dynamic>>[];
    for (var index = 0; index < current.length; index++) {
      final message = current[index];
      if (message['role'] != 'assistant_error') continue;
      final projectionId = currentProjectionIds[message]!;
      if (existing.add(projectionId)) {
        preserved.add({...message, projectionIdKey: projectionId});
        final legacyPartial = message[_legacyRecoveryPartialProjectionKey];
        if (message[_awaitingDurableTurnRecoveryKey] == true &&
            legacyPartial is Map<String, dynamic>) {
          preserved.add(Map<String, dynamic>.from(legacyPartial));
        }
        final prompt = (message['_prompt'] ?? '').toString();
        if (prompt.isEmpty) continue;
        for (
          var candidate = index + 1;
          candidate < current.length;
          candidate++
        ) {
          final paired = current[candidate];
          if (!isRealUserTurn(paired)) continue;
          if ((paired['content'] ?? '').toString() != prompt) break;
          final pairedIdentity = _transcriptMessageIdentity(paired);
          if (pairedIdentity != null &&
              _identityCollectionContains(
                existingUserIdentities,
                pairedIdentity,
              )) {
            break;
          }
          final pairId = paired[pairIdKey];
          if (pairId is String && existingPairIds.contains(pairId)) break;
          if (normalizedNext.any((item) => identical(item, paired))) break;
          preserved.add({...paired, pairIdKey: projectionId});
          existingPairIds.add(projectionId);
          if (pairedIdentity != null) {
            existingUserIdentities.add(pairedIdentity);
          }
          break;
        }
      }
    }
    if (preserved.isEmpty) return normalizedNext;
    return <Map<String, dynamic>>[...preserved, ...normalizedNext];
  }

  String _nextLocalTranscriptProjectionId() =>
      'local-assistant-error-${++_localTranscriptProjectionSerial}';

  void _ensureLocalAssistantErrorIdentities() {
    const projectionIdKey = '_localTranscriptProjectionId';
    const pairIdKey = '_localTranscriptPairId';
    for (var index = 0; index < _messages.length; index++) {
      final error = _messages[index];
      if (error['role'] != 'assistant_error') continue;
      final rawProjectionId = error[projectionIdKey];
      final projectionId =
          rawProjectionId is String && rawProjectionId.isNotEmpty
          ? rawProjectionId
          : _nextLocalTranscriptProjectionId();
      if (rawProjectionId != projectionId) {
        _messages[index] = {...error, projectionIdKey: projectionId};
      }
      final prompt = (error['_prompt'] ?? '').toString();
      if (prompt.isEmpty) continue;
      for (
        var candidate = index + 1;
        candidate < _messages.length;
        candidate++
      ) {
        final user = _messages[candidate];
        if (!isRealUserTurn(user)) continue;
        if ((user['content'] ?? '').toString() != prompt) break;
        if (user[pairIdKey] != projectionId) {
          _messages[candidate] = {...user, pairIdKey: projectionId};
        }
        break;
      }
    }
  }

  void _tagLatestUserForLocalError(String projectionId) {
    for (var index = 0; index < _messages.length; index++) {
      if (!isRealUserTurn(_messages[index])) continue;
      _messages[index] = {
        ..._messages[index],
        '_localTranscriptPairId': projectionId,
      };
      return;
    }
  }

  void _mergeSteerRecords() {
    if (_steerRecords.isEmpty || _messages.isEmpty) return;
    final anchors = <int, List<String>>{};
    final authoritativeCorrectionCounts = <String, int>{};
    var latestUserOrdinal = -1;
    for (final message in _messages.reversed) {
      if (isRealUserTurn(message)) latestUserOrdinal++;
    }
    for (final message in _messages) {
      final key = message['_desktopSnapshotKey']?.toString() ?? '';
      final isInflightCorrection =
          message['_desktopSnapshotKind'] == 'inflight' &&
          key.startsWith('user-inflight-correction-');
      if (!isInflightCorrection) continue;
      final content = message['content']?.toString() ?? '';
      authoritativeCorrectionCounts.update(
        content,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    for (final record in _steerRecords) {
      final authoritativeCount =
          authoritativeCorrectionCounts[record.content] ?? 0;
      if (authoritativeCount > 0 &&
          record.anchorUserOrdinal == latestUserOrdinal) {
        authoritativeCorrectionCounts[record.content] = authoritativeCount - 1;
        continue;
      }
      anchors
          .putIfAbsent(record.anchorUserOrdinal, () => [])
          .add(record.content);
    }
    final userIndexesOldestFirst = <int>[];
    for (var index = _messages.length - 1; index >= 0; index--) {
      if (isRealUserTurn(_messages[index])) {
        userIndexesOldestFirst.add(index);
      }
    }
    final ordinals = anchors.keys.toList()..sort();
    for (final ordinal in ordinals) {
      if (ordinal < 0 || ordinal >= userIndexesOldestFirst.length) continue;
      final userIndex = userIndexesOldestFirst[ordinal];
      var steerRunStart = userIndex;
      while (steerRunStart > 0 &&
          _messages[steerRunStart - 1]['_steer'] == true) {
        steerRunStart--;
      }
      final existingChronological = _messages
          .sublist(steerRunStart, userIndex)
          .reversed
          .toList(growable: false);
      final unusedExisting = List<bool>.filled(
        existingChronological.length,
        true,
      );
      final mergedChronological = <Map<String, dynamic>>[];
      for (final content in anchors[ordinal]!) {
        var matchingIndex = -1;
        for (var index = 0; index < existingChronological.length; index++) {
          if (unusedExisting[index] &&
              existingChronological[index]['content'] == content) {
            matchingIndex = index;
            break;
          }
        }
        if (matchingIndex >= 0) {
          unusedExisting[matchingIndex] = false;
          mergedChronological.add(existingChronological[matchingIndex]);
        } else {
          mergedChronological.add({
            'role': 'user',
            'content': content,
            '_steer': true,
          });
        }
      }
      for (var index = 0; index < existingChronological.length; index++) {
        if (unusedExisting[index]) {
          mergedChronological.add(existingChronological[index]);
        }
      }

      // Lista viva = más nuevo primero. Reconstruir el bloque completo evita
      // duplicar una corrección que ya llegó desde inflight.corrections.
      _messages
        ..removeRange(steerRunStart, userIndex)
        ..insertAll(steerRunStart, mergedChronological.reversed);
    }
  }

  /// Persiste el transcript de un chat LOCAL (bridge) para que sobreviva al
  /// cierre de la pantalla. No-op en instancias remotas (el gateway ya guarda
  /// el historial server-side). Los fallos de storage son best-effort; una
  /// revocación del lifecycle sí aborta el turno antes del transporte.
  Future<void> _persistLocalTranscript(
    LocalConversationLifecycle? capturedLifecycle, [
    LocalConversationOperation? transcriptOperation,
  ]) async {
    if (connection.kind != InstanceKind.localhost) return;
    try {
      if (transcriptOperation != null) {
        LocalConversationCleanupFence.ensureOperationAllowed(
          transcriptOperation,
        );
      }
      final operationId = transcriptOperation?.operationId;
      bool belongsToSnapshot(Map<String, dynamic> message) {
        final producerId = message['_localOperationId'];
        if (producerId == null) return true;
        final producer = _localTranscriptOperations[producerId];
        if (producer == null) return false;
        if (_confirmedLocalTranscriptOperations.contains(producerId)) {
          return LocalConversationCleanupFence.confirmedProjectionSurvivesCleanup(
            producer,
          );
        }
        try {
          LocalConversationCleanupFence.ensureOperationAllowed(producer);
        } on LocalConversationWriteRejected {
          return false;
        }
        return producerId == operationId;
      }

      final snapshot = _messages
          .where(belongsToSnapshot)
          .map((message) => Map<String, dynamic>.from(message))
          .toList(growable: false);
      final stored = await LocalTranscriptStore.saveFromNewestFirst(
        connection.id,
        sessionId,
        snapshot,
        profile: _storedSessionProfile,
        lifecycle: capturedLifecycle,
      );
      if (operationId != null) {
        _confirmedLocalTranscriptOperations.add(operationId);
      }
      if (!_disposed &&
          stored.olderHistoryTruncated &&
          !_localTranscriptOlderHistoryTruncated) {
        _recordLocalTranscriptCoverage(stored);
        _emit(ActiveChatEvent.messagesHydrated);
      }
    } on LocalConversationWriteRejected {
      final operationId = transcriptOperation?.operationId;
      if (operationId != null) {
        _messages.removeWhere(
          (message) => message['_localOperationId'] == operationId,
        );
        _emit(ActiveChatEvent.messagesHydrated);
      }
      rethrow;
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[active-chat] local transcript persistence unavailable '
          '(${error.runtimeType})',
        );
      }
    }
  }

  bool get _hasUnanchoredCancelledUser => _messages.any(
    (message) =>
        isRealUserTurn(message) &&
        message['_cancelledUser'] == true &&
        message['_cancelledTurnFirstUser'] != true &&
        canonicalTranscriptMessageId(message) == null &&
        canonicalTranscriptRowId(message) == null,
  );

  /// A second optimistic turn must never start behind a cancelled user that
  /// still has no server identity: Stop could not anchor the new tombstone
  /// without crossing that ambiguous row. Refresh the complete transcript
  /// first and publish it only if every such row is now durably identified.
  Future<bool> _hydrateCancelledUserAnchorsBeforeSend() async {
    if (_onCancelledTurn == null) return true;
    if (!_hasUnanchoredCancelledUser) return true;
    final target = _latestUserCancellationCandidate();
    if (target == null) return false;
    final localTarget = _messages[target.index];
    if (localTarget['_cancelledUser'] != true ||
        canonicalTranscriptMessageId(localTarget) != null ||
        canonicalTranscriptRowId(localTarget) != null) {
      return false;
    }
    final loadEpoch = _messageLoadEpoch;
    final context = _captureSessionMessagesPageRead(
      consumer: _SessionMessagesPageConsumer.cancelledAnchorRepair,
      loadEpoch: loadEpoch,
      profile: _storedSessionProfile,
      fenceCoverageState: true,
    );
    try {
      final page = await _fetchStoredMessagesPage(context);
      var projected = const <Map<String, dynamic>>[];
      _RefreshedTranscriptGraft? graft;
      final transition = _consumeSessionMessagesPageEvidence(
        page,
        context,
        projector: (pageProvesComplete) {
          final normalized = _normalizedNewestFirst(page.messages);
          final hydratedTargetIndex = _cancelledTurnUserIndex(
            normalized,
            target.tombstone,
            incomingTranscriptComplete: pageProvesComplete,
          );
          if (hydratedTargetIndex < 0 ||
              (canonicalTranscriptMessageId(normalized[hydratedTargetIndex]) ==
                      null &&
                  canonicalTranscriptRowId(normalized[hydratedTargetIndex]) ==
                      null)) {
            return _SessionMessagesPageProjection.reject(
              refreshedNewestFirst: normalized,
            );
          }
          projected = _applyCancelledTurnTombstones(
            _associateGeneratedImagesNewestFirst(normalized),
            incomingTranscriptComplete: pageProvesComplete,
          );
          final candidate = _graftRefreshedTail(
            projected,
            _messages,
            refreshedTranscriptComplete: pageProvesComplete,
          );
          graft = candidate;
          return _SessionMessagesPageProjection.fromGraft(projected, candidate);
        },
      );
      final acceptedGraft = graft;
      if (!transition.publishesProjection || acceptedGraft == null) {
        return false;
      }

      _captureArtifactMaps(page.messages, logicalSessionId: logicalSessionId);
      final anchored = acceptedGraft.messages
          .where((message) => !identical(message, localTarget))
          .toList();
      _messages = _projectTranscriptForInternalState(
        _preserveLocalAssistantErrors(anchored, _messages),
      );
      _mergeSteerRecords();
      _reconcileSubagentsFromTranscript();
      messagesLoaded = true;
      _emit(ActiveChatEvent.messagesHydrated);
      return !_hasUnanchoredCancelledUser;
    } catch (error) {
      debugPrint(
        '[active-chat] cancelled turn identity unavailable '
        '(${error.runtimeType})',
      );
      return false;
    }
  }

  /// Lanza el envío con streaming. Inserta los mensajes optimistas y arranca el
  /// SSE en este servicio (no en el widget), de modo que continúa al navegar.
  Future<bool> send({
    bool mentionsFrozen = false,
    required String fullText,
    required String model,
    required List<Map<String, dynamic>> history,
    String profile = '',
    String? serverSessionId,
    List<AttachmentDraft> nativeAttachments = const [],
    String? desktopText,
    bool voicePlaybackInterrupted = false,
    bool queued = false,
    int? truncateBeforeUserOrdinal,
    ActiveTurnDelivery? delivery,
    DesktopSessionCreateConfig sessionConfig =
        const DesktopSessionCreateConfig(),
    bool? allowTransportFallbackOverride,
    Future<void> Function(String storedSessionId)? beforeDesktopPromptSubmit,
  }) {
    if (delivery != null) {
      final turn = delivery.current;
      // Unannotated legacy callers retain their separate prompt contract.
      if (turn.mentionAnnotation.isNotEmpty) {
        model = turn.model;
        profile = turn.profile;
        nativeAttachments = turn.activeAttachments;
        fullText = appendBotMentionNote(turn.fullText, turn.mentionAnnotation);
        desktopText = turn.desktopText == null
            ? null
            : appendBotMentionNote(turn.desktopText!, turn.mentionAnnotation);
      }
    } else if (!mentionsFrozen) {
      final annotation = buildBotMentionAnnotation(
        mentionResolver.resolve(fullText),
      );
      fullText = appendBotMentionNote(fullText, annotation);
      if (desktopText != null) {
        desktopText = appendBotMentionNote(desktopText, annotation);
      }
    }
    final pendingManualProbeClientTurnId =
        _pendingManualOwnershipProbeClientTurnId;
    final manualOwnershipProbe =
        _ownershipMutationAdmission ==
            _OwnershipMutationAdmission.pendingManualProbe &&
        pendingManualProbeClientTurnId != null &&
        delivery?.current.clientTurnId == pendingManualProbeClientTurnId;
    if (_runtimeReleaseInFlight ||
        (_ownershipMutationAdmission != _OwnershipMutationAdmission.open &&
            !manualOwnershipProbe)) {
      return Future<bool>.value(false);
    }
    // A fresh send is an explicit user gesture: unlike terminal callbacks, it
    // may reopen the FIFO that Stop parked. Do this synchronously before the
    // new turn starts so follow-ups admitted during that turn can drain.
    if (_queueLease == QueueLease.parked && !_disposed) {
      final stop = _stopTransition;
      // `confirmed` no es el único estado terminal: `failed` y `superseded`
      // también dejan al coordinador sin nada que gobernar. Sólo un Stop aún
      // vivo justifica esperar su ACK, y esa espera es acotada.
      if (stop != null && !stop.isFinal) {
        return _sendAfterStopSettles(
          fullText: fullText,
          model: model,
          history: history,
          profile: profile,
          serverSessionId: serverSessionId,
          nativeAttachments: nativeAttachments,
          desktopText: desktopText,
          voicePlaybackInterrupted: voicePlaybackInterrupted,
          queued: queued,
          truncateBeforeUserOrdinal: truncateBeforeUserOrdinal,
          delivery: delivery,
          sessionConfig: sessionConfig,
          allowTransportFallbackOverride: allowTransportFallbackOverride,
          beforeDesktopPromptSubmit: beforeDesktopPromptSubmit,
        );
      }
      _unparkQueueLease();
    }
    final transcriptLifecycle = _localConversationLifecycle;
    LocalConversationOperation? transcriptOperation;
    if (connection.kind == InstanceKind.localhost) {
      try {
        transcriptOperation = LocalConversationCleanupFence.admitOperation(
          connectionId: connection.id,
          profile:
              transcriptLifecycle?.profile ??
              (profile.isEmpty ? _storedSessionProfile : profile),
          sessionId: sessionId,
          lifecycle: transcriptLifecycle,
          kind: LocalConversationOperationKind.projection,
        );
        _localTranscriptOperations[transcriptOperation.operationId] =
            transcriptOperation;
      } catch (error, stackTrace) {
        return Future<bool>.error(error, stackTrace);
      }
    }
    if (_queueAdmissionFrozen) {
      if (!_disposed &&
          _preparedTurnOwners.isEmpty &&
          _reusableQueueStopGeneration == _queueGeneration) {
        _queueAdmissionFrozen = false;
        _queueDrainSuspended = false;
        _reusableQueueStopGeneration = null;
      } else {
        return Future<bool>.value(false);
      }
    }
    if (manualOwnershipProbe) {
      _ownershipMutationAdmission =
          _OwnershipMutationAdmission.manualProbeInFlight;
      _emit(ActiveChatEvent.sessionInfo);
    }
    final attempt = _send(
      fullText: fullText,
      model: model,
      history: history,
      profile: profile,
      serverSessionId: serverSessionId,
      nativeAttachments: nativeAttachments,
      desktopText: desktopText,
      voicePlaybackInterrupted: voicePlaybackInterrupted,
      queued: queued,
      truncateBeforeUserOrdinal: truncateBeforeUserOrdinal,
      delivery: delivery,
      sessionConfig: sessionConfig,
      allowTransportFallbackOverride: allowTransportFallbackOverride,
      beforeDesktopPromptSubmit: beforeDesktopPromptSubmit,
      capturedLifecycle: transcriptLifecycle,
      transcriptOperation: transcriptOperation,
    );
    return manualOwnershipProbe
        ? _settleManualOwnershipProbe(attempt)
        : attempt;
  }

  /// Espera acotada al ACK de interrupción antes de readmitir un envío que el
  /// usuario pidió con la cola estacionada.
  ///
  /// Conserva la espera legítima (reabrir la FIFO antes del ACK podría colar un
  /// seguimiento por delante del interrupt), pero nunca de forma indefinida:
  /// los gateways antiguos pueden no publicar terminal de interrupción — el
  /// mismo caso que `rewrite()` ya contempla. Agotado el plazo se levanta el
  /// park igual, porque en Desktop el park jamás bloquea la admisión.
  Future<bool> _sendAfterStopSettles({
    required String fullText,
    required String model,
    required List<Map<String, dynamic>> history,
    required String profile,
    required String? serverSessionId,
    required List<AttachmentDraft> nativeAttachments,
    required String? desktopText,
    required bool voicePlaybackInterrupted,
    required bool queued,
    required int? truncateBeforeUserOrdinal,
    required ActiveTurnDelivery? delivery,
    required DesktopSessionCreateConfig sessionConfig,
    required bool? allowTransportFallbackOverride,
    required Future<void> Function(String storedSessionId)?
    beforeDesktopPromptSubmit,
  }) async {
    // Reabrir aquí — y no en la reentrada — es lo que garantiza que `send` no
    // pueda volver a caer en esta misma rama con el mismo coordinador.
    await _admitThroughParkedQueue();
    if (_disposed) return false;
    return send(
      mentionsFrozen: true,
      fullText: fullText,
      model: model,
      history: history,
      profile: profile,
      serverSessionId: serverSessionId,
      nativeAttachments: nativeAttachments,
      desktopText: desktopText,
      voicePlaybackInterrupted: voicePlaybackInterrupted,
      queued: queued,
      truncateBeforeUserOrdinal: truncateBeforeUserOrdinal,
      delivery: delivery,
      sessionConfig: sessionConfig,
      allowTransportFallbackOverride: allowTransportFallbackOverride,
      beforeDesktopPromptSubmit: beforeDesktopPromptSubmit,
    );
  }

  Future<bool> _settleManualOwnershipProbe(Future<bool> attempt) async {
    try {
      final accepted = await attempt;
      if (_ownershipMutationAdmission ==
          _OwnershipMutationAdmission.manualProbeInFlight) {
        _ownershipMutationAdmission = accepted
            ? _OwnershipMutationAdmission.open
            : _OwnershipMutationAdmission.conflictReadOnly;
        if (accepted) {
          _pendingManualOwnershipProbeClientTurnId = null;
        } else {
          _ownershipConflictGeneration += 1;
        }
        _queueDrainSuspended = !accepted;
        if (!_disposed) {
          _emit(ActiveChatEvent.sessionInfo);
          if (accepted && !isStreaming) unawaited(_drainQueue());
        }
      }
      return accepted;
    } catch (_) {
      if (_ownershipMutationAdmission ==
          _OwnershipMutationAdmission.manualProbeInFlight) {
        _ownershipMutationAdmission =
            _OwnershipMutationAdmission.conflictReadOnly;
        _queueDrainSuspended = true;
        _ownershipConflictGeneration += 1;
        if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
      }
      rethrow;
    }
  }

  Future<bool> _send({
    required String fullText,
    required String model,
    required List<Map<String, dynamic>> history,
    String profile = '',
    String? serverSessionId,
    List<AttachmentDraft> nativeAttachments = const [],
    String? desktopText,
    bool voicePlaybackInterrupted = false,
    bool queued = false,
    int? truncateBeforeUserOrdinal,
    int? truncateBeforeRowId,
    ActiveTurnDelivery? delivery,
    DesktopSessionCreateConfig sessionConfig =
        const DesktopSessionCreateConfig(),
    bool? allowTransportFallbackOverride,
    Future<void> Function(String storedSessionId)? beforeDesktopPromptSubmit,
    _RewriteReservation? rewriteReservation,
    Map<String, dynamic>? reusedOptimisticUserRow,
    required LocalConversationLifecycle? capturedLifecycle,
    LocalConversationOperation? transcriptOperation,
  }) async {
    final baseSessionConfig = sessionConfig.isEmpty
        ? _stagedFirstSubmitConfig
        : sessionConfig;
    final capturedSessionConfig = allowTransportFallbackOverride == null
        ? baseSessionConfig
        : DesktopSessionCreateConfig(
            model: baseSessionConfig.model,
            reasoningEffort: baseSessionConfig.reasoningEffort,
            fastMode: baseSessionConfig.fastMode,
            title: baseSessionConfig.title,
            hidden: baseSessionConfig.hidden,
            createIfMissing: baseSessionConfig.createIfMissing,
            allowTransportFallback: allowTransportFallbackOverride,
          );
    final queueAdmissionToken = Object();
    _queueAdmissionToken = queueAdmissionToken;
    _queueAdmissionAllowTransportFallback =
        capturedSessionConfig.allowTransportFallback;
    late final int turnEpoch;
    try {
      if (await _hasUnresolvedDurableCompressionFence()) {
        throw const TuiGatewayRpcError(
          'prompt.submit',
          'Session compression requires authoritative reconciliation',
          code: 4009,
        );
      }
      if (_disposed) return false;
      try {
        await _flushPendingCancelledTombstoneUpdates();
      } catch (_) {
        await delivery?.markUnaccepted();
        return false;
      }
      final pendingStop = _durableCancelFlight;
      if (pendingStop != null) {
        await pendingStop;
        if (_disposed) return false;
      }
      // Intento de reparación, nunca una valla de admisión. Si el servidor aún
      // no publica la fila durable del turno detenido, Desktop sigue enviando:
      // el park y el tombstone son asunto de Stop, no del composer. Bloquear
      // aquí convertía un Stop correcto en una sesión inutilizable para
      // siempre — el mismo envío, la cola y la edición quedaban rechazados en
      // silencio. La ambigüedad que esto protegía sigue cerrada donde
      // corresponde: `_latestUserCancellationCandidate` se niega a cruzar una
      // fila de usuario sin identidad, así que un Stop posterior falla de forma
      // visible y reintentable en vez de secuestrar la sesión entera.
      if (!await _hydrateCancelledUserAnchorsBeforeSend()) {
        debugPrint(
          '[active-chat] stopped turn still lacks a durable transcript row; '
          'sending anyway (a later Stop stays fail-closed)',
        );
      }
      if (desktopCompressionInFlight) {
        throw const TuiGatewayRpcError(
          'prompt.submit',
          'Session compression is still running',
          code: 4009,
        );
      }
      final reservedRewrite = _activeRewrite;
      if (reservedRewrite != null &&
          !identical(reservedRewrite, rewriteReservation) &&
          reservedRewrite.transportStarted) {
        return false;
      }
      if (rewriteReservation != null) {
        if (!identical(reservedRewrite, rewriteReservation)) return false;
        rewriteReservation.transportStarted = true;
      }
      if (transcriptOperation != null) {
        LocalConversationCleanupFence.ensureOperationAllowed(
          transcriptOperation,
        );
      }
      _finishVoiceBargeHandoff(notifyTerminal: false);
      _beginObservedResponseTiming();
      if (truncateBeforeUserOrdinal == null) {
        _rewindRollbackMessages = null;
        _rewindRollbackState = null;
        _rewind4018FallbackOrdinal = null;
        _rewindRestoredOnError = false;
      }
      _desktopTerminalRequiresLifecycleEvidence =
          _runTerminal && _desktopRuntimeSessionId != null;
      turnEpoch = _advanceTurnEpoch();
      _turnSubmittedAtMs = _wallClockMs();
      _setNoActivityHint(false);
      // Una hidratación iniciada al abrir la ruta nunca puede aterrizar después
      // del primer submit y sustituir el turno optimista recién insertado.
      _messageLoadEpoch += 1;
      final sessionProfile = _bindSessionProfile(profile);
      _storedSessionProfile = sessionProfile;
      _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
      _activeTurnDelivery = delivery;
      lastPrompt = stripBotMentionNote(fullText);
      _lastModel = model;
      _turnProfile = sessionProfile;
      _turnSessionConfig = capturedSessionConfig;
      // Sesión server-side a usar para este turno (y los reintentos/cola de este
      // turno). Si es null se usa la propia [sessionId] del chat. El modo voz pasa
      // su sesión rotable aquí: así puede empezar de cero tras cancelar sin tocar
      // la identidad del ActiveChat. El contexto se conserva porque el historial
      // completo viaja en cada turno (no depende de la sesión del servidor).
      // El modo voz puede rotar deliberadamente su sesión server-side. Solo una
      // rotación real invalida el binding Desktop anterior; los turnos normales
      // (override null → null) conservan el id canónico obtenido por resume.
      final serverSessionScopeChanged =
          serverSessionId != _serverSessionOverride;
      if (serverSessionScopeChanged) {
        _retireDesktopRuntime();
        _desktopStoredSessionId = null;
        _usingDesktopGateway = false;
      }
      _serverSessionOverride = serverSessionId;
      _captureActiveTurnTranscriptBoundary(
        turnEpoch,
        allowExistingTranscript: !serverSessionScopeChanged,
      );
      state = ChatPipelineState.connecting;
    } finally {
      if (identical(_queueAdmissionToken, queueAdmissionToken)) {
        _queueAdmissionToken = null;
        _queueAdmissionAllowTransportFallback = null;
      }
    }
    trace.clear();
    _activeVoiceTools.clear();
    traceActive = true;
    pendingApproval = null;
    _pendingDesktopInterimKey = null;
    _assistantNarration.reset();
    _assistantRawStream.clear();
    _assistantPublicStream = '';
    currentRunId = null;
    _terminalTimer?.cancel();
    _terminalTimer = null;
    _runTerminal = false;
    _stopConfirmationState = StopConfirmationState.idle;
    _lastStopAffectedLiveTurn = true;
    _backgroundStopVerificationInFlight = false;
    _backgroundStopRemainingTasks = null;
    _desktopTurnStartedAt = null;
    final hasLiveSubagent =
        _subagentActivities?.activities.any(
          (activity) => !activity.isTerminal,
        ) ??
        false;
    if (!hasLiveSubagent) {
      _rememberRetiredSubagentTerminals(_subagentActivities);
      _subagentActivities = null;
      _subagentTranscriptTurnAnchor = null;
    }
    // Un terminal sin texto o una reconciliación tardía no puede arrastrar el
    // placeholder del turno anterior al nuevo timeline.
    _settlePipelinePlaceholders();
    // Un rewind ya dejó la misma fila user en su slot. Los envíos normales sí
    // crean una fila optimista nueva.
    if (reusedOptimisticUserRow == null) {
      _messages.insert(0, {
        'role': 'user',
        'content': fullText,
        '_optimistic': true,
        if (transcriptOperation != null)
          '_localOperationId': transcriptOperation.operationId,
      });
    }
    // Burbuja placeholder del asistente con el estado del pipeline.
    _messages.insert(0, {
      'role': 'assistant',
      'content': '',
      '_pipeline': true,
      if (transcriptOperation != null)
        '_localOperationId': transcriptOperation.operationId,
    });
    _emit(ActiveChatEvent.started);
    if (rewriteReservation != null) {
      rewriteReservation.transcriptRevision = _transcriptRevision;
    }

    if (!capturedSessionConfig.allowTransportFallback &&
        _desktopGateway is! HermesDesktopSessionLifecycleGateway) {
      _failRun('Hermes Desktop session lifecycle is required');
      return _finishTurnDelivery(delivery, false, turnEpoch);
    }

    // Perfil activo (no-default): routing por capacidad, AISLADO en su propio
    // método para NO tocar el camino default. Local → aislamiento completo vía
    // bridge (`hermes --profile`); remoto → personalidad (SOUL inyectado).
    // Degrada con seguridad a default si nada aplica.
    // Hermes Desktop 0.19 ya aísla el perfil de forma nativa en
    // session.resume/session.create. En ese contrato no sondeamos el Mobile
    // Bridge: además de añadir latencia, podía desviar un chat moderno al
    // transporte heredado. El bridge queda solo para gateways sin lifecycle.
    if (profileRoutes(sessionProfile) &&
        _desktopGateway is! HermesDesktopSessionLifecycleGateway) {
      final accepted = await _dispatchWithProfile(
        fullText,
        model,
        history,
        sessionProfile,
        turnEpoch,
        nativeAttachments: nativeAttachments,
        capturedLifecycle: capturedLifecycle,
        transcriptOperation: transcriptOperation,
      );
      return _finishTurnDelivery(delivery, accepted, turnEpoch);
    }

    // Instancia LOCAL: no expone la API HTTP `/v1/runs` (su chat nativo es por
    // WebSocket). Se ejecuta el turno vía el Mobile Bridge (`/bridge/chat` →
    // `hermes -z`), que carga modelo/tools/memoria/skills y devuelve la
    // respuesta final.
    if (connection.kind == InstanceKind.localhost &&
        _desktopGateway is! HermesDesktopSessionLifecycleGateway) {
      await _sendViaBridge(
        fullText,
        history,
        profile: sessionProfile,
        turnEpoch: turnEpoch,
        nativeAttachments: nativeAttachments,
        capturedLifecycle: capturedLifecycle,
        transcriptOperation: transcriptOperation,
      );
      final accepted =
          _turnEpoch == turnEpoch && state != ChatPipelineState.failed;
      return _finishTurnDelivery(delivery, accepted, turnEpoch);
    }
    // Mismo transporte que Hermes Desktop. Si la instancia no expone
    // `/api/ws`, degrada al motor REST `/v1/runs` sin steering parcheado.
    final accepted = await _startRemoteAgentTurn(
      fullText,
      model,
      history,
      turnEpoch,
      sessionConfig: capturedSessionConfig,
      profile: sessionProfile,
      nativeAttachments: nativeAttachments,
      desktopText: desktopText,
      voicePlaybackInterrupted: voicePlaybackInterrupted,
      queued: queued,
      truncateBeforeUserOrdinal: truncateBeforeUserOrdinal,
      truncateBeforeRowId: truncateBeforeRowId,
      beforeDesktopPromptSubmit: beforeDesktopPromptSubmit,
    );
    return _finishTurnDelivery(delivery, accepted, turnEpoch);
  }

  Future<bool> _finishTurnDelivery(
    ActiveTurnDelivery? delivery,
    bool accepted,
    int turnEpoch,
  ) async {
    if (delivery == null || _turnEpoch != turnEpoch) return accepted;
    if (accepted) {
      await delivery.markAccepted();
      if (_runTerminal ||
          state == ChatPipelineState.completed ||
          state == ChatPipelineState.failed ||
          state == ChatPipelineState.cancelled) {
        await delivery.markTerminalAndDelete();
        if (identical(_activeTurnDelivery, delivery)) {
          _activeTurnDelivery = null;
        }
      } else {
        await delivery.markRunning();
      }
    } else {
      await delivery.markUnaccepted();
    }
    return accepted;
  }

  void _finalizeAcceptedTurnDelivery() {
    final delivery = _activeTurnDelivery;
    if (delivery == null || !delivery.acknowledged) return;
    _activeTurnDelivery = null;
    unawaited(delivery.markTerminalAndDelete());
  }

  Future<bool> _beginTurnTransport(
    int turnEpoch,
    PreparedTurnTransport transport,
  ) async {
    if (_turnEpoch != turnEpoch || _runTerminal) return false;
    final delivery = _activeTurnDelivery;
    if (delivery == null) return true;
    final ready = await delivery.beginTransport(transport);
    if (!ready && _turnEpoch == turnEpoch && !_runTerminal) {
      _failRun('No se pudo conservar el turno antes de enviarlo.');
    }
    return ready;
  }

  List<int> _durableRowIdsForRebind() {
    final source = _rewindRollbackMessages ?? _messages;
    final rowIds = <int>[];
    for (final message in source) {
      final rowId = canonicalTranscriptRowId(message);
      if (rowId != null && !rowIds.contains(rowId)) rowIds.add(rowId);
    }
    return rowIds;
  }

  /// Reasigna a cada superviviente su identidad durable posterior al rewind.
  ///
  /// Un rewind reinserta el prefijo conservado como filas nuevas, así que todo
  /// `_desktopRowId` cacheado queda obsoleto. Réplica de `rebindSurvivorRowIds`
  /// (`rewind.ts:106-142`): el mapa `old → new` tiene precedencia; con la lista
  /// posicional sólo se limpian los ordinales *más allá del final*, nunca todos
  /// por un simple desajuste de longitud.
  void _rebindSurvivorUserRowIds(DesktopRewindAck ack) {
    final rowIdMap = ack.survivorRowIdMap;
    // Un ACK sin ninguna de las dos claves sigue invalidando el prefijo: un id
    // obsoleto direcciona una fila archivada y el Gateway lo rechazaría (4018).
    final authoritativeRowIds = ack.survivorUserRowIds ?? const <int?>[];
    final userIndexesOldestFirst = <int>[];
    for (var index = _messages.length - 1; index >= 0; index--) {
      if (isRealUserTurn(_messages[index])) {
        userIndexesOldestFirst.add(index);
      }
    }
    if (userIndexesOldestFirst.isEmpty) return;
    // El último usuario es el prompt nuevo insertado por send(); el ACK solo
    // describe las filas del prefijo que el gateway acaba de reinsertar.
    final survivorIndexes = userIndexesOldestFirst.sublist(
      0,
      userIndexesOldestFirst.length - 1,
    );
    for (var ordinal = 0; ordinal < survivorIndexes.length; ordinal++) {
      final index = survivorIndexes[ordinal];
      final current = _messages[index];
      final int? rowId;
      if (rowIdMap != null) {
        final previous = canonicalTranscriptRowId(current);
        // Las filas fuera del active tip (historia compactada o ancestral) no
        // se reescribieron: conservan su identidad durable.
        if (previous == null || !rowIdMap.containsKey(previous)) continue;
        rowId = rowIdMap[previous];
      } else {
        rowId = ordinal < authoritativeRowIds.length
            ? authoritativeRowIds[ordinal]
            : null;
      }
      final rebound = Map<String, dynamic>.from(current);
      if (rowId == null) {
        rebound.remove('_desktopRowId');
      } else {
        rebound['_desktopRowId'] = rowId;
      }
      _messages[index] = rebound;
    }
    _transcriptRevision += 1;
    final reservation = _activeRewrite;
    if (reservation != null) {
      reservation.transcriptRevision = _transcriptRevision;
    }
  }

  /// El turno de usuario en [chronologicalIndex] falló localmente: su respuesta
  /// es un `assistant_error`, así que el prompt nunca llegó al gateway.
  ///
  /// Equivale a `isFailedUserTurn` (`use-prompt-actions/utils.ts:669-673`), que
  /// mira el mensaje inmediatamente posterior en orden cronológico.
  bool _isFailedUserTurn(
    List<Map<String, dynamic>> chronological,
    int chronologicalIndex,
  ) {
    final next = chronologicalIndex + 1 < chronological.length
        ? chronological[chronologicalIndex + 1]
        : null;
    return next != null && next['role'] == 'assistant_error';
  }

  bool _isStaleRewriteTarget(Object? error) {
    // Hermes Desktop's isCompressedAwayError: a negative segment ordinal
    // means the turn now lives inside a compaction summary, so resuming and
    // retrying can never find it.
    if (error is TuiGatewayRpcError &&
        error.code == 4018 &&
        error.data['segment_ordinal'] is num &&
        (error.data['segment_ordinal'] as num) < 0) {
      return false;
    }
    if (error is TuiGatewayRpcError && error.code == 4018) return true;
    final message = error is TuiGatewayRpcError
        ? error.message
        : error?.toString() ?? '';
    final normalized = message.toLowerCase();
    return normalized.contains('no longer in session history') ||
        normalized.contains('not in session history') ||
        normalized.contains('stale truncate_before_user_ordinal') ||
        (error is TuiGatewayRpcError &&
            error.code == 4030 &&
            normalized.contains('truncate_before_user_ordinal'));
  }

  Future<
    ({
      DesktopSessionSnapshot snapshot,
      List<Map<String, dynamic>> messagesNewestFirst,
      int targetIndex,
      int userOrdinal,
      int rowId,
      int? fallbackOrdinal,
    })?
  >
  _resyncStaleRewriteTarget({
    required HermesDesktopGateway gateway,
    required _RewriteReservation reservation,
    required String sourceText,
    required bool sourceWasNewestUser,
    required String model,
  }) async {
    final durableId = _desktopStoredSessionId ?? serverSessionId;
    final expectedTurnEpoch = _turnEpoch;
    final expectedProfile = _storedSessionProfile;
    final snapshot = await _resumeDesktopSessionForRecovery(
      gateway,
      durableId,
      profile: expectedProfile,
      legacyModel: model,
    );
    if (!identical(_activeRewrite, reservation) ||
        !identical(_desktopGateway, gateway) ||
        _turnEpoch != expectedTurnEpoch ||
        snapshot.created ||
        snapshot.storedSessionId != durableId ||
        !_desktopSnapshotTranscriptIsComplete(snapshot) ||
        !snapshot.messagesProvided) {
      return null;
    }

    final messagesNewestFirst = const DesktopSessionReconciler()
        .project(snapshot)
        .messagesNewestFirst
        .map(Map<String, dynamic>.from)
        .toList(growable: false);
    final chronological = messagesNewestFirst.reversed.toList(growable: false);
    final matches = <int>[];
    for (var index = 0; index < chronological.length; index++) {
      final message = chronological[index];
      if (isRealUserTurn(message) &&
          (message['content'] ?? '').toString().trim() == sourceText.trim()) {
        matches.add(index);
      }
    }
    if (matches.isEmpty || (matches.length > 1 && !sourceWasNewestUser)) {
      return null;
    }
    final targetIndex = matches.length == 1 ? matches.single : matches.last;
    final target = chronological[targetIndex];
    final rowId = canonicalTranscriptRowId(target);
    if (rowId == null) return null;
    var userOrdinal = 0;
    for (var index = 0; index < targetIndex; index++) {
      if (isRealUserTurn(chronological[index])) userOrdinal++;
    }
    return (
      snapshot: snapshot,
      messagesNewestFirst: messagesNewestFirst,
      targetIndex: targetIndex,
      userOrdinal: userOrdinal,
      rowId: rowId,
      fallbackOrdinal: modelSwitchRepairFallbackOrdinal(
        messagesNewestFirst,
        target,
        desktopOrdinal: userOrdinal,
      ),
    );
  }

  ({
    List<Map<String, dynamic>> messages,
    Map<String, dynamic> target,
  })
  _reuseMessageForOptimisticRewrite({
    required List<Map<String, dynamic>> chronological,
    required int targetIndex,
    required Map<String, dynamic> target,
    required String content,
  }) {
    var reused = target;
    try {
      reused['content'] = content;
    } on UnsupportedError {
      reused = Map<String, dynamic>.from(target)..['content'] = content;
      chronological[targetIndex] = reused;
    }
    return (
      messages: chronological
          .take(targetIndex + 1)
          .where((message) => message['_pipeline'] != true)
          .toList(growable: true)
          .reversed
          .toList(growable: true),
      target: reused,
    );
  }

  /// Rebobina hasta un prompt visible y lo vuelve a ejecutar. El ordinal usa el
  /// mismo índice de usuarios (0-based, de antiguo a nuevo) que Hermes Desktop.
  /// La conversación visible se recorta de forma optimista; si el transporte
  /// falla antes de aceptar el prompt, [_startDesktopTurn] restaura la copia.
  Future<void> rewrite({
    required int userOrdinal,
    required String text,
    required String model,
    String profile = '',
    String? desktopText,
    String? mentionText,
    List<AttachmentDraft> nativeAttachments = const [],
  }) async {
    if (mutationsBlockedByOwnershipConflict) {
      throw _ownershipConflictError('session.rewind');
    }
    final mentionAnnotation = buildBotMentionAnnotation(
      mentionResolver.resolve(mentionText ?? text),
    );
    final mentionPayload = appendBotMentionNote(text, mentionAnnotation);
    final desktopMentionPayload = desktopText == null
        ? null
        : appendBotMentionNote(desktopText, mentionAnnotation);
    final capturedLifecycle = _localConversationLifecycle;
    if (_activeRewrite != null) {
      throw StateError('Another conversation rewrite is already active');
    }
    final reservation = _RewriteReservation(
      transcriptRevision: _transcriptRevision,
      turnEpoch: _turnEpoch,
      runtimeSessionId: _desktopRuntimeSessionId,
    );
    _activeRewrite = reservation;
    _rewindDashboardAuthRequired = false;
    try {
      final snapshot = _messages
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final chronological = _messages.reversed.toList();
      var seenUsers = 0;
      var targetIndex = -1;
      for (var i = 0; i < chronological.length; i++) {
        final message = chronological[i];
        if (!isRealUserTurn(message)) continue;
        if (seenUsers == userOrdinal) {
          targetIndex = i;
          break;
        }
        seenUsers++;
      }
      if (targetIndex < 0) {
        throw StateError('The message is no longer in this conversation');
      }
      var target = chronological[targetIndex];
      final sourceText = (target['content'] ?? '').toString();
      final sourceWasNewestUser =
          userOrdinal == chronological.where(isRealUserTurn).length - 1;
      final fallbackOrdinal = modelSwitchRepairFallbackOrdinal(
        _messages,
        target,
        desktopOrdinal: userOrdinal,
      );
      var runtimeId = _desktopRuntimeSessionId;
      var gateway = _desktopGateway;
      // El optimista de usuario de un turno fallido nunca llegó al gateway, así
      // que su row id cacheado ya no direcciona nada y un recorte por él
      // erraría el tiro. Réplica de `planEdit` (`rewind.ts:630-640`).
      final isFailedTurn = _isFailedUserTurn(chronological, targetIndex);
      var truncateBeforeRowId = isFailedTurn
          ? null
          : canonicalTranscriptRowId(target);

      if (!isFailedTurn && truncateBeforeRowId == null && runtimeId == null) {
        final ready = await ensureDesktopRuntime(
          acquireForExplicitAction: true,
        );
        if (!identical(_activeRewrite, reservation) ||
            _turnEpoch != reservation.turnEpoch) {
          return;
        }
        if (ready) {
          runtimeId = _desktopRuntimeSessionId;
          gateway = _desktopGateway;
          reservation.runtimeSessionId = runtimeId;
          reservation.transcriptRevision = _transcriptRevision;
        }
      }
      if (!isFailedTurn && truncateBeforeRowId == null) {
        final resolver = gateway is HermesDesktopRewindResolverGateway
            ? gateway as HermesDesktopRewindResolverGateway
            : null;
        if (runtimeId != null && resolver != null) {
          truncateBeforeRowId = await resolver.resolveDurableUserRowId(
            runtimeId,
            sourceText: sourceText,
            expectedOrdinal: userOrdinal,
          );
        }
        // El ordinal local no comparte espacio con el del gateway tras una
        // compactación o con transcript paginado (`rewind.ts:286-325`). Sin una
        // fila durable exacta, reenviar convertiría la edición en otro turno.
        if (truncateBeforeRowId == null) {
          throw StateError('The message can no longer be edited safely');
        }
      }
      final truncatesDurably = truncateBeforeRowId != null;
      if (!identical(_activeRewrite, reservation) ||
          _transcriptRevision != reservation.transcriptRevision ||
          _turnEpoch != reservation.turnEpoch ||
          _desktopRuntimeSessionId != reservation.runtimeSessionId) {
        return;
      }
      if (truncatesDurably && gateway is! HermesDesktopDurableRewindGateway) {
        throw const TuiGatewayRpcError(
          'prompt.submit',
          'Durable conversation rewind is unavailable',
          code: -32601,
        );
      }

      if (isStreaming) {
        final interruptDrain = runtimeId != null && gateway != null
            ? Completer<void>()
            : null;
        _desktopInterruptDrain = interruptDrain;
        _discardLateInterruptTerminal = interruptDrain != null;
        // Editar NO es un Stop del usuario: la interrupción sólo hace sitio al
        // turno reescrito, que sustituye a esta misma fila. Marcarla como
        // `_cancelledUser` inventaba un turno detenido sin ancla durable —
        // ensuciaba el historial que se manda al modelo y dejaba la fila
        // ambigua que después rompía la propia edición y los envíos siguientes.
        _cancelCurrent(
          requestServerStop: false,
          deferConfirmation: true,
          markUserCancelled: false,
        );
        reservation.transcriptRevision = _transcriptRevision;
        reservation.turnEpoch = _turnEpoch;
        if (runtimeId != null && gateway != null) {
          try {
            await gateway.interrupt(runtimeId);
            // session.interrupt confirma el RPC, pero el terminal del turno viejo
            // puede llegar después. No suscribimos el rewind hasta drenarlo: si no,
            // "Operation interrupted" puede cerrar el turno editado recién creado.
            await interruptDrain?.future.timeout(const Duration(seconds: 3));
          } on TimeoutException {
            // Gateways antiguos pueden no publicar terminal de interrupción. El
            // guard de _onDesktopEvent seguirá descartándolo si llega más tarde.
          } catch (_) {
            // prompt.submit también aplica el busy gate; el envío mostrará el
            // error real si el agente todavía no estuviera listo.
          } finally {
            if (identical(_desktopInterruptDrain, interruptDrain)) {
              _desktopInterruptDrain = null;
            }
          }
        }
      }
      if (!identical(_activeRewrite, reservation) ||
          _turnEpoch != reservation.turnEpoch) {
        return;
      }
      reservation.runtimeSessionId = _desktopRuntimeSessionId;
      reservation.transcriptRevision = _transcriptRevision;

      var rollbackState = state;
      var rollbackMessages = snapshot
          .where((message) => message['_pipeline'] != true)
          .map((message) => Map<String, dynamic>.from(message))
          .toList(growable: false);
      final optimisticRewrite = _reuseMessageForOptimisticRewrite(
        chronological: chronological,
        targetIndex: targetIndex,
        target: target,
        content: mentionPayload,
      );
      _messages = optimisticRewrite.messages;
      target = optimisticRewrite.target;
      if (truncatesDurably) {
        _rewindRollbackMessages = rollbackMessages;
        _rewindRollbackState = rollbackState;
        _rewind4018FallbackOrdinal = fallbackOrdinal;
      }
      _rewindRestoredOnError = false;
      // Editar es un gesto explícito del usuario: como enviar, se admite
      // siempre y levanta el park que dejó un Stop anterior. `_send` no pasa
      // por el gate de `send()`, así que hay que replicarlo aquí o la cola
      // seguiría suspendida después de la edición.
      await _admitThroughParkedQueue();
      if (!identical(_activeRewrite, reservation) ||
          _turnEpoch != reservation.turnEpoch) {
        _messages = rollbackMessages;
        state = rollbackState;
        _rewindRollbackMessages = null;
        _rewindRollbackState = null;
        _rewind4018FallbackOrdinal = null;
        _rewindRestoredOnError = true;
        _emit(ActiveChatEvent.error);
        return;
      }
      final history = _buildHistoryFromMessages(excluding: target);
      try {
        final accepted = await _send(
          fullText: mentionPayload,
          model: model,
          history: history,
          profile: profile,
          nativeAttachments: nativeAttachments,
          desktopText: desktopMentionPayload,
          truncateBeforeUserOrdinal: truncatesDurably ? userOrdinal : null,
          truncateBeforeRowId: truncateBeforeRowId,
          rewriteReservation: reservation,
          reusedOptimisticUserRow: target,
          capturedLifecycle: capturedLifecycle,
        );
        if (!accepted &&
            truncatesDurably &&
            !isFailedTurn &&
            gateway != null &&
            _isStaleRewriteTarget(reservation.rejection)) {
          ({
            DesktopSessionSnapshot snapshot,
            List<Map<String, dynamic>> messagesNewestFirst,
            int targetIndex,
            int userOrdinal,
            int rowId,
            int? fallbackOrdinal,
          })? retryPlan;
          try {
            retryPlan = await _resyncStaleRewriteTarget(
              gateway: gateway,
              reservation: reservation,
              sourceText: sourceText,
              sourceWasNewestUser: sourceWasNewestUser,
              model: model,
            );
          } catch (error) {
            reservation.rejection = error;
          }
          if (retryPlan != null && identical(_activeRewrite, reservation)) {
            final refreshedRollback = retryPlan.messagesNewestFirst
                .where((message) => message['_pipeline'] != true)
                .map((message) => Map<String, dynamic>.from(message))
                .toList(growable: false);
            final refreshedChronological =
                retryPlan.messagesNewestFirst.reversed.toList(growable: false);
            _desktopStoredSessionId = retryPlan.snapshot.storedSessionId;
            _desktopStoredSessionKnownMissing = false;
            _adoptDesktopRuntime(
              retryPlan.snapshot.runtimeSessionId,
              info: retryPlan.snapshot.info,
            );
            _desktopRuntimeInfo = retryPlan.snapshot.info;
            _rememberDesktopLiveStatus(
              retryPlan.snapshot.status,
              running: retryPlan.snapshot.running,
            );
            _usingDesktopGateway = true;
            var retryTarget = refreshedChronological[retryPlan.targetIndex];
            final retryOptimistic = _reuseMessageForOptimisticRewrite(
              chronological: refreshedChronological,
              targetIndex: retryPlan.targetIndex,
              target: retryTarget,
              content: mentionPayload,
            );
            _messages = retryOptimistic.messages;
            retryTarget = retryOptimistic.target;
            _transcriptRevision += 1;
            rollbackMessages = refreshedRollback;
            rollbackState = state;
            _rewindRollbackMessages = refreshedRollback;
            _rewindRollbackState = rollbackState;
            _rewind4018FallbackOrdinal = retryPlan.fallbackOrdinal;
            _rewindRestoredOnError = false;
            reservation
              ..transcriptRevision = _transcriptRevision
              ..turnEpoch = _turnEpoch
              ..runtimeSessionId = retryPlan.snapshot.runtimeSessionId
              ..transportStarted = false
              ..terminalNotificationDeferred = false
              ..rejection = null;
            final retryAccepted = await _send(
              fullText: mentionPayload,
              model: model,
              history: _buildHistoryFromMessages(excluding: retryTarget),
              profile: profile,
              nativeAttachments: nativeAttachments,
              desktopText: desktopMentionPayload,
              truncateBeforeUserOrdinal: retryPlan.userOrdinal,
              truncateBeforeRowId: retryPlan.rowId,
              rewriteReservation: reservation,
              reusedOptimisticUserRow: retryTarget,
              capturedLifecycle: capturedLifecycle,
            );
            if (retryAccepted) return;
          }
        }
        if (!accepted) {
          _messages = rollbackMessages;
          state = rollbackState;
          _rewindRollbackMessages = null;
          _rewindRollbackState = null;
          _rewind4018FallbackOrdinal = null;
          // La reserva seguía siendo nuestra, así que esto no es una carrera
          // con otra edición: el transporte rechazó este turno. El reenvío
          // plano no recorta nada, pero también fracasó — y sin esta marca la
          // pantalla se quedaba sin aviso alguno después de haber interrumpido
          // ya el turno vivo: el usuario perdía la respuesta y la edición sin
          // ver nada.
          _rewindRestoredOnError = true;
          if (reservation.terminalNotificationDeferred) {
            reservation.terminalNotificationDeferred = false;
            _emit(ActiveChatEvent.error);
            _onTerminal();
          }
          return;
        }
      } catch (_) {
        _messages = rollbackMessages;
        state = rollbackState;
        _rewindRollbackMessages = null;
        _rewindRollbackState = null;
        _rewind4018FallbackOrdinal = null;
        rethrow;
      }
    } finally {
      if (identical(_activeRewrite, reservation)) {
        _activeRewrite = null;
      }
    }
  }

  /// Calienta la conexión al gateway (ver [ApiClient.warmUp]). Lo llama el modo
  /// voz al entrar para que el primer turno no pague el handshake en frío.
  Future<void> warmUp() => _api.warmUp();

  /// Abre anticipadamente el canal oficial de chat. Además de reducir la
  /// latencia del primer prompt, ejecuta la reparación de credenciales del
  /// Dashboard antes de que un seguimiento pueda caer al fallback de cola.
  /// Bootstrap lifecycle-only. Passive opt-out must block this path without
  /// disabling an explicit auth warm-up requested by the user surface.
  Future<void> warmDesktopGatewayForAutomaticBootstrap() {
    if (!_attachDesktopRuntimeOnLoad) return Future<void>.value();
    return warmDesktopGateway();
  }

  Future<void> warmDesktopGateway() async {
    if (connection.kind == InstanceKind.localhost) return;
    final dashboardAuthAttempt = ++_dashboardAuthAttemptEpoch;
    try {
      if (_desktopRuntimeSessionId != null &&
          _desktopGateway?.isConnected != true) {
        await ensureDesktopRuntime();
        _setDashboardAuthRequired(false, attemptEpoch: dashboardAuthAttempt);
        return;
      }
      await _desktopGateway?.connect();
      _setDashboardAuthRequired(false, attemptEpoch: dashboardAuthAttempt);
    } catch (error) {
      if (_isDashboardAuthRequired(error)) {
        _setDashboardAuthRequired(true, attemptEpoch: dashboardAuthAttempt);
      }
      debugPrint(
        '[active-chat] Desktop gateway warm-up failed '
        '(${error.runtimeType})',
      );
      // Best-effort: send conserva su fallback REST para bridges antiguos.
    }
  }

  DesktopCompressionAuthorityState get _desktopCompressionAuthorityState =>
      DesktopCompressionAuthorityState(
        activeChatIdentity: _desktopCompressionAuthorityIdentity,
        connectionIdentity: connection,
        gatewayIdentity: _desktopGateway,
        disposed: _disposed,
        profileOwnerBound: _sessionProfileOwner != null,
        wireProfile: _storedSessionProfile,
        storedSessionId: _desktopStoredSessionId,
        runtimeSessionId: _desktopRuntimeSessionId,
        bindEpoch: _desktopBindEpoch,
        sessionEpoch: _desktopSessionEpoch,
        messageLoadEpoch: _messageLoadEpoch,
        tombstoneRevision: _cancelledTombstoneRevision,
        testingTainted: _desktopCompressionTestingTainted,
      );

  DesktopCompressionAuthorityToken _captureDesktopCompressionAuthority() {
    final initial = _desktopCompressionAuthorityState;
    return DesktopCompressionAuthorityToken.capture(
      operationIdentity: Object(),
      initialState: initial,
      requestedDurableId: initial.storedSessionId ?? serverSessionId,
      expectedRootId: logicalSessionId,
      scope: DesktopCompressionAuthorityScope(
        connectionId: connection.id,
        profile: Session.profileOwner(
          _sessionProfileOwner,
          fallback: _storedSessionProfile,
        ),
        logicalSessionId: logicalSessionId,
      ),
    );
  }

  DesktopCompressionFenceScope _fenceScopeForAuthority(
    DesktopCompressionAuthorityToken authority,
  ) => DesktopCompressionFenceScope(
    connectionId: authority.scope.connectionId,
    profile: authority.scope.profile,
    logicalSessionId: authority.scope.logicalSessionId,
  );

  /// Ensures an existing durable chat has a live runtime without ever creating
  /// one. A 4007 means this is still a local draft and is reported as `false`.
  Future<bool> ensureDesktopRuntime({bool acquireForExplicitAction = false}) {
    if (acquireForExplicitAction && mutationsBlockedByOwnershipConflict) {
      return Future<bool>.value(false);
    }
    if (!acquireForExplicitAction) {
      return Future<bool>.value(
        _desktopRuntimeSessionId != null &&
            _desktopGateway?.isConnected == true,
      );
    }
    final token = _captureDesktopCompressionAuthority();
    final authority = token.begin(_desktopCompressionAuthorityState);
    if (authority == null) return Future<bool>.value(false);
    return _acquireDesktopRuntime(
      authority,
      allowTestingIdentityBypass: _allowUnownedDesktopSnapshotForTesting,
    ).then((receipt) => receipt != null);
  }

  /// Explicitly closes a Console-owned idle runtime so another surface may
  /// acquire its durable conversation. The transcript and durable local turn
  /// state are retained; only the exact live runtime binding is retired.
  Future<bool> releaseRuntimeForDesktop() async {
    if (!_releasePreconditionsSatisfied()) return false;
    final gateway = _desktopGateway!;
    final activity = gateway as HermesDesktopSessionActivityGateway;
    final closer = gateway as HermesDesktopSessionCloseGateway;
    final connectionId = connection.id;
    final profile = _storedSessionProfile;
    final durableId = _desktopStoredSessionId!;
    final runtimeId = _desktopRuntimeSessionId!;
    final bindEpoch = _desktopBindEpoch;
    final sessionEpoch = _desktopSessionEpoch;
    final turnEpoch = _turnEpoch;

    _runtimeReleaseInFlight = true;
    _emit(ActiveChatEvent.sessionInfo);
    bool exactBindingStillCurrent() =>
        identical(gateway, _desktopGateway) &&
        connection.id == connectionId &&
        _storedSessionProfile == profile &&
        _desktopStoredSessionId == durableId &&
        _desktopRuntimeSessionId == runtimeId &&
        _desktopBindEpoch == bindEpoch &&
        _desktopSessionEpoch == sessionEpoch &&
        _turnEpoch == turnEpoch;
    bool current() =>
        _releasePreconditionsSatisfied(ignoreReleaseInFlight: true) &&
        exactBindingStillCurrent();

    try {
      final active = await activity
          .listActiveSessions(currentRuntimeSessionId: runtimeId)
          .timeout(_desktopRecoveryAttemptTimeout);
      if (!current() || active.hasMalformedRows) return false;
      final exact = active.sessions
          .where(
            (row) =>
                row.runtimeSessionId == runtimeId &&
                row.storedSessionId == durableId,
          )
          .toList(growable: false);
      if (exact.length != 1) return false;
      for (final row in active.sessions) {
        final collides =
            row.runtimeSessionId == runtimeId ||
            row.storedSessionId == durableId;
        final isExact =
            row.runtimeSessionId == runtimeId &&
            row.storedSessionId == durableId;
        if (collides && !isExact) return false;
      }
      final row = exact.single;
      if (!row.current || row.status != 'idle') return false;

      final closed = await closer
          .closeSession(runtimeId)
          .timeout(_desktopRecoveryAttemptTimeout);
      if (!closed || !exactBindingStillCurrent()) return false;
      _retireDesktopRuntime();
      return true;
    } catch (_) {
      return false;
    } finally {
      _runtimeReleaseInFlight = false;
      if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
    }
  }

  /// Explicit, non-submitting ownership availability check after a 4090.
  ///
  /// A successful resume is deliberately not treated as lease proof. It only
  /// arms exactly one later manual send to test admission with the same durable
  /// clientTurnId. Every other mutation and passive queue drain remains fenced.
  Future<bool> recheckRuntimeOwnership() async {
    if (_disposed ||
        _ownershipMutationAdmission !=
            _OwnershipMutationAdmission.conflictReadOnly ||
        !ownershipRecheckAvailable ||
        ownershipRecheckInFlight) {
      return false;
    }
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopSessionLifecycleGateway ||
        gateway is! HermesDesktopSessionActivityGateway) {
      return false;
    }
    final lifecycle = gateway as HermesDesktopSessionLifecycleGateway;
    final activity = gateway as HermesDesktopSessionActivityGateway;
    final rawDurableId = _desktopStoredSessionId ?? serverSessionId;
    final durableId = rawDurableId.trim();
    if (durableId.isEmpty || durableId != rawDurableId) return false;

    final conflictGeneration = _ownershipConflictGeneration;
    final bindEpoch = _desktopBindEpoch;
    final sessionEpoch = _desktopSessionEpoch;
    final turnEpoch = _turnEpoch;
    final profile = _storedSessionProfile;
    _ownershipMutationAdmission = _OwnershipMutationAdmission.rechecking;
    bool current() =>
        !_disposed &&
        _ownershipMutationAdmission == _OwnershipMutationAdmission.rechecking &&
        conflictGeneration == _ownershipConflictGeneration &&
        bindEpoch == _desktopBindEpoch &&
        sessionEpoch == _desktopSessionEpoch &&
        turnEpoch == _turnEpoch &&
        profile == _storedSessionProfile &&
        identical(gateway, _desktopGateway);

    _emit(ActiveChatEvent.sessionInfo);
    try {
      await (gateway as HermesDesktopGateway).connect();
      if (!current()) return false;
      final active = await activity.listActiveSessions();
      if (!current() || active.hasMalformedRows) return false;
      final matches = active.sessions
          .where((row) => row.storedSessionId == durableId)
          .toList(growable: false);
      if (matches.length > 1) return false;
      if (matches.length == 1) {
        final advertisedRuntimeId = matches.single.runtimeSessionId;
        final runtimeAssociations = active.sessions.where(
          (row) => row.runtimeSessionId == advertisedRuntimeId,
        );
        if (runtimeAssociations.length != 1) return false;
      }

      final DesktopSessionSnapshot snapshot;
      final _DesktopRuntimeBindingOrigin origin;
      if (matches.length == 1) {
        final row = matches.single;
        if (row.runtimeSessionId.isEmpty ||
            row.runtimeSessionId != row.runtimeSessionId.trim()) {
          return false;
        }
        snapshot = await activity.activateSession(
          row.runtimeSessionId,
          storedSessionId: durableId,
        );
        origin = _DesktopRuntimeBindingOrigin.viewerActivated;
      } else {
        snapshot = await lifecycle.resumeExisting(durableId, profile: profile);
        origin = _DesktopRuntimeBindingOrigin.availabilityResumed;
      }
      if (!current() ||
          snapshot.created ||
          !snapshot.identityAliasesConsistent ||
          !snapshot.storedSessionIdentityExplicit ||
          snapshot.storedSessionId != durableId ||
          snapshot.runtimeSessionId.isEmpty ||
          snapshot.runtimeSessionId != snapshot.runtimeSessionId.trim() ||
          (matches.length == 1 &&
              snapshot.runtimeSessionId != matches.single.runtimeSessionId)) {
        return false;
      }

      _desktopStoredSessionId = durableId;
      _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
      _hydrateAgentTasks(snapshot.todoState);
      _desktopRuntimeBindingOrigin = origin;
      _desktopRuntimeInfo = snapshot.info;
      _rememberDesktopLiveStatus(snapshot.status, running: snapshot.running);
      _ownershipMutationAdmission =
          _OwnershipMutationAdmission.pendingManualProbe;
      _queueDrainSuspended = true;
      _emit(ActiveChatEvent.sessionInfo);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (conflictGeneration == _ownershipConflictGeneration) {
        if (_ownershipMutationAdmission ==
            _OwnershipMutationAdmission.rechecking) {
          _ownershipMutationAdmission =
              _OwnershipMutationAdmission.conflictReadOnly;
        }
        if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
      }
    }
  }

  /// Whether lifecycle/bootstrap code may attach this visible durable chat.
  /// Explicit user mutations keep using [ensureDesktopRuntime] and are not
  /// disabled by this passive-open policy.
  bool get attachesDesktopRuntimeOnLoad => _attachDesktopRuntimeOnLoad;

  /// Proves that the current gateway process already owns a runtime for the
  /// durable conversation before an automatic viewer attach may call resume.
  /// A shared database is not a shared runtime: resuming an ID absent from this
  /// process would reconstruct a competing runtime and strand passive REST
  /// observation behind a false local binding.
  Future<List<String>?> _gatewayAdvertisesDurableRuntime(
    HermesDesktopGateway gateway,
    String durableId, {
    required bool Function() stillAuthorized,
  }) async {
    final activity = gateway is HermesDesktopSessionActivityGateway
        ? gateway as HermesDesktopSessionActivityGateway
        : null;
    if (!stillAuthorized()) return null;
    if (activity == null) return const <String>[];
    final active = await activity.listActiveSessions();
    if (!stillAuthorized() || active.hasMalformedRows) return null;
    final matches = <String>[];
    for (final session in active.sessions) {
      if (session.storedSessionId == durableId &&
          session.runtimeSessionId.trim().isNotEmpty) {
        matches.add(session.runtimeSessionId);
      }
    }
    return matches;
  }

  /// Attaches this durable conversation as a viewer of its existing runtime.
  /// This uses the exact non-creating lifecycle path and never submits a prompt.
  /// The durable compression lookup is an authority prerequisite: automatic
  /// attachment proceeds only from an explicit, current `absent` result.
  Future<bool> attachExistingRuntimeViewer({
    bool Function()? stillOwningVisible,
  }) async {
    bool visible() => stillOwningVisible?.call() ?? true;
    if (!_attachDesktopRuntimeOnLoad ||
        _disposed ||
        mutationsBlockedByOwnershipConflict ||
        !visible()) {
      return false;
    }
    final scope = _desktopCompressionFenceScope;
    final authority = _desktopCompressionAuthorityState;
    bool stillAuthorized() =>
        !_disposed &&
        _attachDesktopRuntimeOnLoad &&
        authority.sameCoordinates(_desktopCompressionAuthorityState) &&
        visible();
    if (await _hasUnresolvedDurableCompressionFence(
      capturedScope: scope,
      stillAuthorized: stillAuthorized,
    )) {
      return false;
    }
    if (!stillAuthorized()) return false;
    final token = _captureDesktopCompressionAuthority();
    final transition = token.begin(_desktopCompressionAuthorityState);
    if (transition == null || !stillAuthorized()) return false;
    final receipt = await _acquireDesktopRuntime(
      transition,
      allowTestingIdentityBypass: _allowUnownedDesktopSnapshotForTesting,
      allowActivation: false,
      stillAuthorizedByCaller: visible,
    );
    return receipt != null && visible();
  }

  Future<DesktopCompressionAcquisitionReceipt?> _acquireDesktopRuntime(
    DesktopCompressionAuthorityTransition authority, {
    DesktopCompressionProjection? presentationProjection,
    bool allowTestingIdentityBypass = false,
    bool allowActivation = true,
    bool Function()? stillAuthorizedByCaller,
  }) async {
    final token = authority.token;
    final gateway = token.initialState.gatewayIdentity;
    if (gateway is! HermesDesktopGateway ||
        gateway is! HermesDesktopSessionLifecycleGateway ||
        _desktopStoredSessionKnownMissing) {
      return null;
    }
    bool callerAuthorized() => stillAuthorizedByCaller?.call() ?? true;
    if (!authority.matches(_desktopCompressionAuthorityState) ||
        !callerAuthorized()) {
      return null;
    }
    if (token.initialState.runtimeSessionId != null && gateway.isConnected) {
      return DesktopCompressionAcquisitionReceipt.forExistingBinding(
        authority,
        compressionsAtStart: _compressionCountFromInfo(_desktopRuntimeInfo),
      );
    }

    DesktopCompressionAcquisitionReceipt? reusableReceipt() {
      final receipt = _validatedDesktopAcquisition;
      return receipt != null &&
              receipt.canAuthorize(token, _desktopCompressionAuthorityState)
          ? receipt
          : null;
    }

    _listenToDesktopGateway(gateway);
    if (!callerAuthorized()) return reusableReceipt();
    await gateway.connect();
    if (!authority.matches(_desktopCompressionAuthorityState) ||
        !callerAuthorized()) {
      return reusableReceipt();
    }
    String? advertisedRuntimeId;
    if (!allowActivation && !allowTestingIdentityBypass) {
      final advertisedRuntimes = await _gatewayAdvertisesDurableRuntime(
        gateway,
        token.requestedDurableId,
        stillAuthorized: () =>
            authority.matches(_desktopCompressionAuthorityState) &&
            callerAuthorized(),
      );
      if (advertisedRuntimes == null || advertisedRuntimes.length > 1) {
        return reusableReceipt();
      }
      advertisedRuntimeId = advertisedRuntimes.singleOrNull;
    }
    if (!authority.matches(_desktopCompressionAuthorityState) ||
        !callerAuthorized()) {
      return reusableReceipt();
    }

    final reservation = authority.reserveOwnBind(
      _desktopCompressionAuthorityState,
    );
    if (reservation == null) return reusableReceipt();
    _desktopBindEpoch += 1;
    if (!reservation.matches(_desktopCompressionAuthorityState)) {
      return reusableReceipt();
    }
    presentationProjection?._acceptOwn(runtimeOnly: true);

    bool acquisitionStillAuthorized() =>
        callerAuthorized() &&
        reservation.matches(_desktopCompressionAuthorityState);
    Future<T> authorizedAcquisition<T>(Future<T> Function() operation) =>
        TuiGatewayClient.withCompressionAuthorization(
          acquisitionStillAuthorized,
          operation,
        );

    final lifecycle = gateway as HermesDesktopSessionLifecycleGateway;
    final previousRuntimeId = token.initialState.runtimeSessionId;
    final durableId = token.requestedDurableId;
    final previousProfile = token.initialState.wireProfile;
    final privacyProfile = previousProfile.isEmpty
        ? 'default'
        : previousProfile;
    final approvalGeneration = _approvalGeneration;
    try {
      DesktopSessionSnapshot snapshot;
      var bindingOrigin = _DesktopRuntimeBindingOrigin.availabilityResumed;
      final activity = gateway is HermesDesktopSessionActivityGateway
          ? gateway as HermesDesktopSessionActivityGateway
          : null;
      if (advertisedRuntimeId != null && activity != null) {
        try {
          bindingOrigin = _DesktopRuntimeBindingOrigin.viewerActivated;
          if (!acquisitionStillAuthorized()) return reusableReceipt();
          snapshot = await authorizedAcquisition(
            () => activity.activateSession(
              advertisedRuntimeId!,
              storedSessionId: durableId,
            ),
          );
          if (!acquisitionStillAuthorized()) return reusableReceipt();
        } on TuiGatewayRpcError catch (error) {
          if (error.code == 4007 || error.code == -32601) {
            return reusableReceipt();
          }
          rethrow;
        }
      } else if (allowActivation &&
          previousRuntimeId != null &&
          activity != null) {
        try {
          bindingOrigin = _DesktopRuntimeBindingOrigin.viewerActivated;
          if (!acquisitionStillAuthorized()) return reusableReceipt();
          snapshot = await authorizedAcquisition(
            () => activity.activateSession(
              previousRuntimeId,
              storedSessionId: durableId,
            ),
          );
          if (!acquisitionStillAuthorized()) return reusableReceipt();
        } on TuiGatewayRpcError catch (error) {
          final invalidCapability =
              activity.capabilityState(
                DesktopGatewayCapability.sessionActivate,
              ) ==
              DesktopGatewayCapabilityState.invalid;
          if (error.code != 4007 &&
              error.code != -32601 &&
              !invalidCapability) {
            rethrow;
          }
          if (!acquisitionStillAuthorized()) return reusableReceipt();
          bindingOrigin = _DesktopRuntimeBindingOrigin.availabilityResumed;
          snapshot = await authorizedAcquisition(
            () => lifecycle.resumeExisting(durableId, profile: previousProfile),
          );
          if (!acquisitionStillAuthorized()) return reusableReceipt();
        }
      } else {
        if (!acquisitionStillAuthorized()) return reusableReceipt();
        snapshot = await authorizedAcquisition(
          () => lifecycle.resumeExisting(durableId, profile: previousProfile),
        );
        if (!acquisitionStillAuthorized()) return reusableReceipt();
      }

      if (advertisedRuntimeId != null &&
          snapshot.runtimeSessionId != advertisedRuntimeId) {
        return reusableReceipt();
      }

      final preimage = _desktopCompressionAuthorityState;
      final retires = _desktopRuntimeNeedsAdoption(
        snapshot.runtimeSessionId,
        snapshot.storedSessionId,
      );
      final destination = preimage.withBinding(
        storedSessionId: snapshot.storedSessionId,
        runtimeSessionId: snapshot.runtimeSessionId,
        bindEpoch: preimage.bindEpoch + (retires ? 1 : 0),
        sessionEpoch: preimage.sessionEpoch + (retires ? 2 : 0),
      );
      final evidence = DesktopCompressionAcquisitionEvidence(
        runtimeSessionId: snapshot.runtimeSessionId,
        storedSessionId: snapshot.storedSessionId,
        storedSessionIdentityExplicit: snapshot.storedSessionIdentityExplicit,
        advertisedRootId: snapshot.lineageRootId,
        identityAliasesConsistent: snapshot.identityAliasesConsistent,
        created: snapshot.created,
        compressionsAtStart: _compressionCountFromInfo(snapshot.info),
      );
      DesktopCompressionAcquisitionReceipt? receiptForSnapshot({
        bool testingBypass = false,
      }) => DesktopCompressionAcquisitionReceipt.tryCreate(
        authority: token,
        preimage: preimage,
        destination: destination,
        evidence: evidence,
        allowTestingIdentityBypass: testingBypass,
      );
      // Enabling the seam does not weaken a valid acquisition. Only a
      // snapshot that actually needs the bypass receives non-transferable taint.
      final receipt =
          receiptForSnapshot() ??
          (allowTestingIdentityBypass
              ? receiptForSnapshot(testingBypass: true)
              : null);
      if (receipt == null) return null;

      // Latch before adoption/rebasing can invoke any reentrant callbacks.
      _desktopCompressionTestingTainted = receipt.destination.testingTainted;
      final postReceiptReservation = reservation.destination.withBinding(
        storedSessionId: reservation.destination.storedSessionId,
        runtimeSessionId: reservation.destination.runtimeSessionId,
        bindEpoch: reservation.destination.bindEpoch,
        sessionEpoch: reservation.destination.sessionEpoch,
        testingTainted: receipt.destination.testingTainted,
      );
      bool privacyCheckpointStillAuthorized() => postReceiptReservation
          .sameCoordinates(_desktopCompressionAuthorityState);
      presentationProjection?._beginOwnTransition(
        _compressionProjectionFromAuthority(receipt.destination),
      );
      final infoChanged = snapshot.info != _desktopRuntimeInfo;

      if (snapshot.storedSessionId != durableId &&
          snapshot.storedSessionIdProvenance ==
              DesktopStoredSessionIdProvenance.requestedFallback) {
        return null;
      }
      final acceptedDurableId = snapshot.storedSessionId;
      _recordDurablePrivateTranscriptVetoes(snapshot.messages);
      final coverage = !snapshot.messagesProvided
          ? TranscriptPrivacyCoverage.omitted
          : snapshot.messagesFullyParsed &&
                snapshot.messageCount == snapshot.messages.length
          ? TranscriptPrivacyCoverage.complete
          : TranscriptPrivacyCoverage.partial;
      final checkpoint = _transcriptPublication.checkpoint(
        connectionId: connection.id,
        profile: privacyProfile,
        storedSessionId: acceptedDurableId,
        coverage: coverage,
      );
      if (snapshot.messages.any((message) => !message.publiclyRenderable)) {
        if (!acquisitionStillAuthorized()) return reusableReceipt();
        final beforeSave = _beforePrivacyCheckpointSave;
        if (beforeSave != null) {
          await beforeSave();
          if (!acquisitionStillAuthorized()) return reusableReceipt();
        }
        await LocalTranscriptStore.savePrivacyCheckpoint(
          connection.id,
          acceptedDurableId,
          checkpoint,
          profile: privacyProfile,
          lifecycle: _localConversationLifecycle,
        );
        if (!acquisitionStillAuthorized()) return reusableReceipt();
      }
      if (!acquisitionStillAuthorized() ||
          !privacyCheckpointStillAuthorized() ||
          (_storedSessionProfile.isEmpty ? 'default' : _storedSessionProfile) !=
              privacyProfile) {
        return reusableReceipt();
      }
      if (snapshot.messagesProvided) {
        _captureArtifactMessages(
          snapshot.messages,
          logicalSessionId: logicalSessionId,
        );
      }
      _desktopStoredSessionId = snapshot.storedSessionId;
      _rebaseSubagentActivityScope(
        snapshot.runtimeSessionId,
        reconnectEvidence: snapshot,
      );
      _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
      _hydrateAgentTasks(snapshot.todoState);
      _desktopRuntimeBindingOrigin = snapshot.created
          ? _DesktopRuntimeBindingOrigin.consoleOwned
          : bindingOrigin;
      _desktopStoredSessionKnownMissing = false;
      _desktopRuntimeInfo = snapshot.info;
      _rememberDesktopLiveStatus(snapshot.status, running: snapshot.running);
      _desktopStartedAt = snapshot.startedAt;
      _desktopTurnStartedAt = snapshot.running
          ? snapshot.resolvedTurnStartedAt
          : null;
      if (snapshot.running) {
        _usingDesktopGateway = true;
        _runTerminal = false;
        state = snapshot.inflight?.assistant?.isNotEmpty == true
            ? ChatPipelineState.streaming
            : ChatPipelineState.executing;
      }
      if (!receipt.destination.sameCoordinates(
        _desktopCompressionAuthorityState,
      )) {
        return null;
      }
      if (receipt.provenance !=
          DesktopCompressionReceiptProvenance.testingOnlyUnownedSnapshot) {
        _validatedDesktopAcquisition = receipt;
      }
      presentationProjection?._acceptOwn();

      // All destinations are fixed before callbacks. A callback can invalidate
      // admission, but can never be recaptured as authority for this operation.
      _restorePendingClarify(snapshot);
      _restorePendingApproval(snapshot, expectedGeneration: approvalGeneration);
      if (infoChanged || snapshot.info != const DesktopSessionRuntimeInfo()) {
        _emit(ActiveChatEvent.sessionInfo);
      }
      if (receipt.provenance ==
          DesktopCompressionReceiptProvenance.testingOnlyUnownedSnapshot) {
        // Preserve the public adapter's rejection of an advertised foreign
        // root even when its testing snapshot was adopted for inspection.
        return snapshot.lineageRootId == null ||
                snapshot.lineageRootId == token.expectedRootId
            ? receipt
            : null;
      }
      return receipt.canAuthorize(token, _desktopCompressionAuthorityState)
          ? receipt
          : null;
    } on TuiGatewayRpcError catch (error) {
      if (error.code == 4007 || error.code == -32601) return null;
      rethrow;
    }
  }

  /// Loads the authenticated 0.19 catalog for this live session without ever
  /// creating a runtime. Drafts and legacy servers return `null` so the caller
  /// can use its existing Dashboard/Bridge read-only fallback.
  Future<DesktopModelCatalog?> loadDesktopModelCatalog({
    bool refresh = false,
  }) async {
    if (!await ensureDesktopRuntime()) return null;
    final gateway = _desktopGateway;
    final runtimeId = _desktopRuntimeSessionId;
    if (gateway is! HermesDesktopModelCatalogGateway || runtimeId == null) {
      return null;
    }
    final catalogGateway = gateway as HermesDesktopModelCatalogGateway;
    try {
      return await catalogGateway.modelOptions(runtimeId, refresh: refresh);
    } on TuiGatewayRpcError catch (error) {
      if (error.code == 4007 || error.code == -32601) return null;
      rethrow;
    }
  }

  /// Pide el desglose bajo demanda, igual que el panel de Hermes Desktop.
  ///
  /// Nunca crea una sesión: un draft o un servidor anterior a 0.19 devuelve
  /// `null` y la UI conserva el resumen de `session.info`.
  Future<DesktopContextBreakdown?> loadDesktopContextBreakdown() async {
    if (!await ensureDesktopRuntime()) return null;
    final gateway = _desktopGateway;
    final runtimeId = _desktopRuntimeSessionId;
    if (gateway is! HermesDesktopContextUsageGateway || runtimeId == null) {
      return null;
    }
    final contextGateway = gateway as HermesDesktopContextUsageGateway;
    try {
      final result = await contextGateway.contextBreakdown(runtimeId);
      if (_disposed || _desktopRuntimeSessionId != runtimeId) return null;
      return result;
    } on TuiGatewayRpcError catch (error) {
      if (error.code == 4007 || error.code == -32601) return null;
      rethrow;
    }
  }

  BotMentionResolver get mentionResolver => BotMentionRoster.shared.resolver(
    connection.id,
    sessionProfile.isEmpty ? 'default' : sessionProfile,
  );

  Future<void>? _mentionRosterLoad;
  Future<void> loadMentionRoster() {
    if (BotMentionRoster.shared.contains(connection.id)) return Future.value();
    return _mentionRosterLoad ??= _loadMentionRoster();
  }

  Future<void> _loadMentionRoster() async {
    final rosterGeneration = BotMentionRoster.shared.generation(connection.id);
    try {
      final gateway = _desktopGateway;
      if (gateway is! BotMentionRosterGateway) return;
      final profiles = await (gateway as BotMentionRosterGateway)
          .loadMentionProfiles();
      if (!_disposed) {
        BotMentionRoster.shared.replace(
          connection.id,
          connection.label,
          profiles,
          expectedGeneration: rosterGeneration,
        );
      }
    } catch (_) {
      // A cold/unavailable roster must never block ordinary chat admission.
    } finally {
      _mentionRosterLoad = null;
    }
  }

  /// Catálogo vivo del mismo Gateway que usa Hermes Desktop. No crea sesión.
  Future<DesktopCommandCatalog?> loadDesktopCommandCatalog() async {
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopCommandGateway) return null;
    try {
      return await (gateway as HermesDesktopCommandGateway).commandsCatalog();
    } on TuiGatewayRpcError catch (error) {
      if (error.code == -32601) return null;
      rethrow;
    }
  }

  /// Completion efímera. El llamador debe resolver de nuevo contra catálogo o
  /// comando nativo antes de ejecutar; una suggestion nunca concede capability.
  Future<SlashCompletionBatch?> completeDesktopSlash(String text) async {
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopCommandGateway) return null;
    try {
      return await (gateway as HermesDesktopCommandGateway).completeSlash(text);
    } on TuiGatewayRpcError catch (error) {
      if (error.code == -32601) return null;
      rethrow;
    }
  }

  /// Ejecuta un comando publicado sin convertirlo jamás en prompt ordinario.
  Future<DesktopCommandRpcResult> executeDesktopSlash(
    String name, {
    String arg = '',
  }) => _trackRuntimeMutation(() => _executeDesktopSlash(name, arg: arg));

  Future<DesktopCommandRpcResult> _executeDesktopSlash(
    String name, {
    String arg = '',
  }) async {
    if (mutationsBlockedByOwnershipConflict) {
      throw _ownershipConflictError('slash.exec');
    }
    if (connection.readOnly) {
      throw const TuiGatewayRpcError(
        'slash.exec',
        'Remote commands are unavailable in read-only mode',
        code: 403,
      );
    }
    final canonical = CommandDescriptor.tryNormalizeName(name);
    if (canonical == null ||
        canonical == 'compact' ||
        canonical == 'compress') {
      throw const TuiGatewayRpcError(
        'slash.exec',
        'Command requires a dedicated Console adapter',
        code: 4004,
      );
    }
    late final String argument;
    try {
      argument = CommandArgumentSpec(
        kind: CommandArgumentKind.freeText,
        maxLength: 500,
      ).validate(arg);
    } on FormatException {
      throw const TuiGatewayRpcError(
        'slash.exec',
        'Invalid command argument',
        code: 4004,
      );
    }
    if (!await ensureDesktopRuntime(acquireForExplicitAction: true)) {
      throw const TuiGatewayRpcError(
        'slash.exec',
        'No live runtime is available for this command',
        code: 4007,
      );
    }
    final gateway = _desktopGateway;
    final runtimeId = _desktopRuntimeSessionId;
    if (gateway is! HermesDesktopCommandGateway || runtimeId == null) {
      throw const TuiGatewayRpcError(
        'slash.exec',
        'Desktop command dispatch is unsupported',
        code: -32601,
      );
    }
    final command = argument.isEmpty ? canonical : '$canonical $argument';
    return (gateway as HermesDesktopCommandGateway).slashExec(
      runtimeId,
      command,
    );
  }

  DesktopCompressionFenceScope get _desktopCompressionFenceScope =>
      DesktopCompressionFenceScope(
        connectionId: connection.id,
        profile: Session.profileOwner(
          _sessionProfileOwner,
          fallback: _storedSessionProfile,
        ),
        logicalSessionId: logicalSessionId,
      );

  Future<void> _restoreDurableCompressionFence() async {
    final lookup = await _compressionFenceStore.lookup(
      _desktopCompressionFenceScope,
    );
    if (_disposed || !lookup.isFenced) return;
    final record = lookup.record;
    if (record == null) {
      _desktopCompressionInFlight = true;
      if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
      return;
    }
    _durableCompressionFence = record;
    _desktopCompressionInFlight = true;
    _desktopCompactionStartedAt ??= DateTime.fromMillisecondsSinceEpoch(
      record.createdAtMs,
    );
    if (await _reconcileDurableCompressionFence(record)) return;
    if (await _releaseExpiredDurableCompressionFence(record)) return;
    _scheduleDurableCompressionReconciliation(
      _durableCompressionFence ?? record,
    );
    if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
  }

  Future<bool> _hasUnresolvedDurableCompressionFence({
    DesktopCompressionFenceScope? capturedScope,
    bool Function()? stillAuthorized,
  }) async {
    final lookup = await _compressionFenceStore.lookup(
      capturedScope ?? _desktopCompressionFenceScope,
    );
    if (stillAuthorized != null && !stillAuthorized()) return true;
    if (lookup.status == DesktopCompressionFenceLookupStatus.absent) {
      _durableCompressionFence = null;
      if (_pendingDesktopCompression == null) {
        _desktopCompressionInFlight = false;
      }
      return false;
    }
    final record = lookup.record;
    _desktopCompressionInFlight = true;
    if (record == null) return true;
    _durableCompressionFence = record;
    _desktopCompactionStartedAt ??= DateTime.fromMillisecondsSinceEpoch(
      record.createdAtMs,
    );
    if (await _reconcileDurableCompressionFence(record)) return false;
    if (await _releaseExpiredDurableCompressionFence(record)) return false;
    _scheduleDurableCompressionReconciliation(
      _durableCompressionFence ?? record,
    );
    return true;
  }

  /// An unproven fence past its deadline stops holding anything: the
  /// composer, Home/Conversaciones and runtime attach behave like Hermes
  /// Desktop (which has no fence at all) and a dismissible notice says the
  /// result could not be confirmed. The server's own compression lock still
  /// refuses a conflicting turn with 4009.
  Future<bool> _releaseExpiredDurableCompressionFence(
    DesktopCompressionFenceRecord record, {
    bool deadlineReached = false,
  }) async {
    if (!deadlineReached && record.reconcileUntilMs > _wallClockMs()) {
      return false;
    }
    if (_durableCompressionFence?.scope.key != record.scope.key ||
        _durableCompressionFence?.attemptId != record.attemptId) {
      return false;
    }
    _desktopCompressionReconciliationTimer?.cancel();
    _desktopCompressionReconciliationTimer = null;
    final released = await _deleteDurableCompressionFence(
      record,
      unconfirmed: true,
    );
    if (!released) {
      // Storage refused the delete: keep failing closed, but say so.
      _desktopCompressionUnconfirmable = true;
      if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
    }
    return released;
  }

  Future<bool> _reconcileDurableCompressionFence(
    DesktopCompressionFenceRecord record,
  ) async {
    try {
      Future<Map<String, dynamic>?> readRow(String id) async {
        try {
          return await _api
              .apiGet(
                ApiClient.profileEndpoint(
                  'api/sessions/${Uri.encodeComponent(id)}',
                  profile: record.scope.profile,
                ),
              )
              .timeout(_desktopCompressionReconcileRpcBudget);
        } catch (_) {
          return null;
        }
      }

      var evidence = const DesktopCompressionFenceEvidence.none();
      int? messagesNow;
      void observe(Map<String, dynamic>? response) {
        if (response == null) return;
        if (!evidence.provesSettlement) {
          evidence = DesktopCompressionFenceEvidence.evaluate(record, response);
        }
        final wrapped = response['session'];
        final row = wrapped is Map ? wrapped : response;
        final count = row['message_count'];
        if (row['id'] == record.tipAtStart && count is int && count >= 0) {
          messagesNow = count;
        }
      }

      observe(await readRow(record.scope.logicalSessionId));
      if (_disposed) return false;
      if (!evidence.provesSettlement &&
          record.messagesAtStart != null &&
          record.tipAtStart != record.scope.logicalSessionId) {
        // In-place compaction shrinks the tip row, not the lineage root.
        observe(await readRow(record.tipAtStart));
        if (_disposed) return false;
      }
      var changed = evidence.provesSettlement;
      if (!evidence.provesSettlement) {
        // Nothing durable changed: the attempt may have been refused, found
        // nothing to compress, or still be running. Ask the gateway whether
        // the runtime that ran it is still pinned "compressing".
        if (await _compressionReplayVerdict(record) !=
            DesktopCompressionReplayVerdict.finished) {
          return false;
        }
        if (_disposed) return false;
        changed = false;
      }
      final tip = evidence.authoritativeTip;
      final deleted = await _deleteDurableCompressionFence(record);
      if (!deleted || _disposed) return deleted;
      _restoredCompressionOutcome = (
        changed: changed,
        messagesBefore: record.messagesAtStart,
        messagesAfter: messagesNow,
      );
      _emit(ActiveChatEvent.sessionInfo);
      if (tip != null) _desktopStoredSessionId = tip;
      final hydrationStoredId = serverSessionId;
      final loadEpoch = ++_messageLoadEpoch;
      final authority = _compressionProjectionAuthority;
      await _loadMessagesWhileCompressionFenced(
        loadEpoch,
        forceStoredDisplay: true,
        stillAuthorized: () =>
            authority == _compressionProjectionAuthority &&
            serverSessionId == hydrationStoredId,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Read-only `session.events.since` probe of the runtime that ran the
  /// attempt (never `session.resume`: it cannot steal another client's
  /// transport). See [DesktopCompressionReplayVerdict].
  Future<DesktopCompressionReplayVerdict> _compressionReplayVerdict(
    DesktopCompressionFenceRecord record,
  ) async {
    final runtime = record.runtimeAtStart;
    final gateway = _desktopGateway;
    if (runtime == null ||
        gateway == null ||
        gateway is! HermesDesktopCompressionStatusGateway ||
        record.scope.connectionId != connection.id) {
      return DesktopCompressionReplayVerdict.unknown;
    }
    try {
      await gateway.connect().timeout(_desktopCompressionReconcileRpcBudget);
      final result = await (gateway as HermesDesktopCompressionStatusGateway)
          .compressionEventReplay(runtime)
          .timeout(_desktopCompressionReconcileRpcBudget);
      return DesktopCompressionReplayVerdict.evaluate(result);
    } catch (_) {
      return DesktopCompressionReplayVerdict.unknown;
    }
  }

  ({bool changed, int? messagesBefore, int? messagesAfter})?
  _restoredCompressionOutcome;

  /// Outcome of a compression this process only learned about after the
  /// fact (fence restored after a kill, settled by the server's state). The
  /// chat shows it once, like the RPC outcome notice.
  ({bool changed, int? messagesBefore, int? messagesAfter})?
  takeRestoredCompressionOutcome() {
    final outcome = _restoredCompressionOutcome;
    _restoredCompressionOutcome = null;
    return outcome;
  }

  Future<bool> _deleteDurableCompressionFence(
    DesktopCompressionFenceRecord record, {
    bool unconfirmed = false,
  }) async {
    final deleted = await _compressionFenceStore.deleteAttempt(
      record.scope,
      attemptId: record.attemptId,
    );
    if (!deleted) {
      final authority = await _compressionFenceStore.lookup(record.scope);
      if (authority.record case final current?) {
        _durableCompressionFence = current;
        if (_pendingDesktopCompression?.durableRecord.attemptId !=
            current.attemptId) {
          _pendingDesktopCompression = null;
          _scheduleDurableCompressionReconciliation(current);
        }
      }
      _desktopCompressionInFlight = true;
      return false;
    }
    if (_durableCompressionFence?.scope.key == record.scope.key &&
        _durableCompressionFence?.attemptId == record.attemptId) {
      _durableCompressionFence = null;
    }
    if (_pendingDesktopCompression?.durableRecord.scope.key ==
            record.scope.key &&
        _pendingDesktopCompression?.durableRecord.attemptId ==
            record.attemptId) {
      _pendingDesktopCompression = null;
    }
    if (_durableCompressionFence == null &&
        _pendingDesktopCompression == null) {
      _desktopCompressionReconciliationTimer?.cancel();
      _desktopCompressionReconciliationTimer = null;
      // A clean delete with nothing else outstanding is a real settle: any
      // earlier "couldn't confirm" from a previous attempt no longer applies.
      // An expired, unproven release keeps (or raises) that notice instead.
      _desktopCompressionUnconfirmable = unconfirmed;
    }
    _desktopCompressionInFlight =
        _durableCompressionFence != null || _pendingDesktopCompression != null;
    if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
    return true;
  }

  void _scheduleDurableCompressionReconciliation(
    DesktopCompressionFenceRecord record,
  ) {
    _desktopCompressionReconciliationTimer?.cancel();
    final remainingMs = record.reconcileUntilMs - _wallClockMs();
    if (remainingMs <= 0) {
      _desktopCompressionReconciliationTimer = null;
      // Giving up polling silently (the previous behavior here) left the UI
      // saying "still working" forever once the deadline passed — including
      // right after reopening the app on a session whose fence had already
      // expired while it was closed. Say so instead.
      unawaited(_releaseExpiredDurableCompressionFence(record));
      return;
    }
    final delayMs = math.min(
      remainingMs,
      _desktopCompressionReconciliationDelay.inMilliseconds,
    );
    _desktopCompressionReconciliationTimer = Timer(
      Duration(milliseconds: delayMs),
      () async {
        if (_disposed ||
            _durableCompressionFence?.attemptId != record.attemptId) {
          return;
        }
        if (await _reconcileDurableCompressionFence(record)) return;
        _scheduleDurableCompressionReconciliation(record);
      },
    );
  }

  /// Comprime mediante `session.compress`, el contrato autoritativo actual de
  /// Hermes Desktop. Solo un Gateway antiguo que responda `method not found`
  /// degrada a `slash.exec`/`command.dispatch`.
  ///
  /// No existe fallback local: recortar mensajes en el móvil desalinearía el
  /// historial visible del que realmente usa el agente.
  Future<DesktopCommandDispatch> compressDesktopSession({
    String focusTopic = '',
  }) => _trackRuntimeMutation(
    () => _compressDesktopSession(focusTopic: focusTopic),
  );

  _CompressionProjectionAuthority _compressionProjectionFromAuthority(
    DesktopCompressionAuthorityState authority,
  ) => (
    disposed: authority.disposed,
    runtime: authority.runtimeSessionId,
    stored: authority.storedSessionId,
    profile: authority.wireProfile,
    bind: authority.bindEpoch,
    session: authority.sessionEpoch,
    load: authority.messageLoadEpoch,
    tombstones: authority.tombstoneRevision,
  );

  _CompressionProjectionAuthority get _compressionProjectionAuthority =>
      _compressionProjectionFromAuthority(_desktopCompressionAuthorityState);

  _CompressionProjectionAuthority _compressionOwnDestination({
    required String runtimeId,
    required String? storedId,
    required bool adoptRuntime,
    bool hydrate = false,
  }) {
    final before = _desktopCompressionAuthorityState;
    final retires =
        adoptRuntime &&
        _desktopRuntimeNeedsAdoption(
          runtimeId,
          storedId ?? _serverSessionOverride ?? sessionId,
        );
    final destination = DesktopCompressionAuthorityState(
      activeChatIdentity: before.activeChatIdentity,
      connectionIdentity: before.connectionIdentity,
      gatewayIdentity: before.gatewayIdentity,
      disposed: before.disposed,
      profileOwnerBound: before.profileOwnerBound,
      wireProfile: before.wireProfile,
      storedSessionId: storedId,
      runtimeSessionId: runtimeId,
      bindEpoch: before.bindEpoch + (retires ? 1 : 0),
      sessionEpoch: before.sessionEpoch + (retires ? 2 : 0),
      messageLoadEpoch: before.messageLoadEpoch + (hydrate ? 1 : 0),
      tombstoneRevision: before.tombstoneRevision,
    );
    return _compressionProjectionFromAuthority(destination);
  }

  Future<DesktopCompressionPresentation> compressDesktopSessionForPresentation({
    String focusTopic = '',
  }) => _trackRuntimeMutation(
    () => _compressDesktopSessionForPresentation(focusTopic: focusTopic),
  );

  Future<DesktopCompressionPresentation>
  _compressDesktopSessionForPresentation({String focusTopic = ''}) async {
    final projection = DesktopCompressionProjection._(
      () => _compressionProjectionAuthority,
    );
    try {
      final command = await _compressDesktopSession(
        focusTopic: focusTopic,
        presentationProjection: projection,
      );
      return DesktopCompressionPresentation._(projection, command: command);
    } catch (error) {
      return DesktopCompressionPresentation._(projection, failure: error);
    }
  }

  Future<DesktopCommandDispatch> _compressDesktopSession({
    required String focusTopic,
    DesktopCompressionProjection? presentationProjection,
  }) async {
    if (mutationsBlockedByOwnershipConflict) {
      throw _ownershipConflictError('session.compress');
    }
    // This token is the operation's intent. Nothing that follows an await may
    // reconstruct it from mutable ActiveChat state.
    final token = _captureDesktopCompressionAuthority();
    var authority = token.begin(_desktopCompressionAuthorityState);
    bool preparationStillAuthorized() =>
        authority?.matches(_desktopCompressionAuthorityState) == true;

    if (authority == null ||
        await _hasUnresolvedDurableCompressionFence(
          capturedScope: _fenceScopeForAuthority(token),
          stillAuthorized: preparationStillAuthorized,
        )) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'Session compression requires authoritative reconciliation',
        code: 4009,
      );
    }
    if (!authority.matches(_desktopCompressionAuthorityState)) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'Session compression authority expired',
        code: 4009,
      );
    }
    void prepareOwnTombstoneRevision(int nextRevision) {
      final planned = authority?.prepareOwnTombstoneRevision(
        _desktopCompressionAuthorityState,
        nextRevision,
      );
      if (planned == null) throw StateError('compression authority expired');
      presentationProjection?._beginOwnTransition(
        _compressionProjectionFromAuthority(planned.destination),
      );
      authority = planned;
    }

    void acceptOwnTombstoneRevision() {
      if (authority?.matches(_desktopCompressionAuthorityState) != true) {
        throw StateError('compression authority expired');
      }
      presentationProjection?._acceptOwn();
    }

    try {
      _bindTombstonesToDurableIds(
        _messages,
        incomingTranscriptComplete: _transcriptIsComplete,
        beforeOwnRevision: prepareOwnTombstoneRevision,
        afterOwnRevision: acceptOwnTombstoneRevision,
      );
      if (_cancelledTurnTombstones.any(
        (tombstone) => !tombstone.invalidated && !tombstone.hasTargetIdentity,
      )) {
        final completeTranscript = await _loadStoredMessages(
          token.initialState.wireProfile,
        );
        if (!authority!.matches(_desktopCompressionAuthorityState)) {
          throw StateError('compression authority expired');
        }
        _bindTombstonesToDurableIds(
          _normalizedNewestFirst(completeTranscript),
          incomingTranscriptComplete: true,
          beforeOwnRevision: prepareOwnTombstoneRevision,
          afterOwnRevision: acceptOwnTombstoneRevision,
        );
      }
      if (_cancelledTurnTombstones.any(
        (tombstone) => !tombstone.invalidated && !tombstone.hasTargetIdentity,
      )) {
        throw StateError('cancelled turn identity is still ambiguous');
      }
      await _flushPendingCancelledTombstoneUpdates();
      if (!authority!.matches(_desktopCompressionAuthorityState)) {
        throw StateError('compression authority expired');
      }
    } catch (_) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'Cancelled turn metadata is not durable yet',
        code: 4009,
      );
    }
    if (connection.readOnly) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'Session compression is unavailable in read-only mode',
        code: 403,
      );
    }
    if (isStreaming ||
        _messageQueue.isNotEmpty ||
        needsInput ||
        desktopCompressionInFlight) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'Session is busy',
        code: 4009,
      );
    }
    if (!authority!.matches(_desktopCompressionAuthorityState)) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'Session compression authority expired',
        code: 4009,
      );
    }
    final gateway = token.initialState.gatewayIdentity;
    if (gateway is! HermesDesktopGateway ||
        (gateway is! HermesDesktopCompressionGateway &&
            gateway is! HermesDesktopCommandGateway)) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'Session compression is unsupported by this connection',
        code: -32601,
      );
    }

    final receipt = await _acquireDesktopRuntime(
      authority!,
      presentationProjection: presentationProjection,
    );
    if (receipt == null ||
        !receipt.canAuthorize(token, _desktopCompressionAuthorityState)) {
      throw const TuiGatewayRpcError(
        'session.compress',
        'No live runtime is available for session compression',
        code: 4007,
      );
    }

    final runtimeId = receipt.runtimeSessionId;
    final connectionEpoch = receipt.destination.bindEpoch;
    final sessionEpoch = receipt.destination.sessionEpoch;
    final compressionMessageLoadEpoch = receipt.destination.messageLoadEpoch;
    final compressionTombstoneRevision = receipt.destination.tombstoneRevision;
    final fenceScope = DesktopCompressionFenceScope(
      connectionId: receipt.scope.connectionId,
      profile: receipt.scope.profile,
      logicalSessionId: receipt.scope.logicalSessionId,
    );
    bool compressionFenceStillValid() =>
        receipt.canAuthorize(token, _desktopCompressionAuthorityState);
    bool compressionResultMatchesAuthorityRoot(
      DesktopCompressionResult compression,
    ) => _compressionResultMatchesExpectedRoot(
      compression,
      token.expectedRootId,
    );

    final messagesAtStart = await _storedMessageCountForFence(
      receipt.storedSessionId,
      profile: receipt.scope.profile,
    );
    final createdAtMs = _wallClockMs();
    final arm = await _compressionFenceStore.arm(
      fenceScope,
      tipAtStart: receipt.storedSessionId,
      compressionsAtStart: receipt.evidence.compressionsAtStart,
      messagesAtStart: messagesAtStart,
      runtimeAtStart: runtimeId,
      createdAtMs: createdAtMs,
      reconcileUntilMs:
          createdAtMs + _desktopCompressionReconciliationWindow.inMilliseconds,
    );
    final durableRecord = arm.lookup.record;
    if (!arm.claimed ||
        durableRecord == null ||
        !compressionFenceStillValid()) {
      _desktopCompressionInFlight = arm.lookup.isFenced;
      if (durableRecord != null) _durableCompressionFence = durableRecord;
      if (arm.claimed && durableRecord != null) {
        await _deleteDurableCompressionFence(durableRecord);
      }
      throw const TuiGatewayRpcError(
        'session.compress',
        'Compression fence could not be persisted',
        code: 4009,
      );
    }
    _durableCompressionFence = durableRecord;
    if (!desktopCompressionInFlight) {
      _desktopCompactionStartedAt = DateTime.now();
      _desktopCompactionTokensBefore = null;
      _desktopCompactionMessagesBefore = null;
      _desktopCompactionChunkIndex = null;
      _desktopCompactionChunkCount = null;
      _desktopCompressionUnconfirmable = false;
    }
    _desktopCompressionInFlight = true;
    _emit(ActiveChatEvent.sessionInfo);
    if (!compressionFenceStillValid()) {
      await _deleteDurableCompressionFence(durableRecord);
      throw const TuiGatewayRpcError(
        'session.compress',
        'Compression authority expired before dispatch',
        code: 4009,
      );
    }
    _desktopCompressionRpcInFlight = true;
    presentationProjection?.dispatchAttempted = true;
    try {
      final dispatch = await CompressionDispatcher(gateway).dispatch(
        runtimeId,
        focusTopic: focusTopic,
        connectionEpoch: connectionEpoch,
        sessionEpoch: sessionEpoch,
        stillValid: compressionFenceStillValid,
        matchesRoot: compressionResultMatchesAuthorityRoot,
      );
      final outcome = dispatch.evidence.outcome;
      final compression = dispatch.evidence.nativeResult;
      if (outcome.resolvesAttempt) {
        final deleted = await _deleteDurableCompressionFence(durableRecord);
        if (deleted &&
            compression != null &&
            outcome == DesktopCompressionOutcome.settled &&
            compressionFenceStillValid()) {
          final storedId =
              compression.info?.storedSessionId ?? receipt.storedSessionId;
          presentationProjection?._beginOwnTransition(
            _compressionOwnDestination(
              runtimeId: runtimeId,
              storedId: storedId,
              adoptRuntime: storedId != receipt.storedSessionId,
              hydrate: false,
            ),
          );
          _applyNativeCompressionResult(
            compression,
            runtimeId,
            expectedMessageLoadEpoch: compressionMessageLoadEpoch,
            expectedTombstoneRevision: compressionTombstoneRevision,
          );
          presentationProjection?._acceptOwn();
        }
      } else if (compressionFenceStillValid() &&
          outcome != DesktopCompressionOutcome.ownershipLost) {
        await _beginPendingDesktopCompression(
          durableRecord: durableRecord,
          runtimeId: runtimeId,
          connectionEpoch: connectionEpoch,
          sessionEpoch: sessionEpoch,
          cause: outcome == DesktopCompressionOutcome.acceptedPending
              ? _DesktopCompressionPendingCause.serverPending
              : _DesktopCompressionPendingCause.ambiguousTransport,
        );
      }
      if (dispatch.error case final error?) throw error;
      return dispatch.command ??
          _nativeCompressionDispatch(
            compression!,
            runtimeId: runtimeId,
            focusTopic: focusTopic,
            connectionEpoch: connectionEpoch,
            sessionEpoch: sessionEpoch,
          );
    } finally {
      // Only durable resolution can release the fence, never UI generation.
      _desktopCompressionRpcInFlight = false;
      if (_durableCompressionFence == null && !_desktopCompressionInFlight) {
        _clearDesktopCompactingIndicator();
      }
      if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
    }
  }

  /// Stored `message_count` of the exact row about to be compressed: the
  /// baseline that lets a later REST read prove an in-place compaction that
  /// this process never heard back about (killed app, lost transport).
  Future<int?> _storedMessageCountForFence(
    String storedSessionId, {
    required String profile,
  }) async {
    try {
      final response = await _api
          .apiGet(
            ApiClient.profileEndpoint(
              'api/sessions/${Uri.encodeComponent(storedSessionId)}',
              profile: profile,
            ),
          )
          .timeout(_desktopCompressionReconcileRpcBudget);
      final wrapped = response['session'];
      final row = wrapped is Map ? wrapped : response;
      final count = row['message_count'];
      return row['id'] == storedSessionId && count is int && count >= 0
          ? count
          : null;
    } catch (_) {
      // No baseline only means a lost reply falls back to the deadline.
      return null;
    }
  }

  DesktopCommandDispatch _nativeCompressionDispatch(
    DesktopCompressionResult compression, {
    required String runtimeId,
    required String focusTopic,
    required int connectionEpoch,
    required int sessionEpoch,
  }) {
    final disposition = compression.outcome;
    final acceptance = switch (disposition) {
      DesktopCompressionStatus.compressed => DesktopCommandAcceptance.accepted,
      DesktopCompressionStatus.noOp => DesktopCommandAcceptance.accepted,
      DesktopCompressionStatus.aborted ||
      DesktopCompressionStatus.lockHeld => DesktopCommandAcceptance.rejected,
      DesktopCompressionStatus.pending => DesktopCommandAcceptance.unknown,
    };
    final failure = switch (disposition) {
      DesktopCompressionStatus.aborted => const CommandFailure(
        kind: CommandFailureKind.remote,
        retryable: false,
      ),
      DesktopCompressionStatus.lockHeld => const CommandFailure(
        kind: CommandFailureKind.conflict,
        code: 4009,
        retryable: false,
      ),
      _ => null,
    };
    return DesktopCommandDispatch(
      commandName: 'compress',
      arg: focusTopic.trim(),
      sessionId: runtimeId,
      connectionEpoch: connectionEpoch,
      sessionEpoch: sessionEpoch,
      attemptedRoute: DesktopCommandRoute.sessionCompress,
      fallbackUsed: false,
      dispatchKind: DesktopCommandDispatchKind.none,
      accepted: acceptance,
      failure: failure,
      compressionStatus: disposition,
      compressionResult: compression,
    );
  }

  void _applyNativeCompressionResult(
    DesktopCompressionResult compression,
    String runtimeId, {
    required int expectedMessageLoadEpoch,
    required int expectedTombstoneRevision,
  }) {
    if (!compression.isTerminal ||
        _disposed ||
        expectedMessageLoadEpoch != _messageLoadEpoch ||
        expectedTombstoneRevision != _cancelledTombstoneRevision ||
        _desktopRuntimeSessionId != runtimeId) {
      return;
    }
    final info = compression.info;
    final compressedStoredId = info?.storedSessionId;
    if (compressedStoredId != null && compressedStoredId.isNotEmpty) {
      final storedIdentityChanged =
          compressedStoredId != _desktopStoredSessionId;
      _desktopStoredSessionId = compressedStoredId;
      if (storedIdentityChanged) _adoptDesktopRuntime(runtimeId);
    }
    if (info != null) _desktopRuntimeInfo = info;
    final compressionUsage = compression.usage;
    if (compressionUsage != null) {
      _desktopRuntimeInfo = _desktopRuntimeInfo.withUsage(compressionUsage);
    }
    _desktopTurnStartedAt = null;
    if (info != null) _observeSessionConfigInfo(info);

    final authoritativeMessages = compression.messages;
    final currentContextMessageCount = _messages.where((message) {
      final role = message['role'];
      return (role == 'user' || role == 'assistant') &&
          (message['display_kind'] ?? '').toString().isEmpty &&
          (message['content'] as String?)?.trim().isNotEmpty == true;
    }).length;
    final completeTerminalTranscript =
        compression.outcome == DesktopCompressionStatus.compressed &&
        compression.beforeMessages == currentContextMessageCount &&
        compressedStoredId != null &&
        compressedStoredId.isNotEmpty &&
        authoritativeMessages != null &&
        authoritativeMessages.isNotEmpty &&
        compression.afterMessages != null &&
        authoritativeMessages.length == compression.afterMessages &&
        _desktopSnapshotIdentitiesAreUnambiguous(authoritativeMessages) &&
        !compression.hasFilteredTranscript;
    if (completeTerminalTranscript) {
      const reconciler = DesktopSessionReconciler();
      _messages = reconciler
          .project(
            DesktopSessionSnapshot(
              runtimeSessionId: runtimeId,
              storedSessionId: compressedStoredId,
              created: false,
              messages: authoritativeMessages,
              messagesProvided: true,
              messagesFullyParsed: true,
              messageCount: compression.afterMessages,
              info: info ?? const DesktopSessionRuntimeInfo(),
            ),
          )
          .messagesNewestFirst
          .toList(growable: true);
      _markTranscriptComplete(visibleCount: _messages.length);
    }

    if (compression.outcome == DesktopCompressionStatus.compressed ||
        compression.outcome == DesktopCompressionStatus.noOp) {
      _publishCompressionOutcome(compression);
    }
    _emit(ActiveChatEvent.sessionInfo);
  }

  void _publishCompressionOutcome(DesktopCompressionResult compression) {
    final beforeMessages = compression.beforeMessages;
    final afterMessages = compression.afterMessages;
    final beforeTokens = compression.beforeTokens;
    final afterTokens = compression.afterTokens;
    final removed = compression.removed;
    if (beforeMessages == null ||
        afterMessages == null ||
        beforeTokens == null ||
        afterTokens == null ||
        removed == null) {
      return;
    }
    _messages.removeWhere(
      (message) => message['display_kind'] == 'compression_result',
    );
    final noop = compression.outcome == DesktopCompressionStatus.noOp;
    final summaryHeadline = compression.summary?.headline?.trim();
    final summaryTokenLine = compression.summary?.tokenLine?.trim();
    final fallbackHeadline = noop
        ? 'Nothing to compress: $beforeMessages messages · ~$beforeTokens tokens'
        : 'Compressed: $beforeMessages → $afterMessages messages';
    final content = <String>[
      if (!noop && summaryHeadline?.isNotEmpty == true)
        summaryHeadline!
      else
        fallbackHeadline,
      if (!noop)
        if (summaryTokenLine?.isNotEmpty == true)
          summaryTokenLine!
        else
          'Approx request size: ~$beforeTokens → ~$afterTokens tokens',
    ].join('\n');
    _messages.insert(0, <String, dynamic>{
      'role': 'assistant',
      'content': content,
      'display_kind': 'compression_result',
      'display_metadata': <String, dynamic>{
        'noop': noop,
        'removed': removed,
        'before_messages': beforeMessages,
        'after_messages': afterMessages,
        'before_tokens': beforeTokens,
        'after_tokens': afterTokens,
      },
    });
  }

  bool _compressionResultMatchesExpectedRoot(
    DesktopCompressionResult compression,
    String? expectedRootId,
  ) {
    final info = compression.info;
    if (info == null) return true;
    final raw = info.raw;
    final advertisedRoot =
        raw['_lineage_root_id'] ??
        raw['lineage_root_id'] ??
        raw['lineage_root'];
    // A result may omit root after admission, but an advertised root must match
    // the immutable target restriction captured by this operation.
    if (advertisedRoot == null) return true;
    return expectedRootId != null &&
        advertisedRoot is String &&
        advertisedRoot == expectedRootId &&
        advertisedRoot == advertisedRoot.trim();
  }

  int? _compressionCountFromInfo(DesktopSessionRuntimeInfo info) {
    final value = info.usage?.raw['compressions'];
    return value is int && value >= 0 ? value : null;
  }

  DesktopCompressionFenceEvidence _pendingCompressionEvidence(
    _PendingDesktopCompression record,
    Map<String, dynamic> payload,
  ) => DesktopCompressionFenceEvidence.evaluate(record.durableRecord, payload);

  Future<void> _beginPendingDesktopCompression({
    required DesktopCompressionFenceRecord durableRecord,
    required String runtimeId,
    required int connectionEpoch,
    required int sessionEpoch,
    required _DesktopCompressionPendingCause cause,
  }) async {
    _desktopCompressionReconciliationTimer?.cancel();
    final reconcileUntilMs =
        _wallClockMs() + _desktopCompressionReconciliationWindow.inMilliseconds;
    final transitioned = await _compressionFenceStore.transitionAttempt(
      durableRecord.scope,
      attemptId: durableRecord.attemptId,
      phase: cause == _DesktopCompressionPendingCause.serverPending
          ? DesktopCompressionFencePhase.serverPending
          : DesktopCompressionFencePhase.transportUnknown,
      reconcileUntilMs: reconcileUntilMs,
    );
    if (transitioned == null) {
      final authority = await _compressionFenceStore.lookup(durableRecord.scope);
      final current = authority.record;
      _durableCompressionFence = current;
      _pendingDesktopCompression = null;
      _desktopCompressionInFlight = authority.isFenced;
      if (current != null) _scheduleDurableCompressionReconciliation(current);
      if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
      return;
    }
    final record = _PendingDesktopCompression(
      durableRecord: transitioned,
      runtimeSessionId: runtimeId,
      rootDurableId: transitioned.scope.logicalSessionId,
      bindEpoch: connectionEpoch,
      sessionEpoch: sessionEpoch,
      deadline: DateTime.fromMillisecondsSinceEpoch(
        transitioned.reconcileUntilMs,
      ),
      cause: cause,
    );
    _durableCompressionFence = transitioned;
    _pendingDesktopCompression = record;
    _desktopCompressionInFlight = true;
    _desktopCompressionReconciliationTimer = Timer(
      _desktopCompressionReconciliationDelay,
      () => unawaited(_reconcilePendingDesktopCompression(record)),
    );
    _emit(ActiveChatEvent.sessionInfo);
  }

  bool _isPendingDesktopCompressionCurrent(_PendingDesktopCompression record) =>
      !_disposed &&
      identical(_pendingDesktopCompression, record) &&
      _desktopRuntimeSessionId == record.runtimeSessionId &&
      _desktopBindEpoch == record.bindEpoch &&
      _desktopSessionEpoch == record.sessionEpoch;

  Future<void> _settlePendingDesktopCompression(
    _PendingDesktopCompression record,
    DesktopCompressionFenceEvidence evidence,
  ) async {
    if (!identical(_pendingDesktopCompression, record)) return;
    final tip = evidence.authoritativeTip;
    final deleted = await _deleteDurableCompressionFence(record.durableRecord);
    if (!deleted || _disposed) return;
    if (tip != null) _desktopStoredSessionId = tip;
    if (_desktopRuntimeSessionId != record.runtimeSessionId ||
        _desktopBindEpoch != record.bindEpoch ||
        _desktopSessionEpoch != record.sessionEpoch) {
      return;
    }
    final hydrationStoredId = serverSessionId;
    final loadEpoch = ++_messageLoadEpoch;
    final authority = _compressionProjectionAuthority;
    await _loadMessagesWhileCompressionFenced(
      loadEpoch,
      forceStoredDisplay: true,
      stillAuthorized: () =>
          authority == _compressionProjectionAuthority &&
          serverSessionId == hydrationStoredId,
    );
  }

  /// Releases an expired or retired suppression gate without treating the
  /// compression as complete. Authoritative settlement is reserved for the
  /// exact-root tip/counter evidence in [_settlePendingDesktopCompression].
  void _abandonPendingDesktopCompression([
    _PendingDesktopCompression? expected,
    // Only a genuine deadline expiry while actively reconciling counts as
    // "we tried and couldn't confirm". A runtime retirement/replacement
    // (e.g. `_retireDesktopRuntime`) abandons the local guard too, but that
    // is a bookkeeping reset, not a confirmed-unconfirmable result — it must
    // not surface the warning UI.
    bool unconfirmable = false,
  ]) {
    if (expected != null && !identical(_pendingDesktopCompression, expected)) {
      return;
    }
    _desktopCompressionReconciliationTimer?.cancel();
    _desktopCompressionReconciliationTimer = null;
    if (_pendingDesktopCompression == null) return;
    _pendingDesktopCompression = null;
    _desktopCompressionInFlight = _durableCompressionFence != null;
    if (unconfirmable) _desktopCompressionUnconfirmable = true;
    if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
    if (unconfirmable && expected != null) {
      unawaited(
        _releaseExpiredDurableCompressionFence(
          expected.durableRecord,
          deadlineReached: true,
        ),
      );
    }
  }

  Future<void> _reconcilePendingDesktopCompression(
    _PendingDesktopCompression record,
  ) async {
    if (!_isPendingDesktopCompressionCurrent(record)) return;
    final remainingAtReadStart = record.deadline.difference(
      DateTime.fromMillisecondsSinceEpoch(_wallClockMs()),
    );
    if (remainingAtReadStart <= Duration.zero) {
      _abandonPendingDesktopCompression(record, true);
      return;
    }
    final readBudget =
        remainingAtReadStart < _desktopCompressionReconcileRpcBudget
        ? remainingAtReadStart
        : _desktopCompressionReconcileRpcBudget;
    try {
      // This is deliberately a bounded REST metadata read. It never calls
      // `session.resume`, so observing a late compression cannot steal or
      // rebind another client's live transport.
      final response = await _api
          .apiGet(
            ApiClient.profileEndpoint(
              'api/sessions/${Uri.encodeComponent(record.rootDurableId)}',
              profile: _storedSessionProfile,
            ),
          )
          .timeout(readBudget);
      if (!_isPendingDesktopCompressionCurrent(record)) return;
      final evidence = _pendingCompressionEvidence(record, response);
      if (evidence.provesSettlement) {
        await _settlePendingDesktopCompression(record, evidence);
        if (!_disposed &&
            _durableCompressionFence == null &&
            _desktopRuntimeSessionId == record.runtimeSessionId) {
          _adoptDesktopRuntime(record.runtimeSessionId);
        }
        return;
      }
    } catch (_) {
      // A lost transport/read cannot prove success or failure. Expiry below is
      // intentionally non-success and merely prevents a stale UI gate.
    }
    if (!_isPendingDesktopCompressionCurrent(record)) return;
    final remaining = record.deadline.difference(
      DateTime.fromMillisecondsSinceEpoch(_wallClockMs()),
    );
    if (remaining <= Duration.zero) {
      _abandonPendingDesktopCompression(record, true);
      return;
    }
    _desktopCompressionReconciliationTimer?.cancel();
    _desktopCompressionReconciliationTimer = Timer(
      remaining,
      () => _abandonPendingDesktopCompression(record, true),
    );
  }

  Future<PendingSessionConfigChange> setSessionModel(
    DesktopModelSelection selection, {
    bool confirmExpensiveModel = false,
  }) => _setDesktopSessionConfig(
    SessionModelConfigValue.requested(selection),
    (gateway, runtimeId) => gateway.setSessionModel(
      runtimeId,
      selection,
      confirmExpensiveModel: confirmExpensiveModel,
    ),
  );

  Future<PendingSessionConfigChange> confirmSessionModel(
    PendingSessionConfigChange pending,
  ) {
    final scope = _sessionConfigScope;
    final current = scope == null
        ? null
        : _sessionConfigState.changeFor(scope, DesktopSessionConfigKey.model);
    final requested = pending.requestedValue;
    if (scope != pending.scope ||
        current?.requestEpoch != pending.requestEpoch ||
        current?.status != SessionConfigChangeStatus.confirmRequired ||
        requested is! SessionModelConfigValue ||
        requested.providerSlug == null) {
      throw const TuiGatewayRpcError(
        'config.set',
        'The model confirmation is no longer current',
        code: 4009,
      );
    }
    return setSessionModel(
      DesktopModelSelection(
        modelId: requested.modelId,
        providerSlug: requested.providerSlug!,
      ),
      confirmExpensiveModel: true,
    );
  }

  bool dismissSessionConfigConfirmation(PendingSessionConfigChange pending) {
    final scope = _sessionConfigScope;
    if (scope == null || scope != pending.scope) return false;
    final current = _sessionConfigState.changeFor(scope, pending.key);
    if (current?.requestEpoch != pending.requestEpoch ||
        current?.status != SessionConfigChangeStatus.confirmRequired) {
      return false;
    }
    final next = SessionConfigReducer.reduce(
      _sessionConfigState,
      SessionConfigRequestSuperseded(
        scope: scope,
        key: pending.key,
        requestEpoch: pending.requestEpoch,
      ),
    );
    if (identical(next, _sessionConfigState)) return false;
    _sessionConfigState = next;
    if (!_disposed) _emit(ActiveChatEvent.sessionInfo);
    return true;
  }

  Future<PendingSessionConfigChange> setSessionReasoning(
    DesktopReasoningEffort effort,
  ) => _setDesktopSessionConfig(
    SessionReasoningConfigValue.requested(effort),
    (gateway, runtimeId) => gateway.setSessionReasoning(runtimeId, effort),
  );

  Future<PendingSessionConfigChange> setSessionFastMode(DesktopFastMode mode) =>
      _setDesktopSessionConfig(
        SessionFastConfigValue.requested(mode),
        (gateway, runtimeId) => gateway.setSessionFastMode(runtimeId, mode),
      );

  Future<PendingSessionConfigChange> _setDesktopSessionConfig(
    SessionConfigValue requested,
    Future<DesktopConfigSetResult> Function(
      HermesDesktopSessionConfigGateway gateway,
      String runtimeId,
    )
    send,
  ) async {
    if (mutationsBlockedByOwnershipConflict) {
      throw _ownershipConflictError('config.set');
    }
    if (connection.readOnly) {
      throw const TuiGatewayRpcError(
        'config.set',
        'Session configuration is unavailable in read-only mode',
        code: 403,
      );
    }
    final gateway = _desktopGateway;
    if (gateway is! HermesDesktopSessionConfigGateway) {
      throw const TuiGatewayRpcError(
        'config.set',
        'Session configuration is unsupported by this connection',
        code: -32601,
      );
    }
    final configGateway = gateway as HermesDesktopSessionConfigGateway;
    final scope = _sessionConfigScope;
    final runtimeId = _desktopRuntimeSessionId;
    if (scope == null || runtimeId == null) {
      throw const TuiGatewayRpcError(
        'config.set',
        'No live runtime is available for session configuration',
        code: 4007,
      );
    }

    final requestEpoch = ++_sessionConfigRequestEpoch;
    _sessionConfigRequestsInFlight += 1;
    _sessionConfigState = SessionConfigReducer.reduce(
      _sessionConfigState,
      SessionConfigSendStarted(
        scope: scope,
        requestedValue: requested,
        requestEpoch: requestEpoch,
      ),
    );
    _emit(ActiveChatEvent.sessionInfo);

    try {
      final result = await send(configGateway, runtimeId);
      if (_disposed || _sessionConfigScope != scope) {
        return _capturedSessionConfigChange(scope, requested.key, requestEpoch);
      }
      _sessionConfigState = SessionConfigReducer.reduce(
        _sessionConfigState,
        SessionConfigRpcAccepted(
          scope: scope,
          requestEpoch: requestEpoch,
          result: result,
        ),
      );
    } catch (error) {
      if (_disposed || _sessionConfigScope != scope) {
        return _capturedSessionConfigChange(scope, requested.key, requestEpoch);
      }
      final failure = _sessionConfigFailure(error);
      _sessionConfigState = SessionConfigReducer.reduce(
        _sessionConfigState,
        failure == SessionConfigFailureKind.timeout ||
                failure == SessionConfigFailureKind.transport
            ? SessionConfigTimedOut(
                scope: scope,
                key: requested.key,
                requestEpoch: requestEpoch,
              )
            : SessionConfigRpcRejected(
                scope: scope,
                key: requested.key,
                requestEpoch: requestEpoch,
                failureKind: failure,
              ),
      );
    } finally {
      _sessionConfigRequestsInFlight -= 1;
    }
    _emit(ActiveChatEvent.sessionInfo);
    return _capturedSessionConfigChange(scope, requested.key, requestEpoch);
  }

  PendingSessionConfigChange _capturedSessionConfigChange(
    SessionConfigScope scope,
    DesktopSessionConfigKey key,
    int requestEpoch,
  ) {
    final change = _sessionConfigState.changeFor(scope, key);
    if (change == null || change.requestEpoch != requestEpoch) {
      throw StateError('Session configuration state was superseded');
    }
    return change;
  }

  SessionConfigFailureKind _sessionConfigFailure(Object error) {
    if (error is! TuiGatewayRpcError) {
      return SessionConfigFailureKind.transport;
    }
    return switch (error.code) {
      -32601 => SessionConfigFailureKind.unsupportedMethod,
      4002 => SessionConfigFailureKind.unsupported,
      4009 => SessionConfigFailureKind.busy,
      5001 => SessionConfigFailureKind.rejected,
      5032 => SessionConfigFailureKind.initialization,
      _ when error.message.contains('invalid session config response') =>
        SessionConfigFailureKind.invalidResponse,
      _ when error.message.toLowerCase().contains('timeout') =>
        SessionConfigFailureKind.timeout,
      _ => SessionConfigFailureKind.rejected,
    };
  }

  /// Reanuda una sesión durable sin permitir creación implícita en gateways
  /// modernos. Gateways legacy conservan su contrato anterior hasta que puedan
  /// anunciar [HermesDesktopSessionLifecycleGateway].
  Future<DesktopSessionSnapshot> _resumeDesktopSessionForRecovery(
    HermesDesktopGateway gateway,
    String storedSessionId, {
    required String profile,
    required String legacyModel,
    bool deferRuntimeCommit = false,
  }) async {
    if (deferRuntimeCommit &&
        gateway is HermesDesktopRecoverySessionLifecycleGateway) {
      final recoveryGateway =
          gateway as HermesDesktopRecoverySessionLifecycleGateway;
      return recoveryGateway.resumeExistingForRecovery(
        storedSessionId,
        profile: profile,
      );
    }
    if (gateway is HermesDesktopSessionLifecycleGateway) {
      final lifecycleGateway = gateway as HermesDesktopSessionLifecycleGateway;
      return lifecycleGateway.resumeExisting(storedSessionId, profile: profile);
    }
    return gateway.resumeSession(
      storedSessionId,
      profile: profile,
      model: legacyModel,
    );
  }

  Future<DesktopRosterBoundRecovery> _resumeAdvertisedDesktopSessionForRecovery(
    HermesDesktopGateway gateway,
    String storedSessionId, {
    required String profile,
  }) {
    if (gateway is! HermesDesktopRosterBoundRecoveryGateway) {
      throw const TuiGatewayRpcError(
        'session.active_list',
        'Roster-bound recovery is unavailable',
        code: -32601,
      );
    }
    return (gateway as HermesDesktopRosterBoundRecoveryGateway)
        .resumeAdvertisedExistingForRecovery(storedSessionId, profile: profile);
  }

  RecoveryProof? _prepareDesktopRecoverySnapshot(
    HermesDesktopGateway gateway,
    DesktopSessionSnapshot snapshot,
  ) {
    if (gateway is! HermesDesktopTypedRecoveryGateway) {
      if (gateway is HermesDesktopRecoverySessionLifecycleGateway) {
        // Compatibility signal only. The production gateway deliberately treats
        // this String-only hook as a no-op; it cannot release wire authority.
        (gateway as HermesDesktopRecoverySessionLifecycleGateway)
            .commitRecoveryRuntime(snapshot.runtimeSessionId);
      }
      return null;
    }
    final recoveryGateway = gateway as HermesDesktopTypedRecoveryGateway;
    final coverage = <RecoveryDomain>{};
    // A complete message list proves only transcript rows. It does not prove
    // live tools, subagents, prompts, turn state, or a post-snapshot live cut.
    if (_desktopSnapshotTranscriptIsComplete(snapshot)) {
      coverage.add(RecoveryDomain.transcript);
    }
    try {
      final proof = recoveryGateway.recoveryProofForSnapshot(
        snapshot,
        connectionId: connection.id,
        profile: _storedSessionProfile,
        bindGeneration: _desktopBindEpoch,
        sessionGeneration: _desktopSessionEpoch,
        turnGeneration: _turnEpoch,
        coverage: coverage,
      );
      if (proof.connectionId != connection.id ||
          proof.durableSessionId != snapshot.storedSessionId ||
          proof.runtimeSessionId != snapshot.runtimeSessionId ||
          proof.profile != _storedSessionProfile ||
          proof.bindGeneration != _desktopBindEpoch ||
          proof.sessionGeneration != _desktopSessionEpoch ||
          proof.turnGeneration != _turnEpoch ||
          proof.created != snapshot.created ||
          proof.durableIdentityExplicit !=
              snapshot.storedSessionIdentityExplicit ||
          proof.identityAliasesConsistent !=
              snapshot.identityAliasesConsistent ||
          !recoveryGateway.validateRecovery(proof)) {
        return null;
      }
      return proof;
    } catch (_) {
      return null;
    }
  }

  bool _desktopRecoveryProofStillCurrent(
    RecoveryProof proof,
    HermesDesktopGateway gateway,
    int turnEpoch,
  ) {
    final durable = _desktopStoredSessionId ?? serverSessionId;
    return _canRecoverTurn(turnEpoch) &&
        identical(_desktopGateway, gateway) &&
        proof.connectionId == connection.id &&
        proof.durableSessionId == durable &&
        proof.profile == _storedSessionProfile &&
        proof.bindGeneration == _desktopBindEpoch &&
        proof.sessionGeneration == _desktopSessionEpoch &&
        proof.turnGeneration == _turnEpoch;
  }

  bool _commitDesktopRecoverySnapshot(
    HermesDesktopGateway gateway,
    DesktopSessionSnapshot snapshot,
  ) {
    final proof = _prepareDesktopRecoverySnapshot(gateway, snapshot);
    if (proof == null || gateway is! HermesDesktopTypedRecoveryGateway) {
      return false;
    }
    try {
      return (gateway as HermesDesktopTypedRecoveryGateway).commitRecovery(
        proof,
      );
    } catch (_) {
      return false;
    }
  }

  Future<String?> _reconcilePromptSessionOwnership(
    HermesDesktopGateway gateway,
    Object error, {
    required String rejectedRuntimeId,
    required int expectedSessionEpoch,
    required int expectedBindEpoch,
    required String profile,
    required String model,
    required int turnEpoch,
  }) async {
    if (!_isRecoverablePromptSessionRejection(error) ||
        (gateway is! HermesDesktopSessionLifecycleGateway &&
            gateway is! HermesDesktopRecoverySessionLifecycleGateway) ||
        !_canRecoverTurn(turnEpoch) ||
        profile != _storedSessionProfile ||
        !activeChatRejectedRuntimeStillCurrent(
          expectedSessionEpoch: expectedSessionEpoch,
          currentSessionEpoch: _desktopSessionEpoch,
          expectedBindEpoch: expectedBindEpoch,
          currentBindEpoch: _desktopBindEpoch,
          rejectedRuntimeId: rejectedRuntimeId,
          currentRuntimeId: _desktopRuntimeSessionId,
        )) {
      return null;
    }
    final durableId = _desktopStoredSessionId ?? serverSessionId;
    if (durableId.isEmpty || durableId != durableId.trim()) return null;
    final expectedStoredSessionId = _desktopStoredSessionId;
    final expectedServerSessionId = serverSessionId;
    final expectedProfile = _storedSessionProfile;

    final DesktopSessionSnapshot snapshot;
    try {
      snapshot = await _resumeDesktopSessionForRecovery(
        gateway,
        durableId,
        profile: profile,
        legacyModel: model,
        deferRuntimeCommit: true,
      );
    } catch (_) {
      return null;
    }

    final authoritativeRuntimeId = snapshot.runtimeSessionId;
    final sameRuntimeCanBeRematerialized =
        error is TuiGatewayRpcError && error.code == 4001;
    if (!_canRecoverTurn(turnEpoch) ||
        expectedSessionEpoch != _desktopSessionEpoch ||
        expectedBindEpoch != _desktopBindEpoch ||
        expectedStoredSessionId != _desktopStoredSessionId ||
        expectedServerSessionId != serverSessionId ||
        expectedProfile != _storedSessionProfile ||
        snapshot.created ||
        snapshot.storedSessionId != durableId ||
        _desktopRuntimeSessionId != rejectedRuntimeId ||
        authoritativeRuntimeId.isEmpty ||
        (authoritativeRuntimeId == rejectedRuntimeId &&
            !sameRuntimeCanBeRematerialized)) {
      return null;
    }

    if (!_commitDesktopRecoverySnapshot(gateway, snapshot)) return null;
    _desktopStoredSessionId = snapshot.storedSessionId;
    _desktopStoredSessionKnownMissing = false;
    if (authoritativeRuntimeId != rejectedRuntimeId) {
      _adoptDesktopRuntime(authoritativeRuntimeId, info: snapshot.info);
      _hydrateAgentTasks(snapshot.todoState);
    }
    _desktopRuntimeInfo = snapshot.info;
    _rememberDesktopLiveStatus(snapshot.status, running: snapshot.running);
    _desktopStartedAt = snapshot.startedAt;
    _desktopTurnStartedAt = snapshot.running
        ? snapshot.resolvedTurnStartedAt
        : null;
    _usingDesktopGateway = true;
    return authoritativeRuntimeId;
  }

  /// Resuelve una entrega ambigua únicamente mediante el contrato negociado.
  /// `known:false`, capability ausente o cualquier violación dejan el turno
  /// ambiguo; este método nunca llama submit ni cambia de transporte.
  Future<PreparedTurn> reconcileAmbiguousTurn(
    PreparedTurn turn,
    TurnOutboxPersistence store, {
    bool Function()? stillCurrent,
  }) async {
    if (_disposed ||
        (turn.state != PreparedTurnState.ambiguous &&
            turn.state != PreparedTurnState.accepted &&
            turn.state != PreparedTurnState.running)) {
      return turn;
    }
    final sessionProfile = _bindSessionProfile(turn.profile);
    final gateway = _desktopGateway;
    final expectedQueueGeneration = _queueGeneration;
    final expectedBindEpoch = _desktopBindEpoch;
    final expectedSessionEpoch = _desktopSessionEpoch;
    final expectedStoredSessionId = _desktopStoredSessionId;
    final expectedServerSessionId = serverSessionId;
    final expectedRuntimeSessionId = _desktopRuntimeSessionId;
    final expectedStoredProfile = _storedSessionProfile;
    bool isCurrent() =>
        !_disposed &&
        (stillCurrent?.call() ?? true) &&
        expectedQueueGeneration == _queueGeneration &&
        expectedBindEpoch == _desktopBindEpoch &&
        expectedSessionEpoch == _desktopSessionEpoch &&
        expectedStoredSessionId == _desktopStoredSessionId &&
        expectedServerSessionId == serverSessionId &&
        expectedRuntimeSessionId == _desktopRuntimeSessionId &&
        expectedStoredProfile == _storedSessionProfile &&
        identical(gateway, _desktopGateway);
    if (gateway == null) return turn;
    if (!isCurrent()) return turn;
    final canUseIdempotency = await _canUseTurnIdempotency(gateway);
    if (!isCurrent() || !canUseIdempotency) return turn;
    try {
      _listenToDesktopGateway(gateway);
      if (!isCurrent()) return turn;
      await gateway.connect();
      if (!isCurrent()) return turn;
      final binding = await _resumeDesktopSessionForRecovery(
        gateway,
        turn.sessionId,
        profile: sessionProfile,
        legacyModel: turn.model,
        deferRuntimeCommit: true,
      );
      if (!isCurrent()) return turn;
      final runtimeSessionId = binding.runtimeSessionId;
      if (!isCurrent()) return turn;
      final status = await (gateway as HermesDesktopIdempotentGateway)
          .getTurnStatus(runtimeSessionId, turn.clientTurnId);
      if (!isCurrent() ||
          !status.known ||
          status.state == null ||
          status.clientTurnId != turn.clientTurnId) {
        return turn;
      }
      final localState = switch (status.state!) {
        DesktopTurnState.accepted => PreparedTurnState.accepted,
        DesktopTurnState.running => PreparedTurnState.running,
        DesktopTurnState.terminal ||
        DesktopTurnState.failed ||
        DesktopTurnState.cancelled => PreparedTurnState.terminal,
      };
      final resolved = turn.copyWith(
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        state: localState,
      );
      if (localState == PreparedTurnState.terminal) {
        if (!isCurrent()) return turn;
        if (!_commitDesktopRecoverySnapshot(gateway, binding)) return turn;
        await store.delete(resolved);
        if (!isCurrent()) return turn;
        // The recovery commit is mandatory before adopting the resumed runtime
        // or publishing a terminal transition derived from this snapshot.
        _desktopStoredSessionId = binding.storedSessionId;
        _adoptDesktopRuntime(runtimeSessionId, info: binding.info);
        _usingDesktopGateway = true;
      }
      if (localState == PreparedTurnState.accepted ||
          localState == PreparedTurnState.running) {
        if (!isCurrent()) return turn;
        if (!_commitDesktopRecoverySnapshot(gateway, binding)) return turn;
        _desktopStoredSessionId = binding.storedSessionId;
        _adoptDesktopRuntime(runtimeSessionId, info: binding.info);
        _usingDesktopGateway = true;
        _runTerminal = false;
        _activeTurnDelivery = ActiveTurnDelivery(
          prepared: resolved,
          store: store,
        );
        state = ChatPipelineState.waiting;
        _emit(ActiveChatEvent.connected);
        _armActivityWatchdog();
      }
      return resolved;
    } on TuiGatewayRpcError {
      if (isCurrent()) _turnIdempotencyInvalid = true;
      return turn;
    } catch (_) {
      // Corte de red/socket: no contradice la capability y tampoco demuestra
      // que el turno sea desconocido. Conserva ambiguous sin automatismos.
      return turn;
    }
  }

  /// Selecciona el canal oficial de Desktop cuando está disponible. El fallback
  /// REST conserva compatibilidad con instalaciones que solo publican 8642.
  Future<bool> _startRemoteAgentTurn(
    String fullText,
    String model,
    List<Map<String, dynamic>> history,
    int turnEpoch, {
    required DesktopSessionCreateConfig sessionConfig,
    String profile = '',
    List<AttachmentDraft> nativeAttachments = const [],
    String? desktopText,
    bool voicePlaybackInterrupted = false,
    bool queued = false,
    int? truncateBeforeUserOrdinal,
    int? truncateBeforeRowId,
    Future<void> Function(String storedSessionId)? beforeDesktopPromptSubmit,
  }) {
    final gateway = _desktopGateway;
    if (gateway == null) {
      if (!sessionConfig.allowTransportFallback) {
        _failRun('Hermes Desktop session lifecycle is required');
        return Future<bool>.value(false);
      }
      return _startRestFallbackWithAttachments(
        fullText,
        model,
        history,
        turnEpoch,
        nativeAttachments,
      );
    }
    return _startDesktopTurn(
      gateway,
      fullText,
      turnEpoch,
      profile: profile,
      history: history,
      model: model,
      sessionConfig: sessionConfig,
      nativeAttachments: nativeAttachments,
      desktopText: desktopText,
      voicePlaybackInterrupted: voicePlaybackInterrupted,
      queued: queued,
      truncateBeforeUserOrdinal: truncateBeforeUserOrdinal,
      truncateBeforeRowId: truncateBeforeRowId,
      beforeDesktopPromptSubmit: beforeDesktopPromptSubmit,
      fallback: () {
        _rewindRollbackMessages = null;
        _rewindRollbackState = null;
        _rewind4018FallbackOrdinal = null;
        return _startRestFallbackWithAttachments(
          fullText,
          model,
          history,
          turnEpoch,
          nativeAttachments,
        );
      },
    );
  }

  /// Binds an existing durable session or creates a new runtime only after the
  /// first submit. Modern gateways keep resume and create separate so a 4007
  /// during read/recovery can never generate server-side session garbage.
  Future<DesktopSessionBinding> _bindDesktopSessionForFirstSubmit(
    HermesDesktopGateway gateway, {
    required String profile,
    required List<Map<String, dynamic>> history,
    required String legacyModel,
    required DesktopSessionCreateConfig config,
  }) async {
    if (gateway is HermesDesktopSessionLifecycleGateway) {
      final lifecycle = gateway as HermesDesktopSessionLifecycleGateway;
      final durableId = _desktopStoredSessionId;
      final createsNewMobileSession =
          durableId == null &&
          (sessionId.startsWith('mob-') || _desktopStoredSessionKnownMissing);

      if (!createsNewMobileSession) {
        if (_desktopStoredSessionKnownMissing) {
          throw const TuiGatewayRpcError(
            'session.resume',
            'Pinned session does not exist',
            code: 4007,
          );
        }
        final exactDurableId = durableId ?? serverSessionId;
        final snapshot = await lifecycle.resumeExisting(
          exactDurableId,
          profile: profile,
        );
        _desktopStoredSessionKnownMissing = false;
        return snapshot is DesktopSessionBinding
            ? snapshot
            : DesktopSessionBinding.fromSnapshot(snapshot);
      }

      final DesktopSessionSnapshot snapshot;
      if (gateway is HermesDesktopConfiguredSessionLifecycleGateway) {
        snapshot =
            await (gateway as HermesDesktopConfiguredSessionLifecycleGateway)
                .createForFirstSubmitConfigured(
                  profile: profile,
                  seedMessages: history,
                  config: config,
                );
      } else {
        snapshot = await lifecycle.createForFirstSubmit(
          profile: profile,
          seedMessages: history,
          model: config.model?.modelId ?? legacyModel,
        );
      }
      _desktopStoredSessionKnownMissing = false;
      return snapshot is DesktopSessionBinding
          ? snapshot
          : DesktopSessionBinding.fromSnapshot(snapshot);
    }

    if (!config.allowTransportFallback) {
      throw const TuiGatewayRpcError(
        'session.resume',
        'Hermes Desktop session lifecycle is required',
        code: -32601,
      );
    }

    return gateway.resumeSession(
      serverSessionId,
      profile: profile,
      seedMessages: history,
      model: config.model?.modelId ?? legacyModel,
    );
  }

  Future<bool> _startDesktopTurn(
    HermesDesktopGateway gateway,
    String fullText,
    int turnEpoch, {
    required String profile,
    required List<Map<String, dynamic>> history,
    required String model,
    required DesktopSessionCreateConfig sessionConfig,
    required Future<bool> Function() fallback,
    List<AttachmentDraft> nativeAttachments = const [],
    String? desktopText,
    bool voicePlaybackInterrupted = false,
    bool queued = false,
    int? truncateBeforeUserOrdinal,
    int? truncateBeforeRowId,
    Future<void> Function(String storedSessionId)? beforeDesktopPromptSubmit,
  }) async {
    var submissionAttempted = false;
    var idempotentSubmission = false;
    var promptRecoverySuperseded = false;
    String? attemptedRuntimeId;
    int? attemptedSessionEpoch;
    int? attemptedBindEpoch;
    var boundOrAvailabilityResumedForSubmit = false;
    ({
      String connectionId,
      String profile,
      String durableSessionId,
      String runtimeSessionId,
      int bindEpoch,
      int sessionEpoch,
    })?
    ownershipCandidate;
    void captureRuntimeAttempt(String runtimeSessionId) {
      attemptedRuntimeId = runtimeSessionId;
      attemptedSessionEpoch = _desktopSessionEpoch;
      attemptedBindEpoch = _desktopBindEpoch;
    }

    try {
      _listenToDesktopGateway(gateway);
      await gateway.connect();
      if (_turnEpoch != turnEpoch || _runTerminal) return false;
      var runtimeId = _desktopRuntimeSessionId;
      if (runtimeId == null) {
        final draftSource = serverSessionId;
        final draftSessionEpoch = _desktopSessionEpoch;
        final draftBindEpoch = _desktopBindEpoch;
        final draftWasUnbound = _desktopStoredSessionId == null;
        final binding = await _bindDesktopSessionForFirstSubmit(
          gateway,
          profile: profile,
          history: history,
          legacyModel: model,
          config: sessionConfig,
        );
        runtimeId = binding.runtimeSessionId;
        if (binding.created &&
            _canRecoverTurn(turnEpoch) &&
            draftWasUnbound &&
            _desktopStoredSessionId == null &&
            draftSource == sessionId &&
            serverSessionId == draftSource &&
            draftSessionEpoch == _desktopSessionEpoch &&
            draftBindEpoch == _desktopBindEpoch &&
            profile == sessionProfile &&
            binding.storedSessionId.isNotEmpty) {
          _createdDraftSessionId ??= binding.storedSessionId;
        }
        if (binding.created) {
          _stagedFirstSubmitConfig = const DesktopSessionCreateConfig();
          if (_activeTurnTranscriptBoundaryEpoch == turnEpoch &&
              _activeTurnTranscriptBoundaryIdentity == null &&
              !history.any(isRealUserTurn)) {
            // Creation with no seeded user proves this turn owns the first row.
            _activeTurnStartedFromKnownMissing = true;
          }
        }
        _desktopStoredSessionId = binding.storedSessionId;
        _desktopStoredSessionKnownMissing = false;
        _adoptDesktopRuntime(runtimeId, info: binding.info);
        _hydrateAgentTasks(binding.todoState);
        boundOrAvailabilityResumedForSubmit = true;
        if (binding.info != _desktopRuntimeInfo) {
          _desktopRuntimeInfo = binding.info;
          _emit(ActiveChatEvent.sessionInfo);
        }
      }
      if (beforeDesktopPromptSubmit != null) {
        final storedId = _desktopStoredSessionId;
        if (storedId == null ||
            storedId.isEmpty ||
            storedId != storedId.trim()) {
          throw StateError('Hermes did not confirm a durable session id');
        }
        await beforeDesktopPromptSubmit(storedId);
      }
      if (_turnEpoch != turnEpoch || _runTerminal) return false;
      _adoptDesktopRuntime(runtimeId);
      final durableIdForSubmit = _desktopStoredSessionId;
      if ((boundOrAvailabilityResumedForSubmit ||
              _desktopRuntimeBindingOrigin ==
                  _DesktopRuntimeBindingOrigin.availabilityResumed) &&
          durableIdForSubmit != null &&
          durableIdForSubmit.isNotEmpty &&
          durableIdForSubmit == durableIdForSubmit.trim()) {
        ownershipCandidate = (
          connectionId: connection.id,
          profile: _storedSessionProfile,
          durableSessionId: durableIdForSubmit,
          runtimeSessionId: runtimeId,
          bindEpoch: _desktopBindEpoch,
          sessionEpoch: _desktopSessionEpoch,
        );
      }
      captureRuntimeAttempt(runtimeId);
      _usingDesktopGateway = true;
      currentRunId = null;
      state = ChatPipelineState.waiting;
      await _onForegroundKeepAlive?.call();
      _emit(ActiveChatEvent.connected);
      _armActivityWatchdog();
      final annotatedText = desktopText ?? fullText;
      final mentionAnnotation = botMentionNote(annotatedText);
      var promptText = stripBotMentionNote(annotatedText);
      final attachedImagePaths = <String>[];
      final legacyFileRefs = <String>[];
      final delivery = _activeTurnDelivery;
      final attachmentsForRuntime =
          delivery?.current.activeAttachments ??
          nativeAttachments
              .where(
                (item) => item.uploadState != AttachmentUploadState.removed,
              )
              .toList(growable: false);
      if (attachmentsForRuntime.isNotEmpty) {
        final String attachmentRuntimeId = runtimeId;
        final HermesDesktopAttachmentGateway? attachmentGateway =
            gateway is HermesDesktopAttachmentGateway
            ? gateway as HermesDesktopAttachmentGateway
            : null;
        if (attachmentGateway == null) {
          throw const TuiGatewayRpcError(
            'attachment',
            'Native Desktop attachments are unavailable',
            code: -32601,
          );
        }
        for (final attachment in attachmentsForRuntime) {
          final alreadyAttached = attachment.isAttachedTo(
            attachmentRuntimeId,
            transport: AttachmentRemoteTransport.desktop,
          );
          if (!alreadyAttached &&
              (attachment.localPath.isEmpty ||
                  !await File(attachment.localPath).exists())) {
            _failRun('No se pudo leer un adjunto local.');
            return false;
          }
        }
        if (!await _beginTurnTransport(
          turnEpoch,
          PreparedTurnTransport.desktop,
        )) {
          return false;
        }
        // Desde este punto ya puede existir una mutación remota aunque todavía
        // no se haya llamado prompt.submit. Nunca degradamos a otro transporte.
        submissionAttempted = true;
        for (final initialAttachment in attachmentsForRuntime) {
          var attachment = initialAttachment;
          if (delivery != null && attachment.localId.isNotEmpty) {
            final staged = await delivery.beginAttachmentUpload(
              attachment.localId,
              remoteSessionId: attachmentRuntimeId,
              transport: AttachmentRemoteTransport.desktop,
            );
            if (staged == null) {
              if (delivery.persistenceFailed) {
                _failRun('No se pudo conservar el estado de un adjunto.');
              } else {
                _failRun('El lote de adjuntos cambió durante la subida.');
              }
              return false;
            }
            attachment = staged;
            if (attachment.isAttachedTo(
              attachmentRuntimeId,
              transport: AttachmentRemoteTransport.desktop,
            )) {
              continue;
            }
          }
          try {
            final bytes = await File(attachment.localPath).readAsBytes();
            final encoded = base64Encode(bytes);
            late final String remoteRef;
            if (attachment.isImage) {
              final result = await attachmentGateway.attachImageBytes(
                attachmentRuntimeId,
                filename: attachment.name,
                contentBase64: encoded,
              );
              remoteRef = result.path ?? '';
            } else {
              final result = await attachmentGateway.attachFileBytes(
                attachmentRuntimeId,
                filename: attachment.name,
                mimeType: attachment.mimeType.isEmpty
                    ? 'application/octet-stream'
                    : attachment.mimeType,
                contentBase64: encoded,
              );
              remoteRef = result.refText ?? '';
            }
            if (remoteRef.isEmpty) {
              throw const TuiGatewayRpcError(
                'attachment',
                'Hermes omitted the attachment reference',
              );
            }
            if (delivery == null || attachment.localId.isEmpty) {
              if (attachment.isImage) {
                attachedImagePaths.add(remoteRef);
              } else {
                legacyFileRefs.add(remoteRef);
              }
              continue;
            }
            final persisted = await delivery.markAttachmentAttached(
              attachment.localId,
              attempt: attachment.attempt,
              remoteSessionId: attachmentRuntimeId,
              transport: AttachmentRemoteTransport.desktop,
              remoteRef: remoteRef,
            );
            if (!persisted) {
              if (attachment.isImage) {
                try {
                  await attachmentGateway.detachImage(
                    attachmentRuntimeId,
                    remoteRef,
                  );
                } catch (_) {}
              }
              _failRun(
                delivery.persistenceFailed
                    ? 'No se pudo conservar el estado de un adjunto.'
                    : 'El lote de adjuntos cambió durante la subida.',
              );
              return false;
            }
          } catch (_) {
            if (delivery != null && attachment.localId.isNotEmpty) {
              await delivery.markAttachmentFailed(
                attachment.localId,
                attempt: attachment.attempt,
                errorKind: AttachmentErrorKind.transport,
              );
            } else {
              for (final path in attachedImagePaths) {
                try {
                  await attachmentGateway.detachImage(
                    attachmentRuntimeId,
                    path,
                  );
                } catch (_) {}
              }
            }
            rethrow;
          }
        }
        await delivery?.waitForAttachmentMutations();
        if (delivery != null) {
          final expectedIds = attachmentsForRuntime
              .map((item) => item.localId)
              .where((id) => id.isNotEmpty)
              .toSet();
          final completedIds = delivery.current.activeAttachments
              .where(
                (item) =>
                    expectedIds.contains(item.localId) &&
                    item.isAttachedTo(
                      attachmentRuntimeId,
                      transport: AttachmentRemoteTransport.desktop,
                    ),
              )
              .map((item) => item.localId)
              .toSet();
          if (completedIds.length != expectedIds.length) {
            _failRun('El lote de adjuntos cambió durante la subida.');
            return false;
          }
          final refs = delivery.current.activeAttachments
              .where(
                (item) =>
                    !item.isImage &&
                    item.isAttachedTo(
                      attachmentRuntimeId,
                      transport: AttachmentRemoteTransport.desktop,
                    ),
              )
              .map((item) => item.remoteRef!)
              .toList(growable: false);
          if (refs.isNotEmpty) {
            promptText = '$promptText\n\n${refs.join('\n')}'.trim();
          }
        } else {
          if (legacyFileRefs.isNotEmpty) {
            promptText = '$promptText\n\n${legacyFileRefs.join('\n')}'.trim();
          }
        }
      }
      promptText = appendBotMentionNote(promptText, mentionAnnotation);
      final HermesDesktopRewindGateway? rewindGateway =
          gateway is HermesDesktopRewindGateway
          ? gateway as HermesDesktopRewindGateway
          : null;
      final HermesDesktopDurableRewindGateway? durableRewindGateway =
          gateway is HermesDesktopDurableRewindGateway
          ? gateway as HermesDesktopDurableRewindGateway
          : null;
      if (truncateBeforeUserOrdinal != null) {
        Future<DesktopRewindAck> submitRewind(
          String targetRuntimeId,
          int ordinal,
        ) async {
          captureRuntimeAttempt(targetRuntimeId);
          final rowId = truncateBeforeRowId;
          if (rowId != null) {
            if (durableRewindGateway == null) {
              throw const TuiGatewayRpcError(
                'prompt.submit',
                'Durable conversation rewind is unavailable',
                code: -32601,
              );
            }
            return durableRewindGateway.submitDurableRewindPrompt(
              targetRuntimeId,
              promptText,
              ordinal,
              truncateBeforeRowId: rowId,
              rebindSurvivorRowIds: _durableRowIdsForRebind(),
            );
          }
          if (rewindGateway == null) {
            throw const TuiGatewayRpcError(
              'prompt.submit',
              'Conversation rewind is unavailable',
              code: -32601,
            );
          }
          await rewindGateway.submitRewindPrompt(
            targetRuntimeId,
            promptText,
            ordinal,
          );
          return const DesktopRewindAck();
        }

        Future<DesktopRewindAck> submitRewindWithOrdinalRepair(
          String targetRuntimeId,
        ) async {
          final repairSessionEpoch = _desktopSessionEpoch;
          final repairBindEpoch = _desktopBindEpoch;
          try {
            return await submitRewind(
              targetRuntimeId,
              truncateBeforeUserOrdinal,
            );
          } on TuiGatewayRpcError catch (error) {
            final fallbackOrdinal = _rewind4018FallbackOrdinal;
            final segmentOrdinal = error.data['segment_ordinal'];
            if (error.code != 4018 ||
                (segmentOrdinal is num && segmentOrdinal < 0) ||
                fallbackOrdinal == null ||
                fallbackOrdinal == truncateBeforeUserOrdinal) {
              rethrow;
            }
            if (!activeChatRejectedRuntimeStillCurrent(
              expectedSessionEpoch: repairSessionEpoch,
              currentSessionEpoch: _desktopSessionEpoch,
              expectedBindEpoch: repairBindEpoch,
              currentBindEpoch: _desktopBindEpoch,
              rejectedRuntimeId: targetRuntimeId,
              currentRuntimeId: _desktopRuntimeSessionId,
            )) {
              promptRecoverySuperseded = true;
              rethrow;
            }
            debugPrint(
              '[active-chat] retrying rewind after Hermes model-switch '
              'ordinal repair ($truncateBeforeUserOrdinal -> $fallbackOrdinal)',
            );
            return submitRewind(targetRuntimeId, fallbackOrdinal);
          }
        }

        Future<DesktopRewindAck> submitRewindAfterBusy(
          String targetRuntimeId,
        ) async {
          try {
            return await submitRewindWithOrdinalRepair(targetRuntimeId);
          } on TuiGatewayRpcError catch (error) {
            if (error.code != 4009) rethrow;
          }

          // A rewind must retain its cut; interrupt the old turn and retry the
          // same truncating submit until the gateway releases its running gate.
          _discardLateInterruptTerminal = true;
          try {
            await gateway.interrupt(targetRuntimeId);
          } catch (_) {}

          final deadline = DateTime.now().add(
            _activeChatRewindBusyRetryTimeout,
          );
          while (DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(_activeChatRewindBusyRetryInterval);
            try {
              return await submitRewindWithOrdinalRepair(targetRuntimeId);
            } on TuiGatewayRpcError catch (error) {
              if (error.code != 4009) rethrow;
            }
          }
          throw const TuiGatewayRpcError(
            'prompt.submit',
            'session busy',
            code: 4009,
          );
        }

        if (!await _beginTurnTransport(
          turnEpoch,
          PreparedTurnTransport.desktop,
        )) {
          return false;
        }
        submissionAttempted = true;
        captureRuntimeAttempt(runtimeId);
        late DesktopRewindAck rewindAck;
        try {
          rewindAck = await submitRewindAfterBusy(runtimeId);
        } on TuiGatewayRpcError catch (error) {
          if (!_isRecoverablePromptSessionRejection(error)) rethrow;
          await _activeTurnDelivery?.markRejectedBeforeAcceptance();
          final recoverySessionEpoch = _desktopSessionEpoch;
          final recoveryBindEpoch = _desktopBindEpoch;
          final rejectedRuntimeId = runtimeId;
          final reboundRuntimeId = await _reconcilePromptSessionOwnership(
            gateway,
            error,
            rejectedRuntimeId: rejectedRuntimeId,
            expectedSessionEpoch: attemptedSessionEpoch ?? recoverySessionEpoch,
            expectedBindEpoch: attemptedBindEpoch ?? recoveryBindEpoch,
            profile: profile,
            model: model,
            turnEpoch: turnEpoch,
          );
          if (reboundRuntimeId == null) {
            promptRecoverySuperseded = !activeChatRejectedRuntimeStillCurrent(
              expectedSessionEpoch: recoverySessionEpoch,
              currentSessionEpoch: _desktopSessionEpoch,
              expectedBindEpoch: recoveryBindEpoch,
              currentBindEpoch: _desktopBindEpoch,
              rejectedRuntimeId: rejectedRuntimeId,
              currentRuntimeId: _desktopRuntimeSessionId,
            );
            rethrow;
          }
          final retrySessionEpoch = _desktopSessionEpoch;
          final retryBindEpoch = _desktopBindEpoch;
          if (!await _beginTurnTransport(
            turnEpoch,
            PreparedTurnTransport.desktop,
          )) {
            return false;
          }
          if (!activeChatRejectedRuntimeStillCurrent(
            expectedSessionEpoch: retrySessionEpoch,
            currentSessionEpoch: _desktopSessionEpoch,
            expectedBindEpoch: retryBindEpoch,
            currentBindEpoch: _desktopBindEpoch,
            rejectedRuntimeId: reboundRuntimeId,
            currentRuntimeId: _desktopRuntimeSessionId,
          )) {
            promptRecoverySuperseded = true;
            await _activeTurnDelivery?.markRejectedBeforeAcceptance();
            return false;
          }
          runtimeId = reboundRuntimeId;
          rewindAck = await submitRewindAfterBusy(runtimeId);
        }
        _rebindSurvivorUserRowIds(rewindAck);
        _rewindRollbackMessages = null;
        _rewindRollbackState = null;
        _rewind4018FallbackOrdinal = null;
      } else {
        if (!await _beginTurnTransport(
          turnEpoch,
          PreparedTurnTransport.desktop,
        )) {
          return false;
        }
        submissionAttempted = true;
        final delivery = _activeTurnDelivery;
        final idempotentGateway =
            !voicePlaybackInterrupted &&
                delivery != null &&
                await _canUseTurnIdempotency(gateway)
            ? gateway as HermesDesktopIdempotentGateway
            : null;
        Future<void> submitPrompt(String targetRuntimeId) async {
          captureRuntimeAttempt(targetRuntimeId);
          if (voicePlaybackInterrupted &&
              gateway is HermesDesktopInterruptedPromptGateway) {
            await (gateway as HermesDesktopInterruptedPromptGateway)
                .submitInterruptedPrompt(targetRuntimeId, promptText);
          } else if (idempotentGateway != null) {
            idempotentSubmission = true;
            final ack = queued && gateway is HermesDesktopQueuedPromptGateway
                ? await (gateway as HermesDesktopQueuedPromptGateway)
                      .submitQueuedPromptIdempotent(
                        targetRuntimeId,
                        promptText,
                        delivery!.current.clientTurnId,
                      )
                : await idempotentGateway.submitPromptIdempotent(
                    targetRuntimeId,
                    promptText,
                    delivery!.current.clientTurnId,
                  );
            if (!ack.accepted ||
                ack.clientTurnId != delivery.current.clientTurnId ||
                (ack.state != DesktopTurnState.accepted &&
                    ack.state != DesktopTurnState.running &&
                    ack.state != DesktopTurnState.terminal)) {
              throw const TuiGatewayRpcError(
                'prompt.submit',
                'Hermes returned an invalid idempotent acknowledgement',
              );
            }
            if (ack.state == DesktopTurnState.terminal) {
              await _completeRun();
            }
          } else if (queued && gateway is HermesDesktopQueuedPromptGateway) {
            await (gateway as HermesDesktopQueuedPromptGateway)
                .submitQueuedPrompt(targetRuntimeId, promptText);
          } else {
            await gateway.submitPrompt(targetRuntimeId, promptText);
          }
        }

        try {
          await submitPrompt(runtimeId);
        } on TuiGatewayRpcError catch (error) {
          // image.attach_bytes/file.attach mutan el runtime actual. Hasta que
          // podamos re-subir el lote de forma segura, nunca reenviamos solo el
          // prompt (ni referencias ligadas al runtime anterior) tras reanudar.
          if (attachmentsForRuntime.isNotEmpty) {
            if (_isRecoverablePromptSessionRejection(error)) {
              await delivery?.markRejectedBeforeAcceptance(
                invalidateRemoteSessionId: runtimeId,
                invalidateTransport: AttachmentRemoteTransport.desktop,
              );
            }
            rethrow;
          }
          if (!_isRecoverablePromptSessionRejection(error)) rethrow;
          await delivery?.markRejectedBeforeAcceptance();
          final recoverySessionEpoch = _desktopSessionEpoch;
          final recoveryBindEpoch = _desktopBindEpoch;
          final rejectedRuntimeId = runtimeId;
          final reboundRuntimeId = await _reconcilePromptSessionOwnership(
            gateway,
            error,
            rejectedRuntimeId: rejectedRuntimeId,
            expectedSessionEpoch: attemptedSessionEpoch ?? recoverySessionEpoch,
            expectedBindEpoch: attemptedBindEpoch ?? recoveryBindEpoch,
            profile: profile,
            model: model,
            turnEpoch: turnEpoch,
          );
          if (reboundRuntimeId == null) {
            promptRecoverySuperseded = !activeChatRejectedRuntimeStillCurrent(
              expectedSessionEpoch: recoverySessionEpoch,
              currentSessionEpoch: _desktopSessionEpoch,
              expectedBindEpoch: recoveryBindEpoch,
              currentBindEpoch: _desktopBindEpoch,
              rejectedRuntimeId: rejectedRuntimeId,
              currentRuntimeId: _desktopRuntimeSessionId,
            );
            rethrow;
          }
          final retrySessionEpoch = _desktopSessionEpoch;
          final retryBindEpoch = _desktopBindEpoch;
          if (!await _beginTurnTransport(
            turnEpoch,
            PreparedTurnTransport.desktop,
          )) {
            return false;
          }
          if (!activeChatRejectedRuntimeStillCurrent(
            expectedSessionEpoch: retrySessionEpoch,
            currentSessionEpoch: _desktopSessionEpoch,
            expectedBindEpoch: retryBindEpoch,
            currentBindEpoch: _desktopBindEpoch,
            rejectedRuntimeId: reboundRuntimeId,
            currentRuntimeId: _desktopRuntimeSessionId,
          )) {
            promptRecoverySuperseded = true;
            await delivery?.markRejectedBeforeAcceptance();
            return false;
          }
          runtimeId = reboundRuntimeId;
          await submitPrompt(runtimeId);
        }
      }
      final acceptedOwnership = ownershipCandidate;
      if (acceptedOwnership != null) {
        _mintDesktopRuntimeOwnershipAfterAcceptedSubmit(
          gateway: gateway,
          connectionId: acceptedOwnership.connectionId,
          profile: acceptedOwnership.profile,
          durableSessionId: acceptedOwnership.durableSessionId,
          runtimeSessionId: acceptedOwnership.runtimeSessionId,
          bindEpoch: acceptedOwnership.bindEpoch,
          sessionEpoch: acceptedOwnership.sessionEpoch,
          turnEpoch: turnEpoch,
        );
      }
      return true;
    } catch (error) {
      if (truncateBeforeUserOrdinal != null) {
        _activeRewrite?.rejection = error;
      }
      if (_turnEpoch != turnEpoch || _runTerminal) return false;
      if (promptRecoverySuperseded) return false;
      final failedRuntimeId = attemptedRuntimeId;
      final failureSessionEpoch = attemptedSessionEpoch;
      final failureBindEpoch = attemptedBindEpoch;
      bool failureStillCurrent() {
        if (failedRuntimeId == null ||
            failureSessionEpoch == null ||
            failureBindEpoch == null) {
          return true;
        }
        return activeChatRejectedRuntimeStillCurrent(
          expectedSessionEpoch: failureSessionEpoch,
          currentSessionEpoch: _desktopSessionEpoch,
          expectedBindEpoch: failureBindEpoch,
          currentBindEpoch: _desktopBindEpoch,
          rejectedRuntimeId: failedRuntimeId,
          currentRuntimeId: _desktopRuntimeSessionId,
        );
      }

      if (!failureStillCurrent()) return false;
      if (truncateBeforeUserOrdinal != null) {
        if (error is TuiGatewayRpcError) {
          debugPrint(
            '[active-chat] rewind RPC failed '
            '(type=${error.runtimeType}, method=${error.method}, '
            'code=${error.code ?? 'none'})',
          );
        } else {
          debugPrint('[active-chat] rewind failed (type=${error.runtimeType})');
        }
      }
      if (truncateBeforeUserOrdinal != null && !submissionAttempted) {
        final rollback = _rewindRollbackMessages;
        final rollbackState = _rewindRollbackState;
        if (rollback != null) {
          _turnSubmittedAtMs = null;
          _activityWatchdogTimer?.cancel();
          _activityWatchdogTimer = null;
          _setNoActivityHint(false);
          _messages = rollback;
          _rewindRollbackMessages = null;
          _rewindRollbackState = null;
          _rewind4018FallbackOrdinal = null;
          _rewindRestoredOnError = true;
          _rewindDashboardAuthRequired = error is DashboardAuthException;
          _runTerminal = true;
          traceActive = false;
          pendingApproval = null;
          state = rollbackState ?? ChatPipelineState.completed;
          final activeRewrite = _activeRewrite;
          if (_isStaleRewriteTarget(error) && activeRewrite != null) {
            activeRewrite.terminalNotificationDeferred = true;
          } else {
            _emit(ActiveChatEvent.error);
            _onTerminal();
          }
          return false;
        }
      }
      if (truncateBeforeUserOrdinal != null && submissionAttempted) {
        final rollback = _rewindRollbackMessages;
        final rollbackState = _rewindRollbackState;
        final deterministicRejection =
            (error is TuiGatewayRpcError && error.code != null) ||
            (error is DashboardAuthException &&
                _isTerminalDesktopRecoveryError(error));
        if (deterministicRejection && rollback != null) {
          _turnSubmittedAtMs = null;
          _activityWatchdogTimer?.cancel();
          _activityWatchdogTimer = null;
          _setNoActivityHint(false);
          _messages = rollback;
          _rewindRollbackMessages = null;
          _rewindRollbackState = null;
          _rewind4018FallbackOrdinal = null;
          _rewindRestoredOnError = true;
          _rewindDashboardAuthRequired = error is DashboardAuthException;
          _runTerminal = true;
          traceActive = false;
          pendingApproval = null;
          state = rollbackState ?? ChatPipelineState.completed;
          final activeRewrite = _activeRewrite;
          if (_isStaleRewriteTarget(error) && activeRewrite != null) {
            activeRewrite.terminalNotificationDeferred = true;
          } else {
            _emit(ActiveChatEvent.error);
            _onTerminal();
          }
          return false;
        }
        // Sin un error JSON-RPC con código, el servidor pudo haber aplicado el
        // rewind antes de perderse el ACK. Restaurar el transcript antiguo sería
        // afirmar una línea temporal que quizá ya no existe en Desktop.
        _rewindRollbackMessages = null;
        _rewindRollbackState = null;
        _rewind4018FallbackOrdinal = null;
      }
      if (error is TuiGatewayRpcError) {
        debugPrint(
          '[active-chat] Desktop RPC failed '
          '(method=${error.method}, code=${error.code ?? 'none'})',
        );
      } else {
        debugPrint('[active-chat] Desktop turn failed (${error.runtimeType})');
      }
      final rejectedBeforeAcceptance =
          activeChatPromptWasRejectedBeforeAcceptance(error);
      if (idempotentSubmission && !rejectedBeforeAcceptance) {
        // Anunciada pero incompatible (method-not-found, eco/payload inválido o
        // timeout): se invalida durante esta generación. No hay fallback porque
        // el servidor pudo haber aceptado el turno.
        _turnIdempotencyInvalid = true;
      }
      if (rejectedBeforeAcceptance) {
        await _activeTurnDelivery?.markRejectedBeforeAcceptance();
      }
      if (!failureStillCurrent()) return false;
      final ownershipConflict =
          error is TuiGatewayRpcError &&
          error.method == 'prompt.submit' &&
          error.code == 4090 &&
          error.reason == _sessionNotOwnedReason;
      if (ownershipConflict) {
        _ownershipMutationAdmission =
            _OwnershipMutationAdmission.conflictReadOnly;
        _pendingManualOwnershipProbeClientTurnId =
            _activeTurnDelivery?.current.clientTurnId;
        _ownershipConflictGeneration += 1;
        _queueDrainSuspended = true;
      }
      _activityWatchdogTimer?.cancel();
      _activityWatchdogTimer = null;
      _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
      _usingDesktopGateway = false;
      _retireDesktopRuntime();
      // Solo degradamos antes de entregar el prompt. Después podría estar
      // ejecutándose pese a un timeout de respuesta y repetirlo sería peor.
      if (!submissionAttempted && sessionConfig.allowTransportFallback) {
        return fallback();
      } else {
        _failRun(activeChatPromptFailureUiMessage(error));
        return false;
      }
    }
  }

  void _listenToDesktopGateway(HermesDesktopGateway gateway) {
    _desktopEventSubscription ??= gateway.events.listen(
      _onDesktopEvent,
      onError: (Object error, StackTrace stackTrace) {
        final interruptedActiveTurn =
            _usingDesktopGateway && isStreaming && !_runTerminal;
        final clientSubmittedTurn = _clientSubmittedCurrentTurn;
        final malformedTransport =
            error is TuiGatewayRpcError &&
            error.origin == CompressionFailureOrigin.malformed;
        final viewerRecoveryClosed =
            malformedTransport ||
            _desktopStoredSessionKnownMissing ||
            _closedViewerRecoveryBlocks(gateway);
        // El runtime vive dentro del socket de Desktop. Tras un corte no se
        // puede reutilizar su id en el siguiente intento: fuerza un nuevo
        // session.resume sobre el socket reconectado y evita una cadena de
        // reintentos contra un runtime ya desaparecido.
        final disconnectedRuntimeId = _desktopRuntimeSessionId;
        _expireInteractivePromptsForRuntime(disconnectedRuntimeId);
        _usingDesktopGateway = false;
        _retireDesktopRuntime();
        if (viewerRecoveryClosed) _closeViewerRecovery(gateway);
        if (interruptedActiveTurn && clientSubmittedTurn) {
          _scheduleDesktopTurnRecovery(gateway, _turnEpoch, error);
        } else if (!viewerRecoveryClosed) {
          if (interruptedActiveTurn) {
            _viewerTurnConvergenceEpoch = _turnEpoch;
            _rosterRuntimeAbsenceStreak = 0;
            state = ChatPipelineState.connecting;
            _emit(ActiveChatEvent.connected);
          }
          _scheduleAutomaticDesktopReattach(gateway);
        }
      },
    );
  }

  void _scheduleAutomaticDesktopReattach(HermesDesktopGateway gateway) {
    if ((!_attachDesktopRuntimeOnLoad && !_viewerTurnConvergenceIsCurrent) ||
        gateway is! HermesDesktopRecoverySessionLifecycleGateway ||
        _disposed ||
        (isStreaming && !_viewerTurnConvergenceIsCurrent) ||
        _desktopStoredSessionKnownMissing ||
        _closedViewerRecoveryBlocks(gateway) ||
        _desktopAutomaticReattach != null ||
        !identical(gateway, _desktopGateway)) {
      return;
    }
    final generation = ++_desktopAutomaticReattachGeneration;
    late final Future<void> recovery;
    recovery = _reattachDesktopRuntime(gateway, generation).whenComplete(() {
      if (identical(_desktopAutomaticReattach, recovery)) {
        _desktopAutomaticReattach = null;
      }
    });
    _desktopAutomaticReattach = recovery;
    unawaited(recovery);
  }

  Future<void> _reattachDesktopRuntime(
    HermesDesktopGateway gateway,
    int generation,
  ) async {
    final durableId = _desktopStoredSessionId ?? serverSessionId;
    if (durableId.isEmpty || durableId != durableId.trim()) return;
    final expectedConnectionId = connection.id;
    final expectedLogicalSessionId = logicalSessionId;
    final expectedServerSessionId = serverSessionId;
    final expectedProfile = _storedSessionProfile;
    final expectedTurnEpoch = _turnEpoch;
    final expectedBindEpoch = _desktopBindEpoch;
    final expectedSessionEpoch = _desktopSessionEpoch;
    if (durableId.isEmpty) return;

    bool isCurrent() =>
        !_disposed &&
        (_attachDesktopRuntimeOnLoad || _viewerTurnConvergenceIsCurrent) &&
        (!isStreaming || _viewerTurnConvergenceIsCurrent) &&
        !_desktopStoredSessionKnownMissing &&
        !_closedViewerRecoveryBlocks(gateway) &&
        generation == _desktopAutomaticReattachGeneration &&
        identical(gateway, _desktopGateway) &&
        connection.id == expectedConnectionId &&
        logicalSessionId == expectedLogicalSessionId &&
        serverSessionId == expectedServerSessionId &&
        _storedSessionProfile == expectedProfile &&
        (_desktopStoredSessionId ?? serverSessionId) == durableId &&
        _turnEpoch == expectedTurnEpoch &&
        _desktopBindEpoch == expectedBindEpoch &&
        _desktopSessionEpoch == expectedSessionEpoch &&
        _desktopRuntimeSessionId == null;

    _publishTransportState(ChatTransportState.offline);
    var attempt = 0;
    while (isCurrent()) {
      final delay = _desktopRecoveryDelayForAttempt(attempt);
      attempt += 1;
      if (delay > Duration.zero) {
        final elapsed = await _waitForDesktopRecoveryDelay(
          delay,
          _disposeSignal.future,
        );
        if (!elapsed || !isCurrent()) return;
      } else if (attempt > 1) {
        // A zero-duration test policy must still yield and cannot hot-loop.
        await Future<void>.delayed(Duration.zero);
        if (!isCurrent()) return;
      }
      _publishTransportState(ChatTransportState.reconnecting);
      try {
        DesktopRosterBoundRecovery? recovery;
        late final DesktopSessionSnapshot snapshot;
        if (_viewerTurnConvergenceIsCurrent) {
          final recoveryGateway =
              gateway as HermesDesktopRecoverySessionLifecycleGateway;
          snapshot = await recoveryGateway.resumeExistingForRecovery(
            durableId,
            profile: expectedProfile,
          );
        } else {
          recovery = await _resumeAdvertisedDesktopSessionForRecovery(
            gateway,
            durableId,
            profile: expectedProfile,
          );
          snapshot = recovery.snapshot;
        }
        if (!isCurrent()) return;
        final runtimeId = snapshot.runtimeSessionId;
        final advertisedRoot = snapshot.lineageRootId;
        final identityAccepted =
            !snapshot.created &&
            snapshot.identityAliasesConsistent &&
            snapshot.storedSessionIdentityExplicit &&
            snapshot.storedSessionId == durableId &&
            runtimeId.isNotEmpty &&
            (advertisedRoot == null ||
                advertisedRoot == expectedLogicalSessionId ||
                advertisedRoot == durableId);
        if (!identityAccepted) {
          _closeViewerRecovery(gateway);
          return;
        }
        _publishTransportState(ChatTransportState.connected);
        if (_viewerTurnConvergenceIsCurrent) {
          // Unproven post-cut viewers may publish only durable privacy vetoes.
          if (_recordDurablePrivateTranscriptVetoes(snapshot.messages)) {
            _emit(ActiveChatEvent.messagesHydrated);
          }
          return;
        }

        final rosterGateway =
            gateway as HermesDesktopRosterBoundRecoveryGateway;
        if (!rosterGateway.consumeRosterBoundViewerAttachment(recovery!)) {
          _closeViewerRecovery(gateway);
          return;
        }
        _desktopStoredSessionId = snapshot.storedSessionId;
        _desktopStoredSessionKnownMissing = false;
        _adoptDesktopRuntime(runtimeId, info: snapshot.info);
        _hydrateAgentTasks(snapshot.todoState);
        _desktopRuntimeInfo = snapshot.info;
        _rememberDesktopLiveStatus(snapshot.status, running: snapshot.running);
        _desktopStartedAt = snapshot.startedAt;
        _desktopTurnStartedAt = snapshot.running
            ? snapshot.resolvedTurnStartedAt
            : null;
        _usingDesktopGateway = true;
        _emit(ActiveChatEvent.sessionInfo);
        return;
      } catch (error) {
        if (!isCurrent()) return;
        _publishTransportState(
          gateway.isConnected
              ? ChatTransportState.reconnecting
              : ChatTransportState.offline,
        );
        if (_viewerAttachmentDisposition(error) !=
            _ViewerAttachmentDisposition.retryTransient) {
          _closeViewerRecovery(gateway);
          return;
        }
      }
    }
  }

  void _finalizeColdOpenViewerAttachment(
    HermesDesktopGateway gateway,
    Object? error, {
    required bool durableHistoryIsEmpty,
    required bool durableHistoryLoaded,
  }) {
    if (error == null) return;
    if (error is TuiGatewayRpcError && error.code == 4007) {
      _desktopStoredSessionKnownMissing = true;
      if (durableHistoryLoaded && durableHistoryIsEmpty) {
        _markTranscriptComplete(visibleCount: 0);
      }
    }
    final disposition = _viewerAttachmentDisposition(error);
    if (disposition == _ViewerAttachmentDisposition.retryTransient) {
      _scheduleAutomaticDesktopReattach(gateway);
    } else {
      _closeViewerRecovery(gateway);
    }
  }

  void _closeViewerRecovery(HermesDesktopGateway gateway) {
    _desktopAutomaticReattachGeneration += 1;
    _closedViewerRecoveryScope = _ClosedViewerRecoveryScope(
      gateway: gateway,
      connectionId: connection.id,
      logicalSessionId: logicalSessionId,
      serverSessionId: serverSessionId,
      storedSessionId: _desktopStoredSessionId ?? serverSessionId,
      profile: _storedSessionProfile,
      turnEpoch: _turnEpoch,
      bindEpoch: _desktopBindEpoch,
      sessionEpoch: _desktopSessionEpoch,
    );
  }

  bool _closedViewerRecoveryBlocks(HermesDesktopGateway gateway) {
    final scope = _closedViewerRecoveryScope;
    return scope != null &&
        identical(scope.gateway, gateway) &&
        scope.connectionId == connection.id &&
        scope.logicalSessionId == logicalSessionId &&
        scope.serverSessionId == serverSessionId &&
        scope.storedSessionId == (_desktopStoredSessionId ?? serverSessionId) &&
        scope.profile == _storedSessionProfile &&
        scope.turnEpoch == _turnEpoch &&
        scope.bindEpoch == _desktopBindEpoch &&
        scope.sessionEpoch == _desktopSessionEpoch;
  }

  _ViewerAttachmentDisposition _viewerAttachmentDisposition(Object error) {
    if (error is DashboardAuthException) {
      final status = error.statusCode;
      if ((error.code == DashboardAuthFailureCode.rateLimited &&
              status == 429) ||
          (error.code == DashboardAuthFailureCode.loginFailed &&
              status != null &&
              status >= 500 &&
              status < 600)) {
        return _ViewerAttachmentDisposition.retryTransient;
      }
      return _ViewerAttachmentDisposition.stopTerminal;
    }
    if (error is DashboardWebSocketAuthException) {
      final status = error.statusCode;
      if ((status == null &&
              error.cause == DashboardWebSocketAuthFailureCause.transport) ||
          status == 408 ||
          status == 429 ||
          (status != null && status >= 500 && status < 600)) {
        return _ViewerAttachmentDisposition.retryTransient;
      }
      if (status == 401 || status == 403) {
        return _ViewerAttachmentDisposition.stopTerminal;
      }
      return _ViewerAttachmentDisposition.stopAmbiguous;
    }
    if (error is DashboardHttpException) {
      final status = error.statusCode;
      if (status == 408 || status == 429 || (status >= 500 && status < 600)) {
        return _ViewerAttachmentDisposition.retryTransient;
      }
      return _ViewerAttachmentDisposition.stopTerminal;
    }
    if (error is TimeoutException ||
        error is SocketException ||
        error is HandshakeException ||
        error is HttpException ||
        error is http.ClientException) {
      return _ViewerAttachmentDisposition.retryTransient;
    }
    if (error is WebSocketChannelException) {
      final inner = error.inner;
      if (inner is WebSocketException) {
        final status = inner.httpStatusCode;
        if (status == 408 ||
            status == 429 ||
            (status != null && status >= 500 && status < 600)) {
          return _ViewerAttachmentDisposition.retryTransient;
        }
        return status == null
            ? _ViewerAttachmentDisposition.stopAmbiguous
            : _ViewerAttachmentDisposition.stopTerminal;
      }
      if (inner is TimeoutException ||
          inner is SocketException ||
          inner is HandshakeException ||
          inner is HttpException ||
          inner is http.ClientException) {
        return _ViewerAttachmentDisposition.retryTransient;
      }
      return _ViewerAttachmentDisposition.stopAmbiguous;
    }
    if (error is TuiGatewayRpcError) {
      if (error.origin == CompressionFailureOrigin.malformed) {
        return _ViewerAttachmentDisposition.stopTerminal;
      }
      if (error.failureKind == TuiGatewayRpcFailureKind.timeout ||
          error.failureKind == TuiGatewayRpcFailureKind.connectionLost ||
          (error.code == null &&
              error.origin == CompressionFailureOrigin.unknown &&
              error.message == 'Timeout waiting for JSON-RPC response') ||
          error.code == 5001) {
        return _ViewerAttachmentDisposition.retryTransient;
      }
      if (const <int>{
        4007,
        4030,
        -32700,
        -32600,
        -32601,
        -32602,
      }.contains(error.code)) {
        return _ViewerAttachmentDisposition.stopTerminal;
      }
      return _ViewerAttachmentDisposition.stopAmbiguous;
    }
    return _ViewerAttachmentDisposition.stopAmbiguous;
  }

  bool _isCurrentEpoch(int expectedEpoch) =>
      !_disposed && _turnEpoch == expectedEpoch;

  int _advanceTurnEpoch() {
    if (!_turnEpochInvalidated.isCompleted) {
      _turnEpochInvalidated.complete();
    }
    _turnEpochInvalidated = Completer<void>();

    _pendingAuthoritativeTerminalEpoch = null;
    _pendingAuthoritativeTerminalOutput = null;
    _terminalWarning = null;
    _terminalWarningEpoch = null;
    final nextEpoch = ++_turnEpoch;
    _terminalCommitGate = _TerminalCommitGate(nextEpoch);
    return nextEpoch;
  }

  bool _canRecoverTurn(int expectedEpoch) {
    final stop = _stopTransition;
    return _isCurrentEpoch(expectedEpoch) &&
        !_runTerminal &&
        (stop == null || stop.turnEpoch != expectedEpoch) &&
        // Desenganchar el coordinador terminal no puede reabrir la recuperación
        // del turno que el usuario acaba de detener.
        _finalizedStopTurnEpoch != expectedEpoch;
  }

  bool _isTerminalDesktopRecoveryError(Object error) {
    if (error is DashboardAuthException) {
      final status = error.statusCode;
      if ((error.code == DashboardAuthFailureCode.rateLimited &&
              status == 429) ||
          (error.code == DashboardAuthFailureCode.loginFailed &&
              status != null &&
              status >= 500 &&
              status < 600)) {
        return false;
      }
      return true;
    }
    if (error is DashboardWebSocketAuthException) {
      return _viewerAttachmentDisposition(error) !=
          _ViewerAttachmentDisposition.retryTransient;
    }
    if (error is DashboardHttpException) {
      final status = error.statusCode;
      return status >= 400 && status < 500 && status != 408 && status != 429;
    }
    if (error is! TuiGatewayRpcError) return false;
    if (error.compressionReason ==
        CompressionFailureReason.exclusiveSubmitCapabilityDenied) {
      return true;
    }
    if (error.failureKind == TuiGatewayRpcFailureKind.timeout ||
        error.failureKind == TuiGatewayRpcFailureKind.connectionLost) {
      return false;
    }
    // Un preflight local ("no es seguro aceptar ahora") es transitorio por
    // diseño: el socket está renegociando generación/canal. Tratarlo como
    // terminal abortaba el backoff al primer flap y declaraba perdido un
    // turno que el servidor estaba completando con normalidad.
    if (error.origin == CompressionFailureOrigin.localPreflight) {
      return error.code != null;
    }
    // Fail closed on remote RPC errors. Only the gateway's documented busy
    // response is retryable; typed transport failures were handled above.
    return error.code != 5001;
  }

  void _scheduleDesktopTurnRecovery(
    HermesDesktopGateway gateway,
    int turnEpoch,
    Object originalError,
  ) {
    if (!_canRecoverTurn(turnEpoch) ||
        _recoveringDesktopTurnEpoch == turnEpoch) {
      return;
    }
    debugPrint('[active-chat] recovery scheduled');
    late final Future<void> recovery;
    recovery = _recoverDesktopTurn(gateway, turnEpoch, originalError)
        .whenComplete(() {
          if (identical(_desktopTurnRecovery, recovery)) {
            _desktopTurnRecovery = null;
          }
        });
    _desktopTurnRecovery = recovery;
    unawaited(recovery);
  }

  Future<void> _recoverDesktopTurn(
    HermesDesktopGateway gateway,
    int turnEpoch,
    Object originalError,
  ) async {
    if (!_canRecoverTurn(turnEpoch)) return;
    if (_recoveringDesktopTurnEpoch == turnEpoch) return;
    _recoveringDesktopTurnEpoch = turnEpoch;
    _activityWatchdogTimer?.cancel();
    _activityWatchdogTimer = null;
    _publishTransportState(ChatTransportState.offline);
    state = ChatPipelineState.connecting;
    _emit(ActiveChatEvent.connected);
    try {
      final delivery = _activeTurnDelivery;
      final HermesDesktopIdempotentGateway? idempotentGateway =
          gateway is HermesDesktopIdempotentGateway
          ? gateway as HermesDesktopIdempotentGateway
          : null;
      if (delivery == null || idempotentGateway == null) {
        if (gateway is! HermesDesktopSessionLifecycleGateway &&
            gateway is! HermesDesktopRecoverySessionLifecycleGateway) {
          _degradeLegacyTurnRecovery(turnEpoch, originalError);
          return;
        }
        await _recoverDesktopTurnFromSnapshot(
          gateway,
          turnEpoch,
          originalError,
        );
        return;
      }
      final canUseIdempotency = await _canUseTurnIdempotency(gateway);
      if (!_canRecoverTurn(turnEpoch)) return;
      if (!canUseIdempotency) {
        // The official gateway does not publish `turn_idempotency_v1`. Without
        // it the turn is still recoverable through the live session: resume it
        // and adopt `inflight`/`running` instead of failing the turn outright.
        if (gateway is HermesDesktopSessionLifecycleGateway ||
            gateway is HermesDesktopRecoverySessionLifecycleGateway) {
          await _recoverDesktopTurnFromSnapshot(
            gateway,
            turnEpoch,
            originalError,
          );
        } else {
          _degradeLegacyTurnRecovery(turnEpoch, originalError);
        }
        return;
      }

      // Paridad con Desktop: una pérdida de cobertura no es un fallo terminal.
      // Seguimos marcando el turno como vivo y reemplazamos el socket con
      // backoff acotado (15 s máximo entre intentos) hasta que vuelva la red,
      // el usuario cancele, llegue un terminal o se destruya el chat.
      final epochInvalidated = _turnEpochInvalidated.future;
      var attempt = 0;
      Object lastError = originalError;
      while (_canRecoverTurn(turnEpoch)) {
        final delay = _desktopRecoveryDelayForAttempt(attempt);
        attempt++;
        debugPrint('[active-chat] recovery attempt $attempt');
        if (!_canRecoverTurn(turnEpoch)) return;
        if (delay > Duration.zero) {
          final elapsed = await _waitForDesktopRecoveryDelay(
            delay,
            epochInvalidated,
          );
          if (!elapsed || !_canRecoverTurn(turnEpoch)) return;
        }
        if (!_canRecoverTurn(turnEpoch)) return;
        _publishTransportState(ChatTransportState.reconnecting);
        try {
          final connected = await _desktopRecoveryOperationBeforeDeadline(
            gateway.connect().then((_) => true),
            epochInvalidated,
          );
          if (connected == null || !_canRecoverTurn(turnEpoch)) return;
          debugPrint('[active-chat] ticket ok');
          debugPrint('[active-chat] connected');
          debugPrint('[active-chat] resume start');
          final binding = await _desktopRecoveryOperationBeforeDeadline(
            _resumeDesktopSessionForRecovery(
              gateway,
              serverSessionId,
              profile: _turnProfile,
              legacyModel: _lastModel,
              deferRuntimeCommit: true,
            ),
            epochInvalidated,
          );
          if (binding == null || !_canRecoverTurn(turnEpoch)) return;
          final status = await _desktopRecoveryOperationBeforeDeadline(
            idempotentGateway.getTurnStatus(
              binding.runtimeSessionId,
              delivery.current.clientTurnId,
            ),
            epochInvalidated,
          );
          if (status == null || !_canRecoverTurn(turnEpoch)) return;
          _publishDashboardAuthRequired(false);
          final resultKind = status.known
              ? status.state?.name ?? 'unknown'
              : 'unknown';
          debugPrint('[active-chat] result kind=$resultKind');
          if (!status.known || status.state == null) continue;
          switch (status.state!) {
            case DesktopTurnState.accepted:
              if (!_commitDesktopRecoverySnapshot(gateway, binding)) continue;
              _desktopStoredSessionId = binding.storedSessionId;
              _adoptDesktopRuntime(
                binding.runtimeSessionId,
                info: binding.info,
              );
              _usingDesktopGateway = true;
              state = ChatPipelineState.waiting;
              _armActivityWatchdog();
              _emit(ActiveChatEvent.waiting);
              return;
            case DesktopTurnState.running:
              final recoveryProof = _prepareDesktopRecoverySnapshot(
                gateway,
                binding,
              );
              if (recoveryProof == null ||
                  gateway is! HermesDesktopTypedRecoveryGateway ||
                  !_desktopRecoveryProofStillCurrent(
                    recoveryProof,
                    gateway,
                    turnEpoch,
                  )) {
                continue;
              }
              // Durable ownership must exist before recovery authority is
              // committed. A timeout leaves the proof unconsumed so the next
              // exact resume can retry safely.
              final markedRunning =
                  delivery.current.state == PreparedTurnState.running
                  ? true
                  : await _desktopRecoveryOperationBeforeDeadline(
                      delivery.markRunning().then((_) => true),
                      epochInvalidated,
                    );
              if (markedRunning == null ||
                  !_desktopRecoveryProofStillCurrent(
                    recoveryProof,
                    gateway,
                    turnEpoch,
                  ) ||
                  !(gateway as HermesDesktopTypedRecoveryGateway)
                      .validateRecovery(recoveryProof)) {
                continue;
              }
              if (!(gateway as HermesDesktopTypedRecoveryGateway)
                  .commitRecovery(recoveryProof)) {
                continue;
              }
              _desktopStoredSessionId = binding.storedSessionId;
              _adoptDesktopRuntime(
                binding.runtimeSessionId,
                info: binding.info,
              );
              _usingDesktopGateway = true;
              state = ChatPipelineState.executing;
              _armActivityWatchdog();
              _emit(ActiveChatEvent.toolProgress);
              return;
            case DesktopTurnState.terminal:
              if (!_canRecoverTurn(turnEpoch)) return;
              // Exact terminal status does not adopt a runtime or replay cut.
              debugPrint('[active-chat] converged kind=terminal');
              await _completeRun();
              return;
            case DesktopTurnState.failed:
              if (!_canRecoverTurn(turnEpoch)) return;
              if (!_commitDesktopRecoverySnapshot(gateway, binding)) continue;
              _failRun('Hermes confirmó que el turno falló tras reconectar.');
              return;
            case DesktopTurnState.cancelled:
              if (!_canRecoverTurn(turnEpoch)) return;
              if (!_commitDesktopRecoverySnapshot(gateway, binding)) continue;
              _cancelRunState();
              return;
          }
        } catch (error) {
          if (!_canRecoverTurn(turnEpoch)) return;
          _publishTransportState(
            gateway.isConnected
                ? ChatTransportState.reconnecting
                : ChatTransportState.offline,
          );
          lastError = error;
          if (_isDashboardAuthRequired(error)) {
            _publishDashboardAuthRequired(true);
          }
          if (_isTerminalDesktopRecoveryError(error)) break;
        }
      }
      if (_canRecoverTurn(turnEpoch)) {
        debugPrint(activeChatDesktopRecoveryDiagnostic(lastError));
        _failRun(activeChatDesktopRecoveryUiMessage(lastError));
      }
    } finally {
      if (gateway.isConnected) {
        _publishTransportState(ChatTransportState.connected);
      }
      if (_recoveringDesktopTurnEpoch == turnEpoch) {
        _recoveringDesktopTurnEpoch = null;
      }
    }
  }

  Future<void> _recoverDesktopTurnFromSnapshot(
    HermesDesktopGateway gateway,
    int turnEpoch,
    Object originalError,
  ) async {
    final epochInvalidated = _turnEpochInvalidated.future;
    var attempt = 0;
    var transcriptAttempted = false;
    Object lastError = originalError;
    debugPrint('[active-chat] snapshot recovery start');
    while (_canRecoverTurn(turnEpoch)) {
      final delay = _desktopRecoveryDelayForAttempt(attempt);
      attempt++;
      debugPrint('[active-chat] snapshot recovery attempt $attempt');
      if (delay > Duration.zero) {
        final elapsed = await _waitForDesktopRecoveryDelay(
          delay,
          epochInvalidated,
        );
        if (!elapsed || !_canRecoverTurn(turnEpoch)) return;
      }
      if (!transcriptAttempted) {
        transcriptAttempted = true;
        if (await _tryAdoptDurableTranscriptForRecoveringTurn(turnEpoch)) {
          debugPrint(
            '[active-chat] snapshot recovery converged kind=durable_transcript',
          );
          return;
        }
        if (!_canRecoverTurn(turnEpoch)) return;
      }
      try {
        final connected = await _desktopRecoveryOperationBeforeDeadline(
          gateway.connect().then((_) => true),
          epochInvalidated,
        );
        if (connected == null || !_canRecoverTurn(turnEpoch)) return;
        final storedSessionId = _desktopStoredSessionId ?? serverSessionId;
        DesktopRosterBoundRecovery? rosterRecovery;
        DesktopSessionSnapshot? snapshot;
        if (gateway is HermesDesktopRosterBoundRecoveryGateway) {
          try {
            rosterRecovery = await _desktopRecoveryOperationBeforeDeadline(
              _resumeAdvertisedDesktopSessionForRecovery(
                gateway,
                storedSessionId,
                profile: _turnProfile,
              ),
              epochInvalidated,
            );
            if (rosterRecovery == null || !_canRecoverTurn(turnEpoch)) return;
            snapshot = rosterRecovery.snapshot;
          } catch (error) {
            if (!_canRecoverTurn(turnEpoch)) return;
            if (_isDashboardAuthRequired(error)) rethrow;
          }
        }
        snapshot ??= await _desktopRecoveryOperationBeforeDeadline(
          _resumeDesktopSessionForRecovery(
            gateway,
            storedSessionId,
            profile: _turnProfile,
            legacyModel: _lastModel,
            deferRuntimeCommit: true,
          ),
          epochInvalidated,
        );
        if (snapshot == null || !_canRecoverTurn(turnEpoch)) return;
        if (snapshot is DesktopSessionBinding) {
          debugPrint(
            '[active-chat] snapshot recovery result kind=legacy_binding',
          );
          debugPrint(
            '[active-chat] snapshot recovery gave up kind=legacy_binding attempts=$attempt',
          );
          _degradeLegacyTurnRecovery(turnEpoch, originalError);
          return;
        }
        final resultKind = _desktopSnapshotRecoveryResultKind(snapshot);
        debugPrint('[active-chat] snapshot recovery result kind=$resultKind');
        if (!snapshot.running && snapshot.inflight == null) {
          if (await _tryAdoptDurableTranscriptForRecoveringTurn(turnEpoch)) {
            debugPrint(
              '[active-chat] snapshot recovery converged kind=durable_transcript',
            );
            return;
          }
          if (!_canRecoverTurn(turnEpoch)) return;
          if (!snapshot.messagesProvided ||
              !_desktopSnapshotTranscriptIsComplete(snapshot)) {
            debugPrint(
              '[active-chat] snapshot recovery result kind=durable_pending',
            );
            continue;
          }
        }
        final committed = rosterRecovery != null
            ? (gateway as HermesDesktopRosterBoundRecoveryGateway)
                  .consumeRosterBoundRecovery(rosterRecovery)
            : _commitDesktopRecoverySnapshot(gateway, snapshot);
        if (!committed) {
          debugPrint(
            '[active-chat] snapshot recovery result kind=authority_pending',
          );
          continue;
        }
        _publishDashboardAuthRequired(false);
        debugPrint(
          '[active-chat] snapshot recovery converged kind=$resultKind',
        );
        _applyDesktopRecoverySnapshot(snapshot, turnEpoch);
        return;
      } catch (error) {
        if (!_canRecoverTurn(turnEpoch)) return;
        lastError = error;
        if (_isDashboardAuthRequired(error)) {
          _publishDashboardAuthRequired(true);
        }
        final terminal = _isTerminalDesktopRecoveryError(error);
        debugPrint(
          '[active-chat] snapshot recovery result kind=${terminal ? 'terminal_error' : 'transient_error'}',
        );
        if (terminal) break;
      }
    }
    if (_canRecoverTurn(turnEpoch)) {
      debugPrint(
        '[active-chat] snapshot recovery gave up kind=terminal_error attempts=$attempt',
      );
      debugPrint(activeChatDesktopRecoveryDiagnostic(lastError));
      _failRun(activeChatDesktopRecoveryUiMessage(lastError));
    }
  }

  String _desktopSnapshotRecoveryResultKind(DesktopSessionSnapshot snapshot) {
    if (snapshot.running) {
      return snapshot.inflight == null ? 'running' : 'inflight';
    }
    final status = snapshot.status?.trim().toLowerCase();
    return switch (status) {
      'completed' || 'complete' || 'done' => 'completed',
      'failed' || 'error' => 'failed',
      'cancelled' || 'canceled' => 'cancelled',
      _ => 'idle',
    };
  }

  void _applyDesktopRecoverySnapshot(
    DesktopSessionSnapshot snapshot,
    int turnEpoch,
  ) {
    if (!_canRecoverTurn(turnEpoch)) return;
    final previousMessagesNewestFirst = List<Map<String, dynamic>>.unmodifiable(
      _messages.map(
        (message) => Map<String, dynamic>.unmodifiable(
          Map<String, dynamic>.from(message),
        ),
      ),
    );
    _recordDurablePrivateTranscriptVetoes(snapshot.messages);
    // Recovery is a newer authoritative publication than any refresh that was
    // already in flight when the socket dropped.
    _messageLoadEpoch += 1;
    // Recovery puede recibir el mismo ack diferido que la apertura normal.
    // Sin un REST fresco que demuestre cobertura completa, conserva el
    // fallback visible pero deja armado el refetch al llegar `complete`.
    _desktopHistoryHydrating = snapshot.hydrating;
    _desktopHistoryNeedsHydration = snapshot.hydrating;
    if (snapshot.hydrating) _desktopHydrationOutcome = null;
    const reconciler = DesktopSessionReconciler();
    final snapshotTranscriptComplete = _desktopSnapshotTranscriptIsComplete(
      snapshot,
    );
    if (snapshotTranscriptComplete && snapshot.messagesProvided) {
      _suppressTerminalHydrationAfterCompaction = false;
    }
    final preferFallback =
        _messages.isNotEmpty &&
        (!snapshotTranscriptComplete || snapshot.messages.isEmpty);
    final terminalSnapshot = !snapshot.running && snapshot.inflight == null;
    final persistedTail = snapshot.messagesProvided
        ? reconciler
              .project(_withoutLiveDesktopProjection(snapshot))
              .messagesNewestFirst
        : const <Map<String, dynamic>>[];
    final terminalTailCompletesCurrentTurn =
        terminalSnapshot &&
        _partialTerminalTailCompletesCurrentTurn(persistedTail);
    final terminalSnapshotNeedsProof =
        preferFallback &&
        terminalSnapshot &&
        (!snapshotTranscriptComplete || snapshot.messages.isEmpty);
    if (terminalSnapshotNeedsProof && !terminalTailCompletesCurrentTurn) {
      // A terminal status does not prove that a partial message window covers
      // this turn. Keep the visible prompt/partial intact and fall back to a
      // full transcript read; otherwise an assistant-only page could delete
      // the prompt or an old tool row could falsely seal the run.
      if (snapshot.messagesProvided) {
        _captureArtifactMessages(
          snapshot.messages,
          logicalSessionId: logicalSessionId,
        );
      }
      _recordDesktopSnapshotTranscript(snapshot, preserveVisibleFallback: true);
      _desktopStoredSessionId = snapshot.storedSessionId;
      _rebaseSubagentActivityScope(
        snapshot.runtimeSessionId,
        reconnectEvidence: snapshot,
      );
      _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
      _hydrateAgentTasks(snapshot.todoState);
      _reconcileSubagentsFromTranscript();
      _desktopStoredSessionKnownMissing = false;
      _desktopRuntimeInfo = snapshot.info;
      _rememberDesktopLiveStatus(snapshot.status, running: false);
      _desktopStartedAt = snapshot.startedAt;
      _desktopTurnStartedAt = null;
      _replaceDesktopAcceptedQueue(snapshot.queued?.user);
      _restorePendingClarify(snapshot);
      _restorePendingApproval(snapshot);
      _usingDesktopGateway = true;
      _degradeLegacyTurnRecovery(
        turnEpoch,
        StateError('terminal recovery snapshot did not cover current turn'),
      );
      return;
    }
    var rawFallback = _messages;
    _RefreshedTranscriptGraft? acceptedTerminalTail;
    if (preferFallback &&
        snapshot.messagesProvided &&
        snapshot.messages.isNotEmpty &&
        !snapshot.running &&
        snapshot.inflight == null) {
      // A terminal recovery snapshot may expose only the newest durable page.
      // It is still authoritative for that tail: merge it by stable IDs and
      // discard the superseded synthetic inflight rows before sealing the run.
      // Older visible coverage is retained only when the graft can prove its
      // position; content equality is never used as identity.
      final durableFallback = _messages
          .where(
            (message) =>
                message['_desktopSnapshotKind'] != 'inflight' &&
                message['_pipeline'] != true &&
                message['_optimistic'] != true,
          )
          .toList(growable: false);
      final graft = _graftRefreshedTail(
        persistedTail,
        durableFallback,
        refreshedTranscriptComplete: false,
      );
      if (graft.acceptedRefreshed) {
        acceptedTerminalTail = graft;
        rawFallback = _preserveLocalAssistantErrors(graft.messages, _messages);
      }
    }
    final fallback = preferFallback && snapshot.messagesProvided
        ? reconciler.overlayDurableDisplayMetadata(
            rawFallback,
            snapshot.messages,
          )
        : _messages;
    final projectionSource = preferFallback
        ? _withoutPersistedMessages(snapshot)
        : snapshot;
    final projection = reconciler.project(
      projectionSource,
      fallbackNewestFirst: fallback,
      previousNewestFirst: previousMessagesNewestFirst,
      bridgeOwnedLiveUser: true,
      retainMediaEvidence: true,
    );
    if (snapshot.messagesProvided) {
      _captureArtifactMessages(
        snapshot.messages,
        logicalSessionId: logicalSessionId,
      );
      if (preferFallback &&
          (!snapshotTranscriptComplete || snapshot.messages.isEmpty)) {
        final terminalTail = acceptedTerminalTail;
        _recordDesktopSnapshotTranscript(
          snapshot,
          preserveVisibleFallback:
              terminalTail == null || terminalTail.preservesExistingCoverage,
        );
        if (terminalTail != null) {
          _commitRefreshedTailEvidence(persistedTail, terminalTail);
        }
      }
    } else {
      final announcedCount = snapshot.messageCount;
      final durableFallbackCount = _durableTranscriptCoverageCount(_messages);
      final fallbackCoverageIsInsufficient =
          announcedCount == null ||
          durableFallbackCount == null ||
          announcedCount != durableFallbackCount;
      if (!preferFallback ||
          fallbackCoverageIsInsufficient ||
          _desktopHistoryNeedsHydration) {
        _recordDesktopSnapshotTranscript(
          snapshot,
          preserveVisibleFallback: preferFallback,
        );
      }
    }
    final incomingTranscriptComplete = preferFallback
        ? _transcriptIsComplete
        : snapshotTranscriptComplete;
    _messages = _applyCancelledTurnTombstonesForDisplay(
      _associateGeneratedImagesNewestFirst(
        _sanitizeDesktopFailureProjection(
          projection.messagesNewestFirst.map(Map<String, dynamic>.from),
        ),
      ),
      incomingTranscriptComplete: incomingTranscriptComplete,
    );
    if (!projection.running) {
      _sealRecoveredLiveActivity(completed: !projection.failed);
    }
    if (snapshot.messagesProvided && !preferFallback) {
      _recordDesktopSnapshotTranscript(snapshot);
    }
    _mergeSteerRecords();
    _desktopStoredSessionId = snapshot.storedSessionId;
    _rebaseSubagentActivityScope(
      snapshot.runtimeSessionId,
      reconnectEvidence: snapshot,
    );
    _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
    _hydrateAgentTasks(snapshot.todoState);
    _reconcileSubagentsFromTranscript();
    _desktopStoredSessionKnownMissing = false;
    _desktopRuntimeInfo = snapshot.info;
    _rememberDesktopLiveStatus(projection.status, running: projection.running);
    _desktopStartedAt = snapshot.startedAt;
    _desktopTurnStartedAt = projection.running
        ? snapshot.resolvedTurnStartedAt
        : null;
    _replaceDesktopAcceptedQueue(projection.queuedUser);
    _restorePendingClarify(snapshot);

    if (projection.failed) {
      _sealRecoveredLiveActivity(completed: false);
      final failure =
          snapshot.inflight?.error ??
          StateError('desktop recovery snapshot reported failure');
      debugPrint(activeChatDesktopRecoveryDiagnostic(failure));
      _failRun(
        activeChatDesktopSnapshotFailureUiMessage(snapshot.inflight?.error),
      );
      return;
    }
    if (projection.running) {
      _usingDesktopGateway = true;
      state = snapshot.inflight?.assistant?.isNotEmpty == true
          ? ChatPipelineState.streaming
          : ChatPipelineState.executing;
      _emit(ActiveChatEvent.toolProgress);
      return;
    }

    _usingDesktopGateway = true;
    _sealRecoveredLiveActivity(completed: true);
    final finalText = _latestTurnAssistantText(
      projection.messagesNewestFirst.reversed.toList(growable: false),
      projection.messagesNewestFirst.where(isRealUserTurn).length,
    );
    unawaited(_completeRun(finalOutput: finalText));
  }

  void _sealRecoveredLiveActivity({required bool completed}) {
    for (final event in trace) {
      if (!event.isDone && !event.isFailed) {
        event.status = completed ? 'completed' : 'interrupted';
      }
    }
    final current = _subagentActivities;
    if (current == null) return;
    final entries = <SubagentActivityKey, SubagentActivity>{};
    for (final entry in current.entries.entries) {
      final activity = entry.value;
      entries[entry.key] = activity.isTerminal
          ? activity
          : SubagentActivity(
              key: activity.key,
              source: activity.source,
              phase: completed
                  ? SubagentActivityPhase.completed
                  : SubagentActivityPhase.cancelled,
              details: activity.details,
              subagentId: activity.subagentId,
              delegationId: activity.delegationId,
              childSessionId: activity.childSessionId,
              legacyToolCallId: activity.legacyToolCallId,
              eventRevision: activity.eventRevision,
              seenEventIds: activity.seenEventIds,
            );
    }
    _subagentActivities = SubagentActivityState.withEntries(
      current.scope,
      entries,
    );
    _subagentMutationGeneration += 1;
    _refreshCurrentSubagentPublicProjection();
  }

  /// Un transporte legacy sin idempotencia no puede demostrar a qué turno
  /// pertenece un transcript leído después de perder el socket. Conserva la
  /// proyección visible y deja una recuperación durable explícita; no adopta
  /// GET tardíos, no publica terminalidad y no libera la cola.
  void _degradeLegacyTurnRecovery(int turnEpoch, Object originalError) {
    if (!_canRecoverTurn(turnEpoch) || awaitingDurableTurnRecovery) return;
    debugPrint(activeChatDesktopRecoveryDiagnostic(originalError));
    _turnSubmittedAtMs = null;
    _activityWatchdogTimer?.cancel();
    _activityWatchdogTimer = null;
    _setNoActivityHint(false);
    _flushTokenBuffer();
    state = ChatPipelineState.failed;
    traceActive = false;
    _cancelling = false;
    final hasPartial =
        _messages.isNotEmpty &&
        _messages.first['role'] == 'assistant' &&
        ((_messages.first['content'] as String?) ?? '').trim().isNotEmpty;
    if (hasPartial) {
      final partialProjection = <String, dynamic>{
        ..._messages.first,
        '_pipeline': false,
        _awaitingDurableTurnRecoveryKey: true,
        'partial': true,
        'recoverable': true,
      };
      _messages.first = partialProjection;
      final projectionId = _nextLocalTranscriptProjectionId();
      _tagLatestUserForLocalError(projectionId);
      _messages.insert(0, {
        'role': 'assistant_error',
        'content': activeChatDesktopRecoveryUiMessage(originalError),
        '_prompt': lastPrompt,
        _awaitingDurableTurnRecoveryKey: true,
        'partial': true,
        'recoverable': true,
        _legacyRecoveryPartialProjectionKey: partialProjection,
        '_localTranscriptProjectionId': projectionId,
      });
    } else if (_messages.isNotEmpty && _messages.first['role'] == 'assistant') {
      final projectionId = _nextLocalTranscriptProjectionId();
      _tagLatestUserForLocalError(projectionId);
      _messages.first = {
        'role': 'assistant_error',
        'content': activeChatDesktopRecoveryUiMessage(originalError),
        '_prompt': lastPrompt,
        _awaitingDurableTurnRecoveryKey: true,
        'recoverable': true,
        '_localTranscriptProjectionId': projectionId,
      };
    }
    _emit(ActiveChatEvent.error);
  }

  Future<List<Map<String, dynamic>>> _loadRecoveryTranscript(
    String storedId,
    String profile,
  ) async {
    final gateway = _desktopGateway;
    if (_storedMessageLoader != null ||
        !(_attachDesktopRuntimeOnLoad ||
            _allowUnownedDesktopSnapshotForTesting) ||
        gateway == null ||
        !gateway.isConnected ||
        gateway is! HermesDesktopSessionHistoryGateway ||
        _desktopRuntimeSessionId == null) {
      return _loadStoredMessages(profile);
    }
    final pages = <List<Map<String, dynamic>>>[];
    final signatures = <String>{};
    List<Map<String, dynamic>> withContent(
      List<Map<String, dynamic>> messages,
    ) => [
      for (final message in messages)
        if (message['content'] == null && message['text'] is String)
          // Native history uses text; retain every authority/private flag.
          {...message, 'content': message['text']}
        else
          message,
    ];
    var offset = 0;
    while (true) {
      final page = await _requestStoredMessagesPage(
        storedSessionId: storedId,
        profile: profile,
        limit: 500,
        offset: offset,
        allowNativeHistory: false,
      );
      if (!page.messagesFullyParsed || !page.paginationFullyParsed) {
        throw StateError('Incomplete recovery transcript');
      }
      if (!page.paginationProvided) return withContent(page.messages);
      if (page.limit != 500 || page.offset != offset) {
        throw StateError('Invalid recovery pagination');
      }
      pages.add(page.messages);
      if (page.returned < 500) break;
      if (!signatures.add(jsonEncode(page.messages))) {
        throw StateError('Recovery pagination stalled');
      }
      offset += page.returned;
    }
    return withContent([for (final page in pages.reversed) ...page]);
  }

  // A disconnected turn needs complete durable evidence before it can settle.
  Future<bool> _tryAdoptDurableTranscriptForRecoveringTurn(
    int turnEpoch,
  ) async {
    if (!_canRecoverTurn(turnEpoch)) return false;
    final loadEpoch = _messageLoadEpoch;
    final storedId = serverSessionId;
    final profile = _storedSessionProfile;
    final expectedUsers = _messages.where(isRealUserTurn).length;
    if (expectedUsers <= 0) return false;
    try {
      final transcript = await _desktopRecoveryOperationBeforeDeadline(
        _loadRecoveryTranscript(storedId, profile),
        _turnEpochInvalidated.future,
      );
      if (transcript == null ||
          !_canRecoverTurn(turnEpoch) ||
          loadEpoch != _messageLoadEpoch ||
          storedId != serverSessionId ||
          profile != _storedSessionProfile) {
        return false;
      }
      if (!_restTranscriptCoversAnnouncedCount(transcript)) return false;
      final authority = _terminalAuthority(transcript, expectedUsers);
      if (authority.reason != TerminalAuthorityReason.finalAssistant) {
        return false;
      }
      if (!_terminalTranscriptCanReplaceVisibleProjection(
        transcript,
        expectedUsers,
      )) {
        return false;
      }
      await _completeRun(
        finalOutput: authority.assistantText,
        authoritativeTranscript: transcript,
      );
      return state == ChatPipelineState.completed;
    } catch (_) {
      return false;
    }
  }

  /// Production [ApiClient.getMessages] already walks pages to the end.
  /// Injected test loaders have no pagination metadata, so an announced
  /// count still larger than the list means the GET is a tail, not coverage.
  bool _restTranscriptCoversAnnouncedCount(
    List<Map<String, dynamic>> transcript,
  ) {
    final hydration = _desktopHydrationExpectedMessageCount;
    final hard = _hardExpectedStoredMessageCount;
    final announced = hydration == null
        ? hard
        : hard == null
        ? hydration
        : math.max(hydration, hard);
    if (announced == null || announced <= 0) return true;
    return transcript.length >= announced;
  }

  Future<void> _recoverRestTurnFromTranscript(
    int turnEpoch,
    Object originalError,
  ) async {
    final messageLoadEpoch = _messageLoadEpoch;
    final expectedUsers = _messages.where(isRealUserTurn).length;
    final epochInvalidated = _turnEpochInvalidated.future;
    const delays = <Duration>[
      Duration.zero,
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 6),
      Duration(seconds: 8),
      Duration(seconds: 8),
    ];
    bool stillCurrent() =>
        _canRecoverTurn(turnEpoch) && messageLoadEpoch == _messageLoadEpoch;
    for (final delay in delays) {
      if (!stillCurrent()) return;
      if (delay > Duration.zero) {
        final elapsed = await _waitForTerminalReconcileDelay(
          delay,
          epochInvalidated,
        );
        if (!elapsed || !stillCurrent()) return;
      }
      try {
        final transcript = await _loadStoredMessages(_storedSessionProfile);
        if (!stillCurrent()) return;
        final authority = _terminalAuthority(transcript, expectedUsers);
        if (authority.reason == TerminalAuthorityReason.finalAssistant) {
          await _completeRun(
            finalOutput: authority.assistantText,
            authoritativeTranscript: transcript,
          );
          return;
        }
      } catch (error) {
        if (RegExp(r'HTTP 4\d\d').hasMatch(error.toString())) break;
      }
    }
    if (stillCurrent()) {
      _failRun(
        activeChatDesktopRecoveryUiMessage(originalError),
        failureMetadata: const {_awaitingDurableTurnRecoveryKey: true},
      );
    }
  }

  /// Texto del asistente del TURNO ACTUAL (tras el último mensaje de usuario
  /// esperado) en un transcript cronológico, o null si aún no hay texto. A
  /// diferencia de [_containsCompletedTurn], NO da por buena la presencia de
  /// tools: exige texto real del asistente, que es lo que falta en el bug S3.
  String? _latestTurnAssistantText(
    List<Map<String, dynamic>> chronological,
    int expectedUsers,
  ) => _terminalAuthority(chronological, expectedUsers).assistantText;

  bool _partialTerminalTailCompletesCurrentTurn(
    List<Map<String, dynamic>> tailNewestFirst,
  ) {
    TranscriptMessageIdentity? currentUserIdentity;
    for (final message in _messages) {
      if (!isRealUserTurn(message)) continue;
      currentUserIdentity = _transcriptMessageIdentity(message);
      break;
    }
    if (currentUserIdentity == null || tailNewestFirst.isEmpty) return false;
    final chronological = tailNewestFirst.reversed.toList(growable: false);
    final user = _resolveTranscriptIdentity(
      chronological,
      messageId: currentUserIdentity.messageId,
      rowId: currentUserIdentity.rowId,
      accepts: isRealUserTurn,
    );
    if (user.kind != _TranscriptIdentityResolutionKind.unique) return false;
    final currentTurn = chronological.sublist(user.index);
    return _terminalAuthority(
          currentTurn,
          1,
          source: TerminalEvidenceSource.desktopSnapshot,
          sourceTranscriptComplete: false,
        ).kind ==
        TerminalAuthorityKind.authoritativeSuccess;
  }

  bool _containsDurableFinalAssistantTurn(
    List<Map<String, dynamic>> chronological,
    int expectedUsers,
  ) =>
      _terminalAuthority(chronological, expectedUsers).reason ==
      TerminalAuthorityReason.finalAssistant;

  void _scheduleTerminalTranscriptRecovery(
    int completingEpoch, {
    required int messageLoadEpoch,
    required bool requireAssistantText,
  }) {
    if (_isDetachedIdle) return;
    if (_terminalTranscriptRecoveryEpoch == completingEpoch &&
        _terminalTranscriptRecovery != null) {
      return;
    }
    final bindEpoch = _desktopBindEpoch;
    final sessionEpoch = _desktopSessionEpoch;
    final socketGeneration = _desktopTerminalTransportGeneration;
    final producerChannel = _desktopTerminalProducerChannel;
    final previous = _terminalTranscriptRecovery;
    late final Future<void> recovery;
    recovery =
        () async {
          if (previous != null) await previous;
          if (!_terminalRecoveryAuthorityStillCurrent(
            completingEpoch: completingEpoch,
            messageLoadEpoch: messageLoadEpoch,
            bindEpoch: bindEpoch,
            sessionEpoch: sessionEpoch,
            socketGeneration: socketGeneration,
            producerChannel: producerChannel,
          )) {
            return;
          }
          await _recoverTerminalTranscriptLate(
            completingEpoch,
            messageLoadEpoch: messageLoadEpoch,
            requireAssistantText: requireAssistantText,
            bindEpoch: bindEpoch,
            sessionEpoch: sessionEpoch,
            socketGeneration: socketGeneration,
            producerChannel: producerChannel,
          );
        }().whenComplete(() {
          if (!identical(_terminalTranscriptRecovery, recovery)) return;
          _terminalTranscriptRecovery = null;
          _terminalTranscriptRecoveryEpoch = null;
        });
    _terminalTranscriptRecoveryEpoch = completingEpoch;
    _terminalTranscriptRecovery = recovery;
  }

  bool _terminalRecoveryAuthorityStillCurrent({
    required int completingEpoch,
    required int messageLoadEpoch,
    required int bindEpoch,
    required int sessionEpoch,
    required int? socketGeneration,
    required Object? producerChannel,
  }) =>
      _isCurrentEpoch(completingEpoch) &&
      messageLoadEpoch == _messageLoadEpoch &&
      bindEpoch == _desktopBindEpoch &&
      sessionEpoch == _desktopSessionEpoch &&
      socketGeneration == _desktopTerminalTransportGeneration &&
      identical(producerChannel, _desktopTerminalProducerChannel);

  /// Red de seguridad común para dos carreras del terminal:
  ///  * no llegó texto local (bug S3);
  ///  * sí llegó por streaming, pero API Server aún devuelve 404 para la sesión.
  ///
  /// Relee con backoff acotado, no registra texto privado y solo sustituye la
  /// proyección local cuando el transcript contiene el turno completo.
  Future<void> _recoverTerminalTranscriptLate(
    int completingEpoch, {
    required int messageLoadEpoch,
    required bool requireAssistantText,
    required int bindEpoch,
    required int sessionEpoch,
    required int? socketGeneration,
    required Object? producerChannel,
  }) async {
    final expectedUsers = _messages.where(isRealUserTurn).length;
    debugPrint(
      '[active-chat] terminal transcript recovery started '
      '(users=$expectedUsers, needs_text=$requireAssistantText)',
    );
    final epochInvalidated = _turnEpochInvalidated.future;
    bool stillCurrent() => _terminalRecoveryAuthorityStillCurrent(
      completingEpoch: completingEpoch,
      messageLoadEpoch: messageLoadEpoch,
      bindEpoch: bindEpoch,
      sessionEpoch: sessionEpoch,
      socketGeneration: socketGeneration,
      producerChannel: producerChannel,
    );
    final delays = requireAssistantText
        ? const <Duration>[
            Duration(seconds: 1),
            Duration(seconds: 2),
            Duration(seconds: 3),
            Duration(seconds: 5),
            Duration(seconds: 8),
            Duration(seconds: 8),
          ]
        : const <Duration>[
            // La respuesta ya está segura en la proyección local. Solo damos al
            // commit normal del API un margen corto que no supera el timer
            // terminal de 800 ms ni mantiene un chat cerrado artificialmente.
            Duration(milliseconds: 100),
            Duration(milliseconds: 250),
            Duration(milliseconds: 400),
          ];
    for (final delay in delays) {
      if (!stillCurrent()) return;
      if (requireAssistantText && assistantContent.trim().isNotEmpty) return;
      final elapsed = await _waitForTerminalReconcileDelay(
        delay,
        epochInvalidated,
      );
      if (!elapsed || !stillCurrent()) return;
      if (requireAssistantText && assistantContent.trim().isNotEmpty) return;
      try {
        final transcript = await _loadStoredMessages(_storedSessionProfile);
        if (!stillCurrent()) return;
        final applied = _applyAuthoritativeTerminalTranscriptOnce(
          transcript,
          completingEpoch: completingEpoch,
          messageLoadEpoch: messageLoadEpoch,
        );
        if (applied && stillCurrent()) {
          _commitTerminalSideEffectsOnce(completingEpoch);
          return;
        }
      } catch (error) {
        // 404 es precisamente la carrera observada: la sesión todavía no es
        // visible. 401/403 sí son permanentes para este intento.
        if (RegExp(r'HTTP (401|403)\b').hasMatch(error.toString())) return;
        debugPrint(
          '[active-chat] terminal transcript still pending '
          '(${error.runtimeType})',
        );
      }
    }
  }

  /// Background no demuestra que un canal Desktop esté ocioso: el estado
  /// local puede ir por detrás de un turno remoto ya aceptado. Conservamos el
  /// transporte y dejamos que dispose/process death ejecute el cierre real.
  Future<void> suspendIdleDesktopConnection() => Future<void>.value();

  Future<bool> _canUseTurnIdempotency(HermesDesktopGateway gateway) async {
    if (_turnIdempotencyInvalid || gateway is! HermesDesktopIdempotentGateway) {
      return false;
    }
    final cached = _turnIdempotencySupported;
    if (cached != null) return cached;
    try {
      final supported = await _turnIdempotencyCapability();
      _turnIdempotencySupported = supported;
      return supported;
    } catch (_) {
      // A transient probe failure is not a capability verdict; leave the
      // cache empty so the next recovery asks again.
      return false;
    }
  }

  Future<bool> _startRestFallbackWithAttachments(
    String fullText,
    String model,
    List<Map<String, dynamic>> history,
    int turnEpoch,
    List<AttachmentDraft> attachments,
  ) async {
    final mentionAnnotation = botMentionNote(fullText);
    var fallbackText = sanitizeRemoteChatText(stripBotMentionNote(fullText));
    final refs = <String>[];
    final delivery = _activeTurnDelivery;
    final binaryAttachments =
        (delivery?.current.activeAttachments ??
                attachments
                    .where(
                      (item) =>
                          item.uploadState != AttachmentUploadState.removed,
                    )
                    .toList(growable: false))
            .where((item) => !AttachmentUploader.isTextEmbeddable(item))
            .toList(growable: false);
    if (binaryAttachments.isNotEmpty) {
      if (!await _beginTurnTransport(turnEpoch, PreparedTurnTransport.rest)) {
        return false;
      }
      final attachmentOwner = connection.id;
      for (final initialAttachment in binaryAttachments) {
        var attachment = initialAttachment;
        if (delivery != null && attachment.localId.isNotEmpty) {
          final staged = await delivery.beginAttachmentUpload(
            attachment.localId,
            remoteSessionId: attachmentOwner,
            transport: AttachmentRemoteTransport.rest,
          );
          if (staged == null) {
            _failRun(
              delivery.persistenceFailed
                  ? 'No se pudo conservar el estado de un adjunto.'
                  : 'El lote de adjuntos cambió durante la subida.',
            );
            return false;
          }
          attachment = staged;
          if (attachment.isAttachedTo(
            attachmentOwner,
            transport: AttachmentRemoteTransport.rest,
          )) {
            continue;
          }
        }
        AttachmentUploadResult result;
        try {
          result = await _attachmentUploader(connection, attachment);
        } catch (_) {
          result = const AttachmentUploadResult.failure(
            AttachmentErrorKind.transport,
          );
        }
        if (_turnEpoch != turnEpoch || _runTerminal) return false;
        final managedPath = result.managedPath;
        if (!result.ok || managedPath == null || managedPath.isEmpty) {
          if (delivery != null && attachment.localId.isNotEmpty) {
            await delivery.markAttachmentFailed(
              attachment.localId,
              attempt: attachment.attempt,
              errorKind: result.errorKind ?? AttachmentErrorKind.transport,
            );
          }
          _failRun('No se pudo preparar un adjunto para esta instancia.');
          return false;
        }
        if (delivery == null || attachment.localId.isEmpty) {
          refs.add('[Archivo adjunto disponible en $managedPath]');
          continue;
        }
        final persisted = await delivery.markAttachmentAttached(
          attachment.localId,
          attempt: attachment.attempt,
          remoteSessionId: attachmentOwner,
          transport: AttachmentRemoteTransport.rest,
          remoteRef: managedPath,
        );
        if (!persisted) {
          _failRun(
            delivery.persistenceFailed
                ? 'No se pudo conservar el estado de un adjunto.'
                : 'El lote de adjuntos cambió durante la subida.',
          );
          return false;
        }
      }
      await delivery?.waitForAttachmentMutations();
      if (delivery != null) {
        final expectedIds = binaryAttachments
            .map((item) => item.localId)
            .where((id) => id.isNotEmpty)
            .toSet();
        final completed = delivery.current.activeAttachments
            .where(
              (item) =>
                  expectedIds.contains(item.localId) &&
                  item.isAttachedTo(
                    attachmentOwner,
                    transport: AttachmentRemoteTransport.rest,
                  ),
            )
            .toList(growable: false);
        if (completed.length != expectedIds.length) {
          _failRun('El lote de adjuntos cambió durante la subida.');
          return false;
        }
        refs.addAll(
          completed.map(
            (item) => '[Archivo adjunto disponible en ${item.remoteRef}]',
          ),
        );
      }
    }
    if (refs.isNotEmpty) {
      final separator = fallbackText.contains('⟦adjunto⟧')
          ? '\n'
          : '\n⟦adjunto⟧\n';
      fallbackText = '$fallbackText$separator${refs.join('\n')}';
    }
    return _startRemoteRun(
      appendBotMentionNote(fallbackText, mentionAnnotation),
      model,
      history,
      turnEpoch,
    );
  }

  void _onDesktopEvent(TuiGatewayEvent event) {
    final runtimeId = _desktopRuntimeSessionId;
    if (runtimeId == null) return;
    if (event.type == 'sessions.changed') {
      if (desktopChangeEventsAvailable) {
        _signalAdaptiveRefresh(full: true);
        _emit(ActiveChatEvent.sessionInfo);
      } else {
        unawaited(refreshBackgroundProcesses());
        unawaited(refreshSessionControl());
      }
      return;
    }
    if (event.sessionId != runtimeId) return;
    if (event.type == 'session.reclaimed') {
      final receipt = _desktopRuntimeOwnershipReceipt;
      final reclaimedStoredId = event.payload['stored_session_id']?.toString();
      final exactAuthority =
          receipt != null &&
          receipt.connectionId == connection.id &&
          receipt.profile == _storedSessionProfile &&
          receipt.runtimeSessionId == runtimeId &&
          receipt.durableSessionId == _desktopStoredSessionId &&
          reclaimedStoredId == _desktopStoredSessionId &&
          receipt.bindEpoch == _desktopBindEpoch &&
          receipt.sessionEpoch == _desktopSessionEpoch &&
          (receipt.transportGeneration == null ||
              event.transportGeneration == receipt.transportGeneration) &&
          (receipt.producerChannel == null ||
              identical(event.producerChannel, receipt.producerChannel));
      if (!exactAuthority) return;
      _turnSubmittedAtMs = null;
      _activityWatchdogTimer?.cancel();
      _activityWatchdogTimer = null;
      _setNoActivityHint(false);
      _retireDesktopRuntime();
      _usingDesktopGateway = false;
      _runTerminal = true;
      traceActive = false;
      pendingApproval = null;
      _desktopContinuationRequired = false;
      _emit(ActiveChatEvent.sessionInfo);
      unawaited(ensureDesktopRuntime());
      return;
    }
    _observeDesktopOwnershipTransport(event);
    final payload = event.payload;
    if (_usingDesktopGateway &&
        event.type != 'gateway.ping' &&
        event.type != 'gateway.pong') {
      _observeRuntimeActivity();
    }
    if (event.type == 'session.control.update') {
      _signalAdaptiveRefresh();
      _applySessionControlUpdate(payload['control']);
      return;
    }
    if (event.type == 'todo.updated') {
      _applyTodoUpdate(payload);
      return;
    }
    final isTerminal =
        event.type == 'message.complete' || event.type == 'error';
    final stop = _stopTransition;
    if (stop != null &&
        _stopIsCurrent(stop) &&
        (stop.state == _StopTransitionState.interrupting ||
            stop.state == _StopTransitionState.settling)) {
      final rawSessionInfo = payload['info'];
      final sessionInfo = rawSessionInfo is Map ? rawSessionInfo : payload;
      final confirmsInterrupt =
          isTerminal ||
          (event.type == 'session.info' && sessionInfo['running'] == false) ||
          (event.type == 'request.cancel' &&
              (payload['reason'] ?? '').toString().trim().toLowerCase() ==
                  'interrupted');
      if (confirmsInterrupt) {
        _clearDesktopCompactingIndicator();
        if (!stop.terminal.isCompleted) stop.terminal.complete();
        if (event.type != 'session.info') return;
      }
    }
    final interruptDrain = _desktopInterruptDrain;
    if (interruptDrain != null && isTerminal) {
      _clearDesktopCompactingIndicator();
      if (!interruptDrain.isCompleted) interruptDrain.complete();
      _discardLateInterruptTerminal = false;
      return;
    }

    if (_discardLateInterruptTerminal && isTerminal) {
      final terminalText =
          '${payload['text'] ?? payload['rendered'] ?? payload['message'] ?? ''}'
              .toLowerCase();
      _discardLateInterruptTerminal = false;
      if (terminalText.contains('interrupt') ||
          terminalText.contains('cancel')) {
        _clearDesktopCompactingIndicator();
        return;
      }
    }

    if (event.type == 'session.info') {
      _applyDesktopSessionInfo(payload);
      return;
    }
    // Resume diferido (Hermes Agent 0.20): progreso de la hidratación del
    // historial en segundo plano. Se atiende aunque no haya turno vivo.
    if (event.type == 'session.resume_progress') {
      _handleDesktopResumeProgress(payload);
      return;
    }
    if (event.type == 'status.update') {
      final kind = (payload['kind'] ?? payload['status'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (kind == 'process') {
        if (desktopChangeEventsAvailable) {
          _signalAdaptiveRefresh(processes: true);
          _emit(ActiveChatEvent.subagentActivity);
        } else {
          unawaited(refreshBackgroundProcesses());
        }
        return;
      }
      if (const {'goal', 'loop', 'heartbeat'}.contains(kind)) {
        if (desktopChangeEventsAvailable) {
          _signalAdaptiveRefresh(control: true);
          _emit(ActiveChatEvent.goalUpdated);
        } else {
          unawaited(refreshSessionControl());
        }
        return;
      }
      _applyDesktopStatusUpdate(payload);
      return;
    }
    if (event.type == 'background.complete') {
      final taskId = payload['task_id']?.toString().trim() ?? '';
      if (taskId.isNotEmpty) {
        _signalAdaptiveRefresh(processes: true);
        final rawText = payload['text']?.toString() ?? '';
        final isError = rawText.startsWith('error:');
        _backgroundTaskOutcomes[taskId] = (text: rawText, isError: isError);
        _emit(ActiveChatEvent.backgroundTaskComplete);
        unawaited(
          _notifications
                  ?.backgroundTaskFinished(
                    isError: isError,
                    connId: connection.id,
                    sessionId: runtimeId,
                    taskId: taskId,
                    profile: _storedSessionProfile,
                  )
                  .catchError((_) {}) ??
              Future<void>.value(),
        );
      }
      return;
    }
    if (event.type == 'agent.terminal.output' ||
        event.type == 'terminal.close') {
      _signalAdaptiveRefresh(processes: true);
      _emit(ActiveChatEvent.subagentActivity);
      return;
    }
    if (const {
      'vault.unlock.request',
      'vault.save_login.request',
      'vault.code.request',
    }.contains(event.type)) {
      // The mobile client deliberately stores no vault payload or secret origin.
      _desktopContinuationRequired = true;
      _activityWatchdogTimer?.cancel();
      _activityWatchdogTimer = null;
      state = ChatPipelineState.executing;
      _emit(ActiveChatEvent.approvalRequest);
      return;
    }
    if (const {
      'vault.unlock.expire',
      'vault.save_login.expire',
      'vault.code.expire',
      'vault.unlock.expired',
      'vault.save_login.expired',
      'vault.code.expired',
    }.contains(event.type)) {
      if (_desktopContinuationRequired) {
        _desktopContinuationRequired = false;
        _emit(ActiveChatEvent.toolProgress);
      }
      return;
    }
    if (_usingDesktopGateway && _runTerminal && event.type == 'message.start') {
      if (!_isCausallyAfterDesktopTerminal(event)) {
        // Current upstream has no turn_id. Only producer order on the exact
        // transport that delivered the terminal can prove a successor start.
        // Unsequenced, replay-stale, or post-rotation starts fail closed; an
        // authoritative snapshot may still open the external turn.
        return;
      }
      _beginExternallyObservedDesktopTurn(
        DesktopSessionSnapshot(
          runtimeSessionId: runtimeId,
          storedSessionId: _desktopStoredSessionId ?? serverSessionId,
          created: false,
          running: true,
        ),
      );
    }
    if (_isInteractivePromptEvent(event.type)) {
      _handleInteractivePromptEvent(event.type, runtimeId, payload);
      return;
    }
    if (_isInteractivePromptExpiryEvent(event.type)) {
      _handleInteractivePromptExpiry(runtimeId, payload);
      return;
    }
    if (event.type.startsWith('subagent.')) {
      final isLateAuthoritativeCompletion =
          _runTerminal && event.type == 'subagent.complete';
      final isLiveBackgroundUpdate =
          _runTerminal &&
          const {
            'subagent.thinking',
            'subagent.tool',
            'subagent.progress',
          }.contains(event.type) &&
          _matchesLiveSubagent(payload);
      if (_usingDesktopGateway &&
          (!_runTerminal ||
              isLateAuthoritativeCompletion ||
              isLiveBackgroundUpdate)) {
        _signalAdaptiveRefresh(
          subagents: _subagentEventNeedsRosterRepair(event.type, payload),
        );
        _handleNativeSubagentEvent(event.type, runtimeId, payload);
      }
      return;
    }
    if (_usingDesktopGateway && _runTerminal && isTerminal) {
      // The protocol carries no turn_id. A post-terminal transport event cannot
      // be assigned safely, so only durable transcript reconciliation may amend
      // the completed turn.
      return;
    }
    if (!_usingDesktopGateway || _runTerminal) return;

    if (isTerminal) _recordDesktopTerminalFence(event);

    final isLifecycleEvidence = const {
      'message.start',
      'message.delta',
      'message.interim',
      'reasoning.delta',
      'reasoning.available',
      'thinking.delta',
      'tool.start',
      'tool.progress',
      'tool.generating',
      'tool.complete',
      'approval.request',
    }.contains(event.type);
    if (isLifecycleEvidence) {
      _desktopTerminalRequiresLifecycleEvidence = false;
    } else if ((event.type == 'error' ||
            (event.type == 'message.complete' &&
                (payload['status'] ?? '').toString().trim().toLowerCase() ==
                    'error')) &&
        _desktopTerminalRequiresLifecycleEvidence &&
        !_hasPendingTombstoneMetadataUpdate) {
      // Upstream carries no turn_id, so an uncorrelated negative terminal on a
      // reused runtime is ambiguous until the successor emits lifecycle. A
      // successful message.complete remains valid for legacy direct-completion
      // paths. This cannot distinguish a late success from A from a legitimate
      // direct success for B; the protocol must add turn identity to close that
      // remaining gap.
      return;
    }

    switch (event.type) {
      case 'message.start':
        _clearDesktopCompactingIndicator();
        _desktopTurnStartedAt = DateTime.now();
        state = ChatPipelineState.waiting;
        _emit(ActiveChatEvent.waiting);
      case 'reasoning.delta':
      case 'thinking.delta':
        final delta = payload['text'] ?? payload['delta'];
        if (delta is String && delta.isNotEmpty) {
          _retireDesktopInterimSegment();
          _appendAssistantReasoningActivity(delta);
          state = ChatPipelineState.executing;
          _emit(ActiveChatEvent.toolProgress);
        }
      case 'reasoning.available':
        final reasoning = payload['text'] ?? payload['reasoning'];
        if (reasoning is String && reasoning.trim().isNotEmpty) {
          _retireDesktopInterimSegment();
          _appendAssistantReasoningActivity(reasoning, authoritative: true);
          state = ChatPipelineState.executing;
          _emit(ActiveChatEvent.toolProgress);
        }
      case 'message.delta':
        final deltaText = payload['text'];
        final narratable =
            deltaText is String &&
            _isNarrableDesktopAssistantPayload(event.type, payload);
        if (!narratable) break;
        _prepareDesktopPostInterimSegment();
        if (!_streamingConfirmed) {
          _streamingConfirmed = true;
          ConnectionManager.markStreamingSupported(connection.id);
        }
        _enqueueToken(deltaText, narratable: true);
      case 'message.interim':
        final rawText = payload['text'];
        if (rawText is String &&
            _isNarrableDesktopAssistantPayload(event.type, payload)) {
          final publicText = streamingPublicAssistantText(rawText);
          if (publicText.isNotEmpty) {
            _sealDesktopInterim({
              ...payload,
              'text': publicText,
            }, narratable: true);
          }
        }
      case 'tool.start':
      case 'tool.progress':
      case 'tool.generating':
        _retireDesktopInterimSegment();
        _flushTokenBuffer();
        state = ChatPipelineState.executing;
        if (event.type == 'tool.start') {
          _handleLegacyDelegateEvent(event.type, runtimeId, payload);
        }
        _trackVoiceToolEvent(
          payload,
          running: true,
          startsNew: event.type == 'tool.start',
        );
        _upsertRunTool({
          'tool': payload['name'] ?? payload['tool'] ?? payload['tool_id'],
          'preview': payload['preview'] ?? payload['input'] ?? '',
        }, running: true);
        _upsertAssistantToolActivity(
          payload,
          running: true,
          startsNew: event.type == 'tool.start',
        );
        _emit(ActiveChatEvent.toolProgress);
      case 'tool.complete':
        _retireDesktopInterimSegment();
        _flushTokenBuffer();
        _captureDesktopGeneratedImage(payload);
        _handleLegacyDelegateEvent(event.type, runtimeId, payload);
        _trackVoiceToolEvent(payload, running: false, startsNew: false);
        _upsertRunTool({
          'tool': payload['name'] ?? payload['tool'] ?? payload['tool_id'],
          'preview': payload['preview'] ?? payload['input'] ?? '',
          'error': payload['error'] != null || payload['status'] == 'error',
        }, running: false);
        _upsertAssistantToolActivity(payload, running: false, startsNew: false);
        _emit(ActiveChatEvent.toolProgress);
      case 'approval.request':
        _flushTokenBuffer();
        _handleApprovalRequest(payload);
      case 'message.complete':
        _clearDesktopCompactingIndicator();
        final completeText = payload['text'] ?? payload['rendered'];
        final narratable =
            completeText is String &&
            _isNarrableDesktopAssistantPayload(event.type, payload);
        final terminalSource = narratable ? completeText : null;
        final text = terminalSource is String
            ? finalizedPublicAssistantText(terminalSource)
            : '';
        final reasoning = durableAssistantReasoningText(payload);
        if ((payload['status'] ?? '').toString().trim().toLowerCase() ==
            'error') {
          _failRun(
            activeChatDesktopEventFailureUiMessage(payload['message']),
            terminalText: null,
            terminalTextIsPartial: false,
            authoritativeTerminalOverride: true,
            failureMetadata: {
              'partial': payload['partial'] == true,
              if (payload['recoverable'] is bool)
                'recoverable': payload['recoverable'],
            },
          );
          break;
        }
        _recordTerminalWarning(payload['warning']);
        final settledText = narratable
            ? _settleDesktopInterim(
                text,
                responsePreviewed: payload['response_previewed'] == true,
              )
            : text;
        _completeRun(
          finalOutput: narratable && settledText.isNotEmpty
              ? settledText
              : null,
          finalReasoning: reasoning.isNotEmpty ? reasoning : null,
          finalOutputNarratable: narratable,
        );
      case 'error':
        _clearDesktopCompactingIndicator();
        _failRun(activeChatDesktopEventFailureUiMessage(payload['message']));
    }
  }

  void _recordTerminalWarning(Object? raw) {
    if (raw is! String || _terminalWarningEpoch == _turnEpoch) return;
    final normalized = raw
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) return;
    const maxLength = 240;
    _terminalWarning = normalized.length <= maxLength
        ? normalized
        : '${normalized.substring(0, maxLength - 1).trimRight()}…';
    _terminalWarningEpoch = _turnEpoch;
    _emit(ActiveChatEvent.warning);
  }

  void _recordDesktopTerminalFence(TuiGatewayEvent event) {
    _desktopTerminalSequence = event.sequence;
    _desktopTerminalTransportGeneration = event.transportGeneration;
    _desktopTerminalProducerChannel = event.producerChannel;
  }

  bool _isCausallyAfterDesktopTerminal(TuiGatewayEvent event) {
    final terminalSequence = _desktopTerminalSequence;
    final terminalGeneration = _desktopTerminalTransportGeneration;
    final terminalChannel = _desktopTerminalProducerChannel;
    final candidateSequence = event.sequence;
    final candidateGeneration = event.transportGeneration;
    final candidateChannel = event.producerChannel;
    return terminalSequence != null &&
        terminalGeneration != null &&
        terminalChannel != null &&
        candidateSequence != null &&
        candidateGeneration == terminalGeneration &&
        identical(candidateChannel, terminalChannel) &&
        candidateSequence > terminalSequence;
  }

  void _applyDesktopStatusUpdate(Map<String, dynamic> payload) {
    final kind = (payload['kind'] ?? payload['status'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (kind == 'process') {
      unawaited(refreshBackgroundProcesses());
      return;
    }
    if (const {'goal', 'loop', 'heartbeat'}.contains(kind)) {
      unawaited(refreshSessionControl());
      return;
    }
    if (kind == 'compacted') {
      _desktopCompactedEdgeCount += 1;
      final pending = _pendingDesktopCompression;
      final evidence = pending == null
          ? const DesktopCompressionFenceEvidence.none()
          : _pendingCompressionEvidence(pending, payload);
      if (pending != null &&
          _isPendingDesktopCompressionCurrent(pending) &&
          evidence.provesSettlement) {
        unawaited(_settlePendingDesktopCompression(pending, evidence));
      }
      _clearDesktopCompactingIndicator();
      _emit(ActiveChatEvent.sessionInfo);
      return;
    }
    if (kind == 'ready') {
      // `ready` es la señal de reposo del gateway: ninguna compactación sigue.
      _clearDesktopCompactingIndicator();
      return;
    }
    if (kind == 'compressing') {
      _noteDesktopCompressingText(payload['text']);
      _noteDesktopCompactionChunks(payload);
      return;
    }
    if (kind != 'compacting') return;

    final rawLineage =
        payload['_lineage_root_id'] ??
        payload['lineage_root_id'] ??
        payload['lineage_root'];
    final lineage = rawLineage is String ? rawLineage.trim() : '';
    // El runtime ya se comprobó arriba; una lineage nueva puede ser justo el
    // resultado de rotar un id provisional, así que se adopta en vez de
    // rechazarla por no coincidir todavía con la identidad local.
    _desktopCompactionLineageId = lineage.isEmpty ? logicalSessionId : lineage;
    // Los latidos periódicos repiten `compacting`: solo el primero marca inicio.
    if (!desktopCompressionInFlight) {
      _desktopCompactionStartedAt = DateTime.now();
      _desktopCompactionTokensBefore = null;
      _desktopCompactionMessagesBefore = null;
      _desktopCompactionChunkIndex = null;
      _desktopCompactionChunkCount = null;
    }
    _desktopAutoCompacting = true;
    _armAutoCompactionStaleTimer();
    _noteDesktopCompactionChunks(payload);
    _suppressTerminalHydrationAfterCompaction = true;
    // Cualquier snapshot iniciado antes del evento ya es potencialmente
    // obsoleto y no puede reemplazar la proyección viva.
    _messageLoadEpoch += 1;
    _emit(ActiveChatEvent.sessionInfo);
  }

  static final RegExp _compressingLine = RegExp(
    r'compressing\s+(\d+)\s+messages?\s*\(~\s*([\d.,]+)\s*tok',
    caseSensitive: false,
  );

  /// `status.update(compressing)` fija «compressing N messages (~T tok)»: es la
  /// única cifra viva de un `/compress`; el resto llega en el resultado.
  void _noteDesktopCompressingText(Object? text) {
    if (text is! String) return;
    final match = _compressingLine.firstMatch(text);
    if (match == null) return;
    final messages = int.tryParse(match.group(1) ?? '');
    final tokens = int.tryParse(
      (match.group(2) ?? '').replaceAll(RegExp(r'[.,]'), ''),
    );
    if (tokens == null && messages == null) return;
    _desktopCompactionMessagesBefore = messages;
    _desktopCompactionTokensBefore = tokens;
    _emit(ActiveChatEvent.sessionInfo);
  }

  void _noteDesktopCompactionChunks(Map<String, dynamic> payload) {
    final chunks = parseCompactionChunks(payload);
    if (chunks == null) return;
    _desktopCompactionChunkIndex = chunks.index;
    _desktopCompactionChunkCount = chunks.count;
  }

  void _armAutoCompactionStaleTimer() {
    _autoCompactionStaleTimer?.cancel();
    _autoCompactionStaleTimer = Timer(_autoCompactionStaleAfter, () {
      _autoCompactionStaleTimer = null;
      if (_disposed) return;
      _clearDesktopCompactingIndicator();
    });
  }

  void _clearDesktopCompactingIndicator() {
    _autoCompactionStaleTimer?.cancel();
    _autoCompactionStaleTimer = null;
    if (!_desktopAutoCompacting) return;
    _desktopAutoCompacting = false;
    _emit(ActiveChatEvent.sessionInfo);
  }

  bool _isInteractivePromptEvent(String type) =>
      type == 'clarify.request' ||
      type == 'sudo.request' ||
      type == 'secret.request' ||
      type == 'terminal.read.request';

  bool _isInteractivePromptExpiryEvent(String type) =>
      type == 'clarify.expire' ||
      type == 'sudo.expire' ||
      type == 'secret.expire' ||
      type == 'terminal.read.expire';

  void _handleInteractivePromptExpiry(
    String runtimeId,
    Map<String, dynamic> payload,
  ) {
    if (_retiringDesktopRuntimeSessionId == runtimeId) return;
    final requestId = payload['request_id'];
    if (requestId is! String || requestId.trim().isEmpty) return;
    try {
      _reduceInteractivePrompt(
        InteractivePromptExpired(
          InteractivePromptKey(
            runtimeSessionId: runtimeId,
            requestId: requestId,
          ),
        ),
      );
    } on FormatException {
      return;
    }
  }

  void _applyDesktopSessionInfo(Map<String, dynamic> payload) {
    final rawInfo = payload['info'];
    final parsed = DesktopSessionRuntimeInfo.fromJson(
      rawInfo is Map ? rawInfo : payload,
    );
    // The upstream late-ack path emits session.info on the same runtime after
    // it has adopted the compression tip. Only an exact tip/root change or a
    // native compression counter can settle the gate; an unrelated info event
    // is not a completion inference. Check before identity adoption can rotate
    // the local epoch.
    final pending = _pendingDesktopCompression;
    final compressionEvidence = pending == null
        ? const DesktopCompressionFenceEvidence.none()
        : _pendingCompressionEvidence(pending, payload);
    final settlesPendingCompression =
        pending != null &&
        _isPendingDesktopCompressionCurrent(pending) &&
        compressionEvidence.provesSettlement;
    if (settlesPendingCompression) {
      unawaited(_settlePendingDesktopCompression(pending, compressionEvidence));
    }
    // `status.update(compacting)` es transitorio. Algunos Gateway publican el
    // terminal únicamente como `session.info(running=false)`, sin repetir
    // message.complete/error para el tip anterior. No dejar ese flag pegado:
    // bloquearía cada turno posterior con 4009 aunque el servidor ya esté idle.
    final autoCompactionCleared =
        _desktopAutoCompacting && parsed.running == false;
    if (autoCompactionCleared) {
      _desktopAutoCompacting = false;
      _autoCompactionStaleTimer?.cancel();
      _autoCompactionStaleTimer = null;
    }
    final storedId = parsed.storedSessionId?.trim();
    if (!settlesPendingCompression &&
        storedId != null &&
        storedId.isNotEmpty &&
        storedId != _desktopStoredSessionId) {
      _desktopStoredSessionId = storedId;
      final runtimeId = _desktopRuntimeSessionId;
      if (runtimeId != null) _adoptDesktopRuntime(runtimeId);
    }
    final configChanged = _observeSessionConfigInfo(parsed);
    final infoChanged = parsed != _desktopRuntimeInfo;
    final titleChanged = _adoptDesktopSessionTitle(parsed);
    var turnTimingChanged = false;
    if (parsed.running == true && isStreaming) {
      if (_desktopTurnStartedAt == null) {
        _desktopTurnStartedAt = DateTime.now();
        turnTimingChanged = true;
      }
    }

    if (!configChanged &&
        !infoChanged &&
        !titleChanged &&
        !turnTimingChanged &&
        !autoCompactionCleared) {
      return;
    }
    if (infoChanged) _desktopRuntimeInfo = parsed;
    _emit(ActiveChatEvent.sessionInfo);
  }

  void _handleInteractivePromptEvent(
    String type,
    String runtimeId,
    Map<String, dynamic> payload,
  ) {
    if (_retiringDesktopRuntimeSessionId == runtimeId) return;
    late final InteractivePromptRequest request;
    try {
      request = InteractivePromptRequest.fromGatewayEvent(
        type: type,
        runtimeSessionId: runtimeId,
        payload: payload,
      );
    } on FormatException {
      return;
    }
    final changed = _reduceInteractivePrompt(
      InteractivePromptReceived(request),
    );
    if (!changed) return;
    _activityWatchdogTimer?.cancel();
    _activityWatchdogTimer = null;
    if (!_runTerminal) state = ChatPipelineState.executing;
    if (request is TerminalReadPromptRequest) {
      unawaited(respondToTerminalRead(request.key));
    }
  }

  bool _reduceInteractivePrompt(InteractivePromptEvent event) {
    final next = InteractivePromptReducer.reduce(_interactivePrompts, event);
    if (identical(next, _interactivePrompts)) return false;
    _interactivePrompts = next;
    _emit(ActiveChatEvent.interactiveRequest);
    return true;
  }

  void _restorePendingApproval(
    DesktopSessionSnapshot snapshot, {
    int? expectedGeneration,
  }) {
    if (!snapshot.pendingApprovalProvided ||
        snapshot.runtimeSessionId != _desktopRuntimeSessionId ||
        (expectedGeneration != null &&
            expectedGeneration != _approvalGeneration)) {
      return;
    }
    final pending = snapshot.pendingApproval;
    if (pending == null || pending.isEmpty) {
      pendingApproval = null;
      return;
    }
    if (_approvalRequestId(pending) == null) {
      // Malformed authority is not evidence that a newer live request vanished.
      return;
    }
    _handleApprovalRequest(Map<String, dynamic>.unmodifiable(pending));
  }

  void _restorePendingClarify(DesktopSessionSnapshot snapshot) {
    _reconcilePendingClarifySnapshot(snapshot, unlockResponding: false);
  }

  void _reconcilePendingClarifySnapshot(
    DesktopSessionSnapshot snapshot, {
    required bool unlockResponding,
  }) {
    if (!snapshot.pendingClarifyProvided) return;
    final pending = snapshot.pendingClarify;
    if (pending == null || pending.isEmpty) {
      _reduceInteractivePrompt(
        InteractivePromptClarifySnapshotCleared(snapshot.runtimeSessionId),
      );
      return;
    }
    try {
      final request = InteractivePromptRequest.fromGatewayEvent(
        type: 'clarify.request',
        runtimeSessionId: snapshot.runtimeSessionId,
        payload: pending,
      );
      if (request is ClarifyPromptRequest) {
        _reduceInteractivePrompt(
          InteractivePromptSnapshotReconciled(
            request,
            unlockResponding: unlockResponding,
          ),
        );
      }
    } on FormatException {
      // The field was present, so the snapshot is authoritative even though
      // its payload is malformed. Fail closed only for clarifies in this
      // runtime; unrelated prompt kinds and runtimes remain untouched.
      _reduceInteractivePrompt(
        InteractivePromptClarifySnapshotCleared(snapshot.runtimeSessionId),
      );
    }
  }

  void _expireInteractivePromptsForRuntime(String? runtimeId) {
    if (runtimeId == null) return;
    _reduceInteractivePrompt(InteractivePromptRuntimeExpired(runtimeId));
  }

  SubagentActivityScope _subagentScope(String runtimeId) =>
      SubagentActivityScope(
        connectionId: connection.id,
        profile: _storedSessionProfile,
        parentSessionId: serverSessionId,
        runtimeSessionId: runtimeId,
        turnEpoch: _turnEpoch,
      );

  void _reconcileSubagentsFromTranscript() {
    final historicalMessages = projectHistoricalSubagentCompletions(
      messagesNewestFirst: _messages,
    );
    final historicalChanged = !identical(historicalMessages, _messages);
    if (historicalChanged) _messages = historicalMessages;

    if (_messages.isEmpty) {
      if (historicalChanged) {
        _refreshCurrentSubagentPublicProjection();
        _emit(ActiveChatEvent.subagentActivity);
      }
      return;
    }
    // A persisted delegate_task result proves durable child identities, but
    // not that any child is still alive. Project it in a private, explicitly
    // non-runtime scope so a passive REST hydration can render neutral rows.
    // If this chat later acquires a real runtime, _rebaseSubagentActivityScope
    // moves the same identities into that authoritative scope.
    final publishedRuntimeId = _desktopRuntimeSessionId?.trim();
    final runtimeId = publishedRuntimeId == null || publishedRuntimeId.isEmpty
        ? 'durable-transcript'
        : publishedRuntimeId;
    final before = _subagentActivities;
    final projection = projectSubagentsFromTranscript(
      messagesNewestFirst: _messages,
      scope: _subagentScope(runtimeId),
      current: before,
      currentTurnAnchor: _subagentTranscriptTurnAnchor,
    );
    final anchor = projection.turnAnchor;
    if (anchor == null) return;
    _subagentTranscriptTurnAnchor = anchor;
    _subagentActivities = projection.state;
    if (!identical(before, projection.state)) {
      _subagentMutationGeneration += 1;
      _refreshCurrentSubagentPublicProjection();
      _emit(ActiveChatEvent.subagentActivity);
    } else if (historicalChanged) {
      _refreshCurrentSubagentPublicProjection();
      _emit(ActiveChatEvent.subagentActivity);
    }
  }

  bool _snapshotProvesSubagentReconnectAlias(
    DesktopSessionSnapshot snapshot,
    SubagentActivityState current,
  ) =>
      !snapshot.created &&
      snapshot.identityAliasesConsistent &&
      snapshot.storedSessionIdentityExplicit &&
      snapshot.storedSessionId == current.scope.parentSessionId;

  void _rebaseSubagentActivityScope(
    String runtimeId, {
    DesktopSessionSnapshot? reconnectEvidence,
  }) {
    final current = _subagentActivities;
    if (current == null) return;
    final recoveredScope = _subagentScope(runtimeId);
    if (current.scope == recoveredScope) return;
    if (current.scope.durableLineageKey != recoveredScope.durableLineageKey) {
      return;
    }
    final terminalReconnect =
        reconnectEvidence != null &&
        !reconnectEvidence.running &&
        reconnectEvidence.inflight == null &&
        current.activities.every((activity) => activity.isTerminal);
    if (terminalReconnect) {
      // Terminal recovery seals the old live incarnation before rebasing. Keep
      // that reconciliable activity visible; clearing here loses the only
      // terminal projection before transcript reconciliation can publish it.
      _subagentActivities = SubagentActivityState.withEntries(
        recoveredScope,
        current.entries,
      );
      _subagentControlAuthority.clear();
      _pendingSubagentInterrupts.clear();
      _subagentMutationGeneration += 1;
      _refreshCurrentSubagentPublicProjection();
      return;
    }
    _subagentReconnectAliases.clear();
    if (reconnectEvidence != null &&
        _snapshotProvesSubagentReconnectAlias(reconnectEvidence, current)) {
      for (final activity in current.activities) {
        final subagentId = activity.subagentId;
        final revision = activity.eventRevision;
        final goal = activity.goalPreview;
        final hasStrongSecondaryIdentity =
            activity.childSessionId != null || activity.delegationId != null;
        if (subagentId == null ||
            revision == null ||
            goal == null ||
            !hasStrongSecondaryIdentity) {
          continue;
        }
        _subagentReconnectAliases.add(
          _SubagentReconnectAlias(
            lineage: recoveredScope.durableLineageKey,
            targetRuntimeId: runtimeId,
            subagentId: subagentId,
            childSessionId: activity.childSessionId,
            delegationId: activity.delegationId,
            previousRevision: revision,
            goalPreview: goal,
          ),
        );
      }
    }
    // Runtime rotation always clears mutable incarnation state. A narrowly
    // verified reconnect candidate may later restore only its public goal when
    // the same opaque child identity advances monotonically in the new alias.
    _rememberRetiredSubagentTerminals(current);
    _rememberSubagentHistoricalEvidence(current);
    _subagentActivities = SubagentActivityState.empty(recoveredScope);
    // The new runtime's roster has not been listed yet, so no earlier list is
    // authority over it: proof of absence never crosses a rotation.
    _subagentLiveRosterConfirmed = false;
    _subagentControlAuthority.clear();
    _subagentMutationGeneration += 1;
    _pendingSubagentInterrupts.clear();
    _subagentTranscriptTurnAnchor = null;
    _refreshCurrentSubagentPublicProjection();
  }

  void _handleNativeSubagentEvent(
    String type,
    String runtimeId,
    Map<String, dynamic> payload, {
    bool presentationProof = true,
  }) {
    if (_disposed || _desktopRuntimeSessionId != runtimeId) return;
    final current = _subagentActivities;
    final nextScope = _subagentScope(runtimeId);
    final currentScopeEvent =
        current != null && current.scope.runtimeSessionId == runtimeId
        ? SubagentActivityEvent.tryParseNative(
            type: type,
            scope: current.scope,
            payload: payload,
          )
        : null;
    final continuesCurrentScope =
        currentScopeEvent != null &&
        current!.activities.any(
          (activity) => activity.explicitlyMatches(currentScopeEvent),
        );
    final scope =
        current != null &&
            current.scope.runtimeSessionId == runtimeId &&
            (current.scope == nextScope ||
                continuesCurrentScope ||
                current.activities.any((activity) => !activity.isTerminal))
        ? current.scope
        : nextScope;
    var event = SubagentActivityEvent.tryParseNative(
      type: type,
      scope: scope,
      payload: payload,
    );
    if (event != null) {
      _SubagentReconnectAlias? continuation;
      if (!payload.containsKey('goal')) {
        for (final candidate in _subagentReconnectAliases) {
          if (candidate.provesContinuation(event)) {
            continuation = candidate;
            break;
          }
        }
      }
      final incoming = event;
      _subagentReconnectAliases.removeWhere(
        (candidate) => candidate.targetsSubagent(incoming),
      );
      if (continuation != null) {
        event = SubagentActivityEvent.tryParseNative(
          type: type,
          scope: scope,
          payload: <String, dynamic>{
            ...payload,
            'goal': continuation.goalPreview,
          },
        );
      }
      if (event == null || !_reduceSubagentActivity(event)) return;
      SubagentActivity? authoritative;
      for (final candidate
          in _subagentActivities?.activities ?? const <SubagentActivity>[]) {
        if (candidate.explicitlyMatches(event)) {
          authoritative = candidate;
          break;
        }
      }
      if (authoritative != null && _desktopRuntimeSessionId == runtimeId) {
        final canPublishEventProof =
            presentationProof && _subagentForegroundPresentationLeased;
        if (canPublishEventProof) {
          _subagentPublicEligibleKeys.add(authoritative.key);
          _subagentPresentationState =
              _SubagentPresentationState.foregroundCurrent;
          _refreshCurrentSubagentPublicProjection();
          if (event.phase.isTerminal) {
            _subagentControlAuthority.remove(authoritative.key);
          } else {
            _subagentControlAuthority.add(authoritative.key);
          }
        }
      }
      _emit(ActiveChatEvent.subagentActivity);
    }
  }

  void _handleLegacyDelegateEvent(
    String type,
    String runtimeId,
    Map<String, dynamic> payload,
  ) {
    if (_disposed || _desktopRuntimeSessionId != runtimeId) return;
    final toolName = (payload['name'] ?? payload['tool'])?.toString();
    final toolCallId =
        (payload['tool_id'] ??
                payload['tool_call_id'] ??
                payload['call_id'] ??
                payload['id'])
            ?.toString();
    final current = _subagentActivities;
    final nextScope = _subagentScope(runtimeId);
    final currentScopeEvent =
        current != null && current.scope.runtimeSessionId == runtimeId
        ? SubagentActivityEvent.tryParseLegacyDelegateTool(
            type: type,
            scope: current.scope,
            payload: payload,
            toolName: toolName,
            toolCallId: toolCallId,
          )
        : null;
    final continuesCurrentScope =
        currentScopeEvent != null &&
        current!.activities.any(
          (activity) => activity.explicitlyMatches(currentScopeEvent),
        );
    final scope =
        current != null &&
            current.scope.runtimeSessionId == runtimeId &&
            (current.scope == nextScope ||
                continuesCurrentScope ||
                current.activities.any((activity) => !activity.isTerminal))
        ? current.scope
        : nextScope;
    final event = SubagentActivityEvent.tryParseLegacyDelegateTool(
      type: type,
      scope: scope,
      payload: payload,
      toolName: toolName,
      toolCallId: toolCallId,
    );
    if (event == null || !_reduceSubagentActivity(event)) return;
    if (_subagentPresentationState ==
            _SubagentPresentationState.foregroundCurrent &&
        _subagentForegroundPresentationLeased) {
      final authoritative = _subagentActivities?.activities
          .where((activity) => activity.explicitlyMatches(event))
          .firstOrNull;
      if (authoritative != null) {
        _subagentPublicEligibleKeys.add(authoritative.key);
        final visible = List<SubagentActivity>.of(_subagentPublicActivities)
          ..removeWhere((activity) => activity.explicitlyMatches(event))
          ..add(authoritative);
        _subagentPublicActivities = List.unmodifiable(visible);
      }
    }
    _emit(ActiveChatEvent.subagentActivity);
  }

  /// Captura lateral de resultados estructurados de generación multimedia. No
  /// emite eventos propios ni altera contenido/streaming: `tool.complete`
  /// publicará el `toolProgress` habitual después de adjuntar metadata compacta
  /// al segmento del asistente que ya posee el turno vivo.
  void _captureDesktopGeneratedImage(Map<String, dynamic> payload) {
    final name = _toolName(payload);
    if (!_isGeneratedMediaProducerName(name)) return;
    final callId = _toolCallId(payload);
    if (callId == null) return;
    final rawResult =
        payload['result'] ?? payload['output'] ?? payload['content'];
    final incoming = <Map<String, dynamic>>[];
    if (_isVideoGenerateName(name)) {
      incoming.addAll(
        GeneratedMediaService.referencesFromToolResult(
          name,
          rawResult,
        ).map((reference) => _generatedVideoMetadata(reference, callId)),
      );
    } else {
      incoming.addAll(
        GeneratedImageService.imageReferencesFromResult(
          rawResult,
        ).map((reference) => _generatedImageMetadata(reference, callId)),
      );
    }
    if (incoming.isEmpty) return;
    final assistantIndex = _messages.indexWhere(
      (message) => message['role'] == 'assistant',
    );
    if (assistantIndex < 0) return;
    final assistant = _messages[assistantIndex];
    final merged = _mergeGeneratedImageMetadata(
      _generatedImageMetadataOf(assistant),
      incoming,
    );
    _messages[assistantIndex] = Map<String, dynamic>.unmodifiable({
      ...assistant,
      _generatedImagesMetadataKey: merged,
    });
  }

  void _rememberRetiredSubagentTerminals(SubagentActivityState? state) {
    if (state == null) return;
    for (final activity in state.activities.where(
      (activity) => activity.isTerminal,
    )) {
      _retiredSubagentTerminals.removeWhere(
        (remembered) => remembered.key == activity.key,
      );
      _retiredSubagentTerminals.add(activity);
    }
    const retainedLimit = 64;
    if (_retiredSubagentTerminals.length > retainedLimit) {
      _retiredSubagentTerminals.removeRange(
        0,
        _retiredSubagentTerminals.length - retainedLimit,
      );
    }
  }

  bool _sameDurableSubagentIdentity(
    SubagentActivity left,
    SubagentActivity right,
  ) {
    if (left.key.scope.durableLineageKey != right.key.scope.durableLineageKey) {
      return false;
    }
    final conflicting =
        (left.subagentId != null &&
            right.subagentId != null &&
            left.subagentId != right.subagentId) ||
        (left.delegationId != null &&
            right.delegationId != null &&
            left.delegationId != right.delegationId) ||
        (left.childSessionId != null &&
            right.childSessionId != null &&
            left.childSessionId != right.childSessionId) ||
        (left.legacyToolCallId != null &&
            right.legacyToolCallId != null &&
            left.legacyToolCallId != right.legacyToolCallId);
    if (conflicting) return false;
    return (left.delegationId != null &&
            left.delegationId == right.delegationId) ||
        (left.childSessionId != null &&
            left.childSessionId == right.childSessionId) ||
        (left.legacyToolCallId != null &&
            left.legacyToolCallId == right.legacyToolCallId);
  }

  SubagentActivity _publicSafeSubagentEvidence(
    SubagentActivity activity, {
    bool neutral = false,
  }) => SubagentActivity(
    key: activity.key,
    source: activity.source,
    phase: neutral ? SubagentActivityPhase.unknown : activity.phase,
    subagentId: activity.subagentId,
    delegationId: activity.delegationId,
    childSessionId: activity.childSessionId,
    legacyToolCallId: activity.legacyToolCallId,
    eventRevision: activity.eventRevision,
    seenEventIds: activity.seenEventIds,
    details: SubagentActivityDetails(
      goalPreview: activity.details.goalPreview,
      depth: activity.details.depth,
      model: activity.details.model,
      toolCount: activity.details.toolCount,
      activeToolName: activity.details.activeToolName,
      acceptingSteer: false,
      startedAt: activity.details.startedAt,
    ),
  );

  SubagentActivity _neutralSubagentHistoricalEvidence(
    SubagentActivity activity,
  ) => _publicSafeSubagentEvidence(activity, neutral: true);

  void _rememberSubagentHistoricalEvidence(SubagentActivityState? state) {
    if (state == null) return;
    for (final activity in state.activities.where(
      (activity) => !activity.isTerminal,
    )) {
      final historical = _neutralSubagentHistoricalEvidence(activity);
      _subagentHistoricalEvidence.removeWhere(
        (remembered) => _sameDurableSubagentIdentity(remembered, historical),
      );
      _subagentHistoricalEvidence.add(historical);
    }
    const retainedLimit = 64;
    if (_subagentHistoricalEvidence.length > retainedLimit) {
      _subagentHistoricalEvidence.removeRange(
        0,
        _subagentHistoricalEvidence.length - retainedLimit,
      );
    }
  }

  bool _matchesRetiredSubagent(
    SubagentActivity activity,
    SubagentActivityEvent event,
  ) {
    if (activity.key.scope.durableLineageKey != event.scope.durableLineageKey ||
        activity.key.scope.runtimeSessionId != event.scope.runtimeSessionId) {
      return false;
    }
    final hasDifferentKnownIdentity =
        (activity.subagentId != null &&
            event.subagentId != null &&
            activity.subagentId != event.subagentId) ||
        (activity.delegationId != null &&
            event.delegationId != null &&
            activity.delegationId != event.delegationId) ||
        (activity.childSessionId != null &&
            event.childSessionId != null &&
            activity.childSessionId != event.childSessionId) ||
        (activity.legacyToolCallId != null &&
            event.legacyToolCallId != null &&
            activity.legacyToolCallId != event.legacyToolCallId);
    if (hasDifferentKnownIdentity) return false;
    final sameTurn = activity.key.scope.turnEpoch == event.scope.turnEpoch;
    if (sameTurn) {
      return (activity.subagentId != null &&
              activity.subagentId == event.subagentId) ||
          (activity.delegationId != null &&
              activity.delegationId == event.delegationId) ||
          (activity.childSessionId != null &&
              activity.childSessionId == event.childSessionId) ||
          (activity.legacyToolCallId != null &&
              activity.legacyToolCallId == event.legacyToolCallId);
    }
    // subagent_id is recyclable by the producer. Across turn epochs only a
    // producer-defined secondary incarnation identity may hit a tombstone.
    return (activity.delegationId != null &&
            activity.delegationId == event.delegationId) ||
        (activity.childSessionId != null &&
            activity.childSessionId == event.childSessionId) ||
        (activity.legacyToolCallId != null &&
            activity.legacyToolCallId == event.legacyToolCallId);
  }

  bool _reduceSubagentActivity(SubagentActivityEvent event) {
    if (_retiredSubagentTerminals.any(
      (activity) => _matchesRetiredSubagent(activity, event),
    )) {
      // Retired terminal identities are absorbing tombstones only within the
      // exact producer-defined incarnation.
      return false;
    }
    var current = _subagentActivities;
    if (current != null && current.scope != event.scope) {
      final canBeginSuccessorScope =
          current.activities.every((activity) => activity.isTerminal) &&
          current.scope.durableLineageKey == event.scope.durableLineageKey &&
          current.scope.runtimeSessionId == event.scope.runtimeSessionId &&
          current.scope.turnEpoch < event.scope.turnEpoch &&
          !event.phase.isTerminal;
      if (!canBeginSuccessorScope) return false;
      _rememberRetiredSubagentTerminals(current);
      current = null;
      _subagentTranscriptTurnAnchor = null;
      _pendingSubagentInterrupts.clear();
    }
    final scoped = current ?? SubagentActivityState.empty(event.scope);
    final next = SubagentActivityReducer.reduce(scoped, event);
    if (identical(next, scoped)) return false;
    _subagentActivities = next;
    _subagentMutationGeneration += 1;
    // A child may finish after the parent emitted its terminal event. Keep that
    // completion visible without pretending that the parent pipeline reopened.
    if (!event.phase.isTerminal && !_runTerminal) {
      _armActivityWatchdog();
      state = ChatPipelineState.executing;
    }
    return true;
  }

  bool _matchesLiveSubagent(Map<String, dynamic> payload) {
    String? id(String key) {
      final value = payload[key];
      if (value is! String || value.trim().isEmpty) return null;
      return value.trim();
    }

    final subagentId = id('subagent_id');
    final delegationId = id('delegation_id');
    final childSessionId = id('child_session_id');
    if (subagentId == null && delegationId == null && childSessionId == null) {
      return false;
    }
    return _subagentActivities?.activities.any(
          (activity) =>
              !activity.isTerminal &&
              ((subagentId != null && activity.subagentId == subagentId) ||
                  (delegationId != null &&
                      activity.delegationId == delegationId) ||
                  (childSessionId != null &&
                      activity.childSessionId == childSessionId)),
        ) ??
        false;
  }

  static bool _isNarrableDesktopAssistantPayload(
    String eventType,
    Map<String, dynamic> payload,
  ) {
    if (!const {
      'message.delta',
      'message.interim',
      'message.complete',
    }.contains(eventType)) {
      return false;
    }
    if (hasPrivateTranscriptClassifier(payload)) return false;
    if (eventType != 'message.complete' && payload.containsKey('reasoning')) {
      return false;
    }
    // `message.complete` puede transportar `reasoning` como sidecar canónico.
    // El texto público sigue siendo `text`; nunca concatenamos ese sidecar.

    // El contrato Desktop publica assistant por TIPO (`message.delta`,
    // `message.interim`, `message.complete`); thinking/reasoning/tool usan
    // eventos distintos y el payload público no necesita classifier. Para
    // compatibilidad aceptamos su ausencia, pero cualquier classifier explícito
    // desconocido falla cerrado en Voz en vez de adivinar que es narrable.
    return true;
  }

  int _assistantActivityMessageIndex() => _messages.indexWhere(
    (message) =>
        message['role'] == 'assistant' &&
        (message['display_kind']?.toString().trim().isEmpty ?? true),
  );

  void _appendAssistantReasoningActivity(
    String incoming, {
    bool authoritative = false,
  }) {
    if (incoming.trim().isEmpty) return;
    var index = _assistantActivityMessageIndex();
    if (index < 0) {
      _messages.insert(0, {
        'role': 'assistant',
        'content': '',
        '_pipeline': true,
      });
      index = 0;
    }
    final message = _messages[index];
    final activity = normalizeAssistantActivityTrace(
      message[assistantActivityTraceKey],
    ).map(Map<String, dynamic>.from).toList(growable: true);
    final lastReasoningIndex = activity.lastIndexWhere(
      (step) => step['kind'] == 'reasoning' && step['status'] == 'running',
    );
    final canUpdateLatest =
        lastReasoningIndex >= 0 && lastReasoningIndex == activity.length - 1;
    if (canUpdateLatest) {
      final current = activity[lastReasoningIndex]['text']?.toString() ?? '';
      final text = authoritative
          ? incoming.startsWith(current)
                ? incoming
                : current.startsWith(incoming)
                ? current
                : incoming
          : '$current$incoming';
      activity[lastReasoningIndex] = {
        ...activity[lastReasoningIndex],
        'text': text,
      };
    } else {
      activity.add({
        'kind': 'reasoning',
        'text': incoming,
        'status': 'running',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    }
    final reasoning = activity
        .where((step) => step['kind'] == 'reasoning')
        .map((step) => step['text']?.toString().trim() ?? '')
        .where((text) => text.isNotEmpty)
        .join('\n\n');
    _messages[index] = {
      ...message,
      'reasoning': reasoning,
      assistantActivityTraceKey: activity,
    };
  }

  void _upsertAssistantToolActivity(
    Map<String, dynamic> payload, {
    required bool running,
    required bool startsNew,
  }) {
    var index = _assistantActivityMessageIndex();
    if (index < 0) {
      _messages.insert(0, {
        'role': 'assistant',
        'content': '',
        '_pipeline': true,
      });
      index = 0;
    }
    final message = _messages[index];
    final activity = normalizeAssistantActivityTrace(
      message[assistantActivityTraceKey],
    ).map(Map<String, dynamic>.from).toList(growable: true);
    final rawId =
        payload['tool_call_id'] ??
        payload['call_id'] ??
        payload['tool_id'] ??
        payload['id'];
    final id = rawId?.toString().trim();
    final rawLabel =
        payload['skill'] ??
        payload['name'] ??
        payload['tool'] ??
        payload['tool_id'];
    final label = rawLabel?.toString().trim() ?? '';
    if (label.isEmpty) return;
    final rawKind = (payload['kind'] ?? payload['type'])
        ?.toString()
        .trim()
        .toLowerCase();
    final kind =
        rawKind == 'skill' ||
            payload.containsKey('skill') ||
            label.toLowerCase() == 'skill'
        ? 'skill'
        : 'tool';
    var activityIndex = id == null || id.isEmpty
        ? -1
        : activity.lastIndexWhere(
            (step) =>
                (step['kind'] == 'tool' || step['kind'] == 'skill') &&
                step['id'] == id,
          );
    if (activityIndex < 0 && !startsNew) {
      activityIndex = activity.lastIndexWhere(
        (step) =>
            (step['kind'] == 'tool' || step['kind'] == 'skill') &&
            step['label'] == label &&
            step['status'] == 'running',
      );
    }
    final status = running
        ? 'running'
        : payload['error'] != null || payload['status'] == 'error'
        ? 'failed'
        : 'completed';
    // Detalle SEGURO para la pastilla/el panel (ejecutable, nombre de archivo,
    // host…): nunca el argumento crudo. `tool.start` trae `args`; `tool.complete`
    // trae además `duration_s`, con lo que el «Hecho» del panel mide de verdad.
    final detail = activityToolDetail(label, payload['args']);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final durationS = payload['duration_s'];
    if (activityIndex >= 0) {
      final previous = activity[activityIndex];
      final startedMs = previous['timestamp'];
      final completedAt = running
          ? null
          : (startedMs is num && durationS is num && durationS.isFinite
                ? startedMs.round() + (durationS * 1000).round()
                : nowMs);
      activity[activityIndex] = {
        ...previous,
        'label': label,
        'status': status,
        if (detail != null && previous['detail'] == null) 'detail': detail,
        'completed_at': ?completedAt,
      };
    } else {
      activity.add({
        'kind': kind,
        'label': label,
        'status': status,
        if (id != null && id.isNotEmpty) 'id': id,
        'detail': ?detail,
        // Un fin sin inicio visto solo se mide si el gateway trae la duración.
        'timestamp': !running && durationS is num && durationS.isFinite
            ? nowMs - (durationS * 1000).round()
            : nowMs,
        if (!running && durationS is num && durationS.isFinite)
          'completed_at': nowMs,
      });
    }
    _messages[index] = {...message, assistantActivityTraceKey: activity};
  }

  void _settleAssistantActivity(String? finalReasoning) {
    if (finalReasoning?.trim().isNotEmpty == true) {
      _appendAssistantReasoningActivity(finalReasoning!, authoritative: true);
    }
    final index = _assistantActivityMessageIndex();
    if (index < 0) return;
    final message = _messages[index];
    final activity = normalizeAssistantActivityTrace(
      message[assistantActivityTraceKey],
    ).map(Map<String, dynamic>.from).toList(growable: false);
    if (activity.isEmpty) return;
    for (var step = 0; step < activity.length; step++) {
      if (activity[step]['status'] == 'running') {
        activity[step] = {
          ...activity[step],
          'status': 'completed',
          if (activity[step]['kind'] != 'reasoning')
            'completed_at': DateTime.now().millisecondsSinceEpoch,
        };
      }
    }
    final firstTimestamp = activity
        .map((step) => step['timestamp'])
        .whereType<num>()
        .firstOrNull;
    final durationSeconds = firstTimestamp == null
        ? null
        : ((DateTime.now().millisecondsSinceEpoch - firstTimestamp) / 1000)
              .clamp(0, 604800);
    _messages[index] = {
      ...message,
      assistantActivityTraceKey: activity,
      '_activity_duration_seconds': ?durationSeconds,
    };
  }

  void _retireDesktopInterimSegment() {
    if (_messages.isEmpty ||
        _messages.first['role'] != 'assistant' ||
        _messages.first['_desktopReplaceInterimOnDelta'] != true) {
      return;
    }
    _messages[0] = Map<String, dynamic>.from(_messages.first)
      ..remove('_desktopPreserveInterimOnDelta');
  }

  void _prepareDesktopPostInterimSegment() {
    if (_messages.isEmpty ||
        _messages.first['role'] != 'assistant' ||
        _messages.first['_desktopReplaceInterimOnDelta'] != true) {
      return;
    }
    final preserve =
        _messages.first['_desktopPreserveInterimOnDelta'] == true;
    final current = (_messages.first['content'] as String?) ?? '';
    final next = Map<String, dynamic>.from(_messages.first)
      ..['content'] = preserve && current.isNotEmpty ? '$current\n\n' : ''
      ..['_desktopInterimWasPreserved'] = preserve
      ..remove('_desktopReplaceInterimOnDelta')
      ..remove('_desktopPreserveInterimOnDelta');
    _messages[0] = next;
  }

  void _sealDesktopInterim(
    Map<String, dynamic> payload, {
    required bool narratable,
  }) {
    final rawText = payload['text'];
    if (rawText is! String || rawText.trim().isEmpty) return;
    if (narratable) _assistantNarration.sealInterim(rawText);
    _observeFirstResponseContent(rawText);
    if (!_streamingConfirmed) _armActivityWatchdog();
    _flushTokenBuffer();
    final key = 'assistant-interim-$_turnEpoch-${++_desktopInterimSerial}';
    if (_messages.isNotEmpty && _messages.first['role'] == 'assistant') {
      _messages[0] = {
        ..._messages[0],
        'content': rawText,
        '_pipeline': true,
        '_desktopInterim': true,
        '_desktopInterimPublic': narratable,
        '_desktopInterimKey': key,
        '_desktopInterimText': rawText,
        '_desktopReplaceInterimOnDelta': true,
        '_desktopPreserveInterimOnDelta': true,
      };
    } else {
      _messages.insert(0, {
        'role': 'assistant',
        'content': rawText,
        '_pipeline': true,
        '_desktopInterim': true,
        '_desktopInterimPublic': narratable,
        '_desktopInterimKey': key,
        '_desktopInterimText': rawText,
        '_desktopReplaceInterimOnDelta': true,
        '_desktopPreserveInterimOnDelta': true,
      });
    }
    _pendingDesktopInterimKey = key;
    state = ChatPipelineState.executing;
    _emit(ActiveChatEvent.toolProgress);
  }

  String _settleDesktopInterim(
    String finalText, {
    required bool responsePreviewed,
  }) {
    final key = _pendingDesktopInterimKey;
    _pendingDesktopInterimKey = null;
    if (key == null || finalText.trim().isEmpty) return finalText;
    final interimIndex = _messages.indexWhere(
      (message) => message['_desktopInterimKey'] == key,
    );
    if (interimIndex < 0) return finalText;
    final message = _messages[interimIndex];
    final interimText =
        (message['_desktopInterimText'] as String? ??
                message['content'] as String? ??
                '')
            .trim();
    if (interimText.isEmpty) return finalText;
    final trimmedFinal = finalText.trim();
    final finalContinuesInterim =
        trimmedFinal == interimText ||
        trimmedFinal.startsWith(interimText) ||
        interimText.startsWith(trimmedFinal);
    final preserveInterim =
        !responsePreviewed &&
        !finalContinuesInterim &&
        (message['_desktopPreserveInterimOnDelta'] == true ||
            message['_desktopInterimWasPreserved'] == true);
    final currentText = ((message['content'] as String?) ?? '').trim();
    final settledText = preserveInterim
        ? currentText.startsWith(interimText) &&
                  currentText.endsWith(trimmedFinal)
              ? currentText
              : '$interimText\n\n$trimmedFinal'
        : finalText;
    final streamFinalTail =
        currentText == interimText &&
        trimmedFinal.startsWith(interimText) &&
        trimmedFinal.length > interimText.length;
    final settled = Map<String, dynamic>.from(message)
      ..['content'] = streamFinalTail ? currentText : settledText
      ..['_pipeline'] = false
      ..['_responsePreviewed'] = true
      ..remove('_desktopInterimText')
      ..remove('_desktopReplaceInterimOnDelta')
      ..remove('_desktopPreserveInterimOnDelta')
      ..remove('_desktopInterimWasPreserved');
    _messages[interimIndex] = settled;
    return settledText;
  }

  /// Lanza el turno remoto vía `/v1/runs` (motor de runs con aprobaciones
  /// once/session/always/deny). Extraído sin cambios de comportamiento para poder
  /// reutilizarlo con el `history` original o con el SOUL del perfil inyectado.
  Future<bool> _startRemoteRun(
    String fullText,
    String model,
    List<Map<String, dynamic>> history,
    int turnEpoch,
  ) async {
    try {
      if (!await _beginTurnTransport(turnEpoch, PreparedTurnTransport.rest)) {
        return false;
      }
      final runId = await _api.startRun(
        input: sanitizeRemoteChatText(fullText),
        sessionId: serverSessionId,
        model: explicitRunModel(model),
        profile: sessionProfile,
        history: history
            .map(
              (message) => <String, dynamic>{
                ...message,
                if (message['content'] is String)
                  'content': sanitizeRemoteChatText(
                    message['content'] as String,
                  ),
              },
            )
            .toList(),
      );
      if (_turnEpoch != turnEpoch || _queueAdmissionFrozen) {
        // El POST pudo crear el run justo después de que el usuario pulsase Stop.
        // Su id identifica de forma inequívoca el turno viejo: detenlo y nunca lo
        // adoptes como currentRunId del epoch siguiente.
        try {
          await _api.stopRun(runId, profile: sessionProfile);
        } catch (_) {}
        return false;
      }
      currentRunId = runId;
      state = ChatPipelineState.waiting;
      // Arranca el foreground service / vigilancia en 2º plano para este run
      // (la app está en primer plano aquí, así que iniciarlo está permitido).
      _onRunStarted?.call(runId);
      _emit(ActiveChatEvent.connected);
      // El reloj de silencio solo gobierna la pista visual; el terminal sigue
      // viniendo del servidor o de la recuperación del transporte.
      _armActivityWatchdog();
      _api.streamRunEvents(
        runId,
        profile: sessionProfile,
        onEvent: (event) {
          if (_turnEpoch == turnEpoch) _onRunEvent(event);
        },
        onDone: () {
          if (_turnEpoch == turnEpoch) _onRunStreamDone();
        },
        onError: (e) {
          if (_turnEpoch != turnEpoch) return;
          // Esta ruta pertenece al transporte REST, no al socket Desktop
          // retirado. Conserva la reconciliación histórica de runs REST.
          unawaited(_recoverRestTurnFromTranscript(turnEpoch, e));
        },
        idleTimeout: null,
      );
      return true;
    } catch (e) {
      if (_turnEpoch != turnEpoch) return false;
      _activityWatchdogTimer?.cancel();
      _activityWatchdogTimer = null;
      _failRun(e.toString());
      return false;
    }
  }

  /// ¿El último turno con perfil NO pudo aislarse de verdad? (remoto sin bridge
  /// con soporte). La UI lo usa para avisar honestamente ("actualiza el bridge
  /// para aislar este perfil") sin fingir aislamiento.
  bool profileNotIsolated = false;

  /// Routing del chat cuando hay un perfil activo (no-default y válido).
  ///
  /// El aislamiento REAL (SOUL+skills+memoria+modelo del perfil) SOLO es posible
  /// ejecutando el turno en el home del perfil vía el Mobile Bridge
  /// (`hermes --profile`). El gateway HTTP no puede: siempre antepone el SOUL del
  /// home default. Por eso:
  /// - LOCAL (Termux): bridge nativo con `profile` → aislamiento completo.
  /// - REMOTO con bridge ≥ versión con soporte: se enruta por el bridge (modo
  ///   agente). Si no hay bridge capaz → degrada al gateway (SIN aislar) y marca
  ///   [profileNotIsolated] para que la UI avise. NUNCA rompe ni finge.
  Future<bool> _dispatchWithProfile(
    String fullText,
    String model,
    List<Map<String, dynamic>> history,
    String profile,
    int turnEpoch, {
    List<AttachmentDraft> nativeAttachments = const [],
    required LocalConversationLifecycle? capturedLifecycle,
    LocalConversationOperation? transcriptOperation,
  }) async {
    profileNotIsolated = false;
    if (connection.kind == InstanceKind.localhost) {
      await _sendViaBridge(
        fullText,
        history,
        profile: profile,
        turnEpoch: turnEpoch,
        nativeAttachments: nativeAttachments,
        capturedLifecycle: capturedLifecycle,
        transcriptOperation: transcriptOperation,
      );
      return _turnEpoch == turnEpoch && state != ChatPipelineState.failed;
    }
    final ready = await _remoteBridgeProfileReady();
    // Guarda de ciclo de vida: el turno pudo cancelarse durante el await.
    if (_turnEpoch != turnEpoch ||
        _runTerminal ||
        state == ChatPipelineState.cancelled) {
      return false;
    }
    if (ready) {
      // Aislamiento real vía bridge remoto (modo agente, no el chat-simple local).
      await _sendViaBridge(
        fullText,
        history,
        profile: profile,
        forceAgent: true,
        turnEpoch: turnEpoch,
        nativeAttachments: nativeAttachments,
        capturedLifecycle: capturedLifecycle,
      );
      return _turnEpoch == turnEpoch && state != ChatPipelineState.failed;
    } else {
      // Sin bridge capaz no se puede aislar en remoto. Degradamos al gateway
      // (comportamiento actual, sin aislar) y avisamos — no inyectamos un SOUL
      // débil que el gateway ignora.
      profileNotIsolated = true;
      return _startRemoteAgentTurn(
        fullText,
        model,
        history,
        turnEpoch,
        sessionConfig: _turnSessionConfig,
        profile: profile,
        nativeAttachments: nativeAttachments,
      );
    }
  }

  /// ¿La instancia remota tiene un bridge alcanzable con soporte de perfil
  /// (`hermes --profile`, v1.10.0+)? Cacheado por instancia. Usa `/bridge/health`
  /// (sin auth). Cualquier fallo → false (degrada al gateway).
  static const String _bridgeProfileMinVersion = '1.10.0';
  static final Map<String, bool> _bridgeProfileCache = {};
  Future<bool> _remoteBridgeProfileReady() async {
    final key = connection.id;
    final cached = _bridgeProfileCache[key];
    if (cached != null) return cached;
    final base = connection.derivedBridgeUrl;
    if (base.isEmpty) return _bridgeProfileCache[key] = false;
    try {
      final ver = await BridgeClient.probeVersion(base);
      final ok =
          ver != null &&
          ver.isNotEmpty &&
          BridgeVersion.compare(ver, _bridgeProfileMinVersion) >= 0;
      return _bridgeProfileCache[key] = ok;
    } catch (error) {
      debugPrint(
        '[active-chat] bridge profile unavailable (${error.runtimeType})',
      );
      return _bridgeProfileCache[key] = false;
    }
  }

  /// Invalida la caché de capacidad de perfil del bridge (p.ej. tras actualizarlo).
  static void invalidateBridgeProfileCache([String? connId]) {
    if (connId == null) {
      _bridgeProfileCache.clear();
    } else {
      _bridgeProfileCache.remove(connId);
    }
  }

  /// (Sin uso activo) Antepone el SOUL como system al [history]. Conservado solo
  /// como utilidad pura testeable; la degradación remota ya NO lo usa porque el
  /// gateway antepone su propio SOUL y este se ignora (ver spec 012, FR-016).
  @visibleForTesting
  static List<Map<String, dynamic>> historyWithSoul(
    String? soul,
    List<Map<String, dynamic>> history,
  ) {
    if (soul == null || soul.trim().isEmpty) return history;
    return <Map<String, dynamic>>[
      {'role': 'system', 'content': soul},
      ...history,
    ];
  }

  /// LEGACY (TASK-014): SIN USO. El modo voz ya no envía ningún comando
  /// `/reasoning` automático (era frágil y podía ensuciar la sesión remota si el
  /// servidor no lo interpretaba). Se conserva el método por si una integración
  /// futura lo necesita de forma explícita; candidato a eliminar en una TASK
  /// posterior. No lo llames desde el flujo de voz.
  ///
  /// Aplica el esfuerzo de razonamiento a ESTA sesión vía el comando
  /// `/reasoning <nivel>` del gateway. No inserta mensajes ni emite eventos. Solo
  /// aplica a instancias remotas (`/v1/runs`). Best-effort: si falla, se ignora.
  void applyReasoningEffort(String level, {required String model}) {
    if (connection.kind == InstanceKind.localhost ||
        level.trim().isEmpty ||
        mutationsBlockedByOwnershipConflict) {
      return;
    }
    unawaited(
      _trackRuntimeMutation<void>(() async {
        final runId = await _api.startRun(
          input: '/reasoning $level',
          sessionId: sessionId,
          profile: sessionProfile,
          model: explicitRunModel(model),
          history: const [],
        );
        _api.streamRunEvents(
          runId,
          profile: sessionProfile,
          onEvent: (_) {},
          onDone: () {},
          onError: (_) {},
        );
      }).catchError((Object _) {}),
    );
  }

  /// Camino de chat para instancias LOCALES (Termux): ejecuta un turno del
  /// agente a través del Mobile Bridge (`/bridge/chat` → `hermes -z`). Llega la
  /// respuesta final completa (sin streaming token a token; el oneshot no
  /// mantiene estado de sesión en el agente — cada turno es independiente).
  Future<void> _sendViaBridge(
    String prompt,
    List<Map<String, dynamic>> history, {
    String profile = '',
    bool forceAgent = false,
    required int turnEpoch,
    List<AttachmentDraft> nativeAttachments = const [],
    required LocalConversationLifecycle? capturedLifecycle,
    LocalConversationOperation? transcriptOperation,
  }) async {
    final transcriptLifecycle = capturedLifecycle;
    state = ChatPipelineState.waiting;
    _emit(ActiveChatEvent.connected);
    // Persiste ya el mensaje del usuario: si el turno se interrumpe (el SO mata
    // el proceso durante la llamada larga), al reabrir el chat seguirá la
    // pregunta en pantalla en vez de un historial vacío.
    if (transcriptOperation == null) {
      await _persistLocalTranscript(transcriptLifecycle);
    } else {
      await _persistLocalTranscript(transcriptLifecycle, transcriptOperation);
    }
    if (_turnEpoch != turnEpoch) return;
    try {
      final base = connection.derivedBridgeUrl;
      // Reintentos con backoff: el agente local puede estar despertando de una
      // congelación (Doze/App Standby) o recién arrancado; un único intento
      // fallaría aunque vuelva a responder en 1-2 s. 3 intentos ~6 s de margen.
      String? token;
      for (var attempt = 0; attempt < 3; attempt++) {
        token = await _bridgeProvisioner(base, connection.apiKey.trim());
        if (token != null && token.isNotEmpty) break;
        if (_turnEpoch != turnEpoch || _runTerminal) return;
        if (attempt < 2) {
          await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      }
      if (token == null || token.isEmpty) {
        if (_turnEpoch != turnEpoch) return;
        _failRun(
          'No se pudo conectar con el agente local (Mobile Bridge). '
          'Arranca el agente y reintenta.',
        );
        return;
      }
      final client = _bridgeClientFactory(baseUrl: base, token: token);
      if (_turnEpoch != turnEpoch) {
        client.close();
        return;
      }
      state = ChatPipelineState.executing;
      _emit(ActiveChatEvent.waiting);
      // Mantén vivo el proceso durante la llamada larga a `hermes -z` aunque la
      // app pase a 2º plano (isStreaming=true evita que se baje hasta terminar).
      await _onForegroundKeepAlive?.call();
      // El isolate del servicio sondea /v1/runs, que el bridge no expone, así
      // que no reflejaría este turno. Actualizamos la notificación persistente
      // a mano para que en 2º plano se vea que el agente local está procesando.
      await BackgroundListener.updateText(
        title: sessionTitle.isNotEmpty ? sessionTitle : 'Hermes Console',
        text: 'El agente local está procesando tu mensaje…',
      );

      var effectivePrompt = prompt;
      final attachmentPaths = <String>[];
      final delivery = _activeTurnDelivery;
      final binaryAttachments =
          (delivery?.current.activeAttachments ??
                  nativeAttachments
                      .where(
                        (item) =>
                            item.uploadState != AttachmentUploadState.removed,
                      )
                      .toList(growable: false))
              .where((item) => !AttachmentUploader.isTextEmbeddable(item))
              .toList(growable: false);
      if (!await _beginTurnTransport(
        turnEpoch,
        PreparedTurnTransport.bridgeLocal,
      )) {
        client.close();
        return;
      }
      final attachmentOwner = connection.id;
      try {
        for (final initialAttachment in binaryAttachments) {
          var attachment = initialAttachment;
          if (delivery != null && attachment.localId.isNotEmpty) {
            final staged = await delivery.beginAttachmentUpload(
              attachment.localId,
              remoteSessionId: attachmentOwner,
              transport: AttachmentRemoteTransport.bridgeLocal,
            );
            if (staged == null) {
              client.close();
              _failRun(
                delivery.persistenceFailed
                    ? 'No se pudo conservar el estado de un adjunto.'
                    : 'El lote de adjuntos cambió durante la subida.',
              );
              return;
            }
            attachment = staged;
            if (attachment.isAttachedTo(
              attachmentOwner,
              transport: AttachmentRemoteTransport.bridgeLocal,
            )) {
              continue;
            }
          }
          late final String path;
          try {
            path = await client.uploadAttachment(
              File(attachment.localPath),
              filename: attachment.name,
              mimeType: attachment.mimeType,
            );
          } catch (_) {
            if (delivery != null && attachment.localId.isNotEmpty) {
              await delivery.markAttachmentFailed(
                attachment.localId,
                attempt: attachment.attempt,
                errorKind: AttachmentErrorKind.transport,
              );
            }
            rethrow;
          }
          if (_turnEpoch != turnEpoch || _runTerminal) {
            client.close();
            return;
          }
          if (path.isEmpty) {
            if (delivery != null && attachment.localId.isNotEmpty) {
              await delivery.markAttachmentFailed(
                attachment.localId,
                attempt: attachment.attempt,
                errorKind: AttachmentErrorKind.transport,
              );
            }
            client.close();
            _failRun('No se pudo preparar un adjunto para esta instancia.');
            return;
          }
          if (delivery == null || attachment.localId.isEmpty) {
            attachmentPaths.add(path);
            continue;
          }
          final persisted = await delivery.markAttachmentAttached(
            attachment.localId,
            attempt: attachment.attempt,
            remoteSessionId: attachmentOwner,
            transport: AttachmentRemoteTransport.bridgeLocal,
            remoteRef: path,
          );
          if (!persisted) {
            client.close();
            _failRun(
              delivery.persistenceFailed
                  ? 'No se pudo conservar el estado de un adjunto.'
                  : 'El lote de adjuntos cambió durante la subida.',
            );
            return;
          }
        }
      } catch (_) {
        client.close();
        rethrow;
      }
      await delivery?.waitForAttachmentMutations();
      if (delivery != null) {
        final expectedIds = binaryAttachments
            .map((item) => item.localId)
            .where((id) => id.isNotEmpty)
            .toSet();
        final completed = delivery.current.activeAttachments
            .where(
              (item) =>
                  expectedIds.contains(item.localId) &&
                  item.isAttachedTo(
                    attachmentOwner,
                    transport: AttachmentRemoteTransport.bridgeLocal,
                  ),
            )
            .toList(growable: false);
        if (completed.length != expectedIds.length) {
          client.close();
          _failRun('El lote de adjuntos cambió durante la subida.');
          return;
        }
        attachmentPaths.addAll(completed.map((item) => item.remoteRef!));
      }
      if (attachmentPaths.isNotEmpty) {
        final refs = attachmentPaths
            .map((path) => '[Archivo adjunto disponible en $path]')
            .join('\n');
        effectivePrompt = '$effectivePrompt\n\n$refs'.trim();
      }

      // Resolución del modo de chat: simple evita el bucle de tool-calling que
      // deja vacío a los modelos pequeños (OlliteRT/Ollama ≤3B). Auto → simple
      // porque sin captura del modelo activo no podemos distinguir la capacidad
      // en runtime. Agent → agente completo (requiere modelo ≥7B).
      // `forceAgent` (chat de perfil remoto): exige el modo agente completo
      // (`hermes --profile -z`, con tools/skills/memoria del perfil); el chat
      // simple sería un POST directo al modelo, sin aislamiento. Para instancias
      // locales se respeta su `localChatMode` configurado.
      final useSimple =
          !forceAgent &&
          attachmentPaths.isEmpty &&
          (connection.localChatMode == LocalChatMode.simple ||
              connection.localChatMode == LocalChatMode.auto);

      var text = '';
      try {
        if (useSimple) {
          // Chat directo sin tools (bridge v1.9.0+). Sin SSE: el bridge devuelve
          // JSON plano. Renderizamos la respuesta completa de golpe (al igual que
          // el fallback chat() anterior, pero con modo=simple en el payload).
          text = (await client.chatSimple(
            effectivePrompt,
            history: history,
            profile: profile,
          )).trim();
        } else {
          // Streaming token a token (PTY en el bridge): se va emitiendo cada delta
          // como ActiveChatEvent.token, de modo que el modo voz hable frase a frase y
          // la burbuja crezca en vivo. Si el bridge es viejo (sin /bridge/chat/stream)
          // se cae al chat clásico sin re-ejecutar el turno.
          var gotAny = false;
          try {
            await for (final delta in client.chatStream(
              effectivePrompt,
              history: history,
              profile: profile,
              attachmentPaths: attachmentPaths,
            )) {
              if (_turnEpoch != turnEpoch || _runTerminal) break;
              _observeFirstResponseContent(delta);
              gotAny = true;
              text += delta;
              if (_messages.isNotEmpty && _messages[0]['role'] == 'assistant') {
                _messages[0] = {
                  ..._messages[0],
                  'content': text,
                  '_pipeline': false,
                };
              }
              _emit(ActiveChatEvent.token);
            }
          } on BridgeException catch (error) {
            debugPrint(
              '[active-chat] bridge stream failed (${error.runtimeType})',
            );
            final endpointDefinitelyMissing =
                !gotAny &&
                error.kind == BridgeErrorKind.notFound &&
                error.status == 404;
            // Un error SSE llega después del HTTP 200: aunque aún no haya
            // texto, el agente pudo ejecutar herramientas. Solo un 404 del
            // endpoint demuestra que el stream nunca empezó y permite usar el
            // bridge legacy sin duplicar el turno.
            if (!endpointDefinitelyMissing) rethrow;
            text = (await client.chat(
              effectivePrompt,
              history: history,
              profile: profile,
              attachmentPaths: attachmentPaths,
            )).trim();
          }
        }
      } finally {
        client.close();
      }
      if (_turnEpoch != turnEpoch || _runTerminal) return;
      if (_hasPendingActiveTurnCancellation) {
        try {
          await (_durableCancelFlight ?? _cancelledTurnPersistence);
        } catch (_) {
          // Mantiene el turno cancelable para que Stop pueda reintentarse.
        }
        return;
      }
      if (!await _settleTombstoneMetadataBeforeTerminal(turnEpoch)) return;
      _observeFirstResponseContent(text);
      _runTerminal = true;
      text = text.trim();
      if (_messages.isNotEmpty && _messages[0]['role'] == 'assistant') {
        _messages[0] = {..._messages[0], 'content': text, '_pipeline': false};
      }
      state = ChatPipelineState.completed;
      traceActive = false;
      if (text.isNotEmpty && _shouldNotifyReplies && _notifications != null) {
        final notificationText = GeneratedMediaService.stripDirectives(
          text,
        ).trim();
        await _deliverTerminalNotification(
          () => _notifications.replyReady(
            preview: notificationText.length > 140
                ? '${notificationText.substring(0, 140)}…'
                : notificationText,
            instance: connection.label,
            session: sessionTitle.isNotEmpty ? sessionTitle : sessionId,
            connId: connection.id,
            sessionId: serverSessionId,
            surface: notificationSurface,
            profile: sessionProfile,
            roomId: notificationRoomId,
          ),
        );
      }
      // Guarda la conversación completa (pregunta + respuesta) para que
      // sobreviva al cierre de la pantalla con la generación capturada al
      // admitir este turno.
      await _persistLocalTranscript(transcriptLifecycle, transcriptOperation);
      if (_turnEpoch == turnEpoch) {
        _commitTerminalSideEffectsOnce(turnEpoch);
        if (_messageQueue.isEmpty && _preparedTurnQueue.isEmpty) {
          _onTerminal();
        }
      }
    } catch (error) {
      if (_turnEpoch == turnEpoch) {
        _failRun(activeChatBridgeErrorUiMessage(error));
      }
    }
  }

  /// Conserva una indicación que no pudo entrar en el turno vivo. Se enviará
  /// automáticamente como turno normal al terminar, sin perder el texto.
  bool enqueue(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty ||
        _queueAdmissionFrozen ||
        mutationsBlockedByOwnershipConflict) {
      return false;
    }
    final capturedAllowTransportFallback = isStreaming
        ? _turnSessionConfig.allowTransportFallback
        : (_queueAdmissionAllowTransportFallback ?? false);
    final queueOrder = _nextQueueOrder++;
    _messageQueue.add(
      _QueuedTextTurn(
        appendBotMentionNote(
          trimmed,
          buildBotMentionAnnotation(mentionResolver.resolve(trimmed)),
        ),
        queueOrder,
        id: 'text:$queueOrder',
        // Solo un turno vivo o en admisión puede transferir su policy. Una cola
        // creada en reposo no tiene autoridad para abrir un fallback REST nuevo.
        allowTransportFallback: capturedAllowTransportFallback,
      ),
    );
    // Encolar es intención fresca de seguir la conversación: un park de un Stop
    // anterior no puede retener esta entrada ni las que ya estaban delante
    // (`enqueueQueuedPrompt`, `composer-queue.ts:145-148`).
    _unparkQueueLease();
    _emit(ActiveChatEvent.queueChanged);
    if (!_queueDrainSuspended && !isStreaming) Timer.run(_drainQueue);
    return true;
  }

  void _insertPreparedTurnByOrder(QueuedPreparedTurn turn) {
    if (_preparedTurnQueue.isEmpty ||
        _preparedTurnQueue.last.queueOrder < turn.queueOrder) {
      _preparedTurnQueue.addLast(turn);
      return;
    }
    final ordered = <QueuedPreparedTurn>[..._preparedTurnQueue, turn]
      ..sort((left, right) => left.queueOrder.compareTo(right.queueOrder));
    _preparedTurnQueue
      ..clear()
      ..addAll(ordered);
  }

  Future<bool> enqueuePreparedTurn(ActiveTurnDelivery delivery) async {
    if (_queueAdmissionFrozen || mutationsBlockedByOwnershipConflict) {
      return false;
    }
    final id = delivery.current.clientTurnId;
    final existingOwner = _preparedTurnOwners[id];
    if (existingOwner != null) {
      return existingOwner.state == _PreparedTurnOwnershipState.queued;
    }
    if (_preparedTurnCancellationsInFlight.contains(id)) return false;
    if (_preparedTurnQueue.any((item) => item.turn.clientTurnId == id)) {
      return true;
    }
    if (_pendingPreparedTurnIds.contains(id)) return false;
    final queueOrder = delivery.current.queueOrder ?? _nextQueueOrder;
    if (!delivery.assignQueueOrder(queueOrder)) return false;
    if (queueOrder >= _nextQueueOrder) _nextQueueOrder = queueOrder + 1;
    final queueGeneration = _queueGeneration;
    final queueParkGeneration = _queueParkGeneration;
    final owner = _PreparedTurnOwner(
      delivery: delivery,
      queueOrder: queueOrder,
      // Una outbox durable remota jamás cambia a REST: el ACK/idempotency y los
      // adjuntos pertenecen al runtime Desktop exacto.
      allowTransportFallback: false,
      state: _PreparedTurnOwnershipState.pendingSave,
    );
    _preparedTurnOwners[id] = owner;
    _pendingPreparedTurnIds.add(id);
    _pendingPreparedQueueOrders.add(queueOrder);
    try {
      if (!await delivery.persistPrepared()) {
        if (identical(_preparedTurnOwners[id], owner) &&
            owner.state == _PreparedTurnOwnershipState.pendingSave) {
          _preparedTurnOwners.remove(id);
        }
        return false;
      }
      if (_disposed ||
          queueGeneration != _queueGeneration ||
          owner.state != _PreparedTurnOwnershipState.pendingSave) {
        await _cancelOwnedPreparedTurn(owner);
        return false;
      }
      owner.state = _PreparedTurnOwnershipState.queued;
      _insertPreparedTurnByOrder(owner.queued);
      // Una admisión durable nueva es intención explícita de seguir: levanta el
      // park sólo después de que la escritura preparada haya aterrizado. Un
      // Stop pulsado mientras esa escritura estaba en vuelo gana la carrera y
      // conserva el turno estacionado hasta una reanudación explícita.
      if (_queueParkGeneration == queueParkGeneration) {
        _unparkQueueLease();
      }
      _emit(ActiveChatEvent.queueChanged);
      return true;
    } finally {
      _pendingPreparedTurnIds.remove(id);
      _pendingPreparedQueueOrders.remove(queueOrder);
      if (!_disposed && !_queueDrainSuspended && !isStreaming) {
        Timer.run(_drainQueue);
      }
    }
  }

  Future<void> restoreQueuedTurns(
    Iterable<PreparedTurn> turns,
    TurnOutboxPersistence store, {
    bool scheduleDrain = true,
  }) {
    final snapshot = turns.toList(growable: false);
    final operation = _queuedRestoreTail.then<void>(
      (_) => _restoreQueuedTurnsSerial(
        snapshot,
        store,
        scheduleDrain: scheduleDrain,
      ),
    );
    _queuedRestoreTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _restoreQueuedTurnsSerial(
    Iterable<PreparedTurn> turns,
    TurnOutboxPersistence store, {
    required bool scheduleDrain,
  }) async {
    if (_queueAdmissionFrozen || mutationsBlockedByOwnershipConflict) return;
    final restoreGeneration = _queueGeneration;
    final wasDrainSuspended = _queueDrainSuspended;
    _queueDrainSuspended = true;
    var changed = false;
    final recovered = turns.toList(growable: false)
      ..sort((left, right) {
        final leftOrder = left.queueOrder;
        final rightOrder = right.queueOrder;
        if (leftOrder == null && rightOrder == null) return 0;
        if (leftOrder == null) return -1;
        if (rightOrder == null) return 1;
        return leftOrder.compareTo(rightOrder);
      });
    for (final turn in recovered) {
      final order = turn.queueOrder;
      if (turn.queued && order != null && order >= _nextQueueOrder) {
        _nextQueueOrder = order + 1;
      }
    }
    try {
      for (final persistedTurn in recovered) {
        if (!persistedTurn.queued ||
            persistedTurn.state == PreparedTurnState.terminal) {
          continue;
        }
        var turn = persistedTurn;
        if (turn.state == PreparedTurnState.submitting ||
            turn.state == PreparedTurnState.ambiguous ||
            turn.state == PreparedTurnState.accepted ||
            turn.state == PreparedTurnState.running) {
          turn = await reconcileAmbiguousTurn(
            turn,
            store,
            stillCurrent: () =>
                !_disposed && restoreGeneration == _queueGeneration,
          );
          if (_disposed || restoreGeneration != _queueGeneration) return;
          if (turn.state == PreparedTurnState.terminal) {
            final owner = _preparedTurnOwners.remove(turn.clientTurnId);
            if (owner != null) {
              owner.state = _PreparedTurnOwnershipState.terminal;
              _preparedTurnQueue.removeWhere(
                (item) => item.delivery == owner.delivery,
              );
              if (_blockedPreparedTurnId == turn.clientTurnId) {
                _blockedPreparedTurnId = null;
              }
              changed = true;
            }
            continue;
          }
          // Solo un settlement exacto accepted/running instala el delivery activo.
          // Si la consulta devolvió known:false, el estado persistido por sí solo
          // sigue siendo incierto y debe conservar su lugar en la cola.
          if ((turn.state == PreparedTurnState.accepted ||
                  turn.state == PreparedTurnState.running) &&
              _activeTurnDelivery?.current.clientTurnId == turn.clientTurnId) {
            final owner = _preparedTurnOwners.remove(turn.clientTurnId);
            if (owner != null) {
              owner.state = _PreparedTurnOwnershipState.terminal;
              _preparedTurnQueue.removeWhere(
                (item) => item.delivery == owner.delivery,
              );
              if (_blockedPreparedTurnId == turn.clientTurnId) {
                _blockedPreparedTurnId = null;
              }
            }
            changed = true;
            continue;
          }
        }
        if (_preparedTurnOwners.containsKey(turn.clientTurnId) ||
            _pendingPreparedTurnIds.contains(turn.clientTurnId) ||
            _preparedTurnQueue.any(
              (item) => item.turn.clientTurnId == turn.clientTurnId,
            )) {
          continue;
        }
        final restoredOrder = turn.queueOrder ?? _nextQueueOrder++;
        final owner = _PreparedTurnOwner(
          delivery: ActiveTurnDelivery(prepared: turn, store: store),
          queueOrder: restoredOrder,
          allowTransportFallback: false,
          state: _PreparedTurnOwnershipState.queued,
        );
        _preparedTurnOwners[turn.clientTurnId] = owner;
        _insertPreparedTurnByOrder(owner.queued);
        if (turn.queueOrder == null ||
            turn.state == PreparedTurnState.submitting ||
            turn.state == PreparedTurnState.ambiguous ||
            turn.state == PreparedTurnState.accepted ||
            turn.state == PreparedTurnState.running ||
            turn.activeAttachments.any(
              (attachment) =>
                  attachment.uploadState == AttachmentUploadState.error &&
                  attachment.errorKind == AttachmentErrorKind.missingFile,
            )) {
          _blockedPreparedTurnId ??= turn.clientTurnId;
        }
        changed = true;
      }
      if (changed) _emit(ActiveChatEvent.queueChanged);
    } finally {
      if (!_disposed && restoreGeneration == _queueGeneration) {
        _queueDrainSuspended = scheduleDrain ? wasDrainSuspended : true;
        if (scheduleDrain && !_queueDrainSuspended && !isStreaming) {
          Timer.run(_drainQueue);
        }
      }
    }
  }

  bool promoteQueuedTurn(String id) {
    if (mutationsBlockedByOwnershipConflict || _disposed) return false;
    final occupiedOrders = <int>[
      ..._messageQueue.map((item) => item.queueOrder),
      ..._preparedTurnQueue.map((item) => item.queueOrder),
      ..._pendingPreparedQueueOrders,
    ];
    if (occupiedOrders.isEmpty) return false;
    final promotedOrder = occupiedOrders.reduce(math.min) - 1;
    final textIndex = _messageQueue.toList().indexWhere(
      (item) => item.id == id,
    );
    if (textIndex >= 0) {
      final items = _messageQueue.toList(growable: false);
      final target = items[textIndex];
      _messageQueue
        ..clear()
        ..add(
          _QueuedTextTurn(
            target.text,
            promotedOrder,
            id: target.id,
            allowTransportFallback: target.allowTransportFallback,
          ),
        )
        ..addAll(items.where((item) => !identical(item, target)));
      _emit(ActiveChatEvent.queueChanged);
      return true;
    }
    final preparedId = id.startsWith('prepared:')
        ? id.substring('prepared:'.length)
        : null;
    if (preparedId == null) return false;
    final items = _preparedTurnQueue.toList(growable: false);
    final index = items.indexWhere(
      (item) => item.turn.clientTurnId == preparedId,
    );
    if (index < 0) return false;
    final target = items[index];
    if (target.queueOrder == occupiedOrders.reduce(math.min)) return true;
    final promoted = QueuedPreparedTurn(
      target.delivery,
      queueOrder: promotedOrder,
      allowTransportFallback: target.allowTransportFallback,
    );
    final owner = _preparedTurnOwners[preparedId];
    if (owner != null) owner.queueOrder = promotedOrder;
    _preparedTurnQueue
      ..clear()
      ..add(promoted)
      ..addAll(items.where((item) => !identical(item, target)));
    _emit(ActiveChatEvent.queueChanged);
    return true;
  }

  Future<bool> editQueuedTurn(String id, String text) async {
    if (mutationsBlockedByOwnershipConflict ||
        _disposed ||
        text.trim().isEmpty) {
      return false;
    }
    final textItems = _messageQueue.toList(growable: false);
    final textIndex = textItems.indexWhere((item) => item.id == id);
    if (textIndex >= 0) {
      final target = textItems[textIndex];
      final replacement = _QueuedTextTurn(
        appendBotMentionNote(
          text.trim(),
          buildBotMentionAnnotation(mentionResolver.resolve(text.trim())),
        ),
        target.queueOrder,
        id: target.id,
        allowTransportFallback: target.allowTransportFallback,
      );
      final updated = [...textItems]..[textIndex] = replacement;
      _messageQueue
        ..clear()
        ..addAll(updated);
      _emit(ActiveChatEvent.queueChanged);
      return true;
    }
    if (!id.startsWith('prepared:')) return false;
    final clientTurnId = id.substring('prepared:'.length);
    final queued = _preparedTurnQueue.where(
      (item) => item.turn.clientTurnId == clientTurnId,
    );
    if (queued.isEmpty) return false;
    final changed = await queued.first.delivery.updatePreparedText(text);
    if (changed && !_disposed) _emit(ActiveChatEvent.queueChanged);
    return changed;
  }

  Future<bool> sendQueuedNow(String id) async {
    if (mutationsBlockedByOwnershipConflict || _disposed) return false;
    if (!queuedEntries.any((entry) => entry.id == id) ||
        id == 'desktop-accepted') {
      return false;
    }
    final preparedId = id.startsWith('prepared:')
        ? id.substring('prepared:'.length)
        : null;
    if (preparedId == null) {
      _queuedTextRetryTimer?.cancel();
      _queuedTextRetryTimer = null;
      _clearQueuedRetryState(id);
      _emit(ActiveChatEvent.queueChanged);
    } else {
      _queuedRetryTimer?.cancel();
      _queuedRetryTimer = null;
      _clearQueuedRetryState(preparedId);
      if (_blockedPreparedTurnId == preparedId) _blockedPreparedTurnId = null;
      _emit(ActiveChatEvent.queueChanged);
    }
    promoteQueuedTurn(id);
    // El interrupt existe para alcanzar la cola: el park se levanta antes de
    // interrumpir y de nuevo al asentarse, pues Stop parkea cualquier cola real.
    _unparkQueueLease();
    if (isStreaming) {
      try {
        await cancel();
      } catch (_) {
        return false;
      }
      _unparkQueueLease();
    }
    if (!isStreaming) await _drainQueue();
    return true;
  }

  Future<QueuedSteerOutcome> steerQueuedTurnWithOutcome(String id) async {
    if (mutationsBlockedByOwnershipConflict || _disposed || !isStreaming) {
      return QueuedSteerOutcome.rejected;
    }
    final matches = queuedEntries.where((entry) => entry.id == id);
    if (matches.isEmpty || !matches.first.isSteerable) {
      return QueuedSteerOutcome.rejected;
    }
    final entry = matches.first;
    _unparkQueueLease();
    try {
      final prepared = _preparedTurnQueue.where(
        (item) => 'prepared:${item.turn.clientTurnId}' == id,
      );
      final legacy = _messageQueue.where((item) => item.id == id);
      final payload = prepared.isNotEmpty
          ? appendBotMentionNote(
              prepared.first.turn.fullText,
              prepared.first.turn.mentionAnnotation,
            )
          : legacy.isNotEmpty
          ? legacy.first.text
          : entry.text;
      final disposition = await steer(payload, mentionsFrozen: true);
      if (disposition == DesktopRedirectDisposition.rejected) {
        return QueuedSteerOutcome.rejected;
      }
    } catch (error) {
      return activeChatSteerFailureIsSafeToQueue(error)
          ? QueuedSteerOutcome.rejected
          : QueuedSteerOutcome.unconfirmed;
    }
    return await cancelQueuedByIdentity(id)
        ? QueuedSteerOutcome.accepted
        : QueuedSteerOutcome.queueRemovalFailed;
  }

  Future<bool> steerQueuedTurn(String id) async =>
      await steerQueuedTurnWithOutcome(id) == QueuedSteerOutcome.accepted;

  Future<bool> cancelQueuedTurn(String clientTurnId) async {
    if (mutationsBlockedByOwnershipConflict) return false;
    final queued = _preparedTurnQueue.where(
      (item) => item.turn.clientTurnId == clientTurnId,
    );
    if (queued.isEmpty) return false;
    final target = queued.first;
    final owner = _preparedTurnOwners[clientTurnId];
    if (owner?.state == _PreparedTurnOwnershipState.cancelling) {
      return await _cancelOwnedPreparedTurn(owner!);
    }
    if (_preparedTurnCancellationsInFlight.contains(clientTurnId)) {
      return false;
    }
    if (_preparedTurnQueue.isNotEmpty &&
        identical(_preparedTurnQueue.first, target) &&
        _preparedTurnDrainInFlight) {
      return false;
    }
    _preparedTurnCancellationsInFlight.add(clientTurnId);
    if (owner != null) owner.state = _PreparedTurnOwnershipState.cancelling;
    try {
      if (!await target.delivery.discardPrepared()) {
        if (owner != null) owner.state = _PreparedTurnOwnershipState.queued;
        _blockedPreparedTurnId = clientTurnId;
        _emit(ActiveChatEvent.queueChanged);
        return false;
      }
      if (owner != null) owner.state = _PreparedTurnOwnershipState.terminal;
      _preparedTurnQueue.remove(target);
      if (identical(_preparedTurnOwners[clientTurnId], owner)) {
        _preparedTurnOwners.remove(clientTurnId);
      }
      if (_blockedPreparedTurnId == clientTurnId) {
        _blockedPreparedTurnId = null;
      }
      _unparkQueueLeaseIfEmpty();
      _emit(ActiveChatEvent.queueChanged);
      return true;
    } finally {
      _preparedTurnCancellationsInFlight.remove(clientTurnId);
      if (!_disposed && !_queueDrainSuspended && !isStreaming) {
        Timer.run(_drainQueue);
      }
    }
  }

  Future<bool> cancelQueuedByIdentity(String id) async {
    if (mutationsBlockedByOwnershipConflict || _disposed) return false;
    if (id == 'desktop-accepted') return false;
    if (id.startsWith('prepared:')) {
      return cancelQueuedTurn(id.substring('prepared:'.length));
    }
    final items = _messageQueue.toList(growable: false);
    final index = items.indexWhere((item) => item.id == id);
    if (index < 0) return false;
    final updated = [...items]..removeAt(index);
    _messageQueue
      ..clear()
      ..addAll(updated);
    _unparkQueueLeaseIfEmpty();
    _emit(ActiveChatEvent.queueChanged);
    return true;
  }

  void cancelQueued(int index) {
    final entries = <QueuedEntryView>[
      if (_desktopAcceptedQueuedPrompt != null)
        QueuedEntryView(
          id: 'desktop-accepted',
          kind: QueuedEntryKind.desktopAccepted,
          queueOrder: -1,
          text: stripBotMentionNote(_desktopAcceptedQueuedPrompt!),
        ),
      ..._messageQueue.map(
        (item) => QueuedEntryView(
          id: item.id,
          kind: QueuedEntryKind.text,
          queueOrder: item.queueOrder,
          text: stripBotMentionNote(item.text),
        ),
      ),
    ];
    if (index < 0 || index >= entries.length) return;
    unawaited(cancelQueuedByIdentity(entries[index].id));
  }

  void _clearQueue() {
    final hasAcceptedOptimistic = _messages.any(
      (message) => message['_desktopAcceptedQueued'] == true,
    );
    if (_messageQueue.isEmpty &&
        _preparedTurnQueue.isEmpty &&
        _pendingPreparedQueueOrders.isEmpty &&
        _desktopAcceptedQueuedPrompt == null &&
        !hasAcceptedOptimistic) {
      return;
    }
    _queueGeneration++;
    _messageQueue.clear();
    final prepared = _preparedTurnQueue.toList(growable: false);
    _preparedTurnQueue.clear();
    _blockedPreparedTurnId = null;
    for (final item in prepared) {
      unawaited(item.delivery.discardPrepared());
    }
    _desktopAcceptedQueuedPrompt = null;
    _messages.removeWhere(
      (message) => message['_desktopAcceptedQueued'] == true,
    );
    _unparkQueueLeaseIfEmpty();
    _emit(ActiveChatEvent.queueChanged);
  }

  void _freezeQueueForStop() {
    // Parkear existe para retener turnos ya encolados. Sin nada en cola el park
    // no frena nada y sólo queda como valla rancia — réplica de
    // `parkQueuedPrompts` (`composer-queue.ts:312-317`).
    if (!_hasQueuedWork) return;
    _queueParkGeneration++;
    _queueLease = QueueLease.parked;
    _queueDrainSuspended = true;
    final acceptedByGateway = _desktopAcceptedQueuedPrompt;
    if (acceptedByGateway != null && acceptedByGateway.trim().isNotEmpty) {
      final occupiedOrders = <int>[
        ..._messageQueue.map((item) => item.queueOrder),
        ..._preparedTurnQueue.map((item) => item.queueOrder),
        ..._pendingPreparedQueueOrders,
      ];
      final firstOrder = occupiedOrders.isEmpty
          ? 0
          : occupiedOrders.reduce(math.min) - 1;
      _messageQueue.addFirst(
        _QueuedTextTurn(
          acceptedByGateway.trim(),
          firstOrder,
          id: 'desktop-accepted',
          allowTransportFallback: false,
        ),
      );
      _desktopAcceptedQueuedPrompt = null;
      _messages.removeWhere(
        (message) => message['_desktopAcceptedQueued'] == true,
      );
    }
    _emit(ActiveChatEvent.queueChanged);
  }

  void _ensureOwnedPreparedTurnVisible(_PreparedTurnOwner owner) {
    if (_preparedTurnQueue.any((item) => item.delivery == owner.delivery)) {
      return;
    }
    _insertPreparedTurnByOrder(owner.queued);
  }

  Future<bool> _cancelOwnedPreparedTurn(_PreparedTurnOwner owner) async {
    if (owner.state == _PreparedTurnOwnershipState.terminal) return true;
    owner.state = _PreparedTurnOwnershipState.cancelling;
    _pendingPreparedQueueOrders.remove(owner.queueOrder);
    _ensureOwnedPreparedTurnVisible(owner);
    _preparedTurnCancellationsInFlight.add(owner.id);
    final operation = owner.cancellation ??= owner.delivery
        .markPreparedTerminalAndDelete();
    final terminal = await operation;
    if (identical(owner.cancellation, operation)) owner.cancellation = null;
    if (terminal) {
      owner.state = _PreparedTurnOwnershipState.terminal;
      _preparedTurnQueue.removeWhere((item) => item.delivery == owner.delivery);
      if (identical(_preparedTurnOwners[owner.id], owner)) {
        _preparedTurnOwners.remove(owner.id);
      }
      if (_blockedPreparedTurnId == owner.id) _blockedPreparedTurnId = null;
    } else {
      _blockedPreparedTurnId = owner.id;
    }
    _preparedTurnCancellationsInFlight.remove(owner.id);
    _emit(ActiveChatEvent.queueChanged);
    return terminal;
  }

  void _replaceDesktopAcceptedQueue(String? text) {
    final normalized = text?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (_desktopAcceptedQueuedPrompt == next) return;
    _desktopAcceptedQueuedPrompt = next;
    _emit(ActiveChatEvent.queueChanged);
  }

  void _appendDesktopAcceptedQueue(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    final previous = _desktopAcceptedQueuedPrompt;
    _desktopAcceptedQueuedPrompt = previous == null || previous.isEmpty
        ? normalized
        : '$previous\n\n$normalized';
    _emit(ActiveChatEvent.queueChanged);
  }

  Future<bool> _desktopQueueDrainIsAuthorized() async {
    if (_queueLease == QueueLease.parked) return false;
    final gateway = _desktopGateway;
    if (gateway == null) return true;
    // This Console instance already owns the exact runtime it would submit to;
    // active_list is only an arbitration fallback before runtime ownership.
    // Explicit resume is itself the user-owned authority to reacquire the exact
    // durable session for a parked text entry.
    if (_queueLease == QueueLease.resumeRequested) return true;
    if (_desktopRuntimeSessionId != null) return true;
    // A prepared head is already durably owned by this queue. Requiring an
    // unrelated active-list capability here made the ownership proof unusable
    // precisely on cold/idle gateways and left the FIFO permanently parked.
    if (_preparedTurnQueue.isNotEmpty) {
      final head = _preparedTurnQueue.first;
      final owner = _preparedTurnOwners[head.turn.clientTurnId];
      if (owner != null &&
          identical(owner.delivery, head.delivery) &&
          owner.state == _PreparedTurnOwnershipState.queued) {
        return true;
      }
    }
    if (gateway is! HermesDesktopSessionActivityGateway ||
        _desktopQueueAuthorityCheckInFlight) {
      _passiveRemoteActivityState = DesktopPassiveActivityState.unknown;
      return false;
    }
    final activityGateway = gateway as HermesDesktopSessionActivityGateway;
    final storedId = storedSessionId?.trim();
    if (storedId == null || storedId.isEmpty) return false;
    final expectedTurnEpoch = _turnEpoch;
    final expectedBindEpoch = _desktopBindEpoch;
    final expectedSessionEpoch = _desktopSessionEpoch;
    final expectedRuntimeId = _desktopRuntimeSessionId;
    final requestGeneration = ++_passiveRemoteActivityRequestGeneration;
    _desktopQueueAuthorityCheckInFlight = true;
    try {
      final active = await activityGateway.listActiveSessions(
        currentRuntimeSessionId: expectedRuntimeId ?? '',
      );
      if (!_passiveRemoteActivityRequestStillCurrent(
        storedSessionId: storedId,
        runtimeSessionId: expectedRuntimeId,
        turnEpoch: expectedTurnEpoch,
        bindEpoch: expectedBindEpoch,
        sessionEpoch: expectedSessionEpoch,
        requestGeneration: requestGeneration,
        // Arbitrar la cola solo es válido sin turno vivo propio.
        streaming: false,
      )) {
        return false;
      }
      final state = activeChatPassiveRowsState(
        active.sessions.where((row) => row.storedSessionId == storedId),
        hasMalformedRows: active.hasMalformedRows,
      );
      _passiveRemoteActivityState = state;
      return state == DesktopPassiveActivityState.idle;
    } catch (_) {
      if (_passiveRemoteActivityRequestStillCurrent(
        storedSessionId: storedId,
        runtimeSessionId: expectedRuntimeId,
        turnEpoch: expectedTurnEpoch,
        bindEpoch: expectedBindEpoch,
        sessionEpoch: expectedSessionEpoch,
        requestGeneration: requestGeneration,
        streaming: false,
      )) {
        _applyPassiveActivityState(DesktopPassiveActivityState.unknown);
      }
      return false;
    } finally {
      _desktopQueueAuthorityCheckInFlight = false;
    }
  }

  Future<void> _drainQueue() async {
    if (_disposed ||
        mutationsBlockedByOwnershipConflict ||
        _queueLease == QueueLease.parked ||
        _queueDrainSuspended ||
        isStreaming ||
        _preparedTurnDrainInFlight) {
      return;
    }
    if (!await _desktopQueueDrainIsAuthorized()) return;
    if (_disposed ||
        mutationsBlockedByOwnershipConflict ||
        _queueLease == QueueLease.parked ||
        _queueDrainSuspended ||
        isStreaming ||
        _preparedTurnDrainInFlight) {
      return;
    }
    if (_pendingPreparedQueueOrders.isNotEmpty) {
      final readyOrders = <int>[
        if (_messageQueue.isNotEmpty) _messageQueue.first.queueOrder,
        if (_preparedTurnQueue.isNotEmpty) _preparedTurnQueue.first.queueOrder,
      ];
      if (readyOrders.isEmpty ||
          _pendingPreparedQueueOrders.first < readyOrders.reduce(math.min)) {
        return;
      }
    }
    final preparedHeadBlocked =
        _preparedTurnQueue.isNotEmpty &&
        (_blockedPreparedTurnId == _preparedTurnQueue.first.turn.clientTurnId ||
            _preparedTurnCancellationsInFlight.contains(
              _preparedTurnQueue.first.turn.clientTurnId,
            ));
    final preparedComesFirst =
        _preparedTurnQueue.isNotEmpty &&
        !preparedHeadBlocked &&
        (_messageQueue.isEmpty ||
            _preparedTurnQueue.first.queueOrder <
                _messageQueue.first.queueOrder);
    if (preparedComesFirst) {
      final next = _preparedTurnQueue.first;
      if (_queuedRetriesExhausted.contains(next.turn.clientTurnId)) return;
      final owner = _preparedTurnOwners[next.turn.clientTurnId];
      if (owner?.state == _PreparedTurnOwnershipState.cancelling ||
          _blockedPreparedTurnId == next.turn.clientTurnId ||
          _preparedTurnCancellationsInFlight.contains(next.turn.clientTurnId)) {
        return;
      }
      final turn = next.turn;
      if (turn.queueOrder == null ||
          turn.state == PreparedTurnState.submitting ||
          turn.state == PreparedTurnState.ambiguous ||
          turn.state == PreparedTurnState.accepted ||
          turn.state == PreparedTurnState.running ||
          turn.activeAttachments.any(
            (attachment) =>
                attachment.uploadState == AttachmentUploadState.error &&
                attachment.errorKind == AttachmentErrorKind.missingFile,
          )) {
        _blockedPreparedTurnId = turn.clientTurnId;
        _emit(ActiveChatEvent.queueChanged);
        return;
      }
      _preparedTurnDrainInFlight = true;
      try {
        final accepted = await send(
          fullText: turn.fullText,
          desktopText: turn.desktopText,
          model: turn.model,
          history: _buildHistoryFromMessages(),
          profile: turn.profile,
          nativeAttachments: turn.activeAttachments,
          queued: true,
          delivery: next.delivery,
          allowTransportFallbackOverride: next.allowTransportFallback,
        );
        if (accepted &&
            _preparedTurnQueue.isNotEmpty &&
            identical(_preparedTurnQueue.first, next)) {
          _preparedTurnQueue.removeFirst();
          _clearQueuedRetryState(next.turn.clientTurnId);
          final owner = _preparedTurnOwners[next.turn.clientTurnId];
          if (owner?.delivery == next.delivery) {
            _preparedTurnOwners.remove(next.turn.clientTurnId);
          }
          _blockedPreparedTurnId = null;
          _unparkQueueLeaseIfEmpty();
          _emit(ActiveChatEvent.queueChanged);
        } else if (!accepted) {
          _blockedPreparedTurnId = next.turn.clientTurnId;
          _emit(ActiveChatEvent.queueChanged);
          _scheduleQueuedRetry(next.turn.clientTurnId);
        }
      } finally {
        _preparedTurnDrainInFlight = false;
      }
      return;
    }
    if (_messageQueue.isEmpty) return;
    final next = _messageQueue.first;
    if (_queuedRetriesExhausted.contains(next.id)) return;
    // La rama prepared ya se serializa con esta misma bandera. La de texto no
    // lo hacía: `send()` tarda varios `await` en publicar `connecting`, así que
    // dos drenajes solapados (terminal, retry, park levantado, inventario
    // pasivo) podían leer la misma cabeza y enviarla dos veces.
    _preparedTurnDrainInFlight = true;
    final bool accepted;
    try {
      accepted = await send(
        mentionsFrozen: true,
        fullText: next.text,
        model: _lastModel,
        history: _buildHistoryFromMessages(),
        profile: _turnProfile,
        queued: true,
        allowTransportFallbackOverride: next.allowTransportFallback,
      );
    } finally {
      _preparedTurnDrainInFlight = false;
    }
    if (_messageQueue.isEmpty || !identical(_messageQueue.first, next)) {
      return;
    }
    if (accepted) {
      _messageQueue.removeFirst();
      _clearQueuedRetryState(next.id);
      _unparkQueueLeaseIfEmpty();
      _emit(ActiveChatEvent.queueChanged);
      return;
    }
    // Un rechazo dejaba la entrada muda en la cabeza para siempre: nada más
    // volvía a pedir el drenaje y el panel la mostraba encolada sin avanzar.
    // Desktop reintenta de forma acotada (`MAX_AUTO_DRAIN_ATTEMPTS`) y deja la
    // entrada para un envío manual al agotarse.
    _scheduleQueuedTextRetry(next.id);
  }

  /// Reintento acotado de la cabeza de texto rechazada. Réplica de
  /// `MAX_AUTO_DRAIN_ATTEMPTS` (`composer-queue.ts`): agotados los intentos la
  /// entrada sigue en el panel para un envío manual, pero nunca se queda ahí
  /// sin que nadie vuelva a intentarlo.
  void _scheduleQueuedTextRetry(String id) {
    final attempt = (_queuedRetryAttempts[id] ?? 0) + 1;
    _queuedRetryAttempts[id] = attempt;
    _queuedTextRetryTimer?.cancel();
    _queuedTextRetryTimer = null;
    if (attempt > _maxQueuedRetryAttempts) {
      _queuedRetriesExhausted.add(id);
    }
    _emit(ActiveChatEvent.queueChanged);
    if (attempt > _maxQueuedRetryAttempts) return;
    _queuedTextRetryTimer = Timer(
      Duration(milliseconds: 400 * (1 << (attempt - 1))),
      () {
        _queuedTextRetryTimer = null;
        if (_disposed ||
            _messageQueue.isEmpty ||
            _messageQueue.first.id != id) {
          return;
        }
        unawaited(_drainQueue());
      },
    );
  }

  void _scheduleQueuedRetry(String clientTurnId) {
    final attempt = (_queuedRetryAttempts[clientTurnId] ?? 0) + 1;
    _queuedRetryAttempts[clientTurnId] = attempt;
    _queuedRetryTimer?.cancel();
    if (attempt > _maxQueuedRetryAttempts) {
      // La rama de texto emite arriba; ésta salía sin avisar a nadie, así que
      // el agotamiento quedaba invisible incluso para el panel.
      _queuedRetriesExhausted.add(clientTurnId);
      _emit(ActiveChatEvent.queueChanged);
      return;
    }
    _queuedRetryTimer = Timer(
      Duration(milliseconds: 400 * (1 << (attempt - 1))),
      () {
        _queuedRetryTimer = null;
        if (_disposed || _blockedPreparedTurnId != clientTurnId) return;
        _blockedPreparedTurnId = null;
        _emit(ActiveChatEvent.queueChanged);
        unawaited(_drainQueue());
      },
    );
  }

  /// Los mensajes pendientes son independientes de que el turno anterior haya
  /// terminado, fallado o sido detenido. Desktop aplica el mismo fallback.
  void _drainOrTerminal({required int expectedEpoch}) {
    if (_messageQueue.isEmpty && _preparedTurnQueue.isEmpty) {
      _onTerminal();
      return;
    }
    _terminalTimer?.cancel();
    _terminalTimer = Timer(const Duration(milliseconds: 800), () {
      _terminalTimer = null;
      if (_turnEpoch != expectedEpoch) return;
      _drainQueue();
      if (!isStreaming) _onTerminal();
    });
  }

  /// Historial conversacional reconstruido desde [_messages] para reenviarlo al
  /// agente y mantener el contexto del hilo. Lo usan la cola interna y el modo
  /// voz (que no tiene acceso a la lógica privada). Ver
  /// [_buildHistoryFromMessages].
  /// [excludeCancelled] se conserva por compatibilidad de API, pero ya no elimina
  /// contenido: Stop detiene el trabajo, no borra la memoria conversacional.
  /// Los turnos detenidos se etiquetan solo en el payload del modelo para que no
  /// se reanuden por iniciativa propia y sí puedan retomarse si el usuario los
  /// menciona expresamente.
  List<Map<String, dynamic>> buildHistory({bool excludeCancelled = false}) =>
      _buildHistoryFromMessages();

  /// Reconstruye el historial OpenAI `[{role, content}]` en orden cronológico a
  /// partir de [_messages] (index 0 = más nuevo), descartando placeholders del
  /// pipeline y errores: solo turnos conversacionales reales de user/assistant.
  List<Map<String, dynamic>> _buildHistoryFromMessages({
    Map<String, dynamic>? excluding,
  }) {
    final history = <Map<String, dynamic>>[];
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (identical(m, excluding)) continue;
      final role = (m['role'] ?? '').toString();
      if (role != 'user' && role != 'assistant') continue;
      if (m['_pipeline'] == true) continue;
      if ((m['display_kind'] ?? '').toString().isNotEmpty) continue;
      var content = (m['content'] as String?) ?? '';
      if (content.trim().isEmpty) continue;
      if (m['_cancelled'] == true || m['_cancelledUser'] == true) {
        content =
            '[Turno detenido por el usuario. No continúes este trabajo '
            'automáticamente; úsalo como contexto solo si el usuario vuelve a '
            'referirse a él.]\n$content';
      }
      history.add({'role': role, 'content': content});
    }
    return history;
  }

  void _setNoActivityHint(bool value) {
    if (_noActivityHint == value) return;
    _noActivityHint = value;
    _emit(ActiveChatEvent.sessionInfo);
  }

  void _armActivityWatchdog() {
    _activityWatchdogTimer?.cancel();
    _activityWatchdogTimer = null;
    _setNoActivityHint(false);
    if (_runTerminal || !isStreaming || needsInput) return;
    final turnEpoch = _turnEpoch;
    _activityWatchdogTimer = Timer(_activityHintTimeout, () {
      _activityWatchdogTimer = null;
      if (_disposed ||
          _turnEpoch != turnEpoch ||
          _runTerminal ||
          !isStreaming ||
          needsInput) {
        return;
      }
      _setNoActivityHint(true);
    });
  }

  void _observeRuntimeActivity() {
    if (_runTerminal || !isStreaming) return;
    _setNoActivityHint(false);
    _armActivityWatchdog();
  }

  void _onRunEvent(Map<String, dynamic> event) {
    // El run ya cerró localmente (el usuario tocó parar, o llegó un terminal):
    // ignora los frames rezagados que el gateway siga emitiendo hasta que el
    // SSE se cierre del todo. Si no, un `message.delta` tardío reprogramaría el
    // flush que hace `state = streaming` y resucitaría el estado "respondiendo"
    // (STOP + spinner) pese a estar ya cancelado/fallado.
    if (_runTerminal) return;
    final type = (event['event'] ?? '').toString();
    _observeRuntimeActivity();
    switch (type) {
      case 'message.delta':
        if (!_streamingConfirmed) {
          _streamingConfirmed = true;
          ConnectionManager.markStreamingSupported(connection.id);
        }
        _enqueueToken((event['delta'] ?? '').toString());
      case 'reasoning.delta':
      case 'thinking.delta':
        final delta = event['text'] ?? event['delta'];
        if (delta is String && delta.isNotEmpty) {
          _appendAssistantReasoningActivity(delta);
          _emit(ActiveChatEvent.toolProgress);
        }
      case 'reasoning.available':
        final reasoning = event['text'] ?? event['reasoning'];
        if (reasoning is String && reasoning.trim().isNotEmpty) {
          _appendAssistantReasoningActivity(reasoning, authoritative: true);
          _emit(ActiveChatEvent.toolProgress);
        }
      case 'tool.started':
        _flushTokenBuffer();
        state = ChatPipelineState.executing;
        _trackVoiceToolEvent(event, running: true, startsNew: true);
        _upsertRunTool(event, running: true);
        _upsertAssistantToolActivity(event, running: true, startsNew: true);
        _emit(ActiveChatEvent.toolProgress);
      case 'tool.completed':
        _flushTokenBuffer();
        _trackVoiceToolEvent(event, running: false, startsNew: false);
        _upsertRunTool(event, running: false);
        _upsertAssistantToolActivity(event, running: false, startsNew: false);
        _emit(ActiveChatEvent.toolProgress);
      case 'approval.request':
        _flushTokenBuffer();
        _handleApprovalRequest(event);
      case 'approval.responded':
        final respondedId = _approvalRequestId(event);
        final pendingId = _approvalRequestId(pendingApproval);
        if (respondedId == null ||
            pendingId == null ||
            respondedId != pendingId) {
          return;
        }
        _cancelApprovalNotification(pendingApproval!, terminal: false);
        pendingApproval = null;
        state = ChatPipelineState.executing;
        _emit(ActiveChatEvent.toolProgress);
      case 'run.completed':
        final out = (event['output'] ?? '').toString();
        _completeRun(finalOutput: out.isNotEmpty ? out : null);
      case 'run.failed':
        _failRun((event['error'] ?? 'La ejecución falló').toString());
      case 'run.cancelled':
        _cancelRunState();
    }
  }

  /// El SSE del run cerró. Si no llegó un evento terminal explícito, asume que
  /// el turno completó y refresca.
  void _onRunStreamDone() {
    if (_runTerminal) return;
    _completeRun();
  }

  /// Adapta un evento tool.started/tool.completed del run a una línea de trace.
  void _upsertRunTool(Map<String, dynamic> event, {required bool running}) {
    final tool = (event['tool'] ?? 'herramienta').toString();
    final failed = event['error'] == true;
    final status = running ? 'running' : (failed ? 'failed' : 'completed');
    // Empareja con la última línea abierta de esa herramienta, o crea una nueva.
    final idx = trace.lastIndexWhere(
      (e) => e.id == tool && !e.isDone && !e.isFailed,
    );
    if (!running && idx >= 0) {
      trace[idx].status = status;
    } else {
      // `preview` (el argumento real: query, ruta…) viaja en tool.started y se
      // conserva solo para la tarjeta técnica. Voz clasifica el NOMBRE del tool
      // y jamás consume este campo porque puede contener rutas o secretos.
      final preview = (event['preview'] ?? '').toString();
      trace.add(
        ChatTraceEvent(
          id: tool,
          label: tool,
          status: status,
          emoji: '🔧',
          preview: preview,
        ),
      );
    }
  }

  void _trackVoiceToolEvent(
    Map<String, dynamic> event, {
    required bool running,
    required bool startsNew,
  }) {
    final label =
        (event['name'] ?? event['tool'] ?? event['tool_id'] ?? 'herramienta')
            .toString();
    final rawCallId = event['tool_call_id'] ?? event['call_id'] ?? event['id'];
    final normalizedCallId = rawCallId?.toString().trim();
    final callId = normalizedCallId == null || normalizedCallId.isEmpty
        ? null
        : normalizedCallId;
    var openIndex = callId == null
        ? -1
        : _activeVoiceTools.lastIndexWhere((tool) => tool.callId == callId);
    if (openIndex < 0 && !startsNew) {
      openIndex = _activeVoiceTools.lastIndexWhere(
        (tool) => tool.label == label,
      );
    }
    if (!running) {
      if (openIndex >= 0) _activeVoiceTools.removeAt(openIndex);
      return;
    }
    // A real start represents a new invocation, including two concurrent calls
    // with the same name. Progress/generating only adopts an invocation when a
    // start was not observed (legacy gateways may begin mid-lifecycle).
    if (startsNew) {
      if (callId == null || openIndex < 0) {
        _activeVoiceTools.add((callId: callId, label: label));
      }
      return;
    }
    if (openIndex < 0) {
      _activeVoiceTools.add((callId: callId, label: label));
    }
  }

  /// Aplica la política de aprobaciones a una `approval.request`. Vive aquí (en
  /// el servicio, no en la pantalla) para que YOLO/reglas guardadas auto-resuelvan
  /// AUNQUE el chat esté cerrado o la app en segundo plano —antes esto solo
  /// ocurría en RunsScreen, así que en el chat YOLO seguía preguntando—.
  ///
  ///   autoApprove → resuelve solo con el scope decidido (sin tarjeta).
  ///   blocked     → deniega solo (instancia/sesión solo-lectura).
  ///   ask / sin política → muestra la tarjeta y notifica si está en 2º plano.
  void _handleApprovalRequest(Map<String, dynamic> event) {
    // User input may legitimately take longer than the transport watchdog.
    // Resume the inactivity budget only after the approval is answered.
    _activityWatchdogTimer?.cancel();
    _activityWatchdogTimer = null;
    final command = (event['command'] ?? '').toString();
    final patternKey = (event['pattern_key'] ?? '').toString();
    final policy = _policy;
    final decision = policy?.evaluate(
      mode: policy.effectiveMode(sessionId),
      risk: assessCommandRisk(command.isEmpty ? null : command),
      readOnlyInstance: connection.readOnly,
      hasSavedAlways: policy.hasSavedAlways(
        connection.id,
        patternKey: patternKey.isEmpty ? null : patternKey,
        command: command.isEmpty ? null : command,
      ),
    );

    final requestId = _approvalRequestId(event);
    if (requestId == null) return;
    final permitted = permittedApprovalChoices(event);
    if (decision != null &&
        decision.kind == ApprovalDecisionKind.autoApprove &&
        permitted.contains(decision.scope!.wire)) {
      // YOLO / regla "siempre": resolver sin molestar al usuario.
      pendingApproval = event;
      state = ChatPipelineState.executing;
      _emit(ActiveChatEvent.toolProgress);
      unawaited(
        resolveApproval(decision.scope!.wire).catchError((Object _) {}),
      );
      return;
    }
    if (decision != null &&
        decision.kind == ApprovalDecisionKind.blocked &&
        permitted.contains(ApprovalScope.deny.wire)) {
      // Solo lectura: el agente no puede ejecutar; denegamos automáticamente.
      pendingApproval = event;
      state = ChatPipelineState.executing;
      _emit(ActiveChatEvent.toolProgress);
      unawaited(
        resolveApproval(ApprovalScope.deny.wire).catchError((Object _) {}),
      );
      return;
    }

    // Pedir: tarjeta inline + notificación (acciona aunque la app esté atrás).
    pendingApproval = event;
    state = ChatPipelineState.executing;
    _emit(ActiveChatEvent.approvalRequest);
    final tool =
        (event['command'] ??
                event['tool'] ??
                event['description'] ??
                'una herramienta')
            .toString();
    final approvalId = (event['request_id'] ?? event['approval_id'])
        ?.toString()
        .trim();
    _notifications?.approvalPending(
      tool: tool,
      instance: sessionTitle.isNotEmpty ? sessionTitle : null,
      connId: connection.id,
      // La pantalla y la superficie de voz marcan como visible la identidad
      // persistida. Usar aquí el id móvil provisional clasifica la aprobación
      // del propio chat como si viniera de "otro chat" y oculta su acceso.
      sessionId: serverSessionId,
      sessionTitle: sessionTitle,
      runId: _approvalRunOwner,
      approvalId: approvalId,
      surface: notificationSurface,
      profile: sessionProfile,
      roomId: notificationRoomId,
    );
  }

  /// Resuelve la aprobación pendiente del run (once|session|always|deny).
  Future<void> resolveApproval(String choice) {
    if (mutationsBlockedByOwnershipConflict) {
      return Future<void>.error(_ownershipConflictError('approval.resolve'));
    }
    final approval = pendingApproval;
    if (_approvalRequestId(approval) == null) {
      return Future<void>.error(StateError('Approval is no longer pending'));
    }
    if (!permittedApprovalChoices(approval!).contains(choice)) {
      return Future<void>.error(
        StateError('Approval choice is not permitted by Desktop'),
      );
    }
    return _resolveApprovalRequest(choice, approval);
  }

  String? _approvalRequestId(Map<String, dynamic>? approval) {
    final value = (approval?['request_id'] ?? approval?['approval_id'])
        ?.toString()
        .trim();
    return value == null || value.isEmpty ? null : value;
  }

  String? get _approvalRunOwner => currentRunId ?? _desktopRuntimeSessionId;

  void _cancelApprovalNotification(
    Map<String, dynamic> approval, {
    required bool terminal,
  }) {
    final approvalId = _approvalRequestId(approval);
    final runId = _approvalRunOwner;
    if (approvalId == null || runId == null) return;
    final operation = _notifications?.cancelApproval(
      connId: connection.id,
      profile: sessionProfile,
      runId: runId,
      approvalId: approvalId,
      terminal: terminal,
    );
    if (operation != null) {
      unawaited(operation.catchError((Object _) {}));
    }
  }

  Future<void> _resolveApprovalRequest(
    String choice,
    Map<String, dynamic> approval,
  ) async {
    final runId = _approvalRunOwner;
    final approvalId = _approvalRequestId(approval);
    if (approvalId == null) return;
    final approvalGeneration = _approvalGeneration;
    bool requestStillCurrent() =>
        !_disposed &&
        approvalGeneration == _approvalGeneration &&
        identical(pendingApproval, approval) &&
        _approvalRequestId(pendingApproval) == approvalId;
    final desktop = _desktopGateway;
    final runtimeId = _desktopRuntimeSessionId;
    if (currentRunId == null && desktop != null && runtimeId != null) {
      final requestBindEpoch = _desktopBindEpoch;
      final requestSessionEpoch = _desktopSessionEpoch;
      var resolved = 1;
      if (desktop is HermesDesktopApprovalResultGateway) {
        final result = await (desktop as HermesDesktopApprovalResultGateway)
            .resolveApprovalChecked(runtimeId, choice, requestId: approvalId);
        resolved = result.resolved;
      } else {
        await desktop.resolveApproval(runtimeId, choice, requestId: approvalId);
      }
      final authorityStillCurrent =
          !_disposed &&
          _desktopRuntimeSessionId == runtimeId &&
          _desktopBindEpoch == requestBindEpoch &&
          _desktopSessionEpoch == requestSessionEpoch;
      if (!authorityStillCurrent || resolved <= 0 || !requestStillCurrent()) {
        return;
      }
      if (runId != null) {
        await _notifications?.cancelApproval(
          connId: connection.id,
          profile: sessionProfile,
          runId: runId,
          approvalId: approvalId,
        );
      }
      if (!requestStillCurrent()) return;
      pendingApproval = null;
      state = ChatPipelineState.executing;
      _armActivityWatchdog();
      _emit(ActiveChatEvent.toolProgress);
      return;
    }
    if (runId == null) return;
    await _api.resolveRunApproval(
      runId,
      choice,
      requestId: approvalId,
      profile: sessionProfile,
    );
    if (!requestStillCurrent()) return;
    await _notifications?.cancelApproval(
      connId: connection.id,
      profile: sessionProfile,
      runId: runId,
      approvalId: approvalId,
    );
    if (!requestStillCurrent()) return;
    pendingApproval = null;
    state = ChatPipelineState.executing;
    if (!_streamingConfirmed) _armActivityWatchdog();
    _emit(ActiveChatEvent.toolProgress);
  }

  Future<DesktopPromptResponse> respondToClarify(
    InteractivePromptKey key,
    String answer,
  ) {
    final request = _interactivePrompts[key]?.request;
    if (request is ClarifyPromptRequest && request.isBatch) {
      return Future.error(StateError('Batch clarify requires batch response'));
    }
    return _respondToInteractivePrompt(
      key,
      expectedKind: InteractivePromptKind.clarify,
      invoke: (gateway) => gateway.respondToClarify(key.requestId, answer),
    );
  }

  Future<DesktopPromptResponse> respondToClarifyBatch(
    InteractivePromptKey key,
    Map<String, String> answers,
  ) {
    if (mutationsBlockedByOwnershipConflict) {
      return Future<DesktopPromptResponse>.error(
        _ownershipConflictError('clarify.respond'),
      );
    }
    // Mutual exclusion includes synchronous ResponseStarted callbacks: publish
    // the shared operation before starting any work that can emit an event.
    final inFlight = _batchLocks[key];
    if (inFlight != null) return inFlight;

    final submittedAnswers = Map<String, String>.unmodifiable(answers);
    final completer = Completer<DesktopPromptResponse>();
    final sharedOperation = completer.future;
    _batchLocks[key] = sharedOperation;

    void release() {
      if (identical(_batchLocks[key], sharedOperation)) {
        _batchLocks.remove(key);
      }
    }

    final source = Future<DesktopPromptResponse>.sync(
      () => _respondToClarifyBatch(key, submittedAnswers),
    );
    source.then<void>(
      (result) {
        release();
        completer.complete(result);
      },
      onError: (Object error, StackTrace stackTrace) {
        release();
        completer.completeError(error, stackTrace);
      },
    );
    return sharedOperation;
  }

  Future<DesktopPromptResponse> _respondToClarifyBatch(
    InteractivePromptKey key,
    Map<String, String> answers,
  ) async {
    final runtimeId = _desktopRuntimeSessionId;
    final entry = _interactivePrompts[key];
    if (_retiringDesktopRuntimeSessionId == key.runtimeSessionId ||
        runtimeId != key.runtimeSessionId ||
        entry?.request is! ClarifyPromptRequest ||
        entry?.status != InteractivePromptStatus.pending) {
      throw StateError('Interactive prompt is no longer pending');
    }
    final request = entry!.request as ClarifyPromptRequest;
    if (!request.isBatch) {
      throw StateError('Legacy clarify requires legacy response');
    }
    final desktop = _desktopGateway;
    final HermesDesktopInteractivePromptGateway? interactiveGateway =
        desktop is HermesDesktopInteractivePromptGateway
        ? desktop as HermesDesktopInteractivePromptGateway
        : null;
    if (interactiveGateway == null) {
      throw const TuiGatewayRpcError(
        'interactive.respond',
        'Hermes interactive prompts are unavailable',
        code: -32601,
      );
    }

    _reduceInteractivePrompt(InteractivePromptResponseStarted(key));
    if (_respondingBatchRequest(key, expectedRequest: request) == null) {
      return DesktopPromptResponse.fromJson(
        const {'status': 'expired'},
        method: 'clarify.respond',
        allowExpired: true,
      );
    }
    try {
      DesktopPromptResponse? lastResult;
      var questionIndex = 0;
      while (true) {
        final liveRequest = _respondingBatchRequest(
          key,
          expectedRequest: request,
        );
        if (liveRequest == null) {
          return lastResult ??
              DesktopPromptResponse.fromJson(
                const {'status': 'expired'},
                method: 'clarify.respond',
                allowExpired: true,
              );
        }
        if (questionIndex >= liveRequest.questions.length) break;
        final question = liveRequest.questions[questionIndex++];
        // A passive authoritative snapshot may confirm a later qid while an
        // earlier ACK is in flight. Re-read the live monotonic fence before
        // every send instead of relying on the list captured at submission.
        if (liveRequest.lockedAnswers.containsKey(question.qid)) continue;
        final answer = answers[question.qid];
        if (answer == null || answer.isEmpty) {
          _reduceInteractivePrompt(InteractivePromptResponseFailed(key));
          throw const TuiGatewayRpcError(
            'clarify.respond',
            'Missing answer for a batch question',
            code: 4004,
          );
        }
        lastResult = await interactiveGateway.respondToClarify(
          key.requestId,
          answer,
          questionId: question.qid,
        );
        final liveAfterAck = _respondingBatchRequest(
          key,
          expectedRequest: request,
        );
        if (liveAfterAck == null) return lastResult;
        // Evaluate each response immediately and stop on any non-success
        // outcome, before sending the next sequential answer.
        if (lastResult.isExpired) {
          _reduceInteractivePrompt(InteractivePromptExpired(key));
          return lastResult;
        }
        final authoritativeAnswer = liveAfterAck.lockedAnswers[question.qid];
        if (authoritativeAnswer != null && authoritativeAnswer != answer) {
          _reduceInteractivePrompt(InteractivePromptExpired(key));
          throw StateError('Authoritative clarify answer conflict');
        }
        _reduceInteractivePrompt(
          InteractivePromptBatchProgressConfirmed(key, question.qid, answer),
        );
      }
      final result =
          lastResult ??
          DesktopPromptResponse.fromJson(const {
            'status': 'ok',
          }, method: 'clarify.respond');
      if (_respondingBatchRequest(key, expectedRequest: request) == null) {
        _reduceInteractivePrompt(InteractivePromptExpired(key));
        return result;
      }
      _reduceInteractivePrompt(InteractivePromptResponded(key));
      if (!_runTerminal) _armActivityWatchdog();
      return result;
    } catch (error) {
      if (_interactivePrompts[key]?.isTerminal == true) {
        // A local fail-closed fence (for example, an authoritative answer
        // conflict) must remain terminal and must not be reopened by resume.
      } else if (_disposed ||
          _desktopRuntimeSessionId != key.runtimeSessionId) {
        _reduceInteractivePrompt(InteractivePromptExpired(key));
      } else if (error is TuiGatewayRpcError && error.code != null) {
        _reduceInteractivePrompt(
          error.code == 4009
              ? InteractivePromptExpired(key)
              : InteractivePromptResponseFailed(key),
        );
      } else {
        // A transport failure can happen after the server consumed the answer
        // but before its ACK arrived. Never reopen the card until a fresh
        // session snapshot says exactly which question IDs remain.
        await _reconcileAmbiguousClarify(key);
      }
      rethrow;
    }
  }

  bool _interactivePromptResponseStillLive(
    InteractivePromptKey key, {
    required InteractivePromptKind expectedKind,
    required InteractivePromptRequest expectedRequest,
  }) {
    final current = _interactivePrompts[key];
    final currentRequest = current?.request;
    final isLive =
        !_disposed &&
        _retiringDesktopRuntimeSessionId != key.runtimeSessionId &&
        _desktopRuntimeSessionId == key.runtimeSessionId &&
        currentRequest?.kind == expectedKind &&
        identical(currentRequest, expectedRequest) &&
        current?.status == InteractivePromptStatus.responding;
    if (isLive) return true;

    // A callback may install a different request under a reused identity. Seal
    // only the exact request that started this response, never its replacement
    // or a successor runtime's composite key.
    if (identical(currentRequest, expectedRequest) &&
        current?.isTerminal != true) {
      _reduceInteractivePrompt(InteractivePromptExpired(key));
    }
    return false;
  }

  ClarifyPromptRequest? _respondingBatchRequest(
    InteractivePromptKey key, {
    required ClarifyPromptRequest expectedRequest,
  }) {
    if (_disposed) return null;
    if (_retiringDesktopRuntimeSessionId == key.runtimeSessionId ||
        _desktopRuntimeSessionId != key.runtimeSessionId) {
      // A runtime rotation invalidates only this exact in-flight batch. Seal its
      // entry before returning so a late ACK cannot leave it stuck responding;
      // terminal tombstones and prompts from every other identity stay intact.
      _reduceInteractivePrompt(InteractivePromptExpired(key));
      return null;
    }
    final current = _interactivePrompts[key];
    final request = current?.request;
    return current?.key == key &&
            request is ClarifyPromptRequest &&
            request.key == key &&
            request.isBatch &&
            current?.status == InteractivePromptStatus.responding &&
            _orderedBatchDefinitionsEqual(expectedRequest, request) &&
            _lockedAnswersAdvanceMonotonically(
              expectedRequest.lockedAnswers,
              request.lockedAnswers,
            )
        ? request
        : null;
  }

  bool _orderedBatchDefinitionsEqual(
    ClarifyPromptRequest expected,
    ClarifyPromptRequest current,
  ) {
    if (expected.key != current.key ||
        !expected.isBatch ||
        !current.isBatch ||
        expected.questions.length != current.questions.length) {
      return false;
    }
    for (var index = 0; index < expected.questions.length; index++) {
      final expectedQuestion = expected.questions[index];
      final currentQuestion = current.questions[index];
      if (expectedQuestion.qid != currentQuestion.qid ||
          expectedQuestion.question != currentQuestion.question ||
          expectedQuestion.multiSelect != currentQuestion.multiSelect ||
          expectedQuestion.choices.length != currentQuestion.choices.length) {
        return false;
      }
      for (
        var choiceIndex = 0;
        choiceIndex < expectedQuestion.choices.length;
        choiceIndex++
      ) {
        if (expectedQuestion.choices[choiceIndex] !=
            currentQuestion.choices[choiceIndex]) {
          return false;
        }
      }
    }
    return true;
  }

  bool _lockedAnswersAdvanceMonotonically(
    Map<String, String> expected,
    Map<String, String> current,
  ) {
    for (final answer in expected.entries) {
      if (current[answer.key] != answer.value) return false;
    }
    return true;
  }

  Future<void> _reconcileAmbiguousClarify(InteractivePromptKey key) async {
    final desktop = _desktopGateway;
    if (desktop is! HermesDesktopSessionLifecycleGateway) return;
    final lifecycle = desktop as HermesDesktopSessionLifecycleGateway;
    final bindEpoch = _desktopBindEpoch;
    try {
      final snapshot = await lifecycle.resumeExisting(
        serverSessionId,
        profile: _storedSessionProfile,
        omitMessages: true,
      );
      if (_disposed ||
          bindEpoch != _desktopBindEpoch ||
          _desktopRuntimeSessionId != key.runtimeSessionId) {
        return;
      }
      if (snapshot.runtimeSessionId != key.runtimeSessionId) {
        _reduceInteractivePrompt(InteractivePromptExpired(key));
        return;
      }
      _reconcilePendingClarifySnapshot(snapshot, unlockResponding: true);
    } on Object {
      // Fail closed: keep `responding`, which disables retries until a later
      // authoritative resume/reconnect reconciles the prompt.
    }
  }

  Future<DesktopPromptResponse> respondToSudo(
    InteractivePromptKey key,
    EphemeralSensitiveValue password,
  ) => _respondToSensitiveInteractivePrompt(
    key,
    callerValue: password,
    expectedKind: InteractivePromptKind.sudo,
    invoke: (gateway, ownedValue) =>
        gateway.respondToSudo(key.requestId, ownedValue),
  );

  Future<DesktopPromptResponse> respondToSecret(
    InteractivePromptKey key,
    EphemeralSensitiveValue value,
  ) => _respondToSensitiveInteractivePrompt(
    key,
    callerValue: value,
    expectedKind: InteractivePromptKind.secret,
    invoke: (gateway, ownedValue) =>
        gateway.respondToSecret(key.requestId, ownedValue),
  );

  Future<DesktopPromptResponse> _respondToSensitiveInteractivePrompt(
    InteractivePromptKey key, {
    required EphemeralSensitiveValue callerValue,
    required InteractivePromptKind expectedKind,
    required Future<DesktopPromptResponse> Function(
      HermesDesktopInteractivePromptGateway gateway,
      EphemeralSensitiveValue ownedValue,
    )
    invoke,
  }) {
    String sensitiveValue;
    try {
      sensitiveValue = callerValue.take();
    } catch (error, stackTrace) {
      callerValue.dispose();
      return Future<DesktopPromptResponse>.error(error, stackTrace);
    }
    callerValue.dispose();

    final ownedValue = EphemeralSensitiveValue(sensitiveValue);
    try {
      final operation = _respondToInteractivePrompt(
        key,
        expectedKind: expectedKind,
        invoke: (gateway) => invoke(gateway, ownedValue),
      );
      return operation.whenComplete(ownedValue.dispose);
    } catch (error, stackTrace) {
      ownedValue.dispose();
      return Future<DesktopPromptResponse>.error(error, stackTrace);
    }
  }

  Future<DesktopPromptResponse> respondToTerminalRead(
    InteractivePromptKey key,
  ) => _respondToInteractivePrompt(
    key,
    expectedKind: InteractivePromptKind.terminalRead,
    invoke: (gateway) => gateway.respondToTerminalRead(key.requestId),
  );

  Future<DesktopPromptResponse> _respondToInteractivePrompt(
    InteractivePromptKey key, {
    required InteractivePromptKind expectedKind,
    required Future<DesktopPromptResponse> Function(
      HermesDesktopInteractivePromptGateway gateway,
    )
    invoke,
  }) async {
    if (mutationsBlockedByOwnershipConflict) {
      throw _ownershipConflictError('interactive.respond');
    }
    final runtimeId = _desktopRuntimeSessionId;
    final entry = _interactivePrompts[key];
    if (_retiringDesktopRuntimeSessionId == key.runtimeSessionId ||
        runtimeId != key.runtimeSessionId ||
        entry?.request?.kind != expectedKind ||
        entry?.status != InteractivePromptStatus.pending) {
      throw StateError('Interactive prompt is no longer pending');
    }
    final desktop = _desktopGateway;
    final HermesDesktopInteractivePromptGateway? interactiveGateway =
        desktop is HermesDesktopInteractivePromptGateway
        ? desktop as HermesDesktopInteractivePromptGateway
        : null;
    if (interactiveGateway == null) {
      throw const TuiGatewayRpcError(
        'interactive.respond',
        'Hermes interactive prompts are unavailable',
        code: -32601,
      );
    }

    _reduceInteractivePrompt(InteractivePromptResponseStarted(key));
    if (!_interactivePromptResponseStillLive(
      key,
      expectedKind: expectedKind,
      expectedRequest: entry!.request!,
    )) {
      if (expectedKind == InteractivePromptKind.terminalRead) {
        return DesktopPromptResponse.fromJson(
          const {'status': 'expired'},
          method: 'terminal.read.respond',
          allowExpired: true,
        );
      }
      throw StateError('Interactive prompt is no longer responding');
    }
    try {
      final result = await invoke(interactiveGateway);
      if (_disposed || _desktopRuntimeSessionId != key.runtimeSessionId) {
        _reduceInteractivePrompt(InteractivePromptExpired(key));
        return result;
      }
      _reduceInteractivePrompt(
        result.isExpired
            ? InteractivePromptExpired(key)
            : InteractivePromptResponded(key),
      );
      if (!result.isExpired && !_runTerminal) _armActivityWatchdog();
      return result;
    } catch (error) {
      final rpcCode = error is TuiGatewayRpcError ? error.code : null;
      if (expectedKind == InteractivePromptKind.clarify && rpcCode == null) {
        // A malformed/lost ACK may arrive after Hermes consumed the legacy
        // answer. Keep it fenced until session.resume reconciles authority.
        await _reconcileAmbiguousClarify(key);
      } else {
        _reduceInteractivePrompt(
          rpcCode == 4009
              ? InteractivePromptExpired(key)
              : InteractivePromptResponseFailed(key),
        );
      }
      rethrow;
    }
  }

  /// Adopta un turno iniciado fuera de Console que `session.resume` demuestra
  /// posterior al terminal visible. No reenvía el prompt: solo abre una época
  /// nueva para que delta/complete, recovery y subagentes no compartan las
  /// vallas ni el timer del turno anterior.
  bool _passiveBoundaryStillMatchesLatestDurableUser() {
    Map<String, dynamic>? latestDurableUser;
    for (final message in _messages) {
      if (!isRealUserTurn(message) ||
          _isLiveTranscriptProjection(message) ||
          !_hasDurableTranscriptIdentity(message)) {
        continue;
      }
      latestDurableUser = message;
      break;
    }
    final baseline = _activeTurnTranscriptBoundaryIdentity;
    if (baseline == null) {
      return _activeTurnStartedFromKnownMissing && latestDurableUser == null;
    }
    if (latestDurableUser == null ||
        !transcriptIdentityAliasesAreConsistent(latestDurableUser)) {
      return false;
    }
    final latestIdentity = _transcriptMessageIdentity(latestDurableUser);
    return latestIdentity != null && baseline.matches(latestIdentity);
  }

  void _beginExternallyObservedDesktopTurn(DesktopSessionSnapshot snapshot) {
    _terminalTimer?.cancel();
    _terminalTimer = null;
    final rebasePassiveBoundary =
        _passiveTurnBoundaryFresh &&
        _activeTurnTranscriptBoundaryScopeIsCurrent() &&
        _passiveBoundaryStillMatchesLatestDurableUser();
    final turnEpoch = _advanceTurnEpoch();
    if (rebasePassiveBoundary) {
      // The passive busy edge happened before REST could publish this turn.
      // Preserve that stronger causal boundary across the new turn epoch.
      _activeTurnTranscriptBoundaryEpoch = turnEpoch;
      _passiveTurnBoundaryFresh = false;
    } else {
      // Capture only the durable user that was already visible before this
      // observer publishes the incoming live projection. If the current user is
      // already live (or already durable after a late attach), capture fails
      // closed rather than crossing that row and inventing a predecessor.
      _captureActiveTurnTranscriptBoundary(
        turnEpoch,
        allowExistingTranscript: true,
      );
    }
    _beginObservedResponseTiming();
    final prompt = snapshot.inflight?.user?.trim() ?? '';
    if (prompt.isNotEmpty) lastPrompt = stripBotMentionNote(prompt);
    _settlePipelinePlaceholders();
    _messages.insert(0, {
      'role': 'assistant',
      'content': '',
      '_pipeline': true,
    });
    trace.clear();
    _activeVoiceTools.clear();
    traceActive = true;
    if (pendingApproval != null) {
      _cancelApprovalNotification(pendingApproval!, terminal: true);
    }
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    _pendingDesktopInterimKey = null;
    _assistantNarration.reset();
    _assistantRawStream.clear();
    _assistantPublicStream = '';
    currentRunId = null;
    _runTerminal = false;
    _streamingConfirmed =
        snapshot.inflight?.assistant?.trim().isNotEmpty == true;
    _cancelling = false;
    _discardLateInterruptTerminal = false;
    final hasLiveSubagent =
        _subagentActivities?.activities.any(
          (activity) => !activity.isTerminal,
        ) ??
        false;
    if (!hasLiveSubagent) {
      _rememberRetiredSubagentTerminals(_subagentActivities);
      _subagentActivities = null;
      _subagentTranscriptTurnAnchor = null;
      _pendingSubagentInterrupts.clear();
    }
  }

  /// Cierra la proyección visible del turno anterior y prepara el siguiente que
  /// Desktop ya aceptó. El Gateway conserva la autoridad sobre su envío.
  void _beginDesktopAcceptedQueuedTurn({String? finalOutput}) {
    final queuedPrompt = _desktopAcceptedQueuedPrompt;
    if (queuedPrompt == null || queuedPrompt.isEmpty) return;

    _observeFirstResponseContent(finalOutput);
    _clearDesktopCompactingIndicator();
    _desktopTurnStartedAt = null;
    _turnSubmittedAtMs = null;
    _activityWatchdogTimer?.cancel();
    _activityWatchdogTimer = null;
    _setNoActivityHint(false);
    if (_fluidStreaming) {
      _queueAuthoritativeFinalTail(finalOutput);
      _publishBufferedTokenBatch();
    }
    _flushTokenBuffer();
    if (pendingApproval != null) {
      _cancelApprovalNotification(pendingApproval!, terminal: true);
    }
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    _markCurrentTurnAwaitingTranscript();
    if (finalOutput != null &&
        _messages.isNotEmpty &&
        _messages.first['role'] == 'assistant') {
      _messages[0] = {
        ..._messages[0],
        'content': finalOutput,
        '_pipeline': false,
      };
    }
    _settlePipelinePlaceholders();
    _finalizeAcceptedTurnDelivery();

    // `session.redirect → queued` ya fue aceptado por el Gateway y este nuevo
    // turno se dispara desde su propio drenado. Solo avanzamos la proyección y
    // conservamos la suscripción; llamar a send/submitPrompt lo duplicaría.
    _messageLoadEpoch += 1;
    final turnEpoch = _advanceTurnEpoch();
    // El turno queued ya fue aceptado antes de que llegue aquí; una lectura
    // intermedia puede contener su user durable y no prueba que sea anterior.
    _captureActiveTurnTranscriptBoundary(
      turnEpoch,
      allowExistingTranscript: false,
    );
    _desktopAcceptedQueuedPrompt = null;
    _beginObservedResponseTiming();
    lastPrompt = stripBotMentionNote(queuedPrompt);
    state = ChatPipelineState.waiting;
    trace.clear();
    _activeVoiceTools.clear();
    traceActive = true;
    pendingApproval = null;
    _pendingDesktopInterimKey = null;
    _assistantNarration.reset();
    _assistantRawStream.clear();
    _assistantPublicStream = '';
    currentRunId = null;
    _terminalTimer?.cancel();
    _terminalTimer = null;
    _runTerminal = false;
    _streamingConfirmed = false;
    _cancelling = false;
    _discardLateInterruptTerminal = false;
    final hasLiveSubagent =
        _subagentActivities?.activities.any(
          (activity) => !activity.isTerminal,
        ) ??
        false;
    if (!hasLiveSubagent) {
      _rememberRetiredSubagentTerminals(_subagentActivities);
      _subagentActivities = null;
      _subagentTranscriptTurnAnchor = null;
      _pendingSubagentInterrupts.clear();
    }
    final acceptedOptimistic = _messages
        .where((message) => message['_desktopAcceptedQueued'] == true)
        .toList(growable: false);
    if (acceptedOptimistic.isEmpty) {
      // Un resume puede descubrir una cola aceptada por el Gateway sin que
      // exista la optimista de este proceso.
      _messages.insert(0, {'role': 'user', 'content': queuedPrompt});
    } else {
      _messages.removeWhere(
        (message) => message['_desktopAcceptedQueued'] == true,
      );
      for (final message in acceptedOptimistic) {
        message.remove('_desktopAcceptedQueued');
      }
      // Lista newest-first: al cerrar el reply anterior estas filas pasan a ser
      // el tail visible y quedan justo detrás del placeholder del turno nuevo.
      _messages.insertAll(0, acceptedOptimistic);
    }
    _messages.insert(0, {
      'role': 'assistant',
      'content': '',
      '_pipeline': true,
    });
    _armActivityWatchdog();
    _emit(ActiveChatEvent.queueChanged);
    _emit(ActiveChatEvent.started);
  }

  Future<void> _beginDesktopAcceptedQueuedTurnAfterBarrier(
    int completedEpoch,
  ) async {
    if (!_isCurrentEpoch(completedEpoch) ||
        !_runTerminal ||
        _desktopAcceptedQueuedPrompt == null ||
        !await _desktopQueueDrainIsAuthorized() ||
        !_isCurrentEpoch(completedEpoch) ||
        !_runTerminal) {
      return;
    }
    _beginDesktopAcceptedQueuedTurn();
  }

  Future<void> _deliverTerminalNotification(
    Future<void> Function() show,
  ) async {
    await _beforeTerminalNotification?.call();
    await show();
  }

  void _scheduleTerminalQueueDrainOnce(int completingEpoch) {
    final gate = _terminalCommitGate;
    if (!_isCurrentEpoch(completingEpoch) ||
        gate.epoch != completingEpoch ||
        gate.drainScheduled ||
        (_messageQueue.isEmpty && _preparedTurnQueue.isEmpty)) {
      return;
    }
    gate.drainScheduled = true;
    Timer.run(() {
      if (!_isCurrentEpoch(completingEpoch) ||
          !identical(gate, _terminalCommitGate)) {
        return;
      }
      _drainQueue();
    });
  }

  /// Claims the publish/drain edge for one turn epoch. Transcript application
  /// remains independently idempotent so a later durable hydration may replace
  /// a transport-authoritative projection without replaying terminal effects.
  bool _commitTerminalSideEffectsOnce(int completingEpoch) {
    if (!_isCurrentEpoch(completingEpoch)) return false;
    final gate = _terminalCommitGate;
    if (gate.epoch != completingEpoch) return false;
    gate.terminalClaimed = true;
    if (!gate.donePublished) {
      gate.donePublished = true;
      _emit(ActiveChatEvent.done);
    }
    _scheduleTerminalQueueDrainOnce(completingEpoch);
    if (!gate.desktopQueuedStarted && _desktopAcceptedQueuedPrompt != null) {
      gate.desktopQueuedStarted = true;
      unawaited(_beginDesktopAcceptedQueuedTurnAfterBarrier(completingEpoch));
    }
    return true;
  }

  bool _applyAuthoritativeTerminalTranscriptOnce(
    List<Map<String, dynamic>> transcript, {
    required int completingEpoch,
    required int messageLoadEpoch,
  }) {
    if (!_isCurrentEpoch(completingEpoch) ||
        messageLoadEpoch != _messageLoadEpoch ||
        _suppressTerminalHydrationAfterCompaction) {
      return false;
    }
    final expectedUsers = _messages.where(isRealUserTurn).length;
    if (!_terminalTranscriptCanReplaceVisibleProjection(
          transcript,
          expectedUsers,
        ) &&
        !_completedProcessTurnCoversLiveAssistant(transcript)) {
      return false;
    }
    final gate = _terminalCommitGate;
    if (gate.epoch != completingEpoch) return false;
    if (gate.transcriptApplied) return true;
    _captureArtifactMaps(transcript, logicalSessionId: logicalSessionId);
    final fencedTranscript = _carryNewestTerminalFence(
      _messages,
      _normalizedNewestFirst(transcript),
      candidateTranscriptComplete: true,
    );
    _messages = _applyCancelledTurnTombstonesForDisplay(
      fencedTranscript,
      incomingTranscriptComplete: true,
    );
    _markTranscriptComplete(visibleCount: _messages.length);
    _mergeSteerRecords();
    _reconcileSubagentsFromTranscript();
    gate.transcriptApplied = true;
    return true;
  }

  /// Cierre exitoso del turno: fija el texto final, refresca el historial real
  /// (con sus tool events para agrupar) y notifica si procede.
  Future<void> _completeRun({
    String? finalOutput,
    String? finalReasoning,
    bool finalOutputNarratable = true,
    List<Map<String, dynamic>>? authoritativeTranscript,
  }) async {
    final invocationEpoch = _turnEpoch;
    final invocationBindEpoch = _desktopBindEpoch;
    final invocationSessionEpoch = _desktopSessionEpoch;
    final invocationSocketGeneration = _desktopTerminalTransportGeneration;
    final invocationProducerChannel = _desktopTerminalProducerChannel;
    bool invocationStillCurrent() =>
        _isCurrentEpoch(invocationEpoch) &&
        invocationBindEpoch == _desktopBindEpoch &&
        invocationSessionEpoch == _desktopSessionEpoch &&
        invocationSocketGeneration == _desktopTerminalTransportGeneration &&
        identical(invocationProducerChannel, _desktopTerminalProducerChannel);
    final invocationPublicOutput = finalOutput == null
        ? null
        : finalizedPublicAssistantText(finalOutput);
    final invocationReasoning = finalReasoning?.trim();
    if (invocationPublicOutput?.isNotEmpty == true) {
      _pendingAuthoritativeTerminalEpoch = invocationEpoch;
      _pendingAuthoritativeTerminalOutput = invocationPublicOutput;
    }
    if (_runTerminal) {
      if (_clearFailedStopConfirmation()) {
        _emit(ActiveChatEvent.queueChanged);
      }
      return;
    }
    final pendingMetadataTurnEpoch = invocationEpoch;
    if (_hasPendingActiveTurnCancellation) {
      try {
        await (_durableCancelFlight ?? _cancelledTurnPersistence);
      } catch (_) {
        // Stop sigue visible y reintentable; el terminal no puede cerrar el run.
      }
      if (!invocationStillCurrent()) return;
      return;
    }
    if (!await _settleTombstoneMetadataBeforeTerminal(
      pendingMetadataTurnEpoch,
    )) {
      return;
    }
    if (!invocationStillCurrent() || _runTerminal) return;
    var authoritativeTranscriptApplied = false;
    if (authoritativeTranscript != null) {
      final authorityMessageLoadEpoch = _messageLoadEpoch;
      authoritativeTranscriptApplied =
          _applyAuthoritativeTerminalTranscriptOnce(
            authoritativeTranscript,
            completingEpoch: invocationEpoch,
            messageLoadEpoch: authorityMessageLoadEpoch,
          );
      if (!invocationStillCurrent() ||
          authorityMessageLoadEpoch != _messageLoadEpoch ||
          !authoritativeTranscriptApplied) {
        return;
      }
    }
    final requiresTranscriptAuthority =
        !authoritativeTranscriptApplied &&
        invocationPublicOutput?.isNotEmpty != true &&
        assistantContent.trim().isNotEmpty;
    if (requiresTranscriptAuthority) {
      final authorityMessageLoadEpoch = _messageLoadEpoch;
      final transcriptAuthoritative = await _reconcileTerminalTranscript(
        invocationEpoch,
        authorityMessageLoadEpoch,
        bindEpoch: invocationBindEpoch,
        sessionEpoch: invocationSessionEpoch,
        socketGeneration: invocationSocketGeneration,
        producerChannel: invocationProducerChannel,
      );
      if (!invocationStillCurrent() ||
          authorityMessageLoadEpoch != _messageLoadEpoch ||
          _runTerminal) {
        return;
      }
      if (!transcriptAuthoritative) return;
    }
    // Reclama el terminal después de resolver la metadata: mientras esa
    // persistencia está pendiente puede llegar un replay necesario del mismo
    // borde. A partir de aquí, el primer cierre ganado silencia duplicados.
    _runTerminal = true;
    _viewerTurnConvergenceEpoch = null;
    _settleLiveUsersAlreadyRepresentedByDurableTail();
    final publicFinalOutput =
        _pendingAuthoritativeTerminalEpoch == pendingMetadataTurnEpoch
        ? _pendingAuthoritativeTerminalOutput
        : invocationPublicOutput;
    _pendingAuthoritativeTerminalEpoch = null;
    _pendingAuthoritativeTerminalOutput = null;
    final settledFinalOutput = publicFinalOutput?.isNotEmpty == true
        ? publicFinalOutput
        : null;
    _observeFirstResponseContent(settledFinalOutput);
    _assistantNarration.settleFinal(
      finalOutputNarratable ? settledFinalOutput : null,
    );
    _clearDesktopCompactingIndicator();
    final completingEpoch = _turnEpoch;
    // A transport terminal is newer than any refresh already in flight.
    _messageLoadEpoch += 1;
    final completingMessageLoadEpoch = _messageLoadEpoch;
    _desktopTurnStartedAt = null;
    _turnSubmittedAtMs = null;
    _activityWatchdogTimer?.cancel();
    _activityWatchdogTimer = null;
    _setNoActivityHint(false);
    if (_fluidStreaming) {
      _queueAuthoritativeFinalTail(settledFinalOutput);
      _publishBufferedTokenBatch();
    }
    if (!_isCurrentEpoch(completingEpoch)) return;
    _flushTokenBuffer();
    _settleAssistantActivity(invocationReasoning);
    if (pendingApproval != null) {
      _cancelApprovalNotification(pendingApproval!, terminal: true);
    }
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    _markCurrentTurnAwaitingTranscript();
    if (_messages.isNotEmpty &&
        _messages[0]['role'] == 'assistant' &&
        ((settledFinalOutput != null &&
                _messages[0]['content'] != settledFinalOutput) ||
            invocationReasoning?.isNotEmpty == true)) {
      _messages[0] = {
        ..._messages[0],
        'content': ?settledFinalOutput,
        if (invocationReasoning?.isNotEmpty == true)
          'reasoning': invocationReasoning,
        '_pipeline': false,
      };
    }
    _settlePipelinePlaceholders();
    // El terminal del transporte ya confirma que este turno no debe volver a
    // enviarse. Su outbox se cierra antes de esperar la persistencia tardía del
    // transcript; esa espera solo afecta a la proyección visual.
    _finalizeAcceptedTurnDelivery();
    state = ChatPipelineState.completed;
    traceActive = false;
    // Terminal callbacks may drain only an active lease (or one explicitly
    // resumed after Stop) and only queue entries with durable local ownership.
    // The terminal gate makes this edge single-shot for the turn epoch.
    final hasDurablePreparedOwner = _preparedTurnQueue.any((queued) {
      final owner = _preparedTurnOwners[queued.turn.clientTurnId];
      return owner != null &&
          identical(owner.delivery, queued.delivery) &&
          owner.state == _PreparedTurnOwnershipState.queued;
    });
    if (_queueLease != QueueLease.parked && hasDurablePreparedOwner) {
      _queueLease = QueueLease.active;
      _scheduleTerminalQueueDrainOnce(completingEpoch);
    }
    final hadVisibleTerminalText = assistantContent.trim().isNotEmpty;
    if (hadVisibleTerminalText) {
      _commitTerminalSideEffectsOnce(completingEpoch);
    }
    // An empty transport terminal is not publishable completion: first wait for
    // the canonical transcript under the same turn/message-load fences. Turns
    // with visible streamed text keep the historical non-blocking behavior.
    final transcriptReconciled =
        authoritativeTranscriptApplied ||
        await _reconcileTerminalTranscript(
          completingEpoch,
          completingMessageLoadEpoch,
          bindEpoch: invocationBindEpoch,
          sessionEpoch: invocationSessionEpoch,
          socketGeneration: invocationSocketGeneration,
          producerChannel: invocationProducerChannel,
        );
    if (!invocationStillCurrent() ||
        completingMessageLoadEpoch != _messageLoadEpoch) {
      return;
    }
    final terminalProjectionAuthoritative =
        hadVisibleTerminalText ||
        transcriptReconciled ||
        assistantContent.trim().isNotEmpty;
    if (terminalProjectionAuthoritative) {
      _commitTerminalSideEffectsOnce(completingEpoch);
    }

    final content = assistantContent.trim();
    if (content.isNotEmpty && _shouldNotifyReplies && _notifications != null) {
      final notificationText = GeneratedMediaService.stripDirectives(
        content,
      ).trim();
      await _deliverTerminalNotification(
        () => _notifications.replyReady(
          preview: notificationText.length > 140
              ? '${notificationText.substring(0, 140)}…'
              : notificationText,
          instance: connection.label,
          session: sessionTitle.isNotEmpty ? sessionTitle : sessionId,
          connId: connection.id,
          sessionId: serverSessionId,
          surface: notificationSurface,
          profile: sessionProfile,
          roomId: notificationRoomId,
        ),
      );
      if (!invocationStillCurrent() ||
          completingMessageLoadEpoch != _messageLoadEpoch) {
        return;
      }
    }
    if (!transcriptReconciled || content.isEmpty) {
      // El Gateway puede emitir el terminal antes de que API Server publique la
      // sesión. Si ya tenemos texto por streaming no retrasamos el estado done:
      // reconciliamos en segundo plano y conservamos la proyección local hasta
      // que el transcript autoritativo incluya este turno.
      if (!_isDetachedIdle) {
        _scheduleTerminalTranscriptRecovery(
          completingEpoch,
          messageLoadEpoch: completingMessageLoadEpoch,
          requireAssistantText: content.isEmpty,
        );
      }
    }
    if (_isDetachedIdle) {
      // The authoritative terminal has already completed the background turn.
      // Park only viewer/recovery lifecycle; keep the chat and ownership receipt.
      _parkDetachedIdleLifecycle(terminalJustCompleted: true);
      return;
    }
    _terminalTimer?.cancel();
    _terminalTimer = Timer(const Duration(milliseconds: 800), () {
      _terminalTimer = null;
      if (!_isCurrentEpoch(completingEpoch)) return;
      if (!terminalProjectionAuthoritative) {
        _onTerminal();
        return;
      }
      if (state == ChatPipelineState.completed) {
        state = ChatPipelineState.idle;
        _emit(ActiveChatEvent.messagesHydrated);
      }
      _onTerminal();
    });
  }

  /// Retira en el borde terminal una proyección live de usuario cuando el
  /// mismo turno ya está presente como fila durable exacta en el tail.
  void _settleLiveUsersAlreadyRepresentedByDurableTail() {
    _passiveTurnBoundaryFresh = false;
    final proofPrevious = <Map<String, dynamic>>[];
    final durableOnly = <Map<String, dynamic>>[];
    for (var index = 0; index < _messages.length; index++) {
      final message = _messages[index];
      final localProjection = _isKnownLocalTranscriptProjection(
        _messages,
        index,
      );
      if (!localProjection) durableOnly.add(message);
      proofPrevious.add(
        localProjection &&
                message['role'] == 'user' &&
                !_hasDurableTranscriptIdentity(message) &&
                !_isLiveTranscriptProjection(message)
            ? {...message, '_optimistic': true}
            : message,
      );
    }
    final represented = <int>{
      ..._liveUserProjectionIndexesRepresentedByRefreshedTail(
        durableOnly,
        proofPrevious,
        refreshedTranscriptComplete: _transcriptIsComplete,
        currentTransportTerminalObserved: true,
      ),
      ..._liveUserProjectionIndexesAfterActiveTurnBoundary(_messages),
    };
    if (represented.isEmpty) return;
    _messages = [
      for (var index = 0; index < _messages.length; index++)
        if (!represented.contains(index)) _messages[index],
    ];
  }

  Set<int> _liveUserProjectionIndexesRepresentedAfterActiveTurnBoundary(
    List<Map<String, dynamic>> refreshedNewestFirst,
    List<Map<String, dynamic>> previousNewestFirst,
  ) {
    if (!_activeTurnTranscriptBoundaryScopeIsCurrent()) return const {};

    var boundaryExclusive = refreshedNewestFirst.length;
    final baseline = _activeTurnTranscriptBoundaryIdentity;
    if (baseline != null) {
      final matches = <int>[];
      for (var index = 0; index < refreshedNewestFirst.length; index++) {
        final row = refreshedNewestFirst[index];
        final identity = _transcriptMessageIdentity(row);
        if (transcriptIdentityAliasesShareExactCoordinate(row, baseline) &&
            (identity == null || !baseline.matches(identity))) {
          return const {};
        }
        if (identity != null && baseline.matches(identity)) {
          matches.add(index);
        }
      }
      if (matches.length != 1) return const {};
      boundaryExclusive = matches.single;
    } else if (!_activeTurnStartedFromKnownMissing) {
      return const {};
    }

    final currentDurableUsers = refreshedNewestFirst
        .take(boundaryExclusive)
        .where(
          (message) =>
              isRealUserTurn(message) &&
              !_isLiveTranscriptProjection(message) &&
              _hasDurableTranscriptIdentity(message),
        )
        .toList(growable: false);
    if (currentDurableUsers.isEmpty) return const {};

    final represented = <int>{};
    for (var index = 0; index < previousNewestFirst.length; index++) {
      final live = previousNewestFirst[index];
      if (!isRealUserTurn(live) || !_isLiveTranscriptProjection(live)) {
        continue;
      }
      final matches = currentDurableUsers
          .where(
            (durable) =>
                durable['content']?.toString() == live['content']?.toString(),
          )
          .length;
      if (matches == 1) represented.add(index);
    }
    return represented;
  }

  Set<int> _liveUserProjectionIndexesAfterActiveTurnBoundary(
    List<Map<String, dynamic>> messagesNewestFirst,
  ) {
    if (!_activeTurnTranscriptBoundaryScopeIsCurrent()) return const {};

    final baseline = _activeTurnTranscriptBoundaryIdentity;
    late final int boundaryExclusive;
    if (baseline == null) {
      // An explicitly missing stored transcript is the only safe empty
      // boundary. A late observer with no predecessor identity fails closed.
      if (!_activeTurnStartedFromKnownMissing) return const {};
      boundaryExclusive = messagesNewestFirst.length;
    } else {
      final matches = <int>[];
      for (var index = 0; index < messagesNewestFirst.length; index++) {
        final row = messagesNewestFirst[index];
        final identity = _transcriptMessageIdentity(row);
        if (transcriptIdentityAliasesShareExactCoordinate(row, baseline) &&
            (identity == null || !baseline.matches(identity))) {
          return const {};
        }
        if (identity != null && baseline.matches(identity)) matches.add(index);
      }
      if (matches.length != 1) return const {};
      boundaryExclusive = matches.single;
    }

    final represented = <int>{};
    for (var liveIndex = 0; liveIndex < boundaryExclusive; liveIndex++) {
      final live = messagesNewestFirst[liveIndex];
      if (!isRealUserTurn(live) || !_isLiveTranscriptProjection(live)) {
        continue;
      }
      final candidates = <int>[];
      for (
        var durableIndex = liveIndex + 1;
        durableIndex < boundaryExclusive;
        durableIndex++
      ) {
        final durable = messagesNewestFirst[durableIndex];
        if (!isRealUserTurn(durable) ||
            _isLiveTranscriptProjection(durable) ||
            !_hasDurableTranscriptIdentity(durable) ||
            durable['content']?.toString() != live['content']?.toString()) {
          continue;
        }
        candidates.add(durableIndex);
      }
      // Text/media only confirms the one user row already proven to belong to
      // this post-boundary turn; it never supplies identity by itself.
      if (candidates.length == 1) represented.add(liveIndex);
    }
    return represented;
  }

  /// El placeholder `_pipeline` es estado efímero de UI, no transcript.
  /// Al cerrar/iniciar un turno se eliminan los vacíos y cualquier contenido
  /// defensivo se convierte en mensaje normal para no ocultar texto recibido.
  void _settlePipelinePlaceholders() {
    for (var index = _messages.length - 1; index >= 0; index--) {
      final message = _messages[index];
      if (message['_pipeline'] != true) continue;
      final content = (message['content'] as String?) ?? '';
      if (content.trim().isEmpty) {
        _messages.removeAt(index);
      } else {
        _messages[index] = {...message, '_pipeline': false};
      }
    }
  }

  /// El terminal de Desktop puede adelantarse unos milisegundos al commit del
  /// transcript. Una sola lectura en ese instante devuelve el turno anterior y
  /// deja una burbuja vacía hasta reabrir el chat. El intento bloqueante sigue
  /// siendo único cuando ya existe texto local; si todavía llega un 404, el
  /// backoff de segundo plano completa la reconciliación sin alargar el run.
  Future<bool> _reconcileTerminalTranscript(
    int completingEpoch,
    int messageLoadEpoch, {
    required int bindEpoch,
    required int sessionEpoch,
    required int? socketGeneration,
    required Object? producerChannel,
  }) async {
    bool stillCurrent() =>
        _isCurrentEpoch(completingEpoch) &&
        messageLoadEpoch == _messageLoadEpoch &&
        bindEpoch == _desktopBindEpoch &&
        sessionEpoch == _desktopSessionEpoch &&
        socketGeneration == _desktopTerminalTransportGeneration &&
        identical(producerChannel, _desktopTerminalProducerChannel);
    if (!stillCurrent()) return false;
    if (_suppressTerminalHydrationAfterCompaction) {
      // Tras una compactación el stream/snapshot de Desktop es la fuente viva.
      // El endpoint REST puede seguir apuntando al tip anterior durante unos
      // instantes y no debe borrar la conversación recién rotada.
      return false;
    }
    final epochInvalidated = _turnEpochInvalidated.future;
    final needsRemoteText = assistantContent.trim().isEmpty;
    final delays = needsRemoteText
        ? const <Duration>[
            Duration.zero,
            Duration(milliseconds: 250),
            Duration(milliseconds: 750),
            Duration(milliseconds: 1500),
            Duration(seconds: 3),
          ]
        : const <Duration>[Duration.zero];
    final deadline = DateTime.now().add(_terminalReconcileBudget);

    for (final delay in delays) {
      if (!stillCurrent()) return false;
      var remaining = deadline.difference(DateTime.now());
      if (remaining.inMicroseconds <= 0) return false;
      if (delay > Duration.zero) {
        final wait = delay < remaining ? delay : remaining;
        final elapsed = await _waitForTerminalReconcileDelay(
          wait,
          epochInvalidated,
        );
        if (!elapsed) return false;
        if (!stillCurrent()) return false;
        if (wait < delay) return false;
      }
      remaining = deadline.difference(DateTime.now());
      if (remaining.inMicroseconds <= 0) return false;
      try {
        final transcript = await _terminalTranscriptBeforeDeadline(
          _loadStoredMessages(_storedSessionProfile),
          remaining,
          epochInvalidated,
        );
        if (!stillCurrent() || transcript == null) {
          return false;
        }
        if (!_applyAuthoritativeTerminalTranscriptOnce(
          transcript,
          completingEpoch: completingEpoch,
          messageLoadEpoch: messageLoadEpoch,
        )) {
          continue;
        }
        return true;
      } catch (error) {
        debugPrint(
          '[active-chat] terminal transcript not ready '
          '(${error.runtimeType})',
        );
      }
    }
    return false;
  }

  void requestImmediateTransportRecovery() {
    if (_disposed || _desktopRecoveryWake.isCompleted) return;
    _desktopRecoveryWake.complete();
  }

  Future<bool> _waitForDesktopRecoveryDelay(
    Duration delay,
    Future<void> epochInvalidated,
  ) async {
    final wake = _desktopRecoveryWake;
    final elapsed = Completer<bool>();
    final timer = Timer(delay, () => elapsed.complete(true));
    try {
      return await Future.any<bool>([
        elapsed.future,
        wake.future.then((_) => true),
        _disposeSignal.future.then((_) => false),
        epochInvalidated.then((_) => false),
        _detachedIdleParked.future.then((_) => false),
      ]);
    } finally {
      timer.cancel();
      if (identical(_desktopRecoveryWake, wake) && wake.isCompleted) {
        _desktopRecoveryWake = Completer<void>();
      }
    }
  }

  /// Espera un backoff cancelable sin dejar un `Future.delayed` vivo después
  /// de cerrar el chat o invalidar el turno.
  Future<bool> _waitForTerminalReconcileDelay(
    Duration delay,
    Future<void> epochInvalidated,
  ) async {
    final elapsed = Completer<bool>();
    final timer = Timer(delay, () => elapsed.complete(true));
    try {
      return await Future.any<bool>([
        elapsed.future,
        _disposeSignal.future.then((_) => false),
        epochInvalidated.then((_) => false),
        _detachedIdleParked.future.then((_) => false),
      ]);
    } finally {
      timer.cancel();
    }
  }

  Future<T?> _desktopRecoveryOperationBeforeDeadline<T>(
    Future<T> operation,
    Future<void> epochInvalidated,
  ) async {
    final deadline = Completer<T?>();
    final timer = Timer(_desktopRecoveryAttemptTimeout, () {
      deadline.completeError(
        TimeoutException(
          'Desktop recovery operation timed out',
          _desktopRecoveryAttemptTimeout,
        ),
      );
    });
    try {
      return await Future.any<T?>([
        operation,
        deadline.future,
        _disposeSignal.future.then((_) => null),
        epochInvalidated.then((_) => null),
      ]);
    } finally {
      timer.cancel();
    }
  }

  /// Acota un GET y cancela el temporizador al terminar antes (éxito o error).
  /// `Future.any` por sí solo no cancela su `Future.delayed`; en widget tests y
  /// chats cerrados ese timer quedaba retenido durante todo el presupuesto.
  Future<List<Map<String, dynamic>>?> _terminalTranscriptBeforeDeadline(
    Future<List<Map<String, dynamic>>> request,
    Duration remaining,
    Future<void> epochInvalidated,
  ) async {
    final deadline = Completer<List<Map<String, dynamic>>?>();
    final timer = Timer(remaining, () => deadline.complete(null));
    try {
      return await Future.any<List<Map<String, dynamic>>?>([
        request,
        deadline.future,
        _disposeSignal.future.then((_) => null),
        epochInvalidated.then((_) => null),
      ]);
    } finally {
      timer.cancel();
    }
  }

  TerminalAuthorityDecision _terminalAuthority(
    List<Map<String, dynamic>> chronological,
    int expectedUsers, {
    TerminalEvidenceSource source = TerminalEvidenceSource.durableTranscript,
    bool sourceTranscriptComplete = true,
    bool transportTerminalObserved = false,
    bool transportTerminalIsError = false,
    bool compactionFenceActive = false,
    bool currentAuthorityFence = true,
  }) => decideTerminalAuthority(
    chronological: chronological,
    expectedUsers: expectedUsers,
    source: source,
    sourceTranscriptComplete: sourceTranscriptComplete,
    transportTerminalObserved: transportTerminalObserved,
    transportTerminalIsError: transportTerminalIsError,
    compactionFenceActive: compactionFenceActive,
    currentAuthorityFence: currentAuthorityFence,
    visibleAssistantTextPresent: assistantContent.trim().isNotEmpty,
    allowLegacyDirectToolTerminal: true,
  );

  bool _containsCompletedTurn(
    List<Map<String, dynamic>> chronological,
    int expectedUsers,
  ) =>
      _terminalAuthority(chronological, expectedUsers).kind ==
      TerminalAuthorityKind.authoritativeSuccess;

  bool _turnAwaitsFinalAfterToolInvocation(
    List<Map<String, dynamic>> chronological,
    int expectedUsers,
  ) =>
      _terminalAuthority(chronological, expectedUsers).reason ==
      TerminalAuthorityReason.openToolInvocation;

  bool _completedProcessTurnCoversLiveAssistant(
    List<Map<String, dynamic>> chronological,
  ) {
    if (_messages.length < 2) return false;
    final liveAssistant = _messages[0];
    final processComplete = _messages[1];
    if (liveAssistant['role'] != 'assistant' ||
        _hasDurableTranscriptIdentity(liveAssistant) ||
        processComplete['display_kind'] != 'process_complete' ||
        !transcriptIdentityAliasesAreConsistent(processComplete)) {
      return false;
    }
    final anchor = _transcriptMessageIdentity(processComplete);
    if (anchor == null) return false;
    final newestFirst = chronological.reversed.toList(growable: false);
    final resolved = _resolveTranscriptIdentity(
      newestFirst,
      messageId: anchor.messageId,
      rowId: anchor.rowId,
      accepts: (message) => message['display_kind'] == 'process_complete',
    );
    if (resolved.kind != _TranscriptIdentityResolutionKind.unique) return false;
    return newestFirst
        .take(resolved.index)
        .any(
          (message) =>
              message['role'] == 'assistant' &&
              _hasDurableTranscriptIdentity(message) &&
              (message['content'] ?? '').toString().trim().isNotEmpty,
        );
  }

  /// Prefix comparison remains a projection concern; terminal semantics come
  /// exclusively from [decideTerminalAuthority].
  bool _terminalTranscriptCanReplaceVisibleProjection(
    List<Map<String, dynamic>> chronological,
    int expectedUsers,
  ) {
    final authority = _terminalAuthority(chronological, expectedUsers);
    if (authority.kind != TerminalAuthorityKind.authoritativeSuccess) {
      return false;
    }
    final visible = assistantContent.trim();
    if (visible.isEmpty) return authority.mayReplaceVisibleProjection;
    final remote = authority.assistantText;
    final normalizedVisible = visible.replaceAll(RegExp(r'\s+'), ' ');
    final normalizedRemote = remote?.replaceAll(RegExp(r'\s+'), ' ');
    final stalePrefix =
        normalizedRemote != null &&
        normalizedRemote.length < normalizedVisible.length &&
        normalizedVisible.startsWith(normalizedRemote);
    final preservesVisible = remote != null && !stalePrefix;
    if (!preservesVisible) {
      debugPrint(
        '[active-chat] terminal transcript deferred '
        '(visible_chars=${visible.length}, remote_chars=${remote?.length ?? 0})',
      );
    }
    return preservesVisible;
  }

  /// Cierre con error del turno.
  void _failRun(
    String error, {
    String? terminalText,
    bool terminalTextIsPartial = false,
    bool authoritativeTerminalOverride = false,
    Map<String, dynamic> failureMetadata = const {},
  }) {
    if (_runTerminal && !authoritativeTerminalOverride) {
      if (_clearFailedStopConfirmation()) {
        _emit(ActiveChatEvent.queueChanged);
      }
      return;
    }
    if (_hasPendingActiveTurnCancellation) return;
    if (_hasPendingTombstoneMetadataUpdate) {
      final expectedTurnEpoch = _turnEpoch;
      unawaited(
        _deferFailRunUntilTombstoneMetadataSettles(
          expectedTurnEpoch,
          error,
          terminalText: terminalText,
          terminalTextIsPartial: terminalTextIsPartial,
          authoritativeTerminalOverride: authoritativeTerminalOverride,
          failureMetadata: failureMetadata,
        ),
      );
      return;
    }
    _clearDesktopCompactingIndicator();
    _messageLoadEpoch += 1;
    _runTerminal = true;
    _desktopTurnStartedAt = null;
    _turnSubmittedAtMs = null;
    _activityWatchdogTimer?.cancel();
    _activityWatchdogTimer = null;
    _setNoActivityHint(false);
    _flushTokenBuffer();
    if (pendingApproval != null) {
      _cancelApprovalNotification(pendingApproval!, terminal: true);
    }
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    if (_messages.isNotEmpty && _messages[0]['role'] == 'assistant') {
      final current = ((_messages[0]['content'] as String?) ?? '').trim();
      final terminal = terminalText?.trim() ?? '';
      final continuesCurrent =
          current.isNotEmpty &&
          (terminal.startsWith(current) || current.startsWith(terminal));
      if (terminal.isNotEmpty && (terminalTextIsPartial || continuesCurrent)) {
        _messages[0] = {..._messages[0], 'content': terminal};
      }
    }
    final hasPartial =
        _messages.isNotEmpty &&
        _messages[0]['role'] == 'assistant' &&
        ((_messages[0]['content'] as String?) ?? '').isNotEmpty;
    state = ChatPipelineState.failed;
    _finalizeAcceptedTurnDelivery();
    traceActive = false;
    _cancelling = false;
    if (!hasPartial &&
        _messages.isNotEmpty &&
        _messages[0]['role'] == 'assistant') {
      final projectionId = _nextLocalTranscriptProjectionId();
      _tagLatestUserForLocalError(projectionId);
      _messages[0] = {
        'role': 'assistant_error',
        'content': error,
        '_prompt': lastPrompt,
        ...failureMetadata,
        '_localTranscriptProjectionId': projectionId,
      };
    } else if (hasPartial &&
        _messages.isNotEmpty &&
        _messages[0]['role'] == 'assistant') {
      // A-012 (spec 028): el stream falló a media respuesta. Antes el parcial
      // quedaba pintado como un mensaje normal terminado (sin marca ni
      // reintento) y se podía leer una respuesta truncada creyéndola completa.
      // Se marca como interrumpido (misma marca visual que la cancelación) y
      // se añade la burbuja de error con "Reintentar" encima del parcial.
      _messages[0] = {..._messages[0], '_cancelled': true, '_pipeline': false};
      final projectionId = _nextLocalTranscriptProjectionId();
      _tagLatestUserForLocalError(projectionId);
      _messages.insert(0, {
        'role': 'assistant_error',
        'content': error,
        '_prompt': lastPrompt,
        ...failureMetadata,
        '_localTranscriptProjectionId': projectionId,
      });
    }
    // Avisa del problema si la app está en 2º plano (no molesta en primer plano).
    if (_shouldNotifyReplies && _notifications != null) {
      unawaited(
        _deliverTerminalNotification(
          () => _notifications.replyFailed(
            instance: connection.label,
            session: sessionTitle.isNotEmpty ? sessionTitle : sessionId,
            detail: error,
            connId: connection.id,
            sessionId: serverSessionId,
            surface: notificationSurface,
            profile: sessionProfile,
            roomId: notificationRoomId,
          ),
        ),
      );
    }
    _emit(ActiveChatEvent.error);
    _drainOrTerminal(expectedEpoch: _turnEpoch);
  }

  Future<void> _deferFailRunUntilTombstoneMetadataSettles(
    int expectedTurnEpoch,
    String error, {
    String? terminalText,
    required bool terminalTextIsPartial,
    required bool authoritativeTerminalOverride,
    required Map<String, dynamic> failureMetadata,
  }) async {
    if (!await _settleTombstoneMetadataBeforeTerminal(expectedTurnEpoch)) {
      return;
    }
    _failRun(
      error,
      terminalText: terminalText,
      terminalTextIsPartial: terminalTextIsPartial,
      authoritativeTerminalOverride: authoritativeTerminalOverride,
      failureMetadata: failureMetadata,
    );
  }

  ({int index, CancelledTurnTombstone tombstone})?
  _latestUserCancellationCandidate() {
    for (var index = 0; index < _messages.length; index++) {
      final message = _messages[index];
      if (!isRealUserTurn(message)) continue;
      final content = (message['content'] ?? '').toString();
      if (content.isEmpty) return null;
      final provenAnchorMessageId = message[_stopProofAnchorMessageIdKey];
      final provenAnchorRowId = message[_stopProofAnchorRowIdKey];
      final exactProvenAnchorMessageId =
          provenAnchorMessageId is String && provenAnchorMessageId.isNotEmpty
          ? provenAnchorMessageId
          : null;
      final exactProvenAnchorRowId =
          provenAnchorRowId is int && provenAnchorRowId > 0
          ? provenAnchorRowId
          : null;
      if (exactProvenAnchorMessageId != null ||
          exactProvenAnchorRowId != null) {
        return (
          index: index,
          tombstone: CancelledTurnTombstone(
            content: content,
            anchorMessageId: exactProvenAnchorMessageId,
            anchorRowId: exactProvenAnchorRowId,
          ),
        );
      }
      final targetMessageId = canonicalTranscriptMessageId(message);
      final targetRowId = canonicalTranscriptRowId(message);
      if (targetMessageId != null || targetRowId != null) {
        return (
          index: index,
          tombstone: CancelledTurnTombstone(
            content: content,
            cancelledMessageId: targetMessageId,
            cancelledRowId: targetRowId,
          ),
        );
      }
      String? anchorMessageId;
      int? anchorRowId;
      var anchorIndex = -1;
      final candidateIsLive = _isLiveTranscriptProjection(message);
      for (var older = index + 1; older < _messages.length; older++) {
        final olderMessage = _messages[older];
        anchorMessageId = canonicalTranscriptMessageId(olderMessage);
        anchorRowId = canonicalTranscriptRowId(olderMessage);
        if (anchorMessageId != null || anchorRowId != null) {
          anchorIndex = older;
          break;
        }
        // Un usuario intermedio sin identidad impide demostrar qué turno
        // sigue al ancla. No lo cruces: prompts repetidos podrían cancelar el
        // turno histórico y resucitar precisamente el que se detuvo.
        if (isRealUserTurn(olderMessage)) {
          final isSameLocalTurnProjection =
              candidateIsLive &&
              _isLiveTranscriptProjection(olderMessage) &&
              (olderMessage['content'] ?? '').toString() == content;
          if (!isSameLocalTurnProjection) return null;
        }
      }
      if (anchorMessageId != null || anchorRowId != null) {
        if (candidateIsLive && anchorIndex >= 0) {
          final anchorMessage = _messages[anchorIndex];
          if (isRealUserTurn(anchorMessage) &&
              (anchorMessage['content'] ?? '').toString() == content) {
            // El primer ID encontrado puede ser la copia durable del propio
            // inflight. No es un ancla anterior; la prueba de pertenencia se
            // obtiene por separado del snapshot vivo y su timestamp.
            return null;
          }
          final adjacentDurableUser = _messages
              .skip(anchorIndex + 1)
              .where(isRealUserTurn)
              .firstOrNull;
          if (adjacentDurableUser != null &&
              (adjacentDurableUser['content'] ?? '').toString() == content) {
            // Una fila adyacente por posición puede ser un turno histórico
            // homónimo que llegó tarde. El contenido nunca acredita identidad.
            return null;
          }
        }
        return (
          index: index,
          tombstone: CancelledTurnTombstone(
            content: content,
            anchorMessageId: anchorMessageId,
            anchorRowId: anchorRowId,
          ),
        );
      }
      final hasOlderRealUser = _messages.skip(index + 1).any(isRealUserTurn);
      if (!hasOlderRealUser &&
          (_transcriptIsComplete || _activeTurnStartedFromKnownMissing)) {
        return (
          index: index,
          tombstone: CancelledTurnTombstone(content: content, firstUser: true),
        );
      }
      return null;
    }
    return null;
  }

  bool _sameCancelledTurn(
    CancelledTurnTombstone left,
    CancelledTurnTombstone right,
  ) => _sameCancelledTurnIdentity(left, right);

  bool _cancelledTurnIdentityWasUpgraded(
    ({int index, CancelledTurnTombstone tombstone}) before,
    ({int index, CancelledTurnTombstone tombstone}) after,
  ) {
    if (!after.tombstone.hasTargetIdentity ||
        before.tombstone.content != after.tombstone.content) {
      return false;
    }
    final reboundIndex = _cancelledTurnUserIndex(
      _messages,
      before.tombstone,
      incomingTranscriptComplete: _transcriptIsComplete,
    );
    return reboundIndex >= 0 && reboundIndex == after.index;
  }

  void _commitCancelledTurnLocally(
    ({int index, CancelledTurnTombstone tombstone}) candidate,
  ) {
    final durable = candidate.tombstone;
    final existingIndex = _cancelledTurnTombstones.indexWhere(
      (item) => _sameCancelledTurn(item, durable),
    );
    if (existingIndex < 0) {
      _cancelledTurnTombstones.add(durable);
      _cancelledTombstoneRevision += 1;
    } else if (_cancelledTurnTombstones[existingIndex].invalidated) {
      _cancelledTurnTombstones[existingIndex] = durable;
      _cancelledTombstoneRevision += 1;
    }
    final message = Map<String, dynamic>.of(_messages[candidate.index])
      ..remove(_stopProofAnchorMessageIdKey)
      ..remove(_stopProofAnchorRowIdKey)
      ..addAll({
        '_cancelledUser': true,
        '_cancelledTurnAnchorMessageId': durable.anchorMessageId,
        '_cancelledTurnAnchorRowId': durable.anchorRowId,
        '_cancelledTurnFirstUser': durable.firstUser,
        '_cancelledTurnMessageId': durable.cancelledMessageId,
        '_cancelledTurnRowId': durable.cancelledRowId,
      });
    _messages[candidate.index] = message;
  }

  void _markLatestUserCancelledLocally() {
    for (var index = 0; index < _messages.length; index++) {
      final message = _messages[index];
      if (!isRealUserTurn(message)) continue;
      _messages[index] = {...message, '_cancelledUser': true};
      return;
    }
  }

  /// Conserva únicamente la identidad exacta del último user durable que ya
  /// era visible antes de iniciar el turno. No guarda contenido ni ordinales:
  /// una fila que aparece después del submit no puede convertirse por posición
  /// en el predecessor del inflight.
  void _captureActiveTurnTranscriptBoundary(
    int turnEpoch, {
    bool allowExistingTranscript = true,
  }) {
    _passiveTurnBoundaryFresh = false;
    _activeTurnTranscriptBoundaryEpoch = turnEpoch;
    _activeTurnStartedFromKnownMissing = false;
    _activeTurnTranscriptBoundaryIdentity = null;
    _activeTurnTranscriptBoundarySessionId = serverSessionId;
    _activeTurnTranscriptBoundaryProfile = _storedSessionProfile;
    if (!allowExistingTranscript) return;
    for (final message in _messages) {
      if (!isRealUserTurn(message)) continue;
      // El primer user visible ES la frontera. Si aún es una proyección local
      // no se puede atravesar para capturar como predecessor otro user más
      // antiguo: el tombstone caería sobre esta fila intermedia.
      if (_isLiveTranscriptProjection(message) ||
          message['_desktopAcceptedQueued'] == true) {
        return;
      }
      if (!transcriptIdentityAliasesAreConsistent(message)) return;
      final identity = _transcriptMessageIdentity(message);
      if (identity == null ||
          _uniqueTranscriptIdentityMatch(identity, _messages) == null) {
        return;
      }
      _activeTurnTranscriptBoundaryIdentity = identity;
      return;
    }
    _activeTurnStartedFromKnownMissing =
        _desktopStoredSessionKnownMissing && _messages.isEmpty;
  }

  bool _activeTurnBoundaryAlreadyProven(TranscriptMessageIdentity identity) {
    final baseline = _activeTurnTranscriptBoundaryIdentity;
    return _activeTurnTranscriptBoundaryScopeIsCurrent() &&
        baseline != null &&
        baseline.matches(identity);
  }

  bool _activeTurnTranscriptBoundaryScopeIsCurrent() =>
      _activeTurnTranscriptBoundaryEpoch == _turnEpoch &&
      _activeTurnTranscriptBoundarySessionId == serverSessionId &&
      _activeTurnTranscriptBoundaryProfile == _storedSessionProfile;

  /// Una identidad que no estaba visible antes del submit todavía puede ser
  /// un predecessor acreditado si una página completa la enlaza de forma
  /// única a un Stop anterior. Es el caso del firstUser que se vuelve durable
  /// entre la primera cancelación y el segundo turno.
  bool _completeTranscriptBindsPriorCancellationToBoundary(
    List<Map<String, dynamic>> incoming,
    TranscriptMessageIdentity boundaryIdentity, {
    required bool incomingTranscriptComplete,
  }) {
    if (!incomingTranscriptComplete) return false;
    for (final tombstone in _cancelledTurnTombstones) {
      if (tombstone.invalidated) continue;
      final index = _cancelledTurnUserIndex(
        incoming,
        tombstone,
        incomingTranscriptComplete: true,
      );
      if (index < 0) continue;
      final identity = _transcriptMessageIdentity(incoming[index]);
      if (identity != null &&
          identity.matches(boundaryIdentity) &&
          _uniqueTranscriptIdentityMatch(identity, incoming) != null) {
        return true;
      }
    }
    return false;
  }

  /// Hidrata la identidad exacta del prompt vivo sin inferirla por posición.
  ///
  /// El Gateway actual publica `turn_started_at` antes de ejecutar el turno;
  /// versiones experimentales usaron `inflight.started_at`. El resolver exige
  /// que ambos coincidan cuando coexisten y falla cerrado ante un conflicto.
  /// La fila durable del usuario se escribe después de esa frontera. Por tanto,
  /// una única fila user con ID y timestamp posterior es el target exacto; si
  /// la última fila user es anterior, su ID es un ancla exacta para el inflight
  /// que aún no se persistió. Toda la lectura queda vallada por el epoch de
  /// transcript y por el runtime exacto.
  Future<bool> _hydrateCurrentTurnCancellationIdentity() async {
    bool reject(String reason) {
      debugPrint('[active-chat] Stop identity rejected ($reason)');
      return false;
    }

    final expectedTurnEpoch = _turnEpoch;
    String expectedPrompt = '';
    for (final message in _messages) {
      if (!isRealUserTurn(message) || !_isLiveTranscriptProjection(message)) {
        continue;
      }
      expectedPrompt = (message['content'] ?? '').toString();
      if (expectedPrompt.isNotEmpty) break;
    }
    if (expectedPrompt.isEmpty) expectedPrompt = lastPrompt;
    final gateway = _desktopGateway;
    final expectedRuntimeId = _desktopRuntimeSessionId;
    if (!isStreaming ||
        !_usingDesktopGateway ||
        expectedPrompt.isEmpty ||
        expectedRuntimeId == null ||
        gateway is! HermesDesktopSessionLifecycleGateway) {
      return reject('precondition');
    }
    final lifecycle = gateway as HermesDesktopSessionLifecycleGateway;

    // Stop supersede cualquier refresh anterior. Una carga nueva que empiece
    // después incrementará el epoch y hará fallar esta prueba antes de mutar.
    final proofMessageLoadEpoch = ++_messageLoadEpoch;
    final expectedCoverageRevision = _transcriptCoverageRevision;
    final expectedSessionEpoch = _desktopSessionEpoch;
    final expectedBindEpoch = _desktopBindEpoch;
    final expectedStoredId = serverSessionId;
    final expectedProfile = _storedSessionProfile;

    bool proofStillCurrent() =>
        !_disposed &&
        isStreaming &&
        _usingDesktopGateway &&
        _turnEpoch == expectedTurnEpoch &&
        _messageLoadEpoch == proofMessageLoadEpoch &&
        _transcriptCoverageRevision == expectedCoverageRevision &&
        _desktopSessionEpoch == expectedSessionEpoch &&
        _desktopBindEpoch == expectedBindEpoch &&
        _desktopRuntimeSessionId == expectedRuntimeId &&
        serverSessionId == expectedStoredId &&
        _storedSessionProfile == expectedProfile;

    try {
      final snapshot = await lifecycle.resumeExisting(
        expectedStoredId,
        profile: expectedProfile,
        omitMessages: true,
      );
      if (!proofStillCurrent() ||
          snapshot.runtimeSessionId != expectedRuntimeId ||
          snapshot.storedSessionId != expectedStoredId ||
          !snapshot.running) {
        return reject('snapshot-fence');
      }
      final inflight = snapshot.inflight;
      final startedAt = snapshot.resolvedTurnStartedAt;
      final inflightUser = inflight?.user;
      if (startedAt == null || inflightUser != expectedPrompt) {
        return reject('inflight-proof');
      }

      final page = await _requestStoredMessagesPage(
        storedSessionId: expectedStoredId,
        profile: expectedProfile,
      );
      if (!proofStillCurrent() ||
          page.offset != 0 ||
          !page.messagesFullyParsed ||
          !page.paginationFullyParsed) {
        return reject('transcript-page');
      }
      final pageProvesComplete = _tailPageProvesTranscriptComplete(page);
      final incoming = _normalizedNewestFirst(page.messages);
      Map<String, dynamic>? durableBoundary;
      for (final message in incoming) {
        if (isRealUserTurn(message)) {
          durableBoundary = message;
          break;
        }
      }
      if (durableBoundary == null ||
          !transcriptIdentityAliasesAreConsistent(durableBoundary)) {
        return reject('durable-boundary');
      }
      final durableIdentity = _transcriptMessageIdentity(durableBoundary);
      final durableTimestamp = _transcriptTimestamp(durableBoundary);
      if (durableIdentity == null ||
          _uniqueTranscriptIdentityMatch(durableIdentity, incoming) == null ||
          durableTimestamp == null ||
          durableTimestamp.isAtSameMomentAs(startedAt)) {
        return reject('durable-identity');
      }
      final boundaryIsCurrent = durableTimestamp.isAfter(startedAt);
      if (boundaryIsCurrent &&
          (durableBoundary['content'] ?? '').toString() != inflightUser) {
        return reject('current-content');
      }
      if (!boundaryIsCurrent &&
          !_activeTurnBoundaryAlreadyProven(durableIdentity) &&
          !_completeTranscriptBindsPriorCancellationToBoundary(
            incoming,
            durableIdentity,
            incomingTranscriptComplete: pageProvesComplete,
          )) {
        // Una fila homónima que apareció tras submit también puede ser el
        // target actual con timestamp atrasado. Sin procedencia pre-turno o
        // un tombstone previo enlazado, tratarla como ancla podría ocultar el
        // siguiente turno legítimo.
        return reject('historical-boundary');
      }

      // Un segundo user iniciado bajo la misma frontera indicaría que la
      // página y el inflight no describen una única extensión del transcript.
      for (final message
          in incoming
              .skipWhile((message) => !identical(message, durableBoundary))
              .skip(1)) {
        if (!isRealUserTurn(message)) continue;
        final timestamp = _transcriptTimestamp(message);
        if (timestamp != null && !timestamp.isBefore(startedAt)) {
          return reject('multiple-current-users');
        }
      }

      final localIndex = _messages.indexWhere(
        (message) =>
            isRealUserTurn(message) &&
            _isLiveTranscriptProjection(message) &&
            (message['content'] ?? '').toString() == expectedPrompt,
      );
      if (localIndex < 0) return reject('local-projection');
      if (!proofStillCurrent()) return reject('commit-fence');
      _messages[localIndex] = {
        ..._messages[localIndex],
        if (boundaryIsCurrent && durableIdentity.messageId != null)
          '_desktopMessageId': durableIdentity.messageId,
        if (boundaryIsCurrent && durableIdentity.rowId != null)
          '_desktopRowId': durableIdentity.rowId,
        if (!boundaryIsCurrent && durableIdentity.messageId != null)
          _stopProofAnchorMessageIdKey: durableIdentity.messageId,
        if (!boundaryIsCurrent && durableIdentity.rowId != null)
          _stopProofAnchorRowIdKey: durableIdentity.rowId,
      };
      // La misma lectura puede completar de forma autoritativa la identidad
      // de Stops anteriores (por ejemplo, el firstUser del primer turno). No
      // basta con encontrar el ancla del turno vivo: si dejamos aquel
      // tombstone ambiguo, un segundo Stop queda pendiente entre dos
      // escrituras y la siguiente continuación puede bloquearse. Solo se
      // enlaza cuando offset=0 y la página demuestra cobertura completa; una
      // cola paginada sigue fallando cerrado.
      _bindTombstonesToDurableIds(
        incoming,
        incomingTranscriptComplete: pageProvesComplete,
      );
      return true;
    } catch (error) {
      debugPrint(
        '[active-chat] Stop identity hydration unavailable '
        '(${error.runtimeType})',
      );
      return false;
    }
  }

  Future<void> _persistLatestUserCancellation() async {
    var before = _latestUserCancellationCandidate();
    final persist = _onCancelledTurn;
    if (before == null && persist != null) {
      if (await _hydrateCurrentTurnCancellationIdentity()) {
        before = _latestUserCancellationCandidate();
      }
    }
    if (before == null) {
      if (persist != null) {
        throw StateError('cancelled turn has no durable transcript anchor');
      }
      _markLatestUserCancelledLocally();
      return;
    }
    if (persist != null) {
      _cancelledTurnPersistencePending = true;
      _cancelledTurnPersistenceFailed = false;
      try {
        await persist(before.tombstone);
        _cancelledTurnPersistencePending = false;
        _cancelledTurnPersistenceFailed = false;
      } catch (_) {
        _cancelledTurnPersistencePending = false;
        _cancelledTurnPersistenceFailed = true;
        throw StateError('cancelled turn persistence failed');
      }
    } else {
      _cancelledTurnPersistencePending = false;
      _cancelledTurnPersistenceFailed = false;
    }
    final after = _latestUserCancellationCandidate();
    if (after == null) {
      throw StateError('cancelled turn changed while persisting tombstone');
    }
    if (_sameCancelledTurn(before.tombstone, after.tombstone)) {
      _commitCancelledTurnLocally(after);
      return;
    }
    if (!_cancelledTurnIdentityWasUpgraded(before, after)) {
      throw StateError('cancelled turn changed while persisting tombstone');
    }
    // El tombstone anclado ya está confirmado. Conserva esa autoridad y deja
    // que el mismo reconciliador que usa refresh lo enriquezca con los IDs
    // exactos recién hidratados, sin equiparar mensajes por contenido.
    _commitCancelledTurnLocally((
      index: after.index,
      tombstone: before.tombstone,
    ));
    _bindTombstonesToDurableIds(
      _messages,
      incomingTranscriptComplete: _transcriptIsComplete,
    );
  }

  void _persistLatestUserCancellationInBackground() {
    final persistence = _persistLatestUserCancellation().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _cancelledTurnPersistencePending = false;
      _cancelledTurnPersistenceFailed = true;
      debugPrint(
        '[active-chat] Stop persistence unavailable (${error.runtimeType})',
      );
    });
    _cancelledTurnPersistence = persistence;
    unawaited(persistence);
  }

  /// El run fue cancelado por el servidor (no por el usuario).
  void _cancelRunState() {
    if (_runTerminal) {
      if (_clearFailedStopConfirmation()) {
        _emit(ActiveChatEvent.queueChanged);
      }
      return;
    }
    if (_hasPendingActiveTurnCancellation) return;
    if (_hasPendingTombstoneMetadataUpdate) {
      final expectedTurnEpoch = _turnEpoch;
      unawaited(
        _deferCancelRunUntilTombstoneMetadataSettles(expectedTurnEpoch),
      );
      return;
    }
    _clearDesktopCompactingIndicator();
    _messageLoadEpoch += 1;
    _runTerminal = true;
    _desktopTurnStartedAt = null;
    _turnSubmittedAtMs = null;
    _activityWatchdogTimer?.cancel();
    _activityWatchdogTimer = null;
    _setNoActivityHint(false);
    _flushTokenBuffer();
    if (pendingApproval != null) {
      _cancelApprovalNotification(pendingApproval!, terminal: true);
    }
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    final hasPartial =
        _messages.isNotEmpty &&
        _messages[0]['role'] == 'assistant' &&
        ((_messages[0]['content'] as String?) ?? '').isNotEmpty;
    state = ChatPipelineState.cancelled;
    _finalizeAcceptedTurnDelivery();
    traceActive = false;
    _cancelling = false;
    if (!hasPartial &&
        _messages.isNotEmpty &&
        _messages[0]['role'] == 'assistant') {
      _messages.removeAt(0);
    } else if (hasPartial &&
        _messages.isNotEmpty &&
        _messages[0]['role'] == 'assistant') {
      _messages[0] = {..._messages[0], '_cancelled': true, '_pipeline': false};
    }
    // Marca también el mensaje de usuario para que el historial lo conserve con
    // la instrucción de no reanudarlo automáticamente. Usa una clave propia:
    // `_cancelled` pintaría la burbuja como cancelada y no queremos eso aquí.
    _markLatestUserCancelledLocally();
    _emit(ActiveChatEvent.cancelled);
    _drainOrTerminal(expectedEpoch: _turnEpoch);
  }

  Future<void> _deferCancelRunUntilTombstoneMetadataSettles(
    int expectedTurnEpoch,
  ) async {
    if (!await _settleTombstoneMetadataBeforeTerminal(expectedTurnEpoch)) {
      return;
    }
    _cancelRunState();
  }

  /// Cancela el run en curso; el tombstone durable se persiste en segundo plano.
  Future<void> cancel() {
    final existing = _durableCancelFlight;
    if (existing != null) return existing;
    _freezeQueueForStop();
    // Only visible background activity may preserve the completed transcript.
    final backgroundOnlyStop =
        !isStreaming && !remoteSurfaceOwnsLiveTurn && canStopSessionWork;
    final affectsLiveTurn = !backgroundOnlyStop;
    final coordinator = _StopTransitionCoordinator(
      turnEpoch: _turnEpoch,
      runtimeId: _desktopRuntimeSessionId,
      gateway: _desktopGateway,
      queueGeneration: _queueGeneration,
      deadlineMs: _wallClockMs() + _stopEscalationBudget.inMilliseconds,
      affectsLiveTurn: affectsLiveTurn,
    );
    _lastStopAffectedLiveTurn = affectsLiveTurn;
    _stopTransition = coordinator;
    if (affectsLiveTurn) state = ChatPipelineState.cancelled;
    late final Future<void> operation;
    Future<void> runOwnedCancel() async {
      try {
        await _cancelDurably(coordinator);
      } finally {
        if (identical(_durableCancelFlight, operation)) {
          _durableCancelFlight = null;
          final completionWon =
              _pendingAuthoritativeTerminalEpoch == _turnEpoch &&
              _pendingAuthoritativeTerminalOutput != null &&
              !_runTerminal;
          if (completionWon) {
            unawaited(
              _completeRun(finalOutput: _pendingAuthoritativeTerminalOutput),
            );
          }
          if (releaseRequested && !isStreaming && !hasListeners) {
            _onUnused?.call();
          }
        }
      }
    }

    operation = runOwnedCancel();
    // The caller and state owner observe the same future. A second detached
    // error branch would report durable failures twice to the async zone.
    _durableCancelFlight = operation;
    return operation;
  }

  /// Desengancha un coordinador de Stop que ya alcanzó estado terminal.
  ///
  /// Un coordinador final no gobierna nada: dejarlo en `_stopTransition` es lo
  /// que convertía el park en permanente y bloqueaba `canReleaseToDesktop` de
  /// por vida. Se conserva su epoch para que la recuperación de *ese* turno
  /// siga cerrada, que es lo único que el campo aportaba a `_canRecoverTurn`.
  void _settleStopTransition(
    _StopTransitionCoordinator stop,
    _StopTransitionState terminalState, {
    required StopConfirmationState confirmation,
    bool emitQueueChanged = true,
  }) {
    stop.state = terminalState;
    _stopConfirmationState = confirmation;
    if (!stop.terminal.isCompleted) stop.terminal.complete();
    if (identical(_stopTransition, stop)) {
      _finalizedStopTurnEpoch = stop.turnEpoch;
      _stopTransition = null;
    }
    if (emitQueueChanged && !_disposed) _emit(ActiveChatEvent.queueChanged);
    _unparkQueueLeaseIfEmpty();
  }

  bool _stopIsCurrent(_StopTransitionCoordinator stop) =>
      !_disposed &&
      identical(_stopTransition, stop) &&
      stop.turnEpoch == _turnEpoch &&
      stop.queueGeneration == _queueGeneration &&
      identical(stop.gateway, _desktopGateway);

  bool _transientStopFailure(Object error) {
    if (error is TimeoutException || error is WebSocketChannelException) {
      return true;
    }
    if (error is DashboardHttpException) {
      return error.statusCode == 408 ||
          error.statusCode == 429 ||
          error.statusCode >= 500;
    }
    return error is TuiGatewayRpcError &&
        const {4001, 4009, 5032}.contains(error.code);
  }

  Duration _remainingStopBudget(_StopTransitionCoordinator stop) => Duration(
    milliseconds: math.max(0, stop.deadlineMs - _wallClockMs()),
  );

  Future<T?> _stopOperationBeforeDeadline<T>(
    _StopTransitionCoordinator stop,
    Future<T> operation,
  ) async {
    final remaining = _remainingStopBudget(stop);
    if (remaining <= Duration.zero) {
      throw TimeoutException('Stop escalation budget exhausted');
    }
    final timeout = remaining < _desktopRecoveryAttemptTimeout
        ? remaining
        : _desktopRecoveryAttemptTimeout;
    final deadline = Completer<T?>();
    final timer = Timer(timeout, () {
      deadline.completeError(TimeoutException('Stop operation timed out', timeout));
    });
    try {
      return await Future.any<T?>([
        operation,
        deadline.future,
        _disposeSignal.future.then((_) => null),
      ]);
    } finally {
      timer.cancel();
    }
  }

  Future<bool> _waitForStopRetry(
    _StopTransitionCoordinator stop,
    Duration delay,
  ) {
    final remaining = _remainingStopBudget(stop);
    if (remaining <= Duration.zero) return Future<bool>.value(false);
    final boundedDelay = delay < remaining ? delay : remaining;
    return _waitForTerminalReconcileDelay(
      boundedDelay,
      _disposeSignal.future,
    ).then((elapsed) => elapsed && _remainingStopBudget(stop) > Duration.zero);
  }

  Duration get _stopSettleTimeout =>
      _desktopRecoveryAttemptTimeout < const Duration(seconds: 2)
      ? _desktopRecoveryAttemptTimeout
      : const Duration(seconds: 2);

  Future<bool> _interruptAndSettleStop(
    _StopTransitionCoordinator stop,
    String runtimeId,
  ) async {
    final gateway = stop.gateway!;
    while (_stopIsCurrent(stop) &&
        stop.interruptAttempts < _stopInterruptAttemptLimit &&
        _remainingStopBudget(stop) > Duration.zero) {
      stop.state = _StopTransitionState.interrupting;
      stop.interruptAttempts += 1;
      try {
        await _stopOperationBeforeDeadline(
          stop,
          gateway.interrupt(runtimeId).then((_) => true),
        );
        stop.lastInterruptError = null;
      } catch (error) {
        stop.lastInterruptError = error;
        if (error is TuiGatewayRpcError && error.code == 4007) return true;
        if (error is TuiGatewayRpcError &&
            error.code == 5032 &&
            !stop.agentStartingRetryUsed &&
            stop.interruptAttempts < _stopInterruptAttemptLimit) {
          stop.agentStartingRetryUsed = true;
          continue;
        }
        if (!_transientStopFailure(error)) rethrow;
        return false;
      }
      if (!_stopIsCurrent(stop)) return true;
      stop.state = _StopTransitionState.settling;
      final remaining = _remainingStopBudget(stop);
      if (remaining <= Duration.zero) return false;
      final fullGrace = _stopSettleTimeout;
      final grace = remaining < fullGrace ? remaining : fullGrace;
      final timeout = Completer<bool>();
      final settleTimer = Timer(grace, () => timeout.complete(false));
      late final bool settled;
      try {
        settled = await Future.any<bool>([
          stop.terminal.future.then((_) => true),
          timeout.future,
          _disposeSignal.future.then((_) => false),
        ]);
      } finally {
        settleTimer.cancel();
      }
      return settled ||
          (grace == fullGrace &&
              _stopIsCurrent(stop) &&
              _remainingStopBudget(stop) > Duration.zero);
    }
    return false;
  }

  Future<bool> _recoverAndInterruptStop(
    _StopTransitionCoordinator stop,
    String storedSessionId,
    String profile,
    String model,
  ) async {
    final gateway = stop.gateway!;
    if (gateway is! HermesDesktopSessionLifecycleGateway &&
        gateway is! HermesDesktopRecoverySessionLifecycleGateway) {
      return false;
    }
    for (var recoveryAttempt = 0; recoveryAttempt < 16; recoveryAttempt++) {
      if (!_stopIsCurrent(stop) ||
          stop.interruptAttempts >= _stopInterruptAttemptLimit ||
          _remainingStopBudget(stop) <= Duration.zero) {
        return false;
      }
      final previousError = stop.lastInterruptError;
      if (previousError is TuiGatewayRpcError) {
        if (previousError.code == 5032) return false;
        if (previousError.code == 4001) {
          if (stop.sessionNotFoundRecoveryUsed) return false;
          stop.sessionNotFoundRecoveryUsed = true;
        } else if (previousError.code == 4009 &&
            !await _waitForStopRetry(stop, _stopSettlingPollInterval)) {
          return false;
        }
      }
      stop.state = _StopTransitionState.recovering;
      try {
        final connected = await _stopOperationBeforeDeadline(
          stop,
          gateway.connect().then((_) => true),
        );
        if (connected == null || !_stopIsCurrent(stop)) return false;
        final snapshot = await _stopOperationBeforeDeadline(
          stop,
          _resumeDesktopSessionForRecovery(
            gateway,
            storedSessionId,
            profile: profile,
            legacyModel: model,
            deferRuntimeCommit: true,
          ),
        );
        if (snapshot == null || !_stopIsCurrent(stop)) return false;
        if (!_commitDesktopRecoverySnapshot(gateway, snapshot)) return false;
        _desktopStoredSessionId = snapshot.storedSessionId;
        _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
        _usingDesktopGateway = true;
        if (await _interruptAndSettleStop(stop, snapshot.runtimeSessionId)) {
          return true;
        }
      } catch (error) {
        if (!_stopIsCurrent(stop)) return false;
        if (error is TuiGatewayRpcError && error.code == 4007) return true;
        stop.lastInterruptError = error;
        if (error is TuiGatewayRpcError && error.code == 4009) {
          continue;
        }
        if (!_transientStopFailure(error)) rethrow;
        return false;
      }
    }
    return false;
  }

  void _finalizeStopLocally(
    _StopTransitionCoordinator stop,
    _StopTransitionState terminalState,
    StopConfirmationState confirmation, {
    required bool requestServerStop,
  }) {
    if (stop.affectsLiveTurn) {
      _cancelCurrent(
        requestServerStop: requestServerStop,
        deferConfirmation: true,
        markUserCancelled: false,
        stopped: terminalState == _StopTransitionState.confirmed,
        clearQueue: false,
      );
      _persistLatestUserCancellationInBackground();
    } else {
      _clearQueue();
    }
    _settleStopTransition(
      stop,
      terminalState,
      confirmation: confirmation,
      emitQueueChanged: false,
    );
    if (_backgroundProcesses.isEmpty) _requestPostControlRepair();
    if (!stop.affectsLiveTurn) {
      _emit(ActiveChatEvent.queueChanged);
      return;
    }
    final terminalEpoch = _turnEpoch;
    _emit(ActiveChatEvent.cancelled);
    _drainOrTerminal(expectedEpoch: terminalEpoch);
  }

  Future<void> _cancelDurably(_StopTransitionCoordinator stop) async {
    final cancelEpoch = stop.turnEpoch;
    final cancelRuntimeId = stop.runtimeId;
    final cancelGateway = stop.gateway;
    final usesExactDesktopRuntime =
        cancelRuntimeId != null && cancelGateway != null;
    final hasDesktopStopTarget =
        cancelGateway != null &&
        ((stop.affectsLiveTurn && _usingDesktopGateway) ||
            _activeTurnDelivery?.current.transport ==
                PreparedTurnTransport.desktop ||
            _recoveringDesktopTurnEpoch == cancelEpoch);
    final retriesFailedStop =
        _stopConfirmationState == StopConfirmationState.failed;
    _stopConfirmationState = retriesFailedStop
        ? StopConfirmationState.retrying
        : StopConfirmationState.stopping;
    _emit(ActiveChatEvent.queueChanged);
    bool scopeIsCurrent() => _stopIsCurrent(stop);
    if (!scopeIsCurrent()) {
      _settleStopTransition(
        stop,
        _StopTransitionState.superseded,
        confirmation: StopConfirmationState.idle,
        emitQueueChanged: false,
      );
      return;
    }

    if (hasDesktopStopTarget) {
      try {
        var delivered = usesExactDesktopRuntime
            ? await _interruptAndSettleStop(stop, cancelRuntimeId)
            : false;
        if (!delivered && scopeIsCurrent()) {
          delivered = await _recoverAndInterruptStop(
            stop,
            _desktopStoredSessionId ?? serverSessionId,
            _turnProfile,
            _lastModel,
          );
        }
        if (!delivered && scopeIsCurrent()) {
          _finalizeStopLocally(
            stop,
            _StopTransitionState.failed,
            StopConfirmationState.failed,
            requestServerStop: false,
          );
          return;
        }
      } catch (error) {
        if (scopeIsCurrent()) {
          _finalizeStopLocally(
            stop,
            _StopTransitionState.failed,
            StopConfirmationState.failed,
            requestServerStop: false,
          );
          rethrow;
        }
        _settleStopTransition(
          stop,
          _StopTransitionState.superseded,
          confirmation: StopConfirmationState.idle,
          emitQueueChanged: false,
        );
        return;
      }
      if (!scopeIsCurrent()) {
        // El ACK llegó, pero este coordinador ya no es el vigente. Marcarlo
        // terminal es obligatorio: un coordinador abandonado en `settling` con
        // su `terminal` sin completar deja colgado a cualquiera que lo espere.
        _settleStopTransition(
          stop,
          _StopTransitionState.superseded,
          confirmation: StopConfirmationState.idle,
          emitQueueChanged: false,
        );
        return;
      }
      // El terminal autoritativo puede ganar mientras session.interrupt espera.
      // `_completeRun` conserva su salida antes de esperar este mismo Stop; soltar
      // aquí el flight evita convertir esa carrera válida en cancelación local.
      if (_pendingAuthoritativeTerminalEpoch == cancelEpoch) {
        _settleStopTransition(
          stop,
          _StopTransitionState.superseded,
          confirmation: StopConfirmationState.idle,
        );
        return;
      }
    }
    _finalizeStopLocally(
      stop,
      _StopTransitionState.confirmed,
      StopConfirmationState.confirmed,
      requestServerStop: !hasDesktopStopTarget,
    );
  }

  void _beginVoiceBargeHandoff() {
    _voiceBargeHandoffPending = true;
    _voiceBargeHandoffTimer?.cancel();
    _voiceBargeHandoffTimer = Timer(_voiceBargeHandoffRetention, () {
      _voiceBargeHandoffTimer = null;
      if (!_voiceBargeHandoffPending || _disposed) return;
      _voiceBargeHandoffPending = false;
      if (!isStreaming) _onTerminal();
    });
  }

  void _finishVoiceBargeHandoff({required bool notifyTerminal}) {
    if (!_voiceBargeHandoffPending && _voiceBargeHandoffTimer == null) return;
    _voiceBargeHandoffPending = false;
    _voiceBargeHandoffTimer?.cancel();
    _voiceBargeHandoffTimer = null;
    if (notifyTerminal && !_disposed && !isStreaming) _onTerminal();
  }

  /// Interrumpe un turno porque el usuario empezó a hablar sobre la respuesta.
  ///
  /// Replica el orden de Hermes Desktop: corta el turno en cuanto el VAD
  /// confirma voz, espera brevemente su terminal y deja que la transcripción se
  /// envíe después como un turno nuevo marcado `interrupted`. Así una STT lenta
  /// no permite que la respuesta vieja termine y haga parecer que se perdió el
  /// contexto de la corrección.
  Future<void> interruptForVoiceBarge({
    Duration settleTimeout = activeChatVoiceBargeSettleTimeout,
  }) async {
    if (!isStreaming) return;
    final settleDeadline = DateTime.now().add(settleTimeout);
    Duration remainingSettle() => settleDeadline.difference(DateTime.now());
    _beginVoiceBargeHandoff();
    final runtimeId = _desktopRuntimeSessionId;
    final desktop = _desktopGateway;
    final runId = currentRunId;

    if (_usingDesktopGateway && runtimeId != null && desktop != null) {
      final durableId = _desktopStoredSessionId ?? serverSessionId;
      final ownerProfile = _storedSessionProfile;
      final interruptDrain = Completer<void>();
      _desktopInterruptDrain = interruptDrain;
      _discardLateInterruptTerminal = true;
      _cancelCurrent(requestServerStop: false);
      final interruptEpoch = _turnEpoch;

      Future<void> interruptOnce(String targetRuntimeId) async {
        final remaining = remainingSettle();
        if (remaining <= Duration.zero) {
          throw TimeoutException('Voice barge-in settle deadline elapsed');
        }
        await desktop.interrupt(targetRuntimeId).timeout(remaining);
      }

      try {
        try {
          await interruptOnce(runtimeId);
        } on TuiGatewayRpcError catch (error) {
          if (error.code != 4001 ||
              desktop is! HermesDesktopSessionLifecycleGateway) {
            rethrow;
          }
          final lifecycleDesktop =
              desktop as HermesDesktopSessionLifecycleGateway;

          // Desktop solo reata un runtime obsoleto ante el 4001 oficial. El
          // stored id y el perfil quedan fijados antes del primer interrupt;
          // si otro turno cambia el binding durante el resume, no se adopta ni
          // se envía el retry a ese destino nuevo.
          var remaining = remainingSettle();
          if (remaining <= Duration.zero) {
            throw TimeoutException('Voice barge-in settle deadline elapsed');
          }
          final snapshot = await lifecycleDesktop
              .resumeExisting(
                durableId,
                profile: ownerProfile,
                omitMessages: true,
              )
              .timeout(remaining);
          final currentDurableId = _desktopStoredSessionId ?? serverSessionId;
          if (_disposed ||
              !identical(_desktopGateway, desktop) ||
              !_usingDesktopGateway ||
              _turnEpoch != interruptEpoch ||
              _desktopRuntimeSessionId != runtimeId ||
              _storedSessionProfile != ownerProfile ||
              currentDurableId != durableId) {
            throw StateError('voice_barge_interrupt_target_changed');
          }
          _desktopStoredSessionId = snapshot.storedSessionId;
          _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
          _desktopStoredSessionKnownMissing = false;
          await interruptOnce(snapshot.runtimeSessionId);
        }

        final remaining = remainingSettle();
        if (remaining > Duration.zero) {
          await interruptDrain.future.timeout(remaining);
        }
      } on TimeoutException {
        // Gateways antiguos pueden confirmar el RPC sin publicar un terminal.
        // El guard existente descartará ese terminal si llega más tarde.
      } catch (_) {
        // `prompt.submit` conserva su propio busy gate en el servidor. El
        // siguiente envío mostrará el error real si el turno no se asentó.
      } finally {
        if (identical(_desktopInterruptDrain, interruptDrain)) {
          _desktopInterruptDrain = null;
        }
      }
      return;
    }

    _cancelCurrent(requestServerStop: false);
    if (runId != null) {
      try {
        var remaining = remainingSettle();
        if (remaining <= Duration.zero) return;
        final stopped = await _api
            .stopRun(runId, profile: sessionProfile)
            .timeout(remaining);
        remaining = remainingSettle();
        if (!activeChatVoiceBargeRunIsTerminal(stopped) &&
            remaining > Duration.zero) {
          await waitForActiveChatVoiceBargeTerminal(
            readStatus: () => _api.getRun(runId, profile: sessionProfile),
            timeout: remaining,
          );
        }
      } catch (_) {
        // Compatibilidad REST best-effort; el turno siguiente sigue llevando
        // el historial local con la marca de interrupción.
      }
    }
  }

  void _cancelCurrent({
    required bool requestServerStop,
    bool deferConfirmation = false,
    bool markUserCancelled = true,
    bool stopped = false,
    bool clearQueue = true,
  }) {
    if (_cancelling) return;
    _cancelling = true;
    _clearDesktopCompactingIndicator();
    // Invalida todos los callbacks del transporte que se está abandonando.
    _advanceTurnEpoch();
    _messageLoadEpoch += 1;
    _turnSubmittedAtMs = null;
    _activityWatchdogTimer?.cancel();
    _activityWatchdogTimer = null;
    _setNoActivityHint(false);
    _flushTokenBuffer();
    // Pide al servidor detener el run; el SSE cerrará (o emitirá run.cancelled),
    // pero ya marcamos terminal para no procesarlo dos veces.
    final runId = currentRunId;
    final cancelProfile = _turnProfile;
    if (requestServerStop && runId != null) {
      _api
          .stopRun(runId, profile: cancelProfile)
          .catchError((_) => <String, dynamic>{});
    }
    // Stop significa detener el trabajo completo solicitado desde el composer,
    // no solo el run que está delante. Ningún seguimiento pendiente debe
    // arrancar después de una cancelación explícita del usuario.
    if (clearQueue) _clearQueue();
    _runTerminal = true;
    _desktopTurnStartedAt = null;
    pendingApproval = null;
    _expireInteractivePromptsForRuntime(_desktopRuntimeSessionId);
    final hasPartial =
        _messages.isNotEmpty &&
        _messages[0]['role'] == 'assistant' &&
        ((_messages[0]['content'] as String?) ?? '').isNotEmpty;
    state = ChatPipelineState.cancelled;
    _finalizeAcceptedTurnDelivery();
    traceActive = false;
    _cancelling = false;

    if (!hasPartial &&
        _messages.isNotEmpty &&
        _messages[0]['role'] == 'assistant') {
      _messages.removeAt(0);
    } else if (hasPartial &&
        _messages.isNotEmpty &&
        _messages[0]['role'] == 'assistant') {
      _messages[0] = {
        ..._messages[0],
        '_cancelled': true,
        if (stopped) '_stopped': true,
        '_pipeline': false,
      };
    }
    // Stop conserva el tema como memoria, pero buildHistory lo etiqueta para que
    // ni voz ni texto lo retomen salvo referencia explícita. Steering no pasa
    // por aquí: mantiene este mismo run vivo.
    if (markUserCancelled) _markLatestUserCancelledLocally();
    if (!deferConfirmation) {
      _emit(ActiveChatEvent.cancelled);
      _drainOrTerminal(expectedEpoch: _turnEpoch);
    }
  }

  /// Corrige el turno vivo mediante `session.redirect`, igual que Hermes
  /// Desktop. No llama a `/stop`, no abre otro run y conserva herramientas,
  /// estado y trabajo ya completado. Gateways antiguos degradan a
  /// `session.steer` únicamente cuando no publican el RPC moderno.
  Future<DesktopRedirectDisposition> steer(
    String fullText, {
    bool mentionsFrozen = false,
  }) async {
    if (!mentionsFrozen) {
      fullText = appendBotMentionNote(
        fullText,
        buildBotMentionAnnotation(mentionResolver.resolve(fullText)),
      );
    }
    if (mutationsBlockedByOwnershipConflict) {
      throw _ownershipConflictError('session.redirect');
    }
    if (desktopCompressionInFlight) {
      throw const TuiGatewayRpcError(
        'session.redirect',
        'Session compression is still running',
        code: 4009,
      );
    }
    if (connection.kind == InstanceKind.localhost) {
      throw StateError('steer_not_available_for_local_bridge');
    }
    if (!isStreaming) throw StateError('run_not_active');

    final steerEpoch = _turnEpoch;
    final recovery = _recoveringDesktopTurnEpoch == steerEpoch
        ? _desktopTurnRecovery
        : null;
    if (recovery != null) {
      await recovery;
      if (_turnEpoch != steerEpoch || !isStreaming) {
        throw StateError('run_not_active');
      }
    }

    var runtimeId = _desktopRuntimeSessionId;
    for (
      var attempt = 0;
      attempt < 100 && runtimeId == null && currentRunId == null && isStreaming;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      runtimeId = _desktopRuntimeSessionId;
    }
    final desktop = _desktopGateway;
    if (!_usingDesktopGateway || desktop == null) {
      throw StateError('steer_desktop_gateway_unavailable');
    }
    if (runtimeId == null || !isStreaming) throw StateError('run_not_ready');

    Future<({DesktopRedirectDisposition disposition, bool usedLegacySteer})>
    redirectOnce(String targetRuntimeId) async {
      final anchorUserOrdinal = _messages.where(isRealUserTurn).length - 1;
      final optimisticMessage = <String, dynamic>{
        'role': 'user',
        'content': fullText,
        '_steer': true,
      };

      // Desktop inserta la corrección antes del await: session.redirect puede
      // completar el run y publicar su terminal antes de responder al RPC. Si
      // esperásemos al ACK, la fila acabaría debajo de una respuesta a la que
      // ya afectó o desaparecería durante la reconciliación.
      final insertAt =
          _messages.isNotEmpty && _messages.first['role'] == 'assistant'
          ? 1
          : 0;
      _messages.insert(insertAt, optimisticMessage);
      _emit(ActiveChatEvent.waiting);

      void rollbackOptimisticMessage() {
        _messages.removeWhere(
          (message) => identical(message, optimisticMessage),
        );
      }

      try {
        var disposition = DesktopRedirectDisposition.redirected;
        var usedLegacySteer = false;
        if (desktop case final HermesDesktopRedirectGateway redirectGateway) {
          try {
            disposition = await redirectGateway.redirect(
              targetRuntimeId,
              fullText,
            );
          } on TuiGatewayRpcError catch (error) {
            // Un timeout o error de transporte es ambiguo: reintentar podría
            // duplicar una corrección que el servidor sí alcanzó a aceptar.
            if (error.code != -32601) rethrow;
            await desktop.steer(targetRuntimeId, fullText);
            usedLegacySteer = true;
          }
        } else {
          await desktop.steer(targetRuntimeId, fullText);
          usedLegacySteer = true;
        }

        if (disposition == DesktopRedirectDisposition.rejected) {
          rollbackOptimisticMessage();
          return (disposition: disposition, usedLegacySteer: usedLegacySteer);
        }

        if (disposition == DesktopRedirectDisposition.queued) {
          // El Gateway ya aceptó este texto como siguiente turno. Conservamos
          // la misma fila que se mostró antes del ACK; el terminal del reply
          // vivo la mueve a su posición definitiva sin reconstruirla.
          optimisticMessage
            ..remove('_steer')
            ..['_desktopAcceptedQueued'] = true;
          _appendDesktopAcceptedQueue(fullText);
          return (disposition: disposition, usedLegacySteer: usedLegacySteer);
        }

        _steerRecords.add((
          anchorUserOrdinal: anchorUserOrdinal,
          content: fullText,
        ));
        return (disposition: disposition, usedLegacySteer: usedLegacySteer);
      } catch (_) {
        rollbackOptimisticMessage();
        rethrow;
      }
    }

    late ({DesktopRedirectDisposition disposition, bool usedLegacySteer})
    result;
    try {
      result = await redirectOnce(runtimeId);
    } on TuiGatewayRpcError catch (error) {
      if (error.code != 4001 ||
          desktop is! HermesDesktopSessionLifecycleGateway) {
        rethrow;
      }

      // Igual que Desktop: un runtime obsoleto se reata al stored id con su
      // perfil propietario y session.redirect se reintenta exactamente una
      // vez. No se crea una sesión y no se reintentan timeouts ambiguos.
      final durableId = _desktopStoredSessionId ?? serverSessionId;
      final snapshot = await (desktop as HermesDesktopSessionLifecycleGateway)
          .resumeExisting(
            durableId,
            profile: _storedSessionProfile,
            omitMessages: true,
          );
      if (_disposed || !isStreaming) throw StateError('run_not_active');
      _desktopStoredSessionId = snapshot.storedSessionId;
      _adoptDesktopRuntime(snapshot.runtimeSessionId, info: snapshot.info);
      _desktopStoredSessionKnownMissing = false;
      result = await redirectOnce(snapshot.runtimeSessionId);
    }

    if (result.disposition == DesktopRedirectDisposition.queued) {
      debugPrint('[active-chat] live correction disposition=queued');
      return result.disposition;
    }
    if (result.disposition == DesktopRedirectDisposition.rejected) {
      debugPrint('[active-chat] live correction disposition=rejected');
      return result.disposition;
    }

    debugPrint(
      '[active-chat] live correction disposition='
      '${result.usedLegacySteer ? 'legacy_steer' : 'redirected'}',
    );
    debugPrint('[active-chat] live correction accepted');
    return result.disposition;
  }

  /// Reconciliación durable al volver de 2º plano o recibir una invalidación
  /// `sessions.changed`. Incluso un tail assistant ya final puede haber quedado
  /// obsoleto por un turno creado en Desktop. Las llamadas concurrentes
  /// comparten una única lectura; un stream vivo conserva siempre la autoridad.
  Future<bool> reconcileAfterResume() {
    requestImmediateTransportRecovery();
    if (_runtimeReleaseInFlight) return Future<bool>.value(false);
    final existing = _resumeReconcileFlight;
    if (existing != null) return existing;
    late final Future<bool> flight;
    flight = _reconcileAfterResumeOnce().whenComplete(() {
      if (identical(_resumeReconcileFlight, flight)) {
        _resumeReconcileFlight = null;
      }
    });
    _resumeReconcileFlight = flight;
    return flight;
  }

  Future<bool> _reconcileAfterResumeOnce() async {
    if (_disposed || isStreaming) return false;
    final expectedUsers = _messages.where(isRealUserTurn).length;
    Map<String, dynamic>? latestVisibleUser;
    for (final message in _messages) {
      if (!isRealUserTurn(message)) continue;
      latestVisibleUser = message;
      break;
    }
    // Stop es una autoridad terminal local y durable. Un snapshot `running`
    // retrasado nunca puede convertir esa cancelación en un turno vivo.
    if (state == ChatPipelineState.cancelled ||
        latestVisibleUser?['_cancelledUser'] == true) {
      return false;
    }
    final awaitsDurableTurnRecovery = awaitingDurableTurnRecovery;
    final top = _messages.isEmpty ? null : _messages.first;
    final replacesIncompleteProjection =
        awaitsDurableTurnRecovery ||
        (top != null &&
            top['role'] == 'assistant' &&
            (top['_pipeline'] == true ||
                ((top['content'] as String?) ?? '').trim().isEmpty));
    final visibleChronological = _messages.reversed.toList(growable: false);
    final endsInToolInvocationWithoutFinal =
        expectedUsers > 0 &&
        _turnAwaitsFinalAfterToolInvocation(
          visibleChronological,
          expectedUsers,
        ) &&
        !_containsDurableFinalAssistantTurn(
          visibleChronological,
          expectedUsers,
        );

    // Cerrar/reabrir durante una herramienta puede dejar la proyección local
    // terminada en `tool` justo antes de que Hermes publique el assistant
    // final. Una lectura REST aislada solo ve ese corte y no vuelve a enlazar
    // los eventos del runtime. Repite el mismo lifecycle autoritativo que usa
    // Actualizar: si el turno sigue vivo restaura el WebSocket; si ya terminó
    // adopta el transcript final sin borrar el fallback visible.
    if (endsInToolInvocationWithoutFinal &&
        _desktopGateway is HermesDesktopSessionLifecycleGateway) {
      final previousMessages = _messages
          .map(Map<String, dynamic>.from)
          .toList(growable: false);
      final previousState = state;
      // `loadMessages` incrementa este epoch síncronamente antes de su primer
      // await. Stop, send y cualquier refresh posterior vuelven a avanzarlo.
      final lifecycleLoadEpoch = _messageLoadEpoch + 1;
      try {
        await loadMessages(
          expectedMessageCount: math.max(_messages.length, expectedUsers),
          profile: _storedSessionProfile,
        );
        if (_disposed || lifecycleLoadEpoch != _messageLoadEpoch) return false;
        final changed =
            previousState != state ||
            !_sameTranscriptProjection(previousMessages, _messages);
        final refreshedChronological = _messages.reversed.toList(
          growable: false,
        );
        final stillMissingFinal =
            !isStreaming &&
            expectedUsers > 0 &&
            _turnAwaitsFinalAfterToolInvocation(
              refreshedChronological,
              expectedUsers,
            ) &&
            !_containsDurableFinalAssistantTurn(
              refreshedChronological,
              expectedUsers,
            );
        if (stillMissingFinal) {
          _scheduleTerminalTranscriptRecovery(
            _turnEpoch,
            messageLoadEpoch: _messageLoadEpoch,
            requireAssistantText: true,
          );
        }
        return changed;
      } catch (error) {
        if (_disposed || lifecycleLoadEpoch != _messageLoadEpoch) return false;
        debugPrint(
          '[active-chat] resume lifecycle reconciliation unavailable '
          '(${error.runtimeType})',
        );
        // Conserva el fallback y prueba debajo la lectura REST acotada.
      }
    }
    final requestedSessionId = serverSessionId;
    final requestedProfile = _storedSessionProfile;
    final loadEpoch = ++_messageLoadEpoch;
    final turnEpoch = _turnEpoch;
    final bindEpoch = _desktopBindEpoch;
    final sessionEpoch = _desktopSessionEpoch;
    final socketGeneration = _desktopTerminalTransportGeneration;
    final producerChannel = _desktopTerminalProducerChannel;
    final requiredTerminalFences = _terminalReconciliationFences(_messages);
    try {
      // Instancia LOCAL: no hay historial remoto que re-sincronizar; recupera
      // lo persistido localmente (el bridge no expone /api/sessions/.../messages).
      final List<Map<String, dynamic>> m;
      LocalTranscriptSnapshot? localSnapshot;
      if (connection.kind == InstanceKind.localhost) {
        localSnapshot = await LocalTranscriptStore.loadSnapshot(
          connection.id,
          sessionId,
          profile: _storedSessionProfile,
        );
        m = localSnapshot.messages;
      } else {
        m = await _loadStoredMessages(requestedProfile);
      }
      if (_disposed ||
          loadEpoch != _messageLoadEpoch ||
          turnEpoch != _turnEpoch ||
          requestedSessionId != serverSessionId ||
          requestedProfile != _storedSessionProfile ||
          bindEpoch != _desktopBindEpoch ||
          sessionEpoch != _desktopSessionEpoch ||
          socketGeneration != _desktopTerminalTransportGeneration ||
          !identical(producerChannel, _desktopTerminalProducerChannel) ||
          isStreaming) {
        return false;
      }
      // El endpoint puede ir por detrás del stream justo al volver del fondo.
      // Un [] o el turno anterior no son autoridad suficiente para borrar la
      // burbuja/scrollback local que el usuario ya estaba viendo.
      final incomingUsers = m.where(isRealUserTurn).length;
      final addsDurableTurn = incomingUsers > expectedUsers;
      final candidateAdvances = addsDurableTurn
          ? _containsCompletedTurn(m, incomingUsers)
          : _terminalTranscriptCanReplaceVisibleProjection(m, expectedUsers);
      if (!candidateAdvances) {
        return false;
      }
      final awaitsToolFinal = _turnAwaitsFinalAfterToolInvocation(
        m,
        expectedUsers,
      );
      if (!addsDurableTurn &&
          awaitsToolFinal &&
          !_containsDurableFinalAssistantTurn(m, expectedUsers)) {
        _scheduleTerminalTranscriptRecovery(
          turnEpoch,
          messageLoadEpoch: loadEpoch,
          requireAssistantText: true,
        );
        return false;
      }
      final incomingTranscriptComplete =
          !(localSnapshot?.olderHistoryTruncated ?? false);
      final normalized = _normalizedNewestFirst(m);
      final _RefreshedTranscriptGraft graft = replacesIncompleteProjection
          ? (
              messages: normalized,
              preservesExistingCoverage: false,
              acceptedRefreshed: true,
              retainsExistingRows: false,
              unconfirmedRetainedIdentities:
                  const <TranscriptMessageIdentity>[],
            )
          : _graftRefreshedTail(
              normalized,
              _messages,
              refreshedTranscriptComplete: incomingTranscriptComplete,
              requiredTerminalFences: requiredTerminalFences,
            );
      if (!graft.acceptedRefreshed) return false;
      final nextMessages = _applyCancelledTurnTombstonesForDisplay(
        _associateGeneratedImagesNewestFirst(
          replacesIncompleteProjection
              ? graft.messages
              : _preserveLocalAssistantErrors(graft.messages, _messages),
        ),
        incomingTranscriptComplete: incomingTranscriptComplete,
      );
      final changed = !_sameTranscriptProjection(_messages, nextMessages);
      if (!changed) {
        // La igualdad visual no conserva un cursor parcial: esta lectura durable
        // también acredita la cobertura final y debe retirar el control anterior.
        _commitRefreshedTailEvidence(normalized, graft);
        if (localSnapshot != null) {
          _recordLocalTranscriptCoverage(localSnapshot);
        } else {
          _markTranscriptComplete(visibleCount: nextMessages.length);
        }
        messagesLoaded = true;
        _emit(ActiveChatEvent.messagesHydrated);
        return false;
      }
      _captureArtifactMaps(m, logicalSessionId: logicalSessionId);
      _commitRefreshedTailEvidence(normalized, graft);
      _messages = nextMessages;
      if (localSnapshot != null) {
        _recordLocalTranscriptCoverage(localSnapshot);
      } else {
        _markTranscriptComplete(visibleCount: _messages.length);
      }
      _reconcileSubagentsFromTranscript();
      messagesLoaded = true;
      if (state != ChatPipelineState.failed || awaitsDurableTurnRecovery) {
        state = ChatPipelineState.completed;
      }
      traceActive = false;
      _emit(ActiveChatEvent.messagesHydrated);
      return true;
    } catch (e) {
      debugPrint(
        '[active-chat] resume reconciliation unavailable '
        '(${e.runtimeType})',
      );
      return false;
    }
  }

  /// Coalescing visual equivalente a Desktop: publica deltas a 30 Hz para no
  /// reconstruir Markdown por token. Android añade una adaptación acotada para
  /// ráfagas grandes, porque algunos transportes móviles entregan varios deltas
  /// juntos aunque Desktop los recibiese separados.
  void _ensureTokenFlush() {
    if (_tokenFlushTimer != null && _tokenFlushTimer!.isActive) return;
    final cadence = _desktopStreamCadence;
    _tokenFlushTimer = Timer.periodic(cadence, (t) {
      final pending = _tokenBuffer.toString();
      if (pending.isEmpty) {
        t.cancel();
        _tokenFlushTimer = null;
        return;
      }
      // Igual que Hermes Desktop: limita la frecuencia de repintado, no vuelve
      // a trocear el texto recibido. Inventar frames de 1–6 unidades UTF-16
      // exponía media palabra, marcadores Markdown y grafemas incompletos que
      // nunca habían existido como deltas del Gateway.
      _publishTokenChunk(pending, pending.length);
    });
  }

  void _publishTokenChunk(String pending, int take) {
    _tokenBuffer.clear();
    if (take < pending.length) _tokenBuffer.write(pending.substring(take));
    final chunk = pending.substring(0, take);
    state = ChatPipelineState.streaming;
    if (_messages.isNotEmpty && _messages[0]['role'] == 'assistant') {
      _messages[0] = {
        ..._messages[0],
        'content': ((_messages[0]['content'] as String?) ?? '') + chunk,
        '_pipeline': false,
      };
    }
    _emit(ActiveChatEvent.token);
  }

  void _enqueueToken(String token, {bool narratable = true}) {
    if (token.isEmpty) return;
    _assistantRawStream.write(token);
    final projected = streamingPublicAssistantText(
      _assistantRawStream.toString(),
    );
    if (!projected.startsWith(_assistantPublicStream)) {
      return;
    }
    final publicDelta = projected.substring(_assistantPublicStream.length);
    _assistantPublicStream = projected;
    if (publicDelta.isEmpty) return;
    _observeFirstResponseContent(publicDelta);
    if (narratable) _assistantNarration.appendDelta(publicDelta);
    _tokenBuffer.write(publicDelta);
    if (_immediateStreaming) {
      _flushTokenBuffer();
      state = ChatPipelineState.streaming;
      _emit(ActiveChatEvent.token);
    } else {
      _ensureTokenFlush();
    }
  }

  /// Convierte el sufijo autoritativo todavía invisible en la misma cola
  /// visual. Así el terminal no sustituye de golpe una respuesta que el
  /// transporte entregó coalescida.
  void _queueAuthoritativeFinalTail(String? finalOutput) {
    if (finalOutput == null ||
        _messages.isEmpty ||
        _messages[0]['role'] != 'assistant') {
      return;
    }
    final visible = (_messages[0]['content'] as String?) ?? '';
    if (!finalOutput.startsWith(visible)) return;
    _tokenBuffer
      ..clear()
      ..write(finalOutput.substring(visible.length));
  }

  void _publishBufferedTokenBatch() {
    if (_tokenBuffer.isEmpty) return;
    _tokenFlushTimer?.cancel();
    _tokenFlushTimer = null;
    final pending = _tokenBuffer.toString();
    _publishTokenChunk(pending, pending.length);
  }

  void _flushTokenBuffer() {
    _tokenFlushTimer?.cancel();
    _tokenFlushTimer = null;
    if (_tokenBuffer.isEmpty) return;
    final accumulated = _tokenBuffer.toString();
    _tokenBuffer.clear();
    if (_messages.isNotEmpty && _messages[0]['role'] == 'assistant') {
      _messages[0] = {
        ..._messages[0],
        'content': ((_messages[0]['content'] as String?) ?? '') + accumulated,
        '_pipeline': false,
      };
    }
  }

  void dispose() {
    if (_disposed) return;
    suspendSubagentForegroundPresentation();
    _autoCompactionStaleTimer?.cancel();
    _autoCompactionStaleTimer = null;
    _disposed = true;
    _messageLoadEpoch++;
    final stop = _stopTransition;
    if (stop != null && !stop.isFinal) {
      stop.state = _StopTransitionState.superseded;
      if (!stop.terminal.isCompleted) stop.terminal.complete();
    }
    _queueLease = QueueLease.parked;
    _queueDrainSuspended = true;
    if (!_turnEpochInvalidated.isCompleted) {
      _turnEpochInvalidated.complete();
    }
    _turnEpoch++;
    if (!_disposeSignal.isCompleted) _disposeSignal.complete();
    _activityWatchdogTimer?.cancel();
    _cancelPassiveActivityExpiry();
    _voiceBargeHandoffTimer?.cancel();
    _voiceBargeHandoffTimer = null;
    _voiceBargeHandoffPending = false;
    _queuedRetryTimer?.cancel();
    _queuedRetryTimer = null;
    _queuedTextRetryTimer?.cancel();
    _queuedTextRetryTimer = null;
    _tokenFlushTimer?.cancel();
    _terminalTimer?.cancel();
    _desktopEventSubscription?.cancel();
    _interactivePrompts = InteractivePromptReducer.reduce(
      _interactivePrompts,
      const InteractivePromptDisposed(),
    );
    _retireDesktopRuntime();
    unawaited(_desktopGateway?.close());
    _api.close();
    _transportStatusListenable.dispose();
    _changes.close();
  }
}

final class _TerminalCommitGate {
  _TerminalCommitGate(this.epoch);

  final int epoch;
  bool terminalClaimed = false;
  bool donePublished = false;
  bool drainScheduled = false;
  bool desktopQueuedStarted = false;
  bool transcriptApplied = false;
}

class _HomeWidgetChatMetadata {
  _HomeWidgetChatMetadata.fromSession(Session session)
    : model = _nonEmpty(session.model),
      inputTokens = session.inputTokens,
      outputTokens = session.outputTokens,
      cacheReadTokens = session.cacheReadTokens,
      cacheWriteTokens = session.cacheWriteTokens,
      lastActivityAtMs = (session.lastActivityAt * 1000).round(),
      isUnpersistedMobileDraft = session.isUnpersistedMobileDraft;

  String? model;
  String? provider;
  int inputTokens;
  int outputTokens;
  int? cacheReadTokens;
  int? cacheWriteTokens;
  int lastActivityAtMs;
  bool isUnpersistedMobileDraft;
  bool hasContextSnapshot = false;
  int? contextUsed;
  int? contextMax;
  int? contextPercent;

  void refresh(Session session) {
    model = _nonEmpty(session.model) ?? model;
    inputTokens = session.inputTokens;
    outputTokens = session.outputTokens;
    cacheReadTokens = session.cacheReadTokens;
    cacheWriteTokens = session.cacheWriteTokens;
    lastActivityAtMs = (session.lastActivityAt * 1000).round();
    isUnpersistedMobileDraft = session.isUnpersistedMobileDraft;
  }

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

/// Registro de chats con streaming activo. Singleton vivo en HermesAppState.
class ActiveChatService {
  ActiveChatService({
    this.notifications,
    this.policy,
    SharedPreferences? prefs,
    CancelledTurnTombstoneStore? cancelledTurnStore,
    DesktopCompressionFenceStore? compressionFenceStore,
    GlobalActivityAggregate? globalActivity,
    bool attachDesktopRuntimeOnLoad = true,
  }) : _prefs = prefs,
       _cancelledTurnStore = cancelledTurnStore,
       _attachDesktopRuntimeOnLoadByDefault = attachDesktopRuntimeOnLoad,
       globalActivity =
           globalActivity ??
           GlobalActivityAggregate(
             journal: GlobalActivityJournal.secure(),
             onTerminal: notifications == null
                 ? null
                 : (scope, phase) => notifications.sessionActivityFinished(
                     phase: sessionActivityPhaseWire(phase),
                     connId: scope.connectionId,
                     sessionId: scope.durableSessionId,
                     profile: scope.profile,
                   ),
           ),
       _compressionFenceStore =
           compressionFenceStore ?? DesktopCompressionFenceStore() {
    _restoreObservedFirstTokenLatencies();
    unawaited(_drainPendingCancelledTurnCleanup());
  }

  final NotificationService? notifications;

  /// Política de aprobaciones compartida. Inyectada para que el auto-approval
  /// (YOLO / reglas guardadas) ocurra en la capa de servicio, no en la pantalla.
  final ApprovalPolicyService? policy;

  /// Prefs para registrar runs en RunRegistry cuando se inician desde el chat.
  /// Si es null (p.ej. en tests), el registro se omite sin efecto secundario.
  final SharedPreferences? _prefs;
  final CancelledTurnTombstoneStore? _cancelledTurnStore;
  final DesktopCompressionFenceStore _compressionFenceStore;
  final bool _attachDesktopRuntimeOnLoadByDefault;
  final GlobalActivityAggregate globalActivity;

  final Map<String, ActiveChat> _chats = {};
  final Map<String, List<SteerProjection>> _steerProjectionCache = {};
  final Map<ActiveChat, _HomeWidgetChatMetadata> _homeWidgetMetadata = {};
  final LinkedHashMap<String, int> _observedFirstTokenLatencyCache =
      LinkedHashMap<String, int>();
  static const _observedFirstTokenLatencyPrefsKey =
      'active_chat_observed_ttft_v1';
  HermesHomeWidgetPublisher? _homeWidgetPublisher;
  String? _homeWidgetActiveConnectionId;
  HermesHomeWidgetSnapshot? _lastHomeWidgetSemantic;
  bool _disposed = false;

  static String chatKey(String connectionId, String sessionId) =>
      '$connectionId::$sessionId';

  static const _pendingCancelledTurnCleanupKey =
      'cancelled_turn_cleanup_pending_v1';
  Future<void> _cleanupMutation = Future<void>.value();

  Future<void> _enqueueCancelledTurnCleanup(List<String> command) {
    final prefs = _prefs;
    if (prefs == null) return Future<void>.value();
    final operation = _cleanupMutation.then((_) async {
      final encoded = jsonEncode(command);
      final pending =
          prefs.getStringList(_pendingCancelledTurnCleanupKey) ?? [];
      if (!pending.contains(encoded)) pending.add(encoded);
      await prefs.setStringList(_pendingCancelledTurnCleanupKey, pending);
    });
    _cleanupMutation = operation.catchError((_) {});
    return operation;
  }

  Future<void> _drainPendingCancelledTurnCleanup() {
    final operation = _cleanupMutation.then((_) async {
      final prefs = _prefs;
      final store = _cancelledTurnStore;
      if (prefs == null || store == null) return;
      final pending =
          prefs.getStringList(_pendingCancelledTurnCleanupKey) ?? [];
      if (pending.isEmpty) return;
      final remaining = <String>[];
      for (final encoded in pending) {
        try {
          final command = jsonDecode(encoded);
          if (command is! List || command.isEmpty) continue;
          if (command.first == 'session' && command.length == 4) {
            await store.removeSession(
              connectionId: command[1] as String,
              profile: command[2] as String,
              sessionId: command[3] as String,
            );
          } else if (command.first == 'connection' && command.length == 2) {
            await store.removeConnection(command[1] as String);
          }
        } catch (_) {
          remaining.add(encoded);
        }
      }
      await prefs.setStringList(_pendingCancelledTurnCleanupKey, remaining);
    });
    _cleanupMutation = operation.catchError((_) {});
    return operation;
  }

  Future<int> clearCompressionFenceForSession({
    required String connectionId,
    required String profile,
    required String logicalSessionId,
  }) => _compressionFenceStore.clearSession(
    DesktopCompressionFenceScope(
      connectionId: connectionId,
      profile: profile,
      logicalSessionId: logicalSessionId,
    ),
  );

  Future<int> clearCompressionFencesForConnection(String connectionId) =>
      _compressionFenceStore.clearConnection(connectionId);

  Future<int> clearCancelledTurnsForSession({
    required String connectionId,
    required String profile,
    required String sessionId,
  }) async {
    final owner = Session.profileOwner(profile);
    final scopeIds = <String>{sessionId};
    final matchingChats = <ActiveChat>[];
    for (final chat in _chats.values) {
      if (chat.connection.id != connectionId || chat.sessionProfile != owner) {
        continue;
      }
      final aliases = <String>{
        chat.sessionId,
        chat.serverSessionId,
        chat.logicalSessionId,
      };
      if (!aliases.contains(sessionId)) continue;
      matchingChats.add(chat);
      scopeIds.addAll(aliases);
    }

    var removed = 0;
    Object? firstError;
    StackTrace? firstStack;
    for (final scopeId in scopeIds) {
      try {
        removed +=
            await _cancelledTurnStore?.removeSession(
              connectionId: connectionId,
              profile: owner,
              sessionId: scopeId,
            ) ??
            0;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
        await _enqueueCancelledTurnCleanup([
          'session',
          connectionId,
          owner,
          scopeId,
        ]);
      }
    }
    for (final chat in matchingChats) {
      chat.clearCancelledTurnTombstones();
    }
    // This entry point is called only after the backend confirmed the exact
    // remote session deletion. Do not broaden the durable fence cleanup to
    // aliases discovered from local history.
    await clearCompressionFenceForSession(
      connectionId: connectionId,
      profile: owner,
      logicalSessionId: sessionId,
    );
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
    return removed;
  }

  Future<int> clearCancelledTurnsForConnection(String connectionId) async {
    var removed = 0;
    try {
      removed = await _cancelledTurnStore?.removeConnection(connectionId) ?? 0;
    } catch (_) {
      await _enqueueCancelledTurnCleanup(['connection', connectionId]);
      rethrow;
    } finally {
      await clearCompressionFencesForConnection(connectionId);
      for (final entry in _chats.entries) {
        try {
          final parts = jsonDecode(entry.key);
          if (parts is List &&
              parts.isNotEmpty &&
              parts.first == connectionId) {
            entry.value.clearCancelledTurnTombstones();
          }
        } catch (_) {
          if (entry.key.startsWith('$connectionId::')) {
            entry.value.clearCancelledTurnTombstones();
          }
        }
      }
    }
    return removed;
  }

  static String _registryKey(
    String connectionId,
    String sessionId,
    String profile,
  ) => jsonEncode(<String>[
    connectionId,
    Session.profileOwner(profile),
    sessionId,
  ]);

  static String _legacyChatKey(String connectionId, String sessionId) =>
      '$connectionId::$sessionId';

  int? _cachedObservedFirstTokenLatencyMs(
    String connectionId,
    String sessionId, {
    required String profile,
  }) {
    final owner = Session.profileOwner(profile);
    final current =
        _observedFirstTokenLatencyCache[_registryKey(
          connectionId,
          sessionId,
          owner,
        )];
    if (current != null) return current;
    // Las versiones anteriores no sellaban el perfil. Solo `default` puede
    // adoptar esa métrica: aplicarla a un owner alternativo mezclaría chats
    // que comparten ids entre perfiles.
    if (owner != 'default') return null;
    return _observedFirstTokenLatencyCache[_legacyChatKey(
      connectionId,
      sessionId,
    )];
  }

  String _projectionKey(
    String connectionId,
    String sessionId, {
    required String profile,
  }) => _registryKey(connectionId, sessionId, profile);

  /// Condición extra para NO bajar el foreground service aunque no haya runs en
  /// curso. La usa el modo voz: mientras el TTS sigue hablando en 2º plano tras
  /// completar el run, el proceso debe seguir vivo o el SO cortaría la voz a
  /// media frase. La cablea HermesAppState con el estado del VoiceConversation.
  bool Function()? keepAliveWhile;

  /// Reevalúa si procede bajar el foreground service (lo llama el modo voz cuando
  /// el TTS deja de hablar en 2º plano: ya no hay nada que mantener vivo).
  Future<void> maybeReleaseForeground() => _maybeStopForeground();

  /// Identidades `conexión + perfil + sesión` con un stream EN CURSO.
  ///
  /// Las superficies lo observan como señal de invalidación y consultan
  /// [isActive] para resolver el estado. Incluir el perfil garantiza que el fin
  /// de A notifique aunque B conserve el mismo sessionId en otro owner.
  final ValueNotifier<Set<String>> activeIds = ValueNotifier<Set<String>>({});

  /// Conecta la salida no sensible hacia Glance. El servicio sigue siendo el
  /// único reducer del estado vivo del chat; la app solo conserva la parte base
  /// (instancia, salud y tema) del snapshot.
  void bindHomeWidgetPublisher(
    HermesHomeWidgetPublisher publisher, {
    required String? activeConnectionId,
  }) {
    _homeWidgetPublisher = publisher;
    _homeWidgetActiveConnectionId = activeConnectionId;
    _lastHomeWidgetSemantic = null;
  }

  /// Cambiar de instancia invalida inmediatamente toda identidad y métrica de
  /// la sesión anterior. Los eventos tardíos se ignoran por connection id.
  Future<void> setHomeWidgetActiveConnection(String? connectionId) async {
    if (_homeWidgetActiveConnectionId == connectionId) return;
    _homeWidgetActiveConnectionId = connectionId;
    _lastHomeWidgetSemantic = null;
    final publisher = _homeWidgetPublisher;
    if (publisher == null) return;
    try {
      await publisher.update(
        (current) => current.copyWith(
          clearModel: true,
          clearProvider: true,
          clearSessionId: true,
          clearSessionTitle: true,
          agentState: HomeWidgetAgentState.disconnected,
          clearToolName: true,
          clearContextUsed: true,
          clearContextMax: true,
          clearContextPercent: true,
          clearInputTokens: true,
          clearOutputTokens: true,
          clearCacheReadTokens: true,
          clearCacheWriteTokens: true,
          clearFirstTokenLatencyMs: true,
          clearLastActivityAtMs: true,
        ),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[home-widget] session clear unavailable (${error.runtimeType})',
        );
      }
    }
  }

  MapEntry<String, ActiveChat>? _entryFor(
    String connectionId,
    String sessionId, {
    String? profile,
  }) {
    final owner = profile == null ? null : Session.profileOwner(profile);
    if (owner != null) {
      final key = _registryKey(connectionId, sessionId, owner);
      final direct = _chats[key];
      if (direct != null) return MapEntry(key, direct);
    }
    MapEntry<String, ActiveChat>? match;
    for (final entry in _chats.entries) {
      final chat = entry.value;
      if (chat.connection.id != connectionId ||
          (owner != null && chat.sessionProfile != owner) ||
          (chat.sessionId != sessionId && chat.storedSessionId != sessionId)) {
        continue;
      }
      // Sin perfil explícito nunca elegimos arbitrariamente entre dos homes.
      // Los payloads legacy deben resolver primero su Session autoritativa.
      if (match != null && !identical(match.value, chat)) return null;
      match = entry;
    }
    return match;
  }

  /// Devuelve el chat activo por su ID móvil o por el ID persistido de Hermes.
  ActiveChat? of(String connectionId, String sessionId, {String? profile}) =>
      _entryFor(connectionId, sessionId, profile: profile)?.value;

  Future<SessionStopResult> stopSessionWork({
    required SavedConnection connection,
    required Session session,
    @visibleForTesting HermesDesktopGateway? desktopGateway,
    @visibleForTesting ApiClient? api,
    @visibleForTesting StoredSessionMessageLoader? storedMessageLoader,
  }) async {
    final owner = Session.profileOwner(session.profile);
    final existing = of(connection.id, session.id, profile: owner);
    final attachedForStop = existing == null;
    final chat =
        existing ??
        attach(
          connection: connection,
          sessionId: session.id,
          logicalSessionId: session.logicalId,
          sessionTitle: session.displayTitle,
          sessionSnapshot: session,
          sessionProfile: owner,
          initialStoredSessionId: session.id,
          desktopGateway: desktopGateway,
          api: api,
          storedMessageLoader: storedMessageLoader,
          attachDesktopRuntimeOnLoad: true,
          allowUnownedDesktopSnapshotForTesting: desktopGateway != null,
        );
    try {
      if (!chat.hasDesktopRuntime) {
        await chat.loadMessages(
          expectedMessageCount: session.messageCount,
          profile: owner,
        );
      }
      if (!chat.hasDesktopRuntime) {
        throw const TuiGatewayRpcError(
          'session.interrupt',
          'No live runtime is available',
          code: 4007,
        );
      }
      await Future.wait([
        chat.refreshSubagents(),
        chat.refreshBackgroundProcesses(),
      ]);
      return await chat.stopSessionWork();
    } finally {
      if (attachedForStop) {
        release(connection.id, session.id, profile: owner);
        final retained = _entryFor(connection.id, session.id, profile: owner);
        if (retained != null && identical(retained.value, chat)) {
          _dispose(retained.key);
        }
      }
    }
  }

  /// ¿La sesión tiene un stream en curso?
  bool isActive(String connectionId, String sessionId, {String? profile}) {
    if (profile == null) {
      // Uso de indicador únicamente: sin perfil no elegimos un chat ni
      // devolvemos contenido, pero sí podemos afirmar si cualquiera de los
      // owners con ese id sigue ejecutándose.
      return _chats.values.any(
        (chat) =>
            chat.connection.id == connectionId &&
            (chat.sessionId == sessionId ||
                chat.storedSessionId == sessionId) &&
            chat.sessionActivity.active,
      );
    }
    return _entryFor(
          connectionId,
          sessionId,
          profile: profile,
        )?.value.sessionActivity.active ??
        false;
  }

  int? observedFirstTokenLatencyMs(
    String connectionId,
    String sessionId, {
    String? profile,
  }) {
    final chat = of(connectionId, sessionId, profile: profile);
    if (chat != null) return chat.observedFirstTokenLatencyMs;
    return _cachedObservedFirstTokenLatencyMs(
      connectionId,
      sessionId,
      profile: Session.profileOwner(profile),
    );
  }

  void _restoreObservedFirstTokenLatencies() {
    final raw = _prefs?.getString(_observedFirstTokenLatencyPrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String &&
            key.isNotEmpty &&
            key.length <= 520 &&
            value is int &&
            value >= 0) {
          _observedFirstTokenLatencyCache[key] = value;
        }
      }
      while (_observedFirstTokenLatencyCache.length > 128) {
        _observedFirstTokenLatencyCache.remove(
          _observedFirstTokenLatencyCache.keys.first,
        );
      }
    } catch (_) {
      // Métrica local opcional: datos antiguos/corruptos no bloquean el chat.
    }
  }

  Future<void> _persistObservedFirstTokenLatencies() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(
      _observedFirstTokenLatencyPrefsKey,
      jsonEncode(_observedFirstTokenLatencyCache),
    );
  }

  void _rememberObservedFirstTokenLatency(ActiveChat chat, int? latencyMs) {
    final ids = <String>{chat.sessionId, chat.logicalSessionId};
    final storedId = chat.storedSessionId;
    if (storedId != null && storedId.isNotEmpty) ids.add(storedId);
    final owner = Session.profileOwner(chat.sessionProfile);
    for (final id in ids) {
      final key = _registryKey(chat.connection.id, id, owner);
      if (latencyMs == null) {
        _observedFirstTokenLatencyCache.remove(key);
      } else {
        _observedFirstTokenLatencyCache.remove(key);
        _observedFirstTokenLatencyCache[key] = latencyMs;
      }
      if (owner == 'default') {
        _observedFirstTokenLatencyCache.remove(
          _legacyChatKey(chat.connection.id, id),
        );
      }
    }
    while (_observedFirstTokenLatencyCache.length > 128) {
      _observedFirstTokenLatencyCache.remove(
        _observedFirstTokenLatencyCache.keys.first,
      );
    }
    unawaited(_persistObservedFirstTokenLatencies());
  }

  /// Refresca selección local de modelo/proveedor sin publicar desde la UI.
  /// La proyección final siempre se reduce aquí junto al runtime autoritativo.
  void updateHomeWidgetSessionMetadata(
    ActiveChat chat, {
    Session? session,
    String? model,
    String? provider,
  }) {
    final metadata = _homeWidgetMetadata[chat];
    if (metadata == null) return;
    if (session != null) metadata.refresh(session);
    final normalizedModel = _nonEmptyWidgetText(model);
    final normalizedProvider = _nonEmptyWidgetText(provider);
    if (normalizedModel != null && normalizedModel != 'hermes-agent') {
      metadata.model = normalizedModel;
    }
    if (normalizedProvider != null && normalizedProvider != 'gateway') {
      metadata.provider = normalizedProvider;
    }
    _publishHomeWidgetChat(chat);
  }

  /// Mirrors the exact context projection already accepted by ChatScreen.
  /// Values may be null to represent the same honest unknown state; this
  /// reducer never estimates occupancy from cumulative token counters.
  void updateHomeWidgetSessionContext(
    ActiveChat chat, {
    required int? contextUsed,
    required int? contextMax,
    required int? contextPercent,
  }) {
    final metadata = _homeWidgetMetadata[chat];
    if (metadata == null) return;
    metadata
      ..hasContextSnapshot = true
      ..contextUsed = contextUsed
      ..contextMax = contextMax
      ..contextPercent = contextPercent;
    _publishHomeWidgetChat(chat);
  }

  void _onHomeWidgetChatEvent(ActiveChat chat, ActiveChatEvent event) {
    _publishHomeWidgetChat(chat, event: event);
  }

  HomeWidgetAgentState _homeWidgetAgentState(
    ActiveChat chat,
    ActiveChatEvent? event,
  ) {
    if (event == ActiveChatEvent.error) return HomeWidgetAgentState.error;
    if (event == ActiveChatEvent.done || event == ActiveChatEvent.cancelled) {
      return HomeWidgetAgentState.idle;
    }
    if (event == ActiveChatEvent.token) return HomeWidgetAgentState.streaming;
    if (event == ActiveChatEvent.toolProgress ||
        event == ActiveChatEvent.subagentActivity) {
      return HomeWidgetAgentState.toolExecution;
    }
    if (event == ActiveChatEvent.started ||
        event == ActiveChatEvent.connected ||
        event == ActiveChatEvent.waiting) {
      return HomeWidgetAgentState.thinking;
    }
    if (chat.needsInput ||
        event == ActiveChatEvent.approvalRequest ||
        event == ActiveChatEvent.interactiveRequest) {
      return HomeWidgetAgentState.waitingApproval;
    }
    return switch (chat.state) {
      ChatPipelineState.connecting ||
      ChatPipelineState.waiting => HomeWidgetAgentState.thinking,
      ChatPipelineState.executing => HomeWidgetAgentState.toolExecution,
      ChatPipelineState.streaming => HomeWidgetAgentState.streaming,
      ChatPipelineState.failed => HomeWidgetAgentState.error,
      ChatPipelineState.idle ||
      ChatPipelineState.completed ||
      ChatPipelineState.cancelled => HomeWidgetAgentState.idle,
    };
  }

  String? _runningHomeWidgetTool(ActiveChat chat) {
    for (final tool in chat.trace.reversed) {
      if (tool.status == 'running') return _nonEmptyWidgetText(tool.label);
    }
    return null;
  }

  bool _homeWidgetEventTouchesActivity(
    ActiveChat chat,
    ActiveChatEvent? event,
  ) => switch (event) {
    ActiveChatEvent.started ||
    ActiveChatEvent.connected ||
    ActiveChatEvent.waiting ||
    ActiveChatEvent.token ||
    ActiveChatEvent.toolProgress ||
    ActiveChatEvent.approvalRequest ||
    ActiveChatEvent.interactiveRequest ||
    ActiveChatEvent.subagentActivity ||
    ActiveChatEvent.done ||
    ActiveChatEvent.error ||
    ActiveChatEvent.cancelled => true,
    ActiveChatEvent.sessionInfo => chat.isStreaming,
    _ => false,
  };

  void _publishHomeWidgetChat(ActiveChat chat, {ActiveChatEvent? event}) {
    final publisher = _homeWidgetPublisher;
    final metadata = _homeWidgetMetadata[chat];
    if (publisher == null ||
        metadata == null ||
        chat.connection.id != _homeWidgetActiveConnectionId) {
      return;
    }
    // A draft created by the composer is not addressable through Hermes yet.
    // Publishing its provisional mob-* id would replace the last real session
    // and make the widget's Return action point at a non-existent REST record.
    if (metadata.isUnpersistedMobileDraft &&
        chat.storedSessionId == null &&
        chat.serverSessionId.startsWith('mob-')) {
      return;
    }
    final current = publisher.latest;
    final usage = chat.desktopRuntimeInfo.usage;
    final runtimeModel = _nonEmptyWidgetText(chat.desktopRuntimeInfo.model);
    final turnModel = _nonEmptyWidgetText(chat._lastModel);
    final runtimeProvider = _nonEmptyWidgetText(
      chat.desktopRuntimeInfo.provider,
    );
    final sameSession = current.sessionId == chat.serverSessionId;
    final candidateSessionTitle = _meaningfulWidgetSessionTitle(
      chat.sessionTitle,
    );
    final sessionTitle =
        candidateSessionTitle ?? (sameSession ? current.sessionTitle : null);
    final contextUsed = metadata.hasContextSnapshot
        ? metadata.contextUsed
        : usage?.contextUsed ?? (sameSession ? current.contextUsed : null);
    final contextMax = metadata.hasContextSnapshot
        ? metadata.contextMax
        : usage?.contextMax ?? (sameSession ? current.contextMax : null);
    final contextPercent = metadata.hasContextSnapshot
        ? metadata.contextPercent
        : usage?.contextPercent?.round().clamp(0, 100);
    final livePublishesCache =
        usage?.cacheReadTokens != null || usage?.cacheWriteTokens != null;
    final metadataPublishesCache =
        metadata.cacheReadTokens != null || metadata.cacheWriteTokens != null;
    final useMetadataPromptUsage =
        metadataPublishesCache && !livePublishesCache;
    final agentState = _homeWidgetAgentState(chat, event);
    final toolName = agentState == HomeWidgetAgentState.toolExecution
        ? _runningHomeWidgetTool(chat)
        : null;
    final previousSessionActivity = current.sessionId == chat.serverSessionId
        ? current.lastActivityAtMs
        : null;
    var next = HermesHomeWidgetSnapshot(
      configured: true,
      instanceId: chat.connection.id,
      instanceLabel: chat.connection.label,
      connectionState: switch (event) {
        ActiveChatEvent.connected ||
        ActiveChatEvent.waiting ||
        ActiveChatEvent.token ||
        ActiveChatEvent.toolProgress ||
        ActiveChatEvent.approvalRequest ||
        ActiveChatEvent.interactiveRequest ||
        ActiveChatEvent.subagentActivity ||
        ActiveChatEvent.done ||
        ActiveChatEvent.cancelled => HomeWidgetConnectionState.connected,
        ActiveChatEvent.started
            when current.connectionState ==
                HomeWidgetConnectionState.disconnected =>
          HomeWidgetConnectionState.connecting,
        _ => current.connectionState,
      },
      model:
          runtimeModel ??
          (turnModel == 'hermes-agent' ? null : turnModel) ??
          metadata.model,
      provider: runtimeProvider ?? metadata.provider,
      sessionId: chat.serverSessionId,
      sessionTitle: sessionTitle,
      agentState: agentState,
      toolName: toolName,
      contextUsed: contextUsed,
      contextMax: contextMax,
      contextPercent: contextPercent,
      inputTokens: useMetadataPromptUsage
          ? metadata.inputTokens
          : usage?.input ?? metadata.inputTokens,
      outputTokens: usage?.output ?? metadata.outputTokens,
      cacheReadTokens: livePublishesCache
          ? usage?.cacheReadTokens
          : metadata.cacheReadTokens,
      cacheWriteTokens: livePublishesCache
          ? usage?.cacheWriteTokens
          : metadata.cacheWriteTokens,
      firstTokenLatencyMs: chat.observedFirstTokenLatencyMs,
      lastActivityAtMs: previousSessionActivity ?? metadata.lastActivityAtMs,
      theme: current.theme,
      showAdvancedMetrics: current.showAdvancedMetrics,
    );
    var semantic = next.copyWith(updatedAtMs: 0);
    if (semantic == _lastHomeWidgetSemantic) return;
    if (_homeWidgetEventTouchesActivity(chat, event)) {
      next = next.copyWith(
        lastActivityAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      semantic = next.copyWith(updatedAtMs: 0);
    }
    _lastHomeWidgetSemantic = semantic;
    unawaited(_publishHomeWidgetSnapshot(publisher, next));
  }

  Future<void> _publishHomeWidgetSnapshot(
    HermesHomeWidgetPublisher publisher,
    HermesHomeWidgetSnapshot snapshot,
  ) async {
    try {
      await publisher.publish(snapshot);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[home-widget] chat state unavailable (${error.runtimeType})',
        );
      }
    }
  }

  static String? _nonEmptyWidgetText(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String? _meaningfulWidgetSessionTitle(String? value) {
    final normalized = _nonEmptyWidgetText(value);
    if (normalized == null) return null;
    final placeholder = normalized.toLowerCase();
    if (const <String>{
      'untitled',
      'sin titulo',
      'sin título',
      'new session',
      'new conversation',
      'nueva conversacion',
      'nueva conversación',
    }.contains(placeholder)) {
      return null;
    }
    return normalized;
  }

  /// Engancha (o crea) el chat de una sesión. Lo usa la pantalla al abrirse.
  ActiveChat attach({
    required SavedConnection connection,
    required String sessionId,
    String? logicalSessionId,
    required String sessionTitle,
    Session? sessionSnapshot,
    String? sessionProfile,
    String? initialStoredSessionId,
    LocalConversationLifecycle? localConversationLifecycle,
    NotificationChatSurface notificationSurface =
        NotificationChatSurface.normal,
    String? notificationRoomId,
    bool authoritativeStoredSessionBinding = false,
    String? selectedProvider,
    @visibleForTesting ApiClient? api,
    @visibleForTesting HermesDesktopGateway? desktopGateway,
    @visibleForTesting StoredSessionMessageLoader? storedMessageLoader,
    bool? attachDesktopRuntimeOnLoad,
    @visibleForTesting bool allowUnownedDesktopSnapshotForTesting = false,
    @visibleForTesting Future<bool> Function()? turnIdempotencyCapability,
    @visibleForTesting bool disableForegroundKeepAlive = false,
    @visibleForTesting int transcriptPageSizeForTesting = 500,
  }) {
    final owner = Session.profileOwner(
      sessionProfile ?? sessionSnapshot?.profile,
    );
    final key = _registryKey(connection.id, sessionId, owner);
    final existing = of(connection.id, sessionId, profile: owner);
    if (existing != null) {
      if (existing.bindKnownStoredSession(
        initialStoredSessionId,
        authoritative: authoritativeStoredSessionBinding,
      )) {
        existing._markAttached();
        existing._localConversationLifecycle = localConversationLifecycle;
        existing.sessionTitle = sessionTitle;
        existing._bindSessionProfile(owner);
        existing.bindNotificationTarget(
          notificationSurface,
          roomId: notificationRoomId,
        );
        final metadata = _homeWidgetMetadata[existing];
        if (sessionSnapshot != null) metadata?.refresh(sessionSnapshot);
        final provider = _nonEmptyWidgetText(selectedProvider);
        if (provider != null && provider != 'gateway') {
          metadata?.provider = provider;
        }
        _publishHomeWidgetChat(existing);
        return existing;
      }
      // Un binding nuevo no puede saltarse una escritura durable en vuelo. La
      // próxima invalidación/attach resolverá la identidad tras el commit.
      if (existing.hasPendingDurableCancellation) return existing;
      // A stable mobile Bot/Room route can be reopened after its authoritative
      // stored id changes. Never retarget an existing runtime; dispose that
      // binding and attach a fresh chat for the new durable identity.
      _dispose(key);
    }
    final tombstoneGeneration = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              connection.id,
              connection.kind.name,
              connection.host,
              connection.port,
              connection.useHttps,
              connection.gatewayAuthMode.storageKey,
              connection.apiKey,
            ]),
          ),
        )
        .toString();
    final cancelledTurnStore = _cancelledTurnStore;
    final initialTombstoneSessionIds = <String>{
      sessionId,
      if (logicalSessionId != null && logicalSessionId.isNotEmpty)
        logicalSessionId,
      if (initialStoredSessionId != null && initialStoredSessionId.isNotEmpty)
        initialStoredSessionId,
    };
    late final ActiveChat chat;
    chat = ActiveChat(
      connection: connection,
      sessionId: sessionId,
      logicalSessionId: logicalSessionId,
      sessionTitle: sessionTitle,
      notificationSurface: notificationSurface,
      notificationRoomId: notificationRoomId,
      sessionProfile: owner,
      initialStoredSessionId: initialStoredSessionId,
      localConversationLifecycle: localConversationLifecycle,
      notifications: notifications,
      policy: policy,
      onTerminal: () => _onChatTerminal(key),
      onUnused: () => _onChatUnused(key),
      beforeTerminalNotification: _maybeStopForeground,
      onRunStarted: (runId) => _onRunStarted(key, runId),
      onForegroundKeepAlive: disableForegroundKeepAlive
          ? null
          : () async {
              await BackgroundListener.ensureAutomationForeground();
              _refreshActiveIds();
            },
      api: api,
      desktopGateway: desktopGateway,
      compressionFenceStore: _compressionFenceStore,
      storedMessageLoader: storedMessageLoader,
      attachDesktopRuntimeOnLoad:
          attachDesktopRuntimeOnLoad ?? _attachDesktopRuntimeOnLoadByDefault,
      allowUnownedDesktopSnapshotForTesting:
          allowUnownedDesktopSnapshotForTesting,
      turnIdempotencyCapability: turnIdempotencyCapability,
      transcriptPageSizeForTesting: transcriptPageSizeForTesting,
      initialObservedFirstTokenLatencyMs: _cachedObservedFirstTokenLatencyMs(
        connection.id,
        sessionId,
        profile: owner,
      ),
      onObservedFirstTokenLatency: (latencyMs) {
        _rememberObservedFirstTokenLatency(chat, latencyMs);
        if (latencyMs != null) {
          _onHomeWidgetChatEvent(chat, ActiveChatEvent.token);
        }
      },
      onEvent: (event) {
        _onHomeWidgetChatEvent(chat, event);
        _refreshActiveIds(force: event == ActiveChatEvent.subagentActivity);
        if (event == ActiveChatEvent.subagentActivity) {
          _onChatUnused(key);
        }
      },
      initialSteerProjections:
          _steerProjectionCache[_projectionKey(
            connection.id,
            sessionId,
            profile: owner,
          )] ??
          const [],
      // La primera conversación puede cambiar de id al adoptar la sesión
      // durable de Desktop. Restaura la unión exacta de ruta, lineage y stored
      // id para que un Stop confirmado no desaparezca tras reabrir.
      initialCancelledTurnTombstones:
          cancelledTurnStore?.loadAliases(
            connectionId: connection.id,
            profile: owner,
            sessionIds: initialTombstoneSessionIds,
            generation: tombstoneGeneration,
          ) ??
          const [],
      onCancelledTurn: cancelledTurnStore == null
          ? null
          : (tombstone) {
              final aliases = <String>{...initialTombstoneSessionIds};
              final storedId = chat.storedSessionId;
              if (storedId != null && storedId.isNotEmpty) {
                aliases.add(storedId);
              }
              return cancelledTurnStore.addAliases(
                connectionId: connection.id,
                profile: owner,
                sessionIds: aliases,
                tombstone: tombstone,
                generation: tombstoneGeneration,
              );
            },
    );
    _chats[key] = chat;
    final seed =
        sessionSnapshot ??
        Session(
          id: sessionId,
          title: sessionTitle,
          model: '',
          source: 'mobile',
          messageCount: 0,
          isActive: false,
          preview: '',
          startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
        );
    final metadata = _HomeWidgetChatMetadata.fromSession(seed);
    final provider = _nonEmptyWidgetText(selectedProvider);
    if (provider != null && provider != 'gateway') {
      metadata.provider = provider;
    }
    _homeWidgetMetadata[chat] = metadata;
    _publishHomeWidgetChat(chat);
    return chat;
  }

  /// Un run arrancó: registra la vigilancia en 2º plano y levanta el foreground
  /// service. Esto mantiene vivo el proceso (y con él el isolate de UI que
  /// corre el SSE) mientras el agente responde, aunque el usuario salga de la
  /// app, bloquee o apague la pantalla. Si el SO matase el proceso igualmente,
  /// el isolate del servicio sigue sondeando el run y avisa al terminar.
  Future<void> _onRunStarted(String key, String runId) async {
    final chat = _chats[key];
    if (chat == null) return;
    // Registrar en RunRegistry para que Task Center (Ejecuciones) vea los runs
    // lanzados desde el chat, no solo los de RunsTab. Es un añadido puro:
    // si prefs es null (tests) se omite sin efecto. RunRegistry.add es idempotente.
    final prefs = _prefs;
    if (prefs != null) {
      try {
        final registry = await RunRegistry.load(prefs, chat.connection.id);
        await registry.add(
          RunRecord(
            runId: runId,
            prompt: chat.lastPrompt,
            sessionId: chat.sessionId,
            createdAt: DateTime.now().millisecondsSinceEpoch / 1000,
            lastStatus: 'queued',
            connId: chat.connection.id,
            profile: chat.sessionProfile,
          ),
        );
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[active-chat] run registry add unavailable '
            '(${error.runtimeType})',
          );
        }
      }
    }
    try {
      await BackgroundWatch.add(
        SavedRunWatch(
          connId: chat.connection.id,
          profile: chat.sessionProfile,
          base: chat.connection.baseUrl,
          runId: runId,
          prompt: chat.lastPrompt,
          sessionId: chat.sessionId,
        ),
      );
      await BackgroundListener.ensureAutomationForeground();
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[active-chat] foreground start unavailable '
          '(${error.runtimeType})',
        );
      }
    }
    _refreshActiveIds();
  }

  void requestImmediateTransportRecovery() {
    for (final chat in _chats.values) {
      chat.requestImmediateTransportRecovery();
    }
  }

  /// Reconciliación global al volver de 2º plano: re-sincroniza cualquier chat
  /// cuyo stream pudiera haberse cortado mientras la app estaba suspendida.
  Future<void> reconcileAfterResume() async {
    final chats = _chats.values.toList(growable: false);
    final reserved = <ActiveChat>{};
    for (final chat in chats) {
      chat._reserveResumeReconciliation();
      reserved.add(chat);
    }
    try {
      for (final chat in chats) {
        try {
          await chat.reconcileAfterResume();
        } finally {
          chat._releaseResumeReconciliation();
          reserved.remove(chat);
        }
      }
    } finally {
      for (final chat in reserved) {
        chat._releaseResumeReconciliation();
      }
    }
  }

  /// Relee únicamente el chat que coincide con la identidad durable publicada
  /// por la biblioteca. `sessions.changed` no documenta IDs en su payload; la
  /// pantalla resuelve primero la fila cambiada mediante REST y entrega aquí su
  /// id físico y su lineage. Una coincidencia ambigua falla cerrada.
  Future<bool> invalidateDurableSession({
    required String connectionId,
    required String profile,
    required String sessionId,
    String? logicalSessionId,
  }) {
    final owner = Session.profileOwner(profile);
    final requestedIds = <String>{
      if (sessionId.trim().isNotEmpty) sessionId.trim(),
      if (logicalSessionId?.trim().isNotEmpty == true) logicalSessionId!.trim(),
    };
    if (connectionId.isEmpty || requestedIds.isEmpty) {
      return Future<bool>.value(false);
    }
    ActiveChat? match;
    for (final chat in _chats.values) {
      if (chat.connection.id != connectionId || chat.sessionProfile != owner) {
        continue;
      }
      final chatIds = <String>{
        chat.sessionId,
        chat.logicalSessionId,
        chat.serverSessionId,
        if (chat.storedSessionId?.isNotEmpty == true) chat.storedSessionId!,
      };
      if (!chatIds.any(requestedIds.contains)) continue;
      if (match != null && !identical(match, chat)) {
        return Future<bool>.value(false);
      }
      match = chat;
    }
    return match?.reconcileAfterResume() ?? Future<bool>.value(false);
  }

  Future<void> suspendIdleConnections() async {
    await Future.wait(
      _chats.values.map((chat) => chat.suspendIdleDesktopConnection()),
    );
  }

  /// Suelta el chat al cerrar la pantalla: si NO está en streaming, lo libera
  /// (cierra el cliente HTTP); si está en streaming, lo deja correr en segundo
  /// plano (se reaprovechará al volver y se reapará al terminar sin oyentes).
  void release(String connectionId, String sessionId, {String? profile}) {
    final entry = _entryFor(connectionId, sessionId, profile: profile);
    if (entry == null) return;
    final chat = entry.value;
    _rememberSteerProjections(chat);
    chat.requestReleaseWhenUnused();
    if (chat.sessionActivity.active ||
        chat.hasPendingBackgroundProcessRefresh ||
        chat.hasPendingDurableCancellation ||
        chat.hasListeners ||
        chat.voiceBargeHandoffPending ||
        chat.showReleaseToDesktopControl) {
      _refreshActiveIds();
      return;
    }
    _dispose(entry.key);
  }

  void _onChatUnused(String key) {
    final chat = _chats[key];
    if (chat == null ||
        !chat.releaseRequested ||
        chat.sessionActivity.active ||
        chat.hasPendingBackgroundProcessRefresh ||
        chat.hasPendingDurableCancellation ||
        chat.hasListeners ||
        chat.voiceBargeHandoffPending ||
        chat.showReleaseToDesktopControl) {
      return;
    }
    _dispose(key);
  }

  /// Marca el inicio de un envío: registra la sesión como activa.
  void markStarted(String connectionId, String sessionId) =>
      _refreshActiveIds();

  void _onChatTerminal(String key) {
    final chat = _chats[key];
    if (chat != null) {
      _rememberObservedFirstTokenLatency(
        chat,
        chat.observedFirstTokenLatencyMs,
      );
    }
    _refreshActiveIds();
    // El run terminó: deja de vigilarlo en 2º plano y, si ya no queda ningún
    // run activo, baja el foreground service.
    final runId = chat?.currentRunId;
    if (runId != null && chat != null) {
      BackgroundWatch.remove(
        runId,
        connId: chat.connection.id,
        profile: chat.sessionProfile,
      );
    }
    _maybeStopForeground();
    if (chat == null) return;
    final processRefresh = chat.refreshBackgroundProcesses();
    unawaited(
      processRefresh.whenComplete(() => _settleTerminalChat(key, chat)),
    );
  }

  void _settleTerminalChat(String key, ActiveChat chat) {
    if (!identical(_chats[key], chat) ||
        chat.sessionActivity.active ||
        chat.hasPendingBackgroundProcessRefresh ||
        chat.hasPendingDurableCancellation ||
        chat.hasListeners ||
        chat.voiceBargeHandoffPending ||
        chat.showReleaseToDesktopControl) {
      return;
    }
    _dispose(key);
  }

  /// Baja el foreground service salvo que (a) el usuario activó la escucha
  /// permanente opt-in, o (b) aún hay otro run en curso.
  Future<void> _maybeStopForeground() async {
    if (_chats.values.any((c) => c.isStreaming)) return;
    // El modo voz puede seguir hablando en 2º plano tras completar el run.
    if (keepAliveWhile?.call() ?? false) return;
    try {
      if (await BackgroundListener.isEnabled()) return;
      await BackgroundListener.releaseIdleRuntime();
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[active-chat] foreground stop unavailable '
          '(${error.runtimeType})',
        );
      }
    }
  }

  void _rememberSteerProjections(ActiveChat chat) {
    final sessionIds = <String>{chat.sessionId};
    final storedId = chat.storedSessionId;
    if (storedId != null && storedId.isNotEmpty) sessionIds.add(storedId);
    final projections = chat.steerProjections;
    for (final id in sessionIds) {
      final key = _projectionKey(
        chat.connection.id,
        id,
        profile: chat.sessionProfile,
      );
      if (projections.isEmpty) {
        _steerProjectionCache.remove(key);
      } else {
        _steerProjectionCache[key] = List<SteerProjection>.of(projections);
      }
    }
    // Memoria acotada: son proyecciones de UI, no un transcript local.
    while (_steerProjectionCache.length > 32) {
      _steerProjectionCache.remove(_steerProjectionCache.keys.first);
    }
  }

  void _dispose(String key) {
    final chat = _chats.remove(key);
    if (chat != null) {
      _homeWidgetMetadata.remove(chat);
      _rememberSteerProjections(chat);
      _rememberObservedFirstTokenLatency(
        chat,
        chat.observedFirstTokenLatencyMs,
      );
    }
    chat?.dispose();
    _refreshActiveIds();
  }

  void _refreshActiveIds({bool force = false}) {
    if (_disposed) return;
    final ids = <String>{};
    for (final entry in _chats.entries) {
      if (!entry.value.sessionActivity.active) continue;
      final profile = entry.value.sessionProfile;
      ids.add(
        _registryKey(entry.value.connection.id, entry.value.sessionId, profile),
      );
      final storedId = entry.value.storedSessionId;
      if (storedId != null && storedId.isNotEmpty) {
        ids.add(_registryKey(entry.value.connection.id, storedId, profile));
      }
    }
    if (force ||
        ids.length != activeIds.value.length ||
        !ids.containsAll(activeIds.value)) {
      activeIds.value = ids;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final chat in _chats.values) {
      chat.dispose();
    }
    _chats.clear();
    _homeWidgetMetadata.clear();
    _observedFirstTokenLatencyCache.clear();
    globalActivity.dispose();
    activeIds.dispose();
  }
}
