import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_notification_presenter.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/notifications/room_watcher.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bots/room/room_fixtures.dart';

void main() {
  late Directory dir;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'app_locale': 'en'});
    dir = await Directory.systemTemp.createTemp('faces');
  });
  tearDown(() => dir.delete(recursive: true));

  test('face bitmap renders a PNG once and reuses the file', () async {
    final cache = BotFaceBitmapCache(directory: () async => dir);
    final a = await cache.pathFor(profile: 'builder', state: BotFaceBitmapState.working);
    expect(a, isNotNull);
    final bytes = await File(a!).readAsBytes();
    expect(bytes.sublist(1, 4), 'PNG'.codeUnits);
    final b = await cache.pathFor(profile: 'builder', state: BotFaceBitmapState.working);
    expect(b, a);
    final idle = await cache.pathFor(profile: 'builder');
    expect(idle, isNot(a));
  });

  test('renderPng works without a widget tree', () async {
    final visual = HermesBlobatarFaceVisual.tryParse(
      shapeWire: 'blobatar',
      profileName: 'x',
    )!;
    final png = await BotFaceBitmapCache.renderPng(visual, size: 64);
    expect(png, isNotNull);
    expect(png!.length, greaterThan(100));
  });

  test('room presenter: group conversation with member faces and reply', () async {
    final prefs = await SharedPreferences.getInstance();
    final sink = _Sink();
    final presenter = RichRoomNoticePresenter(
      sink: sink,
      prefs: prefs,
      faces: BotFaceBitmapCache(directory: () async => dir),
    );
    final seq = EventSeq();
    final mention = buildLog([
      seq.member('m-builder', 'builder', '**Done**. @user please merge', 'd1'),
    ]).events.single;
    await presenter.present('c1', buildRoom(), [
      RoomApprovalNotice(driver(pending: [approvalAction()]).approvals.single),
      RoomMentionNotice(mention),
      const RoomLiveNotice(
        working: true,
        members: [(memberId: 'm-builder', state: 'working')],
        workingMemberId: 'm-builder',
        startedAtMs: 5,
      ),
    ]);
    final approval = sink.posts.firstWhere((p) => p['channel'] == 'approvals');
    expect(approval['title'], 'Console Devs');
    expect(approval['text'], 'Needs your OK to run “gh pr ready 51”');
    final action = NotificationActionPayload.tryParse(approval['actionPayload'] as String)!;
    expect(action.isRoomApproval, isTrue);
    final conv = sink.posts.firstWhere((p) => p['channel'] == 'conversations');
    expect(conv['isGroup'], isTrue);
    final message = (conv['messages'] as List).single as Map;
    expect(message['senderName'], 'Builder');
    expect(message['text'], 'Done. @user please merge');
    expect(message['iconPath'], isNotNull);
    expect(conv['alert'], isTrue);
    expect(sink.live.single['text'], 'Builder is working…');
    expect(sink.live.single['trackerIconPath'], isNotNull);
  });

  test('round finished ends the live update and posts an alerting summary', () async {
    final prefs = await SharedPreferences.getInstance();
    final sink = _Sink();
    await RichRoomNoticePresenter(
      sink: sink,
      prefs: prefs,
      faces: BotFaceBitmapCache(directory: () async => dir),
    ).present('c1', buildRoom(), [
      const RoomRoundFinishedNotice(['m-builder', 'm-review'], 9, lastMemberId: 'm-review'),
    ]);
    expect(sink.cancels, [RichNotificationIds.live]);
    final conv = sink.posts.single;
    // A finished round is news: it must reach the shade.
    expect(conv['alert'], isTrue);
    final only = (conv['messages'] as List).single as Map;
    // Without reply lines the last Bot speaks the verdict (not the room).
    expect(only['senderName'], 'Review');
    expect(only['text'], 'Round done · Builder and Review replied');
  });

  test('round finished lists each Bot reply as its own line', () async {
    final prefs = await SharedPreferences.getInstance();
    final sink = _Sink();
    await RichRoomNoticePresenter(
      sink: sink,
      prefs: prefs,
      faces: BotFaceBitmapCache(directory: () async => dir),
    ).present('c1', buildRoom(), [
      RoomRoundFinishedNotice(
        const ['m-radar', 'm-builder'],
        6,
        lastMemberId: 'm-builder',
        discussionId: 'user:d1',
        replies: [
          const RoomRoundReply(
            memberId: 'm-radar',
            text: '**Teide** verses\nline two',
            timeMs: 1,
            eventId: 'e1',
          ),
          RoomRoundReply(
            memberId: 'm-builder',
            text: 'x' * 400,
            timeMs: 2,
            eventId: 'e2',
          ),
        ],
      ),
    ]);
    final messages = (sink.posts.single['messages'] as List).cast<Map>();
    expect(messages.map((m) => m['senderName']), ['Radar', 'Builder']);
    expect(messages[0]['text'], 'Teide verses line two');
    expect((messages[1]['text'] as String).length, lessThanOrEqualTo(240));
    expect((messages[1]['text'] as String).endsWith('…'), isTrue);
    expect(sink.posts.single['subText'], 'Round done · Radar and Builder replied');
    expect(sink.posts.single['alert'], isTrue);
  });

  group('round-finished card across consecutive rounds', () {
    RoomRoundFinishedNotice round(String discussion, int seq) =>
        RoomRoundFinishedNotice(
          const ['m-radar', 'm-builder'],
          seq,
          lastMemberId: 'm-builder',
          discussionId: discussion,
          replies: [
            RoomRoundReply(
              memberId: 'm-radar',
              text: 'verses $discussion',
              timeMs: 1,
              eventId: 'r-$discussion',
            ),
            RoomRoundReply(
              memberId: 'm-builder',
              text: 'summary $discussion',
              timeMs: 2,
              eventId: 'b-$discussion',
            ),
          ],
        );

    test('every new round re-alerts (never a silent same-id update)', () async {
      final prefs = await SharedPreferences.getInstance();
      final sink = _Sink();
      final presenter = RichRoomNoticePresenter(
        sink: sink,
        prefs: prefs,
        faces: BotFaceBitmapCache(directory: () async => dir),
      );
      await presenter.present('c1', buildRoom(), [round('user:d1', 6)]);
      await presenter.present('c1', buildRoom(), [round('user:d2', 12)]);
      expect(sink.posts, hasLength(2));
      for (final card in sink.posts) {
        // A new discussion must reach the shade even when the previous
        // round's card (same tag + id) was already seen or dismissed.
        expect(card['alert'], isTrue);
        expect(card['onlyAlertOnce'], isNot(true));
        expect(card['id'], RichNotificationIds.conversation);
      }
      expect(sink.posts[0]['alertKey'], isNot(sink.posts[1]['alertKey']));
    });

    test('same discussion re-presented does not re-sound', () async {
      final prefs = await SharedPreferences.getInstance();
      final sink = _Sink();
      final presenter = RichRoomNoticePresenter(
        sink: sink,
        prefs: prefs,
        faces: BotFaceBitmapCache(directory: () async => dir),
      );
      await presenter.present('c1', buildRoom(), [round('user:d1', 6)]);
      await presenter.present('c1', buildRoom(), [round('user:d1', 6)]);
      expect(sink.posts[0]['alertKey'], sink.posts[1]['alertKey']);
    });

    test('Live Update withdraw never targets the conversation card', () async {
      final prefs = await SharedPreferences.getInstance();
      final sink = _Sink();
      final presenter = RichRoomNoticePresenter(
        sink: sink,
        prefs: prefs,
        faces: BotFaceBitmapCache(directory: () async => dir),
      );
      await presenter.present('c1', buildRoom(), [round('user:d1', 6)]);
      await presenter.cancelAllLive();
      expect(sink.cancels, everyElement(RichNotificationIds.live));
      expect(sink.cancels, isNot(contains(RichNotificationIds.conversation)));
    });

    test('group card: room title once, Bots as senders, summary is not a '
        'sender named like the room', () async {
      final prefs = await SharedPreferences.getInstance();
      final sink = _Sink();
      await RichRoomNoticePresenter(
        sink: sink,
        prefs: prefs,
        faces: BotFaceBitmapCache(directory: () async => dir),
      ).present('c1', buildRoom(), [round('user:d1', 6)]);
      final card = sink.posts.single;
      final room = buildRoom().name;
      expect(card['conversationTitle'], room);
      expect(card['title'], room);
      final messages = (card['messages'] as List).cast<Map>();
      expect(messages.map((m) => m['senderName']).take(2), [
        'Radar',
        'Builder',
      ]);
      for (final m in messages) {
        expect(m['senderName'], isNot(room), reason: '${m['text']}');
      }
      // The closing summary carries the round verdict, not a fake speaker.
      expect(card['subText'], 'Round done · Radar and Builder replied');
      expect(card['text'], 'Round done · Radar and Builder replied');
    });
  });
}

final class _Sink implements RichNotificationSink {
  final posts = <Map<String, Object?>>[];
  final live = <Map<String, Object?>>[];
  final cancels = <int>[];
  @override
  Future<void> cancel({required int id, String? tag}) async => cancels.add(id);
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
  Future<void> postLiveUpdate(Map<String, Object?> args) async => live.add(args);
}
