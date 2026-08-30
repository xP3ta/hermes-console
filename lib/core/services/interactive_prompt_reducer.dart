import '../models/interactive_prompt.dart';

/// One parked request or terminal tombstone.
///
/// A tombstone has no [request] when a lifecycle event arrived before the
/// request payload. Keeping it prevents a delayed request from reopening an
/// already completed/cancelled/expired prompt.
final class InteractivePromptEntry {
  final InteractivePromptKey key;
  final InteractivePromptRequest? request;
  final InteractivePromptStatus status;

  const InteractivePromptEntry({
    required this.key,
    required this.request,
    required this.status,
  });

  bool get isTerminal => status.isTerminal;
  bool get needsInput => !isTerminal;

  InteractivePromptEntry withRequest(InteractivePromptRequest value) =>
      InteractivePromptEntry(key: key, request: value, status: status);

  InteractivePromptEntry withStatus(InteractivePromptStatus value) =>
      InteractivePromptEntry(key: key, request: request, status: value);

  @override
  String toString() =>
      'InteractivePromptEntry(key: $key, kind: ${request?.kind.name}, '
      'status: ${status.name})';
}

/// Immutable in-memory state for all live runtime prompts.
final class InteractivePromptState {
  final Map<InteractivePromptKey, InteractivePromptEntry> _entries;
  final bool isDisposed;

  const InteractivePromptState.empty()
    : _entries = const {},
      isDisposed = false;

  const InteractivePromptState.disposed()
    : _entries = const {},
      isDisposed = true;

  InteractivePromptState._(
    Map<InteractivePromptKey, InteractivePromptEntry> entries,
  ) : _entries = Map.unmodifiable(entries),
      isDisposed = false;

  Map<InteractivePromptKey, InteractivePromptEntry> get entries => _entries;

  InteractivePromptEntry? operator [](InteractivePromptKey key) =>
      _entries[key];

  Iterable<InteractivePromptEntry> forRuntime(String runtimeSessionId) =>
      _entries.values.where(
        (entry) => entry.key.runtimeSessionId == runtimeSessionId,
      );

  Iterable<InteractivePromptEntry> get blocking =>
      _entries.values.where((entry) => entry.needsInput);

  @override
  String toString() =>
      'InteractivePromptState(entries: ${_entries.length}, '
      'disposed: $isDisposed)';
}

sealed class InteractivePromptEvent {
  const InteractivePromptEvent();
}

final class InteractivePromptReceived extends InteractivePromptEvent {
  final InteractivePromptRequest request;

  const InteractivePromptReceived(this.request);
}

/// A recognized request field that could not be parsed safely.
final class InteractivePromptMalformedReceived extends InteractivePromptEvent {
  final InteractivePromptParseFailure failure;

  const InteractivePromptMalformedReceived(this.failure);
}

/// Authoritative request state read from a fresh `session.resume` snapshot.
///
/// Unlike a duplicate socket event, this may safely release an ambiguous
/// response back to pending after reconciling confirmed progress.
final class InteractivePromptSnapshotReconciled extends InteractivePromptEvent {
  final ClarifyPromptRequest request;
  final bool unlockResponding;

  const InteractivePromptSnapshotReconciled(
    this.request, {
    this.unlockResponding = false,
  });
}

/// An authoritative snapshot explicitly reported no pending clarify request.
final class InteractivePromptClarifySnapshotCleared
    extends InteractivePromptEvent {
  final String runtimeSessionId;

  const InteractivePromptClarifySnapshotCleared(this.runtimeSessionId);
}

final class InteractivePromptResponseStarted extends InteractivePromptEvent {
  final InteractivePromptKey key;

  const InteractivePromptResponseStarted(this.key);
}

final class InteractivePromptResponded extends InteractivePromptEvent {
  final InteractivePromptKey key;

  const InteractivePromptResponded(this.key);
}

/// A response failed before an authoritative terminal outcome was known.
///
/// No value is retained here. Returning to pending only permits a fresh,
/// explicit user entry; callers must never retry a sensitive value.
final class InteractivePromptResponseFailed extends InteractivePromptEvent {
  final InteractivePromptKey key;

  const InteractivePromptResponseFailed(this.key);
}

final class InteractivePromptCancelled extends InteractivePromptEvent {
  final InteractivePromptKey key;

