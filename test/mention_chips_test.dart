import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart'
    show roomMemberColor;
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/bot_mention_roster.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/chat/bot_mention_chips.dart';
import 'package:hermes_android/core/widgets/chat/chat_link_card.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat/mention_chips.dart';
import 'package:hermes_android/core/widgets/chat/user_message_text.dart';
import 'package:hermes_android/core/widgets/mission_profile_avatar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _app(
  Widget child, {
  AppThemeMode mode = AppThemeMode.dark,
  TextDirection? direction,
  Locale locale = const Locale('es'),
}) => MaterialApp(
  theme: AppTheme.fromMode(mode),
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    body: direction == null
        ? child
        : Directionality(textDirection: direction, child: child),
  ),
);

const _ops = AgentProfile(
  name: 'ops',
  botModeUiMeta: {'title': 'Research Buddy'},
);

/// The chat's own profile (default) and two other bots of the roster.
BotMentionRoster _roster() => BotMentionRoster()
  ..replace('conn-a', 'Local', [
    const AgentProfile(name: 'default'),
    _ops,
    const AgentProfile(name: 'writer'),
  ]);

/// A 1:1 chat on conn-a showing [data].
Future<BotMentionRoster> _pumpChat(
  WidgetTester tester,
  String data, {
  BotMentionRoster? roster,
  AppThemeMode mode = AppThemeMode.dark,
  TextDirection? direction,
  bool user = false,
}) async {
  final source = roster ?? _roster();
  addTearDown(source.dispose);
  await tester.pumpWidget(
    _app(
      BotMentionChipScope(
        connectionId: 'conn-a',
        profile: '',
        roster: source,
        child: user
            ? UserMessageText(data: data)
            : ChatMarkdownBody(data: data),
      ),
      mode: mode,
      direction: direction,
    ),
  );
  await tester.pump();
  return source;
}

List<String> _chips(WidgetTester tester) => [
  for (final chip in tester.widgetList<MentionChip>(find.byType(MentionChip)))
    chip.text,
];

/// Counts every resolve (cache hits included): a re-parse resolves again.
class _CountingChips extends MentionChipResolver {
  int resolves = 0;

  @override
  RegExp get pattern => RegExp(r'(?<!\S)@([a-z0-9][a-z0-9_-]*)');

  @override
  MentionChipTarget? resolve(String token) {
    resolves += 1;
    return super.resolve(token);
  }

  @override
  MentionChipTarget? lookup(String token) => token == 'ops'
      ? const MentionChipTarget(kind: MentionChipKind.agent, name: 'Ops')
      : null;

  @override
  MentionChipTarget? lookupName(String code) => lookup(code);
}

/// The profiles of a server like the user's: ids that are also everyday
/// words («sol», «luna», «oficina»), and one whose title repeats another's
/// id (`forja` titled «Sol»), so `sol` is ambiguous as a mention form.
BotMentionRoster _team() => BotMentionRoster()
  ..replace('conn-a', 'Local', [
    const AgentProfile(name: 'default'),
    const AgentProfile(name: 'pi'),
    const AgentProfile(name: 'sol'),
    const AgentProfile(name: 'luna'),
    const AgentProfile(name: 'oficina'),
    const AgentProfile(name: 'reviewer', displayName: 'Code Reviewer'),
    const AgentProfile(name: 'studio-art'),
    const AgentProfile(name: 'forja', botModeUiMeta: {'title': 'Sol'}),
  ]);

/// A 1:1 chat of [profile] on conn-a showing [data], over [roster] (owned
/// by the test: pumped again and again as a reply streams in).
Future<void> _pumpTeam(
  WidgetTester tester,
  String data, {
  required BotMentionRoster roster,
  String profile = 'studio-art',
  Locale locale = const Locale('es'),
  AppThemeMode mode = AppThemeMode.dark,
}) async {
  await tester.pumpWidget(
    _app(
      BotMentionChipScope(
        connectionId: 'conn-a',
        profile: profile,
        roster: roster,
        child: ChatMarkdownBody(data: data),
      ),
      mode: mode,
      locale: locale,
    ),
  );
  await tester.pump();
}

