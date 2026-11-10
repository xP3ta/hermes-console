// The glass band under the floating header (1.4.0): the header is a band of
// glass like the dock, not a solid veil. The strip's ONE blur fills the
// measured rectangle of the header; a tint of the page colour, dense enough
// that the title reads at AA over the worst content that can pass behind
// (white behind a dark theme, black behind a light one), keeps the rest.
// Where there is no glass (high contrast, reduced motion, the policy) it is
// the solid veil of before. Measured, not painted.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/dock.dart'
    show dockRailFootprint, dockRailMargin;
import 'package:hermes_android/core/widgets/dock_style.dart' show DockBar;
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _band = ValueKey('hermes-app-bar-glass');
const _veil = ValueKey('hermes-app-bar-veil');
const _tail = ValueKey('hermes-app-bar-veil-tail');
const _title = ValueKey('hermes-app-bar-plain-title');

Widget _app(
  String themeId, {
  bool scrim = true,
  bool highContrast = false,
  Widget? body,
  PreferredSizeWidget? bar,
  EdgeInsets padding = const EdgeInsets.only(top: 24),
}) => MaterialApp(
  theme: AppTheme.fromId(themeId),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(padding: padding, highContrast: highContrast),
    child: child!,
  ),
  home: Scaffold(
    appBar: bar ?? HermesAppBar(title: const Text('Ajustes'), scrim: scrim),
    body:
        body ??
        ListView(
          clipBehavior: hermesUnderHeader,
          children: [
            for (var i = 0; i < 40; i++)
              SizedBox(
                height: 72,
                child: ColoredBox(
                  key: ValueKey('row-$i'),
                  color: Colors.transparent,
                ),
              ),
          ],
        ),
  ),
);

LinearGradient _gradientOf(WidgetTester tester, Key key) {
  final box = tester.widget<DecoratedBox>(find.byKey(key));
  return (box.decoration as BoxDecoration).gradient! as LinearGradient;
}

List<BackdropFilterLayer> _filters(WidgetTester tester) =>
    tester.layers.whereType<BackdropFilterLayer>().toList();

