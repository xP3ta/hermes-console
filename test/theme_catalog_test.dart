import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

import 'support/theme_profile_fixtures.dart';

void main() {
  group('catálogo de temas', () {
    test('el default es Console y va primero', () {
      expect(AppTheme.defaultThemeId, 'console');
      expect(AppTheme.presets.first.id, 'console');
    });

    test('todos los ids son únicos y no vacíos', () {
      final ids = AppTheme.presets.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids.every((id) => id.isNotEmpty), isTrue);
    });

    test('el catálogo Desktop sigue el orden de BUILTIN_THEMES', () {
      // The full list, families and modes live in theme_family_catalog_test.
      expect(
        AppTheme.presets
            .where((preset) => preset.desktopOfficial)
            .map((preset) => preset.id),
        orderedEquals([
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
        ]),
      );
    });

    test('mapea claves antiguas de AppThemeMode a los nuevos ids', () {
      expect(AppTheme.themeIdFromLegacy('dark'), 'amber');
      expect(AppTheme.themeIdFromLegacy('oled'), 'amber');
      expect(AppTheme.themeIdFromLegacy('teal'), 'dracula');
      expect(AppTheme.themeIdFromLegacy('light'), 'amber-light');
    });

    test('respeta ids nuevos válidos y cae al default con basura/null', () {
      expect(AppTheme.themeIdFromLegacy('steel-light'), 'steel-light');
      expect(AppTheme.themeIdFromLegacy('ember'), 'ember');
      expect(AppTheme.themeIdFromLegacy('no-existe'), 'console');
      expect(AppTheme.themeIdFromLegacy(null), 'console');
    });

    test('presetById devuelve el preset o el primero como fallback', () {
      expect(AppTheme.presetById('mono').name, 'Mono');
      expect(AppTheme.presetById('nope').id, 'console');
    });

    test('fromId construye un ThemeData con la extensión Hermes', () {
      final theme = AppTheme.fromId('catppuccin-dark');
      final colors = theme.hermes;
      expect(colors.accent, const Color(0xFFD4B8F7));
      // El tema claro usa brightness light.
      expect(AppTheme.fromId('claude-light').brightness, Brightness.light);
      expect(AppTheme.fromId('amber-light').brightness, Brightness.light);
      expect(AppTheme.fromId('amber').brightness, Brightness.dark);
    });

    test('las familias Desktop conservan el tono de sus acentos', () {
      // Softened to the Claude bands (theme_claude_bands_test), but each
      // accent keeps the hue Desktop ships.
      const desktop = {
        'nous': Color(0xFF0053FD),
        'midnight': Color(0xFF8B80E8),
        'ember': Color(0xFFD97316),
        'cyberpunk': Color(0xFF00FF41),
        'slate': Color(0xFF58A6FF),
      };
      desktop.forEach((id, source) {
        final accent = AppTheme.presetById(id).colors.accent;
        final a = HSVColor.fromColor(accent).hue;
        final b = HSVColor.fromColor(source).hue;
        final delta = ((a - b + 540) % 360) - 180;
        expect(delta.abs(), lessThan(18), reason: id);
        expect(accent, isNot(source), reason: '$id is softened');
      });
    });

    test('cada tema expone su color de contraste (no es el acento)', () {
      // El color de contraste rompe el monocromo: llega a la extensión Hermes
      // y al colorScheme, y difiere del acento principal del tema.
      final steel = AppTheme.fromId('steel');
      expect(steel.hermes.secondary, const Color(0xFFD1AB7A));
      expect(steel.colorScheme.secondary, const Color(0xFFD1AB7A));
      expect(steel.hermes.secondary, isNot(steel.hermes.accent));

      // Temas distintos tienen contrastes distintos (identidad propia).
      final bordeaux = AppTheme.fromId('bordeaux');
      expect(bordeaux.hermes.secondary, const Color(0xFF90BCA4));
      expect(bordeaux.hermes.secondary, isNot(steel.hermes.secondary));
    });

    test('los títulos llevan el peso/tracking del tema', () {
      // Amber usa títulos gruesos; Bordeaux (elegante) tracking amplio, en
      // sus dos modos.
      for (final id in ['amber', 'amber-light']) {
        expect(
          AppTheme.fromId(id).textTheme.titleLarge?.fontWeight,
          FontWeight.w700,
        );
      }
      for (final id in ['bordeaux', 'bordeaux-light']) {
        expect(AppTheme.fromId(id).textTheme.titleLarge?.letterSpacing, 1.2);
      }
    });

    test('titleMedium conserva la jerarquía global del tema', () {
      final profile = validCustomTheme().copyWith(
        typography: validCustomTheme().typography.copyWith(
          titleWeight: 800,
          titleSpacing: 3,
        ),
      );
      final theme = AppTheme.fromProfile(profile);

      expect(theme.textTheme.titleLarge?.fontWeight, FontWeight.w800);
      expect(theme.textTheme.titleLarge?.letterSpacing, 3);
      // Los dropdowns del Theme Studio fijan su estilo compacto localmente
      // (cubierto por theme_studio_screen_test). No encogemos titleMedium de
      // toda la app porque también lo consumen bloques de contenido/Markdown.
      expect(theme.textTheme.titleMedium?.letterSpacing, 3);
      expect(theme.textTheme.titleMedium?.fontWeight, FontWeight.w800);
    });
  });
}
