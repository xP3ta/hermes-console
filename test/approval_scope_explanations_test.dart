import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/runs_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// Wording mirrors the server: `once` persists nothing, `session` adds the
/// pattern to an in-memory per-session set cleared when the session ends,
/// `always` also writes `command_allowlist` in config.yaml (and Console keeps
/// its own copy in Settings › Permissions / Approvals).
const _expected = {
  'es': (
    once: 'Solo esta llamada.',
    session:
        'Este tipo de comando en este chat, hasta que el chat termine o el '
        'servidor se reinicie.',
    always:
        'Este tipo de comando en todos los chats. Se guarda en el servidor '
        '(command_allowlist de config.yaml) y en Ajustes › Permisos / '
        'Aprobaciones; para retirarlo, quítalo de ambos sitios.',
  ),
  'en': (
    once: 'Only this call.',
    session:
        'This kind of command in this chat, until the chat ends or the '
        'server restarts.',
    always:
        'This kind of command in every chat. Saved on the server '
        '(command_allowlist in config.yaml) and in Settings › Permissions / '
        'Approvals; to withdraw it, remove it from both.',
  ),
};

Widget _host(String locale, Widget child) => MaterialApp(
  locale: Locale(locale),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromMode(AppThemeMode.dark),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

const _approval = {'command': 'rm -rf /tmp/build', 'description': 'terminal'};

void main() {
  for (final locale in _expected.keys) {
    final want = _expected[locale]!;

    testWidgets('chat approval card explains every scope ($locale)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          locale,
          ChatApprovalCard(approval: _approval, busy: false, onChoice: (_) {}),
        ),
      );
      await tester.pump();

      expect(find.byTooltip(want.once), findsOneWidget);
      expect(find.byTooltip(want.session), findsOneWidget);
      expect(find.byTooltip(want.always), findsOneWidget);
    });

    testWidgets('run approval block explains every scope ($locale)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          locale,
          RunApprovalDecisionBlock(
            approval: _approval,
            busy: false,
            readOnly: false,
            allowAlways: true,
            onChoice: (_) {},
            onAlways: () {},
          ),
        ),
      );
      await tester.pump();

      expect(find.byTooltip(want.once), findsOneWidget);
      expect(find.byTooltip(want.session), findsOneWidget);
      expect(find.byTooltip(want.always), findsOneWidget);
    });
  }

  testWidgets('a scope the server does not offer has no explanation', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        'es',
        ChatApprovalCard(
          approval: const {..._approval, 'allow_permanent': false},
          busy: false,
          onChoice: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip(_expected['es']!.session), findsOneWidget);
    expect(find.byTooltip(_expected['es']!.always), findsNothing);
  });

  test('scope explanation keys exist in both ARB files', () {
    const keys = [
      'apx1215ScopeOnceHint',
      'apx1215ScopeSessionHint',
      'apx1215ScopeAlwaysHint',
    ];
    for (final file in ['lib/l10n/app_es.arb', 'lib/l10n/app_en.arb']) {
      final arb = jsonDecode(File(file).readAsStringSync()) as Map;
      for (final key in keys) {
        expect(arb[key], isA<String>(), reason: '$key in $file');
        expect((arb[key] as String).trim(), isNotEmpty);
      }
    }
  });
}
