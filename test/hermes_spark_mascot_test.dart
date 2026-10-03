import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/hermes_spark_mascot.dart';

Widget _host({
  required ValueChanged<double> onFrameChanged,
  bool animate = true,
  bool tickerEnabled = true,
  bool reduceMotion = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: TickerMode(
      enabled: tickerEnabled,
      child: HermesSparkMascot(
        animate: animate,
        onFrameChanged: onFrameChanged,
      ),
    ),
  ),
);

void main() {
  test('el reloj de Spark no supera 30 fps', () {
    expect(
      hermesSparkFrameInterval,
      greaterThan(const Duration(microseconds: 33333)),
    );
  });

  testWidgets('Spark produce como máximo 30 frames por segundo', (
    tester,
  ) async {
    final frames = <double>[];
    await tester.pumpWidget(_host(onFrameChanged: frames.add));

    await tester.pump(const Duration(seconds: 1));

    expect(frames.length, inInclusiveRange(29, 30));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TickerMode y lifecycle pausan y reanudan Spark', (tester) async {
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final frames = <double>[];
    await tester.pumpWidget(
      _host(onFrameChanged: frames.add, tickerEnabled: false),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(frames, isEmpty);

    await tester.pumpWidget(_host(onFrameChanged: frames.add));
    await tester.pump(const Duration(milliseconds: 68));
    expect(frames, hasLength(2));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final pausedCount = frames.length;
    await tester.pump(const Duration(milliseconds: 200));
    expect(frames, hasLength(pausedCount));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 34));
    expect(frames, hasLength(pausedCount + 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Reduce Motion y animate false no crean frames', (tester) async {
    for (final animate in [true, false]) {
      final frames = <double>[];
      await tester.pumpWidget(
        _host(onFrameChanged: frames.add, animate: animate, reduceMotion: true),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(frames, isEmpty);
    }
  });

  testWidgets(
    'cada frame llega a la capa de la chispa sin reconstruir widgets',
    (tester) async {
      final frames = <double>[];
      await tester.pumpWidget(_host(onFrameChanged: frames.add));
      await tester.pump();
      final spark = find.descendant(
        of: find.byType(HermesSparkMascot),
        matching: find.byType(CustomPaint),
      );
      final painterBefore = tester.widget<CustomPaint>(spark).painter;

      await tester.pump(hermesSparkFrameInterval, EnginePhase.build);
      expect(frames, hasLength(1));
      expect(tester.renderObject(spark).debugNeedsPaint, isTrue);
      expect(
        identical(tester.widget<CustomPaint>(spark).painter, painterBefore),
        isTrue,
        reason: 'avanzar un frame no debe reconstruir la chispa',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
