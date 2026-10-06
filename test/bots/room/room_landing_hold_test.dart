import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';

import '../../support/inter_font.dart';
import 'room_fixtures.dart';

/// QA 9491: opening a room with news from while away puts the "new since
/// you left" divider at the top of the screen, and it STAYS there while the
/// rows below it finish their layout (lazy estimates, previews, text that
/// reflows), until the reader scrolls.
final class _FakeTimer implements Timer {
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

final class _Gateway implements RoomGateway {
  HostedGroupRoom room;
  HostedGroupLogPage log;
  RoomDriverStatus? status;

  _Gateway({required this.room, required this.log, this.status});

  HostedGroupWorkspaceReadback get _readback => HostedGroupWorkspaceReadback(
    room: room,
    log: log,
    capabilityGeneration: 1,
    driverStatus: status,
  );

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async =>
      _readback;
  @override
  Future<HostedGroupWorkspaceReadback> send(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
  }) async => _readback;
  @override
  Future<HostedGroupWorkspaceReadback> rename(
    HostedGroupRoom room, {
    required String name,
  }) async => _readback;
  @override
  Future<HostedGroupWorkspaceReadback> stop(HostedGroupRoom room) async =>
      _readback;
  @override
  Future<HostedGroupWorkspaceReadback> disband(HostedGroupRoom room) async =>
      _readback;
  @override
  Future<void> approve(
    HostedGroupRoom room, {
    required RoomApprovalAction action,
    required String choice,
  }) async {}
  @override
  Future<void> retry(HostedGroupRoom room, {required String taskId}) async {}
}

const _caps = RoomCapabilities(
  canSend: true,
  canStop: true,
  canApprove: true,
  canRetry: true,
);

final _clockNow = DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000);

Future<_Gateway> _pump(
  WidgetTester tester, {
  required List<Map<String, dynamic>> events,
  required MemoryRoomPrefs prefs,
  RoomDriverStatus? status,
  bool logOnOpen = true,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final log = buildLog(events);
  final room = buildRoom(latestSeq: log.latestSeq);
  final gateway = _Gateway(room: room, log: log, status: status ?? driver());
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('en'),
      theme: AppTheme.hermesRedDark,
      home: RoomScreen(
        room: room,
        log: logOnOpen ? log : null,
        driverStatus: gateway.status,
        gateway: gateway,
        capabilities: _caps,
        profileFor: (_) => null,
        prefs: prefs,
        pollTimer: (_, _) => _FakeTimer(),
        clock: () => _clockNow,
      ),
    ),
  );
  await _frames(tester);
  return gateway;
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder get _transcript => find.byKey(const ValueKey('room-transcript'));
Finder get _divider => find.byKey(const ValueKey('room-new-since'));

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(
              const ValueKey('room-transcript'),
              skipOffstage: false,
            ),
            matching: find.byType(Scrollable, skipOffstage: false),
            skipOffstage: false,
          )
          .first,
    )
    .position;

/// Read history the reader already saw: 6 rounds of long replies.
List<Map<String, dynamic>> _readHistory(EventSeq seq) {
  final out = <Map<String, dynamic>>[];
  for (var r = 0; r < 6; r++) {
    final u = seq.user('question $r @builder', thread: 'thread-$r');
    final disc = u['event_id'] as String;
    out
      ..add(u)
      ..add(seq.started('m-builder', disc))
      ..add(
        seq.member(
          'm-builder',
          'builder',
          List.generate(6, (i) => 'Answer $r paragraph $i.').join('\n\n'),
          disc,
          thread: 'thread-$r',
        ),
      )
      ..add(seq.settled('m-builder', disc));
  }
  return out;
}

/// A turn event of a member in [thread].
Map<String, dynamic> _inThread(Map<String, dynamic> event, String thread) {
  (event['payload'] as Map<String, dynamic>)['thread_id'] = thread;
  return event;
}

