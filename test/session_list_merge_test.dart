import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart' show hermesRouteObserver;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session _session({
  required String id,
  required String title,
  required String source,
  required double updatedAt,
  String? parentSessionId,
  String? profile,
}) => Session(
  id: id,
  title: title,
  model: source == 'mobile-draft' ? 'draft-model' : 'remote-model',
  source: source,
  messageCount: source == 'mobile-draft' ? 0 : 4,
  isActive: true,
  preview: title,
  startedAt: updatedAt - 10,
  updatedAt: updatedAt,
  parentSessionId: parentSessionId,
  profile: profile,
);

class _SessionListApiClient extends ApiClient {
  _SessionListApiClient(this.remoteSessions)
    : super(
        baseUrl: 'https://hermes.test',
        apiKey: 'test-key',
        connectionId: 'conn-merge',
        httpClient: MockClient((_) async => throw UnimplementedError()),
      );

  final List<Session> remoteSessions;
  bool healthy = true;
  int sessionReads = 0;

  @override
  Future<bool> healthCheck() async => healthy;

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
  }) async {
    sessionReads++;
    if (!healthy) throw StateError('offline');
    return remoteSessions;
  }
}

Widget _host(Widget child) => MaterialApp(
  navigatorObservers: [hermesRouteObserver],
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: child,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a remote session stays authoritative over a newer local draft', () {
    final remote = _session(
      id: 'shared-id',
      title: 'Remote title',
      source: 'mobile',
      updatedAt: 10,
      parentSessionId: 'remote-parent',
    );
    final newerDraft = _session(
      id: 'shared-id',
      title: 'Draft title',
      source: 'mobile-draft',
      updatedAt: 20,
    );

    final merged = mergeRemoteSessionsWithDrafts([remote], [newerDraft]);

    expect(merged, hasLength(1));
    expect(merged.single, isNot(same(remote)));
    expect(merged.single.title, remote.title);
    expect(merged.single.model, remote.model);
    expect(merged.single.source, remote.source);
    expect(merged.single.parentSessionId, 'remote-parent');
    expect(merged.single.hasLocalDraft, isTrue);
  });

  test('offline merge keeps visible remotes and adds new drafts', () {
    final remote = _session(
      id: 'remote-id',
      title: 'Remote title',
      source: 'mobile',
      updatedAt: 10,
    );
    final draft = _session(
      id: 'draft-id',
      title: 'Draft title',
      source: 'mobile-draft',
      updatedAt: 20,
    );

    final merged = mergeRemoteSessionsWithDrafts([remote], [draft]);

    expect(merged.map((session) => session.id), ['remote-id', 'draft-id']);
  });

  test('a new draft is included when no remote session has its id', () {
    final freshDraft = _session(
      id: 'draft-id',
      title: 'Fresh draft',
      source: 'mobile-draft',
      updatedAt: 20,
    );

    final merged = mergeRemoteSessionsWithDrafts(const [], [freshDraft]);

    expect(merged.single.id, freshDraft.id);
    expect(merged.single.isDraftOnly, isTrue);
    expect(merged.single.hasLocalDraft, isTrue);
  });

  test('same opaque id in two profiles never deduplicates across owners', () {
    final remote = _session(
      id: 'shared-id',
      title: 'Remote coding',
      source: 'gateway',
      updatedAt: 10,
      profile: 'coding',
    );
    final otherProfileDraft = _session(
      id: 'shared-id',
      title: 'Draft research',
      source: 'mobile-draft',
      updatedAt: 20,
      profile: 'research',
    );

    final merged = mergeRemoteSessionsWithDrafts([remote], [otherProfileDraft]);

    expect(merged, hasLength(2));
    expect(merged.map((session) => session.profile), {'coding', 'research'});
    expect(
      merged.firstWhere((session) => session.profile == 'coding').hasLocalDraft,
      isFalse,
    );
    expect(
      merged
          .firstWhere((session) => session.profile == 'research')
          .hasLocalDraft,
      isTrue,
    );
  });

  testWidgets(
    'draft invalidation: save and clear reload badges without refresh',
    (tester) async {
      final values = <String, String>{};
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        final args = call.arguments as Map?;
        switch (call.method) {
          case 'readAll':
            return Map<String, String>.of(values);
          case 'read':
            return values[args!['key']];
          case 'write':
            values[args!['key'] as String] = args['value'] as String;
          case 'delete':
            values.remove(args!['key']);
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final remote = _session(
        id: 'canonical-badge',
        title: 'Real conversation',
        source: 'mobile',
        updatedAt: 1,
      );
      final client = _SessionListApiClient([remote]);
      final connection = SavedConnection(
        id: 'conn-merge',
        label: 'QA',
        host: 'hermes.test',
        port: 443,
        apiKey: '',
        useHttps: true,
        kind: InstanceKind.vps,
      );
      await tester.pumpWidget(
        _host(
          SessionListScreen(
            connection: connection,
            connManager: manager,
            clientOverride: client,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final badge = find.byKey(const ValueKey('session-draft-canonical-badge'));
      expect(badge, findsNothing);
      final store = ChatDraftStore(prefs);
      await store.save(
        connection.id,
        'canonical-badge',
        'unsent text',
        const [],
      );
      await tester.pumpAndSettle();
      expect(badge, findsOneWidget);
      expect(find.text('unsent text'), findsNothing);
      expect(find.text('Real conversation'), findsWidgets);
      await store.clear(connection.id, 'canonical-badge');
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
      expect(find.text('Real conversation'), findsWidgets);
      await store.save(
        connection.id,
        'canonical-badge',
        'offline draft',
        const [],
      );
      await tester.pumpAndSettle();
      expect(badge, findsOneWidget);
      client.healthy = false;
      await store.clear(connection.id, 'canonical-badge');
      await tester.pumpAndSettle();
      expect(
        badge,
        findsNothing,
        reason: 'offline clear must retire cached badges',
      );
      expect(find.text('Real conversation'), findsWidgets);
      final readsBeforeNeighbors = client.sessionReads;
      await store.save(
        'other-connection',
        'canonical-badge',
        'neighbor',
        const [],
      );
      await store.save(
        connection.id,
        'canonical-badge',
        'other owner',
        const [],
        profile: 'work',
      );
      await tester.pumpAndSettle();
      expect(client.sessionReads, readsBeforeNeighbors);
      expect(badge, findsNothing);
      client.healthy = true;
      final navigator = Navigator.of(
        tester.element(find.byType(SessionListScreen)),
      );
      navigator.push(MaterialPageRoute<void>(builder: (_) => const SizedBox()));
      await tester.pumpAndSettle();
      await store.save(
        connection.id,
        'canonical-badge',
        'saved under chat',
        const [],
      );
      await tester.pumpAndSettle();
      expect(client.sessionReads, readsBeforeNeighbors);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(
        badge,
        findsOneWidget,
        reason: 'returning route reloads local drafts',
      );
      await store.clear(connection.id, 'canonical-badge');
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
    },
  );

  testWidgets(
    'the list keeps remote metadata during fetch and an offline blip',
    (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final secureStore = <String, String>{};
      final drafts = <String, String>{
        ChatDraftStore.keyForTesting(
          'conn-merge',
          'shared-id',
          profile: 'default',
        ): jsonEncode({
          'savedAt': now,
          'text': 'Newer draft title',
          'attachments': const [],
        }),
        ChatDraftStore.keyForTesting(
          'conn-merge',
          'draft-only',
          profile: 'default',
        ): jsonEncode({
          'savedAt': now,
          'text': 'Draft only title',
          'attachments': const [],
        }),
      };
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              switch (call.method) {
                case 'readAll':
                  return Map<String, String>.of(secureStore);
                case 'read':
                  return secureStore[(call.arguments as Map)['key']];
                case 'write':
                  final args = call.arguments as Map;
                  secureStore[args['key'] as String] = args['value'] as String;
                case 'delete':
                  secureStore.remove((call.arguments as Map)['key']);
              }
              return null;
            },
          );
      addTearDown(
        () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(
                'plugins.it_nomads.com/flutter_secure_storage',
              ),
              null,
            ),
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      secureStore.addAll(drafts);
      final remote = _session(
        id: 'shared-id',
        title: 'Authoritative remote title',
        source: 'mobile',
        updatedAt: 1,
      );
      final client = _SessionListApiClient([remote]);
      final connection = SavedConnection(
        id: 'conn-merge',
        label: 'QA',
        host: 'hermes.test',
        port: 443,
        apiKey: 'test-key',
        useHttps: true,
        kind: InstanceKind.vps,
      );

      await tester.pumpWidget(
        _host(
          SessionListScreen(
            connection: connection,
            connManager: manager,
            clientOverride: client,
          ),
        ),
      );
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text('Draft only title').evaluate().isNotEmpty) break;
      }

      expect(find.text('Authoritative remote title'), findsWidgets);
      expect(find.text('Newer draft title'), findsNothing);
      expect(find.text('Draft only title'), findsWidgets);
      expect(find.byKey(const ValueKey('session-draft-shared-id')), findsOne);
      expect(find.byKey(const ValueKey('session-draft-draft-only')), findsOne);

      client.healthy = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Authoritative remote title'), findsWidgets);
      expect(find.text('Newer draft title'), findsNothing);
      expect(find.text('Draft only title'), findsWidgets);
      expect(find.byKey(const ValueKey('session-draft-shared-id')), findsOne);
      expect(find.byKey(const ValueKey('session-draft-draft-only')), findsOne);
      expect(tester.takeException(), isNull);
    },
  );
}
