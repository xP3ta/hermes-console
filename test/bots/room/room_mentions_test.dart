import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_mentions.dart';

void main() {
  const members = ['Alice', 'bob', 'ops:west'];

  group('resolveRoomMentions', () {
    test('matches handles case-insensitively in roster order', () {
      expect(resolveRoomMentions(['Hi @BOB and @alice'], members), [
        'Alice',
        'bob',
      ]);
    });

    test('@all and @everyone resolve every member', () {
      expect(resolveRoomMentions(['@all'], members), members);
      expect(resolveRoomMentions(['@EVERYONE'], members), members);
    });

    test('unknown-only mentions fall back to every member', () {
      expect(resolveRoomMentions(['@nobody hi'], members), members);
    });

    test('dot punctuation remains part of the server-compatible handle', () {
      expect(resolveRoomMentions(['Ask @bob.'], members), members);
    });

    test('defaultAll false keeps unknown-only mentions unresolved', () {
      expect(
        resolveRoomMentions(['@nobody hi'], members, defaultAll: false),
        isEmpty,
      );
    });
  });
}
