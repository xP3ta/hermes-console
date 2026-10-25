import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/voice_language.dart';
import 'package:hermes_android/core/services/voice/speech_renderer.dart';
import 'package:hermes_android/core/services/voice/conversation/local_voice_command_detector.dart';
import 'package:hermes_android/core/services/voice/voice_response_policy.dart';

void main() {
  final language = voiceLanguageFor('ko-KR');
  final speech = language.speech;
  const detector = LocalVoiceCommandDetector();
  LocalVoiceCommand? detect(String text) =>
      detector.detect(text, language: 'ko-KR');
  String render(String text) => const SpeechRenderer(language: 'ko')
      .render(text).map((segment) => segment.text).join(' ');

  test('uses native grammar and preserves approved metadata', () {
    expect(language.isDraft, isFalse);
    expect(language.code, 'ko');
    expect(language.whisperLanguage, 'ko');
    expect(language.systemSttLocales, ['ko_KR', 'ko-KR', 'ko']);
    expect(language.deviceTtsLocales, ['ko-KR']);
    expect(language.deviceTtsFallback, 'ko-KR');
    expect(language.neuralVoiceId, isNull);
    expect(language.streamingVoiceId, 'af_heart');
    expect(language.systemTtsOnly, isFalse);
    expect(language.commands.wordSeparated, isFalse);
    expect(language.normalizeCommand('헤르메스, 말하기를 멈춰 주세요!'),
        '헤르메스말하기를멈춰주세요');
  });

  test('localizes every spoken message and preserves status', () {
    expect(language.messages.keys.toSet(), voiceLanguageFor('en').messages.keys.toSet());
    expect(language.messages, hasLength(11));
    for (final message in language.messages.values) {
      expect(message, matches(RegExp('[가-힣]')));
    }
    expect(language.message('recognitionUnavailable', {'status': 'offline'}),
        '음성 인식을 사용할 준비가 되지 않았어요 (offline).');
  });

  const silence = [
    '조용히 해.',
    '알겠어, 조용히 해. 더 이상 말하지 마, 부탁해.',
    '헤르메스, 말하기를 멈춰 줄 수 있어?',
    '이제 충분해, 고마워.',
    '더 이상 듣고 싶지 않아.',
    '이제 음성을 꺼 줘도 돼, 고마워.',
    '읽기를 멈춰 주세요.',
    '낭독을 취소해 주세요.',
    '말하기를멈춰주세요',
    '지금 말하는 것을 그만해 주세요.',
    '계속 말하지 않았으면 좋겠어.',
    '이제 그만해도 돼.',
  ];
  for (final phrase in silence) {
    test('silences current speech: $phrase', () {
      expect(detect(phrase), LocalVoiceCommand.silenceCurrent);
    });
  }
  const pauses = [
    '대화를 잠시 멈춰 주세요.', '알겠어, 잠깐 쉬자.',
    '잠시 기다려 주세요.', '대화를일시정지해',
  ];
  for (final phrase in pauses) {
    test('pauses without ending: $phrase', () {
      expect(detect(phrase), LocalVoiceCommand.pause);
    });
  }
  const endings = [
    '헤르메스, 대화를 끝내 줘.', '여기서 마치자, 고마워.',
    '대화를 취소해 주세요.', '이 대화를 계속하고 싶지 않아.',
    '이제 대화를 종료해도 돼.',
  ];
  for (final phrase in endings) {
    test('ends an explicit conversation: $phrase', () {
      expect(detect(phrase), LocalVoiceCommand.end);
    });
  }
  const content = [
    '침묵에 대해 더 말해 줘.', '생산성에 대해 말해 줘.', '알겠어.',
    '왜 더 천천히 말하지 않아?', '더 빨리 말하지 않았으면 좋겠어.',
    '좀 더 천천히 말해 주세요.', '더 빨리 말해 줘.',
    '대화를 취소하지 마.', '대화를 끝내지 말아 주세요.',
    '낭독을 취소하지 마세요.', '음성을 어떻게 끄나요?',
    '조용히 해라는 말의 뜻을 설명해 줘.',
    '대화를 끝내 줘라는 문장을 번역해 줘.',
    '대화를 끝내면 어떻게 돼?', '그는 조용히 해라고 말했어.',
    '취소라는 단어가 들어 있는 이야기를 해 줘.',
    '확인해 줘.', '확인.', '네.', '다시 말해 줘.', '반복해 주세요.',
    '말하기를멈춰주세요라는문장을설명해줘',
    '대화를 끝내 줘 그리고 날씨를 알려 줘.',
  ];
  for (final phrase in content) {
    test('keeps content and unsupported controls: $phrase', () {
      expect(detect(phrase), isNull);
    });
  }
  test('rejects excessive input', () {
    expect(detect(List.filled(50, '조용히 해').join(' ')), isNull);
  });
  test('every deterministic phrase works with and without spaces', () {
    for (final entry in {
      LocalVoiceCommand.silenceCurrent: language.commands.silence,
      LocalVoiceCommand.pause: language.commands.pause,
      LocalVoiceCommand.end: language.commands.end,
    }.entries) {
      for (final phrase in entry.value) {
        expect(detect(phrase), entry.key, reason: phrase);
        expect(detect(phrase.split('').join(' ')), entry.key, reason: phrase);
      }
    }
  });
  test('semantic controls consume complete natural requests', () {
    expect(language.semanticCommand(language.normalizeCommand(
        '지금 말하는 것을 그만해 주세요')), LocalVoiceCommand.silenceCurrent);
    expect(language.semanticCommand(language.normalizeCommand(
        '이제 대화를 종료해도 돼')), LocalVoiceCommand.end);
    expect(language.semanticCommand('대화를종료해도돼라는말을설명해줘'), isNull);
  });

  test('renders Portuguese reference cases in Korean', () {
    final spoken = render('회의는 15:00. 할인은 50%. 비율은 1.5.\n'
        '```\ncode\n```\n끝.');
    expect(spoken, contains('열다섯 시 정각'));
    expect(spoken, contains('오십 퍼센트'));
    expect(spoken, contains('일 점 오'));
    expect('코드 블록은 생략했어요.'.allMatches(spoken), hasLength(1));
    expect(spoken, isNot(contains('code')));
    expect(render('마감은 5/6/2026.'), contains('이천이십육 년 유월 오 일'));
  });
  test('reads native hours and Sino-Korean minutes including midnight', () {
    const cases = {
      '00:00': '영 시 정각', '01:05': '한 시 오 분',
      '02:00': '두 시 정각', '03:30': '세 시 삼십 분',
      '04:09': '네 시 구 분', '12:00': '열두 시 정각',
      '20:15': '스무 시 십오 분', '23:59': '스물세 시 오십구 분',
      '3시 05분': '세 시 오 분',
    };
    for (final entry in cases.entries) {
      expect(render('시각은 ${entry.key}입니다.'), contains(entry.value));
    }
    expect(speech.speakTimes('45:99 2:1 v14:30 /tmp/14:30'),
        '45:99 2:1 v14:30 /tmp/14:30');
    expect(speech.speakTimes('3시 99분 3시 05분7'), '3시 99분 3시 05분7');
  });
  test('reads dates before fractions and validates calendar dates', () {
    expect(render('2026-10-23, 2026/06/05, 2024년 2월 29일'),
        contains('이천이십육 년 시월 이십삼 일'));
    expect(speech.speakDates('2026-02-29 31/2/2026'),
        '2026-02-29 31/2/2026');
    const months = [
      '일월', '이월', '삼월', '사월', '오월', '유월',
      '칠월', '팔월', '구월', '시월', '십일월', '십이월',
    ];
    for (var month = 1; month <= 12; month++) {
      expect(speech.formatDate(1, month, 2026),
          '이천이십육 년 ${months[month - 1]} 일 일');
    }
    expect(speech.speakDates('2024년 2월 29일'),
        '이천이십사 년 이월 이십구 일');
    expect(speech.speakFractions('1/2 3/4 -2/3'),
        '이 분의 일 사 분의 삼 마이너스 삼 분의 이');
    expect(speech.speakFractions('/tmp/1/2 1/0 31/2/2026'),
        '/tmp/1/2 1/0 31/2/2026');
  });
  test('reads signed decimals and percentages digit by digit', () {
    expect(render('값은 -0.05, +1.20, 0.99%와 50%.'),
        '값은 마이너스 영 점 영 오, 플러스 일 점 이 영, 영 점 구 구 퍼센트와 오십 퍼센트.');
    expect(speech.speakDecimals('v1.2.3 /tmp/1.5 x1.5'),
        'v1.2.3 /tmp/1.5 x1.5');
  });
  test('reads currency symbols and ISO codes including Korean won', () {
    const cases = {
      r'$0.99': '영 달러 구십구 센트', '0.99 USD': '영 달러 구십구 센트',
      '0,99€': '영 유로 구십구 센트',
      'EUR 1.01': '일 유로 일 센트', '£2.50': '이 파운드 오십 펜스',
      '12 GBP': '십이 파운드', '₩15000': '만 오천 원',
      '15000 KRW': '만 오천 원', '15000원': '만 오천 원',
      '-USD 1.05': '마이너스 일 달러 오 센트',
    };
    for (final entry in cases.entries) {
      expect(render(entry.key), '${entry.value}.', reason: entry.key);
    }
  });
  test('reads standalone integers and preserves technical tokens', () {
    expect(speech.normalizeNarration('0 10 101 10000 100000001'),
        '영 십 백일 만 일억 일');
    expect(speech.normalizeNarration('v123 file123 /tmp/123 45:99 1.2.3'),
        'v123 file123 /tmp/123 45:99 1.2.3');
    expect(speech.normalizeNarration('1000000000000000'), '1000000000000000');
  });
  test('localizes conjunctions and technical notices', () {
    expect(render('선택은 그리고/또는 입니다.'), contains('그리고 또는'));
    expect(render('선택은 및/또는 입니다.'), contains('및 또는'));
    expect(render('문서 https://example.com 다음'), contains('링크'));
    expect(render('참고 자료:\nhttps://example.com'), isEmpty);
    expect(render('끝났어요?'), '끝났어요?');
  });
  test('filters only delimited noise and complete stock outros', () {
    for (final text in ['[음악]', '(잡음)', '[박수]', '채널을 구독해 주세요.']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(text), isTrue, reason: text);
    }
    for (final text in [
      '음악을 틀어 주세요.', '고마워요.', '시청해 주셔서 감사합니다.',
      '채널을 구독해 주세요라는 문장을 번역해 줘.',
      '잡음이라는 단어를 설명해 줘.',
    ]) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(text), isFalse, reason: text);
    }
  });
  test('recognizes full reading requests conservatively', () {
    for (final text in ['동화를 읽어 줘.', '시를 낭독해 주세요.', '이야기를 들려줘']) {
      expect(VoiceResponsePolicy.wantsFullReading(text), isTrue, reason: text);
    }
    for (final text in ['날씨를 알려 줘.', '동화라는 단어를 설명해 줘.', '소식 알려 줘', '도시를 읽어 줘.']) {
      expect(VoiceResponsePolicy.wantsFullReading(text), isFalse, reason: text);
    }
  });
}
