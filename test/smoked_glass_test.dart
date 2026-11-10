import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/smoked_glass.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';

// The two classic palettes, as in app_theme.dart.
const _classicDark = HermesThemeColors(
  background: Color(0xFF1F1F2B),
  surface: Color(0xFF272834),
  surfaceVariant: Color(0xFF30303E),
  accent: Color(0xFFEEC46E),
  accentHover: Color(0xFFF6D78C),
  onAccent: Color(0xFF211909),
  accentText: Color(0xFFEEC46E),
  textPrimary: Color(0xFFF3EFDE),
  textSecondary: Color(0xFFB1A793),
  textDisabled: Color(0xFF796F5D),
  divider: Color(0xFF383947),
  error: Color(0xFFDD817A),
  warning: Color(0xFFE0B861),
  success: Color(0xFF83D399),
);

const _classicLight = HermesThemeColors(
  background: Color(0xFFF5F5F5),
  surface: Color(0xFFFBFBFB),
  surfaceVariant: Color(0xFFEBEAE7),
  accent: Color(0xFF7C5F27),
  accentHover: Color(0xFF6C4F15),
  onAccent: Color(0xFFFFFFFF),
  accentText: Color(0xFF7C5F27),
  textPrimary: Color(0xFF353025),
  textSecondary: Color(0xFF665D4B),
  textDisabled: Color(0xFFA09884),
  divider: Color(0xFFE0DEDA),
  error: Color(0xFFAB4D45),
  warning: Color(0xFF985F28),
  success: Color(0xFF2E7A4C),
);

