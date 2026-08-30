// Cliente del protocolo oficial usado por Hermes Desktop y el Dashboard.
//
// Transporte: WebSocket `/api/ws` + JSON-RPC 2.0. A diferencia de `/v1/runs`,
// este canal conserva una referencia al AIAgent vivo y expone
// `session.redirect` (con `session.steer` solo para compatibilidad antigua).
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

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
import '../models/desktop_control_center.dart';
import '../models/desktop_context_breakdown.dart';
import '../models/desktop_model_catalog.dart';
import '../models/desktop_session_config.dart';
import '../models/desktop_session_snapshot.dart';
import '../models/interactive_prompt.dart';
import '../models/profile_pet.dart';
import 'capability_payload_sanitizer.dart';
import 'connection_manager.dart';
import 'desktop_control_gateway.dart';
import 'desktop_gateway_capabilities.dart';
import '../utils/transport_privacy.dart';

class TuiGatewayRpcError implements Exception {
  final String method;
  final int? code;
  final String message;

  const TuiGatewayRpcError(this.method, this.message, {this.code});

  @override
  String toString() => 'TuiGatewayRpcError($method, $code): $message';
}

class TuiGatewayEvent {
  final String type;
  final String sessionId;
  final Map<String, dynamic> payload;

  const TuiGatewayEvent({
    required this.type,
    required this.sessionId,
    required this.payload,
  });
}

/// Alias compatible con los consumidores legacy. Los gateways reales devuelven
/// ahora también el snapshot tipado completo de Hermes Agent 0.19.
class DesktopSessionBinding extends DesktopSessionSnapshot {
  const DesktopSessionBinding({
    required super.runtimeSessionId,
    required super.storedSessionId,
    required super.created,
    super.messages,
    super.messagesProvided,
    super.messageCount,
    super.hydrating,
    super.inflight,
    super.queued,
    super.running,
    super.status,
    super.startedAt,
    super.info,
    super.raw,
    super.pendingClarify,
    super.pendingClarifyOutcome,
    super.pendingClarifyProvided,
  });

  factory DesktopSessionBinding.fromSnapshot(DesktopSessionSnapshot snapshot) {
    return DesktopSessionBinding(
      runtimeSessionId: snapshot.runtimeSessionId,
      storedSessionId: snapshot.storedSessionId,
      created: snapshot.created,
      messages: snapshot.messages,
      messagesProvided: snapshot.messagesProvided,
      messageCount: snapshot.messageCount,
      hydrating: snapshot.hydrating,
      inflight: snapshot.inflight,
      queued: snapshot.queued,
      running: snapshot.running,
      status: snapshot.status,
      startedAt: snapshot.startedAt,
      info: snapshot.info,
      raw: snapshot.raw,
      pendingClarify: snapshot.pendingClarify,
      pendingClarifyOutcome: snapshot.pendingClarifyOutcome,
      pendingClarifyProvided: snapshot.pendingClarifyProvided,
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
  });

  Future<void> close();
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

enum DesktopRedirectDisposition { redirected, queued }

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
    // Hermes Agent 0.20: ack inmediato con `hydrating:true` y el historial se
    // carga en segundo plano (`session.resume_progress`). Gateways antiguos
    // ignoran el parámetro y responden como siempre (sin `hydrating`).
    bool deferHistory = false,
  });

  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  });
}

/// Recovery-only resume whose runtime anchor is committed by the caller only
/// after its turn generation is still current.
abstract class HermesDesktopRecoverySessionLifecycleGateway {
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  });

  void commitRecoveryRuntime(String runtimeSessionId);
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
    if (found is! bool ||
        returnedId is! String ||
        returnedId.trim() != requestedSubagentId) {
      throw const FormatException('invalid subagent interrupt result');
    }
    return DesktopSubagentInterruptResult(
      found: found,
      subagentId: requestedSubagentId,
    );
  }
}

