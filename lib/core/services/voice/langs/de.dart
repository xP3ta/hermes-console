part of '../voice_language.dart';

class _DeVoiceLanguage extends VoiceLanguage {
  const _DeVoiceLanguage() : super(
    code: "de",
    whisperLanguage: "de",
    systemSttLocales: const ["de_DE", "de_AT", "de_CH", "de-DE", "de"],
    deviceTtsLocales: const ["de-DE", "de-AT", "de-CH"],
    deviceTtsFallback: "de-DE",
    neuralVoiceId: "de_DE-thorsten-medium",
    streamingVoiceId: "af_heart",
    transcript: _deTranscriptGrammar,
    messages: _deVoiceMessages,
    commands: _deVoiceCommands,
    speech: const _DeSpeechGrammar(),
  );

  @override
  String normalizeCommand(String input) => input.toLowerCase()
      .replaceAll('ä', 'ae')
      .replaceAll('ö', 'oe')
      .replaceAll('ü', 'ue')
      .replaceAll('ß', 'ss')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  @override
  LocalVoiceCommand? semanticCommand(String text) {
    // Only complete requests qualify. Quoted controls, negated cancellation,
    // speed changes and explanations cannot match these anchored templates.
    const prefix = r'(?:(?:kannst|koenntest|wuerdest) du (?:bitte )?|'
        r'ich (?:will|moechte) (?:dass du )?|'
        r'ich denke du kannst (?:jetzt )?|du kannst (?:jetzt )?)?';
    const suffix = r'(?: bitte| jetzt| danke)?';
    if (RegExp('^$prefix(?:'
        r'(?:das|dieses) gespraech nicht (?:fortsetzen|weiterfuehren)|'
        r'(?:die|diese) unterhaltung nicht (?:fortsetzen|weiterfuehren)|'
        r'(?:(?:das|dieses) gespraech|(?:die|diese) unterhaltung) '
        r'(?:jetzt )?(?:beenden|abbrechen|schliessen)|'
        r'(?:beende|beenden|beende jetzt|schliesse) '
        r'(?:(?:das|dieses) gespraech|(?:die|diese) unterhaltung)|'
        r'brich (?:(?:das|dieses) gespraech|(?:die|diese) unterhaltung) ab'
        ')$suffix\$').hasMatch(text)) {
      return LocalVoiceCommand.end;
    }
    if (RegExp('^$prefix(?:'
        r'(?:(?:das|dieses) gespraech|(?:die|diese) unterhaltung) '
        r'(?:kurz )?pausieren|'
        r'pausiere (?:(?:das|dieses) gespraech|(?:die|diese) unterhaltung)|'
        r'(?:warte|warten) (?:bitte )?(?:einen moment|einen augenblick)|'
        r'(?:mach|mache|machen) eine pause'
        ')$suffix\$').hasMatch(text)) {
      return LocalVoiceCommand.pause;
    }
    if (RegExp('^$prefix(?:'
        r'(?:aufhoeren|aufhoer|hoer auf|hoere auf) (?:zu sprechen|zu reden|vorzulesen)|'
        r'(?:die sprachausgabe|das vorlesen|die aktuelle antwort|das audio) '
        r'(?:jetzt )?(?:stoppen|abbrechen|beenden|stummschalten)|'
        r'(?:stoppe|beende) (?:die sprachausgabe|das vorlesen|die aktuelle antwort|das audio)|'
        r'brich (?:die sprachausgabe|das vorlesen|die aktuelle antwort|das audio) ab|'
        r'(?:sprich|rede|lies) nicht (?:weiter|mehr)|'
        r'(?:du )?(?:nicht mehr sprechen|nicht mehr reden|nicht weiterreden)|'
        r'(?:dich nicht mehr hoeren|nicht weiter zuhoeren)|'
        r'(?:du )?(?:weiterredest|weitersprichst) nicht|'
        r'nicht dass du (?:weiterredest|weitersprichst)|'
        r'(?:jetzt )?aufhoeren'
        ')$suffix\$').hasMatch(text)) {
      return LocalVoiceCommand.silenceCurrent;
    }
    return null;
  }
}

