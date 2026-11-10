// Voice preferences a conversation reads from the profile's `/api/config`,
// copied from Hermes Desktop `store/voice-prefs.ts:93-146` and its config
// refresh (`app/session/hooks/use-hermes-config.ts:169-174`).

import 'package:flutter/foundation.dart';

import '../connection_manager.dart';
import 'voice_stop_phrases.dart';

/// Desktop's tuned end-of-turn hold (`voice-prefs.ts:128`), the same 1.25 s
/// Console's loop and barge-in endpoint already use.
const Duration kDesktopVoiceSilence = Duration(milliseconds: 1250);

/// The backend's documented `voice.silence_duration` (`voice-prefs.ts:129`),
/// used when `/api/config/defaults` does not answer.
const double kBackendVoiceSilenceSeconds = 3.0;

/// The backend default sensitivity (`lib/voice-barge-in.ts:40`).
const double kDefaultBargeInThresholdMultiplier = 3.0;

Object? _voiceValue(Object? config, String key) {
  if (config is! Map) return null;
  final voice = config['voice'];
  return voice is Map ? voice[key] : null;
}

/// JavaScript `Number(raw)` for the shapes YAML can hand back: null and an
/// empty string are 0, booleans 1/0, numbers themselves, other strings
/// parsed after trimming; anything else is NaN.
double _jsNumber(Object? raw) {
  if (raw == null) return 0;
  if (raw is bool) return raw ? 1 : 0;
  if (raw is num) return raw.toDouble();
  if (raw is String) {
    final text = raw.trim();
    if (text.isEmpty) return 0;
    return double.tryParse(text) ?? double.nan;
  }
  return double.nan;
}

/// `voice.barge_in`: armed unless the key is explicitly false
/// (`voice-prefs.ts:93-101`).
bool voiceBargeInFromConfig(Object? config) =>
    _voiceValue(config, 'barge_in') != false;

/// `voice.barge_in_threshold_multiplier`: null when unset or invalid, so the
/// monitor keeps its built-in trigger levels (`voice-prefs.ts:103-113`).
double? voiceBargeInThresholdMultiplierFromConfig(Object? config) {
  final value = _jsNumber(
    _voiceValue(config, 'barge_in_threshold_multiplier'),
  );
  return value.isFinite && value > 0 ? value : null;
}

/// Scale of the barge-in trigger levels for [multiplier]
/// (`voice-barge-in.ts:82-88`): the quiet-floor multiplier and the playback
/// minimum both move by `multiplier / 3`; 1 when unset.
double bargeInThresholdScale(double? multiplier) =>
    multiplier != null && multiplier.isFinite && multiplier > 0
    ? multiplier / kDefaultBargeInThresholdMultiplier
    : 1;

double? _silenceSeconds(Object? raw) {
  // `true` must not coerce to 1 s (voice-prefs.ts:134).
  if (raw is bool) return null;
  final value = raw is num ? raw.toDouble() : _jsNumber(raw);
  return value.isFinite && value > 0 ? value : null;
}

/// `voice.silence_duration`: only a value the user changed (different from
/// `/api/config/defaults`) replaces Desktop's 1.25 s (`voice-prefs.ts:
/// 115-146`); `/api/config` merges the defaults, so reading it as-is would
/// triple the hold for everyone who never touched the key.
Duration voiceSilenceFromConfig(Object? config, Object? defaults) {
  final seconds = _silenceSeconds(_voiceValue(config, 'silence_duration'));
  final defaultSeconds =
      _silenceSeconds(_voiceValue(defaults, 'silence_duration')) ??
      kBackendVoiceSilenceSeconds;
  if (seconds == null || seconds == defaultSeconds) {
    return kDesktopVoiceSilence;
  }
  return Duration(microseconds: (seconds * 1000000).round());
}

/// `voice.thinking_sound`: on unless explicitly false
/// (`voice-prefs.ts:148-157`).
bool voiceThinkingSoundFromConfig(Object? config) =>
    _voiceValue(config, 'thinking_sound') != false;

/// The backend's `voice.beep_volume` default (`config_defaults.py:1250`).
const double kDefaultVoiceBeepVolume = 0.3;

