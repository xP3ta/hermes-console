// SPDX-License-Identifier: GPL-3.0-only
// S2: the chat banner for a browser session that ended says so in both
// languages and carries a Sign in action; a non-browser connection keeps the
// existing notice, with no action.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/dashboard_sign_in_event.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Future<Strings> _strings(WidgetTester tester, Locale locale) async {
  late Strings s;
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Builder(
        builder: (context) {
          s = Strings.of(context);
          return const SizedBox();
        },
      ),
    ),
  );
  return s;
}

void main() {
  testWidgets('browser session: expired line, body and a Sign in action', (
    tester,
  ) async {
    for (final (locale, line, body, label) in [
      (
        const Locale('es'),
        'Sesión caducada · Iniciar sesión',
        'Tu sesión en este Hermes ha caducado. Entra de nuevo con el navegador.',
        'Iniciar sesión',
      ),
      (
        const Locale('en'),
        'Session expired · Sign in',
        'Your session on this Hermes has expired. Sign in again with your browser.',
        'Sign in',
      ),
    ]) {
      final str = await _strings(tester, locale);
      var pressed = 0;
      final event = dashboardSignInEvent(
        str: str,
        browserSession: true,
        onSignIn: () => pressed++,
        onDismissed: () {},
      );
      expect(event.line, line);
      expect(event.more, body);
      expect(event.action?.label, label);
      expect(event.action?.closes, isFalse, reason: 'stays until signed in');
      event.action!.onPressed!();
      expect(pressed, 1);
    }
  });

  testWidgets('any other connection keeps the existing notice, no action', (
    tester,
  ) async {
    final str = await _strings(tester, const Locale('en'));
    final event = dashboardSignInEvent(
      str: str,
      browserSession: false,
      onSignIn: () {},
      onDismissed: () {},
    );
    expect(event.line, str.islandSignIn);
    expect(event.more, str.chaDesktopAuthRequiredBanner);
    expect(event.action, isNull);
  });
}
