// Durable Stop: the tombstone that proves a turn was cancelled, its keyed
// store, and the identity resolution that survives a session id change.
// ignore_for_file: prefer_initializing_formals
part of 'active_chat_service.dart';

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
