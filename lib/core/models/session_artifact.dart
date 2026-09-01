enum SessionArtifactKind {
  image,
  file,
  document,
  generated,
  toolResult,
  unknown,
}

enum SessionArtifactAvailability { ready, missing, expired, unknown }

final class SessionArtifactSource {
  final String? messageId;
  final int? rowId;
  final int messageOrdinal;

  const SessionArtifactSource({
    required this.messageOrdinal,
    this.messageId,
    this.rowId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionArtifactSource &&
          messageId == other.messageId &&
          rowId == other.rowId &&
          messageOrdinal == other.messageOrdinal;

  @override
  int get hashCode => Object.hash(messageId, rowId, messageOrdinal);

  @override
  String toString() =>
      'SessionArtifactSource(ordinal: $messageOrdinal, hasId: '
      '${messageId != null}, hasRowId: ${rowId != null})';
}

/// Safe metadata projection. It never owns artifact bytes or transcript text.
final class SessionArtifact {
  final String id;
  final String? serverId;
  final SessionArtifactKind kind;
  final String displayName;
  final String? mimeType;
  final int? sizeBytes;
  final List<SessionArtifactSource> sources;
  final String? managedReference;
  final bool? remote;
  final SessionArtifactAvailability availability;
  final DateTime? createdAt;

  SessionArtifact({
    required this.id,
    required this.kind,
    required this.displayName,
    required List<SessionArtifactSource> sources,
    this.serverId,
    this.mimeType,
    this.sizeBytes,
    this.managedReference,
    this.remote,
    this.availability = SessionArtifactAvailability.unknown,
    this.createdAt,
  }) : sources = List.unmodifiable(sources);

  SessionArtifactSource get primarySource => sources.first;

  SessionArtifact withSources(List<SessionArtifactSource> value) =>
      SessionArtifact(
        id: id,
        serverId: serverId,
        kind: kind,
        displayName: displayName,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        sources: value,
        managedReference: managedReference,
        remote: remote,
        availability: availability,
        createdAt: createdAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionArtifact &&
          id == other.id &&
          serverId == other.serverId &&
          kind == other.kind &&
          displayName == other.displayName &&
          mimeType == other.mimeType &&
          sizeBytes == other.sizeBytes &&
          _listEquals(sources, other.sources) &&
          managedReference == other.managedReference &&
          remote == other.remote &&
          availability == other.availability &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(
    id,
    serverId,
    kind,
    displayName,
    mimeType,
    sizeBytes,
    Object.hashAll(sources),
    managedReference,
    remote,
    availability,
    createdAt,
  );

  @override
  String toString() =>
      'SessionArtifact(kind: ${kind.name}, hasServerId: ${serverId != null}, '
      'sources: ${sources.length}, available: ${availability.name})';
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
