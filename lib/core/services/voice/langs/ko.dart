part of '../voice_language.dart';

class _KoVoiceLanguage extends VoiceLanguage {
  const _KoVoiceLanguage()
      : super(
          code: 'ko',
          whisperLanguage: 'ko',
          systemSttLocales: const ['ko_KR', 'ko-KR', 'ko'],
          deviceTtsLocales: const ['ko-KR'],
          deviceTtsFallback: 'ko-KR',
          neuralVoiceId: null,
          streamingVoiceId: 'af_heart',
          transcript: _koTranscriptGrammar,
          messages: _koVoiceMessages,
          commands: _koVoiceCommands,
          speech: const _KoSpeechGrammar(),
        );

  @override
  String normalizeCommand(String input) => input
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  @override
  LocalVoiceCommand? semanticCommand(String text) {
    final value = normalizeCommand(text);
    // Match whole requests. Quoted controls, negation and questions about
    // controls therefore remain content. Confirmation/repetition have no enum.
    if (RegExp(
      r'^(?:이제|지금)?(?:이)?(?:대화|세션)(?:를|을)?'
      r'(?:끝내|종료해|취소해|마쳐)(?:도돼|도됩니다|줄수있어|줄래|주세요|줘요|줘)?$',
    ).hasMatch(value) ||
        RegExp(r'^(?:이)?대화를계속하고싶지않(?:아|아요)$').hasMatch(value)) {
      return LocalVoiceCommand.end;
    }
    if (RegExp(
      r'^(?:이제|지금)?(?:대화를)?(?:잠시|잠깐)'
      r'(?:멈춰|기다려|쉬어)(?:주세요|줘요|줘|줄래|줄수있어)?$',
    ).hasMatch(value)) {
      return LocalVoiceCommand.pause;
    }
    if (RegExp(
      r'^(?:이제|지금)?(?:말하기|읽기|낭독|음성|오디오)(?:를|을)?'
      r'(?:멈춰|중단해|취소해|꺼)(?:주세요|줘요|줘도돼|줘|줄래|줄수있어|도돼)?$',
    ).hasMatch(value) ||
        RegExp(
          r'^(?:이제|지금)?(?:말하는것을|읽는것을)그만해(?:주세요|줘요|줘)?$',
        ).hasMatch(value) ||
        RegExp(r'^(?:이제)?그만해도돼$').hasMatch(value) ||
        RegExp(r'^계속말하지않았으면좋겠(?:어|어요)$').hasMatch(value)) {
      return LocalVoiceCommand.silenceCurrent;
    }
    return null;
  }
}

const _koVoiceCommands = VoiceCommandGrammar(
  wordSeparated: false,
  silence: [
    '더이상말하지마세요', '더이상말하지마', '더이상듣고싶지않아요',
    '더이상듣고싶지않아', '계속말하지마세요', '계속말하지마',
    '말하기를멈춰주세요', '말하기를멈춰줘', '말하기를멈춰',
    '읽기를멈춰주세요', '읽기를멈춰줘', '읽기를멈춰',
    '낭독을취소해주세요', '낭독을취소해', '조용히해주세요',
    '조용히해줘', '조용히해', '이제충분해요', '이제충분해',
  ],
  pause: [
    '대화를잠시멈춰주세요', '대화를잠시멈춰줘', '대화를잠시멈춰',
    '대화를일시정지해주세요', '대화를일시정지해',
    '잠시기다려주세요', '잠시기다려', '잠깐쉬자', '잠시쉬자', '일시정지',
  ],
  end: [
    '대화를끝내주세요', '대화를끝내줘', '대화를끝내',
    '대화를종료해주세요', '대화를종료해',
    '대화를취소해주세요', '대화를취소해', '여기서마치자', '여기서끝내자',
  ],
  leading: ['헤르메스', 'hermes', '알겠어요', '알겠어', '부탁해요', '부탁해'],
  trailing: ['부탁해요', '부탁해', '감사합니다', '고마워요', '고마워'],
  connectors: ['그리고', '또', '부탁해요', '부탁해'],
);

const _koVoiceMessages = <String, String>{
  'microphoneReleasing': '아직 마이크 사용을 해제하는 중이에요.',
  'microphoneUnclear': '마이크로 들어온 말을 이해하지 못했어요.',
  'didNotHear': '말씀을 듣지 못했어요.',
  'microphoneUnavailable': '마이크를 켤 수 없었어요.',
  'sendFailed': '메시지를 보내지 못했어요.',
  'responseInterrupted': '응답이 중단되었어요.',
  'serverUnavailable': '헤르메스 서버의 음성을 사용할 수 없어요. 음성을 일시 정지했어요.',
  'approvalRequired': '헤르메스에 승인이 필요해요. 앱을 열어 확인해 주세요.',
  'responseRequired': '헤르메스에 답변이 필요해요. 앱을 열어 계속해 주세요.',
  'stopNotSaved': '중지 요청을 안전하게 저장하지 못했어요. 다시 시도해 주세요.',
  'recognitionUnavailable': '음성 인식을 사용할 준비가 되지 않았어요 ({status}).',
};

