import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/app_header_title.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

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
    headerTitleNotifier.value = kDefaultHeaderTitle;
  });

  /// Settings with the title stored as [stored] (null: never stored).
  Future<SharedPreferences> pumpSettings(
    WidgetTester tester, {
    String? stored,
  }) async {
    SharedPreferences.setMockInitialValues({kHeaderTitlePrefKey: ?stored});
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final connection = SavedConnection(
      id: 'qa',
      label: 'QA',
      host: '192.168.1.20',
      port: 8642,
      apiKey: '',
      dashboardUrl: 'http://192.168.1.20:9119',
    );
    loadHeaderTitle(prefs);

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
    return prefs;
  }

  /// The title shown on the «Nombre de la cabecera» row.
  Future<String?> rowTitle(WidgetTester tester) async {
    final label = find.text('Nombre de la cabecera');
    await tester.scrollUntilVisible(
      label,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    final row = find.ancestor(of: label, matching: find.byType(Column)).first;
    return tester
        .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
        .last
        .data;
  }

  test('a fresh install reads CONSOLE', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    headerTitleNotifier.value = 'OTRO';
    loadHeaderTitle(prefs);
    expect(kDefaultHeaderTitle, 'CONSOLE');
    expect(headerTitleNotifier.value, 'CONSOLE');
  });

  test('the former default, stored but never chosen, reads CONSOLE', () async {
    SharedPreferences.setMockInitialValues({
      kHeaderTitlePrefKey: 'HERMES CONSOLE',
    });
    final prefs = await SharedPreferences.getInstance();
    loadHeaderTitle(prefs);
    expect(headerTitleNotifier.value, 'CONSOLE');
    // Start-up only reads: nothing is rewritten on the way to first paint.
    expect(prefs.getString(kHeaderTitlePrefKey), 'HERMES CONSOLE');
  });

  test('a title the user wrote is never rewritten', () async {
    for (final own in const [
      'Mi servidor',
      'HERMES',
      'HERMES CONSOLE Q',
      'hermes console',
      'Console',
    ]) {
      SharedPreferences.setMockInitialValues({kHeaderTitlePrefKey: own});
      final prefs = await SharedPreferences.getInstance();
      loadHeaderTitle(prefs);
      expect(headerTitleNotifier.value, own);
      await setHeaderTitle(prefs, own);
      expect(headerTitleNotifier.value, own);
      expect(prefs.getString(kHeaderTitlePrefKey), own);
    }
  });

  test(
    'an emptied title, or the former default typed again, is CONSOLE',
    () async {
      SharedPreferences.setMockInitialValues({kHeaderTitlePrefKey: 'SERVER'});
      final prefs = await SharedPreferences.getInstance();
      for (final typed in const [
        '',
        '   ',
        'HERMES CONSOLE',
        ' HERMES CONSOLE ',
      ]) {
        await setHeaderTitle(prefs, 'SERVER');
        await setHeaderTitle(prefs, typed);
        expect(headerTitleNotifier.value, 'CONSOLE');
        expect(prefs.getString(kHeaderTitlePrefKey), 'CONSOLE');
      }
    },
  );

  testWidgets('Settings: a fresh install shows CONSOLE', (tester) async {
    await pumpSettings(tester);
    expect(await rowTitle(tester), 'CONSOLE');
    expect(find.text('HERMES CONSOLE'), findsNothing);
  });

  testWidgets('Settings: the former default, stored, shows CONSOLE', (
    tester,
  ) async {
    await pumpSettings(tester, stored: 'HERMES CONSOLE');
    expect(await rowTitle(tester), 'CONSOLE');
    expect(find.text('HERMES CONSOLE'), findsNothing);
  });

  testWidgets('Ajustes y la cabecera comparten siempre el mismo título', (
    tester,
  ) async {
    final prefs = await pumpSettings(tester, stored: 'HERMES CONSOLE Q');

    await tester.scrollUntilVisible(
      find.text('HERMES CONSOLE Q'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('HERMES CONSOLE Q'), findsOneWidget);

    await setHeaderTitle(prefs, 'SERVER');
    await tester.pump();

    expect(find.text('SERVER'), findsOneWidget);
    expect(find.text('HERMES CONSOLE Q'), findsNothing);
  });
}
