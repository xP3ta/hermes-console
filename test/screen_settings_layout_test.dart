import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// Settings presentation: the featured instance card on top (brand + active
// instance) and the grouped rows with a right-aligned value.

Future<void> _pump(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues(const {});
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  final connection = SavedConnection(
    id: 'layout-settings',
    label: 'Servidor local',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'k',
    dashboardUrl: 'http://127.0.0.1:9119',
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: SettingsScreen(connection: connection, connManager: manager),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('phone: featured instance card above the grouped rows', (
    tester,
  ) async {
    await _pump(tester, const Size(400, 900));
    final card = find.byKey(const ValueKey('settings-instance-card'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('HERMES CONSOLE')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining('Active instance · Servidor local'),
      ),
      findsOneWidget,
    );
    final manage = find.widgetWithText(HermesNavRow, 'Manage instances');
    expect(manage, findsOneWidget);
    expect(
      tester.getTopLeft(card).dy,
      lessThan(tester.getTopLeft(manage).dy),
      reason: 'card first, then the rows',
    );
    expect(
      find.descendant(of: manage, matching: find.text('0')),
      findsOneWidget,
      reason: 'value shown on the right',
    );
    expect(
      find.descendant(of: manage, matching: find.byIcon(Icons.chevron_right)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('fold open: categories panel left, detail right', (tester) async {
    await _pump(tester, const Size(1100, 800));
    expect(find.byKey(const ValueKey('settings-categories')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-categories')),
        matching: find.byType(HermesPanel),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-detail-pane')),
        matching: find.byKey(const ValueKey('settings-instance-card')),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
