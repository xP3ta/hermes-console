// Hermes Desktop parity for the "Hermes Desktop" themes section.
//
// Source of truth: apps/desktop/src/themes/presets.ts (BUILTIN_THEMES order)
// and apps/shared/src/theme-presets.ts (THEME_PRESET_PALETTES). Console maps
// Desktop tokens as background→background, card→surface, muted→surfaceVariant,
// foreground→textPrimary, mutedForeground→textSecondary, ring→accent,
// border→divider, destructive→error.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_profile_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `BUILTIN_THEMES` key order in Desktop's presets.ts.
const desktopFamilies = [
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
];

/// Desktop skins that ship both palettes: Console id is the family for the
/// light palette and `<family>-dark` for `darkColors`.
const newDesktopIds = [
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
];

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

List<HermesThemePreset> get _desktopPresets => AppTheme.presets
    .where((preset) => preset.desktopOfficial)
    .toList(growable: false);

void main() {
  group('Hermes Desktop theme catalogue', () {
    test('lists every Desktop family once, in Desktop order', () {
      final families = <String>[];
      for (final preset in _desktopPresets) {
        final family = preset.desktopFamily!;
        if (!families.contains(family)) families.add(family);
      }
      expect(families, desktopFamilies);
      expect(families.length, 12);
    });

    test('each Desktop family offers exactly one light and one dark mode', () {
      for (final family in desktopFamilies) {
        final variants = _desktopPresets
            .where((preset) => preset.desktopFamily == family)
            .toList();
        expect(variants, hasLength(2), reason: family);
        expect(variants.map((preset) => preset.brightness).toSet(), {
          Brightness.light,
          Brightness.dark,
        }, reason: family);
        expect(
          variants.map((preset) => preset.name).toSet(),
          hasLength(1),
          reason: '$family variants share one card title',
        );
      }
    });

    test('new Desktop ids exist and are flagged as Desktop presets', () {
      final ids = AppTheme.presets.map((preset) => preset.id).toSet();
      for (final id in newDesktopIds) {
        expect(ids, contains(id));
        expect(AppTheme.presetById(id).desktopOfficial, isTrue, reason: id);
      }
    });

    test('card titles use the Desktop labels', () {
      String title(String family) => _desktopPresets
          .firstWhere((preset) => preset.desktopFamily == family)
          .name;
      expect(title('nous'), 'Nous');
      expect(title('github'), 'GitHub');
      expect(title('catppuccin'), 'Catppuccin');
      expect(title('everforest'), 'Everforest');
      expect(title('solarized'), 'Solarized');
      expect(title('nous-alt'), 'Nous Alt');
      expect(title('classic'), 'Classic Hermes');
    });
  });

  // Owner priority over byte parity (1.2.15): Desktop families keep their
  // names, modes and hues but are softened to the Claude bands
  // (theme_claude_bands_test). Deviations are documented per family in the
  // design README. These are the accents Desktop ships, before softening.
  const desktopAccents = <String, Color>{
    'nous': Color(0xFF0053FD),
    'nous-dark': Color(0xFF4A84FE),
    'github': Color(0xFF196D31),
    'github-dark': Color(0xFF4F9E5E),
    'catppuccin': Color(0xFF6D2EBF),
    'catppuccin-dark': Color(0xFFCBA6F7),
    'everforest': Color(0xFF586B35),
    'everforest-dark': Color(0xFFA7C080),
    'solarized': Color(0xFF675E34),
    'solarized-dark': Color(0xFF6EA1C4),
    'nous-alt': Color(0xFF0053FD),
    'nous-alt-dark': Color(0xFFFFE6CB),
    'classic': Color(0xFF825D02),
    'classic-dark': Color(0xFFFFBF00),
    'midnight-light': Color(0xFF6F66BA),
    'midnight': Color(0xFF8B80E8),
    'ember-light': Color(0xFFAE5C12),
    'ember': Color(0xFFD97316),
    'mono-light': Color(0xFF737373),
    'mono': Color(0xFF9A9A9A),
    'slate-light': Color(0xFF3E74B3),
    'slate': Color(0xFF58A6FF),
    'cyberpunk-light': Color(0xFF008021),
    'cyberpunk': Color(0xFF00FF41),
  };

  group('Desktop families keep their identity, softened', () {
    test('every Desktop preset keeps the hue of its Desktop accent', () {
      for (final entry in desktopAccents.entries) {
        final preset = AppTheme.presetById(entry.key);
        expect(preset.id, entry.key);
        final source = HSVColor.fromColor(entry.value);
        if (source.saturation < 0.08) continue; // neutral (Mono)
        final hue = HSVColor.fromColor(preset.colors.accent).hue;
        final delta = ((hue - source.hue + 540) % 360) - 180;
        expect(delta.abs(), lessThan(18), reason: entry.key);
      }
    });

    test('no Desktop accent stays at its neon/saturated source', () {
      for (final id in ['nous', 'nous-alt', 'cyberpunk', 'classic-dark']) {
        final accent = AppTheme.presetById(id).colors.accent;
        expect(accent, isNot(desktopAccents[id]), reason: id);
        expect(
          HSVColor.fromColor(accent).saturation,
          lessThan(HSVColor.fromColor(desktopAccents[id]!).saturation),
          reason: id,
        );
      }
    });

    test('applying a Desktop theme builds its ThemeData', () {
      final theme = AppTheme.fromId('catppuccin-dark');
      expect(theme.brightness, Brightness.dark);
      expect(theme.hermes.background, const Color(0xFF1F1F29));
      expect(theme.hermes.accent, const Color(0xFFD4B8F7));
      expect(theme.scaffoldBackgroundColor, const Color(0xFF1F1F29));
      final light = AppTheme.fromId('github');
      expect(light.brightness, Brightness.light);
      expect(light.hermes.accent, const Color(0xFF2E6A3B));
    });
  });

  group('Desktop theme readability', () {
    test('text on every Desktop surface reaches 4.5:1', () {
      final fails = <String>[];
      for (final preset in _desktopPresets) {
        final c = preset.colors;
        final checks = {
          'textPrimary/background': _contrast(c.textPrimary, c.background),
          'textPrimary/surface': _contrast(c.textPrimary, c.surface),
          'textPrimary/surfaceVariant': _contrast(
            c.textPrimary,
            c.surfaceVariant,
          ),
          'accentText/background': _contrast(c.accentText, c.background),
          'onAccent/accent': _contrast(c.onAccent, c.accent),
        };
        checks.forEach((pair, ratio) {
          if (ratio < 4.5) {
            fails.add('${preset.id} $pair ${ratio.toStringAsFixed(2)}');
          }
        });
      }
      expect(fails, isEmpty);
    });
  });

  group('Desktop status colours stay apart from titles', () {
    test('error/success/warning read AA and never match the body text', () {
      final mapped = desktopAccents.keys;
      final fails = <String>[];
      for (final preset in mapped.map(AppTheme.presetById)) {
        final c = preset.colors;
        for (final entry in {
          'error': c.error,
          'success': c.success,
          'warning': c.warning,
        }.entries) {
          if (_contrast(entry.value, c.textPrimary) < 1.3 &&
              _contrast(entry.value, c.background) >= 4.5) {
            fails.add('${preset.id} ${entry.key}');
          }
        }
      }
      expect(fails, isEmpty);
    });
  });

  group('Desktop theme selection persists', () {
    test('every new Desktop id survives a store restart', () async {
      for (final id in newDesktopIds) {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        await ThemeProfileStore(prefs).activate(id);

        final restarted = await ThemeProfileStore(prefs).load();
        expect(restarted.activeProfileId, id, reason: id);
        expect(AppTheme.themeIdFromLegacy(prefs.getString('theme_mode')), id);
      }
    });

    test('Desktop ids that reuse retired Console names are honoured', () {
      // Console once shipped its own `everforest` and `solarized-dark` and
      // migrated them away; they are Desktop themes again and must load.
      expect(AppTheme.themeIdFromLegacy('everforest'), 'everforest');
      expect(AppTheme.themeIdFromLegacy('solarized-dark'), 'solarized-dark');
    });
  });
}
