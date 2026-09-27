import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;
import 'package:hermes_android/core/services/tui_gateway_client.dart'
    show TuiGatewayRpcError;

class FakeRest implements CapabilitiesRest {
  final Map<String, Object> gets = {};
  final Map<String, Object> posts = {};
  final Map<String, Object> puts = {};
  final List<String> calls = [];
  final List<Map<String, dynamic>?> bodies = [];
  final List<Map<String, dynamic>> statusQueue = [];

  Object _resolve(Map<String, Object> table, String endpoint) {
    final path = endpoint.split('?').first;
    return table[endpoint] ??
        table[path] ??
        (throw const DashboardHttpException(404));
  }

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    calls.add('GET $endpoint');
    if (endpoint.startsWith('actions/') && statusQueue.isNotEmpty) {
      return statusQueue.removeAt(0);
    }
    final value = _resolve(gets, endpoint);
    if (value is Exception) throw value;
    if (value is List) return {'data': value};
    return Map<String, dynamic>.from(value as Map);
  }

  @override
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic>? body,
    Duration? timeout,
  }) async {
    calls.add('POST $endpoint');
    bodies.add(body);
    final value = _resolve(posts, endpoint);
    if (value is Exception) throw value;
    return Map<String, dynamic>.from(value as Map);
  }

  @override
  Future<Map<String, dynamic>> put(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    calls.add('PUT $endpoint');
    bodies.add(body);
    final value = _resolve(puts, endpoint);
    if (value is Exception) throw value;
    return Map<String, dynamic>.from(value as Map);
  }

  @override
  Future<void> delete(String endpoint) async {
    calls.add('DELETE $endpoint');
  }
}

