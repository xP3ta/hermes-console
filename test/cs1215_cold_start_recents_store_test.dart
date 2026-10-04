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

  // Secure Storage holds every snapshot in one encrypted file read at
  // launch: a few rows must never cost megabytes.
  const rowBudget = 4 * 1024;
  const snapshotBudget = 64 * 1024;

  test('a row with a huge preview or lineage is left out of the '
      'snapshot; the rows around it stay', () async {
    await store.saveRecents(
      connectionId: 'c',
      profile: '',
      sessions: [
        _row('a'),
        Session(
          id: 'big-preview',
          title: 'Chat',
          model: 'm',
          source: 'cli',
          messageCount: 1,
          isActive: false,
          preview: 'x' * (512 * 1024),
          startedAt: 1790000000,
        ),
        _row(
          'big-lineage',
          lineage: [for (var i = 0; i < 4000; i++) 'ancestor-$i'],
        ),
        _row('d'),
      ],
    );
    final raw = storage.values[ColdStartStore.recentsKey('c', '')]!;
    expect(utf8.encode(raw).length, lessThanOrEqualTo(rowBudget * 2));
    expect(await ids('c', ''), ['a', 'd']);
  });

  test('the whole snapshot stays within its byte budget, keeping the '
      'newest rows', () async {
    // Row sizes swept byte by byte so the cut lands on every offset of the
    // envelope: the bound must hold exactly, not on average.
    for (var pad = 0; pad < 64; pad++) {
      await store.saveRecents(
        connectionId: 'c',
        profile: '',
        sessions: [
          for (var i = 0; i < 23; i++)
            _row('s$i', title: 'T' * (rowBudget - 700 + pad)),
          // Small enough to fit after the cut: it must not fill the gap.
          _row('small'),
        ],
      );
      final raw = storage.values[ColdStartStore.recentsKey('c', '')]!;
      final size = utf8.encode(raw).length;
      expect(size, lessThanOrEqualTo(snapshotBudget), reason: 'pad $pad');
      final kept = (await ids('c', ''))!;
      expect(kept.length, inInclusiveRange(12, 22), reason: 'pad $pad');
      expect(kept, [for (var i = 0; i < kept.length; i++) 's$i']);
      // Nothing left on the table: one more row would not have fitted.
      expect(snapshotBudget - size, lessThan(size ~/ kept.length));
    }
  });

  test('a snapshot of exactly the byte budget fits; one byte more drops '
      'the last row', () async {
    final key = ColdStartStore.recentsKey('c', '');
    Future<int> savedSize(List<Session> rows) async {
      await store.saveRecents(connectionId: 'c', profile: '', sessions: rows);
      return utf8.encode(storage.values[key]!).length;
    }

    // Same-length ids, so every row costs the same but for its title.
    String id(int i) => 'r${i.toString().padLeft(2, '0')}';
    const base = 2000;
    final one = await savedSize([_row(id(0), title: 'T' * base)]);
    final two = await savedSize([
      for (var i = 0; i < 2; i++) _row(id(i), title: 'T' * base),
    ]);
    final rowBytes = two - one - 1; // one comma between rows
    final envelope = one - rowBytes;
    const count = 20;
    // count rows + (count - 1) commas + envelope == budget exactly.
    final room = snapshotBudget - envelope - (count - 1);
    final each = room ~/ count;
    final spare = room - each * count;
    expect(each, lessThanOrEqualTo(rowBudget));
    List<Session> rows(int extra) => [
      for (var i = 0; i < count; i++)
        _row(
          id(i),
          title:
              'T' *
              (base + each - rowBytes + (i == count - 1 ? spare + extra : 0)),
        ),
    ];

    expect(await savedSize(rows(0)), snapshotBudget);
    expect((await ids('c', ''))!.length, count);
    expect(await savedSize(rows(1)), lessThan(snapshotBudget));
    expect((await ids('c', ''))!.length, count - 1);
  });

  test('an oversized stored snapshot is dropped, never decoded', () async {
    final rows = [
      for (var i = 0; i < 3; i++)
        {
          'id': 's$i',
          'title': 'T' * (snapshotBudget ~/ 2),
          'source': 'cli',
          'started_at': 1790000000,
        },
    ];
    final oversized = jsonEncode({
      'v': 1,
      'c': 'c',
      'p': 'default',
      'rows': rows,
    });
    storage.values[ColdStartStore.recentsKey('c', '')] = oversized;
    expect(await ids('c', ''), isNull);
    expect(storage.values, isEmpty);
    // A deletion sweep drops it too instead of rewriting it.
    storage.values[ColdStartStore.recentsKey('c', '')] = oversized;
    await store.forgetSession(connectionId: 'c', profile: '', sessionId: 's0');
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
