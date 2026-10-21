// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// ONB5: a refused password is said in the error colour, in dark and light.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

import '../onb2q/hermes_shaped_server.dart';
import 'onb5_support.dart';

void main() {
  late HermesShapedServer server;
  setUp(() async {
    // The test binding answers every HttpClient with a 400; this test talks
    // to a real server on 127.0.0.1.
    HttpOverrides.global = null;
    server = await HermesShapedServer.start();
  });
  tearDown(() async => server.close());

  for (final theme in ['console', 'console-light']) {
    testWidgets('$theme: the refusal is in the error colour', (tester) async {
      await openOnboarding(tester, theme: theme);
      await scan(tester, v2Link(server.url, pass: 'not-the-password'));
      await tester.tap(find.byKey(const ValueKey('onboarding-confirm')));
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(seconds: 2));
      final wrong = find.byKey(const ValueKey('onb3-wrong-password'));
      expect(wrong, findsOneWidget);
      final c = Theme.of(tester.element(wrong)).hermes;
      final text = tester.widget<Text>(wrong);
      expect(text.style?.color, c.error);
      expect(text.textAlign, TextAlign.center);
    });
  }
}
