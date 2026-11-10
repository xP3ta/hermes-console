import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/screens/onboarding/connect_method_cards.dart';
import 'package:hermes_android/core/design/tokens.dart';
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

/// The three connection cards keep the same order, reach and semantics under
/// either legacy switch value. Setup help remains a separate trailing link.
void expectOnboardingWays(WidgetTester tester, Strings s) {
  final ways = find.byKey(const ValueKey('onboarding-ways'));
  expect(ways, findsOneWidget);
  final cards = tester.widget<ConnectWayCards>(ways);
  expect(cards.recommended, ConnectWay.scan);
  expect(find.byKey(const ValueKey('onboarding-way-ssh')), findsNothing);
  const keys = ['onboarding-way-nous', 'onboarding-manual', 'onboarding-scan'];
  Rect? previous;
  for (final (i, key) in keys.indexed) {
    final card = find.byKey(ValueKey(key));
    expect(find.descendant(of: ways, matching: card), findsOneWidget);
    final rect = tester.getRect(card);
    expect(rect.height, greaterThanOrEqualTo(HermesSpace.tap));
    if (previous != null) {
      expect(rect.top, greaterThanOrEqualTo(previous.bottom));
      expect(rect.width, previous.width);
    }
    final way = ConnectWayCards.order[i];
    expect(
      find.descendant(
        of: card,
        matching: find.text(ConnectWayCards.titleOf(s, way)),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text(ConnectWayCards.bodyOf(s, way)),
      ),
      findsOneWidget,
    );
    final semantics = find.descendant(
      of: card,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.button == true &&
            w.properties.label != null,
      ),
    );
    expect(semantics, findsOneWidget);
    expect(
      tester.widget<Semantics>(semantics).properties.selected,
      way == cards.recommended,
    );
    previous = rect;
  }
  expect(
    tester.getRect(find.byKey(const ValueKey('onboarding-help'))).top,
    greaterThanOrEqualTo(previous!.bottom),
  );
  expect(find.byKey(const ValueKey('onboarding-simple-connect')), findsNothing);
}

/// A card can be taller than the viewport at large text sizes. Centre it
/// before tapping, so its centre remains inside the screen as a real tap is.
Future<void> revealOnboarding(WidgetTester tester, String key) async {
  final control = find.byKey(ValueKey(key));
  await Scrollable.ensureVisible(tester.element(control), alignment: .5);
  await tester.pump();
  expect(control.hitTestable(), findsOneWidget);
}
