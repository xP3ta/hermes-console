import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/edges.dart';
import 'package:hermes_android/core/design/tokens.dart'
    show HermesGel, HermesRadius;
import 'package:hermes_android/core/widgets/session_status_tone.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/session_row_stop_control.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/box_edge_probe.dart';
import 'support/in_memory_compression_restore_storage.dart';
import 'support/home_chat_finders.dart';
import 'support/test_api_client.dart';

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

ApiClient _gateway() => testApiClient(
  baseUrl: 'http://127.0.0.1:8642',
  connectionId: _connectionId,
  httpClient: MockClient((request) async {
    if (request.url.path == '/api/status' ||
        request.url.path == '/api/sessions') {
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
        profileDashboard: testDashboardClient(
          baseUrl: 'http://127.0.0.1:8642',
          httpClient: MockClient((_) async => http.Response('{}', 200)),
        ),
      );

  List<Session> sessions;
  int sessionReads = 0;

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
  useRecentsHomeBoard();
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
    DateTime Function()? clock,
    Future<void>? sessionsGate,
    Future<void> Function()? readGate,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/sessions') {
          if (sessionsGate != null) await sessionsGate;
          if (readGate != null) await readGate();
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
          clockOverride: clock,
        ),
      ),
    );
    return manager;
  }

  int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // T3-A (Ola 7, AUDITORIA-PULIDO §4.2): while the list first loads, the
  // shape of its rows in their cards, static, read as «Cargando…»; then
  // the rows.
  // Flicker audit P1: a refresh over a list that already has rows never
  // swaps them for the skeleton (nor unmounts the RefreshIndicator).
  testWidgets('refresh with rows on screen: no skeleton, the rows stay', (
    tester,
  ) async {
    Completer<void>? hold;
    var reads = 0;
    await pump(
      tester,
      [_row('fila-viva', title: 'Fila viva', lastActive: 1)],
      readGate: () async {
        reads++;
        await hold?.future;
      },
    );
    const skeleton = ValueKey('session-list-skeleton');
    await _pumpUntil(tester, find.text('Fila viva'));
    final before = reads;

    hold = Completer<void>();
    final pull = tester.state<RefreshIndicatorState>(
      find.byType(RefreshIndicator).first,
    );
    unawaited(pull.show());
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(skeleton), findsNothing);
      expect(find.text('Fila viva'), findsOneWidget);
      expect(find.byType(RefreshIndicator), findsWidgets);
    }
    expect(reads, greaterThan(before));

    hold.complete();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(skeleton), findsNothing);
    expect(find.text('Fila viva'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first load: a static skeleton of rows, then the rows', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final gate = Completer<void>();
    await pump(tester, [
      _row('tras-esqueleto', title: 'Tras el esqueleto', lastActive: 1),
    ], sessionsGate: gate.future);
    const skeleton = ValueKey('session-list-skeleton');
    await _pumpUntil(tester, find.byKey(skeleton));
    expect(
      tester.getSemantics(find.byKey(skeleton)),
      isSemantics(label: 'Cargando…', isLiveRegion: true),
    );
    // Static: nothing in it moves by itself (a shimmer is an animated
    // builder, a loader a progress indicator). The rows' own cards are a
    // Material, which only animates when it changes.
    bool movesByItself(Widget w) {
      if (w is AnimatedWidget || w is ProgressIndicator) return true;
      return w is TweenAnimationBuilder;
    }

    expect(
      find.descendant(
        of: find.byKey(skeleton),
        matching: find.byWidgetPredicate(movesByItself),
      ),
      findsNothing,
    );
    expect(find.text('Cargando…'), findsNothing);

    gate.complete();
    await _pumpUntil(tester, find.text('Tras el esqueleto'));
    expect(find.byKey(skeleton), findsNothing);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  // the owner (gint72): no state dot of colour in a title pill. The connection
  // is said with the name, in words, to a screen reader.
  testWidgets('the header says «Conversaciones» and its day count: no '
      'dot of colour; the connection is said in words', (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 10, 14, 12, 0);
    await pump(tester, [
      _row(
        'hoy-1',
        title: 'Firma del keystore en CI',
        lastActive: now.millisecondsSinceEpoch ~/ 1000,
      ),
    ], clock: () => now);
    await _pumpUntil(tester, find.text('Firma del keystore en CI'));

    final pill = find.byWidgetPredicate(
      (w) =>
          w.key == const ValueKey('hermes-app-bar-title') ||
          w.key == const ValueKey('hermes-app-bar-plain-title'),
    );
    final name = find.descendant(
      of: pill,
      matching: find.text('Conversaciones'),
    );
    expect(name, findsOneWidget);
    expect(
      find.byKey(const ValueKey('session-list-connection-dot')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: pill,
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).shape == BoxShape.circle,
        ),
      ),
      findsNothing,
      reason: 'no dot of any kind in the title pill',
    );
    // The name and, under it, the day's count (mock «Chats», «1 hoy»); the
    // instance's name is not repeated anywhere in the header.
    expect(
      find.descendant(of: pill, matching: find.byType(Text)),
      findsNWidgets(2),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('session-list-subtitle')))
          .data,
      '1 hoy',
    );
    expect(find.text('Redesign QA'), findsNothing);
    expect(tester.getSize(pill).height, lessThanOrEqualTo(44));
    // The state is said, whichever it is at this moment.
    final strings = Strings.of(tester.element(pill));
    expect(
      tester.getSemantics(name).label,
      anyOf(
        contains(strings.hwServerOnline),
        contains(strings.hwServerOffline),
        contains(strings.hwServerChecking),
      ),
    );
    handle.dispose();
  });

  testWidgets('el título lleva su subtítulo y cada fila el sprite de su bot', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime(2026, 10, 14, 12, 0);
    final today = now.millisecondsSinceEpoch ~/ 1000;
    final yesterday = DateTime(2026, 10, 13, 12).millisecondsSinceEpoch ~/ 1000;
    await pump(tester, [
      _row('hoy-1', title: 'Firma del keystore en CI', lastActive: today),
      _row('hoy-2', title: 'Notas de la release', lastActive: today - 60),
      _row('ayer-1', title: 'Deploy a staging', lastActive: yesterday),
    ], clock: () => now);
    await _pumpUntil(tester, find.text('Firma del keystore en CI'));

    // Nothing is running: only «2 hoy», under the title.
    final subtitle = find.byKey(const ValueKey('session-list-subtitle'));
    expect(tester.widget<Text>(subtitle).data, '2 hoy');
    expect(
      tester.getRect(subtitle).top,
      greaterThanOrEqualTo(
        tester.getRect(find.text('Conversaciones')).bottom - 1,
      ),
    );
    // Every row starts with its bot's sprite (the default bot's, here).
    expect(
      find.byKey(const ValueKey('profile-face-default')),
      findsNWidgets(3),
    );
  });

  testWidgets('la fila de bots cambia el perfil activo y se calla con uno', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => BotRosterRegistry.shared.forget(_connectionId));

    AgentProfile bot(String name, {bool isDefault = false}) =>
        AgentProfile.fromJson({
          'name': name,
          'path': '/home/u/.hermes/profiles/$name',
          'is_default': isDefault,
        });

    final now = DateTime(2026, 10, 14, 12, 0);
    final today = now.millisecondsSinceEpoch ~/ 1000;
    BotRosterRegistry.shared.publish(_connectionId, 'QA', [
      bot('default', isDefault: true),
    ]);
    final manager = await pump(tester, [
      _row('hoy-1', title: 'Firma del keystore en CI', lastActive: today),
    ], clock: () => now);
    await _pumpUntil(tester, find.text('Firma del keystore en CI'));
    expect(find.byKey(const ValueKey('session-bot-filter')), findsNothing);

    BotRosterRegistry.shared.publish(_connectionId, 'QA', [
      bot('default', isDefault: true),
      bot('ana'),
    ]);
    await tester.pump();
    expect(find.byKey(const ValueKey('session-bot-filter')), findsOneWidget);
    expect(find.text('ana'), findsOneWidget);
    // The filter row sits between the search field and the tabs.
    expect(
      tester.getRect(find.byKey(const ValueKey('session-bot-filter'))).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const ValueKey('session-filter-all'))).top,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('session-bot-filter-ana')));
    await tester.pump();
    expect(manager.activeProfileFor(_connectionId), 'ana');
  });

  testWidgets('la fila de bots llama al perfil principal por su nombre real, '
      'como la lista de Bots, y «Hermes» solo sin nombre', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => BotRosterRegistry.shared.forget(_connectionId));

    AgentProfile bot(
      String name, {
      bool isDefault = false,
      String? title,
      String? display,
    }) => AgentProfile.fromJson({
      'name': name,
      'path': '/home/u/.hermes/profiles/$name',
      'is_default': isDefault,
      'display_name': ?display,
      if (title != null)
        'ui_meta': {
          'hermes-bots': {'title': title},
        },
    });

    final now = DateTime(2026, 10, 14, 12, 0);
    final today = now.millisecondsSinceEpoch ~/ 1000;
    BotRosterRegistry.shared.publish(_connectionId, 'QA', [
      bot('default', isDefault: true, title: 'xPeta', display: 'Hermes'),
      bot('ana'),
    ]);
    await pump(tester, [
      _row('hoy-1', title: 'Firma del keystore en CI', lastActive: today),
    ], clock: () => now);
    await _pumpUntil(tester, find.text('Firma del keystore en CI'));
    final row = find.byKey(const ValueKey('session-bot-filter'));
    expect(
      find.descendant(of: row, matching: find.text('xPeta')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('Hermes')),
      findsNothing,
    );
    // A secondary profile keeps its own name.
    expect(
      find.descendant(of: row, matching: find.text('ana')),
      findsOneWidget,
    );

    BotRosterRegistry.shared.publish(_connectionId, 'QA', [
      bot('default', isDefault: true),
      bot('ana'),
    ]);
    await tester.pump();
    expect(
      find.descendant(of: row, matching: find.text('Hermes')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('xPeta')),
      findsNothing,
    );
    expect(
      find.descendant(of: row, matching: find.text('ana')),
      findsOneWidget,
    );
  });

  testWidgets('las secciones llevan etiqueta en mayúsculas y su cuenta', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // The sections follow the human day (04:00 rollover), so the test fixes
    // the clock instead of depending on the hour the suite runs at.
    final now = DateTime(2026, 10, 14, 12, 0);
    final today = now.millisecondsSinceEpoch ~/ 1000;
    final yesterday = DateTime(2026, 10, 13, 12).millisecondsSinceEpoch ~/ 1000;
    await pump(tester, [
      _row('hoy-1', title: 'Firma del keystore en CI', lastActive: today),
      _row('hoy-2', title: 'Notas de la release', lastActive: today - 60),
      _row('ayer-1', title: 'Deploy a staging', lastActive: yesterday),
    ], clock: () => now);
    await _pumpUntil(tester, find.text('Firma del keystore en CI'));

    final strings = Strings.of(tester.element(find.byType(SessionListScreen)));
    expect(find.text(strings.sesDateToday.toUpperCase()), findsOneWidget);
    expect(find.text(strings.sesDateYesterday.toUpperCase()), findsOneWidget);
    // Cuenta por sección: 2 hoy, 1 ayer.
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    // Section label in small caps on the left, its count on the right edge,
    // in the quiet tone (no « · » joining them any more).
    expect(find.text(' · '), findsNothing);
    final label = tester.widget<Text>(
      find.text(strings.sesDateToday.toUpperCase()),
    );
    final colors = Theme.of(
      tester.element(find.byType(SessionListScreen)),
    ).hermes;
    expect(label.style!.color, colors.textTertiary);
    final todayLabel = tester.getRect(
      find.text(strings.sesDateToday.toUpperCase()),
    );
    expect(
      tester.getRect(find.text('2')).center.dy,
      closeTo(todayLabel.center.dy, 1),
    );
    expect(
      tester.getRect(find.text('2')).left,
      greaterThan(todayLabel.right),
      reason: 'the count closes the line, on the right of the label',
    );
    // «Archivo» sits in the header with a 48 dp target, not on a row of its
    // own under the filters.
    final archive = find.byKey(const ValueKey('session-filter-archived'));
    expect(archive, findsOneWidget);
    expect(tester.getSize(archive).height, greaterThanOrEqualTo(48));
    expect(
      tester.getRect(archive).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const ValueKey('session-filter-all'))).top,
      ),
    );
    // TalkBack (REVIEW-T2-A C1): a button a double tap activates, and it
    // says when the archive is on.
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(
      tester.getSemantics(archive),
      isSemantics(
        label: strings.slFilterArchived,
        isButton: true,
        hasTapAction: true,
        isSelected: false,
      ),
    );
    final node = tester.getSemantics(archive);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pump();
    expect(tester.getSemantics(archive), isSemantics(isSelected: true));
    semantics.dispose();
  });

  testWidgets(
    'a rename or archive made on another screen repaints the list at once',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final today = nowSeconds();
      final manager = await pump(tester, [
        _row('keep-1', title: 'Firma del keystore en CI', lastActive: today),
        _row('arch-1', title: 'Notas de la release', lastActive: today - 60),
      ]);
      await _pumpUntil(tester, find.text('Notas de la release'));
      await tester.pumpAndSettle();

      // Home / chat auto-title write through the same per-connection store.
      final other = await SessionArchive.load(manager.prefs, _connectionId);
      await other.setTitle('keep-1', 'Renombrada en Inicio');
      await tester.pump();
      expect(find.text('Renombrada en Inicio'), findsOneWidget);
      expect(find.text('Firma del keystore en CI'), findsNothing);

      await other.archive('arch-1');
      await tester.pump();
      expect(find.text('Notas de la release'), findsNothing);
      expect(find.text('Renombrada en Inicio'), findsOneWidget);
    },
  );

  testWidgets('cada conversación es una píldora propia: radio, borde y aire '
      'entre filas', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime(2026, 10, 14, 12, 0);
    final today = now.millisecondsSinceEpoch ~/ 1000;
    await pump(tester, [
      _row('hoy-1', title: 'Firma del keystore en CI', lastActive: today),
      _row('hoy-2', title: 'Notas de la release', lastActive: today - 60),
    ], clock: () => now);
    await _pumpUntil(tester, find.text('Firma del keystore en CI'));

    BoxDecoration pillOf(String title) {
      final box = find
          .ancestor(
            of: find.text(title),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).borderRadius ==
                      BorderRadius.circular(HermesRadius.card),
            ),
          )
          .first;
      return tester.widget<DecoratedBox>(box).decoration as BoxDecoration;
    }

    // Each row has its own rounded body and the finish of a box: a contour
    // in two tones (lighter on top), the light of the top edge, the shade of
    // the bottom one and the short compact shadow, all painted (no blur over
    // the text).
    for (final title in ['Firma del keystore en CI', 'Notas de la release']) {
      final decoration = pillOf(title);
      expect(decoration.color, isNotNull, reason: title);
      final boxes = boxEdgesAround(find.text(title));
      expect(boxes, findsOneWidget, reason: title);
      final edge = edgeOf(tester, boxes);
      final under = ThemeContrast.composite(
        decoration.color!,
        const Color(0xFF202020),
      );
      expect(
        ThemeContrast.luminance(ThemeContrast.composite(edge.top, under)),
        greaterThan(
          ThemeContrast.luminance(ThemeContrast.composite(edge.bottom, under)),
        ),
        reason: title,
      );
      final shadow = shadowOf(tester, boxes)!;
      expect(shadow.blur, HermesGel.boxShadowCompactBlur, reason: title);
      expect(shadow.drop, HermesGel.boxShadowCompactDrop, reason: title);
      expect(shadow.color.a, greaterThan(0), reason: title);
    }
    // Two pills, not one joined card: the air between them.
    final first = tester.getRect(
      find
          .ancestor(
            of: find.text('Firma del keystore en CI'),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).borderRadius ==
                      BorderRadius.circular(HermesRadius.card),
            ),
          )
          .first,
    );
    final second = tester.getRect(
      find
          .ancestor(
            of: find.text('Notas de la release'),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).borderRadius ==
                      BorderRadius.circular(HermesRadius.card),
            ),
          )
          .first,
    );
    expect(second.top - first.bottom, greaterThanOrEqualTo(6));
    expect(find.byType(Divider), findsNothing);
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
    'rebuilds without a list change reuse the filtered view, and pin/unpin '
    'still regroup it',
    (tester) async {
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
      await tester.pumpAndSettle();
      final strings = Strings.of(
        tester.element(find.byType(SessionListScreen)),
      );

      final passes = SessionListScreen.debugFilterPasses;
      for (var i = 0; i < 3; i++) {
        tester.element(find.byType(SessionListScreen)).markNeedsBuild();
        await tester.pump();
      }
      expect(SessionListScreen.debugFilterPasses, passes);

      await tester.drag(
        find.text('Migrar tests de pagos'),
        const Offset(400, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text(strings.sesPinned.toUpperCase()), findsOneWidget);
      expect(SessionListScreen.debugFilterPasses, greaterThan(passes));

      await tester.drag(
        find.text('Migrar tests de pagos'),
        const Offset(400, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text(strings.sesPinned.toUpperCase()), findsNothing);
    },
  );

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
    'la lista nunca muestra JSON de tools ni inventa otra vista previa',
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
      // As the Desktop sidebar: only the row's own preview, never the last
      // turn in its place, and no placeholder line when there is none.
      expect(find.text('Comprueba el despliegue'), findsNothing);
      expect(find.text('Sin mensajes visibles'), findsNothing);
      expect(find.text('Tarea automatizada'), findsOneWidget);
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
      final list = tester.widget<SliverPadding>(
        find.byType(SliverPadding).first,
      );
      return list.padding.resolve(TextDirection.ltr).bottom;
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

      await pump(tester, [
        _row(
          'background-1',
          title: 'Informe prolongado',
          lastActive: nowSeconds(),
        ),
      ], activeChats: activeChats);
      await _pumpUntil(tester, find.textContaining('Informe prolongado'));

      final strings = Strings.of(
        tester.element(find.byType(SessionListScreen)),
      );
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

      await pump(tester, [
        _row(
          'compacting-1',
          title: 'Sesión compactando',
          lastActive: nowSeconds(),
        ),
      ], activeChats: activeChats);
      await _pumpUntil(tester, find.text('Sesión compactando'));

      final strings = Strings.of(
        tester.element(find.byType(SessionListScreen)),
      );
      expect(
        find.byKey(const ValueKey('session-running-compacting-1')),
        findsOneWidget,
      );
      expect(find.text(strings.liveCompacting), findsOneWidget);
      // The status line has its own semantic colour, smaller and lighter
      // than the title (it used to be the same white as the title).
      final colors = Theme.of(
        tester.element(find.byType(SessionListScreen)),
      ).hermes;
      final status = tester.widget<Text>(
        find.byKey(const ValueKey('session-running-compacting-1')),
      );
      final title = tester.widget<Text>(find.text('Sesión compactando'));
      expect(
        status.style!.color,
        sessionStatusColor(colors, SessionStatusTone.compacting),
      );
      expect(status.style!.color, isNot(title.style!.color));
      expect(status.style!.fontSize, lessThan(title.style!.fontSize!));
      expect(
        status.style!.fontWeight!.value,
        lessThan(title.style!.fontWeight!.value),
      );
      // The live state is a ring beside its own text, no longer a dot
      // before the title.
      expect(
        find.byKey(const ValueKey('session-live-ring-compacting-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session-live-dot-compacting-1')),
        findsNothing,
      );
      expect(find.byType(SessionRowStopControl), findsNothing);
      activeChats.dispose();
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets('inicio pinta el roster frío por id durable, nunca por título', (
    tester,
  ) async {
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
    final generation = aggregate.beginRosterRequest(connection.id, 'default');
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

    // Home: Continuar marks the working chat, matched by its durable id
    // (both rows share the title).
    expect(
      find.byKey(const ValueKey('home-chat-working-busy-row')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-chat-working-idle-row')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });

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
        find.byKey(const ValueKey('home-chat-working-cold-running')),
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
        find.byKey(const ValueKey('home-chat-working-cold-running')),
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
      // The first absence remains visually continuous while the next read
      // settles; the second absence below removes it.
      expect(
        find.byKey(const ValueKey('home-chat-working-cold-running')),
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
        find.byKey(const ValueKey('home-chat-working-cold-running')),
        findsNothing,
      );
      // Calm again; the refreshed chat is still listed in Continuar.
      expect(
        find.byKey(const ValueKey('home-continue-cold-running')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
    },
  );

  testWidgets('inicio conserva el proceso de fondo tras acabar el turno', (
    tester,
  ) async {
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
    await _pumpUntil(tester, find.textContaining('Informe prolongado'));

    final strings = Strings.of(
      tester.element(find.byType(HomeDashboardScreen)),
    );
    // Home: a chat whose turn ended but keeps a background process is not
    // «working» (Continuar marks turns only).
    expect(
      find.byKey(const ValueKey('home-chat-working-background-1')),
      findsNothing,
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

    // re1215: the busy roster row was read right after this chat saw its
    // own turn end (Hermes clears `running` after post-processing and may
    // run a background review); it is the finished turn, not new work.
    expect(find.text(strings.ss1215StatusWorking), findsNothing);
    expect(
      find.byKey(const ValueKey('home-chat-working-background-1')),
      findsNothing,
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
      find.byKey(const ValueKey('home-chat-working-background-1')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets(
    'el anillo del punto en vivo repinta solo el punto, no la fila entera',
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
          home: SessionListScreen(
            connection: _connection(),
            connManager: manager,
            clientOverride: gateway,
            repositoryOverride: repository,
            globalActivityOverride: aggregate,
            activeSessionListLoader: () async => const DesktopActiveSessionList(
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
      );
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey('session-running-live-1')),
      );
      await tester.pump(const Duration(seconds: 1));

      // The 1.8 s ring ticks every frame while the row is live. Each tick
      // must repaint the dot's own layer, never the title, preview or card.
      final painted = <RenderObject>{};
      debugOnProfilePaint = painted.add;
      addTearDown(() => debugOnProfilePaint = null);
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      debugOnProfilePaint = null;
      final paragraphs = painted.whereType<RenderParagraph>().length;
      expect(
        paragraphs,
        0,
        reason: 'the row text must not be repainted by the ring animation',
      );
      expect(painted, isNotEmpty, reason: 'the ring itself keeps animating');
      // Leaving the screen (opaque route on top) stops the ticker.
      Navigator.of(
        tester.element(find.byType(SessionListScreen)),
      ).push(MaterialPageRoute<void>(builder: (_) => const SizedBox()));
      await tester.pumpAndSettle();
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
      expect(find.bySemanticsLabel('Trabajando…'), findsOneWidget);
      expect(find.byKey(const ValueKey('session-row-stop')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('session-running-live-2')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  group('pantallas tapadas por otra ruta', () {
    // Durante un run con subagentes ActiveChatService fuerza una notificación
    // de `activeIds` por cada evento `subagentActivity`, aunque el conjunto no
    // cambie. Inicio y Conversaciones siguen montados debajo del chat y se
    // reconstruían enteros, robando tiempo a los frames del chat visible.
    int builds(WidgetTester tester, Type type) =>
        tester.widgetList(find.byType(type, skipOffstage: false)).length;

    Future<int> countRebuilds(
      WidgetTester tester,
      Type rowType,
      Future<void> Function() action,
    ) async {
      var count = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (element.widget.runtimeType == rowType) count++;
      };
      try {
        await action();
      } finally {
        debugOnRebuildDirtyWidget = previous;
      }
      return count;
    }

    Future<void> pushCover(WidgetTester tester, Type screen) async {
      Navigator.of(tester.element(find.byType(screen))).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('chat encima')),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(find.text('chat encima'), findsOneWidget);
    }

    testWidgets(
      'Conversaciones no reconstruye su lista mientras está tapada y se '
      'pone al día al volver',
      (tester) async {
        tester.view.physicalSize = const Size(1170, 2532);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final activeChats = ActiveChatService(
          compressionRestoreStore: testCompressionRestoreStore(),
        );
        addTearDown(activeChats.dispose);
        await pump(tester, [
          _row('cubierta-1', title: 'Fila tapada', lastActive: nowSeconds()),
        ], activeChats: activeChats);
        await _pumpUntil(tester, find.text('Fila tapada'));
        expect(builds(tester, HermesSliverRows), greaterThan(0));

        // Visible: una notificación sí repinta la lista (comportamiento
        // existente que no debe perderse).
        final visibleRebuilds = await countRebuilds(
          tester,
          HermesSliverRows,
          () async {
            activeChats.activeIds.value = <String>{};
            await tester.pump();
          },
        );
        expect(visibleRebuilds, greaterThan(0));

        await pushCover(tester, SessionListScreen);
        final hiddenRebuilds = await countRebuilds(
          tester,
          HermesSliverRows,
          () async {
            for (var i = 0; i < 20; i++) {
              activeChats.activeIds.value = <String>{};
              // The streaming chat on top produces a frame every vsync.
              tester.binding.scheduleFrame();
              await tester.pump(const Duration(milliseconds: 16));
            }
          },
        );
        expect(hiddenRebuilds, 0);

        // Al volver se entrega UNA puesta al día.
        final returnRebuilds = await countRebuilds(
          tester,
          HermesSliverRows,
          () async {
            Navigator.of(tester.element(find.text('chat encima'))).pop();
            await tester.pumpAndSettle(const Duration(milliseconds: 50));
          },
        );
        expect(returnRebuilds, greaterThan(0));
        expect(find.text('Fila tapada'), findsOneWidget);
      },
    );

    testWidgets(
      'Inicio no se reconstruye mientras está tapado y se pone al día al '
      'volver',
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
        await manager.setActiveConnection(manager.getConnections().single.id);
        final aggregate = GlobalActivityAggregate.inMemory();
        final activeChats = ActiveChatService(
          globalActivity: aggregate,
          compressionRestoreStore: testCompressionRestoreStore(),
        );
        addTearDown(activeChats.dispose);
        final client = _HomeActivityClient();
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
              activeSessionListLoader: () async =>
                  const DesktopActiveSessionList(),
              eventStreamOverride: const Stream<TuiGatewayEvent>.empty(),
            ),
          ),
        );
        await _pumpUntil(tester, find.textContaining('Informe prolongado'));

        final visibleRebuilds = await countRebuilds(
          tester,
          HomeDashboardScreen,
          () async {
            activeChats.activeIds.value = <String>{};
            await tester.pump();
            await tester.pump();
          },
        );
        expect(visibleRebuilds, greaterThan(0));

        await pushCover(tester, HomeDashboardScreen);
        final hiddenRebuilds = await countRebuilds(
          tester,
          HomeDashboardScreen,
          () async {
            for (var i = 0; i < 20; i++) {
              activeChats.activeIds.value = <String>{};
              // The streaming chat on top produces a frame every vsync.
              tester.binding.scheduleFrame();
              await tester.pump(const Duration(milliseconds: 16));
            }
          },
        );
        expect(hiddenRebuilds, 0);

        final returnRebuilds = await countRebuilds(
          tester,
          HomeDashboardScreen,
          () async {
            Navigator.of(tester.element(find.text('chat encima'))).pop();
            await tester.pumpAndSettle(const Duration(milliseconds: 50));
          },
        );
        expect(returnRebuilds, greaterThan(0));
        expect(find.textContaining('Informe prolongado'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
      },
    );
  });
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
