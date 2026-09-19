// Interruptor global "Usar dock flotante" (Ajustes › apariencia): activado
// por defecto, apaga el dock flotante en toda la app cuando el usuario lo
// desactiva. Estos tests cubren las dos mitades del requisito:
//
//  1. Con el interruptor apagado, `GeneralDockShell` (mecanismo compartido
//     por Cron/Tareas/Herramientas/Ajustes/Sesiones) no pinta ningún dock.
//  2. La app sigue siendo 100% funcional sin él: el FAB nativo de Cron (que
//     normalmente se oculta cuando el dock reemplaza su acción de crear)
//     debe reaparecer y seguir funcionando cuando el dock está apagado,
//     aunque la pantalla siga teniendo un `ConnectionManager` (condición que
//     antes, por sí sola, ocultaba el FAB para siempre — bug confirmado).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _connection = SavedConnection(
  id: 'dock-toggle-qa',
  label: 'Dock toggle QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-only',
  useHttps: true,
);

Widget _shellHost(ConnectionManager manager) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: Scaffold(
    body: GeneralDockShell(
      connection: _connection,
      connManager: manager,
      body: const SizedBox.expand(key: ValueKey('shell-body')),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final controller = DockPreferencesController.instance;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() async {
    // El controlador es un singleton de proceso: se devuelve al estado por
    // defecto (dock activado) para no filtrar estado entre tests de este
    // mismo archivo.
    await controller.setUseDock(true);
  });

  group('GeneralDockShell honors the global "use dock" switch', () {
    testWidgets('paints the dock when the switch is on (default)', (
      tester,
    ) async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await controller.ensureLoaded();
      expect(controller.value.useDock, isTrue);

      await tester.pumpWidget(_shellHost(manager));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('general-mode-floating-dock')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('shell-body')), findsOneWidget);
    });

    testWidgets(
      'paints only the body, with no dock and no empty gap, when the switch is off',
      (tester) async {
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        await controller.setUseDock(false);

        await tester.pumpWidget(_shellHost(manager));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('general-mode-floating-dock')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('general-mode-dock-create')),
          findsNothing,
        );
        // El body sigue presente, sin ningún dock ni tile de acceso rápido.
        expect(find.byKey(const ValueKey('shell-body')), findsOneWidget);
        for (final key in [
          'general-mode-dock-home',
          'general-mode-dock-bots',
          'general-mode-dock-settings',
          'general-mode-dock-back',
        ]) {
          expect(find.byKey(ValueKey(key)), findsNothing);
        }
      },
    );
  });

  // El interruptor global vivía duplicado en los dos widgets de dock que
  // había antes (`BotModeDock` y `GeneralModeDock`) más en el propio shell.
  // Ahora hay un único `Dock`, así que la guarda es una sola: se comprueba
  // que sigue valiendo también para el perfil Bots, que es el que se montaba
  // por su cuenta (Mission Control lo monta directo en su `Stack`, sin pasar
  // por `GeneralDockShell`).
  group('the Bots profile honors the same global switch', () {
    Widget botsHost() => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: Scaffold(
        body: Stack(
          children: [
            const SizedBox.expand(key: ValueKey('bots-body')),
            Dock(
              profileId: DockProfileId.bots,
              actions: const {
                DockItemId.home: DockItemAction(),
                DockItemId.bots: DockItemAction(selected: true),
                DockItemId.work: DockItemAction(),
                DockItemId.create: DockItemAction(),
              },
              createOrbits: [
                DockCreateOrbit(
                  controlKey: const ValueKey('bot-mode-create-bot'),
                  label: 'New bot',
                  icon: Icons.smart_toy_outlined,
                  onTap: () {},
                ),
              ],
            ),
          ],
        ),
      ),
    );

    testWidgets('paints the dock when the switch is on (default)', (
      tester,
    ) async {
      await controller.ensureLoaded();
      await tester.pumpWidget(botsHost());
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('bot-mode-floating-dock')),
        findsOneWidget,
      );
    });

    testWidgets('paints nothing at all when the switch is off', (tester) async {
      await controller.setUseDock(false);
      await tester.pumpWidget(botsHost());
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('bot-mode-floating-dock')),
        findsNothing,
      );
      for (final key in [
        'bot-mode-dock-home',
        'bot-mode-dock-bots',
        'bot-mode-dock-work',
        'bot-mode-dock-create',
        'bot-mode-dock-back',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing);
      }
      // La pantalla de debajo sigue entera: apagar el dock nunca quita
      // funcionalidad nativa.
      expect(find.byKey(const ValueKey('bots-body')), findsOneWidget);
    });
  });

  group('Cron stays fully usable without the dock', () {
    DashboardClient emptyCronClient() => DashboardClient(
      host: 'hermes.local',
      manualToken: 'token',
      httpClientOverride: MockClient((request) async {
        if (request.url.path == '/api/cron/jobs') {
          return http.Response('[]', 200);
        }
        if (request.url.path == '/api/cron/delivery-targets') {
          return http.Response(jsonEncode({'targets': []}), 200);
        }
        if (request.url.path == '/api/model/options') {
          return http.Response(jsonEncode({'providers': []}), 200);
        }
        if (request.url.path == '/api/cron/blueprints') {
          return http.Response(jsonEncode({'blueprints': []}), 200);
        }
        return http.Response('{}', 404);
      }),
    );

    testWidgets(
      'hides its own FAB when the dock is actually active',
      (tester) async {
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        await controller.setUseDock(true);

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            theme: AppTheme.fromId('dark'),
            home: CronScreen(
              connection: _connection,
              connManager: manager,
              clientOverride: emptyCronClient(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('general-mode-floating-dock')),
          findsOneWidget,
        );
        expect(find.byType(FloatingActionButton), findsNothing);
      },
    );

    testWidgets(
      'brings back its native FAB, fully functional, when the dock is switched off',
      (tester) async {
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        // Regresión del bug confirmado: la condición original ocultaba el
        // FAB por tener `connManager` (pantalla "compatible con dock"), no
        // por tener el dock REALMENTE presente. Con el interruptor global
        // apagado, `connManager` sigue siendo no-nulo pero ningún dock se
        // pinta — el FAB debe reaparecer para que crear un cron job siga
        // siendo posible.
        await controller.setUseDock(false);

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            theme: AppTheme.fromId('dark'),
            home: CronScreen(
              connection: _connection,
              connManager: manager,
              clientOverride: emptyCronClient(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('general-mode-floating-dock')),
          findsNothing,
        );
        final fab = find.byType(FloatingActionButton);
        expect(fab, findsOneWidget);
        // La lista vacía ya pinta su propio CTA nativo ("New task"),
        // independiente del dock — no sirve para probar que el FAB en
        // concreto funciona. Se comprueba en su lugar que tocar el FAB
        // abre de verdad el editor real (el campo de prompt del
        // formulario), no un botón decorativo. Se identifica por su key,
        // no por `Dialog`: el rediseño de Cron (feat/cron-dialogs-subagent-
        // redesign) puede envolver el mismo editor en una superficie
        // flotante en vez de un `Dialog` de Material.
        expect(find.byKey(const ValueKey('cron-prompt-field')), findsNothing);

        await tester.tap(fab);
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('cron-prompt-field')), findsOneWidget);
      },
    );
  });
}
