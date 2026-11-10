import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/bot_visual_identity.dart';
import '../widgets/hermes_bot_face.dart';
import 'studio_catalog.dart';

/// Ornament worn above the head (the first-generation editor; the studio
/// replaces it with [BotPiece]s).
enum BotCharacterTopper { none, antenna, sprout, crown, halo }

double _clamp(double value, double min, double max) =>
    value.isNaN ? min : (value < min ? min : (value > max ? max : value));

double _round(double value, int digits) {
  var factor = 1.0;
  for (var i = 0; i < digits; i++) {
    factor *= 10;
  }
  return (value * factor).round() / factor;
}

/// One piece placed on a character: where it sits (a fraction of the
/// canvas), how it is turned and sized, and whether it is mirrored.
@immutable
final class BotPiece {
  final BotPieceKind kind;

  /// Across and down, 0..1 of the canvas.
  final double x;
  final double y;

  /// Degrees, -180..180.
  final double rotation;

  /// Size multiplier, [BotStudioLimits.pieceScaleMin]..Max.
  final double scale;
  final bool flip;

  const BotPiece({
    required this.kind,
    required this.x,
    required this.y,
    this.rotation = 0,
    this.scale = 1,
    this.flip = false,
  });

  /// [kind] at its default place.
  factory BotPiece.placed(BotPieceKind kind) {
    final anchor = botPieceAnchors[kind] ?? (0.5, 0.2);
    return BotPiece(kind: kind, x: anchor.$1, y: anchor.$2);
  }

  /// Tolerant reader: an unknown kind yields null, any bad number takes its
  /// default and every number is clamped to its bounds.
  static BotPiece? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = enumByName(BotPieceKind.values, raw['k'] ?? raw['kind']);
    if (kind == null) return null;
    final anchor = botPieceAnchors[kind] ?? (0.5, 0.2);
    return BotPiece(
      kind: kind,
      x:
          boundedNumber(
            raw['x'],
            BotStudioLimits.piecePositionMin,
            BotStudioLimits.piecePositionMax,
          ) ??
          anchor.$1,
      y:
          boundedNumber(
            raw['y'],
            BotStudioLimits.piecePositionMin,
            BotStudioLimits.piecePositionMax,
          ) ??
          anchor.$2,
      rotation:
          boundedNumber(
            raw['r'] ?? raw['rotation'],
            BotStudioLimits.pieceRotationMin,
            BotStudioLimits.pieceRotationMax,
          ) ??
          0,
      scale:
          boundedNumber(
            raw['s'] ?? raw['scale'],
            BotStudioLimits.pieceScaleMin,
            BotStudioLimits.pieceScaleMax,
          ) ??
          1,
      flip: (raw['f'] ?? raw['flip']) == true,
    );
  }

  Map<String, Object?> toJson() => {
    'k': kind.name,
    'x': _round(x, 4),
    'y': _round(y, 4),
    if (rotation != 0) 'r': _round(rotation, 2),
    if (scale != 1) 's': _round(scale, 3),
    if (flip) 'f': true,
  };

  BotPiece copyWith({
    double? x,
    double? y,
    double? rotation,
    double? scale,
    bool? flip,
  }) => BotPiece(
    kind: kind,
    x: _clamp(
      x ?? this.x,
      BotStudioLimits.piecePositionMin,
      BotStudioLimits.piecePositionMax,
    ),
    y: _clamp(
      y ?? this.y,
      BotStudioLimits.piecePositionMin,
      BotStudioLimits.piecePositionMax,
    ),
    rotation: _clamp(
      rotation ?? this.rotation,
      BotStudioLimits.pieceRotationMin,
      BotStudioLimits.pieceRotationMax,
    ),
    scale: _clamp(
      scale ?? this.scale,
      BotStudioLimits.pieceScaleMin,
      BotStudioLimits.pieceScaleMax,
    ),
    flip: flip ?? this.flip,
  );

  @override
  bool operator ==(Object other) =>
      other is BotPiece &&
      other.kind == kind &&
      other.x == x &&
      other.y == y &&
      other.rotation == rotation &&
      other.scale == scale &&
      other.flip == flip;

  @override
  int get hashCode => Object.hash(kind, x, y, rotation, scale, flip);
}

/// A bot's saved look.
///
/// First generation: silhouette kind, seed, eyes, top ornament and colour,
/// riding the Blobatar face. The studio (format 2) adds a continuous body
/// ([form], [range], [strength]), eye styles with colour and size, placed
/// [pieces], solid or gradient colour, a [finish] and [fur].
///
/// Everything new is optional and its default is "as before": a stored
/// character without the new fields reads back identical and still draws
/// with the first-generation face ([isStudio] is false). Only a character
/// with a [form] is drawn by the studio renderer.
final class BotCharacter {
  /// Format version written to JSON (1 had no studio fields).
  static const int version = 2;

  static final RegExp _seedPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  /// Silhouette kind of [BlobatarShapeWire.kinds]; null derives it from the
  /// seed.
  final String? kind;

  /// Seed part of the face wire; empty follows the profile's name.
  final String seed;

