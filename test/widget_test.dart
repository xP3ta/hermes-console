// Smoke tests de las pantallas principales: comprueban que renderizan sin
// lanzar excepciones, con mocks mínimos (SharedPreferences en memoria + un
// ConnectionManager real sin instancias guardadas).
//
// No se monta `HermesApp` completo a propósito: su `initState` arranca
// notificaciones, foreground task, secure storage y voz (canales de plugin que
// no existen en el entorno de test). Estas pantallas se prueban de forma
// aislada porque no dependen de `HermesAppState` para renderizar su árbol base.
//
// Nota: `OnboardingScreen` tiene una animación `repeat()` (glow de fondo) que
// nunca se asienta; por eso aquí se usa `pump()` con duración fija y nunca
// `pumpAndSettle()`.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/screens/onboarding/connect_chooser_screen.dart';
import 'package:hermes_android/core/screens/onboarding/server_setup_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Envuelve la pantalla bajo test con el tema y la localización que necesita
/// (`Strings.of(context)`), forzando español para poder afirmar sobre textos.
Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  locale: const Locale('es'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: textScale == 1
      ? null
      : (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
  home: child,
);

class _EmptyHomeClient extends ApiClient {
  _EmptyHomeClient()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient(
          (_) async => throw StateError('unexpected HTTP'),
        ),
      );

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<List<Session>> getSessions({bool includeChildren = false}) async => [
    Session(
      id: 'mob-aux-voice-old-session',
      title: 'Internal voice session',
      source: 'mobile',
      model: 'hermes-agent',
      messageCount: 1,
      isActive: false,
      preview: '',
      startedAt: 1,
    ),
    Session(
      id: 'cron_daily_summary_20260801_090000',
      title: 'Informe cron interno',
      source: 'cron',
      model: 'hermes-agent',
      messageCount: 1,
      isActive: false,
      preview: 'Resultado programado',
      startedAt: 2,
    ),
  ].where((session) => !session.id.startsWith('mob-aux-')).toList();

  @override
  void close() {}
}

