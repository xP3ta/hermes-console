import 'package:flutter/material.dart';

import '../models/home_widget_snapshot.dart';
import 'app_theme.dart';
import 'theme_profile.dart';
import 'theme_profile_store.dart';

/// Brightness of the theme that is really active: a custom profile's own
/// brightness, or the preset's (a retired id counts as its survivor); with
/// "Auto" on, the system's [platformBrightness]. The native day/night
/// setting and the home widget both read it, so neither can disagree with
/// the app.
Brightness activeThemeBrightness(
  ThemeProfileStoreSnapshot snapshot, {
  Brightness? platformBrightness,
}) {
  if (platformBrightness != null && followSystemThemeIds(snapshot) != null) {
    return platformBrightness;
  }
  final custom = snapshot.customById(snapshot.activeProfileId);
  if (custom != null) {
    return custom.brightness == ThemeProfileBrightness.light
        ? Brightness.light
        : Brightness.dark;
  }
  return AppTheme.presetById(
    AppTheme.migrateStoredThemeId(snapshot.activeProfileId),
  ).brightness;
}

/// Home widget appearance for [snapshot]: light or dark, like the app.
HomeWidgetTheme homeWidgetThemeFor(
  ThemeProfileStoreSnapshot snapshot, {
  Brightness? platformBrightness,
}) =>
    activeThemeBrightness(snapshot, platformBrightness: platformBrightness) ==
        Brightness.light
    ? HomeWidgetTheme.light
    : HomeWidgetTheme.dark;

/// With "Auto" on, the built-in family's light and dark ids for
/// `MaterialApp.theme` / `darkTheme`; null when one theme applies.
({String light, String dark})? followSystemThemeIds(
  ThemeProfileStoreSnapshot snapshot,
) {
  if (!snapshot.followSystem) return null;
  if (snapshot.customById(snapshot.activeProfileId) != null) return null;
  final id = AppTheme.migrateStoredThemeId(snapshot.activeProfileId);
  if (!AppTheme.presets.any((p) => p.id == id)) return null;
  return (
    light: AppTheme.variantFor(id, Brightness.light),
    dark: AppTheme.variantFor(id, Brightness.dark),
  );
}
