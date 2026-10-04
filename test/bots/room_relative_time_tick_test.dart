import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/bots/ui/room/room_widgets.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'room/room_fixtures.dart';

final class _NoGateway implements RoomGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
}

void main() {
  test('roomAgoNextChange waits for the next label', () {
    expect(roomAgoNextChange(Duration.zero), const Duration(minutes: 1));
    expect(
      roomAgoNextChange(const Duration(minutes: 8, seconds: 5)),
      const Duration(seconds: 55),
    );
    expect(
      roomAgoNextChange(const Duration(hours: 1, minutes: 20)),
      const Duration(minutes: 40),
    );
    expect(
      roomAgoNextChange(const Duration(days: 2, hours: 23)),
      const Duration(hours: 1),
    );
    expect(
      roomAgoNextChange(const Duration(seconds: -30)),
      const Duration(seconds: 90),
    );
  });

  // The last fixture event lands at 1790000140 s.
  const lastEventSeconds = 1790000140;
  late DateTime now;

  Future<void> pumpIdleRoom(WidgetTester tester) async {
    final seq = EventSeq();
    final u = seq.user('@builder go');
    final disc = u['event_id'] as String;
    final started = seq.started('m-builder', disc);
    final reply = seq.member('m-builder', 'builder', 'done', disc);
    final settled = seq.settled(
      'm-builder',
      disc,
      messageId: reply['event_id'] as String,
    );
    final log = buildLog([u, started, reply, settled]);
    // Eight minutes and five seconds after the round finished.
    now = DateTime.fromMillisecondsSinceEpoch(
      (lastEventSeconds + 8 * 60 + 5) * 1000,
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: RoomScreen(
          room: buildRoom(latestSeq: log.latestSeq),
          log: log,
          gateway: _NoGateway(),
          capabilities: const RoomCapabilities(canSend: true),
          profileFor: (_) => null,
          prefs: MemoryRoomPrefs(),
          pollTimer: (_, _) => _FakeTimer(),
          clock: () => now,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String line(WidgetTester tester) => tester
      .widget<Text>(
        find.byKey(const ValueKey('room-strip-summary'), skipOffstage: false),
      )
      .data!;

  bool armed(WidgetTester tester) =>
      (tester.state(find.byType(RoomScreen, skipOffstage: false)) as dynamic)
              .ageTickArmed
          as bool;

  /// Advances the screen clock and the test's fake time together.
  Future<void> advance(WidgetTester tester, Duration by) async {
    now = now.add(by);
    await tester.pump(by);
  }

  testWidgets('the finished-round age ticks while the room is visible', (
    tester,
  ) async {
    await pumpIdleRoom(tester);
    expect(line(tester), 'Round 1 finished · 8 min ago');
    // Not before the minute turns.
    await advance(tester, const Duration(seconds: 50));
    expect(line(tester), 'Round 1 finished · 8 min ago');
    await advance(tester, const Duration(seconds: 10));
    expect(line(tester), 'Round 1 finished · 9 min ago');
    await advance(tester, const Duration(minutes: 2));
    expect(line(tester), 'Round 1 finished · 11 min ago');
  });

  testWidgets('past an hour the label changes once per hour', (tester) async {
    await pumpIdleRoom(tester);
    await advance(tester, const Duration(minutes: 52));
    expect(line(tester), 'Round 1 finished · 1 h ago');
    for (var i = 0; i < 58; i++) {
      await advance(tester, const Duration(minutes: 1));
      expect(line(tester), 'Round 1 finished · 1 h ago');
    }
    await advance(tester, const Duration(minutes: 2));
    expect(line(tester), 'Round 1 finished · 2 h ago');
  });

  testWidgets('no tick in the background; the age is fresh on return', (
    tester,
  ) async {
    await pumpIdleRoom(tester);
    expect(armed(tester), isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(armed(tester), isFalse);
    await advance(tester, const Duration(minutes: 5));
    expect(line(tester), 'Round 1 finished · 8 min ago');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(line(tester), 'Round 1 finished · 13 min ago');
    expect(armed(tester), isTrue);
    await advance(tester, const Duration(minutes: 1));
    expect(line(tester), 'Round 1 finished · 14 min ago');
  });

  testWidgets('no tick while another route covers the room', (tester) async {
    await pumpIdleRoom(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const Text('cover')),
      ),
    );
    await tester.pumpAndSettle();
    expect(armed(tester), isFalse);
    final covered = line(tester);
    // A rebuild under the cover (a late read landing) arms nothing.
    (tester.state(find.byType(RoomScreen, skipOffstage: false)) as dynamic)
        .setState(() {});
    await tester.pump();
    expect(armed(tester), isFalse);
    await advance(tester, const Duration(minutes: 5));
    expect(line(tester), covered);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(line(tester), endsWith('min ago'));
    expect(line(tester), isNot(covered));
    expect(armed(tester), isTrue);
  });
}
