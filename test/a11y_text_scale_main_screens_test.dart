import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';

import 'support/a11y_main_screen_harness.dart';

final _bottomNavigation = <String, Finder>{
  'home tab': find.text('Home'),
  'create tab': find.text('Create'),
  'bots tab': find.text('Bots'),
  'settings tab': find.text('Settings'),
};

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

    await expectA11yLayoutUsable(tester, {
      'empty state': find.text('▸ no instances configured'),
      'default port': find.text('port 8642'),
      'add instance': find.text('add instance'),
      'navigation menu': find.byTooltip('Open navigation menu'),
      ..._bottomNavigation,
    });
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

    await expectA11yLayoutUsable(tester, {
      'title': find.text('Conversations'),
      'menu': find.byTooltip('Menu'),
      'new session': find.byTooltip('New session'),
      'more options': find.byTooltip('More options'),
      'chats tab': find.text('Chats'),
      'automation tab': find.text('Automation'),
      'all tab': find.text('All'),
      'session title': find.text('Accessible conversation'),
      'session preview': find.text('Review the release'),
      ..._bottomNavigation,
    });
  });

  testWidgets('chat remains usable at 200 percent on a compact phone', (
    tester,
  ) async {
    useA11yPhoneView(tester);
    await pumpA11yChat(tester);

    await expectA11yLayoutUsable(tester, {
      'menu': find.byTooltip('Menu'),
      'new chat': find.byTooltip('New chat'),
      'search in chat': find.byTooltip('Search in chat'),
      'conversation settings': find.byTooltip('Conversation settings'),
      'composer': find.byKey(const ValueKey('chat-composer-host')),
      'user message': find.text('Review the release').last,
      'assistant message': find.text('The release is ready.'),
      'edit message': find.byTooltip('Edit message'),
      'copy message': find.byTooltip('Copy message'),
    });
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

    await expectA11yLayoutUsable(tester, {
      'connection section': find.text('connection'),
      'connection label': find.text('Accessibility fixture').last,
      'manage instances': find.text('Manage instances'),
      'appearance section': find.text('Appearance'),
      'themes': find.text('Themes'),
      'font style': find.text('Font style'),
      'language': find.text('Language'),
      'header name': find.text('Header name'),
      'floating dock': find.text('Use floating dock'),
      'dock settings': find.text('Dock'),
      'open bots on launch': find.text('Open Bots on launch'),
    });
  });

  testWidgets('profiles remains usable at 200 percent on a compact phone', (
    tester,
  ) async {
    useA11yPhoneView(tester);
    await pumpA11yProfiles(tester);

    await expectA11yLayoutUsable(tester, {
      'default profile': find.text('default'),
      'release profile': find.text('release'),
      'edit identity': find.byTooltip('Edit profile identity'),
      'rename': find.byTooltip('Rename'),
      'delete': find.byTooltip('Delete'),
      'default delete': find.byTooltip('The default profile cannot be deleted'),
      'reload': find.byTooltip('Reload'),
      ..._bottomNavigation,
    });
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

    await expectA11yLayoutUsable(tester, {
      'skip': find.text('Skip'),
      'title': find.text('Hermes Console'),
      'tagline': find.textContaining('self-hosted Hermes agent'),
      'next': find.text('Next'),
    });
  });
}
