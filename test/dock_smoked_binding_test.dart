import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show BackdropFilterLayer;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock_style.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(String theme) => MaterialApp(
  theme: AppTheme.fromId(theme),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    body: Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFFE53935)),
        ListenableBuilder(
          listenable: DockPreferencesController.instance.listenable,
          builder: (_, _) => GestureDock(
            current: GestureDockTab.home,
            onTab: {GestureDockTab.create: () {}, GestureDockTab.search: () {}},
          ),
        ),
      ],
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(tabs: GestureDockTab.defaultLayout),
    );
    FrostedBackdropPolicy.reducedPerformance.value = false;
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
    await DockPreferencesController.instance.updateGeneral(
      (p) => p.copyWith(style: const DockStyle()),
      persist: false,
    );
  });
  tearDown(() {
    FrostedBackdropPolicy.reducedPerformance.value = false;
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
  });
  for (final theme in ['classic-dark', 'console-light']) {
    testWidgets('$theme: tone shares one filter, respects the chosen floor and '
        'drops it immediately on policy veto without moving controls', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final shaderLoads = HermesLiquidShader.loadAttempts;
      await tester.pumpWidget(_app(theme));
      await tester.pumpAndSettle();
      final fill = find.byKey(const ValueKey('gesture-dock-glass'));
      final rect = tester.getRect(fill);
      HermesGlass? glass() => HermesGlassStrip.of(tester.element(fill));
      expect(glass()?.tone, isNotNull);
      expect(tester.layers.whereType<BackdropFilterLayer>().length, 1);
      final colors = AppTheme.fromId(theme).hermes;
      expect(
        glass()!.tone!.worstRatio(colors.textPrimary, HermesChrome.of(colors)),
        greaterThanOrEqualTo(4.5),
      );
      final visual = resolveDockVisual(colors, const DockStyle());
      expect(glass()!.veil.a, greaterThanOrEqualTo(visual.background.a));
      FrostedBackdropPolicy.blurAllowed.value = false;
      await tester.pump();
      expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
      expect(tester.getRect(fill), rect);
      expect(
        (tester.widget<DecoratedBox>(fill).decoration as BoxDecoration)
            .color!
            .a,
        1,
      );
      FrostedBackdropPolicy.blurAllowed.value = true;
      await tester.pumpAndSettle();
      expect(glass()?.tone, isNotNull);
      expect(tester.getRect(fill), rect);
      await DockPreferencesController.instance.updateGeneral(
        (p) => p.copyWith(style: p.style.copyWith(transparency: 0)),
        persist: false,
      );
      await tester.pumpAndSettle();
      expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
      expect(tester.getRect(fill), rect);
      expect(
        (tester.widget<DecoratedBox>(fill).decoration as BoxDecoration)
            .color!
            .a,
        1,
      );
      expect(HermesLiquidShader.loadAttempts, shaderLoads);
      expect(tester.takeException(), isNull);
    });
  }
}
