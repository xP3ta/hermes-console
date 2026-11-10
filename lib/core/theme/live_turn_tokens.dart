import 'package:flutter/widgets.dart';

/// Measures of the live turn's block, from the look approved on 9 nov
/// (mock `turno3.html`, with the reinforced connector): the «Trabajando»
/// card, the window of at most four actions hanging from it, the reasoning
/// fragment and the tasks card. They live here (not in the widgets) so the
/// literal ratchet counts them once and changing the look is changing one
/// line.
abstract final class HermesLiveTurn {
  /// Actions painted at once; older ones leave by the top.
  static const int windowRows = 4;

  /// A pill of the window (the mock's `.rw`), without the gap above it.
  static const double rowHeight = 30;

  /// The gap between two pills (the mock's `margin-top`).
  static const double rowGap = 5;

  /// Glyph of the kind of tool, and the ring of its state.
  static const double glyphSize = 16;
  static const double ringSize = 15;

  /// The connector: a vertical line hanging from the «Trabajando» card and
  /// a horizontal elbow into each pill; the last pill gets a rounded corner.
  static const double connectorWidth = 2;
  static const double connectorInset = 18;
  static const double elbow = 18;
  static const double corner = 11;

  /// Width of the gutter that holds the connector.
  static const double gutter = connectorInset + connectorWidth + elbow;

  /// Muted green (`#6f9b7a`) at 80 % (`0xCC`), the same in both themes.
  static const Color connector = Color(0xCC6F9B7A);

  /// Soft violet of a memory step (brain glyph, tint and outline), the same
  /// in both themes; the text keeps the theme's own ink.
  static const Color memory = Color(0xFF9B7BE6);

  /// Opacity of a pill by how many pills follow it: the newest is whole,
  /// older ones fade (the mock's `.a1`..`.a3`).
  static const List<double> ageOpacity = [1, 0.85, 0.65, 0.45];

  /// Room (dp, text scale 1) the card's row needs to add the clock, and to
  /// say «herramientas» after the count.
  static const double metaWithClock = 220;
  static const double metaWithWords = 300;

  /// The painted «Trabajando» card (the 48 dp target is taller).
  static const double cardHeight = 36;

  /// A fragment of the last reasoning line, at most this many characters.
  static const int thoughtChars = 100;
  static const double cursorWidth = 5;
  static const double cursorHeight = 12;

  /// Tasks: what stays visible around the one in hand.
  static const int tasksNext = 2;
  static const List<double> nextOpacity = [0.55, 0.4];
  static const double doneOpacity = 0.6;
  static const double progressHeight = 4;
}
