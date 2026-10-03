import 'dart:async';
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
  test(
    'a late background write cannot replace a newer roster the app persisted',
    () async {
      SharedPreferences.setMockInitialValues({'last_connection_id': 'a'});
      final prefs = await SharedPreferences.getInstance();
      final dir = await Directory.systemTemp.createTemp('faces');
      addTearDown(() => dir.delete(recursive: true));
      final gateway = HeldRosterGateway();
      final monitor = BotModeBackgroundMonitor(
        faces: BotFaceBitmapCache(directory: () async => dir),
        now: () => DateTime(2026, 10, 3, 12),
        publish: (_) async {},
        gatewayFor: (_) => gateway,
      );
      // The background read starts at 12:00 and stays on the wire.
      final tick = monitor.tick(
        prefs: prefs,
        targets: [connection],
        notificationsEnabled: true,
      );
      await pumpEventQueue();
      expect(gateway.reads, hasLength(1));
      // The app reads at 12:05 and persists the newer roster.
      final registry = BotRosterRegistry(
        now: () => DateTime(2026, 10, 3, 12, 5),
      )..attachPersistence(prefs, [connection]);
      registry.publish('a', 'A', const [
        AgentProfile(name: 'new'),
      ], ticket: registry.beginRead('a'));
      await pumpEventQueue();
      expect(BotRosterCache(prefs).read(connection).single.name, 'new');
      // The background response lands afterwards.
      gateway.reads.single.complete(const [AgentProfile(name: 'old')]);
      await tick;
      await pumpEventQueue();
      expect(BotRosterCache(prefs).read(connection).single.name, 'new');
      // Next cold start restores the newer roster.
      expect(
        BotRosterRegistry()
            .let((r) => r..attachPersistence(prefs, [connection]))
            .store('a')
            .profiles
            .single
            .name,
        'new',
      );
    },
  );

  test('a newer background read still replaces an older app roster', () async {
    SharedPreferences.setMockInitialValues({'last_connection_id': 'a'});
    final prefs = await SharedPreferences.getInstance();
    final dir = await Directory.systemTemp.createTemp('faces');
    addTearDown(() => dir.delete(recursive: true));
    final registry = BotRosterRegistry(now: () => DateTime(2026, 10, 3, 11))
      ..attachPersistence(prefs, [connection]);
    registry.publish('a', 'A', const [
      AgentProfile(name: 'old'),
    ], ticket: registry.beginRead('a'));
    await pumpEventQueue();
    final monitor = BotModeBackgroundMonitor(
      faces: BotFaceBitmapCache(directory: () async => dir),
      now: () => DateTime(2026, 10, 3, 12),
      publish: (_) async {},
      gatewayFor: (_) => RosterOnlyGateway(),
    );
    await monitor.tick(
      prefs: prefs,
      targets: [connection],
      notificationsEnabled: true,
    );
    await pumpEventQueue();
    expect(BotRosterCache(prefs).read(connection).single.name, 'radar');
  });
}

final class HeldRosterGateway implements BotModeGateway {
  final reads = <Completer<List<AgentProfile>>>[];

  @override
  Future<List<AgentProfile>> listProfiles() {
    final read = Completer<List<AgentProfile>>();
    reads.add(read);
    return read.future;
  }

  @override
  Future<DesktopActiveSessionList> listActiveSessions() async =>
      const DesktopActiveSessionList();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(StateError('offline'));
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
