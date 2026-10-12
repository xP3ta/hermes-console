import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'attachment_card.dart' show saveMediaToGallery, shareMediaFile;
import 'video_player_controls.dart';

/// Inline, non-autoplaying player for generated videos cached in app-private
/// storage, with the shared [VideoPlayerControls] (scrub, replay, ±10 s,
/// mute, speed, full screen). Playback pauses whenever the app leaves the
/// foreground or a page covers the chat.
///
/// Every mount owns a fresh [VideoPlayerController]: the lazy transcript
/// disposes and rebuilds rows freely (leaving the chat, scrolling, a new turn
/// shifting rows), so nothing may keep using a controller after its card is
/// gone. The last position per file is remembered so a remounted row resumes
/// where the user left it instead of jumping back to the first frame.
class GeneratedVideoCard extends StatefulWidget {
  final File file;

  const GeneratedVideoCard({super.key, required this.file});

  static const int _positionMemoCapacity = 24;

  /// Insertion-ordered: the first entry is the least recently used.
  static final Map<String, Duration> _positions = <String, Duration>{};

  @visibleForTesting
  static void clearPlaybackMemoryForTesting() => _positions.clear();

  static Duration? _recallPosition(String path) => _positions[path];

  static void _rememberPosition(String path, Duration position) {
    _positions.remove(path);
    if (position <= Duration.zero) return;
    _positions[path] = position;
    while (_positions.length > _positionMemoCapacity) {
      _positions.remove(_positions.keys.first);
    }
  }

  @override
  State<GeneratedVideoCard> createState() => _GeneratedVideoCardState();
}

