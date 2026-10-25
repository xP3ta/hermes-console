part of '../voice_language.dart';

class _FrVoiceLanguage extends VoiceLanguage {
  const _FrVoiceLanguage() : super(
    code: "fr",
    whisperLanguage: "fr",
    systemSttLocales: const ["fr_FR", "fr_CA", "fr_BE", "fr-CH", "fr-FR", "fr"],
    deviceTtsLocales: const ["fr-FR", "fr-CA", "fr-BE", "fr-CH"],
    deviceTtsFallback: "fr-FR",
    neuralVoiceId: "fr_FR-siwis-medium",
    streamingVoiceId: "af_heart",
    transcript: _frTranscriptGrammar,
    messages: _frVoiceMessages,
    commands: _frVoiceCommands,
    speech: const _FrSpeechGrammar(),
  );

  @override
  LocalVoiceCommand? semanticCommand(String text) {
    // Match whole requests: quoted controls and negated cancellation are content.
    final request = RegExp(
      r'^(?:(?:est ce que |est ce que tu |tu |vous )?'
      r'(?:peux |peux tu |pouvez |pouvez vous |pourrais tu |pourriez vous )|'
      r'je (?:veux |voudrais |souhaite )|'
      r'je pense que tu peux |je crois que tu peux )?',
    );
    final action = text.replaceFirst(request, '')
        .replaceFirst(RegExp(r' maintenant$'), '');
    if (RegExp(r'^(?:arreter|arrete|cesser|cesse) de (?:parler|lire)$|'
        r'^(?:couper|coupe|arreter|arrete|annuler|annule) '
        r'(?:le son|la voix|laudio|la lecture|la locution)$|'
        r'^je ne veux plus (?:tentendre|vous entendre|ecouter|que tu parles)$|'
        r'^ne (?:parle|lis|continue) plus$').hasMatch(action)) {
      return LocalVoiceCommand.silenceCurrent;
    }
    if (RegExp(r'^(?:terminer|termine|fermer|ferme|annuler|annule|'
        r'arreter|arrete|clore) (?:la|cette) (?:conversation|session)$|'
        r'^je ne veux plus continuer (?:la|cette) conversation$')
        .hasMatch(action)) {
      return LocalVoiceCommand.end;
    }
    if (RegExp(r'^(?:mettre|mets|mettez) (?:la|cette) conversation en pause$|'
        r'^(?:faire|fais|faites) une pause$|'
        r'^(?:attends|attendez|attendre) (?:un instant|un moment|une seconde)$')
        .hasMatch(action)) {
      return LocalVoiceCommand.pause;
    }
    return null;
  }
}

const _frVoiceCommands = VoiceCommandGrammar(
  silence: [
    'je ne veux plus que tu continues a parler',
    'je ne veux plus que tu parles',
    'je ne veux plus tentendre',
    'je veux que tu arretes de parler',
    'je veux que tu te taises',
    'tu peux arreter de parler',
    'arrete de parler',
    'cesse de parler',
    'arrete de lire',
    'ne continue pas a parler',
    'ne parle plus',
    'tais toi',
    'taisez vous',
    'reste tranquille',
    'ca suffit',
    'silence',
    'assez',
    'annule la lecture',
  ],
  pause: [
    'mets la conversation en pause',
    'mettez la conversation en pause',
    'fais une pause',
    'faites une pause',
    'faisons une pause',
    'pause',
  ],
  end: [
    'je veux terminer la conversation',
    'je veux fermer la conversation',
    'termine la conversation',
    'ferme la conversation',
    'annule la conversation',
    'arrete la conversation',
    'arretons nous ici',
    'on sarrete ici',
  ],
  leading: [
    'sil te plait hermes', 'bonjour hermes', 'hermes',
    'sil te plait', 'sil vous plait', 'ecoute', 'daccord', 'bon', 'ok',
  ],
  trailing: [
    'sil te plait', 'sil vous plait', 'merci beaucoup', 'merci', 'daccord', 'ok',
  ],
  connectors: ['et maintenant', 'et aussi', 'et', 'sil te plait'],
);

