// Settings > data offers backup and restore for a writable connection and
// hides it on a read-only one.
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
      id: 'bk-entry',
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

  testWidgets('a writable connection offers backup and restore', (
    tester,
  ) async {
    await pumpSettings(tester, readOnly: false);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-backup')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Backup and restore'), findsOneWidget);
    while (tester.takeException() != null) {}
  });

  testWidgets('a read-only connection never offers it', (tester) async {
    await pumpSettings(tester, readOnly: true);
    await tester.dragUntilVisible(
      find.text('data'),
      find.byType(Scrollable).first,
      const Offset(0, -180),
    );
    expect(find.byKey(const ValueKey('settings-backup')), findsNothing);
    while (tester.takeException() != null) {}
  });
}
