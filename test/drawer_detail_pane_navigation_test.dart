import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/tools_hub_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/adaptive_list_detail.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

// On medium and expanded windows a chat opens inside the list's detail pane,
// which is a nested Navigator. A drawer opened from that chat must still
// navigate the app's root navigator. Pushing on the pane's navigator nested a
// whole second screen (app bar, rail, drawer) inside the first.

final _connection = SavedConnection(
  id: 'drawer-pane-test',
  label: 'Pane QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-only',
);

void main() {
  testWidgets('a drawer inside the detail pane navigates the root navigator', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final rootKey = GlobalKey<NavigatorState>();
    final paneKey = GlobalKey<AdaptiveListDetailState>();
    final paneScaffold = GlobalKey<ScaffoldState>();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootKey,
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: AdaptiveListDetail(
            key: paneKey,
            placeholder: const SizedBox.shrink(),
            list: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();

    // Stand-in for a chat opened in the pane: a page with its own drawer.
    paneKey.currentState!.show<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          key: paneScaffold,
          drawer: HermesDrawer(
            connection: _connection,
            connManager: manager,
            current: DrawerSection.chat,
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(paneKey.currentState!.hasDetail, isTrue);

    paneScaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();

    final tools = find.text('Tools');
    final scrollable = find
        .descendant(of: find.byType(Drawer), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(tools, 80, scrollable: scrollable);
    await tester.tap(tools);
    await tester.pumpAndSettle();

    final screen = find.byType(ToolsHubScreen);
    expect(screen, findsOneWidget);
    expect(
      Navigator.of(tester.element(screen)),
      same(rootKey.currentState),
      reason: 'the section must open on the root navigator, not in the pane',
    );
  });
}
