import 'package:flutter_test/flutter_test.dart';
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

void main() {
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
