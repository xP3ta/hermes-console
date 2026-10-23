part of '../voice_language.dart';

class _ItVoiceLanguage extends VoiceLanguage {
  const _ItVoiceLanguage()
      : super(
          code: 'it',
          whisperLanguage: 'it',
          systemSttLocales: const ['it_IT', 'it_CH', 'it-IT', 'it'],
          deviceTtsLocales: const ['it-IT', 'it-CH'],
          deviceTtsFallback: 'it-IT',
          neuralVoiceId: 'it_IT-paola-medium',
          streamingVoiceId: 'af_heart',
          transcript: _itTranscriptGrammar,
          messages: _itVoiceMessages,
          commands: _itVoiceCommands,
          speech: const _ItSpeechGrammar(),
        );

  @override
  LocalVoiceCommand? semanticCommand(String text) {
    // Whole requests only: quoted controls, negated cancellation and questions
    // about controls must remain ordinary content. Confirmation and repetition
    // have no corresponding runtime command in the current shared contract.
    final normalized = normalizeCommand(text);
    const request = r'(?:(?:puoi|potresti|potete|vorrei|voglio|ti chiedo di|'
        r'saresti cosi gentile da|credo che tu possa) )?';
    const end = r'(?:terminare|termina|chiudere|chiudi|concludere|concludi|'
        r'cancellare|cancella|interrompere|interrompi) '
        r'(?:la|questa) (?:conversazione|sessione)';
    if (RegExp('^$request$end\$').hasMatch(normalized) ||
        normalized == 'non voglio continuare la conversazione') {
      return LocalVoiceCommand.end;
    }
    const pause = r'(?:mettere|metti) in pausa (?:la|questa) conversazione|'
        r'(?:fare|fai) una pausa|(?:aspettare|aspetta|attendere|attendi) '
        r'(?:un momento|un attimo|un secondo)';
    if (RegExp('^$request(?:$pause)\$').hasMatch(normalized)) {
      return LocalVoiceCommand.pause;
    }
    const silence = r'(?:(?:smettere|smetti|smettila) di (?:parlare|leggere)|'
        r'(?:interrompere|interrompi|fermare|ferma|cancellare|cancella) '
        r'(?:la lettura|la locuzione|la voce|laudio)|'
        r'(?:smettere|smetti|fermarti|fermati) (?:adesso|ora))';
    if (RegExp('^$request$silence(?: adesso| ora)?\$')
        .hasMatch(normalized)) {
      return LocalVoiceCommand.silenceCurrent;
    }
    if (const {
      'non voglio che continui a parlare',
      'non voglio che tu continui a parlare',
      'non voglio piu sentirti',
      'non voglio piu ascoltarti',
      'non continuare a parlare',
      'non parlare piu',
    }.contains(normalized)) {
      return LocalVoiceCommand.silenceCurrent;
    }
    return null;
  }
}

const _itVoiceCommands = VoiceCommandGrammar(
  silence: [
    'non voglio che tu continui a parlare',
    'non voglio che continui a parlare',
    'non voglio piu sentirti',
    'non voglio piu ascoltarti',
    'voglio che tu smetta di parlare',
    'puoi smettere di parlare',
    'non continuare a parlare',
    'smetti di parlare',
    'smetti di leggere',
    'non parlare piu',
    'cancella la lettura',
    'interrompi laudio',
    'stai zitto',
    'stai zitta',
    'basta cosi',
    'silenzio',
    'basta',
  ],
  pause: [
    'metti in pausa la conversazione',
    'pausa la conversazione',
    'facciamo una pausa',
    'fai una pausa',
    'pausa',
  ],
  end: [
    'voglio terminare la conversazione',
    'voglio chiudere la conversazione',
    'termina la conversazione',
    'concludi la conversazione',
    'chiudi la conversazione',
    'cancella la conversazione',
    'fermiamoci qui',
    'concludiamo qui',
  ],
  leading: ['per favore hermes', 'ciao hermes', 'hermes', 'per favore',
    'ascolta', 'va bene', 'allora', 'okay', 'ok', 'ciao'],
  trailing: ['per favore', 'grazie mille', 'grazie', 'va bene', 'okay', 'ok'],
  connectors: ['e anche', 'e adesso', 'e', 'okay', 'ok', 'per favore'],
);

