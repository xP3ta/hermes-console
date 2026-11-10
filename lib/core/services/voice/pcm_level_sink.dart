import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'hermes_pcm_stream.dart';

/// Windows a second of audio is cut into for its level: 16 a second, a
/// little over 60 ms each, the pace the voice capsule's wave moves at.
const int kPcmLevelWindowsPerSecond = 16;

/// The loudness (RMS, 0..1 of full scale) of each window of
/// [samplesPerWindow] samples of signed 16-bit little-endian mono PCM; a
/// last shorter window counts too.
@visibleForTesting
List<double> pcmWindowLevels(Uint8List pcm16le, int samplesPerWindow) {
  final data = ByteData.sublistView(pcm16le);
  final samples = pcm16le.length ~/ 2;
  final levels = <double>[];
  for (var start = 0; start < samples; start += samplesPerWindow) {
    final end = math.min(samples, start + samplesPerWindow);
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      final s = data.getInt16(i * 2, Endian.little) / 32768;
      sum += s * s;
    }
    levels.add(math.sqrt(sum / (end - start)));
  }
  return levels;
}

/// A [HermesPcmStreamSink] that also tells how loud the reply is while it
/// plays (QA 9709: the voice capsule's wave follows it).
///
/// A block AudioTrack has accepted starts playing about then: its windows'
/// levels go to [level] one after the other, at the pace the audio plays.
/// Paused, stopped or finished, [level] is 0. Everything else is [_inner]'s.
class LevelReportingPcmSink implements HermesPcmStreamSink {
  LevelReportingPcmSink(this._inner, this.level);

  final HermesPcmStreamSink _inner;

  /// Where the level goes (`VoiceService.playbackLevel`).
  final ValueNotifier<double> level;

  final Queue<double> _pending = Queue<double>();
  int _sampleRate = 16000;
  Timer? _timer;
  bool _paused = false;

  int get _samplesPerWindow =>
      math.max(1, _sampleRate ~/ kPcmLevelWindowsPerSecond);

  Duration get _window => Duration(
    microseconds:
        _samplesPerWindow * Duration.microsecondsPerSecond ~/ _sampleRate,
  );

  @override
  int get generation => _inner.generation;

  @override
  Future<void> configure(HermesPcmFormat format) {
    _sampleRate = format.sampleRate;
    return _inner.configure(format);
  }

  @override
  Future<void> write(Uint8List pcm16le) async {
    await _inner.write(pcm16le);
    _pending.addAll(pcmWindowLevels(pcm16le, _samplesPerWindow));
    if (_timer == null && !_paused) {
      _next();
      _timer = Timer.periodic(_window, (_) => _next());
    }
  }

  void _next() {
    if (_pending.isEmpty) {
      _quiet();
      return;
    }
    level.value = _pending.removeFirst();
  }

  /// No level, and nothing scheduled.
  void _quiet() {
    _timer?.cancel();
    _timer = null;
    level.value = 0;
  }

  @override
  Future<void> pause() {
    _paused = true;
    _quiet();
    return _inner.pause();
  }

  @override
  Future<void> resume() {
    _paused = false;
    if (_pending.isNotEmpty && _timer == null) {
      _next();
      _timer = Timer.periodic(_window, (_) => _next());
    }
    return _inner.resume();
  }

  @override
  Future<void> finish() async {
    try {
      await _inner.finish();
    } finally {
      _pending.clear();
      _quiet();
    }
  }

  @override
  Future<void> stop() {
    _pending.clear();
    _quiet();
    return _inner.stop();
  }
}
