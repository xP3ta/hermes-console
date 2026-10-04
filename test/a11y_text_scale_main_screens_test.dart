import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';

import 'support/a11y_main_screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(installA11yPlatformMocks);
  tearDown(clearA11yPlatformMocks);

  testWidgets('home remains usable at 200 percent on a compact phone', (
    tester,
  ) async {
    useA11yPhoneView(tester);
    final manager = await createA11yManager();

    await tester.pumpWidget(
      a11yHost(HomeDashboardScreen(connManager: manager)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    expect(find.text('add instance').hitTestable(), findsOneWidget);
  });

  testWidgets('session list remains usable at 200 percent on a compact phone', (
    tester,
  ) async {
    useA11yPhoneView(tester);
    final manager = await createA11yManager();

    await tester.pumpWidget(
      a11yHost(
        SessionListScreen(
          connection: a11yConnection,
          connManager: manager,
          clientOverride: A11yApiClient(sessions: [a11ySession()]),
          eventStreamOverride: const Stream.empty(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('New session').hitTestable(), findsOneWidget);
  });

  testWidgets('chat remains usable at 200 percent on a compact phone', (
    tester,
  ) async {
    useA11yPhoneView(tester);
    await pumpA11yChat(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('chat-composer-host')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('Review the release'), findsWidgets);
    expect(find.text('The release is ready.'), findsOneWidget);
  });

  testWidgets('settings remains usable at 200 percent on a compact phone', (
    tester,
  ) async {
    useA11yPhoneView(tester);
    final manager = await createA11yManager();

    await tester.pumpWidget(
      a11yHost(
        SettingsScreen(connection: a11yConnection, connManager: manager),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Themes').hitTestable(), findsOneWidget);
  });

  testWidgets('profiles remains usable at 200 percent on a compact phone', (
    tester,
  ) async {
    useA11yPhoneView(tester);
    await pumpA11yProfiles(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Create').hitTestable(), findsOneWidget);
  });

  testWidgets('onboarding remains usable at 200 percent on a compact phone', (
    tester,
  ) async {
    useA11yPhoneView(tester);
    final manager = await createA11yManager(onboarded: false);

    await tester.pumpWidget(
      a11yHost(OnboardingScreen(connManager: manager, onDone: () {})),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text('Next').hitTestable(), findsOneWidget);
  });
}
