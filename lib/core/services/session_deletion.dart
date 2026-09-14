import 'dart:async';
import 'dart:collection';

import '../models/session.dart';

typedef DeleteRemoteSession = Future<bool> Function(String sessionId);
typedef DeleteLinkedCronJob = Future<void> Function(String jobId);
typedef LoadSessionsForDeletion =
    Future<List<Session>> Function({bool includeChildren});
typedef ClearLocalSessionRecovery = Future<void> Function(String sessionId);
typedef ClearConnectionConversationState = Future<int> Function();
typedef ClearProfileConversationState =
    Future<int> Function({required String profile});

class LocalConversationWriteRejected implements Exception {
  const LocalConversationWriteRejected();
}

enum LocalConversationOperationKind {
  save,
  clearExact,
  clearSelector,
  transfer,
  retireOwner,
  projection,
}

/// Structured identity of one irreversible local-storage effect.
final class LocalConversationResourceKey {
  final String connectionId;
  final String profile;
  final String sessionId;
  final String? clientTurnId;
  final String physicalKey;

  const LocalConversationResourceKey({
    required this.connectionId,
    required this.profile,
    required this.sessionId,
    this.clientTurnId,
    required this.physicalKey,
  });

  @override
  bool operator ==(Object other) =>
      other is LocalConversationResourceKey &&
      other.connectionId == connectionId &&
      other.profile == profile &&
      other.sessionId == sessionId &&
      other.clientTurnId == clientTurnId &&
      other.physicalKey == physicalKey;

  @override
  int get hashCode =>
      Object.hash(connectionId, profile, sessionId, clientTurnId, physicalKey);
}

final class _LocalConversationEffectReceipt {
  bool delivered = false;
  bool confirmed = false;
  final Completer<void> settled = Completer<void>();
}

/// Admission token and journal root for one local operation.
final class LocalConversationOperation {
  final String operationId;
  final int admissionSequence;
  final String connectionId;
  final String profile;
  final String sessionId;
  final String? clientTurnId;
  final LocalConversationOperationKind kind;
  final String? _physicalKeyPrefix;
  final LocalConversationLifecycle? _lifecycle;
  final int _admittedEpoch;
  final Set<LocalConversationResourceKey> _resources;
  final Map<LocalConversationResourceKey, _LocalConversationEffectReceipt>
  _effects = {};
  final Completer<void> _settled = Completer<void>();
  bool _superseded = false;

  LocalConversationOperation._({
    required this.operationId,
    required this.admissionSequence,
    required this.connectionId,
    required this.profile,
    required this.sessionId,
    required this.clientTurnId,
    required this.kind,
    this._physicalKeyPrefix,
    required this._lifecycle,
    required this._admittedEpoch,
    required Iterable<LocalConversationResourceKey> resources,
  }) : _resources = Set.unmodifiable(resources);

  bool _selectsResource(LocalConversationResourceKey resource) =>
      resource.connectionId == connectionId &&
      resource.sessionId == sessionId &&
      (_physicalKeyPrefix == null ||
          resource.physicalKey.startsWith(_physicalKeyPrefix));
}

typedef _LocalConversationScope = ({String connectionId, String profile});

final class LocalConversationLifecycle {
  final String connectionId;
  final String profile;
  final String sessionId;
  final Set<String> _sessionAliases;
  final int _epoch;
  bool _acceptingWrites = true;

  LocalConversationLifecycle._({
    required this.connectionId,
    required this.profile,
    required this.sessionId,
    required Set<String> sessionAliases,
    required this._epoch,
  }) : _sessionAliases = Set.of(sessionAliases);

  bool _authorizesSession(String candidate) =>
      candidate == sessionId || _sessionAliases.contains(candidate);
}

final class _LocalConversationScopeState {
  int epoch = 0;
  bool blocked = false;
  int pendingCleanups = 0;
  final Map<String, LocalConversationLifecycle> currentOwners = {};
  final Set<LocalConversationLifecycle> rehydrated = {};
}

final class _LocalCleanupContext {
  final String connectionId;
  final String? profile;
  bool active = true;

  _LocalCleanupContext.profile(this.connectionId, this.profile);

  _LocalCleanupContext.connection(this.connectionId) : profile = null;

  bool coversProfile(String connection, String owner) =>
      active &&
      connectionId == connection &&
      (profile == null || profile == owner);

  bool coversConnection(String connection) =>
      active && connectionId == connection && profile == null;
}

abstract final class LocalConversationCleanupFence {
  static final Map<_LocalConversationScope, _LocalConversationScopeState>
  _states = {};
  static final Set<String> _blockedConnections = {};
  static final Map<String, int> _pendingConnectionCleanups = {};
  static final Queue<Future<void> Function()> _operations = Queue();
  static bool _operationRunning = false;
  static final Object _cleanupZoneKey = Object();
  static int _nextOperationSequence = 0;
  static final List<LocalConversationOperation> _operationJournal = [];
  static final Map<LocalConversationResourceKey, int> _confirmedVersions = {};

