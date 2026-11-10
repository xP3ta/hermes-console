import 'package:hermes_android/core/home/launcher/launcher_widget_palette.dart';
// Measures how legible the text tokens are on the material of the content
// boxes (cards, groups, panels, list sections and their rows, the search
// field, the notices), for every preset, in its own brightness. The tests of
// legibility use the same numbers they print, so the table and the checks
// can never disagree.
import 'package:flutter/material.dart';
import 'package:hermes_android/core/home/board/home_board_kit.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/soft_tokens.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';

/// One surface a text token can sit on, opaque, and a short name for it.
typedef LegibilitySurface = (String name, Color color);

/// A text token of a preset, with the colour it paints.
typedef LegibilityInk = (String name, Color color);

/// The opaque surfaces the text of preset [preset] is read on: the bare page
/// and its glow, and the bodies of the content boxes over each of them. A
/// theme that wears no glass has the bodies it falls back to.
List<LegibilitySurface> legibilitySurfaces(HermesThemePreset preset) {
  final colors = preset.colors;
  final glass = GlassMaterial.resolve(colors, GlassLevel.full);
  final page = ThemeContrast.composite(
    colors.background,
    const Color(0xFF000000),
  );
  if (glass == null) {
    return [
      ('page', page),
      ('surface', ThemeContrast.composite(colors.surface, page)),
      ('surfaceVariant', ThemeContrast.composite(colors.surfaceVariant, page)),
      (
        'fallback-group',
        ThemeContrast.composite(
          colors.surfaceVariant.withValues(alpha: 0.3),
          page,
        ),
      ),
    ];
  }
  final out = <LegibilitySurface>[];
  for (final (backName, back) in [('page', page), ('glow', glass.glow)]) {
    final group = ThemeContrast.composite(glass.groupFill, back);
    final card = ThemeContrast.composite(glass.cardFill, back);
    out
      ..add((backName, back))
      ..add(('group/$backName', group))
      ..add(('card/$backName', card))
      ..add((
        'banner/$backName',
        Color.alphaBlend(colors.accent.withValues(alpha: 0.06), card),
      ));
  }
  return out;
}

/// The text tokens of [preset]: the main, the secondary and the tertiary ink,
/// the placeholder of a field, the caption of a section and the inks of the
/// widgets of Home.
List<LegibilityInk> legibilityInks(HermesThemePreset preset) {
  final colors = preset.colors;
  final soft = SoftPalette.of(
    colors,
    ThemeData.estimateBrightnessForColor(colors.background),
  );
  final hint =
      AppTheme.fromId(preset.id).inputDecorationTheme.hintStyle?.color ??
      colors.textSecondary;
  return [
    ('textPrimary', colors.textPrimary),
    ('textSecondary', colors.textSecondary),
    ('textTertiary', colors.textTertiary),
    ('hint', hint),
    ('sectionCaption', colors.textSecondary),
    ('soft.text', soft.text),
    ('soft.textMuted', soft.textMuted),
    (
      'home.faint',
      HomeType.faint(
        HomePalette(LauncherWidgetPalette.of(colors, fontFamily: 'Inter')),
      ),
    ),
  ];
}

/// One measurement: the lowest contrast of [ink] over the surfaces of
/// [preset], and where it is.
class LegibilityCase {
  const LegibilityCase(this.preset, this.ink, this.surface, this.ratio);
  final String preset;
  final String ink;
  final String surface;
  final double ratio;
  @override
  String toString() => '$preset $ink on $surface ${ratio.toStringAsFixed(2)}';
}

/// The worst surface of every (preset, ink).
List<LegibilityCase> measureLegibility() {
  final out = <LegibilityCase>[];
  for (final preset in AppTheme.presets) {
    final surfaces = legibilitySurfaces(preset);
    for (final (inkName, ink) in legibilityInks(preset)) {
      LegibilityCase? worst;
      for (final (surfaceName, surface) in surfaces) {
        final r = ThemeContrast.ratio(ink, surface);
        if (worst == null || r < worst.ratio) {
          worst = LegibilityCase(preset.id, inkName, surfaceName, r);
        }
      }
      out.add(worst!);
    }
  }
  return out;
}

