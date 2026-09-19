import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/bot_mention_roster.dart';
import 'package:hermes_android/core/widgets/chat_mention_palette.dart';

void main() {
  test(
    'caret, selection, code and IME composing suppress unsafe insertions',
    () {
      TextEditingValue value(String text, int cursor) => TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: cursor),
      );
      expect(chatMentionQuery(value('@op', 3))?.query, 'op');
      expect(chatMentionQuery(value('hey @op rest', 7))?.start, 4);
      expect(chatMentionQuery(value('a@op', 4)), isNull);
      expect(chatMentionQuery(value('@ops', 2)), isNull);
      expect(chatMentionQuery(value('`@op', 4)), isNull);
      expect(chatMentionQuery(value('```\n@op', 7)), isNull);
      expect(
        chatMentionQuery(
          value(
            '@op',
            3,
          ).copyWith(composing: const TextRange(start: 1, end: 3)),
        ),
        isNull,
      );
      expect(
        chatMentionQuery(
          value('@op', 3).copyWith(
            selection: const TextSelection(baseOffset: 1, extentOffset: 3),
          ),
        ),
        isNull,
      );
    },
  );

  testWidgets(
    'palette offers only resolvable other bots, filters and inserts without focus loss',
    (tester) async {
      final roster = BotMentionRoster();
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(() {
        controller.dispose();
        focus.dispose();
        roster.dispose();
      });
      roster.replace('local', 'Local', [const AgentProfile(name: 'default')]);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                ChatMentionPalette(
                  controller: controller,
                  focusNode: focus,
                  connectionId: 'local',
                  profile: 'default',
                  roster: roster,
                ),
                TextField(controller: controller, focusNode: focus),
              ],
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '@');
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-mention-palette')), findsNothing);
      roster.replace('local', 'Local', [
        const AgentProfile(name: 'default'),
        const AgentProfile(
          name: 'ops',
          botModeUiMeta: {'title': 'Research Buddy'},
        ),
        const AgentProfile(name: 'writer'),
      ]);
      await tester.pump();
      expect(find.text('@ops · Research Buddy'), findsOneWidget);
      expect(find.text('@writer'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'hey @res rest');
      controller.selection = const TextSelection.collapsed(offset: 8);
      await tester.pump();
      expect(find.text('@writer'), findsNothing);
      await tester.tap(find.text('@ops · Research Buddy'));
      await tester.pump();
      expect(controller.text, 'hey @ops  rest');
      expect(controller.selection.extentOffset, 9);
      expect(focus.hasFocus, isTrue);
      expect(find.byKey(const ValueKey('chat-mention-palette')), findsNothing);
      controller.value = const TextEditingValue(
        text: '@op',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 1, end: 3),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-mention-palette')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'ambiguous handles are not suggestions and stale chips revalidate',
    (tester) async {
      final roster = BotMentionRoster();
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(() {
        controller.dispose();
        focus.dispose();
        roster.dispose();
      });
      roster.replace('local', '', [const AgentProfile(name: 'ops')]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ChatMentionPalette(
                  controller: controller,
                  focusNode: focus,
                  connectionId: 'local',
                  profile: 'default',
                  roster: roster,
                ),
                TextField(controller: controller, focusNode: focus),
              ],
            ),
          ),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
        ),
      );
      await tester.enterText(find.byType(TextField), '@');
      await tester.pump();
      roster.replace('remote', '', [
        const AgentProfile(name: 'other', mentionHandle: 'ops'),
      ]);
      // The old rendered chip is no longer an unambiguous identity.
      await tester.tap(find.text('@ops'));
      expect(controller.text, '@');
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-mention-palette')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
