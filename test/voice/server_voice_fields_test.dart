import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/server_voice_config.dart';
import 'package:hermes_android/core/services/voice/server_voice_fields.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = <String, dynamic>{
    'model': {'default': 'gpt-5', 'api_key': 'sk-model-secret'},
    'tts': {
      'provider': 'openai',
      'openai': {
        'model': 'gpt-4o-mini-tts',
        'voice': 'marin',
        'api_key': 'sk-voice-secret',
        'base_url': 'https://voice.example.test/v1',
      },
      'elevenlabs': {'voice_id': 'custom-voice', 'api_key': 'el-secret'},
    },
    'stt': {
      'enabled': true,
      'echo_transcripts': false,
      'local': {'model': 'small', 'language': 'es'},
    },
    'voice': {
      'voice_chat_mode': 'chained',
      'max_recording_seconds': 120,
      'gpt_live': {
        'voice': 'cedar',
        'instructions': 'Habla despacio.',
        'api_key': 'sk-live-secret',
      },
    },
  };

  test('reads Desktop\'s voice fields and nothing else', () {
    final fields = ServerVoiceFields.read({'config': config}, const {});

    expect(fields.speech, 'openai');
    expect(fields.text('tts.openai.voice'), 'marin');
    expect(fields.text('tts.openai.model'), 'gpt-4o-mini-tts');
    expect(fields.flag(ServerVoiceFields.transcription), isTrue);
    expect(fields.flag(ServerVoiceFields.echoTranscripts), isFalse);
    expect(fields.flag(ServerVoiceFields.liveTranscription), isNull);
    expect(fields.number(ServerVoiceFields.maxRecordingSeconds), 120);
    expect(fields.text(ServerVoiceFields.liveVoice), 'cedar');
    expect(fields.text(ServerVoiceFields.livePersonality), 'Habla despacio.');

    // No key, token or address is among what was kept, in memory or in what
    // would be stored on the phone.
    final stored = fields.encode();
    for (final secret in const [
      'sk-model-secret',
      'sk-voice-secret',
      'el-secret',
      'sk-live-secret',
      'voice.example.test',
      'api_key',
      'base_url',
    ]) {
      expect(stored.contains(secret), isFalse, reason: secret);
    }
    for (final path in ServerVoiceFields.paths) {
      expect(path.contains('key'), isFalse, reason: path);
      expect(path.contains('token'), isFalse, reason: path);
      expect(path.contains('url'), isFalse, reason: path);
    }
  });

  test('accepts the config with or without its envelope', () {
    final bare = ServerVoiceFields.read(config, const {});
    expect(bare.text('tts.openai.voice'), 'marin');
  });

  test('shows only what the server reports', () {
    final fields = ServerVoiceFields.read(
      {
        'tts': {
          'provider': 'openai',
          'openai': {'voice': 'marin'},
        },
      },
      {
        'fields': {
          'voice.max_recording_seconds': {'type': 'number'},
        },
      },
    );

    // The voice has a value; the model has neither a value nor a schema
    // entry, so it is not a row.
    expect(fields.speechFields, ['tts.openai.voice']);
    expect(fields.reports('tts.openai.model'), isFalse);
    // Listed by the schema without a value: still a field of this server.
    expect(fields.reports(ServerVoiceFields.maxRecordingSeconds), isTrue);
    expect(fields.reports(ServerVoiceFields.liveVoice), isFalse);
    expect(fields.reports(ServerVoiceFields.transcriptionProvider), isFalse);
    expect(fields.transcriber, isNull);
    expect(fields.transcriptionFields, isEmpty);
  });

  test('each provider brings its own model and voice fields', () {
    ServerVoiceFields of(String provider, Map<String, dynamic> own) =>
        ServerVoiceFields.read({
          'tts': {'provider': provider, provider: own},
        }, const {});

    expect(of('edge', {'voice': 'es-ES-ElviraNeural'}).speechFields, [
      'tts.edge.voice',
    ]);
    expect(
      of('elevenlabs', {'model_id': 'eleven_v3', 'voice_id': 'x'}).speechFields,
      ['tts.elevenlabs.model_id', 'tts.elevenlabs.voice_id'],
    );
    expect(of('gemini', {'model': 'm', 'voice': 'Kore'}).speechFields, [
      'tts.gemini.model',
      'tts.gemini.voice',
    ]);
    // A provider Desktop does not know has no fields to show.
    expect(of('custom_lab', {'voice': 'x'}).speechFields, isEmpty);
  });

  test('transcription is local Whisper when the profile names no provider', () {
    final fields = ServerVoiceFields.read({
      'stt': {
        'local': {'model': 'small', 'language': ''},
      },
    }, const {});

    expect(fields.transcriber, 'local');
    expect(fields.transcriptionFields, [
      'stt.local.model',
      'stt.local.language',
    ]);
    expect(fields.transcriptionLanguagePath, 'stt.local.language');
    expect(fields.text('stt.local.language'), isNull);
  });

  test('offers Desktop\'s options, with the value in use among them', () {
    final fields = ServerVoiceFields.read({
      'tts': {
        'provider': 'openai',
        'openai': {'model': 'tts-custom', 'voice': 'marin'},
        'elevenlabs': {'voice_id': 'cloned-voice'},
        'edge': {'voice': 'es-ES-ElviraNeural'},
      },
      'stt': {
        'provider': 'local',
        'local': {'model': 'small', 'language': 'ca'},
      },
    }, const {});

    expect(
      fields.options(ServerVoiceFields.speechProvider),
      kServerVoiceOptions['tts.provider'],
    );
    expect(
      fields.options('tts.openai.voice'),
      kServerVoiceOptions['tts.openai.voice'],
    );
    // A value Desktop does not list stays selectable: it is what is in use.
    expect(fields.options('tts.openai.model'), [
      'tts-custom',
      'gpt-4o-mini-tts',
      'tts-1',
      'tts-1-hd',
    ]);
    // Desktop leaves this one to free text: nothing to pick from.
    expect(fields.options('tts.elevenlabs.voice_id'), isEmpty);
    // Spanish Edge voices first, then Desktop's.
    expect(fields.options('tts.edge.voice').take(4), kServerEdgeSpanishVoices);
    expect(
      fields.options('tts.edge.voice').skip(4),
      kServerVoiceOptions['tts.edge.voice'],
    );
    // Languages start with automatic, and keep one that is not in the list.
    expect(fields.options('stt.local.language'), [
      '',
      'es',
      'en',
      'fr',
      'de',
      'pt',
      'it',
      'ca',
    ]);
  });

  test('falls back to the options the server publishes when Desktop has '
      'none', () {
    final fields = ServerVoiceFields.read(
      {
        'tts': {
          'provider': 'deepinfra',
          'deepinfra': {'model': 'a'},
        },
      },
      {
        'schema': {
          'fields': {
            'tts.deepinfra.model': {
              'options': ['a', 'b'],
            },
            'tts.deepinfra.voice': {'type': 'string'},
          },
        },
      },
    );

    expect(fields.options('tts.deepinfra.model'), ['a', 'b']);
    expect(fields.options('tts.deepinfra.voice'), isEmpty);
    expect(fields.speechFields, ['tts.deepinfra.model', 'tts.deepinfra.voice']);
  });

  test('builds the config patch Desktop sends for one field', () {
    expect(ServerVoiceFields.patch('tts.openai.voice', 'nova'), {
      'tts': {
        'openai': {'voice': 'nova'},
      },
    });
    expect(ServerVoiceFields.patch('stt.enabled', false), {
      'stt': {'enabled': false},
    });
    expect(ServerVoiceFields.patch('voice.max_recording_seconds', 60), {
      'voice': {'max_recording_seconds': 60},
    });
  });

  test('survives being stored and restored', () async {
    final fields = ServerVoiceFields.read(
      {'config': config},
      {
        'fields': {
          'tts.openai.voice': {
            'options': ['marin', 'nova'],
          },
          'model.api_key': {'type': 'string'},
        },
      },
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = ServerVoiceFieldsStore(prefs);
    const identity = 'http://hermes-demo.local:9119::profile=work';

    expect(store.read(identity), isNull);
    await store.write(identity, fields);
    final restored = store.read(identity)!;

    expect(restored.encode(), fields.encode());
    expect(restored.text('tts.openai.voice'), 'marin');
    expect(restored.flag(ServerVoiceFields.transcription), isTrue);
    expect(restored.number(ServerVoiceFields.maxRecordingSeconds), 120);
    // Another profile has its own entry.
    expect(store.read('http://hermes-demo.local:9119'), isNull);
    // What was stored names the voice the same way a config response does.
    final summary = HermesServerVoiceSummary.fromConfig(restored.asConfig());
    expect(summary.ttsProvider, 'openai');
    expect(summary.ttsVoice, 'marin');
    expect(summary.sttLanguage, 'es');
  });

  test('ignores a stored value that is not its own', () {
    expect(ServerVoiceFields.decode(null), isNull);
    expect(ServerVoiceFields.decode('not json'), isNull);
    expect(ServerVoiceFields.decode('[1,2]'), isNull);
    final tampered = ServerVoiceFields.decode(
      '{"values":{"tts.openai.api_key":"sk-x","tts.provider":"edge"},'
      '"published":{}}',
    )!;
    expect(tampered.speech, 'edge');
    expect(tampered.encode().contains('sk-x'), isFalse);
  });
}
