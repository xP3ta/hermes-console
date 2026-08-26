import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'attachment_draft.dart';

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

/// Lote local recuperable de un único envío. Todo el JSON se guarda cifrado;
/// IDs, texto, nombres y rutas nunca deben copiarse a logs/diagnósticos.
class PreparedTurn {
  static const schemaVersion = 2;

  final String connectionId;
  final String sessionId;
  final String clientTurnId;
  final int createdAtMs;
  final int updatedAtMs;
  final String text;
  final List<AttachmentDraft> attachments;
  final String model;
  final String profile;
  final PreparedTurnTransport transport;
  final PreparedTurnState state;
  final bool restoresComposer;

  const PreparedTurn({
    required this.connectionId,
    required this.sessionId,
    required this.clientTurnId,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.text,
    required this.attachments,
    required this.model,
    required this.profile,
    this.transport = PreparedTurnTransport.unknown,
    this.state = PreparedTurnState.prepared,
    this.restoresComposer = true,
  });

  String get storageId =>
      jsonEncode([connectionId, profile, sessionId, clientTurnId]);

  /// Identidad usada por el schema anterior, sin aislamiento por profile.
  String get legacyStorageId => '$connectionId::$sessionId::$clientTurnId';

  List<AttachmentDraft> get activeAttachments => attachments
      .where((item) => item.uploadState != AttachmentUploadState.removed)
      .toList(growable: false);

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
    int? updatedAtMs,
    String? profile,
    List<AttachmentDraft>? attachments,
    PreparedTurnTransport? transport,
    PreparedTurnState? state,
    bool? restoresComposer,
  }) => PreparedTurn(
    connectionId: connectionId,
    sessionId: sessionId,
    clientTurnId: clientTurnId,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    text: text,
    attachments: attachments ?? this.attachments,
    model: model,
    profile: profile ?? this.profile,
    transport: transport ?? this.transport,
    state: state ?? this.state,
    restoresComposer: restoresComposer ?? this.restoresComposer,
  );

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'connection_id': connectionId,
    'session_id': sessionId,
    'client_turn_id': clientTurnId,
    'created_at_ms': createdAtMs,
    'updated_at_ms': updatedAtMs,
    'text': text,
    'attachments': attachments.map((item) => item.toJson()).toList(),
    'model': model,
    'profile': profile,
    'transport': transport.name,
    'state': state.name,
    'restores_composer': restoresComposer,
  };

  factory PreparedTurn.fromJson(Map<String, dynamic> json) {
    final persistedSchema = (json['schema_version'] as num?)?.toInt();
    if (persistedSchema != 1 && persistedSchema != schemaVersion) {
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
      text: text,
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
