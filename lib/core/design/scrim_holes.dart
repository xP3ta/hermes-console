// OPUS-CRISTAL: where a page's foot scrim leaves the content alone, so the
// smoked glass of the pieces above it frosts real content, not the scrim.
//
// The chat's foot scrim (HermesBottomScrim, QA 9529) dissolves the reply
// behind and beside the composer and the context pill. The glass strip blurs
// whatever is painted before it, scrim included: under the pill row the
// scrim's 0.86 of page colour left almost nothing to show (A/B 4f65668f).
// A toned strip that frosts publishes its pieces' outlines here, a few dp
// inside them; the scrim skips them. The gaps between and beside the pieces
// keep the scrim. Without a frosting toned strip there are no holes and the
// scrim paints as before.
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// What publishes holes: asked, in the scrim's own paint, for the holes as
/// they are now (current layout and eligibility), or null when none may
/// open. A read only: it must not notify or mark anything.
abstract interface class HermesScrimHoleSource {
  List<Path>? scrimHolesNow();

  /// The repaint boundary the source and its pieces are painted in.
  RenderObject? get scrimHolePass;
}

/// The nearest repaint boundary at or above [node]: what repaints with it.
RenderObject? hermesPaintPass(RenderObject? node) {
  for (var n = node; n != null; n = n.parent) {
    if (n.isRepaintBoundary) return n;
  }
  return null;
}

/// The outlines, in global logical coordinates, the scrim must not cover.
class HermesScrimHoles extends ChangeNotifier {
  /// How far inside each piece's outline a hole stays. The strip only
  /// publishes still pieces, so a hole never strays into a gap; the inset
  /// also keeps the hole off the piece's anti-aliased rim.
  static const double inset = 4;

  List<Path> _paths = const <Path>[];
  List<Rect> _bounds = const <Rect>[];
  HermesScrimHoleSource? _source;

  /// The holes; empty when nothing frosts.
  List<Path> get paths => _paths;

  /// Their bounds, the identity used to tell a change.
  List<Rect> get bounds => _bounds;

  bool get isEmpty => _paths.isEmpty;

  /// Replaces the holes, as [source] saw them; notifies only when their
  /// bounds change.
  void publish(List<Path> paths, {HermesScrimHoleSource? source}) {
    _source = paths.isEmpty ? null : source;
    final bounds = [for (final path in paths) path.getBounds()];
    if (listEquals(bounds, _bounds)) return;
    _paths = List.unmodifiable(paths);
    _bounds = List.unmodifiable(bounds);
    notifyListeners();
  }

  /// No holes: the scrim covers its whole area.
  void clear() => publish(const <Path>[]);

  /// The holes the scrim may cut in the paint it is doing, [pass] being the
  /// repaint boundary the scrim is painted in: the source's live outlines,
  /// and only if
  /// (1) the source paints in that same pass, so any layout or shape change
  /// of its pieces repaints the scrim in the same frame (a cached scrim
  /// layer can never keep an old hole), and (2) the source still frosts and
  /// its pieces' bounds are exactly those published. A piece moved, a veto
  /// or a lost zone in this frame gives none: never a stale hole outside a
  /// piece, not even for one frame. Read in paint, after layout; it
  /// notifies nothing. Fail-closed: otherwise, no holes.
  List<Path> current(RenderObject? pass) {
    final source = _source;
    if (_paths.isEmpty || source == null || pass == null) {
      return const <Path>[];
    }
    if (!identical(source.scrimHolePass, pass)) return const <Path>[];
    final now = source.scrimHolesNow();
    if (now == null) return const <Path>[];
    final bounds = [for (final path in now) path.getBounds()];
    // The live outlines, never the published ones: a piece whose shape
    // changed within the same bounds (rectangular to bevelled) gets its
    // current outline, so no old corner is ever cut outside it (Git,
    // OPUS-SCRIM-CONTOUR-FRESHNESS-1). The bounds check keeps the
    // published, still position as the condition to cut at all.
    return listEquals(bounds, _bounds) ? now : const <Path>[];
  }
}
