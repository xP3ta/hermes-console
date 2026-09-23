import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/session_row_stop_control.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

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
  String? lastUserPreview,
  String? lastAssistantPreview,
}) => {
  'id': id,
  '_lineage_root_id': id,
  'title': title,
  'preview': preview,
  'last_user_preview': ?lastUserPreview,
  'last_assistant_preview': ?lastAssistantPreview,
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

class _HomeActivityClient extends ApiClient {
  _HomeActivityClient({List<Session>? sessions})
    : sessions =
          sessions ??
          [
            Session(
              id: 'background-1',
              title: 'Informe prolongado',
              model: 'hermes-agent',
              source: 'mobile',
              messageCount: 2,
              isActive: false,
              preview: 'Proceso iniciado',
              startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
            ),
          ],
      super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'gateway-key',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );

  List<Session> sessions;
  int sessionReads = 0;

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
  }) async {
    sessionReads += 1;
    return sessions;
  }

  @override
  void close() {}
}

class _ProcessActivityGateway
    implements HermesDesktopGateway, HermesDesktopControlGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  AgentCenterSnapshot snapshot = const AgentCenterSnapshot(
    snapshots: [],
    processes: [
      BackgroundProcessEntry(
        opaqueId: 'process-1',
        status: AgentCenterStatus.running,
        uptimeSeconds: 3,
      ),
    ],
  );

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-$storedSessionId',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<AgentCenterSnapshot> agentCenterSnapshot({
    String runtimeSessionId = '',
  }) async => snapshot;

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: 'runtime-background-1',
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() => _events.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
    List<Map<String, dynamic>> rows, {
    ActiveChatService? activeChats,
  }) async {
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
          activeChatsOverride: activeChats,
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

  testWidgets(
    'la lista nunca muestra JSON de tools y recupera el último texto humano',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const rawToolCall = '[{"id":"call_latest","type":"function"}]';
      await pump(tester, [
        _row(
          'tool-preview',
          title: 'Deploy a staging',
          lastActive: nowSeconds(),
          preview: rawToolCall,
          lastUserPreview: 'Comprueba el despliegue',
          lastAssistantPreview: rawToolCall,
        ),
        _row(
          'tool-only-preview',
          title: 'Tarea automatizada',
          lastActive: nowSeconds() - 1,
          preview: rawToolCall,
          lastAssistantPreview: rawToolCall,
        ),
      ]);
      await _pumpUntil(tester, find.text('Deploy a staging'));

      expect(find.text(rawToolCall), findsNothing);
      expect(find.text('Comprueba el despliegue'), findsOneWidget);
      expect(find.text('Sin mensajes visibles'), findsOneWidget);
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
    'el proceso de fondo conserva la actividad tras acabar el turno',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final gateway = _ProcessActivityGateway();
      final activeChats = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(activeChats.dispose);
      addTearDown(gateway.close);
      final chat = activeChats.attach(
        connection: _connection(),
        sessionId: 'background-1',
        sessionTitle: 'Informe prolongado',
        desktopGateway: gateway,
        disableForegroundKeepAlive: true,
      )..smoothStreaming = false;
      expect(
        await chat.send(
          fullText: 'genera el informe',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      await chat.refreshBackgroundProcessesForTesting();
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit('message.complete', const {'text': 'proceso iniciado'});
      await done.timeout(const Duration(seconds: 1));

      await pump(
        tester,
        [
          _row(
            'background-1',
            title: 'Informe prolongado',
            lastActive: nowSeconds(),
          ),
        ],
        activeChats: activeChats,
      );
      await _pumpUntil(tester, find.text('Informe prolongado'));

      final strings = Strings.of(tester.element(find.byType(SessionListScreen)));
      expect(find.text(strings.chaBackgroundActivityCount(1)), findsOneWidget);
      expect(
        find.byKey(const ValueKey('session-running-background-1')),
        findsOneWidget,
      );

      gateway.snapshot = const AgentCenterSnapshot(
        snapshots: [],
        processes: [
          BackgroundProcessEntry(
            opaqueId: 'process-1',
            status: AgentCenterStatus.completed,
            uptimeSeconds: 4,
          ),
        ],
      );
      await chat.refreshBackgroundProcessesForTesting();
      expect(chat.hasActiveBackgroundProcesses, isFalse);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text(strings.slActivityBackground), findsNothing);
      expect(find.text(strings.chaBackgroundActivityCount(1)), findsNothing);
      expect(
        find.byKey(const ValueKey('session-running-background-1')),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets(
    'una compactación sin turno enciende la fila con "Compactando" y sin '
    'Detener',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // A /compress restored after a restart that the gateway's replay ring
      // positively reports as still running: display-only "Compactando".
      final store = CompressionRestoreStore(storage: _MemoryRestoreStorage());
      await store.save(
        CompressionRestoreRecord(
          connectionId: _connection().id,
          profile: 'default',
          storedSessionId: 'compacting-1',
          runtimeId: 'runtime-compacting-1',
          startedAtMs: DateTime.now().millisecondsSinceEpoch - 20000,
        ),
      );
      final activeChats = ActiveChatService(compressionRestoreStore: store);
      addTearDown(activeChats.dispose);
      final chat = activeChats.attach(
        connection: _connection(),
        sessionId: 'compacting-1',
        sessionTitle: 'Sesión compactando',
        desktopGateway: _RunningCompressionGateway(),
        disableForegroundKeepAlive: true,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(chat.desktopRestoredCompressionRunning, isTrue);
      expect(chat.desktopManualCompressionInFlight, isFalse);
      expect(chat.sessionActivity.active, isFalse);

      await pump(
        tester,
        [
          _row(
            'compacting-1',
            title: 'Sesión compactando',
            lastActive: nowSeconds(),
          ),
        ],
        activeChats: activeChats,
      );
      await _pumpUntil(tester, find.text('Sesión compactando'));

      final strings = Strings.of(tester.element(find.byType(SessionListScreen)));
      expect(
        find.byKey(const ValueKey('session-running-compacting-1')),
        findsOneWidget,
      );
      expect(find.text(strings.slActivityCompacting), findsOneWidget);
      expect(find.byType(SessionRowStopControl), findsNothing);
      activeChats.dispose();
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets(
    'inicio pinta el roster frío por id durable, nunca por título',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      await manager.saveConnection(
        'Redesign QA',
        '127.0.0.1',
        8642,
        'gateway-key',
        kind: InstanceKind.vps,
      );
      final connection = manager.getConnections().single;
      final aggregate = GlobalActivityAggregate.inMemory();
      final activeChats = ActiveChatService(
        globalActivity: aggregate,
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(activeChats.dispose);
      final generation = aggregate.beginRosterRequest(
        connection.id,
        'default',
      );
      aggregate.applyRoster(
        connectionId: connection.id,
        profile: 'default',
        replayEpoch: 'cold-start',
        requestGeneration: generation,
        roster: const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-busy-row',
              storedSessionId: 'busy-row',
              status: 'working',
            ),
          ],
        ),
      );
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      final client = _HomeActivityClient(
        sessions: [
          Session(
            id: 'busy-row',
            title: 'Título repetido',
            model: 'hermes-agent',
            source: 'mobile',
            messageCount: 2,
            isActive: false,
            preview: 'Fila ocupada',
            startedAt: now,
          ),
          Session(
            id: 'idle-row',
            title: 'Título repetido',
            model: 'hermes-agent',
            source: 'mobile',
            messageCount: 2,
            isActive: false,
            preview: 'Fila inactiva',
            startedAt: now - 1,
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: HomeDashboardScreen(
            connManager: manager,
            clientFactory: (_) => client,
            activeChatsOverride: activeChats,
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Título repetido'));

      expect(
        find.byKey(const ValueKey('home-activity-busy-row')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-activity-idle-row')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets(
    'inicio hidrata active_list y exige dos ausencias antes de quedar inactivo',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      await manager.saveConnection(
        'Redesign QA',
        '127.0.0.1',
        8642,
        'gateway-key',
        kind: InstanceKind.vps,
      );
      final connection = manager.getConnections().single;
      final activeChats = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(activeChats.dispose);
      final events = StreamController<TuiGatewayEvent>.broadcast();
      addTearDown(events.close);
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      Session row(String preview, double activityAt) => Session(
        id: 'cold-running',
        title: 'Trabajo recuperado',
        model: 'hermes-agent',
        source: 'mobile',
        messageCount: 2,
        isActive: false,
        preview: preview,
        startedAt: activityAt,
      );
      final client = _HomeActivityClient(
        sessions: [row('Vista previa anterior', now)],
      );
      var roster = const DesktopActiveSessionList(
        sessions: [
          DesktopActiveSession(
            runtimeSessionId: 'runtime-cold-running',
            storedSessionId: 'cold-running',
            status: 'working',
          ),
        ],
      );
      var rosterReads = 0;
      var failRoster = false;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: HomeDashboardScreen(
            connManager: manager,
            clientFactory: (_) => client,
            activeChatsOverride: activeChats,
            activeSessionListLoader: () async {
              rosterReads += 1;
              if (failRoster) throw StateError('roster unavailable');
              return roster;
            },
            eventStreamOverride: events.stream,
          ),
        ),
      );
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('home-activity-cold-running')),
      );
      expect(rosterReads, greaterThanOrEqualTo(1));
      final initialRosterReads = rosterReads;
      final initialSessionReads = client.sessionReads;

      client.sessions = [row('Vista previa actualizada', now + 60)];
      roster = const DesktopActiveSessionList();
      events.add(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      );
      for (
        var attempt = 0;
        attempt < 40 && rosterReads < initialRosterReads + 1;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(client.sessionReads, greaterThan(initialSessionReads));
      expect(
        find.byKey(const ValueKey('home-activity-cold-running')),
        findsOneWidget,
      );

      failRoster = true;
      events.add(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      );
      await tester.pump(sessionLibraryRefreshGap);
      for (
        var attempt = 0;
        attempt < 40 && rosterReads < initialRosterReads + 2;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(
        activeChats.globalActivity
            .activityFor(connection.id, 'default', 'cold-running')
            ?.stale,
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('home-activity-cold-running')),
        findsOneWidget,
      );

      failRoster = false;
      events.add(
        const TuiGatewayEvent(
          type: 'sessions.changed',
          sessionId: '',
          payload: {},
        ),
      );
      await tester.pump(sessionLibraryRefreshGap);
      for (
        var attempt = 0;
        attempt < 40 && rosterReads < initialRosterReads + 3;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(rosterReads, greaterThanOrEqualTo(initialRosterReads + 3));
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.byKey(const ValueKey('home-activity-cold-running')),
        findsNothing,
      );
      expect(find.text('Vista previa actualizada'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets(
    'inicio conserva el proceso de fondo tras acabar el turno',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      await manager.saveConnection(
        'Redesign QA',
        '127.0.0.1',
        8642,
        'gateway-key',
        kind: InstanceKind.vps,
      );
      final connection = manager.getConnections().single;
      final gateway = _ProcessActivityGateway();
      final activeChats = ActiveChatService(
        compressionRestoreStore: testCompressionRestoreStore(),
      );
      addTearDown(activeChats.dispose);
      addTearDown(gateway.close);
      final chat = activeChats.attach(
        connection: connection,
        sessionId: 'background-1',
        sessionTitle: 'Informe prolongado',
        desktopGateway: gateway,
        disableForegroundKeepAlive: true,
      )..smoothStreaming = false;
      expect(
        await chat.send(
          fullText: 'genera el informe',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      await chat.refreshBackgroundProcessesForTesting();
      final done = chat.changes.firstWhere(
        (event) => event == ActiveChatEvent.done,
      );
      gateway.emit('message.complete', const {'text': 'proceso iniciado'});
      await done.timeout(const Duration(seconds: 1));
      activeChats.globalActivity.applyRoster(
        connectionId: connection.id,
        profile: 'default',
        replayEpoch: 'current',
        requestGeneration: activeChats.globalActivity.beginRosterRequest(
          connection.id,
          'default',
        ),
        roster: const DesktopActiveSessionList(
          sessions: [
            DesktopActiveSession(
              runtimeSessionId: 'runtime-background-1',
              storedSessionId: 'background-1',
              status: 'working',
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: HomeDashboardScreen(
            connManager: manager,
            clientFactory: (_) => _HomeActivityClient(),
            activeChatsOverride: activeChats,
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Informe prolongado'));

      final strings = Strings.of(
        tester.element(find.byType(HomeDashboardScreen)),
      );
      expect(find.text(strings.chaBackgroundActivityCount(1)), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-activity-background-1')),
        findsOneWidget,
      );

      gateway.snapshot = const AgentCenterSnapshot(
        snapshots: [],
        processes: [
          BackgroundProcessEntry(
            opaqueId: 'process-1',
            status: AgentCenterStatus.completed,
            uptimeSeconds: 4,
          ),
        ],
      );
      await chat.refreshBackgroundProcessesForTesting();
      expect(chat.hasActiveBackgroundProcesses, isFalse);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text(strings.slActivityBackground), findsNothing);
      expect(find.text(strings.chaBackgroundActivityCount(1)), findsNothing);
      expect(find.text(strings.chaPipelineThinking), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-activity-background-1')),
        findsOneWidget,
      );

      for (var probe = 0; probe < 2; probe++) {
        activeChats.globalActivity.applyRoster(
          connectionId: connection.id,
          profile: 'default',
          replayEpoch: 'current',
          requestGeneration: activeChats.globalActivity.beginRosterRequest(
            connection.id,
            'default',
          ),
          roster: const DesktopActiveSessionList(),
        );
      }
      expect(
        activeChats.globalActivity.activityFor(
          connection.id,
          'default',
          'background-1',
        ),
        isNull,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.byKey(const ValueKey('home-activity-background-1')),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets(
    'el punto en vivo no deja una animación colgada con movimiento reducido',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
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
              _row('live-1', title: 'Migrar tests de pagos', lastActive: 2),
              _row('live-2', title: 'Migrar tests de pagos', lastActive: 1),
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
            data: const MediaQueryData(
              disableAnimations: true,
              textScaler: TextScaler.linear(2),
            ),
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
      expect(
        find.byKey(const ValueKey('session-row-stop')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-running-live-2')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

final class _RunningCompressionGateway extends _ProcessActivityGateway
    implements HermesDesktopCompressionStatusGateway {
  @override
  Future<Map<String, dynamic>> compressionEventReplay(
    String runtimeSessionId,
  ) async => {
    'events': [
      {
        'type': 'status.update',
        'payload': {'kind': 'compressing', 'text': 'compressing 38 messages'},
      },
    ],
    'latest_seq': 1,
    'truncated': false,
  };
}

final class _MemoryRestoreStorage implements CompressionRestoreStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