  static String _owner(String profile) => profile.isEmpty ? 'default' : profile;

  static _LocalConversationScope _scope(String connectionId, String profile) =>
      (connectionId: connectionId, profile: _owner(profile));

  static _LocalConversationScopeState _stateFor(_LocalConversationScope scope) {
    final state = _states.putIfAbsent(scope, _LocalConversationScopeState.new);
    if (_blockedConnections.contains(scope.connectionId)) state.blocked = true;
    return state;
  }

  static bool _connectionIsCleaning(String connectionId) =>
      (_pendingConnectionCleanups[connectionId] ?? 0) > 0;

  static LocalConversationLifecycle beginLifecycle({
    required String connectionId,
    required String profile,
    required String sessionId,
    Iterable<String> sessionAliases = const [],
  }) {
    final owner = _owner(profile);
    final state = _stateFor(_scope(connectionId, owner));
    final lifecycle = LocalConversationLifecycle._(
      connectionId: connectionId,
      profile: owner,
      sessionId: sessionId,
      sessionAliases: {
        for (final alias in sessionAliases)
          if (alias.isNotEmpty) alias,
      },
      epoch: state.epoch,
    );
    for (final destination in {sessionId, ...lifecycle._sessionAliases}) {
      state.currentOwners[destination] = lifecycle;
    }
    return lifecycle;
  }

  /// Extend an existing producer only after its create RPC proved the new ID.
  /// This does not replace/revive a lifecycle or steal a destination owner.
  static void authorizeCreatedSession(
    LocalConversationLifecycle lifecycle,
    String createdSessionId,
  ) {
    ensureWriteAllowed(
      connectionId: lifecycle.connectionId,
      profile: lifecycle.profile,
      sessionId: lifecycle.sessionId,
      lifecycle: lifecycle,
    );
    final state = _states[_scope(lifecycle.connectionId, lifecycle.profile)]!;
    final owner = state.currentOwners[createdSessionId];
    // A replacement screen may inherit this exact provisional route while its
    // ActiveChat preserves the create receipt. Transfer only from the retired
    // owner of that same provisional identity; never from a live owner or a
    // different route/profile/connection.
    final replaceRetiredSameRoute =
        owner != null &&
        !owner._acceptingWrites &&
        owner.sessionId == lifecycle.sessionId &&
        owner._authorizesSession(createdSessionId);
    if (createdSessionId.isEmpty ||
        (owner != null &&
            !identical(owner, lifecycle) &&
            !replaceRetiredSameRoute)) {
      throw const LocalConversationWriteRejected();
    }
    lifecycle._sessionAliases.add(createdSessionId);
    state.currentOwners[createdSessionId] = lifecycle;
  }

  static void endLifecycle(LocalConversationLifecycle lifecycle) {
    lifecycle._acceptingWrites = false;
  }

  static LocalConversationLifecycle? currentLifecycle({
    required String connectionId,
    required String profile,
    required String sessionId,
  }) {
    final lifecycle =
        _states[_scope(connectionId, profile)]?.currentOwners[sessionId];
    return lifecycle?._acceptingWrites == true ? lifecycle : null;
  }

  static bool rehydrate(LocalConversationLifecycle lifecycle) {
    final state = _states[_scope(lifecycle.connectionId, lifecycle.profile)];
    if (state == null ||
        !lifecycle._acceptingWrites ||
        state.pendingCleanups > 0 ||
        _connectionIsCleaning(lifecycle.connectionId) ||
        state.epoch != lifecycle._epoch ||
        !identical(state.currentOwners[lifecycle.sessionId], lifecycle) ||
        lifecycle.sessionId.trim().isEmpty) {
      return false;
    }
    state.rehydrated.add(lifecycle);
    return true;
  }

  static void ensureWriteAllowed({
    required String connectionId,
    required String profile,
    required String sessionId,
    required LocalConversationLifecycle lifecycle,
  }) {
    final owner = _owner(profile);
    final scope = _scope(connectionId, owner);
    final state = _states[scope];
    if (connectionId != lifecycle.connectionId ||
        owner != lifecycle.profile ||
        !lifecycle._authorizesSession(sessionId) ||
        !lifecycle._acceptingWrites ||
        state == null ||
        state.pendingCleanups != 0 ||
        _connectionIsCleaning(connectionId) ||
        state.epoch != lifecycle._epoch ||
        !identical(state.currentOwners[sessionId], lifecycle) ||
        (state.blocked && !state.rehydrated.contains(lifecycle)) ||
        (_blockedConnections.contains(connectionId) &&
            !state.rehydrated.contains(lifecycle))) {
      throw const LocalConversationWriteRejected();
    }
  }

