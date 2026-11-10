// Q9-CRISTAL (the owner, 29 Oct): every HermesAppBar is a glass strip
// (lib/core/design/glass_strip.dart): its round button, title pill and
// actions pill share ONE blur, wear the composer's veil without shadow,
// over a soft fade; without blur, or on a page where nothing passes under
// the header, the header of before, in the same place.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _titleKey = ValueKey('hermes-app-bar-title');
const _actionsKey = ValueKey('hermes-app-bar-actions');
const _leadingKey = ValueKey('hermes-app-bar-leading');
const _scrimKey = ValueKey('hermes-app-bar-scrim');
const _bandKey = ValueKey('hermes-app-bar-glass');
const _tailKey = ValueKey('hermes-app-bar-veil-tail');
const _row = 'Fila 0 con un texto que pasa por detrás';

Widget _app({
  String themeId = 'classic-dark',
  bool scrim = true,
  bool glass = true,
}) => MaterialApp(
  theme: AppTheme.fromId(themeId),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    drawer: const Drawer(),
    appBar: HermesAppBar(
      titleInPill: true,
      title: const Text('Conversaciones'),
      scrim: scrim,
      glass: glass,
      actions: [
        IconButton(
          icon: const Icon(Icons.edit_square),
          tooltip: 'Nueva',
          onPressed: () {},
        ),
        IconButton(
          icon: const Icon(Icons.more_vert),
          tooltip: 'Más',
          onPressed: () {},
        ),
      ],
    ),
    body: ListView(
      clipBehavior: hermesUnderHeader,
      children: [
        for (var i = 0; i < 40; i++)
          ListTile(
            title: Text(
              i == 0 ? _row : 'Fila $i con un texto que pasa por detrás',
            ),
          ),
      ],
    ),
  ),
);

List<BackdropFilterLayer> _filters(WidgetTester tester) =>
    tester.layers.whereType<BackdropFilterLayer>().toList();

ClipPathLayer _blurClip(WidgetTester tester) {
  final clips = tester.layers.whereType<ClipPathLayer>();
  return clips.singleWhere((layer) => layer.firstChild is BackdropFilterLayer);
}

Material _surface(WidgetTester tester, Key key) {
  final material = find.descendant(
    of: find.byKey(key),
    matching: find.byType(Material),
  );
  return tester.widget<Material>(material.first);
}

List<BoxShadow>? _shadows(WidgetTester tester, Key key) {
  final box = find.descendant(
    of: find.byKey(key),
    matching: find.byType(DecoratedBox),
  );
  final decoration = tester.widget<DecoratedBox>(box.first).decoration;
  return (decoration as ShapeDecoration).shadows;
}

Color? _leadingFill(WidgetTester tester) {
  final theme = tester.widget<IconButtonTheme>(find.byKey(_leadingKey));
  return theme.data.style?.backgroundColor?.resolve({});
}

LinearGradient _scrim(WidgetTester tester) {
  final scrim = tester.widget<DecoratedBox>(find.byKey(_scrimKey));
  return (scrim.decoration as BoxDecoration).gradient! as LinearGradient;
}