/// How far the body of a box sits from the page, per preset: the contrast of
/// the group and the card over the page and over its glow.
class StepCase {
  const StepCase(this.preset, this.dark, this.group, this.card, this.glow);
  final String preset;
  final bool dark;
  final double group;
  final double card;

  /// The smaller of the two bodies against the glow.
  final double glow;
}

List<StepCase> measureSteps() {
  final out = <StepCase>[];
  for (final preset in AppTheme.presets) {
    final glass = GlassMaterial.resolve(preset.colors, GlassLevel.full);
    if (glass == null) continue;
    double over(Color fill, Color back) =>
        ThemeContrast.ratio(ThemeContrast.composite(fill, back), back);
    out.add(
      StepCase(
        preset.id,
        glass.dark,
        over(glass.groupFill, glass.page),
        over(glass.cardFill, glass.page),
        [
          over(glass.groupFill, glass.glow),
          over(glass.cardFill, glass.glow),
        ].reduce((a, b) => a < b ? a : b),
      ),
    );
  }
  return out;
}

/// The summary as markdown lines, worst cases first.
List<String> legibilityMarkdown(String title) {
  final cases = measureLegibility();
  final dark = <String, bool>{
    for (final p in AppTheme.presets)
      p.id:
          ThemeData.estimateBrightnessForColor(p.colors.background) ==
          Brightness.dark,
  };
  final lines = <String>[
    '### $title',
    '',
    '| ink | worst (dark) | worst (light) | below 4.5 | below 7 |',
    '|---|---|---|---|---|',
  ];
  final names = <String>[];
  for (final c in cases) {
    if (!names.contains(c.ink)) names.add(c.ink);
  }
  for (final name in names) {
    final mine = cases.where((c) => c.ink == name).toList();
    LegibilityCase? worstOf(bool wantDark) {
      final pool = mine.where((c) => dark[c.preset] == wantDark).toList()
        ..sort((a, b) => a.ratio.compareTo(b.ratio));
      return pool.isEmpty ? null : pool.first;
    }

    String cell(LegibilityCase? c) => c == null
        ? '-'
        : '${c.ratio.toStringAsFixed(2)} (${c.preset}, ${c.surface})';
    final below45 = mine.where((c) => c.ratio < 4.5).length;
    final below7 = mine.where((c) => c.ratio < 7).length;
    lines.add(
      '| $name | ${cell(worstOf(true))} | ${cell(worstOf(false))} '
      '| $below45/${mine.length} | $below7/${mine.length} |',
    );
  }
  final steps = measureSteps();
  StepCase? least(bool wantDark, double Function(StepCase) of) {
    final pool = steps.where((s) => s.dark == wantDark).toList()
      ..sort((a, b) => of(a).compareTo(of(b)));
    return pool.isEmpty ? null : pool.first;
  }

  lines
    ..add('')
    ..add('| step body/page | worst group | worst card | worst vs glow |')
    ..add('|---|---|---|---|');
  for (final wantDark in [true, false]) {
    final g = least(wantDark, (s) => s.group);
    final c = least(wantDark, (s) => s.card);
    final w = least(wantDark, (s) => s.glow);
    lines.add(
      '| ${wantDark ? 'dark' : 'light'} '
      '| ${g == null ? '-' : '${g.group.toStringAsFixed(3)} (${g.preset})'} '
      '| ${c == null ? '-' : '${c.card.toStringAsFixed(3)} (${c.preset})'} '
      '| ${w == null ? '-' : '${w.glow.toStringAsFixed(3)} (${w.preset})'} |',
    );
  }
  return lines;
}