  static LocalConversationOperation admitOperation({
    required String connectionId,
    required String profile,
    required String sessionId,
    String? clientTurnId,
    LocalConversationLifecycle? lifecycle,
    required LocalConversationOperationKind kind,
    Iterable<LocalConversationResourceKey> resources = const [],
  }) {
    final owner = _owner(profile);
    final state = _stateFor(_scope(connectionId, owner));
    if (lifecycle != null) {
      ensureWriteAllowed(
        connectionId: connectionId,
        profile: owner,
        sessionId: sessionId,
        lifecycle: lifecycle,
      );
    } else if (state.pendingCleanups != 0 ||
        _connectionIsCleaning(connectionId) ||
        state.blocked ||
        _blockedConnections.contains(connectionId)) {
      throw const LocalConversationWriteRejected();
    }
    final sequence = ++_nextOperationSequence;
    final operation = LocalConversationOperation._(
      operationId: 'local-operation-$sequence',
      admissionSequence: sequence,
      connectionId: connectionId,
      profile: owner,
      sessionId: sessionId,
      clientTurnId: clientTurnId,
      kind: kind,
      lifecycle: lifecycle,
      admittedEpoch: lifecycle?._epoch ?? state.epoch,
      resources: resources,
    );
    _operationJournal.add(operation);
    return operation;
  }

  static LocalConversationOperation admitSessionClear({
    required String connectionId,
    required String sessionId,
    String? physicalKeyPrefix,
  }) {
    final sequence = ++_nextOperationSequence;
    final clear = LocalConversationOperation._(
      operationId: 'local-operation-$sequence',
      admissionSequence: sequence,
      connectionId: connectionId,
      profile: '',
      sessionId: sessionId,
      clientTurnId: null,
      kind: LocalConversationOperationKind.clearSelector,
      physicalKeyPrefix: physicalKeyPrefix,
      lifecycle: null,
      admittedEpoch: 0,
      resources: const [],
    );
    _operationJournal.add(clear);
    for (final operation in _operationJournal) {
      if (identical(operation, clear) ||
          operation.admissionSequence >= sequence ||
          operation.connectionId != connectionId ||
          operation.sessionId != sessionId ||
          (physicalKeyPrefix != null &&
              !operation._resources.any(clear._selectsResource)) ||
          operation.kind != LocalConversationOperationKind.save) {
        continue;
      }
      if (!operation._effects.values.any((effect) => effect.delivered)) {
        operation._superseded = true;
      }
    }
    return clear;
  }

  /// Retained confirmed content can outlive its producer, but not a cleanup.
  /// This is a projection predicate, never permission to deliver a new effect.
  static bool confirmedProjectionSurvivesCleanup(
    LocalConversationOperation operation,
  ) {
    final state = _states[_scope(operation.connectionId, operation.profile)];
    return state != null &&
        state.epoch == operation._admittedEpoch &&
        state.pendingCleanups == 0 &&
        !_connectionIsCleaning(operation.connectionId);
  }

  /// Whether cleanup advanced the operation's scope after admission. Lifecycle
  /// retirement alone is deliberately not a cleanup and must not erase a
  /// physical effect that was already handed to storage.
  static bool wasInvalidatedByCleanup(LocalConversationOperation operation) {
    final state = _states[_scope(operation.connectionId, operation.profile)];
    return state != null && state.epoch != operation._admittedEpoch;
  }

  static void ensureOperationAllowed(LocalConversationOperation operation) {
    if (operation._lifecycle == null &&
        (operation.kind == LocalConversationOperationKind.clearSelector ||
            operation.kind == LocalConversationOperationKind.clearExact)) {
      return;
    }
    final state = _states[_scope(operation.connectionId, operation.profile)];
    final lifecycle = operation._lifecycle;
    if (state == null ||
        state.pendingCleanups != 0 ||
        _connectionIsCleaning(operation.connectionId) ||
        state.epoch != operation._admittedEpoch ||
        (state.blocked &&
            (lifecycle == null || !state.rehydrated.contains(lifecycle))) ||
        (_blockedConnections.contains(operation.connectionId) &&
            (lifecycle == null || !state.rehydrated.contains(lifecycle)))) {
      throw const LocalConversationWriteRejected();
    }
    if (lifecycle != null) {
      ensureWriteAllowed(
        connectionId: operation.connectionId,
        profile: operation.profile,
        sessionId: operation.sessionId,
        lifecycle: lifecycle,
      );
    }
  }

  /// Final authorization and handoff share one synchronous turn.
  static Future<bool> commitEffect({
    required LocalConversationOperation operation,
    required LocalConversationResourceKey resource,
    required Future<void> Function() mutation,
  }) async {
    ensureOperationAllowed(operation);
    if (operation._superseded) return false;
    if (!operation._selectsResource(resource) ||
        (operation.kind != LocalConversationOperationKind.clearSelector &&
            (resource.profile != operation.profile ||
                resource.clientTurnId != operation.clientTurnId))) {
      throw const LocalConversationWriteRejected();
    }
    if (operation._resources.isNotEmpty &&
        !operation._resources.contains(resource)) {
      throw StateError('Effect is outside the admitted write-set');
    }
    final receipt = operation._effects.putIfAbsent(
      resource,
      _LocalConversationEffectReceipt.new,
    );
    if (receipt.delivered) {
      throw StateError('Local conversation effect was already delivered');
    }
    receipt.delivered = true;
    try {
      await mutation();
      receipt.confirmed = true;
      _confirmedVersions[resource] = operation.admissionSequence;
      return true;
    } finally {
      if (!receipt.settled.isCompleted) receipt.settled.complete();
    }
  }

