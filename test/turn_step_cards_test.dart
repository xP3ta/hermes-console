import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/hermes_tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/readable_ink.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/chat/tool_steps_summary.dart';
import 'package:hermes_android/core/widgets/chat/turn_step_cards.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';

import 'support/turn_summary_host.dart';

void main() {
  setUp(StepsBarMemory.reset);

  testWidgets('latest three actions stay visible and collapse on completion', (
    tester,
  ) async {
    Widget host(bool live) => turnSummaryHost(
      TurnStepCards(
        entries: [
          for (var i = 0; i < 7; i++) summaryEntry(i, running: live && i == 6),
        ],
        live: live,
        duration: live ? null : const Duration(seconds: 42),
      ),
    );
    await tester.pumpWidget(host(true));
    for (var i = 0; i < 7; i++) {
      expect(
        find.byKey(ValueKey('turn-step-card-tool-$i')),
        i >= 4 ? findsOneWidget : findsNothing,
      );
    }
    expect(find.byKey(const ValueKey('turn-line-label')), findsNothing);
    expect(find.text('0:05'), findsOneWidget);
    await tester.pumpWidget(host(false));
    await tester.pumpAndSettle();
    expect(find.text('Trabajó 0:42 · Leyó 7 archivos'), findsOneWidget);
    expect(find.byKey(const ValueKey('turn-line-group')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('turn-line-label')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 7; i++) {
      expect(find.byKey(ValueKey('turn-step-card-tool-$i')), findsOneWidget);
    }
  });

  testWidgets('thoughts share the three-row budget and retain disclosure', (
    tester,
  ) async {
    final thought = TurnStepCardEntry(
      id: 'thought',
      kind: TurnStepCardKind.thought,
      title: 'Pensó',
      semanticsLabel: 'Pensó',
      duration: const Duration(seconds: 2),
      opened: const Text('reasoning only on request'),
    );
    await tester.pumpWidget(
      turnSummaryHost(
        TurnStepCards(
          entries: [thought, summaryEntry(0, running: true)],
          live: true,
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('turn-inner-thought-thought')),
      findsOneWidget,
    );
    expect(find.text('reasoning only on request'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('turn-inner-thought-label-thought')),
    );
    await tester.pump();
    expect(find.text('reasoning only on request'), findsOneWidget);
    await tester.pumpWidget(
      turnSummaryHost(
        TurnStepCards(
          entries: [
            for (var i = 0; i < 5; i++) summaryEntry(i),
            const TurnStepCardEntry(
              id: 'thinking',
              kind: TurnStepCardKind.thought,
              title: 'Pensamiento',
              semanticsLabel: 'Pensamiento',
              running: true,
            ),
          ],
          live: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('turn-thought-label')), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      expect(
        find.byKey(ValueKey('turn-step-card-tool-$i')),
        i >= 3 ? findsOneWidget : findsNothing,
      );
    }
  });

  testWidgets(
    'MEDIO-1: the widget forwards safe targets for unique file counts',
    (tester) async {
      await tester.pumpWidget(
        turnSummaryHost(
          ThinkingTraceCard(
            events: [
              for (var i = 0; i < 3; i++)
                ChatTraceEvent(
                  id: 'read$i',
                  label: 'read_file',
                  status: 'completed',
                  detail: '/private/same.dart',
                ),
            ],
            active: false,
            stepCards: true,
            headerBuilder: (_, summary, details) => details,
          ),
        ),
      );
      expect(find.text('Trabajó · Leyó 1 archivo'), findsOneWidget);
    },
  );

  testWidgets(
    'MEDIO-2: raw wire details are private in live and settled rows',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        Widget host(bool live) => turnSummaryHost(
          ThinkingTraceCard(
            events: [
              ChatTraceEvent(
                id: 'raw-command',
                label: 'terminal',
                status: live ? 'running' : 'completed',
                detail: '/usr/bin/git status --token=private-value',
              ),
              ChatTraceEvent(
                id: 'raw-file',
                label: 'read_file',
                status: live ? 'running' : 'completed',
                detail: '/private/customer/deploy.sh',
              ),
              ChatTraceEvent(
                id: 'raw-url',
                label: 'web_extract',
                status: live ? 'running' : 'completed',
                detail: 'https://u:private-value@h/p?sig=abc&token=xyz',
              ),
            ],
            active: live,
            stepCards: true,
            headerBuilder: (_, summary, details) => details,
          ),
        );
        for (final live in [true, false]) {
          await tester.pumpWidget(host(live));
          await tester.pumpAndSettle();
          if (!live) {
            await tester.tap(find.byKey(const ValueKey('turn-line-label')));
            await tester.pumpAndSettle();
          }
          expect(find.text('git'), findsOneWidget);
          expect(find.text('deploy.sh'), findsOneWidget);
          expect(find.text('h'), findsOneWidget);
          for (final forbidden in [
            '/private',
            'private-value',
            '--token',
            'sig=',
            'xyz',
          ]) {
            expect(
              find.textContaining(forbidden, findRichText: true),
              findsNothing,
            );
            expect(
              find.bySemanticsLabel(RegExp(RegExp.escape(forbidden))),
              findsNothing,
            );
          }
        }
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('BAJO: subsecond tool and turn durations are omitted', (
    tester,
  ) async {
    await tester.pumpWidget(
      turnSummaryHost(
        TurnStepCards(
          duration: const Duration(milliseconds: 999),
          entries: [
            const TurnStepCardEntry(
              id: 'brief',
              kind: TurnStepCardKind.tool,
              title: 'Ejecutó',
              toolName: 'terminal',
              duration: Duration(milliseconds: 700),
              durationText: '0,7 s',
              semanticsLabel: 'Ejecutó',
            ),
          ],
        ),
      ),
    );
    expect(find.text('Trabajó · Ejecutó 1 comando'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('turn-line-label')));
    await tester.pumpAndSettle();
    expect(find.text('0:00'), findsNothing);
    expect(find.text('0,7 s'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failure state and 1:12 stay fully readable at 320 dp and 2x', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      turnSummaryHost(
        TurnStepCards(
          entries: [
            TurnStepCardEntry(
              id: 'failed',
              kind: TurnStepCardKind.tool,
              title: 'Ejecutó',
              toolName: 'terminal',
              detail: 'git',
              failed: true,
              duration: const Duration(seconds: 72),
              semanticsLabel: 'Ejecutó git, Fallido',
              opened: const Text('output'),
            ),
          ],
        ),
        scale: 2,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('turn-line-label')));
    await tester.pumpAndSettle();
    for (final text in ['Fallido', '· 1:12']) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(
        paragraph.size.width + 0.01,
        greaterThanOrEqualTo(paragraph.getMaxIntrinsicWidth(double.infinity)),
      );
      final rect = tester.getRect(find.text(text));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
    }
    expect(
      tester
          .getSize(find.byKey(const ValueKey('turn-step-card-failed')))
          .height,
      greaterThanOrEqualTo(44),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the actual warning summary ink maintains 4.5:1 in every theme', (
    tester,
  ) async {
    var worst = double.infinity;
    for (final preset in AppTheme.presets) {
      await tester.pumpWidget(
        turnSummaryHost(
          TurnStepCards(
            entries: [
              const TurnStepCardEntry(
                id: 'failed',
                kind: TurnStepCardKind.tool,
                title: 'Ejecutó',
                toolName: 'terminal',
                failed: true,
                semanticsLabel: 'Fallido',
              ),
            ],
          ),
          theme: AppTheme.fromPreset(preset),
        ),
      );
      await tester.pumpAndSettle();
      final label = tester.widget<Text>(
        find.byKey(const ValueKey('turn-line-label')),
      );
      expect(label.data, contains('1 falló'));
      final ink = label.style!.color!;
      final colors = preset.colors;
      expect(ink, readableInkOnTint(colors.warning, colors.background, colors));
      final ratio = ThemeContrast.ratio(ink, colors.background);
      if (ratio < worst) worst = ratio;
      expect(ratio + 1e-9, greaterThanOrEqualTo(4.5), reason: preset.id);
    }
    // Printed once as review evidence for the chosen warning tint.
    debugPrint(
      'Turn summary warning contrast: minimum ${worst.toStringAsFixed(3)}:1',
    );
  });

  testWidgets('tool events and the per-step timer never rebuild the host', (
    tester,
  ) async {
    final entries = ValueNotifier([summaryEntry(0)]);
    addTearDown(entries.dispose);
    var hostBuilds = 0;
    var now = DateTime(2026, 11, 4, 12);
    await tester.pumpWidget(
      turnSummaryHost(
        Builder(
          builder: (context) {
            hostBuilds++;
            return ValueListenableBuilder(
              valueListenable: entries,
              builder: (context, value, child) =>
                  TurnStepCards(entries: value, live: true),
            );
          },
        ),
      ),
    );
    final initial = hostBuilds;
    for (var i = 1; i <= 40; i++) {
      entries.value = [
        for (var j = 0; j < i; j++) summaryEntry(j),
        summaryEntry(i, running: true, start: now, clock: () => now),
      ];
    }
    await tester.pump();
    expect(hostBuilds, initial);
    expect(find.text('0:00'), findsNothing);
    now = now.add(const Duration(seconds: 18));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('0:18'), findsOneWidget);
    expect(hostBuilds, initial);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('thinking to tool handoff has one thought even mid-animation', (
    tester,
  ) async {
    TurnStepCardEntry thought(bool running) => TurnStepCardEntry(
      id: 'same-thought',
      kind: TurnStepCardKind.thought,
      title: running ? 'Pensamiento' : 'Pensó',
      semanticsLabel: 'Pensamiento',
      running: running,
      opened: const Text('one thought body'),
    );
    Widget host(bool toolStarted) => turnSummaryHost(
      TurnStepCards(
        live: true,
        entries: [
          thought(!toolStarted),
          if (toolStarted) summaryEntry(0, running: true),
        ],
      ),
      reduced: false,
    );
    await tester.pumpWidget(host(false));
    await tester.pumpWidget(host(true));
    await tester.pump(HermesMotion.fast);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            ('${widget.key}'.contains('turn-thought-card-') ||
                '${widget.key}'.contains('turn-inner-thought-')),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('invalid thought and turn durations stay unknown', (
    tester,
  ) async {
    await tester.pumpWidget(
      turnSummaryHost(
        ThinkingTraceCard(
          events: [
            ChatTraceEvent(
              id: 'thought',
              label: 'reasoning',
              kind: ChatTraceEventKind.reasoning,
              status: 'completed',
              preview: 'A measured thought without a valid clock.',
              duration: const Duration(days: 1),
            ),
          ],
          active: false,
          stepCards: true,
          duration: const Duration(seconds: -1),
          headerBuilder: (_, summary, details) => details,
        ),
      ),
    );
    expect(find.text('Pensó'), findsOneWidget);
    expect(find.textContaining('24:00'), findsNothing);
    expect(find.textContaining('1440:'), findsNothing);
  });

  testWidgets(
    'raw previews and arguments never enter visible or accessible steps',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final events = [
        ChatTraceEvent(
          id: 'cmd',
          label: 'terminal',
          status: 'completed',
          preview: 'git status --password=privateSecret /private/customer',
          detail: activityToolDetail('terminal', {
            'command': 'git status --short',
          }),
          duration: const Duration(seconds: 2),
        ),
        ChatTraceEvent(
          id: 'file',
          label: 'read_file',
          status: 'completed',
          preview: '/private/customer/deploy.sh',
          detail: activityToolDetail('read_file', {
            'path': '/private/customer/deploy.sh',
          }),
        ),
        ChatTraceEvent(
          id: 'url',
          label: 'web_extract',
          status: 'completed',
          preview: 'https://user:privateSecret@example.com/path?secret=yes',
          detail: activityToolDetail('web_extract', {
            'url': 'https://user:privateSecret@example.com/path?secret=yes',
          }),
        ),
      ];
      await tester.pumpWidget(
        turnSummaryHost(
          ThinkingTraceCard(
            events: events,
            active: false,
            stepCards: true,
            duration: const Duration(seconds: 17),
            headerBuilder: (_, summary, details) => details,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('turn-line-label')));
      await tester.pumpAndSettle();
      expect(find.text('git'), findsOneWidget);
      expect(find.text('deploy.sh'), findsOneWidget);
      expect(find.text('example.com'), findsOneWidget);
      for (final forbidden in [
        'privateSecret',
        '/private',
        '--short',
        '--password',
        '?secret',
        'user:',
      ]) {
        expect(
          find.textContaining(forbidden, findRichText: true),
          findsNothing,
        );
        expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(forbidden))),
          findsNothing,
        );
      }
      expect(find.text('0:02'), findsOneWidget);
      semantics.dispose();
    },
  );

  testWidgets('full summary semantics retains hidden categories and failures', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final tools = [
      'apply_patch',
      'read_file',
      'terminal',
      'web_search',
      'web_fetch',
    ];
    await tester.pumpWidget(
      turnSummaryHost(
        TurnStepCards(
          entries: [
            for (var i = 0; i < tools.length; i++)
              TurnStepCardEntry(
                id: 's$i',
                kind: TurnStepCardKind.tool,
                title: 'Paso',
                toolName: tools[i],
                detail: i < 2 ? 'file.dart' : null,
                failed: i == 4,
                semanticsLabel: 'Paso',
              ),
          ],
        ),
      ),
    );
    expect(find.textContaining('+2 más'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Trabajó · Editó 1 archivo · Leyó 1 archivo · Ejecutó 1 comando · Buscó en la web · Abrió 1 página · 1 falló',
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets(
    'settling animates one persistent container without duplicated rows',
    (tester) async {
      await tester.pumpWidget(
        turnSummaryHost(
          TurnStepCards(
            entries: [summaryEntry(0), summaryEntry(1, running: true)],
            live: true,
          ),
          reduced: false,
        ),
      );
      await tester.pump(HermesMotion.enter);
      final line = tester.element(
        find.byKey(const ValueKey('turn-line-tool-0')),
      );
      await tester.pumpWidget(
        turnSummaryHost(
          TurnStepCards(
            entries: [summaryEntry(0), summaryEntry(1)],
            duration: const Duration(seconds: 8),
          ),
          reduced: false,
        ),
      );
      expect(
        tester.element(find.byKey(const ValueKey('turn-line-tool-0'))),
        same(line),
      );
      await tester.pumpAndSettle();
      expect(find.text('Trabajó 0:08 · Leyó 2 archivos'), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-line-group')), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