class _DeferredHomeClient extends ApiClient {
  _DeferredHomeClient()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient(
          (_) async => throw StateError('unexpected HTTP'),
        ),
      );

  final Completer<bool> health = Completer<bool>();

  @override
  Future<bool> healthCheck() => health.future;

  @override
  Future<List<Session>> getSessions({bool includeChildren = false}) async => [
    Session(
      id: 'chat-loaded',
      title: 'Conversación cargada',
      source: 'mobile',
      model: 'hermes-agent',
      messageCount: 2,
      isActive: false,
      preview: 'Contenido disponible',
      startedAt: 1,
    ),
  ];

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ConnectionManager> emptyManager() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return ConnectionManager.create(prefs);
  }

  group('HomeDashboardScreen', () {
    testWidgets('renderiza el estado vacío cuando no hay instancias', (
      tester,
    ) async {
      final manager = await emptyManager();
      await tester.pumpWidget(_host(HomeDashboardScreen(connManager: manager)));
      // _reload() es asíncrono; deja que termine y que la animación de entrada
      // (TweenAnimationBuilder, finita) se asiente.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // Sin instancias guardadas y sin red: aparece el onboarding vacío.
      expect(find.text('▸ sin instancias configuradas'), findsOneWidget);
      expect(find.text('agregar instancia'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('la barra superior muestra el título de la consola', (
      tester,
    ) async {
      final manager = await emptyManager();
      await tester.pumpWidget(_host(HomeDashboardScreen(connManager: manager)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // La pantalla principal tiene su AppBar y el título por defecto.
      expect(find.byType(HermesAppBar), findsOneWidget);
      expect(find.text('HERMES CONSOLE'), findsOneWidget);
    });

    testWidgets(
      'mantiene una carga limpia hasta resolver las conversaciones iniciales',
      (tester) async {
        final secureValues = <String, String>{};
        const secureChannel = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage',
        );
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(secureChannel, (call) async {
              final args = call.arguments is Map
                  ? Map<Object?, Object?>.from(call.arguments as Map)
                  : const <Object?, Object?>{};
              switch (call.method) {
                case 'write':
                  secureValues[args['key'] as String] = args['value'] as String;
                  return null;
                case 'read':
                  return secureValues[args['key']];
                case 'readAll':
                  return Map<String, String>.of(secureValues);
                case 'delete':
                  secureValues.remove(args['key']);
                  return null;
              }
              return null;
            });
        addTearDown(
          () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(secureChannel, null),
        );

        final manager = await emptyManager();
        await manager.saveConnection(
          'QA',
          '127.0.0.1',
          8642,
          'test-key',
          kind: InstanceKind.vps,
        );
        final client = _DeferredHomeClient();
        var initialLoadSignals = 0;
        final initialLoadProgress = <double>[];

        await tester.pumpWidget(
          _host(
            HomeDashboardScreen(
              connManager: manager,
              clientFactory: (_) => client,
              onInitialLoadProgress: initialLoadProgress.add,
              onInitialLoadComplete: () => initialLoadSignals++,
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('home-initial-loading')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('home-empty-conversations')),
          findsNothing,
        );
        expect(find.text('Nuevo chat'), findsNothing);
        expect(initialLoadSignals, 0);

        client.health.complete(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.byKey(const ValueKey('home-initial-loading')),
          findsNothing,
        );
        expect(find.text('Conversación cargada'), findsOneWidget);
        expect(initialLoadSignals, 1);
        expect(initialLoadProgress, isNotEmpty);
        expect(initialLoadProgress.last, 1);
        expect(
          initialLoadProgress,
          orderedEquals(initialLoadProgress.toList()..sort()),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'una instancia sana con solo sesiones auxiliares muestra un vacío útil',
      (tester) async {
        final secureValues = <String, String>{};
        const secureChannel = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage',
        );
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(secureChannel, (call) async {
              final args = call.arguments is Map
                  ? Map<Object?, Object?>.from(call.arguments as Map)
                  : const <Object?, Object?>{};
              switch (call.method) {
                case 'write':
                  secureValues[args['key'] as String] = args['value'] as String;
                  return null;
                case 'read':
                  return secureValues[args['key']];
                case 'readAll':
                  return Map<String, String>.of(secureValues);
                case 'delete':
                  secureValues.remove(args['key']);
                  return null;
              }
              return null;
            });
        addTearDown(
          () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(secureChannel, null),
        );

        final manager = await emptyManager();
        await manager.saveConnection(
          'QA',
          '127.0.0.1',
          8642,
          'test-key',
          kind: InstanceKind.vps,
        );

        await tester.pumpWidget(
          _host(
            HomeDashboardScreen(
              connManager: manager,
              clientFactory: (_) => _EmptyHomeClient(),
            ),
            textScale: 2,
          ),
        );
        for (var attempt = 0; attempt < 40; attempt++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (find
              .byKey(const ValueKey('home-empty-conversations'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.byKey(const ValueKey('home-empty-conversations')),
          findsOneWidget,
        );
        expect(find.text('Aún no hay conversaciones'), findsOneWidget);
        expect(find.text('Nuevo chat'), findsNothing);
        final emptyState = find.byKey(
          const ValueKey('home-empty-conversations'),
        );
        expect(
          find.descendant(of: emptyState, matching: find.byType(Icon)),
          findsNothing,
        );
        expect(
          find.descendant(of: emptyState, matching: find.byType(FilledButton)),
          findsNothing,
        );
        expect(find.text('Internal voice session'), findsNothing);
        expect(find.text('Informe cron interno'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('OnboardingScreen', () {
    testWidgets('renderiza la primera página y los controles de navegación', (
      tester,
    ) async {
      final manager = await emptyManager();
      await tester.pumpWidget(
        _host(OnboardingScreen(connManager: manager, onDone: () {})),
      );
      // El glow de fondo usa repeat(): NO usar pumpAndSettle (no se asienta).
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Hermes Console'), findsOneWidget);
      expect(find.text('Saltar'), findsOneWidget);
      // Botón de avance (aún no es la última página).
      expect(find.text('Siguiente'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('"Saltar" invoca onDone', (tester) async {
      final manager = await emptyManager();
      var done = false;
      await tester.pumpWidget(
        _host(
          OnboardingScreen(connManager: manager, onDone: () => done = true),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text('Saltar'));
      await tester.pump();

      expect(done, isTrue);
    });

    testWidgets('no desborda en viewport horizontal con fuente al 200 %', (
      tester,
    ) async {
      // 1280x800 físicos a 240 dpi en el laboratorio Android equivalen a
      // ~853x533 puntos lógicos para Flutter.
      await tester.binding.setSurfaceSize(const Size(853, 533));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final manager = await emptyManager();

      await tester.pumpWidget(
        _host(
          OnboardingScreen(connManager: manager, onDone: () {}),
          textScale: 2,
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Hermes Console'), findsOneWidget);
      expect(find.text('Siguiente'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Remote onboarding', () {
    testWidgets('empieza con QR o preparar servidor, sin preguntas técnicas', (
      tester,
    ) async {
      final manager = await emptyManager();
      await tester.pumpWidget(
        _host(ConnectChooserScreen(connManager: manager)),
      );
      await tester.pump();

      expect(find.text('¿Cómo quieres conectar?'), findsOneWidget);
      expect(find.text('Escanear QR'), findsOneWidget);
      expect(find.text('Preparar servidor'), findsOneWidget);
      expect(find.text('¿Ya tienes Hermes Agent?'), findsNothing);
      expect(find.text('¿Está preparado para el móvil?'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('preparar va directo a elegir sistema, copiar y escanear', (
      tester,
    ) async {
      final manager = await emptyManager();
      await tester.pumpWidget(
        _host(ConnectChooserScreen(connManager: manager)),
      );
      await tester.pump();

      await tester.ensureVisible(find.text('Preparar servidor'));
      await tester.tap(find.text('Preparar servidor'));
      await tester.pumpAndSettle();

      expect(find.byType(ServerSetupScreen), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -260));
      await tester.pump();
      expect(find.text('Linux / Termux'), findsOneWidget);
      expect(find.text('Windows / WSL2'), findsOneWidget);
      expect(find.text('¿Cómo accedes a Hermes?'), findsNothing);

      final linuxOption = find.widgetWithText(ChoiceChip, 'Linux / Termux');
      await tester.ensureVisible(linuxOption);
      await tester.pumpAndSettle();
      await tester.tap(linuxOption);
      await tester.pumpAndSettle();

      expect(tester.widget<ChoiceChip>(linuxOption).selected, isTrue);
      final pageScroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Copia para una terminal de confianza'),
        160,
        scrollable: pageScroll,
      );
      expect(find.text('Copia para una terminal de confianza'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('hermes-mobile-setup.sh'),
        240,
        scrollable: pageScroll,
      );
      expect(find.textContaining('hermes-mobile-setup.sh'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Ya veo el QR · abrir cámara'),
        240,
        scrollable: pageScroll,
      );
      expect(find.text('Ya veo el QR · abrir cámara'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('mostrar QR explica el comando antes de abrir la cámara', (
      tester,
    ) async {
      final manager = await emptyManager();
      await tester.pumpWidget(
        _host(
          ServerSetupScreen(connManager: manager, mode: ServerSetupMode.showQr),
        ),
      );
      await tester.pump();

      expect(find.text('Mostrar mi QR'), findsOneWidget);
      expect(find.text('Linux / Termux'), findsOneWidget);
      expect(find.text('Windows / WSL2'), findsOneWidget);
      expect(find.textContaining('hermes-pair.sh'), findsNothing);

      await tester.tap(find.text('Linux / Termux'));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -420));
      await tester.pump();

      expect(find.text('Ya veo el QR · abrir cámara'), findsOneWidget);
      expect(find.textContaining('hermes-pair.sh'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('mostrar QR ofrece PowerShell en Windows', (tester) async {
      final manager = await emptyManager();
      await tester.pumpWidget(
        _host(
          ServerSetupScreen(connManager: manager, mode: ServerSetupMode.showQr),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Windows / WSL2'));
      await tester.pump();

      expect(find.textContaining('fuera de WSL'), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -620));
      await tester.pump();

      expect(find.textContaining('hermes-pair.ps1'), findsOneWidget);
      expect(find.textContaining('| iex'), findsOneWidget);
      expect(find.textContaining('hermes-pair.sh'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
