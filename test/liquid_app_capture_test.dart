// Opt-in evidence from ThemesScreen, a production screen with its real rows.
// No mocked glass scene and no screenshot from the old isolated prototype.
// Writes frame sequences only after the test lane is explicitly released.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/design/modal.dart';
import 'package:hermes_android/core/screens/themes_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart';

const _run = bool.fromEnvironment('RUN_LIQUID_APP_CAPTURE');
final _out = Platform.environment['LIQUID_APP_CAPTURE_DIR'];

enum _Mode { chrome, glass, painted, liquid }

bool _shaderPainted(WidgetTester tester) => find
    .byType(HermesGlassPiece)
    .evaluate()
    .any(HermesGlassStrip.debugShaderActive);

Future<List<int>> _frame(
  WidgetTester tester,
  GlobalKey root,
  Directory dir,
  int index,
  Rect sample,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(root));
  final result = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${dir.path}/frame_${index.toString().padLeft(3, '0')}.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());
      final raw = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final pixels = <int>[];
      for (
        var y = math.max(0, sample.top.floor());
        y < math.min(image.height, sample.bottom.ceil());
        y++
      ) {
        for (
          var x = math.max(0, sample.left.floor());
          x < math.min(image.width, sample.right.ceil());
          x++
        ) {
          final at = (y * image.width + x) * 4;
          pixels.addAll([
            raw.getUint8(at),
            raw.getUint8(at + 1),
            raw.getUint8(at + 2),
          ]);
        }
      }
      return pixels;
    } finally {
      image.dispose();
    }
  });
  return result!;
}

void main() {
  tearDown(() {
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
    FrostedBackdropPolicy.knownHighEnd.value = false;
  });
  for (final size in [const Size(412, 915), const Size(884, 1000)]) {
    for (final theme in ['classic-dark', 'classic']) {
      for (final mode in _Mode.values) {
        testWidgets(
          'app capture $size $theme ${mode.name}',
          (tester) async {
            await loadDesignFonts();
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            FrostedBackdropPolicy.blurAllowed.value = true;
            FrostedBackdropPolicy.reducedPerformance.value = false;
            FrostedBackdropPolicy.knownHighEnd.value = true;
            FrostedBackdropPolicy.liquidGpuValidated.value =
                mode == _Mode.liquid;
            FrostedBackdropPolicy.effectCeiling.value = switch (mode) {
              _Mode.chrome => HermesGlassTier.chrome,
              _Mode.glass => HermesGlassTier.glass,
              _ => HermesGlassTier.liquid,
            };
            final root = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: root,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: AppTheme.fromId(theme),
                  locale: const Locale('es'),
                  localizationsDelegates: Strings.localizationsDelegates,
                  supportedLocales: Strings.supportedLocales,
                  home: const ThemesScreen(),
                ),
              ),
            );
            await tester.pumpAndSettle();
            if (mode == _Mode.liquid) {
              expect(await tester.runAsync(HermesLiquidShader.load), isNotNull);
              await tester.pump();
            }
            final bar = tester.getRect(find.byType(HermesAppBar));
            // The page name is a pill on some pages and plain text on others
            // (ThemesScreen): sample under whichever the bar paints.
            final pill = find.byKey(const ValueKey('hermes-app-bar-title'));
            final title = tester.getRect(
              pill.evaluate().isNotEmpty
                  ? pill
                  : find.byKey(const ValueKey('hermes-app-bar-plain-title')),
            );
            final sample = Rect.fromLTWH(
              title.left + 16,
              title.bottom - 10,
              math.max(1, title.width - 32),
              3,
            );
            final scroll = tester
                .state<ScrollableState>(
                  find
                      .descendant(
                        of: find.byType(ListView).first,
                        matching: find.byType(Scrollable),
                      )
                      .first,
                )
                .position;
            // The sweep below scrolls from 120 to 390 dp: the page must be
            // longer than that (it is ~490-506 dp now that Themes is shorter).
            expect(scroll.maxScrollExtent, greaterThan(400));
            final dir = Directory(
              '$_out/themes_${size.width.toInt()}_${theme}_${mode.name}',
            )..createSync(recursive: true);
            final records = <Map<String, Object?>>[];
            List<int>? first;
            var changed = 0;
            for (var i = 0; i < 16; i++) {
              scroll.jumpTo(120.0 + i * 18);
              await tester.pump(const Duration(milliseconds: 33));
              expect(tester.getRect(find.byType(HermesAppBar)), bar);
              expect(tester.takeException(), isNull);
              final pixels = await _frame(tester, root, dir, i, sample);
              first ??= pixels;
              changed += [
                for (var j = 0; j < pixels.length; j++)
                  if (pixels[j] != first[j]) 1,
              ].length;
              final shader = _shaderPainted(tester);
              if (mode == _Mode.liquid) {
                expect(
                  shader,
                  isTrue,
                  reason:
                      'a requested-but-failed shader is not liquid evidence',
                );
              }
              records.add({
                'frame': i,
                'scrollPixels': scroll.pixels,
                'shaderActuallyPainted': shader,
                'filterLayers': tester.layers
                    .whereType<BackdropFilterLayer>()
                    .length,
              });
            }
            if (mode != _Mode.chrome) {
              expect(
                changed,
                greaterThan(0),
                reason:
                    'pixels INSIDE a fixed header change with the real page behind',
              );
            }
            unawaited(
              showHermesDialog<bool>(
                context: tester.element(find.byType(ThemesScreen)),
                title: 'Aplicar tema',
                message: 'Contenido real de Temas detrás del diálogo.',
                actions: const [
                  HermesDialogAction(label: 'Volver', value: false),
                ],
              ),
            );
            for (var i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 70));
              expect(tester.takeException(), isNull);
              await _frame(tester, root, dir, 16 + i, sample);
            }
            File('${dir.path}/evidence.json').writeAsStringSync(
              jsonEncode({
                'screen': 'ThemesScreen',
                'mode': mode.name,
                'theme': theme,
                'logicalWidth': size.width,
                'logicalHeight': size.height,
                'capturePixelRatio': 1,
                'samplesChangedInsideHeader': changed,
                'minScrollExtent': scroll.minScrollExtent,
                'maxScrollExtent': scroll.maxScrollExtent,
                'gpuCertified': false,
                'frames': records,
              }),
            );
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
          },
          tags: 'opt-in',
          skip:
              !_run ||
              _out == null ||
              _out!.isEmpty ||
              (mode == _Mode.liquid && !ui.ImageFilter.isShaderFilterSupported),
        );
      }
    }
  }
}
