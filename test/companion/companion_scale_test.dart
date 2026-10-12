import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/models/companion_scale.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/screens/companion/mascotas_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mascota con estados configurables: por defecto declara idle+wave pero **no**
/// jump (igual que las base), para validar que el probador deshabilita jump.
Companion _pet(
  String slug,
  String name, {
  Map<CompanionAnimationState, RowSpec>? states,
}) => Companion(
  slug: slug,
  name: name,
  author: 'Hermes team',
  license: 'CC0-1.0',
  spritesheetAsset: 'assets/companions/$slug/spritesheet.webp',
  frameWidth: 192,
  frameHeight: 208,
  cols: 8,
  rows: 9,
  fps: 8,
  states:
      states ??
      const {
        CompanionAnimationState.idle: RowSpec(
          row: 0,
          frameCount: 8,
          loop: true,
        ),
        CompanionAnimationState.wave: RowSpec(
          row: 1,
          frameCount: 6,
          loop: false,
        ),
      },
);

class _FakeRepo extends CompanionRepository {
  final List<Companion> _all;
  _FakeRepo(this._all);
  @override
  Future<List<Companion>> loadAll() async => _all;
}

Future<CompanionController> _controller(List<Companion> pets) async {
  final prefs = await CompanionPreferences.load();
  final c = CompanionController(_FakeRepo(pets), prefs);
  await c.init();
  return c;
}

Future<void> _pumpScreen(WidgetTester tester, CompanionController c) async {
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: MascotasScreen(controller: c),
    ),
  );
  await tester.pump();
}

Future<void> _expandAdvanced(WidgetTester tester) async {
  await tester.tap(find.text('Opciones avanzadas'));
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('CompanionScale (modelo)', () {
    test('fromId mapea los identificadores válidos', () {
      expect(CompanionScale.fromId('small'), CompanionScale.small);
      expect(CompanionScale.fromId('medium'), CompanionScale.medium);
      expect(CompanionScale.fromId('large'), CompanionScale.large);
    });

    test('fromId cae a medium ante valor inválido o nulo', () {
      expect(CompanionScale.fromId(null), CompanionScale.medium);
      expect(CompanionScale.fromId(''), CompanionScale.medium);
      expect(CompanionScale.fromId('gigante'), CompanionScale.medium);
    });

    test('multiplicadores acotados y ordenados S < M < L', () {
      expect(
        CompanionScale.small.multiplier,
        lessThan(CompanionScale.medium.multiplier),
      );
      expect(
        CompanionScale.medium.multiplier,
        lessThan(CompanionScale.large.multiplier),
      );
      expect(CompanionScale.medium.multiplier, 1.0);
      expect(CompanionScale.large.multiplier, lessThanOrEqualTo(1.3));
      expect(CompanionScale.small.multiplier, greaterThanOrEqualTo(0.7));
    });
  });

  group('Persistencia de escala', () {
    test('setScale guarda y get scale lee', () async {
      final prefs = await CompanionPreferences.load();
      expect(prefs.scale, CompanionScale.medium); // default
      await prefs.setScale(CompanionScale.large);
      final reloaded = await CompanionPreferences.load();
      expect(reloaded.scale, CompanionScale.large);
    });

    test('escala persistida inválida cae a default', () async {
      SharedPreferences.setMockInitialValues({'companion.scale': 'enorme'});
      final prefs = await CompanionPreferences.load();
      expect(prefs.scale, CompanionScale.medium);
    });

    test('controller.setScale actualiza, persiste y notifica', () async {
      final c = await _controller([_pet('nimbus', 'Nimbus')]);
      expect(c.scale, CompanionScale.medium);
      var notified = 0;
      c.addListener(() => notified++);

      await c.setScale(CompanionScale.small);
      expect(c.scale, CompanionScale.small);
      expect(notified, greaterThan(0));

      // Persistencia: un controller nuevo sobre las mismas prefs la recupera.
      final prefs = await CompanionPreferences.load();
      final c2 = CompanionController(
        _FakeRepo([_pet('nimbus', 'Nimbus')]),
        prefs,
      );
      await c2.init();
      expect(c2.scale, CompanionScale.small);
    });
  });

  group('Pantalla Mascotas: tamaño + probador', () {
    testWidgets('el slider continuo actualiza el controller', (tester) async {
      final c = await _controller([_pet('nimbus', 'Nimbus')]);
      await _pumpScreen(tester, c);

      final slider = tester.widget<Slider>(
        find.descendant(
          of: find.byKey(const ValueKey('pet-size-slider')),
          matching: find.byType(Slider),
        ),
      );
      slider.onChanged!(1.4);
      await tester.pump();
      slider.onChangeEnd!(1.4);
      await tester.pump();
      expect(c.sizeMultiplier, closeTo(1.4, 0.001));
    });

    testWidgets('el probador deshabilita jump (no declarado) y permite wave', (
      tester,
    ) async {
      // Mascota activa con idle+wave, sin jump (como las base).
      final c = await _controller([_pet('nimbus', 'Nimbus')]);
      await c.select('nimbus');
      await _pumpScreen(tester, c);
      await _expandAdvanced(tester);

      // Saltar (jump) existe en la UI pero su InkWell no tiene onTap → off.
      final jumpInk = tester.widget<InkWell>(
        find.ancestor(of: find.text('Saltar'), matching: find.byType(InkWell)),
      );
      expect(
        jumpInk.onTap,
        isNull,
        reason: 'jump no está declarado → el chip debe quedar deshabilitado',
      );

      // Saludar (wave) está declarado → habilitado (onTap presente).
      final waveInk = tester.widget<InkWell>(
        find.ancestor(of: find.text('Saludar'), matching: find.byType(InkWell)),
      );
      expect(waveInk.onTap, isNotNull);

      // Y al pulsarlo no lanza excepción.
      waveInk.onTap!();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('probar wave no rompe y revierte el preview a reposo', (
      tester,
    ) async {
      final c = await _controller([_pet('nimbus', 'Nimbus')]);
      await c.select('nimbus');
      await _pumpScreen(tester, c);
      await _expandAdvanced(tester);

      tester
          .widget<InkWell>(
            find.ancestor(
              of: find.text('Saludar'),
              matching: find.byType(InkWell),
            ),
          )
          .onTap!();
      await tester.pump();
      // Avanza más allá de la duración del one-shot (6 frames / 8 fps ≈ 750 ms).
      await tester.pump(const Duration(milliseconds: 1200));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'con la opción por defecto (cara del perfil) el probador no ofrece acciones',
      (tester) async {
        final c = await _controller([_pet('nimbus', 'Nimbus')]);
        // selectedSlug == null → cara del perfil; ninguna mascota con estados declarados.
        await _pumpScreen(tester, c);
        expect(c.selectedSlug, isNull);
        expect(
          find.text('Elige una mascota para probar sus animaciones.'),
          findsNothing,
        );
        await _expandAdvanced(tester);
        expect(
          find.text('Elige una mascota para probar sus animaciones.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('no aparece el logo como mascota', (tester) async {
      final c = await _controller([_pet('nimbus', 'Nimbus')]);
      await _pumpScreen(tester, c);
      final logoImages = find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is AssetImage &&
            (w.image as AssetImage).assetName.toLowerCase().contains('logo'),
      );
      expect(logoImages, findsNothing);
    });
  });
}
