// Hosted-room contract: every shape Hermes can send on the `groups.*`
// surface, taken from a snapshot of the server
// (test/fixtures/contract/hosted-rooms.json, refreshed by
// tool/contract/extract_room_contract.py from a hermes-agent checkout), is
// fed to Console's real room parsers and must be read, not rejected.
//
// The published gateway contract types the `groups.*` results but leaves a
// room event's `payload` open; the shape of each event kind exists only as
// the server's validators, so the snapshot also records, per kind, the
// fields those validators allow (required and optional), their enum values,
// the attachment manifest, the roster row and the limits. Every closed shape
// here is built with EVERY field the server allows, at the server's limits:
// refreshing the snapshot from a newer checkout is how a new server field
// that Console would refuse (a whole room log failing to load) shows up
// before users meet it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';

import 'support/contract/gateway_contract.dart';

const _fixturePath = 'test/fixtures/contract/hosted-rooms.json';
const _roomId = 'room-1';
const _gatewayId = 'gateway-1';
const _text = 'Hello room';
const _threadId = 'thread-1';

final Map<String, dynamic> _fixture =
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _section(String name) =>
    _fixture[name] as Map<String, dynamic>;

List<String> _strings(Object? value) =>
    (value as List? ?? const []).cast<String>();

int _limit(String name) => _section('limits')[name] as int;

/// The `groups.*` results Console parses, as an in-memory contract the
/// sampler of the gateway conformance test understands.
GatewayContract _contract() => GatewayContract.fromDocument({
  'components': {'schemas': _fixture['schemas']},
  'methods': [
    for (final entry in _section('methods').entries)
      {
        'name': entry.key,
        'result': {'schema': entry.value},
      },
  ],
  'x-notifications': const [],
  'x-server-requests': const [],
});

/// One manifest at every attachment limit at once: the most entries a
/// message may carry, one of them the largest file, every kind, the longest
/// name and MIME type, and exactly the per-message byte budget.
List<Map<String, dynamic>> _fullManifest() {
  final kinds = _strings(_section('attachment')['kinds']);
  final count = _limit('attachments_per_message');
  final largest = _limit('attachment_bytes');
  final budget = _limit('message_attachment_bytes');
  final sizes = [largest, for (var i = 1; i < count; i++) 1];
  if (count > 1) sizes[1] = budget - largest - (count - 2);
  if (count < 2 || sizes[1] < 1 || sizes[1] > largest) {
    throw StateError('the attachment limits no longer fit one manifest');
  }
  String kindAt(int index) => kinds[index % kinds.length];
  // The longest MIME type goes to the first kind with a free MIME type.
  var longMime = -1;
  for (var i = count - 1; i >= 0; i--) {
    if (!{'image', 'pdf'}.contains(kindAt(i))) longMime = i;
  }
  return [
    for (var i = 0; i < count; i++)
      _attachment(
        fields: _strings(_section('attachment')['fields']),
        id: 'att_${i.toRadixString(16).padLeft(32, '0')}',
        kind: kindAt(i),
        name: i == 0
            ? '${'n' * (_limit('attachment_name_chars') - 4)}.png'
            : 'file-$i',
        size: sizes[i],
        mime: switch (kindAt(i)) {
          'image' => 'image/png',
          'pdf' => 'application/pdf',
          _ when i == longMime => _paddedMime(_limit('attachment_mime_chars')),
          _ => 'application/octet-stream',
        },
      ),
  ];
}

String _paddedMime(int length) {
  const prefix = 'application/';
  return '$prefix${'x' * (length - prefix.length)}';
}

Map<String, dynamic> _attachment({
  required List<String> fields,
  required String id,
  required String kind,
  required String name,
  required int size,
  required String mime,
}) => {
  for (final field in fields)
    field: switch (field) {
      'attachment_id' => id,
      'kind' => kind,
      'name' => name,
      'size' => size,
      'mime' => mime,
      _ => 'v-$field',
    },
};

