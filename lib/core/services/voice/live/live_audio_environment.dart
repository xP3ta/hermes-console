import 'package:flutter/services.dart';

/// Android audio changes that make a live voice session unsafe to continue.
enum LiveAudioEvent {
  /// Another app or a call took audio focus.
  focusLost,

  /// The set of audio output devices changed (headset or Bluetooth).
  routeChanged,
}

/// Stream of [LiveAudioEvent]s from the platform. Listening starts the native
/// observers; cancelling the last listener stops them.
const EventChannel _liveAudioChannel = EventChannel('hermes/live_audio_events');

///
/// One stream is shared by every listener (GPT-Live and the chained engine):
/// a second `receiveBroadcastStream` on the same channel would take over the
/// first one's handler, and cancelling either would stop both.
Stream<LiveAudioEvent> platformLiveAudioEvents() =>
    _sharedLiveAudioEvents ??= _liveAudioChannel
        .receiveBroadcastStream()
        .map(
          (event) => switch (event) {
            'focusLost' => LiveAudioEvent.focusLost,
            'routeChanged' => LiveAudioEvent.routeChanged,
            _ => null,
          },
        )
        .where((event) => event != null)
        .cast<LiveAudioEvent>();

Stream<LiveAudioEvent>? _sharedLiveAudioEvents;
