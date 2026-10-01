// Visual evidence for the tool-activity summary and the compaction state in
// the context pill. Renders real widgets at 412×915, Spanish, dark and light;
// writes PNGs only when TP1216_SHOTS_DIR is set (otherwise a layout smoke
// test). Fixtures are synthetic: generic tool names and a public skill name.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/compaction_progress.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/activity_pill.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/compaction_dock.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/message_avatar_header.dart';
import 'package:hermes_android/core/widgets/session_context_usage.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart' show loadDesignFonts;

const _shotKey = ValueKey('tp1216-shot');
final _t0 = DateTime(2026, 9, 30, 12);

/// Six calls including a skill load, built the way the chat builds them:
/// the safe detail comes from the real `activityToolDetail` projection.
List<ChatTraceEvent> _sixCalls({bool running = false}) {
  final calls = <(String, Map<String, Object?>)>[
    ('skill_view', {'name': 'github-pr-workflow'}),
    ('terminal', {'command': 'git status'}),
    ('read_file', {'path': 'lib/core/widgets/chat_event_cards.dart'}),
    ('terminal', {'command': 'flutter analyze'}),
    ('read_file', {'path': 'AGENTS.md'}),
    ('terminal', {'command': 'flutter test'}),
  ];
  return [
    for (var i = 0; i < calls.length; i++)
      ChatTraceEvent(
        id: 'call-$i',
        label: calls[i].$1,
        status: running && i == calls.length - 1 ? 'running' : 'completed',
        detail: activityToolDetail(calls[i].$1, calls[i].$2),
        startedAt: _t0.add(Duration(seconds: i * 9)),
        duration: running && i == calls.length - 1
            ? null
            : Duration(milliseconds: 700 + i * 900),
      ),
  ];
}

Widget _assistantBlock(List<ChatTraceEvent> events, {required bool active}) =>
    ThinkingTraceCard(
      events: events,
      active: active,
      liveInPill: true,
      duration: active ? null : const Duration(seconds: 72),
      headerBuilder: (context, summary, details) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MessageAvatarHeader(
            name: 'Hermes',
            subtitle: summary,
            actions: [
              for (final icon in [Icons.copy_rounded, Icons.refresh_rounded])
                SizedBox.square(dimension: 48, child: Icon(icon, size: 16)),
            ],
          ),
          details,
        ],
      ),
    );

Widget _composer(
  BuildContext context, {
  required Widget footer,
  Widget? above,
}) {
  final colors = Theme.of(context).hermes;
  return Container(
    color: colors.background,
    padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?above,
        const SizedBox(height: 6),
        HermesComposerSurface(
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Escribe un mensaje…',
                    style: TextStyle(color: colors.textSecondary),
                  ),
                ),
                Icon(Icons.arrow_upward, color: colors.textSecondary),
                const SizedBox(width: 16),
              ],
            ),
          ),
        ),
        footer,
      ],
    ),
  );
}

