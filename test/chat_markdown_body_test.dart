import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat/chat_message_selection_area.dart';
import 'package:hermes_android/core/widgets/markdown_table.dart';
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

TextStyle? _leafStyle(WidgetTester tester, String leafText) {
  TextStyle? found;
  void visit(InlineSpan span, TextStyle? inherited) {
    if (span is! TextSpan || found != null) return;
    final effective = inherited == null
        ? span.style
        : inherited.merge(span.style);
    if ((span.text ?? '').contains(leafText)) {
      found = effective ?? const TextStyle();
      return;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child, effective);
    }
  }

  for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
    visit(widget.text, null);
    if (found != null) break;
  }
  return found;
}

void main() {
  const markdown = '''
## Título

Texto con `inline` y un [enlace](https://example.com).

- uno
- dos

```python
print("hola")
```

| A | B |
| --- | --- |
| 1 | 2 |
''';

  testWidgets('ChatMarkdownBody pinta un String sin ActiveChat', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const ChatMarkdownBody(data: markdown)));
    final colors = AppTheme.hermesRedDark.hermes;

    expect(_leafStyle(tester, 'Título')?.fontSize, 16.5);
    expect(_leafStyle(tester, 'inline')?.fontFamily, 'JetBrainsMono');
    expect(_leafStyle(tester, 'enlace')?.color, colors.secondary);
    expect(find.text('•'), findsNWidgets(2));
    expect(find.text('python'), findsOneWidget);
    expect(find.byType(MarkdownTable), findsOneWidget);
    expect(find.byType(ChatMessageSelectionArea), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('ChatMarkdownBody en streaming no activa la selección', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const ChatMarkdownBody(data: 'Hola **mundo', isStreaming: true)),
    );
    expect(find.byType(ChatMessageSelectionArea), findsOneWidget);
    expect(find.byType(SelectionArea), findsNothing);
    expect(find.textContaining('**'), findsNothing);
  });

  testWidgets('ChatMarkdownBody delega los enlaces en onLinkTap', (
    tester,
  ) async {
    String? tapped;
    await tester.pumpWidget(
      _host(
        ChatMarkdownBody(
          data: '[abrir](https://example.com/x)',
          selectable: false,
          onLinkTap: (href) => tapped = href,
        ),
      ),
    );
    expect(find.byType(ChatMessageSelectionArea), findsNothing);
    await tester.tap(find.textContaining('abrir'));
    expect(tapped, 'https://example.com/x');
  });

  testWidgets('ChatMarkdownBody vacío no ocupa espacio', (tester) async {
    await tester.pumpWidget(_host(const ChatMarkdownBody(data: '   ')));
    expect(find.byType(ChatMarkdownBlock), findsNothing);
  });

  testWidgets('ChatMarkdownBody keeps TeX source out of emphasis parsing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ChatMarkdownBody(
          data: r'Sea $a_1 * b_2$ y cuesta $5 and $10.',
          selectable: false,
        ),
      ),
    );
    expect(_leafStyle(tester, 'a_1 * b_2')?.fontFamily, 'JetBrainsMono');
    expect(find.textContaining(r'$5 and $10'), findsOneWidget);
  });
}
