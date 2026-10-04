import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/room_member_prompts.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../../support/inter_font.dart';
import 'room_fixtures.dart';

/// Room reads that fail on demand, like `groups.state`/`groups.log` on a
/// loaded host: a timeout, a lost socket, or a stale capability generation.
final class _FlakyGateway implements RoomGateway {
  final HostedGroupRoom room;
  final HostedGroupLogPage log;
  final RoomDriverStatus status;
  int reads = 0;
  bool failing = false;
  _FlakyGateway(this.room, this.log, this.status);

  HostedGroupWorkspaceReadback get _rb => HostedGroupWorkspaceReadback(
    room: room,
    log: log,
    capabilityGeneration: 1,
    driverStatus: status,
  );

  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async {
    reads++;
    if (failing) {
      throw const TuiGatewayRpcError(
        'groups.log',
        'Timeout waiting for JSON-RPC response',
        failureKind: TuiGatewayRpcFailureKind.timeout,
      );
    }
    return _rb;
  }

  @override
  Future<HostedGroupWorkspaceReadback> send(
    HostedGroupRoom room, {
    required String text,
    required HostedGroupSendAttempt attempt,
  }) async => _rb;

  @override
  Future<HostedGroupWorkspaceReadback> rename(
    HostedGroupRoom room, {
    required String name,
  }) async => _rb;

  @override
  Future<HostedGroupWorkspaceReadback> stop(HostedGroupRoom room) async => _rb;

  @override
  Future<HostedGroupWorkspaceReadback> disband(HostedGroupRoom room) async =>
      _rb;

  @override
  Future<void> approve(
    HostedGroupRoom room, {
    required RoomApprovalAction action,
    required String choice,
  }) async {}

  @override
  Future<void> retry(HostedGroupRoom room, {required String taskId}) async {}
}

final class _NoTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
}

/// Captures the poller's next tick so a test fires it by hand, at the fake
/// time it chooses.
final class _Ticks {
  void Function()? _next;
  final List<Duration> delays = [];

  Timer call(Duration delay, void Function() callback) {
    delays.add(delay);
    _next = callback;
    return _NoTimer();
  }

  Future<void> fire(WidgetTester tester) async {
    final next = _next;
    expect(next, isNotNull, reason: 'the poller scheduled no tick');
    _next = null;
    next!();
    await tester.pump();
    await tester.pump();
  }
}

final class _Clock {
  DateTime now = DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000);
  void advance(Duration d) => now = now.add(d);
}

const _caps = RoomCapabilities(canSend: true, canAnswerPrompts: true);
const _stale = ValueKey('room-refresh-stale');

final class _Harness {
  final _FlakyGateway gateway;
  final _Ticks ticks;
  final _Clock clock;
  final GlobalKey<RoomScreenState> key;
  _Harness(this.gateway, this.ticks, this.clock, this.key);

  /// One failed poll [after] the previous one.
  Future<void> failTick(WidgetTester tester, Duration after) async {
    gateway.failing = true;
    clock.advance(after);
    await ticks.fire(tester);
  }

