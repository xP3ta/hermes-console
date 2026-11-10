// Run explicitly with Impeller (opt-in).
// These tests require an actually painted shader before checking its fallback.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';

import 'support/liquid_motion_fixture.dart';

const _run = bool.fromEnvironment('RUN_LIQUID_SHADER_CAPTURE');
final _skip = !_run || !ui.ImageFilter.isShaderFilterSupported;

Widget _strip(
  int count, {
  OutlinedBorder shape = const StadiumBorder(),
  Widget? child,
}) => HermesGlassStrip(
  liquid: HermesLiquid.header,
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < count; i++)
        Builder(
          builder: (context) => HermesGlassPiece(
            key: ValueKey('shape-$i'),
            shape: shape,
            child: ColoredBox(
              color: HermesGlassStrip.of(context)!.veil,
              child: SizedBox(
                width: count == 1 ? 220 : 44,
                height: 44,
                child: child,
              ),
            ),
          ),
        ),
    ],
  ),
);

Widget _host(
  Widget child, {
  GlobalKey? root,
  GlobalKey<NavigatorState>? navigator,
}) => RepaintBoundary(
  key: root,
  child: MaterialApp(
    navigatorKey: navigator,
    theme: AppTheme.fromId('classic-dark'),
    home: Scaffold(
      backgroundColor: Colors.white,
      body: Center(child: child),
    ),
  ),
);

bool _shader(WidgetTester tester) => HermesGlassStrip.debugShaderActive(
  tester.element(find.byKey(const ValueKey('shape-0'))),
);