/// A value the server would accept for a room event payload field. A field
/// this table does not know (a new one) gets an identifier-shaped string:
/// Console must not refuse a payload because of a field it does not read.
Object? _payloadValue(String field) => switch (field) {
  'text' => _text,
  'thread_id' => _threadId,
  'attachments' => _fullManifest(),
  'member_index' || 'round_index' => 0,
  'seen_through_seq' || 'execution_generation' || 'grant' => 1,
  'passed' || 'everyone' || 'fallback' => false,
  'member_ids' || 'recipient_member_ids' => const ['member-1'],
  'member_id' || 'lead_member_id' => 'member-1',
  'reason' => 'member busy',
  'error' => 'provider error',
  _ => 'v-${field.replaceAll('_', '-')}',
};

/// The server actor of [actorKind] with every field it may carry, each at
/// the server's length limit.
Map<String, dynamic> _fullActor(String actorKind) {
  final events = _section('events');
  return {
    for (final field in _strings(events['actor_fields']))
      field: switch (field) {
        'kind' => actorKind,
        'display_name' => 'D' * _limit('actor_label_chars'),
        _ => field[0] * _limit('actor_id_chars'),
      },
  };
}

Map<String, dynamic> _event({
  required int seq,
  required String kind,
  required Map<String, dynamic> actor,
  required Map<String, dynamic> payload,
}) => {
  'room_id': _roomId,
  'seq': seq,
  'event_id': 'event-$seq',
  'kind': kind,
  'actor': actor,
  'authority_epoch': 1,
  'payload': payload,
  'created_at': 1700000000.5,
  'idempotent': false,
};

/// [events] as the one page of a complete `groups.log` read.
HostedGroupLogPage _readLog(List<Map<String, dynamic>> events) =>
    HostedGroupLogPage.fromJson(
      {
        'events': events,
        'cursor': events.length,
        'latest_seq': events.length,
        'has_more': false,
        'authority': {'gateway_id': _gatewayId, 'epoch': 1},
      },
      expectedRoomId: _roomId,
      sinceSeq: 0,
    );

/// Every payload the server's validator of [kind] accepts that this test
/// builds: all fields, required fields only, and one per enum value. A kind
/// whose payload the server never closes gets an unknown key.
List<(String, Map<String, dynamic>)> _payloads(String kind) {
  final shape =
      (_section('events')['payloads'] as Map)[kind] as Map<String, dynamic>;
  if (!shape.containsKey('required')) {
    return [
      (
        'open payload',
        {contractUnknownKey: 'x'},
      ),
    ];
  }
  final required = _strings(shape['required']);
  final optional = _strings(shape['optional']);
  final enums = (shape['enums'] as Map? ?? const {}).cast<String, dynamic>();
  Map<String, dynamic> build(Iterable<String> fields) => {
    for (final field in fields)
      field: enums.containsKey(field)
          ? _strings(enums[field]).first
          : _payloadValue(field),
  };
  return [
    ('every field', build([...required, ...optional])),
    ('required fields', build(required)),
    for (final enumField in enums.entries)
      for (final value in _strings(enumField.value))
        (
          '${enumField.key}=$value',
          build([...required, ...optional])..[enumField.key] = value,
        ),
  ];
}

/// A roster row with every field the server allows, for [targetKind].
Map<String, dynamic> _member(
  int index,
  String? targetKind, {
  required bool optional,
}) {
  final member = _section('member');
  final profile = 'profile-$index';
  final fields = [
    ..._strings(member['required']),
    if (optional) ..._strings(member['optional']),
  ];
  Map<String, dynamic> target(String kind) => {
    for (final field in _strings((member['targets'] as Map)[kind]))
      field: switch (field) {
        'kind' => kind,
        'profile' => profile,
        'capability_digest' => 'a' * 64,
        _ => 'v-${field.replaceAll('_', '-')}-$index',
      },
  };
  return {
    for (final field in fields)
      if (field != 'target' || targetKind != null)
        field: switch (field) {
          'member_id' => 'member-$index',
          'profile' => profile,
          'handle' => 'handle-$index',
          'display_name' => 'D' * _limit('actor_label_chars'),
          'target' => target(targetKind!),
          _ => 'v-${field.replaceAll('_', '-')}',
        },
  };
}