  static Future<void> settleDeliveredEffectsBefore(
    LocalConversationOperation clear,
  ) async {
    final pending = <Future<void>>[];
    for (final operation in _operationJournal) {
      if (operation.admissionSequence >= clear.admissionSequence ||
          operation.connectionId != clear.connectionId ||
          operation.sessionId != clear.sessionId) {
        continue;
      }
      for (final entry in operation._effects.entries) {
        if (!clear._selectsResource(entry.key)) continue;
        final effect = entry.value;
        if (effect.delivered && !effect.settled.isCompleted) {
          pending.add(effect.settled.future);
        }
      }
    }
    if (pending.isNotEmpty) await Future.wait(pending);
  }

  static Iterable<LocalConversationResourceKey> resourcesBefore(
    LocalConversationOperation clear,
  ) sync* {
    for (final operation in _operationJournal) {
      if (operation.admissionSequence >= clear.admissionSequence ||
          operation.connectionId != clear.connectionId ||
          operation.sessionId != clear.sessionId) {
        continue;
      }
      yield* operation._resources.where(clear._selectsResource);
    }
  }

  static bool hasConfirmedCommitAfter(
    LocalConversationResourceKey resource,
    int cutoff,
  ) => (_confirmedVersions[resource] ?? 0) > cutoff;

  static void completeOperation(LocalConversationOperation operation) {
    if (!operation._settled.isCompleted) operation._settled.complete();
  }

  static Future<void> waitForSessionClears({
    required String connectionId,
    required String sessionId,
  }) async {
    final pending = _operationJournal
        .where(
          (operation) =>
              operation.kind == LocalConversationOperationKind.clearSelector &&
              operation.connectionId == connectionId &&
              operation.sessionId == sessionId &&
              !operation._settled.isCompleted,
        )
        .map((operation) => operation._settled.future)
        .toList(growable: false);
    if (pending.isNotEmpty) await Future.wait(pending);
  }

  static Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operations.add(() async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _drain();
    return completer.future;
  }

  static void _drain() {
    if (_operationRunning || _operations.isEmpty) return;
    _operationRunning = true;
    final operation = _operations.removeFirst();
    Future<void>.sync(operation).whenComplete(() {
      _operationRunning = false;
      _drain();
    });
  }

  static Future<T> write<T>({
    String? connectionId,
    String? profile,
    String? sessionId,
    LocalConversationLifecycle? lifecycle,
    LocalConversationOperation? admittedOperation,
    required Future<T> Function() operation,
  }) {
    final connection = connectionId ?? lifecycle?.connectionId ?? '';
    final owner = _owner(profile ?? lifecycle?.profile ?? '');
    final session = sessionId ?? lifecycle?.sessionId ?? '';
    if (lifecycle != null &&
        ((connectionId != null && connection != lifecycle.connectionId) ||
            (profile != null && owner != lifecycle.profile) ||
            (sessionId != null && !lifecycle._authorizesSession(session)))) {
      return Future<T>.error(const LocalConversationWriteRejected());
    }
    final scope = _scope(connection, owner);
    final state = _stateFor(scope);
    final admittedEpoch = lifecycle?._epoch ?? state.epoch;
    bool ownerIsValid(_LocalConversationScopeState candidate) =>
        lifecycle == null ||
        identical(candidate.currentOwners[session], lifecycle);
    bool cleanupIsInactive(_LocalConversationScopeState candidate) =>
        candidate.pendingCleanups == 0 && !_connectionIsCleaning(connection);
    bool blockedWriteIsAuthorized(_LocalConversationScopeState candidate) =>
        (!candidate.blocked && !_blockedConnections.contains(connection)) ||
        (lifecycle != null && candidate.rehydrated.contains(lifecycle));
    bool lifecycleIsActive() => lifecycle?._acceptingWrites != false;
    if (!lifecycleIsActive() ||
        !cleanupIsInactive(state) ||
        state.epoch != admittedEpoch ||
        !ownerIsValid(state) ||
        !blockedWriteIsAuthorized(state)) {
      return Future<T>.error(const LocalConversationWriteRejected());
    }
    late final LocalConversationOperation journalOperation;
    try {
      journalOperation =
          admittedOperation ??
          admitOperation(
            connectionId: connection,
            profile: owner,
            sessionId: session,
            lifecycle: lifecycle,
            kind: LocalConversationOperationKind.save,
          );
    } catch (error, stackTrace) {
      return Future<T>.error(error, stackTrace);
    }
    return _enqueue(() {
      final current = _states[scope];
      if (current == null ||
          !lifecycleIsActive() ||
          !cleanupIsInactive(current) ||
          current.epoch != admittedEpoch ||
          !ownerIsValid(current) ||
          !blockedWriteIsAuthorized(current)) {
        throw const LocalConversationWriteRejected();
      }
      ensureOperationAllowed(journalOperation);
      return operation();
    });
  }

