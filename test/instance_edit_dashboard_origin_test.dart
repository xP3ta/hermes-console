// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/dashboard_setup_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'support/connection_editor_actions.dart';

void main() {
  for (final target in [
    'http://127.0.0.2:19119',
    'http://127.0.0.1:19120',
    'https://127.0.0.1:19119',
  ]) {
    testWidgets('Dashboard legacy authority cannot move to $target', (
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
            if (call.method == 'delete') storage.remove(args['key']);
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
      final original = SavedConnection(
        id: 'legacy-dashboard-owner',
        label: 'Synthetic Dashboard',
        host: '127.0.0.1',
        port: 9131,
        apiKey: 'synthetic-gateway',
        dashboardUrl: 'http://127.0.0.1:19119',
        dashboardAuthMode: AuthMode.basicAuth,
      );
      await manager.upsertConnection(original);
      await manager.setDashboardSecrets(
        original.id,
        sessionToken: 'synthetic-session',
        username: 'synthetic-user',
        password: 'synthetic-password',
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: InstanceEditScreen(connManager: manager, initial: original),
        ),
      );
      await tester.pumpAndSettle();
      await openEditorAdvanced(tester);
      final dashboard = find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == original.dashboardUrl,
      );
      await revealEditorControl(tester, dashboard);
      await tester.enterText(dashboard, target);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final signIn = find.byKey(const ValueKey('instance-dashboard-sign-in'));
      await revealEditorControl(tester, signIn);
      expect(signIn.hitTestable(), findsOneWidget);
      await tester.tap(signIn);
      await tester.pumpAndSettle();
      expect(
        find.byType(DashboardSetupScreen),
        findsNothing,
        reason: 'changed authority must be rejected before opening login',
      );
      final save = find.byKey(const ValueKey('instance-save'));
      await revealEditorControl(tester, save);
      expect(save.hitTestable(), findsOneWidget);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final saved = manager.getConnections().single;
      final secrets = await manager.getDashboardSecrets(saved.id);
      expect(
        saved.dashboardUrl != original.dashboardUrl &&
            (secrets.sessionToken == 'synthetic-session' ||
                secrets.password == 'synthetic-password'),
        isFalse,
        reason: 'no saved credential may acquire a different Dashboard origin',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
