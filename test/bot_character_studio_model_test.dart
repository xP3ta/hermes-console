import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/bot_character.dart';
import 'package:hermes_android/core/characters/bot_character_store.dart';
import 'package:hermes_android/core/characters/character_presets.dart';
import 'package:hermes_android/core/characters/studio_catalog.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _studio = BotCharacter(
  kind: 'cloud',
  seed: 'tea-7',
  form: BotForm.cloud,
  range: 0.8,
  strength: 0.25,
  eyeStyle: BotEyeStyle.glint,
  eyeColor: '#2563eb',
  eyeSize: 1.25,
  pieces: [
    BotPiece(kind: BotPieceKind.catEars, x: 0.5, y: 0.2),
    BotPiece(
      kind: BotPieceKind.wing,
      x: 0.25,
      y: 0.6,
      rotation: -30,
      scale: 1.5,
      flip: true,
    ),
  ],
  bodyColor: '#a1b2c3',
  gradient: 'bay',
  finish: BotFinish.glossy,
  fur: true,
);

void main() {
  test('a studio character round-trips through JSON', () {
    final copy = BotCharacter.fromJson(
      jsonDecode(jsonEncode(_studio.toJson())),
    );
    expect(copy, _studio);
    expect(copy.hashCode, _studio.hashCode);
    expect(_studio.toJson()['v'], 2);
    expect(copy!.isStudio, isTrue);
  });

  test('every preset round-trips and is a studio character', () {
    expect(botPresets.length, greaterThanOrEqualTo(8));
    for (final preset in botPresets) {
      final copy = BotCharacter.fromJson(
        jsonDecode(jsonEncode(preset.character.toJson())),
      );
      expect(copy, preset.character, reason: preset.id);
      expect(preset.character.isStudio, isTrue);
    }
  });

  test('a character saved by the first format reads back unchanged', () {
    const stored =
        '{"v":1,"kind":"sun","seed":"tea","eyes":"happy",'
        '"topper":"crown","color":"#ec4899"}';
    final old = BotCharacter.tryParse(stored)!;
    expect(old.kind, 'sun');
    expect(old.seed, 'tea');
    expect(old.eyes, HermesBotFaceEyeStyle.happy);
    expect(old.topper, BotCharacterTopper.crown);
    expect(old.colorHex, '#ec4899');
    // The new fields take their defaults and it keeps the old renderer.
    expect(old.isStudio, isFalse);
    expect(old.form, isNull);
    expect(old.pieces, isEmpty);
    expect(old.range, 0.5);
    expect(old.strength, 0.5);
    expect(old.eyeStyle, BotEyeStyle.dot);
    expect(old.finish, BotFinish.flat);
    expect(old.fur, isFalse);
    // Same face as before the studio existed.
    expect(old.visual('ana').shapeWire, 'blobatar:tea:sun');
    // Writing it again keeps every old field and adds nothing studio.
    final json = old.toJson();
    expect(json['v'], 2);
    expect(json.containsKey('form'), isFalse);
    expect(json.containsKey('pieces'), isFalse);
    expect(BotCharacter.fromJson(json), old);
  });

  test('a newer or foreign document degrades instead of failing', () {
    final future = BotCharacter.fromJson({
      'v': 9,
      'form': 'round',
      'hologram': {'deep': true},
      'finish': 'metallic',
    })!;
    expect(future.form, BotForm.round);
    expect(future.finish, BotFinish.flat);
  });

  test('numbers are clamped and bad types fall back to the default', () {
    final c = BotCharacter.fromJson({
      'form': 'organic',
      'range': 7,
      'strength': -3,
      'eyeSize': 'big',
      'eyeColor': 'red',
      'bodyColor': '#12345',
      'gradient': 'not-a-gradient',
    })!;
    expect(c.range, BotStudioLimits.rangeMax);
    expect(c.strength, BotStudioLimits.strengthMin);
    expect(c.eyeSize, 1);
    expect(c.eyeColor, isNull);
    expect(c.bodyColor, isNull);
    expect(c.gradient, isNull);
  });

  test('slider limits hold through copyWith', () {
    final c = BotCharacter.fresh.copyWith(range: 5, strength: -5, eyeSize: 9);
    expect(c.range, 1);
    expect(c.strength, 0);
    expect(c.eyeSize, BotStudioLimits.eyeSizeMax);
    final low = c.copyWith(eyeSize: 0);
    expect(low.eyeSize, BotStudioLimits.eyeSizeMin);
    final piece = const BotPiece(
      kind: BotPieceKind.star,
      x: 0.5,
      y: 0.5,
    ).copyWith(x: 4, y: -2, rotation: 900, scale: 99);
    expect(piece.x, 1);
    expect(piece.y, 0);
    expect(piece.rotation, 180);
    expect(piece.scale, BotStudioLimits.pieceScaleMax);
    expect(piece.copyWith(scale: 0).scale, BotStudioLimits.pieceScaleMin);
  });

  test('pieces are capped and unknown kinds are dropped', () {
    final c = BotCharacter.fromJson({
      'form': 'round',
      'pieces': [
        for (var i = 0; i < 40; i++) {'k': 'star', 'x': 0.1 * (i % 10)},
        {'k': 'rocket'},
        'text',
      ],
    })!;
    expect(c.pieces.length, BotStudioLimits.maxPieces);
    expect(
      BotCharacter.fromJson({
        'pieces': [
          {'k': 'rocket'},
          7,
        ],
      })!.pieces,
      isEmpty,
    );
    final grown = BotCharacter.fresh.copyWith(
      pieces: [for (var i = 0; i < 30; i++) BotPiece.placed(BotPieceKind.star)],
    );
    expect(grown.pieces.length, BotStudioLimits.maxPieces);
  });

  test('a legacy character upgrades to the closest studio look', () {
    const old = BotCharacter(
      kind: 'organic',
      eyes: HermesBotFaceEyeStyle.happy,
      topper: BotCharacterTopper.crown,
    );
    final up = old.toStudio();
    expect(up.form, BotForm.organic);
    expect(up.eyeStyle, BotEyeStyle.joy);
    expect(up.topper, BotCharacterTopper.none);
    expect(up.pieces.single.kind, BotPieceKind.crown);
    expect(up.toStudio(), up);
  });

  test('changing only a new field is saved and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = await BotCharacterStore.load(prefs);
    addTearDown(() => BotCharacterStore.debugUse(null));

    await store.save('c1', 'ana', BotCharacter.fresh);
    expect(store.characterFor('c1', 'ana'), BotCharacter.fresh);
    for (final next in [
      BotCharacter.fresh.copyWith(fur: true),
      BotCharacter.fresh.copyWith(fur: true, finish: BotFinish.soft),
      BotCharacter.fresh.copyWith(
        fur: true,
        finish: BotFinish.soft,
        pieces: [BotPiece.placed(BotPieceKind.bow)],
      ),
      BotCharacter.fresh.copyWith(
        fur: true,
        finish: BotFinish.soft,
        pieces: [BotPiece.placed(BotPieceKind.bow).copyWith(rotation: 12)],
      ),
    ]) {
      await store.save('c1', 'ana', next);
      expect(store.characterFor('c1', 'ana'), next);
      final reloaded = await BotCharacterStore.load(
        await SharedPreferences.getInstance(),
      );
      expect(reloaded.characterFor('c1', 'ana'), next);
    }
  });
}
