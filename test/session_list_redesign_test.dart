import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Rediseño de Conversaciones (drawer › "Conversaciones").
///
/// El mockup (390×844) pide: secciones "Fijadas" / "Hoy" / "Ayer" con
/// etiqueta en mayúsculas + cuenta, UNA tarjeta redondeada por sección con las
/// filas separadas por líneas finas, punto "en vivo" pulsante para la
/// conversación que está corriendo, punto de atención para la que te necesita,
/// deslizar para "Fijar arriba" y el borrador como texto descriptivo hilado en
/// la vista previa (no una píldora de color).
const _connectionId = 'conn-redesign';

Map<String, dynamic> _row(
  String id, {
  required String title,
  required int lastActive,
  String source = 'mobile',
  String preview = '',
}) => {
  'id': id,
  '_lineage_root_id': id,
  'title': title,
  'preview': preview,
  'model': 'model-a',
  'source': source,
  'message_count': 2,
  'is_active': false,
  'started_at': lastActive - 30,
  'ended_at': lastActive - 1,
  'last_active': lastActive,
  'archived': false,
};

http.Response _page(Iterable<Map<String, dynamic>> rows) => http.Response(
  jsonEncode({
    'sessions': rows.toList(growable: false),
    'total': rows.length,
    'limit': 50,
    'offset': 0,
  }),
  200,
);

ApiClient _gateway() => ApiClient(
  baseUrl: 'http://127.0.0.1:8642',
  apiKey: 'gateway-key',
  connectionId: _connectionId,
  httpClient: MockClient((request) async {
    if (request.url.path == '/health' || request.url.path == '/api/sessions') {
      return http.Response('{}', 200);
    }
    return http.Response('{}', 404);
  }),
);

