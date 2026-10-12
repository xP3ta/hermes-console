import 'agent_profile.dart';
import 'profile_pet.dart';

/// Parsed form of Hermes Desktop's controlled procedural-face wire.
final class BlobatarShapeWire {
  static const kinds = <String>{
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
  };

  final String seed;
  final String? kind;

  const BlobatarShapeWire._({this.seed = '', this.kind});

  bool get followsProfileName => seed.isEmpty;

  String get wire => switch ((seed, kind)) {
    ('', null) => 'blobatar',
    ('', final String kind) => 'blobatar::$kind',
    (final String seed, null) => 'blobatar:$seed',
    (final String seed, final String kind) => 'blobatar:$seed:$kind',
  };

  BlobatarShapeWire withKind(String? value) =>
      parse(BlobatarShapeWire._(seed: seed, kind: value).wire);

  BlobatarShapeWire withSeed(String value) =>
      parse(BlobatarShapeWire._(seed: value, kind: kind).wire);

  static BlobatarShapeWire parse(String raw) =>
      tryParse(raw) ?? (throw const FormatException('Invalid Blobatar wire'));

  static BlobatarShapeWire? tryParse(Object? raw) {
    if (raw is! String) return null;
    final value = raw.trim();
    if (value != raw || value != value.toLowerCase()) return null;
    if (value == 'blobatar') return const BlobatarShapeWire._();
    final parts = value.split(':');
    if (parts.length < 2 || parts.length > 3 || parts.first != 'blobatar') {
      return null;
    }
    final seed = parts[1];
    if (seed.isNotEmpty &&
        !RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(seed)) {
      return null;
    }
    String? kind;
    if (parts.length == 3) {
      kind = parts[2];
      if (!kinds.contains(kind)) return null;
    } else if (seed.isEmpty) {
      return null;
    }
    return BlobatarShapeWire._(seed: seed, kind: kind);
  }
}

/// One effective identity. Raster bytes and pet sheets remain in their own
/// authoritative stores; `ui_meta` only receives Desktop's small wire fields.
sealed class BotVisualIdentity {
  const BotVisualIdentity();

  Map<String, dynamic> toBotModeMetadata();

  /// Android precedence: active pet > photo > Blobatar > classic face.
  static BotVisualIdentity? resolve(
    AgentProfile profile,
    ProfilePetInfo pet,
    AgentProfileAvatar? avatar,
  ) {
    if (pet.enabled && pet.slug.isNotEmpty) {
      return PetSpriteIdentity(
        slug: pet.slug,
        revision: pet.spritesheetRevision,
      );
    }

    final imageKind = profile.botImageKind;
    if (avatar != null && imageKind != 'shape') {
      return ProfileImageIdentity(avatar: avatar, legacy: imageKind != 'photo');
    }

    final shape = profile.botShape;
    final blob = BlobatarShapeWire.tryParse(shape);
    if (blob != null) {
      return ProceduralFaceIdentity(
        shapeWire: blob.wire,
        dormantColorHex: profile.botColorHex,
        useShapeColor: profile.botUsesShapeColor,
      );
    }
    final color = profile.botColorHex;
    if (shape != null && color != null) {
      try {
        return ClassicFaceIdentity(shape: shape, colorHex: color);
      } on FormatException {
        return null;
      }
    }
    return null;
  }
}

final class PetSpriteIdentity extends BotVisualIdentity {
  final String slug;
  final String? revision;

  const PetSpriteIdentity({required this.slug, this.revision});

  @override
  Map<String, dynamic> toBotModeMetadata() => const {
    'imageKind': 'photo',
    'custom': true,
  };

  @override
  bool operator ==(Object other) =>
      other is PetSpriteIdentity &&
      other.slug == slug &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(slug, revision);
}

final class ProfileImageIdentity extends BotVisualIdentity {
  final AgentProfileAvatar avatar;
  final bool legacy;

  const ProfileImageIdentity({required this.avatar, required this.legacy});

  @override
  Map<String, dynamic> toBotModeMetadata() => const {
    'imageKind': 'photo',
    'custom': true,
  };
}

final class ProceduralFaceIdentity extends BotVisualIdentity {
  final String shapeWire;
  final String? dormantColorHex;
  final bool useShapeColor;

  ProceduralFaceIdentity({
    required String shapeWire,
    String? dormantColorHex,
    this.useShapeColor = false,
  }) : shapeWire = BlobatarShapeWire.parse(shapeWire).wire,
       dormantColorHex = _optionalClassicColor(dormantColorHex);

  @override
  Map<String, dynamic> toBotModeMetadata() => {
    'shape': shapeWire,
    if (dormantColorHex != null) 'color': dormantColorHex,
    if (useShapeColor && dormantColorHex != null) 'useShapeColor': true,
    'imageKind': 'shape',
    'custom': true,
  };

  @override
  bool operator ==(Object other) =>
      other is ProceduralFaceIdentity &&
      other.shapeWire == shapeWire &&
      other.dormantColorHex == dormantColorHex &&
      other.useShapeColor == useShapeColor;

  @override
  int get hashCode => Object.hash(shapeWire, dormantColorHex, useShapeColor);
}

final class ClassicFaceIdentity extends BotVisualIdentity {
  static const shapes = <String>{
    'circle',
    'blob',
    'squircle',
    'pill',
    'triangle',
    'hexagon',
    'cloud',
    'drop',
  };
  static const colors = <String>{
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
  };

  final String shape;
  final String colorHex;

