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
}
