import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/device_memory_profile.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/tts_engine.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Spec 048 / US4 — residencia de modelos según memoria
/// (contracts/model-residency.md): con memoria holgada los handoffs
/// escuchar↔hablar conservan los motores; con memoria justa o presión se
/// mantiene la serialización actual; salir del modo voz libera SIEMPRE.
class _SpyStt extends SttEngine {
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  bool get supportsPartials => true;

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
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

/// An on-device recogniser: it can stay loaded between captures.
class _WarmSpyStt extends _SpyStt implements WarmSttEngine {
  int parkCalls = 0;
  int prewarmCalls = 0;

  @override
  Future<void> park() async {
    parkCalls++;
  }

  @override
  Future<void> prewarm() async {
    prewarmCalls++;
  }
}

class _TimedIdleScheduler extends _ManualIdleScheduler {
  final List<Duration> delays = <Duration>[];

  @override
  VoiceIdleTimer create(Duration delay, void Function() callback) {
    delays.add(delay);
    return super.create(delay, callback);
  }
}

class _SpyTts implements TtsEngine, PrewarmableTts {
  int disposeCalls = 0;
  int prewarmCalls = 0;

  @override
  Future<void> prewarm([String? text]) async {
    prewarmCalls++;
  }

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

class _BlockingTts extends _SpyTts {
  Completer<void> speaking = Completer<void>();

  @override
  Future<void> speak(String text) => speaking.future;

  @override
  Future<void> stop() async {
    if (!speaking.isCompleted) speaking.complete();
  }
}

class _ManualIdleTimer implements VoiceIdleTimer {
  final void Function() _callback;
  bool _cancelled = false;

  _ManualIdleTimer(this._callback);

  @override
  void cancel() => _cancelled = true;

  void fire() {
    if (!_cancelled) _callback();
  }
}

class _ManualIdleScheduler {
  final List<_ManualIdleTimer> timers = <_ManualIdleTimer>[];

  VoiceIdleTimer create(Duration delay, void Function() callback) {
    final timer = _ManualIdleTimer(callback);
    timers.add(timer);
    return timer;
  }
}

const _bigDevice = DeviceMemoryProfile(memTotalBytes: 16 * 1024 * 1024 * 1024);
const _smallDevice = DeviceMemoryProfile(memTotalBytes: 4 * 1024 * 1024 * 1024);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({'app_locale': 'es'}));

