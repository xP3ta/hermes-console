import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/utils/chat_read_marker.dart';
import 'package:hermes_android/core/utils/unread_rules.dart';

import 'bots/room/room_fixtures.dart';

typedef _Row = ({int at, UnreadRowKind kind});

int? _first(List<_Row> rows, int seen, int through) =>
    unreadFirstAwayIndex<_Row>(
      rows,
      seenThrough: seen,
      arrivedThrough: through,
      positionOf: (r) => r.at,
      kindOf: (r) => r.kind,
    );

void main() {
  const news = UnreadRowKind.news;
  const own = UnreadRowKind.own;
  const quiet = UnreadRowKind.quiet;

  group('divider window', () {
    final rows = <_Row>[
      (at: 1, kind: news),
      (at: 2, kind: own),
      (at: 3, kind: quiet),
      (at: 4, kind: news),
      (at: 5, kind: news),
    ];

    test('first news after the watermark, skipping own and quiet rows', () {
      expect(_first(rows, 1, 5), 3);
    });

    test('news that arrived after the return is never "since you left"', () {
      expect(_first(rows, 1, 3), isNull);
    });

    test('only own rows after the watermark: no divider', () {
      expect(_first(rows.take(3).toList(), 1, 3), isNull);
    });

    test('a watermark older than everything loaded claims nothing', () {
      expect(_first(rows.skip(1).toList(), 1, 5), isNull);
    });
  });

  test('pill counts only news after the baseline', () {
    final rows = <_Row>[
      (at: 4, kind: news),
      (at: 5, kind: own),
      (at: 6, kind: quiet),
      (at: 7, kind: news),
    ];
    expect(
      unreadNewsAfter<_Row>(
        rows,
        baseline: 4,
        positionOf: (r) => r.at,
        kindOf: (r) => r.kind,
      ),
      1,
    );
  });

  test('pill visible only in the chat, reading, with a count', () {
    expect(unreadPillVisible(present: true, reading: true, count: 2), isTrue);
    expect(unreadPillVisible(present: false, reading: true, count: 2), isFalse);
    expect(unreadPillVisible(present: true, reading: false, count: 2), isFalse);
    expect(unreadPillVisible(present: true, reading: true, count: 0), isFalse);
  });

  test('presence: only a long enough absence is leaving', () {
    var now = DateTime(2026, 10, 6, 12);
    final presence = UnreadPresence(clock: () => now);
    expect(presence.present, isTrue);
    expect(presence.show(), isFalse);
    presence.hide();
    now = now.add(const Duration(seconds: 10));
    presence.hide(); // a second hide keeps the first time
    now = now.add(const Duration(seconds: 49));
    expect(presence.show(), isFalse);
    presence.hide();
    now = now.add(UnreadPresence.leftAfter);
    expect(presence.present, isFalse);
    expect(presence.show(), isTrue);
    expect(presence.present, isTrue);
  });

  test('chat rows: replies are news, own turns and tool rows are not', () {
    expect(
      chatUnreadRowKind({'id': 1, 'role': 'assistant', 'content': 'hola'}),
      news,
    );
    expect(chatUnreadRowKind({'id': 2, 'role': 'user', 'content': 'q'}), own);
    expect(chatUnreadRowKind({'id': 3, 'role': 'tool', 'content': 'x'}), quiet);
    expect(
      chatUnreadRowKind({'id': 4, 'role': 'assistant', 'content': '  '}),
      quiet,
    );
    expect(
      chatUnreadRowKind({
        'role': 'assistant',
        'content': 'thinking',
        '_pipeline': true,
      }),
      quiet,
    );
  });

  test('room transcript: divider only for replies up to the arrival cap', () {
    final seq = EventSeq();
    final u = seq.user('hi @review');
    final disc = u['event_id'] as String;
    final events = buildLog([
      u,
      seq.member('m-review', 'review', 'old', disc),
      seq.user('mine', thread: 'thread-2'),
      seq.member('m-review', 'review', 'away', disc),
      seq.member('m-review', 'review', 'later', disc),
    ]).events;
    final members = buildRoom().members;
    List<String> keys({int? through}) => [
      for (final e in buildRoomTranscript(
        events: events,
        members: members,
        lastSeenSeq: 2,
        arrivedThroughSeq: through,
      ))
        e is RoomNewSinceDivider
            ? 'divider'
            : e is RoomMessageEntry
            ? e.body.toString()
            : '',
    ]..removeWhere((k) => k.isEmpty);
    final withCap = keys(through: 4);
    final at = withCap.indexOf('divider');
    // hi, old, mine (own: above the divider), divider, away, later.
    expect(withCap.length, 6);
    expect(at, 3);
    expect(keys(through: 3).contains('divider'), isFalse);
  });
}
