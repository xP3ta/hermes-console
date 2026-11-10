// CHAT-FLUIDO 6: the assistant style sheet measured its list gutter by
// parsing the whole reply again on every build (on top of MarkdownBody's own
// parse, ~30 times a second on the live tail). Text with no ordered list is
// not parsed at all, and a measured reply is not measured again.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';

Future<double> _indent(WidgetTester tester, String data) async {
  late double indent;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.hermesRedDark,
      home: Builder(
        builder: (context) {
          indent = assistantMarkdownStyleSheet(context, data).listIndent!;
          return const SizedBox();
        },
      ),
    ),
  );
  return indent;
}

void main() {
  setUp(debugClearAssistantListIndentCache);

  testWidgets('no ordered list: no parse, the bullet gutter', (tester) async {
    final plain = await _indent(tester, 'Hola.\n\n- uno\n- dos\n\n`1. no`');
    expect(debugAssistantListIndentParses, 0);
    expect(plain, greaterThanOrEqualTo(16));
  });

  testWidgets('an ordered list is parsed once, then cached', (tester) async {
    const data = '1. uno\n2. dos\n3. tres';
    final first = await _indent(tester, data);
    expect(debugAssistantListIndentParses, 1);
    final again = await _indent(tester, data);
    expect(debugAssistantListIndentParses, 1);
    expect(again, first);
  });

  testWidgets('the gutter still fits the widest ordinal', (tester) async {
    final short = await _indent(tester, '1. a\n2. b');
    final long = await _indent(
      tester,
      List.generate(12, (index) => '${index + 1}. x').join('\n'),
    );
    final started = await _indent(tester, '998. a\n999. b\n1000. c');
    expect(long, greaterThan(short));
    expect(started, greaterThan(long));
  });

  testWidgets('a list in a quote or nested is still measured', (tester) async {
    await _indent(tester, '> 1. citado\n> 2. otro');
    expect(debugAssistantListIndentParses, 1);
    await _indent(tester, '- a\n  1. dentro\n  2. otro');
    expect(debugAssistantListIndentParses, 2);
  });
}
