// Regression tests for spec 070 roster, room and profile layout defects
// found during device QA (items #1–#9).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/state/attention.dart';
import 'package:hermes_android/core/bots/ui/profile/bot_profile_screen.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_header.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/bots/ui/roster/dots_home_view.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_model.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/room_member_status.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/inter_font.dart';
import 'room/room_fixtures.dart';

Widget _app(Widget home, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: home,
);

void _phone(WidgetTester tester) {
  // 1080 x 1920 at 3x, a typical phone.
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

MissionAgent _agent(
  String name, {
  String? preview,
  Map<String, dynamic>? meta,
}) => MissionAgent(
  profile: AgentProfile(
    name: name,
    botModeUiMeta: meta ?? const {},
    canonicalSession: preview == null
        ? null
        : AgentProfileSessionSummary(
            id: 'chat-$name',
            title: 'Bot Chat',
            preview: preview,
            lastActive: 1790000000,
          ),
  ),
  status: MissionAgentStatus.idle,
  statusEvidence: '',
  usage: const MissionUsage(),
);

Future<void> _pumpRoster(
  WidgetTester tester, {
  required List<BotRosterEntry> bots,
  List<RoomRosterEntry> rooms = const [],
}) async {
  _phone(tester);
  final search = ValueNotifier(false);
  addTearDown(search.dispose);
  await tester.pumpWidget(
    _app(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 640),
          disableAnimations: true,
        ),
        child: Scaffold(
          body: DotsHomeView(
            bots: bots,
            rooms: rooms,
            avatarCache: null,
            searchOpen: search,
            onOpenBot: (_) {},
            onBotActions: (_) {},
            onOpenRoom: (_) {},
            now: DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

RenderParagraph _paragraph(WidgetTester tester, Finder finder) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: finder, matching: find.byType(RichText)).first,
    );

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

Future<void> _pumpRoom(
  WidgetTester tester, {
  required List<Map<String, dynamic>> events,
  HostedGroupRoom? room,
  Locale locale = const Locale('en'),
}) async {
  _phone(tester);
  final log = buildLog(events);
  final resolved = room ?? buildRoom(latestSeq: log.latestSeq);
  await tester.pumpWidget(
    _app(
      RoomScreen(
        room: resolved,
        log: log,
        gateway: _NoGateway(),
        capabilities: const RoomCapabilities(canSend: true),
        profileFor: (_) => null,
        prefs: MemoryRoomPrefs(),
        pollTimer: (_, _) => _FakeTimer(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
      ),
      locale: locale,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadInterFont);

  group('roster layout #1–#4', () {
    testWidgets('#1 room title uses the free width (no early ellipsis)', (
      tester,
    ) async {
      final room = RoomRosterEntry(
        roomKey: 'hosted:r1',
        hostedRoomId: 'r1',
        title: 'Design Review',
        members: const [
          RoomRosterMember('builder', null),
          RoomRosterMember('review', null),
          RoomRosterMember('lead', null),
        ],
        preview: 'ok',
        at: DateTime.fromMillisecondsSinceEpoch((1790000000 - 86400) * 1000),
      );
      await _pumpRoster(tester, bots: const [], rooms: [room]);
      final title = find.byKey(ValueKey('roster-room-title-${room.publicKey}'));
      expect(title, findsOneWidget);
      final paragraph = _paragraph(tester, title);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(paragraph.text.toPlainText(), contains('Design Review'));
      // The Dots room card clusters its members' faces (up to three).
      final row = find.byKey(ValueKey('roster-room-row-${room.publicKey}'));
      expect(
        find.descendant(of: row, matching: find.byType(LivingBotFace)),
        findsNWidgets(3),
      );

      // A title too long for one line wraps to two instead of ellipsizing
      // after a handful of characters.
      final long = RoomRosterEntry(
        roomKey: 'hosted:r2',
        hostedRoomId: 'r2',
        title: 'Design Review Board and the Release Train Crew',
        members: const [RoomRosterMember('builder', null)],
        preview: 'ok',
        at: DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000),
      );
      await _pumpRoster(tester, bots: const [], rooms: [long]);
      final longTitle = find.byKey(
        ValueKey('roster-room-title-${long.publicKey}'),
      );
      expect(_paragraph(tester, longTitle).maxLines, 2);
      expect(tester.getSize(longTitle).height, greaterThan(30));
    });

    test('#2 previews are plain text for bots and rooms', () {
      expect(
        rosterPreviewText('Reviewed. Summary: **Failure today (16:20:21)**'),
        'Reviewed. Summary: Failure today (16:20:21)',
      );
      // rt1215: list markers go too (shared plainPreview).
      expect(rosterPreviewText('## Plan\n\n- `a`\n- b'), 'Plan a b');

      final bot = BotRosterEntry.from(
        agent: _agent(
          'atlas',
          preview: '**Failure today** `x` [link](http://a)',
        ),
        live: const BotLiveStatus(RoomPresence.idle),
        now: DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000),
      );
      expect(bot.preview, 'Failure today x link');

      final seq = EventSeq();
      final u = seq.user('hi');
      final m = seq.member(
        'm-builder',
        'builder',
        '## Done\n\n**Failure today** — see `log.txt`',
        u['event_id'] as String,
      );
      final log = buildLog([u, m]);
      final hosted = HostedGroupsSnapshot(
        rooms: [buildRoom(latestSeq: log.latestSeq)],
        logs: [log],
      );
      final rooms = RoomRosterEntry.build(
        hosted: hosted,
        attention: AttentionSummary.fromSnapshot(hosted),
      );
      expect(rooms.single.preview, 'Done Failure today — see log.txt');
    });
  });

  group('room layout #5–#8', () {
    List<Map<String, dynamic>> longRun() {
      final seq = EventSeq();
      final u = seq.user('status?');
      final disc = u['event_id'] as String;
      final long = List.generate(
        30,
        (i) => 'Paragraph $i of a long review answer.',
      ).join('\n\n');
      return [
        u,
        seq.member('m-review', 'review', 'short one', disc),
        seq.member('m-lead', 'lead', long, disc),
      ];
    }

    testWidgets('#5 opening never leaves a run header under the room header', (
      tester,
    ) async {
      final events = longRun();
      await _pumpRoom(tester, events: events);
      final transcript = find.byKey(const ValueKey('room-transcript'));
      final top = tester.getTopLeft(transcript).dy;
      final status = find.byType(AppBar);
      expect(status, findsOneWidget);
      // Transcript starts below the header (column layout, no overlap).
      expect(top, greaterThanOrEqualTo(tester.getBottomLeft(status).dy));
      // The newest speaker run's header (face, name, time) is fully visible
      // below the status line, not cut at (or hidden above) the list edge.
      final lead = events.last['event_id'] as String;
      final header = find.byKey(ValueKey('room-run-header-$lead'));
      expect(header, findsOneWidget);
      expect(tester.getTopLeft(header).dy, greaterThanOrEqualTo(top));
      final face = find.byKey(ValueKey('room-face-$lead'));
      expect(tester.getTopLeft(face).dy, greaterThanOrEqualTo(top));
      // And no other run header straddles the top edge.
      final headers = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('room-run-header-'),
      );
      for (final element in headers.evaluate()) {
        final box = element.renderObject! as RenderBox;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        expect(
          rect.top >= top || rect.bottom <= top,
          isTrue,
          reason: 'run header cut at the transcript top edge',
        );
      }

      // Scrolled all the way up, the first message is fully visible too.
      await tester.fling(transcript, const Offset(0, 4000), 4000);
      await tester.pumpAndSettle();
      final firstBubble = find.byKey(
        ValueKey('room-user-bubble-${events.first['event_id']}'),
      );
      expect(tester.getTopLeft(firstBubble).dy, greaterThanOrEqualTo(top));
    });

    testWidgets('#6 room list spacing equals the main chat (layout parity)', (
      tester,
    ) async {
      const md = '''
Alex: which ones are still alive:

- `feature/preview-directive`
- `fix/heavy-open` / `fix/heavy-open-validation`
- plain item one
- plain `code` item

And whether `fix/tap-targets` is still open.''';
      List<double> gaps(Finder scope) {
        final ys = [
          for (final e
              in find
                  .descendant(of: scope, matching: find.text('•'))
                  .evaluate())
            (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy,
        ];
        return [for (var i = 1; i < ys.length; i++) ys[i] - ys[i - 1]];
      }

      final seq = EventSeq();
      final u = seq.user('x');
      final m = seq.member('m-builder', 'builder', md, u['event_id'] as String);
      await _pumpRoom(tester, events: [u, m]);
      final card = find.byKey(ValueKey('room-member-card-${m['event_id']}'));
      final cardInner = tester.getSize(card).width - 24; // card padding 12+12
      final room = gaps(card);
      expect(room, hasLength(3));

      // Main chat at the same content width.
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: cardInner,
                child: const AssistantMarkdownView(data: md),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final main = gaps(find.byType(AssistantMarkdownView));
      expect(room, main);
    });

    testWidgets('#7 header faces: one overlapping cluster, four max, +n', (
      tester,
    ) async {
      final room = buildRoom(
        members: [
          memberJson('m-1', 'one'),
          memberJson('m-2', 'two'),
          memberJson('m-3', 'three'),
          memberJson('m-4', 'four'),
          memberJson('m-5', 'five'),
        ],
      );
      await _pumpRoom(tester, events: const [], room: room);
      // The old 2×2 mosaic is gone from the header.
      expect(find.byKey(const ValueKey('room-header-faces')), findsNothing);
      final cluster = find.byKey(const ValueKey('room-header-cluster'));
      final faces = [
        for (final id in ['m-1', 'm-2', 'm-3', 'm-4'])
          tester.getRect(find.byKey(ValueKey('room-header-face-$id'))),
      ];
      expect(find.byKey(const ValueKey('room-header-face-m-5')), findsNothing);
      expect(
        find.descendant(of: cluster, matching: find.text('+1')),
        findsOneWidget,
      );
      final bar = tester.getRect(find.byType(AppBar));
      for (var i = 0; i < faces.length; i++) {
        expect(faces[i].size, const Size.square(RoomFaceCluster.faceSize));
        expect(bar.contains(faces[i].topLeft), isTrue);
        expect(bar.contains(faces[i].bottomRight), isTrue);
        if (i > 0) {
          // Overlapping, in a stable left-to-right order.
          expect(faces[i].left, greaterThan(faces[i - 1].left));
          expect(faces[i].overlaps(faces[i - 1]), isTrue);
        }
      }
    });

    for (final (locale, expected) in const [
      (Locale('en'), '4 bots · round finished '),
      (Locale('es'), '4 bots · ronda terminada '),
    ]) {
      testWidgets('#8 idle finished round is ONE compact line ($locale)', (
        tester,
      ) async {
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
        await _pumpRoom(
          tester,
          events: [u, started, reply, settled],
          locale: locale,
        );
        // No panel stacked over a last-activity bar: one grey line in the
        // header.
        expect(find.byKey(const ValueKey('room-round-panel')), findsNothing);
        final line = tester.widget<Text>(
          find.byKey(const ValueKey('room-header-status')),
        );
        expect(line.data, startsWith(expected));
        expect(line.maxLines, 1);
      });
    }

    testWidgets('#8b a working round says who works, same header height', (
      tester,
    ) async {
      final seq = EventSeq();
      final u = seq.user('@builder go');
      final disc = u['event_id'] as String;
      // A current turn: without driver status the room applies the roster
      // worker freshness, so the turn must be recent at the screen clock.
      seq.at = 1790000400 - 40;
      final started = seq.started('m-builder', disc);
      await _pumpRoom(tester, events: [u, started], locale: const Locale('en'));
      expect(
        tester
            .widget<RoomHeaderBar>(find.byType(RoomHeaderBar))
            .preferredSize
            .height,
        RoomHeaderBar.expandedHeight,
      );
      // Who replies and for how long (the clock of the working turn).
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('room-header-status')))
            .data,
        startsWith('console-builder is replying · '),
      );
      expect(
        find.byKey(const ValueKey('room-header-dot-m-builder-working')),
        findsOneWidget,
      );
    });

    testWidgets('#8d a stale started turn without driver status is not '
        'shown as replying', (tester) async {
      final seq = EventSeq();
      final u = seq.user('@builder go');
      final disc = u['event_id'] as String;
      // Started ~280 s before the screen clock: past the worker freshness.
      final started = seq.started('m-builder', disc);
      await _pumpRoom(tester, events: [u, started], locale: const Locale('en'));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('room-header-status')))
            .data,
        isNot(contains('is replying')),
      );
      expect(
        find.byKey(const ValueKey('room-header-dot-m-builder-working')),
        findsNothing,
      );
    });

    testWidgets('#8c bot cards use the full width under a face header line', (
      tester,
    ) async {
      final seq = EventSeq();
      final u = seq.user('x');
      final m = seq.member(
        'm-builder',
        'builder',
        'hello',
        u['event_id'] as String,
      );
      await _pumpRoom(tester, events: [u, m]);
      final card = tester.getRect(
        find.byKey(ValueKey('room-member-card-${m['event_id']}')),
      );
      final face = tester.getRect(
        find.byKey(ValueKey('room-face-${m['event_id']}')),
      );
      // The card starts at the same left margin as the face, below it.
      expect(card.left, face.left);
      expect(card.top, greaterThanOrEqualTo(face.bottom));
    });
  });

  testWidgets('#9 profile app bar shows the Bot name once the hero scrolls', (
    tester,
  ) async {
    _phone(tester);
    const profile = AgentProfile(
      name: 'console-lead',
      description: 'Lead',
      botModeUiMeta: {'title': 'Astra'},
    );
    await tester.pumpWidget(
      _app(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 640),
            disableAnimations: true,
          ),
          child: BotProfileScreen(
            data: () => const BotProfileData(
              profile: profile,
              signal: BotFaceSignal.idle,
            ),
            machineLabel: 'homelab',
            onChat: () {},
            onRooms: () {},
            onRoutines: () {},
            onSoul: () {},
            onSkills: () {},
            onMemory: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final appBar = find.byType(AppBar);
    expect(
      find.descendant(of: appBar, matching: find.text('Profile')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: appBar, matching: find.text('Astra')),
      findsNothing,
    );
    await tester.drag(
      find.byKey(const ValueKey('bot-profile')),
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: appBar, matching: find.text('Astra')),
      findsOneWidget,
    );
    await tester.drag(
      find.byKey(const ValueKey('bot-profile')),
      const Offset(0, 400),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: appBar, matching: find.text('Profile')),
      findsOneWidget,
    );
  });
}
