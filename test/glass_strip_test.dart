// Q9-CRISTAL (the owner, 29 Oct): the composer's glass at the top of every
// screen, the mechanism (lib/core/design/glass_strip.dart). One blur per
// strip, clipped to its pieces and following them; the list behind never
// repaints it; the composer's veil; a soft fade, never a solid band;
// without blur (the device, reduced motion, high contrast) the chrome of
// before, with the same widgets and the same geometry; the pieces' ink at
// AA over any page, in every theme.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';

/// A floating piece as a header builds one: its outline joins the strip,
/// its fill is the strip's glass, or the chrome of before.
class _Piece extends StatelessWidget {
  const _Piece({required this.width, this.child, super.key});

  final double width;
  final Widget? child;

  static const double height = 44;

  @override
  Widget build(BuildContext context) {
    final chrome = HermesChrome.ofContext(context);
    final glass = HermesGlassStrip.of(context);
    return HermesGlassPiece(
      shape: const StadiumBorder(),
      child: Material(
        color: glass?.veil ?? chrome.fill,
        shape: StadiumBorder(side: BorderSide(color: chrome.line)),
        child: SizedBox(width: width, height: height, child: child),
      ),
    );
  }
}

const _left = ValueKey('left');
const _middle = ValueKey('middle');
const _right = ValueKey('right');

