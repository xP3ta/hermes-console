import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat/tool_output_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('es'),
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: SingleChildScrollView(child: SizedBox(width: 360, child: child)),
  ),
);

/// Colour of the leaf span whose text equals [text] exactly.
Color? _lineColor(WidgetTester tester, String text) {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    Color? found;
    void visit(InlineSpan span, TextStyle? inherited) {
      if (span is! TextSpan || found != null) return;
      final style = inherited == null
          ? span.style
          : inherited.merge(span.style);
      if (span.text == text) {
        found = style?.color;
        return;
      }
      for (final c in span.children ?? const <InlineSpan>[]) {
        visit(c, style);
      }
    }

    visit(rich.text, null);
    if (found != null) return found;
  }
  return null;
}

void main() {
  final colors = AppTheme.hermesRedDark.hermes;

  for (final lang in ['diff', 'patch']) {
    testWidgets('```$lang fences use the tool diff renderer', (tester) async {
      const code =
          '--- a/x.dart\n+++ b/x.dart\n@@ -1,3 +1,3 @@\n'
          ' keep this line\n-removed old line\n+added new line';
      await tester.pumpWidget(
        _host(ChatMarkdownBody(data: '```$lang\n$code\n```')),
      );

      expect(find.byType(FileDiffBody), findsOneWidget);
      expect(_lineColor(tester, '-removed old line'), colors.error);
      expect(_lineColor(tester, '+added new line'), colors.success);
      expect(_lineColor(tester, ' keep this line'), colors.textSecondary);
      expect(_lineColor(tester, '@@ -1,3 +1,3 @@'), colors.textTertiary);
      // Language label and copy button stay; copy keeps the raw fence.
      expect(find.text(lang), findsOneWidget);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      await tester.tap(find.byIcon(Icons.content_copy));
      await tester.pump();
      expect(copied, code);
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('non-diff languages keep the highlighted code block', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const ChatMarkdownBody(data: '```python\n-x = 1\n+y = 2\n```')),
    );
    expect(find.byType(FileDiffBody), findsNothing);
    expect(find.text('python'), findsOneWidget);
  });

  testWidgets('huge diff fence is paged by the existing cap', (tester) async {
    final body = List.generate(2000, (i) => '+line number $i').join('\n');
    await tester.pumpWidget(
      _host(ChatMarkdownBody(data: '```diff\n$body\n```')),
    );
    expect(find.byType(FileDiffBody), findsOneWidget);
    expect(find.byKey(const ValueKey('file-diff-show-more')), findsOneWidget);
    expect(find.text('+line number ${fileDiffPageLines - 1}'), findsOneWidget);
    expect(find.text('+line number $fileDiffPageLines'), findsNothing);
  });

  testWidgets('partial streaming diff fence renders while it grows', (
    tester,
  ) async {
    const steps = [
      '```diff\n',
      '```diff\n-a',
      '```diff\n-a\n+b\n@@',
      '```diff\n-a\n+b\n@@ -1 +1 @@\n c',
    ];
    for (final s in steps) {
      await tester.pumpWidget(
        _host(ChatMarkdownBody(data: s, isStreaming: true)),
      );
      expect(tester.takeException(), isNull);
    }
    expect(find.byType(FileDiffBody), findsOneWidget);
    expect(_lineColor(tester, '-a'), colors.error);
    expect(_lineColor(tester, '+b'), colors.success);
  });
}