  Future<void> okTick(WidgetTester tester, Duration after) async {
    gateway.failing = false;
    clock.advance(after);
    await ticks.fire(tester);
  }
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool working = true,
  RoomMemberPromptSource? prompts,
}) async {
  tester.view.physicalSize = const Size(412 * 3, 915 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final seq = EventSeq();
  final log = buildLog([seq.user('hola equipo')]);
  final room = buildRoom(latestSeq: log.latestSeq);
  final status = driver(
    working: working,
    counts: working ? const {'queued': 1} : const {},
  );
  final gateway = _FlakyGateway(room, log, status);
  final ticks = _Ticks();
  final clock = _Clock();
  final key = GlobalKey<RoomScreenState>();
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('es'),
      theme: AppTheme.hermesRedDark,
      home: RoomScreen(
        key: key,
        room: room,
        log: log,
        driverStatus: status,
        gateway: gateway,
        capabilities: _caps,
        profileFor: (_) => null,
        prefs: MemoryRoomPrefs(),
        memberPrompts: prompts,
        pollTimer: ticks.call,
        clock: () => clock.now,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return _Harness(gateway, ticks, clock, key);
}

void _expectCalm() {
  expect(find.byKey(const ValueKey('room-error')), findsNothing);
  expect(find.text('No se pudo actualizar la sala.'), findsNothing);
  expect(find.byKey(_stale), findsNothing);
}

/// The stale line is text plus a spinner only: no retry or other action.
void _expectNoStaleAction() {
  expect(find.byKey(const ValueKey('room-refresh-retry')), findsNothing);
  expect(
    find.descendant(
      of: find.byKey(_stale),
      matching: find.byWidgetPredicate(
        (w) =>
            w is ButtonStyleButton ||
            w is IconButton ||
            w is InkWell ||
            w is GestureDetector,
      ),
    ),
    findsNothing,
  );
  expect(
    find.descendant(of: find.byKey(_stale), matching: find.text('Reintentar')),
    findsNothing,
  );
}

/// Every element in the screen's composer that takes text stays enabled.
void _expectComposerUsable(WidgetTester tester) {
  final fields = tester.widgetList<TextField>(find.byType(TextField));
  expect(fields, isNotEmpty);
  for (final f in fields) {
    expect(f.enabled ?? true, isTrue);
  }
}

void main() {
  setUpAll(loadInterFont);

  testWidgets('a single failed poll shows nothing', (tester) async {
    final h = await _pump(tester);
    await h.okTick(tester, Duration.zero);
    await h.failTick(tester, const Duration(seconds: 3));
    expect(h.gateway.reads, 2);
    _expectCalm();
    await h.okTick(tester, const Duration(seconds: 3));
    _expectCalm();
  });

  testWidgets('several quick failures inside the tolerance show nothing', (
    tester,
  ) async {
    final h = await _pump(tester);
    await h.okTick(tester, Duration.zero);
    // Working cadence (3 s): 14 failures span 42 s, still inside 45 s.
    for (var i = 0; i < 14; i++) {
      await h.failTick(tester, const Duration(seconds: 3));
    }
    expect(h.gateway.reads, 15);
    _expectCalm();
  });

  testWidgets('a failed idle tick followed by its retry shows nothing', (
    tester,
  ) async {
    // Idle cadence tops out at 15 s: one lost tick plus the retry that
    // succeeds lands about 30 s after the last good read.
    final h = await _pump(tester, working: false);
    await h.okTick(tester, Duration.zero);
    await h.failTick(tester, const Duration(seconds: 15));
    await h.okTick(tester, const Duration(seconds: 15));
    _expectCalm();
  });

  testWidgets('stale past the tolerance with every poll failing: calm '
      'reconnecting status, composer still usable', (tester) async {
    final h = await _pump(tester);
    await h.okTick(tester, Duration.zero);
    await h.failTick(tester, const Duration(seconds: 30));
    await h.failTick(tester, const Duration(seconds: 14));
    _expectCalm(); // 44 s since the last good read
    await h.failTick(tester, const Duration(seconds: 1));
    expect(find.byKey(_stale), findsOneWidget);
    expect(
      find.text('Reconectando… la sala puede no estar al día.'),
      findsOneWidget,
    );
    _expectNoStaleAction();
    expect(find.byKey(const ValueKey('room-error')), findsNothing);
    expect(find.textContaining('Timeout waiting'), findsNothing);
    expect(find.text('No se pudo actualizar la sala.'), findsNothing);
    _expectComposerUsable(tester);
  });

  testWidgets('the next successful poll clears the status by itself', (
    tester,
  ) async {
    final h = await _pump(tester);
    await h.okTick(tester, Duration.zero);
    await h.failTick(tester, const Duration(seconds: 50));
    expect(find.byKey(_stale), findsOneWidget);
    // No user action: only the poller reads the room again.
    await h.okTick(tester, const Duration(seconds: 3));
    expect(find.byKey(_stale), findsNothing);
    // And the tolerance restarts from that read.
    await h.failTick(tester, const Duration(seconds: 3));
    _expectCalm();
  });

  testWidgets('a quiet successful poll (nothing changed) also clears it', (
    tester,
  ) async {
    final h = await _pump(tester, working: false);
    await h.okTick(tester, Duration.zero);
    await h.failTick(tester, const Duration(seconds: 60));
    expect(find.byKey(_stale), findsOneWidget);
    await h.okTick(tester, const Duration(seconds: 15));
    expect(find.byKey(_stale), findsNothing);
  });

  testWidgets('the stale line offers no retry: polls keep failing, then the '
      'next successful poll clears it', (tester) async {
    final h = await _pump(tester);
    await h.okTick(tester, Duration.zero);
    await h.failTick(tester, const Duration(seconds: 50));
    expect(find.byKey(_stale), findsOneWidget);
    _expectNoStaleAction();
    // Still failing: the line stays, still without any button.
    await h.failTick(tester, const Duration(seconds: 3));
    await h.failTick(tester, const Duration(seconds: 3));
    expect(find.byKey(_stale), findsOneWidget);
    _expectNoStaleAction();
    // Recovery is automatic: the poller's next good read clears it.
    final before = h.gateway.reads;
    await h.okTick(tester, const Duration(seconds: 3));
    expect(h.gateway.reads, before + 1);
    expect(find.byKey(_stale), findsNothing);
    _expectCalm();
  });

  testWidgets('a single failed manual refresh shows nothing', (tester) async {
    final h = await _pump(tester);
    await h.okTick(tester, Duration.zero);
    h.gateway.failing = true;
    h.clock.advance(const Duration(seconds: 2));
    await h.key.currentState!.refresh();
    await tester.pump();
    _expectCalm();
  });

  testWidgets('returning from background does not count the paused time', (
    tester,
  ) async {
    final h = await _pump(tester);
    await h.okTick(tester, Duration.zero);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    h.clock.advance(const Duration(minutes: 10));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    // The resume tick fails once (socket still waking up): no status.
    await h.failTick(tester, Duration.zero);
    _expectCalm();
  });

  testWidgets('a failed poll logs the failing call and kind, no content', (
    tester,
  ) async {
    final lines = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    try {
      final h = await _pump(tester);
      await h.okTick(tester, Duration.zero);
      await h.failTick(tester, const Duration(seconds: 3));
    } finally {
      // Restored inside the body: the binding checks it before teardown.
      debugPrint = original;
    }
    final failures = [
      for (final l in lines)
        if (l.startsWith('room refresh failed')) l,
    ];
    expect(failures, hasLength(1));
    expect(failures.single, contains('(poll)'));
    expect(failures.single, contains('TuiGatewayRpcError'));
    expect(failures.single, contains('method=groups.log'));
    expect(failures.single, contains('kind=timeout'));
    expect(failures.single, isNot(contains('Timeout waiting')));
  });

  test('failure kinds never carry remote text', () {
    expect(
      roomRefreshFailureKind(StateError('private remote failure')),
      'StateError',
    );
    expect(
      roomRefreshFailureKind(const FormatException('private payload')),
      'FormatException',
    );
    expect(
      roomRefreshFailureKind(StateError('hosted group capability unavailable')),
      'StateError hosted group capability unavailable',
    );
    expect(
      roomRefreshFailureKind(
        const FormatException('room refresh authority changed'),
      ),
      'FormatException room refresh authority changed',
    );
    expect(
      roomRefreshFailureKind(
        const TuiGatewayRpcError(
          'groups.state',
          'private remote failure',
          failureKind: TuiGatewayRpcFailureKind.connectionLost,
        ),
      ),
      'TuiGatewayRpcError method=groups.state code=null '
      'kind=connectionLost reason=null',
    );
  });

  test('a remote RPC reason is logged only when it is a known code', () {
    String kind(Object reason) => roomRefreshFailureKind(
      TuiGatewayRpcError(
        'groups.state',
        'private remote failure',
        code: 4118,
        data: {'reason': reason},
      ),
    );
    expect(
      kind('private remote failure'),
      'TuiGatewayRpcError method=groups.state code=4118 '
      'kind=null reason=other',
    );
    expect(kind('room_history_expired\nleak'), endsWith('reason=other'));
    expect(kind('ROOM_HISTORY_EXPIRED'), endsWith('reason=other'));
    expect(
      kind('room_history_expired'),
      endsWith('reason=room_history_expired'),
    );
    expect(kind('authority_conflict'), endsWith('reason=authority_conflict'));
    expect(
      kind('  authority_conflict '),
      endsWith('reason=authority_conflict'),
    );
    expect(kind(''), endsWith('reason=null'));
  });

  testWidgets('a failing member probe never shows a room refresh error', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      prompts: GatewayRoomMemberPrompts(
        (method, params) async =>
            throw const TuiGatewayRpcError('session.active_list', 'boom'),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await h.okTick(tester, const Duration(seconds: 3));
    }
    h.clock.advance(const Duration(minutes: 5));
    await h.okTick(tester, const Duration(seconds: 3));
    _expectCalm();
  });
}
