// pt1215: copy scopes on the assistant copy action (Desktop
// `assistant-message.tsx` «Copy full response» + per-message copy).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/markdown_clipboard.dart';
import 'package:hermes_android/core/widgets/chat/chat_message_frame.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  String? clipboard;
  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });

  test('code blocks keep their literal text; inline code is not a block', () {
    expect(
      markdownCodeBlocks(
        'Run `ls` then:\n\n```sh\necho 1\necho 2\n```\n\ntext\n\n~~~\nx\n~~~',
      ),
      ['echo 1\necho 2', 'x'],
    );
    expect(markdownCodeBlocks('only `inline` code'), isEmpty);
  });

  testWidgets('tap copies the default; long press lists the scopes', (
    tester,
  ) async {
    var built = 0;
    await tester.pumpWidget(
      _host(
        ChatCopyMessageButton(
          text: () => 'DEFAULT',
          scopes: () {
            built++;
            return [
              ChatCopyScope(
                label: 'One',
                icon: Icons.copy_rounded,
                text: () => 'ONE',
              ),
              ChatCopyScope(
                label: 'Two',
                icon: Icons.code_rounded,
                text: () => 'TWO',
              ),
            ];
          },
        ),
      ),
    );
    // Scopes are not computed while building.
    expect(built, 0);
    await tester.tap(find.byType(ChatCopyMessageButton));
    await tester.pump(const Duration(seconds: 2));
    expect(clipboard, 'DEFAULT');

    await tester.longPress(find.byType(ChatCopyMessageButton));
    await tester.pumpAndSettle();
    expect(built, 1);
    expect(find.byKey(const ValueKey('chat-copy-scopes')), findsOneWidget);
    await tester.tap(find.text('Two'));
    await tester.pumpAndSettle();
    expect(clipboard, 'TWO');
  });

  testWidgets('without scopes a long press opens no menu', (tester) async {
    await tester.pumpWidget(_host(ChatCopyMessageButton(text: () => 'X')));
    await tester.longPress(find.byType(ChatCopyMessageButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-copy-scopes')), findsNothing);
  });
}
