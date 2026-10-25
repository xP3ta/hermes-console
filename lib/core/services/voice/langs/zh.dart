part of '../voice_language.dart';

class _ZhVoiceLanguage extends VoiceLanguage {
  const _ZhVoiceLanguage() : super(
    code: "zh",
    whisperLanguage: "zh",
    systemSttLocales: const ["zh_CN", "zh_TW", "zh_HK", "zh-CN", "zh"],
    deviceTtsLocales: const ["zh-CN", "zh-TW", "zh-HK"],
    deviceTtsFallback: "zh-CN",
    neuralVoiceId: "zh_CN-huayan-medium",
    streamingVoiceId: "af_heart",
    transcript: _zhTranscriptGrammar,
    messages: _zhVoiceMessages,
    commands: _zhVoiceCommands,
    speech: const _ZhSpeechGrammar(),
  );

  @override
  String normalizeCommand(String input) {
    var text = input.toLowerCase();
    // Normalize only control vocabulary; retain all other native characters.
    const variants = <String, String>{
      '請': '请', '說': '说', '話': '话', '閉': '闭',
      '暫': '暂', '對': '对', '結': '结', '這': '这',
      '繼': '继', '續': '续', '讀': '读', '聽': '听', '語': '语',
      '聲': '声', '謝': '谢', '夠': '够', '會': '会', '現': '现',
      '讓': '让', '個': '个', '點': '点', '麼': '么', '為': '为',
      '嗎': '吗', '們': '们', '經': '经', '還': '还',
      '靜': '静', '關': '关', '終': '终', '勞': '劳',
      '願': '愿', '當': '当',
    };
    for (final entry in variants.entries) {
      text = text.replaceAll(entry.key, entry.value);
    }
    return text.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  }

  @override
  LocalVoiceCommand? semanticCommand(String text) {
    final normalized = normalizeCommand(text);
    // Match complete requests, never isolated control words inside content.
    if (RegExp(
      r'^(?:(?:我觉得|我想|我希望|麻烦你|劳驾|能不能|你能|你现在可以|你可以|可以|能否|可不可以|请你|请|现在|已经|就|先))*'
      r'(?:停止|取消|结束|关闭|关掉|切断)(?:当前的?|这段|正在播放的)?'
      r'(?:说话|讲话|朗读|读下去|播放语音|播放音频|语音播放|声音|音频|语音)'
      r'(?:吧|好吗|吗|了)?$',
    ).hasMatch(normalized) || RegExp(
      r'^(?:我)?(?:不想|不愿意|不需要)(?:再|继续)?'
      r'(?:听你说话|听你讲话|听下去|听你朗读)(?:了)?$',
    ).hasMatch(normalized)) {
      return LocalVoiceCommand.silenceCurrent;
    }
    if (RegExp(
      r'^(?:(?:我想|我希望|请你|请|先|现在|把))*'
      r'(?:(?:这次|当前的?)?对话暂停(?:一下)?|暂停(?:这次|当前的?)?对话|稍等(?:一下)?|等一下)'
      r'(?:吧|好吗|了)?$',
    ).hasMatch(normalized)) {
      return LocalVoiceCommand.pause;
    }
    if (RegExp(
      r'^(?:(?:我想|我希望|请你|请|现在|就))*'
      r'(?:结束|取消|关闭|终止)(?:这次|当前的?)?(?:对话|会话|语音对话)'
      r'(?:吧|好吗|了)?$',
    ).hasMatch(normalized) || RegExp(
      r'^(?:不要|我不想)(?:再|继续)(?:这次)?对话了?$',
    ).hasMatch(normalized)) {
      return LocalVoiceCommand.end;
    }
    // Confirmation and repeat requests have no corresponding shared enum.
    return null;
  }
}

