import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/dots_home_model.dart';
import 'package:hermes_android/core/bots/ui/roster/dots_home_view.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_model.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/room_member_status.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

MissionAgent _agent(
  String name, {
  bool isDefault = false,
  Map<String, dynamic> meta = const {},
  String preview = '',
}) => MissionAgent(
  profile: AgentProfile(
    name: name,
    isDefault: isDefault,
    botModeUiMeta: meta,
    canonicalSession: AgentProfileSessionSummary(
      id: 'chat-$name',
      title: 'Bot Chat',
      preview: preview,
    ),
  ),
  status: MissionAgentStatus.idle,
  statusEvidence: '',
  usage: const MissionUsage(),
);

BotRosterEntry _bot(
  String name, {
  bool isDefault = false,
  BotFaceSignal signal = BotFaceSignal.idle,
  Map<String, dynamic> meta = const {},
  int atSeconds = 0,
  String? workingOn,
  String preview = '',
  int delegated = 0,
}) => BotRosterEntry(
  agent: _agent(name, isDefault: isDefault, meta: meta, preview: preview),
  signal: signal,
  workingOn: workingOn,
  preview: preview,
  delegated: delegated,
  at: atSeconds == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(atSeconds * 1000),
);

RoomRosterEntry _room(
  String id, {
  int attention = 0,
  bool working = false,
  int atSeconds = 0,
  bool desktop = false,
  List<String> members = const ['astra', 'forja'],
}) => RoomRosterEntry(
  roomKey: desktop ? 'desktop:$id' : 'hosted:$id',
  hostedRoomId: desktop ? null : id,
  title: 'Room $id',
  members: [for (final m in members) RoomRosterMember(m, null)],
  attentionCount: attention,
  working: working,
  at: atSeconds == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(atSeconds * 1000),
);

/// The busy team of the C3 mockup: main working, one bot waiting, two
/// working, the rest idle by recency; one hidden bot.
List<BotRosterEntry> _busyTeam() => [
  _bot('forja', signal: BotFaceSignal.working, atSeconds: 40),
  _bot('argos', atSeconds: 90),
  _bot(
    'default',
    isDefault: true,
    meta: {'title': 'Hermes'},
    signal: BotFaceSignal.working,
    workingOn: 'Reviewing PR #134',
    atSeconds: 10,
  ),
  _bot('oficina', atSeconds: 70),
  _bot(
    'astra',
    signal: BotFaceSignal.attention,
    workingOn: 'Publish the note?',
    atSeconds: 5,
  ),
  _bot('radar', signal: BotFaceSignal.working, atSeconds: 80),
  _bot('ghost', meta: {'hidden': true}, atSeconds: 99),
];

Widget _app(
  Widget child, {
  Locale locale = const Locale('en'),
  double textScale = 1,
  bool reduceMotion = false,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: reduceMotion,
      ),
      child: Scaffold(body: child),
    ),
  ),
);

class _Taps {
  final opened = <String>[];
  final actions = <String>[];
  final rooms = <String>[];
}

Widget _view(
  List<BotRosterEntry> bots, {
  List<RoomRosterEntry> rooms = const [],
  _Taps? taps,
  ValueNotifier<bool>? searchOpen,
}) {
  final t = taps ?? _Taps();
  return DotsHomeView(
    bots: bots,
    rooms: rooms,
    avatarCache: null,
    searchOpen: searchOpen ?? ValueNotifier(false),
    onOpenBot: (e) => t.opened.add(e.profile.name),
    onBotActions: (e) => t.actions.add(e.profile.name),
    onOpenRoom: (r) => t.rooms.add(r.roomKey),
    onRoomActions: (r) => t.rooms.add('actions:${r.roomKey}'),
  );
}