  final HermesBotFaceEyeStyle eyes;
  final BotCharacterTopper topper;

  /// One of the face colour swatches; null keeps the seeded palette.
  final String? colorHex;

  /// Studio body. Null keeps the first-generation face.
  final BotForm? form;

  /// How far the deformation reaches across the outline, 0..1.
  final double range;

  /// How strong the deformation is, 0..1.
  final double strength;

  final BotEyeStyle eyeStyle;

  /// `#rrggbb`; null picks black or white for contrast with the body.
  final String? eyeColor;

  /// Eye size multiplier.
  final double eyeSize;

  final List<BotPiece> pieces;

  /// Custom solid body colour (`#rrggbb`).
  final String? bodyColor;

  /// Id of one of [botGradients]; wins over the solid colours.
  final String? gradient;

  final BotFinish finish;
  final bool fur;

  const BotCharacter({
    this.kind,
    this.seed = '',
    this.eyes = HermesBotFaceEyeStyle.seeded,
    this.topper = BotCharacterTopper.none,
    this.colorHex,
    this.form,
    this.range = 0.5,
    this.strength = 0.5,
    this.eyeStyle = BotEyeStyle.dot,
    this.eyeColor,
    this.eyeSize = 1,
    this.pieces = const [],
    this.bodyColor,
    this.gradient,
    this.finish = BotFinish.flat,
    this.fur = false,
  });

  static const BotCharacter standard = BotCharacter();

  /// What "new character" starts from: a round, seed-shaped studio body.
  static const BotCharacter fresh = BotCharacter(form: BotForm.round);

  static bool isValidSeed(String value) =>
      value.isEmpty || _seedPattern.hasMatch(value);

  bool get isStandard => this == standard;

  /// Drawn by the studio renderer.
  bool get isStudio => form != null;

