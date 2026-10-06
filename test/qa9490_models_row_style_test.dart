import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_local_models_server.dart';

// QA 9490: in Models, the collapsible rows "Modelos por función" and
// "Proveedores sin configurar" used their own text style instead of the
// shared row style of their siblings (e.g. the local models row).
class _NoBridge implements BridgeManagerContract {
  @override
  Future<BridgeClient?> clientFor(String connectionId) async => null;
  @override
  Future<BridgeState> probe(String connectionId) async => BridgeState.unknown;
  @override
  Future<BridgeProvisionResult> provision(String connectionId) =>
      throw UnimplementedError();
  @override
  Future<bool> tryProvision(String connectionId) async => false;
}

DashboardClient _dashboard(FakeLocalModelsServer local) {
  final localClient = local.client;
  return DashboardClient(
    host: 'hermes.local',
    port: 9119,
    manualToken: 'dashboard-token',
    httpClientOverride: MockClient((request) async {
      switch (request.url.path) {
        case '/api/model/info':
          return http.Response(
            jsonEncode({'model': 'model-a', 'provider': 'alpha'}),
            200,
          );
        case '/api/model/options':
          return http.Response(
            jsonEncode({
              'providers': [
                {
                  'slug': 'alpha',
                  'name': 'Alpha',
                  'authenticated': true,
                  'models': ['model-a'],
                },
                {
                  'slug': 'beta',
                  'name': 'Beta',
                  'authenticated': false,
                  'models': ['model-b'],
                },
              ],
            }),
            200,
          );
        case '/api/model/auxiliary':
          return http.Response(
            jsonEncode({
              'tasks': [
                {'task': 'vision', 'provider': 'auto', 'model': ''},
              ],
            }),
            200,
          );
      }
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..body = request.body;
      return localClient.send(copy).then(http.Response.fromStream);
    }),
  );
}

TextStyle _painted(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(text).text.style!;

void _expectSameStyle(TextStyle actual, TextStyle expected, String what) {
  expect(actual.fontSize, expected.fontSize, reason: '$what fontSize');
  expect(actual.fontWeight, expected.fontWeight, reason: '$what fontWeight');
  expect(actual.fontFamily, expected.fontFamily, reason: '$what fontFamily');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpModels(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: ModelsScreen(
          connection: fakeConnection(),
          dashboardClientForTesting: _dashboard(FakeLocalModelsServer()),
          bridgeManagerForTesting: _NoBridge(),
          gatewayCatalogForTesting: () => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('collapsible Models rows share the sibling row text style', (
    tester,
  ) async {
    await pumpModels(tester);

    final entry = find.byKey(const ValueKey('lm1215-entry'));
    expect(entry, findsOneWidget);
    final entryTexts = find.descendant(of: entry, matching: find.byType(Text));
    final siblingTitle = _painted(tester, entryTexts.at(0));
    final siblingSubtitle = _painted(tester, entryTexts.at(1));

    for (final (title, subtitle) in [
      ('Modelos por función', 'todas en automático'),
      ('Proveedores sin configurar', '1 disponible · pulsa para configurar'),
    ]) {
      expect(find.text(title), findsOneWidget);
      expect(find.text(subtitle), findsOneWidget);
      _expectSameStyle(
        _painted(tester, find.text(title)),
        siblingTitle,
        '$title title',
      );
      _expectSameStyle(
        _painted(tester, find.text(subtitle)),
        siblingSubtitle,
        '$title subtitle',
      );
    }
  });

  // QA 9491: the collapsible rows' icon and text started ~12 px right of
  // their navigation siblings (ListTile's 40 dp leading slot + 16 dp gap
  // against the row's 30 dp icon + 11 dp gap).
  testWidgets('collapsible Models rows start their icon and text in line', (
    tester,
  ) async {
    await pumpModels(tester);

    final entry = find.byKey(const ValueKey('lm1215-entry'));
    expect(entry, findsOneWidget);
    final entryTexts = find.descendant(of: entry, matching: find.byType(Text));
    final siblingTitleX = tester.getTopLeft(entryTexts.at(0)).dx;
    final siblingIconX = tester
        .getTopLeft(
          find.descendant(of: entry, matching: find.byType(Icon)).first,
        )
        .dx;

    for (final (title, icon) in [
      ('Modelos por función', Icons.tune),
      ('Proveedores sin configurar', Icons.lock_outline),
    ]) {
      expect(
        tester.getTopLeft(find.text(title)).dx,
        moreOrLessEquals(siblingTitleX, epsilon: 0.5),
        reason: '$title title x',
      );
      expect(
        tester.getTopLeft(find.byIcon(icon)).dx,
        moreOrLessEquals(siblingIconX, epsilon: 0.5),
        reason: '$title icon x',
      );
    }
  });
}
