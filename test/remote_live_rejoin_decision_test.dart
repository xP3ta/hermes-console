// SPDX-License-Identifier: MIT
//
// remote-live: the decision of a post-cut viewer to rejoin the runtime of
// another surface's running turn (active_chat_service.dart). The end-to-end
// behaviour is pinned in canonical_session_authority_chat_test.dart (RL*).
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';

void main() {
  bool decide({
    bool running = true,
    bool canonical = true,
    bool attaches = true,
    bool conflict = false,
  }) => activeChatViewerRejoinsRunningForeignTurn(
    snapshotRunning: running,
    canonicalSessions: canonical,
    attachesRuntimeOnLoad: attaches,
    ownershipConflict: conflict,
  );

  test('a running turn on a canonical connection is rejoined', () {
    expect(decide(), isTrue);
  });

  test('an idle snapshot keeps the detached convergence (roster settles)', () {
    expect(decide(running: false), isFalse);
  });

  test('a legacy replay connection keeps the detached convergence', () {
    expect(decide(canonical: false), isFalse);
  });

  test('a chat that does not own a runtime on load never takes one', () {
    expect(decide(attaches: false), isFalse);
  });

  test('an ownership conflict (read-only / permission) never rejoins', () {
    expect(decide(conflict: true), isFalse);
  });
}
