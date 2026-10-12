import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/instance_edit_screen.dart';
import 'package:hermes_android/core/screens/dashboard_password_screen.dart';
import 'package:hermes_android/core/screens/gateway_manager_screen.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/animated_hermes_logo.dart';
import 'package:hermes_android/core/widgets/instance_status_panel.dart'
    show DashboardAuthCheck;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/design_shots.dart';
import 'support/onboarding_fakes.dart';
import 'support/connection_editor_actions.dart';

const _root = ValueKey('onboarding-shot-root');

Future<void> _shot(WidgetTester tester, String name) async {
  final mark = find.byKey(const Key('animated_hermes_logo_mark'));
  if (mark.evaluate().isNotEmpty) {
    final provider = tester.widget<Image>(mark).image;
    await tester.runAsync(() => precacheImage(provider, tester.element(mark)));
    await tester.pumpAndSettle();
    expect(provider, isA<ResizeImage>());
    expect(
      ((provider as ResizeImage).imageProvider as AssetImage).assetName,
      kConsoleMarkAsset,
    );
  }
  expect(tester.takeException(), isNull);
  final boundary =
      tester.renderObject(find.byKey(_root)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory('build/onboarding_shots')
      ..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  for (final theme in ['dark', 'light']) {
    testWidgets('O2 landing on Home with a first chat · $theme', (
      tester,
    ) async {
      await loadDesignFonts();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final manager = await onboardingManager();
      final connection = fakeFullPairing.toDraftConnection().copyWith(
        id: 'synthetic-design-home',
      );
      await manager.upsertConnection(connection);
      await manager.setActiveConnection(connection.id);
      await tester.pumpWidget(
        RepaintBoundary(
          key: _root,
          child: onboardingHost(
            HomeDashboardScreen(
              connManager: manager,
              clientFactory: (_) => _HomeDesignClient(),
              dashboardAuthProbe: (_) async => DashboardAuthCheck.ok,
              eventStreamOverride: const Stream.empty(),
              cronJobsLoader: (_, _) async => const [],
              tasksLoader: (_) async => const KanbanBoard(columns: []),
              serverInfoLoader: (_) async => (version: null, update: false),
              limitsLoader: (_) async => null,
            ),
            theme: theme,
          ),
        ),
      );
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const ValueKey('home-first-chat')), findsOneWidget);
      await _shot(tester, 'o2_home_$theme');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('S saved Hermes list · $theme', (tester) async {
      await loadDesignFonts();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final manager = await onboardingManager();
      final first = fakeFullPairing.toDraftConnection().copyWith(
        id: 'synthetic-home',
        kind: InstanceKind.pc,
      );
      await manager.upsertConnection(
        first.copyWith(
          id: 'synthetic-office',
          label: 'Oficina',
          host: 'office.invalid',
        ),
      );
      await manager.upsertConnection(first);
      await manager.setActiveConnection(first.id);
      await tester.pumpWidget(
        RepaintBoundary(
          key: _root,
          child: onboardingHost(
            GatewayManagerScreen(connManager: manager),
            theme: theme,
          ),
        ),
      );
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await _shot(tester, 's_hermes_list_$theme');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('S by hand with the address typed · $theme', (tester) async {
      await loadDesignFonts();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final manager = await onboardingManager();
      await tester.pumpWidget(
        RepaintBoundary(
          key: _root,
          child: onboardingHost(
            InstanceEditScreen(
              connManager: manager,
              diagnostics: OnboardingDiagnostics(),
            ),
            theme: theme,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('instance-gateway-url')),
        '192.168.1.20',
      );
      await tester.pumpAndSettle();
      await _shot(tester, 's_by_hand_$theme');
    });

    testWidgets('S connection and advanced · $theme', (tester) async {
      await loadDesignFonts();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final manager = await onboardingManager();
      final connection = fakeFullPairing.toDraftConnection().copyWith(
        id: 'synthetic-design-connection',
        dashboardAuthMode: AuthMode.basicAuth,
      );
      await manager.upsertConnection(connection);
      await manager.setDashboardSecrets(
        connection.id,
        username: 'synthetic-owner',
        password: 'synthetic-existing-password',
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: _root,
          child: onboardingHost(
            InstanceEditScreen(
              connManager: manager,
              initial: connection,
              diagnostics: OnboardingDiagnostics(),
            ),
            theme: theme,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _shot(tester, 's_connection_$theme');
      await tapOnboarding(tester, 'instance-test');
      await _shot(tester, 's_connected_$theme');
      await openEditorAdvanced(tester);
      await revealEditorControl(
        tester,
        find.byKey(const ValueKey('instance-chat-port')),
      );
      await _shot(tester, 's_advanced_$theme');
      await tester.pumpWidget(
        RepaintBoundary(
          key: _root,
          child: onboardingHost(
            DashboardPasswordScreen(
              connection: connection,
              connManager: manager,
              authorityCurrent: () => true,
            ),
            theme: theme,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _shot(tester, 's_password_$theme');
    });
  }
}

class _HomeDesignClient extends ApiClient {
  _HomeDesignClient()
    : super(
        baseUrl: 'https://fixture.invalid:8642',
        apiKey: 'synthetic-design-key',
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  @override
  Future<bool> healthCheck() async => true;
  @override
  Future<bool> healthReachable() async => true;
  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => <Session>[];
}
