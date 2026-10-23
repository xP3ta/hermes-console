import '../voice_language.dart';

export '../voice_language.dart' show LocalVoiceCommand;

/// Closed deterministic controls for an already active voice session.
class LocalVoiceCommandDetector {
  const LocalVoiceCommandDetector();

  static const int _maxTranscriptChars = 180;

  LocalVoiceCommand? detect(String transcript, {required String language}) {
    if (transcript.isEmpty || transcript.length > _maxTranscriptChars) return null;
    final locale = voiceLanguages[voiceLanguageCode(language)];
    if (locale == null) return null;
    var text = locale.normalizeCommand(transcript);
    if (text.isEmpty) return null;
    final grammar = locale.commands;
    text = _stripEdges(text, grammar.leading, grammar.trailing, grammar.wordSeparated);
    if (text.isEmpty) return null;
    if (_isCommandSequence(text, grammar.end, grammar.connectors, grammar.wordSeparated)) {
      return LocalVoiceCommand.end;
    }
    if (_isCommandSequence(text, grammar.pause, grammar.connectors, grammar.wordSeparated)) {
      return LocalVoiceCommand.pause;
    }
    if (_isCommandSequence(text, grammar.silence, grammar.connectors, grammar.wordSeparated)) {
      return LocalVoiceCommand.silenceCurrent;
    }
    return locale.semanticCommand(text);
  }

  static bool _isCommandSequence(
    String text,
    List<String> phrases,
    List<String> connectors,
    bool wordSeparated,
  ) {
    var rest = text;
    var matched = false;
    while (rest.isNotEmpty) {
      String? phrase;
      for (final candidate in phrases) {
        if (rest == candidate || rest.startsWith(wordSeparated ? '$candidate ' : candidate)) {
          phrase = candidate;
          break;
        }
      }
      if (phrase == null) return false;
      matched = true;
      rest = rest.substring(phrase.length).trimLeft();
      if (rest.isEmpty) return true;
      rest = _stripLeading(rest, connectors, wordSeparated);
    }
    return matched;
  }

  static String _stripEdges(
    String text,
    List<String> leading,
    List<String> trailing,
    bool wordSeparated,
  ) {
    var value = _stripLeading(text, leading, wordSeparated);
    var changed = true;
    while (changed && value.isNotEmpty) {
      changed = false;
      for (final phrase in trailing) {
        if (value == phrase) return '';
        if (value.endsWith(wordSeparated ? ' $phrase' : phrase)) {
          value = value.substring(0, value.length - phrase.length).trimRight();
          changed = true;
          break;
        }
      }
    }
    return value;
  }

  static String _stripLeading(String text, List<String> phrases, bool wordSeparated) {
    var value = text;
    var changed = true;
    while (changed && value.isNotEmpty) {
      changed = false;
      for (final phrase in phrases) {
        if (value == phrase) return '';
        if (value.startsWith(wordSeparated ? '$phrase ' : phrase)) {
          value = value.substring(phrase.length).trimLeft();
          changed = true;
          break;
        }
      }
    }
    return value;
  }

}
