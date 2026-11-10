// CHAT-FLUIDO 2: the live turn's mark beats like Hermes Desktop's
// StatusPulse (components/ui/status-pulse.tsx): 400 ms, opacity 1 → 0.5 → 1,
// every 5 s, every mark on one clock, still with reduced motion and while
// the app is in the background.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';

Widget _host(List<Widget> marks, {bool reduceMotion = false}) => MaterialApp(
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: Scaffold(body: Column(children: marks)),
    ),
  ),
);

double _opacity(WidgetTester tester, [int index = 0]) => tester
    .widgetList<FadeTransition>(
      find.byKey(const ValueKey('turn-status-pulse')),
    )
    .elementAt(index)
    .opacity
    .value;

const _a = TurnStatusPulse(key: ValueKey('a'), color: Colors.orange);
const _b = TurnStatusPulse(key: ValueKey('b'), color: Colors.orange);

void main() {
  final clock = TurnPulseClock.instance;

  testWidgets('the first mark beats at once, then every 5 s', (tester) async {
    await tester.pumpWidget(_host(const [_a]));
    expect(clock.marks, 1);
    expect(clock.running, isTrue);
    // The beat's ticker starts on the next frame.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_opacity(tester), closeTo(0.5, 0.05));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_opacity(tester), 1);
    // Nothing between beats.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pump(const Duration(milliseconds: 2550));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_opacity(tester), closeTo(0.5, 0.05));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('a mark that joins later beats with the others', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const [_a]));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(_host(const [_a, _b]));
    await tester.pump(const Duration(milliseconds: 200));
    // The newcomer waits for the shared beat.
    expect(_opacity(tester, 1), 1);
    await tester.pump(const Duration(milliseconds: 3800));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_opacity(tester, 0), closeTo(0.5, 0.05));
    expect(_opacity(tester, 1), closeTo(0.5, 0.05));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('reduced motion: still, and off the clock', (tester) async {
    await tester.pumpWidget(_host(const [_a], reduceMotion: true));
    expect(clock.marks, 0);
    expect(clock.running, isFalse);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_opacity(tester), 1);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('the clock stops with the last mark', (tester) async {
    await tester.pumpWidget(_host(const [_a]));
    expect(clock.running, isTrue);
    await tester.pumpWidget(_host(const []));
    expect(clock.marks, 0);
    expect(clock.running, isFalse);
  });

  testWidgets('no beat in the background; it resumes on return', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const [_a]));
    await tester.pump(const Duration(milliseconds: 450));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(clock.running, isFalse);
    await tester.pump(const Duration(seconds: 6));
    expect(tester.hasRunningAnimations, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(clock.running, isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_opacity(tester), closeTo(0.5, 0.05));
    await tester.pump(const Duration(milliseconds: 300));
  });
}
