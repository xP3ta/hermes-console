// Hermes Desktop's voice fields, as Console shows them.
//
// Desktop edits voice in Settings > Voice from a fixed list of config keys
// (`apps/desktop/src/app/settings/constants.ts`): a provider and, under it,
// that provider's own model, voice and language. Console shows the same
// fields as pickers, filled with the options Desktop offers, and writes them
// with the same config patch (`PUT /api/config`).
//
// Only the paths listed here are ever read out of a config response, so no
// key, token or address can travel with them or reach the phone's storage.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Options Desktop offers for each field (`ENUM_OPTIONS`).
const Map<String, List<String>> kServerVoiceOptions = {
  'tts.provider': [
    'edge',
    'elevenlabs',
    'openai',
    'xai',
    'minimax',
    'mistral',
    'gemini',
    'neutts',
    'kittentts',
    'piper',
  ],
  'tts.edge.voice': [
    'en-US-AriaNeural',
    'en-US-JennyNeural',
    'en-US-AndrewNeural',
    'en-US-BrianNeural',
    'en-US-GuyNeural',
    'en-GB-SoniaNeural',
  ],
  'tts.openai.model': ['gpt-4o-mini-tts', 'tts-1', 'tts-1-hd'],
  'tts.openai.voice': [
    'alloy',
    'ash',
    'ballad',
    'cedar',
    'coral',
    'echo',
    'fable',
    'marin',
    'nova',
    'onyx',
    'sage',
    'shimmer',
    'verse',
  ],
  'tts.elevenlabs.model_id': [
    'eleven_v3',
    'eleven_ttv_v3',
    'eleven_multilingual_v2',
    'eleven_turbo_v2',
    'eleven_turbo_v2_5',
    'eleven_flash_v2',
    'eleven_flash_v2_5',
  ],
  'tts.xai.voice_id': ['eve'],
  'tts.minimax.model': ['speech-02-hd', 'speech-02-turbo'],
  'tts.mistral.model': ['voxtral-mini-tts-2603'],
  'tts.gemini.model': [
    'gemini-2.5-flash-preview-tts',
    'gemini-2.5-pro-preview-tts',
  ],
  'tts.gemini.voice': [
    'Zephyr',
    'Puck',
    'Charon',
    'Kore',
    'Fenrir',
    'Leda',
    'Orus',
    'Aoede',
    'Callirrhoe',
    'Autonoe',
    'Enceladus',
    'Iapetus',
    'Umbriel',
    'Algieba',
    'Despina',
    'Erinome',
    'Algenib',
    'Rasalgethi',
    'Laomedeia',
    'Achernar',
    'Alnilam',
    'Schedar',
    'Gacrux',
    'Pulcherrima',
    'Achird',
    'Zubenelgenubi',
    'Vindemiatrix',
    'Sadachbia',
    'Sadaltager',
    'Sulafat',
  ],
  'tts.neutts.model': [
    'neuphonic/neutts-air-q4-gguf',
    'neuphonic/neutts-air-q8-gguf',
    'neuphonic/neutts-air',
  ],
  'tts.kittentts.model': [
    'KittenML/kitten-tts-nano-0.8-int8',
    'KittenML/kitten-tts-micro-0.8-int8',
    'KittenML/kitten-tts-mini-0.8-int8',
  ],
  'tts.kittentts.voice': ['Jasper'],
  'tts.piper.voice': [
    'en_US-lessac-medium',
    'en_US-amy-medium',
    'en_US-ryan-high',
    'en_GB-alan-medium',
  ],
  'stt.provider': [
    'local',
    'groq',
    'openai',
    'mistral',
    'xai',
    'elevenlabs',
    'deepinfra',
  ],
  'stt.local.model': ['tiny', 'base', 'small', 'medium', 'large-v3', 'turbo'],
  'stt.openai.model': [
    'whisper-1',
    'gpt-4o-mini-transcribe',
    'gpt-4o-transcribe',
    'gpt-transcribe',
  ],
  'stt.groq.model': ['whisper-large-v3-turbo', 'whisper-large-v3'],
  'stt.mistral.model': ['voxtral-mini-latest', 'voxtral-mini-2602'],
  'stt.xai.model': ['grok-voice-transcribe-2.0', 'grok-voice-transcribe-1.0'],
  'stt.elevenlabs.model_id': ['scribe_v2', 'scribe_v1'],
  'voice.gpt_live.voice': [
    'marin',
    'cedar',
    'quartz',
    'ripple',
    'vesper',
    'willow',
    'stone',
    'gleam',
    'meridian',
    'bossa',
    'tempo',
    'beacon',
    'delta',
    'cinder',
  ],
};

/// Spanish Edge voices Console already offered. Desktop accepts any Edge
/// voice and only suggests English ones.
const List<String> kServerEdgeSpanishVoices = [
  'es-ES-ElviraNeural',
  'es-ES-AlvaroNeural',
  'es-MX-DaliaNeural',
  'es-MX-JorgeNeural',
];