  const InteractivePromptCancelled(this.key);
}

final class InteractivePromptExpired extends InteractivePromptEvent {
  final InteractivePromptKey key;

  const InteractivePromptExpired(this.key);
}

/// Expires every non-terminal prompt owned by a disconnected runtime.
final class InteractivePromptRuntimeExpired extends InteractivePromptEvent {
  final String runtimeSessionId;

  const InteractivePromptRuntimeExpired(this.runtimeSessionId);
}

/// Permanently closes the reducer. Later socket events are ignored.
final class InteractivePromptDisposed extends InteractivePromptEvent {
  const InteractivePromptDisposed();
}

/// Records that one batch question was accepted by the gateway.
///
/// This keeps confirmed progress monotonic so a retry or replay never
/// duplicates an already-consumed answer.
final class InteractivePromptBatchProgressConfirmed
    extends InteractivePromptEvent {
  final InteractivePromptKey key;
  final String qid;
  final String answer;

  const InteractivePromptBatchProgressConfirmed(
    this.key,
    this.qid,
    this.answer,
  );
}

/// Pure state machine for Hermes Desktop blocking requests.
///
/// Terminal states are absorbing. All transitions are keyed by both runtime
/// and request ID, and duplicate events return the original state instance.
abstract final class InteractivePromptReducer {
  static InteractivePromptState reduce(
    InteractivePromptState state,
    InteractivePromptEvent event,
  ) {
    if (state.isDisposed) return state;

    return switch (event) {
      InteractivePromptReceived(:final request) => _receive(state, request),
      InteractivePromptMalformedReceived(:final failure) =>
        _failClosedMalformed(state, failure),
      InteractivePromptSnapshotReconciled(
        :final request,
        :final unlockResponding,
      ) =>
        _reconcileSnapshot(state, request, unlockResponding: unlockResponding),
      InteractivePromptClarifySnapshotCleared(:final runtimeSessionId) =>
        _expireClarifies(state, runtimeSessionId),
      InteractivePromptResponseStarted(:final key) => _transition(
        state,
        key,
        InteractivePromptStatus.responding,
      ),
      InteractivePromptBatchProgressConfirmed(
        :final key,
        :final qid,
        :final answer,
      ) =>
        _confirmBatchProgress(state, key, qid, answer),
      InteractivePromptResponded(:final key) => _transition(
        state,
        key,
        InteractivePromptStatus.responded,
      ),
      InteractivePromptResponseFailed(:final key) => _responseFailed(
        state,
        key,
      ),
      InteractivePromptCancelled(:final key) => _transition(
        state,
        key,
        InteractivePromptStatus.cancelled,
      ),
      InteractivePromptExpired(:final key) => _transition(
        state,
        key,
        InteractivePromptStatus.expired,
      ),
      InteractivePromptRuntimeExpired(:final runtimeSessionId) =>
        _expireRuntime(state, runtimeSessionId),
      InteractivePromptDisposed() => const InteractivePromptState.disposed(),
    };
  }

  static InteractivePromptState _receive(
    InteractivePromptState state,
    InteractivePromptRequest request,
  ) {
    final current = state[request.key];
    if (current == null) {
      return _replace(
        state,
        InteractivePromptEntry(
          key: request.key,
          request: request,
          status: InteractivePromptStatus.pending,
        ),
      );
    }
    if (current.isTerminal) return state;
    final currentRequest = current.request;
    if (currentRequest == null) {
      // A non-terminal lifecycle event beat its request over the wire. Attach
      // the typed payload without rolling the lifecycle backwards to pending.
      return _replace(state, current.withRequest(request));
    }
    // Kind is an immutable discriminator, not part of request identity. Reusing
    // an exact runtime/request key for another kind is a protocol conflict.
    // Erase the payload and keep an absorbing tombstone for delayed replays.
    if (currentRequest.kind != request.kind) {
      return _replace(
        state,
        InteractivePromptEntry(
          key: request.key,
          request: null,
          status: InteractivePromptStatus.expired,
        ),
      );
    }
    // Reconcile a replay of the same request. A reused opaque identity with a
    // different definition is a protocol violation and must not stay usable.
    if (currentRequest is ClarifyPromptRequest &&
        request is ClarifyPromptRequest) {
      if (!_clarifyDefinitionsEqual(currentRequest, request)) {
        return _transition(state, request.key, InteractivePromptStatus.expired);
      }
      final merged = _mergeLockedAnswersMonotonically(
        currentRequest.lockedAnswers,
        request.lockedAnswers,
      );
      if (merged == null) return state;
      if (identical(merged, currentRequest.lockedAnswers)) return state;
      return _replace(
        state,
        current.withRequest(currentRequest.copyWith(lockedAnswers: merged)),
      );
    }
    // Any other duplicate request is idempotent.
    return state;
  }

