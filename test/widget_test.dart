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
  Future<bool> healthReachable() => healthCheck();

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => [
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
  Future<bool> healthReachable() => healthCheck();

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => [
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
      // One plain sentence and one button: no ports, no jargon.
      expect(
        find.text('Conecta Console con tu Hermes para empezar.'),
        findsOneWidget,
      );
      expect(find.text('Conectar'), findsOneWidget);
      expect(find.textContaining('8642'), findsNothing);
      expect(find.textContaining('sin instancias'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('la barra superior muestra el título de la consola', (
      tester,
    ) async {
      final manager = await emptyManager();
      await tester.pumpWidget(_host(HomeDashboardScreen(connManager: manager)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // La pantalla principal tiene su AppBar y el título por defecto:
      // «CONSOLE».
      expect(find.byType(HermesAppBar), findsOneWidget);
      expect(find.text('CONSOLE'), findsOneWidget);
      expect(find.text('HERMES CONSOLE'), findsNothing);
    });

    testWidgets(
      'mientras cargan las conversaciones Home ya está entero y solo la '
      'lista muestra un marcador en línea',
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

        await tester.pumpWidget(
          _host(
            HomeDashboardScreen(
              connManager: manager,
              clientFactory: (_) => client,
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
        // The real Home is there (no full-screen loader), only the recents
        // wait, and no false «empty» or «offline» state shows meanwhile.
        expect(find.byType(HermesAppBar), findsOneWidget);
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
              .byKey(const ValueKey('home-now-calm'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        await tester.pump(const Duration(milliseconds: 100));

        // The useful empty Home is the default widget board: Ahora says
        // all is quiet and Chats has nothing to resume; auxiliary sessions
        // are never offered.
        expect(find.byKey(const ValueKey('home-now-calm')), findsOneWidget);
        expect(find.text('Aún no hay chats'), findsOneWidget);
        expect(find.byKey(const ValueKey('home-first-chat')), findsOneWidget);
        expect(find.text('Hablar con Hermes'), findsOneWidget);
        expect(find.text('Nuevo chat'), findsNothing);
        expect(find.text('Internal voice session'), findsNothing);
        expect(find.text('Informe cron interno'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('OnboardingScreen', () {
    testWidgets('the welcome has two doors and the real Console mark', (
      tester,
    ) async {
      final manager = await emptyManager();
      await tester.pumpWidget(
        _host(OnboardingScreen(connManager: manager, onDone: () {})),
      );
      // The opening plays here (the ambient light never settles).
      await tester.pump(const Duration(milliseconds: 3000));
      expect(find.text('Conecta con tu Hermes'), findsOneWidget);
      expect(find.text('Ya tengo Hermes'), findsOneWidget);
      expect(find.text('Aún no tengo Hermes'), findsOneWidget);
      expect(find.text('Conectar a mano'), findsOneWidget);
      expect(find.text('Buscar mi Hermes'), findsNothing);
      expect(find.byKey(const ValueKey('console-mark')), findsOneWidget);
      expect(find.text('Saltar'), findsNothing);
      expect(find.byType(PageView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
