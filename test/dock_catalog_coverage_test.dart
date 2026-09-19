// Recorre el catálogo COMPLETO (`DockItemId.values`) con todo visible, para
// cazar el tipo de bug que un catálogo pequeño no expone: un id sin acción
// real que aun así ocupa un hueco en la barra (A5 [media, MEDIDO] — `work` en
// "General" y `settings` en "Bots" contaban en `visibleItemIds` pese a
// pintarse como `SizedBox.shrink()`, estrechando el resto de items y
// alterando qué item se retira al insertar "Atrás").
//
// Desde la unificación del dock (un único `Dock` parametrizado, ver
// `widgets/dock.dart`) esa exclusión ya no es una lista negra codificada por
// perfil: un id que no aparece en el mapa `actions` que le pasa la pantalla
// simplemente no existe para ella. Estos tests verifican esa regla genérica
// en los dos perfiles.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: Scaffold(body: child),
);

/// El dock unificado construye su propio `Stack`, así que funciona igual
/// suelto o dentro de uno externo. El perfil "General" se monta en la app
/// real dentro de un `Stack` (`GeneralDockShell`/`HomeDashboardScreen`), así
/// que se prueba en esa misma disposición.
Widget _wrapInStack(Widget child) => _wrap(Stack(children: [child]));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final controller = DockPreferencesController.instance;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() async {
    await controller.resetGeneral();
    await controller.resetBots();
  });

  testWidgets(
    'General profile: every catalog item paints a real, tappable tile, '
    'except the documented no-op ("work"), which is fully excluded',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await controller.ensureLoaded();
      await controller.updateGeneral(
        (p) => p.copyWith(
          items: [for (final id in DockItemId.values) DockItemConfig(id: id)],
        ),
      );

      final taps = <DockItemId, int>{};
      DockItemAction bump(DockItemId id) =>
          DockItemAction(onTap: () => taps[id] = (taps[id] ?? 0) + 1);

      await tester.pumpWidget(
        _wrapInStack(
          Dock(
            profileId: DockProfileId.general,
            // `work` NO está en el mapa: no tiene destino propio fuera de
            // Bots.
            actions: {
              DockItemId.home: bump(DockItemId.home),
              DockItemId.create: bump(DockItemId.create),
              DockItemId.bots: bump(DockItemId.bots),
              DockItemId.settings: bump(DockItemId.settings),
              DockItemId.cron: bump(DockItemId.cron),
              DockItemId.tasks: bump(DockItemId.tasks),
              DockItemId.sessions: bump(DockItemId.sessions),
              DockItemId.tools: bump(DockItemId.tools),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      const actionable = [
        DockItemId.home,
        DockItemId.create,
        DockItemId.bots,
        DockItemId.settings,
        DockItemId.cron,
        DockItemId.tasks,
        DockItemId.sessions,
        DockItemId.tools,
      ];
      for (final id in actionable) {
        final finder = find.byKey(ValueKey('general-mode-dock-${id.name}'));
        expect(finder, findsOneWidget, reason: '$id should paint a real tile');
        await tester.tap(finder);
        await tester.pump();
        expect(
          taps[id],
          greaterThan(0),
          reason: '$id tile should trigger its real action on tap',
        );
      }

      // `work` no tiene acción propia en "General": no debe pintar NINGÚN
      // tile (ni siquiera uno inerte) que pudiera seguir contando para el
      // ancho de la barra.
      expect(
        find.byKey(const ValueKey('general-mode-dock-work')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Bots profile: every catalog item paints a real, tappable tile, '
    'except the documented no-op ("settings"), which is fully excluded',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await controller.ensureLoaded();
      await controller.updateBots(
        (p) => p.copyWith(
          items: [for (final id in DockItemId.values) DockItemConfig(id: id)],
        ),
      );

      final taps = <DockItemId, int>{};
      DockItemAction bump(DockItemId id) =>
          DockItemAction(onTap: () => taps[id] = (taps[id] ?? 0) + 1);

      await tester.pumpWidget(
        _wrap(
          Dock(
            profileId: DockProfileId.bots,
            // `settings` NO está en el mapa: el perfil Bots no ofrece un
            // destino de Ajustes propio.
            actions: {
              DockItemId.home: bump(DockItemId.home),
              DockItemId.bots: bump(DockItemId.bots),
              DockItemId.work: bump(DockItemId.work),
              DockItemId.create: const DockItemAction(),
              DockItemId.cron: bump(DockItemId.cron),
              DockItemId.tasks: bump(DockItemId.tasks),
              DockItemId.sessions: bump(DockItemId.sessions),
              DockItemId.tools: bump(DockItemId.tools),
            },
            createOrbits: const [
              DockCreateOrbit(
                controlKey: ValueKey('bot-mode-create-bot'),
                label: 'Bot',
                icon: Icons.smart_toy_outlined,
              ),
              DockCreateOrbit(
                controlKey: ValueKey('bot-mode-create-room'),
                label: 'Room',
                icon: Icons.groups_2_outlined,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // "create" abre la bandeja de dos órbitas (estado interno del propio
      // dock, no un callback directo): basta con comprobar que el toque
      // realmente la despliega.
      await tester.tap(find.byKey(const ValueKey('bot-mode-dock-create')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('bot-mode-create-actions')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('bot-mode-create-outside')));
      await tester.pumpAndSettle();

      const directAction = [
        DockItemId.home,
        DockItemId.bots,
        DockItemId.work,
        DockItemId.cron,
        DockItemId.tasks,
        DockItemId.sessions,
        DockItemId.tools,
      ];
      for (final id in directAction) {
        final finder = find.byKey(ValueKey('bot-mode-dock-${id.name}'));
        expect(finder, findsOneWidget, reason: '$id should paint a real tile');
        await tester.tap(finder);
        await tester.pump();
        expect(
          taps[id],
          greaterThan(0),
          reason: '$id tile should trigger its real action on tap',
        );
      }

      // `settings` no forma parte del catálogo de "Bots": mismo patrón
      // latente que `work` en "General" (ver A5). No debe pintar tile.
      expect(
        find.byKey(const ValueKey('bot-mode-dock-settings')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'one shared component, two independent profiles: same Dock class, but '
    'each profile keeps its own catalog, style and widget keys',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await controller.ensureLoaded();
      // Estilos deliberadamente distintos por perfil: el usuario corrigió
      // explícitamente que el estilo NO se comparte entre perfiles.
      await controller.updateBots(
        (p) => p.copyWith(
          style: const DockStyle(
            borderShape: DockBorderShape.rounded,
            depth: DockDepth.floating,
          ),
        ),
      );
      await controller.updateGeneral(
        (p) => p.copyWith(
          style: const DockStyle(
            borderShape: DockBorderShape.square,
            depth: DockDepth.flat,
          ),
        ),
      );

      await tester.pumpWidget(
        _wrap(
          Stack(
            children: [
              Dock(
                profileId: DockProfileId.bots,
                actions: const {
                  DockItemId.bots: DockItemAction(),
                  DockItemId.work: DockItemAction(),
                },
              ),
              Dock(
                profileId: DockProfileId.general,
                actions: const {
                  DockItemId.home: DockItemAction(),
                  DockItemId.settings: DockItemAction(),
                },
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Un único componente instanciado dos veces...
      expect(find.byType(Dock), findsNWidgets(2));

      // ...pero cada perfil conserva sus propias keys estables...
      expect(
        find.byKey(const ValueKey('bot-mode-floating-dock')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('general-mode-floating-dock')),
        findsOneWidget,
      );

      // ...su propio catálogo (nada de "Trabajo" en General, nada de
      // "Ajustes" en Bots)...
      expect(find.byKey(const ValueKey('bot-mode-dock-work')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('general-mode-dock-work')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('general-mode-dock-settings')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bot-mode-dock-settings')),
        findsNothing,
      );

      // ...y su propio estilo: el radio exterior de cada barra sale del
      // `DockStyle` de SU perfil, no de uno compartido.
      BorderRadius radiusOf(String key) {
        final decoration =
            tester
                    .widgetList<DecoratedBox>(
                      find.descendant(
                        of: find.byKey(ValueKey(key)),
                        matching: find.byType(DecoratedBox),
                      ),
                    )
                    .first
                    .decoration
                as BoxDecoration;
        return decoration.borderRadius! as BorderRadius;
      }

      expect(
        radiusOf('bot-mode-floating-dock').topLeft.x,
        DockBorderShape.rounded.outerRadius,
      );
      expect(
        radiusOf('general-mode-floating-dock').topLeft.x,
        DockBorderShape.square.outerRadius,
      );
    },
  );
}
