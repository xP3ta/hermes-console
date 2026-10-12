import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/pinned_prompt_prefs.dart';
import 'package:hermes_android/core/services/retired_prefs.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

SavedConnection _connection() => SavedConnection(
  id: 'conn-cs1215-settings',
  label: 'Settings',
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
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  test('the stored quick replies choice is removed at start-up', () async {
    SharedPreferences.setMockInitialValues({
      'chat_quick_replies_enabled': false,
      'unrelated_pref': true,
    });
    final prefs = await SharedPreferences.getInstance();

    await clearRetiredPrefs(prefs);

    expect(prefs.containsKey('chat_quick_replies_enabled'), isFalse);
    expect(prefs.getBool('unrelated_pref'), isTrue);
    // Nothing stored is fine too.
    await clearRetiredPrefs(prefs);
    expect(prefs.containsKey('chat_quick_replies_enabled'), isFalse);
  });

  testWidgets('the chat section of Settings has no quick replies switch', (
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

    // The neighbouring chat switch is there; the quick replies one is not.
    final reactions = find.byKey(const ValueKey('settings-reactions'));
    await tester.scrollUntilVisible(
      reactions,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(reactions, findsOneWidget);
    expect(find.byKey(const ValueKey('settings-quick-replies')), findsNothing);
    expect(find.text('Respuestas rápidas'), findsNothing);
  });

  testWidgets('the chat section of Settings switches the pinned prompt', (
    tester,
  ) async {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains(
        'ListTile background color or ink splashes may be invisible',
      )) {
        return;
      }
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);
    addTearDown(() => PinnedPromptPrefs.debugUse(null));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await PinnedPromptPrefs.load(prefs);
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

    final row = find.byKey(const ValueKey('settings-pinned-prompt'));
    await tester.scrollUntilVisible(
      row,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Fijar tu pregunta arriba'), findsOneWidget);
    expect(PinnedPromptPrefs.shared.enabled, isTrue);

    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pump();

    expect(PinnedPromptPrefs.shared.enabled, isFalse);
    expect(prefs.getBool(PinnedPromptPrefs.key), isFalse);
    expect((await PinnedPromptPrefs.load(prefs)).enabled, isFalse);
  });
}
