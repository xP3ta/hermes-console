// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/design/content.dart';
import 'package:hermes_android/core/design/modal.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'support/connection_editor_actions.dart';

void main() {
  for (final locale in ['en', 'es']) {
    testWidgets(
      'manual auth selector preserves both drafts and authority in $locale',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = <String, String>{};
        const channel = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              final args = (call.arguments as Map?) ?? {};
              if (call.method == 'readAll') return storage;
              if (call.method == 'read') return storage[args['key']];
              if (call.method == 'write') storage[args['key']] = args['value'];
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final prefs = await SharedPreferences.getInstance();
        final manager = await ConnectionManager.create(prefs);
        addTearDown(manager.dispose);
        final initial = SavedConnection(
          id: 'synthetic-selector-owner',
          label: 'Existing',
          host: '127.0.0.1',
          port: 9131,
          apiKey: 'synthetic-gateway',
          dashboardUrl: 'http://127.0.0.1:19119',
          dashboardAuthMode: AuthMode.sessionToken,
        );
        await manager.upsertConnection(initial);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final requests = <http.Request>[];
        final client = MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 200);
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(locale),
              localizationsDelegates: Strings.localizationsDelegates,
              supportedLocales: Strings.supportedLocales,
              home: InstanceEditScreen(connManager: manager, initial: initial),
            ),
          );
          await tester.pumpAndSettle();
          await openEditorAdvanced(tester);
          final selector = find.byKey(
            const ValueKey('dashboard-manual-auth-mode'),
          );
          await tester.ensureVisible(selector);
          final strings = Strings.of(tester.element(selector));
          expect(tester.widget(selector), isA<HermesSelectRow>());
          final row = tester.widget<HermesSelectRow>(selector);
          expect(row.title, strings.ieDashboardAuth);
          expect(row.value, strings.ieDashboardAuthSession);
          final semantics = tester.ensureSemantics();
          expect(
            find.bySemanticsLabel(
              '${strings.ieDashboardAuth}: ${strings.ieDashboardAuthSession}',
            ),
            findsOneWidget,
          );
          semantics.dispose();
          expect(tester.getSize(selector).height, greaterThanOrEqualTo(48));
          final token = find.byKey(const ValueKey('dashboard-manual-token'));
          await tester.ensureVisible(token);
          await tester.enterText(token, 'synthetic-token-draft');
          await tester.pumpAndSettle();
          Future<void> choose(AuthMode mode, String label) async {
            FocusManager.instance.primaryFocus?.unfocus();
            await tester.pumpAndSettle();
            await tester.ensureVisible(selector);
            await tester.pumpAndSettle();
            await tester.tap(selector);
            await tester.pumpAndSettle();
            final options = tester.widget<HermesOptionList<AuthMode>>(
              find.byType(HermesOptionList<AuthMode>),
            );
            expect(options.options.map((o) => o.value), [
              AuthMode.sessionToken,
              AuthMode.basicAuth,
            ]);
            expect(options.options.map((o) => o.label), [
              strings.ieDashboardAuthSession,
              strings.ieDashboardAuthBasic,
            ]);
            await tester.tap(find.text(label).last);
            await tester.pumpAndSettle();
            expect(tester.widget<HermesSelectRow>(selector).value, label);
          }

          await choose(AuthMode.basicAuth, strings.ieDashboardAuthBasic);
          final user = find.byKey(const ValueKey('dashboard-manual-user'));
          final password = find.byKey(
            const ValueKey('dashboard-manual-password'),
          );
          await revealEditorControl(tester, user);
          await tester.ensureVisible(user);
          await tester.enterText(user, 'synthetic-user-draft');
          await tester.ensureVisible(password);
          await tester.enterText(password, 'synthetic-password-draft');
          await tester.pumpAndSettle();
          await choose(AuthMode.sessionToken, strings.ieDashboardAuthSession);
          expect(
            tester.widget<TextField>(token).controller!.text,
            'synthetic-token-draft',
          );
          await choose(AuthMode.basicAuth, strings.ieDashboardAuthBasic);
          expect(
            tester.widget<TextField>(user).controller!.text,
            'synthetic-user-draft',
          );
          expect(
            tester.widget<TextField>(password).controller!.text,
            'synthetic-password-draft',
          );
          await choose(AuthMode.sessionToken, strings.ieDashboardAuthSession);
          // Opening and cancelling the surface must not alter the selected mode.
          await tester.ensureVisible(selector);
          await tester.tap(selector);
          await tester.pumpAndSettle();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(
            tester.widget<HermesSelectRow>(selector).value,
            strings.ieDashboardAuthSession,
          );
          expect(requests, isEmpty);
          expect(
            manager.getConnections().single.dashboardAuthMode,
            AuthMode.sessionToken,
          );
          final save = find.byKey(const ValueKey('instance-save')).last;
          await tester.ensureVisible(save);
          await tester.tap(save);
          await tester.pumpAndSettle();
          final saved = manager.getConnections().single;
          expect(saved.id, initial.id);
          expect(saved.host, initial.host);
          expect(saved.port, initial.port);
          expect(saved.apiKey, initial.apiKey);
          expect(saved.dashboardUrl, initial.dashboardUrl);
          expect(saved.dashboardAuthMode, AuthMode.sessionToken);
          final secrets = await manager.getDashboardSecrets(saved.id);
          expect(secrets.sessionToken, 'synthetic-token-draft');
          expect(requests, isEmpty);
          expect(
            prefs.getKeys().any(
              (k) => '${prefs.get(k)}'.contains('synthetic-token-draft'),
            ),
            isFalse,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }, () => client);
      },
    );
  }
}
