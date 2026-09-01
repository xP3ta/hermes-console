import 'dart:async';

import 'notification_delivery_store.dart';

enum DeliveryPresentation { alert, inline, suppressed, retry }

class NotificationPresentationException implements Exception {
  const NotificationPresentationException(this.code);

  final String code;

  @override
  String toString() => 'NotificationPresentationException($code)';
}

/// The platform seam for durable notification delivery.
abstract interface class NotificationDeliveryPresenter {
  Future<DeliveryPresentation> show(DeliveryEventRecord event);
  Future<void> cancel(DeliveryEventRecord event);
}

/// Coordinates the only durable notification authority.
///
/// Every accepted lifecycle/ingest/dispatch/cancel operation is serialized.
/// Closing fences new work synchronously, drains the accepted tail, then closes
/// SQLite. Platform show is compensated with exact (tag,id) cancellation when
/// its fenced durable transition cannot be committed.
class NotificationDeliveryCoordinator {
  NotificationDeliveryCoordinator({
    required this.store,
    required this.presenter,
    this.dispatchLimit = 5,
    this.retryDelay = const Duration(seconds: 5),
    this.retentionMaxAge = const Duration(days: 30),
    this.retentionMaxTombstones = 4096,
  }) {
    if (dispatchLimit <= 0) {
      throw ArgumentError.value(dispatchLimit, 'dispatchLimit');
    }
    if (retryDelay.isNegative) {
      throw ArgumentError.value(retryDelay, 'retryDelay');
    }
    if (retentionMaxAge.isNegative) {
      throw ArgumentError.value(retentionMaxAge, 'retentionMaxAge');
    }
    if (retentionMaxTombstones < 0) {
      throw ArgumentError.value(
        retentionMaxTombstones,
        'retentionMaxTombstones',
      );
    }
  }

  final NotificationDeliveryStore store;
  final NotificationDeliveryPresenter presenter;
  final int dispatchLimit;
  final Duration retryDelay;
  final Duration retentionMaxAge;
  final int retentionMaxTombstones;

  Future<void>? _initializing;
  Future<void> _operationTail = Future<void>.value();
  bool _closing = false;
  bool _closed = false;
  Future<void>? _closeFuture;

