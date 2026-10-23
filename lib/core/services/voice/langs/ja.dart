part of '../voice_language.dart';

class _JaVoiceLanguage extends VoiceLanguage {
  const _JaVoiceLanguage()
      : super(
          code: 'ja',
          whisperLanguage: 'ja',
          systemSttLocales: const ['ja_JP', 'ja-JP', 'ja'],
          deviceTtsLocales: const ['ja-JP'],
          deviceTtsFallback: 'ja-JP',
          neuralVoiceId: null,
          systemTtsOnly: true,
          streamingVoiceId: 'af_heart',
          transcript: _jaTranscriptGrammar,
          messages: _jaVoiceMessages,
          commands: _jaVoiceCommands,
          speech: const _JaSpeechGrammar(),
        );

  @override
  String normalizeCommand(String input) => input
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  @override
  LocalVoiceCommand? semanticCommand(String text) {
    final normalized = normalizeCommand(text);
    // Match entire requests; quoted controls, negations and explanations stay content.
    const request = r'(?:て|てください|てもらえますか|てもらえると助かります|てほしい|てくれますか)';
    if (RegExp('^(?:今は|今すぐ|もう)?(?:話すの|読み上げ|音声|音|朗読)を'
            '(?:止め|やめ|停止し|キャンセルし)$request\$')
        .hasMatch(normalized)) {
      return LocalVoiceCommand.silenceCurrent;
    }
    if (RegExp('^(?:ちょっと|少し)?待っ$request\$').hasMatch(normalized)) {
      return LocalVoiceCommand.pause;
    }
    if (RegExp('^(?:この)?会話を(?:終了し|終え|やめ|キャンセルし)$request\$')
        .hasMatch(normalized)) {
      return LocalVoiceCommand.end;
    }
    if (RegExp('^(?:この)?会話を一時停止し$request\$').hasMatch(normalized)) {
      return LocalVoiceCommand.pause;
    }
    // Confirmation and repetition have no control value in the shared enum.
    return null;
  }
}

const _jaVoiceCommands = VoiceCommandGrammar(
  wordSeparated: false,
  silence: [
    '話すのをやめてください', '話すのをやめて', '読み上げを止めてください',
    '読み上げを止めて', '読み上げをキャンセルしてください', '音声を止めて',
    'もう話さないで', 'もう聞きたくない', '黙ってください', '黙って',
    '静かにしてください', '静かにして', 'もう十分',
  ],
  pause: ['会話を一時停止してください', '会話を一時停止して', '一時停止して', '少し待って', 'ちょっと待って'],
  end: [
    '会話を終了してください', '会話を終了して', '会話を終わりにして',
    '会話をキャンセルしてください', 'ここで会話を終わりにしましょう',
    '会話を続けたくない',
  ],
  leading: ['ヘルメス', 'hermes', 'お願いします', 'わかった', 'はい'],
  trailing: ['お願いします', 'ありがとうございます', 'ありがとう'],
  connectors: ['それから', 'そして'],
);

const _jaVoiceMessages = <String, String>{
  'microphoneReleasing': 'マイクを解放しています。しばらくお待ちください。',
  'microphoneUnclear': '音声を認識できませんでした。',
  'didNotHear': '声が聞こえませんでした。',
  'microphoneUnavailable': 'マイクを起動できませんでした。',
  'sendFailed': 'メッセージを送信できませんでした。',
  'responseInterrupted': '応答が中断されました。',
  'serverUnavailable': 'Hermesサーバーの音声を利用できないため、音声を一時停止しました。',
  'approvalRequired': 'Hermesが承認を求めています。アプリを開いて確認してください。',
  'responseRequired': 'Hermesが返答を求めています。アプリを開いて続けてください。',
  'stopNotSaved': '停止を安全に保存できませんでした。もう一度お試しください。',
  'recognitionUnavailable': '音声認識の準備ができていません（{status}）。',
};

const _jaTranscriptGrammar = VoiceTranscriptGrammar(
  nonSpeechLabels: r'音楽|雑音|無音|笑い声|拍手',
  // Substring markers would also erase real requests discussing an outro.
  strongMarkers: [],
  subscribeOutro: r'^(?:チャンネル登録をお願いします|ご視聴ありがとうございました)$',
  fullReadingWords: r'^(?:子供に|私に)?(?:物語|お話|童話|詩|詩歌|冗談|歌)を(?:読んで|聞かせて|朗読して|歌って)(?:ください)?[。！!？?\s]*$',
);

const _jaDigits = ['れい', 'いち', 'に', 'さん', 'よん', 'ご', 'ろく', 'なな', 'はち', 'きゅう'];

