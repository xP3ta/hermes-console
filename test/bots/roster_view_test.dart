import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/desktop_projection_rooms.dart';
import 'package:hermes_android/core/bots/state/attention.dart';
import 'package:hermes_android/core/bots/ui/roster/bots_roster_view.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_model.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/room_member_status.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/spec070_fixtures.dart';

MissionAgent _agent(
  String name, {
  MissionAgentStatus status = MissionAgentStatus.idle,
  Map<String, dynamic> meta = const {},
  AgentProfileWorkerSession? worker,
  String? preview,
  double? lastActive,
  String? liveTitle,
}) => MissionAgent(
  profile: AgentProfile(
    name: name,
    botModeUiMeta: meta,
    workerSession: worker,
    canonicalSession: preview == null && lastActive == null
        ? null
        : AgentProfileSessionSummary(
            id: 'chat-$name',
            title: 'Bot Chat',
            preview: preview ?? '',
            lastActive: lastActive,
          ),
  ),
  status: status,
  statusEvidence: '',
  usage: const MissionUsage(),
  liveSessionTitle: liveTitle,
);

BotRosterEntry _bot(
  String name, {
  BotFaceSignal signal = BotFaceSignal.idle,
  Map<String, dynamic> meta = const {},
  int atSeconds = 0,
  String? workingOn,
  String preview = '',
}) => BotRosterEntry(
  agent: _agent(name, meta: meta),
  signal: signal,
  workingOn: workingOn,
  preview: preview,
  at: atSeconds == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(atSeconds * 1000),
);

Widget _app(Widget child, {bool reduceMotion = false}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(body: child),
  ),
);

