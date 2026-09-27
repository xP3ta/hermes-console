import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_mode_widget_snapshot.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/bot_widget_activity.dart';
import 'package:hermes_android/core/services/notifications/bot_mode_background.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/notifications/room_watcher.dart';

import '../bots/room/room_fixtures.dart';

SavedConnection conn(String id) => SavedConnection.fromMap({
  'id': id,
  'label': 'Home $id',
  'host': '192.168.1.20',
  'port': 8642,
  'apiKey': '',
  'useHttps': false,
});

WidgetBot bot(
  String profile,
  WidgetBotState state, {
  String? line,
  String? roomId,
  String? roomName,
  bool pinned = false,
}) => WidgetBot(
  profile: profile,
  name: profile,
  state: state,
  line: line,
  roomId: roomId,
  roomName: roomName,
  pinned: pinned,
  openPayload: NotificationOpen(
    connId: 'c1',
    sessionId: profile,
    profile: profile,
    surface: NotificationChatSurface.bot,
  ).toPayload(),
);

WidgetRoom room(String id, String phase, {String name = 'Room'}) => WidgetRoom(
  roomId: id,
  name: name,
  working: phase == 'working',
  members: const [],
  phase: phase,
  openPayload: NotificationOpen(
    connId: 'c1',
    sessionId: id,
    roomId: id,
    surface: NotificationChatSurface.room,
  ).toPayload(),
);

BotModeWidgetSnapshot snap({
  List<WidgetBot> bots = const [],
  List<WidgetRoom> rooms = const [],
  String conn = 'c1',
}) => BotModeWidgetSnapshot(
  connectionId: conn,
  connectionLabel: 'Home',
  connected: true,
  bots: bots,
  approvals: const [],
  rooms: rooms,
  updatedAtMs: 0,
);

HostedGroupRoom namedRoom(String id, String name, List<String> handles) =>
    HostedGroupRoom.fromJson({
      'room_id': id,
      'name': name,
      'members': [
        for (final h in handles) memberJson('m-$h-$id', h, displayName: h),
      ],
      'authority_gateway_id': gatewayId,
      'authority_epoch': 2,
      'revision': 1,
      'created_at': 1790000000.0,
      'updated_at': 1790000500.0,
      'latest_seq': 3,
    });

