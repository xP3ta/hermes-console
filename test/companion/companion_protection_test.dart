import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/screens/companion/mascotas_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Companion _pet(
  String slug,
  String name, {
  CompanionOrigin origin = CompanionOrigin.base,
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
  origin: origin,
  states: const {
    CompanionAnimationState.idle: RowSpec(row: 0, frameCount: 8, loop: true),
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      CompanionPreferences.enabledKey: true,
    }),
  );

  group('Modelo: origen y protección', () {
    test('base está protegida; imported no', () {
      expect(_pet('nimbus', 'Nimbus').isProtected, isTrue);
      expect(_pet('nimbus', 'Nimbus').origin, CompanionOrigin.base);
      expect(
        _pet('custom', 'Custom', origin: CompanionOrigin.imported).isProtected,
        isFalse,
      );
    });

    test('el origen por defecto es base (assets siempre protegidos)', () {
      expect(_pet('pixel', 'Pixel').origin, CompanionOrigin.base);
    });

    test('generated no está protegida y es file-backed (borrable)', () {
      final g = _pet('hatch-1', 'Hatch', origin: CompanionOrigin.generated);
      expect(g.isProtected, isFalse);
      expect(g.isGenerated, isTrue);
      expect(g.isFileBacked, isTrue); // borra ficheros como imported
      // base/imported no se confunden con generated
      expect(_pet('nimbus', 'Nimbus').isGenerated, isFalse);
      expect(
        _pet('c', 'C', origin: CompanionOrigin.imported).isGenerated,
        isFalse,
      );
    });
  });

  group('Controller: borrado seguro', () {
    test('delete sobre una mascota base es no-op (nunca borra)', () async {
      final c = await _controller([
        _pet('nimbus', 'Nimbus'),
        _pet('pixel', 'Pixel'),
        _pet('violet', 'Violet'),
      ]);
      expect(c.available.length, 3);

      final removed = await c.delete('nimbus');
      expect(removed, isFalse);
      expect(c.available.length, 3);
      expect(c.available.any((p) => p.slug == 'nimbus'), isTrue);
    });

    test('delete sobre slug inexistente es no-op', () async {
      final c = await _controller([_pet('nimbus', 'Nimbus')]);
      final removed = await c.delete('fantasma');
      expect(removed, isFalse);
      expect(c.available.length, 1);
    });

    test(
      'delete sobre importada la elimina y recae a una base si era activa',
      () async {
        final c = await _controller([
          _pet('nimbus', 'Nimbus'),
          _pet('custom', 'Custom', origin: CompanionOrigin.imported),
        ]);
        await c.select('custom');
        expect(c.activeCompanion?.slug, 'custom');

        final removed = await c.delete('custom');
        expect(removed, isTrue);
        expect(c.available.any((p) => p.slug == 'custom'), isFalse);
        // La activa borrada recae en una base válida (nimbus).
        expect(c.selectedSlug, 'nimbus');
      },
    );

    test('borrar una importada no activa no cambia la selección', () async {
      final c = await _controller([
        _pet('nimbus', 'Nimbus'),
        _pet('custom', 'Custom', origin: CompanionOrigin.imported),
      ]);
      await c.select('nimbus');

      final removed = await c.delete('custom');
      expect(removed, isTrue);
      expect(c.selectedSlug, 'nimbus');
      expect(c.available.length, 1);
    });
  });

  group('Pantalla: UI de borrado', () {
    testWidgets(
      'con solo mascotas base no se muestra ningún control de borrado',
      (tester) async {
        final c = await _controller([
          _pet('nimbus', 'Nimbus'),
          _pet('pixel', 'Pixel'),
        ]);
        await _pumpScreen(tester, c);
        expect(find.byIcon(Icons.delete_outline), findsNothing);
      },
    );

    testWidgets('una mascota importada sí ofrece borrar', (tester) async {
      final c = await _controller([
        _pet('nimbus', 'Nimbus'),
        _pet('custom', 'Custom', origin: CompanionOrigin.imported),
      ]);
      await _pumpScreen(tester, c);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });
  });
}