const _itVoiceMessages = <String, String>{
  'microphoneReleasing': 'Il microfono è ancora in fase di rilascio.',
  'microphoneUnclear': 'Non ho capito ciò che hai detto al microfono.',
  'didNotHear': 'Non ti ho sentito.',
  'microphoneUnavailable': 'Non è stato possibile avviare il microfono.',
  'sendFailed': 'Non è stato possibile inviare il messaggio.',
  'responseInterrupted': 'La risposta è stata interrotta.',
  'serverUnavailable': 'La voce del server Hermes non è disponibile. La voce è stata messa in pausa.',
  'approvalRequired': 'Hermes ha bisogno della tua approvazione. Apri l’app per esaminarla.',
  'responseRequired': 'Hermes ha bisogno della tua risposta. Apri l’app per continuare.',
  'stopNotSaved': 'Non è stato possibile salvare l’arresto in sicurezza. Riprova.',
  'recognitionUnavailable': 'Il riconoscimento vocale non è pronto ({status}).',
};

const _itTranscriptGrammar = VoiceTranscriptGrammar(
  fullReadingWords: r'\b(?:fiaba|fiabe|favola|favole|racconto|racconti|poesia|poesie|filastrocca|barzelletta)\b',
  fullReadingPhrases: ['raccontami una storia', 'leggimi una storia', 'leggimi questo'],
  nonSpeechLabels: r'musica|rumore|silenzio|risate|applausi',
  // No substring markers: mentioning an outro in a request is valid speech.
  subscribeOutro: r'^(?:per favore )?iscriviti al canale$',
);

// Do not rewrite numbers inside identifiers, paths, versions or malformed
// dates/times. This is local to Italian and runs before the shared cleanup.
String _itMapProse(String input, String Function(String) transform) {
  final technical = RegExp(
    r'(?:[A-Za-zÀ-ÿ_][A-Za-zÀ-ÿ_0-9.-]*\d[A-Za-zÀ-ÿ_0-9.-]*|'
    r'\d+(?:\.\d+){2,}|'
    r'(?:[\w~.-]+)?[/\\][\w./\\-]+|'
    r'\d{1,2}/\d{1,2}/\d{4}|\d+:\d+)');
  final result = StringBuffer();
  var previous = 0;
  for (final match in technical.allMatches(input)) {
    result.write(transform(input.substring(previous, match.start)));
    result.write(match[0]);
    previous = match.end;
  }
  result.write(transform(input.substring(previous)));
  return result.toString();
}

String _itNumber(int value) {
  if (value < 0) return 'meno ${_itNumber(-value)}';
  if (value > 999999999) return '$value';
  const small = ['zero', 'uno', 'due', 'tre', 'quattro', 'cinque', 'sei',
    'sette', 'otto', 'nove', 'dieci', 'undici', 'dodici', 'tredici',
    'quattordici', 'quindici', 'sedici', 'diciassette', 'diciotto', 'diciannove'];
  if (value < 20) return small[value];
  if (value < 100) {
    const tens = ['', '', 'venti', 'trenta', 'quaranta', 'cinquanta',
      'sessanta', 'settanta', 'ottanta', 'novanta'];
    var prefix = tens[value ~/ 10];
    final remainder = value % 10;
    if (remainder == 1 || remainder == 8) {
      prefix = prefix.substring(0, prefix.length - 1);
    }
    return '$prefix${remainder == 0 ? '' : remainder == 3 ? 'tré' : small[remainder]}';
  }
  if (value < 1000) {
    final remainder = value % 100;
    final hundred = remainder == 8 || (remainder >= 80 && remainder < 90)
        ? 'cent' : 'cento';
    return '${value < 200 ? '' : small[value ~/ 100]}$hundred'
        '${remainder == 0 ? '' : remainder == 3 ? 'tré' : _itNumber(remainder)}';
  }
  if (value < 1000000) {
    return '${value < 2000 ? 'mille' : '${_itNumber(value ~/ 1000).replaceFirst(RegExp(r"tré$"), "tre")}mila'}'
        '${value % 1000 == 0 ? '' : value % 1000 == 3 ? 'tré' : _itNumber(value % 1000)}';
  }
  return '${value < 2000000 ? 'un milione' : '${_itNumber(value ~/ 1000000)} milioni'}'
      '${value % 1000000 == 0 ? '' : ' ${_itNumber(value % 1000000)}'}';
}

