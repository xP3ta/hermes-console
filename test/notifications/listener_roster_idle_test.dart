// SPDX-License-Identifier: GPL-3.0-only
// The listener read the bot roster (`profiles.list`, with each bot's session
// previews) on every pass once it was 3 minutes old: at the 180 s idle
// cadence, on every tick. It names and draws the bots of room notices, so it
// stays fresh while a room works or waits, and is read every 30 minutes
// otherwise.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_mode_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bots/room/room_fixtures.dart';
import 'listener_idle_support.dart';

final _connection = SavedConnection(
  id: 'a',
  label: 'A',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the roster is read every 30 idle minutes, every 3 while a room '
      'works', () async {
    SharedPreferences.setMockInitialValues({'last_connection_id': 'a'});
    final prefs = await SharedPreferences.getInstance();
    final dir = await Directory.systemTemp.createTemp('faces');
    addTearDown(() => dir.delete(recursive: true));
    final seq = EventSeq();
    final rooms = IdleRooms()
      ..events = [
        seq.user('old'),
        seq.member('m-builder', 'builder', 'old', 'd0'),
      ];
    var now = DateTime(2026, 11, 20, 9);
    final m = BotModeBackgroundMonitor(
      sink: IdleSink(),
      faces: BotFaceBitmapCache(directory: () async => dir),
      now: () => now,
      gatewayFor: (_) => rooms,
    );
    Future<void> tick() async {
      await m.tick(
        prefs: prefs,
        targets: [_connection],
        notificationsEnabled: true,
      );
      now = now.add(const Duration(minutes: 3));
    }

    // 21 ticks over one idle hour at the 180 s cadence.
    for (var i = 0; i <= 20; i++) {
      await tick();
    }
    expect(rooms.passes, 21, reason: 'the rooms are read on every tick');
    expect(rooms.profileReads, 3, reason: 'at 0, 30 and 60 minutes');

    rooms.working = true;
    await tick(); // 63 min: this pass finds the room working.
    expect(rooms.profileReads, 3);
    await tick(); // 66 min: the roster is 6 minutes old, read again.
    expect(rooms.profileReads, 4);
    await tick(); // 69 min: 3 minutes old.
    expect(rooms.profileReads, 5);
    await m.close();
  });
}
