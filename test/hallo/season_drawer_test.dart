// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// The side menu wears the same Console logo as Home's title, seasons
// included (owner, QA 9623).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/halloween.dart';
import 'package:hermes_android/core/screens/onboarding/onboarding_motion.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _openDrawer(WidgetTester tester, {double scale = 1}) async {
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  final key = GlobalKey<ScaffoldState>();
  final connection = SavedConnection(
    id: 'drawer-season',
    label: 'Server',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'test-only',
  );
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        key: key,
        drawer: HermesDrawer(
          connection: connection,
          connManager: manager,
          current: DrawerSection.home,
          recentSessionsClientFactory: (saved) => ApiClient(
            baseUrl: saved.baseUrl,
            apiKey: saved.apiKey,
            httpClient: MockClient(
              (_) async => http.Response(
                jsonEncode({'object': 'list', 'data': []}),
                200,
              ),
            ),
          ),
        ),
        body: const SizedBox.expand(),
      ),
    ),
  );
  key.currentState!.openDrawer();
  await tester.pumpAndSettle();
}

ConsoleMark _mark(WidgetTester tester) => tester.widget<ConsoleMark>(
  find.descendant(
    of: find.byKey(const ValueKey('drawer-header-mark')),
    matching: find.byType(ConsoleMark),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => seasonClock = DateTime.now);

  for (final (day, season) in [
    (DateTime(2026, 7, 1), Season.none),
    (DateTime(2026, 10, 31), Season.halloween),
    (DateTime(2026, 12, 25), Season.christmas),
  ]) {
    testWidgets('side menu: the Console logo beside its title on $day', (
      tester,
    ) async {
      seasonClock = () => day;
      await _openDrawer(tester);
      expect(find.byKey(const ValueKey('drawer-header-mark')), findsOneWidget);
      expect(_mark(tester).season, season);
      expect(find.text('Console'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [2.0, 3.0]) {
    testWidgets('side menu header fits 320 dp at ${scale}x text', (
      tester,
    ) async {
      seasonClock = () => DateTime(2026, 10, 31);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _openDrawer(tester, scale: scale);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('drawer-header-mark')), findsOneWidget);
    });
  }
}
