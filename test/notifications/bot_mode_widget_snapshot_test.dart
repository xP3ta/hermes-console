import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_mode_widget_snapshot.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/notifications/bot_mode_background.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/notifications/room_watcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bots/room/room_fixtures.dart';

SavedConnection conn(String id) => SavedConnection.fromMap({
  'id': id,
  'label': 'Home $id',
  'host': '192.168.1.20',
  'port': 8642,
  'apiKey': '',
  'useHttps': false,
});

void main() {
  test('active watch connection follows last, then default, then first', () async {
    SharedPreferences.setMockInitialValues({
      'default_connection_id': 'b',
      'last_connection_id': 'c',
    });
    final prefs = await SharedPreferences.getInstance();
    final targets = [conn('a'), conn('b'), conn('c')];
    expect(activeWatchConnection(prefs, targets)!.id, 'c');
    await prefs.remove('last_connection_id');
    expect(activeWatchConnection(prefs, targets)!.id, 'b');
    await prefs.remove('default_connection_id');
    expect(activeWatchConnection(prefs, targets)!.id, 'a');
    expect(activeWatchConnection(prefs, const []), isNull);
  });

  test('widget snapshot: approvals routed like notifications, room with Stop', () {
    final seq = EventSeq();
    final status = driver(working: true, pending: [approvalAction()]);
    final room = buildRoom(latestSeq: 3);
    final snapshot = buildBotModeWidgetSnapshot(
      connection: conn('c1'),
      connected: true,
      profiles: const [],
      liveSessions: const [],
      rooms: [
        RoomWatchView(
          room: room,
          driverStatus: status,
          state: const RoomWatchState(
            working: true,
            openMembers: {'m-builder'},
            repliers: ['m-review'],
          ),
          lastMemberId: 'm-review',
          lastText: '**Looks good**',
        ),
      ],
      facePaths: const {},
      t: const NotifL10n(false),
      now: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    expect(seq.seq, 0);
    final approval = snapshot.approvals.single;
    expect(approval.title, 'Lead · Console Devs');
    expect(approval.text, 'Needs your OK to run “gh pr ready 51”');
    final action = NotificationActionPayload.tryParse(approval.actionPayload)!;
    expect(action.isRoomApproval, isTrue);
    final widgetRoom = snapshot.room!;
    expect(widgetRoom.working, isTrue);
    expect(widgetRoom.stopPayload, isNotNull);
    expect(widgetRoom.lastMessage, 'Looks good');
    final states = {for (final m in widgetRoom.members) m.name: m.state};
    expect(states['Builder'], 'working');
    expect(states['Review'], 'done');
    expect(states['Lead'], 'needs_you');

    final json = jsonDecode(snapshot.encode()) as Map;
    expect(json['schema_version'], BotModeWidgetSnapshot.schemaVersion);
    expect(json['needs_you_count'], 1);
    expect(snapshot.encode(), isNot(contains('apiKey')));
  });

  test('every widget open payload parses (Bot without a chat included)', () {
    final profile = AgentProfile.fromJson({'name': 'builder'});
    final snapshot = buildBotModeWidgetSnapshot(
      connection: conn('c1'),
      connected: true,
      profiles: [profile],
      liveSessions: const [],
      rooms: const [],
      facePaths: const {},
      t: const NotifL10n(false),
      now: DateTime(2026),
    );
    final open = NotificationOpen.tryParse(snapshot.bots.single.openPayload)!;
    expect(open.surface, NotificationChatSurface.bot);
    expect(open.profile, 'builder');
  });

  test('idle room exposes no Stop', () {
    final snapshot = buildBotModeWidgetSnapshot(
      connection: conn('c1'),
      connected: true,
      profiles: const [],
      liveSessions: const [],
      rooms: [
        RoomWatchView(
          room: buildRoom(),
          driverStatus: driver(),
          state: const RoomWatchState(),
        ),
      ],
      facePaths: const {},
      t: const NotifL10n(true),
      now: DateTime(2026),
    );
    expect(snapshot.room!.stopPayload, isNull);
    expect(snapshot.approvals, isEmpty);
    expect(snapshot.workingCount, 0);
  });
}
