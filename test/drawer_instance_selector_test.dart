import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final demo = SavedConnection(
    id: 'demo',
    label: 'Server',
    host: '100.64.0.10',
    port: 8642,
    apiKey: '',
  );
  final secondary = SavedConnection(
    id: 'secondary',
    label: 'Secondary',
    host: '192.168.1.20',
    port: 8642,
    apiKey: '',
  );

  Future<ConnectionManager> managerWith(
    List<SavedConnection> connections,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    for (final connection in connections.reversed) {
      await manager.upsertConnection(connection);
    }
    return manager;
  }

  Future<void> pumpDrawer(
    WidgetTester tester, {
    required ConnectionManager manager,
    SavedConnection? connection,
    double textScale = 1,
  }) async {
    final scaffoldKey = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          key: scaffoldKey,
          body: const Text('Inicio'),
          drawer: HermesDrawer(
            connection: connection,
            connManager: manager,
            current: DrawerSection.home,
          ),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await tester.pumpAndSettle();
  }

  testWidgets('la cabecera cambia la instancia activa sin abrir Instancias', (
    tester,
  ) async {
    final manager = await managerWith([demo, secondary]);
    await manager.setActiveConnection(demo.id);
    await pumpDrawer(tester, manager: manager, connection: demo);

    expect(find.textContaining('Server'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('drawer-instance-option-demo')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('drawer-instance-selector')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('drawer-instance-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-instance-surface')), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);

    expect(find.byKey(const ValueKey('drawer-instance-option-demo')), findsOne);
    expect(
      find.byKey(const ValueKey('drawer-instance-option-secondary')),
      findsOne,
    );
    final drawerRect = tester.getRect(find.byType(Drawer));
    final selectorRect = tester.getRect(
      find.byKey(const ValueKey('drawer-instance-selector')),
    );
    final firstOptionRect = tester.getRect(
      find.byKey(const ValueKey('drawer-instance-option-demo')),
    );
    expect(firstOptionRect.top, greaterThanOrEqualTo(selectorRect.bottom));
    expect(firstOptionRect.left, greaterThanOrEqualTo(drawerRect.left));
    expect(firstOptionRect.right, lessThanOrEqualTo(drawerRect.right));

    await tester.tap(
      find.byKey(const ValueKey('drawer-instance-option-secondary')),
    );
    await tester.pumpAndSettle();

    expect(manager.activeConnectionId.value, secondary.id);
    expect(
      manager.prefs.getString(ConnectionManager.lastConnKey),
      secondary.id,
    );
    expect(
      find.byKey(const ValueKey('drawer-instance-option-secondary')),
      findsNothing,
    );
  });

  // QA 9491: a MenuAnchor has no route, so Back skipped it and closed what
  // was underneath. Back closes the instance menu only; the next Back closes
  // the drawer.
  testWidgets('Atrás con el selector abierto cierra solo el selector', (
    tester,
  ) async {
    final manager = await managerWith([demo, secondary]);
    await manager.setActiveConnection(demo.id);
    await pumpDrawer(tester, manager: manager, connection: demo);

    await tester.tap(find.byKey(const ValueKey('drawer-instance-selector')));
    await tester.pumpAndSettle();
    final option = find.byKey(const ValueKey('drawer-instance-option-demo'));
    expect(option, findsOne);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(option, findsNothing);
    expect(find.byType(Drawer), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
    expect(manager.activeConnectionId.value, demo.id);
  });

  testWidgets('una sola instancia sigue siendo legible con texto al 200 %', (
    tester,
  ) async {
    final manager = await managerWith([demo]);
    await manager.setActiveConnection(demo.id);
    await pumpDrawer(tester, manager: manager, connection: demo, textScale: 2);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('drawer-instance-selector')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('drawer-instance-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-instance-option-demo')), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sin conexiones la cabecera es informativa y no abre selector', (
    tester,
  ) async {
    final manager = await managerWith([]);
    await pumpDrawer(tester, manager: manager);

    await tester.tap(
      find.byKey(const ValueKey('drawer-instance-selector')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(find.text('sin instancia activa'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('drawer-instance-option-demo')),
      findsNothing,
    );
  });
}
