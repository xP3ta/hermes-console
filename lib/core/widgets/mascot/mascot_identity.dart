import 'package:flutter/painting.dart';

/// The CC0 sprites the mascot can wear (see assets/mascot/LICENSES.md).
enum MascotSpriteKind {
  pixel('assets/mascot/pixel.webp'),
  nimbus('assets/mascot/nimbus.webp'),
  violet('assets/mascot/violet.webp');

  const MascotSpriteKind(this.asset);

  final String asset;
}

/// Who the mascot is: which sprite and which body colour.
///
/// The atlases are white bodies with dark eyes; [color] tints the body
/// through one modulate colour filter, so a profile's colour costs no
/// asset. [MascotIdentity.forProfile] picks both deterministically from a
/// profile or bot id; callers can override either later (settings).
final class MascotIdentity {
  const MascotIdentity({required this.sprite, required this.color});

  final MascotSpriteKind sprite;
  final Color color;

  /// Body colours. The first three are the sprites' own colours.
  static const List<Color> palette = <Color>[
    Color(0xFF78C8AA), // mint (Pixel)
    Color(0xFFE8821C), // orange (Nimbus)
    Color(0xFFAB78D2), // violet (Violet)
    Color(0xFF5A8BC8), // sky
    Color(0xFFE07AA0), // rose
    Color(0xFFA6C850), // lime
  ];

  /// The main Hermes profile: Pixel in mint, as in the chat v2 design.
  static const MascotIdentity hermes = MascotIdentity(
    sprite: MascotSpriteKind.pixel,
    color: Color(0xFF78C8AA),
  );

  /// Deterministic identity for [profileId]: the same id always gets the
  /// same sprite and colour, on every device and run (FNV-1a, not
  /// [String.hashCode], which may differ between platforms).
  factory MascotIdentity.forProfile(
    String profileId, {
    MascotSpriteKind? sprite,
    Color? color,
  }) {
    final hash = _fnv1a(profileId);
    const kinds = MascotSpriteKind.values;
    return MascotIdentity(
      sprite: sprite ?? kinds[hash % kinds.length],
      color: color ?? palette[(hash ~/ kinds.length) % palette.length],
    );
  }

  static int _fnv1a(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  @override
  bool operator ==(Object other) =>
      other is MascotIdentity && other.sprite == sprite && other.color == color;

  @override
  int get hashCode => Object.hash(sprite, color);
}