String _itDigits(String raw) => raw.split('')
    .map((digit) => _itNumber(int.parse(digit))).join(' ');

class _ItSpeechGrammar extends VoiceSpeechGrammar {
  const _ItSpeechGrammar();

  @override
  String get linkWord => 'collegamento';
  @override
  String get codeNotice => 'Blocco di codice omesso.';
  @override
  String get emailAt => ' chiocciola ';
  @override
  String get emailDot => ' punto ';
  @override
  String get conjunctionPattern => r'\be\s*/\s*o\b';
  @override
  String get orWord => 'e oppure';
  @override
  String get decimalSeparator => 'virgola';
  @override
  String get percentUnit => 'per cento';
  @override
  String get currencyJoiner => ' e ';
  @override
  String get referenceHeadingPattern => 'fonti|riferimenti|bibliografia';
  @override
  bool get dateMonthFirst => false;
  @override
  bool get decimalUsesDot => false;

  @override
  (String, String, String, String)? currencyNames(String currency) =>
      switch (currency) {
        '€' => ('euro', 'euro', 'centesimo', 'centesimi'),
        r'$' => ('dollaro', 'dollari', 'centesimo', 'centesimi'),
        '£' => ('sterlina', 'sterline', 'penny', 'penny'),
        _ => null,
      };

  @override
  String? formatCurrency(String currency, int major, int? minor) {
    final names = currencyNames(currency);
    if (names == null || major < 0 || major > 999999999) return null;
    final (one, many, subOne, subMany) = names;
    final amount = major == 1 ? (currency == '£' ? 'una' : 'un')
        : _itNumber(major);
    final base = '$amount ${major == 1 ? one : many}';
    if (minor == null || minor == 0) return base;
    return '$base e ${minor == 1 ? 'un' : _itNumber(minor)} '
        '${minor == 1 ? subOne : subMany}';
  }

  @override
  String speakCurrencies(String input) => _itMapProse(input, (text) {
    const amount = r'(\d+(?:[.,]\d{1,2})?)';
    const unit = r'(USD|EUR|GBP|[€$£])';
    final prefix = RegExp('(?<![\\w.,])([+-]?)$unit\\s*$amount(?![\\w]|[.,]\\d)',
        caseSensitive: false);
    final suffix = RegExp('(?<![\\w.,])([+-]?)$amount\\s*$unit(?![A-Za-z])',
        caseSensitive: false);
    var result = text.replaceAllMapped(prefix, (match) {
      final spoken = speakCurrencyAmount(match[3]!, match[2]!);
      return spoken == null ? match[0]! : '${_itSign(match[1]!)}$spoken';
    });
    result = result.replaceAllMapped(suffix, (match) {
      final spoken = speakCurrencyAmount(match[2]!, match[3]!);
      return spoken == null ? match[0]! : '${_itSign(match[1]!)}$spoken';
    });
    return result;
  });

  @override
  String formatDecimal(String major, String minor) {
    final value = int.tryParse(major);
    if (value == null || value > 999999999) return '$major,$minor';
    return '${_itNumber(value)} virgola ${_itDigits(minor)}';
  }

  @override
  String formatPercentage(String major, String? minor) {
    final value = int.tryParse(major);
    if (value == null || value > 999999999) {
      return minor == null ? '$major%' : '$major,$minor%';
    }
    return '${minor == null ? _itNumber(value) : formatDecimal(major, minor)} per cento';
  }

