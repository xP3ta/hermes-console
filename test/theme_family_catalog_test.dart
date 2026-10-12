// 1.2.15 theme cleanup: fewer, better themes. Every family ships a light and
// a dark variant, the Console-only duplicates of Desktop families are gone,
// and anyone who had a removed theme saved lands on its closest survivor.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

const _finalIds = [
  'console',
  'console-light',
  'amber',
  'amber-light',
  'claude',
  'claude-light',
  'steel',
  'steel-light',
  'bordeaux',
  'bordeaux-light',
  'dracula',
  'dracula-light',
  'gruvbox',
  'gruvbox-light',
  'sage-garden',
  'sage-garden-light',
  'nous',
  'nous-dark',
  'github',
  'github-dark',
  'catppuccin',
  'catppuccin-dark',
  'everforest',
  'everforest-dark',
  'solarized',
  'solarized-dark',
  'nous-alt',
  'nous-alt-dark',
  'classic',
  'classic-dark',
  'midnight-light',
  'midnight',
  'ember-light',
  'ember',
  'mono-light',
  'mono',
  'slate-light',
  'slate',
  'cyberpunk-light',
  'cyberpunk',
];

const _removed = [
  'amber-oled',
  'crimson',
  'hermes-console',
  'mocha',
  'phosphor',
  'graphite',
];

/// Stored id -> (new id, brightness of the destination).
const _migration = <String, (String, Brightness)>{
  // Removed in 1.2.15.
  'amber-oled': ('amber', Brightness.dark),
  'crimson': ('bordeaux', Brightness.dark),
  'hermes-console': ('slate', Brightness.dark),
  'mocha': ('catppuccin-dark', Brightness.dark),
  'phosphor': ('cyberpunk', Brightness.dark),
  'graphite': ('mono', Brightness.dark),
  // Pre-catalogue AppThemeMode keys.
  'oled': ('amber', Brightness.dark),
  'light': ('amber-light', Brightness.light),
  'dark': ('amber', Brightness.dark),
  'teal': ('dracula', Brightness.dark),
  // Retired in U-10.
  'nous-aqua': ('slate', Brightness.dark),
  'cobalt2': ('slate', Brightness.dark),
  'tokyo': ('steel', Brightness.dark),
  'onedark': ('steel', Brightness.dark),
  'aguamarina': ('steel', Brightness.dark),
  'synthwave': ('dracula', Brightness.dark),
  'ayu-mirage': ('amber', Brightness.dark),
  'latte': ('catppuccin', Brightness.light),
  'solarized-light': ('solarized', Brightness.light),
  'manga': ('claude-light', Brightness.light),
};

HermesThemePreset _preset(String id) =>
    AppTheme.presets.firstWhere((p) => p.id == id);

