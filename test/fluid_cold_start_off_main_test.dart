// CHAT-FLUIDO 7: cold-start tails (up to 1 MB each, read while the app
// starts) are decoded off the main isolate above 64 KB, like the Dashboard
// reads (N10g); small ones stay inline. The restored rows are the same.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';
import 'package:hermes_android/core/services/transcript_rehydrate_cost.dart';

class _MemoryStorage implements ColdStartStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<Iterable<String>> keys() async => values.keys.toList();
}

List<Map<String, dynamic>> _rows(String tag, int count, int size) => [
  for (var i = count; i >= 1; i--)
    {
      'id': i,
      'role': i.isOdd ? 'user' : 'assistant',
      'content': '$tag-$i ${'x' * size}',
    },
];

Future<void> _save(ColdStartStore store, String id, int size) =>
    store.saveTail(
      connectionId: 'c',
      profile: 'default',
      storedSessionId: id,
      routeSessionId: id,
      aliases: {id},
      newestFirst: _rows(id, 60, size),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final paths = <bool>[];
  setUp(() {
    paths.clear();
    debugJsonDecodePathObserver = paths.add;
  });
  tearDown(() => debugJsonDecodePathObserver = null);

  test('a large tail decodes off the main isolate, same rows', () async {
    final storage = _MemoryStorage();
    await _save(ColdStartStore(storage: storage), 'big', 2000);
    paths.clear();
    final tails = await ColdStartStore(storage: storage).loadTails();
    expect(paths, [true]);
    expect(tails.single.storedSessionId, 'big');
    expect(tails.single.newestFirst, hasLength(60));
    expect(tails.single.newestFirst.first['content'], startsWith('big-60 '));
  });

  test('a small tail stays inline', () async {
    final storage = _MemoryStorage();
    await _save(ColdStartStore(storage: storage), 'small', 10);
    paths.clear();
    final tails = await ColdStartStore(storage: storage).loadTails();
    expect(paths, [false]);
    expect(tails.single.newestFirst, hasLength(60));
  });

  test('a corrupt tail is still dropped', () async {
    final storage = _MemoryStorage();
    await _save(ColdStartStore(storage: storage), 'bad', 10);
    final key = storage.values.keys.firstWhere(
      (key) => key.startsWith('cold_start_tail_v1.'),
    );
    storage.values[key] = '{"v": 2}';
    final tails = await ColdStartStore(storage: storage).loadTails();
    expect(tails, isEmpty);
    expect(storage.values.containsKey(key), isFalse);
  });
}
