import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/voice_language.dart';
import 'package:hermes_android/core/services/voice/speech_renderer.dart';
import 'package:hermes_android/core/services/voice/conversation/local_voice_command_detector.dart';
import 'package:hermes_android/core/services/voice/voice_response_policy.dart';

void main() {
  final language = voiceLanguageFor('de-DE');
  final speech = language.speech;
  const detector = LocalVoiceCommandDetector();
  LocalVoiceCommand? detect(String text) =>
      detector.detect(text, language: 'de-DE');
  String render(String text) => const SpeechRenderer(language: 'de')
      .render(text)
      .map((segment) => segment.text)
      .join(' ');

  test('German record preserves approved metadata and owns all messages', () {
    expect(language.isDraft, isFalse);
    expect(language.code, 'de');
    expect(language.whisperLanguage, 'de');
    expect(language.systemSttLocales,
        ['de_DE', 'de_AT', 'de_CH', 'de-DE', 'de']);
    expect(language.deviceTtsLocales, ['de-DE', 'de-AT', 'de-CH']);
    expect(language.deviceTtsFallback, 'de-DE');
    expect(language.neuralVoiceId, 'de_DE-thorsten-medium');
    expect(language.streamingVoiceId, 'af_heart');
    expect(language.systemTtsOnly, isFalse);
    expect(language.messages.keys.toSet(),
        voiceLanguageFor('en').messages.keys.toSet());
    expect(language.messages, hasLength(11));
    for (final key in language.messages.keys) {
      expect(language.message(key), isNot(voiceLanguageFor('en').message(key)),
          reason: key);
    }
    expect(language.message('recognitionUnavailable', {'status': 'offline'}),
        'Die Spracherkennung ist nicht bereit (offline).');
  });

  const controls = <LocalVoiceCommand, List<String>>{
    LocalVoiceCommand.silenceCurrent: [
      'Sei still.',
      'Gut, sei still; sprich nicht weiter, bitte.',
      'Hermes, kannst du aufhören zu sprechen?',
      'Es reicht, danke.',
      'Ich möchte dich nicht mehr hören.',
      'Ich denke, du kannst jetzt die Sprachausgabe stoppen, danke.',
      'Hör auf zu reden.',
      'Höre auf vorzulesen.',
      'Sprich nicht weiter.',
      'Brich die Sprachausgabe ab.',
      'Kannst du bitte die aktuelle Antwort abbrechen?',
      'Ich will nicht, dass du weiterredest.',
      'Du kannst jetzt aufhören.',
    ],
    LocalVoiceCommand.pause: [
      'Pausiere das Gespräch.',
      'Okay, mach eine Pause.',
      'Hermes, kannst du das Gespräch kurz pausieren?',
      'Warte einen Moment.',
      'Bitte pausiere die Unterhaltung.',
    ],
    LocalVoiceCommand.end: [
      'Hermes, beende das Gespräch.',
      'Lass uns hier Schluss machen, danke.',
      'Ich möchte die Unterhaltung beenden.',
      'Brich das Gespräch ab.',
      'Kannst du die Unterhaltung jetzt beenden?',
      'Ich möchte dieses Gespräch nicht fortsetzen.',
    ],
  };
  for (final entry in controls.entries) {
    for (final phrase in entry.value) {
      test('German control: $phrase', () {
        expect(detect(phrase), entry.key);
      });
    }
  }

  for (final phrase in [
    'Erzähl mir mehr über Stille.',
    'Sprich über Produktivität.',
    'Okay.',
    'Warum sprichst du nicht langsamer?',
    'Ich möchte nicht, dass du schneller sprichst.',
    'Bitte sprich langsamer.',
    'Bitte sprich schneller.',
    'Erkläre den Satz hör auf zu reden.',
    'Wie kann ich die Sprachausgabe stoppen?',
    'Was bedeutet beende das Gespräch?',
    'Erkläre den Satz beende das Gespräch bitte.',
    'Erkläre den Satz warte einen Moment bitte.',
    'Erkläre den Satz hör auf zu reden bitte.',
    'Beende das Gespräch nicht.',
    'Bitte brich die Unterhaltung nicht ab.',
    'Hör nicht auf zu sprechen.',
    'Pausiere das Gespräch nicht.',
    'Das Wort Stille steht im Text.',
    'Schreibe eine Geschichte über eine Pause.',
    'Die Figur sagt sei still und geht weg.',
    'Stoppe den Download.',
    'Bestätige das bitte.',
    'Ja, bestätigen.',
    'Wiederhole das bitte.',
    'Sag das noch einmal.',
    'Bitte erkläre, warum ich nicht mehr hören möchte.',
  ]) {
    test('German content remains content: $phrase', () {
      expect(detect(phrase), isNull);
    });
  }

  test('all deterministic phrases are reachable and normalization handles umlauts', () {
    expect(language.normalizeCommand('HÖR auf, größere Straße!'),
        'hoer auf groessere strasse');
    for (final entry in {
      LocalVoiceCommand.silenceCurrent: language.commands.silence,
      LocalVoiceCommand.pause: language.commands.pause,
      LocalVoiceCommand.end: language.commands.end,
    }.entries) {
      for (final phrase in entry.value) {
        expect(detect(phrase), entry.key, reason: phrase);
      }
    }
  });

  test('Portuguese renderer scenarios have native German equivalents', () {
    final spoken = render('''
Besprechung um 15:00. Rabatt 50%. Verhältnis 1,5.
```
code
```
Ende.
''');
    expect(spoken, contains('fünfzehn Uhr'));
    expect(spoken, contains('fünfzig Prozent'));
    expect(spoken, contains('eins Komma fünf'));
    expect('Codeblock ausgelassen.'.allMatches(spoken), hasLength(1));
    expect(spoken, isNot(contains('code')));
    expect(render('Abgabe am 5/6/2026.'),
        contains('am fünften Juni zweitausendsechsundzwanzig'));
  });

  test('clock handles midnight, one o clock and minutes', () {
    expect(speech.speakTimes('00:00 01:00 09:05 14:30 23:59'),
        'null Uhr ein Uhr neun Uhr fünf vierzehn Uhr dreißig '
        'dreiundzwanzig Uhr neunundfünfzig');
    expect(speech.speakTimes('2:1 45:99 v14:30 /14:30/x'),
        '2:1 45:99 v14:30 /14:30/x');
  });

  test('dates support local slash, local dot and ISO without decimal corruption', () {
    for (final date in ['5/6/2026', '05.06.2026', '2026-06-05']) {
      expect(render('Termin am $date.'),
          'Termin am fünften Juni zweitausendsechsundzwanzig.');
    }
    expect(speech.speakDates('29.02.2024'),
        'neunundzwanzigster Februar zweitausendvierundzwanzig');
    expect(speech.speakDates('29.02.2025 31/4/2026'),
        '29.02.2025 31/4/2026');
    const months = [
      'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
      'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember',
    ];
    for (var month = 1; month <= 12; month++) {
      expect(speech.formatDate(1, month, 2026), contains(months[month - 1]));
    }
  });

  test('fractions preserve dates and use native denominator names', () {
    expect(speech.speakFractions('1/2 3/4 2/3 5/8 2/7'),
        'ein Halb drei Viertel zwei Drittel fünf Achtel zwei Siebtel');
    expect(speech.speakFractions('2/9 1/20 2/2'),
        'zwei Neuntel ein Zwanzigstel zwei Halbe');
    expect(speech.speakFractions('-1/2 +3/4'), 'minus ein Halb plus drei Viertel');
    expect(speech.speakFractions('1/0 31/13/2026 src/1/2/file'),
        '1/0 31/13/2026 src/1/2/file');
  });

  test('decimals preserve zero digits, signs and technical strings', () {
    expect(speech.speakDecimals('0,05 -1,50 +2.75 −3,01'),
        'null Komma null fünf minus eins Komma fünf null '
        'plus zwei Komma sieben fünf minus drei Komma null eins');
    expect(speech.speakDecimals('05.06.2026 v1.2.3 /tmp/1.5/file 1.234,56'),
        '05.06.2026 v1.2.3 /tmp/1.5/file '
        'eintausendzweihundertvierunddreißig Komma fünf sechs');
    expect(render('Wert 0,99 und 0,99%.'),
        'Wert null Komma neun neun und null Komma neun neun Prozent.');
  });

  test('currencies handle codes, symbols, minor units, signs and grouping', () {
    expect(speech.speakCurrencies(r'€1,01 0,99 EUR USD 2.50 £1.01 GBP 2'),
        'ein Euro und ein Cent null Euro und neunundneunzig Cent '
        'zwei US-Dollar und fünfzig Cent ein Pfund Sterling und ein Penny '
        'zwei Pfund Sterling');
    expect(speech.speakCurrencies('1.234,56 € -0,05 EUR +1 EUR'),
        'eintausendzweihundertvierunddreißig Euro und sechsundfünfzig Cent '
        'minus null Euro und fünf Cent plus ein Euro');
    expect(speech.speakCurrencies(r'-€1,01, +$2.50; −£0.05.'),
        'minus ein Euro und ein Cent, plus zwei US-Dollar und fünfzig Cent; '
        'minus null Pfund Sterling und fünf Pence.');
    expect(render('Preis 1,01 €.'), 'Preis ein Euro und ein Cent.');
  });

  test('currency tokens are paired left to right without stealing the next amount', () {
    const grouped = 'eintausendzweihundertvierunddreißig Euro und sechsundfünfzig Cent';
    expect(speech.speakCurrencyAmount('1.234,56', 'EUR'), grouped);
    for (final input in [
      '1.234,56 EUR -0,05 EUR +1 EUR',
      '1.234,56 € -0,05 EUR +1 EUR',
      'EUR 1.234,56 -0,05 EUR +1 EUR',
    ]) {
      expect(speech.speakCurrencies(input),
          '$grouped minus null Euro und fünf Cent plus ein Euro', reason: input);
    }
    expect(speech.speakCurrencies('1 EUR 2 USD 3 GBP'),
        'ein Euro zwei US-Dollar drei Pfund Sterling');
    expect(speech.speakCurrencies('EUR 1 USD 2 GBP 3'),
        'ein Euro zwei US-Dollar drei Pfund Sterling');
    expect(render('Preis 1.234,56 EUR.'), 'Preis $grouped.');
  });

  test('numbers use German composition and leave technical tokens intact', () {
    expect(speech.normalizeNarration('0 1 16 17 21 30 60 70 100 101 1000 1000000'),
        'null eins sechzehn siebzehn einundzwanzig dreißig sechzig siebzig '
        'einhundert einhunderteins eintausend eine Million');
    expect(speech.normalizeNarration('999999999'),
        'neunhundertneunundneunzig Millionen '
        'neunhundertneunundneunzigtausendneunhundertneunundneunzig');
    expect(speech.normalizeNarration('1000000000 v2 file3 45:99 1/0'),
        '1000000000 v2 file3 45:99 1/0');
  });

  test('conjunctions, links, email and references use German vocabulary', () {
    expect(render('Wähle Tee und/oder Kaffee.'),
        'Wähle Tee und oder Kaffee.');
    expect(render('Siehe https://example.com und 1/2.'),
        contains('Verweis und ein Halb'));
    expect(render('Mail a@example.org.'), contains('a ät example Punkt org'));
    expect(render('Quellen:\nhttps://example.com'), isEmpty);
    expect(render('Lies `read_aloud_session` in /tmp/sample-file.'),
        contains('sample file'));
  });

  test('German STT markers are conservative and requests remain intact', () {
    for (final label in ['[Musik]', '(Stille)', '[Geräusche]', '[Applaus]']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(label), isTrue,
          reason: label);
    }
    for (final outro in ['Danke fürs Zuschauen.', 'Abonniert den Kanal!']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(outro), isTrue);
    }
    for (final request in [
      'Danke für deine Hilfe.',
      'Bitte spiele Musik.',
      'Was bedeutet Danke fürs Zuschauen?',
      'Übersetze Abonniert den Kanal ins Englische.',
      'Erkläre das Wort Stille.',
    ]) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(request), isFalse,
          reason: request);
    }
    for (final request in [
      'Erzähl mir eine Geschichte.',
      'Lies mir den ganzen Text vor.',
      'Trage mir ein Gedicht vor.',
    ]) {
      expect(VoiceResponsePolicy.wantsFullReading(request), isTrue);
    }
    expect(VoiceResponsePolicy.wantsFullReading('Erkläre den Begriff Geschichte.'),
        isFalse);
  });
}
