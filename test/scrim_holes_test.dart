// OPUS-CRISTAL: the chat foot scrim leaves the smoked glass's still pieces
// alone (HermesScrimHoles), so their one blur takes the real content under
// them; the gaps keep the scrim, and without a frosting toned strip the
// scrim paints exactly as before. ChatScreen's wiring is out of scope.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderObject, RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/edges.dart' show HermesBottomScrim;
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/scrim_holes.dart';
import 'package:hermes_android/core/design/smoked_glass.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';

const _root = ValueKey('scrim-holes-root');
const _piece = ValueKey('scrim-holes-piece');
const _scrimHeight = 160.0;

/// A source that always says its holes are where they were published: the
/// scrim's clip alone, without a strip.
class _StillSource implements HermesScrimHoleSource {
  _StillSource(this.paths, this.scrimHolePass);
  final List<Path> paths;
  @override
  final RenderObject? scrimHolePass;
  @override
  List<Path>? scrimHolesNow() => paths;
}

/// [shared]: the ChatScreen wiring. The scrim sits inside the one foot
/// strip, behind the bars (Positioned.fill), so it shares the strip's
/// repaint boundary and is painted after the strip's filter. Otherwise the
/// scrim is the strip's sibling: another paint pass, fail-closed.
Widget _page({
  HermesScrimHoles? holes,
  bool strip = true,
  double lift = 24,
  bool scrimOwnPass = false,
  bool shared = false,
}) {
  final theme = AppTheme.fromId('classic-dark');
  final colors = theme.hermes;
  final chrome = HermesChrome.of(colors);
  const composer = Center(
    child: SizedBox(
      width: 300,
      height: 56,
      child: HermesComposerSurface(
        key: _piece,
        unfocusedHorizontalInset: 0,
        child: SizedBox.expand(),
      ),
    ),
  );
  return RepaintBoundary(
    key: _root,
    child: MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: ListView(
                children: [
                  for (var i = 0; i < 40; i++)
                    Container(
                      height: 36,
                      color: i.isEven ? Colors.white : colors.accent,
                    ),
                ],
              ),
            ),
            if (shared)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: _scrimHeight,
                child: HermesGlassStrip(
                  zone: FrostedZone.bottom,
                  priority: 1,
                  tone: HermesSmokedGlass.of(chrome),
                  toneInks: HermesSmokedGlass.footInks(colors),
                  scrimHoles: holes,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(child: HermesBottomScrim(holes: holes)),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: lift,
                        child: composer,
                      ),
                    ],
                  ),
                ),
              ),
            if (!shared)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: _scrimHeight,
                child: scrimOwnPass
                    ? RepaintBoundary(child: HermesBottomScrim(holes: holes))
                    : HermesBottomScrim(holes: holes),
              ),
            if (strip && !shared)
              Positioned(
                left: 0,
                right: 0,
                bottom: lift,
                child: HermesGlassStrip(
                  zone: FrostedZone.bottom,
                  priority: 1,
                  tone: HermesSmokedGlass.of(chrome),
                  toneInks: HermesSmokedGlass.footInks(colors),
                  scrimHoles: holes,
                  child: composer,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Shared-pass host whose one piece has [shape] (same rect whatever the
/// shape): for a contour that changes within the same bounds.
Widget _shapePage({HermesScrimHoles? holes, required OutlinedBorder shape}) {
  final theme = AppTheme.fromId('classic-dark');
  final colors = theme.hermes;
  final chrome = HermesChrome.of(colors);
  return RepaintBoundary(
    key: _root,
    child: MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: ListView(
                children: [
                  for (var i = 0; i < 40; i++)
                    Container(
                      height: 36,
                      color: i.isEven ? Colors.white : colors.accent,
                    ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: _scrimHeight,
              child: HermesGlassStrip(
                zone: FrostedZone.bottom,
                priority: 1,
                tone: HermesSmokedGlass.of(chrome),
                toneInks: HermesSmokedGlass.footInks(colors),
                scrimHoles: holes,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(child: HermesBottomScrim(holes: holes)),
                    Positioned(
                      left: 50,
                      bottom: 24,
                      width: 300,
                      height: 56,
                      child: HermesGlassPiece(
                        shape: shape,
                        child: Builder(
                          builder: (context) => ClipPath(
                            clipper: ShapeBorderClipper(shape: shape),
                            child: ColoredBox(
                              color:
                                  HermesGlassStrip.of(context)?.veil ??
                                  chrome.opaque,
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<Uint8List> _bytes(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_root),
  );
  late Uint8List bytes;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    bytes = data!.buffer.asUint8List();
    image.dispose();
  });
  return bytes;
}

/// A holes channel for one widget test. The tree is unmounted before the
/// channel is disposed, also when the test fails half-way, so a failure
/// never cascades into the next case as a used-after-dispose. Errors are
/// not swallowed: they propagate after the cleanup.
Future<void> _withHoles(
  WidgetTester tester,
  Future<void> Function(HermesScrimHoles holes) body,
) async {
  final holes = HermesScrimHoles();
  try {
    await body(holes);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    holes.dispose();
  }
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

  testWidgets('the holes notify only when their bounds change', (tester) async {
    final holes = HermesScrimHoles();
    addTearDown(holes.dispose);
    var told = 0;
    holes.addListener(() => told++);
    final a = Path()..addRect(const Rect.fromLTWH(10, 10, 40, 20));
    holes.publish([a]);
    holes.publish([Path()..addRect(const Rect.fromLTWH(10, 10, 40, 20))]);
    expect(told, 1);
    expect(holes.bounds, [const Rect.fromLTWH(10, 10, 40, 20)]);
    holes.clear();
    expect(told, 2);
    expect(holes.isEmpty, isTrue);
  });

  testWidgets('a frosting toned strip opens a hole 4 dp inside its still '
      'piece', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    await _withHoles(tester, (holes) async {
      await tester.pumpWidget(_page(holes: holes));
      await tester.pumpAndSettle();
      final piece = tester.getRect(find.byKey(_piece));
      expect(holes.bounds, hasLength(1));
      final hole = holes.bounds.single;
      final expected = piece.deflate(HermesScrimHoles.inset);
      expect(hole.left, closeTo(expected.left, 0.01));
      expect(hole.top, closeTo(expected.top, 0.01));
      expect(hole.right, closeTo(expected.right, 0.01));
      expect(hole.bottom, closeTo(expected.bottom, 0.01));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(holes.isEmpty, isTrue, reason: 'a strip that leaves clears them');
    });
  });

  testWidgets('a hole shows the content and the gaps keep the scrim', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    await _withHoles(tester, (holes) async {
      // No strip: the hole is published by hand, so only the scrim is read.
      await tester.pumpWidget(_page(holes: holes, strip: false));
      await tester.pumpAndSettle();
      final scrimmed = await _bytes(tester);
      const hole = Rect.fromLTWH(100, 700, 200, 40);
      final paths = [Path()..addRect(hole)];
      final pass = hermesPaintPass(
        tester.renderObject(find.byType(HermesBottomScrim)),
      );
      holes.publish(paths, source: _StillSource(paths, pass));
      await tester.pump();
      final holed = await _bytes(tester);
      int at(Uint8List b, int x, int y) => (y * 400 + x) * 4;
      final inside = at(holed, 200, 720);
      final outside = at(holed, 50, 720);
      expect(
        holed.sublist(outside, outside + 3),
        scrimmed.sublist(outside, outside + 3),
        reason: 'a gap keeps the scrim',
      );
      expect(
        holed.sublist(inside, inside + 3),
        isNot(scrimmed.sublist(inside, inside + 3)),
        reason: 'the hole lets the content through',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // Review: the first paint of a veto must already be the frame of
  // before; the holes' own callback comes a frame later.
  testWidgets('the first paint of a veto is the frame of before, byte for '
      'byte', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    Future<Uint8List> firstVetoFrame(HermesScrimHoles? holes) async {
      FrostedBackdropPolicy.reducedPerformance.value = false;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_page(holes: holes, shared: true));
      await tester.pumpAndSettle();
      if (holes != null) expect(holes.isEmpty, isFalse);
      FrostedBackdropPolicy.reducedPerformance.value = true;
      await tester.pump();
      return _bytes(tester);
    }

    await _withHoles(tester, (holes) async {
      final withChannel = await firstVetoFrame(holes);
      final without = await firstVetoFrame(null);
      expect(withChannel, orderedEquals(without));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_page(holes: holes, shared: true));
      await tester.pumpAndSettle();
      expect(holes.isEmpty, isTrue, reason: 'closed after the veto settles');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('the first paint after a piece moves cuts no stale hole', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    Future<Uint8List> firstMovedFrame(HermesScrimHoles? holes) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_page(holes: holes, shared: true));
      await tester.pumpAndSettle();
      if (holes != null) expect(holes.isEmpty, isFalse);
      // The piece moves up 16 dp; its old hole would hang below it.
      await tester.pumpWidget(_page(holes: holes, lift: 40, shared: true));
      return _bytes(tester);
    }

    await _withHoles(tester, (holes) async {
      final before = await firstMovedFrame(holes);
      final moved = await firstMovedFrame(null);
      // That very paint is the scene without holes: no stale hole anywhere.
      expect(before, orderedEquals(moved));
      // Once the piece stays, the hole opens at its new place.
      await tester.pumpWidget(const SizedBox.shrink());
      // The shared host: the piece moves inside the strip, which repaints
      // and publishes; a sibling strip moved whole would not (fail-closed).
      await tester.pumpWidget(_page(holes: holes, shared: true));
      await tester.pumpAndSettle();
      final at24 = holes.bounds.single;
      await tester.pumpWidget(_page(holes: holes, lift: 40, shared: true));
      await tester.pumpAndSettle();
      expect(holes.bounds.single.top, closeTo(at24.top - 16, 0.01));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('a scrim painted in another pass never cuts a hole', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    await _withHoles(tester, (holes) async {
      await tester.pumpWidget(_page(holes: holes, scrimOwnPass: true));
      await tester.pumpAndSettle();
      // The strip publishes, but a cached scrim layer could keep a stale
      // hole: fail-closed, the scrim stays whole.
      expect(holes.isEmpty, isFalse);
      final withChannel = await _bytes(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_page(scrimOwnPass: true));
      await tester.pumpAndSettle();
      expect(withChannel, orderedEquals(await _bytes(tester)));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // Review: the automatic opening must cut in the shared pass, not only
  // be published. Same scene with and without the channel: the piece's
  // inside differs (its blur now frosts content without scrim), the gaps
  // are identical.
  testWidgets('in the shared pass the automatic hole really cuts', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    await _withHoles(tester, (holes) async {
      await tester.pumpWidget(_page(holes: holes, shared: true));
      await tester.pumpAndSettle();
      expect(holes.bounds, hasLength(1));
      final piece = tester.getRect(find.byKey(_piece));
      final withHoles = await _bytes(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_page(shared: true));
      await tester.pumpAndSettle();
      final without = await _bytes(tester);
      int at(int x, int y) => (y * 400 + x) * 4;
      final inside = at(piece.center.dx.round(), piece.center.dy.round());
      final gap = at(20, piece.center.dy.round());
      expect(
        withHoles.sublist(inside, inside + 3),
        isNot(without.sublist(inside, inside + 3)),
        reason: 'the hole is cut: the piece frosts content, not scrim',
      );
      expect(
        withHoles.sublist(gap, gap + 3),
        without.sublist(gap, gap + 3),
        reason: 'beside the piece the scrim is unchanged',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // Git, OPUS-SCRIM-CONTOUR-FRESHNESS-1: a piece whose contour changes
  // within the same bounds (rectangular to bevelled) must not keep the old
  // rectangular hole: its first paint cuts the live outline only.
  testWidgets('a contour changed within the same bounds cuts no old corner', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    const square = RoundedRectangleBorder();
    final bevel = BeveledRectangleBorder(
      borderRadius: BorderRadius.circular(20),
    );
    var published = const <Rect>[];
    Future<Uint8List> firstBevelFrame(HermesScrimHoles? holes) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_shapePage(holes: holes, shape: square));
      await tester.pumpAndSettle();
      if (holes != null) {
        expect(holes.bounds, hasLength(1));
        published = holes.bounds;
      }
      await tester.pumpWidget(_shapePage(holes: holes, shape: bevel));
      return _bytes(tester);
    }

    await _withHoles(tester, (holes) async {
      final withChannel = await firstBevelFrame(holes);
      expect(holes.bounds, published, reason: 'same bounds, no new publish');
      final without = await firstBevelFrame(null);
      // The piece spans x 50..350, y 720..776. (56, 726) is inside the old
      // square hole (4 dp in) but outside the 20 dp bevel: scrim there.
      int at(int x, int y) => (y * 400 + x) * 4;
      final corner = at(56, 726);
      final centre = at(200, 748);
      expect(
        withChannel.sublist(corner, corner + 3),
        without.sublist(corner, corner + 3),
        reason: 'no old corner cut outside the bevelled piece',
      );
      expect(
        withChannel.sublist(centre, centre + 3),
        isNot(without.sublist(centre, centre + 3)),
        reason: 'the live bevelled hole still cuts',
      );
    });
  });
}
