import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;
import 'package:hermes_android/core/services/tui_gateway_client.dart'
    show TuiGatewayRpcError, TuiGatewayRpcFailureKind;

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

  group('plugins through plugins.manage', () {
    late List<(String, Map<String, dynamic>)> sent;
    Object? reply;

    CapabilitiesRepository repoFor(String profile, FakeRest rest) =>
        CapabilitiesRepository(
          rest: rest,
          profile: profile,
          rpc: (method, params) async {
            sent.add((method, params));
            if (reply is Exception) throw reply!;
            return Map<String, dynamic>.from(reply! as Map);
          },
        );

    setUp(() {
      sent = [];
      reply = {'ok': true};
    });

    test(
      'every mutation carries the hub profile and never uses REST',
      () async {
        final rest = FakeRest();
        final repo = repoFor('work', rest);
        await repo.installPlugin('weather');
        await repo.setPluginEnabled('weather', false);
        await repo.updatePlugin('weather', acceptCapabilities: true);
        await repo.removePlugin('weather');
        expect(sent.map((c) => c.$1).toSet(), {'plugins.manage'});
        expect(sent.map((c) => c.$2), [
          {
            'action': 'install',
            'catalog_name': 'weather',
            'enable': true,
            'force': false,
            'profile': 'work',
          },
          {
            'action': 'toggle',
            'name': 'weather',
            'key': 'weather',
            'enable': false,
            'profile': 'work',
          },
          {
            'action': 'update',
            'name': 'weather',
            'accept_capabilities': true,
            'profile': 'work',
          },
          {'action': 'remove', 'name': 'weather', 'profile': 'work'},
        ]);
        expect(rest.calls, isEmpty);
      },
    );

    test('-32601 falls back to REST only on the default profile', () async {
      reply = const TuiGatewayRpcError('plugins.manage', 'nope', code: -32601);
      final rest = FakeRest()
        ..posts['dashboard/agent-plugins/install'] = {'ok': true};
      await repoFor('default', rest).installPlugin('weather');
      expect(rest.calls, ['POST dashboard/agent-plugins/install']);

      final scoped = FakeRest()
        ..posts['dashboard/agent-plugins/install'] = {'ok': true};
      final repo = repoFor('work', scoped);
      await expectLater(
        repo.installPlugin('weather'),
        throwsA(
          isA<CapabilityFailure>().having(
            (e) => e.kind,
            'kind',
            CapabilityFailureKind.unsupported,
          ),
        ),
      );
      expect(scoped.calls, isEmpty);
      expect(repo.supports(CapabilityFeature.pluginMutations), isFalse);
    });

    test('an RPC timeout is uncertain and is not retried', () async {
      reply = const TuiGatewayRpcError(
        'plugins.manage',
        'request timed out after 120s: plugins.manage',
        failureKind: TuiGatewayRpcFailureKind.timeout,
      );
      final rest = FakeRest();
      final repo = repoFor('work', rest);
      await expectLater(
        repo.installPlugin('weather'),
        throwsA(
          isA<CapabilityFailure>().having(
            (e) => e.kind,
            'kind',
            CapabilityFailureKind.uncertain,
          ),
        ),
      );
      expect(sent, hasLength(1));
      expect(rest.calls, isEmpty);
    });

    test('the install result keeps env, issues and live MCP errors', () async {
      reply = {
        'ok': true,
        'missing_env': ['WEATHER_KEY'],
        'warnings': ['pinned to 1a2b3c4d'],
        'known_issues': ['Rate limited'],
        'python_dependencies': ['httpx'],
        'restart_required': true,
        'gateway_reloaded': false,
        'activation': {
          'live_now': {
            'mcp_servers': [
              {'name': 'weather', 'connected': false, 'error': 'spawn failed'},
              {'name': 'ok', 'connected': true},
            ],
          },
        },
      };
      final result = await repoFor('work', FakeRest()).installPlugin('weather');
      expect(result.missingEnv, ['WEATHER_KEY']);
      expect(result.warnings, ['pinned to 1a2b3c4d']);
      expect(result.knownIssues, ['Rate limited']);
      expect(result.pythonDependencies, ['httpx']);
      expect(result.restartRequired, isTrue);
      expect(result.gatewayReloaded, isFalse);
      expect(result.mcpNotices, ['weather: spawn failed']);
    });

    test('list matches installed rows by catalog_name, then name', () async {
      reply = {
        'plugins': [
          {
            'name': 'wx',
            'key': 'wx',
            'catalog_name': 'weather',
            'status': 'enabled',
            'installed_sha': 'abcdef012345',
            'update_available': true,
          },
          {'name': 'notes', 'key': 'notes', 'status': 'disabled'},
        ],
      };
      final repo = repoFor('work', FakeRest());
      final rows = await repo.installedPluginsRpc();
      expect(sent.single.$2, {'action': 'list', 'profile': 'work'});
      expect(rows.match(catalogName: 'weather', name: 'weather')?.name, 'wx');
      expect(rows.match(catalogName: 'notes', name: 'notes')?.enabled, isFalse);
      expect(rows.match(catalogName: 'ghost', name: 'ghost'), isNull);
    });
  });

  group('action loop is cancellable', () {
    FakeRest runningServer() => FakeRest()
      ..posts['skills/hub/install'] = {'ok': true, 'name': 'a'}
      ..gets['actions/a/status'] = {
        'name': 'a',
        'running': true,
        'lines': ['cloning'],
      };

    int statusReads(FakeRest rest) =>
        rest.calls.where((c) => c.startsWith('GET actions/')).length;

    test('cancel stops the loop without another read', () async {
      final rest = runningServer();
      final token = CapabilityActionToken();
      final repo = CapabilitiesRepository(
        rest: rest,
        sleep: (_) async => token.cancel(),
      );
      await expectLater(
        repo.installSkill('x/y', token: token),
        throwsA(isA<CapabilityActionAbandoned>()),
      );
      expect(statusReads(rest), 1);
    });

    test('pause holds the loop; resume reads once and continues', () async {
      final rest = runningServer();
      final token = CapabilityActionToken();
      var sleeps = 0;
      final repo = CapabilitiesRepository(
        rest: rest,
        sleep: (_) async {
          sleeps++;
          if (sleeps == 1) token.pause();
          if (sleeps == 2) token.cancel();
        },
      );
      final run = repo.installSkill('x/y', token: token);
      final settled = expectLater(
        run,
        throwsA(isA<CapabilityActionAbandoned>()),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(statusReads(rest), 1, reason: 'no reads while paused');
      token.resume();
      await settled;
      // resume read once, the next cadence tick cancelled the loop
      expect(statusReads(rest), 2);
    });

    test('an MCP background install follows the returned action', () async {
      final rest = FakeRest()
        ..posts['mcp/catalog/install'] = {
          'ok': true,
          'background': true,
          'action': 'mcp-install-git',
        };
      rest.statusQueue.addAll([
        {
          'name': 'mcp-install-git',
          'running': true,
          'lines': ['cloning'],
        },
        {'name': 'mcp-install-git', 'running': false, 'exit_code': 0},
      ]);
      final seen = <String>[];
      final repo = CapabilitiesRepository(rest: rest, sleep: (_) async {});
      await repo.installMcp('git-server', onProgress: (s) => seen.add(s.tail));
      expect(seen, ['cloning', '']);
      expect(rest.calls.last, 'GET actions/mcp-install-git/status?lines=200');
    });

    test('a failing MCP background install is a real failure', () async {
      final rest = FakeRest()
        ..posts['mcp/catalog/install'] = {
          'ok': true,
          'background': true,
          'action': 'mcp-install-git',
        };
      rest.statusQueue.add({
        'name': 'mcp-install-git',
        'running': false,
        'exit_code': 2,
        'lines': ['build failed'],
      });
      final repo = CapabilitiesRepository(rest: rest, sleep: (_) async {});
      await expectLater(
        repo.installMcp('git-server'),
        throwsA(
          isA<CapabilityFailure>().having(
            (f) => f.detail,
            'detail',
            'build failed',
          ),
        ),
      );
    });

    test(
      'MCP env body carries only declared keys and no value leaks',
      () async {
        const secret = 'sentinel-secret-value-123';
        final rest = FakeRest()..posts['mcp/catalog/install'] = {'ok': true};
        final repo = CapabilitiesRepository(rest: rest, profile: 'work');
        await repo.installMcp(
          'docs',
          environment: {'DOCS_KEY': secret, 'ROGUE': secret},
          declaredEnv: const ['DOCS_KEY', 'OPTIONAL'],
        );
        final body = rest.bodies.single!;
        expect(body['env'], {'DOCS_KEY': secret});
        expect(body['profile'], 'work');
        expect(body['enable'], isTrue);

        rest.posts['mcp/catalog/install'] = DashboardHttpException(
          400,
          body: '{"detail":"bad $secret"}',
        );
        try {
          await repo.installMcp(
            'docs',
            environment: {'DOCS_KEY': secret},
            declaredEnv: const ['DOCS_KEY'],
          );
          fail('expected a failure');
        } on CapabilityFailure catch (error) {
          expect(error.toString(), isNot(contains(secret)));
          expect(error.detail, isNot(contains(secret)));
        }
      },
    );
  });

  test('plugin catalog marks removed entries with the reason', () async {
    final rest = FakeRest()
      ..gets['dashboard/plugins/catalog'] = {
        'entries': [
          {'name': 'old-one', 'repo': 'https://git.example.test/a/old'},
          {'name': 'renamed', 'repo': 'https://git.example.test/a/bad.git/'},
          {'name': 'fine', 'repo': 'https://git.example.test/a/fine'},
        ],
        'removed': [
          {'name': 'old-one', 'reason': 'Abandoned', 'date': '2026-09-01'},
          {'repo': 'https://git.example.test/a/BAD', 'reason': 'Malicious'},
        ],
      };
    final items = await CapabilitiesRepository(rest: rest).pluginCatalog();
    final byName = {for (final i in items) i.installId: i};
    expect(byName['old-one']!.disclosure.removedReason, 'Abandoned');
    expect(byName['renamed']!.disclosure.removedReason, 'Malicious');
    expect(byName['fine']!.disclosure.removedReason, isEmpty);
  });

  group('plugin credentials through PUT /api/env', () {
    test('only the declared names are sent, with the hub profile', () async {
      final rest = FakeRest()..puts['env'] = {'ok': true};
      final repo = CapabilitiesRepository(rest: rest, profile: 'work');
      await repo.setPluginEnv(
        {'WEATHER_KEY': 'v1', 'ROGUE': 'v2', 'bad name': 'v3'},
        declared: const ['WEATHER_KEY', 'OTHER'],
      );
      expect(rest.calls, ['PUT env']);
      expect(rest.bodies.single, {
        'key': 'WEATHER_KEY',
        'value': 'v1',
        'profile': 'work',
      });
    });

    test('a failure never carries the value and 404 is unsupported', () async {
      const secret = 'sentinel-secret-value-123';
      final rest = FakeRest()
        ..puts['env'] = DashboardHttpException(
          400,
          body: '{"detail":"bad $secret"}',
        );
      final repo = CapabilitiesRepository(rest: rest);
      try {
        await repo.setPluginEnv(
          {'WEATHER_KEY': secret},
          declared: const ['WEATHER_KEY'],
        );
        fail('expected a failure');
      } on CapabilityFailure catch (error) {
        expect('$error ${error.detail}', isNot(contains(secret)));
      }
      final missing = CapabilitiesRepository(rest: FakeRest());
      await expectLater(
        missing.setPluginEnv({'A': 'b'}, declared: const ['A']),
        throwsA(
          isA<CapabilityFailure>().having(
            (e) => e.kind,
            'kind',
            CapabilityFailureKind.unsupported,
          ),
        ),
      );
      expect(missing.supports(CapabilityFeature.envSet), isFalse);
    });
  });
}