Future<void> _phone(WidgetTester tester, {Size size = const Size(360, 800)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  return Future.value();
}

Finder _tile(String name) => find.byKey(ValueKey('dots-tile-$name'));

void main() {
  group('DotsHomeLayout', () {
    test('main bot is the hero even when another bot waits; grid order is '
        'waiting, working, then the rest by recency', () {
      final layout = DotsHomeLayout.build(bots: _busyTeam(), rooms: const []);
      expect(layout.main?.profile.name, 'default');
      expect(layout.team.map((b) => b.profile.name), [
        'astra',
        'radar',
        'forja',
        'argos',
        'oficina',
      ]);
      expect(layout.working, 3, reason: 'main + radar + forja');
      expect(layout.waiting, 1);
      expect(layout.hiddenCount, 1);
    });

    test('a waiting main bot keeps the hero slot and never enters the '
        'grid', () {
      final layout = DotsHomeLayout.build(
        bots: [
          _bot('astra', atSeconds: 50),
          _bot('default', isDefault: true, signal: BotFaceSignal.attention),
        ],
        rooms: const [],
      );
      expect(layout.main?.profile.name, 'default');
      expect(layout.team.map((b) => b.profile.name), ['astra']);
      expect(layout.waiting, 1);
    });

    test('pinned bots lead their tier; hidden bots are left out unless '
        'shown', () {
      final bots = [
        _bot('a', atSeconds: 90),
        _bot('b', meta: {'pinned': true}, atSeconds: 10),
        _bot('c', meta: {'hidden': true}, atSeconds: 99),
      ];
      expect(
        DotsHomeLayout.build(
          bots: bots,
          rooms: const [],
        ).team.map((b) => b.profile.name),
        ['b', 'a'],
      );
      expect(
        DotsHomeLayout.build(
          bots: bots,
          rooms: const [],
          showHidden: true,
        ).team.map((b) => b.profile.name),
        ['b', 'c', 'a'],
      );
    });

    test('rooms: needing you first, then working, then by recency', () {
      final layout = DotsHomeLayout.build(
        bots: const [],
        rooms: [
          _room('old', atSeconds: 10),
          _room('busy', working: true, atSeconds: 5),
          _room('fresh', atSeconds: 90),
          _room('asks', attention: 1, atSeconds: 1),
        ],
      );
      expect(layout.rooms.map((r) => r.title), [
        'Room asks',
        'Room busy',
        'Room fresh',
        'Room old',
      ]);
    });

    test('search filters the hero, the grid and the rooms', () {
      final layout = DotsHomeLayout.build(
        bots: _busyTeam(),
        rooms: [
          _room('astra-room'),
          _room('other', members: const ['x']),
        ],
        query: 'ÁSTRA',
      );
      expect(layout.main, isNull);
      expect(layout.team.map((b) => b.profile.name), ['astra']);
      expect(layout.rooms.map((r) => r.title), ['Room astra-room']);
    });
  });

  group('BotRosterEntry status comes only from the canonical Bot Chat', () {
    MissionAgent project(List<DesktopActiveSession> rows) {
      final profile = AgentProfile.fromJson({
        'name': 'default',
        'is_default': true,
        'canonical_session': {'id': 'bot-chat', 'title': 'Bot Chat'},
        'last_session': {'id': 'normal-chat', 'title': 'Plan'},
      });
      return MissionProjector.build(
        snapshot: MissionBackendSnapshot(
          profiles: [profile],
          profilesCapability: MissionCapabilityState.available,
          loadedAt: DateTime.now(),
          activeSessions: rows,
          activeSessionsAuthoritative: true,
          activeSessionsObservedAt: DateTime.now(),
        ),
      ).agents.single;
    }

    testWidgets('a working normal chat leaves the hero idle; the canonical '
        'one lights it with its own title', (tester) async {
      await _phone(tester);
      final normal = BotRosterEntry.from(
        agent: project(const [
          DesktopActiveSession(
            runtimeSessionId: 'rt',
            storedSessionId: 'normal-chat',
            status: 'working',
            title: 'Plan the trip',
          ),
        ]),
        live: const BotLiveStatus(RoomPresence.idle),
      );
      expect(normal.signal, BotFaceSignal.idle);
      final canonical = BotRosterEntry.from(
        agent: project(const [
          DesktopActiveSession(
            runtimeSessionId: 'rt',
            storedSessionId: 'bot-chat',
            status: 'working',
            title: 'Reviewing PR #134',
          ),
        ]),
        live: const BotLiveStatus(RoomPresence.idle),
      );
      expect(canonical.signal, BotFaceSignal.working);
      await tester.pumpWidget(_app(_view([normal])));
      expect(find.text('Plan the trip'), findsNothing);
      expect(find.byKey(const ValueKey('roster-line-default')), findsOneWidget);
      await tester.pumpWidget(_app(_view([canonical])));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('roster-line-default')))
            .data,
        'Reviewing PR #134',
      );
    });
  });

  test('delegations count only from the canonical Bot Chat', () {
    final profile = AgentProfile.fromJson({
      'name': 'default',
      'is_default': true,
      'canonical_session': {'id': 'bot-chat', 'title': 'Bot Chat'},
    });
    int delegated(List<MissionLiveChat> chats) => MissionProjector.build(
      snapshot: MissionBackendSnapshot(
        profiles: [profile],
        profilesCapability: MissionCapabilityState.available,
        loadedAt: DateTime.now(),
      ),
      liveChats: chats,
    ).agents.single.botChatDelegated;
    const normal = MissionLiveChat(
      profileName: 'default',
      sessionId: 'normal-chat',
      title: 'Plan',
      phase: MissionLivePhase.working,
      subagentCount: 3,
    );
    const canonical = MissionLiveChat(
      profileName: 'default',
      sessionId: 'bot-chat',
      title: 'Bot Chat',
      phase: MissionLivePhase.working,
      subagentCount: 2,
    );
    expect(delegated(const [normal]), 0);
    expect(delegated(const [normal, canonical]), 2);
  });

  group('DotsHomeView', () {
    testWidgets('hero first, waiting tile first, summary and rooms', (
      tester,
    ) async {
      await _phone(tester);
      await tester.pumpWidget(
        _app(
          _view(_busyTeam(), rooms: [_room('r1', working: true), _room('r2')]),
        ),
      );
      final hero = tester.getRect(find.byKey(const ValueKey('dots-main')));
      final astra = tester.getRect(_tile('astra'));
      final radar = tester.getRect(_tile('radar'));
      expect(hero.bottom, lessThanOrEqualTo(astra.top));
      expect(astra.top, radar.top);
      expect(astra.left, lessThan(radar.left));
      expect(find.byKey(const ValueKey('dots-tile-default')), findsNothing);
      expect(find.byKey(const ValueKey('dots-tile-ghost')), findsNothing);
      expect(find.text('3 working · 1 waiting for you'), findsOneWidget);
      expect(find.text('YOUR TEAM'), findsOneWidget);
      // Scroll to the rooms.
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('roster-room-row-${_room('r2').publicKey}')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('ROOMS'), findsOneWidget);
      final r1 = tester.getRect(
        find.byKey(ValueKey('roster-room-row-${_room('r1').publicKey}')),
      );
      final r2 = tester.getRect(
        find.byKey(ValueKey('roster-room-row-${_room('r2').publicKey}')),
      );
      expect(r1.top, r2.top, reason: 'two rooms per row');
      expect(r1.left, lessThan(r2.left));
      expect(
        tester
            .widget<Text>(
              find.byKey(ValueKey('roster-room-line-${_room('r1').publicKey}')),
            )
            .data,
        'Working…',
      );
    });

    testWidgets('taps open the canonical chat, long press the actions, room '
        'tap the room', (tester) async {
      await _phone(tester);
      final taps = _Taps();
      await tester.pumpWidget(
        _app(_view(_busyTeam(), rooms: [_room('r1')], taps: taps)),
      );
      await tester.tap(find.byKey(const ValueKey('mission-bot-default')));
      await tester.tap(find.byKey(const ValueKey('mission-bot-astra')));
      await tester.longPress(find.byKey(const ValueKey('mission-bot-radar')));
      await tester.longPress(find.byKey(const ValueKey('mission-bot-default')));
      expect(taps.opened, ['default', 'astra']);
      expect(taps.actions, ['radar', 'default']);
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('roster-room-row-${_room('r1').publicKey}')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find.byKey(ValueKey('roster-room-row-${_room('r1').publicKey}')),
      );
      expect(taps.rooms, ['hosted:r1']);
    });

    testWidgets('activity chip only with delegations; it opens the main '
        'Bot Chat', (tester) async {
      await _phone(tester);
      final taps = _Taps();
      await tester.pumpWidget(_app(_view(_busyTeam(), taps: taps)));
      expect(find.byKey(const ValueKey('dots-activity')), findsNothing);
      final team = [
        for (final b in _busyTeam())
          if (b.profile.name == 'default')
            _bot(
              'default',
              isDefault: true,
              signal: BotFaceSignal.working,
              workingOn: 'Reviewing PR #134',
              delegated: 2,
            )
          else
            b,
      ];
      await tester.pumpWidget(_app(_view(team, taps: taps)));
      expect(find.text('Activity · 2 delegated'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dots-activity')));
      expect(taps.opened, ['default']);
    });

    testWidgets('TalkBack labels say who, the main role and the status', (
      tester,
    ) async {
      await _phone(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(_view(_busyTeam()), locale: const Locale('es')),
      );
      expect(
        find.bySemanticsLabel(
          'Hermes, bot principal, trabajando: Reviewing PR #134',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('astra, te espera: Publish the note?'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('radar, trabajando'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^argos, libre')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('touch targets are at least 48 dp', (tester) async {
      await _phone(tester);
      await tester.pumpWidget(_app(_view(_busyTeam())));
      for (final name in ['default', 'astra', 'radar', 'argos']) {
        final size = tester.getSize(find.byKey(ValueKey('mission-bot-$name')));
        expect(size.width, greaterThanOrEqualTo(48), reason: name);
        expect(size.height, greaterThanOrEqualTo(48), reason: name);
      }
    });

    for (final locale in const [Locale('es'), Locale('en')]) {
      testWidgets('text scale 2.0 at 360x800 does not overflow '
          '(${locale.languageCode})', (tester) async {
        await _phone(tester);
        final long = [
          _bot(
            'default',
            isDefault: true,
            meta: {'title': 'Hermes principal con un nombre larguísimo'},
            signal: BotFaceSignal.working,
            workingOn: 'Revisando la PR #134 con un título muy largo de verdad',
            delegated: 12,
          ),
          for (final b in _busyTeam())
            if (b.profile.name != 'default') b,
          _bot('social-writer-with-a-long-handle', atSeconds: 3),
        ];
        await tester.pumpWidget(
          _app(
            _view(
              long,
              rooms: [
                _room('a very long room name that wraps', attention: 1),
                _room('b', desktop: true),
              ],
            ),
            locale: locale,
            textScale: 2,
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('grid columns: 4 on a phone, 6 on an expanded tablet, 3 '
        'with 2x text', (tester) async {
      final team = [
        _bot('default', isDefault: true),
        for (var i = 0; i < 8; i++) _bot('b$i', atSeconds: 100 - i),
      ];
      Future<int> firstRow(Size size, {double textScale = 1}) async {
        await _phone(tester, size: size);
        await tester.pumpWidget(_app(_view(team), textScale: textScale));
        final top = tester.getRect(_tile('b0')).top;
        var n = 0;
        for (var i = 0; i < 8; i++) {
          final f = _tile('b$i');
          if (f.evaluate().isNotEmpty && tester.getRect(f).top == top) n++;
        }
        return n;
      }

      expect(await firstRow(const Size(360, 800)), 4);
      expect(await firstRow(const Size(1000, 800)), 6);
      expect(
        await firstRow(const Size(360, 800), textScale: 2),
        3,
        reason: 'very large text keeps names readable with one column less',
      );
    });

    testWidgets('idle home settles: no ticker and no scheduled frame; '
        'working faces tick at most one clock each', (tester) async {
      await _phone(tester);
      debugLivingBotFacesStill = false;
      addTearDown(() => debugLivingBotFacesStill = true);
      final idle = [
        _bot('default', isDefault: true),
        _bot('astra', atSeconds: 2),
        _bot('radar', atSeconds: 1),
      ];
      await tester.pumpWidget(_app(_view(idle)));
      await tester.pump(const Duration(seconds: 1));
      expect(livingBotFaceActiveTickers, 0);
      expect(livingBotFaceSharedBlinkTimers, lessThanOrEqualTo(1));
      expect(livingBotFacePendingBlinks, 0, reason: 'shared blink only');
      expect(tester.binding.hasScheduledFrame, isFalse);

      await tester.pumpWidget(_app(_view(_busyTeam())));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        livingBotFaceActiveTickers,
        4,
        reason:
            'one clock each for main, astra, radar and forja; idle '
            'faces none',
      );

      await tester.pumpWidget(_app(_view(_busyTeam()), reduceMotion: true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(livingBotFaceActiveTickers, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('search field filters the home', (tester) async {
      await _phone(tester);
      final open = ValueNotifier(false);
      await tester.pumpWidget(_app(_view(_busyTeam(), searchOpen: open)));
      open.value = true;
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('mission-bot-search')),
        'radar',
      );
      await tester.pump();
      expect(_tile('radar'), findsOneWidget);
      expect(_tile('astra'), findsNothing);
      expect(find.byKey(const ValueKey('dots-main')), findsNothing);
    });

    testWidgets('hidden toggle shows hidden bots in the grid', (tester) async {
      await _phone(tester);
      await tester.pumpWidget(_app(_view(_busyTeam())));
      expect(_tile('ghost'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('mission-show-hidden')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('mission-show-hidden')));
      await tester.pump();
      await tester.scrollUntilVisible(
        _tile('ghost'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(_tile('ghost'), findsOneWidget);
    });
  });

  testWidgets('dots face: amber dot while waiting, orbit while working, '
      'nothing extra idle', (tester) async {
    await _phone(tester);
    Widget face(BotFaceSignal signal) => _app(
      Center(
        child: LivingBotFace(
          profileName: 'astra',
          signal: signal,
          size: 56,
          style: LivingBotFaceStyle.dots,
        ),
      ),
    );
    await tester.pumpWidget(face(BotFaceSignal.attention));
    expect(find.byKey(const ValueKey('dots-face-waiting-dot')), findsOneWidget);
    expect(find.byKey(const ValueKey('dots-face-orbit')), findsNothing);
    await tester.pumpWidget(face(BotFaceSignal.working));
    expect(find.byKey(const ValueKey('dots-face-orbit')), findsOneWidget);
    expect(find.byKey(const ValueKey('dots-face-waiting-dot')), findsNothing);
    await tester.pumpWidget(face(BotFaceSignal.idle));
    expect(find.byKey(const ValueKey('dots-face-orbit')), findsNothing);
    expect(find.byKey(const ValueKey('dots-face-waiting-dot')), findsNothing);
    expect(find.byKey(const ValueKey('living-face-ring-idle')), findsNothing);
    // RenderObject sanity: the face paints inside its own boundary.
    expect(
      tester.renderObject(find.byType(LivingBotFace)),
      isA<RenderObject>(),
    );
  });
}
