import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const liquidMotionSceneKey = ValueKey('liquid-motion-scene');
const liquidMotionDraftKey = ValueKey('liquid-motion-draft');
const liquidMotionPieceKey = ValueKey('liquid-motion-piece');
const liquidMotionDockKey = ValueKey('gesture-dock-glass');

Future<void> prepareLiquidMotionDock() async {
  SharedPreferences.setMockInitialValues({});
  FeatureFlags.instance.resetForTesting();
  GestureDockController.instance.resetForTesting(
    settings: const GestureDockSettings(
      tabs: GestureDockTab.legacyDefaultLayout,
    ),
  );
  DockGeometry.instance.resetForTesting();
  await DockPreferencesController.instance.ensureLoaded();
}

/// The exact child is retained while ancestor/local scopes change. The dock
/// adds its own real moving:false scope while its hide animation is at rest.
Widget liquidMotionApp({
  required ValueListenable<bool> outer,
  required ValueListenable<bool> inner,
  required TextEditingController draft,
  Offset travel = Offset.zero,
}) => MaterialApp(
  theme: AppTheme.fromId('classic-dark'),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    body: ValueListenableBuilder<bool>(
      valueListenable: outer,
      child: ValueListenableBuilder<bool>(
        valueListenable: inner,
        child: Stack(
          key: liquidMotionSceneKey,
          fit: StackFit.expand,
          children: [
            Center(
              child: HermesGlassStrip(
                liquid: HermesLiquid.header,
                child: Builder(
                  builder: (context) => HermesGlassPiece(
                    key: liquidMotionPieceKey,
                    shape: const StadiumBorder(),
                    child: ColoredBox(
                      color: HermesGlassStrip.of(context)!.veil,
                      child: SizedBox(
                        width: 220,
                        height: 56,
                        child: TextField(
                          key: liquidMotionDraftKey,
                          controller: draft,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            GestureDock(
              current: GestureDockTab.home,
              onTab: {
                for (final tab in GestureDockTab.legacyDefaultLayout)
                  tab: () {},
              },
            ),
          ],
        ),
        builder: (_, moving, child) =>
            HermesLiquidMotion(moving: moving, child: child!),
      ),
      builder: (_, moving, child) => Transform.translate(
        offset: moving ? travel : Offset.zero,
        child: HermesLiquidMotion(moving: moving, child: child!),
      ),
    ),
  ),
);

Rect liquidMotionRelativeRect(WidgetTester tester, Finder finder) => tester
    .getRect(finder)
    .shift(-tester.getTopLeft(find.byKey(liquidMotionSceneKey)));