  Future<(VoiceService, _SpyStt, _SpyTts)> service(
    DeviceMemoryProfile profile, {
    VoiceIdleTimerFactory? idleTimerFactory,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(
      prefs,
      SecureStorage(),
      idleTimerFactory: idleTimerFactory,
    );
    final stt = _SpyStt();
    final tts = _SpyTts();
    voice.debugSttFactory = () => stt;
    voice.debugTtsFactory = () => tts;
    voice.debugMemoryProfile = profile;
    // Materializa ambos motores como haría una sesión de voz real.
    voice.startDictation();
    await voice.enqueueSpeech('Hola.');
    await voice.waitSpeechDone();
    return (voice, stt, tts);
  }

  test('con memoria holgada los handoffs conservan los motores', () async {
    final (voice, stt, tts) = await service(_bigDevice);
    expect(voice.serializesHeavyLocalVoiceModels, isFalse);

    await voice.prepareForNarration();
    expect(stt.stopCalls, 1, reason: 'parar el dictado, no liberar el modelo');
    expect(stt.disposeCalls, 0);

    await voice.releaseTtsForListening();
    expect(tts.disposeCalls, 0, reason: 'el worker TTS queda residente');
  });

  test('con memoria justa se conserva la serialización actual', () async {
    final (voice, stt, tts) = await service(_smallDevice);
    expect(voice.serializesHeavyLocalVoiceModels, isTrue);

    await voice.prepareForNarration();
    expect(stt.disposeCalls, 1);

    await voice.releaseTtsForListening();
    expect(tts.disposeCalls, 1);
  });

  test(
    'la presión de memoria fuerza serialización desde el siguiente handoff',
    () async {
      final (voice, stt, tts) = await service(_bigDevice);

      await voice.onMemoryPressure();
      expect(voice.serializesHeavyLocalVoiceModels, isTrue);

      await voice.prepareForNarration();
      expect(stt.disposeCalls, 1);
      expect(tts.disposeCalls, 0);
    },
  );

  test('cancelar el dictado con residencia conserva el modelo', () async {
    final (voice, stt, tts) = await service(_bigDevice);

    await voice.cancelDictation();

    expect(stt.stopCalls, 1, reason: 'el micrófono se cierra siempre');
    expect(
      stt.disposeCalls,
      0,
      reason:
          'stop-and-talk/pausa no deben pagar una recarga de modelo '
          '(fuga vista en la validación física: ~3,7 s tras interrumpir)',
    );
    expect(tts.disposeCalls, 0);
  });

  test('cancelar el dictado sin residencia destruye como siempre', () async {
    final (voice, stt, _) = await service(_smallDevice);

    await voice.cancelDictation();

    expect(stt.disposeCalls, 1);
  });

  test('salir del modo voz libera siempre y limpia la presión', () async {
    final (voice, stt, tts) = await service(_bigDevice);
    await voice.onMemoryPressure();

    await voice.disposeSttForVoiceExit();
    await voice.disposeTtsForVoiceExit();

    expect(stt.disposeCalls, 1);
    expect(tts.disposeCalls, 1);
    expect(
      voice.serializesHeavyLocalVoiceModels,
      isFalse,
      reason: 'la presión es por sesión de voz: la siguiente empieza limpia',
    );
  });

  test('idle de 90 s evacua ONNX y STT local de forma determinista', () async {
    final scheduler = _ManualIdleScheduler();
    final (voice, stt, tts) = await service(
      _bigDevice,
      idleTimerFactory: scheduler.create,
    );

    await voice.cancelDictation();
    expect(scheduler.timers, isNotEmpty);
    expect(stt.disposeCalls, 0);
    expect(tts.disposeCalls, 0);

    scheduler.timers.last.fire();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(stt.disposeCalls, 1);
    expect(tts.disposeCalls, 1);
  });

  test('reutilizar antes del idle cancela la expulsión pendiente', () async {
    final scheduler = _ManualIdleScheduler();
    final (voice, stt, tts) = await service(
      _bigDevice,
      idleTimerFactory: scheduler.create,
    );

    await voice.cancelDictation();
    final staleTimer = scheduler.timers.last;
    voice.startDictation();
    staleTimer.fire();
    await Future<void>.delayed(Duration.zero);

    expect(stt.disposeCalls, 0);
    expect(tts.disposeCalls, 0);
  });

  test('memory pressure no evacua durante conversación activa', () async {
    final (voice, stt, tts) = await service(_bigDevice);
    voice.setVoiceConversationActive(true);

    await voice.onMemoryPressure();
    expect(stt.disposeCalls, 0);
    expect(tts.disposeCalls, 0);

    voice.setVoiceConversationActive(false);
    await voice.cancelDictation();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(stt.disposeCalls, 1);
    expect(tts.disposeCalls, 1);
  });

  test(
    'onTrimMemory ignora UI_HIDDEN: background no es presión real',
    () async {
      final (voice, stt, tts) = await service(_bigDevice);

      await voice.onTrimMemory(20); // TRIM_MEMORY_UI_HIDDEN

      expect(
        voice.serializesHeavyLocalVoiceModels,
        isFalse,
        reason: 'ir a background no debe reactivar la serialización',
      );
      await voice.cancelDictation();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(stt.disposeCalls, 0);
      expect(tts.disposeCalls, 0);
    },
  );

  test(
    'onTrimMemory en background con conversación activa conserva los modelos',
    () async {
      final (voice, stt, tts) = await service(_bigDevice);
      voice.setVoiceConversationActive(true);

      await voice.onTrimMemory(40); // TRIM_MEMORY_BACKGROUND

      expect(voice.serializesHeavyLocalVoiceModels, isFalse);
      expect(stt.disposeCalls, 0);
      expect(tts.disposeCalls, 0);
    },
  );

  test('onTrimMemory RUNNING_LOW es presión real y sí reacciona', () async {
    final (voice, stt, tts) = await service(_bigDevice);

    await voice.onTrimMemory(10); // TRIM_MEMORY_RUNNING_LOW

    expect(voice.serializesHeavyLocalVoiceModels, isTrue);
    await voice.prepareForNarration();
    expect(stt.disposeCalls, 1);
    expect(tts.disposeCalls, 0);
  });

  test(
    'onTrimMemory en background sin conversación mantiene la evacuación',
    () async {
      final (voice, _, _) = await service(_bigDevice);

      await voice.onTrimMemory(40); // TRIM_MEMORY_BACKGROUND

      expect(
        voice.serializesHeavyLocalVoiceModels,
        isTrue,
        reason: 'sin voz activa la presión del sistema sigue mandando',
      );
    },
  );

  test(
    'Pause libera la lease y los modelos sin borrar la ruta congelada',
    () async {
      final scheduler = _ManualIdleScheduler();
      final (voice, stt, tts) = await service(
        _bigDevice,
        idleTimerFactory: scheduler.create,
      );
      voice.setVoiceConversationActive(true);
      final route = voice.activeVoiceRoute;

      voice.setVoiceConversationAudioLeaseActive(false);
      expect(voice.activeVoiceRoute, same(route));
      expect(
        stt.disposeCalls,
        0,
        reason: 'el recorder real sigue siendo owner',
      );
      await voice.cancelDictation();
      expect(scheduler.timers, isNotEmpty);
      scheduler.timers.last.fire();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(stt.disposeCalls, 1);
      expect(tts.disposeCalls, 1);

      voice.setVoiceConversationAudioLeaseActive(true);
      expect(voice.activeVoiceRoute, same(route));

      voice.setVoiceConversationActive(false);
      expect(voice.activeVoiceRoute, isNull);
      voice.setVoiceConversationAudioLeaseActive(true);
      await voice.onMemoryPressure();
      expect(stt.disposeCalls, 1, reason: 'Exit rechaza una lease tardía');
      expect(tts.disposeCalls, 1, reason: 'Exit rechaza una lease tardía');
    },
  );

  test(
    'una lectura pausada conserva ONNX incluso con memory pressure',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final scheduler = _ManualIdleScheduler();
      final tts = _BlockingTts();
      final voice = VoiceService(
        prefs,
        SecureStorage(),
        idleTimerFactory: scheduler.create,
      )..debugTtsFactory = () => tts;

      await voice.toggleReadAloud(
        messageKey: 'assistant:paused',
        revision: '1',
        markdown: 'Primera frase. Segunda frase.',
      );
      await Future<void>.delayed(Duration.zero);
      await voice.toggleReadAloud(
        messageKey: 'assistant:paused',
        revision: '1',
        markdown: 'Primera frase. Segunda frase.',
      );

      await voice.onMemoryPressure();
      expect(tts.disposeCalls, 0);

      await voice.stopAndDiscardReadAloud();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(tts.disposeCalls, 1);
    },
  );

