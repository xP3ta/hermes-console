import 'bot_room_link.dart';
import 'bot_mention_roster.dart';
import 'bot_profile_client.dart';
// Cliente del protocolo oficial usado por Hermes Desktop y el Dashboard.
//
// Transporte: WebSocket `/api/ws` + JSON-RPC 2.0. A diferencia de `/v1/runs`,
// este canal conserva una referencia al AIAgent vivo y expone
// `session.redirect` (con `session.steer` solo para compatibilidad antigua).
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random, min;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/command_descriptor.dart';
import '../models/agent_profile.dart';
import '../models/admin_integrations.dart';
import '../models/bot_visual_identity.dart';
import '../models/desktop_active_session.dart';
import '../models/desktop_compression_result.dart';
import '../models/desktop_compression_outcome.dart';
import '../models/desktop_control_center.dart';
import '../models/desktop_context_breakdown.dart';
import '../models/desktop_model_catalog.dart';
import '../models/desktop_session_config.dart';
import '../models/desktop_session_snapshot.dart';
import '../models/interactive_prompt.dart';
import '../models/hosted_groups.dart';
import '../models/profile_pet.dart';
import 'capability_payload_sanitizer.dart';
import 'connection_manager.dart';
import 'desktop_control_gateway.dart';
import 'desktop_gateway_capabilities.dart';
import 'json_rpc_wire.dart';
import 'recovery_proof.dart';
import 'replay_batch_proof.dart';
import 'replay_coordinator.dart';
import '../utils/transport_privacy.dart';

class TuiGatewayRpcError implements Exception {
  final String method;
  final int? code;
  final String message;
  final Map<String, dynamic> data;
  final CompressionFailureOrigin origin;
  final TuiGatewayRpcFailureKind? failureKind;
  CompressionFailureReason get compressionReason =>
      data['reason'] == 'SESSION_NOT_OWNED'
      ? CompressionFailureReason.sessionNotOwned
      : data['reason'] == 'EXCLUSIVE_SUBMIT_CAPABILITY_DENIED'
      ? CompressionFailureReason.exclusiveSubmitCapabilityDenied
      : CompressionFailureReason.unknown;

  const TuiGatewayRpcError(
    this.method,
    this.message, {
    this.code,
    this.data = const <String, dynamic>{},
    this.origin = CompressionFailureOrigin.unknown,
    this.failureKind,
  });

  String? get reason {
    final value = data['reason'];
    if (value is! String) return null;
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }

  /// Local roster proof that the durable session has no live runtime: Hermes
  /// reaped it (for example after its orphan grace window) and nothing is
  /// left to rejoin. It is neither a transport failure nor an identity fault.
  bool get rosterSessionNotActive =>
      origin == CompressionFailureOrigin.localPreflight &&
      data['reason'] == rosterSessionNotActiveReason;

  @override
  String toString() => 'TuiGatewayRpcError($method, $code): $message';
}

const String rosterSessionNotActiveReason = 'ROSTER_SESSION_NOT_ACTIVE';

/// Non-sensitive local failure metadata for policies that must not inspect copy.
enum TuiGatewayRpcFailureKind { timeout, connectionLost }

abstract final class SanitizedRpcFailureFactory {
  static final Object _certificate = Object();
  static const Set<String> sensitiveMethods = {
    'sudo.respond',
    'secret.respond',
  };

  static TuiGatewayRpcError remote(String method, {int? safeCode}) {
    _requireSensitive(method);
    return _SanitizedRpcFailure(
      _certificate,
      method,
      'Hermes rejected the sensitive response',
      code: safeCode,
      origin: CompressionFailureOrigin.remoteRpc,
    );
  }

  static TuiGatewayRpcError transport(String method) {
    _requireSensitive(method);
    return _SanitizedRpcFailure(
      _certificate,
      method,
      'Sensitive response transport failed',
      failureKind: TuiGatewayRpcFailureKind.connectionLost,
    );
  }

  static TuiGatewayRpcError timeout(String method) {
    _requireSensitive(method);
    return _SanitizedRpcFailure(
      _certificate,
      method,
      'Timeout waiting for sensitive response',
      failureKind: TuiGatewayRpcFailureKind.timeout,
    );
  }

  static bool isCertified(Object error) =>
      error is _SanitizedRpcFailure &&
      identical(error._certificate, _certificate);

  static void _requireSensitive(String method) {
    if (!sensitiveMethods.contains(method)) {
      throw ArgumentError.value(method, 'method', 'not a sensitive RPC method');
    }
  }
}

final class _SanitizedRpcFailure extends TuiGatewayRpcError {
  final Object _certificate;

  const _SanitizedRpcFailure(
    this._certificate,
    super.method,
    super.message, {
    super.code,
    super.origin,
    super.failureKind,
  });
}

class GatewayReconnectBackoff {
  static const stableInterval = Duration(seconds: 30);
  static const _baseDelay = Duration(seconds: 1);
  static const _maximumDelay = Duration(seconds: 15);

  final double Function() _random;
  int _attempt = 0;

  GatewayReconnectBackoff({double Function()? random})
    : _random = random ?? Random().nextDouble;

  Duration nextDelay() {
    final exponent = _attempt.clamp(0, 6);
    _attempt += 1;
    final ceilingMs = min(
      _baseDelay.inMilliseconds * (1 << exponent),
      _maximumDelay.inMilliseconds,
    );
    final jitter = (_random().clamp(0.0, 1.0) * ceilingMs).floor();
    return Duration(milliseconds: jitter);
  }

  void markHealthy() => _attempt = 0;
}

class TuiGatewayEvent {
  final String type;
  final String sessionId;
  final int? sequence;
  final int? transportGeneration;
  final Object? producerChannel;
  final Map<String, dynamic> payload;

  const TuiGatewayEvent({
    required this.type,
    required this.sessionId,
    this.sequence,
    this.transportGeneration,
    this.producerChannel,
    required this.payload,
  });
}

int? _protocolInteger(Object? value, {bool positive = false}) {
  try {
    return SafeJsonInt.require(value, positive: positive);
  } on JsonRpcWireFormatException {
    return null;
  }
}

/// Alias compatible con los consumidores legacy. Los gateways reales devuelven
/// ahora también el snapshot tipado completo de Hermes Agent 0.19.
class DesktopSessionBinding extends DesktopSessionSnapshot {
  const DesktopSessionBinding({
    required super.runtimeSessionId,
    required super.storedSessionId,
    super.storedSessionIdProvenance,
    required super.created,
    super.lineageRootId,
    super.identityAliasesConsistent,
    super.storedSessionIdentityExplicit,
    super.messages,
    super.messagesProvided,
    super.messagesFullyParsed,
    super.messageCount,
    super.hydrating,
    super.inflight,
    super.queued,
    super.pendingClarify,
    super.pendingClarifyProvided,
    super.pendingApproval,
    super.pendingApprovalProvided,
    super.todoState,
    super.running,
    super.status,
    super.startedAt,
    super.turnStartedAt,
    super.info,
    super.raw,
  });

  factory DesktopSessionBinding.fromSnapshot(DesktopSessionSnapshot snapshot) {
    return DesktopSessionBinding(
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
      inflight: snapshot.inflight,
      queued: snapshot.queued,
      pendingClarify: snapshot.pendingClarify,
      pendingClarifyProvided: snapshot.pendingClarifyProvided,
      pendingApproval: snapshot.pendingApproval,
      pendingApprovalProvided: snapshot.pendingApprovalProvided,
      todoState: snapshot.todoState,
      running: snapshot.running,
      status: snapshot.status,
      startedAt: snapshot.startedAt,
      turnStartedAt: snapshot.turnStartedAt,
      info: snapshot.info,
      raw: snapshot.raw,
    );
  }
}

/// Interfaz pequeña para poder probar [ActiveChat] sin abrir sockets reales.
abstract class HermesDesktopGateway {
  Stream<TuiGatewayEvent> get events;
  bool get isConnected;

  Future<void> connect();

  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  });

  Future<void> submitPrompt(String runtimeSessionId, String text);

  Future<void> steer(String runtimeSessionId, String text);

  Future<void> interrupt(String runtimeSessionId);

  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  });

  Future<void> close();
}

/// Optional read surface; legacy transports retain their REST fallback.
abstract class HermesDesktopSessionHistoryGateway {
  /// [sessionId] is the runtime returned by resume/activate, never a stored id.
  Future<SessionMessagesPage> sessionHistory({
    required String sessionId,
    String? profile,
  });
}

final class DesktopApprovalResult {
  final int resolved;

  const DesktopApprovalResult({required this.resolved});

  factory DesktopApprovalResult.fromJson(Map<String, dynamic> json) {
    final resolved = json['resolved'];
    if (resolved is! int || (resolved != 0 && resolved != 1)) {
      throw const FormatException('invalid approval response');
    }
    return DesktopApprovalResult(resolved: resolved);
  }
}

/// Optional checked approval response. Legacy gateway doubles may keep the
/// original void API while real Desktop transports expose first-wins evidence.
abstract class HermesDesktopApprovalResultGateway {
  Future<DesktopApprovalResult> resolveApprovalChecked(
    String runtimeSessionId,
    String choice, {
    required String requestId,
  });
}

/// Fail-closed admission proof required before any RPC that can acquire or
/// mutate a live session runtime.
abstract class HermesDesktopExclusiveSubmitCapabilityGateway {
  Future<void> ensureExclusiveSubmitCapability();
}

/// Corrección de un turno vivo con la semántica actual de Hermes Desktop.
///
/// `session.redirect` conserva herramientas y trabajo completado, pero vuelve
/// a pedir al modelo que continúe teniendo en cuenta el nuevo texto. Se
/// mantiene como capacidad separada para no romper gateways antiguos que solo
/// implementan `session.steer`.
abstract class HermesDesktopRedirectGateway {
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  );
}

enum DesktopRedirectDisposition { redirected, queued, rejected }

/// Envío que sigue a una interrupción de la reproducción de voz.
///
/// Hermes Desktop marca ese turno con `interrupted: true`; Hermes Agent usa la
/// señal únicamente en el mensaje destinado al modelo para aclarar que la
/// respuesta anterior no llegó a oírse completa. El texto persistido y visible
/// permanece intacto.
abstract class HermesDesktopInterruptedPromptGateway {
  Future<void> submitInterruptedPrompt(String runtimeSessionId, String text);
}

/// Lifecycle moderno y explícito de sesión.
///
/// Se mantiene fuera de [HermesDesktopGateway] para no romper gateways/fakes
/// antiguos. Recuperación, warm-up y apertura de historial deben usar
/// [resumeExisting], que jamás cae implícitamente en `session.create`.
/// [createForFirstSubmit] queda reservado al primer envío de un borrador.
abstract class HermesDesktopSessionLifecycleGateway {
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    // Hermes Agent 0.20 puede devolver un ack inmediato y completar la
    // hidratación mediante `session.resume_progress`. Solicitamos los
    // mensajes (`omitMessages=false`) y además reparamos abajo los markers
    bool deferHistory = false,
  });

  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  });
}

/// Optional exact runtime release. It is separate to preserve old fakes and
/// must only be called after the owner has revalidated release authority.
abstract class HermesDesktopSessionCloseGateway {
  Future<bool> closeSession(String runtimeSessionId);
}

/// Recovery-only resume whose runtime anchor is committed by the caller only
/// after its turn generation is still current.
abstract class HermesDesktopRecoverySessionLifecycleGateway {
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  });

  /// Legacy callers cannot demonstrate snapshot coverage and therefore never
  /// release quarantine.
  @Deprecated('Use HermesDesktopTypedRecoveryGateway')
  void commitRecoveryRuntime(String runtimeSessionId);
}

/// Exact-transport recovery attachment authorized by a fresh active roster.
///
/// Implementations must obtain `session.active_list` and `session.resume` on
/// one unchanged socket/channel/replay epoch and reject absent, duplicate,
/// malformed, or identity-mismatched rows without reconnecting in between.
/// An absent row is reported with [TuiGatewayRpcError.rosterSessionNotActive].
abstract class HermesDesktopRosterBoundRecoveryGateway {
  Future<DesktopRosterBoundRecovery> resumeAdvertisedExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  });

  bool consumeRosterBoundRecovery(DesktopRosterBoundRecovery recovery);

  bool consumeRosterBoundViewerAttachment(DesktopRosterBoundRecovery recovery);
}

final class DesktopRosterBoundRecovery {
  final DesktopSessionSnapshot snapshot;
  final Object _issuer;
  final Object? _transportProof;
  bool _consumed = false;

  DesktopRosterBoundRecovery._(
    this.snapshot,
    this._issuer,
    this._transportProof,
  );

  @visibleForTesting
  DesktopRosterBoundRecovery.forTesting(this.snapshot, Object issuer)
    : _issuer = issuer,
      _transportProof = null;
}

/// Optional typed authority boundary layered over the legacy recovery API.
/// Keeping it separate preserves source compatibility for existing gateways
/// while ensuring a runtime String can never release quarantine.
abstract class HermesDesktopTypedRecoveryGateway {
  RecoveryProof recoveryProofForSnapshot(
    DesktopSessionSnapshot snapshot, {
    required String connectionId,
    required String profile,
    required int bindGeneration,
    required int sessionGeneration,
    required int turnGeneration,
    required Set<RecoveryDomain> coverage,
    int? postSnapshotSequence,
  });

  bool validateRecovery(RecoveryProof proof);
  bool commitRecovery(RecoveryProof proof);
  bool recoveryAuthorityStillCurrent(RecoveryProof proof);
}

/// Atomic first-submit creation with the 0.19 session-scoped configuration.
///
/// This remains a separate optional interface so older gateway fakes and
/// servers stay compatible. There is deliberately no global fallback.
abstract class HermesDesktopConfiguredSessionLifecycleGateway {
  Future<DesktopSessionSnapshot> createForFirstSubmitConfigured({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    required DesktopSessionCreateConfig config,
  });
}

/// Lifecycle opcional para soltar un socket idle sin inutilizar el cliente.
abstract class HermesDesktopLifecycleGateway {
  Future<void> disconnectIdle();
}

enum DesktopPromptResponseStatus { ok, expired }

final class DesktopPromptResponse {
  final DesktopPromptResponseStatus status;

  const DesktopPromptResponse._(this.status);

  bool get isExpired => status == DesktopPromptResponseStatus.expired;

  factory DesktopPromptResponse.fromJson(
    Map<String, dynamic> json, {
    required String method,
    bool allowExpired = false,
  }) {
    final status = json['status'];
    if (status == 'ok') {
      return const DesktopPromptResponse._(DesktopPromptResponseStatus.ok);
    }
    if (allowExpired && status == 'expired') {
      return const DesktopPromptResponse._(DesktopPromptResponseStatus.expired);
    }
    throw TuiGatewayRpcError(
      method,
      'Hermes returned an invalid interactive prompt response',
    );
  }
}

/// RPC opcional para los prompts bloqueantes introducidos por Desktop 0.19.
///
/// Los cuatro métodos se correlacionan solo por el `request_id` opaco que
/// entrega Hermes. Sudo y secretos aceptan un contenedor de un solo uso: el
/// transporte lo consume y redacta antes de esperar la respuesta del servidor.
abstract class HermesDesktopInteractivePromptGateway {
  Future<DesktopPromptResponse> respondToClarify(
    String requestId,
    String answer, {
    String? questionId,
  });

  Future<DesktopPromptResponse> respondToSudo(
    String requestId,
    EphemeralSensitiveValue password,
  );

  Future<DesktopPromptResponse> respondToSecret(
    String requestId,
    EphemeralSensitiveValue value,
  );

  /// La app móvil no posee una terminal administrada. Este RPC responde
  /// siempre con texto vacío para desbloquear el runtime sin leer el sistema.
  Future<DesktopPromptResponse> respondToTerminalRead(String requestId);
}

/// Session-scoped configuration introduced by Hermes Desktop 0.19.
///
/// Implementations must target the live runtime. There is deliberately no
/// global fallback in this interface.
abstract class HermesDesktopSessionConfigGateway {
  Future<DesktopConfigSetResult> setSessionModel(
    String runtimeSessionId,
    DesktopModelSelection selection, {
    bool confirmExpensiveModel = false,
  });

  Future<DesktopConfigSetResult> setSessionReasoning(
    String runtimeSessionId,
    DesktopReasoningEffort effort,
  );

  Future<DesktopConfigSetResult> setSessionFastMode(
    String runtimeSessionId,
    DesktopFastMode mode,
  );
}

/// Optional live-session switching and inventory from Hermes Desktop 0.19.
///
/// Activation targets a known live runtime. Callers must fall back to
/// `resumeExisting` with the durable identity when activation returns 4007 or
/// the capability is unavailable; this interface never creates a session.
abstract class HermesDesktopSessionActivityGateway {
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  );

  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  });

  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  });
}

/// Authenticated provider/model catalog scoped to an existing live runtime.
abstract class HermesDesktopModelCatalogGateway {
  Future<DesktopModelCatalog> modelOptions(
    String runtimeSessionId, {
    bool refresh = false,
  });
}

/// Desglose opcional de la ventana de contexto del runtime vivo.
///
/// Se mantiene separado del gateway base para conservar compatibilidad con
/// servidores y fakes anteriores a Desktop 0.19.
abstract class HermesDesktopContextUsageGateway {
  Future<DesktopContextBreakdown> contextBreakdown(String runtimeSessionId);
}

/// Lectura y escritura opcional de la identidad visual server-side de un
/// profile (avatar raster + metadatos `hermes-bots` de Bot Mode).
///
/// Se mantiene fuera del gateway base para que backends y dobles anteriores a
/// Hermes 0.20 sigan degradando sin exigir estos RPC.
abstract class HermesDesktopProfileAssetsGateway {
  Future<AgentProfileAvatar?> profileAvatar(String profileName);

  /// Persiste título/apariencia/visibilidad del bot en `hermes-bots` de
  /// `ui_meta` (`profiles.configure`). Los parámetros a `null` no se tocan;
  /// `false` en [hidden] o [pinned] se persiste literalmente y un [title]
  /// vacío elimina la clave. La escritura es read-modify-write: Hermes
  /// reemplaza el namespace entero, así que los campos ajenos (`chat`,
  /// `group`, …) se conservan desde una lectura fresca.
  Future<void> saveProfileBotMeta({
    required String profile,
    String? title,
    String? shape,
    String? colorHex,
    bool? hidden,
    bool? pinned,
    BotVisualIdentity? identity,
  });

  /// Escribe el avatar raster del profile (`profiles.set_asset`); [dataUri]
  /// debe ser un data URI PNG/JPEG/WebP dentro de las cotas de
  /// [AgentProfileAvatar].
  Future<void> setProfileAvatar({
    required String profile,
    required String dataUri,
  });

  /// Borra el avatar del profile (`profiles.set_asset` con `clear: true`).
  Future<void> clearProfileAvatar(String profile);
}

/// Skill de un profile según `profiles.describe` (Hermes 0.20, Bot Mode).
final class DesktopProfileSkill {
  final String name;
  final bool enabled;

  const DesktopProfileSkill({required this.name, required this.enabled});
}

/// Creación de bots con paridad Bot Mode de Hermes Desktop
/// (`CreateAgentDialog`): `profiles.create` con clonación/SOUL/modelo en una
/// sola escritura, catálogo opcional de skills vía `profiles.describe` y
/// `profiles.configure` para desactivar skills tras crear.
///
/// Interfaz opcional como el resto de capacidades Desktop: un gateway sin
/// `profiles.describe` degrada devolviendo `null` en
/// [describeProfileSkills] y el diálogo oculta la sección de skills.
abstract class HermesDesktopBotCreationGateway {
  Future<void> createProfileNative({
    required String name,
    String? cloneFrom,
    String description,
    String soul,
    String model,
    String provider,
    bool noSkills,
    bool shareAuth,
  });

  /// Misma escritura que [HermesDesktopProfileAssetsGateway.saveProfileBotMeta]
  /// más el sello `created` (epoch ms) que Desktop usa para ordenar el roster
  /// por actividad reciente (un bot recién creado encabeza la lista).
  Future<void> saveProfileBotMeta({
    required String profile,
    String? title,
    String? shape,
    String? colorHex,
    bool? hidden,
    bool? pinned,
    int? createdAtMs,
    BotVisualIdentity? identity,
  });

  /// Skills del profile origen de clonación, o `null` cuando el gateway no
  /// expone `profiles.describe` (-32601).
  Future<List<DesktopProfileSkill>?> describeProfileSkills(String profile);

  /// Aplica las skills desmarcadas en el diálogo de creación
  /// (`profiles.configure` con `disabled_skills`). Best-effort en el llamador,
  /// igual que en Desktop: el profile ya existe aunque esto falle.
  Future<void> setProfileDisabledSkills({
    required String profile,
    required List<String> disabledSkills,
  });
}

/// Mascotas nativas por perfil de Hermes Agent (RPCs `pet.*`).
///
/// Interfaz opcional (mismo patrón que el resto de capacidades Desktop): los
/// gateways antiguos sin estos métodos fallan cerrados con `-32601`, igual que
/// el manejo de Bot Mode. Todas las llamadas aceptan `profile`; vacío = perfil
/// de arranque del gateway (upstream: `_profile_scoped` en
/// `tui_gateway/server.py`).
abstract class HermesDesktopPetGateway {
  Stream<TuiGatewayEvent> get events;

  Future<ProfilePetInfo> profilePetInfo({
    String profile = '',
    String? knownRevision,
  });

  Future<ProfilePetGallery> profilePetGallery({
    String profile = '',
    bool localOnly = false,
  });

  Future<String?> profilePetThumb({
    String profile = '',
    required String slug,
    String url = '',
  });

  Future<ProfilePetSelection> profilePetSelect({
    String profile = '',
    required String slug,
  });

  Future<bool> profilePetDisable({String profile = ''});
}

/// Catálogo, completion y dispatch usados por las superficies Desktop.
///
/// Es una interfaz opcional para no ampliar [HermesDesktopGateway] ni romper
/// dobles antiguos del chat.
abstract class HermesDesktopCommandGateway {
  Future<DesktopCommandCatalog> commandsCatalog();

  Future<SlashCompletionBatch> completeSlash(String text);

  Future<DesktopCommandRpcResult> slashExec(
    String runtimeSessionId,
    String command,
  );

  Future<DesktopCommandRpcResult> commandDispatch(
    String runtimeSessionId, {
    required String name,
    String arg = '',
  });
}

/// Read-only replay ring of one runtime (`session.events.since`,
/// `last_seen: 0`). Lets a relaunched client learn whether a compression that
/// runtime ran is still pinned, without resuming or stealing it.
abstract class HermesDesktopCompressionStatusGateway {
  Future<Map<String, dynamic>> compressionEventReplay(String runtimeSessionId);
}

/// Compresión manual y explícita de una sesión inactiva.
///
/// Es opcional para mantener compatibles servidores y dobles anteriores a 0.19.
abstract class HermesDesktopCompressionGateway {
  Future<DesktopCompressionResult> compressSession(
    String runtimeSessionId, {
    String focusTopic = '',
  });
}

final class DesktopSubagentInterruptResult {
  final bool found;
  final String subagentId;

  const DesktopSubagentInterruptResult({
    required this.found,
    required this.subagentId,
  });

  factory DesktopSubagentInterruptResult.fromJson(
    Map<String, dynamic> json, {
    required String requestedSubagentId,
  }) {
    final found = json['found'];
    final returnedId = json['subagent_id'];
    if (found is! bool || returnedId != requestedSubagentId) {
      throw const FormatException('invalid subagent interrupt result');
    }
    return DesktopSubagentInterruptResult(
      found: found,
      subagentId: requestedSubagentId,
    );
  }
}

final class DesktopSubagentSnapshot {
  static const _liveStatuses = <String>{
    'requested',
    'queued',
    'running',
    'active',
    'thinking',
    'tool',
    'using_tool',
  };

  final String subagentId;
  final String? parentId;
  final int? depth;
  final String? goal;
  final String? delegationId;
  final String? model;
  final DateTime? startedAt;
  final String status;
  final int? toolCount;
  final String? lastTool;
  final bool? acceptingSteer;

