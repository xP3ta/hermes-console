import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capability_detail_screen.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/capabilities/capability_ui.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;
import 'package:hermes_android/l10n/app_localizations_es.dart';

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

const _docker = CapabilityItem(
  kind: CapabilityKind.skill,
  id: 'skill:official:official/devops/docker',
  name: 'docker',
  description: 'Manage containers and compose stacks',
  category: 'devops',
  source: 'official',
  trust: CapabilityTrust.official,
  installId: 'official/devops/docker',
  installedName: 'docker',
  provenance: 'hub',
  canRemove: true,
);

const _weatherCatalog = CapabilityItem(
  kind: CapabilityKind.plugin,
  id: 'plugin:community:weather',
  name: 'Weather',
  description:
      'Forecasts for any city. Disclosure: hosted-only connector; city names go to weather.example.test.',
  source: 'community',
  trust: CapabilityTrust.community,
  author: 'Example Labs',
  version: '1.2.0',
  installId: 'weather',
  installedName: 'weather',
  tools: ['weather_now'],
  requirements: ['WEATHER_KEY'],
  disclosure: CapabilityDisclosure(
    repo: 'https://git.example.test/labs/weather',
    subdir: 'plugin',
    sha: 'abcdef0123456789abcdef0123456789abcdef01',
    platforms: ['linux', 'macos'],
    requiresHermes: '>=1.2.15',
    hooks: ['on_turn'],
    middleware: ['cache'],
    knownIssues: ['Rate limited'],
  ),
);

const _weather = CapabilityItem(
  kind: CapabilityKind.plugin,
  id: 'plugin:community:weather',
  name: 'Weather',
  description: 'Forecasts for any city',
  source: 'community',
  trust: CapabilityTrust.community,
  author: 'Example Labs',
  version: '1.2.0',
  installId: 'weather',
  installedName: 'weather',
  installedKey: 'weather',
  installed: true,
  enabled: true,
  updateAvailable: true,
  canRemove: true,
  tools: ['weather_now'],
  requirements: ['WEATHER_KEY'],
);

