import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_pinned_prompt_header.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets(
    'the round prompt arrow retains per-chat hide and its accessible action',
    (tester) async {
      var hidden = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromMode(AppThemeMode.dark),
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            body: Center(
              child: ChatPinnedPromptHeader(
                youLabel: 'Tú',
                text: 'El mensaje',
                attachmentCount: 2,
                semanticLabel: 'Tu mensaje',
                hideLabel: 'Ocultar',
                onTap: () {},
                onHide: () => hidden++,
              ),
            ),
          ),
        ),
      );
      final arrow = find.byKey(const ValueKey('chat-jump-to-prompt'));
      expect(tester.getSize(arrow), const Size(48, 48));
      await tester.longPress(arrow);
      expect(
        hidden,
        1,
        reason: 'hiding survives the replacement of the × by the arrow',
      );
      final semantics = tester.ensureSemantics();
      try {
        final node = tester.getSemantics(find.byType(ChatPinnedPromptHeader));
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.longPress),
          isTrue,
        );
        expect(node.label, contains('2'));
      } finally {
        semantics.dispose();
      }
    },
  );
}
