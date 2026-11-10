// The Plugin Hub: the Capabilities catalog filtered to plugins. It lists what
// the server's curated catalog publishes (there is no server-side search,
// update-check or validate route for plugins, so none is faked), installs
// through the one install route and leaves the plugin switched off.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/capabilities/capability_detail_screen.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesStatusText;
import 'package:hermes_android/core/services/command_risk.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;
import 'package:hermes_android/core/services/tui_gateway_client.dart'
    show TuiGatewayRpcError, TuiGatewayRpcFailureKind;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

Map<String, dynamic> _entry(
  String name, {
  bool installed = false,
  bool update = false,
  String status = 'enabled',
  String maintainer = 'Example Labs',
  String version = '1.2.0',
}) => {
  'name': name,
  'title': name[0].toUpperCase() + name.substring(1),
  'description': 'Description of $name',
  'tier': 'community',
  'maintainer': maintainer,
  'version': version,
  'installed': installed,
  'runtime_status': installed ? status : '',
  'update_available': update,
  'capabilities': {'provides_tools': <String>[], 'requires_env': <String>[]},
};

ScriptedRest _server(List<Map<String, dynamic>> entries) => ScriptedRest()
  ..gets['skills'] = <Object>[]
  ..gets['skills/hub/official'] = {'skills': <Object>[]}
  ..gets['dashboard/plugins/catalog'] = {'entries': entries}
  ..gets['dashboard/plugins/hub'] = {
    'plugins': [
      for (final e in entries)
        if (e['installed'] == true)
          {
            'name': e['name'],
            'runtime_status': e['runtime_status'],
            'source': 'community',
            'can_remove': true,
          },
    ],
  }
  ..gets['mcp/catalog'] = {'entries': <Object>[]}
  ..gets['mcp/servers'] = {'servers': <Object>[]};

class _GatedRest extends ScriptedRest {
  final Completer<void> readGate = Completer<void>();
  final Completer<void> postGate = Completer<void>();

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    await readGate.future;
    return super.get(endpoint);
  }

  @override
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic>? body,
    Duration? timeout,
  }) async {
    await postGate.future;
    return super.post(endpoint, body: body, timeout: timeout);
  }
}

Future<void> _pump(
  WidgetTester tester,
  ScriptedRest rest, {
  bool readOnly = false,
  CapabilitiesRpc? rpc,
  bool settle = true,
  Locale? locale,
  double textScale = 1,
}) async {
  await setPhone(tester);
  final app = MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: locale ?? const Locale('es'),
    theme: AppTheme.fromId('dark'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: CapabilitiesScreen(
      repository: repoOf(rest, rpc: rpc),
      readOnly: readOnly,
      initialSegment: CapabilitiesSegment.catalog,
      initialKind: CapabilityKind.plugin,
      searchDebounce: Duration.zero,
    ),
  );
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 844),
        textScaler: TextScaler.linear(textScale),
      ),
      child: app,
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

Finder _row(String name) =>
    find.byKey(ValueKey('cph-row-plugin:community:$name'));

