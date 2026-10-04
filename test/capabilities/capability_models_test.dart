import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';

CapabilityActionStatus _exit(List<String> lines) => CapabilityActionStatus(
  name: 'a',
  running: false,
  exitCode: 1,
  lines: lines,
);

void main() {
  group('security scan gate (ported from Desktop)', () {
    test('current log shape, with and without a findings count', () {
      final counted = _exit([
        'Not installed: the security scan found 3 high-risk pattern(s)',
      ]);
      expect(counted.blockedByScan, isTrue);
      expect(counted.scanFindings, 3);
      final bare = _exit([
        'Not installed: the security scan found high-risk pattern(s)',
      ]);
      expect(bare.blockedByScan, isTrue);
      expect(bare.scanFindings, isNull);
    });

    test('unverified shape', () {
      final status = _exit(['hermes never installs unverified skills']);
      expect(status.blockedByScan, isTrue);
      expect(status.scanFindings, isNull);
    });

    test('legacy shape keeps the findings count', () {
      final status = _exit([
        'Installation blocked: refused (community source + caution verdict, 2 findings)',
      ]);
      expect(status.blockedByScan, isTrue);
      expect(status.scanFindings, 2);
    });

    test('unrelated failures are not scan blocks', () {
      expect(_exit(['network error']).blockedByScan, isFalse);
      // Old heuristic matched any "blocked" next to "security scan".
      expect(
        _exit(['the security scan was blocked by a proxy']).blockedByScan,
        isFalse,
      );
    });
  });
}
