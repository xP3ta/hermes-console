import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_adapters.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

DashboardClient _client(List<http.Request> seen) => DashboardClient(
  host: 'hermes.local',
  port: 9119,
  manualToken: 'dashboard-token',
  httpClientOverride: MockClient((request) async {
    seen.add(request);
    if (request.url.path == '/api/skills') {
      return http.Response(
        jsonEncode([
          {'name': 'arxiv', 'provenance': 'hub', 'enabled': true},
        ]),
        200,
      );
    }
    if (request.url.path == '/api/skills/toggle') {
      return http.Response(jsonEncode({'ok': true}), 200);
    }
    return http.Response(jsonEncode({'skills': []}), 200);
  }),
);

void main() {
  test(
    'GET /api/skills list is wrapped and parsed by the repository',
    () async {
      final seen = <http.Request>[];
      final repo = CapabilitiesRepository(
        rest: DashboardCapabilitiesRest(_client(seen)),
        profile: 'research',
      );
      final skills = await repo.installedSkills();
      expect(skills.single.name, 'arxiv');
      expect(seen.single.url.path, '/api/skills');
      expect(seen.single.url.queryParameters['profile'], 'research');
    },
  );

  test('writable connection reaches the toggle endpoint', () async {
    final seen = <http.Request>[];
    final repo = CapabilitiesRepository(
      rest: DashboardCapabilitiesRest(_client(seen)),
    );
    await repo.setSkillEnabled('arxiv', false);
    expect(seen.single.method, 'PUT');
    expect(jsonDecode(seen.single.body), {'name': 'arxiv', 'enabled': false});
  });

  test(
    'read-only connection blocks every mutation before the network',
    () async {
      final seen = <http.Request>[];
      final repo = CapabilitiesRepository(
        rest: DashboardCapabilitiesRest(_client(seen), readOnly: true),
      );
      await expectLater(
        repo.setSkillEnabled('arxiv', false),
        throwsA(
          isA<CapabilityFailure>().having(
            (f) => f.kind,
            'kind',
            CapabilityFailureKind.forbidden,
          ),
        ),
      );
      await expectLater(
        repo.installSkill('official/research/arxiv'),
        throwsA(isA<CapabilityFailure>()),
      );
      await expectLater(
        repo.removeMcp('docs'),
        throwsA(isA<CapabilityFailure>()),
      );
      expect(seen, isEmpty);
      // Reads still work.
      expect(await repo.installedSkills(), hasLength(1));
    },
  );

  test('gateway passthrough only admits the connector family', () {
    for (final method in const [
      'connectors.list',
      'connectors.catalog',
      'connectors.accounts',
      'connectors.operation.status',
      'mcp.servers.status',
      'connectors.tools',
      'connectors.policy.get',
    ]) {
      expect(
        TuiGatewayClient.capabilitiesRpcAllowed(method, readOnly: true),
        isTrue,
        reason: method,
      );
    }
    for (final method in const [
      'connectors.connect',
      'connectors.operation.wake',
      'connectors.accounts.remove',
      'connection.respond',
      'connectors.policy.set',
    ]) {
      expect(
        TuiGatewayClient.capabilitiesRpcAllowed(method, readOnly: false),
        isTrue,
        reason: method,
      );
      expect(
        TuiGatewayClient.capabilitiesRpcAllowed(method, readOnly: true),
        isFalse,
        reason: method,
      );
    }
    for (final method in const [
      'prompt.submit',
      'session.activate',
      'connectors.policy.reset',
    ]) {
      expect(
        TuiGatewayClient.capabilitiesRpcAllowed(method, readOnly: false),
        isFalse,
        reason: method,
      );
    }
  });

  test('plugins.manage is admitted per action', () {
    bool allowed(String? action, {required bool readOnly}) =>
        TuiGatewayClient.capabilitiesRpcAllowed(
          'plugins.manage',
          action: action,
          readOnly: readOnly,
        );
    expect(allowed('list', readOnly: true), isTrue);
    expect(allowed('list', readOnly: false), isTrue);
    for (final action in const ['install', 'toggle', 'update', 'remove']) {
      expect(allowed(action, readOnly: true), isFalse, reason: action);
      expect(allowed(action, readOnly: false), isTrue, reason: action);
    }
    for (final action in const ['settings', 'onboarding', '', null, 'x']) {
      expect(allowed(action, readOnly: false), isFalse, reason: '$action');
      expect(allowed(action, readOnly: true), isFalse, reason: '$action');
    }
  });
}
