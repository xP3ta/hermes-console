import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/conversation/full_duplex_barge_in_monitor.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice_session_configurator.dart';
import 'package:hermes_android/core/services/voice/hermes_speech_stream.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _TrackingMockClient extends MockClient {
  _TrackingMockClient(super.handler);

  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}

/// Spec 048 / US5 — sonda, consentimiento y ruta autoritativa
/// (contracts/native-voice.md).
class _Playback implements TtsAudioPlayback {
  final _completions = StreamController<void>.broadcast();
  final List<String> mimes = [];

  @override
  Stream<void> get onComplete => _completions.stream;

  @override
  Future<void> playBytes(Uint8List bytes, {required String mimeType}) async {
    mimes.add(mimeType);
    scheduleMicrotask(() => _completions.add(null));
  }

  @override
  Future<void> playFile(String path) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _StopFenceTts implements TtsEngine {
  final List<String> spoken = <String>[];
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

class _CapturedLocalStt implements SttEngine, CapturedWavSttEngine {
  Uint8List? captured;

  @override
  Future<bool> available() async => true;

  @override
  Stream<SttResult> listen({
    String localeId = 'es_ES',
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    bool continuous = false,
  }) {
    onCaptureReady?.call();
    return const Stream<SttResult>.empty();
  }

  @override
  bool get supportsPartials => false;

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<String> transcribeCapturedWav(Uint8List wavBytes) async {
    captured = Uint8List.fromList(wavBytes);
    return 'cállate';
  }
}

Uint8List _bargeInWav({
  int quietFramesBefore = 40,
  int speechFrames = 10,
  int quietFramesAfter = 42,
  int speechAmplitude = 700,
}) {
  const samplesPerFrame = 480;
  final amplitudes = <int>[
    ...List<int>.filled(quietFramesBefore, 80),
    ...List<int>.filled(speechFrames, speechAmplitude),
    ...List<int>.filled(quietFramesAfter, 0),
  ];
  final pcmBytes = amplitudes.length * samplesPerFrame * 2;
  final wav = Uint8List(44 + pcmBytes);
  final data = ByteData.sublistView(wav);

  void ascii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      wav[offset + index] = value.codeUnitAt(index);
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + pcmBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, pcmBytes, Endian.little);
  var offset = 44;
  for (final amplitude in amplitudes) {
    for (var sample = 0; sample < samplesPerFrame; sample++) {
      data.setInt16(
        offset,
        sample.isEven ? amplitude : -amplitude,
        Endian.little,
      );
      offset += 2;
    }
  }
  return wav;
}

Future<void> _grantNativeVoice(
  SharedPreferences preferences,
  String identity,
) async {
  await NativeVoiceConsentStore(
    preferences,
  ).write(identity, NativeVoiceConsent.accepted);
  await NativeVoiceModeStore(
    preferences,
  ).write(identity, NativeVoiceMode.server);
  await NativeVoiceCapabilityStore(preferences).write(
    identity,
    NativeVoiceCapability(
      transcribe: true,
      speak: true,
      checkedAtMs: DateTime.now().millisecondsSinceEpoch,
      conclusive: true,
    ),
  );
}

SavedConnection _nativeConnection(String id, String host) => SavedConnection(
  id: id,
  label: id,
  host: host,
  port: 8642,
  apiKey: String.fromCharCodes(const <int>[107]),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({'app_locale': 'es'}));

