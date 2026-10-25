part of '../voice_language.dart';

class _EsVoiceLanguage extends VoiceLanguage {
  const _EsVoiceLanguage() : super(
    code: "es",
    whisperLanguage: "es",
    systemSttLocales: const ["es_ES", "es_US", "es_MX", "es_419", "es_CO", "es_AR", "es-ES", "es"],
    deviceTtsLocales: const ["es-ES", "es-US", "es-MX", "es-419", "es-CO", "es-AR"],
    deviceTtsFallback: "es-ES",
    neuralVoiceId: "es_ES-davefx-medium",
    streamingVoiceId: "em_santa",
    transcript: _esTranscriptGrammar,
    messages: _esVoiceMessages,
    commands: _esVoiceCommands,
    speech: const _EsSpeechGrammar(),
  );

  @override
  LocalVoiceCommand? semanticCommand(String text) {
    final words = text.split(' ');
    if (_containsAny(text, const [
      'por que',
      'como puedo',
      'como se',
      'que significa',
    ])) {
      return null;
    }
    if (_hasStem(words, const [
      'explic',
      'cuentame',
      'dime',
      'hablame',
      'describe',
      'traduce',
    ])) {
      return null;
    }

    final conversation = _hasStem(words, const [
      'conversacion',
      'sesion',
      'modo',
    ]);
    final endAction = _hasStem(words, const [
      'termin',
      'cerr',
      'finaliz',
      'acab',
    ]);
    final rejectsContinuation =
        words.contains('no') &&
        _hasStem(words, const ['segu', 'continu']) &&
        conversation;
    if (conversation && (endAction || rejectsContinuation)) {
      return LocalVoiceCommand.end;
    }

    final pauseAction = _hasStem(words, const ['paus', 'esper', 'aguard']);
    if (pauseAction &&
        (conversation ||
            words.contains('momento') ||
            words.contains('rato') ||
            _hasStem(words, const ['paus']))) {
      return LocalVoiceCommand.pause;
    }

    // Estas palabras suelen modificar CÓMO debe hablar, no pedir que se calle.
    if (_hasStem(words, const [
      'rapido',
      'despacio',
      'lent',
      'alto',
      'bajo',
      'clar',
      'velocidad',
      'volumen',
    ])) {
      return null;
    }

    if (words.any(
      const {
        'callate',
        'calla',
        'callese',
        'silencio',
        'basta',
        'sh',
        'shh',
        'shhh',
      }.contains,
    )) {
      return LocalVoiceCommand.silenceCurrent;
    }

    final stopAction = _hasStem(words, const [
      'deten',
      'cort',
      'dej',
      'apag',
      'silenci',
      'call',
    ]);
    final explicitStop = words.any(
      const {'parar', 'pares', 'pare', 'para'}.contains,
    );
    final speechTarget = _hasStem(words, const [
      'habl',
      'leer',
      'leyendo',
      'voz',
      'audio',
      'sonando',
      'escuch',
      'oir',
    ]);
    if ((stopAction || explicitStop) && speechTarget) {
      return LocalVoiceCommand.silenceCurrent;
    }

    final negative =
        words.contains('no') ||
        words.contains('nunca') ||
        _containsAny(text, const ['ya no', 'no quiero', 'no me apetece']);
    if (negative &&
        speechTarget &&
        (_hasStem(words, const ['segu', 'continu']) ||
            words.contains('mas') ||
            words.contains('quiero') ||
            words.contains('apetece'))) {
      return LocalVoiceCommand.silenceCurrent;
    }

    // En fase speaking, «¿puedes parar ya?» tiene un referente inequívoco: la
    // locución actual. No aceptamos «para» aislado ni la preposición «para mí».
    if (explicitStop &&
        (words.contains('puedes') ||
            words.contains('puede') ||
            words.contains('ya')) &&
        words.length <= 10) {
      return LocalVoiceCommand.silenceCurrent;
    }
    return null;
  }
}

