import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/data/desktop_projection_rooms.dart';
import 'package:hermes_android/core/bots/state/bot_roster_meta.dart';
import 'package:hermes_android/core/services/bot_profile_client.dart';

import '../support/spec070_fixtures.dart';

final class _RecordingProfileGateway implements BotProfileGateway {
  final patches = <(String, Map<String, dynamic>, Set<String>)>[];

  @override
  Future<void> patchBotMetadata(
    String profile,
    Map<String, dynamic> patch, {
    Set<String> remove = const {},
  }) async => patches.add((profile, patch, remove));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Object? projection() =>
    spec070Profiles().singleWhere((p) => p.name == 'default').groupsProjection;

void main() {
  group('DesktopProjectionRooms (ui_meta hermes-bots-groups v3)', () {
    test('parses rooms, excludes hosted twins and tombstones', () {
      final rooms = DesktopProjectionRooms.parse(
        projection(),
        hostedRoomIds: {'room-devs'},
      );
      expect(rooms.rooms.map((r) => r.roomId), ['room-desktop-1']);
      final room = rooms.rooms.single;
      expect(room.readOnly, isTrue);
      expect(room.name, 'Hermes Console · Equipo');
      expect(room.memberNames, ['astra', 'radar']);
      expect(room.omitted, 40);
      expect(room.lastMessage?.from.name, 'astra');
      expect(room.needsYou, isTrue);
      expect(rooms.updatedAt, isNotNull);
    });

    test('without hosted ids the twin shows too, sorted by recency', () {
      final rooms = DesktopProjectionRooms.parse(projection());
      expect(rooms.rooms.map((r) => r.roomId), ['room-desktop-1', 'room-devs']);
    });

    test('bounds recent messages and counts dropped ones as omitted', () {
      final rooms = DesktopProjectionRooms.parse(
        projection(),
        hostedRoomIds: {'room-devs'},
        maxMessages: 1,
      );
      final room = rooms.rooms.single;
      expect(room.messages, hasLength(1));
      expect(room.omitted, 41);
    });

    test('rejects other versions and malformed envelopes', () {
      expect(DesktopProjectionRooms.parse(null).rooms, isEmpty);
      expect(
        DesktopProjectionRooms.parse({'version': 2, 'rooms': {}}).rooms,
        isEmpty,
      );
      final rooms = DesktopProjectionRooms.parse({
        'version': 3,
        'rooms': {
          'id:x': {
            'roomId': 'x',
            'name': 'ok',
            'log': [
              1,
              {'from': {}},
            ],
          },
          'id:y': 'bad',
        },
      });
      expect(rooms.rooms.single.messages, isEmpty);
    });

    test('user reply clears needsYou', () {
      final rooms = DesktopProjectionRooms.parse({
        'version': 3,
        'rooms': {
          'id:x': {
            'roomId': 'x',
            'name': 'r',
            'log': [
              {
                'from': {'kind': 'member', 'name': 'a'},
                'text': '@user?',
                'at': 1,
              },
              {
                'from': {'kind': 'user', 'name': 'You'},
                'text': 'yes',
                'at': 2,
              },
            ],
          },
        },
      });
      expect(rooms.rooms.single.needsYou, isFalse);
    });
  });

  group('BotRosterMeta', () {
    test('reads Desktop keys from ui_meta hermes-bots', () {
      final profiles = spec070Profiles();
      final hermes = BotRosterMeta.of(profiles.first);
      expect(hermes.pinned, isTrue);
      expect(hermes.sectionId, 'sec-core');
      expect(hermes.sectionName, 'Core');
      expect(BotRosterMeta.of(profiles.last).hidden, isTrue);
    });

    test(
      'writes through patchBotMetadata and drops the legacy chat pin',
      () async {
        final gateway = _RecordingProfileGateway();
        final writer = BotRosterMetaWriter(gateway);
        await writer.setPinned('astra', true);
        await writer.setHidden('radar', false);
        await writer.setSection('astra', id: 'sec-1', name: 'Ops');
        expect(gateway.patches.map((p) => p.$2), [
          {'pinned': true},
          {'hidden': false},
          {'sectionId': 'sec-1', 'sectionName': 'Ops'},
        ]);
        expect(gateway.patches.every((p) => p.$3.contains('chat')), isTrue);
      },
    );
  });
}