  const DesktopSubagentSnapshot({
    required this.subagentId,
    required this.status,
    this.parentId,
    this.depth,
    this.goal,
    this.delegationId,
    this.model,
    this.startedAt,
    this.toolCount,
    this.lastTool,
    this.acceptingSteer,
  });

  static DesktopSubagentSnapshot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final json = <String, dynamic>{};
    for (final entry in raw.entries) {
      if (entry.key is String) json[entry.key as String] = entry.value;
    }
    final subagentId = _subagentOpaqueId(json['subagent_id']);
    final statusValue = json['status'];
    if (subagentId == null || statusValue is! String) return null;
    final status = statusValue.trim().toLowerCase();
    if (!_liveStatuses.contains(status)) return null;
    final toolCount = json['tool_count'];
    final acceptingSteer = json['accepting_steer'];
    final startedAt = _subagentTimestamp(json['started_at']);
    return DesktopSubagentSnapshot(
      subagentId: subagentId,
      parentId: _subagentOpaqueId(json['parent_id']),
      depth: _subagentNonNegativeInt(json['depth']),
      goal: _boundedSubagentText(json['goal'], 1024),
      delegationId: _subagentOpaqueId(json['delegation_id']),
      model: _boundedSubagentText(json['model'], 160),
      startedAt: startedAt,
      status: status,
      toolCount: toolCount is int && toolCount >= 0 ? toolCount : null,
      lastTool: _boundedSubagentText(json['last_tool'], 128),
      acceptingSteer: acceptingSteer is bool ? acceptingSteer : null,
    );
  }

  @override
  String toString() => 'DesktopSubagentSnapshot(status: $status)';
}

final class DesktopSubagentTailResult {
  final bool available;
  final String content;
  final bool truncated;

  const DesktopSubagentTailResult({
    required this.available,
    required this.content,
    required this.truncated,
  });

  factory DesktopSubagentTailResult.fromJson(Map<String, dynamic> json) {
    final available = json['available'];
    final serverTruncated = json['truncated'];
    if (available is! bool || serverTruncated is! bool) {
      throw const FormatException('invalid subagent tail result');
    }
    if (!available) {
      return const DesktopSubagentTailResult(
        available: false,
        content: '',
        truncated: false,
      );
    }
    final rawContent = json['text'] ?? json['content'];
    if (rawContent is! String) {
      throw const FormatException('invalid subagent tail content');
    }
    const limit = 16384;
    final runes = rawContent.runes;
    final clientTruncated = runes.length > limit;
    return DesktopSubagentTailResult(
      available: true,
      content: clientTruncated
          ? String.fromCharCodes(runes.skip(runes.length - limit))
          : rawContent,
      truncated: serverTruncated || clientTruncated,
    );
  }

  @override
  String toString() =>
      'DesktopSubagentTailResult(available: $available, truncated: $truncated)';
}

final class DesktopSubagentSteerResult {
  final String status;
  final String subagentId;
  final String text;

  const DesktopSubagentSteerResult({
    required this.status,
    required this.subagentId,
    required this.text,
  });

  bool get queued => status == 'queued';

  factory DesktopSubagentSteerResult.fromJson(
    Map<String, dynamic> json, {
    required String requestedSubagentId,
  }) {
    final status = json['status'];
    final text = json['text'];
    if (status is! String ||
        text is! String ||
        json['subagent_id'] != requestedSubagentId ||
        !const {'queued', 'rejected'}.contains(status)) {
      throw const FormatException('invalid subagent steer result');
    }
    return DesktopSubagentSteerResult(
      status: status,
      subagentId: requestedSubagentId,
      text: text,
    );
  }
}

String? _subagentOpaqueId(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.trim() != value ||
      value.length > 512 ||
      value.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
    return null;
  }
  return value;
}

String? _boundedSubagentText(Object? value, int maxCharacters) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return String.fromCharCodes(trimmed.runes.take(maxCharacters));
}

DateTime? _subagentTimestamp(Object? value) {
  if (value is String) return DateTime.tryParse(value)?.toUtc();
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

int? _subagentNonNegativeInt(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  final integer = value.toInt();
  return value == integer ? integer : null;
}

/// Control opcional y autenticado de un hijo nativo de Hermes 0.19.
///
/// No incluye la pausa global de delegación: esa mutación requiere una
/// superficie administrativa separada y nunca se ejecuta desde el chat.
abstract class HermesDesktopSubagentGateway {
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  );

  Future<List<DesktopSubagentSnapshot>> listSubagents(String runtimeSessionId);

  Future<DesktopSubagentTailResult> tailSubagent(
    String runtimeSessionId,
    String subagentId,
  );

  Future<DesktopSubagentSteerResult> steerSubagent(
    String runtimeSessionId,
    String subagentId,
    String text,
  );

  Future<DesktopSubagentInterruptResult> interruptSubagent(
    String runtimeSessionId,
    String subagentId,
  );
}

enum DesktopTurnState { accepted, running, terminal, failed, cancelled }

DesktopTurnState _parseDesktopTurnState(Object? raw, String method) {
  final value = raw?.toString() ?? '';
  return DesktopTurnState.values.firstWhere(
    (state) => state.name == value,
    orElse: () => throw TuiGatewayRpcError(
      method,
      'Hermes returned an invalid turn state',
    ),
  );
}

class DesktopTurnAck {
  final bool accepted;
  final String clientTurnId;
  final String serverTurnId;
  final DesktopTurnState state;
  final bool duplicate;

  const DesktopTurnAck({
    required this.accepted,
    required this.clientTurnId,
    required this.serverTurnId,
    required this.state,
    required this.duplicate,
  });

  factory DesktopTurnAck.fromJson(
    Map<String, dynamic> json, {
    required String expectedClientTurnId,
  }) {
    final echoed = (json['client_turn_id'] ?? '').toString();
    if (json['accepted'] != true || echoed != expectedClientTurnId) {
      throw const TuiGatewayRpcError(
        'prompt.submit',
        'Hermes returned an invalid idempotent acknowledgement',
      );
    }
    final serverTurnId = (json['server_turn_id'] ?? '').toString();
    if (serverTurnId.isEmpty) {
      throw const TuiGatewayRpcError(
        'prompt.submit',
        'Hermes omitted the server turn identity',
      );
    }
    final state = _parseDesktopTurnState(json['state'], 'prompt.submit');
    if (state != DesktopTurnState.accepted &&
        state != DesktopTurnState.running &&
        state != DesktopTurnState.terminal) {
      throw const TuiGatewayRpcError(
        'prompt.submit',
        'Hermes acknowledged a turn with an invalid state',
      );
    }
    final duplicate = json['duplicate'];
    if (duplicate is! bool) {
      throw const TuiGatewayRpcError(
        'prompt.submit',
        'Hermes omitted the duplicate flag',
      );
    }
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: echoed,
      serverTurnId: serverTurnId,
      state: state,
      duplicate: duplicate,
    );
  }
}

class DesktopTurnStatus {
  final bool known;
  final String clientTurnId;
  final String? serverTurnId;
  final DesktopTurnState? state;

  const DesktopTurnStatus({
    required this.known,
    required this.clientTurnId,
    this.serverTurnId,
    this.state,
  });

  factory DesktopTurnStatus.fromJson(
    Map<String, dynamic> json, {
    required String expectedClientTurnId,
  }) {
    final known = json['known'];
    final echoed = (json['client_turn_id'] ?? '').toString();
    if (known is! bool || echoed != expectedClientTurnId) {
      throw const TuiGatewayRpcError(
        'turn.status',
        'Hermes returned an invalid turn status',
      );
    }
    if (!known) {
      return DesktopTurnStatus(known: false, clientTurnId: echoed);
    }
    final serverTurnId = (json['server_turn_id'] ?? '').toString();
    if (serverTurnId.isEmpty) {
      throw const TuiGatewayRpcError(
        'turn.status',
        'Hermes omitted the known server turn identity',
      );
    }
    return DesktopTurnStatus(
      known: true,
      clientTurnId: echoed,
      serverTurnId: serverTurnId,
      state: _parseDesktopTurnState(json['state'], 'turn.status'),
    );
  }
}

/// Extensión opcional: comprobación inmediata del socket actual tras un cambio
/// de red o al volver de segundo plano. Un socket medio abierto en la red
/// antigua no espera al plazo completo del heartbeat.
abstract class HermesDesktopTransportProbeGateway {
  /// Devuelve true si el socket respondió; false si no había conexión o la
  /// sonda la declaró muerta (y ya se lanzó la ruta normal de error).
  Future<bool> probeNow();
}

/// Extensión opcional. La interfaz base permanece intacta para instalaciones y
/// fakes heredados; solo se usa tras una capability positiva autenticada.
abstract class HermesDesktopIdempotentGateway {
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  );

  Future<DesktopTurnStatus> getTurnStatus(
    String sessionId,
    String clientTurnId,
  );
}

abstract class HermesDesktopQueuedPromptGateway {
  Future<void> submitQueuedPrompt(String runtimeSessionId, String text);

  Future<DesktopTurnAck> submitQueuedPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  );
}

/// Identidad durable posterior a un `prompt.submit` que recorta.
///
/// Los gateways nuevos devuelven un mapa `old → new` por fila física
/// (`survivor_row_id_map`); los antiguos, los ids visibles de usuario en orden
/// de ordinal (`survivor_user_row_ids`). Un rewind reinserta el prefijo
/// conservado como filas SQLite NUEVAS, así que todo row id cacheado queda
/// obsoleto en cuanto aterriza.
class DesktopRewindAck {
  final List<int?>? survivorUserRowIds;

  /// `old row id → new row id` (o `null` si esa fila dejó de existir). Tiene
  /// precedencia sobre [survivorUserRowIds]: no depende de que el ordinal
  /// local y el del gateway coincidan.
  final Map<int, int?>? survivorRowIdMap;

  const DesktopRewindAck({this.survivorUserRowIds, this.survivorRowIdMap});

  factory DesktopRewindAck.fromJson(Map<String, dynamic> json) {
    final rawMap = json['survivor_row_id_map'];
    if (rawMap is Map) {
      final parsed = <int, int?>{};
      for (final entry in rawMap.entries) {
        final previous = entry.key is int
            ? entry.key as int
            : int.tryParse('${entry.key}');
        if (previous == null) continue;
        final next = entry.value;
        if (next == null) {
          parsed[previous] = null;
        } else if (next is int) {
          parsed[previous] = next;
        }
      }
      return DesktopRewindAck(survivorRowIdMap: parsed);
    }
    final raw = json['survivor_user_row_ids'];
    if (raw is! List) return const DesktopRewindAck();
    return DesktopRewindAck(
      survivorUserRowIds: raw
          .map<int?>((value) => value is int ? value : null)
          .toList(growable: false),
    );
  }
}

/// Capacidades añadidas por Hermes Desktop moderno. Se separan de la interfaz
/// base para que gateways antiguos y dobles de prueba sigan siendo válidos.
abstract class HermesDesktopRewindResolverGateway {
  Future<int?> resolveDurableUserRowId(
    String runtimeSessionId, {
    required String sourceText,
    required int expectedOrdinal,
  });
}

abstract class HermesDesktopRewindGateway {
  Future<void> submitRewindPrompt(
    String runtimeSessionId,
    String text,
    int truncateBeforeUserOrdinal,
  );
}

abstract class HermesDesktopDurableRewindGateway {
  /// [rebindSurvivorRowIds] son los row ids durables que el cliente todavía
  /// tiene cacheados. El gateway devuelve por ellos el mapa autoritativo
  /// `old → new`. Opcional a propósito: los dobles y gateways antiguos que no
  /// lo declaran siguen siendo válidos.
  Future<DesktopRewindAck> submitDurableRewindPrompt(
    String runtimeSessionId,
    String text,
    int truncateBeforeUserOrdinal, {
    required int truncateBeforeRowId,
    List<int> rebindSurvivorRowIds = const [],
  });
}

class DesktopAttachmentResult {
  final String? path;
  final String? refText;

  const DesktopAttachmentResult({this.path, this.refText});
}

abstract class HermesDesktopAttachmentGateway {
  Future<DesktopAttachmentResult> attachImageBytes(
    String runtimeSessionId, {
    required String filename,
    required String contentBase64,
  });

  Future<DesktopAttachmentResult> attachFileBytes(
    String runtimeSessionId, {
    required String filename,
    required String mimeType,
    required String contentBase64,
  });

  Future<void> detachImage(String runtimeSessionId, String path);
}

final class _GroupSocketLease {
  final int generation;
  final WebSocketChannel channel;

  const _GroupSocketLease({required this.generation, required this.channel});
}

final class _SessionRosterSocketLease {
  final int generation;
  final WebSocketChannel channel;
  final String? replayEpoch;

  const _SessionRosterSocketLease({
    required this.generation,
    required this.channel,
    required this.replayEpoch,
  });
}

