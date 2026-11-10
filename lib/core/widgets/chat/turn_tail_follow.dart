import 'package:flutter/widgets.dart';

import '../../theme/motion.dart' show HermesMotion;

/// How far from the newest row a reader still counts as «following the tail»
/// while a long turn grows: the pinned zone, or less than one screen.
///
/// The transcript is a reversed list (offset 0 is the newest row), so the
/// distance to the tail is `pixels - minExtent`.
const double turnFollowMinBand = 100;

/// True when a reader at [pixels] is close enough to the tail that new steps
/// or text should carry the list with them. A reader who went up further than
/// one [viewport] is reading: the list leaves them where they are.
bool withinTurnFollowBand({
  required double pixels,
  required double minExtent,
  required double viewport,
}) {
  final band = viewport > turnFollowMinBand ? viewport : turnFollowMinBand;
  return pixels <= minExtent + band;
}

/// The eased follow already carrying each position to its newest row. A burst
/// of steps used to restart the ease on every event (each `animateTo` cancels
/// the previous one): the list kicked forward again and again instead of
/// settling in one motion. The entry is dropped when the animation ends or
/// anything else (a finger, a jump) replaces it.
final Expando<Object> _tailFollowInFlight = Expando<Object>('tailFollow');

/// Carries a reversed transcript to its newest row after a step or a delta.
/// No-op when the reader is not within [withinTurnFollowBand] or is already
/// there, and when an eased follow is already on its way. Eased when motion
/// is welcome; a jump (no animation) when reduced. Returns whether it moved
/// (or is still moving).
bool followTurnTail(ScrollController controller, {required bool reduceMotion}) {
  if (!controller.hasClients) return false;
  final position = controller.position;
  if (!position.hasContentDimensions) return false;
  if (position.pixels <= position.minScrollExtent) return false;
  if (!withinTurnFollowBand(
    pixels: position.pixels,
    minExtent: position.minScrollExtent,
    viewport: position.viewportDimension,
  )) {
    return false;
  }
  if (reduceMotion) {
    controller.jumpTo(position.minScrollExtent);
    return true;
  }
  if (_tailFollowInFlight[position] != null) return true;
  final token = Object();
  _tailFollowInFlight[position] = token;
  controller
      .animateTo(
        position.minScrollExtent,
        duration: HermesMotion.fast,
        curve: Curves.easeOut,
      )
      .whenComplete(() {
        if (identical(_tailFollowInFlight[position], token)) {
          _tailFollowInFlight[position] = null;
        }
      });
  return true;
}
