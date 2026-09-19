import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/room_summary.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/room_summary_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'room_member_status_test.dart' show statusEvent, statusRoom, statusNow;

void main() {
  final events = [
    statusEvent(1, 'message.user', text: '@forja review the release'),
    for (var i = 2; i < 12; i++)
      statusEvent(
        i,
        'turn.settled',
        payload: {'task_id': 'task-$i', 'passed': true},
      ),
  ];
  final summary = deriveRoomSummary(
    events: events,
    members: statusRoom.members,
    localGatewayId: 'gateway',
    now: statusNow,
  );
  Future<void> pump(
    WidgetTester tester, {
    bool compact = false,
    bool reduced = true,
    ThemeData? theme,
    RoomSummary? data,
    double scale = 1,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.hermesRedLight,
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(
          disableAnimations: reduced,
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: RoomSummaryPill(
              summary: data ?? summary,
              localGatewayId: 'gateway',
              compact: compact,
              maxHeight: 300,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'slim collapsed pill expands in place and pages six rows per section',
    (tester) async {
      await pump(tester);
      expect(find.text('10 done'), findsOneWidget);
      expect(find.byKey(const ValueKey('room-summary-expanded')), findsNothing);
      final before = tester.getTopLeft(
        find.byKey(const ValueKey('room-summary-pill')),
      );
      await tester.tap(find.byKey(const ValueKey('room-summary-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.text('Current topic: @forja review the release'),
        findsOneWidget,
      );
      expect(find.text('Done'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('room-summary-pill'))),
        before,
      );
      expect(
        find.byKey(const ValueKey('room-summary-done-turn:forja:task-11')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('room-summary-done-turn:forja:task-2')),
        findsNothing,
      );
      final more = find.byKey(const ValueKey('room-summary-more-done'));
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('room-summary-done-turn:forja:task-2')),
        findsOneWidget,
      );
      expect(more, findsNothing);
      await tester.tap(find.byKey(const ValueKey('room-summary-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-summary-expanded')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keyboard or recipients preview collapses expanded summary and it stays collapsed',
    (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('room-summary-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('room-summary-expanded')),
        findsOneWidget,
      );
      await pump(tester, compact: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-summary-expanded')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('room-summary-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-summary-expanded')), findsNothing);
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-summary-expanded')), findsNothing);
    },
  );

  testWidgets('motion uses 200ms ease and is removed under reduce motion', (
    tester,
  ) async {
    await pump(tester, reduced: false);
    AnimatedSize animation() => tester.widget<AnimatedSize>(
      find.descendant(
        of: find.byKey(const ValueKey('room-summary-pill')),
        matching: find.byType(AnimatedSize),
      ),
    );
    expect(animation().duration, const Duration(milliseconds: 200));
    expect(animation().curve, Curves.easeInOut);
    await pump(tester, reduced: true);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('room-summary-pill')),
        matching: find.byType(AnimatedSize),
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('room-summary-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('room-summary-expanded')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'needs-you is an avatar dot and plain summary line, light and dark',
    (tester) async {
      final needs = deriveRoomSummary(
        events: [statusEvent(1, 'message.member', text: '@user confirm')],
        members: statusRoom.members,
        localGatewayId: 'gateway',
        now: statusNow,
      );
      for (final theme in [AppTheme.hermesRedLight, AppTheme.hermesRedDark]) {
        await pump(tester, data: needs, theme: theme, scale: 2);
        expect(
          find.byKey(const ValueKey('room-status-forja-needsYou')),
          findsOneWidget,
        );
        expect(find.text('1 needs you · 1 done'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('room-summary-toggle')));
        await tester.pumpAndSettle();
        expect(find.text('forja is waiting for you'), findsWidgets);
        expect(find.byType(Card), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}
