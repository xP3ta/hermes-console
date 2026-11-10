import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_mention_chips.dart';
import 'package:hermes_android/core/bots/ui/room/room_mentions.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat/mention_chips.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'room_fixtures.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.fromMode(AppThemeMode.dark),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: child),
);

List<String> _chips(WidgetTester tester) => [
  for (final chip in tester.widgetList<MentionChip>(find.byType(MentionChip)))
    chip.text,
];

void main() {
  group('room (Desktop classifyGroupMention)', () {
    late List<HostedGroupMember> members;
    setUp(() => members = buildRoom().members);

    Future<List<String>> pumpRoom(
      WidgetTester tester,
      String data, {
      void Function(String handle)? onOpen,
      List<String> openable = const ['builder'],
    }) async {
      await tester.pumpWidget(
        _app(
          MentionChipScope(
            resolver: RoomMentionChips(
              members: members,
              profileFor: (m) => m.handle == 'builder'
                  ? const AgentProfile(name: 'builder')
                  : null,
              avatarCache: null,
              openable: openable,
              onOpen: onOpen,
            ),
            child: ChatMarkdownBody(data: data, selectable: false),
          ),
        ),
      );
      await tester.pump();
      return _chips(tester);
    }

    testWidgets('members, the human and the whole room', (tester) async {
      final chips = await pumpRoom(
        tester,
        '@builder y @Radar, @all, esperad a @user, @nobody no.',
      );
      expect(chips, ['@builder', '@Radar', '@all', '@user']);
      final kinds = [
        for (final c in tester.widgetList<MentionChip>(
          find.byType(MentionChip),
        ))
          c.target.kind,
      ];
      expect(kinds, [
        MentionChipKind.agent,
        MentionChipKind.agent,
        MentionChipKind.broadcast,
        MentionChipKind.human,
      ]);
    });

    testWidgets('a chip exactly when routing reads the handle (#8)', (
      tester,
    ) async {
      // The room's routing (hosted_room_discussion.py resolve_mentions)
      // does not trim punctuation: `@builder.` is the unknown `builder.`,
      // and the composer warns about it. No chip either.
      const text = 'Pregunta a @builder. Y a @review: ya';
      final chips = await pumpRoom(tester, text);
      expect(chips, isEmpty);
      final members = [for (final m in buildRoom().members) m.handle];
      expect(firstUnknownRoomMention(text, members), 'builder.');
      // Followed by a space or a comma it is the member, for both.
      expect(await pumpRoom(tester, 'a @builder, y @review ya'), [
        '@builder',
        '@review',
      ]);
      expect(
        firstUnknownRoomMention('a @builder, y @review ya', members),
        isNull,
      );
    });

    testWidgets('no chips in e-mail, paths, links or code', (tester) async {
      final chips = await pumpRoom(
        tester,
        'mail a@builder.dev, ruta /srv/@builder, `@builder`, '
        '[@builder](https://x.example)\n\n```\n@builder\n```',
      );
      expect(chips, isEmpty);
    });

    testWidgets('only a member Console can open takes a tap', (tester) async {
      final opened = <String>[];
      await pumpRoom(tester, '@builder y @radar', onOpen: opened.add);
      final chips = tester
          .widgetList<MentionChip>(find.byType(MentionChip))
          .toList();
      expect(chips.first.target.onTap, isNotNull);
      expect(chips.last.target.onTap, isNull);
      await tester.tapOnText(find.textRange.ofSubstring('@builder'));
      await tester.pump();
      expect(opened, ['builder']);
    });

    testWidgets('each chip that opens is a node of its own for TalkBack', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final opened = <String>[];
        await pumpRoom(
          tester,
          'pregunta a @builder y a @review',
          onOpen: opened.add,
          openable: const ['builder', 'review'],
        );
        final chips = find.byType(MentionChip);
        // Not merged into the sentence: two taps would collide there.
        expect(
          tester.getSemantics(chips.first),
          isSemantics(
            label: 'Mención a console-builder',
            isLink: true,
            hasTapAction: true,
          ),
        );
        expect(
          tester.getSemantics(chips.last),
          isSemantics(
            label: 'Mención a console-review',
            isLink: true,
            hasTapAction: true,
          ),
        );
        tester.semantics.tap(
          find.semantics.byLabel('Mención a console-review'),
        );
        await tester.pump();
        expect(opened, ['review']);
        // The @token is never read on top of the label.
        expect(find.bySemanticsLabel(RegExp('@builder|@review')), findsNothing);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('a member\'s colour is its own, not random', (tester) async {
      await pumpRoom(tester, '@builder @review');
      final first = [
        for (final c in tester.widgetList<MentionChip>(
          find.byType(MentionChip),
        ))
          c.target.color,
      ];
      await pumpRoom(tester, '@review @builder');
      final second = [
        for (final c in tester.widgetList<MentionChip>(
          find.byType(MentionChip),
        ))
          c.target.color,
      ];
      expect(second, first.reversed.toList());
      expect(first.first, isNot(first.last));
    });
  });
}
