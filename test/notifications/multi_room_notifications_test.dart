import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_notification_presenter.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/notifications/room_watcher.dart';
import 'package:hermes_android/core/widgets/bot_face_identity.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bots/room/room_fixtures.dart';

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

RoomLiveNotice live(String member) => RoomLiveNotice(
  working: true,
  workingMemberId: member,
  members: [(memberId: member, state: 'working')],
  round: 1,
  startedAtMs: 1000,
);

void main() {
  late Directory dir;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'app_locale': 'es'});
    dir = await Directory.systemTemp.createTemp('faces');
  });
  tearDown(() => dir.delete(recursive: true));

  group('face frames per state', () {
    test('every state renders a distinct, non-empty PNG', () async {
      final visual = BotFaceBitmapCache.visualFor('builder', 'blobatar::sun')!;
      final seen = <String>{};
      for (final state in BotFaceBitmapState.values) {
        final png = await BotFaceBitmapCache.renderPng(
          visual,
          state: state,
          size: 96,
          plate: false,
        );
        expect(png, isNotNull);
        expect(png!.sublist(1, 4), 'PNG'.codeUnits);
        expect(png.length, greaterThan(400), reason: state.name);
        seen.add(String.fromCharCodes(png));
      }
      expect(seen.length, BotFaceBitmapState.values.length);
    });

    test('expression frames rotate and differ within a state', () async {
      final visual = BotFaceBitmapCache.visualFor('scout', 'blobatar::cloud')!;
      for (final state in BotFaceBitmapState.values) {
        final count = botFaceFrameCount(state);
        final frames = <String>{};
        for (var f = 0; f < count; f++) {
          final png = await BotFaceBitmapCache.renderPng(
            visual,
            state: state,
            size: 64,
            frame: f,
          );
          frames.add(String.fromCharCodes(png!));
        }
        expect(frames.length, count, reason: state.name);
        // Frame index wraps.
        expect(
          BotFaceBitmapCache.fileKey(
            profile: 'scout',
            identityKey: null,
            state: state,
            size: 64,
            frame: count,
          ),
          BotFaceBitmapCache.fileKey(
            profile: 'scout',
            identityKey: null,
            state: state,
            size: 64,
          ),
        );
      }
    });

    test('done looks up happy, failed crosses the eyes', () {
      expect(
        botFacePose(BotFaceBitmapState.done, 0).eyeGlyph,
        HermesBotFaceEyeGlyph.happy,
      );
      expect(botFacePose(BotFaceBitmapState.done, 0).eyeOffsetY, lessThan(0));
      expect(
        botFacePose(BotFaceBitmapState.failed, 0).eyeGlyph,
        HermesBotFaceEyeGlyph.cross,
      );
      expect(botFacePose(BotFaceBitmapState.needsYou, 0).brows, greaterThan(0));
      expect(
        botFacePose(BotFaceBitmapState.working, 0).eyeOffsetX.abs(),
        greaterThan(1),
      );
    });

    test(
      'raster avatar gets the badge and a different file per state',
      () async {
        final base = await BotFaceBitmapCache.renderPng(
          BotFaceBitmapCache.visualFor('photo', null)!,
          size: 64,
        );
        // Renderer directly: the cache's 3 s timeout is a production
        // guard and makes this flaky on a loaded CI host.
        final image = Uint8List.fromList(base!);
        final idle = await BotFaceBitmapCache.renderAvatarPng(image, size: 64);
        expect(idle, isNotNull);
        final done = await BotFaceBitmapCache.renderAvatarPng(
          image,
          size: 64,
          state: BotFaceBitmapState.done,
        );
        expect(done!.length, greaterThan(200));
        expect(String.fromCharCodes(done), isNot(String.fromCharCodes(idle!)));
        String key(BotFaceBitmapState s) => BotFaceBitmapCache.fileKey(
          profile: 'p',
          identityKey: null,
          state: s,
          size: 64,
          imageDigest: 'x',
        );
        expect(
          key(BotFaceBitmapState.idle),
          isNot(key(BotFaceBitmapState.done)),
        );
      },
    );
  });

  group('conversation avatars', () {
    test(
      'room tile renders 2x2 faces and differs from a single face',
      () async {
        final visuals = [
          for (final p in ['builder', 'review', 'lead', 'scout', 'radar'])
            BotFaceIdentity.resolve(profile: p),
        ];
        final tile = await BotFaceBitmapCache.renderRoomTilePng(
          visuals,
          size: 96,
        );
        final two = await BotFaceBitmapCache.renderRoomTilePng(
          visuals.take(2).toList(),
          size: 96,
        );
        expect(tile!.sublist(1, 4), 'PNG'.codeUnits);
        expect(String.fromCharCodes(tile), isNot(String.fromCharCodes(two!)));
      },
    );

    test(
      'room cards carry the room tile as shortcut icon; Live Update too',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final sink = _Sink();
        final presenter = RichRoomNoticePresenter(
          sink: sink,
          prefs: prefs,
          faces: BotFaceBitmapCache(directory: () async => dir),
        );
        final devs = namedRoom('r-devs', 'Devs', ['builder', 'review']);
        await presenter.present('c1', devs, [
          live('m-builder-r-devs'),
          RoomApprovalNotice(
            driver(
              pending: [
                approvalAction(member: 'm-builder-r-devs', request: 'apr-9'),
              ],
            ).approvals.single,
          ),
        ]);
        final card = sink.posts.single;
        expect(card['shortcutIconPath'] as String, contains('tile_'));
        final msg = (card['messages'] as List).single as Map;
        expect(msg['iconPath'] as String, contains('needsYou'));
        expect(sink.live.single['largeIconPath'] as String, contains('tile_'));
        expect(
          sink.live.single['trackerIconPath'] as String,
          contains('working'),
        );
      },
    );

    test(
      'round card: every line has a face, the verdict is the header',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final sink = _Sink();
        final presenter = RichRoomNoticePresenter(
          sink: sink,
          prefs: prefs,
          faces: BotFaceBitmapCache(directory: () async => dir),
        );
        final qa = namedRoom('r-qa', 'Release checks', ['radar', 'atlas']);
        await presenter.present('c1', qa, [
          RoomRoundFinishedNotice(
            const ['m-radar-r-qa', 'm-atlas-r-qa'],
            9,
            lastMemberId: 'm-atlas-r-qa',
            replies: const [
              RoomRoundReply(
                memberId: 'm-radar-r-qa',
                text: 'versos',
                timeMs: 1,
                eventId: 'e1',
              ),
            ],
          ),
        ]);
        final card = sink.posts.single;
        expect(card['shortcutIconPath'] as String, contains('tile_'));
        for (final m in (card['messages'] as List).cast<Map>()) {
          expect(m['iconPath'], isA<String>(), reason: '${m['senderName']}');
        }
        // No fake "Release checks" sender: the verdict is the subText.
        for (final m in (card['messages'] as List).cast<Map>()) {
          expect(m['senderName'], isNot('Release checks'));
        }
        expect(card['subText'], 'Ronda terminada · Radar y Atlas respondieron');
      },
    );

    test(
      'Live Update names the addressed Bot and a segment per member',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final sink = _Sink();
        final presenter = RichRoomNoticePresenter(
          sink: sink,
          prefs: prefs,
          faces: BotFaceBitmapCache(directory: () async => dir),
        );
        final qa = HostedGroupRoom.fromJson({
          'room_id': 'r-qa',
          'name': 'Release checks',
          'members': [
            memberJson(
              'm-radar',
              'console-radar',
              displayName: 'console-radar',
            ),
            memberJson('m-atlas', 'atlas'),
          ],
          'authority_gateway_id': gatewayId,
          'authority_epoch': 2,
          'revision': 1,
          'created_at': 1790000000.0,
          'updated_at': 1790000500.0,
          'latest_seq': 3,
        });
        // Round opened by the user; no turn.started in the log yet.
        await presenter.present('c1', qa, [
          const RoomLiveNotice(
            working: true,
            startedAtMs: 1000,
            addressedHandles: ['console-radar', 'atlas'],
          ),
        ]);
        final first = sink.live.single;
        expect(first['text'], 'Radar está pensando… · Atlas en espera');
        expect([for (final r in first['rows']! as List) (r as Map)['state']], [
          'working',
          'pending',
        ]);
        expect(first['largeIconPath'] as String, contains('tile_'));
        expect(first['trackerIconPath'] as String, contains('working'));
        expect(first['shortText'], 'Radar');
        // Radar replied, Atlas's turn started.
        await presenter.present('c1', qa, [
          const RoomLiveNotice(
            working: true,
            workingMemberId: 'm-atlas',
            members: [
              (memberId: 'm-radar', state: 'done'),
              (memberId: 'm-atlas', state: 'working'),
            ],
            startedAtMs: 1000,
            addressedHandles: ['console-radar', 'atlas'],
          ),
        ]);
        final second = sink.live.last;
        expect(second['text'], 'Atlas está trabajando… · Radar respondió');
        expect([for (final r in second['rows']! as List) (r as Map)['state']], [
          'done',
          'working',
        ]);
        // Nobody addressed nor started: the room works, one row each.
        await presenter.present('c1', qa, [
          const RoomLiveNotice(working: true, startedAtMs: 1000),
        ]);
        expect(
          sink.live.last['text'] as String,
          startsWith('La sala está trabajando…'),
        );
        expect(sink.live.last['rows'], hasLength(2));
        expect(sink.live.last['trackerIconPath'] as String, contains('tile_'));
      },
    );

    test('bot routine result is a message from that bot', () async {
      final prefs = await SharedPreferences.getInstance();
      final sink = _Sink();
      await BotChatRichNotifications(
        sink: sink,
        faces: BotFaceBitmapCache(directory: () async => dir),
      ).routineResult(
        t: NotifL10n.of(prefs),
        connId: 'c1',
        profile: 'scout',
        botName: 'Scout',
        sessionId: 's1',
        routineTitle: 'Resumen diario',
        ok: true,
        summary: '**3** novedades',
      );
      final card = sink.posts.single;
      expect(card['title'], 'Scout');
      expect(card['isGroup'], isFalse);
      expect(card['accent'], RichAccent.done);
      final msg = (card['messages'] as List).single as Map;
      expect(msg['senderName'], 'Scout');
      expect(msg['text'], 'Terminó «Resumen diario» · 3 novedades');
      expect(msg['iconPath'] as String, contains('_done_'));
    });
  });

  group('Spanish device: no English templates', () {
    const english = [
      'needs you',
      'working…',
      'Working…',
      ' replied',
      'Needs your OK',
      'Round done',
      'is working',
      'Stop all',
      'rooms working',
      'New activity',
      "couldn’t finish",
      'Approve',
      'Deny',
    ];

    test('notification payloads in ES', () async {
      final prefs = await SharedPreferences.getInstance();
      final sink = _Sink();
      final presenter = RichRoomNoticePresenter(
        sink: sink,
        prefs: prefs,
        faces: BotFaceBitmapCache(directory: () async => dir),
      );
      final rooms = [
        namedRoom('r1', 'Devs', ['builder']),
        namedRoom('r2', 'Atlas', ['lead']),
        namedRoom('r3', 'Research', ['scout']),
      ];
      for (final r in rooms) {
        await presenter.present('c1', r, [
          live('m-${r.members.first.handle}-${r.roomId}'),
          RoomApprovalNotice(
            driver(
              pending: [
                approvalAction(
                  member: 'm-${r.members.first.handle}-${r.roomId}',
                  request: 'apr-${r.roomId}',
                ),
              ],
            ).approvals.single,
          ),
        ]);
      }
      await presenter.present('c1', rooms.first, [
        RoomRoundFinishedNotice(
          ['m-builder-r1'],
          4,
          lastMemberId: 'm-builder-r1',
        ),
      ]);
      final text = [...sink.posts, ...sink.live].toString();
      for (final phrase in english) {
        expect(text, isNot(contains(phrase)), reason: phrase);
      }
      expect(text, contains('Necesita tu OK'));
      expect(text, contains('3 salas trabajando'));
      expect(text, contains('Parar ronda'));
      expect(text, contains('Abrir sala'));
    });

    test('Android widget strings: every key localized in ES', () {
      Map<String, String> strings(String locale) => {
        for (final m
            in RegExp(r'<string name="([^"]+)">([^<]*)</string>').allMatches(
              File(
                'android/app/src/main/res/$locale/bot_mode_widgets.xml',
              ).readAsStringSync(),
            ))
          m.group(1)!: m.group(2)!,
      };
      final en = strings('values');
      final es = strings('values-es');
      expect(es.keys.toSet(), en.keys.toSet());
      for (final phrase in english) {
        for (final entry in es.entries) {
          expect(
            entry.value,
            isNot(contains(phrase)),
            reason: '${entry.key}: ${entry.value}',
          );
        }
      }
      // Widget-side templates that used to leak English from Dart.
      expect(es['botw_step_replied'], '%1\$s respondió');
      expect(es['botw_step_working'], '%1\$s trabajando…');
      expect(es['botw_step_needs_you'], '%1\$s te necesita');
      // The widget builds the room ticker from these resources, not from
      // the published (Dart) strings.
      final glance = File(
        'android/app/src/main/kotlin/com/hermesagent/hermes_android/HermesBotModeWidgets.kt',
      ).readAsStringSync();
      expect(glance, contains('R.string.botw_step_replied'));
      expect(glance, isNot(contains('room.steps.')));
      expect(glance, isNot(contains('room.steps)')));
    });
  });

  group('multi-room notifications', () {
    test('one conversation per room and per bot, never merged', () async {
      final prefs = await SharedPreferences.getInstance();
      final sink = _Sink();
      final presenter = RichRoomNoticePresenter(
        sink: sink,
        prefs: prefs,
        faces: BotFaceBitmapCache(directory: () async => dir),
      );
      final devs = namedRoom('r-devs', 'Devs', ['builder', 'review']);
      final ops = namedRoom('r-ops', 'Atlas', ['lead']);
      for (final (room, member) in [
        (devs, 'm-builder-r-devs'),
        (ops, 'm-lead-r-ops'),
      ]) {
        await presenter.present('c1', room, [
          RoomMemberFailedNotice(
            HostedGroupEvent.fromJson({
              'room_id': room.roomId,
              'seq': 5,
              'event_id': 'f-$member',
              'kind': 'turn.failed',
              'actor': {'kind': 'gateway', 'id': gatewayId},
              'authority_epoch': 2,
              'payload': {
                'member_id': member,
                'task_id': 't',
                'turn_id': 'u',
                'round_index': 0,
                'member_index': 0,
                'thread_id': 'thread-1',
                'discussion_event_id': 'd',
              },
              'created_at': 1790000200.0,
              'idempotent': false,
            }, roomId: room.roomId),
          ),
        ]);
      }
      final bots = BotChatRichNotifications(
        sink: sink,
        faces: BotFaceBitmapCache(directory: () async => dir),
      );
      for (final p in ['builder', 'scout']) {
        await bots.replyReady(
          t: NotifL10n.of(prefs),
          connId: 'c1',
          profile: p,
          botName: p,
          sessionId: 's-$p',
          preview: 'Hecho',
        );
      }
      expect(sink.posts, hasLength(4));
      final tags = {for (final p in sink.posts) p['tag']};
      final convs = {for (final p in sink.posts) p['conversationId']};
      final groups = {for (final p in sink.posts) p['groupKey']};
      expect(tags.length, 4);
      expect(convs.length, 4);
      expect(groups.length, 4);
      // Room card: title = room name; sender = the member bot with its face.
      final roomCard = sink.posts.first;
      expect(roomCard['title'], 'Devs');
      final msg = (roomCard['messages'] as List).single as Map;
      expect(msg['senderName'], 'Builder');
      expect(msg['iconPath'], isNotNull);
      expect(roomCard['accent'], RichAccent.failed);
      // Bot completion: done face + green accent.
      expect(sink.posts.last['accent'], RichAccent.done);
      expect(sink.posts.last['summaryLabel'], 'avisos');
    });

    test('max two room Live Updates; the rest share one summary', () async {
      final prefs = await SharedPreferences.getInstance();
      final sink = _Sink();
      final presenter = RichRoomNoticePresenter(
        sink: sink,
        prefs: prefs,
        faces: BotFaceBitmapCache(directory: () async => dir),
      );
      final rooms = [
        namedRoom('r1', 'Devs', ['builder']),
        namedRoom('r2', 'Atlas', ['lead']),
        namedRoom('r3', 'Research', ['scout']),
      ];
      for (final r in rooms) {
        await presenter.present('c1', r, [
          live('m-${r.members.first.handle}-${r.roomId}'),
        ]);
      }
      final roomCards = sink.live.where((a) => a['promote'] != false).toList();
      expect(roomCards.map((a) => a['title']), ['Devs', 'Atlas']);
      // Each room's Stop acts on THAT room only.
      for (final (i, card) in roomCards.indexed) {
        final stop = NotificationActionPayload.tryParse(
          card['actionPayload'] as String,
        )!;
        expect(stop.roomId, rooms[i].roomId);
        expect(card['trackerIconPath'], isNotNull);
      }
      final summary = sink.live.last;
      expect(summary['promote'], isFalse);
      expect(summary['tag'], RichNotificationBuilder.liveSummaryTag);
      expect(summary['title'], '3 salas trabajando');
      expect(summary['text'], 'Devs · Atlas · Research');
      expect(summary['actionPayload'], isNull, reason: 'no Stop all');
      expect(presenter.overflowRooms.values, ['Research']);

      // Devs finishes: Research is promoted to its own card, summary gone.
      await presenter.present('c1', rooms[0], [
        const RoomLiveNotice(working: false, members: []),
      ]);
      await presenter.present('c1', rooms[2], [live('m-scout-r3')]);
      expect(sink.live.last['title'], 'Research');
      expect(sink.live.last['promote'], isNot(false));
      expect(presenter.overflowRooms, isEmpty);
      expect(sink.cancelTags, contains(RichNotificationBuilder.liveSummaryTag));
    });

    test('approve from one room can never hit another room', () async {
      final prefs = await SharedPreferences.getInstance();
      final sink = _Sink();
      final presenter = RichRoomNoticePresenter(
        sink: sink,
        prefs: prefs,
        faces: BotFaceBitmapCache(directory: () async => dir),
      );
      final devs = namedRoom('r-devs', 'Devs', ['builder']);
      final ops = namedRoom('r-ops', 'Atlas', ['lead']);
      final a = driver(
        pending: [approvalAction(member: 'm-builder-r-devs', request: 'apr-1')],
      ).approvals.single;
      final b = driver(
        pending: [approvalAction(member: 'm-lead-r-ops', request: 'apr-2')],
      ).approvals.single;
      await presenter.present('c1', devs, [RoomApprovalNotice(a)]);
      await presenter.present('c1', ops, [RoomApprovalNotice(b)]);
      final gatewayOps = _Ops();
      final router = NotificationActionRouter(
        ops: gatewayOps,
        sink: sink,
        t: NotifL10n.of(prefs),
      );
      for (final card in sink.posts) {
        expect(card['accent'], RichAccent.needsYou);
        await router.handle(
          PendingNotificationAction(
            uid: 'u-${card['id']}',
            action: 'approve',
            payload: NotificationActionPayload.tryParse(
              card['actionPayload'] as String,
            )!,
            notificationId: card['id'] as int,
            tag: card['tag'] as String,
          ),
        );
      }
      expect(gatewayOps.approved, [
        ('r-devs', 'm-builder-r-devs', 'apr-1'),
        ('r-ops', 'm-lead-r-ops', 'apr-2'),
      ]);
      expect(sink.posts[0]['tag'], isNot(sink.posts[1]['tag']));
      final sender0 = (sink.posts[0]['messages'] as List).single as Map;
      expect(sender0['senderName'], 'Builder');
      expect(sink.posts[0]['title'], 'Devs');
    });
  });
}

