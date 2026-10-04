import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';

import 'cs1215_cold_start_store_test.dart' show MemoryColdStartStorage;

Session _row(
  String id, {
  String title = 'Chat',
  List<String> lineage = const [],
}) => Session(
  id: id,
  title: title,
  model: 'm',
  source: 'cli',
  messageCount: 3,
  isActive: false,
  preview: 'vista $id',
  startedAt: 1790000000,
  updatedAt: 1790000100,
  lineageIds: lineage,
);

void main() {
  late MemoryColdStartStorage storage;
  late ColdStartStore store;

  setUp(() {
    storage = MemoryColdStartStorage();
    store = ColdStartStore(storage: storage);
  });

  Future<List<String>?> ids(String conn, String profile) async =>
      (await store.loadRecents(
        connectionId: conn,
        profile: profile,
      ))?.map((s) => s.id).toList();

  test('recents round-trip per connection and profile', () async {
    await store.saveRecents(
      connectionId: 'c1',
      profile: '',
      sessions: [
        _row('a', title: 'Uno'),
        _row('b'),
      ],
    );
    await store.saveRecents(
      connectionId: 'c1',
      profile: 'work',
      sessions: [_row('w')],
    );
    final loaded = (await store.loadRecents(
      connectionId: 'c1',
      profile: 'default',
    ))!;
    expect(loaded.map((s) => s.id), ['a', 'b']);
    expect(loaded.first.title, 'Uno');
    expect(loaded.first.preview, 'vista a');
    expect(loaded.first.lastActivityAt, 1790000100);
    expect(await ids('c1', 'work'), ['w']);
    expect(await ids('c2', ''), isNull);
    expect(await ids('c1', 'wor'), isNull);
  });

  test(
    'an unchanged snapshot is not rewritten; an empty one is removed',
    () async {
      await store.saveRecents(
        connectionId: 'c',
        profile: '',
        sessions: [_row('a')],
      );
      final writes = storage.writes;
      await store.saveRecents(
        connectionId: 'c',
        profile: '',
        sessions: [_row('a')],
      );
      expect(storage.writes, writes);
      await store.saveRecents(
        connectionId: 'c',
        profile: '',
        sessions: const [],
      );
      expect(await ids('c', ''), isNull);
      expect(storage.values.keys.where((k) => k.contains('recents')), isEmpty);
    },
  );

  test('keeps at most maxRecentRows', () async {
    await store.saveRecents(
      connectionId: 'c',
      profile: '',
      sessions: [for (var i = 0; i < 40; i++) _row('s$i')],
    );
    expect((await ids('c', ''))!.length, ColdStartStore.maxRecentRows);
    final stored =
        jsonDecode(storage.values[ColdStartStore.recentsKey('c', '')]!) as Map;
    expect((stored['rows'] as List).length, ColdStartStore.maxRecentRows);
  });

  test(
    'a confirmed deletion leaves the snapshot under any lineage id',
    () async {
      await store.saveRecents(
        connectionId: 'c',
        profile: '',
        sessions: [
          _row('tip', lineage: ['root', 'tip']),
          _row('keep'),
        ],
      );
      await store.saveRecents(
        connectionId: 'other',
        profile: '',
        sessions: [_row('tip')],
      );
      await store.forgetSession(
        connectionId: 'c',
        profile: '',
        sessionId: 'root',
      );
      expect(await ids('c', ''), ['keep']);
      expect(await ids('other', ''), ['tip']);
      expect(
        storage.values.entries
            .where((e) => e.key == ColdStartStore.recentsKey('c', ''))
            .single
            .value,
        isNot(contains('tip')),
      );
    },
  );

  test('forgetting a scope or everything deletes its snapshots', () async {
    for (final conn in ['c', 'd']) {
      for (final profile in ['', 'work']) {
        await store.saveRecents(
          connectionId: conn,
          profile: profile,
          sessions: [_row('$conn-$profile')],
        );
      }
    }
    await store.forgetScope('c', profile: 'work');
    expect(await ids('c', 'work'), isNull);
    expect(await ids('c', ''), isNotNull);
    await store.forgetScope('c');
    expect(await ids('c', ''), isNull);
    expect(await ids('d', 'work'), isNotNull);
    await store.clearAll();
    expect(storage.values.keys.where((k) => k.contains('recents')), isEmpty);
  });

  test('a corrupt or foreign snapshot is dropped, never painted', () async {
    storage.values[ColdStartStore.recentsKey('c', '')] =
        '{"v":1,"c":"x",'
        '"p":"default","rows":[{"id":"a"}]}';
    expect(await ids('c', ''), isNull);
    expect(storage.values, isEmpty);
    storage.values[ColdStartStore.recentsKey('c', '')] = 'not json';
    expect(await ids('c', ''), isNull);
  });
}
