// `voice.stop_phrases`: the spoken (and typed) command that ends a voice
// conversation, copied from Hermes Desktop.
//
// - Reading the list: apps/desktop/src/store/voice-prefs.ts:18-91. Absent or
//   malformed → the backend default with the built-in English list; `[]` →
//   disabled; a list equal to `/api/config/defaults` → default mode; any
//   other list (any language) replaces the built-in one.
// - Matching: apps/desktop/src/lib/voice-stop-word.ts:22-129. Only a whole
//   utterance, optionally addressed to Hermes, is a stop command.
// - Loading: app/session/hooks/use-hermes-config.ts:80 and :170 (config
//   and defaults together; defaults that fail → the backend default).
// - Notice: app/chat/composer/hooks/use-composer-voice.ts:383-401 (it names
//   the first phrase; none when stop phrases are disabled).
//
// Declared deviations from Desktop:
// - Default mode also accepts «cállate»/«callate», the one Spanish command
//   Console already had. A custom list replaces it like the English list.
// - Dart has no Unicode normalization without a package. Of NFKC only the
//   full-width ASCII forms and the ideographic space are folded here.

import 'package:flutter/foundation.dart';

import '../../../l10n/app_localizations.dart';
import '../connection_manager.dart';
import 'voice_server_prefs.dart';

/// How the matcher treats `voice.stop_phrases` (Desktop
/// `VoiceStopPhraseConfig`, voice-prefs.ts:28-30).
enum VoiceStopPhraseMode { defaults, custom, disabled }

/// `voice.stop_phrases` of one profile: the matcher mode and the phrase the
/// "Say … to end" notice names (Desktop `$voiceStopPhraseConfig` and
/// `$voiceStopPhrase`).
class VoiceStopPhraseConfig {
  const VoiceStopPhraseConfig._(this.mode, this.phrases, this.noticePhrase);

  /// The backend default (`DEFAULT_VOICE_STOP_PHRASES = ["stop"]`), used
  /// until the profile's config answers (voice-prefs.ts:18-26).
  static const VoiceStopPhraseConfig backendDefault = VoiceStopPhraseConfig._(
    VoiceStopPhraseMode.defaults,
    <String>[],
    _backendDefaultPhrase,
  );

  /// Reads `voice.stop_phrases` from a `GET /api/config` payload and
  /// compares it with the `GET /api/config/defaults` one; without [defaults]
  /// the backend default `["stop"]` is used (voice-prefs.ts:70-91).
  factory VoiceStopPhraseConfig.fromServerConfig(
    Object? config, [
    Object? defaults,
  ]) {
    final phrases = _stopPhraseList(_voiceValue(config, 'stop_phrases'));
    if (phrases == null) return backendDefault;
    if (phrases.isEmpty) {
      return const VoiceStopPhraseConfig._(
        VoiceStopPhraseMode.disabled,
        <String>[],
        null,
      );
    }
    final defaultPhrases =
        _stopPhraseList(_voiceValue(defaults, 'stop_phrases')) ??
        const <String>[_backendDefaultPhrase];
    if (_samePhrases(phrases, defaultPhrases)) {
      return VoiceStopPhraseConfig._(
        VoiceStopPhraseMode.defaults,
        const <String>[],
        phrases.first,
      );
    }
    return VoiceStopPhraseConfig._(
      VoiceStopPhraseMode.custom,
      List<String>.unmodifiable(phrases),
      phrases.first,
    );
  }

  final VoiceStopPhraseMode mode;

  /// The configured phrases in custom mode; empty in the other modes.
  final List<String> phrases;

  /// The phrase the notice names; null when stop phrases are disabled.
  final String? noticePhrase;
}

const String _backendDefaultPhrase = 'stop';

Object? _voiceValue(Object? config, String key) {
  if (config is! Map) return null;
  final voice = config['voice'];
  return voice is Map ? voice[key] : null;
}

/// Like Desktop's `stopPhraseList` (voice-prefs.ts:44-56): a bare string is
/// one phrase, non-text entries are skipped, anything that is neither a list
/// nor a string means "backend default" (null).
List<String>? _stopPhraseList(Object? raw) {
  final List<Object?>? list = raw is String
      ? <Object?>[raw]
      : raw is List
      ? raw
      : null;
  if (list == null) return null;
  final result = <String>[];
  for (final entry in list) {
    final text = entry is String
        ? entry
        : entry is num
        ? _jsNumberText(entry)
        : null;
    final trimmed = text?.trim() ?? '';
    if (trimmed.isNotEmpty) result.add(trimmed);
  }
  return result;
}

/// `String(n)` in JavaScript: a whole double reads without `.0`.
String _jsNumberText(num value) {
  if (value is double &&
      value.isFinite &&
      value.abs() < 1e21 &&
      value == value.truncateToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}

bool _samePhrases(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].toLowerCase() != b[i].toLowerCase()) return false;
  }
  return true;
}

