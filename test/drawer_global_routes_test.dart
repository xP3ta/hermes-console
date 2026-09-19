import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/appearance_screen.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/screens/tools_hub_screen.dart';
import 'package:hermes_android/core/screens/voice_settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'drawer-global-test',
  label: 'Drawer QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-only',
);

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

Future<void> _pumpDrawer(
  WidgetTester tester, {
  required ConnectionManager manager,
  SavedConnection? connection,
}) async {
  final scaffoldKey = GlobalKey<ScaffoldState>();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Scaffold(
        key: scaffoldKey,
        drawer: HermesDrawer(
          connection: connection,
          connManager: manager,
          current: DrawerSection.home,
        ),
      ),
    ),
  );
  scaffoldKey.currentState!.openDrawer();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder _rowSemantics(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Semantics)).first;

Future<void> _revealDrawerItem(WidgetTester tester, String label) async {
  final item = find.text(label);
  final scrollable = find
      .descendant(of: find.byType(Drawer), matching: find.byType(Scrollable))
      .first;
  for (var attempt = 0; attempt < 4 && item.evaluate().isEmpty; attempt++) {
    await tester.drag(scrollable, const Offset(0, -120));
    await tester.pump();
  }
  await tester.scrollUntilVisible(item, 80, scrollable: scrollable);
  await tester.pump();
}

