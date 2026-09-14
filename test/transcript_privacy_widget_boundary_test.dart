import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';

void main() {
  testWidgets('terminal sealed literal reaches MarkdownBody byte-exactly', (
    tester,
  ) async {
    const literal = 'PUBLIC <｜start｜>not an envelope';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AssistantMarkdownView(data: literal)),
      ),
    );
    final data = tester.widgetList<MarkdownBody>(find.byType(MarkdownBody));
    final rendered = data.map((widget) => widget.data).join();
    expect(rendered.codeUnits, literal.codeUnits);
    expect(utf8.encode(rendered), utf8.encode(literal));
  });

  testWidgets(
    'streaming and terminal private-open bodies stay outside widgets',
    (tester) async {
      const privateOpen =
          '<｜channel｜>analysis<｜message｜>PRIVATE_WIDGET_BOUNDARY';
      for (final streaming in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AssistantMarkdownView(
                data: privateOpen,
                isStreaming: streaming,
              ),
            ),
          ),
        );
        final rendered = tester
            .widgetList<MarkdownBody>(find.byType(MarkdownBody))
            .map((widget) => widget.data)
            .join();
        expect(rendered, isNot(contains('PRIVATE_WIDGET_BOUNDARY')));
      }
    },
  );
}