void main() {
  final t0 = DateTime.utc(2026, 9, 26, 10);

  group('ticker', () {
    test('ticker steps are shortened on whole words, never mid-word', () {
      expect(
        shortenWidgetStep('Arreglar la redirección del login tras el OAuth'),
        'Arreglar la redirección',
      );
      expect(shortenWidgetStep('Run the auth suite now'), 'Run the auth suite');
      expect(shortenWidgetStep('  Leer   el test… '), 'Leer el test');
      // Never ends on a connector.
      expect(shortenWidgetStep('Subir la build de la app'), 'Subir la build');
      // A single long word is kept whole (the widget ellipsizes it).
      expect(
        shortenWidgetStep('Supercalifragilisticexpialidocious test'),
        'Supercalifragilisticexpialidocious',
      );
      for (final raw in [
        'Comparar Glance y RemoteViews en el Pixel',
        'Preparar el entorno de trabajo',
      ]) {
        final short = shortenWidgetStep(raw);
        expect(raw.startsWith(short), isTrue);
        final next = raw.length > short.length ? raw[short.length] : ' ';
        expect(next, ' ', reason: 'cut mid-word: $short');
        expect(short.split(' ').length, lessThanOrEqualTo(4));
      }
      expect(appendStep(const [], 'Arreglar la redirección del login'), [
        'Arreglar la redirección',
      ]);
    });

    test('appends distinct steps, oldest first, max three', () {
      var steps = <String>[];
      for (final s in ['a', 'a', 'b', 'c', 'd']) {
        steps = appendStep(steps, s);
      }
      expect(steps, ['b', 'c', 'd']);
      expect(appendStep(steps, '  '), same(steps));
      // A step seen before moves to the end instead of duplicating.
      expect(appendStep(['a', 'b', 'c'], 'a'), ['b', 'c', 'a']);
    });

    test('tracker accumulates steps across ticks while working', () async {
      final tracker = BotWidgetActivityTracker(MemoryBotWidgetActivityStore());
      for (final (i, step) in ['Plan', 'Edit', 'Test', 'Ship'].indexed) {
        final out = await tracker.apply(
          snap(bots: [bot('builder', WidgetBotState.working, line: step)]),
          now: t0.add(Duration(minutes: i)),
        );
        expect(out.bots.single.steps.last, step);
      }
      final store = tracker.store.load();
      expect(store.entries['bot:builder']!.steps, ['Edit', 'Test', 'Ship']);
    });
  });

  group('2x2 state selection and outcomes', () {
    test('working → done for ten minutes → idle (stale expiry)', () async {
      final tracker = BotWidgetActivityTracker(MemoryBotWidgetActivityStore());
      await tracker.apply(
        snap(bots: [bot('builder', WidgetBotState.working, line: 'Fix login')]),
        now: t0,
      );
      final done = await tracker.apply(
        snap(bots: [bot('builder', WidgetBotState.idle)]),
        now: t0.add(const Duration(minutes: 1)),
      );
      expect(done.bots.single.state, WidgetBotState.done);
      expect(done.hero, const WidgetActiveRef.bot('builder'));
      expect(done.bots.single.steps, ['Fix login']);
      final still = await tracker.apply(
        snap(bots: [bot('builder', WidgetBotState.idle)]),
        now: t0.add(const Duration(minutes: 10)),
      );
      expect(still.bots.single.state, WidgetBotState.done);
      final gone = await tracker.apply(
        snap(bots: [bot('builder', WidgetBotState.idle)]),
        now: t0.add(const Duration(minutes: 12)),
      );
      expect(gone.bots.single.state, WidgetBotState.idle);
      expect(gone.hero, isNull, reason: 'nothing active → overview grid');
      expect(gone.active, isEmpty);
    });

    test('a blocked room turns its working Bot into failed', () async {
      final tracker = BotWidgetActivityTracker(MemoryBotWidgetActivityStore());
      await tracker.apply(
        snap(
          bots: [
            bot(
              'builder',
              WidgetBotState.working,
              roomId: 'r1',
              roomName: 'Devs',
            ),
          ],
        ),
        now: t0,
      );
      final out = await tracker.apply(
        snap(bots: [bot('builder', WidgetBotState.idle)]),
        now: t0.add(const Duration(minutes: 1)),
        roomFailed: {'r1'},
      );
      expect(out.bots.single.state, WidgetBotState.failed);
      expect(out.bots.single.roomName, 'Devs');
    });

    test('outcomes never cross connections', () async {
      final store = MemoryBotWidgetActivityStore();
      final tracker = BotWidgetActivityTracker(store);
      await tracker.apply(
        snap(bots: [bot('builder', WidgetBotState.working)], conn: 'a'),
        now: t0,
      );
      final other = await tracker.apply(
        snap(bots: [bot('builder', WidgetBotState.idle)], conn: 'b'),
        now: t0.add(const Duration(minutes: 1)),
      );
      expect(other.bots.single.state, WidgetBotState.idle);
    });

    test('priority: needs you > failed > working > done', () {
      final bots = [
        bot('d', WidgetBotState.done),
        bot('w', WidgetBotState.working),
        bot('f', WidgetBotState.failed),
        bot('n', WidgetBotState.needsYou),
        bot('i', WidgetBotState.idle),
      ];
      final order = BotWidgetActivityTracker.orderActive(bots: bots, rooms: []);
      expect(order.map((r) => r.id), ['n', 'f', 'w', 'd']);
    });
  });

  group('multi-room / multi-bot', () {
    test(
      'two rooms + three bots: hero by priority, +N, round-robin, pin',
      () async {
        // Scout works alone; builder works in Devs; lead waits in Ops.
        final bots = [
          bot('scout', WidgetBotState.working, line: 'Research'),
          bot(
            'builder',
            WidgetBotState.working,
            roomId: 'r-devs',
            roomName: 'Devs',
          ),
          bot(
            'lead',
            WidgetBotState.needsYou,
            roomId: 'r-ops',
            roomName: 'Ops',
          ),
        ];
        final rooms = [
          room('r-ops', 'needs_you', name: 'Ops'),
          room('r-devs', 'working', name: 'Devs'),
        ];
        final tracker = BotWidgetActivityTracker(
          MemoryBotWidgetActivityStore(),
        );
        final a = await tracker.apply(
          snap(bots: bots, rooms: rooms),
          now: t0,
        );
        // Bots inside an active room are represented by the room row.
        expect(a.active, const [
          WidgetActiveRef.room('r-ops'),
          WidgetActiveRef.room('r-devs'),
          WidgetActiveRef.bot('scout'),
        ]);
        expect(a.hero, const WidgetActiveRef.room('r-ops'));
        expect(a.othersCount, 2);

        // Two items in the top tier rotate on each update.
        final tied = [
          bot('scout', WidgetBotState.working),
          bot(
            'builder',
            WidgetBotState.working,
            roomId: 'r-devs',
            roomName: 'Devs',
          ),
        ];
        final heroes = <WidgetActiveRef?>{};
        for (var i = 1; i <= 2; i++) {
          final s = await tracker.apply(
            snap(
              bots: tied,
              rooms: [room('r-devs', 'working', name: 'Devs')],
            ),
            now: t0.add(Duration(minutes: i)),
          );
          heroes.add(s.hero);
          expect(s.othersCount, 1);
        }
        expect(heroes, {
          const WidgetActiveRef.bot('scout'),
          const WidgetActiveRef.room('r-devs'),
        });

        // A pinned Bot in the top tier stops the rotation.
        final pinned = [
          bot('scout', WidgetBotState.working, pinned: true),
          bot('other', WidgetBotState.working),
        ];
        for (var i = 3; i <= 5; i++) {
          final s = await tracker.apply(
            snap(bots: pinned),
            now: t0.add(Duration(minutes: i)),
          );
          expect(s.hero, const WidgetActiveRef.bot('scout'));
        }
      },
    );

    test('snapshot from real room views: rooms, bot→room, deep links', () {
      final devs = namedRoom('r-devs', 'Design Review', [
        'builder',
        'review',
      ]);
      final ops = namedRoom('r-ops', 'Atlas', ['lead', 'scout']);
      final profiles = [
        for (final p in ['builder', 'review', 'lead', 'scout', 'solo'])
          AgentProfile.fromJson({'name': p, 'display_name': p}),
      ];
      final snapshot = buildBotModeWidgetSnapshot(
        connection: conn('c1'),
        connected: true,
        profiles: profiles,
        liveSessions: const <DesktopActiveSession>[],
        rooms: [
          RoomWatchView(
            room: devs,
            driverStatus: driver(working: true),
            state: const RoomWatchState(
              working: true,
              openMembers: {'m-builder-r-devs'},
              repliers: ['m-review-r-devs'],
            ),
          ),
          RoomWatchView(
            room: ops,
            driverStatus: driver(
              pending: [
                approvalAction(member: 'm-lead-r-ops', request: 'apr-ops'),
              ],
            ),
            state: const RoomWatchState(),
          ),
        ],
        facePaths: const {},
        t: const NotifL10n(true),
        now: t0,
      );
      expect(snapshot.rooms.map((r) => r.roomId), ['r-ops', 'r-devs']);
      expect(snapshot.roomOf('r-ops')!.phase, 'needs_you');
      expect(snapshot.roomOf('r-devs')!.phase, 'working');
      expect(snapshot.roomOf('r-devs')!.steps, [
        'Review respondió',
        'Builder trabajando…',
      ]);
      final builder = snapshot.botOf('builder')!;
      expect(builder.state, WidgetBotState.working);
      expect(builder.roomName, 'Design Review');
      expect(snapshot.botOf('lead')!.roomId, 'r-ops');
      expect(snapshot.botOf('solo')!.roomId, isNull);
      // Every tap opens the exact Bot / room.
      final roomOpen = NotificationOpen.tryParse(
        snapshot.roomOf('r-devs')!.openPayload,
      )!;
      expect(roomOpen.roomId, 'r-devs');
      expect(roomOpen.surface, NotificationChatSurface.room);
      final botOpen = NotificationOpen.tryParse(builder.openPayload)!;
      expect(botOpen.profile, 'builder');
      expect(botOpen.surface, NotificationChatSurface.bot);
      // Approvals carry room + member + request identity.
      final approval = NotificationActionPayload.tryParse(
        snapshot.approvals.single.actionPayload,
      )!;
      expect(approval.roomId, 'r-ops');
      expect(approval.memberId, 'm-lead-r-ops');
      expect(approval.requestId, 'apr-ops');
      expect(snapshot.approvals.single.title, 'Lead · Atlas');
      final json = jsonDecode(snapshot.encode()) as Map;
      expect((json['rooms'] as List).length, 2);
    });
  });

  group('privacy of steps', () {
    test('steps come from titles, never previews; hidden when sensitive', () {
      final profile = AgentProfile.fromJson({
        'name': 'builder',
        'worker_session': {
          'id': 'w1',
          'source': 'kanban',
          'title': '**Fix** the `login` redirect',
          'last_active': t0.millisecondsSinceEpoch / 1000,
        },
      });
      expect(
        botPublicStep(profile: profile, liveSessions: const [], now: t0),
        'Fix the login redirect',
      );
      expect(
        botPublicStep(
          profile: profile,
          liveSessions: const [],
          now: t0,
          hideSensitive: true,
        ),
        isNull,
      );
      final live = DesktopActiveSession.tryParse({
        'id': 'rt-1',
        'session_key': 's1',
        'status': 'working',
        'title': 'Deploy docs',
        'preview': 'rm -rf /secret/path --token=abc',
      })!;
      final withSession = AgentProfile.fromJson({
        'name': 'scout',
        'last_session': {'id': 's1'},
      });
      final step = botPublicStep(
        profile: withSession,
        liveSessions: [live],
        now: t0,
      );
      expect(step, 'Deploy docs');
      final snapshot = buildBotModeWidgetSnapshot(
        connection: conn('c1'),
        connected: true,
        profiles: [withSession],
        liveSessions: [live],
        rooms: const [],
        facePaths: const {},
        t: const NotifL10n(false),
        now: t0,
      );
      final encoded = snapshot.encode();
      expect(encoded, isNot(contains('secret')));
      expect(encoded, isNot(contains('token')));
    });
  });
}
