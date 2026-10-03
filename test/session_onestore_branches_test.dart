// One session state (#21): a real branch (Desktop `/branch`, a reset) is its
// own row on every screen, as in the Desktop sidebar, while delegate runs,
// tool sessions and automation children stay folded under their parent.
// Home, Conversations (Dashboard and gateway paths) and the drawer apply the
// same rule, Session.listsAsOwnRow.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
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

/// One list row in the shape both the Dashboard and the gateway publish.
Map<String, dynamic> _row(
  String id,
  String title, {
  String source = 'desktop',
  String? parent,
  int age = 60,
}) => {
  'id': id,
  '_lineage_root_id': id,
  'title': title,
  'preview': 'Preview of $title',
  'model': 'model-a',
  'source': source,
  'message_count': 4,
  'is_active': false,
  'started_at': _now - age - 30,
  'ended_at': _now - age,
  'last_active': _now - age,
  'archived': false,
  'parent_session_id': ?parent,
};

/// A parent with two Desktop branches, plus the children that must stay
/// folded: a delegate run, a tool session and an unclassified child.
final List<Map<String, dynamic>> _rows = [
  _row('parent', 'Release plan', age: 300),
  _row('branch-a', 'Release plan: option A', parent: 'parent', age: 200),
  _row('branch-b', 'Release plan: option B', parent: 'parent', age: 100),
  _row(
    'delegate',
    'Delegate run',
    source: 'subagent',
    parent: 'parent',
    age: 50,
  ),
  _row('tool', 'Tool session', source: 'tool', parent: 'parent', age: 40),
  _row('unknown', 'Unclassified child', source: '', parent: 'parent'),
];

const _shown = [
  'Release plan',
  'Release plan: option A',
  'Release plan: option B',
];
const _folded = ['Delegate run', 'Tool session', 'Unclassified child'];

http.Response _gatewayPage() =>
    http.Response(jsonEncode({'object': 'list', 'data': _rows}), 200);

class _HomeClient extends ApiClient {
  _HomeClient()
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => _gatewayPage()),
      );

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<bool> healthReachable() => healthCheck();

  @override
  void close() {}
}

void expectRows(String surface) {
  for (final title in _shown) {
    expect(
      find.text(title, skipOffstage: false),
      findsOneWidget,
      reason: '$surface shows "$title"',
    );
  }
  for (final title in _folded) {
    expect(
      find.text(title, skipOffstage: false),
      findsNothing,
      reason: '$surface folds "$title"',
    );
  }
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (finder.evaluate().isNotEmpty) break;
  }
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          secureChannel,
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  test('one rule tells real branches from folded children', () {
    bool own(Map<String, dynamic> row) => Session.fromJson(row).listsAsOwnRow;
    expect(own(_row('root', 'Root')), isTrue);
    expect(own(_row('root-cron', 'Cron root', source: 'cron')), isTrue);
    for (final source in ['desktop', 'cli', 'tui', 'mobile', 'telegram']) {
      expect(own(_row('b', 'Branch', source: source, parent: 'p')), isTrue);
    }
    for (final source in ['subagent', 'tool', 'cron', 'kanban', '', ' ']) {
      expect(
        own(_row('c', 'Child', source: source, parent: 'p')),
        isFalse,
        reason: 'source "$source"',
      );
    }
    expect(own(_row('cron_job_20260101_000000', 'Job', parent: 'p')), isFalse);
  });

  testWidgets('Home shows the parent and both branches', (tester) async {
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
          clientFactory: (_) => _HomeClient(),
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Release plan: option B'));
    expectRows('Home');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final dashboardUp in [true, false]) {
    final path = dashboardUp ? 'Dashboard' : 'gateway fallback';
    testWidgets('Conversations ($path) shows the parent and both branches', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final connection = SavedConnection(
        id: 'conn-onestore-branches',
        label: 'QA',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'test-key',
        dashboardUrl: 'http://127.0.0.1:9119',
        kind: InstanceKind.vps,
      );
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      var reads = 0;
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        port: 9119,
        manualToken: 'dashboard-token',
        httpClientOverride: MockClient((request) async {
          if (!dashboardUp) return http.Response('{}', 500);
          if (request.url.path == '/api/sessions') {
            reads++;
            return http.Response(
              jsonEncode({
                'sessions': _rows,
                'total': _rows.length,
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
          if (request.url.path == '/api/sessions') {
            if (!dashboardUp) reads++;
            return _gatewayPage();
          }
          if (request.url.path == '/health') return http.Response('{}', 200);
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
      await _pumpUntil(tester, find.text('Release plan'));
      expectRows('Conversations ($path)');

      // A later refresh keeps them: no branch flickers out.
      final before = reads;
      unawaited(
        tester
            .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
            .show(),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(reads, greaterThan(before), reason: 'the list refreshed');
      expectRows('Conversations ($path) after a refresh');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('the drawer shows the parent and both branches', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final connection = SavedConnection(
      id: 'drawer-onestore-branches',
      label: 'Server',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-key',
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
            recentSessionsClientFactory: (saved) => ApiClient(
              baseUrl: saved.baseUrl,
              apiKey: 'test-key',
              httpClient: MockClient((_) async => _gatewayPage()),
            ),
          ),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await tester.pumpAndSettle();
    for (final id in ['parent', 'branch-a', 'branch-b']) {
      expect(
        find.byKey(ValueKey('drawer-recent-$id'), skipOffstage: false),
        findsOneWidget,
        reason: 'drawer shows $id',
      );
    }
    for (final id in ['delegate', 'tool', 'unknown']) {
      expect(
        find.byKey(ValueKey('drawer-recent-$id'), skipOffstage: false),
        findsNothing,
        reason: 'drawer folds $id',
      );
    }
  });
}
