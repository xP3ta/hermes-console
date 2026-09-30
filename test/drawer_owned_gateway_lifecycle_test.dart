import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// The projects screen shows an indeterminate loader while its gateway fails,
// so a fixed pump sequence replaces pumpAndSettle after navigation.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a rebuilt projects route keeps one gateway and closes it on pop',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final connManager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final connection = SavedConnection(
        id: 'drawer-gateway-qa',
        label: 'Server',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'k',
      );
      final created = <TuiGatewayClient>[];
      final scaffoldKey = GlobalKey<ScaffoldState>();

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            key: scaffoldKey,
            drawer: HermesDrawer(
              connection: connection,
              connManager: connManager,
              current: DrawerSection.home,
              gatewayFactory: (saved) {
                final client = TuiGatewayClient(
                  saved,
                  channelFactory: (_, _) =>
                      throw StateError('no socket in tests'),
                );
                created.add(client);
                return client;
              },
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      );
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();

      final projects = find.text('Projects');
      await tester.scrollUntilVisible(
        projects,
        80,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('drawer-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(projects);
      await _settle(tester);

      expect(find.byType(ProjectsCenterScreen), findsOneWidget);
      expect(created, hasLength(1));

      // Route pages are rebuilt on external state changes; the screen must
      // keep its client instead of receiving a fresh one each time.
      final route = ModalRoute.of(
        tester.element(find.byType(ProjectsCenterScreen)),
      )!;
      route.changedExternalState();
      await _settle(tester);
      route.changedExternalState();
      await _settle(tester);

      expect(created, hasLength(1));
      expect(created.single.isClosed, isFalse);

      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await _settle(tester);

      expect(find.byType(ProjectsCenterScreen), findsNothing);
      expect(created.every((client) => client.isClosed), isTrue);
    },
  );
}
