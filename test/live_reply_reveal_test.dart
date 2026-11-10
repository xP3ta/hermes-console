import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat/live_reply_reveal.dart';

import 'support/design_shots.dart' show loadDesignFonts;

Widget _host(
  Widget child, {
  bool reduced = false,
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Directionality(
      textDirection: direction,
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 320, child: child),
        ),
      ),
    ),
  ),
);

LiveReplyReveal _reply(String source, {bool enabled = true, Key? textKey}) =>
    LiveReplyReveal(
      key: const ValueKey('reply'),
      revision: source,
      enabled: enabled,
      child: RichText(
        key: textKey,
        text: TextSpan(
          text: source,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 16,
            height: 1.5,
            color: Colors.white,
          ),
        ),
      ),
    );

RenderLiveReplyReveal _render(WidgetTester tester) =>
    tester.renderObject<RenderLiveReplyReveal>(find.byType(LiveReplyReveal));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(warmLiveReplyShader);

  testWidgets('aligned descendant transforms are measured after layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        LiveReplyReveal(
          revision: 'transformed',
          child: Transform.scale(
            scale: 0.98,
            alignment: Alignment.center,
            child: const Text(
              'Un bloque de código que ya compuso su geometría.',
            ),
          ),
        ),
      ),
    );
    final render = _render(tester);
    final geometry = render.geometryBuilds;
    expect(geometry, 1);
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(render.geometryBuilds, geometry);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    expect(
      render.visibleText,
      'Un bloque de código que ya compuso su geometría.',
    );
    expect(debugActiveLiveReplyClocks, 0);
  });

  testWidgets(
    'frames reveal composed text without rebuilding or re-reading the prefix',
    (tester) async {
      var builds = 0;
      final source = 'Una respuesta con un prefijo estable. ' * 100;
      await tester.pumpWidget(
        _host(
          LiveReplyReveal(
            revision: source,
            child: Builder(
              builder: (context) {
                builds++;
                return RichText(
                  text: TextSpan(
                    text: source,
                    style: const TextStyle(fontSize: 16, color: Colors.white),
                  ),
                );
              },
            ),
          ),
        ),
      );
      final render = _render(tester);
      final geometry = render.geometryBuilds;
      expect(render.revealedEnd, 0);
      expect(debugActiveLiveReplyClocks, 1);
      var previous = 0;
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 8));
        expect(render.revealedEnd, greaterThanOrEqualTo(previous));
        previous = render.revealedEnd;
        expect(builds, 1, reason: 'no Markdown/widget build per display tick');
        expect(
          render.geometryBuilds,
          geometry,
          reason: 'cached glyph geometry',
        );
      }
      expect(render.revealedEnd, greaterThan(0));
      expect(render.revealedEnd, lessThan(source.length));
      await tester.pumpAndSettle();
      expect(render.visibleText, source);
      expect(debugActiveLiveReplyClocks, 0);
    },
  );

  testWidgets(
    'a long first frame retains its elapsed time and the clock then stops',
    (tester) async {
      final source = 'palabra ' * 100;
      await tester.pumpWidget(_host(_reply(source)));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_render(tester).visibleText, source);
      await tester.pumpAndSettle();
      expect(debugActiveLiveReplyClocks, 0);
    },
  );

  testWidgets('height grows between frames without re-laying the text out', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_reply('palabra ' * 200)));
    final render = _render(tester);
    final full = render.child!.size.height;
    var previous = render.size.height;
    var intermediate = false;
    for (var frame = 0; frame < 100 && !render.settled; frame++) {
      await tester.pump(const Duration(milliseconds: 8));
      expect(render.size.height, greaterThanOrEqualTo(previous - 0.01));
      if (render.size.height > 0 && render.size.height < full) {
        intermediate = true;
      }
      previous = render.size.height;
    }
    expect(intermediate, isTrue);
    await tester.pumpAndSettle();
    expect(render.size.height, full);
    expect(debugActiveLiveReplyClocks, 0);
  });

  testWidgets(
    'reduced motion and a paused reader show everything immediately',
    (tester) async {
      final source = 'texto recibido ' * 100;
      await tester.pumpWidget(_host(_reply(source), reduced: true));
      expect(_render(tester).visibleText, source);
      expect(_render(tester).size.height, _render(tester).child!.size.height);
      expect(debugActiveLiveReplyClocks, 0);
      await tester.pumpWidget(_host(_reply('$source nuevo', enabled: false)));
      expect(_render(tester).visibleText, '$source nuevo');
      expect(debugActiveLiveReplyClocks, 0);
      await tester.pumpWidget(_host(_reply('$source nuevo', enabled: true)));
      expect(_render(tester).visibleText, '$source nuevo');
      expect(_render(tester).size.height, _render(tester).child!.size.height);
    },
  );

  testWidgets('Unicode and mixed RTL stay on real grapheme boundaries', (
    tester,
  ) async {
    const source = 'مرحبا 👩‍👩‍👧‍👦 بالعالم Flutter 🇪🇸 á\nنص آخر';
    final boundaries = <int>{0};
    var end = 0;
    for (final cluster in source.characters) {
      end += cluster.length;
      boundaries.add(end);
    }
    await tester.pumpWidget(
      _host(_reply(source), direction: TextDirection.rtl),
    );
    final render = _render(tester);
    for (var frame = 0; frame < 80 && !render.settled; frame++) {
      await tester.pump(const Duration(milliseconds: 8));
      expect(boundaries, contains(render.revealedEnd));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    expect(render.visibleText, source);
  });

  testWidgets(
    'reenabling also shows the full height of text received before the next layout',
    (tester) async {
      await tester.pumpWidget(_host(_reply('texto corto', enabled: false)));
      final source = List.filled(
        10,
        'Una línea recibida mientras no se pintaba.',
      ).join('\n');
      await tester.pumpWidget(_host(_reply(source)));
      final render = _render(tester);
      expect(render.visibleText, source);
      expect(
        render.size.height,
        render.child!.size.height,
        reason: 'skipping replay applies to height as well as to glyphs',
      );
      expect(debugActiveLiveReplyClocks, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final direction in TextDirection.values) {
    for (final table in [false, true]) {
      testWidgets(
        'completed sibling stays painted in ${table ? 'table' : 'row'} $direction',
        (tester) async {
          const first = ValueKey('cell-a');
          const second = ValueKey('cell-b');
          Widget cell(String text, Key key) => RichText(
            key: key,
            textDirection: direction,
            text: TextSpan(
              text: text,
              style: const TextStyle(fontSize: 14, color: Colors.white),
            ),
          );
          final cells = [cell('TEXTO A', first), cell('TEXTO B', second)];
          final child = table
              ? Table(
                  textDirection: direction,
                  children: [TableRow(children: cells)],
                )
              : Row(textDirection: direction, children: cells);
          await tester.pumpWidget(
            _host(
              LiveReplyReveal(revision: 'cells', child: child),
              direction: direction,
            ),
          );
          final render = _render(tester);
          final geometry = render.geometryBuilds;
          final a = tester.getRect(find.byKey(first));
          final b = tester.getRect(find.byKey(second));
          final leading = a;
          expect(
            direction == TextDirection.rtl ? a.left > b.left : a.left < b.left,
            isTrue,
          );
          for (var frame = 0; frame < 30 && render.revealedEnd <= 8; frame++) {
            await tester.pump(const Duration(milliseconds: 8));
          }
          expect(render.revealedEnd, greaterThan(8));
          expect(
            render.visibleText,
            startsWith('TEXTO A\n'),
            reason: 'logical child order survives both RTL and LTR layout',
          );
          expect(
            render.visibleText.length,
            lessThan('TEXTO A\nTEXTO B'.length),
          );
          final origin = tester.getTopLeft(find.byType(LiveReplyReveal));
          expect(
            render.paintsPosition(
              leading.topLeft - origin + const Offset(7, 7),
            ),
            isTrue,
            reason: 'the completed sibling remains in the clip at the same Y',
          );
          expect(
            render.geometryBuilds,
            geometry,
            reason: 'no prefix layout or scan on ticks',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpAndSettle();
        },
      );
    }
  }

  testWidgets('two appends during a fade never dim already painted glyphs', (
    tester,
  ) async {
    var source = 'abcdef';
    await tester.pumpWidget(_host(_reply(source)));
    final render = _render(tester);
    for (var frame = 0; frame < 30 && render.visibleText != source; frame++) {
      await tester.pump(const Duration(milliseconds: 8));
    }
    await tester.pump(const Duration(milliseconds: 52));
    for (var arrival = 0; arrival < 2; arrival++) {
      final before = render.tailOpacities;
      expect(before, isNotEmpty);
      expect(
        before.values.any((opacity) => opacity > 0 && opacity < 1),
        isTrue,
      );
      source += 'ghijklmnopqrstuv';
      await tester.pumpWidget(_host(_reply(source)));
      final after = render.tailOpacities;
      for (final entry in before.entries) {
        expect(
          after[entry.key] ?? 1,
          greaterThanOrEqualTo(entry.value),
          reason: 'arrival $arrival, grapheme ending at ${entry.key}',
        );
      }
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pumpAndSettle();
    expect(render.visibleText, source);
    expect(tester.takeException(), isNull);
    expect(debugActiveLiveReplyClocks, 0);
  });

  testWidgets('removal or backgrounding leaves no animation clock', (
    tester,
  ) async {
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await tester.pumpWidget(_host(_reply('burst ' * 500)));
    expect(debugActiveLiveReplyClocks, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(debugActiveLiveReplyClocks, 0);
    expect(_render(tester).visibleText, 'burst ' * 500);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(debugActiveLiveReplyClocks, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(debugActiveLiveReplyClocks, 0);
  });

  testWidgets('loaded shader survives repeated active paints and removal', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_reply('cola ' * 300)));
    final render = _render(tester);
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump(const Duration(milliseconds: 8));
      expect(
        render.usesTailShader,
        isTrue,
        reason:
            'loaded shader required, frame=$frame end=${render.revealedEnd} '
            'alpha=${render.tailOpacities.length} settled=${render.settled}',
      );
      expect(tester.takeException(), isNull);
    }
    expect(debugActiveLiveReplyClocks, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(debugActiveLiveReplyClocks, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the reply does not create a live semantics region per fragment',
    (tester) async {
      final semantics = tester.ensureSemantics();
      const text = ValueKey('reply-text');
      await tester.pumpWidget(_host(_reply('respuesta ' * 50, textKey: text)));
      await tester.pump(const Duration(milliseconds: 32));
      final node = tester.getSemantics(find.byKey(text));
      expect(node.flagsCollection.isLiveRegion, isFalse);
      await tester.pumpAndSettle();
      semantics.dispose();
    },
  );

  testWidgets('Q9SUAVE three intermediate painted frames', (tester) async {
    await tester.runAsync(loadDesignFonts);
    await tester.binding.setSurfaceSize(const Size(320, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const boundary = ValueKey('capture');
    await tester.pumpWidget(
      _host(
        RepaintBoundary(
          key: boundary,
          child: SizedBox(
            width: 320,
            height: 360,
            child: ColoredBox(
              color: const Color(0xff202024),
              child: Align(
                alignment: Alignment.topLeft,
                child: _reply(
                  'El texto aparece con rapidez, sin rehacer el prefijo. ' * 10,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    var previous = 0;
    for (final at in [60, 100, 180]) {
      while (previous < at) {
        final step = (at - previous).clamp(0, 8);
        await tester.pump(Duration(milliseconds: step));
        previous += step;
      }
      await expectLater(
        find.byKey(boundary),
        matchesGoldenFile('goldens/q9_reply_$at.png'),
      );
    }
    await tester.pumpAndSettle();
  });

  testWidgets(
    'first append frame after a settled prefix never exposes the new suffix',
    (tester) async {
      await tester.runAsync(loadDesignFonts);
      const capture = ValueKey('append-capture');
      Widget scene(String source) => _host(
        RepaintBoundary(
          key: capture,
          child: SizedBox(
            width: 320,
            height: 60,
            child: ColoredBox(
              color: const Color(0xff202024),
              child: Align(alignment: Alignment.topLeft, child: _reply(source)),
            ),
          ),
        ),
      );
      Future<String> pixels() async => (await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final frame = await boundary.toImage(pixelRatio: 1);
        final bytes = await frame.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        frame.dispose();
        return sha256.convert(bytes!.buffer.asUint8List()).toString();
      }))!;
      const prefix = 'Hola';
      const complete = 'Hola texto nuevo final';
      await tester.pumpWidget(scene(prefix));
      await tester.pumpAndSettle();
      final before = await pixels();
      expect(_render(tester).settled, isTrue);
      await tester.pumpWidget(scene(complete));
      final firstArrival = await pixels();
      expect(
        firstArrival,
        before,
        reason:
            'the scene already painted by pumpWidget must keep only the settled prefix',
      );
      final geometry = _render(tester).geometryBuilds;
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        await pixels(),
        isNot(before),
        reason: 'the next display frame can reveal/fade new glyphs',
      );
      expect(_render(tester).geometryBuilds, geometry);
      await tester.pumpAndSettle();
      expect(_render(tester).visibleText, complete);
      expect(debugActiveLiveReplyClocks, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