const _zhVoiceCommands = VoiceCommandGrammar(
  wordSeparated: false,
  silence: [
    '我不想让你继续说话', '我不想听你说话了', '我不想再听你说话了',
    '我想让你停止说话', '不要继续说话', '别再说话了', '别再说了',
    '停止说话', '停止讲话', '停止朗读', '取消朗读', '停止播放语音', '闭嘴',
    '别说了', '别读了', '不要说话了', '静音', '我不想再听了',
    '保持安静', '安静', '够了', '到此为止',
  ],
  pause: ['暂停对话', '暂停一下', '休息一下', '稍等一下', '暂停'],
  end: [
    '今天的对话就到这里', '结束这次对话', '结束对话', '取消对话',
    '关闭对话', '终止对话', '我们结束对话吧',
  ],
  leading: ['好的hermes', '你好hermes', 'hermes', '麻烦你', '请你', '请', '好了', '好的'],
  trailing: ['谢谢你', '谢谢', '好吗'],
  connectors: ['然后', '并且', '还有', '和', '请'],
);

const _zhVoiceMessages = <String, String>{
  'microphoneReleasing': '麦克风仍在释放中。',
  'microphoneUnclear': '未能听清你的声音。',
  'didNotHear': '没有听到你的声音。',
  'microphoneUnavailable': '无法启动麦克风。',
  'sendFailed': '消息发送失败。',
  'responseInterrupted': '回答已中断。',
  'serverUnavailable': 'Hermes服务器语音暂不可用。语音已暂停。',
  'approvalRequired': 'Hermes需要你的批准。请打开应用查看。',
  'responseRequired': 'Hermes需要你的回复。请打开应用继续。',
  'stopNotSaved': '无法安全保存停止请求。请重试。',
  'recognitionUnavailable': '语音识别尚未就绪（{status}）。',
};

const _zhTranscriptGrammar = VoiceTranscriptGrammar(
  fullReadingWords: r'^(?:(?:请|请你)?(?:给我|为我)?(?:讲(?:一个|个)?|读(?:一首)?|朗读)(?:故事|童话|诗歌|诗|笑话)|请(?:完整|全文|逐字)朗读(?:这段文字|这篇文章|这首诗))(?:吧|。|！)?$',
  nonSpeechLabels: r'音乐|音樂|噪音|静音|靜音|笑声|笑聲|掌声|掌聲|听不清|聽不清',
  // Use a whole-utterance pattern because strongMarkers are substring matches.
  subscribeOutro: r'^(?:感谢观看|感謝觀看|谢谢观看|謝謝觀看|(?:请|請)?(?:订阅|訂閱)(?:本|这个|這個)频道|(?:请|請)?(?:订阅|訂閱)本頻道)$',
);

class _ZhSpeechGrammar extends VoiceSpeechGrammar {
  const _ZhSpeechGrammar();

