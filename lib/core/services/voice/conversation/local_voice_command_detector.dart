/// Intenciones de control que se pueden consumir íntegramente en el móvil.
/// Nunca se convierten en un mensaje de chat ni requieren un modelo/servidor.
enum LocalVoiceCommand { silenceCurrent, pause, end }

/// Detector cerrado y determinista de controles hablados para una sesión de
/// voz ya activa.
///
/// Combina formas inequívocas con un clasificador semántico pequeño por rasgos
/// (acción de detener + habla/audio, rechazo a seguir escuchando, etc.). No hace
/// red, no usa un LLM y el usuario no tiene que aprender una frase literal.
/// Exige, aun así, que el enunciado completo parezca un control: una petición
/// normal como «explícame por qué no hablas más de esto» no silencia a Hermes.
class LocalVoiceCommandDetector {
  const LocalVoiceCommandDetector();

  static const int _maxTranscriptChars = 180;

  LocalVoiceCommand? detect(String transcript, {required String language}) {
    if (transcript.isEmpty || transcript.length > _maxTranscriptChars) {
      return null;
    }
    var text = _normalize(transcript);
    if (text.isEmpty) return null;

    final languageCode = language.toLowerCase().split(RegExp('[-_]')).first;
    final grammar = switch (languageCode) {
      'es' => _spanish,
      'en' => _english,
      'pt' => _portuguese,
      _ => null,
    };
    if (grammar == null) return null;

    text = _stripEdges(text, grammar.leading, grammar.trailing);
    if (text.isEmpty) return null;

    // Las órdenes destructivas requieren una forma explícita y tienen
    // prioridad si alguna futura gramática comparte vocabulario.
    if (_isCommandSequence(text, grammar.end, grammar.connectors)) {
      return LocalVoiceCommand.end;
    }
    if (_isCommandSequence(text, grammar.pause, grammar.connectors)) {
      return LocalVoiceCommand.pause;
    }
    if (_isCommandSequence(text, grammar.silence, grammar.connectors)) {
      return LocalVoiceCommand.silenceCurrent;
    }
    return switch (languageCode) {
      'es' => _semanticSpanish(text),
      'pt' => _semanticPortuguese(text),
      _ => _semanticEnglish(text),
    };
  }

