import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/models/profile_pet.dart';

import '../support/remove_test_dir.dart';

const _png1x1Base64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

ProfilePetInfo _remotePet(String revision, {String slug = 'zoro'}) =>
    ProfilePetInfo(
      enabled: true,
      slug: slug,
      displayName: 'Zoro',
      mime: 'image/png',
      spritesheetBase64: _png1x1Base64,
      spritesheetRevision: revision,
      frameW: 1,
      frameH: 1,
      framesPerState: 1,
      framesByState: const {'idle': 1},
      framesByRow: const {'0': 1},
      loopMs: 1000,
      scale: 1,
      stateRows: const ['idle'],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const connectionId = 'conn-1';
  const profileId = 'alpha';
  const slug = 'zoro';
  late Directory root;
  late CompanionRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('companion_profile_cache');
    repository = CompanionRepository(importedRootProvider: () async => root);
  });

  tearDown(() async {
    await removeTestDir(root);
  });

  group('CompanionRepository profile pet cache', () {
    test('materializar no publica el índice hasta promote', () async {
      final materialized = await repository.materializeProfilePet(
        _remotePet('rev-1'),
        connectionId: connectionId,
        profileId: profileId,
      );

      expect(File(materialized.spritesheetAsset).existsSync(), isTrue);
      expect(
        await repository.cachedProfilePetRevision(
          connectionId: connectionId,
          profileId: profileId,
          slug: slug,
        ),
        isNull,
      );

      await repository.promoteProfilePetRevision(
        connectionId: connectionId,
        profileId: profileId,
        slug: slug,
        revision: 'rev-1',
      );

      expect(
        await repository.cachedProfilePetRevision(
          connectionId: connectionId,
          profileId: profileId,
          slug: slug,
        ),
        'rev-1',
      );
      expect(
        await repository.loadCachedProfilePet(
          connectionId: connectionId,
          profileId: profileId,
          slug: slug,
          revision: 'rev-1',
        ),
        isNotNull,
      );
    });

    test('spritesheet borrado invalida la revisión publicada', () async {
      final materialized = await repository.materializeProfilePet(
        _remotePet('rev-1'),
        connectionId: connectionId,
        profileId: profileId,
      );
      await repository.promoteProfilePetRevision(
        connectionId: connectionId,
        profileId: profileId,
        slug: slug,
        revision: 'rev-1',
      );

      await File(materialized.spritesheetAsset).delete();

      expect(
        await repository.cachedProfilePetRevision(
          connectionId: connectionId,
          profileId: profileId,
          slug: slug,
        ),
        isNull,
      );
    });

    test('spritesheet corrupto invalida la revisión publicada', () async {
      final materialized = await repository.materializeProfilePet(
        _remotePet('rev-1'),
        connectionId: connectionId,
        profileId: profileId,
      );
      await repository.promoteProfilePetRevision(
        connectionId: connectionId,
        profileId: profileId,
        slug: slug,
        revision: 'rev-1',
      );

      await File(
        materialized.spritesheetAsset,
      ).writeAsBytes(List<int>.filled(32, 0), flush: true);

      expect(
        await repository.cachedProfilePetRevision(
          connectionId: connectionId,
          profileId: profileId,
          slug: slug,
        ),
        isNull,
      );
    });

    test('rev2 de la misma slug conserva rev1 hasta promoverla', () async {
      final rev1 = await repository.materializeProfilePet(
        _remotePet('rev-1'),
        connectionId: connectionId,
        profileId: profileId,
      );
      await repository.promoteProfilePetRevision(
        connectionId: connectionId,
        profileId: profileId,
        slug: slug,
        revision: 'rev-1',
      );

      final rev2 = await repository.materializeProfilePet(
        _remotePet('rev-2'),
        connectionId: connectionId,
        profileId: profileId,
      );

      expect(rev2.spritesheetAsset, isNot(rev1.spritesheetAsset));
      expect(File(rev1.spritesheetAsset).existsSync(), isTrue);
      expect(File(rev2.spritesheetAsset).existsSync(), isTrue);
      expect(
        await repository.cachedProfilePetRevision(
          connectionId: connectionId,
          profileId: profileId,
          slug: slug,
        ),
        'rev-1',
      );
      expect(
        await repository.loadCachedProfilePet(
          connectionId: connectionId,
          profileId: profileId,
          slug: slug,
          revision: 'rev-1',
        ),
        isNotNull,
      );
      expect(
        await repository.loadCachedProfilePet(
          connectionId: connectionId,
          profileId: profileId,
          slug: slug,
          revision: 'rev-2',
        ),
        isNotNull,
      );

      await repository.promoteProfilePetRevision(
        connectionId: connectionId,
        profileId: profileId,
        slug: slug,
        revision: 'rev-2',
      );

      expect(
        await repository.cachedProfilePetRevision(
          connectionId: connectionId,
          profileId: profileId,
          slug: slug,
        ),
        'rev-2',
      );
      expect(File(rev1.spritesheetAsset).existsSync(), isTrue);
    });
  });
}