  /// Tolerant reader: any field of the wrong type or outside its allowlist
  /// falls back to its default; a non-map yields null. Unknown keys and any
  /// newer format version are ignored, never an error.
  static BotCharacter? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['kind'];
    final seed = raw['seed'];
    final color = raw['color'];
    final rawPieces = raw['pieces'];
    final pieces = <BotPiece>[];
    if (rawPieces is List) {
      for (final item in rawPieces) {
        if (pieces.length >= BotStudioLimits.maxPieces) break;
        final piece = BotPiece.fromJson(item);
        if (piece != null) pieces.add(piece);
      }
    }
    final gradient = raw['gradient'];
    return BotCharacter(
      kind: kind is String && BlobatarShapeWire.kinds.contains(kind)
          ? kind
          : null,
      seed: seed is String && isValidSeed(seed.trim().toLowerCase())
          ? seed.trim().toLowerCase()
          : '',
      eyes: _byName(HermesBotFaceEyeStyle.values, raw['eyes']),
      topper: _byName(BotCharacterTopper.values, raw['topper']),
      colorHex:
          color is String &&
              ClassicFaceIdentity.colors.contains(color.trim().toLowerCase())
          ? color.trim().toLowerCase()
          : null,
      form: enumByName(BotForm.values, raw['form']),
      range:
          boundedNumber(
            raw['range'],
            BotStudioLimits.rangeMin,
            BotStudioLimits.rangeMax,
          ) ??
          0.5,
      strength:
          boundedNumber(
            raw['strength'],
            BotStudioLimits.strengthMin,
            BotStudioLimits.strengthMax,
          ) ??
          0.5,
      eyeStyle:
          enumByName(BotEyeStyle.values, raw['eyeStyle']) ?? BotEyeStyle.dot,
      eyeColor: normalizeHex(raw['eyeColor']),
      eyeSize:
          boundedNumber(
            raw['eyeSize'],
            BotStudioLimits.eyeSizeMin,
            BotStudioLimits.eyeSizeMax,
          ) ??
          1,
      pieces: List.unmodifiable(pieces),
      bodyColor: normalizeHex(raw['bodyColor']),
      gradient: gradient is String && botGradientById(gradient) != null
          ? gradient
          : null,
      finish: enumByName(BotFinish.values, raw['finish']) ?? BotFinish.flat,
      fur: raw['fur'] == true,
    );
  }

  static BotCharacter? tryParse(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      return fromJson(jsonDecode(source));
    } on FormatException {
      return null;
    }
  }

  static T _byName<T extends Enum>(List<T> values, Object? name) =>
      enumByName(values, name) ?? values.first;

  Map<String, Object?> toJson() => {
    'v': version,
    'kind': ?kind,
    if (seed.isNotEmpty) 'seed': seed,
    if (eyes != HermesBotFaceEyeStyle.seeded) 'eyes': eyes.name,
    if (topper != BotCharacterTopper.none) 'topper': topper.name,
    'color': ?colorHex,
    if (form != null) 'form': form!.name,
    if (range != 0.5) 'range': _round(range, 4),
    if (strength != 0.5) 'strength': _round(strength, 4),
    if (eyeStyle != BotEyeStyle.dot) 'eyeStyle': eyeStyle.name,
    'eyeColor': ?eyeColor,
    if (eyeSize != 1) 'eyeSize': _round(eyeSize, 3),
    if (pieces.isNotEmpty) 'pieces': [for (final p in pieces) p.toJson()],
    'bodyColor': ?bodyColor,
    'gradient': ?gradient,
    if (finish != BotFinish.flat) 'finish': finish.name,
    if (fur) 'fur': true,
  };

  BotCharacter copyWith({
    Object? kind = _keep,
    String? seed,
    HermesBotFaceEyeStyle? eyes,
    BotCharacterTopper? topper,
    Object? colorHex = _keep,
    Object? form = _keep,
    double? range,
    double? strength,
    BotEyeStyle? eyeStyle,
    Object? eyeColor = _keep,
    double? eyeSize,
    List<BotPiece>? pieces,
    Object? bodyColor = _keep,
    Object? gradient = _keep,
    BotFinish? finish,
    bool? fur,
  }) => BotCharacter(
    kind: identical(kind, _keep) ? this.kind : kind as String?,
    seed: seed ?? this.seed,
    eyes: eyes ?? this.eyes,
    topper: topper ?? this.topper,
    colorHex: identical(colorHex, _keep) ? this.colorHex : colorHex as String?,
    form: identical(form, _keep) ? this.form : form as BotForm?,
    range: _clamp(
      range ?? this.range,
      BotStudioLimits.rangeMin,
      BotStudioLimits.rangeMax,
    ),
    strength: _clamp(
      strength ?? this.strength,
      BotStudioLimits.strengthMin,
      BotStudioLimits.strengthMax,
    ),
    eyeStyle: eyeStyle ?? this.eyeStyle,
    eyeColor: identical(eyeColor, _keep) ? this.eyeColor : eyeColor as String?,
    eyeSize: _clamp(
      eyeSize ?? this.eyeSize,
      BotStudioLimits.eyeSizeMin,
      BotStudioLimits.eyeSizeMax,
    ),
    pieces: pieces == null
        ? this.pieces
        : List.unmodifiable(pieces.take(BotStudioLimits.maxPieces)),
    bodyColor: identical(bodyColor, _keep)
        ? this.bodyColor
        : bodyColor as String?,
    gradient: identical(gradient, _keep) ? this.gradient : gradient as String?,
    finish: finish ?? this.finish,
    fur: fur ?? this.fur,
  );

  static const Object _keep = Object();

  /// The same look as a studio character: a legacy one gets the body, eye
  /// style and ornament closest to what it wore. A studio character is
  /// returned as is.
  BotCharacter toStudio() {
    if (isStudio) return this;
    final mapped = switch (kind) {
      'organic' => BotForm.organic,
      'boxy' => BotForm.boxy,
      'cloud' => BotForm.cloud,
      _ => BotForm.round,
    };
    final ornament = switch (topper) {
      BotCharacterTopper.crown => BotPieceKind.crown,
      BotCharacterTopper.halo => BotPieceKind.halo,
      BotCharacterTopper.sprout => BotPieceKind.sprout,
      _ => null,
    };
    return copyWith(
      form: mapped,
      eyeStyle: switch (eyes) {
        HermesBotFaceEyeStyle.happy => BotEyeStyle.joy,
        HermesBotFaceEyeStyle.sleepy => BotEyeStyle.dreamy,
        HermesBotFaceEyeStyle.wide => BotEyeStyle.oval,
        HermesBotFaceEyeStyle.seeded => BotEyeStyle.dot,
      },
      topper: BotCharacterTopper.none,
      pieces: [...pieces, if (ornament != null) BotPiece.placed(ornament)],
    );
  }

  /// The face wire of this character's silhouette and seed.
  String get wire =>
      HermesBlobatarFaceVisual.buildWire(seedPart: seed, kind: kind) ??
      'blobatar';

  /// The renderable face of this character for [profileName]; never null.
  HermesBlobatarFaceVisual visual(String profileName) =>
      HermesBlobatarFaceVisual.tryParse(
        shapeWire: wire,
        profileName: profileName,
        colorHex: colorHex,
      ) ??
      HermesBlobatarFaceVisual.tryParse(
        shapeWire: 'blobatar',
        profileName: profileName,
      )!;

  @override
  bool operator ==(Object other) =>
      other is BotCharacter &&
      other.kind == kind &&
      other.seed == seed &&
      other.eyes == eyes &&
      other.topper == topper &&
      other.colorHex == colorHex &&
      other.form == form &&
      other.range == range &&
      other.strength == strength &&
      other.eyeStyle == eyeStyle &&
      other.eyeColor == eyeColor &&
      other.eyeSize == eyeSize &&
      listEquals(other.pieces, pieces) &&
      other.bodyColor == bodyColor &&
      other.gradient == gradient &&
      other.finish == finish &&
      other.fur == fur;

  @override
  int get hashCode => Object.hash(
    kind,
    seed,
    eyes,
    topper,
    colorHex,
    form,
    range,
    strength,
    eyeStyle,
    eyeColor,
    eyeSize,
    Object.hashAll(pieces),
    bodyColor,
    gradient,
    finish,
    fur,
  );
}