  group('sonda de capacidad', () {
    test('422/400 (validación del POST vacío) ⇒ capacidad presente', () async {
      final probed = <String>[];
      final cap = await probeNativeVoiceCapability(
        statusOf: (endpoint) async {
          probed.add(endpoint);
          return endpoint == 'speak' ? 400 : 422;
        },
      );
      expect(cap.ok, isTrue);
      expect(cap.conclusive, isTrue);
      expect(probed.toSet(), {'speak', 'transcribe'});
    });

    test(
      '404 o 405 (catch-all GET del frontend) ⇒ ausente y CONCLUYENTE',
      () async {
        final notFound = await probeNativeVoiceCapability(
          statusOf: (endpoint) async => 404,
        );
        expect(notFound.ok, isFalse);
        expect(notFound.conclusive, isTrue);

        final methodNotAllowed = await probeNativeVoiceCapability(
          statusOf: (endpoint) async => 405,
        );
        expect(methodNotAllowed.ok, isFalse);
        expect(methodNotAllowed.conclusive, isTrue);
      },
    );

    test('401/5xx/error de red ⇒ ausente pero NO concluyente', () async {
      // Un Dashboard con la sesión sin establecer devuelve 401: no dice nada
      // sobre si los endpoints existen y no debe cachearse 24 h como "no".
      final unauthorized = await probeNativeVoiceCapability(
        statusOf: (endpoint) async => 401,
      );
      expect(unauthorized.ok, isFalse);
      expect(unauthorized.conclusive, isFalse);

      final offline = await probeNativeVoiceCapability(
        statusOf: (endpoint) async => throw Exception('sin red'),
      );
      expect(offline.ok, isFalse);
      expect(offline.conclusive, isFalse);
    });

    test(
      'el caché ignora resultados no concluyentes y entradas antiguas',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final store = NativeVoiceCapabilityStore(prefs);
        const identity = 'http://hermes-demo.local:9119';

        final inconclusive = await probeNativeVoiceCapability(
          statusOf: (endpoint) async => 401,
        );
        await store.write(identity, inconclusive);
        expect(store.isFresh(store.read(identity)!), isFalse);

        // Entrada antigua sin el campo `conclusive` (formato previo) → re-sondeo.
        final legacy = NativeVoiceCapability.fromJson({
          'transcribe': false,
          'speak': false,
          'checked_at_ms': DateTime.now().millisecondsSinceEpoch,
        });
        expect(store.isFresh(legacy!), isFalse);

        // Entrada de la sonda v1 (GET, falsos 404 por el catch-all) → re-sondeo.
        final v1 = NativeVoiceCapability.fromJson({
          'transcribe': false,
          'speak': false,
          'checked_at_ms': DateTime.now().millisecondsSinceEpoch,
          'conclusive': true,
        });
        expect(store.isFresh(v1!), isFalse);

        final conclusive = await probeNativeVoiceCapability(
          statusOf: (endpoint) async => 422,
        );
        await store.write(identity, conclusive);
        expect(store.isFresh(store.read(identity)!), isTrue);
      },
    );
  });

  group('consentimiento por identidad', () {
    test('cada perfil nombrado conserva un scope independiente', () async {
      final prefs = await SharedPreferences.getInstance();
      const dashboard = 'http://hermes-demo.local:9119';
      final defaultScope = nativeVoicePreferenceIdentity(dashboard);
      final explicitDefault = nativeVoicePreferenceIdentity(
        dashboard,
        profile: 'default',
      );
      final workScope = nativeVoicePreferenceIdentity(
        dashboard,
        profile: 'trabajo principal',
      );
      final qaScope = nativeVoicePreferenceIdentity(dashboard, profile: 'qa');

      expect(defaultScope, dashboard);
      expect(explicitDefault, dashboard);
      expect(workScope, '$dashboard::profile=trabajo%20principal');
      expect(qaScope, '$dashboard::profile=qa');

      await NativeVoiceConsentStore(
        prefs,
      ).write(workScope, NativeVoiceConsent.accepted);
      await NativeVoiceModeStore(
        prefs,
      ).write(workScope, NativeVoiceMode.server);

      expect(
        NativeVoiceConsentStore(prefs).read(workScope),
        NativeVoiceConsent.accepted,
      );
      expect(
        NativeVoiceConsentStore(prefs).read(qaScope),
        NativeVoiceConsent.pending,
      );
      expect(
        NativeVoiceModeStore(prefs).read(workScope),
        NativeVoiceMode.server,
      );
      expect(NativeVoiceModeStore(prefs).read(qaScope), NativeVoiceMode.phone);
    });

    test('pendiente por defecto, persistente y por servidor', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = NativeVoiceConsentStore(prefs);
      const a = 'http://hermes-demo.local:9119';
      const b = 'http://otro:9119';

      expect(store.read(a), NativeVoiceConsent.pending);
      await store.write(a, NativeVoiceConsent.accepted);
      expect(store.read(a), NativeVoiceConsent.accepted);
      // Otra identidad (host/puerto distinto) no hereda el consentimiento.
      expect(store.read(b), NativeVoiceConsent.pending);

      await store.write(a, NativeVoiceConsent.rejected);
      expect(store.read(a), NativeVoiceConsent.rejected);
    });

    test(
      'un consentimiento legacy no selecciona servidor y el modo es por identidad',
      () async {
        final prefs = await SharedPreferences.getInstance();
        const a = 'http://hermes-demo.local:9119';
        const b = 'http://otro:9119';
        await NativeVoiceConsentStore(
          prefs,
        ).write(a, NativeVoiceConsent.accepted);

        final modes = NativeVoiceModeStore(prefs);
        expect(modes.read(a), NativeVoiceMode.phone);
        expect(modes.read(b), NativeVoiceMode.phone);

        await modes.write(a, NativeVoiceMode.server);
        expect(modes.read(a), NativeVoiceMode.server);
        expect(modes.read(b), NativeVoiceMode.phone);
        expect(
          NativeVoiceConsentStore(prefs).read(a),
          NativeVoiceConsent.accepted,
        );
      },
    );
  });

  group('configuración background consentida', () {
    test(
      'consentimiento legacy solo no habilita ni sondea el servidor',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final voice = VoiceService(prefs, SecureStorage());
        var requests = 0;
        final connection = SavedConnection(
          id: 'native-legacy',
          label: 'Hermes',
          host: 'hermes.test',
          port: 8642,
          apiKey: 'test-key',
        );

        expect(
          await configureAcceptedNativeVoiceSession(
            voice: voice,
            connection: connection,
            preferences: prefs,
            profile: '',
            dashboardFactory: (_) => DashboardClient(
              host: 'hermes.test',
              port: 9119,
              httpClientOverride: MockClient((_) async {
                requests++;
                return http.Response('{}', 500);
              }),
            ),
          ),
          isFalse,
        );
        expect(requests, 0);
        expect(voice.nativeVoiceActive, isFalse);
        await voice.dispose();
      },
    );

    test(
      'revocar consentimiento durante config impide instalar callbacks',
      () async {
        final prefs = await SharedPreferences.getInstance();
        const identity = 'http://hermes.test:9119';
        await NativeVoiceConsentStore(
          prefs,
        ).write(identity, NativeVoiceConsent.accepted);
        await NativeVoiceModeStore(
          prefs,
        ).write(identity, NativeVoiceMode.server);
        await NativeVoiceCapabilityStore(prefs).write(
          identity,
          NativeVoiceCapability(
            transcribe: true,
            speak: true,
            checkedAtMs: DateTime.now().millisecondsSinceEpoch,
            conclusive: true,
          ),
        );
        final schemaRequested = Completer<void>();
        final releaseSchema = Completer<void>();
        final client = _TrackingMockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/') {
            return http.Response(
              'window.__HERMES_SESSION_TOKEN__="test-session";',
              200,
            );
          }
          if (request.url.path == '/api/config/schema') {
            if (!schemaRequested.isCompleted) schemaRequested.complete();
            await releaseSchema.future;
            return http.Response('{}', 200);
          }
          if (request.url.path == '/api/config') {
            return http.Response('{}', 200);
          }
          return http.Response('{}', 500);
        });
        final voice = VoiceService(prefs, SecureStorage());
        final connection = SavedConnection(
          id: 'native-revoked-during-config',
          label: 'Hermes',
          host: 'hermes.test',
          port: 8642,
          apiKey: String.fromCharCodes(const <int>[107]),
        );
        addTearDown(() async {
          if (!releaseSchema.isCompleted) releaseSchema.complete();
          await voice.dispose();
        });

        final configuring = configureAcceptedNativeVoiceSession(
          voice: voice,
          connection: connection,
          preferences: prefs,
          profile: '',
          dashboardClient: DashboardClient(
            host: 'hermes.test',
            port: 9119,
            httpClientOverride: client,
          ),
        );
        await schemaRequested.future;
        await NativeVoiceConsentStore(
          prefs,
        ).write(identity, NativeVoiceConsent.rejected);
        releaseSchema.complete();

        expect(await configuring, isFalse);
        expect(voice.nativeVoiceActive, isFalse);
        expect(client.closed, isTrue);
      },
    );

    test('config A tardía no sustituye ni cierra la ruta B vigente', () async {
      final prefs = await SharedPreferences.getInstance();
      const identityA = 'http://voice-a.test:9119';
      const identityB = 'http://voice-b.test:9119';
      for (final identity in <String>[identityA, identityB]) {
        await NativeVoiceConsentStore(
          prefs,
        ).write(identity, NativeVoiceConsent.accepted);
        await NativeVoiceModeStore(
          prefs,
        ).write(identity, NativeVoiceMode.server);
        await NativeVoiceCapabilityStore(prefs).write(
          identity,
          NativeVoiceCapability(
            transcribe: true,
            speak: true,
            checkedAtMs: DateTime.now().millisecondsSinceEpoch,
            conclusive: true,
          ),
        );
      }
      final aSchemaRequested = Completer<void>();
      final releaseA = Completer<void>();
      final clientA = _TrackingMockClient((request) async {
        if (request.url.path == '/api/config/schema') {
          if (!aSchemaRequested.isCompleted) aSchemaRequested.complete();
          await releaseA.future;
        }
        return http.Response('{}', 200);
      });
      final clientB = _TrackingMockClient(
        (_) async => http.Response('{}', 200),
      );
      final voice = VoiceService(prefs, SecureStorage());
      SavedConnection connection(String id, String host) => SavedConnection(
        id: id,
        label: id,
        host: host,
        port: 8642,
        apiKey: String.fromCharCodes(const <int>[107]),
      );
      DashboardClient dashboard(String host, _TrackingMockClient client) =>
          DashboardClient(
            host: host,
            port: 9119,
            manualToken: String.fromCharCodes(const <int>[116]),
            httpClientOverride: client,
          );
      addTearDown(() async {
        if (!releaseA.isCompleted) releaseA.complete();
        await voice.dispose();
      });

      final configuringA = configureAcceptedNativeVoiceSession(
        voice: voice,
        connection: connection('native-a', 'voice-a.test'),
        preferences: prefs,
        profile: '',
        dashboardClient: dashboard('voice-a.test', clientA),
      );
      await aSchemaRequested.future;
      expect(
        await configureAcceptedNativeVoiceSession(
          voice: voice,
          connection: connection('native-b', 'voice-b.test'),
          preferences: prefs,
          profile: '',
          dashboardClient: dashboard('voice-b.test', clientB),
        ),
        isTrue,
      );
      expect(clientB.closed, isFalse);

      releaseA.complete();

      expect(await configuringA, isFalse);
      expect(clientA.closed, isTrue);
      expect(clientB.closed, isFalse);
      expect(voice.nativeVoiceActive, isTrue);
    });

    test(
      'una instancia dispuesta rechaza callbacks nativos directos',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final voice = VoiceService(prefs, SecureStorage());
        await voice.dispose();
        var releases = 0;

        expect(
          voice.enableNativeVoice(
            speak: (_) async => <String, dynamic>{'ok': true},
            transcribe: (_, _) async => <String, dynamic>{'ok': true},
            onDispose: () => releases++,
          ),
          isFalse,
        );
        expect(voice.nativeVoiceActive, isFalse);
        expect(
          releases,
          0,
          reason: 'el caller conserva el recurso no transferido',
        );
      },
    );

    test(
      'dispose durante config invalida callbacks y cierra su cliente',
      () async {
        final prefs = await SharedPreferences.getInstance();
        const identity = 'http://voice-dispose.test:9119';
        await _grantNativeVoice(prefs, identity);
        final schemaRequested = Completer<void>();
        final releaseSchema = Completer<void>();
        final client = _TrackingMockClient((request) async {
          if (request.url.path == '/api/config/schema') {
            if (!schemaRequested.isCompleted) schemaRequested.complete();
            await releaseSchema.future;
          }
          return http.Response('{}', 200);
        });
        final voice = VoiceService(prefs, SecureStorage());
        final configuring = configureAcceptedNativeVoiceSession(
          voice: voice,
          connection: _nativeConnection('native-dispose', 'voice-dispose.test'),
          preferences: prefs,
          profile: '',
          dashboardClient: DashboardClient(
            host: 'voice-dispose.test',
            port: 9119,
            manualToken: String.fromCharCodes(const <int>[116]),
            httpClientOverride: client,
          ),
        );
        await schemaRequested.future;

        await voice.dispose();
        releaseSchema.complete();

        expect(await configuring, isFalse);
        expect(voice.nativeVoiceActive, isFalse);
        expect(client.closed, isTrue);
        await expectLater(
          voice.transcribeNativeWav(Uint8List.fromList(<int>[1])),
          throwsStateError,
        );
      },
    );

    test('cambio de perfil invalida configuración todavía pendiente', () async {
      final prefs = await SharedPreferences.getInstance();
      const identity = 'http://voice-profile.test:9119::profile=work';
      await _grantNativeVoice(prefs, identity);
      final schemaRequested = Completer<void>();
      final releaseSchema = Completer<void>();
      final client = _TrackingMockClient((request) async {
        if (request.url.path == '/api/config/schema') {
          if (!schemaRequested.isCompleted) schemaRequested.complete();
          await releaseSchema.future;
        }
        return http.Response('{}', 200);
      });
      final voice = VoiceService(prefs, SecureStorage());
      var profileIsCurrent = true;
      addTearDown(() async {
        if (!releaseSchema.isCompleted) releaseSchema.complete();
        await voice.dispose();
      });

      final configuring = configureAcceptedNativeVoiceSession(
        voice: voice,
        connection: _nativeConnection('native-profile', 'voice-profile.test'),
        preferences: prefs,
        profile: 'work',
        isStillCurrent: () => profileIsCurrent,
        dashboardClient: DashboardClient(
          host: 'voice-profile.test',
          port: 9119,
          manualToken: String.fromCharCodes(const <int>[116]),
          httpClientOverride: client,
        ),
      );
      await schemaRequested.future;
      profileIsCurrent = false;
      releaseSchema.complete();

      expect(await configuring, isFalse);
      expect(voice.nativeVoiceActive, isFalse);
      expect(client.closed, isTrue);
    });

    test('una sesión reutiliza su DashboardClient y evita relogins', () async {
      final prefs = await SharedPreferences.getInstance();
      const identity = 'http://hermes.test:9119';
      await NativeVoiceConsentStore(
        prefs,
      ).write(identity, NativeVoiceConsent.accepted);
      await NativeVoiceModeStore(prefs).write(identity, NativeVoiceMode.server);
      await NativeVoiceCapabilityStore(prefs).write(
        identity,
        NativeVoiceCapability(
          transcribe: true,
          speak: true,
          checkedAtMs: DateTime.now().millisecondsSinceEpoch,
          conclusive: true,
        ),
      );
      final voice = VoiceService(prefs, SecureStorage());
      final playback = _Playback();
      voice.debugNativePlaybackFactory = () => playback;
      var clients = 0;
      final connection = SavedConnection(
        id: 'native-background',
        label: 'Hermes',
        host: 'hermes.test',
        port: 8642,
        apiKey: 'test-key',
      );

      DashboardClient dashboardFactory(SavedConnection _) {
        clients++;
        return DashboardClient(
          host: 'hermes.test',
          port: 9119,
          httpClientOverride: MockClient((request) async {
            if (request.method == 'GET' && request.url.path == '/') {
              return http.Response(
                'window.__HERMES_SESSION_TOKEN__="test-session";',
                200,
              );
            }
            if (request.method == 'POST') {
              return http.Response(
                jsonEncode({
                  'ok': true,
                  'data_url': 'data:audio/mpeg;base64,${base64Encode([1, 2])}',
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('{}', 500);
          }),
        );
      }

      expect(
        await configureAcceptedNativeVoiceSession(
          voice: voice,
          connection: connection,
          preferences: prefs,
          profile: '',
          dashboardFactory: dashboardFactory,
        ),
        isTrue,
      );
      expect(clients, 1, reason: 'la sesión autentica una sola vez');

      await voice.enqueueSpeech('Uno');
      await voice.waitSpeechDone();
      await voice.enqueueSpeech('Dos');
      await voice.waitSpeechDone();
      expect(clients, 1, reason: 'STT y TTS comparten cookies rotadas');

      await voice.dispose();
    });
  });

  group('ruta estricta de sesión', () {
    test('los fallos se cuentan sin cambiar la selección de servidor', () {
      final session = NativeVoiceSession();
      expect(session.active, isTrue);
      session.noteFailure();
      expect(session.active, isTrue);
      session.noteSuccess();
      session.noteFailure();
      session.noteFailure();
      expect(session.active, isTrue);
      expect(session.consecutiveFailures, 2);
    });

    test(
      'En este móvil fuerza STT y TTS locales sin borrar ajustes remotos',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final voice = VoiceService(
          prefs,
          SecureStorage(),
          initialSettings: const VoiceSettings(
            sttEngine: SttEngineKind.server,
            ttsEngine: TtsEngineKind.elevenlabs,
          ),
        );

        expect(voice.effectiveConversationSttEngine, SttEngineKind.server);
        expect(voice.effectiveConversationTtsEngine, TtsEngineKind.elevenlabs);

        voice.enableOnDeviceVoice();
        expect(voice.onDeviceVoiceActive, isTrue);
        expect(voice.effectiveConversationSttEngine, SttEngineKind.sherpaLive);
        expect(voice.effectiveConversationTtsEngine, TtsEngineKind.onnx);

        voice.disableNativeVoice();
        expect(voice.onDeviceVoiceActive, isFalse);
        expect(voice.effectiveConversationSttEngine, SttEngineKind.server);
        expect(voice.effectiveConversationTtsEngine, TtsEngineKind.elevenlabs);
        await voice.dispose();
      },
    );

    test(
      'la ruta servidor queda congelada hasta Exit y conserva sus callbacks',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final voice = VoiceService(prefs, SecureStorage());
        final playback = _Playback();
        voice.debugNativePlaybackFactory = () => playback;
        final original = <String>[];
        final replacement = <String>[];

        expect(
          voice.enableNativeVoice(
            speak: (text) async {
              original.add(text);
              return {
                'ok': true,
                'data_url': 'data:audio/mpeg;base64,${base64Encode([1, 2])}',
              };
            },
            transcribe: (dataUrl, mime) async => {
              'ok': true,
              'transcript': 'original',
            },
          ),
          isTrue,
        );
        voice.setVoiceConversationActive(true);

        expect(voice.activeVoiceRoute?.kind, VoiceRouteKind.server);
        final frozenRoute = voice.activeVoiceRoute;
        voice.setVoiceConversationAudioLeaseActive(false);
        expect(
          voice.activeVoiceRoute,
          same(frozenRoute),
          reason: 'Pause libera audio, no la identidad/ruta de conversación',
        );
        voice.setVoiceConversationAudioLeaseActive(true);
        expect(voice.activeVoiceRoute, same(frozenRoute));
        expect(voice.enableOnDeviceVoice(), isFalse);
        expect(voice.disableNativeVoice(), isFalse);
        expect(
          voice.enableNativeVoice(
            speak: (text) async {
              replacement.add(text);
              return {
                'ok': true,
                'data_url': 'data:audio/mpeg;base64,${base64Encode([3, 4])}',
              };
            },
            transcribe: (dataUrl, mime) async => {
              'ok': true,
              'transcript': 'replacement',
            },
          ),
          isFalse,
        );

        await voice.enqueueSpeech('Ruta propietaria.');
        await voice.waitSpeechDone();
        expect(original, ['Ruta propietaria.']);
        expect(replacement, isEmpty);

        voice.setVoiceConversationActive(false);
        expect(voice.disableNativeVoice(), isTrue);
        expect(voice.enableOnDeviceVoice(), isTrue);
        await voice.dispose();
      },
    );

    test(
      'cambiar ajustes durante Voz aplica los motores solo tras Exit',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final voice = VoiceService(
          prefs,
          SecureStorage(),
          initialSettings: const VoiceSettings(
            sttEngine: SttEngineKind.whisper,
            ttsEngine: TtsEngineKind.device,
          ),
        );
        final engine = _StopFenceTts();
        voice.debugTtsFactory = () => engine;
        voice.enableOnDeviceVoice();
        voice.setVoiceConversationActive(true);

        expect(voice.activeVoiceRoute?.kind, VoiceRouteKind.phone);
        expect(voice.effectiveConversationSttEngine, SttEngineKind.whisper);
        expect(voice.effectiveConversationTtsEngine, TtsEngineKind.device);
        await voice.enqueueSpeech('Primera.');
        await voice.waitSpeechDone();

        await voice.saveSettings(
          const VoiceSettings(
            sttEngine: SttEngineKind.sherpaLive,
            ttsEngine: TtsEngineKind.onnx,
          ),
        );
        expect(voice.settings.sttEngine, SttEngineKind.sherpaLive);
        expect(voice.settings.ttsEngine, TtsEngineKind.onnx);
        expect(voice.effectiveConversationSttEngine, SttEngineKind.whisper);
        expect(voice.effectiveConversationTtsEngine, TtsEngineKind.device);
        expect(engine.disposeCalls, 0);

        await voice.enqueueSpeech('Segunda.');
        await voice.waitSpeechDone();
        expect(engine.spoken, ['Primera.', 'Segunda.']);
        expect(engine.disposeCalls, 0);

        voice.setVoiceConversationActive(false);
        expect(voice.effectiveConversationSttEngine, SttEngineKind.sherpaLive);
        expect(voice.effectiveConversationTtsEngine, TtsEngineKind.onnx);
        await voice.disposeTtsForVoiceExit();
        expect(engine.disposeCalls, 1);
        await voice.dispose();
      },
    );
  });

  group('enrutado en VoiceService', () {
    test('Stop durante setup TTS no deja que la locución resucite', () async {
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      final buildEntered = Completer<void>();
      final releaseBuild = Completer<TtsEngine>();
      final engine = _StopFenceTts();
      voice.debugTtsBuilder = () {
        if (!buildEntered.isCompleted) buildEntered.complete();
        return releaseBuild.future;
      };

      await voice.enqueueSpeech('No debe sonar.');
      await buildEntered.future;
      await voice.stopSpeaking();
      await voice.enqueueSpeech('Sí debe sonar.');
      releaseBuild.complete(engine);
      await voice.waitSpeechDone();

      expect(engine.spoken, ['Sí debe sonar.']);
      await voice.dispose();
    });

    test('salir durante setup descarta y libera el motor tardío', () async {
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      final buildEntered = Completer<void>();
      final releaseBuild = Completer<TtsEngine>();
      final engine = _StopFenceTts();
      voice.debugTtsBuilder = () {
        if (!buildEntered.isCompleted) buildEntered.complete();
        return releaseBuild.future;
      };

      await voice.enqueueSpeech('No debe sobrevivir.');
      await buildEntered.future;
      var exitCompleted = false;
      final exit = voice.disposeTtsForVoiceExit().whenComplete(() {
        exitCompleted = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        exitCompleted,
        isFalse,
        reason: 'Exit no puede declarar liberado un builder que sigue vivo',
      );
      releaseBuild.complete(engine);
      await exit;
      await voice.waitSpeechDone();

      expect(engine.spoken, isEmpty);
      expect(engine.disposeCalls, 1);
      await voice.dispose();
    });

    test(
      'cambiar de ruta durante setup no mezcla la locución antigua',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final voice = VoiceService(prefs, SecureStorage());
        final buildEntered = Completer<void>();
        final releaseBuild = Completer<TtsEngine>();
        final oldEngine = _StopFenceTts();
        final serverEngine = _StopFenceTts();
        voice.debugTtsBuilder = () {
          if (!buildEntered.isCompleted) buildEntered.complete();
          return releaseBuild.future;
        };

        await voice.enqueueSpeech('Ruta antigua.');
        await buildEntered.future;
        voice.enableNativeVoice(
          speak: (text) async => {'ok': true},
          transcribe: (dataUrl, mime) async => {'ok': true, 'transcript': 'x'},
        );
        voice.debugTtsBuilder = null;
        voice.debugTtsFactory = () => serverEngine;
        await voice.enqueueSpeech('Ruta nueva.');
        releaseBuild.complete(oldEngine);
        await voice.waitSpeechDone();

        expect(oldEngine.spoken, isEmpty);
        expect(oldEngine.disposeCalls, 1);
        expect(serverEngine.spoken, ['Ruta nueva.']);
        await voice.dispose();
      },
    );

    test(
      'modo móvil mantiene el barge-in en Sherpa sin usar Dashboard',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final voice = VoiceService(prefs, SecureStorage());
        final stt = _CapturedLocalStt();
        voice.debugSttFactory = () => stt;
        final source = VoiceServiceFullDuplexCaptureSource(voice);
        final wav = _bargeInWav();

        expect(voice.nativeVoiceActive, isFalse);
        expect(source.transcriptionAvailable, isTrue);
        expect(await source.transcribe(wav), 'cállate');
        expect(stt.captured, wav);

        await voice.dispose();
      },
    );

    test(
      'barge-in vacío con energía respeta el silencio y sube el WAV una vez',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final voice = VoiceService(prefs, SecureStorage());
        final requests = <Uint8List>[];
        final dataUrls = <String>[];
        final mimeTypes = <String>[];
        voice.enableNativeVoice(
          speak: (text) async => {'ok': true},
          transcribe: (dataUrl, mime) async {
            dataUrls.add(dataUrl);
            mimeTypes.add(mime);
            requests.add(
              base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1)),
            );
            return {'ok': true, 'transcript': ''};
          },
        );

        final original = _bargeInWav();
        expect(await voice.transcribeNativeWav(original), isEmpty);

        expect(requests, hasLength(1));
        expect(requests.single, original);
        expect(dataUrls.single, startsWith('data:audio/wav;base64,'));
        expect(mimeTypes.single, 'audio/wav');
        expect(voice.nativeVoiceActive, isTrue);
        await voice.dispose();
      },
    );

    test('barge-in remoto falla sin copiar detail del servidor', () async {
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      voice.enableNativeVoice(
        speak: (text) async => {'ok': true},
        transcribe: (dataUrl, mime) async => {
          'ok': false,
          'detail': 'PRIVATE_NATIVE_STT /home/server/audio.wav',
        },
      );
      addTearDown(voice.dispose);

      await expectLater(
        voice.transcribeNativeWav(_bargeInWav()),
        throwsA(
          predicate<Object>(
            (error) =>
                !error.toString().contains('PRIVATE_NATIVE_STT') &&
                !error.toString().contains('/home/server'),
          ),
        ),
      );
    });

    test('barge-in entendido no duplica la petición STT', () async {
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      var requests = 0;
      voice.enableNativeVoice(
        speak: (text) async => {'ok': true},
        transcribe: (dataUrl, mime) async {
          requests++;
          return {'ok': true, 'transcript': 'continúa'};
        },
      );

      expect(await voice.transcribeNativeWav(_bargeInWav()), 'continúa');
      expect(requests, 1);
      await voice.dispose();
    });

    test('barge-in sin energía no fuerza un segundo STT', () async {
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      var requests = 0;
      voice.enableNativeVoice(
        speak: (text) async => {'ok': true},
        transcribe: (dataUrl, mime) async {
          requests++;
          return {'ok': true, 'transcript': ''};
        },
      );

      final quiet = _bargeInWav(speechAmplitude: 120);
      expect(await voice.transcribeNativeWav(quiet), isEmpty);
      expect(requests, 1);
      await voice.dispose();
    });

    test('reemplazar o apagar voz de servidor libera su sesión', () async {
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      var releases = 0;

      void enable() => voice.enableNativeVoice(
        speak: (text) async => {'ok': true},
        transcribe: (dataUrl, mime) async => {'ok': true},
        onDispose: () => releases++,
      );

      enable();
      expect(releases, 0);
      enable();
      expect(releases, 1);
      voice.disableNativeVoice();
      expect(releases, 2);
      voice.disableNativeVoice();
      expect(releases, 2);

      await voice.dispose();
    });

    test('activo ⇒ la respuesta se sintetiza en el servidor', () async {
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      final playback = _Playback();
      voice.debugNativePlaybackFactory = () => playback;
      final spoken = <String>[];
      voice.enableNativeVoice(
        speak: (text) async {
          spoken.add(text);
          return {
            'ok': true,
            'data_url': 'data:audio/mpeg;base64,${base64Encode([1, 2])}',
          };
        },
        transcribe: (dataUrl, mime) async => {'ok': true, 'transcript': 'x'},
      );

      expect(voice.nativeVoiceActive, isTrue);
      expect(
        voice.serializesHeavyLocalVoiceModels,
        isFalse,
        reason: 'sin modelos locales no hay nada que serializar',
      );

      await voice.enqueueSpeech('Hola nativo.');
      await voice.waitSpeechDone();
      expect(spoken, ['Hola nativo.']);
      expect(playback.mimes, ['audio/mpeg']);
    });

    test('los fallos del servidor no cambian a motores locales', () async {
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      voice.debugNativePlaybackFactory = _Playback.new;
      var calls = 0;
      voice.enableNativeVoice(
        speak: (text) async {
          calls++;
          throw Exception('TTS del servidor caído');
        },
        transcribe: (dataUrl, mime) async => {'ok': true, 'transcript': 'x'},
      );

      // Cada locución conserva la ruta elegida y expone el fallo al controlador.
      await voice.enqueueSpeech('Uno.');
      await expectLater(
        voice.waitSpeechDone(),
        throwsA(isA<VoiceRouteUnavailableException>()),
      );
      await voice.enqueueSpeech('Dos.');
      await expectLater(
        voice.waitSpeechDone(),
        throwsA(isA<VoiceRouteUnavailableException>()),
      );

      expect(calls, 2);
      expect(voice.nativeVoiceActive, isTrue);

      // La tercera vuelve a intentar el servidor; nunca cambia a ONNX/sistema.
      await voice.enqueueSpeech('Tres.');
      await expectLater(
        voice.waitSpeechDone(),
        throwsA(isA<VoiceRouteUnavailableException>()),
      );
      expect(calls, 3);
      expect(voice.nativeVoiceActive, isTrue);
    });

    test(
      'solo un upgrade ausente desactiva streaming durante la sesión',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final voice = VoiceService(prefs, SecureStorage());
        var missingAttempts = 0;
        voice.enableNativeVoice(
          speak: (text) async => {'ok': false},
          transcribe: (dataUrl, mime) async => {'ok': false},
          speechStream: () async {
            missingAttempts++;
            throw HermesSpeechStreamOpenException(
              StateError('HTTP status code: 404'),
            );
          },
        );

        expect(await voice.startNativeSpeechStream(), isNull);
        expect(voice.nativeSpeechStreamingAvailable, isFalse);
        expect(await voice.startNativeSpeechStream(), isNull);
        expect(missingAttempts, 1);

        var transientAttempts = 0;
        voice.enableNativeVoice(
          speak: (text) async => {'ok': false},
          transcribe: (dataUrl, mime) async => {'ok': false},
          speechStream: () async {
            transientAttempts++;
            throw StateError('Network unreachable');
          },
        );

        expect(await voice.startNativeSpeechStream(), isNull);
        expect(voice.nativeSpeechStreamingAvailable, isTrue);
        expect(await voice.startNativeSpeechStream(), isNull);
        expect(transientAttempts, 2);
      },
    );

    test('disableNativeVoice vuelve a los motores locales', () async {
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      voice.enableNativeVoice(
        speak: (text) async => {'ok': true},
        transcribe: (dataUrl, mime) async => {'ok': true},
      );
      expect(voice.nativeVoiceActive, isTrue);

      voice.disableNativeVoice();
      expect(voice.nativeVoiceActive, isFalse);
    });

    test(
      'dictado Hermes sondea solo transcribe y no cambia Modo Voz',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await const VoiceSettings(
          sttEngine: SttEngineKind.hermesServer,
        ).save(prefs);
        final voice = VoiceService(prefs, SecureStorage());
        addTearDown(voice.dispose);
        final paths = <String>[];
        final dashboard = DashboardClient(
          host: '192.168.1.20',
          port: 9119,
          manualToken: 'test-token',
          httpClientOverride: MockClient((request) async {
            paths.add(request.url.path);
            return http.Response('{}', 400);
          }),
        );
        final identity = nativeVoicePreferenceIdentity(
          dashboard.baseUrl,
          profile: 'perfil-es',
        );
        await NativeVoiceConsentStore(
          prefs,
        ).write(identity, NativeVoiceConsent.accepted);
        final connection = SavedConnection(
          id: 'dictation-hermes',
          label: 'Hermes',
          host: '192.168.1.20',
          port: 8642,
          apiKey: 'test-key',
        );
        final owner = Object();
        final preparation = voice.beginHermesServerDictationPreparation(
          owner: owner,
        );

        final configured = await configureHermesServerDictation(
          voice: voice,
          owner: owner,
          preparation: preparation,
          connection: connection,
          preferences: prefs,
          profile: 'perfil-es',
          dashboardClient: dashboard,
        );

        expect(voice.settings.sttEngine, SttEngineKind.hermesServer);
        expect(
          NativeVoiceConsentStore(prefs).read(identity),
          NativeVoiceConsent.accepted,
        );
        expect(paths, ['/api/audio/transcribe']);
        expect(configured, HermesServerDictationConfigurationResult.configured);
        expect(voice.hermesServerDictationReady, isTrue);
        expect(voice.nativeVoiceActive, isFalse);
        expect(
          NativeVoiceModeStore(prefs).read(identity),
          NativeVoiceMode.phone,
        );
        voice.disableHermesServerDictation(owner: owner);
      },
    );

    test(
      'dictado Hermes sin consentimiento falla cerrado y no sondea',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await const VoiceSettings(
          sttEngine: SttEngineKind.hermesServer,
        ).save(prefs);
        final voice = VoiceService(prefs, SecureStorage());
        addTearDown(voice.dispose);
        var requests = 0;
        final dashboard = DashboardClient(
          host: 'otro.test',
          port: 9119,
          httpClientOverride: MockClient((request) async {
            requests++;
            return http.Response('{}', 400);
          }),
        );
        final owner = Object();
        final preparation = voice.beginHermesServerDictationPreparation(
          owner: owner,
        );

        final configured = await configureHermesServerDictation(
          voice: voice,
          owner: owner,
          preparation: preparation,
          connection: SavedConnection(
            id: 'dictation-no-consent',
            label: 'Hermes',
            host: 'otro.test',
            port: 8642,
            apiKey: 'test-key',
          ),
          preferences: prefs,
          profile: 'default',
          dashboardClient: dashboard,
        );

        expect(
          configured,
          HermesServerDictationConfigurationResult.unavailable,
        );
        expect(requests, 0);
        expect(voice.hermesServerDictationReady, isFalse);
      },
    );

    test('un probe tardío no sustituye el binding vigente', () async {
      final prefs = await SharedPreferences.getInstance();
      await const VoiceSettings(
        sttEngine: SttEngineKind.hermesServer,
      ).save(prefs);
      final voice = VoiceService(prefs, SecureStorage());
      addTearDown(voice.dispose);
      final slowProbe = Completer<http.Response>();
      final slowProbeStarted = Completer<void>();
      final clientA = _TrackingMockClient((request) async {
        if (!slowProbeStarted.isCompleted) slowProbeStarted.complete();
        return slowProbe.future;
      });
      final clientB = _TrackingMockClient(
        (request) async => http.Response('{}', 400),
      );
      final dashboardA = DashboardClient(
        host: 'perfil-a.test',
        port: 9119,
        manualToken: 'test-token',
        httpClientOverride: clientA,
      );
      final dashboardB = DashboardClient(
        host: 'perfil-b.test',
        port: 9119,
        manualToken: 'test-token',
        httpClientOverride: clientB,
      );
      await NativeVoiceConsentStore(prefs).write(
        nativeVoicePreferenceIdentity(dashboardA.baseUrl, profile: 'perfil-a'),
        NativeVoiceConsent.accepted,
      );
      await NativeVoiceConsentStore(prefs).write(
        nativeVoicePreferenceIdentity(dashboardB.baseUrl, profile: 'perfil-b'),
        NativeVoiceConsent.accepted,
      );
      final ownerA = Object();
      final ownerB = Object();
      final preparationA = voice.beginHermesServerDictationPreparation(
        owner: ownerA,
      );
      final configuringA = configureHermesServerDictation(
        voice: voice,
        owner: ownerA,
        preparation: preparationA,
        connection: SavedConnection(
          id: 'a',
          label: 'A',
          host: 'perfil-a.test',
          port: 8642,
          apiKey: 'test-key',
        ),
        preferences: prefs,
        profile: 'perfil-a',
        dashboardClient: dashboardA,
      );
      await slowProbeStarted.future;

      final preparationB = voice.beginHermesServerDictationPreparation(
        owner: ownerB,
      );
      final configuredB = await configureHermesServerDictation(
        voice: voice,
        owner: ownerB,
        preparation: preparationB,
        connection: SavedConnection(
          id: 'b',
          label: 'B',
          host: 'perfil-b.test',
          port: 8642,
          apiKey: 'test-key',
        ),
        preferences: prefs,
        profile: 'perfil-b',
        dashboardClient: dashboardB,
      );
      expect(configuredB, HermesServerDictationConfigurationResult.configured);
      expect(clientB.closed, isFalse);

      slowProbe.complete(http.Response('{}', 404));
      expect(
        await configuringA,
        HermesServerDictationConfigurationResult.superseded,
      );
      expect(clientA.closed, isTrue);
      expect(clientB.closed, isFalse);
      expect(voice.hermesServerDictationReady, isTrue);

      expect(voice.disableHermesServerDictation(owner: ownerA), isFalse);
      expect(voice.hermesServerDictationReady, isTrue);
      expect(clientB.closed, isFalse);
      expect(voice.disableHermesServerDictation(owner: ownerB), isTrue);
      expect(clientB.closed, isTrue);
    });

    test(
      'dos probes del mismo owner silencian el resultado obsoleto',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await const VoiceSettings(
          sttEngine: SttEngineKind.hermesServer,
        ).save(prefs);
        final voice = VoiceService(prefs, SecureStorage());
        addTearDown(voice.dispose);
        final probeA = Completer<http.Response>();
        final probeB = Completer<http.Response>();
        final startedA = Completer<void>();
        final startedB = Completer<void>();
        final clientA = _TrackingMockClient((request) async {
          if (!startedA.isCompleted) startedA.complete();
          return probeA.future;
        });
        final clientB = _TrackingMockClient((request) async {
          if (!startedB.isCompleted) startedB.complete();
          return probeB.future;
        });
        final dashboardA = DashboardClient(
          host: 'same-owner-a.test',
          port: 9119,
          manualToken: 'test-token',
          httpClientOverride: clientA,
        );
        final dashboardB = DashboardClient(
          host: 'same-owner-b.test',
          port: 9119,
          manualToken: 'test-token',
          httpClientOverride: clientB,
        );
        await NativeVoiceConsentStore(prefs).write(
          nativeVoicePreferenceIdentity(
            dashboardA.baseUrl,
            profile: 'perfil-a',
          ),
          NativeVoiceConsent.accepted,
        );
        await NativeVoiceConsentStore(prefs).write(
          nativeVoicePreferenceIdentity(
            dashboardB.baseUrl,
            profile: 'perfil-b',
          ),
          NativeVoiceConsent.accepted,
        );
        final owner = Object();
        final preparationA = voice.beginHermesServerDictationPreparation(
          owner: owner,
        );
        final configuringA = configureHermesServerDictation(
          voice: voice,
          owner: owner,
          preparation: preparationA,
          connection: SavedConnection(
            id: 'same-a',
            label: 'Same A',
            host: 'same-owner-a.test',
            port: 8642,
            apiKey: 'test-key',
          ),
          preferences: prefs,
          profile: 'perfil-a',
          dashboardClient: dashboardA,
        );
        await startedA.future;

        final preparationB = voice.beginHermesServerDictationPreparation(
          owner: owner,
        );
        final configuringB = configureHermesServerDictation(
          voice: voice,
          owner: owner,
          preparation: preparationB,
          connection: SavedConnection(
            id: 'same-b',
            label: 'Same B',
            host: 'same-owner-b.test',
            port: 8642,
            apiKey: 'test-key',
          ),
          preferences: prefs,
          profile: 'perfil-b',
          dashboardClient: dashboardB,
        );
        await startedB.future;

        probeA.complete(http.Response('{}', 400));
        expect(
          await configuringA,
          HermesServerDictationConfigurationResult.superseded,
        );
        expect(clientA.closed, isTrue);
        expect(clientB.closed, isFalse);
        expect(voice.hermesServerDictationReady, isFalse);

        probeB.complete(http.Response('{}', 400));
        expect(
          await configuringB,
          HermesServerDictationConfigurationResult.configured,
        );
        expect(clientB.closed, isFalse);
        expect(voice.hermesServerDictationReady, isTrue);
      },
    );

    test(
      'una reconfiguración fallida no conserva el perfil anterior',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await const VoiceSettings(
          sttEngine: SttEngineKind.hermesServer,
        ).save(prefs);
        final voice = VoiceService(prefs, SecureStorage());
        addTearDown(voice.dispose);
        final oldClient = _TrackingMockClient(
          (request) async => http.Response('{}', 400),
        );
        final failedClient = _TrackingMockClient(
          (request) async => http.Response('{}', 404),
        );
        final oldDashboard = DashboardClient(
          host: 'old-profile.test',
          port: 9119,
          manualToken: 'test-token',
          httpClientOverride: oldClient,
        );
        final failedDashboard = DashboardClient(
          host: 'new-profile.test',
          port: 9119,
          manualToken: 'test-token',
          httpClientOverride: failedClient,
        );
        await NativeVoiceConsentStore(prefs).write(
          nativeVoicePreferenceIdentity(oldDashboard.baseUrl, profile: 'old'),
          NativeVoiceConsent.accepted,
        );
        await NativeVoiceConsentStore(prefs).write(
          nativeVoicePreferenceIdentity(
            failedDashboard.baseUrl,
            profile: 'new',
          ),
          NativeVoiceConsent.accepted,
        );
        final owner = Object();
        final oldPreparation = voice.beginHermesServerDictationPreparation(
          owner: owner,
        );
        expect(
          await configureHermesServerDictation(
            voice: voice,
            owner: owner,
            preparation: oldPreparation,
            connection: SavedConnection(
              id: 'old-profile',
              label: 'Old profile',
              host: 'old-profile.test',
              port: 8642,
              apiKey: 'test-key',
            ),
            preferences: prefs,
            profile: 'old',
            dashboardClient: oldDashboard,
          ),
          HermesServerDictationConfigurationResult.configured,
        );
        expect(voice.hermesServerDictationReady, isTrue);
        expect(oldClient.closed, isFalse);

        final failedPreparation = voice.beginHermesServerDictationPreparation(
          owner: owner,
        );
        expect(oldClient.closed, isTrue);
        expect(voice.hermesServerDictationReady, isFalse);
        expect(
          await configureHermesServerDictation(
            voice: voice,
            owner: owner,
            preparation: failedPreparation,
            connection: SavedConnection(
              id: 'new-profile',
              label: 'New profile',
              host: 'new-profile.test',
              port: 8642,
              apiKey: 'test-key',
            ),
            preferences: prefs,
            profile: 'new',
            dashboardClient: failedDashboard,
          ),
          HermesServerDictationConfigurationResult.unavailable,
        );
        expect(failedClient.closed, isTrue);
        expect(voice.hermesServerDictationReady, isFalse);
      },
    );

    test('liberar owner durante el probe impide instalarlo', () async {
      final prefs = await SharedPreferences.getInstance();
      await const VoiceSettings(
        sttEngine: SttEngineKind.hermesServer,
      ).save(prefs);
      final voice = VoiceService(prefs, SecureStorage());
      addTearDown(voice.dispose);
      final probe = Completer<http.Response>();
      final probeStarted = Completer<void>();
      final client = _TrackingMockClient((request) async {
        if (!probeStarted.isCompleted) probeStarted.complete();
        return probe.future;
      });
      final dashboard = DashboardClient(
        host: 'disposed.test',
        port: 9119,
        manualToken: 'test-token',
        httpClientOverride: client,
      );
      await NativeVoiceConsentStore(
        prefs,
      ).write(dashboard.baseUrl, NativeVoiceConsent.accepted);
      final owner = Object();
      final preparation = voice.beginHermesServerDictationPreparation(
        owner: owner,
      );
      final configuring = configureHermesServerDictation(
        voice: voice,
        owner: owner,
        preparation: preparation,
        connection: SavedConnection(
          id: 'disposed',
          label: 'Disposed',
          host: 'disposed.test',
          port: 8642,
          apiKey: 'test-key',
        ),
        preferences: prefs,
        profile: 'default',
        dashboardClient: dashboard,
      );
      await probeStarted.future;

      expect(voice.disableHermesServerDictation(owner: owner), isTrue);
      probe.complete(http.Response('{}', 400));

      expect(
        await configuring,
        HermesServerDictationConfigurationResult.superseded,
      );
      expect(client.closed, isTrue);
      expect(voice.hermesServerDictationReady, isFalse);
    });
  });
}
