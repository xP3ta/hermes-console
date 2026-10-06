import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
// Transitive through video_player; only the fake platform needs it, so it
// stays out of pubspec (and of the release SBOM).
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// In-memory [VideoPlayerPlatform] for widget tests: every created player
/// gets an id, emits `initialized` on listen and records play/pause/seek and
/// disposal, so a test can tell a fresh controller from a reused one.
class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  FakeVideoPlayerPlatform({this.duration = const Duration(seconds: 5)});

  final Duration duration;
  int _nextId = 1;
  final List<int> created = <int>[];
  final List<String> sources = <String>[];
  final Set<int> disposed = <int>{};
  final List<String> calls = <String>[];
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> _positions = {};

  /// When set, the next created player fails to initialize.
  bool failNextInit = false;

  /// When set, [getPosition] answers only on [releasePositions]: models a
  /// position poll still in flight when the clip completes.
  bool holdPositions = false;
  final List<Completer<Duration>> _heldPositions = <Completer<Duration>>[];

  /// Positions polled while [holdPositions] was on and not yet answered.
  int get heldPositionCount => _heldPositions.length;

  /// Answers every held position poll with [position].
  void releasePositions(Duration position) {
    final held = List<Completer<Duration>>.of(_heldPositions);
    _heldPositions.clear();
    for (final c in held) {
      c.complete(position);
    }
  }

  /// Moves the platform playhead; the controller sees it on its next poll.
  void setPosition(int playerId, Duration position) {
    _positions[playerId] = position;
  }

  /// The clip on [playerId] reached its end.
  void emitCompleted(int playerId) {
    _events[playerId]?.add(VideoEvent(eventType: VideoEventType.completed));
  }

  /// Reports how far [playerId] has buffered.
  void emitBuffered(int playerId, Duration end) {
    _events[playerId]?.add(
      VideoEvent(
        eventType: VideoEventType.bufferingUpdate,
        buffered: <DurationRange>[DurationRange(Duration.zero, end)],
      ),
    );
  }

  static FakeVideoPlayerPlatform install({Duration? duration}) {
    final fake = FakeVideoPlayerPlatform(
      duration: duration ?? const Duration(seconds: 5),
    );
    VideoPlayerPlatform.instance = fake;
    return fake;
  }

  /// Players created and not disposed.
  List<int> get live => [
    for (final id in created)
      if (!disposed.contains(id)) id,
  ];

  /// Reports a platform failure on [playerId] after it initialized (e.g. a
  /// decoder or surface error on resume).
  void emitError(int playerId) {
    _events[playerId]?.addError(
      PlatformException(code: 'VideoError', message: 'decoder lost'),
    );
  }

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    created.add(id);
    sources.add(options.dataSource.uri ?? '');
    final fail = failNextInit;
    failNextInit = false;
    final controller = StreamController<VideoEvent>(
      // A cancel without onCancel returns the root-zone null future, which
      // never completes under FakeAsync: the controller's dispose would hang
      // before reaching [dispose] and every player would look leaked.
      onCancel: () => Future<void>.value(),
      onListen: () {
        if (fail) {
          _events[id]?.addError(
            PlatformException(code: 'VideoError', message: 'cannot open'),
          );
          return;
        }
        _events[id]?.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: duration,
            size: const Size(320, 180),
          ),
        );
      },
    );
    _events[id] = controller;
    return id;
  }

  @override
  Future<int?> create(DataSource dataSource) => createWithOptions(
    VideoCreationOptions(
      dataSource: dataSource,
      viewType: VideoViewType.textureView,
    ),
  );

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    calls.add('dispose:$playerId');
    _events.remove(playerId);
  }

  @override
  Future<void> play(int playerId) async {
    assert(!disposed.contains(playerId), 'play on a disposed player');
    calls.add('play:$playerId');
  }

  @override
  Future<void> pause(int playerId) async => calls.add('pause:$playerId');

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    _positions[playerId] = position;
    calls.add('seek:$playerId:${position.inMilliseconds}');
  }

  @override
  Future<Duration> getPosition(int playerId) {
    if (holdPositions) {
      final held = Completer<Duration>();
      _heldPositions.add(held);
      return held.future;
    }
    return Future<Duration>.value(_positions[playerId] ?? Duration.zero);
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async =>
      calls.add('volume:$playerId:$volume');

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async =>
      calls.add('speed:$playerId:$speed');

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      SizedBox.expand(key: ValueKey<String>('fake-video-${options.playerId}'));

  @override
  Widget buildView(int playerId) =>
      SizedBox.expand(key: ValueKey<String>('fake-video-$playerId'));
}
