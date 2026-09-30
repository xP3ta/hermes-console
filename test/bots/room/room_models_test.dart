import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/state/bot_presence.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';

import 'room_fixtures.dart';

void main() {
  group('attachment suffix (G1 interim, Desktop format)', () {
    test('round-trips the Desktop reference suffix', () {
      final text = appendRoomAttachmentSuffix('Look at this', const [
        RoomAttachmentRef(name: 'shot.png', path: '/home/h/uploads/1_shot.png'),
        RoomAttachmentRef(
          name: 'my notes.pdf',
          path: '/home/h/uploads/2 notes.pdf',
        ),
      ]);
      expect(
        text,
        'Look at this\n\n'
        'Attached files staged in your session workspace:\n'
        'shot.png → @file:/home/h/uploads/1_shot.png\n'
        'my notes.pdf → @file:`/home/h/uploads/2 notes.pdf`',
      );
      final parsed = parseRoomMessageText(text);
      expect(parsed.text, 'Look at this');
      expect(parsed.attachments.map((a) => a.path), [
        '/home/h/uploads/1_shot.png',
        '/home/h/uploads/2 notes.pdf',
      ]);
      expect(parsed.attachments.first.isImage, isTrue);
    });

    test('malformed or unsafe suffixes stay in the Markdown body', () {
      const bad =
          'x\nAttached files staged in your session workspace:\nf → @file:../etc/passwd';
      expect(parseRoomMessageText(bad).attachments, isEmpty);
      expect(parseRoomMessageText(bad).text, bad);
    });
  });

  test('mentions become links, never inside code', () {
    final out = linkifyRoomMentions(
      'Hi @builder and @nobody, `@builder` stays\n```\n@review\n```\nmail a@b.c',
      ['builder', 'review'],
    );
    expect(out, contains('[@builder]($roomMentionScheme:builder)'));
    expect(out, contains('@nobody'));
    expect(out, contains('`@builder`'));
    expect(out, contains('\n@review\n'));
    expect(out, contains('a@b.c'));
  });

  group('transcript grouping', () {
    test('consecutive speaker messages form one run', () {
      final seq = EventSeq();
      final u = seq.user('status? @builder @review');
      final disc = u['event_id'] as String;
      final events = buildLog([
        u,
        seq.member('m-builder', 'builder', 'one', disc),
        seq.member('m-builder', 'builder', 'two', disc),
        seq.member('m-review', 'review', 'three', disc),
      ]).events;
      final entries = buildRoomTranscript(
        events: events,
        members: buildRoom().members,
      ).whereType<RoomMessageEntry>().toList();
      expect(entries.map((e) => e.firstOfRun), [true, true, false, true]);
      expect(entries[1].member?.handle, 'builder');
    });

    test('day separator, new-since divider and quiet round divider', () {
      final seq = EventSeq();
      final u = seq.user('go', atSeconds: 1790000100.0);
      final disc = u['event_id'] as String;
      final events = buildLog([
        u,
        seq.member('m-builder', 'builder', 'r1', disc),
        seq.member('m-builder', 'builder', 'r2', disc, round: 1),
      ]).events;
      final entries = buildRoomTranscript(
        events: events,
        members: buildRoom().members,
        lastSeenSeq: 1,
      );
      expect(entries.first, isA<RoomDaySeparator>());
      expect(entries.whereType<RoomNewSinceDivider>(), hasLength(1));
      final round = entries.whereType<RoomRoundDivider>().single;
      expect(round.round, 2);
    });

    test('later discussions in a thread fold into a reply summary', () {
      final seq = EventSeq();
      final root = seq.user('root');
      final disc = root['event_id'] as String;
      final reply = seq.member('m-builder', 'builder', 'answer', disc);
      final followUp = seq.user('follow up', thread: 'thread-1');
      final followDisc = followUp['event_id'] as String;
      final events = buildLog([
        root,
        reply,
        followUp,
        seq.member('m-lead', 'lead', 'in thread', followDisc),
      ]).events;
      final entries = buildRoomTranscript(
        events: events,
        members: buildRoom().members,
      ).whereType<RoomMessageEntry>().toList();
      expect(entries, hasLength(2));
      final summary = entries.last.thread!;
      expect(summary.replies, 2);
      expect(summary.lastActor?.id, 'm-lead');
    });

    test('passes collapse into one line per discussion (no inline passes)', () {
      final seq = EventSeq();
      final u = seq.user('go');
      final disc = u['event_id'] as String;
      final events = buildLog([
        u,
        seq.member('m-builder', 'builder', 'hi', disc),
        seq.settled('m-radar', disc, passed: true),
        seq.settled('m-review', disc, passed: true),
      ]).events;
      final entries = buildRoomTranscript(
        events: events,
        members: buildRoom().members,
      );
      final passes = entries.whereType<RoomPassesEntry>().single;
      expect(passes.memberIds, ['m-radar', 'm-review']);
    });
  });

  group('round panel model', () {
    test('per-member states from turn.* and driver status', () {
      final seq = EventSeq();
      final u = seq.user('@builder @review @lead @radar ship it');
      final disc = u['event_id'] as String;
      final events = buildLog([
        u,
        seq.started('m-builder', disc),
        seq.started('m-lead', disc),
        seq.settled('m-radar', disc, passed: true),
      ]).events;
      final round = deriveRoomRound(
        events: events,
        members: buildRoom().members,
        driverStatus: driver(
          working: true,
          counts: {'running': 2, 'queued': 1},
          pending: [approvalAction()],
        ),
      )!;
      final byHandle = {for (final r in round.rows) r.member.handle: r.state};
      expect(byHandle, {
        'builder': RoomTurnState.working,
        'review': RoomTurnState.queued,
        'lead': RoomTurnState.needsYou,
        'radar': RoomTurnState.passed,
      });
      expect(round.round, 1);
      expect(round.working, 1);
      expect(round.queued, 1);
      expect(round.active, isTrue);
      expect(
        round.rows
            .firstWhere((r) => r.member.handle == 'lead')
            .approval
            ?.command,
        'gh pr ready 51',
      );
    });

    test('without driver status a turn is working only while its latest '
        'activity is within the roster worker freshness', () {
      final seq = EventSeq();
      final u = seq.user('@builder go');
      final disc = u['event_id'] as String;
      final started = seq.started('m-builder', disc);
      final startedAt = started['created_at'] as double;
      final events = buildLog([u, started]).events;
      final members = buildRoom().members;
      DateTime at(double seconds) =>
          DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
      RoomTurnState stateAt(List<HostedGroupEvent> events, DateTime now) =>
          deriveRoomRound(
            events: events,
            members: members,
            now: now,
          )!.rows.single.state;
      final window = BotPresence.workerFreshness.inSeconds;

      expect(stateAt(events, at(startedAt + window)), RoomTurnState.working);
      expect(
        stateAt(events, at(startedAt + window + 1)),
        RoomTurnState.noReply,
      );
      // Freshness counts from the latest activity of that member's turn.
      final later = seq.member(
        'm-builder',
        'builder',
        'partial',
        disc,
        atSeconds: startedAt + window,
      );
      final withActivity = buildLog([u, started, later]).events;
      expect(
        stateAt(withActivity, at(startedAt + window + 60)),
        RoomTurnState.working,
      );
    });

    test('failed turn offers retry only when the server lists the task', () {
      final seq = EventSeq();
      final u = seq.user('@radar check');
      final disc = u['event_id'] as String;
      final events = buildLog([
        u,
        seq.started('m-radar', disc, task: 'task-r'),
        seq.failed('m-radar', disc, task: 'task-r'),
      ]).events;
      final members = buildRoom().members;
      final without = deriveRoomRound(
        events: events,
        members: members,
        driverStatus: driver(),
      )!;
      expect(without.rows.single.state, RoomTurnState.failed);
      expect(without.rows.single.retryOffered, isFalse);
      final withRetry = deriveRoomRound(
        events: events,
        members: members,
        driverStatus: driver(
          pending: [
            {'kind': 'retry', 'task_id': 'task-r'},
          ],
        ),
      )!;
      expect(withRetry.rows.single.retryOffered, isTrue);
    });
  });
}
