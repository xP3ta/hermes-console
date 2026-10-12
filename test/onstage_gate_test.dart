import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/onstage_gate.dart';

void main() {
  testWidgets('forwards while onstage, holds while offstage and catches up '
      'once when visible again', (tester) async {
    final source = ValueNotifier<int>(0);
    addTearDown(source.dispose);
    final gate = OnstageGate();
    addTearDown(gate.dispose);
    var notifications = 0;
    gate.addListener(() => notifications++);

    Widget host({required bool enabled}) => TickerMode(
      enabled: enabled,
      child: Builder(
        builder: (context) {
          gate.bind(context, source);
          return const SizedBox();
        },
      ),
    );

    await tester.pumpWidget(host(enabled: true));
    source.value++;
    expect(notifications, 1);

    await tester.pumpWidget(host(enabled: false));
    expect(gate.onstage, isFalse);
    for (var i = 0; i < 10; i++) {
      source.value++;
    }
    expect(notifications, 1, reason: 'nothing reaches a hidden screen');

    await tester.pumpWidget(host(enabled: true));
    expect(notifications, 2, reason: 'one catch-up when visible again');

    await tester.pumpWidget(host(enabled: false));
    await tester.pumpWidget(host(enabled: true));
    expect(notifications, 2, reason: 'no catch-up without a held change');
  });

  testWidgets('rebinding to a new source stops listening to the old one', (
    tester,
  ) async {
    final first = ValueNotifier<int>(0);
    final second = ValueNotifier<int>(0);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final gate = OnstageGate();
    addTearDown(gate.dispose);
    var notifications = 0;
    gate.addListener(() => notifications++);
    var source = first;

    Widget host() => Builder(
      builder: (context) {
        gate.bind(context, source);
        return const SizedBox();
      },
    );

    await tester.pumpWidget(host());
    source = second;
    await tester.pumpWidget(KeyedSubtree(key: UniqueKey(), child: host()));
    first.value++;
    expect(notifications, 0);
    second.value++;
    expect(notifications, 1);
  });
}
