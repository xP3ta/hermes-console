// The "Style" of the app: Outline gives every theme the structure of the
// terminal looks (flat surfaces with a thin outline, capitals with tracking,
// no glass), Soft (Glass) is the look before it. Only the colours change from
// one theme to the next, and none of them loses legibility. The selector is
// gone from the app: the real store is fixed on Glass, whatever an older
// install saved; Outline stays reachable only from a test store.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/ambient_backdrop.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/hermes_style.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/theme_profile_fixtures.dart';

Future<void> _pump(
  WidgetTester tester,
  ThemeData theme,
  Widget child, {
  PreferredSizeWidget? appBar,
  Locale? locale,
  double textScale = 1,
  double width = 800,
}) => tester.pumpWidget(
  MaterialApp(
    theme: theme,
    locale: locale,
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    builder: (context, home) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        size: Size(width, 800),
        textScaler: TextScaler.linear(textScale),
      ),
      child: home!,
    ),
    home: Scaffold(
      appBar: appBar,
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  ),
);

ThemeData _contour(ThemeData theme) =>
    applyHermesStyle(theme, HermesStyle.contour);

void main() {
  tearDown(() {
    GlassLookPrefs.debugUse(null);
    HermesStylePrefs.debugUse(null);
  });

  final themes = <String, ThemeData>{
    for (final preset in AppTheme.presets)
      preset.id: AppTheme.fromId(preset.id),
    'custom': AppTheme.fromProfile(validCustomTheme()),
  };

  group('the setting', () {
    test('the real store is fixed on Glass and cannot be changed', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = await HermesStylePrefs.load(prefs);
      expect(store.style, HermesStyle.soft);
      expect(store.isContour, isFalse);
      expect(HermesStylePrefs.shared, same(store));
      var notified = 0;
      store.addListener(() => notified++);
      await store.setStyle(HermesStyle.contour);
      expect(store.style, HermesStyle.soft);
      expect(notified, 0);
      expect(prefs.getString(HermesStylePrefs.styleKey), isNull);
    });

    test('Outline saved by an older install does not count', () async {
      SharedPreferences.setMockInitialValues({
        HermesStylePrefs.styleKey: 'contour',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = await HermesStylePrefs.load(prefs);
      expect(store.style, HermesStyle.soft);
      expect(store.isContour, isFalse);
      final theme = AppTheme.fromId('console');
      expect(applyHermesStyle(theme, store.style), same(theme));
    });

    test('without a loaded store the shared one is Glass too', () {
      HermesStylePrefs.debugUse(null);
      expect(HermesStylePrefs.shared.style, HermesStyle.soft);
    });

    test('a test store can still hold Outline', () async {
      final store = HermesStylePrefs.inMemory(HermesStyle.contour);
      expect(store.isContour, isTrue);
      await store.setStyle(HermesStyle.soft);
      expect(store.style, HermesStyle.soft);
    });

    testWidgets('the scope hands the style to the tree and listens', (
      tester,
    ) async {
      final store = HermesStylePrefs.inMemory(HermesStyle.soft);
      HermesStyle? seen;
      await tester.pumpWidget(
        HermesStyleScope(
          prefs: store,
          child: Builder(
            builder: (context) {
              seen = HermesStyleScope.styleOf(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, HermesStyle.soft);
      await store.setStyle(HermesStyle.contour);
      await tester.pump();
      expect(seen, HermesStyle.contour);
    });
  });

  group('Outline on every theme', () {
    test('the flag of the terminal looks is on, and nothing else moves', () {
      expect(themes.length, 43); // 42 presets + a Theme Studio profile
      for (final MapEntry(key: id, value: theme) in themes.entries) {
        final out = _contour(theme);
        final a = theme.hermes;
        final b = out.hermes;
        expect(b.uppercaseTitles, isTrue, reason: id);
        expect(b.outlined, isTrue, reason: id);
        expect(a.outlined, isFalse, reason: id);
        for (final pair in [
          (a.background, b.background),
          (a.surface, b.surface),
          (a.surfaceVariant, b.surfaceVariant),
          (a.accent, b.accent),
          (a.accentText, b.accentText),
          (a.onAccent, b.onAccent),
          (a.textPrimary, b.textPrimary),
          (a.textSecondary, b.textSecondary),
          (a.textTertiary, b.textTertiary),
          (a.divider, b.divider),
          (a.secondary, b.secondary),
        ]) {
          expect(pair.$2, pair.$1, reason: id);
        }
        expect(
          out.hermesComponents.profile.id,
          theme.hermesComponents.profile.id,
          reason: id,
        );
        expect(
          out.textTheme.bodyMedium?.fontFamily,
          (theme.textTheme.bodyMedium?.fontFamily),
          reason: id,
        );
        // The other extensions travel along.
        expect(out.extensions.length, theme.extensions.length, reason: id);
      }
    });

    test('Soft returns the theme as it was', () {
      for (final theme in themes.values) {
        expect(applyHermesStyle(theme, HermesStyle.soft), same(theme));
      }
    });

    test('no theme wears glass in Outline, whatever the Glass level', () {
      for (final MapEntry(key: id, value: theme) in themes.entries) {
        for (final level in GlassLevel.values) {
          expect(
            GlassMaterial.resolve(_contour(theme).hermes, level),
            isNull,
            reason: '$id ${level.name}',
          );
        }
      }
    });

    test('the button gradient and the glow are off in Outline', () {
      final base = AppTheme.fromId('console');
      expect(
        hermesAmbientTheme(
          base,
          level: GlassLevel.full,
        ).filledButtonTheme.style?.backgroundBuilder,
        isNotNull,
      );
      expect(
        hermesAmbientTheme(
          _contour(base),
          level: GlassLevel.full,
        ).filledButtonTheme.style?.backgroundBuilder,
        isNull,
      );
    });

    test('text reads on every surface of every theme, as the palette tests '
        'ask (42 presets and a Studio theme)', () {
      final fails = <String>[];
      for (final MapEntry(key: id, value: theme) in themes.entries) {
        final c = _contour(theme).hermes;
        final surfaces = <String, Color>{
          'page': c.background,
          'group': ThemeContrast.composite(
            c.surfaceVariant.withValues(alpha: 0.3),
            c.background,
          ),
          'panel': ThemeContrast.composite(
            c.surfaceVariant.withValues(alpha: 0.42),
            c.background,
          ),
          'card': c.surface,
          'card-soft': ThemeContrast.composite(
            c.surface.withValues(alpha: HermesSoftLight.cardOpacity),
            c.background,
          ),
          'bubble': c.surfaceVariant,
        };
        // The dimmed ink is only asked on the surfaces a label sits on.
        for (final MapEntry(key: name, value: surface) in surfaces.entries) {
          final primary = ThemeContrast.ratio(c.textPrimary, surface);
          final secondary = ThemeContrast.ratio(c.textSecondary, surface);
          if (primary < 4.5) {
            fails.add('$id/$name primary ${primary.toStringAsFixed(2)}');
          }
          // The same bar the palette test sets for the dimmed ink.
          if (name != 'bubble' && secondary < 3.0) {
            fails.add('$id/$name secondary ${secondary.toStringAsFixed(2)}');
          }
        }
      }
      expect(fails, isEmpty, reason: fails.join('\n'));
    });
  });

  group('what Outline looks like', () {
    testWidgets('a group and a card are flat with the glass level on full', (
      tester,
    ) async {
      GlassLookPrefs.debugUse(GlassLookPrefs.inMemory(GlassLevel.full));
      final theme = _contour(AppTheme.fromId('console'));
      await _pump(
        tester,
        theme,
        const Column(
          children: [
            HermesGroup(children: [SizedBox(height: 40)]),
            HermesCard(child: SizedBox(height: 40, width: 100)),
          ],
        ),
      );
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
      final group = of(HermesGroup);
      expect(group.color, theme.hermes.surfaceVariant.withValues(alpha: 0.3));
      expect(group.gradient, isNull);
      final card = of(HermesCard);
      expect(card.color, theme.hermes.surface);
      expect(card.gradient, isNull);
      expect(card.border, isNotNull);
    });

    testWidgets('Soft keeps the glass the level asks for', (tester) async {
      GlassLookPrefs.debugUse(GlassLookPrefs.inMemory(GlassLevel.full));
      final theme = applyHermesStyle(
        AppTheme.fromId('console'),
        HermesStyle.soft,
      );
      await _pump(
        tester,
        theme,
        const HermesGroup(children: [SizedBox(height: 40)]),
      );
      final decoration =
          tester
                  .widget<Container>(
                    find
                        .descendant(
                          of: find.byType(HermesGroup),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration!
              as BoxDecoration;
      expect(
        decoration.color,
        GlassMaterial.resolve(theme.hermes, GlassLevel.full)!.groupFill,
      );
    });

    testWidgets('titles and section labels are capitals (tracked labels), the '
        'reader keeps the name', (tester) async {
      await _pump(
        tester,
        _contour(AppTheme.fromId('console')),
        const HermesSectionHeader('Aspecto'),
        appBar: const HermesAppBar(title: Text('Ajustes')),
      );
      expect(find.text('ASPECTO'), findsOneWidget);
      expect(find.text('AJUSTES'), findsOneWidget);
      expect(find.text('Aspecto'), findsNothing);
      final label = tester.widget<Text>(find.text('ASPECTO'));
      expect(label.style!.letterSpacing, greaterThan(0));
      expect(label.semanticsLabel, 'Aspecto');
      expect(
        tester.getSemantics(find.text('ASPECTO')).label,
        contains('Aspecto'),
      );
    });

    testWidgets('Soft leaves titles as written', (tester) async {
      await _pump(
        tester,
        AppTheme.fromId('console'),
        const HermesSectionHeader('Aspecto'),
        appBar: const HermesAppBar(title: Text('Ajustes')),
      );
      expect(find.text('Aspecto'), findsOneWidget);
      expect(find.text('Ajustes'), findsOneWidget);
    });
  });

  group('capitals do not overflow with large text', () {
    for (final code in ['es', 'de', 'fr']) {
      testWidgets('$code at scale 2.0 on the cover width, plain and pill', (
        tester,
      ) async {
        late Strings s;
        await _pump(
          tester,
          _contour(AppTheme.fromId('console')),
          Builder(
            builder: (context) {
              s = Strings.of(context);
              return const SizedBox();
            },
          ),
          locale: Locale(code),
          textScale: 2,
          width: 344,
        );
        final titles = [s.setSecAppearance, s.themesTitle, s.themesEmptyCustom];
        for (final pill in [false, true]) {
          for (final title in titles) {
            await _pump(
              tester,
              _contour(AppTheme.fromId('console')),
              ListView(
                children: [
                  HermesSectionHeader(title),
                  const HermesGroup(children: [SizedBox(height: 40)]),
                ],
              ),
              appBar: HermesAppBar(
                title: Text(title),
                titleInPill: pill,
                actions: [
                  IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
                ],
              ),
              locale: Locale(code),
              textScale: 2,
              width: 344,
            );
            expect(
              tester.takeException(),
              isNull,
              reason: '$code pill=$pill "$title"',
            );
          }
        }
      });
    }
  });
}
