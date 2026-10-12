import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/bot_roster_cache.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

final connection = SavedConnection(
  id: 'mc',
  label: 'MC',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

AgentProfile working(String name) => AgentProfile.fromJson({
  'name': name,
  'worker_session': {
    'id': 'w-$name',
    'source': 'kanban',
    'title': 't',
    'last_active': 1,
  },
});

const unsupportedRpc = TuiGatewayRpcError(
  'profiles.list',
  'Method not found',
  code: -32601,
);

void main() {
  test('only the Gateway read is authoritative for activity', () async {
    final registry = BotRosterRegistry();
    registry.publish(connection.id, 'MC', [working('ops')], sessions: true);
    // Legacy Dashboard list: no projections, so activity is kept.
    await loadSharedMissionProfiles(
      registry: registry,
      connection: connection,
      desktopLoader: () async => throw unsupportedRpc,
      legacyDashboardLoader: () async => const [AgentProfile(name: 'ops')],
    );
    expect(
      registry.store(connection.id).profile('ops')!.workerSession?.id,
      'w-ops',
    );
    // Gateway read with include_sessions: an idle bot is idle.
    await loadSharedMissionProfiles(
      registry: registry,
      connection: connection,
      desktopLoader: () async => const [AgentProfile(name: 'ops')],
      legacyDashboardLoader: () async => throw StateError('unused'),
    );
    expect(registry.store(connection.id).profile('ops')!.workerSession, isNull);
  });
  Future<BotRosterRegistry> coldStart() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await BotRosterCache(
      prefs,
    ).write(connection, const [AgentProfile(name: 'ops')]);
    final registry = BotRosterRegistry()
      ..attachPersistence(prefs, [connection]);
    expect(registry.store(connection.id).profiles.single.name, 'ops');
    return registry;
  }

  Future<List<String>> persisted() async => [
    for (final p in BotRosterCache(
      await SharedPreferences.getInstance(),
    ).read(connection))
      p.name,
  ];

  test(
    'a server without profiles.list nor the Dashboard list retracts the cached roster',
    () async {
      final registry = await coldStart();
      await expectLater(
        loadSharedMissionProfiles(
          registry: registry,
          connection: connection,
          desktopLoader: () async => throw unsupportedRpc,
          legacyDashboardLoader: () async =>
              throw const DashboardHttpException(404),
        ),
        throwsA(isA<DashboardHttpException>()),
      );
      expect(registry.store(connection.id).snapshot, isNull);
      await pumpEventQueue();
      expect(await persisted(), isEmpty);
    },
  );

  test('a transient failure keeps the cached roster', () async {
    for (final (desktop, legacy) in <(Object, Object?)>[
      (const TuiGatewayRpcError('profiles.list', 'timeout'), null),
      (unsupportedRpc, const DashboardHttpException(503)),
      (unsupportedRpc, StateError('offline')),
      // A 404 on the Gateway path itself says nothing about the roster.
      (const DashboardHttpException(404), null),
    ]) {
      final registry = await coldStart();
      await expectLater(
        loadSharedMissionProfiles(
          registry: registry,
          connection: connection,
          desktopLoader: () async => throw desktop,
          legacyDashboardLoader: () async => throw legacy ?? StateError('x'),
        ),
        throwsA(anything),
      );
      expect(registry.store(connection.id).profiles.single.name, 'ops');
      await pumpEventQueue();
      expect(await persisted(), ['ops']);
    }
  });

  test('a supported server replaces the cached roster', () async {
    final registry = await coldStart();
    await loadSharedMissionProfiles(
      registry: registry,
      connection: connection,
      desktopLoader: () async => const [AgentProfile(name: 'live')],
      legacyDashboardLoader: () async => throw StateError('unused'),
    );
    expect(registry.store(connection.id).isLive, isTrue);
    expect(registry.store(connection.id).profiles.single.name, 'live');
  });

  test('a live roster is never retracted by an unsupported read', () {
    final registry = BotRosterRegistry();
    registry.publish(connection.id, 'MC', const [AgentProfile(name: 'ops')]);
    registry.unsupported(
      connection.id,
      ticket: registry.beginRead(connection.id),
    );
    expect(registry.store(connection.id).profiles.single.name, 'ops');
  });
}
