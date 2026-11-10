// The glass of text-heavy panels (the side drawer): HermesGlassPanel and the
// smoked tone of HermesSmokedGlass.panelOf. The tone is certified per theme
// with the same machinery as the chat's foot; a theme whose inks do not read
// keeps the opaque surface of before.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/smoked_glass.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';

const _shape = RoundedRectangleBorder(
  borderRadius: BorderRadius.horizontal(right: Radius.circular(22)),
);
const _fallback = Color(0xFF123456);

List<(Color, Color)> _overs(HermesThemeColors colors) {
  final tint = colors.surfaceVariant.withValues(alpha: 0.58);
  return [(colors.textPrimary, tint), (colors.accentHover, tint)];
}

Widget _app(
  ThemeData theme,
  List<(Color, bool)> seen, {
  MediaQueryData? media,
}) {
  Widget panel = HermesGlassPanel(
    shape: _shape,
    fallbackFill: _fallback,
    overs: _overs(theme.hermes),
    builder: (context, fill, glass) {
      seen.add((fill, glass));
      return SizedBox(width: 200, height: 300, child: ColoredBox(color: fill));
    },
  );
  if (media != null) panel = MediaQuery(data: media, child: panel);
  return MaterialApp(
    theme: theme,
    home: Scaffold(
      body: Stack(
        children: [
          ListView(
            children: [
              for (var i = 0; i < 30; i++) ListTile(title: Text('Fila $i')),
            ],
          ),
          Positioned(left: 0, top: 0, child: panel),
        ],
      ),
    ),
  );
}

int _filters(WidgetTester tester) =>
    tester.layers.whereType<BackdropFilterLayer>().length;

void main() {
  tearDown(() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
  });

  test('every preset: the panel tone reads, or the theme is listed as '
      'opaque', () {
    final opaque = <String>[];
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      final chrome = HermesChrome.of(colors);
      final tone = HermesSmokedGlass.panelOf(chrome);
      final reads = HermesGlassPanel.reads(colors, overs: _overs(colors));
      // The check is the strip's own: what it accepts, every ink keeps its
      // floor over the whole range under the glass.
      if (reads) {
        for (final ink in HermesSmokedGlass.panelInks(colors)) {
          expect(tone.readsFor(colors, [ink]), isTrue, reason: preset.id);
        }
      } else {
        opaque.add(preset.id);
      }
    }
    // ignore: avoid_print
    print('PANEL-OPAQUE ${opaque.length}/${AppTheme.presets.length}: $opaque');
    // Indigo glass carries the mock-up's #5B6CFF accent verbatim: as an ink
    // it is 4.4:1 on the opaque chrome and cannot reach the 4.5:1 floor over
    // the darkest part of the smoked glass, so its panels keep the opaque
    // surface (the documented fallback) in both modes. They are counted
    // apart so the budget below keeps meaning "the other presets".
    const mockupPalettes = {'indigo-glass', 'indigo-glass-light'};
    final others = opaque.where((id) => !mockupPalettes.contains(id)).toList();
    // The dark tone reads on every other dark preset (swept, 20/20).
    for (final preset in AppTheme.presets) {
      if (preset.isDark && !mockupPalettes.contains(preset.id)) {
        expect(opaque, isNot(contains(preset.id)));
      }
    }
    // And on most light ones; those that do not keep the opaque surface.
    expect(opaque, isNot(contains('classic')));
    expect(others.length, lessThanOrEqualTo(6));
  });

  test('the panel veil is heavier than the chat foot\'s, in both tones', () {
    expect(
      HermesSmokedGlass.panelDark.veil,
      greaterThan(HermesSmokedGlass.chatDark.veil),
    );
    expect(
      HermesSmokedGlass.panelLight.veil,
      greaterThan(HermesSmokedGlass.chatLight.veil),
    );
    expect(HermesSmokedGlass.panelDark.luminance, lessThanOrEqualTo(0.15));
    expect(HermesSmokedGlass.panelDark.chroma, lessThanOrEqualTo(0.5));
  });

  testWidgets('frosting: the fill is the tone\'s veil and ONE filter runs', (
    tester,
  ) async {
    final seen = <(Color, bool)>[];
    final theme = AppTheme.fromId('classic-dark');
    await tester.pumpWidget(_app(theme, seen));
    await tester.pump();
    final chrome = HermesChrome.of(theme.hermes);
    final tone = HermesSmokedGlass.panelOf(chrome);
    expect(seen.last.$2, isTrue);
    expect(seen.last.$1, tone.veilOf(chrome));
    expect(_filters(tester), 1);
  });

  testWidgets('without blur (the device says no) the opaque fallback', (
    tester,
  ) async {
    FrostedBackdropPolicy.blurAllowed.value = false;
    final seen = <(Color, bool)>[];
    await tester.pumpWidget(_app(AppTheme.fromId('classic'), seen));
    await tester.pump();
    expect(seen.last, (_fallback, false));
    expect(_filters(tester), 0);
  });

  testWidgets('high contrast: the opaque fallback', (tester) async {
    final seen = <(Color, bool)>[];
    await tester.pumpWidget(
      _app(
        AppTheme.fromId('classic-dark'),
        seen,
        media: const MediaQueryData(highContrast: true),
      ),
    );
    await tester.pump();
    expect(seen.last, (_fallback, false));
  });

  testWidgets('a theme whose ink sits inside the range keeps the opaque '
      'surface', (tester) async {
    // An ink just below the chrome lands inside the luminance band under the
    // glass: it can meet a page that matches it (1:1), worse than on the
    // opaque chrome, so the tone must refuse.
    final base = AppTheme.fromId('classic-dark');
    final chrome = HermesChrome.of(base.hermes);
    final colors = base.hermes.copyWith(
      textPrimary: Color.lerp(chrome.opaque, const Color(0xFF000000), 0.15),
    );
    expect(HermesGlassPanel.reads(colors), isFalse);
    final seen = <(Color, bool)>[];
    await tester.pumpWidget(_app(base.copyWith(extensions: [colors]), seen));
    await tester.pump();
    expect(seen.last, (_fallback, false));
    expect(_filters(tester), 0);
  });
}
