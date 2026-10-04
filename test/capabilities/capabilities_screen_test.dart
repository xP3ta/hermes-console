import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/capabilities/capability_detail_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;
import 'package:hermes_android/core/services/tui_gateway_client.dart'
    show TuiGatewayRpcError, TuiGatewayRpcFailureKind;

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

Future<void> _pumpHub(
  WidgetTester tester,
  ScriptedRest rest, {
  bool readOnly = false,
  WidgetBuilder? advanced,
  WidgetBuilder? classic,
}) async {
  await setPhone(tester);
  await tester.pumpWidget(
    spanishApp(
      CapabilitiesScreen(
        repository: repoOf(rest),
        readOnly: readOnly,
        advancedBuilder: advanced,
        classicSkillsBuilder: classic,
        searchDebounce: Duration.zero,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadInterFont);

  testWidgets('catalog groups rows by kind with inline status', (tester) async {
    await _pumpHub(tester, populatedServer());

    expect(find.text('Capacidades'), findsOneWidget);
    expect(find.text('Catálogo'), findsOneWidget);
    expect(find.text('SKILLS'), findsOneWidget);
    expect(find.text('PLUGINS'), findsOneWidget);
    expect(find.text('arxiv'), findsOneWidget);
    expect(find.text('docker'), findsOneWidget);
    expect(find.text('Weather'), findsOneWidget);
    // Installed skill → "Instalada"; plugin with update → "Actualizable";
    // not installed → no status at all.
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey('cph-row-skill:official:official/research/arxiv'),
        ),
        matching: find.text('Instalada'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('cph-row-plugin:community:weather')),
        matching: find.text('Actualizable'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey('cph-row-skill:official:official/devops/docker'),
        ),
        matching: find.text('Instalada'),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('search filters locally and the filter menu narrows by kind', (
    tester,
  ) async {
    await _pumpHub(tester, populatedServer());

    await tester.enterText(find.byKey(const ValueKey('cph-search')), 'dock');
    await tester.pumpAndSettle();
    expect(find.text('docker'), findsOneWidget);
    expect(find.text('arxiv'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('cph-search')), '');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filtrar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cph-filter-kind-plugin')));
    await tester.pumpAndSettle();
    expect(find.text('Weather'), findsOneWidget);
    expect(find.text('docker'), findsNothing);

    await tester.tap(find.byTooltip('Filtrar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cph-filter-kind-all')));
    await tester.pumpAndSettle();
    expect(find.text('docker'), findsOneWidget);
  });

  testWidgets('installed segment lists only installed items', (tester) async {
    await _pumpHub(tester, populatedServer());
    await tester.tap(find.byKey(const ValueKey('cph-seg-installed')));
    await tester.pumpAndSettle();

    expect(find.text('arxiv'), findsOneWidget);
    expect(find.text('notes'), findsOneWidget);
    expect(find.text('Weather'), findsOneWidget);
    expect(find.text('docker'), findsNothing);
    expect(find.text('Desactivada'), findsOneWidget);
  });

  testWidgets('connectors segment shows MCP servers and an honest note', (
    tester,
  ) async {
    await _pumpHub(tester, populatedServer());
    await tester.tap(find.byKey(const ValueKey('cph-seg-connectors')));
    await tester.pumpAndSettle();

    expect(find.text('docs'), findsOneWidget);
    expect(find.text('Activa'), findsOneWidget);
    // No RPC in this repository → hosted connectors are unsupported.
    expect(
      find.text('Este servidor no ofrece conectores de cuenta.'),
      findsOneWidget,
    );
    // The filter only applies to catalog/installed.
    expect(find.byTooltip('Filtrar'), findsNothing);
  });

  testWidgets('empty server: honest empty installed state', (tester) async {
    final rest = ScriptedRest()
      ..gets['skills'] = <Object>[]
      ..gets['skills/hub/official'] = {'skills': <Object>[]};
    await _pumpHub(tester, rest);

    expect(find.byKey(const ValueKey('cph-empty-catalog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cph-seg-installed')));
    await tester.pumpAndSettle();
    expect(find.text('Aún no hay nada instalado'), findsOneWidget);
  });

  testWidgets('offline server: error state with a working retry', (
    tester,
  ) async {
    final rest = ScriptedRest();
    for (final path in const [
      'skills',
      'skills/hub/official',
      'dashboard/plugins/catalog',
      'dashboard/plugins/hub',
      'mcp/catalog',
      'mcp/servers',
    ]) {
      rest.gets[path] = const DashboardHttpException(503);
    }
    await _pumpHub(tester, rest);

    expect(find.byKey(const ValueKey('cph-error')), findsOneWidget);
    expect(find.text('No se pueden cargar las capacidades'), findsOneWidget);
    expect(
      find.text(
        'El servidor no respondió. Revisa la conexión y vuelve a intentarlo.',
      ),
      findsOneWidget,
    );

    final populated = populatedServer();
    rest.gets
      ..clear()
      ..addAll(populated.gets);
    await tester.tap(find.byKey(const ValueKey('cph-retry')));
    await tester.pumpAndSettle();
    expect(find.text('arxiv'), findsOneWidget);
  });

  testWidgets('a failing source shows a partial notice, not an error', (
    tester,
  ) async {
    final rest = populatedServer()
      ..gets['dashboard/plugins/catalog'] = const DashboardHttpException(500);
    await _pumpHub(tester, rest);
    expect(find.byKey(const ValueKey('cph-partial')), findsOneWidget);
    expect(find.text('arxiv'), findsOneWidget);
  });

  testWidgets('read-only: notice, no update-skills entry, detail fenced', (
    tester,
  ) async {
    final rest = populatedServer();
    await _pumpHub(
      tester,
      rest,
      readOnly: true,
      advanced: (_) => const Scaffold(body: Text('advanced-screen')),
    );

    expect(find.byKey(const ValueKey('cph-readonly')), findsOneWidget);
    await tester.tap(find.byTooltip('Más opciones'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cph-menu-update-skills')), findsNothing);
    expect(find.byKey(const ValueKey('cph-menu-advanced')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cph-menu-advanced')));
    await tester.pumpAndSettle();
    expect(find.text('advanced-screen'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('docker'));
    await tester.pumpAndSettle();
    expect(find.byType(CapabilityDetailScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('cph-primary')), findsNothing);
    expect(find.byKey(const ValueKey('cph-detail-readonly')), findsOneWidget);
    expect(rest.mutations, isEmpty);
  });

  testWidgets('menu opens the classic skills screen', (tester) async {
    await _pumpHub(
      tester,
      populatedServer(),
      classic: (_) => const Scaffold(body: Text('classic-screen')),
    );
    await tester.tap(find.byTooltip('Más opciones'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('cph-menu-update-skills')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('cph-menu-classic')));
    await tester.pumpAndSettle();
    expect(find.text('classic-screen'), findsOneWidget);
  });

  testWidgets('update skills runs the server action and reloads', (
    tester,
  ) async {
    final rest = populatedServer()
      ..posts['skills/hub/update'] = {'ok': true, 'name': 'skills-update'}
      ..statusQueue.addAll([
        {
          'name': 'skills-update',
          'running': true,
          'lines': ['checking'],
        },
        {'name': 'skills-update', 'running': false, 'exit_code': 0},
      ]);
    await _pumpHub(tester, rest);
    await tester.tap(find.byTooltip('Más opciones'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cph-menu-update-skills')));
    await tester.pumpAndSettle();

    expect(rest.mutations, ['POST skills/hub/update']);
    expect(find.text('Skills actualizadas'), findsOneWidget);
    expect(find.byKey(const ValueKey('cph-progress')), findsNothing);
  });

  test('installed state of a plugin comes from the hub profile', () async {
    // The REST catalog flags `installed` for the server's launch profile; the
    // hub is on `work`, where plugins.manage list says nothing is installed.
    final rest = populatedServer();
    final repo = CapabilitiesRepository(
      rest: rest,
      profile: 'work',
      rpc: (method, params) async => {'plugins': <Object>[]},
    );
    final snapshot = await CapabilitiesSnapshot.load(repo);
    final weather = snapshot.catalog.firstWhere(
      (i) => i.installId == 'weather',
    );
    expect(weather.installed, isFalse);
    expect(weather.updateAvailable, isFalse);
    expect(snapshot.installed.where((i) => i.installId == 'weather'), isEmpty);
  });

  test(
    'plugins.manage list matches by catalog_name and carries the update',
    () async {
      final repo = CapabilitiesRepository(
        rest: populatedServer(),
        profile: 'work',
        rpc: (method, params) async => {
          'plugins': [
            {
              'name': 'wx',
              'catalog_name': 'weather',
              'status': 'disabled',
              'update_available': true,
            },
          ],
        },
      );
      final snapshot = await CapabilitiesSnapshot.load(repo);
      final weather = snapshot.catalog.firstWhere(
        (i) => i.installId == 'weather',
      );
      expect(weather.installed, isTrue);
      expect(weather.enabled, isFalse);
      expect(weather.updateAvailable, isTrue);
      expect(weather.installedName, 'wx');
    },
  );

  group('a named profile never borrows the launch profile flags', () {
    // REST says Weather is installed (server launch profile); the hub is on
    // `work` and plugins.manage list is down or missing.
    for (final failure in <String, Object>{
      'timeout': const TuiGatewayRpcError(
        'plugins.manage',
        'timed out',
        failureKind: TuiGatewayRpcFailureKind.timeout,
      ),
      'forbidden': const TuiGatewayRpcError('plugins.manage', 'denied'),
      'unsupported': const TuiGatewayRpcError(
        'plugins.manage',
        'nope',
        code: -32601,
      ),
    }.entries) {
      test('${failure.key}: not installed, and the hub says so', () async {
        final repo = CapabilitiesRepository(
          rest: populatedServer(),
          profile: 'work',
          rpc: (method, params) async => throw failure.value,
        );
        final snapshot = await CapabilitiesSnapshot.load(repo);
        final weather = snapshot.catalog.firstWhere(
          (i) => i.installId == 'weather',
        );
        expect(weather.installed, isFalse);
        expect(weather.updateAvailable, isFalse);
        expect(snapshot.partial, isTrue);
      });
    }

    test('the default profile keeps the REST flags without a notice', () async {
      final repo = CapabilitiesRepository(
        rest: populatedServer(),
        rpc: (method, params) async =>
            throw const TuiGatewayRpcError('plugins.manage', 'x', code: -32601),
      );
      final snapshot = await CapabilitiesSnapshot.load(repo);
      final weather = snapshot.catalog.firstWhere(
        (i) => i.installId == 'weather',
      );
      expect(weather.installed, isTrue);
      expect(snapshot.partial, isFalse);
    });
  });

  test('plugin rows keep the canonical key through the snapshot', () async {
    final rest = populatedServer();
    rest.gets['dashboard/plugins/catalog'] = {
      'entries': [
        {'name': 'fal', 'tier': 'official'},
      ],
    };
    final repo = CapabilitiesRepository(
      rest: rest,
      profile: 'work',
      rpc: (method, params) async => {
        'plugins': [
          {'name': 'fal', 'key': 'image_gen/fal', 'catalog_name': 'fal'},
        ],
      },
    );
    final snapshot = await CapabilitiesSnapshot.load(repo);
    final fal = snapshot.catalog.firstWhere((i) => i.installId == 'fal');
    expect(fal.installedKey, 'image_gen/fal');
  });
}
