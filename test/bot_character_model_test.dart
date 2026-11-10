import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/bot_character.dart';
import 'package:hermes_android/core/characters/bot_character_store.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const full = BotCharacter(
    kind: 'cloud',
    seed: 'tea-7',
    eyes: HermesBotFaceEyeStyle.happy,
    topper: BotCharacterTopper.crown,
    colorHex: '#8b5cf6',
  );

  test('round-trips through JSON', () {
    final copy = BotCharacter.fromJson(jsonDecode(jsonEncode(full.toJson())));
    expect(copy, full);
    expect(copy.hashCode, full.hashCode);
    expect(full.toJson()['v'], BotCharacter.version);
  });

  test('the standard character writes only the version', () {
    expect(BotCharacter.standard.toJson(), {'v': BotCharacter.version});
    expect(BotCharacter.fromJson({'v': 1}), BotCharacter.standard);
    expect(BotCharacter.standard.isStandard, isTrue);
  });

  test('missing, foreign or damaged fields fall back to defaults', () {
    final damaged = BotCharacter.fromJson({
      'kind': 'dodecahedron',
      'seed': 'No Good!',
      'eyes': 'laser',
      'topper': 7,
      'color': '#123456',
      'extra': true,
    })!;
    expect(damaged, BotCharacter.standard);
    final partial = BotCharacter.fromJson({'kind': 'sun', 'topper': 'halo'})!;
    expect(partial.kind, 'sun');
    expect(partial.topper, BotCharacterTopper.halo);
    expect(partial.eyes, HermesBotFaceEyeStyle.seeded);
  });

  test('non-objects and broken JSON read as null', () {
    expect(BotCharacter.fromJson('sun'), isNull);
    expect(BotCharacter.fromJson(null), isNull);
    expect(BotCharacter.tryParse('{not json'), isNull);
    expect(BotCharacter.tryParse(''), isNull);
    expect(BotCharacter.tryParse(null), isNull);
  });

  test('every character yields a renderable face', () {
    for (final kind in <String?>[null, ...BlobatarShapeWire.kinds]) {
      for (final seed in ['', 'abc']) {
        final face = BotCharacter(kind: kind, seed: seed).visual('Ana');
        expect(face.resolvedKind, isNotEmpty);
      }
    }
    expect(const BotCharacter(kind: 'boxy').visual('???').resolvedKind, 'boxy');
    expect(full.wire, 'blobatar:tea-7:cloud');
    expect(BotCharacter.standard.wire, 'blobatar');
  });

  test('seed validation matches the face wire', () {
    expect(BotCharacter.isValidSeed(''), isTrue);
    expect(BotCharacter.isValidSeed('a_b-9'), isTrue);
    expect(BotCharacter.isValidSeed('-a'), isFalse);
    expect(BotCharacter.isValidSeed('A'), isFalse);
    expect(BotCharacter.isValidSeed('a' * 65), isFalse);
  });

  test('copyWith can clear kind and colour', () {
    final cleared = full.copyWith(kind: null, colorHex: null);
    expect(cleared.kind, isNull);
    expect(cleared.colorHex, isNull);
    expect(cleared.seed, 'tea-7');
    expect(full.copyWith(seed: 'x').kind, 'cloud');
  });

  group('store', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test(
      'keeps one character per profile and connection, and persists',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final store = await BotCharacterStore.load(prefs);
        await store.save('c1', 'ana', full);
        await store.save('c2', 'ana', const BotCharacter(kind: 'sun'));
        expect(store.characterFor('c1', 'ana'), full);
        expect(store.characterFor('c2', 'ana')?.kind, 'sun');
        expect(store.characterFor('c1', 'bob'), isNull);

        final reloaded = await BotCharacterStore.load(prefs);
        expect(reloaded.characterFor('c1', 'ana'), full);
        expect(reloaded.characterFor('c2', 'ana')?.kind, 'sun');
      },
    );

    test(
      'saving the standard character, or reset, forgets the profile',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final store = await BotCharacterStore.load(prefs);
        await store.save('c1', 'ana', full);
        await store.save('c1', 'ana', BotCharacter.standard);
        expect(store.characterFor('c1', 'ana'), isNull);
        expect(prefs.getString(BotCharacterStore.key), isNull);
      },
    );

    test('notifies listeners on change only', () async {
      final store = await BotCharacterStore.load(
        await SharedPreferences.getInstance(),
      );
      var calls = 0;
      store.addListener(() => calls++);
      await store.save('c1', 'ana', full);
      await store.save('c1', 'ana', full);
      await store.reset('c1', 'nobody');
      expect(calls, 1);
    });

    test('damaged storage degrades to no characters', () async {
      for (final raw in [
        '{oops',
        '[1,2]',
        '"x"',
        '{"c|a": 5, "c|b": {"kind": "sun"}}',
      ]) {
        SharedPreferences.setMockInitialValues({BotCharacterStore.key: raw});
        final store = await BotCharacterStore.load(
          await SharedPreferences.getInstance(),
        );
        expect(store.characterFor('c', 'a'), isNull, reason: raw);
        if (raw.contains('sun')) {
          expect(store.characterFor('c', 'b')?.kind, 'sun');
        }
      }
    });
  });
}