const _deVoiceCommands = VoiceCommandGrammar(
  silence: [
    'ich will nicht dass du weiterredest',
    'ich moechte dich nicht mehr hoeren',
    'ich will dich nicht mehr hoeren',
    'hoer auf zu sprechen',
    'hoer auf zu reden',
    'hoere auf vorzulesen',
    'sprich nicht weiter',
    'sprich nicht mehr',
    'rede nicht weiter',
    'lies nicht weiter',
    'brich die sprachausgabe ab',
    'stoppe die sprachausgabe',
    'sei still',
    'sei leise',
    'halt den mund',
    'es reicht',
    'genug',
    'ruhe',
  ],
  pause: [
    'pausiere das gespraech',
    'pausiere die unterhaltung',
    'mach eine pause',
    'mache eine pause',
    'lass uns eine pause machen',
    'warte einen moment',
    'warte einen augenblick',
    'pause',
  ],
  end: [
    'ich moechte das gespraech beenden',
    'ich moechte die unterhaltung beenden',
    'beende das gespraech',
    'beende die unterhaltung',
    'brich das gespraech ab',
    'brich die unterhaltung ab',
    'lass uns hier schluss machen',
    'lass uns das gespraech beenden',
  ],
  leading: ['bitte hermes', 'okay hermes', 'hallo hermes', 'hermes', 'bitte',
    'okay', 'ok', 'gut', 'hallo'],
  trailing: ['vielen dank', 'danke schoen', 'bitte', 'danke', 'okay', 'ok'],
  connectors: ['und jetzt', 'und', 'bitte', 'okay', 'ok'],
);

const _deVoiceMessages = <String, String>{
  'microphoneReleasing': 'Das Mikrofon wird noch freigegeben.',
  'microphoneUnclear': 'Ich konnte die Aufnahme nicht verstehen.',
  'didNotHear': 'Ich habe dich nicht gehört.',
  'microphoneUnavailable': 'Das Mikrofon konnte nicht gestartet werden.',
  'sendFailed': 'Die Nachricht konnte nicht gesendet werden.',
  'responseInterrupted': 'Die Antwort wurde unterbrochen.',
  'serverUnavailable': 'Die Sprachausgabe des Hermes-Servers ist nicht verfügbar. Der Sprachmodus wurde pausiert.',
  'approvalRequired': 'Hermes benötigt deine Zustimmung. Öffne die App, um die Anfrage zu prüfen.',
  'responseRequired': 'Hermes benötigt deine Antwort. Öffne die App, um fortzufahren.',
  'stopNotSaved': 'Der Stopp konnte nicht sicher gespeichert werden. Versuche es erneut.',
  'recognitionUnavailable': 'Die Spracherkennung ist nicht bereit ({status}).',
};

const _deSmallNumbers = [
  'null', 'eins', 'zwei', 'drei', 'vier', 'fünf', 'sechs', 'sieben', 'acht',
  'neun', 'zehn', 'elf', 'zwölf', 'dreizehn', 'vierzehn', 'fünfzehn',
  'sechzehn', 'siebzehn', 'achtzehn', 'neunzehn',
];
const _deTens = ['', '', 'zwanzig', 'dreißig', 'vierzig', 'fünfzig',
  'sechzig', 'siebzig', 'achtzig', 'neunzig'];
const _deMonths = ['Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
  'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'];

// Cardinal expansion is deliberately bounded to 0..999,999,999.
String _deNumber(int value) {
  if (value < 0) return 'minus ${_deNumber(-value)}';
  if (value > 999999999) return value.toString();
  if (value < 20) return _deSmallNumbers[value];
  if (value < 100) {
    final unit = value % 10;
    return unit == 0 ? _deTens[value ~/ 10]
        : '${unit == 1 ? 'ein' : _deSmallNumbers[unit]}und${_deTens[value ~/ 10]}';
  }
  if (value < 1000) {
    final hundreds = value ~/ 100;
    return '${hundreds == 1 ? 'ein' : _deNumber(hundreds)}hundert'
        '${value % 100 == 0 ? '' : _deNumber(value % 100)}';
  }
  if (value < 1000000) {
    final thousands = value ~/ 1000;
    return '${thousands == 1 ? 'ein' : _deNumber(thousands)}tausend'
        '${value % 1000 == 0 ? '' : _deNumber(value % 1000)}';
  }
  final millions = value ~/ 1000000;
  return '${millions == 1 ? 'eine Million' : '${_deNumber(millions)} Millionen'}'
      '${value % 1000000 == 0 ? '' : ' ${_deNumber(value % 1000000)}'}';
}

String _deOrdinal(int value) {
  const irregular = {1: 'erster', 3: 'dritter', 7: 'siebter', 8: 'achter'};
  return irregular[value] ?? '${_deNumber(value)}${value < 20 ? 'ter' : 'ster'}';
}

// Exclude adjacent identifier, version, path and time characters. A final
// sentence dot remains allowed, but a dot followed by a digit does not.
const _deNumericLeft = r'(?<![\wÄÖÜäöüß/\\.,:+−-])';
const _deNumericRight = r'(?![\wÄÖÜäöüß/\\:+−-]|[.,]\d)';
const _deAmount = r'(?:\d{1,3}(?:\.\d{3})+(?:,\d+)?|\d+(?:[.,]\d+)?)';

