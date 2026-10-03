import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/render/companion_roaming_overlay.dart';
import 'package:hermes_android/core/companion/render/companion_view.dart';
import 'package:hermes_android/core/companion/render/spritesheet_renderer.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_spark_mascot.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _EmptyRepo extends CompanionRepository {
  @override
  Future<List<Companion>> loadAll() async => const [];
}

/// Mascota importada de 8 fps con un atlas PNG mínimo (8x1) en disco.
class _SpriteRepo extends CompanionRepository {
  _SpriteRepo(this.path);

  final String path;

  @override
  Future<List<Companion>> loadAll() async => [
    Companion(
      slug: 'nimbus',
      name: 'Nimbus',
      author: 'team',
      license: 'CC0-1.0',
      origin: CompanionOrigin.imported,
      spritesheetAsset: path,
      frameWidth: 1,
      frameHeight: 1,
      cols: 8,
      rows: 1,
      fps: 8,
      states: const {
        CompanionAnimationState.idle: RowSpec(
          row: 0,
          frameCount: 8,
          loop: true,
        ),
        CompanionAnimationState.run: RowSpec(row: 0, frameCount: 8, loop: true),
      },
    ),
  ];
}

String _writeSpritesheet() {
  final dir = Directory.systemTemp.createTempSync('roaming-sprite-');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/spritesheet.png')
    ..writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAgAAAABAQMAAADZzn0AAAAAA1BMVEX/AAAZ4gk3'
        'AAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg==',
      ),
    );
  return file.path;
}

Future<CompanionController> _controller({
  bool roaming = false,
  bool showOnHome = true,
  bool sprite = false,
}) async {
  SharedPreferences.setMockInitialValues({
    CompanionPreferences.roamingEnabledKey: roaming,
    CompanionPreferences.showOnHomeKey: showOnHome,
    if (sprite) CompanionPreferences.slugKey: 'nimbus',
  });
  final prefs = await CompanionPreferences.load();
  final controller = CompanionController(
    sprite ? _SpriteRepo(_writeSpritesheet()) : _EmptyRepo(),
    prefs,
  );
  await controller.init();
  return controller;
}