void main() {
  group('RosterLayout ordering (spec 070 S1)', () {
    test('pinned on top, Needs you first, user sections, then recency', () {
      final layout = RosterLayout.build(
        bots: [
          _bot('pinned', meta: {'pinned': true}, atSeconds: 50),
          _bot('old', atSeconds: 10),
          _bot('fresh', atSeconds: 90),
          _bot('asks', signal: BotFaceSignal.attention, atSeconds: 5),
          _bot(
            'ops-b',
            meta: {'sectionId': 's1', 'sectionName': 'Ops'},
            atSeconds: 20,
          ),
          _bot(
            'ops-a',
            meta: {'sectionId': 's1', 'sectionName': 'Ops'},
            atSeconds: 30,
          ),
          _bot(
            'art',
            meta: {'sectionId': 's0', 'sectionName': 'Art'},
            atSeconds: 1,
          ),
          _bot('ghost', meta: {'hidden': true}, atSeconds: 99),
        ],
        rooms: [
          RoomRosterEntry(
            roomKey: 'hosted:r1',
            hostedRoomId: 'r1',
            title: 'Room one',
            members: const [],
            at: DateTime.fromMillisecondsSinceEpoch(70000),
          ),
          RoomRosterEntry(
            roomKey: 'hosted:r2',
            hostedRoomId: 'r2',
            title: 'Blocked room',
            members: const [],
            attentionCount: 2,
            at: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
        ],
      );
      expect(layout.pinned.map((b) => b.profile.name), ['pinned']);
      expect(layout.sections.map((s) => s.kind), [
        RosterSectionKind.needsYou,
        RosterSectionKind.user,
        RosterSectionKind.user,
        RosterSectionKind.recent,
      ]);
      expect(layout.sections[0].entries.map((e) => e.title), [
        'asks',
        'Blocked room',
      ]);
      expect(layout.sections[1].name, 'Art');
      expect(layout.sections[2].name, 'Ops');
      expect(layout.sections[2].entries.map((e) => e.title), [
        'ops-a',
        'ops-b',
      ]);
      expect(layout.sections[3].entries.map((e) => e.title), [
        'fresh',
        'Room one',
        'old',
      ]);
      expect(layout.hiddenCount, 1);
    });

    test('filter Bots/Rooms and search flatten the roster', () {
      final bots = [
        _bot('alpha', meta: {'pinned': true}),
        _bot('beta'),
      ];
      final rooms = [
        const RoomRosterEntry(
          roomKey: 'hosted:r',
          hostedRoomId: 'r',
          title: 'Alpha room',
          members: [],
        ),
      ];
      final onlyRooms = RosterLayout.build(
        bots: bots,
        rooms: rooms,
        filter: RosterFilter.rooms,
      );
      expect(onlyRooms.pinned, isEmpty);
      expect(onlyRooms.sections.single.entries.single.title, 'Alpha room');
      final onlyBots = RosterLayout.build(
        bots: bots,
        rooms: rooms,
        filter: RosterFilter.bots,
      );
      expect(
        onlyBots.sections.expand((s) => s.entries).whereType<RoomRosterEntry>(),
        isEmpty,
      );
      final search = RosterLayout.build(
        bots: bots,
        rooms: rooms,
        query: 'ÁLPHA',
      );
      expect(search.pinned, isEmpty);
      expect(search.sections.single.entries.map((e) => e.title).toSet(), {
        'alpha',
        'Alpha room',
      });
    });
  });

  group('state signal and working line', () {
    test('signal comes from server evidence with attention first', () {
      const idle = BotLiveStatus(RoomPresence.idle);
      expect(
        BotRosterEntry.signalFor(agent: _agent('a'), live: idle),
        BotFaceSignal.idle,
      );
      expect(
        BotRosterEntry.signalFor(
          agent: _agent('a', status: MissionAgentStatus.working),
          live: idle,
        ),
        BotFaceSignal.working,
      );
      expect(
        BotRosterEntry.signalFor(
          agent: _agent('a', status: MissionAgentStatus.thinking),
          live: idle,
        ),
        BotFaceSignal.thinking,
      );
      expect(
        BotRosterEntry.signalFor(
          agent: _agent('a', status: MissionAgentStatus.responding),
          live: idle,
        ),
        BotFaceSignal.speaking,
      );
      expect(
        BotRosterEntry.signalFor(
          agent: _agent('a', status: MissionAgentStatus.working),
          live: idle,
          hasAttention: true,
        ),
        BotFaceSignal.attention,
      );
      expect(
        BotRosterEntry.signalFor(
          agent: _agent('a'),
          live: const BotLiveStatus(RoomPresence.working),
        ),
        BotFaceSignal.working,
      );
    });

    test('working line uses the fresh worker title, else the preview', () {
      final now = DateTime.now();
      final working = BotRosterEntry.from(
        agent: _agent(
          'forja',
          status: MissionAgentStatus.working,
          worker: AgentProfileWorkerSession(
            id: 'w',
            source: 'tool',
            title: 'flutter test (3/9)',
            lastActive: now.millisecondsSinceEpoch / 1000,
          ),
          preview: 'old reply',
          lastActive: now.millisecondsSinceEpoch / 1000 - 600,
        ),
        live: const BotLiveStatus(RoomPresence.idle),
        now: now,
      );
      expect(working.workingOn, 'flutter test (3/9)');
      final idle = BotRosterEntry.from(
        agent: _agent(
          'review',
          preview: 'No P0/P1, one nit.',
          lastActive: 1790000000,
        ),
        live: const BotLiveStatus(RoomPresence.idle),
        now: now,
      );
      expect(idle.signal, BotFaceSignal.idle);
      expect(idle.workingOn, isNull);
      expect(idle.preview, 'No P0/P1, one nit.');
      expect(idle.at, DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000));
    });
  });

  group('rooms from hosted groups and Desktop projection', () {
    test('hosted preview, needs-you and projection Desktop rows', () {
      final room = spec070Room();
      final hosted = HostedGroupsSnapshot(
        capabilities: spec070Capabilities(),
        rooms: [room],
        logs: [spec070LogPage('groups_log_page1')],
        driverStatuses: {room.roomId: spec070DriverStatus()},
      );
      final profiles = spec070Profiles();
      final entries = RoomRosterEntry.build(
        hosted: hosted,
        attention: AttentionSummary.fromSnapshot(hosted),
        projection: DesktopProjectionRooms.parse(
          profiles.singleWhere((p) => p.name == 'default').groupsProjection,
          hostedRoomIds: {room.roomId},
        ),
        localProfiles: {for (final p in profiles) p.name: p},
      );
      final hostedEntry = entries.singleWhere((e) => !e.desktopOnly);
      expect(hostedEntry.title, 'Console Devs');
      expect(hostedEntry.needsYou, isTrue);
      expect(hostedEntry.working, isTrue);
      expect(hostedEntry.members.map((m) => m.handle), ['astra', 'radar']);
      final desktop = entries.singleWhere((e) => e.desktopOnly);
      expect(desktop.title, 'Hermes Console · Equipo');
      expect(desktop.needsYou, isTrue);
      expect(desktop.previewAuthor, 'astra');
      expect(desktop.projection?.readOnly, isTrue);
    });
  });

  group('roster widgets', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> pumpRoster(
      WidgetTester tester, {
      required List<BotRosterEntry> bots,
      List<RoomRosterEntry> rooms = const [],
      ValueChanged<BotRosterEntry>? onActions,
    }) async {
      final prefs = await SharedPreferences.getInstance();
      final search = ValueNotifier(false);
      addTearDown(search.dispose);
      await tester.pumpWidget(
        _app(
          BotsRosterView(
            bots: bots,
            rooms: rooms,
            avatarCache: null,
            searchOpen: search,
            prefs: prefs,
            connectionId: 'c',
            onOpenBot: (_) {},
            onBotActions: onActions ?? (_) {},
            onOpenRoom: (_) {},
          ),
          reduceMotion: true,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('bot row shows one state signal, working line in accent', (
      tester,
    ) async {
      await pumpRoster(
        tester,
        bots: [
          _bot(
            'builder',
            signal: BotFaceSignal.working,
            workingOn: 'flutter test (3/9)',
            preview: 'ignored while working',
          ),
          _bot('review', preview: 'No P0/P1, one nit.'),
        ],
      );
      final line = tester.widget<Text>(
        find.byKey(const ValueKey('roster-line-builder')),
      );
      expect(line.data, 'Working · flutter test (3/9)');
      final context = tester.element(find.byType(BotsRosterView));
      expect(line.style?.color, Theme.of(context).hermes.accentText);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('roster-line-review')))
            .data,
        'No P0/P1, one nit.',
      );
      // Single state signal: the face ring; no presence or unread dots.
      expect(
        find.byKey(const ValueKey('living-face-ring-working')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('living-face-ring-idle')), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              RegExp(
                r'^(room-status-|mission-bot-unread-)',
              ).hasMatch((w.key as ValueKey<String>).value),
        ),
        findsNothing,
      );
      expect(find.text('Active'), findsNothing);
      expect(find.text('Inactive'), findsNothing);
    });

    testWidgets('Needs you section first and Desktop room label', (
      tester,
    ) async {
      late RoomRosterEntry desktopRoom;
      await pumpRoster(
        tester,
        bots: [
          _bot('calm', atSeconds: 100),
          _bot('asks', signal: BotFaceSignal.attention, atSeconds: 1),
        ],
        rooms: [
          desktopRoom = RoomRosterEntry(
            roomKey: 'desktop:id:x',
            title: 'Desktop team',
            members: const [RoomRosterMember('astra', null)],
            previewAuthor: 'astra',
            preview: 'ship it?',
            attentionCount: 1,
            at: DateTime.fromMillisecondsSinceEpoch(50000),
          ),
        ],
      );
      final needsY = tester
          .getTopLeft(find.byKey(const ValueKey('roster-section-needs-you')))
          .dy;
      final recentY = tester
          .getTopLeft(find.byKey(const ValueKey('roster-section-recent')))
          .dy;
      expect(needsY, lessThan(recentY));
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('mission-bot-row-asks')))
            .dy,
        lessThan(recentY),
      );
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('mission-bot-row-calm')))
            .dy,
        greaterThan(recentY),
      );
      expect(
        find.byKey(ValueKey('roster-room-desktop-${desktopRoom.publicKey}')),
        findsOneWidget,
      );
      // Spec 080: inline status text on the preview line, not a boxed tag.
      expect(
        find.text('Desktop · read only', findRichText: true),
        findsOneWidget,
      );
      expect(
        tester
            .getTopLeft(
              find.byKey(
                ValueKey('roster-room-desktop-${desktopRoom.publicKey}'),
              ),
            )
            .dy,
        greaterThan(
          tester
                  .getBottomLeft(
                    find.byKey(
                      ValueKey('roster-room-title-${desktopRoom.publicKey}'),
                    ),
                  )
                  .dy -
              1,
        ),
      );
      expect(
        find.byKey(ValueKey('roster-room-needs-you-${desktopRoom.publicKey}')),
        findsOneWidget,
      );
      expect(find.text('astra: ship it?'), findsOneWidget);
    });

    testWidgets('filter segment switches between bots and rooms', (
      tester,
    ) async {
      await pumpRoster(
        tester,
        bots: [_bot('solo')],
        rooms: const [
          RoomRosterEntry(
            roomKey: 'hosted:r',
            hostedRoomId: 'r',
            title: 'Only room',
            members: [],
          ),
        ],
      );
      expect(find.text('Only room'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('roster-filter-bots')));
      await tester.pumpAndSettle();
      expect(find.text('Only room'), findsNothing);
      expect(
        find.byKey(const ValueKey('mission-bot-row-solo')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('roster-filter-rooms')));
      await tester.pumpAndSettle();
      expect(find.text('Only room'), findsOneWidget);
      expect(find.byKey(const ValueKey('mission-bot-row-solo')), findsNothing);
    });

    testWidgets('long-press opens the bot actions callback', (tester) async {
      BotRosterEntry? pressed;
      await pumpRoster(
        tester,
        bots: [_bot('solo')],
        onActions: (entry) => pressed = entry,
      );
      await tester.longPress(find.byKey(const ValueKey('mission-bot-solo')));
      expect(pressed?.profile.name, 'solo');
    });
  });
}
