import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

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