// Japanese large-number groups through 9,999,999,999,999,999 (千兆).
String _jaNumber(int value) {
  if (value == 0) return _jaDigits[0];
  if (value < 0) return 'マイナス${_jaNumber(-value)}';
  if (value > 9999999999999999) return value.toString();
  var rest = value;
  final parts = <String>[];
  for (final group in const [(1000000000000, 'ちょう'), (100000000, 'おく'), (10000, 'まん')]) {
    final count = rest ~/ group.$1;
    if (count > 0) parts.add('${_jaNumber(count)}${group.$2}');
    rest %= group.$1;
  }
  final thousands = rest ~/ 1000;
  if (thousands > 0) {
    parts.add(switch (thousands) {
      1 => 'せん', 3 => 'さんぜん', 8 => 'はっせん',
      _ => '${_jaDigits[thousands]}せん',
    });
  }
  rest %= 1000;
  final hundreds = rest ~/ 100;
  if (hundreds > 0) {
    parts.add(switch (hundreds) {
      1 => 'ひゃく', 3 => 'さんびゃく', 6 => 'ろっぴゃく', 8 => 'はっぴゃく',
      _ => '${_jaDigits[hundreds]}ひゃく',
    });
  }
  rest %= 100;
  if (rest >= 10) {
    parts.add(rest < 20 ? 'じゅう' : '${_jaDigits[rest ~/ 10]}じゅう');
  }
  if (rest % 10 > 0) parts.add(_jaDigits[rest % 10]);
  return parts.join();
}

String _jaSigned(String raw, String spoken) => raw.startsWith('-')
    ? 'マイナス$spoken'
    : raw.startsWith('+') ? 'プラス$spoken' : spoken;

// ASCII technical neighbors exclude paths, identifiers, versions and fragments.
// Native text can touch a number directly, without ASCII word boundaries.
String _jaReplaceNumber(String input, String pattern, String Function(Match) replace) =>
    input.replaceAllMapped(
      RegExp(r'(?<![A-Za-z0-9_./:\\+\-])' + pattern + r'(?![A-Za-z0-9_/:\-]|\.\d)'),
      replace,
    );

class _JaSpeechGrammar extends VoiceSpeechGrammar {
  const _JaSpeechGrammar();

  @override
  String get linkWord => 'リンク';
  @override
  String get codeNotice => 'コードブロックを省略しました。';
  @override
  String get emailAt => ' アットマーク ';
  @override
  String get emailDot => ' ドット ';
  @override
  String get orWord => 'または';
  @override
  String get conjunctionPattern => r'および\s*/\s*または|かつ\s*/\s*または';
  @override
  String get decimalSeparator => 'てん';
  @override
  String get percentUnit => 'パーセント';
  @override
  String get currencyJoiner => '';
  @override
  String get referenceHeadingPattern => '出典|参考文献|参照元';
  @override
  bool get dateMonthFirst => false;
  @override
  bool get decimalUsesDot => true;

  @override
  (String, String, String, String)? currencyNames(String currency) => switch (currency) {
    r'$' => ('ドル', 'ドル', 'セント', 'セント'),
    '€' => ('ユーロ', 'ユーロ', 'セント', 'セント'),
    '£' => ('ポンド', 'ポンド', 'ペンス', 'ペンス'),
    '¥' || '￥' || '円' || 'JPY' => ('えん', 'えん', 'せん', 'せん'),
    _ => null,
  };

  @override
  String? formatCurrency(String currency, int major, int? minor) {
    final names = currencyNames(currency);
    if (names == null) return null;
    final base = '${_jaNumber(major)}${names.$1}';
    return minor == null || minor == 0 ? base : '$base${_jaNumber(minor)}${names.$3}';
  }

  @override
  String speakCurrencies(String input) {
    const units = r'(?:USD|EUR|GBP|JPY|[$€£¥￥円])';
    const amount = r'\d{1,16}(?:[.,]\d{1,2})?';
    const signedAmount = r'[+-]?\d{1,16}(?:[.,]\d{1,2})?';
    String expand(Match match, bool prefix) {
      final sign = match[1]!;
      final raw = match[prefix ? 3 : 2]!;
      final unit = match[prefix ? 2 : 3]!;
      final spoken = speakCurrencyAmount(raw, unit);
      return spoken == null ? match[0]! : _jaSigned(sign, spoken);
    }
    var text = _jaReplaceNumber(input, '([+-]?)($units)\\s*($signedAmount)', (m) => expand(m, true));
    text = _jaReplaceNumber(text, '([+-]?)($amount)\\s*($units)', (m) => expand(m, false));
    return text;
  }

  @override
  String? speakCurrencyAmount(String raw, String currency) {
    final unsigned = raw.replaceFirst(RegExp(r'^[+-]'), '');
    final spoken = super.speakCurrencyAmount(unsigned, currency.toUpperCase());
    return spoken == null ? null : _jaSigned(raw, spoken);
  }