/// Control opcional y autenticado de un hijo nativo de Hermes 0.19.
///
/// No incluye la pausa global de delegación: esa mutación requiere una
/// superficie administrativa separada y nunca se ejecuta desde el chat.
abstract class HermesDesktopSubagentGateway {
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  );

  Future<DesktopSubagentInterruptResult> interruptSubagent(String subagentId);
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

class DesktopRewindAck {
  final List<int?>? survivorUserRowIds;

  const DesktopRewindAck({this.survivorUserRowIds});

  factory DesktopRewindAck.fromJson(Map<String, dynamic> json) {
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
  Future<DesktopRewindAck> submitDurableRewindPrompt(
    String runtimeSessionId,
    String text,
    int truncateBeforeUserOrdinal, {
    required int truncateBeforeRowId,
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

class TuiGatewayClient
    implements
        HermesDesktopGateway,
        HermesDesktopRedirectGateway,
        HermesDesktopInterruptedPromptGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRecoverySessionLifecycleGateway,
        HermesDesktopConfiguredSessionLifecycleGateway,
        HermesDesktopLifecycleGateway,
        HermesDesktopIdempotentGateway,
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
        HermesDesktopSubagentGateway,
        HermesDesktopControlGateway,
        HermesExtensionManagementGateway,
        HermesMcpProvisioningGateway,
        HermesWebhookManagementGateway,
        HermesServerPlatformCapabilitiesGateway {
  static const _transportTeardownBudget = Duration(seconds: 1);

  final SavedConnection _connection;
  final DashboardClient _dashboard;
  final WebSocketChannel Function(Uri uri, Map<String, dynamic> headers)?
  _channelFactory;
  final DesktopGatewayCapabilityCache _capabilityCache;
  final Duration _heartbeatInterval;
  final Duration _heartbeatDeadline;
  static const CapabilityPayloadSanitizer _payloadSanitizer =
      CapabilityPayloadSanitizer();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final Map<int, _PendingRpc> _pending = {};
  int _nextId = 1;
  bool _connected = false;
  bool _closed = false;
  int _socketGeneration = 0;
  int _heartbeatSequence = 0;
  DateTime _lastInboundAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _heartbeatTimer;
  Future<void>? _connecting;
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
  }) : _dashboard = dashboard ?? DashboardClient.lazy(_connection),
       _channelFactory = channelFactory,
       _capabilityCache = capabilityCache ?? DesktopGatewayCapabilityCache(),
       _heartbeatInterval = heartbeatInterval,
       _heartbeatDeadline = heartbeatDeadline;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => _connected;

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
      if (_closed ||
          generation != _socketGeneration ||
          !identical(_channel, channel)) {
        throw StateError('Hermes Desktop connection was superseded');
      }
      _capabilityCache.resetForReconnect();
      _connected = true;
    } catch (error) {
      debugPrint(
        '[tui-gateway] WebSocket connection failed '
        '(${_safeFailureKind(error)})',
      );
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
    _lastInboundAt = DateTime.now();
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) return;
      final frame = Map<String, dynamic>.from(decoded);
      final id = frame['id'];
      if (id is num) {
        final pending = _pending.remove(id.toInt());
        if (pending == null) return;
        pending.timer.cancel();
        final error = frame['error'];
        if (error is Map) {
          final map = Map<String, dynamic>.from(error);
          pending.completer.completeError(
            TuiGatewayRpcError(
              pending.method,
              pending.redactRemoteError
                  ? 'Hermes rejected the sensitive response'
                  : (map['message'] ?? 'Unknown JSON-RPC error').toString(),
              code: (map['code'] as num?)?.toInt(),
            ),
          );
        } else {
          final result = frame['result'];
          pending.completer.complete(
            result is Map
                ? Map<String, dynamic>.from(result)
                : <String, dynamic>{'value': result},
          );
        }
        return;
      }

      if (frame['method'] != 'event') return;
      final rawParams = frame['params'];
      if (rawParams is! Map) return;
      final params = Map<String, dynamic>.from(rawParams);
      final rawPayload = params['payload'];
      final type = (params['type'] ?? '').toString().trim();
      if (type == 'gateway.ready' &&
          rawPayload is Map &&
          rawPayload['heartbeat'] == true) {
        _startHeartbeat(generation, channel);
      }
      final rawSessionId = params['session_id'];
      final explicitSessionId = rawSessionId is String
          ? rawSessionId.trim()
          : '';
      final legacyRuntimeId = _legacyEventRuntimeId;
      final sessionId = explicitSessionId.isNotEmpty
          ? explicitSessionId
          : _connected &&
                !_legacyEventRuntimeAmbiguous &&
                legacyRuntimeId != null &&
                type.isNotEmpty &&
                !type.startsWith('subagent.')
          ? legacyRuntimeId
          : '';
      _events.add(
        TuiGatewayEvent(
          type: type,
          sessionId: sessionId,
          payload: rawPayload is Map
              ? Map<String, dynamic>.from(rawPayload)
              : const <String, dynamic>{},
        ),
      );
    } catch (_) {
      // Un frame ajeno o malformado no debe derribar el stream del chat.
    }
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
    // Antes de `ready`, `_connectOnce` conserva el error original y es el único
    // owner del teardown. Evita dos cancel/close concurrentes sobre un upgrade
    // rechazado.
    if (!wasConnected) return;
    _connected = false;
    _stopHeartbeat();
    _resetLegacyEventRuntimeAnchor();
    _capabilityCache.resetForReconnect();
    _channel = null;
    final subscription = _subscription;
    _subscription = null;
    unawaited(_teardownTransport(channel, subscription));
    _failPending(error, stackTrace);
    // `events` is the long-lived side of the Desktop protocol. A socket can
    // disappear while there is no JSON-RPC request pending (for example while
    // Hermes is executing a tool), so failing only `_pending` leaves the chat
    // stuck in "streaming" until its watchdog fires. Notify the ActiveChat as
    // soon as an already-established transport drops. Connection failures
    // before `ready` are deliberately not forwarded: `_connectOnce` owns those
    // and can still use the REST fallback without racing an event-stream error.
    if (wasConnected && !_events.isClosed) {
      _events.addError(error, stackTrace);
    }
  }

  void _handleSocketDone(int generation, WebSocketChannel channel) {
    if (generation != _socketGeneration || !identical(_channel, channel)) {
      return;
    }
    final wasConnected = _connected;
    _connected = false;
    _stopHeartbeat();
    _resetLegacyEventRuntimeAnchor();
    _capabilityCache.resetForReconnect();
    final subscription = _subscription;
    _channel = null;
    _subscription = null;
    if (wasConnected) {
      unawaited(_teardownTransport(channel, subscription));
    }
    final error = StateError('Hermes Desktop WebSocket closed');
    _failPending(error);
    if (wasConnected && !_events.isClosed) {
      _events.addError(error);
    }
  }

  void _startHeartbeat(int generation, WebSocketChannel channel) {
    _stopHeartbeat();
    _lastInboundAt = DateTime.now();
    if (_heartbeatInterval <= Duration.zero ||
        _heartbeatDeadline <= Duration.zero) {
      return;
    }
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (generation != _socketGeneration ||
          !identical(_channel, channel) ||
          !_connected) {
        return;
      }
      if (DateTime.now().difference(_lastInboundAt) >= _heartbeatDeadline) {
        _handleSocketError(
          generation,
          channel,
          StateError('Hermes Desktop WebSocket heartbeat timed out'),
        );
        return;
      }
      try {
        channel.sink.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'heartbeat-${++_heartbeatSequence}',
            'method': 'gateway.ping',
            'params': const <String, dynamic>{},
          }),
        );
      } catch (error, stackTrace) {
        _handleSocketError(generation, channel, error, stackTrace);
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _failPending(Object error, [StackTrace? stackTrace]) {
    for (final pending in _pending.values.toList()) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          pending.redactRemoteError
              ? TuiGatewayRpcError(
                  pending.method,
                  'Sensitive response transport failed',
                )
              : error,
          stackTrace,
        );
      }
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await connect();
    return _requestConnected(method, params, timeout: timeout);
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
    Duration timeout = const Duration(seconds: 30),
    bool redactRemoteError = false,
  }) {
    final channel = _channel;
    final generation = _socketGeneration;
    if (!_connected || channel == null || _closed) {
      throw StateError('Hermes Desktop WebSocket is not connected');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    final timer = Timer(timeout, () {
      final pending = _pending.remove(id);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.completeError(
          TuiGatewayRpcError(method, 'Timeout waiting for JSON-RPC response'),
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
        pending.completer.completeError(
          redactRemoteError
              ? TuiGatewayRpcError(
                  method,
                  'Sensitive response transport failed',
                )
              : error,
          stackTrace,
        );
      }
      if (redactRemoteError) {
        Error.throwWithStackTrace(
          TuiGatewayRpcError(method, 'Sensitive response transport failed'),
          stackTrace,
        );
      }
      rethrow;
    }
    return completer.future;
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    try {
      return await resumeExisting(storedSessionId, profile: profile);
    } on TuiGatewayRpcError catch (error) {
      if (error.code != 4007) rethrow;
      // Un borrador móvil aún no existe en state.db. Hermes Desktop resuelve
      // el mismo caso creando una sesión viva en el primer envío; sembramos el
      // historial visible para conservar el contexto si era un chat heredado.
      debugPrint('[tui-gateway] stored session missing; creating live session');
      return createForFirstSubmit(
        profile: profile,
        seedMessages: seedMessages,
        model: model,
      );
    }
  }

  Future<List<AgentProfile>> listProfiles({
    bool includeSessions = false,
    Map<String, String> preferredSessionIds = const {},
  }) async {
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
      return List<AgentProfile>.unmodifiable(
        rawProfiles
            .whereType<Map>()
            .map((raw) => AgentProfile.fromJson(Map<String, dynamic>.from(raw)))
            .where((profile) => profile.name.trim().isNotEmpty),
      );
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
  /// `group`, `image`/`pet` heredados, …).
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

    await connect();
    final current = await _botModeProfile(owner);
    if (current.hasInvalidBotModeMetadata) {
      throw const TuiGatewayRpcError(method, 'Bot Mode metadata is malformed');
    }
    final botMeta = <String, dynamic>{...current.botModeUiMeta};
    if (title != null) {
      if (safeTitle!.isEmpty) {
        botMeta.remove('title');
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
    if (identity != null) {
      botMeta
        ..remove('image')
        ..remove('pet')
        ..addAll(identity.toBotModeMetadata());
    }

    final configured = await _request(method, {
      'name': owner,
      'ui_meta': {'hermes-bots': botMeta},
    });
    final applied = configured['applied'];
    if (configured['ok'] != true ||
        applied is! Map ||
        applied['ui_meta'] != true) {
      throw const TuiGatewayRpcError(
        method,
        'Hermes did not persist the bot identity',
      );
    }
  }

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
    final result = await _request('session.resume', {
      'session_id': storedSessionId,
      'source': 'mobile',
      if (profile.trim().isNotEmpty) 'profile': profile.trim(),
      if (omitMessages) 'omit_messages': true,
      if (deferHistory) 'defer_history': true,
    });
    return _parseSessionBinding(
      result,
      requestedStoredSessionId: storedSessionId,
      created: false,
      method: 'session.resume',
    );
  }

  @override
  Future<DesktopSessionBinding> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    final result = await _request('session.resume', {
      'session_id': storedSessionId,
      'source': 'mobile',
      if (profile.trim().isNotEmpty) 'profile': profile.trim(),
    });
    return _parseSessionBinding(
      result,
      requestedStoredSessionId: storedSessionId,
      created: false,
      method: 'session.resume',
      rememberLegacyRuntime: false,
    );
  }

  @override
  void commitRecoveryRuntime(String runtimeSessionId) {
    _rememberLegacyEventRuntime(runtimeSessionId);
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
    final result = await _request('session.create', {
      'source': 'mobile',
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
    final result = await _request('session.create', {
      'source': 'mobile',
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
  }) {
    try {
      final binding = DesktopSessionBinding.fromSnapshot(
        DesktopSessionSnapshot.fromJson(
          result,
          requestedStoredSessionId: requestedStoredSessionId,
          created: created,
          method: method,
        ),
      );
      if (rememberLegacyRuntime) {
        _rememberLegacyEventRuntime(binding.runtimeSessionId);
      }
      return binding;
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
    final result = await _request(method, {
      'session_id': _validatedRuntimeId(method, runtimeSessionId),
      'command': _validatedSlashCommand(method, command),
    }, timeout: const Duration(minutes: 3));
    return DesktopCommandRpcResult.fromJson(
      _payloadSanitizer.sanitizeCommandResponse(result),
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
    final result = await _request(method, {
      'session_id': _validatedRuntimeId(method, runtimeSessionId),
      'name': commandName,
      'arg': argument,
    }, timeout: const Duration(minutes: 3));
    return DesktopCommandRpcResult.fromJson(
      _payloadSanitizer.sanitizeCommandResponse(result),
    );
  }

  @override
  Future<DesktopSubagentInterruptResult> interruptSubagent(
    String subagentId,
  ) async {
    const method = 'subagent.interrupt';
    final requestedId = subagentId.trim();
    if (requestedId.isEmpty || requestedId.length > 512) {
      throw const TuiGatewayRpcError(method, 'Invalid subagent identity');
    }
    final result = await _requestOptionalCapability(
      DesktopGatewayCapability.subagentInterrupt,
      method,
      {'subagent_id': requestedId},
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
    Duration timeout = const Duration(seconds: 30),
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
    final result = await _controlRequest(
      'projects.project_sessions',
      {'project_id': _validatedControlValue(projectId, maxLength: 2048)},
      capability: DesktopGatewayCapability.projectsCenter,
    );
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

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    await _request('prompt.submit', {
      'session_id': runtimeSessionId,
      'text': text,
    });
  }

  @override
  Future<void> submitInterruptedPrompt(
    String runtimeSessionId,
    String text,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (true) {
      try {
        await _request('prompt.submit', {
          'session_id': runtimeSessionId,
          'text': text,
          'interrupted': true,
        });
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
    final result = await _request('prompt.submit', {
      'session_id': runtimeSessionId,
      'text': text,
      'client_turn_id': clientTurnId,
    });
    return DesktopTurnAck.fromJson(result, expectedClientTurnId: clientTurnId);
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
    final wanted = sourceText.trim();
    if (wanted.isEmpty) return null;
    Map<String, dynamic> result;
    try {
      result = await _request('session.history', {
        'session_id': runtimeSessionId,
      });
    } catch (_) {
      return null;
    }
    final rawMessages = result['messages'];
    if (rawMessages is! List) return null;
    bool isTruthyJson(Object? value) {
      if (value == null || value == false) return false;
      if (value is num) return value != 0;
      if (value is String) return value.isNotEmpty;
      return true;
    }

    final durableUsers = <Map<String, dynamic>>[];
    for (final raw in rawMessages) {
      if (raw is! Map) return null;
      final message = Map<String, dynamic>.from(raw);
      if (message['role'] != 'user' || isTruthyJson(message['display_kind'])) {
        continue;
      }
      if (message['row_id'] is! int || message['text'] is! String) {
        return null;
      }
      durableUsers.add(message);
    }
    final matches = durableUsers.where((message) {
      return message['text'] == sourceText;
    }).toList();
    if (matches.length == 1) {
      return matches.single['row_id'] as int;
    }
    if (matches.length > 1 &&
        expectedOrdinal >= 0 &&
        expectedOrdinal < durableUsers.length &&
        matches.any(
          (message) => identical(durableUsers[expectedOrdinal], message),
        )) {
      return durableUsers[expectedOrdinal]['row_id'] as int;
    }
    return null;
  }

  @override
  Future<void> submitRewindPrompt(
    String runtimeSessionId,
    String text,
    int truncateBeforeUserOrdinal,
  ) async {
    await _request('prompt.submit', {
      'session_id': runtimeSessionId,
      'text': text,
      'truncate_before_user_ordinal': truncateBeforeUserOrdinal,
      'confirm_truncate': true,
      if (truncateBeforeUserOrdinal == 0) 'confirm_empty_truncate': true,
    });
  }

  @override
  Future<DesktopRewindAck> submitDurableRewindPrompt(
    String runtimeSessionId,
    String text,
    int truncateBeforeUserOrdinal, {
    required int truncateBeforeRowId,
  }) async {
    final result = await _request('prompt.submit', {
      'session_id': runtimeSessionId,
      'text': text,
      'truncate_before_row_id': truncateBeforeRowId,
      'confirm_truncate': true,
      if (truncateBeforeUserOrdinal == 0) 'confirm_empty_truncate': true,
    });
    return DesktopRewindAck.fromJson(result);
  }

  @override
  Future<DesktopAttachmentResult> attachImageBytes(
    String runtimeSessionId, {
    required String filename,
    required String contentBase64,
  }) async {
    final result = await _request('image.attach_bytes', {
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
    final result = await _request('file.attach', {
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
    await _request('image.detach', {
      'session_id': runtimeSessionId,
      'path': path,
    }, timeout: const Duration(seconds: 10));
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    final result = await _request('session.steer', {
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
    final result = await _request(method, {
      'session_id': runtimeSessionId,
      'text': text,
    }, timeout: const Duration(seconds: 10));
    return switch (result['status']) {
      'redirected' => DesktopRedirectDisposition.redirected,
      'queued' => DesktopRedirectDisposition.queued,
      _ => throw const TuiGatewayRpcError(
        method,
        'Hermes rejected the live correction',
      ),
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
    final runtime = _validatedRuntimeId(method, runtimeSessionId);
    final focus = focusTopic.trim();
    final result = await _request(
      method,
      {'session_id': runtime, if (focus.isNotEmpty) 'focus_topic': focus},
      // La compresión hace una llamada de modelo completa y en servidores
      // domésticos puede tardar varios minutos.
      timeout: const Duration(minutes: 3),
    );
    try {
      return DesktopCompressionResult.fromJson(result);
    } on FormatException {
      throw const TuiGatewayRpcError(
        method,
        'Hermes returned an invalid session compression result',
      );
    }
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
      final opaqueRequestId = _interactiveRequestId(method, requestId);
      await connect();
      final result = await _sendSensitiveResponseConnected(
        method: method,
        requestId: opaqueRequestId,
        valueKey: valueKey,
        value: value,
      );
      return DesktopPromptResponse.fromJson(
        result,
        method: method,
        allowExpired: true,
      );
    } finally {
      // Cubre también validación, conexión y envío fallidos. Nunca permite que
      // el llamador reutilice automáticamente una credencial tras un error.
      value.dispose();
    }
  }

  Future<Map<String, dynamic>> _sendSensitiveResponseConnected({
    required String method,
    required String requestId,
    required String valueKey,
    required EphemeralSensitiveValue value,
  }) {
    try {
      final ephemeralValue = value.take();
      return _requestConnected(method, {
        'request_id': requestId,
        valueKey: ephemeralValue,
      }, redactRemoteError: true);
    } finally {
      // `_requestConnected` serializa el frame de forma síncrona y su tabla de
      // pendientes solo conserva método/completer/timer, nunca los params.
      value.dispose();
    }
  }

  @override
  Future<DesktopPromptResponse> respondToTerminalRead(String requestId) async {
    const method = 'terminal.read.respond';
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
  }) async {
    await _request('approval.respond', {
      'session_id': runtimeSessionId,
      'choice': choice,
      if (resolveAll) 'all': true,
    });
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
