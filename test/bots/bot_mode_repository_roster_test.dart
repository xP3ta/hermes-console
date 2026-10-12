import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/bot_mode_repository.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/bot_roster_cache.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final connection = SavedConnection(
  id: 'bot-mode',
  label: 'QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

/// Only `profiles.list` answers (held by the test); rooms and live
/// sessions fail, which Bot Mode already treats as empty.
final class HeldProfilesGateway implements BotModeGateway {
  final reads = <Completer<List<AgentProfile>>>[];

  @override
  Future<List<AgentProfile>> listProfiles() {
    final read = Completer<List<AgentProfile>>();
    reads.add(read);
    return read.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(StateError('offline'));
}

List<String> rowNames(BotModeSnapshot snapshot) => [
  for (final row in snapshot.bots) row.profile.name,
];

void main() {
  test('Bot Mode publishes its roster read to the shared store', () async {
    final registry = BotRosterRegistry();
    final gateway = HeldProfilesGateway();
    final repo = BotModeRepository(
      gateway: gateway,
      connection: connection,
      rosterRegistry: registry,
    );
    final load = repo.load();
    await pumpEventQueue();
    gateway.reads.single.complete(const [AgentProfile(name: 'ops')]);
    expect(rowNames(await load), ['ops']);
    expect(registry.store(connection.id).profiles.single.name, 'ops');
  });

  test(
    'a rename confirmed while a load is on the wire beats the late roster',
    () async {
      final registry = BotRosterRegistry();
      registry.publish(connection.id, 'QA', const [AgentProfile(name: 'ops')]);
      final gateway = HeldProfilesGateway();
      final repo = BotModeRepository(
        gateway: gateway,
        connection: connection,
        rosterRegistry: registry,
      );
      final load = repo.load();
      await pumpEventQueue();
      registry.profileRenamed(connection.id, 'ops', 'ops2');
      gateway.reads.single.complete(const [AgentProfile(name: 'ops')]);
      expect(rowNames(await load), ['ops2']);
      expect(registry.store(connection.id).profiles.single.name, 'ops2');
    },
  );
  test(
    'a rename confirmed over the cached roster beats the late read',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await BotRosterCache(
        prefs,
      ).write(connection, const [AgentProfile(name: 'ops')]);
      // Cold start: only the cached roster is in the store.
      final registry = BotRosterRegistry()
        ..attachPersistence(prefs, [connection]);
      final gateway = HeldProfilesGateway();
      final repo = BotModeRepository(
        gateway: gateway,
        connection: connection,
        rosterRegistry: registry,
      );
      final load = repo.load();
      await pumpEventQueue();
      registry.profileRenamed(connection.id, 'ops', 'ops2');
      gateway.reads.single.complete(const [AgentProfile(name: 'ops')]);
      expect(rowNames(await load), ['ops2']);
      expect(registry.store(connection.id).profiles.single.name, 'ops2');
    },
  );
}
