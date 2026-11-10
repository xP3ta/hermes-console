// Geometry shared by every launcher widget drawing: one grid, one set of
// sizes, and the tap zones that Android lays over the picture.
//
// Everything here is in dp (the launcher's own unit). The painter draws a
// button from a rect and emits the very same rect as its tap zone, so the
// transparent native view Android places over the picture and the button
// the eye sees can never disagree: there is one rect, computed once.
import 'dart:ui' show Rect, Size;

/// The grid every measure sits on, in dp.
abstract final class LwGrid {
  static const double unit = 4;

  /// Rounds [value] to the grid.
  static double snap(double value) => (value / unit).roundToDouble() * unit;

  /// Rounds [value] up to the grid.
  static double ceil(double value) => (value / unit).ceilToDouble() * unit;

  /// Rounds [value] down to the grid.
  static double floor(double value) => (value / unit).floorToDouble() * unit;

  // ---------------------------------------------------------------- card

  /// Corner radius of a card; a card lower than twice this is a pill.
  static const double radius = 28;

  /// Inner margin of a card of two rows or more, the same on four sides.
  static const double pad = 16;

  /// Inner margin of a one-row card (horizontal / vertical).
  static const double stripPadH = 16;
  static const double stripPadV = 8;

  /// The hairline round the card, inside its edge.
  static const double hairline = 1;

  /// Space between two things that are not one.
  static const double gap = 12;

  /// Space between two lines of the same block.
  static const double gapTight = 4;

  // ---------------------------------------------------------------- tap

  /// Nothing tappable is smaller than this, in either direction.
  static const double tap = 48;

  /// A primary / secondary button of a two-row card.
  static const double button = 44;

  /// The small button of a one-row card.
  static const double buttonSmall = 36;

  /// A round icon button.
  static const double iconButton = 36;
  static const double iconButtonLarge = 48;

  // ---------------------------------------------------------------- faces

  static const double faceLarge = 60;
  static const double faceMedium = 48;
  static const double face = 40;
  static const double faceSmall = 32;
  static const double faceTiny = 28;

  /// The ring round a face that waits for you: a gap and a stroke.
  static const double ringGap = 3;
  static const double ringStroke = 2;

  // ---------------------------------------------------------------- type (sp)

  static const double eyebrow = 12;
  static const double caption = 12;
  static const double line = 14;
  static const double rowLine = 13;
  static const double rowTitle = 15;
  static const double title = 19;
  static const double titleSmall = 17;
  static const double big = 44;
  static const double bigSmall = 36;
  static const double kpi = 40;
  static const double kpiLead = 48;
  static const double button_ = 14;

  /// A text shrinks to this before anything is dropped.
  static const double minSp = 11;

  // ---------------------------------------------------------------- layout thresholds

  /// From this width a widget is four cells wide.
  static const double wideFrom = 250;

  /// Below this height a widget is one row.
  static const double boardFrom = 110;

  /// From this height a widget is four rows.
  static const double tallFrom = 300;
}

/// How many cells a placed widget spans, read from its size in dp.
enum LwSpan {
  twoByOne,
  twoByTwo,
  fourByOne,
  fourByTwo,
  fourByFour;

  static LwSpan of(Size dp) {
    final wide = dp.width >= LwGrid.wideFrom;
    if (dp.height < LwGrid.boardFrom) {
      return wide ? LwSpan.fourByOne : LwSpan.twoByOne;
    }
    if (dp.height >= LwGrid.tallFrom && wide) return LwSpan.fourByFour;
    return wide ? LwSpan.fourByTwo : LwSpan.twoByTwo;
  }

  bool get wide =>
      this == LwSpan.fourByOne ||
      this == LwSpan.fourByTwo ||
      this == LwSpan.fourByFour;

  bool get oneRow => this == LwSpan.twoByOne || this == LwSpan.fourByOne;

  /// A two-letter name for a file name.
  String get code => switch (this) {
    LwSpan.twoByOne => '2x1',
    LwSpan.twoByTwo => '2x2',
    LwSpan.fourByOne => '4x1',
    LwSpan.fourByTwo => '4x2',
    LwSpan.fourByFour => '4x4',
  };
}

/// Where a tap goes. Every destination is one the app already had.
enum LwActionKind {
  /// Open the app.
  app,

  /// Open the setup assistant.
  setup,

  /// Open a conversation (`instanceId`, `sessionId`).
  session,

  /// Open a notification-style destination (`payload`: cron job, task).
  payload,

  /// Approve a pending request (`payload`).
  approve,

  /// Deny a pending request (`payload`).
  deny,

  /// Start a new chat (`target`: composer / voice / camera).
  newChat,
}

/// One tap target over the picture: a rect in dp and what it does.
class LwTapZone {
  const LwTapZone({
    required this.rect,
    required this.kind,
    required this.label,
    this.payload,
    this.instanceId,
    this.sessionId,
    this.target,
  });

  /// Where the tap lands, in dp from the widget's top-left corner; at least
  /// [LwGrid.tap] on each side (see [LwTapZone.hit]).
  final Rect rect;
  final LwActionKind kind;

  /// What a screen reader says for this target, in the app's language.
  final String label;
  final String? payload;
  final String? instanceId;
  final String? sessionId;
  final String? target;

  /// The hit rect of a drawn [drawn] rect: grown to the tap minimum, centred
  /// on it, and kept inside [bounds].
  static Rect hit(Rect drawn, Rect bounds) {
    var rect = drawn;
    if (rect.width < LwGrid.tap) {
      rect = Rect.fromCenter(
        center: rect.center,
        width: LwGrid.tap,
        height: rect.height,
      );
    }
    if (rect.height < LwGrid.tap) {
      rect = Rect.fromCenter(
        center: rect.center,
        width: rect.width,
        height: LwGrid.tap,
      );
    }
    var left = rect.left;
    var top = rect.top;
    if (left < bounds.left) left = bounds.left;
    if (top < bounds.top) top = bounds.top;
    if (left + rect.width > bounds.right) left = bounds.right - rect.width;
    if (top + rect.height > bounds.bottom) top = bounds.bottom - rect.height;
    final out = Rect.fromLTWH(left, top, rect.width, rect.height);
    return out.intersect(bounds);
  }

  Map<String, Object?> toJson() => {
    'l': _r(rect.left),
    't': _r(rect.top),
    'r': _r(rect.right),
    'b': _r(rect.bottom),
    'kind': kind.name,
    'label': label,
    if (payload != null) 'payload': payload,
    if (instanceId != null) 'instance': instanceId,
    if (sessionId != null) 'session': sessionId,
    if (target != null) 'target': target,
  };

  static double _r(double v) => (v * 100).roundToDouble() / 100;
}