const _frVoiceMessages = <String, String>{
  'microphoneReleasing': 'Le microphone est encore en cours de libération.',
  'microphoneUnclear': 'Je n’ai pas compris ce qui a été dit au microphone.',
  'didNotHear': 'Je ne vous ai pas entendu.',
  'microphoneUnavailable': 'Impossible de démarrer le microphone.',
  'sendFailed': 'Impossible d’envoyer le message.',
  'responseInterrupted': 'La réponse a été interrompue.',
  'serverUnavailable': 'La voix du serveur Hermes est indisponible. Le mode vocal a été mis en pause.',
  'approvalRequired': 'Hermes a besoin de votre autorisation. Ouvrez l’application pour la vérifier.',
  'responseRequired': 'Hermes attend votre réponse. Ouvrez l’application pour continuer.',
  'stopNotSaved': 'Impossible d’enregistrer l’arrêt en toute sécurité. Réessayez.',
  'recognitionUnavailable': 'La reconnaissance vocale n’est pas prête ({status}).',
};

// The shared policy only partially folds French accents. Accept both forms.
const _frTranscriptGrammar = VoiceTranscriptGrammar(
  fullReadingWords: r'\b(?:conte|contes|poeme|poemes|poème|poèmes|fable|fables|comptine|comptines)\b',
  fullReadingPhrases: ['raconte-moi une histoire', 'raconte moi une histoire',
    'lis ce texte en entier', 'lis-moi ce texte', 'lis moi ce texte'],
  nonSpeechLabels: r'musique|bruit|silence|rires?|applaudissements',
  // Substring markers cannot safely distinguish quotations from requests.
  strongMarkers: [],
  subscribeOutro: r'^(?:abonnez vous|abonne toi) (?:a|à) la (?:chaine|chaîne)$',
);

class _FrSpeechGrammar extends VoiceSpeechGrammar {
  const _FrSpeechGrammar();

  @override
  String get linkWord => 'lien';
  @override
  String get codeNotice => 'Bloc de code omis.';
  @override
  String get emailAt => ' arobase ';
  @override
  String get emailDot => ' point ';
  @override
  String get conjunctionPattern => r'\bet\s*/\s*ou\b';
  @override
  String get orWord => 'et ou';
  @override
  String get decimalSeparator => 'virgule';
  @override
  String get percentUnit => 'pour cent';
  @override
  String get currencyJoiner => ' et ';
  @override
  String get referenceHeadingPattern => r'sources?|r[eé]f[eé]rences?|bibliographie';
  @override
  bool get dateMonthFirst => false;
  @override
  bool get decimalUsesDot => false;

  @override
  (String, String, String, String)? currencyNames(String currency) => switch (currency) {
    '€' => ('euro', 'euros', 'centime', 'centimes'),
    r'$' => ('dollar américain', 'dollars américains', 'cent', 'cents'),
    '£' => ('livre sterling', 'livres sterling', 'penny', 'pence'),
    _ => null,
  };

  @override
  String? formatCurrency(String currency, int major, int? minor) {
    final names = currencyNames(currency);
    if (names == null) return null;
    final (one, many, subone, submany) = names;
    final amount = _frNumber(major, feminine: currency == '£');
    // French zero and fractional values below two take the singular noun.
    final base = '$amount ${major.abs() < 2 ? one : many}';
    if (minor == null || minor == 0) return base;
    return '$base et ${_frNumber(minor)} ${minor == 1 ? subone : submany}';
  }

  @override
  String speakCurrencies(String input) => _frInProse(input, (text) {
    final pattern = RegExp(
      r'(?<![\w/.:,])([+−-]?)(?:(USD|EUR|GBP|[€$£])\s*(\d+(?:[.,]\d{1,2})?)|'
      r'(\d+(?:[.,]\d{1,2})?)\s*(USD|EUR|GBP|[€$£]))(?![\w/.:,]\d|\w)',
      caseSensitive: false,
    );
    return text.replaceAllMapped(pattern, (match) {
      final amount = speakCurrencyAmount(match[3] ?? match[4]!, match[2] ?? match[5]!);
      final sign = switch (match[1]) { '-' || '−' => 'moins ', '+' => 'plus ', _ => '' };
      return amount == null ? match[0]! : '$sign$amount';
    });
  });