// Canonical English stop commands used while `voice.stop_phrases` is unset
// or still the backend default (voice-stop-word.ts:22-41).
const List<String> _desktopStopPhrases = <String>[
  'stop',
  'stop listening',
  'stop it',
  'stop please',
  'please stop',
  'stop stop',
  'that is all',
  "that's all",
  'never mind',
  'nevermind',
  'end conversation',
  'end the conversation',
  'goodbye',
  'good bye',
  'bye',
  'cancel',
];

// Console's only addition to default mode (see the header).
const List<String> _consoleDefaultPhrases = <String>['cállate', 'callate'];

// Optional address prefixes, stripped before matching (voice-stop-word.ts:45).
const List<String> _addressPrefixes = <String>[
  'hey hermes',
  'hey hermes,',
  'hermes',
  'hermes,',
  'ok',
  'okay',
  'hey',
];

final RegExp _punctuation = RegExp(r'\p{P}+', unicode: true);
final RegExp _whitespace = RegExp(r'\s+');

final Set<String> _defaultPhrases = <String>{
  for (final phrase in [..._desktopStopPhrases, ..._consoleDefaultPhrases])
    _normalize(phrase),
};

/// Desktop's `normalize` (voice-stop-word.ts:47-59): lowercase, punctuation
/// from any script turned into spaces, whitespace collapsed. Transcripts and
/// configured phrases go through the same function.
String _normalize(String text) => _foldWidth(text)
    .toLowerCase()
    .replaceAll(_punctuation, ' ')
    .replaceAll(_whitespace, ' ')
    .trim();

/// The part of NFKC Dart can do without a package: full-width ASCII
/// (U+FF01-U+FF5E) and the ideographic space (U+3000).
String _foldWidth(String text) {
  final units = text.codeUnits;
  if (!units.any(_isWideForm)) return text;
  return String.fromCharCodes(
    units.map(
      (unit) => unit == 0x3000
          ? 0x20
          : _isWideForm(unit)
          ? unit - 0xFEE0
          : unit,
    ),
  );
}

bool _isWideForm(int unit) =>
    unit == 0x3000 || (unit >= 0xFF01 && unit <= 0xFF5E);

String _stripAddress(String text) {
  for (final prefix in _addressPrefixes) {
    // A bare address ("hermes") is not a stop command on its own.
    if (text == prefix) continue;
    if (text.startsWith('$prefix ')) {
      return text.substring(prefix.length + 1).trim();
    }
  }
  return text;
}

/// True when the whole [transcript] is a stop command under [config]
/// (Desktop `isVoiceStopCommand`, voice-stop-word.ts:90-129). Something that
/// merely contains a stop phrase ("stop the container") is never one.
bool isVoiceStopCommand(String transcript, VoiceStopPhraseConfig config) {
  if (transcript.isEmpty) return false;
  final phrases = switch (config.mode) {
    VoiceStopPhraseMode.disabled => const <String>{},
    VoiceStopPhraseMode.custom =>
      config.phrases.map(_normalize).where((p) => p.isNotEmpty).toSet(),
    VoiceStopPhraseMode.defaults => _defaultPhrases,
  };
  if (phrases.isEmpty) return false;
  final normalized = _normalize(transcript);
  if (normalized.isEmpty) return false;
  return phrases.contains(normalized) ||
      phrases.contains(_stripAddress(normalized));
}

/// The "Say … to end the voice chat" notice for a starting conversation, or
/// null when stop phrases are disabled (use-composer-voice.ts:383-401).
String? voiceStopNotice(Strings strings, VoiceStopPhraseConfig config) {
  final phrase = config.noticePhrase;
  return phrase == null ? null : strings.voz132SayStopToEnd(phrase);
}

/// `voice.stop_phrases` of the Dashboard profile the voice conversation runs
/// on, in memory only. Another profile starts from the backend default, as
/// Desktop does before its config loads, and a late answer for a profile
/// that is no longer selected is dropped.
class VoiceStopPhraseState extends ValueNotifier<VoiceStopPhraseConfig> {
  VoiceStopPhraseState() : super(VoiceStopPhraseConfig.backendDefault);

  String? _identity;

  /// Selects the profile a conversation is about to use.
  void select(String identity) {
    if (_identity == identity) return;
    _identity = identity;
    value = VoiceStopPhraseConfig.backendDefault;
  }

  /// Applies [config] if [identity] is still the selected profile.
  bool apply(String identity, VoiceStopPhraseConfig config) {
    if (_identity != identity) return false;
    value = config;
    return true;
  }
}

/// Reads `voice.stop_phrases` for [profile] like Desktop's config refresh:
/// `GET /api/config` and `GET /api/config/defaults` together, the defaults
/// failing → the backend default. Null when the config itself cannot be read
/// (the previous value stays). Only `voice.stop_phrases` is kept from the
/// payload.
Future<VoiceStopPhraseConfig?> loadVoiceStopPhrases(
  DashboardClient dashboard, {
  String? profile,
}) async =>
    (await loadVoiceServerConfig(dashboard, profile: profile))?.stopPhrases;