final class _Ops implements NotificationActionOps {
  final approved = <(String?, String?, String?)>[];
  @override
  Future<void> roomApprove(NotificationActionPayload p, String choice) async =>
      approved.add((p.roomId, p.memberId, p.requestId));
  @override
  Future<void> roomStop(NotificationActionPayload p) async {}
  @override
  Future<void> roomSend(
    NotificationActionPayload p,
    String text,
    String id,
  ) async {}
  @override
  Future<void> runApprove(NotificationActionPayload p, String choice) async {}
  @override
  Future<void> chatApprove(NotificationActionPayload p, String choice) async {}
  @override
  Future<void> botChatReply(
    NotificationActionPayload p,
    String text,
    String id,
  ) async {}
  @override
  Future<void> cronTrigger(NotificationActionPayload p) async {}
}

final class _Sink implements RichNotificationSink {
  final posts = <Map<String, Object?>>[];
  final live = <Map<String, Object?>>[];
  final cancelTags = <String?>[];
  @override
  Future<void> cancel({required int id, String? tag}) async =>
      cancelTags.add(tag);
  @override
  Future<void> confirm({
    required int id,
    String? tag,
    String? title,
    required String text,
    int timeoutMs = 4000,
    bool onlyIfActive = false,
  }) async {}
  @override
  Future<bool> postConversation(Map<String, Object?> args) async {
    posts.add(args);
    return true;
  }

  @override
  Future<void> postLiveUpdate(Map<String, Object?> args) async =>
      live.add(args);
}
