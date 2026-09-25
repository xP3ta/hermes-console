import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'attachment_draft.dart';
import 'bot_mention.dart';

enum PreparedTurnState {
  prepared,
  submitting,
  accepted,
  running,
  ambiguous,
  failedBeforeAcceptance,
  terminal,
}

enum PreparedTurnTransport { desktop, rest, bridgeLocal, unknown }

/// Qué había en el transcript durable visible JUSTO antes de enviar el turno.
/// Solo guarda identidades opacas (nunca texto) y decide un retry tras un
/// fallo de transporte pre-ACK: la frontera calculada en el momento del retry
/// puede haber adoptado ya la fila del propio turno y provocar doble envío.
enum PreparedTurnRetryBoundaryKind {
  /// Último user durable visible, por identidad exacta.
  identity,

  /// Transcript completo sin ningún user durable previo.
  empty,

  /// La sesión no existía en el servidor: este turno iba a crearla.
  knownMissing,

  /// No se pudo demostrar la frontera; el retry falla cerrado.
  unknown,
}

class PreparedTurnRetryBoundary {
  const PreparedTurnRetryBoundary._(
    this.kind, {
    this.messageId,
    this.rowId,
    this.createdSessionId,
  });

  const PreparedTurnRetryBoundary.empty()
    : this._(PreparedTurnRetryBoundaryKind.empty);

  const PreparedTurnRetryBoundary.knownMissing()
    : this._(PreparedTurnRetryBoundaryKind.knownMissing);

  const PreparedTurnRetryBoundary.unknown()
    : this._(PreparedTurnRetryBoundaryKind.unknown);

  /// Devuelve [PreparedTurnRetryBoundary.unknown] si no hay coordenada válida.
  factory PreparedTurnRetryBoundary.identity({String? messageId, int? rowId}) {
    final validMessageId =
        messageId != null && messageId.isNotEmpty && messageId.length <= 180
        ? messageId
        : null;
    final validRowId = rowId != null && rowId > 0 ? rowId : null;
    if (validMessageId == null && validRowId == null) {
      return const PreparedTurnRetryBoundary.unknown();
    }
    return PreparedTurnRetryBoundary._(
      PreparedTurnRetryBoundaryKind.identity,
      messageId: validMessageId,
      rowId: validRowId,
    );
  }

  final PreparedTurnRetryBoundaryKind kind;
  final String? messageId;
  final int? rowId;

  /// Solo para [PreparedTurnRetryBoundaryKind.knownMissing]: clave durable que
  /// devolvió `session.create` para ESTE turno, persistida en cuanto se conoce
  /// (antes de `prompt.submit`). Un 404 solo demuestra «no entregado» si la
  /// lectura se hizo contra exactamente esta clave; sin ella (process death
  /// antes del bind, lote antiguo, lectura con el id provisional `mob-…`) el
  /// retry falla cerrado.
  final String? createdSessionId;

  static String? _validSessionKey(String? value) =>
      value != null &&
          value.isNotEmpty &&
          value.length <= 256 &&
          value == value.trim()
      ? value
      : null;

  /// Copia con la clave creada. Solo aplica a `knownMissing` y nunca
  /// sobrescribe una clave ya fijada con otra distinta.
  PreparedTurnRetryBoundary withCreatedSessionId(String sessionId) {
    final key = _validSessionKey(sessionId);
    if (kind != PreparedTurnRetryBoundaryKind.knownMissing || key == null) {
      return this;
    }
    if (createdSessionId != null) return this;
    return PreparedTurnRetryBoundary._(kind, createdSessionId: key);
  }

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    if (messageId != null) 'message_id': messageId,
    if (rowId != null) 'row_id': rowId,
    if (createdSessionId != null) 'created_session_id': createdSessionId,
  };

  /// Un valor malformado nunca invalida el lote entero: se degrada a
  /// `unknown` (retry fail-closed) en vez de perder la outbox.
  static PreparedTurnRetryBoundary? fromJson(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) return const PreparedTurnRetryBoundary.unknown();
    final kind = PreparedTurnRetryBoundaryKind.values
        .where((value) => value.name == raw['kind'])
        .firstOrNull;
    switch (kind) {
      case PreparedTurnRetryBoundaryKind.identity:
        final messageId = raw['message_id'];
        final rowId = raw['row_id'];
        return PreparedTurnRetryBoundary.identity(
          messageId: messageId is String ? messageId : null,
          rowId: rowId is int ? rowId : null,
        );
      case PreparedTurnRetryBoundaryKind.empty:
        return const PreparedTurnRetryBoundary.empty();
      case PreparedTurnRetryBoundaryKind.knownMissing:
        final created = raw['created_session_id'];
        final key = created is String ? _validSessionKey(created) : null;
        return key == null
            ? const PreparedTurnRetryBoundary.knownMissing()
            : PreparedTurnRetryBoundary._(
                PreparedTurnRetryBoundaryKind.knownMissing,
                createdSessionId: key,
              );
      case PreparedTurnRetryBoundaryKind.unknown:
      case null:
        return const PreparedTurnRetryBoundary.unknown();
    }
  }
}

