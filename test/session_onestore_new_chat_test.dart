// One session state (#21): a chat created in Console is one row on Home,
// Conversations and the drawer. Before the first send it lives only here as
// a draft under its provisional `mob-` id; once Hermes stores it, the server
// row (its real id) is the only row, and a follow-up draft rides that row
// instead of painting a second one. ChatScreen moving the draft from the
// provisional id to the server id is covered in chat_screen_test.dart
// ('a chat created here is one local entry, under the server id').
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart' show hermesRouteObserver;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final int _now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

const _provisionalId = 'mob-created';
const _serverId = 'srv-created';
const _serverTitle = 'Trip budget';
const _firstTurn = 'Plan the trip budget';
const _followUp = 'And the hotel';

/// The stored row Hermes lists once the first turn lands.
Map<String, dynamic> _serverRow() => {
  'id': _serverId,
  '_lineage_root_id': _serverId,
  'title': _serverTitle,
  'preview': _firstTurn,
  'model': 'model-a',
  'source': 'mobile',
  'message_count': 2,
  'is_active': false,
  'started_at': _now - 90,
  'ended_at': _now - 30,
  'last_active': _now - 30,
  'archived': false,
};

final _secure = <String, String>{};

class _HomeClient extends ApiClient {
  _HomeClient(this.rows)
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient(
          (_) async =>
              http.Response(jsonEncode({'object': 'list', 'data': rows}), 200),
        ),
      );

  final List<Map<String, dynamic>> rows;

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<bool> healthReachable() => healthCheck();

  @override
  void close() {}
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> _pumpHome(
  WidgetTester tester,
  List<Map<String, dynamic>> rows,
) async {
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  if (manager.getConnections().isEmpty) {
    await manager.saveConnection(
      'QA',
      '127.0.0.2',
      8642,
      'test-key',
      kind: InstanceKind.vps,
    );
  }
  await manager.setActiveConnection(manager.getConnections().single.id);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      navigatorObservers: [hermesRouteObserver],
      home: HomeDashboardScreen(
        connManager: manager,
        clientFactory: (_) => _HomeClient(rows),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _pumpConversations(
  WidgetTester tester,
  SavedConnection connection,
  List<Map<String, dynamic>> rows,
) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  final dashboard = DashboardClient(
    host: '127.0.0.1',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((request) async {
      if (request.url.path == '/api/sessions') {
        return http.Response(
          jsonEncode({
            'sessions': rows,
            'total': rows.length,
            'limit': 50,
            'offset': 0,
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    }),
  );
  final gateway = ApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    apiKey: 'test-key',
    connectionId: connection.id,
    httpClient: MockClient((request) async {
      if (request.url.path == '/health' ||
          request.url.path == '/api/sessions') {
        return http.Response('{}', 200);
      }
      return http.Response('{}', 404);
    }),
  );
  final repository = SessionRepository(dashboard, gateway);
  addTearDown(() {
    repository.close();
    dashboard.close();
  });
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: SessionListScreen(
        connection: connection,
        connManager: manager,
        clientOverride: gateway,
        repositoryOverride: repository,
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _pumpDrawer(
  WidgetTester tester,
  SavedConnection connection,
  List<Map<String, dynamic>> rows,
) async {
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  final scaffoldKey = GlobalKey<ScaffoldState>();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Scaffold(
        key: scaffoldKey,
        drawer: HermesDrawer(
          connection: connection,
          connManager: manager,
          current: DrawerSection.home,
          recentSessionsClientFactory: (saved) => _HomeClient(rows),
        ),
      ),
    ),
  );
  scaffoldKey.currentState!.openDrawer();
  await tester.pumpAndSettle();
}

Future<void> _saveDraft(
  String connectionId,
  String sessionId,
  String text,
) async => ChatDraftStore(
  await SharedPreferences.getInstance(),
).save(connectionId, sessionId, text, const []);

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _secure.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          final args = call.arguments is Map
              ? Map<Object?, Object?>.from(call.arguments as Map)
              : const <Object?, Object?>{};
          switch (call.method) {
            case 'write':
              _secure[args['key'] as String] = args['value'] as String;
              return null;
            case 'read':
              return _secure[args['key']];
            case 'readAll':
              return Map<String, String>.of(_secure);
            case 'delete':
              _secure.remove(args['key']);
              return null;
            case 'deleteAll':
              _secure.clear();
              return null;
            case 'containsKey':
              return _secure.containsKey(args['key']);
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  group('Home', () {
    Future<String> connectionId() async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await manager.saveConnection(
        'QA',
        '127.0.0.2',
        8642,
        'test-key',
        kind: InstanceKind.vps,
      );
      return manager.getConnections().single.id;
    }

    testWidgets('before the first send: one draft row', (tester) async {
      final id = await connectionId();
      await tester.runAsync(() => _saveDraft(id, _provisionalId, _firstTurn));
      await _pumpHome(tester, const []);
      expect(find.text(_firstTurn), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('stored: the server row only, a follow-up draft rides it', (
      tester,
    ) async {
      final id = await connectionId();
      await tester.runAsync(() => _saveDraft(id, _serverId, _followUp));
      await _pumpHome(tester, [_serverRow()]);
      expect(find.text(_serverTitle), findsOneWidget);
      expect(find.text(_followUp), findsNothing, reason: 'no second row');
      await _unmount(tester);
    });
  });

  group('Conversations', () {
    final connection = SavedConnection(
      id: 'conn-onestore-created',
      label: 'QA',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-key',
      dashboardUrl: 'http://127.0.0.1:9119',
      kind: InstanceKind.vps,
    );

    testWidgets('before the first send: one draft row', (tester) async {
      await tester.runAsync(
        () => _saveDraft(connection.id, _provisionalId, _firstTurn),
      );
      await _pumpConversations(tester, connection, const []);
      expect(find.text(_firstTurn), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('stored: the server row only, a follow-up draft rides it', (
      tester,
    ) async {
      await tester.runAsync(
        () => _saveDraft(connection.id, _serverId, _followUp),
      );
      await _pumpConversations(tester, connection, [_serverRow()]);
      expect(find.text(_serverTitle), findsOneWidget);
      expect(find.text(_followUp), findsNothing, reason: 'no second row');
      await _unmount(tester);
    });
  });

  testWidgets('drawer: the stored chat is one row', (tester) async {
    final connection = SavedConnection(
      id: 'drawer-onestore-created',
      label: 'Server',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-key',
    );
    await tester.runAsync(
      () => _saveDraft(connection.id, _serverId, _followUp),
    );
    await _pumpDrawer(tester, connection, [_serverRow()]);
    expect(
      find.byKey(
        const ValueKey('drawer-recent-$_serverId'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('drawer-recent-$_provisionalId'),
        skipOffstage: false,
      ),
      findsNothing,
    );
  });
}
