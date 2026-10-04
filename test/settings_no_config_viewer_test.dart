import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/bridge_file_editor_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
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

  testWidgets('Settings no longer offers the config.yaml viewer', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final connection = SavedConnection(
      id: 'qa',
      label: 'QA',
      host: '192.168.1.20',
      port: 8642,
      apiKey: 'k',
      dashboardUrl: 'http://192.168.1.20:9119',
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

    final s = Strings.of(tester.element(find.byType(SettingsScreen)));
    // The security group used to end with the viewer row.
    await tester.scrollUntilVisible(
      find.text(s.setPermissions),
      180,
      scrollable: find.byType(Scrollable).first,
    );

    // Rows within the cache extent are built too, so the row that used to
    // follow Permissions is collected without scrolling into later sections.
    final titles = <String>{};
    void collect() {
      for (final row in tester.widgetList<HermesNavRow>(
        find.byType(HermesNavRow, skipOffstage: false),
      )) {
        titles.add('${row.title} ${row.subtitle ?? ''}');
      }
    }

    collect();

    expect(titles, contains(contains(s.setPermissions)));
    expect(
      titles.where((t) => t.toLowerCase().contains('config.yaml')),
      isEmpty,
    );
    expect(find.textContaining('config.yaml'), findsNothing);
    expect(find.byType(BridgeFileEditorScreen), findsNothing);
  });
}
