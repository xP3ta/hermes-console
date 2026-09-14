import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  testWidgets('Ajustes no expone la configuración de compresión automática', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final connection = SavedConnection(
      id: 'settings-without-compression',
      label: 'Hermes',
      host: '127.0.0.1',
      port: 8642,
      apiKey: '',
      dashboardUrl: 'http://127.0.0.1:9119',
    );

    tester.view.physicalSize = const Size(1080, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SettingsScreen(connection: connection, connManager: manager),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('compression-config-card')), findsNothing);
    expect(find.text('Compresión automática'), findsNothing);
    expect(find.text('Comprimir automáticamente'), findsNothing);
  });
}
