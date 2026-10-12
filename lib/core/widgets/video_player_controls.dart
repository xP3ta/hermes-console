import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/app_localizations.dart';
import '../design/modal.dart' show HermesAction, showHermesMenu;
import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// Speeds offered by the speed menu.
const List<double> videoPlaybackSpeeds = <double>[0.5, 1, 1.5, 2];

/// Step of the ±10 s buttons and of the double-tap seek.
const Duration videoSeekStep = Duration(seconds: 10);

/// How long the controls stay up while the video plays untouched.
const Duration videoControlsAutoHide = Duration(seconds: 3);

/// `m:ss` (or `h:mm:ss`) for a playback position or duration.
String formatVideoTime(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final minutes = d.inMinutes.remainder(60);
  if (d.inHours > 0) {
    return '${d.inHours}:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

/// What one player hands to the next when the video moves between the chat
/// card and the full-screen viewer: each surface owns its own controller
/// (the lazy transcript may dispose the card under an open viewer), so the
/// playhead, play state, volume and speed travel as a value.
@immutable
class VideoPlaybackHandoff {
  const VideoPlaybackHandoff({
    this.position = Duration.zero,
    this.playing = false,
    this.volume = 1,
    this.speed = 1,
  });

  factory VideoPlaybackHandoff.of(VideoPlayerController controller) {
    final value = controller.value;
    return VideoPlaybackHandoff(
      position: value.position,
      playing: value.isPlaying,
      volume: value.volume,
      speed: value.playbackSpeed,
    );
  }

  final Duration position;
  final bool playing;
  final double volume;
  final double speed;

  /// Puts [controller] (initialized) in this state. Never starts playback
  /// unless the previous surface was already playing.
  Future<void> applyTo(VideoPlayerController controller) async {
    final value = controller.value;
    if (value.volume != volume) await controller.setVolume(volume);
    if (value.playbackSpeed != speed) await controller.setPlaybackSpeed(speed);
    var target = position;
    if (target > value.duration) target = value.duration;
    if (target.isNegative) target = Duration.zero;
    if (target != controller.value.position) await controller.seekTo(target);
    if (playing) await controller.play();
  }
}

/// Round 48 dp control used by the player overlay (white glyph over video).
class VideoControlButton extends StatelessWidget {
  const VideoControlButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.child,
    this.size = 48,
    this.iconSize = 24,
    this.filled = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final Widget? child;
  final double size;
  final double iconSize;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: SizedBox(
          width: size,
          height: size,
          child: Material(
            color: filled
                ? Colors.black.withValues(alpha: 0.5)
                : Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: Center(
                child: child ?? Icon(icon, color: Colors.white, size: iconSize),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mobile player chrome laid over a [VideoPlayer]: tap to show/hide (auto
/// hide after [videoControlsAutoHide] while playing), play/pause/replay,
/// ±10 s buttons and double-tap seek, a draggable timeline with the
/// buffered range, time labels, mute, speed and a full-screen toggle.
///
/// It also pauses the video when the app leaves the foreground or an opaque
/// route covers it.
class VideoPlayerControls extends StatefulWidget {
  const VideoPlayerControls({
    super.key,
    required this.controller,
    required this.isFullscreen,
    required this.onFullscreen,
    this.leading = const <Widget>[],
    this.trailing = const <Widget>[],
  });

  final VideoPlayerController controller;
  final bool isFullscreen;
  final VoidCallback onFullscreen;

  /// Extra buttons at the start of the top row (download, share).
  final List<Widget> leading;

  /// Extra buttons at the end of the top row (close).
  final List<Widget> trailing;

  @override
  State<VideoPlayerControls> createState() => _VideoPlayerControlsState();
}

class _VideoPlayerControlsState extends State<VideoPlayerControls>
    with WidgetsBindingObserver {
  final GlobalKey _speedAnchor = GlobalKey();
  bool _visible = true;
  Timer? _hideTimer;

  /// The clip reached its end and nothing moved the playhead since: Play
  /// restarts from 0 even when a late position poll left the playhead a
  /// little short of the duration (Play would otherwise resume there and
  /// complete again at once).
  bool _ended = false;
  bool _sawCompleted = false;
  bool _sawPlaying = false;

  double? _dragMs;
  bool _resumeAfterDrag = false;
  Offset? _doubleTapAt;
  bool _accessible = false;
  bool _tickerEnabled = true;

  VideoPlayerController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attach(_controller);
  }

  void _attach(VideoPlayerController controller) {
    _sawCompleted = controller.value.isCompleted;
    _sawPlaying = controller.value.isPlaying;
    controller.addListener(_onValue);
    if (_sawPlaying) _scheduleHide();
  }

  @override
  void didUpdateWidget(covariant VideoPlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onValue);
      _ended = false;
      _dragMs = null;
      _attach(widget.controller);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _accessible = MediaQuery.maybeAccessibleNavigationOf(context) ?? false;
    if (_accessible) _hideTimer?.cancel();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled != _tickerEnabled) {
      _tickerEnabled = enabled;
      // An opaque route now covers this one: stop the sound. Deferred
      // because pausing notifies listeners that rebuild during this build.
      if (!enabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_tickerEnabled) _pauseForInterruption();
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _pauseForInterruption();
  }

  void _pauseForInterruption() {
    if (_controller.value.isPlaying) unawaited(_controller.pause());
    _show();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _controller.removeListener(_onValue);
    super.dispose();
  }

  void _onValue() {
    if (!mounted) return;
    final value = _controller.value;
    if (value.isCompleted && !_sawCompleted) {
      _ended = true;
      _show();
    }
    _sawCompleted = value.isCompleted;
    if (value.isPlaying != _sawPlaying) {
      _sawPlaying = value.isPlaying;
      if (value.isPlaying) {
        _scheduleHide();
      } else {
        _show();
      }
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_visible || _accessible || _dragMs != null) return;
    if (!_controller.value.isPlaying) return;
    _hideTimer = Timer(videoControlsAutoHide, () {
      if (!mounted || _dragMs != null || !_controller.value.isPlaying) return;
      setState(() => _visible = false);
    });
  }

  void _show() {
    if (!mounted) return;
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _toggleVisible() {
    if (_visible && !_accessible) {
      _hideTimer?.cancel();
      setState(() => _visible = false);
    } else {
      _show();
    }
  }

  Future<void> _togglePlay() async {
    _show();
    final value = _controller.value;
    if (value.isPlaying) {
      await _controller.pause();
      return;
    }
    if (_ended ||
        (value.duration > Duration.zero && value.position >= value.duration)) {
      _ended = false;
      await _controller.seekTo(Duration.zero);
    }
    await _controller.play();
  }

  Future<void> _seekTo(Duration target) async {
    final duration = _controller.value.duration;
    if (target > duration) target = duration;
    if (target.isNegative) target = Duration.zero;
    _ended = false;
    await _controller.seekTo(target);
  }

  Future<void> _seekBy(Duration delta) async {
    _show();
    await _seekTo(_controller.value.position + delta);
  }

  Future<void> _toggleMute() async {
    _show();
    final muted = _controller.value.volume == 0;
    await _controller.setVolume(muted ? 1 : 0);
  }

  Future<void> _chooseSpeed() async {
    _show();
    final strings = Strings.of(context);
    final current = _controller.value.playbackSpeed;
    final chosen = await showHermesMenu<double>(
      context: context,
      anchorKey: _speedAnchor,
      title: strings.videoPlayerSpeed,
      actions: <HermesAction<double>>[
        for (final speed in videoPlaybackSpeeds)
          HermesAction<double>(
            key: ValueKey<String>('video-speed-$speed'),
            value: speed,
            label: _speedLabel(strings, speed),
            icon: speed == current ? Icons.check_rounded : null,
          ),
      ],
    );
    if (chosen == null || !mounted) return;
    await _controller.setPlaybackSpeed(chosen);
    if (mounted) setState(() {});
    _show();
  }

  String _speedLabel(Strings strings, double speed) =>
      strings.videoPlayerSpeedValue(
        NumberFormat.decimalPattern(strings.localeName).format(speed),
      );

  void _onDoubleTap(double width) {
    final at = _doubleTapAt;
    if (at == null || width <= 0) return;
    unawaited(_seekBy(at.dx < width / 2 ? -videoSeekStep : videoSeekStep));
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        fit: StackFit.expand,
        children: [
          Semantics(
            label: strings.videoPlayerToggleControls,
            child: GestureDetector(
              key: const ValueKey<String>('video-gesture-layer'),
              behavior: HitTestBehavior.opaque,
              onTap: _toggleVisible,
              onDoubleTapDown: (details) =>
                  _doubleTapAt = details.localPosition,
              onDoubleTap: () => _onDoubleTap(constraints.maxWidth),
            ),
          ),
          AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: Motion.duration(context, Motion.fast),
            child: IgnorePointer(
              key: const ValueKey<String>('video-controls-overlay'),
              ignoring: !_visible,
              child: ExcludeSemantics(
                excluding: !_visible,
                child: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: _controller,
                  builder: (context, value, _) =>
                      _overlay(context, strings, colors, value),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _overlay(
    BuildContext context,
    Strings strings,
    HermesThemeColors colors,
    VideoPlayerValue value,
  ) {
    const labelStyle = TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    final durationMs = value.duration.inMilliseconds.toDouble();
    final maxMs = durationMs > 0 ? durationMs : 1.0;
    final positionMs = (_dragMs ?? value.position.inMilliseconds.toDouble())
        .clamp(0.0, maxMs);
    double? bufferedMs;
    for (final range in value.buffered) {
      final end = range.end.inMilliseconds.toDouble();
      if (bufferedMs == null || end > bufferedMs) bufferedMs = end;
    }
    final muted = value.volume == 0;
    final replay = _ended && !value.isPlaying;
    final playLabel = value.isPlaying
        ? strings.genVideoPause
        : replay
        ? strings.videoPlayerReplay
        : strings.genVideoPlay;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.55),
                  Colors.black.withValues(alpha: 0.05),
                  Colors.black.withValues(alpha: 0.05),
                  Colors.black.withValues(alpha: 0.6),
                ],
                stops: const [0, 0.3, 0.65, 1],
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Row(
            children: [
              ...widget.leading,
              const Spacer(),
              VideoControlButton(
                key: const ValueKey<String>('video-mute'),
                label: muted
                    ? strings.videoPlayerUnmute
                    : strings.videoPlayerMute,
                icon: muted
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                onPressed: () => unawaited(_toggleMute()),
              ),
              Semantics(
                value: _speedLabel(strings, value.playbackSpeed),
                child: VideoControlButton(
                  key: const ValueKey<String>('video-speed'),
                  label: strings.videoPlayerSpeed,
                  onPressed: () => unawaited(_chooseSpeed()),
                  child: Text(
                    _speedLabel(strings, value.playbackSpeed),
                    key: _speedAnchor,
                    maxLines: 1,
                    style: labelStyle.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              ...widget.trailing,
            ],
          ),
        ),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              VideoControlButton(
                key: const ValueKey<String>('video-seek-back'),
                label: strings.videoPlayerSeekBack,
                icon: Icons.replay_10_rounded,
                iconSize: 28,
                filled: true,
                onPressed: () => unawaited(_seekBy(-videoSeekStep)),
              ),
              const SizedBox(width: 20),
              VideoControlButton(
                key: const ValueKey<String>('video-play-pause'),
                label: playLabel,
                icon: value.isPlaying
                    ? Icons.pause_rounded
                    : replay
                    ? Icons.replay_rounded
                    : Icons.play_arrow_rounded,
                size: 60,
                iconSize: 36,
                filled: true,
                onPressed: () => unawaited(_togglePlay()),
              ),
              const SizedBox(width: 20),
              VideoControlButton(
                key: const ValueKey<String>('video-seek-forward'),
                label: strings.videoPlayerSeekForward,
                icon: Icons.forward_10_rounded,
                iconSize: 28,
                filled: true,
                onPressed: () => unawaited(_seekBy(videoSeekStep)),
              ),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Text(
                formatVideoTime(Duration(milliseconds: positionMs.round())),
                key: const ValueKey<String>('video-position-label'),
                maxLines: 1,
                style: labelStyle,
              ),
              Expanded(
                child: Semantics(
                  label: strings.videoPlayerPosition,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: colors.accent,
                      thumbColor: colors.accent,
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.25),
                      secondaryActiveTrackColor: Colors.white.withValues(
                        alpha: 0.5,
                      ),
                      overlayColor: colors.accent.withValues(alpha: 0.2),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 18,
                      ),
                    ),
                    child: Slider(
                      key: const ValueKey<String>('video-seek-slider'),
                      min: 0,
                      max: maxMs,
                      value: positionMs,
                      secondaryTrackValue: bufferedMs?.clamp(0.0, maxMs),
                      semanticFormatterCallback: (v) =>
                          formatVideoTime(Duration(milliseconds: v.round())),
                      onChangeStart: (v) {
                        _hideTimer?.cancel();
                        _resumeAfterDrag = _controller.value.isPlaying;
                        if (_resumeAfterDrag) unawaited(_controller.pause());
                        setState(() => _dragMs = v);
                      },
                      onChanged: (v) => setState(() => _dragMs = v),
                      onChangeEnd: (v) async {
                        final resume = _resumeAfterDrag;
                        _resumeAfterDrag = false;
                        await _seekTo(Duration(milliseconds: v.round()));
                        if (!mounted) return;
                        setState(() => _dragMs = null);
                        if (resume) await _controller.play();
                        _show();
                      },
                    ),
                  ),
                ),
              ),
              Text(
                formatVideoTime(value.duration),
                key: const ValueKey<String>('video-duration-label'),
                maxLines: 1,
                style: labelStyle,
              ),
              VideoControlButton(
                key: const ValueKey<String>('video-fullscreen'),
                label: widget.isFullscreen
                    ? strings.videoPlayerExitFullscreen
                    : strings.genVideoFullscreen,
                icon: widget.isFullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                onPressed: widget.onFullscreen,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
