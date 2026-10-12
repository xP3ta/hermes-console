// Last known server voice mode, per connection and Hermes profile.
//
// The server owns `voice.voice_chat_mode` (`chained` | `gpt-live`) and
// reports it, with whether GPT-Live can start, in
// `GET /api/audio/voice-live/status`. Desktop reads that status and never
// keeps its own switch (`apps/desktop/src/store/voice-live.ts`); Console does
// the same, and remembers the last answer so a voice conversation can pick
// its engine at once instead of waiting for a status request.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'voice_live_protocol.dart';

/// What the server last said for one connection and profile.
final class VoiceChatMode {
  const VoiceChatMode({required this.mode, required this.available});

  final VoiceLiveMode mode;
  final bool available;

  /// GPT-Live starts only when the profile is set to it and it can start.
  bool get startsLive => mode == VoiceLiveMode.gptLive && available;

  @override
  bool operator ==(Object other) =>
      other is VoiceChatMode &&
      other.mode == mode &&
      other.available == available;

  @override
  int get hashCode => Object.hash(mode, available);
}

/// Remembers [VoiceChatMode] across conversations and restarts.
///
/// `SharedPreferences` already serves reads from memory, so every instance
/// over the same preferences sees the same value at once: the conversation
/// coordinator and the settings screen do not need to share one object.
final class VoiceChatModeStore {
  VoiceChatModeStore(SharedPreferences this._prefs);

  /// Memory only, for a process without preferences (tests).
  VoiceChatModeStore.memory() : _prefs = null;

  static const String _prefix = 'voice_chat_mode_v1::';
  static const String _statusPrefix = 'voice_live_status_v1::';

  final SharedPreferences? _prefs;
  final Map<String, String> _memory = {};
  final Map<String, String> _statusMemory = {};

  /// One entry per connection and profile; no profile and `default` are the
  /// same one, as in every profile-scoped Dashboard request.
  static String identity(String connectionId, String? profile) {
    final name = profile?.trim() ?? '';
    return '$connectionId::${name == 'default' ? '' : name}';
  }

  /// `null` until the server has answered once for [identity].
  VoiceChatMode? read(String identity) {
    final stored = _prefs?.getString('$_prefix$identity') ?? _memory[identity];
    return switch (stored) {
      'gpt-live' => const VoiceChatMode(
        mode: VoiceLiveMode.gptLive,
        available: true,
      ),
      'gpt-live:unavailable' => const VoiceChatMode(
        mode: VoiceLiveMode.gptLive,
        available: false,
      ),
      'chained' => const VoiceChatMode(
        mode: VoiceLiveMode.chained,
        available: true,
      ),
      'chained:unavailable' => const VoiceChatMode(
        mode: VoiceLiveMode.chained,
        available: false,
      ),
      _ => null,
    };
  }

  /// Records an answer of the status route. A `null` [status] is a server
  /// without the feature: it can only run the chained conversation.
  void remember(String identity, VoiceLiveStatus? status) {
    final mode = status?.mode == VoiceLiveMode.gptLive ? 'gpt-live' : 'chained';
    final value = status?.available == true ? mode : '$mode:unavailable';
    _memory[identity] = value;
    _prefs?.setString('$_prefix$identity', value);
    // The answer in full, for [lastStatus]. A server without the route has
    // none: nothing about GPT-Live is shown for it.
    if (status == null) {
      _statusMemory.remove(identity);
      _prefs?.remove('$_statusPrefix$identity');
      return;
    }
    final detail = jsonEncode({
      'mode': mode,
      'available': status.available,
      'reason': status.reason,
      'voice': status.voice,
    });
    _statusMemory[identity] = detail;
    _prefs?.setString('$_statusPrefix$identity', detail);
  }

  /// The last status the server gave for [identity], with its reason, so the
  /// settings screen can paint the GPT-Live choice before asking again.
  /// `null` when the server never answered or has no GPT-Live at all.
  VoiceLiveStatus? lastStatus(String identity) {
    final stored =
        _prefs?.getString('$_statusPrefix$identity') ?? _statusMemory[identity];
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is Map) {
          final reason = decoded['reason'];
          final voice = decoded['voice'];
          return VoiceLiveStatus(
            mode: decoded['mode'] == 'gpt-live'
                ? VoiceLiveMode.gptLive
                : VoiceLiveMode.chained,
            available: decoded['available'] == true,
            reason: reason is String ? reason : null,
            voice: voice is String ? voice : null,
          );
        }
      } catch (_) {
        // Fall through to what the mode alone says.
      }
    }
    // Answers remembered before the reason was kept: an available GPT-Live
    // means the server has the route. "Unavailable" alone could also be a
    // server without it, so it is not enough to show the choice.
    final mode = read(identity);
    return mode == null || !mode.available
        ? null
        : VoiceLiveStatus(mode: mode.mode, available: true);
  }
}
