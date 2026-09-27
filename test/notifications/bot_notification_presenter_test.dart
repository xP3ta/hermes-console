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
    expect(message['senderName'], 'console-builder');
    expect(message['text'], 'Done. @user please merge');
    expect(message['iconPath'], isNotNull);
    expect(conv['alert'], isTrue);
    expect(sink.live.single['text'], 'console-builder is working…');
    expect(sink.live.single['trackerIconPath'], isNotNull);
  });

  test('round finished ends the live update and posts a quiet summary', () async {
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
    expect(conv['alert'], isFalse);
    expect(((conv['messages'] as List).single as Map)['text'],
        'Round done · console-builder and console-review replied');
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
