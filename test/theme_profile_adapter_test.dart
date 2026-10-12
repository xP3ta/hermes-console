import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_profile.dart';
import 'package:hermes_android/core/theme/theme_profile_adapter.dart';
import 'package:hermes_android/core/theme/theme_profile_codec.dart';

void main() {
  group('ThemeProfileAdapter built-in equivalence', () {
    test('projects every immutable preset in catalog order', () {
      final profiles = ThemeProfileAdapter.builtinProfiles;
      expect(profiles.length, AppTheme.presets.length);
      expect(
        profiles.map((profile) => profile.id),
        orderedEquals(AppTheme.presets.map((preset) => preset.id)),
      );
      expect(profiles.every((profile) => profile.isBuiltin), isTrue);
      expect(profiles.every((profile) => !profile.isEditable), isTrue);
      expect(
        profiles.every((profile) => profile.componentProfileId == 'minimal'),
        isTrue,
      );
    });

    for (final preset in AppTheme.presets) {
      test('${preset.id} preserves palette, typography and brightness', () {
        final profile = ThemeProfileAdapter.fromPreset(preset);
        final projected = ThemeProfileAdapter.colorsFromProfile(profile);

        expect(profile.id, preset.id);
        expect(profile.basePresetId, preset.id);
        expect(profile.name, preset.name);
        expect(profile.metadata.description, preset.tagline);
        expect(profile.typography.fontFamily, preset.fontFamily);
        expect(profile.typography.titleWeight, preset.titleWeight.value);
        expect(profile.typography.titleSpacing, preset.titleSpacing);
        expect(profile.typography.uppercaseTitles, preset.uppercaseTitles);
        expect(projected.background, preset.colors.background);
        expect(projected.surface, preset.colors.surface);
        expect(projected.surfaceVariant, preset.colors.surfaceVariant);
        expect(projected.accent, preset.colors.accent);
        expect(projected.accentHover, preset.colors.accentHover);
        expect(projected.accentText, preset.colors.accentText);
        expect(
          projected.secondary,
          preset.secondary ?? preset.colors.accentHover,
        );
        expect(projected.onAccent, preset.colors.onAccent);
        expect(projected.textPrimary, preset.colors.textPrimary);
        expect(projected.textSecondary, preset.colors.textSecondary);
        expect(projected.textDisabled, preset.colors.textDisabled);
        expect(projected.error, preset.colors.error);
        expect(projected.success, preset.colors.success);
        expect(projected.warning, preset.colors.warning);
        expect(projected.divider, preset.colors.divider);
        expect(projected.uppercaseTitles, preset.uppercaseTitles);
        expect(
          profile.brightness,
          preset.isDark
              ? ThemeProfileBrightness.dark
              : ThemeProfileBrightness.light,
        );
      });

      test('${preset.id} survives the canonical codec without token drift', () {
        final profile = ThemeProfileAdapter.fromPreset(preset);
        final encoded = ThemeProfileCodec.encode(profile, allowBuiltin: true);
        final decoded = ThemeProfileCodec.decode(
          encoded,
          mode: ThemeProfileDecodeMode.builtin,
        );
        expect(decoded.profile, profile);
      });
    }

    test(
      'duplicate produces an editable copy and leaves the preset untouched',
      () {
        final preset = AppTheme.presets.first;
        final duplicate = ThemeProfileAdapter.duplicatePreset(
          preset,
          id: 'copy-id',
          name: 'Amber copy',
        );
        expect(duplicate.source, ThemeProfileSource.custom);
        expect(duplicate.isEditable, isTrue);
        expect(duplicate.palette.accent, preset.colors.accent);
        expect(preset.id, 'console');
        expect(preset.name, 'Console');
      },
    );

    test(
      'delegates every legacy id to the existing migration source of truth',
      () {
        for (final legacy in [
          null,
          'dark',
          'oled',
          'teal',
          'light',
          'tokyo',
          'does-not-exist',
        ]) {
          expect(
            ThemeProfileAdapter.resolveLegacyBuiltinId(legacy),
            AppTheme.themeIdFromLegacy(legacy),
          );
        }
      },
    );
  });
}
