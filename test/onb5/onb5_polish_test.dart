// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// ONB5: the layout and style facts of the polish (title, fixed actions, the
// consent in the onboarding family, the readable command in light, one-line
// address at 2x, Connect by hand without the gap, the welcome's mark).
import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_motion.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_widgets.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

import '../support/design_shots.dart' show loadDesignFonts;
import '../support/onboarding_fakes.dart' show tapOnboarding;
import 'onb5_support.dart';

Future<void> _manual(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  String theme = 'dark',
  String language = 'es',
}) async {
  await openOnboarding(tester, size: size, theme: theme, language: language);
  await tester.tap(find.byKey(const ValueKey('onboarding-manual')));
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['es', 'en']) {
    testWidgets('$language: Connect by hand is titled «Connect by hand»', (
      tester,
    ) async {
      await _manual(tester, language: language);
      final s = stringsOf(tester, ManualConnectPage);
      final title = find.descendant(
        of: find.byType(ManualConnectPage),
        matching: find.text(s.o2Manual),
      );
      expect(title, findsOneWidget);
      expect(
        tester.getSemantics(title).getSemanticsData().flagsCollection.isHeader,
        isTrue,
      );
      expect(
        find.descendant(
          of: find.byType(ManualConnectPage),
          matching: find.text('Conecta con tu Hermes'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(ManualConnectPage),
          matching: find.text('Connect to your Hermes'),
        ),
        findsNothing,
      );
    });
  }

  testWidgets('confirm with a password and the consent: Connect is above the '
      'fold at 390x844', (tester) async {
    await openOnboarding(tester);
    await scan(tester, lanNoPassword);
    expect(find.byKey(const ValueKey('onb3-password')), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-http-consent')), findsOneWidget);
    expect(rectOf(tester, 'onboarding-confirm').bottom, lessThanOrEqualTo(828));
    expect(rectOf(tester, 'onboarding-other').bottom, lessThanOrEqualTo(844));
  });

  testWidgets('the help keeps «Scan» fixed above the fold', (tester) async {
    await openOnboarding(tester);
    await tester.tap(find.byKey(const ValueKey('onboarding-help')));
    await tester.pumpAndSettle();
    expect(
      rectOf(tester, 'onboarding-help-scan').bottom,
      lessThanOrEqualTo(828),
    );
    // At 320 dp and 2x text the same: the scroll above it, the actions fixed.
    await openOnboarding(tester, size: const Size(320, 640), scale: 2);
    await tapOnboarding(tester, 'onboarding-help');
    expect(tester.takeException(), isNull);
    expect(
      rectOf(tester, 'onboarding-help-scan').bottom,
      lessThanOrEqualTo(640),
    );
  });

  testWidgets('no Material checkbox is left in the flow; the consent is the '
      'onboarding\'s own', (tester) async {
    await loadDesignFonts();
    await openOnboarding(tester);
    await scan(tester, lanNoPassword);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    final key = find.byKey(const ValueKey('pairing-http-consent'));
    expect(tester.widget(key), isA<OnbConsent>());
    expect(tester.getSize(key).height, greaterThanOrEqualTo(48));
    final handle = tester.ensureSemantics();
    SemanticsData data() => tester.getSemantics(key).getSemanticsData();
    expect(data().flagsCollection.isChecked, CheckedState.isFalse);
    await tapOnboarding(tester, 'pairing-http-consent');
    expect(tester.widget<OnbConsent>(key).value, isTrue);
    expect(data().flagsCollection.isChecked, CheckedState.isTrue);
    expect(
      find.descendant(of: key, matching: find.byType(DrawnCheck)),
      findsOneWidget,
    );
    await tapOnboarding(tester, 'pairing-http-consent');
    expect(data().flagsCollection.isChecked, CheckedState.isFalse);
    handle.dispose();
  });

  testWidgets('Connect by hand: the consent is the same widget', (
    tester,
  ) async {
    await loadDesignFonts();
    await _manual(tester);
    await tester.enterText(
      find.byKey(const ValueKey('manual-address')),
      'http://192.168.1.20:9119',
    );
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    final key = find.byKey(const ValueKey('manual-consent'));
    expect(tester.widget(key), isA<OnbConsent>());
    expect(tester.getSize(key).height, greaterThanOrEqualTo(48));
    await tester.tap(key);
    await tester.pumpAndSettle();
    expect(tester.widget<OnbConsent>(key).value, isTrue);
  });

  for (final theme in ['console', 'console-light']) {
    testWidgets('$theme: the setup command reads at AA (>= 4.5:1)', (
      tester,
    ) async {
      await openOnboarding(tester, theme: theme);
      await tester.tap(find.byKey(const ValueKey('onboarding-help')));
      await tester.pumpAndSettle();
      final box = find.descendant(
        of: find.byKey(const ValueKey('pairing-helper-command')),
        matching: find.byType(Container),
      );
      final fill =
          (tester.widget<Container>(box.first).decoration as BoxDecoration)
              .color!;
      final c = Theme.of(tester.element(box.first)).hermes;
      double l(Color x) => x.computeLuminance();
      final hi = l(fill) > l(c.accentText) ? fill : c.accentText;
      final lo = l(fill) > l(c.accentText) ? c.accentText : fill;
      final ratio = (l(hi) + .05) / (l(lo) + .05);
      expect(ratio, greaterThanOrEqualTo(4.5), reason: '$theme $ratio');
    });
  }

  testWidgets('320 dp at 2x: the address stays in one word and one line', (
    tester,
  ) async {
    await loadDesignFonts();
    await openOnboarding(tester, size: const Size(320, 640), scale: 2);
    await scan(tester, lanNoPassword);
    expect(tester.takeException(), isNull);
    final title = biggestText(tester, '192.168.1.20:9119');
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: title, matching: find.byType(RichText)).first,
    );
    final plain = paragraph.text.toPlainText();
    final at = plain.indexOf('192.168.1.20:9119');
    final painter = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
      textScaler: paragraph.textScaler,
    )..layout(maxWidth: paragraph.size.width);
    final tops = painter
        .getBoxesForSelection(
          TextSelection(baseOffset: at, extentOffset: at + 17),
        )
        .map((b) => b.top.round())
        .toSet();
    expect(tops, hasLength(1), reason: 'the address is split: $tops');
  });

  testWidgets('Connect by hand: Connect sits under the fields, keyboard '
      'closed, and keeps its height', (tester) async {
    await _manual(tester);
    final gap =
        rectOf(tester, 'manual-connect').top -
        rectOf(tester, 'manual-password').bottom;
    expect(gap, inInclusiveRange(24, 40));
  });

  testWidgets('the welcome brings the mark close to its title', (tester) async {
    await loadDesignFonts();
    final s = await openOnboarding(tester);
    final mark = rectOf(tester, 'console-mark');
    final title = tester.getRect(find.text(s.o2WelcomeTitle).first);
    final gap = title.top - mark.bottom;
    expect(gap, inInclusiveRange(85, 100), reason: '$gap');
    for (final (size, scale) in [
      (const Size(320, 640), 1.0),
      (const Size(320, 640), 2.0),
    ]) {
      await openOnboarding(tester, size: size, scale: scale);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('the sheet under the camera reaches the edge, dark and light', (
    tester,
  ) async {
    for (final theme in ['console', 'console-light']) {
      await openOnboarding(tester, theme: theme);
      await tester.tap(find.byKey(const ValueKey('onboarding-scan')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      final panel = tester.getRect(find.byKey(const ValueKey('qr-help-panel')));
      expect(panel.bottom, 844, reason: theme);
    }
  });
}
