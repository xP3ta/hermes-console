import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/chat_stream_trace.dart';

// F0 of the fluidity plan: the streaming trace is off unless a qa build asks
// for it, and its debug counters (what tests read) carry numbers only.
void main() {
  setUp(ChatStreamTrace.debugReset);

  test('off outside a qa build that asks for it', () {
    expect(kChatStreamTraceEnabled, isFalse);
  });

  test('counts each point and the characters it moved', () {
    ChatStreamTrace.mark(ChatStreamPoint.flush, chars: 12, pending: 3);
    ChatStreamTrace.mark(ChatStreamPoint.flush, chars: 8);
    ChatStreamTrace.mark(ChatStreamPoint.turnEnd, chars: 40);
    expect(ChatStreamTrace.debugCount(ChatStreamPoint.flush), 2);
    expect(ChatStreamTrace.debugChars(ChatStreamPoint.flush), 20);
    expect(ChatStreamTrace.debugCount(ChatStreamPoint.reveal), 0);
    expect(ChatStreamTrace.debugLastTurnEndChars, 40);
    ChatStreamTrace.debugReset();
    expect(ChatStreamTrace.debugCount(ChatStreamPoint.flush), 0);
    expect(ChatStreamTrace.debugLastTurnEndChars, 0);
  });

  test('trace names are the fixed hermes.chat.stream.* set', () {
    expect(ChatStreamPoint.values.map((p) => p.traceName), [
      'flush',
      'reveal',
      'tail_build',
      'turn_end',
      'highlight',
    ]);
  });
}
