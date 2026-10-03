import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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

final _spritesheetBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAgAAAABAQMAAADZzn0AAAAAA1BMVEX/AAAZ4gk3'
  'AAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg==',
);

/// Spritesheet decoded once in real time before any widget test runs.
late final ui.Image _decodedSpritesheet;

/// Delivers the pre-decoded atlas synchronously.
///
/// Decoding a codec is real engine work that the widget tester's fake clock
/// cannot drive: a test that waits a fixed wall-clock slice for it fails
/// whenever the host is loaded. Handing the renderer an already decoded image
/// keeps its whole resolve → listener → frame-clock path in fake time, so the
/// cadence assertions below depend only on fake time.
class _PreDecodedImage extends ImageProvider<_PreDecodedImage> {
  const _PreDecodedImage();

  @override
  Future<_PreDecodedImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_PreDecodedImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _PreDecodedImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    SynchronousFuture<ImageInfo>(ImageInfo(image: _decodedSpritesheet.clone())),
  );
}

const _spritesheet = _PreDecodedImage();

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

void _expectFirstFrame(List<int> frames) {
  // El atlas llega ya decodificado y de forma síncrona: el primer frame se
  // publica en el mismo pumpWidget, sin depender del reloj real.
  expect(frames, isNotEmpty, reason: 'el asset de prueba debe decodificarse');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _decodedSpritesheet = await decodeImageFromList(_spritesheetBytes);
  });

  testWidgets('avanza al FPS declarado y no a cada vsync', (tester) async {
    final frames = <int>[];
    await tester.pumpWidget(_host(onFrameChanged: frames.add));
    _expectFirstFrame(frames);
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
    _expectFirstFrame(frames);

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
    _expectFirstFrame(frames);
    frames.clear();

    await tester.pump(const Duration(seconds: 1));
    expect(frames, isEmpty);
  });

  testWidgets('TickerMode suspende y reanuda el reloj', (tester) async {
    final frames = <int>[];
    await tester.pumpWidget(
      _host(onFrameChanged: frames.add, tickerEnabled: false),
    );
    _expectFirstFrame(frames);
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
    _expectFirstFrame(frames);
    frames.clear();

    await tester.pump(const Duration(seconds: 1));
    expect(frames, isEmpty);
  });

  testWidgets('0.5× reduce la cadencia de una mascota rápida', (tester) async {
    final frames = <int>[];
    await tester.pumpWidget(
      _host(onFrameChanged: frames.add, speedMultiplier: 0.5),
    );
    _expectFirstFrame(frames);
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
    _expectFirstFrame(frames);
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
    _expectFirstFrame(frames);
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
