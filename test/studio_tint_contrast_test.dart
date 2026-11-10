import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/bot_character.dart';
import 'package:hermes_android/core/characters/studio_catalog.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/screens/characters/studio_canvas.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';

/// The editor tints its page (a tenth) and its canvas (a fifth and a bit)
/// toward the body colour being chosen. Whatever colour that is, the text
/// over the tint must read as well as over the plain theme, up to AA.
void main() {
  final themes = {
    'dark': AppTheme.hermesRedDark,
    'light': AppTheme.hermesRedLight,
  };

  final characters = <String, BotCharacter>{
    for (final hex in ClassicFaceIdentity.colors)
      'solid $hex': BotCharacter.fresh.copyWith(bodyColor: hex),
    for (final gradient in botGradients)
      'gradient ${gradient.id}': BotCharacter.fresh.copyWith(
        gradient: gradient.id,
      ),
    for (final hex in const [
      '#000000',
      '#ffffff',
      '#ffff00',
      '#00ff00',
      '#ff00ff',
      '#0000ff',
    ])
      'custom $hex': BotCharacter.fresh.copyWith(bodyColor: hex),
  };

  for (final theme in themes.entries) {
    test('${theme.key}: tinted page and canvas keep the text readable', () {
      final c = theme.value.extension<HermesThemeColors>()!;
      final surfaces = {'page': c.background, 'canvas': c.surface};
      final inks = {'secondary': c.textSecondary, 'primary': c.textPrimary};
      for (final amount in const [0.1, 0.22]) {
        for (final character in characters.entries) {
          for (final surface in surfaces.entries) {
            final tinted = studioTint(
              surface.value,
              character.value,
              'ana',
              amount,
              ink: c.textSecondary,
            );
            for (final ink in inks.entries) {
              final floor = ThemeContrast.ratio(ink.value, surface.value);
              final wanted = floor < 4.5 ? floor : 4.5;
              expect(
                ThemeContrast.ratio(ink.value, tinted),
                greaterThanOrEqualTo(wanted - 1e-6),
                reason:
                    '${theme.key} ${surface.key} ${ink.key} on '
                    '${character.key} at $amount',
              );
            }
          }
        }
      }
    });
  }

  test('the tint is used when it is harmless and dropped when it is not', () {
    final c = AppTheme.hermesRedLight.extension<HermesThemeColors>()!;
    final pale = BotCharacter.fresh.copyWith(bodyColor: '#f87171');
    final black = BotCharacter.fresh.copyWith(bodyColor: '#000000');
    expect(
      studioTint(c.surface, pale, 'ana', 0.22, ink: c.textPrimary),
      isNot(c.surface),
    );
    expect(
      studioTint(c.surface, black, 'ana', 0.22, ink: c.textSecondary),
      isNot(const Color(0x00000000)),
    );
    // Never lowers the contrast below the plain theme or AA.
    final tinted = studioTint(
      c.surface,
      black,
      'ana',
      0.22,
      ink: c.textSecondary,
    );
    expect(
      ThemeContrast.ratio(c.textSecondary, tinted),
      greaterThanOrEqualTo(
        ThemeContrast.ratio(c.textSecondary, c.surface) < 4.5
            ? ThemeContrast.ratio(c.textSecondary, c.surface) - 1e-6
            : 4.5,
      ),
    );
  });
}
