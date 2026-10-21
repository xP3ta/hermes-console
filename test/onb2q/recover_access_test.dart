// SPDX-License-Identifier: GPL-3.0-only
// Q2: «I don't know the password» leads to one plain page that hands over the
// new-access line of each system, with Copy and Send, and nothing else.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/recover_access_page.dart';
import 'package:hermes_android/core/services/hermes_setup_commands.dart';
import 'package:hermes_android/core/services/official_dashboard_command.dart';
import 'package:hermes_android/core/widgets/dashboard_sign_in_event.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _unix =
    'curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/'
    'hermes-dashboard-setup.sh | sh -s -- --new-access';
const _windows =
    '& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/'
    'hermes-setup/main/hermes-dashboard-setup.ps1))) -NewAccess';

Future<void> _page(WidgetTester tester, {String locale = 'en'}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(locale),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: const RecoverAccessPage(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('the command of each system is exactly the expected line', () {
    expect(newAccessCommand(SetupHostSystem.unix), _unix);
    expect(newAccessCommand(SetupHostSystem.windows), _windows);
    for (final c in [_unix, _windows]) {
      expect(c, isNot(contains('sudo')));
      expect(c, isNot(contains('0.0.0.0')));
    }
    expect(newAccessCommand(SetupHostSystem.unix), contains('--new-access'));
    expect(newAccessCommand(SetupHostSystem.windows), contains('-NewAccess'));
    expect(
      newAccessCommand(SetupHostSystem.unix),
      isNot(equals(newAccessCommand(SetupHostSystem.windows))),
    );
  });

  test('the setup URL lives in one constant, nowhere else in lib', () {
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final t = f.readAsStringSync();
      if (t.contains('hermes-dashboard-setup')) hits.add(f.path);
      if (t.contains('--new-access') || t.contains('-NewAccess')) {
        hits.add(f.path);
      }
    }
    expect(hits.toSet(), {'lib/core/services/official_dashboard_command.dart'});
    expect(kHermesSetupRef, 'main');
  });

  testWidgets(
    'Copy puts the exact line of the chosen system on the clipboard',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _page(tester);
      expect(
        tester
            .widget<SelectableText>(
              find.descendant(
                of: find.byKey(const ValueKey('recover-access-command')),
                matching: find.byType(SelectableText),
              ),
            )
            .data,
        _unix,
      );
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(copied, _unix);

      await tester.tap(find.text('Windows'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(copied, _windows);
      expect(find.text('Open PowerShell'), findsOneWidget);
    },
  );

  testWidgets('Send hands the same line to the share sheet', (tester) async {
    final shared = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/share'),
      (call) async {
        shared.add('${(call.arguments as Map)['text']}');
        return 'dev.fluttercommunity.plus/share/unavailable';
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        null,
      ),
    );
    await _page(tester, locale: 'es');
    expect(find.text('Enviar al ordenador'), findsOneWidget);
    expect(find.text('Copiar'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recover-access-send')));
    await tester.pump();
    await tester.tap(find.text('Windows'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recover-access-send')));
    await tester.pump();
    expect(shared, [_unix, _windows]);
  });

  testWidgets('the existing Hermes command stays one tap away, not repeated', (
    tester,
  ) async {
    await _page(tester);
    expect(find.text(kOfficialDashboardResetCommand), findsNothing);
    await tester.tap(find.byKey(const ValueKey('recover-access-other')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('dashboard-password-command')),
      findsOneWidget,
    );
  });

  testWidgets('the expired-session card offers it as a second action', (
    tester,
  ) async {
    late Strings s;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Builder(
          builder: (c) {
            s = Strings.of(c);
            return const SizedBox();
          },
        ),
      ),
    );
    var opened = 0;
    final event = dashboardSignInEvent(
      str: s,
      browserSession: true,
      onSignIn: () {},
      onRecover: () => opened++,
      onDismissed: () {},
    );
    expect(event.action?.label, s.s2SessionExpiredSignIn);
    expect(event.secondary?.label, s.dashboardSetupForgotPassword);
    event.secondary!.onPressed!();
    expect(opened, 1);
    final other = dashboardSignInEvent(
      str: s,
      browserSession: false,
      onSignIn: () {},
      onRecover: () {},
      onDismissed: () {},
    );
    expect(other.secondary, isNull);
  });
}
