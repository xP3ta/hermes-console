// The tint of a dark page in every surface lifted from it (HermesPageTint):
// on Midnight the bodies of the boxes, the chrome of menus and sheets, the
// glass pieces, the gel of the buttons, the soft widget surface and the dock
// all keep the page's hue and most of its saturation, and every ink still
// reads on them; Black and Gray keep the very values they had.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/box_fill.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/look_feel.dart';
import 'package:hermes_android/core/theme/soft_tokens.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/dock_style.dart';

HermesThemeColors _ground(LookDarkBackground background, [String? accent]) =>
    LookFeel.preset(
      LookFeelSettings(
        darkBackground: background,
        accentId: accent ?? 'terracotta',
      ),
      Brightness.dark,
    ).colors;

const _white = Color(0xFFFFFFFF);
const _black = Color(0xFF000000);

Color _opaque(Color color, Color over) => ThemeContrast.composite(color, over);

double _hueGap(Color a, Color b) {
  final delta = (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue).abs();
  return math.min(delta, 360 - delta);
}

double _saturation(Color c) => HSLColor.fromColor(c).saturation;

/// The surfaces that are lines (a contour, a hairline): tinted like the
/// rest, but no text is read on them.
const _lines = {
  'contour top on page',
  'contour bottom on page',
  'chrome line on page',
  'gel hairline on page',
};

/// Every opaque surface of [colors], by name: each level a dark page lifts.
Map<String, Color> _surfaces(HermesThemeColors colors) {
  final page = colors.background;
  final fill = HermesBoxFill.of(colors);
  final glass = GlassMaterial.resolve(colors, GlassLevel.full)!;
  final chrome = HermesChrome.of(colors);
  final gel = HermesGel.of(colors);
  final soft = SoftPalette.of(colors, Brightness.dark);
  final docks = {
    'dock flat opaque': const DockStyle(depth: DockDepth.flat),
    'dock elevated': const DockStyle(),
    'dock floating': const DockStyle(depth: DockDepth.floating),
  };
  return {
    'group': fill.group,
    'card': fill.card,
    'piece on page': _opaque(glass.pieceFill, page),
    'piece on card': _opaque(glass.pieceFill, fill.card),
    'contour top on page': _opaque(glass.lineTop, page),
    'contour bottom on page': _opaque(glass.lineBottom, page),
    'chrome fill on page': _opaque(chrome.fill, page),
    'chrome opaque': chrome.opaque,
    'chrome raised': chrome.raised,
    'chrome line on page': _opaque(chrome.line, page),
    'gel glass on page': _opaque(gel.glassFill, page),
    'gel hairline on page': _opaque(gel.hairline, page),
    'soft surface': soft.surface,
    for (final entry in docks.entries)
      entry.key: _opaque(
        resolveDockVisual(colors, entry.value).background,
        page,
      ),
  };
}