  Future<T> _accept<T>(Future<T> Function() operation) {
    if (_closing || _closed) {
      return Future<T>.error(
        StateError('NotificationDeliveryCoordinator is closing or closed'),
      );
    }
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<void> _initialize() {
    final existing = _initializing;
    if (existing != null) return existing;
    final attempt = _openStore();
    _initializing = attempt;
    return attempt;
  }

  Future<void> _openStore() async {
    try {
      await store.open();
    } catch (_) {
      _initializing = null;
      rethrow;
    }
  }

  Future<void> initialize() => _accept(_initialize);

  Future<void> recoverAndDispatch() => _accept(() async {
    await _initialize();
    await store.reclaimExpiredLeases();
    try {
      await store.pruneRetention(
        maxAge: retentionMaxAge,
        maxTombstones: retentionMaxTombstones,
      );
    } catch (_) {
      // La poda es mantenimiento local best-effort. Nunca bloquea la
      // recuperación/entrega pendiente; el siguiente arranque reintenta.
    }
    await _dispatchOnce();
  });

  Future<void> ingest(List<SourceCursorUpdate> updates) => _accept(() async {
    await _initialize();
    await store.ingestSourceBatch(updates);
  });

  Future<void> ingestAndDispatch(List<SourceCursorUpdate> updates) =>
      _accept(() async {
        await _initialize();
        await store.ingestSourceBatch(updates);
        await _dispatchOnce();
      });

  Future<bool> ingestDiscovery({
    required String scopeKey,
    required SourceCursorUpdate Function(int? previousGeneration) buildUpdate,
    SourceCursorUpdate Function(int?, String?)? buildUpdateWithPrevious,
    required bool suppressByPolicy,
    bool suppressEventsWhenVersionUnchanged = false,
    bool suppressInitialEvents = true,
  }) => _accept(() async {
    await _initialize();
    final suppressed = await store.ingestDiscovery(
      scopeKey: scopeKey,
      buildUpdate: buildUpdate,
      buildUpdateWithPrevious: buildUpdateWithPrevious,
      suppressByPolicy: suppressByPolicy,
      suppressEventsWhenVersionUnchanged: suppressEventsWhenVersionUnchanged,
      suppressInitialEvents: suppressInitialEvents,
    );
    if (!suppressed) await _dispatchOnce();
    return suppressed;
  });

  Future<void> dispatch() => _accept(() async {
    await _initialize();
    await _dispatchOnce();
  });

  Future<void> _dispatchOnce() async {
    final leases = await store.leaseBatch(dispatchLimit);
    for (final lease in leases) {
      DeliveryPresentation presentation;
      try {
        presentation = await presenter.show(lease.event);
      } on NotificationPresentationException catch (error) {
        await store.retry(
          lease.event.eventKey,
          lease.token,
          delay: retryDelay,
          errorCode: error.code,
        );
        continue;
      } catch (_) {
        await store.retry(
          lease.event.eventKey,
          lease.token,
          delay: retryDelay,
          errorCode: 'platform_show',
        );
        continue;
      }

      if (presentation == DeliveryPresentation.retry) {
        await store.retry(
          lease.event.eventKey,
          lease.token,
          delay: retryDelay,
          errorCode: 'platform_transient',
        );
        continue;
      }
      if (presentation == DeliveryPresentation.suppressed) {
        await store.suppressLease(lease.event.eventKey, lease.token);
        continue;
      }

      bool marked;
      try {
        marked = await store.markPresented(
          lease.event.eventKey,
          lease.token,
          presentation.name,
        );
      } catch (_) {
        // A failed write is ambiguous across SQLite handles. Compensating is
        // safe only while this exact lease is still the authoritative owner;
        // otherwise another engine may already have re-presented the same
        // stable (tag,id).
        final authoritative = await store.eventByKey(lease.event.eventKey);
        if (authoritative?.status == DeliveryStatus.leased &&
            authoritative?.leaseToken == lease.token) {
          try {
            await presenter.cancel(lease.event);
          } catch (_) {
            // The fenced retry remains durable even if exact OS cancel failed.
          }
          await store.retry(
            lease.event.eventKey,
            lease.token,
            delay: retryDelay,
            errorCode: 'store_mark',
          );
        }
        continue;
      }
      if (!marked) {
        final authoritative = await store.eventByKey(lease.event.eventKey);
        if (authoritative?.status == DeliveryStatus.cancelPending &&
            authoritative?.leaseToken == lease.token) {
          try {
            await presenter.cancel(lease.event);
          } catch (_) {
            // The durable cancel_pending owner will retry reconciliation.
            continue;
          }
          await store.markCancelledByLease(lease.event.eventKey, lease.token);
        }
        // Never cancel merely because the fence was lost. A reclaimed owner may
        // already have shown and committed the same stable platform identity.
      }
    }
    await _reconcileCancellations();
  }

  Future<void> cancelApprovalForRun({
    required String connId,
    required String profile,
    required String runId,
  }) => _accept(() async {
    await _initialize();
    await store.markApprovalsCancelPendingForRun(
      connId: connId,
      profile: profile,
      runId: runId,
    );
    await _reconcileCancellations();
  });

  Future<void> cancelApproval({
    required String connId,
    required String profile,
    required String runId,
    required String requestId,
  }) => _accept(() async {
    await _initialize();
    await store.markApprovalCancelPending(
      connId: connId,
      profile: profile,
      runId: runId,
      requestId: requestId,
    );
    await _reconcileCancellations();
  });

  Future<void> cancelApprovalForSession({
    required String connId,
    required String profile,
    required String sessionId,
    required String requestId,
  }) => _accept(() async {
    await _initialize();
    await store.markApprovalCancelPendingForSession(
      connId: connId,
      profile: profile,
      sessionId: sessionId,
      requestId: requestId,
    );
    await _reconcileCancellations();
  });

  Future<void> reconcileCancellations() => _accept(() async {
    await _initialize();
    await _reconcileCancellations();
  });

  Future<void> _reconcileCancellations() async {
    final pending = await store.cancelPendingEvents();
    for (final event in pending) {
      try {
        await presenter.cancel(event);
      } catch (_) {
        continue;
      }
      if (event.leaseToken == null) {
        await store.markCancelled(event.eventKey);
      } else {
        await store.markExpiredCancellationCancelled(event.eventKey);
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closing = true;
    final close = () async {
      await _operationTail;
      await store.close();
      _initializing = null;
      _closed = true;
    }();
    _closeFuture = close;
    await close;
  }
}
