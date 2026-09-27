import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}) async {
  await setPhone(tester);
  await tester.pumpWidget(
    spanishApp(
      CapabilityDetailScreen(
        item: item,
        repository: repoOf(rest),
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