  // ASCII technical tokens, paths, versions, dates and clocks are not numbers
  // in isolation. CJK characters deliberately do not count as boundaries.
  static const _zhLeft = r'(?<![A-Za-z0-9_./:\\+\-−])';
  static const _zhRight = r'(?![A-Za-z0-9_/:\\+\-−]|\.[0-9])';
  static const _zhDigits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];

  @override
  String get linkWord => '链接';
  @override
  String get codeNotice => '已省略代码块。';
  @override
  String get emailAt => ' 艾特 ';
  @override
  String get emailDot => ' 点 ';
  @override
  String get orWord => '或';
  @override
  String get conjunctionPattern => r'(?:和|及|与)\s*/\s*或';
  @override
  String get decimalSeparator => '点';
  @override
  String get percentUnit => '百分之';
  @override
  String get currencyJoiner => '';
  @override
  String get referenceHeadingPattern => '来源|资料来源|参考资料|参考文献|來源|參考資料|參考文獻';
  @override
  bool get dateMonthFirst => false;
  @override
  bool get decimalUsesDot => true;

  @override
  String speakConjunctions(String input) => input.replaceAllMapped(
      RegExp(conjunctionPattern), (_) => '和或');

  @override
  (String, String, String, String)? currencyNames(String currency) => switch (currency.toUpperCase()) {
    r'$' || 'USD' => ('美元', '美元', '美分', '美分'),
    '€' || 'EUR' => ('欧元', '欧元', '欧分', '欧分'),
    '£' || 'GBP' => ('英镑', '英镑', '便士', '便士'),
    '¥' || '￥' || 'CNY' || 'RMB' || '元' || '人民币' => ('元', '元', '分', '分'),
    _ => null,
  };

  // Cardinal readings up to 999,999,999,999; larger values remain unchanged.
  static String _zhInteger(int value, {bool measure = false}) {
    if (value < 0) return '负${_zhInteger(-value, measure: measure)}';
    if (value > 999999999999) return value.toString();
    if (value == 0) return '零';
    if (value == 2 && measure) return '两';
    if (value >= 10000) {
      final unit = value >= 100000000 ? 100000000 : 10000;
      final high = value ~/ unit;
      final low = value % unit;
      final prefix = '${_zhInteger(high, measure: true)}${unit == 10000 ? '万' : '亿'}';
      if (low == 0) return prefix;
      final suffix = '${low >= 10 && low < 20 ? '一' : ''}${_zhInteger(low)}';
      return '$prefix${low < unit ~/ 10 ? '零' : ''}$suffix';
    }
    var result = '';
    var remainder = value;
    var pendingZero = false;
    for (final (unit, label) in const [(1000, '千'), (100, '百'), (10, '十'), (1, '')]) {
      final digit = remainder ~/ unit;
      remainder %= unit;
      if (digit == 0) {
        if (result.isNotEmpty && remainder > 0) pendingZero = true;
        continue;
      }
      if (pendingZero) {
        result += '零';
        pendingZero = false;
      }
      if (!(unit == 10 && digit == 1 && result.isEmpty)) {
        result += digit == 2 && unit >= 100 ? '两' : _zhDigits[digit];
      }
      result += label;
    }
    return result;
  }

  static String _zhReadDigits(String value) =>
      value.split('').map((digit) => _zhDigits[int.parse(digit)]).join();

  static String _zhSign(String sign) => switch (sign) {
    '-' || '−' => '负',
    '+' => '正',
    _ => '',
  };

  @override
  String clock(int hour, String minutes) {
    final minute = int.parse(minutes);
    final prefix = '${_zhInteger(hour, measure: true)}点';
    return minute == 0 ? '$prefix整' : '$prefix${minute < 10 ? '零' : ''}${_zhInteger(minute)}分';
  }

  @override
  String speakTimes(String input) => input.replaceAllMapped(
      RegExp('$_zhLeft([01]?[0-9]|2[0-3]):([0-5][0-9])$_zhRight'),
      (match) => clock(int.parse(match[1]!), match[2]!));

  @override
  String formatDate(int day, int month, int year) =>
      '${_zhReadDigits(year.toString().padLeft(4, '0'))}年${_zhInteger(month)}月${_zhInteger(day)}日';

  static bool _zhValidDate(int day, int month, int year) {
    if (month < 1 || month > 12 || year < 1 || year > 9999 || day < 1) return false;
    final leap = year % 400 == 0 || (year % 4 == 0 && year % 100 != 0);
    final days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return day <= days[month - 1];
  }

  @override
  String speakDates(String input) {
    var text = input.replaceAllMapped(
      RegExp('$_zhLeft([0-9]{4})([-/])([0-9]{1,2})\\2([0-9]{1,2})$_zhRight'),
      (match) {
        final year = int.parse(match[1]!);
        final month = int.parse(match[3]!);
        final day = int.parse(match[4]!);
        return _zhValidDate(day, month, year) ? formatDate(day, month, year) : match[0]!;
      },
    );
    text = text.replaceAllMapped(
      RegExp('$_zhLeft([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})$_zhRight'),
      (match) {
        final day = int.parse(match[1]!);
        final month = int.parse(match[2]!);
        final year = int.parse(match[3]!);
        return _zhValidDate(day, month, year) ? formatDate(day, month, year) : match[0]!;
      },
    );
    return text.replaceAllMapped(
      RegExp('$_zhLeft([0-9]{4})年([0-9]{1,2})月([0-9]{1,2})日'),
      (match) {
        final year = int.parse(match[1]!);
        final month = int.parse(match[2]!);
        final day = int.parse(match[3]!);
        return _zhValidDate(day, month, year) ? formatDate(day, month, year) : match[0]!;
      },
    );
  }

  @override
  String formatFraction(String numerator, String denominator) =>
      '${_zhInteger(int.parse(denominator))}分之${_zhInteger(int.parse(numerator))}';

  @override
  String speakFractions(String input) => input.replaceAllMapped(
      RegExp('$_zhLeft([+−-]?)([0-9]{1,3})/([0-9]{1,3})$_zhRight'),
      (match) => int.parse(match[3]!) == 0
          ? match[0]!
          : '${_zhSign(match[1]!)}${formatFraction(match[2]!, match[3]!)}');

  @override
  String formatDecimal(String major, String minor) =>
      '${_zhInteger(int.parse(major))}点${_zhReadDigits(minor)}';

  @override
  String speakDecimals(String input) => input.replaceAllMapped(
      RegExp('$_zhLeft([+−-]?)([0-9]{1,12})\\.([0-9]+)$_zhRight'),
      (match) => '${_zhSign(match[1]!)}${formatDecimal(match[2]!, match[3]!)}');

  @override
  String formatPercentage(String major, String? minor) =>
      '百分之${minor == null ? _zhInteger(int.parse(major)) : formatDecimal(major, minor)}';

  @override
  String speakPercentages(String input) => input.replaceAllMapped(
      RegExp('$_zhLeft([+−-]?)([0-9]{1,12})(?:[.,]([0-9]+))?\\s*[%％]$_zhRight'),
      (match) => '${_zhSign(match[1]!)}${formatPercentage(match[2]!, match[3])}');

  @override
  String? formatCurrency(String currency, int major, int? minor) {
    final names = currencyNames(currency);
    if (names == null) return null;
    final (unit, _, subunit, _) = names;
    final prefix = '${_zhInteger(major, measure: true)}$unit';
    if (minor == null || minor == 0) return prefix;
    if (unit == '元') {
      final jiao = minor ~/ 10;
      final fen = minor % 10;
      return '$prefix${jiao == 0 ? '零' : '${_zhInteger(jiao)}角'}${fen == 0 ? '' : '${_zhInteger(fen)}分'}';
    }
    return '$prefix${minor < 10 ? '零' : ''}${_zhInteger(minor)}$subunit';
  }

  @override
  String speakCurrencies(String input) {
    const currency = r'(?:USD|EUR|GBP|CNY|RMB|人民币|[$€£¥￥]|元)';
    const amount = r'([+−-]?)([0-9]{1,12}(?:[.,][0-9]{1,2})?)';
    var text = input.replaceAllMapped(
      RegExp('$_zhLeft([+−-]?)($currency)\\s*$amount$_zhRight', caseSensitive: false),
      (match) {
        if (match[1]!.isNotEmpty && match[3]!.isNotEmpty) return match[0]!;
        return '${_zhSign('${match[1]}${match[3]}')}${speakCurrencyAmount(match[4]!, match[2]!) ?? match[0]!}';
      },
    );
    text = text.replaceAllMapped(
      RegExp('$_zhLeft$amount\\s*($currency)$_zhRight', caseSensitive: false),
      (match) => '${_zhSign(match[1]!)}${speakCurrencyAmount(match[2]!, match[3]!) ?? match[0]!}',
    );
    return text;
  }

  @override
  String normalizeNarration(String text) {
    final dated = text.replaceAllMapped(
        RegExp('$_zhLeft([0-9]{4})(?=年)'),
        (match) => _zhReadDigits(match[1]!));
    return dated.replaceAllMapped(
        RegExp('$_zhLeft([+−-]?)([0-9]{1,12})$_zhRight'),
        (match) {
          final measure = RegExp(r'^(?:个|本|张|台|件|条|位|名|天|小时|分钟|公斤|米)')
              .hasMatch(dated.substring(match.end));
          return '${_zhSign(match[1]!)}${_zhInteger(int.parse(match[2]!), measure: measure)}';
        });
  }

  @override
  String withTerminalPunctuation(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || RegExp(r'[。！？.!?…]$').hasMatch(trimmed)) return trimmed;
    return '$trimmed。';
  }

  @override
  String joinTableCells(List<String> cells) => cells.join('，');

  @override
  String joinParagraph(List<String> lines) => lines.join();
}
