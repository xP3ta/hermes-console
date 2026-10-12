// Session detail reads the shared per-connection SessionArchive: an archive
// or rename made by another screen repaints it in place, with no network read.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/session_detail_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'an external archive and rename repaint session detail without a read',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var requests = 0;
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:8642',
        apiKey: 'key',
        httpClient: MockClient((_) async {
          requests++;
          return http.Response('{}', 404);
        }),
      );
      final connection = SavedConnection(
        id: 'connection-detail-store',
        label: 'Instance',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'key',
        kind: InstanceKind.vps,
      );
      const session = Session(
        id: 'session-tip',
        lineageRootId: 'session-root',
        title: 'Server title',
        model: 'model-a',
        source: 'mobile',
        messageCount: 1,
        isActive: false,
        preview: '',
        startedAt: 1784500000,
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: SessionDetailScreen(
            connection: connection,
            session: session,
            client: api,
            skipInitialSessionRefresh: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final baseline = requests;
      final s = await Strings.delegate.load(const Locale('es'));
      final archiveRow = find.byKey(const ValueKey('session-detail-archive'));
      expect(
        find.descendant(of: archiveRow, matching: find.text(s.sesUiArchive)),
        findsOneWidget,
      );
      expect(find.text('Server title'), findsWidgets);

      // Another screen (Conversations, Home) writes the same shared store.
      final prefs = await SharedPreferences.getInstance();
      final shared = await SessionArchive.load(prefs, connection.id);
      await tester.runAsync(() async {
        await shared.archiveSession(session);
        await shared.setSessionTitle(session, 'Renamed elsewhere');
      });
      await tester.pump();

      expect(
        find.descendant(of: archiveRow, matching: find.text(s.sesUiUnarchive)),
        findsOneWidget,
        reason: 'the archive made elsewhere must repaint detail',
      );
      expect(find.text('Renamed elsewhere'), findsWidgets);
      expect(find.text('Server title'), findsNothing);
      expect(requests, baseline, reason: 'no network read for a local change');
    },
  );
}