/// Lote local recuperable de un único envío. Todo el JSON se guarda cifrado;
/// IDs, texto, nombres y rutas nunca deben copiarse a logs/diagnósticos.
class PreparedTurn {
  static const schemaVersion = 5;

  final String connectionId;
  final String sessionId;
  final String clientTurnId;
  final int createdAtMs;
  final int updatedAtMs;

  /// Orden de admisión monotónico de la cola durable. `null` solo existe para
  /// migraciones legacy y bloquea el drain hasta cancelación/reconciliación.
  final int? queueOrder;
  final String text;
  final String fullText;
  final String? desktopText;
  final String mentionAnnotation;
  final List<BotMention> mentions;
  final List<AttachmentDraft> attachments;
  final String model;
  final String profile;
  final PreparedTurnTransport transport;
  final PreparedTurnState state;
  final bool restoresComposer;
  final bool queued;

  /// Frontera durable capturada al enviar. `null` = lote anterior a 1.2.13
  /// (sin frontera persistida).
  final PreparedTurnRetryBoundary? retryBoundary;

  const PreparedTurn({
    required this.connectionId,
    required this.sessionId,
    required this.clientTurnId,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.queueOrder,
    required this.text,
    String? fullText,
    this.desktopText,
    this.mentionAnnotation = '',
    this.mentions = const [],
    required this.attachments,
    required this.model,
    required this.profile,
    this.transport = PreparedTurnTransport.unknown,
    this.state = PreparedTurnState.prepared,
    this.restoresComposer = true,
    this.queued = false,
    this.retryBoundary,
  }) : fullText = fullText ?? text;

  String get storageId =>
      jsonEncode([connectionId, profile, sessionId, clientTurnId]);

  /// Identidad usada por el schema anterior, sin aislamiento por profile.
  String get legacyStorageId => '$connectionId::$sessionId::$clientTurnId';

  List<AttachmentDraft> get activeAttachments => attachments
      .where((item) => item.uploadState != AttachmentUploadState.removed)
      .toList(growable: false);

  /// A matching composer retry must reuse every frozen payload field.
  /// Solo reutiliza la identidad al reintentar exactamente el mismo lote.
  /// Cambiar modelo, perfil o cualquier metadato del adjunto crea otro turno.
  bool matchesBatch({
    required String text,
    required List<AttachmentDraft> attachments,
    required String model,
    required String profile,
    bool restoresComposer = true,
  }) {
    if (this.restoresComposer != restoresComposer) return false;
    if (this.text != text || this.model != model || this.profile != profile) {
      return false;
    }
    final previousAttachments = activeAttachments;
    final currentAttachments = attachments
        .where((item) => item.uploadState != AttachmentUploadState.removed)
        .toList(growable: false);
    if (previousAttachments.length != currentAttachments.length) return false;
    for (var index = 0; index < currentAttachments.length; index++) {
      if (!previousAttachments[index].sameSourceAs(currentAttachments[index])) {
        return false;
      }
    }
    return true;
  }