class TuiGatewayClient
    implements
        HermesDesktopGateway,
        HermesDesktopCompressionStatusGateway,
        BotMentionRosterGateway,
        BotRoomLinkGateway,
        BotProfileGateway,
        BotAvatarGenerationGateway,
        HermesDesktopRedirectGateway,
        HermesDesktopInterruptedPromptGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSessionHistoryGateway,
        HermesDesktopSessionCloseGateway,
        HermesDesktopRecoverySessionLifecycleGateway,
        HermesDesktopRosterBoundRecoveryGateway,
        HermesDesktopTypedRecoveryGateway,
        HermesDesktopConfiguredSessionLifecycleGateway,
        HermesDesktopLifecycleGateway,
        HermesDesktopIdempotentGateway,
        HermesDesktopTransportProbeGateway,
        HermesDesktopQueuedPromptGateway,
        HermesDesktopRewindResolverGateway,
        HermesDesktopRewindGateway,
        HermesDesktopDurableRewindGateway,
        HermesDesktopAttachmentGateway,
        HermesDesktopInteractivePromptGateway,
        HermesDesktopSessionConfigGateway,
        HermesDesktopSessionActivityGateway,
        HermesDesktopModelCatalogGateway,
        HermesDesktopContextUsageGateway,
        HermesDesktopProfileAssetsGateway,
        HermesDesktopBotCreationGateway,
        HermesDesktopPetGateway,
        HermesDesktopCommandGateway,
        HermesDesktopCompressionGateway,
        HermesDesktopApprovalResultGateway,
        HermesDesktopSubagentGateway,
        HermesDesktopProcessStopGateway,
        HermesDesktopControlGateway,
        HermesDesktopSessionControlGateway,
        HermesExtensionManagementGateway,
        HermesMcpProvisioningGateway,
        HermesWebhookManagementGateway,
        HermesServerPlatformCapabilitiesGateway,
        HermesDesktopExclusiveSubmitCapabilityGateway {
  static const _transportTeardownBudget = Duration(seconds: 1);

  static String durableGroupEventId(String clientEventId) =>
      'user:${sha256.convert(utf8.encode(clientEventId))}';

  /// Hermes waits up to 660 seconds for compute-host compression before it
  /// returns the typed `pending` branch. Keep a small transport margin so a
  /// valid server reply is not abandoned first by Console.
  static const sessionCompressRpcTimeout = Duration(seconds: 690);

  final SavedConnection _connection;
  final DashboardClient _dashboard;
  final WebSocketChannel Function(Uri uri, Map<String, dynamic> headers)?
  _channelFactory;
  final DesktopGatewayCapabilityCache _capabilityCache;
  final GroupsCapabilityCache _groupsCapabilityCache = GroupsCapabilityCache();
  final Duration _heartbeatInterval;
  final Duration _heartbeatDeadline;
  final Duration _fanoutInactivityDeadline;
  final DateTime Function() _now;
  static const CapabilityPayloadSanitizer _payloadSanitizer =
      CapabilityPayloadSanitizer();
  static const TuiGatewayRpcError _exclusiveSubmitCapabilityDenied =
      TuiGatewayRpcError(
        'prompt.submit',
        'Hermes Agent cannot safely accept this message',
        data: {'reason': 'EXCLUSIVE_SUBMIT_CAPABILITY_DENIED'},
        origin: CompressionFailureOrigin.localPreflight,
      );
  static const TuiGatewayRpcError _exclusiveSubmitCapabilityRace =
      TuiGatewayRpcError(
        'prompt.submit',
        'Hermes Agent cannot safely accept this message',
        origin: CompressionFailureOrigin.localPreflight,
      );

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final Map<int, _PendingRpc> _pending = {};
  final Map<String, _OpenServerRequest> _openServerRequests = {};
  // Approval queue `request_id` → JSON-RPC server request id (`srq-…`).
  final Map<String, String> _approvalServerRequestIds = {};
  int _nextId = 1;
  bool _connected = false;
  bool _closed = false;
  int _socketGeneration = 0;
  int _exclusiveSubmitCapabilityGeneration = -1;
  bool? _exclusiveSubmitCapabilityAllowed;
  Future<bool>? _exclusiveSubmitCapabilityProbe;
  int _heartbeatSequence = 0;
  DateTime _lastInboundAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Último frame REAL recibido del socket. A diferencia de [_lastInboundAt],
  /// el heartbeat nunca lo adelanta al reanudar el isolate: solo así
  /// [probeNow] distingue un socket vivo de uno medio abierto tras un resume.
  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastHeartbeatTickAt;
  Timer? _heartbeatTimer;
  String? _watchdogRuntimeId;
  bool _watchdogRuntimeBusy = false;
  DateTime? _lastWatchdogActivityAt;
  int _watchdogRuntimeRevision = 0;
  bool _fanoutWatchdogInFlight = false;
  Future<void>? _connecting;

  final ReplayCoordinator _replayCoordinator = ReplayCoordinator();
  bool _replayInFlight = false;
  static const int _maxConcurrentReplayRequests = 4;
  String? _replayEpoch;

  /// Current replay authority domain; rotates with every socket generation.
  String get currentReplayEpoch => _replayEpoch ?? 'legacy:$_socketGeneration';
  bool _connectionReplayCapable = false;
  bool _connectionChangeEvents = false;

  /// `gateway.ready.change_events` of the current connection: the backend
  /// broadcasts sessions/cron/process changes, so polls can be demoted to slow
  /// safety backstops (Hermes Desktop does the same).
  bool get changeEventsAvailable => _connectionChangeEvents;
  Completer<void>? _gatewayReadyCompleter;
  String? _legacyEventRuntimeId;
  bool _legacyEventRuntimeAmbiguous = false;

  TuiGatewayClient(
    this._connection, {
    DashboardClient? dashboard,
    WebSocketChannel Function(Uri uri, Map<String, dynamic> headers)?
    channelFactory,
    DesktopGatewayCapabilityCache? capabilityCache,
    Duration heartbeatInterval = const Duration(seconds: 15),
    Duration heartbeatDeadline = const Duration(seconds: 45),
    Duration probeNowDeadline = const Duration(seconds: 5),
    Duration probeNowRecentInbound = const Duration(seconds: 3),
    Duration? fanoutInactivityDeadline,
    DateTime Function()? now,
  }) : _dashboard = dashboard ?? DashboardClient.lazy(_connection),
       _channelFactory = channelFactory,
       _capabilityCache = capabilityCache ?? DesktopGatewayCapabilityCache(),
       _heartbeatInterval = heartbeatInterval,
       _heartbeatDeadline = heartbeatDeadline,
       _probeNowDeadline = probeNowDeadline,
       _probeNowRecentInbound = probeNowRecentInbound,
       _fanoutInactivityDeadline =
           fanoutInactivityDeadline ??
           (heartbeatInterval > Duration.zero
               ? heartbeatInterval
               : const Duration(seconds: 15)),
       _now = now ?? DateTime.now;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => _connected;

  bool get isClosed => _closed;

  Uri _webSocketUri(DashboardWebSocketAuth auth) {
    final base = Uri.parse(_connection.effectiveDashboardUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path:
          '${base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path}/api/ws',
      queryParameters: {
        ...base.queryParameters,
        auth.queryName: auth.credential,
      },
    );
  }

  @override
  Future<void> connect() {
    if (_closed) {
      return Future.error(StateError('Hermes Desktop gateway is closed'));
    }
    if (_connected) return Future.value();
    final inFlight = _connecting;
    if (inFlight != null) return inFlight;
    final future = _connectOnce();
    _connecting = future;
    return future.whenComplete(() {
      if (identical(_connecting, future)) _connecting = null;
    });
  }

  Future<void> _connectOnce() async {
    final generation = ++_socketGeneration;
    _stopHeartbeat();
    _resetLegacyEventRuntimeAnchor();
    late DashboardWebSocketAuth auth;
    try {
      auth = await _dashboard.webSocketAuth();
    } catch (error, stackTrace) {
      debugPrint(
        '[tui-gateway] Dashboard auth unavailable '
        '(${_safeFailureKind(error)})',
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (_closed || generation != _socketGeneration) {
      throw StateError('Hermes Desktop connection was cancelled');
    }
    final uri = _webSocketUri(auth);
    final channel =
        _channelFactory?.call(uri, auth.headers) ??
        IOWebSocketChannel.connect(
          uri,
          headers: auth.headers,
          pingInterval: const Duration(seconds: 20),
          connectTimeout: const Duration(seconds: 10),
        );
    if (_closed || generation != _socketGeneration) {
      await _teardownTransport(channel, null);
      throw StateError('Hermes Desktop connection was cancelled');
    }
    _connectionReplayCapable = false;
    _connectionChangeEvents = false;
    final gatewayReady = Completer<void>();
    // Socket callbacks may fail readiness before channel.ready settles. Attach a
    // handler immediately so the original upgrade error remains the connect
    // result without an unhandled secondary Future.
    unawaited(gatewayReady.future.catchError((Object _) {}));
    _gatewayReadyCompleter = gatewayReady;
    late final StreamSubscription<dynamic> subscription;
    subscription = channel.stream.listen(
      (raw) => _handleFrame(generation, channel, raw),
      onError: (Object error, StackTrace stackTrace) =>
          _handleSocketError(generation, channel, error, stackTrace),
      onDone: () => _handleSocketDone(generation, channel),
      cancelOnError: false,
    );
    _channel = channel;
    _subscription = subscription;
    try {
      await channel.ready.timeout(const Duration(seconds: 12));
      await gatewayReady.future.timeout(const Duration(seconds: 12));
      if (_closed ||
          generation != _socketGeneration ||
          !identical(_channel, channel)) {
        throw StateError('Hermes Desktop connection was superseded');
      }
      _capabilityCache.resetForReconnect();
      _connected = true;
      _advertiseServerRequestCapability(generation, channel);
      // A recovery caller resumes its stored session only after connect() ends.
      // Drain the server's sequence gap first so replayed deltas/tools cannot
      // race the new snapshot or be delivered out of order with live frames.
      await _fetchReplay();
      if (_closed ||
          generation != _socketGeneration ||
          !identical(_channel, channel) ||
          !_connected) {
        throw StateError('Hermes Desktop disconnected during replay');
      }
    } catch (error) {
      debugPrint(
        '[tui-gateway] WebSocket connection failed '
        '(${_safeFailureKind(error)})',
      );
      if (identical(_gatewayReadyCompleter, gatewayReady)) {
        _gatewayReadyCompleter = null;
      }
      if (generation == _socketGeneration && identical(_channel, channel)) {
        _subscription = null;
        _channel = null;
      }
      // Si el upgrade falla antes de enlazar el sink real (HTTP 401/404), tanto
      // `cancel()` como `close()` pueden quedar pendientes. Se desvincula antes
      // de limpiar y ambas operaciones comparten un único presupuesto para que
      // ActiveChat pueda degradar a `/v1/runs` sin quedar en "Conectando".
      await _teardownTransport(channel, subscription);
      rethrow;
    }
  }

  void _advertiseServerRequestCapability(
    int generation,
    WebSocketChannel channel,
  ) {
    if (generation != _socketGeneration || !identical(_channel, channel)) {
      return;
    }
    try {
      final advertisement = _requestConnected(
        'client.capabilities',
        const <String, dynamic>{'server_requests': true},
        timeout: const Duration(seconds: 10),
      );
      unawaited(
        advertisement.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    } catch (_) {
      // Capability discovery is optional and must not own transport readiness.
    }
  }

  String _safeFailureKind(Object error) {
    if (error is DashboardAuthException) return error.code.stableCode;
    final text = error.toString().toLowerCase();
    if (text.contains('401') || text.contains('403')) return 'unauthorized';
    if (text.contains('timeout') || text.contains('timed out')) {
      return 'timeout';
    }
    if (text.contains('refused')) return 'connection_refused';
    if (text.contains('handshake')) return 'websocket_handshake';
    return error.runtimeType.toString();
  }

  void _handleFrame(int generation, WebSocketChannel channel, dynamic raw) {
    if (generation != _socketGeneration || !identical(_channel, channel)) {
      return;
    }
    try {
      final parsed = JsonRpcWireDecoder.decodeTransportFrame(
        raw,
        replayCapable: _connectionReplayCapable,
      );
      if (parsed == null) return;
      _lastInboundAt = _now();
      _lastFrameAt = _lastInboundAt;
      if (parsed is JsonRpcNotificationFrame) return;
      if (parsed is JsonRpcServerRequestFrame) {
        _deliverServerRequest(parsed, generation, channel);
        return;
      }
      if (parsed is JsonRpcResponseFrame) {
        final pending = _pending[parsed.id];
        if (pending == null) return;
        _pending.remove(parsed.id);
        pending.timer.cancel();
        final error = parsed.error;
        if (error != null) {
          pending.completer.completeError(
            pending.redactRemoteError
                ? SanitizedRpcFailureFactory.remote(
                    pending.method,
                    safeCode: _protocolInteger(error['code']),
                  )
                : TuiGatewayRpcError(
                    pending.method,
                    error['message'] as String,
                    code: _protocolInteger(error['code']),
                    origin: CompressionFailureOrigin.remoteRpc,
                    data: error['data'] is Map<String, dynamic>
                        ? Map<String, dynamic>.unmodifiable(
                            error['data']! as Map<String, dynamic>,
                          )
                        : const <String, dynamic>{},
                  ),
          );
        } else {
          final result = parsed.result;
          if (result is Map<String, dynamic>) {
            // Reconnect contract: resume/activate/events.since answer with the
            // server→client requests still waiting on this session. They are
            // not events, so they cannot ride the replay ring.
            _deliverOpenServerRequests(
              result['open_requests'],
              generation,
              channel,
            );
          }
          pending.completer.complete(
            result is Map<String, dynamic>
                ? Map<String, dynamic>.from(result)
                : <String, dynamic>{'value': result},
          );
        }
        return;
      }

      final parsedEvent = (parsed as JsonRpcEventFrame).event;
      final readyPending = _gatewayReadyCompleter?.isCompleted == false;
      if (parsedEvent.type == 'gateway.ready') {
        if (parsedEvent is! GlobalGatewayEvent ||
            parsedEvent.sequence != null) {
          throw const JsonRpcWireFormatException(
            'gateway.ready must be global',
          );
        }
        final payload = parsedEvent.payload;
        final hasEpoch = payload.containsKey('replay_epoch');
        final epoch = payload['replay_epoch'];
        if (hasEpoch &&
            (epoch is! String || epoch.isEmpty || epoch != epoch.trim())) {
          throw const JsonRpcWireFormatException('invalid replay epoch');
        }
        if (payload.containsKey('heartbeat') && payload['heartbeat'] is! bool) {
          throw const JsonRpcWireFormatException(
            'invalid heartbeat capability',
          );
        }
        if (epoch is String) {
          _adoptReplayEpoch(epoch);
          _connectionReplayCapable = true;
        } else {
          _connectionReplayCapable = false;
          if (_replayCoordinator.hasWatermarks) {
            _replayCoordinator.rotateEpoch();
          }
          _replayEpoch = null;
        }
        _connectionChangeEvents = payload['change_events'] == true;
        if (payload['heartbeat'] == true) _startHeartbeat(generation, channel);
        final ready = _gatewayReadyCompleter;
        if (ready != null && !ready.isCompleted) ready.complete();
        return;
      }
      if (readyPending) {
        throw const JsonRpcWireFormatException(
          'event received before gateway.ready',
        );
      }
      if (parsedEvent is GlobalGatewayEvent) {
        if (!_events.isClosed) {
          _events.add(
            TuiGatewayEvent(
              type: parsedEvent.type,
              sessionId: '',
              payload: parsedEvent.payload,
            ),
          );
        }
        return;
      }
      final sessionEvent = parsedEvent as SessionGatewayEvent;
      final event = TuiGatewayEvent(
        type: sessionEvent.type,
        sessionId: sessionEvent.sessionId,
        sequence: sessionEvent.sequence,
        transportGeneration: generation,
        producerChannel: channel,
        payload: sessionEvent.payload,
      );
      if (sessionEvent.sequence == null) {
        _observeWatchdogEvent(sessionEvent, _now());
        if (!_events.isClosed) _events.add(_translateRequestCancel(event));
        return;
      }
      final disposition = _replayCoordinator.acceptLive(
        sessionEvent,
        socketGeneration: generation,
        channel: channel,
        replayEpoch: _replayEpoch,
      );
      if (disposition == ReplayLiveDisposition.dispatch) {
        _observeWatchdogEvent(sessionEvent, _now());
        if (!_events.isClosed) _events.add(_translateRequestCancel(event));
      }
    } catch (_) {
      _handleMalformedFrame(generation, channel);
    }
  }

  /// Legacy event type each server request kind used to arrive as. The chat
  /// service still consumes those shapes; the transport adapts the v7 frames.
  static const Map<String, String> _serverRequestLegacyEvents = {
    'approval': 'approval.request',
    'clarify': 'clarify.request',
    'sudo': 'sudo.request',
    'secret': 'secret.request',
    'terminal.read': 'terminal.read.request',
    'vault.unlock_prompt': 'vault.unlock.request',
    'vault.save_login': 'vault.save_login.request',
    'vault.code': 'vault.code.request',
  };

  void _deliverServerRequest(
    JsonRpcServerRequestFrame frame,
    int generation,
    WebSocketChannel channel,
  ) {
    final rawSession = frame.params['session_id'];
    final sessionId = rawSession is String ? rawSession.trim() : '';
    final legacyType = _serverRequestLegacyEvents[frame.method];
    if (legacyType == null || sessionId.isEmpty) {
      // Same as Desktop's `no handler` path: fail the request so the backend
      // does not wait on a client that cannot answer this kind of question.
      _writeServerRequestFrame(generation, channel, {
        'jsonrpc': '2.0',
        'id': frame.id,
        'error': {
          'code': legacyType == null ? -32601 : -32602,
          'message': legacyType == null
              ? 'no handler for server request: ${frame.method}'
              : 'server request without session_id',
        },
      });
      return;
    }
    final payload = Map<String, dynamic>.from(frame.params)
      ..remove('session_id');
    if (frame.method == 'approval') {
      // The approval queue keeps its own `request_id`; the UI and the compat
      // `approval.respond` RPC key on it, so it must survive untouched.
      final approvalId = (payload['request_id'] ?? payload['approval_id'])
          ?.toString()
          .trim();
      if (approvalId == null || approvalId.isEmpty) {
        payload['request_id'] = frame.id;
        _approvalServerRequestIds[frame.id] = frame.id;
      } else {
        _approvalServerRequestIds[approvalId] = frame.id;
      }
    } else {
      payload['request_id'] = frame.id;
    }
    _openServerRequests[frame.id] = _OpenServerRequest(
      id: frame.id,
      method: frame.method,
      sessionId: sessionId,
      generation: generation,
      channel: channel,
    );
    if (_events.isClosed) return;
    _events.add(
      TuiGatewayEvent(
        type: legacyType,
        sessionId: sessionId,
        transportGeneration: generation,
        producerChannel: channel,
        payload: Map<String, dynamic>.unmodifiable(payload),
      ),
    );
  }

  void _deliverOpenServerRequests(
    Object? open,
    int generation,
    WebSocketChannel channel,
  ) {
    if (open is! List) return;
    for (final entry in open) {
      if (entry is! Map) continue;
      final id = entry['id'];
      final method = entry['method'];
      final params = entry['params'];
      if (id is! String || id.isEmpty || method is! String || method.isEmpty) {
        continue;
      }
      _deliverServerRequest(
        JsonRpcServerRequestFrame(
          id,
          method,
          params is Map<String, dynamic>
              ? Map<String, dynamic>.unmodifiable(params)
              : const <String, dynamic>{},
        ),
        generation,
        channel,
      );
    }
  }

  /// `request.cancel {id, method, reason}` withdraws an open server request.
  /// Consumers still speak the legacy `*.expire` / `approval.responded` shapes.
  TuiGatewayEvent _translateRequestCancel(TuiGatewayEvent event) {
    if (event.type != 'request.cancel') return event;
    final id = event.payload['id'];
    if (id is! String || id.isEmpty) return event;
    final open = _openServerRequests.remove(id);
    final method = open?.method ?? event.payload['method'];
    if (method is! String) return event;
    var requestId = id;
    if (method == 'approval') {
      for (final entry in _approvalServerRequestIds.entries) {
        if (entry.value == id) {
          requestId = entry.key;
          break;
        }
      }
      _approvalServerRequestIds.remove(requestId);
      return TuiGatewayEvent(
        type: 'approval.responded',
        sessionId: event.sessionId,
        sequence: event.sequence,
        transportGeneration: event.transportGeneration,
        producerChannel: event.producerChannel,
        payload: Map<String, dynamic>.unmodifiable({
          'request_id': requestId,
          'reason': event.payload['reason'],
        }),
      );
    }
    final legacyType = _serverRequestLegacyEvents[method];
    if (legacyType == null) return event;
    return TuiGatewayEvent(
      type:
          '${legacyType.substring(0, legacyType.length - '.request'.length)}'
          '.expire',
      sessionId: event.sessionId,
      sequence: event.sequence,
      transportGeneration: event.transportGeneration,
      producerChannel: event.producerChannel,
      payload: Map<String, dynamic>.unmodifiable({
        'request_id': requestId,
        'reason': event.payload['reason'],
      }),
    );
  }

  /// Answers an open server request over the socket it arrived on. False when
  /// nothing is open under that id (expired, cancelled, or the transport was
  /// replaced — the backend re-delivers it as `open_requests` on resume).
  bool _respondServerRequest(String requestId, Map<String, Object?> result) {
    final open = _openServerRequests.remove(requestId);
    if (open == null) return false;
    return _writeServerRequestFrame(open.generation, open.channel, {
      'jsonrpc': '2.0',
      'id': requestId,
      'result': result,
    });
  }

  bool _writeServerRequestFrame(
    int generation,
    WebSocketChannel channel,
    Map<String, Object?> frame,
  ) {
    if (generation != _socketGeneration || !identical(_channel, channel)) {
      return false;
    }
    try {
      channel.sink.add(jsonEncode(frame));
      return true;
    } catch (error, stackTrace) {
      _handleSocketError(generation, channel, error, stackTrace);
      return false;
    }
  }

  void _handleMalformedFrame(int generation, WebSocketChannel channel) {
    if (generation != _socketGeneration || !identical(_channel, channel)) {
      return;
    }
    final wasConnected = _connected;
    _replayCoordinator.retireTransport(
      generation: generation,
      channel: channel,
    );
    _connected = false;
    _stopHeartbeat();
    _retireWatchdogRuntime();
    _resetLegacyEventRuntimeAnchor();
    _capabilityCache.resetForReconnect();
    _channel = null;
    final subscription = _subscription;
    _subscription = null;
    unawaited(_teardownTransport(channel, subscription));
    final ready = _gatewayReadyCompleter;
    _gatewayReadyCompleter = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        TuiGatewayRpcError(
          'gateway.ready',
          'Invalid JSON-RPC frame',
          origin: CompressionFailureOrigin.malformed,
        ),
      );
    }
    for (final pending in _pending.values) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          pending.redactRemoteError
              ? SanitizedRpcFailureFactory.transport(pending.method)
              : TuiGatewayRpcError(
                  pending.method,
                  'Invalid JSON-RPC frame',
                  origin: CompressionFailureOrigin.malformed,
                ),
        );
      }
    }
    _pending.clear();
    _openServerRequests.clear();
    _approvalServerRequestIds.clear();
    if (wasConnected && !_events.isClosed) {
      _events.addError(
        TuiGatewayRpcError(
          'gateway.frame',
          'Invalid JSON-RPC frame',
          origin: CompressionFailureOrigin.malformed,
        ),
      );
    }
  }

  Future<void> _fetchReplay() async {
    final channel = _channel;
    final epoch = _replayEpoch;
    if (_replayInFlight ||
        !_replayCoordinator.hasWatermarks ||
        !_connected ||
        channel == null ||
        epoch == null) {
      return;
    }
    _replayInFlight = true;
    final generation = _socketGeneration;
    final entries = _replayCoordinator.beginReconnect(
      generation: generation,
      channel: channel,
      epoch: epoch,
    );
    try {
      var nextEntry = 0;
      Future<void> replayWorker() async {
        while (nextEntry < entries.length) {
          final entry = entries[nextEntry++];
          try {
            final result = await _requestConnected(
              'session.events.since',
              <String, dynamic>{
                'session_id': entry.key,
                'last_seen': entry.value,
              },
              timeout: const Duration(seconds: 10),
            );
            if (generation != _socketGeneration ||
                !identical(_channel, channel) ||
                _replayEpoch != epoch) {
              _replayCoordinator.abandonTransaction(entry.key);
              continue;
            }
            final decision = _replayCoordinator.validateReplay(
              entry.key,
              result,
            );
            if (decision is ReplayBatchRetireTransport) {
              _handleMalformedFrame(generation, channel);
              return;
            }
            // Commit proves only the local batch shape. Current upstream can
            // reset seq within the same epoch after FIFO eviction, so neither
            // replay nor held-live is projected before exact snapshot recovery.
          } catch (_) {
            _replayCoordinator.abandonTransaction(entry.key);
          }
        }
      }

      await Future.wait(
        List<Future<void>>.generate(
          entries.length.clamp(0, _maxConcurrentReplayRequests),
          (_) => replayWorker(),
        ),
      );
    } finally {
      _replayCoordinator.abandonAllTransactions();
      _replayInFlight = false;
    }
  }

  void _adoptReplayEpoch(String epoch) {
    if (_replayEpoch == epoch) return;
    if (_replayEpoch != null) _replayCoordinator.rotateEpoch();
    _replayEpoch = epoch;
  }

  static const _heartbeatTimeoutMessage =
      'Hermes Desktop WebSocket heartbeat timed out';
  static const _probeTimeoutMessage = 'Hermes Desktop WebSocket probe timed out';

  /// Motivo estable y no privado del cierre: nunca imprime el mensaje remoto.
  String _socketCloseReason(Object error) {
    if (error is StateError) {
      if (error.message == _heartbeatTimeoutMessage) return 'heartbeat_timeout';
      if (error.message == _probeTimeoutMessage) return 'probe_timeout';
    }
    return 'error:${_safeFailureKind(error)}';
  }

  void _handleSocketError(
    int generation,
    WebSocketChannel channel,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    if (generation != _socketGeneration || !identical(_channel, channel)) {
      return;
    }
    final wasConnected = _connected;
    _replayCoordinator.retireTransport(
      generation: generation,
      channel: channel,
    );
    final ready = _gatewayReadyCompleter;
    _gatewayReadyCompleter = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        TuiGatewayRpcError(
          'gateway.ready',
          'Connection lost before gateway.ready',
          failureKind: TuiGatewayRpcFailureKind.connectionLost,
        ),
      );
    }
    // Antes de `ready`, `_connectOnce` conserva el error original y es el único
    // owner del teardown. Evita dos cancel/close concurrentes sobre un upgrade
    // rechazado.
    if (!wasConnected) return;
    // Diagnóstico sin datos privados: distingue un plazo de heartbeat/sonda
    // vencido de un error del socket (bucles de reconexión en turnos largos).
    debugPrint(
      '[tui-gateway] WebSocket closed '
      '(reason=${_socketCloseReason(error)}, generation=$generation)',
    );
    _connected = false;
    _stopHeartbeat();
    _retireWatchdogRuntime();
    _resetLegacyEventRuntimeAnchor();
    _capabilityCache.resetForReconnect();
    _channel = null;
    final subscription = _subscription;
    _subscription = null;
    unawaited(_teardownTransport(channel, subscription));
    final hadSensitivePending = _pending.values.any(
      (pending) => pending.redactRemoteError,
    );
    _failPending(error, stackTrace);
    // `events` is the long-lived side of the Desktop protocol. A socket can
    // disappear while there is no JSON-RPC request pending (for example while
    // Hermes is executing a tool), so failing only `_pending` leaves the chat
    // stuck in "streaming" until its watchdog fires. Notify the ActiveChat as
    // soon as an already-established transport drops. Connection failures
    // before `ready` are deliberately not forwarded: `_connectOnce` owns those
    // and can still use the REST fallback without racing an event-stream error.
    if (wasConnected && !_events.isClosed) {
      if (hadSensitivePending) {
        _events.addError(
          const TuiGatewayRpcError(
            'gateway.transport',
            'Hermes Desktop connection lost',
            failureKind: TuiGatewayRpcFailureKind.connectionLost,
          ),
        );
      } else if (stackTrace == null) {
        _events.addError(error);
      } else {
        _events.addError(error, stackTrace);
      }
    }
  }

  void _handleSocketDone(int generation, WebSocketChannel channel) {
    if (generation != _socketGeneration || !identical(_channel, channel)) {
      return;
    }
    final wasConnected = _connected;
    _replayCoordinator.retireTransport(
      generation: generation,
      channel: channel,
    );
    final ready = _gatewayReadyCompleter;
    _gatewayReadyCompleter = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        TuiGatewayRpcError(
          'gateway.ready',
          'Connection lost before gateway.ready',
          failureKind: TuiGatewayRpcFailureKind.connectionLost,
        ),
      );
    }
    if (wasConnected) {
      debugPrint(
        '[tui-gateway] WebSocket closed '
        '(reason=on_done, closeCode=${channel.closeCode ?? 'none'}, '
        'generation=$generation)',
      );
    }
    _connected = false;
    _stopHeartbeat();
    _retireWatchdogRuntime();
    _resetLegacyEventRuntimeAnchor();
    _capabilityCache.resetForReconnect();
    final subscription = _subscription;
    _channel = null;
    _subscription = null;
    if (wasConnected) {
      unawaited(_teardownTransport(channel, subscription));
    }
    final hadSensitivePending = _pending.values.any(
      (pending) => pending.redactRemoteError,
    );
    const pendingError = TuiGatewayRpcError(
      'gateway.transport',
      'Hermes Desktop connection lost',
      failureKind: TuiGatewayRpcFailureKind.connectionLost,
    );
    _failPending(pendingError);
    if (wasConnected && !_events.isClosed) {
      _events.addError(
        hadSensitivePending
            ? pendingError
            : StateError('Hermes Desktop WebSocket closed'),
      );
    }
  }

  void _startHeartbeat(int generation, WebSocketChannel channel) {
    _stopHeartbeat();
    final startedAt = _now();
    _lastInboundAt = startedAt;
    _lastHeartbeatTickAt = startedAt;
    if (_heartbeatInterval <= Duration.zero ||
        _heartbeatDeadline <= Duration.zero) {
      return;
    }
    _heartbeatTimer = Timer.periodic(
      _heartbeatInterval,
      (_) => unawaited(_heartbeatTick(generation, channel)),
    );
  }

  Future<void> _heartbeatTick(int generation, WebSocketChannel channel) async {
    if (generation != _socketGeneration ||
        !identical(_channel, channel) ||
        !_connected) {
      return;
    }
    final now = _now();
    final previousTick = _lastHeartbeatTickAt;
    _lastHeartbeatTickAt = now;
    // Android suspende el isolate al dejar la app en segundo plano. Al
    // volver, un Timer periódico vencido puede ejecutarse antes de entregar
    // los frames que el socket dejó en cola. Ese salto no demuestra una
    // conexión muerta: concede una sonda completa antes de invalidarla.
    if (previousTick != null &&
        now.difference(previousTick) >= _heartbeatDeadline) {
      _lastInboundAt = now;
    }
    if (now.difference(_lastInboundAt) >= _heartbeatDeadline) {
      _handleSocketError(
        generation,
        channel,
        StateError(_heartbeatTimeoutMessage),
      );
      return;
    }
    try {
      _heartbeatSequence = _heartbeatSequence >= maxSafeJsonInteger
          ? 1
          : _heartbeatSequence + 1;
      channel.sink.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': -_heartbeatSequence,
          'method': 'gateway.ping',
          'params': const <String, dynamic>{},
        }),
      );
      await _probeSilentFanout(generation, channel, now);
    } catch (error, stackTrace) {
      _handleSocketError(generation, channel, error, stackTrace);
    }
  }

  Future<bool>? _probeNowFlight;
  int _probeNowFlightGeneration = -1;
  final Duration _probeNowDeadline;

  /// Un frame recibido hace menos de esto ya prueba que el socket vive.
  final Duration _probeNowRecentInbound;

  /// Sonda puntual del socket vigente (cambio de red / resume). Cualquier
  /// respuesta, incluso un error JSON-RPC, prueba que el socket vive. Sin
  /// respuesta en ~5 s *y sin ningún frame entrante desde que empezó* se usa
  /// la misma ruta que un heartbeat vencido, así que la reconexión normal
  /// arranca sin esperar los 45 s. Hermes procesa los RPC en serie
  /// (`tui_gateway/ws.py`): un `prompt.submit` o `approval.respond` lento
  /// retrasa el pong aunque los eventos sigan llegando, y cortar entonces
  /// dejaría ambiguo un submit sano. Coalescida por conexión; no-op si no hay
  /// conexión o hubo tráfico reciente. No toca el heartbeat.
  @override
  Future<bool> probeNow() {
    final existing = _probeNowFlight;
    if (existing != null && _probeNowFlightGeneration == _socketGeneration) {
      return existing;
    }
    final channel = _channel;
    if (_closed || !_connected || channel == null) {
      return Future<bool>.value(false);
    }
    if (_now().difference(_lastFrameAt) < _probeNowRecentInbound) {
      return Future<bool>.value(true);
    }
    final generation = _socketGeneration;
    late final Future<bool> flight;
    flight = _probeNowOnce(generation, channel).whenComplete(() {
      if (identical(_probeNowFlight, flight)) _probeNowFlight = null;
    });
    _probeNowFlight = flight;
    _probeNowFlightGeneration = generation;
    return flight;
  }

  Future<bool> _probeNowOnce(int generation, WebSocketChannel channel) async {
    final probeStartedAt = _now();
    try {
      await _requestConnected(
        'gateway.ping',
        const <String, dynamic>{},
        timeout: _probeNowDeadline,
      );
      return true;
    } on TuiGatewayRpcError catch (error) {
      if (error.failureKind == null) return true;
      if (error.failureKind == TuiGatewayRpcFailureKind.timeout) {
        // Cualquier frame posterior al inicio de la sonda prueba que el
        // socket vive: el pong solo espera tras un RPC serial lento.
        if (_lastFrameAt.isAfter(probeStartedAt)) return true;
        _handleSocketError(
          generation,
          channel,
          StateError(_probeTimeoutMessage),
        );
      }
      return false;
    } catch (error, stackTrace) {
      _handleSocketError(generation, channel, error, stackTrace);
      return false;
    }
  }

  @visibleForTesting
  Future<void> debugHeartbeatTick() async {
    final channel = _channel;
    if (channel == null) return;
    await _heartbeatTick(_socketGeneration, channel);
  }

  Future<void> _probeSilentFanout(
    int generation,
    WebSocketChannel channel,
    DateTime now,
  ) async {
    final epoch = _replayEpoch;
    final runtime = _watchdogRuntimeId;
    if (_fanoutWatchdogInFlight ||
        epoch == null ||
        !_connectionReplayCapable ||
        runtime == null ||
        !_watchdogRuntimeBusy ||
        generation != _socketGeneration ||
        !identical(_channel, channel) ||
        !_connected) {
      return;
    }
    final lastActivity = _lastWatchdogActivityAt;
    if (lastActivity != null &&
        now.difference(lastActivity) < _fanoutInactivityDeadline) {
      return;
    }

    _fanoutWatchdogInFlight = true;
    final registration = _watchdogRuntimeRevision;
    final lastSeen = _replayCoordinator.watermarks[runtime] ?? 0;
    // A completed no-gap probe also bounds traffic to one request per busy
    // inactivity window. Heartbeat responses deliberately do not update this
    // runtime-specific clock: a fanout-detached peer still answers ping.
    _lastWatchdogActivityAt = now;
    try {
      final result = await _requestConnected(
        'session.events.since',
        <String, dynamic>{'session_id': runtime, 'last_seen': lastSeen},
        timeout: const Duration(seconds: 10),
      );
      if (generation != _socketGeneration ||
          !identical(_channel, channel) ||
          _replayEpoch != epoch ||
          _watchdogRuntimeId != runtime ||
          !_watchdogRuntimeBusy ||
          _watchdogRuntimeRevision != registration ||
          !_connected) {
        return;
      }
      final current = _replayCoordinator.watermarks[runtime];
      if (current != null && current != lastSeen) return;
      final decision = ReplayBatchProof.validate(
        runtime: runtime,
        epoch: epoch,
        lastSeen: lastSeen,
        result: result,
        held: const <SessionGatewayEvent>[],
      );
      final gapRemains =
          decision is ReplayBatchCommit && decision.newWatermark > lastSeen;
      if (decision is ReplayBatchCommit && !gapRemains) return;

      // Replay can identify a silent gap, but current upstream cannot prove a
      // full snapshot-to-tail cut. Quarantine before notifying ActiveChat so it
      // rehydrates authoritative REST/roster state instead of publishing the
      // replay payload directly.
      _replayCoordinator.quarantine(runtime);
      _retireWatchdogRuntime(runtime);
      if (!_events.isClosed) {
        _events.addError(
          const TuiGatewayRpcError(
            'session.events.since',
            'Hermes Desktop live subscription requires rehydration',
            failureKind: TuiGatewayRpcFailureKind.connectionLost,
          ),
        );
      }
    } catch (_) {
      // A failed diagnostic read is not itself proof that the healthy socket or
      // fanout lease is lost. Retry only after another bounded idle window.
    } finally {
      _fanoutWatchdogInFlight = false;
    }
  }

  @visibleForTesting
  Future<void> debugProbeSilentFanout() async {
    final channel = _channel;
    if (channel == null) return;
    await _probeSilentFanout(_socketGeneration, channel, _now());
  }

  void _adoptWatchdogSnapshot(DesktopSessionSnapshot snapshot) {
    final status = snapshot.status?.trim().toLowerCase();
    final busy =
        snapshot.running ||
        snapshot.inflight != null ||
        snapshot.queued != null ||
        const <String>{
          'running',
          'busy',
          'streaming',
          'compacting',
          'waiting',
        }.contains(status);
    _watchdogRuntimeId = snapshot.runtimeSessionId;
    _watchdogRuntimeBusy = busy;
    _lastWatchdogActivityAt = _now();
    _watchdogRuntimeRevision += 1;
  }

  void _markWatchdogRuntimeBusy(Object? runtimeSessionId) {
    if (runtimeSessionId is! String ||
        runtimeSessionId.isEmpty ||
        runtimeSessionId != runtimeSessionId.trim()) {
      return;
    }
    _watchdogRuntimeId = runtimeSessionId;
    _watchdogRuntimeBusy = true;
    _lastWatchdogActivityAt = _now();
    _watchdogRuntimeRevision += 1;
  }

  void _retireWatchdogRuntime([String? runtimeSessionId]) {
    if (runtimeSessionId != null && _watchdogRuntimeId != runtimeSessionId) {
      return;
    }
    _watchdogRuntimeId = null;
    _watchdogRuntimeBusy = false;
    _lastWatchdogActivityAt = null;
    _watchdogRuntimeRevision += 1;
  }

  void _observeWatchdogEvent(SessionGatewayEvent event, DateTime observedAt) {
    if (event.sessionId != _watchdogRuntimeId) return;
    _lastWatchdogActivityAt = observedAt;
    _watchdogRuntimeRevision += 1;

    final status = event.payload['status']?.toString().trim().toLowerCase();
    final info = event.payload['info'];
    final running =
        event.payload['running'] ?? (info is Map ? info['running'] : null);
    if (event.type == 'message.complete' ||
        event.type == 'error' ||
        event.type == 'session.closed' ||
        running == false ||
        const <String>{
          'idle',
          'complete',
          'completed',
          'terminal',
          'failed',
          'cancelled',
          'canceled',
          'stopped',
        }.contains(status)) {
      _watchdogRuntimeBusy = false;
      return;
    }
    if (running == true ||
        const <String>{
          'running',
          'busy',
          'streaming',
          'compacting',
          'waiting',
        }.contains(status) ||
        event.type == 'message.start' ||
        event.type == 'message.delta' ||
        event.type == 'message.interim' ||
        event.type == 'tool.start') {
      _watchdogRuntimeBusy = true;
    }
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lastHeartbeatTickAt = null;
  }

  void _failPending(Object error, [StackTrace? stackTrace]) {
    for (final pending in _pending.values.toList()) {
      pending.timer.cancel();
      if (pending.completer.isCompleted) continue;
      if (pending.redactRemoteError) {
        pending.completer.completeError(
          SanitizedRpcFailureFactory.transport(pending.method),
        );
        continue;
      }
      final safeError =
          const {
            'gateway.capabilities',
            'session.resume',
          }.contains(pending.method)
          ? TuiGatewayRpcError(
              pending.method,
              'Connection lost before JSON-RPC response',
              failureKind: TuiGatewayRpcFailureKind.connectionLost,
            )
          : error;
      if (stackTrace == null) {
        pending.completer.completeError(safeError);
      } else {
        pending.completer.completeError(safeError, stackTrace);
      }
    }
    _pending.clear();
    _openServerRequests.clear();
    _approvalServerRequestIds.clear();
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    await connect();
    return _requestConnected(method, params, timeout: timeout);
  }

  @override
  Future<void> ensureExclusiveSubmitCapability() async {
    await _requireExclusiveSubmitCapabilityProof();
  }

  // Async-local authorization: concurrent operations never overwrite a guard.
  static final _compressionAuthorization = Object();
  static Future<T> withCompressionAuthorization<T>(
    bool Function() allowed,
    Future<T> Function() operation,
  ) => runZoned(operation, zoneValues: {_compressionAuthorization: allowed});

  Future<Map<String, dynamic>> _requestExclusiveSessionMutation(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 120),
    bool preserveCapabilityFailure = false,
  }) async {
    try {
      final proof = await _requireExclusiveSubmitCapabilityProof(
        preserveTypedFailure: preserveCapabilityFailure,
      );
      if (proof.generation != _socketGeneration ||
          !identical(_channel, proof.channel) ||
          !_connected ||
          (Zone.current[_compressionAuthorization] as bool Function()?)
                  ?.call() ==
              false) {
        throw _exclusiveSubmitCapabilityRace;
      }
    } catch (error) {
      if (error is TuiGatewayRpcError &&
          error.compressionReason ==
              CompressionFailureReason.exclusiveSubmitCapabilityDenied) {
        throw TuiGatewayRpcError(
          method,
          _exclusiveSubmitCapabilityDenied.message,
          data: _exclusiveSubmitCapabilityDenied.data,
          origin: CompressionFailureOrigin.localPreflight,
        );
      }
      if (preserveCapabilityFailure &&
          (error is DashboardAuthException ||
              error is DashboardWebSocketAuthException ||
              error is TuiGatewayRpcError)) {
        rethrow;
      }
      throw TuiGatewayRpcError(
        method,
        _exclusiveSubmitCapabilityRace.message,
        origin: CompressionFailureOrigin.localPreflight,
      );
    }
    return _requestConnected(method, params, timeout: timeout);
  }

  Future<Map<String, dynamic>> _requestPromptSubmit(
    Map<String, dynamic> params,
  ) => _requestExclusiveSessionMutation('prompt.submit', params);

  Future<({int generation, WebSocketChannel channel})>
  _requireExclusiveSubmitCapabilityProof({
    bool preserveTypedFailure = false,
  }) async {
    await connect();
    final generation = _socketGeneration;
    final channel = _channel;
    if (!_connected || channel == null || _closed) {
      throw StateError('Hermes Desktop WebSocket is not connected');
    }
    bool capabilityAllowed;
    try {
      capabilityAllowed = await _resolveExclusiveSubmitCapability(
        generation,
        channel,
      );
    } catch (error) {
      if (error is TuiGatewayRpcError && error.code == -32601) {
        throw _exclusiveSubmitCapabilityDenied;
      }
      if (preserveTypedFailure && error is TuiGatewayRpcError) {
        rethrow;
      }
      throw _exclusiveSubmitCapabilityRace;
    }
    if (!capabilityAllowed) {
      throw _exclusiveSubmitCapabilityDenied;
    }
    if (generation != _socketGeneration ||
        !identical(_channel, channel) ||
        !_connected) {
      throw _exclusiveSubmitCapabilityRace;
    }
    return (generation: generation, channel: channel);
  }

  Future<bool> _resolveExclusiveSubmitCapability(
    int generation,
    WebSocketChannel channel,
  ) {
    if (_exclusiveSubmitCapabilityGeneration != generation) {
      _exclusiveSubmitCapabilityGeneration = generation;
      _exclusiveSubmitCapabilityAllowed = null;
      _exclusiveSubmitCapabilityProbe = null;
    }
    final cached = _exclusiveSubmitCapabilityAllowed;
    if (cached != null) return Future<bool>.value(cached);
    final inFlight = _exclusiveSubmitCapabilityProbe;
    if (inFlight != null) return inFlight;

    final probe = _fetchExclusiveSubmitCapability(generation, channel);
    _exclusiveSubmitCapabilityProbe = probe;
    probe.then<void>(
      (_) {
        if (identical(_exclusiveSubmitCapabilityProbe, probe)) {
          _exclusiveSubmitCapabilityProbe = null;
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(_exclusiveSubmitCapabilityProbe, probe)) {
          _exclusiveSubmitCapabilityProbe = null;
        }
      },
    );
    return probe;
  }

  Future<bool> _fetchExclusiveSubmitCapability(
    int generation,
    WebSocketChannel channel,
  ) async {
    final capabilities = await _requestConnected(
      'gateway.capabilities',
      const <String, dynamic>{},
      timeout: const Duration(seconds: 10),
    );
    final allowed = capabilities['per_session_exclusive_submit'] == true;
    if (generation == _socketGeneration && identical(_channel, channel)) {
      _exclusiveSubmitCapabilityAllowed = allowed;
    }
    return allowed;
  }

  Future<Map<String, dynamic>> _requestOptionalCapability(
    DesktopGatewayCapability capability,
    String method,
    Map<String, dynamic> params,
  ) async {
    if (!_capabilityCache.canAttempt(capability)) {
      throw TuiGatewayRpcError(
        method,
        'Hermes Desktop capability is unavailable',
        code: -32601,
      );
    }
    try {
      final result = await _request(method, params);
      _capabilityCache.mark(
        capability,
        DesktopGatewayCapabilityState.supported,
      );
      return result;
    } on TuiGatewayRpcError catch (error) {
      if (error.code == -32601) {
        _capabilityCache.mark(
          capability,
          DesktopGatewayCapabilityState.unsupported,
        );
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _requestConnected(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 120),
    bool redactRemoteError = false,
  }) {
    final channel = _channel;
    final generation = _socketGeneration;
    if (!_connected || channel == null || _closed) {
      throw StateError('Hermes Desktop WebSocket is not connected');
    }
    var id = _nextId;
    do {
      id = _nextId;
      _nextId = _nextId >= maxSafeJsonInteger ? 1 : _nextId + 1;
    } while (_pending.containsKey(id));
    final completer = Completer<Map<String, dynamic>>();
    final timer = Timer(timeout, () {
      final pending = _pending.remove(id);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.completeError(
          pending.redactRemoteError
              ? SanitizedRpcFailureFactory.timeout(method)
              : TuiGatewayRpcError(
                  method,
                  'Timeout waiting for JSON-RPC response',
                  failureKind: TuiGatewayRpcFailureKind.timeout,
                ),
        );
      }
    });
    _pending[id] = _PendingRpc(
      method,
      completer,
      timer,
      redactRemoteError: redactRemoteError,
    );
    try {
      if (generation != _socketGeneration || !identical(_channel, channel)) {
        throw StateError('Hermes Desktop WebSocket was replaced');
      }
      channel.sink.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }),
      );
    } catch (error, stackTrace) {
      final pending = _pending.remove(id);
      pending?.timer.cancel();
      if (pending != null && !pending.completer.isCompleted) {
        if (redactRemoteError) {
          pending.completer.completeError(
            SanitizedRpcFailureFactory.transport(method),
          );
        } else {
          pending.completer.completeError(error, stackTrace);
        }
      }
      if (redactRemoteError) {
        throw SanitizedRpcFailureFactory.transport(method);
      }
      rethrow;
    }
    return completer.future;
  }

  _SessionRosterSocketLease _captureSessionRosterLease(String method) {
    final channel = _channel;
    if (_closed || !_connected || channel == null) {
      throw _sessionRosterConnectionLost(method);
    }
    return _SessionRosterSocketLease(
      generation: _socketGeneration,
      channel: channel,
      replayEpoch: _replayEpoch,
    );
  }

  void _requireSessionRosterLease(
    _SessionRosterSocketLease lease,
    String method,
  ) {
    if (_closed ||
        !_connected ||
        _socketGeneration != lease.generation ||
        !identical(_channel, lease.channel) ||
        _replayEpoch != lease.replayEpoch) {
      throw _sessionRosterConnectionLost(method);
    }
  }

  TuiGatewayRpcError _sessionRosterConnectionLost(String method) =>
      TuiGatewayRpcError(
        method,
        'Hermes connection changed during session recovery',
        failureKind: TuiGatewayRpcFailureKind.connectionLost,
      );

  Future<T> _awaitSessionRosterLease<T>(
    _SessionRosterSocketLease lease,
    String method,
    Future<T> Function() operation,
  ) async {
    _requireSessionRosterLease(lease, method);
    try {
      final value = await operation();
      _requireSessionRosterLease(lease, method);
      return value;
    } catch (_) {
      _requireSessionRosterLease(lease, method);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _requestSessionRosterLease(
    _SessionRosterSocketLease lease,
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final result = await _awaitSessionRosterLease(
      lease,
      method,
      () => _requestConnected(method, params, timeout: timeout),
    );
    await _awaitSessionRosterLease(
      lease,
      method,
      () => Future<void>.delayed(Duration.zero),
    );
    return result;
  }

  @override
  Future<SessionMessagesPage> sessionHistory({
    required String sessionId,
    String? profile,
  }) async {
    // A read must not reconnect and reuse a runtime from the previous socket.
    const method = 'session.history';
    final lease = _captureSessionRosterLease(method);
    final result = await _requestSessionRosterLease(lease, method, {
      'session_id': sessionId,
      if (profile != null && profile.trim().isNotEmpty)
        'profile': profile.trim(),
    }, timeout: const Duration(seconds: 15));
    final messages = result['messages'];
    if (result['count'] is! int ||
        (result['count'] as int) < 0 ||
        messages is! List ||
        messages.any((row) => row is! Map || row['role'] is! String)) {
      throw const FormatException('Invalid session history');
    }
    // count counts source history rows; projection can expand/filter them.
    // Keep text, row_id and display_metadata intact: the shared display
    // normalizer accepts both REST content and Desktop text.
    // This RPC returns active model history, including active ancestors. It can
    // omit display generations retained as compacted rows, so ActiveChat keeps
    // compacted REST recovery available.
    return SessionMessagesPage.fromRaw(
      rawMessages: messages,
      pagination: null,
      paginationProvided: false,
    );
  }

  static const int _maxGroupListPages = 512;

  Future<GroupsCapabilities> groupCapabilities() async {
    await connect();
    final lease = _captureGroupSocketLease(
      _socketGeneration,
      'groups.capabilities',
    );
    final parsed = await _awaitGroupSocketLease(
      lease,
      'groups.capabilities',
      () => _groupsCapabilityCache.resolve(
        connectionId: _connection.id,
        generation: lease.generation,
        loader: () => _requestConnected(
          'groups.capabilities',
          const <String, dynamic>{},
          timeout: const Duration(seconds: 10),
        ),
      ),
    );
    await _awaitGroupSocketLease(
      lease,
      'groups.capabilities',
      () => Future<void>.delayed(Duration.zero),
    );
    if (parsed == null) {
      throw const TuiGatewayRpcError(
        'groups.capabilities',
        'Group capability evidence is unavailable',
      );
    }
    return parsed;
  }

  Future<({GroupsCapabilities capabilities, _GroupSocketLease lease})>
  _requireGroupMethod(GroupMethod method, {int? generation}) async {
    final capabilities = await groupCapabilities();
    if ((generation != null && capabilities.generation != generation) ||
        !capabilities.supports(method)) {
      throw TuiGatewayRpcError(
        method.wire,
        'Group operation is unavailable',
        code: -32601,
      );
    }
    final lease = _captureGroupSocketLease(
      capabilities.generation,
      method.wire,
    );
    return (capabilities: capabilities, lease: lease);
  }

  _GroupSocketLease _captureGroupSocketLease(int generation, String method) {
    final channel = _channel;
    if (_closed ||
        !_connected ||
        channel == null ||
        _socketGeneration != generation) {
      throw _groupConnectionLost(method);
    }
    return _GroupSocketLease(generation: generation, channel: channel);
  }

  void _requireGroupSocketLease(_GroupSocketLease lease, String method) {
    if (_closed ||
        !_connected ||
        _socketGeneration != lease.generation ||
        !identical(_channel, lease.channel)) {
      throw _groupConnectionLost(method);
    }
  }

  TuiGatewayRpcError _groupConnectionLost(String method) => TuiGatewayRpcError(
    method,
    'Hermes connection changed during the group operation',
    failureKind: TuiGatewayRpcFailureKind.connectionLost,
  );

  Future<T> _awaitGroupSocketLease<T>(
    _GroupSocketLease lease,
    String method,
    Future<T> Function() operation,
  ) async {
    _requireGroupSocketLease(lease, method);
    final value = await operation();
    _requireGroupSocketLease(lease, method);
    return value;
  }

  Future<Map<String, dynamic>> _requestGroupOnLease(
    _GroupSocketLease lease,
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final result = await _awaitGroupSocketLease(
      lease,
      method,
      () => _requestConnected(method, params, timeout: timeout),
    );
    // Give a close queued directly after the response one event-loop turn to
    // retire the transport before any authenticated result can be projected.
    await _awaitGroupSocketLease(
      lease,
      method,
      () => Future<void>.delayed(Duration.zero),
    );
    return result;
  }

  Future<List<HostedGroupRoom>> listGroups({
    int limit = 500,
    int offset = 0,
    int? generation,
  }) async {
    final proof = await _requireGroupMethod(
      GroupMethod.list,
      generation: generation,
    );
    if (limit < 1 || limit > 500 || offset < 0) {
      throw const FormatException('invalid group list window');
    }
    final rooms = <HostedGroupRoom>[];
    final roomIds = <String>{};
    var nextOffset = offset;
    try {
      for (var pageNumber = 0; pageNumber < _maxGroupListPages; pageNumber++) {
        final requestedOffset = nextOffset;
        final result = await _requestGroupOnLease(proof.lease, 'groups.list', {
          'limit': limit,
          'offset': requestedOffset,
          'include_disbanded': false,
        });
        final page = HostedGroupListPage.fromJson(result);
        for (final room in page.rooms) {
          if (!roomIds.add(room.roomId)) {
            throw const FormatException('duplicate room across list pages');
          }
          rooms.add(room);
        }
        final officialNext = page.nextOffset;
        if (officialNext == null) return List.unmodifiable(rooms);
        if (officialNext <= requestedOffset ||
            officialNext != requestedOffset + page.rooms.length) {
          throw const FormatException('invalid room list continuation');
        }
        nextOffset = officialNext;
      }
      throw const FormatException('room list pagination limit exceeded');
    } on FormatException {
      throw const TuiGatewayRpcError(
        'groups.list',
        'Hermes returned an invalid room list',
      );
    }
  }

  Future<HostedGroupRoom> groupState(
    String roomId, {
    int? generation,
    bool includeDisbanded = false,
  }) async {
    final proof = await _requireGroupMethod(
      GroupMethod.state,
      generation: generation,
    );
    return _groupStateOnLease(
      roomId,
      lease: proof.lease,
      includeDisbanded: includeDisbanded,
    );
  }

  Future<HostedGroupRoom> _groupStateOnLease(
    String roomId, {
    required _GroupSocketLease lease,
    bool includeDisbanded = false,
  }) async {
    final room = _groupIdentifier(roomId, 'room id');
    final result = await _requestGroupOnLease(lease, 'groups.state', {
      'room_id': room,
      'include_disbanded': includeDisbanded,
    });
    try {
      final state = HostedGroupRoom.fromJson(result['room']);
      if (state.roomId != room) {
        throw const FormatException('room identity mismatch');
      }
      return state;
    } on FormatException {
      throw const TuiGatewayRpcError(
        'groups.state',
        'Hermes returned invalid room state',
      );
    }
  }

  Future<HostedGroupLogPage> groupLog(
    String roomId, {
    int sinceSeq = 0,
    int limit = 100,
    int? generation,
  }) async {
    final proof = await _requireGroupMethod(
      GroupMethod.log,
      generation: generation,
    );
    return _groupLogOnLease(
      roomId,
      sinceSeq: sinceSeq,
      limit: limit,
      capabilities: proof.capabilities,
      lease: proof.lease,
    );
  }

  /// The complete room log from the beginning, proven gap-free — see
  /// `HostedGroupLogPage.loadComplete`. Every page after the first reuses the
  /// same authenticated lease, so a transport close mid-load surfaces as a
  /// connection-lost error instead of silently rebasing onto a new socket.
  Future<HostedGroupLogPage> groupLogComplete(
    String roomId, {
    int pageLimit = 100,
    int? generation,
  }) async {
    final proof = await _requireGroupMethod(
      GroupMethod.log,
      generation: generation,
    );
    final limit = min(pageLimit, proof.capabilities.maxLogLimit);
    return HostedGroupLogPage.loadComplete(
      pageLimit: limit,
      loader: ({required sinceSeq, required limit}) => _groupLogOnLease(
        roomId,
        sinceSeq: sinceSeq,
        limit: limit,
        capabilities: proof.capabilities,
        lease: proof.lease,
      ),
    );
  }

  Future<HostedGroupLogPage> _groupLogOnLease(
    String roomId, {
    required int sinceSeq,
    required int limit,
    required GroupsCapabilities capabilities,
    required _GroupSocketLease lease,
  }) async {
    final room = _groupIdentifier(roomId, 'room id');
    if (sinceSeq < 0 || limit < 1 || limit > capabilities.maxLogLimit) {
      throw const FormatException('invalid group log window');
    }
    final result = await _requestGroupOnLease(lease, 'groups.log', {
      'room_id': room,
      'since_seq': sinceSeq,
      'limit': limit,
      'include_disbanded': false,
    });
    try {
      return HostedGroupLogPage.fromJson(
        result,
        expectedRoomId: room,
        sinceSeq: sinceSeq,
      );
    } on FormatException {
      throw const TuiGatewayRpcError(
        'groups.log',
        'Hermes returned an invalid room log',
      );
    }
  }

  void _requireReadbackMethod(
    ({GroupsCapabilities capabilities, _GroupSocketLease lease}) proof,
    GroupMethod method,
  ) {
    _requireGroupSocketLease(proof.lease, method.wire);
    if (!proof.capabilities.supports(method)) {
      throw TuiGatewayRpcError(
        method.wire,
        'Group operation is unavailable',
        code: -32601,
      );
    }
  }

  Future<HostedGroupLogPage> sendGroupText({
    required String roomId,
    required String text,
    required String eventId,
    required String threadId,
    required int generation,
  }) async {
    final proof = await _requireGroupMethod(
      GroupMethod.send,
      generation: generation,
    );
    _requireReadbackMethod(proof, GroupMethod.log);
    final room = _groupIdentifier(roomId, 'room id');
    final clientEventId = _groupIdentifier(eventId, 'event id');
    final durableEventId = durableGroupEventId(clientEventId);
    final thread = _groupIdentifier(threadId, 'thread id');
    if (text.trim().isEmpty || utf8.encode(text).length > 65536) {
      throw const FormatException('invalid group message');
    }
    final result = await _requestGroupOnLease(proof.lease, 'groups.send', {
      'room_id': room,
      'event_id': clientEventId,
      'payload': {'text': text, 'thread_id': thread},
    });
    if (result['accepted'] != true ||
        result['client_event_id'] != clientEventId ||
        result['event'] is! Map) {
      throw const TuiGatewayRpcError(
        'groups.send',
        'Hermes did not confirm the room message',
      );
    }
    late final HostedGroupEvent acknowledged;
    try {
      acknowledged = HostedGroupEvent.fromJson(result['event'], roomId: room);
      if (acknowledged.eventId != durableEventId ||
          acknowledged.kind != 'message.user' ||
          acknowledged.actor.kind != 'user' ||
          acknowledged.actor.id != 'desktop' ||
          acknowledged.publicText != text ||
          acknowledged.threadId != thread) {
        throw const FormatException('event acknowledgement tuple mismatch');
      }
    } on FormatException {
      throw const TuiGatewayRpcError(
        'groups.send',
        'Hermes did not confirm the room message',
      );
    }
    _requireGroupSocketLease(proof.lease, 'groups.send');
    final page = await _awaitGroupSocketLease(
      proof.lease,
      'groups.log',
      () => _groupLogOnLease(
        room,
        sinceSeq: acknowledged.sequence - 1,
        limit: 100,
        capabilities: proof.capabilities,
        lease: proof.lease,
      ),
    );
    final immutableMatches = page.events
        .where((entry) => entry.immutableEquals(acknowledged))
        .length;
    if (page.authority.epoch < acknowledged.authorityEpoch ||
        immutableMatches != 1) {
      throw const TuiGatewayRpcError(
        'groups.send',
        'Hermes did not publish the acknowledged room message',
      );
    }
    return page;
  }

  Future<HostedGroupRoom> createGroup({
    required String roomId,
    required String name,
    required List<Map<String, dynamic>> members,
    required int generation,
  }) async {
    final proof = await _requireGroupMethod(
      GroupMethod.create,
      generation: generation,
    );
    _requireReadbackMethod(proof, GroupMethod.state);
    final requestedRoom = _groupIdentifier(roomId, 'room id');
    final result = await _requestGroupOnLease(proof.lease, 'groups.create', {
      'room_id': requestedRoom,
      'name': _groupName(name),
      'members': members,
    });
    try {
      final created = HostedGroupRoom.fromJson(result['room']);
      if (created.roomId != requestedRoom) {
        throw const FormatException('room identity mismatch');
      }
    } on FormatException {
      throw const TuiGatewayRpcError(
        'groups.create',
        'Hermes did not confirm the created room',
      );
    }
    return _groupStateOnLease(requestedRoom, lease: proof.lease);
  }

  Future<HostedGroupRoom> renameGroup({
    required String roomId,
    required String eventId,
    required String name,
    required int generation,
  }) async {
    final proof = await _requireGroupMethod(
      GroupMethod.rename,
      generation: generation,
    );
    _requireReadbackMethod(proof, GroupMethod.state);
    final room = _groupIdentifier(roomId, 'room id');
    await _requestGroupOnLease(proof.lease, 'groups.rename', {
      'room_id': room,
      'event_id': _groupIdentifier(eventId, 'event id'),
      'name': _groupName(name),
    });
    return _groupStateOnLease(room, lease: proof.lease);
  }

  Future<HostedGroupRoom> stopGroup({
    required String roomId,
    required String cancelId,
    required int generation,
  }) async {
    final proof = await _requireGroupMethod(
      GroupMethod.stop,
      generation: generation,
    );
    _requireReadbackMethod(proof, GroupMethod.state);
    final room = _groupIdentifier(roomId, 'room id');
    await _requestGroupOnLease(proof.lease, 'groups.stop', {
      'room_id': room,
      'cancel_id': _groupIdentifier(cancelId, 'cancel id'),
    });
    return _groupStateOnLease(room, lease: proof.lease);
  }

  Future<HostedGroupRoom> retryGroupTask({
    required String roomId,
    required String taskId,
    required int generation,
  }) async {
    final proof = await _requireGroupMethod(
      GroupMethod.retry,
      generation: generation,
    );
    _requireReadbackMethod(proof, GroupMethod.state);
    final room = _groupIdentifier(roomId, 'room id');
    await _requestGroupOnLease(proof.lease, 'groups.retry', {
      'room_id': room,
      'task_id': _groupIdentifier(taskId, 'task id'),
    });
    return _groupStateOnLease(room, lease: proof.lease);
  }

  Future<HostedGroupRoom> approveGroupTask({
    required String roomId,
    required String memberId,
    required String taskId,
    required int executionGeneration,
    required String choice,
    required String requestId,
    required int generation,
  }) async {
    final proof = await _requireGroupMethod(
      GroupMethod.approve,
      generation: generation,
    );
    _requireReadbackMethod(proof, GroupMethod.state);
    final room = _groupIdentifier(roomId, 'room id');
    await _requestGroupOnLease(proof.lease, 'groups.approve', {
      'room_id': room,
      'member_id': _groupIdentifier(memberId, 'member id'),
      'task_id': _groupIdentifier(taskId, 'task id'),
      'execution_generation': executionGeneration,
      'choice': _groupIdentifier(choice, 'approval choice'),
      'request_id': _groupIdentifier(requestId, 'request id'),
    });
    return _groupStateOnLease(room, lease: proof.lease);
  }

  Future<HostedGroupRoom> disbandGroup({
    required String roomId,
    required String cancelId,
    required int generation,
  }) async {
    final proof = await _requireGroupMethod(
      GroupMethod.disband,
      generation: generation,
    );
    _requireReadbackMethod(proof, GroupMethod.state);
    final room = _groupIdentifier(roomId, 'room id');
    await _requestGroupOnLease(proof.lease, 'groups.disband', {
      'room_id': room,
      'cancel_id': _groupIdentifier(cancelId, 'cancel id'),
    });
    return _groupStateOnLease(room, lease: proof.lease, includeDisbanded: true);
  }

  static String _groupIdentifier(String value, String label) {
    final safe = value.trim();
    if (safe.isEmpty ||
        safe != value ||
        safe.runes.length > 128 ||
        safe.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw FormatException('invalid $label');
    }
    return safe;
  }

  static String _groupName(String value) {
    final safe = value.trim();
    if (safe.isEmpty || safe.runes.length > 200) {
      throw const FormatException('invalid group name');
    }
    return safe;
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => resumeExisting(storedSessionId, profile: profile);

  @override
  Future<List<AgentProfile>> loadMentionProfiles() async {
    try {
      return await listProfiles();
    } on TuiGatewayRpcError catch (error) {
      if (error.code != -32601 && error.code != 404 && error.code != 405) {
        rethrow;
      }
      return _dashboard.getProfiles();
    }
  }

  Future<List<AgentProfile>> listProfiles({
    bool includeSessions = false,
    Map<String, String> preferredSessionIds = const {},
  }) async {
    final rosterGeneration = BotMentionRoster.shared.generation(_connection.id);
    await connect();
    final safePreferredSessionIds = <String, String>{};
    if (includeSessions) {
      final validProfile = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
      for (final entry in preferredSessionIds.entries) {
        final profile = entry.key.trim();
        final sessionId = _safeBotModeId(entry.value);
        if (validProfile.hasMatch(profile) &&
            sessionId != null &&
            !sessionId.startsWith('mob-')) {
          safePreferredSessionIds[profile] = sessionId;
        }
      }
    }
    final result = await _request('profiles.list', {
      'include_sessions': includeSessions,
      if (safePreferredSessionIds.isNotEmpty)
        'preferred_session_ids': safePreferredSessionIds,
    });
    final rawProfiles = result['profiles'];
    if (rawProfiles is! List) {
      throw const TuiGatewayRpcError(
        'profiles.list',
        'Hermes returned an invalid profile roster',
      );
    }
    try {
      final profiles = List<AgentProfile>.unmodifiable(
        rawProfiles
            .whereType<Map>()
            .map((raw) => AgentProfile.fromJson(Map<String, dynamic>.from(raw)))
            .where((profile) => profile.name.trim().isNotEmpty),
      );
      BotMentionRoster.shared.replace(
        _connection.id,
        _connection.label,
        profiles,
        expectedGeneration: rosterGeneration,
      );
      return profiles;
    } on FormatException {
      throw const TuiGatewayRpcError(
        'profiles.list',
        'Hermes returned an invalid profile roster',
      );
    }
  }

  /// Creates a profile through the same native Gateway contract used by
  /// Hermes Desktop Bot Mode.
  ///
  /// Model, SOUL and auth sharing are part of the single authoritative
  /// `profiles.create` write. This deliberately avoids the legacy mobile
  /// sequence that created a profile through Dashboard REST and then changed
  /// the model of the running default gateway as a separate side effect.
  @override
  Future<void> createProfileNative({
    required String name,
    String? cloneFrom,
    String description = '',
    String soul = '',
    String model = '',
    String provider = '',
    bool noSkills = false,
    bool shareAuth = true,
  }) async {
    const method = 'profiles.create';
    if (_connection.readOnly) {
      throw const TuiGatewayRpcError(method, 'Connection is read only');
    }
    final profile = name.trim();
    final source = cloneFrom?.trim();
    final selectedModel = model.trim();
    final selectedProvider = provider.trim();
    final validName = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
    if (!validName.hasMatch(profile) ||
        (source != null && source.isNotEmpty && !validName.hasMatch(source))) {
      throw const TuiGatewayRpcError(method, 'Invalid profile name');
    }
    if (selectedModel.isEmpty != selectedProvider.isEmpty) {
      throw const TuiGatewayRpcError(
        method,
        'Profile model and provider must be configured together',
      );
    }
    final safeDescription = description.trim();
    if (safeDescription.runes.length > 2048 || soul.runes.length > 64 * 1024) {
      throw const TuiGatewayRpcError(
        method,
        'Profile metadata exceeds the mobile safety limit',
      );
    }

    await connect();
    final payload = <String, dynamic>{
      'name': profile,
      'description': safeDescription,
      'clone_from': source == null || source.isEmpty ? null : source,
      'no_skills': noSkills,
      'share_auth': shareAuth,
      'mirror_credentials': shareAuth,
      if (soul.trim().isNotEmpty) 'soul': soul,
      if (selectedModel.isNotEmpty) ...{
        'model': selectedModel,
        'provider': selectedProvider,
      },
    };
    final result = await _request(method, payload);
    if (result['ok'] == false) {
      throw const TuiGatewayRpcError(
        method,
        'Hermes did not create the profile',
      );
    }
  }

  @override
  Future<AgentProfileAvatar?> profileAvatar(String profileName) async {
    const method = 'profiles.get_asset';
    final profile = profileName.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(profile)) {
      throw const TuiGatewayRpcError(method, 'Invalid profile name');
    }
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.profileAssets,
      method,
      {'name': profile, 'asset': 'avatar'},
    );
    if (result['found'] == false) return null;
    final data = result['data'];
    if (result['found'] != true || data is! String) {
      _capabilityCache.mark(
        DesktopGatewayCapability.profileAssets,
        DesktopGatewayCapabilityState.invalid,
      );
      throw const TuiGatewayRpcError(
        method,
        'Hermes returned an invalid profile avatar',
      );
    }
    try {
      return AgentProfileAvatar.fromDataUri(data);
    } on FormatException {
      _capabilityCache.mark(
        DesktopGatewayCapability.profileAssets,
        DesktopGatewayCapabilityState.invalid,
      );
      throw const TuiGatewayRpcError(
        method,
        'Hermes returned an invalid profile avatar',
      );
    }
  }

  /// Persiste la identidad visible del bot (título/forma/color) con la
  /// semántica del editor de Hermes Desktop. El namespace `hermes-bots` se
  /// reemplaza entero server-side (es UNA entrada de `ui_meta`), así que la
  /// escritura relee el roster justo antes — el mismo patrón RMW de
  /// [persistCanonicalBotChat] — para no pisar campos ajenos (`chat`,
  /// `group` y extensiones desconocidas). Los assets image/pet no se reescriben.
  @override
  Future<void> saveProfileBotMeta({
    required String profile,
    String? title,
    String? shape,
    String? colorHex,
    bool? hidden,
    bool? pinned,
    int? createdAtMs,
    BotVisualIdentity? identity,
  }) async {
    const method = 'profiles.configure';
    final owner = profile.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(owner)) {
      throw const TuiGatewayRpcError(method, 'Invalid profile name');
    }
    final safeTitle = title?.trim();
    if (safeTitle != null && safeTitle.runes.length > 128) {
      throw const TuiGatewayRpcError(method, 'Invalid bot title');
    }
    final safeShape = shape?.trim().toLowerCase();
    if (safeShape != null &&
        BlobatarShapeWire.tryParse(safeShape) == null &&
        !ClassicFaceIdentity.shapes.contains(safeShape)) {
      throw const TuiGatewayRpcError(method, 'Invalid bot shape');
    }
    final safeColor = colorHex?.trim().toLowerCase();
    if (safeColor != null && !RegExp(r'^#[0-9a-f]{6}$').hasMatch(safeColor)) {
      throw const TuiGatewayRpcError(method, 'Invalid bot color');
    }
    if (createdAtMs != null && createdAtMs < 0) {
      throw const TuiGatewayRpcError(method, 'Invalid bot creation stamp');
    }

    final botMeta = <String, dynamic>{};
    final remove = <String>{};
    if (title != null) {
      if (safeTitle!.isEmpty) {
        remove.add('title');
      } else {
        botMeta['title'] = safeTitle;
      }
    }
    if (shape != null) botMeta['shape'] = safeShape;
    if (colorHex != null) botMeta['color'] = safeColor;
    if (shape != null || colorHex != null) {
      botMeta['imageKind'] = 'shape';
      botMeta['custom'] = true;
    }
    if (hidden != null) botMeta['hidden'] = hidden;
    if (pinned != null) botMeta['pinned'] = pinned;
    if (createdAtMs != null) botMeta['created'] = createdAtMs;
    if (identity != null) botMeta.addAll(identity.toBotModeMetadata());
    try {
      await patchBotMetadata(owner, botMeta, remove: remove);
    } on TuiGatewayRpcError {
      rethrow;
    } catch (_) {
      throw const TuiGatewayRpcError(
        method,
        'Hermes did not persist the bot identity',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> roomLinkRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    const allowed = {
      'groups.capabilities',
      'groups.peer.invite',
      'groups.peer.register',
      'groups.peer.revoke',
    };
    if (!allowed.contains(method) ||
        (_connection.readOnly && method != 'groups.capabilities')) {
      throw TuiGatewayRpcError(method, 'Room linking unavailable');
    }
    await connect();
    return _request(method, params);
  }

  late final BotProfileClient _botProfiles = BotProfileClient((
    method,
    params,
  ) async {
    if (_connection.readOnly) {
      throw const TuiGatewayRpcError(
        'profiles.configure',
        'Connection is read only',
      );
    }
    await connect();
    return _request(method, params);
  });

  @override
  Future<void> patchBotMetadata(
    String profile,
    Map<String, dynamic> patch, {
    Set<String> remove = const {},
  }) => _botProfiles.patchBotMetadata(profile, patch, remove: remove);

  @override
  Future<Map<String, dynamic>> describeBotProfile(String profile) =>
      _botProfiles.describeBotProfile(profile);

  @override
  Future<Map<String, dynamic>> configureBotProfile(
    String profile,
    Map<String, dynamic> changes,
  ) => _botProfiles.configureBotProfile(profile, changes);

  @override
  Future<bool> canGenerateBotAvatar() => _botProfiles.canGenerateBotAvatar();

  @override
  Future<AgentProfileAvatar> generateBotAvatar(String prompt) =>
      _botProfiles.generateBotAvatar(prompt);

  @override
  Future<String> duplicateBotProfile(String profile) =>
      _botProfiles.duplicateBotProfile(profile);

  /// Escribe el avatar del profile en el asset store server-side, como hace
  /// el editor de Hermes Desktop al guardar (la imagen no cabe en `ui_meta`,
  /// que viaja en cada `profiles.list` y está capada a 64KB). El data URI se
  /// valida en cliente con las mismas cotas que la lectura.
  @override
  Future<void> setProfileAvatar({
    required String profile,
    required String dataUri,
  }) async {
    const method = 'profiles.set_asset';
    final owner = profile.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(owner)) {
      throw const TuiGatewayRpcError(method, 'Invalid profile name');
    }
    try {
      AgentProfileAvatar.fromDataUri(dataUri);
    } on FormatException {
      throw const TuiGatewayRpcError(method, 'Invalid profile avatar payload');
    }
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.profileAssets,
      method,
      {'name': owner, 'asset': 'avatar', 'data': dataUri},
    );
    if (result['ok'] != true) {
      throw const TuiGatewayRpcError(
        method,
        'Hermes did not store the profile avatar',
      );
    }
  }

  /// Borra el avatar del profile: el roster vuelve a la cara geométrica
  /// shape/color.
  @override
  Future<void> clearProfileAvatar(String profile) async {
    const method = 'profiles.set_asset';
    final owner = profile.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(owner)) {
      throw const TuiGatewayRpcError(method, 'Invalid profile name');
    }
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.profileAssets,
      method,
      {'name': owner, 'asset': 'avatar', 'clear': true},
    );
    if (result['ok'] != true) {
      throw const TuiGatewayRpcError(
        method,
        'Hermes did not clear the profile avatar',
      );
    }
  }

  // ── Creación de bots (paridad Bot Mode, CreateAgentDialog) ─────────────

  /// Catálogo de skills del profile origen vía `profiles.describe`. Devuelve
  /// `null` cuando el gateway no expone el método (-32601): el diálogo de
  /// creación degrada ocultando la sección, como el checklist staged de
  /// Desktop con un gateway antiguo.
  @override
  Future<List<DesktopProfileSkill>?> describeProfileSkills(
    String profile,
  ) async {
    const method = 'profiles.describe';
    final owner = profile.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(owner)) {
      throw const TuiGatewayRpcError(method, 'Invalid profile name');
    }
    await connect();
    final Map<String, dynamic> result;
    try {
      result = await _request(method, {'name': owner});
    } on TuiGatewayRpcError catch (error) {
      if (error.code == -32601) return null;
      rethrow;
    }
    final raw = result['skills'];
    if (raw is! List) {
      throw const TuiGatewayRpcError(
        method,
        'Hermes returned an invalid skill catalog',
      );
    }
    final skills = <DesktopProfileSkill>[];
    final seen = <String>{};
    for (final entry in raw) {
      if (entry is! Map) continue;
      final name = entry['name']?.toString().trim() ?? '';
      if (name.isEmpty ||
          name.length > 128 ||
          name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f) ||
          !seen.add(name)) {
        continue;
      }
      if (skills.length >= 512) break;
      skills.add(
        DesktopProfileSkill(name: name, enabled: entry['enabled'] != false),
      );
    }
    return List<DesktopProfileSkill>.unmodifiable(skills);
  }

  @override
  Future<void> setProfileDisabledSkills({
    required String profile,
    required List<String> disabledSkills,
  }) async {
    const method = 'profiles.configure';
    final owner = profile.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(owner)) {
      throw const TuiGatewayRpcError(method, 'Invalid profile name');
    }
    final safe = <String>[];
    for (final skill in disabledSkills) {
      final name = skill.trim();
      if (name.isEmpty ||
          name.length > 128 ||
          name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
        continue;
      }
      if (safe.length >= 512) break;
      safe.add(name);
    }
    await connect();
    final result = await _request(method, {
      'name': owner,
      'disabled_skills': safe,
    });
    if (result['ok'] == false) {
      throw const TuiGatewayRpcError(
        method,
        'Hermes did not apply the skill selection',
      );
    }
  }

  // ── Mascotas nativas por perfil (pet.*) ───────────────────────────────

  /// Params comunes de los RPCs `pet.*`: `profile` solo se envía cuando hay
  /// uno explícito (vacío = perfil de arranque del gateway, ver
  /// `_profile_scoped` upstream).
  Map<String, dynamic> _petParams(String profile, {String method = 'pet.*'}) {
    final trimmed = profile.trim();
    if (trimmed.isNotEmpty &&
        !RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(trimmed)) {
      throw TuiGatewayRpcError(method, 'Invalid profile name');
    }
    return {if (trimmed.isNotEmpty) 'profile': trimmed};
  }

  static String _petSlug(String slug, String method) {
    final safe = slug.trim();
    if (safe.isEmpty || safe.length > 128) {
      throw TuiGatewayRpcError(method, 'Invalid pet slug');
    }
    return safe;
  }

  /// Mascota activa del perfil. Upstream es fail-open (`{enabled: false}`
  /// ante cualquier problema), así que esto solo lanza ante error de
  /// transporte o de capacidad (`-32601` en gateways antiguos).
  @override
  Future<ProfilePetInfo> profilePetInfo({
    String profile = '',
    String? knownRevision,
  }) async {
    const method = 'pet.info';
    final revision = knownRevision?.trim() ?? '';
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.profilePets,
      method,
      {
        ..._petParams(profile, method: method),
        if (revision.isNotEmpty) 'knownRevision': revision,
      },
    );
    return ProfilePetInfo.fromJson(result);
  }

  /// Galería adoptable del perfil (petdex mezclada con lo instalado).
  /// [localOnly] evita el fetch remoto del manifest en el gateway.
  @override
  Future<ProfilePetGallery> profilePetGallery({
    String profile = '',
    bool localOnly = false,
  }) async {
    const method = 'pet.gallery';
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.profilePets,
      method,
      {
        ..._petParams(profile, method: method),
        if (localOnly) 'localOnly': true,
      },
    );
    return ProfilePetGallery.fromJson(result);
  }

  /// Miniatura (data URI PNG) de una mascota para listas. Upstream es
  /// fail-open (`{ok: false}`), que aquí se traduce a `null`.
  @override
  Future<String?> profilePetThumb({
    String profile = '',
    required String slug,
    String url = '',
  }) async {
    const method = 'pet.thumb';
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.profilePets,
      method,
      {
        ..._petParams(profile, method: method),
        'slug': _petSlug(slug, method),
        if (url.trim().isNotEmpty) 'url': url.trim(),
      },
    );
    if (result['ok'] != true) return null;
    final dataUri = result['dataUri'];
    return dataUri is String && dataUri.isNotEmpty ? dataUri : null;
  }

  /// Adopta una mascota en el perfil: el gateway la instala si hace falta y
  /// escribe `display.pet.slug` + `enabled=true` en la config del perfil.
  @override
  Future<ProfilePetSelection> profilePetSelect({
    String profile = '',
    required String slug,
  }) async {
    const method = 'pet.select';
    final safeSlug = _petSlug(slug, method);
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.profilePets,
      method,
      {..._petParams(profile, method: method), 'slug': safeSlug},
    );
    if (result['ok'] != true) {
      throw const TuiGatewayRpcError(method, 'Hermes did not select the pet');
    }
    return ProfilePetSelection(
      slug: (result['slug'] ?? safeSlug).toString(),
      displayName: (result['displayName'] ?? '').toString(),
    );
  }

  /// Apaga la mascota del perfil (`display.pet.enabled=false`). Es la
  /// semántica del "sin mascota" del picker de Hermes Desktop.
  @override
  Future<bool> profilePetDisable({String profile = ''}) async {
    const method = 'pet.disable';
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.profilePets,
      method,
      _petParams(profile, method: method),
    );
    return result['ok'] == true;
  }

  /// Persists the canonical Bot Chat using the same server-side namespace as
  /// Hermes Bot Mode, without confusing the durable stored id with the live
  /// runtime id.
  ///
  /// `session.create` does not write an empty row to state.db. Materialising the
  /// title first makes the stored id resumable before it is published in
  /// `ui_meta`. The fresh roster read is a read-modify-write guard: the
  /// `hermes-bots` value is replaced as one top-level ui_meta entry by Hermes,
  /// so Android must preserve fields owned by Desktop (title, shape, colour,
  /// etc.). A different pin discovered during that read is a concurrent owner
  /// and fails closed instead of minting two forever-chats.
  Future<void> persistCanonicalBotChat({
    required String profile,
    required String runtimeSessionId,
    required String storedSessionId,
  }) async {
    final owner = profile.trim();
    final runtimeId = _safeBotModeId(runtimeSessionId);
    final storedId = _safeBotModeId(storedSessionId);
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(owner) ||
        runtimeId == null ||
        storedId == null ||
        storedId.startsWith('mob-')) {
      throw const TuiGatewayRpcError(
        'profiles.configure',
        'Invalid canonical Bot Chat identity',
      );
    }

    await connect();
    var current = await _botModeProfile(owner);
    _rejectConcurrentBotChatPin(current, storedId);

    final title = await _request('session.title', {
      'session_id': runtimeId,
      'title': 'Bot Chat',
    });
    if (title['pending'] == true || title['title'] != 'Bot Chat') {
      throw const TuiGatewayRpcError(
        'session.title',
        'Hermes did not persist the canonical Bot Chat row',
      );
    }

    // The create request already asks for hidden:true. Re-applying it to the
    // runtime proves the now-materialised row is hidden. Older gateways may not
    // expose this optional method; they keep the chat visible but can still own
    // a canonical server-side pin.
    try {
      await ensureCanonicalBotChatHidden(runtimeId);
    } on TuiGatewayRpcError catch (error) {
      if (error.code != -32601) rethrow;
    }

    // Re-read after materialisation so a concurrent Desktop edit cannot be
    // overwritten by the metadata snapshot taken before session.title.
    current = await _botModeProfile(owner);
    _rejectConcurrentBotChatPin(current, storedId);
    // RMW is deep-equal to the authoritative Desktop namespace except for the
    // pin. New Bot Mode writes keep large art in profiles.set_asset, but legacy
    // servers may already contain image/pet fields here; deleting them while
    // adopting a chat would be destructive.
    final botMeta = <String, dynamic>{...current.botModeUiMeta}
      ..['chat'] = storedId;
    final configured = await _request('profiles.configure', {
      'name': owner,
      'ui_meta': {'hermes-bots': botMeta},
    });
    final applied = configured['applied'];
    if (configured['ok'] != true ||
        applied is! Map ||
        applied['ui_meta'] != true) {
      throw const TuiGatewayRpcError(
        'profiles.configure',
        'Hermes did not persist the canonical Bot Chat pin',
      );
    }

    final persisted = await _botModeProfile(owner);
    if (persisted.botChatSessionId != storedId) {
      throw const TuiGatewayRpcError(
        'profiles.configure',
        'Hermes did not confirm the canonical Bot Chat pin',
      );
    }
  }

  /// Revalidates the plugin-owned pin immediately before an official Bot Chat
  /// prompt. The route can remain mounted while Desktop repins or removes its
  /// chat; continuing with the captured id would target the wrong transcript.
  Future<void> assertCanonicalBotChat({
    required String profile,
    required String storedSessionId,
  }) async {
    final owner = profile.trim();
    final storedId = _safeBotModeId(storedSessionId);
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(owner) ||
        storedId == null ||
        storedId.startsWith('mob-')) {
      throw const TuiGatewayRpcError(
        'profiles.list',
        'Invalid canonical Bot Chat identity',
      );
    }
    await connect();
    final current = await _botModeProfile(owner);
    if (current.hasInvalidBotChatPin || current.botChatSessionId != storedId) {
      throw const TuiGatewayRpcError(
        'profiles.list',
        'Canonical Bot Chat pin changed or was removed',
      );
    }
  }

  Future<AgentProfile> _botModeProfile(String owner) async {
    final profiles = await listProfiles();
    for (final candidate in profiles) {
      if (candidate.name == owner) return candidate;
    }
    throw const TuiGatewayRpcError(
      'profiles.configure',
      'Hermes profile disappeared before Bot Chat persistence',
    );
  }

  static void _rejectConcurrentBotChatPin(
    AgentProfile profile,
    String storedSessionId,
  ) {
    if (profile.hasInvalidBotChatPin) {
      throw const TuiGatewayRpcError(
        'profiles.configure',
        'Canonical Bot Chat pin is malformed',
      );
    }
    final existingPin = profile.botChatSessionId;
    if (existingPin != null && existingPin != storedSessionId) {
      throw const TuiGatewayRpcError(
        'profiles.configure',
        'Canonical Bot Chat pin changed concurrently',
      );
    }
  }

  /// Hides an already-resumed canonical chat. The caller must supply the live
  /// runtime id returned by `session.resume`; a stored id is deliberately never
  /// accepted as an implicit lookup because `session.set_hidden` is runtime
  /// scoped in Hermes Agent.
  Future<void> ensureCanonicalBotChatHidden(String runtimeSessionId) async {
    final runtimeId = _safeBotModeId(runtimeSessionId);
    if (runtimeId == null || runtimeId.startsWith('mob-')) {
      throw const TuiGatewayRpcError(
        'session.set_hidden',
        'Invalid Bot Chat runtime identity',
      );
    }
    await connect();
    final result = await _request('session.set_hidden', {
      'session_id': runtimeId,
      'hidden': true,
    });
    if (result['hidden'] != true) {
      throw const TuiGatewayRpcError(
        'session.set_hidden',
        'Hermes did not confirm the hidden Bot Chat state',
      );
    }
  }

  static String? _safeBotModeId(String raw) {
    final value = raw.trim();
    if (value.isEmpty ||
        value.length > 512 ||
        value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return null;
    }
    return value;
  }

  @override
  Future<DesktopSessionBinding> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    final result = await _requestExclusiveSessionMutation('session.resume', {
      'session_id': storedSessionId,
      'source': 'desktop',
      if (profile.trim().isNotEmpty) 'profile': profile.trim(),
      if (omitMessages) 'omit_messages': true,
      if (deferHistory) 'defer_history': true,
    }, preserveCapabilityFailure: true);
    return _parseSessionBinding(
      result,
      requestedStoredSessionId: storedSessionId,
      created: false,
      method: 'session.resume',
    );
  }

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    final result = await _requestExclusiveSessionMutation('session.resume', {
      'session_id': storedSessionId,
      'source': 'desktop',
      // Recovery rebinds a durable session after a rejected live runtime. Its
      // transcript is already REST/snapshot authority; omitting it keeps a
      // heavily-compacted lineage on Gateway's bounded tip-only resume path.
      'omit_messages': true,
      if (profile.trim().isNotEmpty) 'profile': profile.trim(),
    }, preserveCapabilityFailure: true);
    return _parseSessionSnapshot(
      result,
      requestedStoredSessionId: storedSessionId,
      created: false,
      method: 'session.resume',
      rememberLegacyRuntime: false,
    );
  }

  /// Reattaches only when the exact current transport advertises one matching
  /// durable/runtime pair. No helper in this transaction may reconnect.
  @override
  Future<DesktopRosterBoundRecovery> resumeAdvertisedExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    const activeMethod = 'session.active_list';
    const resumeMethod = 'session.resume';
    if (storedSessionId.isEmpty ||
        storedSessionId.length > 1024 ||
        storedSessionId != storedSessionId.trim()) {
      throw const TuiGatewayRpcError(
        activeMethod,
        'Invalid durable session identity',
      );
    }
    if (!_capabilityCache.canAttempt(
      DesktopGatewayCapability.sessionActiveList,
    )) {
      throw const TuiGatewayRpcError(
        activeMethod,
        'Hermes Desktop capability is unavailable',
        code: -32601,
      );
    }

    await connect();
    final lease = _captureSessionRosterLease(activeMethod);
    DesktopActiveSessionList roster;
    try {
      final rosterResult = await _requestSessionRosterLease(
        lease,
        activeMethod,
        const <String, dynamic>{},
      );
      roster = DesktopActiveSessionList.fromJson(rosterResult);
      _requireSessionRosterLease(lease, activeMethod);
      _capabilityCache.mark(
        DesktopGatewayCapability.sessionActiveList,
        DesktopGatewayCapabilityState.supported,
      );
    } on FormatException {
      _capabilityCache.mark(
        DesktopGatewayCapability.sessionActiveList,
        DesktopGatewayCapabilityState.invalid,
      );
      throw const TuiGatewayRpcError(
        activeMethod,
        'Hermes returned an invalid active session inventory',
      );
    } on TuiGatewayRpcError catch (error) {
      if (error.code == -32601) {
        _capabilityCache.mark(
          DesktopGatewayCapability.sessionActiveList,
          DesktopGatewayCapabilityState.unsupported,
        );
      }
      rethrow;
    }
    if (roster.hasMalformedRows) {
      throw const TuiGatewayRpcError(
        activeMethod,
        'Hermes returned an invalid active session inventory',
      );
    }
    final matches = roster.sessions
        .where((row) => row.storedSessionId == storedSessionId)
        .toList(growable: false);
    if (matches.isEmpty) {
      throw const TuiGatewayRpcError(
        activeMethod,
        'Hermes did not advertise an active runtime for this session',
        data: {'reason': rosterSessionNotActiveReason},
        origin: CompressionFailureOrigin.localPreflight,
      );
    }
    if (matches.length != 1) {
      throw const TuiGatewayRpcError(
        activeMethod,
        'Hermes did not prove one active session owner',
      );
    }
    final advertised = matches.single;

    final capabilityAllowed = await _awaitSessionRosterLease(
      lease,
      'gateway.capabilities',
      () => _resolveExclusiveSubmitCapability(lease.generation, lease.channel),
    );
    if (!capabilityAllowed) {
      throw const TuiGatewayRpcError(
        resumeMethod,
        'Hermes Agent cannot safely attach this session',
        origin: CompressionFailureOrigin.localPreflight,
      );
    }
    final result = await _requestSessionRosterLease(lease, resumeMethod, {
      'session_id': storedSessionId,
      'source': 'desktop',
      'omit_messages': true,
      if (profile.trim().isNotEmpty) 'profile': profile.trim(),
    });
    final snapshot = _parseSessionSnapshot(
      result,
      requestedStoredSessionId: storedSessionId,
      created: false,
      method: resumeMethod,
      rememberLegacyRuntime: false,
    );
    _requireSessionRosterLease(lease, resumeMethod);
    if (snapshot.runtimeSessionId != advertised.runtimeSessionId ||
        snapshot.storedSessionId != storedSessionId) {
      throw const TuiGatewayRpcError(
        resumeMethod,
        'Hermes returned a session outside the active roster proof',
      );
    }
    return DesktopRosterBoundRecovery._(snapshot, this, lease);
  }

  @override
  bool consumeRosterBoundRecovery(DesktopRosterBoundRecovery recovery) {
    if (recovery._consumed || !identical(recovery._issuer, this)) return false;
    try {
      final lease = recovery._transportProof;
      if (lease is! _SessionRosterSocketLease) return false;
      _requireSessionRosterLease(lease, 'session.resume');
    } catch (_) {
      return false;
    }
    recovery._consumed = true;
    _adoptWatchdogSnapshot(recovery.snapshot);
    return true;
  }

  @override
  bool consumeRosterBoundViewerAttachment(DesktopRosterBoundRecovery recovery) {
    if (!consumeRosterBoundRecovery(recovery)) return false;
    _rememberLegacyEventRuntime(recovery.snapshot.runtimeSessionId);
    return true;
  }

  @override
  RecoveryProof recoveryProofForSnapshot(
    DesktopSessionSnapshot snapshot, {
    required String connectionId,
    required String profile,
    required int bindGeneration,
    required int sessionGeneration,
    required int turnGeneration,
    required Set<RecoveryDomain> coverage,
    int? postSnapshotSequence,
  }) {
    final channel = _channel;
    if (channel == null) {
      throw StateError('recovery channel is not current');
    }
    return _replayCoordinator.mintRecoveryProof(
      connectionId: _connection.id,
      durableSessionId: snapshot.storedSessionId,
      runtimeSessionId: snapshot.runtimeSessionId,
      profile: profile,
      socketGeneration: _socketGeneration,
      channel: channel,
      bindGeneration: bindGeneration,
      sessionGeneration: sessionGeneration,
      turnGeneration: turnGeneration,
      replayEpoch: _replayEpoch,
      created: snapshot.created,
      durableIdentityExplicit: snapshot.storedSessionIdentityExplicit,
      identityAliasesConsistent: snapshot.identityAliasesConsistent,
      // Current upstream exposes neither cross-domain recovery coverage nor an
      // authoritative snapshot/replay cut. Caller assertions cannot mint either.
      coverage: const <RecoveryDomain>{},
      postSnapshotSequence: null,
    );
  }

  @override
  bool validateRecovery(RecoveryProof proof) {
    final channel = _channel;
    if (channel == null) return false;
    return _replayCoordinator.canCommitRecovery(
      proof,
      socketGeneration: _socketGeneration,
      channel: channel,
      replayEpoch: _replayEpoch,
    );
  }

  @override
  bool commitRecovery(RecoveryProof proof) {
    final channel = _channel;
    if (channel == null) return false;
    final committed = _replayCoordinator.commitRecovery(
      proof,
      socketGeneration: _socketGeneration,
      channel: channel,
      replayEpoch: _replayEpoch,
    );
    if (committed) {
      _rememberLegacyEventRuntime(proof.runtimeSessionId);
      _markWatchdogRuntimeBusy(proof.runtimeSessionId);
      for (final held in _replayCoordinator.takeCommittedRecoveryEvents(
        proof.runtimeSessionId,
      )) {
        if (_events.isClosed) break;
        _events.add(
          TuiGatewayEvent(
            type: held.type,
            sessionId: held.sessionId,
            sequence: held.sequence,
            transportGeneration: _socketGeneration,
            producerChannel: channel,
            payload: held.payload,
          ),
        );
      }
    }
    return committed;
  }

  @override
  bool recoveryAuthorityStillCurrent(RecoveryProof proof) {
    final channel = _channel;
    if (channel == null) return false;
    return _replayCoordinator.isRecoveryAuthorityCurrent(
      proof,
      socketGeneration: _socketGeneration,
      channel: channel,
      replayEpoch: _replayEpoch,
    );
  }

  @override
  void commitRecoveryRuntime(String runtimeSessionId) {
    // A bare runtime string carries no durable identity, generation or domain
    // coverage. Preserve ABI compatibility while failing closed.
  }

  @override
  Future<DesktopSessionBinding> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    final requestedModel = model.trim();
    // `hermes-agent` es el id OpenAI-compatible que anuncia el API Server,
    // no un modelo aceptado por proveedores como openai-codex. Persistirlo en
    // session.create provoca HTTP 400 en el primer turno de cada chat nuevo.
    // Omitido, Hermes resuelve el modelo activo real desde su configuración.
    final explicitModel =
        requestedModel.isNotEmpty &&
            requestedModel.toLowerCase() != 'hermes-agent'
        ? requestedModel
        : null;
    final result = await _requestExclusiveSessionMutation('session.create', {
      'source': 'desktop',
      if (profile.trim().isNotEmpty) 'profile': profile.trim(),
      'model': ?explicitModel,
      if (seedMessages.isNotEmpty) 'messages': seedMessages,
    });
    return _parseSessionBinding(
      result,
      requestedStoredSessionId: '',
      created: true,
      method: 'session.create',
    );
  }

  @override
  Future<DesktopSessionBinding> createForFirstSubmitConfigured({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    required DesktopSessionCreateConfig config,
  }) async {
    final selection = config.model;
    final requestedTitle = config.title?.trim();
    final safeTitle =
        requestedTitle != null &&
            requestedTitle.isNotEmpty &&
            requestedTitle.length <= 256 &&
            !requestedTitle.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)
        ? requestedTitle
        : null;
    final result = await _requestExclusiveSessionMutation('session.create', {
      'source': 'desktop',
      if (profile.trim().isNotEmpty) 'profile': profile.trim(),
      'title': ?safeTitle,
      if (config.hidden) 'hidden': true,
      if (selection != null) ...{
        'model': selection.modelId,
        'provider': selection.providerSlug,
      },
      if (config.reasoningEffort case final effort?)
        'reasoning_effort': effort.wire,
      if (config.fastMode case final mode?) 'fast': mode.enabled,
      'close_on_disconnect': false,
      if (seedMessages.isNotEmpty) 'messages': seedMessages,
    });
    return _parseSessionBinding(
      result,
      requestedStoredSessionId: '',
      created: true,
      method: 'session.create',
    );
  }

  DesktopSessionBinding _parseSessionBinding(
    Map<String, dynamic> result, {
    required String requestedStoredSessionId,
    required bool created,
    required String method,
    bool rememberLegacyRuntime = true,
  }) => DesktopSessionBinding.fromSnapshot(
    _parseSessionSnapshot(
      result,
      requestedStoredSessionId: requestedStoredSessionId,
      created: created,
      method: method,
      rememberLegacyRuntime: rememberLegacyRuntime,
    ),
  );

  DesktopSessionSnapshot _parseSessionSnapshot(
    Map<String, dynamic> result, {
    required String requestedStoredSessionId,
    required bool created,
    required String method,
    bool rememberLegacyRuntime = true,
  }) {
    try {
      final snapshot = DesktopSessionSnapshot.fromJson(
        result,
        requestedStoredSessionId: requestedStoredSessionId,
        created: created,
        method: method,
      );
      if (rememberLegacyRuntime) {
        _rememberLegacyEventRuntime(snapshot.runtimeSessionId);
        _adoptWatchdogSnapshot(snapshot);
      }
      return snapshot;
    } on FormatException {
      throw TuiGatewayRpcError(
        method,
        'Hermes returned an invalid session snapshot',
      );
    }
  }

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => _capabilityCache.state(capability);

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async {
    const method = 'session.activate';
    final runtime = _validatedRuntimeId(method, runtimeSessionId);
    final stored = storedSessionId.trim();
    if (stored.isEmpty) {
      throw const TuiGatewayRpcError(
        method,
        'Missing durable session identity',
      );
    }
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.sessionActivate,
      method,
      {'session_id': runtime, 'cols': 96},
    );
    try {
      final snapshot = DesktopSessionSnapshot.fromJson(
        result,
        requestedStoredSessionId: stored,
        created: false,
        method: method,
      );
      if (snapshot.runtimeSessionId != runtime ||
          snapshot.storedSessionId != stored) {
        throw const FormatException('session.activate identity mismatch');
      }
      _rememberLegacyEventRuntime(snapshot.runtimeSessionId);
      _adoptWatchdogSnapshot(snapshot);
      return snapshot;
    } on FormatException {
      _capabilityCache.mark(
        DesktopGatewayCapability.sessionActivate,
        DesktopGatewayCapabilityState.invalid,
      );
      throw const TuiGatewayRpcError(
        method,
        'Hermes returned an invalid activation snapshot',
      );
    }
  }

  @override
  Future<bool> closeSession(String runtimeSessionId) async {
    const method = 'session.close';
    final runtime = _validatedRuntimeId(method, runtimeSessionId);
    final result = await _request(method, {'session_id': runtime});
    final closed = result['closed'];
    if (closed is! bool) {
      throw const TuiGatewayRpcError(
        method,
        'Hermes returned an invalid close response',
        origin: CompressionFailureOrigin.malformed,
      );
    }
    if (closed) _retireWatchdogRuntime(runtime);
    return closed;
  }

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async {
    const method = 'session.active_list';
    final current = currentRuntimeSessionId.trim();
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.sessionActiveList,
      method,
      {if (current.isNotEmpty) 'current_session_id': current},
    );
    try {
      return DesktopActiveSessionList.fromJson(result);
    } on FormatException {
      _capabilityCache.mark(
        DesktopGatewayCapability.sessionActiveList,
        DesktopGatewayCapabilityState.invalid,
      );
      throw const TuiGatewayRpcError(
        method,
        'Hermes returned an invalid active session inventory',
      );
    }
  }

  @override
  Future<DesktopModelCatalog> modelOptions(
    String runtimeSessionId, {
    bool refresh = false,
  }) async {
    const method = 'model.options';
    final runtime = _validatedRuntimeId(method, runtimeSessionId);
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.modelOptions,
      method,
      {
        'session_id': runtime,
        'explicit_only': true,
        'include_unconfigured': false,
        'refresh': refresh,
      },
    );
    if (result['providers'] is! List) {
      _capabilityCache.mark(
        DesktopGatewayCapability.modelOptions,
        DesktopGatewayCapabilityState.invalid,
      );
      throw const TuiGatewayRpcError(
        method,
        'Hermes returned an invalid model catalog',
      );
    }
    return DesktopModelCatalog.fromJson(result);
  }

  @override
  Future<DesktopContextBreakdown> contextBreakdown(
    String runtimeSessionId,
  ) async {
    const method = 'session.context_breakdown';
    final runtime = _validatedRuntimeId(method, runtimeSessionId);
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.sessionContextBreakdown,
      method,
      {'session_id': runtime},
    );
    try {
      return DesktopContextBreakdown.fromJson(result);
    } on FormatException {
      _capabilityCache.mark(
        DesktopGatewayCapability.sessionContextBreakdown,
        DesktopGatewayCapabilityState.invalid,
      );
      throw const TuiGatewayRpcError(
        method,
        'Hermes returned an invalid context breakdown',
      );
    }
  }

  @override
  Future<DesktopCommandCatalog> commandsCatalog() async {
    const method = 'commands.catalog';
    final result = await _request(
      method,
      const <String, dynamic>{},
      timeout: const Duration(seconds: 20),
    );
    return DesktopCommandCatalog.fromJson(result);
  }

  @override
  Future<SlashCompletionBatch> completeSlash(String text) async {
    const method = 'complete.slash';
    final input = text;
    if (input.length > 4096 ||
        input.contains(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'))) {
      throw const TuiGatewayRpcError(method, 'Invalid slash completion input');
    }
    final result = await _request(method, {
      'text': input,
    }, timeout: const Duration(seconds: 20));
    return SlashCompletionBatch.fromJson(result, input: input);
  }

  @override
  Future<DesktopCommandRpcResult> slashExec(
    String runtimeSessionId,
    String command,
  ) async {
    const method = 'slash.exec';
    final result = await _requestExclusiveSessionMutation(method, {
      'session_id': _validatedRuntimeId(method, runtimeSessionId),
      'command': _validatedSlashCommand(method, command),
    }, timeout: const Duration(minutes: 3));
    return DesktopCommandRpcResult.fromJson(
      _payloadSanitizer.sanitizeCommandResponse(result),
      compressionWireEvidence: DesktopCompressionLegacyEvidence.fromWire(
        result,
      ),
    );
  }

  @override
  Future<DesktopCommandRpcResult> commandDispatch(
    String runtimeSessionId, {
    required String name,
    String arg = '',
  }) async {
    const method = 'command.dispatch';
    final commandName = CommandDescriptor.tryNormalizeName(name);
    if (commandName == null) {
      throw const TuiGatewayRpcError(method, 'Invalid command name');
    }
    final argument = arg.trim();
    if (argument.length > 4096 ||
        argument.contains(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'))) {
      throw const TuiGatewayRpcError(method, 'Invalid command argument');
    }
    final result = await _requestExclusiveSessionMutation(method, {
      'session_id': _validatedRuntimeId(method, runtimeSessionId),
      'name': commandName,
      'arg': argument,
    }, timeout: const Duration(minutes: 3));
    return DesktopCommandRpcResult.fromJson(
      _payloadSanitizer.sanitizeCommandResponse(result),
      compressionWireEvidence: DesktopCompressionLegacyEvidence.fromWire(
        result,
      ),
    );
  }

  String _validatedSubagentId(String method, String value) {
    final parsed = _subagentOpaqueId(value);
    if (parsed == null) {
      throw TuiGatewayRpcError(method, 'Invalid subagent identity');
    }
    return parsed;
  }

  String _validatedSubagentSteerText(String value) {
    if (value.isEmpty ||
        value.length > 16384 ||
        value.contains(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'))) {
      throw const TuiGatewayRpcError(
        'subagent.steer',
        'Invalid subagent steer text',
      );
    }
    return value;
  }

  @override
  Future<List<DesktopSubagentSnapshot>> listSubagents(
    String runtimeSessionId,
  ) async {
    const method = 'subagent.list';
    final result = await _request(method, {
      'session_id': _validatedRuntimeId(method, runtimeSessionId),
    });
    final rawRows = result['subagents'];
    if (rawRows is! List) {
      throw const TuiGatewayRpcError(method, 'Invalid subagent list result');
    }
    return List<DesktopSubagentSnapshot>.unmodifiable(
      rawRows
          .map(DesktopSubagentSnapshot.tryParse)
          .whereType<DesktopSubagentSnapshot>(),
    );
  }

  @override
  Future<DesktopSubagentTailResult> tailSubagent(
    String runtimeSessionId,
    String subagentId,
  ) async {
    const method = 'subagent.tail';
    final result = await _request(method, {
      'session_id': _validatedRuntimeId(method, runtimeSessionId),
      'subagent_id': _validatedSubagentId(method, subagentId),
    });
    try {
      return DesktopSubagentTailResult.fromJson(result);
    } on FormatException {
      throw const TuiGatewayRpcError(method, 'Invalid subagent tail result');
    }
  }

  @override
  Future<DesktopSubagentSteerResult> steerSubagent(
    String runtimeSessionId,
    String subagentId,
    String text,
  ) async {
    const method = 'subagent.steer';
    final requestedId = _validatedSubagentId(method, subagentId);
    final result = await _request(method, {
      'session_id': _validatedRuntimeId(method, runtimeSessionId),
      'subagent_id': requestedId,
      'text': _validatedSubagentSteerText(text),
    });
    try {
      return DesktopSubagentSteerResult.fromJson(
        result,
        requestedSubagentId: requestedId,
      );
    } on FormatException {
      throw const TuiGatewayRpcError(method, 'Invalid subagent steer result');
    }
  }

  @override
  Future<DesktopSubagentInterruptResult> interruptSubagent(
    String runtimeSessionId,
    String subagentId,
  ) async {
    const method = 'subagent.interrupt';
    final requestedId = _validatedSubagentId(method, subagentId);
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.subagentInterrupt,
      method,
      {
        'session_id': _validatedRuntimeId(method, runtimeSessionId),
        'subagent_id': requestedId,
      },
    );
    try {
      return DesktopSubagentInterruptResult.fromJson(
        result,
        requestedSubagentId: requestedId,
      );
    } on FormatException {
      _capabilityCache.mark(
        DesktopGatewayCapability.subagentInterrupt,
        DesktopGatewayCapabilityState.invalid,
      );
      throw const TuiGatewayRpcError(
        method,
        'Hermes returned an invalid subagent interrupt result',
      );
    }
  }

  String _validatedControlValue(String value, {required int maxLength}) {
    final normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.length > maxLength ||
        normalized.contains(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'))) {
      throw const DesktopControlFailure(DesktopControlFailureKind.rejected);
    }
    return normalized;
  }

  DesktopControlFailure _controlFailureFor(Object error) {
    if (error is DesktopControlFailure) return error;
    if (error is TuiGatewayRpcError) {
      return switch (error.code) {
        -32601 => const DesktopControlFailure(
          DesktopControlFailureKind.unsupported,
          code: -32601,
        ),
        4007 => const DesktopControlFailure(
          DesktopControlFailureKind.unavailable,
          code: 4007,
        ),
        4030 => const DesktopControlFailure(
          DesktopControlFailureKind.forbidden,
          code: 4030,
        ),
        final code when code == null => const DesktopControlFailure(
          DesktopControlFailureKind.unavailable,
        ),
        final code => DesktopControlFailure(
          DesktopControlFailureKind.rejected,
          code: code,
        ),
      };
    }
    return const DesktopControlFailure(DesktopControlFailureKind.unavailable);
  }

  Future<Map<String, dynamic>> _controlRequest(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 120),
    DesktopGatewayCapability? capability,
  }) async {
    if (capability != null && !_capabilityCache.canAttempt(capability)) {
      throw const DesktopControlFailure(
        DesktopControlFailureKind.unsupported,
        code: -32601,
      );
    }
    try {
      final result = await _request(method, params, timeout: timeout);
      if (capability != null) {
        _capabilityCache.mark(
          capability,
          DesktopGatewayCapabilityState.supported,
        );
      }
      return result;
    } catch (error) {
      if (capability != null &&
          error is TuiGatewayRpcError &&
          error.code == -32601) {
        _capabilityCache.mark(
          capability,
          DesktopGatewayCapabilityState.unsupported,
        );
      }
      throw _controlFailureFor(error);
    }
  }

  void _requireWritableControlConnection() {
    if (_connection.readOnly) {
      throw const DesktopControlFailure(DesktopControlFailureKind.forbidden);
    }
  }

  Never _invalidControlResponse([DesktopGatewayCapability? capability]) {
    if (capability != null) {
      _capabilityCache.mark(capability, DesktopGatewayCapabilityState.invalid);
    }
    throw const DesktopControlFailure(
      DesktopControlFailureKind.invalidResponse,
    );
  }

  @override
  Future<RecoveryTimeline> listRecovery(String runtimeSessionId) async {
    final runtime = _validatedControlValue(runtimeSessionId, maxLength: 512);
    final result = await _controlRequest('rollback.list', {
      'session_id': runtime,
    }, capability: DesktopGatewayCapability.recoveryCenter);
    try {
      if (result['enabled'] is! bool || result['checkpoints'] is! List) {
        return _invalidControlResponse(DesktopGatewayCapability.recoveryCenter);
      }
      return RecoveryTimeline.fromJson(result);
    } catch (_) {
      return _invalidControlResponse(DesktopGatewayCapability.recoveryCenter);
    }
  }

  @override
  Future<RecoveryDiff> diffRecovery(
    String runtimeSessionId,
    String checkpointHash,
  ) async {
    final result = await _controlRequest('rollback.diff', {
      'session_id': _validatedControlValue(runtimeSessionId, maxLength: 512),
      'hash': _validatedControlValue(checkpointHash, maxLength: 128),
    }, capability: DesktopGatewayCapability.recoveryCenter);
    try {
      if (result['stat'] is! String || result['diff'] is! String) {
        return _invalidControlResponse(DesktopGatewayCapability.recoveryCenter);
      }
      return RecoveryDiff.fromJson(result);
    } catch (_) {
      return _invalidControlResponse(DesktopGatewayCapability.recoveryCenter);
    }
  }

  @override
  Future<RecoveryRestoreResult> restoreRecovery(
    String runtimeSessionId,
    String checkpointHash,
  ) async {
    _requireWritableControlConnection();
    final result = await _controlRequest(
      'rollback.restore',
      {
        'session_id': _validatedControlValue(runtimeSessionId, maxLength: 512),
        'hash': _validatedControlValue(checkpointHash, maxLength: 128),
      },
      timeout: const Duration(minutes: 2),
      capability: DesktopGatewayCapability.recoveryCenter,
    );
    try {
      if (result['success'] is! bool) {
        return _invalidControlResponse(DesktopGatewayCapability.recoveryCenter);
      }
      return RecoveryRestoreResult.fromJson(result);
    } catch (_) {
      return _invalidControlResponse(DesktopGatewayCapability.recoveryCenter);
    }
  }

  @override
  Future<ExtensionsInventory> extensionsInventory({
    String runtimeSessionId = '',
  }) async {
    final runtime = runtimeSessionId.trim();
    final results = await Future.wait([
      _controlRequest('plugins.manage', const {
        'action': 'list',
      }, capability: DesktopGatewayCapability.extensionsCenter),
      _controlRequest('tools.list', {
        if (runtime.isNotEmpty)
          'session_id': _validatedControlValue(runtime, maxLength: 512),
      }, capability: DesktopGatewayCapability.extensionsCenter),
    ]);
    try {
      if (results[0]['plugins'] is! List || results[1]['toolsets'] is! List) {
        return _invalidControlResponse(
          DesktopGatewayCapability.extensionsCenter,
        );
      }
      return ExtensionsInventory.fromJson(
        plugins: results[0],
        toolsets: results[1],
      );
    } catch (_) {
      return _invalidControlResponse(DesktopGatewayCapability.extensionsCenter);
    }
  }

  @override
  Future<void> setPluginEnabled(String name, bool enabled) async {
    _requireWritableControlConnection();
    final result = await _controlRequest('plugins.manage', {
      'action': 'toggle',
      'name': _validatedControlValue(name, maxLength: 160),
      'enable': enabled,
    }, capability: DesktopGatewayCapability.extensionsCenter);
    if (result['ok'] != true) {
      _invalidControlResponse(DesktopGatewayCapability.extensionsCenter);
    }
  }

  @override
  Future<void> setToolsetEnabled(
    String name,
    bool enabled, {
    String runtimeSessionId = '',
  }) async {
    _requireWritableControlConnection();
    final target = _validatedControlValue(name, maxLength: 160);
    final runtime = runtimeSessionId.trim();
    final result = await _controlRequest(
      'tools.configure',
      {
        'action': enabled ? 'enable' : 'disable',
        'names': [target],
        if (runtime.isNotEmpty)
          'session_id': _validatedControlValue(runtime, maxLength: 512),
      },
      timeout: const Duration(minutes: 2),
      capability: DesktopGatewayCapability.extensionsCenter,
    );
    final unknown = result['unknown'];
    if (unknown is! List || unknown.map((value) => '$value').contains(target)) {
      _invalidControlResponse(DesktopGatewayCapability.extensionsCenter);
    }
  }

  @override
  Future<void> reloadMcp({
    String runtimeSessionId = '',
    required bool confirmed,
  }) async {
    _requireWritableControlConnection();
    if (!confirmed) {
      throw const DesktopControlFailure(DesktopControlFailureKind.rejected);
    }
    final runtime = runtimeSessionId.trim();
    final result = await _controlRequest(
      'reload.mcp',
      {
        'confirm': true,
        if (runtime.isNotEmpty)
          'session_id': _validatedControlValue(runtime, maxLength: 512),
      },
      timeout: const Duration(minutes: 2),
      capability: DesktopGatewayCapability.extensionsCenter,
    );
    if (result['status'] != 'reloaded') {
      _invalidControlResponse(DesktopGatewayCapability.extensionsCenter);
    }
  }

  Future<T> _dashboardExtensionRequest<T>(Future<T> Function() request) async {
    try {
      return await request();
    } catch (error) {
      if (error is DesktopControlFailure) rethrow;
      _throwDashboardExtensionFailure(error);
    }
  }

  Never _throwDashboardExtensionFailure(Object error) {
    if (error is DashboardAuthException) {
      throw const DesktopControlFailure(DesktopControlFailureKind.forbidden);
    }
    if (error is DashboardHttpException) {
      final status = error.statusCode;
      if (status == 404 || status == 405) {
        throw DesktopControlFailure(
          DesktopControlFailureKind.unsupported,
          code: status,
        );
      }
      if (status == 401 || status == 403) {
        throw DesktopControlFailure(
          DesktopControlFailureKind.forbidden,
          code: status,
        );
      }
      if (status == 400 || status == 409 || status == 412 || status == 422) {
        throw DesktopControlFailure(
          DesktopControlFailureKind.rejected,
          code: status,
        );
      }
      throw DesktopControlFailure(
        DesktopControlFailureKind.unavailable,
        code: status,
      );
    }
    if (error is FormatException ||
        error is TypeError ||
        error is StateError ||
        error is ArgumentError) {
      throw const DesktopControlFailure(
        DesktopControlFailureKind.invalidResponse,
      );
    }
    throw const DesktopControlFailure(DesktopControlFailureKind.unavailable);
  }

  List<Map<String, dynamic>> _extensionRows(Object? raw) {
    if (raw is! List) {
      throw const DesktopControlFailure(
        DesktopControlFailureKind.invalidResponse,
      );
    }
    return raw
        .take(300)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  @override
  Future<List<DesktopPluginManagementEntry>> managedPlugins() {
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiGet('dashboard/plugins/hub');
      return _extensionRows(result['plugins'])
          .map(DesktopPluginManagementEntry.tryParse)
          .whereType<DesktopPluginManagementEntry>()
          .toList(growable: false);
    });
  }

  @override
  Future<DesktopExtensionInstallResult> installPlugin(
    String identifier, {
    required bool enable,
  }) {
    _requireWritableControlConnection();
    final safeIdentifier = identifier.trim();
    if (!isSafePluginInstallIdentifier(safeIdentifier)) {
      throw const DesktopControlFailure(DesktopControlFailureKind.rejected);
    }
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiPost(
        'dashboard/agent-plugins/install',
        body: {'identifier': safeIdentifier, 'force': false, 'enable': enable},
        timeout: const Duration(minutes: 3),
      );
      final parsed = DesktopExtensionInstallResult.fromPluginJson(result);
      if (!parsed.accepted) {
        throw const DesktopControlFailure(DesktopControlFailureKind.rejected);
      }
      return parsed;
    });
  }

  @override
  Future<void> updatePlugin(String name) {
    _requireWritableControlConnection();
    final safeName = _validatedControlValue(name, maxLength: 160);
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiPost(
        'dashboard/agent-plugins/${Uri.encodeComponent(safeName)}/update',
        timeout: const Duration(minutes: 3),
      );
      if (result['ok'] != true) {
        throw const DesktopControlFailure(DesktopControlFailureKind.rejected);
      }
    });
  }

  @override
  Future<void> removePlugin(String name) {
    _requireWritableControlConnection();
    final safeName = _validatedControlValue(name, maxLength: 160);
    return _dashboardExtensionRequest(
      () => _dashboard.apiDelete(
        'dashboard/agent-plugins/${Uri.encodeComponent(safeName)}',
      ),
    );
  }

  @override
  Future<List<DesktopMcpServerEntry>> mcpServers() {
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiGet('mcp/servers');
      return _extensionRows(result['servers'])
          .map(DesktopMcpServerEntry.tryParse)
          .whereType<DesktopMcpServerEntry>()
          .toList(growable: false);
    });
  }

  @override
  Future<List<DesktopMcpCatalogEntry>> mcpCatalog() {
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiGet('mcp/catalog');
      return _extensionRows(result['entries'])
          .map(DesktopMcpCatalogEntry.tryParse)
          .whereType<DesktopMcpCatalogEntry>()
          .toList(growable: false);
    });
  }

  @override
  Future<DesktopExtensionInstallResult> installMcpCatalogEntry(
    String name, {
    Map<String, String> environment = const {},
  }) {
    _requireWritableControlConnection();
    final safeName = _validatedControlValue(name, maxLength: 160);
    if (environment.length > 40) {
      throw const DesktopControlFailure(DesktopControlFailureKind.rejected);
    }
    final safeEnvironment = <String, String>{};
    for (final entry in environment.entries) {
      final key = entry.key.trim();
      final value = entry.value;
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(key) ||
          value.length > 8192 ||
          value.contains('\u0000')) {
        throw const DesktopControlFailure(DesktopControlFailureKind.rejected);
      }
      safeEnvironment[key] = value;
    }
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiPost(
        'mcp/catalog/install',
        body: {'name': safeName, 'env': safeEnvironment, 'enable': true},
        timeout: const Duration(minutes: 2),
      );
      final parsed = DesktopExtensionInstallResult.fromMcpJson(result);
      if (!parsed.accepted) {
        throw const DesktopControlFailure(DesktopControlFailureKind.rejected);
      }
      return parsed;
    });
  }

  @override
  Future<void> setMcpServerEnabled(String name, bool enabled) {
    _requireWritableControlConnection();
    final safeName = _validatedControlValue(name, maxLength: 160);
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiPut(
        'mcp/servers/${Uri.encodeComponent(safeName)}/enabled',
        body: {'enabled': enabled},
      );
      if (result['ok'] != true) {
        throw const DesktopControlFailure(
          DesktopControlFailureKind.invalidResponse,
        );
      }
    });
  }

  @override
  Future<void> removeMcpServer(String name) {
    _requireWritableControlConnection();
    final safeName = _validatedControlValue(name, maxLength: 160);
    return _dashboardExtensionRequest(
      () =>
          _dashboard.apiDelete('mcp/servers/${Uri.encodeComponent(safeName)}'),
    );
  }

  @override
  Future<DesktopMcpProbeResult> testMcpServer(String name) {
    final safeName = _validatedControlValue(name, maxLength: 160);
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiPost(
        'mcp/servers/${Uri.encodeComponent(safeName)}/test',
        timeout: const Duration(minutes: 1),
      );
      if (result['ok'] is! bool) {
        throw const DesktopControlFailure(
          DesktopControlFailureKind.invalidResponse,
        );
      }
      return DesktopMcpProbeResult.fromJson(result);
    });
  }

  @override
  Future<DesktopMcpServerEntry> addMcpServer(McpServerDraft draft) {
    _requireWritableControlConnection();
    if (draft.url case final uri?) {
      try {
        TransportPrivacy.requireAllowed(uri.toString());
      } on ArgumentError {
        throw const DesktopControlFailure(DesktopControlFailureKind.rejected);
      }
    }
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiPost(
        'mcp/servers',
        body: draft.toRequestJson(),
        timeout: const Duration(minutes: 1),
      );
      final parsed = DesktopMcpServerEntry.tryParse(result);
      if (parsed == null) {
        throw const DesktopControlFailure(
          DesktopControlFailureKind.invalidResponse,
        );
      }
      return parsed;
    });
  }

  @override
  Future<McpOAuthFlow> startMcpOAuth(String name) {
    _requireWritableControlConnection();
    final safeName = _validatedControlValue(name, maxLength: 160);
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiPost(
        'mcp/servers/${Uri.encodeComponent(safeName)}/auth',
        timeout: const Duration(seconds: 45),
      );
      return McpOAuthFlow.fromJson(result);
    });
  }

  @override
  Future<McpOAuthFlow> mcpOAuthFlow(String flowId) {
    final safeFlow = _validatedControlValue(flowId, maxLength: 256);
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiGet(
        'mcp/oauth/flows/${Uri.encodeComponent(safeFlow)}',
      );
      return McpOAuthFlow.fromJson(result);
    });
  }

  @override
  Future<WebhookSnapshot> webhookSnapshot() {
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiGet('webhooks');
      return WebhookSnapshot.fromJson(result);
    });
  }

  @override
  Future<WebhookEnableResult> enableWebhooks() {
    _requireWritableControlConnection();
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiPost(
        'webhooks/enable',
        timeout: const Duration(minutes: 1),
      );
      final parsed = WebhookEnableResult.fromJson(result);
      if (!parsed.ok) {
        throw const DesktopControlFailure(DesktopControlFailureKind.rejected);
      }
      return parsed;
    });
  }

  @override
  Future<WebhookCreateReceipt> createWebhook(WebhookDraft draft) {
    _requireWritableControlConnection();
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiPost(
        'webhooks',
        body: draft.toRequestJson(),
      );
      return WebhookCreateReceipt.fromJson(result);
    });
  }

  @override
  Future<void> setWebhookEnabled(String name, bool enabled) {
    _requireWritableControlConnection();
    final safeName = _validatedWebhookName(name);
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiPut(
        'webhooks/${Uri.encodeComponent(safeName)}/enabled',
        body: {'enabled': enabled},
      );
      if (result['ok'] != true) {
        throw const DesktopControlFailure(
          DesktopControlFailureKind.invalidResponse,
        );
      }
    });
  }

  @override
  Future<void> removeWebhook(String name) {
    _requireWritableControlConnection();
    final safeName = _validatedWebhookName(name);
    return _dashboardExtensionRequest(
      () => _dashboard.apiDelete('webhooks/${Uri.encodeComponent(safeName)}'),
    );
  }

  @override
  Future<A2aServerCapability?> a2aServerCapability() {
    return _dashboardExtensionRequest(() async {
      final result = await _dashboard.apiGet('messaging/platforms');
      return A2aServerCapability.tryFromPlatformsJson(result);
    });
  }

  String _validatedWebhookName(String raw) {
    final value = _validatedControlValue(raw, maxLength: 160).toLowerCase();
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(value)) {
      throw const DesktopControlFailure(DesktopControlFailureKind.rejected);
    }
    return value;
  }

  @override
  Future<AgentCenterSnapshot> agentCenterSnapshot({
    String runtimeSessionId = '',
  }) async {
    final runtime = runtimeSessionId.trim();
    final safeRuntime = runtime.isEmpty
        ? ''
        : _validatedControlValue(runtime, maxLength: 512);
    final snapshotsFuture = _controlRequest('spawn_tree.list', {
      if (safeRuntime.isNotEmpty) 'session_id': safeRuntime,
      'cross_session': safeRuntime.isEmpty,
      'limit': 50,
    }, capability: DesktopGatewayCapability.agentCenter);
    final processesFuture = safeRuntime.isEmpty
        ? Future<Map<String, dynamic>>.value(const {'processes': <Object>[]})
        : _controlRequest('process.list', {
            'session_id': safeRuntime,
          }, capability: DesktopGatewayCapability.agentCenter);
    final results = await Future.wait([snapshotsFuture, processesFuture]);
    try {
      if (results[0]['entries'] is! List || results[1]['processes'] is! List) {
        return _invalidControlResponse(DesktopGatewayCapability.agentCenter);
      }
      return AgentCenterSnapshot.fromJson(
        snapshots: results[0],
        processes: results[1],
      );
    } catch (_) {
      return _invalidControlResponse(DesktopGatewayCapability.agentCenter);
    }
  }

  @override
  Future<SpawnTreeDetail> loadSpawnTree(String opaquePath) async {
    final result = await _controlRequest('spawn_tree.load', {
      'path': _validatedControlValue(opaquePath, maxLength: 2048),
    }, capability: DesktopGatewayCapability.agentCenter);
    try {
      if (result['subagents'] is! List) {
        return _invalidControlResponse(DesktopGatewayCapability.agentCenter);
      }
      return SpawnTreeDetail.fromJson(result);
    } catch (_) {
      return _invalidControlResponse(DesktopGatewayCapability.agentCenter);
    }
  }

  @override
  Future<String> startBackgroundTask(
    String runtimeSessionId,
    String text,
  ) async {
    _requireWritableControlConnection();
    final task = _validatedControlValue(text, maxLength: 2000);
    final result = await _controlRequest(
      'prompt.background',
      {
        'session_id': _validatedControlValue(runtimeSessionId, maxLength: 512),
        'text': task,
      },
      timeout: const Duration(minutes: 2),
      capability: DesktopGatewayCapability.agentCenter,
    );
    final taskId = result['task_id'];
    if (taskId is! String || taskId.trim().isEmpty || taskId.length > 512) {
      return _invalidControlResponse(DesktopGatewayCapability.agentCenter);
    }
    return taskId;
  }

  @override
  Future<void> killBackgroundProcess(
    String runtimeSessionId,
    String processId,
  ) async {
    _requireWritableControlConnection();
    await _controlRequest('process.kill', {
      'session_id': _validatedControlValue(runtimeSessionId, maxLength: 512),
      'process_id': _validatedControlValue(processId, maxLength: 512),
    }, capability: DesktopGatewayCapability.agentCenter);
  }

  @override
  Future<void> stopBackgroundProcesses(String runtimeSessionId) async {
    _requireWritableControlConnection();
    await _controlRequest('process.stop', {
      'session_id': _validatedControlValue(runtimeSessionId, maxLength: 512),
    });
  }

  @override
  Future<ProjectTreeSnapshot> projectTree() async {
    final result = await _controlRequest('projects.tree', const {
      'preview_limit': 3,
    }, capability: DesktopGatewayCapability.projectsCenter);
    try {
      if (result['projects'] is! List) {
        return _invalidControlResponse(DesktopGatewayCapability.projectsCenter);
      }
      return ProjectTreeSnapshot.fromJson(result);
    } catch (_) {
      return _invalidControlResponse(DesktopGatewayCapability.projectsCenter);
    }
  }

  @override
  Future<ProjectNode?> projectSessions(String projectId) async {
    final result = await _controlRequest('projects.project_sessions', {
      'project_id': _validatedControlValue(projectId, maxLength: 2048),
    }, capability: DesktopGatewayCapability.projectsCenter);
    final rawProject = result['project'];
    if (rawProject == null) return null;
    if (rawProject is! Map) {
      return _invalidControlResponse(DesktopGatewayCapability.projectsCenter);
    }
    try {
      return ProjectNode.tryParse(Map<String, dynamic>.from(rawProject)) ??
          _invalidControlResponse(DesktopGatewayCapability.projectsCenter);
    } catch (_) {
      return _invalidControlResponse(DesktopGatewayCapability.projectsCenter);
    }
  }

  @override
  Future<void> setSessionWorkingDirectory(
    String runtimeSessionId,
    String path,
  ) async {
    _requireWritableControlConnection();
    final result = await _controlRequest('session.cwd.set', {
      'session_id': _validatedControlValue(runtimeSessionId, maxLength: 512),
      'cwd': _validatedControlValue(path, maxLength: 4096),
    }, capability: DesktopGatewayCapability.projectsCenter);
    if (result['cwd'] is! String) {
      _invalidControlResponse(DesktopGatewayCapability.projectsCenter);
    }
  }

  static const Set<String> _validSessionControlActions = {
    'goal.pause',
    'goal.resume',
    'goal.clear',
    'goal.unwait',
    'loop.pause',
    'loop.resume',
    'loop.stop',
    'heartbeat.pause',
    'heartbeat.resume',
    'heartbeat.clear',
  };

  @override
  Future<SessionControlSnapshot> readSessionControl(
    String runtimeSessionId,
  ) async {
    final result = await _controlRequest('session.control.read', {
      'session_id': _validatedControlValue(runtimeSessionId, maxLength: 512),
    }, capability: DesktopGatewayCapability.sessionControl);
    return SessionControlSnapshot.fromJson(result['control']);
  }

  @override
  Future<SessionGoalSnapshot?> readSessionGoal(String runtimeSessionId) async =>
      (await readSessionControl(runtimeSessionId)).goal;

  @override
  Future<void> sendSessionControlAction(
    String runtimeSessionId,
    String action,
  ) async {
    if (!_validSessionControlActions.contains(action)) {
      throw ArgumentError.value(
        action,
        'action',
        'not a supported session control action',
      );
    }
    _requireWritableControlConnection();
    await _controlRequest('session.control', {
      'session_id': _validatedControlValue(runtimeSessionId, maxLength: 512),
      'action': action,
    }, capability: DesktopGatewayCapability.sessionControl);
  }

  @override
  Future<void> sendGoalAction(String runtimeSessionId, String action) async {
    if (!action.startsWith('goal.')) {
      throw ArgumentError.value(
        action,
        'action',
        'not a supported goal action',
      );
    }
    await sendSessionControlAction(runtimeSessionId, action);
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    await _requestPromptSubmit({'session_id': runtimeSessionId, 'text': text});
    _markWatchdogRuntimeBusy(runtimeSessionId);
  }

  @override
  Future<void> submitQueuedPrompt(String runtimeSessionId, String text) async {
    await _requestPromptSubmit({
      'session_id': runtimeSessionId,
      'text': text,
      'queued': true,
    });
    _markWatchdogRuntimeBusy(runtimeSessionId);
  }

  @override
  Future<void> submitInterruptedPrompt(
    String runtimeSessionId,
    String text,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (true) {
      try {
        await _requestPromptSubmit({
          'session_id': runtimeSessionId,
          'text': text,
          'interrupted': true,
        });
        _markWatchdogRuntimeBusy(runtimeSessionId);
        return;
      } on TuiGatewayRpcError catch (error) {
        // Mismo settle de Hermes Desktop: un Gateway antiguo puede seguir
        // desmontando el turno interrumpido aunque ya haya confirmado Stop.
        if (error.code != 4009 || !DateTime.now().isBefore(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    final result = await _requestPromptSubmit({
      'session_id': runtimeSessionId,
      'text': text,
      'client_turn_id': clientTurnId,
    });
    final ack = DesktopTurnAck.fromJson(
      result,
      expectedClientTurnId: clientTurnId,
    );
    _markWatchdogRuntimeBusy(runtimeSessionId);
    return ack;
  }

  @override
  Future<DesktopTurnAck> submitQueuedPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    final result = await _requestPromptSubmit({
      'session_id': runtimeSessionId,
      'text': text,
      'client_turn_id': clientTurnId,
      'queued': true,
    });
    final ack = DesktopTurnAck.fromJson(
      result,
      expectedClientTurnId: clientTurnId,
    );
    _markWatchdogRuntimeBusy(runtimeSessionId);
    return ack;
  }

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String sessionId,
    String clientTurnId,
  ) async {
    final result = await _request('turn.status', {
      'session_id': sessionId,
      'client_turn_id': clientTurnId,
    });
    return DesktopTurnStatus.fromJson(
      result,
      expectedClientTurnId: clientTurnId,
    );
  }

  @override
  Future<int?> resolveDurableUserRowId(
    String runtimeSessionId, {
    required String sourceText,
    required int expectedOrdinal,
  }) async {
    try {
      final page = await sessionHistory(sessionId: runtimeSessionId);
      final durableUsers = page.messages
          .where((message) {
            final displayKind =
                message['display_kind']?.toString().trim() ?? '';
            final rowId = message['row_id'];
            return message['role'] == 'user' &&
                displayKind.isEmpty &&
                rowId is int &&
                rowId > 0;
          })
          .toList(growable: false);
      final wanted = sourceText.trim();
      if (wanted.isEmpty) return null;
      final matches = durableUsers
          .where((message) {
            final durableText = (message['text'] ?? message['content'] ?? '')
                .toString()
                .trim();
            return durableText == wanted;
          })
          .toList(growable: false);
      if (matches.length == 1) return matches.single['row_id'] as int;
      if (matches.length > 1 &&
          expectedOrdinal >= durableUsers.length - 1 &&
          identical(matches.last, durableUsers.last)) {
        return matches.last['row_id'] as int;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> submitRewindPrompt(
    String runtimeSessionId,
    String text,
    int truncateBeforeUserOrdinal,
  ) async {
    await _requestPromptSubmit({
      'session_id': runtimeSessionId,
      'text': text,
      'truncate_before_user_ordinal': truncateBeforeUserOrdinal,
      'confirm_truncate': true,
      if (truncateBeforeUserOrdinal == 0) 'confirm_empty_truncate': true,
    });
    _markWatchdogRuntimeBusy(runtimeSessionId);
  }

  @override
  Future<DesktopRewindAck> submitDurableRewindPrompt(
    String runtimeSessionId,
    String text,
    int truncateBeforeUserOrdinal, {
    required int truncateBeforeRowId,
    List<int> rebindSurvivorRowIds = const [],
  }) async {
    final rebind = <int>{...rebindSurvivorRowIds};
    final result = await _requestPromptSubmit({
      'session_id': runtimeSessionId,
      'text': text,
      'truncate_before_row_id': truncateBeforeRowId,
      'confirm_truncate': true,
      // Direccionando por row id el ordinal tail-local se descartó, así que no
      // puede decidir esto: el objetivo durable es el autoritativo y un corte
      // a la primera fila del active tip debe permitirse explícitamente. El
      // gateway lo ignora cuando el prefijo no queda vacío
      // (`rewind.ts:348-350`).
      'confirm_empty_truncate': true,
      if (rebind.isNotEmpty)
        'rebind_survivor_row_ids': rebind.toList(growable: false),
    });
    final ack = DesktopRewindAck.fromJson(result);
    _markWatchdogRuntimeBusy(runtimeSessionId);
    return ack;
  }

  @override
  Future<DesktopAttachmentResult> attachImageBytes(
    String runtimeSessionId, {
    required String filename,
    required String contentBase64,
  }) async {
    final result =
        await _requestExclusiveSessionMutation('image.attach_bytes', {
          'session_id': runtimeSessionId,
          'filename': filename,
          'content_base64': contentBase64,
        });
    if (result['attached'] != true) {
      throw const TuiGatewayRpcError(
        'image.attach_bytes',
        'Hermes did not attach the image',
      );
    }
    return DesktopAttachmentResult(path: result['path']?.toString());
  }

  @override
  Future<DesktopAttachmentResult> attachFileBytes(
    String runtimeSessionId, {
    required String filename,
    required String mimeType,
    required String contentBase64,
  }) async {
    final result = await _requestExclusiveSessionMutation('file.attach', {
      'session_id': runtimeSessionId,
      'path': filename,
      'name': filename,
      'data_url': 'data:$mimeType;base64,$contentBase64',
    });
    if (result['attached'] != true || result['ref_text'] == null) {
      throw const TuiGatewayRpcError(
        'file.attach',
        'Hermes did not attach the file',
      );
    }
    return DesktopAttachmentResult(
      path: result['path']?.toString(),
      refText: result['ref_text']?.toString(),
    );
  }

  @override
  Future<void> detachImage(String runtimeSessionId, String path) async {
    await _requestExclusiveSessionMutation('image.detach', {
      'session_id': runtimeSessionId,
      'path': path,
    }, timeout: const Duration(seconds: 10));
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    final result = await _requestExclusiveSessionMutation('session.steer', {
      'session_id': runtimeSessionId,
      'text': text,
    }, timeout: const Duration(seconds: 10));
    if (result['status'] != 'queued') {
      throw const TuiGatewayRpcError(
        'session.steer',
        'Hermes rejected the steering instruction',
      );
    }
  }

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    const method = 'session.redirect';
    final result = await _requestExclusiveSessionMutation(method, {
      'session_id': runtimeSessionId,
      'text': text,
    }, timeout: const Duration(seconds: 10));
    return switch (result['status']) {
      'redirected' => DesktopRedirectDisposition.redirected,
      'queued' => DesktopRedirectDisposition.queued,
      _ => DesktopRedirectDisposition.rejected,
    };
  }

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    await _request('session.interrupt', {
      'session_id': runtimeSessionId,
    }, timeout: const Duration(seconds: 10));
  }

  @override
  Future<DesktopCompressionResult> compressSession(
    String runtimeSessionId, {
    String focusTopic = '',
  }) async {
    const method = 'session.compress';
    if (runtimeSessionId != runtimeSessionId.trim()) {
      throw const TuiGatewayRpcError(
        method,
        'Invalid runtime session identity',
      );
    }
    final runtime = _validatedRuntimeId(method, runtimeSessionId);
    final focus = focusTopic.trim();
    final result = await _requestExclusiveSessionMutation(method, {
      'session_id': runtime,
      if (focus.isNotEmpty) 'focus_topic': focus,
    }, timeout: sessionCompressRpcTimeout);
    try {
      return DesktopCompressionResult.fromJson(result);
    } on FormatException {
      throw const TuiGatewayRpcError(
        method,
        'Hermes returned an invalid session compression result',
        origin: CompressionFailureOrigin.malformed,
      );
    }
  }

  @override
  Future<Map<String, dynamic>> compressionEventReplay(String runtimeSessionId) {
    const method = 'session.events.since';
    final runtime = _validatedRuntimeId(method, runtimeSessionId);
    return _requestConnected(method, <String, dynamic>{
      'session_id': runtime,
      'last_seen': 0,
    }, timeout: const Duration(seconds: 10));
  }

  String _validatedRuntimeId(String method, String runtimeSessionId) {
    final value = runtimeSessionId.trim();
    if (value.isEmpty) {
      throw TuiGatewayRpcError(method, 'Missing runtime session identity');
    }
    return value;
  }

  String _validatedSlashCommand(String method, String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.length > 4096) {
      throw TuiGatewayRpcError(method, 'Invalid slash command');
    }
    final firstSpace = trimmed.indexOf(RegExp(r'\s'));
    final rawName = firstSpace < 0 ? trimmed : trimmed.substring(0, firstSpace);
    final name = CommandDescriptor.tryNormalizeName(rawName);
    if (name == null) {
      throw TuiGatewayRpcError(method, 'Invalid slash command');
    }
    final arguments = firstSpace < 0
        ? ''
        : trimmed.substring(firstSpace).trim();
    if (arguments.contains(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'))) {
      throw TuiGatewayRpcError(method, 'Invalid slash command');
    }
    return arguments.isEmpty ? name : '$name $arguments';
  }

  Future<DesktopConfigSetResult> _setSessionConfig({
    required String runtimeSessionId,
    required DesktopSessionConfigKey key,
    required String value,
    bool confirmExpensiveModel = false,
  }) async {
    const method = 'config.set';
    final result = await _request(method, {
      'session_id': _validatedRuntimeId(method, runtimeSessionId),
      'key': key.wire,
      'value': value,
      if (key == DesktopSessionConfigKey.model)
        'confirm_expensive_model': confirmExpensiveModel,
    });
    try {
      return DesktopConfigSetResult.fromJson(result, expectedKey: key);
    } on FormatException {
      throw const TuiGatewayRpcError(
        method,
        'Hermes returned an invalid session config response',
      );
    }
  }

  @override
  Future<DesktopConfigSetResult> setSessionModel(
    String runtimeSessionId,
    DesktopModelSelection selection, {
    bool confirmExpensiveModel = false,
  }) => _setSessionConfig(
    runtimeSessionId: runtimeSessionId,
    key: DesktopSessionConfigKey.model,
    value: selection.sessionWireValue,
    confirmExpensiveModel: confirmExpensiveModel,
  );

  @override
  Future<DesktopConfigSetResult> setSessionReasoning(
    String runtimeSessionId,
    DesktopReasoningEffort effort,
  ) => _setSessionConfig(
    runtimeSessionId: runtimeSessionId,
    key: DesktopSessionConfigKey.reasoning,
    value: effort.wire,
  );

  @override
  Future<DesktopConfigSetResult> setSessionFastMode(
    String runtimeSessionId,
    DesktopFastMode mode,
  ) => _setSessionConfig(
    runtimeSessionId: runtimeSessionId,
    key: DesktopSessionConfigKey.fast,
    value: mode.wire,
  );

  String _interactiveRequestId(String method, String requestId) {
    if (requestId.trim().isEmpty) {
      throw TuiGatewayRpcError(method, 'Missing interactive request identity');
    }
    return requestId;
  }

  @override
  Future<DesktopPromptResponse> respondToClarify(
    String requestId,
    String answer, {
    String? questionId,
  }) async {
    const method = 'clarify.respond';
    if (_openServerRequests.containsKey(requestId)) {
      if (questionId != null) {
        // Batch clarify: answers lock one at a time; the last lock resolves the
        // server request itself.
        const lockMethod = 'clarify.lock';
        final result = await _request(lockMethod, {
          'request_id': _interactiveRequestId(lockMethod, requestId),
          'question_id': questionId,
          'answer': answer,
        });
        final remaining = result['remaining'];
        if (result['status'] == 'expired' ||
            (remaining is List && remaining.isEmpty)) {
          _openServerRequests.remove(requestId);
        }
        return DesktopPromptResponse.fromJson(
          result,
          method: lockMethod,
          allowExpired: true,
        );
      }
      if (!_respondServerRequest(requestId, {'answer': answer})) {
        // The socket that owns the request is gone; the backend re-delivers it
        // as `open_requests` on resume, so the card must stay answerable.
        throw const TuiGatewayRpcError(
          'clarify',
          'Hermes Desktop WebSocket was replaced',
        );
      }
      return const DesktopPromptResponse._(DesktopPromptResponseStatus.ok);
    }
    final params = <String, Object?>{
      'request_id': _interactiveRequestId(method, requestId),
      'answer': answer,
    };
    if (questionId != null) params['question_id'] = questionId;
    final result = await _request(method, params);
    return DesktopPromptResponse.fromJson(
      result,
      method: method,
      allowExpired: true,
    );
  }

  @override
  Future<DesktopPromptResponse> respondToSudo(
    String requestId,
    EphemeralSensitiveValue password,
  ) => _respondWithSensitiveValue(
    method: 'sudo.respond',
    requestId: requestId,
    valueKey: 'password',
    value: password,
  );

  @override
  Future<DesktopPromptResponse> respondToSecret(
    String requestId,
    EphemeralSensitiveValue value,
  ) => _respondWithSensitiveValue(
    method: 'secret.respond',
    requestId: requestId,
    valueKey: 'value',
    value: value,
  );

  Future<DesktopPromptResponse> _respondWithSensitiveValue({
    required String method,
    required String requestId,
    required String valueKey,
    required EphemeralSensitiveValue value,
  }) async {
    try {
      late final Future<Map<String, dynamic>> pendingResponse;
      try {
        final opaqueRequestId = _interactiveRequestId(method, requestId);
        await connect();
        pendingResponse = _sendSensitiveResponseConnected(
          method: method,
          requestId: opaqueRequestId,
          valueKey: valueKey,
          value: value,
        );
      } finally {
        // The sole disposal owner runs for validation/connect/sink failures and
        // before awaiting a remote response.
        value.dispose();
      }
      final result = await pendingResponse;
      return DesktopPromptResponse.fromJson(
        result,
        method: method,
        allowExpired: true,
      );
    } catch (error) {
      if (SanitizedRpcFailureFactory.isCertified(error)) {
        rethrow;
      }
      // Recreate the failure locally. Raw transport/auth/ready/socket stacks are
      // never attached to a sensitive completer or returned to its caller.
      throw SanitizedRpcFailureFactory.transport(method);
    }
  }

  Future<Map<String, dynamic>> _sendSensitiveResponseConnected({
    required String method,
    required String requestId,
    required String valueKey,
    required EphemeralSensitiveValue value,
  }) {
    final ephemeralValue = value.take();
    if (_openServerRequests.containsKey(requestId)) {
      // v7 server requests answer every one-string prompt under `value`.
      if (!_respondServerRequest(requestId, {'value': ephemeralValue})) {
        return Future<Map<String, dynamic>>.error(
          TuiGatewayRpcError(method, 'Hermes Desktop WebSocket was replaced'),
        );
      }
      return Future<Map<String, dynamic>>.value({'status': 'ok'});
    }
    return _requestConnected(method, {
      'request_id': requestId,
      valueKey: ephemeralValue,
    }, redactRemoteError: true);
  }

  @override
  Future<DesktopPromptResponse> respondToTerminalRead(String requestId) async {
    const method = 'terminal.read.respond';
    if (_openServerRequests.containsKey(requestId)) {
      if (!_respondServerRequest(requestId, {
        'value': TerminalReadResponsePolicy.noOwnedTerminalText,
      })) {
        throw const TuiGatewayRpcError(
          'terminal.read',
          'Hermes Desktop WebSocket was replaced',
        );
      }
      return const DesktopPromptResponse._(DesktopPromptResponseStatus.ok);
    }
    final result = await _request(method, {
      'request_id': _interactiveRequestId(method, requestId),
      'text': TerminalReadResponsePolicy.noOwnedTerminalText,
    });
    return DesktopPromptResponse.fromJson(result, method: method);
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {
    if (requestId != null && requestId.isNotEmpty) {
      final serverRequestId = _approvalServerRequestIds[requestId];
      if (serverRequestId != null &&
          _respondServerRequest(serverRequestId, {
            'choice': choice,
            if (resolveAll) 'all': true,
          })) {
        _approvalServerRequestIds.remove(requestId);
        return;
      }
    } else if (resolveAll) {
      for (final open in _openServerRequests.values) {
        if (open.method != 'approval' || open.sessionId != runtimeSessionId) {
          continue;
        }
        if (_respondServerRequest(open.id, {'choice': choice, 'all': true})) {
          _approvalServerRequestIds.removeWhere((_, id) => id == open.id);
          return;
        }
        break;
      }
    }
    if (resolveAll || requestId == null) {
      await _request('approval.respond', {
        'session_id': _validatedRuntimeId('approval.respond', runtimeSessionId),
        'choice': choice,
        if (resolveAll) 'all': true,
        if (requestId != null && requestId.isNotEmpty) 'request_id': requestId,
      });
      return;
    }
    await resolveApprovalChecked(
      runtimeSessionId,
      choice,
      requestId: requestId,
    );
  }

  @override
  Future<DesktopApprovalResult> resolveApprovalChecked(
    String runtimeSessionId,
    String choice, {
    required String requestId,
  }) async {
    const method = 'approval.respond';
    final request = _subagentOpaqueId(requestId);
    if (request == null ||
        !const {'once', 'session', 'always', 'deny'}.contains(choice)) {
      throw const TuiGatewayRpcError(method, 'Invalid approval response');
    }
    final serverRequestId = _approvalServerRequestIds[request];
    if (serverRequestId != null &&
        _respondServerRequest(serverRequestId, {'choice': choice})) {
      // The response frame is the first-wins answer by construction: it can
      // only settle the request it was minted for.
      _approvalServerRequestIds.remove(request);
      return const DesktopApprovalResult(resolved: 1);
    }
    final result = await _request(method, {
      'session_id': _validatedRuntimeId(method, runtimeSessionId),
      'choice': choice,
      'request_id': request,
    });
    try {
      return DesktopApprovalResult.fromJson(result);
    } on FormatException {
      throw const TuiGatewayRpcError(method, 'Invalid approval response');
    }
  }

  @override
  Future<void> disconnectIdle() async {
    if (_closed) return;
    await _disconnectTransport('client_background_idle');
  }

  Future<void> _disconnectTransport(String reason) async {
    _socketGeneration++;
    _connected = false;
    _stopHeartbeat();
    _retireWatchdogRuntime();
    _resetLegacyEventRuntimeAnchor();
    _capabilityCache.resetForReconnect();
    _failPending(StateError('Hermes Desktop gateway closed'));
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    await _teardownTransport(
      channel,
      subscription,
      closeCode: ws_status.normalClosure,
      closeReason: reason,
    );
  }

  Future<void> _teardownTransport(
    WebSocketChannel? channel,
    StreamSubscription<dynamic>? subscription, {
    int? closeCode,
    String? closeReason,
  }) async {
    if (channel == null && subscription == null) return;

    Future<void> bestEffort(Future<dynamic> Function() operation) async {
      try {
        await operation();
      } catch (_) {
        // El error que importa pertenece al transporte/RPC original. La
        // limpieza nunca lo reemplaza ni deja una Future sin gestionar.
      }
    }

    final pending = <Future<void>>[];
    // Invocar `close` antes de `cancel` conserva el close frame deliberado que
    // evita cierres 1006 en Android. Las Futures se esperan en paralelo para
    // que ambas compartan el mismo presupuesto total.
    if (channel != null) {
      pending.add(bestEffort(() => channel.sink.close(closeCode, closeReason)));
    }
    if (subscription != null) {
      pending.add(bestEffort(subscription.cancel));
    }
    try {
      await Future.wait(pending).timeout(_transportTeardownBudget);
    } catch (_) {
      // Un sink todavía no enlazado o un onCancel remoto pueden no completar.
      // Las referencias propietarias ya se retiraron antes de entrar aquí.
    }
  }

  void _rememberLegacyEventRuntime(String runtimeSessionId) {
    // Un Gateway antiguo puede omitir `session_id` en eventos foreground. El
    // socket de chat es reutilizable, así que solo inferimos mientras una única
    // identidad runtime haya sido ligada durante esta generación de conexión.
    if (!_connected || _legacyEventRuntimeAmbiguous) return;
    final runtime = runtimeSessionId.trim();
    if (runtime.isEmpty) return;
    final current = _legacyEventRuntimeId;
    if (current == null) {
      _legacyEventRuntimeId = runtime;
    } else if (current != runtime) {
      _legacyEventRuntimeId = null;
      _legacyEventRuntimeAmbiguous = true;
    }
  }

  void _resetLegacyEventRuntimeAnchor() {
    _legacyEventRuntimeId = null;
    _legacyEventRuntimeAmbiguous = false;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _disconnectTransport('client_dispose');
    if (!_events.isClosed) await _events.close();
  }
}

final class _OpenServerRequest {
  final String id;
  final String method;
  final String sessionId;
  final int generation;
  final WebSocketChannel channel;

  const _OpenServerRequest({
    required this.id,
    required this.method,
    required this.sessionId,
    required this.generation,
    required this.channel,
  });
}

class _PendingRpc {
  final String method;
  final Completer<Map<String, dynamic>> completer;
  final Timer timer;
  final bool redactRemoteError;

  const _PendingRpc(
    this.method,
    this.completer,
    this.timer, {
    this.redactRemoteError = false,
  });
}
