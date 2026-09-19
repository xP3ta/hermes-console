import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'shell-widget',
  label: 'Shell QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-only',
);

Widget _host(ConnectionManager manager) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  // Ruta inicial ("Inicio"): sin dock, solo un botón para navegar a la
  // subpantalla que sí lo lleva (GeneralDockShell), igual que en la app
  // real (p.ej. Inicio → Ajustes).
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const ValueKey('open-subscreen'),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => Scaffold(
                body: GeneralDockShell(
                  connection: _connection,
                  connManager: manager,
                  body: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'GeneralDockShell shows Back as soon as it is pushed as a subscreen',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );

      await tester.pumpWidget(_host(manager));
      await tester.pumpAndSettle();

      // Antes de navegar no hay dock alguno en la pantalla raíz: nada que
      // confundir con "Atrás" todavía.
      expect(
        find.byKey(const ValueKey('general-mode-dock-back')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('open-subscreen')));
      await tester.pumpAndSettle();

      // La regresión real (confirmada en dispositivo): "Atrás" se calculaba
      // sobre si algo se apilaba ENCIMA de esta pantalla (siempre false al
      // entrar), no sobre si esta pantalla es en sí misma una subpantalla.
      // Con el fix debe aparecer de inmediato, sin necesidad de empujar una
      // tercera ruta encima.
      expect(
        find.byKey(const ValueKey('general-mode-dock-back')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('general-mode-dock-back')));
      await tester.pumpAndSettle();

      // El botón realmente hace pop: se vuelve a ver la pantalla raíz.
      expect(
        find.byKey(const ValueKey('open-subscreen')),
        findsOneWidget,
      );
    },
  );
}