/// A list under a strip of three pieces, like a header: a round button, a
/// title pill and an actions pill. The strip sits at the screen's top left,
/// so its space is the screen's.
Widget _scene({
  bool enabled = true,
  MediaQueryData Function(MediaQueryData)? media,
  ScrollController? scroll,
  String themeId = 'classic-dark',
}) => MaterialApp(
  theme: AppTheme.fromId(themeId),
  builder: media == null
      ? null
      : (context, child) =>
            MediaQuery(data: media(MediaQuery.of(context)), child: child!),
  home: Scaffold(
    body: Stack(
      children: [
        ListView(
          controller: scroll,
          children: [
            for (var i = 0; i < 60; i++)
              ListTile(title: Text('Fila $i que pasa por detrás')),
          ],
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 80,
          child: HermesGlassStrip(
            enabled: enabled,
            child: const Stack(
              children: [
                Positioned(
                  left: 8,
                  top: 24,
                  child: _Piece(key: _left, width: 44),
                ),
                Positioned(
                  left: 320,
                  top: 24,
                  child: _Piece(key: _middle, width: 160),
                ),
                Positioned(
                  right: 8,
                  top: 24,
                  child: _Piece(key: _right, width: 96),
                ),
              ],
            ),
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

Color _fill(WidgetTester tester, Key key) {
  final material = find.descendant(
    of: find.byKey(key),
    matching: find.byType(Material),
  );
  return tester.widget<Material>(material).color!;
}

void main() {
  tearDown(() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
  });

  group('one blur per strip', () {
    testWidgets('three pieces push ONE backdrop filter, clipped to the '
        'pieces and not to the page between them', (tester) async {
      await tester.pumpWidget(_scene());
      expect(_filters(tester), hasLength(1));
      final path = _blurClip(tester).clipPath!;
      for (final key in const [_left, _middle, _right]) {
        expect(
          path.contains(tester.getCenter(find.byKey(key))),
          isTrue,
          reason: '$key',
        );
      }
      final middle = tester.getRect(find.byKey(_middle));
      final right = tester.getRect(find.byKey(_right));
      // Between the pieces and below them the page shows, sharp.
      expect(path.contains(Offset(200, middle.center.dy)), isFalse);
      expect(
        path.contains(Offset((middle.right + right.left) / 2, middle.top)),
        isFalse,
      );
      final below = Offset(middle.center.dx, middle.bottom + 4);
      expect(path.contains(below), isFalse);
      // The outline is the pieces': a stadium leaves its corners out.
      expect(path.contains(middle.topLeft + const Offset(1, 1)), isFalse);
      expect(HermesGlassStrip.sigma, FrostedBackdrop.glassSigma);
    });

    testWidgets('a piece that grows takes the blur with it', (tester) async {
      final width = ValueNotifier<double>(80);
      addTearDown(width.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId('classic-dark'),
          home: Align(
            alignment: Alignment.topLeft,
            child: HermesGlassStrip(
              child: SizedBox(
                width: 400,
                height: 60,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ValueListenableBuilder<double>(
                    valueListenable: width,
                    builder: (context, value, _) => _Piece(width: value),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      double blurWidth() => _blurClip(tester).clipPath!.getBounds().width;
      expect(blurWidth(), closeTo(80, 0.5));
      width.value = 220;
      await tester.pump();
      expect(blurWidth(), closeTo(220, 0.5));
      expect(_filters(tester), hasLength(1));
    });

    testWidgets('a piece moved behind a repaint boundary of its own is '
        'followed a frame later', (tester) async {
      final left = ValueNotifier<double>(10);
      addTearDown(left.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId('classic-dark'),
          home: Align(
            alignment: Alignment.topLeft,
            child: HermesGlassStrip(
              child: SizedBox(
                width: 400,
                height: 60,
                child: RepaintBoundary(
                  child: ValueListenableBuilder<double>(
                    valueListenable: left,
                    builder: (context, value, _) => Padding(
                      padding: EdgeInsets.only(left: value),
                      child: const Align(
                        alignment: Alignment.topLeft,
                        child: _Piece(width: 60),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      double blurLeft() => _blurClip(tester).clipPath!.getBounds().left;
      expect(blurLeft(), closeTo(10, 0.5));
      left.value = 150;
      await tester.pump();
      await tester.pump();
      expect(blurLeft(), closeTo(150, 0.5));
    });

    testWidgets('scrolling the list behind never repaints the strip', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(_scene(scroll: scroll));
      RenderObject? strip = tester.renderObject(find.byKey(_middle));
      while (strip != null && !strip.isRepaintBoundary) {
        strip = strip.parent;
      }
      expect(strip, isNotNull);
      List<Layer> pictures() {
        final found = <Layer>[];
        void walk(Layer? layer) {
          for (; layer != null; layer = layer.nextSibling) {
            if (layer is PictureLayer) found.add(layer);
            if (layer is ContainerLayer) walk(layer.firstChild);
          }
        }

        walk(strip!.debugLayer!.firstChild);
        return found;
      }

      final before = pictures();
      expect(before, isNotEmpty);
      for (var i = 0; i < 10; i++) {
        scroll.jumpTo(scroll.offset + 30);
        await tester.pump();
      }
      final after = pictures();
      expect(after.length, before.length);
      for (var i = 0; i < after.length; i++) {
        expect(identical(after[i], before[i]), isTrue, reason: 'picture $i');
      }
      expect(_filters(tester), hasLength(1));
    });

    testWidgets('pieces that leave take the blur away; none, no filter', (
      tester,
    ) async {
      final shown = ValueNotifier<bool>(true);
      addTearDown(shown.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId('classic-dark'),
          home: Align(
            alignment: Alignment.topLeft,
            child: HermesGlassStrip(
              child: SizedBox(
                width: 400,
                height: 60,
                child: ValueListenableBuilder<bool>(
                  valueListenable: shown,
                  builder: (context, value, _) => Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _Piece(width: 44),
                      if (value) const _Piece(width: 120),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      double blurWidth() => _blurClip(tester).clipPath!.getBounds().width;
      expect(blurWidth(), closeTo(164, 1));
      shown.value = false;
      await tester.pump();
      expect(blurWidth(), closeTo(44, 1));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId('classic-dark'),
          home: const HermesGlassStrip(child: SizedBox.expand()),
        ),
      );
      expect(_filters(tester), isEmpty);
    });

    testWidgets('a piece outside any strip is nothing of the kind', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId('classic-dark'),
          home: const Center(child: _Piece(key: _middle, width: 120)),
        ),
      );
      expect(_filters(tester), isEmpty);
      final chrome = HermesChrome.of(AppTheme.fromId('classic-dark').hermes);
      expect(_fill(tester, _middle), chrome.fill);
    });
  });

  // the owner's rule 2: ONE blur per zone. Two headers on screen (the list's
  // beside the chat's on the open Fold): the higher priority blurs, the
  // other keeps the glass's veil without blur (REVIEW-Q9-CRISTAL C2: a
  // route transition never flips a header to the chrome of before). Who
  // owns the zone is told after the frame: hence the second pump.
  group('FrostedZone.top', () {
    Widget two({int left = 0, int right = 1, bool rightOn = true}) =>
        MaterialApp(
          theme: AppTheme.fromId('classic-dark'),
          home: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HermesGlassStrip(
                priority: left,
                child: const _Piece(key: _left, width: 120),
              ),
              HermesGlassStrip(
                priority: right,
                enabled: rightOn,
                child: const _Piece(key: _right, width: 120),
              ),
            ],
          ),
        );

    testWidgets('two strips on screen: one blur, the higher priority\'s', (
      tester,
    ) async {
      await tester.pumpWidget(two());
      await tester.pump();
      final veil = FrostedBackdrop.glassVeil(
        AppTheme.fromId('classic-dark').hermes,
      );
      expect(_filters(tester), hasLength(1));
      expect(_fill(tester, _right), veil);
      expect(_fill(tester, _left), veil, reason: 'the glass, without blur');
      // The blur is the right strip's, in its own space (each strip is a
      // layer of its own).
      final origin = tester.getTopLeft(find.byType(HermesGlassStrip).last);
      final path = _blurClip(tester).clipPath!;
      final right = tester.getCenter(find.byKey(_right)) - origin;
      expect(path.contains(right), isTrue);
      expect(path.getBounds().width, closeTo(120, 0.5));
    });

    testWidgets('a strip that is off never keeps the blur from one that is '
        'on', (tester) async {
      await tester.pumpWidget(two(right: 5, rightOn: false));
      await tester.pump();
      final veil = FrostedBackdrop.glassVeil(
        AppTheme.fromId('classic-dark').hermes,
      );
      expect(_filters(tester), hasLength(1));
      expect(_fill(tester, _left), veil);
    });

    testWidgets('a strip on a covered route gives the blur to the one on '
        'screen', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.fromId('classic-dark'),
          home: const Align(
            alignment: Alignment.topLeft,
            child: HermesGlassStrip(
              priority: 3,
              child: _Piece(key: _left, width: 120),
            ),
          ),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Align(
              alignment: Alignment.topLeft,
              child: HermesGlassStrip(child: _Piece(key: _right, width: 200)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump();
      final veil = FrostedBackdrop.glassVeil(
        AppTheme.fromId('classic-dark').hermes,
      );
      expect(_fill(tester, _right), veil);
      expect(_filters(tester), hasLength(1));
      expect(_blurClip(tester).clipPath!.getBounds().width, closeTo(200, 1));
    });
  });

  group('the composer\'s glass', () {
    for (final id in const ['classic-dark', 'classic']) {
      testWidgets('$id: the pieces wear the composer\'s veil', (tester) async {
        await tester.pumpWidget(_scene(themeId: id));
        final veil = FrostedBackdrop.glassVeil(AppTheme.fromId(id).hermes);
        for (final key in const [_left, _middle, _right]) {
          expect(_fill(tester, key), veil, reason: '$key');
        }
        final context = tester.element(find.byKey(_middle));
        expect(HermesGlassStrip.of(context)?.veil, veil);
        expect(HermesGlassStrip.contains(context), isTrue);
      });
    }

    test('the fade is soft: never solid, denser at the top, gone below '
        'the header', () {
      const page = Color(0xFF202020);
      final gradient = HermesGlassStrip.fade(
        page: page,
        statusInset: 24,
        extent: 80,
      );
      final alphas = [for (final color in gradient.colors) color.a];
      expect(alphas.every((a) => a < 1), isTrue, reason: 'no solid band');
      for (var i = 1; i < alphas.length; i++) {
        expect(alphas[i], lessThanOrEqualTo(alphas[i - 1]));
      }
      expect(alphas.last, 0);
      expect(gradient.colors.first.withValues(alpha: 1), page);
      expect(gradient.stops, [0, 24 / 100, 80 / 100, 1]);
      // Lighter than the header band of before (0,62 at its pieces).
      expect(HermesGlassStrip.fadeEdge, lessThan(0.62));
      // fadeAt is the gradient, read at a height.
      double at(double y) =>
          HermesGlassStrip.fadeAt(y, statusInset: 24, extent: 80);
      expect(at(0), HermesGlassStrip.fadeTop);
      expect(at(24), closeTo(HermesGlassStrip.fadeStatus, 1e-9));
      expect(at(80), closeTo(HermesGlassStrip.fadeEdge, 1e-9));
      expect(at(90), closeTo(HermesGlassStrip.fadeEdge / 2, 1e-9));
      expect(at(100), 0);
    });

    // AA of what the pieces say: the ink over the veil, over the fade, over
    // the worst page (white behind a dark theme, black behind a light one),
    // at the foot of a header's pieces, where the fade is lightest: a
    // 56 dp toolbar under a 24 dp status bar, its 44 dp pieces centred.
    test('every theme: the pieces\' ink reads at AA over any page', () {
      const status = 24.0;
      const extent = status + kToolbarHeight;
      const foot = status + (kToolbarHeight + _Piece.height) / 2;
      final fade = HermesGlassStrip.fadeAt(
        foot,
        statusInset: status,
        extent: extent,
      );
      for (final preset in AppTheme.presets) {
        final colors = AppTheme.fromId(preset.id).hermes;
        final chrome = HermesChrome.of(colors);
        final worst = chrome.dark
            ? const Color(0xFFFFFFFF)
            : const Color(0xFF000000);
        final behind = ThemeContrast.composite(
          colors.background.withValues(alpha: fade),
          worst,
        );
        final under = ThemeContrast.composite(
          FrostedBackdrop.glassVeil(colors),
          behind,
        );
        expect(
          ThemeContrast.ratio(chrome.ink, under),
          greaterThanOrEqualTo(4.5),
          reason: preset.id,
        );
      }
    });
  });

  group('without blur: the chrome of before', () {
    void expectBefore(WidgetTester tester) {
      final chrome = HermesChrome.of(AppTheme.fromId('classic-dark').hermes);
      expect(_filters(tester), isEmpty);
      for (final key in const [_left, _middle, _right]) {
        expect(_fill(tester, key), chrome.fill, reason: '$key');
      }
      final context = tester.element(find.byKey(_middle));
      expect(HermesGlassStrip.of(context), isNull);
      expect(HermesGlassStrip.contains(context), isTrue);
    }

    testWidgets('a strip that is off', (tester) async {
      await tester.pumpWidget(_scene(enabled: false));
      expectBefore(tester);
    });

    testWidgets('the device says no (mid or low range, the system\'s '
        'switch)', (tester) async {
      FrostedBackdropPolicy.blurAllowed.value = false;
      await tester.pumpWidget(_scene());
      expectBefore(tester);
    });

    testWidgets('battery saver or low RAM', (tester) async {
      FrostedBackdropPolicy.reducedPerformance.value = true;
      await tester.pumpWidget(_scene());
      expectBefore(tester);
    });

    testWidgets('reduced motion', (tester) async {
      await tester.pumpWidget(
        _scene(media: (data) => data.copyWith(disableAnimations: true)),
      );
      expectBefore(tester);
    });

    testWidgets('high contrast', (tester) async {
      await tester.pumpWidget(
        _scene(media: (data) => data.copyWith(highContrast: true)),
      );
      expectBefore(tester);
    });

    testWidgets('the policy flips live: same geometry, and what sits on a '
        'piece keeps its state', (tester) async {
      final text = TextEditingController(text: 'a medio escribir');
      addTearDown(text.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId('classic-dark'),
          home: Align(
            alignment: Alignment.topCenter,
            child: HermesGlassStrip(
              child: _Piece(
                key: _middle,
                width: 240,
                child: TextField(
                  key: const ValueKey('field'),
                  controller: text,
                  decoration: const InputDecoration.collapsed(hintText: ''),
                ),
              ),
            ),
          ),
        ),
      );
      final field = tester.state(find.byKey(const ValueKey('field')));
      final rect = tester.getRect(find.byKey(_middle));
      expect(_filters(tester), hasLength(1));
      FrostedBackdropPolicy.blurAllowed.value = false;
      await tester.pump();
      expect(_filters(tester), isEmpty);
      expect(tester.state(find.byKey(const ValueKey('field'))), same(field));
      expect(tester.getRect(find.byKey(_middle)), rect);
      FrostedBackdropPolicy.blurAllowed.value = true;
      await tester.pump();
      expect(_filters(tester), hasLength(1));
      expect(text.text, 'a medio escribir');
      expect(tester.getRect(find.byKey(_middle)), rect);
    });
  });
}
