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

// The compact dock pins its labels at 1.0x so they fit the fixed 48dp tile
// (see dock_style.dart); the full label stays available via Tooltip and
// Semantics.
final _fixedSizeDockLabels = _bottomNavigation.keys.toSet();

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
      'empty state': find.text(
        'Connect Console to your Hermes to get started.',
      ),
      'connect': find.text('Connect'),
      'navigation menu': find.byTooltip('Open navigation menu'),
      ..._bottomNavigation,
    }, fixedSizeText: _fixedSizeDockLabels);
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
    }, fixedSizeText: _fixedSizeDockLabels);
  });

  testWidgets('chat remains usable at 200 percent on a compact phone', (
    tester,
  ) async {
    useA11yPhoneView(tester);
    await pumpA11yChat(tester);

    await expectA11yLayoutUsable(tester, {
      'menu': find.byTooltip('Menu'),
      'new chat': find.byTooltip('New chat'),
      // fh1215: the floating header's activity pill.
      'header pill': find.byKey(const ValueKey('chat-header-pill')),
      'composer': find.byKey(const ValueKey('chat-composer-host')),
      'user message': find.text('Review the release').last,
      'assistant message': find.text('The release is ready.'),
      'edit message': find.byTooltip('Edit message'),
      'copy message': find.byTooltip('Copy message'),
    });
    // Search and conversation settings live behind the composer notch. It
    // floats over the transcript like the activity pill, so scrolled
    // messages may pass under it; check it against the fixed chrome only.
    await expectA11yLayoutUsable(tester, {
      'conversation notch': find.byKey(const ValueKey('chat-notch')),
      'composer': find.byKey(const ValueKey('chat-composer-host')),
      'new chat': find.byTooltip('New chat'),
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
      'default actions': find.byKey(const ValueKey('profile-more-default')),
      'release actions': find.byKey(const ValueKey('profile-more-release')),
      'new profile': find.byTooltip('New profile'),
      'reload': find.byTooltip('Reload'),
      ..._bottomNavigation,
    }, fixedSizeText: _fixedSizeDockLabels);
  });

  testWidgets('onboarding remains usable at 200 percent on a compact phone', (
    tester,
  ) async {
    useA11yPhoneView(tester);
    final manager = await createA11yManager(onboarded: false);

    await tester.pumpWidget(
      a11yHost(OnboardingScreen(connManager: manager, onDone: () {})),
    );
    // The opening plays: let it end.
    await tester.pump(const Duration(seconds: 3));

    await expectA11yLayoutUsable(
      tester,
      {
        'welcome': find.text('Connect to your Hermes'),
        'scan': find.text('I already have Hermes'),
        'no Hermes yet': find.text("I don't have Hermes yet"),
        // The headline follows the system size up to 1.35x: at 2x it would break
        // words on a 320 dp phone.
      },
      fixedSizeText: {'welcome'},
    );
  });
}