class _DeSpeechGrammar extends VoiceSpeechGrammar {
  const _DeSpeechGrammar();

  @override
  String get linkWord => 'Verweis';
  @override
  String get codeNotice => 'Codeblock ausgelassen.';
  @override
  String get emailAt => ' ät ';
  @override
  String get emailDot => ' Punkt ';
  @override
  String get conjunctionPattern => r'\bund\s*/\s*oder\b';
  @override
  String get orWord => 'und oder';
  @override
  String get decimalSeparator => 'Komma';
  @override
  String get percentUnit => 'Prozent';
  @override
  String get currencyJoiner => ' und ';
  @override
  String get referenceHeadingPattern => 'quellen?|referenzen?|literatur(?:verzeichnis)?';
  @override
  bool get dateMonthFirst => false;
  @override
  bool get decimalUsesDot => false;

  @override
  (String, String, String, String)? currencyNames(String currency) => switch (currency) {
    '€' => ('Euro', 'Euro', 'Cent', 'Cent'),
    r'$' => ('US-Dollar', 'US-Dollar', 'Cent', 'Cent'),
    '£' => ('Pfund Sterling', 'Pfund Sterling', 'Penny', 'Pence'),
    _ => null,
  };

  @override
  String clock(int hour, String minutes) {
    final time = '${hour == 1 ? 'ein' : _deNumber(hour)} Uhr';
    final minute = int.parse(minutes);
    return minute == 0 ? time : '$time ${_deNumber(minute)}';
  }

  @override
  String speakTimes(String input) => input.replaceAllMapped(
      RegExp('$_deNumericLeft([01]?\\d|2[0-3]):([0-5]\\d)$_deNumericRight'),
      (match) => clock(int.parse(match[1]!), match[2]!));

  @override
  String formatDate(int day, int month, int year) =>
      '${_deOrdinal(day)} ${_deMonths[month - 1]} ${_deNumber(year)}';

  @override
  String speakDates(String input) => input.replaceAllMapped(
      RegExp('$_deNumericLeft'
          r'(?:(\d{1,2})([/.])(\d{1,2})\2(\d{4})|'
          r'(\d{4})-(\d{2})-(\d{2}))'
          '$_deNumericRight'), (match) {
        final day = int.parse(match[1] ?? match[7]!);
        final month = int.parse(match[3] ?? match[6]!);
        final year = int.parse(match[4] ?? match[5]!);
        final date = DateTime.utc(year, month, day);
        if (date.year != year || date.month != month || date.day != day) {
          return match[0]!;
        }
        var spoken = formatDate(day, month, year);
        // German dates after am/vom/zum use the dative ordinal ending.
        if (RegExp(r'\b(?:am|vom|zum)\s+$', caseSensitive: false)
            .hasMatch(input.substring(0, match.start))) {
          spoken = spoken.replaceFirst('er ', 'en ');
        }
        return spoken;
      });

  @override
  String formatFraction(String numerator, String denominator) {
    final sign = numerator.startsWith('+') ? 'plus '
        : numerator.startsWith('-') || numerator.startsWith('−') ? 'minus ' : '';
    final top = int.parse(numerator.replaceFirst(RegExp(r'^[+−-]'), ''));
    final bottom = int.parse(denominator);
    if (bottom == 0) return '$numerator/$denominator';
    final quantity = top == 1 ? 'ein' : _deNumber(top);
    if (bottom == 1) return '$sign$quantity ${top == 1 ? 'Ganzes' : 'Ganze'}';
    const names = {3: 'Drittel', 4: 'Viertel', 5: 'Fünftel',
      6: 'Sechstel', 7: 'Siebtel', 8: 'Achtel'};
    final ordinal = _deOrdinal(bottom);
    final unit = bottom == 2 ? (top == 1 ? 'Halb' : 'Halbe')
        : names[bottom] ?? '${ordinal.substring(0, ordinal.length - 2)}el';
    return '$sign$quantity ${unit[0].toUpperCase()}${unit.substring(1)}';
  }

  @override
  String speakFractions(String input) => input.replaceAllMapped(
      RegExp('$_deNumericLeft([+−-]?\\d{1,3})/(\\d{1,3})$_deNumericRight'),
      (match) => formatFraction(match[1]!, match[2]!));

  String _deReadAmount(String raw) {
    var value = raw;
    var sign = '';
    if (value.startsWith('-') || value.startsWith('−')) {
      sign = 'minus ';
      value = value.substring(1);
    } else if (value.startsWith('+')) {
      sign = 'plus ';
      value = value.substring(1);
    }
    if (RegExp(r'^\d{1,3}(?:\.\d{3})+(?:,\d+)?$').hasMatch(value)) {
      value = value.replaceAll('.', '');
    }
    final parts = value.split(RegExp('[,.]'));
    final major = int.tryParse(parts.first);
    if (major == null || major > 999999999) return raw;
    return '$sign${parts.length == 1 ? _deNumber(major) : formatDecimal(parts.first, parts[1])}';
  }

