// Verifica que "Mascotas" vive en el hub de Herramientas y que, SIN instancia
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

// Encuentra un item del drawer arrastrando su Scrollable hasta que aparezca:
// la cabecera de conexión más el separador que agrupa la navegación puede
// empujar entradas tardías (p. ej. "Herramientas") fuera del viewport de test.
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
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('el drawer mueve "Mascotas" al hub de Herramientas', (
    tester,
  ) async {
    final manager = await _emptyManager();
    await _pumpDrawer(tester, manager);

    await _revealDrawerItem(tester, 'Herramientas');
    expect(find.text('Herramientas'), findsOneWidget);
    expect(find.text('Mascotas'), findsNothing);

    await tester.tap(find.text('Herramientas'));
    await tester.pumpAndSettle();
    expect(find.byType(ToolsHubScreen), findsOneWidget);
    expect(find.text('Mascotas'), findsOneWidget);
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

    await _revealDrawerItem(tester, 'Herramientas');
    await tester.tap(find.text('Herramientas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mascotas'));
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
