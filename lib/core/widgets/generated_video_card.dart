import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'attachment_card.dart' show saveMediaToGallery, shareMediaFile;

/// `mm:ss` for a playback position/duration. Local formatting only — does
/// not touch how the video is decoded or played.
String _formatPlaybackTime(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString();
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Inline, non-autoplaying player for generated videos cached in app-private
/// storage. Playback is paused whenever the app leaves the foreground.
class GeneratedVideoCard extends StatefulWidget {
  final File file;

  const GeneratedVideoCard({super.key, required this.file});

  @override
  State<GeneratedVideoCard> createState() => _GeneratedVideoCardState();
}

class _GeneratedVideoCardState extends State<GeneratedVideoCard>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  Object? _error;
  bool _initializing = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant GeneratedVideoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _generation++;
      final previous = _controller;
      _controller = null;
      if (previous != null) unawaited(previous.dispose());
      _error = null;
      _initializing = false;
    }
  }

  Future<void> _initialize() async {
    if (_initializing) return;
    final generation = ++_generation;
    final previous = _controller;
    _controller = null;
    await previous?.dispose();
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
      if (!mounted || generation != _generation) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initializing = false;
      });
      await controller.play();
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _controller?.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      await _initialize();
      return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      if (controller.value.position >= controller.value.duration) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
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
            onPressed: _togglePlayback,
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
        ? rawRatio.clamp(0.5, 2.4)
        : 16 / 9;
    return Semantics(
      container: true,
      label: strings.genVideoSemanticLabel,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: Colors.black,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _togglePlayback,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: ratio.toDouble(),
                      child: VideoPlayer(controller),
                    ),
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: controller,
                      builder: (context, value, _) => AnimatedOpacity(
                        opacity: value.isPlaying ? 0 : 1,
                        duration: const Duration(milliseconds: 150),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.58),
                            shape: BoxShape.circle,
                          ),
                          child: Semantics(
                            button: true,
                            label: strings.genVideoPlay,
                            excludeSemantics: true,
                            child: const Padding(
                              padding: EdgeInsets.all(14),
                              child: Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 34,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Degradado superior + fila de iconos (descargar,
                    // compartir, pantalla completa) — misma anatomía que ya
                    // existe para las imágenes generadas.
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: IgnorePointer(
                        child: Container(
                          height: 52,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.55),
                                Colors.black.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _VideoOverlayIconButton(
                            icon: Icons.download_rounded,
                            tooltip: strings.imgSaveToGallery,
                            onPressed: () => saveMediaToGallery(
                              context,
                              widget.file,
                              isVideo: true,
                            ),
                          ),
                          const SizedBox(width: 4),
                          _VideoOverlayIconButton(
                            icon: Icons.share_outlined,
                            tooltip: strings.commonShare,
                            onPressed: () => shareMediaFile(widget.file),
                          ),
                          const SizedBox(width: 4),
                          _VideoOverlayIconButton(
                            icon: Icons.fullscreen_rounded,
                            tooltip: strings.genVideoFullscreen,
                            onPressed: () => showVideoViewer(
                              context,
                              widget.file,
                              controller,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Badge de duración, igual que en el visor de imágenes.
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            _formatPlaybackTime(controller.value.duration),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ColoredBox(
                color: colors.surfaceVariant,
                child: Row(
                  children: [
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: controller,
                      builder: (context, value, _) => Semantics(
                        button: true,
                        label: value.isPlaying
                            ? strings.genVideoPause
                            : strings.genVideoPlay,
                        excludeSemantics: true,
                        child: IconButton(
                          onPressed: _togglePlayback,
                          icon: Icon(
                            value.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: VideoProgressIndicator(
                        controller,
                        allowScrubbing: true,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        colors: VideoProgressColors(
                          playedColor: colors.accent,
                          bufferedColor: colors.textSecondary.withValues(
                            alpha: 0.35,
                          ),
                          backgroundColor: colors.divider,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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

/// Small round icon button used in the card's top overlay row (download,
/// share, fullscreen) — same 28px-ish scrim-circle affordance the image
/// viewer uses, just sized for an inline card instead of a full toolbar.
class _VideoOverlayIconButton extends StatelessWidget {
  const _VideoOverlayIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.4),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 28,
            height: 28,
            child: Icon(icon, size: 15, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Fullscreen video viewer: same anatomy as [showImageViewer] (black
/// background, white download/share/spacer/close row on top) plus a
/// floating playback bar (play/pause, accent scrubber, times) over black,
/// with no extra container.
///
/// Reuses the [controller] the card already created and initialized —
/// playback/decoding is entirely owned by [GeneratedVideoCard]; this route
/// only reads its [ValueListenableBuilder] state and calls the same
/// play/pause/seekTo controls the card's own toggle already uses.
Future<void> showVideoViewer(
  BuildContext context,
  File file,
  VideoPlayerController controller,
) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      barrierDismissible: true,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, anim, _) => FadeTransition(
        opacity: anim,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () {
                      if (controller.value.isPlaying) {
                        controller.pause();
                      } else {
                        controller.play();
                      }
                    },
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: VideoPlayer(controller),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  left: 8,
                  child: Row(
                    children: [
                      Builder(
                        builder: (innerCtx) => IconButton(
                          icon: const Icon(
                            Icons.download_rounded,
                            color: Colors.white,
                          ),
                          tooltip: Strings.of(innerCtx).imgSaveToGallery,
                          onPressed: () =>
                              saveMediaToGallery(innerCtx, file, isVideo: true),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.share_outlined,
                          color: Colors.white,
                        ),
                        tooltip: Strings.of(ctx).commonShare,
                        onPressed: () => shareMediaFile(file),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        tooltip: Strings.of(ctx).commonClose,
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 20,
                  child: _VideoViewerPlaybackBar(controller: controller),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Floating playback bar for the fullscreen viewer: play/pause, an
/// accent-colored scrubber and elapsed/total times — no background
/// container, just white/accent controls over the black viewer.
class _VideoViewerPlaybackBar extends StatelessWidget {
  const _VideoViewerPlaybackBar({required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Material(
              color: Colors.white.withValues(alpha: 0.12),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () {
                  if (value.isPlaying) {
                    controller.pause();
                  } else {
                    controller.play();
                  }
                },
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Semantics(
                    button: true,
                    label: value.isPlaying
                        ? strings.genVideoPause
                        : strings.genVideoPlay,
                    excludeSemantics: true,
                    child: Icon(
                      value.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  Text(
                    _formatPlaybackTime(value.position),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: VideoProgressIndicator(
                      controller,
                      allowScrubbing: true,
                      padding: EdgeInsets.zero,
                      colors: VideoProgressColors(
                        playedColor: colors.accent,
                        bufferedColor: Colors.white.withValues(alpha: 0.3),
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _formatPlaybackTime(value.duration),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