  static InteractivePromptState _failClosedMalformed(
    InteractivePromptState state,
    InteractivePromptParseFailure failure,
  ) {
    switch (failure.scope) {
      case InteractivePromptFailureScope.exactKey:
        final key = failure.key;
        return key == null ? state : _expireExactAsTombstone(state, key);
      case InteractivePromptFailureScope.runtimeKind:
        final runtimeSessionId = failure.runtimeSessionId;
        return runtimeSessionId == null
            ? state
            : _expireRuntimeKind(state, runtimeSessionId, failure.kind);
      case InteractivePromptFailureScope.transport:
        return state;
    }
  }

  static InteractivePromptState _expireExactAsTombstone(
    InteractivePromptState state,
    InteractivePromptKey key,
  ) {
    final current = state[key];
    if (current?.isTerminal == true) return state;
    return _replace(
      state,
      InteractivePromptEntry(
        key: key,
        request: null,
        status: InteractivePromptStatus.expired,
      ),
    );
  }

  static InteractivePromptState _expireRuntimeKind(
    InteractivePromptState state,
    String runtimeSessionId,
    InteractivePromptKind kind,
  ) {
    Map<InteractivePromptKey, InteractivePromptEntry>? changed;
    for (final entry in state.entries.values) {
      if (entry.key.runtimeSessionId != runtimeSessionId ||
          entry.isTerminal ||
          entry.request?.kind != kind) {
        continue;
      }
      changed ??= Map.of(state.entries);
      changed[entry.key] = InteractivePromptEntry(
        key: entry.key,
        request: null,
        status: InteractivePromptStatus.expired,
      );
    }
    return changed == null ? state : InteractivePromptState._(changed);
  }

  static InteractivePromptState _reconcileSnapshot(
    InteractivePromptState state,
    ClarifyPromptRequest request, {
    required bool unlockResponding,
  }) {
    final reconciled = _expireClarifies(
      state,
      request.key.runtimeSessionId,
      exceptKey: request.key,
    );
    final current = reconciled[request.key];
    if (current == null) return _receive(reconciled, request);
    if (current.isTerminal) return reconciled;
    final currentRequest = current.request;
    if (currentRequest is! ClarifyPromptRequest) {
      return _replace(
        reconciled,
        InteractivePromptEntry(
          key: request.key,
          request: null,
          status: InteractivePromptStatus.expired,
        ),
      );
    }
    if (!_clarifyDefinitionsEqual(currentRequest, request)) {
      return _transition(
        reconciled,
        request.key,
        InteractivePromptStatus.expired,
      );
    }
    final merged = _mergeLockedAnswersMonotonically(
      currentRequest.lockedAnswers,
      request.lockedAnswers,
    );
    if (merged == null) {
      return _transition(
        reconciled,
        request.key,
        InteractivePromptStatus.expired,
      );
    }
    final nextStatus =
        current.status == InteractivePromptStatus.responding &&
            !unlockResponding
        ? InteractivePromptStatus.responding
        : InteractivePromptStatus.pending;
    if (current.status == nextStatus &&
        identical(merged, currentRequest.lockedAnswers)) {
      return reconciled;
    }
    return _replace(
      reconciled,
      InteractivePromptEntry(
        key: current.key,
        request: currentRequest.copyWith(lockedAnswers: merged),
        status: nextStatus,
      ),
    );
  }

