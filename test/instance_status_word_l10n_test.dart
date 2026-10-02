import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/core/widgets/status_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Widget app(Locale locale, Widget child) => MaterialApp(
    locale: locale,
    theme: AppTheme.fromId('dark'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: Scaffold(body: child),
  );

  const statuses = [
    InstanceStatus.online,
    InstanceStatus.offline,
    InstanceStatus.syncing,
    InstanceStatus.error,
  ];

  Future<List<String>> pillLabels(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(
      app(
        locale,
        Column(
          children: [
            for (final status in statuses)
              StatusPill(key: ValueKey(status), status: status),
          ],
        ),
      ),
    );
    return [
      for (final status in statuses)
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(ValueKey(status)),
                matching: find.byType(Text),
              ),
            )
            .data!,
    ];
  }

  testWidgets('instance status pills are localized in Spanish', (tester) async {
    expect(await pillLabels(tester, const Locale('es')), [
      'EN LÍNEA',
      'SIN CONEXIÓN',
      'SINCRONIZANDO',
      'ERROR',
    ]);
  });

  testWidgets('instance status pills keep the English words', (tester) async {
    expect(await pillLabels(tester, const Locale('en')), [
      'ONLINE',
      'OFFLINE',
      'SYNC',
      'ERROR',
    ]);
  });

  Future<void> pumpDrawer(
    WidgetTester tester, {
    required Locale locale,
    required bool connected,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final connection = SavedConnection(
      id: 'demo',
      label: 'Server',
      host: '127.0.0.1',
      port: 8642,
      apiKey: '',
    );
    await manager.upsertConnection(connection);
    await manager.setActiveConnection(connection.id);
    final scaffoldKey = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          key: scaffoldKey,
          body: const SizedBox.shrink(),
          drawer: HermesDrawer(
            connection: connection,
            connManager: manager,
            current: DrawerSection.home,
            connected: connected,
            recentSessionsClientFactory: (saved) => ApiClient(
              baseUrl: saved.baseUrl,
              apiKey: saved.apiKey,
              httpClient: MockClient(
                (_) async => http.Response('{"object":"list","data":[]}', 200),
              ),
            ),
          ),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await tester.pumpAndSettle();
  }

  testWidgets('drawer header status word is localized in Spanish', (
    tester,
  ) async {
    await pumpDrawer(tester, locale: const Locale('es'), connected: false);
    expect(find.text('Server · sin conexión'), findsOneWidget);
    expect(find.textContaining('offline'), findsNothing);

    await pumpDrawer(tester, locale: const Locale('es'), connected: true);
    expect(find.text('Server · en línea'), findsOneWidget);
    expect(find.textContaining('online'), findsNothing);
  });

  testWidgets('drawer header status word stays English in English', (
    tester,
  ) async {
    await pumpDrawer(tester, locale: const Locale('en'), connected: false);
    expect(find.text('Server · offline'), findsOneWidget);

    await pumpDrawer(tester, locale: const Locale('en'), connected: true);
    expect(find.text('Server · online'), findsOneWidget);
  });
}
