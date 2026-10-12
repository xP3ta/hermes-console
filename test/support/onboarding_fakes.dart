import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection_editor_actions.dart';

const fakeFullPairing = PairingLink(
  host: 'fixture.invalid',
  port: 8642,
  token: 'synthetic-chat-key',
  useHttps: true,
  label: 'Casa',
  dashboardUrl: 'https://fixture.invalid:9119',
  dashboardUser: 'synthetic-owner',
  dashboardPassword: 'synthetic-panel-password',
);

class OnboardingDiagnostics extends ConnectionDiagnostics {
  OnboardingDiagnostics({
    this.gatewayStatus = ProbeStatus.ok,
    this.dashboardStatus = ProbeStatus.ok,
    this.readOnly = false,
  });
  final ProbeStatus gatewayStatus;
  final ProbeStatus dashboardStatus;
  final bool readOnly;
  int calls = 0;

  /// Holds the run between the two surfaces, so a test can look at the
  /// screen with only the first one checked.
  Completer<void>? gate;
  SavedConnection? target;
  DashboardSecrets? sentSecrets;

  @override
  Future<DiagnosticsReport> run(
    Strings s,
    SavedConnection conn,
    DashboardSecrets secrets, {
    DiagnosticsStageCallback? onStage,
  }) async {
    calls++;
    target = conn;
    sentSecrets = secrets;
    final gateway = [ProbeResult(name: 'sessions', status: gatewayStatus)];
    final dashboard = [ProbeResult(name: 'auth', status: dashboardStatus)];
    onStage?.call(DiagnosticsStage.gateway, gateway);
    await gate?.future;
    onStage?.call(DiagnosticsStage.dashboard, dashboard);
    return DiagnosticsReport(
      gateway: gateway,
      dashboard: dashboard,
      matrix: CapabilityMatrix(
        gatewayAuthValid: gatewayStatus.isOk ? CapState.yes : CapState.no,
        dashboardAuthValid: dashboardStatus.isOk ? CapState.yes : CapState.no,
        chatSupported: readOnly ? CapState.no : CapState.yes,
        sessionsWrite: readOnly ? CapState.no : CapState.yes,
        checkedAtMs: 1,
      ),
      suggestions: const [],
      ranAt: DateTime(2026, 1, 1),
    );
  }
}

Future<ConnectionManager> onboardingManager() async {
  SharedPreferences.setMockInitialValues({});
  final store = <String, String>{};
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
        switch (call.method) {
          case 'write':
            store[args['key'] as String] = args['value'] as String;
            return null;
          case 'read':
            return store[args['key']];
          case 'readAll':
            return Map<String, String>.from(store);
          case 'delete':
            store.remove(args['key']);
            return null;
          case 'deleteAll':
            store.clear();
            return null;
          case 'containsKey':
            return store.containsKey(args['key']);
        }
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
  return manager;
}

Widget onboardingHost(
  Widget child, {
  String language = 'es',
  String theme = 'dark',
  double scale = 1,

  /// Tests settle with pumpAndSettle, so they run with reduced motion (the
  /// end states) unless they are about the motion itself.
  bool motion = false,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  locale: Locale(language),
  theme: AppTheme.fromId(
    theme == 'light'
        ? 'console-light'
        : theme == 'dark'
        ? 'console'
        : theme,
  ),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      disableAnimations: !motion,
    ),
    child: child!,
  ),
  home: child,
);

Future<void> tapOnboarding(WidgetTester tester, String key) async {
  final control = find.byKey(ValueKey(key));
  await revealEditorControl(tester, control);
  expect(control.hitTestable(), findsOneWidget);
  await tester.tap(control);
  await tester.pumpAndSettle();
}

Strings onboardingStrings(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(OnboardingScreen)));
