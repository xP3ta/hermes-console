import 'dart:convert';

import '../models/desktop_session_snapshot.dart';
import '../models/session_artifact.dart';

final class ArtifactIndexScope {
  final String connectionId;
  final String logicalSessionId;

  factory ArtifactIndexScope({
    required String connectionId,
    required String logicalSessionId,
  }) {
    if (!_isOpaqueId(connectionId) || !_isOpaqueId(logicalSessionId)) {
      throw const FormatException('Invalid artifact index scope');
    }
    return ArtifactIndexScope._(
      connectionId: connectionId,
      logicalSessionId: logicalSessionId,
    );
  }

  const ArtifactIndexScope._({
    required this.connectionId,
    required this.logicalSessionId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArtifactIndexScope &&
          connectionId == other.connectionId &&
          logicalSessionId == other.logicalSessionId;

  @override
  int get hashCode => Object.hash(connectionId, logicalSessionId);

  @override
  String toString() => 'ArtifactIndexScope(<redacted>)';
}

final class ArtifactAuthorizationPolicy {
  static const int defaultMaximumSizeBytes = 1 << 40;

  final int revision;
  final Set<String> allowedManagedUriSchemes;
  final Set<String> allowedManagedHosts;
  final List<String> allowedManagedPathPrefixes;
  final int maximumSizeBytes;

  factory ArtifactAuthorizationPolicy({
    required int revision,
    Iterable<String> allowedManagedUriSchemes = const [],
    Iterable<String> allowedManagedHosts = const [],
    Iterable<String> allowedManagedPathPrefixes = const [],
    int maximumSizeBytes = defaultMaximumSizeBytes,
  }) {
    if (revision < 0 || maximumSizeBytes <= 0) {
      throw const FormatException('Invalid artifact authorization policy');
    }
    final schemes = <String>{};
    for (final raw in allowedManagedUriSchemes) {
      final scheme = raw.trim().toLowerCase();
      if (!RegExp(r'^[a-z][a-z0-9+.-]{0,31}$').hasMatch(scheme)) {
        throw const FormatException('Invalid managed URI scheme');
      }
      schemes.add(scheme);
    }
    final hosts = <String>{};
    for (final raw in allowedManagedHosts) {
      final host = raw.trim().toLowerCase();
      if (host.isEmpty || host.length > 253 || _hasControl(host)) {
        throw const FormatException('Invalid managed URI host');
      }
      hosts.add(host);
    }
    final prefixes = <String>[];
    for (final raw in allowedManagedPathPrefixes) {
      final normalized = _normalizeAbsolutePath(raw);
      if (normalized == null || normalized == '/') {
        throw const FormatException('Invalid managed path prefix');
      }
      prefixes.add(normalized);
    }
    prefixes.sort();
    return ArtifactAuthorizationPolicy._(
      revision: revision,
      allowedManagedUriSchemes: Set.unmodifiable(schemes),
      allowedManagedHosts: Set.unmodifiable(hosts),
      allowedManagedPathPrefixes: List.unmodifiable(prefixes),
      maximumSizeBytes: maximumSizeBytes,
    );
  }

  const ArtifactAuthorizationPolicy._({
    required this.revision,
    required this.allowedManagedUriSchemes,
    required this.allowedManagedHosts,
    required this.allowedManagedPathPrefixes,
    required this.maximumSizeBytes,
  });

  String? normalizeManagedReference(Object? raw) {
    if (raw is! String) return null;
    final value = raw.trim();
    if (value.isEmpty || value.length > 2048 || _hasControl(value)) {
      return null;
    }

    if (value.startsWith('/')) {
      final path = _normalizeAbsolutePath(value);
      if (path == null) return null;
      for (final prefix in allowedManagedPathPrefixes) {
        if (_isWithinPrefix(path, prefix)) return path;
      }
      return null;
    }

    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasScheme ||
        !allowedManagedUriSchemes.contains(uri.scheme.toLowerCase()) ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        _containsTraversal(uri.pathSegments)) {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    if ((scheme == 'http' || scheme == 'https') &&
        (host.isEmpty || !allowedManagedHosts.contains(host))) {
      return null;
    }
    if (host.isNotEmpty &&
        allowedManagedHosts.isNotEmpty &&
        !allowedManagedHosts.contains(host)) {
      return null;
    }
    return uri.replace(scheme: scheme, host: host).toString();
  }
}

final class ArtifactTranscriptEntry {
  final DesktopSessionMessage message;
  final int messageOrdinal;
  final int messageRevision;
  final String? stableMessageId;
  final int? stableRowId;

  factory ArtifactTranscriptEntry({
    required DesktopSessionMessage message,
    required int messageOrdinal,
    required int messageRevision,
    String? stableMessageId,
  }) {
    if (messageOrdinal < 0 || messageRevision < 0) {
      throw const FormatException('Invalid artifact transcript entry');
    }
    if (stableMessageId != null && !_isStableId(stableMessageId)) {
      throw const FormatException('Invalid artifact source message id');
    }
    final derivedId =
        stableMessageId ??
        message.stableId ??
        _stableId(message.raw['message_id']) ??
        _stableId(message.raw['id']);
    return ArtifactTranscriptEntry._(
      message: _artifactMessageProjection(message),
      messageOrdinal: messageOrdinal,
      messageRevision: messageRevision,
      stableMessageId: derivedId,
      stableRowId: message.identityAliasesConsistent ? message.rowId : null,
    );
  }

  const ArtifactTranscriptEntry._({
    required this.message,
    required this.messageOrdinal,
    required this.messageRevision,
    required this.stableMessageId,
    required this.stableRowId,
  });

  ArtifactTranscriptEntry withMessageRevision(int revision) {
    if (revision < 0) {
      throw const FormatException('Invalid artifact message revision');
    }
    if (revision == messageRevision) return this;
    return ArtifactTranscriptEntry._(
      message: message,
      messageOrdinal: messageOrdinal,
      messageRevision: revision,
      stableMessageId: stableMessageId,
      stableRowId: stableRowId,
    );
  }

  String get _identity => stableRowId != null
      ? 'row:$stableRowId'
      : stableMessageId == null
      ? 'ordinal:$messageOrdinal'
      : 'message:$stableMessageId';

  SessionArtifactSource get _source => SessionArtifactSource(
    messageId: stableMessageId,
    rowId: stableRowId,
    messageOrdinal: messageOrdinal,
  );

  @override
  String toString() =>
      'ArtifactTranscriptEntry(ordinal: $messageOrdinal, '
      'revision: $messageRevision, hasId: ${stableMessageId != null}, '
      'hasRowId: ${stableRowId != null})';
}

const _artifactNestedKeys = <String>{
  'attachment',
  'attachments',
  'artifact',
  'artifacts',
  'file',
  'image',
  'image_url',
  'document',
  'generated_image',
  'generated_images',
  'tool_result',
  'tool_results',
};

const _artifactMetadataKeys = <String>{
  'artifact_type',
  'kind',
  'type',
  'artifact_id',
  'attachment_id',
  'id',
  'mime_type',
  'media_type',
  'mime',
  'content_type',
  'display_name',
  'name',
  'filename',
  'file_name',
  'label',
  'size_bytes',
  'byte_size',
  'size',
  'managed_uri',
  'managed_url',
  'download_uri',
  'download_url',
  'managed_path',
  'uri',
  'url',
  'path',
  'remote',
  'is_remote',
  'availability',
  'artifact_status',
  'status',
  'created_at',
  'timestamp',
  'created',
};

DesktopSessionMessage _artifactMessageProjection(
  DesktopSessionMessage message,
) {
  final isTool = message.role == DesktopSessionMessageRole.tool;
  final content = _sanitizeArtifactValue(message.content, isTool: isTool);
  final context = isTool
      ? _sanitizeArtifactValue(message.context, isTool: true)
      : null;
  final rawContainers = _sanitizeArtifactValue(
    message.artifactContainers,
    isTool: isTool,
  );
  final containers = rawContainers is Map
      ? Map<String, dynamic>.unmodifiable(
          rawContainers.map((key, value) => MapEntry(key.toString(), value)),
        )
      : const <String, dynamic>{};
  return DesktopSessionMessage(
    stableId: message.stableId,
    rowId: message.rowId,
    identityAliasesConsistent: message.identityAliasesConsistent,
    serverOrdinal: message.serverOrdinal,
    artifactContainers: containers,
    role: message.role,
    rawRole: message.rawRole,
    content: content,
    context: context,
  );
}

Object? _sanitizeArtifactValue(
  Object? raw, {
  required bool isTool,
  bool candidate = false,
}) {
  if (raw is List) {
    final values = <Object?>[];
    for (final item in raw) {
      final sanitized = _sanitizeArtifactValue(
        item,
        isTool: isTool,
        candidate: candidate,
      );
      if (sanitized != null) values.add(sanitized);
    }
    return values.isEmpty ? null : List<Object?>.unmodifiable(values);
  }
  final map = _stringMap(raw);
  if (map == null) return null;
  final explicitKind = _explicitKind(map);
  final acceptsMetadata = candidate || explicitKind != null;
  final result = <String, dynamic>{};
  for (final entry in map.entries) {
    final key = entry.key;
    if (_artifactNestedKeys.contains(key)) {
      final nested = _sanitizeArtifactValue(
        entry.value,
        isTool: isTool,
        candidate: key != 'tool_result' && key != 'tool_results',
      );
      if (nested != null) result[key] = nested;
      continue;
    }
    if (isTool && key == 'result' && explicitKind != null) {
      final nested = _sanitizeArtifactValue(entry.value, isTool: true);
      if (nested != null) result[key] = nested;
      continue;
    }
    if (!acceptsMetadata || !_artifactMetadataKeys.contains(key)) continue;
    final scalar = _artifactScalar(entry.value);
    if (scalar != null) result[key] = scalar;
  }
  return result.isEmpty ? null : Map<String, dynamic>.unmodifiable(result);
}

Object? _artifactScalar(Object? value) {
  if (value == null || value is bool || value is num) return value;
  if (value is! String || value.length > 2048 || _hasControl(value)) {
    return null;
  }
  return value;
}

final class ArtifactIndexRevision {
  final ArtifactIndexScope scope;
  final int transcriptRevision;
  final int policyRevision;

  factory ArtifactIndexRevision({
    required ArtifactIndexScope scope,
    required int transcriptRevision,
    required int policyRevision,
  }) {
    if (transcriptRevision < 0 || policyRevision < 0) {
      throw const FormatException('Invalid artifact index revision');
    }
    return ArtifactIndexRevision._(
      scope: scope,
      transcriptRevision: transcriptRevision,
      policyRevision: policyRevision,
    );
  }

  const ArtifactIndexRevision._({
    required this.scope,
    required this.transcriptRevision,
    required this.policyRevision,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArtifactIndexRevision &&
          scope == other.scope &&
          transcriptRevision == other.transcriptRevision &&
          policyRevision == other.policyRevision;

  @override
  int get hashCode => Object.hash(scope, transcriptRevision, policyRevision);

  @override
  String toString() =>
      'ArtifactIndexRevision(transcript: $transcriptRevision, '
      'policy: $policyRevision)';
}

final class ArtifactIndexBuildStats {
  final int inspectedMessages;
  final int reusedMessages;
  final int candidateCount;

  const ArtifactIndexBuildStats({
    required this.inspectedMessages,
    required this.reusedMessages,
    required this.candidateCount,
  });
}

final class ArtifactIndexSnapshot {
  final ArtifactIndexRevision revision;
  final List<SessionArtifact> artifacts;
  final ArtifactIndexBuildStats buildStats;
  final Map<String, _ArtifactMessageProjection> _messageCache;

  ArtifactIndexSnapshot._({
    required this.revision,
    required List<SessionArtifact> artifacts,
    required this.buildStats,
    required Map<String, _ArtifactMessageProjection> messageCache,
  }) : artifacts = List.unmodifiable(artifacts),
       _messageCache = Map.unmodifiable(messageCache);

  @override
  String toString() =>
      'ArtifactIndexSnapshot(revision: ${revision.transcriptRevision}, '
      'artifacts: ${artifacts.length})';
}

/// Pure, explicitly invoked transcript projection. Calling [resolve] is the
/// lazy boundary; an unchanged revision returns [previous] without iterating
/// [transcript].
abstract final class ArtifactIndex {
  static ArtifactIndexSnapshot resolve({
    ArtifactIndexSnapshot? previous,
    required ArtifactIndexScope scope,
    required int transcriptRevision,
    required Iterable<ArtifactTranscriptEntry> transcript,
    required ArtifactAuthorizationPolicy policy,
  }) {
    final revision = ArtifactIndexRevision(
      scope: scope,
      transcriptRevision: transcriptRevision,
      policyRevision: policy.revision,
    );
    if (previous?.revision == revision) return previous!;

    final canReuse =
        previous != null &&
        previous.revision.scope == scope &&
        previous.revision.policyRevision == policy.revision &&
        transcriptRevision > previous.revision.transcriptRevision;
    final priorCache = canReuse
        ? previous._messageCache
        : const <String, _ArtifactMessageProjection>{};
    final entriesByIdentity = <String, ArtifactTranscriptEntry>{};
    for (final entry in transcript) {
      final current = entriesByIdentity[entry._identity];
      if (current == null ||
          entry.messageRevision > current.messageRevision ||
          (entry.messageRevision == current.messageRevision &&
              entry.messageOrdinal < current.messageOrdinal)) {
        entriesByIdentity[entry._identity] = entry;
      }
    }
    final entries = entriesByIdentity.values.toList(growable: false)
      ..sort((left, right) {
        final ordinal = left.messageOrdinal.compareTo(right.messageOrdinal);
        return ordinal != 0
            ? ordinal
            : left._identity.compareTo(right._identity);
      });

    var inspected = 0;
    var reused = 0;
    var candidateCount = 0;
    final nextCache = <String, _ArtifactMessageProjection>{};
    final found = <String, SessionArtifact>{};
    for (final entry in entries) {
      final cached = priorCache[entry._identity];
      late final _ArtifactMessageProjection projection;
      if (cached != null && cached.messageRevision == entry.messageRevision) {
        projection = cached;
        reused++;
      } else {
        projection = _ArtifactMessageProjection(
          messageRevision: entry.messageRevision,
          seeds: _extractMessage(entry.message, policy),
        );
        inspected++;
      }
      nextCache[entry._identity] = projection;
      candidateCount += projection.seeds.length;
      for (final seed in projection.seeds) {
        final identity = seed.serverId == null
            ? _fallbackIdentity(scope, entry._source, seed)
            : 'server:${seed.serverId}';
        final current = found[identity];
        if (current == null) {
          final id = seed.serverId ?? 'local-${_stableFingerprint(identity)}';
          found[identity] = seed.toArtifact(id: id, source: entry._source);
          continue;
        }
        found[identity] = seed.mergeInto(current, source: entry._source);
      }
    }

    return ArtifactIndexSnapshot._(
      revision: revision,
      artifacts: found.values.toList(growable: false),
      buildStats: ArtifactIndexBuildStats(
        inspectedMessages: inspected,
        reusedMessages: reused,
        candidateCount: candidateCount,
      ),
      messageCache: nextCache,
    );
  }
}

final class _ArtifactMessageProjection {
  final int messageRevision;
  final List<_ArtifactSeed> seeds;

  _ArtifactMessageProjection({
    required this.messageRevision,
    required List<_ArtifactSeed> seeds,
  }) : seeds = List.unmodifiable(seeds);
}

final class _ArtifactSeed {
  final String? serverId;
  final SessionArtifactKind kind;
  final String displayName;
  final bool hasExplicitDisplayName;
  final String? mimeType;
  final int? sizeBytes;
  final String? managedReference;
  final bool? remote;
  final SessionArtifactAvailability availability;
  final DateTime? createdAt;

  const _ArtifactSeed({
    required this.serverId,
    required this.kind,
    required this.displayName,
    required this.hasExplicitDisplayName,
    required this.mimeType,
    required this.sizeBytes,
    required this.managedReference,
    required this.remote,
    required this.availability,
    required this.createdAt,
  });

  SessionArtifact toArtifact({
    required String id,
    required SessionArtifactSource source,
  }) => SessionArtifact(
    id: id,
    serverId: serverId,
    kind: kind,
    displayName: displayName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    sources: [source],
    managedReference: managedReference,
    remote: remote,
    availability: availability,
    createdAt: createdAt,
  );

  SessionArtifact mergeInto(
    SessionArtifact current, {
    required SessionArtifactSource source,
  }) => SessionArtifact(
    id: current.id,
    serverId: serverId ?? current.serverId,
    kind: kind == SessionArtifactKind.unknown ? current.kind : kind,
    displayName: hasExplicitDisplayName ? displayName : current.displayName,
    mimeType: mimeType ?? current.mimeType,
    sizeBytes: sizeBytes ?? current.sizeBytes,
    sources: current.sources.contains(source)
        ? current.sources
        : [...current.sources, source],
    managedReference: managedReference ?? current.managedReference,
    remote: remote ?? current.remote,
    availability: availability == SessionArtifactAvailability.unknown
        ? current.availability
        : availability,
    createdAt: current.createdAt ?? createdAt,
  );
}

List<_ArtifactSeed> _extractMessage(
  DesktopSessionMessage message,
  ArtifactAuthorizationPolicy policy,
) {
  final seeds = <_ArtifactSeed>[];

  void collectContainer(
    Object? raw,
    SessionArtifactKind defaultKind, {
    bool requireExplicitType = false,
  }) {
    if (raw is List) {
      for (final item in raw) {
        collectContainer(
          item,
          defaultKind,
          requireExplicitType: requireExplicitType,
        );
      }
      return;
    }
    final map = _stringMap(raw);
    if (map == null) return;
    final explicitKind = _explicitKind(map);
    if (requireExplicitType && explicitKind == null) {
      _collectKnownContainers(
        map,
        isToolMessage: message.role == DesktopSessionMessageRole.tool,
        collect: collectContainer,
      );
      return;
    }
    final seed = _parseCandidate(
      map,
      defaultKind: explicitKind ?? defaultKind,
      policy: policy,
    );
    if (seed != null) seeds.add(seed);
    _collectKnownContainers(
      map,
      isToolMessage: message.role == DesktopSessionMessageRole.tool,
      collect: collectContainer,
    );
    if (message.role == DesktopSessionMessageRole.tool &&
        explicitKind == SessionArtifactKind.toolResult) {
      final result = _stringMap(map['result']);
      final resultKind = result == null ? null : _explicitKind(result);
      if (result != null && resultKind != null) {
        collectContainer(result, resultKind);
      }
    }
  }

  void collectStructuredRoot(Object? raw) {
    if (raw is List) {
      for (final item in raw) {
        collectStructuredRoot(item);
      }
      return;
    }
    final map = _stringMap(raw);
    if (map == null) return;
    final kind = _explicitKind(map);
    if (kind != null) {
      collectContainer(map, kind);
      return;
    }
    _collectKnownContainers(
      map,
      isToolMessage: message.role == DesktopSessionMessageRole.tool,
      collect: collectContainer,
    );
    if (message.role == DesktopSessionMessageRole.tool) {
      final result = _stringMap(map['result']);
      final resultKind = result == null ? null : _explicitKind(result);
      if (result != null && resultKind != null) {
        collectContainer(result, resultKind);
      }
    }
  }

  collectStructuredRoot(message.content);
  if (message.role == DesktopSessionMessageRole.tool) {
    collectStructuredRoot(message.context);
  }
  _collectKnownContainers(
    message.artifactContainers,
    isToolMessage: message.role == DesktopSessionMessageRole.tool,
    collect: collectContainer,
  );
  return List.unmodifiable(seeds);
}

typedef _ContainerCollector =
    void Function(
      Object? raw,
      SessionArtifactKind defaultKind, {
      bool requireExplicitType,
    });

void _collectKnownContainers(
  Map<String, dynamic> map, {
  required bool isToolMessage,
  required _ContainerCollector collect,
}) {
  for (final entry in const <String, SessionArtifactKind>{
    'attachment': SessionArtifactKind.file,
    'attachments': SessionArtifactKind.file,
    'artifact': SessionArtifactKind.unknown,
    'artifacts': SessionArtifactKind.unknown,
    'generated_image': SessionArtifactKind.generated,
    'generated_images': SessionArtifactKind.generated,
  }.entries) {
    if (map.containsKey(entry.key)) collect(map[entry.key], entry.value);
  }
  if (!isToolMessage) return;
  if (map.containsKey('tool_result')) {
    collect(
      map['tool_result'],
      SessionArtifactKind.toolResult,
      requireExplicitType: true,
    );
  }
  if (map.containsKey('tool_results')) {
    collect(
      map['tool_results'],
      SessionArtifactKind.toolResult,
      requireExplicitType: true,
    );
  }
}

_ArtifactSeed? _parseCandidate(
  Map<String, dynamic> map, {
  required SessionArtifactKind defaultKind,
  required ArtifactAuthorizationPolicy policy,
}) {
  final views = <Map<String, dynamic>>[map];
  for (final key in const [
    'attachment',
    'artifact',
    'file',
    'image',
    'image_url',
    'document',
    'generated_image',
  ]) {
    final nested = _stringMap(map[key]);
    if (nested != null) views.add(nested);
  }

  Object? first(Iterable<String> keys) {
    for (final view in views) {
      for (final key in keys) {
        if (view.containsKey(key)) return view[key];
      }
    }
    return null;
  }

  final serverId = _stableId(
    first(const ['artifact_id', 'attachment_id', 'id']),
  );
  final mimeType = _mimeType(
    first(const ['mime_type', 'media_type', 'mime', 'content_type']),
  );
  var kind = _explicitKind(map) ?? defaultKind;
  if (kind == SessionArtifactKind.unknown && mimeType != null) {
    kind = _kindFromMime(mimeType);
  } else if (kind == SessionArtifactKind.file &&
      mimeType != null &&
      _kindFromMime(mimeType) == SessionArtifactKind.image) {
    kind = SessionArtifactKind.image;
  }
  final rawName = first(const [
    'display_name',
    'name',
    'filename',
    'file_name',
    'label',
  ]);
  final explicitDisplayName = _safeDisplayName(rawName);
  final safeName = explicitDisplayName ?? _fallbackDisplayName(kind);
  final rawSize = first(const ['size_bytes', 'byte_size', 'size']);
  final sizeBytes = _sizeBytes(rawSize, policy.maximumSizeBytes);
  final rawReference = first(const [
    'managed_uri',
    'managed_url',
    'download_uri',
    'download_url',
    'managed_path',
    'uri',
    'url',
    'path',
  ]);
  final managedReference = policy.normalizeManagedReference(rawReference);
  final remote = first(const ['remote', 'is_remote']);
  final availability = _availability(
    first(const ['availability', 'artifact_status', 'status']),
  );
  final createdAt = _createdAt(
    first(const ['created_at', 'timestamp', 'created']),
  );
  final hasStructuredMetadata =
      serverId != null ||
      rawName is String ||
      mimeType != null ||
      rawSize != null ||
      rawReference != null;
  if (!hasStructuredMetadata) return null;

  return _ArtifactSeed(
    serverId: serverId,
    kind: kind,
    displayName: safeName,
    hasExplicitDisplayName: explicitDisplayName != null,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    managedReference: managedReference,
    remote: remote is bool ? remote : null,
    availability: availability,
    createdAt: createdAt,
  );
}

SessionArtifactKind? _explicitKind(Map<String, dynamic> map) {
  final raw = map['artifact_type'] ?? map['kind'] ?? map['type'];
  if (raw is! String) return null;
  return switch (raw.trim().toLowerCase().replaceAll('-', '_')) {
    'image' || 'image_url' || 'input_image' => SessionArtifactKind.image,
    'file' || 'attachment' => SessionArtifactKind.file,
    'document' || 'pdf' => SessionArtifactKind.document,
    'generated' || 'generated_image' => SessionArtifactKind.generated,
    'tool_result' => SessionArtifactKind.toolResult,
    'artifact' => SessionArtifactKind.unknown,
    _ => null,
  };
}

SessionArtifactKind _kindFromMime(String mime) {
  if (mime.startsWith('image/')) return SessionArtifactKind.image;
  if (mime.startsWith('text/') ||
      mime == 'application/pdf' ||
      mime.endsWith('+document')) {
    return SessionArtifactKind.document;
  }
  return SessionArtifactKind.file;
}

String? _safeDisplayName(Object? raw) {
  if (raw is String) {
    final withoutControl = raw.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
    final segments = withoutControl.split(RegExp(r'[/\\]+'));
    final leaf = segments.isEmpty ? '' : segments.last.trim();
    if (leaf.isNotEmpty) return _truncateRunes(leaf, 160);
  }
  return null;
}

String _fallbackDisplayName(SessionArtifactKind kind) => switch (kind) {
  SessionArtifactKind.image => 'Image',
  SessionArtifactKind.file => 'File',
  SessionArtifactKind.document => 'Document',
  SessionArtifactKind.generated => 'Generated artifact',
  SessionArtifactKind.toolResult => 'Tool result',
  SessionArtifactKind.unknown => 'Artifact',
};

String? _mimeType(Object? raw) {
  if (raw is! String) return null;
  final value = raw.trim().toLowerCase();
  if (value.length > 127 ||
      !RegExp(
        r"^[a-z0-9!#$&^_.+-]{1,64}/[a-z0-9!#$&^_.+-]{1,64}$",
      ).hasMatch(value)) {
    return null;
  }
  return value;
}

int? _sizeBytes(Object? raw, int maximum) {
  if (raw is! num || !raw.isFinite || raw < 0) return null;
  final value = raw.toInt();
  if (raw != value || value > maximum) return null;
  return value;
}

SessionArtifactAvailability _availability(Object? raw) {
  if (raw is! String) return SessionArtifactAvailability.unknown;
  return switch (raw.trim().toLowerCase()) {
    'ready' || 'available' || 'complete' => SessionArtifactAvailability.ready,
    'missing' || 'not_found' => SessionArtifactAvailability.missing,
    'expired' => SessionArtifactAvailability.expired,
    _ => SessionArtifactAvailability.unknown,
  };
}

DateTime? _createdAt(Object? raw) {
  if (raw is String && raw.length <= 64) {
    return DateTime.tryParse(raw)?.toUtc();
  }
  if (raw is! num || !raw.isFinite || raw < 0) return null;
  try {
    final milliseconds = raw >= 100000000000
        ? raw.round()
        : (raw * 1000).round();
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  } on ArgumentError {
    return null;
  }
}

String _fallbackIdentity(
  ArtifactIndexScope scope,
  SessionArtifactSource source,
  _ArtifactSeed seed,
) {
  final reference = seed.managedReference;
  if (reference != null && Uri.tryParse(reference)?.hasScheme == true) {
    // Una URI administrada identifica el mismo recurso aunque Hermes lo vuelva
    // a proyectar con metadatos más completos desde otro mensaje. Las rutas
    // absolutas son mutables y conservan la fuente dentro de su identidad.
    return [
      scope.connectionId,
      scope.logicalSessionId,
      'managed-reference',
      reference,
    ].map(_lengthPrefixed).join();
  }
  // Sin referencia ni ID de servidor, la fuente evita fusionar adjuntos
  // distintos que solo comparten nombre y metadatos.
  return [
    scope.connectionId,
    scope.logicalSessionId,
    source.rowId != null
        ? 'row:${source.rowId}'
        : source.messageId != null
        ? 'message:${source.messageId}'
        : 'ordinal:${source.messageOrdinal}',
    seed.kind.name,
    reference ?? '',
    seed.mimeType ?? '',
    seed.displayName,
    seed.sizeBytes?.toString() ?? '',
  ].map(_lengthPrefixed).join();
}

String _lengthPrefixed(String value) => '${value.length}:$value';

String _stableFingerprint(String value) {
  var first = 0x811c9dc5;
  var second = 0x9e3779b9;
  for (final byte in utf8.encode(value)) {
    first = ((first ^ byte) * 0x01000193) & 0xffffffff;
    second = ((second ^ byte) * 0x85ebca6b) & 0xffffffff;
  }
  return '${first.toRadixString(16).padLeft(8, '0')}'
      '${second.toRadixString(16).padLeft(8, '0')}';
}

Map<String, dynamic>? _stringMap(Object? raw) {
  if (raw is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in raw.entries) {
    if (entry.key is String) result[entry.key as String] = entry.value;
  }
  return result;
}

String? _stableId(Object? raw) {
  if (raw is! String || !_isStableId(raw)) return null;
  return raw;
}

bool _isStableId(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,255}$').hasMatch(value);

bool _isOpaqueId(String value) =>
    value.trim().isNotEmpty && value.runes.length <= 256 && !_hasControl(value);

bool _hasControl(String value) =>
    value.runes.any((rune) => rune < 0x20 || rune == 0x7f);

String _truncateRunes(String value, int maximum) {
  final runes = value.runes;
  if (runes.length <= maximum) return value;
  return String.fromCharCodes(runes.take(maximum));
}

String? _normalizeAbsolutePath(String raw) {
  final value = raw.trim();
  if (!value.startsWith('/') ||
      value.length > 2048 ||
      _hasControl(value) ||
      value.contains('?') ||
      value.contains('#')) {
    return null;
  }
  final segments = <String>[];
  for (final segment in value.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    late final String decoded;
    try {
      decoded = Uri.decodeComponent(segment);
    } on FormatException {
      return null;
    }
    if (decoded == '..' || decoded.contains('/') || decoded.contains('\\')) {
      return null;
    }
    segments.add(segment);
  }
  return '/${segments.join('/')}';
}

bool _isWithinPrefix(String path, String prefix) =>
    path == prefix ||
    path.startsWith(prefix.endsWith('/') ? prefix : '$prefix/');

bool _containsTraversal(List<String> segments) => segments.any(
  (segment) =>
      segment == '..' || segment.contains('/') || segment.contains('\\'),
);
