import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/bots/ui/room/room_widgets.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../../support/inter_font.dart';
import 'room_fixtures.dart';

/// Bot Mode polish, direction A (fixed status strip):
/// the room's status area never changes height, never pushes what the user
/// is reading, and no card is ever left without a way out.
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
  final List<String> calls = [];
  Completer<void>? retryGate;

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
  Future<HostedGroupWorkspaceReadback> stop(HostedGroupRoom room) async {
    calls.add('stop');
    return _readback;
  }

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
  Future<void> retry(HostedGroupRoom room, {required String taskId}) async {
    calls.add('retry:$taskId');
    await retryGate?.future;
  }
}

const _caps = RoomCapabilities(
  canSend: true,
  canStop: true,
  canApprove: true,
  canRetry: true,
);

Widget _host(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: locale,
  theme: AppTheme.hermesRedDark,
  home: child,
);

Future<_Gateway> _pump(
  WidgetTester tester, {
  required List<Map<String, dynamic>> events,
  RoomDriverStatus? status,
  RoomCapabilities caps = _caps,
  RoomLocalPrefs? prefs,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final log = buildLog(events);
  final room = buildRoom(latestSeq: log.latestSeq);
  final gateway = _Gateway(room: room, log: log, status: status);
  await tester.pumpWidget(
    _host(
      RoomScreen(
        room: room,
        log: log,
        driverStatus: status,
        gateway: gateway,
        capabilities: caps,
        profileFor: (_) => null,
        prefs: prefs ?? MemoryRoomPrefs(),
        pollTimer: (_, _) => _FakeTimer(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
      ),
      locale: locale,
    ),
  );
  // Working faces animate forever: pump frames instead of settling.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return gateway;
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _refresh(WidgetTester tester) async {
  await tester.runAsync(
    () => tester.state<RoomScreenState>(find.byType(RoomScreen)).refresh(),
  );
  await _frames(tester);
}

/// A long, idle, finished conversation (many paragraphs to scroll).
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

Finder get _strip => find.byKey(const ValueKey('room-status-strip'));
Finder get _transcript => find.byKey(const ValueKey('room-transcript'));

/// Top edge (global y) of the first message tile visible in the transcript.
({String key, double top}) _firstVisible(WidgetTester tester) {
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

void main() {
  setUpAll(loadInterFont);

  group('A · fixed status strip', () {
    testWidgets('C4 strip has the same height in every room state', (
      tester,
    ) async {
      final heights = <String, double>{};
      Future<void> measure(
        String label,
        List<Map<String, dynamic>> events,
        RoomDriverStatus? status,
      ) async {
        await _pump(tester, events: events, status: status);
        expect(_strip, findsOneWidget, reason: label);
        heights[label] = tester.getSize(_strip).height;
      }

      var seq = EventSeq();
      var u = seq.user('@builder go');
      var disc = u['event_id'] as String;
      await measure('idle-finished', [
        u,
        seq.started('m-builder', disc),
        seq.member('m-builder', 'builder', 'done', disc),
        seq.settled('m-builder', disc),
      ], driver());

      seq = EventSeq();
      u = seq.user('@builder @review go');
      disc = u['event_id'] as String;
      await measure('working', [
        u,
        seq.started('m-builder', disc),
      ], driver(working: true, counts: {'running': 1, 'queued': 1}));

      seq = EventSeq();
      u = seq.user('@lead merge');
      disc = u['event_id'] as String;
      await measure('needs-you', [
        u,
        seq.started('m-lead', disc),
      ], driver(working: true, pending: [approvalAction()]));

      seq = EventSeq();
      u = seq.user('@radar check');
      disc = u['event_id'] as String;
      await measure(
        'failed',
        [
          u,
          seq.started('m-radar', disc, task: 'task-r'),
          seq.failed('m-radar', disc, task: 'task-r'),
        ],
        driver(
          blocked: true,
          pending: [
            {'kind': 'retry', 'task_id': 'task-r'},
          ],
        ),
      );

      await measure('empty', const [], null);

      expect(heights.values.toSet(), {
        RoomStatusStrip.height,
      }, reason: '$heights');
    });

    testWidgets('C2 the old inserted round panel no longer exists', (
      tester,
    ) async {
      final seq = EventSeq();
      final u = seq.user('@builder go');
      await _pump(
        tester,
        events: [u, seq.started('m-builder', u['event_id'] as String)],
        status: driver(working: true),
      );
      expect(find.byKey(const ValueKey('room-round-panel')), findsNothing);
      // The strip is outside the scrollable transcript.
      expect(find.descendant(of: _transcript, matching: _strip), findsNothing);
    });

    testWidgets('strip shows one face per member with its state dot', (
      tester,
    ) async {
      final seq = EventSeq();
      final u = seq.user('@builder @review @lead @radar ship it');
      final disc = u['event_id'] as String;
      await _pump(
        tester,
        events: [
          u,
          seq.started('m-builder', disc),
          seq.started('m-lead', disc),
          seq.settled('m-radar', disc, passed: true),
        ],
        status: driver(
          working: true,
          counts: {'running': 2, 'queued': 1},
          pending: [approvalAction()],
        ),
      );
      for (final (id, state) in const [
        ('m-builder', 'working'),
        ('m-review', 'queued'),
        ('m-lead', 'needsYou'),
        ('m-radar', 'passed'),
      ]) {
        expect(
          find.descendant(
            of: _strip,
            matching: find.byKey(ValueKey('room-strip-dot-$id-$state')),
          ),
          findsOneWidget,
          reason: '$id should be $state',
        );
      }
      // Needs-you wins the one-line summary.
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('room-strip-summary')))
            .data,
        'console-lead needs you',
      );
    });

    testWidgets('C5 red only for failures; needs-you is amber', (tester) async {
      final seq = EventSeq();
      final u = seq.user('@lead @radar go');
      final disc = u['event_id'] as String;
      await _pump(
        tester,
        events: [
          u,
          seq.started('m-lead', disc),
          seq.started('m-radar', disc, task: 'task-r'),
          seq.failed('m-radar', disc, task: 'task-r'),
        ],
        status: driver(
          working: true,
          pending: [
            approvalAction(),
            {'kind': 'retry', 'task_id': 'task-r'},
          ],
        ),
      );
      final colors = Theme.of(tester.element(_strip)).hermes;
      Color dot(String key) {
        final box = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(DecoratedBox),
          ),
        );
        return (box.decoration as BoxDecoration).color!;
      }

      expect(dot('room-strip-dot-m-radar-failed'), colors.error);
      expect(dot('room-strip-dot-m-lead-needsYou'), colors.warning);
      for (final state in RoomTurnState.values.where(
        (s) => s != RoomTurnState.failed,
      )) {
        expect(
          roomTurnDotColor(colors, state),
          isNot(colors.error),
          reason: state.name,
        );
      }
    });

    testWidgets('tapping the strip opens a floating detail, not a push', (
      tester,
    ) async {
      final seq = EventSeq();
      final u = seq.user('@builder @lead ship it');
      final disc = u['event_id'] as String;
      final gateway = await _pump(
        tester,
        events: [
          u,
          seq.started('m-builder', disc),
          seq.started('m-lead', disc),
        ],
        status: driver(working: true, pending: [approvalAction()]),
      );
      final listTop = tester.getTopLeft(_transcript).dy;
      await tester.tap(_strip);
      await _frames(tester);
      final sheet = find.byKey(const ValueKey('room-round-sheet'));
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(
          of: sheet,
          matching: find.byKey(const ValueKey('room-round-row-m-builder')),
        ),
        findsOneWidget,
      );
      expect(find.text('Wants to run gh pr ready 51'), findsOneWidget);
      // The transcript did not move.
      expect(tester.getTopLeft(_transcript).dy, listTop);
      // Stop all lives in the detail.
      await tester.tap(find.byKey(const ValueKey('room-stop-all')));
      await _frames(tester);
      await tester.tap(
        find.byKey(const ValueKey('hermes-confirm-dialog-confirm')),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _frames(tester);
      expect(gateway.calls, contains('stop'));
    });
  });

  group('A · reading never jumps', () {
    testWidgets('C1 a bot starting while you read moves nothing (0 px)', (
      tester,
    ) async {
      final seq = EventSeq();
      final events = _longRoom(seq);
      final gateway = await _pump(tester, events: events, status: driver());
      // Scroll up to read (offset > 150 on the reversed list).
      await tester.drag(_transcript, const Offset(0, 600));
      await _frames(tester);
      final reading = _firstVisible(tester);
      final listTop = tester.getTopLeft(_transcript).dy;

      // Round starts: status only, no new message.
      final u = seq.user('next @builder', thread: 'thread-next');
      final disc = u['event_id'] as String;
      final all = [...events, u, seq.started('m-builder', disc)];
      gateway
        ..log = buildLog(all)
        ..room = buildRoom(latestSeq: gateway.log.latestSeq)
        ..status = driver(working: true, counts: {'running': 1});
      await _refresh(tester);
      expect(tester.getTopLeft(_transcript).dy, listTop);
      expect(_topOf(tester, reading.key), reading.top);

      // Round ends.
      final reply = seq.member(
        'm-builder',
        'builder',
        'short',
        disc,
        thread: 'thread-next',
      );
      gateway
        ..log = buildLog([...all, reply])
        ..room = buildRoom(latestSeq: gateway.log.latestSeq)
        ..status = driver();
      await _refresh(tester);
      expect(tester.getTopLeft(_transcript).dy, listTop);
      expect(_topOf(tester, reading.key), reading.top);
    });

    testWidgets('C1 new message while reading: stays put, pill "1 new"', (
      tester,
    ) async {
      final seq = EventSeq();
      final events = _longRoom(seq);
      final gateway = await _pump(tester, events: events, status: driver());
      await tester.drag(_transcript, const Offset(0, 600));
      await _frames(tester);
      final reading = _firstVisible(tester);
      final pill = find.byKey(const ValueKey('room-new-pill'));
      expect(pill, findsNothing);

      final u = seq.user('ping @review', thread: 'thread-ping');
      final reply = seq.member(
        'm-review',
        'review',
        'a new long reply\n\nwith two paragraphs',
        u['event_id'] as String,
        thread: 'thread-ping',
      );
      gateway
        ..log = buildLog([...events, u, reply])
        ..room = buildRoom(latestSeq: gateway.log.latestSeq);
      await _refresh(tester);
      expect(_topOf(tester, reading.key), reading.top);
      expect(pill, findsOneWidget);
      expect(
        find.descendant(of: pill, matching: find.text('2 new')),
        findsOneWidget,
      );
      // The pill floats: it is not a transcript item.
      expect(find.descendant(of: _transcript, matching: pill), findsNothing);

      await tester.tap(pill);
      await tester.pumpAndSettle();
      final scroll = tester
          .state<ScrollableState>(
            find
                .descendant(of: _transcript, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      expect(scroll.pixels, 0);
      expect(pill, findsNothing);
    });

    testWidgets('at the bottom, new messages keep you at the bottom', (
      tester,
    ) async {
      final seq = EventSeq();
      final events = _longRoom(seq, rounds: 4);
      final gateway = await _pump(tester, events: events, status: driver());
      ScrollPosition position() => tester
          .state<ScrollableState>(
            find
                .descendant(of: _transcript, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      final u = seq.user('ping @review', thread: 'thread-ping');
      gateway
        ..log = buildLog([
          ...events,
          u,
          seq.member(
            'm-review',
            'review',
            'hi',
            u['event_id'] as String,
            thread: 'thread-ping',
          ),
        ])
        ..room = buildRoom(latestSeq: gateway.log.latestSeq);
      await _refresh(tester);
      expect(position().pixels, position().minScrollExtent);
      final newest = gateway.log.events.last.eventId;
      expect(
        tester.getBottomLeft(find.byKey(ValueKey('room-message-$newest'))).dy,
        lessThanOrEqualTo(tester.getBottomLeft(_transcript).dy),
      );
      expect(find.byKey(const ValueKey('room-new-pill')), findsNothing);
    });
  });

  group('A · every card has a way out', () {
    Future<_Gateway> failedRoom(
      WidgetTester tester, {
      RoomCapabilities caps = _caps,
      RoomLocalPrefs? prefs,
    }) {
      final seq = EventSeq();
      final u = seq.user('@radar check');
      final disc = u['event_id'] as String;
      return _pump(
        tester,
        events: [
          u,
          seq.started('m-radar', disc, task: 'task-r'),
          seq.failed('m-radar', disc, task: 'task-r'),
        ],
        status: driver(
          blocked: true,
          pending: [
            {'kind': 'retry', 'task_id': 'task-r'},
          ],
        ),
        caps: caps,
        prefs: prefs,
      );
    }

    testWidgets('C6 without server retry: no dead button, only Dismiss', (
      tester,
    ) async {
      await failedRoom(
        tester,
        caps: const RoomCapabilities(canSend: true, canStop: true),
      );
      expect(find.text('console-radar could not reply'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('room-retry-task-r-action')),
        findsNothing,
      );
      final dismiss = find.byKey(const ValueKey('room-retry-task-r-dismiss'));
      expect(dismiss, findsOneWidget);
      expect(tester.widget<TextButton>(dismiss).onPressed, isNotNull);
    });

    testWidgets('C6 dismiss removes the card and the strip alert, and sticks', (
      tester,
    ) async {
      final prefs = MemoryRoomPrefs();
      await failedRoom(tester, prefs: prefs);
      expect(
        find.byKey(const ValueKey('room-strip-dot-m-radar-failed')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('room-retry-task-r-dismiss')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _frames(tester);
      expect(find.byKey(const ValueKey('room-retry-task-r')), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('room-strip-summary')))
            .data,
        isNot(contains('failed')),
      );

      // Reopening the room with the same device prefs keeps it dismissed.
      await tester.pumpWidget(const SizedBox());
      await failedRoom(tester, prefs: prefs);
      expect(find.byKey(const ValueKey('room-retry-task-r')), findsNothing);
    });

    testWidgets('C6 with server retry: Retry and Dismiss both work', (
      tester,
    ) async {
      final gateway = await failedRoom(tester);
      expect(
        find.byKey(const ValueKey('room-retry-task-r-dismiss')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('room-retry-task-r-action')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _frames(tester);
      expect(gateway.calls, ['retry:task-r']);
    });

    testWidgets('C7 retry is a no-op while one is in flight', (tester) async {
      final gateway = await failedRoom(tester);
      gateway.retryGate = Completer<void>();
      final retry = find.byKey(const ValueKey('room-retry-task-r-action'));
      await tester.tap(retry);
      await tester.pump();
      await tester.tap(retry, warnIfMissed: false);
      await tester.pump();
      gateway.retryGate!.complete();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _frames(tester);
      expect(gateway.calls.where((c) => c.startsWith('retry')), hasLength(1));
    });

    testWidgets('dismissing a fixed-in-place failure never hides a new one', (
      tester,
    ) async {
      final prefs = MemoryRoomPrefs();
      final gateway = await failedRoom(tester, prefs: prefs);
      await tester.tap(find.byKey(const ValueKey('room-retry-task-r-dismiss')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _frames(tester);
      gateway.status = driver(
        blocked: true,
        pending: [
          {'kind': 'retry', 'task_id': 'task-r2'},
        ],
      );
      await _refresh(tester);
      expect(find.byKey(const ValueKey('room-retry-task-r2')), findsOneWidget);
    });
  });

  group('A · open anchor and typing cost', () {
    testWidgets(
      'C3 first poll block landing after open anchors at the bottom',
      (tester) async {
        final seq = EventSeq();
        final events = _longRoom(seq);
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        // Opens with nothing loaded yet; the whole log arrives on the first
        // poll, after the open post-frame callback already ran.
        final empty = buildLog(const []);
        final room = buildRoom();
        final gateway = _Gateway(room: room, log: empty, status: driver());
        await tester.pumpWidget(
          _host(
            RoomScreen(
              room: room,
              log: empty,
              driverStatus: driver(),
              gateway: gateway,
              capabilities: _caps,
              profileFor: (_) => null,
              prefs: MemoryRoomPrefs(),
              pollTimer: (_, _) => _FakeTimer(),
              clock: () =>
                  DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
            ),
          ),
        );
        await _frames(tester);
        gateway
          ..log = buildLog(events)
          ..room = buildRoom(latestSeq: gateway.log.latestSeq);
        await _refresh(tester);
        final position = tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: _transcript,
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        // At the newest content, not somewhere mid-log.
        expect(
          position.pixels,
          lessThanOrEqualTo(position.minScrollExtent + 150),
        );
        final newest = events.lastWhere((e) => e['kind'] == 'message.member');
        final tile = find.byKey(ValueKey('room-message-${newest['event_id']}'));
        expect(tile, findsOneWidget);
        // Visible; the open anchor may nudge it so the top speaker header
        // is not cut (spec 070 #5), never scrolled away.
        expect(
          tester.getTopLeft(tile).dy,
          lessThan(tester.getBottomLeft(_transcript).dy),
        );
        expect(find.byKey(const ValueKey('room-new-pill')), findsNothing);
      },
    );

    testWidgets('a new log alone (same room, same driver) reaches the screen', (
      tester,
    ) async {
      final seq = EventSeq();
      final events = _longRoom(seq, rounds: 2);
      final status = driver();
      final gateway = await _pump(tester, events: events, status: status);
      final room = gateway.room;
      final reply = seq.member(
        'builder',
        'builder',
        'late reply with no driver change',
        events.lastWhere((e) => e['kind'] == 'message.user')['event_id']
            as String,
        thread: 'thread-1',
        round: 1,
      );
      // Only the log moves: the room and the driver status stay the very
      // same instances, as when a poll brings messages but no state change.
      gateway.log = buildLog([...events, reply]);
      await _refresh(tester);
      expect(identical(gateway.room, room), isTrue);
      expect(identical(gateway.status, status), isTrue);
      expect(
        find.byKey(ValueKey('room-message-${reply['event_id']}')),
        findsOneWidget,
      );
    });

    testWidgets('C9 typing never rebuilds the transcript (2000 events)', (
      tester,
    ) async {
      final seq = EventSeq();
      final events = _longRoom(seq, rounds: 500);
      expect(events, hasLength(2000));
      await _pump(tester, events: events, status: driver());
      Widget transcript() => tester.widget(_transcript);
      final before = transcript();
      final field = find.descendant(
        of: find.byKey(const ValueKey('room-composer')),
        matching: find.byType(EditableText),
      );
      await tester.tap(field);
      await tester.pump();
      for (final ch in 'hola equipo'.split('')) {
        await tester.enterText(
          field,
          '${tester.widget<EditableText>(field).controller.text}$ch',
        );
        await tester.pump();
        // Same widget instance: Flutter skips the whole transcript subtree.
        expect(identical(transcript(), before), isTrue, reason: 'after "$ch"');
      }
      // A real change (a new message) does rebuild it.
      final gateway =
          tester.state<RoomScreenState>(find.byType(RoomScreen)).widget.gateway
              as _Gateway;
      final u = seq.user('ping', thread: 'thread-new');
      gateway
        ..log = buildLog([...events, u])
        ..room = buildRoom(latestSeq: gateway.log.latestSeq);
      await _refresh(tester);
      expect(identical(transcript(), before), isFalse);
    });
  });
}
