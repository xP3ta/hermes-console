enum ActionFollowState { finished, timedOut, cancelled }

/// How following a Dashboard action ended.
class ActionOutcome {
  const ActionOutcome(this.state, {this.exitCode, this.lines = const []});

  final ActionFollowState state;
  final int? exitCode;
  final List<String> lines;

  bool get succeeded => state == ActionFollowState.finished && exitCode == 0;
}

/// Follows a long Dashboard action by reading its status on a fixed interval,
/// for at most [maxReads] reads, and only while [follow]'s `keepGoing` says
/// the page that asked for it is still visible. There is no other polling.
class ActionFollower {
  ActionFollower({
    required this.read,
    this.interval = const Duration(milliseconds: 1200),
    this.maxReads = 150,
    Future<void> Function(Duration)? delay,
  }) : _delay = delay ?? Future<void>.delayed;

  /// One `GET /api/actions/<name>/status`.
  final Future<Map<String, dynamic>> Function(String name) read;
  final Duration interval;
  final int maxReads;
  final Future<void> Function(Duration) _delay;

  Future<ActionOutcome> follow(
    String name, {
    bool Function()? keepGoing,
    void Function(List<String> lines)? onLines,
  }) async {
    bool alive() => keepGoing?.call() ?? true;
    var lines = const <String>[];
    for (var attempt = 0; attempt < maxReads; attempt += 1) {
      if (!alive()) {
        return ActionOutcome(ActionFollowState.cancelled, lines: lines);
      }
      await _delay(interval);
      if (!alive()) {
        return ActionOutcome(ActionFollowState.cancelled, lines: lines);
      }
      final status = await read(name);
      final raw = status['lines'];
      lines = raw is List
          ? [for (final line in raw) line.toString()]
          : const <String>[];
      onLines?.call(lines);
      if (status['running'] != true) {
        final code = status['exit_code'];
        return ActionOutcome(
          ActionFollowState.finished,
          exitCode: code is int ? code : null,
          lines: lines,
        );
      }
    }
    return ActionOutcome(ActionFollowState.timedOut, lines: lines);
  }
}
