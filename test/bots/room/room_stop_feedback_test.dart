import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'room_fixtures.dart';

/// QA: «Parar todo» landed on the server but the room said nothing, so the
/// owner could not tell it worked and tapped again. A stop now says so in the
/// room's own header line (no notice covering the header, per the quiet
/// feedback rule), and a failed stop still raises the error notice.
final class _FakeTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
}

final class _Gateway implements RoomGateway {
  _Gateway({required this.room, required this.log, required this.status});
  final HostedGroupRoom room;
  HostedGroupLogPage log;
  RoomDriverStatus status;
  bool failStop = false;
  int stops = 0;

  HostedGroupWorkspaceReadback get _readback => HostedGroupWorkspaceReadback(
    room: room,
    log: log,
    capabilityGeneration: 1,
    driverStatus: status,
  );

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async =>
      _readback;
  @override
  Future<HostedGroupWorkspaceReadback> send(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
  }) async => _readback;
  @override
  Future<HostedGroupWorkspaceReadback> rename(
    HostedGroupRoom room, {
    required String name,
  }) async => _readback;
  @override
  Future<HostedGroupWorkspaceReadback> stop(HostedGroupRoom room) async {
    stops++;
    if (failStop) throw StateError('synthetic stop failure');
    status = driver(running: true, working: false);
    return _readback;
  }

  @override
  Future<HostedGroupWorkspaceReadback> disband(HostedGroupRoom room) async =>
      _readback;
  @override
  Future<void> approve(
    HostedGroupRoom room, {
    required RoomApprovalAction action,
    required String choice,
  }) async {}
  @override
  Future<void> retry(HostedGroupRoom room, {required String taskId}) async {}
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late DateTime now;
  late EventSeq seq;
  late List<Map<String, dynamic>> raw;

  Future<(_Gateway, Strings)> pumpRoom(WidgetTester tester) async {
    now = DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    seq = EventSeq();
    raw = [seq.user('ship it')];
    final log = buildLog(raw);
    final room = buildRoom(latestSeq: log.latestSeq);
    final status = driver(working: true, counts: {'running': 1});
    final gateway = _Gateway(room: room, log: log, status: status);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        locale: const Locale('en'),
        theme: AppTheme.hermesRedDark,
        home: RoomScreen(
          room: room,
          log: log,
          driverStatus: status,
          gateway: gateway,
          capabilities: const RoomCapabilities(canSend: true, canStop: true),
          profileFor: (_) => null,
          prefs: MemoryRoomPrefs(),
          pollTimer: (_, _) => _FakeTimer(),
          clock: () => now,
        ),
      ),
    );
    await _frames(tester);
    return (gateway, Strings.of(tester.element(find.byType(RoomScreen))));
  }

  Future<void> stopAll(WidgetTester tester, Strings s) async {
    await tester.tap(find.byKey(const ValueKey('room-header')));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('room-stop-all')));
    await _frames(tester);
    await tester.tap(find.text(s.roomStopConfirm));
    await _frames(tester);
  }

  // Notices float in the root overlay as HermesNoticeCard, not SnackBar.
  Finder noticeText(String text) => find.descendant(
    of: find.byType(HermesNoticeCard),
    matching: find.text(text),
  );

  Finder headerSays(String text) => find.textContaining(text);

  testWidgets('a stop that landed says so in the header, not in a notice', (
    tester,
  ) async {
    final (gateway, s) = await pumpRoom(tester);
    expect(headerSays(s.roomActivityStopLine), findsNothing);
    await stopAll(tester, s);
    expect(gateway.stops, 1);
    expect(headerSays(s.roomActivityStopLine), findsOneWidget);
    expect(find.byType(HermesNoticeCard), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new work after the stop clears the stopped line', (
    tester,
  ) async {
    final (gateway, s) = await pumpRoom(tester);
    await stopAll(tester, s);
    expect(headerSays(s.roomActivityStopLine), findsOneWidget);
    gateway.status = driver(working: true, counts: {'running': 1});
    await tester.state<RoomScreenState>(find.byType(RoomScreen)).refresh();
    await _frames(tester);
    expect(headerSays(s.roomActivityStopLine), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  Future<void> refresh(WidgetTester tester) async {
    await tester.state<RoomScreenState>(find.byType(RoomScreen)).refresh();
    await _frames(tester);
  }

  testWidgets('the stopped line is neutral and short-lived', (tester) async {
    final (_, s) = await pumpRoom(tester);
    await stopAll(tester, s);
    expect(roomIslandSays(tester), contains(s.roomActivityStopLine));
    final island = tester.widget<ChatIsland>(
      find.byKey(const ValueKey('room-header')),
    );
    expect(island.status, IslandStatus.idle, reason: 'not a call to act');
    expect(island.events.single.tone, IslandTone.info);
    // Nothing else happens in the room: the line ends on its own.
    now = now.add(const Duration(minutes: 2));
    await tester.pump(const Duration(minutes: 2));
    await _frames(tester);
    expect(headerSays(s.roomActivityStopLine), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a new message from another client ends the stopped line', (
    tester,
  ) async {
    final (gateway, s) = await pumpRoom(tester);
    await stopAll(tester, s);
    expect(headerSays(s.roomActivityStopLine), findsOneWidget);
    // A short round ran elsewhere between two polls: the driver is idle
    // again, but the log has a new reply.
    raw = [...raw, seq.member('m-builder', 'builder', 'done', 'other')];
    gateway.log = buildLog(raw);
    await refresh(tester);
    expect(headerSays(s.roomActivityStopLine), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed stop still says it failed, never stopped', (
    tester,
  ) async {
    final (gateway, s) = await pumpRoom(tester);
    gateway.failStop = true;
    await stopAll(tester, s);
    expect(gateway.stops, 1);
    expect(noticeText(s.roomActionFailed), findsOneWidget);
    expect(headerSays(s.roomActivityStopLine), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
