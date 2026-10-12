import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/models/profile_pet.dart';

const _avatarDataUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

AgentProfile _profile([Map<String, dynamic> metadata = const {}]) =>
    AgentProfile.fromJson({
      'name': 'nimbus',
      'ui_meta': {'hermes-bots': metadata},
    });

void _expectSafeOfficialMetadata(
  Map<String, dynamic> metadata, {
  required String imageKind,
}) {
  expect(metadata['imageKind'], imageKind);
  expect(metadata['custom'], isTrue);
  expect(metadata, isNot(contains('identityKind')));
  expect(metadata, isNot(contains('image')));
  expect(metadata, isNot(contains('pet')));

  final encoded = jsonEncode(metadata).toLowerCase();
  expect(encoded, isNot(contains('<svg')));
  expect(encoded, isNot(contains('data:image/svg')));
  expect(encoded, isNot(contains('base64')));
}

void main() {
  late AgentProfileAvatar avatar;

  setUp(() {
    avatar = AgentProfileAvatar.fromDataUri(_avatarDataUri);
  });

  group('BlobatarShapeWire', () {
    test('accepts every official wire form', () {
      const validWires = [
        'blobatar',
        'blobatar:nimbus',
        'blobatar:nimbus:organic',
        'blobatar::cloud',
      ];

      for (final wire in validWires) {
        expect(BlobatarShapeWire.tryParse(wire), isNotNull, reason: wire);
        expect(() => BlobatarShapeWire.parse(wire), returnsNormally);
      }
    });

    test('accepts every official kind and the maximum seed length', () {
      const kinds = [
        'round',
        'organic',
        'boxy',
        'capsule',
        'nub',
        'cloud',
        'droplet',
        'hexagon',
        'sun',
        'triangle',
      ];
      for (final kind in kinds) {
        expect(BlobatarShapeWire.tryParse('blobatar::$kind'), isNotNull);
      }

      final maxSeed = 'a' * 64;
      expect(
        BlobatarShapeWire.tryParse('blobatar:$maxSeed:triangle'),
        isNotNull,
      );
    });

    test('rejects malformed, unsafe, and oversized wires', () {
      final oversizedSeed = 'a' * 65;
      final invalidWires = <String>[
        '',
        'blobatar:',
        'blobatar:nimbus:unknown',
        'blobatar:nimbus:cloud:extra',
        'blobatar:not a slug',
        'blobatar:nimbus/other',
        'blobatar:nim\nbus',
        'Blobatar:nimbus',
        ' blobatar:nimbus',
        'blobatar:$oversizedSeed',
        '<svg><path /></svg>',
        'data:image/svg+xml;base64,PHN2Zz4=',
      ];

      for (final wire in invalidWires) {
        expect(BlobatarShapeWire.tryParse(wire), isNull, reason: wire);
        expect(
          () => BlobatarShapeWire.parse(wire),
          throwsFormatException,
          reason: wire,
        );
      }
    });
  });

  group('variant validation and metadata', () {
    test('classic faces accept the Desktop shape and color allowlists', () {
      const shapes = [
        'circle',
        'blob',
        'squircle',
        'pill',
        'triangle',
        'hexagon',
        'cloud',
        'drop',
      ];
      const colors = [
        '#f5f5f4',
        '#8d6748',
        '#ef4444',
        '#f97316',
        '#14b8a6',
        '#38bdf8',
        '#3b40c8',
        '#8b5cf6',
        '#ec4899',
        '#9ca3af',
      ];

      for (final shape in shapes) {
        for (final color in colors) {
          final identity = ClassicFaceIdentity(
            shape: shape,
            colorHex: color.toUpperCase(),
          );
          expect(identity.shape, shape);
          expect(identity.colorHex, color);
        }
      }
    });

    test('classic faces reject unknown shapes and non-palette colors', () {
      expect(
        () => ClassicFaceIdentity(shape: 'star', colorHex: '#8b5cf6'),
        throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
      );
      expect(
        () => ClassicFaceIdentity(shape: 'cloud', colorHex: '#ffffff'),
        throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
      );
      expect(
        () => ClassicFaceIdentity(shape: 'cloud', colorHex: '<svg>'),
        throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
      );
    });

    test('all variants emit only official safe metadata', () {
      final variants = <(BotVisualIdentity, String)>[
        (const PetSpriteIdentity(slug: 'zoro', revision: 'rev-1'), 'photo'),
        (ProfileImageIdentity(avatar: avatar, legacy: false), 'photo'),
        (
          ProceduralFaceIdentity(
            shapeWire: 'blobatar:nimbus:organic',
            dormantColorHex: '#8b5cf6',
          ),
          'shape',
        ),
        (ClassicFaceIdentity(shape: 'cloud', colorHex: '#38bdf8'), 'shape'),
      ];

      for (final (identity, imageKind) in variants) {
        _expectSafeOfficialMetadata(
          identity.toBotModeMetadata(),
          imageKind: imageKind,
        );
      }
    });

    test('procedural and classic metadata preserve semantic fields', () {
      expect(
        ProceduralFaceIdentity(
          shapeWire: 'blobatar:nimbus:organic',
          dormantColorHex: '#8b5cf6',
        ).toBotModeMetadata(),
        {
          'shape': 'blobatar:nimbus:organic',
          'color': '#8b5cf6',
          'imageKind': 'shape',
          'custom': true,
        },
      );
      expect(
        ClassicFaceIdentity(
          shape: 'cloud',
          colorHex: '#38bdf8',
        ).toBotModeMetadata(),
        {
          'shape': 'cloud',
          'color': '#38bdf8',
          'imageKind': 'shape',
          'custom': true,
        },
      );
    });
  });

  group('resolve precedence', () {
    const pet = ProfilePetInfo(
      enabled: true,
      slug: 'zoro',
      spritesheetRevision: 'rev-1',
    );

    test('active pet wins over photo and every face representation', () {
      final resolved = BotVisualIdentity.resolve(
        _profile({
          'shape': 'blobatar:nimbus:organic',
          'color': '#38bdf8',
          'imageKind': 'photo',
          'custom': true,
        }),
        pet,
        avatar,
      );

      expect(resolved, isA<PetSpriteIdentity>());
      expect((resolved as PetSpriteIdentity).slug, 'zoro');
      expect(resolved.revision, 'rev-1');
    });

    test('explicit photo wins over procedural and classic metadata', () {
      final resolved = BotVisualIdentity.resolve(
        _profile({
          'shape': 'blobatar:nimbus:organic',
          'color': '#38bdf8',
          'imageKind': 'photo',
          'custom': true,
        }),
        ProfilePetInfo.disabled,
        avatar,
      );

      expect(resolved, isA<ProfileImageIdentity>());
      expect((resolved as ProfileImageIdentity).avatar, same(avatar));
      expect(resolved.legacy, isFalse);
    });

    test('procedural face wins over dormant classic color', () {
      final resolved = BotVisualIdentity.resolve(
        _profile({
          'shape': 'blobatar:nimbus:organic',
          'color': '#38bdf8',
          'imageKind': 'shape',
          'custom': true,
        }),
        ProfilePetInfo.disabled,
        null,
      );

      expect(resolved, isA<ProceduralFaceIdentity>());
      expect(
        (resolved as ProceduralFaceIdentity).shapeWire,
        'blobatar:nimbus:organic',
      );
      expect(resolved.dormantColorHex, '#38bdf8');
    });

    test('classic face resolves from a valid Desktop shape and color', () {
      final resolved = BotVisualIdentity.resolve(
        _profile({
          'shape': 'cloud',
          'color': '#38bdf8',
          'imageKind': 'shape',
          'custom': true,
        }),
        ProfilePetInfo.disabled,
        null,
      );

      expect(resolved, isA<ClassicFaceIdentity>());
      expect((resolved as ClassicFaceIdentity).shape, 'cloud');
      expect(resolved.colorHex, '#38bdf8');
    });

    test('avatar without imageKind remains a marked legacy fallback', () {
      final resolved = BotVisualIdentity.resolve(
        _profile(),
        ProfilePetInfo.disabled,
        avatar,
      );

      expect(resolved, isA<ProfileImageIdentity>());
      expect((resolved as ProfileImageIdentity).avatar, same(avatar));
      expect(resolved.legacy, isTrue);
    });

    test('invalid metadata never resolves as a face', () {
      for (final metadata in [
        {'shape': 'blobatar:nimbus:unknown', 'imageKind': 'shape'},
        {'shape': '<svg />', 'color': '#38bdf8', 'imageKind': 'shape'},
        {'shape': 'cloud', 'color': '#ffffff', 'imageKind': 'shape'},
      ]) {
        expect(
          BotVisualIdentity.resolve(
            _profile(metadata),
            ProfilePetInfo.disabled,
            null,
          ),
          isNull,
          reason: metadata.toString(),
        );
      }
    });
  });

  group('semantic round-trip', () {
    test(
      'silhouette colour is opt-in, persisted in the profile, and survives rehydration',
      () {
        final legacy = _profile({
          'shape': 'blobatar:nimbus:sun',
          'color': '#8b5cf6',
          'imageKind': 'shape',
        });
        expect(legacy.botFaceColorHex, isNull);
        expect(
          (BotVisualIdentity.resolve(legacy, ProfilePetInfo.disabled, null)!
                  as ProceduralFaceIdentity)
              .useShapeColor,
          isFalse,
        );
        final identity = ProceduralFaceIdentity(
          shapeWire: 'blobatar:nimbus:sun',
          dormantColorHex: '#ef4444',
          useShapeColor: true,
        );
        final metadata = identity.toBotModeMetadata();
        expect(metadata, {
          'shape': 'blobatar:nimbus:sun',
          'color': '#ef4444',
          'useShapeColor': true,
          'imageKind': 'shape',
          'custom': true,
        });
        final profile = _profile(metadata);
        expect(profile.botFaceColorHex, '#ef4444');
        expect(
          BotVisualIdentity.resolve(profile, ProfilePetInfo.disabled, null),
          identity,
        );
        expect(
          BotVisualIdentityState.rehydrate(
            profileName: 'nimbus',
            botMeta: metadata,
            hasAvatar: false,
          ).identity,
          identity,
        );
        final classic = BotVisualIdentityState(
          identity: ClassicFaceIdentity(shape: 'circle', colorHex: '#14b8a6'),
        );
        expect(
          classic.mergeBotMeta(metadata),
          isNot(contains('useShapeColor')),
        );
      },
    );
    test('pet serializes and resolves with the active pet contract', () {
      const identity = PetSpriteIdentity(slug: 'zoro', revision: 'rev-1');
      final metadata = identity.toBotModeMetadata();
      final resolved = BotVisualIdentity.resolve(
        _profile(metadata),
        const ProfilePetInfo(
          enabled: true,
          slug: 'zoro',
          spritesheetRevision: 'rev-1',
        ),
        null,
      );

      expect(resolved, isA<PetSpriteIdentity>());
      expect((resolved as PetSpriteIdentity).slug, identity.slug);
      expect(resolved.revision, identity.revision);
      _expectSafeOfficialMetadata(metadata, imageKind: 'photo');
    });

    test('profile image serializes and resolves without embedding bytes', () {
      final identity = ProfileImageIdentity(avatar: avatar, legacy: false);
      final metadata = identity.toBotModeMetadata();
      final resolved = BotVisualIdentity.resolve(
        _profile(metadata),
        ProfilePetInfo.disabled,
        avatar,
      );

      expect(resolved, isA<ProfileImageIdentity>());
      expect((resolved as ProfileImageIdentity).avatar, same(avatar));
      expect(resolved.legacy, isFalse);
      _expectSafeOfficialMetadata(metadata, imageKind: 'photo');
    });

    test('procedural face preserves its wire and dormant color', () {
      final identity = ProceduralFaceIdentity(
        shapeWire: 'blobatar:nimbus:organic',
        dormantColorHex: '#8b5cf6',
      );
      final metadata = identity.toBotModeMetadata();
      final resolved = BotVisualIdentity.resolve(
        _profile(metadata),
        ProfilePetInfo.disabled,
        null,
      );

      expect(resolved, isA<ProceduralFaceIdentity>());
      expect(
        (resolved as ProceduralFaceIdentity).shapeWire,
        identity.shapeWire,
      );
      expect(resolved.dormantColorHex, identity.dormantColorHex);
      _expectSafeOfficialMetadata(metadata, imageKind: 'shape');
    });

    test('classic face preserves its shape and normalized color', () {
      final identity = ClassicFaceIdentity(shape: 'cloud', colorHex: '#38bdf8');
      final metadata = identity.toBotModeMetadata();
      final resolved = BotVisualIdentity.resolve(
        _profile(metadata),
        ProfilePetInfo.disabled,
        null,
      );

      expect(resolved, isA<ClassicFaceIdentity>());
      expect((resolved as ClassicFaceIdentity).shape, identity.shape);
      expect(resolved.colorHex, identity.colorHex);
      _expectSafeOfficialMetadata(metadata, imageKind: 'shape');
    });
  });
}