  @override
  String clock(int hour, String minutes) {
    final minute = int.parse(minutes);
    final base = switch (hour) {
      0 => 'minuit',
      12 => 'midi',
      _ => '${_frNumber(hour, feminine: true)} ${hour == 1 ? 'heure' : 'heures'}',
    };
    return minute == 0 ? base : '$base ${_frNumber(minute)}';
  }

  static const _frMonths = [
    'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
  ];

  @override
  String formatDate(int day, int month, int year) =>
      '${day == 1 ? 'premier' : _frNumber(day)} ${_frMonths[month - 1]} ${_frNumber(year)}';

  @override
  String speakDates(String input) => _frInProse(input, (text) => text.replaceAllMapped(
    RegExp(r'(?<![\w/.:,])(\d{1,2})/(\d{1,2})/(\d{4})(?![\w/.:,]\d|\w)'),
    (match) {
      final day = int.parse(match[1]!);
      final month = int.parse(match[2]!);
      final year = int.parse(match[3]!);
      final date = DateTime.utc(year, month, day);
      if (year < 1 || date.year != year || date.month != month || date.day != day) {
        return match[0]!;
      }
      return formatDate(day, month, year);
    },
  ));

  @override
  String speakTimes(String input) => _frInProse(input, (text) => text.replaceAllMapped(
    RegExp(r'(?<![\w/.:,])([01]?\d|2[0-3]):([0-5]\d)(?![\w/.:,]\d|\w)'),
    (match) => clock(int.parse(match[1]!), match[2]!),
  ));

  @override
  String formatFraction(String numerator, String denominator) {
    final n = int.parse(numerator);
    final d = int.parse(denominator);
    if (d == 0) return '$numerator/$denominator';
    final unit = switch (d) {
      2 => n > 1 ? 'demis' : 'demi',
      3 => 'tiers',
      4 => n > 1 ? 'quarts' : 'quart',
      5 => n > 1 ? 'cinquièmes' : 'cinquième',
      6 => n > 1 ? 'sixièmes' : 'sixième',
      7 => n > 1 ? 'septièmes' : 'septième',
      8 => n > 1 ? 'huitièmes' : 'huitième',
      9 => n > 1 ? 'neuvièmes' : 'neuvième',
      10 => n > 1 ? 'dixièmes' : 'dixième',
      _ => null,
    };
    return unit == null ? '${_frNumber(n)} sur ${_frNumber(d)}' : '${_frNumber(n)} $unit';
  }

  @override
  String speakFractions(String input) => _frInProse(input, (text) => text.replaceAllMapped(
    RegExp(r'(?<![\w/.:,])(\d{1,3})/(\d{1,3})(?![\w/.:,]\d|\w|/)'),
    (match) => formatFraction(match[1]!, match[2]!),
  ));

  @override
  String formatDecimal(String major, String minor) {
    final number = int.tryParse(major);
    final whole = number == null ? major : _frNumber(number);
    final digits = minor.split('').map((digit) => _frNumber(int.parse(digit))).join(' ');
    return '$whole virgule $digits';
  }

  @override
  String formatPercentage(String major, String? minor) =>
      '${minor == null ? _frWhole(major) : formatDecimal(major, minor)} pour cent';

  @override
  String speakPercentages(String input) => _frInProse(input, (text) => text.replaceAllMapped(
    RegExp(r'(?<![\w/.:,])([+−-]?)(\d+)(?:[.,](\d+))?\s*%'),
    (match) => '${_frSign(match[1]!)}${formatPercentage(match[2]!, match[3])}',
  ));

  @override
  String speakDecimals(String input) => _frInProse(input, (text) => text.replaceAllMapped(
    RegExp(r'(?<![\w/.:,])([+−-]?)(\d+)[.,](\d+)(?![\w/.:,]\d|\w)'),
    (match) => '${_frSign(match[1]!)}${formatDecimal(match[2]!, match[3]!)}',
  ));

