// The Look & Feel screen: what is shown, that every choice applies at once,
// «Más temas» and its isolation, accessibility, large text in the nine
// languages and that the free colour picker does not repaint the app while
// it is dragged.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/bot_motion.dart';
import 'package:hermes_android/core/screens/look_feel_screen.dart';
import 'package:hermes_android/core/screens/themes_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/look_feel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tall = Size(400, 2600);

Future<LookFeelPrefs> _prefs([Map<String, Object> values = const {}]) async {
  SharedPreferences.setMockInitialValues(values);
  return LookFeelPrefs(await SharedPreferences.getInstance());
}

/// The app around the screen, themed the way `main.dart` themes it: from the
/// Look & Feel preferences when they are in force.
class _App extends StatelessWidget {
  const _App({
    required this.prefs,
    required this.font,
    required this.fontLog,
    required this.builds,
    this.locale = const Locale('en'),
    this.textScale = 1,
  });

  final LookFeelPrefs prefs;
  final ValueNotifier<String> font;
  final List<String> fontLog;
  final List<int> builds;
  final Locale locale;
  final double textScale;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: prefs,
    builder: (context, _) {
      builds.add(builds.length);
      final themes = prefs.settings.derived
          ? LookFeel.materialThemes(prefs.settings)
          : (theme: AppTheme.fromId('console'), darkTheme: null);
      return MaterialApp(
        locale: locale,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: themes.theme,
        darkTheme: themes.darkTheme,
        themeAnimationDuration: Duration.zero,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: LookFeelScreen(
          prefsForTesting: prefs,
          fontIdForTesting: font,
          onFontForTesting: (id) async {
            fontLog.add(id);
            font.value = id;
          },
        ),
      );
    },
  );
}

Future<
  ({
    LookFeelPrefs prefs,
    ValueNotifier<String> font,
    List<String> fontLog,
    List<int> builds,
  })
>
_pump(
  WidgetTester tester, {
  Map<String, Object> values = const {},
  Locale locale = const Locale('en'),
  double textScale = 1,
  Size size = _tall,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final prefs = await _prefs(values);
  final font = ValueNotifier<String>('system');
  addTearDown(font.dispose);
  final fontLog = <String>[];
  final builds = <int>[];
  await tester.pumpWidget(
    _App(
      prefs: prefs,
      font: font,
      fontLog: fontLog,
      builds: builds,
      locale: locale,
      textScale: textScale,
    ),
  );
  await tester.pump();
  return (prefs: prefs, font: font, fontLog: fontLog, builds: builds);
}

Brightness _brightness(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(LookFeelScreen))).brightness;

Finder _check(Key owner) => find.descendant(
  of: find.byKey(owner),
  matching: find.byIcon(Icons.check_rounded),
);

const _accentIds = [
  'terracotta',
  'orange',
  'rose',
  'violet',
  'indigo',
  'blue',
  'teal',
  'green',
  'slate',
  'custom',
];

const _lightKeys = [ValueKey('lfl-light-white'), ValueKey('lfl-light-paper')];
const _darkKeys = [
  ValueKey('lfl-dark-midnight'),
  ValueKey('lfl-dark-black'),
  ValueKey('lfl-dark-gray'),
];

/// Only the background section of [brightness] is on the screen.
void _expectBackgroundsOf(Brightness brightness) {
  final light = brightness == Brightness.light;
  expect(find.text('Light background'), light ? findsOneWidget : findsNothing);
  expect(find.text('Dark background'), light ? findsNothing : findsOneWidget);
  for (final key in _lightKeys) {
    expect(find.byKey(key), light ? findsOneWidget : findsNothing);
  }
  for (final key in _darkKeys) {
    expect(find.byKey(key), light ? findsNothing : findsOneWidget);
  }
}

