// Look & Feel derivation, contrast by construction, preferences and the
// migration of the preset and mode a user already has.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/look_feel.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Colours a user could pick with the free picker, the awkward ones first:
/// the page's own colours, saturated extremes and mid greys.
const _customColors = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFF000000),
  Color(0xFFFFFF00),
  Color(0xFF00FFFF),
  Color(0xFF000080),
  Color(0xFF0A1020),
  Color(0xFFFAF9F5),
  Color(0xFF808080),
  Color(0xFF777777),
  Color(0xFFFF0000),
  Color(0xFF336699),
  Color(0xFFE5E500),
];

const _grounds = <(String, Brightness, LookFeelSettings)>[
  (
    'white',
    Brightness.light,
    LookFeelSettings(lightBackground: LookLightBackground.white),
  ),
  (
    'paper',
    Brightness.light,
    LookFeelSettings(lightBackground: LookLightBackground.paper),
  ),
  (
    'midnight',
    Brightness.dark,
    LookFeelSettings(darkBackground: LookDarkBackground.midnight),
  ),
  (
    'black',
    Brightness.dark,
    LookFeelSettings(darkBackground: LookDarkBackground.black),
  ),
  (
    'gray',
    Brightness.dark,
    LookFeelSettings(darkBackground: LookDarkBackground.gray),
  ),
];

double _worst(Color ink, List<Color> surfaces) =>
    surfaces.map((s) => ThemeContrast.ratio(ink, s)).reduce(math.min);

double _hueGap(Color a, Color b) {
  final delta = (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue).abs();
  return math.min(delta, 360 - delta);
}