  static InteractivePromptState _expireClarifies(
    InteractivePromptState state,
    String runtimeSessionId, {
    InteractivePromptKey? exceptKey,
  }) {
    Map<InteractivePromptKey, InteractivePromptEntry>? changed;
    for (final entry in state.entries.values) {
      if (entry.key.runtimeSessionId != runtimeSessionId ||
          entry.key == exceptKey ||
          entry.isTerminal ||
          entry.request is! ClarifyPromptRequest) {
        continue;
      }
      changed ??= Map.of(state.entries);
      changed[entry.key] = entry.withStatus(InteractivePromptStatus.expired);
    }
    return changed == null ? state : InteractivePromptState._(changed);
  }

  static InteractivePromptState _transition(
    InteractivePromptState state,
    InteractivePromptKey key,
    InteractivePromptStatus next,
  ) {
    final current = state[key];
    if (current?.isTerminal == true) return state;
    if (current?.status == next) return state;

    return _replace(
      state,
      current?.withStatus(next) ??
          InteractivePromptEntry(key: key, request: null, status: next),
    );
  }

  static InteractivePromptState _expireRuntime(
    InteractivePromptState state,
    String runtimeSessionId,
  ) {
    Map<InteractivePromptKey, InteractivePromptEntry>? changed;
    for (final entry in state.entries.values) {
      if (entry.key.runtimeSessionId != runtimeSessionId || entry.isTerminal) {
        continue;
      }
      changed ??= Map.of(state.entries);
      changed[entry.key] = entry.withStatus(InteractivePromptStatus.expired);
    }
    return changed == null ? state : InteractivePromptState._(changed);
  }

  static InteractivePromptState _responseFailed(
    InteractivePromptState state,
    InteractivePromptKey key,
  ) {
    final current = state[key];
    if (current == null || current.isTerminal) return state;
    if (current.status != InteractivePromptStatus.responding) return state;
    return _replace(state, current.withStatus(InteractivePromptStatus.pending));
  }

  static InteractivePromptState _confirmBatchProgress(
    InteractivePromptState state,
    InteractivePromptKey key,
    String qid,
    String answer,
  ) {
    final current = state[key];
    if (current == null || current.isTerminal) return state;
    final request = current.request;
    if (request is! ClarifyPromptRequest) return state;
    if (current.status != InteractivePromptStatus.responding) return state;
    if (request.lockedAnswers[qid] == answer) return state;
    final updated = Map<String, String>.of(request.lockedAnswers);
    if (updated.containsKey(qid)) return state;
    updated[qid] = answer;
    return _replace(
      state,
      current.withRequest(request.copyWith(lockedAnswers: updated)),
    );
  }

  static bool _questionsEqual(
    List<ClarifyQuestion> a,
    List<ClarifyQuestion> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final aq = a[i];
      final bq = b[i];
      if (aq.qid != bq.qid ||
          aq.question != bq.question ||
          aq.multiSelect != bq.multiSelect ||
          aq.choices.length != bq.choices.length) {
        return false;
      }
      for (var j = 0; j < aq.choices.length; j++) {
        if (aq.choices[j] != bq.choices[j]) return false;
      }
    }
    return true;
  }

  static bool _clarifyDefinitionsEqual(
    ClarifyPromptRequest a,
    ClarifyPromptRequest b,
  ) {
    if (a.isBatch != b.isBatch) return false;
    if (a.isBatch) return _questionsEqual(a.questions, b.questions);
    if (a.question != b.question ||
        a.multiSelect != b.multiSelect ||
        a.choices.length != b.choices.length) {
      return false;
    }
    for (var i = 0; i < a.choices.length; i++) {
      if (a.choices[i] != b.choices[i]) return false;
    }
    return true;
  }

  static Map<String, String>? _mergeLockedAnswersMonotonically(
    Map<String, String> current,
    Map<String, String> replay,
  ) {
    var changed = false;
    final merged = Map<String, String>.of(current);
    for (final entry in replay.entries) {
      final existing = merged[entry.key];
      if (existing == null) {
        merged[entry.key] = entry.value;
        changed = true;
      } else if (existing != entry.value) {
        // Conflicting value for an already-confirmed answer: fail closed.
        return null;
      }
    }
    return changed ? merged : current;
  }

  static InteractivePromptState _replace(
    InteractivePromptState state,
    InteractivePromptEntry entry,
  ) {
    final changed = Map<InteractivePromptKey, InteractivePromptEntry>.of(
      state.entries,
    );
    changed[entry.key] = entry;
    return InteractivePromptState._(changed);
  }
}
