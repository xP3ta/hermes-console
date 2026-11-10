// This file never preloads a shader: it can test a genuinely cold veto with
// either the normal test renderer or an explicitly assigned Impeller runner.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/shell/gesture_dock.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';

import 'support/liquid_motion_fixture.dart';

void main() {
  setUp(() {
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
    FrostedBackdropPolicy.knownHighEnd.value = true;
    FrostedBackdropPolicy.liquidGpuValidated.value = true;
    FrostedBackdropPolicy.effectCeiling.value = HermesGlassTier.liquid;
  });
  tearDown(() {
    FrostedBackdropPolicy.knownHighEnd.value = false;
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
  });

  testWidgets('nested motion is ancestor OR local with a retained reader', (
    tester,
  ) async {
    final outer = ValueNotifier(false);
    final inner = ValueNotifier(false);
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    const readerKey = ValueKey('motion-reader');
    final reader = Builder(
      key: readerKey,
      builder: (context) => Text(
        '${HermesLiquidMotion.of(context)}',
        textDirection: TextDirection.ltr,
      ),
    );
    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: outer,
        child: ValueListenableBuilder<bool>(
          valueListenable: inner,
          child: reader,
          builder: (_, value, child) =>
              HermesLiquidMotion(moving: value, child: child!),
        ),
        builder: (_, value, child) =>
            HermesLiquidMotion(moving: value, child: child!),
      ),
    );
    final element = tester.element(find.byKey(readerKey));
    for (final pair in [
      (false, false),
      (true, false),
      (true, true),
      (false, true),
      (false, false),
      (true, false),
      (false, false),
    ]) {
      outer.value = pair.$1;
      inner.value = pair.$2;
      await tester.pump();
      expect(tester.element(find.byKey(readerKey)), same(element));
      expect(HermesLiquidMotion.of(element), pair.$1 || pair.$2);
      expect(
        find.text('${pair.$1 || pair.$2}'),
        findsOneWidget,
        reason: 'the dependent reader must rebuild without replacing its child',
      );
    }
  });

  testWidgets(
    'cold nested veto reaches real dock and draft without any shader load',
    (tester) async {
      await prepareLiquidMotionDock();
      tester.view.physicalSize = const Size(824, 1830);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final outer = ValueNotifier(true);
      final inner = ValueNotifier(false);
      final draft = TextEditingController(text: 'borrador conservado')
        ..selection = const TextSelection.collapsed(offset: 3);
      addTearDown(outer.dispose);
      addTearDown(inner.dispose);
      addTearDown(draft.dispose);
      expect(HermesLiquidShader.program, isNull);
      expect(HermesLiquidShader.loadAttempts, 0);
      await tester.pumpWidget(
        liquidMotionApp(
          outer: outer,
          inner: inner,
          draft: draft,
          travel: const Offset(9, 13),
        ),
      );
      await tester.pump();
      final field = find.byKey(liquidMotionDraftKey);
      final dock = find.byType(GestureDock);
      final fieldState = tester.state(field);
      final dockState = tester.state(dock);
      final fieldRect = liquidMotionRelativeRect(tester, field);
      final dockRect = liquidMotionRelativeRect(
        tester,
        find.byKey(liquidMotionDockKey),
      );
      for (final pair in [
        (true, false),
        (true, true),
        (false, true),
        (true, false),
      ]) {
        outer.value = pair.$1;
        inner.value = pair.$2;
        for (final ms in [0, 16, 33]) {
          await tester.pump(Duration(milliseconds: ms));
          for (final key in [liquidMotionPieceKey, liquidMotionDockKey]) {
            final context = tester.element(find.byKey(key));
            expect(HermesLiquidMotion.of(context), isTrue);
            expect(HermesGlassStrip.debugShaderActive(context), isFalse);
            expect(HermesGlassStrip.of(context)!.veil.a, greaterThan(0));
          }
          expect(HermesLiquidShader.loadAttempts, 0);
          expect(HermesLiquidShader.program, isNull);
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
  );
}
