import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../../support/inter_font.dart';
import 'room_fixtures.dart';

/// QA 9489: the room must not move under a reader, must never count
/// something that is not a new message from someone else, and the
/// "new since you left" divider exists only for what arrived while away.
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

  void publish(List<Map<String, dynamic>> events, {RoomDriverStatus? next}) {
    log = buildLog(events);
    room = buildRoom(latestSeq: log.latestSeq);
    status = next ?? status;
  }
}

const _caps = RoomCapabilities(
  canSend: true,
  canStop: true,
  canApprove: true,
  canRetry: true,
);

DateTime _clockNow = DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000);

Future<_Gateway> _pump(
  WidgetTester tester, {
  required List<Map<String, dynamic>> events,
  RoomDriverStatus? status,
  MemoryRoomPrefs? prefs,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  _clockNow = DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000);
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
        log: log,
        driverStatus: gateway.status,
        gateway: gateway,
        capabilities: _caps,
        profileFor: (_) => null,
        prefs: prefs ?? MemoryRoomPrefs(),
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

Future<void> _refresh(WidgetTester tester) async {
  await tester.runAsync(
    () => tester
        .state<RoomScreenState>(find.byType(RoomScreen, skipOffstage: false))
        .refresh(),
  );
  await _frames(tester);
}

List<Map<String, dynamic>> _longRoom(EventSeq seq, {int rounds = 12}) {
  final out = <Map<String, dynamic>>[];
  for (var r = 0; r < rounds; r++) {
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

/// A turn event of [member] in [thread] (the fixture's turn events always
/// sit in `thread-1`).
Map<String, dynamic> _inThread(Map<String, dynamic> event, String thread) {
  (event['payload'] as Map<String, dynamic>)['thread_id'] = thread;
  return event;
}

Finder get _transcript => find.byKey(const ValueKey('room-transcript'));
Finder get _pill => find.byKey(const ValueKey('room-new-pill'));
Finder get _divider => find.byKey(const ValueKey('room-new-since'));

String? _pillText(WidgetTester tester) {
  if (_pill.evaluate().isEmpty) return null;
  final texts = find.descendant(of: _pill, matching: find.byType(Text));
  return tester.widget<Text>(texts.first).data;
}

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

/// The message tile whose top is nearest below the list's top edge.
({String key, double top}) _reading(WidgetTester tester) {
  final listTop = tester.getTopLeft(_transcript).dy;
  final listBottom = tester.getBottomLeft(_transcript).dy;
  ({String key, double top})? best;
  for (final e
      in find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('room-message-'),
          )
          .evaluate()) {
    final box = e.renderObject;
    if (box is! RenderBox || !box.attached || !box.hasSize) continue;
    final top = box.localToGlobal(Offset.zero).dy;
    if (top < listTop || top > listBottom) continue;
    final key = (e.widget.key! as ValueKey<String>).value;
    if (best == null || top < best.top) best = (key: key, top: top);
  }
  return best!;
}

double _topOf(WidgetTester tester, String key) =>
    tester.getTopLeft(find.byKey(ValueKey(key))).dy;

/// Visible message tiles in on-screen order (top to bottom).
List<String> _onScreenOrder(WidgetTester tester) {
  final tiles = <({String key, double top})>[];
  for (final e
      in find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('room-message-'),
          )
          .evaluate()) {
    final box = e.renderObject;
    if (box is! RenderBox || !box.attached || !box.hasSize) continue;
    tiles.add((
      key: (e.widget.key! as ValueKey<String>).value,
      top: box.localToGlobal(Offset.zero).dy,
    ));
  }
  tiles.sort((a, b) => a.top.compareTo(b.top));
  return [for (final t in tiles) t.key];
}

Future<void> _background(WidgetTester tester) async {
  for (final s in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
    await tester.pump();
  }
}

Future<void> _foreground(WidgetTester tester) async {
  for (final s in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
    await tester.pump();
  }
}

void main() {
  setUpAll(loadInterFont);

  group('QA 9489 · room reading never jumps', () {
    testWidgets('member streaming, typing row, passes and identical polls '
        'never move the reader nor count anything but replies', (tester) async {
      final seq = EventSeq();
      final events = _longRoom(seq);
      // A round is running when the reader scrolls up: the typing row is
      // the last item of the list at that moment.
      final u = seq.user('next @builder @review', thread: 'thread-next');
      final disc = u['event_id'] as String;
      var all = [
        ...events,
        u,
        _inThread(seq.started('m-builder', disc, task: 'tb'), 'thread-next'),
      ];
      final gateway = await _pump(
        tester,
        events: all,
        status: driver(working: true, counts: {'running': 1}),
      );
      expect(find.byKey(const ValueKey('room-typing-m-builder')), findsOne);

      await tester.drag(_transcript, const Offset(0, 600));
      await _frames(tester);
      final reading = _reading(tester);

      Future<void> step(String label) async {
        await _refresh(tester);
        expect(
          _topOf(tester, reading.key),
          reading.top,
          reason: '$label moved the message being read',
        );
      }

      // Identical poll: same rows re-delivered.
      gateway.publish([...all]);
      await step('an identical poll');
      expect(_pill, findsNothing, reason: 'nothing new, nothing counted');

      // The reply replaces the typing row; a second member starts.
      all = [
        ...all,
        seq.member(
          'm-builder',
          'builder',
          'reply one',
          disc,
          thread: 'thread-next',
        ),
        _inThread(seq.settled('m-builder', disc, task: 'tb'), 'thread-next'),
        _inThread(seq.started('m-review', disc, task: 'tr'), 'thread-next'),
      ];
      gateway.publish(all);
      await step('a reply replacing the typing row');
      expect(_pillText(tester), '1 new');

      // The second member passes (a quiet "passed" line) and the owner
      // writes from another device: neither is news for the reader.
      all = [
        ...all,
        _inThread(
          seq.settled('m-review', disc, passed: true, task: 'tr'),
          'thread-next',
        ),
        seq.user('and also this', thread: 'thread-next'),
      ];
      gateway.publish(all, next: driver());
      await step('a pass line and the owner\'s own message');
      expect(_pillText(tester), '1 new', reason: 'own/quiet rows not counted');

      // Same rows again (polling refresh re-inserting them).
      gateway.publish([...all]);
      await step('a second identical poll');
      expect(_pillText(tester), '1 new');

      // Back to the bottom: chronological order, no duplicates.
      await tester.tap(_pill);
      await tester.pumpAndSettle();
      expect(_pill, findsNothing);
      final p = _position(tester);
      expect(p.pixels, closeTo(p.minScrollExtent, 0.5));
      final order = _onScreenOrder(tester);
      expect(order.toSet(), hasLength(order.length));
      final expected = [
        for (final e in gateway.log.events)
          if (e.publicText != null &&
              order.contains('room-message-${e.eventId}'))
            'room-message-${e.eventId}',
      ];
      expect(order, expected, reason: 'rows stay in log order');
      expect(tester.takeException(), isNull);
    });

    testWidgets('at the bottom while a member streams: follows, no pill', (
      tester,
    ) async {
      final seq = EventSeq();
      final events = _longRoom(seq, rounds: 4);
      final u = seq.user('ping @review', thread: 'thread-ping');
      final disc = u['event_id'] as String;
      var all = [
        ...events,
        u,
        _inThread(seq.started('m-review', disc, task: 'tr'), 'thread-ping'),
      ];
      final gateway = await _pump(
        tester,
        events: all,
        status: driver(working: true, counts: {'running': 1}),
      );
      for (var i = 0; i < 3; i++) {
        all = [
          ...all,
          seq.member(
            'm-review',
            'review',
            'part $i\n\nmore $i',
            disc,
            thread: 'thread-ping',
          ),
        ];
        gateway.publish(all);
        await _refresh(tester);
        final p = _position(tester);
        expect(p.pixels, closeTo(p.minScrollExtent, 0.5), reason: 'step $i');
        expect(_pill, findsNothing);
        expect(_divider, findsNothing);
        final newest = gateway.log.events.last.eventId;
        expect(
          tester.getBottomLeft(find.byKey(ValueKey('room-message-$newest'))).dy,
          lessThanOrEqualTo(tester.getBottomLeft(_transcript).dy),
        );
      }
    });

    testWidgets('scrolled up while 3 replies arrive: pill "3 new", no '
        'divider appears', (tester) async {
      final seq = EventSeq();
      final events = _longRoom(seq);
      final gateway = await _pump(tester, events: events);
      await tester.drag(_transcript, const Offset(0, 600));
      await _frames(tester);
      final reading = _reading(tester);
      final u = seq.user('ping @review', thread: 'thread-ping');
      final disc = u['event_id'] as String;
      gateway.publish([
        ...events,
        u,
        for (var i = 0; i < 3; i++)
          seq.member(
            'm-review',
            'review',
            'reply $i',
            disc,
            thread: 'thread-ping',
          ),
      ]);
      await _refresh(tester);
      expect(_topOf(tester, reading.key), reading.top);
      expect(_pillText(tester), '3 new');
      expect(
        _divider,
        findsNothing,
        reason: 'arrivals while in the room are not "since you left"',
      );
    });
  });

  group('QA 9489 · pill only while in the room', () {
    testWidgets('arrivals while covered or in the background never reach '
        'the pill; arrivals while reading do', (tester) async {
      final seq = EventSeq();
      final events = _longRoom(seq);
      final gateway = await _pump(tester, events: events);
      await tester.drag(_transcript, const Offset(0, 600));
      await _frames(tester);
      final u = seq.user('ping @review', thread: 'thread-ping');
      final disc = u['event_id'] as String;
      var all = [...events, u];

      // Covered by another route: a poll lands two replies.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      all = [
        ...all,
        for (var i = 0; i < 2; i++)
          seq.member(
            'm-review',
            'review',
            'covered $i',
            disc,
            thread: 'thread-ping',
          ),
      ];
      gateway.publish(all);
      await _refresh(tester);
      expect(
        find.byKey(const ValueKey('room-new-pill'), skipOffstage: false),
        findsNothing,
        reason: 'no pill for a reader who is not in the room',
      );
      navigator.pop();
      await tester.pumpAndSettle();
      await _refresh(tester);
      expect(_pill, findsNothing);

      // Short background, then a reply arrives on the first read back.
      await _background(tester);
      all = [
        ...all,
        seq.member(
          'm-review',
          'review',
          'background',
          disc,
          thread: 'thread-ping',
        ),
      ];
      gateway.publish(all);
      _clockNow = _clockNow.add(const Duration(seconds: 5));
      await _foreground(tester);
      await _refresh(tester);
      expect(_pill, findsNothing);

      // In the room, reading: this one counts.
      gateway.publish([
        ...all,
        seq.member('m-review', 'review', 'live', disc, thread: 'thread-ping'),
      ]);
      await _refresh(tester);
      expect(_pillText(tester), '1 new');
    });
  });

  group('QA 9489 · new since you left', () {
    testWidgets('leave and return with 3 new: opens at the first new reply '
        'under the divider, no pill', (tester) async {
      final seq = EventSeq();
      final events = _longRoom(seq);
      final seen = events.last['seq'] as int;
      final u = seq.user('while away @review', thread: 'thread-away');
      final disc = u['event_id'] as String;
      final replies = [
        for (var i = 0; i < 3; i++)
          seq.member(
            'm-review',
            'review',
            List.generate(5, (p) => 'Away $i paragraph $p.').join('\n\n'),
            disc,
            thread: 'thread-away',
          ),
      ];
      final prefs = MemoryRoomPrefs();
      prefs.seen[roomPrefsKey(buildRoom())] = seen;
      await _pump(tester, events: [...events, u, ...replies], prefs: prefs);

      expect(_divider, findsOneWidget);
      final listTop = tester.getTopLeft(_transcript).dy;
      final dividerTop = tester.getTopLeft(_divider).dy;
      expect(
        dividerTop,
        greaterThanOrEqualTo(listTop),
        reason: 'the divider is on screen',
      );
      expect(
        dividerTop,
        lessThan(listTop + 160),
        reason: 'the divider sits at the top, with a little context',
      );
      final first = 'room-message-${replies.first['event_id']}';
      expect(_topOf(tester, first), greaterThan(dividerTop));
      expect(_pill, findsNothing, reason: 'away news never shows the pill');
      final p = _position(tester);
      expect(
        p.pixels,
        greaterThan(p.minScrollExtent + 100),
        reason: 'not opened at the last message',
      );

      // Stillness: no correction frames after landing.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(_divider).dy, dividerTop);
      }
    });

    testWidgets('own messages alone after the marker: no divider', (
      tester,
    ) async {
      final seq = EventSeq();
      final events = _longRoom(seq, rounds: 4);
      final prefs = MemoryRoomPrefs();
      prefs.seen[roomPrefsKey(buildRoom())] = events.last['seq'] as int;
      await _pump(
        tester,
        events: [
          ...events,
          seq.user('just me', thread: 'thread-x'),
        ],
        prefs: prefs,
      );
      expect(_divider, findsNothing);
      expect(_pill, findsNothing);
    });

    testWidgets('nothing new on entry, then a reply while in the room: no '
        'divider, no pill at the bottom', (tester) async {
      final seq = EventSeq();
      final events = _longRoom(seq, rounds: 4);
      final prefs = MemoryRoomPrefs();
      prefs.seen[roomPrefsKey(buildRoom())] = events.last['seq'] as int;
      final gateway = await _pump(tester, events: events, prefs: prefs);
      final u = seq.user('ping @review', thread: 'thread-ping');
      gateway.publish([
        ...events,
        u,
        seq.member(
          'm-review',
          'review',
          'hi',
          u['event_id'] as String,
          thread: 'thread-ping',
        ),
      ]);
      await _refresh(tester);
      expect(_divider, findsNothing);
      expect(_pill, findsNothing);
    });

    testWidgets('backgrounded long enough: news lands on a divider; a short '
        'background does not', (tester) async {
      final seq = EventSeq();
      final events = _longRoom(seq);
      final gateway = await _pump(tester, events: events);

      // Short trip: 5 s.
      await _background(tester);
      final u = seq.user('ping @review', thread: 'thread-ping');
      final disc = u['event_id'] as String;
      var all = [
        ...events,
        u,
        seq.member('m-review', 'review', 'quick', disc, thread: 'thread-ping'),
      ];
      gateway.publish(all);
      _clockNow = _clockNow.add(const Duration(seconds: 5));
      await _foreground(tester);
      await _refresh(tester);
      expect(_divider, findsNothing);
      expect(_pill, findsNothing);

      // Long trip: 10 min, three long replies.
      await _background(tester);
      final away = [
        for (var i = 0; i < 3; i++)
          seq.member(
            'm-review',
            'review',
            List.generate(6, (p) => 'Later $i paragraph $p.').join('\n\n'),
            disc,
            thread: 'thread-ping',
          ),
      ];
      all = [...all, ...away];
      gateway.publish(all);
      _clockNow = _clockNow.add(const Duration(minutes: 10));
      await _foreground(tester);
      await _refresh(tester);
      expect(_divider, findsOneWidget);
      final listTop = tester.getTopLeft(_transcript).dy;
      expect(
        tester.getTopLeft(_divider).dy,
        inInclusiveRange(listTop, listTop + 160),
      );
      expect(_pill, findsNothing);
    });

    testWidgets('covered (App Lock) on return: nothing moves until uncovered', (
      tester,
    ) async {
      final seq = EventSeq();
      final events = _longRoom(seq);
      final gateway = await _pump(tester, events: events);
      await _background(tester);
      final u = seq.user('ping @review', thread: 'thread-ping');
      final disc = u['event_id'] as String;
      gateway.publish([
        ...events,
        u,
        for (var i = 0; i < 3; i++)
          seq.member(
            'm-review',
            'review',
            List.generate(6, (p) => 'Locked $i paragraph $p.').join('\n\n'),
            disc,
            thread: 'thread-ping',
          ),
      ]);
      _clockNow = _clockNow.add(const Duration(minutes: 10));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('locked')),
          ),
        ),
      );
      await _foreground(tester);
      await tester.pumpAndSettle();
      final before = _position(tester).pixels;
      // A poll that sneaks in under the cover neither shows the divider
      // nor scrolls up to it.
      await _refresh(tester);
      // Following may keep the bottom; it never lands on a divider.
      expect(_position(tester).pixels, lessThanOrEqualTo(before));
      expect(
        find.byKey(const ValueKey('room-new-since'), skipOffstage: false),
        findsNothing,
      );

      navigator.pop();
      await tester.pumpAndSettle();
      await _refresh(tester);
      expect(_divider, findsOneWidget);
      expect(_pill, findsNothing);
    });
  });
}