/// Transcription languages offered. The empty value lets the provider detect
/// the language, which is what Hermes does when none is set.
const List<String> kServerTranscriptionLanguages = [
  '',
  'es',
  'en',
  'fr',
  'de',
  'pt',
  'it',
];

/// Longest recording, in seconds, offered for one voice turn.
const List<int> kServerMaxRecordingSeconds = [30, 60, 120, 180, 300, 600];

enum ServerVoiceFieldKind { provider, model, voice, language, other }

/// The non-secret voice fields of one Hermes profile.
class ServerVoiceFields {
  const ServerVoiceFields._(this._values, this._published);

  static const ServerVoiceFields empty = ServerVoiceFields._({}, {});

  static const String speechProvider = 'tts.provider';
  static const String transcriptionProvider = 'stt.provider';
  static const String transcription = 'stt.enabled';
  static const String echoTranscripts = 'stt.echo_transcripts';
  static const String liveTranscription = 'stt.streaming';
  static const String liveVoice = 'voice.gpt_live.voice';
  static const String livePersonality = 'voice.gpt_live.instructions';
  static const String maxRecordingSeconds = 'voice.max_recording_seconds';

  /// Model and voice fields Desktop shows under each speech provider.
  static const Map<String, List<String>> _speech = {
    'edge': ['tts.edge.voice'],
    'openai': ['tts.openai.model', 'tts.openai.voice'],
    'elevenlabs': ['tts.elevenlabs.model_id', 'tts.elevenlabs.voice_id'],
    'xai': ['tts.xai.voice_id'],
    'minimax': ['tts.minimax.model', 'tts.minimax.voice_id'],
    'mistral': ['tts.mistral.model', 'tts.mistral.voice_id'],
    'gemini': ['tts.gemini.model', 'tts.gemini.voice'],
    'neutts': ['tts.neutts.model'],
    'kittentts': ['tts.kittentts.model', 'tts.kittentts.voice'],
    'piper': ['tts.piper.voice'],
    'deepinfra': ['tts.deepinfra.model', 'tts.deepinfra.voice'],
  };

  /// Model and language fields Desktop shows under each transcription
  /// provider.
  static const Map<String, List<String>> _transcription = {
    'local': ['stt.local.model', 'stt.local.language'],
    'openai': ['stt.openai.model'],
    'groq': ['stt.groq.model'],
    'mistral': ['stt.mistral.model'],
    'xai': ['stt.xai.model'],
    'deepinfra': ['stt.deepinfra.model'],
    'elevenlabs': ['stt.elevenlabs.model_id', 'stt.elevenlabs.language_code'],
  };

  /// Every path this class reads.
  static final Set<String> paths = {
    speechProvider,
    transcriptionProvider,
    transcription,
    echoTranscripts,
    liveTranscription,
    liveVoice,
    livePersonality,
    maxRecordingSeconds,
    for (final fields in _speech.values) ...fields,
    for (final fields in _transcription.values) ...fields,
  };

  final Map<String, Object> _values;

  /// Paths the server's schema lists, with the options it publishes for
  /// each (often none).
  final Map<String, List<String>> _published;

  /// Reads the fields out of `GET /api/config` and its schema.
  factory ServerVoiceFields.read(
    Map<String, dynamic> response,
    Map<String, dynamic> schema,
  ) {
    final nested = response['config'];
    final Map<dynamic, dynamic> config = nested is Map ? nested : response;
    final values = <String, Object>{};
    for (final path in paths) {
      Object? node = config;
      for (final segment in path.split('.')) {
        node = node is Map ? node[segment] : null;
      }
      if (node is String || node is bool || node is num) values[path] = node!;
    }
    final wrapped = schema['schema'];
    final Map<dynamic, dynamic> root = wrapped is Map ? wrapped : schema;
    final fields = root['fields'];
    final published = <String, List<String>>{};
    if (fields is Map) {
      for (final path in paths) {
        if (!fields.containsKey(path)) continue;
        final spec = fields[path];
        final offered = spec is Map
            ? (spec['options'] ?? spec['enum'] ?? spec['choices'])
            : null;
        published[path] = offered is List
            ? [
                for (final option in offered)
                  if (option is String && option.trim().isNotEmpty)
                    option.trim(),
              ]
            : const [];
      }
    }
    return ServerVoiceFields._(values, published);
  }

