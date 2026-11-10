import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/characters/bot_character.dart';
import 'package:hermes_android/core/characters/character_spec.dart';
import 'package:hermes_android/core/characters/studio_catalog.dart';

void main() {
  test('a well-formed specification becomes a studio character', () {
    final result = BotCharacterSpec.parse('''
{
  "name": "Blue kitten",
  "form": "cloud",
  "range": 0.7,
  "strength": 0.2,
  "eyeStyle": "glint",
  "eyeColor": "#2563EB",
  "eyeSize": 1.3,
  "bodyColor": "#60a5fa",
  "finish": "soft",
  "fur": true,
  "pieces": [
    {"kind": "catEars", "x": 0.5, "y": 0.2},
    {"kind": "wing", "x": 0.2, "y": 0.6, "rotation": -20, "scale": 1.4, "flip": true}
  ]
}''')!;
    final c = result.character;
    expect(result.name, 'Blue kitten');
    expect(result.ignoredKeys, 0);
    expect(c.isStudio, isTrue);
    expect(c.form, BotForm.cloud);
    expect(c.range, 0.7);
    expect(c.strength, 0.2);
    expect(c.eyeStyle, BotEyeStyle.glint);
    expect(c.eyeColor, '#2563eb');
    expect(c.eyeSize, 1.3);
    expect(c.bodyColor, '#60a5fa');
    expect(c.finish, BotFinish.soft);
    expect(c.fur, isTrue);
    expect(c.pieces.map((p) => p.kind), [
      BotPieceKind.catEars,
      BotPieceKind.wing,
    ]);
    expect(c.pieces.last.flip, isTrue);
    expect(c.pieces.last.rotation, -20);
  });

  test('a chat answer wrapped in a code fence is accepted', () {
    final result = BotCharacterSpec.parse(
      '```json\n{"form":"boxy","gradient":"tide"}\n```',
    )!;
    expect(result.character.form, BotForm.boxy);
    expect(result.character.gradient, 'tide');
  });

  test('numbers outside the bounds are clamped, never trusted', () {
    final c = BotCharacterSpec.parse(
      '''
{"range": 99, "strength": -4, "eyeSize": 1e999,
 "pieces": [{"kind":"star","x":-5,"y":50,"rotation":1e9,"scale":0}]}''',
    )!.character;
    expect(c.range, 1);
    expect(c.strength, 0);
    expect(c.eyeSize, 1);
    final p = c.pieces.single;
    expect(p.x, 0);
    expect(p.y, 1);
    expect(p.rotation, 180);
    expect(p.scale, BotStudioLimits.pieceScaleMin);
  });

  test('wrong types and unknown names fall back to defaults', () {
    final result = BotCharacterSpec.parse('''
{"form": 7, "range": "wide", "strength": null, "eyeStyle": "laser",
 "eyeColor": "red", "bodyColor": "#ggg", "gradient": "../../etc",
 "finish": ["glossy"], "fur": "yes", "pieces": "many",
 "run": "rm -rf /", "__proto__": {"x": 1}, "constructor": 3}''')!;
    final c = result.character;
    expect(c.form, BotForm.round);
    expect(c.range, 0.5);
    expect(c.strength, 0.5);
    expect(c.eyeStyle, BotEyeStyle.dot);
    expect(c.eyeColor, isNull);
    expect(c.bodyColor, isNull);
    expect(c.gradient, isNull);
    expect(c.finish, BotFinish.flat);
    expect(c.fur, isFalse);
    expect(c.pieces, isEmpty);
    expect(result.ignoredKeys, 3);
  });

  test('pieces are capped and bad entries are skipped', () {
    final spec =
        '{"pieces": [${List.filled(50, '{"kind":"heart"}').join(',')},'
        '{"kind":"rocket"}]}';
    expect(
      BotCharacterSpec.parse(spec)!.character.pieces.length,
      BotStudioLimits.maxPieces,
    );
    final mixed = BotCharacterSpec.parse(
      '{"pieces": [{"kind":"rocket"}, 7, null, [], {"kind":"drop"}]}',
    )!;
    expect(mixed.character.pieces.single.kind, BotPieceKind.drop);
  });

  test('hostile input is rejected or neutralised', () {
    for (final bad in <String?>[
      null,
      '',
      '   ',
      'a blue kitten with wings',
      '[1,2,3]',
      '"text"',
      '42',
      'null',
      '{"form":',
      '{{{{',
      "{'form': 'round'}",
      '```\n```',
      '```json',
    ]) {
      expect(BotCharacterSpec.parse(bad), isNull, reason: '$bad');
    }
    // Too deep.
    expect(BotCharacterSpec.parse('${'[' * 40}${']' * 40}'), isNull);
    expect(BotCharacterSpec.parse('${'{"a":' * 30}1${'}' * 30}'), isNull);
    // Too big.
    expect(BotCharacterSpec.parse('{"name":"${'x' * 7000}"}'), isNull);
    // Too many keys.
    final many = {for (var i = 0; i < 80; i++) '"k$i"': '1'};
    expect(
      BotCharacterSpec.parse(
        '{${many.entries.map((e) => '${e.key}:${e.value}').join(',')}}',
      ),
      isNull,
    );
  });

  test('brackets inside strings do not count as depth', () {
    final result = BotCharacterSpec.parse(
      '{"name": "${'[' * 50}", "form": "boxy"}',
    )!;
    expect(result.character.form, BotForm.boxy);
  });

  test('the name is cleaned and capped', () {
    final result = BotCharacterSpec.parse(
      '{"name": "  Kit\\u0000ten\\n\\n   blue ${'z' * 100}"}',
    )!;
    expect(
      result.name.length,
      lessThanOrEqualTo(BotStudioLimits.maxNameLength),
    );
    expect(result.name, isNot(contains('\n')));
    expect(result.name, startsWith('Kit ten blue'));
    expect(BotCharacterSpec.parse('{"name": 5}')!.name, isEmpty);
  });

  test('the result always survives a storage round trip', () {
    final result = BotCharacterSpec.parse(
      '{"form":"rectangle","pieces":[{"kind":"bolt","x":0.3}]}',
    )!;
    expect(BotCharacter.fromJson(result.character.toJson()), result.character);
  });
}