void main() {
  testWidgets('Herramientas normaliza la mayúscula inicial de sus textos', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: ToolsHubScreen(
          destinations: [
            HermesToolDestination(
              id: 'lowercase-test',
              group: 'sistema',
              icon: Icons.build_outlined,
              label: 'herramienta de prueba',
              builder: (_) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );

    expect(find.text('Sistema'), findsOneWidget);
    expect(find.text('Herramienta de prueba'), findsOneWidget);
    expect(find.text('herramienta de prueba'), findsNothing);
  });

  testWidgets('el drawer conserva solo navegación cotidiana', (tester) async {
    final manager = await _manager();
    await _pumpDrawer(tester, manager: manager, connection: _connection);

    expect(find.text('Conversaciones'), findsOneWidget);
    expect(find.text('Proyectos'), findsOneWidget);
    expect(find.text('Kanban'), findsOneWidget);
    await _revealDrawerItem(tester, 'Tareas programadas');
    expect(find.text('Tareas programadas'), findsOneWidget);
    expect(find.text('Voz'), findsOneWidget);
    await _revealDrawerItem(tester, 'Herramientas');
    expect(find.text('Herramientas'), findsOneWidget);
    expect(find.text('Instancias'), findsOneWidget);
    expect(find.text('Ajustes'), findsOneWidget);

    expect(find.text('Personalización'), findsNothing);
    expect(find.text('Avanzado'), findsNothing);
    expect(find.text('Modelos'), findsNothing);
    expect(find.text('Mascotas'), findsNothing);
    expect(find.text('Registro'), findsNothing);
  });

  testWidgets('Herramientas conserva todas las rutas avanzadas', (
    tester,
  ) async {
    final manager = await _manager();
    await _pumpDrawer(tester, manager: manager, connection: _connection);

    await _revealDrawerItem(tester, 'Herramientas');
    await tester.tap(find.text('Herramientas'));
    await tester.pumpAndSettle();

    final hub = tester.widget<ToolsHubScreen>(find.byType(ToolsHubScreen));
    expect(
      hub.destinations.map((destination) => destination.id).toSet(),
      containsAll(<String>{
        'appearance',
        'mascotas',
        'instances',
        'models',
        'ssh',
        'profiles',
        'skills',
        'extensions',
        'memory',
        'cron',
        'soul',
        'task-center',
        'activity',
      }),
    );
    // 'agents' (AgentCenterScreen) se retiró: siempre se abría sin
    // runtimeSessionId desde este catálogo genérico, así que nunca podía
    // mostrar nada útil — confirmado leyendo agent_center_screen.dart, que
    // solo tiene este único call site en todo el código.
    expect(hub.destinations.map((destination) => destination.id).length, 13);
  });

  testWidgets('Voz se bloquea y Herramientas sigue accesible sin instancia', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      final manager = await _manager();
      await _pumpDrawer(tester, manager: manager);

      // Instancias/Ajustes ahora viven en un pie fijo bajo la lista (ver
      // hermes_drawer.dart), lo que le resta altura al viewport scrolleable
      // y empuja "Voz" fuera de la vista inicial en el tamaño de pantalla
      // simulado por el test — se revela igual que ya se hace con
      // "Herramientas" más abajo.
      await _revealDrawerItem(tester, 'Voz');
      expect(find.text('Voz'), findsOneWidget);
      expect(find.text('Apariencia'), findsNothing);

      final voiceNode = tester.getSemantics(_rowSemantics('Voz'));
      expect(voiceNode.flagsCollection.isEnabled, Tristate.isFalse);

      await _revealDrawerItem(tester, 'Herramientas');
      expect(find.text('Herramientas'), findsOneWidget);
      await tester.tap(find.text('Herramientas'));
      await tester.pumpAndSettle();
      expect(find.byType(ToolsHubScreen), findsOneWidget);
      expect(find.text('Apariencia'), findsOneWidget);

      final appearanceNode = tester.getSemantics(_rowSemantics('Apariencia'));
      expect(appearanceNode.flagsCollection.isEnabled, Tristate.isFalse);

      await tester.tap(find.text('Apariencia'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AppearanceScreen), findsNothing);
      expect(find.text('Configura una instancia primero'), findsOneWidget);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('Voz abre sus ajustes con una instancia real', (tester) async {
    final manager = await _manager();
    await _pumpDrawer(tester, manager: manager, connection: _connection);

    await _revealDrawerItem(tester, 'Voz');
    await tester.tap(find.text('Voz'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(VoiceSettingsScreen), findsOneWidget);
  });

  testWidgets('Cron abre la automatización oficial de la instancia', (
    tester,
  ) async {
    final manager = await _manager();
    await _pumpDrawer(tester, manager: manager, connection: _connection);

    await _revealDrawerItem(tester, 'Tareas programadas');
    await tester.tap(find.text('Tareas programadas'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final screen = tester.widget<CronScreen>(find.byType(CronScreen));
    expect(identical(screen.connection, _connection), isTrue);
  });

  testWidgets('Apariencia recibe la misma instancia activa', (tester) async {
    final manager = await _manager();
    await _pumpDrawer(tester, manager: manager, connection: _connection);

    await _revealDrawerItem(tester, 'Herramientas');
    await tester.tap(find.text('Herramientas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apariencia'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final screen = tester.widget<AppearanceScreen>(
      find.byType(AppearanceScreen),
    );
    expect(identical(screen.connection, _connection), isTrue);
  });

  testWidgets('una capacidad descartada se desactiva y explica el motivo', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      final manager = await _manager();
      await manager.saveCapabilities(
        _connection.id,
        const CapabilityMatrix(modelsRead: CapState.no),
      );
      await _pumpDrawer(tester, manager: manager, connection: _connection);

      await _revealDrawerItem(tester, 'Herramientas');
      await tester.tap(find.text('Herramientas'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('tools-search')),
        'Modelos',
      );
      await tester.pump();

      final hub = tester.widget<ToolsHubScreen>(find.byType(ToolsHubScreen));
      final models = hub.destinations.singleWhere(
        (destination) => destination.id == 'models',
      );
      expect(models.enabled, isFalse);

      final modelsNode = tester.getSemantics(
        find.byKey(const ValueKey('tool-semantics-models')),
      );
      expect(modelsNode.flagsCollection.isEnabled, Tristate.isFalse);

      await tester.tap(find.byKey(const ValueKey('tool-models')));
      await tester.pump();
      expect(
        find.text(
          'Esta función no es compatible con la instancia Hermes conectada.',
        ),
        findsOneWidget,
      );
    } finally {
      handle.dispose();
    }
  });
}
