// A2 [alta]: Mission Control conservaba el patrón RouteAware
// (`didPushNext`/`didPopNext`) para decidir cuándo mostrar "Atrás" en su
// dock, patrón que ya se sabía roto (solo se activa mientras la propia
// pantalla está tapada por la ruta nueva, momento en el que su dock es
// invisible) y que ya se había corregido en `GeneralDockShell`
// (`general_dock_shell_test.dart`) pero no aquí. Este test es el análogo
// para Mission Control / el perfil Bots del dock: empuja la pantalla desde una ruta
// raíz y comprueba que "Atrás" aparece de inmediato.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'mission-back-qa',
  label: 'Mission back QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-only',
);

class _EmptySource implements MissionControlDataSource {
  @override
  Future<MissionBackendSnapshot> load() async =>
      MissionBackendSnapshot(loadedAt: DateTime.fromMillisecondsSinceEpoch(0));

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;

  @override
  void close() {}
}

Widget _host(ConnectionManager manager) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  // Ruta inicial ("Inicio"): sin dock, solo un botón para navegar a la
  // subpantalla que sí lo lleva (MissionControlScreen), igual que la app
  // real (Inicio → Bots).
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const ValueKey('open-mission-control'),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MissionControlScreen(
                connection: _connection,
                connManager: manager,
                dataSource: _EmptySource(),
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
    'Mission Control shows Back as soon as it is pushed as a subscreen',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );

      await tester.pumpWidget(_host(manager));
      await tester.pumpAndSettle();

      // Antes de navegar no hay dock alguno en la pantalla raíz.
      expect(find.byKey(const ValueKey('bot-mode-dock-back')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('open-mission-control')));
      await tester.pumpAndSettle();

      // La regresión real: el criterio viejo (RouteAware) solo se activaba
      // cuando algo se apilaba ENCIMA de Mission Control, nunca al entrar
      // en sí. Con el fix (mismo criterio que `GeneralDockShell`, ver
      // `dockShowsBack` en `dock_style.dart`) debe verse de inmediato.
      expect(
        find.byKey(const ValueKey('bot-mode-dock-back')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('bot-mode-dock-back')));
      await tester.pumpAndSettle();

      // El botón realmente hace pop: se vuelve a ver la pantalla raíz.
      expect(find.byKey(const ValueKey('open-mission-control')), findsOneWidget);
    },
  );
}
