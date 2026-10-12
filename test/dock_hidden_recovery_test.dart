// A dock hidden by hand can always be brought back.
//
// Owner report (2026-10-11, Pixel, gesture navigation): "lo oculté y ahora
// se fue y no aparece el dock". What a hidden dock used to leave on screen
// was a 56 x 5 dp strip whose 35 dp touch area sat flush on the navigation
// inset, inside the zone where Android takes swipes; nothing else brought
// it back ("Usar dock flotante" off and on, another screen, the other
// mode). These tests pin what replaces it: a pill inside a touch target of
// at least 48 dp, above the system's area, one tap.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_mode.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

GestureDockController get _c => GestureDockController.instance;

const _screenHeight = 780.0;
const _handle = ValueKey('gesture-dock-handle');
const _pill = ValueKey('gesture-dock-handle-pill');
const _bar = ValueKey('gesture-dock-pointer');

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('classic-dark'),
  home: home,
);

/// A screen with a dock, as Home mounts it.
Widget _screen({List<String>? log, String name = 'home'}) => Scaffold(
  body: Stack(
    fit: StackFit.expand,
    children: [
      Center(child: Text(name)),
      Dock(
        profileId: DockProfileId.general,
        actions: {
          DockItemId.home: const DockItemAction(selected: true),
          DockItemId.create: DockItemAction(onTap: () => log?.add('create')),
          DockItemId.settings: DockItemAction(
            onTap: () => log?.add('settings'),
          ),
        },
      ),
    ],
  ),
);

/// 360 x 780 dp phone with [nav] dp of navigation inset and [gesture] dp of
/// system gesture zone along the bottom edge.
void _phone(WidgetTester tester, {double nav = 24, double gesture = 24}) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.viewPadding = FakeViewPadding(bottom: nav * 3);
  tester.view.padding = FakeViewPadding(bottom: nav * 3);
  tester.view.systemGestureInsets = FakeViewPadding(
    left: 90,
    right: 90,
    bottom: gesture * 3,
  );
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

double _barOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .descendant(of: find.byKey(_bar), matching: find.byType(Opacity))
          .first,
    )
    .opacity;

double _handleOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(_handle),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