/// Every roster row shape: each target kind, no target (a member of the
/// room's own gateway), and without the optional fields.
List<Map<String, dynamic>> _roster() {
  final kinds = (_section('member')['targets'] as Map).keys.cast<String>();
  var index = 0;
  return [
    for (final kind in kinds) _member(++index, kind, optional: true),
    _member(++index, null, optional: true),
    _member(++index, null, optional: false),
  ];
}

/// A form the published schema allows but neither server sends, with the
/// rewrite into what the server does send. Listed only while Console still
/// refuses the contract-only form (checked below), so the list stays true.
final class _ContractOnly {
  final String name;
  final String reason;
  final void Function(Map<String, dynamic> sample) rewrite;

  const _ContractOnly(this.name, this.reason, this.rewrite);
}

Iterable<Map<String, dynamic>> _maps(Object? list) =>
    (list as List? ?? const []).whereType<Map<String, dynamic>>();

Iterable<Map<String, dynamic>> _eventsOf(Map<String, dynamic> result) => [
  ..._maps(result['events']),
  if (result['event'] is Map<String, dynamic>)
    result['event'] as Map<String, dynamic>,
];

Iterable<Map<String, dynamic>> _roomsOf(Map<String, dynamic> result) => [
  if (result['room'] is Map<String, dynamic>)
    result['room'] as Map<String, dynamic>,
  ..._maps(result['rooms']),
];

final _contractOnly = <_ContractOnly>[
  _ContractOnly(
    'RoomEvent.authority_epoch null or absent',
    'every append has been authority-scoped since the first hosted-room '
        'release (gateway/hosted_rooms.py append_event; persistence/sqlite/'
        'gateway/hosted_rooms.py _insert_event takes `epoch: int`); a NULL '
        'column is only a row migrated from a pre-release draft database '
        '(_LEGACY_COLUMNS)',
    (sample) {
      for (final event in _eventsOf(sample)) {
        if (event['authority_epoch'] is! int) event['authority_epoch'] = 1;
      }
    },
  ),
  _ContractOnly(
    'RoomEvent.idempotent absent',
    '_event_from_row always writes it (persistence/sqlite/gateway/'
        'hosted_rooms.py)',
    (sample) {
      for (final event in _eventsOf(sample)) {
        event.putIfAbsent('idempotent', () => false);
      }
    },
  ),
  _ContractOnly(
    'RoomActor optional field null',
    'gateway/hosted_rooms.py _validate_actor skips a None field and keeps '
        'only non-empty strings',
    (sample) {
      for (final event in _eventsOf(sample)) {
        final actor = event['actor'];
        if (actor is Map) actor.removeWhere((_, value) => value == null);
      }
    },
  ),
  _ContractOnly(
    'Room.disbanded_at null',
    '_room_from_row writes disbanded_at only when the room is disbanded',
    (sample) {
      for (final room in _roomsOf(sample)) {
        if (room['disbanded_at'] == null) room.remove('disbanded_at');
      }
    },
  ),
  _ContractOnly(
    'RoomMember open row',
    'the roster is stored as validated at create (hosted_room_discussion.py '
        '_validate_member / _validate_member_target, recorded in the '
        'snapshot\'s "member" section and checked by its own test); the '
        'schema leaves the row open for pre-normalisation drafts',
    (sample) {
      for (final room in _roomsOf(sample)) {
        if (room['members'] is List && (room['members'] as List).isNotEmpty) {
          room['members'] = _roster();
        }
      }
    },
  ),
];

/// The room event schema, sampled on its own as well: only a top-level field
/// of a sample is ever left out, and an event's optional fields matter.
const _roomEvent = 'RoomEvent';

/// The sampled shapes: each `groups.*` result Console parses, and the event.
Map<String, Map<String, dynamic>> _consumers(GatewayContract contract) => {
  for (final method in _section('methods').keys.toList()..sort())
    method: contract.methodResultSchema(method),
  _roomEvent: contract.schemaNamed(_roomEvent),
};