  PreparedTurn copyWith({
    String? mentionAnnotation,
    List<BotMention>? mentions,
    int? updatedAtMs,
    int? queueOrder,
    String? text,
    String? profile,
    List<AttachmentDraft>? attachments,
    String? fullText,
    String? desktopText,
    PreparedTurnTransport? transport,
    PreparedTurnState? state,
    bool? restoresComposer,
    bool? queued,
    PreparedTurnRetryBoundary? retryBoundary,
  }) => PreparedTurn(
    connectionId: connectionId,
    sessionId: sessionId,
    clientTurnId: clientTurnId,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    queueOrder: queueOrder ?? this.queueOrder,
    text: text ?? this.text,
    fullText: fullText ?? this.fullText,
    desktopText: desktopText ?? this.desktopText,
    mentionAnnotation: mentionAnnotation ?? this.mentionAnnotation,
    mentions: mentions ?? this.mentions,
    attachments: attachments ?? this.attachments,
    model: model,
    profile: profile ?? this.profile,
    transport: transport ?? this.transport,
    state: state ?? this.state,
    restoresComposer: restoresComposer ?? this.restoresComposer,
    queued: queued ?? this.queued,
    retryBoundary: retryBoundary ?? this.retryBoundary,
  );

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'connection_id': connectionId,
    'session_id': sessionId,
    'client_turn_id': clientTurnId,
    'created_at_ms': createdAtMs,
    'updated_at_ms': updatedAtMs,
    if (queueOrder != null) 'queue_order': queueOrder,
    'text': text,
    'full_text': fullText,
    if (mentionAnnotation.isNotEmpty) 'mention_annotation': mentionAnnotation,
    if (mentions.isNotEmpty)
      'mentions': mentions.map((bot) => bot.toJson()).toList(),
    if (desktopText != null) 'desktop_text': desktopText,
    'attachments': attachments.map((item) => item.toJson()).toList(),
    'model': model,
    'profile': profile,
    'transport': transport.name,
    'state': state.name,
    'restores_composer': restoresComposer,
    'queued': queued,
    if (retryBoundary != null) 'retry_boundary': retryBoundary!.toJson(),
  };

  factory PreparedTurn.fromJson(Map<String, dynamic> json) {
    final persistedSchema = (json['schema_version'] as num?)?.toInt();
    if (persistedSchema != 1 &&
        persistedSchema != 2 &&
        persistedSchema != 3 &&
        persistedSchema != 4 &&
        persistedSchema != schemaVersion) {
      throw const FormatException('Unsupported prepared turn schema');
    }
    String requiredString(String key) {
      final value = (json[key] ?? '').toString();
      if (value.isEmpty) throw FormatException('Missing $key');
      return value;
    }

    final createdAtMs = (json['created_at_ms'] as num?)?.toInt() ?? 0;
    final updatedAtMs = (json['updated_at_ms'] as num?)?.toInt() ?? 0;
    if (createdAtMs <= 0 || updatedAtMs < createdAtMs) {
      throw const FormatException('Invalid prepared turn timestamps');
    }
    int? queueOrder;
    if ((persistedSchema == 4 || persistedSchema == schemaVersion) &&
        json.containsKey('queue_order')) {
      final rawQueueOrder = json['queue_order'];
      if (rawQueueOrder is! int || rawQueueOrder < 0) {
        throw const FormatException('Invalid prepared turn queue order');
      }
      queueOrder = rawQueueOrder;
    }
    final text = (json['text'] ?? '').toString();
    final connectionId = requiredString('connection_id');
    final sessionId = requiredString('session_id');
    final clientTurnId = requiredString('client_turn_id');
    final attachments = <AttachmentDraft>[];
    final rawAttachments = json['attachments'] as List? ?? const [];
    for (var index = 0; index < rawAttachments.length; index++) {
      final raw = rawAttachments[index];
      if (raw is! Map) throw const FormatException('Invalid attachment');
      final attachmentJson = Map<String, dynamic>.from(raw);
      var attachment = AttachmentDraft.fromJson(attachmentJson);
      if (persistedSchema == 1 &&
          (attachmentJson['local_id'] ?? '').toString().isEmpty) {
        attachment = attachment.copyWith(
          localId: _legacyTurnAttachmentId(
            connectionId: connectionId,
            sessionId: sessionId,
            clientTurnId: clientTurnId,
            index: index,
            attachment: attachment,
          ),
        );
      }
      attachments.add(attachment);
    }
    if (text.trim().isEmpty && attachments.isEmpty) {
      throw const FormatException('Prepared turn is empty');
    }
    T parseEnum<T extends Enum>(List<T> values, String key, T fallback) {
      final raw = (json[key] ?? '').toString();
      return values.cast<T>().firstWhere(
        (value) => value.name == raw,
        orElse: () => fallback,
      );
    }

    return PreparedTurn(
      connectionId: connectionId,
      sessionId: sessionId,
      clientTurnId: clientTurnId,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs,
      queueOrder: queueOrder,
      text: text,
      fullText: persistedSchema != 1 && persistedSchema != 2
          ? (json['full_text'] ?? text).toString()
          : text,
      desktopText: persistedSchema != 1 && persistedSchema != 2
          ? json['desktop_text']?.toString()
          : null,
      mentionAnnotation: json['mention_annotation'] as String? ?? '',
      mentions: List.unmodifiable(
        (json['mentions'] as List? ?? const []).map(
          (raw) => BotMention.fromJson(Map<String, dynamic>.from(raw as Map)),
        ),
      ),
      attachments: attachments,
      model: (json['model'] ?? '').toString(),
      profile: (json['profile'] ?? '').toString(),
      transport: parseEnum(
        PreparedTurnTransport.values,
        'transport',
        PreparedTurnTransport.unknown,
      ),
      state: parseEnum(
        PreparedTurnState.values,
        'state',
        PreparedTurnState.ambiguous,
      ),
      restoresComposer: json['restores_composer'] as bool? ?? true,
      queued: persistedSchema != 1 && persistedSchema != 2
          ? json['queued'] as bool? ?? false
          : false,
      retryBoundary: PreparedTurnRetryBoundary.fromJson(json['retry_boundary']),
    );
  }
}

String _legacyTurnAttachmentId({
  required String connectionId,
  required String sessionId,
  required String clientTurnId,
  required int index,
  required AttachmentDraft attachment,
}) {
  final input =
      '$connectionId\u0000$sessionId\u0000$clientTurnId\u0000$index'
      '\u0000${attachment.type}\u0000${attachment.name}'
      '\u0000${attachment.mimeType}\u0000${attachment.sizeBytes}'
      '\u0000${attachment.localPath}';
  return 'legacy-turn-${sha256.convert(utf8.encode(input))}';
}
