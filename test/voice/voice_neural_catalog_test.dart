import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/tts_model_manager.dart';
import 'package:hermes_android/core/services/voice/voice_language.dart';

void main() {
  test('new neural assets retain published sizes and SHA-256 digests', () {
    const assets = {
      'de_DE-thorsten-medium': (67214254, '50487d9c95fdf2191f31d2588569381063ba1591dcd4c7d4bdd30f12b2191714'),
      'fr_FR-siwis-medium': (67207459, '375909aa30842b3a4efa10b1beb1d761af792960ae6873b4d53889f96c66195b'),
      'it_IT-paola-medium': (67221173, '7541f75778afa164e44e34baaef63befad7698595df26a95ca944b63ef1a16b4'),
      'zh_CN-huayan-medium': (67255926, 'dbdfec42b91d9cee31cce9ff4b3e9c305eb6fbf60546d071f7e46273554cce6b'),
      'ko_KO-kss_low': (66838474, 'f015d1d15a52ed00d6fe22757c5ef4a74283c53daf829c838fa5c22616ed789c'),
    };
    expect(kNeuralVoices.map((voice) => voice.id).toSet().length, kNeuralVoices.length);
    for (final entry in assets.entries) {
      final voice = neuralVoiceById(entry.key)!;
      expect(voice.archiveBytes, entry.value.$1);
      expect(voice.archiveSha256, entry.value.$2);
      expect(voice.url, 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/${voice.dirName}.tar.bz2');
      expect(voice.onnxFile, '${entry.key}.onnx');
    }
    for (final language in voiceLanguages.values) {
      final voiceId = language.neuralVoiceId;
      if (voiceId != null) {
        final voice = neuralVoiceById(voiceId)!;
        expect(voice.locale.startsWith('${language.code}-'), isTrue);
      }
    }
    expect(neuralVoiceById('zh_CN-huayan-medium')!.dictionaryLanguage, 'cmn');
    expect(neuralVoiceById('pt_BR-faber-medium')!.dictionaryLanguage, 'pt');
  });

  test('Japanese stays on system TTS and Korean low quality is explicit', () {
    expect(kNeuralVoices.where((voice) => voice.locale.startsWith('ja')), isEmpty);
    expect(voiceLanguageFor('ja').systemTtsOnly, isTrue);
    expect(voiceLanguageFor('ja').neuralVoiceId, isNull);
    final korean = neuralVoiceById('ko_KO-kss_low')!;
    expect(korean.quality, 'low');
    expect(korean.requiresQualityReview, isTrue);
    expect(korean.dictionaryLanguage, 'ko');
    expect(voiceLanguageFor('ko').neuralVoiceId, isNull);
    expect(korean.dirName, 'vits-mimic3-ko_KO-kss_low');
  });
}
