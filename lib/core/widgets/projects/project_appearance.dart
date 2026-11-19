import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/material.dart';

import '../../models/desktop_control_center.dart';

/// Desktop's project appearance vocabulary, mapped to Material glyphs.
///
/// The wire values are exactly Desktop's: icon ids are its codicon names and
/// colors are its `PROFILE_SWATCHES` strings, so a look chosen on the phone
/// renders identically on Desktop and vice versa.
const List<(String, IconData)> projectIconChoices = [
  ('folder-library', HIcons.folder_copy_outlined),
  ('repo', HIcons.source_outlined),
  ('rocket', HIcons.rocket_launch_outlined),
  ('beaker', HIcons.science_outlined),
  ('flame', HIcons.local_fire_department_outlined),
  ('star-full', HIcons.star_rounded),
  ('heart', HIcons.favorite_rounded),
  ('zap', HIcons.bolt_rounded),
  ('target', HIcons.track_changes_rounded),
  ('lightbulb', HIcons.lightbulb_outline_rounded),
  ('tools', HIcons.build_outlined),
  ('device-desktop', HIcons.desktop_windows_outlined),
  ('device-mobile', HIcons.smartphone_outlined),
  ('terminal', HIcons.terminal_rounded),
  ('dashboard', HIcons.dashboard_outlined),
  ('globe', HIcons.public_rounded),
  ('broadcast', HIcons.podcasts_rounded),
  ('cloud', HIcons.cloud_outlined),
  ('database', HIcons.storage_rounded),
  ('package', HIcons.inventory_2_outlined),
  ('book', HIcons.menu_book_outlined),
  ('organization', HIcons.groups_outlined),
  ('bug', HIcons.bug_report_outlined),
  ('shield', HIcons.shield_outlined),
  ('key', HIcons.key_rounded),
  ('gift', HIcons.card_giftcard_rounded),
  ('telescope', HIcons.travel_explore_rounded),
  ('home', HIcons.home_outlined),
];

/// Desktop `PROFILE_SWATCHES`: 12 hues, 68 % saturation, 58 % lightness.
final List<String> projectColorSwatches = List.unmodifiable([
  for (var index = 0; index < 12; index++) 'hsl(${index * 30} 68% 58%)',
]);

IconData? projectIconFor(String id) {
  for (final (name, icon) in projectIconChoices) {
    if (name == id) return icon;
  }
  return null;
}

/// Default glyph when no icon is chosen, matching Desktop's overview rows.
IconData projectDefaultIcon(ProjectNode project) {
  if (project.noProject) return HIcons.home_outlined;
  if (project.automatic) return HIcons.source_outlined;
  return HIcons.folder_copy_outlined;
}

IconData projectGlyph(ProjectNode project) =>
    projectIconFor(project.icon) ?? projectDefaultIcon(project);

final RegExp _hslPattern = RegExp(
  r'^hsla?\(\s*(-?[\d.]+)(?:deg)?[\s,]+([\d.]+)%[\s,]+([\d.]+)%',
);

/// Parses the CSS colors Desktop stores (`hsl(…)` or `#rrggbb`). Unknown
/// strings yield null so the UI falls back to its neutral tint.
Color? parseProjectColor(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final hsl = _hslPattern.firstMatch(value);
  if (hsl != null) {
    final h = double.tryParse(hsl.group(1)!);
    final s = double.tryParse(hsl.group(2)!);
    final l = double.tryParse(hsl.group(3)!);
    if (h == null || s == null || l == null) return null;
    return HSLColor.fromAHSL(
      1,
      h % 360,
      (s / 100).clamp(0, 1),
      (l / 100).clamp(0, 1),
    ).toColor();
  }
  if (value.startsWith('#')) {
    var hex = value.substring(1);
    if (hex.length == 3) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;
    final parsed = int.tryParse(hex, radix: 16);
    return parsed == null ? null : Color(parsed);
  }
  return null;
}