void main() {
  group('contrast by construction', () {
    // 5 backgrounds x 10 accents (the nine fixed ones plus the free colour,
    // over a dozen awkward values) x the inks.
    for (final (name, brightness, base) in _grounds) {
      final accents = <(String, LookFeelSettings)>[
        for (final accent in LookFeel.accents)
          (accent.id, base.copyWith(accentId: accent.id)),
        for (final color in _customColors)
          (
            'custom-${color.toARGB32().toRadixString(16)}',
            base.copyWith(accentId: lookAccentCustomId, customAccent: color),
          ),
      ];
      for (final (accentName, settings) in accents) {
        test('$name x $accentName: text, accent text, accent and label', () {
          final preset = LookFeel.preset(settings, brightness);
          final c = preset.colors;
          final surfaces = [c.background, c.surface, c.surfaceVariant];

          expect(preset.brightness, brightness);
          expect(c.isLightPalette, brightness == Brightness.light);
          // Text: primary and secondary above AA, tertiary at AA.
          expect(_worst(c.textPrimary, surfaces), greaterThanOrEqualTo(7.0));
          expect(_worst(c.textSecondary, surfaces), greaterThanOrEqualTo(5.0));
          expect(_worst(c.textTertiary, surfaces), greaterThanOrEqualTo(4.5));
          // The accent as text on the page and on every card fill.
          expect(_worst(c.accentText, surfaces), greaterThanOrEqualTo(4.5));
          // The accent as a component (button fill, selection ring).
          expect(_worst(c.accent, surfaces), greaterThanOrEqualTo(3.0));
          expect(_worst(c.accentHover, surfaces), greaterThanOrEqualTo(3.0));
          // The label on the accent fill.
          expect(
            ThemeContrast.ratio(c.onAccent, c.accent),
            greaterThanOrEqualTo(4.5),
          );
          // Status inks read as text.
          for (final ink in [c.error, c.warning, c.success]) {
            expect(_worst(ink, surfaces), greaterThanOrEqualTo(4.5));
          }
        });
      }
    }

    test('the nine fixed accents keep their hue on every background', () {
      for (final (name, brightness, base) in _grounds) {
        for (final accent in LookFeel.accents) {
          final shown = LookFeel.accentShown(
            base.copyWith(accentId: accent.id),
            accent.id,
            brightness,
          );
          expect(
            _hueGap(shown, accent.seed),
            lessThan(20),
            reason: '${accent.id} on $name',
          );
        }
      }
    });

    test('a custom colour that already reads is painted as picked', () {
      const settings = LookFeelSettings(
        accentId: lookAccentCustomId,
        customAccent: Color(0xFF5B9BE6),
      );
      final surfaces = LookFeel.surfacesOf(settings, Brightness.dark);
      final shown = LookFeel.accentShown(
        settings,
        lookAccentCustomId,
        Brightness.dark,
      );
      // 5B9BE6 reads on the dark pages and on the bodies of their boxes at
      // over 3:1: untouched. (3A7BD5 did on the pages alone; the bodies of
      // the cards, a step lighter, are surfaces of the derivation too.)
      expect(_worst(settings.customAccent, surfaces), greaterThan(3.05));
      expect(shown, settings.customAccent);
    });
  });

  group('glass over derived themes', () {
    // The same two checks glass_look_test makes for the 42 presets, for the
    // derived palettes: nothing is lowered, and every ink reads on the
    // composite surface (4.5:1) and on the reading veil (7:1 / 4.5:1).
    test('5 backgrounds x 3 accents x 3 levels: kept and readable', () {
      final fails = <String>[];
      for (final (name, brightness, base) in _grounds) {
        for (final accentId in ['terracotta', 'blue', 'green']) {
          final colors = LookFeel.preset(
            base.copyWith(accentId: accentId),
            brightness,
          ).colors;
          for (final requested in GlassLevel.values) {
            final material = GlassMaterial.resolve(colors, requested);
            if (requested == GlassLevel.off) {
              expect(material, isNull);
              continue;
            }
            final id = '$name/$accentId/${requested.name}';
            if (material == null || material.level != requested) {
              fails.add('$id lowered to ${material?.level.name}');
              continue;
            }
            final page = ThemeContrast.composite(
              colors.background,
              const Color(0xFF000000),
            );
            final bubble = colors.surfaceVariant.withValues(
              alpha: GlassMaterial.bubbleOpacity,
            );
            for (final back in [page, material.glow]) {
              final reading = material.readingBack(page, back);
              for (final fill in [material.groupFill, material.cardFill]) {
                final surface = ThemeContrast.composite(fill, back);
                final glint = ThemeContrast.composite(material.sheen, surface);
                for (final s in [back, surface, glint]) {
                  for (final ink in [
                    colors.textPrimary,
                    colors.textSecondary,
                  ]) {
                    if (ThemeContrast.ratio(ink, s) + 1e-9 < 4.5) {
                      fails.add('$id ink on glass');
                    }
                  }
                }
              }
              for (final fill in [
                null,
                material.groupFill,
                material.cardFill,
                bubble,
              ]) {
                final surface = fill == null
                    ? reading
                    : ThemeContrast.composite(fill, reading);
                if (ThemeContrast.ratio(colors.textPrimary, surface) + 1e-9 <
                        7.0 ||
                    ThemeContrast.ratio(colors.textSecondary, surface) + 1e-9 <
                        4.5) {
                  fails.add('$id reading veil');
                }
              }
            }
          }
        }
      }
      expect(fails.toSet(), isEmpty, reason: fails.toSet().join('\n'));
    });
  });

  group('backgrounds', () {
    test('their character: night blue, near black, charcoal, white, paper', () {
      Color page(LookDarkBackground b) => LookFeel.darkSwatch(b).$1;
      final midnight = page(LookDarkBackground.midnight);
      final black = page(LookDarkBackground.black);
      final gray = page(LookDarkBackground.gray);
      // Midnight is blue-dominant and very dark.
      expect(midnight.b, greaterThan(midnight.r));
      expect(ThemeContrast.luminance(midnight), lessThan(0.02));
      // Black is the darkest, with a subtle step up to its surface.
      expect(
        ThemeContrast.luminance(black),
        lessThan(ThemeContrast.luminance(midnight)),
      );
      expect(
        ThemeContrast.luminance(
          LookFeel.darkSwatch(LookDarkBackground.black).$2,
        ),
        greaterThan(ThemeContrast.luminance(black)),
      );
      // Gray is lighter than both and neutral.
      expect(
        ThemeContrast.luminance(gray),
        greaterThan(ThemeContrast.luminance(midnight)),
      );
      expect((gray.r - gray.b).abs(), lessThan(0.03));
      // White is white; Paper is the warm cream (red above blue).
      expect(LookFeel.lightSwatch(LookLightBackground.white).$1, Colors.white);
      final paper = LookFeel.lightSwatch(LookLightBackground.paper).$1;
      expect(paper.r, greaterThan(paper.b));
      expect(ThemeContrast.luminance(paper), greaterThan(0.9));
    });

    test('the page, the surface and the raised surface are three steps', () {
      for (final (name, brightness, base) in _grounds) {
        final s = LookFeel.surfacesOf(base, brightness);
        expect(
          {s[0], s[1], s[2]},
          hasLength(3),
          reason: '$name has distinct page, surface and raised surface',
        );
      }
    });
  });

  group('the same tokens as the presets', () {
    test('the derived theme carries the HermesThemeColors extension', () {
      for (final brightness in Brightness.values) {
        const settings = LookFeelSettings(accentId: 'blue');
        final theme = LookFeel.themeData(settings, brightness);
        final colors = LookFeel.preset(settings, brightness).colors;
        expect(theme.brightness, brightness);
        expect(theme.hermes.background, colors.background);
        expect(theme.hermes.accent, colors.accent);
        expect(theme.hermes.textPrimary, colors.textPrimary);
        expect(theme.colorScheme.primary, colors.accent);
        expect(theme.colorScheme.onPrimary, colors.onAccent);
        expect(theme.scaffoldBackgroundColor, colors.background);
      }
    });

    test('«Sistema» gives a light and a dark theme, the others one', () {
      const base = LookFeelSettings();
      final system = LookFeel.materialThemes(base);
      expect(system.theme.brightness, Brightness.light);
      expect(system.darkTheme?.brightness, Brightness.dark);
      final light = LookFeel.materialThemes(
        base.copyWith(appearance: LookAppearance.light),
      );
      expect(light.theme.brightness, Brightness.light);
      expect(light.darkTheme, isNull);
      final dark = LookFeel.materialThemes(
        base.copyWith(appearance: LookAppearance.dark),
      );
      expect(dark.theme.brightness, Brightness.dark);
      expect(dark.darkTheme, isNull);
    });

    test('the catalogue is untouched: 42 presets, fromId unchanged', () {
      expect(AppTheme.presets, hasLength(42));
      final preset = AppTheme.presetById('dracula');
      expect(
        AppTheme.fromId('dracula').hermes.background,
        preset.colors.background,
      );
      expect(
        AppTheme.fromPreset(preset).hermes.accent,
        AppTheme.fromId('dracula').hermes.accent,
      );
    });

    test('the brightness follows the appearance, and the system', () {
      const s = LookFeelSettings();
      expect(s.resolveBrightness(Brightness.dark), Brightness.dark);
      expect(s.resolveBrightness(Brightness.light), Brightness.light);
      expect(
        s
            .copyWith(appearance: LookAppearance.light)
            .resolveBrightness(Brightness.dark),
        Brightness.light,
      );
      expect(
        s
            .copyWith(appearance: LookAppearance.dark)
            .resolveBrightness(Brightness.light),
        Brightness.dark,
      );
    });
  });

  group('preferences', () {
    Future<SharedPreferences> prefsWith([
      Map<String, Object> values = const {},
    ]) {
      SharedPreferences.setMockInitialValues(values);
      return SharedPreferences.getInstance();
    }

    test(
      'a fresh install reads as the list (today\'s Console) in «Sistema»',
      () async {
        final store = LookFeelPrefs(await prefsWith());
        expect(store.settings.source, LookFeelSource.list);
        expect(store.settings.appearance, LookAppearance.system);
        expect(store.settings.accentId, 'terracotta');
        expect(store.settings.lightBackground, LookLightBackground.paper);
        expect(store.settings.darkBackground, LookDarkBackground.gray);
      },
    );

    test(
      'migration: a saved preset and its mode stay as «tema de la lista»',
      () async {
        // A dark preset.
        var settings = LookFeelPrefs.read(
          await prefsWith({'active_theme_profile_id': 'dracula'}),
        );
        expect(settings.source, LookFeelSource.list);
        expect(settings.appearance, LookAppearance.dark);
        // A light preset.
        settings = LookFeelPrefs.read(
          await prefsWith({'active_theme_profile_id': 'amber-light'}),
        );
        expect(settings.source, LookFeelSource.list);
        expect(settings.appearance, LookAppearance.light);
        // «Auto» of a family follows the system.
        settings = LookFeelPrefs.read(
          await prefsWith({
            'active_theme_profile_id': 'claude-light',
            'theme_follow_system': true,
          }),
        );
        expect(settings.appearance, LookAppearance.system);
        // The legacy key alone, and a retired id (`light` migrates to Amber
        // light, `oled` to Amber dark).
        expect(
          LookFeelPrefs.read(
            await prefsWith({'theme_mode': 'light'}),
          ).appearance,
          LookAppearance.light,
        );
        expect(
          LookFeelPrefs.read(
            await prefsWith({'theme_mode': 'oled'}),
          ).appearance,
          LookAppearance.dark,
        );
        // A custom or unknown id: the system.
        expect(
          LookFeelPrefs.read(
            await prefsWith({'active_theme_profile_id': 'my-own-uuid'}),
          ).appearance,
          LookAppearance.system,
        );
      },
    );

    test('garbage in the stored values falls back to the defaults', () async {
      final settings = LookFeelPrefs.read(
        await prefsWith({
          'lfl_source': 'nope',
          'lfl_appearance': 'sepia',
          'lfl_accent': 'chartreuse',
          'lfl_light_background': 'x',
          'lfl_dark_background': 'y',
        }),
      );
      expect(settings.source, LookFeelSource.list);
      expect(settings.appearance, LookAppearance.system);
      expect(settings.accentId, 'terracotta');
      expect(settings.lightBackground, LookLightBackground.paper);
      expect(settings.darkBackground, LookDarkBackground.gray);
    });

    test(
      'a change applies at once, puts Look & Feel in force and persists',
      () async {
        final raw = await prefsWith({'active_theme_profile_id': 'dracula'});
        final store = LookFeelPrefs(raw);
        var notified = 0;
        store.addListener(() => notified++);

        final pending = store.setAppearance(LookAppearance.light);
        // Synchronous: the app can repaint before the write finishes.
        expect(notified, 1);
        expect(store.settings.appearance, LookAppearance.light);
        expect(store.settings.derived, isTrue);
        await pending;

        await store.setAccent('green');
        await store.setLightBackground(LookLightBackground.white);
        await store.setDarkBackground(LookDarkBackground.midnight);
        await store.setCustomAccent(const Color(0x80336699));
        expect(notified, 5);
        // The picker's alpha never leaks into the theme.
        expect(store.settings.customAccent, const Color(0xFF336699));
        expect(store.settings.accentId, lookAccentCustomId);
      },
    );

    test(
      'persistence: a new instance with the same prefs reads the same',
      () async {
        final raw = await prefsWith({'active_theme_profile_id': 'dracula'});
        final first = LookFeelPrefs(raw);
        await first.setAppearance(LookAppearance.dark);
        await first.setAccent('violet');
        await first.setDarkBackground(LookDarkBackground.black);
        await first.setLightBackground(LookLightBackground.white);
        await first.setCustomAccent(const Color(0xFF123456));

        final second = LookFeelPrefs(raw);
        expect(second.settings, first.settings);
        expect(second.settings.accentId, lookAccentCustomId);
        expect(second.settings.customAccent, const Color(0xFF123456));
        expect(second.settings.darkBackground, LookDarkBackground.black);
        expect(second.settings.derived, isTrue);
      },
    );

    test(
      '«Más temas»: a list theme leaves the choices, the way back brings them',
      () async {
        final raw = await prefsWith();
        final store = LookFeelPrefs(raw);
        await store.setAppearance(LookAppearance.dark);
        await store.setAccent('teal');
        await store.setDarkBackground(LookDarkBackground.midnight);
        final chosen = store.settings;

        var notified = 0;
        store.addListener(() => notified++);
        await store.useList();
        expect(store.settings.source, LookFeelSource.list);
        expect(notified, 1);
        // Nothing of the choices is lost.
        expect(store.settings.copyWith(source: LookFeelSource.derived), chosen);
        // It survives a restart as the list.
        expect(LookFeelPrefs(raw).settings.source, LookFeelSource.list);

        await store.returnToLookFeel();
        expect(store.settings, chosen);
        expect(LookFeelPrefs(raw).settings, chosen);
      },
    );

    test('an unchanged value does not notify or rewrite', () async {
      final store = LookFeelPrefs(await prefsWith());
      await store.setAppearance(LookAppearance.dark);
      var notified = 0;
      store.addListener(() => notified++);
      await store.setAppearance(LookAppearance.dark);
      await store.useList();
      await store.useList();
      expect(notified, 1);
    });
  });
}
