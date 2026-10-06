// rt1215 scroll sweep: the surfaces that carry long agent text fit a small
// phone (360x640) at text scale 2.0 — no RenderFlex overflow, the long
// content scrolls, the bottom actions stay reachable and a folded block
// never traps the page's own scroll.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/content.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/session_activity.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/interactive_prompt_reducer.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/activity_panel.dart';
import 'package:hermes_android/core/widgets/activity_side_panel.dart';
import 'package:hermes_android/core/widgets/interactive_prompt_card.dart';
import 'package:hermes_android/core/widgets/kanban_task_detail_surface.dart';
import 'package:hermes_android/core/widgets/reasoning_block.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const Size _phone = Size(360, 640);
const double _scale = 2;
final DateTime _t0 = DateTime(2026, 10, 6, 12);

final String _longMarkdown = [
  '**Clarifying homelab choices**',
  for (var i = 1; i <= 12; i++)
    'Paragraph $i: the `nas-$i` host keeps the **nightly** backup and a '
        '[runbook](https://example.com/$i) explains how to restore it.',
  '- first follow-up\n- second follow-up',
].join('\n\n');

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: const TextScaler.linear(_scale),
        ),
        child: child!,
      ),
      home: home,
    ),
  );
  await tester.pump();
  await tester.pump();
}

final SubagentActivityScope _scope = SubagentActivityScope(
  connectionId: 'c',
  parentSessionId: 'p',
  runtimeSessionId: 'r',
  turnEpoch: 1,
);

SubagentActivity _sub(String id) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: id,
  ),
  source: SubagentActivitySource.native,
  phase: SubagentActivityPhase.running,
  subagentId: id,
  details: SubagentActivityDetails(
    goalPreview: '**Audit** the `backup` job of host $id and report back',
  ),
);

void _expectInside(WidgetTester tester, Finder finder, String what) {
  final rect = tester.getRect(finder);
  expect(rect.top, greaterThanOrEqualTo(0), reason: what);
  expect(rect.bottom, lessThanOrEqualTo(_phone.height + 0.5), reason: what);
  expect(rect.left, greaterThanOrEqualTo(0), reason: what);
  expect(rect.right, lessThanOrEqualTo(_phone.width + 0.5), reason: what);
}

void main() {
  testWidgets('activity view with long reasoning and many rows', (
    tester,
  ) async {
    final snapshot = ActivitySnapshot(
      turnActive: true,
      turnStartedAt: _t0,
      headline: 'Pensando…',
      liveReasoning: _longMarkdown,
      subagents: [for (var i = 0; i < 6; i++) _sub('child-$i')],
      processes: const [
        SessionActivityProcess(
          id: 'proc-1',
          command: 'restic backup /srv --verbose --exclude-caches',
          notifyOnComplete: true,
          startedAt: null,
        ),
      ],
    );
    final actions = ActivityPanelActions(
      canStopTurn: true,
      stopTurn: () async {},
      canStopAll: true,
      stopAll: () async {},
      addContext: () {},
      changeCourse: () {},
    );
    await _pump(
      tester,
      Scaffold(
        body: ActivitySidePanelHost(
          child: Column(
            children: [
              const Expanded(child: SizedBox.expand()),
              ActivityPillHost(
                snapshot: snapshot,
                actions: actions,
                clock: () => _t0.add(const Duration(seconds: 10)),
                revealAfter: Duration.zero,
              ),
              const SizedBox(height: 56, child: TextField()),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('activity-pill')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    _expectInside(
      tester,
      find.byKey(const ValueKey('activity-panel')),
      'activity panel',
    );
    // The reasoning box keeps its own bounded height inside the panel.
    final reasoning = find.byKey(const ValueKey('activity-now-reasoning'));
    expect(tester.getSize(reasoning).height, lessThan(_phone.height / 2));
    for (final key in [
      'activity-action-add-context',
      'activity-action-stop-all',
    ]) {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pump();
      _expectInside(tester, find.byKey(ValueKey(key)), key);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('clarify prompt with a long Markdown question and choices', (
    tester,
  ) async {
    final key = InteractivePromptKey(
      runtimeSessionId: 'runtime-a',
      requestId: 'q1',
    );
    await _pump(
      tester,
      Scaffold(
        body: Column(
          children: [
            const Expanded(child: SizedBox.expand()),
            InteractivePromptCard(
              entry: InteractivePromptEntry(
                key: key,
                request: ClarifyPromptRequest(
                  key: key,
                  question: _longMarkdown,
                  choices: [
                    for (var i = 1; i <= 5; i++)
                      'Option $i: keep the nightly backup on nas-$i',
                  ],
                ),
                status: InteractivePromptStatus.pending,
              ),
              busy: false,
              onSubmit: (_) {},
              onCancel: () {},
            ),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final card = find.byType(InteractivePromptCard);
    _expectInside(tester, card, 'prompt card');
    final field = find.descendant(of: card, matching: find.byType(TextField));
    await tester.ensureVisible(field);
    await tester.pump();
    _expectInside(tester, field, 'answer field');
    expect(tester.takeException(), isNull);
  });

  testWidgets('kanban task detail with a long Markdown body', (tester) async {
    final detail = KanbanTaskDetail.fromJson({
      'task': {
        'id': 'long',
        'title': 'Rotate the **backup** keys on every host of the homelab',
        'body': _longMarkdown,
        'status': 'running',
        'assignee': 'luna',
        'result': _longMarkdown,
      },
      'comments': [
        {'id': 1, 'author': 'qa', 'body': 'Looks good'},
      ],
    });
    await _pump(
      tester,
      Scaffold(
        body: KanbanTaskDetailSurface(
          detail: detail,
          readOnly: false,
          onAddComment: (_) async {},
          onUploadAttachment: () async {},
          onDownloadAttachment: (_) async {},
          onDeleteAttachment: (_) async {},
          onInspectRun: (_) async {},
          onTerminateRun: (_) async {},
          onShowLog: () async {},
          onReclaim: () async {},
          onReassign: () async {},
          onSpecify: () async {},
          onDecompose: () async {},
          onConfigureModel: () async {},
          onOpenLinkedTask: (_) async {},
          onArchive: () {},
          onDelete: () {},
          onMove: () {},
          onEdit: () {},
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final body = find.byKey(const ValueKey('kanban-task-detail-body'));
    await tester.ensureVisible(body);
    await tester.pump();
    // The folded Markdown body stays bounded and the page keeps scrolling
    // when the drag starts on it (no inner scroll trap).
    final page = find.ancestor(of: body, matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(page.first).position;
    final before = position.pixels;
    await tester.drag(body, const Offset(0, -200));
    await tester.pump();
    expect(position.pixels, greaterThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long agent text blocks and the reasoning disclosure', (
    tester,
  ) async {
    await _pump(
      tester,
      Scaffold(
        body: ListView(
          children: [
            HermesTextBlock(text: _longMarkdown, copyable: true),
            ReasoningBlock(reasoning: _longMarkdown),
            HermesTextBlock(text: _longMarkdown),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
    await tester.drag(
      find.byKey(const ValueKey('reasoning-panel-surface')),
      const Offset(0, -300),
    );
    await tester.pump();
    expect(list.position.pixels, greaterThan(0), reason: 'page scrolls');
    expect(tester.takeException(), isNull);
  });
}
