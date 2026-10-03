import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/bot_mention_roster.dart';
import 'package:hermes_android/core/services/bot_roster_cache.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<String> names(BotRosterStore store) => [
  for (final p in store.profiles) p.name,
];

final connection = SavedConnection(
  id: 'c',
  label: 'C',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

void main() {
  test('a late, older response never overwrites a newer roster', () {
    final registry = BotRosterRegistry();
    final older = registry.beginRead('c');
    final newer = registry.beginRead('c');
    expect(
      registry.publish('c', 'C', const [
        AgentProfile(name: 'renamed'),
      ], ticket: newer),
      isTrue,
    );
    expect(
      registry.publish('c', 'C', const [
        AgentProfile(name: 'old'),
      ], ticket: older),
      isFalse,
    );
    expect(names(registry.store('c')), ['renamed']);
  });

  test('responses landing in start order are all accepted', () {
    final registry = BotRosterRegistry();
    final first = registry.beginRead('c');
    final second = registry.beginRead('c');
    registry.publish('c', 'C', const [AgentProfile(name: 'a')], ticket: first);
    registry.publish('c', 'C', const [AgentProfile(name: 'b')], ticket: second);
    expect(names(registry.store('c')), ['b']);
  });

  test('a read started before a confirmed mutation cannot undo it', () {
    final registry = BotRosterRegistry();
    registry.publish('c', 'C', const [
      AgentProfile(name: 'ops'),
      AgentProfile(name: 'gone'),
    ]);
    final inFlight = registry.beginRead('c');
    registry.profileRenamed('c', 'ops', 'ops2');
    registry.profileDeleted('c', 'gone');
    registry.profileCreated('c', const AgentProfile(name: 'fresh'));
    expect(names(registry.store('c')), ['ops2', 'fresh']);
    expect(
      registry.publish('c', 'C', const [
        AgentProfile(name: 'ops'),
        AgentProfile(name: 'gone'),
      ], ticket: inFlight),
      isFalse,
    );
    expect(names(registry.store('c')), ['ops2', 'fresh']);
    // A read started afterwards is authoritative again.
    registry.publish('c', 'C', const [
      AgentProfile(name: 'ops2'),
    ], ticket: registry.beginRead('c'));
    expect(names(registry.store('c')), ['ops2']);
  });

  test('a mutation outranks reads in flight even with nothing loaded', () {
    final registry = BotRosterRegistry();
    final inFlight = registry.beginRead('c');
    registry.profileDeleted('c', 'ops');
    expect(
      registry.publish('c', 'C', const [
        AgentProfile(name: 'ops'),
      ], ticket: inFlight),
      isFalse,
    );
  });

  test('forget strands reads that started before it', () {
    final registry = BotRosterRegistry();
    registry.publish('c', 'C', const [AgentProfile(name: 'a')]);
    final inFlight = registry.beginRead('c');
    registry.forget('c');
    expect(registry.store('c').snapshot, isNull);
    registry.publish('c', 'C', const [
      AgentProfile(name: 'a'),
    ], ticket: inFlight);
    expect(registry.store('c').snapshot, isNull);
  });

  test('every store listener sees a mutation in the same call', () {
    final registry = BotRosterRegistry();
    registry.publish('c', 'C', const [AgentProfile(name: 'ops')]);
    final seenByA = <List<String>>[];
    final seenByB = <List<String>>[];
    registry
        .store('c')
        .addListener(() => seenByA.add(names(registry.store('c'))));
    registry
        .store('c')
        .addListener(() => seenByB.add(names(registry.store('c'))));
    registry.profileRenamed('c', 'ops', 'ops2');
    expect(seenByA, [
      ['ops2'],
    ]);
    expect(seenByB, [
      ['ops2'],
    ]);
  });

  test('cold start shows the cached roster until a live read lands', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await BotRosterCache(prefs).write(connection, const [
      AgentProfile(name: 'cached', botModeUiMeta: {'title': 'Cached'}),
    ]);
    final registry = BotRosterRegistry()
      ..attachPersistence(prefs, [connection]);
    final store = registry.store('c');
    expect(names(store), ['cached']);
    expect(store.isLive, isFalse);
    expect(store.profile('cached')!.botTitle, 'Cached');
    // Cache is display data only: no routable mention identities yet.
    final mentions = BotMentionRoster(registry);
    expect(mentions.contains('c'), isFalse);
    expect(mentions.bots('c'), isEmpty);
    expect(mentions.profileFor('c', 'cached'), isNotNull);

    registry.publish('c', 'C', const [
      AgentProfile(name: 'live'),
    ], ticket: registry.beginRead('c'));
    expect(names(store), ['live']);
    expect(store.isLive, isTrue);
    expect(mentions.contains('c'), isTrue);
    await pumpEventQueue();
    // Accepted rosters persist for the next cold start.
    expect(
      BotRosterRegistry()
          .let((r) => r..attachPersistence(prefs, [connection]))
          .store('c')
          .profiles
          .single
          .name,
      'live',
    );
    mentions.dispose();
  });

  test('a forgotten connection stops persisting until re-registered', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final registry = BotRosterRegistry()
      ..attachPersistence(prefs, [connection]);
    registry.forget('c');
    registry.publish('c', 'C', const [AgentProfile(name: 'a')]);
    await pumpEventQueue();
    expect(BotRosterCache(prefs).read(connection), isEmpty);
    final moved = connection.copyWith(host: 'other.local');
    registry.hydrate(moved);
    registry.publish('c', 'C', const [AgentProfile(name: 'b')]);
    await pumpEventQueue();
    expect(BotRosterCache(prefs).read(moved).single.name, 'b');
  });

  test('a mutation on a cached roster keeps it display-only', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await BotRosterCache(
      prefs,
    ).write(connection, const [AgentProfile(name: 'cached')]);
    final registry = BotRosterRegistry()
      ..attachPersistence(prefs, [connection]);
    registry.profileRenamed('c', 'cached', 'moved');
    expect(names(registry.store('c')), ['moved']);
    expect(registry.store('c').isLive, isFalse);
  });

  test('a sessionless read keeps session projections of surviving bots', () {
    final registry = BotRosterRegistry();
    final worker = AgentProfile.fromJson({
      'name': 'ops',
      'worker_session': {
        'id': 'w',
        'source': 'kanban',
        'title': 't',
        'last_active': 1,
      },
    });
    registry.publish('c', 'C', [worker, const AgentProfile(name: 'gone')]);
    registry.publish('c', 'C', const [
      AgentProfile(name: 'ops', displayName: 'Ops'),
      AgentProfile(name: 'new'),
    ]);
    final store = registry.store('c');
    expect(names(store), ['ops', 'new']);
    expect(store.profile('ops')!.displayName, 'Ops');
    expect(store.profile('ops')!.workerSession?.id, 'w');
    expect(store.profile('new')!.workerSession, isNull);
    // A read that asked for projections is authoritative for them.
    registry.publish('c', 'C', sessions: true, [
      AgentProfile.fromJson({
        'name': 'new',
        'worker_session': {
          'id': 'x',
          'source': 'kanban',
          'title': 't',
          'last_active': 1,
        },
      }),
      const AgentProfile(name: 'ops'),
    ]);
    expect(store.profile('ops')!.workerSession, isNull);
  });

  test('BotMentionRoster.replace feeds the shared store with ordering', () {
    final registry = BotRosterRegistry();
    final mentions = BotMentionRoster(registry);
    final older = mentions.generation('c');
    final newer = mentions.generation('c');
    mentions.replace('c', 'C', const [
      AgentProfile(name: 'new'),
    ], expectedGeneration: newer);
    mentions.replace('c', 'C', const [
      AgentProfile(name: 'old'),
    ], expectedGeneration: older);
    expect(names(registry.store('c')), ['new']);
    expect(mentions.bots('c').single.profile, 'new');
    mentions.dispose();
  });

  AgentProfile working(String name) => AgentProfile.fromJson({
    'name': name,
    'worker_session': {
      'id': 'w-$name',
      'source': 'kanban',
      'title': 't',
      'last_active': 1,
    },
  });

  test('a with-sessions read where every bot is idle clears activity', () {
    final registry = BotRosterRegistry();
    registry.publish('c', 'C', [working('ops')], sessions: true);
    registry.publish(
      'c',
      'C',
      const [AgentProfile(name: 'ops')],
      ticket: registry.beginRead('c'),
      sessions: true,
    );
    expect(registry.store('c').profile('ops')!.workerSession, isNull);
    // Without sessions the same roster says nothing about activity.
    registry.publish('c', 'C', [working('ops')], sessions: true);
    registry.publish('c', 'C', const [AgentProfile(name: 'ops')]);
    expect(registry.store('c').profile('ops')!.workerSession?.id, 'w-ops');
  });

  test(
    'a with-sessions read that loses the roster race still sets activity',
    () {
      final registry = BotRosterRegistry();
      registry.publish('c', 'C', [working('ops')], sessions: true);
      final full = registry.beginRead('c');
      final sessionless = registry.beginRead('c');
      registry.publish('c', 'C', const [
        AgentProfile(name: 'ops', displayName: 'Ops'),
      ], ticket: sessionless);
      expect(
        registry.publish(
          'c',
          'C',
          const [AgentProfile(name: 'ops')],
          ticket: full,
          sessions: true,
        ),
        isFalse,
      );
      final ops = registry.store('c').profile('ops')!;
      expect(ops.displayName, 'Ops');
      expect(ops.workerSession, isNull);
      // An older with-sessions read cannot bring activity back.
      registry.publish('c', 'C', [working('ops')], ticket: 1, sessions: true);
      expect(registry.store('c').profile('ops')!.workerSession, isNull);
    },
  );
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
