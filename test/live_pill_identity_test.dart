// The island speaks for the profile you talk to, the main one included:
// its title, else its display name, and «Hermes» only when it has neither;
// and the main profile keeps Hermes' sprite only while the roster gives it
// no name or face of its own.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';

BotRosterStore _store(List<AgentProfile> profiles) {
  final registry = BotRosterRegistry();
  registry.publish('conn', 'QA', profiles);
  return registry.store('conn');
}

void main() {
  test('the main profile\'s title is the island\'s name, not «Hermes»', () {
    final store = _store(const [
      AgentProfile(
        name: 'default',
        isDefault: true,
        displayName: 'Principal',
        botModeUiMeta: {'title': 'Luna'},
      ),
    ]);
    expect(islandProfileNameFor(store, null), 'Luna');
  });

  test('without a title the main profile\'s display name is used', () {
    final store = _store(const [
      AgentProfile(name: 'default', isDefault: true, displayName: 'Atenea'),
    ]);
    expect(islandProfileNameFor(store, null), 'Atenea');
  });

  test('«Hermes» only when the main profile has no name at all', () {
    expect(islandProfileNameFor(null, null), 'Hermes');
    expect(
      islandProfileNameFor(
        _store(const [AgentProfile(name: 'default', isDefault: true)]),
        null,
      ),
      'Hermes',
    );
  });

  test('a named profile: title, else display name, else its own name', () {
    final store = _store(const [
      AgentProfile(
        name: 'forja',
        botModeUiMeta: {'title': 'Forja'},
        displayName: 'x',
      ),
      AgentProfile(name: 'bob', displayName: 'Roberto'),
      AgentProfile(name: 'ana'),
    ]);
    expect(islandProfileNameFor(store, 'forja'), 'Forja');
    expect(islandProfileNameFor(store, 'bob'), 'Roberto');
    expect(islandProfileNameFor(store, 'ana'), 'ana');
    expect(islandProfileNameFor(store, 'ghost'), 'ghost');
  });

  test('the main profile is found by its flag when it is not called '
      '«default»', () {
    final store = _store(const [
      AgentProfile(name: 'hermes', isDefault: true, displayName: 'Hestia'),
    ]);
    expect(islandProfileNameFor(store, null), 'Hestia');
  });

  test('the sprite stays only while the main profile has no name or face', () {
    expect(
      mainRosterProfile(
        _store(const [AgentProfile(name: 'default', isDefault: true)]),
        onlyIfDressed: true,
      ),
      isNull,
    );
    for (final dressed in const [
      AgentProfile(name: 'default', isDefault: true, displayName: 'Luna'),
      AgentProfile(
        name: 'default',
        isDefault: true,
        botModeUiMeta: {'title': 'Luna'},
      ),
      AgentProfile(
        name: 'default',
        isDefault: true,
        botModeUiMeta: {'shape': 'blobatar::round'},
      ),
      AgentProfile(name: 'default', isDefault: true, hasAvatar: true),
    ]) {
      expect(
        mainRosterProfile(_store([dressed]), onlyIfDressed: true),
        isNotNull,
        reason: '$dressed',
      );
    }
  });
}
