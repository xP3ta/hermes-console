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

  const AppErrorRecord({
    required this.source,
    required this.errorType,
    required this.at,
  });

  @override
  String toString() => '$source $errorType ${at.toIso8601String()}';
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
  static void record(String source, Object error) => _record(source, error);

  static void _record(String source, Object error) {
    final record = AppErrorRecord(
      source: source,
      errorType: error.runtimeType.toString(),
      at: DateTime.now(),
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
