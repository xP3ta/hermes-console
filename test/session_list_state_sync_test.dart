import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_activity_aggregate.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Conversations keeps per-session state on the server, as Desktop: the
/// unread dot and the read toggle follow the server's `unread`, and a rename
/// is a PATCH title.
const _connectionId = 'conn-state-sync';

Map<String, dynamic> _row(String id, {String title = 'Plan', bool? unread}) => {
  'id': id,
  '_lineage_root_id': id,
  'title': title,
  'preview': '',
  'model': 'model-a',
  'source': 'cli',
  'message_count': 4,
  'is_active': false,
  'started_at': 10,
  'ended_at': 19,
  'last_active': 20,
  'archived': false,
  'hidden': 0,
  'unread': ?unread,
  'profile': 'default',
};

SavedConnection _connection() => SavedConnection(
  id: _connectionId,
  label: 'State sync QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'key',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

ApiClient _gateway() => ApiClient(
  baseUrl: 'http://127.0.0.1:8642',
  apiKey: 'key',
  connectionId: _connectionId,
  httpClient: MockClient((request) async {
    if (request.url.path == '/health' || request.url.path == '/api/sessions') {
      return http.Response('{}', 200);
    }
    return http.Response('{}', 404);
  }),
);

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureValues = <String, String>{};
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureValues.clear();
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
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  Future<List<http.Request>> pump(
    WidgetTester tester,
    List<Map<String, dynamic>> rows,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final patches = <http.Request>[];
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
        if (request.method == 'PATCH') {
          patches.add(request);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          body.remove('profile');
          return http.Response(
            jsonEncode({'ok': true, 'title': body['title'] ?? 'Plan', ...body}),
            200,
          );
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
        ),
      ),
    );
    return patches;
  }

  testWidgets('the unread dot and the row toggle follow the server', (
    tester,
  ) async {
    final patches = await pump(tester, [
      _row('s1', title: 'Unread plan', unread: true),
      _row('s2', title: 'Legacy plan'),
    ]);
    await _pumpUntil(tester, find.byKey(const ValueKey('session-unread-s1')));
    expect(find.byKey(const ValueKey('session-unread-s2')), findsNothing);

    await tester.longPress(find.text('Unread plan'));
    await tester.pumpAndSettle();
    expect(find.text('Marcar como leído'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('session-menu-unread')));
    await tester.pumpAndSettle();
    expect(jsonDecode(patches.single.body), {
      'unread': false,
      'profile': 'default',
    });
    expect(patches.single.url.path, '/api/sessions/s1');
    expect(find.byKey(const ValueKey('session-unread-s1')), findsNothing);

    // A server that does not publish read state offers no toggle.
    await tester.longPress(find.text('Legacy plan'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-menu-unread')), findsNothing);
  });

  testWidgets('a rename is a PATCH title and the row shows it', (tester) async {
    final patches = await pump(tester, [_row('s1', title: 'Old name')]);
    await _pumpUntil(tester, find.text('Old name'));

    await tester.longPress(find.text('Old name'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cambiar título'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('session-title-editor-field')),
      'New name',
    );
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();

    expect(jsonDecode(patches.single.body), {
      'title': 'New name',
      'profile': 'default',
    });
    expect(find.text('New name'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('session_titles_$_connectionId') ?? [], isEmpty);
    final archive = await SessionArchive.load(prefs, _connectionId);
    await archive.remoteStateSettled;
  });
}
