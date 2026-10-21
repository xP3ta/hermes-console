// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// C3d-2': after the automatic save the chat opens by itself, like Desktop;
// without a model the model screen opens first, never a chat that fails.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/onboarding_arrival.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'c3d_support.dart';

const _openChat = ValueKey('onboarding-open-chat');
const _done = ValueKey('onboarding-done');

Strings _strings(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(Navigator).first));

bool _arrival(Rig rig) =>
    OnboardingArrival.take(rig.manager.getConnections().single.id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(OnboardingArrival.reset);

  testWidgets('RED 2: model ready → the chat opens with no touch', (
    tester,
  ) async {
    final dash = Dash();
    await withDash(dash, () async {
      final (rig, taps) = await connectByHand(tester);
      expect(taps.count, 2, reason: 'Connect by hand, Connect');
      expect(find.byKey(_openChat), findsNothing);
      expect(rig.done, [1]);
      expect(rig.manager.getConnections(), hasLength(1));
      expect(_arrival(rig), isTrue);
      expect(dash.modelReads, 2, reason: 'one info + one options, once');
    });
  });

  testWidgets('RED 3: https saved route needs one touch less', (tester) async {
    final dash = Dash();
    await withDash(dash, () async {
      final (rig, taps) = await connectByHand(tester, saved: true);
      expect(taps.count, 2, reason: 'Connect by hand, Connect');
      expect(rig.done, [1]);
      expect(rig.manager.getConnections(), hasLength(2));
      final created = rig.manager.getConnections().firstWhere(
        (c) => c.id != 'conn-a',
      );
      expect(OnboardingArrival.take(created.id), isTrue);
    });
  });

  testWidgets('RED 8: no button shows while the model is being read', (
    tester,
  ) async {
    final dash = Dash()..hang = Completer<void>();
    await withDash(dash, () async {
      final (rig, _) = await connectByHand(tester);
      final s = _strings(tester);
      expect(find.text(s.o2SuccessTitle), findsOneWidget);
      expect(find.byKey(_openChat), findsNothing);
      expect(find.byKey(_done), findsNothing);
      expect(rig.done, isEmpty);
      dash.hang!.complete();
      await tester.pumpAndSettle();
      expect(rig.done, [1]);
      expect(_arrival(rig), isTrue);
    });
  });

  testWidgets('RED 4: no model → the model screen opens, no chat is queued', (
    tester,
  ) async {
    final dash = Dash(ready: false);
    await withDash(dash, () async {
      final (rig, _) = await connectByHand(tester);
      final s = _strings(tester);
      expect(find.byType(ModelsScreen), findsOneWidget);
      expect(rig.done, isEmpty);
      expect(
        OnboardingArrival.take(rig.manager.getConnections().single.id),
        isFalse,
      );
      // Back without a model: the C3c state, still no chat.
      Navigator.of(tester.element(find.byType(ModelsScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.text(s.o2NeedsModelBody), findsOneWidget);
      expect(find.text(s.o2ChooseModel), findsOneWidget);
      expect(find.text(s.o2GoHome), findsOneWidget);
      expect(find.text(s.o2OpenChat), findsNothing);
      expect(rig.done, isEmpty);
      expect(
        OnboardingArrival.take(rig.manager.getConnections().single.id),
        isFalse,
      );
    });
  });

  testWidgets('RED 5: no model → pick one → the chat opens by itself', (
    tester,
  ) async {
    final dash = Dash(ready: false);
    await withDash(dash, () async {
      final (rig, _) = await connectByHand(tester);
      expect(find.byType(ModelsScreen), findsOneWidget);
      dash.ready = true;
      Navigator.of(tester.element(find.byType(ModelsScreen))).pop();
      await tester.pumpAndSettle();
      expect(rig.done, [1], reason: 'exactly one chat');
      expect(_arrival(rig), isTrue);
    });
  });

  testWidgets('RED 5: still no model, «Choose a model» then ready opens it', (
    tester,
  ) async {
    final dash = Dash(ready: false);
    await withDash(dash, () async {
      final (rig, _) = await connectByHand(tester);
      Navigator.of(tester.element(find.byType(ModelsScreen))).pop();
      await tester.pumpAndSettle();
      expect(rig.done, isEmpty);
      final taps = Taps(tester);
      await taps.key('onboarding-open-chat');
      expect(find.byType(ModelsScreen), findsOneWidget);
      dash.ready = true;
      Navigator.of(tester.element(find.byType(ModelsScreen))).pop();
      await tester.pumpAndSettle();
      expect(rig.done, [1]);
      expect(_arrival(rig), isTrue);
    });
  });

  testWidgets('RED 6: a 401 on the model read still opens the chat', (
    tester,
  ) async {
    final dash = Dash()..modelStatus = 401;
    await withDash(dash, () async {
      final (rig, _) = await connectByHand(tester);
      expect(rig.done, [1]);
      expect(_arrival(rig), isTrue);
    });
  });

  testWidgets('RED 6: a model read that never answers opens the chat after '
      '4 s', (tester) async {
    final dash = Dash()..hang = Completer<void>();
    await withDash(dash, () async {
      final (rig, _) = await connectByHand(tester);
      expect(rig.done, isEmpty);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(rig.done, [1]);
      expect(_arrival(rig), isTrue);
      dash.hang!.complete();
      await tester.pump();
    });
  });

  testWidgets('R11: the new connection keeps its own profile', (tester) async {
    final dash = Dash();
    await withDash(dash, () async {
      final (rig, _) = await connectByHand(
        tester,
        saved: true,
        before: (m) => m.setActiveProfile('conn-a', 'work'),
      );
      final created = rig.manager.getConnections().firstWhere(
        (c) => c.id != 'conn-a',
      );
      expect(rig.manager.activeProfileFor(created.id), '');
      expect(rig.manager.activeProfileFor('conn-a'), 'work');
      expect(
        dash.modelCalls.every((u) => !u.queryParameters.containsKey('profile')),
        isTrue,
      );
    });
  });

  group('R12: the model client is always closed', () {
    for (final (name, make) in <(String, Dash Function())>[
      ('ready', Dash.new),
      ('needs a model', () => Dash(ready: false)),
      ('401', () => Dash()..modelStatus = 401),
      ('timeout', () => Dash()..hang = Completer<void>()),
    ]) {
      testWidgets(name, (tester) async {
        final dash = make();
        await withDash(dash, () async {
          await connectByHand(tester);
          if (dash.hang != null) await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
          // The model screen reads with a client of its own; leave it first.
          if (find.byType(ModelsScreen).evaluate().isNotEmpty) {
            Navigator.of(tester.element(find.byType(ModelsScreen))).pop();
            await tester.pumpAndSettle();
          }
          expect(dash.modelClients, isNotEmpty);
          expect(dash.modelClients.every((c) => c.closed), isTrue);
          dash.hang?.complete();
          await tester.pump();
        });
      });
    }
  });

  testWidgets('R8: QR with the flag on still asks «Open chat»', (tester) async {
    final dash = Dash();
    await withDash(dash, () async {
      final rig = await pumpWelcome(tester);
      final taps = Taps(tester);
      await taps.key('onboarding-scan');
      await taps.key('onboarding-confirm');
      await tester.pump(const Duration(seconds: 6));
      expect(find.byKey(_openChat), findsOneWidget);
      expect(rig.done, isEmpty);
    });
  });

  testWidgets('R1: flag off reads no model and opens nothing', (tester) async {
    final dash = Dash();
    await withDash(dash, () async {
      final rig = await pumpWelcome(tester, flag: false);
      final taps = Taps(tester);
      await taps.key('onboarding-scan');
      await taps.key('onboarding-confirm');
      await tester.pump(const Duration(seconds: 6));
      expect(find.byKey(_openChat), findsNothing);
      expect(find.byKey(_done), findsOneWidget);
      expect(dash.modelReads, 0);
      expect(rig.done, isEmpty);
      expect(
        OnboardingArrival.take(rig.manager.getConnections().single.id),
        isFalse,
      );
    });
  });

  testWidgets('R8: manual with the flag on opens nothing by itself', (
    tester,
  ) async {
    final dash = Dash();
    await withDash(dash, () async {
      final rig = await pumpWelcome(tester);
      final taps = Taps(tester);
      await taps.key('onboarding-manual');
      await tester.pump(const Duration(seconds: 6));
      // The simple form (W4): no connection, no chat until it is filled in.
      expect(find.byKey(const ValueKey('manual-address')), findsOneWidget);
      expect(rig.manager.getConnections(), isEmpty);
      expect(find.byKey(_openChat), findsNothing);
      expect(rig.done, isEmpty);
    });
  });

  testWidgets('R10: «Go to Home» while the re-check runs leaves once', (
    tester,
  ) async {
    final dash = Dash(ready: false);
    await withDash(dash, () async {
      final (rig, _) = await connectByHand(tester);
      // A model gets picked, and the check on return is still running when
      // the person gives up and goes Home. Its answer must not leave twice.
      dash.ready = true;
      dash.hang = Completer<void>();
      Navigator.of(tester.element(find.byType(ModelsScreen))).pop();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(_done));
      await tester.pump(const Duration(milliseconds: 200));
      expect(rig.done, [1]);
      dash.hang!.complete();
      await tester.pumpAndSettle();
      expect(rig.done, [1], reason: 'one exit only');
      expect(
        OnboardingArrival.take(rig.manager.getConnections().single.id),
        isFalse,
      );
    });
  });
}
