// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// ONB7: «Conectado» stays on screen long enough to be seen before the chat
// opens by itself, even when the model check answers at once (José, 9622:
// "entra ultrarrápido y no se llega a ver la animación").
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/onboarding_arrival.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../c3d/c3d_support.dart';
import '../onb2q/hermes_shaped_server.dart';

/// Connect by hand and stop as soon as «Conectado» shows, before the wait.
Future<Rig> _upToSuccess(
  WidgetTester tester, {
  bool untilButtons = true,
}) async {
  HttpOverrides.global = null;
  final server = (await tester.runAsync(HermesShapedServer.start))!;
  addTearDown(server.close);
  Dash.current!.auth = server;
  final rig = await pumpWelcome(tester);
  final taps = Taps(tester);
  await taps.key('onboarding-manual');
  await taps.typeManual(server.url);
  await taps.key('manual-connect');
  for (var i = 0; i < 600; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    final ready = untilButtons
        ? find.byKey(const ValueKey('onboarding-done'))
        : find.byKey(const ValueKey('onboarding-identity'));
    if (ready.evaluate().isNotEmpty) break;
  }
  final s = Strings.of(tester.element(find.byType(Navigator).first));
  expect(find.text(s.o2SuccessTitle), findsOneWidget);
  return rig;
}

Future<void> _tapNow(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(OnboardingArrival.reset);

  testWidgets('the chat opens only after «Conectado» has been shown', (
    tester,
  ) async {
    final dash = Dash();
    await withDash(dash, () async {
      HttpOverrides.global = null;
      final server = (await tester.runAsync(HermesShapedServer.start))!;
      addTearDown(server.close);
      Dash.current!.auth = server;
      final rig = await pumpWelcome(tester);
      final taps = Taps(tester);
      await taps.key('onboarding-manual');
      await taps.typeManual(server.url);
      await taps.key('manual-connect');
      final s = Strings.of(tester.element(find.byType(Navigator).first));

      // Real sockets for the sign-in; the fake clock only moves in 20 ms
      // steps, so the moment «Conectado» appears is measured closely.
      var clock = Duration.zero;
      Duration? shownAt;
      Duration? openedAt;
      for (var i = 0; i < 600 && openedAt == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        clock += const Duration(milliseconds: 20);
        if (shownAt == null &&
            find.text(s.o2SuccessTitle).evaluate().isNotEmpty) {
          shownAt = clock;
        }
        if (rig.done.isNotEmpty) openedAt = clock;
      }
      expect(shownAt, isNotNull, reason: '«Conectado» never showed');
      expect(openedAt, isNotNull, reason: 'the chat never opened');
      expect(dash.modelReads, greaterThan(0));
      // The harness runs with reduced motion: the shorter dwell applies.
      expect(
        openedAt! - shownAt!,
        greaterThanOrEqualTo(
          kOnbSuccessDwellReduced - const Duration(milliseconds: 60),
        ),
      );
      final created = rig.manager.getConnections().single;
      expect(OnboardingArrival.take(created.id), isTrue);
    });
  });

  testWidgets('no model: «Choose a model» during the wait opens ONE models '
      'screen', (tester) async {
    final dash = Dash(ready: false);
    await withDash(dash, () async {
      final rig = await _upToSuccess(tester);
      await _tapNow(tester, 'onboarding-open-chat');
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(find.byType(ModelsScreen, skipOffstage: false), findsOneWidget);
      expect(rig.done, isEmpty);
    });
  });

  testWidgets('no model: «Choose a model» closed before the wait ends does '
      'not reopen by itself', (tester) async {
    final dash = Dash(ready: false);
    await withDash(dash, () async {
      final rig = await _upToSuccess(tester);
      await _tapNow(tester, 'onboarding-open-chat');
      await tester.pump(const Duration(milliseconds: 300));
      Navigator.of(
        tester.element(find.byType(ModelsScreen, skipOffstage: false)),
      ).pop();
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(find.byType(ModelsScreen, skipOffstage: false), findsNothing);
      expect(rig.done, isEmpty);
    });
  });

  testWidgets(
    'system back during the wait goes home: no chat, no models screen',
    (tester) async {
      final dash = Dash();
      await withDash(dash, () async {
        final rig = await _upToSuccess(tester, untilButtons: false);
        expect(rig.done, isEmpty, reason: 'still inside the wait');
        await tester.binding.handlePopRoute();
        for (var i = 0; i < 150; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pumpAndSettle();
        // Back on «Conectado» goes home: no chat is opened, no model screen.
        expect(rig.done, [1]);
        expect(
          OnboardingArrival.take(rig.manager.getConnections().single.id),
          isFalse,
        );
        expect(find.byType(ModelsScreen, skipOffstage: false), findsNothing);
      });
    },
  );

  testWidgets('no model: «Go home» during the wait leaves, no models screen '
      'afterwards', (tester) async {
    final dash = Dash(ready: false);
    await withDash(dash, () async {
      final rig = await _upToSuccess(tester);
      await _tapNow(tester, 'onboarding-done');
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(rig.done, [1]);
      expect(find.byType(ModelsScreen, skipOffstage: false), findsNothing);
    });
  });

  test('the dwell covers the success animation', () {
    expect(kOnbSuccessDwell, greaterThanOrEqualTo(const Duration(seconds: 1)));
    expect(kOnbSuccessDwell.inMilliseconds, lessThanOrEqualTo(2500));
    expect(kOnbSuccessDwellReduced, lessThan(kOnbSuccessDwell));
  });
}
