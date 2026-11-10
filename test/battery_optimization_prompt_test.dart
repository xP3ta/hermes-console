import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/battery_optimization_prompt.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _languages = ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'];
const _title = 'Mantén Console conectada en segundo plano';
const _openKey = ValueKey('battery-prompt-open');
const _dismissKey = ValueKey('battery-prompt-dismiss');

Widget _host(
  Widget child, {
  String lang = 'es',
  String theme = 'dark',
  double textScale = 1,
}) => MaterialApp(
  locale: Locale(lang),
  theme: AppTheme.fromId(theme),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: home!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

void _testAndroid(String name, WidgetTesterCallback body) => testWidgets(
  name,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.android),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(PlatformRichNotifications.channelName);
  late SharedPreferences prefs;
  late List<String> calls;
  Object? status;

  Widget prompt({bool connected = true, bool dismissible = true, Key? key}) =>
      BatteryOptimizationPrompt(
        key: key,
        hasConnection: connected,
        prefs: prefs,
        dismissible: dismissible,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    calls = [];
    status = {'ignoringOptimizations': false, 'backgroundRestricted': false};
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

  _testAndroid('configured Android without exemption offers a quiet card', (
    tester,
  ) async {
    await tester.pumpWidget(_host(prompt()));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsOneWidget);
    expect(find.byKey(_openKey), findsOneWidget);
    expect(find.text('Ahora no'), findsOneWidget);
    expect(calls, ['batteryStatus']);
  });

  _testAndroid('no configured connection: no card or native request', (
    tester,
  ) async {
    await tester.pumpWidget(_host(prompt(connected: false)));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
    expect(calls, isEmpty);
  });

  _testAndroid('a newly configured connection makes the card eligible', (
    tester,
  ) async {
    await tester.pumpWidget(_host(prompt(connected: false)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(prompt()));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsOneWidget);
  });

  testWidgets('other platforms never read Android battery state', (
    tester,
  ) async {
    await tester.pumpWidget(_host(prompt()));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing, reason: defaultTargetPlatform.name);
    expect(calls, isEmpty);
  }, variant: TargetPlatformVariant.all(excluding: {TargetPlatform.android}));

  _testAndroid('exempt Android hides the card', (tester) async {
    status = {'ignoringOptimizations': true, 'backgroundRestricted': false};
    await tester.pumpWidget(_host(prompt()));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
    expect(calls, ['batteryStatus']);
  });

  _testAndroid('unknown battery status hides the card', (tester) async {
    status = null;
    await tester.pumpWidget(_host(prompt()));
    await tester.pumpAndSettle();
    expect(find.byKey(_openKey), findsNothing);
    expect(calls, ['batteryStatus']);
  });

  _testAndroid('dismissal persists across remount and foreground return', (
    tester,
  ) async {
    await tester.pumpWidget(_host(prompt()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_dismissKey));
    await tester.pumpAndSettle();
    expect(prefs.getBool(kBatteryPromptDismissedPref), isTrue);
    expect(find.text(_title), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    // Recreate the preference cache to cover a new app session.
    SharedPreferences.setMockInitialValues({
      kBatteryPromptDismissedPref: prefs.getBool(kBatteryPromptDismissedPref)!,
    });
    prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_host(prompt()));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
  });

  _testAndroid('button invokes exactly the existing native settings method', (
    tester,
  ) async {
    await tester.pumpWidget(_host(prompt()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c != 'batteryStatus'), ['openBatterySettings']);
    expect(find.text(_title), findsOneWidget);
  });

  _testAndroid('granting the exemption removes the card on resume', (
    tester,
  ) async {
    await tester.pumpWidget(_host(prompt()));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsOneWidget);
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    status = {'ignoringOptimizations': true, 'backgroundRestricted': false};
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
    expect(prefs.getBool(kBatteryPromptDismissedPref), isNull);
  });

  _testAndroid('push note stays available after Home is dismissed', (
    tester,
  ) async {
    await prefs.setBool(kBatteryPromptDismissedPref, true);
    await tester.pumpWidget(_host(prompt(dismissible: false)));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsOneWidget);
    expect(find.byKey(_dismissKey), findsNothing);
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(calls, contains('openBatterySettings'));
  });

  _testAndroid('labelled actions expose at least 48 dp targets', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_host(prompt()));
      await tester.pumpAndSettle();
      for (final key in [_openKey, _dismissKey]) {
        final size = tester.getSize(find.byKey(key));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      expect(find.bySemanticsLabel('Abrir ajustes de batería'), findsOneWidget);
      expect(find.bySemanticsLabel('Ahora no'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  _testAndroid('320 dp at 2x text fits all locales in light and dark', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final lang in _languages) {
      for (final theme in ['dark', 'console-light']) {
        for (final dismissible in [true, false]) {
          await tester.pumpWidget(
            _host(
              prompt(
                key: ValueKey('$lang/$theme/$dismissible'),
                dismissible: dismissible,
              ),
              lang: lang,
              theme: theme,
              textScale: 2,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(_openKey), findsOneWidget);
          expect(
            tester.takeException(),
            isNull,
            reason: '$lang/$theme/$dismissible',
          );
          for (final text in tester.widgetList<Text>(find.byType(Text))) {
            expect(text.data?.trim(), isNotEmpty);
          }
        }
      }
    }
  });

  for (final lang in _languages) {
    test('$lang has nonempty localized battery prompt copy', () {
      final catalog = jsonDecode(
        File('lib/l10n/app_$lang.arb').readAsStringSync(),
      ) as Map<String, dynamic>;
      for (final key in [
        'batPromptTitle',
        'batPromptBody',
        'batPromptNotNow',
        'batPromptRestore',
        'batPushBatteryNote',
        'batOpenSettings',
      ]) {
        expect(catalog[key], isA<String>(), reason: '$lang/$key');
        expect(
          (catalog[key] as String).trim(),
          isNotEmpty,
          reason: '$lang/$key',
        );
      }
    });
  }
}
