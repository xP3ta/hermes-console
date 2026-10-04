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

/// Conversations > Archive > Hidden: a chat hidden on the server (which
/// Hermes' listing omits) can be found and shown again, and search hits
/// paint their FTS matches instead of the raw `>>>`/`<<<` delimiters.
const _connectionId = 'conn-hidden-view';

/// A Dashboard that keeps per-session `hidden` like Hermes: the default
/// listing omits hidden rows; search finds them with no hidden flag.
class _Server {
  _Server(this.rows, {this.publishesHidden = true});

  final Map<String, Map<String, dynamic>> rows;
  final bool publishesHidden;
  final List<Map<String, dynamic>> patches = [];
  Map<String, String> snippets = {};
  final List<String> searches = [];

  /// Rows the next default listing still omits: a read that began before
  /// the unhide landed.
  Set<String> staleNextListing = {};

  Map<String, dynamic> _wire(Map<String, dynamic> row) =>
      {...row, if (!publishesHidden) 'hidden': null}
        ..removeWhere((key, value) => key == 'hidden' && value == null);

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path == '/api/sessions') {
      final archivedOnly = request.url.queryParameters['archived'] == 'only';
      final stale = archivedOnly ? const <String>{} : staleNextListing;
      if (!archivedOnly) staleNextListing = {};
      final listed = [
        for (final row in rows.values)
          if (row['hidden'] != 1 &&
              (row['archived'] == true) == archivedOnly &&
              !stale.contains(row['id']))
            _wire(row),
      ];
      return http.Response(
        jsonEncode({
          'sessions': listed,
          'total': listed.length,
          'limit': 50,
          'offset': 0,
        }),
        200,
      );
    }
    if (request.method == 'GET' && path == '/api/sessions/search') {
      searches.add(request.url.queryParameters['q'] ?? '');
      return http.Response(
        jsonEncode({
          'results': [
            for (final entry in snippets.entries)
              {
                'session_id': entry.key,
                'lineage_root': entry.key,
                'snippet': entry.value,
                'title': rows[entry.key]!['title'],
                'source': 'cli',
                'started_at': 10,
                'last_active': 20,
                'message_count': 4,
                'archived': false,
                'profile': 'default',
              },
          ],
        }),
        200,
      );
    }
    if (request.method == 'PATCH' && path.startsWith('/api/sessions/')) {
      final id = path.substring('/api/sessions/'.length);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      patches.add({'id': id, ...body});
      body.remove('profile');
      if (!publishesHidden && body.containsKey('hidden')) {
        return http.Response('{"detail":"Nothing to update"}', 400);
      }
      if (body['hidden'] is bool) rows[id]!['hidden'] = body['hidden'] ? 1 : 0;
      return http.Response(jsonEncode({'ok': true, ...body}), 200);
    }
    return http.Response('{}', 404);
  }
}

Map<String, dynamic> _row(String id, String title, {int hidden = 0}) => {
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
  'hidden': hidden,
  'profile': 'default',
};

