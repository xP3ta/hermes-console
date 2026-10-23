import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/voice_language.dart';
import 'package:hermes_android/core/services/voice/speech_renderer.dart';
import 'package:hermes_android/core/services/voice/conversation/local_voice_command_detector.dart';
import 'package:hermes_android/core/services/voice/voice_response_policy.dart';

void main() {
  final language = voiceLanguageFor('ja-JP');
  final speech = language.speech;
  const detector = LocalVoiceCommandDetector();
  LocalVoiceCommand? detect(String text) =>
      detector.detect(text, language: 'ja-JP');
  String render(String text) => const SpeechRenderer(language: 'ja')
      .render(text).map((segment) => segment.text).join(' ');

  test('uses native grammar and preserves approved metadata', () {
    expect(language.isDraft, isFalse);
    expect(language.commands.wordSeparated, isFalse);
    expect(language.code, 'ja');
    expect(language.whisperLanguage, 'ja');
    expect(language.systemSttLocales, ['ja_JP', 'ja-JP', 'ja']);
    expect(language.deviceTtsLocales, ['ja-JP']);
    expect(language.deviceTtsFallback, 'ja-JP');
    expect(language.neuralVoiceId, isNull);
    expect(language.streamingVoiceId, 'af_heart');
    expect(language.systemTtsOnly, isTrue);
    expect(language.messages.keys, voiceLanguageFor('en').messages.keys);
    expect(language.messages, hasLength(11));
    for (final value in language.messages.values) {
      expect(value, matches(RegExp(r'[ぁ-んァ-ン一-龯]')));
    }
    expect(language.message('recognitionUnavailable', {'status': 'busy'}),
        '音声認識の準備ができていません（busy）。');
  });

  test('preserves native scripts and accepts spaced STT', () {
    expect(language.normalizeCommand(' 読み上げ を 止めて！ '), '読み上げを止めて');
    expect(detect('読み上げ を 止めて！'), LocalVoiceCommand.silenceCurrent);
  });

  const controls = <String, LocalVoiceCommand>{
    '黙って。': LocalVoiceCommand.silenceCurrent,
    'わかった、黙って、もう話さないで、お願いします。': LocalVoiceCommand.silenceCurrent,
    'ヘルメス、話すのをやめてもらえますか？': LocalVoiceCommand.silenceCurrent,
    'もう十分、ありがとう。': LocalVoiceCommand.silenceCurrent,
    'もう聞きたくない。': LocalVoiceCommand.silenceCurrent,
    '今は音声を止めてもらえると助かります。': LocalVoiceCommand.silenceCurrent,
    '読み上げをキャンセルしてください。': LocalVoiceCommand.silenceCurrent,
    '会話を一時停止して。': LocalVoiceCommand.pause,
    'はい、少し待って。': LocalVoiceCommand.pause,
    'ちょっと待ってもらえますか？': LocalVoiceCommand.pause,
    'ヘルメス、会話を終了して。': LocalVoiceCommand.end,
    'ここで会話を終わりにしましょう、ありがとう。': LocalVoiceCommand.end,
    '会話を続けたくない。': LocalVoiceCommand.end,
    '会話をキャンセルしてください。': LocalVoiceCommand.end,
  };
  for (final entry in controls.entries) {
    test('recognizes complete control: ${entry.key}', () {
      expect(detect(entry.key), entry.value);
    });
  }

  const content = [
    '沈黙についてもっと話して。', '生産性について話して。', 'はい。',
    'どうしてもっとゆっくり話さないの？', 'もっと速く話してほしくない。',
    'もっとゆっくり話してください。', 'もっと速く話してください。',
    '「もう話さないで」という文を説明して。', '音声を止めるにはどうすればいい？',
    '会話をキャンセルしないで。', '読み上げを止めないで。',
    '会話を終了してはいけません。', '黙ってという言葉を翻訳して。',
    '確認してください。', 'もう一度言ってください。', '繰り返してください。',
    '会話を終了してという文字列を保存して。', 'キャンセル。',
    '少し待ってという台詞を書いて。', '静かな場所について教えて。',
  ];
  for (final text in content) {
    test('keeps content: $text', () => expect(detect(text), isNull));
  }

  test('reads times including irregular hours and minutes', () {
    expect(render('会議は15:00。割引は50%。比率は1.5。'),
        '会議はじゅうごじ。割引はごじゅうパーセント。比率はいちてんご。');
    for (final entry in {
      '00:00': 'れいじ', '04:01': 'よじいっぷん',
      '07:06': 'しちじろっぷん', '09:08': 'くじはっぷん',
      '14:30': 'じゅうよじさんじゅっぷん',
      '17:00': 'じゅうしちじ', '19:00': 'じゅうくじ', '23:59': 'にじゅうさんじごじゅうきゅうふん',
    }.entries) {
      expect(speech.speakTimes(entry.key), entry.value);
    }
  });

  test('reads dates and irregular calendar days before fractions', () {
    expect(render('期限は5/6/2026。'), '期限はにせんにじゅうろくねんろくがついつか。');
    expect(speech.speakDates('2026-04-20'), 'にせんにじゅうろくねんしがつはつか');
    expect(speech.formatDate(24, 7, 2026), 'にせんにじゅうろくねんしちがつにじゅうよっか');
    expect(speech.formatDate(14, 9, 2026), 'にせんにじゅうろくねんくがつじゅうよっか');
    for (var month = 1; month <= 12; month++) {
      expect(speech.formatDate(1, month, 2026), endsWith('ついたち'));
    }
    expect(speech.speakDates('31/2/2026'), '31/2/2026');
    expect(speech.speakDates('2026年4月4日'), 'にせんにじゅうろくねんしがつよっか');
    expect(speech.speakDates('29/2/2025'), '29/2/2025');
    expect(speech.speakDates('29/2/2024'), 'にせんにじゅうよんねんにがつにじゅうくにち');
    expect(speech.speakFractions('31/2/2026'), '31/2/2026');
  });

  test('reads fractions, decimals, signs, percentages and large integers', () {
    expect(render('1/2と3/4。'), 'にぶんのいちとよんぶんのさん。');
    expect(speech.speakFractions('-1/2'), 'マイナスにぶんのいち');
    expect(speech.speakFractions('1/0'), '1/0');
    expect(render('-0.05と+0.99%。'), 'マイナスれいてんれいごとプラスれいてんきゅうきゅうパーセント。');
    expect(speech.normalizeNarration('300、600、800、3000、8000、10001。'),
        'さんびゃく、ろっぴゃく、はっぴゃく、さんぜん、はっせん、いちまんいち。');
  });

  test('reads all currency positions and local yen without losing zero', () {
    expect(render(r'$0.99、0.99 USD、€1.01、GBP 2.50、¥100、200 JPY。'),
        'れいドルきゅうじゅうきゅうセント、れいドルきゅうじゅうきゅうセント、いちユーロいちセント、にポンドごじゅうペンス、ひゃくえん、にひゃくえん。');
    expect(speech.speakCurrencies('-100円'), 'マイナスひゃくえん');
    expect(speech.speakCurrencies(r'$-0.99'), 'マイナスれいドルきゅうじゅうきゅうセント');
  });

  test('leaves technical tokens and invalid times unchanged in grammar', () {
    const technical = 'v1.2.3 build42 /tmp/1/2 a09:00 45:99 2:1';
    var text = speech.speakDecimals(technical);
    text = speech.speakDates(text);
    text = speech.speakTimes(text);
    text = speech.speakFractions(text);
    expect(speech.normalizeNarration(text), technical);
    expect(render('`build42` と src/lib/main.dart。'), contains('build42'));
    expect(speech.normalizeNarration('10000000000000000'), '10000000000000000');
  });

  test('localizes markup, punctuation, links and conjunctions', () {
    final spoken = render('説明。\n```\ncode\n```\n[資料](https://example.org)と1/2。');
    expect(spoken, contains('コードブロックを省略しました。'));
    expect(spoken, isNot(contains('https')));
    expect(spoken, isNot(contains('code\n')));
    expect(speech.speakConjunctions('および/または'), 'または');
    expect(speech.withTerminalPunctuation('説明'), '説明。');
    expect(speech.withTerminalPunctuation('説明！'), '説明！');
    expect(speech.joinTableCells(['名前', '状態']), '名前、状態');
    expect(render('長い文章の\n続きです。'), '長い文章の続きです。');
  });

  test('filters only delimited non-speech and complete outro labels', () {
    for (final text in ['[音楽]', '(拍手)', '[無音]', 'チャンネル登録をお願いします']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(text), isTrue, reason: text);
    }
    for (final text in ['音楽を流して', 'ありがとう', 'ご視聴ありがとうございましたの意味を教えて',
      'チャンネル登録をお願いしますという文を訳して']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(text), isFalse, reason: text);
    }
  });

  test('recognizes narrative requests without consuming ordinary questions', () {
    for (final text in ['物語を読んで', '子供にお話を聞かせてください', '詩を朗読して']) {
      expect(VoiceResponsePolicy.wantsFullReading(text), isTrue, reason: text);
    }
    for (final text in ['物語の歴史を教えて', 'ニュースを教えて', '詩とは何ですか']) {
      expect(VoiceResponsePolicy.wantsFullReading(text), isFalse, reason: text);
    }
  });
}
