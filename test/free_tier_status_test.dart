import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/free_tier_status.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/free_tier_status.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _Gateway implements HermesDesktopFreeTierGateway {
  final List<String> calls = [];
  bool unsupported = false;
  bool pending = true;

  @override
  Future<FreeTierAckNotice> ackFreeTierNotice({String profile = ''}) async {
    calls.add('ack:$profile');
    pending = false;
    return const FreeTierAckNotice(true);
  }

  @override
  Future<FreeTierStatus> freeTierStatus({String profile = ''}) async {
    calls.add('status:$profile');
    if (unsupported) {
      throw const TuiGatewayRpcError(
        'free_tier.status',
        'unsupported',
        code: -32601,
      );
    }
    return FreeTierStatus(
      hasGuest: true,
      enabled: true,
      available: true,
      noticePending: pending,
      model: 'nous/welcome',
      label: 'Nous Free',
    );
  }
}

final class _NoBridge implements BridgeManagerContract {
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

DashboardClient _dashboard() => DashboardClient(
  host: 'hermes.example.test',
  manualToken: 'test-token',
  httpClientOverride: MockClient((request) async {
    return switch (request.url.path) {
      '/api/model/info' => http.Response(
        jsonEncode({'model': 'welcome', 'provider': 'nous'}),
        200,
      ),
      '/api/model/options' => http.Response(
        jsonEncode({
          'providers': [
            {
              'slug': 'nous',
              'name': 'Nous',
              'authenticated': true,
              'free_tier': true,
              'auth_type': 'oauth',
              'models': ['welcome'],
            },
          ],
        }),
        200,
      ),
      '/api/model/auxiliary' => http.Response('{"tasks":[]}', 200),
      _ => http.Response('', 404),
    };
  }),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('-32601 produces no status', () async {
    final gateway = _Gateway()..unsupported = true;
    final reader = FreeTierStatusReader(gateway: gateway, profile: 'team-one');

    expect(await reader.load(), isNull);
    expect(gateway.calls, ['status:team-one']);
  });

  test('notice is read only on explicit load', () async {
    final gateway = _Gateway();
    final reader = FreeTierStatusReader(gateway: gateway, profile: 'team-one');

    expect(gateway.calls, isEmpty);
    final status = await reader.load();
    expect(status!.shouldShowNotice, isTrue);
    expect(gateway.calls, ['status:team-one']);
  });

  test('notice action acknowledges then re-reads backend state', () async {
    final gateway = _Gateway();
    final reader = FreeTierStatusReader(gateway: gateway, profile: 'team-one');

    final status = await reader.acknowledgeAndReload();

    expect(gateway.calls, ['ack:team-one', 'status:team-one']);
    expect(status!.shouldShowNotice, isFalse);
  });

  testWidgets('Models loads once and dismiss acknowledges before re-read', (
    tester,
  ) async {
    final gateway = _Gateway();
    final dashboard = _dashboard();
    addTearDown(dashboard.close);
    tester.view.physicalSize = const Size(412, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: ModelsScreen(
          connection: SavedConnection(
            id: 'server-a',
            label: 'Server',
            host: 'hermes.example.test',
            port: 5000,
            apiKey: 'test-token',
          ),
          dashboardClientForTesting: dashboard,
          bridgeManagerForTesting: _NoBridge(),
          freeTierGatewayForTesting: gateway,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.calls, ['status:']);
    expect(
      find.text('Free models are available on this server · Nous Free'),
      findsOneWidget,
    );
    await tester.tap(find.text('Unconfigured providers'));
    await tester.pumpAndSettle();
    expect(find.text('Nous Free'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();

    expect(gateway.calls, ['status:', 'ack:', 'status:']);
    expect(
      find.text('Free models are available on this server · Nous Free'),
      findsNothing,
    );
  });
}
