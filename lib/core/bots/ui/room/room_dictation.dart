import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/connection_manager.dart';
import '../../../services/voice/conversation/native_voice_session_configurator.dart';
import '../../../services/voice/stt_engine.dart';
import '../../../services/voice/voice_response_policy.dart';
import '../../../services/voice/voice_service.dart';
import '../../../services/voice/voice_settings.dart' show SttEngineKind;

/// Why dictation could not start (the room shows a short notice).
enum RoomDictationFailure { unavailable, error }

/// Composer dictation for the Room, same engine as the main chat
/// (`VoiceService.startDictation`): the transcript is appended to the
/// composer text when the segment ends. Kept small on purpose: the full
/// chat voice mode is not part of rooms.
abstract class RoomDictation extends ChangeNotifier {
  bool get recording;
  bool get transcribing;
  ValueListenable<double>? get level;

  Future<void> start({
    required String currentText,
    required ValueChanged<String> onText,
    required ValueChanged<RoomDictationFailure> onFailure,
  });
  Future<void> stop();
  Future<void> cancel();
}

final class VoiceRoomDictation extends RoomDictation {
  final VoiceService voice;
  final SavedConnection connection;
  final String profile;

  VoiceRoomDictation({
    required this.voice,
    required this.connection,
    required this.profile,
  });

  bool _recording = false;
  bool _transcribing = false;
  bool _disposed = false;
  StreamSubscription<SttResult>? _sub;
  String _base = '';
  String _original = '';
  String _partial = '';
  ValueChanged<String>? _onText;
  Timer? _fallback;

  @override
  bool get recording => _recording;
  @override
  bool get transcribing => _transcribing;
  @override
  ValueListenable<double>? get level => voice.micLevel;

  static String _join(String base, String segment) {
    final b = base.trimRight();
    final s = segment.trim();
    if (b.isEmpty) return s;
    if (s.isEmpty) return b;
    return '$b $s';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> start({
    required String currentText,
    required ValueChanged<String> onText,
    required ValueChanged<RoomDictationFailure> onFailure,
  }) async {
    if (_recording) return;
    await _sub?.cancel();
    _sub = null;
    if (voice.settings.sttEngine == SttEngineKind.hermesServer) {
      final preparation = voice.beginHermesServerDictationPreparation(
        owner: this,
      );
      final configured = await configureHermesServerDictation(
        voice: voice,
        owner: this,
        preparation: preparation,
        connection: connection,
        preferences: await SharedPreferences.getInstance(),
        profile: profile,
      );
      if (_disposed) {
        voice.cancelHermesServerDictationPreparation(preparation);
        voice.disableHermesServerDictation(owner: this);
        return;
      }
      if (configured == HermesServerDictationConfigurationResult.superseded) {
        return;
      }
      if (configured != HermesServerDictationConfigurationResult.configured) {
        onFailure(RoomDictationFailure.unavailable);
        return;
      }
    } else {
      voice.disableHermesServerDictation(owner: this);
    }
    final check = await voice.checkStt(forComposerDictation: true);
    if (_disposed) return;
    if (!check.ready) {
      onFailure(RoomDictationFailure.unavailable);
      return;
    }
    if (!await voice.prepareForMicrophoneCapture() || _disposed) return;
    _onText = onText;
    _original = currentText;
    _base = currentText.trimRight();
    _partial = '';
    _recording = true;
    _transcribing = false;
    _notify();
    _sub = voice
        .startDictation(continuous: true, forComposerDictation: true)
        .listen(
          (result) {
            var text = result.text.trim();
            if (VoiceResponsePolicy.isLikelySttHallucination(text)) text = '';
            if (!result.isFinal) {
              _partial = text;
              return;
            }
            _partial = '';
            if (text.isNotEmpty) _base = _join(_base, text);
          },
          onError: (Object _) {
            _finish();
            onFailure(RoomDictationFailure.error);
          },
          onDone: _finish,
        );
  }

  void _finish() {
    if (!_recording && !_transcribing) return;
    if (_partial.isNotEmpty) _base = _join(_base, _partial);
    _partial = '';
    _fallback?.cancel();
    _fallback = null;
    _sub?.cancel();
    _sub = null;
    _recording = false;
    _transcribing = false;
    _onText?.call(_base);
    _notify();
  }

  @override
  Future<void> stop() async {
    if (!_recording || _transcribing) return;
    _transcribing = true;
    _notify();
    _fallback?.cancel();
    _fallback = Timer(const Duration(seconds: 4), _finish);
    await voice.stopDictation();
  }

  @override
  Future<void> cancel() async {
    if (!_recording) return;
    _fallback?.cancel();
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    _recording = false;
    _transcribing = false;
    _partial = '';
    _onText?.call(_original);
    _notify();
    await voice.cancelDictation();
  }

  @override
  void dispose() {
    _disposed = true;
    _fallback?.cancel();
    _sub?.cancel();
    if (_recording) unawaited(voice.cancelDictation());
    voice.disableHermesServerDictation(owner: this);
    super.dispose();
  }
}
