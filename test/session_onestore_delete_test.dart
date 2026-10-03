// One session state (#21): a chat deleted on any screen leaves every other
// screen at once, from the shared per-connection SessionArchive, without
// waiting for a network refresh, and a stale page cannot bring it back.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/session_detail_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:hermes_android/core/services/session_deletion.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart' show hermesRouteObserver;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

double _nowSeconds() => DateTime.now().millisecondsSinceEpoch / 1000;

Session _session(String id, {required String title, double? activity}) =>
    Session(
      id: id,
      title: title,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 1,
      isActive: false,
      preview: 'Content',
      startedAt: activity ?? _nowSeconds() - 60,
    );

/// Home's list client. [stalePage] models a refresh that still returns the
/// deleted row (an older cached/proxied page or a response that left the
/// server before the delete landed).
class _HomeClient extends ApiClient {
  _HomeClient(this.sessions)
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  List<Session> sessions;
  int sessionReads = 0;
  Completer<void>? hold;
  bool fail = false;

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
    sessionReads++;
    final snapshot = List<Session>.of(sessions);
    final gate = hold;
    if (gate != null) await gate.future;
    if (fail) throw const CoreReadException(CoreReadErrorKind.malformed);
    return snapshot;
  }

  @override
  void close() {}
}

/// The detail screen's client: the server confirms the delete.
class _DetailClient extends ApiClient {
  _DetailClient(this.target)
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  final Session target;
  final deleted = <String>[];

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => [target];

  @override
  Future<bool> deleteSession(String sessionId, {String? profile}) async {
    deleted.add(sessionId);
    return true;
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final secureValues = <String, String>{};
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

  group('SessionArchive deletion tombstones', () {
    test('a confirmed delete hides the row on every reader at once', () async {
      final prefs = await SharedPreferences.getInstance();
      final home = await SessionArchive.load(prefs, 'conn-a');
      final list = await SessionArchive.load(prefs, 'conn-a');
      final gone = _session('gone', title: 'Gone');
      final kept = _session('kept', title: 'Kept');
      var notified = 0;
      home.addListener(() => notified++);

      final write = list.markSessionDeleted(gone);
      expect(notified, 1, reason: 'synchronous, before any await');
      expect(home.isSessionDeleted(gone), isTrue);
      expect(home.isSessionDeleted(kept), isFalse);
      await write;
      expect(
        prefs.getStringList('deleted_sessions_conn-a')!.single,
        startsWith('gone\t'),
      );
    });

    test('a row with activity newer than the deletion is real data', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = await SessionArchive.load(prefs, 'conn-a');
      final deletedAt = DateTime.fromMillisecondsSinceEpoch(1800000000000);
      final stale = _session('s1', title: 'Old', activity: 1799999000);
      await store.markSessionDeleted(stale, now: deletedAt);

      // The same stale row from a cached page or a late response stays gone.
      expect(store.isSessionDeleted(stale), isTrue);
      // Millisecond timestamps are compared on the same scale.
      expect(
        store.isSessionDeleted(
          _session('s1', title: 'Old', activity: 1799999000000),
        ),
        isTrue,
      );
      // The server recreated it after the delete: shown, never hidden.
      expect(
        store.isSessionDeleted(
          _session('s1', title: 'New', activity: 1800000100),
        ),
        isFalse,
      );
    });

    test(
      'eviction never drops a tombstone a read in flight still needs',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final store = await SessionArchive.load(prefs, 'conn-a');
        const max = SessionArchive.maxDeletedTombstones;
        Session row(int i) => _session('s$i', title: 'S', activity: 1000.0 + i);

        // A page request leaves before the deletes and answers after them.
        final late = store.beginListRead();
        for (var i = 0; i <= max; i++) {
          await store.markSessionDeleted(
            row(i),
            now: DateTime.fromMillisecondsSinceEpoch(0),
          );
        }
        // Its page still carries the earliest deleted row: it stays hidden.
        expect(store.isSessionDeleted(row(0)), isTrue);
        expect(
          prefs.getStringList('deleted_sessions_conn-a'),
          hasLength(max + 1),
        );
        final reread = await SessionArchive.load(prefs, 'conn-a');
        expect(reread.isSessionDeleted(row(0)), isTrue);

        // Its result applied, no read can carry the rows any more: the store
        // goes back within its bound, oldest first.
        late.end();
        await Future<void>.delayed(Duration.zero);
        expect(prefs.getStringList('deleted_sessions_conn-a'), hasLength(max));
        expect(store.isSessionDeleted(row(0)), isFalse);
        expect(store.isSessionDeleted(row(max)), isTrue);
        late.end(); // idempotent
      },
    );

    test(
      'a read that starts after a delete does not hold its tombstone',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final store = await SessionArchive.load(prefs, 'conn-a');
        const max = SessionArchive.maxDeletedTombstones;
        Session row(int i) => _session('s$i', title: 'S', activity: 1000.0 + i);
        await store.markSessionDeleted(
          row(0),
          now: DateTime.fromMillisecondsSinceEpoch(0),
        );
        // Started after s0's delete: the server already answers without it.
        final fresh = store.beginListRead();
        for (var i = 1; i <= max; i++) {
          await store.markSessionDeleted(
            row(i),
            now: DateTime.fromMillisecondsSinceEpoch(0),
          );
        }
        expect(prefs.getStringList('deleted_sessions_conn-a'), hasLength(max));
        expect(store.isSessionDeleted(row(0)), isFalse);
        // The rows deleted while it was open are kept for it.
        expect(store.isSessionDeleted(row(1)), isTrue);
        fresh.end();
      },
    );

