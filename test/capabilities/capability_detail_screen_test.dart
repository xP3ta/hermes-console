import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capability_detail_screen.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/design/hermes_design.dart';

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
  CapabilitiesRpc? rpc,
}) async {
  await setPhone(tester);
  await tester.pumpWidget(
    spanishApp(
      CapabilityDetailScreen(
        item: item,
        repository: repoOf(rest, rpc: rpc),
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

    test('installed plugin with update → update first, remove last', () {
      expect(capabilityActions(_weather, readOnly: false), [
        CapabilityAction.update,
        CapabilityAction.disable,
        CapabilityAction.remove,
      ]);
    });

    test('MCP entry that needs credentials cannot install from here', () {
      const mcp = CapabilityItem(
        kind: CapabilityKind.mcp,
        id: 'mcp:catalog:github',
        name: 'github',
        installId: 'github',
        env: [CapabilityEnvField(name: 'GITHUB_TOKEN')],
      );
      expect(capabilityActions(mcp, readOnly: false), isEmpty);
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
    expect(find.text('docker instalada'), findsOneWidget);
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
        'lines': ['Security scan: blocked, not installed'],
      });
    await _pump(tester, _docker, rest);
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();

    expect(find.text('No instalada'), findsOneWidget);
    expect(
      find.textContaining('El escaneo de seguridad bloqueó esta instalación.'),
      findsOneWidget,
    );
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
  testWidgets('MCP detail asks for the runtime status once and shows it', (
    tester,
  ) async {
    final methods = <String>[];
    await _pump(
      tester,
      CapabilityItem.mcpServer({'name': 'docs', 'transport': 'http'})!,
      populatedServer(),
      rpc: (method, params) async {
        methods.add(method);
        return {
          'servers': [
            {'name': 'docs', 'tools': 2, 'status': 'failed'},
          ],
        };
      },
    );

    expect(methods, ['mcp.servers.status']);
    expect(find.text('Con error'), findsOneWidget);
    expect(find.text('2 herramientas'), findsOneWidget);
  });

  testWidgets('non-MCP detail never asks for the runtime status', (
    tester,
  ) async {
    final methods = <String>[];
    await _pump(
      tester,
      _weather,
      populatedServer(),
      rpc: (method, params) async {
        methods.add(method);
        return {};
      },
    );
    expect(methods, isEmpty);
  });

  group('MCP logs', () {
    final stdio = CapabilityItem.mcpServer({
      'name': 'files',
      'transport': 'stdio',
      'command': 'npx',
    })!;

    ScriptedRest withLogs() => populatedServer()
      ..gets['logs'] = {
        'file': 'mcp',
        'lines': [
          "===== [10:00:05] starting MCP server 'git' =====",
          'git: cloning',
          "2026-10-04 10:01:00,000 ===== starting MCP server 'files' =====",
          'files: ready',
        ],
      };

    List<String> logReads(ScriptedRest rest) =>
        rest.calls.where((c) => c.startsWith('GET logs')).toList();

    testWidgets(
      'open reads once, shows only this server, refresh reads again',
      (tester) async {
        final rest = withLogs();
        await _pump(tester, stdio, rest);
        expect(logReads(rest), isEmpty);

        await tester.tap(find.byKey(const ValueKey('cph-logs-row')));
        await tester.pumpAndSettle();
        expect(logReads(rest), ['GET logs?file=mcp&lines=500']);
        expect(find.textContaining('files: ready'), findsOneWidget);
        expect(find.textContaining('git: cloning'), findsNothing);

        await tester.tap(find.byKey(const ValueKey('cph-logs-refresh')));
        await tester.pumpAndSettle();
        expect(logReads(rest), hasLength(2));
      },
    );

    testWidgets('the agent log is one tap away and searches by name', (
      tester,
    ) async {
      final rest = withLogs()
        ..gets['logs?file=agent&lines=300&search=files'] = {
          'file': 'agent',
          'lines': ['agent: files connected'],
        };
      await _pump(tester, stdio, rest);
      await tester.tap(find.byKey(const ValueKey('cph-logs-row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cph-logs-seg-agent')));
      await tester.pumpAndSettle();

      expect(find.textContaining('agent: files connected'), findsOneWidget);
      expect(logReads(rest).last, 'GET logs?file=agent&lines=300&search=files');
    });

    testWidgets('a server without /api/logs leaves and hides the row', (
      tester,
    ) async {
      final rest = populatedServer();
      await _pump(tester, stdio, rest);
      await tester.tap(find.byKey(const ValueKey('cph-logs-row')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('cph-logs-row')), findsNothing);
      expect(logReads(rest), hasLength(1));
    });

    testWidgets('only MCP servers have logs', (tester) async {
      await _pump(tester, _weather, withLogs());
      expect(find.byKey(const ValueKey('cph-logs-row')), findsNothing);
    });
  });
}

/// Answers "running" for the action status until [released] returns true.
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