// Shared strong markers use substring matching, so no Korean courtesy or
// outro is a strong marker. Only an entire stock subscription request matches.
const _koTranscriptGrammar = VoiceTranscriptGrammar(
  fullReadingWords: r'(?:^|\s)(?:(?:이|그|저|짧은|긴)\s*)?'
      r'(?:동화|이야기|소설|시|시조|노래가사)(?:를|을)\s*'
      r'(?:읽어\s*(?:줘|주세요)|낭독해\s*(?:줘|주세요)|들려\s*(?:줘|주세요))',
  fullReadingPhrases: ['처음부터 끝까지 읽어 줘', '처음부터끝까지읽어줘'],
  nonSpeechLabels: r'음악|잡음|소음|침묵|웃음|웃음소리|박수|들리지\s*않음',
  strongMarkers: [],
  subscribeOutro: r'^(?:채널을\s*구독해\s*주세요|구독과\s*좋아요\s*부탁드립니다)$',
);

// Keep numeric fragments of paths, identifiers, versions and invalid dates
// intact. These guards deliberately allow adjacent Korean particles.
const _koNumberStart = r'(?<![A-Za-z0-9_./:\\+\-])';
const _koNumberEnd = r'(?![A-Za-z0-9_/:\\]|[.]\d|[-]\d)';
const _koDigits = ['영', '일', '이', '삼', '사', '오', '육', '칠', '팔', '구'];

// Up to fifteen decimal digits (through hundreds of trillions). Larger
// values stay as written rather than silently losing precision.
String _koInteger(String raw) {
  final negative = raw.startsWith('-');
  final positive = raw.startsWith('+');
  final digits = raw.replaceFirst(RegExp(r'^[+-]'), '');
  if (digits.length > 15) return raw;
  final parsed = int.tryParse(digits);
  if (parsed == null) return raw;
  var value = parsed;
  final sign = negative ? '마이너스 ' : (positive ? '플러스 ' : '');
  if (value == 0) return '$sign영';
  const smallUnits = ['', '십', '백', '천'];
  const largeUnits = ['', '만', '억', '조'];
  final groups = <String>[];
  var groupIndex = 0;
  while (value > 0) {
    var group = value % 10000;
    var spoken = '';
    for (var place = 0; place < 4; place++) {
      final digit = group % 10;
      if (digit != 0) {
        final head = digit == 1 && place > 0 ? '' : _koDigits[digit];
        spoken = '$head${smallUnits[place]}$spoken';
      }
      group ~/= 10;
    }
    if (spoken.isNotEmpty) {
      if (groupIndex == 1 && spoken == '일') spoken = '';
      groups.insert(0, '$spoken${largeUnits[groupIndex]}');
    }
    value ~/= 10000;
    groupIndex++;
  }
  return '$sign${groups.join(' ')}';
}

class _KoSpeechGrammar extends VoiceSpeechGrammar {
  const _KoSpeechGrammar();

  @override
  String get linkWord => '링크';
  @override
  String get codeNotice => '코드 블록은 생략했어요.';
  @override
  String get emailAt => ' 골뱅이 ';
  @override
  String get emailDot => ' 점 ';
  @override
  String get orWord => ' 또는 ';
  @override
  String get conjunctionPattern => r'(?<=[가-힣])\s*/\s*(?=또는)';
  @override
  String speakConjunctions(String input) =>
      input.replaceAllMapped(RegExp(r'(그리고|및)\s*/\s*또는'),
          (match) => '${match[1]} 또는');
  @override
  String get decimalSeparator => '점';
  @override
  String get percentUnit => '퍼센트';
  @override
  String get currencyJoiner => ' ';
  @override
  String get referenceHeadingPattern => '출처|참고 자료|참고자료|참고 문헌|참고문헌';
  @override
  bool get dateMonthFirst => false;
  @override
  bool get decimalUsesDot => true;

  @override
  (String, String, String, String)? currencyNames(String currency) =>
      switch (currency.toUpperCase()) {
        r'$' || 'USD' => ('달러', '달러', '센트', '센트'),
        '€' || 'EUR' => ('유로', '유로', '센트', '센트'),
        '£' || 'GBP' => ('파운드', '파운드', '펜스', '펜스'),
        '₩' || 'KRW' || '원' => ('원', '원', '전', '전'),
        _ => null,
      };

  @override
  String? formatCurrency(String currency, int major, int? minor) {
    final names = currencyNames(currency);
    if (names == null) return null;
    final base = '${_koInteger('$major')} ${names.$1}';
    if (minor == null || minor == 0) return base;
    return '$base ${_koInteger('$minor')} ${names.$3}';
  }