void main() {
  testWidgets(
    'shows Appearance, ten accents and the backgrounds of the brightness in '
    'view (light, as the system is in tests)',
    (tester) async {
      await _pump(tester);

      for (final text in [
        'Look & Feel',
        'Appearance',
        'Accent',
        'Light background',
        'Font',
        'More themes',
        'System',
        'Light',
        'Dark',
        'White',
        'Paper',
        'Animate bots',
      ]) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      for (final id in _accentIds) {
        expect(find.byKey(ValueKey('lfl-accent-$id')), findsOneWidget);
      }
      _expectBackgroundsOf(Brightness.light);
      expect(
        find.text('42 complete themes, each with its own style'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  group('one background section: the brightness in view', () {
    testWidgets('Appearance Light: only the light background', (tester) async {
      await _pump(
        tester,
        values: {'lfl_source': 'derived', 'lfl_appearance': 'light'},
      );
      _expectBackgroundsOf(Brightness.light);
    });

    testWidgets('Appearance Dark: only the dark background', (tester) async {
      await _pump(
        tester,
        values: {'lfl_source': 'derived', 'lfl_appearance': 'dark'},
      );
      _expectBackgroundsOf(Brightness.dark);
      for (final text in ['Midnight', 'Black', 'Gray']) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
    });

    for (final platform in Brightness.values) {
      testWidgets('Appearance System, system ${platform.name}: that one', (
        tester,
      ) async {
        tester.platformDispatcher.platformBrightnessTestValue = platform;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await _pump(
          tester,
          values: {'lfl_source': 'derived', 'lfl_appearance': 'system'},
        );
        expect(_brightness(tester), platform);
        _expectBackgroundsOf(platform);
      });
    }

    testWidgets('System: a change of the system brightness moves the screen', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final h = await _pump(
        tester,
        values: {
          'lfl_source': 'derived',
          'lfl_appearance': 'system',
          'lfl_dark_background': 'midnight',
        },
      );
      _expectBackgroundsOf(Brightness.light);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      await tester.pump();
      expect(_brightness(tester), Brightness.dark);
      _expectBackgroundsOf(Brightness.dark);
      // The stored dark choice is the one shown; nothing was rewritten.
      expect(_check(const ValueKey('lfl-dark-midnight')), findsOneWidget);
      expect(h.prefs.settings.darkBackground, LookDarkBackground.midnight);
      expect(h.prefs.settings.lightBackground, LookLightBackground.paper);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pump();
      await tester.pump();
      _expectBackgroundsOf(Brightness.light);
      expect(_check(const ValueKey('lfl-light-paper')), findsOneWidget);
    });

    testWidgets('the appearance in force decides, not the theme of the list', (
      tester,
    ) async {
      // A dark theme of the list is in force while the appearance says
      // Light: the light background is the one offered (it is what Look &
      // Feel would paint on the way back).
      await _pump(
        tester,
        values: {
          'lfl_source': 'list',
          'lfl_appearance': 'light',
          'active_theme_profile_id': 'console',
        },
      );
      expect(find.byKey(const ValueKey('lfl-list-banner')), findsOneWidget);
      _expectBackgroundsOf(Brightness.light);
    });

    testWidgets('switching the appearance swaps the section at once', (
      tester,
    ) async {
      await _pump(
        tester,
        values: {'lfl_source': 'derived', 'lfl_appearance': 'light'},
      );
      _expectBackgroundsOf(Brightness.light);
      await tester.tap(find.byKey(const ValueKey('lfl-appearance-dark')));
      await tester.pump();
      _expectBackgroundsOf(Brightness.dark);
      await tester.tap(find.byKey(const ValueKey('lfl-appearance-light')));
      await tester.pump();
      _expectBackgroundsOf(Brightness.light);
    });
  });

  testWidgets('a theme of the list shows «Theme: X» and a way back', (
    tester,
  ) async {
    final h = await _pump(tester);

    expect(h.prefs.settings.derived, isFalse);
    expect(find.text('Theme: Console'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lfl-return')));
    await tester.pump();

    expect(h.prefs.settings.derived, isTrue);
    expect(find.byKey(const ValueKey('lfl-list-banner')), findsNothing);
  });

  testWidgets('Appearance applies at once and puts Look & Feel in force', (
    tester,
  ) async {
    final h = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('lfl-appearance-dark')));
    await tester.pump();
    expect(h.prefs.settings.appearance, LookAppearance.dark);
    expect(h.prefs.settings.derived, isTrue);
    expect(_brightness(tester), Brightness.dark);
    expect(find.byKey(const ValueKey('lfl-list-banner')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('lfl-appearance-light')));
    await tester.pump();
    expect(_brightness(tester), Brightness.light);
    // «Sistema» follows the platform (light in tests).
    await tester.tap(find.byKey(const ValueKey('lfl-appearance-system')));
    await tester.pump();
    expect(h.prefs.settings.appearance, LookAppearance.system);
    expect(_brightness(tester), Brightness.light);
  });

  testWidgets(
    'the accent applies at once and the active circle has the check',
    (tester) async {
      final h = await _pump(
        tester,
        values: {'lfl_source': 'derived', 'lfl_appearance': 'dark'},
      );
      expect(_check(const ValueKey('lfl-accent-terracotta')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('lfl-accent-blue')));
      await tester.pump();

      expect(h.prefs.settings.accentId, 'blue');
      expect(_check(const ValueKey('lfl-accent-blue')), findsOneWidget);
      expect(_check(const ValueKey('lfl-accent-terracotta')), findsNothing);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(
        app.theme!.hermes.accent,
        LookFeel.preset(h.prefs.settings, Brightness.dark).colors.accent,
      );
      expect(
        LookFeel.colors(h.prefs.settings, Brightness.dark).accent,
        isNot(
          LookFeel.colors(const LookFeelSettings(), Brightness.dark).accent,
        ),
      );
    },
  );

  testWidgets('backgrounds: swatch cards with check, applied at once', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      values: {'lfl_source': 'derived', 'lfl_appearance': 'dark'},
    );
    expect(_check(const ValueKey('lfl-dark-gray')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lfl-dark-midnight')));
    await tester.pump();
    expect(h.prefs.settings.darkBackground, LookDarkBackground.midnight);
    expect(_check(const ValueKey('lfl-dark-midnight')), findsOneWidget);
    expect(_check(const ValueKey('lfl-dark-gray')), findsNothing);
    expect(
      tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .theme!
          .hermes
          .background,
      LookFeel.darkSwatch(LookDarkBackground.midnight).$1,
    );

    // The light backgrounds are offered when the light appearance is in
    // view; the dark choice just made stays stored meanwhile.
    await tester.tap(find.byKey(const ValueKey('lfl-appearance-light')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lfl-light-white')));
    await tester.pump();
    expect(h.prefs.settings.lightBackground, LookLightBackground.white);
    expect(h.prefs.settings.darkBackground, LookDarkBackground.midnight);
    expect(_check(const ValueKey('lfl-light-white')), findsOneWidget);
    expect(_check(const ValueKey('lfl-light-paper')), findsNothing);
  });

  testWidgets('font: previews in their own face with a description', (
    tester,
  ) async {
    final h = await _pump(tester);

    expect(
      tester.widget<Text>(find.text('Nunito')).style?.fontFamily,
      'Nunito',
    );
    expect(tester.widget<Text>(find.text('Inter')).style?.fontFamily, 'Inter');
    expect(
      find.text('A rounded sans-serif, friendly and very legible.'),
      findsOneWidget,
    );
    expect(_check(const ValueKey('lfl-font-system')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lfl-font-nunito')));
    await tester.pump();
    expect(h.fontLog, ['nunito']);
    expect(_check(const ValueKey('lfl-font-nunito')), findsOneWidget);
    expect(_check(const ValueKey('lfl-font-system')), findsNothing);
  });

  testWidgets('Animate bots reuses the existing preference', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final raw = await SharedPreferences.getInstance();
    final bots = await BotMotionPrefs.load(raw);
    addTearDown(() => BotMotionPrefs.debugUse(null));
    await _pump(tester);

    expect(bots.animate, isTrue);
    await tester.tap(find.byKey(const ValueKey('lfl-animate-bots')));
    await tester.pump();
    expect(bots.animate, isFalse);
    expect(raw.getBool(BotMotionPrefs.key), isFalse);
  });

  group('free colour', () {
    testWidgets('dragging the picker does not repaint the app; OK applies', (
      tester,
    ) async {
      final h = await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('lfl-return')));
      await tester.pump();
      var notified = 0;
      h.prefs.addListener(() => notified++);
      final buildsBefore = h.builds.length;

      await tester.tap(find.byKey(const ValueKey('lfl-accent-custom')));
      await tester.pumpAndSettle();
      expect(find.text('Accent colour'), findsOneWidget);

      // Drag across the spectrum: many preview frames, none reaches the app.
      final spectrum = find.byKey(const Key('theme_color_spectrum'));
      final gesture = await tester.startGesture(tester.getCenter(spectrum));
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(6, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
      expect(notified, 0);
      expect(h.builds.length, buildsBefore);
      expect(h.prefs.settings.accentId, isNot(lookAccentCustomId));

      await tester.enterText(
        find.byKey(const Key('theme_color_hex')),
        '#336699',
      );
      await tester.tap(find.byKey(const Key('theme_color_confirm')));
      await tester.pumpAndSettle();

      expect(notified, 1);
      expect(h.prefs.settings.accentId, lookAccentCustomId);
      expect(h.prefs.settings.customAccent, const Color(0xFF336699));
      expect(_check(const ValueKey('lfl-accent-custom')), findsOneWidget);
    });

    testWidgets('cancelling the picker changes nothing', (tester) async {
      final h = await _pump(tester);
      final before = h.prefs.settings;
      await tester.tap(find.byKey(const ValueKey('lfl-accent-custom')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.prefs.settings, before);
    });
  });

  testWidgets('«Más temas» opens the list and coming back changes nothing', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      values: {
        'lfl_source': 'derived',
        'lfl_appearance': 'dark',
        'lfl_accent': 'violet',
      },
    );
    final before = h.prefs.settings;

    await tester.tap(find.byKey(const ValueKey('lfl-more-themes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ThemesScreen), findsOneWidget);
    // Look & Feel is the one in force: the list says so and shows no check.
    expect(h.prefs.settings, before);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LookFeelScreen), findsOneWidget);
    expect(h.prefs.settings, before);
    expect(find.byKey(const ValueKey('lfl-list-banner')), findsNothing);
  });

  testWidgets('choosing a list theme and coming back keeps the choices', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      values: {'lfl_source': 'derived', 'lfl_accent': 'rose'},
    );
    // What «Más temas» does when a theme is chosen (HermesAppState.setThemeId).
    await h.prefs.useList();
    await tester.pump();
    expect(find.text('Theme: Console'), findsOneWidget);
    expect(h.prefs.settings.accentId, 'rose');

    await tester.tap(find.byKey(const ValueKey('lfl-return')));
    await tester.pump();
    expect(h.prefs.settings.derived, isTrue);
    expect(h.prefs.settings.accentId, 'rose');
    expect(_check(const ValueKey('lfl-accent-rose')), findsOneWidget);
  });

  group('accessibility', () {
    testWidgets('every control is at least 48 dp and has semantics', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, values: {'lfl_source': 'derived'});

      final keys = <Key>[
        for (final id in _accentIds) ValueKey('lfl-accent-$id'),
        ..._lightKeys,
        const ValueKey('lfl-font-system'),
        const ValueKey('lfl-font-inter'),
        const ValueKey('lfl-font-montserrat'),
        const ValueKey('lfl-font-nunito'),
        const ValueKey('lfl-font-jetbrains'),
        const ValueKey('lfl-more-themes'),
      ];
      void expectTap(Key key) {
        final size = tester.getSize(find.byKey(key));
        expect(size.width, greaterThanOrEqualTo(48), reason: '$key');
        expect(size.height, greaterThanOrEqualTo(48), reason: '$key');
      }

      keys.forEach(expectTap);
      // The dark backgrounds, in the dark appearance.
      await tester.tap(find.byKey(const ValueKey('lfl-appearance-dark')));
      await tester.pump();
      _darkKeys.forEach(expectTap);
      await tester.tap(find.byKey(const ValueKey('lfl-appearance-system')));
      await tester.pump();

      final blue = tester.getSemantics(
        find.byKey(const ValueKey('lfl-accent-blue')),
      );
      expect(blue.label, 'Blue');
      expect(blue.flagsCollection.isButton, isTrue);
      expect(blue.flagsCollection.isSelected, Tristate.isFalse);
      final terracotta = tester.getSemantics(
        find.byKey(const ValueKey('lfl-accent-terracotta')),
      );
      expect(terracotta.label, 'Terracotta');
      expect(terracotta.flagsCollection.isSelected, Tristate.isTrue);
      final paper = tester.getSemantics(
        find.byKey(const ValueKey('lfl-light-paper')),
      );
      expect(paper.label, 'Paper');
      expect(paper.flagsCollection.isSelected, Tristate.isTrue);
      semantics.dispose();
    });
  });

  group('large text in the nine languages', () {
    for (final locale in Strings.supportedLocales) {
      testWidgets('${locale.languageCode}: 200 % text, list in force', (
        tester,
      ) async {
        await _pump(
          tester,
          locale: locale,
          textScale: 2,
          size: const Size(360, 5200),
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('lfl-list-banner')), findsOneWidget);
        expect(find.byKey(const ValueKey('lfl-more-themes')), findsOneWidget);
      });

      testWidgets('${locale.languageCode}: 200 % text, Look & Feel in force', (
        tester,
      ) async {
        await _pump(
          tester,
          values: {'lfl_source': 'derived', 'lfl_appearance': 'dark'},
          locale: locale,
          textScale: 2,
          size: const Size(360, 5200),
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('lfl-list-banner')), findsNothing);
        expect(find.byKey(const ValueKey('lfl-dark-black')), findsOneWidget);
      });
    }
  });

  test(
    'every Look & Feel string exists, translated, in the nine languages',
    () {
      expect(Strings.supportedLocales, hasLength(9));
      // Looked up through the delegates in the screen tests above; here the
      // catalogue's own keys: no language repeats the key or the Spanish text
      // where they must differ.
      for (final locale in Strings.supportedLocales) {
        final strings = lookupStrings(locale);
        for (final text in [
          strings.lflTitle,
          strings.lflAppearance,
          strings.lflAccent,
          strings.lflLightBackground,
          strings.lflDarkBackground,
          strings.lflFont,
          strings.lflMoreThemes,
          strings.lflReturn,
          strings.lflThemeBannerBody,
          strings.lflFontNunitoDesc,
        ]) {
          expect(text.trim(), isNotEmpty, reason: locale.languageCode);
          expect(text, isNot(startsWith('lfl')), reason: locale.languageCode);
        }
        if (locale.languageCode != 'es') {
          expect(
            strings.lflAppearance,
            isNot(lookupStrings(const Locale('es')).lflAppearance),
            reason: '${locale.languageCode} must not repeat Spanish',
          );
          expect(
            strings.lflAccent,
            isNot(lookupStrings(const Locale('es')).lflAccent),
            reason: '${locale.languageCode} must not repeat Spanish',
          );
        }
      }
    },
  );
}
