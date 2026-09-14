import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/stt_hermes_server.dart';
import 'package:record/record.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

/// Spec 048 / US5 — runtime STT contra /api/audio/transcribe
/// (contracts/native-voice.md): el clip WAV local viaja como data_url base64
/// y el transcript del servidor vuelve como final; errores limpios.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('captura habla con el preset acústico equivalente a Desktop', () async {
    expect(kHermesServerSttRecordConfig.encoder, AudioEncoder.wav);
    expect(kHermesServerSttRecordConfig.sampleRate, 16000);
    expect(kHermesServerSttRecordConfig.numChannels, 1);
    expect(kHermesServerSttRecordConfig.echoCancel, isTrue);
    expect(kHermesServerSttRecordConfig.noiseSuppress, isTrue);
    expect(
      kHermesServerSttRecordConfig.androidConfig.audioSource,
      AndroidAudioSource.voiceRecognition,
    );

    final engine = buildHermesServerSttEngine(
      transcribeRequest: (_, _) async => <String, dynamic>{
        'ok': true,
        'transcript': '',
      },
      lang: 'es',
    );
    expect(engine.speechOnsetDb, -18);
    expect(engine.discardAutomaticTurnWithoutSpeechOnset, isTrue);
    await engine.dispose();
  });

  Future<String> clip(List<int> bytes) async {
    final dir = await Directory.systemTemp.createTemp('hermes-stt');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/turno.wav');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  test('el clip se envía como data_url WAV y vuelve el transcript', () async {
    final requests = <(String, String)>[];
    final runtime = HermesServerSttRuntime(
      transcribeRequest: (dataUrl, mimeType) async {
        requests.add((dataUrl, mimeType));
        return {'ok': true, 'transcript': ' hola servidor ', 'provider': 'fw'};
      },
    );
    addTearDown(runtime.dispose);
    final path = await clip([1, 2, 3, 4]);

    final transcript = await runtime.transcribe(
      model: WhisperModel.tiny,
      audioPath: path,
      lang: 'es',
      threads: 2,
    );

    expect(transcript, 'hola servidor');
    expect(requests.single.$2, 'audio/wav');
    expect(
      requests.single.$1,
      'data:audio/wav;base64,${base64Encode([1, 2, 3, 4])}',
    );
  });

  test('un clip vacío no llama al servidor y devuelve vacío', () async {
    var calls = 0;
    final runtime = HermesServerSttRuntime(
      transcribeRequest: (dataUrl, mimeType) async {
        calls++;
        return {'ok': true, 'transcript': 'nunca'};
      },
    );
    addTearDown(runtime.dispose);
    final path = await clip(const []);

    final transcript = await runtime.transcribe(
      model: WhisperModel.tiny,
      audioPath: path,
      lang: 'es',
      threads: 2,
    );

    expect(transcript, '');
    expect(calls, 0);
  });

  test(
    'una respuesta sin ok lanza sin copiar el detalle del servidor',
    () async {
      final runtime = HermesServerSttRuntime(
        transcribeRequest: (dataUrl, mimeType) async => {
          'ok': false,
          'detail': 'PRIVATE_STT_SERVER_DETAIL /home/server/audio.wav',
        },
      );
      addTearDown(runtime.dispose);
      final path = await clip([1]);

      await expectLater(
        runtime.transcribe(
          model: WhisperModel.tiny,
          audioPath: path,
          lang: 'es',
          threads: 2,
        ),
        throwsA(
          predicate<Object>(
            (error) =>
                !error.toString().contains('PRIVATE_STT_SERVER_DETAIL') &&
                !error.toString().contains('/home/server'),
          ),
        ),
      );
    },
  );

  test('el modelo local nunca es requisito: modelReady es true', () async {
    final runtime = HermesServerSttRuntime(
      transcribeRequest: (dataUrl, mimeType) async => {'ok': true},
    );
    addTearDown(runtime.dispose);

    expect(await runtime.modelReady(WhisperModel.tiny), isTrue);
  });
}