  factory ClassicFaceIdentity({
    required String shape,
    required String colorHex,
  }) {
    final normalizedShape = shape.trim().toLowerCase();
    final normalizedColor = colorHex.trim().toLowerCase();
    if (!shapes.contains(normalizedShape) ||
        !colors.contains(normalizedColor)) {
      throw const FormatException('Invalid classic face');
    }
    return ClassicFaceIdentity._(normalizedShape, normalizedColor);
  }

  const ClassicFaceIdentity._(this.shape, this.colorHex);

  @override
  Map<String, dynamic> toBotModeMetadata() => {
    'shape': shape,
    'color': colorHex,
    'imageKind': 'shape',
    'custom': true,
  };

  @override
  bool operator ==(Object other) =>
      other is ClassicFaceIdentity &&
      other.shape == shape &&
      other.colorHex == colorHex;

  @override
  int get hashCode => Object.hash(shape, colorHex);
}

/// Effective identity plus dormant/compatibility state required for a fresh
/// read-modify-write of `ui_meta['hermes-bots']`.
final class BotVisualIdentityState {
  final BotVisualIdentity identity;
  final String? dormantColorHex;
  final bool hasPetImageConflict;
  final String? preservedUnknownShape;

  const BotVisualIdentityState({
    required this.identity,
    this.dormantColorHex,
    this.hasPetImageConflict = false,
    this.preservedUnknownShape,
  });

  factory BotVisualIdentityState.rehydrate({
    required String profileName,
    required Map<String, dynamic> botMeta,
    required bool hasAvatar,
    String? activePetSlug,
  }) {
    final petSlug = _petSlug(activePetSlug);
    final imageKind = _text(botMeta['imageKind'])?.toLowerCase();
    final rawShape = _text(botMeta['shape']);
    final shape = rawShape?.toLowerCase();
    final color = _optionalClassicColor(_text(botMeta['color']));

    if (petSlug != null) {
      return BotVisualIdentityState(
        identity: PetSpriteIdentity(slug: petSlug),
        dormantColorHex: color,
        hasPetImageConflict: hasAvatar && imageKind == 'photo',
        preservedUnknownShape: _unknownShape(rawShape),
      );
    }
    if (hasAvatar && imageKind != 'shape') {
      // This compatibility state has no bytes yet. Callers that need the
      // concrete identity use [BotVisualIdentity.resolve] after get_asset.
      return BotVisualIdentityState(
        identity: _LegacyProfileImageMarker(),
        dormantColorHex: color,
        preservedUnknownShape: _unknownShape(rawShape),
      );
    }
    final blob = BlobatarShapeWire.tryParse(shape);
    if (blob != null) {
      return BotVisualIdentityState(
        identity: ProceduralFaceIdentity(
          shapeWire: blob.wire,
          dormantColorHex: color,
          useShapeColor: botMeta['useShapeColor'] == true,
        ),
        dormantColorHex: color,
      );
    }
    if (shape != null && color != null) {
      try {
        return BotVisualIdentityState(
          identity: ClassicFaceIdentity(shape: shape, colorHex: color),
        );
      } on FormatException {
        // Preserve opaque legacy metadata, but render a controlled fallback.
      }
    }
    return BotVisualIdentityState(
      identity: ClassicFaceIdentity(
        shape: _defaultShape(profileName),
        colorHex: color ?? '#8b5cf6',
      ),
      dormantColorHex: color,
      preservedUnknownShape: rawShape,
    );
  }

  Map<String, dynamic> mergeBotMeta(Map<String, dynamic> fresh) {
    final merged = Map<String, dynamic>.from(fresh)
      ..remove('image')
      ..remove('pet')
      ..remove('useShapeColor')
      ..addAll(identity.toBotModeMetadata());
    return Map<String, dynamic>.unmodifiable(merged);
  }

  static String? _unknownShape(String? value) {
    if (value == null) return null;
    final normalized = value.toLowerCase();
    return ClassicFaceIdentity.shapes.contains(normalized) ||
            BlobatarShapeWire.tryParse(normalized) != null
        ? null
        : value;
  }
}

/// Marker used only before `profiles.get_asset` resolves concrete bytes.
final class _LegacyProfileImageMarker extends BotVisualIdentity {
  @override
  Map<String, dynamic> toBotModeMetadata() => const {
    'imageKind': 'photo',
    'custom': true,
  };
}

String? _optionalClassicColor(String? raw) {
  if (raw == null) return null;
  final value = raw.trim().toLowerCase();
  return ClassicFaceIdentity.colors.contains(value) ? value : null;
}

String? _petSlug(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty || value.length > 128) return null;
  return RegExp(
        r'^[a-z0-9][a-z0-9_-]{0,127}$',
        caseSensitive: false,
      ).hasMatch(value)
      ? value
      : null;
}

String? _text(Object? raw) {
  if (raw is! String) return null;
  final value = raw.trim();
  return value.isEmpty ? null : value;
}

String _defaultShape(String name) {
  const shapes = <String>[
    'circle',
    'squircle',
    'pill',
    'triangle',
    'hexagon',
    'cloud',
    'drop',
  ];
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = ((hash * 31) + unit) & 0xffffffff;
  }
  return shapes[hash % shapes.length];
}

// Compatibility aliases for call sites that use the longer state names.
typedef BlobatarWire = BlobatarShapeWire;
typedef BotPetSpriteIdentity = PetSpriteIdentity;
typedef BotProceduralFaceIdentity = ProceduralFaceIdentity;
typedef BotClassicFaceIdentity = ClassicFaceIdentity;
