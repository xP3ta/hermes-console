import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/bot_face_bitmap.dart';
import 'package:hermes_android/core/services/notifications/bot_notification_presenter.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:hermes_android/core/services/notifications/room_watcher.dart';
import 'package:hermes_android/core/widgets/bot_face_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bots/room/room_fixtures.dart';

// Each Bot tints its own notifications with the colour of its face, so the
// shade says who is talking before reading a word. State colours stay where
// they carry meaning: needs-you amber, failed red.
const _teal = 0xFF46C49F;
const _violet = 0xFF6D35EA;

BotFaceIdentity? _identity(String connId, String profile) => switch (profile) {
  'builder' => BotFaceIdentity.resolve(profile: 'builder', colorHex: '#46c49f'),
  'review' => BotFaceIdentity.resolve(profile: 'review', colorHex: '#6d35ea'),
  _ => null,
};

void main() {
  late Directory dir;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'app_locale': 'en'});
    dir = await Directory.systemTemp.createTemp('accent');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<(RichRoomNoticePresenter, _Sink)> presenter() async {
    final sink = _Sink();
    return (
      RichRoomNoticePresenter(
        sink: sink,
        prefs: await SharedPreferences.getInstance(),
        faces: BotFaceBitmapCache(directory: () async => dir),
        identityFor: _identity,
      ),
      sink,
    );
  }

  test('botAccent is the face colour; unconfigured grey keeps brand', () {
    expect(botAccent(_identity('c1', 'builder')!), _teal);
    expect(botAccent(_identity('c1', 'review')!), _violet);
    expect(
      botAccent(BotFaceIdentity.resolve(profile: 'x', colorHex: '#dddddd')),
      RichAccent.brand,
    );
  });

  test('a finished round wears the colour of the Bot that closed it', () async {
    for (final (last, colour) in [
      ('m-builder', _teal),
      ('m-review', _violet),
    ]) {
      final (p, sink) = await presenter();
      await p.present('c1', buildRoom(), [
        RoomRoundFinishedNotice(
          const ['m-builder', 'm-review'],
          9,
          lastMemberId: last,
          replies: [
            RoomRoundReply(
              memberId: last,
              text: 'done',
              timeMs: 1,
              eventId: 'e-$last',
            ),
          ],
        ),
      ]);
      expect(sink.posts.single['accent'], colour, reason: last);
    }
  });

  test('failure and needs-you keep their state colour', () async {
    final (p, sink) = await presenter();
    final seq = EventSeq();
    final mention = buildLog([
      seq.member('m-builder', 'builder', '@user look', 'd1'),
    ]).events.single;
    await p.present('c1', buildRoom(), [RoomMentionNotice(mention)]);
    expect(sink.posts.single['accent'], RichAccent.needsYou);

    final (p2, sink2) = await presenter();
    final fail = buildLog([EventSeq().failed('m-review', 'd1')]).events.single;
    await p2.present('c1', buildRoom(), [
      RoomMemberFailedNotice(fail),
      RoomRoundFinishedNotice(
        const ['m-builder'],
        9,
        lastMemberId: 'm-builder',
      ),
    ]);
    expect(sink2.posts.single['accent'], RichAccent.failed);
  });

  test('the live card wears the colour of the Bot replying', () async {
    final (p, sink) = await presenter();
    await p.present('c1', buildRoom(), [
      const RoomLiveNotice(
        working: true,
        members: [
          (memberId: 'm-review', state: 'working'),
          (memberId: 'm-builder', state: 'pending'),
        ],
        workingMemberId: 'm-review',
        startedAtMs: 5,
      ),
    ]);
    expect(sink.live.single['accent'], _violet);
  });

  test('a 1:1 reply wears its Bot colour', () async {
    final sink = _Sink();
    await BotChatRichNotifications(
      sink: sink,
      faces: BotFaceBitmapCache(directory: () async => dir),
      identityFor: _identity,
    ).replyReady(
      t: NotifL10n.of(await SharedPreferences.getInstance()),
      connId: 'c1',
      profile: 'builder',
      botName: 'Builder',
      sessionId: 's1',
      preview: 'ready',
    );
    expect(sink.posts.single['accent'], _teal);
  });
}

final class _Sink implements RichNotificationSink {
  final posts = <Map<String, Object?>>[];
  final live = <Map<String, Object?>>[];
  @override
  Future<void> cancel({required int id, String? tag}) async {}
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
