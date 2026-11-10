// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// The chat's model sheet offers the way to a Nous Portal account only when
// nothing in it can be picked, on the page the person lands on, and never
// when the host has no such way (a read-only connection).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/model_provider.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/session_model_sheet.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _nous = ModelProvider(
  slug: 'nous',
  name: 'Nous Portal',
  isCurrent: false,
  authenticated: false,
  authType: 'oauth_device_code',
  oauthProviderId: 'nous',
  keyEnv: '',
  warning: '',
  models: ['hermes-5'],
);

Future<void> _pump(
  WidgetTester tester, {
  required bool usable,
  VoidCallback? onConnect,
  double textScale = 1,
  Locale locale = const Locale('en'),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 1400);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SessionModelSheetBody(
            providers: const [_nous],
            isSelected: (_, _) => false,
            isSelectedProvider: (_) => false,
            cardInfo: (_, _) => SessionModelCardInfo(usable: usable),
            modelLabel: (id) => id,
            onPick: (_, _) {},
            reasoning: null,
            reasoningSupported: false,
            onReasoning: null,
            fastMode: null,
            fastSupported: false,
            onFastMode: null,
            onConnectAccount: onConnect,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  final row = find.byKey(const ValueKey('model-sheet-connect-account-one'));
  final button = find.byKey(
    const ValueKey('model-sheet-connect-account-button'),
  );

  testWidgets('nothing usable: the way to an account is on the first page', (
    tester,
  ) async {
    var taps = 0;
    await _pump(tester, usable: false, onConnect: () => taps++);
    expect(row, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    expect(taps, 1);
  });

  testWidgets('a usable model: no offer', (tester) async {
    await _pump(tester, usable: true, onConnect: () {});
    expect(row, findsNothing);
    expect(button, findsNothing);
  });

  testWidgets('a host without the way (read-only): no offer', (tester) async {
    await _pump(tester, usable: false);
    expect(row, findsNothing);
  });

  for (final locale in Strings.supportedLocales) {
    testWidgets('fits at 2x · ${locale.languageCode}', (tester) async {
      await _pump(
        tester,
        usable: false,
        onConnect: () {},
        textScale: 2,
        locale: locale,
      );
      expect(row, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
