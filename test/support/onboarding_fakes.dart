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

/// A Dashboard-only run, like the real one: [reachStatus] is its liveness
/// probe (`/api/status`), [dashboardStatus] the login and the authenticated
/// `/api/sessions` read behind it.
class OnboardingDiagnostics extends ConnectionDiagnostics {
  OnboardingDiagnostics({
    this.reachStatus = ProbeStatus.ok,
    this.dashboardStatus = ProbeStatus.ok,
    this.readOnly = false,
  });
  final ProbeStatus reachStatus;
  final ProbeStatus dashboardStatus;
  final bool readOnly;
  int calls = 0;

  /// Holds the run before the Dashboard answers, so a test can look at the
  /// screen while the first row is still spinning.
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
    const down = {
      ProbeStatus.timeout,
      ProbeStatus.dnsError,
      ProbeStatus.refused,
      ProbeStatus.error,
      ProbeStatus.tlsError,
    };
    final up = !down.contains(reachStatus);
    final dashboard = [
      ProbeResult(name: 'status', status: reachStatus),
      if (up) ProbeResult(name: 'auth', status: dashboardStatus),
      if (up && dashboardStatus.isOk)
        const ProbeResult(name: 'sessions', status: ProbeStatus.ok),
    ];
    await gate?.future;
    onStage?.call(DiagnosticsStage.dashboard, dashboard);
    return DiagnosticsReport(
      gateway: const [],
      dashboard: dashboard,
      matrix: CapabilityMatrix(
        dashboardAuthValid: dashboardStatus.isOk ? CapState.yes : CapState.no,
        sessionsRead: dashboardStatus.isOk ? CapState.yes : CapState.unknown,
        chatSupported: readOnly ? CapState.no : CapState.unknown,
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
