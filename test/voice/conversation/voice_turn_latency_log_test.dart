import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/conversation/voice_turn_latency_log.dart';

void main() {
  late List<String> lines;
  late int micros;

  VoiceTurnLatencyLog log({bool enabled = true}) => VoiceTurnLatencyLog(
    enabled: enabled,
    nowMicros: () => micros,
    sink: lines.add,
  );

  setUp(() {
    lines = [];
    micros = 0;
  });

  test('end of speech and first text to first audio, in ms', () {
    final l = log()..endpoint();
    micros = 800000;
    l.firstToken();
    micros = 1450000;
    l.firstAudio(VoiceTurnAudioPath.stream, toolActive: false);
    l.flush();
    expect(lines, [
      '[hermes-voice-latency] turn=1 endpoint_to_token_ms=800 '
          'endpoint_to_audio_ms=1450 token_to_audio_ms=650 audio=stream '
          'tool=no audio_during_tool=no',
    ]);
  });

  test('audio while a tool runs is reported, first audio or later', () {
    final l = log()..endpoint();
    l.observe(audioPlaying: false, toolActive: true);
    l.firstToken();
    l.firstAudio(VoiceTurnAudioPath.queue, toolActive: false);
    l.observe(audioPlaying: true, toolActive: true);
    l.flush();
    expect(
      lines.single,
      endsWith('audio=queue tool=yes audio_during_tool=yes'),
    );
  });

  test('a tool that ran in silence is not an interim', () {
    final l = log()..endpoint();
    l.observe(audioPlaying: false, toolActive: true);
    l.firstToken();
    l.observe(audioPlaying: false, toolActive: false);
    l.firstAudio(VoiceTurnAudioPath.queue, toolActive: false);
    l.observe(audioPlaying: true, toolActive: false);
    l.flush();
    expect(lines.single, endsWith('tool=yes audio_during_tool=no'));
  });

  test('an unanswered take prints nothing', () {
    log()
      ..endpoint()
      ..flush()
      ..transcriptFinal()
      ..flush();
    expect(lines, isEmpty);
  });

  test('the endpoint wins over the later final transcript', () {
    final l = log()..endpoint();
    micros = 300000;
    l.transcriptFinal();
    micros = 500000;
    l.firstToken();
    l.flush();
    expect(lines.single, contains('endpoint_to_token_ms=500 '));
    expect(lines.single, contains('endpoint_to_audio_ms=- '));
    expect(lines.single, contains('audio=none'));
  });

  test('a new endpoint closes the previous turn; turns are counted', () {
    final l = log()
      ..endpoint()
      ..firstToken()
      ..endpoint()
      ..firstToken()
      ..flush();
    expect(lines, hasLength(2));
    expect(lines.last, startsWith('[hermes-voice-latency] turn=2 '));
    expect(l.enabled, isTrue);
  });

  test('outside QA it does nothing', () {
    final l = log(enabled: false)
      ..endpoint()
      ..firstToken()
      ..firstAudio(VoiceTurnAudioPath.stream, toolActive: true)
      ..flush();
    expect(l.enabled, isFalse);
    expect(lines, isEmpty);
  });

  test('the default follows the QA trace gate (off in tests)', () {
    expect(VoiceTurnLatencyLog().enabled, isFalse);
  });
}