const _esVoiceCommands = VoiceCommandGrammar(
  silence: [
    'no quiero que sigas hablando',
    'no quiero que hable mas',
    'no quiero que hables mas',
    'no quiero escucharte mas',
    'no quiero oirte mas',
    'quiero que pares de hablar',
    'quiero que se calle',
    'quiero que te calles',
    'puedes parar de hablar',
    'puede parar de hablar',
    'no sigas hablando',
    'no siga hablando',
    'deje de hablar',
    'deja de hablar',
    'para de hablar',
    'ya no hables',
    'ya no hable',
    'no hables mas',
    'no hable mas',
    'te puedes callar',
    'puede callarse',
    'puedes callarte',
    'ya esta',
    'silencio',
    'callate',
    'basta',
  ],
  pause: [
    'pon la conversacion en pausa',
    'pausa la conversacion',
    'vamos a pausar',
    'haz una pausa',
    'pausa esto',
    'pausa',
  ],
  end: [
    'quiero terminar la conversacion',
    'quiero cerrar la conversacion',
    'termina la conversacion',
    'terminemos la conversacion',
    'finaliza la conversacion',
    'cierra la conversacion',
    'acaba la conversacion',
    'dejemoslo aqui',
  ],
  leading: [
    'a ver hermes',
    'por favor hermes',
    'eh hermes',
    'hermes',
    'por favor',
    'escucha',
    'oye',
    'mira',
    'bueno',
    'vale',
    'okay',
    'ok',
    'eh',
  ],
  trailing: ['por favor', 'muchas gracias', 'gracias', 'vale'],
  connectors: ['y tambien', 'y ahora', 'y', 'vale', 'por favor'],
);

const _esVoiceMessages = <String, String>{
  "microphoneReleasing": "El micrófono todavía se está liberando.",
  "microphoneUnclear": "No pude entender el micrófono.",
  "didNotHear": "No te he oído.",
  "microphoneUnavailable": "No se pudo iniciar el micrófono.",
  "sendFailed": "No se pudo enviar el mensaje.",
  "responseInterrupted": "La respuesta se interrumpió.",
  "serverUnavailable": "La voz del servidor Hermes no está disponible. Voz se ha pausado.",
  "approvalRequired": "Hermes necesita tu aprobación. Abre la aplicación para revisarla.",
  "responseRequired": "Hermes necesita tu respuesta. Abre la aplicación para continuar.",
  "stopNotSaved": "No se pudo guardar Stop de forma segura. Reinténtalo.",
  "recognitionUnavailable": "El reconocimiento de voz no está listo ({status})."
};

class _EsSpeechGrammar extends VoiceSpeechGrammar {
  const _EsSpeechGrammar();

  @override
  String get linkWord => "enlace";
  @override
  String get codeNotice => "Bloque de código omitido.";
  @override
  String get emailAt => " arroba ";
  @override
  String get emailDot => " punto ";
  @override
  String get conjunctionPattern => r'(?<=\b[yeo])\s*/\s*(?=(?:ou|[oaui])\b)';
  @override
  String get orWord => " o ";
  @override
  String get decimalSeparator => "coma";
  @override
  String get percentUnit => "por ciento";
  @override
  String get currencyJoiner => " con ";
  @override
  String get referenceHeadingPattern => "fuentes?|referencias?|bibliograf[ií]a";
  @override
  bool get dateMonthFirst => false;
  @override
  bool get decimalUsesDot => false;

  @override
  (String, String, String, String)? currencyNames(String currency) => switch (currency) {
    "€" => ("euro", "euros", "céntimo", "céntimos"),
    "\$" => ("dólar", "dólares", "centavo", "centavos"),
    "£" => ("libra", "libras", "penique", "peniques"),
    _ => null,
  };

  @override
  String clock(int hour, String minutes) => minutes == '00'
      ? "$hour en punto"
      : "$hour y ${int.parse(minutes)}";

  static const _months = [
      'enero',
      'febrero',
      'marzo',
      'abril',
      'mayo',
      'junio',
      'julio',
      'agosto',
      'septiembre',
      'octubre',
      'noviembre',
      'diciembre',
    ];

  @override
  String formatDate(int day, int month, int year) => '$day de ${_months[month - 1]} de $year';

  @override
  String formatFraction(String numerator, String denominator) {
    if (numerator == '1' && denominator == '2') return "un medio";
    if (numerator == '3' && denominator == '4') return "tres cuartos";
    return '$numerator entre $denominator';
  }
}


const _esTranscriptGrammar = VoiceTranscriptGrammar(
  fullReadingWords: r'\b('
      r'cuento|cuentos|cuentito|cuentitos|relato|relatos|fabula|fabulas|'
      r'poema|poemas|poesia|poesias|chiste|chistes|adivinanza|adivinanzas|'
      r'trabalenguas|cancion|canciones|cantame|'
      r'recita|recitame|recitalo|recitanos|'
      r'leeme|leelo|leenos|narrame|narranos'
      r')\b',
  fullReadingPhrases: ['una historia', 'historia para dormir', 'lee en voz alta', 'letra de'],
  nonSpeechLabels: r'musica|ruido|silencio|risas?|aplausos?|inaudible|ininteligible',
  strongMarkers: ['subtitulos realizados por', 'subtitulado por', 'gracias por ver el video'],
  subscribeOutro: r'^(?:por favor )?(?:suscribete|suscribanse) al canal(?: gracias)?$',
);