Widget _contextPill({CompactionProgress? compaction}) {
  final metrics = ValueNotifier(
    const SessionContextMetrics(
      contextUsed: 41000,
      contextMax: 200000,
      percent: 21,
    ),
  );
  return Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Center(
      child: SessionContextPopoverButton(
        metrics: metrics,
        loadBreakdown: () async => null,
        onMetricsSnapshot: (_) {},
        modeLabel: 'YOLO',
        compressionCount: 1,
        compaction: compaction,
        clock: () => _t0.add(const Duration(seconds: 23)),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  ThemeData theme,
  Widget Function(BuildContext) body,
) async {
  await loadDesignFonts();
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: theme,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Scaffold(body: SafeArea(child: body(context))),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _save(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull);
  final dir = Platform.environment['TP1216_SHOTS_DIR'];
  if (dir == null || dir.isEmpty) return;
  final boundary =
      tester.renderObject(find.byKey(_shotKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Widget _screen(
  BuildContext context, {
  required List<Widget> transcript,
  required Widget composer,
}) => Column(
  children: [
    Expanded(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 16, 16, 16),
        children: transcript,
      ),
    ),
    composer,
  ],
);

void main() {
  for (final (themeName, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('$themeName: six calls with a skill, collapsed and expanded', (
      tester,
    ) async {
      await _pump(
        tester,
        theme,
        (context) => _screen(
          context,
          transcript: [
            _assistantBlock(_sixCalls(), active: false),
            const SizedBox(height: 24),
            _assistantBlock(_sixCalls(), active: false),
          ],
          composer: _composer(context, footer: _contextPill()),
        ),
      );
      // Expand the second block to show the unchanged detail.
      await tester.tap(
        find.byKey(const ValueKey('thinking-trace-summary')).last,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await _save(tester, 'tools-six-calls-$themeName');
    });

    testWidgets('$themeName: running group', (tester) async {
      await _pump(
        tester,
        theme,
        (context) => _screen(
          context,
          transcript: [_assistantBlock(_sixCalls(running: true), active: true)],
          composer: _composer(
            context,
            above: ActivityPill(
              model: ActivityPillModel(
                glyph: ActivityGlyph.tool,
                action: 'terminal',
                detail: 'flutter',
                timerStart: _t0,
                semanticsLabel: 'terminal, flutter',
              ),
              now: _t0.add(const Duration(seconds: 51)),
              onTap: () {},
            ),
            footer: _contextPill(),
          ),
        ),
      );
      await _save(tester, 'tools-running-$themeName');
    });

    testWidgets('$themeName: compaction in progress', (tester) async {
      final running = CompactionProgress(
        startedAt: _t0,
        manual: true,
        messagesBefore: 38,
        tokensBefore: 32200,
      );
      await _pump(
        tester,
        theme,
        (context) => _screen(
          context,
          transcript: [_assistantBlock(_sixCalls(), active: false)],
          composer: _composer(
            context,
            footer: _contextPill(compaction: running),
          ),
        ),
      );
      await _save(tester, 'compaction-running-$themeName');
    });

    testWidgets('$themeName: compaction done', (tester) async {
      final done = CompactionProgress(
        startedAt: _t0,
        manual: true,
        messagesBefore: 38,
        messagesAfter: 12,
        tokensBefore: 32200,
        tokensAfter: 9800,
        finishedAt: _t0.add(const Duration(seconds: 23)),
      );
      await _pump(
        tester,
        theme,
        (context) => _screen(
          context,
          transcript: [_assistantBlock(_sixCalls(), active: false)],
          composer: _composer(context, footer: _contextPill(compaction: done)),
        ),
      );
      await _save(tester, 'compaction-done-$themeName');
    });

    testWidgets('$themeName: compaction details in the opened panel', (
      tester,
    ) async {
      final running = CompactionProgress(
        startedAt: _t0,
        manual: true,
        messagesBefore: 38,
        tokensBefore: 32200,
      );
      await _pump(
        tester,
        theme,
        (context) => _screen(
          context,
          transcript: [_assistantBlock(_sixCalls(), active: false)],
          composer: _composer(
            context,
            footer: _contextPill(compaction: running),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('desktop-context-usage-status')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('context-panel-compaction')),
        findsOneWidget,
      );
      await _save(tester, 'compaction-panel-$themeName');
    });

    testWidgets('$themeName: Bot Chat fallback indicator', (tester) async {
      final running = CompactionProgress(startedAt: _t0, manual: false);
      await _pump(
        tester,
        theme,
        (context) => _screen(
          context,
          transcript: [_assistantBlock(_sixCalls(), active: false)],
          composer: _composer(
            context,
            footer: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: CompactionInlineIndicator(
                  compaction: running,
                  clock: () => _t0.add(const Duration(seconds: 9)),
                ),
              ),
            ),
          ),
        ),
      );
      await _save(tester, 'compaction-botchat-$themeName');
    });
  }
}
