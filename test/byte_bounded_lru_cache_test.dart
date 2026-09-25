import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/byte_bounded_lru_cache.dart';

void main() {
  ByteBoundedLruCache<String, String> cache({
    int maxEntries = 512,
    int maxBytes = 100,
  }) => ByteBoundedLruCache<String, String>(
    maxEntries: maxEntries,
    maxBytes: maxBytes,
    sizeOf: (key, value) => key.length + value.length,
  );

  test('expulsa LRU al superar el tope en bytes', () {
    final c = cache();
    c.put('a', 'x' * 29); // 30
    c.put('b', 'x' * 29); // 60
    c.put('c', 'x' * 29); // 90
    expect(c.bytes, 90);
    // Tocar `a` la vuelve la más reciente: la víctima es `b`.
    expect(c.lookup('a')?.value, 'x' * 29);
    c.put('d', 'x' * 29); // 120 > 100 → expulsa b
    expect(c.keysOldestFirstForTesting, ['c', 'a', 'd']);
    expect(c.bytes, 90);
    expect(c.lookup('b'), isNull);
  });

  test('sigue respetando el tope de entradas', () {
    final c = cache(maxEntries: 2, maxBytes: 1 << 20);
    c.put('a', '1');
    c.put('b', '2');
    c.put('c', '3');
    expect(c.keysOldestFirstForTesting, ['b', 'c']);
    expect(c.bytes, 4);
  });

  test('reemplazar una clave no cuenta dos veces sus bytes', () {
    final c = cache();
    c.put('a', 'x' * 49);
    c.put('a', 'x' * 9);
    expect(c.length, 1);
    expect(c.bytes, 10);
  });

  test('una entrada mayor que el tope no se guarda ni vacía la caché', () {
    final c = cache();
    c.put('a', 'x' * 9);
    c.put('huge', 'x' * 200);
    expect(c.keysOldestFirstForTesting, ['a']);
    expect(c.bytes, 10);
  });

  test('clear deja la caché vacía', () {
    final c = cache();
    c.put('a', 'x');
    c.clear();
    expect(c.length, 0);
    expect(c.bytes, 0);
  });

  test('PrivateRenderCaches.unregister retira el clearer', () {
    var clears = 0;
    void clearer() => clears += 1;
    final before = PrivateRenderCaches.registeredCountForTesting;
    PrivateRenderCaches.register(clearer);
    expect(PrivateRenderCaches.registeredCountForTesting, before + 1);
    PrivateRenderCaches.clearAll();
    expect(clears, 1);
    PrivateRenderCaches.unregister(clearer);
    expect(PrivateRenderCaches.registeredCountForTesting, before);
    PrivateRenderCaches.clearAll();
    expect(clears, 1);
  });
}