Future<void> _pump(
  WidgetTester tester,
  CapabilityItem item,
  ScriptedRest rest, {
  bool readOnly = false,
  VoidCallback? onChanged,
  CapabilitiesRepository? repository,
}) async {
  await setPhone(tester);
  await tester.pumpWidget(
    spanishApp(
      CapabilityDetailScreen(
        item: item,
        repository: repository ?? repoOf(rest),
        readOnly: readOnly,
        onChanged: onChanged,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadInterFont);

  group('capabilityActions', () {
    test('not installed → install; read-only → nothing mutating', () {
      expect(capabilityActions(_docker, readOnly: false), [
        CapabilityAction.install,
      ]);
      expect(capabilityActions(_docker, readOnly: true), isEmpty);
    });

    test('a keyless plugin row stays read-only for toggles', () {
      // Names collide across categories; only the canonical key addresses a
      // plugin, so a legacy row without one cannot be toggled.
      final keyless = _weather.copyWith(installedKey: '');
      expect(capabilityActions(keyless, readOnly: false), [
        CapabilityAction.update,
        CapabilityAction.remove,
      ]);
    });

    test('installed plugin with update → update first, remove last', () {
      expect(capabilityActions(_weather, readOnly: false), [
        CapabilityAction.update,
        CapabilityAction.disable,
        CapabilityAction.remove,
      ]);
    });

    test('MCP entry that needs credentials installs through the env sheet', () {
      const mcp = CapabilityItem(
        kind: CapabilityKind.mcp,
        id: 'mcp:catalog:github',
        name: 'github',
        installId: 'github',
        env: [CapabilityEnvField(name: 'GITHUB_TOKEN')],
      );
      expect(capabilityActions(mcp, readOnly: false), [
        CapabilityAction.install,
      ]);
      expect(capabilityActions(mcp, readOnly: true), isEmpty);
    });

    test('a removed catalog entry has no install', () {
      final removed = _weatherCatalog.copyWith(
        disclosure: _weatherCatalog.disclosure.withRemoved('Abandoned'),
      );
      expect(capabilityActions(_weatherCatalog, readOnly: false), [
        CapabilityAction.install,
      ]);
      expect(capabilityActions(removed, readOnly: false), isEmpty);
    });

    test('only https docs links are offered', () {
      const withHttp = CapabilityItem(
        kind: CapabilityKind.skill,
        id: 'x',
        name: 'x',
        docsUrl: 'http://example.com',
      );
      const withHttps = CapabilityItem(
        kind: CapabilityKind.skill,
        id: 'y',
        name: 'y',
        docsUrl: 'https://example.com/docs',
      );
      expect(capabilityActions(withHttp, readOnly: true), isEmpty);
      expect(capabilityActions(withHttps, readOnly: true), [
        CapabilityAction.docs,
      ]);
    });
  });

  testWidgets('install: one primary action, real server call, state flips', (
    tester,
  ) async {
    var changed = 0;
    final rest = ScriptedRest()
      ..posts['skills/hub/install'] = {'ok': true, 'name': 'install-docker'}
      ..statusQueue.addAll([
        {
          'name': 'install-docker',
          'running': true,
          'lines': ['Fetching docker'],
        },
        {'name': 'install-docker', 'running': false, 'exit_code': 0},
      ]);
    await _pump(tester, _docker, rest, onChanged: () => changed++);

    expect(find.text('docker'), findsOneWidget);
    expect(find.text('No instalada'), findsOneWidget);
    expect(find.text('Oficial'), findsOneWidget);
    expect(find.text('Mantenida por el proyecto Hermes.'), findsOneWidget);
    expect(find.byType(HermesActionButton), findsOneWidget);
    expect(find.text('Instalar'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();

    expect(rest.mutations, ['POST skills/hub/install']);
    expect(changed, 1);
    expect(find.text('Activa'), findsOneWidget);
    expect(find.textContaining('docker instalada'), findsOneWidget);
    expect(find.textContaining('sesiones nuevas'), findsOneWidget);
    // Installed hub skill: primary becomes Disable, remove in "More".
    expect(find.text('Desactivar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('progress surface cannot be dismissed while the action runs', (
    tester,
  ) async {
    final rest = ScriptedRest()
      ..posts['skills/hub/install'] = {'ok': true, 'name': 'install-docker'};
    // Keeps answering "running" until the test releases it.
    var release = false;
    final repoRest = _GatedRest(rest, () => release);
    await setPhone(tester);
    await tester.pumpWidget(
      spanishApp(
        CapabilityDetailScreen(item: _docker, repository: repoOf(repoRest)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('cph-progress')), findsOneWidget);
    expect(find.text('Instalando docker…'), findsOneWidget);
    // Tap on the scrim and system back do nothing.
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('cph-progress')), findsOneWidget);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    await nav.maybePop();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('cph-progress')), findsOneWidget);

    release = true;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cph-progress')), findsNothing);
    expect(find.text('Activa'), findsOneWidget);
  });

  testWidgets('a failed install keeps the state and shows the log tail', (
    tester,
  ) async {
    final rest = ScriptedRest()
      ..posts['skills/hub/install'] = {'ok': true, 'name': 'install-docker'}
      ..statusQueue.add({
        'name': 'install-docker',
        'running': false,
        'exit_code': 1,
        'lines': ['fatal: network unreachable'],
      });
    await _pump(tester, _docker, rest);
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();

    expect(find.text('No instalada'), findsOneWidget);
    expect(find.textContaining('fatal: network unreachable'), findsOneWidget);
    expect(find.byKey(const ValueKey('cph-progress')), findsNothing);
  });

  testWidgets('plugin: update is primary, remove lives in More', (
    tester,
  ) async {
    var changed = 0;
    final rest = ScriptedRest()
      ..posts['dashboard/agent-plugins/weather/update'] = {'ok': true};
    await _pump(tester, _weather, rest, onChanged: () => changed++);

    expect(find.text('Actualización disponible'), findsOneWidget);
    expect(find.text('Comunidad'), findsOneWidget);
    expect(find.text('Example Labs'), findsOneWidget);
    expect(find.text('weather_now'), findsOneWidget);
    expect(find.text('WEATHER_KEY'), findsOneWidget);
    expect(find.text('Quitar'), findsNothing);

    await tester.tap(find.byTooltip('Más opciones'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cph-action-remove')), findsOneWidget);
    expect(find.byKey(const ValueKey('cph-action-disable')), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();
    expect(rest.mutations, ['POST dashboard/agent-plugins/weather/update']);
    expect(changed, 1);
    expect(find.text('Actualización disponible'), findsNothing);
  });

  testWidgets('remove from More deletes on the server', (tester) async {
    final rest = ScriptedRest();
    await _pump(tester, _weather.copyWith(updateAvailable: false), rest);
    await tester.tap(find.byTooltip('Más opciones'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cph-action-remove')));
    await tester.pumpAndSettle();

    expect(rest.mutations, ['DELETE dashboard/agent-plugins/weather']);
    expect(find.text('Weather quitada'), findsOneWidget);
    expect(find.text('No instalada'), findsOneWidget);
  });

  testWidgets('read-only detail: no primary, no More, lock tag, reason', (
    tester,
  ) async {
    final rest = ScriptedRest();
    await _pump(tester, _weather, rest, readOnly: true);

    expect(find.byKey(const ValueKey('cph-primary')), findsNothing);
    expect(find.byTooltip('Más opciones'), findsNothing);
    expect(find.text('Solo lectura'), findsOneWidget);
    expect(
      find.text('Conexión de solo lectura: los cambios están desactivados.'),
      findsOneWidget,
    );
    expect(rest.calls, isEmpty);
  });

  testWidgets('plugin disclosure is visible before install', (tester) async {
    await _pump(tester, _weatherCatalog, ScriptedRest());
    for (final text in const [
      'Example Labs',
      '1.2.0 @ abcdef01',
      'https://git.example.test/labs/weather',
      'plugin',
      'linux, macos',
      '>=1.2.15',
      'weather_now',
      'on_turn',
      'cache',
      'WEATHER_KEY',
      'Rate limited',
    ]) {
      expect(find.textContaining(text), findsWidgets, reason: text);
    }
    // The disclosure text is read in full, not collapsed.
    final block = tester.widget<HermesTextBlock>(find.byType(HermesTextBlock));
    expect(block.collapsedLines, greaterThanOrEqualTo(40));
    expect(find.byKey(const ValueKey('cph-primary')), findsOneWidget);
  });

  testWidgets('unknown profile state offers no install and says so', (
    tester,
  ) async {
    await _pump(
      tester,
      _weatherCatalog.copyWith(stateUnknown: true),
      ScriptedRest(),
    );
    expect(find.byKey(const ValueKey('cph-primary')), findsNothing);
    expect(find.text('Estado no disponible'), findsWidgets);
    expect(find.text('No instalada'), findsNothing);
  });

  testWidgets('a removed entry shows the reason and no install', (
    tester,
  ) async {
    await _pump(
      tester,
      _weatherCatalog.copyWith(
        disclosure: _weatherCatalog.disclosure.withRemoved('Abandoned'),
      ),
      ScriptedRest(),
    );
    expect(find.textContaining('Abandoned'), findsWidgets);
    expect(find.byKey(const ValueKey('cph-primary')), findsNothing);
  });

  testWidgets('MCP git entry discloses what runs on the server', (
    tester,
  ) async {
    await _pump(tester, _gitMcp, ScriptedRest());
    for (final text in const [
      'https://git.example.test/labs/docs-mcp',
      'v1.0.0',
      'npm ci',
      'npm run build',
      'api_key',
      'node dist/index.js',
    ]) {
      expect(find.textContaining(text), findsWidgets, reason: text);
    }
  });

  testWidgets('preview and scan rows need support already confirmed', (
    tester,
  ) async {
    // Opening a skill sends nothing: with support undeclared, no row is
    // painted and no probe is made, however often it rebuilds.
    final legacy = ScriptedRest();
    await _pump(tester, _docker, legacy);
    expect(find.byKey(const ValueKey('cph-row-preview')), findsNothing);
    expect(find.byKey(const ValueKey('cph-row-scan')), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(legacy.calls, isEmpty);
  });

  testWidgets('a confirmed preview shows its row and reads it on tap', (
    tester,
  ) async {
    final rest = ScriptedRest()
      ..gets['skills/hub/preview'] = {
        'name': 'docker',
        'skill_md': '# Docker\nRuns **containers**',
        'files': ['SKILL.md', 'scripts/run.sh'],
      };
    // An earlier server response (e.g. the list screen) confirmed the route.
    final repo = repoOf(rest);
    await repo.skillPreview(_docker.installId);
    rest.calls.clear();
    await _pump(tester, _docker, rest, repository: repo);
    expect(rest.calls, isEmpty);
    await tester.ensureVisible(find.byKey(const ValueKey('cph-row-preview')));
    await tester.tap(find.byKey(const ValueKey('cph-row-preview')));
    await tester.pumpAndSettle();
    expect(rest.calls.where((c) => c.startsWith('GET skills/hub/preview')), [
      'GET skills/hub/preview?identifier=official%2Fdevops%2Fdocker',
    ]);
    expect(find.textContaining('Runs **containers**'), findsOneWidget);
    expect(find.textContaining('scripts/run.sh'), findsOneWidget);
    // Scan support was never confirmed: no row.
    expect(find.byKey(const ValueKey('cph-row-scan')), findsNothing);
  });

  testWidgets('the scan row appears once the route is confirmed', (
    tester,
  ) async {
    final rest = ScriptedRest()
      ..gets['skills/hub/scan'] = {'summary': 'Clean', 'findings': <Object>[]};
    final repo = repoOf(rest);
    await repo.skillScan('official/devops/docker');
    rest.calls.clear();
    await setPhone(tester);
    await tester.pumpWidget(
      spanishApp(CapabilityDetailScreen(item: _docker, repository: repo)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cph-row-scan')), findsOneWidget);
    expect(rest.calls.where((c) => c.contains('scan')), isEmpty);
  });

  testWidgets('a blocked skill install offers the scan, never an override', (
    tester,
  ) async {
    final rest = ScriptedRest()
      ..posts['skills/hub/install'] = {'ok': true, 'name': 'install-docker'}
      ..gets['skills/hub/scan'] = {
        'summary': 'Two risky patterns',
        'findings': [
          {'severity': 'high', 'description': 'curl piped to shell'},
        ],
      }
      ..statusQueue.add({
        'name': 'install-docker',
        'running': false,
        'exit_code': 1,
        'lines': [
          'Not installed: the security scan found 2 high-risk pattern(s)',
        ],
      });
    await _pump(tester, _docker, rest);
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'Bloqueada por el escaneo de seguridad (2 hallazgos)',
      ),
      findsOneWidget,
    );
    expect(find.text('Ver escaneo'), findsOneWidget);
    expect(find.textContaining('force'), findsNothing);
    await tester.tap(find.text('Ver escaneo'));
    await tester.pumpAndSettle();
    expect(rest.calls.where((c) => c.startsWith('GET skills/hub/scan')), [
      'GET skills/hub/scan?identifier=official%2Fdevops%2Fdocker',
    ]);
    expect(find.textContaining('curl piped to shell'), findsOneWidget);
  });

  testWidgets('MCP env sheet: obscured fields, only declared keys, cleared', (
    tester,
  ) async {
    const secret = 'sentinel-secret-value-123';
    final rest = ScriptedRest()
      ..posts['mcp/catalog/install'] = const DashboardHttpException(
        400,
        body: '{"detail":"rejected"}',
      );
    await _pump(tester, _gitMcp, rest);
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('cph-env-sheet')), findsOneWidget);
    for (final name in const ['DOCS_KEY', 'DOCS_REGION']) {
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(ValueKey('cph-env-field-$name')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.obscureText, isTrue, reason: name);
      expect(field.autocorrect, isFalse, reason: name);
      expect(field.enableSuggestions, isFalse, reason: name);
      expect(field.enableIMEPersonalizedLearning, isFalse, reason: name);
    }
    await tester.enterText(
      find.byKey(const ValueKey('cph-env-field-DOCS_KEY')),
      secret,
    );
    await tester.tap(find.byKey(const ValueKey('cph-env-submit')));
    await tester.pumpAndSettle();

    expect(rest.mutations, ['POST mcp/catalog/install']);
    expect(rest.bodies.single!['env'], {'DOCS_KEY': secret});
    expect(rest.bodies.single!['enable'], isTrue);
    // The call failed: nothing keeps the value, not even the next sheet.
    expect(find.textContaining(secret), findsNothing);
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();
    final again = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('cph-env-field-DOCS_KEY')),
        matching: find.byType(TextField),
      ),
    );
    expect(again.controller!.text, isEmpty);
  });

  testWidgets('MCP env sheet: a required field must be filled', (tester) async {
    final rest = ScriptedRest()..posts['mcp/catalog/install'] = {'ok': true};
    await _pump(tester, _gitMcp, rest);
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cph-env-submit')));
    await tester.pumpAndSettle();
    expect(rest.mutations, isEmpty);
    expect(find.byKey(const ValueKey('cph-env-sheet')), findsOneWidget);
  });

  testWidgets('plugin install with missing env offers the credentials', (
    tester,
  ) async {
    const secret = 'sentinel-secret-value-123';
    final rest = ScriptedRest()
      ..posts['dashboard/agent-plugins/install'] = {
        'ok': true,
        'missing_env': ['WEATHER_KEY'],
      }
      ..puts['env'] = {'ok': true};
    rest.putProbe = const DashboardHttpException(422);
    await _pump(tester, _weatherCatalog, rest);
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Faltan credenciales: WEATHER_KEY'),
      findsOneWidget,
    );
    await tester.tap(find.text('Añadir credenciales'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cph-env-sheet')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('cph-env-field-WEATHER_KEY')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('cph-env-field-OTHER')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('cph-env-field-WEATHER_KEY')),
      secret,
    );
    await tester.tap(find.byKey(const ValueKey('cph-env-submit')));
    await tester.pumpAndSettle();
    expect(rest.calls.where((c) => c.startsWith('PUT')), [
      'PUT env',
      'PUT env',
    ]);
    expect(rest.bodies.last, {'key': 'WEATHER_KEY', 'value': secret});
    expect(find.textContaining(secret), findsNothing);
  });

  testWidgets('no credentials action when the env route is not confirmed', (
    tester,
  ) async {
    final rest = ScriptedRest()
      ..posts['dashboard/agent-plugins/install'] = {
        'ok': true,
        'missing_env': ['WEATHER_KEY'],
      };
    await _pump(tester, _weatherCatalog, rest);
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Faltan credenciales: WEATHER_KEY'),
      findsOneWidget,
    );
    expect(find.text('Añadir credenciales'), findsNothing);
    // The probe carries no value, so no secret can reach a server that lacks
    // the route.
    expect(
      rest.bodies.whereType<Map>().where((b) => b.containsKey('value')),
      isEmpty,
    );
  });

  test('install confirmation repeats the essentials', () {
    final s = StringsEs();
    final community = capabilityInstallConfirmation(
      s,
      _weatherCatalog,
      destination: 'Casa · work',
    );
    expect(community.title, contains('Weather'));
    for (final part in const [
      'Example Labs',
      'https://git.example.test/labs/weather',
      'Comunidad',
      'Casa · work',
    ]) {
      expect(community.detail, contains(part), reason: part);
    }
    expect(community.detail, contains(s.cphThirdPartyWarning));

    final official = capabilityInstallConfirmation(
      s,
      _docker,
      destination: 'Casa · work',
    );
    expect(official.detail, contains('Casa · work'));
    expect(official.detail, isNot(contains(s.cphThirdPartyWarning)));
  });
}

/// Answers "running" for the action status until [released] returns true.

const _gitMcp = CapabilityItem(
  kind: CapabilityKind.mcp,
  id: 'mcp:catalog:docs',
  name: 'docs',
  source: 'official',
  trust: CapabilityTrust.official,
  installId: 'docs',
  installedName: 'docs',
  transport: 'stdio',
  command: 'node dist/index.js',
  env: [
    CapabilityEnvField(name: 'DOCS_KEY', prompt: 'API key for the docs host'),
    CapabilityEnvField(name: 'DOCS_REGION', required: false),
  ],
  requirements: ['DOCS_KEY', 'DOCS_REGION'],
  disclosure: CapabilityDisclosure(
    installUrl: 'https://git.example.test/labs/docs-mcp',
    installRef: 'v1.0.0',
    bootstrap: ['npm ci', 'npm run build'],
    authType: 'api_key',
  ),
);

class _GatedRest extends ScriptedRest {
  final ScriptedRest inner;
  final bool Function() released;

  _GatedRest(this.inner, this.released);

  @override
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic>? body,
    Duration? timeout,
  }) => inner.post(endpoint, body: body, timeout: timeout);

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    if (endpoint.startsWith('actions/')) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return released()
          ? {'name': 'install-docker', 'running': false, 'exit_code': 0}
          : {'name': 'install-docker', 'running': true};
    }
    return inner.get(endpoint);
  }
}
