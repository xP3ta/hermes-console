import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// El dock flotante se pinta como overlay sobre el cuerpo de la pantalla y no
/// reserva hueco por sí mismo. Ajustes no aplicaba ninguna reserva, así que su
/// última sección ("Acerca de") quedaba tapada por la barra en el dispositivo.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final controller = DockPreferencesController.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  tearDown(() async {
    // El controlador es un singleton de proceso: se devuelve al valor por
    // defecto para no filtrar estado entre tests.
    await controller.setUseDock(true);
  });

  testWidgets('con dock se reserva su alto más el inset seguro del sistema', (
    tester,
  ) async {
    double? withDock;
    double? withoutDock;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        home: MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(bottom: 24)),
          child: Builder(
            builder: (context) {
              withDock = dockScrollReservation(context, useDock: true);
              withoutDock = dockScrollReservation(context, useDock: false);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    // 48 (barra) + 12 (separación del borde) + 6 (lift "Flotante") + 24
    // (inset seguro) + 16 (aire).
    expect(withDock, 106);
    // Sin dock no debe quedar un hueco muerto al final de la lista.
    expect(withoutDock, 0);
  });

  testWidgets('Ajustes reserva hueco para el dock y lo suelta al apagarlo', (
    tester,
  ) async {
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final connection = SavedConnection(
      id: 'dock-reservation-qa',
      label: 'QA',
      host: '127.0.0.1',
      port: 8642,
      apiKey: '',
    );
    await controller.ensureLoaded();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SettingsScreen(connection: connection, connManager: manager),
      ),
    );
    await tester.pump();

    double bottomPadding() {
      final view = tester.widget<ListView>(find.byType(ListView).first);
      return view.padding!.resolve(TextDirection.ltr).bottom;
    }

    // Con el dock encendido la lista deja sitio para la barra.
    expect(bottomPadding(), greaterThanOrEqualTo(66));

    await controller.setUseDock(false);
    await tester.pump();
    expect(bottomPadding(), 0);
  });
}