void main() {
  setUp(() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
    FrostedBackdropPolicy.liquidGpuValidated.value = true;
    FrostedBackdropPolicy.knownHighEnd.value = true;
  });
  tearDown(() {
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
    FrostedBackdropPolicy.knownHighEnd.value = false;
  });

  for (final shape in [const StadiumBorder(), const BeveledRectangleBorder()]) {
    final count = shape is StadiumBorder ? 6 : 1;
    testWidgets(
      '$count $shape: every unsupported piece retains its veil pixels',
      (tester) async {
        final root = GlobalKey();
        expect(await tester.runAsync(HermesLiquidShader.load), isNotNull);
        await tester.pumpWidget(_host(_strip(count, shape: shape), root: root));
        await tester.pump();
        expect(_shader(tester), isFalse);
        expect(tester.layers.whereType<BackdropFilterLayer>(), hasLength(1));
        final centers = [
          for (var i = 0; i < count; i++)
            tester.getCenter(find.byKey(ValueKey('shape-$i'))),
        ];
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(root),
        );
        final colors = AppTheme.fromId('classic-dark').hermes;
        final ink = HermesChrome.of(colors).ink;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            for (final center in centers) {
              final at =
                  (center.dy.floor() * image.width + center.dx.floor()) * 4;
              final under = Color.fromARGB(
                255,
                bytes.getUint8(at),
                bytes.getUint8(at + 1),
                bytes.getUint8(at + 2),
              );
              expect(
                ThemeContrast.ratio(ink, under),
                greaterThanOrEqualTo(4.5),
              );
            }
          } finally {
            image.dispose();
          }
        });
      },
      tags: 'opt-in',
      skip: _skip,
    );
  }

  testWidgets(
    'ancestor motion suspends actual shader without losing draft state',
    (tester) async {
      final moving = ValueNotifier(false);
      final text = TextEditingController(text: 'borrador');
      addTearDown(moving.dispose);
      addTearDown(text.dispose);
      const field = ValueKey('draft');
      await tester.pumpWidget(
        _host(
          ValueListenableBuilder<bool>(
            valueListenable: moving,
            child: _strip(
              1,
              child: TextField(key: field, controller: text),
            ),
            builder: (_, value, child) =>
                HermesLiquidMotion(moving: value, child: child!),
          ),
        ),
      );
      expect(await tester.runAsync(HermesLiquidShader.load), isNotNull);
      await tester.pump();
      expect(_shader(tester), isTrue);
      final state = tester.state(find.byKey(field));
      final rect = tester.getRect(find.byKey(field));
      moving.value = true;
      await tester.pump();
      expect(_shader(tester), isFalse);
      expect(
        HermesGlassStrip.of(
          tester.element(find.byKey(const ValueKey('shape-0'))),
        )!.veil.a,
        greaterThan(0),
      );
      expect(tester.state(find.byKey(field)), same(state));
      expect(tester.getRect(find.byKey(field)), rect);
      expect(text.text, 'borrador');
      moving.value = false;
      await tester.pump();
      expect(_shader(tester), isTrue);
      expect(tester.state(find.byKey(field)), same(state));
    },
    tags: 'opt-in',
    skip: _skip,
  );

  testWidgets(
    'push and pop use protected veil through intermediate route frames',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_host(_strip(1), navigator: navigator));
      expect(await tester.runAsync(HermesLiquidShader.load), isNotNull);
      await tester.pump();
      expect(_shader(tester), isTrue);
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(body: Center(child: _strip(1))),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      for (final element in find.byType(HermesGlassPiece).evaluate()) {
        expect(HermesGlassStrip.of(element)!.veil.a, greaterThan(0));
      }
      await tester.pumpAndSettle();
      expect(_shader(tester), isTrue);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      for (final element in find.byType(HermesGlassPiece).evaluate()) {
        expect(HermesGlassStrip.of(element)!.veil.a, greaterThan(0));
      }
      await tester.pumpAndSettle();
      expect(_shader(tester), isTrue);
      expect(tester.takeException(), isNull);
    },
    tags: 'opt-in',
    skip: _skip,
  );

  testWidgets(
    'nested veto suspends and restores real dock with retained draft',
    (tester) async {
      await prepareLiquidMotionDock();
      tester.view.physicalSize = const Size(824, 1830);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final outer = ValueNotifier(false);
      final inner = ValueNotifier(false);
      final draft = TextEditingController(text: 'borrador conservado')
        ..selection = const TextSelection.collapsed(offset: 3);
      addTearDown(outer.dispose);
      addTearDown(inner.dispose);
      addTearDown(draft.dispose);
      await tester.pumpWidget(
        liquidMotionApp(
          outer: outer,
          inner: inner,
          draft: draft,
          travel: const Offset(9, 13),
        ),
      );
      expect(await tester.runAsync(HermesLiquidShader.load), isNotNull);
      await tester.pump();
      await tester.pump();
      // Positive precondition: this runner selected both shader branches.
      // This diagnostic alone does not establish GPU execution or pixel AA.
      for (final key in [liquidMotionPieceKey, liquidMotionDockKey]) {
        expect(
          HermesGlassStrip.debugShaderActive(tester.element(find.byKey(key))),
          isTrue,
        );
      }
      final field = find.byKey(liquidMotionDraftKey);
      final dock = find.byType(GestureDock);
      final fieldState = tester.state(field);
      final dockState = tester.state(dock);
      final fieldRect = liquidMotionRelativeRect(tester, field);
      final dockRect = liquidMotionRelativeRect(
        tester,
        find.byKey(liquidMotionDockKey),
      );
      final loads = HermesLiquidShader.loadAttempts;
      for (final pair in [
        (true, false),
        (true, true),
        (false, true),
        (false, false),
        (true, false),
        (false, false),
      ]) {
        outer.value = pair.$1;
        inner.value = pair.$2;
        final moving = pair.$1 || pair.$2;
        for (final ms in [0, 16, 33]) {
          await tester.pump(Duration(milliseconds: ms));
          for (final key in [liquidMotionPieceKey, liquidMotionDockKey]) {
            final context = tester.element(find.byKey(key));
            expect(HermesLiquidMotion.of(context), moving);
            expect(HermesGlassStrip.debugShaderActive(context), !moving);
            if (moving) {
              expect(HermesGlassStrip.of(context)!.veil.a, greaterThan(0));
            }
          }
          expect(HermesLiquidShader.loadAttempts, loads);
          expect(tester.layers.whereType<BackdropFilterLayer>(), hasLength(2));
          expect(tester.state(field), same(fieldState));
          expect(tester.state(dock), same(dockState));
          expect(liquidMotionRelativeRect(tester, field), fieldRect);
          expect(
            liquidMotionRelativeRect(tester, find.byKey(liquidMotionDockKey)),
            dockRect,
          );
          expect(draft.text, 'borrador conservado');
          expect(draft.selection, const TextSelection.collapsed(offset: 3));
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
    tags: 'opt-in',
    skip: _skip,
  );
}