void main() {
  setUpAll(loadInterFont);

  testWidgets('lists the catalog as cards with publisher, version and tier', (
    tester,
  ) async {
    final rest = _server([_entry('weather'), _entry('maps', version: '0.4.0')]);
    await _pump(tester, rest);

    expect(find.text('Plugin Hub'), findsWidgets);
    expect(find.byKey(const ValueKey('pgh-hub-intro')), findsOneWidget);
    expect(_row('weather'), findsOneWidget);
    expect(_row('maps'), findsOneWidget);
    expect(
      find.descendant(
        of: _row('weather'),
        matching: find.textContaining('Example Labs'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row('maps'), matching: find.textContaining('0.4.0')),
      findsOneWidget,
    );
    // No skills, no MCP, and the skills hub search is never asked for plugins.
    expect(find.text('SKILLS'), findsNothing);
    expect(rest.calls.where((c) => c.contains('skills/hub/search')), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading shows the loader, not an empty catalog', (tester) async {
    final rest = _GatedRest()
      ..gets['skills'] = <Object>[]
      ..gets['skills/hub/official'] = {'skills': <Object>[]}
      ..gets['dashboard/plugins/catalog'] = {
        'entries': [_entry('weather')],
      }
      ..gets['dashboard/plugins/hub'] = {'plugins': <Object>[]}
      ..gets['mcp/catalog'] = {'entries': <Object>[]}
      ..gets['mcp/servers'] = {'servers': <Object>[]};
    await _pump(tester, rest, settle: false);
    await tester.pump();
    expect(find.byKey(const ValueKey('cph-loading')), findsOneWidget);
    expect(find.byKey(const ValueKey('pgh-no-catalog')), findsNothing);
    rest.readGate.complete();
    await tester.pumpAndSettle();
    expect(_row('weather'), findsOneWidget);
  });

  testWidgets('a server that fails everything shows the error and retry', (
    tester,
  ) async {
    await _pump(tester, ScriptedRest());
    expect(find.byKey(const ValueKey('cph-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('cph-retry')), findsOneWidget);
  });

  testWidgets('a server without a catalog says so instead of inventing one', (
    tester,
  ) async {
    final rest = _server([]);
    rest.gets.remove('dashboard/plugins/catalog');
    await _pump(tester, rest);
    expect(find.byKey(const ValueKey('pgh-no-catalog')), findsOneWidget);
    expect(find.text('Sin catálogo de plugins'), findsOneWidget);
    expect(find.byKey(const ValueKey('pgh-updates')), findsNothing);
  });

  testWidgets('an empty published catalog is the same honest state', (
    tester,
  ) async {
    await _pump(tester, _server([]));
    expect(find.byKey(const ValueKey('pgh-no-catalog')), findsOneWidget);
  });

  testWidgets('a failed catalog read warns and offers a retry', (tester) async {
    final rest = _server([]);
    rest.gets['dashboard/plugins/catalog'] = const DashboardHttpException(500);
    await _pump(tester, rest);
    expect(find.byKey(const ValueKey('cph-partial')), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('search is local over the catalog', (tester) async {
    final rest = _server([_entry('weather'), _entry('maps')]);
    await _pump(tester, rest);
    await tester.enterText(find.byKey(const ValueKey('cph-search')), 'wea');
    await tester.pumpAndSettle();
    expect(_row('weather'), findsOneWidget);
    expect(_row('maps'), findsNothing);
    expect(rest.calls.where((c) => c.contains('skills/hub/search')), isEmpty);

    await tester.enterText(find.byKey(const ValueKey('cph-search')), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cph-empty-catalog')), findsOneWidget);
  });

  testWidgets('updates are grouped first; installed ones say so', (
    tester,
  ) async {
    final rest = _server([
      _entry('weather', installed: true, update: true),
      _entry('maps', installed: true),
      _entry('notes', installed: true, status: 'disabled'),
      _entry('todo'),
    ]);
    await _pump(tester, rest);

    final updates = find.byKey(const ValueKey('pgh-updates'));
    expect(
      find.descendant(of: updates, matching: _row('weather')),
      findsOneWidget,
    );
    expect(find.descendant(of: updates, matching: _row('maps')), findsNothing);
    expect(
      find.descendant(of: _row('weather'), matching: find.text('Actualizable')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row('maps'), matching: find.text('Instalada')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row('notes'), matching: find.text('Desactivada')),
      findsOneWidget,
    );
    // Not installed: no status at all.
    expect(
      find.descendant(
        of: _row('todo'),
        matching: find.byType(HermesStatusText),
      ),
      findsNothing,
    );
  });

  testWidgets('installing sends enable:false, shows progress, lands off', (
    tester,
  ) async {
    final rest = _GatedRest()
      ..gets['skills'] = <Object>[]
      ..gets['skills/hub/official'] = {'skills': <Object>[]}
      ..gets['dashboard/plugins/catalog'] = {
        'entries': [_entry('weather')],
      }
      ..gets['dashboard/plugins/hub'] = {'plugins': <Object>[]}
      ..gets['mcp/catalog'] = {'entries': <Object>[]}
      ..gets['mcp/servers'] = {'servers': <Object>[]}
      ..posts['dashboard/agent-plugins/install'] = {'ok': true};
    rest.readGate.complete();
    await _pump(tester, rest);

    await tester.tap(_row('weather'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // One blocking call, no stream: an indeterminate progress surface.
    expect(find.byKey(const ValueKey('cph-progress')), findsOneWidget);
    expect(find.textContaining('Instalando Weather'), findsOneWidget);

    rest.postGate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cph-progress')), findsNothing);
    expect(rest.mutations, ['POST dashboard/agent-plugins/install']);
    expect(rest.bodies.last, {
      'identifier': '',
      'catalog_name': 'weather',
      'force': false,
      'enable': false,
    });
    expect(find.textContaining('Instalado desactivado'), findsOneWidget);
    // Installed, and not switched on by the install.
    expect(find.byKey(const ValueKey('cph-primary')), findsNothing);
  });

  testWidgets('a scan block leaves everything as it was and never forces', (
    tester,
  ) async {
    final rest = _server([_entry('weather')])
      ..posts['dashboard/agent-plugins/install'] = {
        'ok': false,
        'scan_blocked': true,
        'scan_verdict': 'dangerous',
        'scan_findings': [
          {
            'severity': 'high',
            'description': 'curl piped to shell',
            'file': 'install.sh',
            'line': 3,
          },
        ],
      };
    await _pump(tester, rest);
    await tester.tap(_row('weather'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();

    expect(rest.mutations, ['POST dashboard/agent-plugins/install']);
    expect(rest.bodies.last!['force'], isFalse);
    expect(
      find.textContaining('El escaneo de seguridad bloqueó este plugin'),
      findsOneWidget,
    );
    expect(find.textContaining('curl piped to shell'), findsOneWidget);
    // Rolled back: still offered as not installed, still installable.
    expect(find.text('No instalada'), findsWidgets);
    expect(find.byKey(const ValueKey('cph-primary')), findsOneWidget);
  });

  testWidgets('an install with no answer in time re-reads the server', (
    tester,
  ) async {
    final rest = _server([_entry('weather')]);
    var calls = 0;
    Future<Map<String, dynamic>> rpc(
      String method,
      Map<String, dynamic> params,
    ) async {
      calls++;
      throw const TuiGatewayRpcError(
        'plugins.manage',
        'request timed out after 120s: plugins.manage',
        failureKind: TuiGatewayRpcFailureKind.timeout,
      );
    }

    await _pump(tester, rest, rpc: rpc);
    final listCalls = calls;
    await tester.tap(_row('weather'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cph-primary')));
    await tester.pumpAndSettle();

    // One attempt, never retried, and the user is told to check.
    expect(calls, listCalls + 1);
    expect(find.textContaining('No hubo respuesta a tiempo'), findsOneWidget);
    expect(rest.mutations, isEmpty);
  });

  testWidgets('read-only: cards open but nothing can be installed', (
    tester,
  ) async {
    final rest = _server([_entry('weather')]);
    await _pump(tester, rest, readOnly: true);
    await tester.tap(_row('weather'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cph-primary')), findsNothing);
    expect(rest.mutations, isEmpty);
  });

  test('installing is high risk, and so is removing a plugin', () {
    const plugin = CapabilityItem(
      kind: CapabilityKind.plugin,
      id: 'plugin:community:weather',
      name: 'Weather',
      description: '',
      source: 'community',
      trust: CapabilityTrust.community,
      installId: 'weather',
      installedName: 'weather',
    );
    expect(
      capabilityActionRisk(plugin, CapabilityAction.install),
      CommandRisk.high,
    );
    expect(
      capabilityActionRisk(plugin, CapabilityAction.remove),
      CommandRisk.high,
    );
    expect(
      capabilityActionRisk(
        plugin.copyWith(installed: true),
        CapabilityAction.update,
      ),
      CommandRisk.medium,
    );
    expect(
      capabilityActionRisk(
        plugin.copyWith(installed: true),
        CapabilityAction.enable,
      ),
      CommandRisk.low,
    );
  });

  testWidgets('the Plugins «+» opens the hub on top and back returns', (
    tester,
  ) async {
    final rest = _server([_entry('weather', installed: true)]);
    await setPhone(tester);
    await tester.pumpWidget(
      spanishApp(
        CapabilitiesScreen(
          repository: repoOf(rest),
          initialTab: ExtensionsTab.plugins,
          searchDebounce: Duration.zero,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pgh-hub-intro')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('exu-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('exu-add-plugin-hub')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pgh-hub-intro')), findsOneWidget);
    expect(find.text('Plugin Hub'), findsOneWidget); // the page title

    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pgh-hub-intro')), findsNothing);
    expect(find.byKey(const ValueKey('exu-add')), findsOneWidget);
    expect(find.text('Extensiones'), findsOneWidget);
    // Back on the same tab: the plugin is still listed there.
    expect(find.text('Weather'), findsOneWidget);
  });

  for (final locale in Strings.supportedLocales) {
    testWidgets('2x text in ${locale.languageCode}: hub fits and installs', (
      tester,
    ) async {
      final rest = _server([
        _entry('weather', installed: true, update: true),
        _entry('maps'),
      ]);
      await _pump(tester, rest, locale: locale, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('pgh-updates')), findsOneWidget);
      expect(_row('maps'), findsOneWidget);
      final empty = _server([]);
      await tester.pumpWidget(const SizedBox.shrink());
      await _pump(tester, empty, locale: locale, textScale: 2);
      expect(find.byKey(const ValueKey('pgh-no-catalog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