  @override
  String normalizeNarration(String text) => _frInProse(text, (part) => part.replaceAllMapped(
    RegExp(r'(?<![\w/.:,])([+−-]?)(\d+)(?![\w/.:,]\d|\w|/)'),
    (match) {
      final number = int.tryParse(match[2]!);
      if (number == null || number > 999999999) return match[0]!;
      return '${_frSign(match[1]!)}${_frNumber(number)}';
    },
  ));
}

String _frWhole(String raw) {
  final number = int.tryParse(raw);
  return number == null ? raw : _frNumber(number);
}

String _frSign(String sign) => switch (sign) {
  '-' || '−' => 'moins ', '+' => 'plus ', _ => '',
};

// Keep numeric paths, identifiers and version strings out of speech rewrites.
// Shared renderer path/markup humanization still applies after this grammar.
String _frInProse(String input, String Function(String) transform) {
  final technical = RegExp(
    r'(?<![\w/])(?:[A-Za-z]:[\\/]|[~/.]*[A-Za-z_][\w.-]*[\\/]|/)[\w./\\-]+'
    r'|\b[A-Za-z_]\w*\d[\w.:-]*'
    r'|\b\d+(?:\.\d+){2,}\b',
  );
  final output = StringBuffer();
  var offset = 0;
  for (final match in technical.allMatches(input)) {
    output.write(transform(input.substring(offset, match.start)));
    output.write(match[0]);
    offset = match.end;
  }
  output.write(transform(input.substring(offset)));
  return output.toString();
}

// Standard metropolitan French cardinal numbers, through 999,999,999.
String _frNumber(int value, {bool feminine = false}) {
  if (value < 0) return 'moins ${_frNumber(-value, feminine: feminine)}';
  if (value > 999999999) return '$value';
  const small = ['zéro', 'un', 'deux', 'trois', 'quatre', 'cinq', 'six',
    'sept', 'huit', 'neuf', 'dix', 'onze', 'douze', 'treize', 'quatorze',
    'quinze', 'seize'];
  if (value < 17) return value == 1 && feminine ? 'une' : small[value];
  if (value < 20) return 'dix-${small[value - 10]}';
  if (value < 70) {
    const tens = ['', '', 'vingt', 'trente', 'quarante', 'cinquante', 'soixante'];
    final remainder = value % 10;
    final base = tens[value ~/ 10];
    if (remainder == 0) return base;
    final tail = _frNumber(remainder, feminine: feminine);
    return remainder == 1 ? '$base et $tail' : '$base-$tail';
  }
  if (value < 80) {
    return value == 71 ? 'soixante et onze' : 'soixante-${_frNumber(value - 60)}';
  }
  if (value < 100) {
    return value == 80 ? 'quatre-vingts' : 'quatre-vingt-${_frNumber(value - 80, feminine: feminine)}';
  }
  if (value < 1000) {
    final hundreds = value ~/ 100;
    final remainder = value % 100;
    final base = hundreds == 1 ? 'cent' : '${small[hundreds]} cent';
    return remainder == 0 ? '$base${hundreds > 1 ? 's' : ''}'
        : '$base ${_frNumber(remainder, feminine: feminine)}';
  }
  if (value < 1000000) {
    final thousands = value ~/ 1000;
    final remainder = value % 1000;
    final prefix = _frNumber(thousands).replaceFirst(RegExp(r'(cents|vingts)$'),
        thousands % 100 == 80 ? 'vingt' : 'cent');
    final base = thousands == 1 ? 'mille' : '$prefix mille';
    return remainder == 0 ? base : '$base ${_frNumber(remainder, feminine: feminine)}';
  }
  final millions = value ~/ 1000000;
  final remainder = value % 1000000;
  final base = '${_frNumber(millions)} ${millions == 1 ? 'million' : 'millions'}';
  return remainder == 0 ? base : '$base ${_frNumber(remainder, feminine: feminine)}';
}
