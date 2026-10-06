import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

import 'support/theme_profile_fixtures.dart';

void main() {
  group('catálogo de temas', () {
    test('el default es Amber y va primero', () {
      expect(AppTheme.defaultThemeId, 'amber');
      expect(AppTheme.presets.first.id, 'amber');
    });

    test('todos los ids son únicos y no vacíos', () {
      final ids = AppTheme.presets.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids.every((id) => id.isNotEmpty), isTrue);
    });

    test(
      'el catálogo incluye la selección móvil y Hermes Desktop completo',
      () {
        expect(AppTheme.presets.map((p) => p.id).toList(), [
          'amber',
          'claude',
          'amber-oled',
          'crimson',
          'steel',
          'bordeaux',
          'hermes-console',
          'mocha',
          'dracula',
          'phosphor',
          'gruvbox',
          'graphite',
          'sage-garden',
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
          'claude-light',
        ]);
        final claros = AppTheme.presets
            .where((p) => p.brightness == Brightness.light)
            .toList();
        expect(claros.map((p) => p.id).toList(), [
          'nous',
          'github',
          'catppuccin',
          'everforest',
          'solarized',
          'nous-alt',
          'classic',
          'midnight-light',
          'ember-light',
          'mono-light',
          'slate-light',
          'cyberpunk-light',
          'claude-light',
        ]);
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
        expect(
          AppTheme.presets
              .where((preset) => preset.desktopOfficial)
              .map((preset) => preset.desktopFamily)
              .toSet(),
          {
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
          },
        );
      },
    );

    test('mapea claves antiguas de AppThemeMode a los nuevos ids', () {
      expect(AppTheme.themeIdFromLegacy('dark'), 'amber');
      expect(AppTheme.themeIdFromLegacy('oled'), 'amber-oled');
      expect(AppTheme.themeIdFromLegacy('teal'), 'dracula');
      expect(AppTheme.themeIdFromLegacy('light'), 'claude-light');
    });

    test('migra los ids retirados (U-10) a un superviviente, sin crash', () {
      // Todo id retirado del catálogo debe caer a un preset existente: un
      // usuario con ese tema guardado arranca con el más parecido.
      const retirados = {
        'nous-aqua': 'hermes-console',
        'tokyo': 'steel',
        'onedark': 'steel',
        'cobalt2': 'hermes-console',
        'aguamarina': 'steel',
        'synthwave': 'dracula',
        'ayu-mirage': 'amber',
        'latte': 'claude-light',
        'solarized-light': 'claude-light',
        'gruvbox-light': 'claude-light',
        'manga': 'claude-light',
      };
      retirados.forEach((retirado, destino) {
        final id = AppTheme.themeIdFromLegacy(retirado);
        expect(id, destino, reason: retirado);
        expect(
          AppTheme.presets.any((p) => p.id == id),
          isTrue,
          reason: 'el destino de $retirado debe existir en el catálogo',
        );
      });
    });

    test('respeta ids nuevos válidos y cae al default con basura/null', () {
      expect(AppTheme.themeIdFromLegacy('mocha'), 'mocha');
      expect(AppTheme.themeIdFromLegacy('ember'), 'ember');
      expect(AppTheme.themeIdFromLegacy('no-existe'), 'amber');
      expect(AppTheme.themeIdFromLegacy(null), 'amber');
    });

    test('presetById devuelve el preset o el primero como fallback', () {
      expect(AppTheme.presetById('graphite').name, 'Graphite');
      expect(AppTheme.presetById('nope').id, 'amber');
    });

    test('fromId construye un ThemeData con la extensión Hermes', () {
      final theme = AppTheme.fromId('mocha');
      final colors = theme.hermes;
      expect(colors.accent, const Color(0xFFCBA6F7));
      // El tema claro usa brightness light.
      expect(AppTheme.fromId('claude-light').brightness, Brightness.light);
      expect(AppTheme.fromId('amber').brightness, Brightness.dark);
    });

    test('las familias Desktop conservan sus acentos oficiales', () {
      const expected = {
        'nous': Color(0xFF0053FD),
        'midnight': Color(0xFF8B80E8),
        'ember': Color(0xFFD97316),
        'mono': Color(0xFF9A9A9A),
        'cyberpunk': Color(0xFF00FF41),
        'slate': Color(0xFF58A6FF),
      };
      expected.forEach((id, accent) {
        expect(AppTheme.presetById(id).colors.accent, accent, reason: id);
      });
    });

    test('cada tema expone su color de contraste (no es el acento)', () {
      // El color de contraste rompe el monocromo: llega a la extensión Hermes
      // y al colorScheme, y difiere del acento principal del tema.
      final steel = AppTheme.fromId('steel');
      expect(steel.hermes.secondary, const Color(0xFFD9A868));
      expect(steel.colorScheme.secondary, const Color(0xFFD9A868));
      expect(steel.hermes.secondary, isNot(steel.hermes.accent));

      // Temas distintos tienen contrastes distintos (identidad propia).
      final bordeaux = AppTheme.fromId('bordeaux');
      expect(bordeaux.hermes.secondary, const Color(0xFF86BFA0));
      expect(bordeaux.hermes.secondary, isNot(steel.hermes.secondary));
    });

    test('los títulos llevan el peso/tracking del tema', () {
      // Mocha usa títulos gruesos; Crimson (elegante) tracking amplio.
      expect(
        AppTheme.fromId('mocha').textTheme.titleLarge?.fontWeight,
        FontWeight.w800,
      );
      expect(
        AppTheme.fromId('crimson').textTheme.titleLarge?.letterSpacing,
        1.5,
      );
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
