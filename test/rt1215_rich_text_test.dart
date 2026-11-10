// rt1215: agent text is never shown as raw Markdown. The live reasoning in
// the activity view, the finished reasoning in the chat trace and the long
// agent texts of detail pages render as compact Markdown (bold headings in
// the primary ink, body in the secondary ink); one-line previews go through
// the shared `plainPreview()` and carry no Markdown syntax at all.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_model.dart';
import 'package:hermes_android/core/design/content.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/interactive_prompt_reducer.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/home_recent_sessions.dart';
import 'package:hermes_android/core/utils/plain_preview.dart';
import 'package:hermes_android/core/widgets/activity_sections.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/core/widgets/running_work.dart';
import 'package:hermes_android/core/widgets/interactive_prompt_card.dart';
import 'package:hermes_android/core/widgets/reasoning_block.dart';
import 'package:hermes_android/core/widgets/reasoning_panel.dart';
import 'package:hermes_android/core/widgets/thinking_glyph.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final DateTime _t0 = DateTime(2026, 10, 6, 12);

const String _owner =
    '**Clarifying homelab choices**\n\n'
    'The user wants to know which `docker` host runs the '
    '[backup job](https://example.com/jobs) tonight.';

Widget _app(Widget child, {double textScale = 1}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: true,
      textScaler: TextScaler.linear(textScale),
    ),
    child: home!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(width: 360, child: child),
    ),
  ),
);

/// Every painted text run under [root] with its effective style.
List<({String text, TextStyle style})> _runs(WidgetTester tester, Finder root) {
  final out = <({String text, TextStyle style})>[];
  void walk(InlineSpan span, TextStyle inherited) {
    if (span is! TextSpan) return;
    final style = inherited.merge(span.style);
    final text = span.text;
    if (text != null && text.isNotEmpty) out.add((text: text, style: style));
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, style);
    }
  }

  for (final element
      in find
          .descendant(of: root, matching: find.byType(RichText))
          .evaluate()) {
    walk((element.widget as RichText).text, const TextStyle());
  }
  return out;
}

String _plain(WidgetTester tester, Finder root) =>
    _runs(tester, root).map((r) => r.text).join();

void _expectNoMarkdownSyntax(String text) {
  expect(text, isNot(contains('**')), reason: text);
  expect(text, isNot(contains('`')), reason: text);
  expect(text, isNot(contains('](')), reason: text);
}

void _expectHeading(WidgetTester tester, Finder root, String heading) {
  final colors = AppTheme.hermesRedDark.hermes;
  final run = _runs(tester, root).where((r) => r.text.trim() == heading);
  expect(run, isNotEmpty, reason: 'heading "$heading" as its own run');
  expect(
    run.first.style.fontWeight!.value,
    greaterThanOrEqualTo(FontWeight.w600.value),
  );
  // The thought's titles keep its quiet ink (9 nov live look); other
  // Markdown bodies keep the primary one.
  expect(
    run.first.style.color,
    anyOf(colors.textPrimary, colors.textSecondary.withValues(alpha: 0.85)),
  );
}

void _expectSecondaryBody(WidgetTester tester, Finder root, String fragment) {
  final colors = AppTheme.hermesRedDark.hermes;
  final run = _runs(tester, root).where((r) => r.text.contains(fragment));
  expect(run, isNotEmpty, reason: 'body "$fragment"');
  // The thought is a notch fainter (9 nov live look).
  expect(run.first.style.color, anyOf(colors.textSecondary, colors.textSecondary.withValues(alpha: 0.85)));
  expect(run.first.style.height, greaterThanOrEqualTo(1.35));
}

final SubagentActivityScope _scope = SubagentActivityScope(
  connectionId: 'c',
  parentSessionId: 'p',
  runtimeSessionId: 'r',
  turnEpoch: 1,
);

SubagentActivity _sub(String goal) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: 'child-1',
  ),
  source: SubagentActivitySource.native,
  phase: SubagentActivityPhase.running,
  subagentId: 'child-1',
  details: SubagentActivityDetails(goalPreview: goal),
);

