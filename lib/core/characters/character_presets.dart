import 'bot_character.dart';
import 'studio_catalog.dart';

/// A ready-made character offered in the studio. [id] is stable and names
/// the label (`bstPreset<Id>` in the catalogs).
final class BotPreset {
  final String id;
  final BotCharacter character;

  const BotPreset(this.id, this.character);
}

/// The studio's presets: round faces in different moods, each one a full
/// studio character that can be customised afterwards.
const List<BotPreset> botPresets = [
  BotPreset(
    'coral',
    BotCharacter(
      form: BotForm.round,
      seed: 'coral',
      bodyColor: '#f87171',
      eyeStyle: BotEyeStyle.oval,
      finish: BotFinish.soft,
    ),
  ),
  BotPreset(
    'lilac',
    BotCharacter(
      form: BotForm.organic,
      seed: 'lilac',
      bodyColor: '#c4b5fd',
      eyeStyle: BotEyeStyle.joy,
      finish: BotFinish.matte,
    ),
  ),
  BotPreset(
    'sunny',
    BotCharacter(
      form: BotForm.round,
      seed: 'sunny',
      bodyColor: '#fde047',
      eyeStyle: BotEyeStyle.heart,
      eyeColor: '#dc2626',
      finish: BotFinish.glossy,
    ),
  ),
  BotPreset(
    'mint',
    BotCharacter(
      form: BotForm.cloud,
      seed: 'mint',
      gradient: 'spearmint',
      eyeStyle: BotEyeStyle.wink,
      pieces: [BotPiece(kind: BotPieceKind.leaf, x: 0.7, y: 0.2)],
    ),
  ),
  BotPreset(
    'slate',
    BotCharacter(
      form: BotForm.boxy,
      seed: 'slate',
      bodyColor: '#94a3b8',
      eyeStyle: BotEyeStyle.narrow,
      finish: BotFinish.matte,
      fur: true,
    ),
  ),
  BotPreset(
    'kitten',
    BotCharacter(
      form: BotForm.round,
      seed: 'kitten',
      bodyColor: '#60a5fa',
      eyeStyle: BotEyeStyle.glint,
      finish: BotFinish.soft,
      pieces: [
        BotPiece(kind: BotPieceKind.catEars, x: 0.5, y: 0.2),
        BotPiece(kind: BotPieceKind.wing, x: 0.2, y: 0.56),
        BotPiece(kind: BotPieceKind.wing, x: 0.8, y: 0.56, flip: true),
      ],
    ),
  ),
  BotPreset(
    'ember',
    BotCharacter(
      form: BotForm.organic,
      seed: 'ember',
      gradient: 'cinder',
      eyeStyle: BotEyeStyle.grumpy,
      eyeColor: '#ffffff',
      finish: BotFinish.glossy,
      pieces: [BotPiece(kind: BotPieceKind.horn, x: 0.5, y: 0.15)],
    ),
  ),
  BotPreset(
    'regal',
    BotCharacter(
      form: BotForm.rectangle,
      seed: 'regal',
      gradient: 'plum',
      eyeStyle: BotEyeStyle.dreamy,
      eyeColor: '#ffffff',
      finish: BotFinish.soft,
      pieces: [BotPiece(kind: BotPieceKind.crown, x: 0.5, y: 0.17)],
    ),
  ),
];
