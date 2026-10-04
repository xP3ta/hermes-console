import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';

CapabilityActionStatus _exit(List<String> lines) => CapabilityActionStatus(
  name: 'a',
  running: false,
  exitCode: 1,
  lines: lines,
);

void main() {
  group('security scan gate (ported from Desktop)', () {
    test('current log shape, with and without a findings count', () {
      final counted = _exit([
        'Not installed: the security scan found 3 high-risk pattern(s)',
      ]);
      expect(counted.blockedByScan, isTrue);
      expect(counted.scanFindings, 3);
      final bare = _exit([
        'Not installed: the security scan found high-risk pattern(s)',
      ]);
      expect(bare.blockedByScan, isTrue);
      expect(bare.scanFindings, isNull);
    });

    test('unverified shape', () {
      final status = _exit(['hermes never installs unverified skills']);
      expect(status.blockedByScan, isTrue);
      expect(status.scanFindings, isNull);
    });

    test('legacy shape keeps the findings count', () {
      final status = _exit([
        'Installation blocked: refused (community source + caution verdict, 2 findings)',
      ]);
      expect(status.blockedByScan, isTrue);
      expect(status.scanFindings, 2);
    });

    test('unrelated failures are not scan blocks', () {
      expect(_exit(['network error']).blockedByScan, isFalse);
      // Old heuristic matched any "blocked" next to "security scan".
      expect(
        _exit(['the security scan was blocked by a proxy']).blockedByScan,
        isFalse,
      );
    });
  });

  group('catalog disclosure', () {
    test('plugin entry keeps pin, repo, platforms and known issues', () {
      final item = CapabilityItem.catalogPlugin({
        'name': 'weather',
        'tier': 'community',
        'maintainer': 'Example Labs',
        'version': '1.2.0',
        'repo': 'https://git.example.test/labs/weather',
        'sha': 'abcdef0123456789abcdef0123456789abcdef01',
        'sha_short': 'abcdef01',
        'subdir': 'plugin',
        'platforms': ['linux', 'macos'],
        'requires_hermes': '>=1.2.15',
        'known_issues': ['Rate limited', null],
        'capabilities': {
          'provides_tools': ['weather_now'],
          'provides_hooks': ['on_turn'],
          'provides_middleware': ['cache'],
          'requires_env': ['WEATHER_KEY'],
        },
      })!;
      final d = item.disclosure;
      expect(d.repo, 'https://git.example.test/labs/weather');
      expect(d.subdir, 'plugin');
      expect(d.sha8, 'abcdef01');
      expect(d.pin('1.2.0'), '1.2.0 @ abcdef01');
      expect(d.pin(''), 'abcdef01');
      expect(d.platforms, ['linux', 'macos']);
      expect(d.requiresHermes, '>=1.2.15');
      expect(d.knownIssues, ['Rate limited']);
      expect(d.hooks, ['on_turn']);
      expect(d.middleware, ['cache']);
      expect(item.requirements, ['WEATHER_KEY']);
    });

    test('every optional field may be absent or null', () {
      final item = CapabilityItem.catalogPlugin({
        'name': 'bare',
        'sha': null,
        'repo': null,
        'subdir': null,
        'platforms': null,
        'known_issues': null,
        'capabilities': null,
        'requires_hermes': null,
      })!;
      final d = item.disclosure;
      expect(d.repo, isEmpty);
      expect(d.sha8, isEmpty);
      expect(d.pin(''), isEmpty);
      expect(d.platforms, isEmpty);
      expect(d.knownIssues, isEmpty);
      expect(d.removedReason, isEmpty);
    });

    test('MCP git entry exposes install_url, ref, bootstrap and auth', () {
      final item = CapabilityItem.catalogMcp({
        'name': 'docs',
        'transport': 'stdio',
        'command': 'node',
        'args': ['dist/index.js'],
        'auth_type': 'api_key',
        'install_url': 'https://git.example.test/labs/docs-mcp',
        'install_ref': 'v1.0.0',
        'bootstrap': [
          'npm ci',
          ['npm', 'run', 'build'],
          {'command': 'node', 'args': ['scripts/setup.js']},
          null,
        ],
        'post_install': 'Restart the agent',
      })!;
      final d = item.disclosure;
      expect(d.installUrl, 'https://git.example.test/labs/docs-mcp');
      expect(d.installRef, 'v1.0.0');
      expect(d.bootstrap, [
        'npm ci',
        'npm run build',
        'node scripts/setup.js',
      ]);
      expect(d.authType, 'api_key');
      expect(d.postInstall, 'Restart the agent');
      expect(item.command, 'node dist/index.js');
    });

    test('hub skill keeps its source repo', () {
      final item = CapabilityItem.hubSkill({
        'name': 'docker',
        'identifier': 'community/devops/docker',
        'trust_level': 'community',
        'repo': 'https://git.example.test/skills',
        'tags': ['ops'],
      })!;
      expect(item.disclosure.repo, 'https://git.example.test/skills');
      expect(item.trust, CapabilityTrust.community);
    });

    test('copyWith keeps the disclosure', () {
      final item = CapabilityItem.catalogPlugin({
        'name': 'weather',
        'sha': 'abcdef0123456789abcdef0123456789abcdef01',
      })!;
      expect(item.copyWith(installed: true).disclosure.sha8, 'abcdef01');
    });
  });
}
