// OPUS-CRISTAL: the chat foot's smoked glass in a real Flutter raster, at
// component level (composer + context pill + the chat's current foot scrim,
// over real content). A is today (no strip), B the toned strip. It measures
// what the approved mock-up promised, on the engine's own pixels:
//
//  * perceptible: with an image and code behind, the composer's body shows
//    their colours and shapes; A stays one flat fill;
//  * ghost (the owner's limits for the chat's centres): with real text behind
//    both pieces, each pixel 5 dp inside the composer stays <= 1.1:1 and
//    inside the context pill <= 1.05:1 against the same frame without the
//    transcript's ink. A breach stays red. The scrim's own 1.6 contract
//    is chat_bottom_scrim_test's, not a substitute for these;
//  * AA: the hint keeps at least its ratio on the opaque chrome against every
//    pixel it can sit on (measured on an ink-free twin of the composer);
//  * focus and geometry: same rects A/B, focus kept, focus border painted;
//  * fallback: reduced motion and high contrast paint B exactly as A.
//
// Not ChatScreen: the binding belongs to ChatScreen. PNGs only with
// `--dart-define=GLASS_SHOTS=<dir>`.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/edges.dart' show HermesBottomScrim;
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/smoked_glass.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/session_context_usage.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart';

const _dir = String.fromEnvironment('GLASS_SHOTS');
const _shotKey = ValueKey('chat-foot-glass-shot');
const _footKey = ValueKey('chat-foot');
const _composer = ValueKey('hermes-composer-visible-surface');
const _capsule = ValueKey('status-pill-capsule');
const _size = Size(390, 844);

/// What passes behind the foot.
enum _Behind { image, text }

class _Fixture {
  final text = TextEditingController();
  final focus = FocusNode();
  final metrics = ValueNotifier(const SessionContextMetrics(percent: 45));

  /// [twinAt]: instead of the foot, a bare composer surface on that rect
  /// (the real composer's), so the pixels under the hint can be read
  /// without the hint itself.
  Widget page({
    required String themeId,
    required bool glass,
    required _Behind behind,
    required double footHeight,
    Rect? twinAt,
    bool transcriptInk = true,
    bool showFoot = true,
    bool reducedMotion = false,
    bool highContrast = false,
  }) {
    final theme = AppTheme.fromId(themeId);
    final colors = theme.hermes;
    final chrome = HermesChrome.of(colors);
    Widget foot = twinAt == null
        ? ConsoleComposer(
            controller: text,
            focusNode: focus,
            onSend: (_, _) {},
            footer: ChatStatusPill(
              metrics: metrics,
              onOpenContext: () {},
              modelLabel: 'Opus 5.5',
              onOpenModel: () {},
            ),
          )
        : const HermesComposerSurface(
            unfocusedHorizontalInset: 0,
            child: SizedBox.expand(),
          );
    if (glass) {
      foot = HermesGlassStrip(
        zone: FrostedZone.bottom,
        priority: 1,
        tone: HermesSmokedGlass.of(chrome),
        toneInks: HermesSmokedGlass.footInks(colors),
        child: foot,
      );
    }
    return RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reducedMotion,
            highContrast: highContrast,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              // The transcript runs under the foot, as in ChatScreen.
              Positioned.fill(
                child: _transcript(colors, behind, ink: transcriptInk),
              ),
              // The chat's foot scrim with its current geometry: exactly the
              // area of the bottom pieces (kept by ChatScreen's binding).
              if (footHeight > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: footHeight,
                  child: const HermesBottomScrim(),
                ),
              if (!showFoot)
                const SizedBox.shrink()
              else if (twinAt == null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: KeyedSubtree(key: _footKey, child: foot),
                )
              else
                Positioned.fromRect(rect: twinAt, child: foot),
            ],
          ),
        ),
      ),
    );
  }

  void dispose() {
    text.dispose();
    focus.dispose();
    metrics.dispose();
  }
}

