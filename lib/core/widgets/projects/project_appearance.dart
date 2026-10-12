import 'package:flutter/material.dart';

import '../../models/desktop_control_center.dart';

/// Desktop's project appearance vocabulary, mapped to Material glyphs.
///
/// The wire values are exactly Desktop's: icon ids are its codicon names and
/// colors are its `PROFILE_SWATCHES` strings, so a look chosen on the phone
/// renders identically on Desktop and vice versa.
const List<(String, IconData)> projectIconChoices = [
  ('folder-library', Icons.folder_copy_outlined),
  ('repo', Icons.source_outlined),
  ('rocket', Icons.rocket_launch_outlined),
  ('beaker', Icons.science_outlined),
  ('flame', Icons.local_fire_department_outlined),
  ('star-full', Icons.star_rounded),
  ('heart', Icons.favorite_rounded),
  ('zap', Icons.bolt_rounded),
  ('target', Icons.track_changes_rounded),
  ('lightbulb', Icons.lightbulb_outline_rounded),
  ('tools', Icons.build_outlined),
  ('device-desktop', Icons.desktop_windows_outlined),
  ('device-mobile', Icons.smartphone_outlined),
  ('terminal', Icons.terminal_rounded),
  ('dashboard', Icons.dashboard_outlined),
  ('globe', Icons.public_rounded),
  ('broadcast', Icons.podcasts_rounded),
  ('cloud', Icons.cloud_outlined),
  ('database', Icons.storage_rounded),
  ('package', Icons.inventory_2_outlined),
  ('book', Icons.menu_book_outlined),
  ('organization', Icons.groups_outlined),
  ('bug', Icons.bug_report_outlined),
  ('shield', Icons.shield_outlined),
  ('key', Icons.key_rounded),
  ('gift', Icons.card_giftcard_rounded),
  ('telescope', Icons.travel_explore_rounded),
  ('home', Icons.home_outlined),
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
  if (project.noProject) return Icons.home_outlined;
  if (project.automatic) return Icons.source_outlined;
  return Icons.folder_copy_outlined;
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
