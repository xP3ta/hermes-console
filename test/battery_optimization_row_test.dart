// SPDX-License-Identifier: GPL-3.0-only
// M6: Settings → Notifications says whether Android may hold back the app in
// the background (battery optimisation, background restriction, Samsung's
// sleeping apps) and opens the system screen to change it. Informative only:
// the app never asks for REQUEST_IGNORE_BATTERY_OPTIMIZATIONS.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/battery_optimization_row.dart';
import 'package:hermes_android/core/widgets/battery_optimization_prompt.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _languages = ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'];

Widget _host(Locale locale, Widget child, {double textScale = 1}) =>
    MaterialApp(
      locale: locale,
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: home!,
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('native channel', () {
    const channel = MethodChannel(PlatformRichNotifications.channelName);
    final calls = <String>[];
    Object? status;

    setUp(() {
      calls.clear();
      status = {'ignoringOptimizations': false, 'backgroundRestricted': true};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return switch (call.method) {
              'batteryStatus' => status,
              'openBatterySettings' => true,
              _ => null,
            };
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('reads both flags and opens the system screen', () async {
      final rich = PlatformRichNotifications();
      final got = (await rich.batteryStatus())!;
      expect(got.ignoringOptimizations, isFalse);
      expect(got.backgroundRestricted, isTrue);
      expect(await rich.openBatterySettings(), isTrue);
      expect(calls, ['batteryStatus', 'openBatterySettings']);
    });

    test('an old native side or a malformed reply is «unknown»', () async {
      status = null;
      expect(await PlatformRichNotifications().batteryStatus(), isNull);
      status = {'ignoringOptimizations': 'yes'};
      expect(await PlatformRichNotifications().batteryStatus(), isNull);
    });
  });

  group('row', () {
    Widget row(
      BatteryOptimizationStatus? status, {
      VoidCallback? onOpen,
      Key? key,
    }) => BatteryOptimizationRow(
      key: key,
      load: () async => status,
      openSettings: () async {
        onOpen?.call();
        return true;
      },
    );

    testWidgets('unrestricted: one quiet line, no button', (tester) async {
      await tester.pumpWidget(
        _host(
          const Locale('es'),
          row(
            const BatteryOptimizationStatus(
              ignoringOptimizations: true,
              backgroundRestricted: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sin restricciones'), findsOneWidget);
      expect(find.text('Abrir ajustes de batería'), findsNothing);
    });

    testWidgets('optimised: explains the delay, the Samsung path and opens', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        _host(
          const Locale('es'),
          row(
            const BatteryOptimizationStatus(
              ignoringOptimizations: false,
              backgroundRestricted: false,
            ),
            onOpen: () => opened++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Optimizada'), findsOneWidget);
      expect(find.textContaining('retrasar los avisos'), findsOneWidget);
      expect(find.textContaining('Samsung'), findsOneWidget);
      await tester.tap(find.text('Abrir ajustes de batería'));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('restricted in the background wins over optimised', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const Locale('es'),
          row(
            const BatteryOptimizationStatus(
              ignoringOptimizations: false,
              backgroundRestricted: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Restringida en segundo plano'), findsOneWidget);
      expect(find.textContaining('pueden no llegar'), findsOneWidget);
    });

    testWidgets('unknown (old native side): nothing is shown', (tester) async {
      await tester.pumpWidget(_host(const Locale('es'), row(null)));
      await tester.pumpAndSettle();
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('reads in all nine languages', (tester) async {
      for (final lang in _languages) {
        await tester.pumpWidget(
          _host(
            Locale(lang),
            row(
              const BatteryOptimizationStatus(
                ignoringOptimizations: false,
                backgroundRestricted: false,
              ),
              key: ValueKey(lang),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: lang);
        expect(
          find.byType(HermesSecondaryButton),
          findsOneWidget,
          reason: lang,
        );
      }
    });
  });

  testWidgets('Settings restore action fits 320 dp at 2x in all locales', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({kBatteryPromptDismissedPref: true});
    final prefs = await SharedPreferences.getInstance();
    for (final lang in _languages) {
      await tester.pumpWidget(
        _host(
          Locale(lang),
          BatteryOptimizationRow(
            key: ValueKey(lang),
            prefs: prefs,
            load: () async => const BatteryOptimizationStatus(
              ignoringOptimizations: false,
              backgroundRestricted: true,
            ),
            openSettings: () async => true,
          ),
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      final restore = find.byKey(const ValueKey('battery-prompt-restore'));
      expect(restore, findsOneWidget);
      expect(tester.getSize(restore).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull, reason: lang);
    }
  });

  test('the native side reads the flags and never asks the permission', () {
    final kotlin = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesRichNotifications.kt',
    ).readAsStringSync();
    expect(kotlin, contains('isIgnoringBatteryOptimizations'));
    expect(kotlin, contains('isBackgroundRestricted'));
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(manifest, isNot(contains('REQUEST_IGNORE_BATTERY_OPTIMIZATIONS')));
  });
}
