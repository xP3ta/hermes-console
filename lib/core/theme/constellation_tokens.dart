import 'dart:ui' show Color;

/// The night sky of the memory constellation: its colours and its one timing.
///
/// The map is a scene of its own, always dark whatever the app's theme, so
/// these are fixed values, kept here with the other design tokens.
abstract final class ConstellationTokens {
  /// The page and the sky.
  static const Color night = Color(0xFF04051A);

  /// A star by its kind.
  static const Color memory = Color(0xFF7BE0B8);
  static const Color skill = Color(0xFF9FB0FF);
  static const Color other = Color(0xFFFFC27A);

  /// The three slow clouds.
  static const Color nebulaViolet = Color(0x574636DC);
  static const Color nebulaMagenta = Color(0x3D963CC8);
  static const Color nebulaTeal = Color(0x331496BE);

  /// Twinkling dust and the shooting star's fading tail.
  static const Color dust = Color(0xFFCFD6FF);
  static const Color streakTail = Color(0x00C8D2FF);

  /// The lines between stars, and the ones of the focused star.
  static const Color line = Color(0xFF829AFF);
  static const Color lineLit = Color(0xFFA0AFFF);

  /// The light that travels along a lit line.
  static const Color sparkGlow = Color(0x55D2DCFF);
  static const Color sparkCore = Color(0xFFFFFFFF);

  /// The dark inside of a star.
  static const Color starBody = Color(0xFF0C0E30);

  /// The ball of dust is shown at least this long, so a fast answer does not
  /// make it flash.
  static const Duration minimumLoad = Duration(milliseconds: 900);
}