void main() {
  test('installed skills merge into the official catalog', () async {
    final rest = FakeRest()
      ..gets['skills'] = [
        {
          'name': 'arxiv',
          'description': 'Search papers',
          'category': 'research',
          'enabled': false,
          'provenance': 'hub',
        },
        {
          'name': 'mine',
          'description': 'Hand made',
          'enabled': true,
          'provenance': 'agent',
        },
      ]
      ..gets['skills/hub/official'] = {
        'skills': [
          {
            'name': 'arxiv',
            'identifier': 'official/research/arxiv',
            'description': 'Search papers',
            'category': 'research',
            'installed': true,
          },
          {
            'name': 'docker',
            'identifier': 'official/devops/docker',
            'category': 'devops',
            'installed': false,
          },
        ],
      };
    final repo = CapabilitiesRepository(rest: rest);
    final merged = mergeSkills(
      installed: await repo.installedSkills(),
      official: await repo.officialSkills(),
    );
    expect(merged.map((s) => s.name), ['arxiv', 'docker', 'mine']);
    final arxiv = merged.first;
    expect(arxiv.installed, isTrue);
    expect(arxiv.enabled, isFalse);
    expect(arxiv.trust, CapabilityTrust.official);
    expect(arxiv.canRemove, isTrue);
    expect(arxiv.installId, 'official/research/arxiv');
    expect(merged[1].installed, isFalse);
    expect(merged[2].trust, CapabilityTrust.local);
    expect(merged[2].canRemove, isFalse);
  });

  test('profile scope rides every REST call', () async {
    final rest = FakeRest()
      ..gets['skills'] = <Object>[]
      ..puts['skills/toggle'] = {'ok': true};
    final repo = CapabilitiesRepository(rest: rest, profile: 'coder');
    await repo.installedSkills();
    await repo.setSkillEnabled('arxiv', false);
    expect(rest.calls, [
      'GET skills?profile=coder',
      'PUT skills/toggle?profile=coder',
    ]);
    expect(rest.bodies.last, {
      'name': 'arxiv',
      'enabled': false,
      'profile': 'coder',
    });
  });

  test('a 404 marks the feature unsupported and never retries', () async {
    final rest = FakeRest();
    final repo = CapabilitiesRepository(rest: rest);
    await expectLater(
      repo.pluginCatalog(),
      throwsA(
        isA<CapabilityFailure>().having(
          (f) => f.kind,
          'kind',
          CapabilityFailureKind.unsupported,
        ),
      ),
    );
    expect(repo.supports(CapabilityFeature.pluginCatalog), isFalse);
    await expectLater(repo.pluginCatalog(), throwsA(isA<CapabilityFailure>()));
    expect(
      rest.calls.where((c) => c.contains('plugins/catalog')),
      hasLength(1),
    );
  });

  test('skill install polls the action until a clean exit', () async {
    final rest = FakeRest()
      ..posts['skills/hub/install'] = {
        'ok': true,
        'pid': 1,
        'name': 'skills-install-arxiv-1',
      };
    rest.statusQueue.addAll([
      {
        'name': 'skills-install-arxiv-1',
        'running': true,
        'lines': ['cloning'],
      },
      {
        'name': 'skills-install-arxiv-1',
        'running': false,
        'exit_code': 0,
        'lines': ['installed arxiv'],
      },
    ]);
    final progress = <bool>[];
    final repo = CapabilitiesRepository(rest: rest, sleep: (_) async {});
    final status = await repo.installSkill(
      'official/research/arxiv',
      onProgress: (s) => progress.add(s.running),
    );
    expect(status.succeeded, isTrue);
    expect(progress, [true, false]);
    expect(rest.bodies.first, {'identifier': 'official/research/arxiv'});
    expect(
      rest.calls.last,
      'GET actions/skills-install-arxiv-1/status?lines=200',
    );
  });

  test('a non-zero exit is a real failure with the log tail', () async {
    final rest = FakeRest()
      ..posts['skills/hub/install'] = {'ok': true, 'name': 'a'};
    rest.statusQueue.add({
      'name': 'a',
      'running': false,
      'exit_code': 1,
      'lines': [
        'Not installed: the security scan found 2 high-risk pattern(s)',
        '=== a finished ===',
      ],
    });
    final repo = CapabilitiesRepository(rest: rest, sleep: (_) async {});
    await expectLater(
      repo.installSkill('x/y'),
      throwsA(
        isA<CapabilityFailure>()
            .having((f) => f.kind, 'kind', CapabilityFailureKind.blockedByScan)
            .having((f) => f.detail, 'detail', contains('security scan')),
      ),
    );
  });

  test('plugin catalog parses tier, update and runtime state', () async {
    final rest = FakeRest()
      ..gets['dashboard/plugins/catalog'] = {
        'entries': [
          {
            'name': 'hindsight',
            'title': 'Hindsight',
            'description': 'Memory',
            'tier': 'official',
            'category': 'memory',
            'maintainer': 'Vectorize',
            'version': '1.2',
            'installed': true,
            'update_available': true,
            'runtime_status': 'enabled',
            'capabilities': {
              'provides_tools': ['recall'],
              'requires_env': ['HINDSIGHT_KEY'],
            },
          },
        ],
      }
      ..posts['dashboard/agent-plugins/hindsight/update'] = {
        'ok': false,
        'consent_required': true,
        'delta_lines': ['+ tool: reflect'],
      };
    final repo = CapabilitiesRepository(rest: rest);
    final plugin = (await repo.pluginCatalog()).single;
    expect(plugin.name, 'Hindsight');
    expect(plugin.installId, 'hindsight');
    expect(plugin.trust, CapabilityTrust.official);
    expect(plugin.enabled, isTrue);
    expect(plugin.updateAvailable, isTrue);
    expect(plugin.tools, ['recall']);
    final update = await repo.updatePlugin('hindsight');
    expect(update.consentRequired, isTrue);
    expect(update.deltaLines, ['+ tool: reflect']);
  });

  test('hosted connectors: join, signed out and missing RPC', () async {
    final repo = CapabilitiesRepository(
      rest: FakeRest(),
      rpc: (method, params) async => switch (method) {
        'connectors.list' => {
          'available': true,
          'connectors': [
            {'connector': 'github', 'connected': true, 'enabled': true},
          ],
        },
        'connectors.catalog' => {
          'connectors': [
            {'slug': 'gmail', 'name': 'Gmail', 'description': 'Mail'},
            {'slug': 'github', 'name': 'GitHub', 'description': 'Code'},
          ],
        },
        'connectors.accounts' => {
          'accounts': [
            {'connector': 'github', 'connection_id': 'c1'},
          ],
        },
        _ => throw StateError(method),
      },
    );
    final snap = await repo.hostedConnectors();
    expect(snap.availability, ConnectorAvailability.available);
    expect(snap.connectors.map((c) => c.slug), ['gmail', 'github']);
    expect(snap.connectors.last.connected, isTrue);
    expect(snap.connectors.last.connectionIds, ['c1']);

    final signedOut = CapabilitiesRepository(
      rest: FakeRest(),
      rpc: (method, _) async => throw TuiGatewayRpcError(
        method,
        'Sign in',
        code: 4031,
        data: const {'reason': 'NEEDS_NOUS_AUTH'},
      ),
    );
    expect(
      (await signedOut.hostedConnectors()).availability,
      ConnectorAvailability.signedOut,
    );

    final old = CapabilitiesRepository(
      rest: FakeRest(),
      rpc: (method, _) async =>
          throw TuiGatewayRpcError(method, 'nope', code: -32601),
    );
    expect(
      (await old.hostedConnectors()).availability,
      ConnectorAvailability.unsupported,
    );
  });

  test('connect operation keeps the link and only accepts https', () async {
    final first = ConnectOperation.fromJson({
      'op_id': 'op1',
      'seq': 1,
      'settled': false,
      'targets': [
        {
          'name': 'gmail',
          'state': 'initiated',
          'connect_url': 'https://auth.example/x',
          'connection_id': 'c9',
        },
      ],
    });
    expect(first.connectUrl, Uri.parse('https://auth.example/x'));
    final second = ConnectOperation.fromJson({
      'op_id': 'op1',
      'seq': 2,
      'settled': true,
      'settled_by': 'all_resolved',
      'targets': [
        {'name': 'gmail', 'state': 'connected'},
      ],
    }).carryLinkFrom(first);
    expect(second.connectUrl, first.connectUrl);
    expect(second.allConnected, isTrue);
    expect(second.connectionIds, ['c9']);
    final unsafe = ConnectOperation.fromJson({
      'op_id': 'x',
      'targets': [
        {'name': 'g', 'connect_url': 'javascript:alert(1)'},
      ],
    });
    expect(unsafe.connectUrl, isNull);
  });

  test('filters combine as AND across facets', () {
    const items = [
      CapabilityItem(
        kind: CapabilityKind.skill,
        id: 'a',
        name: 'arxiv',
        category: 'research',
        trust: CapabilityTrust.official,
        installed: true,
      ),
      CapabilityItem(
        kind: CapabilityKind.plugin,
        id: 'b',
        name: 'hindsight',
        category: 'memory',
        trust: CapabilityTrust.community,
      ),
      CapabilityItem(
        kind: CapabilityKind.skill,
        id: 'c',
        name: 'pubmed',
        category: 'research',
        trust: CapabilityTrust.community,
      ),
    ];
    expect(
      filterCapabilities(
        items,
        const CapabilityFilter(category: 'research'),
      ).map((i) => i.id),
      ['a', 'c'],
    );
    expect(
      filterCapabilities(
        items,
        const CapabilityFilter(category: 'research', installedOnly: true),
      ).map((i) => i.id),
      ['a'],
    );
    expect(
      filterCapabilities(
        items,
        const CapabilityFilter(kind: CapabilityKind.plugin, query: 'hind'),
      ).map((i) => i.id),
      ['b'],
    );
    expect(capabilityCategories(items).first, ('research', 2));
  });
}
