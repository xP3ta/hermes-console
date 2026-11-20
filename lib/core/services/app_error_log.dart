import 'dart:collection';

import 'package:flutter/foundation.dart';

/// One uncaught error, reduced to what is safe to keep: where it surfaced,
/// its runtime type and when. Messages and stack traces are never stored
/// because they can carry transcript text, prompts or credentials.
@immutable
final class AppErrorRecord {
  final String source;
  final String errorType;
  final DateTime at;
  final String? rowId;

  const AppErrorRecord({
    required this.source,
    required this.errorType,
    required this.at,
    this.rowId,
  });

  @override
  String toString() =>
      '$source $errorType ${at.toIso8601String()}${rowId == null ? '' : ' $rowId'}';
}

/// Local-only log of uncaught errors. It chains to the handlers that were
/// installed before it, so Flutter's default reporting and any existing
/// verdict stay exactly as they were; nothing is uploaded.
abstract final class AppErrorLog {
  static const int capacity = 50;
  static final ListQueue<AppErrorRecord> _recent = ListQueue();
  static bool _installed = false;

  static List<AppErrorRecord> get recent => List.unmodifiable(_recent);

  static void install() {
    if (_installed) return;
    _installed = true;
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      _record('flutter', details.exception);
      (previousFlutter ?? FlutterError.presentError)(details);
    };
    final dispatcher = PlatformDispatcher.instance;
    final previousPlatform = dispatcher.onError;
    dispatcher.onError = (error, stack) {
      _record('platform', error);
      // `false` hands the error back to the engine's default reporting.
      return previousPlatform?.call(error, stack) ?? false;
    };
  }

  /// Records an error that was caught and handled, e.g. a startup step that
  /// failed and was degraded or surfaced on a recovery screen.
  static void record(String source, Object error, {String? rowId}) =>
      _record(source, error, rowId: rowId);

  static void _record(String source, Object error, {String? rowId}) {
    final record = AppErrorRecord(
      source: source,
      errorType: error.runtimeType.toString(),
      at: DateTime.now(),
      rowId: rowId,
    );
    _recent.addLast(record);
    while (_recent.length > capacity) {
      _recent.removeFirst();
    }
    debugPrint('[app-error] ${record.source} ${record.errorType}');
  }

  @visibleForTesting
  static void resetForTesting() {
    _installed = false;
    _recent.clear();
  }
}

/// What the app was doing in its encrypted storage (Android Keystore) when
/// a read or write failed or was refused. A fixed list, never free text.
enum SecureStorageOperation {
  draftLoad,
  draftSave,
  draftClear,
  draftList,
  outboxRead,
  outboxSave,
  outboxDelete,
  coldStartIndex,
  coldStartTail,
  coldStartKey,
}

/// One kind of secure-storage failure: the operation, the error's runtime
/// type, how many times it happened and when. Never its message, the key,
/// a text, a session or a connection.
@immutable
final class SecureStorageFailure {
  final SecureStorageOperation operation;
  final String errorType;
  final int count;
  final DateTime firstAt;
  final DateTime lastAt;

  const SecureStorageFailure({
    required this.operation,
    required this.errorType,
    required this.count,
    required this.firstAt,
    required this.lastAt,
  });
}

typedef _FailureKind = (SecureStorageOperation, String);

/// Local-only record of secure-storage failures, for the diagnostic export.
/// A failure that repeats (a draft list every few seconds) is counted in
/// one entry instead of pushing others out; at most [capacity] kinds, the
/// least recent dropped first. Nothing is uploaded.
abstract final class SecureStorageDiagnostics {
  static const int capacity = 16;
  static final Map<_FailureKind, SecureStorageFailure> _byKind = {};

  /// Least recently failed first.
  static List<SecureStorageFailure> get recent =>
      List.unmodifiable(_byKind.values);

  static void record(SecureStorageOperation operation, Object error) {
    final errorType = error.runtimeType.toString();
    final previous = _byKind.remove((operation, errorType));
    final now = DateTime.now();
    _byKind[(operation, errorType)] = SecureStorageFailure(
      operation: operation,
      errorType: errorType,
      count: (previous?.count ?? 0) + 1,
      firstAt: previous?.firstAt ?? now,
      lastAt: now,
    );
    while (_byKind.length > capacity) {
      _byKind.remove(_byKind.keys.first);
    }
  }

  /// Returns [future] itself (same result, same timing) and records its
  /// failure as one of [operation].
  static Future<T> watch<T>(
    SecureStorageOperation operation,
    Future<T> future,
  ) {
    future.then<void>(
      (_) {},
      onError: (Object error) => record(operation, error),
    );
    return future;
  }

  @visibleForTesting
  static void resetForTesting() => _byKind.clear();
}
