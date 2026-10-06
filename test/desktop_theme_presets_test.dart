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

  group('Desktop palette tokens survive the mapping', () {
    void expectTokens(
      String id, {
      required Brightness brightness,
      required int background,
      required int surface,
      required int surfaceVariant,
      required int textPrimary,
      required int accent,
      int? error,
    }) {
      final preset = AppTheme.presetById(id);
      expect(preset.id, id);
      expect(preset.brightness, brightness, reason: id);
      final c = preset.colors;
      expect(c.background, Color(background), reason: '$id background');
      expect(c.surface, Color(surface), reason: '$id surface (card)');
      expect(
        c.surfaceVariant,
        Color(surfaceVariant),
        reason: '$id surfaceVariant (muted)',
      );
      expect(c.textPrimary, Color(textPrimary), reason: '$id foreground');
      expect(c.accent, Color(accent), reason: '$id accent (ring)');
      if (error != null) {
        expect(c.error, Color(error), reason: '$id error (destructive)');
      }
    }

    test('Nous is GitHub chrome carrying Nous blue', () {
      expectTokens(
        'nous',
        brightness: Brightness.light,
        background: 0xFFFFFFFF,
        surface: 0xFFF6F8FA,
        surfaceVariant: 0xFFF6F6F6,
        textPrimary: 0xFF1F2328,
        accent: 0xFF0053FD,
        error: 0xFFCF222E,
      );
      expectTokens(
        'nous-dark',
        brightness: Brightness.dark,
        background: 0xFF0D1117,
        surface: 0xFF010409,
        surfaceVariant: 0xFF1A1E24,
        textPrimary: 0xFFE6EDF3,
        accent: 0xFF4A84FE,
        error: 0xFFF85149,
      );
    });

    test('GitHub keeps the upstream green accent', () {
      expectTokens(
        'github',
        brightness: Brightness.light,
        background: 0xFFFFFFFF,
        surface: 0xFFF6F8FA,
        surfaceVariant: 0xFFF6F6F6,
        textPrimary: 0xFF1F2328,
        accent: 0xFF196D31,
        error: 0xFFCF222E,
      );
      expectTokens(
        'github-dark',
        brightness: Brightness.dark,
        background: 0xFF0D1117,
        surface: 0xFF010409,
        surfaceVariant: 0xFF1A1E24,
        textPrimary: 0xFFE6EDF3,
        accent: 0xFF4F9E5E,
        error: 0xFFF85149,
      );
    });

    test('Catppuccin is Latte in light and Mocha in dark', () {
      expectTokens(
        'catppuccin',
        brightness: Brightness.light,
        background: 0xFFEFF1F5,
        surface: 0xFFE6E9EF,
        surfaceVariant: 0xFFE8EBEF,
        textPrimary: 0xFF4C4F69,
        accent: 0xFF6D2EBF,
        error: 0xFFD20F39,
      );
      expectTokens(
        'catppuccin-dark',
        brightness: Brightness.dark,
        background: 0xFF1E1E2E,
        surface: 0xFF181825,
        surfaceVariant: 0xFF29293A,
        textPrimary: 0xFFCDD6F4,
        accent: 0xFFCBA6F7,
        error: 0xFFF38BA8,
      );
    });

    test('Everforest keeps its forest greens', () {
      expectTokens(
        'everforest',
        brightness: Brightness.light,
        background: 0xFFFDF6E3,
        surface: 0xFFFDF6E3,
        surfaceVariant: 0xFFF7F0DE,
        textPrimary: 0xFF5C6A72,
        accent: 0xFF586B35,
        // Desktop's #F1706F lifted to AA sits on Everforest's 5.2:1 body
        // text, so Console deepens it; see the separation test below.
      );
      expectTokens(
        'everforest-dark',
        brightness: Brightness.dark,
        background: 0xFF2D353B,
        surface: 0xFF2D353B,
        surfaceVariant: 0xFF373E42,
        textPrimary: 0xFFD3C6AA,
        accent: 0xFFA7C080,
        error: 0xFFDA6362,
      );
    });

    test('Solarized keeps its fixed-contrast backgrounds', () {
      expectTokens(
        'solarized',
        brightness: Brightness.light,
        background: 0xFFFDF6E3,
        surface: 0xFFD3CBB7,
        surfaceVariant: 0xFFF4EDDB,
        textPrimary: 0xFF1F1F1F,
        accent: 0xFF675E34,
        error: 0xFFE25563,
      );
      final dark = AppTheme.presetById('solarized-dark');
      expect(dark.brightness, Brightness.dark);
      expect(dark.colors.background, const Color(0xFF002B36));
      expect(dark.colors.surface, const Color(0xFF002B36));
      expect(dark.colors.surfaceVariant, const Color(0xFF08313C));
      expect(dark.colors.accent, const Color(0xFF6EA1C4));
    });

    test('Nous Alt keeps the hand-authored Nous palette', () {
      expectTokens(
        'nous-alt',
        brightness: Brightness.light,
        background: 0xFFF8FAFF,
        surface: 0xFFFFFFFF,
        surfaceVariant: 0xFFF2F6FF,
        textPrimary: 0xFF17171A,
        accent: 0xFF0053FD,
        error: 0xFFC72E4D,
      );
      expectTokens(
        'nous-alt-dark',
        brightness: Brightness.dark,
        background: 0xFF0D2F86,
        surface: 0xFF12378F,
        surfaceVariant: 0xFF183F9A,
        textPrimary: 0xFFFFE6CB,
        accent: 0xFFFFE6CB,
        error: 0xFFC0473A,
      );
    });

    test('Classic Hermes is gold on navy, converted like a CLI skin', () {
      expectTokens(
        'classic',
        brightness: Brightness.light,
        background: 0xFFF5F5F5,
        surface: 0xFFF0F0EF,
        surfaceVariant: 0xFFEDEDEC,
        textPrimary: 0xFF2B2109,
        accent: 0xFF825D02,
        error: 0xFFC62828,
      );
      expectTokens(
        'classic-dark',
        brightness: Brightness.dark,
        background: 0xFF1A1A2E,
        surface: 0xFF232335,
        surfaceVariant: 0xFF282738,
        textPrimary: 0xFFFFF8DC,
        accent: 0xFFFFBF00,
        error: 0xFFEF5350,
      );
    });

    test('applying a new Desktop theme builds its ThemeData', () {
      final theme = AppTheme.fromId('catppuccin-dark');
      expect(theme.brightness, Brightness.dark);
      expect(theme.hermes.background, const Color(0xFF1E1E2E));
      expect(theme.hermes.accent, const Color(0xFFCBA6F7));
      expect(theme.scaffoldBackgroundColor, const Color(0xFF1E1E2E));
      final light = AppTheme.fromId('github');
      expect(light.brightness, Brightness.light);
      expect(light.hermes.accent, const Color(0xFF196D31));
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
      // Palettes mapped through the Desktop-palette helper (the six earlier
      // dark-only skins keep their hand-tuned Console status colours).
      final mapped = [
        'nous',
        'nous-dark',
        ...newDesktopIds.where((id) => !id.startsWith('nous-alt')),
      ];
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
      expect(
        _contrast(
          AppTheme.presetById('everforest').colors.error,
          const Color(0xFF5C6A72),
        ),
        greaterThanOrEqualTo(1.3),
      );
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
