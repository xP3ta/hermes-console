import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/capabilities/capability_detail_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;

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
}
