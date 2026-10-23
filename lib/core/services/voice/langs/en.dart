part of '../voice_language.dart';

class _EnVoiceLanguage extends VoiceLanguage {
  const _EnVoiceLanguage() : super(
    code: "en",
    whisperLanguage: "en",
    systemSttLocales: const ["en_US", "en_GB", "en_AU", "en_IN", "en-US", "en"],
    deviceTtsLocales: const ["en-US", "en-GB", "en-AU", "en-IN"],
    deviceTtsFallback: "en-US",
    neuralVoiceId: "en_US-amy-medium",
    streamingVoiceId: "af_heart",
    transcript: _enTranscriptGrammar,
    messages: _enVoiceMessages,
    commands: _enVoiceCommands,
    speech: const _EnSpeechGrammar(),
  );

  @override
  LocalVoiceCommand? semanticCommand(String text) {
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
}

const _enVoiceCommands = VoiceCommandGrammar(
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

const _enVoiceMessages = <String, String>{
  "microphoneReleasing": "The microphone is still being released.",
  "microphoneUnclear": "I could not understand the microphone.",
  "didNotHear": "I did not hear you.",
  "microphoneUnavailable": "The microphone could not be started.",
  "sendFailed": "The message could not be sent.",
  "responseInterrupted": "The response was interrupted.",
  "serverUnavailable": "Hermes server voice is unavailable. Voice was paused.",
  "approvalRequired": "Hermes needs your approval. Open the app to review it.",
  "responseRequired": "Hermes needs your response. Open the app to continue.",
  "stopNotSaved": "Couldn't save Stop safely. Try again.",
  "recognitionUnavailable": "Voice recognition is not ready ({status})."
};

class _EnSpeechGrammar extends VoiceSpeechGrammar {
  const _EnSpeechGrammar();

  @override
  String get linkWord => "link";
  @override
  String get codeNotice => "Code block omitted.";
  @override
  String get emailAt => " at ";
  @override
  String get emailDot => " dot ";
  @override
  String get conjunctionPattern => r'(?<=\b[yeo])\s*/\s*(?=(?:ou|[oaui])\b)';
  @override
  String get orWord => " or ";
  @override
  String get decimalSeparator => "point";
  @override
  String get percentUnit => "percent";
  @override
  String get currencyJoiner => " and ";
  @override
  String get referenceHeadingPattern => "sources?|references?|bibliography";
  @override
  bool get dateMonthFirst => true;
  @override
  bool get decimalUsesDot => true;

  @override
  (String, String, String, String)? currencyNames(String currency) => switch (currency) {
    "€" => ("euro", "euros", "cent", "cents"),
    "\$" => ("dollar", "dollars", "cent", "cents"),
    "£" => ("pound", "pounds", "penny", "pence"),
    _ => null,
  };

  @override
  String clock(int hour, String minutes) => minutes == '00'
      ? "$hour o'clock"
      : "$hour ${int.parse(minutes)}";

  static const _months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];

  @override
  String formatDate(int day, int month, int year) => '${_months[month - 1]} $day, $year';

  @override
  String formatFraction(String numerator, String denominator) {
    if (numerator == '1' && denominator == '2') return "one half";
    if (numerator == '3' && denominator == '4') return "three quarters";
    return '$numerator over $denominator';
  }
}


const _enTranscriptGrammar = VoiceTranscriptGrammar(
  nonSpeechLabels: r'music|noise|silence|laughter|laughs?|applause',
  strongMarkers: ['amara.org', 'thanks for watching', 'thanks watching', 'thank you for watching', 'thank you watching'],
  subscribeOutro: r'^(?:please )?subscribe to the channel(?: gracias)?$',
);
