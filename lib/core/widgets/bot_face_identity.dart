import 'package:flutter/painting.dart';

import '../models/agent_profile.dart';
import 'hermes_bot_face.dart';

/// Where a Bot's face comes from, in priority order.
///
/// a) [avatar]: the Bot's configured raster avatar (photo / sprite) — the
///    image is circle-cropped and the state rides on the badge and glow;
/// b) [procedural]: the Bot's configured Desktop face (shape wire from
///    `ui_meta`), painted by [HermesBotFace] with its state expression;
/// c) [sphere]: nothing configured — the Grok-style sphere in the Bot's
///    colour (vertical gradient, two capsule eyes, no other features).
enum BotFaceSource { avatar, procedural, sphere }

/// Grok-style sphere palette: (top, base, bottom) of the vertical gradient.
/// Same geometry for every Bot; only the colour changes.
abstract final class BotSpherePalette {
  static const Map<String, (Color, Color, Color)> colors = {
    'grey': (Color(0xFFE9EAEE), Color(0xFFC9CBD1), Color(0xFFA5B9D8)),
    'teal': (Color(0xFF79E0C1), Color(0xFF46C49F), Color(0xFF2E9D80)),
    'orange': (Color(0xFFF4B04E), Color(0xFFE8932C), Color(0xFFC4741A)),
    'red': (Color(0xFFF0435F), Color(0xFFD7243F), Color(0xFFA8142B)),
    'violet': (Color(0xFF8F5CF6), Color(0xFF6D35EA), Color(0xFF4D1FC2)),
    'sky': (Color(0xFF7FB0FF), Color(0xFF4C86F2), Color(0xFF2E5FCC)),
  };

  /// Nearest palette entry to [hex] (`#rrggbb`) by base colour; a stable
  /// name-derived entry when the Bot has no colour.
  static String nearest(String? hex, {required String seed}) {
    final parsed = _parse(hex);
    if (parsed == null) {
      final keys = colors.keys.toList(growable: false);
      var hash = 7;
      for (final unit in seed.codeUnits) {
        hash = (hash * 31 + unit) & 0x7fffffff;
      }
      return keys[hash % keys.length];
    }
    // Low-saturation colours are grey whatever their hue.
    final hsl = HSLColor.fromColor(parsed);
    if (hsl.saturation < .18 || hsl.lightness > .9) return 'grey';
    String best = 'grey';
    var bestDistance = double.infinity;
    for (final entry in colors.entries) {
      if (entry.key == 'grey') continue;
      final base = HSLColor.fromColor(entry.value.$2);
      var dh = (hsl.hue - base.hue).abs();
      if (dh > 180) dh = 360 - dh;
      final distance = dh + (hsl.lightness - base.lightness).abs() * 40;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = entry.key;
      }
    }
    return best;
  }

  static Color? _parse(String? hex) {
    final value = hex?.trim().toLowerCase() ?? '';
    if (!RegExp(r'^#[0-9a-f]{6}$').hasMatch(value)) return null;
    return Color(0xFF000000 | int.parse(value.substring(1), radix: 16));
  }
}

/// The one identity resolver shared by widgets, notifications, Live Update
/// trackers and the app (spec 070 § Identity): a Bot always shows the face
/// its owner configured; the generic sphere is only the fallback.
final class BotFaceIdentity {
  const BotFaceIdentity._({
    required this.profile,
    required this.source,
    required this.shapeWire,
    required this.sphere,
  });

  final String profile;
  final BotFaceSource source;

  /// Desktop shape wire of a procedural face.
  final String? shapeWire;

  /// Sphere palette key (always set, also used for the sphere fallback when
  /// an avatar image cannot be decoded).
  final String sphere;

  /// Resolves [profile]'s face from its configured metadata.
  ///
  /// [paintsPhoto] is [AgentProfile.botPaintsPhoto] (a real picture, not
  /// Desktop's PNG backfill of a procedural face). [faceShape] is
  /// [AgentProfile.botFaceShape]; [colorHex] is [AgentProfile.botColorHex].
  static BotFaceIdentity resolve({
    required String profile,
    String? faceShape,
    String? colorHex,
    bool paintsPhoto = false,
  }) {
    final sphere = BotSpherePalette.nearest(colorHex, seed: profile);
    if (paintsPhoto) {
      return BotFaceIdentity._(
        profile: profile,
        source: BotFaceSource.avatar,
        shapeWire: faceShape,
        sphere: sphere,
      );
    }
    final shape = faceShape?.trim();
    if (shape != null && shape.isNotEmpty) {
      return BotFaceIdentity._(
        profile: profile,
        source: BotFaceSource.procedural,
        shapeWire: shape,
        sphere: sphere,
      );
    }
    return BotFaceIdentity._(
      profile: profile,
      source: BotFaceSource.sphere,
      shapeWire: null,
      sphere: sphere,
    );
  }

  /// Identity of a loaded profile; [name] is used when [p] is unknown.
  static BotFaceIdentity ofProfile(AgentProfile? p, {String? name}) => resolve(
    profile: p?.name ?? name ?? 'agent',
    faceShape: p?.botFaceShape,
    colorHex: p?.botColorHex,
    paintsPhoto: p?.botPaintsPhoto ?? false,
  );

  /// Procedural face to paint: the configured shape when it parses, else
  /// the name-derived Blobatar (Console renders a single face system;
  /// classic shapes stay readable for Desktop compatibility).
  HermesBlobatarFaceVisual get visual =>
      HermesBlobatarFaceVisual.tryParse(
        shapeWire: shapeWire ?? 'blobatar',
        profileName: profile,
      ) ??
      HermesBlobatarFaceVisual.tryParse(
        shapeWire: 'blobatar',
        profileName: profile,
      )!;

  /// Stable cache key of everything that changes the rendered face.
  String get cacheKey => '${source.name}:${shapeWire ?? ''}:$sphere';

  @override
  bool operator ==(Object other) =>
      other is BotFaceIdentity &&
      other.profile == profile &&
      other.cacheKey == cacheKey;

  @override
  int get hashCode => Object.hash(profile, cacheKey);

  @override
  String toString() => 'BotFaceIdentity($profile, $cacheKey)';
}
