// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// «Connected» offers the Nous Portal account when the new server lists it
// without an account: one read of the account list, a skippable offer, and
// the account page on tap. Nothing is offered by an older server, a server
// whose Nous account is already signed in, or a read-only connection.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/screens/nous_account_screen.dart';
import 'package:hermes_android/core/services/onboarding_arrival.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'c3d_support.dart';

const _offer = ValueKey('onboarding-nous-offer');

Map<String, dynamic> _nous({bool signedIn = false}) => {
  'id': 'nous',
  'name': 'Nous Portal',
  'flow': 'device_code',
  'disconnectable': true,
  'docs_url': 'https://portal.nousresearch.com',
  'status': {'logged_in': signedIn},
};

Strings _strings(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(Navigator).first));

/// Connect by hand on a server without a usable model, then back from the
/// model screen the flow opens by itself: the «Connected» screen stays.
Future<void> _toConnected(WidgetTester tester) async {
  await connectByHand(tester);
  expect(find.byType(ModelsScreen), findsOneWidget);
  Navigator.of(tester.element(find.byType(ModelsScreen))).pop();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(OnboardingArrival.reset);

  testWidgets('an unsigned Nous account is offered; the tap opens its page', (
    tester,
  ) async {
    final dash = Dash(ready: false)..oauthRows = [_nous()];
    await withDash(dash, () async {
      await _toConnected(tester);
      final s = _strings(tester);
      expect(find.text(s.nacOnboardingOffer), findsOneWidget);
      expect(find.byKey(_offer), findsOneWidget);
      // Skippable: the usual ways out are still there.
      expect(find.text(s.o2ChooseModel), findsOneWidget);
      expect(find.text(s.o2GoHome), findsOneWidget);
      expect(dash.oauthReads, greaterThanOrEqualTo(1));
      await tester.ensureVisible(find.byKey(_offer));
      await tester.tap(find.byKey(_offer));
      await tester.pumpAndSettle();
      expect(find.byType(NousAccountScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('nac-card-connect')), findsOneWidget);
      Navigator.of(tester.element(find.byType(NousAccountScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.text(s.o2SuccessTitle), findsOneWidget);
    });
  });

  for (final (name, rows) in [
    ('a signed-in account', [_nous(signedIn: true)]),
    ('an older server (404)', null),
  ]) {
    testWidgets('$name offers nothing', (tester) async {
      final dash = Dash(ready: false)..oauthRows = rows;
      await withDash(dash, () async {
        await _toConnected(tester);
        final s = _strings(tester);
        expect(find.text(s.o2ChooseModel), findsOneWidget);
        expect(find.byKey(_offer), findsNothing);
        expect(find.text(s.nacOnboardingOffer), findsNothing);
      });
    });
  }
}
