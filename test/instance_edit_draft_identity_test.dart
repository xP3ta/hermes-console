// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'support/connection_editor_actions.dart';

void main() {
  testWidgets('new editor keeps the login owner through retry and save', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final storage = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?) ?? {};
          if (call.method == 'readAll') return storage;
          if (call.method == 'read') return storage[args['key']];
          if (call.method == 'write') storage[args['key']] = args['value'];
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    addTearDown(manager.dispose);
    final client = MockClient((r) async => http.Response('{}', 200));
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: InstanceEditScreen(
            connManager: manager,
            prefill: SavedConnection(
              id: 'ignored-prefill-id',
              label: 'Synthetic new',
              host: '127.0.0.1',
              port: 9131,
              apiKey: '',
              dashboardUrl: 'http://127.0.0.1:19119',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<String> openLogin() async {
        final action = find.byKey(const ValueKey('instance-dashboard-sign-in'));
        await revealEditorControl(tester, action);
        await tester.tap(action);
        await tester.pumpAndSettle();
        final route = tester.widget<DashboardSetupScreen>(
          find.byType(DashboardSetupScreen),
        );
        final id = route.connection.id;
        Navigator.of(tester.element(find.byType(DashboardSetupScreen))).pop();
        await tester.pumpAndSettle();
        return id;
      }

      final first = await openLogin();
      final second = await openLogin();
      expect(
        second,
        first,
        reason: 'retry must not mint a different OAuth owner',
      );
      final save = find.byKey(const ValueKey('instance-save'));
      await tester.scrollUntilVisible(
        save,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(manager.getConnections().single.id, first);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });
}
