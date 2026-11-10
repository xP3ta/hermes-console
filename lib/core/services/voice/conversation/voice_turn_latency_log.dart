// One logcat line per voice turn, for measuring on a phone what the QA
// Timeline trace (`voice_latency_trace.dart`) only shows in DevTools:
//
//   adb logcat | grep hermes-voice-latency
//
// Content-free by construction: the public API takes no text, only moments.
// The line carries milliseconds, a turn counter and yes/no flags.

import 'package:flutter/foundation.dart';

import '../voice_latency_trace.dart';

typedef VoiceTurnLatencySink = void Function(String line);

/// How the first reply audio of a turn reached the speaker.
enum VoiceTurnAudioPath {
  /// Hermes `speak-stream`: the moment is the first PCM accepted by the player.
  stream,

  /// The sentence queue (client-direct, phone TTS or the POST fallback): the
  /// moment is the first chunk accepted by the speech queue.
  queue,
}

final class VoiceTurnLatencyLog {
  VoiceTurnLatencyLog({
    this._enabled = kVoiceLatencyTraceEnabled,
    int Function()? nowMicros,
    VoiceTurnLatencySink? sink,
  }) : _nowMicros = nowMicros ?? _monotonicMicros,
       _sink = sink ?? debugPrint;

  static const String tag = '[hermes-voice-latency]';

  static final Stopwatch _clock = Stopwatch()..start();
  static int _monotonicMicros() => _clock.elapsedMicroseconds;

  final bool _enabled;
  final int Function() _nowMicros;
  final VoiceTurnLatencySink _sink;

  int _turns = 0;
  int? _endpointAt;
  int? _firstTokenAt;
  int? _firstAudioAt;
  VoiceTurnAudioPath? _audioPath;
  bool _tool = false;
  bool _audioDuringTool = false;

  bool get enabled => _enabled;

  bool get _open => _endpointAt != null;

  /// The user stopped talking. Closes the previous turn if it is still open.
  void endpoint() {
    if (!_enabled) return;
    flush();
    _endpointAt = _nowMicros();
  }

  /// The final transcript arrived. Starts the turn when the engine reports no
  /// separate endpoint (streaming STT, or a typed final in tests); a turn
  /// already answered is closed first.
  void transcriptFinal() {
    if (!_enabled) return;
    if (_open && (_firstTokenAt != null || _firstAudioAt != null)) flush();
    if (_open) return;
    _endpointAt = _nowMicros();
  }

  /// The first server-authored reply text of the turn was accepted.
  void firstToken() {
    if (!_enabled || !_open || _firstTokenAt != null) return;
    _firstTokenAt = _nowMicros();
  }

  /// Called on every state change with what the runtime owns right now.
  void observe({required bool audioPlaying, required bool toolActive}) {
    if (!_enabled || !_open) return;
    if (toolActive) _tool = true;
    if (audioPlaying && toolActive) _audioDuringTool = true;
  }

  /// The first reply audio of the turn started on [path].
  void firstAudio(VoiceTurnAudioPath path, {required bool toolActive}) {
    if (!_enabled || !_open || _firstAudioAt != null) return;
    _firstAudioAt = _nowMicros();
    _audioPath = path;
    if (toolActive) {
      _tool = true;
      _audioDuringTool = true;
    }
  }

  /// Prints the open turn, if anything was answered, and closes it.
  void flush() {
    if (!_enabled || !_open) return;
    final endpointAt = _endpointAt!;
    final tokenAt = _firstTokenAt;
    final audioAt = _firstAudioAt;
    if (tokenAt != null || audioAt != null) {
      _turns++;
      String ms(int? from, int? to) => from == null || to == null || to < from
          ? '-'
          : '${((to - from) / 1000).round()}';
      String yesNo(bool value) => value ? 'yes' : 'no';
      _sink(
        '$tag turn=$_turns '
        'endpoint_to_token_ms=${ms(endpointAt, tokenAt)} '
        'endpoint_to_audio_ms=${ms(endpointAt, audioAt)} '
        'token_to_audio_ms=${ms(tokenAt, audioAt)} '
        'audio=${_audioPath?.name ?? 'none'} '
        'tool=${yesNo(_tool)} '
        'audio_during_tool=${yesNo(_audioDuringTool)}',
      );
    }
    _endpointAt = null;
    _firstTokenAt = null;
    _firstAudioAt = null;
    _audioPath = null;
    _tool = false;
    _audioDuringTool = false;
  }
}