void main() {
  test('the matrix keeps grey on grey and pulls white to the pivot', () {
    const glass = HermesSmokedGlass.dark;
    final m = glass.matrix;
    // White (255 on every channel) lands at luminance·255 on a black pivot.
    final red = (m[0] + m[1] + m[2]) * 255 + m[4];
    expect(red, closeTo(glass.luminance * 255, 1e-6));
    // Rows sum to the same value: a grey stays grey.
    expect(m[5] + m[6] + m[7], closeTo(m[0] + m[1] + m[2], 1e-9));
    expect(m[10] + m[11] + m[12], closeTo(m[0] + m[1] + m[2], 1e-9));
    // Light pivot: black lands at (1 − luminance)·255.
    expect(HermesSmokedGlass.light.matrix[4], closeTo(0.85 * 255, 1e-6));
  });

  // Git R1, OPUS-WIRING-CONTRAST-RANGE-1: an ink whose luminance falls
  // inside the range under the glass meets a page that matches it, 1:1.
  test('an ink inside the range under the glass reads 1:1 and is refused', () {
    final chrome = HermesChrome.of(_classicDark);
    expect(chrome.opaque, const Color(0xFF3C3C48));
    const glass = HermesSmokedGlass.dark;
    const ink = Color(0xFF2F2F33);
    final (lo, hi) = glass.underRange(chrome);
    final l = ThemeContrast.luminance(ink);
    expect(l, inInclusiveRange(lo, hi));
    expect(glass.worstRatio(ink, chrome), 1);
    // The page that does it: grey 210 behind, toned, under the veil.
    final m = glass.matrix;
    double toned(int row) =>
        ((m[row * 5] + m[row * 5 + 1] + m[row * 5 + 2]) * 210 + m[row * 5 + 4])
            .clamp(0, 255) /
        255;
    final under = Color.from(
      alpha: 1,
      red: glass.veil * chrome.opaque.r + (1 - glass.veil) * toned(0),
      green: glass.veil * chrome.opaque.g + (1 - glass.veil) * toned(1),
      blue: glass.veil * chrome.opaque.b + (1 - glass.veil) * toned(2),
    );
    final floor = ThemeContrast.ratio(ink, chrome.opaque);
    expect(ThemeContrast.ratio(ink, under), lessThan(floor));
    // So the strip keeps the opaque chrome for it: the floor is not lowered.
    expect(glass.readsFor(_classicDark, [ink]), isFalse);
    // An ink outside the range is measured against the nearer end.
    final primary = _classicDark.textPrimary;
    expect(ThemeContrast.luminance(primary), greaterThan(hi));
    expect(
      glass.worstRatio(primary, chrome),
      closeTo((ThemeContrast.luminance(primary) + 0.05) / (hi + 0.05), 1e-12),
    );
  });

  for (final (name, colors) in [
    ('classic-dark', _classicDark),
    ('classic-light', _classicLight),
  ]) {
    test('$name: every foot ink reads on the smoked glass', () {
      final chrome = HermesChrome.of(colors);
      final glass = HermesSmokedGlass.of(chrome);
      expect(
        glass.readsFor(colors, HermesSmokedGlass.footInks(colors)),
        isTrue,
      );
      for (final ink in HermesSmokedGlass.footInks(colors)) {
        final now = ThemeContrast.ratio(ink, chrome.opaque);
        expect(
          glass.worstRatio(ink, chrome),
          greaterThanOrEqualTo(now < 4.5 ? now : 4.5),
          reason: '$ink',
        );
      }
    });

    test('$name: the glass lets the page through', () {
      final chrome = HermesChrome.of(colors);
      final glass = HermesSmokedGlass.of(chrome);
      final (lo, hi) = glass.underRange(chrome);
      // Not a uniform fill: what passes behind moves the luminance.
      expect(hi - lo, greaterThan(0.02));
      expect(glass.veil, lessThan(1));
    });
  }

  test('the user transparency is a floor for the veil, never lowered', () {
    const glass = HermesSmokedGlass.dark;
    expect(glass.withVeilFloor(0.1), same(glass));
    final floored = glass.withVeilFloor(0.592);
    expect(floored.veil, 0.592);
    expect(floored.pivot, glass.pivot);
    expect(floored.luminance, glass.luminance);
    expect(floored.chroma, glass.chroma);
  });

  // The dock's own tone (dockOf), the one dock_style and gesture_dock use.
  // The bar's icons read on it on every theme. The rail's inks (dockInks,
  // textSecondary among them) do not once the range is certified: about
  // 4.33 at floor 0 and 4.46 at 0.6 on classic-dark, under 4 on dockLight.
  // The rail and the classic bar keep their material of before (Hermes,
  // 31 Oct). The guard is not relaxed.
  for (final themeId in const ['classic-dark', 'console-light', 'classic']) {
    test('$themeId: on the dock tone the bar reads, the rail falls back', () {
      final colors = AppTheme.fromId(themeId).hermes;
      final chrome = HermesChrome.of(colors);
      for (final floor in const [0.0, 0.6]) {
        final glass = HermesSmokedGlass.dockOf(chrome).withVeilFloor(floor);
        expect(
          glass.readsFor(colors, HermesSmokedGlass.barInks(colors)),
          isTrue,
          reason: 'bar, floor $floor',
        );
        expect(
          glass.readsFor(colors, HermesSmokedGlass.dockInks(colors)),
          isFalse,
          reason: 'rail, floor $floor',
        );
      }
    });
  }

  test('a layer over the fill (the dock selection) moves the range and the '
      'inside still reads 1:1', () {
    final chrome = HermesChrome.of(_classicDark);
    const glass = HermesSmokedGlass.dark;
    final selection = _classicDark.accent.withValues(alpha: .16);
    final (lo, hi) = glass.underRange(chrome);
    final (slo, shi) = glass.underRange(chrome, over: selection);
    expect((slo, shi), isNot((lo, hi)));
    final (dark, light) = glass.underExtremes(chrome, over: selection);
    // The colours found sit inside the certified range (it is wider).
    expect(ThemeContrast.luminance(dark), greaterThanOrEqualTo(slo));
    expect(ThemeContrast.luminance(light), lessThanOrEqualTo(shi));
    // A grey between the two ends meets itself somewhere: 1:1.
    final inside = [for (var v = 0; v < 256; v++) Color.fromARGB(255, v, v, v)]
        .where((c) {
          final l = ThemeContrast.luminance(c);
          return l > slo && l < shi;
        })
        .toList();
    expect(inside, isNotEmpty);
    for (final grey in inside) {
      expect(glass.worstRatio(grey, chrome, over: selection), 1);
    }
    // The selected ink of the dock clears both ends and the inside.
    expect(
      glass.worstRatio(_classicDark.accentText, chrome, over: selection),
      greaterThanOrEqualTo(3.05),
    );
  });

  // Terminal's q9_dock_glass_test: a red page behind must show through the
  // dock glass by more than 30 of redness over the opaque dock.
  double redness(Color c) => (c.r - (c.g + c.b) / 2) * 255;
  Color throughTone(HermesSmokedGlass glass, HermesChrome chrome, Color page) {
    final m = glass.matrix;
    double row(int r) =>
        ((m[r * 5] * page.r + m[r * 5 + 1] * page.g + m[r * 5 + 2] * page.b) *
                    255 +
                m[r * 5 + 4])
            .clamp(0, 255) /
        255;
    return Color.from(
      alpha: 1,
      red: glass.veil * chrome.opaque.r + (1 - glass.veil) * row(0),
      green: glass.veil * chrome.opaque.g + (1 - glass.veil) * row(1),
      blue: glass.veil * chrome.opaque.b + (1 - glass.veil) * row(2),
    );
  }

  for (final themeId in const ['classic-dark', 'console-light']) {
    test('$themeId: the dock tone keeps the red signal and its bar inks', () {
      final colors = AppTheme.fromId(themeId).hermes;
      final chrome = HermesChrome.of(colors);
      // The dock's default transparency (0.6) gives a veil of 0.592.
      final glass = HermesSmokedGlass.dockOf(chrome).withVeilFloor(0.592);
      const red = Color(0xFFE53935);
      expect(
        redness(throughTone(glass, chrome, red)),
        greaterThan(redness(chrome.opaque) + 30),
      );
      expect(glass.readsFor(colors, HermesSmokedGlass.barInks(colors)), isTrue);
      // The selected item: accentText adjusted to 3.05 over the selection
      // tint on the toned range, the inside of the range included.
      final selection = colors.accent.withValues(
        alpha: chrome.dark ? .16 : .14,
      );
      final (dark, light) = glass.underExtremes(chrome, over: selection);
      final adjusted = ThemeContrast.adjustForContrastResult(
        colors.accentText,
        [dark, light],
        minimum: 3.05,
        maximumHueShift: 10,
      );
      expect(adjusted.achieved, isTrue);
      expect(
        glass.worstRatio(adjusted.color, chrome, over: selection),
        greaterThanOrEqualTo(3.05),
      );
    });
  }

  test('the chat foot uses chatDark on a dark page; dark is unchanged', () {
    final dark = HermesChrome.of(_classicDark);
    final light = HermesChrome.of(_classicLight);
    expect(HermesSmokedGlass.of(dark), HermesSmokedGlass.chatDark);
    expect(HermesSmokedGlass.of(light), HermesSmokedGlass.chatLight);
    // The shared dark tone (the dock's) is not changed.
    expect(HermesSmokedGlass.dark.luminance, 0.20);
    // The foot rests on a heavier veil of the chrome's grey than the dock
    // (0.40 against 0.30: a greyer body, not a black slab), same chroma.
    expect(HermesSmokedGlass.chatDark.veil, 0.40);
    expect(
      HermesSmokedGlass.chatDark.veil,
      greaterThan(HermesSmokedGlass.dark.veil),
    );
    expect(HermesSmokedGlass.chatDark.chroma, HermesSmokedGlass.dark.chroma);
    expect(HermesSmokedGlass.dark.veil, 0.30);
    expect(HermesSmokedGlass.panelDark.veil, 0.62);
    expect(
      HermesSmokedGlass.chatDark.readsFor(
        _classicDark,
        HermesSmokedGlass.footInks(_classicDark),
      ),
      isTrue,
    );
  });

  // Foot grey (the owner, 1 Nov): the foot's dark body was a black slab (veil 0.30
  // over a page toned to ~#16). The veil is now 0.40 of the chrome's grey.
  // Certification is not lowered: every dark preset where the tone is worn
  // still reads with the foot's inks (readsFor, target 4.5 or the ratio on the
  // opaque chrome), and over a pure black page the body is never near black.
  // The strip only wears the tone where readsFor holds and keeps the opaque
  // chrome elsewhere, so a preset the tone cannot serve is a named fallback,
  // not a pass: Indigo cristal (page #08090F, added after the sweep that
  // tuned chatDark) is the one dark preset whose foot inks do not read on it.
  // The list is pinned: a second preset falling back fails here.
  test('chatDark: 20/21 dark presets read, body never near black', () {
    final dark = AppTheme.presets.where((p) => p.isDark).toList();
    expect(dark.length, 21);
    final tone = HermesSmokedGlass.chatDark;
    final opaqueFallback = <String>[];
    for (final p in dark) {
      if (!tone.readsFor(p.colors, HermesSmokedGlass.footInks(p.colors))) {
        opaqueFallback.add(p.id);
        continue;
      }
      final chrome = HermesChrome.of(p.colors);
      final overBlack = ThemeContrast.composite(
        tone.veilOf(chrome),
        const Color(0xFF000000),
      );
      expect(
        ThemeContrast.luminance(overBlack),
        greaterThanOrEqualTo(0.006),
        reason: '${p.id} body over a black page',
      );
    }
    expect(opaqueFallback, ['indigo-glass']);
  });

  test('the lit rim: a light edge on a dark page, a soft one on a light', () {
    final dark = HermesChrome.of(_classicDark);
    final light = HermesChrome.of(_classicLight);
    expect(HermesGlassRim.edgeOf(dark).a, closeTo(0.20, 0.01));
    expect(HermesGlassRim.edgeOf(light).a, closeTo(0.12, 0.01));
    // The edge is the page's ink: light over dark glass.
    expect(
      ThemeContrast.luminance(HermesGlassRim.edgeOf(dark).withValues(alpha: 1)),
      greaterThan(0.5),
    );
  });

  test('chatDark: the other tones do not move', () {
    expect(HermesSmokedGlass.panelDark.luminance, 0.15);
    expect(HermesSmokedGlass.chatLight.veil, 0.50);
    expect(HermesSmokedGlass.chatLight.luminance, 0.25);
  });

  // A/B f241a8c7: the light pill showed 6 < 12 of the image behind. The chat
  // foot's light tone lets more through and adjusts the pill's status inks,
  // just enough, instead of lowering AA.
  test('chatLight: every foot ink reads, status inks only darken in hue', () {
    final chrome = HermesChrome.of(_classicLight);
    const glass = HermesSmokedGlass.chatLight;
    expect(HermesSmokedGlass.of(chrome), glass);
    expect(
      glass.readsFor(_classicLight, HermesSmokedGlass.footInks(_classicLight)),
      isTrue,
    );
    final adapted = glass.adaptedInks(_classicLight);
    expect(adapted.textPrimary, _classicLight.textPrimary);
    expect(adapted.textSecondary, _classicLight.textSecondary);
    for (final (before, after) in [
      (_classicLight.warning, adapted.warning),
      (_classicLight.error, adapted.error),
      (_classicLight.accentText, adapted.accentText),
      (_classicLight.accent, adapted.accent),
    ]) {
      expect(
        ThemeContrast.luminance(after),
        lessThanOrEqualTo(ThemeContrast.luminance(before)),
      );
      final hue =
          (HSLColor.fromColor(before).hue - HSLColor.fromColor(after).hue)
              .abs();
      expect(hue > 180 ? 360 - hue : hue, lessThan(10));
      final floor = [
        ThemeContrast.ratio(before, chrome.opaque),
        4.5,
      ].reduce((a, b) => a < b ? a : b);
      expect(glass.worstRatio(after, chrome), greaterThanOrEqualTo(floor));
    }
    // Something really changed on classic: warning reads only adjusted.
    expect(adapted.warning, isNot(_classicLight.warning));
  });

  test('chatDark keeps every ink as it is', () {
    final adapted = HermesSmokedGlass.chatDark.adaptedInks(_classicDark);
    expect(adapted.accent, _classicDark.accent);
    expect(adapted.accentText, _classicDark.accentText);
    expect(adapted.warning, _classicDark.warning);
    expect(adapted.error, _classicDark.error);
  });

  // Navegador, 31 Oct: a colour between the coarse samples can sit darker
  // than every sample (chatLight: 0.7182 sampled, below 0.700 found between
  // samples). underRange is certified: a dense grid that does not line up
  // with the coarse one never falls outside it.
  for (final (name, colors, glass) in [
    ('classic chatLight', _classicLight, HermesSmokedGlass.chatLight),
    ('classic light', _classicLight, HermesSmokedGlass.light),
    ('classic-dark chatDark', _classicDark, HermesSmokedGlass.chatDark),
    ('classic-dark dark', _classicDark, HermesSmokedGlass.dark),
  ]) {
    test('$name: no colour of the cube sits outside underRange', () {
      final chrome = HermesChrome.of(colors);
      final (lo, hi) = glass.underRange(chrome);
      final m = glass.matrix;
      double channel(int row, double r, double g, double b) =>
          ((m[row * 5] * r + m[row * 5 + 1] * g + m[row * 5 + 2] * b) * 255 +
                  m[row * 5 + 4])
              .clamp(0, 255) /
          255;
      const n = 30;
      var least = double.infinity, most = double.negativeInfinity;
      var leastAt = '', mostAt = '';
      for (var ri = 0; ri <= n; ri++) {
        for (var gi = 0; gi <= n; gi++) {
          for (var bi = 0; bi <= n; bi++) {
            final r = ri / n, g = gi / n, b = bi / n;
            final under = Color.from(
              alpha: 1,
              red:
                  glass.veil * chrome.opaque.r +
                  (1 - glass.veil) * channel(0, r, g, b),
              green:
                  glass.veil * chrome.opaque.g +
                  (1 - glass.veil) * channel(1, r, g, b),
              blue:
                  glass.veil * chrome.opaque.b +
                  (1 - glass.veil) * channel(2, r, g, b),
            );
            final l = ThemeContrast.luminance(under);
            if (l < least) (least, leastAt) = (l, '$r $g $b');
            if (l > most) (most, mostAt) = (l, '$r $g $b');
          }
        }
      }
      expect(least, greaterThanOrEqualTo(lo), reason: leastAt);
      expect(most, lessThanOrEqualTo(hi), reason: mostAt);
    });
  }

  test('chatLight: adapted warning reads against the certified range', () {
    final chrome = HermesChrome.of(_classicLight);
    const glass = HermesSmokedGlass.chatLight;
    final (lo, _) = glass.underRange(chrome);
    final warning = glass.adaptedInks(_classicLight).warning;
    expect(
      (lo + 0.05) / (ThemeContrast.luminance(warning) + 0.05),
      greaterThanOrEqualTo(4.5),
    );
  });
}
