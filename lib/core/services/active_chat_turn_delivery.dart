// Turn ownership. Tracks whether a prepared turn crossed the transport, so
// a retry can tell a safe resend from a possible duplicate.
// ignore_for_file: prefer_initializing_formals
part of 'active_chat_service.dart';

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
  bool _persistenceFailed = false;
  Future<void> _mutationTail = Future<void>.value();

  PreparedTurn get current => _current;
  bool get transportStarted => _transportStarted;
  bool get acknowledged => _acknowledged;
  bool get persistenceFailed => _persistenceFailed;

  Future<bool> persistPrepared() => _serializeMutation(() async {
    if (_transportStarted || _acknowledged) return false;
    try {
      await _store.save(_current);
      return true;
    } catch (_) {
      _persistenceFailed = true;
      return false;
    }
  });

  Future<bool> discardPrepared() => _serializeMutation(() async {
    if (_transportStarted || _acknowledged) return false;
    try {
      await _store.delete(_current);
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
    if (_acknowledged) return;
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
  Future<void> markRejectedBeforeAcceptance() => _serializeMutation(() async {
    if (_acknowledged) return;
    final next = _current.copyWith(
      updatedAtMs: _nowMs(),
      state: PreparedTurnState.failedBeforeAcceptance,
    );
    _current = next;
    try {
      await _store.save(next);
    } catch (_) {
      _persistenceFailed = true;
    }
  });
}

class QueuedPreparedTurn {
  const QueuedPreparedTurn(this.delivery, {required this.queueOrder});

  final ActiveTurnDelivery delivery;
  final int queueOrder;
  PreparedTurn get turn => delivery.current;
}

class _QueuedTextTurn {
  const _QueuedTextTurn(this.text, this.queueOrder);

  final String text;
  final int queueOrder;
}

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
}