/// The contract samples of [schema] this test checks. Unknown keys are left
/// out: these schemas are closed (`additionalProperties: false`) and so is
/// the server; a key in an open payload is checked per event kind above.
Iterable<ContractSample> _samples(
  ContractSampler sampler,
  Map<String, dynamic> schema,
) => sampler.samples(schema).where((s) => !s.label.endsWith('+extra'));

/// Makes a sampled result coherent where the sampler cannot know the rule
/// (sequence numbers, the room asked for, the method list of a live
/// capabilities read). Never touches the fields under test.
Map<String, dynamic> _coherent(String method, Map<String, dynamic> sample) {
  var out = jsonDecode(jsonEncode(sample)) as Map<String, dynamic>;
  if (method == _roomEvent) {
    // A bare event is read as the one event of a log page.
    out = {
      'events': [out],
      'authority': {'gateway_id': _gatewayId, 'epoch': 1},
    };
  }
  if (method == 'groups.log' || method == _roomEvent) {
    final events = _maps(out['events']).toList();
    for (var i = 0; i < events.length; i++) {
      events[i]['room_id'] = _roomId;
      events[i]['seq'] = i + 1;
      events[i]['event_id'] = 'event-${i + 1}';
    }
    out['cursor'] = events.length;
    out['latest_seq'] = events.length;
    out['has_more'] = false;
  }
  if (method == 'groups.capabilities') {
    out['methods'] = [..._strings(out['methods']), 'groups.capabilities'];
  }
  if (method == 'groups.send') {
    (out['event'] as Map<String, dynamic>)['room_id'] = _roomId;
  }
  return out;
}

/// Parses a coherent `groups.*` result with Console's parser; `true` when
/// every item of it was kept.
bool _parseResult(String method, Map<String, dynamic> result) {
  switch (method) {
    case 'groups.capabilities':
      return GroupsCapabilities.tryParse(
            result,
            connectionId: 'conn-contract',
            generation: 1,
          ) !=
          null;
    case 'groups.list':
      final page = HostedGroupListPage.fromJson(result);
      return page.unreadable.isEmpty &&
          page.rooms.length == (result['rooms'] as List).length;
    case 'groups.state':
      HostedGroupRoom.fromJson(result['room']);
      final driver = result['driver_status'];
      return driver == null || RoomDriverStatus.tryParse(driver) != null;
    case 'groups.create':
      HostedGroupRoom.fromJson(result['room']);
      return true;
    case 'groups.log' || _roomEvent:
      final page = HostedGroupLogPage.fromJson(
        result,
        expectedRoomId: _roomId,
        sinceSeq: 0,
      );
      return page.events.length == (result['events'] as List).length;
    case 'groups.send':
      HostedGroupEvent.fromJson(result['event'], roomId: _roomId);
      return true;
  }
  throw StateError('no parser for $method');
}

/// Outcome of [method]'s parser over [result]: null when kept, else why not.
String? _failure(String method, Map<String, dynamic> result) {
  try {
    return _parseResult(method, result) ? null : 'DROPPED';
  } on Object catch (error) {
    return 'THREW $error';
  }
}

