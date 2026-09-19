import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bot_profile_client.dart';
import 'package:hermes_android/core/services/bot_section_service.dart';

void main() {
  test(
    'partial duplicate retries the existing copy without creating another profile',
    () async {
      var creates = 0, saves = 0;
      final client = BotProfileClient((method, params) async {
        if (method == 'profiles.list') {
          return {
            'profiles': [
              {'name': 'bot'},
              if (creates > 0)
                {
                  'name': 'bot-2',
                  'ui_meta': {
                    'hermes-bots': {'chat': 'old', 'opaque': true},
                  },
                },
            ],
          };
        }
        if (method == 'profiles.create') {
          creates++;
          return {'ok': true};
        }
        saves++;
        if (saves == 1) throw StateError('disconnect');
        final meta = (params['ui_meta'] as Map)['hermes-bots'] as Map;
        expect(meta.containsKey('chat'), false);
        expect(meta['opaque'], true);
        return {
          'applied': {'ui_meta': true},
        };
      });
      await expectLater(
        client.duplicateBotProfile('bot'),
        throwsA(isA<BotDuplicateIncomplete>()),
      );
      expect(await client.duplicateBotProfile('bot'), 'bot-2');
      expect(creates, 1);
      expect(saves, 2);
    },
  );
  test(
    'avatar generation probes and refuses URLs, SVG, and unsupported servers',
    () async {
      final client = BotProfileClient((method, params) async {
        expect(method, 'image.generate');
        if (params['probe'] == true) return {'available': true};
        expect(params['max_bytes'], 2000000);
        return {'success': true, 'image': 'https://provider.invalid/image'};
      });
      expect(await client.canGenerateBotAvatar(), true);
      await expectLater(
        client.generateBotAvatar('A calm owl'),
        throwsStateError,
      );
      final absent = BotProfileClient(
        (_, _) async => throw StateError('unknown'),
      );
      expect(await absent.canGenerateBotAvatar(), false);
      await expectLater(client.generateBotAvatar(' '), throwsFormatException);
    },
  );
  test('section name limits and Desktop-compatible IDs', () {
    expect(() => BotSectionChange.create('x' * 41), throwsFormatException);
    expect(() => BotSectionChange.create('bad\nname'), throwsFormatException);
    expect(
      BotSectionChange.create(' Team ').id,
      matches(r'^sec-[0-9a-z]+-[0-9a-z]{1,5}$'),
    );
  });

  test(
    'CAS conflict rereads and preserves concurrent unknown fields',
    () async {
      var reads = 0;
      final writes = <Map<String, dynamic>>[];
      final client = BotProfileClient((method, params) async {
        if (method == 'profiles.list') {
          reads++;
          return {
            'profiles': [
              {
                'name': 'bot',
                'ui_meta_revisions': {'hermes-bots': reads},
                'ui_meta': {
                  'hermes-bots': {
                    'future': {'nested': reads},
                    'pinned': true,
                    'image': 'legacy',
                    'pet': 'legacy',
                  },
                },
              },
            ],
          };
        }
        writes.add(params);
        return {
          'ok': writes.length > 1,
          'applied': writes.length == 1
              ? {
                  'ui_meta': false,
                  'ui_meta_conflicts': {
                    'hermes-bots': {'actual': 2},
                  },
                }
              : {'ui_meta': true},
        };
      });
      await client.patchBotMetadata('bot', {
        'sectionId': 'sec-a',
        'sectionName': 'Team',
      });
      expect(reads, 2);
      expect(writes.last['ui_meta_expected_revisions'], {'hermes-bots': 2});
      expect(writes.last['ui_meta'], {
        'hermes-bots': {
          'future': {'nested': 2},
          'pinned': true,
          'sectionId': 'sec-a',
          'sectionName': 'Team',
        },
      });
    },
  );

  test('old servers omit CAS and remove uses two explicit nulls', () async {
    Map<String, dynamic>? write;
    final client = BotProfileClient((method, params) async {
      if (method == 'profiles.list') {
        return {
          'profiles': [
            {
              'name': 'bot',
              'ui_meta': {
                'other': {'opaque': true},
                'hermes-bots': {'title': 'Old', 'unknown': 1},
              },
            },
          ],
        };
      }
      write = params;
      return {
        'ok': true,
        'applied': {'ui_meta': true},
      };
    });
    await client.patchBotMetadata(
      'bot',
      const BotSectionChange(null, null).patch,
      remove: {'title'},
    );
    expect(write!.containsKey('ui_meta_expected_revisions'), false);
    expect(write!['ui_meta'], {
      'hermes-bots': {'unknown': 1, 'sectionId': null, 'sectionName': null},
    });
  });

  test('new server without namespace starts at revision zero', () async {
    final client = BotProfileClient((method, params) async {
      if (method == 'profiles.list') {
        return {
          'profiles': [
            {'name': 'bot', 'ui_meta_revisions': {}},
          ],
        };
      }
      expect(params['ui_meta_expected_revisions'], {'hermes-bots': 0});
      return {
        'ok': true,
        'applied': {'ui_meta': true},
      };
    });
    await client.patchBotMetadata('bot', {'pinned': false});
  });

  test('conflicts bounded, ambiguous failures not retried', () async {
    var writes = 0;
    final client = BotProfileClient((method, params) async {
      if (method == 'profiles.list') {
        return {
          'profiles': [
            {'name': 'bot', 'ui_meta_revisions': {}},
          ],
        };
      }
      writes++;
      return {
        'applied': {
          'ui_meta': false,
          'ui_meta_conflicts': {'hermes-bots': {}},
        },
      };
    });
    await expectLater(
      client.patchBotMetadata('bot', {'pinned': true}),
      throwsStateError,
    );
    expect(writes, 3);
    writes = 0;
    final failed = BotProfileClient((method, params) async {
      if (method == 'profiles.list') {
        return {
          'profiles': [
            {'name': 'bot'},
          ],
        };
      }
      writes++;
      throw StateError('Lost response');
    });
    await expectLater(
      failed.patchBotMetadata('bot', {'hidden': true}),
      throwsStateError,
    );
    expect(writes, 1);
  });

  test(
    'rejects malformed, missing, duplicate and oversized metadata before writing',
    () async {
      for (final rows in [
        <Object?>[],
        [
          {'name': 'bot'},
          {'name': 'bot'},
        ],
        [
          {
            'name': 'bot',
            'ui_meta': {'hermes-bots': 'bad'},
          },
        ],
        [
          {
            'name': 'bot',
            'ui_meta_revisions': {'hermes-bots': -1},
          },
        ],
        [
          {
            'name': 'bot',
            'ui_meta': {
              'hermes-bots': {'large': 'é' * 11000},
            },
          },
        ],
      ]) {
        final client = BotProfileClient((method, params) async {
          expect(method, 'profiles.list');
          return {'profiles': rows};
        });
        await expectLater(
          client.patchBotMetadata('bot', {'pinned': true}),
          throwsA(anything),
        );
      }
      expect(BotProfileClient.pythonJsonLength({'x': '😀é'}), 27);
    },
  );

  test(
    'partial section result lists failures and retry only touches failures',
    () async {
      final written = <String>[];
      var failing = true;
      final client = BotProfileClient((method, params) async {
        if (method == 'profiles.list') {
          return {
            'profiles': [
              {'name': 'a'},
              {'name': 'b'},
            ],
          };
        }
        written.add(params['name'] as String);
        if (params['name'] == 'b' && failing) throw StateError('Unavailable');
        return {
          'applied': {'ui_meta': true},
        };
      });
      final service = BotSectionService('local', client);
      final section = BotSectionChange.create(' Team ');
      expect(section.id, matches(r'^sec-[a-z0-9]+-[a-z0-9]{1,5}$'));
      final result = await service.apply('local', {'a': section, 'b': section});
      expect(result.succeeded.keys, ['a']);
      expect(result.failed.keys, ['b']);
      failing = false;
      await service.apply('local', result.failed);
      expect(written, ['a', 'b', 'b']);
      await expectLater(
        service.apply('remote', {'a': section}),
        throwsStateError,
      );
      expect(written, ['a', 'b', 'b']);
    },
  );

  test(
    'duplicate uses full clone and never copies a canonical chat pointer',
    () async {
      final writes = <Map<String, dynamic>>[];
      final client = BotProfileClient((method, params) async {
        if (method == 'profiles.list') {
          return {
            'profiles': [
              {
                'name': 'bot',
                'description': 'Role',
                'ui_meta': {
                  'hermes-bots': {'title': 'Friend'},
                },
              },
              if (writes.isNotEmpty)
                {
                  'name': 'bot-2',
                  'ui_meta': {
                    'hermes-bots': {'chat': 'old', 'shape': 'star'},
                  },
                },
            ],
          };
        }
        writes.add(params);
        return {
          'ok': true,
          'applied': {'ui_meta': true},
        };
      });
      expect(await client.duplicateBotProfile('bot'), 'bot-2');
      expect(writes.first['clone_all'], true);
      expect(writes.first['mirror_credentials'], false);
      final meta = writes.last['ui_meta']['hermes-bots'] as Map;
      expect(meta.containsKey('chat'), false);
      expect(meta['shape'], 'star');
      expect(meta['title'], 'Friend (copy)');
    },
  );
}