  @override
  String formatDecimal(String major, String minor) =>
      '${_deNumber(int.parse(major))} Komma '
      '${minor.split('').map((digit) => _deSmallNumbers[int.parse(digit)]).join(' ')}';

  @override
  String formatPercentage(String major, String? minor) =>
      '${minor == null ? _deNumber(int.parse(major)) : formatDecimal(major, minor)} Prozent';

  @override
  String speakDecimals(String input) => input.replaceAllMapped(
      RegExp('$_deNumericLeft([+−-]?$_deAmount)$_deNumericRight'),
      (match) => match[1]!.contains(RegExp('[,.]'))
          ? _deReadAmount(match[1]!) : match[0]!);

  @override
  String speakPercentages(String input) => input.replaceAllMapped(
      RegExp('$_deNumericLeft([+−-]?$_deAmount)\\s*%$_deNumericRight'),
      (match) => '${_deReadAmount(match[1]!)} Prozent');

  @override
  String? formatCurrency(String currency, int major, int? minor) {
    final names = currencyNames(currency);
    if (names == null || major.abs() > 999999999) return null;
    final (one, many, subOne, subMany) = names;
    final amount = major == 1 ? 'ein' : _deNumber(major);
    final base = '$amount ${major == 1 ? one : many}';
    if (minor == null || minor == 0) return base;
    return '$base und ${minor == 1 ? 'ein' : _deNumber(minor)} '
        '${minor == 1 ? subOne : subMany}';
  }

  @override
  String? speakCurrencyAmount(String raw, String currency) {
    var value = raw;
    var sign = '';
    if (value.startsWith('-') || value.startsWith('−')) {
      sign = 'minus ';
      value = value.substring(1);
    } else if (value.startsWith('+')) {
      sign = 'plus ';
      value = value.substring(1);
    }
    if (RegExp(r'^\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?$').hasMatch(value)) {
      value = value.replaceAll('.', '');
    }
    final parts = value.split(RegExp('[,.]'));
    if (parts.length > 2 || (parts.length == 2 && parts[1].length > 2)) {
      return null;
    }
    final major = int.tryParse(parts[0]);
    if (major == null) return null;
    final minor = parts.length == 1 ? null : int.tryParse(parts[1].padRight(2, '0'));
    final symbol = switch (currency.toUpperCase()) {
      'USD' => r'$', 'EUR' => '€', 'GBP' => '£', _ => currency,
    };
    final spoken = formatCurrency(symbol, major, minor);
    return spoken == null ? null : '$sign$spoken';
  }

  @override
  String speakCurrencies(String input) {
    const unit = r'(?:USD|EUR|GBP|[€$£])';
    var text = input.replaceAllMapped(
        RegExp('$_deNumericLeft([+−-]?)($unit)\\s*([+−-]?$_deAmount)$_deNumericRight',
            caseSensitive: false), (match) {
          final sign = match[1]!;
          final amount = match[3]!;
          if (sign.isNotEmpty && RegExp(r'^[+−-]').hasMatch(amount)) {
            return match[0]!;
          }
          return speakCurrencyAmount('$sign$amount', match[2]!) ?? match[0]!;
        });
    text = text.replaceAllMapped(
        RegExp('$_deNumericLeft([+−-]?$_deAmount)\\s*($unit)$_deNumericRight',
            caseSensitive: false),
        (match) => speakCurrencyAmount(match[1]!, match[2]!) ?? match[0]!);
    return text;
  }

  @override
  String normalizeNarration(String text) => text.replaceAllMapped(
      RegExp('$_deNumericLeft([+−-]?\\d{1,9})$_deNumericRight'),
      (match) => _deReadAmount(match[1]!));
}

const _deTranscriptGrammar = VoiceTranscriptGrammar(
  nonSpeechLabels: r'musik|geräusche?|stille|lachen|gelächter|applaus',
  // Anchored outros avoid deleting genuine input that merely quotes them.
  subscribeOutro: r'^(?:danke f(?:ü|u)rs zuschauen|vielen dank f(?:ü|u)rs zuschauen|'
      r'bitte abonniert den kanal|abonniert den kanal|abonniere den kanal)$',
  fullReadingWords: r'^(?:bitte )?(?:'
      r'erz(?:ä|ae)hl(?:e)? mir (?:eine geschichte|ein m(?:ä|ae)rchen)|'
      r'lies mir (?:den ganzen text|alles) vor|'
      r'trage mir ein gedicht vor)[.!?]*$',
);