  group('recogniser kept warm after voice', () {
    Future<(VoiceService, _WarmSpyStt, _TimedIdleScheduler)> voiceSession(
      DeviceMemoryProfile profile,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      final scheduler = _TimedIdleScheduler();
      final voice = VoiceService(
        prefs,
        SecureStorage(),
        idleTimerFactory: scheduler.create,
      );
      final stt = _WarmSpyStt();
      voice.debugSttFactory = () => stt;
      voice.debugMemoryProfile = profile;
      voice.setVoiceConversationActive(true);
      expect((await voice.checkStt()).ready, isTrue);
      voice.startDictation();
      return (voice, stt, scheduler);
    }

    Future<void> settle() async {
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }

    test(
      'leaving voice frees the microphone and keeps the recogniser',
      () async {
        final (voice, stt, scheduler) = await voiceSession(_bigDevice);

        await voice.disposeSttForVoiceExit(keepRecognizerWarm: true);
        voice.setVoiceConversationActive(false);

        expect(
          stt.parkCalls,
          1,
          reason: 'the capture ends, microphone released',
        );
        expect(
          stt.stopCalls,
          0,
          reason: 'nothing is transcribed on the way out',
        );
        expect(stt.disposeCalls, 0);
        // It waits its own, longer time: 3 minutes, not the 90 s of a dictation.
        expect(scheduler.delays.last, const Duration(minutes: 3));

        // Starting again finds it loaded: the same engine, no new one.
        var created = 0;
        voice.debugSttFactory = () {
          created++;
          return _WarmSpyStt();
        };
        voice.setVoiceConversationActive(true);
        expect((await voice.checkStt()).ready, isTrue);
        voice.startDictation();
        expect(created, 0);
        expect(stt.disposeCalls, 0);

        // Used again, it is nobody's leftover: its timer does not fire on it.
        scheduler.timers.last.fire();
        await settle();
        expect(stt.disposeCalls, 0);
      },
    );

    test('it survives the whole way out of a conversation on this phone, and '
        'the way back in', () async {
      final prefs = await SharedPreferences.getInstance();
      final scheduler = _TimedIdleScheduler();
      final voice = VoiceService(
        prefs,
        SecureStorage(),
        idleTimerFactory: scheduler.create,
      );
      final engines = <_WarmSpyStt>[];
      final tts = _SpyTts();
      voice.debugSttFactory = () {
        final engine = _WarmSpyStt();
        engines.add(engine);
        return engine;
      };
      voice.debugTtsFactory = () => tts;
      voice.debugMemoryProfile = _bigDevice;

      // In, as the chat does it: the phone's route, then the conversation.
      expect(voice.enableOnDeviceVoice(), isTrue);
      voice.setVoiceConversationActive(true);
      expect((await voice.checkStt()).ready, isTrue);
      voice.startDictation();
      await voice.enqueueSpeech('Hola.');
      await voice.waitSpeechDone();

      // Out, in the order the conversation does it: it stops being active,
      // releases the recogniser's capture, the voice, and then the route.
      voice.setVoiceConversationActive(false);
      await voice.disposeSttForVoiceExit(keepRecognizerWarm: true);
      await voice.disposeTtsForVoiceExit();
      voice.disableNativeVoice();
      await settle();

      expect(tts.disposeCalls, 1);
      expect(engines.single.parkCalls, 1);
      expect(engines.single.disposeCalls, 0, reason: 'still loaded');
      // With the voice gone it is alone, on its own three minutes.
      expect(scheduler.delays.last, const Duration(minutes: 3));

      // Back in before that: the same recogniser, nothing loaded again.
      expect(voice.enableOnDeviceVoice(), isTrue);
      voice.setVoiceConversationActive(true);
      expect((await voice.checkStt()).ready, isTrue);
      voice.startDictation();
      expect(engines, hasLength(1));
      expect(engines.single.disposeCalls, 0);

      // Out again and left alone: released when the time is up.
      voice.setVoiceConversationActive(false);
      await voice.disposeSttForVoiceExit(keepRecognizerWarm: true);
      await voice.disposeTtsForVoiceExit();
      voice.disableNativeVoice();
      scheduler.timers.last.fire();
      await settle();
      expect(engines.single.disposeCalls, 1);
    });

    test('the kept recogniser is released when its time is up', () async {
      final (voice, stt, scheduler) = await voiceSession(_bigDevice);
      await voice.disposeSttForVoiceExit(keepRecognizerWarm: true);
      voice.setVoiceConversationActive(false);
      expect(stt.disposeCalls, 0);

      scheduler.timers.last.fire();
      await settle();

      expect(stt.disposeCalls, 1);
      // And the next start builds a fresh one.
      var created = 0;
      voice.debugSttFactory = () {
        created++;
        return _WarmSpyStt();
      };
      await voice.checkStt();
      expect(created, 1);
    });

    test('memory pressure releases it at once', () async {
      final (voice, stt, _) = await voiceSession(_bigDevice);
      await voice.disposeSttForVoiceExit(keepRecognizerWarm: true);
      voice.setVoiceConversationActive(false);

      await voice.onTrimMemory(10); // TRIM_MEMORY_RUNNING_LOW
      await settle();

      expect(stt.disposeCalls, 1);
    });

    test(
      'leaving the app releases it, not a conversation that goes on',
      () async {
        final (voice, stt, _) = await voiceSession(_bigDevice);

        // The conversation continues behind the lock screen: untouched.
        await voice.onTrimMemory(20); // TRIM_MEMORY_UI_HIDDEN
        await settle();
        expect(stt.disposeCalls, 0);

        // Paused by the user, still a conversation: its own timer decides.
        await voice.disposeSttForVoiceExit(keepRecognizerWarm: true);
        voice.setVoiceConversationAudioLeaseActive(false);
        await voice.onTrimMemory(20);
        await settle();
        expect(stt.disposeCalls, 0);

        // Ended, and only waiting for a next start nobody can make from here.
        voice.setVoiceConversationActive(false);
        await voice.onTrimMemory(20);
        await settle();
        expect(stt.disposeCalls, 1);
      },
    );

    test('under memory pressure leaving voice releases as before', () async {
      final (voice, stt, _) = await voiceSession(_bigDevice);
      await voice.onTrimMemory(10); // deferred: the conversation holds audio

      await voice.disposeSttForVoiceExit(keepRecognizerWarm: true);

      expect(stt.parkCalls, 0);
      expect(stt.disposeCalls, 1);
    });

    test('a suspension for privacy still releases everything', () async {
      final (voice, stt, _) = await voiceSession(_bigDevice);

      await voice.disposeSttForVoiceExit();

      expect(stt.parkCalls, 0);
      expect(stt.disposeCalls, 1);
    });

    test('a kept recogniser is not lent to a capture that wants another '
        'engine', () async {
      // The composer dictates with the system recogniser; voice on this
      // phone talks to the on-device one.
      SharedPreferences.setMockInitialValues({
        'app_locale': 'es',
        'voice_stt_engine': SttEngineKind.system.id,
      });
      final prefs = await SharedPreferences.getInstance();
      final voice = VoiceService(prefs, SecureStorage());
      final engines = <_WarmSpyStt>[];
      voice.debugSttFactory = () {
        final engine = _WarmSpyStt();
        engines.add(engine);
        return engine;
      };
      voice.debugMemoryProfile = _bigDevice;
      voice.enableOnDeviceVoice();
      voice.setVoiceConversationActive(true);
      expect(voice.effectiveConversationSttEngine, SttEngineKind.sherpaLive);
      expect((await voice.checkStt()).ready, isTrue);
      voice.startDictation();
      await voice.disposeSttForVoiceExit(keepRecognizerWarm: true);
      voice.setVoiceConversationActive(false);
      expect(engines.single.disposeCalls, 0);

      // The composer's microphone: its own engine, not the leftover.
      final check = await voice.checkStt(forComposerDictation: true);
      expect(check.engine, SttEngineKind.system);
      expect(engines, hasLength(2));
      expect(engines.first.disposeCalls, 1);

      await voice.disposeSttForVoiceExit();
    });

    test(
      'the recogniser starts loading as soon as it is known to be used',
      () async {
        final (voice, stt, _) = await voiceSession(_bigDevice);
        expect(stt.prewarmCalls, 1);

        // Where two heavy models may not share memory, the load keeps its
        // place in the listen/speak handoff.
        final prefs = await SharedPreferences.getInstance();
        final small = VoiceService(prefs, SecureStorage());
        final smallStt = _WarmSpyStt();
        small.debugSttFactory = () => smallStt;
        small.debugMemoryProfile = _smallDevice;
        expect(small.serializesHeavyLocalVoiceModels, isTrue);
        expect((await small.checkStt()).ready, isTrue);
        expect(smallStt.prewarmCalls, 0);
        await small.disposeSttForVoiceExit();
        await voice.disposeSttForVoiceExit();
      },
    );
  });
}
