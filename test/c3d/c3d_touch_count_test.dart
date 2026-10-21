// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// Touches from the welcome to the open chat on the Connect by hand route. It
// replaces the count of the retired network search. The last touch (Send in
// the chat) cannot be made here because ChatScreen needs the whole app, so it
// is added by hand and said so.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/onboarding_arrival.dart';

import 'c3d_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(OnboardingArrival.reset);

  testWidgets('by hand: touches until the chat opens', (tester) async {
    final dash = Dash();
    await withDash(dash, () async {
      final (rig, taps) = await connectByHand(tester);
      // ignore: avoid_print
      print(
        'C3D_HAND_TOUCHES_TO_SEND=${taps.count + 1} (Send added by hand) ${taps.trail}',
      );
      expect(taps.count, 2, reason: 'Connect by hand + Connect; plus Send = 3');
      expect(rig.manager.getConnections(), hasLength(1));
      expect(rig.done, [1]);
      expect(
        OnboardingArrival.take(rig.manager.getConnections().single.id),
        isTrue,
      );
    });
  });

  testWidgets('by hand with a saved Hermes: the same touches', (tester) async {
    final dash = Dash();
    await withDash(dash, () async {
      final (rig, taps) = await connectByHand(tester, saved: true);
      expect(taps.count, 2);
      expect(rig.manager.getConnections(), hasLength(2));
      expect(rig.done, [1]);
    });
  });
}
