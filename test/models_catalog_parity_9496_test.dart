import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/bot_profile_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Synthetic single immutable snapshot, not a device/server observation.
// REST twin: hermes_cli/web_routers/models.py:138-168.
// Desktop consumes authenticated and unavailable_models independently:
// apps/desktop/src/components/model-picker.tsx:345.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final selected in ['fixture-free', 'fixture-missing']) {
    testWidgets(
      'same profile snapshot keeps the authenticated free tier selectable on Bot and Models ($selected)',
      (tester) async {
        final snapshot = <String, dynamic>{
          'model': selected,
          'provider': 'nous',
          'providers': [
            {
              'slug': 'nous',
              'name': 'Nous',
              'authenticated': true,
              'free_tier': true,
              'models': ['fixture-free', 'fixture-retired'],
              'unavailable_models': ['fixture-retired'],
            },
          ],
        };
        final requests = <String>[];
        final bot = BotProfileClient((method, params) async {
          expect(method, 'model.options');
          expect(params['profile'], 'profile-a');
          expect(params['explicit_only'], true);
          requests.add('bot:profile-a');
          return snapshot;
        });
        final botCatalog = await bot.botModelOptions('profile-a');
        final desktop = DesktopModelCatalog.fromJson(snapshot);
        expect(
          botCatalog.providerFor('nous')!.isModelUsable('fixture-free'),
          true,
        );
        expect(
          desktop.providerFor('nous')!.isModelUsable('fixture-retired'),
          false,
        );
        final dashboard = DashboardClient(
          host: 'fixture.local',
          manualToken: 'fixture-token',
          httpClientOverride: MockClient((request) async {
            expect(request.url.queryParameters['profile'], 'profile-a');
            requests.add('models:profile-a');
            if (request.url.path == '/api/model/info') {
              return http.Response(jsonEncode(snapshot), 200);
            }
            if (request.url.path == '/api/model/options') {
              return http.Response(jsonEncode(snapshot), 200);
            }
            return http.Response('{}', 404);
          }),
        );
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(
                'plugins.it_nomads.com/flutter_secure_storage',
              ),
              (call) async =>
                  call.method == 'readAll' ? <String, String>{} : null,
            );
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        await manager.setActiveProfile('parity-fixture', 'profile-a');
        final scope = ActiveProfileScope.of(manager, 'parity-fixture');
        final providers = await dashboard.getModelOptions(
          profile: 'profile-a',
          explicitOnly: true,
        );
        expect(
          providers.single.authenticated,
          botCatalog.providers.single.authenticated,
        );
        tester.view.physicalSize = const Size(412, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            theme: AppTheme.hermesRedDark,
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: ModelsScreen(
              connection: SavedConnection(
                id: 'parity-fixture',
                label: 'Fixture',
                host: 'fixture.local',
                port: 8642,
                apiKey: '',
              ),
              profileScope: scope,
              dashboardClientForTesting: dashboard,

              gatewayCatalogForTesting: () => desktop,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (selected == 'fixture-missing') {
          expect(
            find.byKey(const ValueKey('models-catalog-missing-default')),
            findsOneWidget,
          );
          expect(find.text('fixture-missing'), findsOneWidget);
        }
        await tester.tap(find.text('Nous').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<HermesListRow>(find.byType(HermesListRow))
              .any((row) => row.title == 'fixture-free' && row.onTap != null),
          true,
        );
        final retired = tester
            .widgetList<HermesListRow>(find.byType(HermesListRow))
            .singleWhere((row) => row.title == 'fixture-retired');
        expect(
          retired.onTap,
          isNull,
          reason: 'Desktop locks unavailable_models; Models must not send them',
        );
        expect(
          retired.subtitle,
          isNotNull,
          reason: 'The disabled choice needs an explanation',
        );
        expect(requests, contains('bot:profile-a'));
      },
    );
  }
}
