// Verifica que "Mascotas" vive en Ajustes de la app y que, SIN instancia
// configurada, queda bloqueada como el resto de apartados.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/companion/mascotas_screen.dart';
import 'package:hermes_android/core/screens/tools_hub_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('es'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: child,
);

Future<ConnectionManager> _emptyManager() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ConnectionManager.create(prefs);
}

Future<GlobalKey<ScaffoldState>> _pumpDrawer(
  WidgetTester tester,
  ConnectionManager manager, {
  SavedConnection? connection,
  bool settle = true,
}) async {
  final key = GlobalKey<ScaffoldState>();
  await tester.pumpWidget(
    _host(
      Scaffold(
        key: key,
        drawer: HermesDrawer(
          connection: connection,
          connManager: manager,
          current: DrawerSection.home,
        ),
        body: const SizedBox.expand(),
      ),
    ),
  );
  key.currentState!.openDrawer();
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
  return key;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('el drawer lleva "Mascotas y personajes" a Ajustes de la app', (
    tester,
  ) async {
    final manager = await _emptyManager();
    await _pumpDrawer(tester, manager);

    expect(find.text('Ajustes'), findsOneWidget);
    expect(find.text('Mascotas y personajes'), findsNothing);

    await tester.tap(find.text('Ajustes'));
    await tester.pumpAndSettle();
    expect(find.byType(ToolsHubScreen), findsOneWidget);
    expect(find.text('Mascotas y personajes'), findsOneWidget);
  });

  testWidgets('el scroll del drawer usa clamping local sin rebote', (
    tester,
  ) async {
    final manager = await _emptyManager();
    await _pumpDrawer(tester, manager);

    final list = tester.widget<ListView>(find.byType(ListView).first);
    expect(list.physics, isA<ClampingScrollPhysics>());
    expect(list.physics!.parent, isA<AlwaysScrollableScrollPhysics>());
  });

  testWidgets('sin instancia, pulsar "Mascotas" NO abre MascotasScreen', (
    tester,
  ) async {
    final manager = await _emptyManager();
    await _pumpDrawer(tester, manager);

    await tester.tap(find.text('Ajustes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mascotas y personajes'));
    await tester.pumpAndSettle();

    // Bloqueado: no navega a la pantalla (como el resto de apartados).
    expect(find.byType(MascotasScreen), findsNothing);
  });

  testWidgets('recientes con instancia leen Localizations tras initState', (
    tester,
  ) async {
    final manager = await _emptyManager();
    final connection = SavedConnection(
      id: 'drawer-local-test',
      label: 'Local test',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-only',
      kind: InstanceKind.localhost,
      onDeviceLoopback: true,
    );

    await _pumpDrawer(tester, manager, connection: connection, settle: false);

    expect(tester.takeException(), isNull);
    expect(find.byType(HermesDrawer), findsOneWidget);
  });
}