SavedConnection _connection() => SavedConnection(
  id: _connectionId,
  label: 'Redesign QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'gateway-key',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int attempts = 60,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dock = DockPreferencesController.instance;

  final secureValues = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureValues.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
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
          },
        );
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
    await dock.setUseDock(true);
  });

  /// Monta la pantalla con `rows` como biblioteca autoritativa del Dashboard.
  Future<ConnectionManager> pump(
    WidgetTester tester,
    List<Map<String, dynamic>> rows,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/sessions') {
          return _page(rows);
        }
        return http.Response('{}', 404);
      }),
    );
    final gateway = _gateway();
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SessionListScreen(
          connection: _connection(),
          connManager: manager,
          clientOverride: gateway,
          repositoryOverride: repository,
        ),
      ),
    );
    return manager;
  }

  int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  testWidgets('las secciones llevan etiqueta en mayúsculas y su cuenta', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final today = nowSeconds();
    // Un offset fijo de 26h puede caer dos días atrás si el test corre de
    // madrugada (antes de las 02:00), en vez de "ayer" — se ancla al
    // mediodía del día calendario anterior para que sea independiente de
    // la hora a la que corra la suite.
    final now = DateTime.now();
    final yesterday =
        DateTime(
          now.year,
          now.month,
          now.day - 1,
          12,
        ).millisecondsSinceEpoch ~/
        1000;
    await pump(tester, [
      _row('hoy-1', title: 'Firma del keystore en CI', lastActive: today),
      _row('hoy-2', title: 'Notas de la release', lastActive: today - 60),
      _row('ayer-1', title: 'Deploy a staging', lastActive: yesterday),
    ]);
    await _pumpUntil(tester, find.text('Firma del keystore en CI'));

    final strings = Strings.of(tester.element(find.byType(SessionListScreen)));
    expect(find.text(strings.sesDateToday.toUpperCase()), findsOneWidget);
    expect(find.text(strings.sesDateYesterday.toUpperCase()), findsOneWidget);
    // Cuenta por sección: 2 hoy, 1 ayer.
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('las fijadas van en su propia sección, antes que los días', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final today = nowSeconds();
    await pump(tester, [
      _row('hoy-1', title: 'Firma del keystore en CI', lastActive: today),
      _row('pin-1', title: 'Migrar tests de pagos', lastActive: today - 600),
    ]);
    await _pumpUntil(tester, find.text('Migrar tests de pagos'));

    final strings = Strings.of(tester.element(find.byType(SessionListScreen)));
    expect(find.text(strings.sesPinned.toUpperCase()), findsNothing);

    // Deslizar hacia la derecha fija la conversación (acción del mockup).
    await tester.drag(find.text('Migrar tests de pagos'), const Offset(400, 0));
    await tester.pumpAndSettle();

    expect(find.text(strings.sesPinned.toUpperCase()), findsOneWidget);
    final pinnedHeader = tester.getTopLeft(
      find.text(strings.sesPinned.toUpperCase()),
    );
    final todayHeader = tester.getTopLeft(
      find.text(strings.sesDateToday.toUpperCase()),
    );
    expect(pinnedHeader.dy, lessThan(todayHeader.dy));
  });

  testWidgets(
    'el borrador se hila en la vista previa en vez de una píldora de color',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final today = nowSeconds();
      await pump(tester, [
        _row(
          'draft-1',
          title: 'Notas de la release',
          lastActive: today,
          preview: 'Resume los cambios de la 1.2.10',
        ),
      ]);
      await _pumpUntil(tester, find.text('Notas de la release'));

      final prefs = await SharedPreferences.getInstance();
      await ChatDraftStore(
        prefs,
      ).save(_connectionId, 'draft-1', 'texto sin enviar', const []);
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('session-draft-draft-1')),
      );

      // La clave sigue existiendo (los tests de borradores dependen de ella),
      // pero ahora es texto descriptivo, no una píldora en mayúsculas.
      final draft = tester.widget<Text>(
        find.byKey(const ValueKey('session-draft-draft-1')),
      );
      expect(draft.data, 'Borrador · Resume los cambios de la 1.2.10');
      expect(draft.data, isNot(contains('BORRADOR')));
      // Y el texto del borrador nunca se filtra a la lista.
      expect(find.text('texto sin enviar'), findsNothing);
    },
  );

  testWidgets('deslizar a la izquierda sigue abriendo el menú de acciones', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pump(tester, [
      _row('chat-1', title: 'Deploy a staging', lastActive: nowSeconds()),
    ]);
    await _pumpUntil(tester, find.text('Deploy a staging'));

    await tester.drag(find.text('Deploy a staging'), const Offset(-400, 0));
    await tester.pumpAndSettle();

    // El menú sigue siendo la única vía a borrar/archivar/renombrar/ocultar.
    expect(
      find.byKey(const ValueKey('session-actions-surface')),
      findsOneWidget,
    );
    final strings = Strings.of(tester.element(find.byType(SessionListScreen)));
    expect(find.text(strings.slMenuDelete), findsOneWidget);
    expect(find.text(strings.slMenuArchive), findsOneWidget);
    expect(find.text(strings.slMenuRename), findsOneWidget);
  });

  testWidgets('la lista reserva hueco inferior para el dock flotante', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await dock.ensureLoaded();
    await pump(tester, [
      _row('chat-1', title: 'Deploy a staging', lastActive: nowSeconds()),
    ]);
    await _pumpUntil(tester, find.text('Deploy a staging'));

    double bottomPadding() {
      final list = tester.widget<ListView>(find.byType(ListView).first);
      return list.padding!.resolve(TextDirection.ltr).bottom;
    }

    // El dock se pinta encima de la lista: sin reserva la última conversación
    // quedaba detrás de la barra.
    expect(bottomPadding(), greaterThan(60));

    await dock.setUseDock(false);
    await tester.pump();
    // Y sin dock no debe quedar un hueco muerto.
    expect(bottomPadding(), 12);
  });

  testWidgets(
    'el punto en vivo no deja una animación colgada con movimiento reducido',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final aggregate = GlobalActivityAggregate.inMemory();
      addTearDown(aggregate.dispose);
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        port: 9119,
        manualToken: 'dashboard-token',
        httpClientOverride: MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/api/sessions') {
            return _page([
              _row('live-1', title: 'Migrar tests de pagos', lastActive: 1),
            ]);
          }
          return http.Response('{}', 404);
        }),
      );
      final gateway = _gateway();
      final repository = SessionRepository(dashboard, gateway);
      addTearDown(() {
        repository.close();
        dashboard.close();
      });

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          // Con "reducir movimiento" el anillo pulsante no debe arrancar: una
          // animación infinita aquí dejaría `pumpAndSettle` colgado y, en el
          // dispositivo, incumpliría la preferencia de accesibilidad.
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: SessionListScreen(
              connection: _connection(),
              connManager: manager,
              clientOverride: gateway,
              repositoryOverride: repository,
              globalActivityOverride: aggregate,
              activeSessionListLoader: () async =>
                  const DesktopActiveSessionList(
                    sessions: [
                      DesktopActiveSession(
                        runtimeSessionId: 'runtime-live-1',
                        storedSessionId: 'live-1',
                        status: 'working',
                      ),
                    ],
                  ),
            ),
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Migrar tests de pagos'));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('session-running-live-1')),
      );

      await tester.pumpAndSettle();
      // La actividad ocupa la línea de vista previa (estructura del mockup) y
      // se anuncia como un único nodo accesible.
      expect(find.bySemanticsLabel('trabajando'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
