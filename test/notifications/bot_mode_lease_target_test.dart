// SPDX-License-Identifier: GPL-3.0-only
// The background listener keeps one gateway socket per watched connection
// and reads its silence as "nothing changed". Editing a saved connection
// keeps its id: the socket must follow the new host, or cron and rooms go
// on listening to the old one.
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_mode_background.dart';
import 'package:hermes_android/core/services/shared_gateway_pool.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'listener_idle_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an edited endpoint under the same connection id gets a new socket; '
      'the old host is no longer the one kept', () async {
    HttpOverrides.global = null;
    final first = LoopbackGateway();
    await first.start();
    final second = LoopbackGateway();
    await second.start();
    SharedPreferences.setMockInitialValues({
      'last_connection_id': first.connection.id,
    });
    final prefs = await SharedPreferences.getInstance();
    final dir = await Directory.systemTemp.createTemp('faces');
    addTearDown(() => dir.delete(recursive: true));

    final dialled = <String?>[];
    final clients = <TuiGatewayClient>[];
    final pool = SharedGatewayPool.forTesting(
      factory: (SavedConnection connection) {
        dialled.add(connection.dashboardUrl);
        final client = TuiGatewayClient(
          connection,
          dashboard: IdleTicket(),
          heartbeatInterval: Duration.zero,
        );
        clients.add(client);
        return client;
      },
    );
    addTearDown(pool.closeAll);
    final now = DateTime(2026, 11, 21, 9);
    final monitor = BotModeBackgroundMonitor(
      sink: IdleSink(),
      faces: BotFaceBitmapCache(directory: () async => dir),
      now: () => now,
      pool: pool,
      gatewayFor: (_) => IdleRooms(),
    );
    Future<void> tick(SavedConnection connection) async {
      await withClock(
        Clock(() => now),
        () => monitor.tick(
          prefs: prefs,
          targets: [connection],
          notificationsEnabled: true,
        ),
      );
      await settleLoopback();
    }

    await tick(first.connection);
    expect(dialled, [first.connection.dashboardUrl]);
    expect(monitor.keptGateway(first.connection.id), same(clients.single));

    // The user edits the saved connection: same id, another host.
    expect(second.connection.id, first.connection.id);
    await tick(second.connection);
    expect(dialled, [
      first.connection.dashboardUrl,
      second.connection.dashboardUrl,
    ]);
    expect(monitor.keptGateway(first.connection.id), same(clients.last));
    await monitor.close();
  });
}