/// Divider top relative to the top of what is readable: the transcript runs
/// under the floating header (fh1215), so that is the header's inset.
double _dividerFromTop(WidgetTester tester) =>
    tester.getTopLeft(_divider).dy -
    tester.getTopLeft(_transcript).dy -
    FloatingChatHeader.insetFor(tester.element(_transcript));

void main() {
  setUpAll(loadInterFont);

  group('QA 9491 · room landing stays on the divider', () {
    testWidgets('short rows first, tall rows later: the lazy estimate does '
        'not leave the divider low', (tester) async {
      final seq = EventSeq();
      final history = _readHistory(seq);
      final prefs = MemoryRoomPrefs();
      prefs.seen[roomPrefsKey(buildRoom())] = history.last['seq'] as int;
      final u = seq.user('while away @review', thread: 'thread-away');
      final disc = u['event_id'] as String;
      final news = [
        u,
        // The first news rows are short, so the list's first estimate of
        // what lies below the divider is far below its real height.
        for (var i = 0; i < 4; i++)
          seq.member(
            'm-review',
            'review',
            'ok $i',
            disc,
            thread: 'thread-away',
          ),
        for (var i = 0; i < 4; i++)
          seq.member(
            'm-review',
            'review',
            List.generate(10, (p) => 'Long $i paragraph $p.').join('\n\n'),
            disc,
            thread: 'thread-away',
          ),
      ];
      await _pump(tester, events: [...history, ...news], prefs: prefs);

      expect(_divider, findsOneWidget);
      final landed = _dividerFromTop(tester);
      // fh1215: it lands BELOW the floating header's pill, never under it.
      expect(
        tester.getTopLeft(_divider).dy,
        greaterThan(
          tester.getRect(find.byKey(const ValueKey('room-header'))).bottom,
        ),
      );
      expect(
        landed,
        inInclusiveRange(0, 80),
        reason: 'the divider sits at the top with ~1 row of context',
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_dividerFromTop(tester), closeTo(landed, 2));
      }
    });

    testWidgets('rows below the divider grow after the first frame: the '
        'divider rises to the top and stays there', (tester) async {
      final seq = EventSeq();
      final history = _readHistory(seq);
      final prefs = MemoryRoomPrefs();
      prefs.seen[roomPrefsKey(buildRoom())] = history.last['seq'] as int;
      final u = seq.user('while away @review', thread: 'thread-away');
      final disc = u['event_id'] as String;
      final news = [
        u,
        seq.member(
          'm-review',
          'review',
          // Tall enough at the grown text scale to fill the transcript
          // under the one-line room header.
          'Grow paragraph one.\n\nGrow paragraph two.\n\n'
              'Grow paragraph three.\n\nGrow paragraph four.',
          disc,
          thread: 'thread-away',
        ),
      ];
      await _pump(tester, events: [...history, ...news], prefs: prefs);
      expect(_divider, findsOneWidget);
      final viewport = tester.getSize(_transcript).height;
      // Precondition: before the growth, what is below the divider is
      // shorter than the screen, so the divider is not at the top yet.
      expect(_dividerFromTop(tester), greaterThan(120));

      // Previews and rich text finish their layout: every row is taller.
      tester.platformDispatcher.textScaleFactorTestValue = 2.6;
      await _frames(tester);
      final top = _dividerFromTop(tester);
      expect(
        top,
        inInclusiveRange(0, 80),
        reason:
            'what is below the divider now fills the screen '
            '(viewport $viewport): the landing keeps it at the top',
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_dividerFromTop(tester), closeTo(top, 2));
      }

      // Once the reader scrolls, the landing lets go.
      await tester.drag(_transcript, const Offset(0, 300));
      await _frames(tester);
      final afterDrag = _dividerFromTop(tester);
      expect(afterDrag, greaterThan(top + 100));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          _dividerFromTop(tester),
          closeTo(afterDrag, 1),
          reason: 'no snap back to the landing after a scroll',
        );
      }
    });

    testWidgets('a member typing at the bottom never overrides the landing', (
      tester,
    ) async {
      final seq = EventSeq();
      final history = _readHistory(seq);
      final prefs = MemoryRoomPrefs();
      prefs.seen[roomPrefsKey(buildRoom())] = history.last['seq'] as int;
      final u = seq.user('while away @review @builder', thread: 'thread-away');
      final disc = u['event_id'] as String;
      final news = [
        u,
        for (var i = 0; i < 3; i++)
          seq.member(
            'm-review',
            'review',
            List.generate(6, (p) => 'Away $i paragraph $p.').join('\n\n'),
            disc,
            thread: 'thread-away',
          ),
        _inThread(seq.started('m-builder', disc, task: 'tb'), 'thread-away'),
      ];
      await _pump(
        tester,
        events: [...history, ...news],
        prefs: prefs,
        status: driver(working: true, counts: {'running': 1}),
      );
      expect(_divider, findsOneWidget);
      final landed = _dividerFromTop(tester);
      // fh1215: it lands BELOW the floating header's pill, never under it.
      expect(
        tester.getTopLeft(_divider).dy,
        greaterThan(
          tester.getRect(find.byKey(const ValueKey('room-header'))).bottom,
        ),
      );
      expect(landed, inInclusiveRange(0, 80));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_dividerFromTop(tester), closeTo(landed, 2));
      }
      // The typing row is below, where the reader scrolls to it.
      await tester.drag(_transcript, const Offset(0, -6000));
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('room-typing-m-builder')),
        findsOneWidget,
        reason: 'precondition: a member is typing at the bottom',
      );
    });

    testWidgets('the log arriving after the read marker still lands', (
      tester,
    ) async {
      final seq = EventSeq();
      final history = _readHistory(seq);
      final prefs = MemoryRoomPrefs();
      prefs.seen[roomPrefsKey(buildRoom())] = history.last['seq'] as int;
      final u = seq.user('while away @review', thread: 'thread-away');
      final disc = u['event_id'] as String;
      final news = [
        u,
        for (var i = 0; i < 3; i++)
          seq.member(
            'm-review',
            'review',
            List.generate(6, (p) => 'Late $i paragraph $p.').join('\n\n'),
            disc,
            thread: 'thread-away',
          ),
      ];
      await _pump(
        tester,
        events: [...history, ...news],
        prefs: prefs,
        logOnOpen: false,
      );
      await tester.runAsync(
        () => tester
            .state<RoomScreenState>(
              find.byType(RoomScreen, skipOffstage: false),
            )
            .refresh(),
      );
      await _frames(tester);
      expect(_divider, findsOneWidget);
      expect(_dividerFromTop(tester), inInclusiveRange(0, 80));
    });

    testWidgets('nothing new: opens at the bottom', (tester) async {
      final seq = EventSeq();
      final history = _readHistory(seq);
      final prefs = MemoryRoomPrefs();
      prefs.seen[roomPrefsKey(buildRoom())] = history.last['seq'] as int;
      await _pump(tester, events: history, prefs: prefs);
      expect(_divider, findsNothing);
      // At the bottom (the open anchor may only reveal a run header).
      final newest = find.byKey(
        ValueKey('room-message-${history[history.length - 2]['event_id']}'),
      );
      expect(newest, findsOneWidget);
      final p = _position(tester);
      // The only shift allowed is the open anchor revealing the run header
      // of the row cut by the top edge, never so far that the newest message
      // leaves the screen. (A fixed pixel bound broke as soon as replies grew
      // a quote chip, rp1215.)
      expect(p.pixels, lessThan(p.minScrollExtent + p.viewportDimension));
      expect(
        tester.getRect(newest).top,
        lessThan(tester.getRect(_transcript).bottom),
      );
    });
  });
}