Future<void> _pump(
  WidgetTester tester,
  CompanionController controller, {
  bool reduceMotion = false,
  bool keyboardVisible = false,
  Duration minPause = const Duration(milliseconds: 1400),
  Duration maxPause = const Duration(milliseconds: 3600),
  Duration minTravel = const Duration(milliseconds: 2200),
  Duration maxTravel = const Duration(milliseconds: 5200),
  Duration minRest = const Duration(seconds: 20),
  Duration maxRest = const Duration(seconds: 40),
  VoidCallback? onPetTap,
  ValueChanged<Offset>? onTravelFrame,
  Widget child = const ColoredBox(color: Colors.black),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.fromId('dark'),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            size: const Size(300, 500),
            disableAnimations: reduceMotion,
            viewInsets: EdgeInsets.only(bottom: keyboardVisible ? 280 : 0),
          ),
          child: SizedBox(
            width: 300,
            height: 500,
            child: CompanionRoamingOverlay(
              controller: controller,
              random: math.Random(7),
              minPause: minPause,
              maxPause: maxPause,
              minTravel: minTravel,
              maxTravel: maxTravel,
              minRest: minRest,
              maxRest: maxRest,
              onPetTap: onPetTap,
              petSemanticLabel: 'Mascota — abrir acciones',
              onTravelFrame: onTravelFrame,
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Cuenta los repintados del contenido que la mascota sobrevuela (el Home).
class _PaintCounter extends CustomPainter {
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) => paints++;

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Centro de la mascota tal como quedó pintado en la capa propia del paseo
/// (en coordenadas de esa capa), recorriendo las capas grabadas en el último
/// paint. A diferencia de `getCenter`, que usa la transformación lógica, solo
/// cambia si la capa se volvió a pintar.
Offset _paintedPetCenter(RenderObject roaming) {
  Layer? layer = roaming.debugLayer!.firstChild;
  var transform = Matrix4.identity();
  while (layer != null && layer is! PictureLayer) {
    if (layer is TransformLayer) {
      transform = transform
        ..translateByDouble(layer.offset.dx, layer.offset.dy, 0, 1)
        ..multiply(layer.transform!);
    } else if (layer is OffsetLayer) {
      transform.translateByDouble(layer.offset.dx, layer.offset.dy, 0, 1);
    }
    layer = (layer as ContainerLayer).firstChild;
  }
  expect(layer, isA<PictureLayer>(), reason: 'la mascota debe estar pintada');
  final bounds = (layer! as PictureLayer).canvasBounds;
  return MatrixUtils.transformPoint(transform, bounds.center);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('apagado por defecto no monta la mascota', (tester) async {
    final controller = await _controller();
    await _pump(tester, controller);

    expect(find.byKey(const ValueKey('companion-roaming-pet')), findsNothing);
  });

  testWidgets('opt-in monta una sola mascota dentro de los límites', (
    tester,
  ) async {
    final controller = await _controller(roaming: true);
    await _pump(tester, controller);

    expect(find.byKey(const ValueKey('companion-roaming-pet')), findsOneWidget);
    final travel = tester.widget<CompanionRoamingPosition>(
      find.byKey(const ValueKey('companion-roaming-position')),
    );
    expect(travel.position.value.dx, inInclusiveRange(10, 232));
    expect(travel.position.value.dy, 10);
    expect(find.byType(AnimatedPositioned), findsNothing);
    expect(find.byType(TweenAnimationBuilder<Offset>), findsNothing);
    final ignoreAncestors = find.ancestor(
      of: find.byKey(const ValueKey('companion-roaming-pet')),
      matching: find.byType(IgnorePointer),
    );
    expect(ignoreAncestors, findsWidgets);
    expect(
      tester
          .widgetList<IgnorePointer>(ignoreAncestors)
          .any((widget) => widget.ignoring),
      isTrue,
    );
  });

  testWidgets('ocultarla en Inicio suprime también el paseo', (tester) async {
    final controller = await _controller(roaming: true, showOnHome: false);
    await _pump(tester, controller);

    expect(find.byKey(const ValueKey('companion-roaming-pet')), findsNothing);
    expect(controller.enabled, isTrue);
  });

  testWidgets('el sprite móvil recibe el toque cuando tiene acciones', (
    tester,
  ) async {
    final controller = await _controller(roaming: true);
    var taps = 0;
    await _pump(tester, controller, onPetTap: () => taps++);

    await tester.tap(find.byKey(const ValueKey('companion-roaming-pet')));
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('al pasear usa run y vuelve a idle durante la pausa', (
    tester,
  ) async {
    final controller = await _controller(roaming: true);
    await _pump(
      tester,
      controller,
      minPause: const Duration(milliseconds: 10),
      maxPause: const Duration(milliseconds: 10),
      minTravel: const Duration(milliseconds: 100),
      maxTravel: const Duration(milliseconds: 100),
    );

    final before = tester
        .widget<CompanionRoamingPosition>(
          find.byKey(const ValueKey('companion-roaming-position')),
        )
        .position
        .value;
    await tester.pump(const Duration(milliseconds: 10));
    expect(
      tester.widget<CompanionView>(find.byType(CompanionView)).mood,
      HermesSparkMood.thinking,
    );

    // Un paso de paseo (12 por segundo) más un margen.
    await tester.pump(const Duration(milliseconds: 84));
    final travelling = tester.widget<CompanionRoamingPosition>(
      find.byKey(const ValueKey('companion-roaming-position')),
    );
    expect(travelling.position.value.dy, 10);
    expect(travelling.position.value.dx, isNot(before.dx));

    await tester.pump(const Duration(milliseconds: 84));
    expect(
      tester.widget<CompanionView>(find.byType(CompanionView)).mood,
      HermesSparkMood.idle,
    );
  });

  testWidgets('presupuesto de paseo limita el trabajo a 12 pasos por segundo', (
    tester,
  ) async {
    final controller = await _controller(roaming: true);
    final travelFrames = <Offset>[];
    await _pump(
      tester,
      controller,
      minPause: const Duration(milliseconds: 10),
      maxPause: const Duration(milliseconds: 10),
      minTravel: const Duration(seconds: 5),
      maxTravel: const Duration(seconds: 5),
      onTravelFrame: travelFrames.add,
    );

    await tester.pump(const Duration(milliseconds: 10));
    travelFrames.clear();
    await tester.pump(const Duration(seconds: 1));

    expect(travelFrames, isNotEmpty);
    expect(
      travelFrames.length,
      lessThanOrEqualTo(12),
      reason: 'el paseo no debe volver a seguir cada vsync de un panel 120 Hz',
    );
    expect(find.byType(TweenAnimationBuilder<Offset>), findsNothing);
  });

  testWidgets('reduce motion conserva una mascota estática sin frames', (
    tester,
  ) async {
    final controller = await _controller(roaming: true);
    await _pump(tester, controller, reduceMotion: true);

    final view = tester.widget<CompanionView>(find.byType(CompanionView));
    expect(view.mood, HermesSparkMood.idle);
    expect(view.animate, isFalse);
  });

  testWidgets('el teclado oculta el paseo', (tester) async {
    final controller = await _controller(roaming: true);
    await _pump(tester, controller, keyboardVisible: true);

    expect(find.byKey(const ValueKey('companion-roaming-pet')), findsNothing);
  });

  testWidgets('la pista admite altura intrínseca dentro de un ListView', (
    tester,
  ) async {
    final controller = await _controller(roaming: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        home: Scaffold(
          body: ListView(
            children: [
              CompanionRoamingOverlay(
                controller: controller,
                random: math.Random(7),
                child: const SizedBox(
                  height: 118,
                  child: ColoredBox(color: Colors.black),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('companion-roaming-pet')), findsOneWidget);
  });

  testWidgets('el paseo no repinta el contenido que sobrevuela', (
    tester,
  ) async {
    final controller = await _controller(roaming: true);
    final counter = _PaintCounter();
    final travelFrames = <Offset>[];
    await _pump(
      tester,
      controller,
      minPause: const Duration(milliseconds: 10),
      maxPause: const Duration(milliseconds: 10),
      minTravel: const Duration(seconds: 5),
      maxTravel: const Duration(seconds: 5),
      onTravelFrame: travelFrames.add,
      child: CustomPaint(painter: counter, size: const Size(300, 500)),
    );
    await tester.pump(const Duration(milliseconds: 10));
    final paintsBefore = counter.paints;
    travelFrames.clear();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(travelFrames.length, greaterThan(10));
    expect(
      counter.paints - paintsBefore,
      0,
      reason:
          'cada paso del paseo debe repintar solo la capa de la mascota, '
          'no el Home que hay debajo',
    );
  });

  testWidgets('sin interacción descansa tras unos paseos', (tester) async {
    final controller = await _controller(roaming: true);
    final travelFrames = <Offset>[];
    await _pump(tester, controller, onTravelFrame: travelFrames.add);

    // Dos minutos de Home en reposo con la cadencia real de pausas/paseos.
    for (var i = 0; i < 1200; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Antes: ~60 % del tiempo andando a 20 pasos/s (1487 pasos en 120 s).
    // ignore: avoid_print
    print('idle travel steps in 120 s: ${travelFrames.length}');
    expect(
      travelFrames.length,
      lessThan(500),
      reason: 'un Home desatendido no debe pasear sin descanso',
    );
    expect(travelFrames, isNotEmpty, reason: 'la mascota sigue paseando');
  });

  testWidgets('un toque en cualquier punto despierta a la mascota', (
    tester,
  ) async {
    final controller = await _controller(roaming: true);
    final travelFrames = <Offset>[];
    await _pump(
      tester,
      controller,
      minRest: const Duration(minutes: 10),
      maxRest: const Duration(minutes: 10),
      onTravelFrame: travelFrames.add,
    );
    // Tres paseos caben en ~30 s; después descansa.
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    travelFrames.clear();
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(travelFrames, isEmpty, reason: 'debe estar descansando');

    await tester.tapAt(const Offset(150, 400));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(travelFrames, isNotEmpty, reason: 'el toque recupera el paseo');
  });

  testWidgets('los frames del sprite tampoco repintan el contenido del Home', (
    tester,
  ) async {
    final controller = await _controller(roaming: true, sprite: true);
    expect(controller.activeCompanion?.slug, 'nimbus');
    final counter = _PaintCounter();
    await _pump(
      tester,
      controller,
      // Mascota quieta: solo avanza su animación idle a 8 fps.
      minPause: const Duration(minutes: 5),
      maxPause: const Duration(minutes: 5),
      child: CustomPaint(painter: counter, size: const Size(300, 500)),
    );
    expect(find.byType(SpritesheetRenderer), findsOneWidget);
    final sprite = find.descendant(
      of: find.byType(SpritesheetRenderer),
      matching: find.byType(CustomPaint),
    );
    // El atlas se decodifica fuera del reloj falso del test.
    for (var i = 0; i < 100 && sprite.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(sprite, findsOneWidget, reason: 'el atlas debe decodificarse');
    final paintsBefore = counter.paints;

    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 125));
    }

    expect(counter.paints - paintsBefore, 0);
  });

  testWidgets('cada paso del paseo vuelve a pintar la mascota en su sitio', (
    tester,
  ) async {
    final controller = await _controller(roaming: true);
    final travelFrames = <Offset>[];
    await _pump(
      tester,
      controller,
      minPause: const Duration(milliseconds: 10),
      maxPause: const Duration(milliseconds: 10),
      minTravel: const Duration(seconds: 5),
      maxTravel: const Duration(seconds: 5),
      onTravelFrame: travelFrames.add,
    );
    await tester.pump(const Duration(milliseconds: 10));
    final position = find.byKey(const ValueKey('companion-roaming-position'));
    RenderObject roaming() {
      final object = tester.renderObject(position);
      expect(object.attached, isTrue);
      return object;
    }

    final notifier = tester.widget<CompanionRoamingPosition>(position).position;
    var previous = notifier.value;
    var previousPainted = _paintedPetCenter(roaming());

    for (var step = 0; step < 2; step++) {
      travelFrames.clear();
      // Un paso de paseo (12 por segundo).
      await tester.pump(const Duration(milliseconds: 84));
      expect(travelFrames, isNotEmpty);
      final moved = notifier.value;
      expect(moved.dx, isNot(previous.dx));
      expect(roaming().debugNeedsPaint, isFalse);
      final painted = _paintedPetCenter(roaming());
      // Lo pintado se desplaza exactamente lo que avanzó la posición.
      expect(
        painted.dx - previousPainted.dx,
        closeTo(moved.dx - previous.dx, 0.01),
      );
      expect(
        painted.dy - previousPainted.dy,
        closeTo(moved.dy - previous.dy, 0.01),
      );
      previous = moved;
      previousPainted = painted;
    }
  });
}
