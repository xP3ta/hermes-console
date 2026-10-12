// pm1215: the shared pill morph. Every transient surface that grows out of
// a pill opens as a container transform from the pill, follows the finger
// toward its edge, springs back short of the threshold and shrinks back
// INTO the pill when it closes, with no stuck frame. No ✕: swipe, outside
// tap, Back or the screen reader's dismiss action.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/pill_morph.dart';

const _surface = ValueKey('morph-surface');
final _pill = GlobalKey();
var _dismissCalls = 0;

Future<void> _pump(
  WidgetTester tester, {
  PillMorphEdge edge = PillMorphEdge.top,
  bool reduce = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Align(
            alignment: edge == PillMorphEdge.top
                ? const Alignment(0, -0.85)
                : const Alignment(0, 0.85),
            child: GestureDetector(
              key: _pill,
              onTap: () => Navigator.of(context).push(
                PillMorphRoute<void>(
                  reduceMotion: reduce,
                  dismissLabel: 'Cerrar',
                  builder: (ctx, animation) => PillMorphSurface(
                    animation: animation,
                    origin: () => pillMorphRectOf(_pill),
                    edge: edge,
                    color: Colors.white,
                    reduceMotion: reduce,
                    dismissLabel: 'Cerrar',
                    onDismiss: () {
                      _dismissCalls++;
                      Navigator.of(ctx).maybePop();
                    },
                    child: SizedBox(
                      key: _surface,
                      height: 300,
                      child: ListView(
                        children: [
                          for (var i = 0; i < 4; i++)
                            SizedBox(height: 40, child: Text('row $i')),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              child: const SizedBox(
                width: 160,
                height: 44,
                child: Center(child: Text('pill')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

RenderPillMorph _morph(WidgetTester tester) =>
    tester.renderObject<RenderPillMorph>(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_PillMorphLayout',
      ),
    );

Rect _pillRect(WidgetTester tester) => tester.getRect(find.byKey(_pill));

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(_pill));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

bool _near(Rect a, Rect b, [double tol = 1.5]) =>
    (a.left - b.left).abs() <= tol &&
    (a.top - b.top).abs() <= tol &&
    (a.right - b.right).abs() <= tol &&
    (a.bottom - b.bottom).abs() <= tol;

void main() {
  test('the morph curve is critically damped: fast start, no overshoot', () {
    const curve = kPillMorphCurve;
    expect(curve.transform(0), 0);
    expect(curve.transform(1), 1);
    var last = 0.0;
    for (var i = 1; i <= 100; i++) {
      final v = curve.transform(i / 100);
      expect(v, greaterThanOrEqualTo(last), reason: 'monotonic at $i');
      expect(v, lessThanOrEqualTo(1.0), reason: 'no overshoot at $i');
      last = v;
    }
    // Fast start (no ease-in that reads as a stuck frame).
    expect(curve.transform(0.1), greaterThan(0.15));
    expect(curve.flipped.transform(0.1), lessThan(0.05));
    expect(kPillMorphOpen.inMilliseconds, inInclusiveRange(250, 320));
    expect(kPillMorphClose.inMilliseconds, inInclusiveRange(250, 320));
  });

  testWidgets('opens out of the pill and lands under it', (tester) async {
    await _pump(tester);
    final pill = _pillRect(tester);
    await tester.tap(find.byKey(_pill));
    await tester.pump();
    final first = _morph(tester).currentRect;
    expect(_near(first, pill), isTrue, reason: 'frame 0 is the pill: $first');
    await tester.pump(const Duration(milliseconds: 100));
    final mid = _morph(tester).currentRect;
    expect(mid.width, greaterThan(pill.width + 10));
    await tester.pump(const Duration(milliseconds: 300));
    final open = _morph(tester).currentRect;
    expect(_near(open, _morph(tester).targetRect), isTrue);
    expect(open.top, greaterThanOrEqualTo(pill.bottom), reason: 'under pill');
    expect(find.byIcon(Icons.close_rounded), findsNothing);
  });

  testWidgets('closing shrinks back into the pill with no stuck frame', (
    tester,
  ) async {
    await _pump(tester);
    final pill = _pillRect(tester);
    await _open(tester);
    Navigator.of(tester.element(find.byKey(_surface))).pop();
    final rects = <Rect>[];
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(_surface).evaluate().isEmpty) break;
      rects.add(_morph(tester).currentRect);
    }
    expect(find.byKey(_surface), findsNothing, reason: 'closed in time');
    expect(rects.length, inInclusiveRange(10, 20));
    // Every frame moves (no stuck frame) until it is on the pill.
    for (var i = 1; i < rects.length; i++) {
      final moved =
          (rects[i].height - rects[i - 1].height).abs() +
          (rects[i].width - rects[i - 1].width).abs();
      final onPill = _near(rects[i - 1], pill, 3);
      expect(moved > 0.5 || onPill, isTrue, reason: 'frame $i stuck');
      expect(rects[i].height, lessThanOrEqualTo(rects[i - 1].height + 0.01));
    }
    // The ticker starts on the first frame after the pop; the next one has
    // already moved a visible amount (fast start, no ease-in).
    expect(rects[1].height, lessThan(300 - 15));
    expect(_near(rects.last, pill, 6), isTrue, reason: '${rects.last}');
  });

  testWidgets('a short drag follows the finger and springs back', (
    tester,
  ) async {
    await _pump(tester);
    await _open(tester);
    final open = _morph(tester).currentRect;
    final g = await tester.startGesture(tester.getCenter(find.byKey(_surface)));
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(0, -8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final dragged = _morph(tester).currentRect;
    // A panel under its pill rolls up: the top edge stays (it never covers
    // the pill), the bottom edge follows the finger.
    expect(dragged.top, open.top);
    expect(open.bottom - dragged.bottom, greaterThan(10));
    // Once the drag has started, the surface follows the finger 1:1.
    await g.moveBy(const Offset(0, -16));
    await tester.pump(const Duration(milliseconds: 16));
    final followed = _morph(tester).currentRect;
    expect(dragged.bottom - followed.bottom, closeTo(16, 0.01));
    await tester.pump(const Duration(milliseconds: 200));
    await g.up();
    await tester.pump();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(_surface), findsOneWidget, reason: 'still open');
    expect(_near(_morph(tester).currentRect, open), isTrue);
  });

  testWidgets('a swipe up past the threshold closes the top panel', (
    tester,
  ) async {
    await _pump(tester);
    await _open(tester);
    final pill = _pillRect(tester);
    await tester.timedDrag(
      find.byKey(_surface),
      const Offset(0, -160),
      const Duration(milliseconds: 300),
    );
    Rect? last;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(_surface).evaluate().isEmpty) break;
      last = _morph(tester).currentRect;
    }
    expect(find.byKey(_surface), findsNothing);
    // It lands on the pill, not where the finger left it.
    expect(_near(last!, pill, 6), isTrue, reason: '$last vs $pill');
  });

  testWidgets('a swipe down does not close the top panel', (tester) async {
    await _pump(tester);
    await _open(tester);
    await tester.timedDrag(
      find.byKey(_surface),
      const Offset(0, 160),
      const Duration(milliseconds: 300),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(_surface), findsOneWidget);
  });

  testWidgets('bottom sheet: swipe down closes, swipe up does not', (
    tester,
  ) async {
    await _pump(tester, edge: PillMorphEdge.bottom);
    await _open(tester);
    final open = _morph(tester).currentRect;
    expect(open.bottom, lessThanOrEqualTo(844));
    await tester.timedDrag(
      find.byKey(_surface),
      const Offset(0, -160),
      const Duration(milliseconds: 300),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(_surface), findsOneWidget);
    await tester.timedDrag(
      find.byKey(_surface),
      const Offset(0, 160),
      const Duration(milliseconds: 300),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('outside tap closes; inside tap does not', (tester) async {
    await _pump(tester);
    await _open(tester);
    await tester.tap(find.text('row 1'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_surface), findsOneWidget);
    await tester.tapAt(const Offset(20, 820));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('the screen reader can dismiss it (no visible ✕)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _dismissCalls = 0;
    await _pump(tester);
    await _open(tester);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    var node = tester.getSemantics(find.byKey(_surface));
    while (!node.getSemanticsData().hasAction(SemanticsAction.dismiss)) {
      node = node.parent!;
    }
    tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.dismiss,
    );
    expect(_dismissCalls, 1);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_surface), findsNothing);
    handle.dispose();
  });

  testWidgets('reduced motion: no geometry morph, only a fade', (tester) async {
    await _pump(tester, reduce: true);
    await tester.tap(find.byKey(_pill));
    await tester.pump();
    final first = _morph(tester).currentRect;
    expect(_near(first, _morph(tester).targetRect), isTrue);
    final fade = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_PillMorphLayout',
            ),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(fade.opacity, lessThan(1));
    await tester.pump(kPillMorphFade);
    expect(find.byKey(_surface), findsOneWidget);
  });
}
