/// Wire identity of a turn's streamed reply (Hermes 0.23.1 public contract:
/// `tui_gateway/stream_segments.py`, `contracts/events.py`
/// MessageDeltaPayload / MessageInterimPayload).
///
/// A prompt turn stamps `message.start` with `turn_id`, every
/// `message.delta` with `turn_id` + `segment` (how many interim seals came
/// before it) + `offset` (UTF-16 code units of that segment already sent),
/// and every `message.interim` with the `turn_id` + `segment` it seals. The
/// same frame can reach the chat twice under a new sequence (a reconnect
/// replay, a superseded attempt re-streaming its segment, a second socket);
/// [ReplySegments] remembers how far the turn's reply was applied so a
/// re-sent chunk or seal changes nothing. Frames without a valid stamp
/// (older servers, other emitters) are applied as they come.
library;

/// A frame's stamp; null when the payload carries none (or an invalid one).
final class ReplyStamp {
  final String turnId;
  final int segment;

  /// Only deltas carry it; null for a seal or an invalid offset.
  final int? offset;

  const ReplyStamp(this.turnId, this.segment, [this.offset]);

  static int? _count(Object? value) =>
      value is int && value >= 0 ? value : null;

  static ReplyStamp? of(Map<String, dynamic> payload) {
    final turn = payload['turn_id'];
    final segment = _count(payload['segment']);
    if (turn is! String || turn.isEmpty || segment == null) return null;
    return ReplyStamp(turn, segment, _count(payload['offset']));
  }
}

/// How far one turn's reply has been applied.
final class ReplySegments {
  String? _turn;
  int _segment = 0;

  /// UTF-16 code units of [_segment] applied (Dart `String.length` units).
  int _end = 0;

  /// A snapshot's segment-0 text length waiting for the turn's first stamped
  /// frame (the chat opened or re-attached mid-turn, before any stamp).
  int? _floor;

  /// The part of a stamped delta's [text] not applied yet: '' for a
  /// re-send, the unseen tail for an overlap, the whole text for a new
  /// segment/turn or a gap (frames lost in between are not invented).
  String admitDelta(ReplyStamp stamp, String text) {
    final offset = stamp.offset ?? 0;
    final end = offset + text.length;
    final floor = _floor;
    if (_turn != stamp.turnId && floor != null && stamp.segment == 0) {
      // What a snapshot already put on screen counts as applied: also when
      // the cursor still describes an earlier turn whose end never arrived
      // (it ended while the transport was down) and the snapshot is of the
      // turn this frame belongs to.
      _turn = stamp.turnId;
      _segment = 0;
      _end = floor;
    }
    _floor = null;
    if (_turn != stamp.turnId || stamp.segment > _segment) {
      _turn = stamp.turnId;
      _segment = stamp.segment;
      _end = end;
      return text;
    }
    if (stamp.segment < _segment || end <= _end) return '';
    final seen = _end - offset;
    _end = end;
    return seen > 0 ? text.substring(seen) : text;
  }

  /// Forgets what was applied: a turn boundary (start, end, error, cancel).
  /// A frame of the next turn carries a new `turn_id` anyway; this also
  /// drops a pending snapshot floor of the turn that ended.
  void reset() {
    _turn = null;
    _segment = 0;
    _end = 0;
    _floor = null;
  }

  /// A server snapshot of the running turn replaced the live reply: its
  /// `inflight.assistant` is every delta of the turn appended (Hermes 0.23.1
  /// `session_history._append_inflight_delta`), so while the turn is still
  /// in segment 0 it is exactly what that segment has applied. The cursor
  /// then describes the screen: a re-sent or replayed chunk the snapshot
  /// already holds is dropped, one beyond it applies. Past a seal the
  /// snapshot no longer tells where the segment starts: the cursor is kept,
  /// as Desktop keeps it (never reset on resume).
  void alignTo(int snapshotUnits) {
    if (snapshotUnits < 0) return;
    _floor = snapshotUnits;
    if (_turn == null) return;
    if (_segment == 0) _end = snapshotUnits;
  }

  /// Whether a stamped seal closes a segment not sealed yet; a copy of a
  /// seal already applied returns false.
  bool admitSeal(ReplyStamp stamp) {
    _floor = null;
    if (_turn == stamp.turnId && stamp.segment < _segment) return false;
    _turn = stamp.turnId;
    _segment = stamp.segment + 1;
    _end = 0;
    return true;
  }
}
