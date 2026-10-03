import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

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
}
