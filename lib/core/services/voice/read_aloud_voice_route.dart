// One voice for spoken replies.
//
// «Voz de las respuestas» is a single choice per connection and profile:
// Hermes server or this phone. A voice conversation installs that route when
// it starts and drops it when it ends, so reading a reply aloud outside a
// conversation had no route of its own and always spoke with the phone voice,
// whatever had been chosen. Desktop has one voice for both (its `tts.*`
// config); this gives Console the same answer.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection_manager.dart';
import 'conversation/native_voice.dart';
import 'conversation/native_voice_session_configurator.dart';
import 'voice_service.dart';

/// Puts the voice chosen for a connection and profile in place before a reply
/// is read aloud.
abstract final class ReadAloudVoiceRoute {
  /// Identity whose server route this helper installed last. The route may be
  /// replaced behind its back (a conversation, the settings screen); then
  /// [VoiceService.nativeVoiceActive] or this identity stop matching and the
  /// next read installs it again.
  static String? _alignedIdentity;

  @visibleForTesting
  static void resetForTesting() => _alignedIdentity = null;

  /// With "Hermes server" chosen and accepted for [connection] and [profile],
  /// installs the server voice unless it is already the one in place. With
  /// "this phone", removes a server voice left installed. A running voice
  /// conversation owns the route and is never touched.
  ///
  /// The server route for reading is not strict: if the server cannot be
  /// reached the reply is read with the phone voice rather than not at all.
  static Future<void> align({
    required VoiceService voice,
    required SavedConnection connection,
    required SharedPreferences preferences,
    required String profile,
    NativeVoiceDashboardFactory? dashboardFactory,
  }) async {
    if (voice.activeVoiceRoute != null) return;
    final String identity;
    try {
      final probe = (dashboardFactory ?? DashboardClient.lazy)(connection);
      identity = nativeVoicePreferenceIdentity(probe.baseUrl, profile: profile);
      probe.close();
    } catch (_) {
      // No usable Dashboard for this connection: only the phone can speak.
      return;
    }
    final wantsServer =
        NativeVoiceModeStore(preferences).read(identity) ==
            NativeVoiceMode.server &&
        NativeVoiceConsentStore(preferences).read(identity) ==
            NativeVoiceConsent.accepted;
    if (!wantsServer) {
      if (voice.nativeVoiceActive) voice.disableNativeVoice();
      _alignedIdentity = null;
      return;
    }
    if (voice.nativeVoiceActive && _alignedIdentity == identity) return;
    final installed = await configureAcceptedNativeVoiceSession(
      voice: voice,
      connection: connection,
      preferences: preferences,
      profile: profile,
      dashboardFactory: dashboardFactory,
    );
    _alignedIdentity = installed ? identity : null;
  }
}
