/// Voice language records are shared by recognition, narration and controls.
library;

part 'langs/es.dart';
part 'langs/en.dart';
part 'langs/pt.dart';
part 'langs/de.dart';
part 'langs/fr.dart';
part 'langs/it.dart';
part 'langs/ja.dart';
part 'langs/ko.dart';
part 'langs/zh.dart';

/// Local controls never become chat prompts or require a server.
enum LocalVoiceCommand { silenceCurrent, pause, end }

abstract class VoiceLanguage {
  final String code;
  final String whisperLanguage;
  final List<String> systemSttLocales;
  final List<String> deviceTtsLocales;
  final String deviceTtsFallback;
  final String? neuralVoiceId;
  final String streamingVoiceId;
  final Map<String, String> messages;
  final VoiceCommandGrammar commands;
  final VoiceSpeechGrammar speech;
  final bool isDraft;
  final bool systemTtsOnly;
  final VoiceTranscriptGrammar transcript;

  const VoiceLanguage({
    required this.code,
    required this.whisperLanguage,
    required this.systemSttLocales,
    required this.deviceTtsLocales,
    required this.deviceTtsFallback,
    required this.neuralVoiceId,
    required this.streamingVoiceId,
    required this.messages,
    required this.commands,
    required this.speech,
    this.isDraft = false,
    this.systemTtsOnly = false,
    required this.transcript,
  });

  String message(String key, [Map<String, Object> arguments = const {}]) {
    final template = messages[key] ?? voiceLanguages['en']!.messages[key]!;
    return template.replaceAllMapped(RegExp(r'\{([A-Za-z_][A-Za-z_0-9]*)\}'),
        (match) => arguments[match[1]]?.toString() ?? match[0]!);
  }

  String normalizeCommand(String input) => _normalizeLatinVoiceCommand(input);
  LocalVoiceCommand? semanticCommand(String text);
}

const voiceLanguages = <String, VoiceLanguage>{
  'es': _EsVoiceLanguage(),
  'en': _EnVoiceLanguage(),
  'pt': _PtVoiceLanguage(),
  'de': _DeVoiceLanguage(),
  'fr': _FrVoiceLanguage(),
  'it': _ItVoiceLanguage(),
  'ja': _JaVoiceLanguage(),
  'ko': _KoVoiceLanguage(),
  'zh': _ZhVoiceLanguage(),
};

String voiceLanguageCode(String value) =>
    value.toLowerCase().split(RegExp('[-_]')).first;

VoiceLanguage voiceLanguageFor(String value) =>
    voiceLanguages[voiceLanguageCode(value)] ?? voiceLanguages['en']!;

String get voiceReferenceHeadingPattern =>
    '^(?:${voiceLanguages.values.map((language) => language.speech.referenceHeadingPattern).join('|')})'
    r'(?:\s*:|\s*$)';

class VoiceCommandGrammar {
  final bool wordSeparated;
  final List<String> silence;
  final List<String> pause;
  final List<String> end;
  final List<String> leading;
  final List<String> trailing;
  final List<String> connectors;

  const VoiceCommandGrammar({
    this.wordSeparated = true,
    required this.silence,
    required this.pause,
    required this.end,
    required this.leading,
    required this.trailing,
    required this.connectors,
  });
}

bool _hasStem(List<String> words, List<String> stems) =>
    words.any((word) => stems.any(word.startsWith));

bool _containsAny(String text, List<String> phrases) =>
    phrases.any(text.contains);

