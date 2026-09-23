import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/models/companion_scale.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CompanionPreferences con scope por perfil', () {
    test('la key scoped sigue el formato <pref>.<connId>.<profileId>', () {
      expect(
        CompanionPreferences.scopedSlugKey('conn-1', 'qa'),
        'companion.selected_slug.conn-1.qa',
      );
      // Perfil por defecto (vacío) → segmento `default`.
      expect(
        CompanionPreferences.scopedSlugKey('conn-1', ''),
        'companion.selected_slug.conn-1.default',
      );
    });

    test(
      'dos perfiles del mismo dispositivo conservan selecciones distintas',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await CompanionPreferences.load();

        await prefs.setSelectedSlugFor('conn-1', 'alpha', 'nimbus');
        await prefs.setSelectedSlugFor('conn-1', 'beta', 'jinx');
        await prefs.setEnabledFor('conn-1', 'beta', false);

        expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'nimbus');
        expect(prefs.selectedSlugFor('conn-1', 'beta'), 'jinx');
        expect(prefs.enabledFor('conn-1', 'alpha'), isTrue);
        expect(prefs.enabledFor('conn-1', 'beta'), isFalse);
        // La key global legada no se toca al escribir con scope.
        expect(prefs.selectedSlug, isNull);
      },
    );

    test('dos conexiones con el mismo perfil no se pisan', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await CompanionPreferences.load();

      await prefs.setSelectedSlugFor('conn-1', 'alpha', 'nimbus');
      await prefs.setSelectedSlugFor('conn-2', 'alpha', 'jinx');

      expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'nimbus');
      expect(prefs.selectedSlugFor('conn-2', 'alpha'), 'jinx');
    });

    test('sin valor scoped se cae al global legado', () async {
      SharedPreferences.setMockInitialValues({
        CompanionPreferences.slugKey: 'boba',
        CompanionPreferences.enabledKey: false,
        CompanionPreferences.scaleKey: 'large',
        CompanionPreferences.sizeMultiplierKey: 1.25,
      });
      final prefs = await CompanionPreferences.load();

      expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'boba');
      expect(prefs.enabledFor('conn-1', 'alpha'), isFalse);
      expect(prefs.scaleFor('conn-1', 'alpha'), CompanionScale.large);
      expect(prefs.sizeMultiplierFor('conn-1', 'alpha'), 1.25);
    });

    test('un valor scoped gana al fallback legado', () async {
      SharedPreferences.setMockInitialValues({
        CompanionPreferences.slugKey: 'boba',
      });
      final prefs = await CompanionPreferences.load();

      await prefs.setSelectedSlugFor('conn-1', 'alpha', 'nimbus');

      expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'nimbus');
      // Otros perfiles siguen viendo el legado.
      expect(prefs.selectedSlugFor('conn-1', 'beta'), 'boba');
    });

    test(
      'migración one-shot: copia la key global al scope activo y la conserva',
      () async {
        SharedPreferences.setMockInitialValues({
          CompanionPreferences.slugKey: 'boba',
          CompanionPreferences.enabledKey: false,
        });
        final prefs = await CompanionPreferences.load();

        await prefs.migrateLegacyToScopeOnce('conn-1', 'alpha');

        // Copiada al scope del perfil activo…
        expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'boba');
        expect(prefs.enabledFor('conn-1', 'alpha'), isFalse);
        // …sin borrar la global (fallback legado durante una versión).
        expect(prefs.selectedSlug, 'boba');

        // One-shot por instalación: un segundo scope NO recibe copia (lee el
        // fallback legado hasta tener valor propio).
        await prefs.migrateLegacyToScopeOnce('conn-1', 'beta');
        final raw = await SharedPreferences.getInstance();
        expect(
          raw.getString(CompanionPreferences.scopedSlugKey('conn-1', 'beta')),
          isNull,
        );
        expect(prefs.selectedSlugFor('conn-1', 'beta'), 'boba');

        // Y no pisa un valor scoped propio si se repite sobre el mismo scope.
        await prefs.setSelectedSlugFor('conn-1', 'alpha', 'nimbus');
        await prefs.migrateLegacyToScopeOnce('conn-1', 'alpha');
        expect(prefs.selectedSlugFor('conn-1', 'alpha'), 'nimbus');
      },
    );

    test(
      'la selección explícita del Spark sobrevive a recrear el controller',
      () async {
        SharedPreferences.setMockInitialValues({
          CompanionPreferences.slugKey: 'boba',
        });
        final prefs = await CompanionPreferences.load();

        await prefs.setSelectedSlugFor('conn-1', 'alpha', 'nimbus');
        await prefs.setSelectedSlugFor('conn-1', 'alpha', null);

        final reloaded = await CompanionPreferences.load();
        expect(reloaded.selectedSlugFor('conn-1', 'alpha'), isNull);
        expect(reloaded.selectedSlug, 'boba');
      },
    );

    test(
      'escala y tamaño continuo scoped conviven con el preset global',
      () async {
        SharedPreferences.setMockInitialValues({
          CompanionPreferences.scaleKey: 'small',
        });
        final prefs = await CompanionPreferences.load();

        await prefs.setScaleFor('conn-1', 'alpha', CompanionScale.large);
        expect(prefs.scaleFor('conn-1', 'alpha'), CompanionScale.large);
        expect(prefs.sizeMultiplierFor('conn-1', 'alpha'), 1.25);
        // Otro scope conserva el preset global legado.
        expect(prefs.scaleFor('conn-1', 'beta'), CompanionScale.small);

        await prefs.setSizeMultiplierFor('conn-1', 'alpha', 1.4);
        expect(prefs.sizeMultiplierFor('conn-1', 'alpha'), closeTo(1.4, 0.001));
      },
    );
  });
}
