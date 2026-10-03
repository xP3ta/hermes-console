import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/bot_mode_repository.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/services/bot_roster_cache.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_mode_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

final connection = SavedConnection(
  id: 'a',
  label: 'A',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

final class RosterOnlyGateway implements BotModeGateway {
  int profileReads = 0;

  @override
  Future<List<AgentProfile>> listProfiles() async {
    profileReads++;
    return const [
      AgentProfile(name: 'radar', botModeUiMeta: {'title': 'Radar'}),
    ];
  }

  @override
  Future<DesktopActiveSessionList> listActiveSessions() async =>
      const DesktopActiveSessionList();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(StateError('offline'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'the background roster read reaches the app through the persisted cache',
    () async {
      SharedPreferences.setMockInitialValues({'last_connection_id': 'a'});
      final prefs = await SharedPreferences.getInstance();
      final dir = await Directory.systemTemp.createTemp('faces');
      addTearDown(() => dir.delete(recursive: true));
      final gateway = RosterOnlyGateway();
      final monitor = BotModeBackgroundMonitor(
        faces: BotFaceBitmapCache(directory: () async => dir),
        now: () => DateTime(2026, 10, 3, 12),
        publish: (_) async {},
        gatewayFor: (_) => gateway,
      );
      await monitor.tick(
        prefs: prefs,
        targets: [connection],
        notificationsEnabled: true,
      );
      await pumpEventQueue();
      expect(gateway.profileReads, 1);
      expect(BotRosterCache(prefs).read(connection).single.botTitle, 'Radar');
      // Next cold start of the app: the shared store shows it, no read.
      final registry = BotRosterRegistry()
        ..attachPersistence(prefs, [connection]);
      expect(registry.store('a').profiles.single.name, 'radar');
      expect(registry.store('a').isLive, isFalse);
    },
  );
}