  static _LocalCleanupContext? get _cleanupContext =>
      Zone.current[_cleanupZoneKey] as _LocalCleanupContext?;

  static Future<T>? _nestedProfileCleanup<T>({
    required String connectionId,
    required String profile,
    required Future<T> Function() operation,
  }) {
    final context = _cleanupContext;
    if (context == null || !context.active) return null;
    if (context.coversProfile(connectionId, profile)) return operation();
    return Future<T>.error(
      StateError('Nested cleanup scope is not covered by its parent'),
    );
  }

  static Future<T> cleanupProfile<T>({
    required String connectionId,
    required String profile,
    required Future<T> Function() operation,
  }) {
    final owner = _owner(profile);
    final nested = _nestedProfileCleanup(
      connectionId: connectionId,
      profile: owner,
      operation: operation,
    );
    if (nested != null) return nested;
    final state = _stateFor(_scope(connectionId, owner));
    state.epoch++;
    state
      ..blocked = true
      ..rehydrated.clear();
    state.pendingCleanups++;
    final context = _LocalCleanupContext.profile(connectionId, owner);
    return _enqueue(() async {
      try {
        return await runZoned(
          operation,
          zoneValues: {_cleanupZoneKey: context},
        );
      } finally {
        context.active = false;
        state.pendingCleanups--;
        if (state.pendingCleanups == 0 &&
            !_connectionIsCleaning(connectionId) &&
            state.currentOwners.isEmpty) {
          state.blocked = false;
        }
      }
    });
  }

  static Future<T> cleanupConnection<T>({
    required String connectionId,
    required Future<T> Function() operation,
  }) {
    final parent = _cleanupContext;
    if (parent != null && parent.active) {
      if (parent.coversConnection(connectionId)) return operation();
      return Future<T>.error(
        StateError('Nested cleanup scope is not covered by its parent'),
      );
    }
    _blockedConnections.add(connectionId);
    _pendingConnectionCleanups.update(
      connectionId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    for (final entry in _states.entries.where(
      (entry) => entry.key.connectionId == connectionId,
    )) {
      entry.value.epoch++;
      entry.value
        ..blocked = true
        ..rehydrated.clear();
    }
    final context = _LocalCleanupContext.connection(connectionId);
    return _enqueue(() async {
      try {
        return await runZoned(
          operation,
          zoneValues: {_cleanupZoneKey: context},
        );
      } finally {
        context.active = false;
        final remaining = _pendingConnectionCleanups[connectionId]! - 1;
        if (remaining == 0) {
          _pendingConnectionCleanups.remove(connectionId);
          final connectionStates = _states.entries
              .where((entry) => entry.key.connectionId == connectionId)
              .map((entry) => entry.value)
              .toList(growable: false);
          if (connectionStates.every(
            (state) =>
                state.pendingCleanups == 0 && state.currentOwners.isEmpty,
          )) {
            _blockedConnections.remove(connectionId);
            for (final state in connectionStates) {
              state.blocked = false;
            }
          }
        } else {
          _pendingConnectionCleanups[connectionId] = remaining;
        }
      }
    });
  }

  static void resetForTesting() {
    _states.clear();
    _blockedConnections.clear();
    _pendingConnectionCleanups.clear();
    _operations.clear();
    _operationRunning = false;
    _nextOperationSequence = 0;
    _operationJournal.clear();
    _confirmedVersions.clear();
  }
}

enum HistoryCleanupScope { normalConversations }

class HistoryCleanupInvalidation {
  final String connectionId;
  final HistoryCleanupScope scope;

  const HistoryCleanupInvalidation({
    required this.connectionId,
    required this.scope,
  });
}

/// Señal local y estrecha para refrescar las proyecciones de historial cuando
/// el backend no publica `sessions.changed` después de una limpieza.
///
/// No transporta contenido ni IDs de sesiones: los consumidores vuelven a
/// consultar su autoridad para la conexión afectada.
class HistoryCleanupInvalidationBus {
  final StreamController<HistoryCleanupInvalidation> _controller =
      StreamController<HistoryCleanupInvalidation>.broadcast(sync: true);

  Stream<HistoryCleanupInvalidation> get events => _controller.stream;

  void publish({
    required String connectionId,
    required HistoryCleanupScope scope,
  }) {
    final normalized = connectionId.trim();
    if (normalized.isEmpty || _controller.isClosed) return;
    _controller.add(
      HistoryCleanupInvalidation(connectionId: normalized, scope: scope),
    );
  }

