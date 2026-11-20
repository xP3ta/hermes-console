// `groups.changed` in an open room, as Hermes Desktop's open room uses it
// (canonical-group-workspace.tsx): a push naming the room reads it at once,
// a copy of the same broadcast reads nothing, and a backend whose
// `groups.state` says `change_events` is polled only as a 15 s backstop
// while the pushes can arrive. Without them the room polls as before.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/room_log_cursor.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/spec070_fixtures.dart';
import 'room/room_fixtures.dart';

final class _NoTimer implements Timer {
  _NoTimer(this._cancelled);

  final void Function() _cancelled;
  bool _active = true;

  @override
  void cancel() {
    if (_active) _cancelled();
    _active = false;
  }

  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

/// Every poll the poller schedules, fired by hand.
final class _Schedule {
  final delays = <Duration>[];
  void Function()? _next;
  var cancels = 0;

  Timer call(Duration delay, void Function() callback) {
    delays.add(delay);
    _next = callback;
    return _NoTimer(() => cancels++);
  }

  bool get pending => _next != null;

  void fire() {
    final next = _next;
    expect(next, isNotNull, reason: 'nothing scheduled');
    _next = null;
    next!();
  }
}

({RoomLogDelta delta, bool working}) _quiet() => (
  delta: RoomLogDelta(
    added: const [],
    log: spec070LogPage('groups_log_empty'),
    reset: false,
  ),
  working: false,
);

/// Room reads counted, each answering with [changeEvents].
final class _CountingGateway implements RoomGateway {
  _CountingGateway(this.room, this.log);

  final HostedGroupRoom room;
  final HostedGroupLogPage log;
  bool changeEvents = true;
  int reads = 0;

  HostedGroupWorkspaceReadback get _readback => HostedGroupWorkspaceReadback(
    room: room,
    log: log,
    capabilityGeneration: 1,
    driverStatus: driver(),
    changeEvents: changeEvents,
  );

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async {
    reads++;
    return _readback;
  }

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

TuiGatewayEvent _changed({List<String>? rooms, String? broadcast}) =>
    TuiGatewayEvent(
      type: 'groups.changed',
      sessionId: '',
      payload: {'room_ids': ?rooms, 'broadcast_id': ?broadcast},
    );

void main() {
  group('RoomLogPoller', () {
    test('readNow reads at once, or once right after the read in flight, '
        'never two at a time', () async {
      final schedule = _Schedule();
      final release = <Completer<void>>[];
      var ticks = 0;
      final poller = RoomLogPoller(
        timer: schedule.call,
        tick: () async {
          ticks++;
          final hold = Completer<void>();
          release.add(hold);
          await hold.future;
          return _quiet();
        },
      );
      addTearDown(poller.dispose);
      poller.setVisible(true);
      schedule.fire();
      await Future<void>.delayed(Duration.zero);
      expect(ticks, 1);

      // Two pushes while the read is on the wire: one read after it.
      poller
        ..readNow()
        ..readNow();
      expect(schedule.pending, isFalse);
      release.single.complete();
      await Future<void>.delayed(Duration.zero);
      expect(schedule.delays.last, Duration.zero);
      schedule.fire();
      await Future<void>.delayed(Duration.zero);
      expect(ticks, 2);
      release.last.complete();
      await Future<void>.delayed(Duration.zero);
      expect(schedule.delays.last, isNot(Duration.zero));

      // Idle: a push replaces the wait with a read now.
      final cancels = schedule.cancels;
      poller.readNow();
      expect(schedule.cancels, cancels + 1);
      expect(schedule.delays.last, Duration.zero);
    });

    test('with pushes the next read waits the 15 s backstop; a failed read '
        'keeps the fast cadence', () async {
      final schedule = _Schedule();
      var pushes = true;
      var fail = false;
      final poller = RoomLogPoller(
        timer: schedule.call,
        backstop: () => pushes,
        tick: () async {
          if (fail) throw StateError('room read failed');
          return _quiet();
        },
      );
      addTearDown(poller.dispose);
      poller.setVisible(true);
      schedule.fire();
      await Future<void>.delayed(Duration.zero);
      expect(schedule.delays.last, const Duration(seconds: 15));

      fail = true;
      schedule.fire();
      await Future<void>.delayed(Duration.zero);
      expect(schedule.delays.last, const Duration(seconds: 3));

      fail = false;
      pushes = false;
      schedule.fire();
      await Future<void>.delayed(Duration.zero);
      expect(schedule.delays.last, const Duration(seconds: 3));
    });
  });

  group('RoomScreen', () {
    Future<({_CountingGateway gateway, _Schedule schedule})> pumpRoom(
      WidgetTester tester, {
      required StreamController<TuiGatewayEvent> events,
      required bool Function() pushesLive,
    }) async {
      tester.view.physicalSize = const Size(412 * 3, 915 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final seq = EventSeq();
      final log = buildLog([seq.user('hola equipo')]);
      final room = buildRoom(latestSeq: log.latestSeq);
      final gateway = _CountingGateway(room, log);
      final schedule = _Schedule();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.hermesRedDark,
          home: RoomScreen(
            room: room,
            log: log,
            gateway: gateway,
            capabilities: const RoomCapabilities(canSend: true),
            profileFor: (_) => null,
            prefs: MemoryRoomPrefs(),
            pollTimer: schedule.call,
            clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
            changes: events.stream,
            pushesLive: pushesLive,
          ),
        ),
      );
      await tester.pump();
      // The open read.
      schedule.fire();
      await tester.pump();
      await tester.pump();
      return (gateway: gateway, schedule: schedule);
    }

    testWidgets('a push naming the room reads it now; a copy of the same '
        'broadcast and a push for another room read nothing', (tester) async {
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      final (:gateway, :schedule) = await pumpRoom(
        tester,
        events: events,
        pushesLive: () => true,
      );
      expect(gateway.reads, 1);
      // Pushes can arrive and the room said change_events: a backstop.
      expect(schedule.delays.last, const Duration(seconds: 15));

      events.add(_changed(rooms: [roomId], broadcast: 'epoch:1'));
      await tester.pump();
      expect(schedule.delays.last, Duration.zero);
      schedule.fire();
      await tester.pump();
      await tester.pump();
      expect(gateway.reads, 2);

      events
        ..add(_changed(rooms: [roomId], broadcast: 'epoch:1'))
        ..add(_changed(rooms: ['room-other'], broadcast: 'epoch:2'));
      await tester.pump();
      expect(schedule.delays.last, const Duration(seconds: 15));

      // Something process-wide moved (no room ids), from an older backend
      // (no broadcast id): it reads.
      events.add(_changed());
      await tester.pump();
      expect(schedule.delays.last, Duration.zero);
      schedule.fire();
      await tester.pump();
      await tester.pump();
      expect(gateway.reads, 3);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a backend without change_events, or pushes that cannot '
        'arrive, keeps the usual poll', (tester) async {
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      var live = false;
      final (:gateway, :schedule) = await pumpRoom(
        tester,
        events: events,
        pushesLive: () => live,
      );
      expect(schedule.delays.last, const Duration(seconds: 3));

      live = true;
      gateway.changeEvents = false;
      schedule.fire();
      await tester.pump();
      await tester.pump();
      expect(gateway.reads, 2);
      expect(schedule.delays.last, const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
