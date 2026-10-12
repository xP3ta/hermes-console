import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Synthetic HTTP fixture using the real Dashboard profile query contract.
// This is a route/widget reproduction, not a device observation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'use_floating_dock': false});
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  testWidgets(
    'Settings Chat opens the active profile model and Back keeps settings',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final connection = SavedConnection(
        id: 'navigation-fixture',
        label: 'Fixture',
        host: 'fixture.invalid',
        port: 8642,
        apiKey: '',
        dashboardUrl: 'https://fixture.invalid:9119',
      );
      await manager.setActiveProfile(connection.id, 'profile-a');
      final modelReads = <String>[];
      final client = MockClient((request) async {
        if (request.url.path == '/') {
          return http.Response(
            'window.__HERMES_SESSION_TOKEN__="fixture-token";',
            200,
          );
        }
        final profile = request.url.queryParameters['profile'] ?? 'default';
        if (request.url.path == '/api/model/info') {
          modelReads.add(profile);
          return http.Response(
            jsonEncode({'model': '$profile-model', 'provider': 'fixture'}),
            200,
          );
        }
        if (request.url.path == '/api/model/options') {
          return http.Response(
            jsonEncode({
              'providers': [
                {
                  'slug': 'fixture',
                  'name': 'Fixture',
                  'authenticated': true,
                  'models': ['$profile-model'],
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      tester.view.physicalSize = const Size(412, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await http.runWithClient(() async {
        // Unrelated baseline debug diagnostic in the lazily-built cleanup row.
        // Consume only this exact diagnostic, never product/test failures.
        final previousErrorHandler = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.exceptionAsString().startsWith(
            'ListTile background color or ink splashes may be invisible.',
          )) {
            return;
          }
          previousErrorHandler?.call(details);
        };
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            theme: AppTheme.hermesRedDark,
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: SettingsScreen(connection: connection, connManager: manager),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final tile = find.text('Active model');
        await tester.scrollUntilVisible(
          tile,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump(const Duration(milliseconds: 300));
        FlutterError.onError = previousErrorHandler;
        expect(find.text('profile-a-model'), findsOneWidget);
        expect(modelReads, isNot(contains('default')));
        await tester.tap(tile);
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.byType(ModelsScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Active model'), findsOneWidget);
        expect(manager.activeProfileFor(connection.id), 'profile-a');
      }, () => client);
    },
  );
}
