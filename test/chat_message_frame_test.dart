import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat/chat_message_frame.dart';
import 'package:hermes_android/core/widgets/chat/chat_message_selection_area.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('es'),
  theme: AppTheme.hermesRedDark,
  home: Scaffold(body: SizedBox(width: 360, child: child)),
);

void main() {
  testWidgets('ChatMessageFrame compone cabecera, cuerpo y hora', (
    tester,
  ) async {
    final time = formatChatMessageTime(1700000000)!;
    await tester.pumpWidget(
      _host(
        ChatMessageFrame(
          header: const ChatMessageHeader(
            name: 'coder bot',
            avatar: SizedBox(key: ValueKey('face')),
            nameColor: Colors.teal,
          ),
          time: time,
          children: const [
            ChatMarkdownBody(data: 'Hola **equipo**', selectable: false),
          ],
        ),
      ),
    );

    expect(find.byKey(const ValueKey('face')), findsOneWidget);
    final name = tester.widget<Text>(
      find.byKey(const ValueKey('assistant-header-name')),
    );
    expect(name.data, 'Coder Bot');
    expect(name.style?.color, Colors.teal);
    expect(find.text(time), findsOneWidget);
    expect(find.byType(ChatMessageSelectionArea), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('sin avatar no hay hueco: el nombre empieza donde el cuerpo', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ChatMessageFrame(
          header: ChatMessageHeader(name: 'hermes'),
          selectable: false,
          children: [Text('cuerpo')],
        ),
      ),
    );
    expect(find.byKey(const ValueKey('assistant-avatar-slot')), findsNothing);
    expect(
      find.byKey(const ValueKey('assistant-avatar-initial')),
      findsNothing,
    );
    final name = tester.widget<Text>(
      find.byKey(const ValueKey('assistant-header-name')),
    );
    expect(name.data, 'Hermes');
    expect(name.style?.color, AppTheme.hermesRedDark.hermes.accent);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('assistant-header-name'))).dx,
      tester.getTopLeft(find.text('cuerpo')).dx,
    );
    expect(find.byType(SelectionArea), findsNothing);
  });

  testWidgets('ChatCopyMessageButton copia el texto plano', (tester) async {
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
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      _host(
        ChatMessageFrame(
          header: ChatMessageHeader(
            name: 'hermes',
            actions: [ChatCopyMessageButton(text: () => 'texto plano')],
          ),
          children: const [Text('cuerpo')],
        ),
      ),
    );
    await tester.tap(find.byTooltip('Copiar mensaje'));
    await tester.pump();
    expect(copied, 'texto plano');
    await tester.pump(const Duration(seconds: 2));
  });

  test('formatChatMessageTime acepta segundos, milisegundos y texto', () {
    final seconds = formatChatMessageTime(1700000000);
    expect(seconds, isNotNull);
    expect(formatChatMessageTime(1700000000000), seconds);
    expect(formatChatMessageTime('1700000000'), seconds);
    expect(formatChatMessageTime(0), isNull);
    expect(formatChatMessageTime('x'), isNull);
    expect(formatChatMessageTime(null), isNull);
  });
}