void main() {
  tearDown(() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
  });

  testWidgets('the header is ONE blur: the band under its three pieces, '
      'the measured rectangle of the header and not a pixel more', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    expect(_filters(tester), hasLength(1));
    final path = _blurClip(tester).clipPath!;
    final bar = tester.getRect(find.byType(AppBar));
    final title = tester.getRect(find.byKey(_titleKey));
    final actions = tester.getRect(find.byKey(_actionsKey));
    final leading = tester.getRect(find.byKey(_leadingKey));
    expect(path.contains(title.center), isTrue);
    expect(path.contains(actions.center), isTrue);
    expect(path.contains(leading.center), isTrue);
    // The page between the pieces is frosted too: it is a band.
    final gap = Offset((title.right + actions.left) / 2, title.center.dy);
    expect(gap.dx, greaterThan(title.right));
    expect(path.contains(gap), isTrue);
    expect(path.getBounds().top, bar.top);
    expect(path.getBounds().bottom, bar.bottom);
    expect(path.getBounds().left, bar.left);
    expect(path.getBounds().right, bar.right);
    // Nothing below the header: the tail is tint only.
    expect(path.contains(Offset(title.center.dx, bar.bottom + 2)), isFalse);
  });

  for (final id in const ['classic-dark', 'classic']) {
    testWidgets('$id: the pieces wear the composer\'s veil, their hairline, '
        'no shadow', (tester) async {
      await tester.pumpWidget(_app(themeId: id));
      final colors = AppTheme.fromId(id).hermes;
      final chrome = HermesChrome.of(colors);
      final veil = FrostedBackdrop.glassVeil(colors);
      expect(_surface(tester, _titleKey).color, veil);
      expect(_surface(tester, _actionsKey).color, veil);
      expect(_leadingFill(tester), veil);
      expect(_shadows(tester, _titleKey), isEmpty);
      expect(_shadows(tester, _actionsKey), isEmpty);
      final shape = _surface(tester, _titleKey).shape! as OutlinedBorder;
      expect(shape.side.color, chrome.line);
    });
  }

  testWidgets('the band is translucent: the page colour, never solid, its '
      'tail gone just below the header', (tester) async {
    await tester.pumpWidget(_app());
    final band = tester.widget<DecoratedBox>(find.byKey(_bandKey));
    final gradient =
        (band.decoration as BoxDecoration).gradient! as LinearGradient;
    final alphas = [for (final color in gradient.colors) color.a];
    expect(alphas.every((a) => a < 1 && a > 0), isTrue, reason: 'translucent');
    expect(
      gradient.colors.first.withValues(alpha: 1),
      AppTheme.fromId('classic-dark').hermes.background,
    );
    expect(find.byKey(_scrimKey), findsNothing, reason: 'no second tint');
    final tail = tester.widget<DecoratedBox>(find.byKey(_tailKey));
    final fade = (tail.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(fade.colors.last.a, 0);
    expect(
      tester.getRect(find.byKey(_tailKey)).bottom,
      tester.getRect(find.byType(AppBar)).bottom + HermesAppBar.veilTail,
    );
  });

  group('the header of before', () {
    void expectBefore(WidgetTester tester, {bool scrim = true}) {
      final chrome = HermesChrome.of(AppTheme.fromId('classic-dark').hermes);
      expect(_filters(tester), isEmpty);
      expect(_surface(tester, _titleKey).color, chrome.fill);
      expect(_surface(tester, _actionsKey).color, chrome.fill);
      expect(_leadingFill(tester), chrome.fill);
      expect(_shadows(tester, _titleKey), chrome.shadow);
      if (!scrim) return;
      final gradient = _scrim(tester);
      expect(gradient.colors.first.a, closeTo(0.97, 0.01));
      expect(gradient.stops![2], 0.68);
    }

    testWidgets('without blur (the device policy)', (tester) async {
      FrostedBackdropPolicy.blurAllowed.value = false;
      await tester.pumpWidget(_app());
      expectBefore(tester);
    });

    testWidgets('a page where nothing passes under the header '
        '(glass: false)', (tester) async {
      await tester.pumpWidget(_app(glass: false));
      expectBefore(tester);
    });

    testWidgets('a header with no scrim', (tester) async {
      await tester.pumpWidget(_app(scrim: false));
      expectBefore(tester, scrim: false);
      expect(find.byKey(_scrimKey), findsNothing);
    });
  });

  testWidgets('the geometry is the one of before: same header, same list, '
      'same pieces', (tester) async {
    await tester.pumpWidget(_app());
    final bar = tester.getRect(find.byType(AppBar));
    final row = tester.getRect(find.text(_row));
    final title = tester.getRect(find.byKey(_titleKey));
    FrostedBackdropPolicy.blurAllowed.value = false;
    await tester.pump();
    expect(tester.getRect(find.byType(AppBar)), bar);
    expect(tester.getRect(find.text(_row)), row);
    expect(tester.getRect(find.byKey(_titleKey)), title);
    expect(title.height, HermesAppBar.pieceSize);
  });

  // REVIEW-Q9-CRISTAL C2: two pages with a HermesAppBar (the same
  // priority), one pushed over the other. While the route animates both
  // are on screen and only one owns FrostedZone.top; the other keeps the
  // glass's veil and no shadow, without blur. Neither header flips between
  // glass and the chrome of before halfway.
  testWidgets('a push between two glass headers: neither flips to the '
      'chrome of before halfway', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    Widget page(String name) => Scaffold(
      appBar: HermesAppBar(titleInPill: true, title: Text(name)),
      body: ListView(
        clipBehavior: hermesUnderHeader,
        children: [
          for (var i = 0; i < 30; i++) ListTile(title: Text('$name, fila $i')),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.fromId('classic-dark'),
        home: page('Primera'),
      ),
    );
    await tester.pump();
    final veil = FrostedBackdrop.glassVeil(
      AppTheme.fromId('classic-dark').hermes,
    );
    void expectGlass(String name) {
      final piece = find.ancestor(
        of: find.text(name),
        matching: find.byKey(_titleKey),
      );
      final material = find.descendant(
        of: piece,
        matching: find.byType(Material),
      );
      expect(tester.widget<Material>(material.first).color, veil);
      final box = find.descendant(
        of: piece,
        matching: find.byType(DecoratedBox),
      );
      final decoration = tester.widget<DecoratedBox>(box.first).decoration;
      expect((decoration as ShapeDecoration).shadows, isEmpty, reason: name);
    }

    expectGlass('Primera');
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => page('Segunda')),
      ),
    );
    await tester.pump();
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump(const Duration(milliseconds: 60));
      expectGlass('Primera');
      expectGlass('Segunda');
      expect(_filters(tester), hasLength(1), reason: 'one blur at the top');
    }
    await tester.pumpAndSettle();
    expectGlass('Segunda');
    expect(_filters(tester), hasLength(1));
  });

  // REVIEW-Q9-CRISTAL C1: what the pieces say reads at AA on every surface
  // they can sit on, in every theme: the chrome of before, and the glass
  // over the worst page (white behind a dark theme, black behind a light
  // one) and over its own. The title's badge, over its tint, included.
  test('every theme: the pieces\' ink and the title badge read at AA on '
      'glass and on the chrome of before', () {
    for (final preset in AppTheme.presets) {
      final colors = AppTheme.fromId(preset.id).hermes;
      final chrome = HermesChrome.of(colors);
      final badge = HermesTitleBadge.inkOnBand(colors);
      final tint = chrome.ink.withValues(alpha: HermesTitleBadge.tintOpacity);
      for (final (name, under) in [
        ('chrome', chrome.opaque),
        ('glass, worst page', HermesGlassStrip.worstUnder(colors)),
        ('glass, own page', HermesGlassStrip.ownUnder(colors)),
        (
          'the header band, worst page',
          HermesAppBar.bandUnder(colors, HermesAppBar.bandAlpha(colors)),
        ),
      ]) {
        expect(
          ThemeContrast.ratio(chrome.ink, under),
          greaterThanOrEqualTo(4.5),
          reason: '${preset.id}, ink, $name',
        );
        expect(
          ThemeContrast.ratio(badge, ThemeContrast.composite(tint, under)),
          greaterThanOrEqualTo(4.5),
          reason: '${preset.id}, badge, $name',
        );
      }
    }
  });

  testWidgets('the title badge wears that ink', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('classic-dark'),
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const Scaffold(
          appBar: HermesAppBar(
            titleInPill: true,
            title: Text('Conversaciones'),
            titleBadge: HermesTitleBadge('ana'),
          ),
        ),
      ),
    );
    final text = tester.widget<Text>(find.text('ana'));
    expect(
      text.style?.color,
      HermesTitleBadge.inkOnBand(AppTheme.fromId('classic-dark').hermes),
    );
  });
}
