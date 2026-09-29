import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/gateway_manager_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final first = SavedConnection(
    id: 'first',
    label: 'First',
    host: '100.64.0.10',
    port: 8642,
    apiKey: '',
  );
  final second = SavedConnection(
    id: 'second',
    label: 'Second',
    host: '100.64.0.11',
    port: 8642,
    apiKey: '',
  );

  Future<ConnectionManager> managerWith(List<SavedConnection> conns) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    for (final c in conns.reversed) {
      await manager.upsertConnection(c);
    }
    await manager.setActiveConnection(first.id);
    return manager;
  }

  // Health probes and the dock keep indicators animating, so settle with a
  // bounded number of frames instead of pumpAndSettle.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Root → a screen bound to the active instance (like the Tools hub) →
  /// Instances.
  Future<void> pumpStack(WidgetTester tester, ConnectionManager manager) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const Scaffold(body: Text('root-screen')),
      ),
    );
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('bound-to-first')),
      ),
    );
    await settle(tester);
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => GatewayManagerScreen(connManager: manager),
      ),
    );
    await settle(tester);
  }

  testWidgets(
    'switching the active instance returns to the root instead of leaving '
    'screens bound to the previous instance underneath',
    (tester) async {
      final manager = await managerWith([first, second]);
      await pumpStack(tester, manager);
      expect(find.byType(GatewayManagerScreen), findsOneWidget);

      await tester.tap(find.text('Second'));
      await settle(tester);

      expect(manager.activeConnectionId.value, second.id);
      expect(find.byType(GatewayManagerScreen), findsNothing);
      expect(find.text('bound-to-first'), findsNothing);
      expect(find.text('root-screen'), findsOneWidget);
      expect(find.textContaining('Second'), findsOneWidget);
    },
  );

  testWidgets('tapping the instance that is already active stays in the list', (
    tester,
  ) async {
    final manager = await managerWith([first, second]);
    await pumpStack(tester, manager);

    await tester.tap(find.text('First'));
    await settle(tester);

    expect(manager.activeConnectionId.value, first.id);
    expect(find.byType(GatewayManagerScreen), findsOneWidget);
  });
}
