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
import 'package:hermes_android/core/widgets/interactive_prompt_card.dart';
import 'package:hermes_android/core/widgets/reasoning_block.dart';
import 'package:hermes_android/core/widgets/reasoning_panel.dart';
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
  expect(run.first.style.color, colors.textPrimary);
}

void _expectSecondaryBody(WidgetTester tester, Finder root, String fragment) {
  final colors = AppTheme.hermesRedDark.hermes;
  final run = _runs(tester, root).where((r) => r.text.contains(fragment));
  expect(run, isNotEmpty, reason: 'body "$fragment"');
  expect(run.first.style.color, colors.textSecondary);
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
  group('live reasoning in the activity view', () {
    Finder tail() => find.byKey(const ValueKey('activity-now-reasoning'));

    ActivitySnapshot thinking(String text) => ActivitySnapshot(
      turnActive: true,
      turnStartedAt: _t0,
      headline: 'Thinking…',
      liveReasoning: text,
    );

    testWidgets('a **Title** line is a bold heading without asterisks', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(ActivityNowSection(snapshot: thinking(_owner), now: _t0)),
      );
      await tester.pump();
      final text = _plain(tester, tail());
      _expectNoMarkdownSyntax(text);
      expect(text, contains('docker'));
      expect(text, contains('backup job'));
      _expectHeading(tester, tail(), 'Clarifying homelab choices');
      _expectSecondaryBody(tester, tail(), 'The user wants');
    });

    testWidgets('while streaming it shows the latest section only', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          ActivityNowSection(
            snapshot: thinking(
              '**Reading the config**\n\nOld section body.\n\n$_owner',
            ),
            now: _t0,
          ),
        ),
      );
      await tester.pump();
      final text = _plain(tester, tail());
      expect(text, isNot(contains('Old section body')));
      expect(text, contains('Clarifying homelab choices'));
    });

    testWidgets('a long section scrolls, follows the tail and fades edges', (
      tester,
    ) async {
      final body = [for (var i = 1; i <= 80; i++) 'Line $i of the plan.'];
      await tester.pumpWidget(
        _app(
          ActivityNowSection(
            snapshot: thinking('**Planning**\n\n${body.join('\n\n')}'),
            now: _t0,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: tail(), matching: find.byType(Scrollable)),
          )
          .position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(position.pixels, position.maxScrollExtent);
      expect(_plain(tester, tail()), contains('Line 80 of the plan.'));
      expect(
        find.byKey(const ValueKey('reasoning-panel-fade')),
        findsOneWidget,
      );
    });
  });

  group('reasoning is its own labelled block', () {
    Finder panel() => find.byKey(const ValueKey('reasoning-panel'));

    void expectIdentified(WidgetTester tester, {required bool live}) {
      final colors = AppTheme.hermesRedDark.hermes;
      expect(panel(), findsOneWidget);
      final header = find.byKey(const ValueKey('reasoning-panel-header'));
      expect(
        find.descendant(of: header, matching: find.byIcon(reasoningPanelIcon)),
        findsOneWidget,
      );
      expect(_plain(tester, header), contains('Thinking'));
      expect(
        find.byKey(const ValueKey('reasoning-panel-live')),
        live ? findsOneWidget : findsNothing,
      );
      final surface = tester.widget<Container>(
        find.byKey(const ValueKey('reasoning-panel-surface')),
      );
      final decoration = surface.decoration! as BoxDecoration;
      expect(decoration.color, isNotNull);
      expect(decoration.color, isNot(colors.surface));
      expect(decoration.color, isNot(colors.background));
      final border = decoration.border! as Border;
      expect(border.left.width, greaterThanOrEqualTo(2));
      expect(border.top, BorderSide.none);
      expect(surface.padding, const EdgeInsets.all(12));
    }

    testWidgets('live: header, icon, live dot and an inset surface', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          ActivityNowSection(
            snapshot: ActivitySnapshot(
              turnActive: true,
              turnStartedAt: _t0,
              headline: 'Thinking…',
              liveReasoning: _owner,
            ),
            now: _t0,
          ),
        ),
      );
      await tester.pump();
      expectIdentified(tester, live: true);
      final row = find.byKey(const ValueKey('activity-now-row'));
      expect(_plain(tester, row), isNot(contains('The user wants')));
      expect(
        tester.getTopLeft(panel()).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(row).dy),
      );
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
      final header = find.byKey(const ValueKey('reasoning-panel-header'));
      expect(_plain(tester, header), contains('12'));
      _expectNoMarkdownSyntax(_plain(tester, panel()));
      _expectHeading(tester, panel(), 'Clarifying homelab choices');
      _expectSecondaryBody(tester, panel(), 'The user wants');
      for (final row in find.byType(ActivityStepRow).evaluate()) {
        final text = _plain(tester, find.byWidget(row.widget));
        expect(text, isNot(contains('The user wants')));
      }
    });

    testWidgets('long reasoning: folded with a fade, Show all, header folds', (
      tester,
    ) async {
      final long = [
        '**Planning**',
        for (var i = 1; i <= 40; i++) 'Paragraph $i of the plan.',
      ].join('\n\n');
      await tester.pumpWidget(_app(SingleChildScrollView(child: done(long))));
      await tester.pump();
      await tester.pump();
      final surface = find.byKey(const ValueKey('reasoning-panel-surface'));
      final folded = tester.getSize(surface).height;
      expect(folded, lessThan(220));
      expect(
        find.byKey(const ValueKey('reasoning-panel-fade')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('reasoning-panel-toggle')));
      await tester.pumpAndSettle();
      expect(tester.getSize(surface).height, greaterThan(folded * 2));
      expect(find.text('Show less'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reasoning-panel-header')));
      await tester.pumpAndSettle();
      expect(surface, findsNothing);
      expect(find.byKey(const ValueKey('reasoning-panel-header')), findsOne);
    });

    testWidgets('the reasoning disclosure uses the same block', (tester) async {
      await tester.pumpWidget(_app(const ReasoningBlock(reasoning: _owner)));
      await tester.pump();
      expectIdentified(tester, live: false);
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

    testWidgets('subagent goal in the activity view', (tester) async {
      await tester.pumpWidget(
        _app(
          ActivitySubagentRow(
            activity: _sub('**Audit** the `backup` [job](https://x.y)'),
            actions: ActivityPanelActions.none,
            now: _t0,
          ),
        ),
      );
      await tester.pump();
      final text = _plain(tester, find.byType(ActivitySubagentRow));
      _expectNoMarkdownSyntax(text);
      expect(text, contains('Audit the backup job'));
    });
  });
}