/// [ink] false paints the transcript's words in the page colour: the same
/// layout with nothing to read, the control a ghost is measured against.
Widget _transcript(
  HermesThemeColors colors,
  _Behind behind, {
  bool ink = true,
}) {
  Widget line(String s) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      s,
      style: TextStyle(
        fontSize: 16,
        height: 1.45,
        color: ink ? colors.textPrimary : colors.background,
      ),
    ),
  );
  const prose =
      'Resumen actualizado: el consejo se reúne mañana, la agenda sigue '
      'abierta y las novedades de hoy quedan separadas de las recientes.';
  const codeInks = [
    Color(0xFF7FD1FF),
    Color(0xFFFFB86C),
    Color(0xFF9FE0A8),
    Color(0xFFFF79C6),
  ];
  // Reversed: the first child sits at the bottom of the screen, behind the
  // foot, as the newest content does in the chat.
  return ListView(
    reverse: true,
    physics: const NeverScrollableScrollPhysics(),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    children: [
      if (behind == _Behind.image) ...[
        // A bright, coloured image: the case the glass must show.
        Container(
          height: 260,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(
              colors: [
                Color(0xFFFFFFFF),
                Color(0xFFFFD27A),
                Color(0xFF3EA6FF),
                Color(0xFF0B3D2E),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        // Code: a dark block with coloured lines.
        Container(
          height: 120,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF16161F),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final ink in codeInks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SizedBox(
                    width: 200,
                    height: 7,
                    child: ColoredBox(color: ink),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
      ],
      for (var i = 0; i < 16; i++) line(prose),
    ],
  );
}

Future<ui.Image> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shotKey),
  );
  late ui.Image image;
  await tester.runAsync(() async {
    image = await boundary.toImage();
  });
  return image;
}

Future<ByteData> _bytes(WidgetTester tester, ui.Image image) async {
  late ByteData data;
  await tester.runAsync(() async {
    data = (await image.toByteData())!;
  });
  return data;
}

