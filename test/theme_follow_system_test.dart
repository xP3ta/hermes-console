// "Auto" in every family's Light/Dark selector: the family follows the
// system appearance. The choice persists, a manual Light/Dark pick or a
// custom theme turns it off, and the app, the home widget and the native
// day/night setting all read the same resolved brightness.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/home_widget_snapshot.dart';
import 'package:hermes_android/core/screens/themes_screen.dart';
import 'package:hermes_android/core/theme/active_theme_appearance.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_profile_store.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/theme_profile_fixtures.dart';

ThemeProfileStoreSnapshot _snapshot(String active, {bool auto = false}) =>
    ThemeProfileStoreSnapshot(
      customProfiles: const [],
      activeProfileId: active,
      activeComponentProfileId: 'minimal',
      followSystem: auto,
    );

void main() {
  group('store', () {
    Future<SharedPreferences> fresh() async {
      SharedPreferences.setMockInitialValues({});
      return SharedPreferences.getInstance();
    }

    test('Auto persists across a restart', () async {
      final prefs = await fresh();
      await ThemeProfileStore(prefs).activate('claude', followSystem: true);

      final restarted = await ThemeProfileStore(prefs).load();
      expect(restarted.activeProfileId, 'claude');
      expect(restarted.followSystem, isTrue);
    });

    test('a manual Light or Dark pick turns Auto off', () async {
      final prefs = await fresh();
      final store = ThemeProfileStore(prefs);
      await store.activate('claude', followSystem: true);
      await store.activate('claude-light');

      final restarted = await ThemeProfileStore(prefs).load();
      expect(restarted.activeProfileId, 'claude-light');
      expect(restarted.followSystem, isFalse);
      expect(prefs.getBool(ThemeProfileStore.followSystemKey), isNull);
    });

    test('a custom theme never follows the system', () async {
      final prefs = await fresh();
      final store = ThemeProfileStore(prefs);
      await store.activate('console', followSystem: true);
      final custom = validCustomTheme(id: 'mine');
      await store.save(custom);
      await store.activate(custom.id, followSystem: true);

      final restarted = await ThemeProfileStore(prefs).load();
      expect(restarted.activeProfileId, 'mine');
      expect(restarted.followSystem, isFalse);
    });

    test('installs without the key are not Auto', () async {
      final prefs = await fresh();
      expect((await ThemeProfileStore(prefs).load()).followSystem, isFalse);
    });
  });

  group('resolution', () {
    test('variantFor picks the family member in each brightness', () {
      expect(AppTheme.variantFor('console', Brightness.light), 'console-light');
      expect(AppTheme.variantFor('console-light', Brightness.dark), 'console');
      expect(
        AppTheme.variantFor('midnight', Brightness.light),
        'midnight-light',
      );
      expect(AppTheme.variantFor('nous', Brightness.dark), 'nous-dark');
      expect(AppTheme.variantFor('custom-x', Brightness.dark), 'custom-x');
    });

    test('Auto gives the app both family themes', () {
      expect(followSystemThemeIds(_snapshot('claude')), isNull);
      final pair = followSystemThemeIds(_snapshot('claude-light', auto: true));
      expect(pair, (light: 'claude-light', dark: 'claude'));
    });

    test('Auto: native and home widget follow the system brightness', () {
      final auto = _snapshot('console', auto: true);
      expect(
        activeThemeBrightness(auto, platformBrightness: Brightness.light),
        Brightness.light,
      );
      expect(
        homeWidgetThemeFor(auto, platformBrightness: Brightness.light),
        HomeWidgetTheme.light,
      );
      expect(
        activeThemeBrightness(auto, platformBrightness: Brightness.dark),
        Brightness.dark,
      );
      // Without Auto the system brightness is ignored.
      expect(
        activeThemeBrightness(
          _snapshot('console'),
          platformBrightness: Brightness.light,
        ),
        Brightness.dark,
      );
    });
  });

  group('themes screen', () {
    Widget app(
      ThemeProfileStoreSnapshot snapshot,
      List<(String, bool)> picks, {
      Brightness platform = Brightness.light,
    }) => MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId(snapshot.activeProfileId),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(platformBrightness: platform, disableAnimations: true),
        child: child!,
      ),
      home: ThemesScreen(
        snapshotForTesting: snapshot,
        onSelectForTesting: (id, {followSystem = false}) async =>
            picks.add((id, followSystem)),
      ),
    );

    testWidgets('every family offers Auto next to Light and Dark', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 6000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(_snapshot('console'), []));
      await tester.pump();
      final families = AppTheme.presets.map((p) => p).toList();
      for (final preset in families) {
        final section = preset.desktopOfficial ? 'desktop' : 'console';
        expect(
          find.byKey(ValueKey('$section-theme-${preset.familyId}-auto')),
          findsOneWidget,
          reason: preset.familyId,
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping Auto applies the variant the system shows', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 6000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final picks = <(String, bool)>[];
      await tester.pumpWidget(app(_snapshot('console'), picks));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('console-theme-claude-auto')));
      await tester.pump();
      expect(picks, [('claude-light', true)]);

      picks.clear();
      await tester.pumpWidget(
        app(_snapshot('console'), picks, platform: Brightness.dark),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('console-theme-claude-auto')));
      await tester.pump();
      expect(picks, [('claude', true)]);
    });

    testWidgets('Auto is the selected segment while it is on', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 6000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      bool selected(String key) =>
          tester
              .getSemantics(find.byKey(ValueKey(key)))
              .flagsCollection
              .isSelected ==
          Tristate.isTrue;
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(app(_snapshot('console-light', auto: true), []));
      await tester.pump();
      expect(selected('console-theme-console-auto'), isTrue);
      expect(selected('console-theme-console-light'), isFalse);
      expect(selected('console-theme-console-dark'), isFalse);

      await tester.pumpWidget(app(_snapshot('console-light'), []));
      await tester.pump();
      expect(selected('console-theme-console-auto'), isFalse);
      expect(selected('console-theme-console-light'), isTrue);
      handle.dispose();
    });
  });
}
