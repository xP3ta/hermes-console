// Settings gains ONE row, "Advanced", and nothing else. Diagnostics lives one
// level down and nothing of it is read when Settings opens.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/advanced_settings_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
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

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  // Building the "Data" block of Settings (below the new row) trips a framework
  // assertion about a `ListTile` inside a `DecoratedBox`. It happens on the
  // base too and has nothing to do with this row; only that message is let
  // through, anything else still fails the test.
  void letKnownAssertionThrough(WidgetTester tester) {
    final error = tester.takeException();
    if (error == null) return;
    expect(
      error.toString(),
      contains('ListTile background color or ink splashes may be invisible'),
    );
  }

  Finder advancedRow() => find.byWidgetPredicate(
    (widget) => widget is HermesNavRow && widget.title == 'Avanzado',
  );

  Future<void> scrollToAdvanced(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      advancedRow(),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    letKnownAssertionThrough(tester);
  }

  Future<void> pumpSettings(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final connection = SavedConnection(
      id: 'qa-adv',
      label: 'QA',
      host: 'hermes.example.test',
      port: 8642,
      apiKey: '',
      dashboardUrl: 'http://hermes.example.test:9119',
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SettingsScreen(connection: connection, connManager: manager),
      ),
    );
    await tester.pump();
    letKnownAssertionThrough(tester);
  }

  testWidgets('shows exactly one Advanced row', (tester) async {
    await pumpSettings(tester);
    await scrollToAdvanced(tester);
    expect(advancedRow(), findsOneWidget);
  });

  testWidgets('nothing of Diagnostics is on the Settings screen', (
    tester,
  ) async {
    await pumpSettings(tester);
    await scrollToAdvanced(tester);
    final s = Strings.of(tester.element(find.byType(SettingsScreen)));
    expect(find.text(s.sd1215Diagnostics), findsNothing);
    expect(find.text(s.sd1215Doctor), findsNothing);
  });

  testWidgets('the row opens the Advanced screen', (tester) async {
    await pumpSettings(tester);
    await scrollToAdvanced(tester);
    await tester.tap(advancedRow());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(AdvancedSettingsScreen), findsOneWidget);
  });
}
