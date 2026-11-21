// SPDX-License-Identifier: GPL-3.0-only
// The Bots and Salas home widgets were retired in 1.4.0, yet every listener
// tick still built their snapshot for nothing: a `session.active_list`, the
// avatar of every bot with a photo (the roster refresh dropped them, so up to
// 2 MB each again) and face bitmaps. Without a widget to feed, the pass is
// not made; the rooms are still watched and their notices still posted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_mode_widget_snapshot.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_mode_background.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bots/room/room_fixtures.dart';
import 'listener_idle_support.dart';

/// The listener's socket, counting the avatars asked for over it.
final class _AvatarCountingClient extends TuiGatewayClient {
  _AvatarCountingClient(super.connection);

  int avatars = 0;

  @override
  Future<AgentProfileAvatar?> profileAvatar(String profileName) async {
    avatars++;
    return null;
  }
}

final _connection = SavedConnection(
  id: 'a',
  label: 'A',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late Directory dir;
  late IdleRooms rooms;
  late IdleSink sink;
  late _AvatarCountingClient client;
  late SharedGatewayPool pool;
  late DateTime now;
  late EventSeq seq;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'last_connection_id': 'a'});
    prefs = await SharedPreferences.getInstance();
    dir = await Directory.systemTemp.createTemp('faces');
    addTearDown(() => dir.delete(recursive: true));
    rooms = IdleRooms()
      ..profiles = const [AgentProfile(name: 'radar', hasAvatar: true)];
    seq = EventSeq();
    rooms.events = [
      seq.user('old'),
      seq.member('m-builder', 'builder', 'old', 'd0'),
    ];
    sink = IdleSink();
    client = _AvatarCountingClient(_connection);
    pool = SharedGatewayPool.forTesting(factory: (_) => client);
    addTearDown(pool.closeAll);
    now = DateTime(2026, 11, 20, 9);
  });

  BotModeBackgroundMonitor monitor({
    Future<void> Function(BotModeWidgetSnapshot snapshot)? publish,
  }) => BotModeBackgroundMonitor(
    sink: sink,
    faces: BotFaceBitmapCache(directory: () async => dir),
    now: () => now,
    pool: pool,
    publish: publish,
    gatewayFor: (_) => rooms,
  );

  /// One listener tick, then 180 s of idle cadence.
  Future<void> tick(BotModeBackgroundMonitor m) async {
    await m.tick(
      prefs: prefs,
      targets: [_connection],
      notificationsEnabled: true,
    );
    now = now.add(const Duration(minutes: 3));
  }

  test('without a widget to feed, idle ticks read no live sessions and no '
      'avatars, and the rooms are still watched', () async {
    final m = monitor();
    for (var i = 0; i < 5; i++) {
      await tick(m);
    }
    expect(rooms.passes, 5);
    expect(rooms.liveListReads, 0, reason: 'no session.active_list');
    expect(client.avatars, 0, reason: 'no profiles.get_asset');
    await m.close();
  });

  test('a caller that still publishes the snapshot gets it, reads and '
      'all', () async {
    final published = <BotModeWidgetSnapshot>[];
    final m = monitor(publish: (snapshot) async => published.add(snapshot));
    await tick(m);
    expect(published, hasLength(1));
    expect(rooms.liveListReads, 1);
    expect(client.avatars, greaterThan(0));
    await m.close();
  });

  test('a room notice is still posted without the widget pass', () async {
    final m = monitor();
    await tick(m);
    rooms.working = true;
    rooms.pending = [approvalAction()];
    rooms.events = [...rooms.events, seq.user('ship it')];
    await tick(m);
    expect(sink.conversations, hasLength(1), reason: 'approval card');
    await m.close();
  });
}
