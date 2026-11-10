import 'dart:math' as math;

import 'package:flutter/widgets.dart' show CharacterRange;

/// Presentation-only reveal of an authoritative, growing reply.
///
/// Network arrivals segment only their new suffix. A frame consumes cached
/// grapheme ends; it never scans the closed prefix, parses Markdown or copies
/// the reply. [end] is a UTF-16 offset the renderer can use separately from
/// its layout and opacity animations. [observe] also accepts corrections and
/// segment resets: this buffer never changes the authoritative source.
final class FrameStreamReveal {
  /// Keep the old minimum pace (six characters per 33 ms), independent of
  /// whether a display presents at 30, 60 or 120 Hz.
  static const double minimumRate = 6 / 0.033;

  /// A burst catches up promptly rather than accumulating a slow typewriter.
  static const Duration catchUp = Duration(milliseconds: 120);

  String _source = '';
  final List<int> _ends = [];
  int _head = 0;
  int _end = 0;
  Duration? _observedAt;
  double _arrivalRate = 0;
  double _credit = 0;

  String get source => _source;
  int get end => _end;
  int get pendingGraphemes => _ends.length - _head;
  bool get caughtUp => _end == _source.length;
  double get fractionalProgress => _credit;

  void reset() {
    _source = '';
    _ends.clear();
    _head = 0;
    _end = 0;
    _observedAt = null;
    _arrivalRate = 0;
    _credit = 0;
  }

  /// Call on source arrival, not on each animation frame. [now] belongs to
  /// the same monotonic clock for the whole turn; tests supply their clock.
  void observe(String source, Duration now) {
    if (source == _source) return;
    final previousLength = _source.length;
    final append = source.startsWith(_source);
    final before = pendingGraphemes;
    final at = append ? previousLength : 0;
    if (!append) {
      _ends.clear();
      _head = 0;
      _end = math.min(_end, source.length);
      _credit = 0;
      _arrivalRate = 0;
    }
    _source = source;

    // A delta may finish an emoji/combining sequence that began in the
    // previous delta. Start from that whole cluster, without walking the
    // prefix. The existing endpoint for it is replaced, not duplicated.
    final range = CharacterRange.at(source, at);
    final start = range.stringBeforeLength;
    while (_ends.isNotEmpty && _ends.last > start) {
      _ends.removeLast();
    }
    _head = math.min(_head, _ends.length);
    if (range.isNotEmpty) {
      final boundary = start + range.current.length;
      _ends.add(boundary);
      if (_end > start && _end < boundary) _end = boundary;
    }
    while (range.moveNext()) {
      _ends.add(range.stringBeforeLength + range.current.length);
    }
    // A correction may put the previous visible offset inside a new cluster.
    final visible = CharacterRange.at(source, _end);
    if (visible.isNotEmpty) {
      _end = visible.stringBeforeLength + visible.current.length;
    }
    while (_head < _ends.length && _ends[_head] <= _end) {
      _head++;
    }
    final arrived = math.max(0, pendingGraphemes - before);
    final previousTime = _observedAt;
    if (append && previousTime != null && now > previousTime && arrived > 0) {
      final seconds = (now - previousTime).inMicroseconds / 1000000;
      final sample = arrived / seconds;
      // Speed up immediately; relax gradually when arrivals slow down.
      _arrivalRate = math.max(sample, _arrivalRate * 0.75 + sample * 0.25);
    }
    _observedAt = now;

    // Release endpoints already consumed, keeping a bounded working queue
    // during long replies. Compaction happens on arrival, never on a frame.
    if (_head > 1024) {
      // Keep a small visible tail for the renderer's opacity mask.
      final consumed = _head - 64;
      _ends.removeRange(0, consumed);
      _head -= consumed;
    }
  }

  /// Advance once with the actual time since the previous presented frame.
  /// Fractional credit keeps the pace independent of the refresh rate.
  int advance(Duration elapsed) {
    if (caughtUp) {
      _credit = 0;
      return _end;
    }
    if (elapsed <= Duration.zero) return _end;
    final seconds = elapsed.inMicroseconds / 1000000;
    final catchUpSeconds = catchUp.inMicroseconds / 1000000;
    final rate = math.max(
      minimumRate,
      math.max(_arrivalRate, pendingGraphemes / catchUpSeconds),
    );
    final available = _credit + rate * seconds;
    final take = math.min(pendingGraphemes, available.floor());
    _credit = available - available.floor();
    if (take > 0) {
      _head += take;
      _end = _ends[_head - 1];
    }
    if (caughtUp) _credit = 0;
    return _end;
  }

  /// Beginning of the last [graphemes] already revealed, without scanning
  /// the source. The retained queue always includes the renderer's tail.
  int tailStart(int graphemes) {
    if (_head <= graphemes) return 0;
    return _ends[_head - graphemes - 1];
  }

  /// At most [graphemes] cached visible clusters, including both endpoints.
  List<int> tailBoundaries(int graphemes) {
    final from = math.max(0, _head - graphemes);
    return [
      from == 0 ? 0 : _ends[from - 1],
      for (var index = from; index < _head; index++) _ends[index],
    ];
  }

  /// Reduced motion, a paused follow or backgrounding shows the source
  /// directly and does not leave an animation clock alive.
  int finish() {
    _end = _source.length;
    _ends.clear();
    _head = 0;
    _credit = 0;
    return _end;
  }
}