  /// Restores what [encode] wrote; `null` when nothing usable is stored.
  static ServerVoiceFields? decode(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map) return null;
      final values = <String, Object>{};
      final rawValues = decoded['values'];
      if (rawValues is Map) {
        for (final entry in rawValues.entries) {
          final value = entry.value;
          if (paths.contains(entry.key) &&
              (value is String || value is bool || value is num)) {
            values[entry.key as String] = value as Object;
          }
        }
      }
      final published = <String, List<String>>{};
      final rawPublished = decoded['published'];
      if (rawPublished is Map) {
        for (final entry in rawPublished.entries) {
          final options = entry.value;
          if (paths.contains(entry.key) && options is List) {
            published[entry.key as String] = [
              for (final option in options)
                if (option is String) option,
            ];
          }
        }
      }
      return ServerVoiceFields._(values, published);
    } catch (_) {
      return null;
    }
  }

  String encode() => jsonEncode({'values': _values, 'published': _published});

  bool get isEmpty => _values.isEmpty && _published.isEmpty;

  /// Whether the server reports this field at all: it has a value, or its
  /// schema lists it. A field the server does not report is not shown.
  bool reports(String path) =>
      _values.containsKey(path) || _published.containsKey(path);

  /// The value as text, or `null` when it is unset or empty.
  String? text(String path) {
    final text = _values[path]?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  bool? flag(String path) {
    final value = _values[path];
    return value is bool ? value : null;
  }

  num? number(String path) {
    final value = _values[path];
    if (value is num) return value;
    return value is String ? num.tryParse(value.trim()) : null;
  }

  /// The speech provider in use, when the server says which.
  String? get speech => text(speechProvider);

  /// The transcription provider in use. Hermes transcribes with local
  /// Whisper when the profile names none.
  String? get transcriber =>
      text(transcriptionProvider) ??
      (reports(transcriptionProvider) ||
              _values.keys.any((path) => path.startsWith('stt.'))
          ? 'local'
          : null);

  /// The model and voice fields of the speech provider in use that the
  /// server reports.
  List<String> get speechFields => [
    for (final path in _speech[speech] ?? const <String>[])
      if (reports(path)) path,
  ];

  /// The model and language fields of the transcription provider in use
  /// that the server reports.
  List<String> get transcriptionFields => [
    for (final path in _transcription[transcriber] ?? const <String>[])
      if (reports(path)) path,
  ];

  /// The language field of the transcription provider in use, reported or
  /// not: fixing a wrong language must work on a server that omits defaults.
  String? get transcriptionLanguagePath {
    for (final path in _transcription[transcriber] ?? const <String>[]) {
      if (kindOf(path) == ServerVoiceFieldKind.language) return path;
    }
    return null;
  }

  static ServerVoiceFieldKind kindOf(String path) =>
      switch (path.split('.').last) {
        'provider' => ServerVoiceFieldKind.provider,
        'model' || 'model_id' => ServerVoiceFieldKind.model,
        'voice' || 'voice_id' => ServerVoiceFieldKind.voice,
        'language' || 'language_code' => ServerVoiceFieldKind.language,
        _ => ServerVoiceFieldKind.other,
      };

  /// What can be picked for [path]: Desktop's options, or the ones the
  /// server's schema publishes when Desktop has none, with the value in use
  /// always among them. Empty when there is nothing to pick from; the field
  /// is then shown but cannot be changed here.
  List<String> options(String path) {
    if (kindOf(path) == ServerVoiceFieldKind.language) {
      final current = text(path)?.toLowerCase();
      return [
        ...kServerTranscriptionLanguages,
        if (current != null &&
            current != 'auto' &&
            !kServerTranscriptionLanguages.contains(current))
          current,
      ];
    }
    final offered = <String>[
      if (path == 'tts.edge.voice') ...kServerEdgeSpanishVoices,
      ...?kServerVoiceOptions[path],
    ];
    if (offered.isEmpty) offered.addAll(_published[path] ?? const []);
    final current = text(path);
    if (offered.isNotEmpty && current != null && !offered.contains(current)) {
      offered.insert(0, current);
    }
    return offered;
  }

  /// The config patch that sets [path] to [value].
  static Map<String, dynamic> patch(String path, Object value) {
    Object node = value;
    for (final segment in path.split('.').reversed) {
      node = <String, dynamic>{segment: node};
    }
    return node as Map<String, dynamic>;
  }

  /// The `stt` and `tts` values as a nested config, for the code that
  /// summarises a config response.
  Map<String, dynamic> asConfig() {
    final config = <String, dynamic>{};
    for (final entry in _values.entries) {
      if (!entry.key.startsWith('stt.') && !entry.key.startsWith('tts.')) {
        continue;
      }
      final segments = entry.key.split('.');
      var node = config;
      for (final segment in segments.take(segments.length - 1)) {
        node =
            node.putIfAbsent(segment, () => <String, dynamic>{})
                as Map<String, dynamic>;
      }
      node[segments.last] = entry.value;
    }
    return config;
  }
}

/// Remembers the last [ServerVoiceFields] of each connection and profile, so
/// voice settings paint at once with the last known values and refresh from
/// the server afterwards.
final class ServerVoiceFieldsStore {
  ServerVoiceFieldsStore(this._prefs);

  static const String _prefix = 'server_voice_fields_v1::';

  final SharedPreferences _prefs;

  ServerVoiceFields? read(String identity) =>
      ServerVoiceFields.decode(_prefs.getString('$_prefix$identity'));

  Future<void> write(String identity, ServerVoiceFields fields) =>
      _prefs.setString('$_prefix$identity', fields.encode());
}
