// M5 (performance audit 1.4.0): `debugPrint` is not stripped from release
// builds, so the store flavours silence it at startup. QA builds, debug and
// profile keep their logs.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/release_logging.dart';

void main() {
  late DebugPrintCallback saved;
  final seen = <String>[];

  setUp(() {
    saved = debugPrint;
    seen.clear();
    debugPrint = (message, {wrapWidth}) => seen.add(message ?? '');
  });
  tearDown(() => debugPrint = saved);

  test('a release build of a store flavour drops every debugPrint', () {
    for (final flavor in ['full', 'play']) {
      debugPrint = (message, {wrapWidth}) => seen.add(message ?? '');
      silenceDebugPrintInRelease(releaseMode: true, flavor: flavor);
      debugPrint('[sync] decision');
      debugPrint(null, wrapWidth: 80);
    }
    expect(seen, isEmpty);
  });

  test('QA, debug and profile builds keep their logs', () {
    silenceDebugPrintInRelease(releaseMode: true, flavor: 'qa');
    debugPrint('qa');
    silenceDebugPrintInRelease(releaseMode: false, flavor: 'full');
    debugPrint('debug');
    expect(seen, ['qa', 'debug']);
  });

  test('main() silences it before the first log line', () {
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf('void main() async {');
    expect(start, isNonNegative);
    final silence = source.indexOf('silenceDebugPrintInRelease();', start);
    final firstLog = source.indexOf('PerformanceTrace.qa.start();', start);
    expect(silence, isNonNegative);
    expect(silence, lessThan(firstLog));
  });
}
