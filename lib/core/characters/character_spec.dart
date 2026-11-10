import 'dart:convert';

import 'bot_character.dart';
import 'character_library.dart';
import 'studio_catalog.dart';

/// What the strict validator made of a generated specification.
final class BotSpecResult {
  /// The character: always a studio character, every field valid.
  final BotCharacter character;

  /// A suggested name, cleaned; empty when none was given.
  final String name;

  /// Keys the specification carried that the schema does not know. They are
  /// ignored, never interpreted.
  final int ignoredKeys;

  /// Keys of the schema the specification carried. Zero means it said
  /// nothing the studio understands (`{"foo": 1}`): a caller that applies
  /// the result should treat that as "not understood".
  final int recognizedKeys;

  const BotSpecResult({
    required this.character,
    required this.name,
    required this.ignoredKeys,
    this.recognizedKeys = 0,
  });
}

/// Validates a character specification written by an AI (or anyone) against
/// the studio schema.
///
/// The text is data and nothing else: it is decoded as JSON, only the keys
/// of the schema are read, every enum must be one of its names, every number
/// must be finite and is clamped to its bounds, colours must be `#rrggbb`,
/// and size, depth, key count and piece count are capped. Anything else is
/// dropped. Nothing is ever evaluated, fetched or executed.
///
/// Schema (all optional):
/// `form`, `range` 0..1, `strength` 0..1, `eyeStyle`, `eyeColor`, `eyeSize`
/// 0.6..1.6, `bodyColor`, `gradient`, `finish`, `fur`, `name` and `pieces`
/// (at most 12 of `kind`, `x`, `y` 0..1, `rotation` -180..180, `scale`
/// 0.4..2.5, `flip`).
abstract final class BotCharacterSpec {
  /// Longest accepted text.
  static const int maxChars = 6000;

  /// Deepest accepted nesting of objects and lists.
  static const int maxDepth = 6;

  /// Most keys accepted in any one object.
  static const int maxKeys = 40;

  static const Set<String> _topKeys = {
    'form',
    'range',
    'strength',
    'eyeStyle',
    'eyeColor',
    'eyeSize',
    'bodyColor',
    'gradient',
    'finish',
    'fur',
    'name',
    'pieces',
  };

  /// The character in [source], or null when it is not an acceptable
  /// specification (not JSON, not an object, too big or too deep).
  ///
  /// [source] may be wrapped in a single Markdown code fence, as chat models
  /// tend to answer.
  static BotSpecResult? parse(String? source) {
    if (source == null) return null;
    final text = _unfence(source.trim());
    if (text.isEmpty || text.length > maxChars) return null;
    if (!_depthOk(text)) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || decoded.length > maxKeys) return null;
    var ignored = 0;
    for (final key in decoded.keys) {
      if (key is! String || !_topKeys.contains(key)) ignored++;
    }
    final pieces = <Object?>[];
    final rawPieces = decoded['pieces'];
    if (rawPieces is List) {
      for (final item in rawPieces) {
        if (pieces.length >= BotStudioLimits.maxPieces) break;
        if (item is! Map || item.length > maxKeys) continue;
        pieces.add({
          'k': item['kind'],
          'x': item['x'],
          'y': item['y'],
          'r': item['rotation'],
          's': item['scale'],
          'f': item['flip'],
        });
      }
    }
    final character = BotCharacter.fromJson({
      'form': decoded['form'] ?? BotForm.round.name,
      'range': decoded['range'],
      'strength': decoded['strength'],
      'eyeStyle': decoded['eyeStyle'],
      'eyeColor': decoded['eyeColor'],
      'eyeSize': decoded['eyeSize'],
      'bodyColor': decoded['bodyColor'],
      'gradient': decoded['gradient'],
      'finish': decoded['finish'],
      'fur': decoded['fur'],
      'pieces': pieces,
    })!;
    // An unknown form must still give a studio body.
    final studio = character.isStudio ? character : character.toStudio();
    final name = decoded['name'];
    return BotSpecResult(
      character: studio,
      name: name is String ? BotCharacterLibrary.cleanName(name) : '',
      ignoredKeys: ignored,
      recognizedKeys: decoded.length - ignored,
    );
  }

  static String _unfence(String text) {
    if (!text.startsWith('```')) return text;
    final firstBreak = text.indexOf('\n');
    if (firstBreak < 0) return '';
    var body = text.substring(firstBreak + 1);
    final close = body.lastIndexOf('```');
    if (close >= 0) body = body.substring(0, close);
    return body.trim();
  }

  /// False when brackets nest deeper than [maxDepth] (strings skipped).
  static bool _depthOk(String text) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == 0x5c) {
          escaped = true;
        } else if (c == 0x22) {
          inString = false;
        }
        continue;
      }
      if (c == 0x22) {
        inString = true;
      } else if (c == 0x7b || c == 0x5b) {
        depth++;
        if (depth > maxDepth) return false;
      } else if (c == 0x7d || c == 0x5d) {
        depth--;
      }
    }
    return true;
  }
}