/// `voice.beep_volume`: a number in 0.0-1.0, else 0.3, read like the
/// backend's `_get_beep_volume` (`tools/voice_mode.py:358-366`).
double voiceBeepVolumeFromConfig(Object? config) {
  final raw = _voiceValue(config, 'beep_volume');
  if (raw == null || raw is bool) return kDefaultVoiceBeepVolume;
  final value = raw is num
      ? raw.toDouble()
      : raw is String
      ? double.tryParse(raw.trim())
      : null;
  if (value == null || value.isNaN || value < 0 || value > 1) {
    return kDefaultVoiceBeepVolume;
  }
  return value;
}

/// The profile's barge-in sensitivity, end-of-turn hold and thinking sound.
final class VoiceServerPrefs {
  const VoiceServerPrefs({
    this.bargeInThresholdMultiplier,
    this.silence = kDesktopVoiceSilence,
    this.thinkingSound = false,
    this.beepVolume = kDefaultVoiceBeepVolume,
  });

  static const VoiceServerPrefs desktopDefaults = VoiceServerPrefs();

  factory VoiceServerPrefs.fromServerConfig(Object? config, Object? defaults) =>
      VoiceServerPrefs(
        bargeInThresholdMultiplier: voiceBargeInThresholdMultiplierFromConfig(
          config,
        ),
        silence: voiceSilenceFromConfig(config, defaults),
        thinkingSound: voiceThinkingSoundFromConfig(config),
        beepVolume: voiceBeepVolumeFromConfig(config),
      );

  final double? bargeInThresholdMultiplier;
  final Duration silence;

  /// The profile's `voice.thinking_sound`, read like Desktop's. Console
  /// plays nothing while the agent works whatever it says (QA 9709): the
  /// capsule shows the work instead.
  final bool thinkingSound;
  final double beepVolume;

  @override
  bool operator ==(Object other) =>
      other is VoiceServerPrefs &&
      other.bargeInThresholdMultiplier == bargeInThresholdMultiplier &&
      other.silence == silence &&
      other.thinkingSound == thinkingSound &&
      other.beepVolume == beepVolume;

  @override
  int get hashCode => Object.hash(
    bargeInThresholdMultiplier,
    silence,
    thinkingSound,
    beepVolume,
  );
}

/// The prefs of the profile a conversation uses, in memory only. Another
/// profile starts from Desktop's defaults until its config answers, and a
/// late answer for another profile is dropped.
class VoiceServerPrefsState extends ValueNotifier<VoiceServerPrefs> {
  VoiceServerPrefsState() : super(VoiceServerPrefs.desktopDefaults);

  String? _identity;

  void select(String identity) {
    if (_identity == identity) return;
    _identity = identity;
    value = VoiceServerPrefs.desktopDefaults;
  }

  bool apply(String identity, VoiceServerPrefs prefs) {
    if (_identity != identity) return false;
    value = prefs;
    return true;
  }
}

/// Everything a voice conversation takes from one config read.
final class VoiceServerConfigRead {
  const VoiceServerConfigRead({
    required this.stopPhrases,
    required this.prefs,
    required this.bargeIn,
  });

  factory VoiceServerConfigRead.fromServerConfig(
    Object? config,
    Object? defaults,
  ) => VoiceServerConfigRead(
    stopPhrases: VoiceStopPhraseConfig.fromServerConfig(config, defaults),
    prefs: VoiceServerPrefs.fromServerConfig(config, defaults),
    bargeIn: voiceBargeInFromConfig(config),
  );

  final VoiceStopPhraseConfig stopPhrases;
  final VoiceServerPrefs prefs;
  final bool bargeIn;
}

/// `GET /api/config?profile=` and `GET /api/config/defaults` together, like
/// Desktop's config refresh. The defaults failing means the backend
/// defaults; the config failing means null (the previous values stay). Only
/// the voice keys above are kept from the payload.
Future<VoiceServerConfigRead?> loadVoiceServerConfig(
  DashboardClient dashboard, {
  String? profile,
}) async {
  Future<Map<String, dynamic>> defaults() async {
    try {
      return await dashboard.getServerConfigDefaults();
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  try {
    final payloads = await Future.wait([
      dashboard.getServerConfig(profile: profile),
      defaults(),
    ]);
    return VoiceServerConfigRead.fromServerConfig(payloads[0], payloads[1]);
  } catch (_) {
    return null;
  }
}
