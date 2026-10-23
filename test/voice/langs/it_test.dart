import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/voice_language.dart';
import 'package:hermes_android/core/services/voice/speech_renderer.dart';
import 'package:hermes_android/core/services/voice/voice_response_policy.dart';
import 'package:hermes_android/core/services/voice/conversation/local_voice_command_detector.dart';

void main() {
  final language = voiceLanguageFor('it-IT');
  final speech = language.speech;
  const detector = LocalVoiceCommandDetector();
  String render(String text) => const SpeechRenderer(language: 'it')
      .render(text).map((segment) => segment.text).join(' ');

  test('Italian owns its implementation and preserves approved metadata', () {
    expect(language.isDraft, isFalse);
    expect(language.code, 'it');
    expect(language.whisperLanguage, 'it');
    expect(language.systemSttLocales, ['it_IT', 'it_CH', 'it-IT', 'it']);
    expect(language.deviceTtsLocales, ['it-IT', 'it-CH']);
    expect(language.deviceTtsFallback, 'it-IT');
    expect(language.neuralVoiceId, 'it_IT-paola-medium');
    expect(language.streamingVoiceId, 'af_heart');
    expect(language.systemTtsOnly, isFalse);
    expect(language.messages.keys.toSet(), voiceLanguageFor('en').messages.keys.toSet());
    expect(language.messages, hasLength(11));
    for (final entry in language.messages.entries) {
      expect(entry.value, isNot(voiceLanguageFor('en').messages[entry.key]));
      expect(entry.value.trim(), isNotEmpty);
    }
    expect(language.message('recognitionUnavailable', {'status': 'busy'}),
        'Il riconoscimento vocale non è pronto (busy).');
  });

  final controls = <String, LocalVoiceCommand>{
    'Stai zitto.': LocalVoiceCommand.silenceCurrent,
    'Va bene, stai zitto; non parlare più, per favore.': LocalVoiceCommand.silenceCurrent,
    'Hermes, puoi smettere di parlare?': LocalVoiceCommand.silenceCurrent,
    'Basta così, grazie.': LocalVoiceCommand.silenceCurrent,
    'Non voglio più sentirti.': LocalVoiceCommand.silenceCurrent,
    'Credo che tu possa interrompere l’audio, grazie.': LocalVoiceCommand.silenceCurrent,
    'Cancella la lettura.': LocalVoiceCommand.silenceCurrent,
    'Puoi smettere adesso?': LocalVoiceCommand.silenceCurrent,
    'Non voglio che continui a parlare.': LocalVoiceCommand.silenceCurrent,
    'Metti in pausa la conversazione.': LocalVoiceCommand.pause,
    'Ok, fai una pausa.': LocalVoiceCommand.pause,
    'Puoi aspettare un momento?': LocalVoiceCommand.pause,
    'Vorrei mettere in pausa la conversazione.': LocalVoiceCommand.pause,
    'Hermes, termina la conversazione.': LocalVoiceCommand.end,
    'Fermiamoci qui, grazie.': LocalVoiceCommand.end,
    'Cancella la conversazione.': LocalVoiceCommand.end,
    'Vorrei chiudere questa sessione.': LocalVoiceCommand.end,
    'Non voglio continuare la conversazione.': LocalVoiceCommand.end,
  };
  for (final entry in controls.entries) {
    test('complete control: ${entry.key}', () {
      expect(detector.detect(entry.key, language: 'it-IT'), entry.value);
    });
  }
  for (final text in [
    'Parlami del silenzio.', 'Parlami della produttività.', 'Ok.',
    'Perché non parli più lentamente?', 'Non voglio che parli più velocemente.',
    'Puoi parlare più piano?', 'Puoi parlare più forte?',
    'Spiegami la frase smetti di parlare.', 'Come posso silenziare l’audio?',
    'Non cancellare la conversazione.', 'Non voglio terminare la conversazione.',
    'Non mettere in pausa la conversazione.', 'Non interrompere la lettura.',
    'Il testo contiene basta e termina la conversazione.',
    'Scrivi una storia in cui qualcuno dice stai zitto.',
    'Conferma.', 'Sì, confermo.', 'Ripeti.', 'Puoi ripetere la risposta?',
    'Cancella il file.', 'Pausa pranzo alle dodici.',
  ]) {
    test('ordinary content: $text', () {
      expect(detector.detect(text, language: 'it'), isNull);
    });
  }
  test('semantic requests use complete anchored clauses', () {
    expect(language.semanticCommand(language.normalizeCommand(
        'Saresti così gentile da smettere di leggere adesso?')),
        LocalVoiceCommand.silenceCurrent);
    expect(language.semanticCommand('il silenzio e importante'), isNull);
    expect(detector.detect(List.filled(60, 'basta').join(' '), language: 'it'), isNull);
  });

  test('Portuguese renderer scenarios have native Italian equivalents', () {
    final text = render('Riunione alle 15:00. Sconto del 50%. Valore 1,5.\n'
        '```\ncode\n```\nFine.');
    expect(text, contains('quindici in punto'));
    expect(text, contains('cinquanta per cento'));
    expect(text, contains('uno virgola cinque'));
    expect('Blocco di codice omesso.'.allMatches(text), hasLength(1));
    expect(text, isNot(contains('code')));
    expect(render('Consegna il 5/6/2026.'), contains('cinque giugno duemilaventisei'));
  });
  test('clock handles midnight, singular and minutes', () {
    expect(speech.speakTimes('00:00; 01:00; 09:05; 14:30; 23:59'),
        'mezzanotte; una in punto; nove e cinque; quattordici e trenta; ventitré e cinquantanove');
    expect(speech.speakTimes('2:1 e 45:99'), '2:1 e 45:99');
  });
  test('all months and first day are Italian', () {
    const months = ['gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno',
      'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre'];
    for (var month = 1; month <= 12; month++) {
      expect(speech.formatDate(1, month, 2026), 'primo ${months[month - 1]} duemilaventisei');
    }
    expect(speech.speakDates('31/02/2026'), '31/02/2026');
  });
  test('fractions, conjunctions and signed decimal digits', () {
    expect(render('Completa 1/2 e 3/4 oppure 2/3 e 5/11.'),
        'Completa un mezzo e tre quarti oppure due terzi e cinque su undici.');
    expect(speech.speakDecimals('-0,05 e +1.25'),
        'meno zero virgola zero cinque e più uno virgola due cinque');
    expect(speech.speakPercentages('-0,99% e 50%'),
        'meno zero virgola nove nove per cento e cinquanta per cento');
    expect(render('Scegli e/o combina.'), 'Scegli e oppure combina.');
  });
  test('currencies retain zero, cents and native plurals', () {
    expect(render('Costa 0,99€, poi €1,01 e 2 EUR.'),
        'Costa zero euro e novantanove centesimi, poi un euro e un centesimo e due euro.');
    expect(speech.speakCurrencies(r'USD 1.01; 2 GBP; £0.50; -€2'),
        'un dollaro e un centesimo; due sterline; zero sterline e cinquanta penny; meno due euro');
    expect(speech.speakCurrencies(r'$2; 1 USD; GBP 1.01'),
        'due dollari; un dollaro; una sterlina e un penny');
  });
  test('integer elision, accents and supported range', () {
    expect(speech.normalizeNarration('0 21 28 23 100 108 180 1000 2026 1000000 999999999'),
        'zero ventuno ventotto ventitré cento centotto centottanta mille duemilaventisei un milione novecentonovantanove milioni novecentonovantanovemilanovecentonovantanove');
    expect(speech.normalizeNarration('1000000000'), '1000000000');
  });
  test('technical strings never become dates, money or fractions', () {
    const raw = 'v1.2.3 /tmp/1/2/file file2.txt 45:99 31/02/2026';
    expect(speech.speakDecimals(raw), raw);
    expect(speech.speakFractions(raw), raw);
    expect(speech.speakDates(raw), raw);
    expect(speech.normalizeNarration(raw), raw);
    expect(render('Apri `src/lib/main.dart` e `readAloudState`.'),
        contains('main dart e read Aloud State'));
  });
  test('calendar checks leap years and preserves invalid dates', () {
    expect(speech.speakDates('29/02/2024'), 'ventinove febbraio duemilaventiquattro');
    for (final invalid in ['29/02/2025', '32/01/2026', '01/13/2026']) {
      expect(speech.speakDates(invalid), invalid);
      expect(speech.speakFractions(invalid), invalid);
    }
  });
  test('unsupported quantities and zero denominator stay unexpanded', () {
    expect(speech.formatFraction('1', '0'), '1/0');
    expect(speech.formatCurrency('€', 1000000000, null), isNull);
    expect(speech.formatDecimal('999999999999999999999999', '05'),
        '999999999999999999999999,05');
    expect(speech.formatPercentage('1000000000', null), '1000000000%');
  });
  test('compound numbers retain final accent and remove internal accent', () {
    expect(speech.normalizeNarration('103 1003 23000 1000001'),
        'centotré milletré ventitremila un milione uno');
  });
  test('renderer keeps references and link destinations out of narration', () {
    expect(render('Fonti: https://example.org'), isEmpty);
    expect(render('Apri [la guida](https://example.org/docs).'), 'Apri la guida.');
    expect(render('Visita https://example.org per i dettagli.'),
        'Visita collegamento per i dettagli.');
  });
  test('all deterministic phrases resolve to their own command', () {
    for (final item in [
      (language.commands.silence, LocalVoiceCommand.silenceCurrent),
      (language.commands.pause, LocalVoiceCommand.pause),
      (language.commands.end, LocalVoiceCommand.end),
    ]) {
      for (final phrase in item.$1) {
        expect(detector.detect(phrase, language: 'it'), item.$2, reason: phrase);
      }
    }
  });
  test('Italian transcript patterns retain real requests and quoted markers', () {
    for (final label in ['[Musica]', '(rumore)', '[silenzio]', '[applausi]']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(label), isTrue);
    }
    expect(VoiceResponsePolicy.isLikelySttHallucination('Iscriviti al canale.'), isTrue);
    for (final text in ['Grazie.', 'Metti della musica.', 'Parlami del silenzio.',
      'Spiega la frase iscriviti al canale.', 'Grazie per aver guardato il video.']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(text), isFalse, reason: text);
    }
    expect(VoiceResponsePolicy.wantsFullReading('Leggimi una fiaba.'), isTrue);
    expect(VoiceResponsePolicy.wantsFullReading('Raccontami una storia.'), isTrue);
    expect(VoiceResponsePolicy.wantsFullReading('Riassumi le notizie.'), isFalse);
    expect(VoiceResponsePolicy.speakable('Il silenzio aiuta a concentrarsi.'), isTrue);
  });
}
