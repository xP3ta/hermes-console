import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_sections.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/models/room_mirror.dart';

const mirrorPng =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';

HostedGroupRoom parityRoom({String id = 'room-one', String name = 'Shared'}) =>
    HostedGroupRoom.fromJson({
      'room_id': id,
      'name': name,
      'members': [],
      'authority_gateway_id': 'gateway-test',
      'authority_epoch': 1,
      'revision': 1,
      'created_at': 1,
      'updated_at': 1,
    });

AgentProfile mirroredProfile(Object? rooms, {String name = 'default'}) =>
    AgentProfile.fromJson({
      'name': name,
      'ui_meta': {
        'hermes-bots-groups': {'version': 3, 'rooms': rooms},
      },
    });

MissionAgent _agent(String name, [Map<String, dynamic> meta = const {}]) =>
    MissionAgent(
      profile: AgentProfile(name: name, botModeUiMeta: meta),
      status: MissionAgentStatus.idle,
      statusEvidence: '',
      usage: const MissionUsage(),
    );

void main() {
  test(
    'section strings are bounded, nullable and preserve opaque metadata',
    () {
      final profile = AgentProfile.fromJson({
        'name': 'builder',
        'ui_meta': {
          'hermes-bots': {
            'sectionId': ' sec-team ',
            'sectionName': ' Equipo ',
            'future': {'keep': true},
          },
        },
      });
      expect(profile.botSectionId, 'sec-team');
      expect(profile.botSectionName, 'Equipo');
      expect(profile.botModeUiMeta['future'], {'keep': true});
      for (final raw in [
        null,
        false,
        12,
        [],
        {},
        '',
        '  ',
        'a\nb',
        'x' * 129,
      ]) {
        final bad = AgentProfile(
          name: 'builder',
          botModeUiMeta: {'sectionId': raw, 'sectionName': raw},
        );
        expect(bad.botSectionId, isNull);
        expect(bad.botSectionName, isNull);
      }
      expect(
        AgentProfile(
          name: 'builder',
          botModeUiMeta: {'sectionId': 'x' * 128, 'sectionName': 'ñ' * 128},
        ).botSectionName,
        hasLength(128),
      );
    },
  );

  test(
    'sections use ids, alphabetical names, stable collisions and loose last',
    () {
      final rows = [
        _agent('loose'),
        _agent('z', {'sectionId': 'z', 'sectionName': 'Zulu'}),
        _agent('a', {'sectionId': 'a', 'sectionName': 'Alpha'}),
        _agent('b', {'sectionId': 'b', 'sectionName': 'Alpha'}),
        _agent('legacy', {'sectionId': 'missing'}),
        _agent('rename', {'sectionId': 'z', 'sectionName': 'Zebra'}),
      ];
      final groups = groupBotSections(rows, rows);
      expect(groups.map((g) => g.id), ['a', 'b', 'z', null]);
      expect(groups.map((g) => g.name), ['Alpha', 'Alpha', 'Zebra', null]);
      expect(groups[2].agents.map((a) => a.profile.name), ['z', 'rename']);
      expect(groups.last.agents.map((a) => a.profile.name), [
        'loose',
        'legacy',
      ]);
      expect(
        groupBotSections(rows, rows.reversed).map((g) => g.name),
        groups.map((g) => g.name),
      );
      expect(groupBotSections([rows.first], [rows.first]).single.id, isNull);
      expect(groupBotSections([rows[1]], [rows[1]]).single.name, 'Zulu');
      expect(groupBotSections([], rows), isEmpty);
    },
  );

  test(
    'mirror parses only default v3 identities, never messages or members',
    () {
      final entry = {
        'roomId': 'room-one',
        'name': 'Team',
        'image': mirrorPng,
        'log': 'untrusted',
        'members': false,
      };
      final parsed = mirroredProfile({'id:room-one': entry});
      expect(parsed.roomMirror.rooms.single.name, 'Team');
      expect(parsed.roomMirror.rooms.single.image!.width, 1);
      expect(
        mirroredProfile({'id:room-one': entry}, name: 'other').roomMirror.rooms,
        isEmpty,
      );
      for (final raw in [
        null,
        false,
        [],
        {},
        {'version': 4, 'rooms': {}},
        {'version': 3, 'rooms': []},
      ]) {
        expect(RoomMirror.parse(raw).rooms, isEmpty);
      }
      expect(
        mirroredProfile({
          'bad': null,
          'wrong': 42,
          'empty': {},
        }).roomMirror.rooms,
        isEmpty,
      );
      expect(
        mirroredProfile({
          for (var i = 0; i <= RoomMirror.maxRooms; i++) '$i': entry,
        }).roomMirror.rooms,
        isEmpty,
      );
    },
  );

  test(
    'mirror rejects oversized, non-image, mismatched and corrupt pictures',
    () {
      final pngBytes = base64Decode(mirrorPng.split(',').last);
      final huge = [...pngBytes]..setRange(16, 20, [0, 0, 32, 0]);
      for (final image in [
        null,
        false,
        {},
        'https://example.invalid/image.png',
        'data:image/svg+xml;base64,PHN2Zy8+',
        mirrorPng.replaceFirst('image/png', 'image/jpeg'),
        'data:image/png;base64,!!!!',
        'x' * 24001,
        'data:image/png;base64,${base64Encode(huge)}',
      ]) {
        final mirror = mirroredProfile({
          'a': {'name': 'Team', 'image': image},
        }).roomMirror;
        expect(mirror.rooms.single.image, isNull);
        expect(mirror.rooms.single.name, 'Team');
      }
      final largeImage =
          'data:image/png;base64,${base64Encode([...pngBytes, ...List.filled(17000, 0)])}';
      final budgeted = mirroredProfile({
        for (var i = 0; i < 4; i++)
          '$i': {'name': 'Team $i', 'image': largeImage},
      }).roomMirror;
      expect(budgeted.rooms.where((r) => r.image != null), hasLength(2));
    },
  );

  test('mirror id wins over display name, duplicates fail closed', () {
    final room = parityRoom();
    RoomMirror parse(Map<String, Object?> entries) =>
        mirroredProfile(entries).roomMirror;
    expect(
      parse({
        'one': {'roomId': room.roomId, 'name': 'Renamed'},
        'two': {'name': room.name},
      }).match(room, [room])!.name,
      'Renamed',
    );
    expect(
      parse({
        'one': {'roomId': room.roomId},
        'two': {'roomId': room.roomId},
      }).match(room, [room]),
      isNull,
    );
    expect(
      parse({
        'one': {'name': room.name},
      }).match(room, [room]),
      isNotNull,
    );
    expect(
      parse({
        'one': {'name': room.name.toLowerCase()},
      }).match(room, [room]),
      isNull,
    );
    expect(
      parse({
        'one': {'name': room.name},
      }).match(room, [room, parityRoom(id: 'other')]),
      isNull,
    );
    expect(
      parse({
        'one': {'name': room.name},
        'two': {'name': room.name},
      }).match(room, [room]),
      isNull,
    );
    expect(
      parse({
        'one': {'roomId': 'different', 'name': room.name},
      }).match(room, [room]),
      isNull,
    );
  });

  test('malformed identity fields never enable a name fallback', () {
    final room = parityRoom();
    for (final id in [false, 1, [], {}, '', 'x' * 129, 'bad\nvalue']) {
      final mirror = mirroredProfile({
        'one': {'roomId': id, 'name': room.name},
      }).roomMirror;
      expect(mirror.match(room, [room]), isNull);
    }
    for (final name in [false, [], {}, '', 'x' * 65, 'bad\nvalue']) {
      final mirror = mirroredProfile({
        'one': {'roomId': room.roomId, 'name': name},
      }).roomMirror;
      expect(mirror.match(room, [room])!.name, isNull);
    }
  });

  test('mirror tombstones suppress identity without removing hosted rooms', () {
    final room = parityRoom();
    for (final revision in [1, 2, 3, null]) {
      final mirror = RoomMirror.parse({
        'version': 3,
        'deleted': {'id:room-one': 2},
        'rooms': {
          'id:room-one': {'roomId': room.roomId, 'revision': revision},
        },
      });
      expect(mirror.match(room, [room]), isNull);
    }
    final mirror = RoomMirror.parse({
      'version': 3,
      'deleted': {'name:Shared': 2},
      'rooms': {
        'name:Shared': {'name': room.name, 'revision': 3},
      },
    });
    expect(mirror.match(room, [room]), isNotNull);
  });
}