SavedConnection _connection() => SavedConnection(
  id: _connectionId,
  label: 'Hidden view QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

ApiClient _gateway() => ApiClient(
  baseUrl: 'http://127.0.0.1:8642',
  apiKey: 'k',
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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  Future<void> pump(
    WidgetTester tester,
    _Server server, {
    List<String> legacyHidden = const [],
  }) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    // After create(): it prunes keys of connections it does not know.
    if (legacyHidden.isNotEmpty) {
      await prefs.setStringList('hidden_sessions_$_connectionId', legacyHidden);
    }
    final aggregate = GlobalActivityAggregate.inMemory();
    addTearDown(aggregate.dispose);
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient(server.handle),
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
  }

  Future<void> openHiddenView(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('session-filter-archived')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('archive-view-hidden')));
    await _settle(tester);
  }

  testWidgets('a chat hidden on Desktop too is listed in Archive > Hidden '
      'and Show brings it back with one PATCH hidden:false', (tester) async {
    final server = _Server({
      's1': _row('s1', 'QA ping'),
      's2': _row('s2', 'Other'),
    });
    await pump(tester, server);
    await _pumpUntil(tester, find.text('QA ping'));

    await tester.longPress(find.text('QA ping'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ocultar (también en Desktop)'));
    await _settle(tester);
    expect(server.patches.single, {
      'id': 's1',
      'hidden': true,
      'profile': 'default',
    });
    expect(find.text('QA ping'), findsNothing);

    // Archive alone does not list it: it is not archived.
    await tester.tap(find.byKey(const ValueKey('session-filter-archived')));
    await _settle(tester);
    expect(find.text('Nada archivado'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('archive-view-hidden')));
    await _settle(tester);
    expect(find.text('QA ping'), findsOneWidget);
    expect(find.text('Oculta también en Desktop'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('session-show-s1')));
    await _settle(tester);
    expect(server.patches, hasLength(2));
    expect(server.patches.last, {
      'id': 's1',
      'hidden': false,
      'profile': 'default',
    });
    expect(find.text('QA ping'), findsNothing);
    expect(find.text('Nada oculto'), findsOneWidget);

    // Back in the list, even from a listing read before the unhide landed.
    server.staleNextListing = {'s1'};
    await tester.tap(find.byKey(const ValueKey('session-filter-archived')));
    await _pumpUntil(tester, find.text('QA ping'));
    expect(server.patches, hasLength(2));
    final prefs = await SharedPreferences.getInstance();
    final archive = await SessionArchive.load(prefs, _connectionId);
    await archive.remoteStateSettled;
  });

  testWidgets('a hidden chat found by search shows its match highlighted '
      'and its menu offers Show, not another Hide', (tester) async {
    final server = _Server({'s1': _row('s1', 'QA ping'), 's3': _row('s3', '')});
    await pump(tester, server);
    await _pumpUntil(tester, find.text('QA ping'));
    await tester.longPress(find.text('QA ping'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ocultar (también en Desktop)'));
    await _settle(tester);
    expect(find.text('QA ping'), findsNothing);

    server.snippets = {
      's1': 'QA >>>9484<<< ping',
      // Untitled: its title comes from the preview.
      's3': 'otra >>>9484<<< cosa',
    };
    await tester.enterText(find.byType(TextField).first, '9484');
    await tester.pump(const Duration(milliseconds: 300));
    await _pumpUntil(tester, find.byKey(const ValueKey('session-snippet-s1')));

    final snippet = tester.widget<Text>(
      find.byKey(const ValueKey('session-snippet-s1')),
    );
    final spans = (snippet.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.map((s) => s.text).join(), 'QA 9484 ping');
    expect(
      spans.singleWhere((s) => s.style?.fontWeight == FontWeight.w700).text,
      '9484',
    );
    await _pumpUntil(tester, find.byKey(const ValueKey('session-snippet-s3')));
    expect(find.textContaining('>>>', findRichText: true), findsNothing);
    expect(find.textContaining('<<<', findRichText: true), findsNothing);

    await tester.longPress(find.text('QA ping'));
    await tester.pumpAndSettle();
    expect(find.text('Mostrar (dejar de ocultar)'), findsOneWidget);
    expect(find.text('Ocultar localmente'), findsNothing);
    expect(find.text('Ocultar (también en Desktop)'), findsNothing);
    await tester.tap(find.text('Mostrar (dejar de ocultar)'));
    await _settle(tester);
    expect(server.patches.last, {
      'id': 's1',
      'hidden': false,
      'profile': 'default',
    });
    expect(server.patches, hasLength(2));
  });

  testWidgets('a legacy local-hidden chat is listed and shown again without '
      'a server write', (tester) async {
    final server = _Server({
      'old': _row('old', 'Legacy chat'),
      's2': _row('s2', 'Other'),
    }, publishesHidden: false);
    await pump(tester, server, legacyHidden: ['old']);
    await _pumpUntil(tester, find.text('Other'));
    expect(find.text('Legacy chat'), findsNothing);

    await openHiddenView(tester);
    expect(find.text('Legacy chat'), findsOneWidget);
    expect(find.text('Oculta solo en este dispositivo'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('session-show-old')));
    await _settle(tester);
    expect(find.text('Nada oculto'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('session-filter-archived')));
    await _pumpUntil(tester, find.text('Legacy chat'));
    expect(server.patches, isEmpty);
  });

  testWidgets('typing in Archive > Hidden filters locally and never searches '
      'the server; leaving it searches the current text', (tester) async {
    final server = _Server({
      's1': _row('s1', 'QA ping'),
      's2': _row('s2', 'QA pong'),
      's3': _row('s3', 'Other'),
    });
    await pump(tester, server, legacyHidden: ['s1', 's2']);
    await _pumpUntil(tester, find.text('Other'));
    final field = find.byType(TextField).first;
    await tester.tap(find.byKey(const ValueKey('session-filter-archived')));
    await _settle(tester);
    // A search still waiting for the typing pause is dropped on entering.
    await tester.enterText(field, 'QA');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('archive-view-hidden')));
    await _settle(tester);
    expect(server.searches, isEmpty);
    expect(find.text('QA ping'), findsOneWidget);
    expect(find.text('QA pong'), findsOneWidget);

    for (final query in ['QA', 'QA p', 'QA pi']) {
      await tester.enterText(field, query);
      await tester.pump(const Duration(milliseconds: 300));
      await _settle(tester);
    }
    expect(server.searches, isEmpty);
    expect(find.text('QA ping'), findsOneWidget);
    expect(find.text('QA pong'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('archive-view-archived')));
    await _settle(tester);
    expect(server.searches, ['QA pi']);

    // Back to Hidden, then out of Archive and in again (Hidden is kept).
    await tester.tap(find.byKey(const ValueKey('archive-view-hidden')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('session-filter-archived')));
    await _settle(tester);
    expect(server.searches, ['QA pi', 'QA pi']);
    await tester.tap(find.byKey(const ValueKey('session-filter-archived')));
    await _settle(tester);
    expect(server.searches, ['QA pi', 'QA pi']);
    expect(find.text('QA ping'), findsOneWidget);
  });
}