void main() {
  final contract = _contract();
  final sampler = ContractSampler(contract);
  final events = _section('events');
  final kindsByActor = (events['kinds_by_actor'] as Map).map(
    (actor, kinds) => MapEntry(actor as String, _strings(kinds)),
  );

  test('the snapshot records its upstream source', () {
    final source = _section('source');
    final commit = RegExp(r'^[0-9a-f]{40}$');
    expect(source['checkout_commit'], matches(commit));
    final files = (source['files'] as Map).cast<String, String>();
    expect(files, isNotEmpty);
    for (final changed in files.values) {
      expect(changed, matches(commit));
    }
    expect(source['license'], startsWith('MIT'));
    expect(File(source['generator'] as String).existsSync(), isTrue);
  });

  test('the snapshot covers the 1.4.0 owner message with files', () {
    final user =
        (events['payloads'] as Map)['message.user'] as Map<String, dynamic>;
    expect(user['required'], containsAll(['text', 'thread_id']));
    expect(user['optional'], contains('attachments'));
    expect(kindsByActor['user'], contains('message.user'));
  });

  group('every event kind the server can write is read in its room log', () {
    for (final MapEntry(key: actorKind, value: kinds) in kindsByActor.entries) {
      for (final kind in kinds) {
        for (final (label, payload) in _payloads(kind)) {
          test('$kind ($label)', () {
            final page = _readLog([
              _event(
                seq: 1,
                kind: kind,
                actor: _fullActor(actorKind),
                payload: payload,
              ),
            ]);

            final event = page.events.single;
            expect(event.kind, kind);
            expect(event.eventId, 'event-1');
            expect(event.actor.kind, actorKind);
            if (kind == 'message.user' || kind == 'message.member') {
              expect(event.publicText, _text);
              expect(event.threadId, _threadId);
              final sent = _maps(payload['attachments']).toList();
              expect(event.attachmentsRejected, isFalse);
              expect(
                [for (final file in event.attachments) file.attachmentId],
                [for (final file in sent) file['attachment_id']],
              );
              expect(
                [for (final file in event.attachments) file.kind],
                [for (final file in sent) file['kind']],
              );
            }
          });
        }
      }
    }
  });

  test('an owner message at the server text limit is read whole', () {
    final text = 'a' * _limit('user_text_bytes');
    final page = _readLog([
      _event(
        seq: 1,
        kind: 'message.user',
        actor: _fullActor('user'),
        payload: {'text': text, 'thread_id': _threadId},
      ),
    ]);

    expect(page.events.single.publicText, text);
  });

  test('an owner message with only files is read with an empty text', () {
    final page = _readLog([
      _event(
        seq: 1,
        kind: 'message.user',
        actor: _fullActor('user'),
        payload: {
          'text': '',
          'thread_id': _threadId,
          'attachments': _fullManifest(),
        },
      ),
    ]);

    final event = page.events.single;
    expect(event.publicText, '');
    expect(event.attachments, hasLength(_limit('attachments_per_message')));
  });

  test('every roster row the server can store is read', () {
    final roster = _roster();
    final room = HostedGroupRoom.fromJson({
      'room_id': _roomId,
      'name': 'Room',
      'members': roster,
      'authority_gateway_id': _gatewayId,
      'authority_epoch': 1,
      'revision': 1,
      'created_at': 1700000000.0,
      'updated_at': 1700000000.5,
      'idempotent': false,
      'latest_seq': 0,
    });

    expect([for (final member in room.members) member.memberId], [
      for (final row in roster) row['member_id'],
    ]);
    expect(
      [for (final member in room.members) member.owner.profile],
      [for (final row in roster) row['profile']],
    );
  });

  final consumers = _consumers(contract);

  group('every groups.* result shape of the contract is read', () {
    for (final MapEntry(key: method, value: schema) in consumers.entries) {
      test(method, () {
        final failures = <String>[];
        for (final sample in _samples(sampler, schema)) {
          final result = _coherent(method, sample.value);
          for (final rule in _contractOnly) {
            rule.rewrite(result);
          }
          final failure = _failure(method, result);
          if (failure != null) failures.add('$failure ${sample.label}');
        }
        expect(failures, isEmpty, reason: failures.join('\n'));
      });
    }
  });

  test('every contract-only form is still one Console refuses', () {
    // A rule Console no longer needs is dropped from [_contractOnly], so the
    // list keeps naming only real differences between schema and server.
    final unused = <String>[];
    for (final rule in _contractOnly) {
      var refused = false;
      for (final MapEntry(key: method, value: schema) in consumers.entries) {
        for (final sample in _samples(sampler, schema)) {
          final result = _coherent(method, sample.value);
          for (final other in _contractOnly) {
            if (!identical(other, rule)) other.rewrite(result);
          }
          final before = jsonEncode(result);
          final rewritten = jsonDecode(before) as Map<String, dynamic>;
          rule.rewrite(rewritten);
          if (jsonEncode(rewritten) == before) continue;
          if (_failure(method, rewritten) == null &&
              _failure(method, result) != null) {
            refused = true;
          }
        }
      }
      if (!refused) unused.add('${rule.name}: ${rule.reason}');
    }
    expect(unused, isEmpty, reason: unused.join('\n'));
  });
}
