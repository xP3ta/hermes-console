import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/app_error_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FlutterExceptionHandler? savedFlutterHandler;
  late ErrorCallback? savedPlatformHandler;

  setUp(() {
    savedFlutterHandler = FlutterError.onError;
    savedPlatformHandler = PlatformDispatcher.instance.onError;
    AppErrorLog.resetForTesting();
  });

  tearDown(() {
    FlutterError.onError = savedFlutterHandler;
    PlatformDispatcher.instance.onError = savedPlatformHandler;
    AppErrorLog.resetForTesting();
  });

  test('framework errors still reach the previous handler and are logged '
      'by type only', () {
    final presented = <FlutterErrorDetails>[];
    FlutterError.onError = presented.add;
    AppErrorLog.install();

    final details = FlutterErrorDetails(
      exception: StateError('prompt text sk-private-123'),
    );
    FlutterError.reportError(details);

    expect(presented, [same(details)]);
    expect(AppErrorLog.recent, hasLength(1));
    final record = AppErrorLog.recent.single;
    expect(record.source, 'flutter');
    expect(record.errorType, 'StateError');
    expect('$record', isNot(contains('sk-private-123')));
    expect('$record', isNot(contains('prompt text')));
  });

  test('uncaught async errors keep the previous verdict', () {
    final seen = <Object>[];
    PlatformDispatcher.instance.onError = (error, stack) {
      seen.add(error);
      return true;
    };
    AppErrorLog.install();

    final error = ArgumentError('secret');
    expect(
      PlatformDispatcher.instance.onError!(error, StackTrace.empty),
      isTrue,
    );
    expect(seen, [same(error)]);
    expect(AppErrorLog.recent.single.source, 'platform');
    expect(AppErrorLog.recent.single.errorType, 'ArgumentError');
  });

  test('without a previous handler async errors keep the default path', () {
    PlatformDispatcher.instance.onError = null;
    AppErrorLog.install();

    expect(
      PlatformDispatcher.instance.onError!(StateError('x'), StackTrace.empty),
      isFalse,
      reason: 'false lets the engine report the error as before',
    );
    expect(AppErrorLog.recent, hasLength(1));
  });

  test('installing twice does not log or forward twice', () {
    final presented = <FlutterErrorDetails>[];
    FlutterError.onError = presented.add;
    AppErrorLog.install();
    AppErrorLog.install();

    FlutterError.reportError(FlutterErrorDetails(exception: StateError('x')));

    expect(presented, hasLength(1));
    expect(AppErrorLog.recent, hasLength(1));
  });

  test('keeps only the most recent entries', () {
    FlutterError.onError = (_) {};
    AppErrorLog.install();
    for (var i = 0; i < AppErrorLog.capacity + 20; i++) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: i.isEven ? StateError('') : 'text'),
      );
    }
    expect(AppErrorLog.recent, hasLength(AppErrorLog.capacity));
    expect(AppErrorLog.recent.last.errorType, 'String');
  });

  test('secure-storage failures are counted per operation and error type, '
      'and only the most recent kinds are kept', () {
    SecureStorageDiagnostics.resetForTesting();
    addTearDown(SecureStorageDiagnostics.resetForTesting);
    final errors = <Object>[
      StateError('private'),
      ArgumentError('private'),
      const FormatException('private'),
    ];
    final kinds = [
      for (final operation in SecureStorageOperation.values)
        for (final error in errors) (operation, error),
    ];
    expect(kinds.length, greaterThan(SecureStorageDiagnostics.capacity));
    for (final (operation, error) in kinds) {
      SecureStorageDiagnostics.record(operation, error);
    }
    final newest = kinds.skip(kinds.length - SecureStorageDiagnostics.capacity);

    expect(
      SecureStorageDiagnostics.recent.map((f) => (f.operation, f.errorType)),
      [for (final (op, error) in newest) (op, '${error.runtimeType}')],
    );

    // The oldest kept kind fails again: one entry, counted twice, now the
    // most recent; nothing else is dropped.
    final (operation, error) = newest.first;
    SecureStorageDiagnostics.record(operation, error);
    final recent = SecureStorageDiagnostics.recent;
    expect(recent, hasLength(SecureStorageDiagnostics.capacity));
    expect(recent.last.operation, operation);
    expect(recent.last.errorType, '${error.runtimeType}');
    expect(recent.last.count, 2);
    expect(recent.last.lastAt.isBefore(recent.last.firstAt), isFalse);
    expect(recent.where((f) => f.count == 2), hasLength(1));
  });
}
