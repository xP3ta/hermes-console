import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/interactive_prompt_reducer.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/interactive_prompt_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// Ola 5 (AUDITORIA-PULIDO §2.16): the clarify and approval cards, dark and
/// light, on a phone width.
///
/// Regenerate on the reference engine, never on a developer machine:
///   flutter test --update-goldens test/ola5_request_cards_golden_test.dart
void main() {
  Widget host(Widget child, {required bool dark}) => MaterialApp(
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    locale: const Locale('es'),
    debugShowCheckedModeBanner: false,
    theme: AppTheme.fromMode(dark ? AppThemeMode.dark : AppThemeMode.light),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 392,
          child: RepaintBoundary(key: const ValueKey('golden'), child: child),
        ),
      ),
    ),
  );

  final key = InteractivePromptKey(
    runtimeSessionId: 'runtime-golden',
    requestId: 'srq-golden000001',
  );
  final clarify = InteractivePromptCard(
    entry: InteractivePromptEntry(
      key: key,
      request: ClarifyPromptRequest(
        key: key,
        questions: const [
          ClarifyQuestion(
            qid: 'q0',
            question: '¿Subo los cambios a main?',
            choices: ['Sí, súbelos (Recommended)', 'Todavía no'],
          ),
        ],
      ),
      status: InteractivePromptStatus.pending,
    ),
    busy: false,
    onSubmit: (_) {},
    onSubmitBatch: (_) {},
    onCancel: () {},
    onSkip: () {},
  );
  final approval = ChatApprovalCard(
    approval: const {
      'command': 'git push origin release/1.4.0',
      'description': 'git push',
      'choices': ['once', 'session', 'always', 'deny'],
    },
    busy: false,
    onChoice: (_) {},
  );

  for (final dark in [true, false]) {
    final mode = dark ? 'dark' : 'light';
    testWidgets('clarify card, $mode', (tester) async {
      await tester.pumpWidget(host(clarify, dark: dark));
      await tester.pump();
      await expectLater(
        find.byKey(const ValueKey('golden')),
        matchesGoldenFile('goldens/ola5_clarify_$mode.png'),
      );
    });

    testWidgets('approval card, $mode', (tester) async {
      await tester.pumpWidget(host(approval, dark: dark));
      await tester.pump();
      await expectLater(
        find.byKey(const ValueKey('golden')),
        matchesGoldenFile('goldens/ola5_approval_$mode.png'),
      );
    });
  }
}
