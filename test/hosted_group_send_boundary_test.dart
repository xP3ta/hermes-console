import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

Map<String, Object?> _event({
  int seq = 4,
  String eventId = 'user:durable',
  String text = 'hello',
  String threadId = 'thread-1',
  int authorityEpoch = 2,
  Object? createdAt = 12.5,
  bool idempotent = false,
  Map<String, Object?> actor = const {'kind': 'user', 'id': 'desktop'},
  String roomId = 'room-1',
}) => {
  'room_id': roomId,
  'seq': seq,
  'event_id': eventId,
  'kind': 'message.user',
  'actor': actor,
  'authority_epoch': authorityEpoch,
  'payload': {'text': text, 'thread_id': threadId},
  'created_at': createdAt,
  'idempotent': idempotent,
};

Map<String, Object?> _page({
  List<Object?>? events,
  int cursor = 4,
  int latestSeq = 4,
  bool hasMore = false,
  int authorityEpoch = 2,
}) => {
  'events': events ?? [_event()],
  'cursor': cursor,
  'latest_seq': latestSeq,
  'has_more': hasMore,
  'authority': {'gateway_id': 'gateway-1', 'epoch': authorityEpoch},
};

void main() {
  test(
    'cycle 1: official log envelope preserves typed immutable event fields',
    () {
      final page = HostedGroupLogPage.fromJson(
        _page(),
        expectedRoomId: 'room-1',
        sinceSeq: 3,
      );

      expect(page.cursor, 4);
      expect(page.latestSeq, 4);
      expect(page.authority.gatewayId, 'gateway-1');
      expect(page.authority.epoch, 2);
      final event = page.events.single;
      expect(event.actor.kind, 'user');
      expect(event.actor.id, 'desktop');
      expect(event.createdAt, 12.5);
      expect(event.idempotent, isFalse);
    },
  );

  test('exact tuple: official optional actor metadata is retained exactly', () {
    final event = HostedGroupEvent.fromJson(
      _event(
        actor: const {
          'kind': 'user',
          'id': 'desktop',
          'display_name': 'Desktop User',
          'profile': 'work',
          'connection_id': 'connection-7',
        },
      ),
      roomId: 'room-1',
    );

    expect(event.actor.displayName, 'Desktop User');
    expect(event.actor.profile, 'work');
    expect(event.actor.connectionId, 'connection-7');
  });

  test('exact tuple: unknown actor fields are rejected by the parser', () {
    final event = _event(
      actor: const {
        'kind': 'user',
        'id': 'desktop',
        'display_name': 'Desktop User',
        'unknown': 'not official',
      },
    );

    expect(
      () => HostedGroupEvent.fromJson(event, roomId: 'room-1'),
      throwsFormatException,
    );
  });

  test('exact tuple: message.user payload schema is closed and complete', () {
    final malformedPayloads = <Map<String, Object?>>[
      {'thread_id': 'thread-1'},
      {'text': 'hello'},
      {'text': 'hello', 'thread_id': 'thread-1', 'unknown': true},
      {'text': 'hello', 'thread_id': 'thread-1', 'extra': null},
    ];

    for (final payload in malformedPayloads) {
      final event = {..._event(), 'payload': payload};
      expect(
        () => HostedGroupEvent.fromJson(event, roomId: 'room-1'),
        throwsFormatException,
        reason: '$payload',
      );
    }
  });

  test('exact tuple: complete payload semantics ignore only map key order', () {
    final first = HostedGroupEvent.fromJson({
      ..._event(),
      'kind': 'room.activity',
      'actor': const {'kind': 'gateway', 'id': 'gateway-1'},
      'payload': const {
        'state': {'active': true, 'count': 2},
        'members': ['a', 'b'],
      },
    }, roomId: 'room-1');
    final reordered = HostedGroupEvent.fromJson({
      ..._event(),
      'kind': 'room.activity',
      'actor': const {'id': 'gateway-1', 'kind': 'gateway'},
      'payload': const {
        'members': ['a', 'b'],
        'state': {'count': 2, 'active': true},
      },
    }, roomId: 'room-1');
    final mutated = HostedGroupEvent.fromJson({
      ..._event(),
      'kind': 'room.activity',
      'actor': const {'kind': 'gateway', 'id': 'gateway-1'},
      'payload': const {
        'state': {'active': true, 'count': 3},
        'members': ['a', 'b'],
      },
    }, roomId: 'room-1');

    expect(first.immutableEquals(reordered), isTrue);
    expect(first.immutableEquals(mutated), isFalse);
  });

  test('cycle 2: log page grammar fails closed', () {
    final malformed = <Map<String, Object?>>[
      _page(events: [_event(seq: 5)], cursor: 5, latestSeq: 5),
      _page(
        events: [
          _event(seq: 4),
          _event(seq: 3, eventId: 'user:other'),
        ],
        cursor: 3,
        latestSeq: 3,
      ),
      _page(events: [_event(), _event(seq: 5)], cursor: 5, latestSeq: 5),
      _page(cursor: 3),
      _page(cursor: 4, latestSeq: 3),
      _page(cursor: 4, latestSeq: 5, hasMore: false),
      _page(authorityEpoch: 1),
      {
        'events': [_event()],
        'next_seq': 5,
        'has_more': false,
      },
    ];

    for (final page in malformed) {
      expect(
        () => HostedGroupLogPage.fromJson(
          page,
          expectedRoomId: 'room-1',
          sinceSeq: 3,
        ),
        throwsFormatException,
        reason: '$page',
      );
    }
  });

  test('cycle 3: client event ID maps to the official durable identity', () {
    expect(
      TuiGatewayClient.durableGroupEventId('client-1'),
      'user:5704de18fc6045e4d08c3a261162795689ba6a0383964109350f8fad3c4ad972',
    );
  });

  test(
    'cycle 5: one typed attempt keeps client and thread identity stable',
    () {
      final first = HostedGroupSendAttempt.forClientEvent('client-1');
      final retry = HostedGroupSendAttempt.forClientEvent('client-1');
      final distinct = HostedGroupSendAttempt.forClientEvent('client-2');

      expect(first.clientEventId, retry.clientEventId);
      expect(first.threadId, retry.threadId);
      expect(first.threadId, 'thread-client-1');
      expect(distinct.clientEventId, isNot(first.clientEventId));
      expect(distinct.threadId, isNot(first.threadId));
    },
  );

  test('cycle 6: repository gateway seam carries the typed attempt', () async {
    final attempt = HostedGroupSendAttempt.forClientEvent('client-1');
    late HostedGroupSendAttempt observed;
    Future<HostedGroupLogPage> sendImpl(
      String roomId, {
      required String text,
      required HostedGroupSendAttempt attempt,
      required int generation,
    }) async {
      observed = attempt;
      return HostedGroupLogPage.fromJson(
        _page(),
        expectedRoomId: 'room-1',
        sinceSeq: 3,
      );
    }

    final MissionGroupsSend send = sendImpl;

    await send('room-1', text: 'hello', attempt: attempt, generation: 1);
    expect(observed, same(attempt));
  });

  test('cycle 6: thread is required and text is limited by UTF-8 bytes', () {
    final exact = List.filled(32768, 'é').join();
    final event = HostedGroupEvent.fromJson(
      _event(text: exact),
      roomId: 'room-1',
    );
    expect(utf8.encode(event.publicText!).length, 65536);

    expect(
      () =>
          HostedGroupEvent.fromJson(_event(text: '$exacté'), roomId: 'room-1'),
      throwsFormatException,
    );
    final missingThread = _event()
      ..update('payload', (value) => {'text': 'hello'});
    expect(
      () => HostedGroupEvent.fromJson(missingThread, roomId: 'room-1'),
      throwsFormatException,
    );
    expect(
      () => HostedGroupSendAttempt.forClientEvent('client', threadId: ' '),
      throwsFormatException,
    );
  });

  test(
    'official hosted send requires a proven-complete log; retry and promote stay retired',
    () {
      // `send` became official once loading a room's log could prove
      // completeness (`HostedGroupLogPage.loadComplete`) rather than only a
      // bounded recent window — see `docs/hosted_identity_transition_matrix.md`.
      expect(GroupMethod.official('groups.send'), GroupMethod.send);
      expect(GroupMethod.official('groups.retry'), isNull);
      expect(GroupMethod.official('groups.promote'), isNull);
    },
  );
}
