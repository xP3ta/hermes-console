import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/render/spritesheet_renderer.dart';

const _companion = Companion(
  slug: 'nimbus',
  name: 'Nimbus',
  author: 'team',
  license: 'CC0-1.0',
  spritesheetAsset: 'assets/companions/nimbus/spritesheet.webp',
  frameWidth: 1,
  frameHeight: 1,
  cols: 8,
  rows: 1,
  fps: 8,
  states: {
    CompanionAnimationState.idle: RowSpec(row: 0, frameCount: 8, loop: true),
  },
);

const _fastCompanion = Companion(
  slug: 'nimbus-fast',
  name: 'Nimbus fast',
  author: 'team',
  license: 'CC0-1.0',
  spritesheetAsset: 'assets/companions/nimbus/spritesheet.webp',
  frameWidth: 1,
  frameHeight: 1,
  cols: 8,
  rows: 1,
  fps: 60,
  states: {
    CompanionAnimationState.idle: RowSpec(row: 0, frameCount: 8, loop: true),
  },
);

final _spritesheet = MemoryImage(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAABAQMAAADZzn0AAAAAA1BMVEX/AAAZ4gk3'
    'AAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg==',
  ),
);

Widget _host({
  required ValueChanged<int> onFrameChanged,
  Companion companion = _companion,
  bool animate = true,
  bool tickerEnabled = true,
  bool reduceMotion = false,
  double speedMultiplier = 1,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: TickerMode(
        enabled: tickerEnabled,
        child: SpritesheetRenderer(
          companion: companion,
          state: CompanionAnimationState.idle,
          animate: animate,
          speedMultiplier: speedMultiplier,
          onFrameChanged: onFrameChanged,
          imageProvider: _spritesheet,
        ),
      ),
    ),
  );
}

Future<void> _waitForImage(WidgetTester tester, List<int> frames) async {
  // La decodificación de imágenes ocurre fuera del fake clock del widget test.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  for (var attempt = 0; attempt < 20 && frames.isEmpty; attempt++) {
    await tester.pump(const Duration(milliseconds: 5));
  }
  expect(frames, isNotEmpty, reason: 'el asset de prueba debe decodificarse');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('avanza al FPS declarado y no a cada vsync', (tester) async {
    final frames = <int>[];
    await tester.pumpWidget(_host(onFrameChanged: frames.add));
    await _waitForImage(tester, frames);
    frames.clear();

    await tester.pump(const Duration(milliseconds: 124));
    expect(frames, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(frames, [1]);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('prepara una celda pequeña y no repinta el atlas completo', (
    tester,
  ) async {
    final frames = <int>[];
    await tester.pumpWidget(_host(onFrameChanged: frames.add));
    await _waitForImage(tester, frames);

    ui.Image currentFrame() =>
        (tester
                    .widget<CustomPaint>(
                      find.descendant(
                        of: find.byType(SpritesheetRenderer),
                        matching: find.byType(CustomPaint),
                      ),
                    )
                    .painter!
                as SpriteFramePainter)
            .currentFrameImage!;

    final first = currentFrame();
    expect(first.width, 1);
    expect(first.height, 1);
    expect(first.width, lessThan(8));

    await tester.pump(const Duration(milliseconds: 125));
    final second = currentFrame();
    expect(identical(second, first), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('animate false conserva un frame sin reloj periódico', (
    tester,
  ) async {
    final frames = <int>[];
    await tester.pumpWidget(_host(onFrameChanged: frames.add, animate: false));
    await _waitForImage(tester, frames);
    frames.clear();

    await tester.pump(const Duration(seconds: 1));
    expect(frames, isEmpty);
  });

  testWidgets('TickerMode suspende y reanuda el reloj', (tester) async {
    final frames = <int>[];
    await tester.pumpWidget(
      _host(onFrameChanged: frames.add, tickerEnabled: false),
    );
    await _waitForImage(tester, frames);
    frames.clear();

    await tester.pump(const Duration(milliseconds: 500));
    expect(frames, isEmpty);

    await tester.pumpWidget(_host(onFrameChanged: frames.add));
    await tester.pump(const Duration(milliseconds: 125));
    expect(frames, [1]);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduce-motion suspende el reloj', (tester) async {
    final frames = <int>[];
    await tester.pumpWidget(
      _host(onFrameChanged: frames.add, reduceMotion: true),
    );
    await _waitForImage(tester, frames);
    frames.clear();

    await tester.pump(const Duration(seconds: 1));
    expect(frames, isEmpty);
  });

  testWidgets('0.5× reduce la cadencia de una mascota rápida', (tester) async {
    final frames = <int>[];
    await tester.pumpWidget(
      _host(onFrameChanged: frames.add, speedMultiplier: 0.5),
    );
    await _waitForImage(tester, frames);
    frames.clear();

    await tester.pump(const Duration(milliseconds: 125));
    expect(frames, isEmpty);
    await tester.pump(const Duration(milliseconds: 125));
    expect(frames, [1]);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('limita manifests y multiplicadores rápidos a 30 fps', (
    tester,
  ) async {
    final frames = <int>[];
    await tester.pumpWidget(
      _host(
        onFrameChanged: frames.add,
        companion: _fastCompanion,
        speedMultiplier: 2,
      ),
    );
    await _waitForImage(tester, frames);
    frames.clear();

    await tester.pump(const Duration(milliseconds: 33));
    expect(frames, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(frames, [1]);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('background suspende y resumed reactiva el reloj', (
    tester,
  ) async {
    final frames = <int>[];
    await tester.pumpWidget(_host(onFrameChanged: frames.add));
    await _waitForImage(tester, frames);
    frames.clear();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 500));
    expect(frames, isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 125));
    expect(frames, [1]);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cada frame llega a la capa del sprite sin reconstruir widgets', (
    tester,
  ) async {
    // El reloj notifica al painter; la animación del Home (8 fps) ya no pasa
    // por setState, que bajo el paseo repintaba la pantalla entera.
    final frames = <int>[];
    await tester.pumpWidget(_host(onFrameChanged: frames.add));
    await _waitForImage(tester, frames);
    await tester.pump();
    frames.clear();
    final sprite = find.descendant(
      of: find.byType(SpritesheetRenderer),
      matching: find.byType(CustomPaint),
    );
    final painterBefore = tester.widget<CustomPaint>(sprite).painter;

    await tester.pump(const Duration(milliseconds: 125), EnginePhase.build);
    expect(frames, [1]);
    expect(
      tester.renderObject(sprite).debugNeedsPaint,
      isTrue,
      reason: 'el nuevo frame debe llegar a la capa del sprite',
    );
    expect(
      identical(tester.widget<CustomPaint>(sprite).painter, painterBefore),
      isTrue,
      reason: 'avanzar un frame no debe reconstruir el renderer',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
