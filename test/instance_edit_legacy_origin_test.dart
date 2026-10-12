// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets(
    'changing gateway cannot preserve its legacy credential at another origin',
    (tester) async {
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
        id: 'legacy-owner',
        label: 'Synthetic legacy',
        host: '127.0.0.1',
        port: 9131,
        apiKey: 'synthetic-origin-A-key',
        dashboardUrl: 'http://127.0.0.1:19119',
      );
      await manager.upsertConnection(original);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: InstanceEditScreen(connManager: manager, initial: original),
        ),
      );
      await tester.pumpAndSettle();
      final gateway = find.byKey(const ValueKey('instance-gateway-url'));
      await tester.ensureVisible(gateway);
      await tester.enterText(gateway, 'http://127.0.0.2:9131');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('instance-save'));
      await tester.scrollUntilVisible(
        save,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(save);
      await tester.pumpAndSettle();
      final saved = manager.getConnections().single;
      expect(
        saved.host != original.host && saved.apiKey == original.apiKey,
        isFalse,
        reason:
            'preserve the original connection or remove old authority; never move its secret',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
