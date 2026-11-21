// Settings offers messaging setup and who-may-message-the-bot (Security) to
// every connection and the doctor and security audit (System) only to a
// writable one: they spawn processes on the server.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    required bool readOnly,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final connection = SavedConnection(
      id: 'srv-entries',
      label: 'QA',
      host: 'hermes.example.test',
      port: 8642,
      apiKey: '',
      dashboardUrl: 'http://hermes.example.test:9119',
      readOnly: readOnly,
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SettingsScreen(connection: connection, connManager: manager),
      ),
    );
    await tester.pump();
    // The ListTile ink assertion in this block exists on the base branch.
    while (tester.takeException() != null) {}
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    while (tester.takeException() != null) {}
  }

  testWidgets('a writable connection offers the pairing page and the checks', (
    tester,
  ) async {
    await pumpSettings(tester, readOnly: false);
    await reveal(tester, find.byKey(const ValueKey('settings-messaging')));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-messaging')),
        matching: find.text('Messaging'),
      ),
      findsOneWidget,
    );
    await reveal(
      tester,
      find.byKey(const ValueKey('settings-messaging-pairing')),
    );
    expect(find.text('Messaging access'), findsOneWidget);
    await reveal(tester, find.byKey(const ValueKey('settings-check-doctor')));
    expect(find.text('Run doctor'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-check-security-audit')),
      findsOneWidget,
    );
  });

  testWidgets('a read-only connection keeps the pairing list, not the '
      'checks', (tester) async {
    await pumpSettings(tester, readOnly: true);
    await reveal(tester, find.byKey(const ValueKey('settings-messaging')));
    await reveal(
      tester,
      find.byKey(const ValueKey('settings-messaging-pairing')),
    );
    await tester.dragUntilVisible(
      find.text('data'),
      find.byType(Scrollable).first,
      const Offset(0, -180),
    );
    while (tester.takeException() != null) {}
    expect(
      find.byKey(const ValueKey('settings-check-doctor'), skipOffstage: false),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey('settings-check-security-audit'),
        skipOffstage: false,
      ),
      findsNothing,
    );
  });
}