    test('a cold start reads the tombstone back from storage', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = await SessionArchive.load(prefs, 'conn-a');
      final gone = _session('gone', title: 'Gone');
      await store.markSessionDeleted(gone);
      final persisted = prefs.getStringList('deleted_sessions_conn-a')!;

      // New process: a fresh preferences instance, so a fresh store.
      SharedPreferences.setMockInitialValues({
        'deleted_sessions_conn-a': persisted,
      });
      final coldPrefs = await SharedPreferences.getInstance();
      expect(identical(coldPrefs, prefs), isFalse);
      final cold = await SessionArchive.load(coldPrefs, 'conn-a');
      expect(identical(cold, store), isFalse);
      expect(cold.isSessionDeleted(gone), isTrue);
      expect(cold.isSessionDeleted(_session('kept', title: 'Kept')), isFalse);
    });

    test('other stores keep no tombstone key until a delete', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = await SessionArchive.load(prefs, 'conn-a');
      await store.archive('x');
      expect(prefs.containsKey('deleted_sessions_conn-a'), isFalse);
    });
  });

  group('Home follows a delete made in session detail', () {
    Future<(ConnectionManager, SavedConnection)> setUpManager() async {
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
      final connection = manager.getConnections().single;
      await manager.setActiveConnection(connection.id);
      return (manager, connection);
    }

    Future<void> deleteFromDetail(
      WidgetTester tester,
      SavedConnection connection,
      Session gone,
      _DetailClient detailClient,
    ) async {
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push<bool>(
          MaterialPageRoute<bool>(
            builder: (_) => SessionDetailScreen(
              connection: connection,
              session: gone,
              client: detailClient,
              skipInitialSessionRefresh: true,
            ),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final deleteRow = find.byKey(const ValueKey('session-detail-delete'));
      await tester.ensureVisible(deleteRow);
      await tester.pump();
      await tester.tap(deleteRow);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(
        find.byKey(const ValueKey('session-detail-delete-confirm')),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(detailClient.deleted, [gone.id]);
      expect(find.byType(SessionDetailScreen), findsNothing);
    }

    Future<void> pumpHome(
      WidgetTester tester,
      ConnectionManager manager,
      _HomeClient client,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          navigatorObservers: [hermesRouteObserver],
          home: HomeDashboardScreen(
            connManager: manager,
            clientFactory: (_) => client,
          ),
        ),
      );
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text('Deleted in detail').evaluate().isNotEmpty) break;
      }
      expect(find.text('Deleted in detail'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('a stale refresh page cannot bring the row back', (
      tester,
    ) async {
      final (manager, connection) = await setUpManager();
      final kept = _session('kept', title: 'Kept row');
      final gone = _session('gone', title: 'Deleted in detail');
      // Every Home read, including the one after the detail pops, still
      // carries the deleted row.
      final client = _HomeClient([kept, gone]);
      await pumpHome(tester, manager, client);

      await deleteFromDetail(tester, connection, gone, _DetailClient(gone));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Deleted in detail'), findsNothing);
      expect(find.text('Kept row'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('a late page cannot bring back the earliest of many '
        'deleted chats', (tester) async {
      final (manager, connection) = await setUpManager();
      final kept = _session('kept', title: 'Kept row');
      final gone = _session('gone', title: 'Deleted in detail');
      final client = _HomeClient([kept, gone]);
      await pumpHome(tester, manager, client);

      // A refresh leaves before the deletes and answers after them with the
      // page it read then (still carrying the first deleted chat).
      client.hold = Completer<void>();
      historyCleanupInvalidations.publish(
        connectionId: connection.id,
        scope: HistoryCleanupScope.normalConversations,
      );
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      final store = await SessionArchive.load(prefs, connection.id);
      await tester.runAsync(() async {
        await store.markSessionDeleted(gone);
        // More confirmed deletes than the store's bound.
        for (var i = 0; i < SessionArchive.maxDeletedTombstones; i++) {
          await store.markSessionDeleted(_session('other-$i', title: 'O'));
        }
      });
      await tester.pump();
      expect(find.text('Deleted in detail'), findsNothing);

      client.hold!.complete();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Deleted in detail'), findsNothing);
      expect(find.text('Kept row'), findsOneWidget);

      // A later refresh that fails keeps Home's retained page: the deleted
      // chat is not in it either.
      client
        ..hold = null
        ..fail = true;
      historyCleanupInvalidations.publish(
        connectionId: connection.id,
        scope: HistoryCleanupScope.normalConversations,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Deleted in detail'), findsNothing);
      expect(find.text('Kept row'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('Home\'s retained page cannot bring back the earliest of '
        'many deleted chats', (tester) async {
      final (manager, connection) = await setUpManager();
      final kept = _session('kept', title: 'Kept row');
      final gone = _session('gone', title: 'Deleted in detail');
      final client = _HomeClient([kept, gone]);
      await pumpHome(tester, manager, client);

      // No read is in flight: the bound may drop tombstones right away.
      final prefs = await SharedPreferences.getInstance();
      final store = await SessionArchive.load(prefs, connection.id);
      await tester.runAsync(() async {
        await store.markSessionDeleted(gone);
        for (var i = 0; i < SessionArchive.maxDeletedTombstones; i++) {
          await store.markSessionDeleted(_session('other-$i', title: 'O'));
        }
      });
      await tester.pump();
      expect(store.isSessionDeleted(gone), isFalse, reason: 'evicted');

      // Offline now: Home keeps painting the page it retained.
      client.fail = true;
      historyCleanupInvalidations.publish(
        connectionId: connection.id,
        scope: HistoryCleanupScope.normalConversations,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Deleted in detail'), findsNothing);
      expect(find.text('Kept row'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('the row leaves Home before the slow refresh answers', (
      tester,
    ) async {
      final (manager, connection) = await setUpManager();
      final kept = _session('kept', title: 'Kept row');
      final gone = _session('gone', title: 'Deleted in detail');
      final client = _HomeClient([kept, gone]);
      await pumpHome(tester, manager, client);

      // The refresh Home starts when the detail pops never answers in time.
      client
        ..sessions = [kept]
        ..hold = Completer<void>();
      final reads = client.sessionReads;
      await deleteFromDetail(tester, connection, gone, _DetailClient(gone));
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.sessionReads, greaterThan(reads));
      expect(find.text('Deleted in detail'), findsNothing);
      expect(find.text('Kept row'), findsOneWidget);

      client.hold!.complete();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Deleted in detail'), findsNothing);
      expect(find.text('Kept row'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });

  group('Conversations shares the deletion', () {
    const connectionId = 'conn-onestore-list';
    final connection = SavedConnection(
      id: connectionId,
      label: 'QA',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-key',
      dashboardUrl: 'http://127.0.0.1:9119',
      kind: InstanceKind.vps,
    );
    Map<String, dynamic> row(String id, String title, int lastActive) => {
      'id': id,
      '_lineage_root_id': id,
      'title': title,
      'preview': '',
      'model': 'model-a',
      'source': 'mobile',
      'message_count': 2,
      'is_active': false,
      'started_at': lastActive - 30,
      'ended_at': lastActive - 1,
      'last_active': lastActive,
      'archived': false,
    };

    Future<({List<String> deletes, List<int> reads})> pumpList(
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final rows = [
        row('kept', 'Kept row', now - 120),
        row('gone', 'Deleted row', now - 60),
      ];
      final reads = <int>[0];
      final deletes = <String>[];
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final dashboard = DashboardClient(
        host: '127.0.0.1',
        port: 9119,
        manualToken: 'dashboard-token',
        httpClientOverride: MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/api/sessions') {
            reads[0]++;
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
        connectionId: connectionId,
        httpClient: MockClient((request) async {
          if (request.method == 'DELETE') {
            deletes.add(request.url.pathSegments.last);
            return http.Response('{"deleted": true}', 200);
          }
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
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        if (find.text('Deleted row').evaluate().isNotEmpty) break;
      }
      expect(find.text('Deleted row'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      return (deletes: deletes, reads: reads);
    }

    testWidgets('a delete made on another screen drops the row at once', (
      tester,
    ) async {
      final probe = await pumpList(tester);
      final reads = probe.reads[0];
      final prefs = await SharedPreferences.getInstance();
      final other = await SessionArchive.load(prefs, connectionId);
      await tester.runAsync(
        () => other.markSessionDeleted(_session('gone', title: 'Deleted row')),
      );
      await tester.pump();

      expect(find.text('Deleted row'), findsNothing);
      expect(find.text('Kept row'), findsOneWidget);
      expect(probe.reads[0], reads, reason: 'no network read');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('a delete made here reaches the shared store', (tester) async {
      final probe = await pumpList(tester);
      await tester.drag(find.text('Deleted row'), const Offset(-400, 0));
      await tester.pumpAndSettle();
      final s = Strings.of(tester.element(find.byType(SessionListScreen)));
      await tester.tap(find.text(s.slMenuDelete));
      await tester.pumpAndSettle();
      await tester.tap(find.text(s.slDeleteConfirm).last);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(probe.deletes, ['gone']);

      final prefs = await SharedPreferences.getInstance();
      final home = await SessionArchive.load(prefs, connectionId);
      // What Home, the drawer or a cold-start page would paint next.
      expect(
        home.isSessionDeleted(
          _session('gone', title: 'Deleted row', activity: _nowSeconds() - 60),
        ),
        isTrue,
      );
      expect(
        home.isSessionDeleted(_session('kept', title: 'Kept row')),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });

  testWidgets('drawer recents skip deleted and hidden chats like Home', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final connection = SavedConnection(
      id: 'drawer-onestore',
      label: 'Server',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-key',
    );
    final store = await SessionArchive.load(prefs, connection.id);
    await store.markSessionDeleted(
      _session('deleted', title: 'Deleted', activity: 1785312000),
    );
    await store.hideSession(_session('hidden', title: 'Hidden'));
    final scaffoldKey = GlobalKey<ScaffoldState>();
    Map<String, Object> row(String id, String title) => {
      'id': id,
      'title': title,
      'last_active': '2026-07-29T08:00:00Z',
      'message_count': 2,
    };
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
              httpClient: MockClient(
                (_) async => http.Response(
                  jsonEncode({
                    'object': 'list',
                    'data': [
                      row('kept', 'Kept chat'),
                      row('deleted', 'Deleted chat'),
                      row('hidden', 'Hidden chat'),
                    ],
                  }),
                  200,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('drawer-recent-kept'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('drawer-recent-deleted'), skipOffstage: false),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('drawer-recent-hidden'), skipOffstage: false),
      findsNothing,
    );
  });
}
