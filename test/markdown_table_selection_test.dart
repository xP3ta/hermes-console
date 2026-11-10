// A table is drawn the same way while its reply streams and once the reply
// has finished, and a finished one is selected and copied through the
// message's own selection region, like the rest of the message.
//
// Selectable cells (SelectableText) reserve a line as tall as the ambient
// text style and room for a caret, so a table that switched to them when
// its reply finished grew taller at that moment and pushed the text below.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat/chat_message_frame.dart';
import 'package:hermes_android/core/widgets/chat/live_reply_reveal.dart';
import 'package:hermes_android/core/widgets/markdown_table.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const List<List<String>> _rows = [
  ['Servicio', 'Estado'],
  ['Pasarela', 'activa'],
  [
    'Notificaciones',
    'Retrasadas por la cola de reintentos del servidor de avisos, '
        'se revisan mañana a primera hora',
  ],
];

const List<List<String>> _narrowRows = [
  ['Servicio', 'Estado'],
  ['Pasarela', 'activa'],
];

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 360, child: child),
    ),
  ),
);

Widget _bodyHost(Widget child) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('es'),
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 360, child: child),
    ),
  ),
);

Finder _inTable(Type type) => find.descendant(
  of: find.byType(MarkdownTable),
  matching: find.byType(type),
);

void main() {
  setUpAll(warmLiveReplyShader);

  testWidgets('a finished table is as tall as the live one', (tester) async {
    await tester.pumpWidget(
      _host(
        const ChatMessageFrame(
          selectable: false,
          children: [
            LiveReplyReveal(
              revision: 'live',
              child: MarkdownTable(rows: _rows),
            ),
          ],
        ),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final live = tester.getSize(find.byType(MarkdownTable)).height;

    await tester.pumpWidget(
      _host(const ChatMessageFrame(children: [MarkdownTable(rows: _rows)])),
    );
    await tester.pump();
    final finished = tester.getSize(find.byType(MarkdownTable)).height;

    expect(finished, closeTo(live, 1), reason: 'live table: $live');
    expect(_inTable(EditableText), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // A table wider than the message scrolls sideways: its cells reach the
  // message's selection through the scroll view, one frame later.
  for (final (name, rows) in [
    ('that fits', _narrowRows),
    ('that scrolls sideways', _rows),
  ]) {
    testWidgets('a finished table $name is copied with its message', (
      tester,
    ) async {
      String? copied;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        _host(
          ChatMessageFrame(
            children: [
              const Text('Resumen de hoy'),
              MarkdownTable(rows: rows),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final region = tester.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      region.selectAll();
      await tester.pump();
      Actions.invoke(
        tester.element(find.text('Resumen de hoy')),
        CopySelectionTextIntent.copy,
      );
      await tester.pump();

      expect(copied, isNotNull);
      for (final cell in [
        'Resumen de hoy',
        for (final row in rows) ...row.map((cell) => cell.split(',').first),
      ]) {
        expect(copied, contains(cell));
      }
      expect(tester.takeException(), isNull);
    });
  }

  // A subagent's live stream draws its tail with ChatMarkdownBody, whose
  // region only arrives once the block stops streaming, with no reveal
  // around it: the table is drawn the same way in both states, and the
  // finished one is still copied through the message's region.
  testWidgets('a streaming ChatMarkdownBody table is drawn like the '
      'finished one', (tester) async {
    String? copied;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    const data =
        'Resumen de hoy\n\n'
        '| Servicio | Estado |\n'
        '| --- | --- |\n'
        '| Pasarela | activa |\n'
        '| Notificaciones | retrasadas por la cola de reintentos |\n'
        '| Copias | al día |\n';

    await tester.pumpWidget(
      _bodyHost(const ChatMarkdownBody(data: data, isStreaming: true)),
    );
    await tester.pump();
    expect(find.byType(MarkdownTable), findsOneWidget);
    expect(_inTable(EditableText), findsNothing, reason: 'streaming');
    expect(find.text('Pasarela'), findsOneWidget);
    final live = tester.getSize(find.byType(MarkdownTable)).height;

    await tester.pumpWidget(_bodyHost(const ChatMarkdownBody(data: data)));
    await tester.pump();
    await tester.pump();
    expect(_inTable(EditableText), findsNothing, reason: 'finished');
    final finished = tester.getSize(find.byType(MarkdownTable)).height;
    expect(finished, closeTo(live, 0.5), reason: 'live table: $live');

    final region = tester.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    region.selectAll();
    await tester.pump();
    Actions.invoke(
      tester.element(find.text('Pasarela')),
      CopySelectionTextIntent.copy,
    );
    await tester.pump();
    expect(copied, isNotNull);
    for (final cell in ['Resumen de hoy', 'Servicio', 'Pasarela', 'al día']) {
      expect(copied, contains(cell));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a table outside any selection region keeps selectable cells', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const MarkdownTable(rows: _rows)));
    expect(_inTable(SelectableText), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