  Future<void> close() => _controller.close();
}

final HistoryCleanupInvalidationBus historyCleanupInvalidations =
    HistoryCleanupInvalidationBus();

/// Gate de Settings. Solo lectura falla antes de invocar App Lock; un error del
/// verificador también falla cerrado.
Future<bool> authorizeHistoryCleanup({
  required bool readOnly,
  required Future<bool> Function() verifyAppLock,
}) async {
  if (readOnly) return false;
  try {
    return await verifyAppLock();
  } catch (_) {
    return false;
  }
}

/// Decide si al borrar un informe programado se conserva o se elimina también
/// su tarea. El valor seguro es [keepSchedule]: borrar una conversación nunca
/// debe detener futuras ejecuciones sin una elección explícita del usuario.
enum LinkedCronDeletionMode { keepSchedule, deleteSchedule }

/// Identidades y linaje resueltos una sola vez antes de borrar. El ID que usa
/// el servidor puede diferir de la clave local con la que Chat guardó su
/// draft/outbox; mantenerlos separados evita limpiar el chat equivocado.
class SessionDeletionContext {
  final Session selected;
  final Session target;
  final List<Session> lineage;
  final String remoteSessionId;
  final String localRecoverySessionId;

  const SessionDeletionContext({
    required this.selected,
    required this.target,
    required this.lineage,
    required this.remoteSessionId,
    required this.localRecoverySessionId,
  });
}

/// Resuelve la raíz de una cadena padre/hija. Las compactaciones de Hermes
/// conservan `source: cron`, pero solo la raíz mantiene el ID `cron_<job>_...`.
Session sessionLineageRoot(Session selected, Iterable<Session> sessions) {
  final byId = {for (final session in sessions) session.id: session};
  var current = byId[selected.id] ?? selected;
  final visited = <String>{};
  while (visited.add(current.id)) {
    final parentId = current.parentSessionId;
    if (parentId == null || parentId.isEmpty) break;
    final parent = byId[parentId];
    if (parent == null) break;
    current = parent;
  }
  return current;
}

/// Obtiene el contexto autoritativo para cualquier superficie de borrado.
/// Solo las sesiones cron necesitan refetch, pero cuando lo hacen el helper
/// fuerza `includeChildren` para no dejar continuaciones huérfanas.
Future<SessionDeletionContext> resolveSessionDeletionContext(
  Session selected, {
  required LoadSessionsForDeletion loadSessions,
  String? remoteSessionId,
  String? localRecoverySessionId,
}) async {
  var target = selected;
  List<Session> lineage = const <Session>[];
  if (selected.isJob) {
    lineage = List<Session>.unmodifiable(
      await loadSessions(includeChildren: true),
    );
    target = sessionLineageRoot(selected, lineage);
  }
  final remote = selected.isJob
      ? target.id
      : _nonEmptyOr(remoteSessionId, selected.id);
  return SessionDeletionContext(
    selected: selected,
    target: target,
    lineage: lineage,
    remoteSessionId: remote,
    localRecoverySessionId: _nonEmptyOr(localRecoverySessionId, selected.id),
  );
}

String _nonEmptyOr(String? value, String fallback) {
  final clean = value?.trim() ?? '';
  return clean.isEmpty ? fallback : clean;
}

/// IDs de una cadena completa en orden seguro de borrado: hojas primero y raíz
/// al final. Así cada DELETE no convierte a la siguiente continuación en una
/// nueva sesión principal que "reaparece" en la lista.
List<String> sessionLineageDeleteOrder(
  String rootId,
  Iterable<Session> sessions,
) {
  final children = <String, List<String>>{};
  for (final session in sessions) {
    final parentId = session.parentSessionId;
    if (parentId == null || parentId.isEmpty) continue;
    children.putIfAbsent(parentId, () => <String>[]).add(session.id);
  }

  final order = <String>[];
  final visited = <String>{};
  void visit(String id) {
    if (!visited.add(id)) return;
    for (final childId in children[id] ?? const <String>[]) {
      visit(childId);
    }
    order.add(id);
  }

  visit(rootId);
  return order;
}

enum RemoteSessionDeleteStatus { deleted, rejected, failed }

class RemoteSessionDeleteResult {
  final RemoteSessionDeleteStatus status;
  final Object? error;

  const RemoteSessionDeleteResult._(this.status, [this.error]);

  const RemoteSessionDeleteResult.deleted()
    : this._(RemoteSessionDeleteStatus.deleted);

  const RemoteSessionDeleteResult.rejected()
    : this._(RemoteSessionDeleteStatus.rejected);

  const RemoteSessionDeleteResult.failed(Object error)
    : this._(RemoteSessionDeleteStatus.failed, error);
}

Future<RemoteSessionDeleteResult> deleteRemoteSession(
  String sessionId, {
  required DeleteRemoteSession delete,
}) async {
  try {
    final deleted = await delete(sessionId);
    return deleted
        ? const RemoteSessionDeleteResult.deleted()
        : const RemoteSessionDeleteResult.rejected();
  } catch (error) {
    return RemoteSessionDeleteResult.failed(error);
  }
}

/// Finaliza un borrado ya confirmado por el servidor. La expulsión autoritativa
/// ocurre antes de cualquier limpieza local y cada limpieza es independiente:
/// un fallo de preferencias/Keystore no puede resucitar la fila ni impedir las
/// demás tareas locales.
Future<void> finalizeConfirmedRemoteDeletion({
  required void Function() evict,
  required Iterable<Future<void> Function()> localCleanups,
  void Function(Object error)? onCleanupError,
}) async {
  evict();
  for (final cleanup in localCleanups) {
    try {
      await cleanup();
    } catch (error) {
      onCleanupError?.call(error);
    }
  }
}

/// Resultado de limpiar una fuente local cifrada. El error se conserva para
/// diagnóstico interno, pero la UI solo presenta el número de fuentes que no
/// se pudieron limpiar y nunca serializa la excepción del Keystore.
class LocalConversationClearResult {
  final int removed;
  final Object? error;