Future<void> _write(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shotKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(_dir).createSync(recursive: true);
    File('$_dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Color _at(ByteData data, int width, int x, int y) {
  final i = (y * width + x) * 4;
  return Color.fromARGB(
    255,
    data.getUint8(i),
    data.getUint8(i + 1),
    data.getUint8(i + 2),
  );
}

/// The composer's body, away from its rim and its rounded ends.
Rect _body(Rect composer) => Rect.fromLTRB(
  composer.left + composer.height / 2,
  composer.top + 4,
  composer.right - composer.height / 2,
  composer.bottom - 4,
);

/// The band of a composer's body above its text line, between its
/// controls: within [field] (the text field, between «+» and the primary
/// action), never across a button. A ROI that crossed the round send button
/// read its accent as "content" (measured: 179/215, and the rival's
/// 69,67,75 is 5 % of that accent at its anti-aliased edge).
Rect _band(Rect composer, Rect field) {
  final left = composer.left + composer.height / 2;
  final right = composer.right - composer.height / 2;
  return Rect.fromLTRB(
    left > field.left ? left : field.left,
    composer.top + 3,
    right < field.right ? right : field.right,
    composer.top + 9,
  );
}

/// The composer's text field, inside its visible surface.
Rect _field(WidgetTester tester) => tester.getRect(
  find.descendant(of: find.byKey(_composer), matching: find.byType(TextField)),
);

Iterable<Color> _pixelsIn(ByteData data, int width, Rect r) sync* {
  for (var y = r.top.ceil(); y < r.bottom.floor(); y++) {
    for (var x = r.left.ceil(); x < r.right.floor(); x++) {
      yield _at(data, width, x, y);
    }
  }
}

/// The largest per-channel spread (0..255) across [pixels].
int _spread(Iterable<Color> pixels) {
  final lo = [255, 255, 255];
  final hi = [0, 0, 0];
  for (final c in pixels) {
    final ch = [(c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round()];
    for (var i = 0; i < 3; i++) {
      if (ch[i] < lo[i]) lo[i] = ch[i];
      if (ch[i] > hi[i]) hi[i] = ch[i];
    }
  }
  return [
    for (var i = 0; i < 3; i++) hi[i] - lo[i],
  ].reduce((a, b) => a > b ? a : b);
}

/// A piece's rounded body, 5 dp inside its outline: the rim and the gaps
/// beside it are not the piece's centre.
RRect _mask(Rect piece) {
  final inner = piece.deflate(5);
  final radius = inner.shortestSide / 2;
  return RRect.fromRectAndRadius(
    inner,
    Radius.circular(radius < 23 ? radius : 23),
  );
}

/// The largest contrast, pixel by pixel inside [mask], between a frame and
/// its control without the transcript's ink. 1.0: nothing of it shows.
double _ghost(ByteData shown, ByteData control, int width, RRect mask) {
  var worst = 1.0;
  final r = mask.outerRect;
  for (var y = r.top.ceil(); y < r.bottom.floor(); y++) {
    for (var x = r.left.ceil(); x < r.right.floor(); x++) {
      if (!mask.contains(Offset(x + 0.5, y + 0.5))) continue;
      final ratio = ThemeContrast.ratio(
        _at(shown, width, x, y),
        _at(control, width, x, y),
      );
      if (ratio > worst) worst = ratio;
    }
  }
  return worst;
}

void main() {
  void resetPolicy() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
    FrostedBackdropPolicy.knownHighEnd.value = false;
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
  }

  setUp(() {
    resetPolicy();
    FrostedBackdropPolicy.knownHighEnd.value = true;
  });
  tearDown(resetPolicy);

  Future<void> pump(WidgetTester tester, Widget page) async {
    await loadDesignFonts();
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(page);
    await tester.pumpAndSettle();
  }

  /// The foot's height, measured once without a scrim (ChatScreen sizes
  /// the scrim from the bottom bars it measures).
  Future<double> footHeight(
    WidgetTester tester,
    _Fixture fixture,
    String themeId,
  ) async {
    await pump(
      tester,
      fixture.page(
        themeId: themeId,
        glass: false,
        behind: _Behind.image,
        footHeight: 0,
      ),
    );
    return tester.getRect(find.byKey(_footKey)).height;
  }

  for (final themeId in const ['classic-dark', 'classic']) {
    testWidgets('$themeId: image behind reads through B, A stays flat; '
        'geometry and focus kept', (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final foot = await footHeight(tester, fixture, themeId);
      final measures = <String, Object>{};
      for (final glass in [false, true]) {
        for (final focused in [false, true]) {
          await pump(
            tester,
            fixture.page(
              themeId: themeId,
              glass: glass,
              behind: _Behind.image,
              footHeight: foot,
            ),
          );
          if (focused) {
            fixture.focus.requestFocus();
            await tester.pumpAndSettle();
          } else {
            fixture.focus.unfocus();
            await tester.pumpAndSettle();
          }
          final tag = '${glass ? 'B' : 'A'}-${focused ? 'focus' : 'rest'}';
          measures['$tag-composer'] = tester.getRect(find.byKey(_composer));
          measures['$tag-field'] = _field(tester);
          measures['$tag-capsule'] = tester.getRect(find.byKey(_capsule));
          expect(fixture.focus.hasFocus, focused);
          final border =
              (tester
                              .widget<AnimatedContainer>(find.byKey(_composer))
                              .decoration!
                          as BoxDecoration)
                      .border!
                  as Border;
          expect(border.top.width, focused ? 1.15 : 1);
          final image = await _capture(tester);
          final data = await _bytes(tester, image);
          final composer = measures['$tag-composer']! as Rect;
          final field = measures['$tag-field']! as Rect;
          measures['$tag-spread'] = _spread(
            _pixelsIn(data, image.width, _band(composer, field)),
          );
          image.dispose();
          if (_dir.isNotEmpty) {
            await _write(tester, 'pie_${themeId}_imagen_$tag');
          }
        }
      }
      for (final state in ['rest', 'focus']) {
        expect(measures['B-$state-composer'], measures['A-$state-composer']);
        expect(measures['B-$state-capsule'], measures['A-$state-capsule']);
      }
      // A: one flat fill. B: the image's colour and shape come through the
      // part of the body no ink covers.
      expect(measures['A-rest-spread']! as int, lessThanOrEqualTo(3));
      expect(measures['B-rest-spread']! as int, greaterThanOrEqualTo(12));
      // ignore: avoid_print
      print('OPUS-CRISTAL $themeId band spread $measures');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$themeId: ghost of the text behind, per piece, against '
        'its control (owner: composer <= 1.1, context <= 1.05)', (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final foot = await footHeight(tester, fixture, themeId);
      // The stimulus is real: with no foot and no scrim, the transcript's
      // words are there under both pieces' rects.
      final composerRect = tester.getRect(find.byKey(_composer));
      final capsuleRect = tester.getRect(find.byKey(_capsule));
      final bare = <ByteData>[];
      for (final ink in [true, false]) {
        await pump(
          tester,
          fixture.page(
            themeId: themeId,
            glass: true,
            behind: _Behind.text,
            footHeight: 0,
            transcriptInk: ink,
            showFoot: false,
          ),
        );
        final image = await _capture(tester);
        bare.add(await _bytes(tester, image));
        image.dispose();
      }
      final width = _size.width.toInt();
      for (final (name, rect) in [
        ('composer', composerRect),
        ('capsule', capsuleRect),
      ]) {
        final stimulus = _ghost(bare[0], bare[1], width, _mask(rect));
        // ignore: avoid_print
        print(
          'OPUS-CRISTAL $themeId stimulus under $name '
          '${stimulus.toStringAsFixed(3)}',
        );
        expect(stimulus, greaterThan(3), reason: 'no text behind $name');
      }
      // A (today) and B (glass), each against its own control: same frame,
      // layout and foot, only the transcript's ink removed.
      for (final glass in [false, true]) {
        final shots = <ByteData>[];
        for (final ink in [true, false]) {
          await pump(
            tester,
            fixture.page(
              themeId: themeId,
              glass: glass,
              behind: _Behind.text,
              footHeight: foot,
              transcriptInk: ink,
            ),
          );
          final image = await _capture(tester);
          shots.add(await _bytes(tester, image));
          image.dispose();
          if (_dir.isNotEmpty && ink) {
            await _write(tester, 'pie_${themeId}_texto_${glass ? 'B' : 'A'}');
          }
        }
        final composer = tester.getRect(find.byKey(_composer));
        final capsule = tester.getRect(find.byKey(_capsule));
        final ghostComposer = _ghost(
          shots[0],
          shots[1],
          width,
          _mask(composer),
        );
        final ghostCapsule = _ghost(shots[0], shots[1], width, _mask(capsule));
        // ignore: avoid_print
        print(
          'OPUS-CRISTAL $themeId ${glass ? 'B' : 'A'} ghost composer '
          '${ghostComposer.toStringAsFixed(4)} capsule '
          '${ghostCapsule.toStringAsFixed(4)}',
        );
        // the owner's limits for the chat's centres. Not lowered to pass: a
        // breach stays red and goes to the report as such.
        expect(ghostComposer, lessThanOrEqualTo(1.1));
        expect(ghostCapsule, lessThanOrEqualTo(1.05));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$themeId: the hint keeps its ratio on every pixel under it', (
      tester,
    ) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final foot = await footHeight(tester, fixture, themeId);
      final colors = AppTheme.fromId(themeId).hermes;
      final chrome = HermesChrome.of(colors);
      final rect = tester.getRect(find.byKey(_composer));
      final floor = [
        ThemeContrast.ratio(colors.textSecondary, chrome.opaque),
        4.5,
      ].reduce((a, b) => a < b ? a : b);
      for (final behind in _Behind.values) {
        await pump(
          tester,
          fixture.page(
            themeId: themeId,
            glass: true,
            behind: behind,
            footHeight: foot,
            twinAt: rect,
          ),
        );
        final composer = tester.getRect(find.byKey(_composer));
        final image = await _capture(tester);
        final data = await _bytes(tester, image);
        var worst = double.infinity;
        for (final c in _pixelsIn(data, image.width, _body(composer))) {
          final r = ThemeContrast.ratio(colors.textSecondary, c);
          if (r < worst) worst = r;
        }
        image.dispose();
        // ignore: avoid_print
        print(
          'OPUS-CRISTAL $themeId ${behind.name} hint worst '
          '${worst.toStringAsFixed(3)} floor ${floor.toStringAsFixed(3)}',
        );
        // Strict: no rounding allowance. A raster under the floor stays red
        // and the recipe gets a margin; the threshold is never lowered.
        expect(worst, greaterThanOrEqualTo(floor));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('the first frame of a veto shows no content through the '
      'composer', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final foot = await footHeight(tester, fixture, 'classic-dark');
    await pump(
      tester,
      fixture.page(
        themeId: 'classic-dark',
        glass: true,
        behind: _Behind.image,
        footHeight: foot,
      ),
    );
    final composer = tester.getRect(find.byKey(_composer));
    final field = _field(tester);
    FrostedBackdropPolicy.reducedPerformance.value = true;
    await tester.pump();
    final image = await _capture(tester);
    final data = await _bytes(tester, image);
    final band = _pixelsIn(data, image.width, _band(composer, field)).toList();
    image.dispose();
    final opaque = HermesChrome.of(
      AppTheme.fromId('classic-dark').hermes,
    ).opaque;
    // Mid-easing fill over the opaque base: the opaque chrome, give or take
    // the static shadow under the box; never the image behind.
    expect(_spread(band), lessThanOrEqualTo(3));
    for (final c in band) {
      expect(
        ThemeContrast.ratio(c, opaque),
        lessThan(1.1),
        reason: '$c vs $opaque',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (name, reduced, contrast) in const [
    ('reduced motion', true, false),
    ('high contrast', false, true),
  ]) {
    testWidgets('$name: B paints exactly as A', (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final foot = await footHeight(tester, fixture, 'classic-dark');
      final shots = <Uint8List>[];
      for (final glass in [false, true]) {
        await pump(
          tester,
          fixture.page(
            themeId: 'classic-dark',
            glass: glass,
            behind: _Behind.image,
            footHeight: foot,
            reducedMotion: reduced,
            highContrast: contrast,
          ),
        );
        final image = await _capture(tester);
        final data = await _bytes(tester, image);
        shots.add(data.buffer.asUint8List());
        image.dispose();
      }
      expect(shots[1], orderedEquals(shots[0]));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
