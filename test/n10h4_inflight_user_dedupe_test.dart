import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/utils/chat_turn.dart';

/// N10h4: recovery with an empty snapshot must not paint the prompt twice
/// (own row + `user-inflight`). Mirrors Desktop's last-user-run check in
/// `use-session-actions/utils.ts`.
void main() {
  const prompt = 'Ya esta con wifi';

  DesktopSessionProjection recover(
    List<Map<String, dynamic>> fallbackNewestFirst, {
    String user = prompt,
    bool bridge = true,
  }) => const DesktopSessionReconciler().project(
    DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-1',
      storedSessionId: 'stored',
      created: false,
      inflight: DesktopInflightTurn(user: user, streaming: true),
      running: true,
    ),
    fallbackNewestFirst: fallbackNewestFirst,
    previousNewestFirst: fallbackNewestFirst,
    bridgeOwnedLiveUser: bridge,
  );

  int realUsers(DesktopSessionProjection p) =>
      p.messagesNewestFirst.where(isRealUserTurn).length;

  // The live row already carries streamed text: an empty one would let the
  // downstream coalescer hide the twin by accident.
  Map<String, dynamic> pipeline() => {
    'role': 'assistant',
    'content': 'partial answer',
    '_pipeline': true,
  };
  Map<String, dynamic> oldAnswer() => {
    'role': 'assistant',
    'content': 'previous answer',
  };
  Map<String, dynamic> durableAnswer() => {
    'role': 'assistant',
    'content': 'done',
    'id': 480601,
    '_desktopSnapshotKind': 'persisted',
  };

  for (final variant in <String, Map<String, dynamic>>{
    'optimistic': {'role': 'user', 'content': prompt, '_optimistic': true},
    'durable without started_at': {
      'role': 'user',
      'content': prompt,
      'id': 480603,
    },
  }.entries) {
    test('one bubble when the open prompt is ${variant.key}', () {
      final p = recover([pipeline(), variant.value, oldAnswer()]);
      expect(realUsers(p), 1);
      expect(
        p.messagesNewestFirst.any(
          (m) => m['_desktopSnapshotKey'] == 'user-inflight-runtime-1',
        ),
        isFalse,
      );
    });
  }

  test('(a) finished turn X and the same inflight X from elsewhere emit 1', () {
    final x = {'role': 'user', 'content': prompt, 'id': 480600};
    expect(realUsers(recover([durableAnswer(), x])), 2);
  });

  test('(b) a passive snapshot (bridge=false) is unchanged', () {
    final a = {'role': 'user', 'content': prompt, '_optimistic': true};
    final on = realUsers(recover([pipeline(), a, oldAnswer()]));
    final off = realUsers(recover([pipeline(), a, oldAnswer()], bridge: false));
    expect(on, 1);
    expect(off, 2);
  });

  test('(c) two real prompts in the run are left alone', () {
    final a = {'role': 'user', 'content': prompt, '_optimistic': true};
    final b = {'role': 'user', 'content': prompt, 'id': 480604};
    expect(realUsers(recover([pipeline(), b, a, oldAnswer()])), 3);
  });

  test('(d) a different text is emitted', () {
    final a = {'role': 'user', 'content': 'otra cosa', '_optimistic': true};
    expect(realUsers(recover([pipeline(), a, oldAnswer()])), 2);
  });

  test('(e) a correction is not the opening prompt of the run', () {
    final steer = {'role': 'user', 'content': prompt, '_steer': true};
    final other = {'role': 'user', 'content': 'otra cosa', 'id': 480605};
    expect(realUsers(recover([pipeline(), other, steer, oldAnswer()])), 2);
  });
}
