import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/foreground_conversation_reader.dart';

void main() {
  testWidgets('no solapa y rearma solo despues de completar', (tester) async {
    final firstRead = Completer<bool>();
    var calls = 0;
    final reader = ForegroundConversationReader(
      successInterval: const Duration(seconds: 3),
      failureIntervals: const [Duration(seconds: 5), Duration(seconds: 15)],
      canRead: () => true,
      read: () {
        calls += 1;
        return firstRead.future;
      },
    )..setVisible(true);

    await tester.pump(const Duration(seconds: 3));
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 30));
    expect(calls, 1);

    firstRead.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);

    reader.dispose();
  });

  testWidgets('al ocultarse una lectura pendiente no rearma', (tester) async {
    final pending = Completer<bool>();
    var calls = 0;
    final reader = ForegroundConversationReader(
      successInterval: const Duration(seconds: 3),
      failureIntervals: const [Duration(seconds: 5)],
      canRead: () => true,
      read: () {
        calls += 1;
        return pending.future;
      },
    )..setVisible(true);

    await tester.pump(const Duration(seconds: 3));
    expect(calls, 1);
    reader.setVisible(false);
    pending.complete(true);
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(calls, 1);

    reader.dispose();
  });

  testWidgets('aplica backoff tras fallos y lo reinicia tras exito', (
    tester,
  ) async {
    final outcomes = <bool>[false, false, true, true];
    var calls = 0;
    final reader = ForegroundConversationReader(
      successInterval: const Duration(seconds: 3),
      failureIntervals: const [Duration(seconds: 5), Duration(seconds: 15)],
      canRead: () => true,
      read: () async {
        final outcome = outcomes[calls];
        calls += 1;
        return outcome;
      },
    )..setVisible(true);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 4));
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 14));
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(calls, 3);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(calls, 4);

    reader.dispose();
  });
}