String _normalizeLatinVoiceCommand(String input) {
  var value = input.toLowerCase();
  const replacements = <String, String>{
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'â': 'a',
    'ã': 'a',
    'é': 'e',
    'è': 'e',
    'ë': 'e',
    'ê': 'e',
    'í': 'i',
    'ì': 'i',
    'ï': 'i',
    'î': 'i',
    'ó': 'o',
    'ò': 'o',
    'ö': 'o',
    'ô': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'ü': 'u',
    'û': 'u',
    'ñ': 'n',
    'ç': 'c',
    '’': '',
    "'": '',
  };
  for (final entry in replacements.entries) {
    value = value.replaceAll(entry.key, entry.value);
  }
  return value
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

abstract class VoiceSpeechGrammar {
  const VoiceSpeechGrammar();

  String get linkWord;
  String get codeNotice;
  String get emailAt;
  String get emailDot;
  String get orWord;
  String get conjunctionPattern;
  String get decimalSeparator;
  String get percentUnit;
  String get currencyJoiner;
  String get referenceHeadingPattern;
  bool get dateMonthFirst;
  bool get decimalUsesDot;
  (String, String, String, String)? currencyNames(String currency);
  String clock(int hour, String minutes);
  String formatDate(int day, int month, int year);
  String formatFraction(String numerator, String denominator);

  /// Final language-specific number and spacing normalization after markup cleanup.
  String normalizeNarration(String text) => text;

  String joinParagraph(List<String> lines) => lines.join(' ');
  String joinTableCells(List<String> cells) => cells.join(', ');

  String speakConjunctions(String input) => input.replaceAllMapped(
      RegExp(conjunctionPattern, caseSensitive: false), (_) => orWord);

  String withTerminalPunctuation(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || RegExp(r'[.!?…]$').hasMatch(trimmed)) return trimmed;
    return '$trimmed.';
  }

  String speakTimes(String input) => input.replaceAllMapped(
      RegExp(r'\b([01]?\d|2[0-3]):([0-5]\d)\b'),
      (match) => clock(int.parse(match[1]!), match[2]!));

  String speakDates(String input) => input.replaceAllMapped(
      RegExp(r'\b(\d{1,2})/(\d{1,2})/(\d{4})\b'), (match) {
    final first = int.tryParse(match[1] ?? '');
    final second = int.tryParse(match[2] ?? '');
    final year = int.tryParse(match[3] ?? '');
    if (first == null || second == null || year == null) return match[0] ?? '';
    final day = dateMonthFirst ? second : first;
    final month = dateMonthFirst ? first : second;
    if (day < 1 || day > 31 || month < 1 || month > 12) return match[0] ?? '';
    return formatDate(day, month, year);
  });

  String speakFractions(String input) => input.replaceAllMapped(
      RegExp(r'\b(\d{1,3})/(\d{1,3})\b'),
      (match) => formatFraction(match[1] ?? '', match[2] ?? ''));

  String speakPercentages(String input) => input.replaceAllMapped(
      RegExp(r'\b(\d+)(?:[.,](\d+))?\s*%'),
      (match) => formatPercentage(match[1] ?? '', match[2]));

  String formatPercentage(String major, String? minor) {
    final amount = minor == null ? major : '$major $decimalSeparator $minor';
    return '$amount $percentUnit';
  }

  String speakDecimals(String input) => input.replaceAllMapped(
      decimalUsesDot ? RegExp(r'\b(\d+)\.(\d+)\b') : RegExp(r'\b(\d+),(\d+)\b'),
      (match) => formatDecimal(match[1] ?? '', match[2] ?? ''));

  String formatDecimal(String major, String minor) =>
      '$major $decimalSeparator $minor';

  String speakCurrencies(String input) {
    var result = input.replaceAllMapped(
      RegExp(
        r'\b(USD|EUR|GBP)\s*(\d+(?:[.,]\d{1,2})?)\b',
        caseSensitive: false,
      ),
      (match) =>
          speakCurrencyAmount(match.group(2) ?? '', match.group(1) ?? '') ??
          (match.group(0) ?? ''),
    );
    result = result.replaceAllMapped(
      RegExp(
        r'\b(\d+(?:[.,]\d{1,2})?)\s*(USD|EUR|GBP)\b',
        caseSensitive: false,
      ),
      (match) =>
          speakCurrencyAmount(match.group(1) ?? '', match.group(2) ?? '') ??
          (match.group(0) ?? ''),
    );
    result = result.replaceAllMapped(
      RegExp(r'([€$£])\s*(\d+(?:[.,]\d{1,2})?)'),
      (match) =>
          speakCurrencyAmount(match.group(2) ?? '', match.group(1) ?? '') ??
          (match.group(0) ?? ''),
    );
    result = result.replaceAllMapped(
      RegExp(r'(\d+(?:[.,]\d{1,2})?)\s*([€$£])'),
      (match) =>
          speakCurrencyAmount(match.group(1) ?? '', match.group(2) ?? '') ??
          (match.group(0) ?? ''),
    );
    return result;
  }

  String? speakCurrencyAmount(String raw, String currency) {
    final decimalAt = raw.lastIndexOf(RegExp(r'[,.]'));
    String majorRaw = raw;
    String? minorRaw;
    if (decimalAt >= 0 && raw.length - decimalAt - 1 <= 2) {
      majorRaw = raw.substring(0, decimalAt);
      minorRaw = raw.substring(decimalAt + 1);
    }
    final major = int.tryParse(majorRaw.replaceAll(RegExp(r'[,.]'), ''));
    if (major == null || (minorRaw != null && minorRaw.isEmpty)) return null;
    final minor = minorRaw == null
        ? null
        : int.tryParse(minorRaw.padRight(2, '0'));
    if (minorRaw != null && minor == null) return null;

    final normalizedCurrency = switch (currency.toUpperCase()) {
      'USD' => r'$',
      'EUR' => '€',
      'GBP' => '£',
      _ => currency,
    };
    return formatCurrency(normalizedCurrency, major, minor);
  }

  String? formatCurrency(String currency, int major, int? minor) {
    final names = currencyNames(currency);
    if (names == null) return null;
    final (unitOne, unitMany, subunitOne, subunitMany) = names;
    final unit = major == 1 ? unitOne : unitMany;
    final base = '$major $unit';
    if (minor == null || minor == 0) return base;
    final subunit = minor == 1 ? subunitOne : subunitMany;
    return '$base$currencyJoiner$minor $subunit';
  }
}

/// Patterns are applied across registered languages, as in the existing filter.
class VoiceTranscriptGrammar {
  final String fullReadingWords;
  final List<String> fullReadingPhrases;
  final String nonSpeechLabels;
  final List<String> strongMarkers;
  final String subscribeOutro;

  const VoiceTranscriptGrammar({
    this.fullReadingWords = r'(?!)',
    this.fullReadingPhrases = const [],
    this.nonSpeechLabels = r'(?!)',
    this.strongMarkers = const [],
    this.subscribeOutro = r'(?!)',
  });
}
