import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bot_room_link.dart';
import 'botmode_parity_model_test.dart' show parityRoom;

Map<String, dynamic> _catalog() => {
  'installation_id': 'target',
  'catalog_digest': 'a' * 64,
  'protocol_versions': [2],
  'link_modes': ['direct'],
  'persistent_process': true,
  'text': true,
  'attachments': false,
  'execution_policy': {'target_profile': 'bot'},
  'endpoint': {'available': true, 'url': 'https://target.invalid'},
};
Map<String, dynamic> _caps(Map<String, dynamic> catalog) => {
  'methods': ['groups.peer.invite', 'groups.peer.revoke'],
  'room_link': {'enabled': true, 'profile': 'bot', 'catalog': catalog},
};
void main() {
  test(
    'discovery requires profile-scoped direct v2 capability and secure endpoint',
    () {
      final catalog = _catalog();
      expect(BotRoomLink.catalog(_caps(catalog), 'bot'), isNotNull);
      expect(BotRoomLink.catalog(_caps(catalog), 'another'), isNull);
      for (final bad in [
        {
          ...catalog,
          'protocol_versions': [1],
        },
        {...catalog, 'persistent_process': false},
        {
          ...catalog,
          'link_modes': ['relay'],
        },
        {
          ...catalog,
          'endpoint': {'available': true, 'url': 'http://remote.invalid'},
        },
        {
          ...catalog,
          'endpoint': {
            'available': true,
            'url': 'https://target.invalid/?secret=x',
          },
        },
      ]) {
        expect(BotRoomLink.catalog(_caps(bad), 'bot'), isNull);
      }
      expect(BotRoomLink.catalog({}, 'bot'), isNull);
    },
  );
  for (final fail in [false, true]) {
    test(
      'grant is scoped to room authority and member; registration failure revokes=$fail',
      () async {
        final events = <String>[];
        final catalog = _catalog();
        final link = BotRoomLink((method, params) async {
          events.add(method);
          if (method == 'groups.capabilities') {
            return {
              'driver': true,
              'authority_gateway_id': 'gateway-test',
              'methods': ['groups.peer.register'],
            };
          }
          expect(params.keys.toSet(), {
            'room_id',
            'member_id',
            'target_profile',
            'catalog',
            'grant',
            'target_url',
          });
          expect(params['grant'], 'opaque-scoped-grant');
          expect(params['member_id'], 'm1');
          if (fail) throw StateError('offline');
          return {
            'registered': true,
            'target_profile': 'bot',
            'target_install_id': 'target',
          };
        });
        final future = link.attach(
          room: parityRoom(),
          memberId: 'm1',
          profile: 'bot',
          expectedCatalog: catalog,
          target: (method, params) async {
            events.add(method);
            if (method == 'groups.capabilities') return _caps(catalog);
            if (method == 'groups.peer.revoke') {
              expect(params, {
                'profile': 'bot',
                'grant': 'opaque-scoped-grant',
              });
              return {'revoked': true};
            }
            expect(params, {
              'profile': 'bot',
              'room_id': 'room-one',
              'member_id': 'm1',
              'home_install_id': 'gateway-test',
              'authority_gateway_id': 'gateway-test',
              'authority_epoch': 1,
            });
            return {
              'grant': 'opaque-scoped-grant',
              'catalog': catalog,
              'target_profile': 'bot',
            };
          },
        );
        if (fail) {
          await expectLater(future, throwsStateError);
        } else {
          await future;
        }
        expect(events, [
          'groups.capabilities',
          'groups.capabilities',
          'groups.peer.invite',
          'groups.peer.register',
          if (fail) 'groups.peer.revoke',
        ]);
      },
    );
  }
  test('changed catalog or authority never mints a grant', () async {
    var calls = 0;
    final link = BotRoomLink(
      (m, p) async => {
        'driver': true,
        'authority_gateway_id': 'gateway-test',
        'methods': ['groups.peer.register'],
      },
    );
    await expectLater(
      link.attach(
        room: parityRoom(),
        memberId: 'm',
        profile: 'bot',
        expectedCatalog: _catalog(),
        target: (method, p) async {
          calls++;
          expect(method, 'groups.capabilities');
          return _caps({..._catalog(), 'catalog_digest': 'b' * 64});
        },
      ),
      throwsStateError,
    );
    expect(calls, 1);
  });
}
