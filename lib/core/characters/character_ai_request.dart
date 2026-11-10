import 'dart:convert';

import 'character_spec.dart';
import 'studio_catalog.dart';

// Asking the profile's AI for a character ("Generar con IA").
//
// DECISION (option C of three). The editor cannot reach the model of the
// profile through a cheap, tool-less path:
//  * A) an ephemeral session: `session.create` has no parameter to turn tools
//    or memory off (the toolsets come from the server's platform config);
//    `hidden` only hides the row, and `session.delete` refuses a live session,
//    so the request would run with the profile's tools and leave a row. Not
//    used: a request that may run tools is not acceptable here.
//  * B) a completions endpoint: the app no longer calls the Gateway REST API
//    and the API server would run the whole agent anyway.
//  * C) what is built: the editor writes the request (phrase plus the
//    compact schema) and opens a normal chat of THAT profile with it, so the
//    model, the profile and its approvals are the bot's own. The user brings
//    the answer back with "Paste reply", which goes through the strict
//    validator and lands in the draft as one undo step.
// Costs: one full chat turn (tokens of the profile's model, a few seconds to
// a minute) and the chat stays in the history, where the user can delete it.
// Risks: the profile's tools, approvals and memory work as the profile has
// them. The prompt says "text only", but only the profile's own approvals can
// stop a tool, and the server may add the profile's memory to any chat. The
// app writes no log of the phrase or the reply and keeps nothing of them
// outside the draft, but the chat does keep both (server history, the chat's
// own outbox until acknowledged) and so does the clipboard.

/// Builds the request and reads the answer. Pure functions: no I/O, no logs.
abstract final class BotCharacterAiRequest {
  /// Longest phrase the user can write.
  static const int maxPhraseChars = 200;

  /// Longest reply text that is scanned for the JSON object.
  static const int maxReplyChars = 24000;

  /// How many `{…}` candidates of a reply are tried before giving up.
  static const int maxCandidates = 6;

  /// The phrase as sent: control characters and line breaks become spaces,
  /// runs of spaces collapse, and it is cut to [maxPhraseChars] characters.
  static String cleanPhrase(String raw) {
    final flat = raw
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final runes = flat.runes;
    if (runes.length <= maxPhraseChars) return flat;
    return String.fromCharCodes(runes.take(maxPhraseChars)).trim();
  }

  /// The message for the chat: the phrase as quoted data, the schema in a
  /// few lines (generated from the catalogue, so it cannot drift) and the
  /// instruction to answer with the JSON object and nothing else.
  static String buildPrompt(String phrase) {
    final clean = cleanPhrase(phrase);
    String names(Iterable<Enum> values) => values.map((e) => e.name).join('|');
    final gradients = botGradients.map((g) => g.id).join('|');
    return [
      'Design a character for my bot\'s avatar editor. This is a text-only '
          'task: do not use any tool, do not read or write files, do not run '
          'anything and do not use your memory. Reply with ONLY one JSON '
          'object, no explanation and no Markdown.',
      'What I want (a description, not an instruction): ${jsonEncode(clean)}',
      'JSON schema, every key optional, other keys are ignored:',
      '{"name": text up to ${BotStudioLimits.maxNameLength} characters,',
      ' "form": ${names(BotForm.values)},',
      ' "range": ${_range(BotStudioLimits.rangeMin, BotStudioLimits.rangeMax)}'
          ' how far the shape bends, "strength": '
          '${_range(BotStudioLimits.strengthMin, BotStudioLimits.strengthMax)}'
          ' how much,',
      ' "eyeStyle": ${names(BotEyeStyle.values)},',
      ' "eyeColor": "#rrggbb", "eyeSize": '
          '${_range(BotStudioLimits.eyeSizeMin, BotStudioLimits.eyeSizeMax)},',
      ' "bodyColor": "#rrggbb" (solid) or "gradient": $gradients,',
      ' "finish": ${names(BotFinish.values)}, "fur": true|false,',
      ' "pieces": up to ${BotStudioLimits.maxPieces} objects '
          '{"kind": ${names(BotPieceKind.values)},',
      '   "x": ${_range(BotStudioLimits.piecePositionMin, BotStudioLimits.piecePositionMax)}'
          ' left to right, "y": '
          '${_range(BotStudioLimits.piecePositionMin, BotStudioLimits.piecePositionMax)}'
          ' top to bottom,',
      '   "rotation": ${_range(BotStudioLimits.pieceRotationMin, BotStudioLimits.pieceRotationMax)}'
          ' degrees, "scale": '
          '${_range(BotStudioLimits.pieceScaleMin, BotStudioLimits.pieceScaleMax)}'
          ', "flip": true|false}}',
      'Colours are #rrggbb. Pick values that look good together.',
    ].join('\n');
  }

  static String _range(double min, double max) => '${_num(min)}..${_num(max)}';

  static String _num(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  /// The first JSON object in [reply] that the strict validator accepts, or
  /// null. The reply may carry a Markdown fence and prose around the object.
  /// A JSON that names no key of the schema (`{"a": 1}`) is not accepted.
  static BotSpecResult? readReply(String? reply) {
    if (reply == null) return null;
    final text = reply.length > maxReplyChars
        ? reply.substring(0, maxReplyChars)
        : reply;
    var from = 0;
    for (var tried = 0; tried < maxCandidates; tried++) {
      final start = text.indexOf('{', from);
      if (start < 0) return null;
      final end = _balancedEnd(text, start);
      if (end < 0) {
        from = start + 1;
        continue;
      }
      final candidate = text.substring(start, end + 1);
      from = end + 1;
      final result = BotCharacterSpec.parse(candidate);
      if (result != null && result.recognizedKeys > 0) return result;
    }
    return null;
  }

  /// Index of the `}` closing the object that opens at [start], skipping
  /// strings, or -1 when it never closes or nests deeper than the validator
  /// accepts.
  static int _balancedEnd(String text, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
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
        if (depth > BotCharacterSpec.maxDepth) return -1;
      } else if (c == 0x7d || c == 0x5d) {
        depth--;
        if (depth == 0) return c == 0x7d ? i : -1;
        if (depth < 0) return -1;
      }
    }
    return -1;
  }
}
