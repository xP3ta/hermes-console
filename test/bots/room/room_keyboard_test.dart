import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../../support/inter_font.dart';
import 'room_fixtures.dart';

final class _FakeTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
}

final class _Gateway implements RoomGateway {
  final HostedGroupRoom room;
  final HostedGroupLogPage log;
  _Gateway(this.room, this.log);

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async =>
      HostedGroupWorkspaceReadback(
        room: this.room,
        log: log,
        capabilityGeneration: 1,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> events,
) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final log = buildLog(events);
  final room = buildRoom(latestSeq: log.latestSeq);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('en'),
      theme: AppTheme.hermesRedDark,
      home: RoomScreen(
        room: room,
        log: log,
        gateway: _Gateway(room, log),
        capabilities: const RoomCapabilities(
          canSend: true,
          canRename: true,
          canStop: true,
          canDisband: true,
          canApprove: true,
          canRetry: true,
        ),
        profileFor: (_) => null,
        prefs: MemoryRoomPrefs(),
        pollTimer: (_, _) => _FakeTimer(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Thirty question/answer pairs, each in its own thread, so the
/// transcript scrolls well past one screen.
List<Map<String, dynamic>> _longRoom(EventSeq seq) => [
  for (var i = 0; i < 30; i++)
    ...() {
      final u = seq.user('question $i', thread: 't$i', id: 'user-$i');
      return [
        u,
        seq.member(
          'm-builder',
          'builder',
          'answer $i\n\nline two\n\nline three',
          u['event_id'] as String,
          thread: 't$i',
        ),
      ];
    }(),
];

Finder get _field => find.descendant(
  of: find.byType(ConsoleComposer),
  matching: find.byType(TextField),
);

Finder get _transcript => find.byKey(const ValueKey('room-transcript'));

bool _transcriptMoving(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: _transcript, matching: find.byType(Scrollable)).first,
    )
    .position
    .isScrollingNotifier
    .value;

bool _composerFocused(WidgetTester tester) =>
    tester.widget<TextField>(_field).focusNode!.hasFocus;

void main() {
  setUpAll(loadInterFont);

  group('scrolling never hands the keyboard back to the composer', () {
    testWidgets('a tapped message scrolled out of view by drags', (
      tester,
    ) async {
      await _pump(tester, _longRoom(EventSeq()));
      await tester.tap(_field);
      await tester.pump();
      expect(_composerFocused(tester), isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      // Tapping a message moves focus to its selection region: the
      // keyboard closes, as it should.
      await tester.tap(
        find.textContaining('question 29', findRichText: true).first,
      );
      await tester.pump();
      expect(_composerFocused(tester), isFalse);
      expect(tester.testTextInput.isVisible, isFalse);

      // Reading back until that message is recycled must not reopen it.
      for (var i = 0; i < 6; i++) {
        await tester.drag(_transcript, const Offset(0, 500));
        await tester.pump();
        expect(_composerFocused(tester), isFalse, reason: 'drag $i');
        expect(tester.testTextInput.isVisible, isFalse, reason: 'drag $i');
      }
      await tester.pumpAndSettle();
      expect(_composerFocused(tester), isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('a tapped message flung away, then a tap stops the fling', (
      tester,
    ) async {
      await _pump(tester, _longRoom(EventSeq()));
      await tester.tap(_field);
      await tester.pump();
      await tester.tap(
        find.textContaining('question 29', findRichText: true).first,
      );
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);

      await tester.fling(_transcript, const Offset(0, 1200), 3000);
      await tester.pump(const Duration(milliseconds: 120));
      expect(_transcriptMoving(tester), isTrue, reason: 'fling in flight');
      // Stop the fling with a tap in the middle of the transcript.
      await tester.tapAt(tester.getCenter(_transcript));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(_composerFocused(tester), isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('control: a composer focused by the user stays focused', (
      tester,
    ) async {
      await _pump(tester, _longRoom(EventSeq()));
      await tester.tap(_field);
      await tester.pump();
      await tester.drag(_transcript, const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(_composerFocused(tester), isTrue);
    });
  });

  group('reply in thread', () {
    testWidgets('the inline reply icon sets the thread and focuses composer', (
      tester,
    ) async {
      await _pump(tester, _longRoom(EventSeq()));
      expect(_composerFocused(tester), isFalse);
      await tester.tap(find.byKey(const ValueKey('room-reply-user-29')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-thread-banner')), findsOneWidget);
      expect(_composerFocused(tester), isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets(
      'a tap that stops a fling over a reply icon replies to nothing',
      (tester) async {
        await _pump(tester, _longRoom(EventSeq()));
        await tester.fling(_transcript, const Offset(0, 600), 2500);
        await tester.pump(const Duration(milliseconds: 60));
        expect(_transcriptMoving(tester), isTrue, reason: 'fling in flight');
        final icons = find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('room-reply-'),
        );
        expect(icons, findsWidgets);
        await tester.tapAt(tester.getCenter(icons.first));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('room-thread-banner')), findsNothing);
        expect(_composerFocused(tester), isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
      },
    );

    testWidgets('control: Reply from the thread page focuses the composer', (
      tester,
    ) async {
      final seq = EventSeq();
      await _pump(tester, [
        seq.user('status?', id: 'root'),
        seq.member('m-builder', 'builder', 'one', 'root'),
        seq.user('and now?', id: 'follow-up'),
        seq.member('m-builder', 'builder', 'two', 'follow-up'),
      ]);
      final summary = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'room-thread-summary-',
            ),
      );
      await tester.tap(summary.first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('room-thread-reply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-thread-banner')), findsOneWidget);
      expect(_composerFocused(tester), isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });
  });
}
