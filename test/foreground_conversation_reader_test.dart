import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/foreground_conversation_reader.dart';

class _FakeGateway {
  final Queue<Future<bool> Function()> outcomes = Queue();
  int reads = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  Future<bool> read() async {
    reads += 1;
    inFlight += 1;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      return await (outcomes.isEmpty
          ? Future<bool>.value(true)
          : outcomes.removeFirst()());
    } finally {
      inFlight -= 1;
    }
  }
}

ForegroundConversationReader _reader({
  required _FakeGateway gateway,
  bool changeEventsAvailable = true,
  String durableChatId = 'chat-a',
  bool Function()? externallyOwnedTurnActive,
  bool Function()? recoveryConverging,
}) => ForegroundConversationReader(
  successInterval: const Duration(seconds: 3),
  eventBackstopInterval: const Duration(seconds: 30),
  activeInterval: const Duration(seconds: 3),
  failureIntervals: const [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ],
  changeEventsAvailable: changeEventsAvailable,
  durableChatId: () => durableChatId,
  externallyOwnedTurnActive: externallyOwnedTurnActive ?? () => false,
  recoveryConverging: recoveryConverging ?? () => false,
  canRead: () => true,
  read: gateway.read,
);

Future<void> _pumpImmediate(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 1));

void main() {
  testWidgets(
    'event-capable stable route reads immediately then at 30 seconds',
    (tester) async {
      final gateway = _FakeGateway();
      final reader = _reader(gateway: gateway)
        ..setVisible(true, immediate: true);

      await _pumpImmediate(tester);
      expect(gateway.reads, 1);
      await tester.pump(const Duration(seconds: 29));
      expect(gateway.reads, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(gateway.reads, 2);

      reader.dispose();
    },
  );

  testWidgets('matching sessions.changed coalesces one immediate read', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    final reader = _reader(gateway: gateway)..setVisible(true);

    reader.notifySessionsChanged('chat-b');
    await _pumpImmediate(tester);
    expect(gateway.reads, 0);

    reader
      ..notifySessionsChanged('chat-a')
      ..notifySessionsChanged('chat-a')
      ..notifySessionsChanged('chat-a');
    await _pumpImmediate(tester);
    expect(gateway.reads, 1);

    reader.dispose();
  });

  testWidgets(
    'externally-owned active turn uses 3 seconds until two snapshots agree',
    (tester) async {
      final gateway = _FakeGateway();
      var externallyOwned = true;
      final reader = _reader(
        gateway: gateway,
        externallyOwnedTurnActive: () => externallyOwned,
      )..setVisible(true, immediate: true);

      await _pumpImmediate(tester);
      expect(gateway.reads, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(gateway.reads, 2);
      await tester.pump(const Duration(seconds: 3));
      expect(gateway.reads, 2);
      externallyOwned = false;
      await tester.pump(const Duration(seconds: 27));
      expect(gateway.reads, 3);

      reader.dispose();
    },
  );

  testWidgets('terminal event returns an active route to the slow backstop', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    final reader = _reader(
      gateway: gateway,
      externallyOwnedTurnActive: () => true,
    )..setVisible(true, immediate: true);

    await _pumpImmediate(tester);
    reader.notifyRelevantEvent(terminal: true);
    await _pumpImmediate(tester);
    expect(gateway.reads, 2);
    await tester.pump(const Duration(seconds: 29));
    expect(gateway.reads, 2);
    await tester.pump(const Duration(seconds: 1));
    expect(gateway.reads, 3);

    reader.dispose();
  });

  testWidgets('capability transition demotes the legacy timer to 30 seconds', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    final reader = _reader(gateway: gateway, changeEventsAvailable: false)
      ..setVisible(true, immediate: true);

    await _pumpImmediate(tester);
    reader.setChangeEventsAvailable(true, immediate: false);
    await tester.pump(const Duration(seconds: 29));
    expect(gateway.reads, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(gateway.reads, 2);

    reader.dispose();
  });

  testWidgets('hidden and background route never reads', (tester) async {
    final gateway = _FakeGateway();
    final reader = _reader(gateway: gateway);

    reader
      ..setVisible(false, immediate: true)
      ..notifyRelevantEvent(recoveryConverging: true)
      ..notifySessionsChanged('chat-a');
    await tester.pump(const Duration(minutes: 2));
    expect(gateway.reads, 0);

    reader.dispose();
  });

  testWidgets('legacy gateway retains the 3 second cadence', (tester) async {
    final gateway = _FakeGateway();
    final reader = _reader(gateway: gateway, changeEventsAvailable: false)
      ..setVisible(true, immediate: true);

    await _pumpImmediate(tester);
    expect(gateway.reads, 1);
    for (var expected = 2; expected <= 4; expected++) {
      await tester.pump(const Duration(seconds: 3));
      expect(gateway.reads, expected);
    }

    reader.dispose();
  });

  testWidgets('failures use 5 15 30 60 seconds and cap at 60', (tester) async {
    final gateway = _FakeGateway();
    for (var i = 0; i < 6; i++) {
      gateway.outcomes.add(() async => false);
    }
    final reader = _reader(gateway: gateway)..setVisible(true, immediate: true);

    await _pumpImmediate(tester);
    expect(gateway.reads, 1);
    for (final delay in const [5, 15, 30, 60, 60]) {
      await tester.pump(Duration(seconds: delay - 1));
      expect(gateway.reads, lessThan(6));
      final before = gateway.reads;
      await tester.pump(const Duration(seconds: 1));
      expect(gateway.reads, before + 1);
    }

    reader.dispose();
  });

  testWidgets('relevant event resets failure delay and triggers one read', (
    tester,
  ) async {
    final gateway = _FakeGateway()
      ..outcomes.addAll([
        () async => false,
        () async => false,
        () async => false,
      ]);
    final reader = _reader(gateway: gateway)..setVisible(true, immediate: true);

    await _pumpImmediate(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(gateway.reads, 2);
    reader
      ..notifyRelevantEvent()
      ..notifyRelevantEvent();
    await _pumpImmediate(tester);
    expect(gateway.reads, 3);
    await tester.pump(const Duration(seconds: 4));
    expect(gateway.reads, 3);
    await tester.pump(const Duration(seconds: 1));
    expect(gateway.reads, 4);

    reader.dispose();
  });

  testWidgets('reads never overlap and in-flight events coalesce', (
    tester,
  ) async {
    final firstRead = Completer<bool>();
    final gateway = _FakeGateway()
      ..outcomes.add(() => firstRead.future)
      ..outcomes.add(() async => true);
    final reader = _reader(gateway: gateway)..setVisible(true, immediate: true);

    await _pumpImmediate(tester);
    reader
      ..notifyRelevantEvent()
      ..notifySessionsChanged('chat-a')
      ..notifyRelevantEvent();
    await tester.pump(const Duration(minutes: 1));
    expect(gateway.reads, 1);
    expect(gateway.maxInFlight, 1);

    firstRead.complete(true);
    await _pumpImmediate(tester);
    expect(gateway.reads, 2);
    expect(gateway.maxInFlight, 1);

    reader.dispose();
  });

  testWidgets('generation invalidation cancels stale read results', (
    tester,
  ) async {
    final staleRead = Completer<bool>();
    final gateway = _FakeGateway()
      ..outcomes.add(() => staleRead.future)
      ..outcomes.add(() async => true);
    final reader = _reader(gateway: gateway)..setVisible(true, immediate: true);

    await _pumpImmediate(tester);
    expect(gateway.reads, 1);
    reader.setVisible(false);
    staleRead.complete(true);
    await tester.pump(const Duration(minutes: 1));
    expect(gateway.reads, 1);

    reader.setVisible(true, immediate: true);
    await _pumpImmediate(tester);
    expect(gateway.reads, 2);

    reader.dispose();
  });
}
