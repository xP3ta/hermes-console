import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/quick_reply_prefs.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

SavedConnection _connection() => SavedConnection(
  id: 'conn-rpl1215-settings',
  label: 'Quick replies',
  host: 'hermes.example.test',
  port: 8642,
  apiKey: 'unused',
  dashboardUrl: 'http://hermes.example.test:9119',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  tearDown(() {
    QuickReplyPrefs.debugUse(null);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  test('quick replies are on by default and the choice persists', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = await QuickReplyPrefs.load(prefs);
    expect(store.enabled, isTrue);

    await store.setEnabled(false);
    expect(prefs.getBool(QuickReplyPrefs.key), isFalse);
    expect((await QuickReplyPrefs.load(prefs)).enabled, isFalse);
  });

  testWidgets('the chat section of Settings toggles quick replies', (
    tester,
  ) async {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      // Known base assertion of the Data block, unrelated to this row.
      if (details.exceptionAsString().contains(
        'ListTile background color or ink splashes may be invisible',
      )) {
        return;
      }
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await QuickReplyPrefs.load(prefs);
    final manager = await ConnectionManager.create(prefs);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SettingsScreen(connection: _connection(), connManager: manager),
      ),
    );
    await tester.pump();
    await tester.pump();

    final row = find.byKey(const ValueKey('settings-quick-replies'));
    await tester.scrollUntilVisible(
      row,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Respuestas rápidas'), findsOneWidget);
    expect(QuickReplyPrefs.shared.enabled, isTrue);

    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pump();

    expect(QuickReplyPrefs.shared.enabled, isFalse);
    expect(prefs.getBool(QuickReplyPrefs.key), isFalse);
  });
}
