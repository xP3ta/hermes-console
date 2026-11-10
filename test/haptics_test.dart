// Haptic feedback: the «Respuesta háptica» setting (on by default, saved),
// the one door every tick goes through (silent when it is off, never twice in
// a blink), the fallback tick of every enabled control, and the switch in
// Look & Feel.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/feedback/haptics.dart';
import 'package:hermes_android/core/screens/look_feel_screen.dart';
import 'package:hermes_android/core/theme/look_feel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The ticks the platform was asked for, by name.
List<String> _ticks = <String>[];
List<String> _native = <String>[];

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Future<HapticPrefs> use({bool? enabled}) async {
    SharedPreferences.setMockInitialValues({HapticPrefs.key: ?enabled});
    final store = await HapticPrefs.load();
    HapticPrefs.debugUse(store);
    HermesHaptics.debugReset();
    return store;
  }

  setUp(() {
    _ticks = <String>[];
    _native = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          _ticks.add(call.arguments as String);
        }
        return null;
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('hermes/haptics'),
      (call) async {
        _native.add('${call.method}:${call.arguments}');
        return true;
      },
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('hermes/haptics'),
      null,
    );
    HapticPrefs.debugUse(null);
  });

  group('setting', () {
    test('is on by default', () async {
      final prefs = await use();
      expect(prefs.enabled, isTrue);
      expect(HermesHaptics.enabled, isTrue);
    });

    test('is saved, and read back after a restart', () async {
      final prefs = await use();
      await prefs.setEnabled(false);
      final again = await HapticPrefs.load();
      expect(again.enabled, isFalse);
      await again.setEnabled(true);
      expect((await HapticPrefs.load()).enabled, isTrue);
    });

    test('changing it tells the native side', () async {
      final prefs = await use();
      await prefs.setEnabled(false);
      await prefs.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      expect(_native, <String>['setEnabled:false', 'setEnabled:true']);
    });
  });

  group('one door', () {
    test('each event plays its own strength', () async {
      await use();
      final plays = <String, void Function()>{
        'HapticFeedbackType.selectionClick': HermesHaptics.selection,
        'HapticFeedbackType.lightImpact': HermesHaptics.tap,
        'HapticFeedbackType.mediumImpact': HermesHaptics.confirm,
        'HapticFeedbackType.heavyImpact': HermesHaptics.error,
      };
      for (final entry in plays.entries) {
        HermesHaptics.debugReset();
        _ticks.clear();
        entry.value();
        await Future<void>.delayed(Duration.zero);
        expect(_ticks, <String>[entry.key]);
      }
      HermesHaptics.debugReset();
      _ticks.clear();
      HermesHaptics.success();
      await Future<void>.delayed(Duration.zero);
      expect(_ticks, <String>['HapticFeedbackType.mediumImpact']);
    });

    test('a warning is one light tick', () async {
      await use();
      HermesHaptics.warning();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(_ticks, <String>['HapticFeedbackType.lightImpact']);
    });

    test('is silent when the setting is off', () async {
      final prefs = await use(enabled: false);
      expect(prefs.enabled, isFalse);
      HermesHaptics.selection();
      HermesHaptics.tap();
      HermesHaptics.confirm();
      HermesHaptics.success();
      HermesHaptics.warning();
      HermesHaptics.error();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(_ticks, isEmpty);
      expect(HermesHaptics.firedCount, 0);
    });

    test('finger ticks are never held back: every key ticks', () async {
      await use();
      for (var i = 0; i < 5; i++) {
        HermesHaptics.selection();
      }
      HermesHaptics.tap();
      HermesHaptics.confirm();
      await Future<void>.delayed(Duration.zero);
      expect(_ticks, hasLength(7));
    });

    test('a burst of app events (turn errors) buzzes once', () async {
      await use();
      HermesHaptics.error();
      HermesHaptics.error();
      HermesHaptics.success();
      HermesHaptics.warning();
      await Future<void>.delayed(Duration.zero);
      expect(_ticks, <String>['HapticFeedbackType.heavyImpact']);
      HermesHaptics.debugReset();
      HermesHaptics.success();
      await Future<void>.delayed(Duration.zero);
      expect(_ticks, hasLength(2));
    });
  });

  group('every control', () {
    Future<void> pump(WidgetTester tester, Widget body) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HermesTapHaptics(
            child: Scaffold(body: Center(child: body)),
          ),
        ),
      );
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 70));
    }

    testWidgets('a button gets its light tick', (tester) async {
      await use();
      var pressed = 0;
      await pump(
        tester,
        FilledButton(onPressed: () => pressed++, child: const Text('Go')),
      );
      await tester.tap(find.text('Go'));
      await settle(tester);
      expect(pressed, 1);
      expect(_ticks, <String>['HapticFeedbackType.lightImpact']);
    });

    testWidgets('an icon button, a switch and a checkbox do too', (
      tester,
    ) async {
      await use();
      var on = false;
      await pump(
        tester,
        StatefulBuilder(
          builder: (context, set) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const Key('ib'),
                onPressed: () {},
                icon: const Icon(Icons.add),
              ),
              Switch(
                key: const Key('sw'),
                value: on,
                onChanged: (v) => set(() => on = v),
              ),
              Checkbox(
                key: const Key('cb'),
                value: on,
                onChanged: (v) => set(() => on = v!),
              ),
            ],
          ),
        ),
      );
      for (final key in const ['ib', 'sw', 'cb']) {
        HermesHaptics.debugReset();
        _ticks.clear();
        await tester.tap(find.byKey(Key(key)));
        await settle(tester);
        expect(_ticks, <String>['HapticFeedbackType.lightImpact'], reason: key);
        await tester.pump(const Duration(milliseconds: 100));
      }
    });

    testWidgets('a control with its own tick is not doubled', (tester) async {
      await use();
      await pump(
        tester,
        FilledButton(
          onPressed: HermesHaptics.confirm,
          child: const Text('Send'),
        ),
      );
      await tester.tap(find.text('Send'));
      await settle(tester);
      expect(_ticks, <String>['HapticFeedbackType.mediumImpact']);
    });

    testWidgets('a disabled button is silent', (tester) async {
      await use();
      await pump(
        tester,
        const FilledButton(onPressed: null, child: Text('Off')),
      );
      await tester.tap(find.text('Off'), warnIfMissed: false);
      await settle(tester);
      expect(_ticks, isEmpty);
    });

    testWidgets('text and a text field are silent', (tester) async {
      await use();
      await pump(
        tester,
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('hello'),
            SizedBox(width: 200, child: TextField()),
          ],
        ),
      );
      await tester.tap(find.text('hello'));
      await tester.tap(find.byType(TextField));
      await settle(tester);
      expect(_ticks, isEmpty);
    });

    testWidgets('a scroll over a button is not a tap', (tester) async {
      await use();
      await pump(
        tester,
        SizedBox(
          height: 300,
          child: ListView(
            children: [
              for (var i = 0; i < 30; i++)
                SizedBox(
                  height: 60,
                  child: FilledButton(onPressed: () {}, child: Text('b$i')),
                ),
            ],
          ),
        ),
      );
      await tester.drag(find.text('b2'), const Offset(0, -200));
      await settle(tester);
      expect(_ticks, isEmpty);
      // A short scroll (past the scroll's own slop, under twice it) is a
      // scroll too: the list moved, so the button was not tapped.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('b5')),
      );
      await gesture.moveBy(const Offset(0, -10));
      await gesture.moveBy(const Offset(0, -20));
      await gesture.up();
      await settle(tester);
      expect(_ticks, isEmpty);
    });

    testWidgets('with the setting off nothing buzzes', (tester) async {
      await use(enabled: false);
      await pump(
        tester,
        FilledButton(onPressed: () {}, child: const Text('Go')),
      );
      await tester.tap(find.text('Go'));
      await settle(tester);
      expect(_ticks, isEmpty);
    });

    testWidgets('it syncs the saved setting with the native view', (
      tester,
    ) async {
      await use(enabled: false);
      await pump(tester, const SizedBox());
      await tester.pump();
      expect(_native, contains('setEnabled:false'));
    });
  });

  testWidgets('Look & Feel has the switch, on, and it turns the setting', (
    tester,
  ) async {
    final prefs = await use();
    SharedPreferences.setMockInitialValues({});
    final look = LookFeelPrefs(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: LookFeelScreen(prefsForTesting: look),
      ),
    );
    await tester.pump();
    final tile = find.byKey(const ValueKey('lfl-haptics'));
    expect(tile, findsOneWidget);
    expect(find.text('Respuesta háptica'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    await tester.tap(tile);
    await tester.pump();
    expect(prefs.enabled, isFalse);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
  });
}