  @override
  String formatDecimal(String major, String minor) =>
      _jaSigned(major, '${_jaNumber(int.parse(major).abs())}てん${minor.split('').map((d) => _jaDigits[int.parse(d)]).join()}');

  @override
  String formatPercentage(String major, String? minor) =>
      '${minor == null ? _jaSigned(major, _jaNumber(int.parse(major).abs())) : formatDecimal(major, minor)}パーセント';

  @override
  String speakPercentages(String input) => _jaReplaceNumber(
      input, r'([+-]?\d{1,16})(?:[.,](\d+))?\s*[%％]',
      (m) => formatPercentage(m[1]!, m[2]));

  @override
  String speakDecimals(String input) => _jaReplaceNumber(
      input, r'([+-]?\d{1,16})[.,](\d+)',
      (m) => formatDecimal(m[1]!, m[2]!));

  @override
  String clock(int hour, String minutes) {
    final hourText = switch (hour) {
      0 => 'れいじ', 4 => 'よじ', 7 => 'しちじ', 9 => 'くじ',
      14 => 'じゅうよじ', 17 => 'じゅうしちじ', 19 => 'じゅうくじ',
      _ => '${_jaNumber(hour)}じ',
    };
    final minute = int.parse(minutes);
    if (minute == 0) return hourText;
    final ones = minute % 10;
    final minuteText = ones == 0
        ? '${_jaNumber(minute).replaceFirst(RegExp(r'う$'), '')}っぷん'
        : '${minute >= 10 ? _jaNumber(minute ~/ 10 * 10) : ''}${switch (ones) {
            1 => 'いっぷん', 3 => 'さんぷん', 4 => 'よんぷん', 6 => 'ろっぷん',
            8 => 'はっぷん', _ => '${_jaDigits[ones]}ふん',
          }}';
    return '$hourText$minuteText';
  }

  @override
  String speakTimes(String input) => _jaReplaceNumber(
      input, r'([01]?\d|2[0-3]):([0-5]\d)',
      (m) => clock(int.parse(m[1]!), m[2]!));

  @override
  String formatDate(int day, int month, int year) {
    final monthText = switch (month) {
      4 => 'しがつ', 7 => 'しちがつ', 9 => 'くがつ',
      _ => '${_jaNumber(month)}がつ',
    };
    final dayText = switch (day) {
      1 => 'ついたち', 2 => 'ふつか', 3 => 'みっか', 4 => 'よっか',
      5 => 'いつか', 6 => 'むいか', 7 => 'なのか', 8 => 'ようか',
      9 => 'ここのか', 10 => 'とおか', 14 => 'じゅうよっか',
      20 => 'はつか', 24 => 'にじゅうよっか',
      17 => 'じゅうしちにち', 19 => 'じゅうくにち',
      27 => 'にじゅうしちにち', 29 => 'にじゅうくにち',
      _ => '${_jaNumber(day)}にち',
    };
    return '${_jaNumber(year)}ねん$monthText$dayText';
  }

  @override
  String speakDates(String input) {
    String expand(Match m, bool yearFirst) {
      final year = int.parse(m[yearFirst ? 1 : 3]!);
      final month = int.parse(m[2]!);
      final day = int.parse(m[yearFirst ? 3 : 1]!);
      if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) return m[0]!;
      final date = DateTime.utc(year, month, day);
      if (date.month != month || date.day != day) return m[0]!;
      return formatDate(day, month, year);
    }
    var text = _jaReplaceNumber(input, r'(\d{4})[/-](\d{1,2})[/-](\d{1,2})', (m) => expand(m, true));
    text = _jaReplaceNumber(text, r'(\d{1,2})/(\d{1,2})/(\d{4})', (m) => expand(m, false));
    text = _jaReplaceNumber(text, r'(\d{4})年(\d{1,2})月(\d{1,2})日', (m) => expand(m, true));
    return text;
  }

  @override
  String formatFraction(String numerator, String denominator) =>
      _jaSigned(numerator, '${_jaNumber(int.parse(denominator))}ぶんの${_jaNumber(int.parse(numerator).abs())}');

  @override
  String speakFractions(String input) => _jaReplaceNumber(
      input, r'([+-]?\d{1,3})/(\d{1,3})',
      (m) => int.parse(m[2]!) == 0 ? m[0]! : formatFraction(m[1]!, m[2]!));

  @override
  String normalizeNarration(String text) => _jaReplaceNumber(
      text, r'[+-]?\d{1,16}',
      (m) => _jaSigned(m[0]!, _jaNumber(int.parse(m[0]!).abs())));

  @override
  String joinTableCells(List<String> cells) => cells.join('、');

  @override
  String joinParagraph(List<String> lines) => lines.join();

  @override
  String withTerminalPunctuation(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty || RegExp(r'[。！？.!?…]$').hasMatch(trimmed)
        ? trimmed : '$trimmed。';
  }
}