void main() {
  group('HermesPageTint', () {
    test('Midnight is tinted; Black, Gray and the light pages are not', () {
      expect(HermesPageTint.isTinted(const Color(0xFF0A1020)), isTrue);
      for (final b in LookDarkBackground.values) {
        expect(
          HermesPageTint.isTinted(LookFeel.darkSwatch(b).$1),
          b == LookDarkBackground.midnight,
          reason: b.name,
        );
      }
      // Paper is warm, but a light page is never tinted.
      for (final b in LookLightBackground.values) {
        expect(
          HermesPageTint.isTinted(LookFeel.lightSwatch(b).$1),
          isFalse,
          reason: b.name,
        );
      }
      expect(HermesPageTint.isTinted(_black), isFalse);
    });

    test('on a neutral page every call is the plain white mix', () {
      for (final page in [
        LookFeel.darkSwatch(LookDarkBackground.black).$1,
        LookFeel.darkSwatch(LookDarkBackground.gray).$1,
        for (final preset in AppTheme.presets)
          if (preset.isDark &&
              !HermesPageTint.isTinted(preset.colors.background))
            preset.colors.background,
      ]) {
        for (final amount in [0.055, 0.075, 0.1, 0.15]) {
          expect(
            HermesPageTint.lift(page, amount, page: page),
            ThemeContrast.blend(page, _white, amount),
            reason: '$page lift $amount',
          );
          expect(
            HermesPageTint.veil(page, amount),
            _white.withValues(alpha: amount),
            reason: '$page veil $amount',
          );
        }
      }
    });

    test('on a tinted page the lift keeps hue and saturation', () {
      const page = Color(0xFF0A1020);
      for (final amount in [0.06, 0.1, 0.15, 0.25]) {
        final lifted = HermesPageTint.lift(page, amount, page: page);
        final mixed = ThemeContrast.blend(page, _white, amount);
        expect(_hueGap(lifted, page), lessThan(3), reason: '$amount');
        expect(
          _saturation(lifted),
          closeTo(_saturation(page), 0.03),
          reason: '$amount',
        );
        // The same lightness the mix reached: a step up, never a jump.
        expect(
          HSLColor.fromColor(lifted).lightness,
          closeTo(HSLColor.fromColor(mixed).lightness, 0.01),
        );
      }
    });

    test('the veil lifts the page as much as the white it stands in for', () {
      const page = Color(0xFF0A1020);
      for (final alpha in [0.055, 0.075, 0.14, 0.15]) {
        final veil = HermesPageTint.veil(page, alpha);
        final tinted = _opaque(veil, page);
        final white = _opaque(_white.withValues(alpha: alpha), page);
        expect(
          veil.a,
          closeTo(alpha * HermesPageTint.veilOpacity, 0.01),
          reason: '$alpha',
        );
        // What white lifts the page to, in the page's own hue.
        expect(
          HSLColor.fromColor(tinted).lightness,
          closeTo(HSLColor.fromColor(white).lightness, 0.012),
          reason: '$alpha',
        );
        expect(_hueGap(tinted, page), lessThan(4), reason: '$alpha');
        expect(_saturation(tinted), greaterThan(0.45), reason: '$alpha');
      }
    });
  });

  group('Midnight: every surface keeps the hue of the page', () {
    final colors = _ground(LookDarkBackground.midnight);
    final page = colors.background;

    test('the page is a saturated night blue', () {
      expect(_saturation(page), greaterThan(0.5));
    });

    for (final entry in _surfaces(colors).entries) {
      test(entry.key, () {
        final surface = entry.value;
        expect(surface.a, 1, reason: 'opaque');
        expect(
          _hueGap(surface, page),
          lessThan(8),
          reason: '${entry.key} hue ${HSLColor.fromColor(surface).hue}',
        );
        // At least most of the page's saturation: a blue, not a grey-blue.
        expect(
          _saturation(surface),
          greaterThanOrEqualTo(_saturation(page) * 0.7),
          reason: '${entry.key} saturation ${_saturation(surface)}',
        );
        // And lighter than the page: a surface, not the page again.
        expect(
          ThemeContrast.luminance(surface),
          greaterThan(ThemeContrast.luminance(page)),
          reason: entry.key,
        );
      });
    }

    test('the levels step up in order: page, group, card, chrome, raised', () {
      final s = _surfaces(colors);
      final order = [
        page,
        s['group']!,
        s['card']!,
        s['chrome opaque']!,
        s['chrome raised']!,
      ];
      for (var i = 1; i < order.length; i++) {
        expect(
          ThemeContrast.luminance(order[i]),
          greaterThan(ThemeContrast.luminance(order[i - 1])),
          reason: 'step $i',
        );
      }
    });

    test('the glass pieces stay translucent', () {
      final glass = GlassMaterial.resolve(colors, GlassLevel.full)!;
      expect(glass.level, GlassLevel.full);
      expect(glass.pieceFill.a, lessThan(0.15));
      expect(HermesGel.of(colors).glassFill.a, lessThan(0.15));
    });

    test('the glass stays Full with each of the ten accents', () {
      for (final id in [
        for (final accent in LookFeel.accents) accent.id,
        lookAccentCustomId,
      ]) {
        final c = _ground(LookDarkBackground.midnight, id);
        expect(
          GlassMaterial.effective(c, GlassLevel.full),
          GlassLevel.full,
          reason: id,
        );
      }
    });
  });

  group('Midnight: contrast on every tinted surface', () {
    // What the derivation guarantees, checked on the tinted surfaces: the
    // main ink AAA and the secondary and tertiary inks AA on every body text
    // is read on; the accent as a control 3:1 and the link ink AA on the
    // theme's own surfaces (page, surface, raised surface); the chrome's and
    // the soft widgets' inks on their bodies.
    for (final id in [
      for (final accent in LookFeel.accents) accent.id,
      lookAccentCustomId,
    ]) {
      test('accent $id', () {
        final colors = _ground(LookDarkBackground.midnight, id);
        final chrome = HermesChrome.of(colors);
        final soft = SoftPalette.of(colors, Brightness.dark);
        final failures = <String>[];
        void need(String what, Color ink, Color back, double minimum) {
          final ratio = ThemeContrast.ratio(ink, back);
          if (ratio + 1e-9 < minimum) {
            failures.add('$what ${ratio.toStringAsFixed(2)} < $minimum');
          }
        }

        for (final entry in _surfaces(colors).entries) {
          final name = entry.key;
          // A contour or a hairline is a line: no text is read on it.
          if (_lines.contains(name)) continue;
          final back = entry.value;
          need('$name: primary', colors.textPrimary, back, 7);
          need('$name: secondary', colors.textSecondary, back, 4.5);
          // The raised chrome reads its own muted ink, below.
          if (name == 'chrome raised') continue;
          need('$name: tertiary', colors.textTertiary, back, 4.5);
        }
        // The accent's contract (LookFeel.componentContrast and
        // accentTextContrast) is the theme's own three surfaces.
        for (final back in [
          colors.background,
          colors.surface,
          colors.surfaceVariant,
        ]) {
          need('$back: accent', colors.accent, back, 3);
          need('$back: accent text', colors.accentText, back, 4.5);
        }
        need('chrome: muted ink', chrome.mutedInk, chrome.opaque, 4.5);
        need('chrome: ink', chrome.ink, chrome.opaque, 7);
        need('soft: text', soft.text, soft.surface, 7);
        need('soft: muted', soft.textMuted, soft.surface, 4.5);
        need('soft: faint', soft.faint, soft.surface, 4.5);
        expect(failures, isEmpty, reason: failures.join('\n'));
      });
    }
  });

  group('Black and Gray keep their surfaces', () {
    // The values before the tint existed, pinned: the plain white mix.
    const pinned = {
      LookDarkBackground.black: (
        group: Color(0xFF202020),
        card: Color(0xFF232323),
        opaque: Color(0xFF242424),
        raised: Color(0xFF313131),
        soft: Color(0xFF0E0E0E),
      ),
      LookDarkBackground.gray: (
        group: Color(0xFF333335),
        card: Color(0xFF353538),
        opaque: Color(0xFF3C3C40),
        raised: Color(0xFF48484B),
        soft: Color(0xFF26262A),
      ),
    };
    for (final entry in pinned.entries) {
      test(entry.key.name, () {
        final colors = _ground(entry.key);
        final fill = HermesBoxFill.of(colors);
        final glass = GlassMaterial.resolve(colors, GlassLevel.full)!;
        final chrome = HermesChrome.of(colors);
        final gel = HermesGel.of(colors);
        expect(fill.group, entry.value.group);
        expect(fill.card, entry.value.card);
        expect(chrome.opaque, entry.value.opaque);
        expect(chrome.raised, entry.value.raised);
        expect(
          SoftPalette.of(colors, Brightness.dark).surface,
          entry.value.soft,
        );
        expect(glass.pieceFill, _white.withValues(alpha: 0.075));
        expect(gel.glassFill, _white.withValues(alpha: 0.075));
        // The lines are white (no tint), at or above their floors: their
        // alpha is searched per page ([HermesLines.contourRatio]).
        expect(gel.hairline.withValues(alpha: 1), _white);
        expect(
          gel.hairline.a,
          greaterThanOrEqualTo(HermesGel.hairlineFloorDark - 1e-6),
        );
        expect(chrome.line.withValues(alpha: 1), _white);
        expect(chrome.line.a, greaterThanOrEqualTo(HermesChrome.lineFloorDark));
        // Neutral: no channel stands out.
        for (final surface in _surfaces(colors).values) {
          expect(
            SoftPalette.chroma(surface),
            lessThan(0.02),
            reason: '$surface',
          );
        }
        // The dock is the plain mix too.
        final style = const DockStyle(depth: DockDepth.floating);
        final visual = resolveDockVisual(colors, style);
        var expected = Color.lerp(
          colors.surface,
          _white,
          style.transparency * 0.22,
        )!;
        expected = Color.lerp(expected, _white, 0.03)!;
        expect(
          visual.background.toARGB32(),
          expected
              .withValues(alpha: expected.a * (1 - 0.68 * style.transparency))
              .toARGB32(),
        );
      });
    }
  });
}
