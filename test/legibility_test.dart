import 'package:hermes_android/core/home/launcher/launcher_widget_palette.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_geometry.dart';
// Legibility of the content boxes (cards, groups, panels, list sections and
// their rows, the search field, the notices): a SOLID body a visible step
// from the page, text inks that read on it in every theme, and sizes no
// smaller than the floor. The numbers come from the probe that prints the
// measurement table (support/legibility_probe.dart).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/ambient_backdrop.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/home/board/home_board_kit.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/box_fill.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/hermes_style.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/legibility_probe.dart';

Widget _host(
  ThemeData theme,
  Widget child, {
  double textScale = 1,
  bool highContrast = false,
  double width = 360,
}) => MaterialApp(
  theme: theme,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      highContrast: highContrast,
    ),
    child: home!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  ),
);

void main() {
  setUp(() {
    GlassLookPrefs.debugUse(GlassLookPrefs.inMemory(GlassLevel.full));
    HermesStylePrefs.debugUse(HermesStylePrefs.inMemory());
  });
  tearDown(() {
    GlassLookPrefs.debugUse(null);
    HermesStylePrefs.debugUse(null);
  });

  group('text inks on the body of the boxes, 42 presets', () {
    test('every ink reads AA (4.5:1) on every surface; the main and the '
        'secondary ink reach 7:1; the tertiary 5.5:1', () {
      expect(AppTheme.presets.length, 42);
      final floors = <String, double>{
        'textPrimary': 7,
        'textSecondary': 7,
        'textTertiary': 5.5,
        'hint': 7,
        'sectionCaption': 7,
        'soft.text': 7,
        'soft.textMuted': 7,
        'home.faint': 5.5,
      };
      final fails = <String>[];
      for (final c in measureLegibility()) {
        final floor = floors[c.ink]!;
        if (c.ratio + 1e-9 < 4.5) fails.add('AA $c');
        if (c.ratio + 1e-9 < floor) fails.add('floor $floor $c');
      }
      expect(fails, isEmpty, reason: fails.join('\n'));
    });

    test('the inks are a hierarchy: the main one above the secondary, the '
        'secondary above the tertiary, on the card', () {
      final fails = <String>[];
      for (final preset in AppTheme.presets) {
        final c = preset.colors;
        final card = HermesBoxFill.of(c).card;
        double r(Color ink) => ThemeContrast.ratio(ink, card);
        if (r(c.textSecondary) >= r(c.textPrimary) + 1e-9) {
          fails.add('${preset.id} secondary >= primary');
        }
        if (r(c.textTertiary) >= r(c.textSecondary) + 1e-9) {
          fails.add('${preset.id} tertiary >= secondary');
        }
      }
      expect(fails, isEmpty, reason: fails.join('\n'));
    });

    test('a custom theme of the Studio gets readable inks too', () {
      final theme = AppTheme.fromId('console');
      final fills = HermesBoxFill.of(theme.hermes);
      for (final fill in [fills.group, fills.card]) {
        expect(
          ThemeContrast.ratio(theme.hermes.textSecondary, fill),
          greaterThanOrEqualTo(7),
        );
      }
    });

    test(
      'withReadableInk is idempotent and leaves a readable palette alone',
      () {
        for (final preset in AppTheme.presets) {
          final once = preset.colors;
          final twice = once.withReadableInk();
          expect(twice.textPrimary, once.textPrimary, reason: preset.id);
          expect(twice.textSecondary, once.textSecondary, reason: preset.id);
          expect(twice.textTertiary, once.textTertiary, reason: preset.id);
        }
      },
    );

    test('every preset still wears the full glass (none dropped a level)', () {
      for (final preset in AppTheme.presets) {
        final material = GlassMaterial.resolve(preset.colors, GlassLevel.full);
        expect(material, isNotNull, reason: preset.id);
        expect(material!.level, GlassLevel.full, reason: preset.id);
      }
    });
  });

  group('the body of the boxes', () {
    test('solid, and a visible step from the page: dark 1.25:1 against the '
        'page, 1.15:1 against its glow; light lighter than the page', () {
      final fails = <String>[];
      var darks = 0;
      var lights = 0;
      for (final preset in AppTheme.presets) {
        final glass = GlassMaterial.resolve(preset.colors, GlassLevel.full)!;
        final id = preset.id;
        for (final (name, fill) in [
          ('group', glass.groupFill),
          ('card', glass.cardFill),
        ]) {
          if (fill.a != 1) fails.add('$id $name translucent');
          final page = ThemeContrast.ratio(fill, glass.page);
          final glow = ThemeContrast.ratio(fill, glass.glow);
          if (glass.dark) {
            if (page < 1.25) {
              fails.add('$id $name page ${page.toStringAsFixed(3)}');
            }
            if (glow < 1.15) {
              fails.add('$id $name glow ${glow.toStringAsFixed(3)}');
            }
          } else {
            final lift =
                ThemeContrast.luminance(fill) -
                ThemeContrast.luminance(glass.page);
            if (lift < -1e-9) fails.add('$id $name darker than the page');
          }
        }
        // The card is a step apart from the group.
        if (glass.cardFill == glass.groupFill) fails.add('$id card == group');
        glass.dark ? darks++ : lights++;
      }
      expect(darks, greaterThan(10));
      expect(lights, greaterThan(10));
      expect(fails, isEmpty, reason: fails.join('\n'));
    });

    test(
      'the fallback body is the glass body: same colours, from the page',
      () {
        for (final preset in AppTheme.presets) {
          final glass = GlassMaterial.resolve(preset.colors, GlassLevel.full)!;
          final fill = HermesBoxFill.of(preset.colors);
          expect(glass.groupFill, fill.group, reason: preset.id);
          expect(glass.cardFill, fill.card, reason: preset.id);
        }
      },
    );

    test('the small glass pieces keep their translucent body in dark', () {
      for (final preset in AppTheme.presets) {
        final glass = GlassMaterial.resolve(preset.colors, GlassLevel.full)!;
        if (glass.dark) {
          expect(glass.pieceFill.a, lessThan(0.15), reason: preset.id);
        } else {
          expect(glass.pieceFill, glass.groupFill, reason: preset.id);
        }
      }
    });

    for (final id in ['console', 'console-light', 'nous-dark', 'nous']) {
      final dark = id.contains('dark') || id == 'console';
      testWidgets('$id: the boxes paint the solid body and no blur anywhere', (
        tester,
      ) async {
        final theme = AppTheme.fromId(id);
        await tester.pumpWidget(
          _host(
            theme,
            const Column(
              children: [
                HermesGroup(children: [SizedBox(height: 30)]),
                HermesPanel(child: SizedBox(height: 30)),
                HermesCard(child: SizedBox(height: 30, width: 100)),
                HermesListSection(
                  title: 'Section',
                  children: [SizedBox(height: 30)],
                ),
                HermesInfoBanner('Notice'),
                HermesSearchField(hintText: 'Search', clearTooltip: 'Clear'),
              ],
            ),
          ),
        );
        expect(find.byType(BackdropFilter), findsNothing);
        final fill = HermesBoxFill.of(theme.hermes);
        BoxDecoration of(Type owner) =>
            tester
                    .widget<Container>(
                      find
                          .descendant(
                            of: find.byType(owner),
                            matching: find.byType(Container),
                          )
                          .first,
                    )
                    .decoration!
                as BoxDecoration;
        expect(of(HermesGroup).color, fill.group);
        expect(of(HermesPanel).color, fill.group);
        expect(of(HermesCard).color, fill.card);
        for (final owner in [HermesGroup, HermesPanel, HermesCard]) {
          expect(of(owner).color!.a, 1);
          if (dark) {
            expect(
              ThemeContrast.ratio(
                of(owner).color!,
                ThemeContrast.composite(
                  theme.hermes.background,
                  const Color(0xFF000000),
                ),
              ),
              greaterThanOrEqualTo(1.25),
            );
          }
        }
      });
    }

    testWidgets('no glass (high contrast): the same solid bodies, and the '
        'ink still reads on them', (tester) async {
      for (final id in ['console', 'console-light']) {
        final theme = AppTheme.fromId(id);
        await tester.pumpWidget(
          _host(
            theme,
            const Column(
              children: [
                HermesGroup(children: [SizedBox(height: 30)]),
                HermesCard(child: SizedBox(height: 30, width: 100)),
              ],
            ),
            highContrast: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(BackdropFilter), findsNothing);
        final fill = HermesBoxFill.of(theme.hermes);
        BoxDecoration of(Type owner) =>
            tester
                    .widget<Container>(
                      find
                          .descendant(
                            of: find.byType(owner),
                            matching: find.byType(Container),
                          )
                          .first,
                    )
                    .decoration!
                as BoxDecoration;
        expect(of(HermesGroup).color, fill.group, reason: id);
        expect(of(HermesCard).color, fill.card, reason: id);
        for (final body in [fill.group, fill.card]) {
          expect(
            ThemeContrast.ratio(theme.hermes.textSecondary, body),
            greaterThanOrEqualTo(7),
            reason: id,
          );
        }
      }
    });
  });

  group('sizes', () {
    test('the floor of the content boxes', () {
      expect(HermesType.sectionSize, greaterThanOrEqualTo(12));
      expect(HermesType.subtitleSize, greaterThanOrEqualTo(13));
      expect(HermesType.hintSize, greaterThanOrEqualTo(14));
      expect(HermesType.sectionTracking, lessThanOrEqualTo(0.6));
    });

    testWidgets('the label of a section: 12 or more, w600, a moderate '
        'tracking, in the glass and in the capitals look', (tester) async {
      for (final id in ['console', 'cyberpunk']) {
        await tester.pumpWidget(
          _host(
            AppTheme.fromId(id),
            const HermesListSection(
              title: 'Section',
              children: [SizedBox(height: 30)],
            ),
          ),
        );
        await tester.pumpAndSettle();
        final text = tester.widget<Text>(
          find.byWidgetPredicate(
            (w) =>
                w is Text &&
                w.data != null &&
                w.data!.toLowerCase() == 'section',
          ),
        );
        expect(text.style!.fontSize, greaterThanOrEqualTo(12), reason: id);
        expect(text.style!.fontWeight, FontWeight.w600, reason: id);
        expect(text.style!.letterSpacing, lessThanOrEqualTo(1.2), reason: id);
      }
    });

    testWidgets('subtitles are 13 or more and the placeholder 14', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AppTheme.fromId('console'),
          Column(
            children: [
              HermesSwitchTile(
                title: 'Title',
                subtitle: 'Switch subtitle',
                value: true,
                onChanged: (_) {},
              ),
              HermesNavRow(
                icon: Icons.settings,
                title: 'Nav title',
                subtitle: 'Nav subtitle',
                value: 'Value',
                onTap: () {},
              ),
              const HermesInfoBanner('Notice text'),
              const HermesSearchField(
                hintText: 'Search tools',
                clearTooltip: 'Clear',
              ),
            ],
          ),
        ),
      );
      double size(String text) =>
          tester.widget<Text>(find.text(text)).style!.fontSize!;
      expect(size('Switch subtitle'), greaterThanOrEqualTo(13));
      expect(size('Nav subtitle'), greaterThanOrEqualTo(13));
      expect(size('Notice text'), greaterThanOrEqualTo(13));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.hintStyle!.fontSize, greaterThanOrEqualTo(14));
    });

    test('the Home widgets use launcher labels and quiet text roles', () {
      final p = HomePalette(
        LauncherWidgetPalette.of(
          AppTheme.fromId('console').hermes,
          fontFamily: 'Inter',
        ),
      );
      for (final style in [HomeType.cap(p), HomeType.section(p)]) {
        expect(style.fontSize, greaterThanOrEqualTo(12));
        expect(style.fontWeight, FontWeight.w500);
        expect(style.letterSpacing, lessThanOrEqualTo(0.8));
      }
      expect(HomeType.meta(p).fontSize, LwGrid.rowLine);
      expect(HomeType.when(p).fontSize, LwGrid.caption);
      expect(HomeType.faint(p).a, 1, reason: 'never a faded copy');
    });

    for (final id in ['console', 'console-light']) {
      testWidgets('$id: text at 2x does not overflow the boxes', (
        tester,
      ) async {
        await tester.pumpWidget(
          _host(
            AppTheme.fromId(id),
            Column(
              children: [
                HermesListSection(
                  title: 'A long section title that has to wrap somewhere',
                  children: [
                    HermesNavRow(
                      icon: Icons.settings,
                      title: 'A navigation row with a long title',
                      subtitle: 'And a subtitle that runs to a second line',
                      value: 'Value',
                      onTap: () {},
                    ),
                  ],
                ),
                HermesSwitchTile(
                  title: 'A switch with a long title',
                  subtitle: 'The subtitle of the switch, long as well',
                  value: true,
                  onChanged: (_) {},
                ),
                const HermesGroup(
                  children: [HermesInfoBanner('A notice with some words')],
                ),
                const HermesSearchField(
                  hintText: 'Search the tools here',
                  clearTooltip: 'Clear',
                ),
              ],
            ),
            textScale: 2,
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the glass stays where it was', () {
    testWidgets('no BackdropFilter was added to the boxes of a screen of '
        'rows', (tester) async {
      await tester.pumpWidget(
        _host(
          AppTheme.fromId('console'),
          Column(
            children: [
              for (var i = 0; i < 6; i++)
                const HermesCard(child: SizedBox(height: 24)),
            ],
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(
        HermesGlassLook.of(tester.element(find.byType(HermesCard).first)),
        isNotNull,
      );
    });
  });
}
