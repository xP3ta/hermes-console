import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/voice_language.dart';
import 'package:hermes_android/core/services/voice/voice_response_policy.dart';

List<String> _noticeProblems(Map<String, Map<String, String>> catalogs) {
  final problems = <String>[];
  final english = catalogs['en']!;
  List<String> placeholders(String value) => RegExp(r'\{[A-Za-z_][A-Za-z_0-9]*\}')
      .allMatches(value).map((match) => match[0]!).toList()..sort();
  for (final entry in catalogs.entries) {
    final actual = entry.value;
    if (actual.length != english.length || !actual.keys.toSet().containsAll(english.keys)) {
      problems.add('${entry.key}:keys');
    }
    for (final key in english.keys) {
      final value = actual[key];
      if (value == null) continue;
      if (value.trim().isEmpty) problems.add('${entry.key}:$key:empty');
      if (placeholders(value).join(',') != placeholders(english[key]!).join(',')) {
        problems.add('${entry.key}:$key:placeholders');
      }
    }
  }
  return problems;
}

void main() {
  test('one complete language record owns every voice locale', () {
    expect(voiceLanguages.keys, unorderedEquals(['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']));
    for (final entry in voiceLanguages.entries) {
      final language = entry.value;
      expect(language.code, entry.key);
      expect(language.whisperLanguage, entry.key);
      expect(language.systemSttLocales, isNotEmpty);
      expect(language.deviceTtsLocales, isNotEmpty);
      expect(language.deviceTtsFallback.startsWith('${entry.key}-'), isTrue);
    }
  });
  test('spoken notice catalogs have matching keys and placeholders', () {
    expect(_noticeProblems({
      for (final entry in voiceLanguages.entries) entry.key: entry.value.messages,
    }), isEmpty);
  });
  test('notice parity rejects missing keys, empty text and broken placeholders', () {
    final english = voiceLanguages['en']!.messages;
    final missing = {...english}..remove('didNotHear');
    final empty = {...english, 'didNotHear': ' '};
    final placeholder = {...english, 'recognitionUnavailable': 'Unavailable ({state}).'};
    expect(_noticeProblems({'en': english, 'mutant': missing}), contains('mutant:keys'));
    expect(_noticeProblems({'en': english, 'mutant': empty}), contains('mutant:didNotHear:empty'));
    expect(_noticeProblems({'en': english, 'mutant': placeholder}), contains('mutant:recognitionUnavailable:placeholders'));
  });
  test('regional voice codes normalize and unknown codes use English', () {
    expect(voiceLanguageFor('pt_BR').code, 'pt');
    expect(voiceLanguageFor('zh-Hant-TW').code, 'zh');
    expect(voiceLanguageFor('unknown').code, 'en');
  });
  test('Portuguese spoken copy and grammar retain the existing output', () {
    final language = voiceLanguageFor('pt');
    expect(language.speech.clock(15, '00'), '15 em ponto');
    expect(language.speech.clock(15, '20'), '15 e 20');
    expect(language.speech.formatDate(5, 6, 2026), '5 de junho de 2026');
    expect(language.speech.formatFraction('1', '2'), 'um meio');
    expect(language.speech.formatFraction('3', '4'), 'três quartos');
    expect(language.speech.codeNotice, 'Bloco de código omitido.');
    expect(language.message('didNotHear'), 'Não ouvi você.');
    expect(language.message('recognitionUnavailable', {'status': 'unavailable'}),
        'O reconhecimento de voz não está pronto (unavailable).');
    expect(language.systemSttLocales, ['pt_BR', 'pt_PT', 'pt-BR', 'pt']);
    expect(language.deviceTtsLocales, ['pt-BR', 'pt-PT']);
  });
  test('Japanese uses system TTS and Korean has no automatic neural default', () {
    expect(voiceLanguageFor('ja').neuralVoiceId, isNull);
    expect(voiceLanguageFor('ko').neuralVoiceId, isNull);
  });
  test('user text in a notice is substituted once', () {
    expect(voiceLanguageFor('pt').message('recognitionUnavailable', {'status': '{status}'}),
        'O reconhecimento de voz não está pronto ({status}).');
  });
  test('real Japanese, Korean and Chinese transcripts are not silence', () {
    for (final transcript in ['明日の予定を教えて', '내일 일정을 알려 주세요', '告诉我明天的日程']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(transcript), isFalse,
          reason: transcript);
    }
    for (final noise in ['', '...', '！？']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(noise), isTrue);
    }
  });
}
