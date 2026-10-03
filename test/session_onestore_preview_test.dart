// One session state (#21), previews: Home recents and Conversations paint the
// same preview line for the same chat, from one helper over the session list
// row (the rule Hermes Desktop's sidebar uses: the session's own preview).
// After a cold start Home only has the list response; it must never claim
// "no visible messages" for a chat Conversations can preview.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/home_recent_sessions.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ListOnlyClient extends ApiClient {
  _ListOnlyClient(this.sessions)
    : super(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  final List<Session> sessions;

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
  }) async => List<Session>.of(sessions);

  @override
  void close() {}
}

double _minutesAgo(int minutes) =>
    DateTime.now().subtract(Duration(minutes: minutes)).millisecondsSinceEpoch /
    1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          if (call.method == 'readAll') return <String, String>{};
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  Future<void> pumpColdHome(WidgetTester tester, List<Session> rows) async {
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
    // Fresh process: no active chats, no in-memory transcripts; only the
    // session list response.
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: HomeDashboardScreen(
          connManager: manager,
          clientFactory: (_) => _ListOnlyClient(rows),
        ),
      ),
    );
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text(rows.first.title).evaluate().isNotEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets(
    'cold start: a Console chat titled from its first prompt keeps a preview',
    (tester) async {
      // Auto-title is derived from the first prompt, so title == preview;
      // the list row carries no last-turn previews.
      const prompt = 'Plan the release checklist';
      final row = Session(
        id: 'console-chat',
        title: prompt,
        model: 'model-a',
        source: 'mobile',
        messageCount: 4,
        isActive: false,
        preview: prompt,
        startedAt: _minutesAgo(5),
      );
      await pumpColdHome(tester, [row]);
      final strings = await Strings.delegate.load(const Locale('en'));

      final expected = sessionListPreview(row);
      expect(expected, isNotNull, reason: 'Conversations previews this row');
      expect(find.text(strings.sessionPreviewUnavailable), findsNothing);
      expect(find.byKey(ValueKey('preview-$expected')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Home and Conversations paint the same preview line', (
    tester,
  ) async {
    // A Desktop chat with 42 messages: first prompt plus last-turn previews.
    final row = Session(
      id: 'desktop-chat',
      title: 'Release review',
      model: 'model-a',
      source: 'desktop',
      messageCount: 42,
      isActive: false,
      preview: 'Review the release notes for 1.2.15',
      lastUserPreview: 'And the changelog?',
      lastAssistantPreview: 'The changelog is ready.',
      startedAt: _minutesAgo(25),
    );
    await pumpColdHome(tester, [row]);

    final conversations = sessionListPreview(row)!;
    expect(find.byKey(ValueKey('preview-$conversations')), findsOneWidget);
    expect(find.text('The changelog is ready.'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  test('the shared rule is the session preview, as in Desktop', () {
    final row = Session(
      id: 's',
      title: 'Title',
      model: 'm',
      source: 'mobile',
      messageCount: 4,
      isActive: false,
      preview: 'First prompt',
      lastUserPreview: 'Last prompt',
      lastAssistantPreview: 'Last answer',
      startedAt: 1,
    );
    expect(sessionListPreview(row), 'First prompt');
    // Without a session preview the last turn still gives a line.
    final noPreview = row.copyWith(preview: '');
    expect(sessionListPreview(noPreview), 'Last answer');
  });
}
