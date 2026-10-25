import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/voice_language.dart';
import 'package:hermes_android/core/services/voice/speech_renderer.dart';
import 'package:hermes_android/core/services/voice/conversation/local_voice_command_detector.dart';
import 'package:hermes_android/core/services/voice/voice_response_policy.dart';

void main() {
  final language = voiceLanguageFor('zh-CN');
  final speech = language.speech;
  const detector = LocalVoiceCommandDetector();
  LocalVoiceCommand? command(String text) =>
      detector.detect(text, language: 'zh-CN');
  String render(String text) => const SpeechRenderer(language: 'zh')
      .render(text).map((segment) => segment.text).join(' ');

  test('native record keeps approved metadata and all eleven messages', () {
    expect(language.isDraft, isFalse);
    expect(language.code, 'zh');
    expect(language.whisperLanguage, 'zh');
    expect(language.systemSttLocales, ['zh_CN', 'zh_TW', 'zh_HK', 'zh-CN', 'zh']);
    expect(language.deviceTtsLocales, ['zh-CN', 'zh-TW', 'zh-HK']);
    expect(language.deviceTtsFallback, 'zh-CN');
    expect(language.neuralVoiceId, 'zh_CN-huayan-medium');
    expect(language.streamingVoiceId, 'af_heart');
    expect(language.systemTtsOnly, isFalse);
    expect(language.commands.wordSeparated, isFalse);
    expect(language.messages.keys.toSet(), voiceLanguageFor('en').messages.keys.toSet());
    expect(language.messages, hasLength(11));
    for (final message in language.messages.values) {
      expect(message, matches(RegExp(r'[\u4e00-\u9fff]')));
    }
    expect(language.message('recognitionUnavailable', {'status': 'busy'}),
        '语音识别尚未就绪（busy）。');
  });

  test('normalization preserves native script and accepts spaced STT', () {
    expect(language.normalizeCommand('请 停止 说话！'), '请停止说话');
    expect(command('请 停止 说话！'), LocalVoiceCommand.silenceCurrent);
    expect(command('請停止說話。'), LocalVoiceCommand.silenceCurrent);
  });

  test('Portuguese reference silence cases have native equivalents', () {
    for (final text in [
      '闭嘴。', '好了，闭嘴；别再说了，谢谢。',
      'Hermes，你能停止说话吗？', '够了，谢谢。', '我不想再听你说话了。',
      '我觉得你现在可以停止播放语音了，谢谢。',
      '请取消朗读。', '请不要继续说话。', '请静音。', '我不想再听了。',
    ]) {
      expect(command(text), LocalVoiceCommand.silenceCurrent, reason: text);
    }
  });

  test('pause and explicit conversation termination remain distinct', () {
    for (final text in ['暂停对话。', '好的，休息一下。', '请稍等一下。', '先把对话暂停一下吧。']) {
      expect(command(text), LocalVoiceCommand.pause, reason: text);
    }
    for (final text in ['Hermes，结束对话。', '今天的对话就到这里，谢谢。',
      '我想取消这次对话。', '不要继续这次对话了。', '請結束對話。']) {
      expect(command(text), LocalVoiceCommand.end, reason: text);
    }
  });

  test('content, negation, speed, confirmation and repetition are not controls', () {
    for (final text in [
      '多讲讲沉默。', '请谈谈生产力。', '好的。', '为什么不说慢一点？',
      '我不想让你说得更快。', '请说慢一点。', '请说快一点。',
      '解释一下停止说话是什么意思。', '怎样取消朗读？', '不要取消对话。',
      '请不要停止朗读。', '我不想结束对话。', '确认。', '请确认。',
      '再说一遍。', '请重复刚才的话。', '写一句包含闭嘴的话。',
      '这本书叫结束对话。', '如果我说暂停对话会怎样？',
      '请停止说话然后解释一下原因。', '不要暂停对话。',
      '取消订单。', '请谈谈安静的房间。', '不要静音。',
      '请把静音这个词翻译成英语。',
    ]) {
      expect(command(text), isNull, reason: text);
    }
  });

  test('every deterministic phrase maps to its intended enum', () {
    for (final (phrases, expected) in [
      (language.commands.silence, LocalVoiceCommand.silenceCurrent),
      (language.commands.pause, LocalVoiceCommand.pause),
      (language.commands.end, LocalVoiceCommand.end),
    ]) {
      for (final phrase in phrases) {
        expect(command(phrase), expected, reason: phrase);
      }
    }
  });

  test('hours and minutes use Chinese readings including zero', () {
    expect(speech.speakTimes('现在00:00，02:05，14:30。'),
        '现在零点整，两点零五分，十四点三十分。');
    expect(speech.speakTimes('09:00'), '九点整');
    expect(speech.speakTimes('2:1 45:99 v14:30 /14:30'), '2:1 45:99 v14:30 /14:30');
  });

  test('dates use year month day order and reject impossible dates', () {
    expect(speech.speakDates('交付5/6/2026。'), '交付二零二六年六月五日。');
    expect(speech.speakDates('2026-07-18和2024/02/29'),
        '二零二六年七月十八日和二零二四年二月二十九日');
    expect(speech.speakDates('2026年7月18日'), '二零二六年七月十八日');
    expect(speech.speakDates('31/2/2026 2023-02-29'), '31/2/2026 2023-02-29');
    for (var month = 1; month <= 12; month++) {
      expect(speech.formatDate(1, month, 2026), endsWith('月一日'));
    }
  });

  test('fractions reverse operands and keep technical paths untouched', () {
    expect(speech.speakFractions('完成1/2和3/4，还有2/3。'),
        '完成二分之一和四分之三，还有三分之二。');
    expect(speech.speakFractions('-1/2和+3/4'), '负二分之一和正四分之三');
    expect(speech.speakFractions('src/1/2 1/0 31/2/2026'), 'src/1/2 1/0 31/2/2026');
  });

  test('decimals read fractional digits and preserve signs', () {
    expect(speech.speakDecimals('比率0.99和-2.05及+1.20。'),
        '比率零点九九和负二点零五及正一点二零。');
    expect(speech.speakDecimals('v1.2.3 /1.5 x1.5 2026.07.18'),
        'v1.2.3 /1.5 x1.5 2026.07.18');
  });

  test('percentages put the unit first', () {
    expect(speech.speakPercentages('进度50%，变化-0.99%。'),
        '进度百分之五十，变化负百分之零点九九。');
  });

  test('currencies support both orders, signs and local yuan', () {
    expect(speech.speakCurrencies(r'$0.99，0.99 USD，€1.01，GBP 2.50。'),
        '零美元九十九美分，零美元九十九美分，一欧元零一欧分，两英镑五十便士。');
    expect(speech.speakCurrencies('CNY 12.05，¥2，3.50元，-1.20 EUR。'),
        '十二元零五分，两元，三元五角，负一欧元二十欧分。');
    expect(speech.speakCurrencies('RMB 0.01，人民币2.02'), '零元零一分，两元零二分');
  });

  test('integer units include internal zero and contextual liang', () {
    final cases = <String, String>{
      '0': '零', '10': '十', '12': '十二', '20': '二十', '101': '一百零一',
      '200': '两百', '1002': '一千零二', '2000': '两千',
      '10001': '一万零一', '10010': '一万零一十', '20000': '两万', '100000001': '一亿零一',
      '100010000': '一亿零一万', '999999999999': '九千九百九十九亿九千九百九十九万九千九百九十九',
    };
    for (final entry in cases.entries) {
      expect(speech.normalizeNarration(entry.key), entry.value, reason: entry.key);
    }
    expect(speech.normalizeNarration('2个人和2本书'), '两个人和两本书');
    expect(speech.normalizeNarration('2026年6月'), '二零二六年六月');
    expect(speech.normalizeNarration('v123 x2 1.2.3 1000000000000'),
        'v123 x2 1.2.3 1000000000000');
  });

  test('renderer follows the full pipeline without reinterpreting amounts', () {
    final text = render('会议在14:30，日期5/6/2026，进度0.99%，费用€1.01，完成1/2，和/或任选。');
    expect(text, '会议在十四点三十分，日期二零二六年六月五日，进度百分之零点九九，费用一欧元零一欧分，完成二分之一，和或任选。');
    expect(render('会议09:00。折扣50%。比率1.5。\n```\ncode\n```\n结束。'),
        contains('九点整。折扣百分之五十。比率一点五。'));
    expect(render('```\ncode\n```'), '已省略代码块。');
    expect(render('你好！'), '你好！');
    expect(render('你好'), '你好。');
    expect(render('这是一段\n连续的文字。'), '这是一段连续的文字。');
    expect(render('查看[文档](https://example.com)。'), '查看文档。');
  });

  test('local transcript filters preserve real requests and quoted outros', () {
    for (final text in ['[音乐]', '[噪音]', '[掌声]', '感谢观看', '请订阅本频道。']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(text), isTrue, reason: text);
    }
    for (final text in ['谢谢。', '请播放音乐。', '解释感谢观看这句话。',
      '请翻译请订阅本频道。', '我听到了掌声。', '请说慢一点。']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(text), isFalse, reason: text);
    }
    expect(VoiceResponsePolicy.wantsFullReading('请给我讲一个故事。'), isTrue);
    expect(VoiceResponsePolicy.wantsFullReading('给我讲个故事。'), isTrue);
    expect(VoiceResponsePolicy.wantsFullReading('请完整朗读这段文字。'), isTrue);
    expect(VoiceResponsePolicy.wantsFullReading('解释故事这个词。'), isFalse);
    expect(VoiceResponsePolicy.wantsFullReading('解释请完整朗读这句话。'), isFalse);
    expect(VoiceResponsePolicy.wantsFullReading('今天有什么新闻？'), isFalse);
  });
}
