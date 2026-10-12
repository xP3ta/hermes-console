// The home widget and the native day/night setting follow the theme that is
// really active, including the new light variants and saved ids of themes
// removed in 1.2.15.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/home_widget_snapshot.dart';
import 'package:hermes_android/core/theme/active_theme_appearance.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_profile.dart';
import 'package:hermes_android/core/theme/theme_profile_store.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/theme_profile_fixtures.dart';

ThemeProfileStoreSnapshot _snapshot(
  String active, {
  List<ThemeProfile> custom = const [],
}) => ThemeProfileStoreSnapshot(
  customProfiles: custom,
  activeProfileId: active,
  activeComponentProfileId: 'minimal',
);

void main() {
  test('every preset maps to its own brightness', () {
    for (final preset in AppTheme.presets) {
      final snapshot = _snapshot(preset.id);
      expect(
        activeThemeBrightness(snapshot),
        preset.brightness,
        reason: preset.id,
      );
      expect(
        homeWidgetThemeFor(snapshot),
        preset.brightness == Brightness.light
            ? HomeWidgetTheme.light
            : HomeWidgetTheme.dark,
        reason: preset.id,
      );
    }
  });

  test('a removed id still reports its destination, never a crash', () {
    expect(homeWidgetThemeFor(_snapshot('amber-oled')), HomeWidgetTheme.dark);
    expect(homeWidgetThemeFor(_snapshot('light')), HomeWidgetTheme.light);
    expect(homeWidgetThemeFor(_snapshot('no-such-id')), HomeWidgetTheme.dark);
  });

  test('a custom profile uses its own brightness', () {
    final dark = validCustomTheme(id: 'custom-dark');
    expect(
      activeThemeBrightness(_snapshot('custom-dark', custom: [dark])),
      Brightness.dark,
    );
    final light = dark.copyWith(
      id: 'custom-light',
      brightness: ThemeProfileBrightness.light,
    );
    expect(
      homeWidgetThemeFor(_snapshot('custom-light', custom: [light])),
      HomeWidgetTheme.light,
    );
  });

  group('first frame theme id', () {
    Future<SharedPreferences> prefs(Map<String, Object> values) {
      SharedPreferences.setMockInitialValues(values);
      return SharedPreferences.getInstance();
    }

    test('a removed active id is migrated before the first frame', () async {
      final p = await prefs({ThemeProfileStore.activeProfileKey: 'crimson'});
      expect(HermesApp.getThemeId(p), 'bordeaux');
    });

    test('valid and custom ids pass through unchanged', () async {
      var p = await prefs({
        ThemeProfileStore.activeProfileKey: 'dracula-light',
      });
      expect(HermesApp.getThemeId(p), 'dracula-light');
      p = await prefs({ThemeProfileStore.activeProfileKey: 'custom-uuid-1'});
      expect(HermesApp.getThemeId(p), 'custom-uuid-1');
    });

    test('no saved theme paints the Console default', () async {
      final p = await prefs({});
      expect(HermesApp.getThemeId(p), 'console');
    });

    test('a legacy-only key is migrated', () async {
      final p = await prefs({'theme_mode': 'oled'});
      expect(HermesApp.getThemeId(p), 'amber');
    });
  });
}