  const LocalConversationClearResult({required this.removed, this.error});

  bool get succeeded => error == null;
}

class LocalConversationClearSummary {
  final LocalConversationClearResult drafts;
  final LocalConversationClearResult transcripts;
  final LocalConversationClearResult outbox;

  const LocalConversationClearSummary({
    required this.drafts,
    required this.transcripts,
    required this.outbox,
  });

  int get localFailureCount =>
      [drafts, transcripts, outbox].where((result) => !result.succeeded).length;

  bool get hasChanges =>
      drafts.removed > 0 || transcripts.removed > 0 || outbox.removed > 0;

  bool get allSucceeded => localFailureCount == 0;
}

Future<LocalConversationClearResult> _clearLocalConversationState(
  ClearConnectionConversationState clear,
) async {
  try {
    return LocalConversationClearResult(removed: await clear());
  } catch (error) {
    return LocalConversationClearResult(removed: 0, error: error);
  }
}

Future<LocalConversationClearSummary> clearProfileLocalConversationState({
  required String connectionId,
  required String profile,
  required ClearProfileConversationState clearDrafts,
  required ClearProfileConversationState clearTranscripts,
  required ClearProfileConversationState clearOutbox,
  Future<void> Function({
    required String connectionId,
    required String profile,
  })?
  clearGlobalActivity,
}) async {
  final ownerProfile = Session.profileOwner(profile);
  return LocalConversationCleanupFence.cleanupProfile(
    connectionId: connectionId,
    profile: ownerProfile,
    operation: () async {
      final drafts = await _clearLocalConversationState(
        () => clearDrafts(profile: ownerProfile),
      );
      final transcripts = await _clearLocalConversationState(
        () => clearTranscripts(profile: ownerProfile),
      );
      final outbox = await _clearLocalConversationState(
        () => clearOutbox(profile: ownerProfile),
      );
      if (clearGlobalActivity != null) {
        await clearGlobalActivity(
          connectionId: connectionId,
          profile: ownerProfile,
        );
      }
      return LocalConversationClearSummary(
        drafts: drafts,
        transcripts: transcripts,
        outbox: outbox,
      );
    },
  );
}

enum LinkedSessionDeleteStatus {
  deleted,
  cancelled,
  sessionRejected,
  cronDeleteFailed,
  sessionDeleteFailed,
}

/// Razón estable de un fallo de borrado. La capa de servicio conserva la causa
/// técnica únicamente para diagnóstico; las pantallas presentan el código con
/// ARB y nunca exponen `StateError.toString()` ni copy dependiente del idioma.
enum SessionDeletionFailureCode {
  lineageUnavailable('session_lineage_unavailable'),
  missingCronJobId('missing_cron_job_id'),
  cronManagerUnavailable('cron_manager_unavailable'),
  cronDeleteFailed('cron_delete_failed'),
  sessionDeleteFailed('session_delete_failed');

  const SessionDeletionFailureCode(this.stableCode);

  final String stableCode;
}

class SessionDeletionFailure {
  final SessionDeletionFailureCode code;
  final Object? cause;

  const SessionDeletionFailure(this.code, {this.cause});
}

class LinkedSessionDeleteResult {
  final LinkedSessionDeleteStatus status;
  final bool cronDeleted;
  final SessionDeletionFailure? failure;

  const LinkedSessionDeleteResult._(
    this.status, {
    required this.cronDeleted,
    this.failure,
  });

  const LinkedSessionDeleteResult.deleted({required bool cronDeleted})
    : this._(LinkedSessionDeleteStatus.deleted, cronDeleted: cronDeleted);

  const LinkedSessionDeleteResult.cancelled()
    : this._(LinkedSessionDeleteStatus.cancelled, cronDeleted: false);

  const LinkedSessionDeleteResult.sessionRejected({required bool cronDeleted})
    : this._(
        LinkedSessionDeleteStatus.sessionRejected,
        cronDeleted: cronDeleted,
      );

  LinkedSessionDeleteResult.cronDeleteFailed(
    SessionDeletionFailureCode code, {
    Object? cause,
  }) : this._(
         LinkedSessionDeleteStatus.cronDeleteFailed,
         cronDeleted: false,
         failure: SessionDeletionFailure(code, cause: cause),
       );

