import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One source of truth for the per-connection session overrides (local
/// titles, archive, pin, hidden): every screen reads the same store, a change
/// made on one screen is observed by the others in the same frame without a
/// network read, and no screen can clobber another screen's write.
Session _session(String id, {String title = 'Server title', String? root}) =>
    Session(
      id: id,
      lineageRootId: root,
      title: title,
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 1,
      isActive: false,
      preview: 'Content',
      startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
    );

class _CountingHomeClient extends ApiClient {
  _CountingHomeClient(this.sessions)
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
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
    sessionReads++;
    return List<Session>.of(sessions);
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

  group('SessionArchive store', () {
    test('every screen of one connection shares one store', () async {
      final prefs = await SharedPreferences.getInstance();
      final home = await SessionArchive.load(prefs, 'conn-a');
      final list = await SessionArchive.load(prefs, 'conn-a');
      final other = await SessionArchive.load(prefs, 'conn-b');

      expect(identical(home, list), isTrue);
      expect(identical(home, other), isFalse);
    });

    test('a stale screen copy never clobbers another screen write', () async {
      final prefs = await SharedPreferences.getInstance();
      // Home loads first; Conversations archives; then Home hides another
      // row. Each write persists every set, so a private stale copy in Home
      // would silently un-archive the conversation.
      final home = await SessionArchive.load(prefs, 'conn-a');
      final list = await SessionArchive.load(prefs, 'conn-a');
      await list.archive('archived-in-list');
      await home.hide('hidden-in-home');

      final reread = await SessionArchive.load(prefs, 'conn-a');
      expect(reread.isArchived('archived-in-list'), isTrue);
      expect(reread.isHidden('hidden-in-home'), isTrue);
      expect(prefs.getStringList('archived_sessions_conn-a'), [
        'archived-in-list',
      ]);
      expect(prefs.getStringList('hidden_sessions_conn-a'), ['hidden-in-home']);
    });

    test(
      'chat auto-title survives a rename made from an older screen',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final list = await SessionArchive.load(prefs, 'conn-a');
        // Chat loads the store on its own when the first prompt is sent.
        final chat = await SessionArchive.load(prefs, 'conn-a');
        await chat.autoTitleIfPlaceholder(
          sessionId: 'new-chat',
          currentTitle: 'Untitled',
          prompt: 'Plan the release checklist',
        );
        await list.setTitle('other', 'Renamed in list');

        // The auto-title lives apart from overrides: it only stands in for
        // a placeholder server title.
        final titles = [
          ...?prefs.getStringList('session_titles_conn-a'),
          ...?prefs.getStringList('session_auto_titles_conn-a'),
        ];
        expect(titles.map((row) => row.split('\t').first).toSet(), {
          'new-chat',
          'other',
        });
        expect(list.titleFor('new-chat', 'Untitled'), isNot('Untitled'));
      },
    );

    test('a write notifies readers synchronously', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = await SessionArchive.load(prefs, 'conn-a');
      var notifications = 0;
      final revisions = <int>[];
      store.addListener(() {
        notifications++;
        revisions.add(store.revision);
      });

      final write = store.setTitle('s1', 'New title');
      // Observable before the first await of the write.
      expect(notifications, 1);
      expect(store.titleFor('s1', 'Server'), 'New title');
      await write;
      await store.archive('s2');
      expect(notifications, 2);
      expect(revisions, orderedEquals([...revisions]..sort()));
    });

    test('persists every set before the first await', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = await SessionArchive.load(prefs, 'conn-a');
      final write = store.pin('s1');
      // A reader that re-reads preferences mid-write sees a coherent cut.
      expect(prefs.getStringList('pinned_sessions_conn-a'), ['s1']);
      expect(prefs.getStringList('archived_sessions_conn-a'), isEmpty);
      await write;
    });

    test(
      'an out-of-band preference wipe is adopted on the next load',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final store = await SessionArchive.load(prefs, 'conn-a');
        await store.archive('s1');
        // Connection cleanup removes the keys without going through the store.
        await prefs.remove('archived_sessions_conn-a');

        final reread = await SessionArchive.load(prefs, 'conn-a');
        expect(identical(reread, store), isTrue);
        expect(reread.isArchived('s1'), isFalse);
      },
    );
  });

  group('Home reads the shared store', () {
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

    Future<void> pumpHome(
      WidgetTester tester,
      ConnectionManager manager,
      ApiClient client,
      String visible,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: HomeDashboardScreen(
            connManager: manager,
            clientFactory: (_) => client,
          ),
        ),
      );
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text(visible).evaluate().isNotEmpty) break;
      }
      expect(find.text(visible), findsOneWidget);
      // Let the initial refresh settle so later reads are attributable.
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('a rename on another screen repaints Home in the same frame', (
      tester,
    ) async {
      final (manager, connection) = await setUpManager();
      final client = _CountingHomeClient([
        _session('physical', root: 'logical', title: 'Server title'),
      ]);
      await pumpHome(tester, manager, client, 'Server title');
      final reads = client.sessionReads;

      // Conversations (or the chat auto-title) writes through its own load.
      final other = await SessionArchive.load(manager.prefs, connection.id);
      await other.setSessionTitle(
        _session('physical', root: 'logical'),
        'Renamed elsewhere',
      );
      await tester.pump();

      expect(find.text('Renamed elsewhere'), findsOneWidget);
      expect(find.text('Server title'), findsNothing);
      expect(client.sessionReads, reads, reason: 'no extra network read');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('archiving on another screen drops the Home row at once', (
      tester,
    ) async {
      final (manager, connection) = await setUpManager();
      final kept = _session('kept', title: 'Kept row');
      final archived = _session('gone', title: 'Archived elsewhere');
      final client = _CountingHomeClient([kept, archived]);
      await pumpHome(tester, manager, client, 'Archived elsewhere');
      final reads = client.sessionReads;

      final other = await SessionArchive.load(manager.prefs, connection.id);
      await other.archiveSession(archived);
      await tester.pump();

      expect(find.text('Archived elsewhere'), findsNothing);
      expect(find.text('Kept row'), findsOneWidget);
      expect(client.sessionReads, reads);

      // Restoring it brings the row back from the same retained page.
      await other.unarchiveSession(archived);
      await tester.pump();
      expect(find.text('Archived elsewhere'), findsOneWidget);
      expect(client.sessionReads, reads);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });
}