  @override
  String speakDecimals(String input) => _itMapProse(input, (text) =>
      text.replaceAllMapped(RegExp(r'(?<![\w.,])([+-]?)(\d+)[.,](\d+)(?![\w]|[.,]\d)'),
          (match) => '${_itSign(match[1]!)}${formatDecimal(match[2]!, match[3]!)}'));

  @override
  String speakPercentages(String input) => _itMapProse(input, (text) =>
      text.replaceAllMapped(RegExp(r'(?<![\w.,])([+-]?)(\d+)(?:[.,](\d+))?\s*%'),
          (match) => '${_itSign(match[1]!)}${formatPercentage(match[2]!, match[3])}'));

  @override
  String clock(int hour, String minutes) {
    final minute = int.parse(minutes);
    if (hour == 0) return minute == 0 ? 'mezzanotte'
        : 'mezzanotte e ${_itNumber(minute)}';
    final spokenHour = hour == 1 ? 'una' : _itNumber(hour);
    return minute == 0 ? '$spokenHour in punto'
        : '$spokenHour e ${_itNumber(minute)}';
  }

  @override
  String speakTimes(String input) => input.replaceAllMapped(
      RegExp(r'(?<![\w/\\.:-])([01]?\d|2[0-3]):([0-5]\d)(?![\w/\\:]|\.\d)'),
      (match) => clock(int.parse(match[1]!), match[2]!));

  static const _itMonths = ['gennaio', 'febbraio', 'marzo', 'aprile', 'maggio',
    'giugno', 'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre'];

  @override
  String formatDate(int day, int month, int year) =>
      '${day == 1 ? 'primo' : _itNumber(day)} ${_itMonths[month - 1]} ${_itNumber(year)}';

  @override
  String speakDates(String input) => input.replaceAllMapped(
      RegExp(r'(?<![\w/\\.-])(\d{1,2})/(\d{1,2})/(\d{4})(?![\w/\\]|\.\d)'),
      (match) {
        final day = int.parse(match[1]!);
        final month = int.parse(match[2]!);
        final year = int.parse(match[3]!);
        final date = DateTime.utc(year, month, day);
        if (date.year != year || date.month != month || date.day != day) {
          return match[0]!;
        }
        return formatDate(day, month, year);
      });

  @override
  String formatFraction(String numerator, String denominator) {
    final n = int.parse(numerator);
    final d = int.parse(denominator);
    if (d == 0) return '$numerator/$denominator';
    const singular = {2: 'mezzo', 3: 'terzo', 4: 'quarto', 5: 'quinto',
      6: 'sesto', 7: 'settimo', 8: 'ottavo', 9: 'nono', 10: 'decimo'};
    const plural = {2: 'mezzi', 3: 'terzi', 4: 'quarti', 5: 'quinti',
      6: 'sesti', 7: 'settimi', 8: 'ottavi', 9: 'noni', 10: 'decimi'};
    if (singular.containsKey(d)) {
      return '${n == 1 ? 'un' : _itNumber(n)} ${n == 1 ? singular[d] : plural[d]}';
    }
    return '${_itNumber(n)} su ${_itNumber(d)}';
  }

  @override
  String speakFractions(String input) {
    // Protect paths and full dates before considering isolated fractions.
    return input.replaceAllMapped(
        RegExp(r'(?<![\w/\\.-])(\d{1,3})/(\d{1,3})(?![\w/\\]|\.\d)'),
        (match) => formatFraction(match[1]!, match[2]!));
  }

  @override
  String normalizeNarration(String text) => _itMapProse(text, (prose) =>
      prose.replaceAllMapped(RegExp(r'(?<![\w.,:/\\-])([+-]?)(\d+)(?![\w:/\\]|[.,]\d)'),
          (match) {
            final value = int.tryParse(match[2]!);
            if (value == null || value > 999999999) return match[0]!;
            return '${_itSign(match[1]!)}${_itNumber(value)}';
          }));
}

String _itSign(String sign) => switch (sign) {
  '-' => 'meno ',
  '+' => 'più ',
  _ => '',
};
