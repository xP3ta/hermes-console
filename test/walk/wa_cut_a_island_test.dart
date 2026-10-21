// SPDX-License-Identifier: GPL-3.0-only
// WA (CUT-A): the chat's "no server" island offers the official command page.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_status.dart';
import 'package:hermes_android/core/widgets/connection_help_action.dart';
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
  group('chat island: no server', () {
    testWidgets('flag on: «What to do» opens the command page', (tester) async {
      for (final (locale, line, label) in [
        (const Locale('es'), 'Tu Hermes no responde', 'Qué hago'),
        (const Locale('en'), "Your Hermes isn't answering", 'What to do'),
      ]) {
        final str = await _strings(tester, locale);
        var opened = 0;
        expect(
          connectionIslandLine(
            str: str,
            kind: ConnectionStatusKind.noServer,
            simpleConnect: true,
          ),
          line,
        );
        final action = connectionIslandAction(
          str: str,
          kind: ConnectionStatusKind.noServer,
          simpleConnect: true,
          onOpenHelp: () => opened++,
        );
        expect(action, isNotNull);
        expect(action!.label, label);
        expect(action.closes, isFalse, reason: 'the notice stays until fixed');
        action.onPressed!();
        expect(opened, 1);
      }
    });

    testWidgets('flag off: today\'s line, no action', (tester) async {
      final str = await _strings(tester, const Locale('en'));
      expect(
        connectionIslandLine(
          str: str,
          kind: ConnectionStatusKind.noServer,
          simpleConnect: false,
        ),
        str.connStatusNoServer,
      );
      expect(
        connectionIslandAction(
          str: str,
          kind: ConnectionStatusKind.noServer,
          simpleConnect: false,
          onOpenHelp: () {},
        ),
        isNull,
      );
    });

    testWidgets('other kinds never get the action', (tester) async {
      final str = await _strings(tester, const Locale('en'));
      for (final kind in ConnectionStatusKind.values) {
        if (kind == ConnectionStatusKind.noServer) continue;
        expect(
          connectionIslandAction(
            str: str,
            kind: kind,
            simpleConnect: true,
            onOpenHelp: () {},
          ),
          isNull,
          reason: '$kind',
        );
      }
    });
  });
}
