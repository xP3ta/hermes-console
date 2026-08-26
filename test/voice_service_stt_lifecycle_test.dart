// Tests del ciclo de vida del motor STT en VoiceService (FIX-1, TASK-022).
//
// El bug de estabilidad del modo voz era que checkStt() —llamado en CADA turno—
// destruía y reconstruía el motor STT (y con él un AudioRecord nativo + contexto
// whisper.cpp) en cada escucha, lo que provocaba fugas y cuelgues tras varias
// interacciones. Estos tests verifican el comportamiento corregido sin tocar
// hardware, inyectando un motor falso vía `debugSttFactory`.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';

/// Motor STT falso: cuenta paradas y liberaciones, y puede simular un fallo al
/// liberar para comprobar que no tumba el servicio.
class _FakeStt implements SttEngine {
  _FakeStt({this.throwOnDispose = false, this.disposeGate});

  final bool throwOnDispose;
  final Completer<void>? disposeGate;
  final Completer<void> disposeStarted = Completer<void>();
  int stopCount = 0;
  int disposeCount = 0;

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
    stopCount++;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    if (!disposeStarted.isCompleted) disposeStarted.complete();
    await disposeGate?.future;
    if (throwOnDispose) throw Exception('boom');
  }

  @override
  bool get supportsPartials => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VoiceService voice;
  late List<_FakeStt> created;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    voice = VoiceService(prefs, SecureStorage());
    created = [];
    voice.debugSttFactory = () {
      final e = _FakeStt();
      created.add(e);
      return e;
    };
  });

  test(
    'un ajuste inicial efímero no modifica la preferencia persistida',
    () async {
      SharedPreferences.setMockInitialValues({
        'voice_stt_engine': SttEngineKind.server.id,
      });
      final prefs = await SharedPreferences.getInstance();
      final stored = VoiceSettings.load(prefs);
      final ephemeral = VoiceService(
        prefs,
        SecureStorage(),
        initialSettings: stored.copyWith(sttEngine: SttEngineKind.sherpaLive),
      );

      expect(ephemeral.settings.sttEngine, SttEngineKind.sherpaLive);
      expect(prefs.getString('voice_stt_engine'), SttEngineKind.server.id);
    },
  );

  test(
    'checkStt reutiliza el motor entre turnos (no recrea por turno)',
    () async {
      for (var i = 0; i < 5; i++) {
        final check = await voice.checkStt();
        expect(check.ready, isTrue);
      }
      // Cinco turnos, UN solo motor: antes del fix eran cinco AudioRecord nativos.
      expect(created, hasLength(1));
      expect(created.single.disposeCount, 0);
    },
  );

  test('checkStt recrea el motor si cambia la configuración STT', () async {
    await voice.checkStt();
    expect(created, hasLength(1));

    // Cambiar de motor invalida el cacheado (saveSettings lo libera).
    await voice.saveSettings(
      voice.settings.copyWith(sttEngine: SttEngineKind.system),
    );

    await voice.checkStt();
    expect(created, hasLength(2));
    // El motor viejo se liberó al cambiar de configuración.
    expect(created.first.disposeCount, 1);
    expect(created.last.disposeCount, 0);
  });

  test(
    'stopDictation para el motor pero NO lo libera (se reutiliza)',
    () async {
      await voice.checkStt();
      await voice.stopDictation();

      expect(created.single.stopCount, 1);
      expect(created.single.disposeCount, 0);

      // El siguiente turno reutiliza el MISMO motor (no se creó otro).
      await voice.checkStt();
      expect(created, hasLength(1));
    },
  );

  test(
    'stopDictation es un no-op si no hay motor (no crea ni crashea)',
    () async {
      await voice.stopDictation();
      expect(created, isEmpty);
    },
  );

  test('cancelDictation aborta sin transcribir y recrea el motor', () async {
    await voice.checkStt();
    final engine = created.single;

    await voice.cancelDictation();
    expect(engine.stopCount, 0);
    expect(engine.disposeCount, 1);

    await voice.checkStt();
    expect(created, hasLength(2));
  });

  test(
    'disposeSttForVoiceExit libera el motor y obliga a recrear al reentrar',
    () async {
      await voice.checkStt();
      final engine = created.single;

      await voice.disposeSttForVoiceExit();
      expect(engine.disposeCount, 1);

      // Reentrar al modo voz construye un motor nuevo y limpio.
      await voice.checkStt();
      expect(created, hasLength(2));
      expect(created.last.disposeCount, 0);
    },
  );

  test('disposeSttForVoiceExit es idempotente', () async {
    await voice.checkStt();
    await voice.disposeSttForVoiceExit();
    await voice.disposeSttForVoiceExit();

    // El segundo cierre no re-libera ni revienta.
    expect(created.single.disposeCount, 1);
  });

  test(
    'salir espera un cancel STT pendiente antes de liberar el runtime',
    () async {
      final gate = Completer<void>();
      final engine = _FakeStt(disposeGate: gate);
      voice.debugSttFactory = () {
        created.add(engine);
        return engine;
      };
      await voice.checkStt();

      final cancel = voice.cancelDictation();
      await engine.disposeStarted.future;
      var exitCompleted = false;
      final exit = voice.disposeSttForVoiceExit().then((_) {
        exitCompleted = true;
      });
      await Future<void>.delayed(Duration.zero);

      expect(exitCompleted, isFalse);
      expect(engine.disposeCount, 1);
      gate.complete();
      await Future.wait([cancel, exit]);
      expect(exitCompleted, isTrue);
      expect(engine.disposeCount, 1);
    },
  );

  test(
    'un dispose del motor que lanza excepción no tumba el servicio',
    () async {
      voice.debugSttFactory = () {
        final e = _FakeStt(throwOnDispose: true);
        created.add(e);
        return e;
      };
      await voice.checkStt();

      // No debe propagar la excepción del motor muerto.
      await expectLater(voice.disposeSttForVoiceExit(), completes);

      // Y el servicio sigue usable: el siguiente turno crea un motor nuevo.
      await voice.checkStt();
      expect(created, hasLength(2));
    },
  );

  test('rebind Hermes libera A solo después de disponer su motor', () async {
    final gate = Completer<void>();
    final engine = _FakeStt(disposeGate: gate);
    final prefs = await SharedPreferences.getInstance();
    final hermesVoice = VoiceService(
      prefs,
      SecureStorage(),
      initialSettings: const VoiceSettings(
        sttEngine: SttEngineKind.hermesServer,
      ),
    );
    hermesVoice.debugSttFactory = () => engine;
    final ownerA = Object();
    final ownerB = Object();
    var releasesA = 0;
    var releasesB = 0;
    final preparationA = hermesVoice.beginHermesServerDictationPreparation(
      owner: ownerA,
    );
    expect(
      hermesVoice.enableHermesServerDictation(
        owner: ownerA,
        preparation: preparationA,
        transcribe: (dataUrl, mimeType) async => {'ok': true},
        onDispose: () => releasesA++,
      ),
      isTrue,
    );
    await hermesVoice.checkStt();

    final preparationB = hermesVoice.beginHermesServerDictationPreparation(
      owner: ownerB,
    );
    await engine.disposeStarted.future;
    expect(releasesA, 0);
    expect(
      hermesVoice.enableHermesServerDictation(
        owner: ownerB,
        preparation: preparationB,
        transcribe: (dataUrl, mimeType) async => {'ok': true},
        onDispose: () => releasesB++,
      ),
      isTrue,
    );
    expect(hermesVoice.hermesServerDictationReady, isTrue);

    gate.complete();
    await hermesVoice.disposeSttForVoiceExit();
    expect(releasesA, 1);
    expect(releasesB, 0);
    expect(hermesVoice.disableHermesServerDictation(owner: ownerB), isTrue);
    expect(releasesB, 1);
    expect(hermesVoice.disableHermesServerDictation(owner: ownerB), isFalse);
    expect(releasesB, 1);
    await hermesVoice.dispose();
  });
}
