import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show immutable;

/// Catalogue of the character studio: every option the editor offers, as
/// plain data. Names are stable identifiers written to storage; the visible
/// labels live in the l10n catalogs (prefix `bst`).

/// Base silhouette of a studio character.
enum BotForm { round, organic, boxy, rectangle, cloud }

/// Eye drawings. [dot] is what a new studio character wears.
enum BotEyeStyle {
  dot,
  oval,
  joy,
  dreamy,
  glint,
  bold,
  lantern,
  ring,
  wink,
  amazed,
  narrow,
  grumpy,
  slit,
  undead,
  heart,
}

/// Shading of the body.
enum BotFinish { flat, matte, soft, glossy }

/// Pieces that can be placed on a character.
enum BotPieceKind {
  catEars,
  bearEars,
  bunnyEars,
  crown,
  horn,
  halo,
  swirl,
  sprout,
  leaf,
  wing,
  tail,
  star,
  heart,
  bow,
  paw,
  fin,
  bolt,
  flower,
  moon,
  drop,
}

/// Animation states of the preview. The first group maps onto the face
/// motion engine as it is; the rest are poses layered on top of it.
enum BotStudioState {
  still,
  idle,
  listen,
  think,
  work,
  speak,
  curious,
  celebrate,
  love,
  oops,
  sleep,
  bounce,
  dance,
  spin,
}

/// Bounds of every numeric field. Storage, the editor's sliders and the
/// generated-spec validator all clamp to these.
abstract final class BotStudioLimits {
  static const double rangeMin = 0;
  static const double rangeMax = 1;
  static const double strengthMin = 0;
  static const double strengthMax = 1;
  static const double eyeSizeMin = 0.6;
  static const double eyeSizeMax = 1.6;
  static const double pieceScaleMin = 0.4;
  static const double pieceScaleMax = 2.5;
  static const double pieceRotationMin = -180;
  static const double pieceRotationMax = 180;
  static const double piecePositionMin = 0;
  static const double piecePositionMax = 1;
  static const int maxPieces = 12;
  static const int maxNameLength = 40;
}

/// A named two- or three-stop gradient of the body.
@immutable
final class BotGradient {
  final String id;
  final List<String> stops;

  const BotGradient(this.id, this.stops);
}

/// The body gradients, by stable id.
const List<BotGradient> botGradients = [
  BotGradient('sunrise', ['#fb923c', '#f472b6']),
  BotGradient('zest', ['#facc15', '#84cc16']),
  BotGradient('bay', ['#22d3ee', '#2563eb']),
  BotGradient('gumdrop', ['#f9a8d4', '#a78bfa']),
  BotGradient('cinder', ['#ef4444', '#7f1d1d']),
  BotGradient('nightfall', ['#6366f1', '#0f172a']),
  BotGradient('tide', ['#2dd4bf', '#1d4ed8']),
  BotGradient('apricot', ['#fdba74', '#fb7185']),
  BotGradient('plum', ['#c026d3', '#4c1d95']),
  BotGradient('spearmint', ['#86efac', '#14b8a6']),
  BotGradient('borealis', ['#34d399', '#6366f1', '#a855f7']),
  BotGradient('sherbet', ['#fde68a', '#fda4af']),
  BotGradient('petal', ['#fecdd3', '#e879f9']),
  BotGradient('pearl', ['#e2e8f0', '#a5b4fc']),
];

BotGradient? botGradientById(String? id) {
  if (id == null) return null;
  for (final gradient in botGradients) {
    if (gradient.id == id) return gradient;
  }
  return null;
}

/// Swatches offered for eyes besides "automatic" and the custom colour.
const List<String> botEyeSwatches = [
  '#111827',
  '#ffffff',
  '#7c3aed',
  '#2563eb',
  '#dc2626',
  '#16a34a',
];

final RegExp _hexPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

/// A `#rrggbb` string normalised to lower case, or null when it is not one.
String? normalizeHex(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return _hexPattern.hasMatch(text) ? text.toLowerCase() : null;
}

/// The opaque colour of a normalised `#rrggbb` string.
Color colorFromHex(String hex) => Color(0xff000000 | _hexValue(hex));

int _hexValue(String hex) => int.parse(hex.substring(1), radix: 16);

/// `#rrggbb` of an opaque colour.
String hexFromColor(Color color) {
  final value = color.toARGB32() & 0xffffff;
  return '#${value.toRadixString(16).padLeft(6, '0')}';
}

/// Where a piece lands when it is added: a fraction of the canvas, across
/// then down.
const Map<BotPieceKind, (double, double)> botPieceAnchors = {
  BotPieceKind.catEars: (0.5, 0.2),
  BotPieceKind.bearEars: (0.5, 0.2),
  BotPieceKind.bunnyEars: (0.5, 0.17),
  BotPieceKind.crown: (0.5, 0.17),
  BotPieceKind.horn: (0.5, 0.15),
  BotPieceKind.halo: (0.5, 0.1),
  BotPieceKind.swirl: (0.5, 0.14),
  BotPieceKind.sprout: (0.5, 0.14),
  BotPieceKind.leaf: (0.7, 0.2),
  BotPieceKind.wing: (0.2, 0.56),
  BotPieceKind.tail: (0.85, 0.7),
  BotPieceKind.star: (0.75, 0.2),
  BotPieceKind.heart: (0.78, 0.22),
  BotPieceKind.bow: (0.35, 0.2),
  BotPieceKind.paw: (0.8, 0.78),
  BotPieceKind.fin: (0.16, 0.58),
  BotPieceKind.bolt: (0.8, 0.2),
  BotPieceKind.flower: (0.3, 0.2),
  BotPieceKind.moon: (0.25, 0.2),
  BotPieceKind.drop: (0.8, 0.25),
};

/// [value] as a finite number clamped to `[min, max]`, or null when it is
/// not a finite number (text, null, NaN, infinity).
double? boundedNumber(Object? value, double min, double max) {
  if (value is! num || !value.isFinite) return null;
  return value.toDouble().clamp(min, max).toDouble();
}

/// The member of [values] named [name], or null.
T? enumByName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}
