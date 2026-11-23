import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/models/profile_pet.dart';
import 'package:hermes_android/core/services/profile_pet_visual_adapter.dart';

import 'support/remove_test_dir.dart';

const _twoRowPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAACCAYAAACZgbYnAAAAEUlEQVR4nGP4z8AARAz//wMAEfgD/XUCLkgAAAAASUVORK5CYII=';

void main() {
  test(
    'materializa atlas validado y recorta frame 0 de la fila idle',
    () async {
      final root = await Directory.systemTemp.createTemp('pet-visual-test-');
      addTearDown(() => removeTestDir(root));
      final adapter = ProfilePetVisualAdapter(
        repository: CompanionRepository(importedRootProvider: () async => root),
      );
      const info = ProfilePetInfo(
        enabled: true,
        slug: 'zoro',
        displayName: 'Zoro',
        mime: 'image/png',
        spritesheetBase64: _twoRowPngBase64,
        spritesheetRevision: 'rev-two-rows',
        frameW: 1,
        frameH: 1,
        framesPerState: 1,
        framesByState: {'idle': 1},
        framesByRow: {'idle': 1, 'extra': 1},
        loopMs: 1000,
        stateRows: ['extra', 'idle'],
      );

      final visual = await adapter.materialize(
        info,
        connectionId: 'conn-test',
        profileId: 'infra',
      );

      expect(visual.companion.slug, 'zoro');
      expect(visual.companion.isRemote, isTrue);
      expect(visual.companion.rowFor(CompanionAnimationState.idle)?.row, 1);
      expect(visual.avatar.mimeType, 'image/png');

      final codec = await ui.instantiateImageCodec(visual.avatar.bytes);
      final image = (await codec.getNextFrame()).image;
      addTearDown(() {
        image.dispose();
        codec.dispose();
      });
      expect((image.width, image.height), (1, 1));
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(rgba?.buffer.asUint8List(), [0, 0, 255, 255]);
    },
  );
}
