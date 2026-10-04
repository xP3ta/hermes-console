// A search result for a section of the main Settings screen scrolls to it and
// highlights it once.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/settings/settings_deep_link.dart';
import 'package:hermes_android/core/settings/settings_search.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

Widget _host(ScrollController controller) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  home: Scaffold(
    // Like the Settings list: sections far from the viewport stay built.
    body: ListView(
      controller: controller,
      cacheExtent: 6000,
      children: [
        const SizedBox(height: 1600),
        SettingsDeepLinkTarget(
          section: SettingsSection.security,
          child: const SizedBox(height: 80, child: Text('Security rows')),
        ),
        const SizedBox(height: 1600),
      ],
    ),
  ),
);

Finder _highlight() =>
    find.byKey(const ValueKey('settings-highlight-security'));

void main() {
  tearDown(() => SettingsDeepLink.pending.value = null);

  testWidgets('nothing is highlighted without a request', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    expect(_highlight(), findsNothing);
    expect(controller.offset, 0);
  });

  testWidgets('a request scrolls to the section and highlights it once', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    SettingsDeepLink.request(SettingsSection.security);
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(controller.offset, greaterThan(1000));
    expect(_highlight(), findsOneWidget);
    expect(SettingsDeepLink.pending.value, isNull, reason: 'consumed');

    await tester.pump(const Duration(seconds: 3));
    expect(_highlight(), findsNothing);
  });

  testWidgets('a request made before the screen exists is honored', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    SettingsDeepLink.request(SettingsSection.security);
    await tester.pumpWidget(_host(controller));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(_highlight(), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a request for another section does nothing here', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));

    SettingsDeepLink.request(SettingsSection.about);
    await tester.pump(const Duration(seconds: 1));

    expect(_highlight(), findsNothing);
    expect(controller.offset, 0);
    expect(SettingsDeepLink.pending.value, SettingsSection.about);
  });

  testWidgets('leaving the screen before the highlight ends leaves no timer', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));
    SettingsDeepLink.request(SettingsSection.security);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });
}