  static LocalVoiceCommand? _semanticSpanish(String text) {
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

  static LocalVoiceCommand? _semanticEnglish(String text) {
    final words = text.split(' ');
    if (_containsAny(text, const [
      'why did',
      'why do',
      'how do',
      'how can',
      'what does',
    ])) {
      return null;
    }
    if (_hasStem(words, const ['explain', 'tell', 'describe', 'translate'])) {
      return null;
    }

    final conversation = _hasStem(words, const [
      'conversation',
      'session',
      'mode',
    ]);
    final endAction = _hasStem(words, const [
      'end',
      'close',
      'finish',
      'terminate',
    ]);
    if (conversation && endAction) return LocalVoiceCommand.end;

    final pauseAction = _hasStem(words, const ['pause', 'wait', 'hold']);
    if (pauseAction &&
        (conversation ||
            words.contains('moment') ||
            words.contains('second') ||
            words.contains('pause'))) {
      return LocalVoiceCommand.pause;
    }

    if (_hasStem(words, const [
      'faster',
      'slower',
      'louder',
      'volume',
      'speed',
      'clearly',
    ])) {
      return null;
    }

    if (words.any(
          const {'quiet', 'silence', 'enough', 'shush', 'shh'}.contains,
        ) ||
        _containsAny(text, const ['shut up', 'thats plenty'])) {
      return LocalVoiceCommand.silenceCurrent;
    }

    final stopAction = _hasStem(words, const [
      'stop',
      'quit',
      'cut',
      'mute',
      'silence',
      'cease',
    ]);
    final speechTarget = _hasStem(words, const [
      'talk',
      'speak',
      'read',
      'voice',
      'audio',
      'sound',
      'listen',
      'hear',
    ]);
    if (stopAction && speechTarget) {
      return LocalVoiceCommand.silenceCurrent;
    }

    final negative =
        words.contains('dont') ||
        words.contains('no') ||
        _containsAny(text, const ['do not', 'i dont want', 'i do not want']);
    if (negative &&
        speechTarget &&
        (_hasStem(words, const ['keep', 'continu']) ||
            words.contains('anymore') ||
            words.contains('want'))) {
      return LocalVoiceCommand.silenceCurrent;
    }
    if (stopAction &&
        (words.contains('please') ||
            words.contains('now') ||
            words.contains('you')) &&
        words.length <= 10) {
      return LocalVoiceCommand.silenceCurrent;
    }
    return null;
  }

  static LocalVoiceCommand? _semanticPortuguese(String text) {
    final words = text.split(' ');
    // Perguntas e pedidos de conteúdo nunca são controles.
    if (_containsAny(text, const [
      'por que',
      'como posso',
      'o que significa',
      'me conta',
      'me explica',
      'me fala',
      'fale sobre',
      'fala sobre',
      'mais sobre',
    ])) {
      return null;
    }
    if (_hasStem(words, const ['explic', 'descrev', 'traduz'])) {
      return null;
    }

    final conversation = _hasStem(words, const [
      'conversa',
      'sessa',
      'modo',
    ]);
    final endAction = _hasStem(words, const [
      'termin',
      'encerr',
      'finaliz',
      'acab',
    ]);
    final rejectsContinuation =
        words.contains('nao') &&
        _hasStem(words, const ['continu', 'segu']) &&
        conversation;
    if (conversation && (endAction || rejectsContinuation)) {
      return LocalVoiceCommand.end;
    }

    final pauseAction = _hasStem(words, const ['paus', 'esper', 'aguard']);
    if (pauseAction &&
        (conversation ||
            words.contains('momento') ||
            words.contains('instante') ||
            _hasStem(words, const ['paus']))) {
      return LocalVoiceCommand.pause;
    }

    // Estas palavras costumam modificar COMO Hermes deve falar, não pedir
    // silêncio.
    if (_hasStem(words, const [
      'rapido',
      'devagar',
      'lent',
      'alto',
      'baixo',
      'clar',
      'velocidade',
      'volume',
    ])) {
      return null;
    }

    if (words.any(
      const {
        'cala',
        'cale',
        'silencio',
        'chega',
        'basta',
        'quieto',
        'quieta',
        'sh',
        'shh',
        'shhh',
      }.contains,
    )) {
      return LocalVoiceCommand.silenceCurrent;
    }

    final stopAction = _hasStem(words, const [
      'cort',
      'deix',
      'deslig',
      'silenci',
      'cal',
      'mud',
    ]);
    final explicitStop = words.any(
      const {'parar', 'pare', 'para'}.contains,
    );
    final speechTarget = _hasStem(words, const [
      'fal',
      'ler',
      'lendo',
      'voz',
      'audio',
      'sonando',
      'tocando',
      'escut',
      'ouv',
      'ouc',
    ]);
    if ((stopAction || explicitStop) && speechTarget) {
      return LocalVoiceCommand.silenceCurrent;
    }

    final negative =
        words.contains('nao') ||
        words.contains('nunca') ||
        _containsAny(text, const ['ja nao', 'nao quero', 'nao preciso']);
    if (negative &&
        speechTarget &&
        (_hasStem(words, const ['continu', 'segu']) ||
            words.contains('mais') ||
            words.contains('quero') ||
            words.contains('preciso'))) {
      return LocalVoiceCommand.silenceCurrent;
    }

    // Em fase speaking, «pode parar já?» tem um referente inequívoco: a
    // locução atual. Não aceitamos «para» isolado nem a preposição «para mim».
    if (explicitStop &&
        (words.contains('pode') ||
            words.contains('poderia') ||
            words.contains('ja') ||
            words.contains('agora')) &&
        words.length <= 10) {
      return LocalVoiceCommand.silenceCurrent;
    }
    return null;
  }

  static bool _hasStem(List<String> words, List<String> stems) =>
      words.any((word) => stems.any(word.startsWith));

  static bool _containsAny(String text, List<String> phrases) =>
      phrases.any(text.contains);

  static bool _isCommandSequence(
    String text,
    List<String> phrases,
    List<String> connectors,
  ) {
    var rest = text;
    var matched = false;
    while (rest.isNotEmpty) {
      String? phrase;
      for (final candidate in phrases) {
        if (rest == candidate || rest.startsWith('$candidate ')) {
          phrase = candidate;
          break;
        }
      }
      if (phrase == null) return false;
      matched = true;
      rest = rest.substring(phrase.length).trimLeft();
      if (rest.isEmpty) return true;
      rest = _stripLeading(rest, connectors);
    }
    return matched;
  }

  static String _stripEdges(
    String text,
    List<String> leading,
    List<String> trailing,
  ) {
    var value = _stripLeading(text, leading);
    var changed = true;
    while (changed && value.isNotEmpty) {
      changed = false;
      for (final phrase in trailing) {
        if (value == phrase) return '';
        if (value.endsWith(' $phrase')) {
          value = value.substring(0, value.length - phrase.length).trimRight();
          changed = true;
          break;
        }
      }
    }
    return value;
  }

  static String _stripLeading(String text, List<String> phrases) {
    var value = text;
    var changed = true;
    while (changed && value.isNotEmpty) {
      changed = false;
      for (final phrase in phrases) {
        if (value == phrase) return '';
        if (value.startsWith('$phrase ')) {
          value = value.substring(phrase.length).trimLeft();
          changed = true;
          break;
        }
      }
    }
    return value;
  }

  static String _normalize(String input) {
    var value = input.toLowerCase();
    const replacements = <String, String>{
      'á': 'a',
      'à': 'a',
      'ä': 'a',
      'â': 'a',
      'ã': 'a',
      'é': 'e',
      'è': 'e',
      'ë': 'e',
      'ê': 'e',
      'í': 'i',
      'ì': 'i',
      'ï': 'i',
      'î': 'i',
      'ó': 'o',
      'ò': 'o',
      'ö': 'o',
      'ô': 'o',
      'õ': 'o',
      'ú': 'u',
      'ù': 'u',
      'ü': 'u',
      'û': 'u',
      'ñ': 'n',
      'ç': 'c',
      '’': '',
      "'": '',
    };
    for (final entry in replacements.entries) {
      value = value.replaceAll(entry.key, entry.value);
    }
    return value
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

class _CommandGrammar {
  final List<String> silence;
  final List<String> pause;
  final List<String> end;
  final List<String> leading;
  final List<String> trailing;
  final List<String> connectors;

  const _CommandGrammar({
    required this.silence,
    required this.pause,
    required this.end,
    required this.leading,
    required this.trailing,
    required this.connectors,
  });
}

// Cada lista va de la forma más larga a la más corta para que el consumidor de
// secuencias no acepte un prefijo dejando palabras sin clasificar.
const _spanish = _CommandGrammar(
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

const _english = _CommandGrammar(
  silence: [
    'i do not want you to keep talking',
    'i dont want you to keep talking',
    'do not speak anymore',
    'dont speak anymore',
    'do not talk anymore',
    'dont talk anymore',
    'please stop speaking',
    'please stop talking',
    'stop speaking',
    'stop talking',
    'be quiet',
    'thats enough',
    'shut up',
    'silence',
    'enough',
  ],
  pause: [
    'put the conversation on pause',
    'pause the conversation',
    'take a pause',
    'pause this',
    'pause',
  ],
  end: [
    'i want to end the conversation',
    'i want to close the conversation',
    'finish the conversation',
    'close the conversation',
    'end the conversation',
    'lets stop here',
  ],
  leading: [
    'okay hermes',
    'please hermes',
    'hermes',
    'listen',
    'please',
    'well',
    'okay',
    'ok',
    'hey',
  ],
  trailing: ['please', 'thank you', 'thanks', 'okay', 'ok'],
  connectors: ['and also', 'and now', 'and', 'okay', 'please'],
);

// Formas normalizadas (sem acentos: _normalize remove-os antes de comparar),
// das mais longas para as mais curtas, igual às outras gramáticas.
const _portuguese = _CommandGrammar(
  silence: [
    'nao quero que voce continue falando',
    'nao quero que voce fale mais',
    'nao quero te ouvir mais',
    'quero que voce pare de falar',
    'quero que voce cale a boca',
    'pode parar de falar',
    'nao continue falando',
    'pare de falar',
    'para de falar',
    'nao fale mais',
    'nao fala mais',
    'cala a boca',
    'fica quieto',
    'fica quieta',
    'ja chega',
    'silencio',
    'chega',
    'basta',
  ],
  pause: [
    'coloca a conversa em pausa',
    'pausa a conversa',
    'vamos pausar',
    'faz uma pausa',
    'da uma pausa',
    'pausa isso',
    'pausa',
  ],
  end: [
    'quero terminar a conversa',
    'quero encerrar a conversa',
    'quero fechar a conversa',
    'termina a conversa',
    'encerra a conversa',
    'finaliza a conversa',
    'fecha a conversa',
    'vamos encerrar por aqui',
    'vamos parar por aqui',
  ],
  leading: [
    'por favor hermes',
    'oi hermes',
    'alo hermes',
    'hermes',
    'por favor',
    'escuta',
    'olha',
    'entao',
    'beleza',
    'ta bom',
    'okay',
    'ok',
    'oi',
    'alo',
  ],
  trailing: [
    'por favor',
    'muito obrigado',
    'muito obrigada',
    'obrigado',
    'obrigada',
    'valeu',
    'ta bom',
    'beleza',
    'ok',
    'okay',
  ],
  connectors: ['e tambem', 'e agora', 'e', 'ok', 'okay', 'por favor', 'valeu'],
);