bool _handleTakesTouches(WidgetTester tester) => !tester
    .widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byKey(_handle),
            matching: find.byType(IgnorePointer),
          )
          .first,
    )
    .ignoring;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.instance.resetForTesting(gestureDock: true);
    _c.resetForTesting(
      settings: const GestureDockSettings(
        tabs: GestureDockTab.legacyDefaultLayout,
      ),
    );
    DockGeometry.instance.resetForTesting();
    DockModes.instance.resetForTesting();
  });

  tearDown(() async {
    FeatureFlags.instance.resetForTesting();
    await DockPreferencesController.instance.setUseDock(true);
  });

  group('hidden by hand: the handle', () {
    // Navigation inset and system gesture zone, in dp: gesture navigation
    // (the zone can be taller than the inset), three buttons, and a device
    // that reports neither.
    for (final (nav, gesture) in const [
      (24.0, 24.0),
      (24.0, 32.0),
      (24.0, 48.0),
      (16.0, 32.0),
      (48.0, 48.0),
      (0.0, 0.0),
    ]) {
      testWidgets('inset $nav dp, gesture zone $gesture dp: a pill in a '
          '48 dp target above the system area; one tap brings the dock back', (
        tester,
      ) async {
        _phone(tester, nav: nav, gesture: gesture);
        final log = <String>[];
        await tester.pumpWidget(_app(_screen(log: log)));
        await _settle(tester);
        expect(_barOpacity(tester), 1);
        expect(_handleTakesTouches(tester), isFalse);

        _c.setHidden(true);
        await _settle(tester);

        expect(_barOpacity(tester), 0, reason: 'the bar is away');
        expect(_handleOpacity(tester), 1, reason: 'the handle is in view');
        expect(_handleTakesTouches(tester), isTrue);
        final target = tester.getRect(find.byKey(_handle));
        final pill = tester.getRect(find.byKey(_pill));
        expect(target.width, greaterThanOrEqualTo(48));
        expect(target.height, greaterThanOrEqualTo(48));
        expect(pill.width, greaterThanOrEqualTo(48));
        expect(pill.height, greaterThanOrEqualTo(24));
        expect(target.contains(pill.topLeft), isTrue);
        expect(target.contains(pill.bottomRight), isTrue);
        final system = math.max(nav, gesture);
        expect(
          _screenHeight - target.bottom,
          greaterThan(system),
          reason: 'the whole target is above the system area',
        );
        expect(target.center.dx, 180, reason: 'centred');

        await tester.tap(find.byKey(_handle));
        await _settle(tester);
        expect(_c.hidden.value, isFalse);
        expect(_barOpacity(tester), 1);
        expect(_handleOpacity(tester), 0);
        expect(_handleTakesTouches(tester), isFalse);
        expect(log, isEmpty, reason: 'the tap went to the handle only');
      });
    }

    testWidgets('a hidden bar takes no tap; back in view, it does', (
      tester,
    ) async {
      _phone(tester);
      final log = <String>[];
      await tester.pumpWidget(_app(_screen(log: log)));
      await _settle(tester);
      final settings = tester.getCenter(
        find.byKey(const ValueKey('gesture-dock-tab-settings')),
      );
      _c.setHidden(true);
      await _settle(tester);
      await tester.tapAt(settings);
      await tester.pump();
      expect(log, isEmpty);

      await tester.tap(find.byKey(_handle));
      await _settle(tester);
      await tester.tapAt(settings);
      await tester.pump();
      expect(log, ['settings']);
    });

    testWidgets('every screen with a dock shows the handle', (tester) async {
      _phone(tester, gesture: 48);
      await tester.pumpWidget(_app(_screen()));
      await _settle(tester);
      _c.setHidden(true);
      await _settle(tester);

      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(MaterialPageRoute<void>(builder: (_) => _screen(name: 'next')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('next'), findsOneWidget);
      expect(_c.hidden.value, isTrue);
      final handle = find.byKey(_handle).hitTestable();
      expect(handle, findsOneWidget);
      await tester.tap(handle);
      await _settle(tester);
      expect(_c.hidden.value, isFalse);
    });

    testWidgets('the handle is a labelled button for TalkBack', (tester) async {
      _phone(tester);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_app(_screen()));
      await _settle(tester);
      _c.setHidden(true);
      await _settle(tester);
      final strings = Strings.of(tester.element(find.byKey(_handle)));
      expect(
        tester.getSemantics(find.byKey(_handle)),
        matchesSemantics(
          label: strings.gdShowDock,
          isButton: true,
          hasTapAction: true,
        ),
      );
      _c.setHidden(false);
      await _settle(tester);
      semantics.dispose();
    });
  });

  group('nothing else leaves the app without a dock', () {
    testWidgets('"Usar dock flotante" off and on again shows the dock', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(_screen()));
      await _settle(tester);
      _c.setHidden(true);
      await _settle(tester);

      await DockPreferencesController.instance.setUseDock(false);
      await tester.pump();
      expect(find.byKey(_bar), findsNothing);
      expect(find.byKey(_handle), findsNothing);

      await DockPreferencesController.instance.setUseDock(true);
      await _settle(tester);
      expect(_c.hidden.value, isFalse);
      expect(_barOpacity(tester), 1);
    });

    test('a dock hidden by hand is back on the next app start', () async {
      SharedPreferences.setMockInitialValues({});
      final running = GestureDockController();
      await running.ensureLoaded();
      await running.setOpaque(true);
      running.setHidden(true);
      expect(running.hidden.value, isTrue);

      // Nothing about "hidden" is ever written.
      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString(GestureDockController.storageKey)!)
              as Map<String, dynamic>;
      expect(stored.keys, isNot(contains('hidden')));

      // Even a payload that claims it starts shown.
      await prefs.setString(
        GestureDockController.storageKey,
        jsonEncode({...stored, 'hidden': true}),
      );
      final restarted = GestureDockController();
      await restarted.ensureLoaded();
      expect(restarted.value.opaque, isTrue, reason: 'settings were read');
      expect(restarted.hidden.value, isFalse);
    });

    testWidgets('the keyboard closing brings the dock back even when nothing '
        'rebuilds it', (tester) async {
      // No bottom inset: nothing in the dock's MediaQuery changes with the
      // keyboard, so only the dock itself can notice it closed.
      _phone(tester, nav: 0, gesture: 0);
      final screen = _app(_screen());
      await tester.pumpWidget(screen);
      await _settle(tester);
      IgnorePointer gate() => tester.widget<IgnorePointer>(
        find.byKey(const ValueKey('gesture-dock-keyboard-gate')),
      );
      expect(gate().ignoring, isFalse);

      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(gate().ignoring, isTrue, reason: 'aside while typing');

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(gate().ignoring, isFalse, reason: 'back once it closes');
      expect(_barOpacity(tester), 1);
    });

    testWidgets('a hidden dock keeps its handle after the keyboard closes', (
      tester,
    ) async {
      _phone(tester, gesture: 32);
      await tester.pumpWidget(_app(_screen()));
      await _settle(tester);
      _c.setHidden(true);
      await _settle(tester);

      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(_handle).hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(_handle));
      await _settle(tester);
      expect(_c.hidden.value, isFalse);
    });
  });
}
