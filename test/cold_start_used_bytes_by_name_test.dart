// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';

import 'cs1215_cold_start_store_test.dart' show MemoryColdStartStorage;

/// Counts the key listings: in production each one decrypts all of secure
/// storage (every chat tail included) into one platform message.
class _ListingStorage extends MemoryColdStartStorage {
  int listings = 0;

  @override
  Future<Iterable<String>> keys() {
    listings++;
    return super.keys();
  }
}

Session _row(String id) => Session(
  id: id,
  title: 'Chat $id',
  model: 'm',
  source: 'cli',
  messageCount: 3,
  isActive: false,
  preview: 'preview $id',
  startedAt: 1790000000,
  updatedAt: 1790000100,
);

/// What the cache holds on disk: the lists in secure storage and the tail
/// files (the index and the key of the files aside).
int _bytesOf(MemoryColdStartStorage storage) =>
    storage.values.entries
        .where(
          (entry) =>
              entry.key != ColdStartStore.indexKey &&
              entry.key != ColdStartStore.fileKeyKey,
        )
        .fold(0, (sum, entry) => sum + utf8.encode(entry.value).length) +
    storage.files.values.fold(0, (sum, file) => sum + file.length);

void main() {
  test('opening the cache settings sizes the cache without listing secure '
      'storage', () async {
    final storage = _ListingStorage();
    final writer = ColdStartStore(storage: storage);
    await writer.saveTail(
      connectionId: 'c',
      profile: 'default',
      storedSessionId: 's1',
      routeSessionId: 's1',
      aliases: {'s1'},
      newestFirst: [{'role': 'user', 'content': 'hello'}],
    );
    await writer.saveRecents(
      connectionId: 'c',
      profile: '',
      sessions: [_row('a')],
    );
    await writer.saveList(
      connectionId: 'c',
      profile: 'work',
      sessions: [_row('b')],
    );
    final expected = _bytesOf(storage);
    expect(expected, greaterThan(0));

    // The next launch opens Settings, Cache.
    expect(await ColdStartStore(storage: storage).usedBytes(), expected);
    expect(storage.listings, 0);
  });

  test('a list an older version stored counts once it is read again', () async {
    final storage = _ListingStorage();
    final writer = ColdStartStore(storage: storage);
    await writer.saveRecents(
      connectionId: 'c',
      profile: '',
      sessions: [_row('a')],
    );
    // The older version kept no names of its lists.
    final index = jsonDecode(storage.values[ColdStartStore.indexKey]!) as Map;
    index.remove('lists');
    storage.values[ColdStartStore.indexKey] = jsonEncode(index);
    final expected = _bytesOf(storage);

    // Home reads its recents at launch.
    final launch = ColdStartStore(storage: storage);
    expect(
      await launch.loadRecents(connectionId: 'c', profile: ''),
      hasLength(1),
    );

    expect(await ColdStartStore(storage: storage).usedBytes(), expected);
    expect(storage.listings, 0);
  });

  test('a list emptied or cleared stops counting', () async {
    final storage = _ListingStorage();
    final store = ColdStartStore(storage: storage);
    await store.saveRecents(
      connectionId: 'c',
      profile: '',
      sessions: [_row('a')],
    );
    await store.saveList(connectionId: 'c', profile: '', sessions: [_row('b')]);
    // Home has nothing recent any more.
    await store.saveRecents(connectionId: 'c', profile: '', sessions: []);

    final listOnly = _bytesOf(storage);
    expect(listOnly, greaterThan(0));
    expect(await ColdStartStore(storage: storage).usedBytes(), listOnly);

    // Settings, Cache, Clear: an explicit cleanup may list the keys.
    await store.clearLists();

    expect(await ColdStartStore(storage: storage).usedBytes(), 0);
    expect(
      (jsonDecode(storage.values[ColdStartStore.indexKey]!) as Map)['lists'],
      isNull,
    );
    expect(storage.listings, 1);
  });
}
