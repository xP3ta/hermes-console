import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_sheets.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/bots/ui/room/room_widgets.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'room_fixtures.dart';

final class _FakeTimer implements Timer {
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

final class _Gateway implements RoomGateway {
  final HostedGroupRoom room;
  final HostedGroupLogPage log;
  final RoomDriverStatus? status;
  _Gateway({required this.room, required this.log, this.status});

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
  Future<HostedGroupWorkspaceReadback> stop(HostedGroupRoom room) async =>
      _readback;
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

final class _Live implements RoomMemberLiveSource {
  int reads = 0;
  final Map<String, RoomMemberLive> value;
  _Live(this.value);
  @override
  Future<Map<String, RoomMemberLive>> read(HostedGroupRoom room) async {
    reads++;
    return value;
  }
}

/// The round sheet opened from the room header ("Actividad"): per member it
/// says exactly what the server knows, never more. Shapes follow the real
/// hosted driver: no `turn.started` is ever published, one task runs at a
/// time per room, terminal events carry `created_at`, `passed`,
/// `message_event_id` and a `reason_code`.
final _now = DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000);

List<HostedGroupEvent> _events(List<Map<String, dynamic>> raw) =>
    buildLog(raw).events;

List<HostedGroupMember> get _members => buildRoom().members;

Map<String, dynamic> _failedWith(
  EventSeq seq,
  String member,
  String discussion,
  String reason,
) {
  final e = seq.failed(member, discussion);
  (e['payload'] as Map<String, dynamic>)['reason_code'] = reason;
  return e;
}

Widget _host(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: locale,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<Strings> _pumpDetail(
  WidgetTester tester,
  RoomRoundModel round, {
  List<Widget> approvals = const [],
  void Function(String eventId)? onOpenReply,
  VoidCallback? onStopAll,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _host(
      RoomRoundDetail(
        round: round,
        now: _now,
        profileFor: (_) => null,
        avatarCache: null,
        approvals: approvals,
        onOpenReply: onOpenReply,
        onStopAll: onStopAll,
        onOpenMembers: () {},
      ),
      locale: locale,
    ),
  );
  await _frames(tester);
  return Strings.of(tester.element(find.byType(RoomRoundDetail)));
}

String _rowText(WidgetTester tester, String member) {
  final text = tester.widget<Text>(
    find.byKey(ValueKey('room-round-status-$member')),
  );
  return text.data ?? text.textSpan!.toPlainText();
}

/// Real-server round 1: builder replied, review runs now, lead and radar
/// wait (no `turn.started` anywhere).
({List<HostedGroupEvent> events, String disc}) _liveRound() {
  final seq = EventSeq();
  final u = seq.user('ship it'); // t=110, everyone (no mention)
  final disc = u['event_id'] as String;
  final reply = seq.member('m-builder', 'builder', 'done', disc); // t=120
  final settled = seq.settled(
    'm-builder',
    disc,
    messageId: reply['event_id'] as String,
  ); // t=130
  return (events: _events([u, reply, settled]), disc: disc);
}

void main() {
  // QA 9494 P2: the room menu's «Actividad» log showed raw profile ids
  // («console-radar pasó»), no faces and the server's reason codes. It now
  // names members as the round sheet does, with their original faces and
  // localized reasons.
  group('QA 9494: room menu Activity log', () {
    AgentProfile? profiles(HostedGroupMember m) => switch (m.memberId) {
      'm-radar' => const AgentProfile(
        name: 'radar',
        botModeUiMeta: {'title': 'Radar'},
      ),
      'm-builder' => const AgentProfile(
        name: 'builder',
        botModeUiMeta: {'title': 'Forja'},
      ),
      _ => null,
    };

    testWidgets('display names, faces and localized reasons', (tester) async {
      final seq = EventSeq();
      final u = seq.user('go');
      final disc = u['event_id'] as String;
      final events = _events([
        u,
        seq.settled('m-radar', disc, passed: true),
        _failedWith(seq, 'm-builder', disc, 'provider_rate_limit'),
      ]);
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showRoomActivitySheet(
                context,
                events: events,
                members: _members,
                profileFor: profiles,
                avatarCache: null,
              ),
              child: const Text('open'),
            ),
          ),
          locale: const Locale('es'),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final sheet = find.byKey(const ValueKey('room-activity-sheet'));
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.text('Radar pasó')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('Forja falló')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.textContaining('console-')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.textContaining('provider_rate_limit'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.text(Strings.of(
            tester.element(sheet),
          ).rat1215ReasonRate),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.byType(RoomMemberFace)),
        findsNWidgets(2),
      );
    });
  });

  group('deriveRoomRound on the real server shape', () {
    test('the running task is the first recipient without a terminal; the '
        'rest wait with their position, shown once', () {
      final live = _liveRound();
      final round = deriveRoomRound(
        events: live.events,
        members: _members,
        driverStatus: driver(working: true, counts: {'running': 1}),
        now: _now,
      )!;
      final byId = {for (final r in round.rows) r.member.memberId: r};
      expect(byId['m-builder']!.state, RoomTurnState.replied);
      expect(byId['m-review']!.state, RoomTurnState.working);
      // Working since the previous terminal (t=130), not since the message.
      expect(
        byId['m-review']!.since,
        DateTime.fromMillisecondsSinceEpoch(1790000130 * 1000),
      );
      expect(byId['m-lead']!.state, RoomTurnState.queued);
      expect(byId['m-lead']!.queuePosition, 1);
      expect(byId['m-radar']!.queuePosition, 2);
      expect(byId['m-review']!.queuePosition, isNull);
    });

    test('a reply carries its duration and the transcript event to jump to; '
        'a pass carries neither', () {
      final seq = EventSeq();
      final u = seq.user('ship it'); // 110
      final disc = u['event_id'] as String;
      final reply = seq.member('m-builder', 'builder', 'done', disc); // 120
      final events = _events([
        u,
        reply,
        seq.settled(
          'm-builder',
          disc,
          messageId: reply['event_id'] as String,
        ), // 130
        // A pass never links to a message, even if a payload carried one.
        seq.settled(
          'm-review',
          disc,
          passed: true,
          messageId: 'dmessage:stray',
        ), // 140
      ]);
      final round = deriveRoomRound(
        events: events,
        members: _members,
        driverStatus: driver(working: true, counts: {'running': 1}),
        now: _now,
      )!;
      final byId = {for (final r in round.rows) r.member.memberId: r};
      expect(byId['m-builder']!.took, const Duration(seconds: 20));
      expect(byId['m-builder']!.replyEventId, reply['event_id']);
      expect(byId['m-review']!.replyEventId, isNull);
      expect(byId['m-review']!.took, const Duration(seconds: 10));
      expect(round.total, 4);
      expect(round.responded, 2);
    });

    test('without driver evidence nothing is invented: no working member, '
        'no queue positions', () {
      final live = _liveRound();
      final round = deriveRoomRound(
        events: live.events,
        members: _members,
        now: _now,
      )!;
      expect(
        round.rows.where((r) => r.state == RoomTurnState.working),
        isEmpty,
      );
      expect(round.rows.where((r) => r.queuePosition != null), isEmpty);
    });

    test('later rounds have no known total; previous rounds are kept', () {
      final seq = EventSeq();
      final u = seq.user('ship it');
      final disc = u['event_id'] as String;
      final r1 = seq.member('m-builder', 'builder', 'ask @radar', disc);
      final events = _events([
        u,
        r1,
        seq.settled('m-builder', disc, messageId: r1['event_id'] as String),
        seq.settled('m-review', disc, passed: true),
        seq.settled('m-lead', disc, passed: true),
        seq.settled('m-radar', disc, passed: true),
        seq.settled('m-radar', disc, round: 1, passed: true),
      ]);
      final round = deriveRoomRound(
        events: events,
        members: _members,
        driverStatus: driver(),
        now: _now,
      )!;
      expect(round.round, 2);
      expect(round.total, isNull);
      expect(round.previous, hasLength(1));
      expect(round.previous.single.round, 1);
      expect(round.previous.single.rows.map((r) => r.member.memberId), [
        'm-builder',
        'm-review',
        'm-lead',
        'm-radar',
      ]);
    });

    test('a member the live probe sees working is working, even in a later '
        'round the log cannot predict', () {
      final seq = EventSeq();
      final u = seq.user('ship it');
      final disc = u['event_id'] as String;
      final events = _events([
        u,
        seq.settled('m-builder', disc, passed: true),
        seq.settled('m-review', disc, passed: true),
        seq.settled('m-lead', disc, passed: true),
        seq.settled('m-radar', disc, passed: true),
      ]);
      final round = deriveRoomRound(
        events: events,
        members: _members,
        driverStatus: driver(working: true, counts: {'running': 1}),
        now: _now,
        live: {
          'm-lead': const RoomMemberLive(
            steps: [RoomLiveStep.tool('terminal', context: 'flutter test')],
          ),
        },
      )!;
      final lead = round.rows.firstWhere((r) => r.member.memberId == 'm-lead');
      expect(lead.state, RoomTurnState.working);
      expect(lead.live?.current?.tool, 'terminal');
    });
  });

  group('RoomRoundDetail', () {
    testWidgets('each member says something specific; "Next in the round" '
        'and per-row "Queued" chips are gone', (tester) async {
      final live = _liveRound();
      final round = deriveRoomRound(
        events: live.events,
        members: _members,
        driverStatus: driver(working: true, counts: {'running': 1}),
        now: _now,
        live: {
          'm-review': const RoomMemberLive(
            steps: [
              RoomLiveStep.thinking(done: true),
              RoomLiveStep.tool('terminal', context: 'flutter test'),
            ],
          ),
        },
      )!;
      await _pumpDetail(tester, round);
      expect(_rowText(tester, 'm-builder'), 'Replied in 20 s');
      // 400 - 130 = 270 s.
      expect(_rowText(tester, 'm-review'), 'terminal · flutter test · 4:30');
      expect(_rowText(tester, 'm-lead'), 'Next to reply');
      expect(_rowText(tester, 'm-radar'), 'Waiting for turn (#2)');
      expect(find.text('Next in the round'), findsNothing);
      expect(find.text('Queued'), findsNothing);
      expect(find.text('1 of 4 replied'), findsOneWidget);
      // Elapsed since the user's message (t=110).
      expect(find.text('4:50'), findsOneWidget);
    });

    testWidgets('live phases without a tool: thinking, writing, or the plain '
        'fallback when the server sent nothing', (tester) async {
      final live = _liveRound();
      RoomRoundModel with_(RoomMemberLive? l) => deriveRoomRound(
        events: live.events,
        members: _members,
        driverStatus: driver(working: true, counts: {'running': 1}),
        now: _now,
        live: {'m-review': ?l},
      )!;
      await _pumpDetail(
        tester,
        with_(const RoomMemberLive(steps: [RoomLiveStep.thinking()])),
      );
      expect(_rowText(tester, 'm-review'), 'Thinking… 4:30');
      await _pumpDetail(
        tester,
        with_(const RoomMemberLive(steps: [RoomLiveStep.writing()])),
      );
      expect(_rowText(tester, 'm-review'), 'Writing a reply… 4:30');
      await _pumpDetail(tester, with_(null));
      expect(_rowText(tester, 'm-review'), 'Replying to your message · 4:30');
    });

    testWidgets('failures say why with a translated reason, never the raw '
        'error; unknown reasons fall back', (tester) async {
      final seq = EventSeq();
      final u = seq.user('ship it');
      final disc = u['event_id'] as String;
      final events = _events([
        u,
        _failedWith(seq, 'm-builder', disc, 'provider_quota_limit'),
        _failedWith(seq, 'm-review', disc, 'unknown'),
        seq.cancelled('m-lead', disc),
        seq.deferred('m-radar', disc),
      ]);
      final round = deriveRoomRound(
        events: events,
        members: _members,
        driverStatus: driver(),
        now: _now,
      )!;
      await _pumpDetail(tester, round);
      expect(_rowText(tester, 'm-builder'), 'Error: provider usage limit');
      expect(_rowText(tester, 'm-review'), 'Could not reply');
      expect(_rowText(tester, 'm-lead'), 'Cancelled: a newer message arrived');
      expect(_rowText(tester, 'm-radar'), 'Unavailable · will retry');
      expect(find.textContaining('provider timeout'), findsNothing);
    });

    testWidgets('pending approvals sit above the members', (tester) async {
      final seq = EventSeq();
      final u = seq.user('ship it');
      final round = deriveRoomRound(
        events: _events([u]),
        members: _members,
        driverStatus: driver(
          working: true,
          counts: {'running': 1},
          pending: [approvalAction(member: 'm-builder')],
        ),
        now: _now,
      )!;
      await _pumpDetail(
        tester,
        round,
        approvals: const [
          SizedBox(key: ValueKey('approval-under-test'), height: 40),
        ],
      );
      final approval = tester.getTopLeft(
        find.byKey(const ValueKey('approval-under-test')),
      );
      final firstRow = tester.getTopLeft(
        find.byKey(const ValueKey('room-round-row-m-builder')),
      );
      expect(approval.dy, lessThan(firstRow.dy));
      // The row does not repeat the command shown in the card above.
      expect(
        _rowText(tester, 'm-builder'),
        'Waiting for your permission · 4:50',
      );
    });

    testWidgets('tapping a member who replied jumps to the reply; tapping '
        'the working one opens its live steps', (tester) async {
      final live = _liveRound();
      final round = deriveRoomRound(
        events: live.events,
        members: _members,
        driverStatus: driver(working: true, counts: {'running': 1}),
        now: _now,
        live: {
          'm-review': const RoomMemberLive(
            steps: [
              RoomLiveStep.thinking(done: true),
              RoomLiveStep.tool(
                'read_file',
                context: 'CHANGELOG.md',
                done: true,
              ),
              RoomLiveStep.tool('terminal', context: 'flutter test'),
            ],
          ),
        },
      )!;
      final opened = <String>[];
      await _pumpDetail(tester, round, onOpenReply: opened.add);
      await tester.tap(find.byKey(const ValueKey('room-round-row-m-builder')));
      await _frames(tester);
      expect(opened, [live.events[1].eventId]);

      expect(
        find.byKey(const ValueKey('room-round-steps-m-review')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('room-round-row-m-review')));
      await _frames(tester);
      final steps = find.byKey(const ValueKey('room-round-steps-m-review'));
      expect(steps, findsOneWidget);
      expect(
        find.descendant(
          of: steps,
          matching: find.text('read_file · CHANGELOG.md'),
        ),
        findsOneWidget,
      );
      // Waiting members have nothing to open.
      await tester.tap(find.byKey(const ValueKey('room-round-row-m-lead')));
      await _frames(tester);
      expect(opened, hasLength(1));
    });

    testWidgets('previous rounds start folded and unfold on tap', (
      tester,
    ) async {
      final seq = EventSeq();
      final u = seq.user('ship it');
      final disc = u['event_id'] as String;
      final events = _events([
        u,
        seq.settled('m-builder', disc, passed: true),
        seq.settled('m-review', disc, passed: true),
        seq.settled('m-lead', disc, passed: true),
        seq.settled('m-radar', disc, passed: true),
        seq.settled('m-radar', disc, round: 1, passed: true),
      ]);
      final round = deriveRoomRound(
        events: events,
        members: _members,
        driverStatus: driver(),
        now: _now,
      )!;
      await _pumpDetail(tester, round);
      expect(find.text('Previous rounds · 1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('room-round-past-1-row-m-builder')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('room-round-previous')));
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('room-round-past-1-row-m-builder')),
        findsOneWidget,
      );
      // Round 2 has no known total: count only.
      expect(find.text('1 replied'), findsOneWidget);
    });

    testWidgets('Spanish copy', (tester) async {
      final live = _liveRound();
      final round = deriveRoomRound(
        events: live.events,
        members: _members,
        driverStatus: driver(working: true, counts: {'running': 1}),
        now: _now,
      )!;
      await _pumpDetail(tester, round, locale: const Locale('es'));
      expect(_rowText(tester, 'm-builder'), 'Respondió en 20 s');
      expect(_rowText(tester, 'm-lead'), 'Siguiente en responder');
      expect(_rowText(tester, 'm-radar'), 'Esperando turno (2º)');
      expect(find.text('1 de 4 respondieron'), findsOneWidget);
    });
  });

  group('RoomScreen Activity sheet', () {
    Future<void> pumpScreen(
      WidgetTester tester,
      List<Map<String, dynamic>> events, {
      required RoomDriverStatus status,
      RoomMemberLiveSource? live,
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final log = buildLog(events);
      final room = buildRoom(latestSeq: log.latestSeq);
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
            gateway: _Gateway(room: room, log: log, status: status),
            capabilities: const RoomCapabilities(
              canSend: true,
              canStop: true,
              canApprove: true,
              canRetry: true,
            ),
            profileFor: (_) => null,
            prefs: MemoryRoomPrefs(),
            memberLive: live,
            pollTimer: (_, _) => _FakeTimer(),
            clock: () => _now,
          ),
        ),
      );
      await _frames(tester);
    }

    List<Map<String, dynamic>> liveRaw() {
      final seq = EventSeq();
      final u = seq.user('ship it');
      final disc = u['event_id'] as String;
      final reply = seq.member('m-builder', 'builder', 'done', disc);
      return [
        u,
        reply,
        seq.settled('m-builder', disc, messageId: reply['event_id'] as String),
      ];
    }

    testWidgets('the open sheet shows the working member\'s live step; it is '
        'read only while the sheet is open', (tester) async {
      final live = _Live({
        'm-review': const RoomMemberLive(
          steps: [RoomLiveStep.tool('terminal', context: 'flutter test')],
        ),
      });
      await pumpScreen(
        tester,
        liveRaw(),
        status: driver(working: true, counts: {'running': 1}),
        live: live,
      );
      expect(live.reads, 0);
      await tester.tap(find.byKey(const ValueKey('room-header')));
      await _frames(tester);
      expect(live.reads, 1);
      expect(_rowText(tester, 'm-review'), 'terminal · flutter test · 4:30');
      // The header toggles the sheet closed.
      await tester.tap(find.byKey(const ValueKey('room-header')));
      await _frames(tester);
      expect(find.byKey(const ValueKey('room-round-sheet')), findsNothing);
      expect(live.reads, 1);
    });

    testWidgets('approvals sit on top of the sheet; a replied member closes '
        'the sheet to show the reply', (tester) async {
      await pumpScreen(
        tester,
        liveRaw(),
        status: driver(
          working: true,
          counts: {'running': 1},
          pending: [approvalAction(member: 'm-review', task: 'task-x')],
        ),
      );
      await tester.tap(find.byKey(const ValueKey('room-header')));
      await _frames(tester);
      final card = find.byKey(const ValueKey('room-round-approval-apr-1'));
      expect(card, findsOneWidget);
      expect(
        tester.getTopLeft(card).dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('room-round-row-m-builder')),
              )
              .dy,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('room-round-row-m-builder')));
      await _frames(tester);
      expect(find.byKey(const ValueKey('room-round-sheet')), findsNothing);
    });
  });
}