ClipPathLayer _blurClip(WidgetTester tester) => tester.layers
    .whereType<ClipPathLayer>()
    .singleWhere((layer) => layer.firstChild is BackdropFilterLayer);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void phone(WidgetTester tester, [Size size = const Size(400, 800)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  tearDown(() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
  });

  group('the glass band', () {
    for (final preset in AppTheme.presets) {
      testWidgets('${preset.id}: translucent, the page colour, over the whole '
          'header, and the title reads at AA over the worst content', (
        tester,
      ) async {
        phone(tester);
        await tester.pumpWidget(_app(preset.id));
        final colors = AppTheme.fromId(preset.id).hermes;
        final chrome = HermesChrome.of(colors);
        final bar = tester.getRect(find.byType(AppBar));
        final band = tester.getRect(find.byKey(_band));
        final title = tester.getRect(find.byKey(_title));

        expect(band, bar, reason: 'the measured header, status included');
        expect(bar.height, kToolbarHeight + 24, reason: 'it counts the status');
        expect(band.contains(title.topLeft), isTrue);
        expect(band.contains(title.bottomRight), isTrue);
        expect(find.byKey(_veil), findsNothing, reason: 'no solid veil');

        final gradient = _gradientOf(tester, _band);
        for (final color in gradient.colors) {
          expect(color.a, lessThan(1), reason: 'translucent');
          expect(color.a, greaterThan(0));
          expect(color.withValues(alpha: 1), colors.background);
        }
        final toolbar = gradient.colors[1];
        expect(toolbar.a, greaterThanOrEqualTo(HermesGlassStrip.fadeEdge));
        expect(
          gradient.colors.first.a,
          greaterThanOrEqualTo(toolbar.a),
          reason: 'denser over the status bar',
        );

        // The worst content behind: the page's opposite (a light card behind
        // a dark theme, black text behind a light one), and its mirror.
        for (final behind in [Colors.white, Colors.black]) {
          final under = ThemeContrast.composite(toolbar, behind);
          expect(
            ThemeContrast.ratio(chrome.ink, under),
            greaterThanOrEqualTo(4.5),
            reason: '${preset.id}: the title over $behind',
          );
          final badgeOn = ThemeContrast.composite(
            chrome.ink.withValues(alpha: HermesTitleBadge.tintOpacity),
            under,
          );
          expect(
            ThemeContrast.ratio(HermesTitleBadge.inkOnBand(colors), badgeOn),
            greaterThanOrEqualTo(4.5),
            reason: '${preset.id}: the badge over $behind',
          );
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('every theme keeps some translucency: none needs the band '
        'solid to read', (tester) async {
      for (final preset in AppTheme.presets) {
        final alpha = HermesAppBar.bandAlpha(AppTheme.fromId(preset.id).hermes);
        // ignore: avoid_print
        print('[band] ${preset.id}: tint ${alpha.toStringAsFixed(2)}');
        expect(alpha, lessThan(1), reason: preset.id);
        expect(alpha, greaterThanOrEqualTo(HermesGlassStrip.fadeEdge));
      }
    });

    testWidgets('the blur is ONE, as big as the measured header and no '
        'bigger, and it frosts the page between the pieces', (tester) async {
      phone(tester);
      await tester.pumpWidget(_app('classic-dark'));
      final bar = tester.getRect(find.byType(AppBar));
      expect(_filters(tester), hasLength(1));
      expect(_filters(tester).single.filter, isNotNull);
      final path = _blurClip(tester).clipPath!;
      expect(path.getBounds(), bar);
      final title = tester.getRect(find.byKey(_title));
      expect(path.contains(title.center), isTrue);
      expect(path.contains(Offset(200, bar.bottom + 1)), isFalse);
    });

    testWidgets('a row scrolled under the header is behind the band, which '
        'is translucent', (tester) async {
      phone(tester);
      await tester.pumpWidget(_app('classic-dark'));
      final bar = tester.getRect(find.byType(AppBar));
      await tester.drag(find.byType(ListView), Offset(0, -(bar.bottom + 40)));
      await tester.pump();
      final title = tester.getRect(find.byKey(_title));
      final under = [
        for (var i = 0; i < 40; i++)
          if (find.byKey(ValueKey('row-$i')).evaluate().isNotEmpty)
            tester.getRect(find.byKey(ValueKey('row-$i'))),
      ].where((row) => row.overlaps(title)).toList();
      expect(under, isNotEmpty, reason: 'a row is behind the title');
      final band = tester.getRect(find.byKey(_band));
      for (final row in under) {
        expect(band.intersect(row).height, greaterThan(0));
      }
      expect(_filters(tester), hasLength(1), reason: 'no blur per row');
    });

    testWidgets('below the header the tint melts into the page in '
        'veilTail, which is no more than the gap a page leaves', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(_app('classic-dark'));
      final bar = tester.getRect(find.byType(AppBar));
      final tail = tester.getRect(find.byKey(_tail));
      expect(tail.top, bar.bottom);
      expect(tail.height, HermesAppBar.veilTail);
      expect(HermesAppBar.veilTail, lessThanOrEqualTo(HermesSpace.pageTop));
      expect(HermesAppBar.veilTail, lessThanOrEqualTo(HermesSpace.x2));
      expect(tail.left, 0, reason: 'no rail in a phone window');
      final gradient = _gradientOf(tester, _tail);
      final band = _gradientOf(tester, _band);
      expect(gradient.colors.first.a, band.colors.last.a);
      expect(gradient.colors.last.a, 0.0);
    });
  });

  group('without glass the header is the veil of before', () {
    for (final id in const ['classic-dark', 'classic']) {
      testWidgets('$id: high contrast, the page colour SOLID, no blur', (
        tester,
      ) async {
        phone(tester);
        await tester.pumpWidget(_app(id, highContrast: true));
        final colors = AppTheme.fromId(id).hermes;
        final bar = tester.getRect(find.byType(AppBar));
        final veil = tester.getRect(find.byKey(_veil));
        expect(veil, bar);
        final solid = tester.widget<ColoredBox>(find.byKey(_veil)).color;
        expect(solid.a, 1.0, reason: 'opaque');
        expect(solid.toARGB32(), colors.background.toARGB32());
        expect(find.byKey(_band), findsNothing);
        expect(_filters(tester), isEmpty);
        final tail = _gradientOf(tester, _tail);
        expect(tail.colors.first.a, 1.0);
        expect(tail.colors.last.a, 0.0);
      });

      testWidgets('$id: the glass level off is the solid veil too', (
        tester,
      ) async {
        phone(tester);
        await tester.pumpWidget(
          GlassLookScope(
            prefs: GlassLookPrefs.inMemory(GlassLevel.off),
            child: _app(id),
          ),
        );
        expect(find.byKey(_veil), findsOneWidget);
        expect(find.byKey(_band), findsNothing);
        expect(_filters(tester), isEmpty);
      });

      testWidgets('$id: no blur on this device, the same solid veil', (
        tester,
      ) async {
        phone(tester);
        FrostedBackdropPolicy.blurAllowed.value = false;
        await tester.pumpWidget(_app(id));
        expect(find.byKey(_veil), findsOneWidget);
        expect(find.byKey(_band), findsNothing);
        expect(_filters(tester), isEmpty);
      });
    }
  });

  testWidgets('the band and its tail cost no blur of their own and do not '
      'take touches', (tester) async {
    phone(tester);
    await tester.pumpWidget(_app('classic-dark'));
    for (final key in const [_band, _tail]) {
      expect(
        find.ancestor(
          of: find.byKey(key),
          matching: find.byType(IgnorePointer),
        ),
        findsWidgets,
        reason: '$key',
      );
      expect(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
    }
    expect(find.byType(BackdropFilter), findsNothing, reason: 'no widget');
    expect(_filters(tester), hasLength(1));
  });

  testWidgets('a page that opts out of the scrim has no band, no tail', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(_app('classic-dark', scrim: false));
    expect(find.byKey(_band), findsNothing);
    expect(find.byKey(_veil), findsNothing);
    expect(find.byKey(_tail), findsNothing);
    expect(_filters(tester), isEmpty);
  });

  group('the side rail', () {
    testWidgets('the tail leaves the rail column alone and the first rail '
        'control is not covered', (tester) async {
      phone(tester, const Size(900, 800));
      final railTop = kToolbarHeight + 24 + 4;
      await tester.pumpWidget(
        _app(
          'classic-dark',
          body: Stack(
            children: [
              Positioned(
                key: const ValueKey('rail-first'),
                left: dockRailMargin,
                top: railTop - kToolbarHeight - 24,
                width: DockBar.railWidth,
                height: 48,
                child: const SizedBox(),
              ),
            ],
          ),
        ),
      );
      final tail = tester.getRect(find.byKey(_tail));
      final band = tester.getRect(find.byKey(_band));
      final rail = tester.getRect(find.byKey(const ValueKey('rail-first')));
      expect(
        tail.left,
        dockRailFootprint(tester.element(find.byType(Scaffold))),
      );
      expect(tail.overlaps(rail), isFalse, reason: 'the rail is not dimmed');
      expect(band.left, 0, reason: 'the header itself is edge to edge');
      expect(band.right, 900);
      expect(tail.right, 900);
    });
  });

  testWidgets('a notice is above the header and its band', (tester) async {
    phone(tester);
    await tester.pumpWidget(_app('classic-dark'));
    final context = tester.element(find.byType(Scaffold));
    HermesNotice.show(
      context,
      message: 'Guardado',
      kind: HermesNoticeKind.success,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Guardado'), findsOneWidget);
    // It lives in the overlay, not in the page: the page (header and band
    // included) is painted under it.
    expect(
      find.ancestor(of: find.text('Guardado'), matching: find.byType(Scaffold)),
      findsNothing,
    );
    expect(
      find.ancestor(of: find.text('Guardado'), matching: find.byType(Overlay)),
      findsWidgets,
    );
    await tester.pump(const Duration(seconds: 12));
  });
}
