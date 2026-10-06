// Source guards for the Mobile Bridge retirement (bridge-audit plan, PR 1).
// The removed client calls had no callers; these guards keep them from coming
// back silently while the bridge is phased out.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _code(String path) {
  final source = File(path).readAsStringSync();
  // Drop line comments so historical notes do not count as usage.
  return source
      .split('\n')
      .map((line) {
        final i = line.indexOf('//');
        return i < 0 ? line : line.substring(0, i);
      })
      .join('\n');
}

void main() {
  test('uncalled bridge client calls stay deleted', () {
    final source = _code('lib/core/services/bridge_client.dart');
    for (final dead in const [
      '/bridge/diag/',
      '/bridge/rollback',
      '/bridge/model/get',
      'localDiag(',
      'llamacppBench(',
      'gpuProbe(',
      'rollback(',
      'getActiveModel(',
    ]) {
      expect(source, isNot(contains(dead)), reason: dead);
    }
  });

  test('the uninstantiated RunsTab bridge run path stays deleted', () {
    final source = _code('lib/core/screens/runs_screen.dart');
    expect(source, isNot(contains('class RunsTab')));
    expect(source, isNot(contains('_launchLocalRun')));
    expect(source, isNot(contains('BridgeClient')));
  });

}
