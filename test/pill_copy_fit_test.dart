import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/models/room_summary.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/turn_activity_pill.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/core/widgets/room_summary_pill.dart';
import 'package:hermes_android/core/widgets/status_pill.dart';
import 'package:hermes_android/core/widgets/hermes_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/widgets/dock_style.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'room_member_status_test.dart' show statusRoom, statusNow, statusEvent;
import 'support/inter_font.dart';

void expectPillLabelsFit(WidgetTester tester, Finder surface) {
  for (final element
      in find
          .descendant(of: surface, matching: find.byType(RichText))
          .evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: paragraph.text.toPlainText(),
    );
    expect(paragraph.size.width, lessThanOrEqualTo(360));
  }
  expect(tester.takeException(), isNull);
}

Future<void> pumpPillCopy(
  WidgetTester tester,
  Widget Function(BuildContext) build, {
  required String locale,
  required double scale,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(locale),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedLight,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.topCenter,
            child: Builder(builder: build),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(loadInterFont);

  final scope = SubagentActivityScope(
    connectionId: 'fixture',
    parentSessionId: 'parent',
    runtimeSessionId: 'runtime',
    turnEpoch: 1,
  );
  final activity = [
    for (var i = 0; i < 12; i++)
      SubagentActivity(
        key: SubagentActivityKey(
          scope: scope,
          identityKind: SubagentIdentityKind.subagent,
          stableId: '$i',
        ),
        source: SubagentActivitySource.native,
        phase: i < 2
            ? SubagentActivityPhase.running
            : i < 11
            ? SubagentActivityPhase.completed
            : SubagentActivityPhase.unknown,
        details: const SubagentActivityDetails(),
      ),
  ];
  final summary = deriveRoomSummary(
    events: [
      statusEvent(1, 'message.user', text: 'hello'),
      statusEvent(2, 'turn.settled', payload: {'passed': true}),
    ],
    members: statusRoom.members,
    localGatewayId: 'gateway',
    now: statusNow,
  );
  final surfaces = <String, Widget Function(BuildContext)>{
    'live turn': (_) => TurnActivityPill(
      active: true,
      startedAt: DateTime(2026),
      clock: () => DateTime(2026).add(const Duration(hours: 1)),
      statusLabel: null,
    ),
    'subagent aggregate': (_) =>
        SubagentActivityCard(activities: activity, canInterrupt: (_) => false),
    'completed subagents with dismiss': (_) => SubagentActivityCard(
      activities: activity
          .where((a) => a.phase == SubagentActivityPhase.completed)
          .toList(),
      canInterrupt: (_) => false,
      onDismiss: () {},
    ),
    'room summary': (_) =>
        RoomSummaryPill(summary: summary, localGatewayId: 'gateway'),
    'status': (_) => const StatusPill(status: InstanceStatus.readOnly),
    'dock': (c) => DockBar(
      style: const DockStyle(),
      children: [
        for (final id in [
          DockItemId.cron,
          DockItemId.sessions,
          DockItemId.tools,
          DockItemId.settings,
          DockItemId.bots,
        ])
          DockItemTile(
            controlKey: ValueKey(id),
            label: dockItemLabel(Strings.of(c), id),
            compactLabel: dockItemCompactLabel(Strings.of(c), id),
            icon: Icons.circle_outlined,
            compact: true,
            innerRadius: 12,
            onTap: () {},
          ),
      ],
    ),
    'Hermes': (c) =>
        HermesPill(color: Colors.blue, label: Strings.of(c).statusReadOnly),
  };
  for (final surface in surfaces.entries) {
    testWidgets(
      '${surface.key} primary copy fits 360dp in both languages and scales',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final locale in ['es', 'en']) {
          for (final scale in [1.0, 1.3]) {
            await pumpPillCopy(
              tester,
              surface.value,
              locale: locale,
              scale: scale,
            );
            expectPillLabelsFit(tester, find.byType(Scaffold));
          }
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  test('compact localization length guards', () async {
    for (final locale in ['es', 'en']) {
      final s = await Strings.delegate.load(Locale(locale));
      final labels = <String, int>{
        s.chaTurnStillWorking: 16,
        s.subagentActivitySummary(12, 12): 24,
        s.subagentPillCount(12): 12,
        s.roomSummaryCompact: 15,
        s.roomRecipientsAll(12): 14,
        s.roomRecipientsSome(12, 12): 15,
        s.chaQueuedCount(12): 13,
        s.chaQueuedPausedCount(12): 13,
        s.chaBackgroundTaskDoneShort: 13,
        s.chaBackgroundTaskErrorShort: 15,
        s.chaGoalTurnLabel(12, 99): 12,
        s.dockCronLabel: 7,
        s.dockSessionsLabel: 5,
        s.dockToolsLabel: 6,
      };
      for (final entry in labels.entries) {
        expect(
          entry.key.length,
          lessThanOrEqualTo(entry.value),
          reason: '$locale: ${entry.key}',
        );
      }
    }
  });
}