void main() {
  group('final theme list', () {
    test('matches the approved proposal, default first', () {
      expect(AppTheme.presets.map((p) => p.id).toList(), _finalIds);
      expect(AppTheme.presets.first.id, AppTheme.defaultThemeId);
    });

    test('no removed theme is still offered', () {
      final ids = AppTheme.presets.map((p) => p.id).toSet();
      for (final id in _removed) {
        expect(ids, isNot(contains(id)), reason: id);
      }
    });

    test('20 families, each with exactly one light and one dark variant', () {
      final families = <String, List<HermesThemePreset>>{};
      for (final preset in AppTheme.presets) {
        families.putIfAbsent(preset.familyId, () => []).add(preset);
      }
      expect(families.keys.toList(), [
        'console',
        'amber',
        'claude',
        'steel',
        'bordeaux',
        'dracula',
        'gruvbox',
        'sage-garden',
        'nous',
        'github',
        'catppuccin',
        'everforest',
        'solarized',
        'nous-alt',
        'classic',
        'midnight',
        'ember',
        'mono',
        'slate',
        'cyberpunk',
      ]);
      expect(AppTheme.familyCount, 20);
      families.forEach((family, variants) {
        expect(variants, hasLength(2), reason: family);
        expect(variants.map((p) => p.brightness).toSet(), {
          Brightness.light,
          Brightness.dark,
        }, reason: family);
        // One card per family: both variants carry the family name.
        expect(variants.map((p) => p.name).toSet(), hasLength(1));
      });
    });

    test('Claude is one family: claude + claude-light', () {
      expect(_preset('claude').familyId, 'claude');
      expect(_preset('claude-light').familyId, 'claude');
      expect(_preset('claude-light').name, 'Claude');
      expect(_preset('claude-light').brightness, Brightness.light);
    });
  });

  group('Console: Claude\'s feel in the icon\'s graphite and terracotta', () {
    // Exact values live in theme_soft_palettes_test; this pins the intent.
    test('Console is the default family and comes first', () {
      expect(AppTheme.defaultThemeId, 'console');
      expect(_preset('console').name, 'Console');
      expect(_preset('console-light').name, 'Console');
      expect(_preset('console').brightness, Brightness.dark);
      expect(_preset('console-light').brightness, Brightness.light);
      expect(_preset('console').familyId, 'console');
      expect(_preset('console-light').familyId, 'console');
    });

    test('dark page is the icon graphite, hover the icon terracotta', () {
      final c = _preset('console').colors;
      expect(c.background, const Color(0xFF26262A));
      expect(c.accentHover, const Color(0xFFD97757));
    });

    test('same lightness structure as Claude, cooler neutrals', () {
      for (final (console, claude) in [
        ('console', 'claude'),
        ('console-light', 'claude-light'),
      ]) {
        final a = _preset(console).colors;
        final b = _preset(claude).colors;
        for (final (x, y) in [
          (a.background, b.background),
          (a.surface, b.surface),
          (a.surfaceVariant, b.surfaceVariant),
        ]) {
          // Claude's pages lean warm (red > blue); Console's graphite leans
          // cool (blue >= red) at the same brightness.
          expect(
            (x.computeLuminance() - y.computeLuminance()).abs(),
            lessThan(0.012),
            reason: '$console vs $claude',
          );
          expect(x.b, greaterThanOrEqualTo(x.r), reason: console);
        }
        // Same calm accent family as Claude (terracotta / clay).
        expect(
          (a.accent.computeLuminance() - b.accent.computeLuminance()).abs(),
          lessThan(0.02),
        );
      }
    });
  });

  group('migration of saved theme ids', () {
    _migration.forEach((stored, target) {
      test('$stored -> ${target.$1}', () {
        final (id, brightness) = target;
        expect(AppTheme.themeIdFromLegacy(stored), id);
        expect(AppTheme.migrateStoredThemeId(stored), id);
        expect(_preset(id).brightness, brightness);
      });
    });

    test('every removed id has a migration entry', () {
      for (final id in _removed) {
        expect(_migration.containsKey(id), isTrue, reason: id);
        expect(AppTheme.presets.any((p) => p.id == id), isFalse);
      }
    });

    test('the new gruvbox-light keeps its own id', () {
      expect(AppTheme.themeIdFromLegacy('gruvbox-light'), 'gruvbox-light');
      expect(AppTheme.migrateStoredThemeId('gruvbox-light'), 'gruvbox-light');
    });

    test('valid ids are kept; unknown or null fall back to the default', () {
      for (final id in _finalIds) {
        expect(AppTheme.themeIdFromLegacy(id), id);
        expect(AppTheme.migrateStoredThemeId(id), id);
      }
      expect(AppTheme.themeIdFromLegacy('no-such-theme'), 'console');
      expect(AppTheme.themeIdFromLegacy(''), 'console');
      expect(AppTheme.themeIdFromLegacy(null), 'console');
      expect(AppTheme.presetById('no-such-theme').id, 'console');
      expect(() => AppTheme.fromId('no-such-theme'), returnsNormally);
    });

    test('custom profile ids are not touched by the stored-id migration', () {
      const custom = 'b3be2e40-9fe6-4fc1-9fb5-9eb18844df76';
      expect(AppTheme.migrateStoredThemeId(custom), custom);
    });
  });
}
