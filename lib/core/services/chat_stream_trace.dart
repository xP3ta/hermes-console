import 'dart:developer' as developer;

/// F0 of the fluidity plan (REPORT-AUDITORIA-FLUIDEZ §4): measure the chat's
/// streaming path before changing it.
///
/// Two outputs, both content-free (only counts of characters, never text):
///  * Timeline instant events `hermes.chat.stream.<point>` for Perfetto on a
///    device. Compile-time gated like the voice trace: only the `qa` flavor
///    built with `--dart-define=HERMES_CHAT_STREAM_TRACE=true` emits them;
///    every other build drops them as dead code.
///  * Debug-only counters for tests (inside `assert`, so release builds keep
///    none of them): how many times each point ran and how many characters it
///    moved. They give the reference baseline (work, not milliseconds).
const String _chatStreamFlavor = String.fromEnvironment(
  'HERMES_FLAVOR',
  defaultValue: 'full',
);
const bool _chatStreamRequested = bool.fromEnvironment(
  'HERMES_CHAT_STREAM_TRACE',
  defaultValue: false,
);

const bool kChatStreamTraceEnabled =
    _chatStreamFlavor == 'qa' && _chatStreamRequested;

/// The fixed points of the streaming path. There is no free-form name or
/// argument: a caller cannot attach text, ids or URLs to a trace event.
enum ChatStreamPoint {
  /// The service published buffered deltas (`chars` = published length).
  flush('flush'),

  /// The screen revealed more of the live reply (`chars` = newly revealed,
  /// `pending` = still hidden).
  reveal('reveal'),

  /// The live reply's tail was rebuilt (`chars` = visible length).
  tailBuild('tail_build'),

  /// The turn ended (`chars` = characters shown at once in that frame that
  /// the reveal had not shown yet).
  turnEnd('turn_end'),

  /// Code was syntax-highlighted (`chars` = code length).
  highlight('highlight');

  const ChatStreamPoint(this.traceName);

  final String traceName;
}

abstract final class ChatStreamTrace {
  static final Map<ChatStreamPoint, int> _counts = {};
  static final Map<ChatStreamPoint, int> _chars = {};
  static int _lastTurnEndChars = 0;

  /// Times [point] ran since the last [debugReset] (debug builds only).
  static int debugCount(ChatStreamPoint point) => _counts[point] ?? 0;

  /// Characters [point] moved since the last [debugReset] (debug only).
  static int debugChars(ChatStreamPoint point) => _chars[point] ?? 0;

  /// What the last turn end showed at once (debug only).
  static int get debugLastTurnEndChars => _lastTurnEndChars;

  static void debugReset() {
    _counts.clear();
    _chars.clear();
    _lastTurnEndChars = 0;
  }

  static void mark(ChatStreamPoint point, {int chars = 0, int pending = 0}) {
    assert(() {
      _counts[point] = (_counts[point] ?? 0) + 1;
      _chars[point] = (_chars[point] ?? 0) + chars;
      if (point == ChatStreamPoint.turnEnd) _lastTurnEndChars = chars;
      return true;
    }());
    if (!kChatStreamTraceEnabled) return;
    developer.Timeline.instantSync(
      'hermes.chat.stream.${point.traceName}',
      arguments: {'chars': chars, 'pending': pending},
    );
  }
}
