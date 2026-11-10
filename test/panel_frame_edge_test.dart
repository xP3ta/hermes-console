import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart' show HermesChrome;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';

// A review capture: the pane's grey outline only wrapped the top strip and
// stopped dead where an opaque body began. The edge has to stay on top of
// the content all around, in light and dark, at every width.

const _body = Color(0xFFFF0000);

Future<ui.Image> _paint(
  WidgetTester tester,
  Size size,
  AppThemeMode mode,
) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.fromMode(mode),
      home: RepaintBoundary(
        key: key,
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: debugWorkspacePaneSurface(
              child: Column(
                children: [
                  const SizedBox(height: 60),
                  Expanded(child: ColoredBox(color: _body, child: Container())),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  late ui.Image image;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    image = await boundary.toImage();
  });
  return image;
}

Future<Color> _pixel(WidgetTester tester, ui.Image image, int x, int y) async {
  late ByteData data;
  await tester.runAsync(() async {
    data = (await image.toByteData())!;
  });
  final o = (y * image.width + x) * 4;
  return Color.fromARGB(
    data.getUint8(o + 3),
    data.getUint8(o),
    data.getUint8(o + 1),
    data.getUint8(o + 2),
  );
}

void main() {
  for (final mode in [AppThemeMode.dark, AppThemeMode.light]) {
    for (final size in const [
      Size(320, 640),
      Size(360, 800),
      Size(412, 915),
      Size(915, 412),
      Size(933, 704),
    ]) {
      testWidgets('$mode $size: the hairline runs the full height over an '
          'opaque body', (tester) async {
        final image = await _paint(tester, size, mode);
        final line = HermesChrome.of(AppTheme.fromMode(mode).hermes).line;
        // Pane left edge is at x=8; sample in the body region (below 60 dp
        // header) and at the bottom.
        for (final y in [100, size.height ~/ 2, size.height.toInt() - 40]) {
          final c = await _pixel(tester, image, 8, y);
          expect(
            c,
            isNot(_body),
            reason: 'edge covered by the body at y=$y',
          );
          // The hairline is translucent: the body shows through it, tinted.
          final want = Color.alphaBlend(line, _body);
          expect(
            (c.r - want.r).abs() + (c.g - want.g).abs() + (c.b - want.b).abs(),
            lessThan(0.1),
            reason: 'y=$y is not the edge over the body: $c vs $want',
          );
        }
        final right = await _pixel(tester, image, size.width.toInt() - 9, 100);
        expect(right, isNot(_body));
      });
    }
  }
}