/// Texts of the chips made from an id in inline code (never from `@`).
List<String> _named(WidgetTester tester) => [
  for (final chip in tester.widgetList<MentionChip>(find.byType(MentionChip)))
    if (chip.byName) chip.text,
];

void main() {
  group('1:1 chat (Bot Mode roster, Desktop resolveRosterMentions)', () {
    testWidgets('several mentions, at the start and at the end', (
      tester,
    ) async {
      await _pumpChat(tester, '@ops pregunta a @writer y a @OPS.');
      // As written (case kept), the sentence's full stop stays text.
      expect(_chips(tester), ['@ops', '@writer', '@OPS']);
      await _pumpChat(tester, 'hola @writer');
      expect(_chips(tester), ['@writer']);
    });

    testWidgets('in user messages too, beside @file: references', (
      tester,
    ) async {
      await _pumpChat(tester, 'mira @file:notes.md con @ops', user: true);
      expect(_chips(tester), ['@ops']);
      expect(
        find.byKey(const ValueKey('user-reference-chip-file')),
        findsOneWidget,
      );
    });

    testWidgets('without a roster nothing changes', (tester) async {
      await _pumpChat(
        tester,
        'pregunta a @ops',
        roster: BotMentionRoster(),
      );
      expect(find.byType(MentionChip), findsNothing);
      expect(find.textContaining('pregunta a @ops'), findsOneWidget);
    });

    testWidgets('unknown handles and the chat\'s own profile stay text', (
      tester,
    ) async {
      await _pumpChat(tester, '@nobody, @hermes y @default');
      expect(find.byType(MentionChip), findsNothing);
    });

    testWidgets('no chips in e-mail, paths, inline or fenced code', (
      tester,
    ) async {
      await _pumpChat(
        tester,
        'escribe a ana@ops.com, mira /home/@ops/x y C:\\@ops; '
        'usa `@ops` y no@ops\n\n```\n@ops en código\n```',
      );
      expect(find.byType(MentionChip), findsNothing);
      expect(find.textContaining('@ops en código'), findsOneWidget);
    });

    testWidgets('right-to-left text keeps the chip', (tester) async {
      await _pumpChat(
        tester,
        'مرحبا @ops كيف حالك',
        direction: TextDirection.rtl,
      );
      expect(_chips(tester), ['@ops']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tap does nothing, as in Desktop', (tester) async {
      await _pumpChat(tester, 'pregunta a @ops');
      final chip = tester.widget<MentionChip>(find.byType(MentionChip));
      expect(chip.target.onTap, isNull);
      await tester.tap(find.byType(MentionChip));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a roster that arrives later turns mentions into chips', (
      tester,
    ) async {
      final roster = BotMentionRoster();
      await _pumpChat(tester, 'pregunta a @ops', roster: roster);
      expect(find.byType(MentionChip), findsNothing);
      roster.replace('conn-a', 'Local', [const AgentProfile(name: 'ops')]);
      await tester.pump();
      expect(_chips(tester), ['@ops']);
    });
  });

  group('copy, accessibility and look', () {
    testWidgets('selecting and copying gives the @mention as written', (
      tester,
    ) async {
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
      await _pumpChat(tester, 'Pregunta a @ops y a @writer.');
      expect(_chips(tester), ['@ops', '@writer']);
      final region = tester.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      region.selectAll();
      // ignore: deprecated_member_use
      region.copySelection(SelectionChangedCause.keyboard);
      await tester.pump();
      expect(copied, 'Pregunta a @ops y a @writer.');
    });

    testWidgets('screen readers hear «Mención a …», not just a colour', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await _pumpChat(tester, 'pregunta a @ops y a @writer');
        // A chip without a tap reads inside its sentence: the paragraph
        // merges inline widgets into its own label, one line each, in order.
        // Exactly one node says each mention, as a line of its own.
        expect(
          find.bySemanticsLabel(
            RegExp(r'(^|\n)Mención a Research Buddy(\n|$)'),
          ),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel(RegExp(r'(^|\n)Mención a writer(\n|$)')),
          findsOneWidget,
        );
        // The sentence, in reading order, with each mention said once.
        expect(
          find.bySemanticsLabel(
            RegExp(
              r'^pregunta a\s*\nMención a Research Buddy\n\s*y a\s*\n'
              r'Mención a writer$',
            ),
          ),
          findsOneWidget,
        );
        // Never the @token as well (it would be heard twice).
        expect(find.bySemanticsLabel(RegExp('@ops|@writer')), findsNothing);
      } finally {
        semantics.dispose();
      }
    });

    for (final mode in [AppThemeMode.light, AppThemeMode.dark]) {
      testWidgets('${mode.name}: the label reads on the pill', (tester) async {
        await _pumpChat(tester, 'pregunta a @ops', mode: mode);
        final chip = find.byType(MentionChip);
        final pill = tester.widget<Container>(
          find.descendant(of: chip, matching: find.byType(Container)).first,
        );
        final background = (pill.decoration! as BoxDecoration).color!;
        final label = tester.widget<Text>(
          find.descendant(of: chip, matching: find.byType(Text)).last,
        );
        expect(
          ThemeContrast.ratio(label.style!.color!, background),
          greaterThanOrEqualTo(4.5),
        );
        // The bot's own identity colour (its face), never a random one.
        expect(
          tester.widget<MentionChip>(chip).target.color,
          roomMemberColor('ops', profile: _ops),
        );
      });
    }
  });

  group('large text (REVIEW-R5-B #6)', () {
    testWidgets('at 200 % the chip grows once, with its sentence', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: MentionChipScope(
              resolver: _CountingChips(),
              child: const ChatMarkdownBody(
                data: 'pregunta a @ops',
                selectable: false,
              ),
            ),
          ),
        ),
      );
      final chip = find.byType(MentionChip);
      expect(chip, findsOneWidget);
      // The WidgetSpan scales the chip by 2; its label must not scale again.
      final label = tester.widget<RichText>(
        find.descendant(of: chip, matching: find.byType(RichText)).last,
      );
      expect(label.textScaler.scale(14), 14);
      // The sentence around it still follows the user's text size.
      final sentence = tester.widget<RichText>(
        find
            .ancestor(of: chip, matching: find.byType(RichText))
            .first,
      );
      expect(sentence.textScaler.scale(14), 28);
      expect(tester.takeException(), isNull);
    });
  });

  group('mentions beside a link card (REVIEW-R5-B #2)', () {
    testWidgets('each text part keeps its own key: no duplicate keys', (
      tester,
    ) async {
      final chips = _CountingChips();
      Widget tree(int tick) => _app(
        MentionChipScope(
          resolver: chips,
          child: ChatMarkdownBlock(
            data:
                'Escribe a ana@x.com y a @ops\n\n'
                'https://example.com/guia\n\n'
                'O pregunta a @ops',
            embeds: tick >= 0,
          ),
        ),
      );
      await tester.pumpWidget(tree(0));
      expect(tester.takeException(), isNull);
      expect(find.byType(ChatLinkCard), findsOneWidget);
      expect(_chips(tester), ['@ops', '@ops']);
      final resolves = chips.resolves;
      // Rebuilt, not re-parsed: the keys are equal from one build to the next.
      await tester.pumpWidget(tree(1));
      expect(tester.takeException(), isNull);
      expect(chips.resolves, resolves);
    });
  });

  group('performance', () {
    testWidgets('a rebuild never parses the message again', (tester) async {
      final chips = _CountingChips();
      Widget tree(int tick) => _app(
        MentionChipScope(
          resolver: chips,
          child: Column(
            children: [
              Text('tick $tick'),
              // A new widget each time: the body rebuilds, the parse stays.
              ChatMarkdownBody(
                data: 'hola @ops y @ops',
                selectable: tick < 0,
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(tree(0));
      final afterFirst = chips.resolves;
      expect(afterFirst, greaterThan(0));
      // One lookup for two identical mentions: the cache answers the rest.
      expect(chips.lookups, 1);
      for (var i = 1; i < 5; i++) {
        await tester.pumpWidget(tree(i));
      }
      expect(chips.resolves, afterFirst);
      expect(_chips(tester), ['@ops', '@ops']);
    });

    testWidgets('a roster republished unchanged keeps the parse', (
      tester,
    ) async {
      final roster = await _pumpChat(tester, 'pregunta a @ops');
      MentionChipResolver? scoped() => tester
          .widget<MentionChipScope>(find.byType(MentionChipScope))
          .resolver;
      final before = scoped();
      expect(before, isNotNull);
      roster.replace('conn-a', 'Local', [
        const AgentProfile(name: 'default'),
        _ops,
        const AgentProfile(name: 'writer'),
      ]);
      await tester.pump();
      expect(identical(scoped(), before), isTrue);
      // A real change (a new bot) does re-resolve.
      roster.replace('conn-a', 'Local', [
        const AgentProfile(name: 'default'),
        _ops,
        const AgentProfile(name: 'writer'),
        const AgentProfile(name: 'tester'),
      ]);
      await tester.pump();
      expect(identical(scoped(), before), isFalse);
      expect(_chips(tester), ['@ops']);
    });

    testWidgets('a message without @ costs nothing', (tester) async {
      final chips = _CountingChips();
      await tester.pumpWidget(
        _app(
          MentionChipScope(
            resolver: chips,
            child: const ChatMarkdownBody(data: 'sin menciones'),
          ),
        ),
      );
      expect(chips.resolves, 0);
    });
  });

  group('an agent named by its id in inline code (the server\'s form)', () {
    BotMentionChips chips({String profile = 'studio-art'}) {
      final roster = _team();
      addTearDown(roster.dispose);
      return BotMentionChips(roster.resolver('conn-a', profile));
    }

    test('the bare id of another profile, written exactly, is the agent', () {
      final rules = chips();
      final pi = rules.resolveName('pi');
      expect(pi, isNotNull);
      expect(pi!.kind, MentionChipKind.agent);
      expect(pi.name, 'pi');
      expect(pi.onTap, isNull);
      // A profile whose id is an everyday word is still an id in backticks.
      expect(rules.resolveName('luna'), isNotNull);
      expect(rules.resolveName('oficina'), isNotNull);
      // The friendly name goes to the chip, the id names the profile.
      expect(rules.resolveName('reviewer')!.name, 'Code Reviewer');
    });

    test('only the id itself: never a mention form, a word or a command', () {
      final rules = chips();
      // `@pi` in code is code (the existing rule), as is a title's slug.
      expect(rules.resolveName('@pi'), isNull);
      expect(rules.resolveName('code-reviewer'), isNull);
      expect(rules.resolveName('codereviewer'), isNull);
      // Written otherwise than the server spells it.
      expect(rules.resolveName('Pi'), isNull);
      expect(rules.resolveName('pi '), isNull);
      expect(rules.resolveName('pi.'), isNull);
      expect(rules.resolveName('pi tiene'), isNull);
      // One character is not an id; `hermes` is the CLI as often as the bot.
      expect(rules.resolveName('p'), isNull);
      expect(rules.resolveName('hermes'), isNull);
      expect(rules.resolveName('default'), isNull);
      // Unknown, or ambiguous (`sol` is also forja's title).
      expect(rules.resolveName('nobody'), isNull);
      expect(rules.resolveName('sol'), isNull);
      // A profile's id written as a plain word is a word (the `@` form and
      // the code form are the only ones; prose is never scanned).
      expect(rules.resolveName('a pi'), isNull);
    });

    test('the chat\'s own profile is never a chip', () {
      expect(chips(profile: 'pi').resolveName('pi'), isNull);
      expect(chips(profile: 'pi').resolveName('luna'), isNotNull);
    });

    test('the same id on two connections: only the pinned handle', () {
      final roster = BotMentionRoster()
        ..replace('conn-a', 'Local', [
          const AgentProfile(name: 'default'),
          const AgentProfile(name: 'pi'),
        ])
        ..replace('conn-b', 'Remote', [const AgentProfile(name: 'pi')]);
      addTearDown(roster.dispose);
      final rules = BotMentionChips(roster.resolver('conn-a', 'default'));
      expect(rules.resolveName('pi'), isNull);
      expect(rules.resolveName('pi-conn-b'), isNotNull);
      // The @ form reads the same roster the same way.
      expect(rules.resolve('pi'), isNull);
      expect(rules.resolve('pi-conn-b'), isNotNull);
    });

    testWidgets('the sentence of a delegating reply shows the pill', (
      tester,
    ) async {
      final roster = _team();
      addTearDown(roster.dispose);
      await _pumpTeam(
        tester,
        '3. **Se lo pido a otro agente.** `pi` tiene terminal y puede '
        'hacerlo por mensaje.',
        roster: roster,
      );
      expect(_named(tester), ['pi']);
      final chip = tester.widget<MentionChip>(find.byType(MentionChip));
      // The agent's own identity colour, as the `@` chip and the roster.
      expect(
        chip.target.color,
        roomMemberColor('pi', profile: const AgentProfile(name: 'pi')),
      );
      // The pill reads at the prose's size, not the smaller code size.
      expect(chip.textStyle?.fontSize, isNot(13));
      // Its face comes from the one identity resolver of the app.
      expect(
        find.descendant(
          of: find.byType(MentionChip),
          matching: find.byType(MissionProfileAvatar),
        ),
        findsOneWidget,
      );
    });

    testWidgets('everyday words in prose stay prose, ids in code are agents', (
      tester,
    ) async {
      final roster = _team();
      addTearDown(roster.dispose);
      await _pumpTeam(
        tester,
        'Sale el sol, la luna llena y vamos a la oficina; pídeselo a pi o '
        'con pi lo tienes. `luna` y `oficina` pueden hacerlo.',
        roster: roster,
      );
      expect(_named(tester), ['luna', 'oficina']);
    });

    testWidgets('an unknown id, `@`, a phrase and the own profile stay code', (
      tester,
    ) async {
      final roster = _team();
      addTearDown(roster.dispose);
      await _pumpTeam(
        tester,
        'usa `nobody`, `@pi`, `pi tiene`, `hermes` y `studio-art`',
        roster: roster,
      );
      expect(find.byType(MentionChip), findsNothing);
      expect(find.textContaining('nobody', findRichText: true), findsWidgets);
      expect(
        find.textContaining('studio-art', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('never inside fenced code or a link', (tester) async {
      final roster = _team();
      addTearDown(roster.dispose);
      await _pumpTeam(
        tester,
        '[`pi`](https://example.com/pi) y [pregunta a @pi](https://example.com)'
        '\n\n```\npi\n```\n\n    pi\n',
        roster: roster,
      );
      expect(find.byType(MentionChip), findsNothing);
    });

    testWidgets('a user message keeps its own path: no id chips', (
      tester,
    ) async {
      final roster = _team();
      addTearDown(roster.dispose);
      await tester.pumpWidget(
        _app(
          BotMentionChipScope(
            connectionId: 'conn-a',
            profile: 'studio-art',
            roster: roster,
            child: const UserMessageText(data: 'dile a `pi` y a @luna'),
          ),
        ),
      );
      await tester.pump();
      expect(_chips(tester), ['@luna']);
      expect(_named(tester), isEmpty);
    });

    testWidgets('without a roster the code span is untouched', (tester) async {
      await tester.pumpWidget(
        _app(const ChatMarkdownBody(data: 'pregunta a `pi` ahora')),
      );
      expect(find.byType(MentionChip), findsNothing);
      expect(find.textContaining('pi', findRichText: true), findsWidgets);
    });

    testWidgets('screen readers hear «Agente pi», once, in its sentence', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final roster = _team();
        addTearDown(roster.dispose);
        await _pumpTeam(
          tester,
          'Se lo pido a otro agente. `pi` tiene terminal.',
          roster: roster,
        );
        expect(
          find.bySemanticsLabel(RegExp(r'(^|\n)Agente pi(\n|$)')),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel(
            RegExp(
              r'^Se lo pido a otro agente\.\s*\nAgente pi\n\s*tiene terminal\.$',
            ),
          ),
          findsOneWidget,
        );
        // Not a mention: nothing says «Mención a».
        expect(find.bySemanticsLabel(RegExp('Mención')), findsNothing);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('every language names the agent', (tester) async {
      final roster = _team();
      addTearDown(roster.dispose);
      for (final locale in Strings.supportedLocales) {
        final strings = await Strings.delegate.load(locale);
        final expected = strings.amcAgentChipLabel('pi');
        expect(expected, contains('pi'), reason: '$locale');
        expect(expected.trim().length, greaterThan(2), reason: '$locale');
        final semantics = tester.ensureSemantics();
        try {
          await _pumpTeam(
            tester,
            'hablo con `pi` ahora',
            roster: roster,
            locale: locale,
          );
          expect(_named(tester), ['pi'], reason: '$locale');
          expect(
            find.bySemanticsLabel(
              RegExp('(^|\n)${RegExp.escape(expected)}(\n|\$)'),
            ),
            findsOneWidget,
            reason: '$locale',
          );
        } finally {
          semantics.dispose();
        }
      }
    });

    for (final mode in [AppThemeMode.light, AppThemeMode.dark]) {
      testWidgets('${mode.name}: the id reads on the pill', (tester) async {
        final roster = _team();
        addTearDown(roster.dispose);
        await _pumpTeam(tester, 'pregunta a `pi`', roster: roster, mode: mode);
        final chip = find.byType(MentionChip);
        final pill = tester.widget<Container>(
          find.descendant(of: chip, matching: find.byType(Container)).first,
        );
        final background = (pill.decoration! as BoxDecoration).color!;
        final label = tester.widget<Text>(
          find.descendant(of: chip, matching: find.byType(Text)).last,
        );
        expect(
          ThemeContrast.ratio(label.style!.color!, background),
          greaterThanOrEqualTo(4.5),
        );
      });
    }

    testWidgets('at 200 % the pill grows once, with its sentence', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: MentionChipScope(
              resolver: _CountingChips(),
              child: const ChatMarkdownBody(
                data: 'pregunta a `ops`',
                selectable: false,
              ),
            ),
          ),
        ),
      );
      final chip = find.byType(MentionChip);
      expect(chip, findsOneWidget);
      expect(tester.widget<MentionChip>(chip).byName, isTrue);
      final label = tester.widget<RichText>(
        find.descendant(of: chip, matching: find.byType(RichText)).last,
      );
      expect(label.textScaler.scale(14), 14);
      final sentence = tester.widget<RichText>(
        find.ancestor(of: chip, matching: find.byType(RichText)).first,
      );
      expect(sentence.textScaler.scale(14), 28);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a reply streaming in never moves its line (regression)', (
      tester,
    ) async {
      final roster = _team();
      addTearDown(roster.dispose);
      // Each prefix a stream could stop at: the token half written, closed,
      // continued. The paragraph keeps one height all along (the sentence
      // is short enough for one line at the test width) and the chip, once
      // complete, stays.
      const steps = [
        'Dile a `',
        'Dile a `p',
        'Dile a `pi',
        'Dile a `pi`',
        'Dile a `pi` que',
        'Dile a `pi` que avise a @',
        'Dile a `pi` que avise a @l',
        'Dile a `pi` que avise a @luna',
        'Dile a `pi` que avise a @luna hoy',
      ];
      double? height;
      final seen = <int, List<String>>{};
      for (final (index, step) in steps.indexed) {
        await _pumpTeam(tester, step, roster: roster);
        expect(tester.takeException(), isNull, reason: step);
        final size = tester.getSize(find.byType(ChatMarkdownBody));
        height ??= size.height;
        expect(size.height, height, reason: step);
        seen[index] = _chips(tester);
      }
      expect(seen[0], isEmpty);
      expect(seen[1], isEmpty);
      expect(seen[2], isEmpty);
      expect(seen[3], ['pi']);
      expect(seen[4], ['pi']);
      expect(seen[5], ['pi']);
      expect(seen[6], ['pi']);
      expect(seen[7], ['pi', '@luna']);
      expect(seen[8], ['pi', '@luna']);
    });

    testWidgets('a message without a backtick costs nothing', (tester) async {
      final chips = _CountingChips();
      await tester.pumpWidget(
        _app(
          MentionChipScope(
            resolver: chips,
            child: const ChatMarkdownBody(data: 'sin nombres ni menciones'),
          ),
        ),
      );
      expect(chips.resolves, 0);
      expect(chips.lookups, 0);
    });
  });
}
