// The flap judgement without a gateway: an unmeasured run is invalid, never a
// pass, and a second dial inside one cut window is a miss.
import 'package:flutter_test/flutter_test.dart';

import 'support/flap_verdict.dart';

FlapVerdict _verdict({
  int cuts = 10,
  int opens = 7,
  Map<String, int> windows = const {'1': 1, '2': 1, '3': 1, '10': 1},
  int severed = 3,
}) => flapVerdict(
  cuts: cuts,
  expectedCuts: 10,
  opens: opens,
  opensByWindow: windows,
  severed: severed,
  maxOpens: 10,
);

void main() {
  test('one open per window within the cap is clean', () {
    expect(_verdict().problems, isEmpty);
  });

  test('zero opens still pass when the cuts really severed sockets', () {
    expect(_verdict(opens: 0, windows: const {}).problems, isEmpty);
  });

  test('a run whose cuts severed nothing is invalid, not a success', () {
    final v = _verdict(opens: 0, windows: const {}, severed: 0);
    expect(v.invalid, startsWith('INVALID'));
    expect(v.problems, isNotEmpty);
  });

  test('two opens inside one window is red', () {
    final v = _verdict(windows: const {'1': 1, '4': 2});
    expect(v.problems, ['window 4: 2 opens > 1']);
  });

  test('the cap is the physical windows: 10 pass, 11 do not', () {
    expect(_verdict(opens: 10).problems, isEmpty);
    expect(_verdict(opens: 11).problems, ['WebSocket opens 11 > 10']);
  });

  test('a measure that missed a cut is red', () {
    expect(_verdict(cuts: 9).problems, ['cuts 9 != 10']);
  });
}
