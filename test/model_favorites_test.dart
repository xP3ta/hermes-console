import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/model_favorites.dart';

void main() {
  test('starring keeps the order they were starred in; again unstars', () {
    var favs = ModelFavorites.empty
        .toggled('openai', 'gpt-6')
        .toggled('anthropic', 'claude-opus-5')
        .toggled('nous', 'hermes-4');
    expect(favs.entries.map((e) => '${e.provider}/${e.model}'), [
      'openai/gpt-6',
      'anthropic/claude-opus-5',
      'nous/hermes-4',
    ]);
    expect(favs.contains('anthropic', 'claude-opus-5'), isTrue);
    favs = favs.toggled('anthropic', 'claude-opus-5');
    expect(favs.contains('anthropic', 'claude-opus-5'), isFalse);
    expect(favs.entries.map((e) => e.model), ['gpt-6', 'hermes-4']);
    expect(
      favs.toggled('openai', 'gpt-6').toggled('nous', 'hermes-4').isEmpty,
      isTrue,
    );
  });

  test('a model id may hold a pipe or a colon; only the first pipe splits', () {
    final favs = ModelFavorites.empty.toggled('ollama-local', 'qwen3:8b|q4');
    expect(favs.entries.single.provider, 'ollama-local');
    expect(favs.entries.single.model, 'qwen3:8b|q4');
    expect(ModelFavorites.decode(favs.encode()), favs);
  });

  test('the list is capped: a full one takes no more and keeps its own', () {
    var favs = ModelFavorites.empty;
    for (var i = 0; i < ModelFavorites.maxEntries; i++) {
      favs = favs.toggled('p', 'm$i');
    }
    expect(favs.length, 12);
    expect(favs.isFull, isTrue);
    expect(favs.toggled('p', 'extra'), same(favs));
    expect(favs.toggled('p', 'm0').length, 11);
    expect(favs.toggled('p', 'm0').toggled('p', 'extra').length, 12);
  });

  test('encode and decode round-trip; bad data is an empty list', () {
    final favs = ModelFavorites.empty.toggled('a', 'x').toggled('b', 'y');
    expect(ModelFavorites.decode(favs.encode()), favs);
    for (final bad in [null, '', 'nope', '{}', '[1, null, "x", "|y", "z|"]']) {
      expect(ModelFavorites.decode(bad).isEmpty, isTrue, reason: '$bad');
    }
    // Repeats and past the cap are dropped on the way in.
    final noisy = ModelFavorites.decode(
      '["a|1","a|1",${[for (var i = 0; i < 20; i++) '"b|$i"'].join(',')}]',
    );
    expect(noisy.length, ModelFavorites.maxEntries);
    expect(noisy.entries.first.model, '1');
  });

  test('one list per connection and profile', () {
    expect(
      ModelFavorites.storageKey('conn-1', 'default'),
      'model_favorites_v1_conn-1_default',
    );
    expect(
      ModelFavorites.storageKey('conn-1', 'ana'),
      isNot(ModelFavorites.storageKey('conn-1', 'default')),
    );
    expect(
      ModelFavorites.storageKey('conn-2', 'default'),
      isNot(ModelFavorites.storageKey('conn-1', 'default')),
    );
  });
}
