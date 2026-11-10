// Indigo glass: two presets that carry the approved mock-up palette. The
// Claude-bands sweep exempts them (they are darker and more saturated by
// design); this file pins what makes them a valid, selectable theme instead.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';

void main() {
  final dark = AppTheme.presetById('indigo-glass');
  final light = AppTheme.presetById('indigo-glass-light');

  test('both presets exist, share one family card and keep the default', () {
    expect(dark.id, 'indigo-glass');
    expect(light.id, 'indigo-glass-light');
    expect(dark.brightness, Brightness.dark);
    expect(light.brightness, Brightness.light);
    expect(dark.familyId, 'indigo-glass');
    expect(light.familyId, 'indigo-glass');
    expect(dark.name, 'Índigo cristal');
    expect(light.name, dark.name);
    expect(AppTheme.variantFor('indigo-glass', Brightness.light), light.id);
    expect(AppTheme.variantFor('indigo-glass-light', Brightness.dark), dark.id);
    expect(AppTheme.defaultThemeId, 'console');
    expect(AppTheme.presets.first.id, 'console');
  });

  test('radius and typography match Console', () {
    final console = AppTheme.presetById('console');
    for (final p in [dark, light]) {
      expect(p.radius, console.radius);
      expect(p.fontFamily, console.fontFamily);
      expect(p.titleWeight, console.titleWeight);
      expect(p.titleSpacing, console.titleSpacing);
      expect(p.uppercaseTitles, console.uppercaseTitles);
      expect(p.desktopOfficial, isFalse);
    }
  });

  test('the mock-up variables are carried verbatim', () {
    expect(dark.colors.background, const Color(0xFF08090F));
    expect(dark.colors.textPrimary, const Color(0xFFF3F4F8));
    expect(dark.colors.accent, const Color(0xFF5B6CFF));
    expect(dark.colors.accentHover, const Color(0xFF9B86FF));
    expect(dark.colors.warning, const Color(0xFFFFB454));
    expect(dark.colors.success, const Color(0xFF4CD6A4));
    expect(light.colors.background, const Color(0xFFF1EEF8));
    expect(light.colors.textPrimary, const Color(0xFF1B1B1F));
    expect(light.colors.accent, const Color(0xFF5B6CFF));
    // The divider is white at 14 % over the page (the mock-up hairline).
    final hairline = ThemeContrast.composite(
      const Color(0x24FFFFFF),
      dark.colors.background,
    );
    for (final (a, b) in [
      (hairline.r, dark.colors.divider.r),
      (hairline.g, dark.colors.divider.g),
      (hairline.b, dark.colors.divider.b),
    ]) {
      expect((a - b).abs() * 255, lessThan(2.0));
    }
  });

  test('every ink reads at AA on the page and both surfaces', () {
    final fails = <String>[];
    for (final p in [dark, light]) {
      final c = p.colors;
      for (final (sName, bg) in [
        ('background', c.background),
        ('surface', c.surface),
        ('surfaceVariant', c.surfaceVariant),
      ]) {
        for (final (name, ink) in [
          ('textPrimary', c.textPrimary),
          ('textSecondary', c.textSecondary),
          ('textTertiary', c.textTertiary),
          ('accentText', c.accentText),
          ('error', c.error),
          ('warning', c.warning),
          ('success', c.success),
        ]) {
          final r = ThemeContrast.ratio(ink, bg);
          if (r + 1e-9 < 4.5) {
            fails.add('${p.id} $name/$sName ${r.toStringAsFixed(2)}');
          }
        }
      }
      // The accent itself is a control colour: 3:1 on the page.
      if (ThemeContrast.ratio(c.accent, c.background) < 3.0) {
        fails.add('${p.id} accent/background');
      }
      if (ThemeContrast.ratio(c.onAccent, c.accent) < 4.5) {
        fails.add('${p.id} onAccent/accent');
      }
    }
    expect(fails, isEmpty, reason: fails.join('\n'));
  });

  test('both presets build a ThemeData in the right brightness', () {
    expect(AppTheme.fromId('indigo-glass').brightness, Brightness.dark);
    expect(AppTheme.fromId('indigo-glass-light').brightness, Brightness.light);
  });
}
