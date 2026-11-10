// dp-4 (Desktop parity): Desktop pulls one signature-gated tail of the open
// transcript on every (re)connect and on return to the window
// (apps/desktop/src/app/contrib/hooks/use-background-sync.ts 1149-1240,
// #94779 / #125532). Console's return check already runs on resume (the
// probe skips the read when the tail is unchanged, see
// stale_resume_redirect_test 'a partial page paints the rows after the
// correction once'); the reconnect edge now arms the same check.

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';

void main() {
  bool arms({
    bool? was = false,
    bool connected = true,
    bool streaming = false,
    bool foreground = true,
  }) => chatReconnectArmsReturnCheck(
    wasConnected: was,
    connected: connected,
    streaming: streaming,
    appForeground: foreground,
  );

  test('a socket that was down and is up again arms the tail check', () {
    expect(arms(), isTrue);
  });

  test('binding the chat (no previous state) is not a reconnect', () {
    expect(arms(was: null), isFalse);
  });

  test('staying connected or going down arms nothing', () {
    expect(arms(was: true), isFalse);
    expect(arms(connected: false), isFalse);
    expect(arms(was: true, connected: false), isFalse);
  });

  test('a live turn keeps its own recovery; a hidden app reads nothing', () {
    expect(arms(streaming: true), isFalse);
    expect(arms(foreground: false), isFalse);
  });
}
