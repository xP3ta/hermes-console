// Auditoría de contraste/legibilidad de TODOS los temas. Evita la inconsistencia
// típica de "botón con texto que contrasta mal con su fondo" y texto ilegible
// sobre las superficies. Umbrales basados en WCAG 2.1 (ratio de contraste).
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';

// Ratio de contraste WCAG entre dos colores opacos (1..21).
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('contraste y combinación de los temas', () {
    test('el texto del botón (onAccent) es legible sobre el acento', () {
      // AA para texto grande/UI; los botones suelen llevar texto en negrita.
      const min = 3.0;
      final fails = <String>[];
      for (final p in AppTheme.presets) {
        final r = _contrast(p.colors.onAccent, p.colors.accent);
        if (r < min) fails.add('${p.id}: ${r.toStringAsFixed(2)}');
      }
      expect(fails, isEmpty, reason: 'onAccent vs accent flojo en: $fails');
    });

    test('el texto principal es legible sobre fondo y superficies', () {
      const min = 4.5; // AA texto normal
      final fails = <String>[];
      for (final p in AppTheme.presets) {
        final c = p.colors;
        final checks = {
          'background': _contrast(c.textPrimary, c.background),
          'surface': _contrast(c.textPrimary, c.surface),
          'surfaceVariant': _contrast(c.textPrimary, c.surfaceVariant),
        };
        checks.forEach((surf, r) {
          if (r < min) fails.add('${p.id}/$surf: ${r.toStringAsFixed(2)}');
        });
      }
      expect(fails, isEmpty, reason: 'textPrimary flojo en: $fails');
    });

    test('el texto secundario sigue siendo legible sobre el fondo', () {
      const min = 3.0; // texto atenuado: umbral más laxo pero aún legible
      final fails = <String>[];
      for (final p in AppTheme.presets) {
        final r = _contrast(p.colors.textSecondary, p.colors.background);
        if (r < min) fails.add('${p.id}: ${r.toStringAsFixed(2)}');
      }
      expect(fails, isEmpty, reason: 'textSecondary flojo en: $fails');
    });

    test('el acento destaca sobre el fondo (iconos/enlaces)', () {
      const min = 3.0;
      final fails = <String>[];
      for (final p in AppTheme.presets) {
        final r = _contrast(p.colors.accent, p.colors.background);
        if (r < min) fails.add('${p.id}: ${r.toStringAsFixed(2)}');
      }
      expect(fails, isEmpty, reason: 'accent vs background flojo en: $fails');
    });

    test('el color de contraste (secondary) destaca sobre el fondo', () {
      const min = 3.0;
      final fails = <String>[];
      for (final p in AppTheme.presets) {
        final sec = p.secondary;
        if (sec == null) continue;
        final r = _contrast(sec, p.colors.background);
        if (r < min) fails.add('${p.id}: ${r.toStringAsFixed(2)}');
      }
      expect(
        fails,
        isEmpty,
        reason: 'secondary vs background flojo en: $fails',
      );
    });

    // Auditoría 2026-07-02, hallazgo C5c: `accentText` es el token pensado
    // para pintar TEXTO con el acento (no fondos), así que exige el umbral
    // de texto normal (4.5:1), más estricto que el 3.0 de "accent destaca".
    // Solo se cubren los dos temas claros a los que esta pasada les declaró
    // un `accentText` propio (el resto de temas, oscuros o claros sin tocar,
    // quedan fuera de este hallazgo y se abordarán en pasadas posteriores).
    test(
      'accentText es legible como texto normal en los temas claros corregidos',
      () {
        const min = 4.5;
        final checks = <String, HermesThemeColors>{
          'amber-light (hermesRedLight)': AppTheme.hermesRedLight
              .extension<HermesThemeColors>()!,
          'claude-light': AppTheme.presets
              .firstWhere((p) => p.id == 'claude-light')
              .colors,
        };
        final fails = <String>[];
        checks.forEach((name, c) {
          final r = _contrast(c.accentText, c.background);
          if (r < min) fails.add('$name: ${r.toStringAsFixed(2)}');
        });
        expect(fails, isEmpty, reason: 'accentText flojo en: $fails');
      },
    );
  });

  // 1.2.15: every preset in both modes passes the key pairs of the themes
  // audit. Text 4.5:1, large/UI 3:1. The only exceptions are the documented
  // Desktop status tones that are used as dots/icons (non-text, 3:1).
  group('contrast guard: all presets x modes', () {
    const text = 4.5;
    const ui = 3.0;
    // Status tones that only paint dots/icons and may sit at 3–4.5. Empty
    // since the soft palettes (1.2.15): every status colour reads as text.
    const nonTextStatus = <String>{};

    test('every family is covered in light and dark', () {
      final modes = <String, Set<Brightness>>{};
      for (final p in AppTheme.presets) {
        modes.putIfAbsent(p.familyId, () => {}).add(p.brightness);
      }
      for (final entry in modes.entries) {
        expect(entry.value, {
          Brightness.light,
          Brightness.dark,
        }, reason: entry.key);
      }
    });

    test('text, accent and button pairs', () {
      final fails = <String>[];
      void check(String id, String pair, Color fg, Color bg, double min) {
        final r = ThemeContrast.ratio(fg, bg);
        if (r + 1e-9 < min) fails.add('$id $pair ${r.toStringAsFixed(2)}');
      }

      for (final p in AppTheme.presets) {
        final c = p.colors;
        for (final (name, bg) in [
          ('background', c.background),
          ('surface', c.surface),
          ('surfaceVariant', c.surfaceVariant),
        ]) {
          check(p.id, 'textPrimary/$name', c.textPrimary, bg, text);
          check(p.id, 'textSecondary/$name', c.textSecondary, bg, text);
          check(p.id, 'textTertiary/$name', c.textTertiary, bg, text);
        }
        check(p.id, 'accentText/background', c.accentText, c.background, text);
        check(p.id, 'accent/background', c.accent, c.background, ui);
        check(p.id, 'onAccent/accent', c.onAccent, c.accent, text);
      }
      expect(fails, isEmpty, reason: fails.join('\n'));
    });

    test('status colours: text 4.5, documented dots 3–4.5', () {
      final fails = <String>[];
      for (final p in AppTheme.presets) {
        final c = p.colors;
        for (final (name, tone) in [
          ('error', c.error),
          ('warning', c.warning),
          ('success', c.success),
        ]) {
          final key = '${p.id}/$name';
          final r = ThemeContrast.ratio(tone, c.background);
          if (nonTextStatus.contains(key)) {
            if (r < ui || r >= text) {
              fails.add('$key ${r.toStringAsFixed(2)} (listed as 3–4.5)');
            }
          } else if (r + 1e-9 < text) {
            fails.add('$key ${r.toStringAsFixed(2)}');
          }
        }
      }
      expect(fails, isEmpty, reason: fails.join('\n'));
    });

    test('hairlines stay visible (divider vs surface above 1.15)', () {
      final fails = <String>[];
      for (final p in AppTheme.presets) {
        final r = ThemeContrast.ratio(p.colors.divider, p.colors.surface);
        if (r < 1.15) fails.add('${p.id} ${r.toStringAsFixed(3)}');
      }
      expect(fails, isEmpty, reason: fails.join('\n'));
    });

    test('FAB icon and selected chip label read on the contrast colour', () {
      final fails = <String>[];
      for (final p in AppTheme.presets) {
        final theme = AppTheme.fromId(p.id);
        final fab = theme.floatingActionButtonTheme;
        final r = ThemeContrast.ratio(
          fab.foregroundColor!,
          fab.backgroundColor!,
        );
        if (r < ui) fails.add('${p.id} fab ${r.toStringAsFixed(2)}');
        final chip = theme.chipTheme;
        final label = ThemeContrast.ratio(
          chip.secondaryLabelStyle!.color!,
          chip.selectedColor!,
        );
        if (label < text) {
          fails.add('${p.id} chip ${label.toStringAsFixed(2)}');
        }
      }
      expect(fails, isEmpty, reason: fails.join('\n'));
    });

    testWidgets('chat links and code read at 4.5 on every surface', (
      tester,
    ) async {
      final fails = <String>[];
      for (final p in AppTheme.presets) {
        late MarkdownStyleSheet sheet;
        await tester.pumpWidget(
          // Theme (not MaterialApp.theme): no AnimatedTheme lerp between
          // presets, so the sheet sees exactly this preset's colours.
          Directionality(
            textDirection: TextDirection.ltr,
            child: Theme(
              data: AppTheme.fromId(p.id),
              child: Builder(
                builder: (context) {
                  sheet = assistantMarkdownStyleSheet(context, 'x');
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        final c = p.colors;
        final link = sheet.a!.color!;
        for (final (name, bg) in [
          ('background', c.background),
          ('surface', c.surface),
          ('surfaceVariant', c.surfaceVariant),
        ]) {
          final r = ThemeContrast.ratio(link, bg);
          if (r < text) fails.add('${p.id} link/$name ${r.toStringAsFixed(2)}');
        }
        final code = ThemeContrast.ratio(sheet.code!.color!, c.surfaceVariant);
        if (code < text) fails.add('${p.id} code ${code.toStringAsFixed(2)}');
      }
      expect(fails, isEmpty, reason: fails.join('\n'));
    });
  });
}