void main() {
  group('live thought in the turn', () {
    Finder thought() => find.byKey(const ValueKey('turn-reasoning'));

    testWidgets('a **Title** line is a heading without asterisks', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            child: TurnReasoningQuote(
              text: '**Reading the config**\n\nOld section body.\n\n$_owner',
              live: true,
            ),
          ),
        ),
      );
      await tester.pump();
      final text = _plain(tester, thought());
      _expectNoMarkdownSyntax(text);
      // Whole, from its first section: nothing of it is dropped.
      expect(text, contains('Reading the config'));
      expect(text, contains('Old section body'));
      expect(text, contains('Clarifying homelab choices'));
      expect(text, contains('backup job'));
    });
  });

  // Mock 137 A (the owner, 1.4.0): the reasoning block is the same thin line as
  // the chat's trace, «Thinking… · 12 s» live and «Thinking · 12 s» once
  // finished; its body, a quote with one 2 dp rule and no surface, opens on
  // a tap. Before 1.4.0 it was a header over a six-line box with «Show all»,
  // open from the first token (mock 137, «Hoy»).
  group('reasoning is its own labelled block', () {
    Finder panel() => find.byKey(const ValueKey('reasoning-panel'));
    Finder line() => find.descendant(
      of: panel(),
      matching: find.byKey(const ValueKey('turn-thought-toggle')),
    );
    Finder body() => find.descendant(
      of: panel(),
      matching: find.byKey(const ValueKey('turn-reasoning')),
    );

    void expectIdentified(WidgetTester tester, {required bool live}) {
      expect(panel(), findsOneWidget);
      expect(line(), findsOneWidget);
      expect(tester.getSize(line()).height, 48);
      expect(_plain(tester, line()), contains('Thinking'));
      // Live: the beating dot; finished: the thought's glyph.
      expect(
        find.descendant(of: line(), matching: find.byType(TurnStatusPulse)),
        live ? findsOneWidget : findsNothing,
      );
      expect(
        // QA 9709: the thought's glyph is the brain ([ThinkingGlyph]).
        find.descendant(of: line(), matching: find.byType(ThinkingGlyph)),
        live ? findsNothing : findsOneWidget,
      );
      // Folded until the reader opens it.
      expect(body(), findsNothing);
    }

    Future<void> open(WidgetTester tester) async {
      await tester.tap(line());
      await tester.pumpAndSettle();
    }

    void expectQuote(WidgetTester tester) {
      final quote =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: body(),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(quote.color, isNull, reason: 'no surface behind the quote');
      // Look of 9 nov 2026: a hairline, no thick bar (Desktop draws none).
      expect((quote.border! as BorderDirectional).start.width, 1);
      expect((quote.border! as BorderDirectional).top, BorderSide.none);
    }

    testWidgets('live: one line with the live dot; a tap opens the quote', (
      tester,
    ) async {
      await tester.pumpWidget(_app(ReasoningPanel(text: _owner, live: true)));
      await tester.pump();
      expectIdentified(tester, live: true);
      await open(tester);
      expect(body(), findsOneWidget);
      expectQuote(tester);
    });

    Widget done(String text) => ActivityDoneSection(
      now: _t0,
      dense: true,
      steps: [
        const ActivityStep(
          id: 't1',
          kind: ActivityStepKind.tool,
          label: 'terminal',
          status: ActivityStepStatus.done,
        ),
        ActivityStep(
          id: 'r1',
          kind: ActivityStepKind.reasoning,
          label: 'reasoning',
          status: ActivityStepStatus.done,
          duration: const Duration(seconds: 12),
          text: text,
        ),
      ],
    );

    testWidgets('finished: Thinking · 12 s, Markdown, never inside a row', (
      tester,
    ) async {
      await tester.pumpWidget(_app(done(_owner)));
      await tester.pump();
      expectIdentified(tester, live: false);
      expect(_plain(tester, line()), contains('12'));
      await open(tester);
      expectQuote(tester);
      _expectNoMarkdownSyntax(_plain(tester, panel()));
      _expectHeading(tester, panel(), 'Clarifying homelab choices');
      _expectSecondaryBody(tester, panel(), 'The user wants');
      for (final row in find.byType(ActivityStepRow).evaluate()) {
        final text = _plain(tester, find.byWidget(row.widget));
        expect(text, isNot(contains('The user wants')));
      }
    });

    testWidgets('long reasoning: one tap opens it whole, another folds it', (
      tester,
    ) async {
      final long = [
        '**Planning**',
        for (var i = 1; i <= 40; i++) 'Paragraph $i of the plan.',
      ].join('\n\n');
      await tester.pumpWidget(_app(SingleChildScrollView(child: done(long))));
      await tester.pump();
      final folded = tester.getSize(panel()).height;
      expect(folded, 48, reason: 'the line, nothing else');
      await open(tester);
      // Finished: the whole thought, no box of its own.
      expect(
        find.descendant(of: body(), matching: find.byType(Scrollable)),
        findsNothing,
      );
      expect(tester.getSize(panel()).height, greaterThan(folded * 10));
      expect(
        _plain(tester, panel()),
        contains('Paragraph 40 of the plan.'),
      );
      await open(tester);
      expect(body(), findsNothing);
      expect(tester.getSize(panel()).height, folded);
    });

    testWidgets('the reasoning disclosure uses the same block', (tester) async {
      await tester.pumpWidget(_app(const ReasoningBlock(reasoning: _owner)));
      await tester.pump();
      expectIdentified(tester, live: false);
      await open(tester);
      _expectNoMarkdownSyntax(_plain(tester, panel()));
      _expectHeading(tester, panel(), 'Clarifying homelab choices');
    });
  });

  group('agent texts in detail pages and prompts', () {
    testWidgets('HermesTextBlock renders Markdown agent text', (tester) async {
      await tester.pumpWidget(
        _app(const SingleChildScrollView(child: HermesTextBlock(text: _owner))),
      );
      await tester.pump();
      final root = find.byType(HermesTextBlock);
      _expectNoMarkdownSyntax(_plain(tester, root));
      _expectHeading(tester, root, 'Clarifying homelab choices');
    });

    testWidgets('HermesTextBlock keeps plain or mono text literal', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const SingleChildScrollView(
            child: HermesTextBlock(text: 'echo **not bold**', mono: true),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('echo **not bold**'), findsOneWidget);
    });

    testWidgets('a clarify question renders its Markdown', (tester) async {
      final key = InteractivePromptKey(
        runtimeSessionId: 'runtime-a',
        requestId: 'q1',
      );
      await tester.pumpWidget(
        _app(
          InteractivePromptCard(
            entry: InteractivePromptEntry(
              key: key,
              request: ClarifyPromptRequest(
                key: key,
                question: 'Use the **staging** host or `prod-1`?',
                choices: const ['staging', 'prod-1'],
              ),
              status: InteractivePromptStatus.pending,
            ),
            busy: false,
            onSubmit: (_) {},
            onCancel: () {},
          ),
        ),
      );
      await tester.pump();
      final text = _plain(tester, find.byType(InteractivePromptCard));
      _expectNoMarkdownSyntax(text);
      expect(text, contains('Use the staging host or prod-1?'));
    });
  });

  group('one-line previews carry no Markdown syntax', () {
    const raw =
        '## Daily **backup** report\n'
        '- check `restic` [logs](https://example.com)\n'
        '1. rotate keys\n'
        'MEDIA:/tmp/chart.png';

    void expectPlain(String? value) {
      expect(value, isNotNull);
      for (final token in ['**', '`', '](', '##', 'MEDIA:', '- ', '1. ']) {
        expect(value, isNot(contains(token)), reason: '$token in "$value"');
      }
      expect(value, contains('Daily backup report'));
      expect(value, contains('check restic logs'));
    }

    test('plainPreview', () {
      expectPlain(plainPreview(raw));
      expect(plainPreview(null), '');
      expect(plainPreview('  '), '');
      expect(plainPreview('__under__ and _em_'), 'under and em');
      expect(plainPreview('a\nb'), 'a b');
      expect(plainPreview('x' * 50, maxChars: 10), '${'x' * 9}…');
      expect(plainPreview('2 * 3 = 6'), '2 * 3 = 6');
    });

    test('session list row', () {
      const session = Session(
        id: 's1',
        title: '',
        model: '',
        source: 'cli',
        messageCount: 2,
        isActive: false,
        startedAt: 1,
        preview: raw,
      );
      expectPlain(sessionListPreview(session));
      // The model-level preview feeds titles and search too.
      expectPlain(session.cleanPreview);
    });

    test('room card', () => expectPlain(rosterPreviewText(raw)));

    test('notification body', () => expectPlain(plainNotificationText(raw)));

    testWidgets('subagent goal in «En marcha»', (tester) async {
      final snapshot = ValueNotifier(
        ActivitySnapshot(
          subagents: [_sub('**Audit** the `backup` [job](https://x.y)')],
        ),
      );
      addTearDown(snapshot.dispose);
      await tester.pumpWidget(
        _app(RunningWork(snapshot: snapshot, clock: () => _t0)),
      );
      await tester.pump();
      final text = _plain(tester, find.byType(RunningWork));
      _expectNoMarkdownSyntax(text);
      expect(text, contains('Audit the backup job'));
    });
  });
}