  @override
  String speakCurrencies(String input) {
    const amount = r'(\d{1,15}(?:[.,]\d{1,2})?)';
    const currency = r'(USD|EUR|GBP|KRW|[€$£₩]|원)';
    String convert(Match match, bool prefix) {
      final sign = match[1]!;
      final raw = match[prefix ? 3 : 2]!;
      final unit = match[prefix ? 2 : 3]!;
      final spoken = speakCurrencyAmount(raw, unit);
      if (spoken == null) return match[0]!;
      return '${sign == '-' ? '마이너스 ' : (sign == '+' ? '플러스 ' : '')}$spoken';
    }
    var result = input.replaceAllMapped(
      RegExp('$_koNumberStart([+-]?)$currency\\s*$amount$_koNumberEnd',
          caseSensitive: false),
      (match) => convert(match, true),
    );
    result = result.replaceAllMapped(
      RegExp('$_koNumberStart([+-]?)$amount\\s*$currency$_koNumberEnd',
          caseSensitive: false),
      (match) => convert(match, false),
    );
    return result;
  }

  @override
  String formatDecimal(String major, String minor) =>
      '${_koInteger(major)} 점 ${minor.split('').map((digit) => _koDigits[int.parse(digit)]).join(' ')}';

  @override
  String formatPercentage(String major, String? minor) =>
      '${minor == null ? _koInteger(major) : formatDecimal(major, minor)} 퍼센트';

  @override
  String speakPercentages(String input) => input.replaceAllMapped(
        RegExp('$_koNumberStart([+-]?\\d{1,15})(?:[.,](\\d+))?\\s*%$_koNumberEnd'),
        (match) => formatPercentage(match[1]!, match[2]),
      );

  @override
  String speakDecimals(String input) => input.replaceAllMapped(
        RegExp('$_koNumberStart([+-]?\\d{1,15})[.,](\\d+)$_koNumberEnd'),
        (match) => formatDecimal(match[1]!, match[2]!),
      );

  @override
  String clock(int hour, String minutes) {
    const hours = [
      '영', '한', '두', '세', '네', '다섯', '여섯', '일곱', '여덟', '아홉',
      '열', '열한', '열두', '열세', '열네', '열다섯', '열여섯', '열일곱',
      '열여덟', '열아홉', '스무', '스물한', '스물두', '스물세',
    ];
    final minute = int.parse(minutes);
    return minute == 0
        ? '${hours[hour]} 시 정각'
        : '${hours[hour]} 시 ${_koInteger('$minute')} 분';
  }

  @override
  String speakTimes(String input) {
    var result = input.replaceAllMapped(
      RegExp('$_koNumberStart([01]?\\d|2[0-3]):([0-5]\\d)$_koNumberEnd'),
      (match) => clock(int.parse(match[1]!), match[2]!),
    );
    result = result.replaceAllMapped(
      RegExp('$_koNumberStart([01]?\\d|2[0-3])시(?:\\s*([0-5]?\\d)분)?(?!\\s*\\d|[A-Za-z0-9_])'),
      (match) => clock(int.parse(match[1]!), match[2] ?? '00'),
    );
    return result;
  }

  @override
  String formatDate(int day, int month, int year) {
    final spokenMonth = switch (month) {
      6 => '유',
      10 => '시',
      _ => _koInteger('$month'),
    };
    return '${_koInteger('$year')} 년 $spokenMonth월 ${_koInteger('$day')} 일';
  }

  @override
  String speakDates(String input) {
    String convert(Match match, bool yearFirst) {
      final year = int.parse(match[yearFirst ? 1 : 3]!);
      final month = int.parse(match[2]!);
      final day = int.parse(match[yearFirst ? 3 : 1]!);
      final date = DateTime.utc(year, month, day);
      if (year < 1 || date.year != year || date.month != month || date.day != day) {
        return match[0]!;
      }
      return formatDate(day, month, year);
    }
    var result = input.replaceAllMapped(
      RegExp('$_koNumberStart(\\d{4})[-/](\\d{1,2})[-/](\\d{1,2})$_koNumberEnd'),
      (match) => convert(match, true),
    );
    result = result.replaceAllMapped(
      RegExp('$_koNumberStart(\\d{1,2})/(\\d{1,2})/(\\d{4})$_koNumberEnd'),
      (match) => convert(match, false),
    );
    return result.replaceAllMapped(
      RegExp('$_koNumberStart(\\d{4})년\\s*(\\d{1,2})월\\s*(\\d{1,2})일'),
      (match) => convert(match, true),
    );
  }

  @override
  String formatFraction(String numerator, String denominator) {
    final sign = numerator.startsWith('-')
        ? '마이너스 '
        : (numerator.startsWith('+') ? '플러스 ' : '');
    final absolute = numerator.replaceFirst(RegExp(r'^[+-]'), '');
    return '$sign${_koInteger(denominator)} 분의 ${_koInteger(absolute)}';
  }

  @override
  String speakFractions(String input) => input.replaceAllMapped(
        RegExp('$_koNumberStart([+-]?\\d{1,3})/(\\d{1,3})$_koNumberEnd'),
        (match) => int.parse(match[2]!) == 0
            ? match[0]!
            : formatFraction(match[1]!, match[2]!),
      );

  @override
  String normalizeNarration(String text) => text.replaceAllMapped(
        RegExp('$_koNumberStart([+-]?\\d{1,15})$_koNumberEnd'),
        (match) => _koInteger(match[1]!),
      );
}
