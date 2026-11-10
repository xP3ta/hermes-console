import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/bot_character.dart';
import 'package:hermes_android/core/characters/character_draft.dart';
import 'package:hermes_android/core/characters/character_library.dart';
import 'package:hermes_android/core/characters/studio_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('CharacterDraft', () {
    test('apply, undo and redo walk the history', () {
      final draft = CharacterDraft(BotCharacter.fresh);
      final a = BotCharacter.fresh.copyWith(fur: true);
      final b = a.copyWith(finish: BotFinish.glossy);
      draft
        ..apply(a)
        ..apply(b);
      expect(draft.value, b);
      expect(draft.canUndo, isTrue);
      expect(draft.canRedo, isFalse);
      expect(draft.undo(), isTrue);
      expect(draft.value, a);
      expect(draft.canRedo, isTrue);
      expect(draft.undo(), isTrue);
      expect(draft.value, BotCharacter.fresh);
      expect(draft.undo(), isFalse);
      expect(draft.redo(), isTrue);
      expect(draft.value, a);
      // A new edit drops the redo branch.
      draft.apply(a.copyWith(eyeStyle: BotEyeStyle.heart));
      expect(draft.canRedo, isFalse);
    });

    test('one drag is one undo step however many updates it has', () {
      final draft = CharacterDraft(BotCharacter.fresh);
      draft.beginGesture();
      for (var i = 1; i <= 30; i++) {
        draft.update(BotCharacter.fresh.copyWith(range: i / 30));
      }
      draft.endGesture();
      expect(draft.value.range, 1);
      expect(draft.undo(), isTrue);
      expect(draft.value, BotCharacter.fresh);
      expect(draft.canUndo, isFalse);
    });

    test('a drag that returns to where it began leaves no step', () {
      final draft = CharacterDraft(BotCharacter.fresh);
      draft.beginGesture();
      draft.update(BotCharacter.fresh.copyWith(strength: 0.9));
      draft.update(BotCharacter.fresh);
      draft.endGesture();
      expect(draft.canUndo, isFalse);
    });

    test('placing, changing and removing pieces undoes in order', () {
      final draft = CharacterDraft(BotCharacter.fresh);
      final star = BotPiece.placed(BotPieceKind.star);
      final bow = BotPiece.placed(BotPieceKind.bow);
      draft.apply(draft.value.copyWith(pieces: [star]));
      draft.apply(draft.value.copyWith(pieces: [star, bow]));
      draft.apply(
        draft.value.copyWith(pieces: [star, bow.copyWith(rotation: 45)]),
      );
      draft.apply(draft.value.copyWith(pieces: [bow.copyWith(rotation: 45)]));
      expect(draft.value.pieces.length, 1);
      draft.undo();
      expect(draft.value.pieces.length, 2);
      draft.undo();
      expect(draft.value.pieces.last.rotation, 0);
      draft.undo();
      expect(draft.value.pieces.single, star);
      draft.undo();
      expect(draft.value.pieces, isEmpty);
    });

    test('history is bounded and load starts a clean one', () {
      final draft = CharacterDraft(BotCharacter.fresh);
      for (var i = 0; i < CharacterDraft.limit + 20; i++) {
        draft.apply(BotCharacter.fresh.copyWith(seed: 's$i'));
      }
      var steps = 0;
      while (draft.undo()) {
        steps++;
      }
      expect(steps, CharacterDraft.limit);
      draft.load(BotCharacter.fresh.copyWith(fur: true));
      expect(draft.canUndo, isFalse);
      expect(draft.canRedo, isFalse);
      expect(draft.dirty, isFalse);
      draft.apply(BotCharacter.fresh);
      expect(draft.dirty, isTrue);
      draft.markSaved();
      expect(draft.dirty, isFalse);
    });
  });

  group('BotCharacterLibrary', () {
    test('adds, names, duplicates, renames and removes', () async {
      var n = 0;
      final library = BotCharacterLibrary.memory(newId: () => 'id${n++}');
      final a = await library.add('  Blue   one ', BotCharacter.fresh);
      expect(a.name, 'Blue one');
      final b = await library.add('', BotCharacter.fresh, fallbackName: 'Mine');
      expect(b.name, 'Mine');
      expect(library.items.map((e) => e.id).toSet().length, 2);
      final copy = await library.duplicate(a.id, 'Blue one copy');
      expect(library.items.map((e) => e.name), [
        'Blue one',
        'Blue one copy',
        'Mine',
      ]);
      expect(copy!.character, a.character);
      expect(copy.id, isNot(a.id));
      await library.update(
        a.id,
        name: 'Renamed',
        character: BotCharacter.fresh.copyWith(fur: true),
      );
      expect(library.byId(a.id)!.name, 'Renamed');
      expect(library.byId(a.id)!.character.fur, isTrue);
      expect(library.byId(copy.id)!.character.fur, isFalse);
      await library.remove(a.id);
      expect(library.byId(a.id), isNull);
      expect(library.items.length, 2);
    });

    test('persists and reloads, tolerating damage', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final library = await BotCharacterLibrary.load(prefs);
      addTearDown(() => BotCharacterLibrary.debugUse(null));
      final saved = await library.add(
        'Ana',
        BotCharacter.fresh.copyWith(gradient: 'bay', fur: true),
      );
      final again = await BotCharacterLibrary.load(prefs);
      expect(again.items.single, saved);

      SharedPreferences.setMockInitialValues({
        BotCharacterLibrary.key:
            '{"items": [1, {"id": 2}, {"id":"x","name":"ok","character":{"form":"boxy"}}, {"id":"x","name":"dup","character":{}}]}',
      });
      final damaged = await BotCharacterLibrary.load(
        await SharedPreferences.getInstance(),
      );
      expect(damaged.items.single.name, 'ok');
      SharedPreferences.setMockInitialValues({
        BotCharacterLibrary.key: '{broken',
      });
      final broken = await BotCharacterLibrary.load(
        await SharedPreferences.getInstance(),
      );
      expect(broken.items, isEmpty);
    });

    test('save, duplicate and delete are read back after a restart', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var n = 0;
      final first = await BotCharacterLibrary.load(prefs, () => 'k${n++}');
      addTearDown(() => BotCharacterLibrary.debugUse(null));
      final ana = await first.add(
        'Ana',
        BotCharacter.fresh.copyWith(gradient: 'bay'),
      );
      final copy = await first.duplicate(ana.id, 'Ana (copy)');
      final gone = await first.add('Gone', BotCharacter.fresh);
      await first.remove(gone.id);

      // A restart: a new instance over the same stored preferences.
      final second = await BotCharacterLibrary.load(prefs);
      expect(identical(BotCharacterLibrary.shared, second), isTrue);
      expect(second.items, [ana, copy]);
      expect(second.byId(gone.id), isNull);

      await second.update(ana.id, name: 'Anita');
      final third = await BotCharacterLibrary.load(prefs);
      expect(third.items.map((e) => e.name), ['Anita', 'Ana (copy)']);
    });

    test('a damaged document or entry is ignored, not fatal', () async {
      final good =
          '{"id":"ok","name":"Fine","character":${jsonEncode(BotCharacter.fresh.toJson())}}';
      for (final stored in <Object>[
        42, // wrong type under the key
        '[]',
        '{"items": "no"}',
        '{"items": [null, [], {"id": {}}, {"id":"a","character":7}, '
            '{"id":"b","name":5,"character":{"fur":"x","form":[]}}, $good]}',
      ]) {
        SharedPreferences.setMockInitialValues({
          BotCharacterLibrary.key: stored,
        });
        final library = await BotCharacterLibrary.load(
          await SharedPreferences.getInstance(),
        );
        addTearDown(() => BotCharacterLibrary.debugUse(null));
        expect(
          library.items.every((e) => e.id.isNotEmpty),
          isTrue,
          reason: '$stored',
        );
        if (stored is String && stored.contains('"ok"')) {
          expect(library.byId('ok')?.name, 'Fine');
        } else {
          expect(library.items, isEmpty, reason: '$stored');
        }
      }
    });

    test('the oldest go first past the limit', () async {
      var n = 0;
      final library = BotCharacterLibrary.memory(newId: () => 'i${n++}');
      for (var i = 0; i < BotCharacterLibrary.maxItems + 5; i++) {
        await library.add('c$i', BotCharacter.fresh);
      }
      expect(library.items.length, BotCharacterLibrary.maxItems);
      expect(library.items.first.name, 'c5');
    });
  });
}
