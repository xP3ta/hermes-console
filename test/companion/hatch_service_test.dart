import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/hatch/hatch_provider.dart';
import 'package:hermes_android/core/companion/hatch/hatch_service.dart';
import 'package:hermes_android/core/companion/hatch/mock_hatch_provider.dart';
import 'package:hermes_android/core/companion/hatch/prompt_safety.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';

import '../support/remove_test_dir.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hatch_test_');
  });
  tearDown(() async {
    await removeTestDir(root);
  });

  group('HatchService', () {
    test('materializa una mascota generated idle de 1 frame', () async {
      const service = HatchService();
      final pet = await service.hatch(
        provider: const MockHatchProvider(),
        prompt: 'un zorro naranja',
        storageRoot: root,
      );

      expect(pet.origin, CompanionOrigin.generated);
      expect(pet.isGenerated, isTrue);
      expect(pet.isProtected, isFalse); // borrable
      expect(pet.license, 'user-generated');
      // Solo idle, 1 frame.
      expect(pet.states.keys, [CompanionAnimationState.idle]);
      expect(pet.states[CompanionAnimationState.idle]!.frameCount, 1);
      expect(pet.extraRows, isEmpty);
      // Ficheros escritos en el sandbox.
      expect(await File('${root.path}/${pet.slug}/pet.json').exists(), isTrue);
    });

    test('slug derivado del prompt y único frente a colisiones', () async {
      const service = HatchService();
      final a = await service.hatch(
        provider: const MockHatchProvider(),
        prompt: 'gato',
        storageRoot: root,
        existingSlugs: const {'gato'},
      );
      expect(a.slug, isNot('gato')); // evita pisar el existente
    });

    test('prompt bloqueado → PromptRejectedException (no crea nada)', () async {
      const service = HatchService();
      await expectLater(
        service.hatch(
          provider: const MockHatchProvider(),
          prompt: 'algo nsfw',
          storageRoot: root,
        ),
        throwsA(isA<PromptRejectedException>()),
      );
      expect(root.listSync().whereType<Directory>(), isEmpty);
    });

    test(
      'fallo del proveedor → HatchException sin artefactos a medias',
      () async {
        const service = HatchService();
        await expectLater(
          service.hatch(
            provider: const MockHatchProvider(failWith: 'boom'),
            prompt: 'gato',
            storageRoot: root,
          ),
          throwsA(isA<HatchException>()),
        );
        // No queda ningún directorio de mascota (ni tmp .import-).
        expect(
          root.listSync().whereType<Directory>().where(
            (d) => !d.path.split('/').last.startsWith('.import-'),
          ),
          isEmpty,
        );
      },
    );
  });
}
