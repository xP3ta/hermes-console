import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/voice_language.dart';
import 'package:hermes_android/core/services/voice/speech_renderer.dart';
import 'package:hermes_android/core/services/voice/conversation/local_voice_command_detector.dart';
import 'package:hermes_android/core/services/voice/voice_response_policy.dart';

void main() {
  final language = voiceLanguageFor('fr-FR');
  final speech = language.speech;
  const detector = LocalVoiceCommandDetector();
  LocalVoiceCommand? detect(String text) =>
      detector.detect(text, language: 'fr-FR');
  String render(String text) => const SpeechRenderer(language: 'fr')
      .render(text).map((segment) => segment.text).join(' ');

  test('French implementation preserves the approved voice metadata', () {
    expect(language.isDraft, isFalse);
    expect(language.code, 'fr');
    expect(language.whisperLanguage, 'fr');
    expect(language.systemSttLocales,
        ['fr_FR', 'fr_CA', 'fr_BE', 'fr-CH', 'fr-FR', 'fr']);
    expect(language.deviceTtsLocales, ['fr-FR', 'fr-CA', 'fr-BE', 'fr-CH']);
    expect(language.deviceTtsFallback, 'fr-FR');
    expect(language.neuralVoiceId, 'fr_FR-siwis-medium');
    expect(language.streamingVoiceId, 'af_heart');
    expect(language.systemTtsOnly, isFalse);
  });

  test('all eleven messages are native and preserve interpolation', () {
    expect(language.messages.length, 11);
    expect(language.message('didNotHear'), 'Je ne vous ai pas entendu.');
    expect(language.message('recognitionUnavailable', {'status': 'indisponible'}),
        'La reconnaissance vocale n’est pas prête (indisponible).');
    for (final value in language.messages.values) {
      expect(value, isNotEmpty);
      expect(value, isNot(contains('could not')));
    }
  });

  test('complete native silence requests include the Portuguese equivalents', () {
    for (final text in [
      'Tais-toi.',
      'D’accord, tais-toi ; ne parle plus, s’il te plaît.',
      'Hermes, est-ce que tu peux arrêter de parler ?',
      'Ça suffit, merci.',
      'Je ne veux plus t’entendre.',
      'Je pense que tu peux couper le son maintenant, merci.',
      'Annule la lecture.',
      'Pourrais-tu cesser de lire maintenant ?',
    ]) {
      expect(detect(text), LocalVoiceCommand.silenceCurrent, reason: text);
    }
  });

  test('pause and explicit conversation termination remain distinct', () {
    for (final text in ['Mets la conversation en pause.',
      'D’accord, fais une pause.', 'Attends un instant.']) {
      expect(detect(text), LocalVoiceCommand.pause, reason: text);
    }
    for (final text in ['Hermes, termine la conversation.',
      'Arrêtons-nous ici, merci.', 'Annule la conversation.',
      'Je voudrais fermer cette session.']) {
      expect(detect(text), LocalVoiceCommand.end, reason: text);
    }
  });

  test('content, negated cancellation and unsupported commands stay content', () {
    for (final text in [
      'Parle-moi du silence.', 'Parle de productivité.', 'D’accord.',
      'Pourquoi ne parles-tu pas plus lentement ?',
      'Je ne veux pas que tu parles plus vite.',
      'Parle plus lentement.', 'Parle plus fort.',
      'Explique la phrase ne parle plus.',
      'Comment puis-je couper le son ?',
      'Que signifie terminer la conversation ?',
      'N’annule pas la conversation.', 'Ne termine pas la conversation.',
      'Je ne veux pas annuler la lecture.',
      'Le personnage dit tais-toi dans le roman.',
      'Écris une histoire avec les mots pause et silence.',
      'Confirme.', 'Je confirme.', 'Oui, confirme cela.',
      'Répète.', 'Peux-tu répéter la réponse ?', 'Encore une fois.',
      'Arrête le serveur.', 'Ne fais pas de pause.',
    ]) {
      expect(detect(text), isNull, reason: text);
    }
  });

  test('clock uses French hours and minutes including midnight', () {
    expect(speech.speakTimes('00:00 01:00 14:05 23:30'),
        'minuit une heure quatorze heures cinq vingt-trois heures trente');
    expect(speech.speakTimes('2:1 45:99'), '2:1 45:99');
  });

  test('dates use all twelve French months and first-day ordinal', () {
    const months = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
    for (var month = 1; month <= 12; month++) {
      expect(speech.speakDates('1/$month/2026'),
          'premier ${months[month - 1]} deux mille vingt-six');
    }
    expect(speech.speakDates('5/6/2026'), 'cinq juin deux mille vingt-six');
    expect(speech.speakDates('31/2/2026'), '31/2/2026');
    expect(speech.speakDates('29/2/2024'), 'vingt-neuf février deux mille vingt-quatre');
  });

  test('fractions and decimal digits retain their value', () {
    expect(speech.speakFractions('1/2 1/3 3/4 2/5'),
        'un demi un tiers trois quarts deux cinquièmes');
    expect(speech.speakDecimals('-0,05 et 1.25'),
        'moins zéro virgule zéro cinq et un virgule deux cinq');
    expect(speech.speakPercentages('-0,99% et 50 %'),
        'moins zéro virgule neuf neuf pour cent et cinquante pour cent');
  });

  test('currencies preserve zero, signs, cents and grammatical gender', () {
    expect(speech.speakCurrencies('0,99€ ; €1,01 ; 2 USD ; GBP 1,01'),
        'zéro euro et quatre-vingt-dix-neuf centimes ; un euro et un centime ; '
        'deux dollars américains ; une livre sterling et un penny');
    expect(speech.speakCurrencies(r'-$0.50 ; -1,01 EUR ; 2 £'),
        'moins zéro dollar américain et cinquante cents ; '
        'moins un euro et un centime ; deux livres sterling');
  });

  test('French integers support the documented range and irregular plurals', () {
    expect(speech.normalizeNarration('0 21 71 80 81 91 200 201 1000 2000000'),
        'zéro vingt et un soixante et onze quatre-vingts quatre-vingt-un '
        'quatre-vingt-onze deux cents deux cent un mille deux millions');
    expect(speech.normalizeNarration('999999999'),
        'neuf cent quatre-vingt-dix-neuf millions neuf cent quatre-vingt-dix-neuf '
        'mille neuf cent quatre-vingt-dix-neuf');
    expect(speech.normalizeNarration('1000000000'), '1000000000');
  });

  test('grammar does not reinterpret paths, versions or date fragments', () {
    const technical = '/tmp/1/2 v1.2.3 build42 45:99 31/2/2026';
    expect(speech.speakDecimals(technical), technical);
    expect(speech.speakFractions(technical), technical);
    expect(speech.normalizeNarration(technical), technical);
    expect(speech.speakDecimals('1,234,567'), '1,234,567');
    expect(speech.speakCurrencies('USD 1,234'), 'USD 1,234');
    expect(speech.speakConjunctions('lecture et/ou écriture'), 'lecture et ou écriture');
  });

  test('French conjunction replacement consumes both complete words once', () {
    for (final input in ['lecture et/ou écriture', 'lecture et / ou écriture',
      'lecture et/ ou écriture', 'lecture et /ou écriture']) {
      expect(speech.speakConjunctions(input), 'lecture et ou écriture', reason: input);
    }
    expect(speech.speakConjunctions('et/ou'), 'et ou');
    expect(speech.speakConjunctions('lecture et/ou écriture et/ou dessin'),
        'lecture et ou écriture et ou dessin');
    expect(speech.speakConjunctions('projet/ouverture et outil'),
        'projet/ouverture et outil');
    expect(render('Lecture et/ou écriture.'), 'Lecture et ou écriture.');
  });

  test('renderer adapts all Portuguese renderer fixtures to native French', () {
    final spoken = render('Réunion à 15:00. Remise de 50%. Rapport 1,5. '
        'Livraison le 5/6/2026. Une part de 1/2. Prix 0,99€.\n'
        '```\ncode\n```\nFin.');
    for (final expected in ['quinze heures', 'cinquante pour cent',
      'un virgule cinq', 'cinq juin deux mille vingt six', 'un demi',
      'zéro euro et quatre vingt dix neuf centimes', 'Bloc de code omis.']) {
      expect(spoken, contains(expected));
    }
    expect('Bloc de code omis.'.allMatches(spoken).length, 1);
    expect(render('Voir [la documentation](https://example.org).'),
        'Voir la documentation.');
    expect(render('Sources : https://example.org'), isEmpty);
  });

  test('transcript markers stay conservative and preserve real requests', () {
    for (final text in ['[Musique]', '(Rires)', 'Abonnez-vous à la chaîne.']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(text), isTrue);
    }
    for (final text in ['Merci.', 'Mets de la musique.',
      'Explique la phrase abonnez-vous à la chaîne.',
      'Pourquoi dit-on merci d’avoir regardé ?']) {
      expect(VoiceResponsePolicy.isLikelySttHallucination(text), isFalse);
    }
    expect(VoiceResponsePolicy.wantsFullReading('Raconte-moi un conte.'), isTrue);
    expect(VoiceResponsePolicy.wantsFullReading('Lis ce poème.'), isTrue);
    expect(VoiceResponsePolicy.wantsFullReading('Explique la pause.'), isFalse);
  });
}