class _GeneratedVideoCardState extends State<GeneratedVideoCard> {
  VideoPlayerController? _controller;
  Object? _error;
  bool _initializing = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initialize(autoplay: false));
    });
  }

  @override
  void didUpdateWidget(covariant GeneratedVideoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _generation++;
      _releaseController(rememberAs: oldWidget.file.path);
      _error = null;
      _initializing = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_initialize(autoplay: false));
      });
    }
  }

  /// Detaches and disposes the current controller, remembering where it was.
  void _releaseController({String? rememberAs}) {
    final previous = _controller;
    _controller = null;
    if (previous == null) return;
    previous.removeListener(_onControllerValue);
    if (previous.value.isInitialized) {
      GeneratedVideoCard._rememberPosition(
        rememberAs ?? widget.file.path,
        previous.value.position,
      );
    }
    unawaited(previous.dispose());
  }

  /// A platform failure after initialization (decoder or surface lost, e.g.
  /// on resume) turns the value erroneous. Without this the card kept the
  /// dead frame and its play button did nothing visible.
  void _onControllerValue() {
    final controller = _controller;
    if (controller == null || !mounted || !controller.value.hasError) return;
    _generation++;
    controller.removeListener(_onControllerValue);
    _controller = null;
    unawaited(controller.dispose());
    setState(() {
      _error = controller.value.errorDescription ?? 'playback error';
      _initializing = false;
    });
  }

  Future<void> _initialize({bool autoplay = true}) async {
    if (_initializing) return;
    final generation = ++_generation;
    _releaseController();
    if (!mounted || generation != _generation) return;
    setState(() {
      _initializing = true;
      _error = null;
    });
    final controller = VideoPlayerController.file(widget.file);
    try {
      await controller.initialize();
      if (!mounted || generation != _generation) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(false);
      final resumeAt = GeneratedVideoCard._recallPosition(widget.file.path);
      if (resumeAt != null &&
          resumeAt > Duration.zero &&
          resumeAt < controller.value.duration) {
        await controller.seekTo(resumeAt);
      }
      if (!mounted || generation != _generation) {
        await controller.dispose();
        return;
      }
      controller.addListener(_onControllerValue);
      setState(() {
        _controller = controller;
        _initializing = false;
      });
      if (autoplay) await controller.play();
    } catch (error) {
      await controller.dispose();
      if (!mounted || generation != _generation) return;
      setState(() {
        _controller = null;
        _error = error;
        _initializing = false;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    _releaseController();
    super.dispose();
  }

  /// Full screen gets its own controller (see [showVideoViewer]); the inline
  /// one hands over position, play state, volume and speed, and picks the
  /// viewer's state back up on return.
  Future<void> _openFullscreen() async {
    final controller = _controller;
    final path = widget.file.path;
    var start = const VideoPlaybackHandoff();
    if (controller != null && controller.value.isInitialized) {
      start = VideoPlaybackHandoff.of(controller);
      await controller.pause();
    }
    if (!mounted) return;
    final back = await showVideoViewer(context, widget.file, start: start);
    if (back != null) GeneratedVideoCard._rememberPosition(path, back.position);
    final current = _controller;
    if (!mounted || back == null || current == null) return;
    if (current.value.isInitialized) await back.applyTo(current);
  }

  /// The placeholder's button: Retry after a failure (shows the paused
  /// first frame again), Play otherwise.
  Future<void> _startOrRetry() => _initialize(autoplay: _error == null);

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final controller = _controller;
    if (_initializing) {
      return _VideoFrame(
        child: Semantics(
          label: strings.genMediaLoading,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      final failed = _error != null;
      return _VideoFrame(
        child: Center(
          child: TextButton.icon(
            onPressed: _startOrRetry,
            icon: Icon(
              failed ? Icons.refresh_rounded : Icons.play_arrow_rounded,
            ),
            label: Text(failed ? strings.commonRetry : strings.genVideoPlay),
          ),
        ),
      );
    }

    final rawRatio = controller.value.aspectRatio;
    final ratio = rawRatio.isFinite && rawRatio > 0
        ? rawRatio.clamp(0.5, 2.4).toDouble()
        : 16 / 9;
    return Semantics(
      container: true,
      label: strings.genVideoSemanticLabel,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: Colors.black,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : 300.0;
              // Tall enough for the three control rows even for a very wide
              // clip; capped so a portrait clip does not fill the chat.
              final height = math.max(
                _inlineMinHeight,
                math.min(width / ratio, _inlineMaxHeight),
              );
              return SizedBox(
                width: width,
                height: height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: AspectRatio(
                        aspectRatio: ratio,
                        child: VideoPlayer(controller),
                      ),
                    ),
                    VideoPlayerControls(
                      controller: controller,
                      isFullscreen: false,
                      onFullscreen: () => unawaited(_openFullscreen()),
                      leading: [
                        VideoControlButton(
                          icon: Icons.download_rounded,
                          label: strings.imgSaveToGallery,
                          onPressed: () => saveMediaToGallery(
                            context,
                            widget.file,
                            isVideo: true,
                          ),
                        ),
                        VideoControlButton(
                          icon: Icons.share_outlined,
                          label: strings.commonShare,
                          onPressed: () => shareMediaFile(widget.file),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

const double _inlineMinHeight = 200;
const double _inlineMaxHeight = 480;

class _VideoFrame extends StatelessWidget {
  final Widget child;
  const _VideoFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      constraints: const BoxConstraints(minHeight: 150, maxHeight: 360),
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: child,
    );
  }
}

/// Full-screen video viewer: black page, the shared [VideoPlayerControls]
/// (download/share/close on top, exit-full-screen on the timeline row) and
/// landscape allowed while it is open.
///
/// The route creates, plays and disposes its OWN controller. It used to
/// borrow the inline card's controller, and the lazy transcript disposes
/// that card whenever it rebuilds or recycles the row underneath the open
/// viewer, which left the viewer driving a disposed player: play did nothing.
/// It starts from [start] (playing only if the card was playing) and
/// completes with its own final state so the card resumes from there.
Future<VideoPlaybackHandoff?> showVideoViewer(
  BuildContext context,
  File file, {
  VideoPlaybackHandoff start = const VideoPlaybackHandoff(),
}) {
  return Navigator.of(context).push<VideoPlaybackHandoff>(
    PageRouteBuilder<VideoPlaybackHandoff>(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, anim, _) => CoveredRouteMediaQueryFreeze(
        child: FadeTransition(
          opacity: anim,
          child: _GeneratedVideoViewer(file: file, start: start),
        ),
      ),
    ),
  );
}

class _GeneratedVideoViewer extends StatefulWidget {
  const _GeneratedVideoViewer({required this.file, required this.start});

  final File file;
  final VideoPlaybackHandoff start;

  @override
  State<_GeneratedVideoViewer> createState() => _GeneratedVideoViewerState();
}

class _GeneratedVideoViewerState extends State<_GeneratedVideoViewer> {
  VideoPlayerController? _controller;
  bool _ready = false;
  Object? _error;
  int _generation = 0;

  /// The state handed back to the card; updated before every pop.
  late VideoPlaybackHandoff _resume = widget.start;

  @override
  void initState() {
    super.initState();
    // Landscape is allowed only while full screen is open; leaving restores
    // the app's own orientation policy.
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(_start());
  }

  Future<void> _start() async {
    final generation = ++_generation;
    final controller = VideoPlayerController.file(widget.file);
    setState(() {
      _controller = controller;
      _ready = false;
      _error = null;
    });
    try {
      await controller.initialize();
      if (!mounted || generation != _generation) return;
      await controller.setLooping(false);
      await _resume.applyTo(controller);
      if (!mounted || generation != _generation) return;
      setState(() => _ready = true);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      _controller = null;
      unawaited(controller.dispose());
      setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _generation++;
    final controller = _controller;
    if (controller != null) {
      if (controller.value.isInitialized) {
        GeneratedVideoCard._rememberPosition(
          widget.file.path,
          controller.value.position,
        );
      }
      unawaited(controller.dispose());
    }
    unawaited(
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]),
    );
    super.dispose();
  }

  void _close() {
    final controller = _controller;
    if (_ready && controller != null && controller.value.isInitialized) {
      _resume = VideoPlaybackHandoff.of(controller);
      unawaited(controller.pause());
    }
    Navigator.of(context).pop(_ready ? _resume : null);
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final controller = _controller;
    final file = widget.file;
    final download = VideoControlButton(
      icon: Icons.download_rounded,
      label: strings.imgSaveToGallery,
      onPressed: () => saveMediaToGallery(context, file, isVideo: true),
    );
    final share = VideoControlButton(
      icon: Icons.share_outlined,
      label: strings.commonShare,
      onPressed: () => shareMediaFile(file),
    );
    final close = VideoControlButton(
      icon: Icons.close,
      label: strings.commonClose,
      onPressed: _close,
    );
    final Widget body;
    if (_ready && controller != null) {
      final ratio = controller.value.aspectRatio;
      body = Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: ratio.isFinite && ratio > 0 ? ratio : 16 / 9,
              child: VideoPlayer(controller),
            ),
          ),
          VideoPlayerControls(
            key: const ValueKey<String>('generated-video-viewer-playback'),
            controller: controller,
            isFullscreen: true,
            onFullscreen: _close,
            leading: [download, share],
            trailing: [close],
          ),
        ],
      );
    } else {
      body = Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: _error == null
                ? Semantics(
                    label: strings.genMediaLoading,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        strings.genMediaError,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: () => unawaited(_start()),
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(strings.commonRetry),
                      ),
                    ],
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Row(children: [download, share, const Spacer(), close]),
          ),
        ],
      );
    }
    return PopScope<VideoPlaybackHandoff>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: KeyedSubtree(
            key: const ValueKey<String>('generated-video-viewer-safe-area'),
            child: body,
          ),
        ),
      ),
    );
  }
}