  LinkedSessionDeleteResult.sessionDeleteFailed(
    SessionDeletionFailureCode code, {
    required bool cronDeleted,
    Object? cause,
  }) : this._(
         LinkedSessionDeleteStatus.sessionDeleteFailed,
         cronDeleted: cronDeleted,
         failure: SessionDeletionFailure(code, cause: cause),
       );
}

/// Flujo compartido por Home, Lista, Detalle y Chat. Resuelve el linaje, trata
/// un fallo de red como resultado (nunca como Future rechazado de un widget),
/// ofrece una salida honesta para cron legacy y limpia la recuperación local
/// únicamente después de que todos los DELETE remotos hayan sido confirmados.
Future<LinkedSessionDeleteResult> deleteSessionWithResolvedLineage(
  Session selected, {
  required LoadSessionsForDeletion loadSessions,
  required DeleteRemoteSession deleteSession,
  LinkedCronDeletionMode cronDeletion = LinkedCronDeletionMode.keepSchedule,
  DeleteLinkedCronJob? deleteCronJob,
  String? remoteSessionId,
  String? localRecoverySessionId,
  ClearLocalSessionRecovery? clearLocalRecovery,
}) async {
  late final SessionDeletionContext context;
  try {
    context = await resolveSessionDeletionContext(
      selected,
      loadSessions: loadSessions,
      remoteSessionId: remoteSessionId,
      localRecoverySessionId: localRecoverySessionId,
    );
  } catch (error) {
    return LinkedSessionDeleteResult.sessionDeleteFailed(
      SessionDeletionFailureCode.lineageUnavailable,
      cronDeleted: false,
      cause: error,
    );
  }

  final result = await deleteSessionWithLinkedCron(
    context.target,
    deleteSession: deleteSession,
    deleteCronJob: deleteCronJob,
    lineage: context.lineage,
    remoteSessionId: context.remoteSessionId,
    cronDeletion: cronDeletion,
  );
  if (result.status == LinkedSessionDeleteStatus.deleted &&
      clearLocalRecovery != null) {
    try {
      await clearLocalRecovery(context.localRecoverySessionId);
    } catch (_) {
      // El servidor ya confirmó el borrado. La limpieza local es best-effort y
      // no debe convertir un éxito remoto irreversible en un falso error.
    }
  }
  return result;
}

/// Borra una conversación y conserva por defecto cualquier cron vinculado. Si
/// el usuario eligió eliminar también la programación, elimina primero el job.
/// Ese orden evita afirmar que el cron se detuvo cuando el servidor lo rechazó.
Future<LinkedSessionDeleteResult> deleteSessionWithLinkedCron(
  Session session, {
  required DeleteRemoteSession deleteSession,
  LinkedCronDeletionMode cronDeletion = LinkedCronDeletionMode.keepSchedule,
  DeleteLinkedCronJob? deleteCronJob,
  Iterable<Session> lineage = const <Session>[],
  String? remoteSessionId,
}) async {
  var cronDeleted = false;
  if (session.isJob) {
    if (cronDeletion == LinkedCronDeletionMode.deleteSchedule) {
      final jobId = session.cronJobId;
      if (jobId == null) {
        return LinkedSessionDeleteResult.cronDeleteFailed(
          SessionDeletionFailureCode.missingCronJobId,
        );
      } else if (deleteCronJob == null) {
        return LinkedSessionDeleteResult.cronDeleteFailed(
          SessionDeletionFailureCode.cronManagerUnavailable,
        );
      } else {
        try {
          await deleteCronJob(jobId);
          cronDeleted = true;
        } catch (error) {
          return LinkedSessionDeleteResult.cronDeleteFailed(
            SessionDeletionFailureCode.cronDeleteFailed,
            cause: error,
          );
        }
      }
    }

    // Quitar el schedule evita nuevas ejecuciones, pero Hermes no cancela el
    // agente cron que ya esté escribiendo. Borrar su fila mientras sigue vivo
    // provoca un FK al persistir el siguiente mensaje y la sesión reaparece.
    // La conversación se podrá borrar con un segundo intento al terminar.
    if (session.state == SessionState.active) {
      return LinkedSessionDeleteResult.sessionRejected(
        cronDeleted: cronDeleted,
      );
    }
  }

  final deleteOrder = session.isJob
      ? sessionLineageDeleteOrder(session.id, lineage)
      : <String>[_nonEmptyOr(remoteSessionId, session.id)];
  for (final sessionId in deleteOrder) {
    final sessionResult = await deleteRemoteSession(
      sessionId,
      delete: deleteSession,
    );
    switch (sessionResult.status) {
      case RemoteSessionDeleteStatus.deleted:
        continue;
      case RemoteSessionDeleteStatus.rejected:
        return LinkedSessionDeleteResult.sessionRejected(
          cronDeleted: cronDeleted,
        );
      case RemoteSessionDeleteStatus.failed:
        return LinkedSessionDeleteResult.sessionDeleteFailed(
          SessionDeletionFailureCode.sessionDeleteFailed,
          cronDeleted: cronDeleted,
          cause: sessionResult.error,
        );
    }
  }
  return LinkedSessionDeleteResult.deleted(cronDeleted: cronDeleted);
}
