// SPDX-License-Identifier: GPL-3.0-only
// Every listener tick read each watched room (`groups.capabilities`,
// `groups.list`, one `groups.state` per room) even when nothing moved.
// Hermes Agent's newer gateway says in `groups.state` (`change_events`)
// that it pushes `groups.changed` when a room's log, tasks or live status
// (approvals included) move, and Hermes Desktop then reads an open room on
// that push, its poll only a backstop
// (plugins/hermes-bots/canonical-group-workspace.tsx). The listener does the
// same over the socket it keeps: idle rooms are read on the push or after a
// backstop; working or waiting rooms, and older servers, on every tick.
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/bot_mode_repository.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_mode_background.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/remove_test_dir.dart';

import '../bots/room/room_fixtures.dart';
import 'listener_idle_support.dart';

/// [IdleRooms] whose `groups.state` carries `change_events` = [pushes].
final class _PushRooms extends IdleRooms implements BotModeRoomEventsGateway {
  bool pushes = true;

  @override
  Future<
    ({HostedGroupRoom room, RoomDriverStatus? driverStatus, bool changeEvents})
  >
  groupStateWithEvents(String roomId, {required int generation}) async {
    final state = await groupState(roomId, generation: generation);
    return (
      room: state.room,
      driverStatus: state.driverStatus,
      changeEvents: pushes,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late Directory dir;
  late LoopbackGateway gateway;
  late TuiGatewayClient client;
  late SharedGatewayPool pool;
  late _PushRooms rooms;
  late IdleSink sink;
  late DateTime now;
  late EventSeq seq;

  setUp(() async {
    HttpOverrides.global = null;
    gateway = LoopbackGateway();
    await gateway.start();
    SharedPreferences.setMockInitialValues({
      'last_connection_id': gateway.connection.id,
    });
    prefs = await SharedPreferences.getInstance();
    dir = await Directory.systemTemp.createTemp('faces');
    addTearDown(() => removeTestDir(dir));
    client = gateway.client();
    pool = SharedGatewayPool.forTesting(factory: (_) => client);
    addTearDown(pool.closeAll);
    seq = EventSeq();
    rooms = _PushRooms()
      ..events = [
        seq.user('old'),
        seq.member('m-builder', 'builder', 'old', 'd0'),
      ];
    sink = IdleSink();
    now = DateTime(2026, 11, 20, 9);
  });

  BotModeBackgroundMonitor monitor() => BotModeBackgroundMonitor(
    sink: sink,
    faces: BotFaceBitmapCache(directory: () async => dir),
    now: () => now,
    pool: pool,
    gatewayFor: (_) => rooms,
  );

  /// One listener tick, then 180 s of idle cadence.
  Future<bool> tick(BotModeBackgroundMonitor m) async {
    final active = await withClock(
      Clock(() => now),
      () => m.tick(
        prefs: prefs,
        targets: [gateway.connection],
        notificationsEnabled: true,
      ),
    );
    await settleLoopback();
    now = now.add(const Duration(minutes: 3));
    return active;
  }

  test('pushed rooms are read once while idle, then on groups.changed, and '
      'its approval is announced', () async {
    await client.connect();
    final asked = gateway.methods.length;
    final m = monitor();
    expect(await tick(m), isFalse);
    await tick(m);
    await tick(m);
    expect(rooms.passes, 1, reason: 'six idle minutes, one pass');
    expect(gateway.methods, hasLength(asked), reason: 'it only listens');

    // A member asks for approval; the backend pushes the change.
    rooms.working = true;
    rooms.pending = [approvalAction()];
    rooms.events = [...rooms.events, seq.user('ship it')];
    gateway.broadcast('groups.changed');
    await settleLoopback();
    expect(await tick(m), isTrue, reason: 'fast cadence while it waits');
    expect(rooms.passes, 2);
    expect(sink.conversations, hasLength(1), reason: 'approval card');

    // Working or waiting: every tick reads, push or not.
    await tick(m);
    expect(rooms.passes, 3);
    expect(sink.conversations, hasLength(1), reason: 'never re-announced');
    await m.close();
  });

  test('an older server, without change_events in groups.state, reads on '
      'every tick', () async {
    rooms.pushes = false;
    await client.connect();
    final m = monitor();
    for (var i = 0; i < 4; i++) {
      await tick(m);
    }
    expect(rooms.passes, 4);
    await m.close();
  });

  test('pushed rooms are still read after the ten minute backstop, and once '
      'the socket drops', () async {
    await client.connect();
    final m = monitor();
    await tick(m); // 0
    await tick(m); // 3
    await tick(m); // 6
    await tick(m); // 9
    expect(rooms.passes, 1);
    await tick(m); // 12: past the backstop.
    expect(rooms.passes, 2);
    await gateway.drop();
    await settleLoopback();
    await tick(m);
    expect(rooms.passes, 3, reason: 'the socket is down');
    await m.close();
  });
}
