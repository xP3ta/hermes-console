part of '../voice_language.dart';

class _PtVoiceLanguage extends VoiceLanguage {
  const _PtVoiceLanguage() : super(
    code: "pt",
    whisperLanguage: "pt",
    systemSttLocales: const ["pt_BR", "pt_PT", "pt-BR", "pt"],
    deviceTtsLocales: const ["pt-BR", "pt-PT"],
    deviceTtsFallback: "pt-BR",
    neuralVoiceId: "pt_BR-faber-medium",
    streamingVoiceId: "pm_santa",
    transcript: _ptTranscriptGrammar,
    messages: _ptVoiceMessages,
    commands: _ptVoiceCommands,
    speech: const _PtSpeechGrammar(),
  );

  @override
  LocalVoiceCommand? semanticCommand(String text) {
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
}

const _ptVoiceCommands = VoiceCommandGrammar(
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

const _ptVoiceMessages = <String, String>{
  "microphoneReleasing": "O microfone ainda está sendo liberado.",
  "microphoneUnclear": "Não consegui entender o microfone.",
  "didNotHear": "Não ouvi você.",
  "microphoneUnavailable": "Não foi possível iniciar o microfone.",
  "sendFailed": "Não foi possível enviar a mensagem.",
  "responseInterrupted": "A resposta foi interrompida.",
  "serverUnavailable": "A voz do servidor Hermes está indisponível. A voz foi pausada.",
  "approvalRequired": "Hermes precisa da sua aprovação. Abra o app para revisar.",
  "responseRequired": "Hermes precisa da sua resposta. Abra o app para continuar.",
  "stopNotSaved": "Não foi possível salvar o Stop com segurança. Tente novamente.",
  "recognitionUnavailable": "O reconhecimento de voz não está pronto ({status})."
};

class _PtSpeechGrammar extends VoiceSpeechGrammar {
  const _PtSpeechGrammar();

  @override
  String get linkWord => "link";
  @override
  String get codeNotice => "Bloco de código omitido.";
  @override
  String get emailAt => " arroba ";
  @override
  String get emailDot => " ponto ";
  @override
  String get conjunctionPattern => r'(?<=\b[yeo])\s*/\s*(?=(?:ou|[oaui])\b)';
  @override
  String get orWord => " ou ";
  @override
  String get decimalSeparator => "vírgula";
  @override
  String get percentUnit => "por cento";
  @override
  String get currencyJoiner => " com ";
  @override
  String get referenceHeadingPattern => "fontes?";
  @override
  bool get dateMonthFirst => false;
  @override
  bool get decimalUsesDot => false;

  @override
  (String, String, String, String)? currencyNames(String currency) => switch (currency) {
    "€" => ("euro", "euros", "centavo", "centavos"),
    "\$" => ("dólar", "dólares", "centavo", "centavos"),
    "£" => ("libra", "libras", "centavo", "centavos"),
    _ => null,
  };

  @override
  String clock(int hour, String minutes) => minutes == '00'
      ? "$hour em ponto"
      : "$hour e ${int.parse(minutes)}";

  static const _months = [
      'janeiro',
      'fevereiro',
      'março',
      'abril',
      'maio',
      'junho',
      'julho',
      'agosto',
      'setembro',
      'outubro',
      'novembro',
      'dezembro',
    ];

  @override
  String formatDate(int day, int month, int year) => '$day de ${_months[month - 1]} de $year';

  @override
  String formatFraction(String numerator, String denominator) {
    if (numerator == '1' && denominator == '2') return "um meio";
    if (numerator == '3' && denominator == '4') return "três quartos";
    return '$numerator entre $denominator';
  }
}


// The existing global transcript filter had no Portuguese-specific patterns.
const _ptTranscriptGrammar = VoiceTranscriptGrammar();
